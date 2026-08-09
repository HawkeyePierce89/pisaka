# Rust language support

## Overview

Add Rust as a first-class language across the whole stack, following the template
Go proved: the tree-sitter half (highlighting, symbol index, fuzzy/member
completion, keywords) as a set of records on all platforms, and semantic
intelligence on macOS through **rust-analyzer**.

The acquisition story is the hybrid the ticket names, and it composes machinery
that already exists rather than adding a layer: **discovery first** (rustup users
already have `~/.cargo/bin/rust-analyzer`), **the 2b download second** (unlike
gopls, rust-analyzer publishes official prebuilt binaries). The one genuinely new
mechanism is the archive format — those binaries are bare `.gz`, not tarballs —
which is the moment `LSPArchiveFormat` was designed for.

Everything the set-equality suites can see is driven by them:
`SyntaxLanguage.allCases` gains `.rust` and `SymbolQueryTests`,
`LanguageKeywordsTests`, `LicenseCoverageTests`, `DependencyPinTests` start
failing until each record exists. The implementation follows those failures.

### The pins (resolved during planning — implementation needs no network for these)

| what | pin | provenance |
|---|---|---|
| `tree-sitter-rust` | `exactVersion: "0.24.2"` → tag `v0.24.2`, revision `77a3747266f4d621d0757825e6b11edcbf991ca5` | `github.com/tree-sitter/tree-sitter-rust`, MIT (© 2017 Maxim Sokolov) |
| rust-analyzer | release `2026-08-03` (`rust-analyzer 0.3.2997-standalone`) | `github.com/rust-lang/rust-analyzer`, Apache-2.0 OR MIT |

**The grammar's manifest, read at the pinned revision — the sharp check this
grammar needed and Go's did not:**

- `sources:` is `["src/parser.c", "src/scanner.c"]`. **The external scanner is
  compiled.** This is *not* the `TreeSitterDotenv` failure mode, so the grammar is
  pinned remotely and nothing is vendored. The plan records that as a finding, and
  the iOS device build in Task 11 is the link-time proof.
- Package **and** target are both `TreeSitterRust`, so the resource bundle is
  `TreeSitterRust_TreeSitterRust` — what `LanguageConfiguration(…, name: "Rust")`
  already expects. Swift binding header `bindings/swift/TreeSitterRust/rust.h`,
  entry point `tree_sitter_rust()`. `queries/highlights.scm` ships (plus
  `injections.scm`/`tags.scm`, neither of which this app reads).
- Its manifest declares `.package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.9.0")`
  — the **same package identity** the root pins `branch: main`. It is a
  *test-target-only* dependency and SwiftPM prunes those for a non-root package,
  so resolution adds exactly one pin and provokes no "required using two different
  requirements" failure. This is already proven in this repository rather than
  assumed: `tree-sitter-python` 0.23.6 and `tree-sitter-css` 0.23.2 declare the
  same dependency (`from: "0.8.0"`) and have resolved cleanly since they were
  pinned.
- **Vendored-subtree check: nothing beyond `src/tree_sitter/{alloc,array,parser}.h`**,
  tree-sitter's own MIT headers, already covered by the existing `tree-sitter`
  license entry. `src/scanner.c` is upstream's own code under upstream's own MIT.
  Unlike libgit2's `deps/xdiff` and tree-sitter's `lib/src/unicode`, there is no
  second license to append. That *nothing was found* is the finding to record.
- The C is a parser plus a scanner: no file, network, disk-space, boot-time,
  keyboard or `UserDefaults` API. The audit is re-run over both built binaries
  anyway (Task 11), and the expectation is `PrivacyInfo.xcprivacy` unchanged.

**The highlight query's capture vocabulary at that revision** is 21 names:
`attribute`, `comment`, `comment.documentation`, `constant`, `constant.builtin`,
`constructor`, `escape`, `function`, `function.macro`, `function.method`,
`keyword`, `label`, `operator`, `property`, `punctuation.bracket`,
`punctuation.delimiter`, `string`, `type`, `type.builtin`, `variable.builtin`,
`variable.parameter`. **All 21 already resolve to a non-`.plain` kind** — checked
name by name against `SyntaxTokenKind.nameMap`, the `escape` lesson applied rather
than assumed. Worth recording: `escape` resolves only because the Go work added
`"escape": .string`; without it every `\n` in a Rust string would render
default-colored. So this task adds no map entry, and the reason it needs none is
itself the thing to write down.

**rust-analyzer's macOS artifacts, resolved and measured while planning:**

| arch | URL (release `2026-08-03`) | SHA-256 | bytes | unpacked |
|---|---|---|---|---|
| arm64 | `…/download/2026-08-03/rust-analyzer-aarch64-apple-darwin.gz` | `bba6cd8209643cd781f3ee5474fa232d3ee1b77a57f2e77982806e3c80a65207` | 13,873,448 | 37,914,480 |
| x64 | `…/download/2026-08-03/rust-analyzer-x86_64-apple-darwin.gz` | `8966f9429085c243817b9d13afa76e98920668c07a9b432901daaf047397c6cb` | 14,576,027 | 39,382,228 |

Both were downloaded, hashed, gunzipped and — for the arm64 slice, on this Mac —
executed. Two facts that would otherwise be assumptions: the binary is
`adhoc, linker-signed` Mach-O arm64, so it launches on Apple Silicon without any
signing step of ours; and `URLSession` bytes written by this app carry no
`com.apple.quarantine`, exactly as the Node binaries this layer already installs
do not.

### The symbols query (authored and statically validated during planning)

Every node, field and literal below was checked against `src/node-types.json` at
the pinned revision — all declared, all `named: true`, each field on the node the
query hangs it off. The runtime half is a task step.

```scheme
; Types. Unanchored: a type declaration means the same thing wherever written.
(struct_item name: (type_identifier) @definition.type)
(enum_item   name: (type_identifier) @definition.type)
(union_item  name: (type_identifier) @definition.type)
(trait_item  name: (type_identifier) @definition.type)
(type_item   name: (type_identifier) @definition.type)

; Struct fields are properties of their struct.
(struct_item
  name: (type_identifier) @container
  body: (field_declaration_list
          (field_declaration name: (field_identifier) @definition.property)))

; Enum variants are constants of their enum.
(enum_item
  name: (type_identifier) @container
  body: (enum_variant_list (enum_variant name: (identifier) @definition.constant)))

; Free functions, anchored.
(source_file (function_item name: (identifier) @definition.function))
(mod_item body: (declaration_list (function_item name: (identifier) @definition.function)))

; Inherent and trait impls. `type:` binds the *implementing* type in both
; `impl Type` and `impl Trait for Type`; the generic wrapper is stepped through,
; so `impl<T> Worker<T>` files under `Worker`.
(impl_item
  type: (type_identifier) @container
  body: (declaration_list (function_item name: (identifier) @definition.method)))
(impl_item
  type: (generic_type type: (type_identifier) @container)
  body: (declaration_list (function_item name: (identifier) @definition.method)))
(impl_item
  type: (scoped_type_identifier name: (type_identifier) @container)
  body: (declaration_list (function_item name: (identifier) @definition.method)))

; Trait members: provided methods are `function_item`, required ones
; `function_signature_item`.
(trait_item
  name: (type_identifier) @container
  body: (declaration_list (function_item name: (identifier) @definition.method)))
(trait_item
  name: (type_identifier) @container
  body: (declaration_list (function_signature_item name: (identifier) @definition.method)))

; Top-level consts and statics.
(source_file (const_item name: (identifier) @definition.constant))
(source_file (static_item name: (identifier) @definition.variable))
(mod_item body: (declaration_list (const_item name: (identifier) @definition.constant)))
(mod_item body: (declaration_list (static_item name: (identifier) @definition.variable)))
```

Six decisions in it, because they are decisions:

- **`impl Trait for Type` files under `Type`, not under `Trait`.** One rule for
  both impl forms, and it needs no second pattern: `type:` is the self type in
  both. It is also the rule the rest of the stack already assumes —
  `SymbolIntelligenceProvider`'s member branch answers "`.` after a value of type
  `Worker`" by looking up members whose container is `Worker`, and a `fmt` filed
  under `Display` would never surface there.
