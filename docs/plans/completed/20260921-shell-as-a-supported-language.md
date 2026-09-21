# Shell as a supported language

## Overview

Make a shell script a first-class source file: one new `SyntaxLanguage` case
(`.shell`), the remote `tree-sitter-bash` grammar pinned like every other remote
grammar, answers in all seven per-language tables the compiler and the
set-equality suites demand, a `symbols.scm` under the shared capture convention,
an **app-layer suite that actually compiles and runs that query**, the licence
notice, and the documentation the change makes untrue. Everything already
supported is untouched.

## Context

**What was read out of the tree, not assumed**

- `SyntaxLanguage.init(forFileName:)` runs four phases: exact name → extension →
  prefix → dot-ignore shape. `(".envrc" as NSString).pathExtension` is `""` and
  `".envrc"` does not carry the `".env."` prefix, so **`.envrc` is unclaimed
  today** and lands cleanly in the phase-1 exact-name map, ahead of everything.
  `.env` stays phase 1, `.env.local` phase 3, `.env.json` phase 2 — none moves.
- **Seven exhaustive switches**, confirmed by adding the case and typechecking,
  not by grepping: `CommentStyle.style(for:)`, `LanguageKeywords.keywords(for:)`,
  `SyntaxContextVocabulary.stringForms(for:)` / `.commentForms(for:)` /
  `.stringsSuppressCompletion(for:)`, `SyntaxLanguage.lspLanguageID` (a fifth
  Core switch the ticket did not name), and the app's
  `SyntaxLanguageConfiguration.makeConfiguration(for:)`.
- **The grammar at the newest tag, `v0.25.1`**
  (`a06c2e4415e9bc0346c6b86d401879ffb44058f7`), cloned and inspected. Its
  `Package.swift` is `tree-sitter-go`'s shape: package and target both
  `TreeSitterBash`, `path: "."`, `sources: ["src/parser.c", "src/scanner.c"]`
  (the external scanner **is** compiled — not the vendored-dotenv failure mode),
  `resources: [.copy("queries")]`, `publicHeadersPath: "bindings/swift"` exposing
  `tree_sitter_bash()`. Its only dependency is `tree-sitter/swift-tree-sitter`
  from its **test** target — the same declaration `tree-sitter-go@0.25.0`
  carries, and the committed `Package.resolved` contains no `swift-tree-sitter`
  entry, so the pruning is already proven in this repository rather than hoped
  for.
- **The shipped highlight query emits nine capture names**, read at v0.25.1:
  `comment`, `constant`, `embedded`, `function`, `keyword`, `number`,
  `operator`, `property`, `string`. Eight already resolve through
  `SyntaxTokenKind.nameMap`. `embedded` is the one the table does not know.
- **`embedded` wraps `command_substitution` / `process_substitution` /
  `expansion`** — whole spans that contain their own more-specific captures.
  SwiftTreeSitter's `highlights()` sorts "less-specific matches before
  more-specific" (`QueryDefinitions.swift`), so the inner captures win and only
  the `$(`, `)`, `${`, `}` delimiters are left to it.
- **Grammar node types**, read from `src/node-types.json`: `program`'s children
  expand the hidden `_statement`, whose subtypes include `variable_assignment`,
  `variable_assignments` and `declaration_command`; `function_definition` has a
  `name:` field of type `word`; `variable_assignment`'s `name:` field admits
  `variable_name` **or** `subscript`.
- **`src/scanner.c` includes only `assert.h`, `ctype.h`, `string.h`,
  `wctype.h`** — no required-reason API. The audit will find nothing; its record
  still gets a re-run line.
- **`Resources/Queries` is a folder reference** in `project.yml`, so a new
  `shell/` directory ships with no manifest change.
- **The file-icon table already answers `sh`, `bash`, `zsh`** (terminal glyph,
  green). Confirmed by reading `FileIcon.swift`; `ksh` and `command` fall back to
  the generic icon, which the ticket puts out of scope.
