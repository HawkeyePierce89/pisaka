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

    /// `count(*)` is clamped from SQLite's `Int64`, so the total may legally be
    /// `Int.max`. The familiar `(total + size - 1) / size` adds before it divides
    /// and traps on exactly that input; the arithmetic here never adds to the
    /// total, so the ceiling is a number rather than a crash.
    func testAnEnormousTotalDoesNotOverflowThePageCount() {
        let page = DatabasePage(size: 200, totalRows: Int.max)
        XCTAssertEqual(page.pageCount, (Int.max - 1) / 200 + 1)
        XCTAssertEqual(page.lastIndex, (Int.max - 1) / 200)
        XCTAssertTrue(page.hasNext)
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

    /// The uncounted clamp still has a ceiling — the last index whose `offset` is
    /// an `Int` — so no index this type accepts can trap the multiplication the
    /// page query binds as its `OFFSET`. `pageCount` avoids the same class of
    /// overflow on the other side of the count.
    func testAnEnormousIndexDoesNotOverflowTheOffsetWhileUncounted() {
        var page = DatabasePage(size: 10)
        XCTAssertTrue(page.move(to: .max))
        XCTAssertEqual(page.index, Int.max / 10)
        XCTAssertEqual(page.offset, (Int.max / 10) * 10, "The offset is arithmetic, not a trap")

        let constructed = DatabasePage(size: 200, index: .max)
        XCTAssertEqual(constructed.index, Int.max / 200)
        XCTAssertEqual(constructed.offset, (Int.max / 200) * 200)
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
        let sorted = DatabaseSortState.toggled(nil, column: "name", index: 1)
        XCTAssertEqual(sorted, DatabaseSortState(column: "name", columnIndex: 1, direction: .ascending))
    }

    func testTheSameColumnFlips() {
        var sorted = DatabaseSortState.toggled(nil, column: "name", index: 1)
        sorted = DatabaseSortState.toggled(sorted, column: "name", index: 1)
        XCTAssertEqual(sorted, DatabaseSortState(column: "name", columnIndex: 1, direction: .descending))

        sorted = DatabaseSortState.toggled(sorted, column: "name", index: 1)
        XCTAssertEqual(
            sorted,
            DatabaseSortState(column: "name", columnIndex: 1, direction: .ascending),
            "It flips; it never clears"
        )
    }

    func testAnotherColumnStartsAscendingAgain() {
        let descending = DatabaseSortState(column: "name", columnIndex: 0, direction: .descending)
        XCTAssertEqual(
            DatabaseSortState.toggled(descending, column: "price", index: 1),
            DatabaseSortState(column: "price", columnIndex: 1, direction: .ascending)
        )
    }

    /// The case a name-keyed sort gets wrong: a view answering two columns both
    /// called `id`. Clicking the second must sort the second — start it
    /// ascending, not flip the first — and the two states must not compare equal,
    /// which is what keeps the arrow off the header nobody clicked.
    func testTwoColumnsSpellingTheSameNameSortIndependently() {
        let first = DatabaseSortState.toggled(nil, column: "id", index: 0)
        let second = DatabaseSortState.toggled(first, column: "id", index: 1)

        XCTAssertEqual(second, DatabaseSortState(column: "id", columnIndex: 1, direction: .ascending))
        XCTAssertNotEqual(first, second)

        let flipped = DatabaseSortState.toggled(second, column: "id", index: 1)
        XCTAssertEqual(flipped, DatabaseSortState(column: "id", columnIndex: 1, direction: .descending))
    }

    /// A position that does not exist is not a column: an ordinal reaching the
    /// statement must always name one, so it is floored at the first.
    func testANegativeColumnIndexIsFlooredAtTheFirstColumn() {
        XCTAssertEqual(DatabaseSortState(column: "name", columnIndex: -3).columnIndex, 0)
    }

    // MARK: - Sort survival across a refresh

    func testASortSurvivesAnAnswerThatStillCarriesItsColumn() {
        let sorted = DatabaseSortState(column: "price", columnIndex: 1)
        XCTAssertTrue(sorted.survives(columnNames: ["id", "price", "name"]))
    }

    func testASortDoesNotSurviveADroppedColumn() {
        let sorted = DatabaseSortState(column: "price", columnIndex: 1)
        XCTAssertFalse(sorted.survives(columnNames: ["id"]), "The position is gone")
        XCTAssertFalse(sorted.survives(columnNames: []))
    }

    /// The case the *position* alone gets wrong: the answer still has a column 1,
    /// but it is a different one. The name at the position is checked for exactly
    /// this — an ordinal still in range would otherwise order the next page by a
    /// column nobody asked about, under an arrow naming the one they chose.
    func testASortDoesNotSurviveAReorderedAnswer() {
        let sorted = DatabaseSortState(column: "price", columnIndex: 1)
        XCTAssertFalse(sorted.survives(columnNames: ["price", "id", "name"]))
    }

    func testDirectionFlipsBothWays() {
        XCTAssertEqual(DatabaseSortState.Direction.ascending.flipped, .descending)
        XCTAssertEqual(DatabaseSortState.Direction.descending.flipped, .ascending)
        XCTAssertTrue(DatabaseSortState.Direction.ascending.isAscending)
        XCTAssertFalse(DatabaseSortState.Direction.descending.isAscending)
    }

    func testSelectingAnotherTableClearsTheSort() {
        let sorted = DatabaseSortState(column: "price", columnIndex: 2, direction: .descending)
        XCTAssertNil(DatabaseSortState.carriedOver(sorted, from: "orders", to: "customers"))
        XCTAssertNil(DatabaseSortState.carriedOver(sorted, from: nil, to: "customers"))
    }

    func testReselectingTheSameTableKeepsTheSort() {
        let sorted = DatabaseSortState(column: "price", columnIndex: 2, direction: .descending)
        XCTAssertEqual(DatabaseSortState.carriedOver(sorted, from: "orders", to: "orders"), sorted)
    }
}
