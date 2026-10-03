# Follow-ups after the merge of "follow-ups from the design pass": one drawing defect, five weak pins, and the tail of small ones

## Overview

This closes what the acceptance review of the previous follow-up pass left open. It adds no feature. Each item does one of three things:
- fixes a defect;
- makes an existing claim true;
- lets a test see the regression it names.

There are three groups:
- **A. The Local Changes defect.** Selecting a modified text file blanks most of the main window. Highest priority.
- **B. Five tests or documents that claim more than they pin:**
  - current-line invalidation;
  - the caret column after a deletion that ends at the caret;
  - generated asset symbols staying off;
  - the title label's colour in both appearances;
  - the tooltip suite's claim about what it costs.
- **C. The tail:**
  - an over-cap working file that has no stamp;
  - the HEAD side's cap being applied after the read;
  - a stale selection diff surviving a folder switch;
  - the diff window's title;
  - inert counter assertions in the commit-dialog tests;
  - the tooltip frame and accessibility assertions;
  - the glyph-load rule's horizon;
  - the title label's gap.

### Facts established while planning, which the tasks rely on

**The Local Changes defect**
- **It is a drawing defect, not a layout one.** It was reproduced on the default-branch build, and the window's accessibility tree was read before and after the click. Every frame is correct:
  - the project tree, the tab list and the editor;
  - the dock tab row, the panel header and the file list;
  - both diff scroll views, each at its proper rectangle.
- **The blank area is the hairline colour.** It was captured as 0x414448 under the display profile. Under the same profile, bgPanel 0x2B2D30 captures as 0x323538, and hairline 0x393B40 shifts by the same offset.
- **The cause.** `DiffDividerView.draw(_:)` in `Sources/Pisaka/DiffView.swift` calls `dirtyRect.fill()`. Since macOS 14, `NSView.clipsToBounds` defaults to `false`, so the rect passed to `draw(_:)` is not limited to the view's bounds. The divider therefore paints hairline over everything beneath it in z-order: the whole hosting view, except two things:
  - the right pane, which `DiffContainerView` adds after the divider;
  - the bottom bar, a later sibling.

  This matches the captures exactly.
- **The reach.**
  - It reproduces with a 7-line file as well as a 981-line one.
  - It also reproduces in the separate diff window opened by double-click, where the whole left pane is blank hairline.
  - `DiffView` has exactly three hosts, the only files outside `DiffView.swift` that spell `DiffView(`: `LocalChangesView`, `DiffWindowContent` and `LocalHistoryView`. All three are affected.
  - The commit dialog is not a host. Its unified diff is `CommitUnifiedDiffView`, a SwiftUI view with no `DiffDividerView`.
