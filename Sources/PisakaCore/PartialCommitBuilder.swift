import Foundation

/// Assembles the content a *partial* commit records for one file: the `HEAD`
/// version with only the selected changes applied. Pure and Foundation-only (the
/// `LineDiff`/`ThreeWayMerge` split — every decision here, the `Process` calls and
/// the temporary index in the view layer).
///
/// **The unit of selection is a `LineDiff.rows(old:new:)` index**, and the bytes
/// are taken through `TerminatedLines`, of which `LineDiff.splitLines` is a
/// projection — so the indices and the lines they name cannot drift apart. See
/// `CommitDiffUnits` for what counts as a unit.
///
/// **The separator rule, and it is one rule rather than several.** Every emitted
/// line carries the terminator *of the side it came from*: an unchanged line and
/// an unselected change are emitted from the old side verbatim, a selected change
/// from the new side verbatim. "The file lost (or gained) its final newline" is
/// not a special case but a value of that same rule — `TerminatedLines` gives an
/// unterminated final line an empty terminator, so it is carried like any other.
/// Nothing here ever invents, normalizes or drops a separator, because a commit
/// must not rewrite line endings the user did not select.
///
/// **The invariant: an empty selection reproduces the `HEAD` bytes identically.**
/// This is structural rather than incidental — `LineDiff` emits every old line
/// exactly once and in order (as `unchanged`, `removed`, or the left side of
/// `modified`), and with nothing selected each of those is emitted from the old
/// side verbatim, so the concatenation is `head` by `TerminatedLines`' round-trip
/// invariant. A file nobody checked is therefore committed exactly as it already
/// stands in `HEAD`.
///
/// **The one thing it does supply: a terminator no line can carry.** Only a
/// side's *final* line may be unterminated, so emitting it and then emitting
/// anything at all would fuse two lines into a third that exists on neither side
/// — `head` ending `"…\nb"` with `"c"` and `"d"` appended, `"c"` alone checked,
/// would assemble `"…\nbc\n"`, and `CommitPlan` routes a partial selection through
/// this function, so that line goes into history. Whenever more follows an
/// unterminated line the separator its *counterpart on the other side* carries is
/// inserted first (a plain `"\n"` when it has none), which is exactly the
/// separator the file gained by growing past that line. This never fires for an
/// empty selection — nothing is emitted after `head`'s last line — so the
/// invariant above is untouched.
///
/// **The converse is *not* an invariant, deliberately.** "Selecting every unit
/// yields the worktree bytes" holds only when every *unchanged* line is terminated
/// the same way on both sides. `LineDiff` compares terminator-stripped lines, so a
/// line whose separator alone switched (CRLF→LF, say) produces no changed row —
/// there is no unit for it, nothing to check — and the rule above emits it from
/// the old side with the old terminator. Under mixed endings the fully-selected
/// result therefore differs from the worktree, and that is correct: the builder
/// rewrites what was selected and nothing else. Where the stronger guarantee is
/// actually needed it is obtained *structurally* instead of from this function: a
/// fully checked file bypasses the builder entirely and is placed into the index
/// from the working file by git itself, which also resolves the exec bit, clean
/// filters and `core.autocrlf` (see `CommitPlan`).
public enum PartialCommitBuilder {
    /// Build the content to commit for one file.
    ///
    /// - Parameters:
    ///   - head: the file's `HEAD` text (empty for an untracked file).
    ///   - worktree: the file's working-tree text.
    ///   - rows: `LineDiff.rows(old: head, new: worktree)` — the same rows whose
    ///     indices the selection names.
    ///   - selectedUnits: the row indices the user checked. Indices naming no row,
    ///     or naming an `unchanged` row, are ignored rather than trapping: a
    ///     selection set can outlive a re-diff, and catching that is the staleness
    ///     check's job (`CommitStaleness`), not this function's — degrading here
    ///     must never mean crashing.
    /// - Returns: the assembled text, ready to be hashed into the temporary index.
    public static func assemble(
        head: String,
        worktree: String,
        rows: [DiffRow],
        selectedUnits: Set<Int>
    ) -> String {
        let headLines = TerminatedLines.split(head)
        let worktreeLines = TerminatedLines.split(worktree)

        // A row's line numbers are 1-based within their own side. A number naming
        // no line (which `LineDiff` never produces) contributes nothing.
        func oldLine(_ line: DiffLine?) -> TerminatedLine? {
            guard let line, line.number >= 1, line.number <= headLines.count else { return nil }
            return headLines[line.number - 1]
        }
        func newLine(_ line: DiffLine?) -> TerminatedLine? {
            guard let line, line.number >= 1, line.number <= worktreeLines.count else { return nil }
            return worktreeLines[line.number - 1]
        }

        var assembled = ""
        // Set after emitting a line that carries no terminator — only a side's
        // *final* line can — and flushed before anything else is emitted, so the
        // two never fuse into a line present on neither side. The separator is the
        // counterpart's, i.e. the one the other side gives that same line now that
        // it is no longer last; `"\n"` when there is no counterpart to ask.
        var pendingTerminator: String?

        func emit(_ line: TerminatedLine, counterpart: TerminatedLine?) {
            if let pending = pendingTerminator {
                assembled += pending
                pendingTerminator = nil
            }
            assembled += line.text
            guard line.terminator.isEmpty else { return }
            let borrowed = counterpart?.terminator ?? ""
            pendingTerminator = borrowed.isEmpty ? "\n" : borrowed
        }

        for (index, row) in rows.enumerated() {
            let isSelected = selectedUnits.contains(index)
            switch row.kind {
            case .unchanged:
                // Context: always the old side, so an unselected file is byte-identical
                // to HEAD even when the worktree re-terminated the line.
                if let line = oldLine(row.left) { emit(line, counterpart: newLine(row.right)) }
            case .removed:
                // Selected → the deletion is applied (nothing emitted); otherwise the
                // line survives exactly as HEAD has it.
                if !isSelected, let line = oldLine(row.left) { emit(line, counterpart: nil) }
            case .added:
                if isSelected, let line = newLine(row.right) { emit(line, counterpart: nil) }
            case .modified:
                if isSelected {
                    if let line = newLine(row.right) { emit(line, counterpart: oldLine(row.left)) }
                } else if let line = oldLine(row.left) {
                    emit(line, counterpart: newLine(row.right))
                }
            }
        }
        return assembled
    }
}
