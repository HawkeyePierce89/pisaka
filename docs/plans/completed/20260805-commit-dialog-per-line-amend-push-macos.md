# Commit from the app: modal dialog with per-line selection, author, amend and push (macOS)

## Overview
Close the last gap in the git subsystem: an IDEA-style modal commit dialog. On the left — files with checkboxes; on the right — a unified diff of the selected file with checkboxes on changed lines; at the bottom — the message field, the author line with local-config editing, Amend and Push after commit. The adopted model is JetBrains': exactly what is selected in the UI gets committed. The mechanism is a temporary index (`GIT_INDEX_FILE`) seeded from `read-tree HEAD`, a real `git commit` on top of it (so hooks and git's own author resolution keep working), and `git reset --quiet` after success as the single touch of the real index. All logic — content assembly, file classification, identity, gates, commit and push plans, snapshot-staleness checking, the dialog model — lives in `PisakaCore` under tests (TDD). The sheet and the `Process` calls are a thin, untested view layer. macOS only: the new `GitServicing` methods are defaulted in the extension, so `LibGit2Service` is untouched. The right-hand panel is a new standalone SwiftUI panel with a unified (single-column) diff and checkboxes (the Q&A decision), not an extension of the AppKit `DiffView`.

## Context
Files the implementation builds on:

- `Sources/PisakaCore/LineDiff.swift` — `DiffRow`/`DiffRowKind`/`DiffLine`, `splitLines` (terminators stripped), capped LCS. A selection unit is a row index in `LineDiff.rows(old:new:)`.
- `Sources/PisakaCore/LocalChangesModel.swift` — the model shape to follow: `@MainActor ObservableObject`, IO behind `GitServicing`/`FileServicing`, pure static decisions (`reconcile`, `guardRevert`, `revertedURLs`), generation tokens (`rootRequestGeneration`, `prepareForFolderChange`, `revert(_:originGeneration:)`), the `isReverting`/`beginRevert`/`endRevert` gate. Its `rows(for:)` is deliberately *not* reused by the dialog — see Task 2.
- `Sources/PisakaCore/GitServicing.swift` — protocol + extension defaults (the "new methods break neither the stubs nor `LibGit2Service`" pattern); `headContents(of:root:) -> String?`, whose `nil` means only "the path is absent from HEAD".
- `Sources/PisakaCore/GitError.swift` — typed errors carrying their `LocalizedError` text in Core.
- `Sources/PisakaCore/FileService.swift` — `readTextIfNotBinary`, `binaryProbeBytes = 8000` (the "NUL in the head ⇒ binary" rule, plus the refusal of non-UTF-8).
- `Sources/Pisaka/GitCLIService.swift` — `run(_:in:on:)` / `runBlocking(_:in:)`, serial queue, pipe draining. Two facts Task 2 and Task 8 depend on: stdout is decoded with `String(decoding:as: UTF8.self)` — lossily, so invalid bytes become U+FFFD rather than an error; and the process is launched through `/usr/bin/env` and inherits the app's environment, i.e. `process.environment` is never assigned at all.
- `Sources/Pisaka/LocalChangesView.swift` — the panel header (where the Commit button goes), `ChangedFileRow`.
- `Sources/Pisaka/PisakaApp.swift` — `CommandMenu`, `revertInFlight()`, `autosave.suspendForModal()/resumeFromModal()`, `applyMerge` as the writer-coordination precedent, generation-pinned Local Changes / Log / branch-switcher refreshes.
- Tests: `Tests/PisakaCoreTests/` (one file per type).

Dependencies: none new.

## Development Approach
- Testing approach: TDD for all of Core (test first, then implementation), per the repo convention.
- Every task ends with a green `swift test` before the next one starts.
- The view layer (sheet, `Process` calls) is not tested — every branching decision is lifted into Core.
- Every deliberate limitation is recorded in words in the doc comment of the corresponding type, not only in this plan.
- CRITICAL: every task must include new/updated tests
- CRITICAL: all tests must pass before starting the next task

