# Fix project-tree, editor and minimap UX issues

## Overview

Four independent fixes to the Pisaka SwiftUI layer:

1. Make the empty project-tree pane clickable to open a folder (currently a passive "No folder open" placeholder).
2. Show line numbers in the code editor.
3. Auto-expand the first level of the project tree when a folder is opened.
4. Make the minimap respond to mouse-wheel scrolling.

All four issues are in the `Pisaka` executable (UI) target. Where real logic exists (the minimap scroll math) it is extracted into `PisakaCore` and unit-tested per project convention. The other three are AppKit/SwiftUI view-state changes with no domain logic to test; for those the task verification is that the full existing suite still builds and passes.

## Context

- Files involved:
  - `Sources/Pisaka/ProjectTreeView.swift` — placeholder (issue 1) and root expansion (issue 3)
  - `Sources/Pisaka/ContentView.swift` — wires a new `onOpenFolder` callback through
  - `Sources/Pisaka/PisakaApp.swift` — already has `openFolder()`; passes it to `ContentView`
  - `Sources/Pisaka/CodeEditorView.swift` — line-number ruler (issue 2) + minimap wheel wiring (issue 4)
  - `Sources/Pisaka/MinimapView.swift` — `scrollWheel` handling (issue 4)
  - `Sources/PisakaCore/MinimapGeometry.swift` — new pure scroll-by-delta helper (issue 4)
  - `Tests/PisakaCoreTests/MinimapGeometryTests.swift` — tests for the new helper
- Related patterns:
  - Callbacks (`onOpenFile`, `onClose`) already flow `PisakaApp → ContentView → child view`; `onOpenFolder` follows the same shape.
  - `MinimapView.onScroll` already reports a cursor position the coordinator maps through `MinimapGeometry` and applies via `Coordinator.scrollEditor(to:)`; the wheel path reuses `scrollEditor(to:)`.
  - `MinimapGeometry` is pure (CoreGraphics only) and fully unit-tested — the new delta helper matches `scrollOffset(forMinimapCenterY:)`'s clamping/guard style.
- Dependencies: none new. AppKit `NSRulerView` (already available) provides the line-number gutter.

## Development Approach

- **Testing approach**: Regular (code first, then tests).
- Issues 1–3 are view-only (SwiftUI/AppKit). They carry no PisakaCore logic, so per-task verification is "full suite still passes" rather than new unit tests — this is the honest reading of the project's test mandate (logic lives in Core; views stay thin).
- Issue 4 extracts the scroll-delta-to-offset math into `MinimapGeometry` and unit-tests it, keeping `MinimapView` thin.
- Complete each task fully (build + tests green) before the next.
- **CRITICAL: every task that adds Core logic MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**

## Implementation Steps

### Task 1: Clickable "open folder" placeholder

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] Add an `onOpenFolder: () -> Void = {}` property to `ProjectTreeView`.
- [x] Replace the `Text("No folder open")` placeholder with a clickable area covering the whole pane (`contentShape(Rectangle())` + `onTapGesture`, keeping the same centered hint text, optionally reworded to "Click to open a folder") that calls `onOpenFolder`.
- [x] Add `onOpenFolder: () -> Void = {}` to `ContentView` and pass it into `ProjectTreeView`.
- [x] In `PisakaApp`, pass `onOpenFolder: { openFolder() }` into `ContentView`.
- [x] Build (`swift build`) and run the full suite (`swift test`) — must pass before Task 2.

### Task 2: Line numbers in the editor

**Files:**
- Modify: `Sources/Pisaka/CodeEditorView.swift`
- Create: `Sources/Pisaka/LineNumberRulerView.swift`

- [x] Add an `NSRulerView` subclass `LineNumberRulerView` that draws right-aligned line numbers for the editor's `NSTextView`, aligned to each line fragment via the layout manager, redrawing on scroll and edit.
- [x] In `makeNSView`, attach it as the scroll view's `verticalRulerView`, set `hasVerticalRuler = true` and `rulersVisible = true`, and have the ruler observe the text view (bounds/frame/text-change) so numbers stay in sync; ensure it follows the editor font and system appearance.
- [x] Verify the ruler width/inset does not break the existing minimap layout in `EditorContainerView`. (Ruler lives inside the `NSScrollView`, which reserves the gutter on its left; `EditorContainerView` positions the minimap to the right of the scroll view, so the side-by-side layout is unaffected.)
- [x] Build and run the full suite — must pass before Task 3.

### Task 3: Auto-expand the first tree level on folder open

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`

- [x] Give `DirectoryNodeView` an initializer that accepts a `startsExpanded` flag and seeds `@State isExpanded` via `_isExpanded = State(initialValue:)`.
- [x] Construct the root `DirectoryNodeView` with `startsExpanded: true` so the root's immediate children load and show on open (child nodes keep `startsExpanded: false`).
- [x] Confirm the root's `.id(root)` still resets node state when switching projects, so a newly opened folder also starts expanded.
- [x] Build and run the full suite — must pass before Task 4.

### Task 4: Mouse-wheel scrolling on the minimap

**Files:**
- Modify: `Sources/PisakaCore/MinimapGeometry.swift`
- Modify: `Sources/Pisaka/MinimapView.swift`
- Modify: `Sources/Pisaka/CodeEditorView.swift`
- Modify: `Tests/PisakaCoreTests/MinimapGeometryTests.swift`

- [x] Add a pure method to `MinimapGeometry`, e.g. `scrollOffset(byMinimapDelta:from:)`, that converts a minimap-panel-space scroll delta to a clamped document scroll offset (delta divided by `documentToMinimap`, added to the current offset, clamped to `[0, maxScrollOffset]`), guarding against zero ratio/height like the existing methods.
- [x] Override `scrollWheel(with:)` in `MinimapView` to compute the new offset from the event delta via the geometry helper and report it through a callback (a new `onScrollToOffset`, or by extending the existing scroll wiring).
- [x] In `CodeEditorView.Coordinator.attachMinimap`, wire that callback to `scrollEditor(to:)` so the editor (and, via the bounds notification, the viewport rectangle) follows the wheel.
- [x] Add `MinimapGeometryTests` cases for the new helper: forward/backward deltas, clamping at top and bottom, and zero-height/zero-ratio guards.
- [x] Build and run the full suite — must pass before Task 5.

### Task 5: Verify acceptance criteria

- [x] Run the full test suite (`swift test`) — all green. (105 tests, 0 failures.)
- [x] Build the app (`swift build`) with no warnings introduced by the changes.
- [x] Sanity-check that `PisakaCore` still imports only Foundation/CoreGraphics (no AppKit/Neon leaked in via the new geometry helper).

### Task 6: Update documentation

- [x] Update `README.md` if the line-number gutter / click-to-open-folder are user-facing features worth listing.
- [x] Update `CLAUDE.md` architecture notes for the new `LineNumberRulerView`, the `ProjectTreeView` open-folder/auto-expand behavior, the new `MinimapGeometry` scroll-by-delta method, and the minimap wheel path.
