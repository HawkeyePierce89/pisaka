# Pisaka app (macOS) — window chrome: ContentView, project tree, tabs, diff windows

Design documentation moved verbatim from the root `CLAUDE.md` (which now holds only a one-line-per-file index). Each entry records a file's contract, invariants and the reasoning behind non-obvious decisions — read the relevant entry before modifying that file, and update it when behavior changes.

  - `ContentView.swift` — three-column `HSplitView` (`editorSplit`): left zone is
    just `ProjectTreeView` (the old segmented "Project ⇄ Changes" toggle and
    `LeftPanelMode` are gone — Local Changes moved to the bottom dock), middle is
    the open-tabs list (`TabListView`), right zone is the `editorZone` — the
    `CodeEditorView` for the selected tab or a "No file open" placeholder (no
    inline diff — the old
    Changes-mode right-zone `DiffPane` branch and the `DiffPane` struct itself were
    removed; diffs open in a separate window on double-click). The `if let file`
    branch of `editorZone` is a `VStack(spacing: 0) { PathBarView(fileURL:
    file.url, projectRoot: model.projectRoot).equatable(); Divider();
    <SearchBarView while search.isVisible>; CodeEditorView(…) }` — so the find bar
    sits between the breadcrumb and the editor and, living inside `editorZone`,
    covers **both** tab layouts at once (in `.horizontal` it simply lands under the
    tab strip). `ContentView` takes `search: EditorSearchState` and `reveal:
    EditorRevealState` (both defaulted so previews compile) and threads them into
    `CodeEditorView`, along with `fileURL: file.url` and `diskRevision:
    model.diskRevision(for: file.id)` for the gutter's git-blame column (both with
    defaults on the editor side, so the existing parameter order is untouched and a
    default-constructed `CodeEditorView` still compiles). The private `PathBarView` is the VS Code-style
    breadcrumb: a `.caption`/`.secondary` `Text` of
    `DisplayPath.components(fileURL:projectRoot:home:
    FileManager.default.homeDirectoryForCurrentUser)` joined with `" › "`. All the
    segment logic is Core's `DisplayPath` (the view only reads `home` and picks
    the separator), so this stays display-only and untested like the rest of the
    view layer. It is a *separate `Equatable` view* rather than a
    `@ViewBuilder` on `ContentView` because `DisplayPath.components` resolves
    symlinks (`CanonicalPath.canonical` → `resolvingSymlinksInPath()`, an `lstat`
    walk per path component) while `ContentView.body` re-evaluates on **every**
    keystroke (the editor binding routes each edit through `model.updateText`,
    republishing `openFiles`): keying the view on `(fileURL, projectRoot)` alone
    lets SwiftUI skip the recompute unless the tab or the project root actually
    changed, keeping that filesystem work off the typing path. `.lineLimit(1)` +
    `.truncationMode(.middle)` keep the file name visible in a narrow window and a
    *fixed* 22pt row height keeps the editor from jumping as the path changes.
    Because it lives inside `editorZone` it covers **both** tab layouts at once —
    in `.horizontal` it simply lands under the tab strip — while the "No file
    open" branch is deliberately left bare (no bar without a file). The window
    body is a
    `VStack(spacing: 0) { mainArea; Divider(); bottomBar }`: an always-visible
    VS Code-style `bottomBar` of three toggle buttons (Terminal / Git / Changes,
    the active one highlighted, `arrow.triangle.pull` for Changes) sits flush at
    the bottom, and `mainArea` is the three-column `editorSplit` alone, or — when a
    `BottomPanel` is shown — `editorSplit` over the panel. The bottom bar also hosts
    the `BranchSwitcherView` (JetBrains status-bar convention) showing the current
    branch, threaded through as the `branchSwitcher: BranchSwitcherModel` /
    `onSwitchBranch` / `onCreateBranch` parameters (owned by `PisakaApp`, defaulted
    for previews).
    Panel-height persistence: instead of the old recreated `VSplitView` (which
    reset the height on every panel switch / hide-show), `mainArea` wraps a
    `GeometryReader` around a manual `VStack { editorSplit; panelDivider;
    panelContent(panel).frame(height: …) }`. A `@State private var panelHeight:
    CGFloat = 240` holds the height *independently of which panel is shown*, so it
    survives switches and hide/show (VS Code-style; `@State`-only — cross-launch
    `@AppStorage` is YAGNI). `panelDivider` is a 5pt draggable bar (resize-up-down
    cursor on hover) whose `DragGesture` updates `panelHeight` against a
    `panelDragStartHeight` captured at drag start (so the cumulative translation
    doesn't compound frame-to-frame), clamped via `clampedPanelHeight` to `[120,
    max(120, geo.height / 2)]`. `bottomPanel: Binding<BottomPanel?>` (`nil` = none,
    owned by `PisakaApp`) selects the panel; `panelContent(_:)` renders `.terminal`
    → `TerminalPanelView(model: terminalSessions, projectRoot: model.projectRoot)`
    (an existing terminal keeps its start directory — only `newSession` reads the
    current root), `.log` → `CommitLogView(model: commitLog, projectRoot:,
    onOpenCommitDiff:)` (modest `minHeight`, no full-width `minWidth`/`minHeight`
    that would over-expand the shorter panel), and `.changes` →
    `LocalChangesView(model: localChanges, projectRoot:, onRevert:, onOpenDiff:)`
    rendered as the file list only (the diff opens in a separate window on
    double-click via `onOpenDiff`). A bottom-bar button click routes through
    `onTogglePanel` (shared with the View menu, owned by `PisakaApp`) so a button
    and its matching command behave identically. Empty-gap fix: the `.terminal`
    panel renders only while `terminalSessions.sessions` is non-empty (a private
    `visiblePanel` collapses `.terminal` to `nil` when there are no sessions, so an
    emptied terminal never draws a bare tab bar), and an `.onChange(of:
    terminalSessions.sessions.isEmpty)` resets `bottomPanel` to `nil` when the last
    terminal tab closes so a repeat click / Cmd+Shift+T reopens it in one press.
    `onOpenDiff: (ChangedFile) -> Void` (Local Changes double-click),
    `onOpenCommitDiff: (ChangedFile, Commit) -> Void` (Git Log double-click), and
    `onResolveConflict: (ChangedFile) -> Void` (Local Changes "Resolve" /
    conflicted-file double-click, opening the 3-pane merge window) are
    callback parameters with default no-ops, threaded into the panel subviews
    (`PisakaApp → ContentView → subview`, same shape as `onRevert`/`onOpenFile`).
    `onRun: (URL) -> Void` is threaded the same way into `ProjectTreeView` (the
    file-row "Run" item), wired to `PisakaApp.runFile(url:)`; `onRunTest: (URL) ->
    Void` is threaded identically (the file-row "Run Test" item), wired to
    `PisakaApp.testFile(url:)`.
    The **commit dialog** is presented from here as a `.sheet` on the window
    content root, over the `commitDialog: CommitDialogModel` `PisakaApp` owns and
    loads: `isCommitDialogPresented: Binding<Bool>` raises it, `onOpenCommitDialog`
    is what the Local Changes header button calls (the ⌘K menu item's handler),
    `onCommitFile: (ChangedFile) -> Void` is the same handler with a preselect —
    threaded down into `LocalChangesView` in `panelContent(.changes)` beside
    `onRevert`/`onOpenDiff`/`onResolveConflict`/`onCommit`, and wired by `PisakaApp`
    to `openCommitDialog(preselectingPath: file.path)` so a row's "Commit…" item
    opens the dialog with only that file checked,
    `onCommit: (Int) async -> Void` runs the commit under `PisakaApp`'s gates (the
    `Int` being the project generation the sheet's Commit button captured
    synchronously before its `Task` hop — the `onReplaceAll` shape), and the
    sheet's `onDismiss` is `onCommitDialogDismissed` — fired on *every* closing
    path (a successful Commit, Cancel, Esc), which is what makes the modal autosave
    suspension raised on open impossible to strand. The model is held as a plain
    `var`, deliberately **not** `@ObservedObject` (unlike every other model here):
    this view never reads it, it only hands it to the sheet, which observes it
    itself — observing it here would re-evaluate the whole window (project tree,
    tab list, `CodeEditorView.updateNSView`, the bottom panel) on every keystroke
    in the message field, which is bound to the model's `@Published` `message`.
    All five default to
    `.constant(false)` / no-ops, and `commitDialog` to a real, `Process`-backed
    model, so a default-constructed view (previews/tests) still compiles.
    `bottomPanel`/`onTogglePanel`/`terminalSessions` default to `.constant(nil)` /
    a no-op / a fresh model so a default-constructed `ContentView` (previews/tests)
    compiles. It also takes the shared `settings: SettingsStore` (defaulted to a
    fresh store for previews) and applies two of its preferences: a private
    `ThemePreference.colorScheme` mapping (`.system → nil`, `.light → .light`,
    `.dark → .dark`, kept in the view layer) feeds `.preferredColorScheme(
    settings.themePreference.colorScheme)` on the window content root so a theme
    change re-applies live to SwiftUI and the hosted AppKit views; and
    `settings.tabOrientation` selects the tabs layout — `.vertical` keeps the
    `TabListView` as the middle `editorSplit` column (current behavior), while
    `.horizontal` drops that column and stacks a horizontal `TabListView` strip
    above the editor zone in the right zone (`VStack { strip; editor/placeholder }`),
    leaving `ProjectTreeView`, the bottom dock, and the rest of the split intact.
    It threads `settings.fontSize` and an `onStepFontSize` callback
    (`settings.stepFontSize(by:)`) into the code views.
  - `DiffWindowContent.swift` — the SwiftUI content of a separate diff window
    (opened on double-click of a Local Changes row or a commit's file). Independent
    of the main window's selection: it takes `fileID`, `fileName`, a model-
    agnostic `load: () async -> [DiffRow]` closure (the owner binds the model and
    arguments in — `LocalChangesModel.rows(for:)` or `CommitLogModel.rows(for:in:)`),
    and an observed `settings: SettingsStore` so the separate window's font tracks
    the shared editor font size (Stepper / Cmd+scroll) and a forced theme reaches it
    via `.preferredColorScheme`. It
    shows "Loading…" until the async load resolves (the row methods shell out to
    `git show`), then renders the read-only
    `DiffView(fileID:fileName:rows:fontSize:onStepFontSize:)`. The
    load is guarded by a `@State` generation token mirroring `DiffPane`/
    `CommitDiffPane` (though a window's `(fileID, load)` is fixed for its lifetime,
    so it keeps the single in-flight load honest).
  - `DiffWindowController.swift` — a `@MainActor final class` owning the separate,
    non-modal diff windows. `open(title:content:)` creates a fresh resizable
    `EscClosableWindow` (see below — so Esc closes the window) hosting
    `DiffWindowContent` via an `NSHostingController`, sets its
    title, sizes/centers it (900×600), and retains it; a per-window
    `NSWindowDelegate` forwards `windowWillClose` back to drop the window from the
    retained set (release on close — `isReleasedWhenClosed = false`, the delegate
    held alongside because `NSWindow.delegate` is `weak`). Multiple windows are
    allowed (no dedup/reuse — out of scope), so double-clicking the same file twice
    yields two windows. `closeAll()` closes every retained window (the app calls it
    on `willTerminateNotification` so none linger past termination), mirroring
    `TerminalSessionsModel.terminateAll()`.
  - `ProjectTreeView.swift` — the project file tree: when `projectRoot == nil`
    it shows a centered "Click to open a folder" hint whose whole pane is the
    click target (`contentShape(Rectangle())` + `onTapGesture`) and calls an
    `onOpenFolder()` callback (wired `PisakaApp → ContentView → ProjectTreeView`,
    same shape as `onOpenFile`). Otherwise recursive rows from the root.
    Directories are `DisclosureGroup`s (`DirectoryNodeView`) that lazily load
    children via `model.children(of:)` on expansion (with `@State`); files are
    clickable rows that call an `onOpenFile(url)` callback. `DirectoryNodeView`
    takes a `startsExpanded` flag seeding `@State isExpanded` via
    `State(initialValue:)`: the root node is built with `startsExpanded: true`
    (its `.onAppear` loads children, since `onChange` never fires for an
    already-expanded node) so a freshly opened folder shows its first level
    immediately, while nested nodes default to `false` and load lazily on first
    expansion. The root's `.id(root)` resets node state when switching projects,
    so each newly opened folder also starts expanded. Rows render type-specific
    icons via `FileIcon(for:)` (a private `FileIconColor → SwiftUI Color` helper
    maps the semantic token to a concrete color). Directory-read errors are
    swallowed (empty list / `NSSound.beep()`), never crashing the view — *except*
    a "no such file" error, which is swallowed silently: a revision-driven reload
    runs for every expanded node, so an external `rm -rf build` (which now reaches
    the tree on its own through `ProjectWatcher`) would otherwise beep once per
    expanded descendant before the parent's re-read drops them.
    Rows carry `.contextMenu`s for the writable tree, calling four callbacks
    threaded `PisakaApp → ContentView → ProjectTreeView` (same shape as
    `onOpenFile`/`onOpenFolder`): `onNewFile(dir)`, `onNewFolder(dir)`,
    `onRename(url)`, `onDelete(url)`, `onRun(url)`, and `onRunTest(url)`. A
    directory row offers New
    File… / New Folder… and (non-root only) Rename… / Delete; the root row offers
    only the two create actions; a file row offers Rename… / Delete, plus a "Run"
    item (play icon → `onRun(url)`) shown only when
    `RunCommand.canRun(url.lastPathComponent)` and a "Run Test" item
    (`checkmark.diamond` icon → `onRunTest(url)`) shown only when
    `TestCommand.isTestFile(fileName:)` (directories get neither item). The
    callbacks
    only request the operation — `PisakaApp` does the disk I/O and bumps
    `treeRevision`. `DirectoryNodeView` also observes
    `.onChange(of: model.treeRevision)`: when currently expanded it re-reads
    `children(of:)` so a created / renamed / deleted entry appears without
    reopening the folder; a collapsed node instead drops its cached children
    (`children = nil`) so its next expansion re-reads from disk — without this an
    already-loaded node targeted while collapsed would keep showing a stale
    listing (the lazy first-load only fires when `children == nil`). The
    `.id(root)` identity, `startsExpanded`, and lazy first-load are unchanged.
    With a folder open the rows sit under a small header (a `Divider` between them,
    modeled on the `LocalChangesView` header) holding one Refresh button
    (`arrow.clockwise`, `.borderless`, `.help("Refresh project tree")`) whose action
    is `model.bumpTreeRevision()` — called *directly*, not through a callback
    threaded from `PisakaApp`, since this view already observes the model and the
    bump needs no disk I/O. The header is absent from the `projectRoot == nil`
    placeholder so its whole pane stays the open-folder click target. So
    `treeRevision` — the single re-read trigger `DirectoryNodeView` observes — now
    has three sources: the app's own operations (the context-menu callbacks, Save As,
    a branch checkout), the FSEvents `ProjectWatcher` on macOS, and this button (the
    manual fallback for whatever the watcher misses — an FSEvents buffer overflow, a
    network volume, or simply not wanting to wait out the 1 s latency).
  - `TabListView.swift` / `TabRowView.swift` — the open-tabs list, with an
    `orientation: TabOrientation` parameter (default `.vertical`): vertical is the
    scrolling `LazyVStack` column; horizontal is a horizontal `ScrollView`/
    `LazyHStack` strip of `TabRowView`s sized for a row (the row drops its
    `maxWidth: .infinity` stretch in horizontal mode). `ContentView` picks the mode
    from `settings.tabOrientation`.
