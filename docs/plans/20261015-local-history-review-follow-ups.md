# Local History review follow-ups: the gated recreate-on-restore's record, and a causal rendezvous for the deleted-files listing test

## Overview

The acceptance review of pull request 101 left two findings. This plan closes both, and it changes no behaviour.

**Finding 1: the gated restore. The code is right and the record is wrong.** The review read the gate consult in `restoreFromLocalHistory` (`guard !revertInFlight() else { return }`) as a silent return. It is not one. `revertInFlight()` (`Sources/Pisaka/PisakaApp.swift`, `private func revertInFlight() -> Bool`) calls `PlatformFeedback.warning()` and runs the modal "Git operation in progress" alert before it returns `true`. So a Restore into a missing path while a gated operation runs already beeps, explains and stops, creating nothing and opening nothing. That is the same treatment as every other gated refusal in the app, the project tree's included (`mayBeginFileOperation: { !revertInFlight() }`). Adding a `PlatformFeedback.warning()` at the restore's consult site would make it beep twice and break the shared vocabulary, so the code does not change.

What is wrong is the record. Two places describe the gated restore as silent:

- `docs/architecture/core-local-history.md`, restore entry: "consults `revertInFlight()` and stops silently if a gated operation holds the gate".
- `docs/FEATURES.md`, Local History bullet: "A restore that would recreate a file while a git operation is running does nothing."

Both are corrected. A new source-gating pin keeps the corrected sentence true: the gate the restore consults is the helper that beeps and explains. The project tree's refusals are untouched, as the ticket requires; they were never silent either. Only comment lines change in `PisakaApp.swift`, and `file_length` ignores comment-only lines (`type_body_length` ignores comments too), so the 1935 and 1919 ceilings do not move. Task 1 measures this rather than assuming it.

**Finding 2: the timed window.** `testWaitingForQueuedWritesListsAFileDeletedJustBefore` in `LocalHistoryModelTests` has three problems:

- it spins on `Task.yield()` until its listing task has started;
- it then sleeps in 5 ms steps across a 200 ms deadline, asserting the listing has not finished;
- it needs a test-local `ListingProgress` class for the flags it polls.

The restated test reaches a deterministic causal proof without touching the shared stub. Two facts make that possible:

- `LocalHistoryBrowserModel` does all its reads on one serial `DispatchQueue` (`offMain`).
- The listing task's body runs on the main actor without a suspension between its first statement and the listing's first real suspension.

The test gets a signal from inside the listing task, so by the time it resumes, the listing has either parked on the capture chain (correct) or put its store read on the browser's serial queue (the regression). It then asks the plain, non-awaiting `deletedPaths(root:)` while the capture is still held. That call still proves its own half (it answers `[]`), and because it goes through the same serial queue, its return is a barrier. A non-waiting awaiting form's read would already have run against the empty store and answered `[]`. After the gate is released, the awaiting listing must answer `["gone.swift"]`. A regression fails that assertion deterministically, not probabilistically, and every wait is on a signal that must arrive, through `XCTestExpectation` with a timeout.

One deviation from the ticket: the non-awaiting call moves from before the listing starts to after it. It is still asked while the capture is held, so the half it proves is unchanged, and the new position is what lets it serve as the barrier. `StubFileTree` gets no addition, because ordering is proven through the browser's own serial queue rather than through a new journal or a path-keyed listing gate.

## Context

- Files involved:
  - `Sources/Pisaka/PisakaApp.swift`: `restoreFromLocalHistory(_:)` doc comment only (the sentence "consults the writer gate the way the tree's own create does and stops when a git operation holds it"). `revertInFlight()` is read and left alone.
  - `Tests/PisakaCoreTests/LocalHistorySourceGatingTests.swift`: new pin and the suite header's item 5.
  - `Tests/PisakaCoreTests/LocalHistoryModelTests.swift`: the restated test, removal of `ListingProgress`, the suite header.
  - `docs/architecture/core-local-history.md`: the restore entry (around "stops silently") and the Tests section's `LocalHistoryModelTests` sentence ("A delete capture held on the chain is not yet listed by `deletedPaths`, and is listed by `deletedPaths(root:awaiting:)` once the chain is released."), plus the `LocalHistorySourceGatingTests` inventory line if that section lists the suite's pins.
  - `docs/FEATURES.md`: the Local History bullet's last sentence about the gated recreate.
  - Read, not changed: `.swiftlint.yml` (the 1935/1919 ceilings and their reasoning paragraphs, which do not restate the silent behaviour), `docs/architecture/style-lint.md`, `Sources/PisakaCore/LocalHistoryBrowserModel.swift` (`deletedPaths(root:awaiting:)`, `offMain`, the serial `queue`), `Sources/PisakaCore/LocalHistoryModel.swift` (`waitForQueuedWrites()`, `chain`, `pruneStore()`), `Tests/PisakaCoreTests/Support/StubFileTree.swift` (`Gate`, `listingGate`).
