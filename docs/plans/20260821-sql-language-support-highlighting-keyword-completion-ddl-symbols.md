# SQL language support: highlighting, keyword completion, DDL symbols

## Overview

Add SQL as the editor's fifteenth language, end to end through the repo's
add-a-language checklist: tree-sitter grammar, highlighting, keyword
completion, and symbol indexing of DDL declarations. A `.sql` file gets an
icon, colors, SQL keyword completion, and its `CREATE TABLE` / `CREATE VIEW` /
`CREATE FUNCTION` names in the symbol index, so ⌃⌘J lists them and
go-to-definition jumps to them from another `.sql` file.

## Context

### The grammar must be **vendored**, not pinned remotely

The ticket asked to verify the upstream SwiftPM manifest before committing to
the remote path, and pre-authorized vendoring if it is broken the way dotenv's
was. It is broken — worse than dotenv's, and in two independent ways. Verified
against `DerekStride/tree-sitter-sql` at tag `v0.3.11`
(`7b51ecda191d36b92f5a90a8d1bc3faef1c7b8b8`) and at `main`:

1. **`src/parser.c` is not in the repository.** `.gitignore` carries
   `/src/parser.c`, `/src/tree_sitter/` and `/src/*.json`, so the tagged tree
   contains `src/scanner.c` alone. The manifest's `sources:` names
   `src/parser.c` — SwiftPM reports
   `warning: Invalid Source '…/src/parser.c': File not found.` and the target
   builds to nothing. (Unlike dotenv, whose `sources:` was merely *missing* a
   file, this one *names a file that does not exist*.)
2. **The manifest is a hard SwiftPM error.** Its test target depends on a
   `SwiftTreeSitter` product from `tree-sitter/swift-tree-sitter` without an
   explicit `.product(name:package:)`:
   `error: dependency 'SwiftTreeSitter' in target 'TreeSitterSqlTests' requires
   explicit declaration`. That dependency also vends a product named
   `SwiftTreeSitter` — the same product name ChimeHQ's `SwiftTreeSitter`
   (already in this graph, via Neon) vends, from a different package identity.

Both were reproduced locally with `swift build`. Vendoring under `Vendor/` per
the existing convention is therefore the plan, exactly as the ticket
pre-authorized. The generated sources come from the **npm tarball at the
matching version** (`@derekstride/tree-sitter-sql@0.3.11`), which ships
`src/parser.c`, `src/tree_sitter/{parser,array,alloc}.h`, `src/node-types.json`,
`src/grammar.json`, `queries/` and `LICENSE`. Verified byte-identical to git tag
`v0.3.11` for `grammar.js` and `queries/highlights.scm`.

A prototype `Vendor/TreeSitterSql` built clean (`swift build`, ~1s,
`Build complete!`). `src/parser.c` is 17 MB of generated tables but only
~1.0 MB git-compressed together with the two JSON files, against a 14 MB
`.git` today.

**Consequence for the ticket's requirements:** the `project.yml` `exactVersion:`
pin and the `Package.resolved` entry do *not* apply — a `path:` dependency
carries no pin, which `DependencyPinTests` already handles explicitly
(`guard let url = package.url else { continue } // a Vendor/ path dependency`).
The pin becomes the directory content plus the SHA recorded in `VENDORED.md`,
which
`LicenseCoverageTests.testEveryVendoredEntryRecordsTheSHAItsVendoredDocDoes`
cross-checks against `licenses.json`.

**Second consequence, a gain:** because the query lives in this repository, the
highlight query falls under `VendoredGrammarQueryTests` (node names, anonymous
literals and field names checked against the grammar's own `node-types.json`,
capture set by equality) instead of the hand-pinned tables in
`SyntaxTokenKindTests` that the remote grammars use. That is strictly stronger.

### Verified findings that shape the implementation

Run against the v0.3.11 tree with `tree-sitter-cli@0.25.10`:

- **Highlight query, static half already passes.** Every named node the query
  uses is declared in `node-types.json`; all four field names (`alias`, `name`,
  `parameter`, `value`) are declared; the only unmatched string literals are the
  two `#match?` regex arguments, which `ParsedQuery` already treats as strings
  rather than nodes.
- **Highlight query, runtime half already passes.** `tree-sitter query
  queries/highlights.scm` compiles and captures against a real `.sql` fixture.
