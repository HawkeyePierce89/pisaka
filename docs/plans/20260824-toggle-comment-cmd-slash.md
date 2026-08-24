# Toggle Comment (Cmd+/)

## Overview

Add a Cmd+/ comment toggle to the macOS editor, built as a pure `PisakaCore`
engine plus thin AppKit glue — the same shape as Cmd+D / `DuplicateEngine`.
Two new Core files: a per-language comment-style table (`CommentStyle.swift`,
modelled on `LanguageKeywords`) and the engine (`ToggleCommentEngine.swift`)
that turns (text, selection, language) into one replacement range + replacement
string + resulting selection. The app layer reads the live buffer and the
language the coordinator already tracks, applies the edit with a single
`insertText(_:replacementRange:)` (one undo step, ordinary edit for overlays /
diagnostics shift / LSP sync), and exposes the command as an Edit-menu item
routed through the first responder.

## Context

- Files involved:
  - Create: `Sources/PisakaCore/CommentStyle.swift`,
    `Sources/PisakaCore/ToggleCommentEngine.swift`
  - Create: `Tests/PisakaCoreTests/CommentStyleTests.swift`,
    `Tests/PisakaCoreTests/ToggleCommentEngineTests.swift`
  - Modify: `Sources/Pisaka/CodeEditorView.swift` (coordinator handler,
    `EditorTextView` hook, `makeNSView` wiring)
  - Modify: `Sources/Pisaka/PisakaApp.swift` (Edit-menu item +
    first-responder routing)
  - Modify: `docs/architecture/core-editor.md`, `CLAUDE.md`, `README.md`,
    `docs/FEATURES.md`
- Related patterns:
  - `DuplicateEngine.swift` / `DuplicateEngineTests.swift` — engine value type
    + `NSString`/UTF-16 arithmetic;
    `getLineStart(_:end:contentsEnd:for:)` for the editor-wide separator set
    (LF/CR/CRLF/NEL/LS/PS).
  - `LanguageKeywords.swift` + `LanguageKeywordsTests` — per-language table
    with an explicit "this language has none" set, closed by set equality
    against `SyntaxLanguage.allCases`.
  - `CodeEditorView.swift:1795 duplicateSelection(in:)` — reads buffer +
    selection, brackets the edit with `isApplyingProgrammaticEdit`, applies one
    `insertText`, sets the selection. `coordinator.language` (line 782) already
    holds the attached `SyntaxLanguage?`.
  - `CodeEditorView.swift:2562 goToDefinitionAtCaret()` +
    `PisakaApp.swift:2273 goToDefinitionAtCaret()` — the menu-item →
    first-responder → `EditorTextView` hop, beeping via
    `PlatformFeedback.warning()` when the focused view is not an editor.
- Dependencies: none new. Core stays Foundation-only.

## Design decisions made from the ticket

These are the readings the ticket leaves open; they are decided here so
implementation has no forks:

1. **Comment-style table** — `public enum CommentStyle: Equatable { case
   line(String); case block(open: String, close: String) }`, plus
   `CommentStyle.style(for: SyntaxLanguage) -> CommentStyle?` and
   `public static let languagesWithoutComments: Set<SyntaxLanguage> = [.json,
   .markdown]` (the `languagesWithoutKeywords` shape). The test asserts
   `styled ∪ languagesWithoutComments == Set(SyntaxLanguage.allCases)` and that
   the two sets are disjoint, so a new language fails `swift test` until someone
   decides which it is.
2. **Engine API** — `public struct CommentToggleEdit: Equatable {
   replacementRange: NSRange; text: String; selectedRange: NSRange }` and
   `public enum ToggleCommentEngine { static func toggle(text: NSString,
   selectedRange: NSRange, language: SyntaxLanguage?) -> CommentToggleEdit? }`.
   `nil` means "do nothing, silently": no language, a no-comment language, or a
   wholly blank target. `selectedRange` is in post-edit coordinates. The
   selection is clamped to the buffer bounds first, as `DuplicateEngine` does,
   so an out-of-range or `NSNotFound` range cannot trap.
