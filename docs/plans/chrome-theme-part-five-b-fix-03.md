# Chrome theme, part five (b) — fix 03: simplify the three rules that parse expressions

## Overview

Answers revmux round `04-after-fix-02`: four sources, none degraded, five findings,
all minor, all confirmed and all re-derived in the tree. Every one is about the
gate's own machinery; none is about the product.

**This plan removes machinery rather than patching it, and that is its point.**

Three rounds in a row have found that a freshly written gating rule cannot catch
the regression it names. Round 03 found rules thirty-one and thirty-four could not.
Round 04 finds that rule thirty-five — written last round *specifically* to catch
round 03's major — passes a reversed conditional, and that rule thirty-one's
rewrite left three more gaps, all reachable with the identifiers the guarded files
actually write.

What those three rules have in common is that they **parse expressions and decide
semantics** from source text: which type is this receiver, which branch of this
ternary, what sizes this glyph. Every other rule in this suite pins a *set* of file
names by equality, or the presence or absence of a token — and none of those has
failed. A general Swift analyser written in string matching inside XCTest is not
going to converge; each elaboration opens the next gap, and a rule that is believed
and does not hold is worse than no rule.

So: rule thirty-one is replaced by a total rule that needs no type resolution at
all, rule thirty-five is anchored to one shape instead of searching an argument for
two tokens, and the convention that produced the problem is written down so the
next part does not repeat it.

**The simplification is measured, not hoped for.** Every non-layer
`backgroundColor` assignment in the gated set plus `CodeEditorView.swift` was
counted: there are **eight**. Three are inside `CodePaneGround` itself, one is
`EscClosableWindow`'s window ground, one is `MainWindowChrome`'s, two are `.clear`
on the borderless panels, and one is a text attribute rather than a view's
background. A rule that pins those by site and count is total, cannot go vacuous,
and has no `clipView` gap, no alias gap and no suffix heuristic — because it asks
nothing about types.

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-p5b-fix03 test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -configuration Release -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-p5b-fix03 build
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-p5b-fix03 build
swiftlint --strict
```

Derived data never goes inside the repository working tree.

## Context

Files involved:
- `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift` — rules thirty-one and
  thirty-five, the file-level doc comment (~149), and the type-resolution helpers
  this plan deletes.
- `docs/architecture/core-theme.md` — rule thirty-one's and thirty-five's canonical
  entries (~1846), and the conventions paragraph Task 4 adds.
- `CLAUDE.md` — only if a count or a sentence about the rules changes.
- Read only, to confirm the census: `Sources/Pisaka/DiffView.swift` (~560–562),
  `EscClosableWindow.swift` (~39), `MainWindowChrome.swift` (~63),
  `CompletionPanel.swift` (~156), `HoverPanel.swift` (~218),
  `ProjectSearchView.swift` (~404), `CodeEditorView.swift`.

Related patterns:
- The suite's rules that work pin a **set by equality** (`gatedFiles`,
  `colorExemptions`, `diffWashReaders`, `sharedFieldConstructors`) or the presence
  or absence of a **token** (`containsToken`). Follow those, not the expression
  walkers.
- A pinned site carries its reason in the pin, so removing it later is a decision
  someone reads rather than a line someone deletes.
- A rule that cannot decide must fail loudly, never pass.
- Mutation verification uses the **forms the finding says currently pass**, not a
  form the rule was shaped around. That distinction is what round 03 and round 04
  both turned on.

Dependencies: none new.

## Development Approach

- Testing approach: regular, except the gating work, which is mutation-first: each
  rule is shown red against the regression it names *before* it is believed.
- Complete each task fully before the next; `swift test` must pass before the next
  task starts. A task touching app files also builds the macOS app.
- **Deleting capability is allowed and intended.** If the simple rule cannot
  express something the complex one attempted, that loss is accepted — write down
  in the rule's comment what it no longer claims, rather than keeping the machinery
  to preserve a claim that was not holding anyway.
- No new colour role, no new exemption to the colour rules, no new font size.
- No task takes a screen capture, and no task depends on a human opening a window,
  a sheet, a menu or a popover.
- No product or brand names in code, comments, documentation or commit messages.
- Never narrow a rule to make it pass after a widening exposes code: fix the code
  or pin it with its reason.
- CRITICAL: every task includes new or updated tests.

## Implementation Steps

### Task 1: Rule thirty-one becomes total and stops resolving types

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md`