- **21 capture names emitted**, of which four do not resolve today:
  - `conditional` (CASE/WHEN/THEN/ELSE) → `.plain` — must map to `.keyword`
  - `storageclass` (TEMP/UNLOGGED/MATERIALIZED/…) → `.plain` — must map to `.keyword`
  - `field` (column names in `column_definition`) → `.plain` — must map to `.property`
  - `spell` — the conventional spellcheck marker, emitted *in addition to*
    `@comment` on the same node (`(comment) @comment @spell`). It must stay
    `.plain`, on the `@none` precedent already pinned in `SyntaxTokenKindTests`.
  - `type.qualifier` (NOWAIT/MAXVALUE/MINVALUE/STATISTICS/…) resolves to `.type`
    by prefix, which is wrong — these are keyword-shaped modifiers, not types.
    Plan maps it explicitly to `.keyword`. No other shipped grammar emits it
    (dockerfile/Go/Rust capture sets are pinned and do not contain it).
  - `attribute` (IMMUTABLE/STRICT/PARALLEL/…) resolves to `.property` today.
    Left alone deliberately: remapping it globally would recolor HTML attributes
    and Rust `#[derive(…)]`. Documented, not changed.
- **Symbols query prototype verified against the real parser.** All five
  patterns capture the bare `identifier` (so `public.users` yields `users` —
  identifier-shaped, as the completion-candidate rule requires):

  ```
  (create_table (object_reference name: (identifier) @definition.type))
  (create_view (object_reference name: (identifier) @definition.type))
  (create_materialized_view (object_reference name: (identifier) @definition.type))
  (create_type (object_reference name: (identifier) @definition.type))
  (create_function (keyword_function) . (object_reference name: (identifier) @definition.function))
  (create_table
    (object_reference name: (identifier) @container)
    (column_definitions (column_definition name: (identifier) @definition.property)))
  ```

  Two non-obvious points the query comment must record:
  - **`create_function` needs the anchor, the others must not have one.**
    `create_function` has a *second* direct `object_reference` child — the
    `custom_type:` field of `RETURNS <type>` — so an unanchored pattern would
    index the return type as a function. Anchoring immediately after
    `(keyword_function)` is exact, and survives `CREATE OR REPLACE`. The
    `create_table`/`create_view` rules cannot use the same anchor because
    `optional($._if_not_exists)` is a *hidden* rule whose `keyword_if`/
    `keyword_not`/`keyword_exists` children inline as visible siblings; they
    rely instead on the table/view name being the only direct `object_reference`
    child (verified: `CREATE TABLE copy_users AS SELECT * FROM users` captures
    `copy_users` only).
  - **`CREATE INDEX`, `CREATE SEQUENCE`, `CREATE TRIGGER`, `CREATE SCHEMA` and
    `CREATE ROLE` are deliberately not indexed** — none is a name anyone jumps
    to, and `create_index`'s object_reference is the *table*, which would file a
    duplicate table symbol under the wrong site.
- **Symbol kind mapping decided:** table, view, materialized view and custom
  type → `.type` (they are the named things a query refers to, which is what
  `.type` means everywhere else); function → `.function`; column → `.property`
  with the table as `@container`, following the Go struct-field precedent
  (`(type_spec name: … type: (struct_type … field_declaration …))`). No new
  `SymbolKind` case.
- **Keywords:** the grammar declares 356 `keyword_*` node types — far past
  "curated". The list is drawn *from that set* (not invented) under the rule the
  Go/Rust lists already state: an identifier belongs on a keyword list when no
  source file can ever declare it. In: statement/DDL/DML/clause vocabulary,
  built-in type names (`INT`, `TEXT`, `BOOLEAN`, `TIMESTAMP`, `NUMERIC`, …), the
  literals (`TRUE`/`FALSE`/`NULL`), constraint/permission vocabulary. Out:
  storage-format and engine dialect tokens (`PARQUET`, `ORC`, `RCFILE`, `AVRO`,
  `SEQUENCEFILE`, `TEXTFILE`, `JSONFILE`, `BIN_PACK`, `NOSCAN`, `ZEROFILL`,
  `LOW_PRIORITY`, `DELAYED`, …) and the rare function-attribute knobs. Spelled
  uppercase, as SQL is written; `FuzzyMatch` already has a case-insensitive
  prefix tier, so typing `sel` still matches `SELECT`.

### Files involved

- Create: `Vendor/TreeSitterSql/` (`Package.swift`, `VENDORED.md`, `LICENSE`,
  `grammar.js`, `src/`, `queries/`, `bindings/swift/TreeSitterSql/sql.h`)
- Create: `Resources/Queries/sql/symbols.scm`,
  `Resources/Licenses/TreeSitterSql.txt`
