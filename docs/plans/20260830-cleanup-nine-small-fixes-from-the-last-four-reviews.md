# Cleanup — nine small fixes from the last four acceptance reviews

## Overview

Nine independent findings from the last four feature reviews, settled in one
ticket. Three of them are one-liners, three are documentation-or-test shape,
and one — the syntax-context scanner's performance story — is a real (if
mechanical) refactor of a single Core file that everything else waits behind.
Two items change visible behavior and carry Core tests: the Restore button is
disabled for a revision the buffer already holds, and an indented `#` in a
gitignore file is a pattern rather than a comment. Everything else is
byte-identical behavior, pinned as such.

## Context

### Files involved

Core (modified):

- `Sources/PisakaCore/LocalHistoryBrowserModel.swift` — the current-text seam,
  the published restore plan (items 1, 3).
- `Sources/PisakaCore/SyntaxContextScanner.swift` — the per-scan reader, the
  hoisted form order, the two resumable validators, the exact line anchor
  (items 4, 6).
- `Sources/PisakaCore/SyntaxContextVocabulary.swift` — the anchor vocabulary,
  the per-language anchor decisions, the dotenv escape decision (items 5, 6).

App, macOS (modified):

- `Sources/Pisaka/LocalHistoryView.swift` — the button rule, the row's
  reference date (items 2, 3).
- `Sources/Pisaka/PisakaApp.swift` — the current-text closure (item 1), the
  rename tab guard (item 7).
- `Sources/Pisaka/BracketOverlayLayoutManager.swift` — the parameter name
  (item 9).

Tests:

- `Tests/PisakaCoreTests/LocalHistoryBrowserModelTests.swift` — updated for the
  new seam, plus the restore-plan rule.
- `Tests/PisakaCoreTests/SyntaxContextScannerCharacterizationTests.swift`
  (**new**) — per-offset goldens that pin the scanner's answers across the
  refactor.
- `Tests/PisakaCoreTests/SyntaxContextScannerTests.swift`,
  `SyntaxContextVocabularyTests.swift` — the gitignore anchor and the dotenv
  decision.
- `Tests/PisakaCoreTests/EditorConfigGlobTests.swift` — the clock-free
  replacement for the wall-clock bounds (item 8).
- `Tests/PisakaCoreTests/LocalHistorySourceGatingTests.swift` — only if a rule's
  *mechanism* moved; the rule's meaning must not.

Docs: `docs/architecture/core-local-history.md`,
`docs/architecture/core-intelligence.md`,
`docs/architecture/core-editorconfig.md`. No `CLAUDE.md` index change (no new
source file; a new ordinary Core test suite needs no index line).

### Related patterns

- `ProjectSearchModel.offMain(_:)` — the hop the browser model already owns; the
  deferred disk read rides it rather than inventing a queue.
- `SaveTransformPlan` / `PushPlan` / `LocalHistoryRestore` — decide in Core,
  execute in the app. The Restore button's enablement becomes a published plan,
  which is that pattern rather than a second predicate.
- `SaveTransformController.applyRestore` and the usages reveal — the codebase's
  `NSString` sameness rule, which item 7 borrows verbatim.
- `BracketDepthScanner` — the chunked-read shape the scanner half-copied; item 4
  finishes the copy.
- `EditorConfigGlob.maximumMatchSteps` / `maximumCompileSteps` — the charged
  budgets that replace the clock in item 8.

### Decisions this plan settles

1. **The Local History window's "current" text becomes a two-part seam.** The
   buffer half stays synchronous on the main actor (it is main-actor state and
   costs a dictionary lookup); only the disk half moves off. `select` takes a
   `LocalHistoryCurrentText` — `.text(String)` when a tab holds the file,
   `.deferred(@Sendable () -> String)` otherwise — and the model resolves it
   *inside the hop it already makes* for the content read and the diff. Same
   content, same 1 MiB cap, same empty-string fallback; one fewer main-thread
   read.
2. **The Restore button reads a published plan.** The model keeps the resolved
   current text and publishes `restorePlan: LocalHistoryRestore?`, built by the
   rule that already exists (`NSString` sameness, `nil` for an identical
   revision). The view disables on `restorePlan == nil` and acts on the same
   value, so the comparison is spelled exactly once and the button now agrees
   with the diff pane it sits under. `restore(currentText:)` goes away.
