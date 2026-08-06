# Editor minimap (VS Code-style)

## Overview

Add a VS Code-style minimap to the right of the editor: a scaled-down,
syntax-colored overview of the whole file with a draggable viewport rectangle.
Dragging the rectangle scrolls the editor; scrolling the editor moves the
rectangle. The whole file fits the minimap's height. Pure scroll/viewport math
goes in a new testable `PisakaCore` type; the AppKit/SwiftTreeSitter rendering
and sync live in a thin `Pisaka` view layer.

## Context

- Files involved:
  - Create: `Sources/PisakaCore/MinimapGeometry.swift` (pure geometry, CoreGraphics/Foundation only)
  - Create: `Tests/PisakaCoreTests/MinimapGeometryTests.swift`
  - Create: `Sources/Pisaka/MinimapView.swift` (NSView renderer + viewport overlay + mouse handling)
  - Create: `Sources/Pisaka/MinimapTokenizer.swift` (full-file tree-sitter parse → colored runs, debounced/cached)
  - Modify: `Sources/Pisaka/CodeEditorView.swift` (return a container `[NSScrollView | MinimapView]`; wire scroll sync)
  - Modify: `CLAUDE.md`, `README.md`
- Related patterns:
  - `SyntaxLanguageConfiguration.configuration(for:)` already loads the grammar
    `Language` + highlights `Query`; the tokenizer reuses it.
  - `SyntaxTokenKind(captureName:)` (Core) → `SyntaxTheme.shared.nsColor(for:)`
    is the exact capture→color path the editor's attribute provider uses; the
    minimap reuses it.
  - `SyntaxTheme` is appearance-aware (light/dark) — colors must be resolved at
    draw time, like the editor.
  - The editor's cache-by-version / staleness-avoidance precedent for race
    avoidance.
- Dependencies: no new packages. Tokenizer uses already-pinned SwiftTreeSitter
  via the existing grammar config; `PisakaCore` stays Foundation/CoreGraphics-only.

## Development Approach

- **Testing approach**: TDD for `MinimapGeometry` (pure math, fully
  unit-tested); the view layer (`MinimapView`, tokenizer, `CodeEditorView`
  container) is intentionally thin and not unit-tested, per project convention.
- Complete each task fully before the next; full `swift test` suite must pass
  before moving on.
- **CRITICAL: every task MUST include new/updated tests** (the geometry task
  carries the test burden; view-layer tasks confirm the suite still passes).
- **CRITICAL: all tests must pass before starting next task.**
- Keep all reusable logic/math in `PisakaCore`; keep `Pisaka` views thin. No
  Neon/SwiftTreeSitter/AppKit import in Core or tests.
- Handle AppKit flipped-coordinate / clip-view bounds-origin conversion
  explicitly at the view boundary; `MinimapGeometry` works in a single top-down
  convention.

## Implementation Steps

### Task 1: MinimapGeometry (PisakaCore, TDD)

**Files:**
- Create: `Sources/PisakaCore/MinimapGeometry.swift`
- Create: `Tests/PisakaCoreTests/MinimapGeometryTests.swift`

- [x] Write `MinimapGeometryTests.swift` first, covering: doc shorter than
  viewport (rect spans full minimap height; `scrollOffset` always 0 for any
  minimap y); doc longer than viewport (`scale < 1`; `viewportRect` y/height
  scale with offset); `scrollOffset(forMinimapCenterY:)` clamps at top (y→0 ⇒
  offset 0) and bottom (y→minimapHeight ⇒ offset `documentHeight -
  viewportHeight`); round-trip offset → rect → center-y → offset stays
  consistent within scrollable range; degenerate `documentHeight == 0` and
  `minimapHeight == 0` don't divide by zero.
- [x] Implement `public struct MinimapGeometry: Equatable` with
  `init(documentHeight:viewportHeight:minimapHeight:)`, `var scale: CGFloat`
  (`minimapHeight / documentHeight`, capped at 1), `func
  viewportRect(forScrollOffset:) -> (y: CGFloat, height: CGFloat)`, and `func
  scrollOffset(forMinimapCenterY:) -> CGFloat` (clamped to `[0, max(0,
  documentHeight - viewportHeight)]`). Guard all divisions against zero.
- [x] Implement the `documentHeight <= viewportHeight` branch: rect spans full
  minimap height, `scrollOffset` always 0.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: Full-file tokenizer helper (Pisaka)

