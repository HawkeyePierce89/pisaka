# Git in the editor: gutter change markers, hunk revert, change navigation and word-level diff highlighting

## Overview

The editor gains a live view of what changed in the open file against `HEAD`, plus three ways to act on it. All of this is macOS-only, and the Core parts are Foundation-only so iOS can use them later.

1. **Gutter change markers.** A 2-point strip at the ruler's inner edge marks each line as added or modified, and a small wedge marks where lines were deleted. The live buffer is compared against the file's `HEAD` text. The markers update while the user types, not only on save.
2. **Hunk revert.** Clicking a marker opens a chrome popover that shows the `HEAD` lines and a Revert button. A Git menu item, Revert Change, does the same for the caret's hunk. A revert is one undoable buffer edit. It raises no writer gate, and it consults the gate silently.
3. **Next Change / Previous Change.** These step through the hunks from the caret and wrap around, the same way Next Problem / Previous Problem does.
4. **Word-level emphasis inside modified rows.** This applies to the side-by-side `DiffView` (Local Changes inline diff, Log, Local History) and to the commit dialog's unified diff. The emphasis is computed once per diff build, in Core.

What is new: one hunk model, one navigation rule, one revert plan, one word-diff engine, one generalized line-shift rule, one ruler column, one controller, one popover and three menu items. `LineDiff`'s line algorithm, matrix cap and pairing are untouched.

## Context

### Files involved

Core, read and reused:
- `Sources/PisakaCore/LineDiff.swift`: rows, `DiffRow`, `DiffSide`.
- `TerminatedLines.swift`: verbatim terminators.
- `BlameShift.swift`: the span rule.
- `DiagnosticNavigationRule.swift`: the shape the navigation rule copies.
- `RangeEditPlan.swift`: the apply funnel's input.
- `LocalChangesInlineDiff.swift`: `maxSideBytes`.
- `CommitDiffUnits.swift`: `unified`, `UnifiedDiffLine`.
- `GitBlobText.swift`.
- `ChromeColorRole.swift`: `diffWashRole`, `diffMarkerRole`, the file-status mapping.
- `OccurrenceScan.swift` and `EditorConfigGlob.swift`: double-entry `Work` bookkeeping.
- `LocalChangesModel.swift`: `listRevision`, `isReverting`.

App:
- `Sources/Pisaka/LineNumberRulerView.swift`: the columns, `lineMapDidChange`, `onEdit`, `mouseDown`, `updateThickness`.
- `BlameController.swift`: the controller template.
- `CodeEditorView.swift`: the coordinator, `apply(_:in:afterEdit:)`, `revealRange`, `syncBlame`, `beginBlameBufferSwap`.
- `ProblemCommands.swift`: the menu-items template.
- `ContentView.swift`: `popoverPresenter`, `localChanges`.
- `PisakaApp.swift`: `CommandMenu("Git")`.
- `GitCLIService.swift`: `blame(fileURL:)` runs in the file's directory.
- `ChromePopover.swift` / `ChromePopoverPresenter.swift`.
- `ZoomSurface.swift`: `ZoomSurfaceMarker`.
- `EditorFont.swift`.
- `DiffView.swift`: `DiffTextView.drawBackground`.
- `CommitUnifiedDiffView.swift`.

Tests:
- `Tests/PisakaCoreTests/`: `BlameShiftTests`, `LineDiffTests`, `CommitDiffUnitsTests`, `LocalChangesInlineDiffTests`, `MenuShortcutUniquenessTests`, `ChromeThemeSourceGatingTests`, `ZoomSourceGatingTests`, `LintConfigurationTests`.
- `Tests/PisakaAppTests/`: the ruler suites, and `GitCLIServiceRepositoryTests`' throwaway-repository helper.

Docs:
- `docs/architecture/core-diff-merge.md`, `core-git.md`, `core-git-models.md`, `app-editor-overlays.md`, `app-editor.md`, `core-theme.md`, `core-zoom.md`.
- `docs/FEATURES.md`, `CLAUDE.md`, `.swiftlint.yml` (measured ceilings and their reasons).

### Related patterns

