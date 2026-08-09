#if os(macOS)
import Foundation
import PisakaCore

/// The real `LSPTransport`: one language-server process, three pipes, and no
/// opinion whatsoever about what the bytes mean.
///
/// This is the entire macOS half of the LSP client — the counterpart to
/// `GitCLIService`, written in the same idiom for the same reason. Core owns
/// framing, correlation, budgets and position mapping and is unit-tested without
/// an Xcode installation anywhere in sight; this file owns `Process` and is
/// untested by repository convention, so it is kept small enough to read in one
/// sitting and does exactly three things: write bytes, publish bytes, stop.
///
/// **It never interprets a message and never restarts anything.** A crashed
/// server is reported by `incomingBytes` *finishing*; deciding what that means
/// (D7's backoff, the fourth-failure unavailability) is `LSPWorkspace`'s job,
/// because it is the only thing that knows how many times this has already
/// happened. Re-assembling the chunks into messages is `LSPFraming.Decoder`'s
/// job, and `LSPSession` already owns one — so what is published here is the raw
/// pipe reads, in whatever sizes the kernel had ready, exactly as `LSPTransport`
/// documents.
///
/// `@unchecked Sendable` over an `NSLock`, the `ScriptedLSPTransport` arrangement:
/// `send` is called from the session's actor, the reads arrive on `FileHandle`'s
/// own queue, and `terminate()` can come from either plus `deinit`. The lock is
/// never held across a stream yield or a subprocess wait, so there is nothing to
/// deadlock against.
final class LSPProcessTransport: LSPTransport, @unchecked Sendable {
    /// How long `terminate()` gives `SIGTERM` before escalating to `SIGKILL`.
    ///
    /// Not a courtesy: the release check is `pgrep -fl sourcekit-lsp` coming back
    /// empty after a quit, and a server wedged in its own build-system resolution
    /// will not honour a polite signal. `TerminalSession.terminate()` makes the
    /// same promise about a shell.
    private static let terminationGrace: TimeInterval = 2

    let incomingBytes: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private let errors: Pipe

    /// Writes go here, in order. Serial, so two `send`s can never interleave
    /// halfway through a framed message — which would desync the server's own
    /// decoder permanently.
    private let writeQueue: DispatchQueue

    /// Reaping is blocking (a bounded poll, then `waitUntilExit`), so it gets a
    /// *concurrent* queue: two servers being torn down on a folder switch must not
    /// wait for each other's grace period in turn.
    private static let reapQueue = DispatchQueue(
        label: "LSPProcessTransport.reap",
        attributes: .concurrent
    )

    private let lock = NSLock()
    private var isStopped = false
    private var streamIsFinished = false

    /// Launch `executable` with `arguments`, rooted at `directory`.
    ///
    /// Throws `LSPTransportError.launchFailed` and nothing else: every way this
    /// can fail — a path that is not there, a binary the sandbox refuses, a
    /// toolchain that was deleted between the `xcrun` lookup and now — is the same
    /// answer to `LSPWorkspace`, which spends one restart on it and falls back
    /// silently in the meantime.
    init(executable: URL, arguments: [String], directory: URL) throws {
        var escaped: AsyncStream<Data>.Continuation!
        // Unbounded on purpose. Every element is a piece of the message stream and
        // dropping one desyncs `LSPFraming.Decoder` for good; the bound that
        // actually matters is `Content-Length`'s cap, which Core already enforces.
        incomingBytes = AsyncStream(bufferingPolicy: .unbounded) { escaped = $0 }
        continuation = escaped

        process = Process()
        input = Pipe()
        output = Pipe()
        errors = Pipe()
        writeQueue = DispatchQueue(label: "LSPProcessTransport.write")

        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // The environment is inherited wholesale and never assigned: a language
        // server resolves its toolchain, its caches and its build system out of
        // `PATH`/`HOME`/`DEVELOPER_DIR`, and replacing the environment to add one
        // variable would take all of that away (`GitCLIService.run`'s reasoning,
        // one level down). Nothing here needs a variable set, so nothing is.

        // Writing to a pipe whose read end is gone raises `SIGPIPE`, and the
        // default disposition of `SIGPIPE` kills the *app*. A server that crashes
        // between two `didChange`s is an ordinary event on this path, so the write
        // end is put in no-SIGPIPE mode: `write(2)` then returns `EPIPE`,
        // `FileHandle.write(contentsOf:)` throws it, and the failure is handled
        // like any other death. Set per file descriptor rather than by ignoring
        // the signal process-wide, which would change behaviour for every other
        // pipe in the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, Int32(1))

        do {
            try process.run()
        } catch {
            continuation.finish()
            throw LSPTransportError.launchFailed(
                "\(executable.path): \(error.localizedDescription)"
            )
        }

        startReading()
    }

    deinit {
        // The last line of defence for the orphan check. `LSPWorkspace` terminates
        // deliberately on every path it knows about — a crash, a folder switch, a
        // quit — but a transport that is simply dropped (a launch superseded
        // between `run()` and the handshake) must not leave a `sourcekit-lsp`
        // behind either.
        stop()
    }

    // MARK: - Reading

    private func startReading() {
        // `weak self` is load-bearing twice over. A `FileHandle` retains its
        // readability handler, and the handle is retained by the pipe, which is
        // retained by `self` — a strong capture is a cycle, so `deinit` would
        // never run and the process it kills would never be killed. It also means
        // a transport nobody references stops reading, which is the same contract
        // `LSPSession`'s read task already states about its own owner.
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            guard !chunk.isEmpty else {
                // EOF: the server closed stdout — it exited, crashed, or was
                // killed. All three mean the same thing to the session.
                handle.readabilityHandler = nil
                self.finishStream()
                return
            }
            self.yield(chunk)
        }

