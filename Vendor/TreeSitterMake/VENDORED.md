# Vendored: tree-sitter-make

This directory is a **vendored** copy of a third-party tree-sitter grammar, plus
files written in this repository. One upstream file, `grammar.js`, is **edited**
here, and the parser is **regenerated** from it (see *The newline edit* below). It exists as a local SwiftPM package because
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

- `src/tree_sitter/parser.h`
- `src/tree_sitter/array.h`
- `src/tree_sitter/alloc.h`
- `LICENSE`
- `queries/injections.scm` — adopted unchanged. It injects `"bash"` into
  `(shell_text)` and `(shell_command)`; the app's
  `SyntaxLanguageConfiguration.configuration(forInjectionName:)` resolves
  `"bash"` through its extension map to the shell grammar, so recipe lines and
  `$(shell …)` bodies are highlighted as shell with no code of their own.

**Edited** here from the commit above:

- `grammar.js` — the source the parser is generated from, the source the
  keyword list's built-in functions are reconciled against, and what the
  `tree-sitter` CLI needs if the verification below ever has to fall back to
  `tree-sitter query`. Every departure is marked `// EDIT:`; all of them make up
  the one change described under *The newline edit*.

**Generated** here from the edited `grammar.js`, never hand-edited:

- `src/parser.c`
- `src/grammar.json`
- `src/node-types.json` — byte-identical to upstream's, because the edit adds
  no node and changes no node's children.

The generator is `tree-sitter-cli` **0.26.6**, the version upstream's pinned
commit regenerated its parser with. ABI 15 needs upstream's `tree-sitter.json`
for the language metadata, and that file is deliberately not vendored, so
generation runs in a scratch directory:

```sh
mkdir /tmp/make-regen && cd /tmp/make-regen
curl -fL -o tree-sitter.json \
  https://raw.githubusercontent.com/tree-sitter-grammars/tree-sitter-make/<commit>/tree-sitter.json
cp <repo>/Vendor/TreeSitterMake/grammar.js .
npx tree-sitter-cli@0.26.6 generate --abi 15
cp src/parser.c src/grammar.json src/node-types.json <repo>/Vendor/TreeSitterMake/src/
```

The pipeline is checked against upstream: run on the **unedited** `grammar.js`
at the pinned commit, it reproduces upstream's `parser.c`, `grammar.json`,
`node-types.json` and the three headers byte for byte (2026-10-09). The
headers it writes are identical to the vendored ones and are not copied back.

Deliberately **not** copied: `queries/folds.scm` (fold regions come from a
language server or the pure scanner, never from a grammar query), `bindings/c/` (replaced by the Swift
binding below), `CMakeLists.txt`, `Makefile`, `package.json`,
`tree-sitter.json` (fetched only into the scratch directory above),
`README.md` and `test/`.

Upstream ships no `src/scanner.c`, and `grammar.js` declares no `externals`, so
the parser is the only compiled source.

Written **in this repository**, not upstream:

- `Package.swift` — the SwiftPM manifest, in the same shape as the other
  vendored grammars (`TreeSitterGitignore` is the reference).
- `bindings/swift/TreeSitterMake/make.h` — the C entry-point declaration
  (`tree_sitter_make()`).
