import Foundation

/// Whether the user has been asked about one downloadable server, and what they
/// said (D15).
///
/// Three cases, but only two *answers*: `unasked` is the state the banner is
/// allowed to interrupt from, and the banner has no dismiss — "asked once" means
/// the answer is one of the other two, forever, across launches. That is the
/// whole reason this is persisted rather than held in memory: a prompt that came
/// back every launch would be a prompt the user learns to dismiss without
/// reading, and there is nothing else in this app that asks to download 50 MB.
public enum LSPServerConsent: String, CaseIterable, Equatable, Sendable {
    /// Never asked, or asked and the answer was later forgotten (a removal that
    /// wanted to re-offer the server). Nothing downloads in this state.
    case unasked
    /// Install it, and keep installing it — an accepted server whose files are
    /// missing (a new pin, a de-provisioned directory) installs on first use
    /// without asking again.
    case accepted
    /// Leave this language on tree-sitter. Never prompts, never installs, and is
    /// turned around only from the Settings surface.
    case declined
}

/// What the consent banner needs in order to ask about one server, and nothing
/// else — a value, so the banner has no opinions and no access to the engine.
///
/// The size is `pendingDownloadByteCount`, not the component's own total: the
/// second server costs what is still missing, which is 4 MB rather than 56 once
/// `node` is there. Showing the gross figure would be asking permission for
/// bytes nobody is going to fetch.
public struct LSPConsentPrompt: Equatable, Sendable {
    public let server: LSPDownloadableServer
    public let displayName: String
    public let downloadByteCount: Int

    public init(server: LSPDownloadableServer, displayName: String, downloadByteCount: Int) {
        self.server = server
        self.displayName = displayName
        self.downloadByteCount = downloadByteCount
    }
}

/// One downloadable server as both surfaces see it.
///
/// The banner reads `displayName`/`pendingDownloadByteCount`, the Settings row
/// reads all of it, and neither reaches past this value into the engine or the
/// settings store. `state` is the *server's* state, not a component's: it is
/// `installed` only when the server **and** its runtime are on disk at the
/// pinned version, because that — and nothing weaker — is what makes a registry
/// entry startable.
public struct LSPServerRow: Equatable, Identifiable, Sendable {
    public let server: LSPDownloadableServer
    public let displayName: String
    public let languages: Set<SyntaxLanguage>
    public let consent: LSPServerConsent
    public let state: LSPInstallState
    /// Bytes still to fetch to make this server usable — 0 once it is installed.
    public let pendingDownloadByteCount: Int
    /// The last attempt's failure, or `nil` if the last attempt did not fail.
    ///
    /// This is the *whole* of the failure surface (D15's "raises nothing
    /// anywhere else"): a failed install is a sentence in a Settings row and a
    /// button that says Retry. It never alerts, never beeps and never changes
    /// what the editor does — the language was answering from tree-sitter before
    /// the attempt and still is.
    public let failureMessage: String?
    /// Whether `failureMessage` describes a failed *removal* rather than a failed
    /// install.
    ///
    /// One field rather than two message slots, because there is only ever one
    /// message: each attempt replaces the previous outcome. What it is for is the
    /// install button's label. A removal that deleted the server component and
    /// then failed on the shared runtime leaves the row `.absent` — installable,
    /// legitimately — beside a sentence about a directory that would not go away,
    /// and "Retry" on that button would offer to retry the removal while actually
    /// starting a ~52 MB download of the thing the user just asked to be rid of.
    public let failureWasRemoval: Bool
    /// Whether Remove would reclaim anything for this row — any version of this
    /// server's component, including one a pin bump has left stranded (servable
    /// by nothing, still occupying real disk), and the shared runtime when this
    /// row is the one that stranded it.
    public let hasFilesOnDisk: Bool
    /// Whether this server's files are being deleted right now.
    ///
    /// A removal is not instant: it publishes a registry without the server and
    /// *awaits* that push, which shuts a live session down (up to
    /// `LSPSession.Budgets.shutdown`) before the first byte is deleted (D16).
    /// The row has to say so, because a Remove button that stays live through
    /// that window is a second removal racing the first one's shutdown.
    public let isRemoving: Bool

    public var id: String { server.id }

    public var isInstalled: Bool {
        if case .installed = state { return true }
        return false
    }

