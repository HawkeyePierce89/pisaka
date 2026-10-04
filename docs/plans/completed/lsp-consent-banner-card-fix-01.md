# Fix plan 01: the gutter stops painting above itself, and the consent question becomes a full-width bar

## Overview

This plan answers the acceptance review of the branch `lsp-consent-banner-card`
(plan `docs/plans/completed/20261004-lsp-consent-banner-card.md`). Every gate is
green — `swift test` 6051 tests, the app-layer bundle 220 tests, `swiftlint
--strict`, the Release build — and the result on screen is still wrong. Measured
off a window capture of the Debug build on 2026-10-04 (interface scale 1,
window 1644 points wide, a `.py` file at the project root):

**1. The line-number gutter paints over the consent card's left 48 points.**
Where the card's border, its 18-point padding and its 16-point icon should be,
the pixels carry the gutter's own `bgEditor` fill, with the gutter's exact
width (x 705–752 against the card's visible border at 753; the editor zone
begins at 705). `LineNumberRulerView.drawHashMarksAndLabels(in:)`
(`Sources/Pisaka/LineNumberRulerView.swift:814`) fills
`Self.backgroundRect(in: rect, ruleThickness:)` and then a hairline whose `y`
and `height` are `rect.minY` / `rect.height`; `backgroundRect` clamps only the
trailing edge and carries the vertical half of the handed rectangle through
untouched (`:804`, and `LineNumberRulerBackgroundTests.
testVerticalGeometryIsCarriedThrough` pins exactly that). Since macOS 14
`NSView.clipsToBounds` defaults to `false`, so a rectangle handed to a ruler
is not limited to its bounds, and the two fills land above the ruler, on
whatever sits there — today the consent card. This is the class of defect
`DiffDividerView` had (`DrawDirtyRectSourceGatingTests`); that suite reads
`draw(_:)` overrides only, so a ruler's hook is outside its shape. The ruler is
untouched on this branch; the card made the overpaint visible.

**2. The inset card is the wrong shape for where it sits.** The 8-point band on
`bgEditor` with a rounded, bordered card inside it was the ticket's own
placement decision — the design has no instance of its Banner component in the
main window. Between the breadcrumb bar above and the editor below, both
full-width with a bottom rule, the floating card read as a misplaced block on
screen, and with the gutter's overpaint its left edge looked 48 points in. The
question becomes a **full-width bar**: the design's inner geometry is kept
(padding 14 vertical and 18 horizontal, a 16-point `accent` icon, 10 to the
text, one 13-point primary line, the actions at the trailing edge), the panel
ground runs edge to edge, and a scaled `hairline` rule along the bottom
separates it from the editor, exactly as the breadcrumb and the find bar do.
No radius, no border, no band, no `bgEditor`.

**3. The text column's `.layoutPriority(1)` is inert**, and the code and the
documents credit it with the fix. Removing it by hand left all four
`LSPConsentCardLayoutTests` green; capping the column at 400 points failed
both width tests. The modifier goes, every sentence about the spacer sharing
the width goes with it, and the width tests stay as the pin on the drawn
outcome.

Measured and **not** changed: the Download button is 87 points with its label
inset 14 and 15, No Thanks 89 with 14 and 14, the two 8 apart and 17 from the
bar's trailing edge — the design's values. The breadcrumb showing the bare file
name for a root-level file is older than this branch and is not touched.

Renders go through `HostedRender` (`Tests/PisakaAppTests/HostedRender.swift`),
offscreen, one window per rendered state.

## Validation Commands

```sh
swift test
xcodegen generate && xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build test
swiftlint --strict
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -configuration Release -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build build
```

Derived data lives in that one folder and nowhere else; never inside the
repository. No product or brand names in code, comments, documents or commit
messages. No screen-recording API in any test. Tests stay cheap: one hosted
window per rendered state, many pixels read per bitmap.

## Implementation Steps

### Task 1: The gutter fills nothing outside its own bounds

