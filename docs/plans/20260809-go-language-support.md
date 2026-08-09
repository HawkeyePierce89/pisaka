# Go language support

## Overview

Add Go as a first-class language across the whole stack phases 1, 1.5, 2a and 2b
built, and use it to prove the claim that architecture was designed around: **a
new language is a set of records, not a project.** Concretely — one remote
grammar pin, one `SyntaxLanguage` case, one `symbols.scm`, one keyword list, one
icon entry, one run-command entry — plus the one genuinely new piece, semantic
intelligence on macOS through **gopls**, which cannot use 2b's artifact-download
path because gopls ships no official binaries at all.

Everything the set-equality suites can see is driven by them:
`SyntaxLanguage.allCases` gains `.go` and `SymbolQueryTests`,
`LanguageKeywordsTests`, `LicenseCoverageTests`, `DependencyPinTests` start
failing until each record exists. The implementation follows those failures.

### The pins (resolved during planning — implementation needs no network for these)

| what | pin | provenance |
|---|---|---|
| `tree-sitter-go` | `exactVersion: "0.25.0"` → tag `v0.25.0`, revision `1547678a9da59885853f5f5cc8a99cc203fa2e2c` | `github.com/tree-sitter/tree-sitter-go`, MIT |
| gopls | `v0.23.0`, module `golang.org/x/tools/gopls` | latest non-prerelease `gopls/v*` tag on `github.com/golang/tools` |

Facts about the grammar checkout at that revision, verified while planning:

- It ships a SwiftPM manifest (`Package.swift`, package **and** target named
  `TreeSitterGo`, so the resource bundle is `TreeSitterGo_TreeSitterGo` — the
  convention `LanguageConfiguration(…, name: "Go")` already expects), a Swift
  binding header (`bindings/swift/TreeSitterGo/go.h`, entry point
  `tree_sitter_go()`), and `queries/highlights.scm`.
- `sources:` is `["src/parser.c"]` only — **there is no `src/scanner.c`**, so no
  external scanner and no link-time surprise of the `TreeSitterDotenv` kind.
  `exclude:` is absent.
- **Vendored-subtree check: nothing beyond `src/tree_sitter/parser.h`**,
  tree-sitter's own MIT header, which every grammar in this repo already carries
  and which the existing `tree-sitter` license entry already covers. Unlike
  libgit2's `deps/xdiff` (LGPL-2.1) and tree-sitter's `lib/src/unicode` (ICU),
  there is no second license to append. This is the finding the plan records:
  *nothing was found*.
- Its manifest declares `.package(name: "SwiftTreeSitter", url:
  ".../tree-sitter/swift-tree-sitter")` — but only its **test target** depends on
  it, and SwiftPM prunes a non-root package's test-only dependencies, which is
  why no other `tree-sitter-*` pin in `Package.resolved` drags it in. So
  resolution adds **exactly one** new pin and no collision with ChimeHQ's
  `SwiftTreeSitter`.
