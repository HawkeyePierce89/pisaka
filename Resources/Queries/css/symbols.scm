; Symbol declarations for CSS (tree-sitter/tree-sitter-css).
;
; Convention, shared by every symbols.scm in this directory: the captured node
; is always the *name* node, and the capture name is the kind. An optional
; @container capture in the same match names the enclosing type.
;
; Class and id selectors are matched wherever they appear rather than only as a
; direct child of `(selectors …)`, so `.card .title { … }` contributes both
; names — a compound selector is still a place each of its parts is defined.
; The captured node is the *name* (`card`), not the selector node, so the
; leading `.`/`#` is not part of the symbol.

(class_selector (class_name) @definition.selector)

(id_selector (id_name) @definition.selector)

(keyframes_statement (keyframes_name) @definition.selector)
