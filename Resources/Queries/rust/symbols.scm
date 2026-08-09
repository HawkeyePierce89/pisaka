; Symbol declarations for Rust (tree-sitter/tree-sitter-rust).
;
; Convention, shared by every symbols.scm in this directory: the captured node
; is always the *name* node, and the capture name is the kind. An optional
; @container capture in the same match names the enclosing type.
;
; Six decisions this file makes, each of which reads as an oddity otherwise:
;
;  * **`impl Trait for Type` files under `Type`, not under `Trait`.** One rule
;    covers both impl forms and needs no second pattern, because `type:` is the
;    *self* type in `impl Type` and in `impl Trait for Type` alike (the trait
;    sits in the `trait:` field, which this query never navigates). It is also
;    the rule the rest of the stack already assumes:
;    `SymbolIntelligenceProvider`'s member branch answers "`.` after a value of
;    type `Worker`" by looking up members whose container is `Worker`, and a
;    `fmt` filed under `Display` would never surface there.
;  * **Generics are stripped by stepping through `generic_type`, not by editing
;    the text** — Go's pointer-star reasoning verbatim.
;    `[(type_identifier) (generic_type …)] @container` would capture the
;    *generic_type node* for the generic case and put `<T>` back, and `Worker<T>`
;    matches no declared type. So the self-type shapes get one pattern each.
;  * **`mod_item body:` is anchored beside `source_file`, while `impl` and
;    `trait` bodies are not** — all three hold a `declaration_list`, and naming
;    the parent is what tells them apart exactly. An inline `mod` is a
;    *namespace*, so a `fn`, `const` or `static` written there is as top-level as
;    one in the file; an `impl` or `trait` body is a *container*, whose functions
;    are methods and so reach the container patterns instead; a *function* body
;    holds locals, and is anchored out for the reason every other language's
;    bindings are — unanchored, a helper `fn` and a `const` inside every function
;    fill the picker with names nobody jumps to.
;  * **`const` is a constant, `static` is a variable.** A `static` is Rust's
;    global binding and `static mut` its mutable one — Go's package-level `var`,
;    and the same mapping.
;  * **Trait members need two patterns**, because a provided method (with a body)
;    is a `function_item` and a required one (a signature and a `;`) is a
;    `function_signature_item`. Both are methods of the trait.
;  * **Not indexed, deliberately:** `macro_rules!` definitions, associated
;    `const`s and associated types inside `impl`/`trait` bodies, `use` aliases,
;    tuple-struct positional fields (`ordered_field_declaration_list` declares no
;    names to capture), `union` fields, and `impl` blocks whose self type is a
;    reference, tuple, slice or `dyn` type. Each is a real declaration; none is a
;    name a reader jumps to often enough to pay for a pattern.

; ---- Types -----------------------------------------------------------------
; Unanchored: a type declaration means the same thing wherever it is written.
(struct_item name: (type_identifier) @definition.type)
(enum_item   name: (type_identifier) @definition.type)
(union_item  name: (type_identifier) @definition.type)
(trait_item  name: (type_identifier) @definition.type)
(type_item   name: (type_identifier) @definition.type)

; Struct fields are properties of their struct.
(struct_item
  name: (type_identifier) @container
  body: (field_declaration_list
          (field_declaration name: (field_identifier) @definition.property)))

; Enum variants are constants of their enum.
(enum_item
  name: (type_identifier) @container
  body: (enum_variant_list (enum_variant name: (identifier) @definition.constant)))

; ---- Functions and methods -------------------------------------------------
(source_file (function_item name: (identifier) @definition.function))
(mod_item body: (declaration_list (function_item name: (identifier) @definition.function)))

; Inherent and trait impls. `type:` binds the implementing type in both
; `impl Type` and `impl Trait for Type`; the generic wrapper and the module path
; are stepped through, so `impl<T> Worker<T>` and `impl foo::Bar` file under
; `Worker` and `Bar`.
(impl_item
  type: (type_identifier) @container
  body: (declaration_list (function_item name: (identifier) @definition.method)))

(impl_item
  type: (generic_type type: (type_identifier) @container)
  body: (declaration_list (function_item name: (identifier) @definition.method)))

(impl_item
  type: (scoped_type_identifier name: (type_identifier) @container)
  body: (declaration_list (function_item name: (identifier) @definition.method)))

; Trait members: provided methods are `function_item`, required ones
; `function_signature_item`.
(trait_item
  name: (type_identifier) @container
  body: (declaration_list (function_item name: (identifier) @definition.method)))

(trait_item
  name: (type_identifier) @container
  body: (declaration_list (function_signature_item name: (identifier) @definition.method)))

; ---- Top-level bindings ----------------------------------------------------
(source_file (const_item name: (identifier) @definition.constant))
(source_file (static_item name: (identifier) @definition.variable))
(mod_item body: (declaration_list (const_item name: (identifier) @definition.constant)))
(mod_item body: (declaration_list (static_item name: (identifier) @definition.variable)))