- Related patterns:
  - The source-gating suites' `code(ofFileNamed:under:)` / `body(of:in:)` / `offsets(of:in:)` / `occurrences(of:in:)` helpers, which match against comment- and literal-stripped text.
  - The suite's existing causal rendezvous (`holdChain` on `listingGate`, `Gate.waitUntilReached()`, `drain`).
  - `testCaptureBeforeOperationWithNothingToCaptureDoesNotJoinTheChain`'s use of an `expectation` plus `fulfillment(of:timeout:)` as the loud-failure timeout.
- Dependencies: none.

## Development Approach

- **Testing approach**: Regular (code first, then tests). Task 2 additionally proves its test can fail by temporarily disabling the wait it pins.
- Complete each task fully before moving to the next.
- No behaviour changes: no change to what is captured, listed, migrated or restored, and no change to any gate's feedback.
- Every `xcodebuild` uses `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build`, never a folder inside the repository and never a new one.
- No brand or product names of other editors anywhere: plan, code, comments, docs, commit messages.
- Commit messages follow the repository's existing style.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Correct the record of the gated recreate-on-restore, and pin it

**Files:**
- Modify: `docs/architecture/core-local-history.md`
- Modify: `docs/FEATURES.md`
- Modify: `Sources/Pisaka/PisakaApp.swift` (doc comment only)
- Modify: `Tests/PisakaCoreTests/LocalHistorySourceGatingTests.swift`

- [ ] In `core-local-history.md`'s restore entry, replace "consults `revertInFlight()` and stops silently if a gated operation holds the gate" with wording that says what happens: the consult beeps and shows the "Git operation in progress" notice through `revertInFlight()`, the same refusal every gated operation gives, and stops, creating nothing and opening nothing. Keep the rest of the sentence (the create obeys the gate the way the tree's own create does, and consults it without raising it). Leave the known-limits section as it is.
- [ ] In `FEATURES.md`'s Local History bullet, replace "A restore that would recreate a file while a git operation is running does nothing." with a sentence saying it is refused with the same "Git operation in progress" notice (and its beep) as the other gated file operations, and creates nothing. Do not touch the session-restore paragraph's "Restore is silent", which is about a different feature.
- [ ] In `restoreFromLocalHistory(_:)`'s doc comment in `PisakaApp.swift`, make the gate sentence say the refusal beeps and explains through `revertInFlight()` (for example: "and stops — beeping and explaining, through `revertInFlight()` — when a git operation holds it"). Change comment lines only, with no code line added, removed or moved. The existing pins (`isMissing(` before the refusal, the refusal and `revertInFlight()` before the one `createFile(`) must keep passing unedited.
- [ ] Measure rather than assume. Run `swiftlint lint --strict` and confirm `PisakaApp.swift` is still clean at `file_length` 1935 and `type_body_length` 1919. If the measurement differs, which is not expected because only comment-only lines changed, move both ceilings by the measured amount, update `LintConfigurationTests`' pinned numbers and `style-lint.md`'s ceiling history, and add one clause to each ceiling's reasoning paragraph in `.swiftlint.yml` in the established "measured, never rounded up for room" manner. Otherwise leave all four untouched.
- [ ] Add a new test to `LocalHistorySourceGatingTests`; do not edit `testTheRestoresRecreateRefusesFirstAndConsultsTheGateBeforeItCreates`. Call it, for example, `testTheRestoresGateIsTheOneThatBeepsAndExplains`. It asserts three things:
  - `revertInFlight()`'s body (`body(of: "private func revertInFlight(", in: app)`) contains `PlatformFeedback.warning()` and `.runModal()`, so the record's claim that the gated restore beeps and explains cannot silently go stale;
  - `restoreFromLocalHistory`'s body does not read `localChanges.isReverting` directly, which would bypass the feedback;
  - `restoreFromLocalHistory`'s body contains no `PlatformFeedback.warning()` between the `revertInFlight()` offset and the `createFile(` offset, so a second beep cannot be added at the consult site.

  Match against the comment- and literal-stripped text, like the suite's siblings. Each message states the reason, so the rule is not weaker than its comment.
- [ ] Extend the suite header's item 5 by one clause stating the new pin: the gate the restore consults is the helper that beeps and explains, and nothing beeps a second time beside it.
- [ ] If `core-local-history.md`'s Tests section inventories `LocalHistorySourceGatingTests`' pins, add the new pin there.
- [ ] Run `swift test`. It must pass before Task 2.

### Task 2: Restate the queued-writes test as a causal barrier

**Files:**
- Modify: `Tests/PisakaCoreTests/LocalHistoryModelTests.swift`
- Modify: `docs/architecture/core-local-history.md`

- [ ] Restate `testWaitingForQueuedWritesListsAFileDeletedJustBefore` with this shape:
  - `let gate = await holdChain(model, tree)`, as today;
  - `model.captureBeforeDelete(of: projectFile("gone.swift"), root: projectRoot, bufferTexts: [:])`;
  - `tree.files["project/gone.swift"] = nil`;
  - create two expectations, `started` and `listed`;
  - `let listing = Task { @MainActor in started.fulfill(); let paths = await browser.deletedPaths(root: projectRoot, awaiting: model); listed.fulfill(); return paths }`;
  - `await fulfillment(of: [started], timeout: 5)`;
  - then the non-awaiting `let early = await browser.deletedPaths(root: projectRoot)` with `XCTAssertEqual(early, [], …)`, still asked while the capture is held;
  - `gate.release()`;
  - `await fulfillment(of: [listed], timeout: 5)`;
  - `let deleted = await listing.value`;
  - `XCTAssertEqual(deleted, ["gone.swift"], …)`.
