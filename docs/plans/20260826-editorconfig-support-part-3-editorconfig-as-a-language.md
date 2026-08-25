# EditorConfig support, part 3: `.editorconfig` as a language

## Overview

Parts 1 and 2 made the editor *honor* `.editorconfig`; the file itself still
opens as plain text. This part makes it a first-class language: a
`SyntaxLanguage.editorconfig` case resolved from the file name (case-folded,
agreeing with `EditorConfigResolver.isFileName(_:)`), syntax highlighting
through a vendored tree-sitter grammar, a keyword list of the property names and
identifier-shaped value literals, and a symbols query so ⌃⌘J lists the glob
section headers. Nothing in the resolution engine, the indentation rules or the
on-save transforms moves.

## Context

### The grammar route is decided: **vendor**, exactly as the gitignore/dotenv/SQL grammars were

The upstream evaluation was done while writing this plan (clone inspected, not
guessed):

- Upstream: `https://github.com/ValdezFOmar/tree-sitter-editorconfig`, MIT
  (© 2024 Omar Valdez).
- Latest tag `v2.0.0` → `c4d5e725e1bbf683b223f4bebe83142cefe68da5`
  (2026-02-23). `main` is one commit ahead (a dependency bump); `src/parser.c`
  and `src/node-types.json` are identical between the two, so the **tag is the
  pin** — same posture as dotenv (`1.1.1`) and SQL (`v0.3.11`).
- It ships **no SwiftPM manifest and no Swift binding** (only `bindings/c`,
  `bindings/node`, `bindings/rust`). That is the gitignore condition verbatim,
  so a remote `project.yml` pin is impossible and
  `Vendor/TreeSitterEditorconfig/` is the route.
- It **does** have an external scanner (`externals: [$._end_of_file,
  $._integer_range_start]` → `src/scanner.c`), so `sources:` lists both
  `src/parser.c` and `src/scanner.c` — unlike gitignore, like dotenv/SQL.
- `LANGUAGE_VERSION` is **15**, and the pinned tree-sitter runtime declares
  `TREE_SITTER_LANGUAGE_VERSION 15` / `MIN_COMPATIBLE 13`. Compatible, and at
  the ceiling rather than the floor — the ABI check in the update procedure must
  record that a runtime *downgrade* is what would break it here, the inverse of
  the gitignore note.
- It **does** ship a query, at `queries/editorconfig/highlights.scm` — but it is
  deliberately **not adopted**, for two independent reasons that both must be
  recorded in `VENDORED.md`: (a) its capture names sit outside the vocabulary
  `SyntaxTokenKind` maps (`@character`, `@character.special` resolve to
  `.plain`, i.e. default-colored text — one of the two silent failure modes);
  (b) it uses `#lua-match?`, an editor-specific predicate this app's query
  pipeline does not implement. Its nested `queries/editorconfig/` path also does
  not match the `queries/highlights.scm` layout Neon's `LanguageConfiguration`
  reads out of the SPM resource bundle. So the highlight query is **authored in
  this repository**, like gitignore's, and carries the same "both failure modes
  are silent" verification recipe.

### The grammar's shape (read from `src/node-types.json` at the pin)

Named: `brace_expansion`, `character`, `character_choice`, `character_escape`,
`character_range`, `comment`, `editorconfig`, `glob`, `header`, `integer`,
`integer_range`, `pair`, `preamble`, `property`, `section`, `string`,
`wildcard`.

Anonymous: `!`, `,`, `-`, `..`, `/`, `=`, `[`, `]`, `{`, `}`.

Fields: `pair` → `key`, `value`; `character_range`/`integer_range` → `start`,
`end`.

This is enough for both queries. `(preamble (pair …))` is what makes the
`root = true` preamble distinguishable from an ordinary property without any
predicate — the preamble is its own node, so the "colour `root` differently"
requirement needs no `#eq?`.

### Section navigation: the kind is `.heading`

