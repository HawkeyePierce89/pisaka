# Database viewer, part 2a: inline cell editing (macOS)

## Overview

Make the database viewer tab a writer of exactly one shape: an edited grid cell
becomes a parameterized `UPDATE … SET … WHERE`, addressed by `rowid` or by every
primary-key column and **conditioned on the value the grid was showing**, run in
a transaction on a short-lived read-write connection that commits only when
exactly one row changed. Every decision — which rows are addressable, which
schema column a grid column *is*, what a typed string means as a bound value,
whether an edit is allowed at all, what an affected-row count means — is pure
Core. The app half gains one new mechanical member on the SQLite side and one
wiring line in the scene.

The SQL console is deliberately **not** in this plan; it is part 2b, written
against the write path this one establishes. This file ships complete and usable
on its own.

## Context

- Files involved (Core): `Sources/PisakaCore/DatabaseValue.swift`,
  `DatabaseQuery.swift`, `DatabaseSchema.swift`, `DatabaseServicing.swift`,
  `DatabasePage.swift`, `DatabaseViewerModel.swift`; new
  `DatabaseCellEntry.swift`, `DatabaseRowIdentity.swift`,
  `DatabaseUpdatePlan.swift`.
- Files involved (app, macOS):
  `Sources/Pisaka/Platform/DatabaseConnectionService.swift`,
  `Sources/Pisaka/DatabaseViewerTabs.swift`, `Sources/Pisaka/DatabaseViewerView.swift`,
  `Sources/Pisaka/PisakaApp.swift` (one wiring call), `.swiftlint.yml` (measured
  ceiling bump, with its reason in the comment as every previous bump has).
- Tests: `Tests/PisakaCoreTests/Database*Tests.swift`,
  `Tests/PisakaCoreTests/Support/ScriptedDatabaseService.swift`,
  `DatabaseViewerSourceGatingTests.swift`.
- Docs: `docs/architecture/core-database-viewer.md` (its "What part 2 adds"
  section becomes the real part 2a half plus a reduced note on the console),
  `CLAUDE.md` (index lines + the viewer invariant paragraph), `docs/FEATURES.md`
  and `README.md` (user-facing: cells are editable).
- Related patterns: `GitServicing`'s defaulted later arrivals (the seam grows
  defaulted members); `LocalChangesModel`'s generation tokens and one-message
  slot; `DatabaseQuery` as the only SQL in the repository; the reader rule the
  viewer keeps (it consults the disk-writer gate, never raises it).
- Dependencies: none. `project.yml`, `Package.resolved` and the license manifest
  are untouched; SQLite stays imported in one app file.

## Decisions this plan makes (and the doc will record)

1. **Row identity travels as a trailing result column, and is split off by
   position, never by name.** A rowid table's page is
   `SELECT *, rowid FROM "t" [ORDER BY n dir] LIMIT ? OFFSET ?` — the alias
   **bare** (decision 3), appended **last** so every existing 1-based `ORDER BY`
   ordinal, every grid column position and the `LIMIT 0` shape probe keep meaning
   exactly what they meant in part 1. The trailing column's *name is not
   `rowid`*: on a table with an `INTEGER PRIMARY KEY` alias SQLite answers it
   under the alias column's name (verified: `SELECT *, rowid FROM r` answers
   `id|v|id`), and it is named `rowid` only when no alias exists. So both the
   split and the "does this answer carry identity at all?" test go by **position
   and count** — `answer.columnNames.count == gridColumns.count + 1`, last column
   is the identity — and never by matching a name. The model publishes
   `rows`/`gridColumns` without it, so the grid shows no column the user did not
   ask for. A `WITHOUT ROWID` table appends nothing: its key columns are ordinary
   result columns, located by decision 4.

