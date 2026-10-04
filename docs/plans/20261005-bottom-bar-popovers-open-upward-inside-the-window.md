# The two bottom-bar popovers open upward, inside the window, as one designed component

## Overview

The project switcher and the branch switcher currently present system popovers
(`.popover(isPresented:arrowEdge: .bottom)`). These open below the bar whenever they fit,
sit in a separate system window, draw a system arrow on a system material, and hold an
8-point stack of default controls. This plan replaces both with one in-window popover
component drawn to the design:

- It opens upward from its widget, left-aligned to it, 4 points above the bar, clamped
  inside the window.
- It has no arrow.
- It is built from three slots (Head / List / Foot) and shared pieces: row, project row,
  section header, message line, field block.
- It has keyboard navigation and a remote-row submenu.

Three things are pure Core rules: the placement arithmetic, the keyboard-selection
arithmetic, and the key rule that decides what each key does in each state.

The ticket leaves one architectural choice to the plan. This plan uses an **in-window
SwiftUI overlay** mounted once at the window root, not a child panel:

- An overlay is inside the window by construction and moves with it.
- It re-places itself on resize through the root's geometry.
- It never takes key status from the main window, so "closes when its window resigns key"
  stays a single notification.
- It needs no screen-coordinate conversion.

Dismissal and keys go through local `NSEvent` monitors, the same mechanism
`CompletionPanel.swift` already uses. Those monitors never swallow a click, so the rest of
the window is neither dimmed nor blocked.

## Context

- Files involved:
  - `Sources/Pisaka/ProjectSwitcherView.swift` and `Sources/Pisaka/BranchSwitcherView.swift`,
    both rewritten onto the component.
  - `Sources/Pisaka/ContentView.swift`: `ContentView.body` mounts the host overlay,
    `bottomBar` reports its top edge, and `BottomBar` keeps its current initializer.
  - `Sources/Pisaka/ChromeControls.swift`: `ChromeThemedTextField` gains an optional
    design-glyph leading slot.
  - `Sources/PisakaCore/ChromeGeometry.swift`: the popover tokens.
  - New Core files: `Sources/PisakaCore/PopoverPlacement.swift`,
    `Sources/PisakaCore/PopoverSelection.swift` and `Sources/PisakaCore/PopoverKeyRule.swift`.
  - New app files: `Sources/Pisaka/ChromePopover.swift` (container and pieces) and
    `Sources/Pisaka/ChromePopoverPresenter.swift` (open state, host overlay, monitors).
  - Tests: `Tests/PisakaCoreTests/PopoverPlacementTests.swift`,
    `Tests/PisakaCoreTests/PopoverSelectionTests.swift`,
    `Tests/PisakaCoreTests/PopoverKeyRuleTests.swift`,
    `Tests/PisakaCoreTests/ChromeThemeTests.swift`,
    `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`, and a new
    `Tests/PisakaAppTests/ChromePopoverLayoutTests.swift`.
  - Docs: `docs/architecture/core-theme.md`, `docs/architecture/app-window.md`,
    `docs/architecture/app-git-views.md`, `docs/FEATURES.md` and `CLAUDE.md`.
- Related patterns:
  - `CompletionPanel.swift`: a local `NSEvent` monitor installed while a floating surface is
    open and removed on close.
  - `TreeDraftDismissRule.swift`: a Core rule over `CGRect` geometry, unit-tested.
  - `ChromeThemedTextFieldLayoutTests` and `BottomBarLayoutTests`: `HostedRender` bitmap
    measurement at scale 1.0 and 1.8.
  - `DesignGlyphImage`: design glyphs, sized and hidden from accessibility by construction.
  - `ChromeGeometry`: one token per measurement, scaled at the use site, never a font size.
- Dependencies: none new.

## Development Approach

- **Testing approach**: Regular (code first, then tests), except that the Core rules in
  Task 1 are written test-first.
- Complete each task fully before moving to the next. `swift test` must be green at the end
  of every task. From Task 2 on, the app-layer bundle must be green too.
