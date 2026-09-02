# Database viewer, part 2b: the SQL console (macOS)

## Overview

A SQL console under the database viewer's grid: the reader types SQL, presses Run (⌘↩),
and gets either a bounded table of rows or — after an explicit confirmation — a
committed mutation reported by its affected-row count. Every failure carries SQLite's
own words.

Four decisions this plan makes, which the ticket delegated to it:

1. **Multi-statement input runs in order** (the answered question), and **classification
   is honest about how far it can see**. SQLite resolves object names at *prepare*
   time against the *current* schema, and classification prepares statement by
   statement through the tail without running any of them — so
   `CREATE TABLE x(a); INSERT INTO x VALUES(1);` cannot be classified past the
   `INSERT`, which fails to prepare with `no such table: x`, and the same holds for
   `ALTER TABLE` followed by a statement naming the new column. Refusing that whole
   migration-shaped script as an error would be wrong: it runs fine in order. The
   rule is therefore:
   - Classify by tail until the **first prepare failure**, keeping SQLite's message
     and the index it failed at.
   - If every statement classified so far is read-only, **that failure is the
     answer** — a read cannot have created what the next statement needs. Report
     SQLite's message and run nothing.
   - If any statement classified so far writes, the batch is mutating: ask the
     confirmation, whose prompt says how many statements were classified, how many
     of them write, and that the remainder are classified **as they run, inside the
     same transaction**. `performConsoleWrite` then prepares each statement as it
     is reached — after the earlier ones have run — so a prepare failure there is
     an ordinary failure that rolls the whole batch back.
   - Classification therefore learns a statement's **kind only, never its shape**:
     a `DROP` followed by a `CREATE` of the same name prepares the third statement
     against the old table, which cannot mislead anything, since nothing downstream
     reads column names out of the classification.

   A fully classified read-only batch runs statement by statement on the tab's read
   connection and the result area shows the **last** statement that answered columns.
   A mutating batch runs **whole, as one transaction**, on part 2a's write path, and
   reports the affected-row total only — rows a query inside a mutating batch
   produced are not shown, stated in the confirmation prompt and in the docs.

2. **The seam grows a second write member rather than an optional requirement.**
   `performWrite(_:)` keeps the cell edit's exact-count rule byte for byte and is not
   touched. The console needs a different member anyway for a reason beyond the count:
   it carries the reader's text **verbatim, as one string**, and SQLite prepares one
   statement at a time — `performWrite`'s app half prepares each `DatabaseStatement`
   with a nil tail pointer, so multi-statement text sent through it would silently run
   only the first statement. Two members, two rules, no shared trap.
   `DatabaseWriteOutcome` is reused unchanged.

3. **The console input is drawn monospaced but at the interface metrics**, not at the
   code font, so the viewer tab stays one zoom zone (chrome) and declares no
   `ZoomSurface`. The alternative — the code font, hence a surface — would make the
   input zoom differently from the grid one pixel away, and split a single pane
   between two zoom zones. `ZoomSourceGatingTests`' surface set is therefore
   unchanged, which the existing suite asserts by set equality.

4. **`ATTACH`/`DETACH` are a named known limit, not a special case.**
   `sqlite3_stmt_readonly` reports them read-only, so an `ATTACH` typed alone in the
   console runs on the tab's own read connection and stays attached for the life of
   the tab. Nothing can be written through it — the attached database inherits the
   connection's read-only flag — and closing the tab drops the attachment, so the
   honest move is one sentence in the known-limits list rather than a classifier of
   our own second-guessing SQLite (which is exactly what requirement one forbids).
   An `ATTACH` inside a mutating batch is unaffected: that batch runs on the
   short-lived read-write connection, which is closed when it returns.

The cap: a console read is capped at **500 rows** (`DatabaseConsolePlan.rowLimit`), its
own number rather than the grid's 200 — a page is something the reader can turn, a cap
is something they cannot — enforced by the app half stepping at most the cap and one
row further to learn that more remained. **No `LIMIT` is ever appended to the reader's
text.**