## Implementation Steps

### Task 1: Terminator-preserving splitter and its consistency with LineDiff
The partial-content builder must emit lines verbatim, terminators included, while unit indices come from `LineDiff.rows`, which splits through `splitLines`. If the two splitters diverge on even one separator, the builder silently assembles the wrong lines. So there is one representation: `splitLines` becomes a projection of the new splitter. The order of steps inside this task is part of its substance. The fuzz test `split(text).map(\.content) == LineDiff.splitLines(text)` is written and run against the *old, independent* implementation of `splitLines` — at that point it is meaningful and pins the refactor itself: two different algorithms must agree on mixtures of every separator, otherwise the rewrite changes behavior. After `splitLines` is rewritten as a projection the test becomes a tautology — that is expected and fine; its role changes into a regression lock against "un-projecting" (reintroducing a second independent implementation), which is stated in a comment in the test itself.

**Files:**
- Create: `Sources/PisakaCore/TerminatedLines.swift`
- Create: `Tests/PisakaCoreTests/TerminatedLinesTests.swift`
- Modify: `Sources/PisakaCore/LineDiff.swift`
- Modify: `Tests/PisakaCoreTests/LineDiffTests.swift`
- [x] write tests: `TerminatedLines.split(_:)` returns (content, terminator) pairs for LF / CR / CRLF-as-one / NEL / U+2028 / U+2029, for a final line with no terminator, for empty text, and for text made of separators only
- [x] write the invariant test: concatenating every `content + terminator` reproduces the input text identically
- [x] implement `TerminatedLines` via `enumerateSubstrings(.byLines)` (terminator = enclosingRange minus substringRange), and document in the doc comment that this is the single line representation and why
- [x] write a fuzz/property test (deterministic LCG in the `LineStartIndexTests` style) over mixtures of every separator: `split(text).map(\.content) == LineDiff.splitLines(text)` — and run it *before* rewriting `splitLines`, against its current independent implementation; record its dual role in a comment in the test (now: pins the refactor; afterwards: a lock against a second implementation coming back)
- [x] rewrite `LineDiff.splitLines` as a projection of `TerminatedLines.split` (behavior and the existing `LineDiffTests` unchanged)
- [x] run `swift test` — green

### Task 2: Byte-level access to the HEAD side, "whole-only" classification, selection units and the unified representation
The rule "a file whose *either* side does not decode as text is committed whole only" must rest on bytes, not on a string. The existing `headContents(of:root:) -> String?` is unfit for that for two reasons at once: its `nil` means exactly one thing — "the path is absent from HEAD" — and an undecodable blob does not collapse into it, because `runBlocking` decodes stdout lossily (`String(decoding:as: UTF8.self)`) and invalid bytes become U+FFFD. So a binary HEAD blob arrives either as a plausible-looking garbage string or (had decoding been strict) indistinguishable from absence — and under both readings a file that is *binary in HEAD and text in the worktree* is classified as "wholly added", with selectable units against a falsely empty old side. That is precisely the class of silent corruption the rule exists to catch. Hence a byte-level accessor `headBlob(of:root:) -> Data?`, where absence is signalled by git's exit code rather than by decodability, plus a pure decoder `GitBlobText` applying the same rule as `FileService.readTextIfNotBinary`: a NUL within the first `binaryProbeBytes` bytes ⇒ binary; otherwise strict UTF-8, failure ⇒ binary; otherwise text. The consequence for the dialog, recorded in words: the dialog's diff is *not* built through `LocalChangesModel.rows(for:)`. That path takes the old side from `headContents` and the new side from a strict UTF-8 read, and it is exactly what turns a binary file into "every HEAD line removed". The dialog classifies both sides itself and builds `LineDiff.rows(old:new:)` only for a file whose both sides are text.

