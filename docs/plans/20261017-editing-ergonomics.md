# Editing ergonomics: block indent/outdent, smart Backspace, Move Line, multi-caret Duplicate/Comment, problem navigation, better Toggle Comment

## Overview

This plan closes six gaps in Pisaka's macOS line-editing commands. Every decision is a pure PisakaCore engine over NSString and UTF-16 offsets that returns an edit plan. The app layer applies each plan through one shared multi-range bracket: shouldChangeText(inRanges:), then beginEditing/endEditing, then didChangeText, with the edits applied back-to-front. That makes every command one undo step and one change notification. Undo, autosave, Local History, LSP sync, highlights, folds and diagnostic shifting then keep working with no special cases.

1. R1: Tab on a multi-line selection indents the block. Shift+Tab outdents.
2. R2: Backspace inside space indentation deletes back to the previous indent stop.
3. R3: Move Line Up/Down (⌥⌘[ / ⌥⌘]). A folded block moves, or is swapped past, as one unit.
4. R4: ⌘D and ⌘/ act on every caret and range.
5. R5: Next/Previous Problem (⌘' / ⌘⇧'). It visits errors only when the file has any, and shows the diagnostic popover at the landing point.
6. R6: Toggle Comment aligns its markers at the minimum indentation column and writes {/* */} in JSX children. A new Toggle Block Comment command takes ⌥⌘/.

Decision from the Q&A: block indent, Shift+Tab and smart Backspace all use Enter's unit, IndentUnitRule.unit (EditorConfig first, then inference). Plain Tab on a caret keeps the stricter tabInsertion rule. The EditorConfig invariant in CLAUDE.md and core-editorconfig.md is reworded so the inferred unit may drive exactly these three commands.

## Context

- Core engines to extend:
  - Sources/PisakaCore/IndentUnitRule.swift: tabInsertion and tabInsertionPlan stay unchanged for the iOS caller.
  - Sources/PisakaCore/ToggleCommentEngine.swift
  - Sources/PisakaCore/CommentStyle.swift
  - Sources/PisakaCore/DuplicateEngine.swift
  - Sources/PisakaCore/IndentEngine.swift: inferIndentUnit.
  - Sources/PisakaCore/LineStartIndex.swift, Sources/PisakaCore/TerminatedLines.swift
  - Sources/PisakaCore/FoldState.swift, Sources/PisakaCore/FoldRegion.swift, Sources/PisakaCore/FoldShift.swift
  - Sources/PisakaCore/DiagnosticStore.swift, Sources/PisakaCore/Diagnostic.swift
- New Core files:
  - Sources/PisakaCore/RangeEditPlan.swift
  - Sources/PisakaCore/BlockIndentEngine.swift
  - Sources/PisakaCore/MoveLineEngine.swift
  - Sources/PisakaCore/DiagnosticNavigationRule.swift
  - Sources/PisakaCore/BlockCommentEngine.swift
- App layer:
  - Sources/Pisaka/CodeEditorView.swift: the coordinator's doCommandBy, insertConfiguredTab, deleteAutoPair, duplicateSelection, toggleComment and the reveal funnel; EditorTextView.
  - Sources/Pisaka/SyntaxTreeSnapshot.swift: the cached tree and the static parse, which tag highlighting already uses.
  - Sources/Pisaka/FoldController.swift: apply(_:).
  - Sources/Pisaka/HoverController.swift
  - Sources/Pisaka/PisakaApp.swift: the Edit block holding Toggle Comment, the Group of command types, and the Find menu.
  - New: Sources/Pisaka/LineCommands.swift.
- Tests:
  - Tests/PisakaCoreTests: IndentUnitRuleTests, ToggleCommentEngineTests, CommentStyleTests, DuplicateEngineTests, FoldingSourceGatingTests, MenuShortcutUniquenessTests, plus new suites per engine.
  - Tests/PisakaAppTests: one new suite for the JSX context walk over a real TSX parse.
