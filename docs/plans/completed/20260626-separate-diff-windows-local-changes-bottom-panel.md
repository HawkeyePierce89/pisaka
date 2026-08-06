# Separate diff windows + Local Changes bottom panel + panel-height fix

## Overview

Three related bottom-dock UX changes, almost entirely in the `Pisaka` view layer,
reusing the existing `LineDiff`/`DiffView` and the models' already-tested async row
methods:

1. Panel height persists across panel switches and hide/show (replace the recreated
   `VSplitView` with a manual editor + draggable-divider + fixed-height-panel layout
   backed by `@State`).
2. Local Changes becomes a third bottom-dock panel (beside Terminal and Git Log),
   rendered as a file list; the left "Project ⇄ Changes" segmented toggle and the
   editor-area inline diff are removed.
3. A file's diff opens in an independent, non-modal `NSWindow` on double-click — for
   both Local Changes rows and a commit's files in Git Log. Inline diff panes are
   removed; multiple windows allowed; all closed on app termination.

The only new `PisakaCore` surface is `BottomPanel.changes` plus a small pure
window-title builder (both unit-tested). No new git logic.

## Context

- Files involved:
  - `Sources/PisakaCore/BottomPanel.swift` — add `.changes` case.
  - New `Sources/PisakaCore/DiffWindowTitle.swift` — pure window-title builder.
  - `Sources/Pisaka/ContentView.swift` — manual panel-height layout; add `.changes`
    to `panelContent`; add the Changes bottom-bar button; remove the left segmented
    toggle, the editor-area inline `DiffPane`, and the right-zone changes branch.
  - New `Sources/Pisaka/DiffWindowController.swift` — owns/retains the diff
    `NSWindow`s, opens one hosting a SwiftUI content view, releases on close, closes
    all on termination.
  - New `Sources/Pisaka/DiffWindowContent.swift` — SwiftUI view that loads
    `[DiffRow]` async (Loading → `DiffView`).
  - `Sources/Pisaka/LocalChangesView.swift` — double-click a row opens the diff
    window (single-click still selects/highlights).
  - `Sources/Pisaka/CommitLogView.swift` — `CommitDetailPane` becomes a files-list
    only; remove `CommitDiffPane`; double-click a file opens the diff window.
  - `Sources/Pisaka/PisakaApp.swift` — own `DiffWindowController`; thread the
    double-click → open-diff callbacks; add a View-menu "Show/Hide Local Changes"
    command; close all diff windows on `willTerminateNotification`.
  - `Tests/PisakaCoreTests/BottomPanelTests.swift` — add `.changes` cases.
  - New `Tests/PisakaCoreTests/DiffWindowTitleTests.swift` — test the title builder.
  - `README.md`, `CLAUDE.md` — documentation.
- Related patterns: `TerminalSessionsModel.terminateAll()` (lifecycle-on-termination);
  `DiffPane`/`CommitDiffPane` `@State` generation-token async recompute (reused as
  the async-load pattern in the window content); the existing callback-threading
  shape (`onOpenFile`/`onRevert`: `PisakaApp → ContentView → subview`);
  `BottomPanel.toggled` purity.
- Dependencies: none new. `DiffView`, `LineDiff`, and the models' row methods are
  unchanged — only their call sites move.

## Development Approach

- **Testing approach**: Regular (code first, then tests). New behavioral logic in
  `PisakaCore` (the `.changes` case, the title builder) is unit-tested; the view
  layer (manual split + drag, `DiffWindowController`, the Changes panel, double-click
  handlers, `CommitDetailPane` as a list) is thin and not unit-tested, per project
  convention.
- Complete each task fully before moving to the next.
- Each view-layer task must keep the full build green and the existing suite passing
  (`swift build` + `swift test`).
- **CRITICAL: every code-modifying task MUST include new/updated tests where there is
  testable `PisakaCore` logic.**
- **CRITICAL: all tests must pass before starting the next task.**
- Decisions made (no further input needed): panel height uses `@State` only (meets
  "persist across switch/hide-show"; cross-launch `@AppStorage` is YAGNI); the
  View-menu Local Changes shortcut is Cmd+Shift+G; duplicate diff windows are allowed
  (reuse/focus is out of scope); the window content takes an `async () -> [DiffRow]`
  closure so it is model-agnostic.

## Implementation Steps

### Task 1: Core — `BottomPanel.changes` + window-title builder + tests

**Files:**
- Modify: `Sources/PisakaCore/BottomPanel.swift`
- Create: `Sources/PisakaCore/DiffWindowTitle.swift`
- Modify: `Tests/PisakaCoreTests/BottomPanelTests.swift`
- Create: `Tests/PisakaCoreTests/DiffWindowTitleTests.swift`

- [x] Add `case changes` to `BottomPanel` (it stays `Equatable`; `toggled(_:selecting:)`
  is generic and unchanged).
- [x] Add a pure `DiffWindowTitle` enum with a static builder, e.g.
  `localChanges(path:) -> String` and `commit(path:hash:subject:) -> String`,
  producing a file-path-plus-context title (path + "Local Changes"; path + short hash
  + subject for a commit). Foundation-only, color/UI-free.
- [x] Extend `BottomPanelTests` with `.changes` cases (collapse on re-select; switch
  from another panel; show from hidden).
- [x] Write `DiffWindowTitleTests` covering both builder cases (including short-hash
  truncation).
- [x] Run `swift test` — must pass before Task 2.

### Task 2: ContentView — panel-height persistence, Changes panel, remove left toggle + inline diff

**Files:**
- Modify: `Sources/Pisaka/ContentView.swift`