3. **The row's relative time comes from a passed-in date.** The window holds one
   `@State` reference date refreshed on a 60 s timer and hands it to every row;
   `body` formats against it and reads no clock. This also fixes the stale
   reading the review found, which a pure "pass a date in at open" would not.
4. **The scanner gets one per-scan object, not three patches.** A `Scan`
   reference type created per `scan()` call carries the `NSString`, the chunk
   buffer, the string forms *already ordered*, and the two validator cursors.
   Every helper takes it instead of `text: NSString`, which is the "route the
   helpers through the chunk" branch of item 4b — the buffer stops being
   half-used, the sort (4a) happens once per scan, and the YAML flow-depth and
   HTML inside-tag walks (4c) become resumable forward cursors instead of
   walks from offset zero. The cursors resume only forward; a backwards query
   restarts from zero, which the scan's monotonic candidate order never asks
   for, and that fallback is what keeps the answers identical rather than
   merely "usually identical".
5. **The refactor is pinned by goldens written first.** A characterization suite
   records the context at *every* offset of a corpus (quote-dense YAML, HTML
   with tags/comments/attribute values, Swift/Python/Rust/Go strings, JSON,
   dotenv, gitignore) as run-length-encoded expectations captured from the
   current implementation before anything is touched. The existing scanner
   suite additionally passes unmodified, per the acceptance criteria; the only
   deliberate golden edit is the gitignore run item 6 changes.
6. **The anchor vocabulary gains a case and loses the ambiguous name.**
   `LineAnchor` becomes `.anywhere`, `.trueLineStart` (column zero),
   `.afterIndent` (today's `.lineStart`: first non-whitespace on the line) and
   `.afterWhitespace`. Deleting the name `.lineStart` is deliberate: every
   existing use site becomes a compile error and has to be re-decided rather
   than inherit a silently changed meaning. Per language: **gitignore →
   `.trueLineStart`** (gitignore(5) makes an indented `#` a literal pattern);
   **dockerfile → `.afterIndent`** (the builder skips leading whitespace before
   an instruction or comment); **dotenv → `.afterIndent`** (no normative
   grammar; the loaders in the wild trim); **editorconfig → `.afterIndent`**,
   which is what this repository's own `EditorConfigFile` parser does (it trims
   the line, then tests `#`/`;`) — the two must not disagree about the same
   file; **yaml → `.afterWhitespace`**, unchanged.
7. **The dotenv escape stays `.none`, and the doc says why.** dotenv has no
   normative grammar and escape handling differs per loader; the escape rule's
   only effect in this scanner is where a literal ends, and dotenv strings never
   gate and its `#` is anchored to the line's start, so no answer anywhere
   depends on it. The vocabulary therefore states the lexically conservative
   rule — the first matching quote closes the literal — instead of borrowing
   another language's convention. Recorded in `dotenvStringForms`'s doc comment
   and in the architecture table (which today spells no escape at all for
   dotenv), with a test pinning the stated reading.
8. **The wall clock leaves `EditorConfigGlobTests` entirely.** Every
   pathological input in that suite is one whose real cost is *charged* against
   a budget — that charging was the fix each test was written for. So the
   assertion becomes the algorithmic one: the pathological input must **spend
   its budget** (`exceedsCompileBudget` for the compile shapes; the caller-owned
   match budget driven to exhaustion for the match shapes) and the call must
   return an answer. That fails on a genuinely quadratic parse in the way that
   matters: work that is quadratic *and uncharged* — the actual regression, and
   the one the clock caught — leaves the budget unspent, so the assertion
   fires; work that is quadratic *and charged* is bounded by the budget by
   construction, which is precisely the "cannot hang" property the clock was
   standing in for. **All eight timing assertions in the suite go** (verified:
   `grep -c "started.timeIntervalSinceNow"` on that file is 8), not just the one
   that failed in a release run: they share one mechanism and one failure mode,
   and leaving seven equally noisy siblings would be answering the symptom.
