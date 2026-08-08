# Code intelligence, phase 1: project symbol index, go-to-definition, autocompletion

## Overview

Pisaka gains its first editor intelligence on macOS, iPad and iPhone: jump to a
symbol's declaration, and complete identifiers while typing. The knowledge
source is a project-wide symbol index built from tree-sitter parse trees the app
already produces for highlighting. No language servers, no network, no new
dependencies.

All decision logic goes into `PisakaCore` behind an async provider protocol
(`CodeIntelligenceProviding`), so the phase-2 macOS LSP overlay replaces the
implementation and not the UI wiring. The app layer contributes only the two
things Core cannot hold: the tree-sitter symbol extractor, and the platform
surfaces (⌘-click / menu / popup on macOS; edit menu / keyboard accessory strip
on iOS).

## Context

**Existing code this builds on**

- `Sources/PisakaCore/ProjectSearchModel.swift` — the reference model for the
  whole async shape: `@MainActor ObservableObject`, generation tokens captured
  synchronously before the `Task` hop, a private serial queue with `offMain`,
  chunked publishing, `openBuffers` snapshot taken once on the main actor,
  gitignore/binary/oversize exclusions, `collectFiles` traversal.
- `Sources/PisakaCore/SyntaxLanguage.swift` — file name → language, the gate for
  "is this file worth indexing".
- `Sources/Pisaka/SyntaxLanguageConfiguration.swift` — cached, lock-guarded,
  non-`MainActor` grammar loader; `makeTypeScriptConfiguration` already shows
  how to compile a `Query` from raw `.scm` data against a `Language`.
- `Sources/Pisaka/MinimapTokenizer.swift` — the app-layer precedent for off-main
  tree-sitter work: `computeModel` is a `nonisolated static` function that
  builds its own `Parser` per call and reads the shared cached configuration.
- `Sources/Pisaka/BracketHighlightController.swift` — the `Task.sleep` debounce
  idiom used for editor-side controllers.
- `Sources/Pisaka/PisakaApp.swift` — `openFolder(url:)` (the one place a folder
  switch is registered with every collaborator),
  `activateSearchMatch(url:range:)` (open tab → resolve id → `reveal`), the
  `CommandMenu` blocks, the FSEvents `projectWatcher.start(root:onChange:)`
  wiring.
- `Sources/Pisaka/EditorRevealState.swift` — the one-shot, token-guarded "select
  this range in this tab" request that go-to-definition reuses verbatim.
- `Sources/Pisaka/CodeEditorView.swift` — `EditorTextView` (Cmd+scroll, ⌘D,
  Esc), the coordinator's `isApplyingProgrammaticEdit` re-entry guard, the
  per-file undo-manager discipline, the weak-capture retain-cycle rule.
- `Sources/Pisaka/iOS/CodeEditorView_iOS.swift` /
  `CodeEditorCoordinator_iOS.swift` — the UIKit peer.
- `Tests/PisakaCoreTests/VendoredGrammarQueryTests.swift` — the `ParsedQuery`
  scanner and the query-vs-`node-types.json` assertions this plan reuses for
  `symbols.scm`.
- `Tests/PisakaCoreTests/ReleaseMetadataTests.swift` — the pattern for asserting
  repository files and `project.yml` lines through `#filePath`.

**Dependencies:** none added. SwiftTreeSitter, Neon and the grammars already
linked are the whole toolbox; no pin changes, no `licenses.json` change.

## Decisions taken in this plan

These are the open choices the ticket left to the plan; each is stated here so
the implementation does not re-litigate them.

1. **iOS completion surface — as-you-type strip in `inputAccessoryView`**
   (confirmed with the user). A QuickType-style horizontal row above the
   keyboard, debounced, tap to insert. It never covers the text, never steals a
   keystroke, and works identically with the on-screen and a hardware keyboard,
   so iPad and iPhone share one surface.
2. **macOS completion popup — AppKit's built-in completion machinery.**
   `NSTextView.complete(_:)` plus
   `textView(_:completions:forPartialWordRange:indexOfSelectedItem:)` and
   `rangeForUserCompletion`. It gives the popup, arrow-key navigation, Esc
   dismissal, and — critically — insertion through
   `insertCompletion(_:forPartialWordRange:movement:isFinal:)`, which registers
   a single ordinary undo step on the active per-file undo manager. Building a
   custom `NSPanel` would duplicate all of that for one cosmetic gain (a detail
   column). The delegate is synchronous, so the debounce computes candidates
   through the *async* provider, stores them with the prefix they were computed
   for, and then calls `complete(nil)`; the delegate serves that snapshot when
   the prefix still matches and an empty array otherwise. That is exactly the
   shape a future LSP provider needs, so the seam is not compromised. Trade-off
   accepted and recorded: the popup shows identifiers only, no kind/file column.
