# The database viewer's sidebar becomes resizable and collapsible

## Overview

The database viewer's sidebar (tables, views, the selected table's schema) is pinned at a fixed `metrics.scaled(220)` width. A long name truncates and the reader has no way to see the rest of it. This change does three things:

- The column becomes resizable through a hand-drawn divide: a hairline with an invisible drag strip over it, never an `HSplitView`.
- The sidebar can fold away to a narrow strip, and that strip carries the only control that can unfold it.
- The grid gets its own floor inside the existing `VSplitView`, so the vertical divide can no longer squeeze it to nothing.

This is a layout fix in one already-swept chrome file, `Sources/Pisaka/DatabaseViewerView.swift`. There is no colour change, no new role, no new preference, no new Core rule, and nothing is persisted. The width and the folded state live for the session only.

Three pinned sets in the chrome gating suite move with it: rules twenty, twenty-two and thirty. Each is updated to state what is now true and is never widened. Rule thirty-four is satisfied without a pin moving, because each new glyph carries its own metrics-scaled font. No exemption entry may be added for it.

## Context

- Files involved:
  - `Sources/Pisaka/DatabaseViewerView.swift`: the only source file that changes.
  - `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`:
    - rule twenty's `panelControlBuilders` entry for `DatabaseViewerView.swift`, with its comment
    - rule twenty-two's `cursorPushingFunctions`, with its doc comment
    - rule thirty's `partFiveDButtonCounts` entry, with its comment
  - `docs/architecture/core-database-viewer.md`: the `DatabaseViewerView.swift` entry.
  - `docs/architecture/core-theme.md`:
    - numbered item 22
    - the entry that records a surface's own divide as a hairline with a drag strip (the Log panel already has one)
- Related patterns:
  - `Sources/Pisaka/CommitLogView.swift`:
    - The `CommitLogLayout` holder: plain constants, each with a one-line reason, none derived from a `ChromeGeometry` token (rule seven).
    - `clampedDetailWidth(total:)` is the clamp shape:
      - maximum = `max(minimum, total − neighbour's minimum)`
      - wanted = the session width, or the ideal width if none is set
      - result = `min(max(wanted, minimum), maximum)`
    - A `GeometryReader` wraps the horizontal stack to read the total.
  - `Sources/Pisaka/LeetCodeDescriptionView.swift`: the fold and the resize handle.
    - `@State` for the session width, the drag-start width, `isCollapsed`, the hover flag, and a separate flag for whether this view holds a push.
    - A transparent 5-point strip with the hairline centred as an overlay.
    - A `DragGesture(minimumDistance: 0, coordinateSpace: .global)` whose base comes from the rendered (clamped) width and which skips the zero-translation opening frame.
    - The one `sync…Cursor()` function is the only thing that pushes or pops.
    - `onDisappear` clears hover and the drag-start width, then syncs.
    - `collapsedStrip` holds the only unfold button.
    - Icon glyphs carry their own `.font(metrics.scaledFont(.body))` and `.accessibilityHidden(true)`. The button is named through `.help` and `.accessibilityLabel`.
  - The existing `pagingGlyph(_:)` in the same file is the glyph shape to mirror. Its rule-twenty `ControlBuilder` entry is the shape the new glyph helper's entry copies.
  - `ContentView.swift` builds `BottomPanelHeightRule(floor: metrics.scaled(120), dividerHeight: metrics.scaled(5), editorMinimum: metrics.scaled(120))`. With the bottom dock at its ceiling, the editor zone (where a viewer tab lives) keeps only 120 scaled points. That is the bound the vertical split's floors answer to, not the window's content minimum.
- Pins that must NOT move:
  - The footer's `labelCount: 3` entry and the `pagingGlyph` entry in rule twenty. Neither new button goes in the footer.
  - `DatabaseViewerSourceGatingTests`' disable-term counts. The new buttons carry no `.disabled(model.isWriteInFlight)`.
  - The gated-file, menu-separator, shared-field and spinner pins.
  - Rule thirty-four's exemption list.
  - The rule count, which stays forty-three.
- Dependencies: none.

## Development Approach