2. **`WITHOUT ROWID` is decided by a probe SQLite answers, not by regex over the
   `CREATE` text and not by `PRAGMA table_list`.** The probe is
   `SELECT rowid FROM "t" LIMIT ?` bound to zero — the table name quoted, the
   alias **bare**: it prepares, learns nothing, steps straight to done on a rowid
   table, and fails at prepare with SQLite's own `no such column: rowid` on a
   `WITHOUT ROWID` one. It answers the question the feature actually has — *can
   this table be addressed by rowid?* — rather than the schema trivia
   `table_list.wr` reports, it needs no version floor, and it costs one prepare
   and zero rows. A probe failure of any kind means "no rowid here" and degrades
   to the primary-key strategy; it never publishes an error, because reading the
   page still works and the refusal (with its reason) is what the reader sees if
   they try to edit.

3. **The three rowid alias spellings are the one deliberately unquoted name in
   `DatabaseQuery`, and a shadowed alias is caught rather than guessed.**
   `rowid`, `_rowid_` and `oid` are written bare and **must not** go through
   `quoted(_:)`: SQLite's double-quoted-string fallback turns an unresolved
   quoted identifier into a string *literal*, so `SELECT "rowid" FROM w LIMIT 0`
   on a `WITHOUT ROWID` table succeeds and answers the text `'rowid'` (verified,
   exit 0) — which would classify every such table as rowid-addressable, carry
   the literal `'rowid'` as every row's identity, and make every edit report
   "changed underneath you". Bare, all three fail honestly. The exception is
   safe because it is a **closed set of three literals chosen by this decision,
   never user input**; the file says so at the constant, and the query tests
   assert the bare spelling byte-for-byte so a later "tidy-up" through
   `quoted(_:)` fails the suite. The shadowing rule likewise only works bare: a
   table may declare a column named `rowid`, `_rowid_` or `oid`, and SQLite then
   resolves *that* bare name to the declared column while the other two still
   answer the true rowid (verified). The identity engine therefore picks the
   first of the three spellings that no declared column shadows
   (case-insensitively); if all three are shadowed it falls back to the
   primary-key strategy, and if that is unavailable the table is not editable,
   by typed refusal.

4. **A grid column is matched to a schema column by the answered name, not by
   position — and an ambiguous or absent name is a refusal.** Part 1 reads the
   schema through `PRAGMA table_xinfo`, which lists hidden columns that `SELECT *`
   omits (a virtual table's), so schema ordinals and result ordinals diverge and
   a positional map would silently edit the wrong column. Both the planner and
   the surface's "may this cell be edited?" answer look the grid column's
   answered name up in the schema, case-insensitively; **no unique match is a
   typed refusal**, not a guess. The same lookup locates a `WITHOUT ROWID`
   table's key columns in the answered row.

5. **The affected-row rule travels to the app half as data, because rollback has
   to happen inside the connection's life.** The seam gains one defaulted member,
   `performWrite(_:)`, taking a Core-composed `DatabaseWriteTransaction`
   (`url`, the statements in order, `requiredAffectedRows`) whose begin / commit /
   rollback texts are `DatabaseQuery` constants like everything else. The app half
   opens a read-write connection at `url` with the same busy timeout, runs the
   transaction, compares the accumulated affected rows against the required count,
   commits on a match and rolls back otherwise, closes, and answers a
   `DatabaseWriteOutcome` (`affectedRows`, `isCommitted`). It compares numbers; it
   decides nothing. Core decides what the outcome *means*.

6. **The write connection carries the URL explicitly**, rather than reusing the
   one the read connection opened with: a viewer tab outlives the path it was
   opened at (a rename retargets it, `reload(at:)` follows), and the model's
   `fileURL` is the one thing that is current.

7. **`IS`, not `=`, in the `WHERE`.** The row is addressed by identity **and** by
   the cell's previous value, and both may be NULL; `IS` is SQLite's null-safe
   comparison, so a NULL previous value is matched honestly instead of matching
   nothing. This is also what makes NULL and the empty string stay distinct
   through a write.

8. **The typing rule.** What is typed is text; what is bound is a `DatabaseValue`
   chosen by the column's declared **type affinity** (SQLite's own five-rule
   determination, implemented and tested against its documented examples).
   INTEGER/REAL/NUMERIC bind an integer when the whole string is one, a finite
   real when the whole string is one, and text otherwise; TEXT binds text always.
   For **BLOB/no affinity — an untyped column, common in ad-hoc databases — the
   cell's previous storage class wins when the entry parses as it**: typing `43`
   over the integer `42` stores an integer, typing `43` over the text `42` stores
   text, and anything that does not parse as the previous class stores text. This
   is chosen over "always text" so that editing one cell of an untyped column does
   not silently retype it out from under every query that compares it; it is
   stated in the doc and pinned by tests both ways. Nothing is trimmed — what you
   typed is what is stored. An empty entry is the empty string, never NULL; NULL
   is reachable **only** through an explicit "Set to NULL" gesture, never by
   typing the word.

