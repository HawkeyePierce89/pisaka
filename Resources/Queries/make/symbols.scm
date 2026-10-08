; Symbol declarations for Make (tree-sitter-grammars/tree-sitter-make, vendored
; under Vendor/TreeSitterMake).
;
; Convention, shared by every symbols.scm in this directory: the captured node
; is always the *name* node, and the capture name is the kind. An optional
; @container capture in the same match names the enclosing type.
;
; Two decisions this file makes:
;
;  * **Special and pattern targets are excluded by a predicate.** `.PHONY`,
;    `.SUFFIXES`, `.DEFAULT_GOAL` and every other dot-led target is a directive
;    to make, not a name the user declared, and a pattern rule's `%.o` declares
;    no name at all — so both would only clutter ⌃⌘J. The `#not-match?` is what
;    keeps them out, which makes this the second symbols query that needs a
;    predicate (HTML's `id` filter is the first); `SymbolQueryTests` pins the
;    exact set, and `MakeSymbolQueryTests` executes the query to prove the
;    predicate is evaluated rather than merely present.
;  * **Variables are unanchored.** Make has no local scope: an assignment
;    nested under an `ifeq`/`ifdef` block (a `conditional` node) is as global
;    as one at the top, so anchoring at the root would silently drop every
;    conditionally defined variable. A target-specific assignment
;    (`test: CFLAGS += -g`) is a real definition site too and is indexed;
;    ⌃⌘J already lists several definitions of one name.

; ---- Rule targets ----------------------------------------------------------
; A `$(VAR):` target is a reference, not a `word`, and is not captured.
((rule (targets (word) @definition.target))
 (#not-match? @definition.target "^[.]|%"))

; ---- Variables -------------------------------------------------------------
(variable_assignment name: (word) @definition.variable)
(shell_assignment name: (word) @definition.variable)
(define_directive name: (word) @definition.variable)
