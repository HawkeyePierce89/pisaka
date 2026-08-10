#if os(macOS)
import Foundation
import PisakaCore

/// The real `LSPArchiveUnpacking`: one system tool, fed on stdin (D14).
///
/// The second app-side seam, and the smaller one. Core decides *which* archive is
/// unpacked, *where* it lands and *how many* leading components to drop; this file
/// runs the one program that can do it and reports whether it worked. Like
/// `LSPProcessTransport` and `LSPDownloadService` it is untested by repository
/// convention, so it is kept to a few readable functions over one shared runner.
///
/// **`/usr/bin/tar` and `/usr/bin/gunzip`, not a library.** macOS ships bsdtar
/// (via libarchive) and gzip as system binaries, and they have read these two
/// formats correctly for longer than this project has existed. The alternative —
/// linking libarchive, or writing a gzip inflater and a tar reader — would add a
/// dependency and a license obligation to avoid a subprocess the app already
/// spawns several of. Both are spelled as absolute paths rather than through
/// `/usr/bin/env`, for `LSPToolchain.locate`'s reason: a `PATH` entry must not get
/// to decide which tool unpacks code that is about to be executed.
///
/// **The bytes go in on stdin.** They arrive from the download seam as a `Data`
/// that has already been verified against its pinned digest, and writing them to a
/// temporary file first would mean a file to create, to keep off the user's way,
/// and to delete on every failure path — for no gain, since both tools read a
/// stream perfectly well. It also keeps the *verified* bytes and the *unpacked*
/// bytes the same bytes, with no window in between in which something else could
/// rewrite them.
///
/// **The two formats differ in where stdout goes, and nowhere else** (D22). `tar`
/// writes the files itself and says nothing on stdout, so its stdout is a pipe
/// drained and discarded; `gunzip` writes the *file itself* on stdout, so its
/// stdout is the destination file — created up front with `0o755`, which is what
/// makes the binary executable at the moment it comes into existence rather than
/// by a `chmod` afterwards, and which keeps the ~38 MB from being held a second
/// time in this process's memory. Everything else — the deadline, `F_SETNOSIGPIPE`,
/// the SIGTERM→SIGKILL teardown, the exit status — is one shared function.
///
/// `@unchecked Sendable` over no state at all: this type holds nothing, and each
/// call owns its own process and pipes.
final class LSPArchiveUnpacker: LSPArchiveUnpacking, @unchecked Sendable {
    private static let tarPath = "/usr/bin/tar"
    private static let gunzipPath = "/usr/bin/gunzip"

    /// The mode the decompressed `.gzip` file is created with — `rwxr-xr-x`, the
    /// mode a downloaded binary needs and the one `tar` would have restored from a
    /// tarball's own header. Set at creation, so there is no window in which the
    /// file exists and cannot be run, and `LSPInstallEngine` refuses to commit if
    /// it somehow is not there.
    private static let executableMode = 0o755

    /// Where the blocking work runs. Concurrent, so two unpacks — which the
    /// engine's serial sequence never asks for today, but a future parallel
    /// install would — do not queue behind each other.
    private static let queue = DispatchQueue(
        label: "LSPArchiveUnpacker",
        qos: .utility,
        attributes: .concurrent
    )

    /// How long the tool gets before it is killed.
    ///
    /// The download seam is bounded on both axes (60 s request, 20 min resource)
    /// and this half was not, which made it the one unbounded operation in an
    /// install. That asymmetry is not survivable here: `LSPInstallEngine` keeps
    /// the component in `installs` and `LSPProvisioningModel` keeps the server in
    /// `attempts` until this returns, and *both* are what report `.installing` —
    /// so a continuation that never resumes leaves the row spinning with
    /// `canInstall` and `canRemove` false and `remove(_:)` refusing on its
    /// `attempts[server] == nil` guard. Not a slow install: a dead one, for the
    /// rest of the app run, with nothing said and no way back but quitting.
    ///
    /// Ten minutes is chosen the way the resource timeout was — far above any
    /// real duration (the largest component is 53 MB and unpacks in seconds, so
    /// this is two orders of magnitude of headroom) and far below "never", which
    /// is the only number it is really competing with. A timeout throws, the
    /// engine's existing `catch` discards the staging tree, and the row lands on
    /// the same "not installed + Retry" state every other failure produces.
    private static let deadline: DispatchTimeInterval = .seconds(10 * 60)

    /// How long a killed tool gets to actually die, and its drains to finish.
    private static let teardownGrace: DispatchTimeInterval = .seconds(5)