- `ChromeThemeSourceGatingTests` reads the source tree. Any task that changes a gated file
  updates the rules that read it in the same task, never later.
- Colours reach views as `ChromeColorRole` only, and no role is added. Measurements reach
  views as `ChromeGeometry` tokens, scaled through `InterfaceMetrics` at the use site. Fonts
  come from `metrics.scaledFont(...)` (`.body` is 13, `.subheadline` is 11).
- No product or brand names in code, comments, docs, tests or commit messages.
- xcodebuild uses the default DerivedData location, never a `-derivedDataPath` inside the
  repository.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Core placement, selection arithmetic, the key rule and the popover geometry tokens

**Files:**
- Create: `Sources/PisakaCore/PopoverPlacement.swift`
- Create: `Sources/PisakaCore/PopoverSelection.swift`
- Create: `Sources/PisakaCore/PopoverKeyRule.swift`
- Modify: `Sources/PisakaCore/ChromeGeometry.swift`
- Create: `Tests/PisakaCoreTests/PopoverPlacementTests.swift`
- Create: `Tests/PisakaCoreTests/PopoverSelectionTests.swift`
- Create: `Tests/PisakaCoreTests/PopoverKeyRuleTests.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeTests.swift`

- [x] Write `PopoverPlacement`, a Foundation-only enum of pure static functions over
  `CGRect`. It works in the window root's top-left, y-down coordinate space, which is the
  space SwiftUI's named coordinate space reports. Its doc comment states this convention.
- [x] Implement `popover(widget:barTop:window:width:maxHeight:gap:)`. It returns the
  popover's leading x, its bottom y and the height available to it:
  - Leading x is the widget's minX. When the widget is nearer the window's right edge than
    `width`, x shifts left to `window.maxX - width`. It never goes below `window.minX`.
  - Bottom is `barTop - gap`.
  - Available height is `min(maxHeight, bottom - window.minY)` and is never negative. When
    the window is too short, the container caps itself at this height and the List shrinks.
- [x] Implement `submenu(popover:anchorRowTop:size:window:gap:)`. It returns the submenu's
  frame:
  - It is placed `gap` to the right of the popover, with its top at the anchor row's top.
  - When it does not fit to the right, it goes `gap` to the left of the popover.
  - It is then clamped inside the window on both axes. It shifts up when its bottom would
    pass the window's bottom, and it never goes above the top.
- [x] Write `PopoverSelection`, a value type over a row count and an optional selected
  index:
  - `init(count:)` selects the first row, or nothing when the count is zero.
  - `movedDown()` and `movedUp()` clamp at the ends. There is no wrap.
  - `reset(count:)` returns to the first row. It is used whenever the filter changes.
  - The submenu uses the same type.
- [x] Write `PopoverKeyRule`, a Foundation-only enum with one pure static function,
  `action(for:state:)`. It holds every decision about which key does what in which state:
  - The key enum, `PopoverKey`, is closed: `up`, `down`, `return`, `escape`, `left`,
    `right`, `other`.
  - The state, `PopoverKeyState`, has three booleans: `submenuOpen`, `hasSelection` and
    `selectedHasSubmenu`.
  - The action enum, `PopoverKeyAction`, is closed: `moveUp`, `moveDown`, `activate`,
    `openSubmenu`, `closeSubmenu`, `dismiss`, `passThrough`.
  - **With the submenu open:**
    - ↑ gives `moveUp` and ↓ gives `moveDown` when there is a selection. Without one, both
      pass through.
    - Return gives `activate` when there is a selection, and passes through otherwise.
    - Esc and ← give `closeSubmenu`.
    - → and `other` pass through.
    - `selectedHasSubmenu` is ignored in this state.
  - **With the submenu closed:**
    - ↑ gives `moveUp` and ↓ gives `moveDown` when there is a selection. Without one, both
      pass through.
    - Return gives `openSubmenu` when the selected row has a submenu, `activate` when it
      does not, and passes through with no selection.
    - → gives `openSubmenu` when the selected row has a submenu, and passes through
      otherwise.
    - ← passes through.
    - Esc gives `dismiss`.
    - `other` passes through.
  - The doc comment states two things. First, `other` always passes through, so typing
    keeps reaching the filter field. Second, `selectedHasSubmenu` without `hasSelection` is
    impossible and is read as no selection.