The defects being retired, all confirmed in the tree:
- the resolver never follows a binding from a pane's property, so
  `let clipView = scrollView.contentView` is not a pane. Six such bindings exist
  today: `DiffView.swift:205` and `:391`, `LineNumberRulerView.swift:245`, and
  `CodeEditorView.swift:3089`, `:3197`, `:3222`;
- an unwrapped alias (`if let pane = oursScroll`) is not a pane;
- the name-suffix test runs on **every** receiver, although the helper's comment,
  the rule's comment and `core-theme.md` all say it is a fallback for receivers the
  file never declares;
- the `enclosingScrollView` branch is unreachable.

- [x] Re-census before changing anything: list every non-layer `backgroundColor`
      assignment across the gated set plus `CodeEditorView.swift`. This plan
      counted eight. Report any the census finds that this plan did not, and treat
      a discrepancy as a finding rather than adjusting the number.
      (Census: eight, exactly as counted — none in `CodeEditorView.swift`.)
- [x] Replace the rule with a total one that asks nothing about types: **every**
      non-layer `backgroundColor` assignment in that file set lies inside
      `CodePaneGround`'s brace-matched body, or is one of the pinned sites below.
      Pin them by file **and count**, so a second assignment in a pinned file fails:
  - `EscClosableWindow.swift` — the secondary window's ground (rule twenty-eight).
  - `MainWindowChrome.swift` — the main window's ground, owned by the window-chrome
    rule.
  - `CompletionPanel.swift`, `HoverPanel.swift` — `.clear` on a borderless
    `NSPanel`, which must stay clear for its own rounded layer to draw. Not a code
    pane.
  - `ProjectSearchView.swift` — a text attribute's background, not a view's.
      Each pin carries that reason in the source.
- [x] Delete the type-resolution machinery the rule no longer needs: the pane
      collector, its fixpoint, the suffix test and the dead `enclosingScrollView`
      branch. Keep only what the total rule uses.
- [x] Say in the rule's comment what it no longer claims: it does not identify
      which object is a code pane, because it no longer needs to — it forbids the
      assignment outright outside the sanctioned sites.
- [x] Mutation-verify with the shapes the old rule let through, **each of them**:
      `coordinator.leftText?.backgroundColor = …` in `DiffView.swift`;
      `scroll.backgroundColor = …` inside `MergeView.swift`'s loop;
      `clipView.backgroundColor = …` after one of the six clip-view bindings;
      `pane.backgroundColor = …` under an `if let pane = oursScroll`. All four must
      go red. A second assignment added to a pinned file must also go red. Revert
      each and confirm green, with a clean `git status`.
- [x] Rewrite rule thirty-one's canonical entry in `core-theme.md` to describe the
      total rule and list the five pinned sites with their reasons.
- [x] Run `swift test` and the macOS build. Both must pass.