`(section (header (glob) @definition.heading))`. `.heading` is chosen
deliberately and is the only choice that satisfies requirement 4 without
changing another language: `SymbolIntelligenceProvider.kindsExcludedFromCompletion`
is exactly `[.heading]`, so a section header stays a ⌃⌘J jump target and is
never offered for insertion. `.selector` would *not* do — an identifier-shaped
header like `[Makefile]` would pass `IdentifierScanner.isIdentifier` and start
being offered as a completion, and widening the excluded set to `.selector`
would change CSS behavior, which is out of scope. The doc comments on
`SymbolKind.heading` and on `kindsExcludedFromCompletion` (both currently say "a
Markdown heading") get one clause each.

Because `.heading` is already emitted by the Markdown query,
`SymbolQueryTests.testShippedQueriesEmitExactlyTheCapturesCoreResolves` (union
of captures == all `SymbolKind` captures) stays satisfied with no new kind.

### Test gates this must satisfy (all set-equality, all fail the moment the enum case exists)

- `SymbolQueryTests.testEveryLanguageShipsASymbolsQueryExceptTheUnindexableOnes`
  — needs `Resources/Queries/editorconfig/symbols.scm`.
- `SymbolQueryTests.testRemoteGrammarQueriesUseExactlyThePinnedNodeNames` — its
  closing assertion is `Set(pinnedNodeNames.keys).union([.dotenv, .sql]) ==
  indexableLanguages`; the union gains `.editorconfig`, and a new
  `testEditorConfigSymbolsQueryUsesOnlyNodeNamesTheGrammarDeclares` checks it
  against the vendored `node-types.json` the way dotenv and SQL are checked.
- `LanguageKeywordsTests` — `testEveryLanguageEitherHasKeywordsOrIsExcluded`,
  `testEveryListIsSortedAndDuplicateFree`,
  `testEveryKeywordIsASingleInsertableToken` (this is the identifier-shape gate
  the ticket asks for; it already runs over every list) and
  `testTheDocumentedLanguagesAreTheOnesWithLists`.
- `VendoredGrammarQueryTests` — two new tests mirroring the
  gitignore/dotenv/SQL pair: node names and anonymous literals declared under the
  matching `named` flag, and the emitted capture set by equality with each
  resolving to a non-`.plain` kind.
- `LicenseCoverageTests` — `Resources/Licenses/TreeSitterEditorconfig.txt` + a
  `licenses.json` notice.
- `DependencyPinTests` — a `path:` dependency carries no pin; `Package.resolved`
  must be unchanged.
- Exhaustive switches the new case breaks: `CommentStyle.style(for:)`,
  `LanguageKeywords.keywords(for:)`,
  `SyntaxLanguageConfiguration.makeConfiguration(for:)`.
  (`LSPServerDescription` has a `default:` and is untouched — no LSP work here.)

### Files involved

- Create: `Vendor/TreeSitterEditorconfig/` (`Package.swift`, `VENDORED.md`,
  `LICENSE`, `grammar.js`, `src/`, `queries/highlights.scm`,
  `bindings/swift/TreeSitterEditorconfig/editorconfig.h`)
- Create: `Resources/Queries/editorconfig/symbols.scm`,
  `Resources/Licenses/TreeSitterEditorconfig.txt`
- Modify: `project.yml`, `Resources/Licenses/licenses.json`
- Modify: `Sources/PisakaCore/SyntaxLanguage.swift`, `FileIcon.swift`,
  `CommentStyle.swift`, `LanguageKeywords.swift`, `Symbol.swift`,
  `SymbolIntelligenceProvider.swift` (doc comments only)
- Modify: `Sources/Pisaka/SyntaxLanguageConfiguration.swift`
- Modify: `Tests/PisakaCoreTests/{SyntaxLanguageTests,FileIconTests,CommentStyleTests,LanguageKeywordsTests,SymbolQueryTests,VendoredGrammarQueryTests}.swift`
- Modify: `docs/architecture/core-editor.md`, `core-intelligence.md`,
  `core-editorconfig.md`, `CLAUDE.md`, `docs/FEATURES.md`

## Development Approach

- **Testing approach**: Regular (code first, then tests) — except the
  set-equality gates, which go red the instant the enum case exists and
  therefore pull their own implementation forward inside the same task.
- Task 2 is one task and not five on purpose: `SyntaxLanguage.editorconfig`
  breaks `SymbolQueryTests`, `LanguageKeywordsTests` and three exhaustive
  switches simultaneously, so splitting it would leave `swift test` red at a task
  boundary.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Vendor the grammar and ship its license

**Files:**
- Create: `Vendor/TreeSitterEditorconfig/{Package.swift,VENDORED.md,LICENSE,grammar.js}`,
  `src/{parser.c,scanner.c,grammar.json,node-types.json}`,
  `src/tree_sitter/{parser.h,array.h,alloc.h}`,
  `bindings/swift/TreeSitterEditorconfig/editorconfig.h`
- Create: `Resources/Licenses/TreeSitterEditorconfig.txt`
- Modify: `project.yml`, `Resources/Licenses/licenses.json`

- [x] clone upstream and check out tag `v2.0.0`; re-confirm the SHA, the commit
      date and that `src/parser.c`/`src/node-types.json` are unchanged versus
      `main` before pinning — record whatever is actually observed, do not copy
      the SHA from this plan blindly
- [x] copy **verbatim**: `src/parser.c`, `src/scanner.c`, `src/grammar.json`,
      `src/node-types.json`, `src/tree_sitter/{parser.h,array.h,alloc.h}`,
      `grammar.js` (kept for readability and as the `tree-sitter` CLI fallback),
      `LICENSE`. Do **not** copy upstream's `queries/`, `.editorconfig`,
      `bindings/`, `Cargo.*`, `package*.json`, `tree-sitter.json`, `test/`,
      `examples/`, `.github/`
- [x] author `bindings/swift/TreeSitterEditorconfig/editorconfig.h` declaring
      `tree_sitter_editorconfig()`, modeled on `gitignore.h`
- [x] author `Package.swift` on the dotenv/SQL model: package and target both
      `TreeSitterEditorconfig` (so the resource bundle is
      `TreeSitterEditorconfig_TreeSitterEditorconfig`, which
      `LanguageConfiguration(name: "Editorconfig")` derives), `path: "."`,
      `sources: ["src/parser.c", "src/scanner.c"]`, `.copy("queries")`,
      `publicHeadersPath: "bindings/swift"`, `cSettings:
      [.headerSearchPath("src")]`, `cLanguageStandard: .c11`, no dependencies
      and no test target
- [x] write `VENDORED.md` on the gitignore model, covering: upstream
      URL/tag/SHA/commit date/vendored-on date/license; the vendoring reason (no
      SwiftPM manifest, no Swift binding); what is verbatim vs. authored here;
      that upstream's `queries/editorconfig/highlights.scm` exists and is
      **deliberately not adopted**, with both reasons (unmapped capture names →
      default-colored text; the `#lua-match?` predicate) and the nested-path
      mismatch; the ABI note (parser is 15, the runtime's current ceiling — a
      runtime downgrade, not an upgrade, is the hazard here); the by-hand update
      procedure; and the **mandatory verification recipe** with its two fixtures
      and expected capture table (recipe filled in during Task 3, once the query
      exists)
- [x] wire `project.yml`: a `TreeSitterEditorconfig: { path:
      Vendor/TreeSitterEditorconfig }` package entry beside the three existing
      `path:` grammars with a comment stating its reason, and the matching target
      dependency
- [x] copy the verbatim `LICENSE` to
      `Resources/Licenses/TreeSitterEditorconfig.txt`; check the upstream tree
      for third-party code needing an appended notice — `src/tree_sitter/*.h`
      are tree-sitter's own headers, already covered by the existing
      `tree-sitter` notice exactly as for dotenv/SQL, so no append is expected;
      record what was checked
- [x] add the `licenses.json` notice: id `TreeSitterEditorconfig`, name
      `tree-sitter-editorconfig (vendored)`, origin
      `Vendor/TreeSitterEditorconfig`, `version` = the tag, `revision` = the
      40-hex SHA in `VENDORED.md`, `spdx: "MIT"`, `file:
      "TreeSitterEditorconfig.txt"`
- [x] confirm the scanner and parser reference no required-reason API (the
      `nm -u` audit in `docs/architecture/core-services.md`); no
      `PrivacyInfo.xcprivacy` change is expected — record the result
- [x] `swift build --package-path Vendor/TreeSitterEditorconfig` (builds in
      isolation)
- [x] run `swift test` — `LicenseCoverageTests` and `DependencyPinTests` must
      pass with the new vendored package

### Task 2: Core language wiring — enum case, name mapping, icon, comment style, keywords, symbols query

**Files:**
- Modify: `Sources/PisakaCore/{SyntaxLanguage,FileIcon,CommentStyle,LanguageKeywords,Symbol,SymbolIntelligenceProvider}.swift`
- Create: `Resources/Queries/editorconfig/symbols.scm`
- Modify: `Tests/PisakaCoreTests/{SyntaxLanguageTests,FileIconTests,CommentStyleTests,LanguageKeywordsTests,SymbolQueryTests}.swift`

- [x] add `case editorconfig` to `SyntaxLanguage` and an `exactFileNameMap`
      entry **keyed off `EditorConfigResolver.fileName`**, not a second string
      literal, so the mapping rule and the resolver's cannot become two answers;
      phase 1 lowercases the last path component, which is what gives
      `.EditorConfig` the same result `EditorConfigResolver.isFileName(_:)`
      gives. Deliberately add **no** extension entry and **no** prefix entry —
      `foo.editorconfig` must not resolve
- [x] add `.editorconfig` to `FileIcon.specialNameMap` (lowercased key ⇒
      case-insensitive, same as `.gitignore`), in the config family, with a
      symbol/color that reads as "settings" rather than reusing an existing
      language's
- [x] add `.editorconfig` to `CommentStyle`'s `#` line-comment group — the
      switch is exhaustive so the case forces this; note in a comment that the
      format also accepts `;` and that ⌘/ deliberately writes the spec's primary
      `#`
- [x] add the `editorConfig` keyword list to `LanguageKeywords` and route the
      new case to it: the nine property names (`charset`, `end_of_line`,
      `indent_size`, `indent_style`, `insert_final_newline`, `max_line_length`,
      `root`, `tab_width`, `trim_trailing_whitespace`) plus the eight
      identifier-shaped value literals (`cr`, `crlf`, `false`, `lf`, `space`,
      `tab`, `true`, `unset`), sorted and duplicate-free. Document in the list's
      comment why the charset values are absent — they are not identifier-shaped
      (`utf-8` ends at the hyphen), so listing them would offer text that could
      never be inserted correctly — and state the accepted limit that completion
      is not context-aware and offers keys and values alike
- [x] create `Resources/Queries/editorconfig/symbols.scm` capturing the section
      header glob as `@definition.heading`, with the shared convention header
      comment and a note on why `.heading` and not `.selector`
- [x] extend the doc comments on `SymbolKind.heading` and
      `SymbolIntelligenceProvider.kindsExcludedFromCompletion` so both name the
      `.editorconfig` section header alongside the Markdown heading; no code
      change to the exclusion set
- [x] tests: `SyntaxLanguageTests` —
      `.editorconfig`/`.EditorConfig`/`.EDITORCONFIG` resolve, a path-qualified
      form resolves, and `foo.editorconfig`/`editorconfig`/`.editorconfigx` do
      not; plus an agreement test asserting `SyntaxLanguage(forFileName:) ==
      .editorconfig` exactly when `EditorConfigResolver.isFileName(_:)` is true,
      across the same casings
- [x] tests: `FileIconTests` (icon by name, any casing), `CommentStyleTests`
      (the `#` style), `LanguageKeywordsTests` (a dedicated
      `testEditorConfigListIsThePropertyNamesAndIdentifierShapedValues` pinning
      the exact 17 entries and asserting the charset values are absent — the
      shared sorted/duplicate-free/insertable-token gates already cover the rest)
- [x] tests: `SymbolQueryTests` — add
      `testEditorConfigSymbolsQueryUsesOnlyNodeNamesTheGrammarDeclares` against
      `declaredNodeTypes(vendoredPackage: "TreeSitterEditorconfig")`, and add
      `.editorconfig` to the closing union in
      `testRemoteGrammarQueriesUseExactlyThePinnedNodeNames`
- [x] run `swift test`

### Task 3: The highlight query and its static gate

**Files:**
- Create: `Vendor/TreeSitterEditorconfig/queries/highlights.scm`
- Modify: `Vendor/TreeSitterEditorconfig/VENDORED.md`,
  `Tests/PisakaCoreTests/VendoredGrammarQueryTests.swift`

- [x] author `queries/highlights.scm`, every node name taken from
      `src/node-types.json` and every capture name inside a prefix
      `SyntaxTokenKind` already maps, so **no change to Core's capture mapping is
      needed**. The constructs it must cover, and the intended shape: comments
      (`(comment) @comment`); the section header's brackets
      (`@punctuation.bracket`) with the whole `(glob)` captured as a string so no
      part of a header can be left uncaptured, and the glob's own operators
      layered over it (`(wildcard)` and the character-choice `!` as `@operator`,
      `/` and `,` and `..` as `@punctuation.delimiter`, brace/choice/range
      brackets as `@punctuation.bracket`, `(integer) @number`, the
      character-range `-` as `@operator`); the property key as `@property`, the
      `=` as `@operator`, the value as `@string`; and the `root = true` preamble
      distinguished through the `(preamble (pair …))` node — key as `@keyword`,
      value as `@constant` — which needs no predicate. Verify against the real
      grammar while writing: pattern order matters, later patterns override
      earlier ones on overlapping ranges
- [x] state in the query's header comment, as gitignore's does, that both of its
      failure modes are silent in the app and point at `../VENDORED.md`
- [x] fill in `VENDORED.md`'s Verification section: two fixtures (one ordinary
      `.editorconfig` with a preamble, comments in both `#` and `;` form, a `[*]`
      and a `[*.{js,ts}]` section and several properties; one exercising the glob
      paths the first does not — `**`, `?`, a `[abc]`/`[!a-z]` character choice,
      an escape, a `{1..10}` integer range, a `/`-anchored glob), the observed
      capture table, the harness recipe (throwaway SwiftPM package against the
      vendored package + the resolved `SwiftTreeSitter`/`tree-sitter` checkouts,
      printing every capture and every uncaptured non-newline offset — that count
      must be zero), and the note that `swift test` automates only the static half
