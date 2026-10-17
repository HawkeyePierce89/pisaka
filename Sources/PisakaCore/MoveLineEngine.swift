import Foundation

/// Which way Move Line carries a block.
public enum MoveLineDirection: Equatable, Sendable {
    case up
    case down
}

/// Move Line's whole answer: the text edit, and the folded state to install
/// once that edit has been applied.
///
/// `edit`'s selections move with the text they selected. `folds` is the
/// **complete** state against the resulting text: every folded region inside a
/// moved block or its neighbour translated by that part's displacement, with
/// its header line renumbered, and every other region unchanged. The app
/// applies `edit` — which runs the ordinary fold shift rule — and then installs
/// `folds` whole, so a fold is never revealed by a move and never left pointing
/// at text that moved out from under it.
public struct MoveLinePlan: Equatable {
    public let edit: RangeEditPlan
    public let folds: FoldState

    public init(edit: RangeEditPlan, folds: FoldState) {
        self.edit = edit
        self.folds = folds
    }
}

/// Pure Move Line Up / Down: swaps each block of touched lines with the line —
/// or the folded region — beside it.
///
/// **Blocks.** The touched lines of every range follow `BlockIndentEngine`'s
/// rule (a non-empty range ending exactly at a line start does not touch that
/// line); adjacent or overlapping line sets merge into one block. A block then
/// grows to cover every folded region it touches — a folded region being its
/// header line plus every line its hidden range reaches — so a fold moves as one
/// unit and is never split.
///
/// **Neighbour.** The line just above (up) or below (down) the block, or the
/// whole folded region when that line belongs to one, so a folded block is
/// swapped past in one press. Each block is swapped with its neighbour as one
/// replacement over the pair's span; blocks are never adjacent after merging and
/// a neighbour always lies between them, so the pairs never overlap and the
/// whole command is one plan.
///
/// **No-op.** `nil` — nothing to apply and nothing to undo — when any block
/// already sits on the first line (up) or the last line (down), when the text is
/// empty, or when a caret sits on the phantom empty line after a final
/// separator, which has no text to carry.
///
/// **Terminators.** Every line keeps its own terminator. The one exception is a
/// text with no final separator, when the swap changes which line is last: the
/// line becoming last gives up its terminator to the line leaving the last
/// position. The line count and the final-terminator state are therefore
/// preserved, nothing is merged, lost or duplicated, and a pair's replacement
/// is exactly as long as the span it replaces.
///
/// Lines are split through `TerminatedLines`, so LF, CR, CRLF, NEL, LS and PS
/// all delimit a line.
public enum MoveLineEngine {
    public static func move(
        text: NSString,
        ranges: [NSRange],
        direction: MoveLineDirection,
        folds: FoldState
    ) -> MoveLinePlan? {
        let lines = TerminatedLines.ranges(in: text, range: NSRange(location: 0, length: text.length))
        guard !lines.isEmpty, !ranges.isEmpty else { return nil }
        let model = Lines(text: text, lines: lines)

        var touched: [ClosedRange<Int>] = []
        for range in ranges {
            let clamped = clamp(range, length: text.length)
            let first = model.index(of: clamped.location)
            guard first < lines.count else { return nil }
            var last = model.index(of: NSMaxRange(clamped))
            if clamped.length > 0, last > first, NSMaxRange(clamped) == model.start(of: last) {
                last -= 1
            }
            touched.append(first...min(max(first, last), lines.count - 1))
        }

        let units = foldUnits(folds, model: model)
        let blocks = grown(merged(touched), by: units)

        var pairs: [Pair] = []
        for block in blocks {
            let neighbour: ClosedRange<Int>
            switch direction {
            case .up:
                guard block.lowerBound > 0 else { return nil }
                neighbour = unit(containing: block.lowerBound - 1, in: units)
                pairs.append(Pair(upper: neighbour, lower: block, blockIsUpper: false))
            case .down:
                guard block.upperBound < lines.count - 1 else { return nil }
                neighbour = unit(containing: block.upperBound + 1, in: units)
                pairs.append(Pair(upper: block, lower: neighbour, blockIsUpper: true))
            }
        }

        var edits: [IndentReplacement] = []
        var swaps: [Swap] = []
        for pair in pairs {
            let swap = model.swap(pair)
            swaps.append(swap)
            edits.append(IndentReplacement(range: swap.span, replacement: swap.replacement))
        }

        let selections = ranges.map { range -> NSRange in
            let clamped = clamp(range, length: text.length)
            guard let swap = swaps.first(where: { $0.blockContains(clamped.location) }) else { return clamped }
            let start = swap.mappedBlockOffset(clamped.location)
            let end = swap.mappedBlockOffset(NSMaxRange(clamped))
            return NSRange(location: start, length: max(0, end - start))
        }
        guard let edit = RangeEditPlan(edits: edits, selections: selections) else { return nil }

        let regions = folds.regions.compactMap { region -> FoldRegion? in
            let hidden = region.hiddenRange
            guard let swap = swaps.first(where: {
                hidden.location < NSMaxRange($0.span) && NSMaxRange(hidden) > $0.span.location
            }) else { return region }
            // By construction every folded region a pair reaches lies wholly
            // inside the block or the neighbour; a region straddling a pair's
            // edge is unreachable, and is dropped rather than left on text that
            // moved.
            return swap.translated(region)
        }
        return MoveLinePlan(edit: edit, folds: FoldState(regions: regions))
    }

    // MARK: - Blocks and units

