# Code panes: keep the document clear of the gutter under macOS 26+ inset tiling

## Overview

On macOS 26 and later, AppKit no longer tiles a scroll view's vertical ruler by narrowing the clip view's frame. It now passes the ruler's thickness to the clip view as a leading `contentInsets.left`. That moves the document's home position to a bounds origin of `-contentInsets.left`. The framework applies the inset inside `NSScrollView.tile()` but leaves the bounds origin at 0, so every code pane opens one gutter's width to the right of home, with its first columns under the ruler.

The fix goes in `CodeScrollView.tile()`, the one place the inset is applied; every code pane already builds this subclass. Before calling `super.tile()`, the override reads the clip view's leading inset (the old inset) and its bounds origin x. A pane counts as at home when `origin.x <= -oldInset`, meaning at or left of its old home. That covers a view the framework clamped left of its old home when the inset shrank. After `super.tile()`, the override reads the new inset. If the inset changed and the pane was at home, it moves the clip view to the new home (`x = -newInset`), keeps y, and reflects the scroll to the scrollers. A pane the user scrolled right is not touched.

On older macOS the inset stays 0, so home stays 0, a pane at home sits at `x == 0`, and the inset never changes, so the branch never runs. The completion panel has no ruler, so its inset is always 0 and the branch is inert there too.

## Context

- Files involved:
  - `Sources/Pisaka/ZoomSurface.swift`: `CodeScrollView` gains the `tile()` override; its declaration shape stays the same
  - `Tests/PisakaAppTests/CodeScrollViewHomeTests.swift`: new headless suite
  - `docs/architecture/core-zoom.md`: the `ZoomSurface.swift` entry under "The macOS app half"
  - Read only, unchanged: `Sources/Pisaka/CodeEditorView.swift`, `DiffView.swift`, `MergeView.swift`, `SourceViewerContent.swift`, `CompletionPanel.swift`, `LineNumberRulerView.swift`
- Related patterns:
  - Headless AppKit tests with no window, in the mould of `EditorLayoutHarness` and `CurrentLineHighlightTests`.
  - `ZoomSourceGatingTests.testTheCodePanesScrollInsideTheCodeScrollView` (in `swift test`) reads the `CodeScrollView()` construction sites and the declaration `final class CodeScrollView: NSScrollView, ZoomSurfaceProviding`.
  - `SyntaxBaseForegroundGatingTests` (in the app bundle, `Tests/PisakaAppTests`) lists `ZoomSurface.swift:CodeScrollView`, and that entry must stay valid.
- Dependencies: none. `project.yml` already picks up the new test file through the `Tests/PisakaAppTests` source glob.

## Development Approach

- **Testing approach**: Regular (code first, then tests). The suite pins the invariant, not the mechanism, so it is green under both tilings.
- Complete each task fully before moving to the next.
- No change to any scroll path in `CodeEditorView.swift` (`scrollEditor(to:)`, viewport restore, scroll anchor, reveal). No change to the ruler's layout, thickness computation or drawing.
- This is AppKit-layer behaviour with no Core decision, so nothing goes into `PisakaCore`.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Correct the home position in CodeScrollView.tile()

**Files:**
- Modify: `Sources/Pisaka/ZoomSurface.swift`

- [x] Add `override func tile()` to `CodeScrollView`:
  - before `super.tile()`, read `oldInset = contentView.contentInsets.left` and `wasAtHome = contentView.bounds.origin.x <= -oldInset`
  - call `super.tile()`, then read `newInset = contentView.contentInsets.left`
  - if `newInset != oldInset && wasAtHome`, call `contentView.scroll(to: NSPoint(x: -newInset, y: contentView.bounds.origin.y))` and then `reflectScrolledClipView(contentView)`
  - otherwise do nothing
- [x] Keep the declaration exactly `@MainActor final class CodeScrollView: NSScrollView, ZoomSurfaceProviding` with `let zoomSurfaceKind: ZoomSurfaceKind = .code`.
- [x] Extend the type's doc comment with one short paragraph naming this second behaviour:
  - under inset tiling, home is `-contentInsets.left`
  - "at home" means at or left of the old home, read before `super.tile()`
  - only the at-home case is corrected
  - the correction is inert where the framework tiles by frame and on the ruler-less completion panel
  - point to `core-zoom.md` for the reasoning
- [x] Tests for this task: the behavioural suite is in Task 2. Here, run the gates that read this file's shape: `ZoomSourceGatingTests` through `swift test`, and `SyntaxBaseForegroundGatingTests` through the app bundle (`xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`).
- [x] Run `swift test`, the app bundle via `xcodebuild … test`, and `swiftlint --strict`. All must pass before Task 2. (swift test and swiftlint clean; the app bundle passes apart from 8 layout failures in BottomBarLayoutTests, BottomBarToolTipTests, ChromePopoverLayoutTests and CommitDialogLayoutTests, which fail identically without this change on this machine.)