- Docs: docs/architecture/core-editor.md, app-editor.md, core-editorconfig.md, core-lsp.md, core-folding.md; docs/FEATURES.md; README.md; CLAUDE.md (53,814 characters now, limit 60,000).
- Patterns:
  - insertConfiguredTab's back-to-front bracket, including typingAttributes and the one scrollRangeToVisible.
  - isApplyingProgrammaticEdit and the hasMarkedText guards.
  - FoldCommands and SelectionCommands as stateless Commands types that reach the editor through EditorCommandTarget.focusedEditor.
  - PlatformFeedback.warning() for a beep.
- Dependencies: none new.

## Development Approach

- Testing approach: Regular (engine code first, then its Core tests in the same task).
- Complete each task fully before starting the next. `swift test` must be green at the end of every task.
- Every decision is a Core function. The view only reads the buffer and selection, asks the engine, and applies the plan.
- Never mid-composition. Every programmatic edit sets isApplyingProgrammaticEdit across the whole bracket.
- Line handling goes through LineStartIndex/TerminatedLines, so LF/CR/CRLF/NEL/LS/PS are all covered.
- The app-layer gates run under the pinned Xcode 26.3: `make test-app` and `make build`.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Shared multi-range edit plan and app applier

**Files:**

- Create: `Sources/PisakaCore/RangeEditPlan.swift`
- Modify: `Sources/Pisaka/CodeEditorView.swift`
- Create: `Tests/PisakaCoreTests/RangeEditPlanTests.swift`
- [x] Add `RangeEditPlan`:
  - ascending, non-overlapping `[IndentReplacement]` against the original offsets;
  - post-edit `selections: [NSRange]`;
  - `isEmpty`;
  - a validating initializer that refuses overlapping or unsorted edits;
  - a pure `mapped(offset:)` helper that moves an offset through the edits, which engines use to place carets.
- [x] In the coordinator, extract `apply(_ plan: RangeEditPlan, in textView:) -> Bool` from insertConfiguredTab's bracket:
  - shouldChangeText(inRanges:), then beginEditing, back-to-front replaceCharacters carrying typingAttributes, endEditing, didChangeText;
  - setSelectedRanges, then scroll the first selection into view;
  - isApplyingProgrammaticEdit held for the whole bracket.
- [x] Re-implement insertConfiguredTab on top of the applier, unchanged in behaviour. Its literal-tab fall-through to AppKit stays untouched.
- [x] Update the "one scroll that is not the reveal funnel" comment so it names the applier.
- [x] Tests: validation, the empty plan, offset mapping before, inside and after an edit, and insertions at the same offset.
- [x] Run `swift test`. It must pass.

### Task 2: Block indent and outdent engine (R1, Core)

**Files:**

- Create: `Sources/PisakaCore/BlockIndentEngine.swift`
- Create: `Tests/PisakaCoreTests/BlockIndentEngineTests.swift`
- Modify: `Tests/PisakaCoreTests/IndentUnitRuleTests.swift` (pin that tabInsertionPlan is unchanged)
- [ ] `BlockIndentEngine.isBlockSelection(text:ranges:) -> Bool`: true when any range spans more than one line, or covers a whole line including its terminator.
- [ ] Touched lines follow ToggleCommentEngine's existing rule: a non-empty selection that ends exactly at a line start does not touch that line.
- [ ] `indent(text:ranges:unit:) -> RangeEditPlan`:
  - inserts `unit` at the start of every touched non-blank line, once per line across all ranges, as merged line sets;
  - leaves blank and whitespace-only lines alone, so no trailing whitespace is created;
  - extends each selection to keep covering the same text: a start at column 0 stays at the line start, and the end moves with its line.
- [ ] `outdent(text:ranges:unit:) -> RangeEditPlan` for a caret and a selection alike. Per touched line it removes at most one unit:
  - the line starts with a tab: remove that one tab, whatever the unit (the documented mixed-indentation rule);
  - otherwise remove up to unit-width leading spaces, or the shorter run that exists;
  - no leading whitespace: leave the line alone. An empty plan means no line changed. Carets and selections shift left, clamped at the line start.