- **Testing approach**: Regular. SwiftUI glue is untested by convention, so the test movement is the gating suite's pins. They live in `Tests/PisakaCoreTests/`, so `swift test` covers them. Each pin is updated in the same task as the code that moves it.
- A pin is always updated to state the new truth: a new name in a set, a new entry, or a new count with its comment. It is never widened into a pattern and never deleted. If any pin other than the three named ones goes red, stop and find out why rather than loosening it.
- Every measurement goes through `metrics.scaled(…)`, because the sidebar, its strip and its divide are all in the interface zone.
- No product or brand names in code, comments, docs or commit messages.
- Local `xcodebuild` runs use a derived-data path outside the repository, for example `~/Library/Developer/Xcode/DerivedData/pisaka-<purpose>`, never inside `~/git/pisaka`.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: The layout holder and the grid's floor

**Files:**
- Modify: `Sources/Pisaka/DatabaseViewerView.swift`

- [x] Add a file-local `private enum DatabaseViewerLayout` of plain `Double` constants in `CommitLogLayout`'s shape. Each constant carries a one-line reason, and the enum's doc comment says none of them is derived from a `ChromeGeometry` token. Entries:
  - `sidebarIdealWidth` = 220: the existing literal, now the width before any drag.
  - `sidebarMinWidth` = 160: a table name and its key glyph still fit.
  - `gridMinWidth` = 320: a column or two stays readable beside a widened sidebar.
  - `divideHitWidth` = 5: the drag strip's width, matching the Log's divide and the statement pane's handle.
  - `collapsedStripWidth` = 28: matching the statement pane's folded strip.
  - `sidebarHeaderHeight` = 24: the strip carrying the fold button, the same height as the statement pane's header.
  - `gridMinHeight` = 40: the grid's floor inside the vertical split. This is the header row plus one data row, read off the file's own numbers. Both rows are set in the interface `caption` font (about 13 points of line height at scale one). The header row pads 4 + 4 and a data row pads 3 + 3, giving about 21 + 19.
  - `consoleMinHeight` = 140: moved in from the call site, value and meaning unchanged.
- [x] Give `gridMinHeight` a reason comment that states:
  - the real bound: the editor zone's minimum, which `BottomPanelHeightRule`'s `editorMinimum` sets at 120 scaled points when the bottom dock is at its ceiling. It is not the window's content minimum.
  - that the console's 140 already exceeds that zone on its own. The grid's floor is therefore kept at the smallest honest size (the grid stops vanishing without growing the overshoot by more than one header row and one data row).
  - that the console's 140 is left exactly as it is.
- [x] In `body`, give the grid inside the `VSplitView` `minHeight: metrics.scaled(DatabaseViewerLayout.gridMinHeight)`. Replace the console's literal with `metrics.scaled(DatabaseViewerLayout.consoleMinHeight)`.
- [x] Run `swift test` and confirm it is green with no pin moved yet. Rule seven must stay green on the new holder. If it goes red, a constant was derived from a chrome token, and that is the defect.

### Task 2: The resizable divide and its clamp (rule twenty-two moves)

