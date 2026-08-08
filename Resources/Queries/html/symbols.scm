; Symbol declarations for HTML (tree-sitter/tree-sitter-html).
;
; Convention, shared by every symbols.scm in this directory: the captured node
; is always the *name* node, and the capture name is the kind. An optional
; @container capture in the same match names the enclosing type.
;
; This is the one query that needs a *predicate*: an `id` attribute is
; structurally identical to every other attribute — `attribute_name` is a named
; node whose text is the only thing that distinguishes it — so the filter cannot
; be expressed as a pattern. `@_attribute` is an **auxiliary** capture: the
; leading underscore is tree-sitter's convention for "not an output", and
; `SymbolKind(captureName:)` rejects it, so it can never become a symbol. The
; extractor must therefore *resolve predicates* rather than walk raw matches;
; without that, every attribute value in the file would be indexed as an anchor.
; Both halves are asserted by `SymbolQueryTests`.

((attribute
   (attribute_name) @_attribute
   (quoted_attribute_value (attribute_value) @definition.anchor))
 (#eq? @_attribute "id"))

((attribute
   (attribute_name) @_attribute
   (attribute_value) @definition.anchor)
 (#eq? @_attribute "id"))
