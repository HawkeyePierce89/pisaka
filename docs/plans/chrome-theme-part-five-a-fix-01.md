# Chrome theme, part five (a) — fix 01: the acceptance review's findings

## Overview

This plan answers the acceptance review of the part five (a) branch
(`chrome-theme-part-five-a-popovers-and-search-surfaces`). No revmux round exists
for this branch — the only review before the acceptance one was the executing
agent's own — so every finding below was found by reading the branch against its
plan and verifying the mechanism by hand.

One finding is a live defect: the Find in Files match row was given a fixed,
interface-scaled height while its content is drawn at the *code* font, so the row
overflows from a code font of 24 upward on a supported range of 8 to 32, and the
row is itself a code zoom surface — zooming the very text it draws is what breaks
it. Measured against `NSLayoutManager.defaultLineHeight(for:)`: code font 20 needs
23.0 points and fits inside 24; code font 24 needs 28.0 and does not; code font 30
needs 35.0.

The rest are consistency defects introduced by the same sweep: the three
query-mode toggles now differ in size and colour between the two windows that
draw them, the shared field imposes one text size on every caller, the two AppKit
popovers round their corners at a fixed radius while everything around them
scales, and the recent-searches menu keeps a `Divider()` that the repository's own
idiom — and this very branch, in `ProjectTreeView.swift` — replaced with
`Section` everywhere else.

The gates were green on the branch as reviewed, and must stay green: Core 5758
tests, the app bundle 122, SwiftLint 0 violations over 588 files, the macOS
Release build and the iOS build both succeeding. Each of the four gating rules
this branch added was verified red against a deliberate mutation, so nothing
below may weaken them.

