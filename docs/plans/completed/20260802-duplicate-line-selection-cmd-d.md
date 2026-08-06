# Duplicate Line / Selection in the Editor (Cmd+D)

## Overview
JetBrains Cmd+D semantics in the macOS editor: with no selection the caret's logical line is duplicated (the copy goes below, the caret moves into the copy at the same column); with a selection the selected span is duplicated character-wise (the copy is inserted right after the selection and becomes the new selection). All logic is a pure Foundation `DuplicateEngine` in `PisakaCore`; the view only intercepts the key and applies one programmatic edit (a single undo step).

## Context
  - Files involved:
  - Create: `Sources/PisakaCore/DuplicateEngine.swift`
  - Create: `Tests/PisakaCoreTests/DuplicateEngineTests.swift`
  - Modify: `Sources/Pisaka/CodeEditorView.swift` (`EditorTextView`, `Coordinator`, `makeNSView`)
  - Modify: `CLAUDE.md`, `README.md`
  - Related patterns:
  - `Sources/PisakaCore/IndentEngine.swift` / `AutoPairEngine.swift` — the model for a pure engine over `NSString` + UTF-16 offsets returning a value type describing "what to insert and where"; all the math lives in Core, the view stays thin.
  - `Sources/PisakaCore/LineStartIndex.swift` — the Unicode separator semantics (LF, CR, the CRLF pair as one separator, NEL, U+2028, U+2029). For line boundaries the engine uses `NSString.getLineStart(_:end:contentsEnd:for:)`, which follows the same rules and correctly reports the terminator length (2 for CRLF).
  - `Sources/Pisaka/CodeFontScroll.swift` + `EditorTextView.scrollWheel` — the precedent for intercepting an event on the editor `NSTextView` subclass through a callback installed in `makeNSView`.
  - `Coordinator.isApplyingProgrammaticEdit` (`CodeEditorView.swift:310`) — the existing programmatic-edit discipline: `insertText(_:replacementRange:)` synchronously re-invokes `shouldChangeTextIn`, so the flag is mandatory (otherwise duplicating a lone `(` would fall into auto-pair and insert `()`).
  - Dependencies: none new. Core stays Foundation-only.

## Development Approach
  - **Testing approach**: TDD — `DuplicateEngineTests` are written before the engine and must fail for the expected reason (missing symbol / wrong expectations), then implemented to green.
  - The view layer (`CodeEditorView`) is deliberately untested — the repo convention (all logic in Core); its gate is green macOS and iOS builds.
  - Each task ends with a fully green `swift test` before moving to the next.
  - No new abstractions: one engine file, one value type, one public function.

## Design decisions (to be captured in doc comments)
  - **Caret (empty selection)**: line boundaries come from `getLineStart:end:contentsEnd:for:`; `end - contentsEnd` is the terminator length (0, 1, or 2 for CRLF).
  - Terminator present: `insertionLocation = end`, `text` = the whole line including its terminator, new caret = `end + (caret - lineStart)` (the column is preserved as a UTF-16 offset from the line start, and the copy has the same length — so overrunning it is impossible).
  - No terminator (last line / empty buffer): `insertionLocation = end`, `text = "\n" + line contents`, caret = `end + 1 + (caret - lineStart)`.
  - In a CR/CRLF-delimited file the trailing insertion uses a plain `"\n"` (a deliberate simplification per the spec; a line *with* a terminator copies its own terminator verbatim, including the CRLF pair).
  - Empty buffer: `insertionLocation = 0`, `text = "\n"`, caret `(1, 0)` — as in JetBrains (an empty line is added).
  - **Non-empty selection**: `insertionLocation = NSMaxRange(sel)`, `text` = the selected substring, new selection = `NSRange(location: NSMaxRange(sel), length: sel.length)` — the **copy** is selected, so repeated Cmd+D grows the text (`[ab]` → `ab[ab]` → `abab[ab]`).
  - **Multi-line selection** is duplicated character-wise (as is), not line-wise — JetBrains semantics.
  - **Surrogate pairs**: the engine neither splits nor "expands" ranges — it only clamps `selectedRange` to the buffer bounds; a valid range (with the pair wholly inside the selection) is copied correctly. Expanding to a composed character sequence is deliberately not done (it would change selection semantics; the text view never hands over split ranges).
  - **Clamping**: an invalid `selectedRange` (location/length out of bounds) is coerced to a valid one so the engine can never trap.
  - **The CRLF off-by-one boundary** (pinned by an explicit test, see Task 1): with the caret exactly at `contentsEnd` — the end of the *visible* line, immediately before `\r\n` — the column offset `caret - lineStart` still counts UTF-16 units, so `end + (caret - lineStart)` lands at the same place inside the copy, i.e. right before the copy's own `\r\n` and never inside the pair or past it. Concretely, for `"ab\r\ncd\r\n"` with the caret at 2: `lineStart = 0`, `contentsEnd = 2`, `end = 4` → `insertionLocation = 4`, `text = "ab\r\n"`, caret `= 6`, so the buffer becomes `"ab\r\nab\r\ncd\r\n"` and the caret sits between the copy's `b` and its `\r`.

