# Vendored: tree-sitter-gitignore

This directory is a **vendored** copy of a third-party tree-sitter grammar, plus
two files written in this repository. It exists as a local SwiftPM package
because upstream ships neither a Swift binding nor a highlight query, so it
cannot be consumed as a remote package the way every other grammar in this
project is.

## Upstream

| | |
|---|---|
| URL | <https://github.com/shunsambongi/tree-sitter-gitignore> |
| Branch | `main` |
| Commit | `f4685bf11ac466dd278449bcfe5fd014e94aa504` |
| Commit date | 2022-05-04 |
| Vendored on | 2026-08-02 |
| License | MIT — `LICENSE`, copied verbatim (© 2022 shunsambongi) |

Upstream has published no tagged releases; the commit above was the head of the
default branch at the time of vendoring, which is why an exact SHA is recorded
rather than a version.

## What came from upstream, and what did not

Copied **verbatim** from the commit above:

- `src/parser.c`
- `src/tree_sitter/parser.h`
- `src/grammar.json`
- `src/node-types.json`
- `grammar.js` — not needed to build, kept deliberately: it documents the node
  names in readable form and is what the `tree-sitter` CLI needs if the
  verification below ever has to fall back to `tree-sitter query`.
- `LICENSE`

Upstream has **no `src/scanner.c`** (the grammar is regex-only), which is why
`Package.swift` lists just `src/parser.c` in `sources:`.

Written **in this repository**, not upstream:

- `Package.swift` — the SwiftPM manifest, in the same shape as the remote
  grammar packages this project already consumes (`tree-sitter-json` is the
  reference).
- `bindings/swift/TreeSitterGitignore/gitignore.h` — the C entry-point
  declaration (`tree_sitter_gitignore()`), modeled on `json.h`.
- `queries/highlights.scm` — the highlight query. **Upstream ships no `queries/`
  directory at all.**
- This file.

## Why the hand-written query needs its own verification

Both of its failure modes are **silent in the app**:

- An unknown **node** name makes the query fail to compile, so
  `LanguageConfiguration` throws, `SyntaxLanguageConfiguration.makeConfiguration`
  returns `nil`, and a `.gitignore` quietly falls back to plain text.
- A mistyped **capture** name compiles fine and resolves to
  `SyntaxTokenKind.plain`, i.e. default-colored text.

Neither is caught by "the file looks highlighted". So the query is verified
element by element against a fixture, and that verification **must be re-run
after any grammar update** (see the update procedure below).

## Verification

Last run: 2026-08-02, against the vendored grammar at the SHA in the Upstream
table. Result: the query **compiles** (15 patterns, 5 distinct captures), the
tables below matched element for element, and **zero** non-newline characters of
either fixture were left uncaptured.

### Fixture A — comments, negation, wildcards, path structure

```gitignore
# a comment
node_modules/
!keep.log
*.log
**/build
```

### Confirmed captures (fixture A)

Every node name in `queries/highlights.scm` is taken from `src/node-types.json`;
none is guessed. The table below is the **observed** output of the harness, not
just the intended result; treat any deviation on a re-run as a bug in the query,
not in the table.

| Fixture element | Grammar node | Capture | `SyntaxTokenKind` |
|---|---|---|---|
| `# a comment` | `comment` | `@comment` | `.comment` |
| `!` in `!keep.log` | `negation` | `@operator` | `.operator` |
| `*` in `*.log` | `wildcard_chars` | `@operator` | `.operator` |
| `**` in `**/build` | `wildcard_chars_allow_slash` | `@operator` | `.operator` |
| `node_modules`, `keep.log`, `build` | `pattern_char` (one node **per character**) | `@string` | `.string` |
| `/` after `node_modules` and in `**/build` | `directory_separator` | `@punctuation.delimiter` | `.punctuation` |

Note the per-character shape of `pattern_char`: its grammar rule is
`/[^\n/*?]/`, so a name like `node_modules` parses as a run of adjacent
single-character nodes, each captured separately (confirmed: `node_modules`
comes back as 12 one-character `@string` captures). The rendered result is one
uniform color, but the raw capture list is one entry per character — that is
expected, not a bug.

### Fixture B — the paths fixture A does not reach

