# Editor selection: identifier-aware double-click, occurrence and tag highlighting, TSX parsing, structural selection

## Overview

Three defects in the macOS code editor, plus the selection and highlighting features that belong with them:

- **R1.** Double-click selects exactly one identifier. The boundary rule is the one `IdentifierScanner` already states, now language-aware: in the JavaScript family `$` and `#` are word characters.
- **R2.** The identifier at the caret highlights all its occurrences. The source is `textDocument/documentHighlight` when the file's server offers it, otherwise a budgeted textual scan. The two answers are never mixed and failure is silent.
- **R3.** A one-line selection highlights its other exact matches, capped at 50.
- **R4.** `.tsx` files get their own language case and are parsed with the TSX grammar.
- **R5.** JSX (`.jsx`/`.js`/`.tsx`) and HTML get a matching-tag highlight.
- **R6.** Expand / Shrink Selection walks the syntax tree, with a text-only fallback.
- **R7.** The four new colours are code-zone colours in `SyntaxTheme`.

All decisions are made in `PisakaCore` and tested in `swift test`. The app layer only schedules, reads tree ranges and paints through `BracketOverlayLayoutManager`. Every highlight is a reader: no undo entry, no dirty flag, no path to the save funnel.

## Context

- **Core, modified:**
  - `IdentifierScanner.swift`, `TextualUsageScanner.swift`
  - `SyntaxLanguage.swift`, `CommentStyle.swift`, `FileGlyph.swift`, `FileIcon.swift`, `LanguageKeywords.swift`, `SyntaxContextVocabulary.swift`, `CaretReadout.swift`, `SymbolIndexModel.swift`
  - `LSPServerDescription.swift`, `LSPProvisioningManifest.swift`, `LSPProtocolTypes.swift`, `LSPSession.swift`, `LSPIntelligenceProvider.swift`
  - `CodeIntelligence.swift`, `RoutingIntelligenceProvider.swift`, `SymbolIntelligenceProvider.swift`, `BracketMatchEngine.swift`
- **Core, new:** `WordSelectionRule.swift`, `OccurrenceScan.swift`, `OccurrenceHighlightRule.swift`, `DocumentHighlight.swift`, `OccurrenceHighlightModel.swift`, `TagMatchRule.swift`, `SelectionExpansionRule.swift`
- **App, modified (macOS):** `CodeEditorView.swift` (`EditorTextView` + `Coordinator`), `BracketOverlayLayoutManager.swift`, `BracketHighlightController.swift`, `SyntaxTheme.swift`, `SyntaxLanguageConfiguration.swift`, `CompletionController.swift`, `HoverController.swift`, `PisakaApp.swift`
- **App, new (macOS):** `OccurrenceHighlightController.swift`, `SyntaxTreeSnapshot.swift`, `TagHighlightController.swift`, `SelectionCommands.swift`
- **Resources:** `Resources/Queries/tsx/symbols.scm`
- **Tests:**
  - Core: `Tests/PisakaCoreTests/` (new suites, plus updates to `SymbolQueryTests`, `LanguageKeywordsTests`, `SyntaxLanguageTests`, `MenuShortcutUniquenessTests`, the LSP suites)
  - App: new suites in `Tests/PisakaAppTests/`, beside `BracketPairBackgroundTests` and `MakeSymbolQueryTests`
- **Docs:** `docs/FEATURES.md`; `docs/architecture/core-editor.md`, `core-intelligence.md`, `core-lsp.md`, `app-editor.md`, `app-editor-overlays.md`; `CLAUDE.md` index
- **Patterns to follow:**
  - the LSP-or-scanner routing with one whole answer, as `RoutingIntelligenceProvider.foldRegions` does it;
  - the double-entry `record`/`spend` work bookkeeping in `EditorConfigGlob.MatchWork`;
  - layered background temporary attributes in `BracketOverlayLayoutManager`;
  - the visible-slice push in `EditorSearchController`;
  - a self-contained `Commands` type joined into the existing `Group { FoldCommands(); TabNavigationCommands(…) }`;
  - grammar loading in `SymbolExtractor`/`MinimapTokenizer` (a private `Parser` per parse).