9. **The viewer consults the disk-writer gate and never raises it.** The model
   takes an injected `isWriteBlocked` predicate and refuses a write while a
   worktree-mutating operation is in flight, with a message; the read side is
   untouched. The predicate is wired in the scene to `LocalChangesModel.isReverting`
   — the same flag ⌘S and the tree file operations refuse on — so no file under
   the viewer names a gate call at all, and the gating suite keeps pinning that.
   After a committed write the model calls an injected `didWrite` hook, wired to
   the same generation-pinned `refreshLocalChanges()` a save uses.

10. **Part 1's open question is answered.** Termination's best-effort `closeAll()`
    stays correct: writes are short-lived connections that commit and close before
    `performWrite` returns, so a viewer tab never holds unflushed state.

## Development Approach

- **Testing approach**: TDD for the four pure Core engines (tasks 1–4), regular
  for the model and app halves; every task ends green.
- Complete each task fully before moving to the next.
- Core stays Foundation-only; app views stay thin and `#if os(macOS)`.
- Generation tokens are captured synchronously before every hop.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**

## Implementation Steps

### Task 1: The typing rule

**Files:**
- Create: `Sources/PisakaCore/DatabaseCellEntry.swift`
- Create: `Tests/PisakaCoreTests/DatabaseCellEntryTests.swift`

- [x] add `DatabaseTypeAffinity` (`integer`, `text`, `blob`, `real`, `numeric`)
      with `init(declaredType:)` implementing SQLite's five ordered rules,
      case-insensitively, over a possibly empty declaration
- [x] add the entry rule: typed text + affinity + **previous value** →
      `DatabaseValue`, per decision 8 — no trimming, empty entry is `text("")`,
      the word "null" is never NULL, overflowing integers fall to real then to
      text, non-finite input stays text
- [x] implement the untyped-column clause: for `blob` affinity the previous
      value's storage class is preferred when the entry parses as it, text
      otherwise
- [x] add the explicit NULL gesture as its own value-producing entry point, so no
      caller can reach NULL by string
- [x] write tests: every affinity rule including the documented examples
      (`INT`/`VARCHAR(255)`/`BLOB`/`FLOATING POINT`/`STRING`/empty), the numeric
      cases, empty entry vs. NULL, "NULL"/"null"/"nil" typed as text, whitespace
      preserved, `Int64` boundary values; and the untyped column both ways —
      `43` over integer `42` stays integer, `43` over text `42` stays text, `4x`
      over integer `42` becomes text, over a NULL previous value becomes text
- [x] run `swift test` — must pass before task 2

### Task 2: Row identity — the engine and the two statements

**Files:**
- Create: `Sources/PisakaCore/DatabaseRowIdentity.swift`
- Modify: `Sources/PisakaCore/DatabaseQuery.swift`
- Create: `Tests/PisakaCoreTests/DatabaseRowIdentityTests.swift`
- Modify: `Tests/PisakaCoreTests/DatabaseQueryTests.swift`

- [x] add the three bare alias spellings as a `DatabaseQuery` constant with
      decision 3's reasoning written at it: the one name never passed through
      `quoted(_:)`, a closed set of three literals, never user input