## Implementation Steps

### Task 1: Core — DuplicateEngine (TDD)
**Files:**
  - Create: `Tests/PisakaCoreTests/DuplicateEngineTests.swift`
  - Create: `Sources/PisakaCore/DuplicateEngine.swift`
  - [x] write `DuplicateEngineTests` **before** the engine code, covering: caret mid-line (copy below, same column); caret on the first line; caret on the last line with and without a trailing `\n`; an empty line in the middle; a trailing empty line; an empty buffer; a CRLF file (terminator copied as a pair, caret column correct) and the last CRLF line without a terminator; a CR separator; a U+2028 (LS) separator; a non-empty selection inside a single line (copy is selected); re-applying the result (growth `ab` → `ab[ab]` → `abab[ab]`); a multi-line selection (character-wise); a selection reaching the end of the buffer; a selection with a surrogate pair at its boundary; clamping of a deliberately invalid `selectedRange`
  - [x] add a dedicated CRLF boundary test pinning the caret **exactly at `contentsEnd`** (the end of the visible line, immediately before `\r\n`) — the spot where an off-by-one is most likely: for `"ab\r\ncd\r\n"` with `selectedRange = NSRange(location: 2, length: 0)` assert the full `DuplicateEdit` explicitly (`insertionLocation == 4`, `text == "ab\r\n"`, `selectedRange == NSRange(location: 6, length: 0)`), plus the resulting buffer `"ab\r\nab\r\ncd\r\n"` with the caret between the copy's `b` and its `\r` (i.e. neither inside the CRLF pair nor after it); add the same assertion for the caret at `contentsEnd` of the **last** CRLF line without a trailing terminator
  - [x] run `swift test` and confirm the new tests fail for the expected reason (no `DuplicateEngine`) while the rest of the suite is green
  - [x] implement `public struct DuplicateEdit: Equatable` (`insertionLocation: Int`, `text: String`, `selectedRange: NSRange`, public `init`) with a doc comment in the `NewlineEdit` style
  - [x] implement `public enum DuplicateEngine { public static func duplicate(text: NSString, selectedRange: NSRange) -> DuplicateEdit }` per the Design decisions section (Foundation-only, line boundaries via `getLineStart(_:end:contentsEnd:for:)`, no AppKit/UIKit imports)
  - [x] run `swift test` — the whole suite (including `CrossPlatformAuditTests`) must be green