3. **Touched lines** — the whole-line span from the first touched line's start
   to the last touched line's end. A selection of length > 0 whose end sits
   exactly at a line start does *not* touch that line (selecting whole lines
   including the trailing newline comments the lines you see selected, not one
   more).
4. **A blank caret line is a complete no-op — the caret does not move.** The
   ticket states blank lines are skipped in both directions for line mode and
   that a wholly blank block target is a no-op; the caret case follows the same
   rule, so `toggle` returns `nil`, and `nil` means the app layer does nothing
   at all — no text change and no caret move. (Some mainstream editors instead
   insert a marker on an empty line; here the complete no-op is the deliberate
   choice, and it is the one place the ticket's stated rule departs from that
   common behavior.)
5. **Caret placement, no-selection case** (both modes) — if a following line
   exists, the caret lands at that line's start plus `min(originalColumn,
   thatLine'sContentLength)` in post-edit coordinates; on the last line it stays
   on its own line at `originalColumn + delta`, clamped to
   `[0, newContentLength]`, where `delta` is the token length inserted or
   removed before it, so the caret keeps its position relative to the text.
6. **Selection placement, selection case** — the post-edit whole-line span of
   the touched lines: from the first touched line's start to the last touched
   line's contents end (its terminator excluded).
7. **Line mode** — insert at column 0 with no space after; remove one token
   plus at most one immediately following space, allowing any leading whitespace
   before the token. The all-commented test runs over non-blank touched lines
   only; no non-blank line at all → `nil`.
8. **Block mode** — "first/last touched line" is normalized to "first/last
   **non-blank** touched line" for both the wrap and the unwrap test (a blank
   line has no non-whitespace character to insert before). Wrap inserts the bare
   delimiters with no added inner spaces, matching the line-token rule: the
   opener before the first non-blank line's first non-whitespace character, the
   closer at the end of the last non-blank line's contents. Unwrap tolerates one
   space inside each delimiter and any trailing whitespace after the closer, so
   a wrap/unwrap round-trips and files delimited elsewhere do too. Delimiters
   already inside the target are left exactly as they are.
9. **Menu placement** — `CommandGroup(after: .pasteboard)` puts "Toggle
   Comment" in the stock Edit menu; the item is disabled with no tab open.
   Consequence, accepted: a menu key equivalent is claimed app-wide, so Cmd+/ is
   taken from the embedded terminal and the project tree — with either focused,
   the command beeps (the `goToDefinitionAtCaret()` precedent) rather than
   editing. A language with no comment style is the ticket's *silent* no-op and
   does not beep.

## Development Approach

- **Testing approach**: Regular (code first, then tests) — each Core task
  writes its tests before the task is considered done and `swift test` must be
  green before the next task starts.
- All decisions live in Core and are unit-tested; the macOS glue stays thin and
  untested, per the repo's pure-engine + thin-glue invariant.
- Doc comments carry the reasoning (the house style);
  `docs/architecture/core-editor.md` is updated in the same change as the
  behavior.
- **CRITICAL: every task ships new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**

## Implementation Steps

### Task 1: The per-language comment-style table

**Files:**
- Create: `Sources/PisakaCore/CommentStyle.swift`
- Create: `Tests/PisakaCoreTests/CommentStyleTests.swift`

- [x] Add `public enum CommentStyle: Equatable` with `case line(String)` and
      `case block(open: String, close: String)`, doc-commented in the house
      style (why one style per language, why the absence is recorded
      explicitly).
- [x] Add `public static func style(for language: SyntaxLanguage) ->
      CommentStyle?` covering the switch exhaustively: `//` for
      swift/javascript/typescript/go/rust, `#` for
      python/yaml/dockerfile/dotenv/gitignore, `--` for sql, `/* */` for css,
      `<!-- -->` for html, `nil` for json/markdown.
