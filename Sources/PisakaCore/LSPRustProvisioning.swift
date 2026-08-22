import Foundation

/// Finding the Rust toolchain and any rust-analyzer already on this machine
/// (D23).
///
/// **The seam carries an answer, not a search.** Every candidate location — the
/// inherited `PATH`, `~/.cargo/bin`, Homebrew's prefixes, the login shell's own
/// `$PATH` — is machine-specific knowledge of exactly the kind D9 keeps out of
/// Core, and confirming a find by running `cargo --version` means running a
/// process, which Core may not do at all. So the app searches and Core is handed
/// an `LSPRustToolchainReport`; every *rule* about what that report permits lives
/// in the model below and is unit-tested with no Rust toolchain anywhere in
/// sight.
///
/// **There is deliberately no second seam.** gopls needed one because it is built
/// rather than downloaded; rust-analyzer publishes official prebuilt binaries, so
/// the install is `LSPInstallEngine.install(_:)` over the pinned manifest
/// component and the two seams 2b already has (D21). This protocol is the whole
/// of what Rust adds.
///
/// The implementation is expected to cache its answer per app run **including the
/// negative one** and to resolve off the main thread — `LSPToolchain`'s
/// discipline, for `LSPToolchain`'s reason. The model calls this exactly once and
/// holds what it got, so the caching is belt and braces rather than the thing
/// this design depends on.
public protocol LSPRustToolchainDiscovering: Sendable {
    func discover() async -> LSPRustToolchainReport
}

/// Everything decision-shaped about rust-analyzer: what state it is in, whether
/// it may be offered, what the Settings row may do, and what the registry gets
/// (D21–D24).
///
/// **A third registry contributor, not a third provisioning layer.** What this
/// reuses from 2b is everything that was already generic and string-keyed: the
/// pinned `LSPComponent`, `LSPInstallEngine.install(_:)`/`state(of:)`/
/// `pendingDownloadByteCount(for:)`/`remove(_:)`, `LSPInstallLayout`'s path math,
/// the download and unpack seams, the stage-then-one-rename atomicity (D13), the
/// push-then-delete removal ordering (D16), `LSPServerConsent` under one id in
/// the same `SettingsStore` dictionary (D15), and the failure philosophy — a
/// sentence in a row, a Retry, and no alert ever. What it does *not* reuse is
/// `LSPProvisioningModel`, whose row has no way to say "no Rust toolchain"
/// (D21). `LSPDownloadableServer` is therefore untouched, and its set-equality
/// tests go on saying exactly what they said before.
///
/// **A reader, like the rest of this layer.** It walks its own install root and
/// touches nothing of the user's, so it takes no `autosave.suspend()` /
/// `localChanges.beginRevert()` gate and is not gated by one.
@MainActor
public final class LSPRustProvisioningModel: ObservableObject {
    /// The Settings tab's whole view of rust-analyzer.
    @Published public private(set) var row: LSPRustServerRow

    /// This contributor's share of the registry: one description, or none.
    ///
    /// An array rather than an optional because that is what the composition site
    /// wants — `LSPServerRegistry(provisioning.registry.descriptions +
    /// gopls.descriptions + rust.descriptions)` — and because it keeps the
    /// "contributes nothing" case from needing a `compactMap` at every call site.
    @Published public private(set) var descriptions: [LSPServerDescription] = []

    /// Called with the new descriptions every time they actually change, and
    /// awaited.
    ///
    /// Awaited for `LSPProvisioningModel.onRegistryChange`'s reason: `remove()`
    /// publishes *without* rust-analyzer before deleting anything, because the
    /// push is what shuts the running server down (D16), and deleting an
    /// executable out from under a live server leaves exactly the orphan the
    /// release check greps for.
    public var onDescriptionsChange: (([LSPServerDescription]) async -> Void)?

    private let discovery: LSPRustToolchainDiscovering
    private let engine: LSPInstallEngine
    private let settings: SettingsStore

    /// What the app found, or `nil` until it has answered — the `pending` half of
    /// the lifecycle, and the reason the row has a `pending` status at all.
    private var report: LSPRustToolchainReport?

    /// The one discovery, kept so a second `discover()` awaits the first rather
    /// than starting another. This is what makes the answer — including "no Rust
    /// toolchain" — a per-app-run fact on Core's side too, and not only inside
    /// whatever cache the seam keeps.
    private var discoveryTask: Task<Void, Never>?

    private struct PendingAttempt {
        let id: Int
        let task: Task<Void, Never>
    }

    /// The attempt *this model* started, distinct from the engine's own
    /// per-component table for `LSPProvisioningModel.attempts`' reason: the row
    /// must read "installing…" from the moment the user says yes, including the
    /// window before the engine has claimed anything.
    private var attempt: PendingAttempt?
    private var attemptCounter = 0

