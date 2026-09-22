# Chrome theme, part three: the window's ground, the sidebar's host, the bottom dock and the bottom bar

## Overview

Move the surfaces *around* the editor pane onto the chrome roles: the window's own
ground and its title bar, the project tree's host and a new sidebar header, the
bottom dock's container and both draggable dividers, and the always-visible bottom
bar with its toggles and its three widgets. No palette value changes; `bgCanvas`
and `statusGreen` each gain their first consumer. Five files join
`ChromeThemeSourceGatingTests.gatedFiles`, one of them new; the suite gains two
rules and `ChromeGeometry` two tokens.

## Context

Files involved:

- Modify: `Sources/PisakaCore/ChromeGeometry.swift` — two tokens.
- Create: `Sources/Pisaka/MainWindowChrome.swift` — the title-bar marker.
- Modify: `Sources/Pisaka/PisakaApp.swift` — one existing line, chained (see below).
- Modify: `Sources/Pisaka/ContentView.swift` — window ground, dock container, both
  dividers, bottom bar, empty states.
- Modify: `Sources/Pisaka/ProjectTreeView.swift` — the tree's host and its header.
- Modify: `Sources/Pisaka/ProjectSwitcherView.swift`, `BranchSwitcherView.swift`,
  `PullRequestIndicatorView.swift`.
- Tests: `Tests/PisakaCoreTests/ChromeThemeTests.swift`,
  `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`; create
  `Tests/PisakaAppTests/MainWindowChromeTests.swift`.
- Docs: `docs/architecture/core-theme.md`, `docs/architecture/app-window.md`,
  `docs/architecture/app-shell.md`, `CLAUDE.md`.

Related patterns:

- Part two's breadcrumb and consent strip: a surface draws its own `hairline`
  rectangle rather than a `Divider()`, which would be drawn in the system's
  separator value.
- Part one's `TreeRowBackground.color(for:resolving:)`: the theme travels as a
  role-to-colour *function* so no view file names `ChromeTheme` (gating rule five).
- `MainWindowFrameAutosave.swift`: a non-drawing, hit-test-transparent
  `NSViewRepresentable` marker in the scene's content that reaches the hosting
  window.

Dependencies: none.

## Measured facts that shape the plan

- `Sources/Pisaka/PisakaApp.swift` is at **exactly** its `file_length` ceiling
  (1893 non-comment, non-blank lines; `.swiftlint.yml` warning = error = 1893).
  Any added non-comment line fails `swiftlint --strict`.
- `ChromeThemeSourceGatingTests` currently declares **eight** rules and gates
  **eleven** files; its own count is cross-checked against `core-theme.md`'s
  canonical list and `CLAUDE.md`'s invariant sentence, so adding a rule is a
  three-place edit enforced by the suite.
- The platform-colour sites to convert, exhaustively: `ContentView.swift`
  (2 × `separatorColor`, 3 × `.secondary` empty states, the completion toggle's
  `accentColor`/`.secondary`, the panel toggle's
  `accentColor`/`accentColor`/`.primary`), `BranchSwitcherView.swift` (9),
  `ProjectSwitcherView.swift` (6), `PullRequestIndicatorView.swift` (4).
  `ProjectTreeView.swift` already names no platform colour.

## Decisions made where the ticket is silent

The ticket is self-contained and forbids consulting any external source; the
following were decided from the repository's own conventions and are recorded here
as required.

1. **One rule at the editor/dock boundary.** Requirements 10 and 11 read together
   would put two hairlines five points apart. The divider *is* the dock's top edge,
   so the divider carries the rule (a one-point `hairline` along its top, on a
   `bgPanel` ground) and the panel slot below it draws `bgPanel` with no second
   rule of its own.
2. **The preview divider's rule sits on its leading edge** — the editor pane's own
   boundary — matching the dock divider, whose rule sits on the edge nearer the
   editor.
3. **The widgets' caret** is a trailing `chevron.down` drawn at the same `.callout`
   style as the name, in `textSecondary`. Neither switcher draws one today;
   requirement 8 names one, so it is added.
