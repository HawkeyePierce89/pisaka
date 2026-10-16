import XCTest
@testable import PisakaCore

final class TabNavigationRuleTests: XCTestCase {

    private func tabs(_ count: Int) -> [UUID] {
        (0..<count).map { _ in UUID() }
    }

    // MARK: - Adjacent

    func testForwardAndBackwardStepInTheMiddle() {
        let ids = tabs(3)
        XCTAssertEqual(TabNavigationRule.adjacent(in: ids, selected: ids[1], forward: true), ids[2])
        XCTAssertEqual(TabNavigationRule.adjacent(in: ids, selected: ids[1], forward: false), ids[0])
    }

    func testForwardWrapsFromTheLastTab() {
        let ids = tabs(3)
        XCTAssertEqual(TabNavigationRule.adjacent(in: ids, selected: ids[2], forward: true), ids[0])
    }

    func testBackwardWrapsFromTheFirstTab() {
        let ids = tabs(3)
        XCTAssertEqual(TabNavigationRule.adjacent(in: ids, selected: ids[0], forward: false), ids[2])
    }

    func testTwoTabsAlternate() {
        let ids = tabs(2)
        XCTAssertEqual(TabNavigationRule.adjacent(in: ids, selected: ids[0], forward: true), ids[1])
        XCTAssertEqual(TabNavigationRule.adjacent(in: ids, selected: ids[0], forward: false), ids[1])
    }

    func testASingleTabHasNothingToMoveTo() {
        let ids = tabs(1)
        XCTAssertNil(TabNavigationRule.adjacent(in: ids, selected: ids[0], forward: true))
        XCTAssertNil(TabNavigationRule.adjacent(in: ids, selected: ids[0], forward: false))
    }

    func testNoTabsHasNothingToMoveTo() {
        XCTAssertNil(TabNavigationRule.adjacent(in: [], selected: nil, forward: true))
        XCTAssertNil(TabNavigationRule.adjacent(in: [], selected: UUID(), forward: false))
    }

    func testAnUnknownSelectionAnswersTheFirstForwardAndTheLastBackward() {
        let ids = tabs(3)
        XCTAssertEqual(TabNavigationRule.adjacent(in: ids, selected: UUID(), forward: true), ids[0])
        XCTAssertEqual(TabNavigationRule.adjacent(in: ids, selected: UUID(), forward: false), ids[2])
    }

    func testANilSelectionAnswersTheFirstForwardAndTheLastBackward() {
        let ids = tabs(3)
        XCTAssertEqual(TabNavigationRule.adjacent(in: ids, selected: nil, forward: true), ids[0])
        XCTAssertEqual(TabNavigationRule.adjacent(in: ids, selected: nil, forward: false), ids[2])
    }

    // MARK: - Positional

    func testOneThroughEightAnswerTheNthTab() {
        let ids = tabs(12)
        for number in 1...8 {
            XCTAssertEqual(TabNavigationRule.positional(number, in: ids), ids[number - 1], "⌘\(number)")
        }
    }

    func testNineIsTheLastTabWithThreeTabs() {
        let ids = tabs(3)
        XCTAssertEqual(TabNavigationRule.positional(9, in: ids), ids[2])
    }

    func testNineIsTheLastTabWithTwelveTabs() {
        let ids = tabs(12)
        XCTAssertEqual(TabNavigationRule.positional(9, in: ids), ids[11])
    }

    func testAPositionPastTheCountAnswersNil() {
        let ids = tabs(3)
        XCTAssertNil(TabNavigationRule.positional(5, in: ids))
        XCTAssertNil(TabNavigationRule.positional(4, in: ids))
        XCTAssertEqual(TabNavigationRule.positional(3, in: ids), ids[2])
    }

    func testOneWithASingleTab() {
        let ids = tabs(1)
        XCTAssertEqual(TabNavigationRule.positional(1, in: ids), ids[0])
        XCTAssertEqual(TabNavigationRule.positional(9, in: ids), ids[0])
    }

    func testNumbersOutsideOneThroughNineAnswerNil() {
        let ids = tabs(12)
        for number in [-1, 0, 10, 11] {
            XCTAssertNil(TabNavigationRule.positional(number, in: ids), "⌘\(number)")
        }
    }

    func testNoTabsAnswersNil() {
        for number in 1...9 {
            XCTAssertNil(TabNavigationRule.positional(number, in: []), "⌘\(number)")
        }
    }
}