- `BlameController`: weak ruler, monotonic generation token, attach/sync/reset, `beginBufferSwap`, silent failure.
- `ProblemNavigationItems` plus a coordinator extension. These reach the editor through `EditorCommandTarget.focusedEditor` and beep through `PlatformFeedback.warning()`.
- The single-edit apply funnel `Coordinator.apply(_:in:afterEdit:)`: one undo step.
- `ZoomSurfaceMarker(kind: .code)` behind SwiftUI code-font content.
- Colour by role through `ChromePalette.nsColor(_:)` and the SwiftUI theme environment.

### Dependencies

None new.

## Decisions taken in this plan (each restated in the matching doc)

- **Hunk kinds.** A hunk is added, deleted or modified. A deleted hunk is anchored after buffer line n, or before line 1 when n = 0.
- **Per-line markers** are indexed by ruler line (`LineStartIndex.offsets` count). This keeps the shift invariant `result.count == newLineStarts.count`.
  - Each marker carries an optional strip (added/modified) and two wedge flags: `deletedBelow` (anchored after this line) and `deletedAbove` (line 1 only).
  - An empty buffer against non-empty `HEAD` marks index 0 with `deletedAbove`.
- **Marker column geometry.** The strip occupies the existing trailing padding between the right-aligned numbers and the hairline: 2 points wide, with a 1-point gap on each side.
  - It therefore adds zero width in every case. The gutter never moves when markers arrive or clear, and a file with no markers has today's width. This beats the diagnostics column's constant-width trade because nothing at all is added.
  - The wedge is a triangle the column's width wide and about 0.6 of the ruler font tall, centred on the line boundary. Before line 1 it is clamped inside the first fragment's top, and after the last line inside the last fragment's bottom.
- **Colours.** A Core mapping `ChromeColorRole.changeMarkerRole(for:)` sends added to `statusGreen`, modified to `statusYellow` and deleted to `statusRed`. This is a mapping function, like `changedFileRole`, not a new role.
- **Recompute delay: 250 ms after the last edit.** Typical inter-key intervals are under 200 ms, so a burst coalesces into one diff, yet markers settle within a quarter-second of a pause. The autosave's 2-second window is not used, because the markers describe the buffer, not the disk.
- **Commands never act on a stale answer.** The async recompute only feeds drawing. Revert (popover or menu) and Next/Previous Change recompute the hunks synchronously from the held base and the live buffer at the moment of the command, then act on that answer. The cost is bounded by the size cap and `LineDiff`'s prefix/suffix stripping plus matrix cap.
  - The popover remembers the clicked line, not a hunk value, and it is dismissed on any buffer change.
- **Between an edit and the recompute, markers shift with a generalized span rule.** `BlameShift`'s arithmetic moves into a generic `LineShift.updated(previous: [T?], …)`, and `BlameShift.updated` delegates to it so `BlameShiftTests` pass unchanged.
  - The span keeps its markers only when its line count is unchanged; otherwise it is blanked. Blank is honest.
- **Base reads.** Each read runs `git show HEAD:./<name>` in the file's directory, as blame does, so no repository-root resolution is needed.
  - The bytes are classified through `GitBlobText`. A blob that is not text, an absent path, a thrown error or a side over the cap all mean "no markers", silently.
  - The base is re-read on:
    - tab open/switch
    - URL change
    - `contentReplaced`
    - a change of `diskRevision`
    - a change of `LocalChangesModel.listRevision`, which bumps on every refresh publish. That covers commit (including partial), pull, checkout, merge apply, the pull-request checkout and the post-merge tail.
  - Commits made in the embedded terminal stay unseen until one of those happens. This is the limit blame already states, written the same way.
- **Gate consult.** `ContentView` hands the editor a read-only `gitWriteInFlight: () -> Bool` (`localChanges.isReverting`). Revert refuses silently while it is raised: no beep, no alert. It never raises the gate.
- **Revert plan, byte-exact.** The replacement is HEAD's lines for the hunk, terminators verbatim from `TerminatedLines`.
  - A hunk not touching the end of either side replaces exactly its new-side lines; a mid-file deletion inserts at the start of the line after the anchor.
  - When a hunk reaches the end of the buffer, or a deletion is anchored after the last line, the replaced range starts at the preceding line's terminator and the replacement starts with HEAD's terminator for that line. This brings the presence or absence of a final newline back exactly.
  - The caret goes to the start of the hunk's first line.
  - The revert takes no Local History capture: the next autosave captures the buffer as for any edit.
