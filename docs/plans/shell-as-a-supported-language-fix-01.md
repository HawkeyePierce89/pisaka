# Shell as a supported language — fix 01

## Overview

Answers revmux round `01-initial` on task `shell-as-a-supported-language`
(`.revmux/tasks/shell-as-a-supported-language/01-initial`). Four sources
reported, none degraded; six findings, all `minor`, none gating. The project's
own gates were green before the review and must be green after it: 5711 Core
tests, 98 app-layer tests, both platform builds, and a clean linter.

All six are accepted, plus one item revmux filed as `immaterial` that is
accepted anyway because its mechanism was verified independently in the pinned
grammar, plus one plan correction the user decided on.

Two shapes account for four of the six, and naming them is what keeps the next
round from finding the same thing one line away:

- **A doc comment that states an approximation as if it were exact.** Three of
  the findings are this: the `#` anchor, the `$'…'` reason and the heredoc
  consequence. The approximations themselves are sanctioned by the ticket; what
  is wrong is the sentence recording them, and in this repository the recorded
  reason *is* how the decision reaches the next reader.
- **A doc comment asserting a fact about a sibling table without checking it.**
  The `print` cross-reference is this one.

Each task below therefore carries a **sweep** step: fix the construct across the
files it can occur in, not only the line the finding quoted.

The **pre-existing** finding (`docs/architecture/core-editor.md:149`, "the last
three carry no extension at all", already wrong on master and widened by two
here) is **deliberately out of scope** — the user excluded it. Do not fix it and
do not mention it in any edit.

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-shell test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-shell-ios build
swiftlint --strict
```

Derived data never lands inside the working tree.

## Development Approach

- **Testing approach**: Regular — code, then tests, in the same task.
- **CRITICAL: every task ships new/updated tests**, including the tasks whose
  defect is a sentence: a wrong sentence about scanner behaviour is fixed by
  asserting the behaviour the corrected sentence claims, so the sentence cannot
  drift again without a red test.
- **CRITICAL: all tests pass before the next task starts.**

## Implementation Steps

### Task 1: The `#` anchor answers shell's word boundaries, not physical whitespace

**Files:**
- Modify: `Sources/PisakaCore/SyntaxContextVocabulary.swift`
- Modify: `Sources/PisakaCore/SyntaxContextScanner.swift`
- Modify: `Tests/PisakaCoreTests/SyntaxContextScannerTests.swift`,
  `Tests/PisakaCoreTests/SyntaxContextVocabularyTests.swift`
- Modify: `docs/architecture/core-editor.md` (or whichever doc carries the
  `LineAnchor` vocabulary — find it rather than assuming)

**The defect, as revmux stated it** (`SyntaxContextVocabulary.swift:225`,
confidence 99, corroborated by `bugs+impl` and `adversarial`): the shell arm
returns `.line(token: "#", anchor: .afterWhitespace)`, which
`SyntaxContextScanner.isAnchorSatisfied` implements as "first non-whitespace on
the line, or the previous character is whitespace or a line separator". In shell
a `#` opens a comment whenever it starts a *word*, and the metacharacters `;`,
`)`, `|`, `&` end a word without being whitespace. Confirmed against the real
shell: `/bin/bash -c 'echo hi;# comment<newline>echo done'` prints `hi` then
`done`, so the `#` text is a comment; the scanner answers `.code`. The one
non-test caller is `SymbolIntelligenceProvider.suppressesCompletion`, so the
completion popup opens on prose inside a comment.

**The agreed fix.** `LineAnchor` is a closed four-case enum behind an exhaustive
switch, so the answer is a **fifth case**, not a loosening of `.afterWhitespace`
— yaml holds that anchor and its reading is genuinely correct for yaml, so
changing it in place would break a language this change must not touch.

- [x] Add a fifth `LineAnchor` case for "the token starts a word": satisfied at
      the start of a line, after whitespace, **or** after one of shell's
      word-ending metacharacters. Name it for what it means rather than for the
      language that holds it, and document on the case which characters count and
      why, exactly as the four existing cases document themselves.
- [x] Implement it in `isAnchorSatisfied` beside the others. Do not alter the
      `.afterWhitespace` arm.
- [x] Move `.shell`'s comment form onto the new anchor. `yaml`, `dockerfile`,
      `dotenv`, `editorconfig` and `gitignore` keep the anchors they hold —
      assert that in a test rather than only intending it.
