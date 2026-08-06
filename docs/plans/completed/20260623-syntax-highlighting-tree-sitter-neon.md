# Syntax highlighting (tree-sitter + Neon)

## Overview

Add tree-sitter-based syntax highlighting to the editor via ChimeHQ's Neon, for a
wide initial language set (Swift, JSON, Markdown, JavaScript, TypeScript, Python,
HTML, CSS, YAML). The parsing/theming core is kept portable: pure, UI-free
semantic types live in `PisakaCore` (with tests), while all Neon/AppKit/grammar
wiring lives in the thin `Pisaka` view layer. This introduces the project's first
SPM dependencies.

## Context

- Files involved:
  - Create: `Sources/PisakaCore/SyntaxLanguage.swift`
  - Create: `Sources/PisakaCore/SyntaxTokenKind.swift`
  - Create: `Sources/Pisaka/SyntaxLanguageConfiguration.swift`
  - Create: `Sources/Pisaka/SyntaxTheme.swift` (theme table; kept separate from the editor view)
  - Modify: `Package.swift` (add Neon + grammar dependencies to the `Pisaka` target only)
  - Modify: `Sources/Pisaka/CodeEditorView.swift` (attach/swap Neon `TextViewHighlighter`)
  - Create: `Tests/PisakaCoreTests/SyntaxLanguageTests.swift`
  - Create: `Tests/PisakaCoreTests/SyntaxTokenKindTests.swift`
  - Modify: `CLAUDE.md`, `README.md`
- Related patterns:
  - `FileIcon.swift` — the extension-map + semantic-enum pattern that
    `SyntaxLanguage` and `SyntaxTokenKind` mirror; `FileIconColor` is the
    precedent for keeping color out of Core.
  - `CodeEditorView.swift` — existing `NSViewRepresentable` over `NSTextView` in
    an `NSScrollView`, with a `Coordinator` and per-file undo managers; `fileID`
    change = tab switch.
- Dependencies (new, `Pisaka` target only):
  - `ChimeHQ/Neon` (brings in `SwiftTreeSitter`).
  - One tree-sitter grammar SPM package per language, each shipping
    `highlights.scm` query resources. Exact URLs/versions pinned and verified to
    build in Task 1; languages that fail to build/ship queries are trimmed and
    logged.
  - `PisakaCore` gains NO dependencies and must never import
    Neon/SwiftTreeSitter/AppKit.

## Development Approach

- **Testing approach**: TDD for `PisakaCore` (write
  `SyntaxLanguageTests`/`SyntaxTokenKindTests` first, then implement). The view
  layer (`CodeEditorView`, the language-configuration registry, the theme table)
  is intentionally thin and not unit-tested, per project convention.
- Complete each task fully before moving to the next.
- **CRITICAL: every task that changes `PisakaCore` MUST include new/updated tests.**
- **CRITICAL: `swift test` must pass and `swift build` must succeed before starting the next task.**
- Keep all semantic logic in `PisakaCore`; keep `Pisaka` views thin.

## Implementation Steps

### Task 1: Add and verify SPM dependencies

**Files:**
- Modify: `Package.swift`

- [x] Add `ChimeHQ/Neon` to `dependencies` and to the `Pisaka` executable target only (not `PisakaCore`, not the test target). Pinned to `main` revision `484d6fb` (see note below).
- [x] Add one tree-sitter grammar package per target language (Swift, JSON, Markdown, JavaScript, TypeScript, Python, HTML, CSS, YAML), each to the `Pisaka` target only.
- [x] Pin exact URLs/versions; run `swift build` and confirm SPM resolves and each grammar's C target compiles on macOS, and that each ships `highlights.scm` query resources. Verified all 9 grammars ship `queries/highlights.scm`.
- [x] Trim any grammar that fails to build or lacks query resources from the set; record the dropped languages in the PR/commit notes (do not silently ship fewer). **No languages dropped** — all 9 survive. Two packaging adjustments were required and are documented inline in `Package.swift`: (1) Neon is pinned to a `main` revision rather than tag `0.6.0`, because 0.6.0 predates strict Swift-6 actor isolation and fails to compile against any SwiftTreeSitter the grammars accept under the Swift 6 toolchain; SwiftTreeSitter is pinned to released `0.25.0` (overrides Neon main's `branch: main`, satisfies the grammars' `from:` floor). (2) `tree-sitter-javascript`/`-css`/`-python`/`-yaml` are pinned to their last tags that list `src/scanner.c` literally (js `0.23.1`, css `0.23.2`, python `0.23.6`, yaml `0.7.0`); their newer tags compute sources via a relative-path `FileManager.fileExists` check that drops the external scanner when built as a transitive dependency, breaking the link.
- [x] Confirm `swift build` succeeds with the final dependency set. Clean `swift build` succeeds and `swift test` (58 tests) passes.