- **Generics are stripped by stepping through `generic_type`, not by editing the
  text** — Go's pointer-star reasoning verbatim.
  `[(type_identifier) (generic_type …)] @container` would capture the
  *`generic_type` node* for the generic case and put `<T>` back, so the shapes get
  one pattern each.
- **`mod_item body:` is anchored beside `source_file`, and `impl`/`trait` bodies
  are not** — all three are `declaration_list`, and naming the parent is what
  tells them apart exactly. The rule stated: an inline `mod` is a *namespace*, so
  a `fn` or `const` written there is as top-level as one in the file; an `impl` or
  `trait` body is a *container*, whose functions are methods and reach the
  container patterns instead; a function body holds locals and is anchored out.
- **`const` is a constant, `static` is a variable.** A `static` is Rust's global
  binding, `static mut` its mutable one — Go's package-level `var`, and the same
  mapping.
- **Not indexed, deliberately:** `macro_rules!` definitions, associated consts and
  associated types inside `impl`/`trait` bodies, `use` aliases, tuple-struct
  positional fields (`ordered_field_declaration_list` declares no names to
  capture), `union` fields, and `impl` blocks whose self type is a reference,
  tuple, slice or `dyn` type. Each is a real declaration; none is a name a reader
  jumps to often enough to pay for a pattern, and all are recorded rather than
  omitted.
- **The pin set** for `SymbolQueryTests`: 22 named nodes (`struct_item`,
  `enum_item`, `union_item`, `trait_item`, `type_item`, `field_declaration_list`,
  `field_declaration`, `enum_variant_list`, `enum_variant`, `source_file`,
  `mod_item`, `declaration_list`, `function_item`, `function_signature_item`,
  `impl_item`, `generic_type`, `scoped_type_identifier`, `const_item`,
  `static_item`, `type_identifier`, `identifier`, `field_identifier`), an **empty**
  anonymous-literal set, and three fields (`name`, `body`, `type`).

### Keywords: the rule, and where it draws the line

Rust's **38 strict keywords** (2021 edition: `as async await break const continue
crate dyn else enum extern false fn for if impl in let loop match mod move mut pub
ref return self Self static struct super trait true type unsafe use where while`),
the **17 primitive type names** (`bool char str`, `f32 f64`, `i8 i16 i32 i64 i128
isize`, `u8 u16 u32 u64 u128 usize`), and the one contextual keyword `union`.
**56 entries**, sorted, unique. `Self` sorts first — Swift orders uppercase before
lowercase, exactly as Python's list already opens with `False`/`None`/`True`.

Two lines drawn, both stated on the property:

- **Reserved-but-unusable words are out** (`abstract become box do final gen macro
  override priv try typeof unsized virtual yield`). The Go rule is "include an
  identifier when no source file can ever declare it", and its *purpose* is that
  no other completion source can offer it. These cannot appear in any valid Rust
  program at all, so completing to one can only produce a compile error.
- **`union` is in, `macro_rules` is out.** `union` is contextual and follows the
  precedent already set by Python's soft keywords `match`/`case`, which are in that
  list. `macro_rules` is out because the token a person actually types is
  `macro_rules!`, and a list of bare identifiers that completes to half of it is
  worse than not offering it — the buffer-word harvest picks it up the moment one
  exists in the file.
- **The prelude stays out** (`Option Result Some None Ok Err String Vec Box`), for
  the reason `fmt.Println` stayed out of Go's: they are declarations in a crate,
  and rust-analyzer or the index is what should offer them.

`f16`/`f128` are excluded as unstable; `_` is excluded per Go's precedent
(punctuation the user types directly).

### rust-analyzer: a third registry contributor — decisions D21–D24

To be recorded in `docs/architecture/core-lsp.md` beside D17–D20.

- **D21 — Rust is discovery-first *and* downloadable, and it is a third registry
  contributor rather than a fourth layer.** `LSPDownloadableServer` is
  **untouched** (still `typescript`/`python`), so 2b's enum, its set-equality tests,
  its rows and its banner branch keep saying exactly what they say now. What Rust
  reuses from 2b is the part that was already generic and string-keyed: the pinned
  `LSPComponent` in the manifest, `LSPInstallEngine.install(_ componentID:)`,
  `state(of:)`, `pendingDownloadByteCount(for:)` and `remove(_:)`, plus
  `LSPInstallLayout`'s path math and the download/unpack seams. What it does *not*
  reuse is `LSPProvisioningModel`, because Rust's honest state set is the **Go
  row's**, not the 2b row's: it has a toolchain gate and a discovered-copy state
  that no 2b server has. So the Settings row lives **beside the Go row** in the
  toolchain-gated section, with a download size where Go's has none. That is the
  ticket's open call, stated: a row that offered Install while saying "no Rust
  toolchain" would be a lie, and a 2b row cannot say the true thing.
- **D22 — The second archive format, and the bit `tar` used to carry.**
  `LSPArchiveFormat` gains `case gzip(fileName: String)` and loses its `String`
  raw value (unused anywhere). The associated value is where the *name* has to
  live: a tarball carries its members' names, a bare `.gz` does not, and the
  alternative — a parallel `LSPArtifact.unpackedFileName` — would let the manifest
  express "a gzip with no name" and "a tarball with one". `stripComponents` is
  meaningless for this case and is pinned to `0` by the manifest tests. The app
  unpacker gains the branch: `/usr/bin/gunzip` on stdin, stdout redirected
  straight into a destination file created with `posixPermissions: 0o755`, under
  the same deadline, `F_SETNOSIGPIPE` and SIGTERM→SIGKILL discipline `tar` already
  has — so the ~38 MB is never held a second time in memory and the bit is set at
  creation rather than patched afterwards. **The engine then verifies it**: after
  unpacking a `.gzip` artifact it asks `FileServicing.isExecutableFile(at:)` and
  throws `unpackFailed` if the answer is no, *before* the commit rename — so a
  binary that arrives unexecutable installs nothing and leaves the previous state
  alone, which is D13's promise applied to the one thing D13 could not see.
  `FileServicing` gains that one method **without a default**: a defaulted answer
  would be a gate that silently passes, and there are only three conformers in the
  app plus the test stubs.
- **D23 — The toolchain gate and the `PATH` overlay, applied from day one.**
  rust-analyzer shells out to `cargo` to build the project model, so without a
  toolchain it starts, answers almost nothing, and burns D7's restart budget per
  request while the Settings row claims it is installed — the exact failure the
  gopls `searchPath` lesson recorded. So: **no `cargo` → no prompt, no consent
  written, no registry entry, tree-sitter silently**, for a discovered
  rust-analyzer just as much as for a downloadable one. When a toolchain is found,
  the `PATH` that found it travels as the description's `environment` overlay,
  Core never learning what is in it (D9). Discovery follows `LSPToolchain`'s
  discipline exactly: off-main, non-blocking, cached per app run **including the
  negative answer**, `pending` while unresolved.
- **D24 — What is preferred, the row's states, the licence, and the pin's shape.**
  When both a discovered rust-analyzer and an app-installed one exist, **the app's
  copy wins** — D19's argument unchanged: it is the version this app pinned and
  the only one Remove may touch, and preferring the other would make Remove delete
  a copy that was not in use. The row reports seven states — *looking for a Rust
  toolchain…* / *no Rust toolchain* / *not installed (13.2 MB)* / *installing…* /
  *installed (found on this Mac)* / *installed by Pisaka · 2026-08-03* / a failure
  sentence with Retry — and offers **Remove only for the app's copy**, where it is
  the ordinary 2b removal through `engine.remove("rust-analyzer")`. Consent is the
  existing `LSPServerConsent` under id `"rust-analyzer"` in the same
  `SettingsStore` dictionary, so declining persists and is reversible from the same
  tab (D15). Licences: a bare `.gz` ships no licence file, so
  `licenseFileSubpaths` is empty, `LSPInstalledLicenses` has nothing to read and
  `licenses.json` covers nothing (this app bundles no rust-analyzer bytes) — the
  Go decision applies, and the honest substitute is one sentence in the row naming
  the origin and the `Apache-2.0 OR MIT` dual licence. The version pin is a
  **date** (`2026-08-03`), which is what upstream ships; it sorts correctly
  lexicographically, which is the one property `LSPInstallEngine.state(of:)` reads
  it for.

Three registry contributors now exist. `PisakaApp` composes them —
`LSPServerRegistry(provisioning.registry.descriptions + gopls.descriptions + rust.descriptions)`
— and awaits `LSPWorkspace.updateRegistry(_:)`, preserving D16's push-then-delete
ordering for all three. Every *rule* about when Rust contributes a description
lives in the Core model and is unit-tested there.

### Run/test commands

`TestCommand` already answers `cargo test` for `.rs`; now that Rust is a language
that becomes an assertion rather than a loose extension match.

`RunCommand` gets **no `rs` entry**, and that is the call, recorded as a known
limit with a test that pins it (`canRun("main.rs") == false`). The asymmetry is
real and explainable: `TestCommand` answers a command for a *directory*, so
`cargo test` fits; `RunCommand`'s map answers a command for a *single file* and
appends the quoted path, which `cargo run` cannot take. Rust has a project-level
runner and no file-level one — `rustc` compiles to a binary you then run, which is
two steps and a different thing. `cargo run` from the terminal panel is the answer,
and ⌘U works.

## Context

- **Files involved (Core, modified):** `SyntaxLanguage.swift`, `FileIcon.swift`
  (assert, not add — the `rs` extension is already mapped),
  `LSPServerDescription.swift` (`lspLanguageID` gains `.rust` → `"rust"`),
  `LanguageKeywords.swift`, `LSPProvisioningManifest.swift` (the format case + the
  `rust-analyzer` component), `LSPInstallEngine.swift` (the executable gate),
  `FileService.swift` (`isExecutableFile(at:)`).
- **Files involved (Core, new):** `LSPRustToolchain.swift` (the pin as data, the
  discovery report, the installation kinds, the consent prompt and the Settings
  row with its `canInstall`/`canRemove`/status rules), `LSPRustProvisioning.swift`
  (the one new seam protocol and the `@MainActor` model). Both carry the `LSP`
  prefix deliberately, so `LSPSourceGatingTests`' Core sweep holds them to
  Foundation-only.
- **Files involved (app, new, macOS-gated):** `LSPRustToolchainService.swift` —
  where `cargo` and `rust-analyzer` live on *this* Mac, plus `terminateNow()`.
  There is no second seam: the install is the existing download + unpack pair.
- **Files involved (app, modified):** `SyntaxLanguageConfiguration.swift`,
  `LSPArchiveUnpacker.swift` (the gunzip branch), `LSPConsentBanner.swift` (a Rust
  branch, stated precedence), `LSPServerSettingsView.swift` (the Rust row beside
  Go's), `PisakaApp.swift` (composition, prewarmed discovery, three-way registry
  merge, terminate), `ContentView.swift` (hand the third model to the banner).
- **Resources:** `Resources/Queries/rust/symbols.scm` (new),
  `Resources/Licenses/tree-sitter-rust.txt` (new),
  `Resources/Licenses/licenses.json`, `project.yml`,
  `Pisaka.xcodeproj/…/swiftpm/Package.resolved`.
- **Tests touched:** `SyntaxLanguageTests`, `FileIconTests`, `SyntaxTokenKindTests`,
  `SymbolQueryTests`, `LanguageKeywordsTests`, `LicenseCoverageTests`,
  `DependencyPinTests`, `ReleaseMetadataTests`, `RunCommandTests`,
  `TestCommandTests`, `LSPProvisioningManifestTests`, `LSPInstallEngineTests`,
  `FileServiceTests`, `LSPSourceGatingTests`, `Support/StubFileTree`,
  `Support/ScriptedInstallSeams`; new `LSPRustProvisioningTests`.
- **Related patterns:** `LSPGoToolchain`/`LSPGoplsProvisioning` (the whole row,
  consent and lifecycle shape), `LSPToolchain` (cached, non-blocking,
  negative-answer-included discovery), `LSPInstallEngine`'s stage-verify-rename,
  `SymbolQueryTests`' hand-pinned node sets, `SyntaxTokenKindTests`' hand-pinned
  dockerfile/Go capture tables.
- **Dependencies:** one new remote SwiftPM package, `tree-sitter-rust`.
  rust-analyzer is neither linked nor bundled; it arrives over the network at the
  user's request or not at all.

## Development Approach

- **Testing approach**: TDD where the rules are the deliverable (the archive
  format and the executable gate, the manifest component, the Rust
  toolchain/provisioning model, the keyword list, the query and its pins, the
  run/test decisions); regular for the two SwiftUI surfaces and the two `Process`
  seams, which stay thin and untested by convention.
- Complete each task fully — code, tests, green suite — before the next.
- Core stays Foundation-only: no `Process`, no `AppKit`, no `SwiftTreeSitter`.
  New `LSP*`-prefixed Core files are swept by `LSPSourceGatingTests`; the new app
  file carries `#if os(macOS)` from its first significant line to its last.
