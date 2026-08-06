# Proportional minimap (fixed minimapLineHeight, sliding content)

## Overview

Replace the minimap's "stretch-to-fit" scaling with a VS Code-style proportional
model. Today `MinimapGeometry.scale` squeezes the whole document into the panel
height. Instead, each minimap line gets a fixed height `minimapLineHeight` (~3px);
the minimap content height `contentHeight = lineCount * minimapLineHeight` may
exceed the panel, so the minimap content slides vertically by `minimapScrollTop`
proportionally to the editor's scroll fraction. The document→minimap ratio
`r = contentHeight / documentHeight` is constant and independent of file length.

## Context

- Files involved:
  - `Sources/PisakaCore/MinimapGeometry.swift` — pure math, rewritten to the proportional model.
  - `Tests/PisakaCoreTests/MinimapGeometryTests.swift` — rewritten for the new API.
  - `Sources/Pisaka/CodeEditorView.swift` — owner: defines `minimapLineHeight`, computes `contentHeight`, feeds `minimapScrollTop`, updates `onScroll`.
  - `Sources/Pisaka/MinimapView.swift` — fixed row height drawing, slide offset, vertical culling; new `minimapLineHeight` / `minimapScrollTop` properties (drop `lineHeight`).
- Related patterns: `MinimapGeometry` stays Foundation/CoreGraphics-only (no AppKit). The view layer (`Pisaka`) stays thin and is verified by build, not unit tests (per CLAUDE.md). Only `PisakaCore` has unit tests.
- Dependencies: none new.

## New MinimapGeometry API

- Stored: `documentHeight`, `viewportHeight`, `minimapHeight`, `contentHeight` (owner computes `lineCount * minimapLineHeight`).
- `maxScrollOffset = max(0, documentHeight - viewportHeight)`
- `documentToMinimap = documentHeight > 0 ? contentHeight / documentHeight : 0`
- `minimapScrollTop(forScrollOffset:)` — 0 unless `contentHeight > minimapHeight` and `maxScrollOffset > 0`; otherwise `fraction * (contentHeight - minimapHeight)`.
- `viewportRect(forScrollOffset:)` — returns panel-space `(y, height)` already accounting for the slide: `y = clamped*r - minimapScrollTop(clamped)`, `height = viewportHeight * r`.
- `scrollOffset(forMinimapCenterY:currentScrollOffset:)` — maps a panel y back to a clamped editor offset, centering the viewport on the cursor; the slide is taken from the current offset (documented known nuance: drag converges in practice).
- `scale` / `fitsInViewport` removed (replaced by `documentToMinimap` / direct ratio logic).

## Development Approach

- **Testing approach**: TDD for the Core geometry (rewrite tests alongside the rewrite); view layer verified by `swift build` since it is intentionally not unit-tested.
- Complete each task fully before the next; run the full suite before moving on.
- **CRITICAL: every Core change ships with updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**

## Implementation Steps

### Task 1: Rewrite MinimapGeometry to the proportional model

**Files:**
- Modify: `Sources/PisakaCore/MinimapGeometry.swift`
- Modify: `Tests/PisakaCoreTests/MinimapGeometryTests.swift`

- [x] Add `contentHeight` stored property and update `init` to accept it.
- [x] Add `maxScrollOffset` (keep), `documentToMinimap`, `minimapScrollTop(forScrollOffset:)`.
- [x] Rewrite `viewportRect(forScrollOffset:)` to return panel-space coords with the slide applied.
- [x] Rewrite `scrollOffset(forMinimapCenterY:currentScrollOffset:)` with the slide from the current offset.
- [x] Remove `scale` and `fitsInViewport`; ensure all divisions guard against zero.
- [x] Update the doc comment to describe the fixed-row/slide convention.
- [x] Rewrite tests:
  - Short file (`contentHeight <= minimapHeight`): `minimapScrollTop` always 0; `viewportRect` maps directly via `r`.
  - Long file: offset 0 → slideTop 0 (top); offset `maxScrollOffset` → slideTop `contentHeight - minimapHeight` (bottom); viewport rect stays within `[0, minimapHeight]`.
  - `scrollOffset(forMinimapCenterY:currentScrollOffset:)`: top/bottom clamping and round-trip.
  - Degenerate (`documentHeight == 0`, `minimapHeight == 0`, `contentHeight == 0`): finite, no division by zero.
  - `Equatable` includes `contentHeight`.
- [x] run `swift test` — Core verified in isolation: `swift build --target PisakaCore` and `swift build --target PisakaCoreTests` both succeed against the new API. Full `swift test` rebuilds the whole package and stays red until the view layer is migrated (Tasks 2-3); the full suite is run green in Task 4.

### Task 2: Update MinimapView drawing (fixed row height + slide + culling)

**Files:**
- Modify: `Sources/Pisaka/MinimapView.swift`

- [x] Replace the `lineHeight` property with `minimapLineHeight: CGFloat` and add `minimapScrollTop: CGFloat` (both redraw on change).
- [x] Rewrite `drawTokens`: `rowHeight = minimapLineHeight`; `gap = rowHeight > 2 ? 1 : 0`; `barHeight = max(rowHeight - gap, 1)`; per line `y = line*rowHeight - minimapScrollTop + gap/2`; `continue` when `y + barHeight < 0`, `break` when `y > bounds.height` (cull to the visible slice).
- [x] Draw runs at `charWidth ~1`, clipped to view width, using `color.withAlphaComponent(0.6)`.
- [x] Keep the viewport rectangle from `geometry.viewportRect(forScrollOffset:)` (already panel-space).
- [x] run `swift build` — MinimapView compiles cleanly against the new API; the remaining build errors are confined to `CodeEditorView.swift` (Task 3), which the plan documents as expected (package stays red until Task 4).

### Task 3: Wire the owner (CodeEditorView) to the new model

**Files:**
- Modify: `Sources/Pisaka/CodeEditorView.swift`

- [x] Add a `minimapLineHeight: CGFloat = 3` constant.
- [x] In `refreshGeometry`: compute `contentHeight = CGFloat(minimap.model.lineCount) * minimapLineHeight`; build `MinimapGeometry(documentHeight:viewportHeight:minimapHeight:contentHeight:)`; set `minimap.minimapLineHeight` and `minimap.minimapScrollTop = geometry.minimapScrollTop(forScrollOffset: clipView.bounds.origin.y)`; keep `minimap.scrollOffset = clipView.bounds.origin.y`.
- [x] Update `onScroll` to call `geometry.scrollOffset(forMinimapCenterY: y, currentScrollOffset: clipView.bounds.origin.y)` and remove the now-unused `currentLineHeight()` minimap wiring (drop the method if no longer used).
- [x] run `swift build` — must succeed before Task 4.

### Task 4: Verify acceptance criteria

- [x] run `swift test` (full suite) — must pass. (99 tests, 0 failures)
- [x] run `swift build` — must succeed with no warnings introduced by these changes.
- [x] confirm `PisakaCore` still imports only Foundation/CoreGraphics (no AppKit).

### Task 5: Update documentation

- [x] Update `CLAUDE.md` MinimapGeometry/MinimapView/CodeEditorView descriptions to the proportional model (fixed `minimapLineHeight`, `contentHeight`, `minimapScrollTop` slide, culling; `documentToMinimap` replacing `scale`).
- [x] Update `README.md` only if any user-facing minimap behavior description changes (updated: "whole file fits the minimap's height" → fixed-line-height sliding overview).
