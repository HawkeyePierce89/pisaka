# Fix plan 01 — answers the acceptance review of the bottom-bar popovers

## Overview

This plan answers the three findings of the hand acceptance review of the branch
`bottom-bar-popovers-open-upward-inside-the-window`, taken after ralphex's own two review
passes. None of them is a crash; all three are the drawn result departing from the design
and from the ticket the branch implements, two of them visible on the first screenshot:

- The project popover draws a folder glyph in every row's slot; the design keeps the slot
  **empty** on every row but the current one and the action rows.
- The branch popover's filter field is drawn with no vertical room: the shared field is
  built with no height, so its box hugs the text line. The design's field has 8 points of
  vertical padding and an 8-point gap between the search glyph and the text.
- The field does not take the text focus when the popover opens: on screen its border is
  the one-point `hairline`, not the two-point `accent` of the focused state.

Two decisions are taken and not reopened here: what Return does right after a filter
(today: the first row, "New Branch…") and where letters go while the project popover,
which has no field, is open (today: to the editor beneath). Both stay as they are. The
field keeps the interface font the shared field draws.

The plan runs on the existing branch; ralphex commits each task there.

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test
swiftlint --strict
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -configuration Release build
```

xcodebuild uses the default DerivedData location, never a `-derivedDataPath` inside the
repository. No product or brand names in code, comments, docs, tests or commit messages.

## Implementation Steps

### Task 1: The project rows' slot is empty except on the current row

**File:** `Sources/Pisaka/ProjectSwitcherView.swift:137`

The defect: `ProjectSwitcherPopover` passes `glyph: .folder` to every
`ChromePopoverProjectRow`, so each non-current recent project shows a folder in its
16-point slot. The design, the original ticket and `app-window.md`'s own description of
the row all state the slot is empty: only the current row draws `check` in `accent`, and
only the action row "Open Folder…" draws `folderOpen`. The branch popover already does
this; the project popover does not.

- [x] Drop the folder glyph from the project rows. The current row keeps `check` through
      `isCurrent`; "Open Folder…" keeps `folderOpen`. Nothing else in the row changes.
- [x] The test that would have caught it, read off the project bitmap
      `ChromePopoverLayoutTests` already renders (no new window): in
      `assertProjectPopover`, read a second column down the slot's centre — the
      container's origin plus `popoverRowPaddingX` plus half of `popoverRowGlyphSlot`,
      scaled — and assert that through the non-current row's 36-point band every pixel
      classifies as `fill` (the slot is empty on a clear ground), while through the
      current, selected row's band at least one pixel classifies as the `accent` swatch
      (the check). Both at scale 1.0 and 1.8. Confirm by hand that the first assertion
      goes red with the folder glyph restored, then remove it again.
- [x] `swift test` and the app-layer bundle must pass before the next task.

### Task 2: The filter field's height and glyph gap are tokens, drawn and measured

**Files:** `Sources/PisakaCore/ChromeGeometry.swift`, `Sources/Pisaka/BranchSwitcherView.swift:162`,
`Tests/PisakaCoreTests/ChromeThemeTests.swift`, `Tests/PisakaAppTests/ChromePopoverLayoutTests.swift`

The defect: the branch popover builds `ChromeThemedTextField` with no `height:`, and the
shared `ChromeControlBox` then hugs its text line — zero vertical padding, the
placeholder and the 14-point search glyph pressed against the border — while every other
surface passes a height of its own (the project search 33, the log filter 22, the
LeetCode sheet 26). The glyph-to-text gap is the shared default 6. The design's field, as
literals: padding 8 vertical and 10 horizontal, gap 8 between glyph and text, text 13,
fill `bgEditor`, radius 4, focused stroke `accent` 2 — with a 13-point line that is a box
32 points tall at scale 1. The shared field takes a height, not a vertical padding, and
its gap is a parameter, so both are the caller's to state, and both are measurements, so
both are tokens.

- [x] Add two `ChromeGeometry` tokens, each with a one-line comment and neither a font
      size: `popoverFieldHeight` (32) and `popoverFieldGlyphGap` (8). Add the gap token to
      the type's doc-comment inventory sentence of padding and gap tokens, beside the
      other popover gaps.
- [x] The branch popover passes `height: ChromeGeometry.popoverFieldHeight` and
      `spacing: ChromeGeometry.popoverFieldGlyphGap` to the field (unscaled in, scaled by
      the box, as the other callers do). The horizontal padding stays the shared
      `fieldPaddingX` (10).
- [x] `ChromeThemeTests`: both tokens in the inventory's set equality and both values
      asserted.
- [x] The test that would have caught it, off the branch bitmap the suite already
      renders: `assertBranchPopover` already finds `fieldTop` and `fieldBottom` in its
      column; assert `fieldBottom - fieldTop` equals `32 × scale` within the suite's
      tolerance, at scale 1.0 and 1.8. Confirm by hand that it goes red with the height
      removed from the call, then restore.
- [x] `core-theme.md`'s section *The bottom bar's popover component* names the two
      tokens where it describes `ChromePopoverFieldBlock` and the filter field.
- [x] `swift test` and the app-layer bundle must pass before the next task.

### Task 3: The field takes the focus when the popover opens, and a test sees it

**Files:** `Sources/Pisaka/BranchSwitcherView.swift` (`BranchSwitcherPopover`),
`Tests/PisakaAppTests/ChromePopoverPresenterTests.swift`

The defect: `BranchSwitcherPopover` sets its `FocusState` in `onAppear`. The presenter
mounts the content through the window-root overlay, and at that moment the field is not
yet in the window's responder chain, so the request is lost and the popover opens with
the editor still holding the focus — the screenshot shows the `hairline` border, not the
two-point `accent`. Nothing tests the gain: `testDismissGivesTheFocusBackOnlyWhenThePopoverTookIt`
checks the hand-back against a stub window and sets the focus by hand.

- [ ] Request the focus once the content is mounted in the window, not during the
      appearance pass: the request runs on the main actor after the current layout
      pass (a `Task` on the main actor or `DispatchQueue.main.async` from `onAppear` is
      the ordinary SwiftUI remedy; a second request is harmless). The field then holds
      the window's first responder from the moment the popover is on screen, with no
      click, and typing filters at once.
- [ ] The test that would have caught it, in `ChromePopoverPresenterTests`: host
      `ChromePopoverHost(presenter:)` with the presenter in the environment, the named
      coordinate space, theme and metrics, in a `HostedRender` window of 800 × 500 (the
      shape `testHostReportsTheSubmenuFrameWhereItDrawsIt` already uses); note a bar top,
      present the branch popover id with the real `BranchSwitcherPopover` content over a
      `BranchSwitcherModel` on `ChromePopoverStubGit`; settle; assert the window's first
      responder is an `NSTextView` field editor whose owning control (its delegate) is a
      descendant of the window's content view — the popover's field; then `dismiss()`
      and assert the first responder is no longer that field editor. A borderless
      `HostedRender` window may need to become key for SwiftUI to move the focus: if it
      does, make it so inside the test (a window subclass that can become key, or
      `makeKey()` on one) rather than weakening the assertion. This is one more window in
      the suite; its header's count and the description of what it pins are updated.
- [ ] Run the new case on the code before the fix as well. If it already passes there,
      keep the fix anyway — the lost request is a timing property of the real window's
      first layout pass that an offscreen host may not reproduce — and say so in the
      case's doc comment, so the test's limit is stated where a reader will find it.
- [ ] `core-theme.md`'s component section states the focus rule in one sentence: the
      field requests the focus after it is mounted, and holds it until dismiss hands it
      back. `app-git-views.md`'s `BranchSwitcherView` entry says "focused once mounted"
      where it says "focused on appear".
- [ ] `swift test` and the app-layer bundle must pass before the next task.

### Task 4: Gates

- [ ] `swift test`.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`.
- [ ] `swiftlint --strict` from the repository root.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -configuration Release build`.
- [ ] Confirm by grep that `ProjectSwitcherView.swift` spells no `.folder` glyph on a
      project row, that `BranchSwitcherView.swift` passes `popoverFieldHeight` and
      `popoverFieldGlyphGap`, and that no product or brand name entered the diff.
