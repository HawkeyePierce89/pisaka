import XCTest
import Foundation
@testable import PisakaCore

final class ColumnSelectionEngineTests: XCTestCase {

    // MARK: - Bounds Tests

    func testBounds_NormalizesCoordinates() {
        let bounds = ColumnSelectionEngine.bounds(
            anchor: CGPoint(x: 100, y: 200),
            head: CGPoint(x: 50, y: 150)
        )
        XCTAssertEqual(bounds.left, 50)
        XCTAssertEqual(bounds.right, 100)
        XCTAssertEqual(bounds.top, 150)
        XCTAssertEqual(bounds.bottom, 200)
        XCTAssertEqual(bounds.rect, CGRect(x: 50, y: 150, width: 50, height: 50))
    }

    /// All four corner orders normalize to the same rectangle.
    func testBounds_AllFourCornerOrders() {
        let expected = ColumnSelectionEngine.bounds(
            anchor: CGPoint(x: 10, y: 20), head: CGPoint(x: 30, y: 40)) // down-right
        let downLeft = ColumnSelectionEngine.bounds(
            anchor: CGPoint(x: 30, y: 20), head: CGPoint(x: 10, y: 40))
        let upRight = ColumnSelectionEngine.bounds(
            anchor: CGPoint(x: 10, y: 40), head: CGPoint(x: 30, y: 20))
        let upLeft = ColumnSelectionEngine.bounds(
            anchor: CGPoint(x: 30, y: 40), head: CGPoint(x: 10, y: 20))
        XCTAssertEqual(expected.rect, CGRect(x: 10, y: 20, width: 20, height: 20))
        XCTAssertEqual(downLeft, expected)
        XCTAssertEqual(upRight, expected)
        XCTAssertEqual(upLeft, expected)
    }

    /// A purely vertical drag yields a zero-width rectangle, a purely horizontal
    /// one a zero-height rectangle — neither is normalized away.
    func testBounds_DegenerateDrags() {
        let vertical = ColumnSelectionEngine.bounds(
            anchor: CGPoint(x: 10, y: 40), head: CGPoint(x: 10, y: 20))
        XCTAssertEqual(vertical.rect, CGRect(x: 10, y: 20, width: 0, height: 20))

        let horizontal = ColumnSelectionEngine.bounds(
            anchor: CGPoint(x: 30, y: 20), head: CGPoint(x: 10, y: 20))
        XCTAssertEqual(horizontal.rect, CGRect(x: 10, y: 20, width: 20, height: 0))
    }

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

    /// Offsets far outside the line and the text — negative or past the end —
    /// clamp into the line's content instead of trapping.
    func testRanges_OffsetsOutsideTextBoundsAreClamped() {
        let text = "abc\ndef" as NSString
        let lines = [
            ColumnSelectionLine(lineRange: NSRange(location: 0, length: 4), leftOffset: -5, rightOffset: 100),
            ColumnSelectionLine(lineRange: NSRange(location: 4, length: 3), leftOffset: -1, rightOffset: 999),
        ]

        let ranges = ColumnSelectionEngine.ranges(for: lines, in: text)
        XCTAssertEqual(ranges, [
            NSRange(location: 0, length: 3), // "abc" — clamped to [0, contentEnd 3]
            NSRange(location: 4, length: 3), // "def" — clamped to [4, contentEnd 7]
        ])
    }

    /// A line range lying outside the text (a stale layout answer) is skipped
    /// rather than trapping.
    func testRanges_LineRangeOutsideTextIsSkipped() {
        let text = "abc" as NSString
        let lines = [
            ColumnSelectionLine(lineRange: NSRange(location: 10, length: 4), leftOffset: 10, rightOffset: 12),
            ColumnSelectionLine(lineRange: NSRange(location: 0, length: 3), leftOffset: 1, rightOffset: 2),
        ]

        let ranges = ColumnSelectionEngine.ranges(for: lines, in: text)
        XCTAssertEqual(ranges, [NSRange(location: 1, length: 1)])
    }

    func testRanges_DeduplicatesExactMatches() {
        let text = "abc\ndef" as NSString
        let lines = [
            ColumnSelectionLine(lineRange: NSRange(location: 0, length: 4), leftOffset: 4, rightOffset: 4),
            ColumnSelectionLine(lineRange: NSRange(location: 0, length: 4), leftOffset: 4, rightOffset: 4),
        ]
        let ranges = ColumnSelectionEngine.ranges(for: lines, in: text)
        XCTAssertEqual(ranges, [
            NSRange(location: 3, length: 0) // Trims terminator, so 4 clamps to 3
        ])
    }
}
