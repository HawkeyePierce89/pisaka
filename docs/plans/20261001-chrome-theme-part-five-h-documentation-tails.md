# Chrome theme, part five (h): documentation tails

## Overview

A documentation-only cleanup of three statements left over from the part five (h)
acceptance review. Each one contradicts another statement in the repository or the
code it describes. Nothing under `Sources/` changes. In the test tree only doc
comments in `ChromeThemeSourceGatingTests.swift` change. The work fixes three things:

1. The open-items verdict on the dark ANSI-16 set: it should say *worse*, not
   "as poor".
2. The count of literal-keeping scanner exceptions in `CLAUDE.md`. It is stale and
   nothing pins it. The fix is to stop counting and state the rule instead. The
   theme suite's header also gets its own inventory of these exceptions.
3. The rule forty-four mutation record. The doc entry and the test doc comment
   quote two failure messages, but the run emits three. The fix re-runs the
   mutation and quotes all three as the run prints them.

## Context

- Files involved:
  - `docs/architecture/core-theme.md`: the "What is still waiting" open-items
    paragraph (around line 2267, "are as poor on `0x1E1F22` as they were on
    black"), and the rule forty-four entry (around line 3154, "Verified by
    mutation: …").
  - `CLAUDE.md`: Tests section, the second of the three conventions bullets
    (around lines 432–436, "There are **five such exceptions** today … A sixth
    needs the same statement somewhere a reader will find it.").
  - `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`:
    - the suite header (lines 1–230), which says flatly that "comments and string
      literals are stripped before anything is matched";
    - the query-toggle name rule `testQueryTogglesSpeakOneNamePerMode`
      (~line 2826);
    - the merge editor's chevron check inside
      `testTheCommitDialogsRowsAndControls` (~line 3807);
    - clause (c) of `testAServedPagesChromeIsThePalettes` and its doc comment
      (~line 4757, "the fifth stated exception");
    - the doc comment of
      `testTheTerminalsExemptionSheltersItsTwoANSIArraysAndNothingElse`
      (~lines 5075–5080).
  - `Sources/Pisaka/TerminalTheme.swift`: mutated temporarily for requirement 3
    (line ~182, `caret: ChromePalette.nsColor(.accent, in: appearance)`), then
    restored byte-identical.
- Related patterns: the other four suites that read the literal-keeping scanner
  `GitHubSourceGatingTests.strippingComments(_:)` already state their exception
  in their own header:
  - `GitHubSourceGatingTests` (header ~line 16–20);
  - `LeetCodeAccountSourceGatingTests` (~line 88);
  - `MarkdownPreviewSourceGatingTests` ("The one stated exception", ~line 76);
  - `MenuShortcutUniquenessTests` (~line 28).

  `ReleaseWorkflowTests`' build-output-root rules state their exception in
  `.github/workflows/release.yml` (~line 510). The theme suite's new header
  paragraph follows the same convention.
- Dependencies: none.

## Decision for requirement 2

The plan drops the bare number. It does not pin a count. Reasons:

- What the sentence counts is "suites (or rule families) that read a
  literal-keeping scanner". A test could only derive that by parsing Swift call
  sites and grouping them by suite, and even then "an exception" has no crisp
  unit. The theme suite alone has three such rules, while the release rules live
  in YAML.
- `CLAUDE.md`'s own convention is "prefer set equality to counting; where a count
  is the only shape, pin it cross-file". Here a count is not the only shape: the
  property that matters is that every literal-keeping reading states its reason
  where a reader will find it. That property can be stated without a number.

The inventory therefore lives where it already partly lives: each suite's own doc
comment, plus `release.yml` for the workflow rules. `CLAUDE.md` points there. The
"A sixth needs…" sentence is rewritten as a forward rule: a new literal-keeping
reading owes the same statement. The rewrite is shorter than today's text, so the
`CLAUDE.md` size bound (60,000 characters; currently about 49,800) is not at risk.

## Development Approach

- **Testing approach**: Regular. No behaviour changes, so no new tests. The
  existing gates are the check: `swift test`, including `LintConfigurationTests`
  and its `CLAUDE.md` size bound, and `swiftlint --strict`.
- Complete each task fully before moving to the next.
- Reword only the sentences the three findings name. Do not touch neighbouring
  prose in `core-theme.md` or `app-terminal.md`.
- No product or brand names in docs, comments or commits. Commit messages
  describe the change in plain words.
- Keep new doc-comment lines within the configured SwiftLint line length.
- **CRITICAL: every task MUST include new/updated tests.** For this
  documentation-only ticket that means re-running the existing gates; adding new
  tests is out of scope.
- **CRITICAL: all tests must pass before starting next task.**

## Implementation Steps

### Task 1: Read the three rule forty-four mutation messages off a live run

**Files:**
- Modify (temporarily, then restore): `Sources/Pisaka/TerminalTheme.swift`

- [x] Replace the caret's `ChromePalette.nsColor(.accent, in: appearance)` with
  `NSColor.selectedContentBackgroundColor`. That is the mutation the acceptance
  review ran.
- [x] Run `swift test --filter ChromeThemeSourceGatingTests/testTheTerminalsExemptionSheltersItsTwoANSIArraysAndNothingElse`.
  Copy every failure message verbatim, keeping only the message text after the
  assertion's own prefix. Expect three, each naming `TerminalTheme.swift`. If the
  count is not three, record what the run actually printed and note the
  difference in the progress log.
- [x] Restore the file with `git checkout -- Sources/Pisaka/TerminalTheme.swift`,
  and confirm `git diff --quiet master -- Sources/Pisaka/TerminalTheme.swift`.
- [x] Re-run the same filtered test: it must be green.

### Task 2: Record all three messages in the rule forty-four entry and the test doc comment

**Files:**
- Modify: `docs/architecture/core-theme.md`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [x] In `core-theme.md`'s rule forty-four entry, rewrite the "Verified by
  mutation" sentence so it quotes the three messages from Task 1 verbatim. Leave
  the rest of the entry untouched.
- [x] In the doc comment of
  `testTheTerminalsExemptionSheltersItsTwoANSIArraysAndNothingElse`, rewrite the
  "Verified live by mutation" paragraph the same way. Use the same three messages
  and say which assertion each comes from.
- [x] Run `swift test` and `swiftlint --strict`; both must be clean.

### Task 3: One verdict on the dark ANSI-16 set

**Files:**
- Modify: `docs/architecture/core-theme.md`

- [ ] In the "What is still waiting" paragraph, replace "are as poor on
  `0x1E1F22` as they were on black" with a *worse* verdict. It should carry the
  same sense as the part five (h) entry (~line 2218) and `app-terminal.md`
  (~line 76): poorer on the canvas than on the black they were tuned for. Do not
  restate or recompute any ratio beyond the three already in that sentence.
- [ ] Verify that `grep -n "as poor" docs/architecture/core-theme.md` returns
  nothing.
- [ ] Run `swift test`; it must be green.

### Task 4: State the theme suite's literal-keeping rules where a reader finds them

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [ ] In the suite header, right after the paragraph claiming comments and string
  literals are stripped, add a paragraph naming the exceptions. Follow the
  convention of the other four suites' headers. The paragraph should say that
  three rules read `GitHubSourceGatingTests.strippingComments(_:)`, which removes
  comments and keeps string literals, because each rule's subject *is* a literal:
  - the query-toggle name rule (`testQueryTogglesSpeakOneNamePerMode`): the
    `help:` names are literals;
  - the merge editor's chevron check in `testTheCommitDialogsRowsAndControls`:
    the chevrons are found by symbol names, which are literals;
  - clause (c) of `testAServedPagesChromeIsThePalettes`: a CSS hex value is a
    string literal.

  Every other rule reads the ordinary scanner. Soften the flat "stripped before
  anything is matched" claim so it no longer contradicts the new paragraph.
- [ ] In clause (c)'s doc comment, replace "**Clause (c) is the fifth stated
  exception to the stripped reading.**" with wording that does not number itself,
  for example that it is one of the suite's literal-keeping readings named in the
  header. Keep the rest of that paragraph's reasoning.
- [ ] Verify that `grep -n "fifth stated exception" Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
  returns nothing.
- [ ] Run `swift test` and `swiftlint --strict`; both must be clean.

### Task 5: Drop the bare count from CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] Rewrite the second Tests-conventions bullet. Keep its first clause: a rule
  whose subject is a literal reads a scanner that keeps literals, or it deletes
  the very text it checks. Replace "There are **five such exceptions** today: … A
  sixth needs the same statement somewhere a reader will find it." with the rule
  itself. Every such reading states its reason where a reader will find it: in
  its suite's doc comment, or at the site the rule is about
  (`ReleaseWorkflowTests`' build-output-root rules state theirs in
  `release.yml`). That inventory is the record, and a new literal-keeping reading
  owes the same statement. Use no number.
- [ ] Verify that `grep -n "five such exceptions" CLAUDE.md` returns nothing and
  that no other bare count of literal-keeping exceptions remains in `CLAUDE.md`.
  Confirm the file got shorter, not longer.
- [ ] Run `swift test`; it must be green, and `LintConfigurationTests` must stay
  green including the size bound.

### Task 6: Verify acceptance criteria

- [ ] Run `swift test`; the whole suite must be green.
- [ ] Run `swiftlint --strict` from the repository root; it must be clean.
- [ ] Run each grep from the ticket's acceptance criteria:
  - "as poor" in `core-theme.md`: no output;
  - "five such exceptions" in `CLAUDE.md`: no output;
  - "fifth stated exception" in the theme suite: no output.
- [ ] Confirm that the rule forty-four entry and the test doc comment both quote
  the same three messages from Task 1.
- [ ] Run `git diff master -- Sources/` and confirm it is empty. In particular,
  `TerminalTheme.swift` must be byte-identical to `master`.
- [ ] After committing, confirm `git status --porcelain` is empty.

### Task 7: Update documentation

- [ ] `README.md`: no change (nothing user-facing).
- [ ] `CLAUDE.md`: already updated in Task 5. No other internal pattern changes.
