import Foundation

/// Finding the Go toolchain and any gopls already on this machine (D18).
///
/// **The seam carries an answer, not a search.** Every candidate location —
/// `$GOBIN`, `$GOPATH/bin`, `~/go/bin`, the login `PATH`, `/usr/local/go/bin`,
/// Homebrew's two prefixes — is machine-specific knowledge of exactly the kind
/// D9 keeps out of Core, and asking `go env` for the first two means running
/// `go`, which Core may not do at all. So the app searches and Core is handed an
/// `LSPGoToolchainReport`; every *rule* about what that report permits lives in
/// the model below and is unit-tested with no Go toolchain anywhere in sight.
///
/// The implementation is expected to cache its answer per app run **including
/// the negative one** and to resolve off the main thread — `LSPToolchain`'s
/// discipline, for `LSPToolchain`'s reason. The model calls this exactly once
/// and holds what it got, so the caching is belt and braces rather than the
/// thing this design depends on.
public protocol LSPGoToolchainDiscovering: Sendable {
    func discover() async -> LSPGoToolchainReport
}

/// Building one Go module's program into a directory (D20).
///
/// Deliberately generic — module path, version, the `go` to build with, and
/// where the binary is to land — rather than a `func installGopls()`. The seam
/// is then a description of what `go install` *is*, and the pin stays data in
/// `LSPGopls` where the update procedure can find it.
///
/// `binDirectory` is the staging tree the model owns, which is what `GOBIN` is
/// pointed at: nothing global is touched — not `$PATH`, not `~/go/bin`, not
/// `sudo`. The two honest costs of using the user's own toolchain are recorded
/// as known limits in `docs/architecture/core-lsp.md`: the build writes into the
/// *user's* `GOMODCACHE`/`GOCACHE` (that is what `go install` is, and a private
/// `GOPATH` would re-download and rebuild the world for no benefit), and with
/// `GOTOOLCHAIN=auto` an older toolchain may fetch a newer one to build with.
public protocol LSPGoModuleInstalling: Sendable {
    /// The built executable's URL, or a thrown error for anything that went
    /// wrong — a missing toolchain, a network the module proxy is not reachable
    /// over, a compile failure, a cancelled build. The model does not
    /// distinguish them: every one of them is `LSPGoInstallError.buildFailed`,
    /// whose reason is the sentence the Settings row shows.
    func install(
        module: String,
        version: String,
        using goExecutablePath: String,
        into binDirectory: URL
    ) async throws -> URL
}

/// Why gopls is not installed.
///
/// `LSPInstallError`'s shape and `LSPInstallError`'s promise: a small closed set
/// with readable `errorDescription`s, so the one surface that shows a failure —
/// the Settings row beside a Retry button — can say something true, and every
/// one of them is *silent* everywhere else.
///
/// There is no `checksumMismatch` here, and that absence is D17: nothing is
/// downloaded by this app, so there is nothing for it to hash. Module integrity
/// is Go's checksum database, verified by the toolchain doing the build.
public enum LSPGoInstallError: Error, Equatable, LocalizedError {
    /// `go install` did not produce a binary — it failed, or it was interrupted.
    case buildFailed(reason: String)
    /// It reported success, but the binary is not where `GOBIN` says it must be.
    /// Terminal for the attempt: committing a version directory whose executable
    /// is missing would register a server that cannot start, and every request
    /// through it would spend D7's restart budget discovering that.
    case executableMissing(path: String)
    /// A directory could not be created or renamed while installing.
    case fileSystemFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .buildFailed(reason):
            return "Could not build “\(LSPGopls.displayName)”. \(reason)"
        case .executableMissing:
            return "The build of “\(LSPGopls.displayName)” finished but produced no executable."
        case let .fileSystemFailed(reason):
            return "Could not install “\(LSPGopls.displayName)”. \(reason)"
        }
    }
}

