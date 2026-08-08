; Symbol declarations for Markdown (tree-sitter-grammars/tree-sitter-markdown).
;
; Convention, shared by every symbols.scm in this directory: the captured node
; is always the *name* node, and the capture name is the kind. An optional
; @container capture in the same match names the enclosing type.
;
; A heading's content node starts *after* the `#` markers but still includes the
; space that separates them from the text, so the extractor trims a captured
; name before storing it — the one language where the name node is not already
; exactly the identifier.

(atx_heading heading_content: (inline) @definition.heading)

(setext_heading heading_content: (paragraph) @definition.heading)
