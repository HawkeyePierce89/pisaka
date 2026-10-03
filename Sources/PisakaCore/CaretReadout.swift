import Foundation

/// The bottom bar's caret readout: `Ln <line>, Col <column> · <encoding> · <language>`.
///
/// Pure, so every counting rule is pinned here rather than in the bar:
/// - the line is 1-based, split by `LineStartIndex` — all six separators,
///   the CRLF pair counting once — so it agrees with the gutter's numbers;
/// - the column is 1-based and counts grapheme clusters (Swift `Character`s)
///   from the line start to the caret, so an emoji or a letter carrying a
///   combining mark is one column and a tab is one column too;
/// - a file with no `SyntaxLanguage` reads `Plain Text`;
/// - an offset outside the text clamps into it, so a stale offset published
///   for a buffer that has since shrunk still reads a real position.
public enum CaretReadout {
    /// What the readout calls a file no language claims.
    public static let plainTextName = "Plain Text"

    /// The readout for a caret at UTF-16 `caretOffset` in `text`, indexing the
    /// whole text. The editor asks
    /// `position(text:caretOffset:lineStarts:memo:editFloor:)` with the gutter's
    /// own table instead, and formats that with
    /// `text(position:language:encodingName:)`.
    public static func text(
        text: NSString,
        caretOffset: Int,
        language: SyntaxLanguage?,
        encodingName: String
    ) -> String {
        self.text(position: position(text: text, caretOffset: caretOffset), language: language, encodingName: encodingName)
    }

    /// The readout for an already-computed 1-based line and column.
    public static func text(
        position: (line: Int, column: Int),
        language: SyntaxLanguage?,
        encodingName: String
    ) -> String {
        let languageName = language?.displayName ?? plainTextName
        return "Ln \(position.line), Col \(position.column) · \(encodingName) · \(languageName)"
    }

    /// The 1-based line and column of `caretOffset`, clamped into `text`.
    ///
    /// `lineStarts` is `LineStartIndex.offsets(in:)`'s table of the whole text —
    /// the editor passes the gutter's, which it keeps incrementally — so the line
    /// is a binary search and the column counts the caret's own line from its
    /// start — the full count, which the memoised overload below avoids on most
    /// caret moves and falls back to otherwise. A caret between a CR and
    /// its LF needs no special case, since the whole text's table opens no line
    /// inside the pair. A stale table cannot read outside the text: the line
    /// start used is never past the clamped caret.
    public static func position(text: NSString, caretOffset: Int, lineStarts: [Int]) -> (line: Int, column: Int) {
        let caret = min(max(0, caretOffset), text.length)
        guard !lineStarts.isEmpty else {
            return (1, text.substring(to: caret).count + 1)
        }
        let index = CurrentLineRule.lineIndex(of: caret, in: lineStarts)
        let lineStart = min(max(0, lineStarts[index]), caret)
        let column = text.substring(with: NSRange(location: lineStart, length: caret - lineStart)).count
        return (index + 1, column + 1)
    }

    /// What one readout remembers so the next can count only what moved: the
    /// caret's line start, its UTF-16 offset and the 1-based column read there.
    public struct ColumnMemo: Equatable, Sendable {
        public let lineStart: Int
        public let offset: Int
        public let column: Int

        public init(lineStart: Int, offset: Int, column: Int) {
            self.lineStart = lineStart
            self.offset = offset
            self.column = column
        }
    }

    /// How far back from the lower of the two offsets the incremental count
    /// searches for an anchor, in UTF-16 units.
    ///
    /// An anchor is the line start itself, or a position whose preceding and
    /// following units are both printable ASCII (0x20–0x7E). No grapheme rule
    /// joins two such units — none extends, prepends to or pairs with either —
    /// so that position is a cluster boundary whatever surrounds it, and the
    /// cluster counts on either side of it add. `rangeOfComposedCharacterSequence`
    /// is deliberately not the anchor: it splits a prepend character (U+0600)
    /// from the character it prepends, which would miscount the column.
    static let anchorLookback = 64

