# Git Log (history, branch graph, filters)

## Overview

A JetBrains-style read-only "Log" view: a full-width commit list with a colored
branch graph, ref decorations, and filters (branch/user/date/path) plus message
search. Selecting a commit shows its changed files and a side-by-side diff
(reusing `DiffView`). No history mutation.

Built in four usable stages: (1) commit list, (2) per-commit diff, (3) branch
graph, (4) filters/search. All git access and the heavy-but-pure graph/parse
logic live in `PisakaCore` (unit-tested); the table, graph rendering, filter bar,
and detail wiring are thin view-layer code. `Process` stays in `GitCLIService`.

## Context

- Files involved (Core):
  - Create: `Sources/PisakaCore/Commit.swift` (value type + `git log` parser)
  - Create: `Sources/PisakaCore/CommitGraphLayout.swift` (pure lane/edge layout)
  - Create: `Sources/PisakaCore/LogFilter.swift` (filter → git args + client-side search)
  - Create: `Sources/PisakaCore/CommitLogModel.swift` (`@MainActor ObservableObject`)
  - Modify: `Sources/PisakaCore/GitServicing.swift` (add `commits`, `commitChanges`, per-file commit-vs-parent contents)
- Files involved (view):
  - Create: `Sources/Pisaka/CommitLogView.swift` (full-width table + detail pane)
  - Create: `Sources/Pisaka/CommitGraphView.swift` (graph-gutter NSView)
  - Create: `Sources/Pisaka/LogFilterBar.swift` (filter bar + search field)
  - Modify: `Sources/Pisaka/GitCLIService.swift` (Process-backed `commits`/`commitChanges`)
  - Modify: `Sources/Pisaka/ContentView.swift` (top-level Log mode; full-width zone)
  - Modify: `Sources/Pisaka/PisakaApp.swift` (construct `CommitLogModel`; menu/mode wiring)
- Related patterns to follow:
  - `LocalChangesModel` — async git entry points, monotonic generation guard
    dropping stale results, pure static helpers for decision logic, error
    surfaced to `errorMessage`.
  - `GitStatusParser` — pure `static func parse(_:) -> [...]` over raw git
    output, unit-tested in Core.
  - `DiffPane` in `ContentView.swift` — caching async `rows(for:)` behind a
    `@State` generation token.
  - `GitCLIService.run(_:in:)` — serial-queue Process bridging; reading
    stdout/stderr before `waitUntilExit`.
  - `DiffView` / `LineDiff` — reused verbatim for the commit-vs-parent diff.
- Dependencies: none new. PisakaCore stays Foundation-only.

## Development Approach

- **Testing approach**: TDD for the pure Core pieces (parser, graph layout,
  filter→args, model logic); regular for the thin view layer.
- Complete each task fully (tests passing) before the next.
- **CRITICAL: every Core task ships new/updated `PisakaCoreTests`**; the view
  layer is thin and not unit-tested, per project convention.
- **CRITICAL: all tests must pass (`swift test`) before starting the next task.**
- Each stage is independently usable on its own.

## Implementation Steps

### Task 1: Commit value type + git log parser (PisakaCore)

**Files:**
- Create: `Sources/PisakaCore/Commit.swift`
- Create: `Tests/PisakaCoreTests/CommitParserTests.swift`

- [x] Define `public struct Commit: Identifiable, Equatable` — `hash`,
  `parents: [String]`, `author`, `date`, `subject`, `refs: [String]` (`id == hash`).
- [x] Choose a record/field separator scheme robust to spaces in subjects/refs
  (e.g. a `--pretty=format:` with NUL/`%x00` field separators and a record
  terminator), and document the exact format string the service will pass.
  (`Commit.prettyFormat = "%H%x00%P%x00%an%x00%aI%x00%s%x00%D%x1e"`: NUL field
  separators, RS `%x1e` record terminator.)
- [x] Implement a pure `static func parse(_ output: String) -> [Commit]` for that
  format: hash, parent hashes (space-split, possibly empty for root), author,
  date, subject, and `%D` ref decorations (split, stripping `HEAD -> `, tag
  prefixes, etc.).
