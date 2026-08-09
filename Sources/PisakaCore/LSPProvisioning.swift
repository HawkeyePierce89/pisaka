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
    /// Whether any version of this server's component is on disk — including one
    /// a pin bump has left stranded, which is servable by nothing but is still
    /// occupying real disk and must therefore be removable.
    public let hasFilesOnDisk: Bool

    public var id: String { server.id }

    public var isInstalled: Bool {
        if case .installed = state { return true }
        return false
    }

    /// Install (or Retry) applies to a row with nothing servable on disk and no
    /// attempt in flight.
    public var canInstall: Bool { state == .absent }

    /// Remove applies to anything that has files, once nothing is in flight —
    /// removing mid-download would delete a directory the engine is about to
    /// rename onto.
    public var canRemove: Bool { hasFilesOnDisk && state != .installing }

    public init(
        server: LSPDownloadableServer,
        displayName: String,
        languages: Set<SyntaxLanguage>,
        consent: LSPServerConsent,
        state: LSPInstallState,
        pendingDownloadByteCount: Int,
        failureMessage: String?,
        hasFilesOnDisk: Bool
    ) {
        self.server = server
        self.displayName = displayName
        self.languages = languages
        self.consent = consent
        self.state = state
        self.pendingDownloadByteCount = pendingDownloadByteCount
        self.failureMessage = failureMessage
        self.hasFilesOnDisk = hasFilesOnDisk
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

    /// Attempts this model started, keyed by server. Distinct from the engine's
    /// own in-flight table, which is per *component*: a row must read
    /// "installing…" from the moment the user says yes, including the window
    /// before the engine has claimed anything, and must keep reading it while a
    /// shared `node` that another server is already fetching is waited on.
    private var attempts: [LSPDownloadableServer: Task<Void, Never>] = [:]
    private var failures: [LSPDownloadableServer: String] = [:]
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
    public func prepareForOpening(_ language: SyntaxLanguage) async {
        guard
            let server = LSPDownloadableServer.serving(language),
            settings.consent(for: server.id) == .accepted,
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
    public func install(_ server: LSPDownloadableServer) async {
        settings.setConsent(.accepted, for: server.id)

        // Coalesce at this level too, not just in the engine: two accepts for one
        // server must produce one attempt *and* one `.installing` row, and the
        // claim is made synchronously between the check and the store.
        let task: Task<Void, Never>
        let isOwner: Bool
        if let existing = attempts[server] {
            task = existing
            isOwner = false
        } else {
            failures[server] = nil
            task = Task { @MainActor [engine] in
                do {
                    try await engine.install(server)
                } catch {
                    self.failures[server] = error.localizedDescription
                }
            }
            attempts[server] = task
            isOwner = true
            updateRows()
        }

        await task.value
        if isOwner { attempts[server] = nil }
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
    /// server the user just removed; resetting it to `unasked` would re-prompt
    /// for it, which is the same interruption wearing a question mark. The
    /// Settings row is where it is turned around, and it says so.
    ///
    /// A failed deletion is the row's `failureMessage`, exactly as a failed
    /// install is. Swallowing it would be the one genuinely confusing outcome
    /// this surface can produce: the files are still there, so the very next
    /// `publishRegistry()` re-registers the server and restarts the process the
    /// push just stopped — a Remove that visibly undoes itself with nothing
    /// anywhere saying why.
    public func remove(_ server: LSPDownloadableServer) async {
        removals.insert(server)
        updateRows()
        await publishRegistry()

        do {
            try engine.remove(server.serverComponentID)
            try removeRuntimeIfUnused(after: server)
            failures[server] = nil
        } catch {
            failures[server] = error.localizedDescription
        }

        removals.remove(server)
        settings.setConsent(.declined, for: server.id)
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
        let runtime = server.runtimeComponentID
        let stillNeeded = LSPDownloadableServer.allCases.contains { other in
            other != server
                && other.runtimeComponentID == runtime
                && (attempts[other] != nil || engine.state(of: other.serverComponentID) != .absent)
        }
        guard !stillNeeded else { return }
        try engine.remove(runtime)
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
                failureMessage: failures[server],
                hasFilesOnDisk: engine.state(of: server.serverComponentID) != .absent
            )
        }
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