- [x] Add `public static let languagesWithoutComments: Set<SyntaxLanguage> =
      [.json, .markdown]` with the stated reason (no comment syntax to toggle),
      mirroring `LanguageKeywords.languagesWithoutKeywords`.
- [x] Write `CommentStyleTests`: set-equality closure over
      `SyntaxLanguage.allCases` (styled ∪ without == allCases, and the two
      disjoint), the exact token/pair for every language, and that no token or
      delimiter is empty.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: The engine — line-comment mode

**Files:**
- Create: `Sources/PisakaCore/ToggleCommentEngine.swift`
- Create: `Tests/PisakaCoreTests/ToggleCommentEngineTests.swift`

- [x] Add `public struct CommentToggleEdit: Equatable { replacementRange, text,
      selectedRange }` and `public enum ToggleCommentEngine` with
      `toggle(text:selectedRange:language:)` returning `CommentToggleEdit?`,
      doc-commented with the whole contract (including that `nil` is the silent
      no-op and means no edit *and* no caret move).
- [x] Implement the shared front half: clamp the selection to the buffer,
      resolve the style (return `nil` for a `nil` language or a no-comment
      language), compute the touched whole-line span with
      `getLineStart(_:end:contentsEnd:for:)` — including the "selection ending
      at a line start does not touch that line" rule — and split the span into
      lines carrying their own verbatim terminators.
- [x] Implement line mode: skip blank/whitespace-only lines in both directions;
      if every non-blank touched line begins after leading whitespace with the
      token, remove one token plus at most one following space per line,
      otherwise insert the token at column 0 of every non-blank line; return
      `nil` when no non-blank line exists.
