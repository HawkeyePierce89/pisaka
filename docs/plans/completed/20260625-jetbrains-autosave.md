# JetBrains-style Autosave

## Overview

Add JetBrains-like autosave to Pisaka: a dirty file is written to disk
automatically on four triggers — idle (a short debounce after the last
keystroke), focus loss (the app/window deactivates), tab switch (the selected
file changes), and app termination (Cmd+Q / app quit). Untitled (url-less)
buffers are never autosaved (JetBrains never prompts Save As during autosave);
only files that already have a path and are dirty are written. There is no
user-facing toggle or configurable delay (a fixed idle-delay constant), per the
chosen scope.

Why the fourth trigger is required: `NSApplication.willResignActiveNotification`
does NOT fire when the app is frontmost and quit directly (Cmd+Q) — macOS runs
`applicationShouldTerminate` → `applicationWillTerminate` without deactivating
the app. So focus-loss alone loses every edit made in the last idle-debounce
window (~2 s) before quitting — exactly the data autosave exists to protect. A
termination trigger that flushes synchronously on
`NSApplication.willTerminateNotification` closes that gap. This flush is
synchronous (no debounce, no async hop): the notification is delivered on the
main thread as the run loop ends, the app is about to exit, and
`saveAllDirty()` writes synchronously, so a direct call is the only thing
guaranteed to complete before the process dies.

The testable action — "save every dirty file that has a url, skip the rest" —
lives in PisakaCore (`WorkspaceModel.saveAllDirty()`), fully unit-tested through
the injected `FileServicing` stub. The triggers are inherently AppKit/Combine
concerns (NSApplication notifications, debounce timers, `@Published`
subscriptions) and live in a thin, untested view-layer controller, consistent
with the project's "keep Pisaka views thin / test the logic in Core" convention.

Critical interaction (the real correctness concern): the existing async
git-revert orchestration in `PisakaApp.revertChanges` is built on the assumption
that, while a revert runs git off the main thread, the only writer to disk is the
revert — its resync compares each tab against a pre-revert text snapshot to
decide reload/close. Autosave is a second, uncoordinated disk writer that fires
on a timer / focus-loss / tab-switch. Without coordination it can call
`saveAllDirty()` mid-revert and write a buffer back to disk that the revert is
concurrently discarding (racing `git checkout` on the same file, and corrupting
the snapshot-based resync). So the AutosaveController must be suspendable, and
`revertChanges` must suspend it for the full duration of its revert+resync Task.

## Context

- Files involved:
  - Modify: `Sources/PisakaCore/WorkspaceModel.swift` — add `saveAllDirty() -> [URL]`.
  - Create: `Sources/Pisaka/AutosaveController.swift` — wires the four triggers
    (idle, focus-loss, tab-switch, termination) to `saveAllDirty()` + Local
    Changes refresh, with suspend/resume gating.
  - Modify: `Sources/Pisaka/PisakaApp.swift` — own and start the controller,
    reuse `refreshLocalChanges()`, and bracket `revertChanges` with
    suspend/resume.
  - Modify: `Tests/PisakaCoreTests/WorkspaceModelTests.swift` — tests for
    `saveAllDirty()`.
  - Modify: `README.md`, `CLAUDE.md` — document the feature/pattern.
- Related patterns:
  - `WorkspaceModel.save(for:)` / `markSaved(for:)` — the per-file
    save+baseline-clear logic `saveAllDirty()` generalizes;
    `SaveResult.needsSaveAs` is the url-less signal to skip.
  - `FileServicing` stub injection in `WorkspaceModelTests` for write-failure
    simulation.
  - `PisakaApp.refreshLocalChanges()` — the generation-pinned post-save git
    status refresh to reuse after an autosave writes files.
  - `PisakaApp.revertChanges(contextFile:)` — the in-flight async revert +
    snapshot-based resync the autosave suspension must protect.
- Dependencies: none new. Combine (already in the SwiftUI/Foundation stack) for
  the debounce; AppKit `NSApplication.willResignActiveNotification` for focus
  loss and `NSApplication.willTerminateNotification` for the quit flush.

## Development Approach