- Update set-equality suites by **extending** them, never by weakening an
  assertion into a containment check.
- `swift test` stays offline and subprocess-free: no network, no `tar`, no
  `gunzip`, no fixtures downloaded.
- Match existing comment density: these files carry their reasoning, not their
  mechanics.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**

## Implementation Steps

### Task 1: Pin the grammar and ship its license

**Files:**
- Modify: `project.yml`, `Pisaka.xcodeproj/…/swiftpm/Package.resolved`,
  `Resources/Licenses/licenses.json`
- Create: `Resources/Licenses/tree-sitter-rust.txt`
- Modify: `Tests/PisakaCoreTests/LicenseCoverageTests.swift`

- [x] add the `tree-sitter-rust` package (`exactVersion: "0.24.2"`) and the
      `TreeSitterRust` product to `project.yml`, in the grammar list's existing
      position, with a comment recording the two facts that matter for this
      grammar: its `sources:` **does** compile `src/scanner.c` (so no vendoring),
      and its test-only ChimeHQ/SwiftTreeSitter dependency is pruned exactly as
      `tree-sitter-python`'s and `tree-sitter-css`'s already are
- [x] regenerate the workspace `Package.resolved` and confirm it gained **exactly
      one** pin (identity `tree-sitter-rust`, revision
      `77a3747266f4d621d0757825e6b11edcbf991ca5`, version `0.24.2`) in the v2
      schema — a diff that rewrites the whole file into the legacy v1 shape is the
      Xcode-26 format churn Go's Task 1 recorded, and must be discarded rather
      than committed
      *(Confirmed: `xcodebuild -resolvePackageDependencies` resolved
      `TreeSitterRust @ 0.24.2` at exactly the planned revision and then rewrote
      the whole file into the v1 `object.pins`/`repositoryURL` shape — discarded,
      as Go's Task 1 recorded, and the one pin hand-inserted in v2 form. The
      committed diff is +9 lines, nothing else touched.)*
- [x] copy the verbatim MIT `LICENSE` from the checkout at the pinned revision to
      `Resources/Licenses/tree-sitter-rust.txt` and add the `licenses.json` entry
      (id/name `tree-sitter-rust`, origin, version `0.24.2`, that revision, spdx
      `MIT`), extending `LicenseCoverageTests`' hand-pinned copyright-holder table
      with © 2017 Maxim Sokolov
- [x] read the pinned checkout for vendored third-party trees and record the
      finding either way — the expectation is nothing beyond
      `src/tree_sitter/{alloc,array,parser}.h`, already covered by the
      `tree-sitter` entry, so no appended sub-dependency notice
      *(Finding, as expected and now recorded in
      `testTextsCarryTheirBundledSubDependencyNotices`: `src/` holds only
      `parser.c`, `scanner.c`, the two generated JSON files and
      `tree_sitter/{alloc,array,parser}.h`; no copyright or licence string
      appears anywhere under `src/` or `bindings/`. `scanner.c` is upstream's own
      code under upstream's own MIT, so the shipped text is `LICENSE` verbatim
      with no appendix. The manifest was also read at the pinned revision and
      confirms both planning findings: `sources:` is
      `["src/parser.c", "src/scanner.c"]`, and SwiftTreeSitter is named only by
      the test target.)*
