# Git conflict resolution (3-pane merge)

## Overview

Add a JetBrains-style conflict resolver to Pisaka. Detect files in a merge-conflict
state, open a 3-pane merge editor (ours | result | theirs) sourced from git's stage
blobs (`:1` base, `:2` ours, `:3` theirs), let each conflict hunk be resolved
(accept ours / theirs / both, or edit the result), and on apply write the resolved
text to the working file and `git add` it. Non-binary text files only.

The testable bulk — a pure diff3 three-way merge — lives in `PisakaCore`. The
3-pane editor is a heavy but logic-free view layer, reusing the existing separate
diff-window mechanism. `Process` stays in `GitCLIService`.

## Context

- Files involved (Core, create): `ThreeWayMerge.swift`, `MergeRegion.swift`
  (with `ConflictHunk`), `MergeDocument.swift`, `MergeModel.swift`.
- Files involved (Core, modify): `ChangedFile.swift` (add `FileStatus.conflicted`),
  `GitStatusParser.swift` (parse porcelain-v2 `u` unmerged records),
  `GitServicing.swift` (add `blob(stage:path:root:)` and `stage(path:root:)`).
- Files involved (view, create): `MergeView.swift` (3-pane editor),
  `MergeWindowController.swift` or reuse of `DiffWindowController` mechanism.
- Files involved (view, modify): `GitCLIService.swift` (implement blob/stage),
  `LocalChangesView.swift` (conflicted badge + "Resolve" entry / double-click),
  `LocalChangesModel.swift` (only if a passthrough for the conflicted set is
  needed; conflicted files already flow through `changedFiles`),
  `PisakaApp.swift` + `ContentView.swift` (thread the open-merge callback and own
  a merge-window controller, mirroring `onOpenDiff`/`DiffWindowController`).
- Related patterns to follow: `LineDiff` (LCS line diff + `splitLines` separator
  semantics — the diff3 is built from two `LineDiff` passes), `GitStatusParser`
  (field-split + unsplit-remainder path), `headContents`/`fileContents`
  (`git show` → `nil` on non-zero exit), `LocalChangesModel` (`@MainActor`
  ObservableObject injecting `GitServicing` + `FileServicing`, tested with stubs),
  `DiffWindowController` + `DiffWindowContent` (separate non-modal window,
  release-on-close), `DiffView` (side-by-side TextKit-1 panes, synced scroll,
  per-row highlighting).
- Dependencies: none new. Core stays Foundation-only; view layer reuses Neon/AppKit.

## Development Approach

- Testing approach: TDD for all `PisakaCore` work (the merge logic is the core
  risk — write the diff3 / MergeDocument / parser / MergeModel tests first).
- The view layer (Tasks 5–6) is thin and intentionally not unit-tested, per project
  convention — those tasks verify via `swift build` and the full suite still passing.
- Complete each task fully (build + full suite green) before the next.
- CRITICAL: every code-modifying Core task includes new/updated tests.
- CRITICAL: all tests pass before starting the next task.
- Represent missing-base (add/add) and one-empty-side (modify/delete) conflicts as
  a conflict whose corresponding span is empty — handle, don't special-case away.
- Be explicit about trailing-newline / no-newline-at-EOF in `resolvedText` so apply
  reproduces the resolved bytes faithfully.

## Implementation Steps

### Task 1: Conflict detection (FileStatus + parser)

**Files:**
- Modify: `Sources/PisakaCore/ChangedFile.swift`
- Modify: `Sources/PisakaCore/GitStatusParser.swift`
- Modify: `Tests/PisakaCoreTests/GitStatusParserTests.swift`

- [x] Add `case conflicted` to `FileStatus`.
- [x] Extend `GitStatusParser` to handle the porcelain-v2 unmerged record:
      `u <xy> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>` — 10 fixed fields
      before the path, mapped to `ChangedFile(path:, status: .conflicted)`; path is
      the unsplit remainder (spaces survive), short/malformed lines skipped.