- [x] Write tests: ordinary commit; merge (multiple parents); root commit (no
  parents); ref-decorated commit; subjects and refs containing spaces; empty
  output → `[]`.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: GitServicing.commits + GitCLIService + CommitLogModel (Stage 1 — usable list)

**Files:**
- Modify: `Sources/PisakaCore/GitServicing.swift`
- Create: `Sources/PisakaCore/CommitLogModel.swift`
- Modify: `Sources/Pisaka/GitCLIService.swift`
- Create: `Tests/PisakaCoreTests/CommitLogModelTests.swift`

- [x] Add to `GitServicing`: `func commits(filter: LogFilter, limit: Int, root: URL) async throws -> [Commit]`
  (`LogFilter` is introduced minimally here as an empty/default filter; full
  filtering lands in Task 6).
- [x] Implement `GitCLIService.commits` via `run(...)`: `git log --topo-order
  --parents --pretty=<format>` with the Task 1 format string, `--all` by default,
  `-n <limit>`; feed stdout to `Commit.parse`. Document first-parent / merge
  handling intent.
- [x] Create `CommitLogModel` (`@MainActor ObservableObject`) mirroring
  `LocalChangesModel`: inject `GitServicing`; publish `commits`, `selected`,
  `errorMessage`, `root`, `isLoading`; `refresh(root:limit:) async` resolves repo
  root, fetches off-main, publishes on success, sets `errorMessage` on failure;
  monotonic generation guard discards superseded fetches; pure static helper for
  state reconciliation.
- [x] Tests with a stub `GitServicing`: fetch populates `commits`; error surfaces
  to `errorMessage`; generation guard drops a stale fetch; selection
  reconciles/clears across refresh.
- [x] Run `swift test` — must pass before Task 3.

### Task 3: Log view mode + full-width commit table (view layer)

