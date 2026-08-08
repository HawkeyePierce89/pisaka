; Symbol declarations for dotenv (Vendor/TreeSitterDotenv, pnx/tree-sitter-dotenv).
;
; Convention, shared by every symbols.scm in this directory: the captured node
; is always the *name* node, and the capture name is the kind. An optional
; @container capture in the same match names the enclosing type.
;
; A `.env` file is a flat list of `KEY=value` assignments, so every assignment
; key is a declaration and there is nothing to nest it in.

(document
  (assignment key: (identifier) @definition.variable))
