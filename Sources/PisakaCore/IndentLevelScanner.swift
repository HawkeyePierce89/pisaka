import Foundation

/// One levelled block of a line's leading whitespace: the UTF-16 range it
/// covers and the zero-based indentation level it sits at.
///
/// `level` is *semantic*, not a palette index — the honest level of the column
/// the run started at, 7 staying 7 — exactly the split `BracketToken.depth`
/// draws between what Core answers and what a view colors. Levels may **skip**
/// (a single tab can cross several unit boundaries at once), which is not an
/// error: the column really did move that far.
public struct IndentLevelRun: Equatable {
    /// The whitespace this block covers, in UTF-16 units into the scanned text.
    /// Always non-empty.
    public let range: NSRange
    /// Zero-based indentation level, `column / unitWidth` at the column the run
    /// started at.
    public let level: Int

    public init(range: NSRange, level: Int) {
        self.range = range
        self.level = level
    }
}

/// The two column widths a levelled scan needs: how wide one indentation level
/// is, and how far a tab advances the column.
///
/// Both are answered by `IndentLevelScanner.widths(unit:statedTabWidth:)` from
/// what the editor has *already* decided, so no consumer re-derives either.
public struct IndentLevelWidths: Equatable {
    /// Columns per indentation level.
    public let unitWidth: Int
    /// The tab stop: a tab advances the column to the next multiple of this.
    public let tabWidth: Int

    public init(unitWidth: Int, tabWidth: Int) {
        self.unitWidth = unitWidth
        self.tabWidth = tabWidth
    }
}

/// Which parts of a text's leading whitespace are which indentation level —
/// the one answer behind the editor's indentation-level painting, so the view
/// layer decides nothing about levels.
///
/// Pure and Foundation-only like the editor's other engines (`IndentEngine`,
/// `BracketDepthScanner`), counting UTF-16 units over an `NSString` the caller
/// already holds. Nothing here knows what a color is.
///
/// **The rules it owns.**
///
/// - Leading whitespace is spaces and tabs only — the same two characters
///   `IndentEngine` already treats as indentation — and the walk stops at the
///   first character that is neither.
/// - A space advances the column by one; a tab advances it to the next multiple
///   of `tabWidth`.
/// - A run ends at the first character whose starting column crosses into a new
///   unit, and carries the level of the column it *started* at. So one tab is
///   always one block, even when it crosses several unit boundaries, and the
///   next run's level then skips.
/// - The whitespace left over when the line's content starts is emitted as one
///   more, shorter run at the next level — six spaces at a unit width of four
///   answer a full block at level 0 and a short one at level 1. There is no
///   error level and no special treatment of misalignment.
/// - A line with no leading whitespace, and an empty line, yield nothing; a
///   whitespace-only line is levelled like an indent of its own width, because
///   its content range holds only whitespace and the same walk answers it.
/// - Runs are **never clipped to the requested range**: a range starting or
///   ending mid-indent still answers those lines' whole, correctly levelled
///   runs (`TerminatedLines.ranges(in:range:)` expands to whole lines). A
///   painter clips by drawing.
/// - A `unitWidth` or `tabWidth` of zero or less answers no runs — never a
///   trap, never a loop.
public enum IndentLevelScanner {

    private static let space = unichar(UInt8(ascii: " "))
    private static let tab = unichar(UInt8(ascii: "\t"))

    /// The two widths, derived from what the editor already decided: the unit
    /// string `IndentUnitRule.unit(config:inferred:)` answered, and the
    /// configuration's `tab_width` (`EditorConfigProperties.tabWidth`, `nil`
    /// when unstated).
    ///
    /// - A **space** unit is as wide as its own spaces; a stated `tab_width`
    ///   never re-widens it, because the spaces are what is actually in the
    ///   file.
    /// - A **tab** unit is as wide as the stated `tab_width` and, when
    ///   unstated, as wide as `IndentUnitRule.defaultSpaceWidth` — read from
    ///   the rule rather than restated as a literal here, so this fallback and
    ///   Enter's cannot drift apart.
    /// - The tab stop is the stated `tab_width`, or the unit width when
    ///   unstated. That equality is what makes a tab-indented file with no
    ///   configuration paint exactly one block per tab.
    public static func widths(unit: String, statedTabWidth: Int?) -> IndentLevelWidths {
        let isSpaces = !unit.isEmpty && unit.allSatisfy { $0 == " " }
        let unitWidth = isSpaces
            ? (unit as NSString).length
            : (statedTabWidth ?? IndentUnitRule.defaultSpaceWidth)
        return IndentLevelWidths(unitWidth: unitWidth, tabWidth: statedTabWidth ?? unitWidth)
    }

    /// The levelled runs of every line `range` intersects, in ascending order.
    ///
    /// The lines come from `TerminatedLines.ranges(in:range:)`, so the editor's
    /// separator set (LF, CR, the CRLF pair as one, NEL, LS, PS) is applied
    /// here by *use* rather than by a second table, and only the lines the
    /// range touches are visited — a redraw never walks the whole file.
    public static func runs(
        in text: NSString,
        range: NSRange,
        widths: IndentLevelWidths
    ) -> [IndentLevelRun] {
        runs(in: text, range: range, unitWidth: widths.unitWidth, tabWidth: widths.tabWidth)
    }

    /// The same answer from the two widths spelled out.
    public static func runs(
        in text: NSString,
        range: NSRange,
        unitWidth: Int,
        tabWidth: Int
    ) -> [IndentLevelRun] {
        guard unitWidth > 0, tabWidth > 0 else { return [] }
        var runs: [IndentLevelRun] = []
        for line in TerminatedLines.ranges(in: text, range: range) {
            appendRuns(of: line.content, in: text, unitWidth: unitWidth, tabWidth: tabWidth, to: &runs)
        }
        return runs
    }

    // MARK: - The walk

    /// Walks one line's content and appends its levelled runs.
    ///
    /// `character(at:)` per unit is deliberate where `BracketDepthScanner`
    /// reads in chunks: this walk stops at the first non-indentation character,
    /// so it visits a line's indentation and never its body.
    private static func appendRuns(
        of content: NSRange,
        in text: NSString,
        unitWidth: Int,
        tabWidth: Int,
        to runs: inout [IndentLevelRun]
    ) {
        let end = NSMaxRange(content)
        var column = 0
        var runStart = content.location
        var runLevel = 0
        var index = content.location
        while index < end {
            let character = text.character(at: index)
            guard character == space || character == tab else { break }
            let level = column / unitWidth
            if level != runLevel {
                // This character starts a new unit, so the previous block ended
                // just before it. Its own level is the level of the column it
                // starts at — which is how a tab that crossed several
                // boundaries leaves a gap in the numbering rather than a lie.
                if index > runStart {
                    runs.append(IndentLevelRun(range: NSRange(location: runStart, length: index - runStart), level: runLevel))
                }
                runStart = index
                runLevel = level
            }
            column = character == tab ? (column / tabWidth + 1) * tabWidth : column + 1
            index += 1
        }
        // Whatever whitespace the line's content interrupted is the last,
        // possibly shorter, block.
        if index > runStart {
            runs.append(IndentLevelRun(range: NSRange(location: runStart, length: index - runStart), level: runLevel))
        }
    }
}
