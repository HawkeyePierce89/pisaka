# Pisaka app (macOS) — window chrome: ContentView, project tree, tabs, diff windows

Design documentation moved verbatim from the root `CLAUDE.md` (which now holds only a one-line-per-file index). Each entry records a file's contract, invariants and the reasoning behind non-obvious decisions — read the relevant entry before modifying that file, and update it when behavior changes.

  - `ContentView.swift` — three-column `HSplitView` (`editorSplit`): left zone is
    just `ProjectTreeView` (the old segmented "Project ⇄ Changes" toggle and
    `LeftPanelMode` are gone — Local Changes moved to the bottom dock), middle is
    the open-tabs list (`TabListView`), right zone is the `editorZone` — which
    routes on the selected tab's `kind` and **on nothing else**: a `.viewer` tab
    gets `DatabaseViewerHost(file:)` (`core-database-viewer.md`), **every** `.text`
    tab gets `markdownSplit(for:)` — the editor, and beside it the preview when
    that tab is previewed (`core-markdown-preview.md`) — and no tab at all a
    "No file open" placeholder (no
    inline diff — the old
    Changes-mode right-zone `DiffPane` branch and the `DiffPane` struct itself were
    removed; diffs open in a separate window on double-click). The `if let file`
    branch of **`editorZone`** — the host, not `textEditorZone(for:onScrolled:)`,
    which takes the file as a parameter and holds only what sits *below* the
    breadcrumb — is a `VStack(spacing: 0) { BreadcrumbBarView(fileURL: file.url,
    projectRoot: model.projectRoot); <the tab-kind routing above> }`: the
    breadcrumb first, for **every** tab kind (a database has a path like any
    other file), then either `DatabaseViewerHost(file:)` or
    `markdownSplit(for:)`, whose editor side is
    `textEditorZone(for:onScrolled:)` — `LSPConsentBanner(provisioning:gopls:rust:language:hasProjectRoot:)`,
    `<SearchBarView while search.isVisible>`, `CodeEditorView(…)`. So the find bar
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
    exactly the per-update cost `BreadcrumbBarView`'s inner `.equatable()` view and the non-observed
    `commitDialog` exist to keep off this view; both default (to a controller over a
    fresh, never-walked index, and a no-op) so previews compile.
    A fourth passes straight through for **indentation**: `editorConfig:
    EditorConfigModel`, owned by `PisakaApp` and read only by `CodeEditorView`'s
    Enter and Tab handlers. Like `symbolIndex` it is deliberately not
    `@ObservedObject` (it publishes nothing) but, unlike every other model here, it
    is **undefaulted**, so it joins `model` as a second required argument: the model
    is main-actor-isolated and takes a `FileServicing`, and any default worth
    writing would be a second *live disk reader* built for a view nobody constructs
    (`core-editorconfig.md`, `app-editor.md`).
    A fifth passes straight through for **saves**: `saveTransform:
    SaveTransformController?`, owned by `PisakaApp` and threaded into
    `CodeEditorView`, which attaches it to the live editor. Not `@ObservedObject`
    (it publishes nothing) and — unlike `editorConfig` — optional and defaulted, so
    `nil` in previews and tests simply transforms nothing and `model` +
    `editorConfig` stay the only two required arguments.
    The breadcrumb is no longer private to this file: it is
    `BreadcrumbBarView.swift`, with its own entry below. `ContentView` hosts it and
    adds **no** `Divider()` under it, exactly as it adds none under the horizontal
    tab strip — the strip draws its own bottom rule, so a host-drawn one would be a
    second rule nothing keeps in step with the height above it. Because the
    breadcrumb lives inside `editorZone` it covers **both** tab layouts at once —
    in `.horizontal` it simply lands under the tab strip — while the "No file
    open" branch is deliberately left bare (no bar without a file). The window
    body is a
    `VStack(spacing: 0) { mainArea; bottomBar }` — **no `Divider()` between
    them** since part three: the bar draws its own one-point `hairline` along
    its top edge, in the palette's value rather than the platform's. Keeping a
    rule there at all is a stated deviation from the design, which draws none:
    with the dock closed the editor's ground and the bar's are one value apart
    in the dark theme, so without it the bar would have no visible top edge. The
    body's root paints `chromeColor(.bgCanvas)`, the window's own ground, seen
    at the no-file-open placeholder; the dock's two empty states read as canvas
    but sit on the panel slot's own `bgPanel` (`core-theme.md`'s part-three
    window-ground entry carries the accounting). All three sentences read
    `textSecondary`.
    The colours are reached through a private `chromeColor(_:)`
    **role-to-colour function** resolving `settings.chromeTheme(systemPrefersDark:)`
    against `@Environment(\.colorScheme)`: a root cannot read the environment
    value it writes, and the function shape keeps this file from naming
    `ChromeTheme` (`core-theme.md`'s gating rule five). An always-visible
    `bottomBar` of six toggle buttons (Terminal / Log / Local Changes /
    Problems / Usages / Pull Requests — each name read from
    `BottomPanel.title`, the one table the dock's tab row reads too, so
    `bottomBarButton(systemImage:panel:)` takes no title of its own and a
    tooltip cannot disagree with a tab; the active one highlighted,
    `arrow.triangle.pull` for Changes and — deliberately *not* the same glyph —
    `arrow.triangle.merge` for Pull Requests, since two dock buttons drawn with
    one symbol are indistinguishable at a glance and, since part three made the
    seven controls icon-only, the glyph is all there is (the part-three
    paragraph below carries the current reason; the two are no longer
    *adjacent*, which is why adjacency is not it);
    `exclamationmark.triangle` for Problems,
    `text.magnifyingglass` for Usages) sits flush at
    the bottom, and `mainArea` is the three-column `editorSplit` alone, or — when a
    `BottomPanel` is shown — `editorSplit` over the panel, that panel slot
    painted `bgPanel` with **no rule of its own** (the divider above it carries
    the boundary — see the dividers below).

    **The dock's tab row sits inside `panelContent(_:)`** since part four (a):
    the body is a `VStack(spacing: 0)` of `DockTabRow` above the existing
    `switch`, because this is the one place every panel passes through — one
    call site, every panel gets it, and the slot's pinned frame, its top
    alignment, the clip, the divider and `panelHeightRule` are untouched (the
    row is part of the slot's content, not a strip beside it, so
    `BottomPanelSourceGatingTests`' pins on the call and the `switch` labels
    read the same). `onSelect` asks `BottomPanel.tabActivation(bottomPanel
    .wrappedValue, tab:)` and calls `onTogglePanel(target)` only on `case
    .show(let target)` — `toggled` then yields the target and never collapses —
    and `onClose` calls `onTogglePanel(panel)` with the showing panel, which
    `toggled` collapses. Both paths go through the bar's own funnel, which is
    also what creates the first terminal session, so the scene file gained no
    line. Entry: `DockTabRow.swift` below.

    **The bar since part three.** Its order is **reversed**: a leading group of
    the three widgets at 14-point gaps, a `Spacer()`, then the six panel toggles
    and the completion switch at 2-point gaps. The widgets say *where you are*
    (project, branch, pull request) and now read first; the controls, which say
    what you can open, collect at the trailing end beside the completion switch
    they already sat next to. Both gaps are bare local numbers scaled once —
    deriving either from a `ChromeGeometry` token would couple this bar's
    spacing to a measurement that means something else (gating rule seven). The
    bar itself takes `ChromeGeometry.bottomBarHeight`, a
    `ChromeGeometry.barPaddingX` horizontal inset, a `bgPanel` ground and the
    top `hairline` above. All seven controls — `bottomBarButton(…)` six times
    and `completionToggleButton` — are **icon-only squares**:
    `bottomBarToggleSide` on a side, `bottomBarToggleRadius` of corner radius,
    the icon at `.body`, an `accentTintStrong` ground under an `accent` icon
    while active and no ground under a `textSecondary` icon otherwise, each
    keeping `.contentShape(Rectangle())`. **The visible titles are gone**, which
    is what makes `.help(` and `.accessibilityLabel(` mandatory on every one of
    them rather than polite: the `Label(title, systemImage:)` they used to carry
    *was* each one's accessibility name, while an unhidden `Image(systemName:)`
    supplies a name of its own instead — the *symbol's* (`core-theme.md`'s rule
    ten). Gating
    rule ten pins both in the brace-matched bodies of `bottomBarButton(` and
    `completionToggleButton`, and pins `bottomBarButton(` at exactly seven
    occurrences — one declaration and one call per dock panel — so a seventh
    panel is asked the question rather than shipping under its glyph's name.

    **Both draggable dividers are drawn from the roles too.**
    `panelDivider(available:)` fills `bgPanel` and overlays a one-point
    `hairline` rectangle along its **top** edge;
    `markdownPreviewDivider(available:)` does the same with the rule along its
    **leading** edge. Each rule sits on the edge nearer the editor, which is the
    boundary it states; the dock divider *is* the dock's top edge, which is why
    the panel slot below draws no second rule (two hairlines five points apart
    read as a double rule). The 5-point drag target, the `contentShape`, the
    hover/drag cursor sync and the whole drag gesture below are unchanged — what
    moved is what is drawn, and it is a regression fixed rather than a new
    surface: each used to fill its five points with the platform's
    `separatorColor`, a five-point-wide rule in a value nothing beside it
    shares (`core-theme.md`). The bottom bar also hosts
    the `BranchSwitcherView` (the status-bar convention) showing the current
    branch, threaded through as the `branchSwitcher: BranchSwitcherModel` /
    `onSwitchBranch` / `onCreateBranch` parameters (owned by `PisakaApp`, defaulted
    for previews). Beside it sits the new project switcher (`ProjectSwitcherView`), threaded through as the `recentProjects: () -> [RecentProject]` / `onOpenRecentProject: (URL) -> Void` parameters (owned by `PisakaApp`, defaulted). Beside the branch widget sits
    `PullRequestIndicatorView`, reading the same model the panel does and drawing
    nothing at all unless the checked-out branch has an open pull request; its
    click **opens** rather than toggles (a toggle would collapse the panel when it
    is already the one showing) and then expands that row (`core-github.md`).
    **Since part three all three widgets are on the chrome roles**
    (`core-theme.md`), and the bar's order is reversed: the widgets lead, the six
    panel toggles and the completion switch trail. The branch switcher draws its
    `arrow.triangle.branch` glyph, its branch name and its new `chevron.down`
    caret all in `textSecondary` at `.callout`, and its popover's failure line in
    `statusRed`. The pull-request indicator is now **three** elements — a leading
    `arrow.triangle.merge` (the glyph the Pull Requests toggle uses; the two sit
    at opposite ends of the bar, so the adjacency that once argued against
    sharing it no longer applies), `#N`, and a trailing checks mark whose four
    glyphs are `circle` / `clock` / `xmark.circle.fill` / `checkmark.circle.fill`
    coloured `textSecondary` / `statusYellow` / `statusRed` / `statusGreen` —
    `statusGreen`'s first consumer. All three widgets **drop their own paddings**
    so the bar's 14-point gaps and its `bottomBarHeight` are the measurements
    actually drawn, each keeping `.contentShape(Rectangle())` as its click
    target; the indicator's tooltip, accessibility label and value and its
    absent-rather-than-empty rule are untouched.
    At the **trailing end** of the same bar, after the six panel toggles, sits
    the completion on/off switch (T-4): `completionToggleButton`, in the
    `bottomBarButton` idiom (the same square, the same two states, keyed on
    `settings.completionEnabled`), showing `lightbulb` when on and
    `lightbulb.slash` when off with a `.help(…)` naming the state ("Code
    completion: On" / "Code completion: Off"). It has never carried a `Label`
    title to serve as its accessibility name — and since part three its six
    siblings have lost theirs too — while `.help` is a tooltip rather than a
    name: the label and the state are therefore spelled out with
    `.accessibilityLabel("Code completion")` + `.accessibilityValue(…)`,
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
    `indentLevelHighlightingEnabled:` rides the same route down to
    `CodeEditorView` — a plain undefaulted value beside it, no new observation
    path (`app-editor-overlays.md`) — differing only in having no second surface:
    the Preferences checkbox is the only place it is set.
    Panel-height persistence: instead of the old recreated `VSplitView` (which
    reset the height on every panel switch / hide-show), `mainArea` wraps a
    `GeometryReader` around a manual `VStack { editorSplit; panelDivider;
    panelContent(panel).frame(height: …) }`. A `@State private var panelHeight:
    CGFloat = 240` holds the height *independently of which panel is shown*, so it
    survives switches and hide/show (`@State`-only — cross-launch `@AppStorage` is
    YAGNI). What a *legal* height is, this view no longer decides: the private
    `panelHeightRule` builds a Core `BottomPanelHeightRule` from
    `metrics.scaled(120)` (floor), `metrics.scaled(5)` (the divider strip) and
    `metrics.scaled(120)` (the editor reservation), and **both** the drag and the
    rendered `.frame(height:)` go through it with `available: geo.size.height`, so
    the dragged height and the drawn slot cannot disagree (`core-services.md` has
    the bounds, the degenerate case and why the floor is one number).
    **The drag is measured in a coordinate space that does not move with the
    divider.** `DragGesture`'s default space is `.local` — the divider's own — and
    the divider is precisely what the drag moves: growing the panel by N points
    re-lays the divider N points higher, in whose *new* local space the stationary
    pointer is back at the start location, so `value.translation.height` collapses
    to ~0, the height snaps back to the drag-start base, and the next event repeats
    it. That is an oscillation, not a track, and the pointer drifts off the
    divider; the drag-start base capture prevents frame-to-frame *compounding* but
    cannot fix a translation read against a moving origin. So the column publishes
    `.coordinateSpace(name: panelColumnSpace)` and the gesture is
    `DragGesture(minimumDistance: 0, coordinateSpace: .named(…))`: the column's
    frame is stationary for the whole drag, the cumulative translation is absolute,
    and the mapping is one-to-one. `.global` would serve as well — the container is
    preferred because it stays correct if the window root ever gains chrome above
    `mainArea`. `minimumDistance: 0` is the second half: the default makes the very
    first `onChanged` arrive with a ≥10pt translation already accumulated, applied
    against a base captured in that same call, so the panel jumped 10pt before it
    tracked anything. It has a price paid explicitly: at distance zero a
    mouse-*down* is already a change, so the opening `onChanged` arrives with a
    zero translation before the pointer has moved, and **that one frame writes no
    height**. Otherwise a bare click on the divider would overwrite the remembered
    proposal with the clamped height on screen — discarding, in a window too short
    to grant it, precisely the height the next paragraph says nothing re-clamps.
    Only the opening frame is skipped: once the drag has moved, a translation
    returning to zero means "back to the base" and is written. The base the translation is applied to is the height being
    **rendered**, not the stored `panelHeight`: nothing re-clamps that stored
    proposal when the area shrinks or the interface scale grows, so a base taken
    from it starts the gesture outside the bounds it is clamped against and the
    first drag after a resize moves the pointer a long way before the divider
    moves at all — the same pointer/divider separation, reached by resizing
    instead of by dragging. `panelDragStartHeight` is also the *only* record that
    a drag is in flight; the cursor reads `hovering || panelDragStartHeight !=
    nil` rather than a second flag, because a second flag can go stale against it
    — and did, on the one path that removes the divider mid-drag, where no
    `onEnded` ever arrives.
    **Never over the bottom bar, in three parts — all three are needed.** The
    *behavior* is the rule's tighter clamp: the ceiling is `min(available / 2,
    available - divider - editorMinimum)`, so the arithmetic now asks whether the
    editor, the divider and the panel actually fit instead of clamping the panel
    alone. The *precondition* is that **panel content states no minimum of its
    own**: `panelContent(_:)` renders each panel into a slot of exactly the rule's
    height, and a minimum stated *inside* a fixed-height slot can never be
    satisfied — the child cannot make the slot grow, so its only available outcome
    is to overflow, over the divider above and the bottom bar below. The three
    former `.frame(minHeight:)` modifiers at the call site (Log's 160, Changes'
    and Problems' 120) are deleted for that reason — and `UsagesPanelView` and
    `PullRequestsPanelView`, both added later, state none anywhere, for exactly
    this rule; Log's 160 was the visible
    bleed, spilling at any dragged height between the 120 floor and it, in a large
    window with the editor nowhere near its own minimum. The call site is only
    half of the precondition, though: what lands in the slot is a *view*, and a
    minimum on that view's own `body` root reaches the slot exactly as one written
    at the call site would. `TerminalPanelView` stated `minHeight:
    metrics.scaled(120)` on its body — a tie with the floor, so invisible in the
    ordinary case and live on the degenerate path, where it would have slid the
    terminal's tab bar (the only way to switch or close a session) out from under
    the clip. It is deleted too, and the rule now holds for all six panels in
    their own files. The *guarantee* is `.clipped()` on the column,
    **pinned to the area first** — `.frame(width: geo.size.width, height:
    geo.size.height, alignment: .topLeading)` — because `.clipped()` clips a view
    to the frame it *reported*, not to the one it was proposed: a column whose
    children refuse to shrink reports the oversized height, and a clip attached
    straight to it would clip to the overflow, i.e. to nothing, which is the exact
    case it is here to catch. With the frame stated the clip rect is the
    `GeometryReader`'s own and top alignment sends any surplus off the bottom
    edge. The alignment is **leading** as well as top, and that half is not
    cosmetic: `.top` alone centers horizontally, and the column *is* wider than
    the area in a narrow window — the split's panes state minimum widths the
    `GeometryReader` erases, so their sum can exceed the window minimum below —
    at which point a centered column has the clip take half the surplus off each
    side, cutting the project tree's leading edge. Leading keeps the placement the
    `GeometryReader` gave the column before the pin, so only the bottom is ever
    trimmed. The **slot itself is top-aligned** for the same reason one level in:
    a fixed frame reports the height it was given, so a child that refuses the
    proposal overflows it — and the default `.center` alignment would split that
    surplus evenly, sending half *upwards*, over the divider and into the editor,
    where the column's clip cannot reach it because it is inside the clipped rect.
    `alignment: .top` puts the whole surplus below the slot, which is the column's
    bottom edge, which is where the clip is. Without it the guarantee covers the
    bottom bar and nothing else, and "never over the divider above" would rest on
    the precondition alone — a source rule, which is precisely what the clip is
    here not to depend on. So:
    the clamp rests on arithmetic and the precondition rests on every child
    honoring its proposal, and both can be wrong, so the clip makes "nothing inside
    `mainArea` paints over the bar" unconditional against future layout edits and
    against the editor zone's own fixed strips (breadcrumb, tab strip, consent
    banner, find bar). The clip alone would not do — it would silently hide panel
    content instead of shrinking it. Nothing that must escape the window content
    passes through the column: the completion panel, the hover popover and context
    menus are separate windows. All three parts live in the view layer, where
    `swift test` cannot see them and where each can be undone by an edit that
    compiles and reviews cleanly, so `BottomPanelSourceGatingTests` reads
    `ContentView.swift` (comment- and literal-stripped, the
    `ZoomSourceGatingTests` mould) and pins them: no `minHeight` in any of the
    slot-facing bodies — `panelContent(_:)`, `problemsPanel`, and each of the four
    hosted panel views read *whole* out of its own file (`struct` brace to
    matching brace, not `var body` alone: three of the four bodies are pure
    delegation, so a minimum on the `content` property they compose reaches the
    slot exactly as one on `body` would; the private row and detail structs later
    in those files fall outside the declaration, which excludes `CommitRow`'s
    legitimate per-row `minHeight` without an exemption list), which is what makes
    the sibling-file case above visible to `swift test`. That per-panel table is
    itself pinned **by set equality against the `case .…:` labels of
    `panelContent(_:)`**, the one half of this rule the compiler already
    enforces (the switch is exhaustive over `BottomPanel`): a fifth panel would
    otherwise land a fifth view in the slot with no minimum check at all while the
    suite stayed green — which is the miss `TerminalPanelView` demonstrated for the
    whole life of the rule, and the reason the inventory is tied to the enum
    rather than merely listed. Also pinned: the gesture
    naming `panelColumnSpace` with `minimumDistance: 0`, the top-leading pin
    ordered before the clip, and the slot's own `alignment: .top` — read out of
    exactly the modifiers between the `panelContent(panel)` call and that pin, so
    the column's `.topLeading` cannot satisfy it by accident. All the string matches are made against
    whitespace-stripped source, so a reformat that wraps an argument list cannot
    fail the suite while the rule it guards is intact.
    **The window's minimum content size moved to the body root — both axes.**
    `minHeight: metrics.scaled(400)` and `minWidth: metrics.scaled(640)` used to
    sit on `editorSplit`, where a `GeometryReader` erases its children's minimum
    sizes — so with a panel shown neither reached the window as a minimum content
    size (they only did in the no-panel branch, which leaves no `GeometryReader`
    between the split and the window, so the two branches disagreed about how
    small the window may be). The height did worse than fail: it still made the
    editor refuse to render shorter than it, which is what pushed the surplus onto
    the bottom bar. Stated on the window body `VStack` both apply in both branches
    and `editorSplit` inside the column is free to shrink to the rule's much
    smaller reservation. **The height agrees in both branches now; the width does
    not always**, and that is left as it is on purpose: in the no-panel branch
    with *vertical* tabs the split's panes compose a larger floor than 640 (tree
    180 + tab list 180 + editor 320, scaled, plus the `HSplitView` dividers) and
    raise the window's minimum above it, while in the panel branch the
    `GeometryReader` erases them and 640 is the whole floor. With *horizontal*
    tabs there is no tab-list column — the strip is stacked above the editor
    inside the right zone — so the split composes 180 + 320 and 640 is the
    window's width minimum in both branches. Raising the root `minWidth` to the composed sum
    would hard-code a number that moves with the tab orientation and with the
    panes' own floors, and the case it would rule out is the one the top-*leading*
    pin and the clip below already handle — which is why that alignment is
    described there as a live case rather than a hypothetical. The 320pt `minWidth` on `editorZone` is a different
    number for a different job and stays where it is (`app-editor.md`): it is the
    text view's floor against the statement pane beside it, not the window's.
    `panelDivider(available:)` is a 5pt scaled bar filled with
    `NSColor.separatorColor`. Its **resize cursor is pushed for `hovering ||
    dragging`**, never for hovering alone: a drag quicker than the relayout leaves
    the 5pt strip at once, and a cursor reverting to the arrow mid-resize reads as
    the drag having been dropped. `NSCursor`'s stack is global and a `pop` with
    nothing of ours on it discards somebody else's cursor, so the pair is driven
    off one `panelDividerCursorPushed` flag that only `syncPanelDividerCursor()`
    writes — pushing or popping exactly once per transition — called from
    `.onHover`, from the gesture's first `onChanged`, from `onEnded`, and from
    `.onDisappear`, which is what keeps ⌘-toggling the dock with the pointer on the
    divider from leaking a push that outlives the view that made it.
    **The Markdown preview's divider is that divider turned on its side, with a
    second flag of its own** (`core-markdown-preview.md`). `markdownSplit(for:)`
    is reached for **every** text tab, previewed or not, and that is
    load-bearing rather than tidy: a `ViewBuilder` `if` *is* a structural
    identity, so routing previewed and unpreviewed tabs down two branches would
    put `CodeEditorView` at two positions in the tree and SwiftUI would tear the
    text view — and its `Coordinator` — down on every switch between a Markdown
    tab and any other one. That coordinator is where **all** open tabs' undo
    managers, `EditorViewportMemory` and `FoldStateMemory` live, so the teardown
    would silently drop every open file's undo stack, remembered scroll position
    and folds. `isMarkdownPreviewShown(for:)` is therefore asked *inside*
    `markdownSplitContent(for:size:)`, where it decides a trailing element and a
    width rather than a branch: the editor half carries two always-applied
    frames, a fixed `editorWidth` beside a preview and `maxWidth: .infinity`
    without one, and `onScrolled` is `nil` for an unpreviewed tab — a stored
    property re-assigned on every update, so it costs no identity. The
    `GeometryReader` consequently wraps every editor, which costs the editor
    column nothing: its 320pt floor is stated explicitly at both of
    `editorSplit`'s call sites — on `editorZone` itself in the vertical branch,
    on the `VStack` that is the tab strip plus `editorZone` in the horizontal one
    — rather than derived from the text view's intrinsic width. `markdownSplitContent(for:size:)` spends the divider's 5 scaled
    points first and hands what is left to `MarkdownPreviewWidthRule`, so the two
    frames sum to no more than the area, and pins/clips the pair for `mainArea`'s
    reason. The gesture is measured in `markdownSplitSpace` — the split's own
    frame, which cannot move while the divider does, `panelColumnSpace`'s reason
    on the horizontal axis — with `minimumDistance: 0`, an opening
    zero-translation frame that writes nothing (a bare click must change no
    preference) and a base captured once so a cumulative translation does not
    compound. Two differences from the dock's, both stated where they happen: the
    base is the fraction being *rendered* rather than the stored one, since the
    stored value is a remembered proposal that the point minimums re-clamp at
    layout time; and the fraction is **persisted, exactly once, in `onEnded`**,
    because a `UserDefaults` write on the per-frame path would republish this
    window sixty times a second. The cursor pair is the same rule off a *second*
    flag (`markdownDividerCursorPushed`), because the two dividers can be hovered
    independently and each must balance its own push, and `.onDisappear` clears
    the hover, the drag and the base for the dock's two reasons — ⌘⇧P can take the
    divider away with the pointer on it, and the same removal can land mid-drag,
    where no `onEnded` arrives either.
    `bottomPanel: Binding<BottomPanel?>` (`nil` = none,
    owned by `PisakaApp`) selects the panel; `panelContent(_:)` renders `.terminal`
    → `TerminalPanelView(model: terminalSessions, projectRoot: model.projectRoot)`
    (an existing terminal keeps its start directory — only `newSession` reads the
    current root), `.log` → `CommitLogView(model: commitLog, projectRoot:,
    onOpenCommitDiff:)`, `.changes` →
    `LocalChangesView(model: localChanges, projectRoot:, onRevert:, onOpenDiff:)`
    rendered as the file list only (the diff opens in a separate window on
    double-click via `onOpenDiff`), `.problems` → `ProblemsPanelView(model:
    diagnostics, projectRoot:, onActivate:)`, `.usages` →
    `UsagesPanelView(model: usages, onActivate:)` and `.pullRequests` →
    `PullRequestsPanelView(model:coordinator:)`, both read off the
    `PullRequestCoordinator` this view takes from the **environment** rather than
    as a parameter — `DatabaseViewerHost`'s arrangement, and for its reason: this
    view only routes to the feature's two surfaces, and `PisakaApp.swift` is at
    its measured `file_length` ceiling with no line to spend threading a
    parameter straight through (`core-github.md`) — full entries below. The
    diagnostics model is optional here (`nil` in previews/tests), and a throwaway
    default would both allocate per body evaluation and never update, so the nil
    branch renders the same empty state a real model shows before any server has
    reported. `usages` is optional for the same reason and one more: a textual scan
    republishes once per walked chunk, and a `@ObservedObject` here would re-render
    the project tree, the tab list and `CodeEditorView.updateNSView` with every one
    of them — so the model is threaded straight into the panel, which observes it
    itself. Its row callback is likewise the whole `UsageResult` rather than a
    `(url, range)` pair, because the range worth revealing depends on the file's
    text *at click time*, which only the app can read. A bottom-bar button click routes through
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
    `PisakaApp.testFile(url:)`; and `onShowLocalHistory: (URL) -> Void` likewise
    (the file-row "Local History" item), wired to `PisakaApp.showLocalHistory(for:)`
    — the *same* handler ⌘⇧H reaches, because there is one window and one browser
    model behind it (`core-local-history.md`).
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
    a no-op / a fresh model so a `ContentView` built for a preview or a test needs
    to supply only the two undefaulted arguments, `model` and `editorConfig`. It also takes the shared `settings: SettingsStore` (defaulted to a
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
    reads the environment. Its own scaled constants include the window's minimum
    width and height, the bottom bar's paddings and icon fonts, and the three
    numbers it hands `BottomPanelHeightRule` — the 120pt panel floor, the 5pt
    divider strip and the 120pt editor reservation — so a 200% terminal tab strip
    still leaves room for the panel's content. The panel *content* states no
    minimum of its own (see the panel-height paragraph above); the slot's scaled
    height is the only height it has.
  - `ProjectSwitcherView.swift` (macOS) — the bottom-bar project switcher. Reads `recentProjects` inside the button's action before presenting, so the catalog is queried exactly at popover-open time. Takes two closures: `onOpenFolder` (dismisses and calls, wired to the same open panel) and `onOpenRecent` (dismisses and calls with the URL). Includes a current-row short-circuit: clicking the already-current project just dismisses the popover. The empty state is a short list with only the "Open Folder…" item. Everything sizes through the interface zone (`\.interfaceMetrics`), and it deliberately declares no zoom surface.

    **On the chrome roles** since part three (`core-theme.md`): it reads
    `\.chromeTheme` beside `\.interfaceMetrics` and spends `textPrimary` on the
    project's name at `.callout`, `textSecondary` on the leading `folder` glyph
    and on the trailing `chevron.down` caret the sweep added — the widget opens a
    list and now says so. It draws **no padding of its own**: the bottom bar owns
    the 14-point gaps between its three widgets and its own height, so a padding
    here would make the bar's stated measurements not the ones drawn; the label
    keeps `.contentShape(Rectangle())` so the whole of it stays the click target.
    The popover's colours are roles too — `accent` for the current row's glyph
    and name, `textSecondary` for the section header, the path line and the empty
    state, `textPrimary` for a non-current row's name — because gating rule one
    is per *file* and this file obeys it whole. Every symbol the file draws is
    `.accessibilityHidden(true)` (a `Button` combines its children), and the
    popover row's is hidden with a **debt paid**: its glyph is
    `row.isCurrent ? "checkmark" : "folder"`, so the row states
    `.accessibilityValue("Current project")` for the project that is open —
    hiding the glyph without that left the current row announcing exactly what
    every other row announced, since the `accent` beside it is no more readable
    without sight (`core-theme.md`, rule ten's second half). The popover's `Divider()` calls
    deliberately **stay**: a divider names no colour, so no rule can see it, and
    its ground is still the platform's material, on which a `hairline` rule would
    be the mismatch rather than the cure. That deferral is recorded as inherited
    work for the popovers' part in `core-theme.md`.
  - `ProblemsPanelView.swift` (macOS) — the Problems panel: every diagnostic the
    language servers currently hold, grouped by file. It observes `DiagnosticsModel`
    (`@ObservedObject` — this view is *for* that state and nothing else renders it)
    and holds no domain logic: a header carries the error/warning counts from
    `model.counts` (information/hint deliberately absent — "how much is broken",
    not "how much was said"; each badge hidden at zero so an all-clear header reads
    as just "Problems"), below it one group per diagnosed file in
    `store.rows(relativeTo:)`'s stable order — file icon, relative path components,
    then rows of severity icon, message (two-line limited) and a one-based line
    number. Rows key their `ForEach` by rendered content (`Row`'s `Hashable`), so
    an insertion above must not shift identity onto another message — sound only
    because `rows(relativeTo:)` collapses byte-identical rows first, which is why
    two diagnostics differing in nothing the panel shows list once. The one-based
    display is the store's zero-based buffer geometry plus
    one, because the number beside a message must read as what the gutter shows;
    severity colours are **two tables, one per zone**: the header badges and the
    row glyphs are chrome and read `ChromeColorRole.diagnosticRole(for:)` — the
    same answer the gutter's severity dot reads — while the squiggle under the
    text is the code zone and reads `SyntaxTheme.diagnosticColor(for:)`; this file
    names no `SyntaxTheme` at all (`core-theme.md`, rule fifteen). Every size
    runs through `\.interfaceMetrics` like its sibling panels. Activating a row calls back with `(url, range)`; the app wires that
    straight to `activateSearchMatch(url:range:)` (`app-shell.md`), which already
    opens-or-reselects the tab and reveals the range for Find in Files and Go to
    Definition — the panel is that entry point's third caller, and inventing a
    second open-and-reveal path for it would be how the two stop agreeing. An empty
    list draws a centered "No problems" placeholder rather than collapsing, so the
    dock height does not jump when the last squiggle clears.
    **On the chrome roles since part four (a)** (`core-theme.md`): the view and
    its row read `\.chromeTheme`. The header is a `panelHeaderHeight` strip
    inset by `panelHeaderPaddingX` that draws its own one-point `hairline` along
    its bottom edge — the `Divider()` the stack used to place under it is gone
    (rule fourteen) — with the title at `.body` semibold in `textPrimary` and
    every header `Text` limited to one line (rule eleven: the strip's height is
    fixed — pinned label by label inside the `header` and `severityBadge(…)`
    builders, since the file already spelled the limit on its file-group path
    and a file-level check was satisfied by that). The file-group header draws its icon `textSecondary` and its path
    `textPrimary`; a row draws its message `textPrimary` and its `:line` at
    `.subheadline` monospaced in `textSecondary` (it was an off-scale 10-point
    `.caption`); the hover wash is `hoverTint`; row and group horizontal insets
    spend `rowPaddingX`, and every other number lives in `private enum
    ProblemsPanelLayout`; the placeholder is `textSecondary`.
  - `UsagesPanelView.swift` (macOS) — the Usages panel: every place the identifier
    the user asked about (⌃⌘U) is used, grouped by file. `ProblemsPanelView`'s shape
    throughout — a header strip, one group per file, rows that activate through the
    app's single open-and-reveal entry point — because the two panels answer the
    same kind of question (where in this project is *this*) and a second row idiom
    would be a second thing to learn for nothing. It observes `FindUsagesModel`
    (`@ObservedObject`, for the reason above: this view is *for* that state) and
    holds **no domain logic at all** — grouping, ordering, the cap and the empty
    reason are all published state, and the one thing that looks like a decision
    here, what a click does, is `UsageResult.revealRange(naming:in:)` in Core, asked
    by the app against the buffer the click actually lands in.
    What it adds over Problems is the **honesty line**: the header names the
    identifier in the monospaced interface font and then says, in words, whether the
    rows are a language server's resolved references or whole-word text matches
    ("textual matches"). In words rather than through an icon, because the
    difference is a difference in what the list *claims* and not a difference in
    severity — a panel that blurred the two would be a panel confidently listing
    coincidences. The count sits at the trailing edge and says
    “more not shown” whenever `isTruncated` is set. It deliberately does **not**
    print `UsagesAnswer.cap`: that flag is true for two reasons and only one of them
    is the cap — a walk that abandoned the project once it held one row past the cap
    can still hand over a deduplicated list below it — so a header naming 2 000
    beside a count of 1 431 would be a header contradicting itself. What is true in
    both cases is that there are more, and the number beside it is the number drawn. A spinner shows while a
    walk is still filling it, since a textual answer arrives per chunk.
    The empty state says **which** nothing it means (`UsagesEmptyReason`'s three
    cases spelled as three sentences), rather than drawing an empty list that reads
    the same whether the question was never asked, refused, or genuinely answered
    with nothing. Rows draw the line number and the preview line with the
    occurrence emphasized, assembled from `MatchPreview.matchRange` — already
    clamped to the clipped window, so a match the clip cut still draws (unemphasized
    at worst) rather than dropping the row.
    Chrome, not a code surface: everything sizes through `\.interfaceMetrics`, the
    preview is drawn in the *interface* font rather than the editor's (this is a
    list of places, not a view of code — and drawing it at the code font would make
    the panel a zoom surface its dock siblings are not), it declares **no** zoom
    surface, and it states no minimum height. `BottomPanelSourceGatingTests` pins
    all of that.
    **On the chrome roles since part four (a)**, in Problems' shape: the same
    `panelHeaderHeight` header drawing its own bottom `hairline` (no
    `Divider()`), the title `.body` semibold in `textPrimary`, the identifier
    `.callout` monospaced in `textPrimary`, the provenance note and the count at
    `.subheadline` in `textSecondary` (both were off-scale 10-point `.caption`),
    every header `Text` on one line (rule eleven, counted label by label inside
    the `header` builder); the file-group header and the `hoverTint`
    wash as in Problems; the line number `.subheadline` monospaced in
    `textSecondary`; the preview's hit `textPrimary` semibold between
    `textSecondary` context; the placeholder `textSecondary`; local numbers in
    `private enum UsagesPanelLayout`.
  - `DockTabRow.swift` (macOS) — the bottom dock's own tab row: one row across
    the top of the dock naming the panel on screen and offering the other five,
    with a close action at the trailing end. **Its own file so it can be
    gated**, the breadcrumb's and the tab strip's precedent, and called once,
    from `ContentView.panelContent(_:)` (the entry above). A `View` taking
    `selection: BottomPanel`, `onSelect: (BottomPanel) -> Void` and `onClose: ()
    -> Void`, reading `\.interfaceMetrics` and `\.chromeTheme`. The row is
    `ForEach(BottomPanel.allCases)` at a 2-point gap, a `Spacer` keeping at least
    10 points, then the close action; horizontal padding `dockTabRowPaddingX`,
    height `dockTabRowHeight`, **no minimum anywhere** (it sits inside the
    fixed-height slot, and `BottomPanelSourceGatingTests` reads its type body
    among the slot-facing ones), **no ground of its own** (the slot paints
    `bgPanel`) and a one-point `hairline` along its bottom edge, drawn
    **behind** the tabs with `.background(alignment: .bottom)` — never as an
    overlay, which paints over the lower point of the selected tab's two-point
    accent strip (the first cut's defect; gating rule sixteen). A tab is
    a `.plain` `Button` over a `VStack(spacing: 0)`: the title from
    `BottomPanel.title` at `.callout`, one line, padded by
    `dockTabLabelPaddingX`, `textPrimary` selected and `textSecondary` otherwise,
    regular weight in both states (a weight change would widen the label and
    shift every tab after it); under it an `accentIndicator`-high strip,
    `accent` selected and `Color.clear` otherwise, so selection never moves the
    title. The tab carries `.accessibilityLabel(panel.title)` and
    `.accessibilityValue("Selected"/"Not selected")`, and the strip is
    `.accessibilityHidden(true)` — it *is* the selection, which the value
    speaks. The close action is an `xmark` at `.body` in `textSecondary`, named
    by `.help("Close panel")` and `.accessibilityLabel("Close panel")` rather
    than by its glyph. **Three decisions live here**: six tabs, not the
    design's seven, because the seventh names a panel the application does not
    have and a tab that does nothing is a defect; a tab **selects and never
    collapses** — the click is Core's `BottomPanel.tabActivation(_:tab:)`, whose
    `.alreadyShowing` answer does nothing — while collapsing belongs to the bar's
    toggle and to close; and close alone, because minimise and close would be
    one action on a dock with one state. The gaps are bare local numbers in
    `private enum DockTabRowLayout` (gating rule seven). Gating rules twelve
    (reachability: the type is named only here and in `ContentView.swift`, built
    exactly once inside `panelContent(`, and no hosted panel names it), thirteen
    (the tab's label/value/hidden strip, the close action's help and label),
    eleven, fourteen and sixteen pin it (`core-theme.md`).
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
    `SyntaxLanguageConfiguration`/`SyntaxTheme` — including the `.plain` base
    foreground set beside the font, so a character no capture covers reads the
    same table the editor reads — same `@ObservedObject`
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
    unscaled row geometry now comes from **two** places, split by whose
    measurement it is. The chrome's own — a row's height
    (`ChromeGeometry.rowHeight`, applied as a *fixed* min/max frame rather than
    as padding around the content, so a tree row and a tab row cannot drift apart
    when one gains a taller glyph — with one exception, both row kinds lifting
    that ceiling while they host a rename draft, for the reason given in the
    draft field's entry below), its horizontal padding
    (`ChromeGeometry.rowPaddingX`) and one level of nesting
    (`ChromeGeometry.treeIndentStep`, the former literal `12`) — are tokens, read
    by every chrome list (`core-theme.md`). What stays in `TreeRowLayout` is the
    part that is the *tree's* own: the chevron column, its spacing and the gutter
    derived from the two. Both sets have the same **three** readers — both row
    kinds and, since the inline draft occupies the row it stands in and must be
    padded and gutter-inset with the very same numbers or the tree would visibly
    shift as a draft opens and closes, `ProjectTreeDraftField.swift` — which is
    why `TreeRowLayout` is internal rather than `private`. As literals they would
    drift apart, and reading alike is the whole point. Every size
    goes through `\.interfaceMetrics` like the rest of the tree; the style names
    no `interfaceScale` and declares no zoom surface, so
    `ZoomSourceGatingTests`' set equalities are untouched. `DirectoryNodeView`
    takes a `startsExpanded` flag seeding `@State isExpanded` via
    `State(initialValue:)`: the root node is built with `startsExpanded: true`
    (its `.onAppear` loads children, since `onChange` never fires for an
    already-expanded node) so a freshly opened folder shows its first level
    immediately, while nested nodes default to `false` and load lazily on first
    expansion. The root's `.id(root)` resets node state when switching projects,
    so each newly opened folder also starts expanded. Rows render type-specific
    icons via `FileIcon(for:)`, drawn **monochrome** in
    `ChromeColorRole.textSecondary`: only the symbol is read, the semantic tint
    deliberately not (a column of differently-tinted glyphs argues with the
    selection wash that is the row's actual message — the monochrome-icon
    decision, `core-theme.md`). The app layer's former file-scope
    `color(for: FileIconColor) -> Color` helper is **deleted** along with its two
    readers' need for it; `FileIconColor` itself is untouched Core vocabulary
    that iOS still paints. Directory-read errors are swallowed
    (`PlatformFeedback.warning()`, and `children` left *unset* rather than
    cached as an empty list, so collapsing and re-expanding retries a transient
    failure), never crashing the view — *except* a "no such file" error, which
    is swallowed silently: a revision-driven reload runs for every expanded
    node, so an external `rm -rf build` (which now reaches the tree on its own
    through `ProjectWatcher`) would otherwise beep once per expanded descendant
    before the parent's re-read drops them.
    Rows carry `.contextMenu`s for the writable tree, backing the inline
    naming flow. A directory row offers New File / New Folder (no ellipsis)
    and (non-root only) Rename / Delete; the root row offers only the two
    create actions; a file row offers Rename / Delete, plus a "Run" item
    (play icon → `onRun(url)`) shown only when
    `RunCommand.canRun(url.lastPathComponent)` and a "Run Test" item
    (`checkmark.diamond` icon → `onRunTest(url)`) shown only when
    `TestCommand.isTestFile(fileName:)` (directories get neither item), and —
    last, after a `Divider()` below Rename/Delete — a plain **"Local History"**
    item (`onShowLocalHistory(url)`) shown **unconditionally** on every file row, unlike
    the two above: whether a file has revisions is a question only the store can
    answer, and answering it per row would cost a directory read per row of the
    tree, so the window is opened and says "No history for this file yet." itself
    (`core-local-history.md`). Directories get no such item. The
    create and rename actions no longer prompt via dialog: they guard
    against `mayBeginFileOperation` at command time (so the "Git operation
    in progress" alert fires exactly when the menu is chosen), then set an
    inline `@State private var draft: TreeEditDraft?`. A drafted folder row
    expands if collapsed and renders the draft as its literal first child,
    scrolled into view; a drafted file or folder row swaps its label for the
    draft field. While a row is drafted, its tap (expand/open), drag source,
    drop delegate, context menu, and button trait are suppressed so
    VoiceOver reaches the field and gestures do not compete with typing.
    The menu's suppression is the **absence** of the modifier, not an empty
    menu body: `.contextMenu` installed with nothing in it still opens on a
    right-click, so `if !isDrafted { … }` *inside* the builder answered a
    drafted row with an empty panel that flashed shut. Both row kinds go
    through one `projectTreeContextMenu(isEnabled:menuItems:)` `@ViewBuilder`
    helper (the shape `projectTreeDragSource(isEnabled:url:session:)` already
    had) that omits the modifier instead, leaving AppKit no menu to open at
    all — the click then only cancels the draft. Unlike the drag source's
    flag this one does flip, and the resulting view-identity change is free:
    it flips at most twice per draft (opened, then committed or cancelled),
    at moments the row is rebuilt anyway. The
    draft survives `treeRevision` bumps, tearing down only on project
    switch, or when the row that draws it leaves the hierarchy. That last
    condition has one reach, spelled by `draftIsBelow(_:)` and asked at
    three sites: collapsing a folder, an `ENOENT` on its reload, and a
    *successful* reload that no longer lists the way down to the drafted
    row (`draftedChild()` — the drafted entry itself when the draft is
    anchored in that directory, otherwise the child folder its subtree
    hangs from, which must still be a directory, since a folder replaced by
    a file of the same name stops rendering its subtree without losing the
    name). All three are the whole *subtree*, not the direct children: a
    draft left behind by a narrower rule would survive with nothing drawing
    it — no field to press Esc in, no mouse-down monitor (the region view
    went away with the row) — and a later re-expansion, or the path simply
    reappearing, would revive an editable field that steals focus for an
    edit the user believes they ended. A folder's *own* rename draft is
    deliberately outside that reach: it is drawn in the folder's label row,
    which its parent still lists, so collapsing the folder keeps it. The
    containment test compares standardized, symlink-**un**resolved paths,
    and is the one place here that deliberately does not follow
    `CanonicalPath`'s resolve-first rule: the question is which row hangs
    off which row, not which file is the same file, and the tree spells
    both sides by appending components to the opened root, so both already
    agree. Resolving would only introduce disagreement — a project holding
    `link -> deep/real` would lose a draft rendered under `link` when the
    unrelated `deep` collapses, and keep one alive unrendered when `link`
    points outside the collapsed directory. The
    `onNewFile(URL,
    String)` / `onNewFolder(URL, String)` / `onRename(URL, String)`
    callbacks take the final accepted text and run under the same writer
    gate as defense-in-depth, while `onDelete` / `onRun` / `onRunTest`
    remain parameterless callbacks. The callbacks only *request* the
    operation: `PisakaApp` validates once more, performs the disk I/O and
    bumps `treeRevision`. `DirectoryNodeView` also observes `.onChange(of:
    model.treeRevision)`: when currently expanded it re-reads
    `children(of:)` so a created / renamed / deleted entry appears without
    reopening the folder; a collapsed node instead drops its cached children
    (`children = nil`) so its next expansion re-reads from disk — without
    this an already-loaded node targeted while collapsed would keep showing
    a stale listing (the lazy first-load only fires when `children == nil`).
    The `.id(root)` identity, `startsExpanded`, and lazy first-load are
    unchanged. With a folder open the rows sit under a small header (a
    `Divider` between them, modeled on the `LocalChangesView` header)
    holding one Refresh button (`arrow.clockwise`, `.borderless`,
    `.help("Refresh project tree")`) whose action is
    `model.bumpTreeRevision()` — called *directly*, not through a callback
    threaded from `PisakaApp`, since this view already observes the model
    and the bump needs no disk I/O. The header is absent from the
    `projectRoot == nil` placeholder so its whole pane stays the open-folder
    click target. So `treeRevision` — the single re-read trigger
    `DirectoryNodeView` observes — now has three sources: the app's own
    operations (the context-menu callbacks, Save As, a branch checkout), the
    FSEvents `ProjectWatcher` on macOS, and this button (the manual fallback
    for whatever the watcher misses — an FSEvents buffer overflow, a network
    volume, or simply not wanting to wait out the 1 s latency).
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
    source app with it — behind a dialog. The highlight is the **accent at 40 %
    opacity**, reached at the *same* site and through the same rule as every
    other row state: the row asks `TreeRowState.state(isSelected:isWindowKey:
    isHovering:isDropTarget:)` (`core-theme.md`) and maps the answer through
    `TreeRowBackground.color(for:resolving:)`. Drop outranks hover there because
    the pointer is inside the row and both conditions are true at once, and "will
    this drop land here?" is the only question being asked; the wash is heavier
    than `accentTintStrong` for the same reason — a drop over a row that is also
    selected has to out-read the selection. The closed role set names no drop
    wash and gains none: this is the accent read more strongly, which is a
    reading the palette already supports, not a twenty-second role. One rule and
    one mapping, read by both row kinds, is what stops the treatments drifting
    apart. Everything else on both row kinds is **unchanged and in the same
    order**: the row's single `.onTapGesture` still toggles a folder (a drag and a
    click are distinct gestures), the hover highlight, the full-row `.contextMenu`s
    and the row's accessibility re-declaration (combined element, `.isButton`, the
    expansion value, the toggle action) are exactly as above. Nothing here names
    `interfaceScale` and no zoom surface is declared, so `ZoomSourceGatingTests`'
    set equalities are untouched.
  - `ProjectTreeView.swift`, **the chrome theme's third surface** — the rows are
    drawn from the colour roles through the geometry-and-state path
    (`core-theme.md`). Every row background is one expression: the row asks
    `TreeRowState.state(...)` and maps the answer through the file-scope
    `TreeRowBackground.color(for:resolving:)` — `hover` → `hoverTint`,
    `selectedFocused` → `accentTintStrong`, `selectedUnfocused` →
    `selectionInactive`, `dropTarget` → the accent at 40 %, and `plain` →
    `.clear`, the *absence* of a background rather than a colour of its own.
    (`role(for:)` beneath it still answers the four that a role states, and `nil`
    for the two that do not: `plain`, which paints nothing, and `dropTarget`,
    whose wash the closed set does not name.) The theme arrives as a
    role-to-colour *function*, not as the theme value, so no view file names
    `ChromeTheme` — rule five of the gating suite (`core-theme.md`). Both row
    kinds read that one mapping, for the reason they share the geometry tokens.
    Two of the rule's four inputs are
    **derived, not interactive**: *selection* is "this row's file is the active
    editor tab's file" — `ProjectTreeView` builds a `TreeSelection` from
    `model.selectedFile?.url` **once per render** and hands *that* down the
    recursion, carrying the tab's url in both spellings (standardized, and with
    its symlinks resolved), so a row matches either by a purely lexical
    comparison of its own standardized url. Resolving per row instead would cost
    one `realpath(3)` per visible row per keystroke, `DirectoryNodeView` being an
    observer of the workspace. The two sides need two spellings because a tree
    row's url is built by appending a listing's component to the opened root
    while a tab's came from wherever it was opened. The accepted limit is stated
    on `TreeSelection`: a row reached through a *symlinked* root while the tab's
    url is already canonical is not highlighted, a configuration neither producer
    creates. No click-to-select is introduced. *Focus* is
    `@Environment(\.controlActiveState) == .key` on the row: the window is key or
    it is not. A folder row passes `isSelected: false` unconditionally — a folder
    is never an editor tab — and a file row passes `isDropTarget: false`, a file
    not being a drop destination. The empty-state hint and both icon columns take
    `textSecondary`.

    Part three adds the surface *around* those rows. **The host** — both
    branches of the body, the tree and the open-a-folder placeholder alike —
    draws `bgPanel`. The placeholder is deliberately *not* the window's
    `bgCanvas` showing through: it stands inside the same split slot as the tree
    it replaces, bounded by the same divider, and a pane whose ground changed
    with whether a folder happened to be open would read as a hole in the
    sidebar rather than as the window behind it. **The header** is a fixed strip
    of `ChromeGeometry.sidebarHeaderHeight` (32) inset by
    `ChromeGeometry.barPaddingX` (12) — the same inset the bottom bar draws, and
    deliberately not `rowPaddingX` (8), which is a row's padding inside its own
    highlight — both scaled at the use site. It carries the open folder's name,
    uppercased, in `textSecondary` at `.subheadline`/`.semibold` with
    `metrics.scaled(0.5)` of tracking at the leading end; a `Spacer()`; and the
    Refresh button at the trailing end, its icon `textSecondary` at `.body` and
    its tooltip unchanged. The header draws its **own** one-point `hairline`
    rectangle along its bottom edge and the `Divider()` that used to sit between
    it and the tree is gone — part two's precedent: a `Divider()` is painted in
    the system's separator value, which disagrees with the `hairline` role beside
    it in either appearance. The Refresh button is a **deliberate deviation**:
    the design draws the project label alone, but a restyle does not remove a
    working control, and this is the tree's one manual re-read path.
  - `ProjectTreeDraftField.swift` — the AppKit-backed `NSTextField` behind
    the tree's inline naming, in five types: `TreeEditDraft` (what is being
    named), `TreeNameFieldView` (the row-shaped draft: icon column, field,
    red reason line), `TreeDraftDismissRegion` (the invisible mouse-down
    observer), `ProjectTreeDraftFieldRepresentable` (+ its `Coordinator`)
    and `CustomTextField`. The layer split gives this view no business
    logic: it collects the typed text, draws the invalid-input text and a
    wrapped reason line in `ChromeColorRole.statusRed`, and delegates every rule — validation,
    preselection, live collision check, and what a click means — to
    `FileName` and `TreeDraftDismissRule` (`core-workspace.md`). Validation
    composes in one fixed order: blank (not an error — no reason line, but
    Enter refuses), then the grammar validator for the draft's kind, then
    the sibling collision check for single-component input only — where
    "single-component" is `parseRelativeEntryPath`'s answer and not a
    `contains("/")` test on the string, because a single trailing slash is
    the natural way to spell a folder (`Sources/` is one component, and the
    string test both skipped its collision check and would have compared the
    raw spelling against the siblings).
    **Focus loss is decided by two paths that never disagree.** A
    project-tree row is a plain SwiftUI view that never takes first
    responder, so clicking one moves focus nowhere and
    `controlTextDidEndEditing` never fires — which is why the draft carries
    a **local `.leftMouseDown`/`.leftMouseUp`/`.rightMouseDown` `NSEvent`
    monitor**, alive
    for exactly as long as the draft is (installed in the region view's
    `viewDidMoveToWindow`, removed when the window goes away and again from
    `dismantleNSView`, both halves idempotent — and one draft at a time is
    already the tree's invariant). It follows `ZoomController`'s monitor
    discipline (token stored, `[weak self]`, `MainActor.assumeIsolated` for
    the same recorded reason), differing only in being installed per draft
    rather than per app run. Each event is handed to `TreeDraftDismissRule`
    as four AppKit facts — is this the draft's own window, did it land inside
    that window's content view, where did it land in the region's
    coordinates, how big is the region — and nothing
    else: another window's click is that window's business, a click on this
    window's *chrome* is the user moving or minimising the window they are
    typing in, a click inside the draft is an ordinary edit (caret
    placement, drag-selection), anything else in the draft's own window
    cancels. The chrome fact is `window.contentLayoutRect`, measured
    against `locationInWindow` in that same unflipped window space —
    **not** `contentView`'s bounds, because a plain SwiftUI `WindowGroup`
    window carries `fullSizeContentView` and its content view therefore
    spans the title bar, which would answer `true` for every title-bar drag
    and make the chrome answer unreachable. `contentLayoutRect` draws
    the line where AppKit draws it and so leaves two limits stated on the
    rule: a resize drag begun from the content side of the bottom, left or
    right edge, and the click that reactivates the app, both land inside the
    content area and are both answered `cancel` (the resize drag's answer is
    never applied, for the deferral reason below).
    Two things follow, and both are deliberate. **The dismissing click is
    never swallowed**: the monitor always returns the event unchanged, so
    cancelling and the click's ordinary effect both happen — the folder
    toggles, the file opens, the right-clicked row gets its own menu — which
    is what Finder does with an inline rename and what a
    swallow-the-first-click rule would cost the user a second click for. The
    drafted row is the one exception, since `projectTreeContextMenu(isEnabled:)`
    installs no menu on it while the draft is open and AppKit resolves the menu
    before SwiftUI re-renders the cancelled row: right-clicking it beside the
    field cancels and opens nothing (`TreeDraftDismissRule`). The
    rule is asked on the mouse-**down** — where the user aimed, and what
    keeps a text-selection drag out of the field from reading as a click
    elsewhere — but a left-click's cancellation is held until the matching
    mouse-**up**: a SwiftUI tap completes only when the release is still
    inside the view the press began in, and cancelling shifts every row
    below the draft up. Running it on the down would move the tree in the
    middle of the click and cost that second click after all. A **context
    click** cancels on the down, since that is when `NSMenu` opens — and since
    the menu's tracking loop eats the release a deferred cancel would wait for.
    `DismissRegionView.opensContextMenu(on:)` is the one place that classifies
    it, and it reads the *modifiers* as well as the type: a Control-click is the
    same gesture, but macOS delivers it as a `.leftMouseDown` carrying
    `.control` and only routes it to the menu path later, inside `sendEvent(_:)`
    — so classifying by event type alone would defer it to a release that never
    arrives and leave the draft open over the menu it just opened.
    `TreeDraftDismissRule.cancelTiming(opensContextMenuOnMouseDown:)` holds the
    policy; the view supplies only the AppKit fact. The wait's stated
    cost, recorded on the rule: a gesture that takes the mouse over from its own
    down — a window resize begun in the content area's edge band, a drag started
    on any non-drafted row — runs a modal tracking loop that dequeues its own
    events, so the `.leftMouseUp` never reaches the monitor and the pending
    cancel is never applied. The draft outlives that gesture, still editable and
    still cancellable by Esc or by the next click outside it.
    And **the region tested against is a real view, not a computed
    rectangle**: the draft is a `VStack` of which only the field is an
    `NSView`, so the region is an invisible `NSViewRepresentable` attached
    as the draft's outermost `.background`, *after* the padding — SwiftUI
    sizes a background to its primary view, so its `bounds` **is** the
    draft's rectangle, and "clicking the icon or the reason line does not
    cancel" holds by construction rather than by a measured inset. It draws
    nothing, hit-tests to `nil` and claims only the size proposed to it, so
    it can neither intercept a click nor move the layout. Two edges of that
    construction are stated where they are decided (`TreeDraftDismissRule`'s
    "What `draftBounds` is") and worth repeating here: what is handed to the
    rule is `bounds.intersection(visibleRect)` — since the tree scrolls and
    a draft scrolled out of the clip view would otherwise keep owning clicks
    on the pane header and the panes around it, while the intersection is
    what keeps it from owning the whole window (AppKit's `visibleRect` is the
    superviews' visible region in the receiver's coordinates and is *not*
    intersected with the receiver's own `bounds`, so it is routinely larger
    than it — measured, not assumed); and only a *create* draft
    draws an icon column of its own, so during a **rename** the row's icon
    and the row's padding around the field belong to the row, sit outside
    the rectangle, and a click on them cancels like any other click on the
    row. Because the
    monitor is *local*, ⌘Tab away and ⌘Tab back preserves the draft: another
    app's clicks are never seen, and window resign-key is not a
    cancellation. Returning by *clicking* the window is the limit noted
    above — that event is this app's own, so it cancels if it lands outside
    the draft.
    `controlTextDidEndEditing` remains the second path — the fallback for
    what genuinely moves first responder (Tab away, a control that takes
    focus) — with its three-way test unchanged: `isFinishing` (Enter or Esc
    already ended this draft), the teardown flag (set by the view subclass
    in `viewWillMove(toWindow:)` when `newWindow == nil` and by
    `dismantleNSView`, and cleared again in `viewDidMoveToWindow` whenever
    there *is* a window — the flag means "being removed", and a re-attached
    field is alive again), and `window == nil`. It cannot instead *read* the
    responder chain: the notification is posted from within
    `resignFirstResponder`, before the window installs the incoming
    responder, so `window.firstResponder` is still the field editor being
    dismissed. The two paths are idempotent with each other because both end
    at `draft = nil`.
    **Focus is taken, not handed over.** `CustomTextField` acquires first
    responder in `viewDidMoveToWindow` — the symmetric hook to the
    `viewWillMove(toWindow:)` it already overrides, and the first moment
    AppKit guarantees a window, firing for the whole subtree when an
    ancestor joins one. That covers the late-attachment path (expanding a
    collapsed folder and drafting in it is a single command) which the
    retired "ask on the next runloop turn, give up if there is no window"
    block silently lost, opening the draft deaf. Acquisition is one-shot
    *per attachment* (guarded by that flag plus the teardown flag, so a
    draft replaced by a second command cannot steal focus back) — joining a
    window clears **both** flags, because a field that leaves a window and
    rejoins one is alive again and needs the caret back as much as it needs
    to be cancellable again; a latched focus flag would leave that draft
    open, editable and permanently deaf, which is the very defect this hook
    exists to remove. Because that clearing happens one line before the
    acquisition, the flag alone cannot refuse a *spurious* notification —
    AppKit re-sends `viewDidMoveToWindow` for the same window when an
    ancestor is re-added — so the acquisition is made idempotent against the
    state itself: **a field that already owns its field editor returns
    immediately**. Without that test `makeFirstResponder` would resign the
    live editor, and the resulting `controlTextDidEndEditing` trips none of
    its three tests (nothing is finishing, nothing is tearing down, the
    window is there) and cancels the draft mid-typing — the same silent loss
    from the opposite direction. Re-acquiring cannot re-select over what the user has
    typed, which is what keeps the two flags separate: the initial selection from
    `initialRenameSelection(in:isDirectory:)` is computed once in
    `makeNSView` and applied to the field editor exactly once — then
    cleared, so a re-attachment can never re-select over what the user has
    since typed (cleared *after* the field editor is found, so a miss leaves
    the request standing rather than surrendering the range to
    `becomeFirstResponder`'s select-all) — and the one case no window hook can foresee,
    `makeFirstResponder` refusing, retries a single bounded time on the next
    runloop turn, re-checking window and teardown. One attempt, never a
    poll.
    **The field draws at the interface zone's size.** It is AppKit, so the
    row's `.font(metrics.scaledFont(.body))` cannot reach it: the zone's
    point size is handed to the representable as an `InterfaceMetrics` and
    applied to the `NSFont` in `makeNSView` and again on every
    `updateNSView` (a zoom step while a draft is open is one of those
    passes), exactly as `HoverPanel` does for the chrome's one other AppKit
    text surface. Two things depend on it, which is why a hard-coded
    `NSFont.systemFontSize` was wrong rather than merely inconsistent: the
    drafted row would draw at 13 pt beside the scaled icon and label of the
    row it replaced, and the height below is measured off `field.font`.
    **The field wraps and the row grows to fit it.** A deep relative path is
    the whole reason relative-path create exists, so the field is configured
    exactly as the retired `FilePanels.promptName` dialog was
    (`usesSingleLineMode = false`, wrapping non-scrolling cell, no line cap,
    `.byWordWrapping`) and `sizeThatFits` returns the height the cell needs
    at the width the tree pane proposes, clamped to at least one line and at
    most the same six-line ceiling the dialog used (past that the input is
    pathological and a taller row pushes the tree around more than it
    helps). The two points of caret/descender slack are added to the
    *measurement* as well as to that floor and that ceiling — carried by only
    two of the three, the measured heights in between would be the one part of
    the range drawn without it, the same field tighter at two lines than at
    one. **Only a concrete, positive, finite proposed width is answered**;
    the unspecified, zero and infinite proposals are the row's `HStack`
    probing for flexibility and return `nil`, handing them to SwiftUI's
    default sizing. The tempting alternative — answering them with the
    width the field is currently laid out at — is the one thing this must
    never do: SwiftUI positions an `NSTextField` representable by its
    *alignment rect*, so the field's frame is four points wider than the
    width it was assigned, and reporting that frame back as the row's
    minimum widens the row four points per layout pass until AppKit aborts
    the window's constraint loop. The create draft took exactly that path
    before the guard existed; its outermost frame now states
    `maxWidth: .infinity` too, which removes the runaway's room but not the
    guard, the refusal being about what a representable may report rather than
    about which row happens to be capped. Enter is still
    never a line break — the coordinator swallows every newline selector and
    commits instead. The arithmetic is deliberately *not* shared with
    `FilePanels.promptFieldHeight(of:)`, which measures against a fixed 400
    pt accessory width and feeds an `NSLayoutConstraint` it mutates; only
    the six-line clamp is a shared number, and it is stated in both places.
    The reason line's inset is likewise construction rather than arithmetic:
    it is led by the *same* `iconColumn` view drawn hidden and collapsed to
    zero height, so it matches the field's lead exactly and stays zero for a
    rename draft, which has no icon column at all.
    **The draft is in the chrome theme's gated set** (`core-theme.md`), although
    it is an editing affordance rather than a row: an inline draft *replaces* a
    tree row on screen and must read identically to the row it stands in for. So
    it takes the same geometry — `ChromeGeometry.rowPaddingX` horizontally, and
    no vertical padding at all: a **rename** draft is inside the row it renames,
    which already carries `ChromeGeometry.rowHeight`, while a **create** draft is
    a row of its own (hosted directly by `DirectoryNodeView`) and therefore
    states that height itself, as a `minHeight` and never a ceiling, so the
    wrapped reason line can grow past one row. The two row kinds lift their own
    `maxHeight` for exactly that reason while they host a rename draft: the row
    states the height, and a draft inside it must still be able to grow when its
    reason line wraps. The draft also draws its icon column monochrome in
    `textSecondary` like the row it replaces, and takes the reason line in
    `statusRed`. The field
    itself is the chrome's one `NSTextField` and therefore the tree's one user of
    the **AppKit bridge**: `updateNSView` sets `textColor` to
    `ChromePalette.nsColor(.statusRed)` while the input is invalid and
    `ChromePalette.nsColor(.textPrimary)` otherwise — dynamic colours, so the
    field follows the window's appearance while observing nothing itself.
  - `TabListView.swift` / `TabRowView.swift` — the open-tabs **vertical column**
    and nothing else: the scrolling `LazyVStack` of `TabRowView`s, each stretched
    to `maxWidth: .infinity`. The `orientation: TabOrientation` parameter is
    gone; `ContentView` still picks the presentation from
    `settings.tabOrientation`. The horizontal presentation used to be a branch
    inside these two and is now `TabStripView`, split out rather than left here
    because the two orientations state *different* chrome — the strip a height and
    a rule under it, the column a width it is given and a boundary its splitter
    states for it — so
    neither can be a branch inside the other, and a strip is not a list of rows
    running sideways.
    Both files are **drawn entirely from the chrome colour roles** (the second
    part of the sweep, `core-theme.md`) through the environment path. The column
    is `bgPanel` behind the scroll view and draws **no pane-edge rule of its
    own**: its host is not a stack but the `HSplitView` in `editorSplit`, which
    draws a splitter divider at the column/editor boundary whatever the column
    does, so a trailing hairline here would be a second rule beside that one —
    and `app-window.md`'s own minimum-width paragraph already budgets those
    dividers into the window. The pane immediately left of it in the same split
    view, the gated `ProjectTreeView`, states that boundary the same way: by
    leaving it to the splitter. (The strip's bottom rule is the other case — its
    host *is* a `VStack`, which draws nothing between its children.)
    A row is `ChromeGeometry.verticalTabRowHeight` tall with `rowPaddingX`
    horizontal padding, and states the strip's vocabulary turned through a right
    angle: the active row filled `bgEditor` with an `accent` bar
    `ChromeGeometry.accentIndicator` wide on its **leading** edge (the strip's
    underline, rotated), its label `textPrimary` while every other row's is
    `textSecondary`, and `hoverTint` under the pointer on an inactive row only —
    the active one is already the one row that is filled. The icon is
    **`TabFileIcon`**, the second of the two views the orientations share (both
    live in `TabStripView.swift`): the monochrome `FileIcon` symbol in
    `textSecondary` (the monochrome-icon decision in `core-theme.md`), with an
    untitled buffer asked about under its display name so the fallback symbol is
    still `FileIcon`'s own. The trailing slot is the first,
    **`TabStatusMark`**: the
    three-claimant precedence exists once, so the two orientations cannot drift
    into two rules. Both are one view rather than one rule restated twice, for
    the same reason and pinned by the same suite — `ChromeThemeSourceGatingTests`
    holds the icon rule to one spelling by set equality, having found it pasted
    into both. Every number goes through `metrics.scaled(_:)`.
  - `TabStripView.swift` — the horizontal tab strip above the editor, and the
    **first surface drawn entirely from the chrome colour roles** through the
    SwiftUI environment path (`@Environment(\.chromeTheme)`, `core-theme.md`). It
    owns the strip's whole chrome, which is why its host adds neither a
    `.frame(height:)` nor a `Divider()`: the strip states its own height
    (`ChromeGeometry.tabStripHeight`) and draws its own bottom hairline, so the
    two cannot disagree. The strip is `bgPanel` behind a horizontal
    `ScrollView`/`LazyHStack` of `TabStripCell`s; the hairline is drawn *behind*
    the cells on the strip's bottom edge (`.background(alignment: .bottom)`,
    layered between the `bgPanel` ground and the cells) so the active tab —
    filled in `bgEditor`, to read as the top edge of the editor rather than as a
    highlighted row — sits above it and merges into the editor below, its accent
    underline interrupting the rule for the tab's width. It was an *overlay*
    until part four (a)'s review round: an overlay covers its whole content, so
    it painted over the active tab's fill and the lower point of its underline,
    the opposite of what the comment beside it claimed. Gating rule sixteen pins
    the construct here and in `DockTabRow.swift`. A cell carries `TabFileIcon`, a view of its
    own in this file and the **second** of the two things the vertical column
    shares with the strip: a monochrome file icon
    (`textSecondary`; `FileIcon`'s tint is deliberately unread — see the
    monochrome-icon decision in `core-theme.md`), a `metrics.scaledFont(.callout)`
    label in `textPrimary` when active and `textSecondary` otherwise, one
    `accent` underline `ChromeGeometry.accentIndicator` tall on the active tab, a
    trailing `hairline` between tabs, and **one slot** — `TabStatusMark`, the
    other shared view, so the precedence below exists once rather than twice — holding either
    the close mark or the unsaved-changes dot, claimed in that order: the mark under the
    pointer, then the dot, then the mark on the active tab. The dot therefore
    **outranks** the mark on an active tab — unsaved work is a fact about the
    file that nothing else on the strip states, while the mark is one hover away
    — and the mark still shows on an active tab with nothing to report, so the
    tab most likely to be closed does not have to be hunted for. An untitled
    buffer has no url and is asked about under its display name, so the fallback
    symbol is still `FileIcon`'s own rather than a second guess spelled here —
    that rule is `TabFileIcon`'s, spelled once and asked by both orientations,
    which is also what keeps `FileIcon(` off a second gated file's lines (each
    such line is exempt from the suite's no-system-colour rule, the icon tints
    sharing SwiftUI's hue names).
    Every **chrome** measurement goes through `ChromeGeometry` and
    `metrics.scaled(_:)` — the strip's height, the bottom and trailing hairlines,
    the row padding, the accent indicator. The cell's own glyph sizes (icon 11,
    close mark 9, dot 7, the 14-point slot they share, the 6-point item spacing)
    stay local and scaled, as the sweep guide permits: they are this surface's
    numbers, not chrome measurements another surface could drift from
    (`core-theme.md`, step 3).
  - `BreadcrumbBarView.swift` — the breadcrumb bar above the editor: the open
    file's path relative to the opened project root
    (`backend › src › dialogs.service.ts`), or an abbreviated absolute path when
    the file lives outside the root. All the segment computation is Core's
    `DisplayPath.components(fileURL:projectRoot:home:)` — the view only reads
    `home` (the `TerminalLaunch` precedent) — so this stays display-only and
    untested like the rest of the view layer. Rendered inside
    `ContentView.editorZone`, so both tab orientations get it.
    **Why it is a file of its own**: it was private to `ContentView.swift`, and a
    file gated by `ChromeThemeSourceGatingTests` may name no system semantic
    colour while `ContentView` is full of them for surfaces later parts of the
    sweep will reach — gating rule one is per *file*, so lifting the strip out is
    what let it join the gated set now instead of waiting for its host
    (`core-theme.md`). It draws `bgPanel`, is
    `ChromeGeometry.breadcrumbHeight` tall (a fixed height keeps the editor from
    jumping as the path changes) with `rowPaddingX` horizontal padding and
    `metrics.scaledFont(.subheadline)` text, and — like the tab strip — draws its
    **own** bottom hairline, which is why its host's `Divider()` is gone.
    **Two views in one file**: a thin outer `BreadcrumbBarView` reading
    `@Environment(\.chromeTheme)` and `\.interfaceMetrics`, and a private,
    `.equatable()` `BreadcrumbSegments` storing `fileURL`, `projectRoot`,
    `metrics` and the resolved `ChromeAppearance`, compared by a hand-written `==`
    over the four. The equatable half exists because `DisplayPath.components`
    resolves symlinks (`CanonicalPath.canonical` → `resolvingSymlinksInPath()`, an
    `lstat` walk per path component) while `ContentView.body` re-evaluates on
    **every** keystroke (the editor binding routes each edit through
    `model.updateText`, republishing `openFiles`): keying it on the tab and the
    root keeps that filesystem work off the typing path. The appearance travels
    down as a stored property for exactly the same reason the metrics do —
    equality decides whether the body runs at all, so a view comparing only the
    identity would hold yesterday's colours until the tab changed — and it is an
    **equality term, not a colour source**: the body still asks
    `theme.color(_:)`, so neither view names the theme's *type* and gating rule
    five is untouched. The path is composed as **one** `Text` by `+`, the final
    segment `textPrimary` and every leading segment and `›` separator
    `textSecondary`, with `.lineLimit(1)` + `.truncationMode(.middle)`: one run
    rather than an `HStack` of labels, because middle truncation over a single
    string is what keeps the file name visible in a narrow window while a stack
    would truncate each label on its own and lose the name first.