    /// Why an unpack did not happen.
    ///
    /// Bare reason phrases, for the reason `LSPDownloadService.Failure` states at
    /// length: `LSPInstallEngine` re-attributes whatever this throws to the
    /// component it is installing, so a second attribution here would surface as
    /// two sentences about one failure.
    enum Failure: Error, LocalizedError {
        /// The tool is not where it has always been, or could not be launched.
        case toolUnavailable(String)
        /// It ran and refused: a truncated archive, an unreadable member, a
        /// destination that vanished.
        case extractionFailed(status: Int32, message: String)
        /// It ran and never finished, so it was killed (see `deadline`).
        case timedOut
        /// The `.gzip` destination file could not be created to write into — a
        /// staging directory that vanished, a full or read-only volume. Its own
        /// case because it happens *before* anything is launched, so there is no
        /// exit status and no diagnostic line to report.
        case destinationUnwritable(String)

        var errorDescription: String? {
            switch self {
            case .toolUnavailable(let reason):
                return "The system archive tool could not be run. \(reason)"
            case let .extractionFailed(status, message):
                return message.isEmpty ? "The archive tool exited with status \(status)." : message
            case .timedOut:
                return "The archive tool did not finish and was stopped."
            case .destinationUnwritable(let path):
                return "“\(path)” could not be created."
            }
        }
    }

    /// The tool's stderr, written by one queue and read by another.
    ///
    /// An ordinary local would do if the drain were always joined before the
    /// read — which is exactly what stops being true once the join is bounded:
    /// on the timeout path the deadline can expire while the drain thread is
    /// still inside `readDataToEndOfFile`, and reading the same storage from two
    /// threads is a data race whatever the timing usually is.
    private final class Diagnostics: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func store(_ value: Data) {
            lock.lock()
            defer { lock.unlock() }
            data = value
        }

        var value: Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    init() {}