- **`PisakaAppTests` is an application-host bundle** (`TEST_HOST` /
  `BUNDLE_LOADER` pointing at `Pisaka.app`, `project.yml`), so a `@testable
  import Pisaka` there runs *inside the host app process*: `Bundle.main` is
  `Pisaka.app`, which is where the `Resources/Queries` folder reference lands, so
  `SymbolQueryCatalog.query(for:)` resolves and compiles for real.
  `Tests/PisakaAppTests/Fixtures/` already exists (`every-element.md`), is read
  through `#filePath`, and needs no `exclude:` — `Package.swift` does not see
  that bundle at all.
- **The fence claim, verified rather than asserted.** Two different paths, and
  only one of them touches this table:
  `SyntaxLanguageConfiguration.configuration(forInjectionName:)` lowercases the
  injection name and resolves it through `SyntaxLanguage(rawValue:)` **then**
  `SyntaxLanguage(fileExtension:)` — so in the *editor*, a fenced block inside an
  open Markdown file picks up the new language for ` ```shell ` (raw value) and
  for ` ```sh `/` ```bash `/` ```zsh `/` ```ksh ` (extension map), with no extra
  code. The *Markdown preview* is unrelated:
  `MarkdownRenderer.highlightName(for:)` takes the first whitespace-separated
  word of the info string, lowercases it and emits `class="language-<name>"` for
  the bundled highlighter to resolve against its own alias table. It never
  consults `SyntaxLanguage`, so the preview neither gains nor loses anything
  here.

**Files involved**

Core (modified): `SyntaxLanguage.swift`, `CommentStyle.swift`,
`LanguageKeywords.swift`, `SyntaxContextVocabulary.swift`,
`LSPServerDescription.swift`.
App (modified): `Sources/Pisaka/SyntaxLanguageConfiguration.swift`.
Resources (new): `Resources/Queries/shell/symbols.scm`,
`Resources/Licenses/tree-sitter-bash.txt`.
Resources (modified): `Resources/Licenses/licenses.json`.
Manifest: `project.yml`,
`Pisaka.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
Core tests (modified): `SyntaxLanguageTests`, `CommentStyleTests`,
`ToggleCommentEngineTests`, `LanguageKeywordsTests`,
`SyntaxContextVocabularyTests`, `SyntaxContextScannerTests`, `SymbolQueryTests`,
`SyntaxTokenKindTests`, `LicenseCoverageTests`.
App tests (new): `Tests/PisakaAppTests/ShellSymbolQueryTests.swift`,
`Tests/PisakaAppTests/Fixtures/shell-symbols.sh`.
Docs: `docs/architecture/core-editor.md`, `core-intelligence.md`,
`core-services.md`, `CLAUDE.md` (one sentence), `README.md`,
`docs/FEATURES.md`.

**Related patterns**

`tree-sitter-go`'s pin and its `project.yml` comment (the manifest-shape
reasoning to reuse); `tree-sitter-rust`'s capture-pin test (the exact mould for
the new one); Python's and Go's `symbols.scm` top-level anchoring; the `@none`
precedent in `SyntaxTokenKindTests` for a capture that is deliberately plain;
`MarkdownParserTests` (the mould for an app-layer suite that executes what
`swift test` structurally cannot reach, over a `#filePath` fixture).

**Dependencies** — one: `tree-sitter/tree-sitter-bash` at `v0.25.1`. Nothing is
vendored; no highlight query is authored.

**Decisions settled here, so implementation is not a guess**