- [x] **Record the remaining approximation honestly.** The converse case is not
      fixed by this and must not be claimed as fixed: in `echo foo\ #bar` the
      backslash escapes the physical space, so `#bar` stays part of the argument
      while the scanner calls it a comment. State that on the shell arm beside
      the other recorded approximations, in the same voice.
- [x] **Rewrite the sentence that made this a finding.** The shell arm's doc
      comment currently states the rule as exact ("a `#` glued to the preceding
      character is part of a word"). That claim is true for `foo#bar` and
      `${var#prefix}` and false for a word-ending metacharacter. Say what is now
      handled and what is not.
- [x] **Sweep:** the construct is *a `LineAnchor` doc comment asserting a
      language's rule as exact*. Re-read all five cases' doc comments and the
      per-language comment-form arms, and correct any other that overstates. Say
      what was checked and what, if anything, changed.
- [x] Tests: `echo hi;# note` reads as a comment; `case $x in b)#note` reads as a
      comment; a `#` after `|` and after `&` reads as a comment; `foo#bar` and
      `${var#prefix}` still do **not**; the escaped-space case is pinned as the
      known approximation with a comment naming it as such, so the test records
      the limit rather than hiding it; and the other five languages' anchors are
      asserted unchanged.

### Task 2: The `$'…'` and heredoc reasons say what the scanner actually does

**Files:**
- Modify: `Sources/PisakaCore/SyntaxContextVocabulary.swift`
- Modify: `docs/architecture/core-intelligence.md`
- Modify: `Tests/PisakaCoreTests/SyntaxContextScannerTests.swift`

Both findings are the same shape — a recorded consequence narrower than the real
one — and both sentences are mirrored in the architecture doc, so they are one
task.

**Defect A** (`SyntaxContextVocabulary.swift:449`, confidence 99, corroborated by
`docs+tests` and `adversarial`): the doc says `$'…'` "lexes as an ordinary
single-quoted string — which ends it in exactly the same place, since the only
difference is what the escapes *mean*." False. ANSI-C quoting escapes the
delimiter itself, so `$'it\'s'` closes on the **third** apostrophe. The shipped
form is `escape: .none` and `advanceString` only consults the escape length when
`escape == .backslash`, so the scanner closes on the second and the third
re-opens a line-spanning string. On `x=$'it\'s'   # note` the trailing `#` is
read as inside a string, and because shell does not suppress completion inside
strings the popup stays alive across the region.

**Defect B** (`SyntaxContextVocabulary.swift:443`, confidence 85, corroborated by
`bugs+impl` and `arch+quality`): heredocs are unmodelled with the reason that the
body "lexes as code, which is the honest failure: the words in it stay completable
rather than being gated by a guess." That holds only until the body contains an
apostrophe. Both string forms are `spansLines: true` and `advanceString` pops a
string frame on a line separator only when `!spansLines`, so a single `'` in an
English heredoc body (`It's done`) leaves the scan in `.string` until the next
apostrophe or the requested offset — past the `EOF` terminator and into whatever
follows. Comment-based suppression then stops working for the remainder of the
file, which is the one thing shell's comment form was added to provide. Neither
is a regression — shell had no vocabulary at all before — and both are contained
to completion suppression.

- [ ] Correct the `$'…'` sentence: say that the scanner closes on the second
      apostrophe while bash closes on the third, and what that costs.
- [ ] Correct the heredoc sentence: say that the body lexes as code **only while
      it contains no apostrophe**, and that one apostrophe carries `.string` past
      the terminator into the rest of the file.
- [ ] Mirror both corrections in `docs/architecture/core-intelligence.md`, where
      the same two sentences appear.
- [ ] **Sweep:** the construct is *a sentence in this file stating what the
      scanner does without the case that breaks it*. Re-read every recorded
      approximation on the shell arms and on the neighbouring languages' arms;
      correct any other that is narrower than the behaviour. Say what was checked.
- [ ] Tests that would have caught both, written as **characterisation** tests of
      today's behaviour with a comment saying the behaviour is the known
      approximation and the assertion exists so the doc sentence cannot drift
      from it: `x=$'it\'s'   # note` — the `#` is not read as a comment; a
      heredoc body containing `It's done` leaves a following `# note` unread as a
      comment. Do **not** change the scanner to fix either: the approximations
      are sanctioned by the ticket, only their description was wrong.

### Task 3: The keyword rationale stops citing a fact that is untrue of this file

**Files:**
- Modify: `Sources/PisakaCore/LanguageKeywords.swift`
- Modify: `docs/architecture/core-intelligence.md`
- Modify: `Tests/PisakaCoreTests/LanguageKeywordsTests.swift`

**The defect** (`LanguageKeywords.swift:198`, confidence 90): the shell list
justifies dropping `echo` "by the same rule that keeps `print` and `console` off
the other lists". `console` is on no list, but `print` **is** — `LanguageKeywords
.go` contains both `"print"` and `"println"`, and the Go list's own doc comment
explains at length why: Go's predeclared identifiers are declared in no source
file, so no other completion source can offer them. Nothing executes
differently; the cost is that the decision record argues from a fact untrue of
the file it lives in, and `print` is exactly the precedent that would settle the
next borderline word.

- [ ] Rewrite the shell list's justification so it cites only what is true of
      this file. `echo` is still out, and the reason still holds — an ordinary
      command a `$PATH` program could perform — but the supporting cross-
      reference must either name a word genuinely on no list, or name Go's
      `print` **and** say why Go's case is different (a predeclared identifier
      with no declaration site anywhere, which `echo` is not).
- [ ] Mirror the correction in `docs/architecture/core-intelligence.md`.
- [ ] **Sweep:** the construct is *a doc comment asserting what some other
      keyword list does or does not contain*. Grep every doc comment in this file
      for a claim about a sibling list and check each against the lists
      themselves. Report what was checked and what was wrong.
- [ ] A test that would have caught it: assert the cross-reference mechanically —
      for each word a doc comment claims is on no list, assert it appears in no
      list. Keep it a rule over the lists rather than a hard-coded pair, so the
      next such claim is checked for free.

### Task 4: The multi-assignment pattern carries its grammar caveat

**Files:**
- Modify: `Resources/Queries/shell/symbols.scm`
- Modify: `docs/architecture/core-intelligence.md`
- Modify: `Tests/PisakaAppTests/ShellSymbolQueryTests.swift`

revmux filed this `immaterial`; it is accepted anyway because its mechanism was
verified directly in the pinned grammar — `src/grammar.json` declares the
conflict `["command", "variable_assignments"]`, which is what makes the parse
greedy across newlines.

**The defect** (`Resources/Queries/shell/symbols.scm:33`): the
`(program (variable_assignments …))` pattern captures only while nothing after
the line reads as a command name. For the ordinary `A=1 B=2` followed by any
further statement, the run collapses into a `command` with the assignments as its
prefix, and neither name is captured. The **fixture** documents this at length
and places its multi-assignment line at end of file for exactly this reason; the
**query file** does not, and the query file is what a reader consults. One of the
three shapes the plan claims for top-level assignments is therefore near-inert,
and that is not currently recorded where it would be read.

- [ ] Add the caveat to the pattern's own comment in `symbols.scm`: name the
      declared grammar conflict, say that the capture survives only when no later
      statement can read as a command, and say plainly that this makes the pattern
      rare in practice rather than implying it works generally.
- [ ] Mirror it in `docs/architecture/core-intelligence.md`'s shell section,
      which currently describes three working shapes.
- [ ] **Do not attempt to fix the capture.** Working around a declared grammar
      conflict from a query is out of scope and would be a different decision; the
      deliverable here is an honest record.
- [ ] A test that would have caught it: extend `ShellSymbolQueryTests` with a
      second, small fixture — or an inline source string, whichever fits the
      suite's shape — where `A=1 B=2` is followed by an ordinary command, and
      assert that neither name is indexed, with a comment naming the grammar
      conflict as the cause. That turns the caveat into an assertion, so a
      grammar bump that changes the behaviour shows up as a red test rather than
      as a silently stale comment.

### Task 5: The ten shell dot-files get a file icon

**Files:**
- Modify: `Sources/PisakaCore/FileIcon.swift`
- Modify: `Tests/PisakaCoreTests/FileIconTests.swift`
- Modify: the architecture doc carrying `FileIcon`'s entry

**The defect** (`FileIcon.swift:89`, confidence 70, refined): `SyntaxLanguage`
now claims ten startup dot-files, while `FileIcon`'s special-name map lists none
of them, so `.zshrc` and `.envrc` highlight as shell, index, and comment with `#`
— and draw the fallback grey document icon. `FileIconTests`' own comment names
this divergence as something only a test prevents. Cosmetic, contained to the
tree and tab icon, and no regression: these names had neither a language nor an
icon before.

- [ ] Add the ten names — `.bashrc`, `.bash_profile`, `.bash_logout`, `.zshrc`,
      `.zprofile`, `.zshenv`, `.zlogin`, `.zlogout`, `.profile`, `.envrc` — to
      the special-name map, answering the same symbol and colour the `sh`/`bash`/
      `zsh` extensions already answer.
- [ ] `ksh` and `command` are a **stated, accepted cost** recorded in the
      original plan. Leave them on the fallback icon and do not quietly add them;
      if the task judges that inconsistent, say so in the report rather than
      acting on it.
- [ ] **Sweep:** the construct is *a name `SyntaxLanguage` claims that `FileIcon`
      does not answer for*. Compare the two tables in both directions and report
      every divergence found, fixing only the ten above.
- [ ] A test that would have caught it: assert each of the ten resolves to the
      shell icon rather than the fallback, and — the rule rather than the
      instances — that every name in `SyntaxLanguage`'s exact-name map has a
      `FileIcon` answer that is not the fallback, with the two accepted
      exceptions named explicitly so the exemption is visible.

### Task 6: `FEATURES.md` names shell among the indexed languages

**Files:**
- Modify: `docs/FEATURES.md`

**The defect** (`docs/FEATURES.md:448`, confidence 90, refined): the paragraph
enumerating the languages whose declarations are indexed does not name shell,
although shell ships a symbols query and is not in `unindexableLanguages`. Two
refinements the reviewer supplied, both of which lower the pressure without
making it wrong: the original plan deliberately scoped the user-facing edits to
four lists and said "nowhere else", so this is a scoping judgement rather than a
skipped step; and the paragraph is *already* non-exhaustive — `Resources/Queries`
holds sixteen language directories and the paragraph names thirteen, SQL and
EditorConfig having both been added without touching it.

- [ ] Add shell to the list.
- [ ] **Since the same sentence is already wrong about two other languages**,
      also add SQL and EditorConfig, so the fix does not leave a list that is
      accurate about the newest language and stale about two older ones. That is
      the sweep for this one: the construct is *a user-facing list that must match
      `Resources/Queries` minus `unindexableLanguages`*.
- [ ] Verify the resulting list against `Resources/Queries` and
      `SymbolIndexModel.unindexableLanguages` and state in the report that the two
      now agree — or, if some language is deliberately omitted, say which and why.
- [ ] No test: `docs/FEATURES.md` has no gate, and inventing one for a prose list
      is out of scope here. Say so in the report rather than silently leaving the
      checkbox meaningless.

### Task 7: The archived plan records how its manual gate was discharged

**Files:**
- Modify: `docs/plans/completed/20260921-shell-as-a-supported-language.md`

The plan's last section is "## Post-Completion (manual, by the user — mandatory,
not optional)", requiring a DEBUG build, ⌃⌘J on a fixture script, and a report of
what the picker listed. **That step was not performed** — the execution log says
outright that the remaining post-completion items were left to the user — yet the
plan was moved into `completed/`. revmux raised this as its one open question.