**Files:**
- Modify: `Sources/Pisaka/DatabaseViewerView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [x] Add session state, each with a doc comment saying it is session-only, following the statement pane and the Log's detail width:
  - `@State private var sidebarWidth: CGFloat?` (nil means the ideal width)
  - `@State private var sidebarDragStartWidth: CGFloat?`
  - `@State private var isHoveringSidebarDivide = false`
  - `@State private var sidebarDivideCursorPushed = false`
- [x] Wrap the body's `HStack` in a `GeometryReader` and pass its total width. Add `clampedSidebarWidth(total:)`:
  - minimum = `metrics.scaled(sidebarMinWidth)`
  - maximum = `max(minimum, total − metrics.scaled(gridMinWidth))`
  - wanted = `sidebarWidth ?? metrics.scaled(sidebarIdealWidth)`
  - result = `min(max(wanted, minimum), maximum)`

  Its doc comment says the floor on the maximum is the answer when the two bounds cross in a narrow window.
- [x] Replace the standalone `hairline(horizontal: false)` between the sidebar and the split with `sidebarDivide(total:)`. It is a `Color.clear` strip `metrics.scaled(divideHitWidth)` wide, with the vertical `hairline` as its overlay so the rule is still drawn exactly once, plus `.contentShape(Rectangle())`. It carries:
  - `.onHover`, which sets the hover flag and syncs.
  - `.onDisappear`, which clears the hover flag and `sidebarDragStartWidth`, then syncs. Its comment says why: a tab closed with the pointer on the strip or mid-drag gets neither a hover-exit nor a drag-end, and the cursor stack is global.
  - `DragGesture(minimumDistance: 0, coordinateSpace: .global)`:
    - its base comes from the rendered clamped width, and the zero-translation opening frame is skipped
    - it writes `sidebarWidth = clamp(base + translation.width)`; the sign is the mirror of the statement pane's, because the sidebar is on the left
    - `onEnded` drops the base and syncs
  - Brief comments stating the global coordinate space and the rendered-base reasons, pointing at the statement pane's handle rather than restating its essay.
- [x] Add `syncSidebarDivideCursor()`, the only function that pushes or pops. It pushes when `isHoveringSidebarDivide || sidebarDragStartWidth != nil` and no push is held. It pops when neither is true and a push is held.
- [x] Lay the sidebar out at the clamped width instead of the hard literal.
- [x] Update rule twenty-two:
  - Add `"DatabaseViewerView.swift: syncSidebarDivideCursor"` to `cursorPushingFunctions`.
  - In the rule's doc comment, change "all four" to "all five" and add that the database viewer's sidebar divide joined in this change.
- [x] Run `swift test`. It must be green, with rule twenty-two passing on the real function and no other pin moved.

### Task 3: Folding the sidebar away (rules twenty and thirty move)

**Files:**
- Modify: `Sources/Pisaka/DatabaseViewerView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [ ] Add `@State private var isSidebarCollapsed = false`, session state like the width.
- [ ] Add `sidebarGlyph(_:)` in `pagingGlyph`'s shape: an `Image(systemName:)` with its own `.font(metrics.scaledFont(.body))`, `textSecondary` and `.accessibilityHidden(true)`. Each glyph is sized on its own chain, so rule thirty-four needs no exemption entry.
- [ ] Give the sidebar a top header declaration, `private var sidebarHeader: some View`:
  - `metrics.scaled(sidebarHeaderHeight)` tall on `bgPanel`, with a bottom `hairline`.
  - A trailing `.plain` button labelled `sidebarGlyph("sidebar.left")`, with `.help("Hide the sidebar")` and `.accessibilityLabel("Hide the sidebar")`. Its action sets `isSidebarCollapsed = true`.
  - The glyph is `sidebar.left`, not `chevron.left`, because `chevron.left` already means "previous page" in this file's footer. One glyph must not mean two things in one tab.
- [ ] Add `private var collapsedSidebarStrip: some View`:
  - a `metrics.scaled(collapsedStripWidth)`-wide `bgPanel` column
  - a `.plain` button labelled `sidebarGlyph("sidebar.left")`, with `.help("Show the sidebar")` and `.accessibilityLabel("Show the sidebar")`; its action sets `isSidebarCollapsed = false`
  - Hide and Show share the glyph because they are never on screen together.
  - Its doc comment says this is the only control that can unfold the sidebar, so the sidebar can never be folded away with the way back lost.
- [ ] When folded, the body lays out the strip, then a plain vertical `hairline` (no drag strip, since nothing is resizable while folded), then the split.
  - The divide leaves the tree when the sidebar folds, so its `onDisappear` releases any push. Say that in a comment.
  - The clamp is only asked when the sidebar is shown.
- [ ] Update rule twenty's `panelControlBuilders` entry for `DatabaseViewerView.swift`, keeping the footer and `pagingGlyph` builders unchanged. Add:
  - `ControlBuilder(path: ["private var sidebarHeader: some View"], required: [".accessibilityLabel("], hidesSymbols: true, labelCount: 1)`
  - `ControlBuilder(path: ["private var collapsedSidebarStrip: some View"], required: [".accessibilityLabel("], hidesSymbols: true, labelCount: 1)`
  - `ControlBuilder(path: ["private func sidebarGlyph("], required: [".accessibilityHidden(true)"], hidesSymbols: true)`
- [ ] Extend that entry's comment:
  - The header holds the icon-only Hide button, and the strip holds the icon-only Show button, the only way back.
  - Each spells exactly one label because each holds exactly one control. The count makes deleting either label red: rule twenty has no completeness check, so an unlisted builder would leave the label unguarded.
  - The glyph helper is hidden where it is drawn, like `pagingGlyph`.
