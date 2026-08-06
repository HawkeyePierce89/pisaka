import Foundation

/// The text to splice in for one duplication plus where the selection should
/// land afterward.
///
/// `insertionLocation` is a UTF-16 offset into the *current* document at which
/// `text` is inserted (always a zero-length replacement — a duplication never
/// deletes anything), and `selectedRange` is the resulting selection expressed
/// in the coordinates of the document *after* the insertion: a caret (zero
/// length) for the line case, and the freshly inserted **copy** for the
/// selection case, so repeated duplications grow the text (`[ab]` → `ab[ab]` →
/// `abab[ab]`).
public struct DuplicateEdit: Equatable {
    public let insertionLocation: Int
    public let text: String
    public let selectedRange: NSRange

    public init(insertionLocation: Int, text: String, selectedRange: NSRange) {
        self.insertionLocation = insertionLocation
        self.text = text
        self.selectedRange = selectedRange
    }
}

/// Pure, testable duplicate-line/selection computation for the editor —
/// Foundation only, so it stays in `PisakaCore` and is unit-tested without any
/// AppKit/UIKit dependency (the `IndentEngine`/`AutoPairEngine` precedent: the
/// engine operates on an `NSString` + UTF-16 offsets and returns a value type
/// describing "what to insert and where", while the view layer applies it as one
/// programmatic edit).
///
/// The semantics are JetBrains' Cmd+D:
/// - **No selection** — the caret's logical line is duplicated below it and the
///   caret moves into the copy at the same column.
/// - **A selection** — the selected span is duplicated *character-wise* (a
///   multi-line selection included, deliberately not rounded out to whole
///   lines), the copy inserted right after the selection and selected itself.
///
/// Line boundaries come from `NSString.getLineStart(_:end:contentsEnd:for:)`,
/// which follows the same Unicode separator semantics as `LineStartIndex` (LF,
/// CR, the CRLF pair as *one* separator, NEL, U+2028, U+2029) and reports the
/// terminator length as `end - contentsEnd` — 2 for CRLF, so a terminated line
/// copies its own terminator verbatim and the pair is never split.
public enum DuplicateEngine {
    /// Compute the duplication for `selectedRange` in `text`.
    ///
    /// `selectedRange` is clamped to the buffer bounds first, so an out-of-range
    /// (or `NSNotFound`) range can never trap; it is otherwise used as given —
    /// the engine never widens a range to a composed character sequence, since
    /// that would change selection semantics (and the text view never hands over
    /// a range splitting a surrogate pair).
    ///
    /// **Caret case.** With a terminator present the whole line *including* its
    /// terminator is inserted at `end`, and the new caret is
    /// `end + (caret - lineStart)`: the column is a UTF-16 offset from the line
    /// start and the copy has the same length, so overrunning it is impossible —
    /// a caret sitting exactly at `contentsEnd` of a CRLF line lands right before
    /// the *copy's* own `\r\n`, neither inside the pair nor past it. The column is
    /// clamped to `contentsEnd`, so a caret sitting *inside* a CRLF terminator
    /// (between `\r` and `\n`) lands at the copy's line end rather than inside the
    /// copy's own pair — unreachable through TextKit, which lays the pair out as a
    /// single break, but expressible programmatically. On a line
    /// with no terminator (the last line, or an empty buffer) a plain `"\n"` is
    /// prepended to the copy instead — a deliberate simplification, so a
    /// CR/CRLF-delimited file's trailing insertion uses `"\n"` while every
    /// terminated line still copies its own separator verbatim. An empty buffer
    /// therefore gains an empty line, as in JetBrains.
    public static func duplicate(text: NSString, selectedRange: NSRange) -> DuplicateEdit {
        let range = clamped(selectedRange, length: text.length)

        if range.length > 0 {
            let copyStart = NSMaxRange(range)
            return DuplicateEdit(
                insertionLocation: copyStart,
                text: text.substring(with: range),
                selectedRange: NSRange(location: copyStart, length: range.length)
            )
        }

        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        text.getLineStart(
            &lineStart,
            end: &lineEnd,
            contentsEnd: &contentsEnd,
            for: NSRange(location: range.location, length: 0)
        )

        // Clamped to the line's *contents* so a caret that sits inside a two-unit
        // CRLF terminator (between `\r` and `\n` — unreachable through TextKit,
        // which lays the pair out as one break, but expressible programmatically)
        // lands at the copy's line end rather than inside the copy's own pair.
        let column = min(range.location - lineStart, contentsEnd - lineStart)
        let hasTerminator = lineEnd > contentsEnd

        if hasTerminator {
            let line = text.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            return DuplicateEdit(
                insertionLocation: lineEnd,
                text: line,
                selectedRange: NSRange(location: lineEnd + column, length: 0)
            )
        }

        let contents = text.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
        return DuplicateEdit(
            insertionLocation: lineEnd,
            text: "\n" + contents,
            selectedRange: NSRange(location: lineEnd + 1 + column, length: 0)
        )
    }

    /// Coerce a possibly invalid selection (out-of-bounds location, `NSNotFound`,
    /// a negative or overlong length) into a valid range inside `[0, length]`.
    private static func clamped(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        let maxLength = length - location
        return NSRange(location: location, length: min(max(range.length, 0), maxLength))
    }
}
