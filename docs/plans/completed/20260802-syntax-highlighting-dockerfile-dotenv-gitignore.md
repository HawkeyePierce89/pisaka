# Syntax highlighting for Dockerfile, .env and .gitignore

## Overview

Add three new languages to `SyntaxLanguage` (dockerfile, dotenv, gitignore) resolved by *file name* (not extension alone), wire up two ready-made SPM grammars (camdencheek/tree-sitter-dockerfile v0.2.0, pnx/tree-sitter-dotenv v1.1.1), and vendor the third as a local SPM package `Vendor/TreeSitterGitignore/` (upstream shunsambongi/tree-sitter-gitignore, MIT — it ships neither `bindings/swift` nor `queries/highlights.scm`, so the Swift header and the highlight query are written here). The view layer gets three new mappings in `SyntaxLanguageConfiguration` following the existing pattern.

> **Superseded during Task 5 — dotenv is vendored too.** The remote
> `tree-sitter-dotenv` package does not link (its manifest omits `src/scanner.c`
> for a grammar that declares an external scanner), so it was vendored as
> `Vendor/TreeSitterDotenv/` as well. The delivered state is therefore **one**
> remote grammar (dockerfile) and **two** local path dependencies. Every mention
> of a remote dotenv pin below — Overview above, Context, Task 3 — predates that
> discovery; the Task 5 note records the change.

The gitignore rule is a *shape*, not a name list: a lowercased file name that starts with `.` and ends with `ignore` resolves to `.gitignore` — so `.gitignore`, `.dockerignore`, `.npmignore`, `.eslintignore`, `.prettierignore` and a bare `.ignore` are all covered by one rule, while `foo.ignore` (no leading dot — this is a dot-file convention, not an extension), `gitignore` and `ignore` are not. It runs *after* the exact-name and extension phases, so the `.env.json` → `.json` pin is unaffected.

Because the gitignore query is ours, it gets its own verification task: both of its failure modes are silent in the app. An unknown *node name* makes the query fail to compile, so `LanguageConfiguration` throws, `makeConfiguration` returns `nil`, and the file falls back to plain text; a mistyped *capture name* compiles fine and resolves to `SyntaxTokenKind.plain`, i.e. default-colored text. Neither is caught by "the file looks highlighted".

## Context

- Files involved:
  - `Sources/PisakaCore/SyntaxLanguage.swift` — enum + `extensionMap` + `init(forFileName:)` (currently extension-only: `(fileName as NSString).pathExtension`, so `.env`/`.gitignore` yield an empty extension and `Dockerfile` yields none)
  - `Tests/PisakaCoreTests/SyntaxLanguageTests.swift` — including `testEveryCaseIsReachableByExtension` (breaks on the new cases; must be rewritten as reachability "by name OR extension")
  - `Sources/PisakaCore/SyntaxTokenKind.swift` — longest-prefix capture-name mapping (`comment`, `string`, `operator`, `punctuation`, `keyword` are already mapped)
  - `Sources/Pisaka/SyntaxLanguageConfiguration.swift` — `makeConfiguration(for:)`, lazy cache, `bundleName:` fallback (markdown_inline precedent)
  - `project.yml` — `packages:` and `targets.Pisaka.dependencies`
  - `Pisaka.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` — committed (per `.gitignore`)
  - `CLAUDE.md`, `README.md` (the supported-language list)
  - New: `Vendor/TreeSitterGitignore/` (Package.swift, src/, bindings/swift/, queries/, LICENSE, VENDORED.md) — and, per the Task 5 deviation, `Vendor/TreeSitterDotenv/` in the same shape
- Related patterns:
  - Grammar SPM layout — the exact shape of `SourcePackages/checkouts/tree-sitter-json/Package.swift`: `path: "."`, `sources: ["src/parser.c"]`, `resources: [.copy("queries")]`, `publicHeadersPath: "bindings/swift"`, `cSettings: [.headerSearchPath("src")]`, `cLanguageStandard: .c11`. The resource bundle is named `TreeSitter<Name>_TreeSitter<Name>.bundle` — loading `highlights.scm` in `LanguageConfiguration(name:)` depends on this.
  - `SyntaxLanguageConfiguration` is not `@MainActor`; its cache is `NSLock`-guarded — new cases are just added to the `switch`.
  - `PisakaCore` stays Foundation-only; grammars live in the app target only.
- Dependencies: as planned, two new remote packages (exact pins) and one local path dependency with no external dependencies of its own; as delivered (Task 5 deviation), **one** remote package and **two** local path dependencies.