**Files:**
- Create: `Sources/PisakaCore/GitBlobText.swift`
- Create: `Sources/PisakaCore/CommitDiffUnits.swift`
- Create: `Tests/PisakaCoreTests/GitBlobTextTests.swift`
- Create: `Tests/PisakaCoreTests/CommitDiffUnitsTests.swift`
- Modify: `Sources/PisakaCore/GitServicing.swift`
- [x] write tests for `GitBlobText.classify(_ data: Data?) -> BlobText`: `nil` → `.absent`; data with a NUL in the head → `.binary`; invalid UTF-8 without a NUL → `.binary`; a NUL beyond `binaryProbeBytes` → `.text` (the boundary matches `FileService`); empty data → `.text("")`; ordinary text → `.text`
- [x] write a test pinning the separation of meanings: `.absent` and `.binary` are different cases and neither is expressible through the other
- [x] add `headBlob(of path: String, root: URL) async throws -> Data?` to `GitServicing` with a `nil` default in the extension (existing stubs and `LibGit2Service` untouched); state the contract in the doc comment: `nil` = "the path is absent from HEAD", decided by git's exit code; bytes are returned raw, decoding is `GitBlobText`'s job
- [x] write `FileCommitEligibility` classification tests: `.wholeOnly` for `.deleted`; `.wholeOnly` when the HEAD side is `.binary`; `.wholeOnly` when the worktree side is binary/unreadable; `.selectable` when both sides are text (including untracked: HEAD `.absent` + worktree text); a `.wholeOnly` file has no selectable units
- [x] write the regression test for the original trap: HEAD side binary, worktree side text → `.wholeOnly`, not "whole file added" with selectable units
- [x] write `selectableUnits(rows:)` tests: row indices of `added`/`removed`/`modified`; `unchanged` is not a unit; a file differing only in line endings yields zero units (a boundary, pinned in words in the doc comment — `splitLines` compares terminator-stripped lines, so such a file is committed whole only)
- [x] write unified-representation tests: context/`-`/`+`; a `modified` row expands into a pair of lines sharing one `unitIndex`; old- and new-side numbers are correct; row order preserved
- [x] implement `GitBlobText`, `FileCommitEligibility` (`.selectable` / `.wholeOnly(reason:)`), `selectableUnits`, `UnifiedDiffLine` + its construction from `[DiffRow]`
- [x] run `swift test` — green

### Task 3: Partial-content builder
The central new logic. Given the HEAD text, the worktree text and a set of selected units, assemble "HEAD plus only the selected changes". The separator rule: every emitted line carries the terminator of the side it came from (unchanged and unselected lines — the old side verbatim; selected ones — the new side verbatim); a missing final newline is a special case of that same rule, not a separate branch. There is exactly one invariant and it is structural: an empty unit set yields the HEAD bytes identically. The converse — "selecting every unit yields the worktree bytes" — is false and deliberately *not* pinned as an invariant: a line whose terminator alone changed (CRLF→LF) with identical content is not a unit at all (`splitLines` compares stripped lines), and by the separator rule it is emitted from the old side verbatim — with the old terminator. Equality with the worktree holds only when every unchanged line is terminated the same way on both sides; under mixed endings the builder's result ≠ the worktree, and that is correct behavior. In production the divergence is unobservable: a fully checked file bypasses the builder entirely (Task 6).

