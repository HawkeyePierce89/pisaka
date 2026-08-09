import Foundation

/// Which servers are running, for which project, holding which documents open —
/// and when to stop trying.
///
/// `LSPSession` is one conversation and knows nothing outside it; this is the
/// layer that decides there *should* be a conversation. It owns three things no
/// session can own for itself:
///
/// * **One server per `(server, root)`**, started lazily on the first request for
///   a language it serves. Lazily because a project with no Swift in it must not
///   pay for sourcekit-lsp resolving a build system, and per-root because a
///   language server's whole model is a workspace.
/// * **What the server has been told.** D2's sync is request-driven: nothing is
///   pushed on a keystroke, and every request calls `prepare(url:language:text:)`
///   first, which sends a `didOpen` (or a `didChange` with a bumped version)
///   exactly when the text differs from what this server was last given. The cost
///   of a request is therefore at most one whole-file notification, and the
///   correctness rule — the server has the current text before any question about
///   it — holds without a single line of change-notification wiring in the editor.
/// * **When to give up** (D7). A crashed server is restarted three times with
///   1 s / 2 s / 4 s of backoff; the fourth failure marks that `(server, root)`
///   unavailable for the rest of the app run and nothing is ever launched for it
///   again. Silently, always: no alert, no banner, no state the user can see —
///   the language simply keeps answering with tree-sitter.
///
/// The budget is per `(server, root)` rather than per server, so a server that
/// cannot cope with *one* project (a half-checked-out package, a `Package.swift`
/// that does not resolve) does not poison the next folder the user opens. It is
/// never reset within a root, because a server that has crashed four times on the
/// same project is not going to succeed on the fifth.
///
/// **`Process` is not in this file, and cannot be.** Transports arrive through
/// `transportFactory`, which the app supplies (`LSPProcessTransport`, task 8) and
/// every test supplies as a scripted fake. That is the same seam
/// `SymbolIndexModel` makes for tree-sitter extraction, for the same reason: the
/// entire lifecycle — lazy start, sync bookkeeping, backoff, folder switch — is
/// unit-tested in a target that cannot spawn a process.
///
/// **A reader, never a writer** (D10). Nothing here raises `autosave.suspend()` or
/// `localChanges.beginRevert()`, and nothing here is gated by them. It reads
/// buffers and asks questions; it writes nothing to disk. A refresh landing
/// mid-revert costs at worst one wrong answer that the next request corrects,
/// while taking the writer gate would serialize the editor behind a language
/// server — the rule already written for the symbol index.
///
/// `@MainActor` for `SymbolIndexModel`'s reason: the bookkeeping is touched from
/// the editor's own turn (a folder switch, a tab close) and must be *synchronous*
/// there, so `prepareForFolderChange` can pin a generation before any hop.
@MainActor
public final class LSPWorkspace {
    /// How a transport is made. `@MainActor` because launching a process is the
    /// app's business and happens in the same turn the workspace decides to
    /// launch one; throwing because "there is no sourcekit-lsp on this machine"
    /// is an ordinary answer, not an exceptional one.
    public typealias TransportFactory = @MainActor (LSPServerDescription, URL) throws -> LSPTransport

    /// What a request needs to ask its question: the live session, the URI the
    /// server knows this file by, and the description behind it.
    ///
    /// Handed out only after the flush, so a caller holding one of these knows the
    /// server has the text the request was built against.
    public struct PreparedDocument: Sendable {
        public let session: LSPSession
        public let description: LSPServerDescription
        public let uri: String
        /// The version the server now holds — the number a `$/cancelRequest`-era
        /// race would be diagnosed by, and what the tests assert the flush did.
        public let version: Int
        /// The request generation this document was prepared under, so the answer
        /// that comes back can be checked against the folder that asked for it —
        /// see `stillHolds(_:)`. Pinned before the launch, not read afterwards.
        public let generation: Int
    }

    /// D7's backoff, in order. Its length *is* the restart budget: three delays,
    /// three restarts, and the fourth failure is terminal.
    public nonisolated static let backoffDelays: [TimeInterval] = [1, 2, 4]

    /// One server, one project root.
    struct ServerKey: Hashable, Sendable {
        let serverID: String
        /// The canonical root path, so the same folder reached through a symlink
        /// is the same key — and does not start a second server.
        let root: String
    }

