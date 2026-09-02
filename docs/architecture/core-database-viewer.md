# PisakaCore + Pisaka app (macOS) — the database viewer tab

Design documentation for the database viewer: the rule that recognizes a
database file, the **second kind of tab** it opens into, the async seam that
talks to SQLite, the pure engines that decide every statement, every parsed
answer and every page of rows, the viewer model that orders overlapping loads,
and the macOS surface that draws what Core answered. Read the relevant entry
before modifying that file, and update it when behavior changes.

This is **parts 1 and 2a**, and the seam between them is worth keeping in
mind while reading: part 1 built a reader, part 2a gave it **one write of
exactly one shape** — a grid cell edited in place becomes a parameterized
`UPDATE … SET … WHERE`, addressed by `rowid` or by every primary-key column,
conditioned on the value the grid was showing, and run in a transaction on a
short-lived read-write connection that commits only when exactly one row
changed. The viewer is still macOS-only, its own connection is still opened
read-only, and its tab kind still can never be dirty. What part **2b** adds —
the SQL console — has its seat reserved at the end of this document.

## The shape of the feature, in one paragraph

Opening a `.sqlite` / `.sqlite3` / `.db` file gives you a **viewer tab** instead
of an editor: a sidebar of the database's tables and views, the selected one's
schema, and a paged, sortable grid of its rows. A viewer tab is an ordinary
`OpenFile` with `kind == .viewer`; it carries no text and **can never be
dirty**, which is the invariant every text-assuming consumer in the app rides on
rather than re-deriving. The tab kind is **off by default** and turned on by the
macOS app alone (`WorkspaceModel(viewerTabsEnabled: true)` — the one site),
because the routing lives in Core's `open(url:)` where iOS also opens files and
iOS has no viewer surface. Core composes every byte of SQL and reads every
answer; the app half owns one SQLite connection per tab and knows nothing about
what any of it means. The whole feature is a **reader**: it never raises the
disk-writer gate and is never gated by it.

## Four decisions this feature was built on

1. **The session record did not change.** `SessionTab` stays the flat
   `path`/`text` struct. A viewer tab is persisted as an ordinary `path` record,
   and restore gets it back as a viewer tab because `restoreSession` opens every
   titled record *through* `WorkspaceModel.open(url:)`, which applies the
   recognition rule. One decision point, no new field, no compatibility
   question — and a restore into a workspace with the switch off produces no
   viewer tab at all, which is exactly what iOS wants.

2. **A viewer tab's file is probed, not read.** `open(url:)` for a recognized
   file never calls `fileService.read` — the bytes are not text. Existence is
   established with `fileService.fileStamp(at:)`, and a `nil` stamp throws the
   **new** `FileServiceError.missingFile(name:)`. The enum had no not-found case
   before: the text path learns a file is missing from `String(contentsOf:)`,
   which the viewer path never calls. Restore skips such a record exactly as it
   skips a deleted text file's.

3. **Viewer tabs are off unless the macOS app turns them on.** The iOS layer
   reaches `open(url:)` from four places (`RootView_iOS.swift` ×3 and
   `FilePicker_iOS.swift`), where a viewer tab would render a database as an
   *empty text file*. So `WorkspaceModel.init` carries
   `viewerTabsEnabled: Bool = false`; with it off a database takes the ordinary
   read path and fails exactly as it does today — `FileService.read` is strict
   UTF-8 and a database header does not decode — so iOS fails honestly rather
   than lying quietly. Only `Sources/Pisaka/PisakaApp.swift` passes `true`, and
   `DatabaseViewerSourceGatingTests` pins both halves of that sentence. Giving
   iOS a surface, and therefore the switch, is a follow-up ticket's business.

4. **`PisakaApp.swift` was at its measured lint ceiling and did not simply
   grow.** The per-tab model ownership and connection lifetime live in
   `DatabaseViewerTabs.swift`, a file of their own, so `PisakaApp` paid four
   lines for the feature's wiring plus thirteen for the tab-kind skips rather
   than four hundred. Both ceilings moved by the measured amount only
   (`file_length` 1809 → 1826 → 1829 → 1833 → 1837 → 1838, `type_body_length`
   1800 → 1810 → 1813 → 1817 → 1821 → 1822 — the second step is the viewer
   reconnect below, the fourth part 2a's write wiring and the fifth the rename's
   viewer retarget; `style-lint.md` carries the whole chain), with the reason
   appended to `.swiftlint.yml`'s ceiling comment and both numbers updated in
   `LintConfigurationTests.documentedRootThresholds`. See `style-lint.md`.

## Ten decisions the write path was built on (part 2a)

1. **Row identity travels as a trailing result column, and is split off by
   position, never by name.** A rowid table's page is
   `SELECT *, rowid FROM "t" [ORDER BY n dir] LIMIT ? OFFSET ?` — the alias
   **bare** (decision 3), appended **last** so every 1-based `ORDER BY` ordinal,
   every grid column position and the `LIMIT 0` shape probe go on meaning exactly
   what they meant in part 1. The trailing column's *name is not `rowid`*: on a
   table with an `INTEGER PRIMARY KEY` alias SQLite answers it under the alias
   column's own name (`SELECT *, rowid FROM r` answers `id|v|id`), and it is
   called `rowid` only where no such alias exists. So both the split and the
   "does this answer carry identity at all?" test go by **position and count** —
   the model appended exactly one column and it is the last one — and never by
   matching a name. `rows` and `gridColumns` are published without it, so the
   grid shows no column the reader did not ask for. A `WITHOUT ROWID` table
   appends nothing: its key columns are ordinary result columns, located by
   decision 4.

2. **`WITHOUT ROWID` is decided by a probe SQLite answers**, not by a regex over
   the `CREATE` text and not by `PRAGMA table_list`. The probe is
   `SELECT rowid FROM "t" LIMIT ?` bound to zero: it prepares, learns nothing and
   steps straight to done on a rowid table, and fails **at prepare** with
   SQLite's own `no such column: rowid` on a `WITHOUT ROWID` one. It answers the
   question the feature actually has — *can a row here be addressed by rowid?* —
   rather than the schema trivia `table_list.wr` reports, it needs no version
   floor, and it costs one prepare and zero rows. A probe failure of **any** kind
   means "no rowid here" and degrades to the primary-key strategy; it never
   publishes an error, because reading the page still works and the refusal, with
   its own sentence, is what the reader meets only if they try to edit.

3. **The three rowid alias spellings are the one deliberately unquoted name in
   `DatabaseQuery`, and a shadowed alias is caught rather than guessed.**
   `rowid`, `_rowid_` and `oid` are written bare and **must not** go through
   `quoted(_:)`: SQLite's double-quoted-string fallback re-reads an unresolved
   quoted identifier as a string *literal*, so `SELECT "rowid" FROM w LIMIT 0`
   against a `WITHOUT ROWID` table **succeeds** and answers the four characters
   `rowid` — which would classify every such table as rowid-addressable, carry
   the literal `'rowid'` as every row's identity, and make every edit report that
   the row changed underneath the reader. Bare, all three fail honestly. The
   exception is safe because the set is **closed and chosen here**: three
   literals spliced from a `CaseIterable` enum's raw values, never from anything
   a reader typed, and `DatabaseQueryTests` asserts the bare spelling
   byte-for-byte so a later tidy-up through `quoted(_:)` fails the suite instead
   of the user's edit. The shadowing rule likewise only works bare: a table may
   declare a column named `rowid`, `_rowid_` or `oid`, and SQLite then resolves
   *that* bare name to the declared column while the other two go on answering
   the true rowid. So the alias is not a constant — it is the first of the three
   spellings no declared column shadows (case-insensitively), asked **before**
   the probe, since probing a shadowed spelling asks about the declared column
   instead. A table shadowing all three falls back to its primary key, and a
   table with neither is not editable, by typed refusal.

4. **A grid column is matched to a schema column by the answered name, not by
   position — and an ambiguous or absent name is a refusal.** The schema is read
   through `PRAGMA table_xinfo`, which lists hidden columns that `SELECT *` omits
   (a virtual table's, and both flavours of generated column), so schema ordinals
   and result ordinals diverge and a positional map would silently write the
   wrong column. Both the planner and the surface's "may this cell be edited?"
   answer look the grid column's answered name up in the schema,
   case-insensitively; **no unique match is a typed refusal**, not a guess. The
   same lookup locates a `WITHOUT ROWID` table's key columns in the answered row,
   and it is stated once (`DatabaseRowIdentity.answeredIndex(of:in:)`) so the two
   engines cannot disagree about what "the same column" means.

5. **The affected-row rule travels to the app half as data, because rollback has
   to happen inside the connection's life.** Core cannot decide "commit or roll
   back" after the fact: by the time an outcome reached it the connection would
   be gone, and re-opening one to undo a write is a second write with its own
   failure modes. So the seam gained one defaulted member, `performWrite(_:)`,
   taking a Core-composed `DatabaseWriteTransaction` (`url`, the statements in
   order, `requiredAffectedRows`) whose begin / commit / rollback texts are
   `DatabaseQuery` constants like everything else. The app half opens a
   read-write connection at `url` with the same busy timeout, runs the
   transaction, compares the accumulated affected rows against the required
   count, commits on a match and rolls back otherwise, closes, and answers a
   `DatabaseWriteOutcome` (`affectedRows`, `isCommitted`). It compares two
   numbers; it decides nothing. What the outcome *means* is read back in Core.

6. **The write connection carries the URL explicitly**, rather than inheriting
   the one the read connection opened with: a viewer tab outlives the path it was
   opened at — the project tree's rename retargets the tab and
   `DatabaseViewerTabs.retarget(id:url:)` hands the model the new path, while a
   git operation that *replaced* the file goes through the heavier `reload(at:)`
   — so the model's
   `fileURL` is the one thing that is current at the moment the write is
   composed. It is also what lets the write be a *separate, short-lived*
   read-write connection while the tab's own stays read-only.

7. **`IS`, not `=`, in the `WHERE`.** The row is addressed by identity **and** by
   the cell's previous value, and both may be NULL; `= NULL` is NULL — never true
   — so an `=` here would make every NULL cell silently unwritable and every NULL
   identity match nothing. `IS` is SQLite's null-safe comparison, and it is what
   keeps NULL and the empty string distinct through a write.

8. **The typing rule.** What is typed is text; what is bound is a
   `DatabaseValue` chosen by the column's declared **type affinity** (SQLite's
   own five ordered rules, re-implemented and tested against the documentation's
   own examples — including `FLOATING POINT`, which contains `INT` inside `POINT`
   and therefore has INTEGER affinity). INTEGER/REAL/NUMERIC bind an integer when
   the whole string is one, a finite real when the whole string is one, and text
   otherwise; TEXT binds text always. For **BLOB — "no affinity", an untyped
   column, common in ad-hoc databases — the cell's previous storage class wins
   when the entry parses as it**: typing `43` over the integer `42` stores an
   integer, typing `43` over the text `42` stores text, and anything that does
   not parse as the previous class stores text. Chosen over "always text" so that
   editing one cell of an untyped column does not silently retype it out from
   under every query that compares it; pinned by tests both ways. **Nothing is
   trimmed** — a text column may perfectly well hold `" 42 "`. An empty entry is
   the empty string, never NULL; NULL is reachable **only** through an explicit
   "Set to NULL" gesture, modelled as its own case so no caller can reach it by
   string, and never by typing the word.

