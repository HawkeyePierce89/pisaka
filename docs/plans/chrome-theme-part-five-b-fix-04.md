# Chrome theme, part five (b) — fix 04: three edits, and the convention made true

## Overview

Answers revmux round `05-after-fix-03`: four sources, none degraded, three
findings, all minor, all confirmed and all re-derived in the tree. None is about
the product; all three are about the gating suite and the document describing it.

**This is the last fix round on this branch, and no review round follows it.** The
revmux chain stops at five rounds by its own rule, and it has earned the stop: the
last three rounds found zero defects in the application and twelve in the suite
that guards it. The acceptance review (`ticket-to-plan:review`) is the next reading,
and it reads the branch against the plan rather than the diff against itself.

Two of the three findings are mine rather than the executor's, and they are why
this round exists instead of being deferred:

- Rule thirty-five still does not hold what it claims. It was written for the one
  major finding on this branch, and it still passes a spelling that gives the
  selected row an opaque background.
- The convention I asked for in fix 03 contradicts itself. It says a rule "does not
  resolve types, evaluate conditionals or decide which of two branches runs" and
  then calls rule thirty-five's branch-picking rewrite a permitted shape. A
  convention meant to restrain the next part is broken in the sentence that states
  it.

**One decision settles both.** Rather than granting a fourth shape or an exception,
rule thirty-five is reduced to the first permitted shape: it pins the background
expression by **set equality**, one entry per selectable list. No spelling escapes,
because any spelling other than the pinned one fails — which is strictly stronger
than the anchored conditional it replaces, and needs no branch picking at all.

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-p5b-fix04 test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -configuration Release -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-p5b-fix04 build
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-p5b-fix04 build
swiftlint --strict
```

Derived data never goes inside the repository working tree.

## Context

Files involved:
- `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift` — rule thirty-five
  (~3276–3300), the header self-check (~3565–3578), and the header's own
  convention paragraph (~31–38, ~165).
- `docs/architecture/core-theme.md` — rule thirty-five's canonical entry and the
  convention paragraph (~1955–1982).
- Read only: `Sources/Pisaka/LocalHistoryView.swift` (~159–167), the one selectable
  list in the gated set.

Related patterns:
- Set equality is this suite's strongest and most-used shape (`gatedFiles`,
  `colorExemptions`, `diffWashReaders`, `sharedFieldConstructors`). It is total by
  construction: anything not in the set fails, without the rule understanding why.
- A pinned expression carries its normalized form, so a reformat fails loudly and a
  person looks. That is the safe direction of failure.
- A check's **message** is part of what it claims. A message promising more than the
  assertion tests is the same defect as a rule that cannot go red.

Dependencies: none new.

## Development Approach

- Testing approach: mutation-first for the rule work — each rule is shown red
  against the regression it names before it is believed.
- Complete each task fully before the next; `swift test` must pass before the next
  task starts. A task touching app files also builds the macOS app.
- **No new machinery.** This round only removes or narrows. If a task seems to need
  a new parser, helper or heuristic, stop and say so rather than writing one — that
  instinct is what the convention exists to catch.
- No source file outside the suite and the two documents changes. `LocalHistoryView`
  is already correct and is read, not edited.
- No task takes a screen capture, and no task depends on a human opening a window.
- No product or brand names in code, comments, documentation or commit messages.
- CRITICAL: every task includes new or updated tests.

## Implementation Steps

### Task 1: Rule thirty-five pins the background by set equality

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md`

The defect: the rule asks whether the branch taken when the row equals the selection
*contains* the token `clear`, not whether it *is* `clear`. `ternaryParts` also skips
nested ternaries by design. So both of these pass while giving the selected row an
opaque background:

```swift
.listRowBackground(snapshot.fileName == selection.wrappedValue
    ? (isActive ? Color.clear : chromeColor(.bgPanel)) : chromeColor(.bgPanel))
.listRowBackground(snapshot.fileName == selection.wrappedValue
    ? flag ? Color.red : Color.clear : chromeColor(.bgPanel))
```

- [x] Replace the anchored-conditional machinery with a pinned set: for each gated
      file that constructs a `List` binding `selection:`, the whitespace-normalized
      text of every `listRowBackground` argument must equal the entry pinned for
      that file. Assert by **set equality in both directions**, so an unpinned list
      and a changed expression both fail.
- [x] Seed the set with the one selectable list that exists today,
      `LocalHistoryView.swift`, taking its expression verbatim from the source.