- **Word diff tokens.** A token is a run of word characters (Unicode letters, digits, underscore), a run of whitespace, or a single other character.
  - The diff is an LCS over the tokens after stripping the common token prefix and suffix. Adjacent or touching changed ranges are merged.
  - Results are UTF-16 ranges into each side's text.
- **Word diff threshold.** A row is left whole (no ranges) when the changed non-whitespace UTF-16 units on the longer side exceed 60% of that side's non-whitespace units. Both sides of 60% are tested.
- **Word diff budget.** The LCS is charged in matrix cells: a per-row ceiling of 250,000 cells, plus a per-build ceiling of 4,000,000 shared across all rows of one diff. Over the ceiling, a row gets no ranges.
  - Bookkeeping is double-entry, following `OccurrenceScan.Work`: `record` counts cells actually filled, `spend` charges the ceiling, and the two are never hoisted into one local.
- **Where word ranges live.** `DiffRow` gains `words: WordDiffRanges?` (old-side and new-side `[NSRange]`), defaulted to `nil` in the initializer so every existing construction compiles.
  - `LineDiff.rows(old:new:)` fills it for `.modified` rows after pairing. The pairing itself is unchanged, and the existing fifteen `LineDiffTests` compare fields, so they keep passing unchanged.
  - An internal `rows(old:new:wordRanges: false)` path serves the gutter model, which never draws words.
  - `UnifiedDiffLine` gains `emphasis: [NSRange]` (defaulted to empty). `CommitDiffUnits.unified` copies each side's ranges onto the `-` and `+` lines of a modified row; no other row kind ever carries any.
- **Emphasis drawing.** The changed range is filled again with the row's own `diffWashRole` over the existing wash.
  - At the palette's wash alpha (0x22) the composite reads at roughly twice the wash's opacity in both appearances. On paper that is legible.
  - The live check is in Post-Completion. If it reads illegible in either appearance, the drawing stops at the line and the user decides; no role or value is added.
- **Popover.** It is presented through the window's existing `ChromePopoverPresenter` (the root overlay with its own Esc/click-outside monitors and the injected theme), so no new theme root is added.
  - Anchor: the marker's rect converted from the ruler to the window's content view and flipped into the root's top-left coordinate space.
  - Content: a `ChromePopover`. The Head says "HEAD". The List shows HEAD's lines at `EditorFont`, or "No lines in HEAD" for an added hunk, behind `ZoomSurfaceMarker(kind: .code)`. The Foot holds a Revert button.
- **Shortcuts.**
  - Next Change: ⌃⌥⇧↓. Previous Change: ⌃⌥⇧↑. These avoid Mission Control's ⌃↑/⌃↓ and the existing line commands, and are checked by `MenuShortcutUniquenessTests`.
  - Revert Change has no shortcut.
- **Size caps.** `PisakaApp.swift` and `CodeEditorView.swift` sit at lint size caps, so all new app logic lives in new files: `GitChangeController.swift`, `ChangeCommands.swift`, `ChangeHunkPopover.swift`. Only minimal hooks are added to the two big files, and the `.swiftlint.yml` ceilings move by the measured counts with their reasons appended, as the existing comments do.

## Development Approach

- **Testing approach**: Regular (code first, then tests in the same task). The Core gate is `swift test`. The app-layer gate is `make test-app` under the pinned Xcode.
- Complete each task fully before moving to the next.
- Read each touched file's `docs/architecture/` entry before changing it.
- Async tests use a causal rendezvous (`Gate`/`waitFor`), never a delay. Performance is charged, never timed.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Generalize the line-shift span rule

**Files:**
- Create: `Sources/PisakaCore/LineShift.swift`
- Modify: `Sources/PisakaCore/BlameShift.swift`
- Create: `Tests/PisakaCoreTests/LineShiftTests.swift`

- [ ] Move `BlameShift`'s arithmetic into a generic `LineShift.updated<T>(previous: [T?], previousLineStarts:, newLineStarts:, editedRange:, changeInLength:) -> [T?]`. Keep the same fallbacks, the same `oldEnd - 1` clamp and the same return-`previous`-unchanged fast path. Keep the doc comment's reasoning, moved with the code.
- [ ] Make `BlameShift.updated` a one-line delegate so its callers and `BlameShiftTests` are untouched.
- [ ] Write `LineShiftTests`: a non-`BlameLine` payload covering keystroke, Enter split, whole-line delete, multi-line paste and the fallback guards.
- [ ] Run `swift test`; it must pass.

