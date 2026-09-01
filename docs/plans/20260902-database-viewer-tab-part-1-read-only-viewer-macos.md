# Database viewer tab, part 1: the second tab kind and the read-only viewer (macOS)

## Overview

Part 1 of the split agreed in planning. It delivers everything up to and
including a **read-only** database viewer: the extension recognition rule, a
second kind of tab in `WorkspaceModel` (a *viewer tab* that carries no text and
can never be dirty), the async database seam in Core with its scripted fake, the
schema/value/pagination/sort engines, the viewer model with its generation
tokens, the macOS surface (table and view list, schema, paged sortable grid,
error state), and the deliberate skip of viewer tabs by every text-assuming
consumer — plus the gating suite that keeps those skips honest.

**Part 2 is a separate ticket, written after this lands**: the inline
cell-editing engine (the `UPDATE … WHERE` plan with its typed refusals), the
transactional write with the affected-row check, and the SQL console with its
mutating-statement confirmation. Part 1 shapes the seam so Part 2 only adds
protocol members (defaulted, the `GitServicing` precedent) and never revisits the
tab-kind work.

Nothing here adds a SwiftPM dependency: the app half links the system SQLite
library available in the Apple SDK. `project.yml`, `Package.resolved` and the
license manifest are untouched.

## Context

**Core files involved**

- `Sources/PisakaCore/OpenFile.swift` — gains the tab kind; `isDirty` becomes
  `false` by construction for a viewer tab.
- `Sources/PisakaCore/WorkspaceModel.swift` — a new `viewerTabsEnabled` switch
  on the initializer; `open(url:)` routes on the recognition rule only when the
  switch is on; every text-shaped method skips viewer tabs; `close` never
  returns `.needsConfirmation` for one.
- `Sources/PisakaCore/FileService.swift` — one new `FileServiceError` case for
  the failed existence probe (see decision 2).
- `Sources/PisakaCore/EditorSession.swift` — **unchanged on purpose**
  (decision 1).
- `Sources/PisakaCore/FileIcon.swift` — an icon for the recognized extensions.

**App files involved (all macOS, `#if os(macOS)`)**

- `Sources/Pisaka/DatabaseViewerTabs.swift` — **new**: the per-tab viewer-model
  ownership and connection lifetime, deliberately its own file rather than more
  of `PisakaApp` (see the lint note below).
- `Sources/Pisaka/DatabaseViewerView.swift` — **new**: the surface.
- `Sources/Pisaka/Platform/DatabaseConnectionService.swift` — **new**: the one
  file that imports the system SQLite module.
- `Sources/Pisaka/ContentView.swift` — `editorZone` routes on the tab kind.
- `Sources/Pisaka/PisakaApp.swift` — kept to the **four unavoidable edits**:
  turning the workspace switch on, the `openBuffers` skip, the ⌘S funnel's
  early return, and the resync branch (plus the three buffer-snapshot maps'
  filter, which is the same one-expression change repeated).

**Patterns followed**

- Seam shape: `LeetCodeTransport` / `LSPTransport` / `GitServicing` — Core owns
  every decision and the SQL text, the app owns the C API and knows nothing
  about what it means. Defaulted protocol members so a partial stub compiles.
- Scripted fake:
  `Tests/PisakaCoreTests/Support/ScriptedLeetCodeTransport.swift` and
  `ScriptedLSPTransport.swift`.
- Generation tokens captured **synchronously before the `Task` hop**
  (`LocalChangesModel`, `FindUsagesModel`).
- Async test staging with `Gate` and a `waitFor` condition-wait that fails
  loudly, never a timed delay.
- Source-gating suite shape: `LocalHistorySourceGatingTests` — reads `Sources/`
  through `#filePath`, strips comments and string literals, pins counts.
- Store-as-spelled / match-canonically: `WorkspaceModel.canonicalURL`.

**Dependencies:** none new. The app half imports the system SQLite module; Core
imports Foundation only.

## Development Approach

- **Testing approach**: Regular (code first, then tests in the same task).
- Complete each task fully — including its tests and a green `swift test` —
  before starting the next.
- Core stays Foundation-only; no SQLite import anywhere under
  `Sources/PisakaCore/`.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**

### Four decisions made up front (do not re-litigate mid-implementation)

