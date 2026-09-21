# Chrome theme, part 2: the gutter regression and the editor pane's chrome

## Overview

Fix the regression the first part shipped — the line-number ruler fills the
rectangle it is handed instead of its own width, painting the whole editor pane
in `bgEditor` and hiding the code and the minimap — and move the rest of the
editor pane onto the colour roles: the vertical tab column, the breadcrumb, the
minimap's own chrome and the language-server consent strip. No role is added and
no geometry token is added; the sidebar, the bottom dock and bar, the dock
panels, the dialogs and the terminal stay for later parts.

## Context

**Files involved**

App (modified):
- `Sources/Pisaka/LineNumberRulerView.swift` — the background fill becomes a
  pure seam; nothing else about the gutter changes.
- `Sources/Pisaka/TabListView.swift` / `TabRowView.swift` — the vertical column
  and its row, onto the roles.
- `Sources/Pisaka/TabStripView.swift` — unchanged visually; gains the shared
  close-mark/dirty-dot slot the two orientations now both draw.
- `Sources/Pisaka/ContentView.swift` — hosts the extracted breadcrumb, loses the
  `Divider()` under it (the strip draws its own rule, as the tab strip does).
- `Sources/Pisaka/MinimapView.swift` — background and viewport indicator only.
- `Sources/Pisaka/LSPConsentBanner.swift` — the strip, its two text weights and
  its confirming action.

App (new):
- `Sources/Pisaka/BreadcrumbBarView.swift` — the path strip, lifted out of
  `ContentView.swift` (it cannot be restyled in place: a gated file may name no
  system semantic colour, and `ContentView` is full of them for surfaces this
  part does not touch).

Tests:
- `Tests/PisakaAppTests/LineNumberRulerBackgroundTests.swift` (new) — the seam.
- `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift` — `gatedFiles`
  grows by exactly five files; the five rules and three exemptions untouched.