    private struct Failure {
        let message: String
        let wasRemoval: Bool
    }

    private var failure: Failure?
    private var isRemoving = false

    public init(
        discovery: LSPRustToolchainDiscovering,
        engine: LSPInstallEngine,
        settings: SettingsStore
    ) {
        self.discovery = discovery
        self.engine = engine
        self.settings = settings
        row = LSPRustServerRow(
            status: .pending,
            consent: settings.consent(for: LSPRustAnalyzer.componentID)
        )
        updateRow()
    }

    // MARK: - Discovery

    /// Ask the app where `cargo` and rust-analyzer are, once per app run.
    ///
    /// Called at startup (`LSPToolchain.prewarm()`'s position) so the answer is
    /// there before the first `.rs` file is opened; safe to call again from
    /// anywhere, because every later call awaits the first one's task and re-runs
    /// nothing.
    ///
    /// The row and the descriptions are updated *inside* the task rather than
    /// after awaiting it, so a second caller that joins mid-flight returns to
    /// finished state rather than to a row the first caller has not published
    /// yet.
    public func discover() async {
        if let discoveryTask { return await discoveryTask.value }
        let task = Task { @MainActor in
            let found = await discovery.discover()
            report = found
            updateRow()
            await publish()
        }
        discoveryTask = task
        await task.value
    }

    // MARK: - Reading

    /// The pinned record this model acts on, or `nil` for a manifest that does
    /// not describe it — in which case nothing is offered, installed or
    /// registered, which is this layer's uniform answer to data it cannot act on.
    private var component: LSPComponent? {
        LSPRustAnalyzer.component(in: engine.manifest)
    }

    /// Which rust-analyzer answers right now, or none.
    ///
    /// **The app's own copy wins** (D24). It is the version this app pinned and
    /// verified, and the only one Remove may touch; preferring the other would
    /// make Remove delete a copy that was not in use.
    public var installation: LSPRustAnalyzerInstallation? {
        if
            let component,
            engine.isInstalled(component.id),
            let executable = engine.layout.executable(of: component) {
            return .appInstalled(version: component.version, path: executable.path)
        }
        if let path = report?.discoveredRustAnalyzerPath { return .discovered(path: path) }
        return nil
    }

    /// May the banner offer rust-analyzer for `language`, and at what size?
    ///
    /// The pure rule over four facts: the language is Rust, the manifest
    /// describes the component, there is a `cargo` for the server to drive with
    /// nothing installed yet, and the question has not been answered. Anything
    /// else — no toolchain, declined, already accepted, a rust-analyzer already
    /// on the machine, an install in flight — answers `nil`, which is how a
    /// banner with no dismiss button nonetheless never appears twice.
    ///
    /// Read off the published `row` rather than re-derived from the disk, for
    /// `LSPProvisioningModel.consentPrompt(forOpening:)`'s reason: the banner
    /// asks this from its `body`, so a version that listed directories would do
    /// so on every keystroke for as long as the question stayed open.
    public func consentPrompt(forOpening language: SyntaxLanguage) -> LSPRustConsentPrompt? {
        guard language == .rust, row.status == .notInstalled, row.consent == .unasked else {
            return nil
        }
        guard let component else { return nil }
        return LSPRustConsentPrompt(
            displayName: LSPRustAnalyzer.displayName,
            version: component.version,
            downloadByteCount: row.pendingDownloadByteCount
        )
    }

    // MARK: - Answering

    /// The silent half of D15: a rust-analyzer the user has *already* accepted is
    /// downloaded when a Rust file is opened, without asking again.
    ///
    /// Called on every tab open, so it does nothing in every common case — not a
    /// Rust file, no toolchain, already installed, declined, or not yet asked
    /// (which is the banner's business).
    ///
    /// **An attempt that already failed this app run is not retried here.** The
    /// guard is the whole difference between "installs on first use" and a retry
    /// loop: a failed install leaves nothing installed, so without it every
    /// switch back to a `.rs` tab would start another 13 MB download — and
    /// `install()` clears the row's `failureMessage` before each attempt, so the
    /// one place D15 reports the failure would be wiped by the very tab switch
    /// that re-triggered it. The budget is "once per app run, automatically"; the
    /// Settings row's Retry stays unconditional, and so does the next launch.
    ///
    /// A failed **removal** is not that failure and suppresses nothing. It leaves
    /// consent `accepted` — only a *successful* removal declines — and the state
    /// it can leave behind, the pinned version gone while some other version
    /// directory refused to go, is one an install fixes rather than one it
    /// repeats. The button beside the sentence already draws this distinction
    /// (`failureWasRemoval`); the guard draws the same one rather than reading
    /// "some failure happened".
    public func prepareForOpening(_ language: SyntaxLanguage) async {
        guard
            language == .rust,
            settings.consent(for: LSPRustAnalyzer.componentID) == .accepted
        else { return }

        // Discovery is *awaited* here rather than read off `report`, and that is
        // load-bearing rather than tidy — `LSPGoplsProvisioningModel`'s reason
        // verbatim. It is kicked off unawaited at launch and costs a subprocess,
        // up to a login shell, while this runs from the banner's `.task`, which
        // fires within milliseconds of the first render. A restored `.rs` tab
        // therefore regularly arrives before the answer does, and a `report`
        // still `nil` at that moment would decline silently *for the whole app
        // run*: the trigger this runs under does not fire again until the
        // language or the project root changes, and nothing else calls this.
        // `discover()` coalesces onto the one task, so every call after the first
        // is free — and the non-Rust guard above keeps that out of the ordinary
        // tab open.
        await discover()

        guard
            failure?.wasRemoval != false,
            report?.hasToolchain == true,
            installation == nil
        else { return }
        await install()
    }

