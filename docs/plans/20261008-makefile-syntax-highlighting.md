# Makefile: syntax highlighting as the eighteenth language

## Overview

Add `SyntaxLanguage.make` (display name "Makefile") on both platforms, on the same
footing as Dockerfile. The case resolves from `Makefile`/`makefile`/`GNUmakefile` and
`*.mk`/`*.mak`. Highlighting comes from a fifth vendored grammar,
`Vendor/TreeSitterMake`, and bash is injected into recipe bodies. Toggle-comment uses
`#`, keyword completion covers the identifier-shaped GNU make directives and built-in
functions, and a `symbols.scm` indexes rule targets (a new `SymbolKind.target`) and
variable definitions. There is no LSP server and no provisioning entry.

## Context

### Grammar facts (checked against a fresh clone while writing this plan; re-confirm before pinning)

- The pinned source is `https://github.com/tree-sitter-grammars/tree-sitter-make`, MIT,
  © 2021 Alexandre A. Muller. It is the maintained fork of `alemuller/tree-sitter-make`.
- Newest tag: `v1.1.1` → `5e9e8f8f…` (2024-12-21). `HEAD` of the default branch:
  `70613f3d812cbabbd7f38d104d60a409c4008b43` (2026-02-26), 9 commits past the tag. Those
  commits include "add missing GNU Make builtin functions", "sync queries from
  nvim-treesitter" and a regeneration with tree-sitter 0.26.6.
- Decision: pin the `HEAD` commit, not the tag. The tag's parser lacks built-in functions
  this feature highlights and completes. `VENDORED.md` records this reason.
- The repository has no `Package.swift` and no Swift binding, only
  `bindings/c/tree_sitter/tree-sitter-make.h`, which declares `tree_sitter_make()`. That
  is the editorconfig/gitignore condition, so the grammar is vendored.
- It is parser-only, with no `externals`, so `sources: ["src/parser.c"]`, like gitignore.
- `LANGUAGE_VERSION 15`, the ceiling of the pinned runtime (15, minimum 13). As for
  editorconfig, a runtime downgrade is the hazard.
- Upstream ships `queries/highlights.scm`, `injections.scm` and `folds.scm` at the flat
  `queries/` path that Neon reads.
- `injections.scm` injects `"bash"` into `(shell_text)` and `(shell_command)`.
  `SyntaxLanguageConfiguration.configuration(forInjectionName:)` already resolves
  `"bash"` through the extension map to `.shell`, so copying the file verbatim gives
  recipe-line shell highlighting at no extra cost.
- `highlights.scm` cannot be used verbatim. Its captures `@spell` and
  `@character.special` resolve to `.plain` (the silent failure mode
  `VendoredGrammarQueryTests` refuses). It also colours variable names as
  `@string.special.symbol` and references as `@string`, which would draw every variable
  in string colour.
- So `highlights.scm` is adapted from upstream, and every edit is listed in
  `VENDORED.md`.
- The predicates it uses (`#eq?`, `#any-of?`, `#set!`) are all implemented by the pinned
  SwiftTreeSitter (`Predicate.swift`).
- Node shapes the queries rely on, from `src/node-types.json`:
  - `rule` has children `targets`/`recipe`, and `targets` contains `word` (among other
    children).
  - `variable_assignment` has fields `name: (word)`, `operator`, `value`, and optionally
    `target_or_pattern`. Target-specific assignments are top-level `variable_assignment`
    nodes too.
  - `shell_assignment` and `define_directive` each have a `name: (word)` field.
  - Assignments inside `ifeq` blocks are nested under `conditional`, so variable captures
    must not be anchored to the root.

### Decisions taken here

- **Symbol kind for targets: a new `SymbolKind.target`**, on the precedent of
  Dockerfile's `.stage`. `.function` would be a lie. `.target` is an ordinary completion
  candidate, and `IdentifierScanner` already filters names that are not
  identifier-shaped (`foo.o`, `build-all`).
  - It needs a badge in `CompletionPopup.symbolBadges`.
  - `SymbolQueryTests.testShippedQueriesEmitExactlyTheCapturesCoreResolves` holds the new
    case and the new capture against each other.
