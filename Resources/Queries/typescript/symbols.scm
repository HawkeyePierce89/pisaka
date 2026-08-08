; Symbol declarations for TypeScript (tree-sitter/tree-sitter-typescript).
;
; Convention, shared by every symbols.scm in this directory: the captured node
; is always the *name* node, and the capture name is the kind. An optional
; @container capture in the same match names the enclosing type.
;
; The TypeScript grammar is a superset of the JavaScript one and the editor
; parses `.ts`/`.tsx` with it alone, so this file repeats the JavaScript
; patterns rather than relying on composition — the same reason
; `SyntaxLanguageConfiguration.makeTypeScriptConfiguration` merges the two
; highlight queries. Keep the two files in step when either changes.
;
; `private_property_identifier` is the one captured node whose text is not just
; the name: the grammar spans the leading `#` (`#count`) and offers no inner node
; to capture instead. `SymbolExtractor` narrows that one code unit off both the
; text and the range, so the member is stored as `count` — the spelling
; `IdentifierScanner` resolves, and therefore the only one go-to-definition and
; completion can ever reach. See the `#` rule on `SymbolExtractor.name`.

; ---- Classes ---------------------------------------------------------------
(class_declaration name: (type_identifier) @definition.type)
(abstract_class_declaration name: (type_identifier) @definition.type)

(class_declaration
  name: (type_identifier) @container
  body: (class_body (method_definition
                      name: [(property_identifier) (private_property_identifier)] @definition.method)))

(class_declaration
  name: (type_identifier) @container
  body: (class_body (public_field_definition
                      name: [(property_identifier) (private_property_identifier)] @definition.property)))

(abstract_class_declaration
  name: (type_identifier) @container
  body: (class_body (method_definition
                      name: [(property_identifier) (private_property_identifier)] @definition.method)))

(abstract_class_declaration
  name: (type_identifier) @container
  body: (class_body (abstract_method_signature
                      name: [(property_identifier) (private_property_identifier)] @definition.method)))

(abstract_class_declaration
  name: (type_identifier) @container
  body: (class_body (public_field_definition
                      name: [(property_identifier) (private_property_identifier)] @definition.property)))

; ---- Types the language adds on top of JavaScript --------------------------
(interface_declaration name: (type_identifier) @definition.type)
(type_alias_declaration name: (type_identifier) @definition.type)
(enum_declaration name: (identifier) @definition.type)
; `namespace X {}` and `module "x" {}` — two node names for the same idea.
(internal_module name: [(identifier) (nested_identifier)] @definition.type)
(module name: (identifier) @definition.type)

(interface_declaration
  name: (type_identifier) @container
  body: (interface_body (property_signature name: (property_identifier) @definition.property)))

(interface_declaration
  name: (type_identifier) @container
  body: (interface_body (method_signature name: (property_identifier) @definition.method)))

(enum_declaration
  name: (identifier) @container
  body: (enum_body (property_identifier) @definition.constant))

(enum_declaration
  name: (identifier) @container
  body: (enum_body (enum_assignment name: (property_identifier) @definition.constant)))

; ---- Functions -------------------------------------------------------------
(function_declaration name: (identifier) @definition.function)
(generator_function_declaration name: (identifier) @definition.function)
(function_signature name: (identifier) @definition.function)

; An object literal's function-valued members read as methods.
(pair
  key: (property_identifier) @definition.method
  value: [(arrow_function) (function_expression)])

; ---- Bindings --------------------------------------------------------------
(lexical_declaration "const" (variable_declarator name: (identifier) @definition.constant))
(lexical_declaration "let" (variable_declarator name: (identifier) @definition.variable))
(variable_declaration (variable_declarator name: (identifier) @definition.variable))
