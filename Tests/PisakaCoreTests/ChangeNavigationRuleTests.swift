import XCTest
@testable import PisakaCore

/// `ChangeNavigationRule.targetLine(hunks:caretLine:direction:)` — the stops,
/// the strictly-past-the-caret search and its wrap.
final class ChangeNavigationRuleTests: XCTestCase {

    // Stops: 2 (modified 2..<4), 6 (deleted after line 6), 9 (added 9..<10).
    private let hunks = [
        ChangeHunk(kind: .modified, newLines: 2..<4, oldLines: 2..<3),
        ChangeHunk(kind: .deleted, newLines: 7..<7, oldLines: 6..<8),
        ChangeHunk(kind: .added, newLines: 9..<10, oldLines: 10..<10),
    ]

    private func target(_ caret: Int, _ direction: DiagnosticNavigationDirection) -> Int? {
        ChangeNavigationRule.targetLine(hunks: hunks, caretLine: caret, direction: direction)
    }

    func testStopsAreFirstLinesAndAnchorsAscending() {
        XCTAssertEqual(ChangeNavigationRule.stops(in: hunks), [2, 6, 9])
    }

    func testNextWrapsPastTheLastStop() {
        XCTAssertEqual(target(0, .next), 2)
        XCTAssertEqual(target(9, .next), 2)
        XCTAssertEqual(target(20, .next), 2)
    }

    func testPreviousWrapsBeforeTheFirstStop() {
        XCTAssertEqual(target(10, .previous), 9)
        XCTAssertEqual(target(2, .previous), 9)
        XCTAssertEqual(target(0, .previous), 9)
    }

    func testCaretInsideAHunk() {
        XCTAssertEqual(target(3, .next), 6)
        XCTAssertEqual(target(3, .previous), 2)
    }

    func testCaretOnAHunksFirstLineMovesOn() {
        XCTAssertEqual(target(2, .next), 6)
        XCTAssertEqual(target(9, .previous), 6)
    }

    func testCaretOnADeletionsAnchorMovesOn() {
        XCTAssertEqual(target(6, .next), 9)
        XCTAssertEqual(target(6, .previous), 2)
        XCTAssertEqual(target(5, .next), 6)
        XCTAssertEqual(target(7, .previous), 6)
    }

    func testDeletionBeforeLineOneStopsOnLineZero() {
        let before = [
            ChangeHunk(kind: .deleted, newLines: 0..<0, oldLines: 0..<2),
            ChangeHunk(kind: .modified, newLines: 4..<5, oldLines: 6..<7),
        ]
        XCTAssertEqual(ChangeNavigationRule.stops(in: before), [0, 4])
        XCTAssertEqual(ChangeNavigationRule.targetLine(hunks: before, caretLine: 4, direction: .next), 0)
        XCTAssertEqual(ChangeNavigationRule.targetLine(hunks: before, caretLine: 2, direction: .previous), 0)
    }

    func testStopsAreDistinct() {
        // A deletion before line 1 and a strip on line 0 share stop 0.
        let shared = [
            ChangeHunk(kind: .deleted, newLines: 0..<0, oldLines: 0..<1),
            ChangeHunk(kind: .added, newLines: 0..<1, oldLines: 1..<1),
        ]
        XCTAssertEqual(ChangeNavigationRule.stops(in: shared), [0])
        XCTAssertEqual(ChangeNavigationRule.targetLine(hunks: shared, caretLine: 0, direction: .next), 0)
    }

    func testNoHunksIsNil() {
        XCTAssertNil(ChangeNavigationRule.targetLine(hunks: [], caretLine: 3, direction: .next))
        XCTAssertNil(ChangeNavigationRule.targetLine(hunks: [], caretLine: 3, direction: .previous))
    }
}