- [x] Add the popover tokens to `ChromeGeometry`. Each gets a one-line comment, and none of
  them is a font size:
  - `popoverWidth` 300 and `popoverMaxHeight` 360.
  - `popoverBarGap` 4 (above the bar) and `popoverSubmenuGap` 4 (beside the popover). These
    are two measurements, so they get two tokens, following the type's own `barPaddingX`
    argument.
  - `popoverShadowOffsetY` 8 and `popoverShadowBlur` 24.
  - `popoverHeadPaddingBottom` 4, `popoverListPaddingBottom` 6 and
    `popoverFieldBlockPadding` 8.
  - `popoverRowHeight` 28, `popoverProjectRowHeight` 36, `popoverRowPaddingX` 12,
    `popoverRowGap` 6, `popoverRowGlyphSlot` 16 and `popoverProjectRowLineGap` 1.
  - `popoverSectionHeaderPaddingTop` 12, `popoverSectionHeaderPaddingX` 12 and
    `popoverSectionHeaderPaddingBottom` 4.
  - `popoverMessagePaddingY` 8 and `popoverMessagePaddingX` 12.
  - The container's corner radius reuses `cornerRadiusMax` (6), which the type defines as
    the one radius a chrome surface's corners take. Its stroke reuses `hairlineWidth`. The
    type's doc comment adds the new padding and gap tokens to its inventory sentence.
- [x] Placement tests, each with literal frames:
  - The ordinary case: left-aligned, bottom 4 above the bar, full height.
  - A widget near the right edge: the popover shifts left so its maxX is the window's maxX.
  - A window narrower than the popover: x is pinned at minX.
  - A short window: the available height is below 360, and the bottom is still 4 above the
    bar.
- [x] Submenu tests:
  - It fits to the right.
  - It flips to the left.
  - It is clamped up from the window's bottom.
- [x] Selection tests:
  - The first row is selected on init.
  - An empty count gives no selection.
  - Moving down and up clamps at both ends.
  - `reset` returns to the first row after any move.
  - A reset to a smaller count stays in range.
- [x] Write `PopoverKeyRuleTests`. It enumerates every (key, state) pair, which is
  7 keys × 8 states = 56 cases, against one literal expected-action table, and asserts the
  table covers every case by set equality. Named assertions also cover:
  - `other` passes through in all eight states, so the filter field keeps typing.
  - ← and → pass through whenever they mean nothing: ← with the submenu closed, → with the
    submenu open, and → on a row with no submenu.
  - Esc closes the submenu alone when one is open and dismisses otherwise.
  - Return on a row with a submenu opens it rather than activating.
  - The impossible combination reads as no selection.
- [x] Update `ChromeThemeTests` so the token inventory's set equality and its value
  assertions include every new token.
- [x] Run `swift test`. It must pass before Task 2.

### Task 2: The popover component and its shared pieces

**Files:**
- Create: `Sources/Pisaka/ChromePopover.swift`
- Modify: `Sources/Pisaka/ChromeControls.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `CLAUDE.md`, `docs/architecture/core-theme.md` (the gated-file count only, if it
  changes)

- [x] Write `ChromePopover<Head, List, Foot>`, the container, under `#if os(macOS)`:
  - Width: `popoverWidth`, scaled.
  - Height: it hugs its content up to a `maxHeight` passed in, which is the placement's
    available height, already capped at `popoverMaxHeight`. Only the List scrolls. The Head
    and Foot are fixed, and the List takes the remaining height, hugging its content when
    that is shorter.
  - Corners `cornerRadiusMax`, fill `bgPopover`, and a 1-point `hairline` stroke.
  - A shadow in `bgCanvas`: x 0, y `popoverShadowOffsetY`, radius `popoverShadowBlur / 2`.
    A comment states the conversion from a design blur to a SwiftUI shadow radius.
  - No arrow and no material.
  - Head: bottom padding `popoverHeadPaddingBottom` and a `hairline` rule along its bottom.
  - List: bottom padding `popoverListPaddingBottom`, clipped.
  - Foot: a `hairline` rule along its top, drawn only when the caller passes a Foot. An
    optional Foot, or an `EmptyView` check, decides this. The Head is optional in the same
    way, because the submenu has none.