- **Dependencies:** none new. The TSX grammar is the `TreeSitterTSX` target, which the already-linked `TreeSitterTypeScript` product ships; its resource bundle is `TreeSitterTypeScript_TreeSitterTSX`. The JavaScript bundle ships `highlights-jsx.scm`. No new licence entry is needed: same package, same licence.

## Development Approach

- **Testing approach:** Regular (code first, then tests in the same task).
- Complete each task fully before moving on.
- Before touching any file, read its entry in `docs/architecture/`.
- Async ordering uses generation tokens captured before the hop. Races are staged with `Gate`/`waitFor`, never timed waits. Performance bounds are charged, never timed.
- Run gates under the pinned Xcode: `make test`, `make test-app`, `make lint`, `make build`. `make build-ios` belongs to CI.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Language-aware boundary rule and the word-selection rule (Core)

**Files:**
- Modify: `Sources/PisakaCore/IdentifierScanner.swift`
- Create: `Sources/PisakaCore/WordSelectionRule.swift`
- Modify: `Sources/PisakaCore/SyntaxLanguage.swift`
- Create/modify: `Tests/PisakaCoreTests/IdentifierScannerTests.swift`, `Tests/PisakaCoreTests/WordSelectionRuleTests.swift`

- [x] Add `SyntaxLanguage.extraWordScalars` (or an equivalent small enum):
  - `$` and `#` for `.javascript`, `.typescript` and (after Task 3) `.tsx`;
  - empty for every other language.
- [x] Give every `IdentifierScanner` entry point an optional `language: SyntaxLanguage? = nil` parameter: `isIdentifierStart`/`Continuation`, `isIdentifier`, `identifier(in:at:)`, `completionPrefixRange`, `completionReplaceRange`, `words`, `memberContext`.
  - The extra scalars count as both start and continuation. This stays the one statement of the rule.
  - `nil` keeps today's set exactly, so iOS call sites stay untouched; that is a stated limit.
- [x] Add `IdentifierScanner.identifier(in:containing:language:)`. It is only the first probe: the identifier containing the character at the offset, with no "ending at" fallback. A click on `.` right after `z` must not select `z`.
- [x] Create `WordSelectionRule.range(proposed:platformRange:text:language:) -> NSRange`, the word-granularity answer.
  - A click (empty or one-character proposal) on an identifier character returns that identifier.
  - On a drag, each end that lies in an identifier snaps to that identifier's bounds. An end that does not keeps the platform's bound.
  - When neither end is in an identifier, it returns `platformRange` unchanged, which is AppKit's behaviour.
- [x] Thread `language:` through `TextualUsageScanner.matches` (`isWholeWord`) and the scanner calls in `SymbolIntelligenceProvider` (harvest + candidate filter), `LSPIntelligenceProvider` and `FindUsagesModel`/`RenameEditPlan`, using the language each already holds.
- [x] Tests:
  - periods, `?.`, `::`, `->`, `_`, digits/trim, Unicode letters, combining marks;
  - `$store`, `c$d` and `#privateField` as one word in JS/TS but split in Swift;
  - the `friendListSchema` sample (`z`, `object`, `array`, `string`, `default` each alone) and `res.status`, `Date.now()`;
  - completion prefix/replace ranges over `$`/`#` in JS/TS, and shell `$FOO|` still completing `FOO`;
  - drag snapping at both ends, and a punctuation click returning the platform range.
- [x] Run `make test`; it must pass before Task 2.

### Task 2: Double-click override in the editor (app)

**Files:**
- Modify: `Sources/Pisaka/CodeEditorView.swift`, `Sources/Pisaka/CompletionController.swift`, `Sources/Pisaka/HoverController.swift`
- Create: `Tests/PisakaAppTests/WordSelectionGranularityTests.swift`

- [x] Override `selectionRange(forProposedRange:granularity:)` in `EditorTextView`.
  - For `.selectByWord`, call `super`, then return `WordSelectionRule.range(…)` with the coordinator's language.
  - Every other granularity is passed through; triple-click (`.selectByParagraph`) is untouched.