- [ ] Remove the `while !progress.started { await Task.yield() }` spin, the 200 ms deadline loop with its `Task.sleep`, the `XCTAssertFalse(progress.finished, …)`, and the `ListingProgress` class, which has no other user. Restore `holdChain`'s doc comment to sit directly above `holdChain`. Today the line "Hold the chain on the store sweep's first listing, so the main actor can mutate the stub tree while nothing on the chain is touching it." is separated from it by `ListingProgress`.
- [ ] Rewrite the test's doc comment to explain the rendezvous the way its siblings do:
  - The listing task signals from its first statement, and its body runs on the main actor with no suspension between that signal and the listing's first real suspension. So when the test resumes, the awaiting form has either parked on the capture chain or put its store read on the browser model's serial queue.
  - The plain form is then asked while the capture is held. It answers `[]`, which proves its half, and because it reads through the same serial queue its return is a barrier: an awaiting form that did not wait would already have read the empty store and answered `[]`.
  - The release and the final assertion that the awaiting form lists `gone.swift` therefore fail deterministically on that regression, with no window of time anywhere.
  - Both expectations fail loudly on timeout instead of hanging.
- [ ] Update the suite header ("Nothing here sleeps: the one test that has to observe work in flight holds it on `StubFileTree.readGate` …") so it stays true. Name the second rendezvous: the queued-writes test's barrier through the browser model's serial queue.
- [ ] Prove the test can fail. Temporarily delete `await capture?.waitForQueuedWrites()` from `LocalHistoryBrowserModel.deletedPaths(root:awaiting:)`, then run `swift test --filter LocalHistoryModelTests/testWaitingForQueuedWritesListsAFileDeletedJustBefore` several times (for example five) and confirm it fails every time on the `["gone.swift"]` assertion. Restore the line, then confirm `git diff Sources/PisakaCore` is empty and the test passes.
- [ ] Confirm `grep -nE "Task\.sleep|Task\.yield|Date\(\)\.addingTimeInterval" Tests/PisakaCoreTests/LocalHistoryModelTests.swift` finds nothing.
- [ ] In `core-local-history.md`'s Tests section, replace the `LocalHistoryModelTests` sentence "A delete capture held on the chain is not yet listed by `deletedPaths`, and is listed by `deletedPaths(root:awaiting:)` once the chain is released." with one that describes the causal shape. The non-awaiting form, asked while the capture is held, answers `[]`. Its return through the browser model's serial queue is the barrier behind which an awaiting form that did not wait would already have answered. The awaiting form, started before it, lists the deleted file once the chain is released. There is no timed window.
- [ ] Run `swift test`. It must pass before Task 3.

### Task 3: Verify acceptance criteria

- [ ] Run `swift test`; the full suite passes, including `LintConfigurationTests` and `LocalHistorySourceGatingTests` with the existing restore pin unedited.
- [ ] Run `swiftlint --strict` from the repository root; clean.
- [ ] Run `xcodegen generate`, then `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build test`; the app-layer bundle passes.
- [ ] Run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -configuration Release -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build build` and `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build build`; both succeed.
- [ ] Run `grep -n -i "stops silently\|does nothing" docs/architecture/core-local-history.md docs/FEATURES.md` and confirm no hit describes the gated restore.
- [ ] Confirm `git diff --stat` touches only the files named in Tasks 1–2, with no Core source file and no code line of `PisakaApp.swift` changed.

### Task 4: Update documentation

- [ ] Confirm every documentation entry touched in Tasks 1–2 is consistent: the restore entry and the Tests inventory in `core-local-history.md`, and the Local History bullet in `FEATURES.md`. If Task 1 had to move the ceilings, also check `style-lint.md` and `.swiftlint.yml`.
- [ ] README.md: no change. Its Local History lines do not describe the gated refusal.
- [ ] CLAUDE.md: no change. No pattern, file or invariant changes, and the cross-cutting Local History bullet makes no claim about the gated restore's feedback.

## Post-Completion

*Items requiring manual intervention; no checkboxes, informational only.*

**Manual verification** (Debug build only, never a Release build under the user defaults):

- Start a long gated operation (a branch switch on a repository with many changed files, or a revert). While it runs, click Restore on a revision of a deleted file. Expect the beep and the "Git operation in progress" notice; no file appears in the tree, no tab opens, and the Local History window stays as it was. After the operation finishes, the same click recreates the file and restores into it. The notice was already part of this refusal before this change; the ticket's criterion named only the beep.
- New File, Rename, Delete and drag-and-drop under the gate behave exactly as before: beep plus the same notice.
