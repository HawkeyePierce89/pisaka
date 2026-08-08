# Vendored: tree-sitter-dotenv

This directory is a **vendored** copy of a third-party tree-sitter grammar. It
exists as a local SwiftPM package for one reason: **upstream's own manifest does
not link.**

## Why this is vendored and not a remote package

The grammar declares an external scanner —

```js
externals: $ => [
  $._end_of_assignment,
],
```

— whose five `tree_sitter_dotenv_external_scanner_{create,destroy,serialize,`
`deserialize,scan}` functions are defined in `src/scanner.c`. Upstream's
`Package.swift` lists only `src/parser.c` in `sources:`, leaving a literal
`// NOTE: if your language has an external scanner, add it here.` in its place.
The package therefore *compiles* fine and fails at **link** time, in the
consuming app rather than in the package:

```
Undefined symbols for architecture arm64:
  "_tree_sitter_dotenv_external_scanner_create", referenced from:
      _tree_sitter_dotenv.language in TreeSitterDotenv.o
  … (all five)
```

This is not specific to the pinned tag: the same omission is present on upstream
`main` (checked at vendoring time), so no available version of the remote package
can be linked. The fix is one line — `src/scanner.c` in `sources:` — but it has
to live in a manifest we control, hence this directory.

Everything else here is upstream's, copied verbatim. If upstream ever fixes its
manifest, this package can be replaced by the remote pin again (see the last
section).

## Upstream

| | |
|---|---|
| URL | <https://github.com/pnx/tree-sitter-dotenv> |
| Tag | `v1.1.1` |
| Commit | `8b1dad881974a7c1a7e3cb1f55b3a9b38ddec3ec` |
| Commit date | 2026-07-22 |
| Vendored on | 2026-08-02 |
| License | MIT — `LICENSE`, copied verbatim (© 2024 Henrik Hautakoski) |

The tag matches the exact pin `project.yml` previously carried for the remote
package, so vendoring changed the grammar's *contents* not at all — only how it
is built.

## What came from upstream, and what did not

Copied **verbatim** from the tag above:

- `src/parser.c`
- `src/scanner.c` — the file the upstream manifest forgets
- `src/tree_sitter/parser.h`, `src/tree_sitter/alloc.h`, `src/tree_sitter/array.h`
  (the scanner includes all three)
- `src/grammar.json`, `src/node-types.json`
- `grammar.js` — not needed to build, kept deliberately: it documents the node
  names and the `externals` declaration above in readable form, and it is what
  the `tree-sitter` CLI would need to re-derive the parser.
- `bindings/swift/TreeSitterDotenv/dotenv.h` — the C entry-point declaration.
  **Unlike the vendored gitignore grammar, this binding is upstream's**, not
  written here.
- `queries/highlights.scm` — likewise upstream's. It is *not* hand-written here,
  so it needs no per-element verification of its own the way
  `Vendor/TreeSitterGitignore/queries/highlights.scm` does.
- `LICENSE`

Written **in this repository**, not upstream:

- `Package.swift` — same shape as upstream's minus the test target and its
  `SwiftTreeSitter` dependency, **plus `src/scanner.c` in `sources:`**.
- This file.

Dropped: `bindings/{c,go,node,python,rust}`, `bindings/swift/TreeSitterDotenvTests`,
`test/`, `docs/`, and the non-SwiftPM build files (`binding.gyp`, `Cargo.toml`,
`CMakeLists.txt`, `Makefile`, `go.mod`, `package.json`, `pyproject.toml`,
`setup.py`, `tree-sitter.json`) — none of them is reachable from the SwiftPM
target.

## Capture names

`queries/highlights.scm` emits `keyword`, `operator`, `comment`, `constant`,
`number`, `string`, and `variable`. All seven already resolve to a non-`.plain`
`SyntaxTokenKind` through Core's mapping.

`Tests/PisakaCoreTests/VendoredGrammarQueryTests.swift` pins this automatically:
it reads *this* `queries/highlights.scm` through `#filePath`, asserts the emitted
set is exactly those seven names (so an update that adds one fails the suite
until Core's mapping is confirmed to cover it, rather than rendering it
default-colored), that each resolves to a non-`.plain` kind, and — against
`src/node-types.json` — that every node name and anonymous literal the query uses
is one the grammar actually declares *under the matching `named` flag* (the two
kinds are compared as separate sets, because spelling a named node `"like this"`
or an anonymous token `(like this)` fails query compilation exactly as an unknown
name does). If an update legitimately changes the set, update that expectation.

## Symbol query

`Resources/Queries/dotenv/symbols.scm` lives outside this directory but is pinned
by *this* grammar: it captures
`(document (assignment key: (identifier) @definition.variable))`, and
`SymbolQueryTests` checks every node name and anonymous literal in it against
this package's `src/node-types.json` under the matching `named` flag — the same
check `VendoredGrammarQueryTests` runs on the highlight query, and possible for
the same reason (dotenv is one of only two grammars whose sources are in-repo).

Its failure mode is quieter than the highlight query's, which is why step 5 below
covers both files: if an upstream rename touches the nodes the query names, the
file still builds and still highlights — it just declares nothing, and a `.env`
with no symbols is indistinguishable from one that genuinely has none.

## Update procedure

1. Clone upstream, check out the new tag, and record its SHA and date.
2. Re-copy: `src/parser.c`, `src/scanner.c`, `src/tree_sitter/*.h`,
   `src/grammar.json`, `src/node-types.json`, `grammar.js`, `LICENSE`,
   `bindings/swift/TreeSitterDotenv/dotenv.h`, `queries/highlights.scm`.
3. **Keep** (do not overwrite): `Package.swift` and this file.
4. Re-check upstream's `sources:` list against `src/`: if it now includes
   `src/scanner.c`, the reason this package is vendored has gone away — prefer
   dropping this directory and restoring the remote pin in `project.yml`. If it
   still omits it, keep the local manifest and make sure any *newly* added source
   file is in our `sources:` too (a missing one is another link error, not a
   compile error).
5. Re-derive the capture-name set from the updated `queries/highlights.scm` and
   reconcile the expectation in `VendoredGrammarQueryTests` (`swift test` reports
   the difference for you — it reads the file, so a stale expectation fails
   rather than silently passing). Do the same for
   `Resources/Queries/dotenv/symbols.scm` against `SymbolQueryTests`, and open a
   `.env` file in a DEBUG build to confirm its keys still answer ⌃⌘J: neither
   suite can *compile* a query (Core does not link SwiftTreeSitter), so a query
   that no longer compiles surfaces only as `SymbolQueryCatalog`'s DEBUG
   `assertionFailure`.
6. `swift build --package-path Vendor/TreeSitterDotenv`.
7. `swift test` at the repo root, then the macOS and iOS builds — the iOS build is
   what catches a link regression on the other platform.
