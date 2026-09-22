# Chrome theme part three — one finding from the acceptance review

## Overview

The acceptance review, reading every changed file in full, found one defect the
two review rounds did not: **the first fix round silenced the only non-visual
indicator of which project and which branch are the current ones.**

Round one correctly found that the two bar widgets had started announcing their
own decorative glyphs, and the fix hid every `Image(systemName:)` in both files.
Two of those symbols are not decoration. In `ProjectSwitcherView.projectRow` the
glyph is `row.isCurrent ? "checkmark" : "folder"`, and in
`BranchSwitcherView.rowIcon(for:)` it is `"checkmark"` for the current branch —
each is the row's **state**, and the only other carrier of that state is the
accent colour on the row's text, which assistive technology cannot read either.
After the fix a listener hears the same announcement for the project they are in
and every other project in the list.

The new gating rule makes it permanent rather than accidental: it requires the
`Image(systemName:)` count and the `.accessibilityHidden(true)` count to be
equal in both files, so a state-bearing symbol *must* be hidden to keep the gate
green. The rule is right about decoration and blind to state, and both halves
are fixed here.

This is the shape revmux's own guidance warns about — a fix written for the case
that prompted it — so it is fixed at the construct rather than at the two sites:
any symbol in these files whose *name or colour varies with a value* is state.

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-chrome-part-three test
swiftlint --strict
```

Never pass a derived-data path inside the repository.

## Implementation Steps

### Task 1: The two popovers announce the state their glyph used to carry

**Files:** `Sources/Pisaka/ProjectSwitcherView.swift`,
`Sources/Pisaka/BranchSwitcherView.swift`

- [x] `projectRow(_:)`: keep the symbol hidden — it is redundant with a spoken
      value — and give the row itself an accessibility value naming the state,
      so the current project's row is distinguishable without sight. The row's
      name stays its label; only the state is added.
- [x] `branchRow(_:action:)`: the same for the current branch. Check
      `remoteBranchRow(_:)` too and state in a comment what it needs or why it
      needs nothing: its glyph does not vary with `isCurrent`, so if it carries
      no state it carries none and that is worth saying once.
- [x] Correct the comment beside each hidden symbol. "Decoration beside the
      row's own name" is false precisely on the row where the glyph is a
      checkmark; say that the glyph is hidden *because the state it showed is
      now spoken*, which is a different sentence and the true one.
- [x] Sweep the construct rather than the two sites: in both files, find every
      `Image(systemName:)` whose symbol name **or** colour is chosen by a
      condition, and make sure each such state has a spoken carrier. A symbol
      that is the same in every state is decoration and stays hidden and silent.

### Task 2: The gating rule stops requiring a state-bearing glyph to be silenced

**File:** `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [ ] Keep the counting half — every `Image(systemName:)` in the two widget
      files is hidden — since it is what catches the original defect.
- [ ] Add the half that was missing: each of those two files must also spell
      an accessibility **value** (the state carrier), so hiding a glyph cannot
      silently remove information again. A rule cannot detect which symbol
      encodes state, and it should not pretend to; what it can pin is that a
      file which hides every symbol it draws still says something about state.
- [ ] Say in the rule's doc comment what it does *not* see, in the suite's own
      idiom — the honest limit is part of the rule.
- [ ] If the rule count or its wording changes, keep the suite's marker,
      `core-theme.md`'s canonical list and `CLAUDE.md`'s invariant sentence in
      agreement; the suite checks all three against each other.

### Task 3: The record

**Files:** `docs/architecture/core-theme.md`, `docs/architecture/app-window.md`
(and `app-git-views.md` if its branch-switcher entry states the row's
announcement)

- [ ] Record the correction in the part-three entry: the widgets hide their
      decorative symbols, and the two rows that encoded state in a glyph now
      speak it — with one sentence on why the counting rule alone was not
      enough, so the next part reusing this idiom does not repeat it.

### Task 4: Gates

- [ ] `swift test` green.
- [ ] The app-layer bundle green on a macOS destination, derived data under
      `~/Library/Developer/Xcode/DerivedData/pisaka-chrome-part-three`.
- [ ] `swiftlint --strict` clean from the repository root.
