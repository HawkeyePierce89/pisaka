import Foundation

/// What a folding region *is*, in the closed vocabulary this editor understands.
///
/// The three cases are the ones `textDocument/foldingRange` names in its own
/// `FoldingRangeKind` (`comment`, `imports`, `region`); the specification leaves
/// that field open, so a value outside this table is read as **absent** rather
/// than as a refusal — a region whose kind nothing named is still a region, and
/// nothing in part 1 branches on the kind at all. The fallback scanner never
/// names one: brackets and indentation say where a block is, never what it is.
public enum FoldRegionKind: String, Equatable, CaseIterable, Sendable {
    case comment
    case imports
    case region
}

/// One collapsible block, as the two facts every consumer of it needs: what the
/// editor hides when it is folded, and which line keeps the chevron.
///
/// **The hidden range starts at the end of the header line's *content* and ends
/// at the end of the last line's *content*.** So the first line stays visible in
/// full — including its trailing `{`, the thing that says a block follows — and
/// the block's last line joins it, closer and all, behind the placeholder. The
/// header's own separator is inside the hidden range, which is exactly what
/// makes the following text land on the header's line when the range is hidden.
///
/// UTF-16 offsets into the whole buffer, like every other editor engine here:
/// the buffer is never modified by folding, so an offset means the same thing
/// folded and unfolded.
///
/// **A region with an empty hidden range is not representable.** The
/// initializer refuses one, so "the gutter draws a chevron here" and "there is
/// something behind it to hide" are one fact rather than two that can disagree.
/// A negative offset or a negative header line is refused for the same reason:
/// there is no honest region to describe.
///
/// `Comparable` is the ordering key every producer sorts by — `headerLine`
/// ascending, then the **longer** region first, then the earlier one first so
/// the order is total. The longer-first tiebreak is what makes "the outermost
/// region on this line" the first of a header line's candidates, which is how
/// the merge rule picks between two brackets opening on one line.
public struct FoldRegion: Equatable, Hashable, Comparable, Sendable {
    /// What is hidden when this region is folded, in UTF-16 units. Never empty.
    public let hiddenRange: NSRange
    /// The zero-based index of the line that stays visible and carries the
    /// chevron — the line `hiddenRange.location` sits at the end of.
    public let headerLine: Int
    /// What the source called this block, when it called it anything.
    public let kind: FoldRegionKind?

    /// Refuses an empty hidden range, a negative offset and a negative header
    /// line; every other input is a region.
    public init?(hiddenRange: NSRange, headerLine: Int, kind: FoldRegionKind? = nil) {
        guard hiddenRange.length > 0, hiddenRange.location >= 0, headerLine >= 0 else { return nil }
        self.hiddenRange = hiddenRange
        self.headerLine = headerLine
        self.kind = kind
    }

    public static func < (lhs: FoldRegion, rhs: FoldRegion) -> Bool {
        if lhs.headerLine != rhs.headerLine { return lhs.headerLine < rhs.headerLine }
        if lhs.hiddenRange.length != rhs.hiddenRange.length { return lhs.hiddenRange.length > rhs.hiddenRange.length }
        return lhs.hiddenRange.location < rhs.hiddenRange.location
    }

    /// Every region in `regions` moved through one save's transform, dropping any
    /// whose remapped range comes out empty.
    ///
    /// **Both lists a fold owner holds go through this**: the folded state
    /// (``FoldState/remapped(through:)``) *and* the candidates a chevron is drawn
    /// from. The candidates are not optional bookkeeping — a save can move offsets
    /// under a list the next answer will not replace for another debounce, and a
    /// chevron clicked in that window would fold bounds computed against the
    /// pre-save text.
    ///
    /// Header lines are carried unchanged, for the reason stated on
    /// ``FoldState/remapped(through:)``: none of the three save transforms changes
    /// how many separators precede a given line.
    public static func remapped(_ regions: [FoldRegion], through plan: SaveTransformPlan) -> [FoldRegion] {
        guard !plan.isEmpty else { return regions }
        return regions.compactMap { region in
            FoldRegion(
                hiddenRange: plan.remappedRange(region.hiddenRange),
                headerLine: region.headerLine,
                kind: region.kind
            )
        }
    }
}