- [x] The failure message says what to do: the expression changed, so a person must
      confirm the selected row still yields its background and then update the pin.
      Say in the comment that a reformat fails too, and that this is deliberate —
      the rule cannot read the expression, so it refuses to guess.
- [x] Delete `ternaryParts`, `comparesRow` and anything else only the old rule used.
      Do not keep a helper "in case".
- [x] Mutation-verify with **both spellings above** plus the three from the previous
      round (inverted branches, a negated comparison, a condition on something other
      than row identity) — five in all. Each must go red. Then the shipped
      expression must be green. Add a second selectable list without pinning it and
      confirm red. Revert each and confirm a clean `git status`.
- [x] Rewrite rule thirty-five's canonical entry to describe the pin, and say
      plainly what it no longer attempts: it does not read the conditional.
- [x] Run `swift test` and the macOS build. Both must pass.

### Task 2: The convention becomes true

**Files:**
- Modify: `docs/architecture/core-theme.md` (~1955–1982)
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift` (header, ~31–38, ~165)

The defect: the convention allows three shapes — pin a set by equality, assert a
token, or do either inside a brace-matched body — and adds that a rule "does not
resolve types, evaluate conditionals or decide which of two branches runs". Two
paragraphs later it says rules thirty-one and thirty-five "have since been rewritten
into the permitted shapes — a total ban with pinned sites, one anchored conditional
that fails when it cannot be read". An anchored conditional is none of the three,
and the same passage calls those rules "the precedents not to copy" while listing
one as permitted.

After Task 1 the contradiction has a clean resolution: rule thirty-five is a pinned
set, which *is* the first shape.

- [ ] Correct the passage to say rule thirty-five was reduced to a pinned set, not
      to an anchored conditional. The three shapes stand; no fourth is added and no
      exception is granted.
- [ ] Keep rule thirty-four named as the one rule that still reads a modifier chain,
      and keep it flagged as narrowed rather than extended — that part was accurate.
- [ ] Make the same corrections in the suite's own header, which carries the
      convention twice.
- [ ] Re-read the whole passage once it is edited and confirm no sentence in it now
      describes a rule that does not exist in that form. Report anything else it
      claims that the suite does not do.
- [ ] No new test: this is prose. Confirm `swift test` stays green — the count and
      canonical-list self-checks read this document.

### Task 3: The header self-check claims exactly what it tests

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

The defect: `testTheSuitesHeaderInventoriesEveryRule` counts the `/// - **` bullets
between the inventory's opening sentence and the class declaration and compares that
count with `declaredRuleCount()`. Its message promises "one bolded bullet per
declared rule (N), **in the same order**". Neither order nor correspondence is
tested, so swapping two bullets stays green, and so does dropping a real rule's
bullet while keeping one for a rule that no longer exists.

- [ ] Prefer the stronger fix if it is cheap: compare the **ordered list of bolded
      bullet titles** against the **ordered list of rule-marker titles**, both
      normalized. This is two ordered lists compared, which is the set-equality
      shape, not expression analysis — it does not violate the convention.
- [ ] If the two vocabularies cannot be made to match without rewording every rule
      marker or every bullet, do not force it: state the check honestly as a count
      instead, drop "in the same order" from the message and from `core-theme.md`,
      and say in the comment what the count does not catch. **Do not leave the
      stronger claim beside the weaker test.**
- [ ] Say in the commit message which of the two was done and why.
- [ ] Mutation-verify whichever landed: for the ordered comparison, swap two bullets
      and confirm red, and replace one bullet's title with a rule that does not
      exist and confirm red; for the count, remove a bullet and confirm red. Revert
      and confirm green, with a clean `git status`.
- [ ] Run `swift test`. It must pass.

### Task 4: Verify the gates

- [ ] Run every command in **Validation Commands**. All must pass. Report exact
      counts: the Core test total, the app-bundle total, the SwiftLint violation and
      file counts, and both build verdicts.
- [ ] Confirm the rule count agrees in all four places it is spelled — the suite's
      markers, the suite's header inventory, `core-theme.md`'s canonical list and
      `CLAUDE.md`.
- [ ] Confirm `git status --porcelain` is empty.

## Post-Completion

For the acceptance review, needing a human and a running app:

- Open the Local History window (⌘⇧H) and click a revision: the row must be visibly
  selected, and it must be the row *Restore* acts on.
- Check the branch and project switcher popovers at 150% and 200% interface scale:
  the three container-font glyphs must still grow with the text beside them.
- Open the commit dialog, a merge window, a diff window and a source viewer in both
  appearances, and switch the Theme preference while each is open.