### Task 2: Rule thirty-five checks which row yields its background

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md`

The defect: for each `listRowBackground` under a selectable `List`, the rule asserts
only that the selection binding's name appears in the argument and that the token
`clear` appears in the argument. It never checks **which branch** gets `clear`, so
every one of these passes while drawing an opaque background on the selected row:

```swift
.listRowBackground(snapshot.fileName == selection.wrappedValue ? chromeColor(.bgPanel) : Color.clear)
.listRowBackground(snapshot.fileName != selection.wrappedValue ? Color.clear : chromeColor(.bgPanel))
.listRowBackground(selection.wrappedValue == nil ? Color.clear : chromeColor(.bgPanel))
```

- [ ] Anchor the check to one shape instead of searching the argument: the
      argument is a conditional whose **condition compares the row's identity with
      the selection binding**, and whose branch taken **when that comparison holds**
      names `clear`. Take the condition as the text before the first top-level `?`
      and the true branch as the text between that `?` and its matching top-level
      `:`; do not attempt to evaluate anything beyond that.
- [ ] Where the shape cannot be recognized, **fail** with a message asking for the
      background to be written in that shape. A rule that cannot decide does not
      decide in favour of the code.
- [ ] Keep the existing non-vacuity anchor (the revisions list must still be seen)
      and add set equality over the gated files that construct a selectable `List`,
      so a new one is a deliberate addition rather than a silent pass.
- [ ] Mutation-verify with **all three forms above**, each separately: each must go
      red. Then the correct form must be green. Revert and confirm a clean
      `git status`.
- [ ] Update rule thirty-five's canonical entry to describe the anchored shape and
      to say plainly that a background written another way fails by design.
- [ ] Run `swift test` and the macOS build. Both must pass.

### Task 3: The suite's own inventory catches up, and the duplicate splitter goes

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md`

- [ ] The file-level doc comment (~149) is the rule inventory `CLAUDE.md` sends
      readers to. It ends at rule thirty-four and has no entry for thirty-five, and
      its rule thirty-four bullet still says a glyph is sized by "a scaled font or
      frame" — the wording the previous round removed, since a metrics frame now
      counts only beside `.resizable()`. Correct both.
- [ ] Rule thirty-five added a second top-level comma splitter beside the one the
      rule thirty-one work had just added. Task 1 deletes much of that machinery;
      once it has, keep exactly one splitter and route both callers through it, or
      state in a comment why two are needed.
- [ ] Extend `testBothSummariesSpellTheSuitesOwnRuleCount`, or add a sibling check,
      so the **suite's own header** is compared against the declared rule count too.
      The header drifted precisely because nothing read it; the two documents are
      checked and it was not.
- [ ] Mutation-verify the new header check: remove a bullet and confirm red;
      restore and confirm green, with a clean `git status`.
- [ ] Run `swift test`. It must pass.

### Task 4: Write down the convention that would have prevented this

**Files:**
- Modify: `docs/architecture/core-theme.md`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift` (doc comment)

- [ ] Record, beside the rules rather than among them, what a gating rule in this
      suite may do: pin a **set** by equality, or assert the **presence or absence**
      of a token through `containsToken`, or take a **brace-matched body** and do
      one of those inside it. It does not resolve types, evaluate conditionals or
      decide which of two branches runs.
- [ ] State the evidence in one short paragraph: three consecutive review rounds
      found that the three rules attempting expression analysis (thirty-one,
      thirty-four, thirty-five) did not catch the regressions they named, while no
      set-equality or token rule in this suite has failed. Name the three so the
      next reader knows which precedents not to copy.
- [ ] State the consequence honestly: a property that cannot be expressed this way
      is not pinned by this suite at all, and belongs in the app-layer bundle or in
      the acceptance review's own reading — not in a rule that claims more than it
      holds.
- [ ] No new test: this is a convention. Confirm `swift test` stays green, since
      the count and canonical-list self-checks read this document.

### Task 5: Verify the gates

- [ ] Run every command in **Validation Commands**. All must pass. Report exact
      counts: the Core test total, the app-bundle total, the SwiftLint violation and
      file counts, and both build verdicts.
- [ ] Confirm the rule count agrees in all the places it is spelled — the suite's
      own markers, the suite's header inventory, `core-theme.md`'s canonical list
      and `CLAUDE.md`.
- [ ] Confirm `git status --porcelain` is empty.

## Post-Completion

For the acceptance review, needing a human and a running app:

- Open the Local History window (⌘⇧H) and click a revision: the row must be visibly
  selected, and it must be the row *Restore* acts on.
- Check the branch and project switcher popovers at 150% and 200% interface scale:
  the three container-font glyphs must still grow with the text beside them.