- [x] add `DatabaseRowIdentity`: the strategy (`rowid(spelling)` /
      `primaryKey(columns)` / `unavailable(reason)`) resolved from the entry kind,
      the columns and the probe's answer, per decisions 2, 3 and 4 — including
      the rule that every key column must resolve to exactly one answered column
      by name
- [x] add `DatabaseQuery.rowIdProbe(table:)` (`SELECT rowid FROM "t" LIMIT ?`
      bound to zero) and extend `DatabaseQuery.page(…)` with the optional trailing
      identity column, leaving the sort ordinal, the `LIMIT`/`OFFSET` binding and
      the floors exactly as they are
- [x] write tests: strategy for a plain table, a view, a `WITHOUT ROWID` table
      with a single and with a composite key, each of the three spellings shadowed
      in turn (and all three shadowed), a key column absent from the answer, a key
      column whose name matches two answered columns; **the byte-for-byte SQL of
      the probe and of the identity-carrying page**, asserting the alias appears
      bare and unquoted (sorted and unsorted, with the ordinal proven unchanged by
      the appended column)
- [x] run `swift test` — must pass before task 3

### Task 3: The update-plan engine and its refusals

**Files:**
- Create: `Sources/PisakaCore/DatabaseUpdatePlan.swift`
- Modify: `Sources/PisakaCore/DatabaseQuery.swift`
- Create: `Tests/PisakaCoreTests/DatabaseUpdatePlanTests.swift`
- Modify: `Tests/PisakaCoreTests/DatabaseQueryTests.swift`

- [x] add `DatabaseEditRefusal` — the typed reasons, each with the sentence the
      banner shows: the entry is a view; the column is generated or hidden; the
      column has no unique match in the schema by name (decision 4); the cell (old
      or new value) is a blob; the table is `WITHOUT ROWID` and its full key is
      unavailable; the table declares no usable row identity
- [x] add `DatabaseUpdatePlan` and the pure planner: schema + identity strategy +
      identity values + previous value + new value → a plan carrying one
      `DatabaseStatement` and `requiredAffectedRows == 1`, or a refusal; the grid
      column is resolved to its schema column **by answered name**, per decision 4
- [x] add `DatabaseQuery.update(table:column:identity:)` composing
      `UPDATE "t" SET "c" = ? WHERE <identity IS ?…> AND "c" IS ?` — identifiers
      through `quoted(_:)` (the rowid alias the one bare name), every value bound,
      binding order fixed and asserted
- [x] add the transaction texts (`beginImmediate`, `commit`, `rollback`) as
      `DatabaseQuery` constants, so no SQL is spelled outside this file
- [x] write tests: the plan for a rowid table and for a composite-key
      `WITHOUT ROWID` table (every key column in the `WHERE`, in key order); every
      refusal by reason; **a schema whose hidden column precedes a visible one, so
      a positional map would name the wrong column — the plan must name the right
      one, and an unmatched name must refuse**; a NULL previous value and a NULL
      new value; that no cell content ever reaches `sql` (a value spelling
      `'; DROP TABLE` travels bound); identifier quoting for names holding quotes
      and spaces
- [x] run `swift test` — must pass before task 4

### Task 4: The seam's write member

**Files:**
- Modify: `Sources/PisakaCore/DatabaseServicing.swift`
- Modify: `Tests/PisakaCoreTests/Support/ScriptedDatabaseService.swift`
- Modify: `Tests/PisakaCoreTests/DatabaseServicingTests.swift`

- [x] add `DatabaseWriteTransaction` (url, statements, `requiredAffectedRows`) and
      `DatabaseWriteOutcome` (`affectedRows`, `isCommitted`) as Core value types,
      documenting decisions 5 and 6 on them
- [x] add `performWrite(_:) async throws -> DatabaseWriteOutcome` to
      `DatabaseServicing`, **defaulted** to throwing an honest "this connection is
      read-only" `DatabaseError`, the way `GitServicing`'s later arrivals arrived
