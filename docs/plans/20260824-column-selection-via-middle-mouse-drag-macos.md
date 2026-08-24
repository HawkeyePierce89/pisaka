# Column selection via middle-mouse drag (macOS editor)

## Overview

Claim the middle mouse button in the macOS code editor (`EditorTextView`) for a
rectangular (column) selection: press anchors, drag extends live (autoscrolling
past the visible edge), release finalizes. The rule that turns a drag's two
corners plus the layout's per-line answers into an ordered list of
`selectedRanges` lives in a new pure `PisakaCore` engine with full unit tests;
the view only resolves pointer coordinates through TextKit and applies the
result. A middle click without meaningful movement places a single caret and
focuses the editor. Nothing else changes: the native Option-drag / ⌘⌥-drag
rectangular selection, ⌘-click go-to-definition and plain click/drag selection
are untouched, and everything downstream of a multi-range selection (typing,
deleting, copying) stays stock AppKit.

## Context

- Files involved:
  - Create: `Sources/PisakaCore/ColumnSelectionEngine.swift` — the pure engine.
  - Create: `Tests/PisakaCoreTests/ColumnSelectionEngineTests.swift`.
  - Modify: `Sources/Pisaka/CodeEditorView.swift` — `EditorTextView`'s three
    `otherMouse…` overrides plus two private stored properties.
  - Modify: `CLAUDE.md` (one index line under the `core-editor.md` list),
    `docs/architecture/core-editor.md` (full engine entry),
    `docs/architecture/app-editor.md` (the `CodeEditorView.swift` wiring),
    `docs/FEATURES.md` (user-facing gesture), `README.md` (shortcut table row).
- Related patterns:
  - `DuplicateEngine.swift` — the precedent for a Foundation-only engine over an
    `NSString` + UTF-16 offsets that returns a value the view applies; it also
    establishes `getLineStart(_:end:contentsEnd:for:)` as the way a line's
    terminator is excluded (CRLF counted as one separator).
  - `MinimapGeometry.swift` — the precedent for a Core engine importing
    `CoreGraphics` for `CGFloat` geometry.
  - `LineStartIndex.isLineSeparator(_:)` — the editor-wide separator set.
  - `EditorTextView.mouseDown(with:)` (`CodeEditorView.swift:2618`) and its
    `clickSlop` constant (2 pt) — the existing click-vs-drag tolerance this
    gesture reuses.
  - `DiffView.swift:335` / `MergeView.swift:630` — the existing
    `layoutManager.enumerateLineFragments(forGlyphRange:)` idiom.
- Dependencies: none. No new packages, no `project.yml` change.
- Layout facts this relies on: the editor disables soft wrap
  (`textContainer.widthTracksTextView = false`, huge container size,
  `CodeEditorView.swift:278`), so one line fragment is one document line;
  `allowsNonContiguousLayout = true`, so layout is forced for the probed rect
  before enumeration.
- Lint headroom: `.swiftlint.yml` caps `file_length` at 1400 *code* lines
  (comment-only lines are not counted); `CodeEditorView.swift` sits at ~1164, so
  the added wiring fits with room to spare and needs no in-file disable.

## Design decisions

**Engine split (requirement 5 + requirement 2).** Visual columns mean the
horizontal edges must be resolved by the glyph layout per line, which the view
alone can do. The engine therefore owns the two decisions that are not layout:

1. `bounds(anchor:head:)` — normalizing two drag corners (any of the four corner
   orders, in the flipped text-view coordinate space) into one rectangle:
   `left`/`right` and `top`/`bottom`.
2. `ranges(for:in:)` — turning the layout's per-line answers into the ordered
   `selectedRanges`: clamping each pair into that line's own character range,
   trimming the line terminator (LF, CR, CRLF as one, NEL, LS, PS) so it is
   never swallowed, ordering the pair, sorting and de-duplicating, and letting a
   zero-width rectangle fall out naturally as one zero-length range per line
   (the multi-caret case).

The view passes each line's own character range (taken from the line fragment's
glyph range) rather than letting the engine infer the line from an offset: a
point to the right of a short line can resolve to an offset past that line's
content, and inferring the line from that offset would attach the range to the
*next* line and collide with that line's own entry.

**No modal event loop.** Unlike the ⌘-click case — where `super.mouseDown` runs
its own tracking loop and forced the `nextEvent` peek — `NSTextView` ignores
`otherMouseDown` entirely, so AppKit delivers `otherMouseDragged` /
`otherMouseUp` to this view normally. A three-override state machine (anchor
point + a "moved past the slop" flag) is therefore enough, and it keeps
`autoscroll(with:)` on the ordinary event path. The anchor is stored in *view*
coordinates, which autoscroll does not disturb.