- [ ] Tests:
  - three lines are indented with the selection preserved, and outdent restores them byte-for-byte;
  - tab unit;
  - blank lines are skipped;
  - mixed tab line with a spaces unit;
  - short runs;
  - a caret outdents its line;
  - no-op answers an empty plan;
  - overlapping and adjacent ranges merge;
  - empty file, first and last line, no trailing newline, CRLF, and each of the six separators;
  - a test that fails if Tab on a multi-line selection replaced the text, the old behaviour.
- [ ] Run `swift test`. It must pass.

### Task 3: Smart Backspace engine (R2, Core)

**Files:**

- Modify: `Sources/PisakaCore/BlockIndentEngine.swift`
- Modify: `Tests/PisakaCoreTests/BlockIndentEngineTests.swift`
- [ ] Add `smartBackspace(text:selections:unit:) -> RangeEditPlan?`. It answers nil, meaning stock deletion, unless every selection is a zero-width caret with:
  - at least one character of leading whitespace before it;
  - only spaces between the line start and the caret;
  - a unit made of spaces, so its width is known.
- [ ] Each deletion runs back to the previous multiple of the unit width, measured from the column. It removes at most one unit and never crosses non-whitespace. Several carets on one line merge.
- [ ] Tests:
  - 4-space unit: column 8 goes to 4, column 6 goes to 4, column 1 goes to 0;
  - after `foo` answers nil;
  - a selection answers nil;
  - tab whitespace answers nil;
  - a tab unit answers nil;
  - one non-qualifying caret makes the whole command nil;
  - multi-caret gives one plan;
  - CRLF and other separators.
- [ ] Run `swift test`. It must pass.

### Task 4: Wire Tab, Shift+Tab and Backspace (R1/R2, app)

**Files:**

- Modify: `Sources/Pisaka/CodeEditorView.swift`
- Modify: `docs/architecture/core-editorconfig.md`, `docs/architecture/core-editor.md`, `docs/architecture/app-editor.md`
- [ ] insertTab: when `BlockIndentEngine.isBlockSelection` is true and no text is marked, apply `indent` with `indentUnit(text:)`, which is IndentUnitRule.unit, the rule's answer. Otherwise run today's insertConfiguredTab path untouched.
- [ ] Route insertBacktab in doCommandBy to `outdent`:
  - mid-composition it is consumed as a no-op;
  - an empty plan beeps nothing and registers no undo;
  - it returns true.
- [ ] deleteBackward: deleteAutoPair runs first. Then ask `smartBackspace`; nil falls through to stock. Option- and Command-Backspace are different selectors and are left untouched.
- [ ] Confirm the completion popup's key handling still runs before doCommandBy, so precedence is unchanged.
- [ ] Docs:
  - core-editorconfig.md: rewrite the "Tab is stricter" paragraph. Plain Tab on a caret stays strict; block indent, Shift+Tab and smart Backspace use Enter's unit. Document the mixed-indentation rule, and record that the explicit command is the one sanctioned rewrite of existing indentation.
  - core-editor.md: the BlockIndentEngine entry.
  - app-editor.md: the wiring.
- [ ] Tests: add a Core test that `IndentUnitRule.tabInsertionPlan` answers exactly as before for a single range and for several. The Core suites from Tasks 2–3 cover the decisions.
- [ ] Run `swift test` and `make build`. Both must pass.

### Task 5: Move Line engine with fold units (R3, Core)

**Files:**

- Create: `Sources/PisakaCore/MoveLineEngine.swift`
- Create: `Tests/PisakaCoreTests/MoveLineEngineTests.swift`
- [ ] `MoveLineEngine.move(text:ranges:direction:folds:) -> MoveLinePlan?`:
  - takes the touched lines of every range and merges adjacent or overlapping blocks;
  - grows each block to cover any folded region it touches, where a folded region is its header line plus its hidden lines;
  - takes as the neighbour the adjacent line, or the whole folded region when that line belongs to one;
  - swaps the block with its neighbour, as one replacement over the pair per block, all within one plan.