Docs: `docs/architecture/core-theme.md` (the surfaces added to the sweep),
`app-window.md` (the tab column, the breadcrumb), `app-editor-overlays.md` (the
gutter's corrected fill, the minimap's chrome), `core-provisioning.md` (the
consent strip's chrome), `CLAUDE.md` (one index line for the new file).

**Related patterns**

- `TabStripView.swift` — the vocabulary the vertical column must restate: panel
  ground, hairline against the editor, active cell filled `bgEditor` with an
  `accentIndicator` accent bar, `textPrimary`/`textSecondary` labels, monochrome
  `FileIcon` symbol, the three-claimant mark slot.
- `LineNumberRulerView.numberAttributes` — the precedent for this part's seam:
  drawing cannot be asserted, what is about to be drawn can.
- `ChromePalette.nsColor(_:)` for AppKit surfaces (ruler, minimap),
  `@Environment(\.chromeTheme)` + `theme.color(_:)` for SwiftUI ones.
- The sweep guide's six steps in `core-theme.md`, including step 5 — a file
  joins `gatedFiles` as part of restyling it, not afterwards.

**Dependencies** — none.

**Decisions taken here** (a tech-lead call each; say so in review if any is wrong)

- **The seam is a static, pure function.**
  `LineNumberRulerView.backgroundRect(in:ruleThickness:)` clamps the handed
  rectangle's trailing edge to the gutter's width
  (`maxX = min(rect.maxX, ruleThickness)`, width never negative) and keeps its y
  and height, so a partial dirty rectangle starting inside the gutter is still
  correct. `drawHashMarksAndLabels` fills what it answers; the hairline beside it
  is already right and is left alone.
- **The breadcrumb moves to its own file** for the gating reason above, and is
  renamed `BreadcrumbBarView` — what the docs have always called it.
- **The breadcrumb keeps `.equatable()`** (it exists to keep a symlink-resolving
  path walk off the typing path) and stays live under a theme change by splitting
  in two inside its new file: a thin outer view reading
  `@Environment(\.chromeTheme)` and handing the inner, equatable view the
  resolved `ChromeAppearance` as a stored property beside `metrics` — the same
  argument the stored metrics already make. The inner view reads its colours from
  the environment; neither names the theme's *type*, so gating rule five is
  untouched.
- **The segments are one `Text`**, composed by `+` so the final segment can be
  `textPrimary` while the rest and the separators are `textSecondary`; an
  `HStack` of labels would lose the middle truncation that keeps the file name
  visible in a narrow window.
- **The close-mark/dirty-dot slot becomes one shared view**, `TabStatusMark`,
  living in `TabStripView.swift` beside the doc comment that already states the
  rule, and used by both orientations — so the two cannot drift into two rules.
  The strip's rendering is byte-identical.
- **The consent strip's declining action** (and its two siblings) is drawn as a
  plain label in `textSecondary`; only the confirming action takes the accent
  with `onAccent` text and `cornerRadiusMax`. A system-drawn button beside an
  accent one is the mixed look this part is removing.
- **The minimap's viewport indicator** is filled `accentTint` and stroked
  `accentTintStrong`. If the stroke reads too faint when the app is looked at,
  the fallback is `accent` at full strength — still a declared role, no new one.
- **The brand-name sweep is the repository's whole set, not this part's
  rewrites** — see Task 6.
- `currentLine` and `bracketMatch` stay unused, as the ticket says.

## Development Approach

- **Testing approach**: TDD for the one pure rule in this part (the gutter's
  background rectangle — write the seam test first, watch it fail against a
  `rect`-returning stub); regular for the four SwiftUI/AppKit restyles, which are
  covered by the gating suite rather than by assertions about pixels.
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**
- Core gate: `swift test`. App gate: `xcodebuild -project Pisaka.xcodeproj
  -scheme Pisaka -destination 'platform=macOS' test`. Style gate:
  `swiftlint --strict` from the repository root.
- Builds and test runs write nothing into the repository tree: pass
  `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-chrome-theme-2`.
- No product or brand names anywhere — code, comments, docs or commit messages.

## Implementation Steps

### Task 1: The gutter regression — the fill seam

**Files:**
- Modify: `Sources/Pisaka/LineNumberRulerView.swift`
- Create: `Tests/PisakaAppTests/LineNumberRulerBackgroundTests.swift`

- [x] Write the failing test first: hand `backgroundRect(in:ruleThickness:)` a
      742-wide rectangle against a 59-wide gutter and assert the answer is 59
      wide; assert a narrower dirty rectangle is returned unchanged; assert a
      dirty rectangle starting inside the gutter keeps its origin and stops at
      the gutter's trailing edge; assert a dirty rectangle wholly to the right of
      the gutter yields zero width rather than a negative one; assert y and
      height are carried through untouched.
- [x] Add the seam as a `static func` on `LineNumberRulerView`, `internal` for
      the reason `numberAttributes` is, with a doc comment naming the regression
      it prevents: an `NSRulerView` is handed the rectangle *it* was asked to
      redraw, which is not its bounds.
- [x] Call it from `drawHashMarksAndLabels` in place of `rect.fill()`; leave the
      hairline, the attributes and every other drawing line as they are.
- [x] run `swift test` and the app-layer bundle — must pass before Task 2

### Task 2: The vertical tab column

**Files:**
- Modify: `Sources/Pisaka/TabRowView.swift`, `Sources/Pisaka/TabListView.swift`,
  `Sources/Pisaka/TabStripView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [x] Extract the strip cell's three-claimant slot into a shared `TabStatusMark`
      view in `TabStripView.swift` (hover → close mark, else dirty → dot, else
      active → close mark), carrying the existing doc comment, and have the strip
      cell use it so its rendering is unchanged.
- [x] `TabListView`: `bgPanel` ground, a trailing hairline against the editor
      drawn by the column itself (`hairlineWidth`, scaled), rows at no padding of
      their own beyond the existing vertical inset.
- [x] `TabRowView`: `verticalTabRowHeight` tall, `rowPaddingX` horizontal; active
      row filled `bgEditor` with an `accentIndicator`-wide `accent` bar on the
      leading edge; label `textPrimary` when active and `textSecondary`
      otherwise; an inactive row hovered takes `hoverTint`; the monochrome
      `FileIcon` symbol in `textSecondary` (the strip's `iconSymbolName` rule,
      including the unsaved-buffer fallback); the shared `TabStatusMark` in the
      trailing slot. Every number through `metrics.scaled(_:)`.
- [x] Add `TabListView.swift` and `TabRowView.swift` to
      `ChromeThemeSourceGatingTests.gatedFiles`, with a comment naming this part.
- [x] run `swift test` and the app-layer bundle — must pass before Task 3

### Task 3: The breadcrumb

**Files:**
- Create: `Sources/Pisaka/BreadcrumbBarView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [x] Move `PathBarView` out of `ContentView.swift` into the new file as
      `BreadcrumbBarView`, carrying its doc comment — minus the brand reference
      — and adding why it now lives in a file of its own.
- [x] Split it into the thin outer view (reads `@Environment(\.chromeTheme)`,
      passes `theme.appearance` down) and the inner `.equatable()` view storing
      `fileURL`, `projectRoot`, `metrics` and `appearance`, with a hand-written
      `==` over the four and a comment explaining that the appearance travels for
      the same reason the metrics do.
- [x] Draw it: `breadcrumbHeight` tall, `bgPanel`, a bottom hairline of its own,
      segments and `›` separators in `textSecondary`, the last segment in
      `textPrimary`, composed as one `Text` so middle truncation survives;
      `rowPaddingX` horizontal padding; `metrics.scaledFont(.subheadline)`.
- [x] `ContentView`: host `BreadcrumbBarView` and delete the `Divider()` under
      it, as the horizontal tab strip's host already does.
- [x] Add `BreadcrumbBarView.swift` to `gatedFiles`.
- [x] run `swift test` and the app-layer bundle — must pass before Task 4

### Task 4: The minimap's own chrome

**Files:**
- Modify: `Sources/Pisaka/MinimapView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [x] Background: `ChromePalette.nsColor(.bgEditor)` filling `bounds`, replacing
      the half-opacity system text background.
- [x] Viewport indicator: fill `accentTint`, stroke `accentTintStrong`, both
      dynamic, no cached colour and no appearance observer — the bridge's rule.
- [x] Leave `drawTokens` and `MinimapTokenizer` untouched, and say in the file's
      doc comment that the runs are the *code's* colours and stay with
      `SyntaxTheme` — the same boundary the syntax highlighting sits on.
- [x] Add `MinimapView.swift` to `gatedFiles`.
- [x] run `swift test` and the app-layer bundle — must pass before Task 5

### Task 5: The consent banner

**Files:**
- Modify: `Sources/Pisaka/LSPConsentBanner.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [ ] The strip: `bgPanel` background on all three rows, and its bottom rule
      drawn as a `hairline` rectangle instead of a `Divider()`.
- [ ] Text: the question line `textPrimary`, the explanatory caption (and the
      runtime-network note, which is the same kind of fact) `textSecondary`, the
      leading symbol `accent` in place of `.tint`.
- [ ] Actions: one private helper for the confirming button — `accent` fill,
      `onAccent` label, `cornerRadiusMax`, padding from `rowPaddingX` — used by
      all three rows' accepting action; the declining action a plain
      `textSecondary` label button. No keyboard shortcut is added: the existing
      doc comment explains why, and it still holds.
- [ ] Add `LSPConsentBanner.swift` to `gatedFiles`.
- [ ] run `swift test` and the app-layer bundle — must pass before Task 6

### Task 6: Documentation, and the brand-name sweep

The no-brand-names convention is **absolute and repository-wide** — it is not
scoped to the text a given part happens to rewrite. Removing a product name from
a comment or a doc sentence is not a restyle: it touches no surface, changes no
behaviour and cannot collide with a later part of the sweep. So this task clears
**all five** references the repository currently holds, not only the two this
part would rewrite anyway.

**Files:**
- Modify: `docs/architecture/core-theme.md`, `app-window.md`,
  `app-editor-overlays.md`, `core-provisioning.md`, `CLAUDE.md`
- Modify (brand sweep): `Sources/Pisaka/ContentView.swift`,
  `docs/architecture/app-window.md`, and the breadcrumb comment moved in Task 3

- [ ] Brand sweep, all five: (1) the breadcrumb's doc comment, rewritten in
      Task 3; (2) `docs/architecture/app-window.md` line ~141, the branch
      widget's "status-bar convention" sentence; (3)
      `Sources/Pisaka/ContentView.swift` line ~148, the bottom-dock-panel
      property's comment; (4) `Sources/Pisaka/ContentView.swift` line ~792, the
      branch widget comment above `BranchSwitcherView`; (5) the matching
      breadcrumb sentence in `app-window.md`. In each case replace the product
      name with what it was standing in for (the convention or the placement
      being described), never by deleting the sentence's meaning. Then `grep -ri`
      the repository for the offending names to confirm the set is empty — code,
      comments, docs and the commit message alike.
- [ ] `core-theme.md`: retitle the "three surfaces restyled here" section as the
      sweep's running record and add this part's surfaces — the vertical tab
      column (and the one slot view the two orientations now share), the
      breadcrumb (including why it is a file of its own and how it stays both
      equatable and live), the minimap's chrome (and the run colours it does not
      touch), the consent strip; restate what remains for later parts, and that
      `currentLine`/`bracketMatch` are deliberately still unused.
