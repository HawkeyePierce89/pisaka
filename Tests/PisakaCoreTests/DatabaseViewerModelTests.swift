import XCTest
@testable import PisakaCore

/// The viewer model against `ScriptedDatabaseService`: what each user action
/// sends, what it publishes, what it discards, and what it leaves alone when
/// something fails.
///
/// Every statement asserted here is compared against `DatabaseQuery`'s own text
/// rather than a literal, so a change to the SQL moves both halves together —
/// `DatabaseQueryTests` is where the text itself is pinned byte-for-byte.
@MainActor
final class DatabaseViewerModelTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/tmp/Project/app.sqlite")

    // MARK: - The happy path

    func testLoadOpensTheFileAndListsTablesAndViews() async {
        let service = ScriptedDatabaseService()
        serveListing(on: service, entries: [("items", "table"), ("recent", "view")])
        let model = DatabaseViewerModel(fileURL: url, service: service)

        await model.load()

        XCTAssertEqual(service.openedURLs, [url])
        XCTAssertEqual(
            model.entries,
            [
                DatabaseTableEntry(name: "items", kind: .table, definition: "CREATE TABLE items(a)"),
                DatabaseTableEntry(name: "recent", kind: .view, definition: "CREATE VIEW recent(a)"),
            ]
        )
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoadingEntries)
        XCTAssertNil(model.selectedTable)
    }

    func testASecondLoadRefreshesTheListingWithoutReopeningTheFile() async {
        let service = ScriptedDatabaseService()
        serveListing(on: service, entries: [("items", "table")])
        let model = DatabaseViewerModel(fileURL: url, service: service)

        await model.load()
        await model.load()

        XCTAssertEqual(service.openedURLs, [url], "A connection is one file, opened once")
        XCTAssertEqual(service.count(for: DatabaseQuery.tableListing.sql), 2)
    }

    func testSelectLoadsTheSchemaTheCountAndTheFirstPage() async {
        let service = ScriptedDatabaseService()
        serveListing(on: service, entries: [("items", "table")])
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")], [.integer(2), .null]])
        let model = DatabaseViewerModel(fileURL: url, service: service, pageSize: 2)

        await model.load()
        await model.select(table: "items")

        XCTAssertEqual(model.selectedTable, "items")
        XCTAssertEqual(model.columns.map(\.name), ["id", "label"])
        XCTAssertEqual(model.columns.first?.primaryKeyPosition, 1)
        XCTAssertEqual(model.gridColumns, ["id", "label"])
        XCTAssertEqual(model.rows, [[.integer(1), .text("one")], [.integer(2), .null]])
        XCTAssertEqual(model.page.totalRows, 5)
        XCTAssertEqual(model.page.index, 0)
        XCTAssertEqual(model.displayedRows, 1...2)
        XCTAssertEqual(model.selectedEntry?.kind, .table)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoadingRows)

        XCTAssertEqual(
            service.runSQL,
            [
                DatabaseQuery.tableListing.sql,
                DatabaseQuery.columnSchema(table: "items").sql,
                DatabaseQuery.rowCount(table: "items").sql,
                pageSQL(table: "items"),
            ]
        )
    }

    // MARK: - Paging

    func testPagingForwardAndBackBindsItsLimitAndOffset() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .null]])
        let model = await loadedModel(service)
        await model.select(table: "items")

        await model.goToPage(1)
        XCTAssertEqual(model.page.index, 1)
        XCTAssertTrue(model.page.hasPrevious)
        XCTAssertTrue(model.page.hasNext)

        await model.goToPage(2)
        XCTAssertEqual(model.page.index, 2)
        XCTAssertFalse(model.page.hasNext)

        await model.goToPage(0)

        let bound = service.statements(for: pageSQL(table: "items")).map(\.parameters)
        XCTAssertEqual(
            bound,
            [
                [.integer(2), .integer(0)],
                [.integer(2), .integer(2)],
                [.integer(2), .integer(4)],
                [.integer(2), .integer(0)],
            ]
        )
    }

    func testEveryPageLoadIsExactlyOnePageSizedStatement() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .null]])
        let model = await loadedModel(service)

        await model.select(table: "items")
        await model.goToPage(1)

        let selects = service.runSQL.filter { $0.hasPrefix("SELECT * FROM") }
        XCTAssertEqual(selects.count, 2)
        for statement in service.statements(for: pageSQL(table: "items")) {
            XCTAssertTrue(statement.sql.contains("LIMIT ? OFFSET ?"), "A page is never an unbounded select")
            XCTAssertEqual(statement.parameters.first, .integer(2))
        }
    }

    func testMovingToThePageAlreadyShownAsksNothing() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .null]])
        let model = await loadedModel(service)
        await model.select(table: "items")

        await model.goToPage(0)
        await model.goToPage(-4)
        XCTAssertEqual(service.count(for: pageSQL(table: "items")), 1)

        await model.goToPage(99)
        XCTAssertEqual(model.page.index, 2, "Clamped onto the last page that exists")
        XCTAssertEqual(service.count(for: pageSQL(table: "items")), 2)
    }

    // MARK: - Sorting

    func testSortToggleRequeriesWithTheNewOrderAndResetsToTheFirstPage() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .null]])
        servePage(on: service, table: "items", orderBy: "label", ascending: true, rows: [[.integer(3), .text("a")]])
        servePage(on: service, table: "items", orderBy: "label", ascending: false, rows: [[.integer(9), .text("z")]])
        let model = await loadedModel(service)
        await model.select(table: "items")
        await model.goToPage(2)

        await model.toggleSort(column: "label")
        XCTAssertEqual(model.sort, DatabaseSortState(column: "label", direction: .ascending))
        XCTAssertEqual(model.page.index, 0, "A new ordering makes the old page number meaningless")
        XCTAssertEqual(model.rows, [[.integer(3), .text("a")]])
        XCTAssertEqual(model.page.totalRows, 5, "An ORDER BY does not change how many rows there are")
        XCTAssertEqual(service.count(for: DatabaseQuery.rowCount(table: "items").sql), 1)

        await model.toggleSort(column: "label")
        XCTAssertEqual(model.sort, DatabaseSortState(column: "label", direction: .descending))
        XCTAssertEqual(model.rows, [[.integer(9), .text("z")]])

        XCTAssertEqual(
            Array(service.runSQL.suffix(2)),
            [
                pageSQL(table: "items", orderBy: "label", ascending: true),
                pageSQL(table: "items", orderBy: "label", ascending: false),
            ]
        )
    }

    func testSortingWithNothingSelectedAsksNothing() async {
        let service = ScriptedDatabaseService()
        let model = DatabaseViewerModel(fileURL: url, service: service)

        await model.toggleSort(column: "label")
        await model.goToPage(3)

        XCTAssertTrue(service.runSQL.isEmpty)
        XCTAssertNil(model.sort)
    }

    // MARK: - Moving between tables

    func testSelectingAnotherTableClearsTheSortTheRowsAndThePage() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .null]])
        servePage(on: service, table: "items", orderBy: "label", ascending: true, rows: [[.integer(3), .text("a")]])
        serveSchema(on: service, table: "orders", columns: ["ref"])
        serveCount(on: service, table: "orders", total: 1)
        servePage(on: service, table: "orders", columns: ["ref"], rows: [[.text("x")]])
        let model = await loadedModel(service)

        await model.select(table: "items")
        await model.toggleSort(column: "label")
        await model.select(table: "orders")

        XCTAssertNil(model.sort, "A column name means nothing in another table")
        XCTAssertEqual(model.gridColumns, ["ref"])
        XCTAssertEqual(model.rows, [[.text("x")]])
        XCTAssertEqual(model.page.index, 0)
        XCTAssertEqual(model.page.totalRows, 1)
    }

    func testReselectingTheSameTableKeepsTheSort() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .null]])
        servePage(on: service, table: "items", orderBy: "label", ascending: true, rows: [[.integer(3), .text("a")]])
        let model = await loadedModel(service)

        await model.select(table: "items")
        await model.toggleSort(column: "label")
        await model.select(table: "items")

        XCTAssertEqual(model.sort, DatabaseSortState(column: "label", direction: .ascending))
        XCTAssertEqual(model.rows, [[.integer(3), .text("a")]], "A refresh re-asks the sorted page")
    }

    // MARK: - Failures

    func testAFileThatIsNotADatabaseLandsInTheErrorState() async {
        let service = ScriptedDatabaseService()
        service.failOpen(with: DatabaseError.notADatabase(message: "file is not a database"))
        serveListing(on: service, entries: [("items", "table")])
        let model = DatabaseViewerModel(fileURL: url, service: service)

        await model.load()

        XCTAssertEqual(model.errorMessage, "file is not a database", "SQLite's own words, not ours")
        XCTAssertTrue(model.entries.isEmpty, "An unreadable file is an error, not a database with no tables")
        XCTAssertFalse(model.isLoadingEntries)
        XCTAssertTrue(service.runSQL.isEmpty, "Nothing is run against a connection that did not open")
    }

    func testAFailedOpenIsRetriedByTheNextLoad() async {
        let service = ScriptedDatabaseService()
        service.failOpen(with: DatabaseError.busy(message: "database is locked"))
        serveListing(on: service, entries: [("items", "table")])
        let model = DatabaseViewerModel(fileURL: url, service: service)

        await model.load()
        XCTAssertEqual(model.errorMessage, "database is locked")

        service.clearOpenFailure()
        await model.load()

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.entries.map(\.name), ["items"])
        XCTAssertEqual(service.openedURLs, [url, url])
    }

    func testAFailureMidPagingSurfacesItsMessageAndLeavesThePageInPlace() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")]])
        let model = await loadedModel(service)
        await model.select(table: "items")

        service.fail(pageSQL(table: "items"), with: DatabaseError.busy(message: "database is locked"))
        await model.goToPage(1)

        XCTAssertEqual(model.errorMessage, "database is locked")
        XCTAssertEqual(model.rows, [[.integer(1), .text("one")]], "The page the reader was reading stays on screen")
        XCTAssertEqual(model.gridColumns, ["id", "label"])
        XCTAssertFalse(model.isLoadingRows)
        XCTAssertEqual(
            model.page.index,
            0,
            "The failed move is put back: the footer is drawn from the page index, so an index that "
                + "advanced while the rows did not would count page 2 over page 1's rows"
        )
    }

    func testAFailedSortPutsBackTheColumnAndThePage() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")]])
        servePage(on: service, table: "items", rows: [[.integer(3), .text("three")]])
        let model = await loadedModel(service)
        await model.select(table: "items")
        await model.goToPage(1)

        service.fail(
            pageSQL(table: "items", orderBy: "label"),
            with: DatabaseError.busy(message: "database is locked")
        )
        await model.toggleSort(column: "label")

        XCTAssertEqual(model.errorMessage, "database is locked")
        XCTAssertNil(model.sort, "The header arrow must not claim an order the rows are not in")
        XCTAssertEqual(model.page.index, 1, "The sort's page reset is put back with it")
        XCTAssertEqual(model.rows, [[.integer(3), .text("three")]])
    }

    func testAMalformedCountIsRefusedRatherThanReadAsZero() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        service.serve(DatabaseQuery.rowCount(table: "items").sql, columns: ["count(*)"], rows: [[.text("many")]])
        servePage(on: service, table: "items", rows: [[.integer(1), .null]])
        let model = await loadedModel(service)

        await model.select(table: "items")

        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.page.totalRows)
        XCTAssertTrue(model.rows.isEmpty, "The page after the refusal was never asked for")
        XCTAssertEqual(service.count(for: pageSQL(table: "items")), 0)
    }

    func testAFailedRefreshKeepsTheListingItAlreadyHas() async {
        let service = ScriptedDatabaseService()
        serveListing(on: service, entries: [("items", "table"), ("recent", "view")])
        let model = DatabaseViewerModel(fileURL: url, service: service)
        await model.load()
        let listed = model.entries

        service.fail(DatabaseQuery.tableListing.sql, with: DatabaseError.busy(message: "database is locked"))
        await model.load()

        XCTAssertEqual(model.errorMessage, "database is locked")
        XCTAssertEqual(
            model.entries,
            listed,
            "A failure never blanks a good answer: emptying the sidebar on a transient lock would drop "
                + "the reader out of the table they were reading, with the message explaining nothing"
        )
        XCTAssertFalse(model.isLoadingEntries)
    }

    func testAFailedMoveToAnotherTableShowsTheNewNameOverAnEmptyGrid() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")]])
        service.fail(
            DatabaseQuery.columnSchema(table: "orders").sql,
            with: DatabaseError.sqlError(message: "no such table: orders")
        )
        let model = await loadedModel(service)
        await model.select(table: "items")
        await model.toggleSort(column: "label")

        await model.select(table: "orders")

        // The one deliberate exception to "a failure never blanks a good answer":
        // leaving items' rows under orders' name is the lie the error message
        // does not correct.
        XCTAssertEqual(model.errorMessage, "no such table: orders")
        XCTAssertEqual(model.selectedTable, "orders")
        XCTAssertTrue(model.rows.isEmpty, "The previous table's rows are not this table's rows")
        XCTAssertTrue(model.gridColumns.isEmpty)
        XCTAssertTrue(model.columns.isEmpty)
        XCTAssertNil(model.sort, "A column name means nothing in another table")
        XCTAssertEqual(model.page.index, 0)
        XCTAssertNil(model.page.totalRows)
    }

    func testAMalformedListingIsRefused() async {
        let service = ScriptedDatabaseService()
        service.serve(DatabaseQuery.tableListing.sql, columns: ["title"], rows: [[.text("items")]])
        let model = DatabaseViewerModel(fileURL: url, service: service)

        await model.load()

        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.entries.isEmpty)
    }

    // MARK: - Superseded work

    func testASupersededPageLoadPublishesNothing() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("stale")]])
        serveSchema(on: service, table: "orders", columns: ["ref"])
        serveCount(on: service, table: "orders", total: 1)
        servePage(on: service, table: "orders", columns: ["ref"], rows: [[.text("fresh")]])

        let gate = Gate()
        service.hold(pageSQL(table: "items"), on: gate)
        let model = await loadedModel(service)

        let held = Task { await model.select(table: "items") }
        await waitUntil { gate.reached }

        // The first selection is suspended inside its page read; the second one
        // runs to completion and publishes over it.
        await model.select(table: "orders")
        XCTAssertEqual(model.rows, [[.text("fresh")]])

        gate.release()
        await held.value

        XCTAssertEqual(model.selectedTable, "orders")
        XCTAssertEqual(model.rows, [[.text("fresh")]], "The superseded page never lands")
        XCTAssertEqual(model.gridColumns, ["ref"])
        XCTAssertEqual(model.page.totalRows, 1)
    }

    func testTheLoadingFlagsAreRaisedWhileAReadIsInFlight() async {
        let service = ScriptedDatabaseService()
        serveListing(on: service, entries: [("items", "table")])
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .null]])

        let listingGate = Gate()
        service.hold(DatabaseQuery.tableListing.sql, on: listingGate)
        let model = DatabaseViewerModel(fileURL: url, service: service, pageSize: 2)

        let listing = Task { await model.load() }
        await waitUntil { listingGate.reached }
        // The flag the footer's spinner is drawn from, observed raised rather
        // than only observed cleared: asserting the cleared state alone stays
        // green with every `= true` deleted.
        XCTAssertTrue(model.isLoadingEntries)
        listingGate.release()
        await listing.value
        XCTAssertFalse(model.isLoadingEntries)

        let pageGate = Gate()
        service.hold(pageSQL(table: "items"), on: pageGate)
        let rows = Task { await model.select(table: "items") }
        await waitUntil { pageGate.reached }
        XCTAssertTrue(model.isLoadingRows)
        pageGate.release()
        await rows.value
        XCTAssertFalse(model.isLoadingRows)
    }

    func testAListingInFlightWhenTheTabClosesPublishesNothing() async {
        let service = ScriptedDatabaseService()
        serveListing(on: service, entries: [("stale", "table")])
        let gate = Gate()
        service.hold(DatabaseQuery.tableListing.sql, on: gate)
        let model = DatabaseViewerModel(fileURL: url, service: service)

        let held = Task { await model.load() }
        await waitUntil { gate.reached }

        // Closing bumps both tokens, which is what strands the listing already
        // in flight — a tab that is gone must not publish into itself.
        await model.close()

        gate.release()
        await held.value

        XCTAssertTrue(model.entries.isEmpty, "The superseded listing never lands")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoadingEntries)
    }

    func testAFailureThatArrivesSupersededPublishesNoMessage() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        service.fail(pageSQL(table: "items"), with: DatabaseError.busy(message: "database is locked"))
        serveSchema(on: service, table: "orders", columns: ["ref"])
        serveCount(on: service, table: "orders", total: 1)
        servePage(on: service, table: "orders", columns: ["ref"], rows: [[.text("fresh")]])

        let gate = Gate()
        service.hold(pageSQL(table: "items"), on: gate)
        let model = await loadedModel(service)

        let held = Task { await model.select(table: "items") }
        await waitUntil { gate.reached }
        await model.select(table: "orders")
        gate.release()
        await held.value

        XCTAssertNil(model.errorMessage, "A superseded load's failure is not the current tab's failure")
        XCTAssertEqual(model.rows, [[.text("fresh")]])
    }

    // MARK: - Closing

    func testCloseClosesTheConnectionExactlyOnce() async {
        let service = ScriptedDatabaseService()
        serveListing(on: service, entries: [("items", "table")])
        let model = DatabaseViewerModel(fileURL: url, service: service)
        await model.load()

        await model.close()
        await model.close()

        XCTAssertEqual(service.closeCount, 1, "The tab owner closes on tab close and again at termination")
        XCTAssertFalse(service.isOpen)
    }

    func testNothingIsAskedAfterClose() async {
        let service = ScriptedDatabaseService()
        serveListing(on: service, entries: [("items", "table")])
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 1)
        servePage(on: service, table: "items", rows: [[.integer(1), .null]])
        let model = DatabaseViewerModel(fileURL: url, service: service)
        await model.load()
        await model.select(table: "items")
        let asked = service.runSQL.count

        await model.close()
        await model.load()
        await model.select(table: "items")
        await model.goToPage(1)
        await model.toggleSort(column: "label")

        XCTAssertEqual(service.runSQL.count, asked, "A closed tab runs nothing")
        XCTAssertFalse(model.isLoadingRows)
        XCTAssertFalse(model.isLoadingEntries)
    }

    // MARK: - The lifetime the app drives

    // `DatabaseViewerTabs` (macOS, untested by convention) creates one model the
    // first time a viewer tab is shown, hands the same one back on every later
    // selection, and closes it when the tab goes away. Each of those three is a
    // claim about *this* type, and each is asserted here.

    func testAFreshModelTouchesNothingUntilItIsShown() async {
        let service = ScriptedDatabaseService()
        serveListing(on: service, entries: [("items", "table")])

        _ = DatabaseViewerModel(fileURL: url, service: service)

        XCTAssertEqual(service.openedURLs, [], "Constructing a tab's model must not open the file")
        XCTAssertEqual(service.runSQL, [])
        XCTAssertFalse(service.isOpen)
    }

    func testReselectingTheTabReusesTheModelAndItsConnection() async {
        let service = ScriptedDatabaseService()
        let model = await loadedModel(service, tables: [("items", "table")])
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 4)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")], [.integer(2), .text("two")]])
        servePage(
            on: service,
            table: "items",
            orderBy: "label",
            rows: [[.integer(2), .text("two")], [.integer(1), .text("one")]]
        )
        await model.select(table: "items")
        await model.toggleSort(column: "label")
        await model.goToPage(1)

        // What re-selecting the tab does: the surface reappears and refreshes the
        // listing. It must not be a second connection, and it must not be a reset.
        await model.load()

        XCTAssertEqual(service.openedURLs, [url], "A re-selected tab reuses the model it already had")
        XCTAssertEqual(model.selectedTable, "items")
        XCTAssertEqual(model.sort, DatabaseSortState(column: "label", direction: .ascending))
        XCTAssertEqual(model.page.index, 1)
        XCTAssertEqual(model.rows, [[.integer(2), .text("two")], [.integer(1), .text("one")]])
    }

    func testATabClosedBeforeItWasEverShownStillReleasesItsService() async {
        let service = ScriptedDatabaseService()
        let model = DatabaseViewerModel(fileURL: url, service: service)

        await model.close()

        XCTAssertEqual(service.closeCount, 1, "The owner closes every model it holds, opened or not")
        XCTAssertEqual(service.openedURLs, [], "And closing one must not open it on the way out")
    }

    func testAClosedTabsModelNeverReopensTheFile() async {
        let service = ScriptedDatabaseService()
        serveListing(on: service, entries: [("items", "table")])
        let model = DatabaseViewerModel(fileURL: url, service: service)
        await model.load()
        await model.close()

        // A view still holding the model for one more frame after the tab closed.
        await model.load()

        XCTAssertEqual(service.openedURLs, [url], "A closed tab is closed for good")
        XCTAssertEqual(service.closeCount, 1)
    }

    // MARK: - Rolling back onto the rows on screen

    func testAFailedRefreshOfTheSameTablePutsBackThePageTheRowsBelongTo() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")]])
        let model = await loadedModel(service)
        await model.select(table: "items")
        await model.goToPage(1)

        // The table shrank to one page and the re-read of it fails: the count
        // lands (re-clamping the index to 0) and the page statement does not.
        serveCount(on: service, table: "items", total: 1)
        service.fail(pageSQL(table: "items"), with: DatabaseError.busy(message: "database is locked"))
        await model.select(table: "items")

        XCTAssertEqual(model.errorMessage, "database is locked")
        XCTAssertEqual(model.rows, [[.integer(1), .text("one")]], "A failure never blanks a good answer")
        XCTAssertEqual(
            model.page.index,
            1,
            "The refresh applied a new count before the page it could not read; leaving it there would have "
                + "the footer counting one page over another page's rows"
        )
        XCTAssertEqual(model.page.totalRows, 5, "The total is the one the rows on screen were counted against")
    }

    func testAFailureAfterASupersededMoveRestoresThePageTheGridIsActuallyShowing() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 6)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")]])
        let model = await loadedModel(service)
        await model.select(table: "items")

        // Two overlapping moves, both held inside the page read: the first is
        // superseded (it publishes nothing and undoes nothing) and the second
        // fails. Page 2 was never drawn, so putting *it* back would have the
        // footer counting a page nobody ever saw.
        let gate = Gate()
        service.fail(pageSQL(table: "items"), with: DatabaseError.busy(message: "database is locked"))
        service.hold(pageSQL(table: "items"), on: gate)
        let first = Task { await model.goToPage(1) }
        await waitUntil { service.count(for: self.pageSQL(table: "items")) == 2 }
        let second = Task { await model.goToPage(2) }
        await waitUntil { service.count(for: self.pageSQL(table: "items")) == 3 }
        gate.release()
        gate.release()
        await first.value
        await second.value

        XCTAssertEqual(model.errorMessage, "database is locked")
        XCTAssertEqual(model.rows, [[.integer(1), .text("one")]])
        XCTAssertEqual(
            model.page.index,
            0,
            "Page 1 is what the rows on screen are; the superseded move's target was never published"
        )
    }

    // MARK: - Whose message it is

    func testARefreshedListingDoesNotClearAPageLoadsFailure() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")]])
        let model = await loadedModel(service)
        await model.select(table: "items")

        service.fail(pageSQL(table: "items"), with: DatabaseError.busy(message: "database is locked"))
        await model.goToPage(1)
        await model.load()

        XCTAssertEqual(
            model.errorMessage,
            "database is locked",
            "The listing refreshes every time the tab is shown; letting its success speak for a page load "
                + "would take away the one sentence explaining the rows on screen"
        )
    }

    func testASuccessfulPageLoadClearsThePageLoadsOwnFailure() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        service.fail(
            pageSQL(table: "items"),
            once: DatabaseError.busy(message: "database is locked"),
            thenServe: DatabaseResultSet(columnNames: ["id", "label"], rows: [[.integer(1), .text("one")]])
        )
        let model = await loadedModel(service)

        await model.select(table: "items")
        XCTAssertEqual(model.errorMessage, "database is locked")

        await model.select(table: "items")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.rows, [[.integer(1), .text("one")]])
    }

    // MARK: - Reconnecting

    func testReloadReopensTheFileAndReReadsTheSelectedTable() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("before")]])
        let model = await loadedModel(service)
        await model.select(table: "items")
        await model.goToPage(1)

        servePage(on: service, table: "items", rows: [[.integer(9), .text("after")]])
        await model.reload()

        XCTAssertEqual(service.closeCount, 1, "The stale handle is released before the new one is opened")
        XCTAssertEqual(
            service.openedURLs,
            [url, url],
            "git renames a new file over the old one; the handle must follow"
        )
        XCTAssertEqual(model.rows, [[.integer(9), .text("after")]])
        XCTAssertEqual(model.page.index, 1, "A re-selection is a refresh: the tab keeps its place")
        XCTAssertNil(model.errorMessage)
    }

    func testReloadDropsASelectionTheNewDatabaseNoLongerHolds() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")]])
        let model = await loadedModel(service)
        await model.select(table: "items")

        serveListing(on: service, entries: [("orders", "table")])
        await model.reload()

        XCTAssertNil(model.selectedTable, "A name the new database does not answer to is not a selection")
        XCTAssertTrue(model.rows.isEmpty, "Leaving the old table's rows under no name at all is the same lie")
        XCTAssertTrue(model.columns.isEmpty)
        XCTAssertNil(model.sort)
        XCTAssertNil(model.page.totalRows)
    }

    func testAReloadThatCannotReopenLeavesTheTabAsItWas() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")]])
        let model = await loadedModel(service)
        await model.select(table: "items")

        service.failOpen(with: DatabaseError.cannotOpen(message: "unable to open database file"))
        await model.reload()

        XCTAssertEqual(model.errorMessage, "unable to open database file")
        XCTAssertEqual(model.rows, [[.integer(1), .text("one")]], "Nothing was read, so nothing is replaced")
        XCTAssertEqual(model.selectedTable, "items")
        XCTAssertFalse(model.isLoadingRows)
    }

    func testAReloadReopensTheURLItIsGivenRatherThanTheOneTheTabWasOpenedAt() async {
        let service = ScriptedDatabaseService()
        let model = await loadedModel(service)
        let renamed = url.deletingLastPathComponent().appendingPathComponent("renamed.sqlite")

        // A rename retargets the tab (`WorkspaceModel.applyRenamePlan` is
        // kind-blind) while the open handle goes on answering off the same inode,
        // so the reconnect is the one moment the tab's own path is used again.
        await model.reload(at: renamed)

        XCTAssertEqual(model.fileURL, renamed, "The tab follows its file")
        XCTAssertEqual(
            service.openedURLs,
            [url, renamed],
            "Re-opening the opened-at path would report 'unable to open' over a file that is right there"
        )
        XCTAssertNil(model.errorMessage)
    }

    func testAReloadWithNoNewURLKeepsTheOneTheTabHas() async {
        let service = ScriptedDatabaseService()
        let model = await loadedModel(service)

        await model.reload()

        XCTAssertEqual(model.fileURL, url)
        XCTAssertEqual(service.openedURLs, [url, url])
    }

    func testAnOpenSupersededByAReloadDoesNotLatchTheConnectionOpen() async {
        let service = ScriptedDatabaseService()
        serveListing(on: service, entries: [("items", "table")])
        let model = DatabaseViewerModel(fileURL: url, service: service, pageSize: 2)

        // The one interleaving that can strand the tab: a `load()` resumes from
        // its `open` *inside* the window `reload()` opens between setting
        // `isOpen` false and its `close()` landing. A superseded load that
        // records `isOpen = true` there latches it true over a connection the
        // close is about to release — and since nothing outside
        // `reload()`/`close()` ever clears the flag, the reload's own load then
        // skips the re-open and every statement for the life of the tab throws
        // `.closed`.
        let openGate = Gate()
        let closeGate = Gate()
        service.holdOpen(on: openGate)
        service.holdClose(on: closeGate)

        let superseded = Task { await model.load() }
        await waitUntil { openGate.reached }
        let reloading = Task { await model.reload() }
        await waitUntil { closeGate.reached }

        // Resume the superseded load first — the whole point of the staging —
        // and only then let the close, and the re-open behind it, through.
        openGate.release()
        await superseded.value
        openGate.release()
        closeGate.release()
        await reloading.value

        XCTAssertNil(model.errorMessage, "The reconnect's own load must run against an open connection")
        XCTAssertEqual(model.entries.map(\.name), ["items"])
        XCTAssertEqual(service.openedURLs, [url, url], "The reload re-opens rather than trusting a stale flag")
        XCTAssertTrue(service.isOpen, "The reload's re-open is the connection the tab ends on")
    }

    func testAClosedTabIgnoresAReload() async {
        let service = ScriptedDatabaseService()
        let model = await loadedModel(service)
        await model.close()

        await model.reload()

        XCTAssertEqual(service.closeCount, 1, "close() latches; a reload after it must not re-open the file")
        XCTAssertEqual(service.openedURLs, [url])
    }

    // MARK: - Scripting helpers

    /// A model whose connection is open and whose listing has been read.
    ///
    /// Where every selection test starts, because a `select` before a `load` runs
    /// against a connection that is not open — which the fake refuses with
    /// `DatabaseError.closed`, exactly as the real one does, so a test that
    /// skipped the load would be asserting about a closed connection rather than
    /// about paging.
    private func loadedModel(
        _ service: ScriptedDatabaseService,
        tables: [(String, String)] = [("items", "table"), ("orders", "table")],
        pageSize: Int = 2
    ) async -> DatabaseViewerModel {
        serveListing(on: service, entries: tables)
        let model = DatabaseViewerModel(fileURL: url, service: service, pageSize: pageSize)
        await model.load()
        return model
    }

    /// A condition-wait that fails loudly.
    ///
    /// `Task.sleep` rather than `Gate.waitUntilReached`'s yield spin, for the
    /// reason `ProjectSearchModelTests` uses the same shape: the work being
    /// staged here starts on the **main actor** (the model is main-actor
    /// isolated), so a spin that only yields never lets the queued task reach
    /// the gate at all. A real suspension does.
    private func waitUntil(
        _ condition: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<2_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for the gated call", file: file, line: line)
    }

    private func pageSQL(table: String, orderBy column: String? = nil, ascending: Bool = true) -> String {
        DatabaseQuery.page(table: table, orderBy: column, ascending: ascending, limit: 1, offset: 0).sql
    }

    private func serveListing(on service: ScriptedDatabaseService, entries: [(String, String)]) {
        service.serve(
            DatabaseQuery.tableListing.sql,
            columns: DatabaseSchema.entryColumns,
            rows: entries.map { name, kind in
                [.text(name), .text(kind), .text("CREATE \(kind.uppercased()) \(name)(a)")]
            }
        )
    }

    /// A `PRAGMA table_xinfo` answer: the first column is the primary key, the
    /// rest are plain.
    private func serveSchema(on service: ScriptedDatabaseService, table: String, columns names: [String] = ["id", "label"]) {
        let rows: [[DatabaseValue]] = names.enumerated().map { offset, name in
            [
                .text(name),
                .text(offset == 0 ? "INTEGER" : "TEXT"),
                .integer(offset == 0 ? 1 : 0),
                .null,
                .integer(offset == 0 ? 1 : 0),
                .integer(0),
            ]
        }
        service.serve(
            DatabaseQuery.columnSchema(table: table).sql,
            columns: DatabaseSchema.columnPragmaColumns,
            rows: rows
        )
    }

    private func serveCount(on service: ScriptedDatabaseService, table: String, total: Int) {
        service.serve(
            DatabaseQuery.rowCount(table: table).sql,
            columns: ["count(*)"],
            rows: [[.integer(Int64(total))]]
        )
    }

    private func servePage(
        on service: ScriptedDatabaseService,
        table: String,
        orderBy column: String? = nil,
        ascending: Bool = true,
        columns names: [String] = ["id", "label"],
        rows: [[DatabaseValue]]
    ) {
        service.serve(
            pageSQL(table: table, orderBy: column, ascending: ascending),
            columns: names,
            rows: rows
        )
    }
}