- [x] Write tests: a `u` record → `.conflicted`; a `u` record with a spaced path;
      a `u` record interleaved with `1`/`?` records; a malformed/short `u` line
      skipped.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: ThreeWayMerge + MergeRegion/ConflictHunk

**Files:**
- Create: `Sources/PisakaCore/MergeRegion.swift` (`MergeRegion`, `ConflictHunk`)
- Create: `Sources/PisakaCore/ThreeWayMerge.swift`
- Create: `Tests/PisakaCoreTests/ThreeWayMergeTests.swift`

- [x] Define `ConflictHunk` (Equatable): the `base`, `ours`, `theirs` line spans
      (each as `[String]` logical lines, an empty array for a missing/empty side).
- [x] Define `MergeRegion` (Equatable): `.stable([String])` (identical, or changed
      by only one side → auto-merged) and `.conflict(ConflictHunk)`.
- [x] Implement `ThreeWayMerge.regions(base:ours:theirs:) -> [MergeRegion]`: split
      all three via the same separator semantics as `LineDiff.splitLines`; build a
      base→ours and a base→theirs `LineDiff`; walk both alignments together,
      emitting stable regions where both sides agree (or only one side changed) and
      `.conflict` regions only where both sides changed the same base span
      differently. Coalesce adjacent stable lines.
- [x] Write tests (write first, TDD): no change; ours-only change (auto-merged, no
      conflict); theirs-only change (auto-merged); both change the same region
      (conflict); add/add with empty base; modify/delete (one side empty span);
      multiple conflict hunks interleaved with stable regions; trailing-newline
      preservation.
- [x] Run `swift test` — must pass before Task 3.

### Task 3: MergeDocument + Resolution

**Files:**
- Create: `Sources/PisakaCore/MergeDocument.swift` (`MergeDocument`, `Resolution`)
- Create: `Tests/PisakaCoreTests/MergeDocumentTests.swift`

- [x] Define `Resolution` (Equatable): `.unresolved`, `.ours`, `.theirs`,
      `.bothOursFirst`, `.bothTheirsFirst`, `.custom(String)`.
- [x] Define `MergeDocument`: the ordered `[MergeRegion]` plus a per-conflict
      `Resolution`; build it from regions (each conflict starts `.unresolved`).
- [x] Implement `resolvedText` (stable regions verbatim + each conflict's chosen
      content, with `bothOursFirst`/`bothTheirsFirst` concatenation order and
      faithful line-join / trailing-newline handling), `unresolvedCount`,
      `isFullyResolved`, and a setter that updates a conflict's resolution.
- [x] Write tests (TDD): `resolvedText` for each `Resolution`; partial vs full
      resolution (`unresolvedCount`/`isFullyResolved`); `bothOursFirst` vs
      `bothTheirsFirst` ordering; `.custom` text; a document with multiple
      conflicts resolved independently.
- [x] Run `swift test` — must pass before Task 4.

### Task 4: GitServicing blob/stage + GitCLIService impl + MergeModel

**Files:**
- Modify: `Sources/PisakaCore/GitServicing.swift`
- Create: `Sources/PisakaCore/MergeModel.swift`
- Modify: `Sources/Pisaka/GitCLIService.swift`
- Create: `Tests/PisakaCoreTests/MergeModelTests.swift`

- [x] Add to `GitServicing`: `blob(stage:path:root:) async throws -> String?`
      (a missing stage — add/add with no base, modify/delete — returns `nil`) and
      `stage(path:root:) async throws`. Default both in the protocol extension
      (`nil` / no-op) so existing stubs keep compiling.
- [x] Implement them in `GitCLIService`: `blob` runs `git show :<N>:<path>`
      (non-zero exit → `nil`, mirroring `headContents`); `stage` runs
      `git add -- <path>` (non-zero exit → thrown `GitError`).
