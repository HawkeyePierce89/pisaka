import XCTest
@testable import PisakaCore

final class CaretReadoutTests: XCTestCase {
    private func readout(_ text: String, _ offset: Int, _ language: SyntaxLanguage? = .swift) -> String {
        CaretReadout.text(
            text: text as NSString,
            caretOffset: offset,
            language: language,
            encodingName: FileService.encodingName
        )
    }

    func testEncodingNameIsUTF8() {
        XCTAssertEqual(FileService.encodingName, "UTF-8")
    }

    func testFullShape() {
        XCTAssertEqual(readout("let x = 1\n", 4), "Ln 1, Col 5 · UTF-8 · Swift")
    }

    func testNoLanguageReadsPlainText() {
        XCTAssertEqual(readout("abc", 0, nil), "Ln 1, Col 1 · UTF-8 · Plain Text")
    }

    func testLanguageNameIsDisplayName() {
        XCTAssertEqual(readout("", 0, .javascript), "Ln 1, Col 1 · UTF-8 · JavaScript")
    }

    func testEmptyText() {
        XCTAssertEqual(readout("", 0), "Ln 1, Col 1 · UTF-8 · Swift")
    }

    func testASCIIColumnsAndLines() {
        let text = "abc\ndefg\nhi"
        XCTAssertEqual(readout(text, 0), "Ln 1, Col 1 · UTF-8 · Swift")
        XCTAssertEqual(readout(text, 3), "Ln 1, Col 4 · UTF-8 · Swift")
        XCTAssertEqual(readout(text, 4), "Ln 2, Col 1 · UTF-8 · Swift")
        XCTAssertEqual(readout(text, 6), "Ln 2, Col 3 · UTF-8 · Swift")
        XCTAssertEqual(readout(text, 9), "Ln 3, Col 1 · UTF-8 · Swift")
    }

    /// The last line has no terminator; a caret at its end is past its last
    /// character, not on a line beyond it.
    func testCaretAtEndOfUnterminatedLastLine() {
        let text = "abc\nhi"
        XCTAssertEqual(readout(text, 6), "Ln 2, Col 3 · UTF-8 · Swift")
    }

    /// A terminated last line leaves an empty line after it, as the gutter shows.
    func testCaretAfterTrailingSeparatorIsOnTheEmptyLastLine() {
        XCTAssertEqual(readout("abc\n", 4), "Ln 2, Col 1 · UTF-8 · Swift")
    }

    func testCRLFCountsOnce() {
        let text = "ab\r\ncd\r\nef"
        XCTAssertEqual(readout(text, 4), "Ln 2, Col 1 · UTF-8 · Swift")
        XCTAssertEqual(readout(text, 6), "Ln 2, Col 3 · UTF-8 · Swift")
        XCTAssertEqual(readout(text, 9), "Ln 3, Col 2 · UTF-8 · Swift")
    }

    /// A caret between a CR and its LF is still on the line the pair ends:
    /// the pair is one separator, so no line starts inside it.
    func testCaretInsideCRLFPairStaysOnItsLine() {
        XCTAssertEqual(readout("ab\r\ncd", 3), "Ln 1, Col 4 · UTF-8 · Swift")
    }

    /// The readout's line agrees with the gutter's index of the whole text at
    /// every offset, whatever the mix of separators.
    func testLineAgreesWithTheWholeTextIndexEverywhere() {
        let text = "a\r\nb\rc\n\u{0085}d\u{2028}\u{2029}e\r\n" as NSString
        let starts = LineStartIndex.offsets(in: text)
        for offset in 0...text.length {
            let expected = starts.lastIndex { $0 <= offset }! + 1
            XCTAssertEqual(CaretReadout.position(text: text, caretOffset: offset).line, expected, "offset \(offset)")
        }
    }

    func testBareCRSplits() {
        XCTAssertEqual(readout("ab\rcd", 4), "Ln 2, Col 2 · UTF-8 · Swift")
    }

    func testNELLineSeparatorAndParagraphSeparatorSplit() {
        let text = "a\u{0085}b\u{2028}c\u{2029}d"
        XCTAssertEqual(readout(text, 2), "Ln 2, Col 1 · UTF-8 · Swift")
        XCTAssertEqual(readout(text, 4), "Ln 3, Col 1 · UTF-8 · Swift")
        XCTAssertEqual(readout(text, 6), "Ln 4, Col 1 · UTF-8 · Swift")
        XCTAssertEqual(readout(text, 7), "Ln 4, Col 2 · UTF-8 · Swift")
    }

    /// An emoji is two UTF-16 units (a family emoji many more) but one column.
    func testEmojiIsOneColumn() {
        let text = "a😀b" as NSString
        XCTAssertEqual(readout(text as String, 3), "Ln 1, Col 3 · UTF-8 · Swift")
        let family = "👨‍👩‍👧x"
        let afterFamily = (family as NSString).length - 1
        XCTAssertEqual(readout(family, afterFamily), "Ln 1, Col 2 · UTF-8 · Swift")
    }

    /// A letter and its combining mark are one grapheme cluster, so one column.
    func testCombiningMarkIsOneColumn() {
        let text = "e\u{0301}x"
        XCTAssertEqual(readout(text, 2), "Ln 1, Col 2 · UTF-8 · Swift")
        XCTAssertEqual(readout(text, 3), "Ln 1, Col 3 · UTF-8 · Swift")
    }

    func testTabIsOneColumn() {
        XCTAssertEqual(readout("\t\tx", 2), "Ln 1, Col 3 · UTF-8 · Swift")
    }

    func testOffsetBeyondTextClampsToEnd() {
        XCTAssertEqual(readout("abc\nde", 99), "Ln 2, Col 3 · UTF-8 · Swift")
        XCTAssertEqual(readout("abc", -5), "Ln 1, Col 1 · UTF-8 · Swift")
    }
}
