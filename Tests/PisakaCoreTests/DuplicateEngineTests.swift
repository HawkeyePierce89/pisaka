import XCTest
@testable import PisakaCore

final class DuplicateEngineTests: XCTestCase {
    private func edit(_ text: String, _ range: NSRange) -> DuplicateEdit {
        DuplicateEngine.duplicate(text: text as NSString, selectedRange: range)
    }

    private func caret(_ text: String, at location: Int) -> DuplicateEdit {
        edit(text, NSRange(location: location, length: 0))
    }

    /// Apply an edit the way the view layer does: splice `text` in at
    /// `insertionLocation` (a zero-length replacement range).
    private func applied(_ source: String, _ edit: DuplicateEdit) -> String {
        let mutable = NSMutableString(string: source)
        mutable.replaceCharacters(
            in: NSRange(location: edit.insertionLocation, length: 0),
            with: edit.text
        )
        return mutable as String
    }

    // MARK: - Caret (empty selection)

    func testCaretMidLineDuplicatesLineBelowKeepingColumn() {
        let text = "let a = 1\nlet b = 2\n"
        // Caret inside the first line, at column 4.
        let result = caret(text, at: 4)
        XCTAssertEqual(result.insertionLocation, 10)
        XCTAssertEqual(result.text, "let a = 1\n")
        XCTAssertEqual(result.selectedRange, NSRange(location: 14, length: 0))
        XCTAssertEqual(applied(text, result), "let a = 1\nlet a = 1\nlet b = 2\n")
    }

    func testCaretOnFirstLineAtLineStart() {
        let text = "ab\ncd\n"
        let result = caret(text, at: 0)
        XCTAssertEqual(result.insertionLocation, 3)
        XCTAssertEqual(result.text, "ab\n")
        XCTAssertEqual(result.selectedRange, NSRange(location: 3, length: 0))
        XCTAssertEqual(applied(text, result), "ab\nab\ncd\n")
    }

    func testCaretOnLastLineWithTrailingNewline() {
        let text = "ab\ncd\n"
        // Caret on the second (last non-empty) line, column 1.
        let result = caret(text, at: 4)
        XCTAssertEqual(result.insertionLocation, 6)
        XCTAssertEqual(result.text, "cd\n")
        XCTAssertEqual(result.selectedRange, NSRange(location: 7, length: 0))
        XCTAssertEqual(applied(text, result), "ab\ncd\ncd\n")
    }

    func testCaretOnLastLineWithoutTrailingNewline() {
        let text = "ab\ncd"
        let result = caret(text, at: 4)
        XCTAssertEqual(result.insertionLocation, 5)
        XCTAssertEqual(result.text, "\ncd")
        XCTAssertEqual(result.selectedRange, NSRange(location: 7, length: 0))
        XCTAssertEqual(applied(text, result), "ab\ncd\ncd")
    }

    func testCaretOnEmptyLineInTheMiddle() {
        let text = "ab\n\ncd\n"
        let result = caret(text, at: 3)
        XCTAssertEqual(result.insertionLocation, 4)
        XCTAssertEqual(result.text, "\n")
        XCTAssertEqual(result.selectedRange, NSRange(location: 4, length: 0))
        XCTAssertEqual(applied(text, result), "ab\n\n\ncd\n")
    }

    func testCaretOnTrailingEmptyLine() {
        let text = "ab\n"
        let result = caret(text, at: 3)
        XCTAssertEqual(result.insertionLocation, 3)
        XCTAssertEqual(result.text, "\n")
        XCTAssertEqual(result.selectedRange, NSRange(location: 4, length: 0))
        XCTAssertEqual(applied(text, result), "ab\n\n")
    }

    func testEmptyBufferAddsAnEmptyLine() {
        let result = caret("", at: 0)
        XCTAssertEqual(result.insertionLocation, 0)
        XCTAssertEqual(result.text, "\n")
        XCTAssertEqual(result.selectedRange, NSRange(location: 1, length: 0))
        XCTAssertEqual(applied("", result), "\n")
    }

    // MARK: - Separators