### Task 2: Hunk model from diff rows

**Files:**
- Create: `Sources/PisakaCore/ChangeHunk.swift`
- Create: `Tests/PisakaCoreTests/ChangeHunkTests.swift`

- [ ] Add `ChangeHunk` (`Equatable`, `Sendable`): `kind` (`added` / `deleted` / `modified`); `newLines: Range<Int>`, empty for a deleted hunk; `anchor`, the buffer line a deleted hunk sits after, -1 for before line 1; `oldLines: Range<Int>`.
- [ ] Add `ChangeHunk.hunks(from rows: [DiffRow]) -> [ChangeHunk]`: maximal runs of non-unchanged rows, with kind derived from which sides the run carries. Pure; it does not re-diff.
- [ ] Add `ChangeMarkerKind` and the per-line `ChangeLineMarker` (optional strip plus `deletedAbove` / `deletedBelow`).
- [ ] Add `ChangeHunk.lineMarkers(for:lineCount:)`, indexed by ruler line.
- [ ] Add `ChromeColorRole.changeMarkerRole(for:)`: added → `statusGreen`, modified → `statusYellow`, deleted → `statusRed`. No new role.
- [ ] Write tests: each kind; adjacent rows merging; deletion before line 1, after the last line and mid-file; a modified run with unequal side counts; an empty buffer; marker array length equal to the line-start count, including a trailing-separator buffer; the role mapping.
- [ ] Run `swift test`; it must pass.

### Task 3: The gutter change model

**Files:**
- Create: `Sources/PisakaCore/GutterChangeModel.swift`
- Modify: `Sources/PisakaCore/LineDiff.swift` (internal no-words entry point only, used here; full word wiring in Task 6)
- Create: `Tests/PisakaCoreTests/GutterChangeModelTests.swift`

- [ ] Add `GutterChangeModel.compute(base: String?, buffer: String) -> GutterChanges`, where `GutterChanges` holds `hunks` and `markers`. It is pure and safe to call off the main thread. No base means empty; either side's UTF-8 count over `maxSideBytes` means empty.
- [ ] Declare `GutterChangeModel.maxSideBytes = 1 << 20`, restated, and pin it equal to `LocalChangesInlineDiff.maxSideBytes` with a test.
- [ ] Add `GutterChanges.hunk(atLine:)` for click/caret lookup: the hunk containing the line, or the deleted hunk anchored at that line boundary; the first in order wins.
- [ ] Write tests: no base, an identical file, the three kinds together; CRLF, separators NEL/LS/PS; whitespace-only change is modified; the cap on each side (just under, just over); `hunk(atLine:)` for strip lines, anchor lines and line 1 carrying both wedges.
- [ ] Run `swift test`; it must pass.

### Task 4: Navigation rule and revert plan

**Files:**
- Create: `Sources/PisakaCore/ChangeNavigationRule.swift`
- Create: `Sources/PisakaCore/HunkRevertPlan.swift`
- Create: `Tests/PisakaCoreTests/ChangeNavigationRuleTests.swift`
- Create: `Tests/PisakaCoreTests/HunkRevertPlanTests.swift`

- [ ] Add `ChangeNavigationRule.targetLine(hunks:caretLine:direction:) -> Int?`, reusing `DiagnosticNavigationDirection`. Stops are each hunk's first new-side line, or its anchor line for a deletion (line 0 for before line 1); stops are distinct and ascending. The search is strictly past the caret, wrapping. No stops answers `nil`.
- [ ] Add `HunkRevertPlan.plan(hunk:base:buffer:) -> RangeEditPlan?`: one edit plus a caret at the hunk's first line start, built from `TerminatedLines` on both sides with terminators verbatim, applying the end-of-text rule from Decisions.
- [ ] Write navigation tests: wrap both ways; caret inside a hunk; caret on a hunk's first line moves on; caret on a deletion's anchor; no hunks.
- [ ] Write revert tests: hunk at the start of the file; modified hunk ending at an unterminated last line; added line at an unterminated end; CRLF file; deletion after the last line, with HEAD both terminated and unterminated; modified hunk with unequal side counts; a fuzz test — reverting every hunk of random small texts, back to front, yields HEAD byte for byte, and reverting one hunk leaves the others' hunks intact.
- [ ] Run `swift test`; it must pass.

