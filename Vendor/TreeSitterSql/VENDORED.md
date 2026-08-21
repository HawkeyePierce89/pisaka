# Vendored: tree-sitter-sql

This directory is a **vendored** copy of a third-party tree-sitter grammar. It
exists as a local SwiftPM package because upstream is broken in two independent ways.

## Why this is vendored and not a remote package

1. **`src/parser.c` is not in the repository.** `.gitignore` carries
   `/src/parser.c`, `/src/tree_sitter/` and `/src/*.json`, so the tagged tree
   contains `src/scanner.c` alone. The manifest's `sources:` names
   `src/parser.c` — SwiftPM reports
   `warning: Invalid Source '…/src/parser.c': File not found.` and the target
   builds to nothing.
2. **The manifest is a hard SwiftPM error.** Its test target depends on a
   `SwiftTreeSitter` product from `tree-sitter/swift-tree-sitter` without an
   explicit `.product(name:package:)`:
   `error: dependency 'SwiftTreeSitter' in target 'TreeSitterSqlTests' requires
   explicit declaration`. That dependency also vends a product named
   `SwiftTreeSitter` — the same product name ChimeHQ's `SwiftTreeSitter`
   (already in this graph, via Neon) vends, from a different package identity.

## Upstream

| | |
|---|---|
| URL | <https://github.com/DerekStride/tree-sitter-sql> |
| Tag | `v0.3.11` |
| Commit | `7b51ecda191d36b92f5a90a8d1bc3faef1c7b8b8` |
| Commit date | 2025-10-01 |
| Vendored on | 2026-08-21 |
| License | MIT — `LICENSE`, copied verbatim (© 2021 Derek Stride) |

## What came from upstream, and what did not

Copied **verbatim** from the npm tarball `@derekstride/tree-sitter-sql@0.3.11`
(because the git repo ignores the generated files):

- `src/parser.c`
- `src/tree_sitter/parser.h`, `src/tree_sitter/alloc.h`, `src/tree_sitter/array.h`
- `src/grammar.json`, `src/node-types.json`

Copied **verbatim** from the git tag:

- `src/scanner.c`
- `grammar.js`
- `bindings/swift/TreeSitterSql/sql.h` (the npm tarball does not include Swift bindings)
- `queries/highlights.scm` and `queries/indents.scm`
- `LICENSE`

Written **in this repository**, not upstream:

- `Package.swift` — drops the test target and dependencies to avoid the SwiftPM error.
- This file.

## Update procedure

1. Check out the new git tag and fetch the matching npm tarball.
2. Record the tag, SHA, and date.
3. Re-copy the generated `src/` files from the npm tarball.
4. Re-copy the other files (`queries/`, `grammar.js`, `LICENSE`, Swift headers) from the git tag.
5. **Keep** (do not overwrite): `Package.swift` and this file.
6. Check if upstream fixed the two defects: if the manifest no longer has the hard
   dependency error, and if the generated parser is available, prefer dropping this
   directory and restoring the remote pin in `project.yml`.
7. Re-derive the capture-name set from `queries/highlights.scm` and reconcile
   the expectation in `VendoredGrammarQueryTests`.
8. Verify `Resources/Queries/sql/symbols.scm` against `SymbolQueryTests`.
9. `swift build --package-path Vendor/TreeSitterSql`.
10. `swift test` at the repo root, then the macOS and iOS builds.