1. **The session record does not change.** `SessionTab` stays the flat
   `path`/`text` struct. A viewer tab is persisted as an ordinary `path` record,
   and restore gets it back as a viewer tab because `restoreSession` opens every
   titled record *through* `WorkspaceModel.open(url:)`, which applies the
   recognition rule. One decision point, no new field, no compatibility
   question.

2. **A viewer tab's file is probed, not read.** `open(url:)` for a recognized
   file never calls `fileService.read` (the bytes are not text). Existence is
   probed with `fileService.fileStamp(at:)`. A `nil` probe throws a **new**
   `FileServiceError` case — `case missingFile(name: String)`, with an
   `errorDescription` naming the file in plain words — because the existing enum
   has no not-found case at all (only `alreadyExists`, `unsupported`,
   `notADirectory(name:)`); the text path gets its not-found error out of
   `String(contentsOf:)`, which the viewer path never calls. Restore skips such
   a record exactly as it skips a deleted text file's.

3. **Viewer tabs are off by default and turned on by the macOS app alone.**
   The routing lives in Core's `open(url:)`, and the iOS layer opens files
   through that same method in four places (`RootView_iOS.swift` and
   `FilePicker_iOS.swift`), where there is no viewer surface — an iOS viewer tab
   would render a database as an empty text file. So `WorkspaceModel.init` gains
   `viewerTabsEnabled: Bool = false`; with it off, a `.sqlite`/`.db` file takes
   the ordinary read path and fails exactly as it does today (`FileService.read`
   is strict UTF-8 and a database header does not decode) — iOS behavior is
   unchanged, honestly failing rather than silently lying. Only
   `Sources/Pisaka/PisakaApp.swift` passes `true`; the gating suite pins that.
   Turning iOS on is the follow-up ticket's business, not a fallback here.

4. **`PisakaApp.swift` is at its measured lint ceiling and must not simply
   grow.** The file sits at exactly `file_length` 1809, with `type_body_length`
   1800 one behind it and the `PisakaApp` struct body spanning nearly the whole
   file; `.swiftlint.yml` calls both measured and "not a licence to grow". So
   the per-tab viewer-model ownership and connection lifetime go in their own
   file (`DatabaseViewerTabs.swift`) and the `PisakaApp` edits stay minimal.
   Task 7 measures what is left with `swiftlint --strict` and, only if the file
   still crosses, raises **both** ceilings by the measured amount — never
   rounded up for room — extends the ceiling comment with this feature's reason
   as previous features did, and updates
   `LintConfigurationTests.documentedRootThresholds` (which carries both
   numbers) in the same commit.

## Implementation Steps

### Task 1: The recognition rule and the second tab kind

**Files:**
- Create: `Sources/PisakaCore/DatabaseFileRule.swift`
- Modify: `Sources/PisakaCore/OpenFile.swift`, `Sources/PisakaCore/FileIcon.swift`
- Create: `Tests/PisakaCoreTests/DatabaseFileRuleTests.swift`
- Modify: `Tests/PisakaCoreTests/OpenFileTests.swift` (or create if absent),
  `Tests/PisakaCoreTests/FileIconTests.swift`

- [x] Write `DatabaseFileRule` — one pure static answer, `isDatabaseFile(named:)`,
      over the recognized extension set (`sqlite`, `sqlite3`, `db`), matched
      case-insensitively on the **last** path extension only; expose the
      recognized set as a `public static let` so the icon table and the docs read
      it rather than restating it
- [x] Add `OpenFile.Kind` (`.text`, `.viewer`) with `.text` as the initializer
      default, and make `isDirty` return `false` for `.viewer` unconditionally —
      the "never dirty by construction" invariant, stated in the doc comment
- [x] Add a `viewer` initializer (`url` required, `text`/`savedText` forced
      empty) so a viewer tab cannot be constructed carrying text
- [x] Add the recognized extensions to `FileIcon`'s extension table
- [x] Write tests: each recognized extension in both cases; an unrecognized
      extension; a name whose *middle* component is `db` (`a.db.txt` → not
      recognized); no extension; a dotfile; the icon entries; a `.viewer`
      `OpenFile` is not dirty even if someone assigns `text`
- [x] run `swift test` — must pass before Task 2

### Task 2: Viewer-tab semantics in the workspace model, behind the platform switch

