import XCTest
@testable import PisakaCore

/// The viewer's paging and sort arithmetic, asserted directly rather than
/// through the model's three `await`s — every case here is one a real database
/// produces, and none of them needs a connection to reproduce.
final class DatabasePageTests: XCTestCase {

    // MARK: - Construction

    func testDefaultsToTheFirstPageWithAnUncountedTotal() {
        let page = DatabasePage()
        XCTAssertEqual(page.size, DatabasePage.defaultSize)
        XCTAssertEqual(page.index, 0)
        XCTAssertNil(page.totalRows)
        XCTAssertFalse(page.isCounted)
        XCTAssertNil(page.pageCount)
        XCTAssertNil(page.lastIndex)
        XCTAssertEqual(page.offset, 0)
    }

    func testSizeIsFlooredAtOneRow() {
        XCTAssertEqual(DatabasePage(size: 0).size, 1)
        XCTAssertEqual(DatabasePage(size: -10).size, 1)
    }

    func testConstructedIndexGoesThroughTheSameClamp() {
        XCTAssertEqual(DatabasePage(size: 10, index: -3).index, 0)
        XCTAssertEqual(DatabasePage(size: 10, index: 99, totalRows: 25).index, 2)
        XCTAssertEqual(DatabasePage(size: 10, index: 99).index, 99, "Uncounted, nothing to clamp against")
    }

    func testNegativeTotalIsFlooredAtZero() {
        let page = DatabasePage(size: 10, totalRows: -5)
        XCTAssertEqual(page.totalRows, 0)
    }

    // MARK: - Offsets and bounds

    func testOffsetIsTheIndexTimesTheSize() {
        var page = DatabasePage(size: 25, totalRows: 1_000)
        XCTAssertEqual(page.offset, 0)
        page.move(to: 3)
        XCTAssertEqual(page.offset, 75)
    }

    func testPageCountRoundsUpForAShortLastPage() {
        XCTAssertEqual(DatabasePage(size: 10, totalRows: 30).pageCount, 3)
        XCTAssertEqual(DatabasePage(size: 10, totalRows: 31).pageCount, 4)
        XCTAssertEqual(DatabasePage(size: 10, totalRows: 1).pageCount, 1)
    }

    func testAnEmptyTableStillHasOnePage() {
        let page = DatabasePage(size: 10, totalRows: 0)
        XCTAssertEqual(page.pageCount, 1)
        XCTAssertEqual(page.lastIndex, 0)
        XCTAssertFalse(page.hasPrevious)
        XCTAssertFalse(page.hasNext)
        XCTAssertNil(page.displayedRows(loaded: 0))
    }

    func testHasPreviousAndHasNextAcrossThreePages() {
        var page = DatabasePage(size: 10, totalRows: 25)
        XCTAssertFalse(page.hasPrevious)
        XCTAssertTrue(page.hasNext)

        page.move(to: 1)
        XCTAssertTrue(page.hasPrevious)
        XCTAssertTrue(page.hasNext)

        page.move(to: 2)
        XCTAssertTrue(page.hasPrevious)
        XCTAssertFalse(page.hasNext, "The last page is short but it is still the last")
    }

    func testHasNextIsFalseWhileTheTotalIsUnknown() {
        let page = DatabasePage(size: 10)
        XCTAssertFalse(page.hasNext, "Promising a next page before counting would be a guess")
        XCTAssertFalse(page.isCounted)
    }

    // MARK: - Moving

    func testMoveClampsAndReportsWhetherItMoved() {
        var page = DatabasePage(size: 10, totalRows: 25)
        XCTAssertTrue(page.move(to: 2))
        XCTAssertEqual(page.index, 2)

        XCTAssertFalse(page.move(to: 2), "Moving to the page already shown is not a move")
        XCTAssertFalse(page.move(to: 40), "Clamped back onto the page already shown")
        XCTAssertEqual(page.index, 2)

        XCTAssertTrue(page.move(to: -5))
        XCTAssertEqual(page.index, 0)
    }

