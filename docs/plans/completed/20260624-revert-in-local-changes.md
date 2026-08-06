# Revert in Local Changes

## Overview

Let the user discard local changes from the Local Changes panel — revert one or
more changed files back to their `HEAD` version (deleting a reverted untracked
file, which has no `HEAD` version). The action is destructive and irreversible,
so it is always confirmed first, and any open tab for a reverted file is kept in
sync with the new on-disk contents (reloaded, or closed if the file was deleted).

Follows the project's strict split: all logic and state live in `PisakaCore`
(`LocalChangesModel`, `WorkspaceModel`, the `GitServicing` protocol) and are
unit-tested; the SwiftUI/AppKit/`Process` glue stays thin in `Pisaka` and is not
unit-tested, per convention.

## Context

- Files involved:
  - Modify: `Sources/PisakaCore/GitServicing.swift` — add `revert(_:root:)`.
  - Modify: `Sources/PisakaCore/LocalChangesModel.swift` — `revertSelection`,
    `toggleChecked`, `filesToRevert(contextFile:)`, `revert(_:)`.
  - Modify: `Sources/PisakaCore/WorkspaceModel.swift` — `reloadFromDisk(id:)`.
  - Modify: `Sources/Pisaka/GitCLIService.swift` — real `Process`/`FileManager`
    revert.
  - Modify: `Sources/Pisaka/LocalChangesView.swift` — per-row checkbox + context
    menu Revert item.
  - Modify: `Sources/Pisaka/PisakaApp.swift` — `revertChanges(contextFile:)`
    orchestration.
  - Modify: `Sources/Pisaka/FilePanels.swift` — confirm-revert `NSAlert`.
  - Modify: `Tests/PisakaCoreTests/LocalChangesModelTests.swift` — extend
    `StubGit` to record/fail `revert`; new model tests.
  - Modify: `Tests/PisakaCoreTests/WorkspaceModelTests.swift` — `reloadFromDisk`
    tests.
  - Modify: `CLAUDE.md`, `README.md`.
- Related patterns:
  - Protocol-behind-injectable-stub split (`GitServicing`/`FileServicing`): pure
    declaration in Core, `Process`-backed impl in `Pisaka`, in-memory stub in
    tests.
  - `LocalChangesModel.refresh(root:)` already re-binds/clears selection and
    surfaces failures via `errorMessage` — revert reuses `refresh` and the same
    `errorMessage` channel.
  - `ChangedFileRow` (in `LocalChangesView`) is the row used by both flat and
    by-folder modes — the checkbox + context menu added there cover both.
  - `FilePanels.confirmClose` is the model for the destructive-confirm `NSAlert`.
- Dependencies: none new. Core stays Foundation-only; the `Process`/`FileManager`
  work stays in `Pisaka`.

## Development Approach

- **Testing approach**: Regular (code first, then tests) — matches the existing
  `LocalChangesModelTests`/`WorkspaceModelTests` style.
- Complete each task fully (code + tests + green suite) before the next.
- **CRITICAL: every Core change ships with new/updated `PisakaCore` tests; the
  full `swift test` suite must pass before starting the next task.**
- The view/orchestration layer (`LocalChangesView` checkbox/menu, `PisakaApp`,
  the `NSAlert`, `GitCLIService.revert`) is intentionally thin and not
  unit-tested.

## Implementation Steps

### Task 1: `GitServicing.revert` + real `GitCLIService` implementation

**Files:**
- Modify: `Sources/PisakaCore/GitServicing.swift`
- Modify: `Sources/Pisaka/GitCLIService.swift`
- Modify: `Tests/PisakaCoreTests/LocalChangesModelTests.swift`

- [x] Add `func revert(_ file: ChangedFile, root: URL) throws` to the
  `GitServicing` protocol, with a doc comment describing the destructive,
  per-status behavior (restore-from-`HEAD` for tracked files; delete for the
  no-`HEAD` cases).
- [x] Implement it in `GitCLIService` using the existing `run(_:in:)` plumbing
  plus `FileManager`, dispatching on `file.status`:
  - `.modified`, `.deleted`: `git checkout HEAD -- <path>` (restores index +
    working tree from `HEAD`).
  - `.renamed`: restore the original via `git checkout HEAD -- <oldPath>` and
    remove the new path (`git rm -f -- <path>`), so both sides of the rename are
    undone.
  - `.added`: `git rm -f -- <path>` (unstage + remove the working file — it has
    no `HEAD` version).
  - `.untracked`: `FileManager.default.removeItem(at: root/path)` (git does not
    track it).
  - Throw `GitError` on a non-zero git exit so the model can surface it.
- [x] Extend `StubGit` in the test file: record `revertedFiles: [ChangedFile]`
  and add a `revertError: Error?` to simulate a failure; implement
  `revert(_:root:)` to append (or throw).
- [x] Run `swift build` and `swift test` — suite must pass (the existing stub now
  satisfies the protocol) before Task 2.

### Task 2: `LocalChangesModel` revert state + logic

**Files:**
- Modify: `Sources/PisakaCore/LocalChangesModel.swift`
- Modify: `Tests/PisakaCoreTests/LocalChangesModelTests.swift`