**Files:**
- Modify: `Sources/PisakaCore/WorkspaceModel.swift`,
  `Sources/PisakaCore/FileService.swift`
- Modify: `Tests/PisakaCoreTests/WorkspaceModelTests.swift`,
  `Tests/PisakaCoreTests/EditorSessionTests.swift`,
  `Tests/PisakaCoreTests/FileServiceTests.swift`

- [x] Add `FileServiceError.missingFile(name: String)` with its `errorDescription`
      arm, and a doc note that it is thrown by the probe-only open path
      (decision 2)
- [x] Add `viewerTabsEnabled: Bool = false` to `WorkspaceModel.init`, stored, with
      a doc comment carrying decision 3 in full — including that iOS keeps today's
      read-failure behavior and why
- [x] `open(url:)`: keep the canonical-path dedup exactly as it is (it already
      matches a viewer tab against a second open of the same database), then,
      **only when the switch is on**, branch on `DatabaseFileRule` — a recognized
      file is probed with `fileService.fileStamp(at:)` and appended as a `.viewer`
      `OpenFile`, throwing `.missingFile` when the probe comes back `nil`; every
      other case, and every case with the switch off, takes the read path
      unchanged
- [x] Make every text-shaped method skip a viewer tab, each with a one-line doc
      note saying why: `save(for:)` returns `.saved` **without writing** (saving a
      viewer tab is a no-op, not an error), `saveAllDirty()` skips it (already
      implied by `isDirty`, but made explicit and tested), `saveAs(url:for:)`
      refuses, `markSaved`, `updateText`, `replaceText`, `reloadFromDisk` and
      `reconcileSavedBaseline` are no-ops returning `false` where they return a
      `Bool`
- [x] `close(id:force:)`: a viewer tab is always `.closed`, never
      `.needsConfirmation`
- [x] Confirm `EditorSession.snapshot` already records a viewer tab as a `path`
      record (it branches on `url`, not on content) and that `restoreSession`
      brings it back as a viewer tab through `open(url:)`; add the tests rather
      than the code