## Development Approach

- **Testing approach**: TDD for Core (resolution tests written and failing before the implementation); vendoring/build work is verified via `swift build`/`xcodebuild`; the hand-written gitignore query is verified by a throwaway SwiftTreeSitter harness that asserts capture-per-element.
- Every task ends with a fully green `swift test` before moving on.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**
- Manual in-app checks live in Post-Completion (not agent-automatable).

## Implementation Steps

### Task 1: Core — resolve Dockerfile/.env/.gitignore (TDD)

**Files:**
- Modify: `Tests/PisakaCoreTests/SyntaxLanguageTests.swift`
- Modify: `Sources/PisakaCore/SyntaxLanguage.swift`

- [x] Tests first (must fail): positive — `Dockerfile`, `DOCKERFILE`, `Dockerfile.dev`, `Dockerfile.prod`, `web.dockerfile`, `.env`, `.env.local`, `.env.production`, `.gitignore`, `.dockerignore`, `.npmignore`, `.eslintignore`, `.prettierignore`, `.ignore`
- [x] Negative tests: `env`, `myenv.txt`, `envfile`, `Dockerfileish`, `foo.ignore` (no leading dot), `gitignore` (no dot), `ignore`
- [x] Rule-precedence test: exact name → extension → prefix/shape (pins: `.env.json` resolves to `.json`, `Dockerfile.dev` to `.dockerfile`) — the dot-ignore shape rule runs last so it can never shadow an earlier phase
- [x] Raw-value stability test: `SyntaxLanguage(rawValue: "dockerfile"/"dotenv"/"gitignore")` is non-`nil` (raw values are consumed by `configuration(forInjectionName:)` for fenced blocks)
- [x] Rewrite `testEveryCaseIsReachableByExtension` as `testEveryCaseIsReachableByFileName` — cover all `allCases` through a set of file *names* (not extensions only), so a future case with no resolution rule fails
- [x] Implementation: three new cases; `extensionMap` gains `"dockerfile": .dockerfile`; a private `exactFileNameMap` (`dockerfile`, `.env`), private prefix rules (`dockerfile.`, `.env.`), and the gitignore shape rule — lowercased name `hasPrefix(".") && hasSuffix("ignore")`, with a length guard so the two can't overlap on a single token — applied by `init(forFileName:)` in the order "exact name → extension → prefix → dot-ignore shape"
- [x] Update the type's doc comments: resolution is now by file name, not by extension alone; state the gitignore shape rule and why it is a shape rather than a name list (one syntactic family, dot-file convention)
- [x] `swift test` — fully green (960 tests, 0 failures)

### Task 2: Vendor the gitignore grammar

**Files:**
- Create: `Vendor/TreeSitterGitignore/Package.swift`
- Create: `Vendor/TreeSitterGitignore/src/parser.c`, `src/tree_sitter/parser.h` (+ `src/scanner.c` if upstream has one), `src/grammar.json`, `src/node-types.json`
- Create: `Vendor/TreeSitterGitignore/grammar.js` (copied verbatim — the `tree-sitter` CLI fallback in Task 4 needs it, and it documents the node names)
- Create: `Vendor/TreeSitterGitignore/bindings/swift/TreeSitterGitignore/gitignore.h`
- Create: `Vendor/TreeSitterGitignore/queries/highlights.scm`
- Create: `Vendor/TreeSitterGitignore/LICENSE`, `Vendor/TreeSitterGitignore/VENDORED.md`