- [x] extend `VendoredGrammarQueryTests` with the two editorconfig tests
      mirroring the existing three grammars: node names and anonymous literals
      declared under the matching `named` flag, and the emitted capture set
      asserted by equality with each name resolving to a non-`.plain`
      `SyntaxTokenKind`
- [x] run `swift test`

### Task 4: App-layer grammar registration and platform builds

**Files:**
- Modify: `Sources/Pisaka/SyntaxLanguageConfiguration.swift`

- [x] `import TreeSitterEditorconfig` beside the other grammar imports, with a
      comment noting it is the fourth vendored one and pointing at its
      `VENDORED.md`
- [x] add the `case .editorconfig` arm returning
      `LanguageConfiguration(tree_sitter_editorconfig(), name: "Editorconfig")` —
      the exhaustive switch already forces it; comment why the name is
      `"Editorconfig"` and not `"EditorConfig"` (the resource bundle is
      `TreeSitterEditorconfig_TreeSitterEditorconfig`)
- [x] `xcodegen generate`
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=macOS' -configuration Release build`
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'generic/platform=iOS' build` — the grammar must link on both
      destinations, like the existing ones
- [x] confirm `Package.resolved` is unchanged by the path dependency; if
      `xcodebuild -resolvePackageDependencies` rewrites it, regenerate rather
      than hand-edit and re-run `DependencyPinTests`
- [x] run `swift test`

### Task 5: Documentation

**Files:**
- Modify: `docs/architecture/core-editor.md`, `core-intelligence.md`,
  `core-editorconfig.md`, `CLAUDE.md`, `docs/FEATURES.md`

- [x] `core-editor.md`: extend the `SyntaxLanguage.swift` entry with the
      exact-name rule and why it borrows the resolver's own constant, the
      `FileIcon.swift` entry, and the `CommentStyle.swift` entry (`#`, with `;`
      accepted by the format but not written by ⌘/)