Language: this plan is written in English, and so is every comment and document
it changes.

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-fix01 test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -configuration Release -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-fix01 build
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-fix01 build
swiftlint --strict
```

Derived data never goes inside the repository working tree.

## Context

Files involved:
- `Sources/Pisaka/ProjectSearchView.swift` — the match row (`row(result:index:)`,
  ~line 367), the toggle builder (~line 282), the three fields, `SearchLayout`.
- `Sources/Pisaka/SearchBarView.swift` — the toggle builder (~line 219), the two
  fields.
- `Sources/Pisaka/ChromeControls.swift` — the shared box, field and secondary
  button; gains the shared toggle.
- `Sources/Pisaka/CompletionPanel.swift` (~line 160) and
  `Sources/Pisaka/HoverPanel.swift` (~line 225) — the layer corner radius.
- `Sources/Pisaka/SearchHistoryMenu.swift` — the menu's separator.
- `Sources/Pisaka/BranchSwitcherView.swift`, `Sources/Pisaka/ProjectSwitcherView.swift`
  — the duplicated sentence, and the branch filter field's text size.
- `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift` — rules twenty-four,
  twenty-six and the new twenty-seven, plus the count bookkeeping.
- `docs/architecture/core-theme.md`, `docs/architecture/app-editor.md`, `CLAUDE.md`.

Related patterns:
- A measurement belongs to exactly one zone. `metrics.scaled(_:)` is the
  interface zone; `settings.fontSize` is the code zone. The existing comment on
  the match row states the row is a code surface, and `ZoomSourceGatingTests`
  pins that marker — this plan does not change either.
- The divergence between two copies of one control is what
  `ChromeControls.swift` exists to prevent. The field shape is the precedent; the
  toggle is the same argument.
- A menu's separator is a `Section` boundary in this repository:
  `LocalChangesView.swift` since part four (b), and both context menus in
  `ProjectTreeView.swift` since this branch.
- Gating rules read comment- and literal-stripped text and match multi-line calls
  with a whitespace-tolerant regular expression or a brace-matched body
  (`matchedBody(after:in:)`), never a contiguous substring.

Dependencies: none new.

## Development Approach

- Testing approach: regular, except the gating rules. Each new or changed rule is
  first shown red against a deliberately broken local edit, then reverted and
  shown green. A rule that cannot be made red is not a rule.
- Complete each task fully before moving to the next; `swift test` must pass
  before the next task starts.
- No task takes a screen capture, and no task depends on a human opening a menu,
  a popover or a window.
- No new role and no new exemption. No font size in `ChromeGeometry`, and none in
  a per-file layout table either — that table is the same thing under another
  name, which is the defect Task 2 removes.
- Read each file's `docs/architecture/` entry before modifying it.
- No product or brand names in code, comments, docs or commit messages.
- CRITICAL: every task includes new or updated tests.

## Implementation Steps

### Task 1: The match row keeps the code zone's height

The defect: `ProjectSearchView.swift:401` pins the row to
`metrics.scaled(SearchLayout.rowHeight)` — 24 points times the *interface* scale
— while both `Text`s inside it are sized by `settings.fontSize`, the *code* font.
From a code font of 24 the text no longer fits, and the row draws over its
neighbours; below that, at a raised interface scale, the row is taller than its
content for no reason. The design's 24 describes a mock drawn at a fixed
12-point monospaced line, not the user's code font.

- [x] Delete the `.frame(height:)` on the match row. The row's height goes back to
      being whatever its content needs, which is what it was before this branch.
- [x] Keep the leading and trailing paddings, and move `.contentShape(Rectangle())`
      so it comes *after* them: it currently sits before, so the 34 points of
      leading inset the branch added are not part of the row's click target.
- [x] `SearchLayout.rowHeight` loses its only reader — delete the token rather
      than leaving it unread.
- [x] Leave the group header's own `headerHeight` alone: that row is drawn at
      `callout`, an interface size, so an interface-scaled height is correct there.
      Say so in one line beside it, because the two neighbouring rows now treat
      height differently on purpose.
- [x] The row keeps `ZoomSurfaceMarker(kind: .code)` and its explanatory comment.
- [x] Run `swift test` and the macOS build.

### Task 2: One query-mode toggle, drawn once

The defect: `SearchBarView.swift:219` and `ProjectSearchView.swift:282` are two
copies of one control, and they have diverged. The find bar draws its label at
`subheadline` (11 points) and `textPrimary` when off; Find in Files draws it at a
raw `16` taken from `SearchLayout.toggleFontSize` and `textSecondary` when off.
The 16 came from the design's toggle *icons*, which are 16 by 16 — an icon box
read as a font size, so the labels are half again as large as every neighbour.
The comment on master that said the two toggles matched was deleted along with
the match.

- [x] Add a shared query-mode toggle to `ChromeControls.swift`, taking the label,
      an `isOn` binding and the help text. It draws the label at `subheadline`,
      semibold, monospaced; `accent` on an `accentTint` ground while on;
      `textPrimary` and no ground while off; and it carries the spoken name, the
      tooltip and the on/off `accessibilityValue` both copies already had.
- [x] Both surfaces call it. Delete both private `toggle(_:isOn:help:)` builders
      and `SearchLayout.toggleFontSize`.
- [x] Extend rule twenty-six — already the "one field shape" rule — so that it is
      the "one shape per control" rule: the set of gated files constructing the
      shared toggle equals {`SearchBarView.swift`, `ProjectSearchView.swift`}, and
      no gated file outside `ChromeControls.swift` declares a toggle builder of
      its own. Keep its existing field clauses untouched.
- [x] Show the extended rule red against a local edit that reinstates a private
      toggle builder in one of the two surfaces, then revert.
- [x] Run `swift test` and the macOS build.

### Task 3: The shared field carries its caller's text size

The defect: `ChromeThemedTextField` fixes `.callout` for every caller. That is
the Log filter bar's own size, so lifting the shape silently shrank the branch
switcher's filter field from `body` to `callout`, and it draws the Find in Files
query, replace and file-mask fields at 12 where the design states 13.

- [x] Give the shared field a text-style parameter defaulting to `.callout`, so
      the Log filter bar's pixels stay exactly as they are.
- [x] Find in Files' three fields and the branch switcher's filter field pass
      `.body`, restoring the switcher's previous size and matching the design.
- [x] The field's inner gap — currently the bare `6` inside the shared view — takes
      the same treatment as the padding: a parameter with the Log filter bar's
      value as the default, so a future caller is not silently given a number that
      belongs to another surface.
- [x] Extend `ChromeThemeTests`' token inventory if any new token is introduced;
      prefer a parameter over a token where the number belongs to one caller.
- [x] Run `swift test` and the macOS build.

### Task 4: The popovers' corner radius follows the interface scale

The defect: both AppKit panels assign `ChromeGeometry.cornerRadiusMax` to the
layer unscaled (`CompletionPanel.swift:160`, `HoverPanel.swift:225`), so at a
raised interface scale the popover keeps six-point corners while everything
drawn inside it grows. The stated exception for an unscaled token covers
`hairlineWidth` — a hairline is one point by definition — and not a radius.

- [x] Set the corner radius where the interface metrics are known. Both panels
      receive `InterfaceMetrics` in their `show(…)` path and not in `makePanel()`,
      so the radius is applied there, beside the size the panel is already given.
      It is a plain number rather than a `CGColor`, so it does not belong inside
      the drawing-appearance block and must not be moved into one.
- [x] The border width stays unscaled, and the comment says why: the hairline is
      the stated exception, the radius was not.
- [x] Run `swift test` and the macOS build.

### Task 5: The menu joins the `Section` idiom, and rule twenty-four loses its exception

The defect is an inconsistency this branch created and then enshrined. The
repository's idiom for a separator inside a menu is a `Section` boundary —
`LocalChangesView.swift` has done it since part four (b), and this branch
converted both of `ProjectTreeView.swift`'s context menus to it. Yet
`SearchHistoryMenu.swift` keeps a literal `Divider()`, and rule twenty-four
blesses it by name and pins a comment to justify it. Two menus, two answers.

- [ ] `SearchHistoryMenu` groups its rows and its *Clear History* button into two
      `Section`s. The rendered separator is unchanged; the `Divider()` and the
      comment pinning the exception both go.
- [ ] Rule twenty-four becomes exception-free: **no** gated file spells
      `Divider(`. Drop the owner set, the per-file count and the pinned-comment
      assertion.
- [ ] Give the rule a non-vacuity clause in their place, or it becomes an
      assertion that nothing is nothing: every gated file that builds a `Menu`
      — `SearchHistoryMenu.swift`, `ProjectTreeView.swift`, `LocalChangesView.swift`
      — spells `Section` at least once, pinned by set equality so a fourth menu
      file has to be added deliberately.
- [ ] Show the rewritten rule red twice: once with a `Divider()` put back in the
      menu, and once with a `Section` removed from one of the three. Revert both.
- [ ] Delete the duplicated sentence in `BranchSwitcherView.swift` and
      `ProjectSwitcherView.swift`: each states "the popover's arrow keeps the
      system material, because the content background cannot reach it" twice, once
      in the doc comment and again as an inline comment two lines below. Keep the
      doc comment's copy.
- [ ] Run `swift test` and the macOS build.

### Task 6: Rule twenty-seven — each measurement follows its own zone

The rule that would have caught Task 1, generalized to cover Task 4 as well,
since both are the same mistake in opposite directions: a chrome measurement that
does not follow the interface scale, and a code-zone measurement that does.

- [ ] Add rule twenty-seven with two clauses:
      - the match row's brace-matched body in `ProjectSearchView.swift` names
        `settings.fontSize` and spells no `.frame(` height at all — matched over a
        brace-matched body so a multi-line call cannot slip past, the mistake part
        four (b) shipped with rule twenty-one;
      - each `cornerRadius` assignment in `CompletionPanel.swift` and
        `HoverPanel.swift` names `metrics` on the same statement.
- [ ] Both clauses carry a non-vacuity check: the row's body must be found and
      must name `settings.fontSize`, and each panel must have at least one
      `cornerRadius` assignment.
- [ ] Show the rule red three times — a `.frame(height:)` restored on the match
      row, the same written across two lines, and an unscaled radius restored in
      one panel — then revert each.
- [ ] Update the suite's header bullet list and its `spelled` count to
      twenty-seven.
- [ ] Run `swift test`.

### Task 7: Documentation and the count bookkeeping

- [ ] `core-theme.md`: the canonical rule list opens at twenty-seven and gains
      rule twenty-seven; rule twenty-four's entry loses the menu exception; the
      part five (a) record gains what this fix changed — the match row's height,
      the one shared toggle, the field's text-style parameter, the scaled radius
      and the menu's `Section`s — stated as corrections to that part rather than
      as a new part.
- [ ] `CLAUDE.md`: the chrome invariant says twenty-seven rules and lists the new
      one; the `Divider()` clause drops its "(the menu's)" exception. The gated
      file count stays thirty-four and the unspent roles stay three.
- [ ] `app-editor.md`: the find bar and the Find in Files window gain the shared
      toggle and the match row's zone rule.
- [ ] The three count assertions — the suite, `CLAUDE.md`, `core-theme.md` — agree.
- [ ] Run `swift test`.

### Task 8: Verify the gates

- [ ] `swift test` is green, with a test count no lower than 5758.
- [ ] The app bundle is green at 122 tests.
- [ ] `swiftlint --strict` is clean from the repository root.
- [ ] The macOS Release build and the iOS build both succeed, with derived data
      outside the repository.
- [ ] Grep-confirm: `gatedFiles` still has 34 entries; `colorExemptions` and
      `roleNamingExemptions` are unchanged; no gated file spells `Divider(`;
      `bgPopover` still has five readers; `ZoomSourceGatingTests` is untouched;
      no `toggleFontSize` and no `rowHeight` remain in `SearchLayout`.
