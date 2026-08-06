# MVP 0.1 — Native Swift Code Editor (macOS) with Vertical Tabs

## Overview

A minimal native macOS text editor: a vertical list of open files (tabs) on the left, a simple text editor on the right. The user can create new files, open existing ones, switch between them, edit, save (including Save As for Untitled), see an unsaved-changes indicator, and close files correctly with a confirmation prompt when there are unsaved changes.

Architecture: Swift Package Manager. All logic (file model, tabs, dirty state, disk read/write) lives in a testable library, PisakaCore. The UI is a thin SwiftUI layer (executable Pisaka): an HSplit with a tab list plus an NSTextView-based editor via NSViewRepresentable. The app runs non-sandboxed so NSOpenPanel/NSSavePanel work without entitlements.

## Context

- Files involved (all created from scratch):
  - `Package.swift` — SPM manifest (executable Pisaka, library PisakaCore, test target PisakaCoreTests; platform macOS 13+)
  - `Sources/PisakaCore/OpenFile.swift` — model of an open file (id, url?, display name, text, isDirty)
  - `Sources/PisakaCore/FileService.swift` — text read/write to disk (pure, testable)
  - `Sources/PisakaCore/WorkspaceModel.swift` — ObservableObject: list of open files, selected file, newFile/open/save/saveAs/close operations + confirmation logic
  - `Sources/Pisaka/PisakaApp.swift` — @main App, menu and shortcuts (Cmd+N/O/S/W)
  - `Sources/Pisaka/ContentView.swift` — two-zone layout (tabs left, editor right)
  - `Sources/Pisaka/TabListView.swift` + `Sources/Pisaka/TabRowView.swift` — vertical tabs (name, active state, change indicator, close button)
  - `Sources/Pisaka/CodeEditorView.swift` — NSViewRepresentable wrapping NSTextView (monospace, undo/redo, copy/paste)
  - `Sources/Pisaka/FilePanels.swift` — wrappers over NSOpenPanel/NSSavePanel and a confirm dialog (NSAlert)
  - `Tests/PisakaCoreTests/*` — unit tests for the model
- Related patterns: standard SwiftUI App lifecycle, `@StateObject`/`@ObservedObject`, `NSViewRepresentable`, `.commands` for menus/shortcuts.
- Dependencies: Apple SDK only (SwiftUI, AppKit, Foundation). No external packages.

## Development Approach

- **Testing approach**: Regular (code first, then tests). All domain logic lives in PisakaCore and is covered by XCTest. The UI layer is thin; for UI tasks we test the logic extracted into the model, not the Views themselves.
- Complete each task fully before moving to the next.
- Commands: build `swift build`, test `swift test`, run `swift run Pisaka`.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**

## Implementation Steps

### Task 1: SPM project skeleton and empty window

**Files:**
- Create: `Package.swift`, `Sources/Pisaka/PisakaApp.swift`, `Sources/Pisaka/ContentView.swift`, `Sources/PisakaCore/PisakaCore.swift`, `Tests/PisakaCoreTests/SmokeTests.swift`

- [x] Define Package.swift: platform macOS(.v13), executable target `Pisaka` (depends on `PisakaCore`), library `PisakaCore`, test target `PisakaCoreTests`
- [x] Minimal @main SwiftUI App with a single window and a stub ContentView (empty HSplit)
- [x] Smoke test in PisakaCore (e.g. a version/constant) — confirms `swift test` runs
- [x] `swift build` and `swift run Pisaka` launch an empty window
- [x] run project test suite — must pass before task 2

### Task 2: Domain model (OpenFile, FileService, WorkspaceModel)

**Files:**
- Create: `Sources/PisakaCore/OpenFile.swift`, `Sources/PisakaCore/FileService.swift`, `Sources/PisakaCore/WorkspaceModel.swift`, `Tests/PisakaCoreTests/WorkspaceModelTests.swift`, `Tests/PisakaCoreTests/FileServiceTests.swift`

- [x] `OpenFile`: id (UUID), url (optional), displayName ("Untitled" when no url, otherwise file name), text, savedText, isDirty = text != savedText
- [x] `FileService`: read(url) -> String, write(text, to: url) with error handling
- [x] `WorkspaceModel` (ObservableObject): `openFiles`, `selectedID`; methods `newFile()` (creates Untitled and selects it), `open(url:)` (creates a tab from contents, selects it), `updateText(_:for:)`, `markSaved(for:)`
- [x] Tests: newFile creates Untitled and makes it active; open reads contents and adds a tab; updateText sets isDirty; markSaved clears isDirty; FileService round-trip (write→read) via a temp file
- [x] run project test suite — must pass before task 3

