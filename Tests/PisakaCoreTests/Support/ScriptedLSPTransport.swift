import Foundation
@testable import PisakaCore

/// A deterministic `LSPTransport` that never spawns a process.
///
/// The fake server the whole LSP suite talks to: it decodes what the client
/// wrote, records it, and reacts according to a script written per method. That
/// makes every case the session has to survive — a slow answer, a dropped one, a
/// reply out of order, a stream that just stops, bytes that are not LSP at all —
/// an ordinary, fast unit test instead of something that needs Xcode installed.
///
/// `@unchecked Sendable` over an `NSLock`: the session writes from its actor, the
/// scripted delays fire on detached tasks, and the tests read the recording from
/// the main thread. The lock is never held across the stream yield's continuation
/// callback, so there is nothing to deadlock against.
final class ScriptedLSPTransport: LSPTransport, @unchecked Sendable {
    /// What this fake server does when it receives a request for some method.
    struct Step: Sendable {
        enum Action: Sendable {
            /// Answer with this `result` (`nil` writes no `result` member at all).
            case reply(JSONValue?)
            /// Answer with a JSON-RPC error.
            case fail(LSPResponseError)
            /// Receive it and never answer — how a timeout is staged.
            case drop
            /// End the byte stream instead of answering: a crash, mid-flight.
            case close
            /// Write these exact bytes back. Malformed framing, a response to an
            /// id nobody is waiting for — anything the typed cases cannot spell.
            case raw(Data)
        }

        var action: Action
        /// Applied before the action, so a test can order two replies against
        /// each other without depending on scheduler luck.
        var delay: TimeInterval = 0

        static func reply(_ result: JSONValue?, after delay: TimeInterval = 0) -> Step {
            Step(action: .reply(result), delay: delay)
        }

        static func fail(_ error: LSPResponseError, after delay: TimeInterval = 0) -> Step {
            Step(action: .fail(error), delay: delay)
        }

        static let drop = Step(action: .drop)

        static func close(after delay: TimeInterval = 0) -> Step {
            Step(action: .close, delay: delay)
        }

        static func raw(_ data: Data, after delay: TimeInterval = 0) -> Step {
            Step(action: .raw(data), delay: delay)
        }
    }

    let incomingBytes: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    /// The stderr side (D44), driven by the test through `writeError(_:)` and
    /// `reportExit(code:)` — nothing here writes to it on its own.
    let errorOutput: AsyncStream<LSPErrorOutputEvent>
    private let errorContinuation: AsyncStream<LSPErrorOutputEvent>.Continuation

    private let lock = NSLock()
    private var scripts: [String: [Step]] = [:]
    /// Called from `send`, synchronously, on whatever thread the session writes
    /// from — which is never the main one.
    ///
    /// The seam an *interleaving* is staged through, and the only thing that can
    /// stage one deterministically: blocking in here holds the writer inside its
    /// notification while the main actor is free to run something else, which is
    /// exactly the window `LSPWorkspace.flush` claims a document against. `Gate`'s
    /// principle, applied one layer down.
    private var onSend: (@Sendable (String) -> Void)?
    private var received: [LSPIncomingMessage] = []
    private var framing = LSPFraming.Decoder()
    private var streamIsFinished = false
    private var terminated = false
    private var inputClosed = false
    /// Set when `terminate()` landed while the byte stream was still open — the
    /// "signalled before it left" fact D43's ordering is asserted on.
    private var terminatedWithStreamOpen = false
    private var writeError: LSPTransportError?
    /// Whether the fake leaves when it is told to (D43). `true` by default — a
    /// well-behaved server ends its stream on `exit`, so a shutdown in any test
    /// that is about something else costs no grace. `false` stages the server
    /// that ignores both `exit` and a closed stdin.
    private var leavesOnExit = true

    init() {
        var escaped: AsyncStream<Data>.Continuation!
        incomingBytes = AsyncStream { escaped = $0 }
        continuation = escaped
        var escapedErrors: AsyncStream<LSPErrorOutputEvent>.Continuation!
        errorOutput = AsyncStream { escapedErrors = $0 }
        errorContinuation = escapedErrors
    }

    // MARK: - stderr (D44)

    /// Write `text` to the fake server's stderr.
    func writeError(_ text: String) {
        errorContinuation.yield(.bytes(Data(text.utf8)))
    }

    func writeError(_ bytes: Data) {
        errorContinuation.yield(.bytes(bytes))
    }

    /// Report the process's exit status and finish the stderr side.
    func reportExit(code: Int32) {
        errorContinuation.yield(.exited(code: code))
        errorContinuation.finish()
    }