    func testMoveDoesNotClampUpwardWhileUncounted() {
        var page = DatabasePage(size: 10)
        XCTAssertTrue(page.move(to: 7))
        XCTAssertEqual(page.index, 7)
    }

    func testCountThatShrankPullsAStaleIndexBack() {
        var page = DatabasePage(size: 10, index: 39, totalRows: 400)
        XCTAssertEqual(page.index, 39)

        XCTAssertTrue(page.setTotalRows(5), "A shrunken table moves the reader onto a page that exists")
        XCTAssertEqual(page.index, 0)
        XCTAssertEqual(page.pageCount, 1)
    }

    func testCountThatGrewLeavesTheIndexAlone() {
        var page = DatabasePage(size: 10, index: 2, totalRows: 30)
        XCTAssertFalse(page.setTotalRows(900))
        XCTAssertEqual(page.index, 2)
        XCTAssertEqual(page.pageCount, 90)
    }

    func testUncountingDropsTheTotalAndKeepsTheIndex() {
        var page = DatabasePage(size: 10, index: 2, totalRows: 100)
        XCTAssertFalse(page.setTotalRows(nil))
        XCTAssertNil(page.totalRows)
        XCTAssertEqual(page.index, 2)
    }

    func testResetReturnsToTheFirstPageAndForgetsTheTotal() {
        var page = DatabasePage(size: 10, index: 3, totalRows: 100)
        page.reset()
        XCTAssertEqual(page.index, 0)
        XCTAssertNil(page.totalRows)
    }

    // MARK: - What the footer says

    func testDisplayedRowsFollowWhatActuallyArrived() {
        var page = DatabasePage(size: 10, totalRows: 25)
        XCTAssertEqual(page.displayedRows(loaded: 10), 1...10)

        page.move(to: 2)
        XCTAssertEqual(page.displayedRows(loaded: 5), 21...25, "The last page is short and says so")
        XCTAssertNil(page.displayedRows(loaded: 0))
    }

    // MARK: - Sort state

    func testANewColumnSortsAscending() {
        let sorted = DatabaseSortState.toggled(nil, column: "name")
        XCTAssertEqual(sorted, DatabaseSortState(column: "name", direction: .ascending))
    }

    func testTheSameColumnFlips() {
        var sorted = DatabaseSortState.toggled(nil, column: "name")
        sorted = DatabaseSortState.toggled(sorted, column: "name")
        XCTAssertEqual(sorted, DatabaseSortState(column: "name", direction: .descending))

        sorted = DatabaseSortState.toggled(sorted, column: "name")
        XCTAssertEqual(sorted, DatabaseSortState(column: "name", direction: .ascending), "It flips; it never clears")
    }

    func testAnotherColumnStartsAscendingAgain() {
        let descending = DatabaseSortState(column: "name", direction: .descending)
        XCTAssertEqual(
            DatabaseSortState.toggled(descending, column: "price"),
            DatabaseSortState(column: "price", direction: .ascending)
        )
    }

    func testDirectionFlipsBothWays() {
        XCTAssertEqual(DatabaseSortState.Direction.ascending.flipped, .descending)
        XCTAssertEqual(DatabaseSortState.Direction.descending.flipped, .ascending)
        XCTAssertTrue(DatabaseSortState.Direction.ascending.isAscending)
        XCTAssertFalse(DatabaseSortState.Direction.descending.isAscending)
    }

    func testSelectingAnotherTableClearsTheSort() {
        let sorted = DatabaseSortState(column: "price", direction: .descending)
        XCTAssertNil(DatabaseSortState.carriedOver(sorted, from: "orders", to: "customers"))
        XCTAssertNil(DatabaseSortState.carriedOver(sorted, from: nil, to: "customers"))
    }

    func testReselectingTheSameTableKeepsTheSort() {
        let sorted = DatabaseSortState(column: "price", direction: .descending)
        XCTAssertEqual(DatabaseSortState.carriedOver(sorted, from: "orders", to: "orders"), sorted)
    }
}