- `queries/highlights.scm` — the highlight query, **adapted** from upstream's
  `queries/highlights.scm` at the pinned commit. Upstream's file cannot be used
  verbatim, and every departure is marked `; EDIT:` in the file:
  - `@spell` dropped from `(comment)`, because it has no `SyntaxTokenKind` and
    resolves to `.plain`.
  - Automatic variables (`$@`, `$<`, `$^`, …): `@character.special` →
    `@variable.builtin`. The upstream name resolves to `.plain`.
  - The recipe's `@` echo-suppression prefix: `@character.special` →
    `@operator`, for the same reason.
  - Names in `variable_assignment`, `shell_assignment` and `define_directive`:
    `@string.special.symbol` → `@variable`.
  - In `$(NAME)` references, upstream captured the name as `@string` ("to match
    bash") and the whole node as `@operator`. Here the name is `@variable` and
    only the delimiters `$`, `$$`, `(`, `)`, `{`, `}` are `@operator`, so the two
    captures no longer overlap. Upstream's two string captures would have drawn
    every variable in string colour.
  - Added `intcmp`, `let` and `guile` to the `@function.builtin` list. The pinned
    `grammar.js` declares them in `FUNCTIONS`, but upstream's query list was
    never updated.
  - Added one pattern for target-specific assignments
    (`debug: CFLAGS += -O0`). These are `variable_assignment` nodes, not `rule`
    nodes, so upstream left their target and `:` uncoloured. They get
    `@function`/`@operator`, the same as an ordinary rule.
  - Added `"sinclude"` to the `include_directive` keyword alternatives. The
    grammar parses GNU make's `-include` alias as an `include_directive`, and
    without it in the list the whole pattern failed to match, so neither the
    keyword nor its filenames were coloured. The keyword and the filenames are
    also split into two patterns: upstream's single pattern required a bare
    `word` filename, so `include $(DEPS)` or `sinclude $(wildcard *.mk)` left
    the keyword plain. Executed by `MakeSymbolQueryTests` in the app-layer
    bundle.
  - Replaced `"!="` with `"+="` in the `define_directive` operator
    alternatives: `node-types.json` declares `+=` and not `!=` for that node.
  - Added two patterns for `VPATH_assignment` and `RECIPEPREFIX_assignment`.
    Their names are anonymous tokens, not a `word`, so upstream's
    `variable_assignment` patterns never matched them and both stayed
    uncoloured. The name is `@variable.builtin` and the operator `@operator`.
    `VPATH` is also added to the three special-variable `#any-of?` lists, since
    `override VPATH = …` and `define VPATH` parse its name as an ordinary
    `word`. Executed by `MakeSymbolQueryTests` in the app-layer bundle.
  - Known grammar limit, not fixable in a query: the parser hardcodes the
    recipe prefix to a tab (`_recipeprefix`, an upstream `TODO external parser
    for .RECIPEPREFIX`), so after `.RECIPEPREFIX = >` a `>`-prefixed line is
    not a `recipe_line`, gets no Bash injection and may parse as an `ERROR`.
    The assignment itself is coloured; honouring it needs an external scanner,
    which this fork deliberately does not add (the newline edit below is the
    only grammar change made here).
    Likewise `VPATH != …` at a line start lexes `VPATH` as the dedicated
    node's keyword and does not parse as a `shell_assignment`.
  - Added `.NOTINTERMEDIATE` and `.WAIT` to the special-target `#any-of?`, and
    `.LIBPATTERNS`, `.LOADED` and `.SHELLSTATUS` to the special-variable one, so
    both lists match the names `Resources/Queries/make/symbols.scm` refuses to
    index. Added two patterns drawing `.WAIT` as `@function.builtin` among a
    rule's prerequisites, where it is ordinarily written — one for an ordinary
    rule's `prerequisites`, one for a static-pattern rule's
    `prerequisite: (pattern_list)`. Added two patterns applying the
    special-variable list to `shell_assignment` and `define_directive` names,
    because `.EXTRA_PREREQS != …` and `define .FEATURES` set a special variable
    as surely as `:=` does and the symbols query filters all three forms alike.
    All of these are executed by `MakeSymbolQueryTests` in the app-layer bundle.
  - Added three patterns capturing `vpath`, `undefine` and `private` as
    `@keyword`. The grammar parses each into a node of its own
    (`vpath_directive`, `undefine_directive`, `private_directive`), but
    upstream's query gave none of them a capture, so the keyword stayed plain
    text. Executed by `MakeSymbolQueryTests` in the app-layer bundle.

  Everything else is upstream's text: patterns, predicates (`#eq?`,
  `#any-of?`, `#set! priority`) and the commented-out `":::="` lines. All three
  predicates are implemented by the pinned SwiftTreeSitter.
- This file.

### The newline edit

Upstream's `shell_text` (a recipe line's text) and the `shell_command` of a
`NAME != command` assignment end **before** their line's newline, which
followed as a separate hidden token. `queries/injections.scm` injects bash into
both, and SwiftTreeSitterLayer parses every bash injection of one file as one
combined layer whose included ranges are exactly those nodes. With every newline
outside the ranges, bash's lexer read across the gap, so `exit 1` on one recipe
line and `echo` on the next became the single word `1\n\techo`, and the next
line's command name lost its `function` capture. A query cannot reach the
newline (it is an unnamed hidden token, refused at compile time), and neither
the layer nor Neon offers a hook to widen a range, so the fix is in the grammar:

- a hidden `_shell_line: seq($._line_text, NL)` is aliased to `shell_text` in
  `recipe_line` and to `shell_command` in `shell_assignment`, so both nodes end
  after their newline;
- `_prefixed_recipe_line` and `_attached_recipe_line` end in either a
  `recipe_line` or a bare `NL`, so an empty recipe line still parses, and
  `recipe`'s attached form no longer takes its own `NL`;
- the `$(shell …)` body keeps `_paren_text`: it ends at its `)`.

