# Editor auto-indent

## Overview

Make pressing Enter in the editor land the cursor at a sensible indent instead of
column 0, and make typing a closing bracket on a whitespace-only line dedent to
its opener. All indent computation is pure and lives in a new `IndentEngine` in
`PisakaCore` (UI-free, unit-tested); `CodeEditorView` adds thin `NSTextView`
interception that translates engine results into edits routed through the per-file
undo manager.

Scope (full variant from brainstorming): (a) inherit the current line's leading
whitespace, (b) add one indent unit after a trailing `{`/`(`/`[`, (c) dedent a
closing `}`/`)`/`]` typed on a whitespace-only line to match its opener. No
language-specific rules, no string/comment awareness, no auto-close, no
configurable indent unit.

## Context

- Files involved:
  - Create: `Sources/PisakaCore/IndentEngine.swift` (pure engine + value types)
  - Create: `Tests/PisakaCoreTests/IndentEngineTests.swift`
  - Modify: `Sources/Pisaka/CodeEditorView.swift` (Enter + closing-bracket
    interception in the `Coordinator`)
  - Modify: `CLAUDE.md`, `README.md`
- Related patterns:
  - Pure Foundation-only engines in Core mirroring `LineStartIndex` / `LineDiff` /
    `MinimapModel`; they take `NSString` + UTF-16 offsets and split lines via
    `LineStartIndex` semantics.
  - Small public `Equatable` value types like `DiffRow` / `IndentReplacement`.
  - Tests use `XCTest`, `@testable import PisakaCore`.
- Dependencies: none new. `PisakaCore` stays Foundation-only; no AppKit/Neon.

## Design notes (resolved)

- `newlineIndentation` returns a small value type `NewlineEdit { text: String;
  cursorOffset: Int }` rather than a bare `String`, so the between-brackets split
  (which inserts two newlines and repositions the cursor on the middle line) and
  the simple case share one return shape. Simple case: `text = "\n" + indent`,
  `cursorOffset = text.count`. Split case (`{|}`): `text = "\n" + base+unit + "\n"
  + base`, `cursorOffset = 1 + (base+unit).utf16 length`, leaving the existing
  closer pushed onto its own line at `base`.
- `dedentOnClosing` returns `IndentReplacement? { range: NSRange; replacement:
  String }` — the current line's leading-whitespace range and the opener line's
  indentation; `nil` when the prefix isn't whitespace-only or no matching opener
  is found.
- Line boundaries are computed with the same Unicode separators as the rest of the
  editor (via `LineStartIndex`), so indent logic agrees with the gutter/minimap.

## Development Approach

- **Testing approach**: Regular (code first, then tests) for each Core task.
- Every Core task ships with new/updated `IndentEngineTests`; the full suite must
  pass before the next task.
- The view-layer wiring (Task 4) carries no unit tests, per the project convention
  that `Pisaka` views are intentionally thin and untested; it relies on the
  engine's tests for correctness.
- **CRITICAL: every Core task MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**

## Implementation Steps

### Task 1: IndentEngine value types + inferIndentUnit

**Files:**
- Create: `Sources/PisakaCore/IndentEngine.swift`
- Create: `Tests/PisakaCoreTests/IndentEngineTests.swift`

- [x] Create `IndentEngine.swift` with `NewlineEdit` and `IndentReplacement`
      (public `Equatable` value types).
- [x] Implement `inferIndentUnit(text: NSString) -> String`: detect tabs vs
      spaces and the smallest indent step observed across lines; fall back to four
      spaces for an empty or unindented file.
- [x] Write tests: tabs; two-space; four-space; empty file → four-space fallback;
      unindented file → four-space fallback.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: newlineIndentation

**Files:**
- Modify: `Sources/PisakaCore/IndentEngine.swift`
- Modify: `Tests/PisakaCoreTests/IndentEngineTests.swift`

