# Local Changes: async git + human-readable errors

## Overview

Two related fixes for the Local Changes panel:

1. Move all `git` CLI work (refresh, revert, diff) off the main thread so a large
   repository no longer freezes the UI. Approach: make `GitServicing` async,
   `LocalChangesModel` `@MainActor` with `async` methods, and bridge the blocking
   `Process` call to async on a dedicated serial queue inside `GitCLIService`. The
   branch-heavy revert/refresh decision logic is extracted into pure synchronous
   helpers first, so it stays under synchronous unit tests while only the
   sequencing/IO becomes async.
2. Make `GitError` human-readable: move it to `PisakaCore`, keep its
   `LocalizedError` conformance, and unit-test `errorDescription`. The model
   already sets `errorMessage = error.localizedDescription`, so moving the error
   to Core makes that message testable and meaningful.

## Context

- Files involved:
  - Create: `Sources/PisakaCore/GitError.swift`
  - Modify: `Sources/PisakaCore/GitServicing.swift` (async protocol)
  - Modify: `Sources/PisakaCore/LocalChangesModel.swift` (`@MainActor`, async
    `refresh`/`revert`/`rows`/`selectedRows`, pure decision helpers, stale-refresh
    generation guard)
  - Modify: `Sources/Pisaka/GitCLIService.swift` (drop the local `GitError`; bridge
    `Process` to async on a dedicated serial `DispatchQueue` via
    `withCheckedThrowingContinuation`)
  - Modify: `Sources/Pisaka/PisakaApp.swift` (`Task`-wrap `refresh`/`revert`)
  - Modify: `Sources/Pisaka/ContentView.swift` (async `DiffPane.recompute`)
  - Create: `Tests/PisakaCoreTests/GitErrorTests.swift`
  - Modify: `Tests/PisakaCoreTests/LocalChangesModelTests.swift` (async stub +
    async test methods; new pure-helper and stale-guard tests)
  - Modify: `CLAUDE.md` (document the async/`@MainActor`/`GitError`-in-Core changes)
- Related patterns: the existing `FileServicing`/`GitServicing`
  protocol-behind-injectable-stub split; `PartialRevertError` already in Core with
  `InterruptedRevert` conforming in the view target; `FileIconColor`/`FileStatus`
  color-free-semantics-in-Core precedent for moving `GitError` to Core.
- Dependencies: none new. Swift tools 5.9 (Swift 5 language mode → any strict-
  concurrency / `Sendable` issues surface as warnings, not errors).

## Development Approach

- **Testing approach**: Regular (code first, then tests) — except the pure helpers
  (Task 2) and `GitError` (Task 1), which are naturally test-alongside.
- Order is chosen so each task compiles and the full suite passes before the next:
  Core error move → extract pure helpers (still synchronous) → flip everything to
  async in one atomic cut → additive stale-result guard → verify → docs.
- Every behavioral change ships with new/updated `PisakaCore` tests; the thin view
  layer (`GitCLIService` bridge, `Task` wrapping) is not unit-tested, per project
  convention, but must `swift build` cleanly.
- **CRITICAL: every code task includes new/updated tests, and the full suite +
  `swift build` must pass before starting the next task.**

## Implementation Steps

### Task 1: Move GitError to PisakaCore with LocalizedError

**Files:**
- Create: `Sources/PisakaCore/GitError.swift`
- Modify: `Sources/Pisaka/GitCLIService.swift`
- Create: `Tests/PisakaCoreTests/GitErrorTests.swift`

- [x] Create `GitError.swift` in Core: `public enum GitError: Error, Equatable, LocalizedError` with cases `gitUnavailable`, `notARepository(stderr: String)`, `revertFailed(reason: String)`, and the `errorDescription` switch (move the human-text logic verbatim from `GitCLIService`, including the empty-stderr fallback to "This folder is not a git repository."). Make cases/payloads `public`.
- [x] Remove the `enum GitError` and its `LocalizedError` extension from `GitCLIService.swift`; it now resolves to the Core type via the existing `import PisakaCore`. Leave `InterruptedRevert` and `RemoveFailure` in the view target.
- [x] Add `GitErrorTests.swift` asserting `errorDescription` for each case: `gitUnavailable`, `notARepository` with non-empty stderr (trimmed, passed through), `notARepository` with empty/whitespace stderr (fallback message), and `revertFailed(reason:)`.
- [x] run `swift build` and `swift test` — must pass before Task 2.

### Task 2: Extract pure decision helpers in LocalChangesModel (still synchronous)

**Files:**
- Modify: `Sources/PisakaCore/LocalChangesModel.swift`
- Modify: `Tests/PisakaCoreTests/LocalChangesModelTests.swift`

