; Symbol declarations for Make (tree-sitter-grammars/tree-sitter-make, vendored
; under Vendor/TreeSitterMake).
;
; Convention, shared by every symbols.scm in this directory: the captured node
; is always the *name* node, and the capture name is the kind. An optional
; @container capture in the same match names the enclosing type.
;
; Two decisions this file makes:
;
;  * **Special names and pattern targets are excluded by a predicate.**
;    `.PHONY`, `.SUFFIXES` and the other special targets, like the special
;    variables `.DEFAULT_GOAL` and `.RECIPEPREFIX`, are directives to make, not
;    names the user declared, and a pattern rule's `%.o` declares no name at
;    all — so they would only clutter ⌃⌘J. The filter lists GNU make's special
;    names exactly rather than their shape: an ordinary dot-led target
;    (`.venv`, `.BUILD`) is a real name and stays indexed. The `#not-match?` is what keeps them out,
;    which makes this the second symbols query that needs a predicate (HTML's
;    `id` filter is the first); `SymbolQueryTests` pins the exact set, and
;    `MakeSymbolQueryTests` executes the query to prove the predicate is
;    evaluated rather than merely present.
;  * **Variables are unanchored.** Make has no local scope: an assignment
;    nested under an `ifeq`/`ifdef` block (a `conditional` node) is as global
;    as one at the top, so anchoring at the root would silently drop every
;    conditionally defined variable. A target-specific assignment
;    (`test: CFLAGS += -g`) is a real definition site too and is indexed;
;    ⌃⌘J already lists several definitions of one name. `VPATH` is parsed
;    as a dedicated `VPATH_assignment` node whose name is an anonymous token,
;    so it needs a pattern of its own; it is indexed like `SHELL` or
;    `MAKEFLAGS`, which are ordinary `variable_assignment`s.

; ---- Rule targets ----------------------------------------------------------
; A `$(VAR):` target is a reference, not a `word`, and is not captured. The
; four patterns are disjoint on which prerequisite fields are present, so a
; target is captured at most once. Only the last — a rule with no
; prerequisites at all — drops suffix-shaped targets: GNU make records
; `.c.o: config.h` and `.s.o: | out` as explicit targets *and* suffix rules
; (both, outside `.POSIX`; explicit only, under it), and a static-pattern
; rule always applies to the targets it enumerates.
((rule (targets (word) @definition.target) target: (_))
 (#not-match? @definition.target "^[.](DEFAULT|DELETE_ON_ERROR|EXPORT_ALL_VARIABLES|IGNORE|INTERMEDIATE|LOW_RESOLUTION_TIME|NOTINTERMEDIATE|NOTPARALLEL|ONESHELL|PHONY|POSIX|PRECIOUS|SECONDARY|SECONDEXPANSION|SILENT|SUFFIXES|WAIT)$|%"))
((rule (targets (word) @definition.target) !target normal: (_))
 (#not-match? @definition.target "^[.](DEFAULT|DELETE_ON_ERROR|EXPORT_ALL_VARIABLES|IGNORE|INTERMEDIATE|LOW_RESOLUTION_TIME|NOTINTERMEDIATE|NOTPARALLEL|ONESHELL|PHONY|POSIX|PRECIOUS|SECONDARY|SECONDEXPANSION|SILENT|SUFFIXES|WAIT)$|%"))
((rule (targets (word) @definition.target) !target !normal order_only: (_))
 (#not-match? @definition.target "^[.](DEFAULT|DELETE_ON_ERROR|EXPORT_ALL_VARIABLES|IGNORE|INTERMEDIATE|LOW_RESOLUTION_TIME|NOTINTERMEDIATE|NOTPARALLEL|ONESHELL|PHONY|POSIX|PRECIOUS|SECONDARY|SECONDEXPANSION|SILENT|SUFFIXES|WAIT)$|%"))
((rule (targets (word) @definition.target) !target !normal !order_only)
 (#not-match? @definition.target "^[.](DEFAULT|DELETE_ON_ERROR|EXPORT_ALL_VARIABLES|IGNORE|INTERMEDIATE|LOW_RESOLUTION_TIME|NOTINTERMEDIATE|NOTPARALLEL|ONESHELL|PHONY|POSIX|PRECIOUS|SECONDARY|SECONDEXPANSION|SILENT|SUFFIXES|WAIT)$|^([.](out|a|ln|o|c|cc|C|cpp|p|f|F|m|r|y|l|ym|lm|s|S|mod|sym|def|h|info|dvi|tex|texinfo|texi|txinfo|w|ch|web|sh|elc|el)){1,2}$|%"))

; ---- Variables -------------------------------------------------------------
; Every form that can define a name is filtered alike: `.DEFAULT_GOAL != …`
; and `define .DEFAULT_GOAL` set the special variable as surely as `:=` does.
((variable_assignment name: (word) @definition.variable)
 (#not-match? @definition.variable "^[.](DEFAULT_GOAL|EXTRA_PREREQS|FEATURES|INCLUDE_DIRS|LIBPATTERNS|LOADED|RECIPEPREFIX|SHELLFLAGS|SHELLSTATUS|VARIABLES)$"))
((shell_assignment name: (word) @definition.variable)
 (#not-match? @definition.variable "^[.](DEFAULT_GOAL|EXTRA_PREREQS|FEATURES|INCLUDE_DIRS|LIBPATTERNS|LOADED|RECIPEPREFIX|SHELLFLAGS|SHELLSTATUS|VARIABLES)$"))
((define_directive name: (word) @definition.variable)
 (#not-match? @definition.variable "^[.](DEFAULT_GOAL|EXTRA_PREREQS|FEATURES|INCLUDE_DIRS|LIBPATTERNS|LOADED|RECIPEPREFIX|SHELLFLAGS|SHELLSTATUS|VARIABLES)$"))
(VPATH_assignment name: "VPATH" @definition.variable)
