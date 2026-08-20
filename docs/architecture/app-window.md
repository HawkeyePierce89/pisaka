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
    LSPConsentBanner(provisioning:gopls:rust:language:hasProjectRoot:); <SearchBarView while
    search.isVisible>; CodeEditorView(…) }` — so the find bar
    sits between the breadcrumb and the editor and, living inside `editorZone`,
    covers **both** tab layouts at once (in `.horizontal` it simply lands under the
    tab strip). The consent banner (phase 2b, entry in `core-provisioning.md`) sits
    above the find bar so it is the topmost thing in the editor zone without
    covering the file's own path; it is keyed on `SyntaxLanguage(forFileName:
    file.displayName)` and on `model.projectRoot != nil`, and renders nothing at
    all — no layout, no divider — unless that language has an unanswered,
    uninstalled server *this app can provision* — downloaded (phase 2b), **built
    by the user's own Go toolchain** (gopls, D17), or **downloaded behind a
    toolchain gate** (rust-analyzer, D21–D24) — *and* there is a project for it
    to serve
    (`LSPWorkspace` refuses to prepare anything without a root, so offering the
    download with only a loose file open would spend a permanent, one-shot consent
    on something that could not demonstrate itself). The three contributors serve
    disjoint languages, so the branches cannot collide today; the precedence is
    nonetheless stated as **2b → Go → Rust** (the composition order, and the order
    the Settings tab lists them), because a strip that asked two questions at once
    would be a worse thing to discover than an arbitrary order.
    `gopls: LSPGoplsProvisioningModel` and `rust: LSPRustProvisioningModel` are
    threaded in beside `provisioning` and, like it, are **not** observed by
    `ContentView` — the banner observes all three itself, so an install's state
    changes redraw the strip and not the window. The same
    keyed view is where an *already accepted* server is installed on first use, so
    both halves of "what happens when this file is opened" stay in one place; the
    Go and Rust halves of that await discovery rather than reading it, since each
    search is started unawaited at launch and a restored `.go`/`.rs` tab regularly
    beats it (entry in `core-lsp.md`).
    The **LeetCode description pane** (LC-1, full entry in `core-leetcode.md`) is
    the trailing child of an `HStack` around the editor split — a sibling, never a
    fourth `HSplitView` column and never a conditional *wrapping* the editor, since
    a split child that comes and goes resets every column's width and a wrapper
    would tear down the `NSTextView`, its undo stack and its scroll position on
    every LeetCode tab selection. `leetCode: LeetCodeModel` is threaded in beside
    `provisioning`/`symbolIndex` and, like them, is **not** observed here: the pane
    observes it itself and renders *nothing at all* — no divider, no width — until
    there is a statement, which is why the window cannot decide the pane's
    visibility and does not try. What the window *does* own is the fetch, a
    `.task(id:)` keyed on **(selected tab path, LeetCode folder)** beside the
    bottom-dock `onChange`: both halves, because the association needs both, and
    the folder is read from `settings` (observed here) rather than from
    `model.solutionsFolder` (not) — `LeetCodeFolderChooser` writes both halves and
    only one of them invalidates this view. The pane cannot start the request
    itself, since it does not exist until the statement does.
    LC-2 puts two more values through the same hand-off, for the judge section the
    pane now hosts under the statement: `workspace: model` and
    `activeFileURL: model.selectedFile?.url`. The workspace is a **plain value**,
    the `commitDialog`/`symbolIndex` rule again and for its sharpest reason — an
    `@ObservedObject` would re-render that section on every keystroke *in the file
    being solved* — and nothing down there reads a buffer at render time; the judge
    reads one synchronously when a button is pressed. The selection travels
    **separately** precisely *because* the workspace is not observed: that value is
    what re-runs the judge's `prepare`, so it has to come from a view that is
    watching it, and this is that view. The editor's 320pt
    `minWidth` stays on `editorZone` (the horizontal branch: on the `VStack` that is
    the tab strip plus the editor) rather than moving to the new `HStack`: on the
    wrapper it would be the floor for *editor + pane*, so a wide statement would
    come out of the text view's minimum and squeeze it to a sliver. The zone's own
    minimum then composes as editor + pane, which is what it should be.
    `ContentView` takes `search: EditorSearchState` and `reveal:
    EditorRevealState` (both defaulted so previews compile) and threads them into
    `CodeEditorView`, along with `fileURL: file.url` and `diskRevision:
    model.diskRevision(for: file.id)` for the gutter's git-blame column (both with
    defaults on the editor side, so the existing parameter order is untouched and a
    default-constructed `CodeEditorView` still compiles). Three more pass straight
    through to the editor for **code intelligence**: the `SymbolIndexController`
    that schedules the shown file's re-index, `onGoToDefinition`, wired to
    `PisakaApp`'s Find-in-Files activation path (opening a tab is the app's job),
    and `onViewDefinitionOutsideProject`, wired to the read-only source viewer
    window (D3). The last two are separate closures rather than one with a flag,
    because opening a tab and opening a model-less window are different app-level
    operations that happen to be reached from the same click.
    The controller is deliberately **not** `@ObservedObject` — it publishes nothing,
    and the index model behind it republishes after every chunk of a walk, which is
    exactly the per-update cost `PathBarView.equatable()` and the non-observed
    `commitDialog` exist to keep off this view; both default (to a controller over a
    fresh, never-walked index, and a no-op) so previews compile.
    The private `PathBarView` is the VS Code-style
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
    At the **trailing end** of the same bar, after the branch widget, sits the
    completion on/off switch (T-4): `completionToggleButton`, in the existing
    `bottomBarButton` idiom (plain button style, accent tint when active,
    secondary when not), showing `lightbulb` when on and `lightbulb.slash` when
    off with a `.help(…)` naming the state ("Code completion: On" / "Code
    completion: Off"). Unlike its siblings it is deliberately icon-only, so it
    carries no `Label` title to serve as its accessibility name and `.help` is a
    tooltip rather than a name: the label and the state are therefore spelled out
    with `.accessibilityLabel("Code completion")` + `.accessibilityValue(…)`,
    without which the one bottom-bar control that silently changes how the editor
    behaves could not be identified without sight. It writes **straight through** to
    `settings.completionEnabled` with no local `@State`, which is what makes it
    impossible for this icon and the Preferences → General checkbox to disagree:
    both are views of the one stored flag (`core-services.md`), as is the iOS
    Settings row. The same flag is passed down to `CodeEditorView` as
    `completionEnabled:` beside `fontSize` — a plain value, no new observation
    path (`app-editor.md`) — and `PisakaApp` greys out Find > "Complete" while it
    is off, so an explicitly invoked command is never a silent no-op. Off is
    total but tears nothing down: ⌃⌘J go-to-definition keeps working and flipping
    it back on costs a keystroke, not a restart.
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
    It threads `settings.fontSize` into the code views — the `onStepFontSize`
    callback that used to accompany it is gone with `CodeFontScroll`, since the
    app's one zoom event monitor now receives every ⌘/⌃-scroll and pinch
    (`core-zoom.md`).
    Two further zoom responsibilities land on this root because it is the window's
    root. It applies **`.interfaceScaled(settings)`**, so every chrome view below
    — including the commit sheet presented from this body — inherits the interface
    zone's `InterfaceMetrics`, while the editor, the terminal and the diff/merge
    panes are deliberately unaffected (they draw at their own zones' sizes); and it
    pushes the **terminal** zone's size into the live sessions with `.onAppear {
    terminalSessions.applyFontSize(settings.terminalFontSize) }` plus an
    `.onChange(of:)`, from here rather than from the panel because a session can be
    created while the panel is off screen (⌘R/⌘U) and the panel is torn down
    whenever the dock shows Log or Changes (`app-terminal.md`). Being the root that
    *injects* the environment, it reads its own metrics from
    `settings.interfaceMetrics` rather than from `@Environment` — an environment
    write reaches descendants, not the view that makes it — and every view below it
    reads the environment. Its own scaled constants include the panel divider, the
    bottom bar's paddings and icon fonts, the bottom panels' minimum heights and
    the panel-height floor, so a 200% terminal tab strip still leaves room for the
    panel's content.
  - `DiffWindowContent.swift` — the SwiftUI content of a separate diff window
    (opened on double-click of a Local Changes row or a commit's file). Independent
    of the main window's selection: it takes `fileID`, `fileName`, a model-
    agnostic `load: () async -> [DiffRow]` closure (the owner binds the model and
    arguments in — `LocalChangesModel.rows(for:)` or `CommitLogModel.rows(for:in:)`),
    and an observed `settings: SettingsStore` so the separate window's font tracks
    the shared editor font size (the Preferences stepper or a zoom over the pane),
    a forced theme reaches it via `.preferredColorScheme`, and — being an
    `NSHostingController` root of its own — the interface zone reaches its chrome
    via `.interfaceScaled(settings)`. Each such root applies that modifier itself:
    a hosting controller starts a *new* SwiftUI tree, so nothing is inherited from
    the main window, and the same is true of `SourceViewerContent`,
    `ProjectSearchView`, `MergeView` and `LeetCodeBrowserView` (sheets, which are
    presented from an already-scaled root, inherit it and do not repeat it). The
    diff *rows* stay on the code zone throughout — the interface scale never
    multiplies a code-font site. It
    shows "Loading…" until the async load resolves (the row methods shell out to
    `git show`), then renders the read-only
    `DiffView(fileID:fileName:rows:fontSize:)`. The
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
  - `SourceViewerWindowController.swift` — owns the separate, non-modal **source
    viewer** windows a Go to Definition opens when the declaration lives *outside*
    the opened folder (`core-lsp.md`'s D3): an SDK `.swiftinterface`, a dependency
    checkout, a generated header. Same shape as `DiffWindowController` — an
    `NSHostingController` inside an `EscClosableWindow`, retained for its lifetime,
    released on `windowWillClose` through a per-window delegate held alongside
    (because `NSWindow.delegate` is `weak`), and `closeAll()` from the app's
    `willTerminateNotification` observer.
    **Two deliberate differences from the diff windows.** *It reads the file itself,
    before creating the window.* `DiffWindowContent` loads asynchronously and shows
    "Loading…" because its rows come from `git show`; here the whole content is one
    file read, and doing it up front is what lets an unreadable target — a path the
    server named that has since moved, a permission the app does not have, a binary
    or oversize file — be reported as *nothing happened*: `open` returns `false`
    having created nothing, and `PisakaApp.viewDefinitionOutsideProject` beeps,
    exactly as a ⌘-click that resolved nothing does. It reads through
    `FileService.readTextIfNotBinary` under
    `LSPIntelligenceProvider.maximumTargetFileBytes` — deliberately the same door and
    the same cap the provider already used to turn the server's `(line, character)`
    into an offset, so a file the provider refused produced no candidate at all and
    the viewer can never be asked for something larger. *It reuses a window per file.*
    Diff windows state outright that they do not dedup, and are right not to — two
    diffs of one file at different commits are different documents — but a viewer
    shows a *file*, so ⌘-clicking three `Foundation` symbols must not leave three
    identical windows; a second jump into a file already open re-reveals through that
    window's own `EditorRevealState` token and brings it forward. The key is the
    **symlink-resolved** path, for `CanonicalPath`'s reason: a server answers with the
    path *it* resolved (`/private/tmp/…` for a folder opened as `/tmp/…`), and two
    spellings of one file must not become two windows.
    **Structurally read-only**: nothing here creates a `WorkspaceModel` tab, touches
    `AutosaveController`, or keeps a writable handle — the content is a `String`
    copied out of the file once. There is no code path from a viewer window back to
    disk, which is the actual guarantee D3 is after: a semantic jump into the SDK
    cannot write outside the project root because there is nothing to write *with*,
    not because a flag is set correctly.
  - `SourceViewerContent.swift` — the SwiftUI content of a source viewer window:
    one file, read-only, syntax-highlighted, scrolled to a range. Modeled on
    `DiffWindowContent` + `DiffView`'s read-only pane — same `preferredColorScheme`
    propagation into a separate window, same Neon highlighting through
    `SyntaxLanguageConfiguration`/`SyntaxTheme`, same `@ObservedObject`
    `SettingsStore` so the viewer's font tracks the editor's. Its small
    `NSTextView` subclass (`SourceViewerTextView`) no longer overrides
    `scrollWheel`; it declares `zoomSurfaceKind = .code` instead, and the view is
    one of the `NSHostingController` roots that applies `.interfaceScaled(settings)`
    — so a gesture over the text grows the code zone and one over the window's
    chrome grows the interface zone (`docs/architecture/core-zoom.md`). Unlike the
    diff it loads nothing asynchronously.
    **It is not `CodeEditorView` with `isEditable = false`.** That view brings the
    binding it writes back through, per-file undo managers, auto-pair and auto-indent
    interception, the symbol re-index, blame, the minimap and completion — none of
    which means anything for a file that is not a tab. What is left after removing all
    of it is `DiffView.makePane` plus the editor's own `LineNumberRulerView` gutter
    (with `canAnnotate` left false: blaming a file outside the repository would be a
    `git` error, not an annotation). Read-only but **selectable**, because copying a
    signature out of an SDK interface is the second thing anyone does after jumping
    into one. Same TextKit 1 / no-soft-wrap setup as the editor and the diff panes, so
    a logical line is one visual row and the gutter's numbers line up with the lines
    the server counted.
    **`EditorRevealState` is reused rather than reinvented**, which is what makes the
    reveal correct on the *first* showing too: the controller records the request
    before the content exists, and the pane consumes it on its first update — the same
    update that installs the text — which is the exact ordering that state was
    designed around for a Find in Files activation that has to open the file first.
    Each window gets its own state and a generated `fileID`, since a viewer shows one
    file for its whole life. `applyReveal` is the same one-shot, token-guarded,
    clamped rule as `CodeEditorView.Coordinator.applyReveal`, including the deferral
    to the next turn so the target range has been laid out (a freshly created window
    has laid out nothing yet) and the clamp-by-truncating-the-length so an empty range
    at the very end of the buffer does not scroll to the top.
  - `ProjectTreeView.swift` — the project file tree: when `projectRoot == nil`
    it shows a centered "Click to open a folder" hint whose whole pane is the
    click target (`contentShape(Rectangle())` + `onTapGesture`) and calls an
    `onOpenFolder()` callback (wired `PisakaApp → ContentView → ProjectTreeView`,
    same shape as `onOpenFile`). Otherwise recursive rows from the root.
    Directories are `DisclosureGroup`s (`DirectoryNodeView`) that lazily load
    children via `model.children(of:)` on expansion (with `@State`); files are
    clickable rows that call an `onOpenFile(url)` callback. Directory rows are
    drawn through a private `DisclosureGroupStyle` (`FolderDisclosureStyle` + its
    `FolderDisclosureRow`) that renders chevron and
    label as **one full-width row**: the whole row toggles expansion, not just the
    ~10pt chevron, and it carries the same hover highlight and padding as a file
    row (`FileRowView`), so both row kinds read and behave alike. Because the
    style draws the chevron itself there is no separate disclosure control, so
    "one click, one state change" holds by construction — the row's single
    `.onTapGesture` is the only path that changes expansion, and it is the same
    path a chevron click takes. Drawing it also *removes* a control assistive
    technology could actuate (a real disclosure triangle is a button with an
    expanded/collapsed value; an `onTapGesture` on an `HStack` is nothing), so
    the row re-declares itself as one — combined element, `.isButton`, the
    expansion state as its `accessibilityValue`, and an `accessibilityAction`
    toggling the same binding, adding no second expansion path. Both symbols
    inside that element — the style's chevron and the label's folder icon — are
    `.accessibilityHidden(true)`: combining children folds an unhidden SF
    Symbol's own name into the element's label ("chevron.right, folder fill,
    Sources"), and both are decorative beside the name, the button trait and the
    value. That restores
    **VoiceOver** actuation only: a trait is not a focusable control, so the
    chevron can no longer be reached under Full Keyboard Access. Accepted, and
    recorded rather than fixed — the tree has no keyboard navigation at all (a
    file row is an `onTapGesture` too), so focusing folder rows alone would make
    it half-navigable; restoring it is a tree-wide keyboard pass.
    `DirectoryNodeView` hands its right-click menu **to the style** (a
    `@ViewBuilder` closure the style stores) so the menu hangs off the row rather
    than the label: hover highlight, tap target and context menu are then one
    rectangle, as they already are on a file row. Left on the label the menu
    would have excluded the chevron column and the row's horizontal padding while
    the highlight covered them. The label therefore keeps only its
    `.frame(maxWidth: .infinity, alignment: .leading)`, and for truncation rather
    than for hit testing. The style renders `configuration.content` **only while
    expanded**, so a collapsed folder shows nothing — as the default style does,
    tearing content state down on collapse the same way. The lazy first load does
    *not* depend on that: it hangs off `onChange(of: isExpanded)` / `onAppear` and
    is unaffected either way. The style adds **no inset of its own** to `content`:
    measured on macOS, the default disclosure style indents content by **zero**
    (only its *label* sits right of the triangle), so all of the tree's *nesting*
    indent comes — before and after — from the `.padding(.leading,
    metrics.scaled(12))` `DirectoryNodeView` puts on each child row. A
    chevron-column-plus-spacing inset on `content` was tried and reverted: it
    measured 28pt of indent per level against today's 12pt, i.e. indent that never
    existed, truncating names in a ~200pt pane. What the chevron column *does*
    change is the **row lead**, and it changes it for both row kinds on purpose. A
    folder row's label starts one `horizontalPadding` + chevron column + spacing
    in (6 + 12 + 4 = 22pt at scale 1), which is more than the 12pt a child row is
    inset by; a file row therefore leads with the same empty gutter
    (`TreeRowLayout.chevronGutter`, the two constants scaled *separately* so the
    half-point grid cannot drift them apart). Without it, files sat at 18pt under a
    folder label at 22pt — children rendering 4pt **left** of their own parent,
    i.e. an inverted hierarchy. With it, a file's icon and a sibling folder's icon
    share a vertical line and every child sits exactly 12pt right of its parent at
    every depth and scale; the cost is that the tree's whole content, files
    included, sits one gutter further right than before this change (which is the
    ordinary file-tree layout, and the one visible geometry change here). The
    unscaled row geometry lives in one `TreeRowLayout` enum that **both** row kinds
    read (the horizontal/vertical padding and the hover-highlight color, plus the
    chevron column, its spacing and the gutter derived from the two) — as literals
    they would drift apart, and reading alike is the whole point. Every size goes
    through
    `\.interfaceMetrics` like the rest of the tree; the style names no
    `interfaceScale` and declares no zoom surface, so `ZoomSourceGatingTests`' set
    equalities are untouched. `DirectoryNodeView`
    takes a `startsExpanded` flag seeding `@State isExpanded` via
    `State(initialValue:)`: the root node is built with `startsExpanded: true`
    (its `.onAppear` loads children, since `onChange` never fires for an
    already-expanded node) so a freshly opened folder shows its first level
    immediately, while nested nodes default to `false` and load lazily on first
    expansion. The root's `.id(root)` resets node state when switching projects,
    so each newly opened folder also starts expanded. Rows render type-specific
    icons via `FileIcon(for:)` (a private `FileIconColor → SwiftUI Color` helper
    maps the semantic token to a concrete color). Directory-read errors are
    swallowed (`PlatformFeedback.warning()`, and `children` left *unset* rather
    than cached as an empty list, so collapsing and re-expanding retries a
    transient failure), never crashing the view — *except*
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
    **Drag and drop moves.** Every row *except the project root* is a drag
    source, and every *folder* row — the root included, which is how an entry is
    moved back to the top of the project — is a drop target (a *file* row is a
    drag source only: it installs no drop delegate and can never highlight as
    one); dropping an entry on
    a folder calls a seventh callback, `onMove(source, folder)`, threaded
    `PisakaApp → ContentView → ProjectTreeView` exactly like the other six and
    wired to `PisakaApp.moveItem(at:into:)`. The view decides nothing: whether a
    drop may land and where it lands are `MoveDropRule`'s answers
    (`core-workspace.md`), and the app re-asks the same engine behind the writer
    gate when the drop is performed. The payload is an `NSItemProvider` registered
    under the tree's **own private type identifier**
    (`ws.karmanov.pisaka.project-tree-row`, in a private `ProjectTreeDrag` enum),
    deliberately *not* `public.file-url`: registering the file url would offer
    every row to Finder as a file drag and let a Finder file be dropped onto a
    folder row — a different feature, with its own copy-vs-move, security-scope
    and cross-volume questions. Under this identifier the payload means nothing
    outside the tree, so a drag leaving the window does nothing and a foreign drag
    is refused by `validateDrop` before any rule runs. Nothing reads the payload
    back: the authoritative source url is the one a private, tree-wide
    `TreeDragSession` recorded when the drag started, which only this tree's own
    drag source sets. The item exists so the drag is legible to AppKit at all — a
    provider registering no type never begins a drag, which is also why the root
    row opts out through a `@ViewBuilder` branch (`projectTreeDragSource(isEnabled:
    url:session:)`) rather than by returning an empty provider. `TreeDragSession`
    is an `ObservableObject` with **no `@Published` property, on purpose**:
    starting a drag, crossing rows and finishing one must invalidate nothing,
    since everything a drag draws is a row's own `isDropTarget` `@State`. It also
    **memoizes** the full, disk-touching `MoveDropRule` decision keyed on the
    (source, target) pair — `validateDrop`, `dropUpdated` and `dropEntered` all
    ask repeatedly while the pointer sits in one row, and each fresh answer lists
    two directories, so the memo turns that into one listing per row *entered*.
    The shared `TreeDropDelegate` (taking the destination as a plain url, so it
    knows nothing about rows) accepts only when all three hold: the payload
    carries the private identifier, the session names a source, and the decision
    is `.move`. **A refusal decided there is therefore silent by construction**:
    SwiftUI documents `dropEntered`, `dropUpdated` and `performDrop` as running
    only for a drop `validateDrop` accepted, so a collision, a self-drop, a
    descendant or the same-parent no-op shows an unlit row and the refusal cursor
    and does nothing on release — it never reaches `moveItem` and never raises an
    alert. That leaves the alert for what the hover answer could not have caught
    (the writer gate; a destination that gained the name, or a source that
    vanished, between hover and release), which is what `moveItem`'s re-ask
    behind the gate is for — see `MoveDropRule`'s "How a refusal reaches the
    user" in `core-workspace.md`. `dropEntered` still sets `isDropTarget` from
    the answer rather than to a bare `true`, and `dropUpdated` still has a
    `.forbidden` branch: both are free (the session memoized the answer) and both
    keep the highlight tied to the rule rather than to that documented ordering.
    `performDrop` clears the session *before* calling `onMove`, and dispatches
    the callback **out of the drop callout** (`DispatchQueue.main.async`): a
    session still naming a source behind a modal alert would answer a later
    `validateDrop` for a drag that ended long ago, and a modal loop spun from
    inside AppKit's `performDragOperation:` blocks the drag session — and the
    source app with it — behind a dialog. The highlight is a new
    `TreeRowLayout.dropHighlight` (`accentColor.opacity(0.4)`), applied at the
    *same* site and from the same enum as `hoverHighlight` and deliberately
    stronger than it: the pointer is inside the row, so both conditions are true
    at once, and the difference between the two is the whole answer to "will this
    drop land here?" — drawing them from one place is what stops them drifting
    apart. Everything else on both row kinds is **unchanged and in the same
    order**: the row's single `.onTapGesture` still toggles a folder (a drag and a
    click are distinct gestures), the hover highlight, the full-row `.contextMenu`s
    and the row's accessibility re-declaration (combined element, `.isButton`, the
    expansion value, the toggle action) are exactly as above. Nothing here names
    `interfaceScale` and no zoom surface is declared, so `ZoomSourceGatingTests`'
    set equalities are untouched.
  - `TabListView.swift` / `TabRowView.swift` — the open-tabs list, with an
    `orientation: TabOrientation` parameter (default `.vertical`): vertical is the
    scrolling `LazyVStack` column; horizontal is a horizontal `ScrollView`/
    `LazyHStack` strip of `TabRowView`s sized for a row (the row drops its
    `maxWidth: .infinity` stretch in horizontal mode). `ContentView` picks the mode
    from `settings.tabOrientation`.