Nothing else in the grammar changes. `NL` matches `[\r\n]+`, so a node also
carries the blank lines after it; bash reads them as separators.
`VendoredGrammarQueryTests.testMakeShellInjectionTargetsEndAfterTheirNewline`
pins the edit in the generated `grammar.json`, so a re-copy of upstream's
`src/` fails `swift test`.

### Third-party code inside the vendored tree

None beyond the grammar itself. `src/tree_sitter/{parser.h,array.h,alloc.h}`
are tree-sitter's own generated headers, already covered by the `tree-sitter`
notice the app ships; `Resources/Licenses/TreeSitterMake.txt` is therefore
`LICENSE` byte for byte, with nothing appended.

### Required-reason audit

`nm -u` on the built object (`parser.o` from
`swift build --package-path Vendor/TreeSitterMake`, 2026-10-08, re-run on the
regenerated parser 2026-10-09) lists **zero**
undefined symbols, and the only defined text symbol is `_tree_sitter_make`: a
parser-only grammar is static tables plus one accessor and calls nothing,
required-reason API or otherwise. `PrivacyInfo.xcprivacy` is unchanged.

## ABI

`grep LANGUAGE_VERSION src/parser.c` reads 15 (the regenerated parser too), which is the ceiling of the
tree-sitter runtime the app pins (15, minimum 13). As for the editorconfig
grammar, **a runtime downgrade, not an upgrade, is the hazard here**: a runtime
below 15 refuses this parser at load time and every Makefile falls back to plain
text.

## Verification

Last run: 2026-10-08, against the vendored grammar at the SHA in the Upstream
table, using the recipe below.

The query **compiles**: 34 patterns and 12 capture names, of which 11 are
emitted plus the auxiliary `@_target` that the `.PHONY` pattern's predicate
reads. The injection query compiles too. Both fixtures parse with no `ERROR`
node.

Re-run 2026-10-09 after the newline edit, before and after it with one
harness, and the two outputs diffed. Both queries compile (34 patterns, 12
capture names); fixtures A and B and the app bundle's `injected-shell.mk` parse
with no `ERROR` or missing node. **Every Make-side capture and every
uncaptured-offset count is identical**; the one difference is that each
injected range now ends after its newline (for example `swiftlint --strict\n`
where it was `swiftlint --strict`). Through a Make root `LanguageLayer` over
`injected-shell.mk`, the joined words `1\n\techo` and
`"swiftlint is not installed"\n\tswiftlint` are gone, and `echo` and the
second `swiftlint` resolve to `function`. Fixture B has grown since the first
run below, so its uncaptured count is now 101 rather than 93, the same before
and after the edit.

Every row of both tables below was witnessed as the **effective** capture at
that element. The captures added after this run — `vpath`, `undefine` and
`private`, the special-variable list on `!=` and `define` names, `.WAIT` among
prerequisites, and the include keyword ahead of a non-`word` filename — are
**not** in either fixture; they are verified instead by the runtime tests in
`Tests/PisakaAppTests/MakeSymbolQueryTests.swift`, which execute the query
against the vendored grammar with predicates resolved. "Effective" means the last of SwiftTreeSitter's `highlights()`,
which sorts less-specific captures before more-specific ones; Neon applies them
in that order, so the last one is what gets drawn. Every observed name resolved
through `SyntaxTokenKind(captureName:)` to the table's kind and none to `.plain`.
The one exception is `_target`, which Neon draws over the whole `.PHONY`
targets node before the finer `@function.builtin` replaces it.

Recipe bodies were reported as `bash` injections. So were `$(shell …)` and `!=`
right-hand sides, and the app resolves `bash` to the shell grammar.

Uncaptured non-whitespace outside the injected shell: 25 offsets in fixture A,
93 in fixture B. **All of them are deliberately plain text**, as upstream
leaves them too: assignment values (`Pisaka`, `platform=macOS`, `-O2`),
function arguments (`src/*.c`, `%.c,%.o,`), `ifeq` operands and the variable
after `ifdef`/`export`, the body of a `define`, and the prerequisites of
ordinary rules (`build` in `test: build`; `.PHONY`'s prerequisites *are*
coloured). Make has no literal syntax that tells a value from a word, so
colouring these would be guessing.

### Fixture A

```make
# Build helpers
.PHONY: build test lint

SCHEME = Pisaka
DEST ?= platform=macOS

build:
	xcodebuild -scheme $(SCHEME) -destination '$(DEST)' build

test: build
	@swift test

lint:
	swiftlint --strict
```

### Confirmed captures (fixture A)

