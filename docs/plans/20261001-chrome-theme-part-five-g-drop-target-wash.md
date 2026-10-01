# Chrome theme, part five (g): the project tree's drop-target wash becomes a role

## Overview

The project tree paints a drop-target row with `resolving(.accent).opacity(0.4)`, which composes an alpha at the use site. That breaks rule twenty-nine ("a wash's alpha is the palette's"), but the rule does not catch it: its alpha clause only looks for alphas chained onto `nsColor(`, `.color(` or `chromeColor(`. This part settles the conflict between that rule and the closed role set, and the table is what gives. The design states three strengths of the accent wash: a marked surface, a selected row and a drop target. The palette carried only two. The third becomes a role, `dropTargetTint`, set to the accent's own hues at alpha `0x66`. That is exactly 0.4 (102 ÷ 255), so nothing changes on screen. The tree no longer composes an alpha. Rule twenty-nine's alpha clause is strengthened to catch the helper-call form, and this is checked live by mutation. The documents are updated so that what they say in the present tense is true.

## Context

- Files involved:
  - `Sources/PisakaCore/ChromeColorRole.swift`: the closed enum. Its doc comment says "These 21 roles" and "a twenty-second role".
  - `Sources/Pisaka/ChromePalette.swift`: the exhaustive `switch`. Its doc comment says "a twenty-second role added to Core without a pair here".
  - `Sources/Pisaka/ProjectTreeView.swift`: `enum TreeRowBackground` at about line 900, with `role(for:)` and `color(for:resolving:)`. Their doc comments explain the `nil` for `.dropTarget` and the accent at 40 %.
  - `Tests/PisakaCoreTests/ChromeThemeTests.swift`: `XCTAssertEqual(ChromeColorRole.allCases.count, 21)`.
  - `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`: rule twenty-nine (`testTheMergeWashIsCoresOneAnswer`), including its "Known gap" doc comment.
  - `Tests/PisakaAppTests/ChromePaletteTests.swift`: the expected `(dark, light, alpha)` table, for example `.accentTintStrong: (0x4F8DFF, 0x2F6FE0, 0x33)`. It also holds the relation test comparing the inactive selection with the current line, which the new assertion copies.
  - `Tests/PisakaAppTests/TreeRowBackgroundTests.swift`: new file, the mapping's own suite.
  - `docs/architecture/core-theme.md`: these passages:
    - the Core section's "twenty-one" and the canonical role list;
    - the closed-set paragraph;
    - the project-tree-rows passage in "The surfaces restyled so far";
    - part five (f);
    - "What is still waiting";
    - rule twenty-nine's entry in the gating section;
    - the sweep guide at the end.
  - `docs/architecture/app-window.md`: the project-tree entry ("gains none").
  - `CLAUDE.md`: the chrome-theme invariant bullet ("21-case").
- Related patterns:
  - How rule forty-three's mutation check is recorded in `core-theme.md`.
  - The part-entry shape used by parts five (a)–(f).
  - The palette suite's relation test, `testTheInactiveSelectionWashIsNotTheCurrentLineWash`.
  - `Tests/PisakaAppTests` is picked up by `project.yml` as a directory (`sources: [Tests/PisakaAppTests]`). A new file there joins the bundle after `xcodegen generate`.
- Dependencies: none.

### A finding that shapes the rule's strengthening

Read literally, the requirement matches "any call whose balanced argument list spells a role case". Run that way over today's `Sources/Pisaka/`, it catches the tree's `resolving(.accent).opacity(0.4)`. It also catches two chains in `ChromeControls.swift`, at lines 178 and 207. Each is a `.background(RoundedRectangle(…).fill(theme.color(.accent)))` call (lines 174 and 203) followed by `.opacity(isEnabled ? … : 0.5)`. These are view modifiers that dim a whole button, not an alpha on a role's colour. In both, the role sits inside a nested call, not in the `.background(` call's own argument list.

So the clause is limited to a role case spelled at the call's **own** argument depth. That means a leading-dot raw value, matched as a token, at nesting depth one inside the balanced parentheses, and not inside a nested call. This still catches:

- `resolving(.accent).opacity(…)`;
- every chain the old clause caught, such as `theme.color(.x).opacity` and `nsColor(.x, …).withAlphaComponent`.

It does not catch the two button-dimming chains, which is correct. The rule's entry records this scope decision and the reason for it.

## Development Approach

- **Testing approach**: Regular (code first, then tests). Two tests would have caught this change's absence: the strengthened clause, proven by mutation, and the palette relation assertion. The new mapping suite stops the tree from drifting back to composing an alpha.
- Complete each task fully before moving to the next.
- After Task 1, the app target does not compile until Task 2 adds the palette row. That is the exhaustive `switch` doing its job. `swift test` stays green throughout.
- No brand or product names in code, comments, documents, commit messages or the branch name.
- Local Xcode builds use a DerivedData path outside the repository: `~/Library/Developer/Xcode/DerivedData/pisaka-<purpose>`.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: The twenty-second role in Core

