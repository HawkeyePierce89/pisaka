# Vendored: tree-sitter-editorconfig

This directory is a **vendored** copy of a third-party tree-sitter grammar, plus
three files written in this repository. It exists as a local SwiftPM package
because upstream ships neither a SwiftPM manifest nor a Swift binding.

## Upstream

| | |
|---|---|
| URL | <https://github.com/ValdezFOmar/tree-sitter-editorconfig> |
| Tag | `v2.0.0` |
| Commit | `c4d5e725e1bbf683b223f4bebe83142cefe68da5` |
| Commit date | 2026-02-23 |
| Vendored on | 2026-08-26 |
| License | MIT — `LICENSE`, copied verbatim (© 2024 Omar Valdez) |

## What came from upstream, and what did not

Copied **verbatim** from the tag above:

- `src/parser.c`
- `src/scanner.c`
- `src/tree_sitter/parser.h`
- `src/tree_sitter/array.h`
- `src/tree_sitter/alloc.h`
- `src/grammar.json`
- `src/node-types.json`
- `grammar.js` — not needed to build, kept deliberately: it documents the node
  names in readable form and is what the `tree-sitter` CLI needs if the
  verification below ever has to fall back to `tree-sitter query`.
- `LICENSE`

Written **in this repository**, not upstream:

- `Package.swift` — the SwiftPM manifest, in the same shape as the remote
  grammar packages this project already consumes.
- `bindings/swift/TreeSitterEditorconfig/editorconfig.h` — the C entry-point
  declaration (`tree_sitter_editorconfig()`).
- `queries/highlights.scm` — the highlight query. Upstream's `queries/editorconfig/highlights.scm` exists but is **deliberately not adopted** for two reasons: (a) its capture names sit outside the vocabulary `SyntaxTokenKind` maps (`@character`, `@character.special` resolve to `.plain`, i.e. default-colored text — one of the two silent failure modes); (b) it uses `#lua-match?`, an editor-specific predicate this app's query pipeline does not implement. Its nested `queries/editorconfig/` path also does not match the `queries/highlights.scm` layout Neon's `LanguageConfiguration` reads out of the SPM resource bundle.
- This file.

## Why the hand-written query needs its own verification

Both of its failure modes are **silent in the app**:

- An unknown **node** name makes the query fail to compile, so
  `LanguageConfiguration` throws, `SyntaxLanguageConfiguration.makeConfiguration`
  returns `nil`, and a `.editorconfig` quietly falls back to plain text.
- A mistyped **capture** name compiles fine and resolves to
  `SyntaxTokenKind.plain`, i.e. default-colored text.

Neither is caught by "the file looks highlighted". So the query is verified
element by element against a fixture, and that verification **must be re-run
after any grammar update** (see the update procedure below).

## Verification