### Task 5: Word-level diff engine

**Files:**
- Create: `Sources/PisakaCore/WordDiff.swift`
- Create: `Tests/PisakaCoreTests/WordDiffTests.swift`

- [ ] Add the tokenizer from Decisions.
- [ ] Add `WordDiff.ranges(old:new:work:) -> WordDiffRanges?`: common-token prefix/suffix strip, LCS over the middle, merge of adjacent/touching ranges, and the 60% threshold measured on the longer side.
- [ ] Add a `Work` struct with `record` / `spend`, a per-row ceiling (250,000 cells) and an internal seam taking a caller-owned `Work`, so tests read both what was performed and what was left. A shared per-build `Work` (4,000,000) is threaded through by the caller.
- [ ] Write tests: one changed word, with ranges on both sides; punctuation as single tokens; whitespace runs; non-ASCII letters and surrogate pairs (UTF-16 offsets); merge of touching ranges; threshold just below and just above 60%; identical sides and empty sides.
- [ ] Write the budget test: a minified ~20k-character line against a near-copy drives the per-row ceiling to exhaustion. Assert no ranges, assert the performed cells relative to the charged ceiling (performed ≤ charged, and performed > 0), and assert the per-build ceiling stops later rows.
- [ ] Run `swift test`; it must pass.

### Task 6: Carry word ranges with the rows (one Core answer)

**Files:**
- Modify: `Sources/PisakaCore/LineDiff.swift`
- Modify: `Sources/PisakaCore/CommitDiffUnits.swift`
- Modify: `Tests/PisakaCoreTests/CommitDiffUnitsTests.swift`
- Create: `Tests/PisakaCoreTests/LineDiffWordRangesTests.swift`
- Modify: any Core test that compares built modified rows against hand-built ones (grep for `DiffRow(kind: .modified` and `.rows(` equality)

- [ ] Add `DiffRow.words: WordDiffRanges?`, defaulting to `nil` in `init`.
- [ ] Make `LineDiff.rows(old:new:)` fill it for `.modified` rows only, after pairing, under one per-build `Work`. The `wordRanges: false` path stays for the gutter model.
- [ ] Add `UnifiedDiffLine.emphasis: [NSRange]`, defaulting to empty. `CommitDiffUnits.unified` copies the old-side ranges to the `-` line and the new-side ranges to the `+` line, and gives every other line none.
- [ ] Write tests: modified rows carry ranges; unchanged, added and removed rows never do; a rewritten line carries none; `unified` keeps the pairing, and the `-`/`+` lines' emphasis equals the row's two sides — nothing re-splits; the existing fifteen `LineDiffTests` pass unchanged.
- [ ] Update any equality-based fixture in other Core suites that now sees ranges.
- [ ] Run `swift test`; it must pass.

### Task 7: Ruler marker column

**Files:**
- Modify: `Sources/Pisaka/LineNumberRulerView.swift`
- Create: `Tests/PisakaAppTests/LineNumberRulerChangeMarkerTests.swift`

