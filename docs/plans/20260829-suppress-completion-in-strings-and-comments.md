# Suppress fallback completion inside string literals and comments

## Overview

The index-backed completion fallback currently offers project symbols, buffer
words and keywords wherever the caret sits — including inside a string literal
or a comment, where none of them are meaningful. This adds a pure `PisakaCore`
syntax-context engine (a per-language lexing vocabulary plus a linear scanner)
and asks it once, at the top of `SymbolIntelligenceProvider`'s single static
completion entry point. Inside a gated string or a comment the fallback answers
`[]`; inside an interpolation hole it answers exactly as in open code. The
routing provider, the LSP provider, go-to-definition, the symbol index and the
file-symbols list are untouched.

## Context

- Files involved:
  - Create: `Sources/PisakaCore/SyntaxContextVocabulary.swift` — the
    per-language string/comment table and the gating policy.
  - Create: `Sources/PisakaCore/SyntaxContextScanner.swift` — the pure scanner
    + the `SyntaxContext` result.
  - Modify: `Sources/PisakaCore/SymbolIntelligenceProvider.swift` — one guard at
    the top of the static `completions(for:in:limit:bufferWordLimit:)`.
  - Modify: `Sources/PisakaCore/CodeIntelligence.swift` —
    `CompletionRequest.offset`'s doc comment currently states "the tree-sitter
    provider ignores the field entirely"; that stops being true.
  - Create: `Tests/PisakaCoreTests/SyntaxContextVocabularyTests.swift`,
    `Tests/PisakaCoreTests/SyntaxContextScannerTests.swift`.
  - Modify: `Tests/PisakaCoreTests/SymbolIntelligenceProviderTests.swift` — new
    gate tests appended; existing tests unmodified.
  - Modify: `CLAUDE.md` (two index lines),
    `docs/architecture/core-intelligence.md` (full entries),
    `docs/architecture/core-editor.md` (one cross-reference under
    `BracketDepthScanner`).

- Verified in the code, and load-bearing for this design:
  - `CompletionRequest` already carries `text`, `offset: Int?` and
    `language: SyntaxLanguage?`; both editor call sites
    (`Sources/Pisaka/CompletionController.swift:359`,
    `Sources/Pisaka/iOS/CodeEditorCoordinator_iOS.swift:405`) fill `offset`. No
    seam change, no view-layer change.
  - Explicit invocation (⌃Space / menu) goes through the same `update(…)` and
    builds the same request — `explicit` only skips the debounce and the
    minimum-prefix gate. Requirement 5 therefore needs no code of its own, only
    a test.
  - `RoutingIntelligenceProvider.completions(for:)` forwards the *same* request
    to the fallback, so the gate applies unchanged behind the router. The
    router's empty-answer fall-through is untouched.
  - Existing provider tests build `CompletionRequest` without `offset` (it
    defaults to `nil`), so "no offset ⇒ no gate" keeps every one of them passing
    unmodified.
  - `CommentStyle` models one *preferred toggle* style per language (Swift gets
    `//` only, never `/* */`). It is a toggle authority, not a lexing
    vocabulary, so the new table is separate — with a consistency test that pins
    the relationship rather than duplicating the data.
  - `LanguageKeywords` / `SymbolIndexModel.unindexableLanguages` give the
    closed-set pattern to mirror: an explicit "declares nothing" set plus a
    set-equality test against `SyntaxLanguage.allCases`, so a new language cannot
    fall through silently.
  - `BracketDepthScanner` gives the performance pattern: chunked
    `getCharacters(_:range:)` reads into a reusable `[unichar]` buffer
    (`chunkSize = 4096`) instead of per-character message sends.
  - Lint constraints that shape the code: `cyclomatic_complexity` and
    `function_body_length` ceilings are measured maxima (22 / 140), documented
    as "honest ceilings, not disables". The scanner must be decomposed into
    per-state helpers rather than one large loop; no threshold is raised and no
    in-file `swiftlint:disable` is added.

- Dependencies: none. Foundation only.

## Design decisions this plan fixes

### 1. Two questions, one scan

`SyntaxContextScanner` answers honestly — `.code`, `.string`, `.comment` — and a
separate policy decides which of those *suppress completion*, per language. That
split is what lets a language recognize its strings (so a `#` inside a quoted
scalar is not mistaken for a comment) without gating them.