- [x] Write the pieces, all in this file:
  - **`ChromePopoverRow`**:
    - Height `popoverRowHeight`, horizontal padding `popoverRowPaddingX`, gap
      `popoverRowGap`.
    - A leading slot `popoverRowGlyphSlot` wide, holding an optional `DesignGlyphImage` at
      14, or nothing.
    - The title in `.body` and `textPrimary`, one line, truncated in the middle.
    - An `isCurrent` flag that draws the title in `accent` with `.check` in the slot.
    - An optional trailing `chevronRight` (12) in `textSecondary`, switching to
      `textPrimary` while the row is hovered or selected.
    - The ground is `accentTintStrong` when selected, otherwise `hoverTint` when hovered,
      otherwise clear. Selection wins.
    - One accessibility element whose label is the title, with an optional value and an
      optional hint. The remote row uses the hint to say it opens a submenu.
  - **`ChromePopoverProjectRow`**:
    - Height `popoverProjectRowHeight`, with the same slot, padding and ground rules.
    - The name in `.body` and `textPrimary` (`accent` when current). The path in
      `.subheadline` and `textSecondary`, one line, truncated in the middle.
      `popoverProjectRowLineGap` between them.
  - **`ChromePopoverSectionHeader`**: `.subheadline` semibold in `textSecondary`, with top,
    side and bottom padding from the three header tokens.
  - **`ChromePopoverMessage`**: `.subheadline`, with padding `popoverMessagePaddingY` and
    `popoverMessagePaddingX`, and a role passed in (`textSecondary` for empty states,
    `statusRed` for the error).
  - **`ChromePopoverFieldBlock`**: wraps any field, stretched to the inner width, with
    `popoverFieldBlockPadding` on all sides.
- [x] Give `ChromeThemedTextField` an optional `designGlyph: DesignGlyph?` leading slot,
  drawn through `DesignGlyphImage` at size 14 in `textSecondary`. The existing
  `glyph: String?` callers stay unchanged.
- [x] Update `ChromeThemeSourceGatingTests` for the new file:
  - Add `ChromePopover.swift` to `gatedFiles`.
  - Add it to the `bgPopoverReaders` set of rule twenty-three. During this task the switcher
    files still name `bgPopover` too; they leave in Task 4.
  - Adjust any rule that enumerates gated files and their glyphs.
  - Run the suite to find every rule the new file trips.
  - If the gated-file count changes, update the spelled count in the suite, in `CLAUDE.md`'s
    theme invariant ("sixty-one") and in `core-theme.md`'s inventory paragraph, all
    together.
  - No rule is added or removed here.
- [x] Run `swift test`, the app-layer bundle (`xcodebuild -project Pisaka.xcodeproj -scheme
  Pisaka -destination 'platform=macOS' test`) and `swiftlint --strict`. All must pass before
  Task 3.

### Task 3: The presenter, the host overlay and placement at the window root