- [x] teach `ScriptedDatabaseService` to script write outcomes and failures, to
      record the transactions it was handed, and to gate one mid-flight (the
      existing `Gate` rendezvous) so the race tests in task 6 can stage
- [x] write tests: the default member refuses honestly; the scripted one records
      the transaction verbatim
- [x] run `swift test` — must pass before task 5

### Task 5: The model carries row identity through every load

**Files:**
- Modify: `Sources/PisakaCore/DatabaseViewerModel.swift`
- Modify: `Tests/PisakaCoreTests/DatabaseViewerModelTests.swift`

- [x] resolve the identity strategy in `select(table:)`: run the probe once per
      selection, combine it with the columns and the entry kind, and hold the
      result beside `shown`
- [x] compose the page with the trailing identity column when the strategy is
      `rowid`, and split it off in `publish(_:table:)` **by position and count**
      (decision 1) so `rows` and `gridColumns` are exactly what part 1 published;
      an answer whose column count is not `grid + 1` is treated as identity-less
      rather than mis-split
- [x] keep the sort-survival check, the carried-sort shape probe and the failure
      restore reasoning working against the **grid** columns, not the raw answer
- [x] expose a read-only `canEdit(columnIndex:)`-style answer the surface greys
      cells out on, derived from the strategy and from the schema column looked up
      **by answered name** (decision 4), never re-derived in the view
- [x] write tests: identity carried and hidden for a rowid table; **the same for a
      table with an `INTEGER PRIMARY KEY` alias, where the trailing column repeats
      the alias column's name — split still correct**; nothing appended for a view
      or a `WITHOUT ROWID` table; a sort ordinal still ordering the same column
      with the identity column present; a probe failure degrading silently with no
      error banner; `canEdit` with a hidden schema column ahead of the visible
      ones; superseded loads still publishing nothing
- [x] run `swift test` — must pass before task 6

### Task 6: The model's write flow

**Files:**
- Modify: `Sources/PisakaCore/DatabaseViewerModel.swift`
- Modify: `Tests/PisakaCoreTests/DatabaseViewerModelTests.swift`

- [x] add the injected `isWriteBlocked` predicate and `didWrite` hook (both
      defaulted so every existing construction site and test is unchanged)
- [x] add `updateCell(row:column:entry:)` and `setCellToNull(row:column:)`:
      refuse under the gate with a message; resolve the plan (refusal → message,
      nothing sent); refuse a second concurrent write on the tab; publish
      `isWriting`
- [x] interpret the outcome: committed → re-query the current page (and only the
      page — the count cannot change) and call `didWrite`; rolled back with zero →
      "this row changed underneath you, nothing was written"; rolled back with more
      than one → say how many it would have touched; a thrown failure → SQLite's
      own words. No path blanks a good page.
- [x] give the message slot a third source so a write's message is not cleared by
      a listing refresh or a page turn, and is cleared by the next successful write
      or by selecting another table
- [x] capture the rows token synchronously before the write hop, so a selection or
      page turn that overtakes a write publishes the newer state and the write
      publishes nothing (the commit still stands, which is honest and asserted)
- [x] write tests, all against the scripted seam: a committed edit re-queries and
      hooks; the gate refusal writes nothing and leaves the page; each typed
      refusal; zero-affected and many-affected rollbacks with their messages; a
      thrown SQLite failure; NULL set and unset round-tripping distinctly from
      `""`; a write superseded mid-flight by a table selection; a second write
      while one is in flight
- [x] run `swift test` — must pass before task 7

### Task 7: The app half — the write connection, the wiring and the gating pins