    /// Each folded region as the closed line span it occupies, merged so nested
    /// and overlapping regions form one maximal unit.
    private static func foldUnits(_ folds: FoldState, model: Lines) -> [ClosedRange<Int>] {
        let spans = folds.regions.compactMap { region -> ClosedRange<Int>? in
            guard region.headerLine < model.count else { return nil }
            let last = min(model.index(of: NSMaxRange(region.hiddenRange)), model.count - 1)
            return region.headerLine...max(region.headerLine, last)
        }
        return merged(spans, joiningAdjacent: false)
    }

    private static func merged(
        _ spans: [ClosedRange<Int>],
        joiningAdjacent: Bool = true
    ) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let reach = joiningAdjacent ? 1 : 0
            if let last = result.last, span.lowerBound <= last.upperBound + reach {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// Grow every block over the fold units it touches, re-merging until no
    /// block touches a unit it does not cover.
    private static func grown(_ blocks: [ClosedRange<Int>], by units: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        var current = blocks
        while true {
            let next = merged(current.map { block in
                units.reduce(block) { block, unit in
                    unit.overlaps(block)
                        ? min(block.lowerBound, unit.lowerBound)...max(block.upperBound, unit.upperBound)
                        : block
                }
            })
            if next == current { return current }
            current = next
        }
    }

    private static func unit(containing line: Int, in units: [ClosedRange<Int>]) -> ClosedRange<Int> {
        units.first { $0.contains(line) } ?? line...line
    }

    private static func clamp(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        return NSRange(location: location, length: min(max(range.length, 0), length - location))
    }

    // MARK: - Swapping

    /// Two consecutive line spans to be exchanged; `blockIsUpper` says which of
    /// the two is the block being moved.
    private struct Pair {
        let upper: ClosedRange<Int>
        let lower: ClosedRange<Int>
        let blockIsUpper: Bool
    }

    /// One pair's replacement, and how its two parts moved.
    private struct Swap {
        let span: NSRange
        let replacement: String
        /// The block's original span and its new start and length.
        let block: NSRange
        let newBlockStart: Int
        let newBlockLength: Int
        /// Header-line and offset displacement of each part.
        let upper: NSRange
        let upperLineShift: Int
        let upperOffsetShift: Int
        let lowerLineShift: Int
        let lowerOffsetShift: Int

        func blockContains(_ offset: Int) -> Bool {
            offset >= block.location && offset <= NSMaxRange(block)
        }

        /// An offset inside the block (its end included) moved with the block,
        /// clamped to the block's new length — which differs only by a
        /// terminator handed over at the end of a file.
        func mappedBlockOffset(_ offset: Int) -> Int {
            newBlockStart + min(max(0, offset - block.location), newBlockLength)
        }

        /// A folded region inside the pair, moved with its part. A hidden range
        /// ends at its last line's content end, so a terminator handed over
        /// never falls inside it.
        func translated(_ region: FoldRegion) -> FoldRegion? {
            let hidden = region.hiddenRange
            guard hidden.location >= span.location, NSMaxRange(hidden) <= NSMaxRange(span) else { return nil }
            let inUpper = hidden.location < NSMaxRange(upper)
            let offsetShift = inUpper ? upperOffsetShift : lowerOffsetShift
            let lineShift = inUpper ? upperLineShift : lowerLineShift
            return FoldRegion(
                hiddenRange: NSRange(location: hidden.location + offsetShift, length: hidden.length),
                headerLine: region.headerLine + lineShift,
                kind: region.kind
            )
        }
    }

    private struct Lines {
        let text: NSString
        let lines: [TerminatedLineRange]

        var count: Int { lines.count }

        func start(of line: Int) -> Int {
            line < lines.count ? lines[line].enclosing.location : text.length
        }

        /// The line holding `offset`. An offset at the end of a text that ends
        /// in a separator answers `count` — the phantom empty line.
        func index(of offset: Int) -> Int {
            var low = 0
            var high = lines.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if lines[mid].enclosing.location <= offset {
                    low = mid
                } else {
                    high = mid - 1
                }
            }
            if offset >= NSMaxRange(lines[low].enclosing), lines[low].terminator.length > 0 {
                return low + 1
            }
            return low
        }

        func span(of lineSpan: ClosedRange<Int>) -> NSRange {
            let start = lines[lineSpan.lowerBound].enclosing.location
            return NSRange(location: start, length: NSMaxRange(lines[lineSpan.upperBound].enclosing) - start)
        }

        func swap(_ pair: Pair) -> Swap {
            let upperSpan = span(of: pair.upper)
            let lowerSpan = span(of: pair.lower)
            var upperText = text.substring(with: upperSpan)
            var lowerText = text.substring(with: lowerSpan)
            let lastLine = lines[pair.lower.upperBound]
            if lastLine.terminator.length == 0 {
                // The lower part's last line is the file's unterminated last
                // line, and the upper part's last line is about to become last:
                // it hands its terminator over.
                let handed = lines[pair.upper.upperBound].terminator
                upperText = (upperText as NSString).substring(to: upperSpan.length - handed.length)
                lowerText += text.substring(with: handed)
            }
            let span = NSRange(location: upperSpan.location, length: upperSpan.length + lowerSpan.length)
            let lowerLength = (lowerText as NSString).length
            let upperLength = (upperText as NSString).length
            let upperLines = pair.upper.count
            let lowerLines = pair.lower.count
            return Swap(
                span: span,
                replacement: lowerText + upperText,
                block: pair.blockIsUpper ? upperSpan : lowerSpan,
                newBlockStart: pair.blockIsUpper ? span.location + lowerLength : span.location,
                newBlockLength: pair.blockIsUpper ? upperLength : lowerLength,
                upper: upperSpan,
                upperLineShift: lowerLines,
                upperOffsetShift: lowerLength,
                lowerLineShift: -upperLines,
                lowerOffsetShift: span.location - lowerSpan.location
            )
        }
    }
}