- Modify: `project.yml`, `Resources/Licenses/licenses.json`
- Modify: `Sources/PisakaCore/SyntaxLanguage.swift`, `FileIcon.swift`,
  `LanguageKeywords.swift`, `SyntaxTokenKind.swift`
- Modify: `Sources/Pisaka/SyntaxLanguageConfiguration.swift`
- Modify: `Tests/PisakaCoreTests/{VendoredGrammarQueryTests,SyntaxTokenKindTests,
  SyntaxLanguageTests,FileIconTests,LanguageKeywordsTests,SymbolQueryTests}.swift`
- Modify: `docs/architecture/core-editor.md`, `core-intelligence.md`, `CLAUDE.md`

## Development Approach

- **Testing approach**: Regular (code first, then tests) — except the two
  set-equality gates (`SymbolQueryTests`, `LanguageKeywordsTests`), which fail
  the moment the enum case exists and so pull their own implementation forward.
- Task 2 is deliberately one task and not four: adding `SyntaxLanguage.sql`
  breaks `SymbolQueryTests` and `LanguageKeywordsTests` by set equality until
  the query file and the keyword list exist, so they cannot be split without
  leaving the suite red at a task boundary.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Vendor the grammar and ship its license

**Files:**
- Create: `Vendor/TreeSitterSql/Package.swift`, `VENDORED.md`, `LICENSE`,
  `grammar.js`, `src/{parser.c,scanner.c,node-types.json,grammar.json}`,
  `src/tree_sitter/{parser.h,array.h,alloc.h}`,
  `queries/{highlights.scm,indents.scm}`,
  `bindings/swift/TreeSitterSql/sql.h`
- Create: `Resources/Licenses/TreeSitterSql.txt`
- Modify: `project.yml`, `Resources/Licenses/licenses.json`

- [x] fetch `@derekstride/tree-sitter-sql@0.3.11` from npm and the git tag
      `v0.3.11` (`7b51ecda191d36b92f5a90a8d1bc3faef1c7b8b8`); confirm
      `grammar.js` and `queries/highlights.scm` are byte-identical between the
      two before using either
- [x] copy the tree verbatim into `Vendor/TreeSitterSql/`: generated `src/`
      (from the tarball, since git ignores it), `queries/`, `grammar.js`,
      `LICENSE`, and `bindings/swift/TreeSitterSql/sql.h` (from the git tag —
      the tarball has no Swift binding)
- [x] author `Package.swift` on the `Vendor/TreeSitterDotenv` model: package and
      target both `TreeSitterSql` (so the resource bundle is
      `TreeSitterSql_TreeSitterSql`, which `LanguageConfiguration(name: "Sql")`
      derives), `path: "."`, `sources: ["src/parser.c", "src/scanner.c"]`,
      `.copy("queries")`, `publicHeadersPath: "bindings/swift"`,
      `cSettings: [.headerSearchPath("src")]`, `cLanguageStandard: .c11`, and
      **no dependencies and no test target** — dropping upstream's
      `swift-tree-sitter` test dependency, whose `SwiftTreeSitter` product name
      collides with ChimeHQ's already in this graph
- [x] write `VENDORED.md` on the dotenv/gitignore model: upstream URL, tag,
      commit SHA, commit date, vendored-on date, license line; **the two
      independent reasons** this is vendored (gitignored `src/parser.c` named in
      `sources:`; the test-target dependency that is a hard SwiftPM error) with
      the reproduced messages; what is verbatim vs. authored here (only
      `Package.swift`); that the generated `src/` comes from the npm tarball at
      the matching version and must be re-taken from there on every update; the
      by-hand update procedure incl. the manual runtime query check; and how to
      drop back to a remote pin if upstream ever fixes both defects
- [x] wire `project.yml`: a `TreeSitterSql: { path: Vendor/TreeSitterSql }`
      entry beside the two existing `path:` grammars, a target dependency
      `- package: TreeSitterSql / product: TreeSitterSql`, and a comment
      recording why this one is a path dependency
- [x] copy the verbatim `LICENSE` (MIT, © 2021 Derek Stride) to
      `Resources/Licenses/TreeSitterSql.txt`; check the upstream tree for
      vendored third-party code the way the tree-sitter/ICU precedent demands
      and append any notice found — note that `src/tree_sitter/*.h` are
      tree-sitter's own headers, already covered by the existing `tree-sitter`
      notice exactly as they are for dotenv/gitignore