**Files:**
- Modify: `Sources/PisakaCore/ChromeColorRole.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeTests.swift`

- [x] Add `case dropTargetTint` to the "Row and line states" group, right after `hoverTint`. Its doc comment says two things:
  - It is the wash a row takes while a drag hovers over it, when the only question being asked is whether the drop lands here.
  - It is stronger than `accentTintStrong` because hover, selection and drop are all true when a drag sits over a selected row. The drop wash is therefore the same hue at a heavier strength.
- [x] Rewrite the enum's doc comment so that it holds:
  - The set has twenty-two roles.
  - The set is closed against *call sites*. It grew once, in part five (g), because the design states a value the table did not carry. A role whose only justification is a call site is still a case for the refusal.
  - `currentLine` and `bracketMatch` are still the two unspent roles.
  - Nothing in the file spells "21", "twenty-one" or "twenty-second" any more.
- [x] Update the `allCases.count` assertion in `ChromeThemeTests` to 22. Grep the Core test tree for any other pin that spells twenty-one for the role set. Leave the `TreeRowState` precedence tests untouched.
- [x] Run `swift test`; it must pass.

### Task 2: The palette row and its relation assertion

**Files:**
- Modify: `Sources/Pisaka/ChromePalette.swift`
- Modify: `Tests/PisakaAppTests/ChromePaletteTests.swift`

- [x] Add the `dropTargetTint` case to the palette's exhaustive `switch`: `0x4F8DFF` dark and `0x2F6FE0` light, both at alpha `0x66`. Its comment says it is the accent's hue at a third strength, above `accentTintStrong`, and names `ProjectTreeView.swift` as the file that uses it.
- [x] Update the palette's doc comment about "a twenty-second role added to Core without a pair here" so the count is right again: either say twenty-third, or drop the number.
- [x] Add `.dropTargetTint: (0x4F8DFF, 0x2F6FE0, 0x66)` to the palette suite's expected table. The existing every-role test then pins the new row in both appearances.
- [x] Add one relation test next to the inactive-selection one. In both appearances, reading the concrete AppKit colour:
  - `dropTargetTint` has the same RGB as `accent`.
  - Its alpha is strictly greater than `accentTintStrong`'s and strictly less than `accent`'s.
  - Its alpha is exactly `0x66`, which is the no-pixel-change claim.
- [x] Confirm the existing "the two themes disagree about every role" test still passes with the new row, since its hue differs between the two themes.
- [x] Build the macOS app target, then run `swift test` and the app-layer bundle; both must pass.