    func testCRLFTerminatorIsCopiedAsAPair() {
        let text = "ab\r\ncd\r\n"
        let result = caret(text, at: 1)
        XCTAssertEqual(result.insertionLocation, 4)
        XCTAssertEqual(result.text, "ab\r\n")
        XCTAssertEqual(result.selectedRange, NSRange(location: 5, length: 0))
        XCTAssertEqual(applied(text, result), "ab\r\nab\r\ncd\r\n")
    }

    /// The off-by-one boundary: the caret sits exactly at `contentsEnd` — the end
    /// of the *visible* line, immediately before `\r\n`. The column is a UTF-16
    /// offset from the line start and the copy has the same length, so the new
    /// caret lands right before the *copy's* own `\r\n`, never inside the pair.
    func testCaretExactlyAtContentsEndOfCRLFLine() {
        let text = "ab\r\ncd\r\n"
        let result = caret(text, at: 2)
        XCTAssertEqual(result.insertionLocation, 4)
        XCTAssertEqual(result.text, "ab\r\n")
        XCTAssertEqual(result.selectedRange, NSRange(location: 6, length: 0))

        let after = applied(text, result)
        XCTAssertEqual(after, "ab\r\nab\r\ncd\r\n")
        // The caret sits between the copy's `b` and its `\r`: neither inside the
        // CRLF pair nor past it.
        let ns = after as NSString
        XCTAssertEqual(ns.substring(with: NSRange(location: 5, length: 1)), "b")
        XCTAssertEqual(ns.substring(with: NSRange(location: 6, length: 1)), "\r")
    }

    /// The same boundary on the *last* CRLF line, which carries no terminator: a
    /// plain `"\n"` is used for the trailing insertion (deliberate simplification).
    func testCaretExactlyAtContentsEndOfLastCRLFLineWithoutTerminator() {
        let text = "ab\r\ncd"
        let result = caret(text, at: 6)
        XCTAssertEqual(result.insertionLocation, 6)
        XCTAssertEqual(result.text, "\ncd")
        XCTAssertEqual(result.selectedRange, NSRange(location: 9, length: 0))

        let after = applied(text, result)
        XCTAssertEqual(after, "ab\r\ncd\ncd")
        XCTAssertEqual((after as NSString).length, 9)
    }

    /// Every single-unit separator `LineStartIndex` recognizes — LF, CR, NEL,
    /// U+2028, U+2029 — must terminate a line here too, so the copy carries that
    /// file's own separator verbatim. (CRLF, the one two-unit separator, has its
    /// own tests above.)
    func testEverySingleUnitLineSeparator() {
        for separator in ["\n", "\r", "\u{85}", "\u{2028}", "\u{2029}"] {
            let text = "ab\(separator)cd"
            let result = caret(text, at: 1)
            XCTAssertEqual(result.insertionLocation, 3, "separator \(separator.debugDescription)")
            XCTAssertEqual(result.text, "ab\(separator)", "separator \(separator.debugDescription)")
            XCTAssertEqual(
                result.selectedRange,
                NSRange(location: 4, length: 0),
                "separator \(separator.debugDescription)"
            )
            XCTAssertEqual(
                applied(text, result),
                "ab\(separator)ab\(separator)cd",
                "separator \(separator.debugDescription)"
            )
        }
    }

    /// The neighbor of `testCaretExactlyAtContentsEndOfCRLFLine`: a caret *inside*
    /// the CRLF pair (between `\r` and `\n`). TextKit lays the pair out as one
    /// break so this is unreachable by typing, but the column is clamped to the
    /// line's contents, so the caret lands at the copy's line end rather than
    /// inside the copy's own pair.
    func testCaretInsideACRLFPairIsClampedToTheCopysLineEnd() {
        let text = "ab\r\ncd\r\n"
        let result = caret(text, at: 3)
        XCTAssertEqual(result.insertionLocation, 4)
        XCTAssertEqual(result.text, "ab\r\n")
        XCTAssertEqual(result.selectedRange, NSRange(location: 6, length: 0))

        let after = applied(text, result)
        XCTAssertEqual(after, "ab\r\nab\r\ncd\r\n")
        let ns = after as NSString
        XCTAssertEqual(ns.substring(with: NSRange(location: 5, length: 1)), "b")
        XCTAssertEqual(ns.substring(with: NSRange(location: 6, length: 1)), "\r")
    }

    // MARK: - Non-empty selection