1. **The case is `shell`**, raw value `"shell"`, query directory
   `Resources/Queries/shell/`. Not the grammar's own name: the case has to cover
   `zsh`, `ksh` and `.profile` too. The raw value is load-bearing for one
   verified path — `configuration(forInjectionName:)` tries `rawValue` first and
   the extension map second — so in the editor's fenced-block injection all of
   ` ```shell `, ` ```sh `, ` ```bash `, ` ```zsh ` and ` ```ksh ` resolve with
   no extra code. The Markdown preview's fence label is *not* one of those paths
   and is unaffected either way.
2. **`embedded` is left deliberately unmapped**, following `@none` rather than
   adding a table entry: it is an injection marker, not a token class, and there
   is no kind in the fourteen that it means. What it actually paints, given the
   less-specific-first ordering, is the `$(`/`)`/`${`/`}` delimiters — leaving
   those at the default colour is correct, and a test pins it so a later
   "map everything" sweep cannot quietly colour it.
3. **`lspLanguageID` is `"shellscript"`** — the protocol's own identifier for a
   shell script, spelled differently from the raw value. No server is registered;
   the arm exists so the mapping stays total, exactly as `.dotenv`'s does.
4. **Completion is not suppressed inside shell strings.** A double-quoted shell
   string interpolates (`"$HOME/bin"`, `"${TAG}-rc"`), so its contents are the
   vocabulary completion should still offer. The flag is per language, so the
   non-interpolating single-quoted form inherits the same answer — a popup nobody
   asked for costs less than silence in the form people actually type in. The doc
   sentence that today says "the four document-vocabulary languages" becomes
   untrue and is rewritten to name the second reason.
5. **The `#` anchor is `.afterWhitespace`**, the reading YAML already uses: a `#`
   glued to the preceding character is part of a word, so neither `foo#bar` nor
   `${var#prefix}` opens a comment.
6. **Three shapes are not modelled**, stated on the vocabulary entry itself:
   heredocs (the delimiter is an arbitrary word declared on an earlier line, so
   no fixed `StringForm` describes it — the body lexes as code), `$'…'` (its
   escapes are C's, and `allowedPrefixLetters` takes letters, not `$`; it lexes
   as an ordinary single-quoted string, which ends it in the same place), and
   backslash-continued lines.
7. **Functions are unanchored, variables are anchored.** A shell function is
   global wherever its definition runs, so nesting does not scope it; an
   assignment inside a function body or a loop is almost always a local or a
   counter, so the assignment patterns hang off `(program …)` — Python's and Go's
   anchoring, for the same reason. A bare `export PATH` inside a
   `declaration_command` is **not** captured: it names a variable bound
   elsewhere, so indexing it would file a definition at a line that defines
   nothing.
8. **The keyword line, restated so it actually divides the list** (replacing the
   earlier "builtins are in because nothing on disk declares them", which
   admitted and refused the same words — `echo`, `printf`, `test`, `pwd` and
   `kill` are builtins *and* real files in `/bin`). The line is: **a word is in
   when the shell itself must interpret it for the script to mean what it says**
   — the reserved words, plus the builtins that *bind or unbind a name*, *set a
   shell option or change how the shell reads what follows*, or *alter control
   flow*. A word is **out** when it is an ordinary command that a program in
   `$PATH` could perform, whether or not this shell also implements it
   internally — which is `LanguageKeywords`' own "deliberately not a
   standard-library index" rule (`print` and `console` are excluded because a
   project that uses them has them in its buffer already, and `echo` is the same
   argument).
   - In: `alias, break, builtin, case, command, continue, coproc, declare, do,
     done, elif, else, esac, eval, exec, exit, export, fi, for, function,
     getopts, if, in, let, local, mapfile, read, readarray, readonly, return,
     select, set, shift, shopt, source, then, time, trap, typeset, unalias,
     unset, until, while`.
   - Out, and named so the exclusion is a decision: `echo, printf, test, pwd,
     kill, type, hash, ulimit, umask, jobs, fg, bg, wait, pushd, popd` (ordinary
     commands), `true`/`false` (commands here, not literals — unlike a language
     whose grammar has a boolean literal), every external program (`grep`, `sed`,
     `awk`, `git`), and the bracket/brace tokens (punctuation, which the
     identifier rule would refuse to insert anyway).
   - **One stated deviation** from the trim list the review suggested:
     `mapfile`/`readarray` stay *in*, because they bind a name — the same clause
     that admits `read`, which no external program can do — while `jobs`, `fg`,
     `bg` and `wait` stay *out*, because manipulating the job table is none of
     the three clauses. The list obeys the line as written.