**Live vs. final.** Drag events apply
`setSelectedRanges(_:affinity:stillSelecting: true)`; the release applies the
same ranges with `stillSelecting: false`, matching how AppKit's own drag
selection reports.

## Development Approach

- **Testing approach**: TDD for the Core engine (tests first, then the engine);
  regular for the view wiring, which is untested by repository convention.
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests** — except the view-layer
  and documentation tasks, where the convention is explicitly "thin and
  untested"; those tasks re-run the existing suite instead.
- **CRITICAL: all tests must pass before starting next task.**
- No competing product names anywhere in code, comments or docs.

## Implementation Steps

### Task 1: The `ColumnSelectionEngine` Core engine

**Files:**
- Create: `Sources/PisakaCore/ColumnSelectionEngine.swift`
- Create: `Tests/PisakaCoreTests/ColumnSelectionEngineTests.swift`

- [x] write `ColumnSelectionEngineTests` first, covering: normalization from all
      four corner orders (down-right, down-left, up-right, up-left) plus the
      zero-width and zero-height drags; a multi-line rectangle over uniform
      lines; a line shorter than the rectangle clamping to its content end; the
      terminator never included, for LF, for CR, and for CRLF (both offsets
      landing past the content end); a purely zero-width rectangle yielding one
      zero-length range per line; a single-line drag; an empty document; a
      per-line pair handed over in reverse order; offsets outside the line's
      range and outside the text's bounds (clamped, never trapping); and empty
      input yielding no ranges
