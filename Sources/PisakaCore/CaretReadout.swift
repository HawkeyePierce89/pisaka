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

    /// The readout for a caret at UTF-16 `caretOffset` in `text`.
    public static func text(
        text: NSString,
        caretOffset: Int,
        language: SyntaxLanguage?,
        encodingName: String
    ) -> String {
        let (line, column) = position(text: text, caretOffset: caretOffset)
        let languageName = language?.displayName ?? plainTextName
        return "Ln \(line), Col \(column) · \(encodingName) · \(languageName)"
    }

    /// The 1-based line and column of `caretOffset`, clamped into `text`.
    ///
    /// Only the text before the caret is indexed, so a caret near the top of a
    /// large file costs what it is near rather than the whole buffer; the line
    /// starts at or before the caret are the same either way. The one place the
    /// two readings differ is a caret between a CR and its LF: the prefix ends
    /// in a bare CR and so opens a line at the caret, where the whole text's
    /// CRLF pair does not — that trailing start is dropped.
    static func position(text: NSString, caretOffset: Int) -> (line: Int, column: Int) {
        let caret = min(max(0, caretOffset), text.length)
        var starts = LineStartIndex.offsets(in: text.substring(to: caret) as NSString)
        if caret > 0, caret < text.length, starts.count > 1, starts.last == caret,
           text.character(at: caret - 1) == 0x0D, text.character(at: caret) == 0x0A {
            starts.removeLast()
        }
        // `starts` is ascending, begins at 0 and ends at or before the caret.
        let lineStart = starts[starts.count - 1]
        let column = text.substring(with: NSRange(location: lineStart, length: caret - lineStart)).count
        return (starts.count, column + 1)
    }
}