- [ ] Add `setChangeMarkers(_:)` / `clearChangeMarkers()`. Markers are stored at ruler-line count, and in `lineMapDidChange` they are shifted with `LineShift` beside the blame annotations.
- [ ] Draw strips and wedges in `drawVisibleLine` from the visible-fragment walk, filling the line's full fragment height across wraps, with colour through `ChromePalette.nsColor(ChromeColorRole.changeMarkerRole(for:))`. The column sits in the existing trailing padding, and `updateThickness` is unchanged.
- [ ] Add an internal `changeMarkerHit(at point:) -> Int?`, resolving a click in the column to a ruler line through the layout manager (the chevron click's mapping). For line 1 carrying both wedges, the top half picks the upper one.
- [ ] Add `onChangeMarkerClicked: ((Int, NSRect) -> Void)?`. `mouseDown` checks it after the chevron, with the same modifier/click-count gate.
- [ ] Write headless app tests: `ruleThickness` is identical with and without markers; the hit line for a strip; the hit for a wedge after the last line and before line 1; a click outside the column is not a hit; markers shift across an Enter and blank across a multi-line paste.
- [ ] Run `make test-app`: no new failures beyond the eight known scale-1.8 assertions.

### Task 8: GitChangeController and editor wiring

**Files:**
- Create: `Sources/Pisaka/GitChangeController.swift`
- Modify: `Sources/Pisaka/GitCLIService.swift` (`headText(fileURL:)`: `git show HEAD:./<name>` in the file's directory, classified through `GitBlobText`)
- Modify: `Sources/Pisaka/CodeEditorView.swift` (minimal: own the controller, `attach`/`sync`/`beginBufferSwap`/`reset` beside blame's, forward edits, the new `gitRevision` and `gitWriteInFlight` inputs)
- Modify: `Sources/Pisaka/ContentView.swift` (pass `localChanges.listRevision` and `{ localChanges.isReverting }`)
- Create: `Tests/PisakaAppTests/GitChangeControllerRepositoryTests.swift`

- [ ] Shape the controller like `BlameController`: a weak ruler, a generation token captured synchronously before every hop, and at most one base read in flight plus one pending. It holds `(fileID, url, base)` for the displayed file. `sync(fileID:fileURL:diskRevision:gitRevision:contentReplaced:)` re-reads the base when the file, path, disk revision or git revision changes, or the content was replaced. Read failure or nil clears the markers silently.
- [ ] Recompute: an edit notification schedules a coalesced recompute 250 ms after the last edit. It snapshots the buffer string and the token synchronously, runs `GutterChangeModel.compute` on a detached task, and installs the result only if the token is current. A base arrival also recomputes.
- [ ] Add `currentChanges(buffer:) -> GutterChanges`, the synchronous answer the commands use.
- [ ] Check `GitCLIArgumentSourceGatingTests` and update its inventory for the new `show` invocation if it pins argument shapes.
- [ ] Write the app test, using `GitCLIServiceRepositoryTests`' helper — a throwaway repository with one committed file: base loads; after a buffer edit a hunk appears, observed through a completion hook as a rendezvous rather than a delay; the revert plan's output equals the committed bytes exactly; an untracked file yields no markers.
- [ ] Run `swift test` and `make test-app`; both must pass (apart from the known eight).

### Task 9: Revert Change (popover and menu item)

**Files:**
- Create: `Sources/Pisaka/ChangeHunkPopover.swift`
- Create: `Sources/Pisaka/ChangeCommands.swift`
- Modify: `Sources/Pisaka/ContentView.swift` (hand the editor a present/dismiss closure over `popoverPresenter`)
- Modify: `Sources/Pisaka/PisakaApp.swift` (one `ChangeCommandItems` entry inside `CommandMenu("Git")`)
- Modify: `.swiftlint.yml` (measured ceilings plus reason, if moved)

- [ ] Build the popover: a `ChromePopover` with Head "HEAD", a List of HEAD lines at `EditorFont` (or "No lines in HEAD") behind `ZoomSurfaceMarker(kind: .code)`, and a Foot Revert button, coloured only by popover roles. Anchor: the marker rect, converted to root space. Esc and click-outside are handled by the presenter. A buffer change or tab switch dismisses it.
- [ ] Add the coordinator extension `revertChange(atLine:) -> Bool`: refuse silently when `gitWriteInFlight()`; recompute synchronously and find the hunk; build `HunkRevertPlan` and apply it through `apply(_:in:)` — one undo step, caret at the hunk start, no disk write and no Local History call.
- [ ] Add the Git menu item Revert Change, with no shortcut: the caret line's hunk. It is disabled with no editor focused and beeps when the caret is in no hunk.
- [ ] Write tests (Core coverage stays in Task 4): extend the Task 8 app test — revert through the coordinator path, then undo restores the edit and redo reverts again; with the gate raised, nothing changes.
- [ ] Run `swift test`, `make test-app` and `swiftlint --strict`; all must pass.

### Task 10: Next Change / Previous Change

**Files:**
- Modify: `Sources/Pisaka/ChangeCommands.swift`

- [ ] Add Next Change (⌃⌥⇧↓) and Previous Change (⌃⌥⇧↑) items in the same Git-menu entry, disabled with no open tab.
- [ ] Add the coordinator half: recompute synchronously, ask `ChangeNavigationRule`, convert the line to its start offset and land through `revealRange` (so a folded hunk unfolds). No hunks means beep.
- [ ] Confirm `MenuShortcutUniquenessTests` passes with the new chords and the text view binds neither chord.
- [ ] Run `swift test`, `make test-app` and `swiftlint --strict`; all must pass.

### Task 11: Word emphasis in the diff surfaces

**Files:**
- Modify: `Sources/Pisaka/DiffView.swift` (`DiffTextView.drawBackground`: per visible modified row, fill the side's `row.words` ranges with the row's `diffWashRole` over the wash, through the layout manager's rects for the range)
- Modify: `Sources/Pisaka/CommitUnifiedDiffView.swift` (`AttributedString` background on `line.emphasis` ranges in the line's wash role)
- Create: `Tests/PisakaAppTests/DiffWordEmphasisTests.swift`

- [ ] Draw the emphasis in both `DiffView` panes, which covers Local Changes inline, the Log and Local History. Leave the iOS diff view untouched.
- [ ] Draw the emphasis on the unified diff's `-` and `+` lines.
- [ ] Write headless app tests through `HostedRender` / bitmap: a one-word change shows a stronger wash only inside the word's rect on both panes; a rewritten line shows a uniform wash.
- [ ] Run `make test-app`: no new failures.

### Task 12: Source-gating suites

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `Tests/PisakaCoreTests/ZoomSourceGatingTests.swift`
- Modify: `Tests/PisakaCoreTests/LintConfigurationTests.swift` (only if a pinned ceiling or count moved)

- [ ] Add `ChangeHunkPopover.swift` (and `ChangeCommands.swift`, if it draws) to the theme suite's obeying set, by set equality. Add a rule that the ruler's change column and the popover colour only through roles. Update the suite's doc-comment inventory.
- [ ] Add the popover to the zoom suite's `ZoomSurfaceMarker` set. Pin that its code font comes from `EditorFont`.
- [ ] Run `swift test`; it must pass.

### Task 13: Verify acceptance criteria

- [ ] Run `swift test`.
- [ ] Run `swiftlint --strict` from the repository root.
- [ ] Run `make test-app` under the pinned Xcode: no new failures beyond the eight scale-1.8 assertions.
- [ ] Run `make build` (macOS Release) under the pinned Xcode.
- [ ] Confirm every new Core file has tests that cover its branches: threshold, budget, end-of-text revert cases, wrap rules.

### Task 14: Update documentation

- [ ] `docs/architecture/core-diff-merge.md`: entries for `WordDiff` and for `DiffRow.words` / `UnifiedDiffLine.emphasis`; drop the "no word-level intra-line ranges (deferred)" sentence.
- [ ] `core-git.md`: `LineShift`, with `BlameShift` as its delegate.
- [ ] `core-git-models.md`: `ChangeHunk`, `GutterChangeModel`, `ChangeNavigationRule`, `HunkRevertPlan`, each with the decisions above.
- [ ] `app-editor-overlays.md`: the ruler's change column (geometry, zero width) and `GitChangeController` beside `BlameController`, including the terminal-commit limit.
- [ ] `app-editor.md`: `ChangeCommands`, `ChangeHunkPopover`.
- [ ] `core-theme.md` and `core-zoom.md`: updated counts and lists.
- [ ] `docs/FEATURES.md`: the four features, including the terminal-commit limit stated as blame's is.
- [ ] `README.md`: shortcuts, if it lists Git shortcuts.
- [ ] `CLAUDE.md`: index names for the new Core and app files; the theme-suite file count, if it moved; one invariant bullet — "gutter change markers are a reader; a hunk revert is a buffer edit that raises no gate and consults one"; the file stays under 60,000 characters (`LintConfigurationTests`).

## Post-Completion

Manual checks, not automatable:
- Live acceptance 1–4 from the ticket in a DEBUG build: strips and wedge while typing, save, commit clears, untracked file; popover revert, ⌘Z / ⌘⇧Z, deleted-hunk revert on a CRLF file; Next/Previous Change cycle and beep; word emphasis in the inline diff, diff window and commit dialog.
- Legibility of the composited emphasis in light and dark. If illegible in either appearance, stop at line-level emphasis and ask the user; add no role.
- CI: the macOS Release and iOS builds pass.
