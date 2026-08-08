#if os(iOS)
import SwiftUI
import PisakaCore

/// View-layer mapping from the SwiftUI-free `ThemePreference` (Core) to a SwiftUI
/// `ColorScheme?` for `.preferredColorScheme(...)`, the iOS peer of the macOS
/// `ContentView` extension (`.system → nil`, `.light → .light`, `.dark → .dark`).
/// Kept in the view layer so Core stays SwiftUI-free.
extension ThemePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// The iOS / iPadOS root view — the adaptive peer of the macOS `ContentView`.
///
/// iPad (regular width): a `NavigationSplitView` with the project tree as the
/// sidebar and the editor (with its tab strip) as the detail. iPhone (compact
/// width): a `NavigationStack` rooted at the tree that pushes the editor screen
/// when a file opens. The split-vs-stack choice keys off the horizontal size
/// class so the same view adapts across iPad multitasking widths and iPhone.
///
/// All domain state lives in the shared Core models (`WorkspaceModel`,
/// `SettingsStore`) and the `FileAccessController`; this view is thin wiring:
/// toolbar actions, the document-picker / settings sheets, and the size-class
/// composition.
struct RootView_iOS: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var settings: SettingsStore
    @ObservedObject var fileAccess: FileAccessController
    @ObservedObject var localChanges: LocalChangesModel
    @ObservedObject var commitLog: CommitLogModel
    @ObservedObject var branchSwitcher: BranchSwitcherModel

    /// The shared scoped file service, used to build a `MergeModel` whose resolved
    /// write goes through the same security scope as the workspace.
    let fileService: FileServicing

    /// The security-scope provider, passed to the merge route's `LibGit2Service` so
    /// its direct repository/index access runs under the opened folder's grant.
    let scopeProvider: SecurityScopeProviding

    /// The Keychain PAT store, managed in the Settings sheet and consulted by the
    /// branch-switcher's fetch (a create-from-`origin/…` on a private HTTPS repo).
    let credentialStore: KeychainCredentialStore

    /// The project-wide symbol index and the controller that schedules its
    /// incremental work. Plain `let`s, never `@ObservedObject`: the model
    /// republishes after every chunk of a walk and nothing in this view reads it —
    /// observing it would rebuild the whole root on each chunk. The editor surfaces
    /// ask their questions through `symbolIndex.provider`.
    let symbolIndex: SymbolIndexModel
    let symbolIndexController: SymbolIndexController

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Which document picker (if any) is presented.
    @State private var activePicker: DocumentPicker.Mode?
    /// Whether the Preferences sheet is shown (iOS has no ⌘, scene).
    @State private var showingSettings = false
    /// A host to pre-fill in the Settings PAT section — set when the user is directed
    /// there from a `credentialsRequired` failure, so the token field is already keyed
    /// to the offending host.
    @State private var settingsPrefillHost: String?
    /// Whether the Local Changes sheet is shown.
    @State private var showingLocalChanges = false
    /// Whether the Git Log sheet is shown.
    @State private var showingLog = false
    /// On compact width, whether the editor screen is pushed onto the stack.
    @State private var showingEditor = false
    /// Sidebar/detail visibility for the iPad split (shows both by default).
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// A dirty tab awaiting a close decision (Save / Discard / Cancel).
    @State private var pendingCloseID: UUID?
    /// The conflicted file currently being resolved in the merge route (with its
    /// loaded `MergeModel`), or `nil` when no merge is presented. Holding the model
    /// here (a reference type in `@State`) retains it for the route's lifetime.
    @State private var mergeTarget: MergeTarget?
    /// A create-from-remote whose fetch failed (offline, or on iOS a missing PAT),
    /// awaiting the user's "Create from Local" / "Cancel" decision — the iOS peer of
    /// `PisakaApp.handleFetchUnavailable`.
    @State private var pendingFetchUnavailable: PendingFetchUnavailable?

    /// A failed branch switch/create to surface to the user. The branch sheet (which
    /// hosts `branchSwitcher.errorMessage`) is dismissed before the async git op runs,
    /// so a blocked checkout / create failure has no surface there — this root-level
    /// alert is the iOS peer of macOS `PisakaApp.presentBranchError` /
    /// `reportInvalidBranchName`.
    @State private var branchAlert: BranchAlert?

    private var isCompact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        adaptiveBody
            .preferredColorScheme(settings.themePreference.colorScheme)
            // Restore the most-recently-opened folder on launch (resolving its
            // security-scoped bookmark), so the tree is populated without a
            // re-pick. A no-op when there are no recents.
            .onAppear { fileAccess.restoreLastFolder() }
            // Refresh the always-visible branch widget when the project folder
            // changes — both a picker open and a launch-time bookmark restore route
            // through `WorkspaceModel.openFolder`, which publishes `projectRoot`.
            // Capture the request token synchronously (this `onChange` body runs on
            // the main actor) before the `Task` hop, so two rapid folder switches
            // settle on the latest even if their unstructured tasks start out of
            // order. (Local Changes / Log refresh from `synchronizeGitModels` and
            // their sheets' `.onAppear`; the branch widget is never dismissed, so it
            // needs this.)
            .onChange(of: model.projectRoot) { _, newRoot in
                // The symbol index is registered here rather than in
                // `synchronizeGitModels` precisely because *both* folder paths — a
                // picker open and the launch-time bookmark restore — publish
                // `projectRoot`, and an index that only existed after a manual pick
                // would leave go-to-definition dead on every relaunch. Closing the
                // folder (`nil`) still prepares, which clears the index: a symbol
                // pointing into a folder the app can no longer read is worse than
                // no symbol.
                symbolIndexController.reset()
                let symbolRequest = symbolIndex.prepareForFolderChange(root: newRoot)
                guard let newRoot else { return }
                Task { await symbolIndex.rebuild(root: newRoot, request: symbolRequest) }
                let request = branchSwitcher.prepareForRefresh(root: newRoot)
                Task { await branchSwitcher.refresh(root: newRoot, request: request) }
            }
            .sheet(item: $activePicker) { mode in
                DocumentPicker(mode: mode, onPick: { url in
                    activePicker = nil
                    handlePicked(url, mode: mode)
                }, onCancel: { activePicker = nil })
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView_iOS(
                    settings: settings,
                    credentialStore: credentialStore,
                    prefillHost: settingsPrefillHost,
                    onDone: {
                        showingSettings = false
                        settingsPrefillHost = nil
                    }
                )
            }
            .sheet(isPresented: $showingLocalChanges) {
                LocalChangesView_iOS(
                    model: localChanges,
                    settings: settings,
                    projectRoot: model.projectRoot,
                    onRevert: revert,
                    onResolveConflict: resolveConflict,
                    onDone: { showingLocalChanges = false }
                )
            }
            .sheet(item: $mergeTarget) { target in
                NavigationStack {
                    MergeRoute_iOS(
                        model: target.model,
                        settings: settings,
                        onApply: { await applyMerge(target.model, file: target.file) },
                        onDone: { mergeTarget = nil }
                    )
                }
            }
            .sheet(isPresented: $showingLog) {
                CommitLogView_iOS(
                    model: commitLog,
                    settings: settings,
                    projectRoot: model.projectRoot,
                    onDone: { showingLog = false }
                )
            }
            .confirmationDialog(
                "Unsaved changes",
                isPresented: closeConfirmationBinding,
                presenting: pendingCloseID
            ) { id in
                closeConfirmationActions(for: id)
            } message: { _ in
                Text("This file has unsaved changes.")
            }
            .confirmationDialog(
                "Couldn't fetch from the remote",
                isPresented: fetchUnavailableBinding,
                presenting: pendingFetchUnavailable
            ) { pending in
                Button("Create from Local") {
                    let target = pending
                    pendingFetchUnavailable = nil
                    let origin = branchSwitcher.currentRefreshGeneration
                    Task {
                        await createBranch(
                            name: target.name,
                            from: target.startPoint,
                            fetchRemote: false,
                            originGeneration: origin
                        )
                    }
                }
                if let host = pending.credentialsHost {
                    Button("Add Token in Settings…") {
                        pendingFetchUnavailable = nil
                        settingsPrefillHost = host
                        showingSettings = true
                    }
                }
                Button("Cancel", role: .cancel) { pendingFetchUnavailable = nil }
            } message: { pending in
                Text(pending.message + "\n\nCreate the branch from the local copy of the remote ref instead?")
            }
            .alert(
                branchAlert?.title ?? "",
                isPresented: branchAlertBinding,
                presenting: branchAlert
            ) { _ in
                Button("OK", role: .cancel) { branchAlert = nil }
            } message: { alert in
                Text(alert.message)
            }
    }

    // MARK: - Adaptive composition

    @ViewBuilder
    private var adaptiveBody: some View {
        if isCompact {
            // iPhone: a navigation stack — tree at the root, editor pushed on open.
            NavigationStack {
                ProjectTreeView_iOS(
                    model: model,
                    onOpenFile: openTreeFile,
                    onOpenFolder: { activePicker = .folder }
                )
                .navigationTitle(projectTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .navigationDestination(isPresented: $showingEditor) {
                    editorArea
                        .navigationTitle(model.selectedFile?.displayName ?? "Editor")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        } else {
            // iPad: a sidebar (tree) + detail (editor) split.
            NavigationSplitView(columnVisibility: $columnVisibility) {
                ProjectTreeView_iOS(
                    model: model,
                    onOpenFile: openTreeFile,
                    onOpenFolder: { activePicker = .folder }
                )
                .navigationTitle(projectTitle)
                .toolbar { toolbarContent }
            } detail: {
                editorArea
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    /// The editor zone: the open-tabs UI (form chosen by `TabLayout`) above/beside
    /// the editor for the selected tab, or a placeholder when nothing is open.
    @ViewBuilder
    private var editorArea: some View {
        let presentation = TabLayout.presentation(
            isCompactWidth: isCompact,
            orientation: settings.tabOrientation
        )
        switch presentation {
        case .switcher:
            VStack(spacing: 0) {
                if !model.openFiles.isEmpty {
                    TabSwitcher_iOS(model: model, onClose: requestClose)
                    Divider()
                }
                editorOrPlaceholder
            }
        case .horizontalStrip:
            VStack(spacing: 0) {
                if !model.openFiles.isEmpty {
                    TabStrip_iOS(model: model, axis: .horizontal, onClose: requestClose)
                        .frame(height: 44)
                    Divider()
                }
                editorOrPlaceholder
            }
        case .verticalColumn:
            HStack(spacing: 0) {
                if !model.openFiles.isEmpty {
                    TabStrip_iOS(model: model, axis: .vertical, onClose: requestClose)
                        .frame(width: 220)
                    Divider()
                }
                editorOrPlaceholder
            }
        }
    }

    @ViewBuilder
    private var editorOrPlaceholder: some View {
        if let file = model.selectedFile {
            CodeEditorView_iOS(
                fileID: file.id,
                fileName: file.displayName,
                fileURL: file.url,
                text: binding(for: file.id),
                fontSize: settings.fontSize,
                onStepFontSize: { settings.stepFontSize(by: $0) },
                symbolIndex: symbolIndexController
            )
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No file open")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            BranchSwitcherView_iOS(
                model: branchSwitcher,
                onSwitch: { branch in
                    // Pin the refresh generation synchronously, before the `Task` hop,
                    // so a folder switch in the gap makes the checkout bail rather than
                    // run against the newly opened repo (mirrors the macOS path).
                    let origin = branchSwitcher.currentRefreshGeneration
                    Task { await switchBranch(branch, originGeneration: origin) }
                },
                onCreateBranch: { name, startPoint in
                    let origin = branchSwitcher.currentRefreshGeneration
                    Task { await createBranch(name: name, from: startPoint, originGeneration: origin) }
                },
                onCheckoutRemote: { branch in
                    let origin = branchSwitcher.currentRefreshGeneration
                    Task { await checkoutRemote(branch, originGeneration: origin) }
                }
            )
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button {
                    activePicker = .folder
                } label: {
                    Label("Open Folder…", systemImage: "folder")
                }
                Button {
                    activePicker = .file
                } label: {
                    Label("Open File…", systemImage: "doc")
                }
                Button {
                    model.newFile()
                    if isCompact { showingEditor = true }
                } label: {
                    Label("New File", systemImage: "doc.badge.plus")
                }
            } label: {
                Image(systemName: "plus")
            }

            Button {
                showingLocalChanges = true
            } label: {
                Image(systemName: "arrow.triangle.pull")
            }
            .disabled(model.projectRoot == nil)

            Button {
                showingLog = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .disabled(model.projectRoot == nil)

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
        }
    }

    // MARK: - Actions

    /// The window/sidebar title: the open folder's name, or the app name.
    private var projectTitle: String {
        model.projectRoot?.lastPathComponent ?? "Pisaka"
    }

    /// Handle a document-picker result for the given mode.
    private func handlePicked(_ url: URL, mode: DocumentPicker.Mode) {
        switch mode {
        case .folder:
            fileAccess.openFolder(at: url)
            synchronizeGitModels(forRoot: url)
        case .file:
            fileAccess.openFile(at: url)
            if isCompact { showingEditor = true }
        }
    }

    /// Register a folder switch with the git models synchronously, the iOS peer of
    /// `PisakaApp.openFolder`'s `prepareForFolderChange`/`prepareForRefresh` calls.
    ///
    /// This must run in the same main-actor turn as the folder open (before any
    /// `await`): it resets the previous repo's state and bumps each model's request
    /// generation *now*, so an in-flight revert bails the instant it resumes rather
    /// than mutating the repository the user just left, and it pins the generation
    /// each refresh runs under so a task that starts out of order can't republish the
    /// superseded repo. Without it the git sheets refresh only from their own
    /// `.onAppear`/`.onChange(of: projectRoot)`, which never fires while dismissed —
    /// reopening the mid-revert folder-switch window the macOS path fences against.
    private func synchronizeGitModels(forRoot root: URL) {
        let changesGeneration = localChanges.prepareForFolderChange(root: root)
        Task { await localChanges.refresh(root: root, requestGeneration: changesGeneration) }
        let logRequest = commitLog.prepareForRefresh(root: root)
        Task {
            await commitLog.refresh(
                root: root,
                limit: CommitLogView_iOS.initialLimit,
                request: logRequest
            )
        }
        // Register the branch widget synchronously too — the `.onChange(of:
        // model.projectRoot)` backstop fires in a later SwiftUI update cycle, so
        // bumping the generation only there would leave a window where an in-flight
        // branch switch/create (which pinned `originGeneration` at tap time) resumes
        // after the folder committed but before the generation moved, and mutates the
        // repo the user just left. This closes it, matching `PisakaApp.openFolder`.
        let branchRequest = branchSwitcher.prepareForRefresh(root: root)
        Task { await branchSwitcher.refresh(root: root, request: branchRequest) }
    }

    /// Open a file from the project tree. It lives under the already-scoped
    /// project root, so the model's read flows through the registered folder's
    /// access grant — no per-file bookmark needed (unlike a standalone file pick).
    /// A read failure is surfaced non-fatally.
    private func openTreeFile(_ url: URL) {
        do {
            try model.open(url: url)
            if isCompact { showingEditor = true }
        } catch {
            PlatformFeedback.warning()
        }
    }

    /// Revert the given files (already confirmed in the Local Changes sheet) and
    /// resync any open tabs, the iOS peer of `PisakaApp.revertChanges` (minus the
    /// autosave / project-tree gates — iOS has no autosave controller and the tree
    /// is read-only, so there is no second uncoordinated disk writer to fence off).
    ///
    /// It snapshots every open tab's buffer before the off-main revert (the editor
    /// stays interactive while libgit2 mutates the working tree), then reloads/closes
    /// a tab only when its buffer is provably unchanged since that snapshot; a buffer
    /// the user edited (or a tab opened during the revert, with no snapshot) is
    /// preserved and its saved baseline reconciled so a since-saved edit still
    /// prompts on close rather than being silently lost.
    @MainActor
    private func revert(_ files: [ChangedFile]) async {
        guard !files.isEmpty else { return }
        // Pin the project the revert was confirmed against; the model bails if a
        // folder switch lands before the revert body samples its root/generation.
        let originGeneration = localChanges.currentRequestGeneration
        let preRevertText = Dictionary(
            uniqueKeysWithValues: model.openFiles.map { ($0.id, $0.text) }
        )
        let reverted = await localChanges.revert(files, originGeneration: originGeneration)
        for url in reverted {
            guard let id = model.fileID(forURL: url) else { continue }
            guard let before = preRevertText[id], before == model.text(for: id) else {
                model.reconcileSavedBaseline(id: id)
                PlatformFeedback.warning()
                continue
            }
            if fileExistsScoped(url) {
                if !model.reloadFromDisk(id: id) {
                    model.close(id: id, force: true)
                    PlatformFeedback.warning()
                }
            } else {
                model.close(id: id, force: true)
            }
        }
    }

    /// `FileManager.fileExists` bracketed by the covering security scope. On a real
    /// device a path under a scoped folder may not be `stat`-able without the grant
    /// active, and a false negative here would force-close a tab whose file actually
    /// still exists (instead of reloading it). The body never throws, so the `?? false`
    /// fallback is unreachable.
    private func fileExistsScoped(_ url: URL) -> Bool {
        (try? scopeProvider.withSecurityScope(covering: url) {
            FileManager.default.fileExists(atPath: url.path)
        }) ?? false
    }

    /// Open the 3-pane merge editor for a conflicted file as a sheet route — the iOS
    /// peer of `PisakaApp.resolveConflict`. Builds a fresh `MergeModel` (its own
    /// libgit2 service, sharing the scoped `FileService` so the resolved write is
    /// bracketed by the same security scope), kicks off the off-main load of the
    /// `:1`/`:2`/`:3` index stages, and presents the route. The repo root is the one
    /// `LocalChangesModel` resolved (repo-root-relative paths), falling back to the
    /// opened folder.
    private func resolveConflict(_ file: ChangedFile) {
        guard let root = localChanges.root ?? model.projectRoot else {
            PlatformFeedback.warning()
            return
        }
        let mergeModel = MergeModel(
            gitService: LibGit2Service(scopeProvider: scopeProvider),
            fileService: fileService
        )
        Task { @MainActor in await mergeModel.load(file: file, root: root) }
        mergeTarget = MergeTarget(file: file, root: root, model: mergeModel)
    }

    /// Perform a guarded merge apply: write the resolved text + stage (via
    /// `MergeModel.apply()`), then refresh Local Changes and resync any open tab on
    /// the resolved file — the iOS peer of `PisakaApp.applyMerge` (minus the autosave
    /// / project-tree gates, which iOS lacks). Returns whether the apply succeeded
    /// (the route closes on `true`).
    ///
    /// The open tab is snapshotted before the async apply and only reloaded over when
    /// it was clean at the snapshot and is provably unchanged since — otherwise the
    /// user's edit is preserved (saved baseline reconciled, beep) rather than
    /// silently discarded. A file staged as a deletion (modify/delete resolved to the
    /// deleted side) closes its now-stale tab instead of reloading.
    @MainActor
    private func applyMerge(_ mergeModel: MergeModel, file: ChangedFile) async -> Bool {
        let root = localChanges.root ?? model.projectRoot
        let resolvedURL = root?.appendingPathComponent(file.path)
        let preApply: (id: UUID, text: String, wasDirty: Bool)? = resolvedURL
            .flatMap { model.fileID(forURL: $0) }
            .flatMap { id in model.text(for: id).map { (id, $0, model.isDirty(for: id)) } }

        let applied = await mergeModel.apply()
        guard applied else { return false }

        // Refresh Local Changes (the resolved file leaves the conflicted set).
        if let projectRoot = model.projectRoot {
            let requestGeneration = localChanges.currentRequestGeneration
            await localChanges.refresh(root: projectRoot, requestGeneration: requestGeneration)
        }

        guard let resolvedURL, let id = model.fileID(forURL: resolvedURL) else { return true }
        // Reload only when the tab holds no unsaved edits to lose.
        guard let before = preApply, before.id == id, !before.wasDirty,
              before.text == model.text(for: id) else {
            model.reconcileSavedBaseline(id: id)
            PlatformFeedback.warning()
            return true
        }
        if fileExistsScoped(resolvedURL) {
            if !model.reloadFromDisk(id: id) {
                model.close(id: id, force: true)
                PlatformFeedback.warning()
            }
        } else {
            model.close(id: id, force: true)
        }
        return true
    }

    // MARK: - Branch switching

    /// Check out a local branch, then resync open tabs and refresh the git models —
    /// the iOS peer of `PisakaApp.switchBranch`/`runBranchOperation` (minus the
    /// autosave / project-tree gates, which iOS lacks, exactly like the iOS revert
    /// path). The dirty-tree warning is presented by the widget before this is called.
    /// A blocked checkout surfaces git's message (naming the conflicting files) via a
    /// root-level alert — the branch sheet that hosts `branchSwitcher.errorMessage` is
    /// already dismissed by the time this runs.
    @MainActor
    private func switchBranch(_ branch: BranchRef, originGeneration: Int? = nil) async {
        await runBranchOperation {
            await branchSwitcher.switchTo(branch, originGeneration: originGeneration)
        }
    }

    /// Snapshot open tabs, run the checkout `op` off the main actor, and on success
    /// resync tabs + refresh the git models; on failure surface git's message (a
    /// generation-mismatch bail leaves `errorMessage` nil and exits silently). The
    /// iOS peer of `PisakaApp.runBranchOperation` (minus the autosave / project-tree
    /// gates iOS lacks), shared by `switchBranch` and `checkoutRemote`.
    @MainActor
    private func runBranchOperation(_ op: () async -> Bool) async {
        let snapshot = openTabSnapshot()
        // The repository the checkout runs against, so the resync touches only tabs
        // under it (tabs persist across folder switches). `originGeneration` was pinned
        // synchronously at the call site to keep the checkout bound to the origin repo.
        let repoRoot = branchSwitcher.root
        guard await op() else {
            presentBranchError(branchSwitcher.errorMessage)
            return
        }
        finishBranchOperation(snapshot: snapshot, repoRoot: repoRoot)
    }

    /// Check out a remote branch via git DWIM (switch to the same-named local if it
    /// exists, else create it from the remote ref, no fetch), then resync open tabs and
    /// refresh the git models — the iOS peer of `PisakaApp.checkoutRemote`, a mirror of
    /// `switchBranch`. The dirty-tree warning is presented by the widget before this is
    /// called, routed through the *remote* branch of the confirmation so it lands here
    /// (the DWIM path) rather than in `switchBranch` (which would detach HEAD).
    @MainActor
    private func checkoutRemote(_ branch: BranchRef, originGeneration: Int? = nil) async {
        await runBranchOperation {
            await branchSwitcher.checkoutRemote(branch, originGeneration: originGeneration)
        }
    }

    /// Present the "Branch operation failed" alert, but only for a real git failure:
    /// a generation-mismatch bail leaves `errorMessage` nil, so a nil `message` stays
    /// silent (no beep, no alert). The iOS peer of macOS `PisakaApp.presentBranchError`.
    @MainActor
    private func presentBranchError(_ message: String?) {
        guard let message else { return }
        PlatformFeedback.warning()
        branchAlert = BranchAlert(title: "Branch operation failed", message: message)
    }

    /// Create-and-switch a new branch `name` at `startPoint` under the same (absence
    /// of) gates as the iOS revert path. On `.fetchUnavailable` (a remote start whose
    /// fetch failed — offline, or in Part A no PAT on iOS) it offers "create from the
    /// local copy" via a confirmation dialog; an invalid name / hard failure surfaces a
    /// root-level alert (the branch sheet is already dismissed by then).
    @MainActor
    private func createBranch(
        name: String,
        from startPoint: BranchSwitcherModel.StartPoint,
        fetchRemote: Bool = true,
        originGeneration: Int? = nil
    ) async {
        let snapshot = openTabSnapshot()
        // The repository the create runs against, so the resync scopes to its tabs;
        // `originGeneration` (pinned synchronously at the call site) keeps the create
        // bound to the origin repo across the `Task` hop.
        let repoRoot = branchSwitcher.root
        let outcome = await branchSwitcher.createBranch(
            name: name,
            from: startPoint,
            fetchRemote: fetchRemote,
            originGeneration: originGeneration
        )
        switch outcome {
        case .created:
            finishBranchOperation(snapshot: snapshot, repoRoot: repoRoot)
        case .invalidName:
            PlatformFeedback.warning()
            branchAlert = BranchAlert(
                title: "Invalid branch name",
                message: "\"\(name)\" is not a valid git branch name."
            )
        case .failed:
            // Alert only on a real git failure; a generation-mismatch bail leaves
            // `errorMessage` nil and exits silently, matching `PisakaApp.createBranch`.
            presentBranchError(branchSwitcher.errorMessage)
        case .fetchUnavailable(let error):
            PlatformFeedback.warning()
            // A missing PAT (`credentialsRequired`) also offers "Add Token in
            // Settings…", pre-filled with the offending host; any other fetch failure
            // (offline, etc.) offers only "Create from Local" / "Cancel".
            let host: String? = { if case .credentialsRequired(let h) = error { return h } else { return nil } }()
            pendingFetchUnavailable = PendingFetchUnavailable(
                name: name,
                startPoint: startPoint,
                message: error.localizedDescription,
                credentialsHost: host
            )
        }
    }

    /// The post-success tail shared by switch and create: resync open tabs to the new
    /// working tree, bump `treeRevision`, and refresh Local Changes and Log. Mirrors
    /// `PisakaApp.finishBranchOperation`.
    @MainActor
    private func finishBranchOperation(
        snapshot: [UUID: (text: String, wasDirty: Bool)],
        repoRoot: URL?
    ) {
        resyncOpenTabsAfterCheckout(snapshot: snapshot, repoRoot: repoRoot)
        model.bumpTreeRevision()
        refreshGitModelsAfterBranchChange()
    }

    /// A snapshot of every open tab's buffer text and dirty state, captured
    /// synchronously before a branch mutation hops off the main actor — so the
    /// post-checkout resync can tell a tab it may safely reload (clean and unchanged)
    /// from one the user has edits in. Mirrors `PisakaApp.openTabSnapshot`.
    private func openTabSnapshot() -> [UUID: (text: String, wasDirty: Bool)] {
        Dictionary(
            uniqueKeysWithValues: model.openFiles.map {
                ($0.id, ($0.text, model.isDirty(for: $0.id)))
            }
        )
    }

    /// After a successful checkout/create the working tree may have changed under any
    /// open tab. Reload each tab that holds no unsaved edits to lose (clean at the
    /// snapshot and provably unchanged since); preserve — reconcile its saved baseline
    /// so a since-saved edit still prompts on close, and beep — a tab the user had
    /// edits in; close a tab whose file no longer exists on the new branch. Tabs
    /// outside `repoRoot` are left untouched (tabs persist across folder switches). The
    /// iOS peer of `PisakaApp.resyncOpenTabsAfterCheckout`, using `fileExistsScoped`.
    private func resyncOpenTabsAfterCheckout(
        snapshot: [UUID: (text: String, wasDirty: Bool)],
        repoRoot: URL?
    ) {
        let rootPath = repoRoot?.resolvingSymlinksInPath().path
        var didPreserve = false
        for file in model.openFiles {
            guard let fileURL = file.url else { continue }
            if let rootPath,
               !ScopedFileAccess.path(fileURL.resolvingSymlinksInPath().path, isWithin: rootPath) {
                continue
            }
            let id = file.id
            guard let snap = snapshot[id], !snap.wasDirty, snap.text == model.text(for: id) else {
                model.reconcileSavedBaseline(id: id)
                didPreserve = true
                continue
            }
            if let url = file.url, fileExistsScoped(url) {
                if !model.reloadFromDisk(id: id) {
                    model.close(id: id, force: true)
                    didPreserve = true
                }
            } else {
                model.close(id: id, force: true)
            }
        }
        if didPreserve { PlatformFeedback.warning() }
    }

    /// Refresh Local Changes and Log after a branch change (same folder), each pinned
    /// to its current request generation so an out-of-order task can't republish a
    /// superseded repo — the iOS peer of `PisakaApp.refreshLocalChanges`/`refreshLog`.
    private func refreshGitModelsAfterBranchChange() {
        guard let root = model.projectRoot else { return }
        let changesGeneration = localChanges.currentRequestGeneration
        Task { await localChanges.refresh(root: root, requestGeneration: changesGeneration) }
        let logRequest = commitLog.prepareForRefresh(root: root)
        Task {
            await commitLog.refresh(
                root: root,
                limit: CommitLogView_iOS.initialLimit,
                request: logRequest
            )
        }
    }

    private var fetchUnavailableBinding: Binding<Bool> {
        Binding(
            get: { pendingFetchUnavailable != nil },
            set: { if !$0 { pendingFetchUnavailable = nil } }
        )
    }

    private var branchAlertBinding: Binding<Bool> {
        Binding(
            get: { branchAlert != nil },
            set: { if !$0 { branchAlert = nil } }
        )
    }

    /// A binding to a specific file's text that routes writes through the model so
    /// dirty state is tracked, mirroring the macOS `ContentView.binding(for:)`.
    private func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { model.openFiles.first { $0.id == id }?.text ?? "" },
            set: { model.updateText($0, for: id) }
        )
    }

    /// Request to close a tab. A clean tab closes immediately; a dirty one defers
    /// to a confirmation dialog (Save / Discard / Cancel).
    private func requestClose(_ id: UUID) {
        // Hand the tab's index entry back to disk once the close is settled;
        // `forgetIndexedBuffer` no-ops while any tab still shows the file, so the
        // deferred-confirmation branch leaves the buffer mark alone.
        let closingURL = model.openFiles.first { $0.id == id }?.url
        defer { forgetIndexedBuffer(closingURL) }
        if model.close(id: id) == .needsConfirmation {
            pendingCloseID = id
        } else if isCompact && model.openFiles.isEmpty {
            // Closing the last tab on the pushed editor screen returns to the tree.
            showingEditor = false
        }
    }

    /// Tell the symbol index that `url` no longer has an editor buffer behind it, so
    /// the next walk re-extracts it from disk — the iOS peer of
    /// `PisakaApp.forgetIndexedBuffer`, and a no-op while any tab still shows the
    /// file (a cancelled close, or the same file reached through two tabs).
    private func forgetIndexedBuffer(_ url: URL?) {
        guard let url, model.fileID(forURL: url) == nil else { return }
        symbolIndexController.noteBufferClosed(url: url)
    }

    private var closeConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingCloseID != nil },
            set: { if !$0 { pendingCloseID = nil } }
        )
    }

    @ViewBuilder
    private func closeConfirmationActions(for id: UUID) -> some View {
        // Save is only offered for a titled file (an "Untitled" buffer has no url;
        // a Save-As/export flow is out of scope for Phase 1).
        if let file = model.openFiles.first(where: { $0.id == id }), file.url != nil {
            Button("Save") {
                do {
                    _ = try model.save(for: id)
                    model.close(id: id, force: true)
                    forgetIndexedBuffer(file.url)
                } catch {
                    PlatformFeedback.warning()
                }
                pendingCloseID = nil
            }
        }
        Button("Discard Changes", role: .destructive) {
            let closingURL = model.openFiles.first { $0.id == id }?.url
            model.close(id: id, force: true)
            forgetIndexedBuffer(closingURL)
            pendingCloseID = nil
            if isCompact && model.openFiles.isEmpty { showingEditor = false }
        }
        Button("Cancel", role: .cancel) { pendingCloseID = nil }
    }
}

