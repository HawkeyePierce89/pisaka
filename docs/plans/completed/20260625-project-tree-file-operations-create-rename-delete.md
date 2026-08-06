# Project tree file operations (create / rename / delete)

## Overview

Make the project tree writable from a context menu: New File, New Folder, Rename, Delete. Disk I/O goes behind `FileServicing` in PisakaCore; open-tab reconciliation lives in `WorkspaceModel` (pure, unit-tested); context menus, the name dialog, delete confirmation, and orchestration are thin view-layer wiring in `ProjectTreeView` / `FilePanels` / `PisakaApp`. A renamed file's tab follows the new path, a deleted file's (or folder's nested) tabs close, and the tree refreshes via a published `treeRevision` token without reopening the folder.

## Context

- Files involved:
  - Modify: `Sources/PisakaCore/FileService.swift` (protocol + real impl: createFile/createDirectory/move/removeItem)
  - Modify: `Sources/PisakaCore/WorkspaceModel.swift` (renamePath, closeFiles, treeRevision)
  - Create: `Sources/PisakaCore/FileName.swift` (pure `isValidFileName` helper)
  - Modify: `Sources/Pisaka/ProjectTreeView.swift` (context menus, treeRevision-driven refresh)
  - Modify: `Sources/Pisaka/FilePanels.swift` (promptName + confirmDelete alerts)
  - Modify: `Sources/Pisaka/PisakaApp.swift` (orchestration: prompt/confirm → disk call → model reconcile → treeRevision bump)
  - Modify: `Sources/Pisaka/ContentView.swift` (thread new callbacks through to ProjectTreeView, same shape as onOpenFile/onOpenFolder)
  - Modify/Create tests: `Tests/PisakaCoreTests/` (FileService against temp dir, WorkspaceModel reconciliation, isValidFileName); the existing `FileServicing` test stub gains the four new methods
- Related patterns: `canonicalURL` matching from `fileID(forURL:)` / `open(url:)`; the existing `FileServicing`-behind-stub split; `DirectoryNodeView`'s `@State children` cache + `.id(root)` identity + `startsExpanded`; `FilePanels.confirmClose`-style NSAlert; the `PisakaApp → ContentView → ProjectTreeView` callback threading used by `onOpenFile`/`onOpenFolder`
- Dependencies: none new. Core stays Foundation-only; view layer stays AppKit/SwiftUI.

## Development Approach

- **Testing approach**: Regular (code first, then tests) for the FileService/disk layer; the WorkspaceModel reconciliation and isValidFileName are small and pure, written with tests alongside.
- Complete each task fully before moving to the next.
- **CRITICAL: every Core task includes new/updated PisakaCoreTests**; the view layer (menus, dialog, treeRevision wiring) is intentionally thin and not unit-tested, per project convention.
- **CRITICAL: full `swift test` suite passes before starting the next task.**

## Implementation Steps

### Task 1: FileServicing disk operations

**Files:**
- Modify: `Sources/PisakaCore/FileService.swift`
- Modify: test stub in `Tests/PisakaCoreTests/` (the existing `FileServicing` stub used by WorkspaceModel/LocalChanges tests)

- [x] Add to the `FileServicing` protocol: `createFile(at:) throws`, `createDirectory(at:) throws`, `move(from:to:) throws`, `removeItem(at:) throws`
- [x] Implement in `FileService` via `FileManager`: createFile/createDirectory throw on existing path (and on a missing parent); `move` throws on collision (do not clobber an existing destination); `removeItem` deletes a file or directory tree
- [x] Extend the test stub: record calls and allow simulating per-method success/failure, with defaults so existing tests keep compiling
- [x] Write `FileService` tests against a temp directory: createFile/createDirectory succeed, throw on collision, throw on missing parent; move renames and throws on collision; removeItem deletes a file and a directory tree
- [x] Run `swift test` — must pass before Task 2

### Task 2: Name validation helper

**Files:**
- Create: `Sources/PisakaCore/FileName.swift`
- Create/Modify: `Tests/PisakaCoreTests/FileNameTests.swift`

- [x] Add pure `isValidFileName(_:) -> Bool`: rejects empty/whitespace-only and any name containing a path separator (`/`) or `\0`
- [x] Tests: rejects empty, whitespace-only, and path-separator names; accepts ordinary names and dotfiles
- [x] Run `swift test` — must pass before Task 3

### Task 3: WorkspaceModel tab reconciliation + treeRevision

**Files:**
- Modify: `Sources/PisakaCore/WorkspaceModel.swift`
- Modify: `Tests/PisakaCoreTests/WorkspaceModelTests.swift`

- [x] Add `@Published public private(set) var treeRevision: Int = 0` with a `bumpTreeRevision()` mutator (or document direct increment) the app calls after any successful file operation
- [x] Add `renamePath(from:to:)`: for any open tab whose canonical url equals `from`, set its url to `to`; for any open tab whose canonical url is *under* `from` (folder rename), rewrite its path prefix from `from` to `to`. Use the same canonical-match rule as `fileID(forURL:)`. Preserve dirty state (`savedText` untouched); `displayName` derives from `url` automatically
- [x] Add `closeFiles(under url:)`: force-close the tab whose canonical url equals `url`, and (folder delete) every tab whose canonical url is under it; leave unrelated tabs open; keep `selectedID` valid via existing close/selection logic
- [x] Tests — renamePath: an open file gets the new url and derived name; a folder rename rewrites the prefix of every nested open tab; an unopened/unrelated path is a no-op; dirty state preserved
- [x] Tests — closeFiles(under:): closes a deleted file's tab; closes every tab under a deleted folder; leaves unrelated tabs open; selection moves correctly when the selected tab is closed
- [x] Run `swift test` — must pass before Task 4

### Task 4: FilePanels name + delete dialogs

**Files:**
- Modify: `Sources/Pisaka/FilePanels.swift`

- [x] Add `promptName(title:defaultValue:) -> String?` — an `NSAlert` hosting an `NSTextField` accessory, returning the entered string on OK (pre-filled with `defaultValue` for Rename, empty for New), `nil` on Cancel
- [x] Add `confirmDelete(fileNames:) -> Bool` — a warning-style destructive-confirm `NSAlert` listing the target(s), mirroring `confirmClose`/`confirmRevert`, returning `true` only on Delete
- [x] (No unit tests — thin AppKit wrappers, per convention)

### Task 5: ProjectTreeView context menus + refresh wiring

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`

- [x] Add context menus: directory rows → New File…, New Folder…, Rename…, Delete; file rows → Rename…, Delete; the root node and the empty/no-folder pane → New File…, New Folder… (create target = clicked directory, or the clicked file's parent)
- [x] Thread new callbacks (e.g. `onNewFile(dir)`, `onNewFolder(dir)`, `onRename(url)`, `onDelete(url,isDirectory)`) through `PisakaApp → ContentView → ProjectTreeView` down into `DirectoryNodeView`/file rows, following the existing `onOpenFile`/`onOpenFolder` shape
- [x] In `DirectoryNodeView`, add `.onChange(of: model.treeRevision)` that, when expanded, re-reads `children(of:)`; keep `.id(root)` identity, `startsExpanded`, and lazy first-load intact
- [x] (No unit tests — thin view wiring, per convention)

### Task 6: PisakaApp orchestration

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] New File: promptName → `isValidFileName` → `fileService.createFile(at: dir/name)` → `model.open(url:)` (show the new file) → bump `treeRevision`
- [x] New Folder: promptName → validate → `fileService.createDirectory(at:)` → bump `treeRevision`
- [x] Rename: promptName pre-filled with current name → validate → `fileService.move(from: url, to: parent/newName)` → `model.renamePath(from:to:)` → bump `treeRevision`
- [x] Delete: `confirmDelete` → `fileService.removeItem(at: url)` → `model.closeFiles(under: url)` → bump `treeRevision`
- [x] On any disk-call failure (collision, missing path, write error): surface non-fatally — beep and/or an error-text `NSAlert`; never crash the view, never bump `treeRevision` on failure
- [x] (No unit tests — orchestration glue; logic is covered by Core tests)

### Task 7: Verify acceptance criteria

- [x] Run full `swift test` — all tests pass
- [x] Run `swift build` — compiles clean
- [x] Confirm the new Core logic (FileService ops, renamePath, closeFiles, isValidFileName) has direct test coverage

### Task 8: Update documentation

- [x] `CLAUDE.md`: document the four new `FileServicing` methods, `WorkspaceModel`'s `renamePath`/`closeFiles`/`treeRevision`, `isValidFileName`, and the context-menu / name-dialog / refresh wiring in `ProjectTreeView` / `FilePanels` / `PisakaApp`
- [x] `README.md`: update the project-tree limitation — it now supports create, rename, and delete (still no drag-and-drop or filesystem change detection)