- [x] Add `@State private var panelHeight: CGFloat` (sensible default, e.g. 240).
  Replace `mainArea`'s conditional `VSplitView { editorSplit; panelContent(panel) }`
  with a manual `VStack(spacing: 0) { editorSplit; Divider()-with-drag;
  panelContent(panel).frame(height: panelHeight) }`; the divider's `DragGesture`
  updates `panelHeight`, clamped to ~[120, half the window via a `GeometryReader`
  height]. Because `panelHeight` is independent of which panel is shown, it survives
  panel switches and hide/show.
- [x] Add a third "Changes" `bottomBarButton` beside Terminal/Git (e.g.
  `systemImage: "arrow.triangle.pull"`).
- [x] Add `.changes` to `panelContent(_:)` → `LocalChangesView` rendered as a file
  list only, threading `onRevert`/`onOpenDiff`. (Double-click `onOpenDiff` threading
  into `LocalChangesView` completes in Task 4 when that view gains the param; the
  callback is declared on `ContentView` here.)
- [x] Remove the left-zone segmented `Picker` and `LeftPanelMode`; the left zone is
  just `ProjectTreeView` again. Remove the right-zone `if leftPanelMode == .changes …
  DiffPane` branch (right zone is the editor / "No file open" only). Delete the
  now-unused `DiffPane` struct.
- [x] Add an `onOpenDiff: (ChangedFile) -> Void` (Local Changes) and
  `onOpenCommitDiff: (ChangedFile, Commit) -> Void` (Git Log) callback parameters
  with default no-ops, threaded into the panel subviews.
- [x] Run `swift build` and `swift test` — must pass before Task 3.

### Task 3: DiffWindowController + DiffWindowContent (view layer)

**Files:**
- Create: `Sources/Pisaka/DiffWindowController.swift`
- Create: `Sources/Pisaka/DiffWindowContent.swift`

- [x] `DiffWindowContent`: a SwiftUI view taking `fileID: String`, `fileName: String`,
  `title: String`, and a `load: () async -> [DiffRow]` closure. Shows "Loading…" until
  the async load resolves (guarded by a `@State` generation token, mirroring
  `DiffPane`), then renders `DiffView(fileID:fileName:rows:)`. Read-only; independent
  of main-window selection.
- [x] `DiffWindowController` (a `final class`): retains an array/set of open
  `NSWindow`s; `open(title:content:)` creates a non-modal, resizable `NSWindow`
  hosting the content via `NSHostingController`, sets its title, shows it, and
  registers a `windowWillClose` observer/delegate that drops the window from the
  retained set (release on close). Add `closeAll()` (close every retained window) for
  the app-termination path, mirroring `TerminalSessionsModel.terminateAll()`.
  Multiple windows allowed (no dedup).
- [x] Run `swift build` — must pass before Task 4.

### Task 4: Wire double-click → diff window; CommitDetailPane as files-list; app wiring

**Files:**
- Modify: `Sources/Pisaka/LocalChangesView.swift`
- Modify: `Sources/Pisaka/CommitLogView.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] `LocalChangesView`: add `onOpenDiff: (ChangedFile) -> Void`; on each
  `ChangedFileRow` add a double-click (`.onTapGesture(count: 2)`, declared before the
  single-tap select) that calls `onOpenDiff(file)`. Single-click still sets
  `model.selected`. Thread `onOpenDiff` through `ChangeNodeView` too.
- [x] `CommitLogView`: `CommitDetailPane` becomes a files-list only (remove the
  `VSplitView` and the `CommitDiffPane` struct); double-clicking a `CommitFileRow`
  calls a threaded `onOpenCommitDiff(file, commit)`. Keep the async file-list load
  (`changes(for:)`) and its generation-token guard.
- [x] `PisakaApp`: add `private let diffWindows = DiffWindowController()`. Add handlers
  `openLocalChangesDiff(_ file:)` (title via `DiffWindowTitle.localChanges`, load =
  `localChanges.rows(for:)`) and `openCommitDiff(_ file:in commit:)` (title via
  `DiffWindowTitle.commit`, load = `commitLog.rows(for:in:)`), passing them as
  `onOpenDiff`/`onOpenCommitDiff` into `ContentView`. Add a "Show/Hide Local Changes"
  View-menu command (Cmd+Shift+G) routed through `togglePanel(.changes)`. In the
  `willTerminateNotification` observer, also call `diffWindows.closeAll()` alongside
  `terminalSessions.terminateAll()`.
- [x] Run `swift build` and `swift test` — must pass before Task 5.

### Task 5: Verify acceptance criteria

- [x] Run `swift build` — clean compile.
- [x] Run `swift test` — full suite passes (existing `LineDiff`/`DiffView`/model-row/
  `GitStatusParser` tests stand unchanged; new `BottomPanel.changes` and
  `DiffWindowTitle` tests pass).

### Task 6: Update documentation

- [x] `CLAUDE.md`: document `BottomPanel.changes` and `DiffWindowTitle`; the manual
  panel-height persistence in `ContentView`; `DiffWindowController`/`DiffWindowContent`
  and separate diff windows on double-click; Local Changes now a bottom panel and Git
  Log commit detail now a files-list; removal of the left Project/Changes toggle and
  the inline diff panes (`DiffPane`/`CommitDiffPane`).
- [x] `README.md`: Local Changes is now a bottom panel (beside Terminal/Git,
  Cmd+Shift+G); diffs (Local Changes and per-commit) open in a separate window on
  double-click; update the shortcuts table and the feature descriptions accordingly.
