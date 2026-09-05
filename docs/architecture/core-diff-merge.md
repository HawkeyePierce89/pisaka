# PisakaCore — diff & three-way merge

Design documentation moved verbatim from the root `CLAUDE.md` (which now holds only a one-line-per-file index). Each entry records a file's contract, invariants and the reasoning behind non-obvious decisions — read the relevant entry before modifying that file, and update it when behavior changes.

  - `MergeRegion.swift` — pure value types for the 3-pane conflict resolver
    (Foundation-only, color/UI-free). `ConflictHunk` (`Equatable`): the `base`,
    `ours`, `theirs` line spans of one base region (each `[String]` logical lines,
    an empty array for a missing/empty side — `base == []` is add/add with no
    common ancestor, `ours == []`/`theirs == []` is modify/delete). `MergeRegion`
    (`Equatable`): `.stable([String])` (identical in all three, changed by only
    one side, or changed identically by both — final lines verbatim) and
    `.conflict(ConflictHunk)` (a span both sides changed differently).
  - `ThreeWayMerge.swift` — pure, testable diff3 three-way merge: `static func
    regions(base:ours:theirs:) -> [MergeRegion]`. Splits all three texts into
    logical lines with the same separators as `LineDiff.splitLines`, builds a
    base→ours and a base→theirs `LineDiff` (`matchedPairs`/`matchedPairs`-derived
    `SideHunk`s in base coordinates), sorts the two sides' hunks by base position,
    and walks them together: emitting `.stable` where both sides agree or only one
    changed (and reconciling false conflicts — identical edits, or one side equal
    to base — to stable), `.conflict` only where both sides changed the same base
    span differently, coalescing adjacent stable lines. Hunks are grouped into one
    region only on *strict* base-coordinate overlap (`next.oStart < regionOEnd`): two
    changes that merely *abut* (ours edits line b, theirs edits the following line c)
    are independent and auto-merge rather than collapsing into a spurious both-sides
    conflict. The sole exception is two pure insertions at the *same* base gap (each
    zero base length at the same point — add/add over an empty base), grouped as a
    genuine conflict. add/add (empty base) and
    modify/delete (one empty side) fall out as conflicts whose corresponding span
    is empty — handled, not special-cased. Foundation-only, unit-tested like
    `LineDiff`/`MinimapModel`.
  - `MergeDocument.swift` — the editable state of a three-way merge (Foundation-
    only, `Equatable`). `Resolution` (`Equatable`): `.unresolved` (initial, blocks
    apply), `.ours`, `.theirs`, `.bothOursFirst`/`.bothTheirsFirst` (concatenate
    both sides in the chosen order), `.custom(String)` (the user's edited span,
    split into logical lines on assembly). `MergeDocument` holds the ordered
    `[MergeRegion]` plus a private per-conflict `[Resolution]` (in conflict order,
    one per `.conflict` region, seeded `.unresolved`) and a `trailingNewline` flag.
    `resolvedText` reassembles the document — stable regions verbatim, each
    conflict's chosen content (an *unresolved* conflict emits git-style
    `<<<<<<< ours` / `=======` / `>>>>>>> theirs` markers so a partial result stays
    faithful and visibly unresolved), logical lines joined with `\n`, a trailing
    `\n` appended iff `trailingNewline` and non-empty so apply writes faithful
    bytes. Also `conflictCount`, `resolutions`, `resolution(at:)`,
    `unresolvedCount`, `isFullyResolved`, and `setResolution(_:at:)` (an
    out-of-range index is ignored so a stale view index can't trap). The
    `resolution → [String]` mapping is exposed as `public static
    resolvedLines(for:resolution:)` so `MergeView`'s result-pane builder reuses the
    exact marker text and ordering instead of mirroring it.
  - `MergeModel.swift` — `@MainActor ObservableObject` for the 3-pane merge editor,
    mirroring `LocalChangesModel`'s shape: injects `GitServicing` (read the merge
    index stages + stage the result) and `FileServicing` (write the resolved
    working file) so the real `Process`-backed service runs in `Pisaka` and stubs
    in tests; pure Foundation. Publishes `document` (read-only — mutated only via
    `load`/`accept`), `errorMessage`, `file`, `root`, plus computed
    `isFullyResolved`/`unresolvedCount`. `load(file:root:)` reads the `:1`/`:2`/`:3`
    blobs off-main (a missing stage → `nil` → empty content, so `ThreeWayMerge`
    represents add/add and modify/delete as a conflict with an empty span) and
    builds a `MergeDocument`, deciding `trailingNewline` from the resolved sides in
    preference order (ours, then theirs, then base; default `true`); a read failure
    clears the document and sets `errorMessage`. If *both* the ours (`:2`) and
    theirs (`:3`) stages are absent the file is not actually in a merge conflict (a
    stale Local Changes snapshot, or a delete/delete git already resolved): `load`
    refuses — clears the document, sets `errorMessage` — rather than building a
    zero-conflict, trivially "fully resolved" empty document whose Apply would write
    `""` over a good file. It also records `deletedSide` (for a modify/delete — base
    present and exactly one of ours/theirs absent — *which* side is the absent/deleted
    one, `.ours` or `.theirs`; `nil` otherwise). `accept(_:at:)`
    sets a conflict's resolution (no-op when no document / out of range). `apply()`
    refuses (sets `errorMessage`, writes nothing) while unresolved, else applies the
    resolution: a modify/delete the user resolved *to the deleted side* stages a
    *deletion* via `GitServicing.stageRemoval` (`git rm -f`) rather than writing an
    empty file. The deletion decision (private `deletionChosen(in:)`) keys off
    *which resolution was selected* — every conflict resolved to the absent side
    (`.ours` when ours was deleted, `.theirs` when theirs was) on a document with at
    least one conflict — **not** the output bytes: an empty `resolvedText` that comes
    from a modified side that is itself empty, a `.custom` resolution edited down to
    empty, or a degenerate zero-conflict modify/delete (both sides emptied to the
    same content) is an empty-*file* result the user chose to keep, so it writes +
    stages an empty tracked file rather than deleting. Any other resolution writes
    `resolvedText` via `FileServicing.write` and stages via `GitServicing.stage`; it
    surfaces a write/stage failure without a half-applied success claim and returns
    `true` only on a clean apply.
  - `LineDiff.swift` — pure, testable side-by-side line diff. `DiffRowKind`
    (`unchanged, added, removed, modified` — color-free like `FileStatus`),
    `DiffLine` (1-based `number` + separator-stripped `text`), `DiffRow` (`kind`
    plus optional `left`/`right`; a `nil` side is a filler keeping the panes
    aligned, so `.added`→`left==nil`, `.removed`→`right==nil`,
    `.unchanged`/`.modified`→both present), and `enum LineDiff { static func
    rows(old:new:) -> [DiffRow] }`. Splits both texts into logical lines with the
    same Unicode separators as the editor (see `LineStartIndex`), strips the
    common leading/trailing lines (so a small edit in a large file diffs only the
    changed middle), runs a classic LCS diff over that middle (a single flat
    `(k+1)*(l+1)` `Int` buffer), and pairs deletes+inserts inside one hunk into
    `.modified` rows (so a one-line edit shows as a single aligned row) before any
    leftover removed/added rows. The LCS matrix is capped (`maxMatrixCells`); a
    pathologically large fully-divergent middle skips the quadratic matrix and
    falls back to a plain replace, so memory and main-thread time stay bounded
    even for huge files. No word-level intra-line ranges (the optional refinement
    was deferred). Foundation-only. `splitLines` is **not** an independent
    splitter: it is a one-line *projection* of `TerminatedLines.split` (see the
    next entry), because the commit dialog indexes one splitter's output with the
    other's indices.
  - `TerminatedLines.swift` — the single line representation shared by the diff
    and the partial-commit builder (Foundation-only). `TerminatedLine`
    (`content` — the separator-stripped text a `DiffRow` compares — plus
    `terminator`, the separator verbatim: `"\n"`, `"\r"`, `"\r\n"` as *one*,
    NEL, LS, PS, or `""` for an unterminated final line) and `enum
    TerminatedLines { static func split(_:) -> [TerminatedLine] }`, implemented
    over `NSString.enumerateSubstrings(.byLines)` with the terminator taken as
    the enclosing-range-minus-substring-range *difference* — so the CRLF pair
    stays intact with no separator table of its own, and the separator set is
    identical to `LineStartIndex`'s. **Why it exists:** a partial commit
    assembles a file out of lines from two sides and must emit them verbatim,
    terminators included, or a commit would silently rewrite line endings nobody
    selected; the diff, meanwhile, compares lines *stripped*, and a selection
    unit is an index into `LineDiff.rows`. So the builder indexes one splitter's
    output with another splitter's indices, and a disagreement on even one
    separator would assemble the wrong lines with no error anywhere. Hence one
    implementation rather than two: `LineDiff.splitLines` is
    `split(text).map(\.content)`, so the consistency is *structural*, and
    `TerminatedLinesTests` additionally fuzzes the two against each other (a
    deterministic LCG over mixtures of every separator). That fuzz test was
    written and run against the **old, independent** `splitLines` — where it
    pinned the refactor — and is now a tautology by construction; its documented
    role today is a **lock against a second independent implementation coming
    back**, which is stated in a comment in the test itself. The structural
    invariant everything else rests on: concatenating every `content +
    terminator` reproduces the input identically (so `"a\n"` and `"a"` both split
    to one line, differing only in its terminator, and a trailing separator adds
    no phantom empty line). The **same reasoning one level down** makes
    `ranges(_:) -> [TerminatedLineRange]` — the split as offsets (`content`,
    `terminator`, and `enclosing` for the two together, the CRLF pair still one
    range) — the primitive, with `split(_:)` projecting it: the save transform
    *edits* lines and would otherwise re-derive offsets by measuring the
    substrings it was handed, which is a second definition of what a line is by
    another name. And **one level down again**: the offsets themselves are
    answered by the *bounded* `ranges(in:range:) -> [TerminatedLineRange]`, of
    which the whole-text `ranges(_:)` is simply the full-range call — so
    `ranges(in:range:)` is *the* primitive the other two project from, and there
    is still exactly one traversal that decides where a line ends. Bounding it is
    what makes it the primitive rather than a convenience: a consumer that only
    cares about the lines it is *drawing* (`IndentLevelScanner`, painting the
    editor's indentation levels on every redraw) must not pay for a traversal of
    the whole file, and paying for one in a second implementation of "where does
    a line end" would be worse still. The bounded form **expands `range` to whole
    lines before anything is enumerated**, through `NSString.lineRange(for:)`, so
    a range starting or ending mid-line answers those lines whole rather than a
    fragment of one, and nothing is clipped on the way out either — a caller
    asking about a drawn region gets lines it can reason about without knowing
    where it cut. `range` is clamped to the text first, so an out-of-bounds or
    negative request is *answered* rather than trapping, and only the expanded
    span is ever enumerated. `TerminatedLinesTests` fuzzes the `split(_:)`
    projection and pins the bounded form against the whole-text one (same answer
    over the full range; whole lines for a mid-line range). Its consumers'
    reasoning is in `core-editorconfig.md` (`SaveTransform`) and
    `core-editor.md` (`IndentLevelScanner`).
  - `ChangeTree.swift` — pure directory-tree grouping for the by-folder mode of
    the Local Changes view. `ChangeNode` (a uniform node: `name`, repo-relative
    `path` as identity, absolute `url` = `root` + `path` for the view's
    `FileIcon(for:)`, a `file` for a leaf / `nil` for a directory, and `children`
    `nil` for a leaf so the SwiftUI tree recurses like `DirectoryNodeView`) and
    `enum ChangeTree { static func build(from: [ChangedFile], root: URL) ->
    [ChangeNode] }`. Root-level files stay flat at the top; at every level
    directories come first then files, each sorted case-insensitively (mirroring
    `FileService`/`DirectoryEntry`). Foundation-only, fully unit-tested.
