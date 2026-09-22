# Chrome theme part three — two one-line gaps from the acceptance review

## Overview

Two small items the acceptance review is not willing to ship silently. Neither
is a redesign; each is one line plus the sentence saying why.

1. **The bar's labels can wrap into a bar that can no longer grow.** This part
   gave the bottom bar a fixed `bottomBarHeight` frame, where before it was
   content-driven padding. Neither switcher's label carries a line limit, so on
   a narrow window — or with a long branch name, which this very branch has —
   the flexible `Text` wraps and the second line is clipped by the fixed height
   instead of growing the bar. The first review round raised this shape and
   synthesis dropped it without a stated reason; the acceptance review does not
   think it should have been.
2. **The sidebar header's Refresh button is icon-only and unnamed.** It carries
   `.help("Refresh project tree")` — a tooltip, which is not an accessibility
   name — and nothing else, so it announces its glyph. This is *pre-existing*:
   the button was icon-only before this part too. It is fixed here because this
   part rebuilt the header around it and because the branch now states the rule
   for exactly this shape three files away; leaving the one control the part
   personally re-laid-out as the exception would be the kind of local blindness
   the rest of this sweep exists to remove.

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-chrome-part-three test
swiftlint --strict
```

Never pass a derived-data path inside the repository.

## Implementation Steps

### Task 1: The bar's two labels stay on one line

**Files:** `Sources/Pisaka/ProjectSwitcherView.swift`,
`Sources/Pisaka/BranchSwitcherView.swift`

- [x] Give each widget's own `Text(currentLabel)` a single-line limit with a
      truncation mode, matching what the project switcher's *popover* rows
      already do for the same reason.
- [x] Say in one comment per site what the limit protects: the bar states its
      height now, so a label that wraps is a label that is cut in half rather
      than one that makes room for itself.
- [x] Sweep the construct rather than the two sites: any `Text` drawn directly
      inside the bottom bar's fixed-height frame — the widgets' labels included
      — must be single-line. If a third one exists, it gets the same treatment
      in this commit.
- [x] **The test that would have caught it**: pin it where the bar's own rules
      already live. In the gating suite's bottom-bar rule, assert that each of
      the three widget files spells a single-line limit for the label it draws
      in the bar — in the suite's own counted/contains idiom, with the honest
      limit stated in the doc comment (a source rule cannot see a layout, only
      the line that prevents it).

### Task 2: The sidebar header's Refresh button says what it is

**File:** `Sources/Pisaka/ProjectTreeView.swift`

- [ ] Give the button an explicit accessibility label naming the command, so it
      is not announced by its glyph. Keep the tooltip as it is.
- [ ] Record in one short comment that a tooltip is not a name — the same
      sentence the bottom bar's toggles carry, which is why both now spell both.
- [ ] Sweep the construct in this file: any other control here whose whole label
      is an `Image(systemName:)` gets the same treatment in this commit, and if
      there is none, say so in the task's own commit message rather than
      leaving it unasked.

### Task 3: Gates

- [ ] `swift test` green.
- [ ] The app-layer bundle green on a macOS destination, derived data under
      `~/Library/Developer/Xcode/DerivedData/pisaka-chrome-part-three`.
- [ ] `swiftlint --strict` clean from the repository root.