    /// `position(text:caretOffset:lineStarts:)`, counting only what changed
    /// since `memo` was taken when that is provably the same answer.
    ///
    /// `editFloor` is the lowest UTF-16 offset any edit touched since `memo`, or
    /// `nil` when there was none. The incremental path needs a memo on the
    /// caret's own line start with `[lineStart, memo.offset)` unedited
    /// (`editFloor` `nil` or at least `memo.offset`), and an anchor within
    /// `anchorLookback` units at or below the lower of the two offsets; it then
    /// reads column(anchor) = memo.column − count(anchor..old) and
    /// column(new) = column(anchor) + count(anchor..new). Every other case —
    /// another line, an edit before the old caret, a line with no ASCII anchor
    /// nearby — is the full count. The returned memo is the next call's.
    public static func position(
        text: NSString,
        caretOffset: Int,
        lineStarts: [Int],
        memo: ColumnMemo?,
        editFloor: Int?
    ) -> (line: Int, column: Int, memo: ColumnMemo) {
        let counted = countedPosition(
            text: text, caretOffset: caretOffset, lineStarts: lineStarts, memo: memo, editFloor: editFloor
        )
        return (counted.line, counted.column, counted.memo)
    }

    /// The memoised position plus the UTF-16 units it examined — the anchor
    /// search plus the units counted — which the tests charge. Never a clock.
    static func countedPosition(
        text: NSString,
        caretOffset: Int,
        lineStarts: [Int],
        memo: ColumnMemo?,
        editFloor: Int?
    ) -> (line: Int, column: Int, memo: ColumnMemo, work: Int) {
        let caret = min(max(0, caretOffset), text.length)
        let index = lineStarts.isEmpty ? 0 : CurrentLineRule.lineIndex(of: caret, in: lineStarts)
        let lineStart = lineStarts.isEmpty ? 0 : min(max(0, lineStarts[index]), caret)
        var work = 0
        if let memo, memo.lineStart == lineStart,
           memo.offset >= lineStart, memo.offset <= text.length,
           editFloor.map({ $0 >= memo.offset }) ?? true {
            let lower = min(memo.offset, caret)
            let search = anchor(in: text, from: lower, lineStart: lineStart)
            work += search.examined
            if let anchor = search.anchor {
                let atAnchor = memo.column - clusterCount(text, from: anchor, to: memo.offset, work: &work)
                let column = atAnchor + clusterCount(text, from: anchor, to: caret, work: &work)
                return (index + 1, column, ColumnMemo(lineStart: lineStart, offset: caret, column: column), work)
            }
        }
        let column = clusterCount(text, from: lineStart, to: caret, work: &work) + 1
        return (index + 1, column, ColumnMemo(lineStart: lineStart, offset: caret, column: column), work)
    }

    /// The nearest anchor at or below `offset` and no further back than
    /// `anchorLookback`, with the number of distinct units read to find it.
    private static func anchor(in text: NSString, from offset: Int, lineStart: Int) -> (anchor: Int?, examined: Int) {
        let floor = max(lineStart, offset - anchorLookback)
        var examined = 0
        var following: unichar?
        if offset < text.length, offset > lineStart {
            following = text.character(at: offset)
            examined += 1
        }
        var position = offset
        while position >= floor {
            if position == lineStart { return (position, examined) }
            let preceding = text.character(at: position - 1)
            examined += 1
            if let unit = following, isPrintableASCII(unit), isPrintableASCII(preceding) {
                return (position, examined)
            }
            following = preceding
            position -= 1
        }
        return (nil, examined)
    }

    private static func isPrintableASCII(_ unit: unichar) -> Bool {
        unit >= 0x20 && unit <= 0x7E
    }

    /// The grapheme clusters in `[start, end)`, charging `work` with the units
    /// it scans — here, where the scan happens, so a count over a wider range
    /// than the incremental path needs is charged for that range.
    private static func clusterCount(_ text: NSString, from start: Int, to end: Int, work: inout Int) -> Int {
        work += end - start
        return text.substring(with: NSRange(location: start, length: end - start)).count
    }

    /// `position(text:caretOffset:lineStarts:)` over the whole text's table.
    static func position(text: NSString, caretOffset: Int) -> (line: Int, column: Int) {
        position(text: text, caretOffset: caretOffset, lineStarts: LineStartIndex.offsets(in: text))
    }
}
