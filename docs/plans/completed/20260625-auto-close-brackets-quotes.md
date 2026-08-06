# Auto-close brackets & quotes

## Overview

Add auto-closing of bracket and quote pairs to the editor: typing an opener
inserts its closer with the caret between them, typing a matching closer over an
auto-inserted one steps past it, Backspace on an empty pair deletes both, and
typing an opener/quote with a selection wraps it. Pairs: `()`, `[]`, `{}`, `""`,
`''`, `` `` ``.

Per the project's split, all decision logic is pure and lives in a new
`PisakaCore/AutoPairEngine.swift` (unit-tested, Foundation-only); the
`NSTextView` interception is thin wiring in `CodeEditorView`, coordinated with
the existing auto-indent / dedent-on-closing interception.

## Context

- Files involved:
  - Create: `Sources/PisakaCore/AutoPairEngine.swift`
  - Create: `Tests/PisakaCoreTests/AutoPairEngineTests.swift`
  - Modify: `Sources/Pisaka/CodeEditorView.swift` (the `Coordinator`'s
    `shouldChangeTextIn` and `doCommandBy` interceptors, and the
    `isApplyingIndentEdit` reentrancy flag)
  - Modify: `CLAUDE.md`, `README.md`
- Related patterns: `IndentEngine.swift` (pure `NSString`/UTF-16 engine with
  `Equatable` value types, `LineStartIndex`-based line splitting, raw-character
  bracket matching with no string/comment awareness) is the direct model. The
  view glue mirrors the existing `newlineIndentation` / `dedentOnClosing`
  interception (programmatic edits via `insertText(_:replacementRange:)` for
  single-step undo, guarded by a reentrancy flag).
- Dependencies: none new. `PisakaCore` stays Foundation-only.

## Development Approach

- **Testing approach**: TDD-leaning — `AutoPairEngine` is pure, so write the
  engine and its tests together (Task 1) before wiring the view (Task 2). The
  view layer is thin and intentionally not unit-tested, per project convention.
- Complete each task fully before moving to the next.
- **CRITICAL: every code task includes new/updated tests where the code is in
  `PisakaCore`.**
- **CRITICAL: all tests must pass (`swift test`) before starting the next task.**

## Implementation Steps

### Task 1: AutoPairEngine in PisakaCore (pure + tested)

**Files:**
- Create: `Sources/PisakaCore/AutoPairEngine.swift`
- Create: `Tests/PisakaCoreTests/AutoPairEngineTests.swift`

- [x] Define `public enum AutoPairAction: Equatable` with cases
  `wrap(open: String, close: String)`, `insertPair(close: String)`, `typeOver`,
  `passthrough`.