9. **The viewer consults the disk-writer gate and never raises it.** The model
   takes an injected `isWriteBlocked` predicate and refuses a write while a
   worktree-mutating operation is in flight, with a sentence; the read side is
   untouched, because the viewer goes on answering questions about a database
   while git rewrites the worktree. The predicate is wired in the scene to
   `LocalChangesModel.isReverting` — the same flag ⌘S and the project-tree file
   operations refuse on — so **no file under the viewer names a gate call or
   `localChanges` at all**, and the gating suite pins that. After a committed
   write the model calls an injected `didWrite` hook, wired to the same
   generation-pinned `refreshLocalChanges()` a save uses: a database is a tracked
   file, so an edit that landed must show up in Local Changes.

10. **Part 1's open question is answered.** Termination's best-effort
    `closeAll()` stays correct: a write is a short-lived connection that commits
    or rolls back and closes before `performWrite(_:)` returns, so a viewer tab
    never holds unflushed state and there is nothing for a missed run-loop turn
    to lose.

## Files

### `PisakaCore`

- `DatabaseFileRule.swift` — the one rule that decides whether a name names a
  database. A single pure static answer, `isDatabaseFile(named:)`, over
  `recognizedExtensions` (`sqlite`, `sqlite3`, `db`), matched
  **case-insensitively on the last path extension only**. `a.db.txt` is a text
  file whose middle component happens to read `db`; opening it in the viewer
  would hide a file the user can perfectly well edit. The set is a
  `public static let` because three readers ask it — `open(url:)`'s routing,
  `FileIcon`'s extension table and this document — and a set restated three
  times is a set that drifts. `.db` is not SQLite's alone; a file that is not a
  database fails at connection time with the library's own message, which is a
  better answer than refusing to look.

- `OpenFile.swift` — gains `Kind` (`.text` / `.viewer`) as an **immutable**
  property: a tab never changes what it shows. The ordinary initializer
  deliberately has no `kind:` parameter — the only way to build a viewer tab is
  `init(id:viewerFor:)`, which requires a `url` (there is no unsaved database)
  and forces both text sides empty — so "a viewer tab carries no text" holds by
  construction rather than by convention. `isDirty` returns `false` for a
  `.viewer` tab **unconditionally**, so even a caller that assigns `text`
  afterwards cannot make one dirty. That single guard is what silently excludes
  viewer tabs from autosave, from the on-save transform and from Local History
  capture, all three of which are gated on dirtiness — the gating suite pins
  that reasoning rather than adding a second filter at each site.

- `FileService.swift` — one new case, `FileServiceError.missingFile(name:)`,
  with its `errorDescription` arm naming the file in plain words. Thrown by the
  probe-only open path alone (decision 2).

- `FileIcon.swift` — the database extensions are **not** written out in the
  extension table: it is now built by folding
  `DatabaseFileRule.recognizedExtensions` into the hand-written half, so the
  icon can never name a set the viewer does not recognize, or miss one it does.

- `WorkspaceModel.swift` — the routing and the viewer-tab semantics. `open(url:)`
  runs the canonical-path dedup **first and kind-blind**, so a second open of a
  database already showing selects its tab exactly as it does for a text file
  (including through a symlinked or unstandardized path); then, *only when
  `viewerTabsEnabled` is on*, a recognized name is probed with
  `fileStamp(at:)` and appended as a `.viewer` `OpenFile`. Every other file, and
  every file at all with the switch off, takes the read path unchanged. Every
  text-shaped method then skips a viewer tab, each with its reason stated on the
  method:
  - `save(for:)` returns `.saved` **without writing** — saving a viewer tab is a
    no-op, not an error; a Save All or a scripted save deserves "there was
    nothing to do" rather than a failure report about a file it never edited.
  - `saveAllDirty()` skips it with an explicit kind test that is *redundant*
    (`isDirty` is already false) and stated anyway, because this method writes
    files and the reason a database is never among them should not have to be
    traced through another type's invariant.
  - `saveAs(url:for:)` refuses outright: "save the database elsewhere" is a
    copy, not a save, and the viewer holds no bytes it could write there.
  - `markSaved`, `updateText`, `replaceText`, `reloadFromDisk` and
    `reconcileSavedBaseline` are no-ops, returning `false` where they return a
    `Bool`. Refreshing what the viewer *shows* is the viewer model's job,
    through the database connection.
  - `close(id:force:)` always answers `.closed` for one: `isDirty` is false by
    construction, so a viewer tab cannot reach the confirmation branch.

- `DatabaseValue.swift` — one cell as one of SQLite's five storage classes
  (`integer`/`real`/`text`/`blob`/`null`), closed on purpose: SQLite has exactly
  these five, and a value the app half could not classify is a bug reported as a
  `DatabaseError`, not smuggled through as a sixth case nobody can render.
  **Rendering lives here**, not in the grid, so the grid, the cell editor's seed
  text and (in part 2b) the console's result table cannot disagree about the one distinction the viewer
  must never blur: `nullDisplayText` is `"NULL"`, non-empty by construction, so
  an empty `text("")` cell renders as the empty string and is never mistaken for
  a missing value — while `isNull` is the honest question, because no `String`
  marker is unforgeable against a text value that spells it out. A blob renders
  as `blobDisplayText(byteCount:)`, a placeholder rather than the bytes: a blob
  column holds images and archives, and its size is the one fact a reader can
  act on. The case therefore **carries the length and nothing else** —
  `blob(byteCount:)`, not `blob(Data)`. That is not a rendering convenience: a
  blob cell may hold a gigabyte and a page holds `DatabasePage.defaultSize` rows,
  so a value that carried the bytes would make one page of a table of images an
  unbounded read in the one layer whose whole discipline is that every read is
  one bounded page — while the bytes it copied would be read by nobody. The app
  half asks SQLite for the length and copies no bytes at all
  (`DatabaseConnectionService`), so a page of blobs costs a page of integers;
  a cell editor that needed a blob's contents would have to ask for *that one
  cell* — which part 2a instead declines to do at all, refusing a blob cell by
  name (`DatabaseEditRefusal.blobCell`).
  The same shape decides what a bound blob can mean: a `DatabaseValue` blob has
  no bytes to bind, so there is no faithful binding of one — a zero-blob of that
  length and a SQL `NULL` are each a *different value* from the one the reader
  saw — and the bind path **refuses** it with a `DatabaseError.sqlError` instead
  of picking one. That refusal is the one place a `DatabaseError` carries words
  of this app's rather than SQLite's (stated on the type), and it is the second
  half of part 2a's blob rule: a write that reached that line would report
  `SQLITE_OK` at every layer with the bytes gone, so the planner refuses a blob
  cell before a statement exists and the binder refuses one that arrived
  anyway. The same file carries `DatabaseStatement` (SQL text plus positionally
  bound parameters) and `DatabaseResultSet` (column names, rows, `affectedRows`,
  and a bounds-checked `value(row:column:)` so a malformed answer is reported
  rather than trapped on). `affectedRows` is carried from the start although
  every read leaves it zero — it is what part 2a's `UPDATE … WHERE` is checked
  by to confirm it touched exactly the row it named, and adding it later would
  have meant revisiting the seam. "Zero for every read" is a rule the *implementations* must
  make true, not one they inherit: SQLite's own counter is per-connection and a
  `SELECT` does not reset it, so an implementation that simply asks it after a
  read would answer with whatever the previous write did — which is exactly the
  number the write path would then trust. `DatabaseConnectionService` asks
  `sqlite3_stmt_readonly` first and reports zero for a read.