        // stderr is drained and discarded. Draining is not optional: a server that
        // logs steadily would otherwise fill the pipe buffer and block *writing a
        // log line*, wedging the whole server behind an output nobody reads. What
        // it says is another matter — nothing on this path is ever shown to the
        // user (D7), and a language server's stderr is its own diagnostics, not a
        // message about this project. No `self` is captured, so this handler
        // keeps nothing alive.
        errors.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }

        // The backstop for an EOF that never comes: a server whose child inherited
        // stdout keeps the write end open after the server itself is gone, and the
        // stream would then simply go quiet — leaving `LSPWorkspace` unable to
        // notice the crash, and every request falling back until the folder is
        // closed. Reaping is the reliable signal, so it ends the stream too.
        //
        // The race this trades for is theoretical: it can only drop bytes a server
        // wrote immediately before exiting, and the one response the client ever
        // waits for at shutdown (`shutdown` itself) is answered while the process
        // is still alive.
        process.terminationHandler = { [weak self] _ in
            self?.finishStream()
        }
    }

    private func yield(_ chunk: Data) {
        lock.lock()
        let finished = streamIsFinished
        lock.unlock()
        guard !finished else { return }
        continuation.yield(chunk)
    }

    private func finishStream() {
        lock.lock()
        let alreadyFinished = streamIsFinished
        streamIsFinished = true
        lock.unlock()
        guard !alreadyFinished else { return }
        continuation.finish()
    }

    // MARK: - LSPTransport

    /// Hand one framed message to the server.
    ///
    /// Returns as soon as the bytes are queued, per `LSPTransport`'s contract:
    /// waiting here would put the session's actor behind a pipe that a busy server
    /// has not drained, and a `didChange` carrying a large file is bigger than a
    /// pipe buffer. The queue is serial, so order is preserved.
    ///
    /// A write that fails afterwards (`EPIPE`, the server died between this call
    /// and the flush) cannot be reported to this caller — so it is treated as what
    /// it is, a death: the stream is finished, which is the one thing the session
    /// already knows how to handle. `notRunning` is thrown only for a send after
    /// the transport has already stopped.
    func send(_ data: Data) throws {
        lock.lock()
        let stopped = isStopped
        lock.unlock()
        guard !stopped else { throw LSPTransportError.notRunning }

        let handle = input.fileHandleForWriting
        writeQueue.async { [weak self] in
            do {
                try handle.write(contentsOf: data)
            } catch {
                self?.finishStream()
            }
        }
    }

    func terminate() {
        stop()
    }

    /// Idempotent teardown: stop reading, close the write end, `SIGTERM`, and
    /// escalate to `SIGKILL` if the server has not gone after the grace period.
    private func stop() {
        lock.lock()
        let alreadyStopped = isStopped
        isStopped = true
        lock.unlock()

        // The stream is finished even on a repeat call: a read task that is still
        // waiting on it is exactly what a second `terminate()` is trying to
        // unblock.
        finishStream()
        guard !alreadyStopped else { return }

        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        // Closing stdin gives a server that reads to EOF a chance to exit on its
        // own before the signal arrives — sourcekit-lsp does exactly that.
        //
        // On the write queue, not here: `send` only *queues* a write, and
        // `LSPSession.shutdown()` queues the `exit` notification and then calls
        // `terminate()` in the same turn. Closing the descriptor from this thread
        // would race that write and usually win, so the notification that lets a
        // server end with status 0 would be dropped on the ordinary quit path —
        // the one thing the serial write queue exists to make impossible. The
        // signals below are unaffected: they are sent regardless, immediately.
        let stdin = input.fileHandleForWriting
        writeQueue.async { try? stdin.close() }

        guard process.isRunning else { return }
        process.terminate()

        let process = self.process
        let pid = process.processIdentifier
        LSPProcessTransport.reapQueue.async {
            let deadline = Date().addingTimeInterval(LSPProcessTransport.terminationGrace)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            // `pid > 0` guards the one genuinely dangerous mistake here: `kill(0,
            // …)` signals the entire process group, i.e. Pisaka itself. A process
            // that never launched reports 0, and this is the check
            // `TerminalSession.terminate()` makes for the same reason.
            if process.isRunning, pid > 0 {
                kill(pid, SIGKILL)
            }
            process.waitUntilExit()
        }
    }

    // MARK: - The factory

    /// Resolve `description` on this machine and start it, rooted at `root`.
    ///
    /// This is the whole of what `LSPWorkspace.transportFactory` is handed (task
    /// 9): the workspace decides *whether* to launch, this decides *what* that
    /// means here. A description whose executable cannot be found throws rather
    /// than returning `nil`, because the workspace already treats a throwing
    /// factory exactly like a crash — one spent restart, then silence — and a
    /// machine with no Xcode must not retry a process launch once per keystroke.
    static func make(for description: LSPServerDescription, root: URL) throws -> LSPProcessTransport {
        guard let path = LSPToolchain.executablePath(for: description.launch) else {
            throw LSPTransportError.launchFailed("\(description.id): not found on this machine")
        }
        return try LSPProcessTransport(
            executable: URL(fileURLWithPath: path),
            arguments: description.arguments,
            directory: root
        )
    }
}

#endif