- **Testing approach**: Regular (code first, then tests) for Task 1; the
  view-layer controller (Tasks 2–3) has no Core-testable surface beyond
  `saveAllDirty()` — the trigger wiring and suspend/resume gating are view-layer
  concerns (analogous to the untested trigger logic in CodeEditorView/PisakaApp),
  so they carry no Core test.
- Complete each task fully before moving to the next.
- Keep all domain logic in PisakaCore; keep the controller a thin
  trigger→action wiring.
- **CRITICAL: every code task MUST include new/updated tests** (Task 1 carries
  the test coverage for the behavioral change).
- **CRITICAL: all tests must pass before starting the next task.**

## Implementation Steps

### Task 1: Add saveAllDirty() to WorkspaceModel

**Files:**
- Modify: `Sources/PisakaCore/WorkspaceModel.swift`
- Modify: `Tests/PisakaCoreTests/WorkspaceModelTests.swift`

- [x] Add `@discardableResult public func saveAllDirty() -> [URL]`: iterate
  `openFiles`; for each file that `isDirty` and has a non-nil `url`, write `text`
  via `fileService.write(_:to:)` and set `savedText = text`, collecting the saved
  `url`. Skip clean files and url-less ("Untitled") buffers entirely (never
  returns `.needsSaveAs`, never prompts).
- [x] On a per-file write failure (`try`), leave that file untouched (stays
  dirty) and continue with the rest — autosave must never abort the batch or
  surface a modal; the failed file is simply omitted from the returned urls.
- [x] Return the list of urls actually written (empty when nothing was
  dirty/titled), so the caller can refresh Local Changes only when something
  changed and so the method is naturally idempotent.
- [x] Document the method (skip-Untitled rationale,
  write-failure-skips-and-continues, idempotence) in the same comment style as
  `save(for:)`.
- [x] Write tests: saves multiple dirty titled files (correct urls returned, all
  become not-dirty); skips clean files; skips a dirty url-less buffer (stays
  dirty, not in result); a second call returns `[]` and writes nothing
  (idempotent); a stubbed write failure for one file leaves it dirty while the
  others save and are returned; verifies bytes written match each file's `text`.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: AutosaveController with the four triggers and suspend gating

**Files:**
- Create: `Sources/Pisaka/AutosaveController.swift`

- [x] Create `final class AutosaveController` holding the Combine cancellables
  and the notification observers, with a fixed `idleDelay` constant (e.g. `2.0`
  seconds) and a `start(model:onSaved:)` method (plus `stop()`/`deinit` teardown
  removing observers and cancelling subscriptions).
- [x] Idle trigger: subscribe to `model.$openFiles` with `.debounce(for:
  .seconds(idleDelay), scheduler: DispatchQueue.main)` and call
  `performAutosave`. Note in a comment that `saveAllDirty()` itself mutates
  `openFiles` (sets `savedText`), which republishes `$openFiles` and re-arms the
  debounce — but the re-fire is a no-op write because `saveAllDirty()` is
  idempotent, so the loop terminates; non-keystroke republishes
  (newFile/open/markSaved/reload) likewise cost at most one idempotent re-fire.
- [x] Tab-switch trigger: subscribe to `model.$selectedID.dropFirst()` and call
  `performAutosave` (flushing all dirty files so the previously-edited file is
  written before the new one is shown). Note in a comment that `selectedID` also
  changes on tab *close* (including revert-driven force-closes) — harmless here
  because clean/closed files write nothing (idempotence) and revert-driven closes
  happen while autosave is suspended (see suspend gating).
- [x] Focus-loss trigger: observe `NSApplication.willResignActiveNotification`;
  in the handler hop to the main actor (the model is mutated only on the main
  thread) before calling `performAutosave`.
- [x] Termination trigger (the gap this revision closes): observe
  `NSApplication.willTerminateNotification` and call a synchronous `flushNow()`
  directly in the handler — NOT the debounced idle path and NOT an async
  main-actor hop. `flushNow()` respects the suspend gate, then calls
  `model.saveAllDirty()` synchronously so every dirty titled file is on disk
  before the process exits; it skips `onSaved` (the app is quitting, there is no
  Local Changes UI left to refresh). Note in a comment that
  `willResignActiveNotification` does not fire on a direct Cmd+Q of the frontmost
  app, so without this trigger the last idle-debounce window of edits is lost on
  quit; the notification is delivered on the main thread as the run loop ends, so
  a direct synchronous write is both safe and the only thing guaranteed to
  complete.