Last run: 2026-08-26, against the vendored grammar at the SHA in the Upstream
table. Executed by the recipe below: a throwaway SwiftPM package depending on
this directory plus the checked-out `SwiftTreeSitter`/`tree-sitter` and
`PisakaCore` (for `SyntaxTokenKind(captureName:)`). Result: the query
**compiles** (14 patterns, 9 distinct capture names); every row of both tables
below was witnessed by an executed capture carrying that name whose range
contains the element; every observed capture name resolved through
`SyntaxTokenKind(captureName:)` to exactly the table's kind, none to `.plain`;
and **zero non-whitespace** characters of either fixture were left uncaptured.
The zero is over non-whitespace characters deliberately: the only offsets no
capture covers are newlines and the eight single spaces around `=` in fixture
A, and whitespace renders default-colored anyway, so nothing user-visible is
left uncolored (an earlier phrasing of this paragraph claimed zero over
*non-newline* characters, which today's run contradicted). Broader captures
overlap finer ones by design — a header's `glob` node spans its whole pattern,
so e.g. `*` carries both its `wildcard` `@operator` and the enclosing
`@string`, and a preamble pair carries both the generic `@property`/`@string`
and the preamble `@keyword`/`@constant`.

### Fixture A

```editorconfig
# A comment
; Another comment
root = true

[*]
indent_style = space
indent_size = 2

[*.{js,ts}]
charset = utf-8
```

### Confirmed captures (fixture A)

| Fixture element | Grammar node | Capture | `SyntaxTokenKind` |
|---|---|---|---|
| `# A comment` / `; Another comment` | `comment` | `@comment` | `.comment` |
| `root` | `property` (inside `preamble`) | `@keyword` | `.keyword` |
| `true` | `string` (inside `preamble`) | `@constant` | `.constant` |
| `[` and `]` in sections | anonymous `"["` / `"]"` in `header` | `@punctuation.bracket` | `.punctuation` |
| `*` in `[*]` | `wildcard` | `@operator` | `.operator` |
| `{` and `}` in `{js,ts}` | `brace_expansion` anonymous `"{"` / `"}"` | `@punctuation.bracket` | `.punctuation` |
| `,` in `{js,ts}` | `brace_expansion` anonymous `","` | `@punctuation.delimiter` | `.punctuation` |
| `.`, `js`, `ts` | `glob` | `@string` | `.string` |
| `indent_style`, `charset`, etc | `property` | `@property` | `.property` |
| `=` | anonymous `"="` | `@operator` | `.operator` |
| `space`, `2`, `utf-8` | `string` | `@string` | `.string` |

### Fixture B

```editorconfig
[/**/?]
[foo\[bar\]]
[[abc]_[!a-z]]
[file_{1..10}.txt]
```

### Confirmed captures (fixture B)

| Fixture element | Grammar node | Capture | `SyntaxTokenKind` |
|---|---|---|---|
| `[` and `]` in headers | anonymous `"["` / `"]"` in `header` | `@punctuation.bracket` | `.punctuation` |
| `/` | `glob` anonymous `"/"` | `@punctuation.delimiter` | `.punctuation` |
| `**`, `?` | `wildcard` | `@operator` | `.operator` |
| `\[` and `\]` | `glob` / `character_escape` | `@string` | `.string` |
| inner `[` and `]` in `[abc]` | `character_choice` anonymous `"["` / `"]"` | `@punctuation.bracket` | `.punctuation` |
| `!` in `[!a-z]` | `character_choice` anonymous `"!"` | `@operator` | `.operator` |
| `-` in `[a-z]` | `character_range` anonymous `"-"` | `@operator` | `.operator` |
| `{` and `}` in `{1..10}` | `integer_range` anonymous `"{"` / `"}"` | `@punctuation.bracket` | `.punctuation` |
| `..` | `integer_range` anonymous `".."` | `@punctuation.delimiter` | `.punctuation` |
| `1` and `10` | `integer` | `@number` | `.number` |
| `foo`, `bar`, `abc`, `a`, `z`, `file_`, `_`, `.txt` | `glob` / `character` | `@string` | `.string` |

### How to re-run it

**1. Static cross-check** (cheap, run it first — and now also automated): every node identifier and anonymous literal used in
`queries/highlights.scm` must appear in `src/node-types.json` **under the
matching `named` flag**.

**2. The harness.** Stand up a throwaway SwiftPM package in a temp directory (do
**not** commit it) with an executable target depending on:

- `.package(path: "<repo>/Vendor/TreeSitterEditorconfig")` → product
  `TreeSitterEditorconfig`
- `.package(path: "<repo>/SourcePackages/checkouts/SwiftTreeSitter")` → product
  `SwiftTreeSitter`
- `.package(path: "<repo>/SourcePackages/checkouts/tree-sitter")` — declared but
  unused.

The program should: build `Language(language: tree_sitter_editorconfig())`, load
`queries/highlights.scm` with `try Query(language:data:)` (a compile failure here
is the loud version of the app's silent plain-text fallback — exit non-zero),
`Parser().parse(fixture)`, run `query.execute(in: tree)` and print every
`(capture.name, text of capture.range)` pair sorted by position, **and** print
every non-whitespace UTF-16 offset of the fixture that no capture covers.
Compare against the tables above; the uncovered non-whitespace count must be
zero (newlines and the single spaces between tokens may stay uncovered —
whitespace renders default-colored regardless). Then run each observed capture
name through `SyntaxTokenKind(captureName:)` and confirm each resolves to the
kind its table row states, never `.plain`.

Delete the temp package afterwards. Note that `swift test` automates only the static half.

**3. The Core pin (automated — runs on every `swift test`).**
`Tests/PisakaCoreTests/VendoredGrammarQueryTests.swift` reads this package's own
files through `#filePath` and asserts two things:
- every node name and anonymous literal `queries/highlights.scm` uses is declared
  in `src/node-types.json` *under the matching `named` flag*.
- the set of capture names it emits is explicitly verified.

## Update procedure

1. Clone upstream, check out the new tag/commit, and record its SHA and date.
2. Re-copy **only** these: `src/parser.c`, `src/scanner.c`, `src/grammar.json`, `src/node-types.json`, `src/tree_sitter/{parser.h,array.h,alloc.h}`, `grammar.js`, `LICENSE`.
3. **Keep** (do not overwrite): `Package.swift`,
   `bindings/swift/TreeSitterEditorconfig/editorconfig.h`, `queries/highlights.scm`,
   this file.
4. Re-read `src/node-types.json` and reconcile `queries/highlights.scm` with it.
5. Check the parser's ABI: `grep LANGUAGE_VERSION src/parser.c` is 15. The runtime's current ceiling is 15 — **a runtime downgrade, not an upgrade, is the hazard here**.
6. `swift build --package-path Vendor/TreeSitterEditorconfig`.
7. **Re-run the verification above.** This step is not optional.
8. Update the Upstream table at the top of this file and any table row the reconciliation changed.
9. `swift test` at the repo root, then the macOS and iOS builds.