- [x] add `Sources/PisakaCore/ColumnSelectionEngine.swift` (Foundation +
      CoreGraphics only), with a file-header doc comment stating the contract,
      the coordinate convention and why the line range is supplied rather than
      inferred:
      - `public struct ColumnSelectionBounds: Equatable` — `left`, `right`,
        `top`, `bottom` (`CGFloat`), plus the enclosing `CGRect` the view uses to
        ask the layout manager for the glyph range to enumerate
      - `public struct ColumnSelectionLine: Equatable` — `lineRange: NSRange`
        (the line's characters, terminator included) and the two resolved UTF-16
        offsets the layout returned for the rectangle's left and right edges
      - `public enum ColumnSelectionEngine` with
        `static func bounds(anchor: CGPoint, head: CGPoint) -> ColumnSelectionBounds`
        and
        `static func ranges(for lines: [ColumnSelectionLine], in text: NSString) -> [NSRange]`
      - `ranges` clamps every line range into the text's bounds, trims the
        trailing separator (`LineStartIndex.isLineSeparator`, CRLF as one),
        clamps and orders each offset pair inside `[lineStart, contentEnd]`,
        and returns the ranges ascending by location with exact duplicates
        removed (AppKit requires ordered, non-overlapping ranges)
- [x] run `swift test` — must pass before Task 2

### Task 2: The middle-button gesture in `EditorTextView`

**Files:**
- Modify: `Sources/Pisaka/CodeEditorView.swift`

- [x] add two private stored properties to `EditorTextView`: the column-drag
      anchor point (view coordinates, `nil` when no middle drag is in flight) and
      a "passed the slop radius" flag
- [x] override `otherMouseDown(with:)`: for anything but the middle button
      (`event.buttonNumber != 2`), or a non-selectable view, fall through to
      `super`; otherwise take first responder if the view does not already hold
      it, record the anchor, clear the moved flag, and consume the event
- [x] override `otherMouseDragged(with:)`: with no anchor recorded fall through
      to `super`; otherwise call `autoscroll(with:)` first, then convert the
      event location *after* autoscroll, ignore movement still inside
      `Self.clickSlop`, and once past it set the moved flag and apply the
      selection with `stillSelecting: true`
- [x] override `otherMouseUp(with:)`: with no anchor fall through to `super`;
      with the moved flag set apply the selection once more with
      `stillSelecting: false`; otherwise collapse to a single caret at the
      anchor via `characterIndexForInsertion(at:)`; clear the drag state on
      every path
- [x] add the private helper that computes the ranges for an anchor/head pair:
      `ColumnSelectionEngine.bounds(anchor:head:)`, then build the **probe rect**
      from those bounds — widened to the container horizontally and, before it
      reaches the layout manager, inflated so that neither dimension is
      degenerate (at least one point of height, and at least one point of width
      if it was not already widened), because a zero-height single-line drag or a
      zero-width vertical drag can otherwise make
      `glyphRange(forBoundingRect:in:)` enumerate no fragments at all — then
      `ensureLayout` + `glyphRange(forBoundingRect:in:)` over the probe rect and
      `enumerateLineFragments(forGlyphRange:)` collecting one
      `ColumnSelectionLine` per fragment (`characterIndexForInsertion(at:)`
      probed at the *un-inflated* bounds' left and right edges on the fragment's
      vertical centre, so inflation never widens the selected columns; the line's
      character range from the fragment's glyph range), then
      `ColumnSelectionEngine.ranges(for:in:)`; apply only a non-empty result, so
      a degenerate enumeration leaves the existing selection alone
- [x] document in doc comments: why the probe rect is inflated out of degeneracy
      before the layout manager sees it and why the edge offsets are still taken
      from the un-inflated bounds; why no modal event loop is needed here (unlike
      the ⌘-click path); why the anchor is stored in view coordinates
      (autoscroll-stable); why the probe is per line fragment (visual columns,
      one fragment per line with soft wrap off); and that the gesture never
      edits the document
- [x] run `swift test` (the Core suite must stay green) and
      `swiftlint --strict` — both must pass before Task 3

### Task 3: Documentation

**Files:**
- Modify: `CLAUDE.md`, `docs/architecture/core-editor.md`,
  `docs/architecture/app-editor.md`, `docs/FEATURES.md`, `README.md`

- [ ] `CLAUDE.md`: add one index line for `ColumnSelectionEngine.swift` in the
      `core-editor.md` list — the middle-drag column-selection rule
- [ ] `docs/architecture/core-editor.md`: add the full entry — the two entry
      points and their types, why the split between "normalize the rectangle"
      (Core) and "resolve x to an offset" (view layout), why the line range is
      supplied rather than inferred from an offset, the terminator trimming
      including the CRLF pair, the zero-width multi-caret case, the ordering /
      de-duplication contract `selectedRanges` requires, and the empty-document
      behavior
- [ ] `docs/architecture/app-editor.md`: extend the `CodeEditorView.swift` entry
      with the middle-button wiring — the three overrides and their state, the
      shared `clickSlop`, autoscroll during the drag, `stillSelecting` live vs.
      final, focus-on-press, and the note that the native Option-drag and the
      ⌘-click gesture are untouched
- [ ] `docs/FEATURES.md`: add the gesture to the editor's macOS feature list next
      to the existing selection/definition gestures — middle-button drag selects
      a column, a purely vertical drag gives multiple insertion points, a plain
      middle click just places the caret, and the wheel still scrolls
- [ ] `README.md`: add a row to the shortcut table for the middle-button drag
      (alongside the existing gesture rows) and, if it reads naturally, mention
      column selection in the editor feature bullet
- [ ] run `swift test` and `swiftlint --strict` — both must pass before Task 4

### Task 4: Verify acceptance criteria

- [ ] run `swift test` — the full `PisakaCore` suite must pass
- [ ] run `swiftlint --strict` from the repository root — must be clean, with no
      new in-file disables
- [ ] run `xcodegen generate` and
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`
      — must succeed
- [ ] run the iOS build
      (`-destination 'platform=iOS Simulator,name=iPhone 17 Pro'`) to confirm the
      new Core file stays iOS-compatible and no macOS API leaked into Core
- [ ] confirm by inspection that the new engine imports only Foundation and
      CoreGraphics, and that no view-layer file outside `CodeEditorView.swift`
      changed

## Post-Completion (manual verification, macOS app run)

These need a running app and are for the reviewer, not the agent:

- Middle-drag over tab-indented lines and lines shorter than the rectangle
  selects the same characters a native Option-drag over the same two points
  does.
- A single-line horizontal middle-drag (no vertical movement) selects that line's
  span — the degenerate-rect case.
- Dragging up/left behaves like down/right.
- A purely vertical middle-drag yields multiple carets; typing inserts on every
  touched line; deleting and copying behave as after an Option-drag.
- Dragging past the top/bottom (and side) edge autoscrolls and keeps extending.
- A middle click without movement places one caret and focuses an unfocused
  editor, and does nothing else.
- Option-drag, ⌘⌥-drag, ⌘-click go-to-definition and plain click/drag selection
  all still work; the wheel still scrolls.