### Task 2: Headless suite pinning the at-home invariant

**Files:**
- Create: `Tests/PisakaAppTests/CodeScrollViewHomeTests.swift`

- [ ] Write one private helper that builds the test pane:
  - a `CodeScrollView` with a frame (for example 600×400) and no window
  - a wide, tall document view (`NSView` or `NSTextView`) so a horizontal scroll has room
  - a plain `NSRulerView(scrollView:orientation: .verticalRuler)` with a set `ruleThickness`
  - `hasVerticalRuler = true` and `rulersVisible = true`, then a call to `tile()`
- [ ] Test: after the first tile, `contentView.bounds.origin.x == -contentView.contentInsets.left`.
- [ ] Test: widening the ruler (raise `ruleThickness`, then tile) leaves a pane that was at home at the new home, by the same equation.
- [ ] Test: narrowing the ruler leaves a pane that was at home at the new home, by the same equation.
- [ ] Test: a pane scrolled right is not sent home by a ruler change.
  - Scroll the clip view to `-oldInset + d` (for example d = 200) and reflect.
  - Widen the ruler and tile, then narrow it and tile.
  - After each change, assert `contentView.bounds.origin.x - (-newInset) >= d - abs(newInset - oldInset)`.
  - Do not assert that `bounds.origin.x` is preserved exactly.
  - The test's doc comment says why the weaker assertion is the honest one. What the framework does to a scrolled view's origin when its inset changes belongs to the framework, not to us, and it can differ between frame tiling on the CI runner and inset tiling on macOS 26+. The property this change owns is narrower: a scrolled pane is never re-homed.
- [ ] Test: a `CodeScrollView` with no vertical ruler (the completion panel's shape) keeps origin x 0 after tile.
- [ ] The suite's doc comment states that it pins the invariant rather than the mechanism. Under frame tiling the inset is 0 and home is 0, so it passes on the older CI runner. On macOS 26+ it exercises the correction.
- [ ] Run `xcodegen generate`, then `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`. It must pass before Task 3.

### Task 3: Record the behaviour in core-zoom.md

**Files:**
- Modify: `docs/architecture/core-zoom.md`

- [ ] In the `ZoomSurface.swift` entry, add a paragraph saying that `CodeScrollView` now carries one behaviour beyond its marker. Cover:
  - the macOS 26+ inset tiling and its home position of `-contentInsets.left`
  - why the fix lives in `tile()` rather than in a scroll path: the framework applies the inset there and leaves the origin at 0, and no app scroll runs first
  - what was ruled out:
    - the app scroll paths
    - the inset setter's own view of the origin
    - a second `tile()`
    - `automaticallyAdjustsContentInsets = false`, which leaves the clip view at full width under the ruler
  - the at-home predicate (`origin.x <= -oldInset`, read before `super.tile()`), and why it includes a view clamped left of its old home
  - that a user's horizontal offset is not re-homed
  - that the correction is inert under frame tiling and on the completion panel
  - the cross-cutting invariant: after every tile, a pane at home sits at `x == -contentInsets.left`
  - that `CodeScrollViewHomeTests` pins it, including why its scrolled-right assertion is deliberately weaker than exact preservation
- [ ] Confirm CLAUDE.md needs no new index name. The suite is app-bundle only and is not in the `swift test` source-gating list.
- [ ] Run `swift test` (including `LintConfigurationTests`). It must pass before Task 4.

### Task 4: Verify acceptance criteria

- [ ] Run `swift test`.
- [ ] Run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`.
- [ ] Run `swiftlint --strict` from the repository root.
- [ ] Run the macOS Release build to confirm the override compiles on the shipping path: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -configuration Release build`.
- [ ] Confirm the suite reaches every branch in `CodeScrollView.tile()` on the running macOS: inset changed at home, inset changed while scrolled, and inset unchanged.

### Task 5: Update documentation

- [ ] README.md and `docs/FEATURES.md`: no user-facing feature change, so leave them unless a known-issues line mentions the gutter overlap.
- [ ] CLAUDE.md: no change. There is no new file index name, and the reasoning lives in `core-zoom.md`.

## Post-Completion (manual)

- On macOS 26+, launch with a restored session and confirm every tab shows column 0 with the horizontal scroller at 0. Check the Local Changes inline diff, the diff window, the merge editor and the source viewer the same way.
- Toggle blame, zoom the code zone and cross a line-count digit boundary, both at home and while scrolled right.