Fixture A exercises neither `?` nor any bracket expression nor an escape, and a
break in those query patterns would be just as silent, so they get their own
fixture:

```gitignore
?.log
[abc]/x
[!a-z].txt
[[:digit:]]
a\ b/c
```

### Confirmed captures (fixture B)

| Fixture element | Grammar node | Capture | `SyntaxTokenKind` |
|---|---|---|---|
| `?` in `?.log` | `wildcard_char_single` | `@operator` | `.operator` |
| `[` and `]` | anonymous `"["` / `"]"` in `bracket_expr` | `@punctuation.bracket` | `.punctuation` |
| `a`, `b`, `c` in `[abc]` | `bracket_char` | `@string` | `.string` |
| `!` in `[!a-z]` | `bracket_negation` | `@operator` | `.operator` |
| `-` in `[a-z]` | anonymous `"-"` in `bracket_range` | `@operator` | `.operator` |
| `[:digit:]` | `bracket_char_class` (whole node) | `@string` | `.string` |
| `\ ` in `a\ b` | `pattern_char_escaped` | `@string` | `.string` |

`directory_separator_escaped` (`\/`) is the one query pattern neither fixture
reaches; its node name is present in `src/node-types.json` and it is captured
identically to `directory_separator`.

The requirement the tables encode is stronger than "these captures are right":
**every element of both fixtures must be captured by something**. An uncaptured
pattern body renders in the default text color, which is exactly what a silently
broken query looks like — so the harness also reports every non-newline
character no capture covers, and that count must be zero.

### How to re-run it