### Task 2: PisakaCore — SyntaxLanguage

**Files:**
- Create: `Sources/PisakaCore/SyntaxLanguage.swift`
- Create: `Tests/PisakaCoreTests/SyntaxLanguageTests.swift`

- [x] Write `SyntaxLanguageTests`: each known extension maps to its language; case-insensitive (`.SWIFT` == `.swift`); unknown/no extension → `nil`; `init?(forFileName:)` derives the extension from a file name.
- [x] Implement `SyntaxLanguage` enum (`String`, `CaseIterable`, `Equatable`) with `init?(fileExtension:)` and `init?(forFileName:)`, backed by a lowercased extension→language map (`swift→.swift`, `js/jsx/mjs/cjs→.javascript`, `ts/tsx→.typescript`, `json→.json`, `md/markdown→.markdown`, `py→.python`, `html/htm→.html`, `css→.css`, `yml/yaml→.yaml`), mirroring `FileIcon`'s extension-map pattern.
- [x] If any language was dropped in Task 1, keep only the supported cases. (No languages dropped in Task 1 — all 9 kept.)
- [x] Run `swift test` — must pass before Task 3. (65 tests pass.)

### Task 3: PisakaCore — SyntaxTokenKind

**Files:**
- Create: `Sources/PisakaCore/SyntaxTokenKind.swift`
- Create: `Tests/PisakaCoreTests/SyntaxTokenKindTests.swift`

- [x] Write `SyntaxTokenKindTests`: plain capture names map to their kind; dotted names resolve by longest known prefix (`keyword.control` → `.keyword`, `punctuation.bracket` → `.punctuation`); unknown capture name → `.plain`.
- [x] Implement `SyntaxTokenKind` (`Equatable`) with cases keyword, string, comment, number, type, function, variable, constant, `operator`, punctuation, property, parameter, label, plain, and `init(captureName:)` that splits the dotted name and matches the longest known prefix against a name→kind table; no match → `.plain`. No color in Core (semantic only, like `FileIconColor`).
- [x] Run `swift test` — must pass before Task 4. (70 tests pass.)

### Task 4: Pisaka — language-configuration registry and theme

**Files:**
- Create: `Sources/Pisaka/SyntaxLanguageConfiguration.swift`
- Create: `Sources/Pisaka/SyntaxTheme.swift`

- [x] Implement a registry mapping `SyntaxLanguage` → Neon `LanguageConfiguration` (loading each grammar + its bundled queries). Only include languages that survived Task 1. (`SyntaxLanguageConfiguration.swift` — all 9 languages; lazy-cached, returns `nil` on load failure. Added `SwiftTreeSitter` product to the `Pisaka` target so `LanguageConfiguration`/`Language` can be imported directly.)
- [x] Implement `SyntaxTheme`: a `SyntaxTokenKind → Color` table with light/dark variants following the system appearance (built-in single theme; not user-configurable). (`SyntaxTheme.swift` — dynamic `NSColor` per kind resolved by effective appearance; exposes `color(for:)` and `nsColor(for:)` for the Task 5 attribute provider.)
- [x] Confirm `swift build` succeeds. (Clean build succeeds; `swift test` still passes — 70 tests.)

### Task 5: Pisaka — wire the highlighter into CodeEditorView

**Files:**
- Modify: `Sources/Pisaka/CodeEditorView.swift`