Folded in from part 2a's acceptance review: the paging buttons and the sort headers
disable while **any** write is in flight — a cell edit or a console mutation.

## Context

### Files involved

Core (new):
- `Sources/PisakaCore/DatabaseConsolePlan.swift` — the console's vocabulary and its
  whole pure decision: classification bookkeeping (including the deferral), the
  run/confirm/refuse/nothing policy, the prompt sentence, the row cap, the footer
  sentences, the refusals.
- `Sources/PisakaCore/DatabaseConsoleModel.swift` — the main-actor flow: one
  generation token, the console's own message slot, the write's refusal order.

Core (modified):
- `DatabaseServicing.swift` — three new members (`classifyConsole`, `runConsoleRead`,
  `performConsoleWrite`), the two new seam value types, all three defaulted to an
  honest refusal exactly as `performWrite(_:)` is.
- `DatabaseViewerModel.swift` — owns the console model, exposes `isWriteInFlight`,
  gains `refreshAfterWrite()` (listing + re-selection + count + page), and stops the
  console in `close()`.
- `DatabaseValue.swift` / `DatabaseQuery.swift` — doc headers only (the tense of "in
  part 2" and the console as the one stated exception to Core-composed SQL).

App (new):
- `Sources/Pisaka/DatabaseConsoleView.swift` — the pane. `#if os(macOS)`, name
  prefixed `Database` so the gating suite's rules apply to it automatically.

App (modified):
- `Sources/Pisaka/Platform/DatabaseConnectionService.swift` — the three seam members:
  one prepare-by-tail loop shared by all of them, the bounded stepping, the console's
  transaction bracket.
- `Sources/Pisaka/DatabaseViewerView.swift` — hosts the pane; disables paging and the
  sort headers while a write is in flight.

Tests:
- New `Tests/PisakaCoreTests/DatabaseConsolePlanTests.swift`,
  `Tests/PisakaCoreTests/DatabaseConsoleModelTests.swift`.
- Modified `Support/ScriptedDatabaseService.swift`, `DatabaseServicingTests.swift`,
  `DatabaseViewerModelTests.swift`, `DatabaseViewerSourceGatingTests.swift`.

Docs: `docs/architecture/core-database-viewer.md` (the reserved "What part 2b adds"
section becomes the real thing), `CLAUDE.md` (index lines + the invariant paragraph),
`docs/FEATURES.md`, `README.md`.

### Related patterns

- `LocalChangesModel` / `DatabaseViewerModel`: `@MainActor ObservableObject`, I/O behind
  an injected seam, overlapping work ordered by a monotonic token bumped in the
  **synchronous prefix** before the first `await`.
- `DatabaseViewerModel.updateCell`: the refusal order a write is asked in, the gate
  consulted through an injected closure, `didWrite` after a commit only.
- `ScriptedDatabaseService`: answers keyed by SQL text, an unscripted call throws,
  `Gate` holds a call open while a test stages a race.
- `DatabaseViewerTabs`: the gate question and the write hook arrive as closures, so no
  viewer file names `localChanges`.

### Dependencies

None. `project.yml`, `Package.resolved` and the license manifest are untouched; SQLite
stays imported in exactly one file.

## Development Approach

- **Testing approach**: Regular (code first, then tests) for the app-side files that
  cannot be tested at all; **TDD** for every Core decision, which is where the whole
  feature lives.
- Complete each task fully before moving to the next.
- Core is Foundation-only and imports no SQLite; app views are thin and `#if os(macOS)`.
- Generation tokens are captured synchronously before every hop; every failure carries
  SQLite's own sentence; nothing is silently swallowed.
- No product or brand names anywhere.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting the next task**

## Implementation Steps

### Task 1: The console's pure vocabulary and policy

**Files:**
- Create: `Sources/PisakaCore/DatabaseConsolePlan.swift`
- Create: `Tests/PisakaCoreTests/DatabaseConsolePlanTests.swift`

- [x] `DatabaseConsoleStatementKind` — a closed `.read` / `.write`, which is SQLite's
      answer for one prepared statement and never a judgement of ours.
- [x] `DatabaseConsoleClassification` — the whole text's answer as far as it could be
      read: `kinds` in statement order, plus `deferral: Deferral?` — the case that
      says **"classified up to statement k, the rest deferred"**, carrying SQLite's
      verbatim message from the prepare that stopped it. `classifiedCount` is
      `kinds.count`; `isComplete` is `deferral == nil`; `writeCount` counts `.write`;
      `isMutating` is `writeCount > 0`; a text that held no statements at all (blank,
      or only comments) is empty and complete, which is a state and not a failure.
      Documented: a deferral is **not** an error by itself — whether it is depends on
      what was classified before it, which is the policy's job.
- [x] `DatabaseConsolePlan.decide(_ classification:)` — the whole confirmation policy,
      four answers:
      - `.nothingToRun` — empty and complete.
      - `.refuse(message:)` — deferred with **no write** among the statements
        classified so far (including the case where nothing classified at all, i.e.
        an ordinary syntax error at statement one). A read cannot have created what
        the next statement needs, so the prepare failure *is* the answer: SQLite's
        message, and nothing runs.
      - `.confirmWrite(prompt:)` — any `.write` among the classified statements,
        deferred or not.
      - `.read` — complete, non-empty, all read-only. This is the only answer that
        reaches `runConsoleRead`, so that member never sees a deferred text.
- [x] The prompt sentence, composed here and shown verbatim by the app: how many
      statements were classified, how many of them change the database, that they run
      as one transaction which rolls back whole if any of them fails, and — when
      deferred — that the rest of the text is classified as it runs, inside that same
      transaction, so a failure there rolls everything back too; plus, when the batch
      also holds a read, that rows a query inside a mutating batch returns are not
      shown. Singular/plural spelled out rather than "1 statement(s)".
- [x] `DatabaseConsolePlan.rowLimit = 500` — the one cap, with its reasoning (a page
      is turnable, a cap is not; the grid's 200 is a different number for a different
      question and the two must not be tied).
- [x] The footer sentences: `resultFooter(rowCount:isTruncated:)` ("500 rows · first
      500 rows shown" when truncated, the plain count otherwise, "No rows" for an
      empty answer) and `affectedRowsFooter(_:)` ("1 row changed" / "N rows changed" /
      "No rows changed").
- [x] The refusal sentences the console owns, because SQLite has no words for them:
      the disk-writer gate's, "a run is already in flight", and "nothing to run".
- [x] Tests: the policy's four answers over every classification shape — empty;
      all-read complete; all-write complete; mixed complete; single statement of each
      kind; **read-only prefix then a deferral → `.refuse` carrying SQLite's exact
      message**; **write prefix then a deferral → `.confirmWrite`**; nothing
      classified at all + deferral → `.refuse`; a deferral at index 0 with a write at
      index 0 is impossible by construction and is asserted as such. The prompt's
      wording for 1 / n statements, with and without a read in the batch, and with and
      without a deferral. The footers at 0, 1, n and truncated. The bookkeeping
      (`classifiedCount`, `writeCount`, `isComplete`). The cap is a stated constant and
      is not `DatabasePage.defaultSize`.
- [x] run `swift test` — must pass before task 2

### Task 2: The seam's console half

**Files:**
- Modify: `Sources/PisakaCore/DatabaseServicing.swift`
- Modify: `Tests/PisakaCoreTests/Support/ScriptedDatabaseService.swift`
- Modify: `Tests/PisakaCoreTests/DatabaseServicingTests.swift`

- [x] `DatabaseConsoleAnswer` — what a console read answered: `columnNames`, `rows`,
      `isTruncated`. Documented as the **last** statement in the text that answered
      columns, with truncation being that statement's.
- [x] `DatabaseConsoleTransaction` — `url`, the reader's `text` **verbatim**, and
      `readRowLimit` (what a read-only statement *inside* a mutating batch may be
      stepped to before it is abandoned; a non-read-only statement is always stepped to
      completion, because abandoning one would half-perform it — an
      `INSERT … RETURNING` is the case that makes this rule necessary).
- [x] Three protocol members, each defaulted in the extension to the same honest
      refusal `performWrite(_:)` uses (`sqlError`, because SQLite has no words for a
      failure it never saw), so a conformer with no console half refuses rather than
      fails to compile:
      - `classifyConsole(_ text: String) async throws -> DatabaseConsoleClassification`
        — prepares statement by statement through the tail and **runs none**;
      - `runConsoleRead(_ text: String, rowLimit: Int) async throws -> DatabaseConsoleAnswer`;
      - `performConsoleWrite(_ transaction: DatabaseConsoleTransaction) async throws -> DatabaseWriteOutcome`.
- [x] Document on the seam the four rules the app half owes:
      1. the text is carried verbatim and never rewritten (**the console is the one
         stated exception to "Core composes every byte of SQL"**);
      2. `classifyConsole` **does not throw on a prepare failure** — it returns what it
         classified plus the deferral carrying SQLite's message, because whether that
         failure is fatal is the policy's decision, not the seam's; it throws only for
         a failure that is not about the text (no connection, and the like);
      3. the read run steps only statements SQLite itself reports read-only and refuses
         any other rather than writing through the read path;
      4. a console run leaves the connection in autocommit — a statement that opened a
         transaction of its own is rolled back before the member returns, so a stray
         `BEGIN` cannot freeze the tab's read snapshot for the life of the tab.
- [x] `performWrite(_:)` and `DatabaseWriteOutcome` are **not touched**; say so in the
      doc comment, next to the cell edit's exact-count rule.
- [x] `ScriptedDatabaseService`: script a classification per text (deferral included),
      script console read answers (a queue, last sticky, as everything else there),
      script console write outcomes, record every text and transaction handed over
      (`consoleTexts`, `consoleTransactions`), and a `Gate` hook for each of the three
      so a test can hold one open. An unscripted console call throws, like every other
      unscripted call.
- [x] Tests: the three defaults refuse honestly (extend the existing `FixedAnswerStub`
      cases); the fake's queue/sticky/record behavior for the console half, including
      a scripted deferral round-tripping unchanged.
- [x] run `swift test` — must pass before task 3

### Task 3: The console model, and the viewer's post-write refresh

**Files:**
- Create: `Sources/PisakaCore/DatabaseConsoleModel.swift`
- Modify: `Sources/PisakaCore/DatabaseViewerModel.swift`
- Create: `Tests/PisakaCoreTests/DatabaseConsoleModelTests.swift`
- Modify: `Tests/PisakaCoreTests/DatabaseViewerModelTests.swift`

- [x] `DatabaseConsoleModel`: `@MainActor ObservableObject` holding the same
      `DatabaseServicing` instance the tab holds, plus four closures — the current
      `fileURL`, `isWriteBlocked`, `didWrite`, and `refreshAfterWrite` — so it names
      neither the gate nor the tab's url directly and follows a rename for free.
      Published: `answer` (the last `DatabaseConsoleAnswer`), `footer`, `message`
      (**the console's own slot**), `affectedRows`, `isRunning`, `isWriting`, and
      `pendingConfirmation` (the prompt awaiting an answer).
- [x] `run(_ text: String)`: bump the console token synchronously, then
      `classifyConsole` — **nothing runs until the text has been classified as far as
      it can be**. Then `DatabaseConsolePlan.decide(_:)` and nothing else: `.nothingToRun`
      says so, `.refuse(message)` puts SQLite's message in the console's slot and runs
      nothing, `.read` runs immediately, `.confirmWrite` publishes `pendingConfirmation`
      and stops. The model holds the classified text so `confirm()` sends **that exact
      string**.
- [x] `confirm()` / `cancel()`: cancelling clears the pending confirmation and changes
      nothing at all. Confirming asks the refusals in this order, each with its own
      sentence and **nothing sent** until all pass: the disk-writer gate (asked here,
      immediately before sending, not before the prompt — the gate can rise while the
      reader reads it), then "a write is already in flight" (the console's own or the
      tab's cell edit — one write per tab), then `performConsoleWrite`.
- [x] A console mutation is deliberately **not** refused by a page load in flight:
      unlike a cell edit it is planned against nothing on screen. Documented at the
      refusal list.
- [x] After a committed console write, in this order: publish the affected-row footer
      and clear the console's message → `didWrite()` (Local Changes, told even if the
      run was superseded, because it is about the file and not the screen) →
      `await refreshAfterWrite()`. A rollback or a throw — including a prepare failure
      on a deferred statement, which rolls the whole batch back — publishes SQLite's
      sentence and refreshes nothing.
- [x] A read's answer replaces the previous one; a **failed** run replaces nothing — the
      previous result and the table grid both stand under the message. The console's
      slot is never written by a page turn and never cleared by one.
- [x] One generation token: bumped in each run's synchronous prefix, and a superseded
      run publishes nothing (not its rows, not its message, not its spinner) — with
      `didWrite` the one stated exception, for `updateCell`'s reason.
- [x] `DatabaseViewerModel`: own the console (`public let console: DatabaseConsoleModel`,
      built in `init` with the four closures);
      `public var isWriteInFlight { isWriting || console.isWriting }`; `close()` stops
      the console (token bumped, flags lowered) as it does the two loads.
- [x] `DatabaseViewerModel.refreshAfterWrite()`: bump the rows token synchronously,
      record `pendingReselection = selectedTable`, then `await load()` — so the listing
      is re-read (a created table appears, a dropped one goes) and `reselectIfPending()`
      does the rest: re-select as a *refresh* (the sort and page index survive; the
      schema, identity, count and page are re-queried), or — for a table the new
      listing does not hold — the exact clear-everything path a reload that lost its
      table already takes. No connection re-open: a console write does not replace the
      file's inode.
- [x] Tests (against `ScriptedDatabaseService`, races staged with `Gate`, no timed
      delays): a read publishes rows/columns/footer; truncation reaches the footer; a
      mutating text asks and runs nothing until confirmed; declining runs nothing and
      sends nothing; confirming sends **the text verbatim** in one transaction and
      reports the count; **a read-only prefix then a deferral is refused with SQLite's
      message and sends nothing**; **a write prefix then a deferral asks, runs, and a
      failure the app half reports for a deferred statement leaves the model saying
      SQLite's sentence with nothing refreshed and no `didWrite`**; the gate refusal
      (and that a read is **not** refused while the gate is up); the in-flight refusal
      for both the console's own write and a cell edit; a failed run leaves the
      previous result and the grid untouched; the message slot's independence from the
      viewer's in both directions; the post-mutation order (footer → `didWrite` →
      listing → re-selection → count/page); a dropped selected table landing exactly
      where a lost reload leaves it; a created table appearing in `entries`; a
      superseded console run publishing nothing while still calling `didWrite`;
      `close()` stopping the console.
- [x] run `swift test` — must pass before task 4

### Task 4: The app half — prepare by tail, step within the cap, one bracket

**Files:**
- Modify: `Sources/Pisaka/Platform/DatabaseConnectionService.swift`

- [x] One private prepare-by-tail loop used by all three members: prepare from the
      current offset, hand the statement to the body, advance to the tail SQLite
      reports, stop at the end of the text. This is what makes "how many statements the
      text holds" an answer rather than a guess, and it is the machinery
      `execute(_:on:)` deliberately does not have (its nil tail pointer is correct for
      a Core-composed single statement and must stay that way).
- [x] `classifyConsole`: prepare each statement on the **tab's read connection**, read
      `sqlite3_stmt_readonly`, finalize, and step nothing. A prepare failure **ends the
      loop and is returned as the deferral** with SQLite's verbatim message and the
      index — never thrown, because prepare resolves names against the schema as it
      stands *now* and the statements before it have not run yet. (Preparing a mutating
      statement on a read-only connection succeeds — SQLite refuses at step time, not
      at prepare time — which is what makes classification free and side-effect-free.)
- [x] `runConsoleRead`: on the read connection, in order; it is only ever given a fully
      classified read-only text (the policy's `.read`). A statement SQLite does not
      report read-only is still refused rather than stepped (belt and braces against a
      text whose meaning changed between classification and the run). Rows are
      collected up to `rowLimit`, then one further step decides `isTruncated`, then the
      statement is finalized. The answer kept is the **last** statement whose column
      count was non-zero, with its own truncation flag.
- [x] `performConsoleWrite`: a separate, short-lived read-write connection at the
      transaction's url (never creating), foreign keys on, `BEGIN IMMEDIATE`, then the
      same prepare-by-tail loop over the reader's text — **each statement prepared as
      it is reached, after the earlier ones have run**, which is what lets a migration
      the classifier could not see through run correctly. Accumulate `sqlite3_changes`;
      **commit on success** whatever the total; a prepare failure or a step failure
      anywhere throws with SQLite's message and rolls the whole batch back; close on
      every path; checkpoint the WAL after a commit. A read-only statement inside the
      batch is stepped at most `readRowLimit` and abandoned, its rows discarded; a
      non-read-only one is always stepped to completion.
- [x] Both console run paths leave the connection in autocommit: after the loop, if
      `sqlite3_get_autocommit` says a transaction is open, roll it back.
- [x] The tab's connection stays `SQLITE_OPEN_READONLY` and there is still exactly one
      `SQLITE_OPEN_READWRITE` open in the file — the console write reuses
      `openReadWrite(at:)` rather than adding a second one.
- [x] Tests: this file links SQLite and is untestable by `swift test` by convention; its
      rules are pinned statically in task 6 instead (the open flags by count, the single
      read-write site, the import). The behavior it implements is covered through the
      scripted seam in task 3.
- [x] run `swift test` and the macOS build — must pass before task 5

### Task 5: The pane

**Files:**
- Create: `Sources/Pisaka/DatabaseConsoleView.swift`
- Modify: `Sources/Pisaka/DatabaseViewerView.swift`

- [x] `DatabaseConsoleView`, `#if os(macOS)`: a multi-line input, a Run control with
      ⌘↩, the result table, its footer, and the console's message. It decides nothing —
      every sentence it draws is Core's, and the confirmation is Core's prompt shown in
      a dialog whose two answers call `confirm()` / `cancel()`.
- [x] The result table draws `DatabaseValue.displayText` with NULL styled from `isNull`
      — **the same one rendering the grid uses**, so the two can never disagree about
      the one distinction the viewer must not blur. Its own compact table rather than
      the grid's rows, which carry edit affordances a console result must not have.
- [x] Everything sized through `\.interfaceMetrics`; the input is
      `metrics.scaledFont(.body, design: .monospaced)` — monospaced, interface zone. No
      `ZoomSurface` is declared, and the file states why (the tab is one zoom zone; the
      surface set stays exactly what `ZoomSourceGatingTests` pins).
- [x] The input is `@State` in the view: transient pane state, never persisted, never
      part of the session, never a dirty buffer.
- [x] `DatabaseViewerView` hosts the pane below the grid in a resizable split, observing
      both the viewer model and `model.console`, and disables — from the one Core answer
      `model.isWriteInFlight` — the two paging buttons, the sort headers, and (with the
      console's own `isRunning`) Run. `isGridIdle` grows the same term, so no editor
      opens over an in-flight console mutation either.
- [x] Tests: the view layer is untested by convention; its rules are pinned in task 6.
- [x] run `swift test`, the macOS build and the iOS build — must pass before task 6

### Task 6: The gating suite

**Files:**
- Modify: `Tests/PisakaCoreTests/DatabaseViewerSourceGatingTests.swift`

- [ ] The console asks the gate exactly once and **before anything is sent**: inside
      `DatabaseConsoleModel`, `isWriteBlocked()` occurs once and precedes the
      `performConsoleWrite(` call site — the `updateCell` rule, restated for the second
      writer. The existing "exactly one" assertion on `DatabaseViewerModel` is kept as
      it stands, with its comment saying why there are now two places and not one.
- [ ] The console's read path names neither the gate nor the hook (the
      `testTheReadPathNamesNeitherTheGateNorTheHook` shape, extended with the console's
      `run(_:)` and `classifyConsole`).
- [ ] The console composes no SQL: no Core console file names `DatabaseQuery`, and
      `DatabaseQuery.swift` names no console member — the console's text is the
      reader's and travels verbatim, which is the one stated exception to Core-composed
      SQL and must stay an exception rather than a second composer.
- [ ] The reader's text reaches the seam through exactly one call site each:
      `runConsoleRead(` and `performConsoleWrite(` occur once apiece in
      `DatabaseConsoleModel`.
- [ ] The three existing rules that must keep holding are covered for the new files
      automatically by `databaseFiles()`' name prefix (macOS gating, no `localChanges`,
      no writer gate) — assert that the new files are actually in that set rather than
      trusting the prefix silently.
- [ ] `PisakaApp.swift`'s tab-kind filter counts are unchanged (nine `.text`, two
      `.viewer`): the console needs nothing in the scene, since the gate question and
      the write hook are already wired.