    /// Install (or Retry) applies to a row with nothing servable on disk and
    /// nothing in flight — neither an install (which `state` already reports as
    /// `.installing`) nor a removal.
    ///
    /// The removal half is not covered by `state`: a removal that starts from the
    /// stranded-runtime state finds the server component `.absent` and keeps
    /// reading `.absent` all the way through, so without `!isRemoving` this row
    /// would offer Install beside its own "Removing…" and a spinner — and the
    /// action behind it would be an install racing a deletion of the runtime it
    /// needs.
    public var canInstall: Bool { state == .absent && !isRemoving }

    /// Remove applies to anything that has files, once nothing is in flight —
    /// removing mid-download would delete a directory the engine is about to
    /// rename onto, and removing mid-removal would delete one the *first*
    /// removal is still stopping a process on top of.
    public var canRemove: Bool { hasFilesOnDisk && state != .installing && !isRemoving }

    public init(
        server: LSPDownloadableServer,
        displayName: String,
        languages: Set<SyntaxLanguage>,
        consent: LSPServerConsent,
        state: LSPInstallState,
        pendingDownloadByteCount: Int,
        failureMessage: String?,
        hasFilesOnDisk: Bool,
        isRemoving: Bool = false,
        failureWasRemoval: Bool = false
    ) {
        self.server = server
        self.displayName = displayName
        self.languages = languages
        self.consent = consent
        self.state = state
        self.pendingDownloadByteCount = pendingDownloadByteCount
        self.failureMessage = failureMessage
        self.hasFilesOnDisk = hasFilesOnDisk
        self.isRemoving = isRemoving
        self.failureWasRemoval = failureWasRemoval
    }
}

/// The one thing that knows which servers exist, what state each is in, and what
/// the registry should therefore look like right now.
///
/// **Why a model and not two views doing their own arithmetic.** The consent
/// banner and the Settings surface ask overlapping questions ("may I offer
/// this?", "is it installing?", "how big is it?") and both can *answer* them
/// (accept, install, remove). Two independent readers of the engine would drift
/// the moment one of them acted — a banner accepting while a Settings row still
/// says "not installed" — and, worse, would each need their own opinion about
/// when to push a new registry. Everything decision-shaped is therefore here,
/// and the views are `rows`, `consentPrompt(forOpening:)` and four verbs.
///
/// **The registry is the output.** `registry` starts as the base one
/// (sourcekit-lsp, found through `xcrun`, which this layer neither provisions
/// nor can interfere with) and gains an entry per *installed* server. Every
/// change is pushed through `onRegistryChange`, which the app wires to
/// `LSPWorkspace.updateRegistry(_:)` — that is what makes an install servable
/// and a removal terminate its process without a restart (D16). The base entries
/// stay first, so a hand-registered override of a downloadable language keeps
/// winning (`LSPServerRegistry`'s first-registration-wins rule).
///
/// **A reader, like the rest of this layer.** It walks its own install root and
/// touches nothing of the user's, so it takes no `autosave.suspend()` /
/// `localChanges.beginRevert()` gate and is not gated by one.
@MainActor
public final class LSPProvisioningModel: ObservableObject {
    /// One row per downloadable server, in `LSPDownloadableServer.allCases`
    /// order — a fixed, stated order rather than one derived from state, so a
    /// Settings list does not reshuffle itself while an install runs.
    @Published public private(set) var rows: [LSPServerRow] = []

    /// The registry as it should be *now*: the base plus every installed server.
    @Published public private(set) var registry: LSPServerRegistry

    /// Called with the new registry every time it actually changes, and awaited.
    ///
    /// Awaited on purpose. `remove(_:)` publishes a registry without the server
    /// **before** deleting its files, because the push is what shuts the running
    /// process down (D16) and deleting an executable out from under a live
    /// process leaves exactly the orphan the release check greps for. That
    /// ordering is only real if the model can wait for the push to finish, which
    /// a fire-and-forget callback could not offer.
    public var onRegistryChange: ((LSPServerRegistry) async -> Void)?

    private let engine: LSPInstallEngine
    private let settings: SettingsStore
    private let baseRegistry: LSPServerRegistry

    /// An attempt in flight, with an id so the task that finishes clears its own
    /// slot and never a newer one's — the engine's `PendingInstall`, for the same
    /// reason.
    private struct PendingAttempt {
        let id: Int
        let task: Task<Void, Never>
    }

    /// Attempts this model started, keyed by server. Distinct from the engine's
    /// own in-flight table, which is per *component*: a row must read
    /// "installing…" from the moment the user says yes, including the window
    /// before the engine has claimed anything, and must keep reading it while a
    /// shared `node` that another server is already fetching is waited on.
    private var attempts: [LSPDownloadableServer: PendingAttempt] = [:]
    private var attemptCounter = 0