- [x] Adapt the `NSTextView`/`NSScrollView` setup as needed for TextKit compatibility with the chosen Neon `TextViewHighlighter` variant (TextKit 1 vs 2). (Build the text view explicitly as TextKit 1 via `NSTextView(usingTextLayoutManager: false)` in a manually-assembled `NSScrollView`, matching Neon's example, with non-contiguous layout enabled.)
- [x] Derive the active `SyntaxLanguage` from the selected file's name via `SyntaxLanguage(forFileName:)` (using existing model state — `selectedID`, `OpenFile.url`; add model API only if wiring proves it necessary). (Passed `file.displayName` as a new `fileName` parameter to `CodeEditorView` from `ContentView`; no model API needed.)
- [x] Attach a Neon `TextViewHighlighter` with the resolved `LanguageConfiguration`; rebuild/swap the configuration when the selected file (`fileID`) changes. (Coordinator owns the highlighter; `updateHighlighter` rebuilds on language change and re-invalidates on same-language content swaps.)
- [x] Implement the attribute provider: Neon capture name → `SyntaxTokenKind(captureName:)` (Core) → `SyntaxTheme` `Color` (resolved for light/dark) → `[.foregroundColor: …]`. (Uses `SyntaxTheme.shared.nsColor(for:)` — appearance-aware dynamic `NSColor`.)
- [x] When no language is detected (untitled or unknown extension), show plain text with no highlighter attached. (`rebuildHighlighter` detaches the storage delegate and leaves `highlighter == nil`.)
- [x] Confirm `swift build` succeeds. (Clean build succeeds; `swift test` still passes — 70 tests.)

### Task 6: Verify acceptance criteria

- [x] Run `swift build` — must succeed. (Clean build complete.)
- [x] Run `swift test` — full suite must pass. (70 tests pass.)
- [x] Confirm `PisakaCore` has no Neon/SwiftTreeSitter/AppKit imports (grep the target). (Grep confirms no forbidden imports.)
- [x] Confirm the final supported-language set matches what's documented and what builds. (All 9 languages — swift, javascript, typescript, json, markdown, python, html, css, yaml — consistent across `SyntaxLanguage`, the registry, and the grammar deps.)

### Task 7: Update documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [x] Update `CLAUDE.md`: relax the "Apple SDK only / no external dependencies" rule, noting the Neon/tree-sitter dependencies and why they are confined to the `Pisaka` target; document the new `PisakaCore` files (`SyntaxLanguage`, `SyntaxTokenKind`) and the highlighting wiring in `CodeEditorView` (registry + theme). (Conventions rule rewritten to confine deps to the `Pisaka` target; `SyntaxLanguage`/`SyntaxTokenKind` documented under `PisakaCore`; `CodeEditorView`, `SyntaxLanguageConfiguration`, and `SyntaxTheme` documented under `Pisaka`.)
- [x] Update `README.md` feature list to mention syntax highlighting and the final supported languages. (Added a syntax-highlighting feature bullet listing all 9 languages; removed "No syntax highlighting" from the limitations.)

## Post-Completion (manual verification, not agent-automatable)

- Launch `swift run Pisaka`, open files of each supported type, and visually
  confirm highlighting in both light and dark appearance, including switching
  between tabs of different languages and editing (incremental re-highlight).

## Risks (carried from the request)

- Grammar SPM packaging is inconsistent — some grammars may not build on macOS or
  may omit query resources; mitigated by Task 1 verification + trimming + logging
  dropped languages.
- First external dependencies — slower builds (C grammar targets); SPM resolution
  must work in the build environment.
- TextKit 1 vs 2 compatibility for the chosen Neon highlighter — handled in Task 5.
- UTF-16/byte-offset mismatches across Swift strings, `NSTextView`, and
  tree-sitter — Neon manages this, provided the editor feeds consistent text/edit
  info.

## Out of scope (YAGNI)

- iPad/iPhone support (core kept portable now; no iOS work here).
- User-configurable themes or per-token color settings.
- LSP/semantic tokens, code folding, bracket matching, indentation guides.
