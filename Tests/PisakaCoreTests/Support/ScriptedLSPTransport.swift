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
    private var writeError: LSPTransportError?

    init() {
        var escaped: AsyncStream<Data>.Continuation!
        incomingBytes = AsyncStream { escaped = $0 }
        continuation = escaped
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
    /// completions with `.` as a trigger, and `completionItem/resolve`.
    static func initializeResult(
        positionEncoding: String? = "utf-16",
        definition: Bool = true,
        hover: Bool = true,
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

    func send(_ data: Data) throws {
        lock.lock()
        if terminated {
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

    func terminate() {
        lock.lock()
        terminated = true
        lock.unlock()
        closeStream()
    }

    // MARK: - Reacting

    private func react(to message: LSPIncomingMessage) {
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
}