- [x] Implement `newlineIndentation(text: NSString, location: Int, unit: String)
      -> NewlineEdit`: base = current line's leading whitespace; +one `unit` when
      the current line (trailing whitespace ignored) ends with `{`/`(`/`[`;
      between-brackets split when the char before `location` is an opener and the
      char after is its matching closer.
- [x] Write tests: inherits the previous line's indent (the `expect(…)` example);
      adds one unit after trailing `{`/`(`/`[`; between-`{}` split (middle line
      indented, closer dedented, `cursorOffset` on the middle line); empty line /
      start of file → empty indent; mixed tabs/spaces inherited verbatim.
- [x] Run `swift test` — must pass before Task 3.

### Task 3: dedentOnClosing

**Files:**
- Modify: `Sources/PisakaCore/IndentEngine.swift`
- Modify: `Tests/PisakaCoreTests/IndentEngineTests.swift`

- [x] Implement `dedentOnClosing(text: NSString, location: Int, closing:
      Character, unit: String) -> IndentReplacement?`: only when the current line
      up to `location` is whitespace-only; scan backward tracking bracket depth to
      find the matching opener; return the leading-whitespace range plus the
      opener line's indentation. `nil` when prefix not whitespace-only or no
      matching opener. Bracket matching counts raw characters (no string/comment
      awareness).
- [x] Write tests: dedents to the opener's indent; nesting picks the correct
      opener; no matching opener → `nil`; cursor not on a whitespace-only prefix
      → `nil`; replacement preserves opener's tabs/spaces style.
- [x] Run `swift test` — must pass before Task 4.

### Task 4: CodeEditorView interception (view wiring)

**Files:**
- Modify: `Sources/Pisaka/CodeEditorView.swift`

- [x] Enter: in `Coordinator.textView(_:doCommandBySelector:)` for
      `insertNewline:`, read `textView.string` + selected range, compute `unit`
      via `inferIndentUnit` and the edit via `newlineIndentation`, insert via
      `insertText(_:replacementRange:)`, set the selected range to `location +
      cursorOffset`, return `true` to suppress the default.
- [x] Closing bracket: in
      `Coordinator.textView(_:shouldChangeTextIn:replacementString:)`, when the
      replacement is a single `}`/`)`/`]` and the line prefix is whitespace-only,
      apply `dedentOnClosing` by rewriting the leading-whitespace range via
      `insertText(_:replacementRange:)` (rewriting the whitespace and the bracket
      together in one undoable edit, returning `false` to suppress the default
      insertion — mutating inside `shouldChangeTextIn` and returning `true` would
      proceed against a now-stale `affectedCharRange`).
- [x] Route all programmatic edits through `insertText(_:replacementRange:)` so
      the per-file undo manager records them as ordinary, single-step-undoable
      edits.
- [x] No new unit tests (view layer is thin and untested by project convention);
      correctness is covered by the engine tests.
- [x] Run `swift build` — must succeed before Task 5.

### Task 5: Verify acceptance criteria

- [x] Run `swift build` — succeeds.
- [x] Run `swift test` — full suite passes.

### Task 6: Update documentation

- [x] `CLAUDE.md`: add an `IndentEngine` bullet under `PisakaCore` (the three
      functions, the `NewlineEdit`/`IndentReplacement` types, the
      raw-bracket-matching limitation, the infer-unit four-space fallback) and
      note the Enter / closing-bracket interception under the `CodeEditorView`
      bullet.
- [x] `README.md`: mention auto-indent (inherit indentation, indent after an
      opening bracket, dedent a closing bracket) in the editor feature list.

## Post-Completion Verification

- [ ] Manually confirm the `expect(…)` example: Enter on the `expect` line lands
      the cursor under `expect`.
- [ ] Manually confirm undo: a single undo reverses an Enter-with-indent in one
      step.

## Out of scope (YAGNI)

- Full reformatting / reindent-region.
- Language-specific rules (`switch`/`case`, statement continuation, `else`).
- String/comment awareness in bracket matching.
- Auto-closing brackets/quotes.
- A configurable indent unit or tabs/spaces setting.
