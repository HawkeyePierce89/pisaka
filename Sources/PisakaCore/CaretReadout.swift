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
    /// whole text. The editor asks `position(text:caretOffset:lineStarts:)` with
    /// the gutter's own table instead, and formats that with
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
    /// is a binary search and the column counts only the caret's own line: a
    /// caret move never copies or rescans the buffer. A caret between a CR and
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

    /// `position(text:caretOffset:lineStarts:)` over the whole text's table.
    static func position(text: NSString, caretOffset: Int) -> (line: Int, column: Int) {
        position(text: text, caretOffset: caretOffset, lineStarts: LineStartIndex.offsets(in: text))
    }
}