- [ ] It answers nil, meaning no-op with no undo, when any block already sits at the first or last line.
- [ ] Terminators:
  - every line keeps its own terminator;
  - when the swap changes which line is last in a file with no trailing newline, the line becoming last gives up its terminator to the line leaving the last position;
  - so the file's line count and final-terminator state are preserved, and nothing is merged, lost or duplicated.
- [ ] `MoveLinePlan` holds:
  - `edit: RangeEditPlan`, whose selections move with the text;
  - `folds: FoldState`: every folded region inside a moved block or neighbour is translated by its block's displacement, with header lines renumbered, and every other region is unchanged.
- [ ] Chosen fold behaviour: a fold is never revealed and never left pointing at the wrong text. The app applies the edit, which runs the ordinary shift rule, then installs `plan.folds`.
- [ ] Tests:
  - line 2 of 3 moves down, with the caret on the moved text;
  - up and down at the edges answer nil;
  - the last line without a trailing newline, both directions, with line count and terminator assertions;
  - CRLF, and mixed separators across all six;
  - a multi-line selection moves;
  - two carets on adjacent lines merge into one block;
  - two separate blocks move independently;
  - blocks that would collide after the move;
  - a folded neighbour is skipped whole, the moved block carries a fold, and the resulting FoldState is pinned;
  - empty file and single-line file.
- [ ] Run `swift test`. It must pass.

### Task 6: Move Line commands (R3, app)

**Files:**

- Create: `Sources/Pisaka/LineCommands.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`, `Sources/Pisaka/CodeEditorView.swift`
- Modify: `Tests/PisakaCoreTests/MoveLineEngineTests.swift`
- Modify: `Tests/PisakaCoreTests/FoldingSourceGatingTests.swift` (if its writer inventory needs the new caller)
- Modify: `docs/architecture/core-folding.md`
- [ ] Add a `LineCommands` Commands type in the FoldCommands/SelectionCommands shape, with `CommandGroup(after: .pasteboard)`:
  - Move Line Up, ⌥⌘[;
  - Move Line Down, ⌥⌘].

  It goes inside the existing `Group` in PisakaApp, so no new top-level entry is added. A nil answer or no editor beeps.
- [ ] Add the coordinator entry `moveLines(_ direction:) -> Bool`: read the folded regions from FoldController, apply `plan.edit` through the applier, then install `plan.folds` with `foldController.apply(_:)`, handing over a whole value.
- [ ] Undo is an ordinary edit, stated and pinned rather than accidental: undoing a move replays the inverse replacement through the existing `FoldShift.updated` rule and nothing else, so a fold inside the swapped span may open on undo. No fold is ever registered in undo.
  - core-folding.md states this next to the move's fold rule.
  - A Core test in MoveLineEngineTests takes a move whose block carries a fold, applies `plan.folds`, then feeds the inverse edit (the pair span in the new text, the original pair text) to `FoldShift.updated`, and pins the result: the fold intersecting the swapped span is dropped, folds outside it shift unchanged.
- [ ] Update FoldingSourceGatingTests if the set of files that hand a value through apply(_:) is pinned. The move is a new whole-value writer, not a fourth spelled mutation.
- [ ] Tests: run MenuShortcutUniquenessTests with the new chords. The ⌥⌘[ and ⌥⌘] chords are distinct from the tab-navigation ⌘⇧[ and ⌘⇧].
- [ ] Docs:
  - core-editor.md: the MoveLineEngine entry.
  - core-folding.md: the move's fold rule and the undo rule above.
  - app-editor.md: the wiring.
- [ ] Run `swift test` and `make build`. Both must pass.

### Task 7: Multi-range Duplicate and aligned, multi-range Toggle Comment (R4 + R6 alignment)

**Files:**

