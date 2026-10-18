# Close the four open findings: autosave replay ordering, HEAD-read prompt, final-newline row, quit ordering

## Overview

Four small corrections to existing contracts, each raised by the acceptance reviews of the gutter change markers and the external-change detection. Nothing else changes.

- **R1**: a trigger that fired while the writer gate was up is replayed on the next main-actor turn, not inside `resume()`. So no autosave runs between a gated operation's gate drop and its own resync.
- **R2**: the gutter's HEAD read (`git cat-file --filters`) sets `GIT_TERMINAL_PROMPT=0`. The prompt-suppression gating suite pins it.
- **R3**: `LineDiff.rows` emits a `.modified` row when the two sides' last lines have the same text and only one of them is terminated.
- **R4**: the quit asks, then flushes, then starts the language-server teardown, and starts the teardown only when that first round left nothing in conflict.

**Decision for R1: the replay hops; the two call sites are not reordered.** Reasons:

- One change in `AutosaveController.replayPendingIfReady()` covers all nine gated operations, and any future one, through the same mechanism `DiskSyncController.gateChanged` already uses for the deferred disk-check pass.
- Reordering the two sites (the branch-operation bracket's success path, `createBranch`) would put `finishBranchOperation`'s Local Changes and Log refresh kicks under a raised gate. It would also leave the next gated operation that lowers its gate before its resync open to the same bug.
- The rule that gates are down before any modal is untouched, because no site moves its `resume()` / `endRevert()`.
- The quit-time `flushNow` is not a replay and keeps its synchronous path.
- When its turn comes, the hop re-reads both gates and the pending flag, because another operation may have raised the gate in between.

## Context

- Files involved:
  - `Sources/Pisaka/AutosaveController.swift`: `resume()`, `resumeFromModal()`, `replayPendingIfReady()`, `performAutosave()`, `flushNow`
  - `Sources/Pisaka/PisakaApp.swift`:
    - `runBranchOperation` and `createBranch`, the two sites that lower the gates before their resync (read only, no change expected)
    - the `appDelegate.*` installation at about line 1230
  - `Sources/Pisaka/DiskSyncController.swift`: `gateChanged`, the pattern to copy
  - `Sources/Pisaka/AppDelegate.swift`: `applicationShouldTerminate`, `askUntilFlushed`, `flushLeftNoConflict`
  - `Sources/Pisaka/GitCLIService.swift`: `headText(fileURL:)`, and the `fetch`/`push`/`pull`/`commit` environment comments it mirrors
  - `Sources/PisakaCore/LineDiff.swift`: `rows(old:new:wordRanges:)`, `splitLines`; `matchedPairs` stays untouched for `ThreeWayMerge`
  - `Sources/PisakaCore/TerminatedLines.swift`, `PartialCommitBuilder.swift`, `HunkRevertPlan.swift`, `GutterChangeModel.swift`, `CommitDiffUnits.swift`, `UnifiedDiffDisplayRows.swift`: consumers of the rows, expected to need no code change
  - Tests (Core):
    - `Tests/PisakaCoreTests/LineDiffTests.swift`, `PartialCommitBuilderTests.swift`, `HunkRevertPlanTests.swift` (its fuzz exception for "a final newline differing on an unchanged last line"), `GutterChangeModelTests.swift`, `TerminatedLinesTests.swift` (the splitLines fuzz)
    - the `CommitDiffUnits` / `UnifiedDiffDisplayRows` tests
    - `GitCLIArgumentSourceGatingTests.swift`
  - Tests (app): `Tests/PisakaAppTests/DiskSyncControllerTests.swift`, the pattern for real files plus the real `FileService`
  - Docs:
    - `docs/architecture/app-shell.md`, `app-git-views.md`, `core-diff-merge.md`, `core-git-models.md`
    - `core-commit.md` (its `PartialCommitBuilder` entry restates the "converse is not an invariant" paragraph)
    - `docs/FEATURES.md`: the gutter feature entry at about line 179 and the known-limitations entry at about line 1941
- Related patterns:
  - the deferred pass's next-turn `Task { @MainActor [weak self] in … }` with the condition re-checked
  - a causal rendezvous through the autosave `onSaved` sink and `XCTestExpectation`, never a delay
  - source gating on comment-stripped, literal-keeping text, using set equality
- Dependencies: none

## Development Approach

- **Testing approach**: Regular (code first, then tests). Each test that pins a correction must fail on the current code; check that by running it before the fix where practical.
- Complete each task fully before moving to the next.
- Pure engine + thin glue:
  - The R3 row rule lives in Core and is unit-tested.
  - R1 and R4 are app-layer wiring, pinned by headless app-layer tests in `Tests/PisakaAppTests`.
  - R2 is pinned by the existing source-gating suite.
- `swiftlint --strict` with the committed configuration. A length ceiling is raised only with a reason in the config.
- The plan and the code name no other editor, IDE or project.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: R3, a final-newline-only difference is a modified last row (Core)

**Files:**
- Modify: `Sources/PisakaCore/LineDiff.swift`
- Modify: `Sources/PisakaCore/PartialCommitBuilder.swift` (doc comment only)
- Modify: `Tests/PisakaCoreTests/LineDiffTests.swift`
- Modify: `Tests/PisakaCoreTests/PartialCommitBuilderTests.swift`
- Modify: `Tests/PisakaCoreTests/HunkRevertPlanTests.swift`
- Modify: `Tests/PisakaCoreTests/GutterChangeModelTests.swift`
- Modify: the `CommitDiffUnits` / `UnifiedDiffDisplayRows` test file(s)

- [x] In `rows(old:new:wordRanges:)`, read whether each side's last line is terminated: `TerminatedLines.split(text).last?.terminator.isEmpty == false`.
  - When the final op is `.equal(o, n)`, `o` is the old side's last index and `n` is the new side's, and exactly one of the two is terminated, emit that row as `.modified` with `words: nil`.
  - Every other path is unchanged.
  - `splitLines` stays the pure projection of `TerminatedLines.split`.
  - `matchedPairs` (used by `ThreeWayMerge`) is not touched.
  - The doc comment states that this is the one place the projection sees a terminator, and why.
- [x] Update the "the converse is not an invariant" paragraph in `PartialCommitBuilder`'s doc comment: a last line that only gained or lost its terminator is now a unit, while a mid-file separator switch (CRLF→LF) still is not. No code change is expected, because the builder's rule already carries the side's terminator.
- [x] LineDiffTests, the new row:
  - `"a\nb"` vs `"a\nb\n"`, and the reverse, give one `.modified` row for line 2 with `words == nil`.
  - CRLF, CR and NEL terminators behave the same.
  - Both sides terminated, or both unterminated, give no change rows.
  - A last line whose text also differs is still `.modified`, as today, with word ranges on the public path.
  - Empty versus `"\n"` behaves as today, because the last op there is an insert.
  - The gutter path (`wordRanges: false`) gives the same kinds.
- [x] PartialCommitBuilderTests, both directions for the newline-only unit:
  - selected: the result is the worktree bytes (the terminator gained or lost);
  - not selected: the result is the HEAD bytes, byte-identical.
- [x] HunkRevertPlanTests:
  - Remove the fuzz's "final newline differing on an unchanged last line" exception, so reverting every hunk always yields `base` byte for byte.
  - Add a directed test that the newline-only hunk reverts to HEAD's terminator state.
- [x] GutterChangeModelTests: a newline-only difference marks the last line as modified, and the hunk at the caret on that line exists.
- [x] CommitDiffUnits / UnifiedDiffDisplayRows tests: the newline-only file has one unit, and the unified rows list the last line as removed, then added.
- [x] Confirm the `TerminatedLinesTests` splitLines fuzz stays green.
- [x] Run `swift test`; it must pass before Task 2.

### Task 2: R2, the HEAD read suppresses the terminal prompt

**Files:**
- Modify: `Sources/Pisaka/GitCLIService.swift`
- Modify: `Tests/PisakaCoreTests/GitCLIArgumentSourceGatingTests.swift`
- Modify: `Tests/PisakaCoreTests/GitHubSourceGatingTests.swift` (only if its deferring comment restates the set)

- [x] Pass `environment: ["GIT_TERMINAL_PROMPT": "0"]` to `headText`'s `run`, with a comment beside it giving the reason: `--filters` runs smudge filters, and an LFS smudge may fetch and prompt on /dev/tty, which would wedge the shared serial queue. Fetch, push and pull set it for the same reason.
  - The arguments, `stdoutLimit` and the directory are unchanged.
- [x] Extend `testTheNetworkCommandsSuppressTheTerminalPrompt`'s expected set to `{fetch, push, pull, commit, headText}`.
  - Rename the test if its name no longer reads truthfully (it now covers commands that reach a remote, or run hooks or filters that may).
  - Update the suite's doc-comment inventory and assertion message.
- [x] Check that the suite fails with the variable removed from `headText`, then restore it.
- [x] Run `swift test`; it must pass before Task 3.

### Task 3: R1, the autosave replay hops to the next main-actor turn

**Files:**
- Modify: `Sources/Pisaka/AutosaveController.swift`
- Create: `Tests/PisakaAppTests/AutosaveReplayOrderTests.swift`

- [x] Change `replayPendingIfReady()` so it schedules `Task { @MainActor [weak self] in … }`.
  - When the turn comes, it re-checks `!isRegularSuspended` and `pendingAutosave`, then clears the flag and calls `performAutosave()`.
  - The flag stays set until then, so a gate raised in between keeps the debt.
  - `resume()` and `resumeFromModal()` both go through it; `flushNow` is untouched.
  - The doc comment states the reason: every gated operation lowers its gates and then resyncs its tabs in the same synchronous stretch, so the replay must not run first. The deferred disk-check pass follows the same rule.
- [x] App-layer test, using real files and the real `FileService`:
  1. Open a tab and edit it (dirty).
  2. `suspend()` the autosave.
  3. Fire a trigger synchronously under the gate by changing `selectedID` to a second open tab, so `pendingAutosave` is set.
  4. Rewrite the edited tab's file on disk, standing in for the checkout.
  5. `resume()`.
  6. In the same synchronous stretch, run the operation's resync for an edited tab: `model.reconcileSavedBaseline(id:)`, which `resyncOpenTabsAfterCheckout` calls.
  7. Assert immediately: the tab is dirty and `isInExternalConflict == false`.
  8. Rendezvous on the `onSaved` sink's expectation for the replayed autosave, then assert that the tab is still not in conflict and that the replay treated it as writable (its buffer is on disk).
  - On the current code the synchronous replay puts the tab in conflict before the reconcile, and the sink never fires for it.
- [x] Second test: a gate raised again before the hop's turn keeps the pending save, and it is replayed after the next drop.
- [x] Run the new test against the old `replayPendingIfReady` to see it fail, then against the fix to see it pass.
- [x] Run `xcodegen generate` if the test folder needs it, then run `swift test` and the app-layer bundle (the same eight known scale-1.8 failures and no others). Both must pass before Task 4.

### Task 4: R4, the quit asks, flushes, then tears down

**Files:**
- Modify: `Sources/Pisaka/AppDelegate.swift`
- Create: `Tests/PisakaAppTests/QuitOrderTests.swift`

- [x] Move the body of `applicationShouldTerminate` into an internal method that takes the asynchronous reply as a closure; the delegate method passes `sender.reply(toApplicationShouldTerminate:)`. This seam lets a headless test observe the deferred reply without terminating the test host.
- [x] The first round stays synchronous on the main actor and loops until the flush skips nothing:
  1. Ask `externalChangeQuestion`; `.cancel` answers `.terminateCancel` with no teardown requested.
  2. Collect any `awaiting`.
  3. Run `flushLeftNoConflict()`.
  4. If that flush skipped a conflict, ask again.
- [x] Only after that round, read `languageServerTeardown?()`.
  - If nothing is pending, answer `.terminateNow`.
  - Otherwise await the Local History writes and the teardown, then run `askUntilFlushed()`, unchanged. Its question finds only conflicts that arose during the wait, the one case where a Cancel after the teardown is still reachable.
  - Update the doc comments of `externalChangeQuestion`, `flushBeforeTermination` and `askUntilFlushed`.
- [x] App-layer tests with recording closures:
  - order: a conflicted round answered `.proceed`, then the flush, then the teardown factory, in that order;
  - Cancel on the first round: `.terminateCancel`, the teardown factory never invoked and the flush never run;
  - a flush that skips a conflict sends the quit back to the question before any teardown;
  - no live servers and no conflict: `.terminateNow` with exactly one flush;
  - a conflict introduced during the teardown wait, staged by a `Gate` the teardown closure waits on: the re-check asks, and a Cancel replies `false`.
- [x] Run `swift test` and the app-layer bundle; both must pass before Task 5.

### Task 5: Documentation and inventory suites

**Files:**
- Modify: `docs/architecture/app-shell.md` (the `AutosaveController.swift` entry and the quit paragraph in the `AppDelegate.swift` entry)
- Modify: `docs/architecture/app-git-views.md` (the change column's `headText` paragraph)
- Modify: `docs/architecture/core-diff-merge.md` (the `LineDiff.swift` entry)
- Modify: `docs/architecture/core-git-models.md` (the `GutterChangeModel` / `HunkRevertPlan` entries)
- Modify: `docs/architecture/core-commit.md` (the `PartialCommitBuilder` entry, the paragraph beginning "The converse is deliberately not", at about line 139)
- Modify: `docs/FEATURES.md` (the gutter feature entry at about line 179, and the known-limitations entry at about line 1941)
- Modify: `CLAUDE.md` (only if a claim changes)

- [ ] `app-shell.md`:
  - The replay runs on the next main-actor turn and is named as covered by the "same synchronous stretch" rule beside the deferred pass. The quit flush is the synchronous exception.
  - Rewrite the quit sequence: question, flush, then teardown. The post-wait re-check exists only for conflicts that arise during the wait, and that is the one reachable Cancel-after-teardown case.
- [ ] `app-git-views.md`: the HEAD read sets `GIT_TERMINAL_PROMPT=0`, with the smudge reason.
- [ ] `core-diff-merge.md`: the final-newline row rule, and the one place the projection sees a terminator.
- [ ] `core-git-models.md`: the gutter marks it, and the revert restores HEAD's terminator state. Drop any stated limit to the contrary.
- [ ] `core-commit.md`: the same correction as `PartialCommitBuilder`'s doc comment in Task 1. A last line that only gained or lost its terminator is now a unit, while a mid-file separator switch still is not, so the repo-level doc and the code comment agree.
- [ ] `FEATURES.md`, in both places a reader looks for the gutter's limits, state that a final-newline-only change is marked on the last line. Drop nothing.
  - the feature entry at about line 179, beside "untracked or binary file, a file over 1 MiB and an Untitled buffer simply show no markers";
  - the known-limitations entry at about line 1941, beside "Files over 1 MiB on either side show no markers".
- [ ] Grep the inventory suites (`LocalHistorySourceGatingTests`, `GitHubSourceGatingTests`, `LintConfigurationTests`, others) for counts or sets these changes touch, and update them. Keep `CLAUDE.md` under its measured size.
- [ ] Run `swift test`; it must pass.

### Task 6: Verify acceptance criteria

- [ ] Run `swift test`.
- [ ] Run the app-layer bundle under the pinned Xcode: `DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`. It must show the same eight known scale-1.8 failures and no others.
- [ ] Run the macOS build under the pinned Xcode.
- [ ] Run `swiftlint --strict` from the repository root.
- [ ] Confirm each new test pins its requirement:
  - the R1 replay test fails without the hop;
  - the R2 gating suite fails without the variable;
  - the R3 row tests fail without the rule;
  - the R4 order test fails on the old ordering.

### Task 7: Update documentation

- [ ] README.md needs no change: no user-facing shortcut or feature list changes beyond `FEATURES.md`.
- [ ] Update CLAUDE.md only if an invariant sentence changed. None is expected, since "the same synchronous stretch" lives in `app-shell.md`.

## Post-Completion

- Manual checks in a DEBUG build:
  - a branch switch with a dirty tab and a pending idle debounce ends with the reconcile beep, not the conflict bar;
  - a newline-only edit shows the marker, its popover and Revert;
  - ⌘Q with a live server and a conflicted tab, then Cancel, leaves the server running.