3. **macOS definition picker — an `NSMenu` popped up at the caret**, one item
   per candidate reading `container.name — relative/path.swift:42`. Keyboard
   navigable, Esc-dismissable, no window controller to own.
4. **Shortcuts.** Go to Definition: ⌘-click, plus a `Find` menu item at ⌃⌘J
   (Xcode's binding; ⌘J and ⌃⌘F are free here, ⌃⌘J is unused by the app).
   Complete: a menu item at ⌃Space, in addition to AppKit's stock ⌥⎋ / F5.
5. **FSEvents-driven refresh — a debounced, stamp-gated re-walk.** The watcher
   reports only "something changed" (directory-level events), so the index
   re-runs the traversal and re-extracts *only* files whose `(byteCount,
   modificationDate)` stamp differs from the indexed one; vanished files are
   removed by set difference. This needs one new `FileServicing.fileStamp(at:)`
   (defaulted to `nil`, like `symbolicLinkDestination`/`fileByteCount`), and it
   is what keeps an `npm i` from re-parsing the whole project every second. iOS
   has no watcher, so there the index refreshes on folder open, tab open and
   buffer edits only — stated in the docs rather than worked around.
6. **What gets indexed.** A file is indexed only when
   `SyntaxLanguage(forFileName:)` resolves to a language that has a
   `symbols.scm` — so `.gitignore` and unknown extensions are skipped before any
   read. The existing `.git`/`.DS_Store`, gitignore, symlink, binary and 1 MB
   oversize exclusions come free from the shared traversal.
7. **The Core↔extractor seam is a *synchronous* injected function, and there is
   no extractor actor.** `SymbolIndexModel` injects `extractSymbols: @Sendable
   (String, SyntaxLanguage, URL) -> [Symbol]` and calls it only from inside its
   own `await offMain { … }` blocks — the private serial queue
   `ProjectSearchModel` already establishes. That queue *is* the serialization,
   so an actor on top of it would add a second hop and a second ordering
   authority for nothing; and, more importantly, an async closure awaited *per
   file* would have to be pulled out of the chunk body, turning the existing
   `await offMain { whole chunk } → re-check generation` shape into a per-file
   interleaving with a generation re-check after every file. Thread safety is
   the `MinimapTokenizer.computeModel` arrangement, which this repository
   already relies on: each call builds its own `Parser` and its own query cursor
   (tree-sitter parsers and cursors are not safe to share), while the compiled
   `Query` and `Language` come from the lock-guarded caches and are only read.
   The alternative — an async closure with a generation re-check after the await
   — was considered and rejected on those two grounds; the choice is recorded in
   `docs/architecture/core-intelligence.md` so phase 2 can revisit it
   deliberately if an LSP-backed *indexer* ever needs the async form. Note that
   this is the *indexing* seam only: the user-facing `CodeIntelligenceProviding`
   protocol stays async, which is the seam phase 2 actually slots into.

## Development approach

- **Testing approach**: regular (code first, then tests) — matching the
  repository's existing suites.
- Complete each task fully before moving to the next; `swift test` must be green
  at the end of every task.
- **Every task carries new/updated `PisakaCore` tests.** The app layer stays
  untested by convention, so any logic worth asserting must end up in Core.
- Core files stay Foundation-only (`CrossPlatformAuditTests` enforces it); app
  files stay thin, macOS under `#if os(macOS)`, iOS under `Sources/Pisaka/iOS/`.

## Implementation Steps

### Task 1: The symbol value type and the synchronous index

**Files:**

- Create: `Sources/PisakaCore/Symbol.swift`
- Create: `Sources/PisakaCore/SymbolIndex.swift`
- Create: `Tests/PisakaCoreTests/SymbolIndexTests.swift`

**Intent.** The two pure, allocation-cheap primitives everything else stands on:
what a symbol *is*, and a store that answers "who is named X" and "who starts
with X" fast enough to run on the main actor between keystrokes.

**Requirements.**

- `SymbolKind` — a closed, color-free enum covering what the queries can
  actually distinguish: `type`, `function`, `method`, `property`, `constant`,
  `variable`, `heading`, `selector`, `key`, `stage`, `anchor`. It carries the
  capture-name mapping (`init?(captureName:)`), returning `nil` for a name no
  query should be emitting — the counterpart of `SyntaxTokenKind(captureName:)`,
  except that an unknown capture is *dropped* rather than defaulted, so a typo
  cannot inject a garbage symbol.
- `Symbol` — `name`, `kind`, `range` (UTF-16, the *name* node's range, so a jump
  lands on the identifier and not on the whole declaration), `fileURL`,
  `containerName: String?`, and the 1-based `line` the picker displays.
- `SymbolIndex` — a plain struct/final class holding per-file symbol arrays plus
  a name bucket and a lowercased-prefix bucket. Operations: `replace(fileURL:
  symbols:)` (idempotent, fully replaces that file's contribution),
  `remove(fileURL:)`, `symbols(named:)`, `symbols(withPrefix:limit:)`,
  `symbols(inFile:)`, `indexedFileCount`. Files are keyed by
  `CanonicalPath.canonical(_:).path`, so a tab opened through a symlink and the
  traversal's spelling of the same file collapse to one entry — the rule
  `ProjectSearchModel.bufferKey(for:)` already uses.
- Prefix lookup is case-insensitive; ordering is left entirely to the ranking
  layer (Task 2), so the index returns candidates in a stable, documented order
  (file key, then location) and decides nothing about relevance.

**Acceptance.** `replace` twice for the same file leaves no residue of the first
call in either bucket; `remove` erases a file from both; a symbol whose name
differs only in case is found by prefix and not by exact name; the
canonical-path keying collapses `/tmp` and `/private/tmp` spellings.

- [x] add `SymbolKind` + `Symbol` with the capture-name mapping
- [x] add `SymbolIndex` with replace/remove and the two lookups
- [x] write `SymbolIndexTests` covering replace/remove semantics, prefix vs
      exact matching, case handling and canonical-path keying
- [x] run `swift test` — must pass before Task 2

### Task 2: Identifier scanning, the provider protocol, and ranking

**Files:**

- Create: `Sources/PisakaCore/IdentifierScanner.swift`
- Create: `Sources/PisakaCore/CodeIntelligence.swift`
- Create: `Sources/PisakaCore/SymbolIntelligenceProvider.swift`
- Create: `Tests/PisakaCoreTests/IdentifierScannerTests.swift`
- Create: `Tests/PisakaCoreTests/SymbolIntelligenceProviderTests.swift`

**Intent.** Everything the UI asks a question about, and the seam phase 2 slots
into. No tree-sitter, no platform types.

**Requirements.**

- `IdentifierScanner` — pure `NSString`/UTF-16 helpers: `identifier(in:at:)`
  (the whole identifier the caret or a click lands in, plus its range),
  `completionPrefixRange(in:at:)` (the partial word to the left of the caret;
  `foo.bar|` yields `bar`, `$FOO|` yields `FOO`, a caret after a non-identifier
  yields an empty range at the caret), and `words(in:limit:)`, the buffer word
  harvester. Identifier boundaries are one documented rule shared by all three:
  a leading letter or `_`, continuing with letters, digits and `_`, using
  Unicode letter/digit classification so a non-ASCII identifier is not split.
  `words` de-duplicates and caps, so a minified bundle cannot produce a 200
  000-entry set.
- `CodeIntelligence.swift` — the seam. `DefinitionRequest` (identifier, the file
  it was asked from, caret offset), `DefinitionCandidate` (the `Symbol` plus the
  project-relative path the picker shows), `CompletionRequest` (prefix, current
  file, the current buffer text for word harvesting), `CompletionItem` (text,
  kind, `isFromCurrentFile`), and:

```swift
public protocol CodeIntelligenceProviding: AnyObject {
    func definitions(for request: DefinitionRequest) async -> [DefinitionCandidate]
    func completions(for request: CompletionRequest) async -> [CompletionItem]
}
```

Async by design even though phase 1 answers synchronously, because an LSP
provider cannot.

- `SymbolIntelligenceProvider` — the index-backed implementation, and the home
  of every ranking rule, all of it pure and directly testable:
- definitions: exact, case-sensitive name match; current file first, then the
  rest ordered by relative path then line. An empty identifier yields nothing.
- completions: merge index prefix matches with harvested buffer words; sort by
  (case-sensitive prefix before case-insensitive, current-file before project,
  symbols before bare words, then shorter name, then lexicographic); collapse
  duplicates by name keeping the best-ranked entry; drop the token being typed
  itself; cap the result.

**Acceptance.** Ranking is fully pinned by tests, including each tie-break in
isolation; the word harvester's boundaries are pinned including the
`$`/`.`/digit-leading/Unicode cases; a provider over an empty index still
returns buffer words, which is the graceful-degradation guarantee for languages
with no query.

- [ ] add `IdentifierScanner`
- [ ] add the request/result types and `CodeIntelligenceProviding`
- [ ] add `SymbolIntelligenceProvider` with the documented ranking
- [ ] write both test files, covering ordering, dedup, caps and boundaries
- [ ] run `swift test` — must pass before Task 3

### Task 3: The shared project traversal and the async index model

**Files:**

- Create: `Sources/PisakaCore/ProjectFileWalk.swift`
- Create: `Sources/PisakaCore/SymbolIndexModel.swift`
- Modify: `Sources/PisakaCore/ProjectSearchModel.swift`
- Modify: `Sources/PisakaCore/FileService.swift`
- Create: `Tests/PisakaCoreTests/SymbolIndexModelTests.swift`
- Modify: `Tests/PisakaCoreTests/ProjectSearchModelTests.swift`
- Modify: `Tests/PisakaCoreTests/FileServiceTests.swift`

**Intent.** One traversal serving both Find in Files and the index, and the
orchestration model that keeps the index honest while the project changes under
it.

**Requirements.**

- Move `collectFiles(root:maskPatterns:fileService:)` and
  `relativePath(of:under:)` verbatim (doc comments included) out of
  `ProjectSearchModel` into `ProjectFileWalk`, and have `ProjectSearchModel`
  call through. This is a move, not a rewrite: the gitignore stack, the `.git`/
  `.DS_Store` filter, the symlink rules and the deterministic ordering are
  unchanged, and the existing traversal tests move with it. The alternative —
  reaching into another model's `nonisolated static` — is what this avoids.
- Add `FileStamp` (`byteCount`, `modificationDate`) and
  `FileServicing.fileStamp(at:)`, defaulted to `nil` so a partial stub still
  compiles; the concrete `FileService` reads both from one `resourceValues`
  call. A `nil` stamp means "always re-extract", so a stub service degrades to
  correct-but-slower rather than stale.
- `SymbolIndexModel` — `@MainActor`, `ObservableObject`, Foundation-only,
  modelled directly on `ProjectSearchModel`:
- injected `fileService`, an `openBuffers: () -> [URL: String]` snapshot
  closure, and the **synchronous** extractor `extractSymbols: @Sendable (String,
  SyntaxLanguage, URL) -> [Symbol]` — the app-layer tree-sitter function, which
  is the only reason Core stays Foundation-only. Per Decision 7, this closure is
  *never* awaited: it is called only from inside the model's own `await offMain
  { … }` blocks, so the model's private serial queue is the sole serialization
  authority and the existing `offMain(whole chunk) → re-check generation` shape
  is preserved exactly as `ProjectSearchModel` writes it. A test double is
  therefore an ordinary counting closure with no concurrency of its own.
- `prepareForFolderChange(root:) -> Int` bumps the generation and clears the
  index synchronously, before any `Task` hop, and `currentRequestGeneration`
  lets a caller pin a deferred rebuild — the repository's standard scheme.
- `rebuild(root:request:)` walks off-main on that private serial queue, skips
  files whose language has no query, and processes the list in chunks (32,
  matching project search) — one `offMain` block per chunk, calling
  `extractSymbols` once per file inside it — publishing after each chunk so
  results are usable while the walk continues. The generation is re-checked
  after *every* await, i.e. after every chunk.
- `refresh(root:)` re-walks and re-extracts only files whose stamp changed,
  removing files the walk no longer sees; same chunked shape.
- `reindexBuffer(url:text:language:) async` re-extracts one file from live text
  — the extraction itself inside a one-file `await offMain { … }`, with a
  generation re-check after it, so a folder switch mid-extraction discards the
  result — and marks its entry buffer-sourced. `forgetBuffer(url:)` on tab close
  reverts it to the disk version on the next refresh.
- **Buffer-over-disk precedence**: a chunk result never overwrites an entry a
  buffer wrote, so a mid-walk edit is not clobbered by the file's stale on-disk
  text arriving a moment later.
- `publishedIndex` (or an equivalent read accessor) is what
  `SymbolIntelligenceProvider` reads; the model exposes the provider so the app
  holds exactly one object.
- The model never writes to disk and never takes the autosave/revert gate — it
  is a reader, and the docs must say so explicitly.

**Acceptance.** Tests cover: a superseded rebuild publishing nothing; two rapid
folder changes settling on the newer one; a buffer entry surviving a concurrent
disk chunk; a `reindexBuffer` whose generation was bumped mid-flight publishing
nothing; a stamp-unchanged file not being re-extracted (asserted by counting
extractor invocations); a deleted file leaving the index on refresh; per-chunk
incremental availability (symbols answerable before the walk finishes);
unindexable languages never reaching the extractor.

- [ ] extract `ProjectFileWalk` and repoint `ProjectSearchModel` (no behavior
      change)
- [ ] add `FileStamp` + `fileStamp(at:)` with the defaulted protocol requirement
- [ ] add `SymbolIndexModel` with the generation scheme, chunked walk,
      stamp-gated refresh, buffer precedence and the off-main buffer re-index
- [ ] move the traversal tests, add `SymbolIndexModelTests`, extend
      `FileServiceTests`
- [ ] run `swift test` — must pass before Task 4

### Task 4: The `symbols.scm` query resources and their static verification

**Files:**

- Create: `Resources/Queries/<language>/symbols.scm` for swift, javascript,
  typescript, python, markdown, css, yaml, json, html, dockerfile, dotenv
- Modify: `project.yml`
- Create: `Tests/PisakaCoreTests/Support/QueryScanner.swift`
- Modify: `Tests/PisakaCoreTests/VendoredGrammarQueryTests.swift`
- Create: `Tests/PisakaCoreTests/SymbolQueryTests.swift`
- Modify: `Tests/PisakaCoreTests/ReleaseMetadataTests.swift`

**Intent.** The language knowledge itself, plus the static assertions that make
a grammar update fail `swift test` instead of silently degrading a language to
"no symbols" — the same reasoning `VendoredGrammarQueryTests` documents for
highlighting, which applies here with one extra twist: a broken symbols query is
*even quieter*, because an unindexed file looks exactly like a file with no
symbols.

**Requirements.**

- Query convention, authored once and used by all eleven files: the captured
  node is always the **name** node, and the capture name is the kind —
  `@definition.type`, `@definition.function`, `@definition.method`,
  `@definition.property`, `@definition.constant`, `@definition.variable`,
  `@definition.heading`, `@definition.selector`, `@definition.key`,
  `@definition.stage`, `@definition.anchor`. An optional `@container` capture in
  the same *match* supplies the enclosing type's name. Extraction reads matches
  (not captures), which is what makes the pairing possible.
- Coverage per the ticket: full declarations for Swift, JavaScript, TypeScript
  and Python; Markdown headings; CSS selectors; top-level YAML and JSON keys;
  Dockerfile build stages; dotenv variables; HTML `id` attributes. No gitignore
  query — the language is simply absent from the resource directory, and the
  test asserts that absence deliberately.
- `project.yml` gains `Resources/Queries` as a **folder reference** (`type:
  folder`), exactly like `Resources/Licenses`: the directory is copied verbatim,
  so adding a language's query needs no `xcodegen generate`.
- Promote the private `ParsedQuery` scanner out of `VendoredGrammarQueryTests`
  into a shared test-support file so both suites read queries the same way;
  `VendoredGrammarQueryTests` keeps its assertions and loses only the local
  copy.
- `SymbolQueryTests` (a repository test, `#filePath`-based, Foundation only):
- every `SyntaxLanguage` except `.gitignore` has a non-empty `symbols.scm`, and
  `.gitignore` has none — set equality against `SyntaxLanguage.allCases`, so
  adding a language later fails here until its query exists;
- every capture name across all eleven queries is either `container` or maps to
  a non-`nil` `SymbolKind`, asserted by **set equality** so a query gaining a
  capture fails until Core covers it;
- for the two vendored grammars (dotenv, and gitignore's deliberate absence),
  the query's node names and anonymous literals are validated against that
  package's own `src/node-types.json` under the matching `named` flag — the
  existing `assertQueryNodesAreDeclared` assertions, reused;
- for the nine remote grammars, whose sources are not in-repo, the node-name set
  each query uses is pinned by hand, the way `SyntaxTokenKindTests` pins the
  dockerfile captures — so a grammar update that renames a node fails here with
  a message naming the language, even though the repository cannot see the
  grammar.
- `ReleaseMetadataTests` gains an assertion that `project.yml` carries the
  `Resources/Queries` folder-reference lines, so the queries cannot fall out of
  the bundle unnoticed.
- The **runtime** half — that each query actually compiles against its grammar
  and captures what a fixture contains — needs SwiftTreeSitter, which Core does
  not link. It is covered instead by a debug-build guard in Task 5 and recorded
  as a manual check in the architecture doc, following the `VENDORED.md`
  precedent.
- [ ] author the eleven `symbols.scm` files under the stated capture convention
- [ ] wire `Resources/Queries` into `project.yml` as a folder reference
- [ ] move `ParsedQuery` into shared test support and repoint the vendored suite
- [ ] add `SymbolQueryTests` and the `ReleaseMetadataTests` assertion
- [ ] run `swift test` — must pass before Task 5

### Task 5: The app-layer tree-sitter symbol extractor

**Files:**

- Create: `Sources/Pisaka/Platform/SymbolQueryCatalog.swift`
- Create: `Sources/Pisaka/Platform/SymbolExtractor.swift`
- Create: `Sources/Pisaka/Platform/SymbolIndexController.swift`

**Intent.** The thin bridge that turns text into `[Symbol]`, shared by both
platforms, and the debounce that keeps an edited buffer's symbols current.

**Requirements.**

- `SymbolQueryCatalog` — loads `Queries/<language>/symbols.scm` from
  `Bundle.main`, compiles it into a `Query` against the grammar's `Language`
  (obtained from `SyntaxLanguageConfiguration`), and caches it. Not
  `@MainActor`, lock-guarded, `nil` on any failure — the exact contract and
  structure of `SyntaxLanguageConfiguration`, so a packaging or compilation
  failure degrades that language to "no symbols" rather than crashing. In DEBUG
  only, a compilation failure trips an `assertionFailure` naming the language:
  this is the runtime half `swift test` cannot reach, and a developer running a
  debug build hits it on the first file of that type.
- `SymbolExtractor` — **not an actor**: a caseless enum holding one `nonisolated
  static func symbols(in text: String, language: SyntaxLanguage, fileURL: URL)
  -> [Symbol]`, the `MinimapTokenizer.computeModel` shape. Per Decision 7 the
  caller (`SymbolIndexModel`) already serializes it on its own off-main queue,
  so no actor is introduced; the function's own thread-safety contract is the
  one `computeModel` already relies on — **each call builds its own `Parser` and
  its own query cursor**, and only *reads* the shared lock-guarded
  `Language`/`Query` caches. It parses the text, executes the symbols query,
  walks **matches**, maps the kind capture through `SymbolKind` and the optional
  `@container` capture to `containerName`, converts node ranges (already UTF-16
  `NSRange`) and computes the 1-based line via `LineStartIndex`. Unknown
  captures and empty names are dropped. Returning `[]` (no query, parse failure)
  is the documented degradation.
- `SymbolIndexController` — `@MainActor`, the `BracketHighlightController`
  debounce idiom: `noteBufferChanged(url:text:language:)` coalesces keystrokes
  (400 ms) into one `await SymbolIndexModel.reindexBuffer(…)`, while a tab
  open/switch re-indexes **immediately**, so the file the user is looking at has
  symbols before they finish reading it. It also owns the FSEvents refresh
  debounce (500 ms on top of the watcher's 1 s coalescing).
- All three live in `Sources/Pisaka/Platform/` and are compiled on both
  destinations, like `LicenseCatalogLoader`. No Core test changes — these files
  hold no decisions; the decisions are already in Core and tested there.
- [ ] add `SymbolQueryCatalog` with the debug-only compile guard
- [ ] add `SymbolExtractor` as a `nonisolated static` function (parser per call)
- [ ] add `SymbolIndexController` with the two debounces
- [ ] run `swift test` — must stay green

### Task 6: Index lifecycle wiring on both platforms

**Files:**

- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Sources/Pisaka/CodeEditorView.swift`
- Modify: `Sources/Pisaka/iOS/PisakaApp_iOS.swift`
- Modify: `Sources/Pisaka/iOS/RootView_iOS.swift`
- Modify: `Sources/Pisaka/iOS/CodeEditorView_iOS.swift`

**Intent.** Give the index a life: built on folder open, refreshed on external
change, kept current for the buffer being typed in — on both platforms, before
any UI surface consumes it.

**Requirements.**

- macOS `PisakaApp` owns the `SymbolIndexModel` as a `@StateObject`, constructed
  in the existing `init()` alongside `ProjectSearchModel` so it closes over the
  same `WorkspaceModel` (the `openBuffers` snapshot closure is the same one,
  weakly captured). Its `extractSymbols` argument is a **direct synchronous
  reference to `SymbolExtractor.symbols(in:language:fileURL:)`** — no actor hop,
  no `Task`, matching Decision 7 and Task 3's closure type exactly. The iOS root
  constructs it the same way, from the same function.
- `openFolder(url:)` calls `prepareForFolderChange(root:)` **synchronously** in
  the same main-actor turn as every other collaborator, then spawns the pinned
  `Task { await rebuild(...) }`. This is the sole place the switch is
  registered, so session restore gets it for free.
- The FSEvents callback, which today only bumps `treeRevision`, additionally
  asks `SymbolIndexController` for a debounced refresh. Nothing about it is
  gated: the index is a reader, so no `isReverting`-style guard belongs there —
  the same reasoning already written on `projectWatcher`.
- `ContentView` threads the model into `CodeEditorView`, which hands text
  changes and tab switches to `SymbolIndexController` from the paths that
  already exist for the minimap and bracket debounces. Every closure capturing
  the coordinator is weak, per the documented retain-cycle rule.
- The iOS root does the same at its folder-open point and on tab open; it has no
  watcher, so refresh there comes only from buffer edits and saves.
- [ ] own and construct the model on both platforms, passing the synchronous
      `SymbolExtractor` function; wire folder open
- [ ] wire the FSEvents refresh (macOS) and the buffer/tab-switch re-index
      (both)
- [ ] verify with `xcodebuild` macOS + iOS that both destinations build
- [ ] run `swift test` — must stay green

### Task 7: Go to Definition on macOS

**Files:**

- Modify: `Sources/Pisaka/CodeEditorView.swift`
- Create: `Sources/Pisaka/DefinitionPicker.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`

**Intent.** Click or press a key on an identifier and land on its declaration,
across files, reusing the Find-in-Files navigation path already proven.

**Requirements.**

- `EditorTextView` overrides `mouseDown(with:)`: a Command-held click (and no
  other modifier) resolves the character index under the point and asks the
  coordinator, consuming the event; every other click falls through to stock
  behavior — including Command-drag, which must still select rather than
  navigate.
- The coordinator asks Core for the identifier at that offset
  (`IdentifierScanner`), builds a `DefinitionRequest` and awaits
  `CodeIntelligenceProviding.definitions(for:)`.
- Zero candidates: `NSSound.beep()` and nothing else. One: navigate immediately.
  Several: `DefinitionPicker` pops an `NSMenu` at the caret's screen rect, one
  item per candidate showing container, relative path and line.
- Navigation goes through the app's existing `activateSearchMatch` path — open
  (or re-select) the tab through `openFile(url:)`, resolve the id, hand the
  range to `EditorRevealState`. A definition inside the *current* file takes the
  same path, so the caret move and scroll are one code path.
- A `Find` menu item "Go to Definition" at ⌃⌘J drives the same coordinator entry
  point from the caret, so the feature is reachable without a mouse.
- Core carries every decision already (Task 2); this task adds no new testable
  logic. Any behavior that turns out to need a decision goes into Core with a
  test rather than into the view.
- [ ] add the ⌘-click hit test and the coordinator entry point
- [ ] add `DefinitionPicker` and the no-match beep
- [ ] wire navigation through the existing reveal path and add the menu item
- [ ] run `swift test` — must stay green

### Task 8: Autocompletion on macOS

**Files:**

- Modify: `Sources/Pisaka/CodeEditorView.swift`
- Create: `Sources/Pisaka/CompletionController.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`

**Intent.** Offer the project's symbols and the buffer's words while typing,
without disturbing anything the editor already does with a keystroke.

**Requirements.**

- `CompletionController` (`@MainActor`, the `BracketHighlightController`
  debounce idiom, 150 ms): on each text change it computes the completion prefix
  through `IdentifierScanner`, and — if the prefix is at least two characters —
  awaits the provider, stores `(prefix, items)` and calls
  `textView.complete(nil)`. A superseded request is discarded by generation
  token. An empty result never opens the popup.
- `EditorTextView.rangeForUserCompletion` is overridden to return Core's
  completion-prefix range, so `foo.bar|` completes `bar` and not `foo.bar`.
- The coordinator implements
  `textView(_:completions:forPartialWordRange:indexOfSelectedItem:)`, returning
  the stored snapshot when the requested partial word still equals the prefix it
  was computed for, and `[]` otherwise. Synchronous by AppKit's contract;
  correct because the async work already happened.
- Insertion goes through AppKit's
  `insertCompletion(_:forPartialWordRange:movement:isFinal:)`, overridden on
  `EditorTextView` only to raise the coordinator's `isApplyingProgrammaticEdit`
  flag around `super`, so the auto-pair/dedent interceptor does not treat a
  completion as typed text. Undo is AppKit's, on the per-file undo manager, one
  step — nothing about the documented undo discipline changes.
- Explicit invocation: a `Find` menu item "Complete" at ⌃Space calling
  `complete(nil)` after forcing an immediate (undebounced) candidate refresh;
  AppKit's stock ⌥⎋ / F5 keep working through the same delegate.
- The popup must not appear while an IME composition is in flight
  (`hasMarkedText()`), matching the ⌘D guard's reasoning.
- [ ] add `CompletionController` with the debounce, snapshot and generation
      guard
- [ ] override `rangeForUserCompletion` and `insertCompletion(…)`; implement the
      completions delegate
- [ ] add the ⌃Space menu item and the IME guard
- [ ] run `swift test` — must stay green

### Task 9: The iOS surfaces

**Files:**

- Modify: `Sources/Pisaka/iOS/CodeEditorCoordinator_iOS.swift`
- Modify: `Sources/Pisaka/iOS/CodeEditorView_iOS.swift`
- Create: `Sources/Pisaka/iOS/CompletionBar_iOS.swift`
- Create: `Sources/Pisaka/iOS/DefinitionRoute_iOS.swift`
- Modify: `Sources/Pisaka/iOS/RootView_iOS.swift`

**Intent.** The same two features through touch-appropriate affordances, sharing
every Core decision with macOS.

**Requirements.**

- **Definition** — the coordinator implements
  `textView(_:editMenuForTextIn:suggestedActions:)` and appends a "Go to
  Definition" action when the identifier under the selection resolves. One
  candidate navigates; several present a small list. Navigation is routed
  through `DefinitionRoute_iOS` — a reference type held in `@State` by
  `RootView_iOS`, the shape `DiffRoute_iOS`/`MergeRoute_iOS` already establish —
  because opening the tab is the root view's job, not the text view's. No match
  gives a light `PlatformFeedback` haptic and nothing else.
- **Completion** — `CompletionBar_iOS`, a `UIInputView` installed as the text
  view's `inputAccessoryView`: a horizontally scrolling row of buttons,
  populated from the same debounced provider call as macOS (150 ms), tapping
  inserts. Plain UIKit rather than a hosted SwiftUI view, so there is no
  hosting-controller lifecycle to manage inside an input accessory.
- Insertion reuses the coordinator's existing `applyEdit` path, so it passes
  through the same programmatic-edit guard the auto-pair and indent code uses
  and registers one undo step.
- The bar hides itself when there are no candidates, so it never occupies space
  for nothing, and it is torn down in `dismantleUIView` alongside the
  highlighter.
- [ ] add the edit-menu action and `DefinitionRoute_iOS`, wired through
      `RootView_iOS`
- [ ] add `CompletionBar_iOS` and install it as the input accessory
- [ ] route insertion through the existing programmatic-edit path
- [ ] run `swift test` — must stay green

### Task 10: Verify acceptance criteria

- [ ] run `swift test` — the full suite must pass
- [ ] run `xcodegen generate`, then `xcodebuild -project Pisaka.xcodeproj
      -scheme Pisaka -destination 'platform=macOS' build`
- [ ] run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=iOS Simulator,name=iPhone 17 Pro' build`
- [ ] confirm every new Core type has a test file and that
      `CrossPlatformAuditTests` still passes (no forbidden imports leaked into
      Core)

### Task 11: Update documentation

- [ ] add `docs/architecture/core-intelligence.md` with full entries for
      `Symbol`, `SymbolIndex`, `ProjectFileWalk`, `SymbolIndexModel`,
      `IdentifierScanner`, `CodeIntelligence` and `SymbolIntelligenceProvider` —
      including the buffer-over-disk rule, the stamp-gated refresh, the
      reader-not-writer statement, the **synchronous-extractor seam and why it
      is not an actor** (Decision 7), and the manual runtime query check the
      static tests cannot cover
- [ ] add the app-layer entries: `SymbolQueryCatalog`, `SymbolExtractor` and
      `SymbolIndexController` to `docs/architecture/app-ios.md` (Platform
      shims), recording `SymbolExtractor`'s parser-per-call thread-safety
      contract; the macOS completion/definition files to
      `docs/architecture/app-editor.md`; the `PisakaApp` lifecycle wiring to
      `docs/architecture/app-shell.md`; the iOS surfaces to
      `docs/architecture/app-ios.md`
- [ ] note the `collectFiles`/`relativePath` move in
      `docs/architecture/core-search.md`
- [ ] add index lines only to `CLAUDE.md` (one per new file, plus the new doc in
      the architecture index) and extend the cross-cutting invariants section
      with the index's reader-only coordination rule
- [ ] update `README.md` with the two new user-facing features and their
      shortcuts