4. **The pull-request indicator is three elements**: a leading
   `arrow.triangle.merge` glyph (the same glyph the Pull Requests toggle uses, and
   now at the opposite end of the bar so the old adjacency argument does not
   apply), `#N`, and a trailing checks mark. The mark's four glyphs are today's
   three plus `circle` for *no checks* — the neutral member of the `*.circle.fill`
   family already used for failure and success — coloured `statusGreen` /
   `statusRed` / `statusYellow` / `textSecondary`.
5. **The two switcher popovers are converted too.** The ticket puts popovers in
   parts four to six, but gating rule one is per *file*, and requirement 15 says
   the whole file obeys. The popovers' colours are therefore mapped mechanically
   (`.secondary` → `textSecondary`, `.primary` → `textPrimary`,
   `Color.accentColor` → `accent`, `.red` → `statusRed`); their layout, fonts and
   behaviour are untouched. Reported here as the scope consequence it is, not as an
   exemption.
6. **The window marker rides in a file of its own**, attached by chaining onto the
   existing `.background(MainWindowFrameAutosave())` line rather than adding a
   line, because `PisakaApp.swift` sits exactly at its `file_length` ceiling — the
   precedent that file already documents for
   `.environmentObject(databaseViewers).environmentObject(pullRequests)`. The frame
   persistence's contract, its file and its own gating suite are untouched.
7. **The three widgets drop their own horizontal and vertical padding** so the
   bar's stated 14-point gaps and 28-point height are the measurements actually
   drawn; each keeps `.contentShape(Rectangle())` so its whole label stays the
   click target.
8. **Two new gating rules** (nine: the window chrome is configured in one file;
   ten: every bottom-bar toggle is identifiable without sight), taking the suite to
   **ten** rules and **sixteen** gated files.
9. **Twelve surfaces swept** after this part: part one's three, part two's four,
   and part three's five — the window's ground and title bar, the sidebar's host
   and header, the bottom dock's container and its two dividers, the bottom bar and
   its toggles, and the bar's three widgets.
10. **The open-a-folder placeholder pane draws `bgPanel`, not `bgCanvas` — a stated
    divergence from requirement 1.** That requirement lists the pane among the
    places the window ground shows through; it is in fact the sidebar's own
    surface, drawn by `ProjectTreeView` inside the sidebar's slot and bounded by
    the same split as the tree it replaces. A pane that changed ground depending on
    whether a folder was open would read as a hole in the sidebar rather than as
    the window behind it. The pane therefore draws `bgPanel` like the tree it
    stands in for, and the ticket sentence naming it as canvas is superseded.
    `bgCanvas` still has its consumer: the window root paints it, and it shows
    through at the no-file-open placeholder and the root's own empty states.
    Recorded here rather than left silent, because a quiet divergence from an
    explicit requirement reads as a miss.
11. **The two switcher popovers keep their `Divider()` calls.** Decision 5 converts
    the popovers' *colours* because the gating rules are per file; it deliberately
    does not convert their rules. A `Divider()` names no colour, so gating rule one
    cannot see it — and the fix is not available yet: the popover's own ground is
    the platform's material, which parts four to six sweep, and a `hairline` rule
    painted on a platform material ground would be the mismatch rather than the
    cure. The rules therefore stay platform-drawn until the ground under them is
    swept, and the deferral is written into `core-theme.md`'s part-three record
    (below) as inherited work for the popovers' part, so it is found there rather
    than rediscovered. No test is asked for this; a rule that cannot yet be stated
    is not one to pin.

## Development Approach

- **Testing approach**: Regular (code first, then tests), matching the sweep
  guide's step order — restyle, add the file to `gatedFiles`, run the gates.
- Complete each task fully before moving to the next.
- A file joins `ChromeThemeSourceGatingTests.gatedFiles` in the same task that
  restyles it.
- A task that adds a gating rule updates `core-theme.md`'s canonical list and
  `CLAUDE.md`'s count sentence in that same task — the suite fails otherwise.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**
- Builds go to `~/Library/Developer/Xcode/DerivedData/pisaka-chrome-part-three`,
  never inside the repository.

## Implementation Steps

### Task 1: The two geometry tokens

**Files:**

- Modify: `Sources/PisakaCore/ChromeGeometry.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeTests.swift`