    /// "Download" in the banner: record the answer and install.
    public func accept() async {
        await install()
    }

    /// "No Thanks" in the banner: record the answer and do nothing else, ever.
    /// Nothing is downloaded, nothing is registered, and Rust goes on being
    /// answered by the tree-sitter index.
    public func decline() {
        settings.setConsent(.declined, for: LSPRustAnalyzer.componentID)
        updateRow()
    }

    /// Download and install rust-analyzer, from the banner's Download or the
    /// Settings row's Install/Retry.
    ///
    /// Installing *is* consent, so this records `accepted` first, for
    /// `LSPProvisioningModel.install(_:)`'s reason: the Settings row is the one
    /// place a declined server is turned around, and it would be a strange kind
    /// of turning around that installed the server and then let the next launch
    /// decline to keep it.
    ///
    /// **Without a toolchain it does nothing at all** — not a download, not a
    /// recorded failure, not a recorded consent (D23). A rust-analyzer with no
    /// `cargo` to shell out to answers almost nothing while every request through
    /// it spends D7's restart budget finding that out, no view offers the action
    /// in that state, and a row reading "no Rust toolchain" beside a sentence
    /// about a download that did not happen would be describing an attempt nobody
    /// made.
    ///
    /// Failure is absorbed here and nowhere else (D15): it becomes the row's
    /// `failureMessage` and the row goes back to "not installed", with Retry
    /// available. Nothing throws out of this method.
    public func install() async {
        guard !isRemoving, report?.hasToolchain == true, let component else { return }
        settings.setConsent(.accepted, for: LSPRustAnalyzer.componentID)

        // Coalesced, with the claim made synchronously between the check and the
        // store: two accepts — the banner's button and the Settings row's, or a
        // tab open landing on the banner's — must produce one download and one
        // `installing` row.
        let task: Task<Void, Never>
        if let existing = attempt {
            task = existing.task
        } else {
            failure = nil
            attemptCounter += 1
            let id = attemptCounter
            task = Task { @MainActor [engine] in
                do {
                    try await engine.install(component.id)
                } catch {
                    self.failure = Failure(message: error.localizedDescription, wasRemoval: false)
                }
                // Released from inside the task body, and only while it is still
                // ours — `LSPInstallEngine.install`'s rule, for its reason: a
                // Retry that adopted a *finished* task would return immediately
                // and install nothing while the row updated as though it had.
                if self.attempt?.id == id { self.attempt = nil }
            }
            attempt = PendingAttempt(id: id, task: task)
            updateRow()
        }

        await task.value
        updateRow()
        await publish()
    }

    /// Remove this app's own copy — and only ever that one.
    ///
    /// The order is the point: **push, then delete** (D16). The push is what
    /// stops the running server; only once it has returned may the files it was
    /// running from go away.
    ///
    /// Consent becomes `declined`, the only answer that describes what just
    /// happened operationally: leaving it `accepted` would have the next `.rs`
    /// file silently re-download what the user just removed. It gates
    /// *installing* and nothing else, so a machine that also has a rustup
    /// rust-analyzer goes straight back to using that one — which is right, since
    /// this app neither put it there nor was asked about it.
    ///
    /// Refuses when there is nothing under the install root (`canRemove` says so
    /// too, and this is the half that does not depend on a view): a binary in
    /// `~/.cargo/bin` is not this app's to delete, and `engine.remove` would not
    /// touch it anyway — it only ever deletes inside the install root. What it
    /// *does* reclaim is every version directory there, including one a pin bump
    /// stranded, which is why the guard is "are there files" rather than "is the
    /// pinned version installed" (`LSPRustServerRow.hasFilesOnDisk`).
    ///
    /// **Re-entrant calls and calls during an install return immediately**, for
    /// `LSPProvisioningModel.remove(_:)`'s reasons: the push suspends for as long
    /// as the shutdown takes, and a second call arriving in that window would
    /// find the descriptions already published and walk straight into deleting
    /// the executable the first call is still politely stopping.
    public func remove() async {
        guard
            !isRemoving,
            attempt == nil,
            engine.state(of: LSPRustAnalyzer.componentID) != .absent
        else { return }
        isRemoving = true
        updateRow()
        await publish()

        do {
            try engine.remove(LSPRustAnalyzer.componentID)
            failure = nil
            settings.setConsent(.declined, for: LSPRustAnalyzer.componentID)
        } catch {
            failure = Failure(message: error.localizedDescription, wasRemoval: true)
        }

        isRemoving = false
        updateRow()
        await publish()
    }

