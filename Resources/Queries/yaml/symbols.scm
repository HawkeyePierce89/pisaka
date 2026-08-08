; Symbol declarations for YAML (tree-sitter-grammars/tree-sitter-yaml).
;
; Convention, shared by every symbols.scm in this directory: the captured node
; is always the *name* node, and the capture name is the kind. An optional
; @container capture in the same match names the enclosing type.
;
; Only *top-level* keys are indexed: the pattern is anchored to
; `(document (block_node (block_mapping …)))`, so a nested mapping's keys — of
; which a CI config has hundreds, most of them repeated (`name`, `run`, `uses`)
; — never reach the index. Anchors are indexed too, because `*ref` is the one
; place a YAML file genuinely cross-references a name.

(document
  (block_node
    (block_mapping
      (block_mapping_pair key: (flow_node) @definition.key))))

(anchor (anchor_name) @definition.anchor)