9. **The runtime half of the symbols query is a test, not a hand-off.** The
   failure this ticket names as silent — a query that stops compiling against its
   grammar — is invisible to `swift test` (Core does not link tree-sitter) and to
   both builds. It is *not* invisible to `PisakaAppTests`, which runs inside the
   host app: `SymbolQueryCatalog.query(for: .shell)` compiles the real `.scm`
   against the real grammar and returns `nil` on failure, and
   `SymbolExtractor.symbols(in:language:fileURL:)` executes it. So Task 3 asserts
   the four decisions of point 7 *by execution* over a fixture script. Scoped to
   shell alone: the same gap for the other sixteen languages is pre-existing and
   is not this ticket. (Note for the implementer: the test scheme's config is
   Debug, so a query that fails to compile trips `SymbolQueryCatalog`'s
   `assertionFailure` first and the failure surfaces as a trap naming the
   language — a hard failure either way, and the diagnosis arrives with it.)
   The manual ⌃⌘J check stays, as confirmation of the end-to-end path, but is no
   longer the only evidence.

## Development Approach

- **Testing approach**: Regular — code, then tests, in the same task.
- Complete each task fully before the next; `swift test` is green at every task
  boundary, which is why the language and its tables land as one step rather than
  split (the symbols-query set-equality suite fails the moment the case exists
  and nothing else would make it pass).
- **CRITICAL: every task ships new/updated tests.**
- **CRITICAL: all tests pass before the next task starts.**
- Builds write derived data to
  `~/Library/Developer/Xcode/DerivedData/pisaka-shell`, never inside the working
  tree.

## Implementation Steps

### Task 1: Pin the grammar and ship its licence

**Files:**
- Modify: `project.yml`
- Modify: `Pisaka.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (regenerated)
- Create: `Resources/Licenses/tree-sitter-bash.txt`
- Modify: `Resources/Licenses/licenses.json`
- Modify: `Tests/PisakaCoreTests/LicenseCoverageTests.swift`

Lands the dependency on its own, with nothing importing it yet, so the pin and
the licence machinery are proven green before any language work rests on them.

- [x] Add the package to `project.yml` beside the other grammars —
      `url: https://github.com/tree-sitter/tree-sitter-bash`,
      `exactVersion: "0.25.1"` — and the target dependency
      (`package: tree-sitter-bash`, `product: TreeSitterBash`). No
      `destinationFilters:`.
- [x] Write the `project.yml` comment the way `tree-sitter-go`'s and
      `tree-sitter-rust`'s are written, stating the two facts read out of the
      manifest **at this revision**: `sources:` names `src/scanner.c` so the
      external scanner really compiles (the failure the vendored dotenv package
      exists to avoid), and the `swift-tree-sitter` dependency is test-target
      only — a different package identity from the root's branch-pinned
      `SwiftTreeSitter`, pruned by SwiftPM, so it adds no pin and provokes no
      two-requirements conflict. Say that the resource bundle is
      `TreeSitterBash_TreeSitterBash`, which is what `name: "Bash"` derives.
- [x] Regenerate: `xcodegen generate`, then
      `xcodebuild -project Pisaka.xcodeproj -resolvePackageDependencies
      -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-shell`.
      Confirm the resolved file stays v2 schema, records the 40-hex revision for
      the tag, and gained **no** `swift-tree-sitter` entry. Never hand-edit it.
- [x] Copy upstream's `LICENSE` at the pinned revision verbatim to
      `Resources/Licenses/tree-sitter-bash.txt`. Read the package manifest for
      any third-party tree it compiles in; there is none, so no appendix —
      unlike libgit2 and tree-sitter itself.
- [x] Add the `licenses.json` notice: `id`/`name` `tree-sitter-bash`, `origin`
      the repository URL, `version` `0.25.1`, `revision` the recorded pin, `spdx`
      `MIT`, `file` `tree-sitter-bash.txt`.
- [x] Add the `tree-sitter-bash` row to `LicenseCoverageTests`'
      `expectedCopyrightHolders`.
