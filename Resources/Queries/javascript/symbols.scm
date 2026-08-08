; Symbol declarations for JavaScript (tree-sitter/tree-sitter-javascript).
;
; Convention, shared by every symbols.scm in this directory: the captured node
; is always the *name* node, and the capture name is the kind. An optional
; @container capture in the same match names the enclosing type.
;
; A binding's kind follows its *declaration keyword* (`const` → constant,
; `let`/`var` → variable) rather than its value, so `const render = () => …`
; is indexed exactly once. Matching on the value as well would emit a second,
; duplicate symbol at the same range — and phase 1 shows no kind column, so the
; extra precision would buy nothing.
;
; `private_property_identifier` is the one captured node whose text is not just
; the name: the grammar spans the leading `#` (`#count`) and offers no inner node
; to capture instead. `SymbolExtractor` narrows that one code unit off both the
; text and the range, so the member is stored as `count` — the spelling
; `IdentifierScanner` resolves, and therefore the only one go-to-definition and
; completion can ever reach. See the `#` rule on `SymbolExtractor.name`.

; ---- Classes ---------------------------------------------------------------
(class_declaration name: (identifier) @definition.type)

(class_declaration
  name: (identifier) @container
  body: (class_body (method_definition
                      name: [(property_identifier) (private_property_identifier)] @definition.method)))

(class_declaration
  name: (identifier) @container
  body: (class_body (field_definition
                      property: [(property_identifier) (private_property_identifier)] @definition.property)))

; ---- Functions -------------------------------------------------------------
(function_declaration name: (identifier) @definition.function)
(generator_function_declaration name: (identifier) @definition.function)

; An object literal's function-valued members read as methods.
(pair
  key: (property_identifier) @definition.method
  value: [(arrow_function) (function_expression)])

; ---- Bindings --------------------------------------------------------------
(lexical_declaration "const" (variable_declarator name: (identifier) @definition.constant))
(lexical_declaration "let" (variable_declarator name: (identifier) @definition.variable))
(variable_declaration (variable_declarator name: (identifier) @definition.variable))