- [x] `core-intelligence.md`: extend the `LanguageKeywords.swift` entry with the
      list's sourcing, the charset exclusion and the stated
      non-context-awareness; extend the symbols-query section with the
      section-header mapping and why `.heading` is the kind that keeps a header
      out of completion
- [x] `core-editorconfig.md`: one short paragraph noting the file is now a
      first-class language, with a pointer to the
      `core-editor.md`/`core-intelligence.md` entries and an explicit statement
      that resolution, indentation and the on-save transforms are unchanged by it
- [x] `CLAUDE.md`: update the vendoring convention paragraph — "Three
      tree-sitter grammars are vendored" becomes four, with this one's reason in
      one clause (upstream ships no SwiftPM manifest and no Swift binding, and
      its own query is unusable here) — and add the language to the index lines
      that enumerate languages, without growing either into an essay
- [x] `docs/FEATURES.md`: add the language to the lines that already enumerate
      languages — the comment-toggle list, the highlighting list, the file-name
      resolution list and the keyword-completion list — plus the one line this
      feature deserves
- [x] run `swift test`

### Task 6: Verify acceptance criteria

- [ ] `swift test` fully green, with `VendoredGrammarQueryTests`,
      `SymbolQueryTests`, `LanguageKeywordsTests`, `SyntaxLanguageTests`,
      `CommentStyleTests`, `FileIconTests`, `LicenseCoverageTests` and
      `DependencyPinTests` all picking up the new language