- [x] run `swift test` — `DependencyPinTests` and `LicenseCoverageTests` green
      *(full suite: 2218 tests, 0 failures)*

### Task 2: The language case, its icon, its grammar and its capture vocabulary

**Files:**
- Modify: `Sources/PisakaCore/SyntaxLanguage.swift`,
  `Sources/PisakaCore/LSPServerDescription.swift`,
  `Sources/Pisaka/SyntaxLanguageConfiguration.swift`
- Modify: `Tests/PisakaCoreTests/SyntaxLanguageTests.swift`,
  `Tests/PisakaCoreTests/FileIconTests.swift`,
  `Tests/PisakaCoreTests/SyntaxTokenKindTests.swift`

- [x] add `case rust` and the `"rs"` extension mapping; pin that `main.rs`
      resolves, that the raw value is `rust` (the ` ```rust ` fence path through
      `configuration(forInjectionName:)`), and that no prefix or dot-ignore rule
      can claim a Rust name
      *(`testRustNamesResolve`/`testRustLookalikesDoNotResolveToRust` added;
      `rs` moved out of the two "unknown extension" tests, which kept their
      shape with `rst`/`zip` standing in. `testRawValuesAreStable` now pins both
      spellings the injection path tries — raw value `rust` and extension `rs`.)*
- [x] assert `FileIcon` already maps `rs` rather than adding it, so icon and
      language cannot drift apart; give Rust the `lspLanguageID` `"rust"`
      *(`FileIcon`'s map was already `rs` → code-glyph/orange and is untouched;
      `FileIconTests` now pins it beside Go's. `lspLanguageID` gains
      `case .rust: return "rust"`, pinned in `LSPServerRegistryTests`.)*
- [x] load the grammar in `SyntaxLanguageConfiguration` —
      `LanguageConfiguration(tree_sitter_rust(), name: "Rust")` plus
      `import TreeSitterRust`
      *(The macOS build succeeds, so the module imports, the C entry point
      resolves and the package links — the planning finding that package and
      target share the name `TreeSitterRust`, and so need no explicit
      `bundleName:`, holds.)*
- [x] pin the highlight query's 21 capture names by hand in `SyntaxTokenKindTests`
      (the dockerfile/Go precedent), read out of the resolved checkout at the
      pinned revision, asserting each resolves to its expected kind **and** that
      none resolves to `.plain`; note on the table that `escape` resolves only
      because of the Go-era `"escape": .string` entry
      *(Re-read from the resolved checkout at revision `77a3747266…`: exactly
      the 21 names the plan lists, no more. All 21 resolve non-`.plain` with no
      `nameMap` change, and the count is asserted so a table that loses a row
      fails rather than passing quietly.)*
- [x] `LanguageKeywords.keywords(for:)` is a total switch — add the
      `case .rust: return []` placeholder with a comment saying Task 4 replaces it
      (never a `languagesWithoutKeywords` entry)
- [x] run `swift test` — expect exactly two failures, `SymbolQueryTests` and
      `LanguageKeywordsTests`; those are Tasks 3 and 4
      *(2221 tests, exactly 2 failures, and exactly those two:
      `testEveryLanguageShipsASymbolsQueryExceptTheUnindexableOnes` and
      `testEveryLanguageEitherHasKeywordsOrIsExcluded`. Both are the set-equality
      suites doing their job — `.rust` is in `allCases` with neither a query
      directory nor a keyword list yet.)*

### Task 3: The symbols query

**Files:**
- Create: `Resources/Queries/rust/symbols.scm`
- Modify: `Tests/PisakaCoreTests/SymbolQueryTests.swift`

- [x] write `symbols.scm` as drafted above, with a header comment stating the
      shared capture convention and the six decisions (the implementing type as
      container for both impl forms, stepping through `generic_type` rather than
      alternating, `mod_item body:` anchored beside `source_file` while
      `impl`/`trait` bodies are not, `const`→constant / `static`→variable, and
      what is deliberately not indexed)
      *(Written as drafted. The sixth decision the header states as its own is
      the trait pair — provided methods are `function_item`, required ones
      `function_signature_item` — with the not-indexed list beside it.)*
- [x] add Rust to `SymbolQueryTests.pinnedNodeNames` with its 22 named nodes, its
      empty anonymous-literal set and its three fields (`name`, `body`, `type`) —
      the coverage, capture-vocabulary and predicate-free assertions then cover it
      automatically
      *(The pin's comment records what the empty anonymous set hides: every
      distinction this query draws is drawn by a named node or a field, and
      `generic_type`/`scoped_type_identifier` appear only to be stepped through.
      The suite's "eleven remote grammars" doc comment became twelve.)*
- [x] re-verify every pinned name against the *resolved* checkout's
      `src/node-types.json` under the matching `named` flag, and confirm the
      checkout revision is `77a3747266…`
      *(Checkout revision confirmed `77a3747266f4d621d0757825e6b11edcbf991ca5`.
      All 22 node names are declared with `named: true`; no name the query uses
      is an anonymous token; and each of `name`/`body`/`type` is declared on the
      node the query hangs it off — checked pair by pair, not merely as a global
      field set.)*
- [x] runtime half of the documented recipe: compile the query against the grammar
      and run it over a fixture `.rs` file exercising every pattern — a struct with
      fields, a tuple struct, an enum with variants, a union, a trait with both a
      provided and a required method, a type alias, `impl Worker`,
      `impl<T> Worker<T>`, `impl Display for Worker`, `impl foo::Bar`, a free `fn`,
      an inline `mod` with a `fn`/`const`/`static`, top-level `const`/`static`, and
      a function-local `fn`/`const` that must **not** be indexed — then record the
      confirmed element-by-element capture table in
      `docs/architecture/core-intelligence.md`, including the `impl` case proving
      methods file under the bare type name with generics stripped and the enum
      case proving variants file under the enum
      *(No `tree-sitter` CLI on this Mac and none needed: the runtime was
      compiled from the resolved `tree-sitter` checkout together with the
      grammar's `parser.c` **and `scanner.c`** into a throwaway
      `ts_query_new`/`ts_query_cursor` harness — which also exercises the
      external scanner outside Xcode. The query compiled to 18 patterns /
      7 captures and **all 18 fired**. Confirmed: `impl<T> Holder<T>` files
      `get` under `Holder` with no `<T>`; `impl fmt::Display for Worker` files
      `fmt` under `Worker`, not `Display`; `impl deep::Nested` files under
      `Nested`; `State`'s three variants file under `State`. The negatives held
      too — locals in `new`/`main_entry`, `macro_rules!`, the `use … as` alias,
      tuple-struct and union fields, the trait's associated `const`/`type`, and
      a struct-variant's own fields — the last of which the plan had not listed
      and is now recorded in the not-indexed set on both the query and the doc.)*
- [x] run `swift test` — `SymbolQueryTests` green
      *(`SymbolQueryTests` 9 tests, 0 failures. The suite's one remaining
      failure is `LanguageKeywordsTests`, which is Task 4's — Task 2 left
      `case .rust: return []` as the placeholder it names.)*

### Task 4: Rust keywords

**Files:**
- Modify: `Sources/PisakaCore/LanguageKeywords.swift`
- Modify: `Tests/PisakaCoreTests/LanguageKeywordsTests.swift`

- [x] add the 56-entry Rust list per the stated rule, sorted and duplicate-free,
      with the rule and both lines it draws written on the property (reserved-but-
      unusable words out; `union` in and `macro_rules` out, with the Python soft-
      keyword precedent named; the prelude out); note that `Self` sorts first
      *(The property states the primitives' inclusion under Go's rule verbatim —
      an identifier belongs here when no source file can ever declare it — and
      draws **three** lines rather than two, the third being the unstable
      `f16`/`f128` and `_`, which the plan had recorded as an aside rather than
      as a line.)*
- [x] replace the Task 2 placeholder with `case .rust: return rust`; leave
      `languagesWithoutKeywords` alone
- [x] extend `LanguageKeywordsTests` with the content pins the shape invites — the
      38 strict keywords in full, a representative of each primitive family
      (`i32`, `u128`, `usize`, `f64`, `bool`, `char`, `str`), `union` present, and
      the line the list must not cross: `abstract`, `virtual`, `yield`, `Option`,
      `Some`, `Vec`, `macro_rules` all absent, and no entry containing `!`, `:` or
      a dot. `testTheDocumentedLanguagesAreTheOnesWithLists` gains `.rust` by
      extension, still set equality
      *(Pinned by **set equality** against the union of the three families, Go's
      precedent, rather than by the representative subset alone — a subset check
      is what a hand edit slips through. The representatives are asserted too, so
      a family lost wholesale is named rather than read out of a set diff, and
      the count is pinned at 56 so a duplicate fails. `Self` leading the sorted
      list is asserted as its own line.)*
- [x] run `swift test` — full suite green again
      *(2223 tests, 0 failures — the last of the two set-equality failures Task 2
      deliberately left is now closed.)*

### Task 5: Run and test commands for Rust

**Files:**
- Modify: `Tests/PisakaCoreTests/RunCommandTests.swift`,
  `Tests/PisakaCoreTests/TestCommandTests.swift`

- [x] pin `TestCommand` now that Rust is a language: `foo.rs` resolves to
      `cargo test`, and Rust inherits neither Go's `_test.go` nor JS's infix
      `.test.` convention — every `.rs` file is a test target because Rust's tests
      live beside the code
      *(`testIsTestFileRust` now pins the three foreign conventions as answering
      **true** — `foo_test.rs`, `test_foo.rs`, `foo.test.rs` are testable for the
      same reason `lib.rs` is, not because they matched anything — so the failure
      mode a borrowed suffix check would introduce is *excluding* files, and the
      test says so. `testRustAlwaysResolves` gained the second half of the rule:
      `cargo test` takes neither the file nor its directory, so the command is
      one constant string, no evidence is consulted, and a path full of shell
      metacharacters cannot reach the command line at all — unlike Go's.)*
- [x] pin the `RunCommand` decision rather than leaving it implied:
      `canRun("main.rs")` is `false` and `command(forFileName:)` answers `nil`,
      with the test's comment carrying the reason (the map runs one file; Rust has
      a project runner and no file runner)
      *(`testRustHasNoRunner`, in its own MARK section so it reads as a decision
      rather than as `.rs` falling through the "unsupported" test beside `.md`
      and `Makefile`. The uppercase `MAIN.RS` is pinned too, since `canRun`
      lowercases before the lookup and an entry added later would answer both.)*
- [x] assert `SyntaxLanguage(forFileName:)`, `isTestFile` and `canRun` agree on one
      Rust file
      *(`testRustRunTestAndLanguageAgreeOnTheSameFile`, in the shape of the Go
      agreement test it sits beside — and it is the one place the asymmetry is
      stated rather than implied: same file, `.rust` / testable / **not**
      runnable.)*
- [x] run `swift test`
      *(2225 tests, 0 failures.)*

### Task 6: The second archive format and the executable-bit gate

The mechanism half of the download path, end to end: the enum's second case, the
engine's new pre-commit gate, and the app unpacker's branch. TDD — the rules are
the deliverable.

**Files:**
- Modify: `Sources/PisakaCore/LSPProvisioningManifest.swift`,
  `Sources/PisakaCore/LSPInstallEngine.swift`,
  `Sources/PisakaCore/FileService.swift`,
  `Sources/Pisaka/LSPArchiveUnpacker.swift`,
  `Sources/Pisaka/iOS/SecurityScopedBookmarks.swift` (the decorator forwards)
- Modify: `Tests/PisakaCoreTests/Support/StubFileTree.swift`,
  `Tests/PisakaCoreTests/Support/ScriptedInstallSeams.swift`,
  `Tests/PisakaCoreTests/LSPInstallEngineTests.swift`,
  `Tests/PisakaCoreTests/FileServiceTests.swift`,
  `Tests/PisakaCoreTests/LSPProvisioningManifestTests.swift`

- [x] `LSPArchiveFormat` gains `case gzip(fileName: String)` and drops its unused
      `String` raw value, with D22's reasoning on the case — why the name lives in
      the payload, and why the case implies "and it is executable"
      *(`LSPArtifact.stripComponents`' own doc was corrected in the same edit: it
      claimed "every artifact here is 1", which stops being true the moment this
      case exists.)*
- [x] `FileServicing` gains `isExecutableFile(at:) -> Bool`, **undefaulted**, with
      the reason written on it; implement in `FileService`, forward in
      `SecurityScopedFileService`, add to `StubFileTree` (an injectable per-path
      executable bit) and to the small local stubs `swift test` compiles
      *(Ten conformers in all — `FileService`, the iOS decorator, `StubFileTree`
      and seven local test stubs. `FileService` answers `false` for a directory
      rather than forwarding `FileManager`'s search-permission `true`, since the
      gate is asked about a file an unpack was supposed to produce.
      `StubFileTree.move`/`removeItem` carry the bit with the file, as a rename
      does on a real volume — without that a binary unpacked into staging would
      arrive at its version directory unexecutable, a property of the stub and of
      nothing else.)*
- [x] `LSPInstallEngine.perform` verifies, after unpacking a `.gzip` artifact and
      **before** `commit`, that the named file is executable — otherwise
      `unpackFailed`, the staging tree is discarded and nothing is renamed
      *(Per artifact rather than per component, so the check runs at the point the
      destination is still in hand and a component mixing formats needs no second
      rule.)*
- [x] `LSPArchiveUnpacker` gains the gzip branch: `/usr/bin/gunzip` fed the
      verified bytes on stdin, stdout redirected into a destination file created
      with `posixPermissions: 0o755`, under the same deadline, `F_SETNOSIGPIPE`
      and SIGTERM→SIGKILL teardown as the tar path; `stripComponents` is ignored
      here and the switch stays exhaustive
      *(The two formats now differ in exactly one place — where stdout goes — so
      `run` was generalised over a `tool`, its arguments and an `Output` of
      `.discarded` (a drained pipe, `tar`) or `.file` (the destination handle,
      `gunzip -c`). The stdout drain thread exists only for the pipe case: a file
      never blocks its writer the way a full pipe does. `Failure.tarUnavailable`
      became `toolUnavailable` and gained `destinationUnwritable`, which happens
      before anything is launched and so has no exit status to report.)*
- [x] tests: a `.gzip` artifact whose unpack produces an executable installs and
      commits with exactly one rename; one whose unpack produces a **non-executable**
      file throws `unpackFailed`, records **no** move, leaves the version directory
      absent and a previous install untouched; a `.gzip` install still discards its
      staging tree on a checksum mismatch; and **every existing tar-based component
      still installs unchanged**
      *(Five tests over two new fixture components — `binary` 1.0.0 and its 2.0.0
      bump, so the "previous install byte-for-byte" case is a real upgrade rather
      than a re-install. `ScriptedUnpacker` gained `forgetExecutableMode(_:)` and
      now materialises a `.gzip` archive as one file named by the format, marked
      executable, which is what the real unpacker does. The tarball test asserts
      the gate is `.gzip`'s alone: nothing the tar path writes is executable in
      the stub tree and it installs anyway.)*
- [x] `LSPProvisioningManifestTests` gains the invariant that a `.gzip` artifact
      declares `stripComponents == 0`
      *(Written as a switch over the format so both halves are stated — tarballs
      still pinned at 1 — rather than as a weakened "0 or 1". Vacuous for `gzip`
      until Task 7 adds the component, which is the point: the assertion is there
      before the data is.)*
- [x] run `swift test`, then the macOS build (Go's Task 7 precedent — `swift test`
      compiles `PisakaCore` alone and cannot see the unpacker)
      *(2231 tests, 0 failures; `xcodebuild -destination 'platform=macOS'`
      BUILD SUCCEEDED.)*

### Task 7: The rust-analyzer manifest component

**Files:**
- Modify: `Sources/PisakaCore/LSPProvisioningManifest.swift`
- Modify: `Tests/PisakaCoreTests/LSPProvisioningManifestTests.swift`

- [x] add `LSPComponent.rustAnalyzer` — id `rust-analyzer`, version `2026-08-03`,
      `licenseSPDX: "Apache-2.0 OR MIT"`, **empty** `licenseFileSubpaths` with the
      reason on it (a bare `.gz` ships no licence file; the Settings row's sentence
      is the substitute), `requires: []`, `executableSubpath: "bin/rust-analyzer"`,
      and the two architecture-tagged artifacts with the URLs, SHA-256s, byte
      counts and unpacked sizes from the table above,
      `format: .gzip(fileName: "rust-analyzer")`, `stripComponents: 0`,
      `destinationSubpath: "bin"`
- [x] add it to `LSPProvisioningManifest.standard`, and record in the manifest's
      by-hand update procedure how these numbers were obtained (download,
      `shasum -a 256`, `gunzip` + `ls -l`) — the procedure this component's *dated*
      version makes people re-run more often than the others
      *(A third recipe beside Node's and npm's, with `curl -o` rather than a pipe
      stated as the point: the URL redirects to `objects.githubusercontent.com`,
      so both the digest and the byte count have to come from the bytes that
      actually arrive. `unpackedByteCount` is exact here rather than rounded — one
      file, nothing for `du` to round to a block size. The two by-hand
      confirmations no test can make are named: `file` must report the slice the
      `architecture:` claims, and the published binary is `adhoc, linker-signed`,
      so a future unsigned release would pass the executable gate and die at
      `exec` — worth a `--version` before shipping a pin. `standard`'s own doc now
      records why the component is there with no `LSPDownloadableServer` case.)*
- [x] tests: the component resolves, its two artifacts split cleanly by
      architecture (exactly one per slice), `installationOrder` is the single
      component (nothing required), the digests are 64 lowercase hex, the URLs are
      HTTPS and name the pinned release, and the empty `licenseFileSubpaths` is
      asserted **as a decision** rather than passing by accident
      *(Four new tests; three existing ones extended rather than weakened. The
      arch test's "everything that is not node is an npm tarball" rule became a
      hand-written native set (`node`, `rust-analyzer`) checked both ways, so a
      native artifact carrying `nil` fails as loudly as an npm one carrying
      `.arm64`. The licence test learned `OR` beside `AND` — the operands are what
      it validates, and the first `OR` expression must not read as unrecognised —
      and pins the empty-subpath exemption by id. A fourth test the plan did not
      list closes the gap `.gzip` opens: the file name is spelled twice, in the
      format's payload and inside `executableSubpath`, and nothing at runtime
      compares them, so a mismatch installs cleanly and `ENOENT`s on every start.
      `LSPDownloadableServer`'s set equality is asserted **unchanged** in the same
      suite, which is D21 stated as a test.)*
- [x] run `swift test`
      *(2235 tests, 0 failures.)*

### Task 8: Core — the Rust toolchain and rust-analyzer domain

Everything decision-shaped, in Foundation alone: what states exist, when a prompt
may be offered, what the Settings row may do, what the registry gets, and the one
seam the app fills in. TDD.

**Files:**
- Create: `Sources/PisakaCore/LSPRustToolchain.swift`,
  `Sources/PisakaCore/LSPRustProvisioning.swift`
- Create: `Tests/PisakaCoreTests/LSPRustProvisioningTests.swift`
- Modify: `Tests/PisakaCoreTests/Support/ScriptedInstallSeams.swift`,
  `Tests/PisakaCoreTests/LSPSourceGatingTests.swift`

- [x] value types: `LSPRustAnalyzer` (the pin as data — component id, display name,
      executable name/subpath, origin, licence SPDX — deriving what it can from
      the manifest component rather than restating it), `LSPRustToolchainReport`
      (`.missing` / `.found(cargoPath:searchPath:rustAnalyzerPath:)`, with
      `searchPath` load-bearing per D23), `LSPRustAnalyzerInstallation`
      (`.discovered(path:)` / `.appInstalled(version:path:)`),
      `LSPRustConsentPrompt` (carrying the download byte count, unlike Go's), and
      `LSPRustServerRow` with `canInstall`/`canRemove`/status as properties so the
      views hold no logic — including the `pending` state, for the reason the Go
      row has one
      *(The "deriving what it can" clause was taken further than the plan drafted:
      `LSPRustAnalyzer` carries **only** what a manifest record has no field for —
      id, display name, origin — plus `component(in:)`. The version, the licence
      expression and the executable subpath are read *through* that from whichever
      manifest the engine was built over, so there is exactly one spelling of each
      and the tests can drive the model with a fixture pin. `LSPRustServerRow`
      gained `licenseSPDX` and `pendingDownloadByteCount` for the same reason: the
      view holds no logic, so the row is where both reach it.)*
- [x] the one seam: a discovery protocol answering the report — `Sendable`,
      `async`, never mentioning `Process`. There is deliberately no install seam:
      the install is `engine.install(LSPRustAnalyzer.componentID)`
- [x] the `@MainActor` model: pending-until-discovered lifecycle; **no toolchain →
      no prompt, no consent written, no description, and `install()` does nothing
      at all** (D23, and Go's "a row reading *no toolchain* beside a sentence about
      a failed attempt nobody made"); D24's app-copy-wins preference; consent under
      id `"rust-analyzer"` through `SettingsStore`; the silent "already accepted →
      install on first `.rs` open, once per app run, and never retry a failed
      attempt" rule; the install and removal delegated to the shared
      `LSPInstallEngine` with D16's push-then-delete ordering; the published
      description as `.executable(path:)` with the discovered `PATH` as its
      `environment` overlay; and an awaited change callback
      *(The model takes no `FileServicing` at all, unlike the gopls one: every
      disk question — is it installed, where is the executable, are there files to
      reclaim, how many bytes are still to fetch — is already an engine method,
      because unlike gopls this server *is* a manifest component. `status()` reads
      this model's own attempt before the engine's, so the row says "installing…"
      from the moment the user says yes rather than from the moment the engine
      claims the component.)*
- [x] tests: no toolchain → never prompts, never installs, contributes no
      description, even with a rust-analyzer discovered; discovered rust-analyzer +
      toolchain → used silently, no prompt, no Remove; accept → one install, a
      description appears, consent persists; decline → persists across a rebuilt
      model and never re-prompts; a failed install → row sentence plus Retry, no
      description, no second automatic attempt this run; Remove → description
      withdrawn *before* deletion, refuses for a discovered copy, and falls back to
      the discovered copy afterwards; a coalesced double-accept → one install; the
      negative discovery answer cached per app run; the prompt's byte count comes
      from `pendingDownloadByteCount` and is zero once installed
      *(Sixteen tests over a fixture manifest whose version is deliberately **not**
      the shipped `2026-08-03`, so a model that hard-coded the pin would fail here
      rather than pass by coincidence; one further test pins the two facts the
      shipped record has to state for the model's path math to work. The plan's
      "even with a rust-analyzer discovered" case turned out to be unrepresentable
      — `.missing` carries no path, which is D23 stated in the type — so the
      sharper case is staged instead: a Mac this app installed a copy on whose
      toolchain has since gone, where the row reads "no Rust toolchain", nothing is
      registered, and Remove is still offered for the files. A test the plan did
      not list covers the `.gzip` gate from up here: an unpack that forgets the
      executable bit installs nothing and the row says so.)*
- [x] register both new Core files in `LSPSourceGatingTests.expectedCoreFiles`
- [x] run `swift test`
      *(2254 tests, 0 failures.)*

### Task 9: App — the Rust toolchain discovery seam

**Files:**
- Create: `Sources/Pisaka/LSPRustToolchainService.swift`
- Modify: `Tests/PisakaCoreTests/LSPSourceGatingTests.swift`

- [x] discovery, in `LSPGoToolchainService`'s search order and with its discipline:
      the inherited `PATH` first, then `~/.cargo/bin` (where rustup puts both
      `cargo` and the `rust-analyzer` proxy — this is the common case and the
      reason the ticket says discovery first), then Homebrew's prefixes, then the
      **login shell last** asked for `$PATH` (not `command -v`), so a
      version-manager shim is found at the cost of one subprocess; report the
      `PATH` that found `cargo` alongside it; a `cargo` that cannot answer
      `cargo --version` is reported as **no toolchain**; deadlines on both the
      login shell and the probe, because this runs at every launch on a Mac with no
      Rust at all
      *(The `--version` probe is applied to a **discovered rust-analyzer too**,
      which the plan did not list and which the `~/.cargo/bin` bullet is the reason
      for: rustup installs a `rust-analyzer` proxy there whether or not the
      component behind it was ever added, so on the single most common Rust setup
      an unprobed search finds an executable file that exits non-zero the instant
      anything asks it anything — a Settings row reading "installed (found on this
      Mac)" over Rust files that silently answer from the tree-sitter index, D23's
      failure with a different first cause. One subprocess, and only on machines
      that have a candidate. Both probes run under the `PATH` that found the
      `cargo` and inherit everything else — `RUSTUP_HOME`, `CARGO_HOME`,
      `RUSTUP_TOOLCHAIN`, proxy settings — so the probe's answer is the answer for
      the real thing rather than for a program run in an environment nothing else
      uses.)*
- [x] cache the whole answer per app run **including the negative one**, resolve
      off the main thread, never block a caller; a child registry that covers every
      process this file spawns, so `terminateNow()` leaves no login shell behind
      *(Cancellation is what the registry is really written for here, and the login
      shell is the child that has it: it is the only one that can outlive a quit,
      since a profile slow enough to hang is exactly why it has a deadline. A
      child killed by `cancel()` throws `.cancelled` rather than reporting its
      non-zero status, so a quit cannot become a cached "no Rust toolchain".)*
- [x] add the file to `LSPSourceGatingTests.expectedAppFiles`; `#if os(macOS)` from
      its first significant line to its last
- [x] run `swift test`, then the macOS build (the seam itself is untested by
      convention, like `LSPDownloadService`)
      *(2254 tests, 0 failures — the file is app-side, so the suite's own change is
      `testTheDiscoveredAppFilesAreExactlyTheExpectedOnes` and
      `testEveryAppLSPFileIsGatedToMacOS` picking it up.
      `xcodegen generate` + `xcodebuild -destination 'platform=macOS'`
      BUILD SUCCEEDED; `Package.resolved` untouched.)*

### Task 10: App — wiring, the banner branch and the Settings row

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift`, `Sources/Pisaka/ContentView.swift`,
  `Sources/Pisaka/LSPConsentBanner.swift`,
  `Sources/Pisaka/LSPServerSettingsView.swift`

- [x] compose the Rust model once in `PisakaApp.init` beside the other two, sharing
      the **same** `LSPInstallEngine` (one install root, one `sweepStaging()`),
      kick off discovery there, and merge the three registry contributors into one
      awaited `updateRegistry(_:)` push — each closure taking its own contributor's
      *new* value and reading the other two's published ones
      *(`makeRust(engine:settings:)` beside `makeGopls`, with the same defaulted
      arguments for the default-constructed `ContentView`. The unawaited
      `Task { await rust.discover() }` sits beside gopls's and carries the extra
      reason this one has: the banner's `.task` awaits discovery before it can
      silently install an already-accepted rust-analyzer, so it must join this
      task rather than start a second search.)*
- [x] extend the terminate observer so `lspRustToolchain.terminateNow()` runs
      beside the other two — no orphan process after quit, and permanently, so a
      `.rs` tab opening after the observer starts nothing
      *(The note records what this call is **not** for: the rust-analyzer download
      is `URLSession` bytes into a staging tree, which the process exit ends and
      the next launch's `sweepStaging()` reclaims — unlike gopls's `go install`,
      which has a compiler beneath it and is exactly what its `terminateNow()`
      exists to stop.)*
- [x] give the banner a Rust branch: same strip, same two actions, no dismiss, the
      download arrow and the **size** (it is a download), copy that says what
      actually happens; state the precedence between the three branches even though
      the contributors serve disjoint languages today
      *(Precedence stated as 2b → Go → Rust: the composition order, and the order
      the Settings tab lists them. Two things the copy deliberately does and does
      not say are written on `rustRow`: the version is named because it is a
      *date*, which is the one version string worth showing before someone agrees
      to a download; the toolchain is not mentioned at all, because D23 means this
      prompt cannot appear without a `cargo`, so the sentence would only ever be
      read by someone who already has one.)*
- [x] give the Settings tab a Rust row beside the Go row rendering D24's seven
      states, with Install/Retry, a Remove that appears only for the app-installed
      copy, and one sentence naming rust-analyzer's origin and its
      `Apache-2.0 OR MIT` dual licence — `LSPInstalledLicenses` deliberately has
      nothing to read, and that decision is written down rather than left as an
      omission
      *(The two toolchain-gated rows now form their own tail of the list, in the
      order that reads best: Go's row is never a download and Rust's always is.
      The licence sentence reads its SPDX expression off `rust.row`, which reads
      the manifest, so the text in the view cannot drift from the pin — and it
      states the gopls sentence's point arrived at from the opposite direction:
      this one *is* downloaded, but a bare `.gz` holding one binary unpacks no
      licence file for `LSPInstalledLicenses` to read. The `noToolchain` sentence
      carries three halves rather than Go's two, naming `cargo` explicitly, since
      "no Rust toolchain" beside a row titled Rust reads as if Rust itself were
      the thing Pisaka could not find.)*
- [x] run `swift test`, then the macOS build
      *(2254 tests, 0 failures — the four files are app-side, so the suite is
      unchanged by design; `xcodebuild -destination 'platform=macOS'`
      BUILD SUCCEEDED.)*

### Task 11: Build both destinations and re-run the required-reason audit

**Files:**
- Modify: `docs/architecture/core-services.md` (the audit record)

- [x] `xcodegen generate`, then build macOS and iOS (device arch,
      `generic/platform=iOS`, CI's own flags) — the iOS build is the link-time
      proof that the grammar's **external scanner** compiled and linked, the dotenv
      failure mode this grammar was checked for
      *(Both BUILD SUCCEEDED. The proof is sharper than "it linked": all five
      `_tree_sitter_rust_external_scanner_{create,destroy,serialize,deserialize,scan}`
      symbols are **defined** (`T`) in both binaries, so the dotenv shape — five
      undefined externals at the consuming app's link step — is ruled out by the
      linker rather than by reading upstream's `sources:`.)*
- [x] confirm `TreeSitterRust_TreeSitterRust.bundle` appears in the
      `-scanforprivacyfile` list of both Info.plist steps, and that the committed
      `Package.resolved` came through the pair byte-identical
      *(Present in both, in each case exactly once and beside the same 15 other
      grammar bundles — 16 per destination. `Package.resolved` hashes
      `db2ab036ee37f9a758e483ff78162e8d103823fbce35f57e935d456bf961f33a` before
      and after the `xcodegen generate` + two builds, and the worktree is clean,
      so neither the generate nor the resolves rewrote it.)*
- [x] re-run the recorded `nm -u` audit over both built binaries — including the
      check that the scanned files are non-trivial and that `_tree_sitter_rust` is
      **defined** in each — and update the record with the date, the grammar added
      and the result; sweep `Sources/` for new required-reason call sites from
      Tasks 6 and 9 (`isExecutableFile`, the discovery probes) and name them in the
      record either way
      *(2184 undefined symbols on iOS and 2308 on macOS, so neither scan was the
      launch-stub trap; `_tree_sitter_rust` defined `T` in both. The same four
      symbols as the 2026-08-09 record — `_stat`, `_lstat`, `_fstat`,
      `_mach_absolute_time` — and nothing else. The `Sources/` sweep found no new
      category at all: no disk-space, boot-time or keyboard hit, and no new
      timestamp call site. What it did find is that the record's one named
      `isExecutableFile` call site is now a family of five, including the first
      one in **Core** — `FileServicing.isExecutableFile(at:)` behind
      `LSPInstallEngine`'s `.gzip` gate — so the record names the family and says
      why a permission question is still nothing to declare.)*
- [x] update `Resources/PrivacyInfo.xcprivacy` **only if** the audit found
      something; `ReleaseMetadataTests`' set equality is the gate either way
      *(The audit found nothing, so the manifest is untouched and its three
      category/reason pairs still pass `ReleaseMetadataTests`' set equality —
      which is the assertion that would have failed had the audit and the file
      disagreed in either direction.)*
- [x] correct the dependency and licence-directory counts in the same doc, which
      Task 1 makes stale
      *(Both 19s become 20, and they were the same 20 all along: 19 resolved
      checkouts minus the `excluded` `swift-argument-parser`, plus the two
      `Vendor/` grammars, equals the 20 `notices` in `licenses.json` and the 20
      `.txt` files beside it.)*
- [x] run `swift test`
      *(2254 tests, 0 failures.)*

### Task 12: Verify acceptance criteria

- [x] `swift test` — full suite green
      *(2254 tests, 0 failures.)*
- [x] both destination builds succeed
      *(`xcodegen generate`, then `platform=macOS` and `generic/platform=iOS`:
      both BUILD SUCCEEDED. The worktree is clean afterwards and
      `Package.resolved` still hashes
      `db2ab036ee37f9a758e483ff78162e8d103823fbce35f57e935d456bf961f33a` — the
      same digest Task 11 recorded, so the generate and the two resolves rewrote
      nothing.)*
- [x] audit the branch **as a diff against `master`** (not merely re-run green,
      since a weakened assertion passes either way) confirming `SymbolQueryTests`,
      `LanguageKeywordsTests`, `SyntaxTokenKindTests`, `LicenseCoverageTests`,
      `DependencyPinTests`, `ReleaseMetadataTests`, `LSPSourceGatingTests` and
      `LSPProvisioningManifestTests` still assert by set equality and changed only
      by gaining rows
      *(Read as a diff, suite by suite. Six changed, and every change is an
      added row: `SymbolQueryTests` gains the `.rust` pin (22 named / empty
      anonymous / three fields) with its table's other entries untouched;
      `LanguageKeywordsTests`' `testTheDocumentedLanguagesAreTheOnesWithLists`
      gains `.rust` inside the same `XCTAssertEqual`; `SyntaxTokenKindTests` and
      `LicenseCoverageTests` gain one hand-pinned table entry each;
      `LSPSourceGatingTests` gains three file names across its two expected
      sets. **`DependencyPinTests` and `ReleaseMetadataTests` are byte-identical
      to `master`** — both derive their sets from the files they read, so the
      new pin and the unchanged privacy manifest are covered without an edit,
      which is the stronger outcome.
      `LSPProvisioningManifestTests` is the one worth stating in detail, because
      three of its existing assertions were rewritten rather than appended to,
      and each rewrite **narrows**: the host allow-list gains `github.com` as a
      fourth literal (still a closed set, with the redirect-and-digest reasoning
      written on it); the architecture test's derived rule "everything that is
      not `node` is an npm tarball" became a hand-written native set checked in
      *both* directions, so a native artifact carrying `nil` now fails where it
      previously could not; the strip-depth test became an exhaustive switch
      stating both halves (tarballs still pinned at 1, gzip at 0) rather than a
      weakened "0 or 1"; and the licence test's `AND` split became `AND`-then-
      `OR` with the empty-`licenseFileSubpaths` exemption pinned **by id**, so a
      second component cannot inherit it. `LSPDownloadableServer`'s own set
      equality is asserted unchanged in that same suite. No assertion anywhere on
      the branch became a containment check.)*
- [x] confirm the `.gzip` extension is pinned in all three directions: an install
      producing an executable commits, a non-executable outcome never commits, and
      every tar-based component still installs
      *(All three, in `LSPInstallEngineTests`' new D22 section over the `binary`
      fixture component: `testAGzipArtifactInstallsAsOneExecutableFileInOneRename`
      (format and `stripComponents: 0` reach the seam whole, exactly one rename,
      the committed file answers `isExecutableFile`);
      `testAGzipUnpackThatForgetsTheModeCommitsNothing` (`unpackFailed` naming
      both the file and the reason, **zero** moves, no version directory, state
      `.absent`, staging swept); and
      `testTarballComponentsInstallUnchangedAndAreNotAskedToBeExecutable`, which
      asserts the gate is `.gzip`'s alone by installing a tarball whose entry
      point is *not* executable in the stub tree. Two further directions the
      criterion did not ask for are covered beside them: a failed `.gzip`
      **upgrade** leaves the previous install byte-for-byte and still runnable,
      and a `.gzip` checksum mismatch never reaches the unpacker at all — so the
      gate follows the digest rather than standing in for it.)*

### Task 13: Update documentation

**Files:**
- Modify: `docs/architecture/core-intelligence.md`, `docs/architecture/core-lsp.md`,
  `docs/architecture/core-provisioning.md`, `docs/architecture/core-workspace.md`,
  `docs/architecture/core-services.md`, `docs/architecture/app-editor.md`,
  `docs/architecture/app-editor-overlays.md`, `CLAUDE.md`, `README.md`

- [ ] `core-intelligence.md`: the Rust symbols query, its six decisions and the
      confirmed capture table from Task 3's runtime check; the keyword list's rule
      and the two lines it draws
- [ ] `core-lsp.md`: D21–D24 in full, the two new Core files' entries, and the
      known limits (no rust-analyzer without `cargo`; a discovered copy used at
      whatever version it is and never replaced; discovery per app run rather than
      per folder; no rust-analyzer on iOS, ever; the `.rs`-has-no-⌘R limit)
- [ ] `core-provisioning.md`: the `.gzip` format and the executable gate, the
      `rust-analyzer` component and its by-hand pin-update procedure (including
      that its version is a *date*), what Rust reuses from 2b and what it
      deliberately does not, the unpacker's second branch, the Settings row and the
      banner's third branch, and why `LSPInstalledLicenses` has nothing of it
- [ ] `core-workspace.md` / `core-services.md`: `FileServicing.isExecutableFile`,
      the `RunCommand`/`TestCommand` decisions, and Task 11's refreshed audit
      record
- [ ] `app-editor-overlays.md` / `app-editor.md`: the grammar registry entry (the
      `TreeSitterRust_TreeSitterRust` bundle derivation and the 21 captures that
      needed no map change) and `LSPRustToolchainService`'s entry beside
      `LSPToolchain`'s
- [ ] `CLAUDE.md`: index lines for the new Core and app files only — no essays —
      plus the one clause the *Provisioned servers* invariant needs now that a
      provisioned server can also be discovered
- [ ] `README.md`: Rust in the highlighting, indexing and keyword lists;
      rust-analyzer in the semantic-intelligence section with the acquisition story
      stated plainly (used if already on your Mac, otherwise offered once with its
      size and downloaded from the official release; a Rust toolchain is required
      either way); a Prerequisites entry; Rust in the test-command list with the
      run-command limit stated; a Limitations bullet in its neighbours' shape; and
      the License-section paragraph saying why rust-analyzer appears in neither
      `Resources/Licenses/` nor Acknowledgements

## Post-Completion Checks (manual)

On a Mac **with** a Rust toolchain, in a real cargo project:

- rust-analyzer already present (`~/.cargo/bin/rust-analyzer`): discovered and used
  with **no prompt**; the row reads "installed (found on this Mac)" and offers no
  Remove.
- rust-analyzer absent: the first `.rs` file prompts **once**, with the download
  size; accepting downloads, verifies and installs the binary, and Rust becomes
  semantic **without a restart**; the row then reads "installed by Pisaka ·
  2026-08-03" and offers Remove.
- Declining persists across a relaunch and never re-prompts; Preferences turns it
  around.
- ⌘-click jumps to a symbol in another file **and another module**; completion
  after `.` on a typed value lists that type's members; completing a symbol from an
  unimported module inserts the `use` and the symbol as **one undo step**.
- `kill` rust-analyzer mid-session → the next request degrades to tree-sitter
  silently, no alert.
- Quit with an install in flight → no orphan process, no staging tree left after
  the next launch's sweep.
- Remove → Rust returns to tree-sitter (or to a discovered copy, if there is one).

On a Mac **without** a Rust toolchain: no prompt ever, the row says so, and `.rs`
files highlight, index, complete and jump from the tree-sitter index.

On iOS/iPadOS: a `.rs` file highlights, indexes, completes (fuzzy + keywords +
members) and jumps within the project — no language server anywhere in sight.
