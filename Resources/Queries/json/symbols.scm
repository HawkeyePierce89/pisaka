; Symbol declarations for JSON (tree-sitter/tree-sitter-json).
;
; Convention, shared by every symbols.scm in this directory: the captured node
; is always the *name* node, and the capture name is the kind. An optional
; @container capture in the same match names the enclosing type.
;
; Only *top-level* keys are indexed — the pattern is anchored to
; `(document (object …))`. A `package-lock.json` has tens of thousands of nested
; keys and none of them is a name anybody navigates to; the top-level ones
; (`scripts`, `dependencies`, `name`) are. `string_content` rather than
; `(string)` is captured so the quotes are not part of the symbol name.

(document
  (object
    (pair key: (string (string_content) @definition.key))))
