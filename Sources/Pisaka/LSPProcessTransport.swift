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

    /// stderr and the exit status (D44), for `LSPWorkspace`'s failure record —
    /// pulled out of `errorDrain`, which owns both and outlives this transport
    /// until it has them.
    let errorOutput: AsyncStream<LSPErrorOutputEvent>
    private let errorDrain: ErrorDrain

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

        process = Process()
        input = Pipe()
        output = Pipe()
        errors = Pipe()
        writeQueue = DispatchQueue(label: "LSPProcessTransport.write")
        let drain = ErrorDrain(
            handle: errors.fileHandleForReading,
            process: process,
            grace: terminationGrace
        )
        errorDrain = drain
        errorOutput = AsyncStream { await drain.next() }

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
            errorDrain.abandon()
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
        // stderr is left to `errorDrain`, which holds what it reads from until
        // the process has exited and stderr has ended — a launch whose handshake
        // failed is dropped here the moment it gives up, often before the last
        // lines and the exit status D44 keeps have arrived.
        stop()
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
        // an alert (D7). The handler holds `errorDrain`, never `self`: the drain
        // references neither the transport nor the pipe's write end, so there is
        // no cycle through `self`, and reading goes on past this transport's
        // release until the drain says it is done.
        let drain = errorDrain
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                drain.readingDidEnd()
                return
            }
            drain.append(chunk)
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
            drain.processDidExit(code: process.terminationReason == .uncaughtSignal ? -status : status)
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
        // still sit unread in the stderr pipe. `errorDrain` reads on to EOF, and
        // stops on its own grace after the exit for a grandchild that holds the
        // pipe open.
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

/// The stderr side of one transport (D44): what the server wrote, and how its
/// process ended, held until `LSPWorkspace` pulls them through `errorOutput`.
///
/// **Its own object, so it outlives the transport.** A launch whose handshake
/// fails is dropped the moment it gives up — which is exactly when its last
/// lines and its exit status are still on their way — so the drain is held by
/// the stderr handler and the termination handler instead, and itself holds the
/// read handle and the `Process` until each has delivered its half. Those two
/// cycles are the point: each is broken by the event it waits for.
///
/// **Bounded by bytes, with the exit status beside the bytes rather than among
/// them.** What the consumer has not pulled yet is coalesced into one buffer
/// that keeps the newest `LSPServerFailureRecord.capacity` bytes — the record's
/// own bound, so a burst the main actor is slow to read loses nothing the
/// record would have kept — and the exit status sits in a slot no amount of
/// logging can evict.
///
/// Finished once stderr has reached EOF and the exit status is in, or `grace`
/// after the exit when a grandchild that inherited stderr holds it open past
/// the server's own end — whose output is not the server's to record.
private final class ErrorDrain: @unchecked Sendable {
    private let lock = NSLock()
    private let grace: TimeInterval
    private var handle: FileHandle?
    private var process: Process?
    private var pending = Data()
    private var exitCode: Int32?
    private var exitDelivered = false
    private var readingEnded = false
    private var finished = false
    /// The consumer's pull, parked until there is something to hand it. One
    /// consumer only, like `errorOutput` itself.
    private var waiter: CheckedContinuation<LSPErrorOutputEvent?, Never>?

    init(handle: FileHandle, process: Process, grace: TimeInterval) {
        self.handle = handle
        self.process = process
        self.grace = grace
    }

    /// The next event, or `nil` once finished and empty — `errorOutput`'s
    /// unfolding.
    func next() async -> LSPErrorOutputEvent? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let event = takeLocked() {
                lock.unlock()
                continuation.resume(returning: event)
            } else if finished {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func append(_ chunk: Data) {
        update {
            pending.append(chunk)
            let overflow = pending.count - LSPServerFailureRecord.capacity
            if overflow > 0 { pending = Data(pending.dropFirst(overflow)) }
        }
    }

    func readingDidEnd() {
        update {
            readingEnded = true
            handle = nil
            if exitCode != nil { finished = true }
        }
    }

    func processDidExit(code: Int32) {
        var waitsForReading = false
        update {
            exitCode = code
            process = nil
            if readingEnded { finished = true }
            waitsForReading = !finished
        }
        guard waitsForReading else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            update {
                handle?.readabilityHandler = nil
                handle = nil
                finished = true
            }
        }
    }

    /// The process never ran: nothing will ever arrive.
    func abandon() {
        update {
            handle = nil
            process = nil
            finished = true
        }
    }

    /// Apply `change` under the lock, then hand the parked consumer whatever it
    /// can now have — resumed outside the lock.
    private func update(_ change: () -> Void) {
        lock.lock()
        change()
        var resume: (CheckedContinuation<LSPErrorOutputEvent?, Never>, LSPErrorOutputEvent?)?
        if let waiter {
            if let event = takeLocked() {
                resume = (waiter, event)
            } else if finished {
                resume = (waiter, nil)
            }
            if resume != nil { self.waiter = nil }
        }
        lock.unlock()
        if let resume { resume.0.resume(returning: resume.1) }
    }

    /// The bytes before the exit status, so a crash's last lines precede the
    /// code they explain.
    private func takeLocked() -> LSPErrorOutputEvent? {
        if !pending.isEmpty {
            defer { pending = Data() }
            return .bytes(pending)
        }
        if let exitCode, !exitDelivered {
            exitDelivered = true
            return .exited(code: exitCode)
        }
        return nil
    }
}

#endif