- `DatabaseServicing.swift` — the whole app/Core boundary: `open(url:)`,
  `run(_:) -> DatabaseResultSet`, `close()` and — part 2a's one addition —
  `performWrite(_:) -> DatabaseWriteOutcome`, all `async`, with `close()` and
  `performWrite(_:)` defaulted the way `GitServicing`'s optional members are so a
  fixed-answer stub compiles. A connection is **one file**: `open(url:)` is called once per
  instance and `close()` must be safe to call twice, because the tab owner closes
  on tab close and again at termination rather than tracking which already
  happened. Beside it `DatabaseError` — `cannotOpen`, `notADatabase`, `busy`,
  `sqlError` (each carrying SQLite's message **verbatim**) and `closed` (ours,
  so it has no library text to quote), with a `LocalizedError` conformance so the
  published message is a real sentence instead of "operation couldn't be
  completed (… error N)". Nothing in this layer swallows, paraphrases or
  summarises a failure: "file is not a database", "database is locked" and
  "no such column: foo" each say what to do about it better than any sentence
  written here would.
  The **write half** lives here as three things. `DatabaseWriteTransaction` is
  one write, whole — the url to open, the statements in order, and the
  `requiredAffectedRows` that permits a commit — and it carries the rule as
  *data* because rollback has to happen inside the connection's life (decision
  5), and the url explicitly because a viewer tab outlives the path it was opened
  at (decision 6). The transaction's statements deliberately **exclude** the
  bracket: `DatabaseQuery.beginImmediate`, `.commit` and `.rollback` are the
  implementation's own, not the plan's content. `DatabaseWriteOutcome` is two
  numbers and no sentence — `affectedRows` and `isCommitted` — because a rollback
  at zero ("somebody changed this row") and a rollback above one ("that identity
  did not identify") deserve different things said to the reader, and which
  sentence each gets is Core's call rather than the connection's. And
  `performWrite(_:)` is **defaulted to an honest refusal** ("This database
  connection is read-only.") rather than to a silent no-op: answering
  `DatabaseWriteOutcome(affectedRows: 0, isCommitted: false)` would be
  indistinguishable from the collision case, so a conformer with no write half
  would have the model telling the reader their edit collided with somebody
  else's, about a connection that was never going to write anything. The member's
  contract is spelled on the protocol — open read-write and **never** creating,
  bracket in `BEGIN IMMEDIATE`, accumulate each statement's `affectedRows`,
  commit only on an exact match, roll back on every other path including a throw,
  and close on all of them — and part 2b's console is written against this same
  member.

- `DatabaseQuery.swift` — **the only thing in the repository that writes SQL**,
  asserted byte-for-byte in its tests. It exists because of one fact:
  *identifiers cannot be parameters*. A table or column name is part of the
  statement's grammar, so it must be spliced into the text — which is the shape
  an injection takes — hence `quoted(_:)`, one function used by every splice,
  wrapping in double quotes and doubling the embedded ones so a name containing
  a quote, a semicolon or a space closes nothing and starts nothing. Nothing is
  rejected: every string is a legal identifier once quoted, and refusing to show
  a table because of its name would refuse a database SQLite is happy with. The
  corollary is enforced too — everything that *can* be a parameter **must** be
  one, which is why `LIMIT` and `OFFSET` travel as bound values, and why every
  value a cell edit carries — the new value, the identity values, the previous
  value — is a parameter, so a cell spelling `'; DROP TABLE t; --` travels as
  data. There is **one stated exception to `quoted(_:)`**, and it is what makes
  the write path correct rather than merely tidy: the three rowid alias
  spellings (`rowIdAliases`, off the `DatabaseRowIdAlias` enum's raw values) are
  spliced **bare**, because SQLite's double-quoted-string fallback re-reads an
  unresolved quoted identifier as a string *literal* — `SELECT "rowid" FROM w
  LIMIT 0` against a `WITHOUT ROWID` table succeeds and answers the four
  characters `rowid`, which would classify every such table as
  rowid-addressable, carry the literal `'rowid'` as every row's identity, and
  make every edit report that the row changed underneath the reader (decision 3).
  Bare, all three fail honestly, and the exception is safe because the set is
  closed, chosen by this file and never reachable from anything a reader typed;
  the tests assert the bare spelling byte-for-byte so a later tidy-up fails the
  suite instead of the user's edit. The read statements: `tableListing` (`sqlite_master`, not the modern `sqlite_schema`
  alias, so the text runs against every SQLite this app may meet; internal tables
  excluded by their *reserved* `sqlite_` prefix, so no table of the user's can be
  hidden by that filter; ordered by name alone, because grouping tables and views
  apart is the sidebar's presentation decision); `columnSchema(table:)` using
  `PRAGMA table_xinfo` rather than `table_info` — it answers the same rows plus
  `hidden`, the only way to learn a column is generated, which is the fact the
  write path needs in order to refuse to write it; `rowCount(table:)`, asked separately
  because a `LIMIT`ed page knows nothing about what lies past its end;
  `resultColumns(table:)`, the same `SELECT *` with the limit bound to **zero**
  — the shape of the answer, asked without reading it, which is what a sort
  carried across a refresh is checked against before a page is composed (the
  model's entry says why the page's own answer is one statement too late), and
  free because SQLite learns the column names off the prepared statement and
  steps straight to done; and
  `page(table:orderByColumnIndex:ascending:limit:offset:)`, whose `limit` and
  `offset` are bound and **floored at zero** — not defensive tidiness, but
  because SQLite reads a *negative* `LIMIT` as "no limit at all", so a negative
  slipping through would turn the one statement that must always be bounded into
  a full-table select. Its sort names its column by **1-based result ordinal**
  (`ORDER BY 3`), never by name: `SELECT *` over a view may answer two columns
  spelling the same name, and `ORDER BY "id"` against such an answer silently
  resolves to the first of them whichever header was clicked. The ordinal is
  exactly the position the grid drew, so the two cannot disagree — and since an
  ordinal is a number rather than an identifier, the sort splices nothing and
  `quoted(_:)` has one caller fewer.
  Part 2a added two more reads and the write. `rowIdProbe(table:alias:)` is
  `SELECT <alias> FROM "t" LIMIT ?` bound to zero — one prepare, no rows, the
  question "can a row here be addressed by rowid?" asked as a statement SQLite
  answers (decision 2) — and `page(…)` grew an optional `identityAlias` that
  appends that alias as a **trailing** result column, and only ever trailing, so
  the `ORDER BY` ordinal, the grid's column positions and the shape probe all go
  on meaning what they meant (decision 1). `update(table:column:identity:newValue:previousValue:)`
  composes the one statement in this app that changes a database:
  `UPDATE "t" SET "c" = ? WHERE <identity IS ?…> AND "c" IS ?`. Its `WHERE`
  names the row **twice over** — the identity (a rowid, or every column of a
  `WITHOUT ROWID` key in key order) says *which* row, and the trailing term says
  the cell still holds what the grid was showing — so a row somebody else changed
  in between matches nothing, the affected-row count comes back zero, and the
  transaction rolls back; that is how "this changed underneath you" is *detected*
  rather than guessed at. `IS` throughout, never `=`, because both halves may be
  NULL (decision 7). The binding order is fixed and asserted: the `SET` value
  first, then the identity values in address order, then the previous value —
  the app half binds positionally and knows none of it. Finally the transaction
  texts, `beginImmediate` / `commit` / `rollback`, are constants here rather than
  in the app half, because a `BEGIN` is no less SQL than a `SELECT` and this file
  is the only thing in the repository that writes SQL. `IMMEDIATE` rather than a
  deferred `BEGIN`: a deferred transaction takes its write lock at the first
  statement that needs one, so a second writer arriving in between turns into a
  `SQLITE_BUSY` *mid*-transaction, where asking up front spends the busy timeout
  before anything has been written — the failure a reader can be told about
  plainly. One statement runs *ahead* of the bracket: `foreignKeysOn`
  (`PRAGMA foreign_keys = ON`), before the `BEGIN` because the pragma is a
  documented no-op inside a transaction. SQLite enforces `NOT NULL`, `CHECK`,
  `UNIQUE` and `PRIMARY KEY` whatever a connection asks for, and foreign keys
  only when told to — per connection, defaulting to **off**. Unasked, a cell edit
  that leaves a child row pointing at a parent which does not exist commits,
  reports one row changed and tells the reader it succeeded: the single shape of
  write this layer could let through while every other violation came back in
  SQLite's own words. The affected-row rule means a committed edit is one the
  database agreed to, and a foreign key the database was never asked to check is
  an agreement nobody made. It does not disturb the count either — `sqlite3_
  changes` does not count rows changed by foreign-key actions, so a cascading
  update still reports the one row the statement itself touched.

- `DatabaseSchema.swift` — the schema value types and the two **pure** parsers.
  `DatabaseTableEntry` is a name, a closed `Kind` (`table`/`view` — the listing
  asks for exactly two, and an index or a trigger is not something a grid can
  show; the raw value *is* `sqlite_master`'s own text) and the `definition`
  carried **untouched**, the exact `CREATE` text SQLite stored, because
  re-composing it from the parsed columns would be this layer inventing a fact it
  can only approximate.
  `DatabaseColumn` carries the name, the declared type (verbatim and possibly
  empty — SQLite's type affinity allows a column with no declared type, which is
  a fact about the schema and not a parse failure), the **primary-key position as
  an ordinal** rather than a flag (a composite key's order is what a
  `WITHOUT ROWID` table's `UPDATE … WHERE` addresses a row by — see
  `DatabaseRowIdentity` — and a `Bool` would have thrown it away and forced a
  second pragma), not-null, the default as a SQL *expression* string
  (`CURRENT_TIMESTAMP` is not a value), and one `isHidden` flag folded from the
  pragma's four-way code, because the only thing the viewer does with it is the
  same in every case. `entries(from:)` and `columns(from:)` take the result set
  the seam already answered and never ask for another; they **refuse rather than
  guess**, with `DatabaseSchemaError` naming precisely what was looked for and
  where (`missingColumn(name:found:)`, `unexpectedValue(column:row:)`,
  `unknownEntryKind(_:row:)`) — a result set arrives from a library, so its shape
  is an assumption however carefully Core composed the query, and inventing an
  empty name or a `false` would put a lie on screen that no later layer can
  detect. A result set that declares *nothing at all* (no columns, no rows) is
  the one shape accepted as an empty answer: a pragma naming a table SQLite does
  not know answers that way, and the caller selected that table out of a listing,
  so a table that vanished between the two is a race and not a malformed answer.
  The column names each parser reads are `public static let`s here so
  `DatabaseQueryTests` can pin them against the statements that produce them and
  a rename cannot drift past both.

- `DatabasePage.swift` — the viewer's whole paging arithmetic, kept out of the
  model so the awkward cases are asserted directly rather than through three
  `await`s, and every one of them is a case a real database produces: a table
  with no rows, a last page shorter than the page size, and — the one that
  actually bites — a total that **shrank** while the reader sat on a page past
  the new end, which is what a second process deleting rows looks like from here
  (`setTotalRows(_:)` re-clamps and reports that the index moved, which is the
  caller's cue that the page it is about to request is not the one it asked for).
  **"Not yet counted" is a state, not a zero**: the count is a statement of its
  own, so between selecting a table and its answer arriving the total is
  genuinely unknown — `totalRows` is `nil`, `pageCount` is `nil` with it, and
  `hasNext` is `false`, the type's one deliberate under-promise, because
  refusing to promise a next page for a moment is honest and claiming one that
  may not exist is not. Uncounted, `clamping(_:)` therefore has no last page to
  clamp against — but it still has a **ceiling**, the last index whose `offset`
  is an `Int`, so no index this type accepts can trap the multiplication the page
  query binds as its `OFFSET`; that is the same class of overflow `pageCount` is
  written the long way round to avoid, taken on the other side of the count. A table with **no rows still has one page**, the empty
  one the reader is looking at; reporting zero would put them on page 1 of 0.
  `displayedRows(loaded:)` is driven by what actually arrived rather than by the
  page size, so a short last page does not claim rows the grid is not drawing.
  `defaultSize` is 200, referenced by both the arithmetic and the statement that
  binds it rather than restated at either site. Alongside it
  `DatabaseSortState`: a column — as a **position** (`columnIndex`) with the name
  at that position carried alongside — plus `ascending`/`descending`, with three
  rules. The position is the identity, not the name: a view may answer two columns
  both called `id` (which is already why the grid draws headers and cells by
  position), and a sort keyed by the name would order by whichever of them SQLite
  resolved the name to — the first — while the arrow appeared on *every* header
  spelling it, so clicking the second `id` would silently order by the first and
  say it had done what was asked. `toggled(_:column:index:)` (a **new** column
  sorts ascending, because that is the order the reader means; the **same**
  column — the same *position* — flips, with no third click that
  clears, because cycling back into SQLite's arbitrary storage order through a
  header nobody aimed at would look like the sort had failed);
  `carriedOver(_:from:to:)` (nothing survives a genuine table change — a column
  is meaningful only inside its own table, and carrying a sort into a table that
  does not have it would order the next page by a column nobody asked about —
  while re-selecting the table already showing
  keeps the sort, because that is a refresh and not a move); and
  `survives(columnNames:)`, which the model asks of every answer. Both halves
  must hold — the position must exist *and* the name at it must be the one the
  sort was made against — because the column can change under a *refresh*: it can
  be dropped (the ordinal falls out of range) or merely **reordered**, which is
  the case a position alone gets wrong, since the ordinal would still be in range
  and the next page would come back ordered by whatever now sits there under an
  arrow still naming the column the reader chose. See `publish` below. The two
  types live in one
  file because a sort change resets the page and a table change clears the sort:
  the rules are read together or not at all.

- `DatabaseCellEntry.swift` — the typing rule: what the reader typed becomes
  what the database stores (decision 8). `DatabaseTypeAffinity` is SQLite's own
  five, determined from the declared type by SQLite's own five **ordered** rules,
  case-insensitively over a possibly empty declaration — a re-implementation of a
  documented rule rather than an invention, tested against the documentation's
  own example table. The order is load-bearing rather than incidental:
  `FLOATING POINT` contains `INT` inside `POINT` and therefore has INTEGER
  affinity, which restating the rules as independent tests would quietly get
  wrong. A declaration of nothing but whitespace is read as *no* declaration,
  since SQLite cannot produce one and falling through five substring tests to
  NUMERIC would be a worse answer to a question only a malformed schema asks.
  `DatabaseCellEntry` itself has two cases, and the second is the whole point of
  the type: **NULL is a gesture, never a word**. A cell holding the text `NULL`
  and a cell holding SQL `NULL` render identically (the marker is ink, not
  identity), so a rule that read the typed string would make the two impossible
  to tell apart *and* impossible to type — nobody could ever store the four
  characters. Modelling the gesture as its own case means no caller can reach
  `.null` by string, and the compiler says so. `.typed` carries the text
  **verbatim**: nothing is trimmed anywhere in the file, so `" 42 "` in an
  INTEGER column *binds* text — and SQLite then applies the column's affinity on
  store and keeps the integer 42, exactly as it would for the same string in an
  `UPDATE` anybody else wrote. This file decides what is bound; the column
  decides what is stored. `value(affinity:previousValue:)` is the whole rule — TEXT
  stores text always; INTEGER/REAL/NUMERIC take an integer when the whole string
  is one (an overflowing one falls to a real, as SQLite's own literal does), a
  finite real when the whole string is one, and text otherwise; BLOB, which is
  "no affinity", is the interesting one and consults the cell's previous storage
  class. The numeric parse is deliberately stricter than `Double.init(_:)`, which
  accepts `inf`, `nan` and hexadecimal floats and maps `1e400` to an infinity: the
  spelling is checked against SQLite's own literal shape first and the result
  required to be finite, and the digit scan is ASCII-only so the two halves of
  the answer cannot disagree about what a numeral is.

- `DatabaseRowIdentity.swift` — how the rows of one table are addressed, decided
  once per selection. Three cases: `rowid(alias:)` (almost every table),
  `primaryKey(columns:)` (a `WITHOUT ROWID` table, every key column in **key
  order**, taken off `DatabaseColumn.primaryKeyPosition` — which is why part 1
  carried it as an ordinal rather than a flag), and `unavailable(_:)` carrying a
  `DatabaseRowIdentityGap` that names the missing fact rather than a sentence
  (the sentences are `DatabaseEditRefusal`'s, so this stays a decision and not a
  phrasebook). Two rules make it less obvious than it looks. *Shadowing*: the
  three alias spellings are the same column until the table declares one of its
  own by that name, at which point that spelling resolves to the **declared**
  column while the other two still answer the true rowid — so `probeAlias(columns:)`
  picks the first unshadowed spelling **before** the probe runs, because probing
  a shadowed spelling asks about the declared column instead, and a table
  shadowing all three has no spelling left to ask with and falls back to its key.
  *Schema ordinals are not result ordinals*: `answeredIndex(of:in:)` locates a
  column by name, case-insensitively, and answers `found`/`missing`/`ambiguous`
  — three outcomes rather than an optional, because "two columns spell this name"
  and "none does" are refused with different sentences. `DatabaseKeyColumn`
  carries a name **and** a position for the same reason: the name is what the
  `WHERE` quotes and the index is where that column's value sits in the row on
  screen, and neither can be derived from the other.

- `DatabaseUpdatePlan.swift` — the pure planner and its refusals; nothing in the
  file talks to a database, so every refusal and every byte of the statement is
  testable without SQLite. `DatabaseEditRefusal` is the closed set of reasons,
  each carrying **the sentence the banner shows**, because the two halves of a
  refusal have to travel together: the surface greys a cell out from the reason
  and explains it from the same value, so what the grid refuses and what the
  reader is told cannot drift apart. The reasons are an unaddressable row
  (carrying the identity engine's own gap rather than re-spelling its four
  outcomes), a row that arrived without its identity value, a grid column with no
  unique schema match (decision 4), a generated or hidden column, a blob cell —
  a page carries a blob's *length* and never its bytes, so there is nothing to
  put in the `WHERE` and a text field is not how a blob is replaced — and a cell
  that is no longer on the page at all. `DatabaseEditTarget` gathers what an edit
  is planned against (the table, the schema in `table_xinfo` order, the grid's
  answered column names, the identity strategy) and holds both column lists
  because they are **not the same list**. `DatabaseRowAddress` is how *this* row
  is named, with the values this page answered — split from `DatabaseRowIdentity`
  because the strategy is resolved once per selection while the values change
  with every page. `DatabaseUpdatePlanner` has two entry points on purpose:
  `refusal(…)` is what greys a cell out before anyone types, and `plan(…)` asks
  it again before composing, so the two can never disagree about what is
  editable. The refusals are ordered widest-first, so a reader looking at a view
  is told it is a view rather than told about whichever column their pointer
  happened to be over. The plan carries the statement and
  `requiredAffectedRows` (always 1, carried anyway rather than assumed
  downstream — it is the whole safety property), and deliberately **nothing
  else**: the value being written is already `statement.parameters[0]`, the
  model settles a committed write by re-reading the page rather than by
  believing what it sent, and a second spelling of it would in any case name the
  *bound* value and not what the cell ends up holding — SQLite applies the
  column's affinity on store, so `" 42 "` bound as text into an INTEGER column
  reads back as 42.

- `DatabaseViewerModel.swift` — one open database tab's state, in
  `LocalChangesModel`'s shape: a `@MainActor ObservableObject` whose I/O is
  injected behind `DatabaseServicing`, whose published state is only ever touched
  on the main actor, and whose overlapping loads are ordered by monotonic
  generation tokens. Foundation only — every statement it sends is composed by
  `DatabaseQuery` and every answer read by `DatabaseSchema`, so nothing here
  knows SQLite exists. `load()` opens the connection once (a second call is a
  refresh; a failed open leaves `isOpen` false so the next call retries rather
  than running statements against nothing) and lists the tables and views.
  `select(table:)` loads the schema, the count and the first page — with one
  statement in between when, and only when, a sort was carried into it: the
  shape probe that keeps a stale ordinal from reaching SQLite (below).
  `goToPage(_:)` moves and reloads — a move to the page already shown is a no-op
  rather than a re-query, because the paging controls are clickable at both ends.
  It is not a no-op for the state the *click* already changed, though: the token
  is bumped before the call, so a request that early-returns has already
  superseded whatever was in flight, and a superseded load clears nothing —
  including `isLoadingRows`. `settleConsumedRequest(_:)` therefore puts the
  position back onto the rows on screen and lowers the flag for any request that
  presented a token and then did nothing, which is reachable from two clicks on ◀
  faster than the button redraws. `toggleSort`'s own "nothing is selected"
  early return settles the same way, for the same reason, whether or not a
  click can reach it today. A caller that presented no token superseded
  nothing and keeps the plain no-op.
  `toggleSort(column:index:)` flips or re-aims the sort, resets to the first page and
  **keeps the count**: an `ORDER BY` reorders rows without changing how many
  there are, so re-asking `count(*)` would be a second full-table read for an
  answer already in hand. `reload(at:)` is the tab's `reloadFromDisk`: it releases
  the connection, opens the file again — at the url the caller passes, since a
  rename retargets a viewer tab while its open handle keeps answering off the
  renamed inode, so this is the one moment the tab's own path is used again — and
  re-reads the listing, then re-selects
  the table it was showing when the new database still holds it (a re-selection
  is a *refresh*, so the sort and the page index survive) and drops it, rows and
  all, when it does not. It also **clears the row identity** on the way in: the
  rows stay on screen — a reconnect blanks no good page — but `fileURL` has
  already been retargeted at the file that replaced them, so for the length of the
  reconnect the page names rows of a database that is gone while an edit would be
  sent to the one that took its place, carrying the old rowid and the old previous
  value into it, where the `IS` guard cannot tell the two apart if the row it
  lands on happens to match. Clearing turns every cell into the refusal an
  unaddressable table already gets (`.unaddressableRow(.noRowIdentity)`), which
  the re-selection then lifts; the window matters because a re-open that *fails*
  leaves it open for the life of the tab. A re-open that fails leaves the tab as
  it was under the banner explaining why, rather than re-selecting into a closed connection and
  replacing the open's message with a second one about a statement. **That
  re-selection is recorded, not read off the reconnect's own `load()`**
  (`pendingReselection`): the reader selecting this tab starts a second `load()`
  — the view's `.task` — which can land while the reconnect's own load is
  suspended in `open` and supersede it, and a superseded load records no `isOpen`
  and publishes nothing, so a re-selection gated on that flag is skipped on the
  one interleaving that most needs it — the sidebar refreshing to the new
  database while the schema, the rows and the sort go on describing the
  pre-operation one, with no banner and no spinner saying so. The intent is
  therefore consumed by whichever listing load actually lands, is left standing by
  one that failed (the next refresh recovers it), and is dropped rather than
  applied when the reader has since selected something else — what is on screen
  is their click, not the reconnect's memory of one. `close()`
  latches. `gridColumns` is published
  separately from `columns` and is deliberately **not** `columns.map(\.name)`: a
  hidden column appears in the pragma and not in `SELECT *`, so reading the
  headers off the schema would shift every cell in such a table one column left.
  Part 2a made it a writer of exactly one shape, and left the read side alone.
  **Row identity is resolved once per selection and travels hidden**:
  `select(table:)` asks the rowid probe once, with the schema and before the
  count, because its answer decides the *shape* of every page the selection then
  composes; the alias is remembered for the selection (a page turn or a sort
  toggle re-asking it would be one prepare per click for an answer that cannot
  have changed) and `publish(_:table:)` splits the trailing column back off **by
  position and count**, never by name (decision 1). `rows` and `gridColumns` are
  therefore exactly what part 1 published, the sort-survival check and the
  carried-sort probe are asked against the **grid**'s columns rather than the raw
  answer (against the raw one a sort at the last grid column would be checked
  against the identity column's name and dropped on every load), and an answer
  that is not one column wider than it should be is published whole and reported
  identity-less — which cannot happen, and is a deliberate choice of degradation:
  a raw answer costs the reader one visible column they did not ask for, where a
  half-split one would shift every cell in the grid. **A probe that fails is an
  answer, not a failure**: it is read as "no rowid here" and publishes no banner,
  because reading the page still works; the two failures that are not really
  about identity (a connection that went away, a table dropped between the
  listing and the selection) fail again, loudly, on the count or the page a
  moment later. `editTarget` / `editRefusal(row:column:)` / `canEdit(row:column:)`
  are the read-only answers the surface greys cells out on, assembled here so the
  question and the statement that acts on it come from **one** value. `editTarget`
  is **stored, not computed**, rebuilt by a `didSet` on each of the four
  properties it is made of: it resolves every grid column to its schema column
  (`DatabaseEditTarget.resolvedColumns`, a case-insensitive scan per column) and
  the surface asks for a refusal on every cell it draws, so re-deriving it per
  cell made this the grid's hottest allocation on a wide table. Rebuilt from the
  `didSet`s rather than from the handful of methods that assign those properties,
  so a later path that clears or sets one cannot forget it and leave the grid
  greying cells out against a previous table's schema — and `resolvedColumns` is
  kept in step by `didSet` inside the struct for the same reason, since both
  lists it is derived from are `var`.
  `reportEditRefusal(row:column:)` is how a gesture on a refused cell gets its
  sentence into the banner **without going near the write path**: routing the
  attempt through `updateCell` instead would mean inventing an entry nobody typed
  purely to be refused again — for a blob cell that entry is the `<n bytes>`
  placeholder, one missing refusal away from being written — and would let the
  gate's own sentence mask the cell's whenever a worktree operation happened to be
  in flight.
  `updateCell(row:column:entry:request:)` is the write, and the order of its
  refusals is the design: the **rows token** first (`request` is the token the
  gesture captured through `rowsToken`, so a page that landed between the
  keystroke and the task body turns the attempt into nothing rather than into a
  write aimed at whatever row now holds that coordinate — carrying *that* row's
  identity and *that* row's previous value, and so committing), then a **page
  still in flight** — which that token cannot see, because it was bumped before
  that load's first hop and so a gesture made after it captured the very number
  the check compares; the rows on screen are the ones that load is about to
  replace, so the write is refused in the same words. The surface asks the same
  question before it opens an editor (`isGridIdle`), but that is the grid keeping
  a field from being opened over rows that are leaving, not the rule: a caller
  that is not the grid inherits nothing from a view, so the refusal lives here.
  Then the
  disk-writer gate (an operation rewriting the worktree may
  be replacing this very file), then the plan (a refusal is shown in its own
  words and **nothing is sent**), then "one write per tab" — a second edit
  arriving while one is in flight is refused rather than queued, because the plan
  behind it was composed against page values the first write may be in the middle
  of replacing. `setCellToNull(row:column:)` is that same method with an entry of
  `.null`, so the gate is asked in exactly one place. The **rows token is
  captured, not bumped**: a write is not a load and publishes no page of its own,
  so it must not supersede the loads around it — what it must do is notice that
  one of them superseded *it*, in which case the newer state stays on screen and
  the write publishes nothing — no message and no re-query. The commit still
  stands, which is the honest outcome and is asserted; the **rollback sentences
  and a thrown failure are silenced by the same guard, deliberately** — all of
  them are about the page the write was planned against, and above the page a
  newer load published they would describe nothing that is on screen, which is
  the same lie a superseded load telling its own story would be. **`didWrite` is told
  either way**, ahead of the supersession guard, because that hook is about the
  file on disk rather than about the page this tab happens to be holding: a
  committed edit changed a tracked file whether or not the grid still shows what
  it changed, and Local Changes would otherwise go on calling the database
  unmodified. `isWriting` is the one
  flag lowered on **every** path including the superseded one, because nothing
  but this write ever raises it and a write that returned to find itself
  superseded is the only thing that can lower it; left up, the tab would refuse
  every later edit for its life. `settle(_:)` reads the outcome: committed →
  re-query **only the page** (an `UPDATE` changes no row's existence, so the
  count cannot have changed), **under a token of its own** — the one
  rows-replacing load with no gesture in front of it to bump one, and the reason
  it must is that what it lands is not what the write was planned against: a sort
  on the edited column reorders the page around the row that just changed, and
  anything else holding the database may have rewritten the rest of it meanwhile.
  Left on the write's own token, a gesture captured *before* the write would
  still pass the staleness check afterwards and be planned against a page nobody
  has looked at, carrying that row's identity and that row's previous value — and
  so committing, which is precisely what `rowsToken` exists to prevent; rolled back at zero → "this row
  changed underneath you, nothing was written"; rolled back at anything else →
  say how many it would have touched; a throw → SQLite's own words. No path
  blanks a good page. Finally the one message slot gained a **third source**: a
  write's sentence is about a cell that is still on screen, so it is not cleared
  by a listing refresh (the tab's `.task` runs one a moment later) or by a page
  turn — and *is* cleared by the next write that succeeds and by every
  `select(table:)`, the move that leaves the cell behind and the refresh alike.
  The refresh half is not a nicety: three of these sentences end in "Reload the
  table and try again", the reachable reload is the re-selection
  `reselectIfPending` makes after a reconnect (the sidebar cannot re-select the
  row it already has), and a sentence that outlived it would accuse the reader
  of a stale row over rows that were just re-read. When that reconnect finds the
  table gone, the write's sentence goes with the rows for the same reason the
  page load's does — a banner over an empty grid and an unselected sidebar
  explains a state that no longer exists.

### `Pisaka` (app layer — macOS only, every file inside `#if os(macOS)`)

- `Platform/DatabaseConnectionService.swift` — the app half of the seam, and
  **the only file in the repository that imports the system SQLite module**
  (pinned by the gating suite). The `GitCLIService` / `LSPProcessTransport`
  position one level down: it hands Core's finished text to
  `sqlite3_prepare_v2`, binds a list of values it never inspects, steps, reads
  each column back **by its storage class** (not by the declared type), and hands
  back columns and rows. An `actor` rather than a lock, because a `sqlite3 *`
  opened without `SQLITE_OPEN_FULLMUTEX` is not safe on two threads and the model
  can have a page load and a listing refresh in flight at once. Opened
  `SQLITE_OPEN_READONLY` and deliberately **without** `SQLITE_OPEN_CREATE`: the
  file was probed into existence by `WorkspaceModel.open(url:)`, and a path that
  reached here anyway must report rather than quietly conjure an empty database.
  The read-only flag is what makes the layer's reader claim true *at the file
  level*, not merely at the SQL level: a read-write handle checkpoints a WAL
  database when its last connection closes and deletes the `-wal`/`-shm`
  sidecars, so opening and closing a viewer tab would rewrite the tracked `.db`
  file and show it as modified in Local Changes — a worktree write with no writer
  gate held and no user action behind it — besides taking write locks that
  contend with whatever else has the database open. **Part 2a's write path did
  not change that flag**: a cell update opens a connection of its own.
  A **busy timeout** (5 s) is set immediately after the open, before any statement
  can run: without it SQLite returns `SQLITE_BUSY` the instant a lock is
  contended, so a viewer opened over a database another process is writing would
  flash an error rather than wait the moment out — and five seconds is short
  enough that a genuinely *held* lock reports instead of hanging the tab. A text
  binding uses SQLite's transient destructor, because the Swift array backing it
  dies at the end of the call; a blob **reads back as its length alone and cannot
  be bound at all** — `sqlite3_column_bytes` without `sqlite3_column_blob` on the
  way out, a refusal on the way in — so no page ever copies a blob's bytes and no
  write can substitute bytes it does not have (see `DatabaseValue`). A `deinit` closes the handle as
  a **backstop**: `close()` is the normal path and the tab owner drives it, but it
  is `async`, so every route to it is a `Task` hop a torn-down owner may never run
  — and the handle nobody closed is a leaked file descriptor for the app's life. Every failure becomes a
  `DatabaseError` carrying `sqlite3_errmsg` verbatim; `close()` finalizes, closes
  and is safe to call twice.
  `performWrite(_:)` is part 2a's one new member, and the fact that it runs on a
  **connection of its own** is the point of it rather than an implementation
  detail: the tab's handle stays `SQLITE_OPEN_READONLY` for its whole life, so a
  tab nobody edited never takes a write lock at all, while a write that is
  *asked for* holds one for exactly as long as it takes to run. A commit is followed by
  `DatabaseQuery.walCheckpoint` (`PRAGMA wal_checkpoint(FULL)`), outside the
  transaction and under `try?` so a checkpoint that cannot run never turns a
  write that succeeded into a failure. Without it a WAL database's edit is
  committed and durable and yet leaves the tracked bytes untouched — SQLite folds
  committed frames back only when the *last* connection to the database closes,
  and the tab's read-only one is still open (and could not checkpoint even if it
  were last) — so `didWrite` would refresh Local Changes into showing nothing,
  `git commit` would not carry the edit, and the one undo the viewer offers would
  have nothing to undo. `FULL` rather than `PASSIVE`, which copies only what no
  reader is holding and would make "did this reach the file?" depend on timing;
  on a database not in WAL mode it is a no-op answering a row of `-1`s. What
  closing the write connection still does **not** do is tidy the sidecars up —
  SQLite unlinks `-wal`/`-shm` only on the close of the last connection — so on a
  WAL database they outlive the edit. `docs/FEATURES.md` says both halves in the
  user's words. It opens `SQLITE_OPEN_READWRITE` and
  again **no** `SQLITE_OPEN_CREATE` (a database moved away since the page was
  read must report, not be conjured empty and then written into), at the
  transaction's own url (decision 6), sets the same busy timeout — which matters
  more here, since `BEGIN IMMEDIATE` asks for the write lock up front and a
  database another process is writing should wait the five seconds out rather
  than refuse the edit the instant a lock is contended — sends
  `DatabaseQuery.foreignKeysOn` before the `BEGIN`, where it is not yet a no-op
  and on this connection because the setting is per-connection, brackets the
  statements,
  accumulates their `affectedRows`, commits only on an exact match and rolls back
  otherwise, rolls back and rethrows on any failure (with `try?`, because a
  rollback that fails has nothing further to say and replacing the statement's
  own message with its would lose the sentence explaining what went wrong), and
  closes on **every** path in a `defer`, the throwing ones included — a leaked
  write handle would hold the write lock for the life of the app. The
  prepare/bind/step mechanics were split into one private `execute(_:on:)` that
  both connections use, or the two would eventually disagree about what binding a
  text value or reading a blob means. The affected-row rule is enforced here
  because this is the only place it *can* be, with the transaction still open;
  this compares two numbers and what either outcome means to the reader is
  `DatabaseViewerModel`'s to say.

- `DatabaseViewerTabs.swift` — who owns a viewer tab's connection, and for
  exactly how long. One `DatabaseViewerModel` per viewer tab keyed by tab id,
  created the first time the tab is shown and released when the tab goes away;
  because the model holds one service and a connection is one file, "one model
  per tab" and "one connection per open database" are the same sentence.
  Re-selecting a tab hands back the model it already had, with its selected
  table, page and sort intact — which is the whole reason this state does not
  live in the view. **Tab close is observed, not called**: the owner subscribes
  to the workspace's `openFiles` and closes the connection of any tab that is no
  longer there, because a tab can leave through the close button, ⌘W, a
  force-close after a checkout, or a folder switch that replaces the whole tab
  set — one subscription covers all four, where four call sites would eventually
  be three. (The `@Published` sink reads its *argument*, never
  `workspace.openFiles`: the publisher fires before the property is written.) The
  models dictionary is deliberately not `@Published` — views observe the model
  they were handed, and republishing here would re-render the window every time a
  tab opened for no visible change. `reload(id:url:)` is what the post-operation
  resyncs call for a viewer tab whose file survived the operation: it re-reads the
  database over a fresh connection, because git replaces a file by renaming a new
  one over it and the tab's handle would otherwise go on answering out of the
  unlinked old one. The `url` is the tab's url *now*, not the one the model was
  built with: `WorkspaceModel.applyRenamePlan` retargets a `.viewer` tab like any
  other, and the open handle goes on answering off the renamed inode, so a
  reconnect against the opened-at path is the one moment that divergence can
  surface — as a permanent "unable to open database file" over a file sitting in
  the tree under its new name. A tab that has never been shown has no model and nothing
  stale, so it is skipped — it opens against the new file when it is first
  selected. `retarget(id:url:)` is the lighter sibling and the rename's *own*
  half: `performMove` calls it for every tab the rename plan retargeted, and it
  only moves the model's `fileURL`. No reconnect, because a rename moves the name
  and not the inode — the page on screen stays and the open handle is still
  answering the same database. Part 1 needed neither, since `fileURL` was read at
  reconnect and nowhere else; part 2a makes it the path a cell edit opens
  **read-write**, so a renamed tab without this would address the name it was
  created under for the life of the tab. `closeAll()` is what termination calls,
  and
  is **best effort by construction and said to be**: it runs from
  `willTerminateNotification`, the last notification AppKit posts, so the `async`
  close may not get a run-loop turn — acceptable for these read-only connections,
  which have nothing unflushed to lose, and still acceptable now that the viewer
  writes, because a write is a separate connection that commits or rolls back and
  closes before `performWrite(_:)` returns (decision 10). What the call really
  buys is the non-terminating path releasing everything at a point where the hop
  certainly runs. **A whole file of its own on purpose** (decision 4), and it
  states the reader boundary: nothing in this feature may name
  `autosave.suspend()` or `localChanges.beginRevert()`.
  It is also where the viewer's two scene answers are forwarded.
  `start(isWriteBlocked:didWrite:)` is called once from the scene and stores both
  closures; every model this owner builds is constructed with closures that hop
  through *this* object rather than capturing today's values, so a tab shown
  before the scene wired them still asks the real question afterwards and the
  ordering of `.onAppear` against the first tab selection decides nothing. Weakly
  captured, because a model outliving the owner belongs to a torn-down window: it
  then answers "nothing is in the way", the same posture a model built in a test
  or a preview takes. The gate arrives as a **question**, never as the gate's own
  API — which is precisely how the viewer both consults the gate and goes on
  naming no gate call, and why no file under the feature mentions `localChanges`
  at all.

- `DatabaseViewerView.swift` — the surface: an error banner above everything (a
  failure that scrolled away with the grid would be a failure nobody read), a
  sidebar of tables and views (distinguished), the selected one's schema under
  it, and the paged grid with clickable sorting headers and paging controls in
  its footer. **The view decides nothing** — which page exists, whether there is
  a next one, what row range is on screen, which way a header click sorts and how
  a cell is written are all Core's answers, drawn the way `LocalChangesView` draws
  `LocalChangesModel`. The one thing it judges is ink: a NULL cell is styled from
  `isNull`, never by comparing its text to the marker, because a text value
  spelling `NULL` renders identically and must not be dressed as a missing one.
  Every `ForEach` over columns — the headers and the schema list, matching the
  data rows, which always did — is keyed by **position, not by name**: a view may
  legally select two columns with the same name (`SELECT t.id, u.id FROM t JOIN
  u`) and SQLite answers both of them as `id`, so identifying a header by its
  string would draw fewer headers than there are cells and shift every heading in
  that view. The position is what a header click *sends* as well as what draws
  it: `toggleSort(column:index:)` takes it and the arrow is drawn from
  `sort.columnIndex`, so a click on one duplicate cannot flip the other or put
  the arrow on both (`DatabaseSortState`). The footer's one judgement is the same honesty rule as the model's:
  "Loading…" is said only while `isLoadingRows`, so the uncounted-and-empty state
  a *failed* selection leaves behind does not claim a load is in flight
  underneath the banner explaining that one failed. The grid's placeholder answers
  the same way: "No tables or views" is a **claim about the database**, so it is
  made only once there is one to make it about — while `isLoadingEntries` is up
  nobody has read the file yet ("Loading…"), and under an error banner the banner
  already said what happened. The page's rows are drawn from a `LazyVStack`: a
  page is 200 rows, a wide table's page is thousands of cells, and an eager stack
  builds every one of them on the main actor before the first is on screen, on
  every select, page turn and sort. Lazy is safe inside the bidirectional
  `ScrollView` because every row is the same width by construction — each cell is
  drawn at the one fixed column width the headers use.
  Everything is sized through `\.interfaceMetrics`; nothing is drawn at the code
  font, so the viewer is chrome for zoom purposes and declares no `ZoomSurface`.
  `DatabaseViewerHost` is the thin adapter `ContentView` routes to: it asks the
  environment's `DatabaseViewerTabs` for the tab's model and keys the surface on
  the tab id, so switching between two viewer tabs rebuilds against the other
  model rather than reusing one's scroll and selection under another database's
  rows. The load is kicked by `.task(id: ObjectIdentifier(model))` — keyed on the
  model rather than on its `fileURL`, which a rename can change under it: a task
  re-fired by a retarget would race the `reload(at:)` doing that same reconnect,
  and one model is one tab is one connection anyway.
  Part 2a made the grid **editable, and decided nothing new in doing it**. A
  double-click — or Return on the focused cell — opens a plain field seeded from
  the cell's rendered text; Return commits through `updateCell`, Escape closes it
  and writes nothing. A NULL cell seeds **empty**, because an empty entry means
  the empty string and NULL is a gesture: seeding the marker would make Return
  store the *text* `NULL`, the one confusion the marker exists to prevent, and
  NULL is instead reachable only through the cell menu's explicit "Set to NULL"
  beside a "Copy" of the rendered text. A **single** click focuses the cell, which is what
  makes the Return shortcut reachable at all: `.focusable` alone leaves Tab
  traversal as the only route, and Tab reaches a non-text control only when the
  system's "Use keyboard navigation to move focus between controls" is on — off by
  default — so without the click the documented Return path would be dead on an
  ordinary Mac. It is declared *after* the double-click and guarded by the same answer the cell
  is drawn from, so focus is never armed over a refusal — but it does **not**
  rely on winning the disambiguation, because that arbitration is SwiftUI's and
  unspecified: it closes only an editor open at a *different* coordinate, so a
  single tap that fires after the double-click's `beginEditing` on the very same
  cell leaves the field it just opened alone. A cell Core refuses is **drawn
  dimmed**, is not
  focusable — so Return cannot reach it either — carries the refusal's own
  sentence as its tooltip, and on a double-click hands the attempt to the model anyway, which is
  what puts that same sentence in the banner and sends nothing by construction.
  The refusal is asked **once**, in the cell, and the dimming, the tooltip, the
  disabled menu item and the banner are four renderings of that one answer. The
  dimming is `.opacity` over the whole cell rather than a second
  `foregroundStyle`, so it *composes* with the NULL rendering instead of
  competing with it — a refused NULL stays italic and tertiary and simply reads
  fainter, where a greyer foreground would have drawn a refused value and an
  editable NULL the same colour — and it is what tells a view or an unaddressable
  table (where **every** cell is refused) apart from an editable one at a glance,
  which hovering each cell in turn is not. Editing is closed
  by `isLoadingRows` rising — the one signal every rows-replacing path (a
  selection, a page turn, a sort, the re-query after a committed write) raises
  before its hop — and is not offered at all while a write or a load is in
  flight, because an editor opened over either would be typing into rows that no
  longer exist by the time Return arrives; the editing state is a *coordinate*
  rather than a value, so this matters. That closing is **housekeeping, not the
  safety property**: `onChange` is a per-render diff, so a load that raises and
  lowers the flag between two renders never fires it. What makes an editor
  outliving its rows harmless is that the rows token is captured when the field
  **opens** (`editingToken`) rather than when Return is pressed — every
  rows-replacing path bumps the generation before its first hop, so a load
  starting under an open editor makes that token stale by construction and
  `updateCell` refuses. Reading the token at the keystroke instead would have
  made the whole guard depend on a render having happened in between. The **single click also closes an editor
  open somewhere else**, which is not tidiness: focus leaving a field is not a
  signal anything here sees, so without it the abandoned field would stay on
  screen unfocused with the editing coordinate still pointing at it — and since
  the Return shortcut is enabled only while *no* editor is open, Return would
  silently stop working on the cell the reader just clicked, until they thought
  to press Escape on a field they had already left. Closing writes nothing, the
  same answer Escape and every rows-replacing load give. Cells are no longer
  `.textSelection(.enabled)`: on selectable text a double-click selects a word,
  and that is the gesture editing needs; Copy puts on the pasteboard exactly the
  string a selection would have carried. Return is carried by a zero-sized,
  accessibility-hidden button with a keyboard shortcut rather than
  `onKeyPress(_:)`, which is macOS 14 while this app runs on 13, and it is
  enabled only while a grid cell actually holds the keyboard so it can take
  Return neither from the field it opens nor from anything else the window shows.
  Everything is still sized through `\.interfaceMetrics` and nothing is drawn at
  the code font, so the pane still declares no `ZoomSurface`.

- `ContentView.swift` — `editorZone` keeps the breadcrumb for **every** tab (a
  database has a path like any other file) and routes below it on the tab kind:
  a viewer tab gets `DatabaseViewerHost`, a text tab gets `textEditorZone(for:)`,
  which is the consent banner, the find bar and `CodeEditorView` lifted into a
  helper so the routing is one short expression rather than a hundred lines of
  editor wiring wrapped in an `if`.

- `PisakaApp.swift` — the wiring edits plus the skips. `WorkspaceModel(
  viewerTabsEnabled: true)` is the one site that turns decision 3 on;
  `DatabaseViewerTabs` is constructed over that **same** workspace instance (it
  follows that workspace's tab set), held as a `@StateObject`, injected into the
  window's environment, and `closeAll()`ed at termination beside the other
  windows'. Then every text-assuming consumer skips viewer tabs:
  - `openBuffers` — the closure feeding the symbol index and Find in Files.
    Contributing an empty buffer for a real path would make both answer for the
    database out of the buffer branch, reporting it as an empty file and
    outranking the on-disk branch that would at least have declined it as binary.
  - the ⌘S funnel `save(id:)` — returns `true` **early**, ahead of the writer-gate
    check (a save that writes nothing cannot race git), ahead of
    `saveTransform.prepareForSave` (no buffer to transform, no caret to protect)
    and ahead of the recreate probe (which would put an empty file back where a
    deleted database was). Nothing to save is not a failure: returning `false`
    would beep at the close prompt and fail the run/test pre-run save.
  - the three buffer-snapshot maps — the rename pass's
    `bufferTextsByCanonicalPath()`, project Replace All's `textsBeforeBatch`, and
    `openTabSnapshot()` before a checkout. Each says "this file's bytes are these
    bytes"; a database's are not, and its tab's text is empty, so an entry would
    offer the rename plan an empty baseline for a real path that `expectedText`
    would then verify against and rewrite. (Replace All's resync loop skips them
    for the same reason **and must**, since a missing entry reads as "changed".)
  - the post-operation resync — all **three** sites, through one shared
    `resyncViewerTab(_:mayRemoveFiles:)`: `resyncOpenTabsAfterCheckout`, the
    revert loop, and `applyMerge`, which resyncs its one resolved file inline
    rather than through the loop and so needs the rule asked separately (a
    database can be tracked, and therefore conflicted and resolved) — a viewer tab whose
    file is gone and whose caller `mayRemoveFiles` **force-closes**, exactly like
    a text tab on a deleted file, and its connection goes with it through the tab
    subscription; a viewer tab whose file is still there keeps its **tab** — no
    reload, no baseline reconcile, no beep — while its **connection is re-opened**
    through `DatabaseViewerTabs.reload(id:url:)`, at the url the rule just
    confirmed exists. That second half is not optional:
    git replaces a file by renaming a new one over it, so the tab's connection is
    left pointing at the unlinked old inode and every later read answers the
    pre-operation database with nothing on screen saying so. It is the viewer's
    half of the `reloadFromDisk` beside it. Without the rule at all the text
    branch reads a viewer tab as "unchanged" (its text is empty on both sides),
    asks `reloadFromDisk`, gets the `false` a viewer tab always answers, and
    force-closes a tab whose file is sitting right there.
  - `syncOpenBuffersForDiagnostics` — the diagnostics push channel's whole-set
    flush (D30), which hands each open buffer's text to `LSPDocumentSyncController`
    on a session restore and on a registry change. Unfiltered it would offer the
    empty string for a real database path; today no `SyntaxLanguage` maps
    `db`/`sqlite`/`sqlite3` so the controller drops it, but that is an accident of
    another file's table and not a rule — the filter is the rule.
  - the **Find menu's four in-editor commands** — Find…, Replace…, Find Next,
    Find Previous — through one `isFindableTabSelected`. The find bar is rendered
    inside `ContentView`'s `textEditorZone` alone, so ⌘F on a viewer tab would set
    `EditorSearchState.isVisible` with nothing on screen to show for it, and the
    *next* text tab selected would then come up with the bar already open and
    holding focus, from a keystroke aimed at a different tab. Greyed out, the menu
    says so where every other unavailable command in it already does. (Find in
    Files is untouched: it is a window over the project, not over the selected
    tab, and a database is excluded from that walk by the binary/size filters as
    it always was.)
  - **File ▸ Local History…** — through `localHistoryTargetURL`, which now answers
    only for a text tab. This is the one Local History path that is *not* settled
    by "never dirty": the command opens a window from the selected tab's url, and
    a Restore from it reads `text(for:)` as the text it is displacing — the empty
    string, for a viewer tab — and captures that as a revision under the
    database's path before an `applyRestore` that is a no-op for the kind restores
    nothing. It is reachable, because a `.db` that is not SQLite was an ordinary
    text tab before this feature existed and can carry real revisions.
  - the **write wiring**, part 2a's one addition and four lines in the scene's
    existing start-once block: `databaseViewers.start(isWriteBlocked:didWrite:)`,
    with the gate question wired to `localChanges.isReverting` and the hook to
    the generation-pinned `refreshLocalChanges()` a save already uses. It reads
    the flag directly rather than calling `revertInFlight()`, because that helper
    beeps and runs a modal alert while a refused cell edit already has a sentence
    of its own in the viewer's banner — two notices for one refusal is one too
    many. Wired here for the same reason autosave's answers are: the owner is
    built in `init` (it follows the workspace's tab set) while the models it
    answers out of are `@StateObject`s that do not exist at that point.
  - autosave, the on-save transform and Local History *capture* need **no** filter:
    all three are gated on `isDirty`, which is `false` for a viewer tab by
    construction. The invariant *is* the reason, so the gating suite pins it
    rather than letting a second filter grow beside it. (The menu command above is
    the exception that proves the shape: it reaches the buffer without asking
    whether it is dirty.)

## The generation-token scheme

`DatabaseViewerModel` carries **two** tokens, because there are two
independently re-triggerable loads. The table listing is re-asked by `load()`;
the schema-and-page load is re-asked by `select(table:)`, `goToPage(_:)` and
`toggleSort(column:index:)`, which a reader can fire far faster than a large table
answers. One shared token would let a finished listing cancel a page load that
has nothing to do with it, so the two are counted apart.

Each token is bumped in its method's **synchronous prefix** — the run of
statements before the first `await`, which the main actor executes without
interruption — and every result is dropped unless the token it captured is still
the latest. A superseded load publishes **nothing**: not its rows, not its
error, not its loading flag, **and not `isOpen`**. That last one is the
subtle case: a superseded load's open is a fact about a connection somebody else
has since replaced. `reload()` bumps the token, sets `isOpen` false and *then*
awaits `close()`, so a load resuming in between that recorded `isOpen = true`
would latch it true over a connection the close is about to release — and since
nothing outside `reload()`/`close()` ever clears the flag again, every statement
for the rest of the tab's life would throw `.closed` under a banner naming a
closed connection. Nothing is lost by discarding it: the newest load always
re-asks `open`, which the seam requires to be harmless a second time (two loads
racing can both find the connection unopened and both ask), and records the flag
itself.

`close()` bumps **both** tokens before releasing the connection, so a load still
in flight resumes to find itself superseded and publishes nothing into a tab that
is gone.

The synchronous prefix is the right place only for a caller that is *already*
inside the model. A **view** is not: it clicks, then hops through an unstructured
`Task`, and the repository's standing rule — stated on
`ProjectSearchModel.search(root:query:mask:request:)` and
`SymbolIndexModel.rebuild(root:request:)` — is that unstructured tasks are not
guaranteed to start in creation order. A token bumped inside `select` is
therefore bumped when the task *runs*, not when the click happened: two quick
sidebar clicks, table A then B, could start B-first and leave A to bump last and
win, settling the tab on the table the user clicked first with nothing superseded
and no error. So `prepareForRowsChange()` is the model's `prepareForSearch(root:)`
— it bumps the rows token synchronously in the click and hands back the token the
resulting load must present — and `select(table:request:)` /
`toggleSort(column:index:request:)` refuse a request that is no longer the latest,
**before** either of them mutates anything (`toggleSort` would otherwise flip the
header arrow for rows it never loaded). `goToPage(_:request:)` takes the same
token, and the footer captures its *target index* in the click too. Two paging
clicks would indeed settle on the same index whichever order they were picked up
in — but the race the token exists for is not paging against paging: a paging
click that lands after a sidebar selection reads the newly selected table, moves
its still-uncounted page off index 0 (`clamping` deliberately does not clamp
upward while uncounted) and bumps the token, so the select's schema and `count(*)`
are discarded as superseded and the tab settles on page 2 of a table with an empty
schema pane and a footer that can state no total. The **write** takes the same token by a second accessor rather than the same one:
`rowsToken` reads the generation *without* bumping it, because a write publishes no
page of its own and must not supersede the loads around it — it captures the page it
means to write against and is refused when a load has replaced it, where a read bumps
and wins. All three read entry points now
refuse a stale request before mutating anything. `reload()`'s own re-selection and
Core's tests pass no request and are never refused — and a caller that *did*
present one and then early-returns settles it, on every one of the three paths
that can do so.

## Two rules the model never breaks

**A failure never blanks a good answer.** Every seam failure lands in
`errorMessage` and leaves the rows, the schema and the listing exactly as they
were: a page that failed to refresh is still the page the reader was reading, and
replacing it with emptiness would destroy the only context the message has. The
one deliberate exception is selecting a *different* table, which clears the
previous table's rows in its synchronous prefix — leaving them under another
table's name would be a lie the error message does not correct.

**A sort the answer no longer carries did not happen** — and it is asked
*before* the page, not only after it. `reload` re-selects the table by name after
re-opening the file, that re-selection is a refresh, so the sort is carried, and
the database underneath may have been rebuilt with the sorted column dropped,
renamed or reordered. `select` therefore asks `DatabaseQuery.resultColumns` for
the shape the table answers now and drops a sort that fails
`survives(columnNames:)` before composing its page, because the two ways a stale
ordinal goes wrong are both settled by then: a **dropped** column leaves an
ordinal SQLite rejects at *prepare* time (`ORDER BY 2` against a one-column
`SELECT *` is an error, not an unsorted page), so the refresh would fail outright
under a message about an ordinal rather than showing the rebuilt table; and a
**reordered** answer — the case the position alone cannot catch — succeeds,
putting a page ordered by a column nobody clicked on screen. `publish` keeps the
same check on the answer itself, which is where a shape that changed between the
two statements lands, and which is the only check a page turn or a sort toggle
gets: within one selection the ordinal came from the answer on screen, so nothing
re-probes on those paths. Left set either way, the sort would claim an ordering
no header arrow can even show — a dropped column is not in `gridColumns` either —
and re-send it on every later page.

A failed read additionally puts the `page` and the `sort` back onto **the rows
that are actually on screen**, which is the same rule read from the chrome's
side. Those two are what the footer and the header arrow are drawn from, so a
`page` that moved while the rows did not would have the footer counting
"Rows 3–3 of 5 · Page 2 of 3" over page 1's rows, and a header arrow claiming an
order the grid is not in — under an error banner that explains neither. The
restore target is the private `shown` — the table, page and sort the last
successful `publish` answered — and deliberately **not** "the value the caller
held before it moved": the two agree for a single request and part ways the
moment two overlap, because a superseded move publishes nothing *and undoes
nothing*, which leaves the next failure's "previous" pointing at a page that was
never drawn. It is also what a failed *refresh* of the table already on screen
puts back, where the count landed and the page it was gating did not. An empty
grid has no position to restore, so the page returns to uncounted and the footer
says nothing.

**A failure is cleared by the load that caused it, and by no other.** The two
loads have their own tokens, so they have their own claim on the one message slot
too (`errorSource`): `load()` runs again every time the tab is shown, and a
listing that refreshed successfully clearing the banner for a page turn that
failed would take away the one sentence explaining the rows on screen. The
message itself is never a sentence this layer wrote: it is SQLite's, or the
schema parser's description of the shape it could not read.

**Every read is bounded.** The grid never asks for a table, only ever for one
page of it — `DatabaseQuery.page` with `LIMIT`/`OFFSET` bound — so opening a
hundred-million-row table costs one page-sized read and one `count(*)`. The
tests assert this as work, not as timing: a page load sends exactly one
page-sized statement and never an unbounded select.

## The reader boundary

The viewer neither raises the disk-writer gate (`autosave.suspend()` /
`localChanges.beginRevert()`) nor waits on it — the terminal's and the symbol
index's position. Reading sends nothing but `SELECT`s and pragmas, and the one
write goes into the database file, which is not a worktree *text* file any gated
operation is snapshotting. `DatabaseViewerSourceGatingTests` pins that no file of
this feature names either gate call.

Part 2a made the distinction **finer rather than weaker**: the viewer now
*consults* that gate before it writes a cell, which is the opposite direction —
refusing to write while an operation is rewriting the worktree, rather than
making that operation wait. A cell edit is not a worktree rewrite and
serializing a branch switch behind one would be backwards; writing a file out
from under an operation that is in the middle of replacing it would be worse.
The way the viewer stays a reader while asking is that the question arrives as
an **injected closure**: Core takes `isWriteBlocked` (defaulted to "nothing is
in the way"), `DatabaseViewerTabs` forwards it, and the scene is the one place
it is tied to `LocalChangesModel.isReverting` — so no file under the viewer names
`localChanges` at all, and Core, which cannot see `LocalChangesModel`, asks the
same question the app does. The gating suite pins four things about it: the
question is asked before anything is sent, it is asked in exactly one place
(`setCellToNull` routes through `updateCell`), the read entry points name neither
it nor the write hook, and the scene wires both exactly once.

The other direction is `didWrite`: a database is a tracked file, so a committed
edit owes Local Changes the same generation-pinned refresh a save gives it. It is
called on a commit alone — a rollback and a failure change nothing on disk and so
leave nothing stale.

The one place the feature touches a gated operation is the resync described
above, and it touches it only to be **excluded** from the text-shaped reasoning.

## Tests

Core-side, all in `Tests/PisakaCoreTests/`:

- `DatabaseFileRuleTests`, `FileIconTests`, `OpenFileTests` — the recognition
  rule in both cases, a middle `db` component, no extension, a dotfile; the icon
  entries; and that a `.viewer` `OpenFile` is not dirty even when someone assigns
  `text`.
- `WorkspaceModelTests` / `FileServiceTests` / `EditorSessionTests` — both switch
  positions (with it on, a `.viewer` tab with empty text and **no `read` call** on
  the stub; with it off, the same open takes the read path and surfaces today's
  read failure — iOS behavior, pinned), the dedup through an unstandardized path,
  the `.missingFile` throw, every text-shaped method asserted against
  `StubFileTree`'s call log to have written nothing, `close` never asking for
  confirmation, the resync rules, and a snapshot→restore round trip over a mixed
  set of text, untitled and viewer tabs — including that a restore into a
  switch-off workspace produces no viewer tab.
- `DatabaseValueTests`, `DatabaseServicingTests` — rendering for all five storage
  classes including NULL versus the empty string and the blob placeholder, that a
  blob value carries its length and no bytes (a gigabyte cell is the same size as
  an empty one), equality, and the fake's own call log and failure injection
  behaving as the later suites assume.
- `DatabaseCellEntryTests` — every affinity rule against SQLite's own
  documented examples (`INT`, `VARCHAR(255)`, `BLOB`, `FLOATING POINT`, `STRING`
  and an empty declaration), the numeric cases including `Int64` boundaries and
  an overflowing literal falling to a real, whitespace preserved rather than
  trimmed, `"NULL"`/`"null"`/`"nil"` stored as text while the gesture stores
  NULL, the empty entry as the empty string — and the untyped column both ways:
  `43` over the integer `42` stays an integer, `43` over the text `42` stays
  text, `4x` over either becomes text, and anything over a NULL becomes text.
- `DatabaseRowIdentityTests`, `DatabaseUpdatePlanTests` — the strategy for a
  plain table, a view, and a `WITHOUT ROWID` table with a single and with a
  composite key; each of the three alias spellings shadowed in turn and all three
  shadowed at once; a key column absent from the answer and one whose name
  matches two answered columns, each refused with its own reason. Then the plan:
  a rowid table and a composite-key table (every key column in the `WHERE`, in
  key order), every refusal by reason, a NULL previous value and a NULL new
  value, that no cell content ever reaches `sql` (a value spelling `'; DROP
  TABLE` travels bound), identifier quoting for names holding quotes and spaces,
  and — the case a positional map gets wrong — **a schema whose hidden column
  precedes a visible one**, where the plan must name the right column and an
  unmatched name must refuse. Plus a **blob primary key**, refused for every cell
  of the row and composing nothing (while a key column merely holding text still
  writes); the two backstops in `address(…)` — an empty key list and a key column
  positioned past the row — which are what stop a `WHERE` naming no row and
  therefore matching every one; and the surface-versus-planner agreement asserted
  by asking **both** halves about every column of one fixture rather than by
  asking `refusal(…)` twice. Every refusal's sentence is pinned non-empty and
  distinct, and the sample list is held complete by a `tag(_:)` `switch` with no
  `default`: a case added to `DatabaseEditRefusal` stops that test file compiling.
- `DatabaseSchemaTests`, `DatabaseQueryTests` — quoting a plain identifier, one
  holding a double quote, a semicolon and a space; the listing parser over a
  table and a view; the column parser over a composite primary key (ordinals
  preserved), a not-null column, a defaulted column and a generated one; every
  malformed shape producing its typed error; and every built statement asserted
  **byte-for-byte** with its parameter list — including the rowid probe and the
  identity-carrying page with the alias proven **bare and unquoted** (sorted and
  unsorted, with the `ORDER BY` ordinal proven unchanged by the appended column),
  and the `UPDATE`'s clause order and binding order.
- `DatabasePageTests`, `DatabaseViewerModelTests` — the paging and sort rules
  including the shrunken-total case, a total at `Int.max` (which the page-count
  arithmetic must answer rather than overflow on, since `count(*)` is clamped
  from SQLite's `Int64`), an index at `Int.max` while *uncounted* (which the
  offset arithmetic must likewise answer rather than trap on), two columns
  spelling one name sorting independently,
  and a sort surviving or not surviving a dropped versus a *reordered* answer —
  each of those two asserted at the model as *the stale ordinal never being
  sent*, since the drop's statement is one real SQLite refuses to prepare and the
  reorder's is one it happily answers wrongly, and neither is visible in a
  scripted answer alone; then the model against
  `ScriptedDatabaseService`: the happy path, paging forward and back with the
  bound `LIMIT`/`OFFSET` asserted per request, a sort toggle re-querying and
  resetting to page 1, a superseded load discarding its result (staged with
  `Gate`, asserted by polling for the sink's record and never by hop count), a
  file that is not a readable database landing in the error state rather than in
  an empty table list, a mid-paging failure leaving the previous page in place,
  and `close()` closing exactly once — plus the lifecycle the app drives (create
  on first selection, reuse on re-selection, close on tab close). Part 2a's half
  of that suite: identity carried and hidden for a rowid table, **and for a table
  with an `INTEGER PRIMARY KEY` alias where the trailing column repeats the alias
  column's name** (the split still correct, which is the case a name match gets
  wrong); nothing appended for a view or a `WITHOUT ROWID` table; a sort ordinal
  still ordering the same column with the identity column present; a probe
  failure degrading silently with no banner; `canEdit` with a hidden schema
  column ahead of the visible ones; then the write flow against the scripted
  seam — a committed edit re-querying the page and calling the hook, the gate
  refusal writing nothing and leaving the page, each typed refusal, the
  zero-affected and many-affected rollbacks with their sentences, a thrown SQLite
  failure, NULL set and unset round-tripping distinctly from the empty string, a
  write superseded mid-flight by a table selection (which publishes nothing while
  the commit still stands, and where the hook *is* still called because the file
  did change), and a second write refused while one is in flight. Then, on review:
  a write carrying a **stale rows token** refused before anything is composed and
  the same write with the current token going through; a retargeted tab writing to
  its new path with no reconnect; `reportEditRefusal` saying the refusal and
  sending nothing, and saying nothing for a cell that may be edited; a page that
  came back **without** the identity column it asked for publishing unsplit and
  refusing the edit; a committed write whose re-read fails saying so and leaving
  nothing spinning; a `WITHOUT ROWID` table's write end-to-end off a real page
  answer, with every key column in key order; `updateCell`/`setCellToNull` on a
  closed tab sending nothing; and the write's own three sentences pinned by
  content rather than against the constants that produce them.
- `DatabaseViewerSourceGatingTests` — the static rules no compiler can see:
  SQLite imported in exactly one file and nowhere under `Sources/PisakaCore/`;
  every app-side file of the feature `#if os(macOS)`-gated; `viewerTabsEnabled`
  spelled in exactly one app file, and that file `PisakaApp.swift`, while
  `iOS/PisakaApp_iOS.swift` constructs its workspace without it; no file of the
  feature naming either writer-gate call; the tab's connection opened
  `SQLITE_OPEN_READONLY` and the write's `SQLITE_OPEN_READWRITE`, exactly once
  each, with `SQLITE_OPEN_CREATE` nowhere and no other file opening a connection
  at all — which is the flag the whole reader claim rests on and the one a
  compiler is happy to see changed; and the app sites that iterate
  `openFiles` for text pinned **by count** against the count of tab-kind filters,
  so a new text-shaped consumer fails here until it skips viewer tabs; and part
  2a's four gate pins — the write entry points asking `isWriteBlocked()` before
  anything is sent and asking it in exactly one place, no viewer file naming
  `localChanges`, the scene wiring the question to that flag and the hook to
  `refreshLocalChanges()` exactly once, and the read entry points naming neither.
  Like every
  suite of its kind it matches against comment- and string-literal-stripped text,
  because the files it reads quote the very tokens it looks for.

The shared fake is `Tests/PisakaCoreTests/Support/ScriptedDatabaseService.swift`:
canned answers keyed by SQL text, a call log, per-call failure injection, and a
`Gate` hook so a test can hold one call open while another proceeds. Its write
half is deliberately **not** keyed by SQL text: a transaction is a list of
statements the model composes from a plan asserted elsewhere, so keying by text
would mean restating the composed `UPDATE` byte-for-byte in every write test just
to script an answer. What the write path is about is the *outcome* — committed,
rolled back at zero, rolled back at many, thrown — so that is what is scripted
(singly or as a sequence, the last sticking), while what was handed over is read
back verbatim out of `writeTransactions`. It is also not gated on whether this
instance's read connection is open, because a write is a connection of its own. It runs on
the cooperative pool, so everything it records hops to the main actor first —
the repository's standing rule for a fake standing in for a `nonisolated async`
seam.

## Known limits (parts 1 and 2a)

- **One write of one shape.** A cell is editable in place; nothing else is. There
  is no SQL console (part 2b), no insert, no delete, no schema change, no
  multi-cell or multi-row edit and no undo of a committed one — the database's
  own tools and the file's git history are what an edit is undone through. A
  blob cell cannot be edited at all: a page carries a blob's length and never its
  bytes, so the old value cannot be put in a `WHERE` and there is nothing for a
  text field to show. Neither can a generated or hidden column, a view's rows, a
  column whose name the schema cannot resolve uniquely, or a table that declares
  no rowid and no primary key — each refused by name, with its own sentence.
  A **binary primary key** is the same refusal one step further out
  (`DatabaseEditRefusal.blobRowIdentity`): a `WITHOUT ROWID` table keyed on a
  BLOB — a content-addressed table — has no row this layer can *name*, since the
  bytes a `WHERE` would name it with never left the database, so every cell of
  such a row is refused rather than the key column alone. Asked in one place
  (`DatabaseUpdatePlanner.blobKeyColumn(identity:row:)`) and consulted from both
  `refusal(…)` and `address(…)`, so the grid never draws as editable a cell the
  planner would refuse — and so the binder's blob refusal, which speaks about a
  seam rather than about a cell, stays unreachable.
- **The tab's own connection is still read-only.** It is opened
  `SQLITE_OPEN_READONLY` and stays so for its whole life, so the reader claim
  holds *at the file level* and not merely at the SQL level — no hot-journal
  recovery at open, no WAL checkpoint at close, and so no worktree write behind
  the reader's back. A cell edit opens a second, short-lived read-write
  connection and closes it again, so only an edit that was actually asked for
  pays that cost (the connection service's entry above has the full reasoning).
- **An edit is refused while the worktree is being rewritten**, and refused
  outright rather than queued: a checkout, a revert, a merge apply, a project
  Replace All, a commit or an LSP rename in flight means the file may be replaced
  under the write. Reading the same tab is unaffected. A second edit arriving
  while one is in flight is likewise refused rather than queued.
- **A WAL database no live connection has initialized may refuse to open.** A
  read-only handle cannot create or recover the `-shm` sidecar a WAL database
  needs, so one left behind by a process that died without checkpointing — or one
  whose sidecars are not writable — answers SQLite's "unable to open database
  file" where a read-write handle would have recovered it. The failure is honest
  (SQLite's own sentence reaches the banner) and the trade is deliberate: taking a
  write handle to read a tracked file is the larger cost, per the bullet above.
- **A value whose rendering does not round-trip cannot be edited faithfully.**
  Two shapes reach the grid as text that is not what SQLite holds, and the write
  binds *the rendering* back into the `WHERE` and the `SET`. A TEXT cell holding
  bytes that are not valid UTF-8 is decoded with U+FFFD substitutions, so the
  `IS` guard matches nothing and the edit is rolled back under the collision
  sentence ("This row changed underneath you") — which is the wrong reason, and
  reloading never helps. A REAL cell holding an infinity renders as `inf`, which
  the typing rule correctly declines to read as a numeral, so re-committing an
  untouched cell retypes it from a float to the text `inf` — SQLite's own
  affinity answer for that spelling, but not what was there. Both are refusals
  the layer *should* make and cannot: the page carries the rendering, not the
  bytes, and making it carry both is a change to the seam rather than to the
  planner. Neither is reachable from a database written by ordinary means.
- **macOS only.** iOS opens a database as text and fails, honestly (decision 3).
- The grid pages at a fixed 200 rows and has no jump-to-page field; the row count
  is read once per table selection, so a table another process is writing shows a
  total that is a moment old until the table is re-selected. A *page* that has
  gone past the end after such a change re-clamps on the next count.
- Only tables and views are listed. Indexes, triggers and virtual-table shadow
  tables are not shown, and neither is `sqlite_`-prefixed internal bookkeeping.
- The listing does not refresh itself: a table created by another process appears
  after the tab is reopened (or after a `load()` refresh).
- Attached databases and encrypted databases get no special handling — the
  latter simply fails to open with SQLite's own message. A `WITHOUT ROWID` table
  is handled only where it has to be: it is *detected* (by probe) and its rows
  are addressed by their declared primary key, and nothing else about it is
  special-cased.

## What part 2b adds

Part 2b is a separate ticket, written against the write path this one
established, and it revisits none of it:

- **The SQL console**, with its mutating-statement confirmation. It composes its
  own statements in `DatabaseQuery` like everything else, runs a mutating one
  through the same `performWrite(_:)` member — which is why that member takes a
  *list* of statements and a required count rather than one `UPDATE` and a `1` —
  and renders its result table through `DatabaseValue.displayText`, which is why
  rendering lives in Core rather than in the grid.
- The decision **whether iOS gets a surface**, and therefore the switch, is still
  open; until then `viewerTabsEnabled` stays `false` everywhere but
  `PisakaApp.swift`.

Part 1's one open question is **answered** and needs no further work:
`closeAll()` at termination stays best effort, because a write is a separate
connection that commits or rolls back and closes before `performWrite(_:)`
returns, so a viewer tab never holds unflushed state (decision 10).