- **Special and pattern targets are excluded** with
  `(#not-match? @definition.target "^[.]|%")`. Without it, `.PHONY`, `.SUFFIXES` and
  `%.o` would land in ⌃⌘J.
  - This makes Make the second symbols query with a predicate. `SymbolQueryTests`
    currently pins HTML as the only one, so that pin becomes an exact map
    `{html: [match?], make: [not-match?]}`, and the extractor's doc comment is updated to
    match.
  - The app-layer suite below executes the query, so the predicate is proven to be
    evaluated, not just present.
- **Variables:** names from `variable_assignment`, `shell_assignment` and
  `define_directive` are captured as `@definition.variable`, unanchored, so definitions
  inside conditionals are indexed. Target-specific assignments are indexed too: each one
  is a real definition site, and ⌃⌘J already lists multiple definitions of one name.
- **Keywords: identifier-shaped words only.** `testEveryKeywordIsASingleInsertableToken`
  runs over every list, so `.PHONY` and the other special targets (leading dot),
  `filter-out` and `-include` (hyphen) cannot be listed. The list's comment states this
  exclusion, as editorconfig's does for charset values. The list contains:
  - directives: `define`, `else`, `endef`, `endif`, `export`, `ifdef`, `ifeq`, `ifndef`,
    `ifneq`, `include`, `override`, `private`, `sinclude`, `undefine`, `unexport`, `vpath`
  - built-in functions at the pinned grammar's set (hyphenated ones excluded):
    `abspath`, `addprefix`, `addsuffix`, `and`, `basename`, `call`, `dir`, `error`,
    `eval`, `file`, `filter`, `findstring`, `firstword`, `flavor`, `foreach`, `guile`,
    `if`, `info`, `join`, `lastword`, `notdir`, `or`, `origin`, `patsubst`, `realpath`,
    `shell`, `sort`, `strip`, `subst`, `suffix`, `value`, `warning`, `wildcard`, `word`,
    `wordlist`, `words`, `let`, `intcmp`
  - The final list is sorted, duplicate-free, and reconciled against the grammar's
    `grammar.js` at the pin.
- **`SyntaxContextVocabulary`:** comment form `.line("#", anchor: .anywhere)`, no string
  forms, and `stringsSuppressCompletion` is `false` (Make has no string literal). The
  stated non-model: a `#` inside a recipe line belongs to the shell and a
  backslash-escaped `\#` is literal, but the scanner still calls both a comment. The cost
  is that completion is suppressed there, which is the conservative direction.
- **Other answers:**
  - `CommentStyle`: joins the `#` line group.
  - `lspLanguageID`: `"makefile"`, the protocol's spelling. No server speaks it; the arm
    keeps the mapping total.
  - `FileGlyph`: `.fileCode`.
- **`FileIcon`:** `"makefile"` (hammer, gray) already exists. Add `"gnumakefile"` and the
  `mk`/`mak` extensions with the same icon, so the existing icon/language agreement test
  stays green.
- **No prefix rule** (`Makefile.inc`), because the ticket does not require it.
  - `makefile.swift` stays Swift (the extension phase answers before anything else).
  - `.makeignore` stays gitignore (dot-ignore shape).
  - Tests assert both.

### Test gates that go red the moment the case exists

- Exhaustive switches:
  - `SyntaxLanguage.displayName`
  - `CommentStyle.style(for:)`
  - `LanguageKeywords.keywords(for:)`
  - `SyntaxContextVocabulary` (three switches)
  - `FileGlyph.forFile`
  - `lspLanguageID`
  - `SyntaxLanguageConfiguration.makeConfiguration(for:)`
  - `CompletionPopup.symbolBadges` (forced by the new `SymbolKind`)
- Set-equality and pinned-list suites:
  - `SymbolQueryTests`: the query must exist, its node names must be declared, the
    vendored-language union must include `.make`, and the predicate pin changes.
  - `LanguageKeywordsTests`: `testTheDocumentedLanguagesAreTheOnesWithLists`.
  - `LicenseCoverageTests`: the vendored-id set at line ~328, plus the copyright-line map
    at ~600.
  - `VendoredGrammarQueryTests`.
  - `FileIconTests` and `FileGlyphTests`.

### Files involved

- Create:
  - `Vendor/TreeSitterMake/`, containing `Package.swift`, `VENDORED.md`, `LICENSE`,
    `grammar.js`, `src/{parser.c,grammar.json,node-types.json}`,
    `src/tree_sitter/{parser.h,array.h,alloc.h}`,
    `queries/{highlights.scm,injections.scm}` and
    `bindings/swift/TreeSitterMake/make.h`
  - `Resources/Queries/make/symbols.scm`
  - `Resources/Licenses/TreeSitterMake.txt`
  - `Tests/PisakaAppTests/MakeSymbolQueryTests.swift`
  - `Tests/PisakaAppTests/Fixtures/make-symbols.mk`
