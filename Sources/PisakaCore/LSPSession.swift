import Foundation

/// A notification the *server* initiated, lifted out of its envelope (D29).
///
/// The value the session's `notifications` stream carries: the method name and
/// the params exactly as they arrived, with nothing session-shaped attached.
/// What a method means — diagnostics to route, logs to drop — is entirely the
/// consumer's business; this layer guarantees only wire order and delivery.
public struct LSPServerNotification: Equatable, Hashable, Sendable {
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue? = nil) {
        self.method = method
        self.params = params
    }
}

/// One live conversation with one language server.
///
/// Above `LSPFraming` (bytes) and `LSPProtocolTypes` (bodies), below
/// `LSPWorkspace` (which server, which root, when to restart): this is the
/// protocol *driver*. It owns the handshake, the id counter, the table of
/// requests waiting for an answer, and the rules for every way a conversation can
/// end. It does not know what a project is, which language a file is, or that
/// there might be a second server — one session is one process's worth of state.
///
/// An `actor` because the state it protects is touched from three directions at
/// once: caller tasks issuing requests, the read task delivering the server's
/// messages, and per-request timeout tasks firing. Serialising them is exactly
/// what an actor is for, and it keeps the pending table free of a lock.
///
/// Three rules run through the whole file.
///
/// **Every request has a deadline** (D7). A language server is a program that can
/// wedge — sourcekit-lsp resolving a build system, a server waiting on an index
/// write — and a wedged server must cost one *question*, not the editor. So a
/// request that outlives its budget fails on its own and takes nothing else with
/// it, and the caller falls back to tree-sitter without ever knowing why.
///
/// **The end is terminal.** EOF, a framing error, a failed handshake and a
/// graceful `shutdown` all land in the same place: the session goes to
/// `.terminated`, every pending request is failed exactly once, and it never
/// serves another. Restart is `LSPWorkspace`'s decision because it is the only
/// thing that can count failures; a session that resurrected itself would hide
/// the crash loop D7 exists to bound.
///
/// **The owner keeps it alive.** The read task holds the session weakly, so an
/// `LSPSession` nobody references stops reading — deliberately, because a strong
/// self would make every session immortal until its server exited, and the whole
/// D7 restart scheme depends on being able to drop one. `LSPWorkspace` is the
/// owner; anything else holding a session for the length of a conversation must
/// say so.
///
/// **We answer, never initiate policy.** A server may ask *us* things
/// (`client/registerCapability`, `workspace/configuration`). Every one gets a
/// reply — an empty one where the spec allows, `MethodNotFound` where it does not
/// — because a server left waiting on a reply to its own request will happily
/// stall the request we are waiting on. Notifications, which want no reply, get
/// none either — but since D29 they are not dropped: each one travels out on the
/// `notifications` stream for its single consumer (`LSPWorkspace`) to act on,
/// where an unrecognised one is ignored instead of here.
public actor LSPSession {
    /// How long each kind of exchange is worth waiting for (D7).
    ///
    /// A definition is a deliberate act and worth a beat; completion has already
    /// spent the editor's 150 ms debounce and must not make the popup feel stuck;
    /// the handshake is generous because sourcekit-lsp resolves the whole build
    /// system on first start.
    public struct Budgets: Equatable, Hashable, Sendable {
        public var handshake: TimeInterval
        public var definition: TimeInterval
        public var completion: TimeInterval
        /// `completionItem/resolve`, which D4 prefetches in the background while
        /// the popup is open — the same order of magnitude as the completion it
        /// belongs to.
        public var resolve: TimeInterval
        /// `textDocument/hover` (D25): completion's budget, not definition's.
        /// Nobody asked for a hover deliberately — the pointer merely stopped
        /// moving — so an answer that arrives after the pointer has moved on is
        /// worth nothing, and waiting a definition's three seconds for it only
        /// keeps a request alive past its own usefulness.
        public var hover: TimeInterval
        /// `textDocument/references` — definition's number, and for definition's
        /// reason. It is an explicit command someone typed a shortcut for, not a
        /// pointer that happened to stop moving: the answer is still wanted when
        /// it arrives late, so it is worth the deliberate act's three seconds
        /// rather than the dwell's one and a half. Expiry here is cheap —
        /// `FindUsagesModel` walks the project textually instead and says so.
        public var references: TimeInterval
        /// `textDocument/rename` — **not** `references`' number, though the two
        /// are the same act asked two ways. Three seconds is the span of a
        /// question whose expiry costs nothing: a references timeout degrades to
        /// the textual scan, and a definition's to tree-sitter. A rename has no
        /// second answer of any kind (D35), and by the time it is sent the user
        /// has already been made to fill in a modal dialog — so its expiry is not
        /// a degraded answer but a bare refusal of a command they deliberately
        /// invoked. It is also a categorically heavier question: `references`
        /// reads an index, while a workspace rename type-checks the reverse
        /// dependency graph, which on a mid-sized module is ordinarily seconds
        /// rather than milliseconds. Timing out a rename that would have
        /// succeeded is the one failure this layer cannot make invisible, so the
        /// span is the one a person waiting on a dialog will tolerate.
        public var rename: TimeInterval
        /// How long a polite `shutdown` may take before we stop being polite.
        /// Short on purpose: the process is being killed either way, and this is
        /// only the difference between a clean exit and a SIGTERM.
        public var shutdown: TimeInterval

        public init(
            handshake: TimeInterval = 20,
            definition: TimeInterval = 3,
            completion: TimeInterval = 1.5,
            resolve: TimeInterval = 1.5,
            hover: TimeInterval = 1.5,
            references: TimeInterval = 3,
            rename: TimeInterval = 20,
            shutdown: TimeInterval = 2
        ) {
            self.handshake = handshake
            self.definition = definition
            self.completion = completion
            self.resolve = resolve
            self.hover = hover
            self.references = references
            self.rename = rename
            self.shutdown = shutdown
        }

        /// D7's numbers.
        public static let standard = Budgets()
    }

    /// Where the conversation is. There is no `.restarting`: a session that ended
    /// is over, and the next one is a new `LSPSession` over a new transport.
    public enum Phase: Equatable, Sendable {
        case notStarted
        case running
        case terminated
    }

    /// The wire this session speaks over.
    ///
    /// Readable from outside — and synchronously, being an immutable `Sendable`
    /// `let` — for one reason: `LSPWorkspace` unregisters a transport only while
    /// it is still the one filed under the key (`forget(_:for:)`), and the
    /// teardown paths that hold a *session* need its transport's identity to make
    /// that check. Without it the only way to drop a finished session's entry is
    /// an unconditional clear, which is exactly how a newer launch's live process
    /// stops being reachable by `terminateNow()`.
    public let transport: LSPTransport
    public let budgets: Budgets

    /// Every server-initiated notification the peer sends, in wire order (D29).
    ///
    /// Exactly **one consumer**: `LSPWorkspace`, which attaches its iteration
    /// once the handshake has succeeded and the session is filed under its key,
    /// and keeps it for the life of the session. Attaching *after* `start` is
    /// safe — and is half of why the buffer is unbounded: the stream exists from
    /// `init`, so anything the peer says during the handshake waits for the
    /// consumer instead of being dropped. The other half is the steady state,
    /// where a burst of pushes between two hops of the consumer task must not
    /// strand anything — the whole reason this is a stream and not a callback
    /// (two pushes reordered by two independent `Task` hops would leave stale
    /// errors on screen forever).
    /// **Finishing is the signal**: `close(reason:)` — already the single
    /// terminal transition, so no second finish is reachable — finishes the
    /// stream exactly once however the conversation ended (EOF, framing error,
    /// shutdown), and D33's clearing rule reads that as "the server died — clear
    /// its diagnostics" without tearing anything down itself. This layer routes
    /// nothing: diagnostics, logs and progress all arrive here alike, and what to
    /// do with each is the consumer's decision.
    public let notifications: AsyncStream<LSPServerNotification>
    private var notificationsContinuation: AsyncStream<LSPServerNotification>.Continuation

    private var phase: Phase = .notStarted
    /// Why the session ended — handed to every request attempted afterwards, so a
    /// caller learns *that* the server is gone rather than getting a generic
    /// refusal.
    private var closureReason: LSPSessionError?
    /// Raised for the length of `shutdown()`, so the polite exchange can still
    /// use the wire while new work is refused.
    private var isShuttingDown = false

    /// JSON-RPC ids are ours to choose and only have to be unique per connection;
    /// counting up makes a transcript readable and a test able to assert the
    /// exact sequence.
    private var nextID = 1
    private var pending: [LSPRequestID: CheckedContinuation<JSONValue?, Error>] = [:]

    private var framing = LSPFraming.Decoder()
    private var readTask: Task<Void, Never>?

    /// What the server said it can do, once the handshake landed.
    public private(set) var capabilities: LSPServerCapabilities?

    /// This server's settings keyed by section, exactly as its description
    /// carried them (`LSPServerDescription.configuration`). Taken at `start` and
    /// never changed afterwards: it is pinned data, not a settings surface.
    private var configuration: JSONValue?

    public init(transport: LSPTransport, budgets: Budgets = .standard) {
        self.transport = transport
        self.budgets = budgets
        var escaped: AsyncStream<LSPServerNotification>.Continuation!
        self.notifications = AsyncStream(bufferingPolicy: .unbounded) { escaped = $0 }
        self.notificationsContinuation = escaped
    }

    // MARK: - State

    public var isRunning: Bool { phase == .running && !isShuttingDown }
    public var currentPhase: Phase { phase }

    /// Test seam: proof that a cancelled, timed-out or failed request left no
    /// entry behind. A leaked continuation is invisible until the process exits
    /// and Swift complains, so it is asserted directly.
    var pendingRequestCount: Int { pending.count }

    // MARK: - Handshake

    /// `initialize` → `initialized`, the only sequence that makes a server usable.
    ///
    /// Returns the server's capabilities so the caller can decide the server is
    /// not worth keeping (a server that cannot answer definitions, or that chose
    /// a position encoding other than the UTF-16 this codebase counts in —
    /// `LSPServerCapabilities.usesUTF16Positions`).
    ///
    /// Any failure here terminates the session *and the process*: a server that
    /// never finished initialising is not going to start, and leaving it running
    /// is exactly the orphan the post-completion check greps for.
    ///
    /// `configuration` — the description's, verbatim — is delivered on both
    /// channels a server may take settings on, because which one it reads is the
    /// server's decision and not ours: a `workspace/didChangeConfiguration`
    /// notification carrying `{settings: …}` right after `initialized`, and every
    /// `workspace/configuration` pull answered section by section out of the same
    /// value for as long as the session lives. No server-specific code exists
    /// anywhere here; the value is data on the description.
    ///
    /// With no configuration nothing changes for the five servers that ship
    /// without one: the notification is not sent, and a pull is still answered
    /// `null` per item. The client capability `workspace.configuration` stays
    /// `false` for the same reason — a server that pulls does so regardless, and
    /// advertising `true` would rewrite the handshake for all of them for no
    /// gain.
    @discardableResult
    public func start(
        processID: Int?,
        rootURI: String?,
        rootPath: String? = nil,
        clientInfo: LSPClientInfo? = LSPClientInfo(name: "Pisaka", version: PisakaCore.version),
        initializationOptions: JSONValue? = nil,
        configuration: JSONValue? = nil
    ) async throws -> LSPServerCapabilities {
        guard phase == .notStarted else { throw closureReason ?? .notRunning }
        phase = .running
        self.configuration = configuration

        // Taken exactly once, before anything is written: a reply to `initialize`
        // can arrive before `send` returns on a fast server.
        let stream = transport.incomingBytes
        readTask = Task { [weak self] in
            for await chunk in stream {
                guard let self else { return }
                await self.ingest(chunk)
            }
            await self?.handleStreamEnd()
        }

        do {
            let params = LSPInitializeParams(
                processId: processID,
                clientInfo: clientInfo,
                rootUri: rootURI,
                rootPath: rootPath,
                initializationOptions: initializationOptions
            )
            let result = try await perform(
                LSPMethod.initialize,
                params: try JSONValue(encoding: params),
                timeout: budgets.handshake
            )
            guard let result,
                  let initialized = try? result.decoded(as: LSPInitializeResult.self) else {
                throw LSPSessionError.handshakeRejected("`initialize` did not answer an InitializeResult")
            }
            capabilities = initialized.capabilities
            // The spec forbids sending anything else before this; the request
            // methods below are only reachable once `start` has returned.
            try send(.notification(LSPNotificationMessage(
                method: LSPMethod.initialized,
                params: .object([:])
            )))
            // Push, for the servers that read the payload — and only when there
            // is something to push, so a server with no configuration sees the
            // handshake it saw before this existed.
            if let configuration {
                try send(.notification(LSPNotificationMessage(
                    method: LSPMethod.didChangeConfiguration,
                    params: .object(["settings": configuration])
                )))
            }
            return initialized.capabilities
        } catch {
            close(reason: (error as? LSPSessionError) ?? .handshakeRejected("\(error)"))
            throw error
        }
    }

    // MARK: - Requests

    /// Send a request and wait for its answer, or for `timeout` to run out.
    ///
    /// Throws `LSPResponseError` when the server refused, `LSPSessionError` when
    /// the conversation did, and `CancellationError` when the caller's task was
    /// cancelled — in which case a `$/cancelRequest` has already gone out, so the
    /// server can stop working on an answer nobody will read.
    public func request(
        _ method: String,
        params: JSONValue? = nil,
        timeout: TimeInterval
    ) async throws -> JSONValue? {
        guard !isShuttingDown else { throw closureReason ?? .notRunning }
        return try await perform(method, params: params, timeout: timeout)
    }

    /// Send a notification. Nothing comes back and nothing is awaited — a
    /// notification that cannot be written means the server is gone, which the
    /// next request will discover.
    public func notify(_ method: String, params: JSONValue? = nil) throws {
        guard phase == .running else { throw closureReason ?? .notRunning }
        try send(.notification(LSPNotificationMessage(method: method, params: params)))
    }

    private func perform(
        _ method: String,
        params: JSONValue?,
        timeout: TimeInterval
    ) async throws -> JSONValue? {
        try Task.checkCancellation()
        guard phase == .running else { throw closureReason ?? .notRunning }

        let id = LSPRequestID.number(nextID)
        nextID += 1
        try send(.request(LSPRequestMessage(id: id, method: method, params: params)))

        // Started *after* the write, so the budget covers the server's thinking
        // and not our own encoding.
        let deadline = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            } catch {
                return  // the request answered first and cancelled us
            }
            await self?.expire(id, method: method)
        }
        defer { deadline.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue?, Error>) in
                // Registered synchronously, before any suspension: the
                // cancellation handler below can only reach the actor afterwards,
                // so a cancel that fires immediately still finds the entry.
                pending[id] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// The budget ran out. The request fails alone — nothing else in the pending
    /// table is touched, because one slow answer is not evidence the server is
    /// broken — and the server is told to stop, since we will not read the reply.
    private func expire(_ id: LSPRequestID, method: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        sendCancelRequest(id)
        continuation.resume(throwing: LSPSessionError.timedOut(method: method))
    }

    /// The caller's task was cancelled (a second ⌘-click, a new keystroke
    /// superseding the completion behind it).
    private func cancel(_ id: LSPRequestID) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        sendCancelRequest(id)
        continuation.resume(throwing: CancellationError())
    }

    private func sendCancelRequest(_ id: LSPRequestID) {
        guard phase == .running else { return }
        let params = try? JSONValue(encoding: LSPCancelParams(id: id))
        try? send(.notification(LSPNotificationMessage(
            method: LSPMethod.cancelRequest,
            params: params
        )))
    }

    // MARK: - Typed exchanges

    public func didOpen(_ params: LSPDidOpenTextDocumentParams) throws {
        try notify(LSPMethod.didOpen, params: try JSONValue(encoding: params))
    }

    public func didChange(_ params: LSPDidChangeTextDocumentParams) throws {
        try notify(LSPMethod.didChange, params: try JSONValue(encoding: params))
    }

    public func didClose(_ params: LSPDidCloseTextDocumentParams) throws {
        try notify(LSPMethod.didClose, params: try JSONValue(encoding: params))
    }

    public func definition(
        _ params: LSPTextDocumentPositionParams
    ) async throws -> LSPDefinitionResponse {
        let result = try await request(
            LSPMethod.definition,
            params: try JSONValue(encoding: params),
            timeout: budgets.definition
        )
        return try decode(result, as: LSPDefinitionResponse.self, method: LSPMethod.definition)
    }

    /// The same position question as `definition`, on its own budget (D25).
    ///
    /// Whether the server was worth asking at all — `capabilities.supportsHover`
    /// — is the caller's check, not this one's: a session answers what it is
    /// asked, and the provider is the layer that knows not to ask.
    public func hover(
        _ params: LSPTextDocumentPositionParams
    ) async throws -> LSPHoverResponse {
        let result = try await request(
            LSPMethod.hover,
            params: try JSONValue(encoding: params),
            timeout: budgets.hover
        )
        return try decode(result, as: LSPHoverResponse.self, method: LSPMethod.hover)
    }

    /// Every reference to the symbol at the position, declaration included.
    ///
    /// Whether the server advertised `referencesProvider` is the caller's check,
    /// exactly as it is for `hover`: a session answers what it is asked.
    public func references(
        _ params: LSPReferenceParams
    ) async throws -> LSPReferencesResponse {
        let result = try await request(
            LSPMethod.references,
            params: try JSONValue(encoding: params),
            timeout: budgets.references
        )
        return try decode(result, as: LSPReferencesResponse.self, method: LSPMethod.references)
    }

    /// The whole-workspace edit that renames the symbol at the position.
    ///
    /// Nothing is written here — this is a read like every other exchange in this
    /// actor, and what to do with the answer (verify it, then apply it or abort)
    /// belongs to the layer that owns the writer gate.
    public func rename(_ params: LSPRenameParams) async throws -> LSPWorkspaceEdit {
        let result = try await request(
            LSPMethod.rename,
            params: try JSONValue(encoding: params),
            timeout: budgets.rename
        )
        return try decode(result, as: LSPWorkspaceEdit.self, method: LSPMethod.rename)
    }

    public func completion(
        _ params: LSPCompletionParams
    ) async throws -> LSPCompletionResponse {
        let result = try await request(
            LSPMethod.completion,
            params: try JSONValue(encoding: params),
            timeout: budgets.completion
        )
        return try decode(result, as: LSPCompletionResponse.self, method: LSPMethod.completion)
    }

    /// The item is echoed back *verbatim* — including its opaque `data`, which is
    /// how the server correlates the resolve with the list it produced.
    public func resolveCompletionItem(
        _ item: LSPCompletionItem
    ) async throws -> LSPCompletionItem {
        let result = try await request(
            LSPMethod.resolveCompletionItem,
            params: try JSONValue(encoding: item),
            timeout: budgets.resolve
        )
        return try decode(
            result,
            as: LSPCompletionItem.self,
            method: LSPMethod.resolveCompletionItem
        )
    }

    /// A missing `result` member and an explicit `null` are the same answer to
    /// every method this phase sends (both mean "nothing found"), so they are
    /// folded together here rather than at every call site.
    private func decode<T: Decodable>(
        _ result: JSONValue?,
        as type: T.Type,
        method: String
    ) throws -> T {
        do {
            return try (result ?? .null).decoded(as: T.self)
        } catch {
            throw LSPSessionError.malformedResponse(method: method)
        }
    }

    // MARK: - Shutting down

    /// The polite exit: `shutdown`, then `exit`, then kill the process anyway.
    ///
    /// Ordered, not optional. A server is entitled to flush state on `shutdown`,
    /// and `exit` is what lets it end with status 0; `transport.terminate()`
    /// afterwards is the guarantee — not the request — that nothing outlives the
    /// app, which is the difference between this and hoping a well-behaved server
    /// exits on its own.
    ///
    /// Never throws: every caller is a lifecycle path (folder switch, app
    /// termination) with nothing useful to do about a server that will not say
    /// goodbye.
    public func shutdown() async {
        guard phase == .running, !isShuttingDown else {
            close(reason: .notRunning)
            return
        }
        isShuttingDown = true
        _ = try? await perform(LSPMethod.shutdown, params: nil, timeout: budgets.shutdown)
        try? send(.notification(LSPNotificationMessage(method: LSPMethod.exit)))
        close(reason: .notRunning)
    }

    /// Stop now, without the handshake — the crash path and the "we gave up" path.
    public func terminate() {
        close(reason: .connectionClosed)
    }

    /// The single terminal transition. Idempotent: EOF, a framing error and an
    /// explicit shutdown all arrive here, sometimes two of them for the same
    /// ending, and the pending table must be failed exactly once.
    private func close(reason: LSPSessionError) {
        guard phase != .terminated else { return }
        phase = .terminated
        closureReason = reason
        isShuttingDown = false

        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: reason) }

        readTask?.cancel()
        readTask = nil
        transport.terminate()
        // The consumer's crash/exit signal (D33). Unreachable twice: `close` is
        // guarded by the phase above, so the stream finishes exactly once.
        notificationsContinuation.finish()
    }

    // MARK: - Reading

    /// One chunk off the wire, however much of a message it happens to be.
    private func ingest(_ chunk: Data) {
        guard phase != .terminated else { return }
        let payloads: [Data]
        do {
            payloads = try framing.append(chunk)
        } catch let error as LSPFramingError {
            // Unrecoverable by construction (see `LSPFraming`): there is no way
            // to find where the next message starts, so the conversation is over.
            close(reason: .framing(error))
            return
        } catch {
            close(reason: .connectionClosed)
            return
        }
        for payload in payloads {
            // A payload that is framed correctly but is not a JSON-RPC message is
            // dropped, not fatal: the stream is still in sync, so exactly one
            // message is lost. That is the opposite trade from a framing error,
            // and for the opposite reason.
            guard let message = try? LSPIncomingMessage.decode(payload) else { continue }
            handle(message)
        }
    }

    private func handle(_ message: LSPIncomingMessage) {
        switch message {
        case .response(let response):
            // An id we no longer hold is expected, not exceptional: it is the
            // answer to a request that already timed out or was cancelled, and
            // the only correct thing to do with it is nothing.
            guard let id = response.id,
                  let continuation = pending.removeValue(forKey: id) else { return }
            if let error = response.error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: response.result)
            }

        case .notification(let notification):
            // Diagnostics, logs, progress: nothing here acts on any of them,
            // and nothing is dropped either — the consumer on `notifications`
            // decides (D29). Yielding into a finished continuation is a no-op,
            // so one racing the session's end is simply lost with it.
            notificationsContinuation.yield(LSPServerNotification(
                method: notification.method,
                params: notification.params
            ))

        case .serverRequest(let request):
            answer(request)
        }
    }

    /// Every server-initiated request gets a reply, including the ones we do not
    /// implement — a server blocked on an answer we never send is a server that
    /// stops answering us.
    private func answer(_ request: LSPRequestMessage) {
        let response: LSPResponseMessage
        switch request.method {
        case LSPMethod.registerCapability, LSPMethod.unregisterCapability:
            // Dynamic registration is declined in the client capabilities, so a
            // server should not ask; one that asks anyway is acknowledged and
            // ignored, which is cheaper than an error it might treat as fatal.
            response = LSPResponseMessage(id: request.id, result: .null)

        case LSPMethod.workspaceConfiguration:
            // `workspace.configuration` is advertised as `false`, so this is a
            // server going beyond what was agreed — and it is nonetheless *the*
            // channel that carries a setting, because a server that asks anyway
            // (yaml-language-server pulls unconditionally on `initialized`,
            // ignoring the pushed payload) takes its settings from the answer and
            // from nowhere else. The spec's result is one value per requested
            // item, in order: this server's own section where the description
            // names it, and `null` — "no setting", which stays exactly true for
            // every server whose description carries none — where it does not.
            let items = request.params?["items"]?.arrayValue ?? []
            response = LSPResponseMessage(
                id: request.id,
                result: .array(items.map(setting(forRequestedItem:)))
            )

        default:
            response = LSPResponseMessage(
                id: request.id,
                error: LSPResponseError(
                    code: .methodNotFound,
                    message: "Pisaka does not implement \(request.method)"
                )
            )
        }
        try? send(.response(response))
    }

    /// One item of a `workspace/configuration` request → the value to answer it
    /// with.
    ///
    /// A section is matched by its exact name against the top level of the
    /// configuration object — the spelling the server asks for is the spelling
    /// the description must use (`"[yaml]"` is a section name like any other, not
    /// a nested path). An item with no `section`, a section this server's
    /// configuration does not name, and any request at all to a server without a
    /// configuration all answer `null`: absent, not empty, which is what a server
    /// reads as "use your default".
    private func setting(forRequestedItem item: JSONValue) -> JSONValue {
        guard let section = item["section"]?.stringValue,
              let value = configuration?[section] else { return .null }
        return value
    }

    /// The byte stream ended: the process exited, crashed, or was terminated.
    private func handleStreamEnd() {
        close(reason: closureReason ?? .connectionClosed)
    }

    // MARK: - Writing

    private func send(_ message: LSPOutgoingMessage) throws {
        do {
            try transport.send(try LSPFraming.encode(message))
        } catch let error as LSPTransportError {
            // A failed write means the pipe is gone; there is no state in which
            // the next one succeeds.
            close(reason: .connectionClosed)
            throw error
        }
    }
}

/// Why an LSP exchange could not be completed on *our* side of the conversation.
///
/// A server's own refusal is an `LSPResponseError` and is thrown as itself — the
/// two are different facts, and a caller deciding whether to fall back cares
/// about the difference (a `MethodNotFound` says this server will never answer
/// this question; a `timedOut` says nothing about the next request).
///
/// Not `LocalizedError`, for the same reason as `LSPTransportError`: none of this
/// is ever shown to anyone.
public enum LSPSessionError: Error, Equatable, Hashable, Sendable {
    /// The session has not started, has been shut down, or already failed.
    case notRunning
    /// The per-request budget ran out (D7). Carries the method so a test — and a
    /// debug log — can tell which question was abandoned.
    case timedOut(method: String)
    /// The server's byte stream ended while requests were in flight.
    case connectionClosed
    /// The stream stopped being readable as LSP. Terminal by construction.
    case framing(LSPFramingError)
    /// `initialize` failed, or answered something that is not an
    /// `InitializeResult`.
    case handshakeRejected(String)
    /// The response arrived and decoded as JSON, but not as the shape the method
    /// is defined to answer.
    case malformedResponse(method: String)
}
