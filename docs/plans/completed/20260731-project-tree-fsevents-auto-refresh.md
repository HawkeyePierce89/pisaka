# Project tree auto-refresh on external changes (FSEvents) + a manual Refresh button

## Overview

The project tree currently re-reads directories only on `WorkspaceModel.treeRevision`, which is bumped after operations performed by the app itself (create / rename / delete, checkout). Changes made by an external process (`npx @nestjs/cli new backend` in the embedded terminal, Finder, `git` in a console) do not show up in the tree until the folder is reopened.

We add two independent mechanisms:

1. **Watcher** — an FSEvents subscription on `projectRoot` (macOS-only) that bumps `treeRevision` on its own. The "is this batch worth a re-read" decision is made by a pure Core filter, `TreeRefreshFilter`, which drops `.git` noise, `.DS_Store`, and paths outside the root.
2. **Refresh button** in the tree header — the fallback (FSEvents buffer overflow, network volumes, "I want it right now").

The existing re-read mechanism is sufficient: `DirectoryNodeView` already observes `treeRevision` (an expanded node re-reads `children(of:)`, a collapsed one drops its cache). No new tree-refresh logic is written.

### Decision on `kFSEventStreamCreateFlagIgnoreSelf` (the review feedback)

Adopted — the stream is created with `kFSEventStreamCreateFlagIgnoreSelf`, and the doc comment records why.

- **What it buys:** self-generated writes never echo back. The app's own create / rename / delete already bump `treeRevision` synchronously, so the echo is pure duplication; more importantly **autosave** writes a file every idle burst / tab switch / focus loss, and under dir-level events each such write reports the containing directory — without the flag that is a recurring bump, i.e. a synchronous `contentsOfDirectory` re-read of every expanded node on the main thread, for a change that never alters the listing. That is the one self-noise source that is frequent rather than incidental.
- **What it does not cost:** the embedded terminal's shell is a *child* process (its own pid), as is every `git` invocation from `GitCLIService`, so their events still arrive normally — the headline case (`npx … new backend`) is unaffected.
- **The one coverage gap it opens, closed in this plan:** `PisakaApp.saveAs(id:)` (`Sources/Pisaka/PisakaApp.swift:445`) writes a *new* file into the project folder and does **not** bump `treeRevision` today — it currently relies on nothing, and without the flag the watcher would have covered it by accident. Task 3 adds the missing `model.bumpTreeRevision()` there, which is the existing convention ("the app bumps after its own successful disk mutation") rather than a new mechanism. After that, every in-app write that changes tree membership bumps explicitly, so `IgnoreSelf` loses nothing. (iOS has no Save As path, so this is macOS-only.)

### Reachability of the filter's rules under the chosen dir-level flags (recorded because it drives the doc comments)

- **`root/.git` rule — live.** Without `kFSEventStreamCreateFlagFileEvents` FSEvents reports the *directory* in which something changed, and a `git commit` in the terminal writes into `root/.git`, `root/.git/objects/xx`, `root/.git/refs/heads` — all same-or-descendant of `root/.git`, so the batch is correctly dropped. This is the rule that makes "`git` in the terminal doesn't flicker the tree" work. (Our *own* git runs are now covered twice: `IgnoreSelf` does not suppress them — they are subprocesses — but this rule does.)
- **outside-the-root rule — live** (FSEvents can deliver such paths around stream move/recreate).
- **`.DS_Store` rule — dormant** under the current flags: the file's own path never arrives; a Finder write to `root/.DS_Store` is reported as the directory `root`, so the batch passes the filter and produces one harmless bump (the listing excludes `.DS_Store`, the children array is unchanged, the UI does not move). The rule is kept as cheap defense-in-depth for a possible future switch to file-level events, and both the doc comment and its tests must say so explicitly rather than implying a behavior production never exercises.

## Context