- Modify:
  - `project.yml`
  - `Resources/Licenses/licenses.json`
  - Core sources in `Sources/PisakaCore/`: `SyntaxLanguage`, `FileIcon`, `FileGlyph`,
    `CommentStyle`, `LanguageKeywords`, `SyntaxContextVocabulary`,
    `LSPServerDescription`, `Symbol`, `CompletionPopup`, `SymbolIntelligenceProvider`
    (doc comment only)
  - `Sources/Pisaka/SyntaxLanguageConfiguration.swift`
  - `Sources/Pisaka/Platform/SymbolExtractor.swift` (doc comment only)
  - Core tests in `Tests/PisakaCoreTests/`: `SyntaxLanguageTests`, `FileIconTests`,
    `FileGlyphTests`, `CommentStyleTests`, `ToggleCommentEngineTests`,
    `LanguageKeywordsTests`, `SyntaxContextVocabularyTests`,
    `SyntaxContextScannerTests`, `SymbolQueryTests`, `VendoredGrammarQueryTests`,
    `LicenseCoverageTests`, `CompletionPopupTests` (if badges are pinned)
  - Docs: `README.md`, `docs/FEATURES.md`, and in `docs/architecture/`:
    `core-editor.md`, `core-intelligence.md`, `app-editor-overlays.md`,
    `core-services.md`
  - `CLAUDE.md`

## Development Approach

- **Testing approach**: Regular (code first, then tests). The set-equality gates go red
  the instant the enum case exists, so Task 2 is deliberately one task: splitting it
  would leave `swift test` red at a task boundary.
- Copy facts (SHA, dates, node names) from what the clone actually shows at
  implementation time, not from this plan.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Vendor the grammar and ship its license

**Files:**
- Create: `Vendor/TreeSitterMake/{Package.swift,VENDORED.md,LICENSE,grammar.js}`,
  `src/{parser.c,grammar.json,node-types.json}`,
  `src/tree_sitter/{parser.h,array.h,alloc.h}`, `queries/injections.scm`,
  `bindings/swift/TreeSitterMake/make.h`
- Create: `Resources/Licenses/TreeSitterMake.txt`
- Modify: `project.yml`, `Resources/Licenses/licenses.json`,
  `Tests/PisakaCoreTests/LicenseCoverageTests.swift`

- [x] Clone `tree-sitter-grammars/tree-sitter-make`. Re-confirm the default-branch HEAD
  SHA and date, its distance from `v1.1.1`, `LANGUAGE_VERSION`, and the absence of
  `externals`/`scanner.c`. Pin the observed HEAD commit.
- [x] Copy these files **verbatim**:
  - `src/parser.c`, `src/grammar.json`, `src/node-types.json`
  - `src/tree_sitter/{parser.h,array.h,alloc.h}`
  - `grammar.js`, `LICENSE`, `queries/injections.scm`
- [x] Do not copy `folds.scm`, `bindings/c`, `CMakeLists.txt`, `Makefile`,
  `package.json`, `tree-sitter.json` or `test/`.
- [x] Author `bindings/swift/TreeSitterMake/make.h` declaring `tree_sitter_make()`,
  modelled on `gitignore.h`.
- [x] Author `Package.swift` on the gitignore/editorconfig model:
  - package and target both named `TreeSitterMake`, so the bundle is
    `TreeSitterMake_TreeSitterMake`
  - `path: "."`, `sources: ["src/parser.c"]`, `.copy("queries")`
  - `publicHeadersPath: "bindings/swift"`, `headerSearchPath("src")`, `.c11`
  - no dependencies and no test target
- [x] Write `VENDORED.md` in the editorconfig shape, covering:
  - upstream URL, commit, date, vendored-on date and licence
  - why the fork rather than `alemuller`, and why HEAD rather than `v1.1.1`
  - the vendoring reason: no SwiftPM manifest and no Swift binding
  - what is verbatim and what is authored here
  - the ABI note
  - that `injections.scm` is adopted verbatim and resolves `"bash"` to the shell grammar
  - the by-hand update procedure
  - a Verification section placeholder, filled in Task 3
