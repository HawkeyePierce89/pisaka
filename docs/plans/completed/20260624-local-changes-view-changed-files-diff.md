# Local Changes (view changed files + side-by-side diff)

## Overview

A JetBrains-style "Local Changes" view: list files differing from `HEAD`, group
them flat or by folder, and view a side-by-side diff (working copy vs `HEAD`) of
any file. A "Project ⇄ Changes" toggle in the left panel swaps the project tree
for the changes list. No commit, staging, changelists, history, or filesystem
watching. Built across all 5 increments, with the risky `DiffView` rendering last
and staged into sub-steps.

Domain logic and parsing live in `PisakaCore` (pure, Foundation-only, fully
unit-tested); `Process`/AppKit/SwiftUI stay in the thin `Pisaka` view layer behind
the `GitServicing` protocol so a future iOS swap is cheap.

## Context

- Files involved (Core, new): `Sources/PisakaCore/GitServicing.swift`,
  `ChangedFile.swift`, `GitStatusParser.swift`, `LineDiff.swift`,
  `ChangeTree.swift`, `LocalChangesModel.swift`
- Files involved (Pisaka, new): `Sources/Pisaka/GitCLIService.swift`,
  `LocalChangesView.swift`, `DiffView.swift`
- Files involved (Pisaka, modified): `ContentView.swift` (left-panel mode toggle),
  `PisakaApp.swift` (refresh-on-save wiring)
- Tests (new): `Tests/PisakaCoreTests/GitStatusParserTests.swift`,
  `LineDiffTests.swift`, `ChangeTreeTests.swift`, `LocalChangesModelTests.swift`
- Related patterns to follow:
  - `WorkspaceModel.swift` / `FileService.swift` — `ObservableObject` model +
    protocol-behind-injectable-stub split
  - `FileIcon.swift` / `SyntaxTokenKind.swift` — pure semantic enums, color-free
    in Core
  - `LineNumberRulerView.swift`, `MinimapView.swift`, `CodeEditorView.swift` —
    gutter, synced-scroll, and Neon highlighting to reuse in `DiffView`
  - `MinimapModelTests.swift` / `LineStartIndexTests.swift` — captured-sample /
    fuzz test style
- Dependencies: no new external packages. `git` CLI invoked via `Process`
  (macOS), Neon reused for diff-pane highlighting.

## Development Approach

- **Testing approach**: TDD for all `PisakaCore` tasks (parser, `LineDiff`,
  `ChangeTree`, `LocalChangesModel`) — write the captured-sample/edge-case tests
  first, then implement. View-layer tasks (`GitCLIService`, `LocalChangesView`,
  `DiffView`, the toggle) are intentionally thin and not unit-tested per project
  convention; their gate is `swift build` succeeding and the full `swift test`
  suite still passing.
- Complete each task fully before the next; tasks are ordered so each builds on
  the last (the 5 increments).
- **CRITICAL: every Core task includes new/updated tests.**
- **CRITICAL: `swift test` must pass before starting the next task.**
- Keep all domain logic in `PisakaCore`; keep `Pisaka` views thin. `PisakaCore`
  must not import Neon/SwiftTreeSitter/AppKit/`Process`.

## Implementation Steps

### Task 1: Git models + `--porcelain=v2` status parser (Core, increment 1)

**Files:**
- Create: `Sources/PisakaCore/GitServicing.swift` (protocol `GitServicing`;
  `changedFiles(root:)`, `headContents(of:root:)`)
- Create: `Sources/PisakaCore/ChangedFile.swift` (`FileStatus` enum, `ChangedFile`
  struct)
- Create: `Sources/PisakaCore/GitStatusParser.swift` (pure
  `static func parse(_ output: String) -> [ChangedFile]`)
- Create: `Tests/PisakaCoreTests/GitStatusParserTests.swift`

- [x] Define `FileStatus` (`modified, added, deleted, renamed, untracked`) and
  `ChangedFile` (`path`, `status`, `oldPath`, `id`) per spec
- [x] Define the `GitServicing` protocol (no `Process` — declaration only, lives
  in Core)
