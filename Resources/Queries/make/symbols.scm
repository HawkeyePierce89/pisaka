; Symbol declarations for Make (tree-sitter-grammars/tree-sitter-make, vendored
; under Vendor/TreeSitterMake).
;
; Convention, shared by every symbols.scm in this directory: the captured node
; is always the *name* node, and the capture name is the kind. An optional
; @container capture in the same match names the enclosing type.
;
; Two decisions this file makes:
;
;  * **Special names and pattern targets are excluded by a predicate.**
;    `.PHONY`, `.SUFFIXES` and the other special targets, like the special
;    variables `.DEFAULT_GOAL` and `.RECIPEPREFIX`, are directives to make, not
;    names the user declared, and a pattern rule's `%.o` declares no name at
;    all — so they would only clutter ⌃⌘J. GNU make spells every special name
;    as a dot followed by capitals and underscores, and only that shape is
;    filtered: an ordinary dot-led file target (`.venv`, `.build/app`) is a
;    real name and stays indexed. The `#not-match?` is what keeps them out,
;    which makes this the second symbols query that needs a predicate (HTML's
;    `id` filter is the first); `SymbolQueryTests` pins the exact set, and
;    `MakeSymbolQueryTests` executes the query to prove the predicate is
;    evaluated rather than merely present.
;  * **Variables are unanchored.** Make has no local scope: an assignment
;    nested under an `ifeq`/`ifdef` block (a `conditional` node) is as global
;    as one at the top, so anchoring at the root would silently drop every
;    conditionally defined variable. A target-specific assignment
;    (`test: CFLAGS += -g`) is a real definition site too and is indexed;
;    ⌃⌘J already lists several definitions of one name.

; ---- Rule targets ----------------------------------------------------------
; A `$(VAR):` target is a reference, not a `word`, and is not captured.
((rule (targets (word) @definition.target))
 (#not-match? @definition.target "^[.][A-Z_]+$|%"))

; ---- Variables -------------------------------------------------------------
((variable_assignment name: (word) @definition.variable)
 (#not-match? @definition.variable "^[.][A-Z_]+$"))
(shell_assignment name: (word) @definition.variable)
(define_directive name: (word) @definition.variable)