- [ ] `app-window.md`: rewrite the `TabListView`/`TabRowView` entry and the
      breadcrumb entry (new file name, new structure, the deleted `Divider()`).
- [ ] `app-editor-overlays.md`: the ruler's corrected fill — the seam, why the
      handed rectangle is not the bounds, and that the test is the only thing
      that can see it — and the minimap's background and viewport indicator.
- [ ] `core-provisioning.md`: one paragraph on the consent strip's chrome in its
      `LSPConsentBanner.swift` entry.
- [ ] `CLAUDE.md`: one index line for `BreadcrumbBarView.swift` under
      `app-window.md`, and the tab-column line adjusted; nothing else grows.
- [ ] run `swift test` (the doc-reading suites) — must pass before Task 7

### Task 7: Verify acceptance criteria

- [ ] `swift test` — green
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=macOS' -derivedDataPath
      ~/Library/Developer/Xcode/DerivedData/pisaka-chrome-theme-2 test` — green
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'generic/platform=iOS' -derivedDataPath
      ~/Library/Developer/Xcode/DerivedData/pisaka-chrome-theme-2 build` — the
      iOS target still builds
- [ ] `swiftlint --strict` from the repository root — clean
- [ ] Confirm the seam test fails when the background rectangle is widened back
      to the rectangle it is handed, then revert