- [x] add the `licenses.json` notice: id `TreeSitterSql`, origin
      `Vendor/TreeSitterSql`, `version: "v0.3.11"`, `revision` = the 40-hex SHA
      recorded in `VENDORED.md`, `spdx: "MIT"`, `file: "TreeSitterSql.txt"`
- [x] review the privacy manifest obligation: confirm `scanner.c` and
      `parser.c` reference no required-reason API (`nm -u` on the built object,
      per the `docs/architecture/core-services.md` audit record); record the
      result — no `PrivacyInfo.xcprivacy` change is expected
- [x] verify the package builds in isolation:
      `swift build --package-path Vendor/TreeSitterSql`
- [x] run `swift test` — `DependencyPinTests` (path dependency carries no pin),
      `LicenseCoverageTests` (vendored origin, real license source, SHA matches
      `VENDORED.md`) and `LicenseNoticeTests` must all pass

### Task 2: Core language wiring — enum case, icon, keywords, symbols query

**Files:**
- Modify: `Sources/PisakaCore/SyntaxLanguage.swift`, `FileIcon.swift`,
  `LanguageKeywords.swift`
- Create: `Resources/Queries/sql/symbols.scm`
- Modify: `Tests/PisakaCoreTests/{SyntaxLanguageTests,FileIconTests,
  LanguageKeywordsTests,SymbolQueryTests}.swift`

- [x] add `case sql` to `SyntaxLanguage` and `"sql": .sql` to `extensionMap`
      (extension phase only — SQL has no extensionless or prefix form)
- [x] add `"sql": FileIcon(symbolName: "cylinder.split.1x2", color: .blue)` to
      `FileIcon.extensionMap`, in the Data/config group
- [x] add the curated uppercase `sql` list to `LanguageKeywords` and route
      `case .sql` to it; keep it sorted and duplicate-free (both asserted); the
      doc comment states the sourcing rule (drawn from the grammar's 356
      `keyword_*` node types, filtered by "no source file can ever declare it"),
      what is deliberately excluded (storage-format/engine dialect tokens) and
      why the list is uppercase while `FuzzyMatch`'s case-insensitive prefix tier
      keeps lowercase typing working
- [x] write `Resources/Queries/sql/symbols.scm` with the six verified patterns,
      under the shared capture convention; the header comment records the kind
      mapping (table/view/materialized view/custom type → `type`, function →
      `function`, column → `property` with the table as `@container`), why
      `create_function` needs the `.` anchor and the others must not have one
      (the `_if_not_exists` inlining), that `object_reference name:` captures the
      bare identifier so `public.users` indexes as `users`, and which `CREATE`
      forms are deliberately not indexed and why
- [x] extend `SyntaxLanguageTests` with `.sql` resolution from `foo.sql`,
      `FOO.SQL`, and `path/to/schema.sql`
- [x] extend `FileIconTests` with the `.sql` icon
- [x] confirm `LanguageKeywordsTests` (set equality against `allCases`, sorted,
      duplicate-free, keywords-are-never-definitions) and `SymbolQueryTests`
      (query directory set equality, node/field/capture names, `SymbolKind`
      resolution) pass with no exception entry — SQL is indexable, so it must
      **not** appear in `SymbolIndexModel.unindexableLanguages`
- [x] run `swift test` — must pass before task 3

### Task 3: Highlighting — capture mapping and the vendored-query gate

**Files:**
- Modify: `Sources/PisakaCore/SyntaxTokenKind.swift`
- Modify: `Tests/PisakaCoreTests/VendoredGrammarQueryTests.swift`,
  `SyntaxTokenKindTests.swift`

- [x] add four `nameMap` entries with their reasons: `"conditional": .keyword`,
      `"storageclass": .keyword`, `"field": .property`, and
      `"type.qualifier": .keyword` (the last overrides the `type` prefix on
      purpose — `NOWAIT`/`MAXVALUE` are modifiers, not types; note that no other
      pinned grammar emits it)
- [x] leave `attribute` mapped to `.property` and record why in the same place:
      remapping it would recolor HTML attributes and Rust `#[derive(…)]`
- [x] add `testSqlQueryUsesOnlyNodeNamesTheGrammarDeclares` to
      `VendoredGrammarQueryTests` via the existing
      `assertHighlightQueryNodesAreDeclared(vendoredPackage:)` helper