    // MARK: - Scripting

    /// Queue the reactions to `method`, consumed in order. **The last step
    /// repeats**, so scripting one reply covers a method asked twice — which is
    /// what most tests want, and what makes an unscripted extra request obvious
    /// (it gets no answer at all).
    func script(_ method: String, _ steps: [Step]) {
        lock.lock()
        scripts[method] = steps
        lock.unlock()
    }

    func script(_ method: String, _ step: Step) {
        script(method, [step])
    }

    /// Install the write hook — see `onSend`.
    func onSend(_ hook: (@Sendable (String) -> Void)?) {
        lock.lock()
        onSend = hook
        lock.unlock()
    }

    /// Stage a server that ignores `exit` and stdin EOF — see `leavesOnExit`.
    func ignoreExit() {
        lock.lock()
        leavesOnExit = false
        lock.unlock()
    }

    /// The hook for staging a pipe that went away without an EOF.
    /// When set, `send` throws this error while `incomingBytes` stays open. This is deliberately
    /// different from `terminate()`, which closes the stream and therefore reintroduces the race
    /// between the stream consumer noticing the EOF and a concurrent request noticing the write failure.
    func failWrites(with error: LSPTransportError?) {
        lock.lock()
        writeError = error
        lock.unlock()
    }

    /// The stock `initialize` answer: a server that does definitions, hovers,
    /// references, renames, folding ranges, completions with `.` as a trigger,
    /// and `completionItem/resolve`.
    static func initializeResult(
        positionEncoding: String? = "utf-16",
        definition: Bool = true,
        hover: Bool = true,
        references: Bool = true,
        rename: Bool = true,
        foldingRange: Bool = true,
        completion: Bool = true,
        resolvesCompletionItems: Bool = true
    ) -> JSONValue {
        var capabilities: [String: JSONValue] = [:]
        if let positionEncoding {
            capabilities["positionEncoding"] = .string(positionEncoding)
        }
        if definition {
            capabilities["definitionProvider"] = .bool(true)
        }
        if hover {
            capabilities["hoverProvider"] = .bool(true)
        }
        if references {
            capabilities["referencesProvider"] = .bool(true)
        }
        if rename {
            capabilities["renameProvider"] = .bool(true)
        }
        if foldingRange {
            capabilities["foldingRangeProvider"] = .bool(true)
        }
        if completion {
            capabilities["completionProvider"] = .object([
                "resolveProvider": .bool(resolvesCompletionItems),
                "triggerCharacters": .array([.string("."), .string("(")]),
            ])
        }
        return .object([
            "capabilities": .object(capabilities),
            "serverInfo": .object(["name": .string("scripted"), "version": .string("1.0")]),
        ])
    }

    // MARK: - Driving the client

    /// Push a message the client did not ask for — a server-initiated request, a
    /// notification, or a response to an id nobody is waiting on.
    func emit(_ message: LSPOutgoingMessage) {
        let framed = try! LSPFraming.encode(message)
        write(framed)
    }

    /// Make the fake server send a server-initiated notification at any moment —
    /// diagnostics, logs, progress: whatever method a test names.
    func push(method: String, params: JSONValue? = nil) {
        emit(.notification(LSPNotificationMessage(method: method, params: params)))
    }