- [x] Implement the resulting selection/caret per decisions 5 and 6 above
      (caret to the following line preserving column, clamped; on the last line
      the caret stays, shifted by the token delta; a selection becomes the
      touched lines' post-edit whole-line span).
- [x] Write `ToggleCommentEngineTests` for line mode: caret on an uncommented
      and on an already-commented line; caret column preservation and the
      last-line case; selection over uncommented, fully commented and mixed
      lines; blank lines inside a selection; first and last line of the
      document; a selection ending exactly at a line start; CRLF, CR, NEL,
      U+2028/U+2029 buffers; indented tokens; both `//x` and `// x` removal
      spellings; `#` and `--` languages; empty document; a blank caret line
      (asserting `nil` — no edit and no caret move); json/markdown; `nil`
      language; an out-of-range/`NSNotFound` selection.
- [x] Run `swift test` — must pass before Task 3.

### Task 3: The engine — block-comment mode

**Files:**
- Modify: `Sources/PisakaCore/ToggleCommentEngine.swift`
- Modify: `Tests/PisakaCoreTests/ToggleCommentEngineTests.swift`

- [x] Implement block mode over the same touched-line span: unwrap when the
      first non-blank line begins after leading whitespace with the opener and
      the last non-blank line ends before trailing whitespace with the closer
      (removing one pair plus at most one space inside each delimiter);
      otherwise wrap, inserting the bare opener before the first non-blank
      line's first non-whitespace character and the bare closer at the end of
      the last non-blank line's contents.
- [x] Return `nil` for a wholly blank target; reuse the same caret/selection
      placement rules as line mode.
- [x] Extend the tests: CSS and HTML wrap and unwrap of a single caret line and
      of a multi-line selection; an indented opener; `/*x*/` and `/* x */`
      removal spellings; trailing whitespace after the closer; a target that
      already contains a delimiter inside it (wrapped verbatim, nothing escaped
      or rebalanced); blank lines at the edges of the selection; a wholly blank
      target (asserting `nil`); caret advance after a single-line wrap; a
      wrap→unwrap round-trip restoring the original text exactly.
- [x] Run `swift test` — must pass before Task 4.

### Task 4: macOS wiring

**Files:**
- Modify: `Sources/Pisaka/CodeEditorView.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] Add `Coordinator.toggleComment(in textView: NSTextView)`: read the live
      buffer, selection and `self.language`, call the engine, return silently on
      `nil` (no text change, no caret move), otherwise apply the edit with one
      `insertText(_:replacementRange:)` bracketed by
      `isApplyingProgrammaticEdit` (mandatory, not defensive — a one-character
      replacement would otherwise fall into the auto-pair interceptor), then
      install `edit.selectedRange`.
- [x] Add `EditorTextView.onToggleComment: ((NSTextView) -> Void)?` and
      `func toggleCommentAtSelection()` forwarding to it, mirroring
      `onGoToDefinition` / `goToDefinitionAtCaret()`, and wire it in
      `makeNSView` with the weak-coordinator capture the file's retain-cycle
      rule requires.
- [x] Add the Edit-menu item in `PisakaApp.swift`: `CommandGroup(after:
      .pasteboard)` with a "Toggle Comment" button, `.keyboardShortcut("/",
      modifiers: .command)`, disabled when `model.selectedID == nil`.
- [x] Add the private `toggleCommentAtCaret()` routing through
      `NSApp.keyWindow?.firstResponder as? EditorTextView`, beeping with
      `PlatformFeedback.warning()` otherwise — documenting why this command is
      responder-routed (it carries no state) and that the app-wide key
      equivalent takes Cmd+/ from the terminal and the project tree.
- [x] Build both destinations: `xcodegen generate` if needed, then the macOS and
      iOS `xcodebuild` commands from `CLAUDE.md` — both must succeed (Core must
      stay iOS-clean).

### Task 5: Documentation

**Files:**
- Modify: `docs/architecture/core-editor.md`, `CLAUDE.md`, `README.md`,
  `docs/FEATURES.md`

- [x] Add full entries for `CommentStyle.swift` and `ToggleCommentEngine.swift`
      to `docs/architecture/core-editor.md` in the `DuplicateEngine` style: the
      contract, the separator handling, every decision listed above
      (touched-line rule, blank-line skipping — including that a blank caret
      line is a complete no-op with the caret left where it is, stated as the
      deliberate choice against the common alternative of inserting a marker on
      an empty line, and naming no other product — caret/selection placement,
      both uncomment spellings, block-mode normalization to non-blank edges, no
      delimiter rebalancing), what `nil` means, and the named test suites.
- [x] Add one index line per new file to the `core-editor.md` list in
      `CLAUDE.md` — index only, no essay.
- [x] Add the `Cmd+/` row to the README keyboard-shortcut table and mention the
      toggle in the README feature paragraph beside Cmd+D.
- [x] Add the feature to `docs/FEATURES.md` next to the Cmd+D entry, including
      the CSS/HTML block behavior, the silent no-op for JSON/Markdown and
      unknown file types, the single-undo-step guarantee, and that it is
      macOS-only (no iOS wiring).

### Task 6: Verify acceptance criteria

- [ ] Run `swift test` — the full suite green, including the new
      `CommentStyleTests` and `ToggleCommentEngineTests`.
- [ ] Run `swiftlint --strict` from the repository root — clean, with no new
      in-file disables.
- [ ] Build macOS (`xcodebuild -project Pisaka.xcodeproj -scheme Pisaka
      -destination 'platform=macOS' build`) and iOS Simulator — both succeed.
- [ ] Re-read the doc entries against the shipped code so the architecture doc,
      `CLAUDE.md`, `README.md` and `docs/FEATURES.md` describe the behavior
      actually implemented.

## Post-Completion (manual, by the user)

- In a DEBUG build: Cmd+/ on a Swift line, on a mixed multi-line selection, on a
  CSS rule and an HTML block; confirm one Cmd+Z reverts each toggle whole, and
  that Cmd+/ in a JSON file does nothing without a beep.