- [x] add `testSqlQueryEmitsExactlyTheExpectedCaptureNames`: the 21 emitted
      names asserted by set equality, with
      `assertResolvesWithoutFallingBackToPlain` applied to the set **minus
      `spell`**, and a comment stating that `spell` staying `.plain` is the
      intended outcome on the `@none` precedent — it rides along with `@comment`
      on the same node, so nothing renders uncolored because of it
- [x] pin `SyntaxTokenKind(captureName: "spell") == .plain` in
      `SyntaxTokenKindTests`, beside the existing `none` pin, so a future
      "map everything" change cannot quietly give it a color
- [x] extend `SyntaxTokenKindTests` with the four new mappings, including that
      `type.qualifier` resolves to `.keyword` rather than to `.type` by prefix
- [x] run `swift test` — must pass before task 4

### Task 4: App-layer grammar registration and platform builds

**Files:**
- Modify: `Sources/Pisaka/SyntaxLanguageConfiguration.swift`

- [x] `import TreeSitterSql` beside the other grammar imports, with a comment
      noting it is the third vendored one and pointing at its `VENDORED.md`
- [x] add `case .sql: return try LanguageConfiguration(tree_sitter_sql(), name: "Sql")`
      to `makeConfiguration(for:)` — the switch is exhaustive, so the enum case
      from task 2 already forces this; comment that `name:` is `"Sql"` and not
      `"SQL"` because the resource bundle is `TreeSitterSql_TreeSitterSql`
- [x] `xcodegen generate`
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -configuration Release build`
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build`
      (the grammar must link on both destinations, like the existing ones)
- [x] confirm `Package.resolved` is unchanged by the path dependency; if
      `xcodebuild -resolvePackageDependencies` rewrites it, regenerate rather
      than hand-edit and re-run `DependencyPinTests`
- [x] run `swift test`

### Task 5: Update architecture documentation

**Files:**
- Modify: `docs/architecture/core-editor.md`,
  `docs/architecture/core-intelligence.md`, `CLAUDE.md`

- [x] `core-editor.md`: extend the `SyntaxLanguage.swift` and `FileIcon.swift`
      entries with SQL; add the `SyntaxTokenKind.swift` reasoning for the four
      new capture mappings, the `spell`/`none` exception and the deliberate
      non-change to `attribute`
- [x] `core-intelligence.md`: extend the `LanguageKeywords.swift` entry with the
      SQL list's sourcing and exclusion rules, and the symbols-query section
      with SQL's kind mapping, the `create_function` anchor, and the `CREATE`
      forms deliberately left unindexed
- [x] `CLAUDE.md`: update the vendoring convention paragraph — it currently says
      "Two tree-sitter grammars are vendored under `Vendor/`"; make it three and
      state SQL's reason in one clause (upstream ships no generated parser and
      its manifest is a hard SwiftPM error), without growing into an essay
- [x] run `swift test`

### Task 6: Verify acceptance criteria

- [x] `swift test` fully green, with `DependencyPinTests`,
      `VendoredGrammarQueryTests`, `SyntaxTokenKindTests`,
      `LanguageKeywordsTests`, `SymbolQueryTests` and `LicenseCoverageTests`
      all picking up SQL
- [x] `xcodegen generate` && macOS Release build && iOS `generic/platform=iOS` build
- [x] confirm no LSP registry, provisioning, manifest or `PrivacyInfo.xcprivacy`
      change was made

## Post-Completion (manual — load-bearing, cannot be automated)

The convention requires opening a file of the new language in a **DEBUG build**
on every grammar addition: a broken symbols query is silent (an unindexed file
looks like a file that declares nothing), and `SymbolQueryCatalog`'s DEBUG
assertion is the only thing that can see a query that no longer compiles.

1. Run a DEBUG build and open a `.sql` file containing `CREATE TABLE`,
   `CREATE VIEW`, `CREATE MATERIALIZED VIEW`, `CREATE TYPE … AS ENUM` and
   `CREATE OR REPLACE FUNCTION`, including a schema-qualified name
   (`public.users`) and an `IF NOT EXISTS` form.
2. Confirm highlighting renders — keywords, strings, comments, column names and
   `CASE`/`WHEN` all distinctly colored, nothing default-colored in bulk.
3. Confirm no `SymbolQueryCatalog` assertion fires.
4. ⌃⌘J lists the file's DDL names, with columns shown under their table.
5. Type `sel` and confirm `SELECT` is offered; type a table's prefix and confirm
   the table name is offered from the project index.
6. Go-to-definition on a table name referenced in a *second* `.sql` file jumps
   to its `CREATE TABLE`.
7. Confirm the project tree shows the SQL icon rather than the generic `doc`.
