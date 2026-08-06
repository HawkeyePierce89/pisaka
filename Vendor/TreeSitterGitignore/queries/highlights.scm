; Highlight query for tree-sitter-gitignore.
;
; NOT upstream — written in this repository (see ../VENDORED.md). Upstream ships
; no `queries/` directory at all.
;
; Every node name below is taken verbatim from `src/node-types.json`; none is
; guessed. Both failure modes of this file are silent in the app, so it is
; verified element by element against a fixture — see the "Verification" section
; of ../VENDORED.md and re-run it after any grammar update:
;   * an unknown *node* name makes the query fail to compile, so
;     `LanguageConfiguration` throws and the file degrades to plain text;
;   * a mistyped *capture* name compiles fine and resolves to
;     `SyntaxTokenKind.plain`, i.e. default-colored text.
;
; Capture names are restricted to prefixes `SyntaxTokenKind` already maps
; (`comment`, `operator`, `string`, `punctuation`), so this query needs no
; change to the Core mapping.

; ---------------------------------------------------------------------------
; Comments — a whole `# …` line.
; ---------------------------------------------------------------------------

(comment) @comment

; ---------------------------------------------------------------------------
; Operators: negation and wildcards, the two things that change what a pattern
; means rather than what it names.
; ---------------------------------------------------------------------------

; A leading `!` (re-include an otherwise ignored path).
(negation) @operator

; `?` — one character.
(wildcard_char_single) @operator
; `*` — any run of characters within one path component.
(wildcard_chars) @operator
; `**` — any run of characters, slashes included.
(wildcard_chars_allow_slash) @operator

; ---------------------------------------------------------------------------
; The pattern body itself.
;
; `pattern_char` matches a *single* character (grammar rule `/[^\n/*?]/`), so a
; name like `node_modules` parses as a run of adjacent `pattern_char` nodes,
; each captured separately. That is invisible in the rendered result — the whole
; run ends up one color — but it is what the verification fixture's output looks
; like, so it is stated here rather than read as a bug.
; ---------------------------------------------------------------------------

(pattern_char) @string
(pattern_char_escaped) @string

; ---------------------------------------------------------------------------
; Path structure: `/`, and its escaped form `\/`.
; ---------------------------------------------------------------------------

(directory_separator) @punctuation.delimiter
(directory_separator_escaped) @punctuation.delimiter

; ---------------------------------------------------------------------------
; Bracket expressions — `[abc]`, `[a-z]`, `[!abc]`, `[[:digit:]]`.
;
; The enclosing brackets and the range's `-` are anonymous tokens; the negation
; is an operator like the leading `!`; everything that *names* characters is
; part of the pattern body and so takes the same color as it. `bracket_range`
; and `bracket_char_class` are deliberately captured as whole nodes rather than
; through their inner tokens, so no element is left uncaptured.
; ---------------------------------------------------------------------------

(bracket_expr "[" @punctuation.bracket "]" @punctuation.bracket)
(bracket_negation) @operator
(bracket_range "-" @operator)
(bracket_char) @string
(bracket_char_escaped) @string
(bracket_char_class) @string