- [ ] run `swift test` — must pass before task 7

### Task 7: Documentation

**Files:**
- Modify: `docs/architecture/core-database-viewer.md`, `CLAUDE.md`, `docs/FEATURES.md`,
  `README.md`, `Sources/PisakaCore/DatabaseQuery.swift`,
  `Sources/PisakaCore/DatabaseValue.swift`

- [ ] `core-database-viewer.md`: the reserved "What part 2b adds" section becomes the
      feature's real entries — one per new file, plus the four decisions above with
      their reasoning (the honest classification rule and why a read-only prefix's
      prepare failure is the answer while a write prefix's is not; in-order
      multi-statement and why the last column-answering statement is the one shown; the
      second write member and why not an optional requirement; the cap and why it is not
      the page size), the seam's three new members and the four rules the app half owes,
      the post-mutation refresh order, and the console's own message slot. The
      document's opening paragraph stops saying part 2b is elsewhere. The "known limits"
      list gains the console's:
      - `ATTACH`/`DETACH` are reported read-only by SQLite, so one typed alone runs on
        the tab's read connection and the attachment lasts the life of the tab; the
        attached database inherits the connection's read-only flag, so nothing can be
        written through it, and closing the tab drops it.
      - rows from a mutating batch are not shown;
      - no history, saved queries or highlighting;
      - a read batch is not one snapshot;
      - classification sees kinds, never shapes, and only as far as the first prepare
        failure.