**Files:**
- Create: `Sources/Pisaka/ChromePopoverPresenter.swift`
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift` (only if a rule reads
  the changed sites)

- [x] Write `ChromePopoverPresenter`, a `@MainActor` `ObservableObject`.
  - **State it holds:**
    - The open popover's identity, its anchor widget frame and its content (`AnyView`; the
      content structs observe their own models).
    - The bar's top edge.
    - The ordered row actions the open content registers: `id`, `activate`, and optional
      submenu rows. An action row is an ordinary entry.
    - The main `PopoverSelection` and an optional submenu (anchor row id, anchor row top,
      rows, and its own `PopoverSelection`).
    - The current frames of the popover and the submenu.
  - **API:**
    - `present(id:anchor:content:)`, which toggles when the same id is already open.
    - `dismiss()`.
    - `setRows(_:)`, which resets the selection to the first row.
    - `openSubmenu(for:)`, `closeSubmenu()` and `activateSelected()`.
  - **Environment:** an environment key carries an optional presenter. When there is none in
    the environment (as when `BottomBarLayoutTests` and `BottomBarToolTipTests` host
    `BottomBar` alone), a widget's button does nothing harmful.
- [x] Write the host overlay view, `ChromePopoverHost`, and mount it once in
  `ContentView.body`:
  - It sits inside the modifiers that inject `chromeTheme` and `interfaceMetrics`, so it
    inherits both and adds no injection root.
  - It sits above the bar's `.zIndex(1)`.
  - The root declares a named coordinate space, and the widgets, the bar and the rows report
    their frames in it.
  - The host reads the root's size through a `GeometryReader` and calls
    `PopoverPlacement.popover(...)` with the widget frame, the bar top, the root bounds, and
    `popoverWidth`, `popoverMaxHeight` and `popoverBarGap`, all scaled.
  - It positions the container bottom-leading at the result and passes the available height
    as the container's `maxHeight`.
  - When the submenu is open, it is the same `ChromePopover` with no Head, holding two
    `ChromePopoverRow`s. It is placed by `PopoverPlacement.submenu(...)` with
    `popoverSubmenuGap` scaled, and its height is known from the row tokens and the List
    padding.
  - A window resize re-places it through the geometry. A window move needs nothing.
  - The overlay hit-tests only the drawn surfaces, so the rest of the window stays
    interactive.
- [x] `ContentView.bottomBar` reports the bar's top edge to the presenter. `BottomBar`'s
  initializer and stored properties do not change, so its two existing suites compile and
  run unchanged.
- [x] Monitors and observers are installed on present and removed on dismiss, scoped to the
  root's window:
  - **Mouse:** a local monitor for left, right and other mouse-down. A click outside the
    popover's frame, the submenu's frame and the anchor widget's frame dismisses and is
    returned unconsumed. A click on the widget is left to the widget's toggle.
  - **Keys:** a local key-down monitor with no key logic of its own. It does three things:
    - It maps the event to `PopoverKey`: key code 126 is `up`, 125 `down`, 36 and 76
      `return`, 53 `escape`, 123 `left`, 124 `right`. Anything else, and any of these
      carrying ⌘, ⌃ or ⌥, is `other`.
    - It builds `PopoverKeyState` from its own state and calls
      `PopoverKeyRule.action(for:state:)`.
    - It executes the returned action against the matching `PopoverSelection` (the
      submenu's when it is open) or the presenter API. `passThrough` returns the event
      unconsumed, and every other action consumes it. The field therefore keeps the text
      focus throughout, and typing keeps filtering.
  - **Key window:** `NSWindow.didResignKeyNotification` for that window dismisses.
- [x] Every row activation dismisses everything before running its closure. The current
  branch's row and the current project's row only dismiss.
- [x] Tests: the key decisions are `PopoverKeyRule`'s and are enumerated in Task 1, as is
  the placement and selection arithmetic. What remains here is the key-code mapping and the
  wiring, which Task 4's content and Task 5's suite exercise. Run `swift test`, the
  app-layer bundle and `swiftlint --strict`. All must pass before Task 4.

### Task 4: Both switchers on the component, with the submenu and the keyboard model

**Files:**
- Modify: `Sources/Pisaka/BranchSwitcherView.swift`
- Modify: `Sources/Pisaka/ProjectSwitcherView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `CLAUDE.md`, `docs/architecture/core-theme.md` (rule count only, if a rule is
  added or removed)

- [ ] Shared changes to both widgets:
  - Each widget keeps its button label, tooltip, accessibility label and value, and disabled
    rule, unchanged.
  - `.popover(...)` and `@State isPresented` are removed. The button records its frame in
    the root's coordinate space and calls `presenter.present(...)`.
  - The sentence "the popover's arrow keeps the system material" disappears from both files.
