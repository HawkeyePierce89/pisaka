# Chrome theme, part five (c) — fix 01: the review round's findings

## Overview

Answers revmux round `01-initial` on task
`chrome-theme-part-five-c-preferences-and-pr-sheets`: four sources, none degraded,
eleven findings, all minor, all confirmed by verification and all re-derived in the
tree before this plan was written.

Two are defects a user would meet:

- **The Preferences tab bar draws no separator at all.** Its bottom `hairline` is
  applied *after* its opaque `bgPanel` ground, so SwiftUI draws the rule behind the
  fill. The page below is also `bgPanel`, so the bar and the page run together.
  Confirmed **live**: a standalone probe rendered both modifier orders side by side
  with a deliberately loud three-point rule, and the shipped order showed nothing.
- **The menu field's chevron is not part of its menu.** The `Image` sits as a
  sibling of `Menu`, not inside its label, so clicking what looks like the dropdown
  arrow does nothing. The arrangement came with the shape lifted from the Log filter
  bar, so this part spread it from one field to three.

Two are rules that do not hold what they claim, the class that cost part five (b)
three rounds:

- rule thirty-seven records **which files mention** each shape and never how many,
  so one of `SettingsView`'s two segmented controls could become a menu field with
  the file still in both sets and the gate green;
- the stepper-grid clause asserts the token `stepped` somewhere in the whole
  `ChromeStepper` body, and that token appears in both `adjust(_:)` and
  `stepButton(…)` — so the visible buttons could regress to a grid of their own
  while `adjust` keeps the gate green.

The remaining seven are documents and comments the branch made untrue.