- [x] Wire `project.yml`: add a `TreeSitterMake: { path: Vendor/TreeSitterMake }` entry
  beside the other four, with a reason comment, plus the matching target dependency.
- [x] Copy `LICENSE` to `Resources/Licenses/TreeSitterMake.txt`. Check the tree for
  third-party code needing an appended notice (`src/tree_sitter/*.h` is already covered
  by the `tree-sitter` notice) and record the result.
- [x] Add the `licenses.json` notice: id `TreeSitterMake`, name
  `tree-sitter-make (vendored)`, origin `Vendor/TreeSitterMake`, revision = the SHA,
  `spdx: "MIT"`.
- [x] Extend `LicenseCoverageTests`: add `TreeSitterMake` to the vendored-id set and the
  copyright line `Copyright (c) 2021 Alexandre A. Muller`.
- [x] Run the `nm -u` required-reason audit from `core-services.md` against the built
  object and record the result. No `PrivacyInfo.xcprivacy` change is expected.
- [x] Run `swift build --package-path Vendor/TreeSitterMake`.
- [x] Run `swift test`: `LicenseCoverageTests` and `DependencyPinTests` must be green.

### Task 2: Core language wiring: case, resolution, icon, comment, context, keywords, symbol kind, symbols query

**Files:**
- Modify: Core sources in `Sources/PisakaCore/`: `SyntaxLanguage`, `FileIcon`,
  `FileGlyph`, `CommentStyle`, `SyntaxContextVocabulary`, `LanguageKeywords`,
  `LSPServerDescription`, `Symbol`, `CompletionPopup`, `SymbolIntelligenceProvider`
- Modify: `Sources/Pisaka/SyntaxLanguageConfiguration.swift`. The exhaustive switch
  forces it here; the arm is filled in for real in Task 4 and returns
  `LanguageConfiguration(tree_sitter_make(), name: "Make")` now.
- Create: `Resources/Queries/make/symbols.scm`
- Modify: the matching Core tests in `Tests/PisakaCoreTests/`