**Files:**
- Modify: `Sources/Pisaka/LineNumberRulerView.swift`
- Modify: `Tests/PisakaAppTests/LineNumberRulerBackgroundTests.swift`
- Modify: `Tests/PisakaCoreTests/DrawDirtyRectSourceGatingTests.swift` (doc comment only)
- Modify: `docs/architecture/app-editor-overlays.md`

- [x] Make the pure rule clamp both halves: `backgroundRect` takes the ruler's
      `bounds` as well and answers the handed rectangle intersected with the
      bounds, then trailing-clamped to `ruleThickness` as today — a rectangle
      wholly outside the bounds answers empty, never negative. Rewrite its doc
      comment: the vertical half is no longer "the scroll position's business",
      because the handed rectangle regularly extends beyond the ruler's bounds
      and the ruler does not clip, so an unclamped fill paints the surface above
      the editor (the consent bar, on 2026-10-04).
- [x] In `drawHashMarksAndLabels(in:)`, derive one clamped rectangle from the
      handed one through that rule before any fill, and use its `minY` and
      `height` for the hairline at the gutter's trailing edge as well; the
      current-line band is a row of the gutter read off the layout manager and
      stays as it is. Nothing in the hook fills `rect`'s vertical extent any
      more.
- [x] `LineNumberRulerBackgroundTests`: replace
      `testVerticalGeometryIsCarriedThrough` with its opposite — a rectangle
      extending above and below the bounds is clamped to the bounds' vertical
      extent, one inside the bounds is carried through — and pass `bounds` in
      the existing four. Then add a **drawing-level** test: build a ruler as
      `GutterFoldTests` does (`LineNumberRulerView(scrollView:textView:)` over
      the harness's text view), give it a frame such as 59×300, lock a bitmap
      graphics context 59 wide and 372 tall pre-filled with a sentinel colour
      that no role resolves to, translate so the ruler's bounds occupy the
      bottom 300 points, and call `drawHashMarksAndLabels(in:)` with a
      rectangle starting 72 points above the bounds and spanning the pane's
      width. Assert that every sampled pixel in the 72 rows above the bounds
      still carries the sentinel and that a pixel inside the bounds carries
      `bgEditor`, so the test has teeth in both directions. Mind the ruler's
      `isFlipped`; state in the test's doc comment which way "above" is in
      bitmap rows.
- [x] Mutation check, by hand and never committed: drop the vertical clamp
      (carry the handed `minY`/`height` through again) and confirm the
      drawing-level test fails; restore.
- [x] `DrawDirtyRectSourceGatingTests`' doc comment: in the audit paragraph,
      record that `LineNumberRulerView.drawHashMarksAndLabels(in:)` is a second
      drawing hook outside this rule's shape, that it filled its handed
      rectangle's vertical extent until 2026-10-04, and that
      `LineNumberRulerBackgroundTests` pins it instead. No rule change.
- [x] `app-editor-overlays.md`, the ruler's entry where `backgroundRect` is
      described (around line 643): both halves are clamped, why, and what it
      painted over.
- [x] Run `swift test` and the app-layer bundle; both must pass.

### Task 2: The consent bar replaces the card

**Files:**
- Modify: `Sources/Pisaka/LSPConsentBanner.swift`
- Modify: `Tests/PisakaAppTests/LSPConsentCardLayoutTests.swift` (renamed to `LSPConsentBarLayoutTests.swift`)
- Modify: `Tests/PisakaCoreTests/LSPSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md`, `docs/architecture/core-provisioning.md`, `docs/architecture/app-window.md`, `docs/FEATURES.md`

- [x] Rename `LSPConsentCard` to `LSPConsentBar` and redraw it: full width on
      a `bgPanel` ground, padding `metrics.scaled(14)` vertical and
      `metrics.scaled(18)` horizontal, a `hairline` `Rectangle` of height
      `metrics.scaled(ChromeGeometry.hairlineWidth)` along the bottom (never a
      `Divider()`), and nothing else around it: no `RoundedRectangle`, no
      `strokeBorder`, no 8-point padding, no `bgEditor`. The row inside is
      unchanged — the 16-point `accent` icon sized on its own chain, 10 to the
      text column, the body-size primary line and the optional subheadline-size
      secondary line, a spacer of at least 16, the two shared-style buttons 8
      apart at their fitting width.
- [x] Remove `.layoutPriority(1)`. Rewrite the view's doc comment and every
      comment in the file that speaks of a card, a band, a border, a radius,
      or of the text column sharing width with the spacer; keep the reasons
      that still hold (no `Divider()`, no `.keyboardShortcut`, the shared
      styles, the copy's reasons). The banner's own header says "bar" where it
      said "card".
- [x] Rename the suite to `LSPConsentBarLayoutTests` and re-aim it. At scales
      1 and 1.8: the pixel half a point in from the window's top-leading corner
      is `bgPanel` (nothing is inset); the bar's ground at the window's
      horizontal middle is `bgPanel`; a column through the leading padding
      carries `hairline` only at the bottom rule, whose extent is one scaled
      hairline tall within 0.6 and whose `maxY` equals the bar's height —
      the scaled 14 + 28 + 14 plus the scaled hairline — within 0.6; the rule
      is `hairline` at half a point in from both window edges and at the
      middle, so it spans the full width; the pixel just below the rule is
      the window's ground, not `bgPanel`. The two width tests keep their
      method, with the bar's height read as the bottom rule's `maxY` and
      `columnStart` recomputed as the scaled 18 + 16 + 10 with no inset and no
      border. Rewrite the suite's doc comment: the bar's geometry, how each
      value is measured, and the mutation record — a column capped at 400
      points fails both width tests; no sentence about a layout priority.
- [x] Mutation check, by hand and never committed: cap the text column at 400
      points and confirm both width tests fail; restore.
- [x] `LSPSourceGatingTests`: the keyboard-shortcut rule's anchor becomes
      `struct LSPConsentBar`, its test and doc sentences say "bar".
- [x] `core-theme.md`, the consent entry: rewrite for the bar and record the
      deviation from the design's Banner component as deliberate — the
      component is a bordered card with radius 6, and between two full-width
      bars with bottom rules it read as a misplaced block on screen on
      2026-10-04; the component's inner geometry is kept and the card stays
      the design's answer should a floating placement ever appear. Say that
      the text column carries no layout priority and that the suite pins the
      drawn width. `core-provisioning.md`'s `LSPConsentBanner.swift` entry:
      "bar" for "card", the bottom rule, the geometry, no priority sentence,
      the renamed suite. `app-window.md` and `docs/FEATURES.md`: "bar" where
      they say "card". The archived plan under `docs/plans/completed/` is
      history and is not edited.
- [x] Run `swift test`, the app-layer bundle and `swiftlint --strict`; all
      must pass.

### Task 3: Gates and the diff read

- [x] Run every command under Validation Commands; all green.
- [x] Read the branch's cumulative diff against `master` and confirm: no
      `Divider()`, no hex literal, no numeric font size other than the icon's
      `metrics.scaled(16)`, no `.keyboardShortcut`, no `layoutPriority`, no
      `LSPConsentCard` anywhere under `Sources/`, `Tests/` or
      `docs/architecture/`; `size(_:)` keeps its signature for
      `LSPServerSettingsView`; `backgroundRect` is called with the ruler's
      `bounds` at its one call site.
- [x] Confirm `CLAUDE.md` is unchanged and under its measured size limit.

## Post-Completion

- Live check in a Debug build, never Release, with the consent dictionary
  emptied through a launch argument: a `.py` file at the project root at
  interface scale 1 shows the bar flush with the editor zone's left edge, the
  icon visible, the gutter painting nothing above the editor; the bar is
  56 points plus one hairline tall; answering either button removes it.