**The user's decision:** the step is discharged by `ShellSymbolQueryTests`, which
compiles the query against the real grammar and asserts the extracted symbol set
by equality. The plan must say so rather than sit in `completed/` with an
unperformed mandatory item.

- [ ] Rewrite that section to record the decision and its date: the automated
      app-layer suite is accepted as the runtime verification; name what it
      asserts (the grammar loads, the query compiles, and the fixture's symbol set
      matches exactly, including the four exclusions) and name what it does **not**
      cover — the tail from the index to the picker UI, and the by-eye checks on
      highlighting, ⌘/ and the minimap.
- [ ] Do not delete the section and do not silently tick it. The value is the
      record that a mandatory gate was consciously converted, not that the
      document looks finished.
- [ ] Change nothing else in the archived plan.

### Task 8: Run the gates

- [ ] `swift test` — green.
- [ ] The app-layer bundle — green, `ShellSymbolQueryTests` among it.
- [ ] The iOS device build — green.
- [ ] `swiftlint --strict` — clean.
- [ ] Confirm each new test **bites**: break the thing it guards, confirm the red,
      revert. Do this for the new anchor case, the two characterisation tests, the
      cross-reference rule, the multi-assignment assertion and the icon rule.
      Report which ones were mutated and what the failure said.
- [ ] Confirm `git status` shows only the intended changes and that no derived
      data was written inside the working tree.