- [ ] `swiftlint --strict` clean from the repository root
- [ ] `xcodegen generate` && macOS Release build && iOS `generic/platform=iOS`
      build
- [ ] confirm no exemption was added to any suite for this language beyond the
      vendoring route's legitimate ones, and that no LSP registry, provisioning
      manifest, `PrivacyInfo.xcprivacy`, resolution-engine, indentation or
      save-transform file was touched

## Post-Completion (manual — load-bearing, cannot be automated)

The convention requires opening a file of the new language in a **DEBUG build**
on every grammar addition. Both failure modes are silent: a query that no longer
compiles degrades the file to plain text, and a mistyped capture renders it
default-colored; `SymbolQueryCatalog`'s DEBUG assertion is the only thing that
can see the symbols query fail.

1. Run the vendored package's runtime harness from `VENDORED.md` against both
   fixtures and confirm the capture tables match and the uncaptured-character
   count is zero.
2. Run a DEBUG build and open an `.editorconfig` containing a `root = true`
   preamble, `#` and `;` comments, a `[*]` section, a `[*.{js,ts}]` brace
   expansion, a `[{1..10}.txt]` integer range and a `[[abc]x]` character choice.
3. Confirm highlighting renders — comments, section globs, keys, values and the
   preamble all distinctly colored, nothing default-colored in bulk, and the file
   is not falling back to plain text.
4. Confirm no `SymbolQueryCatalog` assertion fires.
5. ⌃⌘J lists the file's section headers.
6. Type `ind` and confirm `indent_style`/`indent_size` are offered; type `cr`
   and confirm `crlf` is offered; confirm no section-header glob is ever offered
   for insertion.
7. Confirm the project tree and the tab show the new icon rather than the
   generic `doc`, including for a file named `.EditorConfig`.
8. Open a file with the same content under a different name and confirm it does
   **not** highlight as this language.
