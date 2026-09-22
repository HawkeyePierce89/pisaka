# Chrome theme part three — fixes from review round 02-after-fix

## Overview

Answers both findings of the second review round (`02-after-fix`, profile
`final`, two sources, none degraded). The round reported **nothing gating** —
`final`'s bar is major and above — and both findings are minor. Both are
nonetheless accepted, because both are contradictions the *first* fix round
introduced: it corrected a claim in four places and left a fifth, and it deleted
a test assertion while a document still credits the suite with it. A branch that
ships a comment saying the opposite of the rule beside it has documented its own
reasoning wrong.

Two sentences, no executable code reached. Each task sweeps for the *construct*
rather than the quoted site, because the defect in both cases is exactly "one
surviving copy of a claim that was corrected elsewhere".

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-chrome-part-three test
swiftlint --strict
```

Never pass a derived-data path inside the repository.

## Implementation Steps

### Task 1: One surviving copy of the superseded accessibility reason

**Finding** (`Sources/Pisaka/ContentView.swift:945`, minor, confidence 90,
verdict refined): the doc comment on `bottomBarButton(_:systemImage:panel:)`
still reads that the `Label` these buttons carried "supplied the accessibility
name for free, and an icon alone supplies none". Four other sites — rule ten's
doc comment in `ChromeThemeSourceGatingTests`, `app-window.md`, `CLAUDE.md`, and
the stated reason both switcher widgets hide their symbols — now say the
contrary, that an unhidden SF Symbol folds *its own* name into the control. The
sentence was introduced by this branch, and the fix commit whose message is
"refresh … the contradicting reasons" touched the suite and three documents but
not `ContentView.swift`.

Nothing operational is wrong: `.accessibilityLabel` replaces whatever a child
image contributes, so both controls behave correctly under either reading. What
is wrong is that a maintainer reading the very declaration rule ten gates learns
the reading the branch decided against — and the widgets' hide-the-symbol rule
reads as unnecessary from there.

- [x] Correct the sentence to the branch's settled reading: an icon-only control
      whose `Label` is gone announces the *symbol's* name unless an explicit
      `.accessibilityLabel` replaces it, which is why both are mandatory here —
      and why a decorative symbol beside a name is hidden instead.
- [x] **Sweep for the construct, not the quoted line.** Grep the working tree
      for every sentence asserting that an `Image(systemName:)`, an SF Symbol or
      an icon supplies *no* accessibility name — in source comments, test doc
      comments and documents alike — and correct every surviving copy in this
      same commit. Search for the claim's shape rather than the exact phrase: it
      is wrapped across line breaks at several of the sites already corrected.
- [x] No new test: the claim is prose, and rule ten already pins the behaviour
      the prose explains. Say so rather than inventing a pin.
- [x] Run `swift test` (the gating suites read these files) and the app-layer
      bundle.

### Task 2: A document credits a test with an assertion that was deliberately removed

**Finding** (`docs/architecture/app-shell.md:1541`, minor, confidence 95,
verdict refined): the `MainWindowChrome.swift` entry ends "…plus that the marker
view is hit-test transparent **and not an accessibility element**". The suite
disclaims exactly that second half: the first fix round deleted the assertion as
a tautology and recorded in the test's own comment that a plain `NSView` already
answers `false`, so the suite "cannot pin it and does not pretend to". The
document sentence was written before that deletion and never revised.

`CLAUDE.md` makes the architecture entry the contract read before modifying a
file, so a reader of the marker's initialiser is told a gate protects a line no
gate protects. The realistic damage is re-adding the tautological assertion the
round just removed, or trusting a gate that does not exist.

- [x] Correct the sentence: the suite drives a real window through the
      attachment path and asserts the title bar and the ground in both
      appearances plus hit-test transparency; the `setAccessibilityElement(false)`
      line is deliberately **not** pinned, and why.
- [x] **Sweep for the construct**: check every other document sentence that
      credits a suite of this branch — `MainWindowChromeTests`,
      `ChromeThemeSourceGatingTests`' new rules, `ChromeThemeTests`' token set —
      with what it asserts, and correct any other claim the suites do not
      actually make. One wrong claim of this shape was written by the round that
      was fixing wrong claims; the question is whether it was the only one.
- [x] No new test, for task 1's reason.
- [x] Run `swift test`.

### Task 3: Gates

- [x] `swift test` green.
- [x] The app-layer bundle green on a macOS destination, derived data under
      `~/Library/Developer/Xcode/DerivedData/pisaka-chrome-part-three`.
- [x] `swiftlint --strict` clean from the repository root.
- [x] Confirm the gating suite's rule count still agrees with `core-theme.md`'s
      canonical list and `CLAUDE.md`'s invariant sentence.
