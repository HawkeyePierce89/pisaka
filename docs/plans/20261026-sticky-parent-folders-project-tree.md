# Sticky parent folders in the project tree (macOS)

## Overview

When you scroll through a long expanded folder, the project tree keeps the row of every
expanded ancestor whose own row has scrolled above the viewport. Those rows are pinned at the
tree's top edge, directly under the pane header, so you can always see which folders contain
what is on screen. It is a navigation aid only. It changes nothing about what the tree holds or
what any operation addresses.

Core makes every decision. A new pure rule, `TreeStickyRule`, gets the expanded folders'
measured extents, the viewport and the row height. It answers which rows are pinned, in what
order, where each is drawn (including the push-out offset) and how tall the stack is. The same
rule answers the anchor that places a scrolled-to row below the stack, through one function
shared by the pinned-row click and the draft placement. The SwiftUI layer measures and draws.

All app code stays in `ProjectTreeView.swift`. That file has about 1,224 non-comment lines
against SwiftLint's 1,982 limit. Staying in it means the chrome-theme gated set (sixty-six
files) and the counts restated in `CLAUDE.md` and `core-theme.md` do not change.

## Context

- Files involved:
  - Create: `Sources/PisakaCore/TreeStickyRule.swift`,
    `Tests/PisakaCoreTests/TreeStickyRuleTests.swift`,
    `Tests/PisakaAppTests/TreeStickyStackLayoutTests.swift`,
    `Tests/PisakaAppTests/TreeStickyScrollListingTests.swift`
  - Modify: `Sources/Pisaka/ProjectTreeView.swift`,
    `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift` (rule thirty-five's pinned
    row-background expressions only), `docs/FEATURES.md`, `docs/architecture/app-window.md`,
    `docs/architecture/core-workspace.md`, `docs/architecture/core-theme.md` (only where it
    inventories rule thirty-five's expressions), `CLAUDE.md`
- Related patterns:
  - `TreeChainRule` / `TreeRevealRule` are pure Core tree rules with their entries in
    `core-workspace.md`.
  - `TreeListingSource` / `TreeDragSession` are `ObservableObject` holders with nothing
    published, so the tree root is never invalidated by them.
  - `TreeRowState` + `TreeRowBackground.color(for:resolving:)` is the one row-background
    mapping.
  - `TreeIndentGuide`, `DesignGlyphImage`, `treeDiagnosticDot`, `treeNameForeground` and
    `segmentsText` are the existing row-drawing pieces.
  - `HostedRender` is the shared harness for bitmap layout tests. `TreeChainRowLayoutTests`
    shows the row-slot, glyph-slot and guide measurement idiom. `TreeGitStatusColourTests` and
    `TreeDiagnosticMarkTests` show how the git and diagnostics lookups are built.
- Dependencies: none new. Deployment target is macOS 14. `onScrollGeometryChange` (macOS 15)
  is not available, so the scroll offset is read with a `GeometryReader` and a preference
  inside the scroll content.

## Decisions made here (binding on implementation)

### 1. The rule's contract (`TreeStickyRule`, Foundation only)

**Input**

- `Folder` has five fields: `depth` (`0` is the project root), `isExpanded`, `top` and
  `bottom` of the folder's whole node (its row plus its expanded subtree), both in content
  coordinates.
- The row itself is taken to be `[top, top + rowHeight)`. `rowHeight` is the input height of
  one row, which is also the height of a pinned copy.
- The viewport is given as `top` (the content offset at the viewport's top edge) and `height`.
- The input order is not trusted. The rule orders folders by `top` ascending, then by `depth`
  ascending.

**Eligibility.** A folder is eligible only when all three hold:

- `depth ≥ 1` (the root never pins),
- it is expanded,
- `bottom > top + rowHeight`, meaning it has at least one descendant row.

**Cap**

- `maximumRows = floor(viewportHeight / 3 / rowHeight)`, and `0` when `rowHeight ≤ 0`.
- With `0`, nothing pins.
- The fraction is the constant `capFraction = 1.0/3.0`.

**Choosing the chain**

- Level `i` has the nominal slot `S_i = viewport.top + i·rowHeight`.
- The next member is the first eligible folder, in rule order, that:
  - lies inside the previous member's subtree (deeper depth, `top ≥ previous.top + rowHeight`
    and `bottom ≤ previous.bottom`; any eligible folder when the chain is empty), and
  - satisfies `top < S_i < bottom`.
- Because spans containing one point nest, the first match is the outermost one, and the
  members form an ancestor chain.
- When the chain already holds `maximumRows`, a further candidate must satisfy
  `top < S_(maximumRows−1) < bottom`. If it does, the outermost member is dropped and the
  candidate is appended. Repeat until no candidate qualifies.
- So capping drops the outermost rows first, and a capped row joins only once its real row is
  fully under the stack. A copy is never drawn while its real row shows below the stack.

**Drawing positions**

- Final index `j` is drawn at `min(S_j, folder.bottom − rowHeight)`, reported relative to the
  viewport top. That value is negative or below the nominal slot while the row is being pushed
  out.
- Each output row (`Stack.Row`) carries the input index, its `top`, its `pushOffset` (≤ 0) and
  its `scrollAnchorY` (Decision 2), so the view does no arithmetic for the click.
- `Stack.height` is the largest drawn bottom relative to the viewport top, clamped to `≥ 0`. It
  is `0` for an empty stack.
- Rows are drawn outermost on top. A deeper row whose subtree ends slides up under its parent.
  When a parent and its child end together, the child slides under the parent and the parent is
  then pushed out by the row that follows.

### 2. Scroll anchors (Core)

- **The unit-point arithmetic.** `anchorY(rowsAbove:rowHeight:viewportHeight:)` returns
  `k·h / (H − h)`, clamped to `0…1`, and `0` when `H ≤ h`. This is the `UnitPoint.y` that
  `scrollTo` needs so a row of height `h` lands with its top `k` rows below the viewport top:
  `scrollTo` aligns the same unit point of the item and of the viewport.
- **Eligible ancestor count.** For a row whose top is `rowTop`, `eligibleAncestorCount` is the
  number of eligible folders (Decision 1) whose span contains that row: `top < rowTop < bottom`.
  The folder itself is not counted. This is the number of rows that will qualify for the stack
  once that row sits under it, because every one of them then has its real row above the
  viewport and its subtree continuing below.
- **The one below-the-stack anchor.**
  `scrollAnchorY(forRowAt rowTop:folders:viewportHeight:rowHeight:) -> Double` returns
  `anchorY(rowsAbove: min(eligibleAncestorCount, maximumRows))`. It is the only function that
  answers "where should this row land so the stack does not cover it". Both the pinned-row click
  and the draft placement call it; neither uses the row's index in the current stack. The index
  is wrong once the cap has dropped outer rows: with `maximumRows` 3 and `a/b/c/d/e` all
  expanded and deep, the stack shows `[b, c, d]`. Clicking `d` (index 2) would land `d` in slot
  2, but after the scroll `a`, `b` and `c` all qualify and fill slots 0–2, covering `d`'s real
  row. The count gives 3 and lands it in slot 3, just under the stack.
- **Click on a pinned row.** `stack(...)` fills each `Stack.Row.scrollAnchorY` by calling
  `scrollAnchorY(forRowAt: folder.top, …)` with its own inputs. The view passes
  `UnitPoint(x: 0, y: row.scrollAnchorY)` to `scrollTo` and computes nothing.
- **Reveal.** `revealAnchorY = 0.5` stays the centre. A Core test pins that, for every viewport
  height with `maximumRows ≥ 1`, a centred row's top `(H − h)/2` is at or below the largest
  stack the cap allows. Reveal therefore always lands below the stack.
- **Create draft.** `placement(ofRowAt:folders:viewport:rowHeight:) -> Double?`
  - It returns `nil` when `[rowTop, rowTop + h)` already lies inside
    `[viewport.top + stack.height, viewport.top + H)` (no scroll, today's minimal behaviour).
  - Otherwise it returns `scrollAnchorY(forRowAt: rowTop, …)`, the same function the click
    uses.
  - This replaces today's anchor-less `scrollTo("draft-row")`, which can leave the draft under
    the stack. That happens when a partly covered folder is expanded by New File and becomes
    pinned over its own first child.

### 3. Measurement (app) — no listing and no file-system call

- `DirectoryNodeView` gains `depth` (root `0`, child = parent + 1; a chain row is one node and
  one depth).
- **Folder reports.** While a node is expanded, a `GeometryReader` background on its
  `DisclosureGroup` reports one value through a preference key (`TreeStickyFoldersKey`, an
  array). The value holds:
  - its node frame in a named content coordinate space set on the padded content `VStack`,
  - its depth and `isExpanded`,
  - its `TreeNodeShape`,
  - its head's scroll id,
  - the node's `$isExpanded` binding.

  Collapsed nodes attach no reader. This is a cost measure: a collapsed subtree has nothing to
  measure. The rule still owns the collapsed case. Frames in content space do not change while
  scrolling, so scrolling never recomputes the reports.
- **Scroll offset.** One `GeometryReader` in the content's background reports the content's
  `minY` in a named space on the `ScrollView` (`TreeScrollOffsetKey`).
  - `.onPreferenceChange` writes it into `TreeStickyViewport`, an `ObservableObject` with one
    `@Published top`.
  - That object is owned by an unpublished holder `@StateObject`, the `TreeListingSource`
    pattern. Only the overlay observes it, so a scroll frame re-renders the overlay alone, never
    the tree root or any row.
- **Viewport height.** The overlay's own `GeometryReader` gives the viewport height.
- **Folder row scroll id.** The folder row (`FolderDisclosureRow`, not the whole node, so the
  anchor maths sees one row's height) gets `.id(TreeRevealRequest.rowID(head))` for
  click-to-scroll.
- **What a pinned row reads.** It reads its name, segment colours and dot from the tree root's
  `gitStatus` / `diagnostics` values, the same published lookups, asked with the same URLs the
  real row uses (`spokenGitStateURL`, `diagnosticMarkURL`, `gitStatusURLs`).
- **Nothing persisted.** Nothing is written to the session or the settings.

### 4. Drawing (app)

**Shared drawing with the real row**

- Glyph, dot and name/segments are extracted into one shared label view, used by the real row
  and the pinned copy. The real row keeps its rename-field branch around that view.
- Chevron column, padding and the fixed `rowHeight` frame are also extracted into one shared
  row layout piece, used by `FolderDisclosureRow` and the copy. This way "exactly as the real
  row draws" holds by construction.
- The copy always draws `chevronDown`, because only expanded folders pin. It never draws a
  draft.

**Overlay placement and layering**

- The overlay sits on the `ScrollView` through
  `.overlayPreferenceValue(TreeStickyFoldersKey.self, alignment: .top)`, inside the existing
  `ScrollViewReader`. It therefore sits directly under the header, which is outside the scroll
  view.
- It is clipped to the scroll view, so a pushed-out row never draws over the header.
- Its frame is exactly `Stack.height` tall, so everything below the stack keeps receiving
  clicks, drags and menus.

**Indent**

- The indent is built by layout, not arithmetic: one
  `metrics.scaled(ChromeGeometry.treeIndentStep)`-wide spacer per depth level.
- Each spacer carries the existing `TreeIndentGuide` as its leading background, so every
  enclosing folder's guide runs through the pinned row as it runs through the real one.

**Layers, back to front**

1. The `bgPanel` ground across the full width.
2. The guides.
3. The row with its own background. That background comes from
   `TreeRowState.state(isSelected: false, isWindowKey: controlActiveState == .key,
   isHovering: isHovering, isDropTarget: false)` and `TreeRowBackground.color(for:resolving:)`.

A one-`hairline` rule is drawn at the stack's bottom edge,
`metrics.scaled(ChromeGeometry.hairlineWidth)` tall.

**Gating update.** That background expression is added as a third `ProjectTreeView.swift`
entry to rule thirty-five's pinned expression set in `ChromeThemeSourceGatingTests`, with its
reason in the set's doc comment, and to `core-theme.md` wherever that set is inventoried.

**Interaction**

- A tap on the chevron slot sets the reported binding to `false`. The same `@State` collapses,
  and the node's existing collapse handler drops any draft below.
- A tap anywhere else on the row calls
  `withAnimation { proxy.scrollTo(rowID, anchor: UnitPoint(x: 0, y: row.scrollAnchorY)) }`,
  reading the value the rule put on the `Stack.Row` (Decision 2). It changes no selection and
  opens no file.
- No `onDrag`, no `onDrop`, no context menu.
- The whole overlay is `.accessibilityHidden(true)`.

**Sizes and colours.** Every size goes through `metrics.scaled(...)` /
`metrics.scaledFont(...)`, and every colour through `theme.color(role)`.

### 5. Tests

**AC3 (no listing on scroll).** The tree's memo exposes no listing count, so the pin counts at
the file-service seam instead, which is strictly stronger: it also catches link queries. A
counting `FileServicing` wrapper is injected through `WorkspaceModel(fileService:)` and counts
every protocol call.

**Hosted-render test.** It runs at interface scale 1.8 with two renders. Exact sizes are in
Task 3.

## Development Approach

- **Testing approach**: TDD for the Core rule; code first, then tests, for the app layer.
- Complete each task fully before moving to the next.
- Before touching a file, read its entry in `docs/architecture/` (`app-window.md` for
  `ProjectTreeView.swift`, `core-workspace.md` for tree rules, `core-theme.md` for the gating
  rule).
- Gates, under the pinned Xcode, always with the one permanent DerivedData folder:
  - `swift test`
  - `xcodegen generate`
  - `DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build test`
  - The same with `-configuration Release build`, and the iOS build with
    `-destination 'generic/platform=iOS'`.
  - `swiftlint --strict` from the repository root.
- **Hand-breaks.** Each new pin is proven able to fail: break the code by hand, see the named
  test fail, restore. Record it in the plan file's `## Execution notes` section, together with
  the hosted-render measurements (pixel positions and colour values read).
- No brand names or references to other editors anywhere: code, comments, docs, commit
  messages.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Core rule — which folders pin and where

**Files:**
- Create: `Sources/PisakaCore/TreeStickyRule.swift`
- Create: `Tests/PisakaCoreTests/TreeStickyRuleTests.swift`

- [x] Write `TreeStickyRuleTests` first. Cover every case below with hand-computed extents
  (`rowHeight` 22, viewport heights chosen so the cap is 1, 2 and 4 rows):
  - no ancestor (offset 0, and a folder whose real row is still at or below the viewport top);
  - one pinned row at top 0;
  - several rows stacked outermost first at 0, h, 2h;
  - input order shuffled gives the same answer;
  - push-out: the last descendant's bottom inside the slot gives a negative top and the
    matching `pushOffset`;
  - a child ending with its parent slides under it, then the parent alone is pushed;
  - the cap drops the outermost first, and a capped candidate joins only once fully under the
    stack;
  - `maximumRows` is 0 below three rows' height, so nothing pins;
  - a collapsed ancestor never pins;
  - the root (depth 0) never pins;
  - an expanded empty folder never pins;
  - a chain row (one `Folder`, any segment count) pins as exactly one row;
  - a sibling folder after a pinned folder's subtree never stacks under it;
  - `Stack.height` for empty, full and pushed stacks.
- [x] Implement `TreeStickyRule` per Decision 1: `Folder`, `Stack`, `Stack.Row` (without
  `scrollAnchorY` yet; Task 4 adds it), `capFraction`, `maximumRows(viewportHeight:rowHeight:)`,
  `stack(folders:viewport:rowHeight:)`. It is pure, Foundation only, doc-commented with the
  contract, and does one sort plus one forward pass.
- [x] Hand-break two pins and record them in Execution notes: remove the depth-0 exclusion,
  and swap the drop-outermost for drop-innermost.
- [x] Run `swift test`; it must pass before Task 2.

### Task 2: Measurement plumbing and shared row drawing (no visible change yet)

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`
- Create: `Tests/PisakaAppTests/TreeStickyScrollListingTests.swift`

- [x] Extract the folder label (glyph + dot + name/segments) and the folder row layout
  (chevron column, padding, fixed frame) into shared views used by the real row,
  behaviour-identical. The rename-field branch stays on the real row only.
- [x] Add `depth` to `DirectoryNodeView`.
- [x] Add the expanded-only folder report preference, the content and viewport coordinate
  spaces, the scroll-offset preference, the `TreeStickyViewport` object and its unpublished
  holder `@StateObject`, all per Decision 3. Add the folder row's scroll id.
- [x] Keep the plain `VStack`, and its comment at the scroll container. Add one sentence there
  on why measurement goes through preferences instead.
- [x] Write `TreeStickyScrollListingTests` (AC3), in one window:
  - a temporary project with `a/` holding 60 files and `b/` holding 5;
  - a `WorkspaceModel` built over a counting `FileServicing` wrapper of `FileService()`;
  - a reveal of `a/f45` to expand and scroll;
  - after settling, record the call count;
  - scroll the hosting `NSScrollView`'s clip view to four different offsets (`scroll(to:)` +
    `reflectScrolledClipView`), settling after each;
  - assert the count never moved and the clip view's origin did.
- [x] Hand-break and record: a listing inside the scroll-offset handler makes the test fail.
- [x] Existing tree suites stay green unchanged: `TreeChainRowLayoutTests`,
  `TreeRowGlyphLayoutTests`, `TreeIndentGuideLayoutTests`, `TreeGitStatusColourTests`,
  `TreeDiagnosticMarkTests`, `TreeRowBackgroundTests`, `TreeRevealRequestTests`. Run
  `swift test` and the app bundle; both must pass before Task 3.

### Task 3: The pinned stack overlay

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Create: `Tests/PisakaAppTests/TreeStickyStackLayoutTests.swift`

- [x] Add the overlay and the pinned row view per Decision 4: placement under the header,
  clip, frame of exactly `Stack.height`, z-order outermost on top, indent spacers carrying
  `TreeIndentGuide`, ground/guides/row layering, hover background through the shared mapping,
  hairline at the stack bottom, chevron-tap collapse through the reported binding, no
  drag/drop/menu/draft, overlay hidden from accessibility. The row-body tap is wired in Task 4,
  once the rule answers its anchor.
- [x] Add the pinned row's background expression to rule thirty-five's pinned set, with its
  reason in the set's doc comment. Run every source-gating suite
  (`ChromeThemeSourceGatingTests`, `ZoomSourceGatingTests`, `MenuShortcutUniquenessTests`,
  `DrawDirtyRectSourceGatingTests`); fix the code, not the rules, except for that one
  deliberate entry.
- [x] Extend `TreeStickyScrollListingTests` with one capture at its final offset. Assert a
  pinned row's chevron is inked in the first row slot under the header. This proves SwiftUI
  observed the AppKit-driven scroll, which is how a wheel scroll arrives.
- [x] Write `TreeStickyStackLayoutTests`, `HostedRender` at scale 1.8, window
  `metrics.scaled(240) × metrics.scaled(300)`, dark theme.
  - **Project.** `a/` with 40 files; `gitStatus` marking `a/f03` modified, so `a` takes the
    modified name role; `diagnostics` with an error in `a/f07`, so `a`'s glyph carries the
    error dot.
  - **Render A** (no reveal; `a` collapsed in row 1): read `a`'s name colour and dot colour.
  - **Render B** (reveal `a/f30`, centred, so `a`'s real row is above the viewport), assert:
    - `a`'s chevron and glyph are inked in the first row slot directly under the header, at the
      depth-1 chevron and glyph slots (the chain suite's slot functions);
    - name colour and dot colour equal render A's and match their roles;
    - the hairline runs at the stack's bottom edge;
    - the root's guide runs through the pinned row at the depth-0 guide centre.
  - Two renders in total; no loops over windows or bitmaps.
- [x] Hand-break and record, each making the named test fail:
  - an unscaled indent;
  - the copy's name drawn without its git role;
  - the overlay offset by the content padding;
  - accessibility not hidden (state the probe used: the overlay's `accessibilityHidden` read
    off the hosting view's accessibility children).
- [x] Run `swift test` and the app bundle; both must pass before Task 4.

### Task 4: Programmatic scrolls land below the stack

**Files:**
- Modify: `Sources/PisakaCore/TreeStickyRule.swift`, `Tests/PisakaCoreTests/TreeStickyRuleTests.swift`
- Modify: `Sources/Pisaka/ProjectTreeView.swift`

- [x] Write the tests first:
  - `anchorY` for k = 0, 1, 3, clamping, and `H ≤ h`;
  - `scrollAnchorY(forRowAt:…)` with the cap dropping outer rows: cap 3 (`H = 9h`), five nested
    expanded deep folders `a/b/c/d/e`, viewport placed so the stack is `[c, d, e]` (`a` and `b`
    dropped). The innermost pinned row's `Stack.Row.scrollAnchorY` equals
    `anchorY(rowsAbove: 3)`, not `anchorY(rowsAbove: 2)`; the same value comes from calling
    `scrollAnchorY(forRowAt: e.top, …)` directly;
  - with the cap dropping nothing: cap 4, three nested expanded folders all pinned. Every
    `Stack.Row.scrollAnchorY` equals `anchorY(rowsAbove: indexInStack)`, because the eligible
    ancestor count equals the index;
  - `eligibleAncestorCount` ignores the root, collapsed folders and the row's own folder;
  - `revealAnchorY` clears the capped stack for every viewport height from `3h` to `60h` in
    one-point steps (charged as a loop over inputs, no clock);
  - `placement` returns `nil` for a clear row, `scrollAnchorY(forRowAt:…)` for a row under the
    stack and for a row below the viewport, and caps the ancestor count at `maximumRows`.
- [x] Implement `anchorY`, `scrollAnchorY(forRowAt:folders:viewportHeight:rowHeight:)`,
  `revealAnchorY` and `placement` per Decision 2, and add `Stack.Row.scrollAnchorY`, filled
  inside `stack(...)` by calling `scrollAnchorY(forRowAt:)`. `placement` calls the same
  function. Neither path reads the index in the stack.
- [x] Wire them in:
  - the pinned-row tap scrolls with `UnitPoint(x: 0, y: row.scrollAnchorY)`, doing no
    arithmetic;
  - reveal uses `UnitPoint(x: 0, y: TreeStickyRule.revealAnchorY)` instead of `.center`;
  - the draft row reports its top through a small `Double?` preference, and the tree keeps a
    pending flag set by `onDraftAppeared`;
  - when both the flag and a measured top are present, the tree asks `placement` once and
    scrolls only on a non-nil anchor, then clears the flag. This is causal, with no timed
    delay.
- [x] Hand-break and record:
  - `anchorY` without the `− h` term fails its test;
  - `Stack.Row.scrollAnchorY` built from the index in the stack instead of the eligible
    ancestor count fails the cap-dropped case.
- [x] Run `swift test` and the app bundle; both must pass before Task 5.

### Task 5: Verify acceptance criteria

- [x] `swift test` green, including `TreeStickyRuleTests` and every source-gating suite.
- [x] App bundle green under the pinned Xcode, including both new suites (run under Xcode
  27.1: the pinned 26.3 is not installed here; CI runs the pinned one).
- [x] macOS Release build and iOS build green.
- [x] `swiftlint --strict` clean from the repository root.
- [x] `CLAUDE.md` under 60,000 characters (`LintConfigurationTests`).
- [x] Grep the diff for brand names or references to other editors; none.
- [x] Execution notes in this plan file hold every hand-break and the hosted-render
  measurements.

### Task 6: Update documentation

- [ ] `docs/FEATURES.md`, project-tree text: expanded ancestors stay pinned under the header
  while scrolling. They are pushed out as their contents end and capped at a third of the
  tree's height. Clicking one scrolls to its folder; its chevron collapses it.
- [ ] `docs/architecture/app-window.md`, `ProjectTreeView.swift` entry, the mechanism:
  - expanded-only folder reports in content space;
  - the offset holder observed by the overlay alone;
  - why scrolling re-renders no row and lists nothing;
  - the shared label/row views;
  - the overlay's placement, clip and hit area;
  - reveal centre, click and draft placement through the rule (the click reads the row's
    `scrollAnchorY`, never its index).

  And the stated limits:
  - the one-third cap;
  - click-to-scroll and chevron collapse only (no menu, drag, drop or draft);
  - hidden from accessibility;
  - the row extent assumed to be one `rowHeight`, so a folder whose own rename draft is open is
    measured as one row.
- [ ] `docs/architecture/core-workspace.md`: a full `TreeStickyRule.swift` entry with the
  contract from Decisions 1–2 (including why the below-the-stack anchor counts eligible
  ancestors rather than reading the stack index) and its test suite.
- [ ] `docs/architecture/core-theme.md`: rule thirty-five's inventory gains the new
  expression, if it lists them.
- [ ] `CLAUDE.md`: add `TreeStickyRule.swift` to the `core-workspace.md` index line only.
- [ ] Re-run `swift test` (doc-reading suites included).

## Execution notes

(Filled in during execution: hand-breaks with the failing test each produced, and the
hosted-render measurements.)

### Task 1

- `TreeStickyRuleTests`: 20 tests, all green; full `swift test` 7,145 tests green;
  `swiftlint --strict` clean.
- `Folder` carries four fields (`depth`, `isExpanded`, `top`, `bottom`); Decision 1's
  "five fields" lists those four, and the pinned row maps back to its report through
  `Stack.Row.index` (the input index), so no fifth field was needed.
- `Stack.Row` is declared in an extension of `Stack`: nested inside it, SwiftLint's
  `nesting` rule (types at most one level deep) refused it. The name is unchanged.
- `maximumRows` floors `viewportHeight · capFraction / rowHeight` with a `1e-9` tolerance,
  so an exact multiple (66 / 3 / 22) is not floored one row short by the binary rounding of
  `1.0/3.0`; pinned by `testMaximumRowsIsAThirdOfTheViewportInWholeRows` (65.9 → 0, 66 → 1,
  131.9 → 1, 132 → 2, 264 → 4).
- Hand-break 1, depth-0 exclusion removed from eligibility (`folder.depth >= 1 &&` deleted):
  27 assertions failed across 15 tests, among them `testTheRootNeverPins`
  (`[root@0.0]` ≠ `[]`), `testOnePinnedRowAtTheTop` (`[root@0, a@22]` ≠ `[a@0]`) and
  `testTheRowsCarryTheirInputIndex` (`[2, 5, 4, 0]` ≠ `[5, 4, 0]`). Restored.
- Hand-break 2, drop-outermost swapped for drop-innermost (`chain.removeFirst()` →
  `chain.removeLast()`): `testTheCapDropsTheOutermostFirst` and
  `testACappedCandidateJoinsOnlyOnceFullyUnderTheStack` failed, each with `[a@0, c@22]` ≠
  `[b@0, c@22]`. Restored; the restored file compared byte-identical to the saved copy.

### Task 2

- App-layer gates ran under Xcode 27.1 (`/Applications/Xcode.app`): the pinned Xcode 26.3 is
  not installed on this machine, so `DEVELOPER_DIR` was left unset. CI runs the pinned one.
  The app bundle passed 497 tests with 0 failures, among them `TreeStickyScrollListingTests`
  and the seven named tree suites unchanged. `swift test` passed 7,145 tests, and the 265
  source-gating tests were re-run over the final source. `swiftlint --strict` is clean.
- Shared drawing: `TreeFolderRowLayout` (chevron column, padding, fixed frame with the
  rename-draft ceiling) and `TreeFolderLabel` (glyph, dot, name slot). `TreeFolderName` is the
  plain or segmented name, and its `segmentsText` is now static with a `resolving` theme
  function. The real row keeps the rename-field branch and passes the field into the label's
  name slot.
- **Deviation from Decision 3, measured: the scroll offset is not a preference.** A
  `TreeScrollOffsetKey` preference read by `.onPreferenceChange` on the `ScrollView` was
  built first. Its handler fired only twice, both times with `0`, through the reveal's
  animated scroll and four AppKit clip-view scrolls. Logged in the same run, the reader's
  own `frame(in: .named(viewport)).minY` went `-136 … -600`, so the geometry did move. The
  reader therefore writes straight into `TreeStickyViewport` through
  `onChange(of: minY, initial: true)`, which logged `-400`, `-700` and `-1000` for the AppKit
  scrolls. The key was removed, and the reason is in the comment at the reader.
- Measured for Task 3: the folder reports *do* cross the scroll view. A debug
  `overlayPreferenceValue(TreeStickyFoldersKey.self)` on the `ScrollView` received 2 reports
  (root `4–1516`, `a` `28–1492` in content space) once `a` expanded. Each expanded node's
  reader closure re-runs on a scroll frame, because its global position moves, but the frame
  it reports in content space stays the same, and it reads nothing.
- Hand-break: `_ = try? model.children(of: root)` added in the offset handler. The test
  failed at each offset (`8 ≠ 7`, `9 ≠ 7`, `10 ≠ 7`, `11 ≠ 7` calls; "scrolling to 100.0
  reached the file service 1 time(s)" … "4 time(s)"). Restored, and the restored file
  compared byte-identical to the saved copy.

### Task 3

- App-layer gates ran under Xcode 27.1 again (the pinned 26.3 is not installed here). The
  app bundle passed 499 tests with 0 failures, among them both sticky suites and the seven
  tree suites unchanged. `swift test` passed 7,145 tests, among them the four source-gating
  suites (`ChromeThemeSourceGatingTests` 75, `ZoomSourceGatingTests` 8,
  `MenuShortcutUniquenessTests` 3, `DrawDirtyRectSourceGatingTests` 10). `swiftlint
  --strict` is clean.
- Views: `TreeStickyStackView` (the overlay, the viewport's one observer) and
  `TreeStickyRowView` (the copy), both at the end of `ProjectTreeView.swift`, plus
  `TreeStickyPinnedRow`, which identifies a copy by its folder's scroll id. Because they sit
  after `FileRowView`, the copy's `rowBackground` is the tree's third entry in
  `chromeRowBackgrounds` in source order as well. The chevron-tap target is the row's
  leading padding plus `TreeRowLayout.chevronGutter`, overlaid on the shared row layout.
- Hosted-render measurements (`TreeStickyStackLayoutTests`, scale 1.8, the bitmap at 1 px
  per point on this machine). Header `57.5`, row height `43`. The reveal settled at clip
  origin `1163`. Render A's root chevron ink is `(19.5, 83.5, 13 × 7)`. Render B's pinned
  chevron ink is `(48.5, 75.5, 13 × 8)`: one step (`29`) right of the root's, and the same
  offset into its slot (`18` vs `19`, within 2 px). The pinned glyph ink is
  `(73, 69.5, 24 × 23)`. Name colour in A and B: sRGB `0.794 0.647 0.390`
  (`statusYellow`). Dot colour in A and B: sRGB `0.777 0.486 0.443` (`statusRed`). The
  bottom rule runs `99.5 ..< 101.5`, i.e. it ends at the slot's bottom `100.5`
  (+1 px sampling) and is the scaled hairline thick.
- **Deviation, measured: the accessibility probe reads the source.** Headless, the hosting
  view's `accessibilityChildren()` is empty, with the window ordered front or not. An
  accessibility hit test over the pinned row answers the hosting view itself. So a probe of
  the accessibility tree passes whether or not the overlay is hidden, which is the
  `LocalChangesLayoutTests` / `WelcomeLayoutTests` finding again.
  `testThePinnedStackIsHiddenFromAccessibility` instead reads `ProjectTreeView.swift`,
  with line comments stripped, and requires `.accessibilityHidden(true)` inside
  `TreeStickyStackView`'s declaration.
- Hand-breaks, each run against `TreeStickyStackLayoutTests`, each restored, and the
  restored file compared byte-identical to the saved copy:
  - Unscaled indent (the spacer's `.frame(width: ChromeGeometry.treeIndentStep)`): 5
    failures, among them "the pinned chevron is not one indent step right of the root's"
    (`24 ≠ 29`) and "the pinned row does not start directly under the header" (`12 ≠ 19`).
  - The copy's name as a plain `Text(shape.label)`: "the pinned copy's name is not drawn in
    its git role, statusYellow".
  - The overlay offset by the content padding (`.padding(.top, metrics.scaled(4))`): 3
    failures. "The pinned row does not start directly under the header" (`25 ≠ 19`), "the
    hairline does not run at the stack's bottom edge" (`108.5 ≠ 100.5`), and the
    bgPanel-ground check.
  - `.accessibilityHidden(true)` removed: "the pinned stack is not hidden from
    accessibility", and failing alone, in three runs. On the first run with this break the
    layout test also died once inside `HostedRender.settle` ("needing another Update
    Constraints in Window pass"). That did not recur in three more runs with the break or
    in three clean runs of both suites, so it is recorded here as a one-off.
- `TreeStickyScrollListingTests`' added capture at offset 1000 finds the pinned chevron in
  the first slot under the header, wider than a third of the chevron column, so it is not
  `a`'s one-point guide.

### Task 4

- Gates under Xcode 27.1 again (the pinned 26.3 is not installed here): the app bundle
  passed 499 tests with 0 failures; `swift test` passed 7,153 tests, among them
  `TreeStickyRuleTests` (28) and every source-gating suite; `swiftlint --strict` is clean.
- Core: `revealAnchorY`, `anchorY(rowsAbove:rowHeight:viewportHeight:)`,
  `eligibleAncestorCount(forRowAt:folders:rowHeight:)`,
  `scrollAnchorY(forRowAt:folders:viewportHeight:rowHeight:)` and
  `placement(ofRowAt:folders:viewport:rowHeight:)`; `Stack.Row.scrollAnchorY` is filled in
  `stack(...)` by `scrollAnchorY(forRowAt: folder.top, …)`, and `placement` asks the same
  function. The capped fixture is `a/b/c/d/e` at tops 22…110, viewport top 200, `H = 198`:
  the stack is `[c, d, e]` and its anchors are `[0.25, 0.375, 0.375]` (`anchorY` 2, 3, 3).
  The reveal-centre test checks 1,255 heights (66 … 1,320) and asserts that count.
- App: the reveal scrolls to `UnitPoint(x: 0, y: TreeStickyRule.revealAnchorY)`. The pinned
  row's body tap hands its `Stack.Row` and the folder's scroll id to the tree, which scrolls
  to `UnitPoint(x: 0, y: row.scrollAnchorY)`; the chevron slot's own tap, overlaid on top,
  still collapses. The draft row reports its content-space top through
  `TreeStickyDraftTopKey` (read by `onPreferenceChange` inside the scroll view, as a
  layout-only change it reaches it). `onDraftAppeared` sets `draftPlacementPending`.
  `TreeStickyDraftPlacement` sits behind the stack inside the same `overlayPreferenceValue`
  closure, where the reports and the viewport meet. It reads the offset object without
  observing it, so scrolling never re-renders it. Its
  `onChange(of: pending ? draftTop : nil, initial: true)` asks `placement` once, and
  the tree scrolls only on a non-nil anchor and clears the flag either way.
  `draftAppearedTrigger` and the anchor-less `scrollTo("draft-row")` are gone.
- Hand-break 1, `anchorY` without the `− h` term (`let travel = viewportHeight`):
  `testAnchorYLandsTheRowsTopKRowsBelowTheViewportTop` failed 6 assertions, among them
  `0.111… ≠ 0.125`, `0.333… ≠ 0.375` and `1.0 ≠ 0.0` for `H ≤ h`. Restored.
- Hand-break 2, `Stack.Row.scrollAnchorY` built from the index in the stack
  (`anchorY(rowsAbove: level, …)`): `testTheClickAnchorCountsEligibleAncestorsNotTheIndexInACappedStack`
  failed 4 assertions (`0.25 ≠ 0.375` for `e`; `[0.0, 0.125, 0.25] ≠ [0.25, 0.375, 0.375]`),
  while the uncapped case stayed green, as it must. Restored, and the restored file
  compared byte-identical to the saved copy.

### Task 5

- `swift test`: 7,153 tests, 0 failures. Among them `TreeStickyRuleTests` (28), every
  `*SourceGatingTests` suite and `LintConfigurationTests` (29), re-run filtered: 285 tests,
  0 failures. `CLAUDE.md` is 56,806 characters.
- App bundle under Xcode 27.1 (the pinned 26.3 is still not installed here): 499 tests,
  0 failures, `TreeStickyScrollListingTests` and `TreeStickyStackLayoutTests` among them.
  The macOS Release build and the iOS build (`generic/platform=iOS`,
  `CODE_SIGNING_ALLOWED=NO`) both succeeded. `swiftlint --strict` reported 0 violations in
  788 files.
- Brand grep over the branch's added lines and its commit messages: no editor names. "Xcode"
  appears only as the toolchain in gate commands and these notes.
- Execution notes cover every hand-break the plan names (Task 1: two, Task 2: one, Task 3:
  four, Task 4: two) and Task 3's hosted-render measurements.

## Post-Completion

Manual checks in a Debug build only:

- Open a project with a deep expanded folder and scroll through it. Confirm stacking at the
  indents, push-out one by one, and the one-third cap.
- Click a pinned row, including the innermost row of a capped stack: its real row lands just
  under the stack, never under a copy.
- Click a pinned chevron: the folder collapses and unpins.
- Reveal a file deep in a pinned subtree: it lands below the stack.
- Run New File on a partly covered folder: the draft lands below the stack.
- With VoiceOver, the pinned copies are not announced.
