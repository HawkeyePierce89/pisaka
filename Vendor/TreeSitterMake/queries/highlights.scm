; Highlight query for tree-sitter-make.
;
; ADAPTED from upstream's queries/highlights.scm at the pinned commit (see
; ../VENDORED.md for the commit and the full list of edits). Upstream's file
; cannot be adopted verbatim: `@spell` and `@character.special` resolve to
; `SyntaxTokenKind.plain`, and it colours variable names as
; `@string.special.symbol` and references as `@string`, which would draw every
; variable in string colour. Every edit is marked `; EDIT:` below; everything
; unmarked is upstream's text.
;
; Every node name below is declared in `src/node-types.json`. Both failure modes
; of this file are silent in the app, so it is verified against two fixtures —
; see the "Verification" section of ../VENDORED.md and re-run it after any
; grammar update:
;   * an unknown *node* name makes the query fail to compile, so
;     `LanguageConfiguration` throws and the file degrades to plain text;
;   * a mistyped *capture* name compiles fine and resolves to
;     `SyntaxTokenKind.plain`, i.e. default-colored text.
;
; Capture names are restricted to prefixes `SyntaxTokenKind` already maps.

; EDIT: `@spell` dropped (no SyntaxTokenKind; resolves to .plain).
(comment) @comment

(conditional
  (_
    [
      "ifeq"
      "else"
      "ifneq"
      "ifdef"
      "ifndef"
    ] @keyword.conditional)
  "endif" @keyword.conditional)

(rule
  (targets
    (word) @function))