**Files:**
- Create: `Sources/PisakaCore/PartialCommitBuilder.swift`
- Create: `Tests/PisakaCoreTests/PartialCommitBuilderTests.swift`
- [x] write the invariant test: an empty unit set yields the HEAD bytes identically (including under mixed endings and with no trailing newline)
- [x] write the conditional-equality test: when every unchanged line is terminated identically on both sides, selecting all units yields the worktree bytes identically
- [x] write the counterexample test to the unconditional version: a file where an unchanged line's terminator switched CRLF→LF — there are no units for it at all, and selecting every existing unit keeps the old terminator, so the result differs from the worktree (expected behavior, not a bug)
- [x] write combination tests: added only; removed only; modified only; adjacent changes; interleaved selected and unselected units
- [x] write separator tests: a CRLF file; mixed endings (a selected line brings the new side's terminator, an unselected one keeps the old); no trailing newline on both sides and on one
- [x] write the degenerate-case test: untracked (HEAD empty) — selecting a subset of added units
- [x] implement `PartialCommitBuilder.assemble(head:worktree:rows:selectedUnits:)` on top of `TerminatedLines`; document the separator rule, the structural "nothing selected = HEAD" invariant, and in words why the converse equality is conditional and where it is guaranteed structurally instead
- [x] run `swift test` — green

### Task 4: Author identity
An always-visible author of the future commit is the point of the feature (the pain: a work repository silently committing under a personal global name). The source and the signature text are pure. Mixed sources must not lie: the signature has to name the source of each field.

**Files:**
- Create: `Sources/PisakaCore/CommitIdentity.swift`
- Create: `Tests/PisakaCoreTests/CommitIdentityTests.swift`
- [x] write tests: both fields from local → `Name <email> (local)`; both from global → `(global)`; mixed → the signature names each field's source separately and never claims a single source
- [x] write "unset" tests: empty/absent name, empty/absent email, both — `isComplete == false`
- [x] implement `IdentityFieldSource` (`.local`/`.global`/`.unset`) and `CommitIdentity` (`name`, `email`, sources, `isComplete`, `signature`), including the pure `resolve(localName:localEmail:effectiveName:effectiveEmail:)` — deciding a field's source from the pair "local value / effective value"
- [x] record in the doc comment: the global config is never touched, editing writes local only
- [x] run `swift test` — green

### Task 5: Repository state, Commit gates, amend availability and the push plan
The temporary-index mechanism bypasses two of git's own protections — "you have unmerged files" (checked against the real index, which we substitute) and "cannot do a partial commit during a merge". So blocking during an in-progress operation is our responsibility, and that same block subsumes "amend unavailable during a merge". The consequence is recorded in words: a merge commit cannot be created from the UI.

**Files:**
- Create: `Sources/PisakaCore/CommitContext.swift`
- Create: `Sources/PisakaCore/CommitGate.swift`
- Create: `Sources/PisakaCore/PushPlan.swift`
- Create: `Tests/PisakaCoreTests/CommitGateTests.swift`
- Create: `Tests/PisakaCoreTests/PushPlanTests.swift`
- [x] write `InProgressOperation.detect(markerNames:)` tests: MERGE_HEAD → merge, CHERRY_PICK_HEAD → cherry-pick, REVERT_HEAD → revert, rebase-merge/rebase-apply → rebase, empty → nil
- [x] write gate tests, each reason separately plus the allowing case: no repository; identity unset; message empty after trimming; non-amend with zero selected units; a conflicted file present; each in-progress operation; a commit/push already running — with the reason text for each
- [x] write amend tests: with amend an empty file selection is legal, without amend it blocks; amend is unavailable on an unborn HEAD
- [x] write `PushPlan` tests (three branches): upstream exists → plain push; no upstream but a remote exists → push creating the upstream; detached HEAD or no remote → push unavailable, with a reason
- [x] implement `CommitContext` (unborn HEAD, `InProgressOperation?`, detached, current branch, upstream, remotes), `CommitGate.evaluate(...) -> CommitBlock?` with human text in Core, and `PushPlan.plan(context:)`
- [x] document in words: why we block during an in-progress operation, and that finishing a merge stays a console job
- [x] run `swift test` — green

### Task 6: Commit plan and snapshot-staleness check
A whole file is put into the temporary index from the working file — git itself resolves symlinks, the exec bit, clean filters and `core.autocrlf`; a file with no selected units never enters the index at all. That fork is what makes both boundaries structural: "nothing selected = HEAD" because the path never enters the index, and "everything selected = worktree" because the bytes are placed by git rather than by the builder (for which, as Task 3 shows, that equality does not hold in general). Modality blocks internal writers but not console git, so immediately before the commit every included file is re-read and re-diffed (the `guardRevert` precedent), and any divergence aborts the whole batch.

**Files:**
- Create: `Sources/PisakaCore/CommitPlan.swift`
- Create: `Tests/PisakaCoreTests/CommitPlanTests.swift`
- [x] write plan-by-status tests: modified/added/untracked whole → add from the worktree; partial → assembled content with the mode from HEAD, or from the worktree when there is no HEAD entry; deleted → remove the path; renamed whole and partial → remove the old path + add the new one
- [x] write the test: a file with zero selected units drops out of the plan entirely
- [x] write the test: a file with all units selected enters the plan as `.addFromWorktree`, not through the builder (the structural guarantee from this task's preamble)
- [x] write the test: a `.wholeOnly` file (binary or deleted) enters the plan whole only — `.addFromWorktree` / `.removePath`, never `.addContent`
- [x] write checkbox-state tests: all units → checked, some → mixed, none → unchecked; a whole-only file with zero units but checked → checked, not mixed
- [x] write staleness tests: snapshot matches → proceed; changed status / changed `oldPath` / changed diff / changed side classification (text became binary) → abort with a reason naming the path; nothing is written on abort
- [x] implement `CommitPlan` (`CommitPlanEntry`: `.addFromWorktree` / `.addContent(content:modeSource:)` / `.removePath`), `CommitPlan.build(...)`, `CheckboxState`, `CommitStaleness.check(...)`
- [x] document in words the consequences of the model: a manual `git add` from the terminal is overwritten by a commit from the UI; the staged effects of formatter hooks are erased by the final `reset --quiet`, while their worktree edits remain as local changes
- [x] run `swift test` — green

### Task 7: GitServicing extension and CommitDialogModel
The new protocol methods are defaulted in the extension (existing stubs and `LibGit2Service` untouched). The model follows the `LocalChangesModel`/`MergeModel` shape: `@MainActor ObservableObject`, IO behind protocols, a generation token for folder changes, origin-pinning of `commit()` itself. Loading a file in the dialog goes through `headBlob` + `GitBlobText` plus a worktree read (Task 2), not through `LocalChangesModel.rows`.

**Files:**
- Modify: `Sources/PisakaCore/GitServicing.swift`
- Modify: `Sources/PisakaCore/GitError.swift`
- Create: `Sources/PisakaCore/CommitDialogModel.swift`
- Create: `Tests/PisakaCoreTests/CommitDialogModelTests.swift`
- Modify: `Tests/PisakaCoreTests/GitErrorTests.swift`
- [x] add to `GitServicing` (all with extension defaults): `commitContext(root:)`, `identity(root:)`, `setLocalIdentity(name:email:root:)`, `headMessage(root:)`, `commit(_:message:amend:root:)`, `push(_:root:)`; add `GitError.commitFailed(reason:)` / `.pushFailed(reason:)` with texts and tests
- [x] write model tests against stubs: loading the context and the files; the "all files checked" default; toggling a file and an individual unit; a file binary on the HEAD side arrives in the model as `.wholeOnly` with no units (an end-to-end test over a `headBlob` stub)
- [x] write amend-checkbox-with-message tests: the `HEAD` message is substituted only into a field empty after trimming; non-empty user text is left alone; turning it off restores the previous text only when the field still equals the auto-inserted text verbatim
- [x] write `commit()` sequencing tests: a stale snapshot aborts the whole batch and writes nothing; a failed commit leaves state as is and surfaces stderr verbatim; success clears the message field; a push failure after a successful commit is its own state — "commit created, push failed"
- [x] write race tests: a folder change invalidates the dialog (the `prepareForFolderChange` pattern); `commit(originGeneration:)` with a stale token does nothing (the `revert(_:originGeneration:)` pattern); a repeat commit while one is running is blocked
- [x] implement `CommitDialogModel` on top of the pure pieces from Tasks 2–6
- [x] run `swift test` — green

### Task 8: GitCLIService — raw stdout, environment override, temporary index, commit, amend, push, config
A thin, untested `Process` layer. `plumbing commit-tree` is deliberately not used — a real `git commit` is needed so that pre-commit/commit-msg hooks and git's own author resolution keep working (bonus: through `git diff --cached` the hooks see exactly the content being committed). Two amendments to the existing `run`/`runBlocking`, both dictated by how it works today. First: stdout is decoded lossily, so `headBlob` needs a path that hands back bytes as they are. Second, and this one is critical: the process is launched through `/usr/bin/env` and today inherits the app's environment (`process.environment` is never assigned), so the new parameter is an *override* merged over `ProcessInfo.processInfo.environment`, not a replacement. Assigning `process.environment = ["GIT_INDEX_FILE": …]` would wipe `PATH` (so `/usr/bin/env git` would stop finding git at all), `HOME` (git would lose the global config — author resolution and credential helpers), and everything the hooks rely on. The parameter's default is an empty dictionary, under which the environment is assembled identically to today's behavior, so existing call sites are unchanged.

**Files:**
- Modify: `Sources/Pisaka/GitCLIService.swift`
- [x] extend `run`/`runBlocking` with two things: a parameter `environment: [String: String] = [:]` merged over `ProcessInfo.processInfo.environment` (the override wins over the inherited value; an empty dictionary = today's inheritance), and access to the raw stdout `Data` alongside the decoded string; existing call sites keep reading the string and pass no environment
- [x] record in `run`'s doc comment why it is a merge rather than a replacement — the launch goes through `/usr/bin/env`, and hooks and credential helpers live in the inherited environment
- [x] implement `headBlob(of:root:)` via `git show HEAD:<path>` with raw stdout: `nil` only on a non-zero exit (the path is absent from HEAD), otherwise the bytes as they are — decodability does not affect classification
- [x] implement `commitContext`/`identity`/`headMessage`/`setLocalIdentity` via `rev-parse`, `symbolic-ref`, markers in the git dir, `@{upstream}`, `git remote`, `git config --local --get` + `git config --get`, `git config --local user.name/user.email`
- [x] implement `commit`: a temporary directory → `GIT_INDEX_FILE` as an environment override → `read-tree HEAD` (unborn → `read-tree --empty`) → per plan entry `update-index --add` / `hash-object -w --path=…` + `update-index --add --cacheinfo` / `update-index --force-remove` → `git commit -F <message file>` (+ `--amend`) with the same override → on success `git reset --quiet` with no override (the real index)
- [x] ensure: a failure at any step surfaces with its stderr, the real index and HEAD untouched; temporary files are removed on every outcome (`defer`)
- [x] implement `push` per `PushPlan` (plain push / push creating the upstream), non-zero → `GitError.pushFailed`
- [x] run `swift test` — green (Core must not break); build the macOS target

### Task 9: Commit dialog (SwiftUI sheet) and app integration
A sheet on the main window; a unified diff with checkboxes (the Q&A decision). Before opening — refuse while `isReverting`, and flush dirty buffers; for the duration of the modal — `suspendForModal()`/`resumeFromModal()`, with the release guaranteed on every closing path. Separately — the right-hand panel for a file that is committed whole only. There are three such categories and all three behave the same way: `.wholeOnly` for reason "deleted", `.wholeOnly` for reason "binary / non-UTF-8 on at least one side", and `.selectable` with zero selectable units (a file differing only in line endings — the boundary from Tasks 2/3). In these cases the panel draws neither a diff nor a single line checkbox: instead, a "committed as a whole" placeholder with the concrete reason. This is substantive rather than cosmetic: a diff whose checkboxes cannot be clicked reads as "selection is broken", and for a binary file arriving through a `LocalChangesModel.rows`-like path as "every HEAD line removed" it also reads as an invitation to silent corruption. Such a file's checkbox in the left-hand list is an ordinary checked state, never mixed (the rule from Task 6).

**Files:**
- Create: `Sources/Pisaka/CommitDialogView.swift`
- Create: `Sources/Pisaka/CommitUnifiedDiffView.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `Sources/Pisaka/LocalChangesView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`
- [x] assemble the sheet: on the left the file list with checkboxes (mixed included) and status badges, on the right the unified diff with checkboxes on units, at the bottom the multiline message field, the author line, the Amend and Push after commit checkboxes, and the Commit/Cancel buttons; a blocked Commit shows the reason from `CommitGate`
- [x] implement the "whole only" branch of the right-hand panel: for `.wholeOnly` (deleted; binary / non-UTF-8) and for `.selectable` with zero units (line endings differ only), a "committed as a whole" placeholder with the reason text taken from Core (`FileCommitEligibility.reason` / "only line endings differ") is drawn instead of the diff and the checkboxes; not a single line checkbox exists in this branch
- [x] the author-editing dialog: two fields, a write to the local config, an update of the author line; "unset" — red signature and a blocked Commit
- [x] add the Commit button to the `LocalChangesView` header and a menu item (⌘K), both disabled with no folder open; thread the callbacks per the `PisakaApp → ContentView → LocalChangesView` convention. **Deviation from the item as written:** an *empty change list* deliberately does not disable either. That list is refreshed only on a folder open, a save and the manual Refresh button, so a change made in the embedded terminal or an external editor would leave ⌘K dead until the user found that button — while the dialog's own load runs a fresh `git status` and reports "No local changes" honestly. It is also what makes a message-only amend reachable, a clean tree being exactly when one is wanted (`CommitGate` already permits an empty selection under Amend).
- [x] implement coordination in `PisakaApp`: refuse on `revertInFlight()`, flush autosave before opening, `suspendForModal()`/`resumeFromModal()` via `defer`, generation-pinned Local Changes / Git Log / branch-switcher refresh after success (no `bumpTreeRevision` — the worktree did not change)
- [x] ensure closing behavior: Esc/Cancel — no side effects; Commit closes on success and, on failure, leaves the dialog open with stderr verbatim
- [x] run `swift test` — green

### Task 10: Verify acceptance criteria
- [x] `swift test` — the whole suite green (1484 tests, 0 failures)
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build` — succeeds
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` — succeeds (the new `GitServicing` methods did not touch `LibGit2Service`)
- [x] check against the ticket text that every listed test category is present in the suite (assembly and its boundaries, the splitter fuzz test, binary — including "binary in HEAD, text in worktree", identity, gates, push DWIM, the commit plan, mixed, staleness, push failure)
  - assembly and its boundaries — `PartialCommitBuilderTests` (23): `testEmptySelectionReproducesHeadBytes`, `…UnderMixedEndingsAndNoTrailingNewline`, `testSelectingAllUnitsReproducesWorktreeWhenUnchangedLinesAgreeOnTerminators`, `testUnchangedLineWhoseTerminatorSwitchedIsNotAUnitAndKeepsTheOldTerminator` (the counterexample), CRLF/mixed/no-trailing-newline separator tests
  - splitter fuzz — `TerminatedLinesTests.testSplitContentsMatchLineDiffSplitLines` (+ the fixed-mixture companion and `testConcatenationReproducesInput`)
  - binary, incl. "binary in HEAD, text in worktree" — `GitBlobTextTests` (8), `CommitDiffUnitsTests.testBinaryInHeadTextInWorktreeIsWholeOnlyNotWhollyAdded`, `CommitPlanTests.testBinaryInHeadTextInWorktreeEntersThePlanWholeOnly`, `CommitDialogModelTests.testFileBinaryInHeadArrivesWholeOnlyWithNoUnits`
  - identity — `CommitIdentityTests` (15), mixed-source and unset cases included
  - gates — `CommitGateTests` (35): every reason separately, precedence, `testEveryBlockCarriesText`
  - push DWIM — `PushPlanTests` (15): all three branches plus origin preference and detached/unborn edge cases
  - the commit plan — `CommitPlanTests` (37) by status, whole-vs-partial fork, `.wholeOnly` whole-only entry
  - mixed — `CommitPlanTests.testCheckboxIsMixedWhenSomeUnitsAreSelected` / `…WholeOnlyFileWithZeroUnitsIsCheckedNotMixed`, `CommitDialogModelTests.testToggleUnitProducesMixedState`
  - staleness — `CommitDialogModelTests.testStaleSnapshotAbortsTheWholeBatchAndWritesNothing` / `…CommitWithAStaleOriginGenerationDoesNothing`, `CommitPlanTests.testEveryStaleReasonCarriesDistinctNonEmptyText`
  - push failure — `CommitDialogModelTests.testPushFailureAfterASuccessfulCommitIsItsOwnState`, `GitErrorTests.testPushFailedReturnsItsReason`

### Task 11: Update documentation
- [x] extend `CLAUDE.md`: the new Core types (splitter, `GitBlobText`, units/classification, builder, identity, context/gates, commit and push plans, `CommitDialogModel`), the new `GitServicing` methods (including `headBlob`'s contract: `nil` = "absent from HEAD", decided by the exit code), raw stdout and the environment override in `GitCLIService` (a merge over the inherited environment, not a replacement — otherwise `/usr/bin/env`, hooks and credential helpers break) and the temporary-index mechanism, the new view files and the wiring
- [x] record the deliberate limitations in words: a merge commit cannot be created from the UI; a manual `git add` is overwritten; the staged effects of hooks are erased by `reset --quiet`; binary and deleted files are whole only; why the dialog does not reuse `LocalChangesModel.rows` (that path turns a binary file into "every HEAD line removed"); a file differing only in line endings has zero units; all three "whole only" categories show a placeholder in the right-hand panel rather than a diff with unclickable checkboxes; `splitLines` is a projection of `TerminatedLines`, and their consistency fuzz test stands as a lock against a second independent implementation coming back; "nothing selected = HEAD" is the builder's invariant, while "everything selected = worktree" is a structural guarantee of the plan (the file bypasses the builder), not a property of the builder
- [x] extend `README.md`: commit from the app, per-line selection, amend, push after commit, author editing

## Post-Completion (manual verification on a real repository)
- a partial commit of a few lines: `git show` shows exactly those, the worktree and Local Changes untouched
- a whole commit of several files; untracked / deleted / renamed
- a binary file — whole only, a placeholder instead of the diff in the right-hand panel, content byte-identical after the commit
- a file binary in HEAD and text in the worktree (e.g. unpacked in place) — the dialog offers whole only, with no per-line checkboxes
- a file differing only in line endings — the "committed as a whole" placeholder, zero units
- a whole commit of a file with mixed line endings — the worktree bytes are preserved (the builder is bypassed)
- initial commit (unborn HEAD); amend (lines + message — one commit in `git log`); message-only amend
- push creating an upstream; push with an unreachable remote → "commit created, push failed"
- a failing pre-commit hook → error, the repository untouched; a hook invoking external tools finds them (the environment is not wiped)
- identity unset → editing writes the local config; the global one is unchanged
- `git add` from the terminal + a commit from the UI → what the UI selected is what got committed
- during a merge (both with conflicts and after resolving) Commit is blocked with a reason

## Out of scope
Force push and its confirmations; the "amending an already-pushed commit" warning; creating a merge commit from the UI (finishing a merge stays a console job); message history and templates; GPG signing; changelists; per-line revert (an obvious follow-up on top of the same builder); iOS.