    /// The last attempt's outcome, when it failed — carrying *which* attempt it
    /// was, because the row's install button is labelled off it (`failureWasRemoval`).
    private struct Failure {
        let message: String
        let wasRemoval: Bool
    }

    private var failures: [LSPDownloadableServer: Failure] = [:]
    /// Servers whose files are being deleted right now — excluded from the
    /// registry so the pre-deletion push is a registry without them.
    private var removals: Set<LSPDownloadableServer> = []

    public init(
        engine: LSPInstallEngine,
        settings: SettingsStore,
        baseRegistry: LSPServerRegistry = .standard
    ) {
        self.engine = engine
        self.settings = settings
        self.baseRegistry = baseRegistry
        self.registry = baseRegistry
        updateRows()
    }

    // MARK: - Reading

    public func row(for server: LSPDownloadableServer) -> LSPServerRow? {
        rows.first { $0.server == server }
    }

    /// Everything, re-derived from the engine — the launch call, and the one
    /// anything outside this model makes after touching the install root.
    ///
    /// Publishing here is what makes a relaunch pick up what a previous run
    /// installed: the disk is the state (D12), so "restore the registry" is a
    /// directory listing and not a persisted copy of what was registered last
    /// time.
    public func refresh() async {
        updateRows()
        await publishRegistry()
    }

    /// May the banner offer `language`'s server, and at what size?
    ///
    /// A pure rule over three facts and nothing else: the language has a
    /// downloadable server, its consent is `unasked`, and there is nothing
    /// installed or installing. Anything else — declined, already accepted,
    /// already there, in flight — answers `nil`, which is how a banner that has
    /// no dismiss button nonetheless never appears twice.
    ///
    /// Read off the published `rows` rather than re-derived from the engine, and
    /// that is not a shortcut: the banner calls this from its `body`, so a version
    /// that asked the engine would run five synchronous directory listings on the
    /// main thread every time the editor re-rendered — on every keystroke, for as
    /// long as the question stays open. `rows` is recomputed at exactly the
    /// moments the answer can change (a decline, an install starting or finishing,
    /// a removal, the launch `refresh()`), so reading it is both cheaper and the
    /// same answer the Settings surface is showing.
    public func consentPrompt(forOpening language: SyntaxLanguage) -> LSPConsentPrompt? {
        guard let server = LSPDownloadableServer.serving(language) else { return nil }
        guard let row = row(for: server) else { return nil }
        guard row.consent == .unasked, row.state == .absent else { return nil }
        return LSPConsentPrompt(
            server: server,
            displayName: row.displayName,
            downloadByteCount: row.pendingDownloadByteCount
        )
    }

    // MARK: - Answering

    /// The silent half of D15: a server the user has *already* accepted installs
    /// when a file that needs it is opened, without asking again.
    ///
    /// Called on every tab open, so it must be cheap and must do nothing in the
    /// overwhelmingly common cases — no downloadable server for this language,
    /// already installed, declined, or not yet asked (which is the banner's
    /// business, not this method's).
    ///
    /// **An attempt that already failed this app run is not retried here**, and
    /// that guard is the whole difference between "installs on first use" and a
    /// retry loop. A failed install leaves the server `absent`, so without it every
    /// switch back to a `.ts` tab would start the same ~52 MB download again — the
    /// machine is offline, or a proxy is serving something that fails the digest,
    /// and neither of those changes because a tab did. Worse, `install(_:)` clears
    /// the row's `failureMessage` before each attempt, so the one place D15 reports
    /// the failure would be wiped by the very tab switch that re-triggered it. The
    /// budget is therefore "once per app run, automatically": the Settings row's
    /// Retry stays unconditional, and so does the next launch.
    public func prepareForOpening(_ language: SyntaxLanguage) async {
        guard
            let server = LSPDownloadableServer.serving(language),
            settings.consent(for: server.id) == .accepted,
            failures[server] == nil,
            state(of: server) == .absent
        else { return }
        await install(server)
    }

    /// "Download" in the banner: record the answer and install.
    public func accept(_ server: LSPDownloadableServer) async {
        await install(server)
    }

    /// "No Thanks" in the banner: record the answer and do nothing else, ever.
    /// No download, no registry push, no state to clean up — the language was
    /// answering from tree-sitter and continues to.
    public func decline(_ server: LSPDownloadableServer) {
        settings.setConsent(.declined, for: server.id)
        updateRows()
    }