- [x] Extract the refresh state-reconciliation into a pure static helper, e.g. `reconcile(previousRoot:newRoot:files:selected:revertSelection:) -> (selected: ChangedFile?, revertSelection: Set<String>)`, capturing the prune-vs-clear rule (clear on root change, else intersect with current ids) and the selection re-bind. Have `refresh` call it.
- [x] Extract the per-file pre-revert stale check into a pure helper, e.g. `enum RevertGuard { case proceed; case abort(reason: String) }` + `guardRevert(file:current:) -> RevertGuard`, encoding "current exists and status + oldPath match, else abort with the `… changed since the list was last refreshed` message." Have the revert loop call it.
- [x] Extract reverted-URL assembly into a pure helper, e.g. `revertedURLs(for file: ChangedFile, root: URL) -> [URL]` (new path, plus the restored old path for a rename), used on the success path; keep the `PartialRevertError.changedPaths → URLs` mapping inline or in a sibling pure helper.
- [x] Refactor `refresh`/`revert` to delegate to these helpers without changing observable behavior (methods stay synchronous in this task).
- [x] Add synchronous unit tests for each pure helper (root-change clears vs intersect; selection rebind/clear; guard proceed/abort permutations across status & oldPath; rename returns both URLs). Keep the existing end-to-end model tests as-is.
- [x] run `swift build` and `swift test` — must pass before Task 3.

### Task 3: Convert GitServicing, LocalChangesModel, and GitCLIService to async

**Files:**
- Modify: `Sources/PisakaCore/GitServicing.swift`
- Modify: `Sources/PisakaCore/LocalChangesModel.swift`
- Modify: `Sources/Pisaka/GitCLIService.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Tests/PisakaCoreTests/LocalChangesModelTests.swift`

- [x] `GitServicing`: make `repositoryRoot`, `changedFiles`, `headContents`, `revert` `async throws`.
- [x] `LocalChangesModel`: annotate the class `@MainActor`; make `refresh(root:) async`, `revert(_:) async -> [URL]`, `rows(for:) async -> [DiffRow]`, and replace the `selectedRows` computed property with `selectedRows() async -> [DiffRow]`; add `await` to all internal `gitService` calls and to `headText`/`headContents` usage in `rows`. Keep `toggleChecked`, `filesToRevert`, `select`, `tree` synchronous.
- [x] `GitCLIService`: make `run(_:in:)` async by dispatching its existing blocking body onto a dedicated serial `DispatchQueue` and resuming a `withCheckedThrowingContinuation` (so a `git` run never occupies a cooperative-pool thread; the serial queue also serializes repo access). Make every method and private helper that calls `run` (`changedFiles`, `headContents`, `revert`, `checkout`, `move`, `worktreeMatchesHead`, `remove`, `revertRename`, `repositoryRoot`) `async`/`await` accordingly; `removeUntracked` (pure syscalls) stays synchronous. `InterruptedRevert`/`RemoveFailure` unchanged.
- [x] Update call sites so the executable builds: in `PisakaApp`, wrap `refreshLocalChanges()`'s call in `Task { await localChanges.refresh(root:) }`, and wrap `revertChanges(contextFile:)`'s `revert` + the tab-resync loop in a `Task { @MainActor in … }` (run the synchronous `confirmRevert` dialog before awaiting). In `ContentView`, make `DiffPane.recompute()` launch `Task { rows = await model.rows(for: file) }`, guarding against a stale assignment when `file` changed during the await (e.g. capture the file and only assign if it still matches). (Also updated `LocalChangesView.refreshIfPossible()`, another call site.)
- [x] Update `LocalChangesModelTests`: make `StubGit`'s methods `async`; convert existing test methods to `async` and `await` the model's `refresh`/`revert`/`rows`/`selectedRows`. Address any Swift-5-mode concurrency warnings pragmatically (the suite must build and pass).
- [x] run `swift build` and `swift test` — must pass before Task 4.

### Task 4: Stale-result guard for concurrent refreshes

**Files:**
- Modify: `Sources/PisakaCore/LocalChangesModel.swift`
- Modify: `Tests/PisakaCoreTests/LocalChangesModelTests.swift`

- [x] Add a monotonically increasing generation token to `refresh`: capture it at entry, and after the `await`ed IO resolves, commit the new published state only if the token is still the latest (a superseded refresh discards its result instead of overwriting a newer one).
- [x] Extend `StubGit` with a gating mechanism (e.g. an optional per-call continuation/closure) so a test can resolve two in-flight `changedFiles` calls out of order.
- [x] Add an async test driving two overlapping `refresh` calls whose stub completions resolve out of order, asserting the newer refresh's result wins and the stale one does not clobber it.
- [x] run `swift build` and `swift test` — must pass before Task 5.

### Task 5: Verify acceptance criteria

- [x] run `swift build` (executable + library compile clean)
- [x] run `swift test` (full suite passes)
- [x] confirm no `git` work runs synchronously on the main thread (model methods async, `GitCLIService.run` bridged off-main) and that `error.localizedDescription` now yields the `GitError` human text
- [x] verify `PisakaCore` test coverage of the new pure helpers, `GitError.errorDescription`, and the stale-refresh guard

### Task 6: Update documentation

- [x] Update `CLAUDE.md`: note `GitServicing` is async; `GitError` now lives in `PisakaCore` and conforms to `LocalizedError`; `LocalChangesModel` is `@MainActor` with async `refresh`/`revert`/`rows` and synchronous pure decision helpers (`reconcile`/`guardRevert`/URL assembly) plus the stale-refresh generation guard; `GitCLIService` bridges `Process` to async on a dedicated serial queue.
- [x] README.md: reviewed — no described detail became inaccurate (the async refactor is internal with no user-facing behavior change), left unchanged.