/// Everything decision-shaped about gopls: what state it is in, whether it may
/// be offered, what the Settings row may do, and what the registry gets (D17–D20).
///
/// **A second registry contributor, not a second provisioning layer.**
/// `LSPProvisioningModel` owns the *downloadable* servers — pinned URL, pinned
/// digest, unpack, one rename — and gopls has none of that, because there are no
/// official prebuilt binaries to pin. What it shares with that layer is
/// everything that is not about bytes: `LSPServerConsent` under one id in the
/// same `SettingsStore` dictionary (D15), `LSPInstallLayout`'s path math,
/// `LSPInstallEngine.remove(_:)`, the stage-then-one-rename atomicity (D13), the
/// push-then-delete removal ordering (D16), and the failure philosophy — a
/// sentence in a row, a Retry, and no alert ever. The app composes the two
/// contributors into one registry and pushes it through
/// `LSPWorkspace.updateRegistry(_:)`.
///
/// **A reader, like the rest of this layer.** It walks its own install root and
/// touches nothing of the user's, so it takes no `autosave.suspend()` /
/// `localChanges.beginRevert()` gate and is not gated by one.
@MainActor
public final class LSPGoplsProvisioningModel: ObservableObject {
    /// The Settings tab's whole view of gopls.
    @Published public private(set) var row: LSPGoServerRow

    /// This contributor's share of the registry: one description, or none.
    ///
    /// An array rather than an optional because that is what the composition
    /// site wants — `LSPServerRegistry(provisioning.registry.descriptions +
    /// gopls.descriptions)` — and because it keeps the "contributes nothing"
    /// case from needing a `compactMap` at every call site.
    @Published public private(set) var descriptions: [LSPServerDescription] = []

    /// Called with the new descriptions every time they actually change, and
    /// awaited.
    ///
    /// Awaited for `LSPProvisioningModel.onRegistryChange`'s reason, which is
    /// sharper here than there: `remove()` publishes *without* gopls before
    /// deleting anything, because the push is what shuts the running server down
    /// (D16), and deleting an executable out from under a live server leaves
    /// exactly the orphan the release check greps for.
    public var onDescriptionsChange: (([LSPServerDescription]) async -> Void)?

    private let discovery: LSPGoToolchainDiscovering
    private let installer: LSPGoModuleInstalling
    private let engine: LSPInstallEngine
    private let fileService: FileServicing
    private let settings: SettingsStore

    private var layout: LSPInstallLayout { engine.layout }

    /// What the app found, or `nil` until it has answered — the `pending` half
    /// of the lifecycle, and the reason the row has a `pending` status at all.
    private var report: LSPGoToolchainReport?

    /// The one discovery, kept so a second `discover()` awaits the first rather
    /// than starting another. This is what makes the answer — including
    /// "no Go toolchain" — a per-app-run fact on Core's side too, and not only
    /// inside whatever cache the seam keeps.
    private var discoveryTask: Task<Void, Never>?

    private struct PendingAttempt {
        let id: Int
        let task: Task<Void, Never>
    }

    private var attempt: PendingAttempt?
    private var attemptCounter = 0
    /// Distinguishes one attempt's staging tree from the next's, so a Retry can
    /// never adopt the half-built directory a previous attempt left behind
    /// (`LSPInstallLayout.stagingDirectory`).
    private var stagingCounter = 0

    private struct Failure {
        let message: String
        let wasRemoval: Bool
    }

    private var failure: Failure?
    private var isRemoving = false

    public init(
        discovery: LSPGoToolchainDiscovering,
        installer: LSPGoModuleInstalling,
        engine: LSPInstallEngine,
        fileService: FileServicing,
        settings: SettingsStore
    ) {
        self.discovery = discovery
        self.installer = installer
        self.engine = engine
        self.fileService = fileService
        self.settings = settings
        row = LSPGoServerRow(status: .pending, consent: settings.consent(for: LSPGopls.componentID))
        updateRow()
    }