| Fixture element | Grammar node | Capture | `SyntaxTokenKind` |
|---|---|---|---|
| `# Build helpers` | `comment` | `@comment` | `.comment` |
| `.PHONY` | `word` in `targets` (special-target `#any-of?`) | `@function.builtin` | `.function` |
| `build`, `test`, `lint` after `.PHONY:` | `word` in `prerequisites` (`#eq? @_target ".PHONY"`) | `@function` | `.function` |
| `build:`, `test:`, `lint:` targets | `word` in `targets` | `@function` | `.function` |
| `:` in rules | anonymous `":"` in `rule` | `@operator` | `.operator` |
| `SCHEME`, `DEST` | `variable_assignment` `name:` | `@variable` | `.variable` |
| `=`, `?=` | anonymous operator in `variable_assignment` | `@operator` | `.operator` |
| `$(` / `)` in `$(SCHEME)` | anonymous `"$"`/`"("`/`")"` in `variable_reference` | `@operator` | `.operator` |
| `SCHEME`, `DEST` in references | `word` in `variable_reference` | `@variable` | `.variable` |
| `@` before `swift test` | anonymous `"@"` in `recipe_line` | `@operator` | `.operator` |
| recipe bodies | `shell_text` | injected `bash` | (shell grammar) |

### Fixture B

```make
include config.mk
-include local.mk
sinclude extra.mk
export PATH
override CFLAGS += -O2
SRCS := $(wildcard src/*.c)
OBJS = $(patsubst %.c,%.o,$(SRCS))
HASH != git rev-parse HEAD
MAKEFLAGS += --no-builtin-rules

ifeq ($(OS),Darwin)
  CC := clang
else
  CC ?= gcc
endif

ifdef DEBUG
CFLAGS += -g
endif

define BANNER =
built $(HASH)
endef

debug: CFLAGS += -O0

%.o: %.c | build
	$(CC) $(CFLAGS) -c $< -o $@

app: $(OBJS)
	$(CC) -o $@ $^ \
	  $(shell pkg-config --libs zlib)

NUM := $(intcmp 1,2,lt)
.SUFFIXES:

VPATH = src
.RECIPEPREFIX = >
define FOOTER +=
done
endef
```

### Confirmed captures (fixture B)

| Fixture element | Grammar node | Capture | `SyntaxTokenKind` |
|---|---|---|---|
| `include`, `-include`, `sinclude`, `export` | anonymous keywords | `@keyword.import` | `.keyword` |
| `config.mk`, `local.mk`, `extra.mk` | `word` in `include_directive` `filenames:` | `@string.special.path` | `.string` |
| `override` | anonymous keyword | `@keyword` | `.keyword` |
| `ifeq`, `else`, `endif`, `ifdef` | anonymous keywords in `conditional` | `@keyword.conditional` | `.keyword` |
| `define`, `endef` | anonymous keywords in `define_directive` | `@keyword` | `.keyword` |
| `CFLAGS`, `SRCS`, `OBJS`, `CC` (also inside `ifeq`), `NUM` | `variable_assignment` `name:` | `@variable` | `.variable` |
| `HASH` | `shell_assignment` `name:` | `@variable` | `.variable` |
| `BANNER`, `FOOTER` | `define_directive` `name:` | `@variable` | `.variable` |
| `VPATH`, `.RECIPEPREFIX` | anonymous name token in `VPATH_assignment` / `RECIPEPREFIX_assignment` | `@variable.builtin` | `.variable` |
| `MAKEFLAGS` | `word` in `variable_assignment` (`#any-of?`) | `@variable.builtin` | `.variable` |
| `+=`, `:=`, `=`, `?=`, `!=` (incl. `define FOOTER +=` and the `VPATH`/`.RECIPEPREFIX` `=`) | anonymous operators | `@operator` | `.operator` |
| `wildcard`, `patsubst`, `shell`, `intcmp` | anonymous function names | `@function.builtin` | `.function` |
| `$(` / `)` of function calls and references | anonymous `"$"`/`"("`/`")"` | `@operator` | `.operator` |
| `SRCS`, `OS`, `CC`, `CFLAGS`, `OBJS` in `$(…)` | `word` in `variable_reference` | `@variable` | `.variable` |
| `debug` / `:` in `debug: CFLAGS += -O0` | `word` in `target_or_pattern:` / anonymous `":"` | `@function` / `@operator` | `.function` / `.operator` |
| `%.o` target, `\|` | `word` in `targets` / anonymous `"\|"` | `@function` / `@operator` | `.function` / `.operator` |
| `$` / `<`, `@`, `^` in `$<`, `$@`, `$^` | `automatic_variable` | `@operator` / `@variable.builtin` | `.operator` / `.variable` |
| `.SUFFIXES` | `word` in `targets` (special-target `#any-of?`) | `@function.builtin` | `.function` |
| recipe bodies, `$(shell …)` body, `!=` value | `shell_text` / `shell_command` | injected `bash` | (shell grammar) |