- [ ] Update rule thirty's `partFiveDButtonCounts` entry for `DatabaseViewerView.swift` from `(buttons: 6, styled: 4)` to `(buttons: 8, styled: 6)`. Rewrite its comment to name the sidebar's Hide and Show buttons among the styled ones, with the cell menu's Copy and Set to NULL still the two unstyled menu items.
- [ ] Run `swift test`. It must be green:
  - rules twenty, thirty and thirty-four pass
  - the footer's `labelCount: 3` and the `pagingGlyph` builder are unchanged
  - no rule-thirty-four exemption entry was added
- [ ] Temporarily delete one of the new `.accessibilityLabel(` calls and confirm rule twenty goes red, then restore it.

### Task 4: Update documentation

**Files:**
- Modify: `docs/architecture/core-database-viewer.md`
- Modify: `docs/architecture/core-theme.md`

- [ ] In `core-database-viewer.md`'s `DatabaseViewerView.swift` entry, describe:
  - The sidebar divide: a hand-drawn hairline with a 5-point drag strip, not an `HSplitView`, because a platform divider is drawn in a colour no chrome role reaches.
  - The clamp against the sidebar's own minimum and the grid's minimum, with the crossed-bounds answer and the Log's detail pane as the precedent.
  - The fold: its leftover strip holds the only unfold control, and Hide and Show both use `sidebar.left` because `chevron.left` means paging in this tab.
  - The cursor released from `onDisappear` (rule twenty-two).
  - The grid's floor inside the `VSplitView`:
    - It is the header row plus one data row.
    - Its real bound is the editor zone's 120-point minimum from `BottomPanelHeightRule`'s `editorMinimum`.
    - The console's unchanged 140 already exceeds that bound alone, which is why the grid had no floor before and why this one is kept minimal. State this as a known limit.
  - That the width and the fold are session state, with no `SettingsStore` key and no Core rule. Nothing is written, so there is nothing to clamp at write time, and two sibling panes already answer the question in the view. Word this so a later reader does not add a preference by reflex.
- [ ] In `core-theme.md`, numbered item 22: its list of pushing functions spells the Log divide's, the two `ContentView` dividers' and the statement pane's `syncResizeHandleCursor`. Add the viewer's `syncSidebarDivideCursor` by name, and make the item's prose about which divides exist mention the database viewer's sidebar divide.
- [ ] In `core-theme.md`, record beside the Log panel's matching entry that the database viewer's sidebar divide is now a hand-drawn hairline with a drag strip rather than a platform divider.
  - The `VSplitView` divider stays listed as the named open departure; do not touch it.
  - The rule count stays forty-three, so the cross-file rule-count sentences in `core-theme.md` and `CLAUDE.md` do not change.
- [ ] `CLAUDE.md` is not modified.
- [ ] Run `swift test` again, since the doc and count suites read these files. It must be green.

### Task 5: Verify acceptance criteria

- [ ] Run `swift test`. It must be green at 5816 tests: none added or removed, three pins restated.
- [ ] Run `xcodegen generate`, then `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-sidebar test`. It must be green at 126 tests.
- [ ] Run `swiftlint --strict` from the repository root. It must be clean across 591 files.
- [ ] Run `xcodebuild … -configuration Release -destination 'platform=macOS' build` with the same out-of-repo derived-data root. It must succeed.
- [ ] Run `xcodebuild … -destination 'generic/platform=iOS' build`. It must succeed.
- [ ] Re-read the diff of `ChromeThemeSourceGatingTests.swift` and confirm exactly three pins changed, none widened:
  - twenty: three builders added and the comment extended
  - twenty-two: the set and the doc sentence
  - thirty: the entry and its comment
  - thirty-four: no exemption entry

## Post-Completion

- Manual check in a DEBUG build, on a database with a long table name:
  - Drag the divide both ways and confirm it tracks the pointer without oscillating.
  - Shrink the window until the bounds cross and confirm the sidebar holds its minimum.
  - Fold and unfold the sidebar, and confirm the folded strip's button is the only way back and works.
  - Close the viewer tab mid-drag and confirm the resize cursor does not stick.
  - Drag the vertical split and confirm the grid stops at its floor, keeping the header and one row visible.
  - With the bottom dock dragged to its ceiling, look at how the split behaves in the 120-point editor zone.
