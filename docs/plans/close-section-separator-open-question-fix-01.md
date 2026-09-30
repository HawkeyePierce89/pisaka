# Fix plan 01: the probe "drew" nothing — say so everywhere the document says otherwise

## Overview

This plan answers revmux round `01-initial` on the branch `close-section-separator-open-question`. The round confirmed two findings, both minor, both in `docs/architecture/core-theme.md`, and both of one shape: the branch added a sentence saying the `Commands` probe "was a structural measurement, not a screen capture … nothing it saw was drawn on a screen", while two sentences that predate the branch still say that probe *drew* separators. The branch is what makes them contradict each other, and the ticket's requirement 3 asked for exactly this qualification, so the branch does not yet meet its own acceptance.

Documentation only. No Swift source, test, resource or configuration file changes. The two Swift sites that carry the same unqualified sentence (`LeetCodeOpenProblemSheet.swift`, `ChromeThemeSourceGatingTests.swift`) stay as written; the document already records them.

## Validation Commands

- `swift test` — the Core gate reads `docs/architecture/core-theme.md` through `#filePath` (rule count, canonical list, sweep-closure scan); it must stay at 5820 tests, 0 failures.
- `git diff --stat master..HEAD` — only `docs/architecture/core-theme.md` and files under `docs/plans/` change.
- `grep -n -i -E 'dr(e|a)w(n|s)? .{0,40}separator' docs/architecture/core-theme.md` — after the fix, no hit may say the `Commands` probe drew a separator; the hits that remain are about the in-window menus measured on screen or about `Divider()` being drawn in the system's separator value.

## Development Approach

- Voice as the document's: measured facts with their numbers, the limit of the measurement beside them. No brand or product names. Do not cite the review round, the ticket, the session or any external file in the document.
- A prose defect has no test that can pin it; the check that would have caught both findings is the grep above, run over the whole document rather than the search terms the previous plan used ("neither hides", "collapses adjacent", "edge separator"), which miss the verb "draw". Run it before committing.
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Decision 1 of part five (d) says the two `Section`s drew four separators

**Files:**
- Modify: `docs/architecture/core-theme.md`

Finding `docs+tests-1` (confirmed, confidence 95, two sources), `docs/architecture/core-theme.md:1759`. As revmux stated it: decision 1 of the LeetCode part still reads "two `Section { }` groups, turned out to draw four separators where one had been (the measurement is under rule twenty-four)". That is the unqualified drawn-on-screen claim, and it sends the reader to a paragraph that now says the opposite. The new rule-24 paragraph also lists the remaining sites of the unqualified sentence and names only the two Swift ones, so this in-document site is missing from that list.

- [x] At line 1759, reword "turned out to draw four separators where one had been" so it states the structural reading: the two groups held four separator items in the menu's structure where one had been. Keep the pointer "(the measurement is under rule twenty-four)" and the rest of the sentence.
- [x] In the rule-24 paragraph that names the two Swift sites, do not add this site: once reworded it no longer carries the unqualified sentence, and the list must stay true — it names sites that *still* say it. Confirm by re-reading that the list's claim ("Two Swift sites still state the premise without that qualifier") holds after the edit.
- [x] Run the grep from Validation Commands over the whole document and confirm no remaining hit attributes drawing to the `Commands` probe. (Done: the decision-1 site is gone; the one remaining hit, rule 24's "drew four separators", is task 2's edit.)
- [x] Run `swift test`. It must pass before task 2.

### Task 2: Rule twenty-four says "drew four separators" beside "nothing it saw was drawn", and states the method twice

**Files:**
- Modify: `docs/architecture/core-theme.md`

Finding `arch+quality-1` (confirmed, confidence 80), `docs/architecture/core-theme.md:2619–2624`. As revmux stated it: the kept probe sentence still says the probe "drew four separators at 126 pt", "two each at 104 pt" and "one at 93 pt"; the newly added sentence says the probe was structural and "nothing it saw was drawn on a screen". So the paragraph first reports what the probe drew, then says nothing it saw was drawn. The added sentence also repeats the parenthetical already in the paragraph ("item arrays read after `NSMenu.update()`, heights from `NSMenu.size`"), so the method is stated twice.

- [ ] In the kept sentence, change "drew" to a structural verb — held, or reported — so it reads as what `NSMenu.size` reported for four separator items, with the four numbers (126 / 104 / 104 / 93 pt) and the placement parenthetical kept exactly.
- [ ] Shorten the added sentence so it no longer restates the method the parenthetical two sentences earlier already gives: keep "structural measurement, not a screen capture" and "nothing it saw was drawn on a screen", drop the repeated `NSMenu.update()` / `NSMenu.size` clause.
- [ ] Keep everything else in the rule-24 description exactly as it is: the rule's number and heading, both pinned sets, the viewer's explanation, the `commandsDividerBodies` exception, the five-menus contrast, the stated limit and the two named Swift sites.
- [ ] Run the grep from Validation Commands again; the only "drew"/"draw" hits about separators left in the document must be the on-screen ones (the in-window menus) and the `Divider()`-in-system-colour sentences.
- [ ] Run `swift test`. It must pass before task 3.

### Task 3: Run the gates

- [ ] `swift test`: 5820 tests, 0 failures.
- [ ] `git diff --stat master..HEAD`: `docs/architecture/core-theme.md` and `docs/plans/` only.
- [ ] Grep the added lines of `git diff master..HEAD -- docs/architecture/core-theme.md` for "sweep" paired with "closed", "finished" or "complete", and for brand or product names: none.
- [ ] Linter: not run, because `swiftlint --strict` does not read Markdown.