    private struct DocumentState {
        /// Which server holds this document open. A restart changes the session
        /// but not the key, so this is compared rather than the session identity:
        /// a document whose server died must be re-`didOpen`ed, not `didChange`d.
        var serverKey: ServerKey
        var version: Int
        var text: String
    }

    /// A launch in flight, with an id so the caller that started it can clear the
    /// slot without clobbering a *newer* launch that replaced it.
    private struct PendingLaunch {
        let id: Int
        let task: Task<LSPSession?, Never>
    }

    /// A flush in flight, with the same id discipline and for the same reason.
    private struct PendingFlush {
        let id: Int
        let task: Task<Result<Int, Error>, Never>
    }

    /// The one way a flush fails that is not the transport's fault: the server it
    /// was talking to stopped being the server filed under its key while the
    /// notification was in flight. Read by `prepare` exactly like a write failure —
    /// drop the state, answer `nil`, let the next request re-`didOpen`.
    private enum FlushFailure: Error {
        case serverReplaced
    }

    private let registry: LSPServerRegistry
    private let transportFactory: TransportFactory
    private let budgets: LSPSession.Budgets
    /// The backoff wait, injectable so the restart tests assert D7's delays
    /// instead of sleeping for seven seconds.
    private let delay: @MainActor (TimeInterval) async -> Void
    private let processID: Int?

    private var sessions: [ServerKey: LSPSession] = [:]
    /// The transport behind each session — including one whose handshake has not
    /// finished yet, registered the moment the factory hands it over.
    ///
    /// Duplicating what `LSPSession` already holds, for exactly one reason:
    /// `terminateNow()` has to reach a live process from a context that cannot
    /// `await`, and a session is an actor. `LSPTransport.terminate()` is
    /// synchronous and idempotent (its own contract), so this map is the only thing
    /// that makes the quit path possible at all.
    private var transports: [ServerKey: LSPTransport] = [:]
    private var pendingLaunches: [ServerKey: PendingLaunch] = [:]
    private var documents: [String: DocumentState] = [:]
    /// The flush already running for a document, so a second request for the same
    /// file waits for it instead of interleaving with it.
    ///
    /// `flush` is a read-modify-write over `documents[uri]` with an `await` in the
    /// middle, and two requests for one file overlap as a matter of course rather
    /// than exotically: every request queued behind a launch resumes in the turn
    /// the handshake finishes, and a request the router abandoned at its deadline
    /// keeps flushing while the next one starts. Interleaved, two of them would
    /// send two `didOpen`s for one URI, or two `didChange`s carrying the same
    /// version — and, worse, leave `documents[uri]` recording text this server was
    /// never sent, which the next request reads as "nothing to send" and then asks
    /// its question against the wrong file, silently, until the buffer changes
    /// again.
    private var flushes: [String: PendingFlush] = [:]
    private var failures: [ServerKey: Int] = [:]
    private var unavailable: Set<ServerKey> = []

    private var currentRoot: URL?
    /// The public ordering token, bumped only when the opened folder actually
    /// changes — `SymbolIndexModel.prepareForFolderChange`'s contract, so a caller
    /// can pin one token across both models.
    private var generation = 0
    /// The private supersession token. Bumped by a folder change *and* by
    /// `shutdownAll()`, and checked by a launch after its handshake: a session
    /// that finished starting into a workspace that has since moved on is
    /// terminated rather than stored. Separate from `generation` precisely so a
    /// `shutdownAll()` does not invalidate a token the caller pinned from
    /// `prepareForFolderChange` in the same turn.
    private var epoch = 0
    private var launchCounter = 0
    private var flushCounter = 0

