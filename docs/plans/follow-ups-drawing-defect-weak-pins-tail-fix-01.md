# Fix plan 01: the diff divider lands on whole pixels, and the render test reads it where it is unambiguous

## Overview

This plan answers the one red check on the branch
`follow-ups-drawing-defect-weak-pins-tail` (pull request #92). The `build-macos`
job on the macOS 15 runner fails
`LocalChangesLayoutTests.testASelectedDiffLeavesThePanelDrawnAtScaleOnePointEight`
with

```
XCTAssertEqualWithAccuracy failed: ("-0.2417") is not equal to ("0.5") +/- ("0.15")
- the divider between the diff panes is not hairline at scale 1.8
```

while the same test passes on the developer machine (macOS 27). The other three
checks (`test`, `build-ios`, `lint`) are green.

**The cause.** `DiffContainerView.layout()` (`Sources/Pisaka/DiffView.swift:524`)
splits its width as `paneWidth = (width − hairlineWidth) / 2`, puts the left pane
at `0…paneWidth`, the divider at `paneWidth` with width `hairlineWidth` (one
point, unscaled — the panes are a code-zoom surface, the token's stated
exception) and the right pane after it. At interface scale 1.8 the hosted panel
is 1620 points wide and the list 576, so `paneWidth` is fractional and the
one-point divider straddles two pixel columns. The test's `dividerLeftShare`
(`Tests/PisakaAppTests/LocalChangesLayoutTests.swift:411`) reads one pixel
column — `floor(frame.minX × pixelScale)` at the divider's vertical middle — and
asserts its blend between the `bgEditor` swatch and the `hairline` swatch equals
the fraction of that column the divider covers, 0.5 here. On the runner that
column read darker than `bgEditor` itself: neither the left pane's ground nor the
divider was drawn there as the test assumed. That assumption is the defect; it is
environment-dependent by construction. At scale 1 every frame is integral and
the test passes on both machines.

**What it is not.** Both machines render at backing scale 1, so the backing
scale is not the difference. Forcing `scrollerStyle = .legacy` on both pane
scroll views locally did not reproduce the failure, so the scroller style is not
the cause either. How macOS 15 snaps drawing to the pixel grid at fractional
frames is not reproducible locally and is **not chased**: the fix removes the
fractional frame instead.

**The product consequence of the same arithmetic.** At a fractional width the
hairline is drawn as two half-covered columns — a blurred two-pixel line — on
every display.

Renders go through `HostedRender` (`Tests/PisakaAppTests/HostedRender.swift`):
`cacheDisplay(in:to:)` of the hosting view in one borderless window per state,
offscreen; `pixelScale` is bitmap pixels per point.

## Validation Commands

```sh
swift test
xcodegen generate && xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-fix01 test
swiftlint --strict
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -configuration Release -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-fix01 build
```

Derived data stays outside the repository. No product or brand names in code,
comments, documents or commit messages. No screen-recording API in any test:
every render stays offscreen through `HostedRender`. No window, hosting view or
bitmap per row or per pixel. Work on this branch in place; do not create a
branch.

## Implementation Steps

### Task 1: The split is pixel-aligned, and the test reads one whole column of the divider

**Finding** (gating, CI), `Sources/Pisaka/DiffView.swift:524-533` and
`Tests/PisakaAppTests/LocalChangesLayoutTests.swift:363-372, 411-430`: a
one-point divider at a fractional offset covers two pixel columns by half, and
the test's reading of the straddled column depends on how the machine draws it.

**Fix, the layout.** `DiffContainerView.layout()` rounds the left pane's width to
the window's backing pixel grid — `window?.backingScaleFactor ?? 1` — so the
divider's frame starts on a pixel boundary; the divider stays
`ChromeGeometry.hairlineWidth` points wide and unscaled (the code-zoom exception
is unchanged), and the right pane takes whatever remains. The layout stays
correct when the container is narrower than the divider (no negative widths).
A comment states why: a one-point rule at a fractional offset is drawn as two
half-covered columns, and the render test reads it as one.

**Fix, the test.** Replace `dividerLeftShare` and its blend arithmetic with a
read of one pixel column that lies entirely inside the divider's hosted frame:
from `dividerFrame` and `render.pixelScale`, take the first column whose
`[column, column + 1) / pixelScale` span lies within `[minX, maxX]`, and fail
loudly through `XCTUnwrap` when no such column exists. Assert that column, at the
divider's vertical middle, matches `hairline` through the existing
`matches(_:atX:y:ground:)` against the left pane's `bgEditor` ground — the exact
match the suite already uses, no tolerance, no blend. Keep this at both scales.
The rows-band negative assertions, the list and header positive assertions and
the diff-window render stay exactly as they are.

**Mutation check,** by hand and never committed: restore the unrounded
`(width − hairlineWidth) / 2` and run the suite — the scale-1.8 test must fail
on the unwrap (no fully covered column). The scale-1 test may still pass; that is
expected, and is why the runner's failure was invisible there.

**Documentation.** In `LocalChangesLayoutTests`' header, replace the half-pixel
explanation ("read as the leftmost pixel column's blend…") with the whole-column
read, and record the CI failure that forced it: on the macOS 15 runner the
straddled column read darker than the ground, unreproduced on the developer
machine with either scroller style. In `docs/architecture/app-git-views.md`, the
`DiffView.swift` entry's `DiffDividerView` passage states that the split is
pixel-aligned and why. The suite's window count does not change. No other
document changes unless one stops being truthful.

- [x] `DiffContainerView.layout()` rounds the left pane's width to the window's backing pixel grid, with the comment above; the divider stays one unscaled point; no negative frame at any width
- [x] `LocalChangesLayoutTests` reads one pixel column entirely inside the divider's frame, unwrapping loudly when there is none, and asserts it matches `hairline` through `matches(_:atX:y:ground:)` at both scales; `dividerLeftShare` is gone
- [x] mutation: with the unrounded split restored, the scale-1.8 test fails on the unwrap; restore the fix afterwards
- [x] `LocalChangesLayoutTests`' header and the `DiffDividerView` passage in `docs/architecture/app-git-views.md` updated as described

### Task 2: Verify

- [ ] `swift test` passes
- [ ] the app-layer bundle passes, and `LocalChangesLayoutTests` passes three runs in a row
- [ ] `swiftlint --strict` clean
- [ ] the macOS Release build succeeds