- [x] Run `swift test` — `DependencyPinTests` and the `LicenseCoverageTests`
      pin/coverage assertions must all pass — before Task 2.

### Task 2: The language and its seven tables

**Files:**
- Modify: `Sources/PisakaCore/SyntaxLanguage.swift`, `CommentStyle.swift`,
  `LanguageKeywords.swift`, `SyntaxContextVocabulary.swift`,
  `LSPServerDescription.swift`
- Modify: `Sources/Pisaka/SyntaxLanguageConfiguration.swift`
- Create: `Resources/Queries/shell/symbols.scm`
- Modify: `Tests/PisakaCoreTests/SyntaxLanguageTests.swift`,
  `CommentStyleTests.swift`, `ToggleCommentEngineTests.swift`,
  `LanguageKeywordsTests.swift`, `SyntaxContextVocabularyTests.swift`,
  `SyntaxContextScannerTests.swift`, `SymbolQueryTests.swift`

One task because the set-equality suites make it one: the enum case, every table
that must answer for it, and the query that keeps `SymbolQueryTests` green are a
single indivisible green step.

- [x] Add `case shell` to `SyntaxLanguage`. Extend `extensionMap` with `sh`,
      `bash`, `zsh`, `ksh`, `command`, and `exactFileNameMap` with `.bashrc`,
      `.bash_profile`, `.bash_logout`, `.zshrc`, `.zprofile`, `.zshenv`,
      `.zlogin`, `.zlogout`, `.profile`, `.envrc`. **No phase is reordered,
      loosened, or given a new rule** — every new name is served by the two maps
      that already exist. Extend the type's doc comment with one sentence on why
      `.envrc` is an exact name: it is one character from the dotenv family, and
      an exact name in phase 1 is the only placement that cannot interact with
      the `.env.` prefix rule in either direction.
- [x] `CommentStyle`: `.shell` joins the `#` line-comment group.
      `languagesWithoutComments` unchanged.
- [x] `LanguageKeywords`: add the `shell` list exactly as decision 8 fixes it,
      sorted and duplicate-free, and write decision 8's line — the three
      admitting clauses and the "an ordinary command a `$PATH` program could
      perform is out" refusal — into the list's own doc comment, naming `echo` as
      the worked example and `mapfile`/`read` as the clause that admits them.
- [x] `SyntaxContextVocabulary`: add the three arms. Strings — `'…'`
      `spansLines: true, escape: .none` and `"…"` `spansLines: true,
      escape: .backslash`; comments — `.line(token: "#", anchor:
      .afterWhitespace)`; suppression — `false`. Put decisions 4, 5 and 6 above
      on the entry itself, not only in this plan. Rewrite the type-level sentence
      and `stringsSuppressCompletion`'s own doc, which today say the `false`
      answer belongs to "the four document-vocabulary languages" — shell is the
      fifth and joins for a different reason. Correct `vocabulary(for:)`'s
      "all 16 `SyntaxLanguage` cases" to 17.
- [x] `SyntaxLanguage.lspLanguageID`: `case .shell: return "shellscript"`, with
      the one-line note that it is the protocol's spelling, that it differs from
      the raw value, and that no server speaks it here — the arm exists so the
      mapping stays total, as `.dotenv`'s does.
- [x] `SyntaxLanguageConfiguration`: `import TreeSitterBash` beside the other
      remote grammars, and
      `case .shell: return try LanguageConfiguration(tree_sitter_bash(), name: "Bash")`,
      noting that the bundle `TreeSitterBash_TreeSitterBash` is what that name
      derives.
- [x] Write `Resources/Queries/shell/symbols.scm` under the shared convention:
      `(function_definition name: (word) @definition.function)` unanchored, and
      three `(program …)`-anchored variable patterns — a bare
      `variable_assignment`, one inside `variable_assignments` (the `A=1 B=2`
      form), and one inside a `declaration_command` (`readonly ROOT=/srv`).
      Capture `name: (variable_name)` specifically, which is what skips the
      `subscript` form `arr[2]=x`. Carry decision 7 and the subscript note in the
      file's own header comment, the way Python's and Go's do.