**Files:**
- Create: `Sources/Pisaka/CommitLogView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] Add a top-level mode that swaps the editor area for a full-width Log view
  (a window-level toggle / menu command so the graph gets full width; must not
  regress the existing Project ⇄ Changes left-panel toggle or the Local Changes
  diff area). (`WorkspaceMode` binding owned by `PisakaApp`, flipped by a "View"
  menu command — Cmd+Shift+L; `ContentView` renders `CommitLogView` full-width in
  `.log`, the existing `editorSplit` otherwise.)
- [x] Build `CommitLogView`: a full-width table/list of commits (short hash,
  subject, author, date, ref badges), wired to `CommitLogModel`, with row
  selection setting `model.selected`. Include a "Load more" affordance that
  re-fetches with a larger `limit` (no infinite paging). (Shown only when the last
  fetch filled the limit; bumps the limit and re-fetches the whole list.)
- [x] Construct the shared `CommitLogModel` (real `GitCLIService`) in `PisakaApp`;
  refresh it on folder open (synchronous switch-prep where applicable,
  `Task`-wrapped async refresh), reusing the generation-pinning pattern. (Model's
  own monotonic refresh generation guard handles ordering, so no switch-prep is
  needed; the view's `onAppear`/`onChange(projectRoot)` are idempotent backstops.)
- [x] `swift build` succeeds; existing `swift test` still passes (414 tests, no
  Core regressions).

### Task 4: Commit selection → changed files + side-by-side diff (Stage 2)

**Files:**
- Modify: `Sources/PisakaCore/GitServicing.swift`
- Modify: `Sources/Pisaka/GitCLIService.swift`
- Modify: `Sources/PisakaCore/CommitLogModel.swift`
- Modify: `Sources/Pisaka/CommitLogView.swift`
- Modify: `Tests/PisakaCoreTests/CommitLogModelTests.swift`

- [x] Add `func commitChanges(hash: String, root: URL) async throws -> [ChangedFile]`
  to `GitServicing`; implement in `GitCLIService` via `git diff-tree` / `git show
  --name-status` against the first parent (document merge-commit = first-parent
  diff, not combined). (`git diff-tree --no-commit-id --name-status -r -M
  --first-parent --root <hash>`, parsed by the new pure
  `CommitChangesParser` in Core; `--first-parent` documents merge = mainline diff,
  `--root` diffs a root commit against the empty tree.)
- [x] Add commit-vs-parent per-file contents accessors so the model can build
  `DiffRow`s via the existing `LineDiff` (old = file at first parent, new = file
  at the commit; empty side for add/delete), e.g. `rows(for:in:) async ->
  [DiffRow]` on `CommitLogModel` mirroring `LocalChangesModel.rows(for:)`.
  (`GitServicing.fileContents(at:path:root:)` via `git show <rev>:<path>`;
  `CommitLogModel.rows(for:in:)` reads old from `commit.parents.first` and new from
  `commit.hash`, plus `changes(for:)` for the file list. Both Log-only methods are
  defaulted in a `GitServicing` extension so non-Log stubs keep compiling.)
- [x] Build the commit-detail pane in `CommitLogView`: changed-files list + reuse
  `DiffView` (cache rows behind a `@State` generation token, like `DiffPane`).
  (`CommitDetailPane` = `VSplitView` of a changed-files list (`CommitFileRow`) over
  `CommitDiffPane`, opened beside the commit list in an `HSplitView` on selection;
  both detail loads are generation-guarded.)
- [x] Tests with stub: `commitChanges` maps to `[ChangedFile]`; rows build
  correctly for add/delete/modify; stale-generation guard on row recompute.
  (`CommitChangesParserTests` covers M/A/D/T/rename/copy/spaces/CRLF/malformed;
  `CommitLogModelTests` adds `changes`/`rows` coverage for modify/add/delete/rename/
  root/pre-refresh and error-swallowing. View-layer generation guard is thin glue,
  untested per project convention.)
- [x] Run `swift test` — must pass before Task 5. (431 tests, 0 failures.)

### Task 5: CommitGraphLayout + graph-gutter NSView (Stage 3)

**Files:**
- Create: `Sources/PisakaCore/CommitGraphLayout.swift`
- Create: `Tests/PisakaCoreTests/CommitGraphLayoutTests.swift`
- Create: `Sources/Pisaka/CommitGraphView.swift`
- Modify: `Sources/Pisaka/CommitLogView.swift`

- [x] Implement pure `CommitGraphLayout`: given topologically ordered `[Commit]`
  with parent hashes, assign each commit a lane (column) and compute each row's
  edge segments (incoming/outgoing/pass-through) plus a stable lane color index.
  Foundation-only, no AppKit. (`CommitGraphLayout.layout(_:) -> CommitGraph`;
  `CommitGraphRow` = node `column`/`colorIndex` + outgoing `edges`; `GraphEdge` =
  `fromColumn`/`toColumn`/`colorIndex`. Lanes "seek" a parent hash; first parent
  continues the node's lane keeping its color, extra parents open fresh-colored
  lanes, merges reuse an existing seeking lane, freed slots are reused to stay
  narrow.)
- [x] Tests: linear history (single lane); branch-then-merge (a lane opens then
  closes); parallel branches (distinct lanes); octopus merge (3+ parents);
  lane-color stability across rows; empty input. (`CommitGraphLayoutTests`, 8
  cases incl. root-commit and freed-slot-reuse.)
- [x] Build `CommitGraphView` (an `NSView`, color-free layout consumed at draw
  time like the minimap): draw nodes + colored edges aligned to each table row;
  resolve lane colors in the view layer. (`CommitGraphView` `NSViewRepresentable`
  + `CommitGraphRowNSView`: one fixed-height cell per row, top-half from the
  previous row's edges + bottom-half from this row's, node dot on top; a fixed
  `NSColor` palette resolved at draw time so it follows the appearance.)
- [x] Integrate the graph gutter alongside the commit rows in `CommitLogView`
  (rows align with the graph; document/row metrics consistent). (`CommitLogView`
  lays the graph out once and threads each row + the previous row's edges into
  `CommitRow`'s leading graph cell; fixed `rowHeight` keeps cells aligned with
  the text columns.)
- [x] Run `swift test` — must pass before Task 6. (439 tests, 0 failures.)

### Task 6: LogFilter → args + message search + filter bar (Stage 4)

**Files:**
- Modify: `Sources/PisakaCore/LogFilter.swift`
- Modify: `Sources/PisakaCore/CommitLogModel.swift`
- Create: `Sources/Pisaka/LogFilterBar.swift`
- Modify: `Sources/Pisaka/CommitLogView.swift`
- Create: `Tests/PisakaCoreTests/LogFilterTests.swift` (+ extend model tests)

- [x] Flesh out `LogFilter` (branch/ref selection incl. "All" → `--all`,
  author/user, date range, path) with a pure `gitArguments() -> [String]`
  builder, plus a pure client-side message-search predicate over loaded commits.
  (`LogFilter.RefSelection` `.all`/`.ref`; `author`/`since`/`until`/`path` fields;
  `gitArguments()` orders ref-scope + options then a `--`-separated pathspec, blank
  author/path trimmed away, dates as UTC ISO-8601; `LogFilter.search(_:query:)`
  matches subjects case-insensitively, blank query = pass-through. Search is *not* a
  `LogFilter` field so a search change never re-fetches.)
- [x] Wire `CommitLogModel`: a filter change rebuilds args and re-fetches off-main
  (generation-guarded); search filters the published commits client-side without
  re-fetching. (`applyFilter(_:root:limit:)` no-ops on an unchanged filter else
  stores it and re-`refresh`es through the same generation guard; `setSearchQuery`
  + computed `visibleCommits` filter the loaded `commits` with no git call;
  `references` listed best-effort in `refresh` for the picker.)
- [x] Tests: `LogFilter → args` for each dimension and combinations ("All" vs a
  chosen ref, author, date range, path); client-side search matches subjects
  (case-insensitive); model re-fetches on filter change and surfaces errors.
  (`LogFilterTests` 19 cases; `CommitLogModelTests` adds applyFilter
  refetch/no-op/error, client-side search-without-refetch, and references loading.)
- [x] Build `LogFilterBar` (branch picker, user/date/path controls, search field)
  above the commit table; available branches/refs sourced via the service.
  (`LogFilterBar` seeds local state from `model.filter`/`searchQuery`, applies
  server dimensions via `onApplyFilter` and the message box live via `onSearch`;
  `GitServicing.references(root:)` (defaulted to `[]`) implemented in
  `GitCLIService` via `git for-each-ref` — local branches, remotes, then tags.)
- [x] Run `swift test` — must pass before Task 7. (462 tests, 0 failures.)

### Task 7: Verify acceptance criteria

- [x] Run full test suite: `swift test` — all green. (462 tests, 0 failures.)
- [x] Run `swift build` — clean compile of both targets. (Build complete.)
- [x] Confirm PisakaCore stays Foundation-only (no Neon/SwiftTreeSitter/AppKit
  imports in Core or tests). (grep over Sources/PisakaCore + Tests: no
  Neon/SwiftTreeSitter/AppKit/SwiftUI/Cocoa imports.)
- [x] Verify the four stages each function and the Project ⇄ Changes toggle and
  Local Changes diff are unregressed. (Automatable portion verified: full Core
  suite green covers all four stages' logic and the clean view-layer build leaves
  the existing toggles/diff paths intact; interactive UI walkthrough is manual —
  not automatable here.)

### Task 8: Update documentation

- [x] Update `CLAUDE.md`: document `Commit` + the log parser, `CommitGraphLayout`,
  `LogFilter`, `CommitLogModel`, and the new `GitServicing`/`GitCLIService`
  methods under the PisakaCore/view sections; note the Log mode, graph `NSView`,
  filter bar, and commit-detail reuse of `DiffView`. (Added `Commit`,
  `CommitChangesParser`, `CommitGraphLayout`, `LogFilter`, `CommitLogModel` to the
  PisakaCore section; extended the `GitServicing`/`GitCLIService` entries with the
  four Log methods; added `CommitLogView`/`CommitGraphView`/`LogFilterBar` and the
  `WorkspaceMode`/View-menu wiring to the view section.)
- [x] Update `README.md`: add the Log view (commit history, branch graph,
  filters/search, per-commit diff) to the feature list. (Added a Log feature bullet
  and the Cmd+Shift+L shortcut.)
