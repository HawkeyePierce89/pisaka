; Symbol declarations for Python (tree-sitter/tree-sitter-python).
;
; Convention, shared by every symbols.scm in this directory: the captured node
; is always the *name* node, and the capture name is the kind. An optional
; @container capture in the same match names the enclosing type.
;
; Python spells a method and a free function with the same node
; (`function_definition`), so the two are told apart by their *parent*: the
; top-level patterns are anchored to `(module …)` and the member patterns to a
; class body. Without that anchoring every method would be emitted twice.
; A decorated declaration nests one level deeper, hence the paired patterns.

; ---- Classes ---------------------------------------------------------------
(class_definition name: (identifier) @definition.type)

; ---- Methods and class attributes ------------------------------------------
(class_definition
  name: (identifier) @container
  body: (block (function_definition name: (identifier) @definition.method)))

(class_definition
  name: (identifier) @container
  body: (block (decorated_definition
                 (function_definition name: (identifier) @definition.method))))

(class_definition
  name: (identifier) @container
  body: (block (expression_statement
                 (assignment left: (identifier) @definition.property))))

; ---- Top-level functions and bindings --------------------------------------
(module (function_definition name: (identifier) @definition.function))

(module (decorated_definition
          (function_definition name: (identifier) @definition.function)))

(module (expression_statement (assignment left: (identifier) @definition.variable)))
