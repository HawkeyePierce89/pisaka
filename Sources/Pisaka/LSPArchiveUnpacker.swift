#if os(macOS)
import Foundation
import PisakaCore

/// The real `LSPArchiveUnpacking`: one `tar`, fed on stdin (D14).
///
/// The second app-side seam, and the smaller one. Core decides *which* archive is
/// unpacked, *where* it lands and *how many* leading components to drop; this file
/// runs the one program that can do it and reports whether it worked. Like
/// `LSPProcessTransport` and `LSPDownloadService` it is untested by repository
/// convention, so it is kept to a single readable function.
///
/// **`/usr/bin/tar`, not a library.** macOS ships bsdtar (via libarchive) as a
/// system binary and it has read gzip'd tarballs correctly for longer than this
/// project has existed. The alternative — linking libarchive, or writing a gzip
/// inflater and a tar reader — would add a dependency and a license obligation to
/// avoid a subprocess the app already spawns several of. Spelled as an absolute
/// path rather than through `/usr/bin/env`, for `LSPToolchain.locate`'s reason: a
/// `PATH` entry must not get to decide which `tar` unpacks code that is about to
/// be executed.
///
/// **The bytes go in on stdin.** They arrive from the download seam as a `Data`
/// that has already been verified against its pinned digest, and writing them to a
/// temporary file first would mean a file to create, to keep off the user's way,
/// and to delete on every failure path — for no gain, since `tar` reads a stream
/// perfectly well. It also keeps the *verified* bytes and the *unpacked* bytes the
/// same bytes, with no window in between in which something else could rewrite
/// them.
///
/// `@unchecked Sendable` over no state at all: this type holds nothing, and each
/// call owns its own process and pipes.
final class LSPArchiveUnpacker: LSPArchiveUnpacking, @unchecked Sendable {
    private static let tarPath = "/usr/bin/tar"

    /// Where the blocking work runs. Concurrent, so two unpacks — which the
    /// engine's serial sequence never asks for today, but a future parallel
    /// install would — do not queue behind each other.
    private static let queue = DispatchQueue(
        label: "LSPArchiveUnpacker",
        qos: .utility,
        attributes: .concurrent
    )

    /// Why an unpack did not happen.
    ///
    /// Bare reason phrases, for the reason `LSPDownloadService.Failure` states at
    /// length: `LSPInstallEngine` re-attributes whatever this throws to the
    /// component it is installing, so a second attribution here would surface as
    /// two sentences about one failure.
    enum Failure: Error, LocalizedError {
        /// `tar` is not where it has always been, or could not be launched.
        case tarUnavailable(String)
        /// It ran and refused: a truncated archive, an unreadable member, a
        /// destination that vanished.
        case extractionFailed(status: Int32, message: String)

        var errorDescription: String? {
            switch self {
            case .tarUnavailable(let reason):
                return "The system archive tool could not be run. \(reason)"
            case let .extractionFailed(status, message):
                return message.isEmpty ? "The archive tool exited with status \(status)." : message
            }
        }
    }

    init() {}

    func unpack(
        _ archive: Data,
        format: LSPArchiveFormat,
        into destination: URL,
        stripComponents: Int
    ) async throws {
        // Exhaustive on purpose rather than a comparison: a second format is a
        // compile error here, which is the whole reason `LSPArchiveFormat` is an
        // enum and not a `Bool` (see its own note).
        let decompression: String
        switch format {
        case .tarGzip: decompression = "-z"
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.queue.async {
                do {
                    try Self.run(
                        archive: archive,
                        decompression: decompression,
                        destination: destination,
                        stripComponents: stripComponents
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// One `tar -xz --strip-components=<n> -C <dir>`, start to exit status.
    ///
    /// Blocking from top to bottom, which is why it only ever runs on `queue`.
    private static func run(
        archive: Data,
        decompression: String,
        destination: URL,
        stripComponents: Int
    ) throws {
        let executable = URL(fileURLWithPath: tarPath)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw Failure.tarUnavailable("\(tarPath) is not there.")
        }

        let process = Process()
        process.executableURL = executable
        // `-f -` is explicit rather than relying on the default archive: bsdtar
        // reads stdin when no file is given, but which stream a `tar` defaults to
        // is exactly the sort of thing that differs between implementations, and
        // this one is being handed 53 MB on a pipe.
        process.arguments = [
            "-x",
            decompression,
            "-f", "-",
            "--strip-components=\(stripComponents)",
            "-C", destination.path,
        ]

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
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

        do {
            try process.run()
        } catch {
            throw Failure.tarUnavailable(error.localizedDescription)
        }

        // Three streams, three threads, and none of them may wait for another —
        // `GitCLIService`/`LSPToolchain`'s deadlock rule, which bites harder here
        // than anywhere else in the app: the archive is far larger than any pipe
        // buffer, so a write that is not concurrent with the drains blocks
        // forever the moment `tar` writes more diagnostics than its own buffer
        // holds. So stdin is written on one queue, stdout is drained on another,
        // and stderr is read to EOF on this thread — which is also what makes
        // `diagnostics` an ordinary local rather than shared mutable state.
        let writeQueue = DispatchQueue(label: "LSPArchiveUnpacker.stdin")
        let stdin = input.fileHandleForWriting
        writeQueue.async {
            try? stdin.write(contentsOf: archive)
            // Closing is what tells `tar` the archive is complete; without it a
            // successful extraction would sit waiting for more input.
            try? stdin.close()
        }

        let outputQueue = DispatchQueue(label: "LSPArchiveUnpacker.stdout")
        outputQueue.async { _ = output.fileHandleForReading.readDataToEndOfFile() }

        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()

        outputQueue.sync {}
        writeQueue.sync {}
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw Failure.extractionFailed(
                status: process.terminationStatus,
                message: lastLine(of: diagnostics)
            )
        }
    }

    /// The last thing `tar` complained about, trimmed and capped.
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