- [ ] Branch popover: `BranchSwitcherView.swift` gains a `BranchSwitcherPopover` view struct
  holding the model, the four closures, the selected row id and a dismiss closure. It
  builds:
  - **Head:**
    - A `ChromePopoverFieldBlock` with the themed field: placeholder "Filter branches",
      design glyph `.search`, `.body` text, focused on appear.
    - A "New Branch…" `ChromePopoverRow` with `.gitBranch`.
  - **List:**
    - "Local" and "Remote" `ChromePopoverSectionHeader`s, each omitted when its section is
      empty.
    - Local rows: `ChromePopoverRow`, with `isCurrent` drawing accent plus check, an empty
      slot otherwise, and the accessibility value "Current branch" on the current row.
    - Remote rows: `ChromePopoverRow` with the trailing chevron and the submenu hint.
      Clicking one opens the submenu, whose rows are "Checkout" and
      "New Branch from '<shortName>'…", calling `onCheckoutRemote` and `onCreateFromRemote`
      respectively.
    - "No branches" as a `textSecondary` `ChromePopoverMessage` when both sections are
      empty.
  - **Foot:** `model.errorMessage` as a `statusRed` `ChromePopoverMessage`, and no Foot
    otherwise.
  - **Row registration:** it registers its row actions in display order (the action row
    first) on appear and on every `filterText` change. The selection resets to the first row
    each time.
- [ ] Project popover: `ProjectSwitcherView.swift` gains a `ProjectSwitcherPopover` struct,
  with its rows read at open time as today. It builds:
  - **Head:** "Open Folder…" with `.folderOpen`.
  - **List:** a "Recent" header plus `ChromePopoverProjectRow`s (the accessibility value
    "Current project" on the current row), or "No recent projects" as a `textSecondary`
    message.
  - It registers its rows the same way.
- [ ] Every SF Symbol row glyph ("checkmark", "folder", "cloud", "arrow.triangle.branch",
  "plus", "folder.badge.plus") is gone, and so is the remote row's `Menu`.
- [ ] Update `ChromeThemeSourceGatingTests`: re-read every rule that names either file, and
  move each pin to where the code now lives.
  - Rule twenty-three's `bgPopoverReaders` drops both switcher files, since
    `ChromePopover.swift` is now the reader. The "presents a popover" half no longer sees
    `.popover(` in them.
  - Rule twenty-four's `menuFiles` drops `BranchSwitcherView.swift`.
  - The glyph-sizing exemptions for `branchRow(`, `remoteBranchRow(` and `projectRow(` are
    removed, because the rows now draw design glyphs sized by construction. The comment
    above them is corrected.
  - Rule ten's reading of the bar widgets' glyphs and values is re-checked against the
    widgets' new bodies.
  - The bar-label `lineLimit` rule is re-checked.
  - Rule twenty-six's field constructors and the drawn-name caller counts stay as they are
    unless the call moved files.
  - Each suite comment that described the old popover rows is updated.
  - If a rule is added or removed, the spelled rule count changes in the suite, in
    `CLAUDE.md` and in `core-theme.md`'s canonical list, all together.
- [ ] Confirm that `BottomBarLayoutTests` and `BottomBarToolTipTests` pass unmodified.
- [ ] Run `swift test`, the app-layer bundle and `swiftlint --strict`. All must pass before
  Task 5.

### Task 5: Bitmap suite for the component's measurements

**Files:**
- Create: `Tests/PisakaAppTests/ChromePopoverLayoutTests.swift`

- [ ] Write `ChromePopoverLayoutTests`, rendering through the shared `HostedRender`:
  - It uses a stub `GitServicing` that answers a fixed list (a current local branch, a
    second local branch and one remote) plus an error message, so the Foot draws, followed
    by `await model.refresh(root:)`.
  - It hosts `BranchSwitcherPopover` inside a `ChromePopover` with the first row
    ("New Branch…") selected, at interface scale 1.0 and 1.8.
  - It hosts `ProjectSwitcherPopover` with two recent rows and the first list row selected,
    at both scales.
  - That makes four renders and four windows in total, which the suite's header states.
    There is no render per row and no screen-recording API.