- [x] Implement `MergeModel: @MainActor ObservableObject` (Core), injecting
      `GitServicing` + `FileServicing`: `load(file:root:)` reads the `:1`/`:2`/`:3`
      blobs off-main and builds a `MergeDocument` via `ThreeWayMerge`; publishes the
      document, accept actions (set a conflict's resolution), `isFullyResolved`, and
      `errorMessage`; `apply()` refuses while unresolved, else writes `resolvedText`
      to the working file (`FileServicing.write`) and stages it (`GitServicing.stage`),
      surfacing a write/stage failure without a half-applied claim.
- [x] Write tests (TDD) with stub services: `load` builds the document from stub
      blobs (including a missing-stage/`nil` base); accept actions update the
      document and `isFullyResolved`; `apply` writes `resolvedText` and stages the
      path on full resolution; `apply` is refused / does not write or stage while
      unresolved; a stub write/stage failure surfaces an error.
- [x] Run `swift test` — must pass before Task 5.

### Task 5: 3-pane MergeView + merge window

**Files:**
- Create: `Sources/Pisaka/MergeView.swift`
- Create: `Sources/Pisaka/MergeWindowController.swift` (or extend `DiffWindowController`)
- Modify: `Sources/Pisaka/ContentView.swift`, `Sources/Pisaka/PisakaApp.swift`

- [x] Build `MergeView` as a 3-pane editor: `ours | result(editable) | theirs`,
      TextKit-1 panes like `DiffView`, with conflict-hunk highlighting, per-hunk
      accept buttons (◀ ours / ▶ theirs / both ordering toggle), prev/next conflict
      navigation, and synced vertical scrolling across the three panes. The middle
      pane edits feed back into the `MergeModel` document (`.custom`).
- [x] Add a merge window owner mirroring `DiffWindowController` (fresh non-modal
      `NSWindow`, release-on-close, `closeAll()` on `willTerminateNotification`).
- [x] Thread an `onResolveConflict(ChangedFile)` callback `PisakaApp → ContentView`
      and an "Apply" affordance enabled only when `isFullyResolved`.
- [x] View layer — no unit tests per project convention.
- [x] Run `swift build` and `swift test` — full suite must pass before Task 6.

### Task 6: Apply + Local Changes entry point

**Files:**
- Modify: `Sources/Pisaka/LocalChangesView.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`, `Sources/Pisaka/ContentView.swift`

- [x] Surface conflicted files in Local Changes: a one-letter badge / status color
      for `.conflicted` (e.g. "C") in `ChangedFileRow`, and a "Resolve" context-menu
      item + double-click that opens the merge window via the threaded callback.
- [x] Wire Apply end-to-end: on `MergeModel.apply()` success, close the merge
      window and refresh Local Changes (reuse the existing generation-pinned
      `refreshLocalChanges`); surface a failure via the existing alert/beep path.
- [x] View layer — no unit tests per project convention.
- [x] Run `swift build` and `swift test` — full suite must pass before Task 7.

### Task 7: Verify acceptance criteria

- [x] Run `swift test` (full suite) — all green. (547 tests, 0 failures)
- [x] Run `swift build` — clean.
- [x] Confirm new `PisakaCore` tests cover ThreeWayMerge / MergeDocument / parser /
      MergeModel including add/add, modify/delete, multi-hunk, and apply-while-
      unresolved refusal. (ThreeWayMergeTests: AddAddWithEmptyBase, ModifyDelete,
      MultipleConflictsInterleaved; MergeModelTests: MissingBaseStage,
      ApplyRefusedWhileUnresolved)

### Task 8: Update documentation

- [x] `README.md`: add conflict resolution to the feature list (detect conflicts,
      3-pane merge editor, accept ours/theirs/both or edit, apply + stage).
- [x] `CLAUDE.md`: document `FileStatus.conflicted` + the `GitStatusParser` `u`
      record; `ThreeWayMerge` / `MergeRegion` / `ConflictHunk` / `MergeDocument` /
      `MergeModel`; the `GitServicing` `blob`/`stage` methods and their
      `GitCLIService` impls; and the merge window / 3-pane `MergeView` / Local
      Changes "Resolve" entry in the view layer.

## Post-Completion

- [ ] Manually verify the merge editor against a real conflicted repository: create
      a merge conflict, open Local Changes, resolve via accept ours/theirs/both and
      via editing the result, then Apply and confirm the file is written + staged.
