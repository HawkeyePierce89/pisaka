; Symbol declarations for Swift (alex-pinkus/tree-sitter-swift).
;
; Convention, shared by every symbols.scm in this directory: the captured node
; is always the *name* node, and the capture name is the kind. An optional
; @container capture in the same match names the enclosing type.
;
; Duplicate-free by construction: a `function_declaration` is captured either as
; a member of a type or as a top-level declaration, never by both, because the
; top-level patterns are anchored to `(source_file …)`.

; ---- Types -----------------------------------------------------------------
; `class_declaration` is the grammar's node for class/struct/enum/actor and
; `extension` alike — the keyword is its `declaration_kind` field.
(class_declaration name: (type_identifier) @definition.type)
(protocol_declaration name: (type_identifier) @definition.type)
(typealias_declaration name: (type_identifier) @definition.type)
(associatedtype_declaration name: (type_identifier) @definition.type)

; ---- Members of a type -----------------------------------------------------
; The body is spelled `(_ …)` because a struct/class uses `class_body` while an
; enum uses `enum_class_body`.
(class_declaration
  name: [(type_identifier) (user_type)] @container
  body: (_ (function_declaration name: (simple_identifier) @definition.method)))

(class_declaration
  name: [(type_identifier) (user_type)] @container
  body: (_ (init_declaration "init" @definition.method)))

(class_declaration
  name: [(type_identifier) (user_type)] @container
  body: (_ (property_declaration
             (value_binding_pattern "let")
             name: (pattern (simple_identifier) @definition.constant))))

(class_declaration
  name: [(type_identifier) (user_type)] @container
  body: (_ (property_declaration
             (value_binding_pattern "var")
             name: (pattern (simple_identifier) @definition.property))))

(class_declaration
  name: [(type_identifier) (user_type)] @container
  body: (enum_class_body (enum_entry (simple_identifier) @definition.constant)))

(protocol_declaration
  name: (type_identifier) @container
  (protocol_body (protocol_function_declaration name: (simple_identifier) @definition.method)))

(protocol_declaration
  name: (type_identifier) @container
  (protocol_body (protocol_property_declaration name: (pattern (simple_identifier) @definition.property))))

; ---- Top-level declarations ------------------------------------------------
(source_file (function_declaration name: (simple_identifier) @definition.function))

(source_file (property_declaration
               (value_binding_pattern "let")
               name: (pattern (simple_identifier) @definition.constant)))

(source_file (property_declaration
               (value_binding_pattern "var")
               name: (pattern (simple_identifier) @definition.variable)))