### How to re-run it

**1. Static cross-check.** This step is automated and runs on every
`swift test` (see 3), but run it first anyway because it is cheap. Every node
name, anonymous literal and field used in `queries/highlights.scm` and
`queries/injections.scm` must appear in `src/node-types.json` **under the
matching `named` flag**.

**2. The harness.** Create a throwaway SwiftPM package in a temp directory and
do **not** commit it. Give it an executable target that depends on:

- `.package(path: "<repo>/Vendor/TreeSitterMake")` → product `TreeSitterMake`
- `.package(path: "<DerivedData>/SourcePackages/checkouts/SwiftTreeSitter")` →
  product `SwiftTreeSitter`
- `.package(path: "<DerivedData>/SourcePackages/checkouts/tree-sitter")`,
  declared but unused
- `.package(path: "<repo>")` → product `PisakaCore`, for
  `SyntaxTokenKind(captureName:)`

The program does the following:

1. Build `Language(language: tree_sitter_make())`.
2. Load both `queries/highlights.scm` and `queries/injections.scm` with
   `try Query(language:data:)`. A compile failure here is the loud version of
   the app's silent plain-text fallback, so exit non-zero on one.
3. Parse each fixture and report any `ERROR` node.
4. Run `query.execute(in: tree).resolve(with: Predicate.Context(string:))`, so
   that the `#eq?` and `#any-of?` predicates are evaluated rather than ignored.
5. Collect `highlights()` and `injections()`.
6. Assign each UTF-16 offset the **last** highlight covering it, and print the
   runs with each name's `SyntaxTokenKind`.
7. Print the injected ranges.
8. Print every non-whitespace offset that no highlight covers and that lies
   outside an injected range.

Compare the output against the tables above, and classify every uncaptured
offset as one of the deliberately-plain cases listed above. Check that every
injected range ends after its newline. Then run a Make root `LanguageLayer`
(Neon and the shell grammar as further dependencies) over
`Tests/PisakaAppTests/Fixtures/injected-shell.mk` and confirm that no bash
capture spans a newline, i.e. no recipe line's last word has been joined to the
next line's first.

Delete the temp package afterwards. `swift test` automates only the static
half of this procedure.

**3. The Core pin.** This part is automated and runs on every `swift test`.
`Tests/PisakaCoreTests/VendoredGrammarQueryTests.swift` reads this package's
files through `#filePath` and asserts:

- every node name, literal and field in both query files is declared;
- the emitted capture set equals the expected set exactly, with each name
  non-`.plain`;
- the auxiliary set is `{_target}`;
- none of upstream's replaced capture names has come back with a re-copy.

## Update procedure

1. Clone upstream, check out the new commit, and record its SHA and date.
2. Re-copy **only** these: `src/tree_sitter/{parser.h,array.h,alloc.h}`,
   `LICENSE`, `queries/injections.scm`.
3. Take upstream's new `grammar.js` and **re-apply every `// EDIT:`** from the
   current one (*The newline edit*). Then regenerate `src/parser.c`,
   `src/grammar.json` and `src/node-types.json` with the scratch-directory
   recipe above, using the `tree-sitter-cli` version upstream's commit
   generated with and recording it here. Never copy upstream's `src/` files:
   they lack the edit.
4. **Keep** (do not overwrite): `Package.swift`,
   `bindings/swift/TreeSitterMake/make.h`, `queries/highlights.scm`, this file.
5. Confirm upstream still ships no `src/scanner.c` and `grammar.js` still
   declares no `externals`; if either changed, add the scanner to `sources:`.
6. Re-read `src/node-types.json` and reconcile `queries/highlights.scm`,
   `queries/injections.scm` and `Resources/Queries/make/symbols.scm` with it.
   Reconcile the built-in function list in `LanguageKeywords` against
   `grammar.js`.
7. Check the parser's ABI: `grep LANGUAGE_VERSION src/parser.c` must not exceed
   the runtime's ceiling.
8. `swift build --package-path Vendor/TreeSitterMake`.
9. **Re-run the verification above.** This step is not optional.
10. Update the Upstream table at the top of this file, the `revision` in
   `Resources/Licenses/licenses.json`, and re-copy `LICENSE` to
   `Resources/Licenses/TreeSitterMake.txt` if it changed.
11. `swift test` at the repo root, then the macOS and iOS builds.
