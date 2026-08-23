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
/// * **What a server says unprompted** (D29). Every session carries a
///   notification stream with exactly one consumer — a main-actor task this
///   file owns beside the session and cancels with it. It decodes
///   `textDocument/publishDiagnostics`, accepts a push only for a document
///   that server currently holds at the version it was last given (D31), maps
///   the entries onto buffer offsets against the text the server was told, and
///   hands the result to ``onDiagnostics``. Every teardown path emits the
///   matching clear synchronously (D33), and the stream's own termination —
///   the externally-killed server — clears the key on the way out.
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

    /// Which server answers for which language — a `var` since 2b (D16), because a
    /// server the app has just finished installing must become servable in the
    /// turn it lands rather than at the next launch. Swapped only through
    /// `updateRegistry(_:)`, which is what makes "un-registered means stopped"
    /// true rather than hopeful.
    private var registry: LSPServerRegistry
    private let transportFactory: TransportFactory
    private let budgets: LSPSession.Budgets
    /// The backoff wait, injectable so the restart tests assert D7's delays
    /// instead of sleeping for seven seconds.
    private let delay: @MainActor (TimeInterval) async -> Void
    private let processID: Int?

    private var sessions: [ServerKey: LSPSession] = [:]
    /// The per-session notification consumer (D29), keyed like `sessions` and
    /// cancelled wherever the session goes away — see
    /// `attachNotificationConsumer(for:)`.
    private var notificationTasks: [ServerKey: Task<Void, Never>] = [:]
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

    /// The sink every accepted push and every teardown clear is handed to —
    /// `DiagnosticsModel.receive(_:)` in the composed app, a recording closure
    /// in the tests. `nil` (the default) changes nothing about routing: pushes
    /// are decoded, gated and then dropped, exactly as notifications were
    /// before this channel existed. Called on the main actor, always — every
    /// emission site is one of this class's own main-actor methods.
    public var onDiagnostics: ((LSPDiagnosticEvent) -> Void)?

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
        let liveTransports = transports
        sessions = [:]
        pendingLaunches = [:]
        documents = [:]

        // D33: every diagnostic a torn-down server produced dies with it, and
        // the model is told *now*, synchronously — not after a polite goodbye
        // that may take a whole request budget. Each consumer task is cancelled
        // with its session and stays silent on the way out (it sees the
        // cancellation, knows this path already cleared), so the key's clear is
        // emitted exactly once.
        for key in live.keys {
            notificationTasks[key]?.cancel()
            notificationTasks[key] = nil
            onDiagnostics?(.cleared(.server(serverID: key.serverID, root: key.root)))
        }

        // `transports` is deliberately *not* emptied alongside the other three. It
        // is the only map `terminateNow()` reads, and every process below stays
        // alive until the `await` that stops it returns — so clearing it here would
        // make each one unreachable for exactly the window in which a quit is most
        // likely to land, and a quit inside that window leaves the orphan
        // `terminateNow()` exists to kill. Each entry is dropped instead once its
        // process is actually dead, under `forget`'s identity guard so a launch that
        // registered a *newer* transport for the same key in the meantime keeps it.
        // The inflight transports need no entry here at all: a superseded launch
        // sees the epoch mismatch, terminates what it built and `forget`s it itself.
        for (key, session) in live {
            for (uri, state) in open where state.serverKey == key {
                try? await session.didClose(LSPDidCloseTextDocumentParams(uri: uri))
            }
            await session.shutdown()
            if let transport = liveTransports[key] { forget(transport, for: key) }
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

        let live = sessions
        let liveTransports = transports
        sessions = [:]
        transports = [:]
        pendingLaunches = [:]
        documents = [:]

        // D33, synchronously: quit time offers no further run-loop turn in which
        // a consumer task could wake, so the clears go out from here. The
        // cancelled consumers stay silent (see `shutdownAll`).
        for key in live.keys {
            notificationTasks[key]?.cancel()
            notificationTasks[key] = nil
            onDiagnostics?(.cleared(.server(serverID: key.serverID, root: key.root)))
        }

        for transport in liveTransports.values { transport.terminate() }
    }

    // MARK: - Registration

    /// Swap the registry, and stop every server the swap un-registered or changed
    /// (D16).
    ///
    /// 2a fixed the registry at construction, which was enough while the only
    /// server was one `xcrun` finds. 2b installs servers *while the app runs*, and
    /// the whole promise of that feature is that opening a `.ts` file, accepting the
    /// download and getting semantic completion is one uninterrupted sequence — so
    /// `canServe` has to flip from `false` to `true` without a restart, which means
    /// the registry has to move.
    ///
    /// It has to flip **both ways**, and that is the half with teeth. Removing a
    /// server in Settings un-registers it, and a description that is merely
    /// forgotten leaves its process running against a root nobody will ever ask it
    /// about again: the orphan `pgrep -fl node` finds after quitting. So an
    /// un-registered — or *changed*, which for a launch description means a
    /// different id, executable, argument list or initialization options — server is
    /// shut down politely here, its documents `didClose`d first (D2) exactly as a
    /// folder switch does, its transport dropped and its documents forgotten.
    ///
    /// Its D7 bookkeeping is cleared with it, so a re-added server starts with a
    /// fresh budget of three restarts. The rule "never reset within a root" is about
    /// a server that keeps crashing on the same project; a server the user has just
    /// removed and reinstalled is a *new* server on that project, and making someone
    /// relaunch the app to get a second chance after a bad download would be the
    /// silent failure D7 exists to avoid, not the one it prevents.
    ///
    /// Everything the swap left alone is left alone: an unchanged server keeps its
    /// session, its open documents and its failure count, and neither generation
    /// token moves — a registry update is not a folder change, and a request in
    /// flight for a server that survived is still a request about the folder it was
    /// asked under.
    public func updateRegistry(_ registry: LSPServerRegistry) async {
        guard registry != self.registry else { return }
        let before = LSPWorkspace.reachableDescriptions(in: self.registry)
        let after = LSPWorkspace.reachableDescriptions(in: registry)
        self.registry = registry

        // Gone, shadowed, or launched differently. Written as "not identical to
        // what it was" rather than "absent now" so a version bump — same id, new
        // executable path under a new version directory — is torn down too: the
        // running process is the *old* install, whose directory the engine is about
        // to delete.
        func isStale(_ serverID: String) -> Bool {
            after[serverID] == nil || after[serverID] != before[serverID]
        }

        failures = failures.filter { !isStale($0.key.serverID) }
        unavailable = unavailable.filter { !isStale($0.serverID) }

        let dead = Set(sessions.keys).union(pendingLaunches.keys).filter { isStale($0.serverID) }
        guard !dead.isEmpty else { return }

        // D33, for the registry's half of it: a stale server's diagnostics die
        // with it, before any goodbye — both halves below tear something down
        // (a live session, or a launch that already registered), and neither
        // waits politely before the model is told. Emitted once per dead key up
        // front; a key whose pending launch never registered simply clears
        // nothing. The cancelled consumers stay silent on their way out.
        for key in dead {
            notificationTasks[key]?.cancel()
            notificationTasks[key] = nil
            onDiagnostics?(.cleared(.server(serverID: key.serverID, root: key.root)))
        }

        // Every map a `prepare` reads is emptied *before* the first hop, so one
        // racing this call finds nothing to hand out rather than a session that is
        // on its way to being shut down — `shutdownAll()`'s ordering, applied to a
        // subset. `transports` is the exception, for the reason spelled out below;
        // no reader consults it, so leaving it populated hands nothing out.
        var live: [ServerKey: LSPSession] = [:]
        var liveTransports: [ServerKey: LSPTransport] = [:]
        var inflight: [ServerKey: PendingLaunch] = [:]
        var open: [String: DocumentState] = [:]
        for key in dead {
            if let session = sessions.removeValue(forKey: key) {
                live[key] = session
                // Every transport stays in `transports` for now — the session's, and
                // a pending launch's alike. A transport registered there is the only
                // thing `terminateNow()` can reach a process through, and a process
                // here is alive until the `await` that stops it returns: the
                // handshake this method waits out for a pending launch is the slowest
                // thing this layer does, and the shutdown it waits out for a live
                // session runs a whole request budget. Dropping either one now would
                // leave a live process unreachable for that whole window, so a quit
                // inside it orphans exactly what `terminateNow()` exists to kill.
                // Both loops below clear their own, once the process is actually
                // dead and under the same identity guard.
                liveTransports[key] = transports[key]
            }
            if let pending = pendingLaunches.removeValue(forKey: key) { inflight[key] = pending }
        }
        for (uri, state) in documents where dead.contains(state.serverKey) {
            open[uri] = state
            documents[uri] = nil
        }

        for (key, session) in live {
            for (uri, state) in open where state.serverKey == key {
                try? await session.didClose(LSPDidCloseTextDocumentParams(uri: uri))
            }
            await session.shutdown()
            if let transport = liveTransports[key] { forget(transport, for: key) }
        }

        // A launch that had not finished when the registry moved. The epoch is
        // deliberately *not* bumped for it — that token supersedes every launch in
        // flight, including the ones for servers this update left untouched, and
        // killing a healthy server's handshake because an unrelated one was
        // installed is the opposite of what this method is for. So the launch runs
        // to completion and is unregistered and shut down here afterwards.
        //
        // Every one of those three unregistrations is guarded by an identity check,
        // and the guard is the point: this loop awaits, so a second `updateRegistry`
        // (remove then reinstall from the Settings surface) can have re-registered the
        // *same* key with a live session, a live transport and open documents before we
        // wake. Clearing them unconditionally would drop the new server's transport out
        // of `terminateNow()`'s reach — the orphan process this whole method exists to
        // prevent — and forget documents it has open.
        //
        // The transport takes `forget`'s check rather than the session's, because the
        // two can disagree. Taking a launch out of `pendingLaunches` above is what lets
        // a second launch start for the same key, and a transport is registered
        // *before* its handshake while a session is filed only after: the second launch
        // can therefore own `transports[key]` while `sessions[key]` is still the first
        // one's — the one moment `sessions[key] === orphan` is true and the entry is
        // somebody else's. Clearing it there leaves the second server serving requests
        // with nothing for a quit to reach, which is the same orphan by a longer route.
        for (key, pending) in inflight {
            guard let orphan = await pending.task.value else { continue }
            guard sessions[key] === orphan else { await orphan.shutdown(); continue }
            sessions[key] = nil
            documents = documents.filter { $0.value.serverKey != key }
            // The transport is cleared *after* the goodbye, not before it, for the
            // reason the collection loop above states and the live-session loop
            // already obeys: `shutdown()` waits out a whole request budget against
            // a process that is still running, and `transports` is the only map
            // `terminateNow()` reads. Unregistering here — the obvious place,
            // beside the other two — would leave this launch alive and unreachable
            // for that entire window, which is the orphan the branch exists to
            // prevent, reached by the one path that had finished handshaking.
            await orphan.shutdown()
            forget(orphan.transport, for: key)
        }
    }

    /// The descriptions a registry can actually route to, by id.
    ///
    /// Keyed off `servedLanguages` rather than `descriptions` because the registry
    /// resolves first-registration-wins per language: a description that is shadowed
    /// for *every* language it claims can never be launched again, so for the
    /// purposes of "is this still the server?" it is gone, and its process should go
    /// with it.
    private static func reachableDescriptions(
        in registry: LSPServerRegistry
    ) -> [String: LSPServerDescription] {
        var map: [String: LSPServerDescription] = [:]
        for language in registry.servedLanguages {
            guard let description = registry.description(for: language) else { continue }
            map[description.id] = description
        }
        return map
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
    ///
    /// `forceFlush` retires that no-op for one caller: the diagnostics sync
    /// (D30). A push-only server publishes when a notification *arrives*, and any
    /// other flusher landing first — a completion at its shorter debounce, a
    /// hover, a definition — has already told the server this exact text without
    /// leaving behind an accepted push: its version moved past the model's sync
    /// record, so the gate rejected the publish it provoked, and the settling
    /// sync arriving afterwards would find nothing to send and nothing coming.
    /// One more full-text `didChange` — bytes identical, version bumped — is what
    /// keeps D32's self-correction unconditional: every settled burst ends with a
    /// notification the server must answer, whose push the gate accepts, because
    /// the sync record is written from exactly this returned version. Providers
    /// keep the default: their question itself needs no second notification.
    public func prepare(
        url: URL,
        language: SyntaxLanguage,
        text: String,
        forceFlush: Bool = false
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
                // Resolved from the *file*, not the language: `.tsx` and `.jsx`
                // share a `SyntaxLanguage` case with their plain counterparts but
                // not an LSP id (see `lspLanguageID(forFileNamed:)`).
                languageID: language.lspLanguageID(forFileNamed: url.lastPathComponent),
                session: session,
                key: key,
                forceFlush: forceFlush
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
    ///
    /// `forceFlush` is the diagnostics sync's flag (see `prepare`): it only ever
    /// turns the identical-text no-op into a version-bumping full-text
    /// `didChange`, so a push-only server has one more notification to answer.
    private func flush(
        uri: String,
        text: String,
        languageID: String,
        session: LSPSession,
        key: ServerKey,
        forceFlush: Bool
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
        // claiming anything, so the common path allocates nothing. A forced flush
        // (D30's settling sync) declines it: its whole purpose is to provoke one
        // more publish when somebody else already delivered this text.
        if let state = documents[uri], state.serverKey == key,
           state.text == text, !forceFlush {
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
                        languageID: languageID,
                        session: session,
                        key: key,
                        forceFlush: forceFlush
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
        languageID: String,
        session: LSPSession,
        key: ServerKey,
        forceFlush: Bool
    ) async throws -> Int {
        if let state = documents[uri], state.serverKey == key {
            if state.text == text, !forceFlush { return state.version }
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
                    languageId: languageID,
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
        // D33's per-document rule: the last tab on the file closed, and its set
        // goes with it — emitted whether or not a session survives to be told
        // (the editor's copy of the document is gone either way).
        onDiagnostics?(.cleared(.document(url: url)))
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
                rootPath: LSPWorkspace.rootPath(for: root),
                initializationOptions: description.initializationOptions,
                configuration: description.configuration
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
                // D33's unavailability rule: the key is retired for the app run,
                // so whatever a *predecessor* life of it left on screen goes too.
                // This attempt never registered, so the clear is for the dead
                // lives before it.
                onDiagnostics?(.cleared(.server(serverID: key.serverID, root: key.root)))
                return nil
            }
            guard sessions[key] == nil else {
                // Someone else is already filed under this key. Normally
                // impossible — `liveSession` reuses a live session and
                // `pendingLaunches` coalesces concurrent starts — but D16's
                // `updateRegistry` takes a launch *out* of `pendingLaunches`
                // without stopping it, so a remove-then-reinstall can start a
                // second process for the same key while this one is still
                // handshaking. Registering over it would leave that newer
                // process running with nothing pointing at it: the orphan
                // `terminateNow()` could not reach. The epoch cannot express
                // this — it is deliberately not bumped by a registry update —
                // so the check is identity, like every other one here.
                await session.terminate()
                forget(transport, for: key)
                return nil
            }
            sessions[key] = session
            // The push channel opens with the session, not with the first
            // request: from here on this server may say things nobody asked for,
            // and its consumer must already be listening.
            attachNotificationConsumer(for: key)
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
        // D33: its diagnostics die with it too — synchronously, in this same
        // mutation prefix, so the editor's surfaces blank in the turn the crash
        // was noticed rather than whenever the consumer task next runs. The task
        // is cancelled here and stays silent on its way out; this is the clear.
        // (If the consumer's stream finished first, it has already spoken for
        // the crash; the two can both fire depending on which noticed first,
        // which is fine: a clear is idempotent, and every sink must treat D33's
        // clears as at-least-once.)
        notificationTasks[key]?.cancel()
        notificationTasks[key] = nil
        onDiagnostics?(.cleared(.server(serverID: key.serverID, root: key.root)))
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
            // D33's last teardown site: a spent budget retires the key, and the
            // key's diagnostics go with it. Usually a duplicate of the clear
            // `noteDeath` emitted one line earlier for this same crash; it is
            // the *only* one on the launch-failure path, where no session ever
            // died but a predecessor's answers may still be on screen.
            onDiagnostics?(.cleared(.server(serverID: key.serverID, root: key.root)))
            return false
        }
        return true
    }

    // MARK: - Notifications (D29)

    /// Attach the one per-session notification consumer (D29), held in
    /// `notificationTasks` beside the session.
    ///
    /// Called from `launch` the moment a session is filed under its key, so the
    /// stream has its consumer before the first request goes out — a real
    /// server may push diagnostics for the `didOpen` well before the flush that
    /// carried it returns. Cancelled by every teardown path (each of which
    /// emits the key's clear itself); left to run out on its own only when the
    /// stream finishes under it, which is how an externally-killed server is
    /// noticed (D33).
    private func attachNotificationConsumer(for key: ServerKey) {
        guard let session = sessions[key] else { return }
        notificationTasks[key]?.cancel()
        let stream = session.notifications
        notificationTasks[key] = Task { @MainActor [weak self] in
            for await notification in stream {
                guard let self else { return }
                self.route(notification, from: key)
            }
            guard let self, !Task.isCancelled else { return }
            // The stream finishing is the crash/exit signal (D33): EOF or a
            // framing error ended the conversation without any of the deliberate
            // teardowns below having spoken. Skipped when a *replacement* session
            // now owns the key — its pushes have already re-published, and
            // clearing for the dead predecessor would wipe them. A `noteDeath`
            // that notices the same crash later emits its own clear; both are
            // fine (idempotent, at-least-once), as documented there.
            if let filed = self.sessions[key], filed !== session { return }
            self.onDiagnostics?(.cleared(.server(serverID: key.serverID, root: key.root)))
        }
    }

    /// Decode one notification and, when it survives D31's gates, hand the
    /// mapped set to the sink. Every other method is ignored, as before.
    ///
    /// The gates, in order: the URI must be one **this** `(server, root)`
    /// currently holds — a push for a closed file, a file another server owns,
    /// or a file nobody opened is noise — and the version, when the server sent
    /// one, must be the one this workspace last gave it. A push that passes both
    /// is mapped against the text the server was *told* (`documents[uri].text`),
    /// not the live buffer: the editor's copy may already have moved on, and
    /// reconciling that difference is ``DiagnosticShift``'s job downstream, in
    /// the model — never a remap here.
    private func route(_ notification: LSPServerNotification, from key: ServerKey) {
        guard notification.method == LSPMethod.publishDiagnostics else { return }
        guard let params = notification.params,
              let push = try? params.decoded(as: LSPPublishDiagnosticsParams.self) else { return }
        guard let state = documents[push.uri], state.serverKey == key else { return }
        if let version = push.version, version != state.version { return }

        // The URI round-trips through URL here once, at the boundary: everything
        // downstream (the store's keys, the panel's paths) speaks URL, and a URI
        // that does not parse names no file this editor opened.
        guard let url = URL(string: push.uri) else { return }
        let content = state.text as NSString
        let lineStarts = LSPPositionMap.lineStarts(in: content)
        let diagnostics = push.diagnostics.compactMap {
            Diagnostic.make(from: $0, in: content, lineStarts: lineStarts, url: url)
        }
        onDiagnostics?(.published(
            url: url,
            serverID: key.serverID,
            root: key.root,
            version: push.version,
            diagnostics: diagnostics
        ))
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

    /// The same root as a file-system path, for the servers that read the
    /// deprecated `rootPath` and nothing else (`LSPInitializeParams.rootPath`
    /// carries the whole reason). Standardized like `rootURI` and *not*
    /// symlink-resolved for `documentURI`'s reason — the two must name the same
    /// directory, or a server would resolve imports under one spelling and be
    /// handed documents under another. No trailing slash: this is a path, and
    /// pyright hands it to `Uri.file` where a trailing separator would become an
    /// empty last component.
    nonisolated static func rootPath(for root: URL) -> String {
        root.standardizedFileURL.path
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

/// What the diagnostics channel says, in one value: an accepted push, or the
/// clear that follows a teardown (D33).
///
/// This is the whole output side of the push channel — ``LSPWorkspace/onDiagnostics``'s
/// payload. `published` carries the set already mapped onto buffer offsets
/// against the text the server was told (D31); what happens to it next —
/// accepted against sync bookkeeping or dropped (D32) — is downstream. The
/// `serverID`/`root` pair mirrors `DiagnosticStore.ServerKey` so a clear can be
/// keyed exactly as the store keys its provenance; `published` spells both
/// halves out rather than carrying that store type so this file keeps speaking
/// its own vocabulary.
public enum LSPDiagnosticEvent: Equatable, Sendable {
    /// An accepted push for a held document, mapped to UTF-16 buffer offsets.
    /// `version` is the wire value verbatim (`nil` when the server sent none);
    /// the model's acceptance gate reads it against its last sync.
    case published(
        url: URL,
        serverID: String,
        root: String,
        version: Int?,
        diagnostics: [Diagnostic]
    )
    /// Something was torn down and its diagnostics go with it. One case with an
    /// explicit scope rather than two overloads of `.cleared` because Swift
    /// cannot pattern-match same-named cases against each other — the switch
    /// would resolve every `.cleared` to whichever shape was declared last.
    ///
    /// - `server`: every diagnostic one `(server, root)` produced dies with it
    ///   — a death, a shutdown, an un-registration, the fourth-failure
    ///   unavailability, the externally-killed-server signal.
    /// - `document`: one document left the editor (`didClose`) and its set goes
    ///   with it.
    case cleared(Cleared)

    /// The scope a ``cleared`` event names.
    public enum Cleared: Equatable, Sendable {
        case server(serverID: String, root: String)
        case document(url: URL)
    }
}