- [ ] Add `case make` with `displayName` "Makefile".
- [ ] Add exact names `makefile`, `gnumakefile` (lowercased; `Makefile` is reached
  through the type's case folding) and extensions `mk`, `mak`. Add no prefix rule.
  Extend the type's doc comment with one paragraph on the case and why it needs no
  prefix rule.
- [ ] `FileIcon`: add `gnumakefile` plus the `mk`/`mak` extensions with the existing
  hammer/gray icon. `FileGlyph`: `.make` → `.fileCode`.
- [ ] `CommentStyle`: add `.make` to the `#` line group.
- [ ] `SyntaxContextVocabulary`:
  - comment form `#`, anchor `.anywhere`
  - string forms: none
  - `stringsSuppressCompletion` is `false`
  - comment the recipe-line and `\#` non-models
- [ ] `LanguageKeywords`: add the `make` list described in Context, sorted, with a
  comment stating the sourcing and the identifier-shape exclusion (special targets,
  `filter-out`, `-include`).
- [ ] `lspLanguageID`: `.make` → `"makefile"`, with a one-line reason.
- [ ] `SymbolKind`: add `case target` with a doc comment ("a Makefile rule target"). Add
  its `CompletionPopup` badge (e.g. `"target"` or `"scope"`; pick an SF Symbol that
  exists on macOS 14/iOS 17). Name `.target` in the `kindsExcludedFromCompletion` doc
  comment's list of non-code kinds that stay candidates.
- [ ] Create `Resources/Queries/make/symbols.scm` with:
  - the shared convention header
  - `(rule (targets (word) @definition.target) (#not-match? @definition.target "^[.]|%"))`
  - the three `name: (word) @definition.variable` patterns
  - comments on why special/pattern targets are excluded and why variables are
    unanchored
- [ ] Tests, `SyntaxLanguageTests`:
  - `Makefile`, `makefile`, `GNUmakefile`, `MAKEFILE`, `rules.mk`, `x.MAK` and the
    path-qualified `sub/Makefile` all resolve to `.make`
  - `Makefile.swift` → `.swift` and `.makeignore` → `.gitignore`
  - `makefiles` and `Makefile.inc` → nil
  - every pre-existing mapping is re-asserted unchanged where it neighbours the new names
- [ ] Tests, `FileIconTests` and `FileGlyphTests`: the new names and extensions.
- [ ] Tests, `CommentStyleTests` and `ToggleCommentEngineTests`: ⌘/ inserts and removes
  `# ` on a Makefile line.
- [ ] Tests, `SyntaxContextVocabularyTests` and `SyntaxContextScannerTests`: `#` comments
  at line start and mid-line, and no string context.
- [ ] Tests, `LanguageKeywordsTests`:
  - add `.make` to the documented-languages set
  - add a dedicated test pinning the exact list, and that `.PHONY`, `filter-out` and
    `-include` are absent
- [ ] Tests, `SymbolQueryTests`:
  - `testMakeSymbolsQueryUsesOnlyNodeNamesTheGrammarDeclares` against
    `declaredNodeTypes(vendoredPackage: "TreeSitterMake")`
  - add `.make` to the vendored union
  - change the predicate pin to the exact `{html: [match?], make: [not-match?]}` map,
    with the reason in the assertion message
- [ ] Run `swift test`.

### Task 3: The highlight query and its static gate

**Files:**
- Create: `Vendor/TreeSitterMake/queries/highlights.scm`
- Modify: `Vendor/TreeSitterMake/VENDORED.md`,
  `Tests/PisakaCoreTests/VendoredGrammarQueryTests.swift`

- [ ] Author `queries/highlights.scm` adapted from upstream at the pin. Each edit is
  marked in the file and listed in `VENDORED.md`:
  - drop `@spell`
  - automatic variables (`$@`, `$<`, …) → `@variable.builtin`
  - recipe `@` prefix → `@operator`
  - assignment/define names → `@variable`
  - `variable_reference` word → `@variable`, keeping `$`/`(`/`)` as `@operator`
- [ ] Keep these from upstream: `@comment`, `@keyword*`, `@function` (targets and
  `.PHONY` prerequisites), `@function.builtin`, `@operator`, `@string.special.path`
  (include filenames), `@variable.builtin`, `@punctuation.special`.
- [ ] Every capture must resolve to a non-`.plain` `SyntaxTokenKind` with no change to
  Core's map. State in the header comment that both failure modes are silent.
- [ ] Extend `VendoredGrammarQueryTests` with the make pair:
  - node names and literals declared under the matching `named` flag
  - the emitted (non-auxiliary) capture set by equality, each non-`.plain`
- [ ] Add a node-name check for `queries/injections.scm`. A small helper overload reading
  that file is enough.
- [ ] Update the suite's doc comment inventory.
- [ ] Fill in `VENDORED.md`'s Verification section:
  - two fixtures: an ordinary Makefile; and one with conditionals, `define`/`endef`,
    `!=`, target-specific variables, pattern rules, automatic variables and
    `$(shell …)`/`$(patsubst …)`
  - the harness recipe: a throwaway SwiftPM package that prints every capture plus the
    count of uncaptured non-whitespace offsets outside recipe bodies
  - the observed capture table
  - the note that `swift test` automates only the static half
- [ ] Run the harness and record the result.
- [ ] Run `swift test`.

### Task 4: App-layer registration and the executed symbols query

**Files:**
- Modify: `Sources/Pisaka/SyntaxLanguageConfiguration.swift`,
  `Sources/Pisaka/Platform/SymbolExtractor.swift` (doc comment)
- Create: `Tests/PisakaAppTests/MakeSymbolQueryTests.swift`,
  `Tests/PisakaAppTests/Fixtures/make-symbols.mk`

- [ ] Add `import TreeSitterMake` with the "fifth vendored grammar, see its
  `VENDORED.md`" comment. Finalise the `.make` arm (`name: "Make"` → bundle
  `TreeSitterMake_TreeSitterMake`) with a short comment.
- [ ] Update `SymbolExtractor`'s "exactly one query needs predicates" paragraph to name
  Make's special-target filter as the second.
- [ ] Add `MakeSymbolQueryTests`, modelled on `ShellSymbolQueryTests`:
  - the configuration and `SymbolQueryCatalog.query(for: .make)` load
  - extraction over the fixture yields exactly the expected targets (`build`, `test`,
    `lint`, …) and variables, by set equality
  - `.PHONY`, `.SUFFIXES` and `%.o` are absent, which proves the predicate is evaluated
  - a `$(VAR):` target is not captured
  - the configuration's injection query loads, and
    `configuration(forInjectionName: "bash")` resolves
