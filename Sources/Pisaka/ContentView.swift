#if os(macOS)
import SwiftUI
import PisakaCore

/// View-layer mapping from the SwiftUI-free `ThemePreference` (Core) to a SwiftUI
/// `ColorScheme?` for `.preferredColorScheme(...)`: `.system → nil` (follow the
/// system), `.light → .light`, `.dark → .dark`. Kept here so Core stays
/// SwiftUI-free (the same split as `FileIconColor → Color`).
extension ThemePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: WorkspaceModel
    /// Observable state for the Local Changes panel. Defaults to a real,
    /// `Process`-backed service so previews/tests can construct the view without
    /// the app wiring.
    @ObservedObject var localChanges: LocalChangesModel = LocalChangesModel(gitService: GitCLIService())
    /// Observable state for the Log view. Defaults to a real, `Process`-backed
    /// service so previews/tests can construct the view without the app wiring.
    @ObservedObject var commitLog: CommitLogModel = CommitLogModel(gitService: GitCLIService())
    /// Observable state for the branch-switcher widget (bottom bar). Defaults to a
    /// real, `Process`-backed service so previews/tests can construct the view
    /// without the app wiring.
    @ObservedObject var branchSwitcher: BranchSwitcherModel = BranchSwitcherModel(gitService: GitCLIService())
    /// State for the commit dialog (⌘K). Owned by `PisakaApp`, which loads it
    /// before presenting the sheet; defaults to a real, `Process`-backed service so
    /// previews/tests can construct the view without the app wiring.
    ///
    /// Deliberately **not** `@ObservedObject`: this view never reads it, it only
    /// hands it to the sheet, which observes it itself. Observing it here would
    /// re-evaluate the whole window — the project tree, the tab list,
    /// `CodeEditorView.updateNSView`, the bottom panel — on every keystroke in the
    /// commit message field, which is bound to the model's `@Published` `message`.
    /// That is the per-keystroke cost `PathBarView.equatable()` exists to avoid,
    /// arriving from a new source.
    var commitDialog: CommitDialogModel = CommitDialogModel(gitService: GitCLIService())
    /// Owns the embedded terminal's live sessions. Defaults to a fresh model so
    /// previews/tests can construct the view without the app wiring.
    @ObservedObject var terminalSessions: TerminalSessionsModel = TerminalSessionsModel()
    /// Persisted user preferences (tab orientation, theme, shared editor font
    /// size). Owned by `PisakaApp`; defaults to a fresh store so a
    /// default-constructed view (previews/tests) still compiles. Downstream tasks
    /// read each setting from here to apply theme, tab layout, and font size.
    @ObservedObject var settings: SettingsStore = SettingsStore()
    /// The find/replace bar's state (⌘F). Window-scoped and owned by `PisakaApp`
    /// so the pattern and toggles survive a tab switch; observed here because
    /// `isVisible` decides whether the bar is rendered above the editor. Defaults
    /// to a fresh state so a default-constructed view (previews/tests) compiles.
    @ObservedObject var search: EditorSearchState = EditorSearchState()
    /// Pending "select this range" request from the Find in Files window (⌘⇧F).
    /// Owned by `PisakaApp` for the same reason as `search` — an activation may
    /// open the file, so the request is recorded before the editor showing it
    /// exists — and threaded straight into `CodeEditorView`, which consumes it.
    /// Defaults to a fresh state so a default-constructed view compiles.
    @ObservedObject var reveal: EditorRevealState = EditorRevealState()
    /// Schedules the symbol index's buffer re-index (debounced while typing,
    /// immediate on a tab switch). Owned by `PisakaApp` and threaded straight into
    /// `CodeEditorView`; deliberately **not** `@ObservedObject` — it publishes
    /// nothing, and the index model behind it republishes after every chunk of a
    /// walk, which is exactly the per-update cost `PathBarView.equatable()` and the
    /// non-observed `commitDialog` exist to keep off this view. Defaults to a
    /// controller over a fresh, never-walked index so a default-constructed view
    /// (previews/tests) still compiles.
    var symbolIndex: SymbolIndexController = SymbolIndexController(model: SymbolIndexModel())
    /// What `.editorconfig` says about the file being edited. Owned by `PisakaApp`
    /// and threaded straight into `CodeEditorView`, which is the only thing that
    /// asks it anything; deliberately **not** `@ObservedObject` for the
    /// `symbolIndex` reasons above — it publishes nothing. Undefaulted, unlike its
    /// neighbours: the model is main-actor-isolated and takes a `FileServicing`,
    /// so there is no default worth writing that would not be a second, live disk
    /// reader built for a view nobody constructs.
    var editorConfig: EditorConfigModel
    /// The one funnel every macOS save passes through before it writes. Owned by
    /// `PisakaApp` and threaded straight into `CodeEditorView`, which attaches it
    /// to the live editor; deliberately **not** `@ObservedObject` and optional
    /// (`nil` in previews/tests transforms nothing), both for the `symbolIndex`
    /// reasons above.
    var saveTransform: SaveTransformController?
    /// Schedules the diagnostics channel's push sync (D30): the same three
    /// editor triggers — tab open/switch, wholesale buffer swap, settled typing
    /// — that drive the symbol index also flush the buffer to its language
    /// server, so the two readers can never disagree about which buffer is
    /// current. Owned by `PisakaApp` and threaded straight into
    /// `CodeEditorView`; deliberately **not** `@ObservedObject` and optional
    /// (`nil` in previews/tests syncs nothing), both for the `symbolIndex`
    /// reasons above.
    var lspSync: LSPDocumentSyncController?
    /// The diagnostics channel's observable model — the store the editor paints
    /// its squiggles from. Owned by `PisakaApp` and threaded straight into
    /// `CodeEditorView`; deliberately **not** `@ObservedObject` and optional
    /// (`nil` in previews/tests shows none), both for the `symbolIndex` reasons
    /// above — and doubly so because the store republishes on every keystroke's
    /// shift, which must not re-render this view.
    var diagnostics: DiagnosticsModel?
    /// Which downloadable language servers exist and what state each is in.
    /// Threaded straight through to the consent banner, and deliberately **not**
    /// `@ObservedObject` — the `symbolIndex` precedent, and for the reason
    /// `PisakaApp` states where it holds this model as a plain `let`: this view
    /// shows nothing published on it, and subscribing would put the project tree,
    /// the tab list and `CodeEditorView.updateNSView` back on the republish path
    /// for every install transition. `LSPConsentBanner` observes it itself, which
    /// is what makes the strip appear and disappear. Owned by `PisakaApp`; the
    /// default builds a throwaway stack over the same install root so a
    /// default-constructed view (previews/tests) still compiles, matching the
    /// `GitCLIService()` defaults above. A model nobody asks anything of
    /// downloads nothing.
    var provisioning: LSPProvisioningModel = PisakaApp.makeProvisioning().model
    /// Whether Go has a language server on this Mac, and how it would get one.
    /// Threaded through to the same consent banner and non-observed here for the
    /// same reason as `provisioning` above — the banner observes it itself. Owned
    /// by `PisakaApp`; the default builds a throwaway stack that searches for
    /// nothing until something calls `discover()`.
    var gopls: LSPGoplsProvisioningModel = PisakaApp.makeGopls().model
    /// Whether Rust has a language server on this Mac, and how it would get one.
    /// Threaded through to the same consent banner and non-observed here for the
    /// same reason as the two above. Owned by `PisakaApp`; the default builds a
    /// throwaway stack that searches for nothing until something calls
    /// `discover()` — and, with no toolchain answer yet, offers nothing either.
    var rust: LSPRustProvisioningModel = PisakaApp.makeRust().model
    /// Who is signed in to LeetCode, and the statement for the active tab.
    /// Threaded through to the description pane and deliberately **not**
    /// `@ObservedObject` — the `provisioning`/`symbolIndex` precedent, and the
    /// rule `PisakaApp` states where it holds this model as a plain `let`: this
    /// view shows nothing published on it, and subscribing would put the project
    /// tree, the tab list and `CodeEditorView.updateNSView` on the republish path
    /// of every busy transition and every statement fetch.
    /// `LeetCodeDescriptionPane` observes it itself, which is what makes the pane
    /// appear and disappear. Owned by `PisakaApp`; the default builds a throwaway
    /// stack that talks to nothing until something asks it to.
    var leetCode: LeetCodeModel = PisakaApp.makeLeetCode()
    /// Open the file a Go to Definition landed on and select the declaration's
    /// name. Wired to the same `PisakaApp` entry point a Find in Files activation
    /// uses — opening a tab is the app's job — and threaded straight into
    /// `CodeEditorView`. Default no-op for previews/tests.
    var onGoToDefinition: (URL, NSRange) -> Void = { _, _ in }
    /// Show a definition that lives outside the opened folder in the separate
    /// read-only source viewer window (D3). Wired to `PisakaApp` — owning windows
    /// is the app's job — and threaded straight into `CodeEditorView`. Default
    /// no-op for previews/tests.
    var onViewDefinitionOutsideProject: (URL, NSRange) -> Void = { _, _ in }
    /// Which bottom dock panel is shown (`nil` = none), VS Code-style. Owned by
    /// `PisakaApp` and bound here; `.constant(nil)` keeps the default-constructed
    /// view (previews/tests) with no panel shown.
    var bottomPanel: Binding<BottomPanel?> = .constant(nil)
    /// Toggle a bottom dock panel (creating the first terminal session if needed).
    /// Routed through `PisakaApp` so the bottom-bar buttons and the View-menu
    /// commands share one implementation. Default no-op for previews/tests.
    var onTogglePanel: (BottomPanel) -> Void = { _ in }
    /// Invoked when a Problems-panel row is activated, opening (or re-selecting)
    /// the file and revealing the diagnostic's range. Wired to the same
    /// `PisakaApp.activateSearchMatch(url:range:)` a Find in Files activation and
    /// Go to Definition use. Default no-op for previews/tests.
    var onActivateProblem: (URL, NSRange) -> Void = { _, _ in }
    /// Invoked when a tab requests to close (button or command). Defaults to a
    /// no-op so previews/tests can construct the view without the app wiring.
    var onClose: (UUID) -> Void = { _ in }
    /// Invoked when a project-tree file row is clicked. Defaults to a no-op so
    /// previews/tests can construct the view without the app wiring.
    var onOpenFile: (URL) -> Void = { _ in }
    /// Invoked when the empty project-tree pane is clicked to open a folder.
    /// Defaults to a no-op so previews/tests can construct the view without the
    /// app wiring.
    var onOpenFolder: () -> Void = {}
    /// Invoked when a changed-file row requests a revert. Defaults to a no-op so
    /// previews/tests can construct the view without the app wiring.
    var onRevert: (ChangedFile) -> Void = { _ in }
    /// Invoked when a Local Changes row is double-clicked to open its diff in a
    /// separate window. Defaults to a no-op so previews/tests can construct the
    /// view without the app wiring.
    var onOpenDiff: (ChangedFile) -> Void = { _ in }
    /// Invoked when a commit's file is double-clicked in the Git Log to open its
    /// diff in a separate window. Defaults to a no-op so previews/tests can
    /// construct the view without the app wiring.
    var onOpenCommitDiff: (ChangedFile, Commit) -> Void = { _, _ in }
    /// Invoked when a conflicted Local Changes file requests resolution (the
    /// "Resolve" entry / double-click), opening the 3-pane merge window. Defaults
    /// to a no-op so previews/tests can construct the view without the app wiring.
    /// (The Local Changes trigger that calls this is wired in Task 6.)
    var onResolveConflict: (ChangedFile) -> Void = { _ in }
    /// Branch-switcher callbacks (bottom-bar widget), wired to `PisakaApp`'s gated
    /// orchestration. Default no-ops so previews/tests can construct the view.
    var onSwitchBranch: (BranchRef) -> Void = { _ in }
    var onCreateBranchFromRemote: (BranchRef) -> Void = { _ in }
    var onCheckoutRemote: (BranchRef) -> Void = { _ in }
    var onNewBranch: () -> Void = {}
    /// Project-tree file-operation callbacks, threaded down to `ProjectTreeView`.
    /// Default no-ops so previews/tests can construct the view without the app
    /// wiring.
    var mayBeginFileOperation: () -> Bool = { true }
    var onNewFile: (URL, String) -> Void = { _, _ in }
    var onNewFolder: (URL, String) -> Void = { _, _ in }
    var onRename: (URL, String) -> Void = { _, _ in }
    /// Invoked when a project-tree drag drops the entry at the first URL onto the
    /// folder at the second, wired to `PisakaApp.moveItem(at:into:)`. The view
    /// layer decides nothing about the move: every validity and destination
    /// question is `MoveDropRule`'s.
    var onMove: (URL, URL) -> Void = { _, _ in }
    var onDelete: (URL) -> Void = { _ in }
    /// Invoked when a project-tree file row requests a run (the "Run" context-menu
    /// item), wired to `PisakaApp.runFile(url:)`. Default no-op so previews/tests
    /// can construct the view without the app wiring.
    var onRun: (URL) -> Void = { _ in }
    /// Invoked when a project-tree file row requests a test run (the "Run Test"
    /// context-menu item), wired to `PisakaApp.testFile(url:)`. Default no-op so
    /// previews/tests can construct the view without the app wiring. Threaded down
    /// to `ProjectTreeView` in Task 5.
    var onRunTest: (URL) -> Void = { _ in }
    /// Whether the commit dialog sheet is up. Owned by `PisakaApp` (which loads the
    /// model before raising it) and bound here; `.constant(false)` keeps the
    /// default-constructed view (previews/tests) without a sheet.
    var isCommitDialogPresented: Binding<Bool> = .constant(false)
    /// Invoked by the Local Changes header's Commit button — the same handler as
    /// the ⌘K menu item, so the two behave identically. Default no-op.
    var onOpenCommitDialog: () -> Void = {}
    /// Invoked by a Local Changes row's "Commit…" context-menu item, opening the
    /// commit dialog with only that file preselected. Wired to the *same*
    /// `PisakaApp.openCommitDialog` orchestration as `onOpenCommitDialog`, with the
    /// preselect as its only difference. Default no-op.
    var onCommitFile: (ChangedFile) -> Void = { _ in }
    /// Run the commit the dialog describes. `PisakaApp` owns the gates and the
    /// post-success refreshes, and closes the sheet itself. The `Int` is the
    /// project generation the *view* captured synchronously before its `Task` hop
    /// (`onReplaceAll`'s shape and reason — read inside the task it would compare
    /// against itself). Default no-op.
    var onCommit: (Int) async -> Void = { _ in }
    /// Called on *every* path that closes the commit sheet (Commit, Cancel, Esc),
    /// so the modal autosave suspension `PisakaApp` raises when opening it is
    /// always released. Default no-op.
    var onCommitDialogDismissed: () -> Void = {}

    /// Height of the bottom dock panel. Held independently of *which* panel is
    /// shown so it survives panel switches and hide/show, VS Code-style (the old
    /// recreated `VSplitView` reset it on every change). `@State` only — meeting
    /// "persist across switch/hide-show"; cross-launch persistence is YAGNI.
    @State private var panelHeight: CGFloat = 240
    /// The panel height captured at the start of a divider drag, so the cumulative
    /// `DragGesture` translation is applied to a fixed base rather than compounding
    /// against the live `panelHeight` each frame. `nil` when not dragging.
    @State private var panelDragStartHeight: CGFloat?

    /// The interface zone's metrics. Computed from the store rather than read
    /// from the environment because this view is the *root* that injects it (see
    /// `SettingsStore.interfaceMetrics`); every view below reads the environment.
    private var metrics: InterfaceMetrics { settings.interfaceMetrics }

    var body: some View {
        // The editor (or editor-over-panel split) fills the window above an
        // always-visible bottom bar of Terminal/Git/Changes/Problems toggle
        // buttons, VS Code-style.
        VStack(spacing: 0) {
            mainArea
            Divider()
            bottomBar
        }
        // Empty-gap fix: closing the last terminal tab leaves the panel selection
        // on `.terminal` with nothing to draw. Collapse the panel so the bar sits
        // flush at the bottom and a repeat click/⌘⇧T reopens it in one press.
        .onChange(of: terminalSessions.sessions.isEmpty) { isEmpty in
            if isEmpty && bottomPanel.wrappedValue == .terminal {
                bottomPanel.wrappedValue = nil
            }
        }
        // The terminal zone's size, pushed into the live sessions the way the
        // theme is — but from the *window root* rather than from the panel,
        // because a session can be created while the panel is not on screen
        // (⌘R/⌘U make one and only then show the panel) and because the panel is
        // torn down whenever the dock shows Log or Changes instead. Seeding on
        // appear is what lets `TerminalSessionsModel` size those later sessions
        // correctly; the `onChange` carries a Preferences edit or a zoom gesture
        // to every session, active or not. Both are no-ops for a session already
        // at that size.
        .onAppear { terminalSessions.applyFontSize(settings.terminalFontSize) }
        .onChange(of: settings.terminalFontSize) { size in
            terminalSessions.applyFontSize(size)
        }
        // Ask the model what statement — if any — belongs to the tab the user is
        // looking at. Attached to the window root rather than to the pane
        // because the pane renders nothing until this has produced something,
        // so it cannot be the thing that starts it; and keyed on
        // `leetCodeStatementKey` so it runs once per tab (or folder) change
        // rather than once per keystroke. The model answers `nil` for a tab that
        // is not a LeetCode solution file, which is what takes the pane back
        // down. Cache first, network behind it — see `LeetCodeModel.statement`.
        .task(id: leetCodeStatementKey) {
            await leetCode.statement(
                forFileAt: model.selectedFile?.url,
                in: settings.leetCodeFolderURL
            )
        }
        // The commit dialog is a sheet on the main window (⌘K, or the Local
        // Changes header button). `onDismiss` fires on every closing path — the
        // Commit that succeeded, Cancel, Esc — which is what makes the modal
        // autosave suspension `PisakaApp` raises on open impossible to strand.
        .sheet(isPresented: isCommitDialogPresented, onDismiss: onCommitDialogDismissed) {
            CommitDialogView(
                model: commitDialog,
                settings: settings,
                onCommit: onCommit,
                onCancel: { isCommitDialogPresented.wrappedValue = false }
            )
        }
        // Apply the theme at the window content root so it propagates to SwiftUI
        // and the hosted AppKit views. `settings` is observed, so flipping the
        // preference re-applies live (`.system` maps to `nil`, i.e. follow the
        // system appearance).
        .preferredColorScheme(settings.themePreference.colorScheme)
        // The interface zone's scale, injected at the window root so every chrome
        // view below — including the commit sheet presented from this body —
        // inherits it. The editor, the terminal and the diff/merge panes are
        // deliberately unaffected: they draw at their own zones' font sizes.
        .interfaceScaled(settings)
    }

    /// What a statement request depends on: which tab is selected, and where the
    /// LeetCode folder is. Both halves, because the association needs both — a
    /// file's *name* names a problem only when the file also sits inside that
    /// folder — so re-pointing the folder has to re-ask the question for the tab
    /// already open.
    ///
    /// The folder is read from `settings` rather than from `leetCode`
    /// (`solutionsFolder` holds the same URL) precisely because `settings` is
    /// observed here and the model is not: `LeetCodeFolderChooser` writes both
    /// halves, and this is the half that invalidates this view.
    private var leetCodeStatementKey: String {
        let file = model.selectedFile?.url?.path ?? ""
        let folder = settings.leetCodeFolderURL?.path ?? ""
        return file + "\u{0}" + folder
    }

    /// The editor split, optionally with a bottom dock panel below it. The panel
    /// sits at a manually managed `panelHeight` (held independently of which panel
    /// is shown, so it persists across switches and hide/show — unlike the old
    /// recreated `VSplitView`), separated by a draggable divider. The terminal
    /// branch is shown only when there is a live session, so an emptied terminal
    /// never draws a bare tab bar (the empty-gap bug); the Log panel has no such
    /// precondition.
    @ViewBuilder
    private var mainArea: some View {
        if let panel = visiblePanel {
            // `GeometryReader` gives the available height so the panel-height drag
            // can clamp against the window (lower bound 120pt, upper bound half the
            // area). Existing terminal sessions keep the directory they were
            // started in — only `newSession` reads `projectRoot` — so a folder
            // switch never moves a running shell.
            GeometryReader { geo in
                VStack(spacing: 0) {
                    editorSplit
                        .frame(maxHeight: .infinity)
                    panelDivider(maxHeight: geo.size.height)
                    panelContent(panel)
                        .frame(height: clampedPanelHeight(maxHeight: geo.size.height))
                }
            }
        } else {
            editorSplit
        }
    }

    /// The draggable divider between the editor and the bottom dock panel. Drag up
    /// to grow the panel, down to shrink it; the cumulative translation is applied
    /// to the height captured at drag start so it does not compound frame-to-frame.
    private func panelDivider(maxHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color(NSColor.separatorColor))
            .frame(height: metrics.scaled(5))
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let base = panelDragStartHeight ?? panelHeight
                        if panelDragStartHeight == nil { panelDragStartHeight = base }
                        panelHeight = clampedPanelHeight(
                            proposed: base - value.translation.height,
                            maxHeight: maxHeight
                        )
                    }
                    .onEnded { _ in panelDragStartHeight = nil }
            )
    }

    /// `panelHeight` clamped to `[120, maxHeight / 2]` (lower bound floored so a
    /// tiny window still yields a usable lower bound), the floor itself scaled by
    /// the interface zone so a 200% terminal tab strip still leaves room for the
    /// panel's content.
    private func clampedPanelHeight(maxHeight: CGFloat) -> CGFloat {
        clampedPanelHeight(proposed: panelHeight, maxHeight: maxHeight)
    }

    private func clampedPanelHeight(proposed: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let floor = metrics.scaled(120)
        let upper = max(floor, maxHeight / 2)
        return min(max(proposed, floor), upper)
    }

    /// The panel to actually render below the editor: the selected `bottomPanel`,
    /// except `.terminal` collapses to `nil` while there are no live sessions.
    private var visiblePanel: BottomPanel? {
        switch bottomPanel.wrappedValue {
        case .terminal where terminalSessions.sessions.isEmpty:
            return nil
        case let panel:
            return panel
        }
    }

    @ViewBuilder
    private func panelContent(_ panel: BottomPanel) -> some View {
        switch panel {
        case .terminal:
            TerminalPanelView(model: terminalSessions, projectRoot: model.projectRoot)
        case .log:
            // No `minWidth: 640`/`minHeight: 400` here — those over-expand the
            // shorter bottom panel; a modest `minHeight` keeps it usable.
            CommitLogView(model: commitLog, projectRoot: model.projectRoot, onOpenCommitDiff: onOpenCommitDiff)
                .frame(minHeight: metrics.scaled(160))
        case .changes:
            // Local Changes is now a bottom dock panel (beside Terminal/Git),
            // rendered as the file list only — the diff opens in a separate window
            // on double-click via `onOpenDiff`.
            LocalChangesView(
                model: localChanges,
                projectRoot: model.projectRoot,
                onRevert: onRevert,
                onOpenDiff: onOpenDiff,
                onResolveConflict: onResolveConflict,
                onJumpToSource: jumpToSource,
                onOpenFile: onOpenFile,
                onCommit: onOpenCommitDialog,
                onCommitFile: onCommitFile
            )
                .frame(minHeight: metrics.scaled(120))
        case .problems:
            problemsPanel
                .frame(minHeight: metrics.scaled(120))
        }
    }

    /// The Problems panel, hosted like its three siblings. `diagnostics` is
    /// optional (`nil` in previews/tests), and a default-constructed throwaway
    /// model would both allocate per body evaluation and never update — so the
    /// nil branch renders the same empty state the real model shows when no
    /// server has reported anything.
    @ViewBuilder
    private var problemsPanel: some View {
        if let diagnostics {
            ProblemsPanelView(
                model: diagnostics,
                projectRoot: model.projectRoot,
                onActivate: onActivateProblem
            )
        } else {
            Text("No problems")
                .font(metrics.scaledFont(.callout))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The always-visible bottom bar: Terminal/Git/Changes/Problems toggle
    /// buttons, the active one highlighted. Clicking goes through `onTogglePanel`
    /// (shared with the View menu) so a button and its matching command behave
    /// identically.
    private var bottomBar: some View {
        HStack(spacing: metrics.scaled(4)) {
            bottomBarButton(title: "Terminal", systemImage: "terminal", panel: .terminal)
            bottomBarButton(title: "Git", systemImage: "arrow.triangle.branch", panel: .log)
            bottomBarButton(title: "Changes", systemImage: "arrow.triangle.pull", panel: .changes)
            bottomBarButton(title: "Problems", systemImage: "exclamationmark.triangle", panel: .problems)
            Spacer()
            // JetBrains-style branch widget on the right of the status bar: shows
            // the current branch and opens the switch/create popover.
            BranchSwitcherView(
                model: branchSwitcher,
                onSwitch: onSwitchBranch,
                onCreateFromRemote: onCreateBranchFromRemote,
                onCheckoutRemote: onCheckoutRemote,
                onNewBranch: onNewBranch
            )
            completionToggleButton
        }
        .padding(.horizontal, metrics.scaled(8))
        .padding(.vertical, metrics.scaled(4))
    }

    /// The completion on/off switch at the trailing end of the status bar, in the
    /// same plain-button idiom as `bottomBarButton`. It writes *straight through*
    /// to `settings.completionEnabled` with no local `@State`, which is what makes
    /// it impossible for this icon and the Preferences checkbox to disagree: both
    /// are views of the one stored flag. Off is total — no automatic popup and no
    /// explicit invocation — but nothing in the intelligence stack is torn down,
    /// so ⌃⌘J go-to-definition keeps working and flipping it back on costs a
    /// keystroke, not a restart.
    private var completionToggleButton: some View {
        let isOn = settings.completionEnabled
        return Button {
            settings.completionEnabled.toggle()
        } label: {
            Image(systemName: isOn ? "lightbulb" : "lightbulb.slash")
                .font(metrics.scaledFont(.callout))
                .padding(.horizontal, metrics.scaled(6))
                .padding(.vertical, metrics.scaled(3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        .help(isOn ? "Code completion: On" : "Code completion: Off")
        // Its siblings carry a `Label`, whose title *is* their accessibility
        // name; this one is deliberately icon-only, and `.help` is a tooltip
        // rather than a name — so the label and the state are spelled out here.
        // Without them this is the one bottom-bar control that cannot be
        // identified without sight, and it silently changes how the editor
        // behaves.
        .accessibilityLabel("Code completion")
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private func bottomBarButton(title: String, systemImage: String, panel: BottomPanel) -> some View {
        let isActive = bottomPanel.wrappedValue == panel
        return Button {
            onTogglePanel(panel)
        } label: {
            Label(title, systemImage: systemImage)
                .font(metrics.scaledFont(.callout))
                .padding(.horizontal, metrics.scaled(8))
                .padding(.vertical, metrics.scaled(3))
                .background(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: metrics.scaled(5)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
    }

    private var editorSplit: some View {
        HSplitView {
            // Left zone: the project tree. (Local Changes is now a bottom dock
            // panel, so the old "Project ⇄ Changes" segmented toggle is gone.)
            ProjectTreeView(
                model: model,
                onOpenFile: onOpenFile,
                onOpenFolder: onOpenFolder,
                mayBeginFileOperation: mayBeginFileOperation,
                onNewFile: onNewFile,
                onNewFolder: onNewFolder,
                onRename: onRename,
                onDelete: onDelete,
                onRun: onRun,
                onRunTest: onRunTest,
                onMove: onMove
            )
            // Every pane's minimum, ideal and maximum width is scaled: at the top
            // of the range the tree's rows are half again as tall and their names
            // half again as wide, so a fixed 180pt floor would clip exactly the
            // content the zoom was asked to enlarge.
            .frame(
                minWidth: metrics.scaled(180),
                idealWidth: metrics.scaled(240),
                maxWidth: metrics.scaled(360)
            )

            switch settings.tabOrientation {
            case .vertical:
                // Middle zone: vertical tab list, as its own resizable column.
                TabListView(model: model, orientation: .vertical, onClose: onClose)
                    .frame(
                        minWidth: metrics.scaled(180),
                        idealWidth: metrics.scaled(220),
                        maxWidth: metrics.scaled(320)
                    )

                // Right zone: the editor zone for the selected tab, with the
                // LeetCode statement beside it when there is one.
                HStack(spacing: 0) {
                    // The 320pt floor stays on the *editor*, not on the zone: put
                    // it on the `HStack` and the pane's width comes out of the
                    // editor's minimum, so a wide statement can squeeze the text
                    // view to a sliver. The zone's own minimum then composes as
                    // editor + pane, which is what it should be.
                    editorZone
                        .frame(minWidth: metrics.scaled(320), maxWidth: .infinity, maxHeight: .infinity)
                    descriptionPane
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .horizontal:
                // No separate tabs column: a horizontal tab strip is stacked above
                // the editor zone in the right zone instead. The statement pane
                // sits beside the *whole* column, tab strip included, so it spans
                // the full height in both orientations.
                HStack(spacing: 0) {
                    // The 320pt floor is on the editor column here too, for the
                    // reason spelled out in the vertical branch above.
                    VStack(spacing: 0) {
                        TabListView(model: model, orientation: .horizontal, onClose: onClose)
                            .frame(height: metrics.scaled(32))
                        Divider()
                        editorZone
                    }
                    .frame(minWidth: metrics.scaled(320), maxWidth: .infinity, maxHeight: .infinity)
                    descriptionPane
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The window's own minimum, scaled with the rest: at 200% the panes it
        // has to hold are twice as wide, so a fixed floor would let the user
        // shrink the window until the chrome clipped.
        .frame(minWidth: metrics.scaled(640), minHeight: metrics.scaled(400))
    }

    /// The LeetCode statement beside the editor. Renders **nothing at all** —
    /// no divider, no width — unless the model has a statement for the active
    /// tab, which is the only way this view can host it without observing
    /// `leetCode` itself (see the note on that property, and the one on the
    /// pane).
    private var descriptionPane: some View {
        // The workspace goes down as a plain value, not as an observed object:
        // the judge section reads the live buffer only when a button is pressed,
        // and this is the same non-observed hand-off `commitDialog` gets. The
        // *selection* travels separately because it is what re-prepares the judge
        // — and this view is already watching it.
        LeetCodeDescriptionPane(
            model: leetCode,
            settings: settings,
            workspace: model,
            activeFileURL: model.selectedFile?.url
        )
    }

    /// The text editor for the selected tab, or a placeholder when no file is open.
    /// (The inline diff pane is gone — diffs open in a separate window on
    /// double-click.) Shared by both tab orientations.
    @ViewBuilder
    private var editorZone: some View {
        if let file = model.selectedFile {
            VStack(spacing: 0) {
                // The metrics travel as a stored property rather than through the
                // environment precisely because this view is `.equatable()`:
                // SwiftUI compares the view's *values* to decide whether to
                // re-render, so a scale that lived only in the environment would
                // leave the breadcrumb at its old size until the file changed.
                PathBarView(fileURL: file.url, projectRoot: model.projectRoot, metrics: metrics)
                    .equatable()
                Divider()
                // The consent banner (D15), between the breadcrumb and the find
                // bar so it is the topmost thing in the editor zone without
                // covering the file's own path. It renders nothing at all unless
                // the selected tab's language has an unanswered, uninstalled
                // server this app can provision — downloaded, downloaded behind a
                // toolchain gate, or built by the user's own Go toolchain — and it
                // is also where an *already* accepted server is installed on first
                // use — both keyed on this one language and on there being a
                // project to serve.
                LSPConsentBanner(
                    provisioning: provisioning,
                    gopls: gopls,
                    rust: rust,
                    language: SyntaxLanguage(forFileName: file.displayName),
                    hasProjectRoot: model.projectRoot != nil
                )
                // The find/replace bar sits between the breadcrumb and the editor,
                // so it covers both tab orientations at once (in `.horizontal` it
                // simply lands under the tab strip). Rendered only while open —
                // closing it also drops the match highlight, which the state's
                // `close()` asks the controller to do directly.
                if search.isVisible {
                    SearchBarView(search: search)
                    Divider()
                }
                CodeEditorView(
                    fileID: file.id,
                    fileName: file.displayName,
                    openFileIDs: Set(model.openFiles.map(\.id)),
                    externalTextRevision: model.textReplacementRevision(for: file.id),
                    fileURL: file.url,
                    diskRevision: model.diskRevision(for: file.id),
                    projectRoot: model.projectRoot,
                    text: binding(for: file.id),
                    fontSize: settings.fontSize,
                    completionEnabled: settings.completionEnabled,
                    interfaceMetrics: metrics,
                    search: search,
                    reveal: reveal,
                    symbolIndex: symbolIndex,
                    editorConfig: editorConfig,
                    saveTransform: saveTransform,
                    lspSync: lspSync,
                    diagnostics: diagnostics,
                    onGoToDefinition: onGoToDefinition,
                    onViewDefinitionOutsideProject: onViewDefinitionOutsideProject
                )
            }
        } else {
            Text("No file open")
                .font(metrics.scaledFont(.body))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A binding to a specific file's text that routes writes through the model
    /// so dirty state is tracked. Reads find the file by `id` each time, so the
    /// binding stays valid as `openFiles` changes.
    private func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { model.openFiles.first { $0.id == id }?.text ?? "" },
            set: { model.updateText($0, for: id) }
        )
    }

    /// Jump to a changed file's source in the editor, resolving the
    /// repo-relative path against the repository root. A `nil` root (no folder
    /// open) or a deleted file is a silent no-op — the beep in `openFile(url:)`
    /// is the failure signal.
    private func jumpToSource(_ file: ChangedFile) {
        guard let root = localChanges.root,
              let url = LocalChangesModel.jumpToSourceURL(for: file, root: root)
        else { return }
        onOpenFile(url)
    }
}

/// The VS Code-style breadcrumb bar above the editor: the open file's path
/// relative to the opened project root (`backend › src › dialogs.service.ts`), or
/// an abbreviated absolute path when it lives outside the root. All the segment
/// computation is `PisakaCore.DisplayPath` — this is display only, so the view
/// stays thin and the rule stays unit-tested. `home` is read here (Core takes it
/// as a parameter, the `TerminalLaunch` precedent).
///
/// A fixed row height keeps the editor from jumping as the path changes, and
/// middle truncation keeps the file name visible in a narrow window. Rendered
/// inside `ContentView.editorZone`, so both tab orientations get it (in
/// `.horizontal` it lands just under the tab strip).
///
/// It is a separate `Equatable` view — rather than a `@ViewBuilder` on
/// `ContentView` — because `DisplayPath.components` resolves symlinks
/// (`CanonicalPath.canonical` → `resolvingSymlinksInPath()`, an `lstat` walk per
/// path component) while `ContentView.body` re-evaluates on *every* keystroke:
/// the editor binding routes each edit through `model.updateText`, republishing
/// `openFiles`. Keying the view on `(fileURL, projectRoot)` alone lets SwiftUI
/// skip the recompute unless the tab or the project root actually changed, so
/// that filesystem work stays off the typing path.
///
/// The interface metrics are a stored property for the same reason the identity
/// is: equality decides whether SwiftUI re-runs this body at all, so the scale
/// has to be part of what it compares.
private struct PathBarView: View, Equatable {
    let fileURL: URL?
    let projectRoot: URL?
    let metrics: InterfaceMetrics

    var body: some View {
        Text(
            DisplayPath.components(
                fileURL: fileURL,
                projectRoot: projectRoot,
                home: FileManager.default.homeDirectoryForCurrentUser
            )
            .joined(separator: " › ")
        )
        .font(metrics.scaledFont(.caption))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, metrics.scaled(8))
        .frame(
            maxWidth: .infinity,
            minHeight: metrics.scaled(22),
            maxHeight: metrics.scaled(22),
            alignment: .leading
        )
    }
}

#endif