- [ ] add `sidebarHeaderHeight: Double = 32` — the project sidebar's header strip.
- [ ] add `barPaddingX: Double = 12` — the horizontal inset of a header or bar,
      documented as one measurement drawn on the sidebar header and the bottom bar,
      and explicitly *not* `rowPaddingX` (8), which is a row's padding inside its
      highlight.
- [ ] update the file's doc comment so the token inventory it recites stays true.
- [ ] extend `testGeometryTokensCarryTheirTableValues` with both values.
- [ ] extend `testGeometryDeclaresExactlyTheseTokensAndNoFontSize`'s set-equality
      list with both names.
- [ ] update `core-theme.md`'s `ChromeGeometry.swift` entry, which recites the
      token inventory in prose.
- [ ] run `swift test` — must pass before task 2.

### Task 2: The window's ground and its title bar

**Files:**

- Create: `Sources/Pisaka/MainWindowChrome.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `Sources/Pisaka/ContentView.swift` (the ground only)
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Create: `Tests/PisakaAppTests/MainWindowChromeTests.swift`
- Modify: `docs/architecture/core-theme.md`, `CLAUDE.md`

- [ ] write `MainWindowChrome.swift` under `#if os(macOS)`: a non-drawing,
      hit-test-transparent `NSViewRepresentable` marker in
      `MainWindowFrameAutosave`'s mould, whose view reaches the hosting window on
      `viewDidMoveToWindow` (skipping sheets) and applies the chrome through one
      `static func apply(to:)` — `titlebarAppearsTransparent = true` and
      `backgroundColor = ChromePalette.nsColor(.bgPanel)`, the *dynamic* colour, so
      no appearance observer and no cached value is needed. The title text and the
      window buttons are left alone. Document why the ground is `bgPanel` here
      while the content root paints `bgCanvas`: the title bar is a panel strip, and
      it must read as one surface with the strips below it.
- [ ] attach it in the scene by chaining:
      `.background(MainWindowFrameAutosave()).background(MainWindowChrome())`, with
      a comment naming the `file_length` ceiling as the reason for the chain, as
      the neighbouring `.environmentObject` line already does.
- [ ] in `ContentView`, add `@Environment(\.colorScheme) private var colorScheme`
      and a `private func chromeColor(_ role: ChromeColorRole) -> Color` that
      resolves through `settings.chromeTheme(systemPrefersDark: colorScheme ==
      .dark)` — a role-to-colour function, so the file never names `ChromeTheme`
      and gating rule five is untouched. Document that this is the seam's first
      consumer and why a root cannot read the environment it writes.
- [ ] paint the body's root `VStack` with `chromeColor(.bgCanvas)`.
- [ ] add `"MainWindowChrome.swift"` and keep `ContentView.swift` **out** of
      `gatedFiles` for now (it still carries platform colours until task 4).
- [ ] add gating **rule nine**: the set of files under `Sources/` naming
      `titlebarAppearsTransparent` equals `["MainWindowChrome.swift"]` — a second
      window-chrome setter would compete with this one and nothing in the compiler
      can see it. Add its `// MARK: - Rule nine:` marker, its doc-comment paragraph
      in the suite's numbered list, its item in `core-theme.md`'s canonical list,
      and bump `CLAUDE.md`'s "its eight rules" to nine.
- [ ] write `MainWindowChromeTests.swift` in the app bundle: build a real
      `NSWindow`, call `MainWindowChrome.apply(to:)`, and assert the transparent
      title bar and that the background colour resolves to
      `ChromePalette.nsColor(.bgPanel, in:)`'s value in both appearances; assert
      the marker view is hit-test transparent and not an accessibility element.
- [ ] run `swift test` and the app-layer bundle — must pass before task 3.

### Task 3: The sidebar — the tree's host and its header

**Files:**

- Modify: `Sources/Pisaka/ProjectTreeView.swift`
- Modify: `docs/architecture/app-window.md`

- [ ] paint both branches of the body — the tree and the open-a-folder placeholder
      pane — with `theme.color(.bgPanel)` from the environment the file already
      reads (decision 10).
- [ ] rebuild `header`: a `.frame(height:)` of `ChromeGeometry.sidebarHeaderHeight`
      and a `.padding(.horizontal,)` of `ChromeGeometry.barPaddingX`, both scaled
      at the use site; a leading project label — the open folder's name uppercased,
      `textSecondary`, `metrics.scaledFont(.subheadline, weight: .semibold)`,
      `.tracking(metrics.scaled(0.5))`; a `Spacer()`; the Refresh button at the
      trailing end, its icon `textSecondary` at `.body`, its tooltip unchanged.