- [ ] Confirm `gatedFiles` grew by exactly the five files restyled here and that
      the five rules and three exemptions are unchanged (diff the suite)
- [ ] **Capture the running app, headlessly, once per appearance.** Not by
      running the executable and not by driving the interface with synthetic
      clicks — both were tried on this machine and neither works (a directly-run
      binary shows no window; synthetic clicks land in whatever application is
      frontmost). The procedure, run twice — once with `dark`, once with
      `light`:
      1. Quit any running instance (`osascript -e 'quit app id
         "ws.karmanov.pisaka"'`, then confirm with `pgrep`), because a live
         instance rewrites its own defaults on quit.
      2. Select the appearance *outside the interface*: `defaults write
         ws.karmanov.pisaka settings.themePreference -string dark` (then
         `light`) — the key `SettingsStore.Keys.themePreference` names and the
         raw value `ThemePreference` declares.
      3. Launch the built bundle with `open` — `open -a
         "$DERIVED/Build/Products/Debug/Pisaka.app"` — never the executable
         inside it.
      4. Wait for a window, then read its frame through the accessibility API: a
         small Swift helper (written under the derived-data path, **not** into
         the repository tree) that finds the process by bundle identifier, asks
         `AXUIElementCopyAttributeValue` for `kAXWindowsAttribute` and prints the
         first window's position and size.
      5. `screencapture -x -R"$x,$y,$w,$h" "$OUT/chrome-dark.png"` with `$OUT`
         outside the repository tree (under the derived-data path or `$TMPDIR`),
         then read the image back and judge it: the editor shows its code, the
         gutter is gutter-wide and agrees in colour with the pane, the minimap
         draws its runs, and the five surfaces read as specified.
      6. Quit the instance before the next appearance.

      **Honest fallback:** if no window frame can be obtained — the
      accessibility permission is not granted to the driving process, the window
      list is empty, or the wait times out — the task says so plainly in its
      report, names which step failed, ticks nothing, and leaves the visual
      confirmation to the manual post-completion list below. A box that could not
      be verified is not ticked.
- [ ] Confirm nothing was written into the repository tree (`git status` clean
      but for the intended changes)

## Post-Completion (manual, by the user)

- Launch in dark and in light and look at the five surfaces against the
  specification, the horizontal strip included — it must be visually unchanged.
  (This stays on the list whether or not Task 7's capture succeeded; the
  regression this part fixes passed every automated gate the pipeline has.)
- Switch Appearance in Settings in both directions and confirm every surface
  recolours live, with no relaunch.
- Switch the tab-orientation preference both ways and confirm each column/strip
  is correct and the editor beside it is undisturbed.
- Zoom the interface and confirm the tab column, the breadcrumb and the consent
  strip scale; zoom the code and confirm the gutter and minimap follow the code
  zone as before.