    /// Install `server`, from the banner's Download or the Settings row's
    /// Install/Retry.
    ///
    /// Installing *is* consent, so this records `accepted` first: the Settings
    /// row is the one place a declined server can be turned around, and it would
    /// be a strange kind of turning around that installed the server and then
    /// let the next launch's `prepareForOpening` decline to keep it current.
    ///
    /// Failure is absorbed here and nowhere else (D15): it becomes the row's
    /// `failureMessage` and the row goes back to "not installed", with Retry
    /// available. Nothing throws out of this method, because there is no caller
    /// that could do anything more useful with an error than the row already
    /// does.
    ///
    /// **An install while this server is being removed returns immediately**, the
    /// symmetric half of `remove(_:)`'s own guard. Today it is a net over a state
    /// nothing reaches rather than a fix for one something does — `remove(_:)`
    /// suspends only inside the shutdown push, which happens *before* any deletion
    /// and therefore only for a server that is installed, so an install arriving
    /// there finds every component already on disk and does nothing anyway. It is
    /// written down all the same, in `mayDelete(_:)`'s mould: the reason it is
    /// currently unreachable is a fact about where the one `await` in `remove(_:)`
    /// happens to sit, and an install that landed after a deletion would record
    /// `accepted`, download, and commit a version directory into a tree the
    /// removal is about to finish clearing. `canInstall` hides the button for the
    /// same window; this is the half that does not depend on a view.
    public func install(_ server: LSPDownloadableServer) async {
        guard !removals.contains(server) else { return }
        settings.setConsent(.accepted, for: server.id)

        // Coalesce at this level too, not just in the engine: two accepts for one
        // server must produce one attempt *and* one `.installing` row, and the
        // claim is made synchronously between the check and the store.
        let task: Task<Void, Never>
        if let existing = attempts[server] {
            task = existing.task
        } else {
            failures[server] = nil
            attemptCounter += 1
            let id = attemptCounter
            task = Task { @MainActor [engine] in
                do {
                    try await engine.install(server)
                } catch {
                    self.failures[server] = Failure(
                        message: error.localizedDescription,
                        wasRemoval: false
                    )
                }
                // Released from inside the task body, and only while it is still
                // ours — the engine's rule (`LSPInstallEngine.install`), for the
                // same reason. Clearing it in the awaiting owner below instead
                // would leave a *finished* task sitting in the slot until that
                // continuation ran, and a Retry landing in that window would adopt
                // it, return immediately and install nothing while the row updated
                // as though it had.
                if self.attempts[server]?.id == id { self.attempts[server] = nil }
            }
            attempts[server] = PendingAttempt(id: id, task: task)
            updateRows()
        }

        await task.value
        updateRows()
        await publishRegistry()
    }

