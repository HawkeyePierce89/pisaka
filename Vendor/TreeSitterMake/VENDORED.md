# Vendored: tree-sitter-make

This directory is a **vendored** copy of a third-party tree-sitter grammar, plus
files written in this repository. It exists as a local SwiftPM package because
upstream ships neither a SwiftPM manifest nor a Swift binding — only a C header
under `bindings/c/` (`tree-sitter-make.h`, declaring `tree_sitter_make()`).

## Upstream

| | |
|---|---|
| URL | <https://github.com/tree-sitter-grammars/tree-sitter-make> |
| Tag | none — default-branch `HEAD`, 9 commits past `v1.1.1` |
| Commit | `70613f3d812cbabbd7f38d104d60a409c4008b43` |
| Commit date | 2026-02-26 |
| Vendored on | 2026-10-08 |
| License | MIT — `LICENSE`, copied verbatim (© 2021 Alexandre A. Muller) |

### Why this fork

`tree-sitter-grammars/tree-sitter-make` is the maintained fork of
`alemuller/tree-sitter-make`, the original repository. The fork carries the
original author's copyright and licence unchanged; the original has not moved
in years and is what the fork's fixes are on top of.

### Why `HEAD` and not the `v1.1.1` tag

The tag (`5e9e8f8f…`, 2024-12-21) predates three commits this feature relies
on: "add missing GNU Make builtin functions" (the tag's parser does not know
the built-ins `intcmp`, `let` and `guile`, which the editor highlights as
`@function.builtin` and offers as keyword completions), "parse trailing
comments in variable assignments", and "parse parentheses in make text and
continued recipes". The `HEAD` commit itself only regenerates the parser with
tree-sitter 0.26.6. Pinning a commit rather than a tag costs nothing here: the
directory content is the pin either way.

## What came from upstream, and what did not

Copied **verbatim** from the commit above:

- `src/parser.c`
- `src/tree_sitter/parser.h`
- `src/tree_sitter/array.h`
- `src/tree_sitter/alloc.h`
- `src/grammar.json`
- `src/node-types.json`
- `grammar.js` — not needed to build, kept deliberately: it documents the node
  names in readable form, it is the source the keyword list's built-in
  functions are reconciled against, and it is what the `tree-sitter` CLI needs
  if the verification below ever has to fall back to `tree-sitter query`.
- `LICENSE`
- `queries/injections.scm` — adopted unchanged. It injects `"bash"` into
  `(shell_text)` and `(shell_command)`; the app's
  `SyntaxLanguageConfiguration.configuration(forInjectionName:)` resolves
  `"bash"` through its extension map to the shell grammar, so recipe lines and
  `$(shell …)` bodies are highlighted as shell with no code of their own.

Deliberately **not** copied: `queries/folds.scm` (fold regions come from a
language server or the pure scanner, never from a grammar query), `bindings/c/` (replaced by the Swift
binding below), `CMakeLists.txt`, `Makefile`, `package.json`,
`tree-sitter.json`, `README.md` and `test/`.

Upstream ships no `src/scanner.c`, and `grammar.js` declares no `externals`, so
the parser is the only compiled source.

Written **in this repository**, not upstream:

- `Package.swift` — the SwiftPM manifest, in the same shape as the other
  vendored grammars (`TreeSitterGitignore` is the reference).
- `bindings/swift/TreeSitterMake/make.h` — the C entry-point declaration
  (`tree_sitter_make()`).
- `queries/highlights.scm` — the highlight query, adapted from upstream's (see
  the Verification section for what changed and why).
- This file.

### Third-party code inside the vendored tree

None beyond the grammar itself. `src/tree_sitter/{parser.h,array.h,alloc.h}`
are tree-sitter's own generated headers, already covered by the `tree-sitter`
notice the app ships; `Resources/Licenses/TreeSitterMake.txt` is therefore
`LICENSE` byte for byte, with nothing appended.

### Required-reason audit

`nm -u` on the built object (`parser.o` from
`swift build --package-path Vendor/TreeSitterMake`, 2026-10-08) lists **zero**
undefined symbols, and the only defined text symbol is `_tree_sitter_make`: a
parser-only grammar is static tables plus one accessor and calls nothing,
required-reason API or otherwise. `PrivacyInfo.xcprivacy` is unchanged.

## ABI

`grep LANGUAGE_VERSION src/parser.c` reads 15, which is the ceiling of the
tree-sitter runtime the app pins (15, minimum 13). As for the editorconfig
grammar, **a runtime downgrade, not an upgrade, is the hazard here**: a runtime
below 15 refuses this parser at load time and every Makefile falls back to plain
text.

## Verification

To be filled in when `queries/highlights.scm` is authored.

## Update procedure

1. Clone upstream, check out the new commit, and record its SHA and date.
2. Re-copy **only** these: `src/parser.c`, `src/grammar.json`,
   `src/node-types.json`, `src/tree_sitter/{parser.h,array.h,alloc.h}`,
   `grammar.js`, `LICENSE`, `queries/injections.scm`.
3. **Keep** (do not overwrite): `Package.swift`,
   `bindings/swift/TreeSitterMake/make.h`, `queries/highlights.scm`, this file.
4. Confirm upstream still ships no `src/scanner.c` and `grammar.js` still
   declares no `externals`; if either changed, add the scanner to `sources:`.
5. Re-read `src/node-types.json` and reconcile `queries/highlights.scm`,
   `queries/injections.scm` and `Resources/Queries/make/symbols.scm` with it.
   Reconcile the built-in function list in `LanguageKeywords` against
   `grammar.js`.
6. Check the parser's ABI: `grep LANGUAGE_VERSION src/parser.c` must not exceed
   the runtime's ceiling.
7. `swift build --package-path Vendor/TreeSitterMake`.
8. **Re-run the verification above.** This step is not optional.
9. Update the Upstream table at the top of this file, the `revision` in
   `Resources/Licenses/licenses.json`, and re-copy `LICENSE` to
   `Resources/Licenses/TreeSitterMake.txt` if it changed.
10. `swift test` at the repo root, then the macOS and iOS builds.