- [ ] Run `xcodegen generate`, then
  `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`.
- [ ] Run the macOS `-configuration Release` build and the iOS `generic/platform=iOS`
  build.
- [ ] Confirm `Package.resolved` is unchanged (a path dependency carries no pin). If it
  is rewritten, regenerate it rather than hand-edit, and re-run `DependencyPinTests`.
- [ ] Run `swift test`.

### Task 5: Verify acceptance criteria

- [ ] Run `swift test` fully green, including:
  - `VendoredGrammarQueryTests`, `SymbolQueryTests`, `LanguageKeywordsTests`,
    `LicenseCoverageTests`, `DependencyPinTests`
  - `SyntaxLanguageTests`, `FileIconTests`, `CommentStyleTests`
- [ ] Run `swift build --package-path Vendor/TreeSitterMake`.
- [ ] Run the app-bundle `xcodebuild … test`, the macOS Release build and the iOS device
  build.
- [ ] Run `swiftlint --strict` from the repository root; it must be clean.
- [ ] Confirm nothing was touched in: the LSP registry (beyond the `lspLanguageID` arm),
  the provisioning manifest, `PrivacyInfo.xcprivacy`, the indentation rules or the save
  transforms.
- [ ] Confirm every new test fails when its subject is reverted.

### Task 6: Update documentation

- [ ] `README.md`: add Makefiles to the syntax-highlighting language list (line ~121).
- [ ] `docs/FEATURES.md`: add Make to each enumeration:
  - comment toggle
  - highlighting (~809)
  - the file-name resolution list (~813: `Makefile`, `GNUmakefile`, `*.mk`)
  - keyword completion (~289)
  - indexed symbols (~470: "Makefile targets and variables")
  - Dockerfile-style definition lines (~427)
- [ ] `docs/architecture/core-editor.md`:
  - `SyntaxLanguage.swift`: the new names and extensions, and why there is no prefix rule
  - `FileIcon.swift` and `FileGlyph.swift`
  - `CommentStyle.swift`
  - `SyntaxContextVocabulary`: the `#` anchor and its non-models
- [ ] `docs/architecture/core-intelligence.md`:
  - the Make keyword list, its sourcing and its identifier-shape exclusions
  - the symbols query: targets as `.target`, the special/pattern-target predicate (now
    the second predicate-bearing query), and unanchored variables
  - the new `SymbolKind.target` and its badge
- [ ] `docs/architecture/app-editor-overlays.md`: the `SyntaxLanguageConfiguration` entry
  gains the fifth vendored grammar and the bash recipe injection.
- [ ] `docs/architecture/core-services.md`: the required-reason audit record gains the
  Make grammar's result.
- [ ] `CLAUDE.md`:
  - "four tree-sitter grammars" → five in the `project.yml` and `Vendor/` bullets
  - add `TreeSitterMake` to the package list
  - the Vendor-only and "Four … are vendored … for four different reasons" convention
    sentences become five, with this one's reason in one clause
  - the Tests paragraph's "the one that executes a shipped tree-sitter query" becomes
    plural
  - stay under the 60,000-character cap
- [ ] Run `swift test`; `LintConfigurationTests` holds the CLAUDE.md size.

## Post-Completion (manual: load-bearing, cannot be automated)

The language convention requires opening a file of the new language in a **DEBUG
build**. Both of a query's failure modes are silent, and `SymbolQueryCatalog`'s DEBUG
assertion is the only thing that sees a broken symbols query.

1. Run the `VENDORED.md` harness on both fixtures and confirm the capture tables match.
2. In a DEBUG build, open this repository's `Makefile`:
   - comments, variable assignments, targets, `$(…)` references and `.PHONY` are
     distinctly coloured
   - recipe lines are highlighted as shell
   - the file is not plain text
   - the bottom bar reads "Makefile"
3. Confirm no `SymbolQueryCatalog` assertion fires, and ⌃⌘J lists `help`, `setup`,
   `hooks`, `test`, `lint`, `build`, … but not `.PHONY`.
4. ⌘/ toggles `#` on a line.
5. Typing `patsu` offers `patsubst`.
6. Open `GNUmakefile`, `makefile` and `rules.mk` copies and confirm they highlight the
   same way, while `Makefile.swift` and `.makeignore` do not.
7. Record in the archived plan that this DEBUG check was done.