- [ ] replace the header's `Divider()` with a one-point `hairline` rectangle drawn
      by the header itself along its bottom edge, so the rule agrees with the
      hairlines beside it in either appearance (part two's precedent).
- [ ] record in the file's own comment that the Refresh button is a deliberate
      deviation: the design draws the label alone, and a working control is not
      removed by a restyle; and that the placeholder pane draws the sidebar's
      ground (decision 10).
- [ ] `ProjectTreeView.swift` is already gated, so the existing rules cover it; no
      `gatedFiles` change.
- [ ] update the `ProjectTreeView.swift` entry in `app-window.md` with the host's
      ground and the header's contract.
- [ ] run `swift test` and the app-layer bundle — must pass before task 4.

### Task 4: The window root — the dock, both dividers and the bottom bar

**Files:**

- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md`, `CLAUDE.md`

- [ ] `panelDivider(available:)`: keep the 5-point drag target, the `contentShape`,
      the hover/drag cursor sync and the whole drag gesture verbatim; fill
      `bgPanel` and overlay a one-point `hairline` rectangle along its **top** edge
      (decision 1).
- [ ] `markdownPreviewDivider(available:)`: the same, keeping the 5-point width,
      with the rule along its **leading** edge (decision 2).
- [ ] paint the dock's panel slot `bgPanel`, with no second rule of its own.
- [ ] the three empty-state sentences the root draws — "No problems", the usages
      invitation and "No file open" — read `textSecondary`.
- [ ] `bottomBarButton(title:systemImage:panel:)` becomes an icon-only square:
      `bottomBarToggleSide` on a side, `bottomBarToggleRadius` corner radius, its
      icon at `.body`; active draws an `accentTintStrong` ground with an `accent`
      icon, inactive no ground and a `textSecondary` icon; each carries
      `.help(title)` and `.accessibilityLabel(title)`, with a comment recording
      that the visible labels are gone and why both are now mandatory.
- [ ] `completionToggleButton` takes the same idiom — same square, same two states
      keyed on `settings.completionEnabled` — and keeps its existing `.help`,
      `.accessibilityLabel` and `.accessibilityValue`.
- [ ] reverse the bar: a leading group of the three widgets at 14-point gaps, a
      `Spacer()`, then a trailing group of the six panel toggles followed by the
      completion toggle at 2-point gaps. All gaps are bare local numbers scaled
      once (gating rule seven forbids deriving them from a token).
- [ ] give the bar `bottomBarHeight`, a `barPaddingX` horizontal inset, a `bgPanel`
      ground and a one-point `hairline` along its **top** edge; delete the
      `Divider()` the body used to place above it, recording the deviation (the
      design draws no rule there; the app keeps one because with the dock closed
      the editor and panel grounds are one value apart in the dark theme).
- [ ] add `"ContentView.swift"` to `gatedFiles`.
- [ ] add gating **rule ten**: inside `ContentView.swift`, the brace-matched bodies
      of `bottomBarButton(` and `completionToggleButton` each spell `.help(` and
      `.accessibilityLabel(`, and `bottomBarButton(` occurs exactly seven times
      (one declaration, six calls). Use the suite's existing brace-matching helper
      idiom. Add its `// MARK:` marker, its doc-comment paragraph, its item in
      `core-theme.md`'s canonical list, and bump `CLAUDE.md`'s count to ten.
- [ ] run `swift test` and the app-layer bundle — must pass before task 5.

### Task 5: The bar's three widgets

**Files:**

- Modify: `Sources/Pisaka/ProjectSwitcherView.swift`,
  `Sources/Pisaka/BranchSwitcherView.swift`,
  `Sources/Pisaka/PullRequestIndicatorView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/app-window.md`

- [ ] each widget adds `@Environment(\.chromeTheme) private var theme` beside its
      existing `\.interfaceMetrics`.
- [ ] project switcher: the name `textPrimary` at `.callout`, its folder icon and
      its new trailing `chevron.down` `textSecondary`; drop its own paddings, keep
      `.contentShape(Rectangle())`.
- [ ] branch switcher: the branch name, its icon and its new caret all
      `textSecondary` at `.callout`; the failure line `statusRed`; same padding
      treatment.
- [ ] pull-request indicator: leading `arrow.triangle.merge` and `#N` in
      `textSecondary`; the checks mark from the four-case table of decision 4,
      coloured `statusGreen` / `statusRed` / `statusYellow` / `textSecondary`; the
      tooltip, the accessibility label and value, and the absent-rather-than-empty
      rule unchanged.
- [ ] convert the two popovers' colours by the mechanical mapping of decision 5,
      leaving layout, fonts and behaviour alone — including their `Divider()`
      calls, which stay for the reason decision 11 states; record that reason in
      each file's comment.
- [ ] add all three file names to `gatedFiles`.
- [ ] update the three widgets' entries in `app-window.md` with the roles they
      spend.
- [ ] run `swift test` and the app-layer bundle — must pass before task 6.

### Task 6: Documentation

**Files:**

- Modify: `docs/architecture/core-theme.md`, `docs/architecture/app-window.md`,
  `docs/architecture/app-shell.md`, `CLAUDE.md`

- [ ] `core-theme.md`: a **Part three** record in parts one and two's shape — each
      file, the roles it spent, and which entries are *regressions* fixed rather
      than new surfaces (the two dividers, which were filling five points with the
      platform's separator colour, and the window root's empty states, which were
      platform-coloured outside any named surface).
- [ ] `core-theme.md`: in the same part-three record, name the **inherited work**
      this part knowingly leaves behind for the popovers' part — the two switcher
      popovers' `Divider()` rules and the platform material ground under them
      (decision 11) — so the later part finds it rather than rediscovers it; and
      state the placeholder pane's ground with its reason (decision 10).
- [ ] `core-theme.md`: shrink "What is still waiting" to the six dock panels, the
      dialogs and sheets, the separate windows, the Preferences surfaces and the
      terminal; record the dock's own tab row and the caret readout as deliberately
      deferred, and say that `dockTabRowHeight` stays unused until the tab row gets
      its design decision.
- [ ] `core-theme.md`: correct the unused-role list — `bgCanvas` and `statusGreen`
      are spent here, leaving **six** (`bgPopover`, `currentLine`, `bracketMatch`,
      `diffAddedBackground`, `diffRemovedBackground`, `conflictBackground`), each
      still named with the surface it waits for. Verify the arithmetic against the
      `ChromeColorRole.swift` doc comment and correct that comment's own unused
      list to match.
- [ ] `app-shell.md`: a full entry for `MainWindowChrome.swift` — what it sets, why
      the ground is `bgPanel`, why the colour is dynamic, and that it is a sibling
      of the frame marker rather than a change to it.
- [ ] `app-window.md`: update the `ContentView.swift` entry for the bar's reversed
      order, the toggles' new shape, the dock container and both dividers.
- [ ] `CLAUDE.md`: the new index line for `MainWindowChrome.swift` under
      `app-shell.md`; the chrome invariant's surface count (seven → twelve, each
      named), its gated-file count (eleven → sixteen) and its rule count (already
      moved to ten in tasks 2 and 4 — verify the sentence is coherent as a whole).
- [ ] run `swift test` — the suite's cross-file count rules must agree with both
      documents.

### Task 7: Verify acceptance criteria

- [ ] `swift test` green.
- [ ] app-layer bundle green on a macOS destination, with derived data under
      `~/Library/Developer/Xcode/DerivedData/pisaka-chrome-part-three`.
- [ ] `swiftlint --strict` clean from the repository root.
- [ ] confirm by search that no file among the swept set names a platform semantic
      colour or a hex literal (the gating suite's own rules, re-read as an
      acceptance check).
- [ ] confirm `bgCanvas` and `statusGreen` each have a call site.

## Post-Completion (manual verification)

- Flip the Theme preference between Light, Dark and System and confirm every
  surface this part touched repaints without a relaunch, the title bar included.
- Drag the dock divider and the preview divider: both still resize, both show the
  resize cursor for hover and for drag, and a click that never becomes a drag
  leaves the panel where it was.
- Tab through the bottom bar with VoiceOver and confirm each icon-only toggle
  announces its panel.
