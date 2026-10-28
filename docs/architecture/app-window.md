# Pisaka app (macOS) — window chrome: ContentView, project tree, tabs, diff windows

Design documentation moved verbatim from the root `CLAUDE.md` (which now holds a per-file index and the cross-cutting invariants). Each entry records a file's contract, invariants and the reasoning behind non-obvious decisions — read the relevant entry before modifying that file, and update it when behavior changes.

  - `ContentView.swift` — three-column split (`editorSplit`), two nested
    `ChromeSplitView`s rather than the platform's `HSplitView` (`core-theme.md`,
    *The shared split*): the tree at 180/240/360 scaled against a trailing
    minimum of everything right of it at its floor; with vertical tabs a second
    split, `TabColumnSplit` (`TabListView.swift`), holding the tab column within
    `TabColumnWidthRule`'s bounds against the editor's 320. The LeetCode
    statement pane beside the editor adds its rendered width to both splits'
    trailing minimums through `ChromeSplitTrailingDemand`, and the window root
    reads the same preference into the window's width floor
    (`editorRowFloorWidth` + `WindowFloorFrame`), so opening a statement raises the window's
    minimum instead of pushing the editor row past the window's edge. Left zone is
    just `ProjectTreeView` (the old segmented "Project ⇄ Changes" toggle and
    `LeftPanelMode` are gone — Local Changes moved to the bottom dock), middle is
    the open-tabs list (`TabListView`), right zone is the `editorZone` — which
    routes on the selected tab's `kind` and **on nothing else**: a `.viewer` tab
    gets `DatabaseViewerHost(file:)` (`core-database-viewer.md`), **every** `.text`
    tab gets `markdownSplit(for:)` — the editor, and beside it the preview when
    that tab is previewed (`core-markdown-preview.md`) — and no tab at all a
    "No file open" placeholder, reached only with a folder open, because with
    no folder and no tab `workspace` draws the Welcome screen instead of the
    whole split (`WelcomeView.swift` below) (no
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
    `<ExternalChangeBar while model.isInExternalConflict(file.id)>`,
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
    the Settings tab lists them), because a bar that asked two questions at once
    would be a worse thing to discover than an arbitrary order.
    `gopls: LSPGoplsProvisioningModel` and `rust: LSPRustProvisioningModel` are
    threaded in beside `provisioning` and, like it, are **not** observed by
    `ContentView` — the banner observes all three itself, so an install's state
    changes redraw the bar and not the window. The same
    keyed view is where an *already accepted* server is installed on first use, so
    both halves of "what happens when this file is opened" stay in one place; the
    Go and Rust halves of that await discovery rather than reading it, since each
    search is started unawaited at launch and a restored `.go`/`.rs` tab regularly
    beats it (entry in `core-lsp.md`).
    The **LeetCode description pane** (LC-1, full entry in `core-leetcode.md`) is
    the trailing child of an `HStack` around the editor split — a sibling, never a
    fourth split column and never a conditional *wrapping* the editor, since
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
    operations that happen to be reached from the same click. Which of the two a
    candidate takes is asked through `opensDefinitionInSourceViewer`, also passed
    straight through: the app wires it to
    `WorkspaceModel.opensInSourceViewer(_:isOutsideProjectRoot:)`, and its default
    reads the candidate's `isOutsideProjectRoot` alone so previews compile
    (`app-editor.md`).
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
     second rule nothing keeps in step with the height above it. The `Divider()`
     under `SearchBarView` is gone since part five (a) for the same reason: the bar
     draws its own `hairline` along its bottom edge, leaving a one-line comment in
     the style of the one at ~line 403. Because the breadcrumb lives inside
     `editorZone` it covers **both** tab layouts at once — in `.horizontal` it
     simply lands under the tab strip — while the "No file open" branch is
     deliberately left bare (no bar without a file). The window body is a
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
    `BottomPanel.title`, the one table the dock's tab row reads too, and each
    glyph from `BottomPanel.glyph`, the same table's second column — so
    `bottomBarButton(panel:)` takes neither of its own, `panelToggles` builds
    the six from `ForEach(BottomPanel.allCases)`, and neither a tooltip nor the
    order can disagree with a tab; the active one highlighted. The glyphs are
    design glyphs drawn through `DesignGlyphImage`, and why each is distinct
    lives beside the values in `BottomPanel.swift` (`core-services.md`)) sits flush at
    the bottom, and `mainArea` is the three-column `editorSplit` alone, or — when a
    `BottomPanel` is shown — `editorSplit` over the panel, that panel slot
    painted `bgPanel` with **no rule of its own** (the divider above it carries
    the boundary — see the dividers below).

    **The dock's tab row sits inside `panelContent(_:)`** since part four (a):
    the body is a `VStack(spacing: 0)` of `DockTabRow` above the existing
    `switch`, because this is the one place every panel passes through — one
    call site, every panel gets it, and the slot's pinned frame, its top
    alignment, the bar's cover, the divider and `panelHeightRule` are untouched (the
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
    top `hairline` above. All seven controls — `bottomBarButton(panel:)` once
    per `BottomPanel.allCases` entry inside `panelToggles`, and
    `completionToggleButton` — are **icon-only squares**:
    `bottomBarToggleSide` on a side, `bottomBarToggleRadius` of corner radius,
    the icon at `.body`, an `accentTintStrong` ground under an `accent` icon
    while active and no ground under a `textSecondary` icon otherwise (since the
    design pass: `BottomPanel.glyph` at 13 on an `accentTint` ground — see
    below), each
    keeping `.contentShape(Rectangle())`. **The visible titles are gone**, which
    is what makes a tooltip and `.accessibilityLabel(` mandatory on every one of
    them rather than polite: the `Label(title, systemImage:)` they used to carry
    *was* each one's accessibility name, while an unhidden `Image(systemName:)`
    supplies a name of its own instead — the *symbol's* (`core-theme.md`'s rule
    ten). Gating
    rule ten pins both in the brace-matched bodies of `bottomBarButton(` and
    `completionToggleButton`, and pins `bottomBarButton(` at exactly two
    occurrences — the declaration and the one call inside `panelToggles`, whose
    body must read `BottomPanel.allCases` and name no panel case — so the bar
    keeps no second list of panels and a seventh panel arrives through the one
    builder whose name the rule already requires.

    **The toggles' tooltips are AppKit's, not `.help`'s.** Each of the seven
    carries `.background(BarToolTip(text:))` — an `NSViewRepresentable` whose
    `BarToolTipView` sets `toolTip`, draws nothing, answers `nil` to every hit
    test (the click lands on the SwiftUI button in front of it) and is not an
    accessibility element — with the panel's `title` for a panel toggle and
    "Code completion: On"/"Code completion: Off" for the switch. `.help` on the
    same toggles never showed in the shipped window, and the diagnosis is
    recorded here because it did **not** end at a cause this app could fix:
    hosted headlessly in a titled window shaped like the main one, and also
    read off the real main window inside the test host, SwiftUI's tooltip bridge
    (the hosting view's dynamic tooltip manager, asked at a point) answered the
    right string at every toggle — with and without the bar's `.zIndex(1)`, with
    and without the transparent title bar, and with the hit-transparent markers
    (`MainWindowChromeView`, `MainWindowFrameAutosaveView`) in place, an AppKit
    hit test at each toggle landing on the window's hosting view itself. Three
    of the four candidates are therefore ruled out as the cause. The fourth —
    whether the window is key and the application active when the framework
    decides to ask that bridge on hover — is the one step a headless test cannot
    drive: the test host never becomes the active application, and there even a
    bare `Button` with `.help` shows no tooltip, so no headless experiment
    separates "never asked" from "asked and suppressed". With no fix to make at a
    cause, the bar takes the plan's fallback: `NSView.toolTip` is AppKit's own
    mechanism, registered as a tracking rect on the view itself, and does not go
    through SwiftUI's bridge at all. **The bar's three widgets carry theirs the
    same way**, so the whole bar has one tooltip mechanism: the project widget
    "Current project — click to switch", the branch widget "Current branch —
    click to switch or create" and the pull-request indicator its composed
    `helpText(_:)`, each verbatim from its former `.help` and placed with
    `.background(BarToolTip(text:))` so it takes the widget's frame. Each widget
    also names itself outright: the project and branch widgets gained
    `.accessibilityLabel("Current project")` / `("Current branch")` with the
    folder or branch they draw as `.accessibilityValue`, so the text the combined
    label announced before is still spoken; the indicator keeps its label and
    value. Every other `.help` in the window is untouched by this.
    `BottomBarToolTipTests` finds each tooltip view by its text: the seven
    toggles' at their toggle-square frame, in two named tests at scale 1.0 and
    1.8 sharing one assertion helper, and the project and branch widgets' inside
    the bar's band, inside the window, overlapping neither each other nor any
    toggle's square, and as wide as the widget itself — measured by hosting the
    widget alone and reading `fittingSize`, which is the ideal width rounded up,
    so the drawn width is that measure or one backing pixel less, the bar
    aligning both edges to the pixel grid. "Never takes a click" is pinned side
    by side: at the centre of a hosted toggle's tooltip view, `hitTest` answers
    `nil` where a plain `NSView` of the same frame answers itself, and the same
    instance carries the toggle's text. Not being an accessibility element is
    deliberately not asserted, because a plain `NSView` answers that too. Each
    test hosts the bar in one titled window (the completion-state test in two),
    six in all. The indicator is drawn only for a
    current-branch pull request, which the fixture has not, so its tooltip is
    pinned by gating rule ten alone. Rule ten requires `BarToolTip(` and
    `.accessibilityLabel(` and refuses `.help(` in both builders, the
    `BottomBar` struct and the three widget files.

    **No accessibility hint is added**, to any bar control. The toggles' former
    `.help` texts were the panel title and the completion state — word for word
    their accessibility label and value — so a hint would make VoiceOver read the
    same words twice. Rule ten does not require one.

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
    for previews). Beside it sits the new project switcher (`ProjectSwitcherView`), threaded through as the `recentProjects: () -> [RecentProject]` / `onOpenRecentProject: (URL) -> Void` parameters (owned by `PisakaApp`, defaulted). The two switchers' popovers are drawn by one per-window `ChromePopoverPresenter` (`@StateObject`) through `ChromePopoverHost`, an overlay `body` mounts once inside the theme and scale injections, above the bar's `.zIndex(1)`, with the named coordinate space the widgets, the bar and the rows report their frames in; `bottomBar` reports its own top edge to the presenter, and `BottomBar`'s initializer and stored properties are unchanged, so its two suites host it alone (`core-theme.md`, *The bottom bar's popover component*). Beside the branch widget sits
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
    `statusGreen`'s first consumer. **Since the design pass** the bar draws the
    design's own glyphs through `DesignGlyphImage`, at the design's sizes: the
    project switcher `package` 12 (`textSecondary`), its name at `.callout` in
    `textPrimary` and `chevron-down` 10; the branch switcher `git-branch` 12, its
    name and `chevron-down` 10, all `textSecondary`; the indicator
    `git-pull-request` 12, `#N`, and a checks mark that is the design's `check`
    (`statusGreen`) or `x` (`statusRed`) for a verdict — Core's
    `GitHubChecksSummary.indicatorGlyph` — and keeps the panel's SF Symbol,
    sized to 12, for pending or no checks. Each panel toggle is a 22-point
    square of radius 4 carrying `BottomPanel.glyph` at 13, two points from its
    neighbours; the active one draws `accent` on `accentTint` (it was
    `accentTintStrong`), the others `textSecondary`, and the completion switch
    keeps its SF Symbols at 13 (`.body`) in the same colours.
    `BottomBarLayoutTests` measures the toggle squares, their 2-point gaps, the
    active ground and the 14-point widget gap off the real window root at scale
    1.0 and 1.8. All three widgets **drop their own paddings**
    so the bar's 14-point gaps and its `bottomBarHeight` are the measurements
    actually drawn, each keeping `.contentShape(Rectangle())` as its click
    target; the indicator's accessibility label and value and its
    absent-rather-than-empty rule are untouched, and its tooltip moved to
    `BarToolTip` with the other widgets' (above).
    At the **trailing end** of the same bar, after the six panel toggles, sits
    the completion on/off switch (T-4): `completionToggleButton`, in the
    `bottomBarButton` idiom (the same square, the same two states, keyed on
    `settings.completionEnabled`), showing `lightbulb` when on and
    `lightbulb.slash` when off with a tooltip (`BarToolTip`, above) naming the
    state ("Code completion: On" / "Code completion: Off"). It has never carried a `Label`
    title to serve as its accessibility name — and since part three its six
    siblings have lost theirs too — while a tooltip is not a name: the label and the state are therefore spelled out with
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
    reset the height on every panel switch / hide-show), `mainArea` hands
    `BottomDockColumn` (its own entry below) the three parts of a manual
    `VStack { editorSplit; panelDivider; panelContent(panel).frame(height: …) }`,
    which the column stacks inside its `GeometryReader`. A `@State private var panelHeight:
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
    a named coordinate space — `BottomDockColumn` publishes it, under the name
    `panelColumnSpace` that `ContentView` passes in as `coordinateSpaceName` — and
    the gesture is
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
    the bar. It is deleted too, and the rule now holds for all six panels in
    their own files. The *guarantee* is **drawing order at the window root**: the
    body draws `bottomBar` with an explicit `.zIndex(1)` on its own opaque
    `bgPanel` ground, so whatever spills off `mainArea`'s bottom edge — a future
    layout edit, an intrinsic minimum in the editor zone's fixed strips, an
    arithmetic slip — lands *under* the bar, never over it, and clicks on the bar
    still reach the bar. It used to be `.clipped()` on the dock column, and **the
    clip was the lost-top-row bug**: with any panel open the whole editor split —
    the tree's header, the tab strip — sat under the transparent title bar by
    exactly the top safe-area inset (so it never grew with the interface scale),
    and with the dock closed it sat correctly. Bisected in a hosted window
    (`BottomDockLayoutTests`' doc comment carries the measurements): the
    `GeometryReader`, the pin and the coordinate space are innocent, and **a clip
    of any spelling — `.clipped()`, `.clipShape`, `.mask`, a clipped compositing
    group — applied to any ancestor of an `HSplitView`** leaves the split's own
    frame in place while its panes' content drops the inset and rises under the
    title bar; a pure-SwiftUI stack under the same clip keeps it. The dock branch
    was the only one with a clip above the split. With an editor that refuses to
    shrink the clipped column was worse still, pushing the tree's row past the
    window's top edge. So the column now carries **no clip**, and the overflow
    guarantee moved to the root — no constant offset, no padding sized to the
    title bar, no hand-added `safeAreaInsets`, and `MainWindowChrome` untouched.
    The column stays **pinned to the area** — `.frame(width: geo.size.width,
    height: geo.size.height, alignment: .topLeading)` — because a column whose
    children refuse to shrink would otherwise report its oversized height, and
    the coordinate space published on it would be a rect that grows with the
    overflow; with the frame stated it is the `GeometryReader`'s own rect and top
    alignment sends any surplus off the bottom edge, under the bar. The alignment
    is **leading** as well as top, and that half is not cosmetic: `.top` alone
    centers horizontally, and the column *is* wider than the area in a narrow
    window — the split's panes state minimum widths the `GeometryReader` erases,
    so their sum can exceed the window minimum below — at which point a centered
    column pushes half the surplus off the leading edge, cutting the project
    tree's leading edge. Leading keeps the placement the `GeometryReader` gave
    the column before the pin and sends the whole surplus off the trailing edge,
    where the window ends. The **slot itself is top-aligned** for the same
    reason one level in: a fixed frame reports the height it was given, so a
    child that refuses the proposal overflows it — and the default `.center`
    alignment would split that surplus evenly, sending half *upwards*, over the
    divider and into the editor, inside `mainArea`, where the bar's cover cannot
    reach it. `alignment: .top` puts the whole surplus below the slot, which is
    the column's bottom edge, under the bar. Without it the guarantee covers the
    bottom bar and nothing else, and "never over the divider above" would rest on
    the precondition alone — a source rule, which is precisely what the cover is
    here not to depend on. So: the clamp rests on arithmetic and the precondition
    rests on every child honoring its proposal, and both can be wrong, so the
    drawing order makes "nothing inside `mainArea` paints over the bar"
    unconditional against future layout edits and against the editor zone's own
    fixed strips (breadcrumb, tab strip, consent banner, find bar). The cover
    alone would not do — it would silently hide panel content instead of
    shrinking it. Nothing that must escape the window content passes through the
    column: the completion panel, the hover popover and context menus are
    separate windows. All three parts live in the view layer, where
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
    naming `panelColumnSpace` with `minimumDistance: 0` and the column
    publishing the name it is handed; the top-leading pin in
    `BottomDockColumn.swift`, **no `clipped`, `clipShape`, `mask` or
    `cornerRadius` — called with an argument list or a trailing closure —
    anywhere in that file, nor in `ContentView`'s `body`,
    `mainArea` or `editorSplit`** — the split's other ancestors, so a clip that
    moves one level up is refused too (a pane that needs one clips in its own
    declaration, below the split, as the markdown split does) — and
    `bottomBar.zIndex(1)` plus the bar's own `bgPanel` background in
    `ContentView.swift` — the source
    rule that keeps the lost top row from coming back, since a clip is the most
    natural thing to add back to a column whose overflow must not reach the bar;
    and the slot's own `alignment: .top` — read out of exactly the modifiers
    between the `panelContent(panel)` call and the end of the column's `panel:`
    builder, so the column's `.topLeading` cannot satisfy it by accident. The
    layout itself — the top row's y identical with the dock open and closed and
    flush with `contentLayoutRect`'s top, at interface scale 1.0 and 1.8 and
    with the vertical-tabs split's three panes; the bar's frame unchanged; the
    slot ending at or above the bar; an overflowing column keeping its top row
    flush and landing under the bar, whose pixels and clicks stay its own,
    measured only once the harness's layout has settled — is pinned by `BottomDockLayoutTests`
    in the app-layer bundle, the one gate that places views. All the string matches are made against
    whitespace-stripped source, so a reformat that wraps an argument list cannot
    fail the suite while the rule it guards is intact.
    **The window's minimum content size moved to the body root — both axes.**
    `minHeight: metrics.scaled(400)` and `minWidth: metrics.scaled(640)` used to
    sit on `editorSplit`, where `BottomDockColumn`'s `GeometryReader` erases its children's minimum
    sizes — so with a panel shown neither reached the window as a minimum content
    size (they only did in the no-panel branch, which leaves no `GeometryReader`
    between the split and the window, so the two branches disagreed about how
    small the window may be). The height did worse than fail: it still made the
    editor refuse to render shorter than it, which is what pushed the surplus onto
    the bottom bar. Stated on the window body `VStack` both apply in both branches
    and `editorSplit` inside the column is free to shrink to the rule's much
    smaller reservation. **The height and the width now agree in both branches.**
    The width once did not: with vertical tabs the platform split composed its
    panes' floors (tree 180 + tab list 180 + editor 320, scaled, plus its
    dividers) into a window minimum above 640 in the no-panel branch, while the
    panel branch's `GeometryReader` erased them. `editorSplit` is now
    `ChromeSplitView`, which lays its panes out inside a `GeometryReader` of its
    own, so no pane floor reaches the window from the split itself. The root
    therefore composes it: `minWidth` is the larger of 640 and
    `editorRowFloorWidth` — the tree's 180, its strip, the tree's trailing
    minimum (editor 320, plus tab column 180 and its strip with vertical tabs)
    and the width the LeetCode statement reports through
    `ChromeSplitTrailingDemand`, all scaled and built from the same properties
    the splits are handed, so the number cannot drift from them. Zero while the
    Welcome screen stands in for the split. Stated at the root, it holds in
    both branches — the panel branch's `GeometryReader` used to erase the
    platform split's composed floor, so this is stricter than before — and no
    pane is squeezed below its minimum nor the editor row pushed past the
    window's edge. The preference is read on `mainArea`, not on `editorSplit`,
    so it falls back to zero when the split leaves. It is held in a
    `StatementDemandProbe` the root never reads, observed only by the
    `WindowFloorFrame` modifier that applies the floor, so a statement drag —
    which changes the reported width on every frame — re-evaluates that
    modifier and not the whole window root (the `caretReadout` /
    `TabColumnWidthProbe` pattern). `SplitPaneRule`'s
    "trailing minimum wins" stays the in-split answer for a host that does
    not compose a floor. The top-*leading* pin above still
    covers any child that refuses its proposal, which is why that alignment is
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
    frames sum to no more than the area, and pins and clips the pair so a half
    that refuses its proposal cannot paint over the other. That clip is safe where
    the dock column's was not: it sits inside one of `editorSplit`'s panes, below
    the split, and only a clip *above* that split ever lost the top inset. The gesture is measured in `markdownSplitSpace` — the split's own
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
    `LocalChangesView(model: localChanges, projectRoot:, codeFontSize:,
    onRevert:, onOpenDiff:)` — the file list with the selected file's diff
    inline beside it at `settings.fontSize`, while double-click still opens the
    diff in a separate window via `onOpenDiff` — `.problems` → `ProblemsPanelView(model:
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
    `onCommit: (Int, Bool) async -> Void` runs the commit under `PisakaApp`'s gates (the
    `Int` being the project generation the sheet's Commit button captured
    synchronously before its `Task` hop — the `onReplaceAll` shape — and the
    `Bool` whether to push), and the
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
    **The caret readout.** After the completion switch the bar draws
    `CaretReadout`'s string (`core-editor.md`; its measurements are
    `core-theme.md`'s *The bottom bar's caret readout*), handed in as
    `BottomBar.caretReadout` — a plain string, so the bar stays hostable alone.
    It comes from `CaretReadoutModel`, defined in this file: the editor reports
    each caret move's line and column through `CodeEditorView.onCaretMoved`
    (`app-editor.md`), and the model composes the readout on the **next main-queue turn**, coalescing a
    burst of moves into one readout and never publishing from inside a SwiftUI
    update (the editor restores a tab's selection while installing it). It is
    keyed by tab id, and `readout(for:)` answers empty unless that id is the
    **focused text tab** — so a database viewer tab, no tab, or a caret last
    reported by a tab no longer focused draws nothing. The window root holds the
    model as `@State`, **not** `@StateObject`, and only `CaretReadoutObserver`
    around the bar observes it: a caret move re-evaluates the bar, never the
    window root. The language is `SyntaxLanguage(forFileName:)` of the tab's
    display name, as the editor's own highlighter resolves it.
  - `BottomDockColumn.swift` (macOS) — the bottom dock's container, extracted
    from `ContentView.mainArea`: a generic `BottomDockColumn<Editor, Divider,
    Panel>` that `mainArea` renders whenever a dock panel is visible (the
    no-panel branch renders `editorSplit` directly). It owns the container's
    geometry and nothing else — the `GeometryReader`, the `VStack(spacing: 0)` of
    editor (`maxHeight: .infinity`) over divider over panel slot, the
    `.topLeading` pin to the reader's size, and the named coordinate space
    published on the pinned rect. *What* it stacks arrives through three
    builders: the editor, and the divider and panel slot built from the available
    height, which is the one input `BottomPanelHeightRule` needs; the slot
    arrives with its rule-sized, top-aligned frame already on it, and the column
    adds nothing. The space's name is the caller's (`coordinateSpaceName`,
    `ContentView.panelColumnSpace`), because the drag that reads it is built
    there. **It carries no clip, and must not**: a clip on any ancestor of the
    editor's split made the platform split's panes drop the window's top
    safe-area inset and slide under the transparent title bar — the lost-top-row
    bug, whose bisection and fix are in `ContentView.swift`'s entry above. The
    editor's split is now `ChromeSplitView`, which that trap may not reach; the
    column stays unclipped all the same. The
    guarantees it keeps: the divider drag is measured in its stationary pinned
    rect and tracks one-to-one; `BottomPanelHeightRule` stays the one authority
    on the slot's height (the column sizes nothing); top-leading alignment sends
    any surplus down, under the bar, and off the trailing edge, never over the
    project tree's leading edge; and "nothing paints over the bottom bar" is the
    window root's drawing order, not this view's. The window's minimum content
    size stays stated at the body root, because this column's `GeometryReader`
    erases its children's minimums. `BottomPanelSourceGatingTests` pins the pin,
    the absence of any clip spelling and the published space;
    `BottomDockLayoutTests` (app-layer bundle) hosts it in a real window.
    **What that guard does not deliver, stated rather than claimed**: the suite
    hosts this column with stub panes around a platform `HSplitView` of its own,
    because `ContentView` cannot be built in a test — so it cannot see the main
    window's real split, which is now `ChromeSplitView`, and the clip trap it
    records belongs to the platform split and may not apply to the new host at
    all. The column stays unclipped regardless. The real check of the main
    window's top row under the title bar is a live one, made in the running
    app.
    **Why it is a file of its own**: testability of the real container.
    `ContentView` needs dozens of models and closures to exist at all, so no
    layout suite can build it; this view needs none of them, so the suite hosts
    the very container the app renders, with stub panes, rather than a copy that
    could drift from it.

  - `WelcomeView.swift` (macOS) — the Welcome screen, drawn **instead of the
    tree + editor split** when nothing is open: no folder and no tab.
    **The switch.** `ContentView.workspace` asks
    `WelcomeScreen.shows(projectRoot:openFileCount:)` (`core-services.md`) and
    renders either `WelcomeView` or `editorSplit`. Both `mainArea` branches route
    through `workspace`, the one inside `BottomDockColumn` and the one without a
    panel, so the dock, its divider and the bottom bar are the same around
    either. The two empty-state captions survive only in the states the Welcome
    screen does not own. The tree's "Click to open a folder" is reached only with
    tabs open and no folder. The editor's "No file open" is reached only with a
    folder open and no tab. Each site carries a comment saying so.
    **Four parts.**
    - Header: the app icon, "Pisaka", and `CFBundleShortVersionString`.
    - The "Start" column: one row per `WelcomeAction`, each a glyph, the display
      title, and the chord's display string right-aligned.
    - The "Recent" column: `WelcomeScreen.recents(recentProjects())`, read once
      per showing in `onAppear` and never per body evaluation, because the fetch reads the
      session catalog and checks each folder on disk. A row shows the folder name
      over its middle-truncated path. When the list is empty, the column shows
      the hint "Open a folder to get started — it will appear here next time".
    - Footer: the three `WelcomeFooterEntry` labels with Core's chord strings
      ("Zoom ⌘+ ⌘− ⌘0"). It is **informational only**: it runs nothing, so each
      menu item stays the single implementation of its command. Core's pin
      guarantees every advertised chord is a command that is enabled with no
      folder open.
    **Every action is a closure the scene already owns.** `ContentView` maps
    `WelcomeAction` onto `onOpenFolder`, `onOpenFileDialog` (the Open… command's
    panel), `onNewUntitledFile` (`model.newFile()`) and `onOpenLeetCodeProblem`
    (raises the Open Problem… sheet). A recent row calls `onOpenRecentProject`,
    the bottom-bar switcher's own path. The `…Dialog` and `…Untitled` names keep
    these apart from the tree's existing `onOpenFile(url)` and `onNewFile`, which
    mean different things.
    **Layout.** The content is centred, capped at `contentMaxWidth` (760 at 1.0),
    inside a `ScrollView` whose minimum height is the viewport's, so the content
    stays centred while it fits and scrolls once it does not. A
    `ViewThatFits(in: .horizontal)` puts the columns side by side at their own
    widths and falls back to a stacked layout; the footer does the same. Every
    size goes through `metrics`, every colour through a role (`core-theme.md`,
    *The Welcome screen*), and every glyph through `DesignGlyph`.
    **State outlives the view.** The recents and the selection live in a
    `WelcomeViewState` that `ContentView` owns as a `@StateObject`, not in the
    view: opening or closing a dock panel moves `workspace` between
    `mainArea`'s two branches, which recreates `WelcomeView`, and that must not
    reset the selection, re-read the recents or take focus from the panel just
    opened. `onAppear` loads the state only when it is not loaded yet;
    `ContentView` resets it when `WelcomeScreen.shows` turns false, so the next
    showing reads the recents afresh. Focus is taken on the showing's first
    appear and on any later one with the dock closed (`isDockOpen`, passed by
    `ContentView` as `visiblePanel != nil`): closing a panel removes the view
    that held focus, so without it ↑/↓/Return would be dead until a click,
    while opening one leaves focus with the panel.
    **Keyboard.** The view is focusable, with its focus ring suppressed
    (`.focusEffectDisabled()`, chrome rule forty-nine), and draws **no focus
    border in its place** — closed by reason, not deferred: its focus exists
    only so the whole screen receives key equivalents and marks no control, so
    a border around the whole canvas would suggest a selection that does not
    exist (the keyboard selection is the row's `accentTint`). It takes focus on its showing's first appear and whenever it reappears with
    the dock closed. ↑/↓ move Core's `WelcomeSelection`, Tab jumps to the
    other column's first row — or, when that column is empty, is ignored so
    ordinary focus navigation takes it — and Return activates the selected target: an
    action, or a recent folder's URL. Every row carries its flattened index as
    its `id`, and a selection change scrolls that row into view through a
    `ScrollViewReader`, so the stacked layout at the minimum window never
    highlights — or lets Return open — a row below the viewport. Every row is also a real `Button` with an
    accessibility label (the title or folder name) and value (the chord or
    path). It declares no zoom surface and sits under ContentView's existing
    interface root, so `ZoomSourceGatingTests` is unchanged.
    **Tests.** The decisions are Core's, in `WelcomeScreenTests` and
    `WelcomeShortcutPinTests`. `WelcomeLayoutTests` (app bundle) renders the
    view through `HostedRender` at 0.8, 1.5 and 2.0, at the window's content
    minimum and at a large size. It asserts that nothing draws outside the frame,
    that the minimum's columns stack rather than overlap (scrolling to the end to
    reach the recents card), and that the empty-recents hint is present.

  - `ProjectSwitcherView.swift` (macOS) — the bottom-bar project switcher. Reads `recentProjects` inside the button's action before presenting, so the catalog is queried exactly at popover-open time. Takes two closures: `onOpenFolder` (wired to the same open panel) and `onOpenRecent` (called with the URL); the presenter dismisses before either runs. Includes a current-row short-circuit: clicking the already-current project just dismisses the popover. The empty state is the "Open Folder…" row over one "No recent projects" message. Everything sizes through the interface zone (`\.interfaceMetrics`), and it deliberately declares no zoom surface.

    **The popover is the window's in-window component** (`core-theme.md`, *The
    bottom bar's popover component*). The button records its frame in the
    root's named coordinate space and calls `presenter.present(...)` — a toggle
    for the same widget — with no `.popover(` and no `@State isPresented`; the
    presenter comes from the environment and is absent where `BottomBar` is
    hosted alone, where the button presents nothing. The popover opens upward,
    left-aligned to the widget, 4 points above the bar, clamped inside the
    window, with no arrow. Its content is `ProjectSwitcherPopover`: the Head is
    an "Open Folder…" `ChromePopoverRow` with the `folder-open` design glyph;
    the List is a "Recent" `ChromePopoverSectionHeader` over one
    `ChromePopoverProjectRow` per project (name over path, the current row in
    `accent` with `.check` in its slot and the accessibility value "Current
    project"), or a `textSecondary` `ChromePopoverMessage` when there are none.
    It registers its rows with the presenter in display order, the action row
    first, on appear, so ↑/↓ select, Return activates and Esc dismisses while
    the pointer still works as before. The widget's button label, tooltip,
    accessibility label and value, and disabled rule are unchanged.

    **On the chrome roles** since part three (`core-theme.md`): it reads
    `\.chromeTheme` beside `\.interfaceMetrics` and spends `textPrimary` on the
    project's name at `.callout`, `textSecondary` on the leading `package` glyph
    (12) and on the trailing `chevron-down` caret (10) — both design glyphs
    since the design pass, each hidden from accessibility by the helper — the caret the sweep added — the widget opens a
    list and now says so. It draws **no padding of its own**: the bottom bar owns
    the 14-point gaps between its three widgets and its own height, so a padding
    here would make the bar's stated measurements not the ones drawn; the label
    keeps `.contentShape(Rectangle())` so the whole of it stays the click target.
    The popover's colours are the component's roles — `accent` for the current
    row's glyph and name, `textSecondary` for the section header, the path line
    and the empty state, `textPrimary` for a non-current row's name, all on
    `bgPopover` drawn by `ChromePopover.swift`, which this file no longer names.
    Every glyph the file draws is a design glyph, hidden from accessibility by
    the helper (a `Button` combines its children), and the current row's `.check`
    is hidden with a **debt paid**: the row states the accessibility value
    "Current project" for the project that is open — hiding the glyph without
    that left the current row announcing exactly what every other row
    announced, since the `accent` beside it is no more readable without sight
    (`core-theme.md`, rule ten's second half). The slots are separated by
    `hairline` rules the component draws; the file spells no `Divider()`.
  - `ProblemsPanelView.swift` (macOS) — the Problems panel: every diagnostic the
    language servers currently report about the project, grouped by file —
    open files' mapped sets and **closed files' positional ones** alike
    (`core-lsp.md`, D46), so it is the project's list rather than the open tabs'. It observes `DiagnosticsModel`
    (`@ObservedObject` — this view is *for* that state and nothing else renders it)
    and holds no domain logic: a header carries the error/warning counts from
    `model.counts` (information/hint deliberately absent — "how much is broken",
    not "how much was said"; each badge hidden at zero so an all-clear header reads
    as just "Problems"), below it one group per diagnosed file in
    `store.rows(relativeTo:)`'s stable order — file icon, relative path components,
    then rows of severity icon, message (two-line limited) and a one-based line
    number (a closed file's row shows the server's start line plus one). Rows key their `ForEach` by rendered content (`Row`'s `Hashable`), so
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
    runs through `\.interfaceMetrics` like its sibling panels. Activating a row
    calls back with `(url, row)` — the whole `DiagnosticStore.Row`, not a range,
    because a closed file's row carries the server's position, which only becomes
    a range once the file is open. The app wires it to
    `PisakaApp.activateProblem(url:row:)` (`app-shell.md`), shaped like
    `activateUsage`: `openFile(url:viewerRange:)` opens or re-selects the tab, the opened
    tab's text goes to Core's `Row.rangeToReveal(in:)` — the server's position
    mapped onto the buffer just opened, clamped, or the mapped offsets clamped
    into its length — and `reveal.reveal(fileID:range:)` lands the caret. The two
    activations share one open-and-reveal tail, `openAndReveal(url:viewerRange:range:)`, so
    they cannot stop agreeing; a file that did not open leaves no tab and the
    activation returns silently, never beeping and never trapping. An empty
    list draws a centered "No problems" placeholder rather than collapsing, so the
    dock height does not jump when the last squiggle clears. The groups sit in a
    `LazyVStack`: the list is the project's, a workspace-wide server can report
    thousands of rows, and the store republishes on every keystroke's shift while
    the panel shows, so only what is on screen is built.
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
    a `.plain` `Button` whose label is the title from `BottomPanel.title` at
    `.callout`, one line, padded by `dockTabLabelPaddingX`, `textPrimary`
    selected and `textSecondary` otherwise, regular weight in both states (a
    weight change would widen the label and shift every tab after it); the title
    reserves `accentIndicator` of height below itself, and the strip of that
    height is an `.overlay(alignment: .bottom)` on the title's box, `accent`
    selected and `Color.clear` otherwise, so selection never moves the title.
    **The padded title alone sizes a tab**: the strip takes its width from the
    title and can never ask for width of its own. A strip stacked under the
    title as a sibling was the cause of the tabs spreading across the row — a
    shape accepts any width it is offered, so every tab was width-flexible and
    the row shared its spare width among the six instead of giving it to the
    `Spacer`. `DockTabRowLayoutTests` (app-layer bundle) hosts the row in a
    1000-point window, at interface scale 1 and 1.8, and measures it off a
    rendered bitmap: each selected strip as wide as its padded title (measured
    apart, from the font), the six packed from the leading padding a tab gap
    apart, the close glyph at the trailing padding, and the rest of the row
    between the last tab and the close action. The tab carries `.accessibilityLabel(panel.title)` and
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
    (opened on double-click of a Local Changes row or a commit's file, or by the
    external-change bar's Compare). Independent
    of the main window's selection: it takes `fileID`, `fileName`, a model-
    agnostic `load: () async -> [DiffRow]` closure (the owner binds the model and
    arguments in — `LocalChangesModel.rows(for:)` or `CommitLogModel.rows(for:in:)`,
    or, for the external-change Compare, `LineDiff.rows(old: buffer, new: disk)`
    over two texts snapshotted at the press — `DiskSyncController`, `app-shell.md`),
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
    **Chrome (part five (b), `core-theme.md`).** Gated. The root resolves its one
    colour — "Loading…" in `textSecondary` — through a private `chromeColor(_:)`
    in the window-root shape, holding no `\.chromeTheme` in its struct; the
    side-by-side pane inside it was swept in part four (b).
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
    **Chrome (part five (b)).** Gated, naming no role: it constructs
    `EscClosableWindow`, which paints the window's `bgPanel` ground; the
    controller sets none of its own (rule twenty-eight).
  - `SourceViewerWindowController.swift` — owns the separate, non-modal **source
    viewer** windows a Go to Definition opens when the declaration lives *outside*
    the opened folder (`core-lsp.md`'s D3): an SDK `.swiftinterface`, a dependency
    checkout, a generated header — and, through the open funnel
    `PisakaApp.openFile(url:viewerRange:)`, every file inside dependencies under
    the opened folder (`WorkspaceModel.opensInSourceViewer`, `app-shell.md`). Same shape as `DiffWindowController` — an
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
    having created nothing, and the caller — `PisakaApp.viewDefinitionOutsideProject`
    or the funnel — beeps, exactly as a ⌘-click that resolved nothing does. It reads through
    `FileService.readTextIfNotBinary` under
    `LSPIntelligenceProvider.maximumTargetFileBytes` — deliberately the same door and
    the same cap the provider already used to turn the server's `(line, character)`
    into an offset, so on the D3 route a file the provider refused produced no
    candidate at all and the viewer is never asked for something larger. On the
    funnel's route the cap is a **real limit**: a file inside dependencies over
    16 MB, or one that reads as binary, opens nothing and beeps, where before the
    dependency rule it opened as a tab. *It reuses a window per file.*
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
    **Chrome (part five (b)).** Gated, naming no role, like the diff window's
    controller: the window ground is `EscClosableWindow`'s.
  - `SourceViewerContent.swift` — the SwiftUI content of a source viewer window:
    one file, read-only, syntax-highlighted, scrolled to a range. Modeled on
    `DiffWindowContent` + `DiffView`'s read-only pane — same `preferredColorScheme`
    propagation into a separate window, same `PredicateResolvingHighlighter` through
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
    **Chrome (part five (b), `core-theme.md`).** Gated, naming no role: its pane's
    one colour — the text view, scroll view and clip view on `bgEditor`, so the
    gutter's own `bgEditor` fill shows no lighter band beside the text — is now
    `CodePaneGround.apply(scrollView:textView:)` (`DiffView.swift`), the one
    definition its four callers share, replacing the three assignments it used to
    make itself. A root that paints no SwiftUI colour.
  - `ProjectTreeView.swift` — the project file tree: when `projectRoot == nil`
    (reached only with tabs open, since with no tab either the Welcome screen
    replaces the whole split) it shows a centered "Click to open a folder" hint whose whole pane is the
    click target (`contentShape(Rectangle())` + `onTapGesture`) and calls an
    `onOpenFolder()` callback (wired `PisakaApp → ContentView → ProjectTreeView`,
    same shape as `onOpenFile`). Otherwise recursive rows from the root.
    Directories are `DisclosureGroup`s (`DirectoryNodeView`) that lazily load
    children via `model.children(of:)` on expansion (with `@State`), read
    through the tree's one `TreeListingMemo` and drawn as `TreeChainRule`'s
    rows — a folder or a single-child chain, see the chain entry below; files are
    clickable rows that call an `onOpenFile(url)` callback. Directory rows are
    drawn through a private `DisclosureGroupStyle` (`FolderDisclosureStyle` + its
    `FolderDisclosureRow`) that renders chevron and
    label as **one full-width row**: the whole row toggles expansion, not just the
    chevron, and it carries the same hover highlight and padding as a file
    row (`FileRowView`), so both row kinds read and behave alike. Because the
    style draws the chevron itself there is no separate disclosure control, so
    "one click, one state change" holds by construction — the row's single
    `.onTapGesture` is the only path that changes expansion, and it is the same
    path a chevron click takes. Drawing it also *removes* a control assistive
    technology could actuate (a real disclosure triangle is a button with an
    expanded/collapsed value; an `onTapGesture` on an `HStack` is nothing), so
    the row re-declares itself as one — combined element, `.isButton`, the
    expansion state — followed by the git state's word, see the git-status
    entry below — as its `accessibilityValue`, and an `accessibilityAction`
    toggling the same binding, adding no second expansion path. **The glyphs
    are the design's**, drawn through `DesignGlyphImage` in `textSecondary`: the
    chevron at 12 in the 12-point chevron column — `chevron-down` when expanded,
    `chevron-right` when collapsed, two glyphs rather than one rotated — then,
    after the 4-point gap, `FileGlyph.forFolder(expanded:)` at 14 in a 14-point
    slot (`TreeRowLayout.iconSize`); a file row draws `FileGlyph.forFile(named:)`
    in the same slot, and the inline draft draws the glyph its row will have.
    Both glyphs inside that element are hidden from accessibility by the helper:
    combining children would fold an unhidden image's own name into the
    element's label, and both are decorative beside the name, the button trait
    and the value. `TreeRowGlyphLayoutTests` (app bundle) renders a tree once per
    scale (1.0 and 1.8) and finds ink inside the 12- and 14-point slots, none in
    the gap or in a file row's chevron column. That restores
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
    derived from the two. Both sets have the same **four** readers — both row
    kinds; since the inline draft occupies the row it stands in and must be
    padded and gutter-inset with the very same numbers or the tree would visibly
    shift as a draft opens and closes, `ProjectTreeDraftField.swift`; and the
    indent guide, which centres its rule in the chevron column inset by the row
    padding (see the indent-guide entry below) — which is
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
    placed below the pinned stack (`TreeStickyRule.placement`, see the
    sticky-folders entry below); a drafted file or folder row swaps its label for the
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
    *successful* reload whose rows no longer offer the way down to the
    drafted row (`draftHangingBelow()` asking each returned row
    `TreeRow.leads(toDraftAnchor:renaming:)` — the drafted entry itself when
    the draft is anchored in that directory, otherwise the child folder its
    subtree hangs from, which must still be a directory, since a folder
    replaced by a file of the same name stops rendering its subtree without
    losing the name; for a chain row, only its tail or below). All three are the whole *subtree*, not the direct children: a
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
    gate as defense-in-depth, while `onRun(URL)` / `onRunTest(URL)` take
    only the row's url and `onDelete(URL, String?)` also carries the name
    the confirmation quotes (a chain row's label, `nil` otherwise — see the
    single-child chains entry). The callbacks only *request* the
    operation: `PisakaApp` validates once more, performs the disk I/O and
    bumps `treeRevision`. `DirectoryNodeView` also observes `.onChange(of:
    model.treeRevision)`: when currently expanded it re-reads its listing
    (through the tree's `TreeListingMemo`, which reads `children(of:)` once per
    revision — see the single-child chains entry) so a created / renamed /
    deleted entry appears without
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
    and the bump needs no disk I/O — **followed by `onRefreshGitStatus()`**, the
    one callback it does take: the names' git colours are the other half of what
    the button promises, and a git refresh is the app's to run. `ContentView`
    threads it through and `PisakaApp` wires it to `refreshLocalChanges()`, which
    pins its request generation synchronously, so a refresh superseded by a later
    one publishes nothing; the default is a no-op so previews and tests construct
    the view without the wiring. The header is absent from the
    `projectRoot == nil` placeholder so its whole pane stays the open-folder
    click target. So `treeRevision` — the single trigger on which
    `DirectoryNodeView` reads the disk anew (a node also reloads when its parent
    hands it a new shape and re-runs the chain rule when `separated` changes,
    both through the memo and listing nothing new) — now has three sources: the app's own
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
    source app with it — behind a dialog. The highlight is **`dropTargetTint`**,
    reached at the *same* site and through the same rule as every
    other row state: the row asks `TreeRowState.state(isSelected:isWindowKey:
    isHovering:isDropTarget:)` (`core-theme.md`) and paints the answer through
    `TreeRowBackground.background(for:isTestRow:resolving:)`. Drop outranks hover there because
    the pointer is inside the row and both conditions are true at once, and "will
    this drop land here?" is the only question being asked; the wash is heavier
    than `accentTintStrong` for the same reason — a drop over a row that is also
    selected has to out-read the selection. The drop target maps to
    `dropTargetTint` through `TreeRowBackground`, which composes no alpha — the
    accent's hue at a third strength the palette carries (part five (g) in
    `core-theme.md`) — and `TreeRowBackgroundTests` pins it. One rule and
    one mapping, read by both row kinds (and by the sticky stack's pinned
    folder copy, hover only), is what stops the treatments drifting
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
    `TreeRowState.state(...)` and paints the answer through the file-scope
    `TreeRowBackground.background(for:isTestRow:resolving:)`, whose state layer
    is `role(for:)`'s answer — `hover` → `hoverTint`,
    `selectedFocused` → `accentTintStrong`, `selectedUnfocused` →
    `selectionInactive`, `dropTarget` → `dropTargetTint`, and `plain` →
    no layer, the *absence* of a background rather than a colour of its own
    (the test-row wash beneath it is the **test rows** entry's, below).
    (`role(for:)` answers a role for every state but one, and `nil`
    only for `plain`, which paints nothing; no state composes an alpha, the drop
    wash's strength coming from the palette — pinned by
    `TreeRowBackgroundTests`.) The theme arrives as a
    role-to-colour *function*, not as the theme value, so no view file names
    `ChromeTheme` — rule five of the gating suite (`core-theme.md`). Both row
    kinds — and the sticky stack's pinned folder copy, hover only — read that
    one mapping, for the reason they share the geometry tokens.
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

    **Reveal in Project Tree** (the tab menu's item, `app-shell.md`) reaches the
    tree as one optional, one-shot `TreeRevealRequest`, declared app-side in this
    file: a monotonic `token`, the `target` file and its `ancestors` — every
    directory from the opened root down to the target's parent, root included,
    which is `TreeRevealRule.ancestors` (`core-workspace.md`), spelled the way the
    tree spells its rows. `init?(after:revealing:root:)` builds the next request
    (the previous token plus one, so revealing the same file twice is two requests
    and the second re-expands what the user collapsed in between; nil without a
    root or outside it), and the target is the last ancestor plus the file's name,
    so it too is the row's own spelling. `expands(_:)`, `targets(_:)` and
    `rowID(_:)` compare **standardized paths**, not urls: a listing spells a
    directory with a trailing slash and an appended component does not, and the
    two must still match — that logic is why `TreeRevealRequestTests` (app bundle)
    exists. They are asked of each node's `revealURL` — the opened root plus one
    listing *name* per level — never of its listed `url`: a listing may spell its
    entries under a resolved parent (`/tmp` lists as `/private/tmp`), which the
    request, spelled under the root as opened, does not share. The file row keeps
    its listed url as its scroll id. The request **expands and scrolls; it never selects**: the app selects
    the tab first, so the existing `TreeSelection` highlights the row — one
    selection, not a second spelling of it. It is handed down the recursion beside
    `selection`. A `DirectoryNodeView` whose url the request `expands` sets
    `isExpanded = true` from both `.onChange(of: reveal)` and `.onAppear` — a node
    already on screen sees the request change, but a child created by its parent's
    expansion exists only after the request arrived and sees it only on appear —
    and remembers the token it honoured, acting once per request. Expansion runs
    through the ordinary `onChange(of: isExpanded)` → `loadChildren()` path, so
    lazy loading and the `treeRevision` refresh are unchanged. **The scroll is
    causal, not timed**: file rows carry `.id(TreeRevealRequest.rowID(url))`, and
    the target row reports `onRevealed(token, id)` from its `.onAppear` (its folder
    just expanded) and from `.onChange(of: reveal)` (already on screen);
    `ProjectTreeView` then scrolls the existing `ScrollViewReader` to it at
    `UnitPoint(x: 0, y: TreeStickyRule.revealAnchorY)` — the centre, which
    always clears the pinned stack (see the sticky-folders entry below) — the reader wraps the `ScrollView`, since a proxy drives only the
    scroll views its reader contains. That report also **withdraws the request** — the tree records the
    completed token and hands `nil` down from then on — so a node the user later
    collapses, or one rebuilt by a re-expansion of its parent, is never re-opened
    by a request already honoured. **A request that cannot be honoured is
    withdrawn too**: every ancestor node checks its listing for the row the request
    needs there (`step(below:)` — the next ancestor, or the target inside the
    deepest) after `loadChildren()` and, already expanded, when the request
    arrives, and reports `onRevealed(token, nil)` when it is missing — a file under
    the excluded `.git`, one deleted while its tab stays open — or present with
    the wrong kind: an ancestor step must list as a directory and the target as a
    non-directory, or no row would ever continue or complete the request. The
    listing is matched by entry name, for the resolved-parent reason above. Without that, a request whose row never appears would
    stay live and re-expand every rebuilt folder the user collapsed. **A
    chain row asks the chain variants**, `expands(anyOf:)` and
    `isUnreachable(belowChain:listing:)`, over its segments' reveal spellings
    (see the chain entry below). The `"draft-row"` scroll id is unchanged.
    **Both `.onChange(of: reveal)` sites use the two-argument form**, whose
    action reads the update it was called for: the deprecated one-argument
    form's action reads the previous update's `reveal`, which for a node or
    row already on screen is still `nil` — so a request never expanded an
    on-screen folder nor scrolled to an on-screen row, and only `.onAppear`
    ever honoured one. `TreeRevealOnScreenTests` (app bundle) pins the node
    half — a request published to a hosted tree expands its already-drawn,
    collapsed `t` — and `TreeStickyScrollRoundingTests`' second reveal (the
    sticky entry) the row half. **Every `onChange` in the file is the
    two-argument form**, not only the ones that read a captured value (the
    reveal, `shape`, `separated` and `treeRevision` handlers, the last through
    `reloadOrForget()`'s read of `shape`): the `projectRoot`, `isExpanded` and
    `draft` handlers moved too, so a new handler copies the safe form.
    `ProjectTreeSourceGatingTests` (Core) pins it over the file's stripped
    text — every `onChange(` call, wrapped or not, must end in a trailing
    closure naming exactly two parameters — and was seen red on the four
    one-argument sites before they moved.
  - `ProjectTreeView.swift`, **git-status name colouring** — each row's *name*
    is drawn in its git state: conflict, modified, added, ignored or plain
    (`TreeGitStatus`, `core-git-models.md`). `ProjectTreeView` takes the lookup
    as a value, `gitStatus`, **`.empty` by default** so previews and the
    existing app tests construct it unchanged; `ContentView` passes
    `localChanges.treeGitStatus`, and the value travels down the recursion
    beside `selection` to every folder and file row. Each row asks it **once
    per render**, lexically — a folder its own url in `DirectoryNodeView`'s
    body, a file through the folder listing it — and the name's colour and the
    row's spoken state are both drawn from that one answer. Only the **name
    text** takes `ChromeColorRole.treeNameRole(for:)` (`core-theme.md`) through
    the injected theme, via the file-scope `treeNameForeground(_:resolving:)`,
    which applies **no foreground at all** for `plain` (`nil`), so a tree outside
    a repository stays pixel-identical to the tree before git state. The icon
    stays `textSecondary`, the chevron is unchanged, the row background still
    comes from `TreeRowState` through `TreeRowBackground`, a selected row keeps
    its status colour (the background is a separate answer), and the inline
    rename field is not recoloured. **Accessibility**: a folder row's value is
    Core's `TreeGitState.accessibilityValue(state:mark:row:isTestRow:isDependencyRoot:)` — the
    expansion word, then a dependency root's "Dependencies", the test row's
    "Test", the state's word and the diagnostic mark's words, each when there
    is one,
    joined by `", "` (still `""` while a
    rename draft is open); a file row becomes **one combined element** carrying
    those words as its value, `""` when plain and clean, and stays `.contain` while
    its rename draft is open, mirroring the folder row, so the field stays
    reachable as itself. **The tree only reads git state**: no timer, no git
    call and no writer-gate interaction of its own; its one trigger is the
    Refresh button's `onRefreshGitStatus`, which asks the app — it redraws
    when the model publishes a new lookup, which every existing refresh does —
    the tree's own file operations included, which re-ask git themselves
    because the watcher drops this process's writes (`app-shell.md`).
    Chrome gating rule fifty-one pins `ProjectTreeView.swift` as the mapping's
    only reader and `ContentView`'s hand-off of the lookup (`core-theme.md`);
    `TreeGitStatusColourTests` (app bundle) renders one tree with the lookup
    and once with `.empty`, and pins that a folder and a modified file draw
    their names in `statusYellow`, an ignored file's in `textSecondary`, the
    glyph unchanged, and a plain row pixel-identical to the tree without git
    state.
  - `ProjectTreeView.swift`, **test rows** — a row Core's `TreeTestRule`
    (`core-workspace.md`) answers as a test row — under a test folder, a test
    folder itself, or a file named by its ecosystem's test convention — is
    washed in `ChromeColorRole.treeRowWashRole(isTestRow:)`'s answer, the
    palette's faint green `diffAddedBackground`, **beneath** the row-state
    tints. **Components down the recursion**: `DirectoryNodeView` carries
    `relativeComponents`, the root-relative listing names of its contents
    directory — `[]` for the root, which is therefore never a test row, and the
    parent's plus `TreeNodeShape.segmentNames` (the folder's name, or every
    segment's for a chain) for a child — so no canonicalization enters and the
    cost is the row's depth. Each node asks the rule **once per render** with
    `isFolder: true` (a chain is judged by its tail, so a test segment anywhere
    in it washes the row); each file row is asked by the folder listing it with
    `relativeComponents + [entry.name]` and `isFolder: false`. Both answers
    pass through the row's dependency state's
    `showsTestWash(isTestRow:)` before they are used, so **nothing inside
    dependencies is washed** (the **dependency folders** entry, below); the
    fields keep their `isTestRow` names, which is what leaves the three gated
    background bodies' text unchanged. **One site**:
    the folder row, the file row and the sticky stack's pinned copy all paint
    through `TreeRowBackground.background(for:isTestRow:resolving:)`, which
    lays `layers(for:isTestRow:)` — the wash role first, then `role(for:)`'s
    state role, `nil`s dropped — bottom to top, each the resolver's colour
    unchanged and composing no alpha; so hover, selection and a drop target
    paint over the wash and a selected test row still reads as selected. The
    commit dialog's file row keeps `color(for:resolving:)` and is never washed.
    **The pinned copy** reads the node's own answer, carried on its
    `TreeStickyFolderReport` (`isTestRow`). **Drafts**: the row being renamed
    keeps its wash (the background ignores `isDrafted`) while its spoken value
    stays `""`; the create draft row is not wired and is never washed.
    **Accessibility**: a test row's value gains `Test` — after a folder's
    expansion word and before the git and diagnostic words, a clean test file
    saying just `Test` (`TreeGitState.accessibilityValue(state:mark:row:isTestRow:isDependencyRoot:)`,
    `core-git-models.md`). Chrome gating rule fifty-two pins the wash's one
    reader and that every ask lies inside `enum TreeRowBackground`
    (`core-theme.md`); `TreeRowBackgroundTests` pins `layers(for:isTestRow:)`
    over all ten combinations and the layered background's resolver use, and
    `TreeTestRowWashTests` (app bundle) renders one tree per appearance and
    pins that the `Tests` folder, its child and `a_test.go` are washed, an
    unwashed sibling and the canvas are not, and a selected test file draws its
    selection tint rather than the wash. That selected row is a file of its own
    because the unfocused selection, `selectionInactive`, is **opaque**: a
    selected test row in a window that is not key shows no wash, while hover,
    the focused selection and a drop target are translucent and show it.
    `TreeRowBackgroundTests` also renders `Layered` once to pin that the last
    colour paints on top, and `TreeTestRowReportTests` (app bundle) that a
    chain's node is judged by all its segments (`src/test/java` washed,
    `lib/core` not) and that the pinned copy's report carries that answer.
  - `ProjectTreeView.swift`, **dependency folders** — a folder Core's
    `DependencyFolderRule` (`core-workspace.md`) answers as a **dependency
    root** — a table name with one of its markers beside it — draws a
    `dependencies` **tag** after its name, drawn through the shared
    `ChromeTag` (`core-theme.md`): the word in `textSecondary` at the
    `.caption` interface style, inset by `ChromeGeometry.tagPaddingX` /
    `tagPaddingY` inside a `Capsule().strokeBorder` in `hairline` at
    `hairlineWidth`, with no fill — the form the Pull Requests panel's state
    tags already take. It sits inside `TreeFolderLabel`'s `HStack(spacing:
    metrics.scaled(4))` after `name()`, at the `HStack`'s default centre
    alignment, so it stays vertically centred on the row. The call site adds
    `.fixedSize()`, so a long name truncates first and the tag stays whole,
    and `.accessibilityHidden(true)`. **Why a tag and not a plain word**: the
    common real dependency root is gitignored, so its *name* is already drawn
    in `textSecondary`; a word in that role at the name's own font read as
    more of the name. The ring and the smaller style make it read as a mark.
    No role, no palette value and no gated rule was added; the two padding
    tokens moved into `ChromeGeometry` from the panel's layout table.
    **Boundary versus inheritance**: only the root row is tagged; every row
    below it is **inside dependencies**, untagged, and never washed as a test
    row — a vendored package's `test` folder washes nothing.
    **State down the recursion**: `DirectoryNodeView` carries
    `dependencyState: DependencyFolderRule.State` beside `relativeComponents`.
    The root passes `.outside` and never evaluates itself, so it is never a
    dependency root whatever it is called. A child node is
    `.node(segmentNames:siblingNames:parent:)` — `.inside` under a `.root` or
    `.inside` parent, otherwise `.root` exactly when the row is a root row — and
    a file row is `.file(inParent:)`. The names come from the listing the node
    already holds (`currentChildrenNames`), so the state costs **no I/O**.
    **Chains**: a chain row is a root row when **any** segment is one, which in
    practice is its head (a root always has a marker beside it, so it is never
    a folder's sole entry). The head is asked about the parent's listing names;
    a later segment about `[its own name]`, because `TreeChainRule` folds a
    folder only when it is its parent's sole entry. The row stands for its head,
    as its git colour does, and everything below the chain inherits.
    **The pinned copy** reads the node's own answer from
    `TreeStickyFolderReport.isDependencyRoot` (part of its `==`) and passes it
    to `TreeFolderLabel`, so the copy is tagged as its row is. **Drafts**:
    the row being renamed keeps its tag beside the rename field (the field
    replaces only the name); the create draft row is not a `TreeFolderLabel`
    and never shows one. **Accessibility**: a dependency root folder's value
    gains `Dependencies` after its expansion word and before `Test`, the git
    word and the diagnostic words (`TreeGitState.accessibilityValue(state:mark:
    row:isTestRow:isDependencyRoot:)`, `core-git-models.md`); file rows pass
    `false`, and a drafted row still says `""`. **Tests.**
    `DependencyFolderRuleTests` (Core) pins the rule and the state;
    `TreeDependencyCaptionTests` (app bundle) renders one tree per appearance —
    a root `node_modules` beside `package.json` and an `other/node_modules`
    beside no marker, two packages each so neither chains — with a git lookup
    marking the root `node_modules` **ignored**, the common real case. It pins,
    in both appearances: that the case is real (the name's pixel farthest from
    the row background is nearer `textSecondary` than `textPrimary`); the **ring** (on the row's
    centre line a narrow window at each end of the tag, clear of the word,
    holds a pixel off the background); the **size** (the word's vertical ink
    band is strictly shorter than the name's — read on the central half of the
    word's columns, because the capsule's end radius exceeds the horizontal
    inset, strictly between the ring's top and bottom lines found on those
    columns, and on the name's first letters `nod`, an ascender and no
    descender like the word's central columns, because the underscore's drop
    below the baseline otherwise let a tag drawn at `.body` pass); and the
    **unmarked row** (the band where a tag would sit, one indent step further
    right on `other/node_modules`, holds only its background, with the sixth
    row proving the reveal expanded `other/`). Each bitmap assertion was
    checked against its mutation under the pinned Xcode: no `strokeBorder`
    fails the ring, `.body` fails the size, no tag at all fails the ring.
  - `ProjectTreeView.swift`, **diagnostic severity dots** — a row whose file or
    folder has an error or a warning at or below it carries a **6 pt dot** in
    its glyph's bottom-trailing corner. The lookup is Core's `TreeDiagnostics`
    (`core-lsp.md`): `ProjectTreeView` takes it as a value, `diagnostics`,
    **`.empty` by default**, beside `gitStatus` and for its reasons, and passes it
    down the recursion the same way. Each folder and file row asks it **once per
    render**, lexically, and the dot and the row's spoken words are drawn from
    that one answer. The dot is the file-scope `treeDiagnosticDot(_:diameter:
    resolving:)`: an `.overlay(alignment: .bottomTrailing)` on the glyph — so the
    glyph's slot, and with it every name's alignment, is untouched — holding a
    `Circle` `metrics.scaled(TreeRowLayout.diagnosticDotSize)` across (the new
    `TreeRowLayout` token, 6, under half the 14 pt slot so the glyph still reads),
    filled with `theme.color(ChromeColorRole.diagnosticRole(for: severity))` and
    hidden from accessibility; with no severity the overlay is empty and the row
    draws exactly as before. The severity is the mark's `severity`, handed
    straight to Core's mapping, so the tree spells **no severity case label**
    (chrome gating rule fifteen, which now names the tree as the role's third
    reader, `core-theme.md`); there is no arithmetic on the token and no opacity.
    The name colour, background, indent guide and glyph tone are untouched, and
    the draft-hosting row keeps its glyph and therefore its dot. A folder's dot
    stands for everything beneath it, expanded or not — a collapsed folder is
    exactly where a closed file's problem needs pointing at. **Accessibility**:
    the mark's words ("has errors", "has warnings") follow the git word in the
    row's value, through the same Core composition above; headless SwiftUI builds
    no accessibility nodes, so that composition is tested in Core
    (`TreeGitStatusTests`). **Publishing without re-rendering per keystroke**:
    `ContentView` still observes nothing of `DiagnosticsModel`, whose store
    republishes on every keystroke's shift. The lookup reaches the tree through
    `TreeDiagnosticsObserver`, a thin wrapper kept in `ContentView.swift` that
    observes only the model's `TreeDiagnosticsHolder` — which assigns only on
    inequality — around the tree alone, so a lookup change re-evaluates the tree
    and not the window root, and a shift that keeps every worst severity
    re-evaluates nothing; without a model (previews, tests) the tree receives
    `.empty`. **A reader**: the dot, the lookup and the wrapper neither raise nor
    consult the writer gate. `TreeDiagnosticMarkTests` (app bundle) renders one
    project — an error file, a warning file, a clean file, a collapsed folder
    holding a warning file, a collapsed clean folder — at scale 1 and 1.8, with
    and without the lookup, and pins `statusRed` in the bottom-trailing quarter of
    the error file's and the root folder's glyph slots, `statusYellow` for the
    warning file and folder, the clean rows' slots identical to the render
    without the lookup, and the dot's extent growing with the scale.
  - `ProjectTreeView.swift`, **indent guides** — while a folder is expanded, a
    private `TreeIndentGuide` draws one vertical `hairline` rule **behind its
    children block**. `FolderDisclosureStyle` wraps `configuration.content` in
    one zero-spacing `VStack` and gives that stack the guide as a leading
    `.background`, so the guide is *one* background spanning the whole block —
    nested expanded blocks and an open create-draft included — rather than a
    modifier each row would receive, and every row's own background paints over
    it exactly as before. **Placed by layout, never by arithmetic on a token**
    (chrome gating rule seven): the scaled `ChromeGeometry.rowPaddingX` as a
    leading inset, then a frame exactly one scaled `TreeRowLayout.chevronWidth`
    column wide with the scaled `ChromeGeometry.hairlineWidth` rule centred in
    it — the chevron's own two measurements, so the guide sits on the centre of
    the parent folder's chevron column at every interface scale. Nested folders
    sit one indent step in, so their guides land one step deeper with nothing
    here knowing about depth. A collapsed folder draws nothing, its content not
    being rendered at all. Decoration only: `allowsHitTesting(false)`, hidden
    from accessibility, no highlight and no setting. It adds no width to the
    content, so `TreeRowGlyphLayoutTests` stayed green unchanged.
    `TreeIndentGuideLayoutTests` (app bundle) renders a tree whose root is
    expanded with a couple of children, once at scale 1 and once larger, and
    finds a `hairline`-coloured column of the scaled width at the root chevron's
    centre across the children rows' span, moving with the scale, and absent
    from the root row itself.
  - `ProjectTreeView.swift`, **single-child folder chains** — a run of folders
    each holding nothing but the next (`src/main/java/com/acme`) is drawn as
    **one row** labelled `a/b/c`, whose expansion goes straight to the last
    folder's contents. Every decision is `TreeChainRule`'s (`core-workspace.md`);
    the view maps the answer to rows and derives no address of its own.
    **Row kinds.** A node's children are `TreeChainRule.rows` over its listing: a
    file (`FileRowView`), a plain folder or a chain. The two directory kinds go
    through **one** `ForEach` branch and one `DirectoryNodeView`, identified by
    `TreeRow.id` — the head — and handed down as a private `TreeNodeShape`
    (`.folder` or `.chain`), so a folder that turns into a chain or back keeps its
    node and its `@State`, expansion above all. The root is built as itself, a
    single-segment `.folder`; it is never one of a listing's entries, so it heads
    no chain. **Identity is the head, contents are the tail**: the row lists,
    expands to and creates into its contents directory, its children's reveal
    spelling continues from the tail's, and every other address is read off
    `TreeChain` — rename names the tail, Delete and the drag source address the
    head, the drop destination is the tail (`FolderDisclosureStyle` /
    `FolderDisclosureRow` carry `dragSource` and `dropDestination` separately;
    the root still drags nothing), and the diagnostic dot and spoken git state
    are the head's, the row standing for the head's subtree.
    **Drawing.** The label is **one** `Text` of concatenated runs, so a long
    chain truncates in the middle as a whole: each segment's name in
    `ChromeColorRole.treeNameRole(for:)` of its *own* segment's git state (or the
    inherited foreground when there is none), each `/` in `textSecondary`. The
    glyph is the folder glyph with **one** diagnostic dot, the head's mark; the
    accessibility element, value and drafted `.contain` are a plain folder's.
    A chain's rename field replaces the tail's name only: the leading segments
    and their `/` stay drawn before it, coloured as in the label, passed into
    `TreeNameFieldView` as its optional `leading` text, and the field validates
    against `TreeChain.renameSiblings`. A create draft opens under the row and
    validates against the tail's listing. `isDrafted` is "the draft renames this
    row's tail". Children are inset one `treeIndentStep` and the indent guide
    hangs from the row's chevron exactly as for any folder; every size is
    through `InterfaceMetrics` and every colour a role, so no file joins a gated
    set.
    **Menu.** New File / New Folder (into the tail); `Rename "<tail>"` and
    `Delete "<label>"`, the titles being `TreeChain`'s; then `Show as Separate
    Folders`. A plain folder keeps `Rename` / `Delete`, and a separated folder
    whose joining the rule says would draw a chain of more than one segment
    (`offersShowAsOneRow`) adds `Show as One Row`. **The delete confirmation
    names what the menu item named**: the tree's `onDelete` carries
    `(URL, String?)` — the head's real url and the shape's
    `deleteConfirmationName`, which is `TreeChain.deleteConfirmationName` (the
    label, the very name `deleteTitle` quotes) for a chain and nil for a file
    or plain folder. `ContentView` passes it through and
    `PisakaApp.deleteItem(at:named:)` hands `FilePanels.confirmDelete` the
    name, or `url.lastPathComponent` when it is nil, so a file's and a plain
    folder's sheet is exactly as before. The two view items are view choices,
    not file operations: no draft, no gate.
    **The unfold memory.** `separatedFolders: Set<String>` is `@State` on
    `ProjectTreeView`, keyed by `TreeChainRule.key(for:)` and handed down as a
    value beside `opensOnAppearance`, with one callback carrying a private
    `TreeSeparationChange` — `separate(head:opening:)`, `join`, `appeared`.
    `Show as Separate Folders` inserts the head only, so the row becomes `a` over
    `b/c`, which offers the same item again; `Show as One Row` removes the folder.
    Unfolding an **expanded** chain also records `TreeChain.remainderHead` (the
    second segment) in the transient "open on first appearance" set: the new
    node starts expanded and spends its key in `.onAppear`, so the row the user
    was looking at stays expanded, while the head keeps its own expansion because
    its identity is unchanged; a collapsed chain records nothing. **A stated
    limit**: folders the user had opened *below* the tail are rebuilt under the
    new remainder node and come back collapsed (the same holds for `Show as One
    Row` on an open folder's descendants), since expansion is per-node `@State`
    and nothing tree-wide records it. Neither set is
    written to the session, both are cleared on a project-root change, and
    neither is pruned — a key whose folder is gone matches no row. A `separated`
    change re-runs the rule over the node's own **remembered** listing against
    the memo alone (`rememberedListing(of:revision:)`), stores that listing as
    the node's `children` — so the rows and the listing the create draft and
    reveal read come from one read — and lists nothing — joining
    included, because the rule walks a separated head's run under every load
    that draws it, and a probe that failed under that load is answered as the
    same failure rather than retried (`core-workspace.md`). The memo answers
    only for a load it still holds, so the handler first asks it for the
    node's **own** listing: on a miss it takes the ordinary
    `reloadOrForget()` instead. That is the project-root change — the tree's
    `onChange(of: projectRoot)` resets the memo and clears `separated`, and
    SwiftUI may run it *after* the new root node's `onAppear` load, which
    would otherwise leave the `separated` re-run reading an empty memo and
    drawing every top-level chain as a plain folder until the next bump.
    **Re-evaluation needs no new trigger.** Every expanded node reloads on a
    `treeRevision` bump, as before, through the memo, and a node also reloads
    when the shape its parent hands it changes (`TreeNodeShape` is `Equatable`,
    chain listing included) — the memo already holding that listing, since the
    parent's probe read it. **Both the `shape` and the `separated` handler use
    the two-argument `onChange`**, for the reason the reveal sites do: the
    deprecated one-argument form's action reads the previous update's `let`
    properties, so a grown chain listed its *old* tail (`a/b/c` drawing `c`
    as its one child) and a separation toggle re-ran the rule over the old
    `separated` set. `TreeChainReshapeTests` (app bundle) pins the `shape`
    half — `a/b` growing to `a/b/c` lists `c`'s files — and was seen red on
    the one-argument form. **Extend**: `a/b/c` gaining a lone `d` becomes
    `a/b/c/d`, same head, still expanded, showing `d`'s listing. **Shorten**: a
    file appearing in `b` makes the row `a/b`, still expanded, with `c` (now a
    plain collapsed row) and the file as children. **Drafts after a reshape**:
    the collapse and missing-directory checks ask `draftIsBelow` of the
    **contents directory** — asking about the head would drop a chain row's own
    rename draft, anchored inside the head, on collapse — and the reload check
    asks each returned row `TreeRow.leads(toDraftAnchor:renaming:)`, so a draft
    anchored on what became an inner segment is dropped — and so does the
    `separated` handler, whose re-run can fold the anchor into a chain just the
    same. `leads` answers reachability only, so a reshape can still hand a draft
    to a node that is **collapsed** — a shortened chain's old tail, now a plain
    collapsed row (or, collapsed itself, the shortened chain), or a folder under
    an unfolded chain's tail — where nothing draws it; a collapsed node therefore
    re-asserts the collapse rule (`dropDraftHiddenByCollapse()`, a draft below
    its contents directory is dropped) when it appears and when a reload finds
    it collapsed. The create-expands `onChange` compares against the contents
    directory. `TreeDraftDismissRule` is untouched.
    **Reveal through chains.** `TreeRevealRequest` gains two chain questions,
    asked of the node's segments in reveal spelling
    (`TreeNodeShape.revealURLs(underHead:)` → `TreeChain.revealURLs`): a chain
    node expands once per token when `expands(anyOf:)` finds any segment —
    head, inner or tail — among the ancestors, and withdraws the request when
    `isUnreachable(belowChain:listing:)` holds against the **tail's** listing. An
    inner segment has no listing to ask: the chain itself says that folder holds
    exactly the next segment, so a request whose step below an inner segment is
    anything else (another folder, or the target) is unreachable; below the tail
    it is the plain check.
    **The memo's place.** `ProjectTreeView` owns one `TreeListingMemo` for its
    lifetime, through a private `TreeListingSource` (an `ObservableObject` with
    nothing published, like `TreeDragSession`, because listing must invalidate
    nothing; the memo is made on the first ask, its listing function being
    `model.children(of:)`), and resets it on a project-root change with the
    draft. **Every load lists through it**: `loadChildren()` reads the contents
    directory under the current `treeRevision`, then asks the rule with
    `model.isSymbolicLink` and the memo as the listing function, so each
    directory is read at most once per revision whatever the probe order. Only
    the node's own contents read may beep (unless the directory is missing);
    probe failures are silent by the rule. Nothing lists outside a load. **A
    stated limit** follows from the memo: a folder first opened later in the
    same revision shows the listing its parent's probe read, not a fresh one, so
    a change that bumps no revision (an FSEvents overflow, a network volume)
    stays unseen there until the watcher's next event or the Refresh button —
    where before this a never-loaded folder read the disk on its first open.
    **A second stated limit is the probe's cost**: a load reads not only its
    contents directory but every non-link subfolder in it (the rule must see
    each one's listing to know whether it heads a chain), synchronously on the
    main thread, and the memo forgets on every revision while every expanded
    node reloads on each bump. An expanded folder with N subfolders therefore
    costs N + 1 directory reads per `treeRevision`, where before it cost one —
    noticeable on a very wide folder (`node_modules`, `Pods`) kept open while
    the watcher bumps the revision, or on a network volume — and the probe
    reads folders the user never opened, so a root above a TCC-protected
    folder (`~/Desktop`, `~/Documents`, `~/Downloads`) can raise the privacy
    prompt when the root loads rather than when that folder is expanded. No
    cap, no off-main-thread probe and no reuse of the previous revision's
    shapes exists today; each would change what the rule answers or when, a
    design decision deliberately not taken here.
    `TreeChainRowLayoutTests` (app bundle) builds a real project in which
    `a/b/c` holds two files, reveals one so the chain expands through the reveal
    path, and renders one window at scale 1 and one at 1.8: exactly four rows
    (root, chain, two files), the chain one scaled `rowHeight`, each file's glyph
    one scaled `treeIndentStep` right of the chain's, and one `hairline` guide on
    the chain chevron's centre with none for the inner segments.
    `TreeGitStatusColourTests.testAChainRowColoursEachSegmentByItsOwnStateAndItsSeparatorSecondary`
    samples each segment's role and the separator's `textSecondary` off one
    render; `TreeRevealRequestTests` pins the chain questions.
  - `ProjectTreeView.swift`, **sticky parent folders** — while the tree scrolls
    through an expanded folder, a copy of every expanded ancestor whose real row
    has scrolled above the viewport is pinned at the scroll view's top edge,
    directly under the pane header. Every decision — which rows pin, in what
    order, where each is drawn (push-out included), how tall the stack is, and
    where a scrolled-to row must land — is `TreeStickyRule`'s
    (`core-workspace.md`); the view measures, draws and hands the answers to
    `scrollTo`. A navigation aid only: nothing is persisted, and nothing about
    what the tree holds or what any operation addresses changes.
    **Measurement.** `DirectoryNodeView` carries `depth` (root `0`, child the
    parent's plus one, a chain row one node and one depth). While a node is
    expanded, a `GeometryReader` background on its `DisclosureGroup` reports one
    `TreeStickyFolderReport` through `TreeStickyFoldersKey` (an array, tree
    order): the whole node's frame in the named **content** space
    (`TreeStickySpace.content`, set on the padded content `VStack`), its depth
    and expansion, its `TreeNodeShape`, whether it is a test row (`isTestRow`,
    the node's own `TreeTestRule` answer), its folder row's scroll id
    (`TreeRevealRequest.rowID(head)`, on `FolderDisclosureRow` alone so the
    anchor maths sees one row's height) and the node's own `$isExpanded`.
    The report and its key are **internal** rather than private — the shape
    alone stays `fileprivate`, its type being private — for the app-bundle
    suites that read a node through them under `@testable import`, all hosting
    the tree through `TreeRevealHost` / `TreeRevealHostState` (internal, in
    `TreeStickyScrollRoundingTests.swift`: a wrapper republishing `reveal:` from
    an `ObservableObject` and collecting `TreeStickyFoldersKey`):
    `TreeStickyScrollRoundingTests` measures a folder's top,
    `TreeRevealOnScreenTests` waits on a folder's expansion,
    `TreeChainReshapeTests` measures a grown chain's node and
    `TreeTestRowReportTests` reads a node's test-row answer.
    **Collapsed nodes attach no reader** — they have no subtree to measure —
    and a frame in content space does not move while scrolling, so a scroll
    changes no report. The **scroll offset** is read by one `GeometryReader` on
    the padded content, its `minY` in the scroll view's named **viewport**
    space, and written through `onChange(of:initial:)` into
    `TreeStickyViewport` — an `ObservableObject` with a `@Published top` and a
    `@Published contentWidth` (the same reader's width, through a second
    `onChange`), each assigned only on inequality — held by `TreeStickyViewportSource`, an
    unpublished `@StateObject` (the `TreeListingSource` pattern), so the tree
    root that owns it is never invalidated by the offset. It is deliberately
    **not a preference**: measured, a preference changed by scrolling alone
    never reached an `onPreferenceChange` outside the scroll view (two calls,
    both `0`, through a reveal and four AppKit clip-view scrolls), while the
    reader itself saw every offset. The viewport height is the overlay's own
    `GeometryReader`. **Why scrolling re-renders no row and lists nothing**:
    the overlay, `TreeStickyStackView`, is the offset's **one observer**, so a
    scroll frame re-renders it alone; the reports it reads carry no listing and
    the rows it draws read the root's already-published `gitStatus` and
    `diagnostics` lookups with the urls the real row asks
    (`spokenGitStateURL`, `diagnosticMarkURL`, `gitStatusURLs`), so no file-system
    call is reachable from a scroll.
    **Shared drawing.** The folder row is split into `TreeFolderRowLayout`
    (chevron column, padding, the fixed `rowHeight` frame with its rename-draft
    ceiling) and `TreeFolderLabel` (glyph, diagnostic dot, name slot), whose
    name is `TreeFolderName` (plain or segmented; `segmentsText` is static over
    a `resolving` function). `FolderDisclosureRow` and the pinned copy
    (`TreeStickyRowView`) both draw through them, so "drawn exactly as the real
    row" holds by construction; the real row keeps its rename-field branch,
    passing the field into the label's name slot. The copy always draws
    `chevron-down`, because only expanded folders pin, and never a draft.
    **Overlay.** `.overlayPreferenceValue(TreeStickyFoldersKey.self, alignment:
    .top)` on the `ScrollView`, inside the existing `ScrollViewReader` — so on
    the viewport rather than in the content, directly under the header, which
    is outside the scroll view, whatever the offset. Its frame is **exactly
    `Stack.height`** tall and the **content's width** wide — measured by the
    content's own reader into `TreeStickyViewport.contentWidth`, which is the
    scroll view's width less a legacy scroller, so the stack neither paints over
    that scroller nor takes its drags (an overlay scroller, drawn over the
    content, is still covered while it shows, as it covers the rows) — then
    `.clipped()` **and** `.contentShape(Rectangle())`. Both are needed:
    `clipped()` limits drawing alone, so without the content shape a row being
    pushed out would still take the header's clicks above the frame. So a
    pushed-out row never draws over the header nor answers its clicks, and
    everything below the stack keeps receiving clicks, drags and menus. Rows are a `ZStack` offset by each `Stack.Row.top`,
    `zIndex`ed **outermost on top**, identified by the folder's scroll id so a
    copy keeps its hover state while the stack above it changes. **Indent by
    layout**: one `metrics.scaled(ChromeGeometry.treeIndentStep)`-wide spacer
    per depth level, each carrying `TreeIndentGuide` as its leading background,
    so every enclosing folder's guide runs through the copy as through the real
    row. Back to front: the `bgPanel` ground across the full width, the guides,
    the row over its own background —
    `TreeRowState.state(isSelected: false, isWindowKey: controlActiveState ==
    .key, isHovering: isHovering, isDropTarget: false)` through
    `TreeRowBackground.background(for:isTestRow:resolving:)` with the report's
    `isTestRow`, so a test folder's copy is washed as its row is — the tree's third pinned entry in
    chrome gating rule thirty-five (`core-theme.md`) — and a one-`hairline` rule
    `metrics.scaled(ChromeGeometry.hairlineWidth)` tall at the stack's bottom
    edge, `.allowsHitTesting(false)` so the last copy's bottom strip under it
    still takes that copy's tap. Every size goes through `metrics`, every colour through
    `theme.color(role)`.
    **Interaction.** A tap on the chevron slot (the scaled leading padding
    plus `TreeRowLayout.chevronGutter`, overlaid on the row) sets the reported
    binding to `false` — the very `@State` the real row toggles, so the node's
    collapse handler drops any draft below. A tap anywhere else hands the
    `Stack.Row` and the scroll id to the tree, which calls `withAnimation {
    proxy.scrollTo(id, anchor: UnitPoint(x: 0, y: row.scrollAnchorY)) }`,
    reading the anchor the rule put on the row — **never the row's index in
    the stack**, which is wrong once the cap has dropped outer rows. It changes
    no selection and opens nothing. **Reveal** scrolls to
    `TreeStickyRule.revealAnchorY` (the centre, which the rule proves clears
    the largest stack the cap allows). **The create draft is placed through
    the rule**: the draft row reports its content-space top through
    `TreeStickyDraftTopKey` (a `Double?`, read by `onPreferenceChange` inside
    the scroll view, where a layout-only change reaches it); `onDraftAppeared`
    sets `draftPlacementPending`; `TreeStickyDraftPlacement`, drawn behind the
    stack inside the same overlay closure where the reports and the viewport
    meet, reads the offset object **without observing it** and, when both the
    flag and a measured top are present, asks `TreeStickyRule.placement` once —
    the tree scrolls `"draft-row"` only on a non-nil anchor and clears the flag
    either way. Causal, with no timed delay; it replaces the anchor-less
    `scrollTo("draft-row")`, which could leave the draft under a folder that
    New File had just expanded and that then pinned over its own first child.
    **Stated limits.** The stack is capped at **a third** of the tree's height
    in whole rows (`TreeStickyRule.capFraction`), dropping the outermost rows
    first. A copy offers **click-to-scroll and chevron collapse only**: no
    context menu, no drag, no drop, no draft. The whole overlay is
    `.accessibilityHidden(true)` — the real rows carry everything a reader
    needs. The rule takes a folder's own row to be one `rowHeight` tall, so a
    folder whose **own rename draft** is open (its row grown to fit a wrapped
    field) is still measured as one row.
    **Tests.** `TreeStickyScrollListingTests` (app bundle) builds a project with
    `a/` of 60 files and `b/` of 5 over a counting `FileServicing` wrapper
    injected through `WorkspaceModel(fileService:)` — strictly stronger than a
    listing count, since it also catches link queries — at interface scale 1,
    dark, in a 240 × 300 window. It reveals `a/f00`, which expands `a` without
    scrolling: the centre anchor clamps to the top, so nothing pins at the
    landing and no animated scroll is left to race the ones below. Its first
    assertions check exactly that — the clip view still at `0`, and one capture
    finding no stack hairline. It then scrolls the hosting `NSScrollView`'s
    clip view to four offsets and pins that the file-service call count never
    moved while the clip view's origin did; one capture at the final offset
    finds the stack's hairline at the first slot's bottom edge and `a`'s pinned
    chevron inked in that slot at the depth-1 chevron column, proving SwiftUI
    observed the AppKit-driven scroll, which is how a wheel scroll arrives. `TreeStickyStackLayoutTests`
    (app bundle, `HostedRender` at 1.8, dark) renders a project whose `a/`
    holds 40 files, a modified `a/f03` and an error in `a/f07`, twice: `a`
    collapsed, then `a/f30` revealed. It pins `a`'s chevron and glyph in the
    first slot under the header at the depth-1 slots, the copy's name and dot
    colours equal to the real row's and to `statusYellow` / `statusRed`, the
    hairline at the stack's bottom edge and the root's guide through the copy.
    Its accessibility pin **reads the source** — `.accessibilityHidden(true)`
    inside `TreeStickyStackView`'s declaration, line comments stripped —
    because headless the hosting view's `accessibilityChildren()` is empty and a
    hit test answers the hosting view itself, so a probe of the tree would pass
    either way. `TreeStickyScrollRoundingTests` (app bundle, `HostedRender` at
    1, one window resized once) pins the scroll rounding
    `TreeStickyRule.slotTolerance` is sized against. Over sixty empty folders,
    `t/x` and sixty root files, a first reveal of `t/x` in a window taller than
    the document expands `t` without scrolling, so no animated scroll is left in
    flight; `t`'s report gives its node's frame (asserted two rows tall), and
    from it the window height is derived so that the centred target for `x` lies exactly
    half a point off the whole-point grid — asserted before scrolling, along
    with the target being inside the scrollable range, so the test fails rather
    than passing on a scroll that rounded nothing. A raw scroll back to `0` and
    a second reveal then go the real path, `scrollTo` at `revealAnchorY`, and
    the wait is a condition on the clip view's origin. It reads the window's
    backing scale at run time: at exactly 1 — the only scale measured, and the
    one this headless host reports — the settled offset is on the whole-point
    grid, exactly half a point short of the target and within the tolerance;
    at any other scale only
    `|settled − target| ≤ slotTolerance` is asserted.
  - `ProjectTreeDraftField.swift` — the AppKit-backed `NSTextField` behind
    the tree's inline naming, in five types: `TreeEditDraft` (what is being
    named), `TreeNameFieldView` (the row-shaped draft: icon column, field,
    red reason line; a rename's icon column is the optional `leading` text — a
    chain row's leading segments, built and coloured by the row — or nothing), `TreeDraftDismissRegion` (the invisible mouse-down
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
    row — except a chain rename's `leading` segments, which are drawn inside
    the draft and so are "inside" like the field. Because the
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
    rename draft, which has no icon column of that kind. A chain rename's
    `leading` text is not twinned: its reason line starts at zero, under the
    leading segments rather than under the field, with the row's full width to
    wrap in.
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
  - `ExternalChangeBar.swift` (macOS) — the external-change bar: a full-width
    row between the consent banner and the find bar in the editor zone, drawn for
    the selected tab exactly while `WorkspaceModel.isInExternalConflict` holds and
    gone the moment it does not — after an answer, an edit to the disk's text, or
    a pass that reloaded the tab. **When it shows is the model's rule, not this
    view's**, and the view holds no state, so the clean-but-stale case keeps it up
    exactly as it keeps the tab's marker. It quotes the file's display name, says
    that autosave will not write it and that the version given up is kept in
    Local History, and offers **Reload, Overwrite and Compare, equally
    weighted**: all three `.chromeSecondary`, because two of them give up one side
    and neither is the safer one to recommend. **No `.keyboardShortcut(.defaultAction)`**,
    for the consent bar's reason — a default button in the editor window would take
    every Return typed in the file below — and no dismiss: the conflict is a fact
    about the file and ends only through an answer or an edit. The three actions
    are `ContentView`'s `onExternalChangeReload` / `Overwrite` / `Compare`,
    wired in `PisakaApp` to `DiskSyncController.reloadFromBar`, to
    `save(id:externalChangeAnswer: .overwrite)` and to
    `DiskSyncController.compare` (`app-shell.md`), so Reload and Overwrite run
    the very capture-then-act helpers the modal question does. The geometry is
    the consent bar's — `bgPanel` ground padded 14 by 18, the 16-point
    `fileWarning` glyph in `statusYellow` (the tab's own mark, so bar and tab say
    the same thing) with the text 10 beyond it, the actions at least 16 away and 8
    apart, one scaled `hairline` rule along the bottom — every number through
    `metrics.scaled(_:)` and every colour a role, so it is in
    `ChromeThemeSourceGatingTests`' gated set. It is chrome, not a code-font
    surface, so it declares no zoom zone. `ExternalChangeBarLayoutTests` (app
    bundle, `HostedRender`) pins three buttons, none drawn as the default, at
    scale 1.0 and 1.8.
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
    own**: its host is not a stack but the `ChromeSplitView` in `editorSplit`, which
    draws a `hairline` divider at the column/editor boundary whatever the column
    does, so a trailing hairline here would be a second rule beside that one.
    The pane immediately left of it in the same split
    view, the gated `ProjectTreeView`, states that boundary the same way: by
    leaving it to the splitter. (The strip's bottom rule is the other case — its
    host *is* a `VStack`, which draws nothing between its children.)
    The column has **no top inset**: the first row sits flush under the title
    bar, the design's placement (a 4-point bottom inset stays past the last
    row). Its width is `TabColumnWidthRule`'s (`core-services.md`): the scaled
    minimum 180, default 220 and maximum 320, the maximum also held to a third
    of the window. `ContentView` reads the window's width **once**, from one
    `GeometryReader` in its body root's background, and hands it with the
    metrics (a zoom being the second trigger) to `TabColumnWidthProbe`, an
    `ObservableObject` held in a plain `@State` — not `@StateObject` — so its
    publishes never invalidate the root. The probe publishes the rule's
    `Bounds` and **assigns only when they differ**: above the threshold, where
    the maximum is the scaled 320 whatever the width, a resize publishes
    nothing, where the former `@State windowWidth` re-evaluated the whole window
    root on every point of a drag. The bounds reach the split through
    `TabColumnSplit`, the probe's only observer, a `ChromeSplitView` holding
    `TabListView` as its leading pane and the editor as its trailing one, the
    editor's scaled 320 as the trailing minimum. A change of bounds re-clamps
    the dragged width without discarding it, so a window narrowed and widened
    again gets the column's width back. The bounds are `nil` until the first
    read, and the split then uses an unbounded window's, so its first layout
    adopts the default width rather than a maximum computed from nothing (the
    split adopts the ideal once). `TabColumnWidthProbeTests` pins the publishing with
    no view: two widths above the threshold publish once, a narrow one
    publishes new bounds, the bounds are `nil` before the first update, and a
    zoom at an unchanged width publishes the zoomed bounds.
    A row is `ChromeGeometry.verticalTabRowHeight` (28) tall with `rowPaddingX`
    horizontal padding and a one-point `hairline` rule along its bottom edge
    (`hairlineWidth`, scaled), and states the strip's vocabulary turned through
    a right angle: the active row's **ground does not change** — the column's
    `bgPanel` shows through it as through every row — and it is marked by an
    `accent` bar `ChromeGeometry.accentIndicator` wide on its **leading** edge
    (the strip's underline, rotated) and by its label, `textPrimary` while
    every other row's is `textSecondary`; `hoverTint` under the pointer on an
    inactive row only, so hovering the active row never reads as a second
    selection. `TabColumnLayoutTests` (app bundle) renders the column over three
    files at scale 1.0 and 1.8 and reads off the one bitmap: the selected row's
    accent bar starts at y 0 and is 28 tall, one hairline run sits at each
    row's bottom, and the selected row's middle is the `bgPanel` ground. The icon is
    **`TabFileIcon`**, the second of the two views the orientations share (both
    live in `TabStripView.swift`): `FileGlyph`'s design glyph at 13 in
    `textSecondary` (the monochrome-icon decision in `core-theme.md`), with an
    untitled buffer asked about under its display name so the fallback is still
    `FileGlyph`'s own plain-text answer. The trailing slot is the first,
    **`TabStatusMark`**: the
    four-claimant precedence exists once, so the two orientations cannot drift
    into two rules. Both are one view rather than one rule restated twice, for
    the same reason and pinned by the same suite — `ChromeThemeSourceGatingTests`
    holds the icon rule to one spelling by set equality, having found it pasted
    into both. Every number goes through `metrics.scaled(_:)`.
    A row carries the same `tabGestures(file:files:actions:)` the strip's cell
    does — the middle click, the path tooltip and the context menu, all three
    described under `TabStripView.swift` below — so the two orientations cannot
    drift. `TabListView` takes a `TabActions` in place of the bare `onClose` it
    took before, and hands it to each row and to its `TabStatusMark`.
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
    the construct here and in `DockTabRow.swift`. The active cell's `bgEditor`
    fill passes `ignoresSafeAreaEdges: []`, so it does not climb through the
    transparent title bar above the strip to the window's top edge; the strip's
    `bgPanel` ground keeps the default and paints the title bar above the editor
    column on purpose, or the root's `bgCanvas` shows there and two-tones it
    against the sidebar. The reasoning, and rule forty-seven that pins both
    halves, are in `core-theme.md`. A cell carries `TabFileIcon`, a view of its
    own in this file and the **second** of the two things the vertical column
    shares with the strip: `FileGlyph`'s design glyph at 13 in `textSecondary`
    (see the monochrome-icon decision in `core-theme.md`), a `metrics.scaledFont(.callout)`
    label in `textPrimary` when active and `textSecondary` otherwise, one
    `accent` underline `ChromeGeometry.accentIndicator` tall on the active tab, a
    trailing `hairline` between tabs, and **one slot** — `TabStatusMark`, the
    other shared view, so the precedence below exists once rather than twice — holding
    the close mark, the external-change mark or the unsaved-changes dot, claimed in
    that order: the mark under the pointer, then the external-change mark, then the
    dot, then the close mark on the active tab. **The external-change mark** is the
    `fileWarning` design glyph at 12 in `statusYellow` — a shape and a colour the
    dot never takes — helped and labelled "Changed on disk", drawn while
    `model.isInExternalConflict(file.id)` (each orientation passes `isInConflict`
    to the cell or row). It outranks the dot because a tab in conflict is usually
    dirty too, and the dot alone would claim autosave is going to write it, which
    it will not; a clean tab stale against the disk carries it as well, since the
    conflict rule is derived from the texts and not from the dirty flag
    (`core-workspace.md`). The dot therefore
    **outranks** the mark on an active tab — unsaved work is a fact about the
    file that nothing else on the strip states, while the mark is one hover away
    — and the mark still shows on an active tab with nothing to report, so the
    tab most likely to be closed does not have to be hunted for. An untitled
    buffer has no url and is asked about under its display name, so the fallback
    glyph is still `FileGlyph`'s own rather than a second guess spelled here —
    that rule is `TabFileIcon`'s, spelled once and asked by both orientations.
    The close mark is the design's `x` glyph at 12, inside a plain button that
    names itself "Close", since the helper hides the glyph from accessibility.
    Every **chrome** measurement goes through `ChromeGeometry` and
    `metrics.scaled(_:)` — the strip's height, the bottom and trailing hairlines,
    the row padding, the accent indicator. The cell's own glyph sizes (icon 13,
    close mark 12, dot 7, the 14-point slot they share, the 6-point item spacing)
    stay local and scaled, as the sweep guide permits: they are this surface's
    numbers, not chrome measurements another surface could drift from
    (`core-theme.md`, step 3).

    **The tab gestures**, shared by both orientations and living here beside
    `TabStatusMark` and `TabFileIcon` so no new app file joins the chrome-theme
    and zoom gating inventories. **`TabActions`** is what a tab can ask of the app
    and replaces the bare `onClose` both orientations took: the project root (the
    menu's availability, the relative path and the tooltip are judged against it),
    one `close(command, anchor)` that `PisakaApp` routes into `closeTabs` — so
    every close, the mark, ⌥-click, the middle click and the five menu items
    alike, goes through the one funnel and a batch stops at the first Cancel —
    the tree reveal and Local History, both the app's, and the pasteboard and
    Finder actions, which need nothing the app holds and are stated here as
    defaults (`NSPasteboard.general`, `NSWorkspace.activateFileViewerSelecting`).
    `ContentView` gains two parameters — `tabActions`, passed to the strip or the
    column, and `treeReveal`, passed to `ProjectTreeView` as `reveal:`.
    `tabGestures(file:files:actions:)` attaches all three gestures in one place.
    **The context menu** (`tabContextMenu`) answers right click and ⌃-click alike,
    SwiftUI's `.contextMenu` doing both: three groups — the five close commands
    from `TabCloseCommand.allCases`, then Copy Path / Copy Relative Path / Reveal
    in Finder / Reveal in Project Tree, then Local History — grouped by `Section`s
    rather than separated by `Divider()`s, as every gated menu is, the menu drawing
    its own separators. Every item is `.disabled` from
    `TabCloseRule.MenuAvailability` and **never hidden**, and every action takes
    the tab the menu was opened on, not the active one. **The middle click** is
    `TabMiddleClickCatcher`, an `NSViewRepresentable` laid over each cell and row,
    because SwiftUI offers no other-button gesture; it is the one AppKit view in a
    tab's stack, draws nothing and has no `draw(_:)`. Its `TabMiddleClickView`'s
    `hitTest` claims the point **only while the event being dispatched** is an
    `otherMouseDown`/`otherMouseDragged`/`otherMouseUp` from button 2 — the
    decision is the static `claims(type:buttonNumber:)`, and the type is asked
    before `buttonNumber`, which raises on a non-mouse event — so every other
    event, left and right clicks, hover and tooltip tracking, falls through to the
    SwiftUI tab beneath and selection, the close mark and the context menu are
    untouched. The event comes from an **injectable source**, `currentEvent: () ->
    NSEvent?` defaulting to `NSApp.currentEvent`, so `TabMiddleClickTests` (app
    bundle) can hand `hitTest` a synthesized center-button `CGEvent` and assert it
    claims the point, while a left-button event and a nil source answer nil. **It
    closes on mouse-up**, inside its own bounds, as a button does: a press can be
    abandoned by dragging off the tab, and closing on the down would act before
    the user had finished the gesture. It never selects the tab first. **⌥-click**
    on the close mark: `TabStatusMark`'s button reads
    `NSEvent.modifierFlags.contains(.option)` and asks for `.closeOthers` with ⌥
    held, `.close` otherwise. **The tooltip** is `.help(DisplayPath.tooltip(...))`
    on the cell and the row — the relative path, an absolute one outside the root,
    "Untitled" — while the close mark's own `.help("Close")` keeps winning over its
    small area.
  - `BreadcrumbBarView.swift` — the breadcrumb bar above the editor: the open
    file's path starting with the opened project root's name, the way the project
    tree does (`project › backend › src › dialogs.service.ts`), or an abbreviated absolute path when
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
    **own** bottom hairline, which is why its host's `Divider()` is gone. The
    separators are the design's `chevron-right` glyph at 10 points, scaled with
    the interface, set inline in the one `Text` run with a space either side:
    `DesignGlyphDrawing.inlineImage(_:pointSize:)` bakes the size into a template
    image (a frame cannot reach inside a `Text`), and the run's `textSecondary`
    foreground tints it, so truncation still treats the path as one string.
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