9. **Item 4c gets a clock-free scaling test too**, by the same reasoning: an
   internal test seam returns the number of characters the validators visited
   during one scan, and the test asserts that count grows roughly linearly (a
   4× document costing well under 6× the steps) — quadratic re-walking blows it
   by an order of magnitude, and no scheduling noise can move it.

## Development Approach

- **Testing approach**: Regular, except Task 2 — the characterization goldens
  are written and made green *before* the refactor they exist to pin.
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests** (the three app-layer
  items — 1's wiring, 2, and 7 — stay untested by convention and instead carry
  their reasoning in the doc comment at the changed code).
- **CRITICAL: all tests must pass before starting the next task.**
- Behavior changes are Core-first; the view layer only wires triggers.
- No product or brand names in code, comments, tests, docs or commits.

## Implementation Steps

### Task 1: Local History — the current-text seam, the restore plan, the row's clock

**Files:**

- Modify: `Sources/PisakaCore/LocalHistoryBrowserModel.swift`
- Modify: `Sources/Pisaka/LocalHistoryView.swift`, `Sources/Pisaka/PisakaApp.swift`
- Modify: `Tests/PisakaCoreTests/LocalHistoryBrowserModelTests.swift`

- [x] Add `LocalHistoryCurrentText` (in the browser model's file — no new file):
  `.text(String)` for a value already in hand and
  `.deferred(@Sendable () -> String)` for one that must be read, with a doc
  comment stating that `.deferred` is resolved off the main actor and is the
  reason the window no longer reads disk on it.
- [x] Change `select(_:currentText:)` to take that value and resolve it inside
  the existing `offMain` block, beside the content read and the diff; the
  generation token keeps its current discipline (bumped synchronously before the
  hop, re-checked after it) and a superseded selection publishes nothing.
- [x] Keep the resolved text on the model and publish
  `restorePlan: LocalHistoryRestore?`, built by the existing rule — the
  `NSString` sameness question that answers `nil` for a revision the buffer
  already holds. Clear it in `open(file:root:)` and on a `nil` selection.
  Remove `restore(currentText:)`; move its doc-comment reasoning to the plan's
  construction site.
- [x] `LocalHistoryView`: the button disables on `restorePlan == nil` and acts on
  that same value; the `currentText` closure now answers a
  `LocalHistoryCurrentText`; the footer comment is rewritten to say why the
  enablement is now the plan itself.
- [x] `LocalHistoryView`: one `@State` reference date on the window root,
  refreshed on a 60 s timer, passed into `RevisionRow`; `body` reads no clock.
  State the reason in the row's doc comment.
- [x] `PisakaApp.currentTextForLocalHistory` answers `.text(buffer)` when a tab
  holds the file and `.deferred { … }` otherwise, carrying the same
  `readTextIfNotBinary` call, the same 1 MiB cap and the same empty-string
  fallback; the doc comment gains why the buffer half stays synchronous (it is
  main-actor state and costs a lookup) and the disk half does not.
- [x] Tests: the deferred closure is resolved off the main thread (recorded
  inside the closure, awaited through the existing rendezvous helpers — no timed
  delays); the plan is `nil` for a byte-identical revision and non-`nil` for a
  decomposed/precomposed pair; the plan clears on retarget and on deselect; a
  superseded selection publishes no plan.
- [x] Update the existing `select`/`restore` call sites in that suite.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: Characterization goldens for the syntax-context scanner

**Files:**

- Create: `Tests/PisakaCoreTests/SyntaxContextScannerCharacterizationTests.swift`

- [x] Build a corpus of documents chosen to hit every validator branch:
  quote-dense YAML (flow collections, block plain scalars, comment-only lines,
  doubled-quote escapes), HTML (attribute values, `>` inside a value, comments,
  an unclosed comment), Swift (pound padding, interpolation holes), Python
  (prefixes, f-string braces), Rust (raw forms), Go, JSON, dotenv, gitignore,
  editorconfig, Dockerfile, SQL, CSS, Markdown.
- [x] For each document, assert the context at **every** offset `0…length`
  against a run-length-encoded expectation string committed in the test.
- [x] Capture those expectations from the *current, unmodified* implementation
  (dump once, read the encodings, commit them), then run the suite green before
  changing any production code. State in the file's doc comment that these are
  characterization goldens: they assert nothing about what is *right*, only that
  the performance work in Task 3 changed nothing.
- [x] Run `swift test` — must pass before Task 3.

### Task 3: The scanner's performance story

**Files:**

- Modify: `Sources/PisakaCore/SyntaxContextScanner.swift`
- Modify: `Tests/PisakaCoreTests/SyntaxContextScannerCharacterizationTests.swift`
  (the scaling assertion only)

- [x] Introduce a per-scan `Scan` reference type holding the `NSString`, its
  length, the chunk buffer and the chunk bookkeeping, `character(at:)` and
  `isMatch(at:pattern:)`, the string forms **ordered once** at construction
  (item 4a), and the two validator cursors below.
- [x] Thread it through every helper in place of `text: NSString`, so every
  per-character read goes through the chunk (item 4b). The buffer stops being
  half-used; the fallback for a look-ahead beyond the current chunk stays.
- [x] Replace `yamlFlowDepth(upTo:)`'s walk-from-zero with a resumable cursor on
  `Scan` (position, depth, in-single, in-double), advancing forward to the
  requested limit and restarting from zero only for a backwards query — which
  the scan's monotonic candidate order never issues, and which is why the
  answers are identical rather than merely close (item 4c).
- [x] Replace `isInsideHtmlTag(at:)`'s walk-from-zero the same way (position,
  in-tag, in-single, in-double, in-comment). Preserve today's answers exactly at
  the target-clamped tail: the cursor commits only to a safe boundary and the
  last few characters are resolved on a scratch copy, so a clamped decision is
  never recorded into the cursor for a later, longer query to inherit.