    /// Remove `server`, and the runtime with it when nothing else needs it.
    ///
    /// The order is the point: **push, then delete**. The push is what tears the
    /// running session down (D16); only once it has returned may the files it
    /// was running from go away.
    ///
    /// Consent becomes `declined`, which is the only answer that describes what
    /// just happened operationally — "do not install this, and do not ask me".
    /// Leaving it `accepted` would have the next `.ts` file silently download the
    /// server the user just removed; resetting it to `unasked` would re-prompt for
    /// it, which is the same interruption wearing a question mark. The Settings
    /// row is where it is turned around, and it says so.
    ///
    /// It is recorded **between the two deletions**, and that placement is the
    /// whole rule rather than a detail of ordering. Consent describes the server,
    /// so it must follow the fate of the server's own component and nothing else.
    /// A failed `engine.remove(serverComponentID)` records nothing: the files are
    /// still there and the push below re-registers them, so the server goes on
    /// serving, and "declined" is the one thing an installed, registered,
    /// actively-answering server is not. But once that call has returned, the
    /// server *is* gone — `makeRegistry()` will not re-register it and the row
    /// reads `.absent` — so a shared runtime that then refuses to delete must not
    /// roll the answer back with it. It would leave `accepted` describing a server
    /// with no files, and the next launch's `prepareForOpening` would silently
    /// re-download the ~52 MB the user just asked to be rid of, while this run's
    /// row offered a button labelled Retry that installs.
    ///
    /// Either failure is the row's `failureMessage`, exactly as a failed install
    /// is. Swallowing the first would be the one genuinely confusing outcome this
    /// surface can produce: the files are still there, so the very next
    /// `publishRegistry()` re-registers the server and restarts the process the
    /// push just stopped — a Remove that visibly undoes itself with nothing
    /// anywhere saying why.
    ///
    /// **Re-entrant calls return immediately**, and that guard is what makes the
    /// push-then-delete ordering real rather than nominal. The push suspends for
    /// as long as the shutdown takes; a second call arriving in that window finds
    /// the registry already published, so its own `publishRegistry()` returns
    /// without suspending at all and it walks straight into `engine.remove(…)` —
    /// deleting the executable out from under the session the first call is still
    /// politely stopping, which is the exact orphan this ordering exists to
    /// prevent. `canRemove` hides the button for the same window; this is the
    /// half that does not depend on a view.
    ///
    /// **A removal while this server is installing returns immediately too**, and
    /// for a sharper reason than tidiness. The state that makes both buttons
    /// appear on one row is the stranded runtime — server component absent, `node`
    /// on disk — where `canInstall` and `canRemove` are simultaneously true, so a
    /// Remove clicked off a row snapshot taken a frame before a Retry claimed the
    /// attempt would run against an install in flight. `engine.remove` would then
    /// no-op on the server component (nothing is committed yet, it is all still
    /// staging) and go straight on to delete the shared runtime, because
    /// `runtimeIsNeeded(byAnythingOtherThan:)` only ever asks about the *other*
    /// servers — this one's own attempt is excluded by construction. The install
    /// would then commit its artifact onto a deleted `node`, or, if the runtime was
    /// still staging and so nothing was deleted, commit both and leave a fully
    /// servable, registered server under the `declined` this removal just recorded.
    public func remove(_ server: LSPDownloadableServer) async {
        guard !removals.contains(server), attempts[server] == nil else { return }
        removals.insert(server)
        updateRows()
        await publishRegistry()

        do {
            try engine.remove(server.serverComponentID)
            failures[server] = nil
            settings.setConsent(.declined, for: server.id)
            try removeRuntimeIfUnused(after: server)
        } catch {
            failures[server] = Failure(message: error.localizedDescription, wasRemoval: true)
        }

        removals.remove(server)
        updateRows()
        await publishRegistry()
    }

    /// The shared runtime goes when the last server that needed it does.
    ///
    /// "Needs it" is *any files on disk*, not "installed at the pinned version":
    /// a server left stranded by a pin bump is one accepted install away from
    /// being current again, and deleting 50 MB of Node out from under it would
    /// turn that into a full re-download.
    ///
    /// An attempt this model is holding counts as needing it too. In practice the
    /// engine's own in-flight table already answers `installing` for anything
    /// being fetched, so this clause covers only the sliver between `install`
    /// claiming `attempts[server]` and the engine claiming the component — but
    /// "does a server still need the runtime" is this model's question, and
    /// answering it purely out of the engine's table makes the answer depend on
    /// which of two tasks the scheduler ran first. The attempts are what this
    /// model knows; they belong in the rule.
    private func removeRuntimeIfUnused(after server: LSPDownloadableServer) throws {
        guard !runtimeIsNeeded(byAnythingOtherThan: server) else { return }
        try engine.remove(server.runtimeComponentID)
    }

    private func runtimeIsNeeded(byAnythingOtherThan server: LSPDownloadableServer) -> Bool {
        let runtime = server.runtimeComponentID
        return LSPDownloadableServer.allCases.contains { other in
            other != server
                && other.runtimeComponentID == runtime
                && (attempts[other] != nil || engine.state(of: other.serverComponentID) != .absent)
        }
    }

    // MARK: - Deriving

    /// The state of a whole server: `installed` needs its own component *and*
    /// its runtime, because a registry entry names paths in both.
    ///
    /// `installing` is deliberately **not** inherited from the runtime. A second
    /// server that has been asked for really is installing while it waits for a
    /// shared `node` download — and reads so, because this model holds an attempt
    /// for it — but a server nobody has asked about must not announce itself as
    /// installing merely because the *other* one is fetching the runtime they
    /// would share. That row would offer no Install button, no Remove button and
    /// a spinner for work nobody requested.
    private func state(of server: LSPDownloadableServer) -> LSPInstallState {
        if attempts[server] != nil { return .installing }
        if engine.state(of: server.serverComponentID) == .installing { return .installing }
        if
            engine.isInstalled(server),
            let version = engine.manifest.component(server.serverComponentID)?.version
        {
            return .installed(version: version)
        }
        return .absent
    }