- **Files involved:**
  - Create: `Sources/PisakaCore/TreeRefreshFilter.swift`
  - Create: `Tests/PisakaCoreTests/TreeRefreshFilterTests.swift`
  - Create: `Sources/Pisaka/ProjectWatcher.swift` (macOS-only)
  - Modify: `Sources/Pisaka/PisakaApp.swift` (watcher ownership, `openFolder()`, `willTerminateNotification`, the `saveAs` bump)
  - Modify: `Sources/Pisaka/ProjectTreeView.swift` (header with the Refresh button)
  - Modify: `CLAUDE.md`, `README.md`
  - Modify (doc comments): `Sources/PisakaCore/WorkspaceModel.swift`, `Sources/PisakaCore/LocalChangesModel.swift` ("the app does not watch the filesystem" — the tree now does, on macOS)
- **Related patterns:**
  - `ScopedFileAccess.path(_:isWithin:)` (`Sources/PisakaCore/ScopedFileAccess.swift:64`) — same-or-descendant over string paths with trailing-slash normalization; the filter reuses it instead of duplicating the logic.
  - `ScopedFileAccess` / `FileIcon` / `LineDiff` — "pure testable math in Core, IO in the view layer".
  - `AutosaveController` — a thin, untested view-layer class with an idempotent `start(...)` / `stop()` / `deinit`; `ProjectWatcher` copies that shape.
  - `DiffWindowController` / `MergeWindowController` — a `private let` in `PisakaApp` plus teardown on `willTerminateNotification`.
  - The `arrow.clockwise` button in the `LocalChangesView` header (`Sources/Pisaka/LocalChangesView.swift:59`) — the prototype for the Refresh button.
  - `#if os(macOS)` wrapping the whole file — every macOS-only `Sources/Pisaka/*.swift`.
- **Dependencies:** none new. FSEvents comes from `CoreServices` (a system framework), imported only in `ProjectWatcher.swift`; `PisakaCore` stays Foundation-only.

## Development Approach

- **Testing approach**: TDD for Core (`TreeRefreshFilter`) — tests are written first and must fail for the expected reason (missing type / wrong decision), then the implementation.
- The view layer (`ProjectWatcher`, the `PisakaApp` integration, the `ProjectTreeView` button) is, per project convention, not covered by unit tests (all decision logic lives in the Core filter); its verification is green macOS and iOS builds plus the manual run-through in the Post-Completion section.
- Complete each task fully before moving to the next; `swift test` must be green before starting the next task.
- No settings/toggles, no keyboard shortcut or menu item for Refresh, iOS out of scope.

## Implementation Steps

### Task 1: Core — TreeRefreshFilter (TDD)

**Files:**
- Create: `Tests/PisakaCoreTests/TreeRefreshFilterTests.swift`
- Create: `Sources/PisakaCore/TreeRefreshFilter.swift`