**Files:**
- Modify: `Sources/Pisaka/Platform/DatabaseConnectionService.swift`
- Modify: `Sources/Pisaka/DatabaseViewerTabs.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `.swiftlint.yml`
- Modify: `Tests/PisakaCoreTests/DatabaseViewerSourceGatingTests.swift`

- [x] implement `performWrite(_:)`: `sqlite3_open_v2` with
      `SQLITE_OPEN_READWRITE` and **no** `SQLITE_OPEN_CREATE`, the same busy
      timeout, `BEGIN IMMEDIATE`, the statements in order accumulating
      `affectedRows`, commit-or-rollback by the required count, rollback on any
      throw, close on every path (including the throwing ones), SQLite's message
      verbatim; the read-only connection and its flags are untouched
- [x] forward the gate predicate and the write hook through `DatabaseViewerTabs`
      into each model it builds, naming no gate call anywhere in the feature
- [x] wire them once in the scene's existing start-once block: the gate flag
      `LocalChangesModel.isReverting` and the generation-pinned local-changes
      refresh a save already uses
- [x] move the two measured lint ceilings by the measured procedure, recording in
      the config comment what the added lines buy (as every previous bump does)
- [x] extend the gating suite: the SQLite import stays in one file; the new Core
      files never import it; the app-side files stay macOS-gated; **no viewer file
      raises the writer gate** (the existing assertion, now covering the write
      path); the model's write entry points consult the gate predicate before
      sending anything; the scene wires that predicate to the gate flag; the
      viewer's read path names neither
- [x] run `swift test` — must pass before task 8

### Task 8: The editable grid

**Files:**
- Modify: `Sources/Pisaka/DatabaseViewerView.swift`

- [x] make a cell editable in place: double-click (or Return on the focused cell)
      opens a field seeded with the value's text — a NULL cell seeds empty, since
      an empty entry means the empty string and NULL is a gesture, not a word;
      Return commits through the model, Escape cancels and writes nothing
- [x] add the explicit "Set to NULL" item to the cell's context menu, alongside a
      "Copy" of the rendered text
- [x] draw the non-editable state honestly: a cell in a view, a generated column,
      a blob cell, a column the schema cannot name uniquely or an unaddressable
      table does not open an editor, and the refusal's own sentence is what the
      banner shows when the reader tries
- [x] disable editing while a write is in flight and while the grid is loading;
      the surface decides none of it — it draws the model's answers, per the
      file's standing rule
- [x] confirm the pane still declares no zoom surface and still sizes everything
      through `\.interfaceMetrics`
- [x] run `swift test` and `swiftlint --strict` — must pass before task 9

### Task 9: Verify acceptance criteria

- [ ] run `swift test`
- [ ] run `xcodebuild` for the macOS destination and for `generic/platform=iOS`
- [ ] run `swiftlint --strict` from the repository root
- [ ] confirm `project.yml`, `Package.resolved` and `Resources/Licenses/` are
      untouched by `git status`

### Task 10: Update documentation

- [ ] rewrite `docs/architecture/core-database-viewer.md`'s "What part 2 adds"
      into the real part 2a half: the ten decisions above with their reasoning
      (including *why* the rowid alias is the one unquoted name and what the
      quoted spelling silently does instead), one entry per new file, the amended
      entries for the seam, the query composer, the model and the connection
      service, the answered termination question, and a shortened note reserving
      the SQL console for part 2b
- [ ] add the three new Core files' index lines to `CLAUDE.md` and amend the
      viewer invariant paragraph: the tab kind still can never be dirty, the
      viewer still never raises the writer gate — but it now *consults* it, its
      one write is a transactional cell update on a separate short-lived
      read-write connection, and the read connection stays read-only
- [ ] note the editable grid in `README.md` / `docs/FEATURES.md` with the NULL
      gesture and what is not editable

## Post-Completion (manual, by the user)

- Edit a cell in a rowid table, reopen the file, confirm it persisted.
- Edit a table with an `INTEGER PRIMARY KEY` alias and a composite-key
  `WITHOUT ROWID` table; confirm the refusals on a view, a generated column and a
  blob cell.
- Change a row from another process between page load and edit; confirm the
  "changed underneath you" message and that nothing was overwritten.
- Confirm Local Changes stays empty after opening/closing a viewer tab and shows
  the database as modified after a committed edit.
- Start a branch switch and attempt an edit; confirm the refusal and that reading
  the same tab is unaffected.
