# Open a folder as a project and show a project file tree

## Overview

Add the ability to open a folder as a project: the user picks a directory
(menu "Open Folder…", Cmd+Shift+O) and a project file tree appears on the left.
Clicking a file in the tree opens it in a tab (via the existing
`WorkspaceModel.open(url:)`). The window layout becomes three columns:
project tree | open-tabs list | editor.

All directory-reading logic and the project-root state live in `PisakaCore`
(testable); the SwiftUI layer stays thin and only renders the tree and handles
clicks.

## Context

- Files involved:
  - Modify: `Sources/PisakaCore/FileService.swift` — add directory listing.
  - Modify: `Sources/PisakaCore/WorkspaceModel.swift` — add `projectRoot` and `openFolder(url:)`.
  - Modify: `Sources/Pisaka/FilePanels.swift` — folder-picker panel.
  - Modify: `Sources/Pisaka/ContentView.swift` — three-column `HSplitView`.
  - Modify: `Sources/Pisaka/PisakaApp.swift` — "Open Folder…" command.
  - Create: `Sources/Pisaka/ProjectTreeView.swift` — file tree (recursive rows with disclosure).
  - Modify: `Tests/PisakaCoreTests/FileServiceTests.swift`, `Tests/PisakaCoreTests/WorkspaceModelTests.swift` — new tests.
- Related patterns:
  - The `FileServicing` protocol already abstracts the disk for tests via a stub — directory listing is added the same way.
  - `FileServiceTests` already works with temporary files/directories.
  - `TabListView`/`TabRowView` — a model of thin recursive SwiftUI layout for `ProjectTreeView`.
  - `model.open(url:)` already reuses an open tab if the file is already open.
- Dependencies: Apple SDK only (SwiftUI/AppKit/Foundation). No external dependencies.

## Development Approach

- **Testing approach**: Regular (code first, then tests) — matches the current repository style.
- Listing/sorting logic and the project-root state live in `PisakaCore` with unit tests; tree-node expansion and panels are a thin UI layer without tests (like the rest of the UI).
- Directory entry sorting: directories first, then files, case-insensitive alphabetical; hidden files (starting with a dot) are not shown.
- **CRITICAL: every task includes new/updated PisakaCore tests.**
- **CRITICAL: the full test suite must pass before starting the next task.**

## Implementation Steps

### Task 1: Directory listing in PisakaCore

**Files:**
- Modify: `Sources/PisakaCore/FileService.swift`
- Modify: `Tests/PisakaCoreTests/FileServiceTests.swift`

- [x] Add a public `DirectoryEntry` model (`url: URL`, `isDirectory: Bool`, computed `name` from `lastPathComponent`), `Identifiable`/`Equatable`.
- [x] Add a method to the `FileServicing` protocol: `func contentsOfDirectory(at url: URL) throws -> [DirectoryEntry]`.
- [x] Implement in `FileService`: read the directory contents, filter out hidden entries (name starts with `.`), sort (directories first, then by name case-insensitive), return `[DirectoryEntry]`.
- [x] Write tests: listing a temporary directory with subfolders and files verifies hidden-entry filtering, ordering (folders→files, alphabetical), and the `isDirectory` flag.
- [x] `swift test` — must pass before Task 2.

### Task 2: Project root in WorkspaceModel

**Files:**
- Modify: `Sources/PisakaCore/WorkspaceModel.swift`
- Modify: `Tests/PisakaCoreTests/WorkspaceModelTests.swift`

- [x] Add `@Published public private(set) var projectRoot: URL?`.
- [x] Add `openFolder(url:)` that sets `projectRoot` (does not touch open tabs).
- [x] Add a thin listing pass-through for the UI: `func children(of url: URL) throws -> [DirectoryEntry]` delegating to `fileService.contentsOfDirectory(at:)` (so the view goes through the model rather than the service directly).
- [x] Write tests: `openFolder` sets `projectRoot`; `children(of:)` returns stub data; opening a folder does not change `openFiles`/`selectedID`.
- [x] `swift test` — must pass before Task 3.

### Task 3: Folder-picker panel and tree view

**Files:**
- Modify: `Sources/Pisaka/FilePanels.swift`
- Create: `Sources/Pisaka/ProjectTreeView.swift`

- [x] In `FilePanels` add `showOpenFolderPanel() -> URL?` (`canChooseDirectories = true`, `canChooseFiles = false`, `allowsMultipleSelection = false`).
- [x] Create `ProjectTreeView` (receives `model: WorkspaceModel`, `onOpenFile: (URL) -> Void`): when `projectRoot == nil` show a placeholder ("No folder open"), otherwise a recursive list from the root.
- [x] Implement the recursive row: for a directory — a `DisclosureGroup` that lazily loads children via `model.children(of:)` on expansion (with `@State` for children/expansion state); for a file — a clickable row that calls `onOpenFile(url)`.
- [x] Directory-read errors must not crash the view (empty list / `NSSound.beep()`), following the error-handling pattern in `PisakaApp`.
- [x] Add a minimal PisakaCore test covering the behavior the view relies on (e.g. `children(of:)` for a nested directory), since the SwiftUI views themselves are intentionally not tested.
- [x] `swift test` — must pass before Task 4.

### Task 4: Three-column layout and menu command

**Files:**
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] In `ContentView` make a three-column `HSplitView`: `ProjectTreeView` (left, e.g. `minWidth: 180, ideal: 240`) | `TabListView` (as now) | editor (as now).
- [x] Pass a tree file-open callback into `ContentView` that calls a new wrapper function in `PisakaApp` on top of `model.open(url:)` (with `NSSound.beep()` on error, like `openFile()`).
- [x] In `PisakaApp` add an "Open Folder…" button (Cmd+Shift+O) in `CommandGroup(replacing: .newItem)` next to "Open…", calling `FilePanels.showOpenFolderPanel()` → `model.openFolder(url:)`.
- [x] `swift build` — the app builds (`swift run Pisaka` launch is a manual step; build verified).
- [x] `swift test` — must pass before Task 5.

### Task 5: Verify acceptance criteria

- [x] `swift test` — full suite passes.
- [x] `swift build` — no warnings/errors.
- [x] Verify coverage of the new `PisakaCore` logic (directory listing, `openFolder`, `children(of:)`).

### Task 6: Update documentation

- [x] Update `README.md`: mention "Open Folder…" (Cmd+Shift+O) and the project tree panel.
- [x] Update `CLAUDE.md`: describe `DirectoryEntry`/`contentsOfDirectory`, `projectRoot`/`openFolder`/`children(of:)` in `WorkspaceModel`, the new `ProjectTreeView.swift`, and the three-column `ContentView` layout.