- [x] Write `GitStatusParserTests` first: captured `--porcelain=v2` samples
  covering modified `1`, added, deleted, renamed `2` (old+new path), untracked
  `?`, paths with spaces, and unicode; assert resulting `[ChangedFile]`
- [x] Implement `GitStatusParser.parse` over the porcelain v2 grammar (`1`/`2`/`?`
  record types), mapping XY codes to `FileStatus` and extracting rename old/new
  paths
- [x] run `swift test` - must pass before Task 2

### Task 2: `GitCLIService` — Process-backed git layer (Pisaka, increment 1)

**Files:**
- Create: `Sources/Pisaka/GitCLIService.swift` (`GitCLIService: GitServicing`)

- [x] Implement `changedFiles(root:)` by running `git status --porcelain=v2
  -uall` via `Process` in `root` and feeding stdout to `GitStatusParser.parse`
- [x] Implement `headContents(of:root:)` via `git show HEAD:<path>`, returning
  `nil` for a new/untracked file (non-zero exit / missing object) rather than
  throwing
- [x] Handle non-repo / git-missing by throwing a typed error the model can
  surface; consider `-z` NUL-delimited output if quoting proves fragile (note in
  code)
- [x] run `swift build` and `swift test` (suite must still pass)

### Task 3: `LineDiff` — Myers/LCS side-by-side row diff (Core, increment 4)

**Files:**
- Create: `Sources/PisakaCore/LineDiff.swift` (`DiffRowKind`, `DiffLine`,
  `DiffRow`, `enum LineDiff { static func rows(old:new:) }`)
- Create: `Tests/PisakaCoreTests/LineDiffTests.swift`

- [x] Write `LineDiffTests` first: add-only, remove-only, modified, mixed hunks,
  empty old, empty new, identical files (no changed rows); assert filler/alignment
  invariant (a `nil` side always pairs a real line on the other; `added`→
  `left==nil`, `removed`→`right==nil`, `modified`/`unchanged`→both present);
  assert 1-based line numbers per side
- [x] Implement `LineDiff.rows` via an LCS/Myers line diff producing aligned
  `[DiffRow]`, splitting lines through Core's existing `LineStartIndex` semantics
  for separator consistency
- [x] (Optional refinement) word-level changed ranges on `.modified` rows, with a
  focused test if included — deferred to DiffView Task 7 sub-step C (polish)
- [x] run `swift test` - must pass before Task 4

### Task 4: `ChangeTree` — folder grouping (Core, increment 3)

**Files:**
- Create: `Sources/PisakaCore/ChangeTree.swift` (`ChangeTree.build(from:
  [ChangedFile], root: URL)`)
- Create: `Tests/PisakaCoreTests/ChangeTreeTests.swift`

- [x] Write `ChangeTreeTests` first: single-level nesting, deep nesting, multiple
  files per directory, directories-first/case-insensitive ordering (mirroring
  `DirectoryEntry` sort), flat-fallback for root-level files
- [x] Implement the pure directory-tree grouping over repo-relative paths
- [x] run `swift test` - must pass before Task 5

### Task 5: `LocalChangesModel` — observable model (Core, increment 2)

**Files:**
- Create: `Sources/PisakaCore/LocalChangesModel.swift` (`ObservableObject`:
  `changedFiles`, `groupingMode` flat/byFolder, `selected`, `refresh(root:)`, diff
  rows for selection)
- Create: `Tests/PisakaCoreTests/LocalChangesModelTests.swift`

- [x] Write `LocalChangesModelTests` first with a stub `GitServicing`: `refresh`
  populates `changedFiles`; selection changes; `rows(for:)` builds via `LineDiff`
  from stub `headContents` + working text; a git-service error is
  surfaced/handled (state cleared, no crash)
- [x] Implement `LocalChangesModel` injecting `GitServicing` (default to a real
  service in Pisaka, stub in tests, like `WorkspaceModel`/`FileService`); expose
  grouping mode and the rows for the selected file
- [x] run `swift test` - must pass before Task 6