- Modify: `Sources/PisakaCore/DuplicateEngine.swift`, `Sources/PisakaCore/ToggleCommentEngine.swift`
- Modify: `Tests/PisakaCoreTests/DuplicateEngineTests.swift`, `Tests/PisakaCoreTests/ToggleCommentEngineTests.swift`
- Modify: `Sources/Pisaka/CodeEditorView.swift`
- [ ] Add `DuplicateEngine.duplicate(text:selectedRanges:) -> RangeEditPlan`:
  - each range keeps today's semantics: a caret duplicates its line, a selection duplicates itself;
  - carets on the same line duplicate that line once;
  - one resulting caret or selection per original range, placed in the copy;
  - a single range equals today's DuplicateEdit, pinned by a test.
- [ ] Toggle Comment alignment: when commenting, insert `token + " "` at the minimum leading-whitespace length of the non-blank touched lines, counted in UTF-16 units, so a tab counts as one unit. Document that.
  - Uncommenting already strips the token after each line's own indentation, so both the aligned form and the old per-line form are recognised.
  - The caret delta applies when the caret column is at or past the insertion column.
  - Existing tests are updated deliberately to the aligned expectation, not deleted.
- [ ] Add `ToggleCommentEngine.toggle(text:selectedRanges:language:style:) -> RangeEditPlan?`:
  - line-style languages: the line set is the union of lines touched by all ranges, and one all-commented decision and one alignment column apply across that union; edits are per line: a zero-length insertion, or a deletion of the token plus an optional space;
  - block-style languages (css, html, and the JSX contextual style of Task 8): the touched lines are merged into contiguous line blocks, and each block is wrapped separately, or unwrapped when it is already wrapped, as one wrap per merged block, all in one plan;
  - selections are mapped through the plan. The single-range answer matches the existing engine's text and selection.
- [ ] Coordinator: duplicateSelection and toggleComment read `selectedRanges` and apply through the applier, as one undo step.
- [ ] Tests:
  - lines indented 4 and 8 get `//` at column 4 on both, and uncommenting restores them byte-for-byte;
  - the old per-line form uncomments;
  - a column selection across 3 lines duplicates and comments all 3;
  - non-contiguous caret lines;
  - two separate line blocks in CSS get two `/* */` wraps in one plan, and a second toggle unwraps both;
  - blank lines are untouched;
  - CRLF and the six separators;
  - a test that fails if only the first range were edited.
- [ ] Run `swift test`. It must pass.

### Task 8: Contextual JSX comment style (R6, Core + app)

**Files:**

- Modify: `Sources/PisakaCore/CommentStyle.swift`, `Sources/PisakaCore/ToggleCommentEngine.swift`
- Modify: `Tests/PisakaCoreTests/CommentStyleTests.swift`, `Tests/PisakaCoreTests/ToggleCommentEngineTests.swift`
- Modify: `Sources/Pisaka/SyntaxTreeSnapshot.swift`, `Sources/Pisaka/CodeEditorView.swift`
- Create: `Tests/PisakaAppTests/CommentContextTreeWalkTests.swift`
- [ ] In CommentStyle, add `enum CommentContext { case code, jsxChildren }`.
- [ ] Add `CommentStyle.context(ancestors: [(kind: String, startsAtLineOffset: Bool)]) -> CommentContext`, read innermost first. `startsAtLineOffset` is true when the node starts exactly at the line's first non-whitespace offset. Ancestor kinds alone cannot tell a child line from a continuation line inside a multi-line opening tag, which is why the flag is part of the input. Rule:
  - `jsx_expression` or `jsx_attribute` answers code;
  - `jsx_text` answers jsxChildren;
  - `jsx_element`, `jsx_self_closing_element`, `jsx_opening_element` or `jsx_closing_element` answers jsxChildren only when the node starts at the line offset and its enclosing element's parent is `jsx_element`;
  - one of those element nodes that does not start at the line offset answers code, because the line is inside a tag;
  - unlisted kinds are skipped and the walk continues;
  - reaching the root answers code. There is no `jsx_fragment` case: the pinned TSX grammar has no such node, and a fragment is a `jsx_element` whose opening element has no name. The doc comment says so.