- [x] `SymbolQueryTests`: add `.shell` to `pinnedNodeNames` — named
      `{declaration_command, function_definition, program, variable_assignment,
      variable_assignments, variable_name, word}`, anonymous `{}`, fields
      `{name}`. The existing union assertion then covers the new language
      automatically.
- [x] Tests, each asserted **by name**: every new extension and dot-file resolves
      to `.shell`; `.env`, `.env.local` and `.env.json` resolve exactly as on the
      default branch; `fish`, `csh`, `tcsh` and `ps1` still resolve to `nil`; a
      path form (`scripts/deploy.sh`, `project/.zshrc`) resolves; `.shell` is not
      in `SymbolIndexModel.unindexableLanguages`; the comment style is
      `.line("#")` and `ToggleCommentEngine` round-trips a selection; the keyword
      list holds `function`/`local`/`fi`/`read` and holds neither `echo`, `grep`,
      `true` nor a bracket token; the vocabulary spot checks (single quote takes
      no escape, double quote takes backslash, both span lines, the anchor, the
      suppression answer); and scanner cases — `echo "# not a comment"` reads as
      a string, `foo#bar` and `${var#prefix}` are not comments, `# real` is.
- [x] Run `swift test` — every set-equality suite green — before Task 3.

### Task 3: Execute the symbols query in the app-layer bundle

**Files:**
- Create: `Tests/PisakaAppTests/ShellSymbolQueryTests.swift`
- Create: `Tests/PisakaAppTests/Fixtures/shell-symbols.sh`

The gate for decision 9: the only place in this pipeline where the new query is
compiled against its grammar and run. `swift test` cannot reach it (Core does not
link tree-sitter) and neither build executes it; the app-host bundle does both.

- [x] Write the fixture script under `Tests/PisakaAppTests/Fixtures/`, read
      through `#filePath` the way `MarkdownParserTests` reads its own. It must
      contain, deliberately and in one file: several functions in both spellings
      (`name() { … }` and `function name { … }`), top-level assignments in all
      three captured shapes (a bare `X=1`, the `A=1 B=2` form, and a
      `readonly`/`export`/`declare` declaration command with a value),
      assignments **inside** function bodies and inside a loop, a bare
      `export PATH` with no value, an array subscript assignment `arr[2]=x`, and
      a `#` comment plus a quoted `#` so the fixture is a plausible script rather
      than a list of patterns.
