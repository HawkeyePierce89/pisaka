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

- `grammar.js`
- `bindings/swift/TreeSitterSql/sql.h` (the npm tarball does not include Swift bindings)
- `queries/indents.scm`
- `LICENSE`

Written **in this repository** (or modified from upstream):

- `Package.swift` — drops the test target and dependencies to avoid the SwiftPM error.
- `queries/highlights.scm` — modified from upstream to add missing captures for columns and functions (`;; Added by Review Fixes` at the bottom of the file).
- `src/scanner.c` — copied from the git tag, then three memory defects fixed. Each site
  carries a `// Local fix (see VENDORED.md)` marker:
  - the `DOLLAR_QUOTED_STRING` branch freed nothing on the early `return false` taken when
    the tag it had just scanned equals the one the state already holds — every dollar-quoted
    string re-scanned in that position leaked its tag;
  - `tree_sitter_sql_external_scanner_deserialize` overwrote `state->start_tag` with `NULL`
    without freeing what it was holding, so deserializing over a live state leaked that tag;
  - `tree_sitter_sql_external_scanner_serialize` narrowed `strlen(...) + 1` from `size_t` to
    `int`. The existing `>= TREE_SITTER_SERIALIZATION_BUFFER_SIZE` refusal is unchanged and
    still returns `0`; the length is now a `size_t` throughout and converted to the
    function's `unsigned` at the `return`, where that guard has already bounded it.

  Checked against upstream on 2026-09-08: the newest tag is still `v0.3.11` and the default
  branch's `src/scanner.c` is byte-identical to it, so none of the three is fixed upstream
  and there was no hunk to port.
- This file.

## Update procedure

1. Check out the new git tag and fetch the matching npm tarball.
2. Record the tag, SHA, and date.
3. Re-copy the generated `src/` files from the npm tarball.
4. Re-copy the other files (`queries/indents.scm`, `grammar.js`, `LICENSE`, Swift headers) from the git tag. For `queries/highlights.scm`, re-copy it but re-apply the local fixes marked `;; Added by Review Fixes`.
5. Re-copy `src/scanner.c` from the git tag, then diff it against the vendored copy: for each
   fix marked `// Local fix (see VENDORED.md)`, re-apply it if the new tag does not carry it,
   and **drop** it (deleting its entry above) if upstream now does. If every one is dropped,
   move the file back into the verbatim list.
6. **Keep** (do not overwrite): `Package.swift` and this file.
7. Check if upstream fixed the two *packaging* defects from "Why this is vendored"
   (not the scanner fixes of step 5): if the manifest no longer has the hard
   dependency error, and if the generated parser is available, prefer dropping this
   directory and restoring the remote pin in `project.yml`.
8. Re-derive the capture-name set from `queries/highlights.scm` and reconcile
   the expectation in `VendoredGrammarQueryTests`.
9. Verify `Resources/Queries/sql/symbols.scm` against `SymbolQueryTests`.
10. `swift build --package-path Vendor/TreeSitterSql`.
11. `swift test` at the repo root, then the macOS and iOS builds.