- [x] Pass the coordinator's language at every macOS `IdentifierScanner` call site: the ⌘-click, hover and completion controllers, and the `validateMenuItem` probe.
- [x] App test over a headless `EditorTextView` (`EditorLayoutHarness`):
  - word granularity on `z.object({…})`, `res.status`, `c$d` (TS);
  - a punctuation click equals `super`;
  - paragraph granularity unchanged.
- [x] Run `make test` and `make test-app` (no new failures beyond the eight known scale-1.8 assertions) before Task 3.

### Task 3: TSX as its own language (R4)

**Files:**
- Modify: `Sources/PisakaCore/SyntaxLanguage.swift` (`case tsx`, `"tsx": .tsx`, display name "TSX"), and every exhaustive switch the compiler reports: `CommentStyle`, `FileGlyph`, `FileIcon`, `LanguageKeywords` (shares the TypeScript list), `SyntaxContextVocabulary`, `CaretReadout`, `LSPServerDescription` (`.tsx` → `typescriptreact`, the TS server's language set), `LSPProvisioningManifest` (`[.typescript, .tsx, .javascript]`)
- Modify: `Sources/Pisaka/SyntaxLanguageConfiguration.swift`
- Create: `Resources/Queries/tsx/symbols.scm`
- Modify: `Tests/PisakaCoreTests/SymbolQueryTests.swift` (pinned node names), `LanguageKeywordsTests`, `SyntaxLanguageTests`, `LSPServerRegistryTests`, and any `allCases` set-equality suite that fails
- Create: `Tests/PisakaAppTests/TSXGrammarQueryTests.swift`

- [x] Add `SyntaxLanguage.tsx`. `.ts` stays `.typescript` and `.jsx` stays `.javascript`. Add `.tsx` to the JS-family word scalars from Task 1.
- [x] In `SyntaxLanguageConfiguration`, import `TreeSitterTSX` and add `makeTSXConfiguration()`.
  - It runs over `tree_sitter_tsx()` with `name: "TSX"` and bundle `TreeSitterTypeScript_TreeSitterTSX`.
  - Highlights are composed in this order: JS `highlights.scm`, then JS `highlights-jsx.scm`, then TS `highlights.scm`.
  - Factor the merge helper out of `makeTypeScriptConfiguration()` so the TS path stays byte-for-byte the same.
- [x] Add `Resources/Queries/tsx/symbols.scm` under the shared capture convention, starting from the TypeScript query.
- [x] Check that the LSP `languageId` for `.tsx` stays `typescriptreact`, and that `canServe(.tsx)` routes to typescript-language-server.
- [x] App test that executes the shipped grammar:
  - `Queries/tsx/symbols.scm` compiles against TSX and yields a component symbol for a sample;
  - the merged TSX highlights query compiles;
  - a JSX element in a `.tsx` sample parses without `ERROR` nodes, and its tag name and attribute are captured as `@tag`/`@attribute`.
- [x] Core tests: the extension map, the display name, the keyword/symbols set equalities, the LSP id and the server language set.
- [x] Run `make test` and `make test-app` before Task 4.

### Task 4: Colours and the overlay layers (R7)

**Files:**
- Modify: `Sources/Pisaka/SyntaxTheme.swift`, `Sources/Pisaka/BracketOverlayLayoutManager.swift`
- Create: `Tests/PisakaAppTests/OccurrenceBackgroundTests.swift`
- Modify: `Tests/PisakaAppTests/SyntaxThemeTests.swift`

- [x] Add four dynamic code-zone colours beside the bracket-match colour, each with light and dark values: `occurrenceReadBackground`, `occurrenceWriteBackground`, `selectionMatchBackground` (fainter) and `tagMatchBackground`. No chrome role is added, and the chrome-theme gating sets are unchanged.
- [x] In `BracketOverlayLayoutManager`, add `setOccurrenceRuns([(NSRange, kind)])` and `setTagRanges([NSRange])`. Both are no-ops when unchanged, as `setPairRanges` is.
  - Paint order, bottom to top: occurrences / selection matches, then tag pair, then bracket pair, then search matches, then the current search match.
  - `clearBackgrounds(storageLength:)` drops the new layers too.
- [x] App tests:
  - the layers paint and clear in that order;
  - unchanged input causes no repaint;
  - **AC4:** painting and clearing every layer leaves `undoManager.canUndo == false`, the string unchanged, and no `NSTextStorage` character edit (`editedMask` has no `.editedCharacters`);
  - colour light/dark values are distinct.
- [x] Run `make test-app` before Task 5.

### Task 5: Budgeted textual scans and highlight eligibility (Core, R2/R3)

**Files:**
- Create: `Sources/PisakaCore/OccurrenceScan.swift`, `Sources/PisakaCore/OccurrenceHighlightRule.swift`
- Create: `Tests/PisakaCoreTests/OccurrenceScanTests.swift`, `Tests/PisakaCoreTests/OccurrenceHighlightRuleTests.swift`

- [x] `OccurrenceScan.identifierMatches(of:in:language:budget:) -> [NSRange]?`
  - Matches are whole-word and case-sensitive. Whole-word means `IdentifierScanner.identifier(in:at:language:)` resolves exactly that range to that text, as `TextualUsageScanner` already asks. It builds no line index and no previews.
  - `nil` means "budget exhausted", and the caller shows nothing.
- [x] `OccurrenceScan.exactMatches(of:in:budget:)` does the same for R3: literal and case-sensitive.
- [x] Both use double-entry work bookkeeping. `record(_:)` counts the UTF-16 units searched plus each whole-word check. `spend(_:)` charges them, as two separate calls at each site.
  - The production ceiling is a stated constant (2,097,152 units).
  - An `internal` seam takes a smaller budget and exposes the performed work for tests.
- [x] `OccurrenceHighlightRule.mode(text:selection:language:) -> .identifier(Match) | .selectionMatch(String) | .none`.
  - **Identifier:** a caret in or touching an identifier, or a selection equal to exactly one identifier.
  - **Selection match:** a non-empty selection within one line (no `LineStartIndex` separator inside), not exactly one identifier, at least two UTF-16 units, not all whitespace.
  - **None:** anything else.
- [x] `OccurrenceHighlightRule.selectionMatchCap = 50`. Past 50 matches the answer is empty.
- [x] Tests:
  - whole-word and case-sensitivity, including `foo` in `foo.bar` but not in `foobar`/`_foo`, and `$x` in TS;
  - the `createStoreApiClient` sample's three `started`;
  - budget exhaustion on a pathological one-line input, asserting `nil` **and** performed work ≈ charged work at the ceiling (not a clock);
  - every R3 eligibility edge (multi-line, one-unit, whitespace, the exact identifier);
  - the cap at 50 and 51.
- [x] Run `make test` before Task 6.

### Task 6: `textDocument/documentHighlight` and the routing (Core, R2)

**Files:**
- Create: `Sources/PisakaCore/DocumentHighlight.swift` (`DocumentHighlightRequest`; `DocumentHighlightAnswer { provenance: .server | .textual, highlights: [(range, kind: .read | .write)] }`)
- Modify: `Sources/PisakaCore/LSPProtocolTypes.swift`, `LSPSession.swift`, `LSPIntelligenceProvider.swift`, `CodeIntelligence.swift`, `RoutingIntelligenceProvider.swift`, `SymbolIntelligenceProvider.swift`
- Modify/create the LSP suites: protocol coding, session, provider, routing (using `ScriptedLSPTransport`)

- [x] Protocol layer:
  - the method constant;
  - `LSPDocumentHighlightParams` and the `DocumentHighlight[] | null` result, where `kind` is 1 Text, 2 Read, 3 Write, or absent;
  - the client capability `textDocument.documentHighlight`;
  - the server capability `supportsDocumentHighlight`, decoded from `boolean | options`.
- [x] `LSPSession.documentHighlight(_:)`, with a `documentHighlight` budget in `LSPSession.Budgets` and `RoutingIntelligenceProvider.Budgets` set to completion's 1.5 s.
- [x] `LSPIntelligenceProvider.documentHighlights(for:)`.
  - It returns `nil` unless the server is prepared and advertises the capability, and when the buffer is no longer held (`stillHolds`).
  - Ranges are mapped through `LSPPositionMap`. `Write` maps to write; `Read`, `Text` and absent map to read.
- [x] `CodeIntelligenceProviding.documentHighlights(for:)`, defaulting to `nil`.
  - `SymbolIntelligenceProvider` answers with `OccurrenceScan.identifierMatches`: provenance `.textual`, every range read, and `nil` on an exhausted budget.
  - The router asks the server within its budget when `canServe(language)`. **A server answer, even an empty one, is final.** Only `nil` (no server, no capability, failure, timeout) falls back. The answer is never a merge.
- [x] Record the decision as D45 in `core-lsp.md` (Task 14). Silent fallback, no alert. (D45 entry written now; Task 14 adds the index and cross-references.)
- [x] Tests:
  - capability decoding in both spellings;
  - kind mapping including absent;
  - the server answer used whole with `.server` provenance;
  - failure, timeout and a missing capability falling back to `.textual`;
  - no answer ever containing both provenances;
  - a stale buffer answering `nil`.
- [x] Run `make test` before Task 7.

### Task 7: The occurrence-highlight model (Core, ordering)

**Files:**
- Create: `Sources/PisakaCore/OccurrenceHighlightModel.swift`
- Create: `Tests/PisakaCoreTests/OccurrenceHighlightModelTests.swift`

- [x] Add a `@MainActor` model holding the current answer (`[OccurrenceHighlight]` with read/write/selectionMatch kinds) and a monotonic generation token.
- [x] `settle(text:selection:language:fileURL:fileID:)` captures the token synchronously, then picks a mode via `OccurrenceHighlightRule`.
  - **Identifier mode:** the provider's `documentHighlights`.
  - **Selection-match mode:** `OccurrenceScan.exactMatches` with the cap, run off the main actor on the immutable snapshot.
  - **None:** clears.
  - A superseded result is discarded.
- [x] `noteEdit()` bumps the token and clears, so an edit clears until the next settle. `reset()` runs on tab switch or teardown.
- [x] Tests using `Gate`:
  - a slow first request overtaken by a second never publishes;
  - an edit during flight discards the result;
  - the mode switching clears the other mode's answer;
  - the server answer's write kind survives into the published state.
- [x] Run `make test` before Task 8.

### Task 8: Occurrence highlighting in the editor (app, R2/R3)

**Files:**
- Create: `Sources/Pisaka/OccurrenceHighlightController.swift`
- Modify: `Sources/Pisaka/CodeEditorView.swift` (Coordinator only)
- Create: `Tests/PisakaAppTests/OccurrenceHighlightControllerTests.swift`

- [x] The controller is owned by the `CodeEditorView` coordinator alone. The source viewer, diff/merge, Markdown preview and database viewer never get one.
- [x] Behaviour:
  - a selection change schedules `model.settle` after a 75 ms debounce;
  - the text-storage edit observer calls `model.noteEdit()` and clears the layer;
  - a tab switch calls `reset()`;
  - on publish and on scroll it pushes only the on-screen slice to `setOccurrenceRuns`, in the colours from Task 4.
- [x] App test: publishing never registers undo or dirties the buffer, and only on-screen runs are pushed. The causal hop is a published-state observation, not a sleep.
- [x] Run `make test` and `make test-app` before Task 9.

### Task 9: Matching-tag rule (Core, R5)

**Files:**
- Create: `Sources/PisakaCore/TagMatchRule.swift`
- Create: `Tests/PisakaCoreTests/TagMatchRuleTests.swift`

- [x] Input `TagElement { range, openName: NSRange, closeName: NSRange? }`. A fragment's names are its `<>`/`</>` ranges; a self-closing or unclosed element has `closeName == nil`. The input also carries the caret's chain of enclosing elements, innermost first, and whether the bracket pair is active at the caret.
- [x] Output `(tagRanges: [NSRange], suppressBracketPair: Bool)`.
  - **Caret in a tag name** (inclusive end): that element's names; a self-closing element gives its one name. The bracket pair is suppressed.
  - **Caret at an active bracket and not in a tag name:** no tag ranges.
  - **Otherwise:** the innermost enclosing element that has a closing name gives its two names, one level only. Both highlights may show.
- [x] Tests:
  - the `Header` sample (`</header>` caret; caret in `<span>` text);
  - nested same-name elements;
  - fragments;
  - self-closing elements, in the name and elsewhere;
  - attributes and children;
  - bracket priority both ways.
- [x] Run `make test` before Task 10.

### Task 10: Tree snapshot and tag highlighting (app, R5)

**Files:**
- Create: `Sources/Pisaka/SyntaxTreeSnapshot.swift`, `Sources/Pisaka/TagHighlightController.swift`
- Modify: `Sources/Pisaka/CodeEditorView.swift`, `Sources/Pisaka/BracketHighlightController.swift`
- Create: `Tests/PisakaAppTests/TagElementExtractionTests.swift` (+ fixtures in `Tests/PisakaAppTests/Fixtures/`)

- [x] `SyntaxTreeSnapshot` parses the buffer with the language's root grammar through a private `Parser`, off the main actor.
  - It caches per `(fileID, edit generation)` and is invalidated on edit, with a generation token on every parse.
  - It is shared by Task 12.
- [x] Extract the caret's enclosing element chain:
  - **JSX** (`.javascript`, `.tsx`): `jsx_element` with the opening/closing `name` fields; `jsx_self_closing_element`; a nameless opening/closing element is a fragment.
  - **HTML:** `element`/`script_element`/`style_element` with `start_tag`/`end_tag` `tag_name`, and `self_closing_tag`.
- [x] `TagHighlightController`, on the same 75 ms settle:
  - feeds `TagMatchRule`, with the bracket-pair state from `BracketMatchEngine.pair`;
  - paints through `setTagRanges`;
  - tells `BracketHighlightController` to suppress the pair when asked;
  - clears on edit.
- [x] App test: parse TSX, JSX and HTML fixtures, then assert the extracted chains at chosen offsets and the resulting ranges, including nested same-name elements and a fragment.
- [x] Run `make test` and `make test-app` before Task 11.

### Task 11: Expansion rule, history and the text fallback (Core, R6)

**Files:**
- Create: `Sources/PisakaCore/SelectionExpansionRule.swift`
- Modify: `Sources/PisakaCore/BracketMatchEngine.swift` (add `enclosingPair(text:around:)`, reusing its chunked scans and bracket tables)
- Create: `Tests/PisakaCoreTests/SelectionExpansionRuleTests.swift`; extend `BracketMatchEngineTests`

- [x] `candidates(text:selection:language:ancestors:stringContent:)` builds the ordered candidates:
  1. The word, offered only when the selection sits in an identifier (always inside string content). A caret on punctuation gets no word step.
  2. Each named ancestor, innermost first. When an ancestor's first and last characters form a bracket pair, its inner contents come immediately before it.
  3. The line.
  4. The document.
- [x] `fallbackCandidates(text:selection:language:)` for a language without a grammar: the word, then repeated `enclosingPair` outward (contents before pair), then the line, then the document.
- [x] `next(selection:candidates:)` returns the first candidate that strictly contains the selection. An equal range is skipped.
- [x] `SelectionExpansionHistory` has `push`, `pop` (Shrink) and `reset`.
- [x] Tests:
  - the expansion order over a hand-built ancestor chain;
  - the equal-range skip;
  - the word step inside a string;
  - a punctuation caret going straight to its node;
  - contents before brackets;
  - the full fallback chain over nested brackets;
  - push/pop/reset;
  - `enclosingPair` across mixed kinds.
- [x] Run `make test` before Task 12.

### Task 12: Expand / Shrink Selection commands (app, R6)

**Files:**
- Create: `Sources/Pisaka/SelectionCommands.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift` (add `SelectionCommands()` inside the existing `Group { … }`; the builder stays at ten entries), `Sources/Pisaka/CodeEditorView.swift` (`expandSelection()`/`shrinkSelection()` on the editor reached through `EditorCommandTarget`)
- Modify: `Tests/PisakaCoreTests/MenuShortcutUniquenessTests.swift` (doc inventory), `FoldingSourceGatingTests` if its scene-file rule needs it
- Create: `Tests/PisakaAppTests/SelectionExpansionTests.swift`

- [x] Add Edit menu items "Expand Selection" (⌃⌘→) and "Shrink Selection" (⌃⌘←) in a `CommandGroup(after: .pasteboard)`. Without a focused editor, or with no further step, they beep through `PlatformFeedback.warning()`.
- [x] Verify the chords are free:
  - against every `keyboardShortcut` (the uniqueness suite);
  - against AppKit's `StandardKeyBinding.dict` (read with `plutil`).

  Record the result in the type's doc comment, as `FoldCommands` does.
  (Result: free among the app's shortcuts; AppKit binds `@^←`/`@^→` to base writing direction, which the menu equivalent takes precedence over — recorded in `SelectionCommands`' doc comment.)
- [x] The editor walks the `SyntaxTreeSnapshot` from the selection up through named ancestors, marking string-content nodes, and feeds `SelectionExpansionRule`. A language with no grammar uses `fallbackCandidates`.
  - The editor's own selection changes are flagged so they keep the history.
  - Any other selection change, and any edit, resets it.
  - (Implemented in a new `SelectionExpansionController.swift`, held by the coordinator as one lazy property, because `CodeEditorView.swift` sits at the `file_length` ceiling; `PisakaApp.swift`'s ceilings rose by one for the `SelectionCommands()` entry, following `style-lint.md`'s procedure.)
- [x] App test: on a TS fixture, expand from a caret steps through word, argument contents, call, statement, then shrink returns along the same path. A manual selection change or an edit clears the history. Plain text uses the fallback.
- [x] Run `make test`, `make test-app` and `make lint` before Task 13.

### Task 13: Verify acceptance criteria

- [x] Run `make test` (`swift test`): green.
- [x] Run `make lint` (`swiftlint --strict`): clean.
- [x] Run `make test-app` under the pinned Xcode: no new failures beyond the eight known scale-1.8 layout assertions.
- [x] Run `make build` (macOS Release) under the pinned Xcode. iOS is CI's.
- [x] Confirm `MenuShortcutUniquenessTests` sees ⌃⌘→/⌃⌘← and that the `.commands { }` builder holds at most ten entries.
- [x] Check that every new Core file has a test suite covering its public API.

### Task 14: Update documentation

- [x] `docs/FEATURES.md`: double-click words, occurrence and selection-match highlighting, matching tags, TSX, Expand/Shrink Selection and their chords.
- [x] `docs/architecture/`:
  - `core-editor.md`: new entries for `WordSelectionRule`, `OccurrenceScan`, `OccurrenceHighlightRule`, `OccurrenceHighlightModel`, `TagMatchRule`, `SelectionExpansionRule`; an updated `BracketMatchEngine` and `SyntaxLanguage` (`.tsx`).
  - `core-intelligence.md`: `IdentifierScanner`'s language-aware rule and its completion consequence; the `SymbolIntelligenceProvider` textual highlight answer.
  - `core-lsp.md`: `DocumentHighlight.swift`, the new request among the client's questions with its silent fallback, its budget, and D45 ("a server answer, even empty, is final").
  - `app-editor.md`: `SelectionCommands`, the double-click override, expand/shrink.
  - `app-editor-overlays.md`: the new layers and paint order, `OccurrenceHighlightController`, `TagHighlightController`, `SyntaxTreeSnapshot`, the TSX configuration.
- [x] `CLAUDE.md`:
  - index names for every new Core and app file under the docs above;
  - `DocumentHighlight.swift` under `core-lsp.md`;
  - the completion-candidate invariant notes that the boundary rule is language-aware for the JavaScript family.

  `LintConfigurationTests` must keep it under 60,000 characters.

## Post-Completion

- In a DEBUG build, open a `.tsx` file and confirm ⌃⌘J answers. This is the grammar convention's manual check.
- In a DEBUG build, run the four user samples:
  - `friendListSchema` double-clicks;
  - `started` occurrences, with the declaration in the write colour under typescript-language-server;
  - `Header` tag pairs;
  - `.tsx` tag and attribute colouring.
- Confirm the CI iOS build (`generic/platform=iOS`) is green: the new `SyntaxLanguage` case reaches the iOS switches.