**1. Static cross-check** (cheap, run it first — and now also automated, see
"Automated coverage" below): every node identifier and anonymous literal used in
`queries/highlights.scm` must appear in `src/node-types.json` **under the
matching `named` flag** — an `(identifier)` form against the `named: true`
entries and a `"literal"` form against the `named: false` ones. The two sets must
be kept apart, not merged: the wrong form fails query compilation with
`TSQueryErrorNodeType` just as an unknown name does, and this grammar declares 18
anonymous tokens that read like ordinary node names (`digit`, `alpha`, `blank`,
`alnum`, `cntrl`, `graph`, `lower`, `print`, `punct`, `space`, `upper`, `xdigit`,
`[:`, `:]`, `\`, `[`, `]`, `-`), so `(digit) @string` looks perfectly correct and
is not. Anything left over is a typo — or a node whose `named` status a grammar
update flipped. Parse the query for `(identifier` and `"literal"` tokens
after stripping `;` comments, and set-subtract the `type` values collected
recursively from `node-types.json`. As of the last run the query uses 15 named
nodes (`bracket_char`, `bracket_char_class`, `bracket_char_escaped`,
`bracket_expr`, `bracket_negation`, `bracket_range`, `comment`,
`directory_separator`, `directory_separator_escaped`, `negation`, `pattern_char`,
`pattern_char_escaped`, `wildcard_char_single`, `wildcard_chars`,
`wildcard_chars_allow_slash`) and 3 anonymous literals (`-`, `[`, `]`), all
present.

**2. The harness.** Stand up a throwaway SwiftPM package in a temp directory (do
**not** commit it) with an executable target depending on:

- `.package(path: "<repo>/Vendor/TreeSitterGitignore")` → product
  `TreeSitterGitignore`
- `.package(path: "<repo>/SourcePackages/checkouts/SwiftTreeSitter")` → product
  `SwiftTreeSitter`
- `.package(path: "<repo>/SourcePackages/checkouts/tree-sitter")` — declared but
  unused; it only keeps SwiftTreeSitter's own remote dependency resolvable
  offline (SwiftPM warns about the duplicate identity and the unused dependency;
  both warnings are expected)

The program should: build `Language(language: tree_sitter_gitignore())`, load
`queries/highlights.scm` with `try Query(language:data:)` (a compile failure here
is the loud version of the app's silent plain-text fallback — exit non-zero),
`Parser().parse(fixture)`, run `query.execute(in: tree)` and print every
`(capture.name, text of capture.range)` pair sorted by position, **and** print
every non-newline UTF-16 offset of the fixture that no capture covers. Compare
against the tables above; the uncovered count must be zero. Then run each
observed capture name through `SyntaxTokenKind(captureName:)` and confirm the
kinds are the intended, mutually distinct four.

Delete the temp package afterwards.

If the harness cannot be stood up, the fallback is the `tree-sitter` CLI:
`tree-sitter query queries/highlights.scm <fixture>` using the copied
`grammar.js`, asserting the same tables (the CLI is not installed in this repo's
toolchain, which is why the harness is the primary route).

**3. The Core pin (automated — runs on every `swift test`).**
`Tests/PisakaCoreTests/VendoredGrammarQueryTests.swift` reads *this package's own
files* through `#filePath` and asserts two things, so neither steps 1 nor 3 of
the recipe depends on someone remembering to re-run them:

- every node name and anonymous literal `queries/highlights.scm` uses is declared
  in `src/node-types.json` *under the matching `named` flag* — the static
  cross-check of step 1, which is what catches a typo, a node a grammar update
  renamed, or one whose `named` status it flipped, *before* the query fails to
  compile and the file degrades to plain text. The named and anonymous types are
  compared as two separate sets for the reason step 1 gives: this grammar's
  `digit`/`alpha`/`space`/… are anonymous tokens that read like node names, so a
  merged lookup would accept `(digit) @string`, which does not compile;
- the set of capture names it emits is exactly `comment`, `operator`, `string`,
  `punctuation.delimiter`, `punctuation.bracket`, each resolving to a non-`.plain`
  `SyntaxTokenKind`, and the four resulting kinds stay mutually distinct.

The set equality is deliberate: a query that *gains* a capture fails the suite
until someone confirms Core's mapping covers it, rather than rendering it
default-colored. If a grammar update legitimately changes the emitted set, update
that expectation — and re-run the runtime harness above, which is the half no
test can cover (Core does not link SwiftTreeSitter).

## Update procedure

1. Clone upstream, check out the new commit, and record its SHA and date.
2. Re-copy **only** these: `src/parser.c`, `src/tree_sitter/parser.h`,
   `src/grammar.json`, `src/node-types.json`, `grammar.js`, `LICENSE`.
3. **Keep** (do not overwrite): `Package.swift`,
   `bindings/swift/TreeSitterGitignore/gitignore.h`, `queries/highlights.scm`,
   this file.
4. If upstream has gained a `src/scanner.c`, add it to `sources:` in
   `Package.swift`; if it has gained its own `queries/`, decide explicitly
   whether to adopt it (and re-do the verification against it either way).
5. Re-read `src/node-types.json` and reconcile `queries/highlights.scm` with it —
   node names may have been renamed, added, or removed. `swift test` now checks
   this mechanically (`VendoredGrammarQueryTests`, see below), so run it here
   rather than discovering a rename in the app.
6. Check the parser's ABI: `grep LANGUAGE_VERSION src/parser.c` must be **≥**
   `TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION` in the tree-sitter runtime the
   app resolves (`SourcePackages/checkouts/tree-sitter/lib/include/tree_sitter/api.h`).
   The vendored parser is ABI **13**, generated in 2022, which is exactly the
   floor of the currently pinned tree-sitter 0.25.10 — so a runtime bump that
   raises that floor makes `ts_parser_set_language` reject this grammar and every
   `.gitignore`/`.dockerignore`/… degrade to plain text, silently and with a
   green build. If it is below the floor, regenerate `src/parser.c` from
   `grammar.js` with a current `tree-sitter` CLI (and re-do step 5, since node
   names can shift).
7. `swift build --package-path Vendor/TreeSitterGitignore`.
8. **Re-run the verification above.** This step is not optional: both failure
   modes of the query are silent in the running app. `swift test` automates the
   *static* half of it — `Tests/PisakaCoreTests/VendoredGrammarQueryTests.swift`
   reads this package's `queries/highlights.scm` and `src/node-types.json` and
   asserts every node name and anonymous literal is declared, and that the emitted
   capture names are exactly the expected set, each resolving to a non-`.plain`
   `SyntaxTokenKind`. It cannot cover the *runtime* half (that the query compiles
   against the built grammar, and that every element of a fixture is captured),
   which needs SwiftTreeSitter and so stays this manual recipe.
9. Update the Upstream table at the top of this file (SHA, commit date, vendored
   date) and any table row the reconciliation changed.
10. `swift test` at the repo root, then the macOS and iOS builds.