    public init(
        registry: LSPServerRegistry = .standard,
        budgets: LSPSession.Budgets = .standard,
        processID: Int? = Int(ProcessInfo.processInfo.processIdentifier),
        // Core cannot start a process, so the default is the honest answer rather
        // than a stub that pretends: with no factory, nothing ever launches and
        // every request falls back.
        transportFactory: @escaping TransportFactory = { _, _ in
            throw LSPTransportError.launchFailed("no transport factory")
        },
        delay: @escaping @MainActor (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.registry = registry
        self.budgets = budgets
        self.processID = processID
        self.transportFactory = transportFactory
        self.delay = delay
    }

    // MARK: - Folder lifecycle

    /// Synchronously record that the workspace is moving to `root` (`nil` when the
    /// folder was closed), returning the request generation the switch produced.
    ///
    /// The `SymbolIndexModel.prepareForFolderChange` / `ProjectSearchModel`
    /// precedent, called in the same main-actor turn as the folder open and
    /// *before* any `Task`: a `prepare` that was already in flight resumes to find
    /// itself superseded and terminates the server it just started, rather than
    /// answering the new project's questions out of the old one's index.
    ///
    /// Servers are not torn down here — that is `shutdownAll()`, which the caller
    /// awaits right after — because a graceful `shutdown`→`exit` cannot happen
    /// synchronously and pretending otherwise would leave the orphan the release
    /// check greps for.
    @discardableResult
    public func prepareForFolderChange(root: URL?) -> Int {
        guard root != currentRoot else { return generation }
        currentRoot = root
        generation += 1
        epoch += 1
        return generation
    }

    public var currentRequestGeneration: Int { generation }
    public var root: URL? { currentRoot }

    /// Stop every server, politely, and forget every document.
    ///
    /// Called on a folder switch and from the app's `willTerminateNotification`
    /// observer — the two places `TerminalSessionsModel.terminateAll()` and
    /// `DiffWindowController.closeAll()` are already called from. Every open
    /// document is `didClose`d before its server is shut down (D2), which costs
    /// nothing and leaves a server that is about to be asked to exit with a
    /// coherent view of the world.
    ///
    /// Never throws and never waits on a server that will not answer:
    /// `LSPSession.shutdown()` gives up after its own budget and terminates the
    /// transport regardless.
    public func shutdownAll() async {
        // Bumped first: a launch still in flight will see the mismatch after its
        // handshake and terminate itself instead of registering into the maps this
        // method just emptied.
        epoch += 1

        let live = sessions
        let inflight = pendingLaunches
        let open = documents
        sessions = [:]
        transports = [:]
        pendingLaunches = [:]
        documents = [:]

        for (key, session) in live {
            for (uri, state) in open where state.serverKey == key {
                try? await session.didClose(LSPDidCloseTextDocumentParams(uri: uri))
            }
            await session.shutdown()
        }

        // A launch that had not finished when the epoch moved returns `nil` and has
        // already terminated its own transport; awaiting it is what makes
        // "nothing outlives this call" true rather than likely.
        for pending in inflight.values {
            if let orphan = await pending.task.value { await orphan.shutdown() }
        }
    }

    /// Kill every server **now**, synchronously, without the handshake — what app
    /// termination means.
    ///
    /// `shutdownAll()` is the polite path and the one every other caller wants, but
    /// it cannot be the quit path: `NSApplication.willTerminateNotification` is the
    /// last thing AppKit posts before the process exits, so there is no further
    /// run-loop turn in which a `Task` wrapping an `async` teardown would ever run —
    /// the same reason the autosave and session writers flush *synchronously* from
    /// that observer. A `Task` there would compile, do nothing, and leave the orphan
    /// `sourcekit-lsp` the release check greps for.
    ///
    /// So this reaches past the sessions to the transports, whose `terminate()` is
    /// synchronous and idempotent by contract: stdin closed, `SIGTERM` sent,
    /// escalating on its own. A launch still mid-handshake is killed too — its
    /// transport is registered before the handshake starts precisely so this can
    /// find it — and the `LSPSession` objects are simply dropped: with the byte
    /// stream gone there is nothing left for one to do, and nobody will ask it
    /// anything after this.
    ///
    /// The epoch bump keeps that true for the launch tasks that resume during the
    /// remaining moments of the process: they find themselves superseded, terminate
    /// what they built, and register nothing.
    public func terminateNow() {
        epoch += 1

        let live = transports
        sessions = [:]
        transports = [:]
        pendingLaunches = [:]
        documents = [:]

        for transport in live.values { transport.terminate() }
    }

    // MARK: - Documents

    /// Make sure a server for `language` is running and holds the current text of
    /// `url`, and hand back what a request needs.
    ///
    /// `nil` — the answer for every failure, uniformly — means "ask tree-sitter":
    /// no server serves the language, no folder is open, the file lives outside
    /// the root, the server is unavailable, the launch failed, the handshake was
    /// rejected, the folder changed while we were starting, or the notification
    /// could not be written. The caller (`LSPIntelligenceProvider`, task 6) does
    /// not distinguish them, because D7's fallback is per request and silent.
    ///
    /// The flush is the whole of D2: `didOpen` the first time this server sees the
    /// document, one full-text `didChange` when the text differs from what it was
    /// last told, and nothing at all when it does not — so a second request at the
    /// same keystroke sends no notification.
    public func prepare(
        url: URL,
        language: SyntaxLanguage,
        text: String
    ) async -> PreparedDocument? {
        guard let root = currentRoot else { return nil }
        guard let description = registry.description(for: language) else { return nil }
        // A document is never opened against a root it does not live under: a
        // server initialized for one project has no business being told about a
        // file from another, and the answers it gave would be about the wrong
        // build.
        guard LSPWorkspace.path(of: url, isUnder: root) else { return nil }

        let token = generation
        let key = ServerKey(serverID: description.id, root: LSPWorkspace.rootKey(for: root))
        guard let session = await liveSession(for: description, root: root, key: key) else {
            return nil
        }
        // The folder moved while the server was starting: this session belongs to
        // a project nobody is looking at, and `shutdownAll` is on its way.
        guard token == generation else { return nil }

        let uri = LSPWorkspace.documentURI(for: url)
        let version: Int
        do {
            version = try await flush(
                uri: uri,
                text: text,
                language: language,
                session: session,
                key: key
            )
        } catch {
            // The notification could not be written, which means the pipe is gone.
            // The session has already gone terminal; the next request restarts it.
            documents[uri] = nil
            return nil
        }
        // The same guard as above, applied to the flush's hop — and it is not the
        // one the flush already makes. `send`'s `isCurrent` check catches a
        // *teardown*: `shutdownAll()` empties `sessions`, so a notification
        // resuming after it throws `serverReplaced` and the `catch` above answers
        // `nil`. But a folder switch is two steps, and only the first is
        // synchronous — `prepareForFolderChange` bumps the generation in the
        // editor's turn, and the `shutdownAll()` it schedules runs a turn later. A
        // flush resuming inside that window still finds its session filed under
        // its key, succeeds, and would hand back a document for the root the user
        // has just left. The provider would then ask the old project's server a
        // question and publish an answer naming a file under a folder nobody is
        // looking at — a confident jump, which never falls back, because it *is*
        // an answer. The document state `send` recorded is left alone: it is a
        // true record of what that server was told, and the teardown drops it.
        guard token == generation else { return nil }

        return PreparedDocument(
            session: session,
            description: description,
            uri: uri,
            version: version,
            generation: token
        )
    }

    /// `didOpen` / `didChange` / nothing — serialised per document.
    ///
    /// The serialisation is the whole of this method; `send(…)` below is the part
    /// that talks. See `flushes` for what interleaving two of them costs.
    private func flush(
        uri: String,
        text: String,
        language: SyntaxLanguage,
        session: LSPSession,
        key: ServerKey
    ) async throws -> Int {
        // Wait out whatever is already flushing this document. A loop rather than
        // one wait: several requests can be queued on the same flush, they all wake
        // when it finishes, and only one of them gets to claim the slot below — the
        // rest find the *next* claim here and wait again.
        //
        // This terminates only because the running flush clears its own slot from
        // inside its task body, before it completes. Clearing it from the awaiting
        // owner instead would leave the slot occupied by an *already finished* task
        // at the moment every waiter wakes, and `await` on a finished task returns
        // without suspending — so the loop would spin on the main actor and never
        // let the owner run. That is a hang, not a slowdown.
        while let inFlight = flushes[uri] { _ = await inFlight.task.value }

        // The no-op — a second request at the same keystroke — is answered without
        // claiming anything, so the common path allocates nothing.
        if let state = documents[uri], state.serverKey == key, state.text == text {
            return state.version
        }

        // Claimed synchronously: there is no suspension point between the loop
        // above and this line, so exactly one waiter can get here at a time.
        flushCounter += 1
        let id = flushCounter
        let task = Task { @MainActor [self] () -> Result<Int, Error> in
            let outcome: Result<Int, Error>
            do {
                outcome = .success(
                    try await send(
                        uri: uri,
                        text: text,
                        language: language,
                        session: session,
                        key: key
                    )
                )
            } catch {
                outcome = .failure(error)
            }
            // Released here, as the last thing this task does and while it is still
            // running — see the loop above for why it cannot be released by the
            // owner afterwards. The body cannot start before the store below (the
            // main actor is held until this method suspends), so the slot is
            // always the one this claim put there.
            if flushes[uri]?.id == id { flushes[uri] = nil }
            return outcome
        }
        flushes[uri] = PendingFlush(id: id, task: task)
        return try await task.value.get()
    }

    /// The notification itself, and the version bookkeeping behind it. Runs only
    /// under `flush`'s per-document claim.
    private func send(
        uri: String,
        text: String,
        language: SyntaxLanguage,
        session: LSPSession,
        key: ServerKey
    ) async throws -> Int {
        if let state = documents[uri], state.serverKey == key {
            guard state.text != text else { return state.version }
            let version = state.version + 1
            try await session.didChange(
                LSPDidChangeTextDocumentParams(uri: uri, version: version, fullText: text)
            )
            guard isCurrent(session, for: key) else { throw FlushFailure.serverReplaced }
            documents[uri] = DocumentState(serverKey: key, version: version, text: text)
            return version
        }

        // Either the first request for this file, or the first since the server
        // behind it was replaced — a restarted server knows nothing, so a
        // `didChange` against it would be a version bump over a document it never
        // opened.
        try await session.didOpen(
            LSPDidOpenTextDocumentParams(
                textDocument: LSPTextDocumentItem(
                    uri: uri,
                    languageId: language.lspLanguageID,
                    version: 1,
                    text: text
                )
            )
        )
        guard isCurrent(session, for: key) else { throw FlushFailure.serverReplaced }
        documents[uri] = DocumentState(serverKey: key, version: 1, text: text)
        return 1
    }

    /// Whether `session` is still the one filed under `key` — the check that stops
    /// a notification written a moment ago from writing its document state back
    /// over a clear that superseded it.
    ///
    /// `send` is a read-modify-write over `documents[uri]` with an `await` in the
    /// middle, and the per-document flush claim only serialises it against *other
    /// flushes*. `noteDeath`, `shutdownAll()` and `terminateNow()` drop document
    /// state from outside that claim — they must, since a crash and a quit do not
    /// queue behind a keystroke — so a `didChange` that returned successfully just
    /// before the server died resumes into a world where its document was already
    /// forgotten, and writes it back. The entry then records the file as open on a
    /// key whose *replacement* server has never heard of it: every later flush
    /// takes the "nothing to send" fast path or bumps a version against a document
    /// that was never `didOpen`ed, so that file falls back to tree-sitter silently
    /// for the life of that server. The identity check is `forget(_:for:)`'s, for
    /// `forget(_:for:)`'s reason.
    private func isCurrent(_ session: LSPSession, for key: ServerKey) -> Bool {
        sessions[key] === session
    }

    /// Tell the server the file is gone from the editor — the last tab on it
    /// closed (D2).
    ///
    /// Called under the app's existing "no other tab shows this file" guard, beside
    /// `SymbolIndexModel.forgetBuffer(url:)`. A file nobody opened, or one whose
    /// server has since died, is a no-op: the state is dropped either way, so the
    /// next request re-opens rather than assuming the server still has it.
    ///
    /// Runs under the same per-document claim `flush` takes, and must: a tab closed
    /// while a request is flushing is ordinary (the close *is* what supersedes the
    /// request), and without the claim the two interleave in the one way that does
    /// lasting damage. `send` is a read-modify-write over `documents[uri]` with an
    /// `await` in the middle, so a `didClose` landing inside that window drops the
    /// state and then has it *written back* by the notification that was already in
    /// flight — leaving a document the server has been told is closed recorded here
    /// as open, with exactly the text it was told. The next request reads that as
    /// "nothing to send", never re-`didOpen`s, and asks about a document the server
    /// dropped — silently, for the rest of the app run, since only another close or
    /// a crash clears the entry.
    public func didClose(url: URL) async {
        let uri = LSPWorkspace.documentURI(for: url)
        // Wait out whatever is flushing this document — `flush`'s loop, for
        // `flush`'s reason, and it terminates for the same one: the running task
        // clears its own slot from inside its body.
        while let inFlight = flushes[uri] { _ = await inFlight.task.value }

        guard let state = documents.removeValue(forKey: uri) else { return }
        guard let session = sessions[state.serverKey] else { return }

        // Claimed like a flush, so a request that arrives while the notification is
        // being written waits rather than re-opening the document underneath it.
        // There is no suspension point between the loop above and this line, so the
        // claim is exactly the one this call put there.
        flushCounter += 1
        let id = flushCounter
        let task = Task { @MainActor [self] () -> Result<Int, Error> in
            do {
                try await session.didClose(LSPDidCloseTextDocumentParams(uri: uri))
            } catch {
                // The pipe is gone, which the next request rediscovers on its own.
                // The state is already dropped, which is the part that matters.
            }
            if flushes[uri]?.id == id { flushes[uri] = nil }
            return .success(state.version)
        }
        flushes[uri] = PendingFlush(id: id, task: task)
        _ = await task.value
    }

    /// Whether an answer prepared against `prepared` may still be read — the folder
    /// it was asked about is still the open one, *and* the server still holds
    /// exactly the version the question was built against.
    ///
    /// **The version half.** `prepare` releases the document's flush claim before it
    /// returns, so a *second* request carrying older text (one queued behind a
    /// launch, or one the router abandoned at its deadline and then resumed) can
    /// `didChange` the server backwards between the flush and the request that
    /// followed it. The answer that comes back is then about a document whose offsets
    /// the caller's buffer does not describe.
    ///
    /// **The generation half**, and it is not the version check wearing another hat:
    /// a request is outstanding for as long as the server takes to answer, which is
    /// the widest window in the whole layer, and a folder switch inside it leaves
    /// `documents` untouched until the `shutdownAll()` it *schedules* runs a turn
    /// later. The version therefore still matches, and the answer — computed by a
    /// server initialized for the root the user has just left — would name a file
    /// under a closed folder. That is the same window `prepare` closes on both sides
    /// of the flush (see the guards there), reaching past `prepare` to cover the
    /// request itself; nothing downstream can close it, because a jump *is* an
    /// answer and so never falls back.
    ///
    /// Callers ask this before reading a response and treat `false` as no answer at
    /// all. Checking after the fact rather than holding the flush claim across the
    /// request is deliberate: the claim would serialise every other question about
    /// that file behind a server allowed to take seconds, and the cost of the
    /// conservative answer is one tree-sitter fallback in a case where the world had
    /// moved on anyway.
    public func stillHolds(_ prepared: PreparedDocument) -> Bool {
        guard prepared.generation == generation else { return false }
        return documents[prepared.uri]?.version == prepared.version
    }

    // MARK: - Sessions

    /// Whether asking a server about `language` is worth attempting at all — the
    /// question `RoutingIntelligenceProvider` (task 7) asks before it spends a
    /// budget on one.
    ///
    /// Deliberately does not start anything: it is a *policy* answer (is there a
    /// server for this language, in this root, that has not given up), not a
    /// health check.
    public func canServe(_ language: SyntaxLanguage) -> Bool {
        guard let root = currentRoot,
              let description = registry.description(for: language) else { return false }
        let key = ServerKey(serverID: description.id, root: LSPWorkspace.rootKey(for: root))
        return !unavailable.contains(key)
    }

    /// Whether this language's server has failed often enough to be given up on
    /// for the rest of the app run (D7).
    public func isUnavailable(_ language: SyntaxLanguage) -> Bool {
        guard let root = currentRoot,
              let description = registry.description(for: language) else { return false }
        return unavailable.contains(
            ServerKey(serverID: description.id, root: LSPWorkspace.rootKey(for: root))
        )
    }

    /// The running session for this `(server, root)`, starting one if there is
    /// none and restarting one that died — within D7's budget.
    private func liveSession(
        for description: LSPServerDescription,
        root: URL,
        key: ServerKey
    ) async -> LSPSession? {
        if unavailable.contains(key) { return nil }

        // The supersession token, pinned **before the first hop** rather than
        // beside the launch below. Everything between here and there suspends —
        // the liveness check on a session that turned out to be dead, the death
        // booking, the wait on somebody else's launch — and a folder switch fits
        // through any of them. A launch that read `epoch` afterwards would read
        // the value the switch had already bumped, pass its own guard, and file a
        // server into the maps `shutdownAll()` had just emptied: a live
        // `sourcekit-lsp` for a root nobody is looking at, which nothing tears
        // down until the *next* switch or the quit.
        let token = epoch

        if let existing = sessions[key] {
            if await existing.isRunning { return existing }
            // The server crashed, exited, or was killed. This is where a crash is
            // *noticed*: nothing pushes it, because a session that reported its own
            // death would need a back-reference to the thing that decides whether
            // it deserves another chance.
            //
            // `sessions[key]` is re-read rather than trusted across the hop above:
            // two requests in flight (a definition and a completion, say) both read
            // the slot, both suspend on `isRunning`, and both come back holding the
            // same corpse. Only the one that still finds *its* session filed under
            // the key books the death — the other would spend a second restart on
            // one crash, and D7's budget of three would be gone after two.
            if sessions[key] === existing {
                guard await noteDeath(of: key) else { return nil }
            } else if let replacement = sessions[key] {
                // The other observer has already restarted it. That server is the
                // answer; launching a second one for the same key is the one thing
                // this method exists to prevent.
                return replacement
            }
        }

        // A second request arriving while the first is still handshaking waits for
        // it rather than starting a second server — the difference between "lazy"
        // and "once".
        if let pending = pendingLaunches[key] { return await pending.task.value }

        // Nothing is started for a workspace that has moved on since this call
        // began — see the token above. The same guard `launch` applies after D7's
        // backoff, applied to the hops that happen *before* it.
        //
        // `unavailable` is re-read for the same reason it is re-read there. The
        // entry check ran before the liveness hop and the death booking, and the
        // *second* observer of one crash resumes past both: the first one booked
        // the death, spent the last of D7's budget, and returned `nil`, but this
        // one finds the slot empty (so neither branch above answers) and would
        // launch. `canServe`/`isUnavailable` already answer `false` for the key by
        // then, so nothing would ever route to that server — it would just be a
        // live `sourcekit-lsp` holding a build-system cache until the next folder
        // switch or the quit, and the contradiction of "nothing is ever launched
        // for it again".
        guard !unavailable.contains(key), token == epoch else { return nil }

        launchCounter += 1
        let id = launchCounter
        // The token travels into the task rather than being re-read inside it: the
        // `prepareForFolderChange` discipline, applied to the one token `launch`
        // checks. Reading `epoch` inside `launch` instead would read it after two
        // more suspension points a folder switch fits through comfortably: the
        // task's own scheduling, and D7's backoff, which is up to four seconds long.
        // A launch that pinned the *already bumped* epoch passes its own guard and
        // files a session into maps `shutdownAll()` has just emptied, where the next
        // visit to that folder finds a corpse and charges its death against D7's
        // budget — four folder round-trips and a healthy server is unavailable for
        // the rest of the app run.
        let task = Task { @MainActor [weak self] () -> LSPSession? in
            guard let self else { return nil }
            return await self.launch(description: description, root: root, key: key, epoch: token)
        }
        pendingLaunches[key] = PendingLaunch(id: id, task: task)
        let session = await task.value
        // Only our own slot: a `shutdownAll` (which clears the map) or a newer
        // launch registered here in the meantime must not be erased.
        if pendingLaunches[key]?.id == id { pendingLaunches[key] = nil }
        return session
    }

    /// Start one server and complete its handshake, or count the attempt as a
    /// failure.
    ///
    /// `epoch` is the supersession token, pinned by the caller before this task was
    /// even created — see `liveSession`.
    private func launch(
        description: LSPServerDescription,
        root: URL,
        key: ServerKey,
        epoch token: Int
    ) async -> LSPSession? {
        // D7's backoff, paid before the attempt rather than after the crash: the
        // wait belongs to whoever is asking for a restart, and a session that died
        // while nobody was looking should not have delayed anything.
        if let previousFailures = failures[key], previousFailures > 0 {
            let index = min(previousFailures, LSPWorkspace.backoffDelays.count) - 1
            await delay(LSPWorkspace.backoffDelays[index])
        }
        // The wait is the widest window in this layer, so it is also checked across:
        // a folder switch during the backoff must not launch anything at all, and
        // neither must a budget another request spent while this one slept — four
        // seconds is long enough for the remaining restarts to be booked and the
        // key retired, and a server launched after that is one nothing will ever
        // ask a question.
        guard !unavailable.contains(key), token == epoch else { return nil }

        let transport: LSPTransport
        do {
            transport = try transportFactory(description, root)
        } catch LSPTransportError.notReady {
            // Not a failure: the factory declined to answer *yet* rather than
            // blocking the turn it was called on (the toolchain lookup is still
            // running). Nothing was attempted, so nothing is counted — charging
            // D7's budget for it would let three ⌘-clicks in the first second
            // after launch retire a perfectly good server for the app run. This
            // request falls back; the next one launches.
            return nil
        } catch {
            // No toolchain, no executable, no pipe. Counted like a crash: a
            // machine with no Xcode must stop trying, not retry per keystroke.
            _ = noteFailure(of: key)
            return nil
        }
        // Registered *before* the handshake, so `terminateNow()` can reach a server
        // that is still resolving a build system — the case a quit is most likely to
        // land in, since that is also the slowest thing this layer ever does.
        transports[key] = transport

        let session = LSPSession(transport: transport, budgets: budgets)
        do {
            let capabilities = try await session.start(
                processID: processID,
                rootURI: LSPWorkspace.rootURI(for: root),
                initializationOptions: description.initializationOptions
            )
            guard token == epoch else {
                // The folder changed (or everything was shut down) while this
                // server was starting. Not a failure — nothing went wrong — so it
                // costs no restart budget, but the process must not survive it.
                await session.terminate()
                forget(transport, for: key)
                return nil
            }
            guard capabilities.usesUTF16Positions else {
                // Every offset in this codebase is UTF-16. A server that chose
                // another encoding would mis-map every position in any file with
                // one non-ASCII character, which is worse than not answering — and
                // it will choose the same encoding on every restart, so this is
                // terminal rather than countable.
                await session.terminate()
                forget(transport, for: key)
                unavailable.insert(key)
                return nil
            }
            sessions[key] = session
            return session
        } catch {
            await session.terminate()
            forget(transport, for: key)
            _ = noteFailure(of: key)
            return nil
        }
    }

    /// Drop `transport` from the map — but only while it is still the one filed
    /// under `key`.
    ///
    /// A launch that gives up resumes on a main-actor turn arbitrarily later, by
    /// which time a folder switch may have emptied the map and a *newer* launch
    /// registered its own transport in it. Clearing that one would leave a live
    /// process nothing could reach, which is the one thing this bookkeeping exists
    /// to prevent — the same identity check `liveSession` makes on `pendingLaunches`.
    private func forget(_ transport: LSPTransport, for key: ServerKey) {
        if transports[key] === transport { transports[key] = nil }
    }

    /// A session that was running is not any more: forget it, forget what it was
    /// told, and decide whether it gets another chance.
    /// Every mutation happens *before* the one `await`, and that ordering is the
    /// point: a second request that observed the same crash must find the slot
    /// already empty (`liveSession`'s identity check) rather than a session still
    /// filed under the key while this one waits on a terminate.
    private func noteDeath(of key: ServerKey) async -> Bool {
        let dead = sessions[key]
        sessions[key] = nil
        transports[key] = nil
        // Everything this server was told died with it. Dropping the state is what
        // makes the next request send a `didOpen` rather than a `didChange`
        // against a document the new process has never heard of.
        documents = documents.filter { $0.value.serverKey != key }
        let mayRestart = noteFailure(of: key)
        if let dead { await dead.terminate() }
        return mayRestart
    }

    /// D7's counter. `false` once the budget is spent — and from then on the
    /// `(server, root)` is unavailable for the rest of the app run, so nothing is
    /// ever launched for it again.
    private func noteFailure(of key: ServerKey) -> Bool {
        let count = (failures[key] ?? 0) + 1
        failures[key] = count
        guard count <= LSPWorkspace.backoffDelays.count else {
            unavailable.insert(key)
            return false
        }
        return true
    }

    // MARK: - URIs

    /// The `file:` URI a document is known by. Standardized, so the same file
    /// spelled two ways is one document — but *not* symlink-resolved, because the
    /// server must be told the path the user opened (a target it reports back is
    /// matched against the same spelling).
    nonisolated static func documentURI(for url: URL) -> String {
        url.standardizedFileURL.absoluteString
    }

    /// The root's URI, always with the trailing slash a directory URI carries.
    nonisolated static func rootURI(for root: URL) -> String {
        URL(fileURLWithPath: root.standardizedFileURL.path, isDirectory: true).absoluteString
    }

    /// The `(server, root)` key's root half: canonical, so two spellings of the
    /// same folder share one server.
    nonisolated static func rootKey(for root: URL) -> String {
        CanonicalPath.canonical(root).path
    }

    /// Whether `url` lives strictly under `root`, compared the way the rest of the
    /// app compares paths (`CanonicalPath`, whole components).
    nonisolated static func path(of url: URL, isUnder root: URL) -> Bool {
        CanonicalPath.relativeComponents(
            of: CanonicalPath.canonical(url).pathComponents,
            under: CanonicalPath.canonical(root).pathComponents
        ) != nil
    }

    // MARK: - Test seams

    /// The `(server, root)` pairs with a live session — how the tests assert
    /// "started once" and "not started again".
    var liveServerCount: Int { sessions.count }

    /// Every document some server currently holds open.
    var openDocumentURIs: Set<String> { Set(documents.keys) }
}