- [ ] Measurements off each branch bitmap, all within half a point:
  - The container's width: the `hairline` stroke columns are 300 × scale apart.
  - The field block: the field box's top minus the container's top edge, and the selected
    row's top minus the field box's bottom, are each 8 × scale.
  - The selected "New Branch…" row's `accentTintStrong` extent is 28 × scale.
  - The Head's bottom rule and the Foot's top rule are rows of `hairline` exactly 1 × scale
    thick.
  - A section header's height: the distance from the Head's rule to the first Local row's
    top, minus that row's position, equals 12 × scale plus 4 × scale plus the 11-point
    semibold line height at that scale, within one point.
- [ ] Measurement off the project bitmap: the selected project row's `accentTintStrong`
  extent is 36 × scale.
- [ ] Run the app-layer bundle and `swift test`. Both must pass before Task 6.

### Task 6: Documentation

**Files:**
- Modify: `docs/architecture/core-theme.md`
- Modify: `docs/architecture/app-window.md`
- Modify: `docs/architecture/app-git-views.md`
- Modify: `docs/FEATURES.md`
- Modify: `CLAUDE.md`

- [ ] `core-theme.md`:
  - New entries for `PopoverPlacement.swift`, `PopoverSelection.swift`,
    `PopoverKeyRule.swift`, `ChromePopover.swift` and `ChromePopoverPresenter.swift`.
    Together they cover:
    - the placement rule and its clamps, including the submenu's flip;
    - the three slots and the rule for when the Foot is present;
    - every literal as its token;
    - the keyboard model: the key rule's full table, what passes through to the field, and
      that the presenter only maps key codes and executes the rule's action;
    - the in-window overlay choice and why it was made;
    - the fact that the design's two popovers are one component.
  - The popover passages and the gating inventory are updated: rule twenty-three's readers,
    the menu files, the glyph exemptions, and the gated-file and rule counts if they
    changed.
  - Every "arrow keeps the system material" sentence is removed.
- [ ] `app-window.md` (`ProjectSwitcherView`) and `app-git-views.md` (`BranchSwitcherView`)
  state the new behaviour and drop the arrow and `Divider()` sentences.
- [ ] `docs/FEATURES.md`: one line saying the project and branch popovers support
  ↑/↓/Return/Esc and that → opens a remote branch's actions.
- [ ] `CLAUDE.md`:
  - The core-theme index line gains `PopoverPlacement.swift`, `PopoverSelection.swift` and
    `PopoverKeyRule.swift` (Core list) and `ChromePopover.swift` and
    `ChromePopoverPresenter.swift` (app surfaces). Nothing else changes, apart from the
    gated-file and rule counts if Tasks 2 and 4 changed them.
  - The file stays under 60,000 characters.
- [ ] Run `swift test`, which runs `LintConfigurationTests` (it checks the `CLAUDE.md` size)
  and the doc-reading suites. It must pass.

### Task 7: Verify acceptance criteria

- [ ] Run `swift test`.
- [ ] Run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS'
  test`.
- [ ] Run `swiftlint --strict` from the repository root.
- [ ] Run `xcodegen generate`, then `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka
  -destination 'platform=macOS' -configuration Release build`.
- [ ] Run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
  'generic/platform=iOS' build`. This confirms that the three new Core files
  (`PopoverPlacement.swift`, `PopoverSelection.swift`, `PopoverKeyRule.swift`) compile for
  iOS.
- [ ] Confirm by grep that no `.popover(` remains in either switcher file, and that no
  "system material" sentence about these popovers remains in code or docs.

## Post-Completion

- Manual check in a Debug build, with a window placed low on the screen:
  - Both popovers open upward, left-aligned, 4 points above the bar, with no arrow and
    nothing drawn outside the window.
  - The field is focused and shows the search glyph.
  - ↑/↓ move the selection while typing still filters.
  - → or Return on a remote row opens the submenu beside it, and ← or Esc close the
    submenu alone.
  - A click elsewhere, or switching to another app, closes the popover without swallowing
    the click.