- [ ] `DatabaseQuery.swift`'s header — still the only thing that *composes* SQL, with
      the console named as the one stated exception (text carried verbatim, never
      parsed, rewritten or composed).
- [ ] `DatabaseValue.swift` — the "in part 2 the console's result table" note becomes
      the present tense.
- [ ] `CLAUDE.md`: index lines for `DatabaseConsolePlan.swift`,
      `DatabaseConsoleModel.swift` and `DatabaseConsoleView.swift`, and the
      database-viewer invariant paragraph updated — the console as the one stated
      exception to Core-composed SQL, classification being SQLite's and honest about its
      horizon, the write half now being two members with two rules, and paging/sort/Run
      disabled while a write is in flight. Kept to the index-and-invariant discipline:
      no per-file essays, and the file stays well under its target size.
- [ ] `docs/FEATURES.md` and `README.md`: the console as a user-facing feature — what
      runs without asking, what asks, what the footer says, and the cap.
- [ ] run `swift test` — must pass before task 8

### Task 8: Verify acceptance criteria

- [ ] `swift test` — the whole suite green
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- [ ] `swiftlint --strict` from the repository root — clean
- [ ] `git status` confirms `project.yml`, `Package.resolved` and `Resources/Licenses/`
      are untouched
- [ ] Re-read the acceptance list in the ticket against the tests that cover each item,
      and name in the final report any criterion that only a manual run can show

## Post-Completion (manual, by the user)

- Open a database tab in a DEBUG build and run: a `SELECT` under the cap and one over
  it; `CREATE TABLE x(a); INSERT INTO x VALUES(1);` as one confirmed batch (the case
  classification cannot see through); a `DROP TABLE` of the selected table (lands where
  a lost reload lands); a syntax error (grid and previous result unchanged); a mutation
  while a checkout is in flight.
- Confirm Local Changes shows the database as modified.