- **The panel draws legitimate hairlines of its own,** all in `LocalChangesView.swift`:
  - the toolbar's bottom rule (an `.overlay(alignment: .bottom)` fill);
  - the list/diff divider (a `hairline`-filled rectangle at the list's trailing edge);
  - the header's bottom rule (an `.overlay(alignment: .bottom)` fill).

  A "no hairline pixel" assertion must exclude these by frame.
- **The reduced-host layout facts still stand as facts.** The probe hosted `LocalChangesView` alone in a 900×240 borderless window, with a 400-row `.rows` state published before hosting. Its measurements:
  - the list is 320 points wide;
  - `DiffContainerView` sits at x = 321 and measures 579×176;
  - its `fittingSize` is 0×0;
  - the hosting view's `fittingSize` is 449×92.

  So no oversized ideal size is reported, and no layout fix is needed.
- **The other `draw(_:)` overrides in `Sources/Pisaka` are clean:**
  - `MinimapView` fills `bounds`;
  - `CompletionPanel` fills per-row rects built from `bounds.width`, and uses `dirtyRect` only in `intersects`;
  - `CommitGraphView` strokes lines from `bounds` and never fills the dirty rect;
  - the iOS `CommitGraphView_iOS`, `DiffView_iOS` and `MergeView_iOS` do not fill their `rect` (`MergeView_iOS` passes it only to `glyphRange(forBoundingRect:in:)`).
- **Screen-recording APIs are forbidden in tests.** `CGWindowListCreateImage`, `screencapture` and every other screen-recording API raise a system permission dialog on this machine, which an unattended run must never trigger. Every render in this plan is offscreen.

**The current-line invalidation**
- `BracketOverlayLayoutManager.setCurrentLine(_:)` invalidates the old band and the new band through `view.setNeedsDisplay(_:)` on the text view.
- The coordinator invalidates the ruler as a whole, with `ruler.needsDisplay = true`.
- `LineNumberRulerView` is `final`, and so is the layout manager.
- `EditorLayoutHarness` constructs its own plain `NSTextView(usingTextLayoutManager: false)`.

**The caret memo**
- `CaretReadout.countedPosition` takes the incremental path only when `editFloor` is `nil` or at least `memo.offset`.
- The coordinator lowers `caretEditFloor` in `bufferEdited`, which runs after the edit.
- The pre-edit hook is `textView(_:shouldChangeTextIn:replacementString:)`. Today it returns early for everything except one-character replacements.

**The rest**
- **Generated asset symbols.** `project.yml` sets `ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS: NO` once, in the app target's base settings. No suite reads it.
- **Over-cap working file with no stamp.** When the stamp is `nil`, `LocalChangesInlineDiff.workingSide` calls `readTextIfNotBinary`. A `nil` answer from that call is classified `.binary`, even when the file is only over the cap.
- **The HEAD blob.**
  - `GitServicing.headBlob(of:root:)` defaults to `nil`, and only `GitCLIService` implements it.
  - `LocalChangesModel.loadSelectionDiff` and `CommitDialogModel.headSide(for:root:)` both fetch the blob and only then compare its size with the cap.
- **Folder switch.**
  - `prepareForFolderChange(root:)` does not clear `selectionDiff`.
  - `refreshImpl`'s success path leaves `selectionDiff` as it is when the root changes.
- **Diff window title.** `PisakaApp.swift` calls `DiffWindowTitle.localChanges(path: file.path)`, which is repository-relative. The panel header uses `ChangedFileGroups.displayPath(_:projectPrefix:)`.
- **Inert counters.** Three tests in `CommitDialogModelTests` assert `unifiedLinesComputations` while `files` is empty, so the counter cannot move:
  - `testUnifiedDisplayRowsAreDroppedByTheLoadsPerOpenClear`;
  - `testUnifiedDisplayRowsAreDroppedByAFailedReload`;
  - `testUnifiedDisplayRowsAreDroppedByAFolderSwitch`.
- **Tooltips.**
  - `BottomBarToolTipTests.toolTips(completionOn:scale:)` creates one window per call. Two of those calls come from the loop over scales.
  - `testTheToolTipViewNeverTakesAClick` asserts `isAccessibilityElement() == false`, which a plain `NSView` also answers.
- **Title gap.**
  - `MainWindowChrome.titleLabelButtonGap` is a private 8.
  - The width cap is computed from the window buttons' `frame.maxX` and applied against the title bar view's width.

## Context

Files involved:
- **Local Changes drawing defect:**
  - `Sources/Pisaka/DiffView.swift`;
  - `Tests/PisakaAppTests/LocalChangesLayoutTests.swift`;
  - `Tests/PisakaAppTests/HostedRender.swift` (a helper; read only, unless a small offscreen-render addition is needed);
  - new: `Tests/PisakaCoreTests/DrawDirtyRectSourceGatingTests.swift`;
  - `docs/architecture/app-git-views.md`;
  - `CLAUDE.md` (the repository-file suite list only).
- **Current line:**
  - `Sources/Pisaka/LineNumberRulerView.swift`;
  - `Tests/PisakaAppTests/CurrentLineHighlightTests.swift`, `EditorLayoutHarness.swift`;
  - `docs/architecture/app-editor-overlays.md`.
- **Caret:**
  - `Sources/PisakaCore/CaretReadout.swift`, `Sources/Pisaka/CodeEditorView.swift`;
  - `Tests/PisakaCoreTests/CaretReadoutTests.swift`;
  - `docs/architecture/core-editor.md`, `app-editor.md`.
- **Glyph pins:**
  - `Tests/PisakaCoreTests/DesignGlyphAssetTests.swift`, `ChromeThemeSourceGatingTests.swift`;
  - `docs/architecture/core-theme.md`.
- **Window chrome:**
  - `Sources/Pisaka/MainWindowChrome.swift`;
  - `Tests/PisakaAppTests/MainWindowChromeTests.swift`;
  - `docs/architecture/app-shell.md`.
- **Tooltips:**
  - `Tests/PisakaAppTests/BottomBarToolTipTests.swift`;
  - `docs/architecture/app-window.md`.
- **Inline diff tail:**
  - `Sources/PisakaCore/LocalChangesInlineDiff.swift`, `LocalChangesModel.swift`, `GitServicing.swift`, `CommitDialogModel.swift`;
  - `Sources/Pisaka/GitCLIService.swift`;
  - Core tests for each;
  - `docs/architecture/core-git.md`, `core-git-models.md`, `core-commit.md`.
- **Diff window title:**
  - `Sources/PisakaCore/DiffWindowTitle.swift`, `Sources/Pisaka/PisakaApp.swift`;
  - `Tests/PisakaCoreTests/DiffWindowTitleTests.swift`;
  - `docs/architecture/core-services.md`, `app-shell.md`.
- **Feature list:** `docs/FEATURES.md`. Check it, and change it only if it stops being truthful.

Related patterns:
- **Bitmap renders** go through `HostedRender`, the way `LocalChangesLayoutTests`' placeholder cases do:
  - stub git and file services;
  - one window per state;
  - samples read with `matches(_:atX:y:ground:)`;
  - always offscreen, never a screen-recording API.
- **Repository-file gating suites** follow the `BottomPanelSourceGatingTests` mould:
  - read the sources through `#filePath`, with Foundation only;
  - reuse `LSPSourceGatingTests`' Swift scanner, so comments and literals are stripped before matching;
  - keep the inventory in the suite's own header.
- **Charged bounds** go through `CaretReadout.countedPosition`'s `work`, never a clock.
- **Project YAML pins** use `activeYAMLLines` / `contains(consecutively:)`, comment-stripped.
- **Unknown means re-read.** A `nil` stamp or size means "unknown", never "absent".
- **Generation tokens** are captured synchronously.
- **Async races** are staged with `Gate` / `waitFor`.

Dependencies: none new.

## Development Approach

- **Testing approach:** regular. Code comes first, then tests in the same task. The exception is Task 1, whose render tests are written and seen failing on the unfixed code before the fix.
- Complete each task fully before moving to the next.
- Before changing a file, read its entry in `docs/architecture/`. Update that entry in the same task.
- Domain decisions live in `PisakaCore`, with their own tests. The app layer only wires them.
- No product or brand names anywhere: code, comments, docs, tests, commit messages, branch name.
- **Test helpers stay cheap:**
  - no `NSWindow(`, `NSHostingView(` or bitmap capture per row or per pixel;
  - each suite's header states its real window count.
- **No screen-recording API in any test:** no `CGWindowListCreateImage`, no `screencapture`, nothing that reads the screen or a window's on-screen backing.
- **Build location.** Build with the default DerivedData location, outside the repository. Never pass a `-derivedDataPath` inside it.
- **Gates after every task:**
  - `swift test`;
  - `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`;
  - `swiftlint --strict` from the repository root;
  - in tasks that touch Core, also `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build`.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: The diff divider must not paint outside its bounds

**Files:**
- Modify: `Sources/Pisaka/DiffView.swift`
- Modify: `Tests/PisakaAppTests/LocalChangesLayoutTests.swift` (and `HostedRender.swift` only if a small offscreen-render addition is needed)
- Create: `Tests/PisakaCoreTests/DrawDirtyRectSourceGatingTests.swift`
- Modify: `docs/architecture/app-git-views.md`, `CLAUDE.md` (add the new suite's name to the repository-file suite list)

- [x] **Write the panel render test first,** in `LocalChangesLayoutTests`.
  - **The state.** Render `LocalChangesView` with a published `.rows` state, never a placeholder:
    - stub services, as the placeholder cases already use;
    - one modified text file, a handful of lines with one changed, so both panes carry text and gutter numbers;
    - select the file, then wait on the model's published `selectionDiff`, polling with a deadline and failing loudly.
  - **The renders.** One window per state, at scale 1 and at scale 1.8, through `HostedRender` on the panel ground, as the existing cases do.
  - **The positive assertions:**
    - the file list's ink (the status letter's and the name's `textPrimary`) is present in its rows;
    - the header text is present;
    - the `DiffDividerView` column between the two diff panes, found from the hosted `DiffContainerView`'s subview frames, matches `hairline`.
  - **The negative assertion: no sampled pixel matches `hairline`.** It samples exactly two bands:
    - **the file rows' band inside the list:** x from the list's leading edge up to, and not including, the list/diff divider; y from below the header's bottom rule to the end of the last row;
    - **the header's text band:** the header's frame minus its bottom rule.
  - **What the bands exclude, by frame.** Every hairline the panel legitimately draws is outside both bands:
    - the list/diff divider at the list's trailing edge;
    - the toolbar's bottom rule;
    - the header's bottom rule.

    Compute the bands from the hosted frames, scaled by the interface scale, and never from hard-coded pixel offsets.
  - **Do not loosen the assertion.** If the test fails after the fix on a legitimate rule, the only permitted change is to narrow the sampled rects so they exclude that rule's frame. The colour match must not be loosened, and samples must not be skipped by any other criterion.
- [x] **Fail first.** Confirm that both renders fail on the unfixed code.
  - A `cacheDisplay(in:to:)` render should hand `draw(_:)` the same unclipped rect.
  - If it does not, the fallback is still offscreen:
    - `displayIgnoringOpacity(_:in:)` into an `NSGraphicsContext` built on an `NSBitmapImageRep`;
    - or the window's `contentView`'s own `cacheDisplay(in:to:)`.

    Keep one window per state.
  - Never read the window's backing, the screen or anything screen-shaped. `CGWindowListCreateImage`, `screencapture` and every other screen-recording API are forbidden, because they raise a system permission dialog.
  - The suite header says which render path was used, and why.
- [x] **Add the second render:** `DiffWindowContent` with the same rows, at scale 1, in one window, on the same offscreen path.
  - `load` returns the rows, and `settings` is a fresh `SettingsStore`.
  - Wait until the hosted `DiffContainerView` is in the view tree, polling with a deadline and failing loudly.
  - Assert that the left pane draws: its gutter numbers' ink is present in the left pane's gutter.
  - Confirm it fails on the unfixed code.
- [x] **The fix.** `DiffDividerView.draw(_:)` fills `bounds`, never `dirtyRect`.
  - A comment states why: since macOS 14, `NSView.clipsToBounds` defaults to `false`, so the rect passed to `draw(_:)` may extend beyond the view, and filling it paints over every view beneath it in z-order.
  - The fix covers all three hosts of `DiffView`: the Local Changes panel, the separate diff window and Local History.
  - No other source change in this task.
- [x] **The gating rule.** Create `DrawDirtyRectSourceGatingTests`, a repository-file suite in the existing mould.
  - **The input.** It enumerates every `.swift` file under `Sources/Pisaka`, recursively and including `iOS/`, comment- and literal-stripped through `LSPSourceGatingTests`' scanner.
  - **Collecting the overrides.** For every `override func draw(_ <name>: NSRect)` or `override func draw(_ <name>: CGRect)`, the rule takes the body's text by brace matching.
  - **The rule.** That body never fills its own parameter. Each of these fails:
    - `<name>.fill(`;
    - `fill(<name>`, which covers `context.fill(<name>)` and `__NSRectFill(<name>)`;
    - `NSRectFill(<name>`.
  - **Set equality.** It pins the set of files that declare a `draw` override, so a new override must be added, and so reviewed, deliberately. The set:
    - `DiffView.swift`;
    - `MinimapView.swift`;
    - `CompletionPanel.swift`;
    - `CommitGraphView.swift`;
    - `iOS/CommitGraphView_iOS.swift`;
    - `iOS/DiffView_iOS.swift`;
    - `iOS/MergeView_iOS.swift`.
  - **Mutation checks,** by hand and never committed:
    - restoring `dirtyRect.fill()` fails the rule;
    - so does writing `context.fill(dirtyRect)` in any listed file.
  - **The header is the inventory.** It covers:
    - the rule, and why it exists: the macOS 14 default and the measured defect;
    - the audit: the six other overrides draw from `bounds` or row rects, or do not fill;
    - the pinned file set;
    - the horizon: a dirty rect copied into a local variable and filled through it passes, and is not chased.
- [x] **The architecture doc.** In `app-git-views.md`'s `DiffView` entry, at the `DiffDividerView` passage, record:
  - the measured cause: a hairline fill over everything beneath the divider, invisible to frames because every frame was correct;
  - the reach: the three hosts named above;
  - the rule: a draw override never fills its dirty rect;
  - the suite that pins the rule.

  `app-window.md` needs no change.
- [x] **The suite header.** Update `LocalChangesLayoutTests`' header to cover:
  - the rows state;
  - the diff-window render;
  - the offscreen render path and why it was chosen;
  - the exact sampled bands, and the legitimate hairlines they exclude by frame;
  - the total window count;
  - why the placeholder-only renders and any frame assertion could not see this defect.
- [x] **`CLAUDE.md`.** Add the new suite's name to the list of repository-file suites. Nothing else changes there.
- [x] Run the gates. They must pass before Task 2.

### Task 2: Current-line invalidation recorded, both bands

**Files:**
- Modify: `Sources/Pisaka/LineNumberRulerView.swift` (drop `final`, with a one-line reason)
- Modify: `Tests/PisakaAppTests/EditorLayoutHarness.swift`, `Tests/PisakaAppTests/CurrentLineHighlightTests.swift`
- Modify: `docs/architecture/app-editor-overlays.md`

- [x] **The harness.** `EditorLayoutHarness.init` takes the text view to install, defaulting to `NSTextView(usingTextLayoutManager: false)`. Every existing caller compiles unchanged.
- [x] **The ruler.** `LineNumberRulerView` loses `final`, so the test can subclass it. A one-line comment states that reason.
- [x] **Two recording subclasses** in the test file:
  - a text-view subclass that overrides `setNeedsDisplay(_:)` and appends each rect;
  - a ruler subclass that overrides `setNeedsDisplay(_:)` and the `needsDisplay` setter, recording `true` as the full bounds.
- [x] **`testACaretMoveInvalidatesBothPaintersAndMovesTheWash`.**
  - **Setup.** Place the caret on line 0 and clear both records. Then move the caret to line 3 through `coordinator.updateCurrentLine(of:)`.
  - **Text view.** Its recorded rects cover line 0's band and line 3's band. Each band is `layoutManager.currentLineBand(for:)` offset by `textContainerOrigin`.
  - **Ruler.** Its recorded rects cover both bands' vertical ranges.
  - **Render.** Keep the render assertion: the old line is untinted and the new line is tinted.
  - **The window.** If recording works without a window, drop the borderless window and the layer-flag reading. Otherwise keep the window, and replace only the flag assertions.
- [x] **Mutation checks,** run by hand and never committed. Each must fail the test:
  - removing `previous` from `setCurrentLine`'s loop;
  - removing `ruler.needsDisplay = true`.
- [x] **Docs.** Rewrite the suite header to state what is now pinned (both bands, both painters) and the window count. Update the matching passage in `app-editor-overlays.md`.
- [x] Run the gates. They must pass before Task 3.

### Task 3: The caret column after a deletion ending at the caret

**Files:**
- Modify: `Sources/PisakaCore/CaretReadout.swift`, `Sources/Pisaka/CodeEditorView.swift`
- Modify: `Tests/PisakaCoreTests/CaretReadoutTests.swift`
- Modify: `docs/architecture/core-editor.md`, `docs/architecture/app-editor.md`

- [x] **Core.** Add the public `CaretReadout.rebasedMemo(_ memo: ColumnMemo, text: NSString, editStart: Int) -> ColumnMemo?`, plus an internal counted twin that returns `work`. It reads the pre-edit text, is pure, and leaves `countedPosition` unchanged. Its rules, in order:
  1. If `editStart >= memo.offset`, return the memo unchanged, at zero work.
  2. If `editStart < memo.lineStart`, return `nil`.
  3. Otherwise, search for an anchor at or below `editStart` and at least `memo.lineStart`, within `anchorLookback`. Reuse `anchor(in:from:lineStart:)`.
     - **Anchor found:** return `ColumnMemo(lineStart: memo.lineStart, offset: anchor, column: memo.column − count(anchor..memo.offset))`. Charge both the search and the count.
     - **No anchor:** return `nil`.
- [x] **App.** In `textView(_:shouldChangeTextIn:replacementString:)`, before the existing guard:
  - when `caretColumnMemo` exists and `caretEditFloor` is `nil` or at least `memo.offset`, replace the memo with `rebasedMemo(memo, text: textView.string as NSString, editStart: affectedCharRange.location)`;
  - otherwise, leave the memo alone.

  The rebase is idempotent, so a re-entrant call does no harm.
- [x] **Core tests.**
  - **Correctness.** Cover deletions ending at the caret: one unit, a word and a selection. For each, rebase on the pre-edit text, then call `position(…memo:editFloor:)` on the post-edit text. The result equals the full count. Run this over the existing Unicode sweep strings.
  - **Charged bound.** Use a 4,000,000-unit printable-ASCII line with the memo at its end:
    - a one-unit backspace costs at most 2 × (`anchorLookback` + 2) + 1;
    - a five-unit word delete costs at most 5 + 2 × (`anchorLookback` + 2) + 1;
    - a 1,000-unit cut costs at most 1,000 + 2 × (`anchorLookback` + 2) + 1.
  - **The unhandled shapes:**
    - an edit starting before the line start returns `nil`;
    - a deletion spanning back to the line start is correct, and its work is at least the line prefix.
  - **No anchor.** With no ASCII anchor within the lookback, the result is `nil`.
- [x] **Docs.**
  - `CaretReadout.swift`'s doc comments and `core-editor.md` name the handled shapes: backspace, word-delete-backward and cut all rebase in the pre-edit hook.
  - The same two places name the unhandled shapes, which still take the full count:
    - a deletion back past the anchor;
    - a paste replacing the line's head;
    - an edit across a line start.
  - `app-editor.md` describes the coordinator's pre-edit rebase.
- [x] Run the gates, including the iOS build. They must pass before Task 4.

### Task 4: Glyph pins: asset symbols stay off, and the glyph-load rule's horizon

**Files:**
- Modify: `Tests/PisakaCoreTests/DesignGlyphAssetTests.swift`, `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md`

- [x] **The asset-symbols pin.** `DesignGlyphAssetTests` gains a test that reads `project.yml` through `#filePath`, comment-stripped through `activeYAMLLines`. It asserts:
  - exactly one active line equals `ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS: NO`;
  - no active line sets `ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS` or `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS` to anything else.

  The failure message names the generated-accessor form of glyph loading, which the gating rule cannot see.
- [x] Add that pin to the suite header's bullet list.
- [x] **The rule's entry.** Update the glyph-load rule's entry in `ChromeThemeSourceGatingTests`' header, and item 46 in `core-theme.md`, with two points:
  - **The dependency.** The rule relies on asset symbols staying off, which `DesignGlyphAssetTests` pins.
  - **The horizon.** The matcher reads argument lists only, so a glyph name passed through a local variable, or interpolated into a string, passes. Call this "the local-variable form", as other entries do.

  The matcher is not widened, and the rule count stays forty-six.
- [x] Check every place that restates the rule's wording, and update it there.
- [x] Run the gates. They must pass before Task 5.

### Task 5: Main window chrome: the title label's colour in both appearances, and its gap

**Files:**
- Modify: `Sources/Pisaka/MainWindowChrome.swift`
- Modify: `Tests/PisakaAppTests/MainWindowChromeTests.swift`
- Modify: `docs/architecture/app-shell.md`

- [ ] **The gap.**
  - **Measure.** On the suite's placement window, with a long title, record the zoom button's and the label's frames in the title bar view's space and in window space. From those, find where the six points come from.
  - **Fix.** `applyTitleLabel` computes the buttons' trailing edge in the same space as the label's constraints, by converting each button's bounds into the title bar view.
  - Make `titleLabelButtonGap` internal.
- [ ] **Tests,** on the suite's one placement window:
  - **The gap.** With a truncating title, the label's window-space minX minus the zoom button's window-space maxX equals `MainWindowChrome.titleLabelButtonGap`, within 0.5. Also assert that the constant is 8.
  - **The colour.** Resolve the label's `textColor` under `.aqua` and under `.darkAqua`, with `performAsCurrentDrawingAppearance`. Each equals `ChromePalette.nsColor(.textPrimary, in:)` for that appearance, compared component by component.
- [ ] Update the suite header and `app-shell.md`'s `MainWindowChrome.swift` entry.
- [ ] Run the gates. They must pass before Task 6.

### Task 6: Bottom-bar tooltip suite: a truthful cost claim and assertions that discriminate

**Files:**
- Modify: `Tests/PisakaAppTests/BottomBarToolTipTests.swift`
- Modify: `docs/architecture/app-window.md`

- [ ] **Split the scales.** Split `testEachToolTipViewIsItsTogglesSquareAndNothingElseCarriesOne` into two named tests, one at scale 1 and one at scale 1.8, sharing one private assertion helper.
  - The header states the real cost: one titled window per `toolTips` call, and how many each test makes.
  - The sentence "no loop creates an AppKit object" then holds literally.
- [ ] **Widget extent.** For the project widget and the branch widget, measure each widget's width by hosting it once per test and reading `fittingSize`. Assert:
  - the tooltip view's width equals the widget's width, within 0.5;
  - its minX and maxX lie inside the window;
  - the two widgets' tooltip extents overlap neither each other nor any toggle's square.

  The vertical assertion stays.
- [ ] **The vacuous assertion.** Replace `isAccessibilityElement()` with two assertions only the tooltip host answers:
  - its `hitTest` returns `nil` where a plain `NSView` of the same frame returns itself, checked side by side in the test;
  - the hosted instance carries the toggle's tooltip text.

  Drop the accessibility assertion, and record why in the header.
- [ ] Update the passage in `app-window.md` that describes this suite.
- [ ] Run the gates. They must pass before Task 7.

### Task 7: Inline diff tail: no-stamp over-cap, the HEAD size seam, folder switch

**Files:**
- Modify: `Sources/PisakaCore/LocalChangesInlineDiff.swift`, `LocalChangesModel.swift`, `GitServicing.swift`, `CommitDialogModel.swift`, `Sources/Pisaka/GitCLIService.swift`
- Modify: `Tests/PisakaCoreTests/LocalChangesInlineDiffTests.swift`, `LocalChangesModelTests.swift`, `CommitDialogModelTests.swift`
- Modify: `docs/architecture/core-git.md`, `core-git-models.md`, `core-commit.md`, `docs/FEATURES.md` (only if it is no longer truthful)

- [ ] **No stamp.**
  - When `stamp` is `nil`, ask `fileService.fileByteCount(at:)` before reading. Over `maxSideBytes`, the result is `.tooLarge`, with no read.
  - Correct the doc comment that says this case lands in `.binary`.
  - Tests:
    - a `nil` stamp with a byte count over the cap gives `.tooLarge`, and no read is recorded;
    - a `nil` stamp with an unknown byte count still reads.
- [ ] **The HEAD size seam.**
  - `GitServicing` gains `headBlobSize(of:root:) async throws -> Int?`, defaulting to `nil`, which means unknown.
  - `GitCLIService` implements it as `git cat-file -s HEAD:<path>`. A non-zero exit gives `nil`.
  - `LocalChangesModel.loadSelectionDiff` asks the size first. Over the cap, the HEAD side is `.tooLarge`, with no blob read.
  - `CommitDialogModel.headSide(for:root:)` shares the seam. Over `maxSelectableFileBytes`, the result is `.binary`, with no fetch.
  - In both, a `nil` size falls through to today's path.
  - Tests:
    - an over-cap size causes zero blob reads, in both models;
    - an at-cap size still fetches, and so does an unknown size.
  - Document the seam in `core-git.md`, and its two uses in `core-git-models.md` and `core-commit.md`.
- [ ] **Folder switch.**
  - `prepareForFolderChange(root:)` sets `selectionDiff = nil` and bumps the selection-diff token.
  - `refreshImpl`'s success path clears `selectionDiff` when the root changed.
  - Tests:
    - a published diff is gone after a folder change;
    - a refresh that resolves a new root clears it;
    - a load held at a `Gate` past a switch publishes nothing.
  - Document both clears in `core-git-models.md`.
- [ ] Keep `FEATURES.md`'s inline-diff sentence truthful.
- [ ] Run the gates, including the iOS build. They must pass before Task 8.

### Task 8: Diff window title, and the commit dialog's inert counters

**Files:**
- Modify: `Sources/PisakaCore/DiffWindowTitle.swift`, `Sources/Pisaka/PisakaApp.swift`
- Modify: `Tests/PisakaCoreTests/DiffWindowTitleTests.swift`, `Tests/PisakaCoreTests/CommitDialogModelTests.swift`
- Modify: `docs/architecture/core-services.md`, `docs/architecture/app-shell.md`

- [ ] **The title.**
  - `DiffWindowTitle.localChanges(path:projectPrefix:)` builds the path with `ChangedFileGroups.displayPath(_:projectPrefix:)`. `projectPrefix` defaults to `""`.
  - `PisakaApp.openLocalChangesDiff` passes `localChanges.projectPrefix`.
  - Tests cover three cases:
    - the same folder;
    - a nested project: `app/Sources/X.swift` under the prefix `app` reads `Sources/X.swift — Local Changes`;
    - a file outside the project, which takes the fallback form.
  - Update the file's header comment, `core-services.md` and `app-shell.md`.
- [ ] **The inert counters.** In the three memo-drop tests, remove the `unifiedLinesComputations` assertions. Reword each doc comment to say what proves the drop: the empty answer, compared by equality.
- [ ] Run the gates. They must pass before Task 9.

### Task 9: Verify acceptance criteria

- [ ] Run `swift test`.
- [ ] Run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`.
- [ ] Run the macOS build and the `generic/platform=iOS` build.
- [ ] Run `swiftlint --strict` from the repository root.
- [ ] Confirm the gating inventories are current:
  - the rule count reads forty-six in `ChromeThemeSourceGatingTests`, `CLAUDE.md` and `core-theme.md`;
  - the new `DrawDirtyRectSourceGatingTests` is listed in `CLAUDE.md`;
  - `CLAUDE.md` stays under 60,000 characters;
  - no other gating inventory went stale.
- [ ] **Window cost.** Confirm that no new or changed test helper creates a window, hosting view or bitmap per row or per pixel, and that each touched suite's header states its window count truthfully.
- [ ] **No screen recording.** Confirm that no test uses a screen-recording API.

### Task 10: Update documentation

- [ ] Re-read every `docs/architecture/` entry touched above against the final code:
  - `app-git-views.md`, `app-editor-overlays.md`;
  - `core-editor.md`, `app-editor.md`;
  - `core-theme.md`, `app-shell.md`, `app-window.md`;
  - `core-git.md`, `core-git-models.md`, `core-commit.md`, `core-services.md`.
- [ ] `CLAUDE.md` stays an index. Its only change is the new suite's name.
- [ ] `README.md` / `docs/FEATURES.md`: keep the inline diff's placeholder text truthful. No other user-facing change.

## Post-Completion

- **The fix in the running app.**
  - Select a modified text file in Local Changes. The project tree, the tab list, the editor, and the panel's list and header stay drawn.
  - Double-click the file. The separate diff window's left pane draws.
  - Open a Local History diff. Both panes draw.
- **Carried over from the previous review.** These manual checks belong to this ticket's acceptance review:
  - hover tooltips on the project, branch and pull-request widgets;
  - the title label across a full-screen round trip and a theme change;
  - a double-click on a binary row opening the diff window;
  - typing smoothness with the panel open.
