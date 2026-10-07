import XCTest
@testable import PisakaCore

final class PopoverSelectionTests: XCTestCase {
    func testInitSelectsTheFirstRow() {
        XCTAssertEqual(PopoverSelection(count: 4).selectedIndex, 0)
    }

    func testEmptyCountSelectsNothing() {
        let selection = PopoverSelection(count: 0)
        XCTAssertNil(selection.selectedIndex)
        XCTAssertNil(selection.movedDown().selectedIndex)
        XCTAssertNil(selection.movedUp().selectedIndex)
    }

    func testMovingDownClampsAtTheLastRow() {
        let selection = PopoverSelection(count: 3).movedDown().movedDown().movedDown().movedDown()
        XCTAssertEqual(selection.selectedIndex, 2)
    }

    func testMovingUpClampsAtTheFirstRow() {
        let selection = PopoverSelection(count: 3).movedUp()
        XCTAssertEqual(selection.selectedIndex, 0)
        XCTAssertEqual(PopoverSelection(count: 3).movedDown().movedDown().movedUp().selectedIndex, 1)
    }

    func testResetReturnsToTheFirstRowAfterAnyMove() {
        let moved = PopoverSelection(count: 5).movedDown().movedDown()
        XCTAssertEqual(moved.selectedIndex, 2)
        XCTAssertEqual(moved.reset(count: 5).selectedIndex, 0)
    }

    func testSelectingClampsToTheRows() {
        let selection = PopoverSelection(count: 4)
        XCTAssertEqual(selection.selecting(2).selectedIndex, 2)
        XCTAssertEqual(selection.selecting(-3).selectedIndex, 0)
        XCTAssertEqual(selection.selecting(99).selectedIndex, 3)
        XCTAssertEqual(selection.selecting(99).count, 4)
        XCTAssertNil(PopoverSelection(count: 0).selecting(2).selectedIndex)
    }

    func testResetToASmallerCountStaysInRange() {
        let reset = PopoverSelection(count: 5).movedDown().movedDown().movedDown().reset(count: 2)
        XCTAssertEqual(reset.count, 2)
        XCTAssertEqual(reset.selectedIndex, 0)
        XCTAssertEqual(reset.movedDown().movedDown().selectedIndex, 1)
        XCTAssertNil(reset.reset(count: 0).selectedIndex)
    }
}