- [ ] Add `CommentStyle.style(for:context:)`:
  - jsxChildren in javascript, typescript or tsx answers `.block(open: "{/*", close: "*/}")`;
  - every other case answers `style(for:)`. CommentStyle stays the single table.
- [ ] Toggle Comment uses the contextual style for a merged line block only when both its first and its last non-blank touched lines answer jsxChildren. The block path of Task 7 then wraps and unwraps `{/* … */}` around that block.
- [ ] App side, in a new `CommentContextTreeWalk` beside `SelectionExpansionTreeWalk`:
  - for each of those lines, collect the innermost-first ancestor chain at the line's first non-whitespace offset as (kind, startsAtLineOffset) pairs;
  - use `SyntaxTreeSnapshot.cached`, else a synchronous `SyntaxTreeSnapshot.parse`, for JSX-capable languages only;
  - no tree answers code silently.
- [ ] Core tests:
  - the rule over synthetic chains: a child element line, a jsx_text line, a line inside `{…}`, the root element in a `return (…)`, plain code;
  - an attribute line inside a multi-line opening tag (`className="x"`) answers code;
  - a lone `/>` line answers code;
  - a child's closing `</span>` line answers jsxChildren;
  - the children of a fragment `<>...</>` answer jsxChildren;
  - style(for:context:) over all languages;
  - toggle wraps and unwraps `{/* */}`;
  - two separate blocks in JSX children get two `{/* */}` wraps in one plan;
  - a test that fails if `//` were written into JSX children.
- [ ] App test: parse real TSX and assert that:
  - a `<div>` child line is jsxChildren;
  - a `{…}` line and plain TS are code;
  - an attribute line inside a multi-line opening tag is code;
  - a child line of a `<>...</>` fragment is jsxChildren.
- [ ] Run `swift test` and `make test-app`. Both must pass.

### Task 9: Toggle Block Comment (R6, ⌥⌘/)

**Files:**

- Create: `Sources/PisakaCore/BlockCommentEngine.swift`
- Create: `Tests/PisakaCoreTests/BlockCommentEngineTests.swift`
- Modify: `Sources/PisakaCore/CommentStyle.swift`, `Tests/PisakaCoreTests/CommentStyleTests.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`, `Sources/Pisaka/CodeEditorView.swift`
- [ ] Add `CommentStyle.blockDelimiters(for:context:)`:
  - `/* */` for swift, javascript, typescript, tsx, go, rust and css;
  - `<!-- -->` for html;
  - `{/* */}` in the JSX context.
- [ ] Add closed sets `languagesWithBlockComments` and `languagesWithoutBlockComments`. Pin by set equality that they partition `SyntaxLanguage.allCases`.
- [ ] `BlockCommentEngine.toggle(text:selectedRanges:delimiters:) -> RangeEditPlan`, applied per range in one plan:
  - a selection that starts with `open` and ends with `close` (with an optional inner space each side) unwraps;
  - any other selection is wrapped as `open + " " + text + " " + close`, and the selection then covers the wrapped text, so a second press unwraps;
  - a caret inserts `open` + two spaces + `close`, i.e. `/*  */`, with the caret placed between the two spaces.
- [ ] Chosen fallback: a language with a line style but no block syntax (`#` and `--` languages) runs the line-comment toggle. json and markdown are a no-op with a beep.
- [ ] Menu: add Toggle Block Comment (⌥⌘/) beside Toggle Comment inside the same existing `CommandGroup(after: .pasteboard)` block in PisakaApp, routed like toggleCommentAtCaret through EditorTextView.
- [ ] Tests:
  - wrap, unwrap and caret insert;
  - a caret at offset k in a Swift buffer yields exactly `/*  */` inserted at k, with the resulting caret at k + 3, between the two spaces;
  - HTML delimiters;
  - JSX delimiters;
  - multi-range;
  - the fallback for python and sql;
  - the no-op for json;
  - the set-equality coverage.
- [ ] Run `swift test`. It must pass.