- [x] Suspend gating: add a `suspendCount` (a counter, not a boolean, so
  overlapping/nested reverts each balance their own suspend/resume) with
  `suspend()` / `resume()`. Both `performAutosave` and `flushNow` early-return
  while `suspendCount > 0`. This is what keeps autosave from writing to disk
  during an in-flight git revert (which would race `git checkout` and corrupt the
  revert's snapshot-based resync); a quit landing mid-revert is a rare corner
  where the revert's intentional discard wins, which is acceptable.
- [x] `performAutosave`: return early if suspended; otherwise call
  `model.saveAllDirty()` and, when the returned urls are non-empty, invoke the
  `onSaved` closure (Local Changes refresh). Beep at most once if a dirty titled
  file remained unsaved after a write failure (optional, non-modal).
- [x] No unit tests (view-layer trigger + suspend wiring, like
  CodeEditorView/PisakaApp); the behavioral logic is covered by Task 1's
  `saveAllDirty()` tests.

### Task 3: Wire AutosaveController into the app and protect the revert

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] Hold an `AutosaveController` in `PisakaApp` (a stored property, started
  once from the window content's `.onAppear`), and start it passing `model` and
  an `onSaved` closure that calls the existing `refreshLocalChanges()` (reusing
  its generation-pinning rather than duplicating the git status refresh).
- [x] In `revertChanges(contextFile:)`, bracket the revert with the controller:
  call `autosave.suspend()` *synchronously* after the user confirms (right where
  `originGeneration`/`preRevertText` are captured, before the `Task` hop), and
  `autosave.resume()` via `defer` inside the `Task { @MainActor in … }` so it
  always resumes — including the early-bail paths (origin-generation mismatch,
  empty `reverted`). This guarantees no idle/focus-loss/tab-switch autosave fires
  for the full duration of the revert *and* its resync loop. Do not suspend
  before/around the confirm dialog (the modal alert is app-modal and synchronous,
  so no autosave can interleave there, and cancel must not leave autosave
  suspended).
- [x] Verify with `swift build` that the controller starts, autosave fires on
  idle/focus-loss/tab-switch/quit, and a revert suspends/resumes it — without
  regressing manual Save (Cmd+S), the close-confirmation path, or the existing
  revert resync.

### Task 4: Verify acceptance criteria

- [x] Run full test suite: `swift test` — must pass. (270 tests, 0 failures.)
- [x] Run `swift build` — must compile with no new warnings. (Build complete, no
  warnings.)
- [x] Confirm Task 1 tests cover the autosave decision logic (dirty+titled
  saved, untitled/clean skipped, failures skipped, idempotent). (Covered by
  testSaveAllDirtySavesMultipleTitledFiles, testSaveAllDirtySkipsCleanFiles,
  testSaveAllDirtySkipsUntitledBuffer, testSaveAllDirtyIsIdempotent,
  testSaveAllDirtyWriteFailureSkipsFileAndContinues.)

### Task 5: Update documentation

- [x] Update `README.md` feature list with the autosave behavior (auto-saves
  dirty files on idle, focus loss, tab switch, and on quit; Untitled files are
  not autosaved).
- [x] Update `CLAUDE.md`: document `WorkspaceModel.saveAllDirty()` in the
  WorkspaceModel.swift bullet; add an `AutosaveController.swift` bullet under the
  Pisaka target (the four triggers, the synchronous quit flush via
  `willTerminateNotification` and why focus-loss alone misses Cmd+Q, the fixed
  idle delay, idempotent self-retrigger termination, and the suspend/resume
  counter); and note in the PisakaApp.swift bullet that `revertChanges` brackets
  its revert+resync Task with `autosave.suspend()`/`resume()` to keep autosave
  from racing the in-flight git revert.
