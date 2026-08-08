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

    private let registry: LSPServerRegistry
    private let transportFactory: TransportFactory
    private let budgets: LSPSession.Budgets
    /// The backoff wait, injectable so the restart tests assert D7's delays
    /// instead of sleeping for seven seconds.
    private let delay: @MainActor (TimeInterval) async -> Void
    private let processID: Int?

    private var sessions: [ServerKey: LSPSession] = [:]
    private var pendingLaunches: [ServerKey: PendingLaunch] = [:]
    private var documents: [String: DocumentState] = [:]
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

        return PreparedDocument(
            session: session,
            description: description,
            uri: uri,
            version: version
        )
    }

    /// `didOpen` / `didChange` / nothing, and the version bookkeeping behind it.
    private func flush(
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
        documents[uri] = DocumentState(serverKey: key, version: 1, text: text)
        return 1
    }

    /// Tell the server the file is gone from the editor — the last tab on it
    /// closed (D2).
    ///
    /// Called under the app's existing "no other tab shows this file" guard, beside
    /// `SymbolIndexModel.forgetBuffer(url:)`. A file nobody opened, or one whose
    /// server has since died, is a no-op: the state is dropped either way, so the
    /// next request re-opens rather than assuming the server still has it.
    public func didClose(url: URL) async {
        let uri = LSPWorkspace.documentURI(for: url)
        guard let state = documents.removeValue(forKey: uri) else { return }
        guard let session = sessions[state.serverKey] else { return }
        try? await session.didClose(LSPDidCloseTextDocumentParams(uri: uri))
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

        if let existing = sessions[key] {
            if await existing.isRunning { return existing }
            // The server crashed, exited, or was killed. This is where a crash is
            // *noticed*: nothing pushes it, because a session that reported its own
            // death would need a back-reference to the thing that decides whether
            // it deserves another chance.
            guard await noteDeath(of: key) else { return nil }
        }

        // A second request arriving while the first is still handshaking waits for
        // it rather than starting a second server — the difference between "lazy"
        // and "once".
        if let pending = pendingLaunches[key] { return await pending.task.value }

        launchCounter += 1
        let id = launchCounter
        let task = Task { @MainActor [weak self] () -> LSPSession? in
            guard let self else { return nil }
            return await self.launch(description: description, root: root, key: key)
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
    private func launch(
        description: LSPServerDescription,
        root: URL,
        key: ServerKey
    ) async -> LSPSession? {
        // D7's backoff, paid before the attempt rather than after the crash: the
        // wait belongs to whoever is asking for a restart, and a session that died
        // while nobody was looking should not have delayed anything.
        if let previousFailures = failures[key], previousFailures > 0 {
            let index = min(previousFailures, LSPWorkspace.backoffDelays.count) - 1
            await delay(LSPWorkspace.backoffDelays[index])
        }

        let token = epoch
        let transport: LSPTransport
        do {
            transport = try transportFactory(description, root)
        } catch {
            // No toolchain, no executable, no pipe. Counted like a crash: a
            // machine with no Xcode must stop trying, not retry per keystroke.
            _ = noteFailure(of: key)
            return nil
        }

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
                return nil
            }
            guard capabilities.usesUTF16Positions else {
                // Every offset in this codebase is UTF-16. A server that chose
                // another encoding would mis-map every position in any file with
                // one non-ASCII character, which is worse than not answering — and
                // it will choose the same encoding on every restart, so this is
                // terminal rather than countable.
                await session.terminate()
                unavailable.insert(key)
                return nil
            }
            sessions[key] = session
            return session
        } catch {
            await session.terminate()
            _ = noteFailure(of: key)
            return nil
        }
    }

    /// A session that was running is not any more: forget it, forget what it was
    /// told, and decide whether it gets another chance.
    private func noteDeath(of key: ServerKey) async -> Bool {
        if let dead = sessions[key] { await dead.terminate() }
        sessions[key] = nil
        // Everything this server was told died with it. Dropping the state is what
        // makes the next request send a `didOpen` rather than a `didChange`
        // against a document the new process has never heard of.
        documents = documents.filter { $0.value.serverKey != key }
        return noteFailure(of: key)
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
