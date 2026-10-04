# Fix plan 02: the ruler clips its own drawing to its bounds

## Overview

This plan answers the second acceptance check of the branch
`lsp-consent-banner-card` (plan
`docs/plans/completed/20261004-lsp-consent-banner-card.md`, after fix plan 01).
Every gate is green and one defect is still on screen, measured off a window
capture of the Debug build on 2026-10-04 (interface scale 1, window 1644 points
wide, a `.py` file at the project root, the consent bar shown):

**A one-point vertical line runs through the whole height of the consent bar at
the gutter's trailing edge** — pixel column 786, the same column the gutter's
hairline occupies inside the editor below — in a lighter shade than the gutter's
own `hairline` (`0x4C4E50` against `0x414448` in the capture), and only in the
bar's rows. It is not always there: an earlier capture of the same binary had the
column clean. Reproduced outside the app with a stock `NSRulerView` inside an
`NSScrollView`, driven through `displayIgnoringOpacity(_:in:)` into a bitmap
pre-filled with magenta and handed a rectangle 72 points taller than its bounds:
the column `ruleThickness - 1` was tinted over all 72 rows **outside** the ruler.
`NSRulerView`'s own `draw(_:)` paints a translucent one-point separator along
its client edge over the whole rectangle it is handed, and since macOS 14
`NSView.clipsToBounds` defaults to `false`, nothing limits it to the ruler.
Fix plan 01 clamped what *our* hook paints; the superclass's own drawing is
outside that clamp, which is why the line survives on the bar while the gutter's
`bgEditor` fill no longer does. Setting `clipsToBounds = true` on the same stock
ruler left all 72 rows magenta.

The remedy is the ruler clipping its drawing to its bounds, so **everything**
drawn through it — the superclass's separator, the hook's fills, the labels —
stays inside the ruler. `backgroundRect(in:bounds:ruleThickness:)` stays: the
clamp decides *what* the hook paints and the clip decides *where* drawing can
land, and the arithmetic test suite keeps its subject.

Not changed: the breadcrumb bar (the design's own breadcrumb for a file at
`Sources/PisakaCore/WorkspaceModel.swift` in a project named `pisaka` reads
`Sources › PisakaCore › WorkspaceModel.swift`, relative to the root and without
its name, which is what `DisplayPath.components` does; a root-level file shows
its bare name by the same rule).

## Validation Commands

```sh
swift test
xcodegen generate && xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build test
swiftlint --strict
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -configuration Release -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build build
```

Derived data lives in that one folder and nowhere else; never inside the
repository. No product or brand names in code, comments, documents or commit
messages. No screen-recording API in any test. Tests stay cheap: one bitmap per
test, many pixels read per bitmap, no window.

## Implementation Steps

### Task 1: The ruler clips everything it draws to its bounds

**Files:**
- Modify: `Sources/Pisaka/LineNumberRulerView.swift`
- Modify: `Tests/PisakaAppTests/LineNumberRulerBackgroundTests.swift`
- Modify: `Tests/PisakaCoreTests/DrawDirtyRectSourceGatingTests.swift` (doc comment only)
- Modify: `docs/architecture/app-editor-overlays.md`

- [x] In `LineNumberRulerView.init(scrollView:textView:)` (the one initializer both
      construction sites — `CodeEditorView` and `SourceViewerContent` — go through),
      set `clipsToBounds = true` right after `super.init`. A comment states why:
      since macOS 14 the default is `false`; `NSRulerView`'s own `draw(_:)` paints a
      translucent one-point separator along its client edge across the whole
      rectangle it is handed, which regularly reaches above the ruler, and that line
      landed on the surface above the editor (the consent bar, 2026-10-04); the hook's
      own clamp (`backgroundRect(in:bounds:ruleThickness:)`) cannot reach the
      superclass's drawing, so the clip is the one answer that covers everything drawn
      through this view. Nothing else in the file changes; the clamp stays, with its
      comment amended by one sentence saying the clip now guards the superclass's
      drawing as well and the clamp still decides what the hook paints.
- [x] Add `testTheRulerDrawsNothingAboveItsBounds` to `LineNumberRulerBackgroundTests`,
      modelled on `testTheHookPaintsNothingAboveItsBounds` but driving the **stock
      draw path**, not the hook: build the ruler as that test does (a text view in a
      scroll view, the ruler 59 points wide and 300 tall), make a 59×372 bitmap
      pre-filled with the magenta sentinel, and call `ruler.displayIgnoringOpacity(_:in:)`
      with a rectangle covering the ruler's bounds plus 72 points above them, in the
      bitmap's graphics context (translated so the extra 72 rows are inside the
      bitmap, handling `isFlipped` as the existing test does). Assert that every
      pixel of the 72 rows outside the bounds still carries the sentinel — including
      the column at `ruleThickness - 1`, where the superclass's separator lands — and
      that a pixel inside the bounds is no longer the sentinel. Mutation check, by
      hand and never committed: with `clipsToBounds = true` removed, this test must
      fail (the probe outside the app showed exactly that column tinted); the
      existing hook test may stay green, which is the point — the hook was already
      clamped and this test covers what the hook test cannot see.
- [x] Update the suite's header: it now pins two things — the hook's clamp and the
      view's clip — and says why both exist (the clamp decides what the hook paints,
      the clip is the only thing that reaches the superclass's own separator). Keep
      the window count truthful: this suite opens no window.
- [x] In `DrawDirtyRectSourceGatingTests`' doc comment, the sentence recording the
      ruler hook as a second drawing hook outside its shape gains the fact that the
      ruler also clips to its bounds, pinned by the bitmap test, so a stock
      `NSRulerView` separator cannot leave the ruler either.
- [x] `docs/architecture/app-editor-overlays.md`, `LineNumberRulerView` entry, at the
      passage about the gutter's fill clamped to the bounds (around the line that
      names macOS 14's `clipsToBounds` default): add that the ruler sets
      `clipsToBounds = true`, why (the superclass's own translucent separator painted
      over the consent bar on 2026-10-04 through a dirty rectangle reaching above the
      ruler, and no clamp inside the hook can reach the superclass's drawing), and
      what pins it. State the division of labour in one sentence: the clamp decides
      what the hook paints, the clip decides where any drawing through the view can
      land.
- [x] Run `swift test`, the app-layer bundle and `swiftlint --strict`; all green.
- [x] Commit.

### Task 2: Final gates and a read of the branch diff

**Files:** none new.

- [x] Run all four validation commands; record the counts in the commit message.
- [x] `git diff master...HEAD --stat` and read the diff of `LineNumberRulerView.swift`
      and the two test files once more against the overview above: no stray change,
      no product or brand name, every comment truthful about what is now pinned.
- [x] Commit if anything changed.
