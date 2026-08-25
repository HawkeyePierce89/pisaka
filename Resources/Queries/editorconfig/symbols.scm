; Symbol declarations for EditorConfig (tree-sitter-editorconfig).
;
; Convention, shared by every symbols.scm in this directory: the captured node
; is always the *name* node, and the capture name is the kind. An optional
; @container capture in the same match names the enclosing type.
;
; Section headers are mapped to @definition.heading, not @definition.selector.
; This is deliberate: .heading is excluded from keyword completion, keeping 
; identifier-shaped headers like [Makefile] from being offered for insertion,
; without changing the behavior for CSS selectors.

(section (header (glob) @definition.heading))
