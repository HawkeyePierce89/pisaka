; Symbol declarations for Dockerfile (camdencheek/tree-sitter-dockerfile).
;
; Convention, shared by every symbols.scm in this directory: the captured node
; is always the *name* node, and the capture name is the kind. An optional
; @container capture in the same match names the enclosing type.
;
; A multi-stage build's stage names are the only things a Dockerfile declares
; and then refers to by name (`FROM builder`, `COPY --from=builder`), so they
; are what the index carries.

(from_instruction as: (image_alias) @definition.stage)