    // MARK: - Discovery

    /// Ask the app where `go` and gopls are, once per app run.
    ///
    /// Called at startup (`LSPToolchain.prewarm()`'s position) so the answer is
    /// there before the first `.go` file is opened; safe to call again from
    /// anywhere, because every later call awaits the first one's task and
    /// re-runs nothing.
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

    /// Which gopls answers right now, or none.
    ///
    /// **The app's own copy wins** (D19). It is the version this app pinned and
    /// the only one Remove may touch, and preferring the other would make Remove
    /// delete a copy that was not in use.
    public var installation: LSPGoplsInstallation? {
        if let url = installedExecutableURL() {
            return .appInstalled(version: LSPGopls.version, path: url.path)
        }
        if let path = report?.discoveredGoplsPath { return .discovered(path: path) }
        return nil
    }

    /// May the banner offer gopls for `language`, and with which toolchain?
    ///
    /// The pure rule over three facts: the language is Go, there is a `go` to
    /// build with, nothing is installed, and the question has not been answered.
    /// Anything else — no toolchain, declined, already accepted, a gopls already
    /// on the machine, an install in flight — answers `nil`, which is how a
    /// banner with no dismiss button nonetheless never appears twice.
    ///
    /// Read off the published `row` rather than re-derived from the disk, for
    /// `LSPProvisioningModel.consentPrompt(forOpening:)`'s reason: the banner
    /// asks this from its `body`, so a version that listed directories would do
    /// so on every keystroke for as long as the question stayed open.
    public func consentPrompt(forOpening language: SyntaxLanguage) -> LSPGoConsentPrompt? {
        guard language == .go, row.status == .notInstalled, row.consent == .unasked else {
            return nil
        }
        guard let goPath = report?.goPath else { return nil }
        return LSPGoConsentPrompt(
            displayName: LSPGopls.displayName,
            version: LSPGopls.version,
            goExecutablePath: goPath
        )
    }

    // MARK: - Answering

    /// The silent half of D15: gopls the user has *already* accepted is built
    /// when a Go file is opened, without asking again.
    ///
    /// Called on every tab open, so it does nothing in every common case — not a
    /// Go file, no toolchain, already installed, declined, or not yet asked
    /// (which is the banner's business).
    ///
    /// **An attempt that already failed this app run is not retried here.** The
    /// guard is the whole difference between "installs on first use" and a retry
    /// loop: a failed build leaves nothing installed, so without it every switch
    /// back to a `.go` tab would start another `go install` — and `install()`
    /// clears the row's `failureMessage` before each attempt, so the one place
    /// D15 reports the failure would be wiped by the very tab switch that
    /// re-triggered it. The budget is "once per app run, automatically"; the
    /// Settings row's Retry stays unconditional, and so does the next launch.
    public func prepareForOpening(_ language: SyntaxLanguage) async {
        guard language == .go, settings.consent(for: LSPGopls.componentID) == .accepted else {
            return
        }

        // Discovery is *awaited* here rather than read off `report`, and that is
        // load-bearing rather than tidy. It is kicked off unawaited at launch and
        // costs a subprocess — up to a login shell — while this runs from the
        // banner's `.task`, which fires within milliseconds of the first render.
        // A restored `.go` tab therefore regularly arrives before the answer
        // does, and a `report` that is still `nil` at that moment would decline
        // silently *for the whole app run*: the trigger this runs under does not
        // fire again until the language or the project root changes, and nothing
        // else calls this. `discover()` coalesces onto the one task, so every
        // call after the first is free — and the non-Go guard above is what keeps
        // that out of the ordinary tab open.
        await discover()

        guard failure == nil, report?.hasToolchain == true, installation == nil else { return }
        await install()
    }

    /// "Install" in the banner: record the answer and build.
    public func accept() async {
        await install()
    }