- [x] Add an internal test seam returning the number of characters the two
  validators visited in one scan, documented as existing for the scaling
  assertion and read by nothing in the app.
- [x] Tests: the goldens from Task 2 pass **unmodified**; the existing scanner
  suite passes unmodified; a new scaling assertion shows the validator step count
  for a quote-dense YAML document and an HTML document growing roughly linearly
  (4× the document costing well under 6× the steps), with the comment stating
  that a re-walk from zero blows this by an order of magnitude and that no clock
  is involved.
- [x] Check `swiftlint --strict` for the file's measured thresholds (length,
  cyclomatic complexity, parameter count); if a ceiling genuinely moves, move it
  in `.swiftlint.yml` with its reason and update `LintConfigurationTests`.
- [x] Run `swift test` — must pass before Task 4.

### Task 4: The anchor vocabulary and the dotenv decision

**Files:**

- Modify: `Sources/PisakaCore/SyntaxContextVocabulary.swift`,
  `Sources/PisakaCore/SyntaxContextScanner.swift`
- Modify: `Tests/PisakaCoreTests/SyntaxContextScannerTests.swift`,
  `Tests/PisakaCoreTests/SyntaxContextVocabularyTests.swift`,
  `Tests/PisakaCoreTests/SyntaxContextScannerCharacterizationTests.swift`

- [x] Replace `LineAnchor.lineStart` with two cases — `.trueLineStart` (column
  zero) and `.afterIndent` (first non-whitespace on the line) — so every use
  site must be re-decided rather than inherit a changed meaning. Each case's doc
  comment says which languages hold it and why.
- [x] Re-point the four affected languages: gitignore to `.trueLineStart`;
  dockerfile, dotenv and editorconfig to `.afterIndent`, each with its one-line
  reason on the entry (editorconfig's cites this repository's own
  `.editorconfig` parser, which trims before testing `#`/`;` — the two must
  agree about the same file).
- [x] Teach `isAnchorSatisfied` the exact case: satisfied at offset 0 or
  immediately after a line separator, with no whitespace tolerance.
- [x] Record the dotenv escape decision (`.none`) in `dotenvStringForms`'s doc
  comment with the reason from the Decisions section above.
- [x] Tests: a gitignore `#` at true line start is a comment and suppresses
  completion; an indented `#` is code and does not; the unchanged mid-line case
  still holds; the dockerfile/dotenv/editorconfig indented `#` (and `;`) stay
  comments; a dotenv literal closing at the first matching quote pins the
  `.none` reading.