// MARK: - Project tree (iOS)

/// The iOS project file tree — the peer of the macOS `ProjectTreeView`. Renders
/// the directory rooted at `model.projectRoot`; tapping a file row opens it.
/// Reuses the same model paths (`children(of:)` for listing, `treeRevision` for
/// refresh) so all logic stays in the model. When no folder is open a placeholder
/// invites opening one.
struct ProjectTreeView_iOS: View {
    @ObservedObject var model: WorkspaceModel
    var onOpenFile: (URL) -> Void
    var onOpenFolder: () -> Void

    var body: some View {
        Group {
            if let root = model.projectRoot {
                ScrollView {
                    // A plain VStack (not LazyVStack): the tree is already lazy via
                    // DisclosureGroup, and a lazy container would discard an
                    // off-screen node's cached children — the macOS rationale.
                    VStack(alignment: .leading, spacing: 0) {
                        DirectoryNodeView_iOS(
                            model: model,
                            url: root,
                            name: root.lastPathComponent,
                            onOpenFile: onOpenFile,
                            startsExpanded: true
                        )
                        .id(root)
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Button("Open a folder", action: onOpenFolder)
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// One directory row: a `DisclosureGroup` that lazily loads its children on first
/// expansion and caches them in `@State`, re-reading on a `treeRevision` bump —
/// the iOS mirror of the macOS `DirectoryNodeView`.
private struct DirectoryNodeView_iOS: View {
    @ObservedObject var model: WorkspaceModel
    let url: URL
    let name: String
    let onOpenFile: (URL) -> Void

    @State private var isExpanded: Bool
    @State private var children: [DirectoryEntry]?

    init(
        model: WorkspaceModel,
        url: URL,
        name: String,
        onOpenFile: @escaping (URL) -> Void,
        startsExpanded: Bool = false
    ) {
        self.model = model
        self.url = url
        self.name = name
        self.onOpenFile = onOpenFile
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(children ?? []) { entry in
                if entry.isDirectory {
                    DirectoryNodeView_iOS(
                        model: model,
                        url: entry.url,
                        name: entry.name,
                        onOpenFile: onOpenFile
                    )
                    .padding(.leading, 12)
                } else {
                    FileRow_iOS(entry: entry, onOpen: { onOpenFile(entry.url) })
                        .padding(.leading, 12)
                }
            }
        } label: {
            let icon = FileIcon(for: DirectoryEntry(url: url, isDirectory: true))
            HStack(spacing: 6) {
                Image(systemName: icon.symbolName)
                    .foregroundStyle(swiftUIColor(for: icon.color))
                Text(name)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded && children == nil { loadChildren() }
        }
        .onAppear {
            if isExpanded && children == nil { loadChildren() }
        }
        .onChange(of: model.treeRevision) {
            if isExpanded { loadChildren() } else { children = nil }
        }
    }

    private func loadChildren() {
        do {
            children = try model.children(of: url)
        } catch {
            PlatformFeedback.warning()
            children = nil
        }
    }
}

/// One file row in the iOS tree: a tappable label that opens the file.
private struct FileRow_iOS: View {
    let entry: DirectoryEntry
    let onOpen: () -> Void

    var body: some View {
        let icon = FileIcon(for: entry)
        HStack(spacing: 6) {
            Image(systemName: icon.symbolName)
                .foregroundStyle(swiftUIColor(for: icon.color))
            Text(entry.name)
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}

/// Maps a semantic `FileIconColor` token to a concrete SwiftUI `Color` (the iOS
/// peer of the macOS `ProjectTreeView.color(for:)`).
private func swiftUIColor(for token: FileIconColor) -> Color {
    switch token {
    case .orange: return .orange
    case .yellow: return .yellow
    case .blue: return .blue
    case .green: return .green
    case .purple: return .purple
    case .red: return .red
    case .pink: return .pink
    case .gray: return .gray
    case .accent: return .accentColor
    }
}

/// A presented merge route: the conflicted file, the repo root it resolves against,
/// and its loaded `MergeModel`. Held in `@State` so the model (a reference type) is
/// retained for the route's lifetime; identity is the file's repo-relative path.
private struct MergeTarget: Identifiable {
    let file: ChangedFile
    let root: URL
    let model: MergeModel
    var id: String { file.id }
}

/// A create-from-remote whose fetch failed, awaiting the "Create from Local" /
/// "Cancel" decision. Carries the entered name, the (remote) start point to retry
/// without a fetch, git's error message for the dialog, and — when the failure was a
/// missing PAT — the host to pre-fill in Settings (else `nil`, so only the
/// create-from-local / cancel choices are offered).
private struct PendingFetchUnavailable: Identifiable {
    let name: String
    let startPoint: BranchSwitcherModel.StartPoint
    let message: String
    let credentialsHost: String?
    let id = UUID()
}

/// A failed branch switch/create surfaced as a root-level alert (the branch sheet is
/// already dismissed by then). `title`/`message` mirror macOS's
/// `presentBranchError` ("Branch operation failed") and `reportInvalidBranchName`
/// ("Invalid branch name").
private struct BranchAlert: Identifiable {
    let title: String
    let message: String
    let id = UUID()
}

/// Make `DocumentPicker.Mode` usable as a `sheet(item:)` identity.
extension DocumentPicker.Mode: Identifiable {
    var id: Int {
        switch self {
        case .folder: return 0
        case .file: return 1
        }
    }
}
#endif