    // MARK: - Deriving

    private func updateRow() {
        row = LSPRustServerRow(
            status: status(),
            consent: settings.consent(for: LSPRustAnalyzer.componentID),
            failureMessage: failure?.message,
            failureWasRemoval: failure?.wasRemoval ?? false,
            version: component?.version ?? "",
            licenseSPDX: component?.licenseSPDX ?? "",
            pendingDownloadByteCount: engine.pendingDownloadByteCount(
                for: LSPRustAnalyzer.componentID
            ),
            hasFilesOnDisk: engine.state(of: LSPRustAnalyzer.componentID) != .absent,
            isRemoving: isRemoving
        )
    }

    private func status() -> LSPRustServerRow.Status {
        guard let report else { return .pending }
        guard report.hasToolchain else { return .noToolchain }
        // This model's own attempt first, then the engine's: the window between a
        // user saying yes and the engine claiming the component belongs to the
        // row as much as the download does.
        if attempt != nil { return .installing }
        // The engine's answer covers an install of *this* component that this
        // model did not start. Nothing in the app reaches it today — every
        // rust-analyzer install goes through `install()` above, whose attempt
        // outlives the engine's — and it is deliberately not tested as though
        // something did. It is here because the engine is shared and its state is
        // per component: a second reader of the same component would otherwise
        // read `.notInstalled` and offer Install over a download in flight, which
        // is the one wrong answer this row can give.
        if engine.state(of: LSPRustAnalyzer.componentID) == .installing { return .installing }
        switch installation {
        case let .appInstalled(version, _): return .appInstalled(version: version)
        case .discovered: return .discovered
        case nil: return .notInstalled
        }
    }

    /// What this contributor adds to the registry.
    ///
    /// A plain `.executable(path:)` entry with no arguments — rust-analyzer
    /// speaks LSP over stdio by default — under the same id the consent, the
    /// install root and `engine.remove` use. Core learns no paths and gains no
    /// launch kind (D9).
    ///
    /// **A toolchain is required even for a rust-analyzer the app did not
    /// install** (D23). The server shells out to `cargo` to build the project
    /// model, so without one it starts and answers almost nothing while every
    /// request through it spends D7's restart budget finding that out.
    /// Contributing nothing is the honest answer, and it is the same one the row
    /// gives.
    ///
    /// **And "a toolchain exists" is not the same as "rust-analyzer can find
    /// it."** It resolves `cargo` on its own `PATH`, and the `PATH` a
    /// Finder-launched app inherits is `launchd`'s four directories — so the
    /// discovered search path travels with the description as its environment
    /// overlay, and this guard requires it. Without that, every state above stays
    /// exactly as it reads and the server still answers nothing, which is the one
    /// failure the routing provider cannot see: an empty answer and a file with
    /// nothing in it are the same value at that seam.
    ///
    /// An *empty* search path is treated as no search path, `LSPGoplsProvisioningModel`'s
    /// rule and for its reason: contributing `PATH=""` would register a server
    /// that resolves *nothing* by name — strictly worse than the inherited
    /// environment this seam exists to improve on, and identical in the Settings
    /// row.
    private func makeDescriptions() -> [LSPServerDescription] {
        guard !isRemoving, let installation else { return [] }
        guard let searchPath = report?.searchPath, !searchPath.isEmpty else { return [] }
        return [
            LSPServerDescription(
                id: LSPRustAnalyzer.componentID,
                languages: [.rust],
                launch: .executable(path: installation.executablePath),
                environment: ["PATH": searchPath]
            ),
        ]
    }

    /// Published only when it actually changed, for
    /// `LSPProvisioningModel.publishRegistry()`'s reason: pushing an equal
    /// registry tears nothing down only because `updateRegistry(_:)` makes the
    /// same comparison, and relying on someone else's early return for
    /// correctness is how a later refactor kills a running server on a timer.
    private func publish() async {
        let next = makeDescriptions()
        guard next != descriptions else { return }
        descriptions = next
        await onDescriptionsChange?(next)
    }
}
