# Fix plan 01: three chrome surfaces, acceptance review

## Overview

This plan answers the acceptance review of the branch
`three-chrome-surfaces-that-do-not-draw-what-their-docs-say`. One finding gates
the merge: a new app-layer test is red on the reviewer's machine and depends on
the machine it runs on, so it would also be unreliable in CI.

`CommitUnifiedDiffWashTests.testShortChangedLinesDoNotScrollWithLegacyScrollers`
forces legacy scroll bars by writing `AppleShowScrollBars = Always` into
`UserDefaults.standard` and posting
`NSScroller.preferredScrollerStyleDidChangeNotification`. Whether that changes
the hosted scroll view's style depends on the machine's own scroll-bar setting
and input devices: it took effect in the implementation run and does not take
effect on the reviewer's machine, where the test fails 3 of 3 on its own guard
(`XCTAssertLessThan failed: ("600.0") is not less than ("599.0") - the scrollers
are not legacy — the case is not exercised`,
`Tests/PisakaAppTests/CommitUnifiedDiffWashTests.swift:110`). It is also the only
app-layer test that writes into the app's real preferences domain
(`ws.karmanov.pisaka`, the test host's `UserDefaults.standard`); it restores the
key afterwards, but a test must not touch the user's preferences at all.

The production code (`CommitUnifiedDiffView.swift`, `VisibleWidthProbe`) is not
in question and is not changed by this plan.

## Validation Commands

```sh
swift test
xcodegen generate && xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-three-surfaces-fix test
swiftlint --strict
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -configuration Release -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-three-surfaces-fix build
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-three-surfaces-fix build
```

Derived data stays outside the repository. No product or brand names in code,
comments, documents or commit messages.

## Implementation Steps

### Task 1: The legacy-scroller case forces the style on the hosted scroll view, deterministically

**Finding** (important, new), `Tests/PisakaAppTests/CommitUnifiedDiffWashTests.swift:98-113`:
the case reaches legacy scrollers through a user default and a notification,
which is machine-dependent and writes into the app's real preferences domain.

**Fix.** Make the case independent of the machine and of any preference:

- Remove every `UserDefaults` read and write and the
  `preferredScrollerStyleDidChangeNotification` posts from the suite.
- Give `DiffRender` a way to set `scrollerStyle = .legacy` directly on the
  `NSScrollView` it already finds in the hosting view (the same lookup
  `contentWidth` and `visibleWidth` use), then let the layout settle and
  capture again, so the clip view shrinks by the vertical scroller's width and
  `VisibleWidthProbe` reports the new width. If the hosting framework resets the
  style on its own update pass, re-apply it after each settle inside that
  helper.
- If, even so, the style cannot be held on the hosted scroll view, replace the
  end-to-end case with a direct check of the probe: host `VisibleWidthProbe`
  (make it `internal` if it is `private`, with a one-line comment saying the
  app-layer suite reads it) inside a plain `NSScrollView` whose
  `scrollerStyle` is `.legacy` and whose document is taller than its frame, and
  assert that the width it reports equals the clip view's bounds width and is
  smaller than the scroll view's frame width. Record in the suite's doc comment
  which of the two forms is used and why.
- Keep the guard that proves the case is exercised (the visible width is
  smaller than the pane), and keep the assertion that the content is exactly the
  visible width.
- Update the case's doc comment so it describes how the style is forced now and
  no longer mentions the user default.

- [x] remove the user-default and notification mechanism from the suite
- [x] force legacy scrollers on the hosted scroll view itself (or, if that cannot be held, check the probe directly as described), keeping the "case is exercised" guard
- [x] confirm by mutation that the case still catches the defect it pins: temporarily make the content's minimum width read the pane's frame width instead of `visibleWidth`, see the case fail, restore
- [x] confirm no file under `Tests/PisakaAppTests/` reads or writes `UserDefaults.standard` (grep)
- [x] update the suite's doc comment, and the `CommitUnifiedDiffView.swift` entry in `docs/architecture/app-git-views.md` if it describes how the legacy case is forced

### Task 2: Verify

- [ ] `swift test` passes
- [ ] the app-layer bundle passes, and `CommitUnifiedDiffWashTests` passes three runs in a row
- [ ] `swiftlint --strict` clean
- [ ] macOS Release and iOS builds succeed
