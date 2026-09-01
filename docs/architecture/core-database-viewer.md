# PisakaCore + Pisaka app (macOS) — the database viewer tab

Design documentation for the database viewer: the rule that recognizes a
database file, the **second kind of tab** it opens into, the async seam that
talks to SQLite, the pure engines that decide every statement, every parsed
answer and every page of rows, the viewer model that orders overlapping loads,
and the macOS surface that draws what Core answered. Read the relevant entry
before modifying that file, and update it when behavior changes.

This is **part 1**: the viewer is read-only and macOS-only. What part 2 adds —
inline cell editing, the transactional write, the SQL console — has its seat
reserved at the end of this document; nothing here needs revisiting for it.

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
   (`file_length` 1809 → 1826, `type_body_length` 1800 → 1810), with the reason
   appended to `.swiftlint.yml`'s ceiling comment and both numbers updated in
   `LintConfigurationTests.documentedRootThresholds`. See `style-lint.md`.

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
  **Rendering lives here**, not in the grid, so the grid and (in part 2) the
  console's result table cannot disagree about the one distinction the viewer
  must never blur: `nullDisplayText` is `"NULL"`, non-empty by construction, so
  an empty `text("")` cell renders as the empty string and is never mistaken for
  a missing value — while `isNull` is the honest question, because no `String`
  marker is unforgeable against a text value that spells it out. A blob renders
  as `blobDisplayText(byteCount:)`, a placeholder rather than the bytes: a blob
  column holds images and archives, and its size is the one fact a reader can
  act on. The same file carries `DatabaseStatement` (SQL text plus positionally
  bound parameters) and `DatabaseResultSet` (column names, rows, `affectedRows`,
  and a bounds-checked `value(row:column:)` so a malformed answer is reported
  rather than trapped on). `affectedRows` is carried from the start although
  every part-1 read leaves it zero — it is what part 2's `UPDATE … WHERE` checks
  to confirm it touched exactly the row it named, and adding it later would mean
  revisiting the seam.