**Files:**
- Create: `Sources/Pisaka/MinimapTokenizer.swift`

- [x] Implement a helper that, given text + `SyntaxLanguage`, gets the
  `LanguageConfiguration` via `SyntaxLanguageConfiguration.configuration(for:)`,
  parses the entire text with SwiftTreeSitter, runs the highlights `Query`, and
  produces per-line colored non-whitespace runs: `[(NSRange, captureName)]` →
  `SyntaxTokenKind(captureName:)` → `NSColor` via `SyntaxTheme.shared`. Output a
  line-indexed model of colored segments suitable for drawing (e.g. per line:
  ranges of columns + token kind/color).
- [x] Debounce re-parse on text change and cache by file id + text version
  (string identity/hash); only re-parse on real content change. Resolve colors
  at draw time (appearance-aware), storing token kind rather than a frozen color
  where practical.
- [x] No detected language → empty result (minimap draws nothing / blank),
  matching the editor's plain-text path.
- [x] Run `swift test` — suite must still pass (no Core changes; confirms build
  integrity).

### Task 3: MinimapView renderer + mouse handling (Pisaka)

**Files:**
- Create: `Sources/Pisaka/MinimapView.swift`

- [x] Implement `MinimapView: NSView` that draws, per document line, small
  colored rectangles (~1pt/char, clipped to minimap width) for non-whitespace
  runs, scaled via `MinimapGeometry.scale` so the document fits the minimap
  height. Cap work for very large files (merge/skip rows below ~1px) to stay
  responsive.
- [x] Draw the viewport rectangle overlay (semi-transparent fill + border) on
  top, positioned from `MinimapGeometry.viewportRect(forScrollOffset:)`.
- [x] Mouse handling: `mouseDown` + `mouseDragged` map cursor y through
  `MinimapGeometry.scrollOffset(forMinimapCenterY:)` and report the target
  offset via a callback; the same path serves click-to-jump and rectangle drag.
- [x] Redraw on system appearance change (light/dark) and on resize; re-resolve
  `SyntaxTheme` colors for the current appearance.
- [x] Run `swift test` — suite must still pass.

### Task 4: Wire minimap into CodeEditorView + scroll sync (Pisaka)

**Files:**
- Modify: `Sources/Pisaka/CodeEditorView.swift`

- [x] Change `makeNSView` to return a container holding `[NSScrollView |
  MinimapView]` with the minimap a fixed width on the right (update the
  `NSViewRepresentable` `NSViewType` and `updateNSView` accordingly).
- [x] Editor → minimap: set `scrollView.contentView.postsBoundsChangedNotifications
  = true`, observe `boundsDidChangeNotification`, convert the flipped clip-view
  bounds origin to the geometry's top-down convention, recompute the rect,
  redraw.
- [x] Minimap → editor: the minimap's offset callback scrolls the text view's
  clip view (converting back to AppKit coordinates); the viewport rect then
  follows automatically via the bounds notification (closed loop).
- [x] Feed the tokenizer on text edits (debounced), on language/`fileID` change,
  and rebuild the minimap model accordingly; build `MinimapGeometry` from current
  document/viewport/minimap heights and refresh on resize.
- [x] Ensure observers are removed on teardown (`dismantleNSView`) to avoid leaks
  across tab switches.
- [x] Run `swift build` and `swift test` — suite must pass.

### Task 5: Verify acceptance criteria

- [x] Run full test suite: `swift test` — all green.
- [x] Run `swift build` — compiles clean (no warnings introduced in changed
  files).
- [x] Confirm `PisakaCore` and the test target import only Foundation/CoreGraphics
  (no Neon/SwiftTreeSitter/AppKit) — grep the new Core file and test file.
- [x] Confirm `MinimapGeometry` test coverage spans all bullet cases listed in
  Task 1.

### Task 6: Update documentation

- [x] `CLAUDE.md`: document `MinimapGeometry` (PisakaCore) and the new view files
  (`MinimapView`, `MinimapTokenizer`), plus the `CodeEditorView` container/
  scroll-sync change.
- [x] `README.md`: add the minimap to the Features list; remove any "no minimap"
  wording from MVP 0.1 Limitations if present.

## Out of scope (YAGNI)

- Sliding minimap for huge files (fit-all only).
- Toggle to show/hide, configurable width, hover line preview, drag-selection on
  the minimap.
- Sharing the parse tree with Neon (deliberate separate parse).
