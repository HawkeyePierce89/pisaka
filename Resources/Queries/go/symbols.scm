; Symbol declarations for Go (tree-sitter/tree-sitter-go).
;
; Convention, shared by every symbols.scm in this directory: the captured node
; is always the *name* node, and the capture name is the kind. An optional
; @container capture in the same match names the enclosing type.
;
; Four decisions this file makes, each of which reads as an oddity otherwise:
;
;  * **The pointer star is stripped by the grammar, not by us.** `*` is an
;    anonymous token inside `pointer_type`, so capturing the `type_identifier`
;    *inside* it yields `Worker`, not `*Worker` — the spelling the type itself is
;    indexed under, and therefore the only one `SymbolIntelligenceProvider`'s
;    receiver promotion (`index.declaresType(named:)`) can look up. That is why
;    the four receiver forms are four patterns rather than one alternation:
;    `[(type_identifier) (pointer_type …)] @container` would capture the
;    *pointer_type node* for the pointer case and put the star back.
;  * **Interface methods are methods with the interface as container**, so a
;    member completion after a value of interface type lists them. `method_elem`
;    is the 0.25.x node name — it was `method_spec` in older grammars, exactly the
;    kind of rename the hand-pinned node set in `SymbolQueryTests` exists to make
;    visible on a pin bump.
;  * **Consts and vars are anchored to `source_file`**, the JavaScript/TypeScript
;    reasoning verbatim: unanchored, `var_spec` matches every `var` inside every
;    function body and the index fills with locals. `var_spec_list` needs its own
;    pattern because a grouped `var ( … )` block nests one level deeper; a grouped
;    `const ( … )` does not.
;  * **The package clause is not indexed.** `package foo` repeats in every file of
;    a directory, so indexing it would put N identical `foo` symbols in the picker
;    for a name nobody jumps to.

; ---- Types -----------------------------------------------------------------
(type_declaration (type_spec name: (type_identifier) @definition.type))
(type_declaration (type_alias name: (type_identifier) @definition.type))

(type_spec
  name: (type_identifier) @container
  type: (struct_type
          (field_declaration_list
            (field_declaration name: (field_identifier) @definition.property))))

(type_spec
  name: (type_identifier) @container
  type: (interface_type (method_elem name: (field_identifier) @definition.method)))

; ---- Functions and methods -------------------------------------------------
(source_file (function_declaration name: (identifier) @definition.function))

(method_declaration
  receiver: (parameter_list (parameter_declaration type: (type_identifier) @container))
  name: (field_identifier) @definition.method)

(method_declaration
  receiver: (parameter_list (parameter_declaration type: (pointer_type (type_identifier) @container)))
  name: (field_identifier) @definition.method)

(method_declaration
  receiver: (parameter_list (parameter_declaration type: (generic_type type: (type_identifier) @container)))
  name: (field_identifier) @definition.method)

(method_declaration
  receiver: (parameter_list (parameter_declaration
                              type: (pointer_type (generic_type type: (type_identifier) @container))))
  name: (field_identifier) @definition.method)

; ---- Package-level bindings ------------------------------------------------
; The const pattern navigates by position where the var ones navigate by field,
; and that asymmetry is the grammar's, not a slip: `const_spec`'s `name` field is
; declared to hold the separating `,` tokens as well as the identifiers, and a
; field whose run of children is interrupted by an anonymous token yields only
; its first named child to `name: (identifier)`. `const A, B = 1, 2` would index
; `A` alone. Every direct `identifier` child of a `const_spec` *is* a declared
; name — the initializers live one level down, inside `value: (expression_list)`
; — so dropping the field is exact rather than merely broader. `var_spec`'s
; `name` field holds identifiers only and so keeps the field.
(source_file (const_declaration (const_spec (identifier) @definition.constant)))
(source_file (var_declaration (var_spec name: (identifier) @definition.variable)))
(source_file (var_declaration (var_spec_list (var_spec name: (identifier) @definition.variable))))