### Task 10: Next / Previous Problem (R5)

**Files:**

- Create: `Sources/PisakaCore/DiagnosticNavigationRule.swift`
- Create: `Tests/PisakaCoreTests/DiagnosticNavigationRuleTests.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`, `Sources/Pisaka/CodeEditorView.swift`, `Sources/Pisaka/HoverController.swift`
- [ ] `DiagnosticNavigationRule.target(diagnostics:caret:direction:) -> Int?`:
  - when any error exists, only errors are considered; otherwise all severities;
  - stops are the distinct start offsets, ascending;
  - next is the first stop strictly after the caret, wrapping to the first;
  - previous is the last stop strictly before the caret, wrapping to the last;
  - no stops answers nil.
- [ ] Coordinator `goToProblem(_ direction:) -> Bool`:
  - reads `DiagnosticStore.entry(for:)`, already shifted by DiagnosticShift; no server request is made;
  - places the caret through the existing reveal funnel the Problems row uses, so folds unfold by the reveal rule;
  - then presents the diagnostics-only popover anchored at the target through a new `HoverController.showDiagnostics(at:in:)`. It reuses the diagnostics HoverContent composition and the generation token, and runs after the selection change, so the popover's dismiss-on-selection does not tear it down;
  - if the anchor rect is not laid out yet, it presents on the next run-loop turn.
- [ ] Menu: add Next Problem (⌘') and Previous Problem (⌘⇧') to the existing Find menu, `.disabled(model.selectedID == nil)`. A nil target beeps.
- [ ] Tests:
  - 2 errors and 3 warnings cycle through the 2 errors only and wrap;
  - warnings only cycle all 3;
  - previous wraps backwards;
  - diagnostics with the same start are one stop;
  - a caret at a start moves on;
  - an empty list answers nil.
- [ ] Run MenuShortcutUniquenessTests.
- [ ] Docs: core-lsp.md (the navigation rule as a reader over the store) and app-editor.md (wiring and popover).
- [ ] Run `swift test` and `make build`. Both must pass.

### Task 11: Verify acceptance criteria

- [ ] Run `swift test`.
- [ ] Run `swiftlint --strict` from the repository root.
- [ ] Run `make test-app` and `make build` under the pinned Xcode 26.3 (PINNED_XCODE).
- [ ] Confirm MenuShortcutUniquenessTests and the source-gating suites are green.
- [ ] Confirm each new engine's suite covers the edge cases listed in its task, and that a regression test exists for each old behaviour that changed: Tab replacing a multi-line selection, ⌘D and ⌘/ editing only the first range, and per-line ragged comment markers.

### Task 12: Update documentation

- [ ] docs/FEATURES.md: the block indent/outdent, smart Backspace, Move Line, multi-caret Duplicate/Comment, Next/Previous Problem, aligned and JSX-aware Toggle Comment, and Toggle Block Comment sections.
- [ ] README.md: add ⌥⌘[ / ⌥⌘], ⌘' / ⌘⇧', ⌥⌘/ and Shift+Tab to the shortcut table.
- [ ] docs/architecture entries:
  - core-editor.md: RangeEditPlan, BlockIndentEngine, MoveLineEngine, BlockCommentEngine, and the CommentStyle and ToggleCommentEngine changes;
  - app-editor.md;
  - core-editorconfig.md;
  - core-lsp.md;
  - core-folding.md.
- [ ] CLAUDE.md:
  - add the new Core files to the core-editor.md index line, and DiagnosticNavigationRule.swift to the core-lsp.md line;
  - reword the "Tab is stricter" sentence of the Indentation invariant;
  - add `LineCommands.swift` to the app-editor.md line;
  - keep the file under 60,000 characters, which LintConfigurationTests checks.

## Post-Completion

- In a DEBUG build, check by hand:
  - ⌘/ on a TSX `<div>` child line and on an attribute line of a multi-line opening tag;
  - ⌘' landing popover placement;
  - Move Line across a folded block, and undo of that move;
  - IME composition with Tab and Shift+Tab.