### Task 3: Vertical tabs (UI + supporting logic)

**Files:**
- Create: `Sources/Pisaka/TabListView.swift`, `Sources/Pisaka/TabRowView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`, `Sources/PisakaCore/WorkspaceModel.swift`, `Tests/PisakaCoreTests/WorkspaceModelTests.swift`

- [x] TabRowView shows displayName, active state (highlight), unsaved-changes indicator (dot), close button
- [x] TabListView — vertical list of tabs, selection switches selectedID; ContentView wires the list (left) and an editor stub (right)
- [x] In WorkspaceModel: a `select(_:)` method and a computed `selectedFile`
- [x] Tests: select changes selectedFile; openFiles preserves insertion order; the indicator is tied to the selected model's isDirty
- [x] run project test suite — must pass before task 4

### Task 4: NSTextView-based editor

**Files:**
- Create: `Sources/Pisaka/CodeEditorView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`, `Tests/PisakaCoreTests/WorkspaceModelTests.swift`

- [x] CodeEditorView (NSViewRepresentable) with NSScrollView+NSTextView: monospaced font, isEditable, undo/redo (allowsUndo), default copy/paste
- [x] Two-way binding: editor text comes from selectedFile.text; edits call `updateText` (updates isDirty)
- [x] Switching tabs updates the editor contents to the corresponding file's text
- [x] Tests: editing the selected file's text sets isDirty and the indicator; switching between files preserves each file's independent text
- [x] run project test suite — must pass before task 5

### Task 5: File operations, menu, and shortcuts

**Files:**
- Create: `Sources/Pisaka/FilePanels.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`, `Sources/PisakaCore/WorkspaceModel.swift`, `Tests/PisakaCoreTests/WorkspaceModelTests.swift`

- [x] FilePanels: wrappers showOpenPanel() -> URL?, showSavePanel(suggestedName:) -> URL? (NSOpenPanel/NSSavePanel)
- [x] Menu commands with shortcuts: Cmd+N (newFile), Cmd+O (open via panel), Cmd+S (save), Cmd+W (close)
- [x] WorkspaceModel.save(for:): if a url exists — write to disk and markSaved; if no url — signal that Save As is needed (return a flag/enum)
- [x] WorkspaceModel.saveAs(url:for:): assign url, write to disk, update displayName, markSaved
- [x] Tests: save of an existing file writes to disk and clears isDirty; save of Untitled requires Save As; saveAs assigns url/name and clears isDirty
- [x] run project test suite — must pass before task 6

### Task 6: Closing a file with unsaved-changes confirmation

**Files:**
- Modify: `Sources/Pisaka/FilePanels.swift`, `Sources/Pisaka/PisakaApp.swift`, `Sources/Pisaka/TabRowView.swift`, `Sources/PisakaCore/WorkspaceModel.swift`, `Tests/PisakaCoreTests/WorkspaceModelTests.swift`

- [x] WorkspaceModel.close(id:): if the file is not dirty — remove the tab immediately; recompute selectedID correctly (neighboring tab)
- [x] Confirmation logic for dirty files: confirm dialog (NSAlert) with Save / Don't Save / Cancel; Save → save (or Save As for Untitled) and close, Don't Save → close without saving, Cancel → do nothing
- [x] Closing is available via the tab's close button and Cmd+W (closes the active tab)
- [x] Tests: close of a clean file removes it immediately; close of a dirty file requires a decision (model does not remove without confirmation); after closing, selectedID points to a correct neighboring tab; closing the last tab clears the selection
- [x] run project test suite — must pass before task 7

### Task 7: Verify acceptance criteria

- [x] run full test suite (`swift test`) — all tests green
- [x] `swift build` with no errors/warnings
- [x] verify test coverage of PisakaCore meets 80%+ (line coverage 100%, region 95–100%)

### Task 8: Update documentation

- [x] Update README.md: what Pisaka MVP 0.1 is, how to build/run (`swift run Pisaka`), the list of shortcuts and MVP limitations
- [x] Create CLAUDE.md describing the structure (PisakaCore vs Pisaka, where the logic lives, where the UI lives) and build/test commands

## Post-Completion

- [ ] Manual Definition of Done run via `swift run Pisaka`: launch app; create a new file; type text; Save As; open two more files from disk; see all open files in vertical tabs; switch between files; edit one file; see the unsaved-changes indicator; save via Cmd+S; close the dirty file and get the confirm dialog; close a clean file with no confirm dialog.