- [x] Define `public enum AutoPairEngine` with the opener→closer /
  closer→opener / self-closing-quote tables (`(`↔`)`, `[`↔`]`, `{`↔`}`, and
  `"`, `'`, `` ` `` as their own close).
- [x] Implement `public static func action(text: NSString, selectedRange:
  NSRange, typed: String) -> AutoPairAction`:
  - Non-single-character `typed` → `.passthrough`.
  - Opener: selection non-empty → `.wrap`; else can-close → `.insertPair`; else
    `.passthrough`.
  - Closer: next char (at `selectedRange` end) equals the typed closer →
    `.typeOver`; else `.passthrough`.
  - Quote: selection non-empty → `.wrap`; else next char equals the quote →
    `.typeOver`; else can-close-quote → `.insertPair`; else `.passthrough`.
  - can-close (brackets): the next char is end-of-buffer, a line separator (same
    set as `IndentEngine`/`LineStartIndex`), whitespace, or a closing bracket —
    so an opener before a word does not strand a closer.
  - can-close-quote: can-close AND the char immediately before the caret is not
    alphanumeric (so `don'` → passthrough, not `don''`).
- [x] Implement `public static func shouldDeletePair(text: NSString, location:
  Int) -> Bool`: true when the char immediately before `location` is an
  opener/quote and the char immediately after `location` is its matching closer
  (empty pair `(|)`, `"|"`, …); false otherwise (mismatched, non-empty, or caret
  not between a pair; guard boundaries).
- [x] Use surrogate-safe `UnicodeScalar`/`character(at:)` reads (map surrogate
  halves to non-matching), matching `IndentEngine`'s approach; all index math
  guards buffer bounds.
- [x] Write `AutoPairEngineTests` covering: `insertPair` for each pair at
  end-of-line / before whitespace / before a closer; opener before a word →
  `.passthrough`; `typeOver` for brackets and for quotes when next char equals;
  apostrophe in a word (`don'`) → `.passthrough` and a quote before a word →
  `.passthrough`; `wrap` for a non-empty selection with an opener and with a
  quote; `shouldDeletePair` true for empty matching pair, false for
  non-empty/mismatched/not-between; end-of-file and line-separator-neighbor
  boundary cases.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: Wire AutoPairEngine into CodeEditorView

**Files:**
- Modify: `Sources/Pisaka/CodeEditorView.swift`

- [x] Rename the reentrancy flag `isApplyingIndentEdit` →
  `isApplyingProgrammaticEdit` (update its doc comment and all uses) so it gates
  both indent and auto-pair programmatic edits.
- [x] In `textView(_:shouldChangeTextIn:replacementString:)`, restructure so it
  handles auto-pair for single-character `replacementString` (including
  non-empty `affectedCharRange` for wrap) while preserving the existing dedent
  path:
  - Bail (`return true`) while `isApplyingProgrammaticEdit` is set.
  - Compute `AutoPairEngine.action(text:, selectedRange: affectedCharRange,
    typed: replacementString)`.
  - `.wrap(open, close)`: in one `insertText(_:replacementRange:)`, replace the
    selection with `open + selectedSubstring + close`; set the selection to the
    wrapped inner range; `return false`.
  - `.insertPair(close)`: insert `typed + close` at the caret via one
    `insertText`, then set the caret between them; `return false`.
  - `.typeOver`: move the caret one past the existing closer without inserting;
    `return false`.
  - `.passthrough`: for a single closing bracket, fall through to the existing
    `dedentOnClosing` logic (unchanged); otherwise `return true`.
  - Order for a closing bracket: auto-pair `.typeOver` is checked first; only on
    `.passthrough` does the dedent path run.
- [x] Each programmatic auto-pair edit is bracketed by
  `isApplyingProgrammaticEdit = true/false` and goes through
  `insertText(_:replacementRange:)` so the per-file undo manager records it as
  one step.
- [x] In `textView(_:doCommandBy:)`, intercept `deleteBackward(_:)`: when the
  selection is empty and `AutoPairEngine.shouldDeletePair(text:, location:)` is
  true, delete the two-character empty pair in one `insertText("",
  replacementRange:)` (guarded by the reentrancy flag) and `return true`;
  otherwise `return false` for the default delete. Keep the existing
  `insertNewline(_:)` interception intact.
- [x] `swift build` succeeds; `swift test` (Core suite) still passes.

### Task 3: Verify acceptance criteria

- [x] Run `swift build` — compiles cleanly.
- [x] Run `swift test` — full suite passes.
- [x] Confirm `AutoPairEngineTests` covers each `AutoPairAction` case and
  `shouldDeletePair` true/false paths (coverage of the new pure engine).

### Task 4: Update documentation

- [x] `CLAUDE.md`: add an `AutoPairEngine.swift` bullet under `PisakaCore`
  documenting the `AutoPairAction` model, the can-close / can-close-quote
  heuristics, the empty-pair `shouldDeletePair`, and the heuristic-only (no
  lexer) quote limitation; note the character-input / Backspace interception and
  its coordination with the dedent logic (and the generalized
  `isApplyingProgrammaticEdit` guard) in the `CodeEditorView` bullet.
- [x] `README.md`: add auto-closing brackets and quotes (with type-over,
  wrap-selection, and empty-pair Backspace) to the editor feature list.