- [x] Write tests, **both switch positions**: with the switch on, opening a
      recognized file yields a `.viewer` tab with empty text and no `read` call on
      the stub; with it off, the same open takes the read path and surfaces the
      read failure — today's iOS behavior, pinned; opening the same database
      twice yields one tab and selects it, including through a
      symlinked/unstandardized path; opening a recognized-but-missing file throws
      `.missingFile` naming the file;
      `save`/`saveAllDirty`/`saveAs`/`updateText`/`replaceText`/`reloadFromDisk`
      write nothing and change nothing (assert against `StubFileTree`'s call log);
      `close` never asks for confirmation; snapshot→restore round-trips a mixed
      set of text, untitled and viewer tabs with the selection landing on the
      right one, and a restore into a switch-off workspace does not produce a
      viewer tab
- [x] run `swift test` — must pass before Task 3

### Task 3: The database seam and its scripted fake

**Files:**
- Create: `Sources/PisakaCore/DatabaseValue.swift`,
  `Sources/PisakaCore/DatabaseServicing.swift`
- Create: `Tests/PisakaCoreTests/Support/ScriptedDatabaseService.swift`
- Create: `Tests/PisakaCoreTests/DatabaseValueTests.swift`,
  `Tests/PisakaCoreTests/DatabaseServicingTests.swift`

- [ ] `DatabaseValue` — a closed enum over the five storage classes
      (`integer(Int64)`, `real(Double)`, `text(String)`, `blob(Data)`, `null`),
      plus the display rendering the grid uses: `displayText` renders NULL as a
      marker that is **not** producible by an empty text value, and a blob as a
      byte-count placeholder rather than raw bytes; `isNull`; a doc comment
      stating that rendering lives here so both the grid and (in part 2) the
      console share one answer
- [ ] `DatabaseStatement` (SQL text plus ordered bound parameters) and
      `DatabaseResultSet` (column names, rows, and the affected-row count) as
      `Equatable, Sendable` value types
- [ ] `DatabaseError` — typed failures with a `message` carrying the library's own
      text verbatim (cannot open, not a database, busy, SQL error, closed);
      nothing is swallowed anywhere in the layer
- [ ] `DatabaseServicing` — the async protocol: `open(url:)`, `close()`,
      `run(_:) -> DatabaseResultSet`. Members defaulted where a partial stub makes
      sense, following `GitServicing`. Doc comment records that Core composes
      every byte of SQL and every bound value, that the app half knows nothing
      about what any of it means, and that part 2 will add the transactional
      members here
- [ ] Build `ScriptedDatabaseService`: canned answers keyed by SQL text, a call
      log, per-call failure injection, and a `Gate` hook so a test can hold one
      call open while another proceeds; main-actor-safe writes per the repo's
      cooperative-pool rule
- [ ] Write tests: value rendering for all five classes including NULL vs. the
      empty string and a blob placeholder; `DatabaseValue` equality; the fake's
      own call log and failure injection behave as the later tasks assume
- [ ] run `swift test` — must pass before Task 4

### Task 4: Schema modeling and query building

**Files:**
- Create: `Sources/PisakaCore/DatabaseSchema.swift`,
  `Sources/PisakaCore/DatabaseQuery.swift`
- Create: `Tests/PisakaCoreTests/DatabaseSchemaTests.swift`,
  `Tests/PisakaCoreTests/DatabaseQueryTests.swift`

- [ ] `DatabaseSchema.swift`: `DatabaseTableEntry` (name, a closed `kind` of table
      or view, and the declaration text as stored, carried untouched for part 2)
      and `DatabaseColumn` (name, declared type, primary-key position as an
      optional ordinal, not-null, default value, and whether the column is
      hidden/generated) — plus the two **pure parsers** that turn a
      `DatabaseResultSet` into `[DatabaseTableEntry]` and `[DatabaseColumn]`, each
      rejecting a result set whose shape it does not recognize with a typed error
      rather than guessing
- [ ] `DatabaseQuery.swift`: identifier quoting (double-quote wrapping with
      embedded quotes doubled — identifiers **cannot** be parameters, which is
      exactly why the quoting is one tested function), the table/view listing
      query, the column-schema pragma, the row-count query, and the page query
      with an optional `ORDER BY` on a quoted column plus `LIMIT`/`OFFSET`
      supplied as **bound values**
- [ ] Write tests: quoting a plain identifier, one containing a double quote, one
      containing a semicolon or a space; the listing parser on rows holding both a
      table and a view; the column parser on a composite primary key (ordinals
      preserved), a not-null column, a defaulted column and a generated column; a
      malformed result set producing the typed error; every built statement
      asserted byte-for-byte with its parameter list
- [ ] run `swift test` — must pass before Task 5

### Task 5: Pagination, sort state and the viewer model

**Files:**
- Create: `Sources/PisakaCore/DatabasePage.swift`,
  `Sources/PisakaCore/DatabaseViewerModel.swift`
- Create: `Tests/PisakaCoreTests/DatabasePageTests.swift`,
  `Tests/PisakaCoreTests/DatabaseViewerModelTests.swift`

- [ ] `DatabasePage.swift`: the page-size constant, the page index with its
      clamping, the offset math, `hasPrevious`/`hasNext`, the displayed row range,
      the total-count handling including the **not yet counted** state, and the
      degenerate cases (zero rows, a last page shorter than the page size, a count
      that shrank under a stale index). Alongside it `DatabaseSortState`: the
      column and direction, the toggle rule (a new column sorts ascending, the
      same column flips), and the rule that selecting a different table clears the
      sort
- [ ] `DatabaseViewerModel.swift` — a `@MainActor` `ObservableObject` over
      `DatabaseServicing`: `load()` (open the connection, list tables and views),
      `select(table:)` (schema plus first page), `goToPage`, `toggleSort(column:)`,
      and `close()`. **Every** async load captures its generation token
      synchronously before the `Task` hop and discards a superseded result instead
      of publishing over newer state — separate tokens for the table list and for
      the page/schema load, since they are independently re-triggerable. Every
      seam failure lands in a published error message; a failed load never blanks
      a good previous result silently
- [ ] Sorting and paging **re-query**: assert in tests that a page load asks for
      exactly one page-sized statement and never an unbounded select
- [ ] Write tests against `ScriptedDatabaseService`: the happy path (list → select
      → schema + first page); paging forward and back on a table larger than one
      page, asserting the bound `LIMIT`/`OFFSET` per request; a sort toggle
      re-queries with the new `ORDER BY` and resets to the first page; a superseded
      load discards its result (staged with `Gate`, asserted by polling for the
      sink's record, never by hop count); a file that is not a readable database
      lands in the error state rather than an empty table list; a seam failure
      mid-paging surfaces its message and leaves the previous page in place;
      `close()` closes the connection exactly once
- [ ] run `swift test` — must pass before Task 6

### Task 6: The macOS connection service, the tab owner and the viewer surface

**Files:**
- Create: `Sources/Pisaka/Platform/DatabaseConnectionService.swift`,
  `Sources/Pisaka/DatabaseViewerTabs.swift`,
  `Sources/Pisaka/DatabaseViewerView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`, `Sources/Pisaka/PisakaApp.swift`

- [ ] `DatabaseConnectionService` — an `actor` conforming to `DatabaseServicing`,
      entirely under `#if os(macOS)`, and the **only** file in the repository that
      imports the system SQLite module. One connection per instance, opened
      read-write with a busy timeout set immediately after open so a locked
      database reports rather than hangs; `run` prepares, binds each
      `DatabaseValue` through the typed bind calls, steps, and reads each column
      back by its storage class; every failure becomes a `DatabaseError` carrying
      the library's message verbatim; `close` finalizes and closes and is safe to
      call twice
- [ ] `DatabaseViewerTabs` — a `@MainActor final class ObservableObject` owning
      the per-tab viewer models keyed by tab id: create one lazily when a viewer
      tab is first selected, hand back the existing one on re-selection, and
      **close its connection when the tab closes** and at termination. This is a
      whole file of its own precisely so `PisakaApp` does not grow (decision 4).
      Its doc comment states the reader boundary: the viewer neither raises nor
      waits on the disk-writer gate — the terminal precedent
- [ ] `DatabaseViewerView` — the thin surface: a sidebar listing tables and views
      (distinguished), the selected table's schema, the paged grid with clickable
      sorting headers and paging controls, and a prominent error banner for the
      model's error state. All rendering decisions come from Core
      (`DatabaseValue.displayText`, `DatabasePage`, `DatabaseSortState`); the view
      holds no logic of its own. Font and metrics follow the existing
      interface-scale convention
- [ ] `ContentView.editorZone`: keep the breadcrumb for every tab, then route on
      the tab kind — a viewer tab renders `DatabaseViewerView` instead of the find
      bar, the consent banner and the code editor
- [ ] `PisakaApp`: **two edits only in this task** — construct the workspace with
      `viewerTabsEnabled: true` (the one site that turns decision 3 on), and hold
      the `DatabaseViewerTabs` owner as a `@StateObject` passed into the
      environment
- [ ] Write tests: this task's testable half is Core-side — extend
      `DatabaseViewerModelTests` with the lifecycle the app drives (create on first
      selection, close on tab close, a second selection of the same tab reusing
      the model), since the views themselves are untested by convention
- [ ] run `swift test` — must pass before Task 7

### Task 7: Every text-assuming consumer skips viewer tabs, the gating suite, and the lint ceilings

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Create: `Tests/PisakaCoreTests/DatabaseViewerSourceGatingTests.swift`
- Modify: `Tests/PisakaCoreTests/WorkspaceModelTests.swift`
- Modify (only if measured necessary): `.swiftlint.yml`,
  `Tests/PisakaCoreTests/LintConfigurationTests.swift`

- [ ] `openBuffers` (the closure feeding the symbol index and project search):
      skip viewer tabs — a viewer tab has no text, and contributing an empty
      buffer for a real path would make the index and Find in Files report the
      database as an empty file
- [ ] The ⌘S funnel `save(id:)`: a viewer tab returns early as a **no-op that
      reports success**, before the writer-gate check and before
      `saveTransform.prepareForSave` — nothing to save is not a failure
- [ ] The three buffer-snapshot maps (the rename pass, project Replace All, and
      the checkout snapshot): skip viewer tabs so no pass ever believes it vouched
      for a database's bytes
- [ ] `resyncOpenTabsAfterCheckout`: a viewer tab whose file is gone and whose
      caller `mayRemoveFiles` **force-closes**, exactly like a text tab on a
      deleted file (and its connection is closed with it); a viewer tab whose file
      is still there is left alone — no reload, no baseline reconcile, no beep
- [ ] Verify (and assert in the new suite) that the autosave scans, the on-save
      transform and Local History capture already exclude viewer tabs **because**
      they are gated on `isDirty`, which is `false` by construction — the
      invariant is the reason, so the suite pins it rather than adding a second
      filter
- [ ] Write `DatabaseViewerSourceGatingTests`, following
      `LocalHistorySourceGatingTests` (read through `#filePath`, comments and
      string literals stripped): the system SQLite module is imported in exactly
      one file; every app-side file of this feature is `#if os(macOS)`-gated; no
      file under `Sources/PisakaCore/` imports SQLite; **`viewerTabsEnabled` is
      spelled in exactly one app file and it is `Sources/Pisaka/PisakaApp.swift`,
      while `Sources/Pisaka/iOS/PisakaApp_iOS.swift` constructs its workspace
      without it** (decision 3); no file of this feature names
      `autosave.suspend()` or `localChanges.beginRevert()` (the reader rule); and
      the app sites that iterate `openFiles` for text pinned by count against the
      count of tab-kind filters, so a new text-shaped consumer fails here until it
      skips viewer tabs
- [ ] Write tests: the resync rules (deleted database force-closes, present
      database untouched) exercised at the Core level through `WorkspaceModel`
- [ ] Run `swiftlint --strict` and read what `PisakaApp.swift` now measures. If it
      crosses `file_length` or `type_body_length`, raise **both** configured
      ceilings to the measured numbers — never rounded up for room — extend the
      existing ceiling comment in `.swiftlint.yml` with this feature's reason in
      the same voice as the entries already there, and update both entries in
      `LintConfigurationTests.documentedRootThresholds`. If it does not cross,
      change neither file and say so
- [ ] Re-run any counting gating suite this task's edits touch
      (`LocalHistorySourceGatingTests` in particular) and update its documented
      counts rather than silencing it
- [ ] run `swift test` — must pass before Task 8

### Task 8: Verify acceptance criteria

- [ ] run `swift test` — the whole suite must be green
- [ ] run `swiftlint --strict` from the repository root — must be clean
- [ ] build macOS: `xcodegen generate` then
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`
- [ ] build iOS:
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
      — the feature is macOS-only, so this proves the gating
- [ ] confirm `git diff` touches neither `project.yml`'s dependencies,
      `Package.resolved`, nor `Resources/Licenses/`

### Task 9: Update documentation

**Files:**
- Create: `docs/architecture/core-database-viewer.md`
- Modify: `CLAUDE.md`, `README.md`, `docs/FEATURES.md`

- [ ] Write `docs/architecture/core-database-viewer.md` covering both halves: the
      recognition rule, the second tab kind and why the session record did not
      change, the probe-not-read open and the new `FileServiceError` case, **the
      platform switch and why iOS stays off** (decision 3, with the four iOS open
      sites named), the seam and what each side owns, the schema/value/query
      engines, the pagination and sort rules, the generation-token scheme, the
      app-side connection lifetime and busy timeout, why the tab owner is its own
      file, the reader boundary with the disk-writer gate, and an explicit **"what
      part 2 adds"** section so the follow-up ticket has its seat reserved
- [ ] Add one index line per new file to `CLAUDE.md` under a new
      `core-database-viewer.md` heading, plus a cross-cutting invariant paragraph:
      the viewer is a reader with a store of its own that is one file, never takes
      the writer gate, is never gated by it, its tabs are the one tab kind that
      can never be dirty, and the tab kind is off unless the macOS app turns it on
- [ ] Add the new gating suite to `CLAUDE.md`'s test-suite inventory, and — if
      Task 7 moved the ceilings — the `.swiftlint.yml` note in `style-lint.md`
- [ ] Add the user-facing feature line to `README.md` and its detail to
      `docs/FEATURES.md`, stating plainly that this version is read-only and
      macOS-only
- [ ] run `swift test` once more (the documentation suites read repository files)
      — must pass

## Post-Completion

- Manual check in a debug build: open a real database from the project tree, page
  through a table larger than one page, sort by a column, confirm NULL and the
  empty string render differently and a blob shows a placeholder, close the tab
  and reopen the project to confirm session restore brings the viewer tab back;
  point the viewer at a `.db` file that is not a database and confirm the error
  state.
- Write the part 2 ticket (inline cell editing, transactional write, SQL console)
  against the seam this part established; decide there whether iOS gets a surface
  and therefore the switch.