    private func updateRows() {
        rows = LSPDownloadableServer.allCases.map { server in
            LSPServerRow(
                server: server,
                displayName: server.displayName,
                languages: server.languages,
                consent: settings.consent(for: server.id),
                state: state(of: server),
                pendingDownloadByteCount: engine.pendingDownloadByteCount(for: server),
                failureMessage: failures[server]?.message,
                hasFilesOnDisk: hasReclaimableFiles(server),
                isRemoving: removals.contains(server),
                failureWasRemoval: failures[server]?.wasRemoval ?? false
            )
        }
    }

    /// Whether Remove would actually free disk for this row.
    ///
    /// The server's own component at any version, first — the stranded-pin case
    /// `hasFilesOnDisk` was written for.
    ///
    /// **And the shared runtime, when this row is what stranded it.** A server is
    /// two components installed in manifest order, and `node` commits by its own
    /// rename *before* the server's artifact is fetched: a download that dies on
    /// the 4 MB tarball after the 52 MB one landed leaves ~110 MB unpacked under a
    /// row that reads "not installed". Deriving this from the server component
    /// alone left `canRemove` false on every row in that state, so the only way
    /// out was the Finder — which the surface does name (D12: the disk is the
    /// state), but naming an escape hatch is not the same as the button being
    /// right. The runtime is deliberately *kept* rather than swept, so the retry
    /// costs 4 MB and not 56; this makes it reclaimable, not automatic.
    ///
    /// Gated on the server having been *answered about* — `accepted` or
    /// `declined`, i.e. anything but `unasked` — so the orphan is offered under a
    /// row the user has actually acted on and not under an untouched one that
    /// merely shares the runtime, and on nothing else needing it, which is
    /// `removeRuntimeIfUnused`'s own rule, so a row never offers a Remove that
    /// would reclaim nothing.
    ///
    /// **`declined` has to count, and that is not a widening for its own sake.**
    /// `remove(_:)` records the decline *between* the two deletions, so the one
    /// state that strands the runtime with no server left to explain it — the
    /// server component deleted, `removeRuntimeIfUnused` then throwing — is
    /// reached with consent already `declined`. Requiring `accepted` here made
    /// that state terminal: ~110 MB of unpacked Node on disk, `canRemove` false on
    /// every row, and the only way out the Finder — under a row whose own message
    /// says the removal failed. It survives relaunch too, because both halves of
    /// the answer are read off the disk (D12) rather than off an in-memory note of
    /// what went wrong.
    ///
    /// A row that was declined without ever being installed is unaffected: the
    /// runtime can only exist because something else fetched it, and
    /// `runtimeIsNeeded(byAnythingOtherThan:)` answers for that.
    private func hasReclaimableFiles(_ server: LSPDownloadableServer) -> Bool {
        if engine.state(of: server.serverComponentID) != .absent { return true }
        guard settings.consent(for: server.id) != .unasked else { return false }
        return engine.state(of: server.runtimeComponentID) != .absent
            && !runtimeIsNeeded(byAnythingOtherThan: server)
    }

    /// The base registry plus every installed server, pushed only when it is
    /// different from what was pushed last.
    ///
    /// The "only when different" guard is not an optimization:
    /// `LSPWorkspace.updateRegistry(_:)` tears down every session whose
    /// description changed, so pushing an equal registry on every refresh would
    /// be harmless only because that method makes the same comparison — and
    /// relying on someone else's early return for correctness is how a later
    /// refactor kills a running server on a timer.
    private func publishRegistry() async {
        let next = makeRegistry()
        guard next != registry else { return }
        registry = next
        await onRegistryChange?(next)
    }

    private func makeRegistry() -> LSPServerRegistry {
        var descriptions = baseRegistry.descriptions
        for server in LSPDownloadableServer.allCases {
            guard !removals.contains(server), engine.isInstalled(server) else { continue }
            guard
                let description = server.serverDescription(
                    manifest: engine.manifest,
                    layout: engine.layout
                )
            else { continue }
            descriptions.append(description)
        }
        return LSPServerRegistry(descriptions)
    }
}

extension LSPDownloadableServer {
    /// The server that would answer for `language`, if any.
    ///
    /// Pure, and `nil` for the overwhelming majority of languages — including
    /// `.swift`, whose server is found through `xcrun` and is not something this
    /// layer provisions, replaces or can interfere with. The served-language sets
    /// are disjoint (`LSPProvisioningManifestTests` pins that by set equality), so
    /// "the first that serves it" is "the one that serves it".
    public static func serving(_ language: SyntaxLanguage) -> LSPDownloadableServer? {
        allCases.first { $0.languages.contains(language) }
    }
}