### Task 3: The tree composes no alpha

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`
- Create: `Tests/PisakaAppTests/TreeRowBackgroundTests.swift`

- [x] Make `TreeRowBackground.role(for:)` return `.dropTargetTint` for `.dropTarget`. Only `.plain` still returns `nil`.
- [x] Remove the special case from `color(for:resolving:)`. It returns the state's role where there is one and `Color.clear` otherwise. Both row kinds keep calling this one mapping.
- [x] Rewrite both doc comments:
  - Every state answers with a role or with nothing.
  - `nil` now has only one reason: `.plain` paints nothing.
  - The drop wash's strength now comes from the palette.
  - Remove the "accent at 40 %" and "a wash the closed role set does not name" text, and the stale `color(for:theme:)` reference.
- [x] Create `TreeRowBackgroundTests.swift`. It is macOS-gated and uses `@testable import Pisaka`, like its neighbours. Its doc comment says what it pins: the tree's state-to-role mapping, and that the mapping composes no alpha. It also says what it leaves to other suites: the palette's values are `ChromePaletteTests`' business, and the state precedence is Core's (`TreeRowState`'s tests). The suite asserts:
  - Over `TreeRowState.allCases`, `role(for:)` returns `nil` exactly for `.plain`. `.dropTarget` maps to `.dropTargetTint`, and `.hover`, `.selectedFocused` and `.selectedUnfocused` keep `hoverTint`, `accentTintStrong` and `selectionInactive`.
  - `color(for:resolving:)` with a recording resolver: for every state that has a role, the resolver is asked exactly that role once and its colour comes back unchanged, with no alpha composed. For `.plain`, the resolver is never asked.
- [x] Run `xcodegen generate` so the new file joins the bundle.
- [x] Check that `git grep -n 'opacity(0.4)' Sources/` finds nothing.
- [x] Run `swift test` and the app-layer bundle; both must pass.

### Task 4: Rule twenty-nine sees the helper-call form

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [x] Strengthen the alpha clause in `testTheMergeWashIsCoresOneAnswer`. It reads each gated file's text with comments and literals stripped. An `.opacity` or `.withAlphaComponent` chained onto any call is red when that call's own balanced argument list spells a role case:
  - A role case is a leading-dot raw value from `ChromeColorRole.allCases`, matched as a token at nesting depth one and not inside a nested call.
  - Reuse the existing `balancedEnd(from:in:)` and the walk over whitespace and members.
  - Either keep the `nsColor(`, `.color(` and `chromeColor(` form as it is, or show that the new form covers it.
- [x] The failure message names the file and the call, using the existing wording: "a wash's alpha is the palette's, not one composed at the use site".
- [x] Rewrite the rule's "Known gap" doc comment:
  - The helper-call form is now caught.
  - Record the depth-one scope and its reason: the two button-dimming `.opacity` chains in `ChromeControls.swift`, at lines 178 and 207, are view modifiers whose role sits in a nested call.
  - The local-variable form remains a named gap, because following a value through a `let` needs data flow.
  - Remove the sentence saying the rule "is not strengthened here".
- [x] Run the mutation check live:
  1. Temporarily restore `if state == .dropTarget { return resolving(.accent).opacity(0.4) }` in `ProjectTreeView.swift` and run the gating suite. It must fail and name `ProjectTreeView.swift`.
  2. Restore the file and run it again. It must be green.
  3. Note the result for the documentation task. (Result: with the line restored into `color(for:resolving:)`, the rule failed with "ProjectTreeView.swift chains .opacity onto resolving(…), which spells a role — a wash's alpha is the palette's, not one composed at the use site"; after the restore the suite was green, 61 tests, 0 failures.)
- [x] Check that no count pinned by the gating suite changes: still forty-three rules and still sixty gated files.
- [x] Run `swift test`; it must pass.

### Task 5: The documents say what is now true

**Files:**
- Modify: `docs/architecture/core-theme.md`
- Modify: `docs/architecture/app-window.md`
- Modify: `CLAUDE.md`

- [ ] Update these parts of `core-theme.md`:
  - **Core section:** change "twenty-one" to twenty-two, and add `dropTargetTint` to the canonical role list in the row-and-line-states group.
  - **The closed-set paragraph and the sweep guide's "when a surface seems to need a role that does not exist, it does not":** rewrite both in the present tense. The set is closed against call sites. It grew once, in part five (g), because the design states a value the table did not carry. A role whose only justification is a call site is still a case for the refusal.
  - **The project-tree-rows passage in "The surfaces restyled so far":** the drop target now reads `dropTargetTint` through the one mapping, which composes no alpha and is pinned by `TreeRowBackgroundTests`.
  - **Part five (f)'s closing paragraph:** remove "and now the tree's drop-target alpha".
  - **"What is still waiting":** remove the drop-target item and any cross-references to it. The terminal palette, the caret readout, the lane hues and the unified diff's two departures stay.
  - **Rule twenty-nine's entry:** record the strengthened clause, its depth-one scope and the `ChromeControls.swift` reason. Record the mutation check: red on `ProjectTreeView.swift`, then green again after the restore. Name the local-variable form as the one gap that remains.
  - **A new part five (g) entry**, in the existing part-entry shape. It records:
    - the decision, and why the table gives by one row;
    - the numbers: `0x66` = 102 ÷ 255 = 0.4; the hues `0x4F8DFF` and `0x2F6FE0`; the role count going from 21 to 22; still two unspent roles; still sixty gated files and forty-three rules;
    - the palette relation assertion and the new mapping suite;
    - the mutation check;
    - the gap that remains.
  - **The earlier parts' sentences that say "`ChromeColorRole` stays at twenty-one":** leave them as written.
- [ ] In `app-window.md`, rewrite the project-tree entry's "gains none" sentence. The drop target now maps to `dropTargetTint` through `TreeRowBackground`, which composes no alpha and is pinned by `TreeRowBackgroundTests`.
- [ ] In `CLAUDE.md`, change "21-case" to 22-case. Keep the claim only and stay under the 60,000-character ceiling.
- [ ] Run the acceptance greps:
  - `git grep -n 'twenty-one\|21-case\|21 roles' Sources/PisakaCore/ChromeColorRole.swift CLAUDE.md` finds nothing.
  - The canonical list names twenty-two roles.
  - Any count the gating suite pins against the document agrees.
- [ ] Run `swift test`; it must pass, including `LintConfigurationTests` and the gating suite's checks against `core-theme.md`.

### Task 6: Verify acceptance criteria

- [ ] `swift test` is green.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`, with DerivedData outside the repository, is green, including `TreeRowBackgroundTests`.
- [ ] `swiftlint --strict` from the repository root is clean.
- [ ] The macOS build with `-configuration Release` and the iOS Debug build (`generic/platform=iOS`) are both green.
- [ ] `git grep -n 'opacity(0.4)' Sources/` finds nothing.
- [ ] Rule twenty-nine's entry in `core-theme.md` records the mutation check against `ProjectTreeView.swift`.

### Task 7: Update documentation

- [ ] `README.md` and `docs/FEATURES.md` need no change, because nothing is user-visible.
- [ ] `CLAUDE.md` needs only the role count, done in Task 5. Confirm nothing else there restates the count.
