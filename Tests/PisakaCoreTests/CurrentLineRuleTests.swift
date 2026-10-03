import Foundation
@testable import PisakaCore
import XCTest

final class CurrentLineRuleTests: XCTestCase {
    private func line(_ text: String, _ selection: NSRange) -> NSRange? {
        let content = text as NSString
        return CurrentLineRule.highlightedLine(
            selection: selection,
            lineStarts: LineStartIndex.offsets(in: content),
            length: content.length
        )
    }

    func testACaretHighlightsItsLineSeparatorIncluded() {
        XCTAssertEqual(line("one\ntwo\nthree", NSRange(location: 5, length: 0)), NSRange(location: 4, length: 4))
    }

    func testACaretAtALineStartHighlightsThatLine() {
        XCTAssertEqual(line("one\ntwo\nthree", NSRange(location: 4, length: 0)), NSRange(location: 4, length: 4))
    }

    func testACaretAtALineEndHighlightsThatLine() {
        XCTAssertEqual(line("one\ntwo\nthree", NSRange(location: 3, length: 0)), NSRange(location: 0, length: 4))
    }

    func testASelectionWithinOneLineStillHighlights() {
        XCTAssertEqual(line("one\ntwo\nthree", NSRange(location: 8, length: 3)), NSRange(location: 8, length: 5))
    }

    func testAMultiLineSelectionHighlightsNothing() {
        XCTAssertNil(line("one\ntwo\nthree", NSRange(location: 2, length: 4)))
        XCTAssertNil(line("one\ntwo\nthree", NSRange(location: 0, length: 13)))
    }

    func testAWholeLineSelectedWithItsSeparatorCoversOneLine() {
        XCTAssertEqual(line("one\ntwo\nthree", NSRange(location: 4, length: 4)), NSRange(location: 4, length: 4))
        XCTAssertNil(line("one\ntwo\nthree", NSRange(location: 4, length: 5)))
    }

    func testTheLastLineRunsToTheEnd() {
        XCTAssertEqual(line("one\ntwo\nthree", NSRange(location: 13, length: 0)), NSRange(location: 8, length: 5))
    }

    func testTheTrailingEmptyLineIsALine() {
        XCTAssertEqual(line("one\ntwo\n", NSRange(location: 8, length: 0)), NSRange(location: 8, length: 0))
        XCTAssertEqual(line("one\ntwo\n", NSRange(location: 7, length: 0)), NSRange(location: 4, length: 4))
    }

    func testAnEmptyDocumentHighlightsItsOneLine() {
        XCTAssertEqual(line("", NSRange(location: 0, length: 0)), NSRange(location: 0, length: 0))
        XCTAssertEqual(
            CurrentLineRule.highlightedLine(selection: NSRange(location: 0, length: 0), lineStarts: [], length: 0),
            NSRange(location: 0, length: 0)
        )
    }

    func testEverySeparatorSplitsTheSameWayTheGutterDoes() {
        // CRLF is one separator; NEL, LS and PS each open a line.
        let text = "a\r\nb\u{85}c\u{2028}d\u{2029}e"
        XCTAssertEqual(line(text, NSRange(location: 3, length: 0)), NSRange(location: 3, length: 2))
        XCTAssertEqual(line(text, NSRange(location: 7, length: 0)), NSRange(location: 7, length: 2))
        XCTAssertEqual(line(text, NSRange(location: 9, length: 0)), NSRange(location: 9, length: 1))
    }

    func testAStaleSelectionClampsIntoTheText() {
        XCTAssertEqual(line("one\ntwo", NSRange(location: 40, length: 3)), NSRange(location: 4, length: 3))
    }
}
