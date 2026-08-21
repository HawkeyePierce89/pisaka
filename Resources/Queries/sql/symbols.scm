; SQL symbols query
;
; Kind mapping:
; - table, view, materialized view, custom type -> `type`
; - function -> `function`
; - column -> `property` (with the table as `@container`)
;
; Notes:
; - `create_function` needs the `.` anchor immediately after `(keyword_function)`
;   so it does not capture the return type as a function. The others must NOT
;   have one because `_if_not_exists` is a hidden rule whose `keyword_if`/etc
;   children inline as visible siblings, which would break the anchor.
; - `object_reference name:` captures the bare identifier, so `public.users`
;   indexes exactly as `users`.
; - `CREATE INDEX`, `CREATE SEQUENCE`, `CREATE TRIGGER`, `CREATE SCHEMA` and
;   `CREATE ROLE` are deliberately not indexed (they are not names anyone jumps
;   to, or the object_reference is the table which would create duplicates).

(create_table (object_reference name: (identifier) @definition.type))
(create_view (object_reference name: (identifier) @definition.type))
(create_materialized_view (object_reference name: (identifier) @definition.type))
(create_type (object_reference name: (identifier) @definition.type))
(create_function (keyword_function) . (object_reference name: (identifier) @definition.function))
(create_table
  (object_reference name: (identifier) @container)
  (column_definitions (column_definition name: (identifier) @definition.property)))