- [x] Add `@Published public private(set) var revertSelection: Set<String> = []`
  (checked file ids) and `func toggleChecked(_ file: ChangedFile)` (insert/remove
  `file.id`).
- [x] Add `func filesToRevert(contextFile: ChangedFile) -> [ChangedFile]` — pure
  resolution: if `contextFile.id` is in `revertSelection`, return all current
  `changedFiles` whose id is checked; otherwise return `[contextFile]`.
- [x] Add `@discardableResult func revert(_ files: [ChangedFile]) -> [URL]` —
  guard `root`; for each file call `try gitService.revert(file, root: root)` and
  collect `root.appendingPathComponent(file.path)`; on a thrown error set
  `errorMessage` (and stop), else clear it; then `refresh(root: root)` (which
  drops the reverted files and re-binds/clears the selection), clear
  `revertSelection`, and return the collected URLs.
- [x] Tests: `toggleChecked` adds then removes an id; `filesToRevert` returns the
  checked set when the context file is checked and just the context file
  otherwise; `revert` calls `gitService.revert` once per file (assert via
  `StubGit.revertedFiles`), refreshes (changed files updated from the stub),
  clears `revertSelection`, and returns the reverted URLs; exercise the untracked
  branch and a `revertError` path (sets `errorMessage`, does not crash).
- [x] Run `swift test` — must pass before Task 3.

### Task 3: `WorkspaceModel.reloadFromDisk(id:)`

**Files:**
- Modify: `Sources/PisakaCore/WorkspaceModel.swift`
- Modify: `Tests/PisakaCoreTests/WorkspaceModelTests.swift`

- [x] Add `@discardableResult func reloadFromDisk(id: UUID) -> Bool` — look up the
  open file; no-op returning `false` for an unknown id or a url-less (Untitled)
  buffer; read via `fileService.read(url:)`; on success replace both `text` and
  `savedText` (so `isDirty` clears) and return `true`; on a read failure leave the
  buffer untouched and return `false` (reported, not fatal).
- [x] Tests: reload replaces `text`/`savedText` and the file becomes not-dirty;
  unknown id and url-less file are no-ops (return `false`); a read failure (stub
  `read` throws) returns `false` without crashing and leaves the buffer unchanged.
- [x] Run `swift test` — must pass before Task 4.

### Task 4: View layer — checkbox, context menu, app orchestration, confirm alert

**Files:**
- Modify: `Sources/Pisaka/FilePanels.swift`
- Modify: `Sources/Pisaka/LocalChangesView.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] `FilePanels`: add `confirmRevert(fileNames: [String]) -> Bool` — an
  `NSAlert` (warning style) listing the affected files in `informativeText`, with
  destructive "Revert" + "Cancel" buttons, returning `true` only on Revert. Mirror
  the `confirmClose` style.
- [x] `LocalChangesView`: give `ChangedFileRow` (and the by-folder
  `ChangeNodeView` leaf) a leading checkbox bound to whether the file's id is in
  `model.revertSelection`, toggling via `model.toggleChecked(file)`; add a
  `.contextMenu` with a **Revert** item that calls a new `onRevert(file)`
  callback. Thread `onRevert` from `LocalChangesView` down through the rows.
- [x] `PisakaApp`: add `revertChanges(contextFile:)`:
  1. `let files = localChanges.filesToRevert(contextFile: contextFile)`.
  2. Confirm via `FilePanels.confirmRevert(fileNames:)`; on cancel, return before
     any mutation.
  3. `let reverted = localChanges.revert(files)`.
  4. For each reverted `url`, find the matching open tab by url; if the file still
     exists on disk (`FileManager.default.fileExists`), `model.reloadFromDisk(id:)`,
     otherwise `model.close(id:force: true)`.
- [x] Wire `onRevert` from `PisakaApp` → `ContentView` → `LocalChangesView`
  (same shape as the existing `onOpenFile`/`onOpenFolder` callbacks).
- [x] Run `swift build` to confirm the app target compiles (view layer is not
  unit-tested).

### Task 5: Verify acceptance criteria

- [x] Run the full `swift test` suite — all green.
- [x] Run `swift build` — the `Pisaka` app target compiles with no warnings from
  the changed files.
- [x] Confirm new Core code (model revert/selection, `reloadFromDisk`) is covered
  by the new tests.

### Task 6: Update documentation

- [x] `CLAUDE.md`: document `GitServicing.revert`, `GitCLIService.revert`'s
  per-status `Process`/`FileManager` behavior, `WorkspaceModel.reloadFromDisk`,
  and the `LocalChangesModel` additions (`revertSelection`, `toggleChecked`,
  `filesToRevert`, `revert`); note the checkbox + context-menu + mandatory
  confirmation flow and the post-revert open-buffer sync in the view layer.
- [x] `README.md`: mention revert (discard local changes for selected files) in
  the Local Changes feature description.

## Out of scope (YAGNI)

- Reverting individual lines/hunks; undo of a revert; a dedicated "revert all"
  button (multi-select checkboxes cover it); drag-and-drop or keyboard shortcuts
  for revert.