    /// The same, after a delay — how two pushes are ordered against other
    /// traffic without depending on scheduler luck (`Step.delay`'s device, one
    /// layer up).
    func pushAfter(delay: TimeInterval, method: String, params: JSONValue? = nil) {
        let message = LSPNotificationMessage(method: method, params: params)
        Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard let self else { return }
            self.emit(.notification(message))
        }
    }

    func write(_ data: Data) {
        lock.lock()
        let finished = streamIsFinished
        lock.unlock()
        guard !finished else { return }
        continuation.yield(data)
    }

    /// EOF: the server exited, crashed, or was killed.
    func closeStream() {
        lock.lock()
        let alreadyFinished = streamIsFinished
        streamIsFinished = true
        lock.unlock()
        guard !alreadyFinished else { return }
        continuation.finish()
    }

    // MARK: - LSPTransport

    /// Deliberately carries no write budget (D39). The bound the real transport
    /// grew is about a *backlog*, and this fake decodes each message inside the
    /// call and never queues anything — there is no pipe to fill, so a ceiling
    /// here could only be crossed by a test writing 32 MiB of scripted JSON to
    /// watch an arithmetic rule `LSPWriteBudgetTests` already states directly.
    func send(_ data: Data) throws {
        lock.lock()
        if terminated || inputClosed {
            lock.unlock()
            throw LSPTransportError.notRunning
        }
        if let error = writeError {
            lock.unlock()
            throw error
        }
        let payloads: [Data]
        let messages: [LSPIncomingMessage]
        do {
            payloads = try framing.append(data)
            messages = try payloads.map { try LSPIncomingMessage.decode($0) }
        } catch {
            lock.unlock()
            throw error
        }
        received.append(contentsOf: messages)
        let hook = onSend
        lock.unlock()

        // Outside the lock, and before the reaction: a hook that blocks must hold
        // only the writer, not every reader of the recording.
        if let hook {
            for message in messages {
                switch message {
                case .serverRequest(let request): hook(request.method)
                case .notification(let notification): hook(notification.method)
                case .response: break
                }
            }
        }

        for message in messages { react(to: message) }
    }

    func closeInput() {
        lock.lock()
        inputClosed = true
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        if !terminated, !streamIsFinished { terminatedWithStreamOpen = true }
        terminated = true
        lock.unlock()
        closeStream()
    }

    // MARK: - Reacting

    private func react(to message: LSPIncomingMessage) {
        if case .notification(let notification) = message, notification.method == LSPMethod.exit {
            lock.lock()
            let leaves = leavesOnExit
            lock.unlock()
            if leaves { closeStream() }
            return
        }
        // A client request decodes as `.serverRequest` here: the case names are
        // written from the session's point of view, and this object is the peer.
        guard case .serverRequest(let request) = message else { return }
        guard let step = nextStep(for: request.method) else { return }
        perform(step, for: request)
    }

    private func nextStep(for method: String) -> Step? {
        lock.lock()
        defer { lock.unlock() }
        guard var steps = scripts[method], let step = steps.first else { return nil }
        if steps.count > 1 {
            steps.removeFirst()
            scripts[method] = steps
        }
        return step
    }

    private func perform(_ step: Step, for request: LSPRequestMessage) {
        let action = step.action
        let id = request.id
        let work: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            switch action {
            case .reply(let result):
                self.emit(.response(LSPResponseMessage(id: id, result: result)))
            case .fail(let error):
                self.emit(.response(LSPResponseMessage(id: id, error: error)))
            case .drop:
                break
            case .close:
                self.closeStream()
            case .raw(let data):
                self.write(data)
            }
        }
        guard step.delay > 0 else {
            work()
            return
        }
        Task {
            try await Task.sleep(nanoseconds: UInt64(step.delay * 1_000_000_000))
            work()
        }
    }

    // MARK: - The recording

    var receivedMessages: [LSPIncomingMessage] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    /// Every method the client sent, requests and notifications alike, in order —
    /// the sequence assertions read from.
    var sentMethods: [String] {
        receivedMessages.compactMap { message in
            switch message {
            case .serverRequest(let request): return request.method
            case .notification(let notification): return notification.method
            case .response: return nil
            }
        }
    }

    func requests(for method: String) -> [LSPRequestMessage] {
        receivedMessages.compactMap { message in
            guard case .serverRequest(let request) = message, request.method == method else {
                return nil
            }
            return request
        }
    }

    func notifications(for method: String) -> [LSPNotificationMessage] {
        receivedMessages.compactMap { message in
            guard case .notification(let notification) = message,
                  notification.method == method else { return nil }
            return notification
        }
    }

    /// The client's answers to *our* requests.
    var sentResponses: [LSPResponseMessage] {
        receivedMessages.compactMap { message in
            guard case .response(let response) = message else { return nil }
            return response
        }
    }

    var isTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminated
    }

    var isInputClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inputClosed
    }

    var wasTerminatedWithStreamOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminatedWithStreamOpen
    }
}

/// The exit-grace seam (D43) held open until the test lets it go.
///
/// `Gate`'s causal rendezvous for an `async` wait: every call is recorded the
/// moment it starts and parks on a continuation, not a blocked thread — so two
/// sessions waiting out their graces at once cost the cooperative pool nothing,
/// and "both waits started before either was released" is a fact read off
/// `started`, not a timing. `release()` resumes every wait parked so far and
/// every one that arrives later; a test must call it before it ends, or the
/// parked continuations leak.
final class GraceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var startedGraces: [TimeInterval] = []
    private var isReleased = false

    /// The seam itself, for `LSPSession(exitGraceWait:)` /
    /// `LSPWorkspace(exitGraceWait:)`.
    var wait: @Sendable (TimeInterval) async -> Void {
        { [self] grace in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                startedGraces.append(grace)
                if isReleased {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// The grace each wait was started with, in arrival order.
    var started: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return startedGraces
    }

    func release() {
        lock.lock()
        isReleased = true
        let parked = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in parked { continuation.resume() }
    }
}
