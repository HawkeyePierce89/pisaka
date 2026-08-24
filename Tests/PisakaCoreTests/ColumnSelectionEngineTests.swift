import XCTest
import Foundation
@testable import PisakaCore

final class ColumnSelectionEngineTests: XCTestCase {

    // MARK: - Ranges Resolution Tests

    func testRanges_MultiLineUniform() {
        let text = "abc\ndef\nghi" as NSString
        let lines = [
            ColumnSelectionLine(lineRange: NSRange(location: 0, length: 4), leftOffset: 1, rightOffset: 3),
            ColumnSelectionLine(lineRange: NSRange(location: 4, length: 4), leftOffset: 5, rightOffset: 7),
            ColumnSelectionLine(lineRange: NSRange(location: 8, length: 3), leftOffset: 9, rightOffset: 11),
        ]

        let ranges = ColumnSelectionEngine.ranges(for: lines, in: text)
        XCTAssertEqual(ranges, [
            NSRange(location: 1, length: 2), // "bc"
            NSRange(location: 5, length: 2), // "ef"
            NSRange(location: 9, length: 2),  // "hi"
        ])
    }

    func testRanges_LineShorterThanRectangle() {
        let text = "a\nabcde\n" as NSString // length 8
        let lines = [
            ColumnSelectionLine(lineRange: NSRange(location: 0, length: 2), leftOffset: 2, rightOffset: 4), // past end of "a"
            ColumnSelectionLine(lineRange: NSRange(location: 2, length: 6), leftOffset: 4, rightOffset: 6),  // middle of "abcde"
        ]

        let ranges = ColumnSelectionEngine.ranges(for: lines, in: text)
        // first line: content ends at 1. left=2, right=4 clamps to 1..1
        // second line: content ends at 7. left=4, right=6 clamps to 4..6
        XCTAssertEqual(ranges, [
            NSRange(location: 1, length: 0),
            NSRange(location: 4, length: 2),
        ])
    }

    func testRanges_TerminatorLF() {
        let text = "abc\n" as NSString
        let lines = [
            ColumnSelectionLine(lineRange: NSRange(location: 0, length: 4), leftOffset: 2, rightOffset: 5)
        ]

        let ranges = ColumnSelectionEngine.ranges(for: lines, in: text)
        // content ends at 3. left=2, right=5 clamps to 2..3
        XCTAssertEqual(ranges, [
            NSRange(location: 2, length: 1)
        ])
    }

    func testRanges_TerminatorCR() {
        let text = "abc\r" as NSString
        let lines = [
            ColumnSelectionLine(lineRange: NSRange(location: 0, length: 4), leftOffset: 2, rightOffset: 5)
        ]

        let ranges = ColumnSelectionEngine.ranges(for: lines, in: text)
        XCTAssertEqual(ranges, [
            NSRange(location: 2, length: 1)
        ])
    }

    func testRanges_TerminatorCRLF() {
        let text = "abc\r\n" as NSString
        let lines = [
            ColumnSelectionLine(lineRange: NSRange(location: 0, length: 5), leftOffset: 4, rightOffset: 6)
        ]

        let ranges = ColumnSelectionEngine.ranges(for: lines, in: text)
        // content ends at 3. left=4, right=6 clamps to 3..3
        XCTAssertEqual(ranges, [
            NSRange(location: 3, length: 0)
        ])
    }

    func testRanges_PureTerminatorEdgeCase() {
        let text = "\n" as NSString
        let lines = [
            ColumnSelectionLine(lineRange: NSRange(location: 0, length: 1), leftOffset: 0, rightOffset: 1)
        ]

        let ranges = ColumnSelectionEngine.ranges(for: lines, in: text)
        XCTAssertEqual(ranges, [
            NSRange(location: 0, length: 0)
        ])
    }

    func testRanges_ZeroWidthYieldsOneZeroLengthRangePerLine() {
        let text = "abc\ndef\n" as NSString
        let lines = [
            ColumnSelectionLine(lineRange: NSRange(location: 0, length: 4), leftOffset: 1, rightOffset: 1),
            ColumnSelectionLine(lineRange: NSRange(location: 4, length: 4), leftOffset: 5, rightOffset: 5),
        ]

        let ranges = ColumnSelectionEngine.ranges(for: lines, in: text)
        XCTAssertEqual(ranges, [
            NSRange(location: 1, length: 0),
            NSRange(location: 5, length: 0),
        ])
    }

    func testRanges_SingleLineDrag() {
        let text = "abcdef" as NSString
        let lines = [
            ColumnSelectionLine(lineRange: NSRange(location: 0, length: 6), leftOffset: 1, rightOffset: 4)
        ]

        let ranges = ColumnSelectionEngine.ranges(for: lines, in: text)
        XCTAssertEqual(ranges, [
            NSRange(location: 1, length: 3)
        ])
    }

    func testRanges_EmptyDocument() {
        let text = "" as NSString
        let lines = [
            ColumnSelectionLine(lineRange: NSRange(location: 0, length: 0), leftOffset: 0, rightOffset: 0)
        ]

        let ranges = ColumnSelectionEngine.ranges(for: lines, in: text)
        XCTAssertEqual(ranges, [
            NSRange(location: 0, length: 0)
        ])
    }

    func testRanges_ReverseOrderOffsets() {
        let text = "abcdef" as NSString
        let lines = [
            ColumnSelectionLine(lineRange: NSRange(location: 0, length: 6), leftOffset: 4, rightOffset: 1)
        ]

        let ranges = ColumnSelectionEngine.ranges(for: lines, in: text)
        XCTAssertEqual(ranges, [
            NSRange(location: 1, length: 3)
        ])
    }

    func testRanges_EmptyInputYieldsNoRanges() {
        let text = "abc\ndef" as NSString
        let ranges = ColumnSelectionEngine.ranges(for: [], in: text)
        XCTAssertTrue(ranges.isEmpty)
    }
}