**The sweep is done and its result is part of this plan.** The tab bar's defect is
one instance: `TabStripView` applies the rule before its ground and says why in its
own comment, and `DockTabRow` draws no ground on the strip at all, so it has no
ordering to get wrong.

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-p5c-fix01 test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -configuration Release -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-p5c-fix01 build
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-p5c-fix01 build
swiftlint --strict
```

Derived data never goes inside the repository working tree.

## Context

Files involved:
- `Sources/Pisaka/ChromeControls.swift` — `ChromeSettingsTabBar` (the background
  order) and `ChromeMenuField` (the chevron).
- `Sources/PisakaCore/ChromeGeometry.swift` — the type's doc-comment inventory and
  `menuFieldHeight`'s / `segmentedControlHeight`'s comments.
- `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift` — rules sixteen and
  thirty-seven, and the header inventory's bullets for twenty-seven and thirty.
- `Tests/PisakaCoreTests/ZoomSourceGatingTests.swift` — the stepper-grid clause.
- `docs/architecture/core-theme.md` (~945, ~1389, decision 9),
  `core-zoom.md` (~512 and Known limits), `core-services.md` (~244).

Related patterns:
- **SwiftUI draws each later `.background` further back.** A rule that must show
  goes on *before* the opaque ground. `TabStripView.swift` is the worked example and
  its comment states the reasoning; follow it rather than restating it.
- The suite's convention, recorded beside the rules: a rule pins a **set** by
  equality, asserts the **presence or absence of a token**, or does one of those
  inside a **brace-matched body**. It does not resolve types, evaluate conditionals
  or decide which branch runs. Counting occurrences and comparing two tokens'
  positions inside one matched body are within it; parsing an expression is not.
- Rule thirty already counts per file (`Button` against `buttonStyle`); rule
  thirty-seven's fix is that shape applied to the five settings shapes.

Dependencies: none new.

## Development Approach

- Testing approach: mutation-first for every rule touched — each is shown red
  against the regression it names *before* it is believed.
- Complete each task fully before the next; `swift test` must pass before the next
  task starts. A task touching app files also builds the macOS app.
- **No new machinery.** Every clause here is a count, a token, or two token
  positions inside one matched body. If a task seems to need a parser, stop and say
  so rather than writing one.
- Read each file's `docs/architecture/` entry before modifying it.
- No new colour role, no new exemption, no new font size, no new geometry token.
- No task takes a screen capture, and no task depends on a human opening a window.
- No product or brand names in code, comments, documentation or commit messages.
- Where a document was made untrue, correct it to what the tree does — and where a
  sentence was true of an earlier part, say when it stopped being true rather than
  deleting the history.
- CRITICAL: every task includes new or updated tests.

## Implementation Steps

### Task 1: The Preferences tab bar's rule is drawn in front of its ground

**Files:**
- Modify: `Sources/Pisaka/ChromeControls.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md`

The defect: `ChromeSettingsTabBar.body` applies `.background(theme.color(.bgPanel))`
and *then* `.background(alignment: .bottom) { hairline }`. Each later `.background`
is drawn further back, so the rule lands behind a fully opaque fill and is never
seen. The Preferences page below the bar is also `bgPanel`, so the two run together
with nothing between them.

- [x] Swap the two modifiers so the bottom rule is applied first and the ground
      after, as `TabStripView` does. Keep the reason in a comment pointing at the
      ordering, not at the colours.
- [x] Re-run the sweep rather than trusting this plan's copy: for every strip in
      rule sixteen's list, report the source order of its `.background(` calls.
      This plan found `TabStripView` correct and `DockTabRow` carrying no ground on
      the strip; report anything it did not account for.
      (Swept: TabStripView applies the hairline background at line 49 before its
      bgPanel ground at 54, its cell's bgEditor fill at 96 also after; DockTabRow
      spells one .background( only, the hairline, so no ground. Nothing else.)
- [x] **Rule sixteen gains an ordering clause.** In each listed strip's matched
      body, the `.background(alignment: .bottom)` whose body names `hairline` must
      appear **before** any plain `.background(` naming a background role — compare
      the two occurrences' positions inside that one body. A strip that draws no
      ground on itself satisfies it vacuously, and the comment says so, naming
      `DockTabRow` as that case so the next reader does not read the clause as
      unreachable.
- [x] Mutation-verify: restore the shipped order and confirm red; swap
      `TabStripView`'s two backgrounds and confirm red; revert both and confirm
      green, with a clean `git status`.
- [x] Extend rule sixteen's canonical entry and its header bullet with the ordering
      clause: the defect it now also pins is a rule that exists, is drawn with the
      right modifier, and is invisible.
- [x] Run `swift test` and the macOS build. Both must pass.

### Task 2: The menu field's chevron opens the menu

**Files:**
- Modify: `Sources/Pisaka/ChromeControls.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

The defect: in `ChromeMenuField` the chevron `Image` is a sibling of `Menu` rather
than part of its label, so the visible affordance is not the control. The shape was
lifted from the Log filter bar with the arrangement intact, so this part carried it
to the catalog page's language field and the create sheet's base field as well.

- [x] Move the chevron inside the `Menu`'s own label, beside the value text, so the
      whole field including the arrow opens the menu. Keep the chevron hidden from
      accessibility and the field's spoken label and value unchanged.
- [x] **Rule thirty-seven gains a shape-integrity clause** (or rule thirty, if that
      reads better where the shapes' callers are already pinned): inside
      `struct ChromeMenuField`'s matched body, the `chevron` glyph lies inside the
      `Menu`'s `label:` closure. Express it as a token inside a matched body, not as
      a parse of the view tree.
- [x] Mutation-verify: move the chevron back outside the label and confirm red;
      revert and confirm green, with a clean `git status`.
- [x] Run `swift test` and the macOS build. Both must pass.

### Task 3: Rule thirty-seven counts constructions, not mentions

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md`

The defect: the rule inserts a file name into a set when the file *mentions* a
shape's token, then compares the sets. It never counts. `SettingsView.swift` spells
two `ChromeSegmentedControl`s, two `ChromeStepper`s, two `ChromeSwitch`es and one
`ChromeMenuField`, so one segmented control could become a menu field with the file
still in both sets and the gate green — while the rule's own comment, its header
bullet and `core-theme.md` all say the pinned sets are the picker rule's whole
expression.

- [ ] Pin a **per-file construction count** for each of the five shapes, the way
      rule thirty already counts `Button` against `buttonStyle`. Count constructions
      through `callRanges(_:in:)` so a wrapped call counts.
- [ ] Confirm every number against the tree before writing it; a count this plan
      guessed is a count that will be wrong.
- [ ] Correct the three places that claim the sets are the rule's whole expression,
      so the document describes what the rule now does.
- [ ] Mutation-verify with the regression the old rule allowed: change one of
      `SettingsView`'s two segmented controls into a `ChromeMenuField` and confirm
      red — the file stays in both sets, so only the count can catch it. Then add a
      sixth construction to a pinned file and confirm red. Revert and confirm green,
      with a clean `git status`.
- [ ] Run `swift test`. It must pass.

### Task 4: The stepper's visible buttons are checked, not just its accessibility action

**Files:**
- Modify: `Tests/PisakaCoreTests/ZoomSourceGatingTests.swift`
- Modify: `docs/architecture/core-zoom.md`

The defect: the clause asserts the token `stepped` somewhere in `struct
ChromeStepper`'s whole body. That token appears twice — in `adjust(_:)`, the
accessibility action, and in `stepButton(glyph:spoken:by:)`, the visible minus and
plus. If `stepButton` regressed to arithmetic of its own, `adjust` alone keeps the
gate green, on the exact regression the failure message names. `core-zoom.md` claims
"every step — the glyph buttons and the adjust action — goes through the rule".

- [ ] Read `private func stepButton(` and `private func adjust(` as **separate**
      matched bodies and require `stepped` in each, with a message naming which half
      failed.
- [ ] Mutation-verify each half independently: replace `stepButton`'s call with
      arithmetic and confirm red; restore it and replace `adjust`'s and confirm red;
      revert and confirm green, with a clean `git status`.
- [ ] Run `swift test`. It must pass.

### Task 5: The geometry table's inventory and the two equal heights

**Files:**
- Modify: `Sources/PisakaCore/ChromeGeometry.swift`
- Modify: `docs/architecture/core-theme.md`

- [ ] The type's doc comment states a count and lists the inset, padding and gap
      tokens. The list omits `settingsRowSpacing`, which this branch added and
      documents as a vertical spacing, and it still omits the older `fieldPaddingX`
      and `secondaryButtonPaddingX`. Either list all of them and correct the count,
      or drop the number and keep the list — prefer dropping the number, since the
      count has now fallen behind twice.
- [ ] `segmentedControlHeight` and `menuFieldHeight` each say they are equal "so the
      two line up in one settings row", and decision 9 says 26 was chosen to match
      the segmented control on the same page. **No surface draws both**, so as
      written the justification is false. Keep both tokens — two shapes are two
      measurements, the argument `barPaddingX` already makes — and state the honest
      reason in all three places: the design draws no menu field on a settings page,
      so 26 is chosen to agree with the segmented control's height should a page
      ever draw both, and they are separate tokens because they are separate shapes.
- [ ] No new test: both are comments. Confirm `swift test` stays green, since the
      geometry inventory test reads the token list.

### Task 6: Six passages the branch made untrue

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift` (header only)
- Modify: `docs/architecture/core-theme.md`, `core-zoom.md`, `core-services.md`

- [ ] **The header inventory's bullets.** Rule twenty-seven's bullet lists only the
      Find in Files row and the popover radii and omits the new clause pinning every
      `.frame(` in the commit dialog's `messageBox` to `messageLineHeight`. Rule
      thirty's says "every button in part five (b)'s files is styled" although the
      rule now also enforces part five (c)'s counts and its own message already says
      so. Extend both.
- [ ] **`core-zoom.md`'s Known limits** still lists "the Preferences window's own tab
      bar" among AppKit chrome that stays at the system size at every scale. It is
      now a SwiftUI view reading `\.interfaceMetrics`. Remove it from that list.
- [ ] **`core-zoom.md`'s pin entry** (~512) still describes only the terminal stepper
      with hard-coded bounds. Reword: both Preferences steppers name their zone's
      `ZoomScaleRule`, and the stepper steps through `stepped(_:by:)` — matching
      Task 4's two-half clause.
- [ ] **`core-services.md`** (~244) says the store's font constants survive because
      "the iOS pinch and **both platforms'** Preferences steppers still name them".
      The macOS stepper now names `ZoomScaleRule.editorFont`. Say the iOS pinch, the
      iOS Preferences stepper and the Core `clampFontSize` callers, and drop macOS.
- [ ] **`core-theme.md`'s part five (c) summary** (~1389) lists the rules that gained
      clauses and pins but omits rule eighteen, which this branch also rewrote —
      `sharedSpellingCaseLabels` now pins a per-file count instead of asserting no
      match. Add it.
- [ ] **`core-theme.md`'s shared-field callers paragraph** (~945) still says the Log
      bar routes "its three boxed system controls — the branch menu and the two date
      bounds — through the box". The branch menu is now the shared `ChromeMenuField`
      and no longer builds a box. Correct it to the two date bounds, naming when the
      branch menu left.
- [ ] No new test beyond the header bullets, which the header self-check already
      compares against the rule markers. Confirm `swift test` stays green.

### Task 7: Verify the gates

- [ ] Run every command in **Validation Commands**. All must pass. Report exact
      counts: the Core test total, the app-bundle total, the SwiftLint violation and
      file counts, and both build verdicts.
- [ ] Confirm the rule count and the gated-file count agree in all four places they
      are spelled — the suite's markers, the suite's header inventory,
      `core-theme.md`'s canonical list and `CLAUDE.md`.
- [ ] Confirm `git status --porcelain` is empty.

## Post-Completion

For the acceptance review, needing a human and a running app:

- Open Preferences and confirm the tab bar is separated from the page by a visible
  rule, in both appearances.
- Click the chevron of each menu field — the catalog page's language, the create
  sheet's base, the Log bar's branch — and confirm each opens its menu.