### Task 2: View — Cmd+D interception in the editor (macOS)
**Files:**
  - Modify: `Sources/Pisaka/CodeEditorView.swift`
  - [x] add a `duplicateSelection(in textView: NSTextView) -> Bool` method to `Coordinator`: it reads `textView.string`/`selectedRange()`, calls `DuplicateEngine.duplicate`, applies the result with a single `insertText(edit.text, replacementRange: NSRange(location: edit.insertionLocation, length: 0))` under `isApplyingProgrammaticEdit` (one undo step; the flag is mandatory — otherwise a single-character copy would re-enter `shouldChangeTextIn` and hit auto-pair), then `setSelectedRange(edit.selectedRange)`
  - [x] add a callback property `var onDuplicate: ((NSTextView) -> Bool)?` to `EditorTextView` (modeled on `onStepFontSize`) and `override func performKeyEquivalent(with event: NSEvent) -> Bool`: it fires only on a "clean" Cmd+D — `charactersIgnoringModifiers?.lowercased() == "d"` and `modifierFlags.intersection([.command, .shift, .option, .control]) == [.command]` — and only when the view is editable and is its window's firstResponder (`performKeyEquivalent` is dispatched across the whole window tree, so without this check Cmd+D would fire while focus is in the terminal / project tree); in every other case return `super.performKeyEquivalent(with:)`, so Cmd+Shift+D and other combinations are not swallowed
  - [x] in `makeNSView`, wire `textView.onDuplicate = { [weak coordinator = context.coordinator] tv in coordinator?.duplicateSelection(in: tv) ?? false }` next to `textView.onStepFontSize` — the capture must be `weak`: the coordinator holds the text view weakly, but Neon's `TextViewHighlighter` (owned strongly by the coordinator) keeps a strong `textView`, so a strong capture closes a retain cycle
  - [x] leave the read-only views (`DiffView`/`MergeView`) untouched
  - [x] run `swift test` (must stay green) and build macOS: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build` (running `xcodegen generate` first if needed)

### Task 3: Documentation
**Files:**
  - Modify: `CLAUDE.md`
  - Modify: `README.md`
  - [x] CLAUDE.md: add `DuplicateEngine.swift` to the `PisakaCore` file list (after `DisplayPath.swift`, keeping the block's ordering) with its API and semantics (caret/selection, terminators including the CRLF-at-`contentsEnd` boundary, JetBrains behavior, "the copy is selected")
  - [x] CLAUDE.md: extend the `CodeEditorView.swift` description with the wiring — Cmd+D interception in `EditorTextView.performKeyEquivalent` (clean Cmd+D only, firstResponder only), applied as a single `insertText(_:replacementRange:)` under `isApplyingProgrammaticEdit` (one undo step), then `setSelectedRange`
  - [x] README.md: add the row `| Cmd+D | Duplicate the current line (or the selection) |` to the "Keyboard Shortcuts (macOS)" table and mention it in the editor feature list
  - [x] record the follow-ups (as "out of scope" in CLAUDE.md/README): the iOS variant via `UIKeyCommand` for an external keyboard on the same Core engine, and an Edit → Duplicate Line menu item
  - [x] run `swift test` — green

### Task 4: Verify acceptance criteria
  - [x] `swift test` — whole suite green (906 tests, 0 failures)
  - [x] `xcodegen generate` + `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build` — BUILD SUCCEEDED
  - [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build` — BUILD SUCCEEDED (unsigned, `CODE_SIGNING_ALLOWED=NO`, as in CI)
  - [x] verify `Sources/PisakaCore/DuplicateEngine.swift` imports nothing but Foundation and that the new tests cover every case listed in Task 1 (including the CRLF caret-at-`contentsEnd` boundary)

## Post-Completion (manual verification, macOS)
  - Cmd+D on a line with no selection: the copy appears below, the caret sits in the copy at the same column.
  - Cmd+D with a selection: the copy is inserted right after the selection and is itself selected; repeated presses grow the text.
  - A single Cmd+Z undoes one whole duplication.
  - Cmd+Shift+D does nothing; Cmd+D with focus in the terminal / project tree does not duplicate.