- [x] Clone shunsambongi/tree-sitter-gitignore, record the default-branch SHA (`f4685bf11ac466dd278449bcfe5fd014e94aa504`, `main`, 2022-05-04); copy `src/`, `grammar.js` and `LICENSE` (MIT); upstream has **no** `src/scanner.c`, so `sources:` lists only `src/parser.c`
- [x] `Package.swift` in the tree-sitter-json shape (name/target `TreeSitterGitignore`, `path: "."`, `sources: ["src/parser.c"]`, `resources: [.copy("queries")]`, `publicHeadersPath: "bindings/swift"`, `cSettings: [.headerSearchPath("src")]`, `cLanguageStandard: .c11`), no testTarget, no external dependencies
- [x] Write `bindings/swift/TreeSitterGitignore/gitignore.h` modeled on `json.h` (declaring `const TSLanguage *tree_sitter_gitignore(void);`)
- [x] Write `queries/highlights.scm` against the node names read out of the copied `src/node-types.json` (do **not** guess them), with capture names restricted to the already-mapped `SyntaxTokenKind` set. Target four visually distinct classes: comment node → `@comment`; negation `!` → `@operator`; wildcards `*` / `**` / `?` → `@operator`; ordinary pattern body → `@string`; directory separator → `@punctuation.delimiter`. Bracket expressions are covered too (`[`/`]` → `@punctuation.bracket`, `bracket_negation` and the range `-` → `@operator`, the character nodes → `@string`) so no element is left uncaptured. Confirmed to **compile** against the vendored grammar via a throwaway `Query(language:data:)` harness; the element-by-element capture table is Task 4
- [x] Record in `VENDORED.md`: upstream URL, exact SHA, date, upstream license (MIT, file `LICENSE`), an explicit note that `bindings/swift/` and `queries/highlights.scm` are written in this repo (not upstream), the verification fixture + expected capture table from Task 4, and a step-by-step update procedure (which files to re-copy, which to keep, and that Task 4's verification must be re-run after any update)
- [x] Build the package in isolation: `swift build --package-path Vendor/TreeSitterGitignore` — clean
- [x] `swift test` at the repo root — still green (960 tests, 0 failures; the vendored package must not leak into the root manifest)

### Task 3: project.yml — three new dependencies and pins

**Files:**
- Modify: `project.yml`
- Modify: `Pisaka.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (regenerated)

- [x] Add to `packages:`: `tree-sitter-dockerfile` (`exactVersion: "0.2.0"`), `tree-sitter-dotenv` (`exactVersion: "1.1.1"`), and the local `TreeSitterGitignore` (`path: Vendor/TreeSitterGitignore`) — with a comment on why gitignore is local
- [x] Add three matching `package:`/`product:` entries to `targets.Pisaka.dependencies` (confirm exact product names against the resolved checkouts): `TreeSitterDockerfile`, `TreeSitterDotenv`, `TreeSitterGitignore`
- [x] `xcodegen generate` + `xcodebuild -project Pisaka.xcodeproj -resolvePackageDependencies -clonedSourcePackagesDirPath SourcePackages`
- [x] Confirm from `SourcePackages/checkouts/`: module names, C entry points, and that `queries/highlights.scm` is present in both packages. Confirmed — modules/products `TreeSitterDockerfile` / `TreeSitterDotenv`; headers `bindings/swift/TreeSitterDockerfile/dockerfile.h` declares `extern TSLanguage *tree_sitter_dockerfile();` (**non-const** return, no `void` parameter list) and `bindings/swift/TreeSitterDotenv/dotenv.h` declares `const TSLanguage *tree_sitter_dotenv(void);`; both ship `queries/highlights.scm` (dockerfile also has `src/scanner.c`, which its own manifest lists — Task 5 note: the dockerfile entry point's non-const return may need a cast at the `LanguageConfiguration` call site)
- [x] Verify the updated `Package.resolved` carries the new pins and is staged for commit (a local path dependency adds no pin) — `TreeSitterDockerfile` @ 0.2.0 (`868e44ce378deb68aac902a9db68ff82d2299dd0`), `TreeSitterDotenv` @ 1.1.1 (`8b1dad881974a7c1a7e3cb1f55b3a9b38ddec3ec`); no `TreeSitterGitignore` entry, as expected for a path dependency
- [x] `swift test` — green (Core untouched, no regression: 960 tests, 0 failures)

### Task 4: Verify the hand-written gitignore query element by element

**Files:**
- Modify: `Vendor/TreeSitterGitignore/queries/highlights.scm` (fixes found by the check)
- Modify: `Vendor/TreeSitterGitignore/VENDORED.md` (record the fixture and the confirmed capture table)
- Modify (conditionally): `Tests/PisakaCoreTests/SyntaxTokenKindTests.swift`

- [x] Static cross-check first: extract every node identifier and anonymous literal used in `queries/highlights.scm` and assert each is present in `src/node-types.json` (named types plus the `named: false` children entries); any leftover is a typo — fix before proceeding. Clean: 15 named nodes + 3 anonymous literals (`-`, `[`, `]`), zero leftovers, no fix needed
- [x] Build a throwaway SwiftPM package in a temp dir (not committed) that path-depends on `Vendor/TreeSitterGitignore` and on the resolved `SourcePackages/checkouts/SwiftTreeSitter`, loads `queries/highlights.scm` through `Query(language:data:)`, parses this fixture, and prints every `(capture name, matched text)` pair (also needed a declared-but-unused path dependency on `SourcePackages/checkouts/tree-sitter` so SwiftTreeSitter's own remote dependency resolves offline; query compiled: 15 patterns, 5 captures):

      ```
      # a comment
      node_modules/
      !keep.log
      *.log
      **/build
      ```

- [x] Assert the printed pairs element by element — a compile failure of the query (unknown node name) fails loudly here instead of degrading to plain text in the app. All confirmed, plus `/` → `punctuation.delimiter`; a second fixture (`?.log`, `[abc]/x`, `[!a-z].txt`, `[[:digit:]]`, `a\ b/c`) covers the `?`/bracket/escape patterns fixture A never reaches, equally silent if broken:
  - `# a comment` → `comment`
  - `!` in `!keep.log` → `operator`
  - `*` in `*.log` and `**` in `**/build` → `operator`
  - `node_modules`, `keep.log`, `build` (the pattern bodies) → `string` (one one-character capture per character — `pattern_char`'s rule is `/[^\n/*?]/`)
  - every element above is captured by *something* — an uncaptured pattern body means the query silently renders default-colored. The harness reports uncovered non-newline offsets: **0** for both fixtures
- [x] Run each observed capture name through `SyntaxTokenKind(captureName:)` and assert the resulting kinds are the intended, mutually distinct ones (`.comment` / `.operator` / `.string` / `.punctuation`) — this is what catches a mistyped capture name, which compiles fine and resolves to `.plain`
- [x] Add `SyntaxTokenKindTests` cases pinning exactly the capture names this query emits → their expected kinds (only the ones not already covered) — `testVendoredGitignoreQueryCaptureNamesResolve` pins all five (`comment`, `operator`, `string`, `punctuation.delimiter`, `punctuation.bracket`), asserts none resolves to `.plain`, and asserts the four kinds stay mutually distinct; every name already resolved, so no Core mapping change was needed
- [x] Copy the fixture and the confirmed capture table into `VENDORED.md` as the re-verification recipe; delete the temp package
- [x] Fallback if the harness can't be stood up: run `tree-sitter query queries/highlights.scm <fixture>` with the copied `grammar.js` and assert the same table from its output; the static cross-check and the `SyntaxTokenKindTests` pins are mandatory either way — not needed (the harness ran; the `tree-sitter` CLI is not installed, and `VENDORED.md` records that as the reason the harness is the primary route)
- [x] `swift test` — green (961 tests, 0 failures)

### Task 5: View — mappings in SyntaxLanguageConfiguration

**Files:**
- Modify: `Sources/Pisaka/SyntaxLanguageConfiguration.swift`
- Modify (conditionally): `Sources/PisakaCore/SyntaxTokenKind.swift`, `Tests/PisakaCoreTests/SyntaxTokenKindTests.swift`

- [x] Add three `import`s and three branches in `makeConfiguration(for:)` following the existing pattern (`LanguageConfiguration(tree_sitter_x(), name: …)`); no sub-language injections — names `Dockerfile`/`Dotenv`/`Gitignore`; the dockerfile header's non-`const` `TSLanguage *` return needed no cast (it imports as `OpaquePointer!` like the others)
- [x] Build the macOS target and inspect the actual resource-bundle names inside the built `Pisaka.app` (`*_TreeSitter*.bundle`); if the name is not derivable from `name:` for the local package or for dockerfile/dotenv, pass an explicit `bundleName:` (the `markdown_inline` precedent) — all three came out as `TreeSitterDockerfile_TreeSitterDockerfile.bundle` / `TreeSitterDotenv_TreeSitterDotenv.bundle` / `TreeSitterGitignore_TreeSitterGitignore.bundle`, each carrying `queries/highlights.scm`, so the default `TreeSitter\(name)_TreeSitter\(name)` derivation holds and **no** `bundleName:` was needed
- [x] **Deviation from Task 3 — dotenv had to be vendored.** The first macOS link failed with five undefined `tree_sitter_dotenv_external_scanner_*` symbols: upstream `tree-sitter-dotenv` v1.1.1 declares an external scanner (`externals: [$._end_of_assignment]`) but its `Package.swift` `sources:` lists only `src/parser.c`, leaving `// NOTE: if your language has an external scanner, add it here.` where `src/scanner.c` belongs. The same omission is on upstream `main`, so no remote version links. Vendored the v1.1.1 tree verbatim as `Vendor/TreeSitterDotenv/` (parser + **scanner** + headers + `grammar.js` + upstream's own `bindings/swift` header and `queries/highlights.scm` + `LICENSE`, MIT) with a locally written manifest whose only substantive change is `src/scanner.c` in `sources:`; `VENDORED.md` records the SHA, the reason, and how to drop the directory and restore the remote pin if upstream fixes it. `project.yml` now uses `TreeSitterDotenv: path: Vendor/TreeSitterDotenv` and `Package.resolved` correspondingly lost its dotenv pin (path dependencies carry none) — the Task 3 pin note above is superseded for dotenv only; dockerfile is unchanged at 0.2.0
- [x] Read the real upstream `highlights.scm` of the dockerfile and dotenv grammars, extract the set of capture names, and run them through `SyntaxTokenKind(captureName:)`; add missing prefixes to the Core mapping only if they actually occur (gitignore's captures are already pinned in Task 4) — dockerfile emits `keyword`, `operator`, `comment`, `punctuation.special`, `string`, `constant`, `none`; dotenv emits `keyword`, `operator`, `comment`, `constant`, `number`, `string`, `variable`. Every one already resolves to its intended kind, so **the Core mapping is unchanged**. `@none` is the one that resolves to `.plain`, which is correct: it is tree-sitter's "deliberately not highlighted" capture, used on `(expansion)` so only `$`/`{`/`}` are colored
- [x] If the Core mapping changed — add `SyntaxTokenKindTests` cases for every new capture name (real grammar name → expected kind) — mapping unchanged, so no new prefixes; added the pins anyway (the names are load-bearing and nothing else guards them): `testDockerfileGrammarQueryCaptureNamesResolve`, `testDotenvGrammarQueryCaptureNamesResolve` (both asserting no name resolves to `.plain`, dotenv additionally that key/`=`/value stay three distinct kinds) and `testNoneCaptureNameStaysPlain` pinning `@none` → `.plain` as intentional
- [x] `swift test` — green (964 tests, 0 failures) and `xcodebuild … -destination 'platform=macOS' build` — **BUILD SUCCEEDED**

### Task 6: Verify acceptance criteria

- [x] `swift test` — full run green (964 tests, 0 failures)
- [x] `xcodegen generate` (clean generation, no errors)
- [x] macOS build: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -clonedSourcePackagesDirPath SourcePackages -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` — **BUILD SUCCEEDED**
- [x] iOS build (the cross-platform linking check for the three new grammars): same command with `-destination 'generic/platform=iOS'` — **BUILD SUCCEEDED** (so the vendored dotenv scanner and the vendored gitignore parser link on the device arch too, not just macOS)
- [x] Confirm the built macOS app contains the resource bundles of all three new grammars — `Pisaka.app/Contents/Resources/` carries `TreeSitterDockerfile_TreeSitterDockerfile.bundle`, `TreeSitterDotenv_TreeSitterDotenv.bundle` and `TreeSitterGitignore_TreeSitterGitignore.bundle`, each with `Contents/Resources/queries/highlights.scm` present (the file `LanguageConfiguration(name:)` loads)

### Task 7: Update documentation

**Files:**
- Modify: `CLAUDE.md`, `README.md`

- [x] `CLAUDE.md`, the `SyntaxLanguage.swift` entry: three new cases and the exact name-resolution rules — the "exact name → extension → prefix → dot-ignore shape" order, and the gitignore rule stated as its shape (leading `.` + trailing `ignore`, lowercased), with the negatives that keep it honest (`foo.ignore`, `gitignore`, `ignore`) and the note that running it last is what preserves the `.env.json` → `.json` pin (also `.eslintignore.md` → `.markdown`, and the rewritten `testEveryCaseIsReachableByFileName` guard)
- [x] `CLAUDE.md`, `Conventions`: the one new remote grammar with its pin (dockerfile 0.2.0); a separate paragraph on the vendoring pattern covering **both** local packages and their *different* reasons — gitignore because upstream ships no SwiftPM manifest/binding/queries at all (so `bindings/swift` and `highlights.scm` are ours, both failure modes of a hand-written query are silent in the app, and the per-element verification recipe in `VENDORED.md` must be re-run on every grammar update), dotenv because upstream's manifest omits `src/scanner.c` for a grammar that has an external scanner and so fails to link (verbatim copy of v1.1.1 + a one-line manifest fix; drop it for the remote pin if upstream fixes theirs) — plus where `VENDORED.md` lives, that a path dependency carries no `Package.resolved` pin, and how to update by hand
- [x] `CLAUDE.md`, the `SyntaxLanguageConfiguration.swift` entry: three new mappings, no injections (and no `bundleName:` — the default `TreeSitter<name>_TreeSitter<name>` derivation holds for the local packages too; the dockerfile header's non-`const` return needed no cast)
- [x] `README.md`: extend the supported-language list (Dockerfile, .env, and dot-prefixed ignore files — `.gitignore`/`.dockerignore`/`.npmignore`/`.eslintignore`/…), noting that detection is by file name
- [x] `swift test` — green after the doc edits (964 tests, 0 failures)

## Post-Completion (manual check, macOS)

- Open `Dockerfile`, `Dockerfile.dev`, `.env`, `.env.local` from a real project — comments/keys/strings are colored and the minimap is colored too.
- Open a `.gitignore` containing all four element classes and check them individually, not just "it looks colored": the `#` comment is dimmed, `!` on a negation and `*`/`**` are in the operator color, an ordinary pattern is in the string color, and no line is left in the default text color (default color everywhere = the query silently failed to compile).
- Open a `.dockerignore` (or `.eslintignore`) and confirm it highlights the same way — the shape rule, not a name list.
- Confirm `env` and `foo.ignore` stay plain text.

## Code-review follow-ups (applied after Task 7)

- Task 1's dot-ignore *length guard* turned out to be unreachable — a six-character
  name ending in `ignore` **is** `ignore`, which fails the leading-dot test — and its
  stated rationale ("the two ends can't overlap") described a state that cannot
  occur. Removed; the rule is now `hasPrefix(".") && hasSuffix("ignore")` and the
  leading dot is documented as what makes `.ignore` the shortest match. Behavior
  and tests unchanged.
- `init(forFileName:)` now matches the argument's **last path component**. Phases 1,
  3 and 4 compared the whole string while phase 2 (`NSString.pathExtension`) already
  read the last component, so a caller passing a path would have got highlighting
  for `backend/app.ts` but plain text for `backend/.env` — a partial, per-language
  silent failure. Every live call site passes a `lastPathComponent` today, but two
  derive it from `ChangedFile.path`. Pinned by `testPathsResolveByTheirLastComponent`.
- Task 4's / Task 5's capture-name pins were hardcoded restatements of the queries:
  they never read the `.scm` files, so they could not detect the drift they were
  written for. Replaced for the two **in-repo** queries by
  `Tests/PisakaCoreTests/VendoredGrammarQueryTests.swift`, which reads each vendored
  `queries/highlights.scm` and `src/node-types.json` through `#filePath` and asserts
  (a) every node name and anonymous literal the query uses is declared by the grammar
  — the static half of the `VENDORED.md` recipe, now automated, catching a
  grammar-update rename before it ships as plain text — and (b) the emitted capture
  set is exactly the expected one, each name non-`.plain`. Both checks were
  mutation-tested (renamed node, mistyped capture, unknown literal → all fail).
  The dockerfile query is a remote dependency and unreadable from Core, so its names
  stay pinned by hand in `SyntaxTokenKindTests`.
- `Package.resolved` had been rewritten from SwiftPM's v2 schema into the legacy v1
  shape (all 304 lines churned, hiding the one real change). Restored to v2 with only
  the `tree-sitter-dockerfile` 0.2.0 pin added; `xcodebuild -resolvePackageDependencies`
  re-resolves all 20 packages against it and leaves it byte-identical.
- Docs: `CLAUDE.md` and `Package.swift` claimed *every* dependency is version-pinned,
  which the two path dependencies contradict; `CLAUDE.md`'s project layout gained the
  `Vendor/` directory. `Vendor/TreeSitterGitignore/VENDORED.md`'s update procedure
  gained an **ABI check** — the vendored parser is ABI 13, exactly the pinned
  tree-sitter 0.25.10's `TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION`, so a runtime
  bump would silently reject the grammar.

Still open (deliberately not done here): nothing verifies at **build or test time**
that the grammars load and their resource bundles ship — `configuration(for:)`
swallows every failure into `nil` → plain text, and there is no test target in
`project.yml`. A CI step asserting each `TreeSitter*_TreeSitter*.bundle` in the built
app contains `queries/highlights.scm`, or a small XCTest target walking
`SyntaxLanguage.allCases` through `configuration(for:)`, would close it for all
twelve languages. That is new CI/project infrastructure and belongs in its own plan.

## Out of scope

- Ignore-style files that do *not* follow the dot-file convention (e.g. a plain `ignore` or `foo.ignore`) — deliberately unmatched.
- Automating updates of the vendored grammar.
