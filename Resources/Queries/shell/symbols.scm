; Symbol declarations for shell (tree-sitter/tree-sitter-bash).
;
; Convention, shared by every symbols.scm in this directory: the captured node
; is always the *name* node, and the capture name is the kind. An optional
; @container capture in the same match names the enclosing type.
;
; Two decisions this file makes, each of which reads as an asymmetry otherwise:
;
;  * **Functions are unanchored, variables are anchored.** A shell function is
;    global wherever its definition runs — nesting one inside another, or inside
;    an `if`, does not scope it — so `function_definition` is matched at any
;    depth. An assignment is the opposite: one inside a function body or a loop
;    is almost always a local or a counter, so the three assignment patterns
;    hang off `(program …)`. That is Python's and Go's anchoring, for the same
;    reason: unanchored, the index fills with locals.
;  * **The name is captured as `(variable_name)` specifically**, not by field
;    alone. `variable_assignment`'s `name:` field admits `variable_name` *or*
;    `subscript`, and `arr[2]=x` declares nothing new — naming the node is what
;    skips the subscript form.
;
; A bare `export PATH` inside a `declaration_command` is deliberately **not**
; captured: it names a variable bound elsewhere, so indexing it would file a
; definition at a line that defines nothing. Only the assigning form
; (`readonly ROOT=/srv`) is matched, through the nested `variable_assignment`.

; ---- Functions -------------------------------------------------------------
(function_definition name: (word) @definition.function)

; ---- Top-level variable bindings -------------------------------------------
(program (variable_assignment name: (variable_name) @definition.variable))

; `A=1 B=2` on one line nests one level deeper.
(program (variable_assignments
           (variable_assignment name: (variable_name) @definition.variable)))

; `declare -r ROOT=/srv`, `readonly ROOT=/srv`, `export TAG=v1`.
(program (declaration_command
           (variable_assignment name: (variable_name) @definition.variable)))