Public API:

- `SyntaxContextScanner.context(in: NSString, at: Int, language: SyntaxLanguage)
  -> SyntaxContext`
- `SyntaxContextScanner.suppressesCompletion(in:at:language:) -> Bool` — the one
  call the provider makes.

### 2. Per-language vocabulary — every one of the 16 cases decided

Strings gated where a string is an island inside code; recognized-but-ungated
where the strings *are* the document's vocabulary (so word completion of a
repeated key keeps working there, and comment lexing stays correct); no
vocabulary at all where the language has neither.

| language | string forms | strings gate? | comments |
|---|---|---|---|
| swift | `"…"` single-line; `"""…"""` multi-line; pound padding `#"…"#`/`##"…"##` (escape is `\` + N `#`) | yes | `//` anywhere; `/* */` **nesting** |
| javascript / typescript | `'…'`, `"…"` single-line, `\` escape; `` `…` `` multi-line with `${…}` holes | yes | `//`; `/* */` non-nesting |
| python | `'…'`, `"…"` single-line; `'''…'''`, `"""…"""` multi-line; prefixes `r b u f` in any case/order — `r` makes `\` inert, `f` enables `{…}` holes (`{{`/`}}` are literal) | yes | `#` anywhere |
| go | `"…"` single-line `\`; `` `…` `` raw multi-line, no escapes; `'…'` rune, single-line | yes | `//`; `/* */` non-nesting |
| rust | `"…"` `\`; raw `r"…"`, `r#"…"#`, `br#"…"#` (no escapes). **`'` is deliberately not a string delimiter** | yes | `//`; `/* */` **nesting** |
| css | `'…'`, `"…"` single-line `\` | yes | `/* */` non-nesting |
| sql | `'…'` multi-line, escape by doubling (`''`). `"` deliberately not modeled | yes | `--` anywhere; `/* */` non-nesting |
| dockerfile | `'…'`, `"…"` single-line `\` | yes | `#` at line start only |
| json | `"…"` single-line `\` | **no** | none |
| yaml | `'…'` (doubling escape), `"…"` (`\`), single-line | **no** | `#` at line start or after whitespace |
| html | `'…'`, `"…"` attribute values, single-line, no escapes | **no** | `<!-- -->` non-nesting |
| dotenv | `'…'`, `"…"` single-line | **no** | `#` at line start |
| gitignore | none | — | `#` at line start |
| editorconfig | none | — | `#` and `;` at line start |
| markdown | none | none | **completely ungated** |

Stated reasons carried in the source doc comments:

- **Rust's `'`**: a lifetime (`&'a str`, `T: 'static`) would open a bogus
  literal; the single-line recovery rule bounds the damage to that line, but the
  *right* answer is not to model it. A char literal is one character wide and
  never worth completing inside.
- **SQL's `"`**: it quotes an *identifier*, which is exactly the thing worth
  completing; gating it would silence completion on quoted column names.
- **JSON / YAML / HTML / dotenv**: gating them silences the only completion
  those files have — buffer-word completion of a repeated key, class name, path
  or variable. Their strings are still *lexed*, because that is what keeps `#`
  inside a quoted YAML scalar from reading as a comment and `<!--` inside an
  attribute value from reading as one.
- **Markdown**: prose all the way down, with no vocabulary to speak of.
- **Regex literals are not modeled** (JS/TS) and neither are
  `<script>`/`<style>` bodies in HTML: distinguishing `/` division from a regex
  opener needs a parser, and an embedded-language body needs a second grammar.
  Stated limits, not omissions.

### 3. Interpolation holes — Python f-strings are included

`${…}` (template literals), `\(…)` / `\#(…)` (Swift, pound count matching the
string's) and `{…}` in Python f-strings all re-open `.code`. F-strings are in
because excluding them would be a *regression*: completion inside
`f"{user.na|me}"` works today and is genuinely useful, and the brace-depth
machinery is the same machinery `${…}` already needs — the only extra rule is
that `{{`/`}}` are literal braces. Holes count depth, so `${ {a: 1} }` closes at
the right brace, and the scanner keeps an explicit state stack so a string
inside a hole inside a string nests correctly.

### 4. The boundary rule

The context at offset `k` is the state after consuming characters `[0, k)`. That
yields exactly the rule Requirement 7 asks for, with no special-casing: just
before an opening quote is code, just after it is string; just before the
closing quote is string, just after it is code. A caret between the two slashes
of `//` is code; after both, comment. A single-line form's state is reset at a
line separator, so an unterminated `'` cannot poison the rest of the buffer; a
multi-line form runs to the end of the buffer, and the caret after an
unterminated opener is inside.

### 5. Where the gate goes, and how often it is asked

One guard at the top of the static
`completions(for:in:limit:bufferWordLimit:)`, *before* the member branch — so
member completion (Requirement 6) is covered by the same line. `nil` offset or
`nil` language means no position or no vocabulary, hence no gate.
`SyntaxContextVocabulary.canSuppressCompletion(_:)` short-circuits before any
scan for a language whose vocabulary can produce no suppressing context
(markdown, json), so those files pay nothing. One call site, one scan per
request.

## Development Approach

- **Testing approach**: Regular (code first, then tests) for the vocabulary
  table; TDD for the scanner, where the edge cases *are* the specification.
- Complete each task fully before moving to the next.
- Every task ships new or updated `PisakaCore` tests; `swift test` must be green
  before the next task starts.
- No product or brand names in code, comments, tests, docs or commit messages.
- Keep every new function inside the measured lint ceilings by decomposing the
  scanner into per-state helpers; do not raise a threshold and do not add an
  in-file disable.

## Implementation Steps

### Task 1: The per-language vocabulary table

**Files:**
- Create: `Sources/PisakaCore/SyntaxContextVocabulary.swift`
- Create: `Tests/PisakaCoreTests/SyntaxContextVocabularyTests.swift`

- [x] define the value types: a string form (open/close delimiters,
      `spansLines`, escape rule — none / backslash / doubled-delimiter, optional
      letter prefixes, whether pound padding is allowed, the hole rule) and a
      comment form (line with an anchor — anywhere / line start / after
      whitespace — or block with a `nestable` flag)
- [x] write `SyntaxContextVocabulary.vocabulary(for:)` covering all 16
      `SyntaxLanguage` cases exactly as the table above states, each non-obvious
      decision carrying its reason in a doc comment
- [x] add the explicit `languagesWithoutStringVocabulary` set (`markdown`,
      `gitignore`, `editorconfig`) and the per-language
      `stringsSuppressCompletion` flag (false for `json`, `yaml`, `html`,
      `dotenv`)
- [x] add `canSuppressCompletion(_:)` — true when the language has comment forms
      or gated string forms; false for `markdown` and `json`
- [x] write tests: set equality of `languagesWithoutStringVocabulary` ∪
      (languages with string forms) against `SyntaxLanguage.allCases`; the same
      closure check for comment forms against
      `CommentStyle.languagesWithoutComments`; the containment consistency test
      (every token `CommentStyle.style(for:)` names must appear among that
      language's comment forms, and a language in `languagesWithoutComments`
      must declare none) with a doc comment explaining why containment and not
      equality; `canSuppressCompletion` per language; no empty or duplicated
      delimiter
- [x] run `swift test` — must pass before Task 2

### Task 2: The scanner

**Files:**
- Create: `Sources/PisakaCore/SyntaxContextScanner.swift`
- Create: `Tests/PisakaCoreTests/SyntaxContextScannerTests.swift`

- [x] write the failing tests first, one per rule: plain single- and
      double-quoted strings in each gated language; multi-line forms (triple
      quotes, backticks); raw and pound-padded forms; escaped quote and escaped
      backslash (`"a\\"` closes, `"a\""` does not); doubled-delimiter escape in
      SQL and YAML; unterminated single-line string ending at the line
      separator; unterminated multi-line string running to the buffer end with
      the caret inside; the four boundary offsets around an opening and a
      closing delimiter; a caret between the two characters of `//`; line
      comment to end of line; block comment across lines; nested block comments
      in Swift and Rust versus non-nesting elsewhere; `//` and `#` inside a
      string are not comments; a quote inside a comment does not open a string;
      `${…}`, `\(…)`, `\#(…)` and Python `{…}` holes reporting `.code`;
      `{{`/`}}` staying literal; brace/paren depth inside a hole; a string
      nested inside a hole; anchored comment tokens (`#` mid-line in a
      Dockerfile / gitignore / editorconfig line is *not* a comment; `#`
      mid-line after whitespace in YAML is, and inside a quoted YAML scalar is
      not); Rust `'a` lifetimes leaving the rest of the line as code; markdown
      always `.code`; JSON strings reported `.string` but `suppressesCompletion`
      false; out-of-range and negative offsets
- [x] implement `SyntaxContext` and `SyntaxContextScanner`: an explicit state
      stack, chunked `getCharacters(_:range:)` reads with a reusable `[unichar]`
      buffer following `BracketDepthScanner`'s pattern, decomposed into
      per-state helpers so no function exceeds the measured complexity/length
      ceilings
- [x] implement `suppressesCompletion(in:at:language:)`: short-circuit on
      `canSuppressCompletion`, then map the context through
      `stringsSuppressCompletion`
- [x] run `swift test` — must pass before Task 3

### Task 3: The gate in the fallback provider

**Files:**
- Modify: `Sources/PisakaCore/SymbolIntelligenceProvider.swift`
- Modify: `Sources/PisakaCore/CodeIntelligence.swift`
- Modify: `Tests/PisakaCoreTests/SymbolIntelligenceProviderTests.swift`

- [x] add the guard at the top of the static
      `completions(for:in:limit:bufferWordLimit:)`, before the member branch,
      with a doc comment stating: why it is here and not in the router or the
      view layer, why `nil` offset and `nil` language mean ungated, and that it
      is asked exactly once per request
- [x] extend the method's existing documentation block with the gate as a stated
      rule, and note that `definitions(…)`, the index and the walk stay
      untouched — the same navigation-versus-typing asymmetry the candidate rule
      already records
- [x] correct `CompletionRequest.offset`'s doc comment, which currently says the
      tree-sitter provider ignores the field entirely
- [x] append provider tests: in-string and in-comment requests return `[]` for
      symbols, keywords and buffer words alike; a request in a `${…}` hole and
      one in a `\(…)` hole return exactly what the same request in open code
      returns; a member request inside a string returns `[]`; the request the
      explicit path builds is gated identically (same request shape, no
      `explicit` flag reaching the provider); `nil` offset ungated; `nil`
      language ungated; an out-of-range offset ungated; a
      `json`/`yaml`/`html`/`dotenv` string ungated; a `markdown` buffer ungated;
      a comment in `yaml` gated; a mid-line `#` in a Dockerfile line ungated
- [x] confirm no existing test in the file was edited
- [x] run `swift test` — must pass before Task 4

### Task 4: Verify acceptance criteria

- [x] run `swift test` — full suite green
- [x] run `swiftlint --strict` from the repository root — clean, with no
      threshold raised and no in-file disable added
- [x] run `xcodegen generate` and build macOS: `xcodebuild -project
      Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`
- [x] build iOS: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka
      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- [x] confirm by `git diff` that no view-layer file changed and that
      `RoutingIntelligenceProvider.swift` and `LSPIntelligenceProvider.swift`
      are untouched

### Task 5: Update documentation

**Files:**
- Modify: `CLAUDE.md`, `docs/architecture/core-intelligence.md`,
  `docs/architecture/core-editor.md`

- [ ] add two index lines to `CLAUDE.md` under `core-intelligence.md` — one for
      `SyntaxContextVocabulary.swift`, one for `SyntaxContextScanner.swift`
- [ ] add the full entries to `docs/architecture/core-intelligence.md`: the
      two-questions split, the whole per-language table with its reasons, the
      interpolation-hole decision including why f-strings are in, the boundary
      rule, the stated limits (regex literals, embedded HTML bodies, Rust `'`,
      SQL `"`), the single-call-site rule and the `canSuppressCompletion`
      short-circuit
- [ ] update the `SymbolIntelligenceProvider` and `CompletionRequest` entries in
      the same doc for the gate
- [ ] add one cross-reference sentence under `BracketDepthScanner` in
      `docs/architecture/core-editor.md`: a lexing engine now exists, and it is
      deliberately not shared — rainbow brackets scan the whole buffer on every
      debounce and want raw characters, while this answers one offset per
      request
- [ ] re-run `swift test` and `swiftlint --strict`

## Post-Completion (manual)

- Open a buffer of each gated language and confirm by hand that typing inside a
  plain string and inside a comment opens no popup, and that typing inside
  `${…}` and `\(…)` completes exactly as in open code.