    /// "No Thanks" in the banner: record the answer and do nothing else, ever.
    /// Nothing is built, nothing is registered, and Go goes on being answered by
    /// the tree-sitter index.
    public func decline() {
        settings.setConsent(.declined, for: LSPGopls.componentID)
        updateRow()
    }

    /// Build and install gopls, from the banner's Install or the Settings row's
    /// Install/Retry.
    ///
    /// Installing *is* consent, so this records `accepted` first, for
    /// `LSPProvisioningModel.install(_:)`'s reason: the Settings row is the one
    /// place a declined server is turned around, and it would be a strange kind
    /// of turning around that installed gopls and then let the next launch
    /// decline to keep it.
    ///
    /// **Without a toolchain it does nothing at all** — not a recorded failure,
    /// not a recorded consent. There is nothing to build with, no view offers
    /// the action in that state, and a row reading "no Go toolchain" beside a
    /// sentence about a build that did not happen would be describing an attempt
    /// nobody made.
    ///
    /// Failure is absorbed here and nowhere else (D15): it becomes the row's
    /// `failureMessage` and the row goes back to "not installed", with Retry
    /// available. Nothing throws out of this method.
    public func install() async {
        guard !isRemoving, let goPath = report?.goPath else { return }
        settings.setConsent(.accepted, for: LSPGopls.componentID)

        // Coalesced, with the claim made synchronously between the check and the
        // store: two accepts — the banner's button and the Settings row's, or a
        // tab open landing on the banner's — must produce one build and one
        // `installing` row, and one `go install` of a module that is not in the
        // build cache is minutes, not milliseconds.
        let task: Task<Void, Never>
        if let existing = attempt {
            task = existing.task
        } else {
            failure = nil
            attemptCounter += 1
            let id = attemptCounter
            task = Task { @MainActor in
                do {
                    try await self.performInstall(goPath: goPath)
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
    /// happened operationally: leaving it `accepted` would have the next `.go`
    /// file silently rebuild what the user just removed. It gates *installing*
    /// and nothing else, so a machine that also has a user-installed gopls goes
    /// straight back to using that one — which is right, since this app neither
    /// put it there nor was asked about it.
    ///
    /// Refuses when there is nothing under the install root (`canRemove` says so
    /// too, and this is the half that does not depend on a view): a binary in
    /// `~/go/bin` is not this app's to delete, and `engine.remove` would not
    /// touch it anyway — it only ever deletes inside the install root. What it
    /// *does* reclaim is every version directory there, including one a pin bump
    /// stranded, which is why the guard is "are there files" rather than "is the
    /// pinned version installed" (`LSPGoServerRow.hasFilesOnDisk`).
    ///
    /// **Re-entrant calls and calls during an install return immediately**, for
    /// `LSPProvisioningModel.remove(_:)`'s reasons: the push suspends for as long
    /// as the shutdown takes, and a second call arriving in that window would
    /// find the descriptions already published and walk straight into deleting
    /// the executable the first call is still politely stopping.
    public func remove() async {
        guard !isRemoving, attempt == nil, !installedVersions().isEmpty else { return }
        isRemoving = true
        updateRow()
        await publish()

        do {
            try engine.remove(LSPGopls.componentID)
            failure = nil
            settings.setConsent(.declined, for: LSPGopls.componentID)
        } catch {
            failure = Failure(message: error.localizedDescription, wasRemoval: true)
        }

        isRemoving = false
        updateRow()
        await publish()
    }

    // MARK: - Installing

    /// D13, in order: stage, build into the staging tree, check what came out,
    /// one `move`, then — and only then — drop what it replaced.
    ///
    /// Every failure before the `move` drops the staging tree and rethrows, so
    /// "whatever was installed before is exactly as it was" needs no rollback to
    /// be true.
    private func performInstall(goPath: String) async throws {
        if installedExecutableURL() != nil { return }

        stagingCounter += 1
        let staging = layout.stagingDirectory(
            componentID: LSPGopls.componentID,
            version: LSPGopls.version,
            token: stagingCounter
        )

        do {
            // `stagingCounter` restarts at zero every launch, so the first
            // attempt of a run recomputes the exact path an attempt of the
            // previous run may still occupy — and `ensureDirectory` succeeds on
            // a directory that already exists, which would adopt that
            // half-written tree rather than refuse it. The engine's
            // `sweepStaging()` normally removed it a moment ago, but it is
            // best-effort by design, so the empty tree the rest of this sequence
            // assumes is established here.
            discard(staging)
            try ensureDirectory(staging)
            let bin = staging.appendingPathComponent(LSPGopls.binSubpath, isDirectory: true)
            try ensureDirectory(bin)

            do {
                _ = try await installer.install(
                    module: LSPGopls.modulePath,
                    version: LSPGopls.moduleVersion,
                    using: goPath,
                    into: bin
                )
            } catch {
                throw LSPGoInstallError.buildFailed(reason: error.localizedDescription)
            }

            // The seam's answer is checked against where `GOBIN` was pointed
            // rather than believed. `LSPGopls.executableSubpath` is a constant
            // because the registry entry's path has to be derivable from a
            // directory listing after a relaunch (D12), so a build that put the
            // binary somewhere else is an install that could not be described —
            // which is a failure now rather than a server that will not start
            // later.
            guard executableExists(in: bin) else {
                throw LSPGoInstallError.executableMissing(
                    path: bin.appendingPathComponent(LSPGopls.executableName).path
                )
            }

            try commit(staging)
        } catch {
            discard(staging)
            throw error
        }
    }

    /// The single rename that makes the version directory exist, and the cleanup
    /// that may only happen after it.
    ///
    /// Older versions are dropped *afterwards*, best-effort:
    /// `LSPInstallEngine.commit`'s rule, for its reason — by this point the new
    /// gopls is installed and servable, and failing the install because a stale
    /// directory would not go away would turn a successful upgrade into a
    /// reported failure over some wasted disk.
    private func commit(_ staging: URL) throws {
        let destination = layout.versionDirectory(
            componentID: LSPGopls.componentID,
            version: LSPGopls.version
        )
        do {
            try fileService.ensureDirectory(at: layout.componentDirectory(LSPGopls.componentID))
            try fileService.move(from: staging, to: destination)
        } catch {
            throw LSPGoInstallError.fileSystemFailed(reason: error.localizedDescription)
        }
        removeOtherVersions()
    }

    private func removeOtherVersions() {
        for version in installedVersions() where version != LSPGopls.version {
            let directory = layout.versionDirectory(
                componentID: LSPGopls.componentID,
                version: version
            )
            guard mayDelete(directory) else { continue }
            try? fileService.removeItem(at: directory)
        }
    }

    // MARK: - Reading the disk

    /// The app-installed executable, or `nil` — one directory listing, which is
    /// the whole of "is it installed" (D12: the disk is the state, so a relaunch
    /// picks up what a previous run built without anything having persisted a
    /// note about it).
    ///
    /// A version directory that exists but holds no binary is deliberately *not*
    /// installed: the rename is what creates that directory and the binary is
    /// inside the tree being renamed, so the only way to see one without the
    /// other is a tree somebody edited by hand.
    private func installedExecutableURL() -> URL? {
        let bin = layout
            .versionDirectory(componentID: LSPGopls.componentID, version: LSPGopls.version)
            .appendingPathComponent(LSPGopls.binSubpath, isDirectory: true)
        guard executableExists(in: bin) else { return nil }
        return bin.appendingPathComponent(LSPGopls.executableName)
    }

    private func executableExists(in binDirectory: URL) -> Bool {
        guard let entries = try? fileService.contentsOfDirectory(at: binDirectory) else {
            return false
        }
        return entries.contains { !$0.isDirectory && $0.name == LSPGopls.executableName }
    }

    private func installedVersions() -> [String] {
        guard let entries = try? fileService.contentsOfDirectory(
            at: layout.componentDirectory(LSPGopls.componentID)
        ) else { return [] }
        return entries.filter(\.isDirectory).map(\.name).sorted()
    }

    // MARK: - Deriving

    private func updateRow() {
        row = LSPGoServerRow(
            status: status(),
            consent: settings.consent(for: LSPGopls.componentID),
            failureMessage: failure?.message,
            failureWasRemoval: failure?.wasRemoval ?? false,
            version: LSPGopls.version,
            hasFilesOnDisk: !installedVersions().isEmpty,
            isRemoving: isRemoving
        )
    }

    private func status() -> LSPGoServerRow.Status {
        guard let report else { return .pending }
        guard report.hasToolchain else { return .noToolchain }
        if attempt != nil { return .installing }
        switch installation {
        case .appInstalled: return .appInstalled(version: LSPGopls.version)
        case .discovered: return .discovered
        case nil: return .notInstalled
        }
    }

    /// What this contributor adds to the registry.
    ///
    /// A plain `.executable(path:)` entry with no arguments — gopls speaks LSP
    /// over stdio by default — under the same id the consent, the install root
    /// and `engine.remove` use. Core learns no paths and gains no launch kind
    /// (D18).
    ///
    /// **A toolchain is required even for a gopls the app did not install.**
    /// gopls shells out to `go list` to understand a module, so without a `go`
    /// it starts and answers nothing while every request through it spends D7's
    /// restart budget finding that out. Contributing nothing is the honest
    /// answer, and it is the same one the row gives.
    ///
    /// **And "a toolchain exists" is not the same as "gopls can find it."** The
    /// server looks `go` up on its own `PATH` (`exec.LookPath`), and the `PATH` a
    /// Finder-launched app inherits is `launchd`'s four directories — so the
    /// discovered search path travels with the description as its environment
    /// overlay, and this guard requires it. Without that, every state above stays
    /// exactly as it reads here and the server still answers nothing, which is
    /// the one failure the routing provider cannot see: an empty answer and a
    /// file with nothing in it are the same value at that seam.
    ///
    /// An *empty* search path is treated as no search path, which the app cannot
    /// currently report — every branch of its search either found the `go` on a
    /// non-empty `PATH` or built one around it. It is checked here anyway because
    /// the alternative failure is the quiet one: contributing `PATH=""` would
    /// register a server that resolves *nothing* by name, which is strictly worse
    /// than the inherited environment this seam exists to improve on, and it would
    /// look identical in the Settings row.
    private func makeDescriptions() -> [LSPServerDescription] {
        guard !isRemoving, let installation else { return [] }
        guard let searchPath = report?.searchPath, !searchPath.isEmpty else { return [] }
        return [
            LSPServerDescription(
                id: LSPGopls.componentID,
                languages: [.go],
                launch: .executable(path: installation.executablePath),
                environment: ["PATH": searchPath]
            )
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

    // MARK: - Mechanism

    private func ensureDirectory(_ url: URL) throws {
        do {
            try fileService.ensureDirectory(at: url)
        } catch {
            throw LSPGoInstallError.fileSystemFailed(reason: error.localizedDescription)
        }
    }

    /// Drop an attempt's staging tree. Best-effort by design: this runs on a
    /// path that is *already* failing, and the engine's sweep at the next launch
    /// is what makes leftovers a disk-space question rather than a correctness
    /// one.
    private func discard(_ staging: URL) {
        guard mayDelete(staging) else { return }
        try? fileService.removeItem(at: staging)
    }

    /// `LSPInstallEngine.mayDelete(_:)`'s rule, restated because this model
    /// deletes through `fileService` directly: inside the install root, and
    /// never the root itself.
    private func mayDelete(_ url: URL) -> Bool {
        layout.contains(url) && !layout.isBase(url)
    }
}