(rule
  (targets) @_target
  (prerequisites
    (word) @function
    (#eq? @_target ".PHONY")))

; EDIT: ".NOTINTERMEDIATE" and ".WAIT" added — GNU make 4.4's special targets,
; missing from upstream's list.
(rule
  (targets
    (word) @function.builtin
    (#any-of? @function.builtin
      ".DEFAULT" ".SUFFIXES" ".DELETE_ON_ERROR" ".EXPORT_ALL_VARIABLES" ".IGNORE" ".INTERMEDIATE"
      ".LOW_RESOLUTION_TIME" ".NOTINTERMEDIATE" ".NOTPARALLEL" ".ONESHELL" ".PHONY" ".POSIX"
      ".PRECIOUS" ".SECONDARY" ".SECONDEXPANSION" ".SILENT" ".SUFFIXES" ".WAIT")))

; EDIT: added — `.WAIT` is ordinarily written as a prerequisite
; (`all: one .WAIT two`), where it orders the parallel build rather than naming
; a file. A static-pattern rule's prerequisites are a `pattern_list` instead.
(prerequisites
  (word) @function.builtin
  (#eq? @function.builtin ".WAIT"))

(rule
  prerequisite: (pattern_list
    (word) @function.builtin
    (#eq? @function.builtin ".WAIT")))

(rule
  [
    "&:"
    ":"
    "::"
    "|"
  ] @operator)

[
  "export"
  "unexport"
] @keyword.import

(override_directive
  "override" @keyword)

; EDIT: added — `vpath`, `undefine` and `private` are GNU make directives the
; grammar parses into nodes of their own, but upstream gave them no capture, so
; the keyword stayed plain text.
(vpath_directive
  "vpath" @keyword)

(undefine_directive
  "undefine" @keyword)

(private_directive
  "private" @keyword)

; EDIT: "sinclude" added — the grammar parses it as an include_directive
; (GNU make's alias for -include), and without it the whole pattern failed to
; match, leaving the keyword and its filenames uncoloured. The keyword and the
; filenames are also split into two patterns: upstream's single pattern required
; a bare `word` filename, so `include $(DEPS)` left the keyword plain.
(include_directive
  [
    "include"
    "-include"
    "sinclude"
  ] @keyword.import)

(include_directive
  filenames: (list
    (word) @string.special.path))

; EDIT: name `@string.special.symbol` → `@variable` (a definition is a
; variable, not a string).
(variable_assignment
  name: (word) @variable
  [
    "?="
    ":="
    "::="
    ; ":::="
    "+="
    "="
  ] @operator)

; EDIT: name `@string.special.symbol` → `@variable`.
(shell_assignment
  name: (word) @variable
  "!=" @operator)

; EDIT: name `@string.special.symbol` → `@variable`; operator "!=" (which the
; grammar never produces here) replaced by "+=" (which it does).
(define_directive
  "define" @keyword
  name: (word) @variable
  [
    "="
    ":="
    "::="
    ; ":::="
    "?="
    "+="
  ]? @operator
  "endef" @keyword)

; EDIT: added — a target-specific assignment (`debug: CFLAGS += -O0`) is a
; `variable_assignment`, not a `rule`, so upstream left its target and `:`
; uncoloured. They are drawn as an ordinary rule's are.
(variable_assignment
  target_or_pattern: (list
    (word) @function)
  ":" @operator)

; EDIT: ".LIBPATTERNS", ".LOADED" and ".SHELLSTATUS" added — GNU make's
; special variables, missing from upstream's list. "VPATH" added to all three
; lists: `override VPATH = …` and `define VPATH` name it as an ordinary `word`,
; which the dedicated `VPATH_assignment` pattern below never sees.
(variable_assignment
  (word) @variable.builtin
  (#any-of? @variable.builtin
    ".DEFAULT_GOAL" ".EXTRA_PREREQS" ".FEATURES" ".INCLUDE_DIRS" ".LIBPATTERNS" ".LOADED"
    ".RECIPEPREFIX" ".SHELLFLAGS" ".SHELLSTATUS" ".VARIABLES" "MAKEARGS" "MAKEFILE_LIST" "MAKEFLAGS" "MAKE_RESTARTS" "MAKE_TERMERR"
    "MAKE_TERMOUT" "SHELL" "VPATH"))

; EDIT: added — `.DEFAULT_GOAL != …` and `define .FEATURES` set a special
; variable as surely as `:=` does, so the same list applies to both forms.
(shell_assignment
  name: (word) @variable.builtin
  (#any-of? @variable.builtin
    ".DEFAULT_GOAL" ".EXTRA_PREREQS" ".FEATURES" ".INCLUDE_DIRS" ".LIBPATTERNS" ".LOADED"
    ".RECIPEPREFIX" ".SHELLFLAGS" ".SHELLSTATUS" ".VARIABLES" "MAKEARGS" "MAKEFILE_LIST" "MAKEFLAGS" "MAKE_RESTARTS" "MAKE_TERMERR"
    "MAKE_TERMOUT" "SHELL" "VPATH"))

(define_directive
  name: (word) @variable.builtin
  (#any-of? @variable.builtin
    ".DEFAULT_GOAL" ".EXTRA_PREREQS" ".FEATURES" ".INCLUDE_DIRS" ".LIBPATTERNS" ".LOADED"
    ".RECIPEPREFIX" ".SHELLFLAGS" ".SHELLSTATUS" ".VARIABLES" "MAKEARGS" "MAKEFILE_LIST" "MAKEFLAGS" "MAKE_RESTARTS" "MAKE_TERMERR"
    "MAKE_TERMOUT" "SHELL" "VPATH"))

; EDIT: added — `VPATH` and `.RECIPEPREFIX` assignments are dedicated nodes
; whose name is an anonymous token, so neither pattern above matches them and
; upstream left both uncoloured. Their names are built-in variables.
(VPATH_assignment
  "VPATH" @variable.builtin
  [
    "?="
    ":="
    "::="
    "+="
    "="
  ] @operator)

(RECIPEPREFIX_assignment
  ".RECIPEPREFIX" @variable.builtin
  [
    "?="
    ":="
    "::="
    "+="
    "="
  ] @operator)

; EDIT: upstream captured the referenced name as `@string` ("to match bash")
; and the whole reference node as `@operator`. The name is `@variable` here,
; and only the delimiters are `@operator`, so the two captures no longer
; overlap.
(variable_reference
  (word) @variable)

(variable_reference
  [
    "$"
    "$$"
    "("
    ")"
    "{"
    "}"
  ] @operator)

(shell_function
  [
    "$"
    "("
    ")"
  ] @operator
  "shell" @function.builtin)

(function_call
  [
    "$"
    "("
    ")"
  ] @operator)

(substitution_reference
  [
    "$"
    "("
    ")"
  ] @operator)

; EDIT: `@character.special` → `@variable.builtin` (`$@`, `$<`, `$^`, … are
; make's built-in automatic variables; `@character.special` resolves to .plain).
(automatic_variable
  "$"
  _ @variable.builtin
  (#set! priority 105))

(automatic_variable
  [
    "$"
    "("
    ")"
  ] @operator
  (#set! priority 105))

; EDIT: `@character.special` → `@operator` (the recipe's echo-suppression
; prefix; `@character.special` resolves to .plain).
(recipe_line
  "@" @operator)

; EDIT: "intcmp", "let" and "guile" added — the pinned grammar.js declares
; them in FUNCTIONS but upstream's query list was not updated with them.
(function_call
  [
    "subst"
    "patsubst"
    "strip"
    "findstring"
    "filter"
    "filter-out"
    "sort"
    "word"
    "words"
    "wordlist"
    "firstword"
    "lastword"
    "dir"
    "notdir"
    "suffix"
    "basename"
    "addsuffix"
    "addprefix"
    "join"
    "wildcard"
    "realpath"
    "abspath"
    "error"
    "warning"
    "info"
    "origin"
    "flavor"
    "foreach"
    "if"
    "or"
    "and"
    "intcmp"
    "let"
    "call"
    "eval"
    "file"
    "value"
    "guile"
  ] @function.builtin)

"\\" @punctuation.special
