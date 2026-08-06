import XCTest
@testable import PisakaCore

final class TerminalTabsTests: XCTestCase {
    func testClosingActiveMiddleTabSelectsLeftNeighbor() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(
            TerminalTabs.activeIDAfterClosing(b, order: [a, b, c], active: b),
            a
        )
    }

    func testClosingActiveFirstTabSelectsNewFirst() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(
            TerminalTabs.activeIDAfterClosing(a, order: [a, b, c], active: a),
            b
        )
    }

    func testClosingActiveLastTabSelectsLeftNeighbor() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(
            TerminalTabs.activeIDAfterClosing(c, order: [a, b, c], active: c),
            b
        )
    }

    func testClosingLastRemainingTabClearsSelection() {
        let a = UUID()
        XCTAssertNil(TerminalTabs.activeIDAfterClosing(a, order: [a], active: a))
    }

    func testClosingNonActiveTabLeavesSelectionUnchanged() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(
            TerminalTabs.activeIDAfterClosing(a, order: [a, b, c], active: b),
            b
        )
    }

    func testClosingUnknownIDLeavesSelectionUnchanged() {
        let a = UUID(), b = UUID()
        let unknown = UUID()
        XCTAssertEqual(
            TerminalTabs.activeIDAfterClosing(unknown, order: [a, b], active: a),
            a
        )
    }

    func testClosingWithNoActiveSelectionStaysNil() {
        let a = UUID(), b = UUID()
        XCTAssertNil(TerminalTabs.activeIDAfterClosing(a, order: [a, b], active: nil))
    }
}