- [x] `ShellSymbolQueryTests` — `#if os(macOS)`, `@testable import Pisaka`, with
      a doc comment stating why it exists (the silent failure mode, and that the
      two types it drives are structurally out of `swift test`'s reach):
      - [x] `SyntaxLanguageConfiguration.configuration(for: .shell)` is
            non-`nil` — the grammar loads and its bundled highlight query
            resolves.
      - [x] `SymbolQueryCatalog.query(for: .shell)` is non-`nil` — the shipped
            `.scm` compiles against the pinned grammar. This is the assertion the
            ticket calls silent today.
      - [x] `SymbolExtractor.symbols(in:language:fileURL:)` over the fixture,
            with the result reduced to a comparison shape that carries no
            absolute path (the `(kind, name, line)` triple) and asserted **by set
            equality** against the expected set written out in full. The four
            decisions of point 7 are then assertions rather than readings: every
            function is present under `.function`; every top-level assignment is
            present under the variable kind; **no** assignment made inside a
            function body or a loop appears; and neither `arr[2]=x` nor the
            valueless `export PATH` appears.
- [x] Run
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=macOS' -derivedDataPath
      ~/Library/Developer/Xcode/DerivedData/pisaka-shell test` — the whole
      app-layer bundle green, not just the new suite — before Task 4. Also run
      `swift test` to confirm the new fixture changed nothing there (the app
      bundle is invisible to `Package.swift`, so no `exclude:` entry is needed —
      confirm that is still true rather than adding one).

### Task 4: Pin the grammar's capture set

**Files:**
- Modify: `Tests/PisakaCoreTests/SyntaxTokenKindTests.swift`

- [x] Add `testShellGrammarQueryCaptureNamesResolve` in the exact shape of the
      Rust and Go tests: the **nine** names read out of the resolved checkout at
      v0.25.1 with a one-line note each on what they cover, a count assertion
      (`9`), and the loop that asserts each resolves to its expected kind. Note
      on the table that `variable_name` is emitted as `property`, so `$HOME`
      takes the property colour — the grammar's choice, recorded rather than
      corrected — and that this table needed **no** new `nameMap` entry.
- [x] Add `testShellEmbeddedCaptureIsDeliberatelyUnmapped`, asserting
      `SyntaxTokenKind(captureName: "embedded") == .plain`, with decision 2's
      reasoning on it: it is an injection marker rather than a token class, it
      wraps spans whose inner captures already win under SwiftTreeSitter's
      less-specific-first ordering, and what it is left painting is the `$(`,
      `)`, `${`, `}` delimiters — correctly at the default colour. Written the
      way `testNoneCaptureNameStaysPlain` is: the absence is the decision.
- [x] Run `swift test` — must pass before Task 5.

### Task 5: Re-run the required-reason API audit

**Files:**
- Modify: `docs/architecture/core-services.md`
- Modify (only if the audit finds something): `Resources/PrivacyInfo.xcprivacy`

- [x] Build for iOS device and run the recorded `nm -u` grep against the
      **correct** binary — the debug dylib for a Debug build — confirming first
      that the file scanned lists hundreds of undefined symbols, since an empty
      match on the wrong binary reads exactly like a clean result.
- [x] Record the outcome as a new "Last re-run" line in the audit, naming the
      newly linked grammar and its answer. The expectation from reading
      `src/scanner.c` (only `assert.h`, `ctype.h`, `string.h`, `wctype.h`) is
      that nothing changes — but record what the command actually printed, not
      the expectation.
- [x] Touch `PrivacyInfo.xcprivacy` **only** if the audit finds a symbol the
      manifest does not already declare; `ReleaseMetadataTests` asserts that set
      by set equality, so a speculative edit fails.
- [x] Run `swift test` — must pass before Task 6.

### Task 6: Documentation

**Files:**
- Modify: `docs/architecture/core-editor.md`,
  `docs/architecture/core-intelligence.md`, `CLAUDE.md`, `README.md`,
  `docs/FEATURES.md`

- [x] `core-editor.md`: extend the `SyntaxLanguage` entry with the new extensions
      and dot-files, the `.envrc` placement argument, and one sentence on the
      injection path the raw value serves (and that the Markdown preview's fence
      label is a different, unaffected path); extend the `SyntaxTokenKind` entry
      with the `embedded` decision and the ordering fact it rests on; extend the
      `LanguageKeywords` entry with the line decision 8 states.
- [x] `core-intelligence.md`: a shell section in the shape of the Go and Rust
      ones — the query's two anchoring decisions, the node/field names verified
      against the pinned `node-types.json`, what the static half of the
      verification recipe found, and **the new app-layer suite as the runtime
      half**, naming what it asserts and why the manual step is now a
      confirmation rather than the only evidence. Correct the "16
      `SyntaxLanguage` cases" sentence to 17.
- [x] `CLAUDE.md`: the Tests paragraph enumerates the `PisakaAppTests` suites, so
      add `ShellSymbolQueryTests` to that list with its half-sentence reason (it
      executes a symbols query against its grammar, which `swift test` cannot).
      Nothing else in that file: the vendored-grammar count is unchanged, "one
      tree-sitter grammar per language" still holds, and the index line for
      `SyntaxLanguage.swift` still describes the file. Confirm by inspection and
      say so.
- [x] `README.md` and `docs/FEATURES.md`: add shell to the language lists that
      become untrue (highlighting, comment toggle, keyword completion, file-name
      resolution). Nowhere else — do not restate the language in every document
      that mentions the table.
- [x] Run `swift test` — must pass before Task 7.

### Task 7: Verify acceptance criteria

- [x] `swift test` — green, including `SymbolQueryTests`, `LanguageKeywordsTests`,
      `LicenseCoverageTests`, `DependencyPinTests` and `ReleaseMetadataTests`.
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=macOS' -derivedDataPath
      ~/Library/Developer/Xcode/DerivedData/pisaka-shell test` — the app-layer
      bundle green, `ShellSymbolQueryTests` among it.
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'generic/platform=iOS' -derivedDataPath
      ~/Library/Developer/Xcode/DerivedData/pisaka-shell build` — the iOS device
      build green, which is the standing link-time proof that the grammar's
      external scanner really compiles.
- [x] `swiftlint --strict` from the repository root — clean at the pinned
      version.
- [x] Confirm the capture pin fails as designed: temporarily rename one of the
      nine names, confirm the failure, revert.
- [x] Confirm the symbols-query node pin fails as designed: temporarily add a
      node name to the query, confirm `SymbolQueryTests` names shell, revert.
- [x] Confirm the **runtime** pin fails as designed: temporarily break the query
      (rename a node to one the grammar does not have), confirm
      `ShellSymbolQueryTests` fails and names shell, revert. This is the
      assertion the whole of Task 3 exists for, so it is proven to bite rather
      than assumed to.
- [x] Build a **DEBUG** macOS build to the out-of-tree derived-data path and
      launch it with a scratch project directory **outside the repository**
      containing the same shape of fixture script as Task 3's. Report the build
      and launch outcome and any `SymbolQueryCatalog` assertion it trips.
- [x] Confirm `git status` shows only the intended changes and that no derived
      data was written inside the working tree.

Recorded outcome of this pass (2026-09-21):

- `swift test`: 5711 tests, 0 failures.
- App-layer bundle (`platform=macOS`, out-of-tree derived data): 98 tests, 0
  failures, `ShellSymbolQueryTests`' three among them.
- iOS device build (`generic/platform=iOS`): BUILD SUCCEEDED — the external
  scanner links.
- `swiftlint --strict` 0.65.1: 0 violations in 579 files.
- Capture pin: renaming `property` to `propertyX` failed
  `testShellGrammarQueryCaptureNamesResolve` on both of its assertions, naming
  the capture. Reverted.
- Node pin: adding a `(subshell …)` pattern failed
  `testRemoteGrammarQueriesUseExactlyThePinnedNodeNames` with
  "shell/symbols.scm changed which named nodes it matches". Reverted.
- Runtime pin: renaming `function_definition` to a node the grammar does not
  have failed the app-layer run, naming the file — it trips
  `SymbolQueryCatalog`'s DEBUG assertion inside the test process
  ("Queries/shell/symbols.scm does not compile against the shell grammar"),
  which aborts the run before `ShellSymbolQueryTests`' own assertion reports.
  The gate bites and names shell either way; the reporting route is the DEBUG
  assertion rather than an XCTest failure line. Reverted.
- DEBUG macOS build to `~/Library/Developer/Xcode/DerivedData/pisaka-shell`:
  BUILD SUCCEEDED; launched with `/tmp/pisaka-shell-scratch` (outside the
  repository) holding `deploy.sh`, a copy of Task 3's fixture. The app ran with
  no `SymbolQueryCatalog` assertion and no error output, and was left running
  for the manual step below.
- `git status` clean; the ignored `build/` and `DerivedData/` directories in the
  tree pre-date this work (7–8 September) and nothing was written into them.

## Post-Completion (manual, by the user — mandatory, not optional)

- In the DEBUG build launched above, open the fixture shell script and press
  ⌃⌘J. **Report which file was opened and exactly what the picker listed** — the
  functions must appear, the top-level assignments must appear, and the
  assignments made inside function bodies must not. This confirms the end-to-end
  path (bundle → catalog → extractor → index → picker); the query's own
  compilation and its four anchoring decisions are already gated by Task 3, so
  this is a confirmation rather than the only evidence.
- Open the same script and confirm by eye that it is highlighted, that ⌘/
  comments and uncomments a selection with `#`, and that the minimap draws token
  runs for it.
