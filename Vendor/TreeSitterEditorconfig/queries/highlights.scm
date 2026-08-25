; Highlight query for tree-sitter-editorconfig.
;
; NOT upstream — written in this repository (see ../VENDORED.md). Upstream ships
; queries/editorconfig/highlights.scm, but it is deliberately not adopted because
; its capture names sit outside the vocabulary SyntaxTokenKind maps, and it uses
; #lua-match?.
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
; Capture names are restricted to prefixes `SyntaxTokenKind` already maps.

; ---------------------------------------------------------------------------
; Comments
; ---------------------------------------------------------------------------

(comment) @comment

; ---------------------------------------------------------------------------
; Preamble (root = true)
; ---------------------------------------------------------------------------

(preamble
  (pair
    key: (property) @keyword
    value: (string)? @constant))

; ---------------------------------------------------------------------------
; Properties
; ---------------------------------------------------------------------------

(pair
  key: (property) @property
  "=" @operator
  value: (string)? @string)

; ---------------------------------------------------------------------------
; Section Headers & Globs
; ---------------------------------------------------------------------------

(section
  (header
    "[" @punctuation.bracket
    (glob) @string
    "]" @punctuation.bracket))

(wildcard) @operator
(character_choice "!" @operator)
(character_choice "[" @punctuation.bracket "]" @punctuation.bracket)
(character_range "-" @operator)
(brace_expansion "{" @punctuation.bracket "}" @punctuation.bracket)
(brace_expansion "," @punctuation.delimiter)
(integer_range "{" @punctuation.bracket "}" @punctuation.bracket)
(integer_range ".." @punctuation.delimiter)
(integer) @number
(glob "/" @punctuation.delimiter)