- `DatabaseServicing.swift` — the whole app/Core boundary: `open(url:)`,
  `run(_:) -> DatabaseResultSet`, `close()`, all `async`, with `close()`
  defaulted the way `GitServicing`'s optional members are so a fixed-answer stub
  compiles. A connection is **one file**: `open(url:)` is called once per
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
  one, which is why `LIMIT` and `OFFSET` travel as bound values. The four
  statements: `tableListing` (`sqlite_master`, not the modern `sqlite_schema`
  alias, so the text runs against every SQLite this app may meet; internal tables
  excluded by their *reserved* `sqlite_` prefix, so no table of the user's can be
  hidden by that filter; ordered by name alone, because grouping tables and views
  apart is the sidebar's presentation decision); `columnSchema(table:)` using
  `PRAGMA table_xinfo` rather than `table_info` — it answers the same rows plus
  `hidden`, the only way to learn a column is generated, which is the fact part 2
  needs in order to refuse to write it; `rowCount(table:)`, asked separately
  because a `LIMIT`ed page knows nothing about what lies past its end; and
  `page(table:orderBy:ascending:limit:offset:)`, whose `limit` and `offset` are
  bound and **floored at zero** — not defensive tidiness, but because SQLite
  reads a *negative* `LIMIT` as "no limit at all", so a negative slipping through
  would turn the one statement that must always be bounded into a full-table
  select.

- `DatabaseSchema.swift` — the schema value types and the two **pure** parsers.
  `DatabaseTableEntry` is a name, a closed `Kind` (`table`/`view` — the listing
  asks for exactly two, and an index or a trigger is not something a grid can
  show; the raw value *is* `sqlite_master`'s own text) and the `definition`
  carried **untouched**, the exact `CREATE` text SQLite stored, because part 2
  needs to know how a column was declared and re-composing that from the parsed
  columns would be this layer inventing a fact it can only approximate.
  `DatabaseColumn` carries the name, the declared type (verbatim and possibly
  empty — SQLite's type affinity allows a column with no declared type, which is
  a fact about the schema and not a parse failure), the **primary-key position as
  an ordinal** rather than a flag (a composite key's order is what part 2's
  `UPDATE … WHERE` addresses a row by, and a `Bool` would throw it away and force
  a second pragma later), not-null, the default as a SQL *expression* string
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
  may not exist is not. A table with **no rows still has one page**, the empty
  one the reader is looking at; reporting zero would put them on page 1 of 0.
  `displayedRows(loaded:)` is driven by what actually arrived rather than by the
  page size, so a short last page does not claim rows the grid is not drawing.
  `defaultSize` is 200, referenced by both the arithmetic and the statement that
  binds it rather than restated at either site. Alongside it
  `DatabaseSortState`: a column plus `ascending`/`descending`, with two rules —
  `toggled(_:column:)` (a **new** column sorts ascending, because that is the
  order the reader means; the **same** column flips, with no third click that
  clears, because cycling back into SQLite's arbitrary storage order through a
  header nobody aimed at would look like the sort had failed) and
  `carriedOver(_:from:to:)` (nothing survives a genuine table change — a column
  name is meaningful only inside its own table, and carrying `ORDER BY "price"`
  into a table with no `price` would turn the next page query into a SQL error
  nobody asked for — while re-selecting the table already showing keeps the
  sort, because that is a refresh and not a move). The two types live in one
  file because a sort change resets the page and a table change clears the sort:
  the rules are read together or not at all.

- `DatabaseViewerModel.swift` — one open database tab's state, in
  `LocalChangesModel`'s shape: a `@MainActor ObservableObject` whose I/O is
  injected behind `DatabaseServicing`, whose published state is only ever touched
  on the main actor, and whose overlapping loads are ordered by monotonic
  generation tokens. Foundation only — every statement it sends is composed by
  `DatabaseQuery` and every answer read by `DatabaseSchema`, so nothing here
  knows SQLite exists. `load()` opens the connection once (a second call is a
  refresh; a failed open leaves `isOpen` false so the next call retries rather
  than running statements against nothing) and lists the tables and views.
  `select(table:)` loads the schema, the count and the first page.
  `goToPage(_:)` moves and reloads — a move to the page already shown is a no-op
  rather than a re-query, because the paging controls are clickable at both ends.
  `toggleSort(column:)` flips or re-aims the sort, resets to the first page and
  **keeps the count**: an `ORDER BY` reorders rows without changing how many
  there are, so re-asking `count(*)` would be a second full-table read for an
  answer already in hand. `close()` latches. `gridColumns` is published
  separately from `columns` and is deliberately **not** `columns.map(\.name)`: a
  hidden column appears in the pragma and not in `SELECT *`, so reading the
  headers off the schema would shift every cell in such a table one column left.

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
  `SQLITE_OPEN_READWRITE` and deliberately **without** `SQLITE_OPEN_CREATE`: the
  file was probed into existence by `WorkspaceModel.open(url:)`, and a path that
  reached here anyway must report rather than quietly conjure an empty database.
  A **busy timeout** (5 s) is set immediately after the open, before any statement
  can run: without it SQLite returns `SQLITE_BUSY` the instant a lock is
  contended, so a viewer opened over a database another process is writing would
  flash an error rather than wait the moment out — and five seconds is short
  enough that a genuinely *held* lock reports instead of hanging the tab. Text and
  blob bindings use SQLite's transient destructor, because the Swift value backing
  them dies at the end of the `withUnsafe…` call. Every failure becomes a
  `DatabaseError` carrying `sqlite3_errmsg` verbatim; `close()` finalizes, closes
  and is safe to call twice.

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
  tab opened for no visible change. `closeAll()` is what termination calls, and
  is **best effort by construction and said to be**: it runs from
  `willTerminateNotification`, the last notification AppKit posts, so the `async`
  close may not get a run-loop turn — acceptable for part 1's read-only
  connections, which have nothing unflushed to lose, and what the call really buys
  is the non-terminating path releasing everything at a point where the hop
  certainly runs. **A whole file of its own on purpose** (decision 4), and it
  states the reader boundary: nothing in this feature may name
  `autosave.suspend()` or `localChanges.beginRevert()`.

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
  Everything is sized through `\.interfaceMetrics`; nothing is drawn at the code
  font, so the viewer is chrome for zoom purposes and declares no `ZoomSurface`.
  `DatabaseViewerHost` is the thin adapter `ContentView` routes to: it asks the
  environment's `DatabaseViewerTabs` for the tab's model and keys the surface on
  the tab id, so switching between two viewer tabs rebuilds against the other
  model rather than reusing one's scroll and selection under another database's
  rows. The load is kicked by `.task(id: model.fileURL)`.

- `ContentView.swift` — `editorZone` keeps the breadcrumb for **every** tab (a
  database has a path like any other file) and routes below it on the tab kind:
  a viewer tab gets `DatabaseViewerHost`, a text tab gets `textEditorZone(for:)`,
  which is the consent banner, the find bar and `CodeEditorView` lifted into a
  helper so the routing is one short expression rather than a hundred lines of
  editor wiring wrapped in an `if`.

- `PisakaApp.swift` — the four wiring edits plus the skips. `WorkspaceModel(
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
  - the post-operation resync (`resyncOpenTabsAfterCheckout` and the revert loop,
    through one shared `resyncViewerTab(_:mayRemoveFiles:)`) — a viewer tab whose
    file is gone and whose caller `mayRemoveFiles` **force-closes**, exactly like
    a text tab on a deleted file, and its connection goes with it through the tab
    subscription; a viewer tab whose file is still there is **left alone**: no
    reload, no baseline reconcile, no beep. Without that rule the text branch
    reads a viewer tab as "unchanged" (its text is empty on both sides), asks
    `reloadFromDisk`, gets the `false` a viewer tab always answers, and
    force-closes a tab whose file is sitting right there.
  - autosave, the on-save transform and Local History capture need **no** filter:
    all three are gated on `isDirty`, which is `false` for a viewer tab by
    construction. The invariant *is* the reason, so the gating suite pins it
    rather than letting a second filter grow beside it.

## The generation-token scheme

`DatabaseViewerModel` carries **two** tokens, because there are two
independently re-triggerable loads. The table listing is re-asked by `load()`;
the schema-and-page load is re-asked by `select(table:)`, `goToPage(_:)` and
`toggleSort(column:)`, which a reader can fire far faster than a large table
answers. One shared token would let a finished listing cancel a page load that
has nothing to do with it, so the two are counted apart.

Each token is bumped in its method's **synchronous prefix** — the run of
statements before the first `await`, which the main actor executes without
interruption — and every result is dropped unless the token it captured is still
the latest. A superseded load publishes **nothing**: not its rows, not its
error, not its loading flag. The one thing recorded even when superseded is
`isOpen`, because that is a fact about the connection rather than published
state: the file is open either way, and opening it twice is what must not happen.

`close()` bumps **both** tokens before releasing the connection, so a load still
in flight resumes to find itself superseded and publishes nothing into a tab that
is gone.

## Two rules the model never breaks

**A failure never blanks a good answer.** Every seam failure lands in
`errorMessage` and leaves the rows, the schema and the listing exactly as they
were: a page that failed to refresh is still the page the reader was reading, and
replacing it with emptiness would destroy the only context the message has. The
one deliberate exception is selecting a *different* table, which clears the
previous table's rows in its synchronous prefix — leaving them under another
table's name would be a lie the error message does not correct. The message
itself is never a sentence this layer wrote: it is SQLite's, or the schema
parser's description of the shape it could not read.

**Every read is bounded.** The grid never asks for a table, only ever for one
page of it — `DatabaseQuery.page` with `LIMIT`/`OFFSET` bound — so opening a
hundred-million-row table costs one page-sized read and one `count(*)`. The
tests assert this as work, not as timing: a page load sends exactly one
page-sized statement and never an unbounded select.

## The reader boundary

The viewer neither raises the disk-writer gate (`autosave.suspend()` /
`localChanges.beginRevert()`) nor waits on it — the terminal's and the symbol
index's position. Part 1 sends nothing but `SELECT`s and pragmas, and even part
2's writes will go into the database file, which is not a worktree *text* file
any gated operation is snapshotting. `DatabaseViewerSourceGatingTests` pins that
no file of this feature names either gate call.

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
  classes including NULL versus the empty string and the blob placeholder,
  equality, and the fake's own call log and failure injection behaving as the
  later suites assume.
- `DatabaseSchemaTests`, `DatabaseQueryTests` — quoting a plain identifier, one
  holding a double quote, a semicolon and a space; the listing parser over a
  table and a view; the column parser over a composite primary key (ordinals
  preserved), a not-null column, a defaulted column and a generated one; every
  malformed shape producing its typed error; and every built statement asserted
  **byte-for-byte** with its parameter list.
- `DatabasePageTests`, `DatabaseViewerModelTests` — the paging and sort rules
  including the shrunken-total case, then the model against
  `ScriptedDatabaseService`: the happy path, paging forward and back with the
  bound `LIMIT`/`OFFSET` asserted per request, a sort toggle re-querying and
  resetting to page 1, a superseded load discarding its result (staged with
  `Gate`, asserted by polling for the sink's record and never by hop count), a
  file that is not a readable database landing in the error state rather than in
  an empty table list, a mid-paging failure leaving the previous page in place,
  and `close()` closing exactly once — plus the lifecycle the app drives (create
  on first selection, reuse on re-selection, close on tab close).
- `DatabaseViewerSourceGatingTests` — the static rules no compiler can see:
  SQLite imported in exactly one file and nowhere under `Sources/PisakaCore/`;
  every app-side file of the feature `#if os(macOS)`-gated; `viewerTabsEnabled`
  spelled in exactly one app file, and that file `PisakaApp.swift`, while
  `iOS/PisakaApp_iOS.swift` constructs its workspace without it; no file of the
  feature naming either writer-gate call; and the app sites that iterate
  `openFiles` for text pinned **by count** against the count of tab-kind filters,
  so a new text-shaped consumer fails here until it skips viewer tabs. Like every
  suite of its kind it matches against comment- and string-literal-stripped text,
  because the files it reads quote the very tokens it looks for.

The shared fake is `Tests/PisakaCoreTests/Support/ScriptedDatabaseService.swift`:
canned answers keyed by SQL text, a call log, per-call failure injection, and a
`Gate` hook so a test can hold one call open while another proceeds. It runs on
the cooperative pool, so everything it records hops to the main actor first —
the repository's standing rule for a fake standing in for a `nonisolated async`
seam.

## Known limits (part 1)

- **Read-only.** Cells cannot be edited, there is no SQL console, and nothing in
  the app writes to a database. The connection is opened read-write anyway, so
  part 2 needs no change to the open.
- **macOS only.** iOS opens a database as text and fails, honestly (decision 3).
- The grid pages at a fixed 200 rows and has no jump-to-page field; the row count
  is read once per table selection, so a table another process is writing shows a
  total that is a moment old until the table is re-selected. A *page* that has
  gone past the end after such a change re-clamps on the next count.
- Only tables and views are listed. Indexes, triggers and virtual-table shadow
  tables are not shown, and neither is `sqlite_`-prefixed internal bookkeeping.
- The listing does not refresh itself: a table created by another process appears
  after the tab is reopened (or after a `load()` refresh).
- Attached databases, `WITHOUT ROWID` specifics and encrypted databases get no
  special handling — the last simply fails to open with SQLite's own message.

## What part 2 adds

Part 2 is a separate ticket, written against the seam this part established. It
adds **protocol members, defaulted** (the `GitServicing` precedent) and revisits
none of the tab-kind work:

- **Inline cell editing** — the pure `UPDATE … WHERE` plan with its typed
  refusals: no primary key, a generated or hidden column, a view rather than a
  table, a value whose storage class cannot be expressed. The facts it needs are
  already carried: `DatabaseColumn.primaryKeyPosition` as an *ordinal* (so a
  composite key can address a row), `isHidden`, and
  `DatabaseTableEntry.definition` verbatim.
- **The transactional write** with the affected-row check —
  `DatabaseResultSet.affectedRows` exists for exactly this and is already
  populated by the app half.
- **The SQL console**, with its mutating-statement confirmation. Its result table
  renders through `DatabaseValue.displayText`, which is why rendering lives in
  Core rather than in the grid.
- The decision **whether iOS gets a surface**, and therefore the switch, is part
  2's to make; until then `viewerTabsEnabled` stays `false` everywhere but
  `PisakaApp.swift`.

A write also reopens one question part 1 could answer cheaply: `closeAll()` at
termination is best effort, which is fine for read-only connections with nothing
unflushed. A writing viewer must settle that differently.