- [x] Update the gitignore run in the Task 2 goldens, with a comment naming this
  item as the reason the expectation moved; every other language's golden stays
  byte-identical.
- [x] Run `swift test` — must pass before Task 5.

### Task 5: Two one-line hardenings

**Files:**

- Modify: `Sources/Pisaka/PisakaApp.swift`,
  `Sources/Pisaka/BracketOverlayLayoutManager.swift`

- [x] Rename apply pass: the per-tab guard compares with `NSString` equality
  rather than Swift's, preserving today's "no verified text ⇒ no match, and the
  file is reported unrewritten" behavior. The surrounding doc comment gains the
  reason: the plan was verified against exact bytes, and canonical equivalence
  would vouch for a tab holding a differently-encoded spelling — the same hazard
  the restore path and the usages reveal already name.
- [x] Fix the underline override's duplicated parameter name; zero behavior
  change.
- [x] Both are app-layer and stay untested by convention; the reasoning ships at
  the code.
- [x] Run `swift test` — must pass before Task 6.

### Task 6: Clock-free budget assertions in the glob suite

**Files:**

- Modify: `Tests/PisakaCoreTests/EditorConfigGlobTests.swift`

- [x] Replace **all eight** `-started.timeIntervalSinceNow` bounds (currently at
  lines 263, 276, 292, 305, 320, 359, 373 and 388) with the charged-work
  assertion for each shape: the compile-budget cases assert
  `exceedsCompileBudget` (and, for the whole-file case, that every section
  degraded that way, so the file's total work is sections × the ceiling); the
  match cases run against a caller-owned budget and assert it was driven to
  exhaustion **and** that the call answered. Confirm with
  `grep -c "timeIntervalSinceNow"` that the file reaches zero.
- [x] Keep every pathological input exactly as it is — the coverage is the
  input, not the clock — and keep the two "nowhere near the budget" tests, which
  are the other side of the bound and already clock-free.
- [x] Rewrite each test's comment to say what the assertion now proves and how it
  fails on a quadratic regression: uncharged quadratic work leaves the budget
  unspent and fires the assertion; charged quadratic work is bounded by the
  budget, which is the property the clock stood in for. Keep the measured
  pre-fix numbers in the comments — they are the evidence for why the input is
  pathological.
- [x] Run `swift test` — must pass before Task 7.

### Task 7: Verify acceptance criteria

- [x] `swift test` — full suite green.
- [x] `swiftlint --strict` from the repository root — clean.
- [x] `xcodegen generate` if needed, then the macOS build
  (`-configuration Release`, `platform=macOS`) and the iOS build
  (`generic/platform=iOS`) — both succeed.
- [x] Confirm the macOS build log emits **no** warning for the bracket overlay
  file (grep the log for the file name).
- [x] Confirm the existing scanner suite is unmodified except the gitignore
  expectations item 6 legitimately changed (`git diff` on that file).

### Task 8: Update documentation

- [x] `docs/architecture/core-local-history.md` — the browser model's
  current-text seam (buffer synchronous, disk deferred and resolved in the hop
  it already makes), the published restore plan as the button's one rule, and
  the window's single reference date.
- [x] `docs/architecture/core-intelligence.md` — the vocabulary table's
  gitignore row (`#` at true line start only) and dotenv row (the escape
  decision and its reason); the anchor vocabulary's four cases with the
  per-language assignment; the scanner's per-scan reader, the ordered forms and
  the two resumable validator cursors, including the restart-on-backwards-query
  rule.
- [x] `docs/architecture/core-editorconfig.md` — the glob suite's eight
  pathological tests now assert charged budget rather than wall-clock time, and
  why that still catches the regression they were written for.
- [x] No `CLAUDE.md` change: no new source file, and the new suite is an
  ordinary Core test suite rather than a repository-file one.

## Post-Completion (manual, outside the agent's checkboxes)

- Open a gitignore file with an indented `#` pattern line in a debug build and
  confirm completion is offered there and still suppressed on a true comment
  line.
- Open the Local History window on a file no tab holds, confirm the diff and the
  1 MiB behavior are unchanged, and confirm Restore is greyed out on a revision
  identical to the buffer.