- [x] Write `TreeRefreshFilterTests` first, covering every acceptance case:
  - a batch made only of `root/.git/...` → `false`;
  - a mixed batch (`root/.git/objects` + `root/src`) → `true`;
  - `.DS_Store` only (at the root and in a nested folder) → `false`;
  - a path equal to `root` itself → `true` (the root's contents changed);
  - a nested foreign `root/deps/foo/.git` → `true` (part of the project);
  - a path outside `root` → `false`;
  - trailing slashes on batch paths (FSEvents reports directories with a slash) — for the `.git` ignore, for `.DS_Store`, and for the inside-the-root check;
  - an empty batch → `false`;
  - plus a "false prefix match" case: `root/.gitignore` and `root/.github` must not count as `.git` (normalization must go through `path(_:isWithin:)`, not `hasPrefix`).
- [x] The `.DS_Store` cases carry a comment stating what they actually assert: file-level-event behavior. Under the watcher's current dir-level flags such a path never arrives (a Finder `.DS_Store` write is reported as the containing directory), so these tests guard a dormant defense-in-depth branch, not a production path — see the doc comment.
- [x] Confirm the tests fail for the expected reason (type missing / behavior not implemented).
- [x] Implement `public enum TreeRefreshFilter { public static func shouldRefresh(changedPaths: [String], root: URL) -> Bool }`:
  - `true` if at least one path in the batch is not ignored; an empty batch → `false`;
  - ignored: same-or-descendant of `root/.git` (only the opened root's top-level `.git`), a last component of `.DS_Store`, and any path that is not same-or-descendant of `root`;
  - same-or-descendant goes through the existing `ScopedFileAccess.path(_:isWithin:)` (it already normalizes a trailing slash); the last component is taken after trailing-slash normalization;
  - string comparison only, no disk access: the filter must stay pure (an FSEvents callback has no business touching the filesystem).
- [x] Doc comment records the decisions, per-rule, including which of them the current watcher can actually trigger:
  - `root/.git` — live under dir-level events (`git` writes land in `root/.git/**`, which is reported as those directories); only the opened root's top-level `.git` is ignored, since a nested `deps/foo/.git` is part of the visible tree;
  - outside-the-root — live; ignored because FSEvents can deliver such paths when the stream is moved/recreated, and they are not our project;
  - `.DS_Store` — dormant with the watcher's dir-level flags: the `.DS_Store` file's own path is never delivered (the containing directory is reported instead), so a Finder write still passes the filter and causes one harmless bump; the rule is kept only as defense-in-depth should the stream ever switch to `kFSEventStreamCreateFlagFileEvents`. State this plainly so the rule is not mistaken for live behavior;
  - the filter deliberately says nothing about *who* produced the event — self-generated writes are excluded at the stream level (`kFSEventStreamCreateFlagIgnoreSelf`, see `ProjectWatcher`), not here, so the filter stays a pure path decision;
  - why the logic lives in Core: testability of the off-by-one-prone path matching; all IO lives in `ProjectWatcher`.
- [x] Foundation-only, no `import CoreServices` and no `#if os(...)`.
- [x] Run `swift test` — fully green.

### Task 2: View — ProjectWatcher (macOS-only)

**Files:**
- Create: `Sources/Pisaka/ProjectWatcher.swift`

- [x] Whole file inside `#if os(macOS)`; imports `Foundation`, `CoreServices`, `PisakaCore`.
- [x] `final class ProjectWatcher` with `start(root: URL, onChange: @escaping () -> Void)`, `stop()`, `deinit → stop()`. A repeated `start` first stops the previous stream (idempotence — the `AutosaveController.start` precedent), so a folder change simply switches the subscription.
- [x] FSEvents stream on `root.path`:
  - directory-level events (no `kFSEventStreamCreateFlagFileEvents`) — knowing "something changed in this directory" is enough, the re-read is per-directory anyway; the doc comment notes the consequence for `TreeRefreshFilter`'s `.DS_Store` rule (dormant, one harmless bump on a Finder write) and that the `.git` rule is unaffected because `git` writes are reported as directories inside `root/.git`;
  - `kFSEventStreamCreateFlagIgnoreSelf` — drop events caused by *this* process. Doc comment records the rationale and the boundaries: our own create/rename/delete already bump `treeRevision` synchronously, and autosave writes would otherwise cause a recurring, listing-identical re-read of every expanded node; the embedded terminal's shell and every `GitCLIService` invocation are child processes with their own pids, so their events are unaffected; and the only in-app write that changes tree membership without a bump (Save As of an Untitled buffer into the project) gets its bump in Task 3, so nothing is lost by the flag;
  - latency `1.0` s, ordinary deferred coalescing (no `kFSEventStreamCreateFlagNoDefer`) — an `npm i` with thousands of events collapses into a handful of firings;
  - `kFSEventStreamCreateFlagUseCFTypes`, `sinceWhen = kFSEventStreamEventIdSinceNow`;
  - the stream runs on its own serial queue (`FSEventStreamSetDispatchQueue`).
- [x] Stream callback: build the batch of paths → `TreeRefreshFilter.shouldRefresh(changedPaths:root:)` → on `true` hop to the main actor → `onChange()`. No other logic in the callback — every decision lives in the Core filter (or, for the self-events, in the stream flags).
- [x] Careful with the C API: `FSEventStreamContext.info` via `Unmanaged` (retain on `start`, release on `stop`); in `stop()` — `FSEventStreamStop` → `FSEventStreamInvalidate` → `FSEventStreamRelease`, then clear the stored reference; `stop()` is idempotent.
- [x] Doc comment following the view-layer file convention: why the class is thin and untested (the `AutosaveController`/`GitCLIService` precedent), why these particular flags/latency were chosen, and that iOS is out of scope (FSEvents is unavailable there).
- [x] No tests, per project convention (view layer; all decision logic is in `TreeRefreshFilter`, covered in Task 1). Verification is compilation in Task 5.
- [x] Run `swift test` — stays green (Core untouched).

### Task 3: View — wire ProjectWatcher into PisakaApp

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] `private let projectWatcher = ProjectWatcher()` next to `diffWindows`/`mergeWindows`, with a doc comment in the neighbors' style.
- [x] In `openFolder()`, after `model.openFolder(url: url)` — `projectWatcher.start(root: url, onChange: { model.bumpTreeRevision() })`; a folder change switches the subscription automatically thanks to the idempotent `start`.
- [x] In the `willTerminateNotification` observer — `projectWatcher.stop()` next to `terminalSessions.terminateAll()` / `closeAll()`, so no streams outlive the app.
- [x] Add `model.bumpTreeRevision()` to `saveAs(id:)` after a successful `model.saveAs(url:for:)` (next to `refreshLocalChanges()`), with a comment: Save As writes a *new* file into the project, and since the watcher ignores self-generated events (`kFSEventStreamCreateFlagIgnoreSelf`) the app must bump for it like every other in-app disk mutation. (The bump is unconditional — a destination outside the open folder just re-reads listings that did not change, and gating on containment would add a path check for no benefit.)
- [x] A comment recording why nothing else is gated: the bump is idempotent and the re-read is read-only; a harmless `.DS_Store`-driven bump and worktree events during a revert (a `git` subprocess, so still delivered) are inert, while the `.git` noise of git operations is dropped by the Core filter — no `isReverting` gate is needed here.
- [x] No tests, per convention (view layer). Verification is compilation in Task 5.
- [x] Run `swift test` — stays green.

### Task 4: View — manual Refresh button in ProjectTreeView

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`

- [x] Add a tree header shown only when a folder is open (`model.projectRoot != nil`), holding a Refresh button (`Image(systemName: "arrow.clockwise")`, `.buttonStyle(.borderless)`, `.help("Refresh project tree")`), modeled on the `LocalChangesView` header; action — `model.bumpTreeRevision()`.
- [x] The call is direct: `ProjectTreeView` already observes `WorkspaceModel`, so no callback threading through `ContentView` is needed.
- [x] The "Click to open a folder" placeholder keeps no header and keeps its whole-pane click target.
- [x] Update the `ProjectTreeView` doc comment: the tree re-reads on `treeRevision`, which is now bumped by the app's own operations, by the watcher, and by this button.
- [x] No new Core tests: the re-read mechanism (`treeRevision` → `DirectoryNodeView`) already exists and is covered, and the button is pure view wiring (project convention).
- [x] Run `swift test` — stays green.

### Task 5: Verify acceptance criteria

- [x] `swift test` — fully green (817 tests, 0 failures).
- [x] `xcodegen generate`, then the macOS build: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build` — green (** BUILD SUCCEEDED **).
- [x] iOS build: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build` — green (** BUILD SUCCEEDED **, run with `CODE_SIGNING_ALLOWED=NO` per the CI convention of an unsigned device-arch build; confirms the `#if os(macOS)` in `ProjectWatcher.swift` holds and iOS does not compile it).
- [x] Grep to confirm `PisakaCore` contains no `import CoreServices` and no `#if os(`, and that `import CoreServices` appears only in `Sources/Pisaka/ProjectWatcher.swift` — all three confirmed.

### Task 6: Update documentation

**Files:**
- Modify: `CLAUDE.md`, `README.md`
- Modify (doc comments): `Sources/PisakaCore/WorkspaceModel.swift`, `Sources/PisakaCore/LocalChangesModel.swift`

- [x] `CLAUDE.md`, `PisakaCore` section: describe `TreeRefreshFilter.swift` (signature, the three ignore rules with the note that `.DS_Store` is dormant under the watcher's dir-level flags, that self-events are excluded at the stream level rather than here, reuse of `ScopedFileAccess.path(_:isWithin:)`, Foundation-only).
- [x] `CLAUDE.md`, `Pisaka` section: add `ProjectWatcher.swift` (FSEvents, dir-level, `IgnoreSelf` and what it does and does not suppress — child processes such as the embedded terminal's shell and `GitCLIService` still deliver events — 1 s latency, its own serial queue, idempotent `start`, teardown), its ownership and call sites in `PisakaApp` (`openFolder` / `willTerminateNotification`), the new `saveAs` bump and why `IgnoreSelf` requires it, and the Refresh button in `ProjectTreeView`.
- [x] Grep `does not watch` and fix the wording at `CLAUDE.md:236` (the `WorkspaceModel`/`treeRevision` section), `CLAUDE.md:668` (`LocalChangesModel`), `Sources/PisakaCore/WorkspaceModel.swift:23`, and `Sources/PisakaCore/LocalChangesModel.swift:453`. Clarify: on macOS the tree watches the filesystem (FSEvents), while Local Changes and open tabs still do not (their snapshot guarantees are unchanged — the per-file re-query in `revert` remains mandatory); on iOS the tree still refreshes only on internal operations.
- [x] `README.md`: in the project-tree description (around line 289) — auto-refresh on external changes on macOS (~1–2 s, including changes made from the embedded terminal) plus the Refresh button ("the watcher is the automatic path, the button is the manual one").
- [x] `README.md`, "MVP 0.1 Limitations" (line 292): fix the "no file-system change detection" / "No automatic file-change detection on disk" bullets — the tree now detects them on macOS; the limitation narrows to Local Changes / Git Log / open tabs, and to iOS.

## Post-Completion (manual verification, macOS — outside the automatable checklists)

- `npx @nestjs/cli new backend` in the embedded terminal → the `backend` folder appears in the tree on its own within ~1–2 s (confirms `IgnoreSelf` does not suppress the child shell's events).
- Deleting/renaming from outside (Finder, console) — the tree catches up the same way.
- `git commit` / `git status` in the embedded terminal (they write only into `.git`) → no re-read is triggered; the tree does not flicker.
- Typing in a file and letting autosave fire → no tree re-read at all (the self-event is dropped by `IgnoreSelf`, before the filter).
- Save As of an Untitled buffer into the open project folder → the new file appears in the tree immediately (the explicit bump, since the watcher ignores our own write).
- Finder `.DS_Store` noise: expect a *harmless bump* rather than "no reaction" — under dir-level events the containing directory is reported, so the filter passes it, the directory re-reads, and nothing visibly changes (the listing excludes `.DS_Store`). Check only that the tree does not visibly move; do not expect the filter to suppress it.
- Switching the opened folder → events from the old root no longer affect the tree.
- Create a file via Finder → press Refresh → it shows up immediately, without waiting for the watcher.
- The Refresh button is visible only when a folder is open.
- No FSEvents streams remain after the app quits.
