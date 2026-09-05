import Foundation

/// Pure incremental shift of a document's fold regions across a single text
/// edit, so a collapsed block stays collapsed over the code it was collapsed
/// over while the user types above it — instead of drifting onto the wrong lines
/// until the next scan lands, or springing open on every keystroke.
///
/// This is ``DiagnosticShift`` applied to fold regions, line for line and on
/// purpose: the two answer the same question about the same kind of value (a
/// UTF-16 span plus the line it is numbered by, maintained between two authored
/// answers), and a second, subtly different three-way test is exactly the kind
/// of divergence that produces one-off bugs in one of them only. So the rule
/// is the same rule:
///
/// - a region **entirely before** the edit is unchanged — its bounds and its
///   header line are untouched, byte for byte;
/// - a region **entirely after** the edit is shifted by `changeInLength` and its
///   header line renumbered from `newLineStarts`;
/// - a region whose hidden range **intersects** the touched span is dropped —
///   which, for the folded state, means that block unfolds.
///
/// Dropping is the honest answer for an intersecting region: the edit changed
/// the text the fold was hiding, so nobody knows any more where the block ends
/// until the scanner or the server says. Typing inside a folded block is only
/// possible through a reveal, which unfolds it first; typing on the header line
/// itself is the ordinary case this rule is written for, and it opens the block
/// rather than hiding the character just typed.
///
/// Foundation-only, and pure arithmetic over offsets and line-start tables — no
/// `NSString`, no content comparison — because the editor coordinator already
/// holds both tables at the moment of the edit (`LineStartIndex.updated(...)`
/// produces the new one from the old one), exactly as ``BlameShift`` and
/// ``DiagnosticShift`` do.
///
/// ## The touched span
///
/// With `loc = editedRange.location` and
/// `oldEnd = loc + editedRange.length - changeInLength` (the end of the replaced
/// region in **pre-edit** coordinates — `editedRange` is the edited span in the
/// *new* text, `NSTextStorage.editedRange`'s contract):
///
/// - "entirely before" is `region.end <= loc`;
/// - "entirely after" is `region.start >= oldEnd`;
/// - anything else intersects `[loc, oldEnd)` and is dropped.
///
/// Both comparisons are **half-open**, and the half-openness is load-bearing at
/// both edges, in the same way and for the same reason as the diagnostics': a
/// region ending exactly at `loc` covers only characters the edit did not touch,
/// and one starting exactly at `oldEnd` covers only characters the edit did not
/// remove. A hidden range starts at the end of its header line's content, so
/// typing anywhere on the header line — including at its very end, one character
/// before a `{`, the commonest edit there is — is an insertion at or before the
/// region's start: a pure insertion has `loc == oldEnd`, the region's start is
/// at or after it, and the block survives, shifted. That is the case this rule
/// is written for, and it is why the test is `>=` rather than `>`.
///
/// ## Renumbering
///
/// A shifted survivor's hidden range moves by `changeInLength` (both bounds),
/// and its header line is recomputed from `newLineStarts` — the table the caller
/// passes, so a survivor lands on the line the *editor* says it is on now, which
/// is what the gutter draws its chevron beside. The line is derived from the
/// shifted range's **start**, the offset at the end of the header line's
/// content, which is on the header line by construction. An untouched survivor
/// keeps its stored header line: nothing before `loc` moved, so re-deriving it
/// could only launder a divergence, not fix one.
///
/// Unlike the diagnostics', both numberings here are the **editor's own**
/// (`LineStartIndex`), never LSP's: a region arriving from
/// `textDocument/foldingRange` is mapped into buffer offsets and renumbered
/// against the editor's table before it ever reaches this function, so D1's
/// separator divergence is settled upstream and cannot reappear as a drifting
/// chevron.
///
/// ## Fallback
///
/// Any inconsistent input returns `[]` — the honest "nothing folded", never a
/// drifted set. Precisely, the checks are: a line-start array that is empty or
/// not anchored at `0` (either side); a negative `editedRange.location` or
/// `.length`; an `oldEnd` that comes out before `loc` or whose arithmetic
/// overflows (which a degenerate `NSNotFound`-sized range would); any single
/// region whose end offset or shifted bounds overflow; and a shifted region that
/// `FoldRegion`'s own initializer refuses. That last one is handled and
/// unreachable, deliberately: "entirely after" means
/// `start >= oldEnd = loc + length - delta`, so a shifted start is at least
/// `loc`, which the gate has already refused to let be negative — the failable
/// initializer is answered honestly rather than force-unwrapped on an argument
/// nobody re-derives at the call site. One bad entry poisons the whole answer on
/// purpose: everything folded springs open, the next scan re-offers every
/// chevron, and nothing is left hiding text at coordinates nobody can justify.
///
/// Note what is deliberately *not* checked, exactly as in ``DiagnosticShift``:
/// an edit lying wholly **past the end** of the previous text, or a survivor
/// landing past the new buffer's length. Line-start tables alone carry no buffer
/// length, so detecting either needs a further parameter for cases the only
/// caller cannot produce (`NSTextStorage.editedRange` is by construction in
/// range; the folded state is clamped to the buffer when it is restored). Such
/// input yields a shifted set, not the fallback — the reason this list is
/// spelled out rather than summarized as "out-of-range".
public enum FoldShift {
    /// Shift `regions` across one edit, given the line starts on both sides of
    /// it. `editedRange` is the edited span in the **new** text and
    /// `changeInLength` the signed length delta — exactly what `NSTextStorage`
    /// reports during `didProcessEditing`.
    ///
    /// `previousLineStarts` takes part in the consistency gate only: a region is
    /// never indexed *by* the table. It is a parameter nonetheless because the
    /// caller holds both tables at the moment of the edit, because requiring
    /// both keeps the three shifters' call sites interchangeable, and because a
    /// broken table on either side means the caller's bookkeeping is broken —
    /// the same honesty the rest of the fallback encodes.
    public static func updated(
        _ regions: [FoldRegion],
        previousLineStarts: [Int],
        newLineStarts: [Int],
        editedRange: NSRange,
        changeInLength delta: Int
    ) -> [FoldRegion] {
        guard previousLineStarts.first == 0,
              newLineStarts.first == 0,
              editedRange.location >= 0,
              editedRange.length >= 0
        else { return [] }

        let loc = editedRange.location
        // Pre-edit end of the replaced region, overflow-checked rather than
        // plain: a degenerate range (`NSNotFound`, i.e. `Int.max`) must fall to
        // the fallback, not trap.
        let (replacedEnd, endOverflowed) = loc.addingReportingOverflow(editedRange.length)
        guard !endOverflowed else { return [] }
        let (oldEnd, deltaOverflowed) = replacedEnd.subtractingReportingOverflow(delta)
        guard !deltaOverflowed, oldEnd >= loc else { return [] }

        var result: [FoldRegion] = []
        result.reserveCapacity(regions.count)
        for region in regions {
            let start = region.hiddenRange.location
            let (end, regionEndOverflowed) = start.addingReportingOverflow(region.hiddenRange.length)
            guard !regionEndOverflowed else { return [] }
            if end <= loc {
                result.append(region)
                continue
            }
            guard start < oldEnd else {
                let (newStart, startOverflowed) = start.addingReportingOverflow(delta)
                // The length never changes, but the shifted end must not
                // overflow either — a guard, not a used value.
                let (_, endShiftOverflowed) = end.addingReportingOverflow(delta)
                guard !startOverflowed, !endShiftOverflowed else { return [] }
                guard let shifted = FoldRegion(
                    hiddenRange: NSRange(location: newStart, length: region.hiddenRange.length),
                    headerLine: LSPPositionMap.lineIndex(containing: newStart, lineStarts: newLineStarts),
                    kind: region.kind
                ) else { return [] }
                result.append(shifted)
                continue
            }
            // Intersects the touched span: dropped, i.e. that block unfolds.
        }
        return result
    }

    /// The same rule applied to a whole ``FoldState``, which is what the editor
    /// actually holds: the surviving regions, re-normalized. A convenience over
    /// the array form and never a second rule — the coverage is derived from the
    /// regions, so there is nothing else to shift.
    public static func updated(
        _ state: FoldState,
        previousLineStarts: [Int],
        newLineStarts: [Int],
        editedRange: NSRange,
        changeInLength delta: Int
    ) -> FoldState {
        FoldState(regions: updated(
            state.regions,
            previousLineStarts: previousLineStarts,
            newLineStarts: newLineStarts,
            editedRange: editedRange,
            changeInLength: delta
        ))
    }
}