### Task 6: Left-panel mode toggle + `LocalChangesView` flat/tree list (Pisaka, increments 2–3)

**Files:**
- Modify: `Sources/Pisaka/ContentView.swift` (segmented "Project ⇄ Changes" toggle
  at top of left zone; show `ProjectTreeView` or `LocalChangesView`)
- Create: `Sources/Pisaka/LocalChangesView.swift` (flat list or directory tree per
  `groupingMode`, status icons via `FileIcon` + a `FileStatus` color, flat/tree
  toggle, manual refresh button)
- Modify: `Sources/Pisaka/PisakaApp.swift` (construct `LocalChangesModel`;
  auto-refresh on `markSaved`)

- [x] Add the left-panel mode segmented control selecting Project vs Changes (same
  wiring shape as `onOpenFolder`)
- [x] Build `LocalChangesView`: flat list and by-folder tree (`ChangeTree`),
  status icon + color, manual refresh button calling `model.refresh(projectRoot)`;
  clicking a row sets `selected`
- [x] Wire auto-refresh on file save (`markSaved`) — no filesystem watching
- [x] run `swift build` and `swift test` (suite must still pass)

### Task 7: `DiffView` side-by-side rendering (Pisaka, increment 5)

**Files:**
- Create: `Sources/Pisaka/DiffView.swift` (`NSViewRepresentable` — two
  `NSTextView`s, synced scroll, per-row backgrounds, fillers, gutter/change
  markers; word-diff + connectors as final polish)

- [x] Sub-step A: two `NSTextView` panes side by side rendering `[DiffRow]`,
  per-row background by `DiffRowKind`, filler blocks for `nil` sides (alignment),
  synced vertical scroll (reuse minimap synced-scroll approach)
- [x] Sub-step B: per-pane line-number gutter (reuse `LineNumberRulerView`
  approach) and change markers; Neon syntax highlighting on both panes (reuse
  `CodeEditorView`/`SyntaxLanguageConfiguration`)
- [x] Sub-step C (polish): word-level intra-line highlight on `.modified` rows and
  the connecting zig-zag between panes, if `LineDiff` exposes word ranges —
  N/A: `LineDiff` does not expose word ranges (the optional word-level refinement
  was deferred in Task 3), so there is nothing to render here. Whole-line
  red/green row backgrounds + change markers cover the `.modified` case.
- [x] Present `DiffView` when a changed file is selected in `LocalChangesView`
- [x] run `swift build` and `swift test` (suite must still pass)

### Task 8: Verify acceptance criteria

- [x] run full suite: `swift test` (188 tests, 0 failures)
- [x] run `swift build` and confirm a clean build (the project has no separate
  linter)
- [x] confirm `PisakaCore` still imports only Foundation (no
  Neon/SwiftTreeSitter/AppKit/`Process`) — only Foundation + pre-existing
  CoreGraphics (MinimapGeometry), both Apple SDK
- [x] verify new Core types have ≥80% test coverage (parser, `LineDiff`,
  `ChangeTree`, `LocalChangesModel`) — region/line coverage: GitStatusParser
  81.25%/100%, LineDiff 96.23%/99.36%, ChangeTree 96%/100%, LocalChangesModel
  97.22%/98.51%

### Task 9: Update documentation

- [x] Update `CLAUDE.md`: document new `PisakaCore` types (`GitServicing`,
  `ChangedFile`/`FileStatus`, `GitStatusParser`, `LineDiff`/`DiffRow`,
  `ChangeTree`, `LocalChangesModel`) and new view files (`GitCLIService`,
  `LocalChangesView`, `DiffView`, left-panel mode toggle)
- [x] Update `README.md`: add Local Changes (view changed files, group by folder,
  side-by-side diff) to the feature list

## Post-Completion (manual verification)

- Launch `swift run Pisaka`, open a git repo folder, toggle to Changes, confirm
  the changed-file list matches `git status`, switch flat/tree grouping, click a
  modified file and confirm the side-by-side diff aligns correctly, edit+save a
  file and confirm the list auto-refreshes.