    func testSelectionInsideOneLineIsDuplicatedAndTheCopyIsSelected() {
        let text = "abcd"
        let result = edit(text, NSRange(location: 1, length: 2))
        XCTAssertEqual(result.insertionLocation, 3)
        XCTAssertEqual(result.text, "bc")
        XCTAssertEqual(result.selectedRange, NSRange(location: 3, length: 2))
        XCTAssertEqual(applied(text, result), "abcbcd")
    }

    func testRepeatedDuplicationGrowsTheText() {
        // `[ab]` -> `ab[ab]` -> `abab[ab]`
        var text = "ab"
        var selection = NSRange(location: 0, length: 2)

        let first = edit(text, selection)
        text = applied(text, first)
        selection = first.selectedRange
        XCTAssertEqual(text, "abab")
        XCTAssertEqual(selection, NSRange(location: 2, length: 2))

        let second = edit(text, selection)
        text = applied(text, second)
        selection = second.selectedRange
        XCTAssertEqual(text, "ababab")
        XCTAssertEqual(selection, NSRange(location: 4, length: 2))
    }

    func testMultiLineSelectionIsDuplicatedCharacterWise() {
        let text = "ab\ncd\nef\n"
        // "b\ncd" — a span crossing a line break, duplicated as-is.
        let result = edit(text, NSRange(location: 1, length: 4))
        XCTAssertEqual(result.insertionLocation, 5)
        XCTAssertEqual(result.text, "b\ncd")
        XCTAssertEqual(result.selectedRange, NSRange(location: 5, length: 4))
        XCTAssertEqual(applied(text, result), "ab\ncdb\ncd\nef\n")
    }

    func testSelectionReachingTheEndOfTheBuffer() {
        let text = "ab\ncd"
        let result = edit(text, NSRange(location: 3, length: 2))
        XCTAssertEqual(result.insertionLocation, 5)
        XCTAssertEqual(result.text, "cd")
        XCTAssertEqual(result.selectedRange, NSRange(location: 5, length: 2))
        XCTAssertEqual(applied(text, result), "ab\ncdcd")
    }

    func testSelectionContainingAWholeSurrogatePairCopiesItIntact() {
        let text = "a😀b"
        // The emoji is two UTF-16 units, wholly inside the selection.
        let result = edit(text, NSRange(location: 1, length: 2))
        XCTAssertEqual(result.insertionLocation, 3)
        XCTAssertEqual(result.text, "😀")
        XCTAssertEqual(result.selectedRange, NSRange(location: 3, length: 2))
        XCTAssertEqual(applied(text, result), "a😀😀b")
    }

    // MARK: - Clamping

    func testOutOfBoundsLocationIsClampedToTheBufferEnd() {
        let text = "abc"
        let result = edit(text, NSRange(location: 10, length: 5))
        XCTAssertEqual(result.insertionLocation, 3)
        XCTAssertEqual(result.text, "\nabc")
        XCTAssertEqual(result.selectedRange, NSRange(location: 7, length: 0))
        XCTAssertEqual(applied(text, result), "abc\nabc")
    }

    func testOverlongLengthIsClampedToTheBufferEnd() {
        let text = "abc"
        let result = edit(text, NSRange(location: 1, length: 10))
        XCTAssertEqual(result.insertionLocation, 3)
        XCTAssertEqual(result.text, "bc")
        XCTAssertEqual(result.selectedRange, NSRange(location: 3, length: 2))
        XCTAssertEqual(applied(text, result), "abcbc")
    }

    func testNotFoundLocationIsClampedAndNeverTraps() {
        let text = "abc"
        let result = edit(text, NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(result.insertionLocation, 3)
        XCTAssertEqual(result.text, "\nabc")
        XCTAssertEqual(result.selectedRange, NSRange(location: 7, length: 0))
    }

    func testNegativeLocationIsClampedToZero() {
        let text = "abc"
        let result = edit(text, NSRange(location: -3, length: -1))
        XCTAssertEqual(result.insertionLocation, 3)
        XCTAssertEqual(result.text, "\nabc")
        // The caret was clamped to 0 — column 0 of the only line, so the copy's
        // own column 0 is one unit past the inserted `"\n"`.
        XCTAssertEqual(result.selectedRange, NSRange(location: 4, length: 0))
        XCTAssertEqual(applied(text, result), "abc\nabc")
    }
}