    func unpack(
        _ archive: Data,
        format: LSPArchiveFormat,
        into destination: URL,
        stripComponents: Int
    ) async throws {
        // Exhaustive on purpose rather than a comparison: a third format is a
        // compile error here, which is the whole reason `LSPArchiveFormat` is an
        // enum and not a `Bool` (see its own note).
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.queue.async {
                do {
                    switch format {
                    case .tarGzip:
                        try Self.extractTarball(
                            archive: archive,
                            destination: destination,
                            stripComponents: stripComponents
                        )
                    case .gzip(let fileName):
                        // `stripComponents` is deliberately unused: a bare `.gz`
                        // holds one file and no layout, and the manifest pins the
                        // value to 0 for exactly that reason.
                        try Self.expandFile(
                            archive: archive,
                            destination: destination.appendingPathComponent(fileName)
                        )
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// One `tar -xz --strip-components=<n> -C <dir>`.
    private static func extractTarball(
        archive: Data,
        destination: URL,
        stripComponents: Int
    ) throws {
        try run(
            tool: tarPath,
            // `-f -` is explicit rather than relying on the default archive:
            // bsdtar reads stdin when no file is given, but which stream a `tar`
            // defaults to is exactly the sort of thing that differs between
            // implementations, and this one is being handed 53 MB on a pipe.
            arguments: [
                "-x",
                "-z",
                "-f", "-",
                "--strip-components=\(stripComponents)",
                "-C", destination.path,
            ],
            archive: archive,
            output: .discarded
        )
    }

    /// One `gunzip -c` writing straight into `destination`, which is created
    /// executable before the tool is launched.
    ///
    /// The file is created here rather than by redirecting into something the
    /// shell made, because there is no shell: `Process.standardOutput` takes a
    /// `FileHandle`, and a handle needs a file. Creating it with the mode already
    /// on it is the whole point — a `chmod` afterwards would leave a window in
    /// which the binary exists and cannot be run, and a failure between the two
    /// would commit exactly the unrunnable install `LSPInstallEngine`'s gate
    /// refuses.
    private static func expandFile(archive: Data, destination: URL) throws {
        guard FileManager.default.createFile(
            atPath: destination.path,
            contents: nil,
            attributes: [.posixPermissions: executableMode]
        ), let handle = try? FileHandle(forWritingTo: destination) else {
            throw Failure.destinationUnwritable(destination.path)
        }
        // Closed on every path, including the timeout: the handle is this
        // process's, and leaving it open would leak a descriptor per failed
        // install and keep the file the engine is about to delete alive.
        defer { try? handle.close() }

        try run(
            tool: gunzipPath,
            // `-c` is what makes it write to stdout rather than looking for a
            // `.gz` file to replace beside itself; with no operand it reads stdin.
            arguments: ["-c"],
            archive: archive,
            output: .file(handle)
        )
    }

    /// Where the tool's stdout goes.
    private enum Output {
        /// A pipe, drained on its own queue and thrown away — `tar`, which says
        /// nothing there but must never be left to fill a buffer nobody reads.
        case discarded
        /// The tool *is* the writer: `gunzip -c` emits the unpacked file itself,
        /// so its stdout is the destination handle and no byte of it passes
        /// through this process.
        case file(FileHandle)
    }

    /// One tool, fed `archive` on stdin, start to exit status.
    ///
    /// Blocking from top to bottom, which is why it only ever runs on `queue`.
    private static func run(
        tool: String,
        arguments: [String],
        archive: Data,
        output: Output
    ) throws {
        let executable = URL(fileURLWithPath: tool)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw Failure.toolUnavailable("\(tool) is not there.")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let input = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardError = errors

        let outputPipe: Pipe?
        switch output {
        case .discarded:
            let pipe = Pipe()
            process.standardOutput = pipe
            outputPipe = pipe
        case .file(let handle):
            process.standardOutput = handle
            outputPipe = nil
        }
        // The environment is inherited wholesale and never assigned, for
        // `LSPProcessTransport`'s reason: nothing here needs a variable set, so
        // nothing is.

        // `tar` that rejects the archive exits while there are still tens of
        // megabytes queued for its stdin, and writing to a pipe whose read end is
        // gone raises `SIGPIPE` — whose default disposition kills the *app*. Set
        // per descriptor rather than by ignoring the signal process-wide, exactly
        // as `LSPProcessTransport` does: `write(2)` then answers `EPIPE`, the write
        // below fails harmlessly, and the exit status is what reports the failure.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, Int32(1))

        // Assigned before `run()`, which is the only order in which it is
        // guaranteed to fire: a small archive can be extracted and exited from
        // before the next statement on this thread runs.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            throw Failure.toolUnavailable(error.localizedDescription)
        }

        // Three streams, three threads, and none of them may wait for another —
        // `GitCLIService`/`LSPToolchain`'s deadlock rule, which bites harder here
        // than anywhere else in the app: the archive is far larger than any pipe
        // buffer, so a write that is not concurrent with the drains blocks
        // forever the moment the tool writes more diagnostics than its own buffer
        // holds. So stdin is written on one queue and each output stream is
        // drained on its own — including stderr, which used to be read on this
        // thread and now cannot be, because this thread has a deadline to keep.
        let streams = DispatchGroup()
        let writeQueue = DispatchQueue(label: "LSPArchiveUnpacker.stdin")
        let stdin = input.fileHandleForWriting
        writeQueue.async(group: streams) {
            try? stdin.write(contentsOf: archive)
            // Closing is what tells the tool the archive is complete; without it
            // a successful extraction would sit waiting for more input.
            try? stdin.close()
        }

        // Only when stdout is a pipe. A stdout that *is* the destination file
        // needs no drain — a file never blocks a writer the way a full pipe does,
        // and there is nothing on this side to read.
        if let outputPipe {
            let outputQueue = DispatchQueue(label: "LSPArchiveUnpacker.stdout")
            outputQueue.async(group: streams) {
                _ = outputPipe.fileHandleForReading.readDataToEndOfFile()
            }
        }

        let diagnostics = Diagnostics()
        let errorQueue = DispatchQueue(label: "LSPArchiveUnpacker.stderr")
        errorQueue.async(group: streams) {
            diagnostics.store(errors.fileHandleForReading.readDataToEndOfFile())
        }

        // The exit is waited for rather than the drains, because the drains are
        // the thing that can outlive it: a pipe stays readable while any
        // descriptor for its write end is open, and the process ending is the
        // event that says whether this install worked.
        if exited.wait(timeout: .now() + deadline) == .timedOut {
            kill(process, waitingOn: exited)
            _ = streams.wait(timeout: .now() + teardownGrace)
            throw Failure.timedOut
        }

        // Bounded for the same reason the exit wait is: the tool is gone, but a
        // drain blocked on a descriptor something else inherited would otherwise
        // reinstate exactly the unbounded wait this method exists to avoid. The
        // status below is what decides the outcome; the drains only decorate it,
        // so an unfinished one costs a diagnostic line, not correctness.
        _ = streams.wait(timeout: .now() + teardownGrace)
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw Failure.extractionFailed(
                status: process.terminationStatus,
                message: lastLine(of: diagnostics.value)
            )
        }
    }

    /// SIGTERM, a grace period, then SIGKILL — `LSPProcessTransport`'s teardown,
    /// for its reason: a process wedged badly enough to miss the deadline is one
    /// that may also ignore a polite signal, and leaving it holding a staging
    /// directory that is about to be deleted is worse than killing it.
    private static func kill(_ process: Process, waitingOn exited: DispatchSemaphore) {
        process.terminate()
        guard exited.wait(timeout: .now() + teardownGrace) == .timedOut else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
        _ = exited.wait(timeout: .now() + teardownGrace)
    }

    /// The last thing the tool complained about, trimmed and capped.
    ///
    /// The last line rather than the whole stream: a failing extraction can report
    /// one line per member, and what ends up in a Settings row should be a
    /// sentence rather than a log. Capped because nothing stops a filename from
    /// being enormous.
    private static func lastLine(of diagnostics: Data) -> String {
        let text = String(decoding: diagnostics, as: UTF8.self)
        let line = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }
}

#endif
