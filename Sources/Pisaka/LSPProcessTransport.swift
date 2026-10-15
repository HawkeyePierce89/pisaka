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
    /// same promise about a shell. An init parameter (default 2 s) only so the
    /// app-layer shutdown test can watch both halves of the escalation without
    /// waiting out the real one.
    private let terminationGrace: TimeInterval

    let incomingBytes: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    /// stderr chunks and the exit status (D44), for `LSPWorkspace`'s failure
    /// record. Bounded to the newest chunks: unlike stdout, losing an old log
    /// line costs nothing — the record keeps only a tail anyway — and a server
    /// logging faster than the main actor reads must not grow this without end.
    let errorOutput: AsyncStream<LSPErrorOutputEvent>
    private let errorContinuation: AsyncStream<LSPErrorOutputEvent>.Continuation

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
    private var isInputClosed = false
    private var streamIsFinished = false
    /// The two halves `errorOutput` finishes after: stderr reached EOF, and the
    /// exit status was reported. Both, so a crash's
    /// last lines — readable a moment after the process is reaped — still land
    /// before the stream ends.
    private var errorReadingEnded = false
    private var exitReported = false

    /// What is queued but not yet written, bounded (D39). Guarded by `lock`, like
    /// every other piece of state here: `send` admits from the session's actor and
    /// the write queue drains from its own thread.
    private var writeBudget = LSPWriteBudget()

    /// Launch `executable` with `arguments`, rooted at `directory`.
    ///
    /// Throws `LSPTransportError.launchFailed` and nothing else: every way this
    /// can fail — a path that is not there, a binary the sandbox refuses, a
    /// toolchain that was deleted between the `xcrun` lookup and now — is the same
    /// answer to `LSPWorkspace`, which spends one restart on it and falls back
    /// silently in the meantime.
    init(
        executable: URL,
        arguments: [String],
        directory: URL,
        environment: [String: String] = [:],
        terminationGrace: TimeInterval = 2
    ) throws {
        self.terminationGrace = terminationGrace
        var escaped: AsyncStream<Data>.Continuation!
        // Unbounded on purpose. Every element is a piece of the message stream and
        // dropping one desyncs `LSPFraming.Decoder` for good; the bound that
        // actually matters is `Content-Length`'s cap, which Core already enforces.
        incomingBytes = AsyncStream(bufferingPolicy: .unbounded) { escaped = $0 }
        continuation = escaped
        var escapedErrors: AsyncStream<LSPErrorOutputEvent>.Continuation!
        errorOutput = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { escapedErrors = $0 }
        errorContinuation = escapedErrors

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
        // The environment is inherited wholesale and never *replaced*: a language
        // server resolves its toolchain, its caches and its build system out of
        // `PATH`/`HOME`/`DEVELOPER_DIR`, and assigning the environment to add one
        // variable would take all of that away (`GitCLIService.run`'s reasoning,
        // one level down). A description that names variables therefore gets them
        // merged *over* the inherited set and nothing else is touched — and a
        // description that names none (every server but gopls) leaves
        // `process.environment` unassigned exactly as before, so the inheritance
        // is the real one rather than a copy this process took of it.
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, overlay in overlay }
        }

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
            errorContinuation.finish()
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
        // A grandchild that inherited stderr can hold it open past the server's
        // own exit; the record's reader must not outlive the transport for it.
        errors.fileHandleForReading.readabilityHandler = nil
        errorContinuation.finish()
    }

    /// The server's pid — read by the app-layer shutdown test, which has to see
    /// the process itself go away rather than take the stream's word for it.
    var processIdentifier: Int32 { process.processIdentifier }

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

        // stderr is always drained. Draining is not optional: a server that logs
        // steadily would otherwise fill the pipe buffer and block *writing a log
        // line*, wedging the whole server behind an output nobody reads. What it
        // says is handed to `errorOutput` and nowhere else — the workspace keeps a
        // bounded tail for the settings row (D44), and nothing on this path is ever
        // an alert (D7). `weak self` for the stdout handler's reason.
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                self.endErrorOutput(exitCode: nil)
                return
            }
            self.errorContinuation.yield(.bytes(chunk))
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
        process.terminationHandler = { [weak self] process in
            self?.finishStream()
            // A signal is reported negated, so one integer carries both endings
            // (`LSPServerFailureRecord.lastExitCode`).
            let status = process.terminationStatus
            self?.endErrorOutput(exitCode: process.terminationReason == .uncaughtSignal ? -status : status)
        }
    }

    /// Record one of `errorOutput`'s two endings — the exit status when
    /// `exitCode` is given, stderr's end otherwise — and finish the stream once
    /// both have happened.
    private func endErrorOutput(exitCode: Int32?) {
        lock.lock()
        if exitCode == nil { errorReadingEnded = true } else { exitReported = true }
        let done = errorReadingEnded && exitReported
        lock.unlock()
        if let exitCode { errorContinuation.yield(.exited(code: exitCode)) }
        if done { errorContinuation.finish() }
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
    ///
    /// **The queue is bounded** (D39). A server that is alive but no longer
    /// reading its stdin never fails a write, so without a bound the backlog grows
    /// by one whole document per `didChange` and nothing in the layer ever
    /// notices — a request timeout fails one request, and `didChange` has no reply
    /// to time out at all. `LSPWriteBudget` therefore admits every message before
    /// it is queued: nothing pending is always accepted, however large (one big
    /// document is not a dead server), and a backlog that would cross
    /// `LSPWriteBudget.defaultCeiling` — 32 MiB — is read as the server's death.
    /// That is the *same* call the failed write above already makes: nothing is
    /// queued, the stream is finished, no error is thrown and no new failure
    /// channel exists, so `LSPWorkspace` owns everything after it exactly as it
    /// owns a crash (D7's backoff, the diagnostics clear, the fourth-failure
    /// retirement).
    func send(_ data: Data) throws {
        lock.lock()
        if isStopped || isInputClosed {
            lock.unlock()
            throw LSPTransportError.notRunning
        }
        let admission = writeBudget.admit(data.count)
        lock.unlock()

        guard admission == .queued else {
            finishStream()
            return
        }

        let handle = input.fileHandleForWriting
        writeQueue.async { [weak self] in
            do {
                try handle.write(contentsOf: data)
            } catch {
                self?.finishStream()
            }
            // On both paths: the bytes are off the queue either way, and a
            // transport that stopped counting on a failure would refuse the next
            // send of a server that is merely being torn down.
            guard let self else { return }
            self.lock.lock()
            self.writeBudget.drain(data.count)
            self.lock.unlock()
        }
    }

    /// Close stdin so a server that reads to EOF can leave on its own (D43).
    ///
    /// On the write queue, behind every write already handed to `send` — the
    /// `exit` the session queued just before this call above all. Closing the
    /// descriptor from this thread would race that write and usually win.
    func closeInput() {
        lock.lock()
        let alreadyClosed = isInputClosed
        isInputClosed = true
        lock.unlock()
        guard !alreadyClosed else { return }
        let stdin = input.fileHandleForWriting
        writeQueue.async { try? stdin.close() }
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
        // stderr is deliberately *not* detached: a crash ends stdout, and this
        // runs from the session's reaction to that, while the server's last
        // lines — the panic, the missing toolchain, exactly what D44 keeps — may
        // still sit unread in the stderr pipe. Its handler reads on to EOF and
        // ends that half of `errorOutput` itself; `deinit` is the backstop for a
        // grandchild that holds the pipe open.
        // Stdin is closed here too, for the paths that never said goodbye (a
        // crash, a superseded launch, `terminateNow()`); the polite path has
        // already closed it through `closeInput()` and given the server its exit
        // grace (D43), so this is then a no-op. On the write queue for
        // `closeInput()`'s reason. The signals below are unaffected: they are
        // sent regardless, immediately.
        closeInput()

        guard process.isRunning else { return }
        process.terminate()

        let process = self.process
        let pid = process.processIdentifier
        let grace = terminationGrace
        LSPProcessTransport.reapQueue.async {
            let deadline = Date().addingTimeInterval(grace)
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
    ///
    /// **Called on the main actor, so it never waits for the lookup.** A toolchain
    /// tool nobody has resolved yet answers `.pending` and this throws `notReady`,
    /// which costs no restart budget: the request behind it falls back to
    /// tree-sitter for the moment it takes the background `xcrun` to answer, rather
    /// than the main thread stalling on one inside the launch turn. In practice the
    /// startup `prewarm()` means this is only ever reached by a request that beat
    /// it.
    static func make(for description: LSPServerDescription, root: URL) throws -> LSPProcessTransport {
        let path: String
        switch LSPToolchain.resolution(for: description.launch) {
        case .found(let resolved):
            path = resolved
        case .missing:
            throw LSPTransportError.launchFailed("\(description.id): not found on this machine")
        case .pending:
            throw LSPTransportError.notReady
        }
        return try LSPProcessTransport(
            executable: URL(fileURLWithPath: path),
            arguments: description.arguments,
            directory: root,
            environment: description.environment
        )
    }
}

#endif