- The C is a pure parser: no file, network, disk-space, boot-time, keyboard or
  `UserDefaults` API. The required-reason audit is re-run over the built binaries
  anyway (the record's `nm -u` step), and the expectation is that
  `Resources/PrivacyInfo.xcprivacy` is unchanged.

The highlight query's capture vocabulary at that revision is `function`,
`function.builtin`, `function.method`, `type`, `property`, `variable`,
`operator`, `keyword`, `string`, `escape`, `number`, `constant.builtin`,
`comment`. Thirteen names, twelve of which `SyntaxTokenKind` already resolves to
a non-`.plain` kind. **`escape` is the one that does not** — tree-sitter-go
spells escape sequences `@escape` rather than the more common `@string.escape`,
and with no `escape` prefix in the name map every `\n` inside a Go string would
render default-colored. One map entry (`"escape": .string`) closes it.

### The symbols query (authored and statically validated during planning)

Every node, field and literal name below was checked against `src/node-types.json`
at the pinned revision — all declared, under the right `named` flag. That is the
plan-time half of the acceptance criterion; the runtime half (does it compile,
does a fixture's declarations actually get captured) is a task step.

```scheme
(type_declaration (type_spec name: (type_identifier) @definition.type))
(type_declaration (type_alias name: (type_identifier) @definition.type))

(type_spec
  name: (type_identifier) @container
  type: (struct_type
          (field_declaration_list
            (field_declaration name: (field_identifier) @definition.property))))

(type_spec
  name: (type_identifier) @container
  type: (interface_type (method_elem name: (field_identifier) @definition.method)))

(source_file (function_declaration name: (identifier) @definition.function))

(method_declaration
  receiver: (parameter_list (parameter_declaration type: (type_identifier) @container))
  name: (field_identifier) @definition.method)

(method_declaration
  receiver: (parameter_list (parameter_declaration type: (pointer_type (type_identifier) @container)))
  name: (field_identifier) @definition.method)

(method_declaration
  receiver: (parameter_list (parameter_declaration type: (generic_type type: (type_identifier) @container)))
  name: (field_identifier) @definition.method)

(method_declaration
  receiver: (parameter_list (parameter_declaration
                              type: (pointer_type (generic_type type: (type_identifier) @container))))
  name: (field_identifier) @definition.method)

(source_file (const_declaration (const_spec name: (identifier) @definition.constant)))
(source_file (var_declaration (var_spec name: (identifier) @definition.variable)))
(source_file (var_declaration (var_spec_list (var_spec name: (identifier) @definition.variable))))
```

Four things about it worth stating, because they are decisions:

- **The pointer star is stripped by the grammar, not by us.** `*` is an anonymous
  token inside `pointer_type`, so capturing the `type_identifier` *inside* it
  yields `Worker`, not `*Worker` — which is the spelling go-to-definition indexes
  the type under and the spelling `SymbolIntelligenceProvider`'s receiver
  promotion (`index.declaresType(named:)`) looks up. Four receiver patterns rather
  than one alternation, because `[(type_identifier) (pointer_type …)] @container`
  would capture the *pointer_type node* for the pointer case and put the star
  back.
- **Interface methods are methods with the interface as container.**
  `method_elem` is the 0.25.x node name (it was `method_spec` in older grammars) —
  a rename exactly of the kind the hand-pinned node set exists to make visible on
  a pin bump.
- **Consts and vars are anchored to `source_file`**, the JavaScript/TypeScript
  reasoning verbatim: unanchored, `var_spec` matches every `var` inside every
  function body and the index fills with locals. `var_spec_list` gets its own
  pattern because a grouped `var ( … )` block nests one level deeper; a grouped
  `const ( … )` does not.
- **The package clause is not indexed.** `package foo` repeats in every file of a
  directory, so indexing it would put N identical `foo` symbols in the picker for
  a name nobody jumps to.

### Keywords: the rule

Go's **25 reserved words**, plus **the universe block's predeclared identifiers**:
the constants (`true`, `false`, `nil`, `iota`), the type names (`any`, `bool`,
`byte`, `comparable`, `complex64/128`, `error`, `float32/64`, `int`,
`int8/16/32/64`, `rune`, `string`, `uint`, `uint8/16/32/64`, `uintptr`) and the
built-in functions (`append`, `cap`, `clear`, `close`, `complex`, `copy`,
`delete`, `imag`, `len`, `make`, `max`, `min`, `new`, `panic`, `print`,
`println`, `real`, `recover`). 70 entries, sorted, unique.

The rule, stated: **include an identifier when no source file can ever declare
it.** That is exactly the existing TypeScript precedent — `string`, `number`,
`boolean`, `never` are in that list for the same reason, "keywords in type
position, not declarations anything could jump to". Go's builtins are a sharper
case than TypeScript's: `len` and `error` are declared in no file anywhere, so
*no other completion source can ever offer them* — not the index, not the
harvested buffer words unless the user already typed one. Cutting them would
leave `len` uncompletable in a Go project forever. It does not contradict the
list's "not a standard-library index" rule: `fmt.Println` is a declaration in a
package, and stays out.

### gopls: discovery first, consented `go install` second — decisions D17–D20

To be recorded in `docs/architecture/core-lsp.md` beside D1–D10.

- **D17 — gopls is discovered, never downloaded, and 2b is not touched.** There
  are no official prebuilt gopls binaries; it is distributed as source and
  installed with `go install`. So the manifest gains nothing,
  `LSPProvisioningManifest`, `LSPInstallEngine`'s install path and
  `LSPDownloadableServer` are all untouched, and there is no `LSPComponent` for
  gopls. What *is* reused, because it is pure or generic: the `LSPInstallLayout`
  path math (`versionDirectory(componentID:version:)`,
  `stagingDirectory(componentID:version:token:)` are already string-keyed and need
  no `LSPComponent`), and `LSPInstallEngine.remove("gopls")`, which already
  deletes any component directory on disk whether or not the manifest describes
  it. So Remove, staging sweep and "delete the LanguageServers directory to
  de-provision completely" keep working with **zero engine changes**.
- **D18 — No new `Launch` case; the app reports a path, Core composes a
  description.** The obvious move — a third `LSPServerDescription.Launch` beside
  `.toolchainTool`/`.executable` — is the wrong one: everything gopls discovery
  knows (`$GOBIN`, `$GOPATH/bin`, `~/go/bin`, the login `PATH`,
  `/usr/local/go/bin`, Homebrew) is machine-specific knowledge of exactly the kind
  D9 keeps out of Core. Instead the app *does* the search and hands Core a value —
  "no Go toolchain", or "go at `<path>`, gopls at `<path>` / not found" — and Core
  turns a found gopls into a plain `.executable(path:)` registry entry,
  `id: "gopls"`, `languages: [.go]`, no arguments (gopls speaks LSP over stdio by
  default). Core learns no paths and gains no launch kind. Discovery follows the
  `LSPToolchain` discipline exactly: non-blocking, off-main, cached per app run
  **including the negative answer**, `pending` while unresolved.
- **D19 — What is preferred, and the row's two "installed" states.** When both a
  user-installed gopls and an app-installed one exist, **the app's own copy wins**:
  it is the version this app pinned and the only one Remove may touch, and
  preferring the other would make Remove delete a copy that was not in use. The
  Settings row therefore reports five states — *no Go toolchain* / *not installed*
  / *installing…* / *installed (found on this Mac)* / *installed by Pisaka ·
  v0.23.0* — and offers **Remove only for the last**, never for a binary in
  `~/go/bin` that the app did not put there. Consent is the existing
  `LSPServerConsent` under id `"gopls"` in the same `SettingsStore` dictionary, so
  declining persists and is reversible from the same tab, per D15.
- **D20 — The install, and where it lands.** Accepting runs
  `go install golang.org/x/tools/gopls@v0.23.0` with `GOBIN` pointed at a staging
  directory under the app's own install root, then one `move` onto
  `…/LanguageServers/gopls/v0.23.0/bin/gopls` — D13's atomicity, reused rather
  than reimplemented. Nothing global is touched: no `$PATH`, no `~/go/bin`, no
  `sudo`. Module integrity is Go's checksum database and `GONOSUMDB`-free default
  (`sum.golang.org`), their equivalent of 2b's pinned SHA-256s, so the app does
  not hash anything itself. Failure philosophy is 2b's verbatim: silent
  per-request fallback to tree-sitter, no alert ever, the failure visible only as
  the Settings row's sentence plus Retry. Two honest known limits get written
  down: the build writes into the *user's* `GOMODCACHE`/`GOCACHE` (that is what
  `go install` is, and the alternative — a private `GOPATH` — re-downloads and
  rebuilds the world for no benefit), and with `GOTOOLCHAIN=auto` (Go's default)
  an old toolchain may fetch a newer one to build gopls.

Two registry contributors now exist. The app composes them —
`LSPServerRegistry(provisioning.registry.descriptions + gopls.descriptions)` —
and awaits `LSPWorkspace.updateRegistry(_:)`, preserving D16's push-then-delete
ordering for both. That is three lines of glue; every *rule* about when gopls
contributes a description lives in the Core model and is unit-tested there.

### Run/test commands

The mechanism extends naturally and is **wired**, not recorded as a limit.
`TestCommand` already knows Go (`_test.go` detection and `go test <dir>`) — it
was written language-agnostically before Go was a `SyntaxLanguage`, which is
itself the point being proved. `RunCommand` needs one map entry:
`"go": ["go", "run"]`. One stated limit: `go run <file>` runs that file alone, so
a `main` split across several files in a package needs `go run .` from the
terminal — the same shape as every other entry in that map, which all run a
single file.

## Context

- **Files involved (Core, modified):** `SyntaxLanguage.swift`, `FileIcon.swift`,
  `SyntaxTokenKind.swift`, `LanguageKeywords.swift`, `RunCommand.swift`,
  `LSPServerDescription.swift` (`lspLanguageID` gains `.go` → `"go"`).
- **Files involved (Core, new):** `LSPGoToolchain.swift` (the value types:
  toolchain/gopls state, the consent prompt, the Settings row and its
  `canInstall`/`canRemove`/status rules), `LSPGoplsProvisioning.swift` (the two
  seam protocols, the typed error, and the `@MainActor` model that owns discovery,
  consent, install, removal and the published description). Both carry the `LSP`
  prefix deliberately, so `LSPSourceGatingTests`' Core sweep picks them up and
  holds them to Foundation-only.
- **Files involved (app, new, macOS-gated):** `LSPGoToolchainService.swift` — one
  file implementing both seams, because both are the same technology (shell out to
  the user's `go`), unlike 2b's `URLSession`/`tar` pair.
- **Files involved (app, modified):** `SyntaxLanguageConfiguration.swift`,
  `LSPConsentBanner.swift` (a Go branch beside the download branch, same strip,
  different copy and actions), `LSPServerSettingsView.swift` (the Go row),
  `PisakaApp.swift` (composition, prewarmed discovery, registry merge, terminate),
  `ContentView.swift` (hand the model to the banner).
- **Resources:** `Resources/Queries/go/symbols.scm` (new),
  `Resources/Licenses/tree-sitter-go.txt` (new), `Resources/Licenses/licenses.json`,
  `project.yml`,
  `Pisaka.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
- **Tests touched:** `SymbolQueryTests`, `LanguageKeywordsTests`,
  `SyntaxTokenKindTests`, `LicenseCoverageTests`, `DependencyPinTests`,
  `ReleaseMetadataTests`, `FileIconTests`, `SyntaxLanguageTests`,
  `RunCommandTests`, `TestCommandTests`, `LSPServerRegistryTests`,
  `LSPSourceGatingTests`; new `LSPGoplsProvisioningTests`.
- **Related patterns:** `LSPToolchain`'s cached, non-blocking,
  negative-answer-included resolution; `LSPProvisioningModel`'s
  row/consent/failure shape; `LSPInstallEngine`'s stage-then-one-rename;
  `StubFileTree` (mutable half) and `ScriptedInstallSeams` as the models for the
  new scripted fakes; `SymbolQueryTests`' hand-pinned node sets for remote
  grammars; `SyntaxTokenKindTests`' hand-pinned dockerfile captures.
- **Dependencies:** one new remote SwiftPM package, `tree-sitter-go`. gopls is
  *not* a dependency of this app in any sense — it is neither linked, bundled,
  downloaded nor required.

## Development Approach

- **Testing approach**: TDD where the rules are the deliverable (the Go
  toolchain/gopls model, the keyword list, the query and capture pins, the run
  command); regular for the two SwiftUI surfaces and the `Process` seam, which
  stay thin and untested by convention.
- Complete each task fully — code, tests, green suite — before the next.
- Core stays Foundation-only: no `Process`, no `AppKit`, no `SwiftTreeSitter`. New
  `LSP*`-prefixed Core files are swept by `LSPSourceGatingTests`, which enforces
  exactly that; the new app file carries `#if os(macOS)` from its first
  significant line.
- Update set-equality suites by **extending** them, never by weakening an
  assertion into a containment check.
- Match existing comment density: these files carry their reasoning, not their
  mechanics.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**

## Implementation Steps

### Task 1: Pin the grammar and ship its license

The dependency conventions in full, done first so every later task compiles
against a real grammar. Nothing here is behavioral, and two static suites are the
gate.

**Files:**
- Modify: `project.yml`, `Pisaka.xcodeproj/…/swiftpm/Package.resolved`,
  `Resources/Licenses/licenses.json`
- Create: `Resources/Licenses/tree-sitter-go.txt`
- Modify: `Tests/PisakaCoreTests/DependencyPinTests.swift`,
  `Tests/PisakaCoreTests/LicenseCoverageTests.swift` (only if either spells a
  package count or list that must grow)

- [x] add the `tree-sitter-go` package (`exactVersion: "0.25.0"`) and the
      `TreeSitterGo` product dependency to `project.yml`, in the position the
      existing grammar list uses
- [x] regenerate the workspace `Package.resolved` via `xcodegen generate` +
      `xcodebuild -resolvePackageDependencies`, and confirm it gained **exactly
      one** pin (identity `tree-sitter-go`, revision
      `1547678a9da59885853f5f5cc8a99cc203fa2e2c`, version `0.25.0`) in the v2
      schema — a diff that rewrites the whole file is format churn and must be
      regenerated rather than committed
      — the resolve confirmed exactly that pin, but **Xcode 26.6 rewrote the
      whole file into the legacy v1 schema** (`object.pins`/`repositoryURL`),
      because SwiftPM picks the resolved-file format from the lowest root
      tools-version and the two `Vendor/` path packages are
      `swift-tools-version:5.3`. That is the format churn this bullet forbids, so
      the churn was discarded and the one new pin written into the committed v2
      file in place. CI's Xcode 16.4 keeps writing v2; a local Xcode build will
      downgrade the file again, and that rewrite must be discarded, never
      committed.
- [x] copy the verbatim `LICENSE` from the checkout at the pinned revision to
      `Resources/Licenses/tree-sitter-go.txt`, and add the `licenses.json` entry
      (id/name `tree-sitter-go`, origin, version `0.25.0`, that revision, spdx
      `MIT`)
- [x] record in the plan's docs pass that the vendored-subtree read found nothing
      beyond `src/tree_sitter/parser.h`, already covered by the `tree-sitter`
      entry — so unlike libgit2 and tree-sitter itself, this text needs no
      appended sub-dependency notice
      — recorded in `docs/architecture/core-services.md` beside the libgit2 and
      tree-sitter appendices. One correction to the plan-time reading: `src/`
      holds `tree_sitter/alloc.h` and `array.h` as well as `parser.h`, all three
      tree-sitter's own MIT headers and all three already covered by the same
      entry, so the conclusion is unchanged.
- [x] run `swift test`, confirming `DependencyPinTests` (requirement↔pin
      agreement, 40-hex revisions, `swifttreesitter` still the only branch pin)
      and `LicenseCoverageTests` (id set vs. `project.yml`, revision vs.
      `Package.resolved`) are green

### Task 2: The language case, its icon, its grammar and its capture vocabulary

`SyntaxLanguage.go` is the change that starts every other suite failing. This
task adds it and everything the *highlighting* half needs, including the one
capture-name gap.

**Files:**
- Modify: `Sources/PisakaCore/SyntaxLanguage.swift`,
  `Sources/PisakaCore/FileIcon.swift`, `Sources/PisakaCore/SyntaxTokenKind.swift`,
  `Sources/PisakaCore/LSPServerDescription.swift`,
  `Sources/Pisaka/SyntaxLanguageConfiguration.swift`
- Modify: `Tests/PisakaCoreTests/SyntaxLanguageTests.swift`,
  `Tests/PisakaCoreTests/FileIconTests.swift`,
  `Tests/PisakaCoreTests/SyntaxTokenKindTests.swift`

- [x] add `case go` and the `"go"` extension mapping; confirm the four-phase
      resolution still behaves (`main.go` → `.go`, and no prefix/dot-ignore rule
      can claim it)
      — `testGoNamesResolve`/`testGoLookalikesDoNotResolveToGo` pin it, including
      that `.goignore` (a dot-file with no `go` extension) still belongs to the
      shape rule and that a bare `go`/`go.work` resolves to nothing. The raw value
      is pinned too, since `configuration(forInjectionName:)` reaches Go through it
      for ```` ```go ```` fences.
- [x] `FileIcon` already maps the `go` extension — assert it rather than add it,
      and give Go the `lspLanguageID` `"go"` (the `switch` is total, so the
      compiler asks)
- [x] add `"escape": .string` to `SyntaxTokenKind.nameMap` with the reasoning on
      it (tree-sitter-go spells escape sequences `@escape`, not `@string.escape`;
      without this every `\n` in a Go string renders default-colored)
- [x] load the grammar in `SyntaxLanguageConfiguration` —
      `LanguageConfiguration(tree_sitter_go(), name: "Go")` plus the
      `import TreeSitterGo`
- [x] pin the highlight query's thirteen capture names by hand in
      `SyntaxTokenKindTests`, the dockerfile precedent, asserting each resolves to
      its expected kind **and** that none resolves to `.plain`
      — re-read from the resolved checkout at the pinned revision
      (`1547678a…`); the thirteen are exactly the vocabulary the plan recorded.
- [x] run `swift test` — expect `SymbolQueryTests` and `LanguageKeywordsTests` to
      fail on the new case; that is the next two tasks
      — confirmed: 2192 tests, exactly those two failures and no others.
      `LanguageKeywords.keywords(for:)` is a *total* switch, so it could not be
      left unhandled; `case .go: return []` is the placeholder that keeps the
      package compiling while the set-equality sweep goes red, and Task 4 replaces
      it with the real list (never with a `languagesWithoutKeywords` entry).

### Task 3: The symbols query

The query above, shipped, plus the static pins that make its node/field/literal
vocabulary reviewable on the next grammar bump, plus the runtime check the
repository's recipe requires for every grammar change.

**Files:**
- Create: `Resources/Queries/go/symbols.scm`
- Modify: `Tests/PisakaCoreTests/SymbolQueryTests.swift`

- [x] write `symbols.scm` as drafted above, with the header comment stating the
      shared convention and the four decisions (pointer receivers, `method_elem`,
      top-level anchoring, no package clause)
      — shipped as drafted with **one substantive change the runtime check
      forced**: the const pattern navigates by position,
      `(const_spec (identifier) @definition.constant)`, not by `name:`. See the
      fourth bullet.
- [x] add Go to `SymbolQueryTests.pinnedNodeNames` with its named nodes, its empty
      anonymous-literal set and its fields (`name`, `receiver`, `type`) — the
      coverage, capture-vocabulary and predicate-free assertions then cover it
      automatically
      — 23 named nodes, empty anonymous set, the three fields. A comment on the
      entry records that this pin does *not* move if the const pattern is ever
      "tidied" back to `name:` (same node and field vocabulary either way), so the
      reasoning lives on the query and in the capture table instead.
- [x] re-verify every pinned name against the pinned checkout's
      `src/node-types.json` under the matching `named` flag (the plan-time check,
      repeated at implementation time against the actually-resolved checkout in
      `SourcePackages/checkouts/tree-sitter-go`)
      — all 23 named, none anonymous, none missing; `name`/`receiver`/`type` all
      declared, and each on the nodes the query hangs them off. Checkout revision
      confirmed `1547678a9da59885853f5f5cc8a99cc203fa2e2c`.
- [x] runtime half of the documented recipe: compile the query against the grammar
      and run it over a fixture `.go` file exercising every pattern (struct with
      fields, interface with methods, type alias, generic type,
      value/pointer/generic receivers, grouped and ungrouped `const`/`var`, a
      function local that must **not** be indexed) — via a throwaway
      `npx tree-sitter query` run against the checkout, since `PisakaCore` cannot
      link SwiftTreeSitter; record the confirmed element-by-element capture table
      in `docs/architecture/core-intelligence.md`
      — run with `tree-sitter query` 0.25.10; all twelve patterns fired, pointer
      and generic receivers yielded `Worker`/`Pair` with no star, and the three
      function locals were correctly absent. **The check earned its keep**: with
      the drafted `const_spec name: (identifier)`, `const A, B = 1, 2` indexed `A`
      alone, because the grammar declares `const_spec`'s `name` field to hold the
      separating `,` tokens and a field interrupted by an anonymous token yields
      only its first named child. `var_spec`'s field holds identifiers only, so
      vars were unaffected — the asymmetry is the grammar's. Dropping the field is
      exact, not merely broader: a `const_spec`'s direct `identifier` children are
      exactly its names, the initializers being one level down inside
      `value: (expression_list)`. The grammar declares exactly two such
      comma-carrying fields (`const_spec.name`, `type_case.type`) and the query
      touches only the first. Capture table recorded in `core-intelligence.md`.
- [x] run `swift test` — `SymbolQueryTests` green
      — 9 tests, 0 failures. The suite's one remaining failure is
      `LanguageKeywordsTests`, the expected red Task 2 recorded and Task 4 closes.

### Task 4: Go keywords

**Files:**
- Modify: `Sources/PisakaCore/LanguageKeywords.swift`
- Modify: `Tests/PisakaCoreTests/LanguageKeywordsTests.swift`

- [x] add the 70-entry Go list per the stated rule, sorted and duplicate-free,
      with the rule itself written on the property — reserved words plus the
      universe block, because those are the identifiers no file can declare and
      therefore no other source can offer
      — the list is **69** entries, not 70: the plan's total is an arithmetic
      slip, not a missing entry. Its own composition adds up to 69 (25 reserved
      words + 22 predeclared types + 4 constants + 18 built-in functions), and
      every identifier the plan enumerated is present. The count is written on
      the property beside that breakdown so it stays derivable rather than
      asserted. Go's universe block holds one further name, the blank identifier
      `_`, deliberately left out: it is punctuation the user types directly, and
      offering it would mean a popup entry that completes to nothing readable.
- [x] wire `keywords(for: .go)`; leave `languagesWithoutKeywords` alone (Go is
      code)
      — the Task 2 placeholder comment goes with it; `case .go: return go` is
      now an ordinary arm.
- [x] extend `LanguageKeywordsTests` with the Go-specific assertions its shape
      invites: the sorted/unique/non-empty invariants come free from the existing
      per-language sweep, so add the ones that pin *content* — that `nil`, `iota`,
      `error` and `len` are present and that no dotted or package-qualified name
      (`fmt.Println`) crept in
      — two suites: one asserting all 25 reserved words in full plus a
      representative of each universe-block family (the four arguments for
      inclusion are different arguments, so a dropped family is its own
      regression), and one pinning the line the list must not cross —
      `fmt.Println`, `fmt`, `Sprintf` absent, and no entry containing a dot.
      `testTheDocumentedLanguagesAreTheOnesWithLists` gained `.go` by extension,
      not by weakening: it is still set equality.
- [x] run `swift test`
      — 2194 tests, 0 failures. The whole suite is green again; the sorted,
      duplicate-free, single-insertable-token and boundary-reachability sweeps
      all cover the new list automatically, including its digit-carrying entries
      (`complex128`, `uint8`), which reach the matcher through the
      digit/letter-transition boundary.

### Task 5: Run and test commands for Go

**Files:**
- Modify: `Sources/PisakaCore/RunCommand.swift`
- Modify: `Tests/PisakaCoreTests/RunCommandTests.swift`,
  `Tests/PisakaCoreTests/TestCommandTests.swift`

- [ ] add `"go": ["go", "run"]` to `RunCommand.runners`, with the single-file
      limit noted
- [ ] tests: `main.go` runs as `go run <quoted path>`, `canRun` answers true, a
      path with a space survives `ShellQuote`
- [ ] `TestCommand` already resolves Go — add the assertions that pin it now that
      Go is a language rather than a loose extension: `_test.go` is a test file,
      `foo.go` is not, and the command is `go test <quoted dir>`
- [ ] run `swift test`

### Task 6: Core — the Go toolchain and gopls domain

Everything decision-shaped about gopls, in Foundation alone: what states exist,
when a prompt may be offered, what the Settings row may do, what the registry
gets, and the two seams the app fills in. This is the task with the rules in it,
so it is TDD.

**Files:**
- Create: `Sources/PisakaCore/LSPGoToolchain.swift`,
  `Sources/PisakaCore/LSPGoplsProvisioning.swift`
- Create: `Tests/PisakaCoreTests/LSPGoplsProvisioningTests.swift`
- Modify: `Tests/PisakaCoreTests/Support/` (a scripted discovery/install pair, in
  `ScriptedInstallSeams`' mould), `Tests/PisakaCoreTests/LSPSourceGatingTests.swift`

- [ ] value types: the discovery report (no toolchain / `go` at a path, with gopls
      found at a path or not), the gopls installation (`discovered` vs
      `appInstalled(version:)`), the consent prompt, and the Settings row with
      `canInstall`/`canRemove`/status as properties — D19's rules, so the views
      hold no logic
- [ ] the two seams: a discovery protocol answering the report, and an install
      protocol taking (`go` executable, module path, version, target bin
      directory) and answering the installed executable URL — both `Sendable`,
      both `async`, neither mentioning `Process`
- [ ] the `@MainActor` model: pending-until-discovered lifecycle, D19's
      app-copy-wins preference, the `unasked`/`accepted`/`declined` consent
      through `SettingsStore` under id `"gopls"`, the silent "already accepted →
      install on first `.go` open, once per app run" rule (2b's `prepareForOpening`
      guard, including *not* retrying a failed attempt), the
      staging-then-one-rename install over `LSPInstallLayout` + `FileServicing`,
      removal through `LSPInstallEngine.remove("gopls")` with the
      push-then-delete ordering, the published description, and an awaited change
      callback
- [ ] tests: no toolchain → never prompts, never installs, contributes no
      description; gopls discovered → used silently, no prompt, no Remove; accept
      → one install, one rename, a description appears, consent persists; decline
      → persists across a rebuilt model and never re-prompts; a failed install →
      row message plus Retry, no description, no second automatic attempt this
      run; Remove → description withdrawn *before* deletion, and refuses for a
      discovered copy; a coalesced double-accept → one install
- [ ] register both new Core files in `LSPSourceGatingTests.expectedCoreFiles`
- [ ] run `swift test`

### Task 7: App — the machine-knowledge seams

One macOS-gated file, the app's whole contribution: where `go` and `gopls` live
on *this* Mac, and what running `go install` means here.

**Files:**
- Create: `Sources/Pisaka/LSPGoToolchainService.swift`
- Modify: `Tests/PisakaCoreTests/LSPSourceGatingTests.swift`

- [ ] discovery: locate `go` (login `PATH`, `/usr/local/go/bin`, Homebrew
      prefixes), then ask it `go env GOBIN GOPATH` and look for `gopls` in
      `GOBIN`, `GOPATH/bin` and `~/go/bin`; cache the whole answer per app run
      **including the negative one**, resolve off the main thread, never block a
      caller — `LSPToolchain`'s discipline, and its pipe-draining and `/dev/null`
      stdin discipline too
- [ ] install: `go install golang.org/x/tools/gopls@<version>` with `GOBIN` set to
      the staging directory the model passes, environment otherwise inherited
      untouched, stdout and stderr drained, the last lines of stderr kept as the
      failure sentence the row shows, and a SIGTERM→SIGKILL teardown on
      cancellation so a quit mid-build leaves no `go` child
      (`LSPProcessTransport`'s rule)
- [ ] add the file to `LSPSourceGatingTests.expectedAppFiles`; it is gated
      `#if os(macOS)` from its first significant line to its last
- [ ] run `swift test` (the gating suite is what covers this file; the seam itself
      is untested by convention, like `LSPDownloadService`)

### Task 8: App — wiring, the banner branch and the Settings row

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift`, `Sources/Pisaka/ContentView.swift`,
  `Sources/Pisaka/LSPConsentBanner.swift`,
  `Sources/Pisaka/LSPServerSettingsView.swift`

- [ ] compose the model once in `PisakaApp.init` beside the provisioning pair,
      kick off discovery there (the `LSPToolchain.prewarm()` position), and merge
      the two registry contributors into one awaited
      `LSPWorkspace.updateRegistry(_:)` push, base entries first so a
      hand-registered override still wins
- [ ] extend the terminate observer so an in-flight `go install` is torn down with
      the rest — no orphan `go` (or `gopls`) after quit
- [ ] give the banner a Go branch: same strip, same two actions and no dismiss,
      copy that says what actually happens ("Install gopls with your Go
      toolchain?" — built from source by your own `go`, nothing downloaded by
      Pisaka), and the same `.task(id:)` silent half calling the model's
      prepare-on-open; the download branch keeps precedence if both ever apply
- [ ] give the Settings tab a Go row rendering D19's five states, with
      Install/Retry and a Remove that appears only for the app-installed copy,
      plus one sentence naming gopls's origin and BSD-3-Clause licence — gopls
      ships no licence file into `GOBIN`, so there is nothing for
      `LSPInstalledLicenses` to read and nothing for `licenses.json` to cover
      (this app bundles no gopls bytes); the sentence is the honest substitute,
      and the decision is written down rather than left as an omission
- [ ] run `swift test`

### Task 9: Build both destinations and re-run the required-reason audit

**Files:**
- Modify: `docs/architecture/core-services.md` (the audit record)

- [ ] `xcodegen generate`, then build macOS and iOS (device arch,
      `generic/platform=iOS`) — the iOS build is what proves the new C compiles
      for every destination
- [ ] re-run the recorded `nm -u` audit over both built binaries and update the
      record with the date, the grammar that was added and the result
- [ ] update `Resources/PrivacyInfo.xcprivacy` **only if** the audit found
      something; the expectation is that a tree-sitter parser adds no
      required-reason API, and `ReleaseMetadataTests`' set equality is the gate
      either way
- [ ] run `swift test`

### Task 10: Verify acceptance criteria

- [ ] `swift test` — full suite green, every set-equality suite extended rather
      than weakened
- [ ] both destination builds succeed
- [ ] confirm no test was made more permissive: `SymbolQueryTests`,
      `LanguageKeywordsTests`, `SyntaxTokenKindTests`, `LicenseCoverageTests`,
      `DependencyPinTests`, `ReleaseMetadataTests`, `LSPSourceGatingTests` all
      still assert by set equality

### Task 11: Update documentation

**Files:**
- Modify: `docs/architecture/core-intelligence.md`, `docs/architecture/core-lsp.md`,
  `docs/architecture/core-provisioning.md`, `docs/architecture/app-editor.md`,
  `docs/architecture/core-services.md`, `CLAUDE.md`, `README.md`

- [ ] `core-intelligence.md`: the Go symbols query, its four decisions, and the
      confirmed capture table from the runtime check
- [ ] `core-lsp.md`: D17–D20 in full, the two new Core files' entries, and the
      known limits (shared `GOMODCACHE`/`GOCACHE`, `GOTOOLCHAIN=auto` possibly
      fetching a toolchain, no gopls on iOS ever)
- [ ] `core-provisioning.md`: a short cross-reference stating what gopls reuses
      (layout, remove, consent, banner, tab) and what it deliberately does not
      (manifest, download, digest, unpack) — so the next reader does not go
      looking for a gopls artifact
- [ ] `app-editor.md` / `core-services.md`: the grammar registry entry, the new
      app seam file, the refreshed audit record
- [ ] `CLAUDE.md`: index lines for the new Core and app files only — no essays
- [ ] `README.md`: Go in the highlighting, indexing and keyword lists; gopls in
      the semantic-intelligence section with the acquisition story stated plainly
      (used if already on your Mac; otherwise offered once and built by *your* Go
      toolchain; a Go toolchain is required either way, and nothing is downloaded
      by Pisaka), Go added to the run/test list with the single-file `go run`
      limit, and the de-provisioning paragraph noting that Remove and deleting the
      LanguageServers directory apply to the app-installed copy only

## Post-Completion Checks (manual)

On a Mac **with** a Go toolchain, in a real Go module:

- gopls already present (`~/go/bin/gopls`): it is discovered and used with **no
  prompt**; the Settings row reads "installed (found on this Mac)" and offers no
  Remove.
- gopls absent: the first `.go` file prompts **once**; accepting installs into the
  app's own tree and Go becomes semantic **without a restart**; the row then reads
  "installed by Pisaka · v0.23.0" and offers Remove.
- Declining persists across a relaunch and never re-prompts; Preferences turns it
  around.
- ⌘-click jumps to a symbol in another file **and another package**; completion
  after `.` on a typed value lists that type's members; completing a symbol from
  an unimported package inserts the `import` and the symbol as **one undo step**.
- `kill` gopls mid-session → the next request degrades to tree-sitter silently, no
  alert.
- Quit with an install in flight → `pgrep -f 'gopls|go install'` finds nothing.

On a Mac **without** a Go toolchain: no prompt ever, the Settings row says so, and
Go files highlight, index, complete and jump from the tree-sitter index.

On iOS/iPadOS (simulator or device): a `.go` file highlights, indexes, completes
(fuzzy + keywords + members) and jumps within the project — no language server
anywhere in sight.
