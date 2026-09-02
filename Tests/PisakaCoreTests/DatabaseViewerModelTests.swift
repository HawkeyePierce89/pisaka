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
                // The rowid probe: one prepare, no rows, asked once per
                // selection and never again on a page turn.
                DatabaseQuery.rowIdProbe(table: "items").sql,
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
        servePage(on: service, table: "items", orderBy: 1, ascending: true, rows: [[.integer(3), .text("a")]])
        servePage(on: service, table: "items", orderBy: 1, ascending: false, rows: [[.integer(9), .text("z")]])
        let model = await loadedModel(service)
        await model.select(table: "items")
        await model.goToPage(2)

        await model.toggleSort(column: "label", index: 1)
        XCTAssertEqual(model.sort, DatabaseSortState(column: "label", columnIndex: 1, direction: .ascending))
        XCTAssertEqual(model.page.index, 0, "A new ordering makes the old page number meaningless")
        XCTAssertEqual(model.rows, [[.integer(3), .text("a")]])
        XCTAssertEqual(model.page.totalRows, 5, "An ORDER BY does not change how many rows there are")
        XCTAssertEqual(service.count(for: DatabaseQuery.rowCount(table: "items").sql), 1)

        await model.toggleSort(column: "label", index: 1)
        XCTAssertEqual(model.sort, DatabaseSortState(column: "label", columnIndex: 1, direction: .descending))
        XCTAssertEqual(model.rows, [[.integer(9), .text("z")]])

        XCTAssertEqual(
            Array(service.runSQL.suffix(2)),
            [
                pageSQL(table: "items", orderBy: 1, ascending: true),
                pageSQL(table: "items", orderBy: 1, ascending: false),
            ]
        )
    }

    func testSortingWithNothingSelectedAsksNothing() async {
        let service = ScriptedDatabaseService()
        let model = DatabaseViewerModel(fileURL: url, service: service)

        await model.toggleSort(column: "label", index: 1)
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
        servePage(on: service, table: "items", orderBy: 1, ascending: true, rows: [[.integer(3), .text("a")]])
        serveSchema(on: service, table: "orders", columns: ["ref"])
        serveCount(on: service, table: "orders", total: 1)
        servePage(on: service, table: "orders", columns: ["ref"], rows: [[.text("x")]])
        let model = await loadedModel(service)

        await model.select(table: "items")
        await model.toggleSort(column: "label", index: 1)
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
        servePage(on: service, table: "items", orderBy: 1, ascending: true, rows: [[.integer(3), .text("a")]])
        let model = await loadedModel(service)

        await model.select(table: "items")
        await model.toggleSort(column: "label", index: 1)
        await model.select(table: "items")

        XCTAssertEqual(model.sort, DatabaseSortState(column: "label", columnIndex: 1, direction: .ascending))
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
            pageSQL(table: "items", orderBy: 1),
            with: DatabaseError.busy(message: "database is locked")
        )
        await model.toggleSort(column: "label", index: 1)

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
        await model.toggleSort(column: "label", index: 1)

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
        await model.toggleSort(column: "label", index: 1)

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
            orderBy: 1,
            rows: [[.integer(2), .text("two")], [.integer(1), .text("one")]]
        )
        await model.select(table: "items")
        await model.toggleSort(column: "label", index: 1)
        await model.goToPage(1)

        // What re-selecting the tab does: the surface reappears and refreshes the
        // listing. It must not be a second connection, and it must not be a reset.
        await model.load()

        XCTAssertEqual(service.openedURLs, [url], "A re-selected tab reuses the model it already had")
        XCTAssertEqual(model.selectedTable, "items")
        XCTAssertEqual(model.sort, DatabaseSortState(column: "label", columnIndex: 1, direction: .ascending))
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

    // MARK: - The token captured before the hop

    func testASelectPresentingASupersededRequestPublishesNothing() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")]])
        serveSchema(on: service, table: "orders")
        serveCount(on: service, table: "orders", total: 1)
        servePage(on: service, table: "orders", rows: [[.integer(9), .text("nine")]])
        let model = await loadedModel(service)

        // The clicks, in order: "items" then "orders". Each captures its token
        // synchronously, which is the whole point — the two loads then run in the
        // *reverse* order, exactly what an unstructured `Task` pair may do.
        let first = model.prepareForRowsChange()
        let second = model.prepareForRowsChange()
        await model.select(table: "orders", request: second)
        await model.select(table: "items", request: first)

        XCTAssertEqual(
            model.selectedTable,
            "orders",
            "The later click owns the newer token, so the earlier load is refused however late it starts"
        )
        XCTAssertEqual(model.rows, [[.integer(9), .text("nine")]])
        XCTAssertEqual(
            service.count(for: DatabaseQuery.columnSchema(table: "items").sql),
            0,
            "A superseded select is refused before it sends anything"
        )
    }

    func testAToggleSortPresentingASupersededRequestLeavesTheSortAlone() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")]])
        let model = await loadedModel(service)
        await model.select(table: "items")

        let stale = model.prepareForRowsChange()
        model.prepareForRowsChange()
        await model.toggleSort(column: "label", index: 1, request: stale)

        XCTAssertNil(
            model.sort,
            "The refusal comes before the sort is toggled, or a superseded click would still reorder the "
                + "header arrow it never loaded rows for"
        )
    }

    func testAPageMovePresentingASupersededRequestLeavesThePageAlone() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 500)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")]])
        let model = await loadedModel(service)
        await model.select(table: "items")

        // The footer click captures its token, then a sidebar click captures a
        // newer one. The paging task is picked up last and must refuse: a paging
        // click racing a *selection* is the race the token exists for, because
        // the page index it moves belongs to whichever table won.
        let stale = model.prepareForRowsChange()
        model.prepareForRowsChange()
        await model.goToPage(1, request: stale)

        XCTAssertEqual(
            model.page.index,
            0,
            "The refusal comes before the page moves, or a superseded click would still carry the "
                + "winning table's page off the first one"
        )
    }

    func testAPageMoveWithTheLatestRequestLoadsThatPage() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 500)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")]])
        let model = await loadedModel(service)
        await model.select(table: "items")

        let request = model.prepareForRowsChange()
        await model.goToPage(1, request: request)

        XCTAssertEqual(model.page.index, 1)
        XCTAssertEqual(
            service.statements(for: pageSQL(table: "items")).last?.parameters.last,
            .integer(Int64(model.page.offset)),
            "The latest token is honoured, so the second page is actually fetched"
        )
    }

    func testReloadRetiresTheRowsBannerAlongWithTheSelectionItExplained() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        service.fail(pageSQL(table: "items"), with: DatabaseError.busy(message: "database is locked"))
        let model = await loadedModel(service)
        await model.select(table: "items")
        XCTAssertEqual(model.errorMessage, "database is locked")

        serveListing(on: service, entries: [("orders", "table")])
        await model.reload()

        XCTAssertNil(model.selectedTable)
        XCTAssertNil(
            model.errorMessage,
            "The rows the banner was about are gone with the selection, so a message explaining a state "
                + "that no longer exists goes with them"
        )
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

    /// The reconnect's re-selection may not be read off its *own* load's success.
    ///
    /// The reader selecting this tab starts a second `load()` — the view's
    /// `.task` — and it can land inside the window the reconnect's own load is
    /// suspended in `open`. That supersedes the reconnect's load, which then
    /// publishes nothing and records no open, so a re-selection gated on `isOpen`
    /// is skipped: the sidebar refreshes to the new database while the schema, the
    /// rows and the sort go on describing the pre-operation one, silently. The
    /// intent is therefore consumed by whichever listing load actually lands.
    func testAReconnectSupersededByATabSelectionStillPutsTheSelectionBack() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")]])
        let model = await loadedModel(service)
        await model.select(table: "items")

        // The database is rewritten under the tab: the same table, other rows.
        servePage(on: service, table: "items", rows: [[.integer(9), .text("nine")]])

        // Two gates rather than one, so the interleaving is staged rather than
        // raced: the reconnect's own open waits on the first, the tab selection's
        // on the second, and the test lets them through in that order.
        let reconnectOpen = Gate()
        service.holdOpen(on: reconnectOpen)
        let reloading = Task { await model.reload() }
        await waitUntil { reconnectOpen.reached }

        let selectionOpen = Gate()
        service.holdOpen(on: selectionOpen)
        let selecting = Task { await model.load() }
        await waitUntil { service.openedURLs.count == 3 }

        // The reconnect's load resumes into a token the selection's load already
        // took, and returns having published nothing.
        reconnectOpen.release()
        await reloading.value
        selectionOpen.release()
        await selecting.value

        XCTAssertEqual(model.selectedTable, "items")
        XCTAssertEqual(
            model.rows,
            [[.integer(9), .text("nine")]],
            "The listing that landed owes the reconnect its re-selection; the rows on screen would "
                + "otherwise still be the pre-operation database's, under the new database's sidebar"
        )
        XCTAssertEqual(service.count(for: pageSQL(table: "items")), 2, "The page was re-read once")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoadingRows)
    }

    /// A pending re-selection is the reconnect's memory of a click, and the
    /// selection on screen is the reader's own: the later one wins.
    func testAReconnectDoesNotPutItsSelectionBackOverAReaderWhoMovedOn() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")]])
        let model = await loadedModel(service)
        await model.select(table: "items")

        service.failOpen(with: DatabaseError.cannotOpen(message: "unable to open database file"))
        await model.reload()
        XCTAssertEqual(model.errorMessage, "unable to open database file")

        // Under the banner the reader picks another table. The connection is
        // closed, so the read fails — but the selection is theirs either way.
        await model.select(table: "orders")
        XCTAssertEqual(model.selectedTable, "orders")

        service.clearOpenFailure()
        await model.load()

        XCTAssertEqual(
            model.selectedTable,
            "orders",
            "The refresh that finally opened the file must not undo the reader's own selection"
        )
    }

    func testAClosedTabIgnoresAReload() async {
        let service = ScriptedDatabaseService()
        let model = await loadedModel(service)
        await model.close()

        await model.reload()

        XCTAssertEqual(service.closeCount, 1, "close() latches; a reload after it must not re-open the file")
        XCTAssertEqual(service.openedURLs, [url])
    }

    // MARK: - A request that consumed a token and then did nothing

    func testAPagingClickThatMovesNowhereSettlesTheStateItAlreadyConsumed() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")]])
        let model = await loadedModel(service)
        await model.select(table: "items")
        await model.goToPage(1, request: model.prepareForRowsChange())
        XCTAssertEqual(model.page.index, 1)

        // Two clicks on ◀ faster than the button redraws. The first moves to page
        // 0 and suspends inside its read; the second reads the index that click
        // already changed, clamps onto it, and has nothing to do — having bumped
        // the token that strands the first one.
        let gate = Gate()
        service.hold(pageSQL(table: "items"), on: gate)
        let held = Task { await model.goToPage(0, request: model.prepareForRowsChange()) }
        await waitUntil { gate.reached }
        XCTAssertTrue(model.isLoadingRows)

        await model.goToPage(-1, request: model.prepareForRowsChange())

        gate.release()
        await held.value

        XCTAssertFalse(
            model.isLoadingRows,
            "The superseded load publishes nothing, including its own cleared flag — so the click that "
                + "superseded it must clear it, or the footer spins for the life of the tab"
        )
        XCTAssertEqual(
            model.page.index,
            1,
            "The position goes back onto the rows actually on screen, exactly as a failed load does"
        )
    }

    func testANoOpPagingCallWithoutATokenStaysAPlainNoOp() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")]])
        let model = await loadedModel(service)
        await model.select(table: "items")
        await model.goToPage(1)

        await model.goToPage(1)

        XCTAssertEqual(model.page.index, 1)
        XCTAssertEqual(
            service.count(for: pageSQL(table: "items")),
            2,
            "A caller that consumed no token superseded nothing and gets no re-query"
        )
    }

    // MARK: - A sort the answer no longer carries

    func testAReloadDropsASortWhoseColumnTheRebuiltTableNoLongerHas() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")]])
        serveResultColumns(on: service, table: "items")
        servePage(
            on: service,
            table: "items",
            orderBy: 1,
            rows: [[.integer(1), .text("one")]]
        )
        let model = await loadedModel(service)
        await model.select(table: "items")
        await model.toggleSort(column: "label", index: 1)
        XCTAssertEqual(model.sort?.column, "label")
        let sortedPagesBefore = service.count(for: pageSQL(table: "items", orderBy: 1))

        // The database is rebuilt under the tab without `label`. The re-selection
        // a reload makes is a *refresh*, so the sort is carried — and an ordinal
        // the answer no longer has is not a mis-sort but a statement real SQLite
        // refuses to prepare, which is why the shape is asked for first.
        serveSchema(on: service, table: "items", columns: ["id"])
        serveResultColumns(on: service, table: "items", columns: ["id"])
        servePage(on: service, table: "items", columns: ["id"], rows: [[.integer(1)]])
        await model.reload()

        XCTAssertNil(
            model.sort,
            "A sort the answered columns do not name did not happen; leaving it set claims an ordering "
                + "with no header arrow to click off and re-sends it on every later page"
        )
        XCTAssertEqual(
            service.count(for: pageSQL(table: "items", orderBy: 1)),
            sortedPagesBefore,
            "The stale ordinal must never reach SQLite: ORDER BY 2 against a one-column answer is "
                + "rejected at prepare time, so the refresh would fail rather than come back unsorted"
        )
        XCTAssertEqual(model.gridColumns, ["id"])
        XCTAssertEqual(model.rows, [[.integer(1)]])
        XCTAssertNil(model.errorMessage)
    }

    /// The case a position alone cannot catch: the ordinal is still in range, so
    /// the sorted statement would *succeed* and put a page ordered by a column
    /// nobody clicked on screen. Checking the shape first is what keeps it from
    /// being asked at all.
    func testAReloadDropsASortTheRebuiltTableMerelyReordered() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")]])
        serveResultColumns(on: service, table: "items")
        servePage(on: service, table: "items", orderBy: 1, rows: [[.integer(1), .text("one")]])
        let model = await loadedModel(service)
        await model.select(table: "items")
        await model.toggleSort(column: "label", index: 1)
        let sortedPagesBefore = service.count(for: pageSQL(table: "items", orderBy: 1))

        // Same two columns, the other way round: position 1 now spells `id`.
        serveSchema(on: service, table: "items", columns: ["label", "id"])
        serveResultColumns(on: service, table: "items", columns: ["label", "id"])
        servePage(
            on: service,
            table: "items",
            columns: ["label", "id"],
            rows: [[.text("one"), .integer(1)]]
        )
        await model.reload()

        XCTAssertNil(model.sort, "The name at the position is not the one the sort was made against")
        XCTAssertEqual(
            service.count(for: pageSQL(table: "items", orderBy: 1)),
            sortedPagesBefore,
            "An ordinal another column moved into orders by that column and says nothing; the page it "
                + "would have answered must never be asked for"
        )
        XCTAssertEqual(model.gridColumns, ["label", "id"])
        XCTAssertEqual(model.rows, [[.text("one"), .integer(1)]])
    }

    func testASortTheAnsweredColumnsStillNameSurvivesAReload() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")]])
        serveResultColumns(on: service, table: "items")
        servePage(on: service, table: "items", orderBy: 1, rows: [[.integer(1), .text("one")]])
        let model = await loadedModel(service)
        await model.select(table: "items")
        await model.toggleSort(column: "label", index: 1)
        let sortedPagesBefore = service.count(for: pageSQL(table: "items", orderBy: 1))

        await model.reload()

        XCTAssertEqual(model.sort?.column, "label", "The drop is the exception, not the rule")
        XCTAssertEqual(model.sort?.direction, .ascending)
        XCTAssertEqual(
            service.count(for: pageSQL(table: "items", orderBy: 1)),
            sortedPagesBefore + 1,
            "A surviving sort is re-sent, so the refreshed page is in the order the arrow claims"
        )
    }

    /// The probe is the carried sort's own cost and nobody else's: an unsorted
    /// selection composes its page with nothing to check.
    func testAnUnsortedSelectionAsksForNoShape() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")]])
        let model = await loadedModel(service)

        await model.select(table: "items")
        await model.select(table: "items")

        XCTAssertEqual(service.count(for: DatabaseQuery.resultColumns(table: "items").sql), 0)
        XCTAssertEqual(model.rows, [[.integer(1), .text("one")]])
    }

    // MARK: - Row identity

    // The identity a cell edit will address a row by is resolved once per
    // selection and travels as a trailing result column the grid never sees.
    // Everything here is about that column being asked for, split off by
    // position, and never mistaken for one of the reader's own.

    func testARowIdTableCarriesItsIdentityWithoutShowingIt() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items", primaryKey: [:])
        serveProbe(on: service, table: "items")
        serveCount(on: service, table: "items", total: 2)
        servePage(
            on: service,
            table: "items",
            identity: .rowid,
            columns: ["id", "label", "rowid"],
            rows: [[.integer(1), .text("one"), .integer(7)], [.integer(2), .null, .integer(9)]]
        )
        let model = await loadedModel(service)

        await model.select(table: "items")

        XCTAssertEqual(model.rowIdentity, .rowid(alias: .rowid))
        XCTAssertTrue(
            service.runSQL.contains(pageSQL(table: "items", identity: .rowid)),
            "The page asks for the identity column"
        )
        XCTAssertEqual(model.gridColumns, ["id", "label"], "The grid shows no column the reader did not ask for")
        XCTAssertEqual(model.rows, [[.integer(1), .text("one")], [.integer(2), .null]])
        XCTAssertEqual(model.rowIdentityValues, [.integer(7), .integer(9)])
        XCTAssertEqual(model.rowIdentityValue(at: 1), .integer(9))
        XCTAssertNil(model.rowIdentityValue(at: 2))
        XCTAssertTrue(model.canEdit(row: 0, column: 1))
    }

    /// The reason the split is by position: on a table with an
    /// `INTEGER PRIMARY KEY` alias, SQLite answers the appended column under the
    /// **alias column's own name**, so a split that looked for a column called
    /// `rowid` would find none — and one that looked for the identity by name
    /// would find the alias column instead and hand the grid a row one value
    /// short.
    func testAnIntegerPrimaryKeyAliasRepeatsItsNameAndTheSplitStillHolds() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "r", columns: ["id", "v"])
        serveProbe(on: service, table: "r")
        serveCount(on: service, table: "r", total: 1)
        servePage(
            on: service,
            table: "r",
            identity: .rowid,
            columns: ["id", "v", "id"],
            rows: [[.integer(4), .text("x"), .integer(4)]]
        )
        let model = await loadedModel(service, tables: [("r", "table")])

        await model.select(table: "r")

        XCTAssertEqual(model.gridColumns, ["id", "v"])
        XCTAssertEqual(model.rows, [[.integer(4), .text("x")]])
        XCTAssertEqual(model.rowIdentityValues, [.integer(4)])
        XCTAssertEqual(model.rowIdentity, .rowid(alias: .rowid))
    }

    func testAViewIsNeverProbedAndRefusesEveryCell() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "recent", columns: ["a"], primaryKey: [:])
        serveCount(on: service, table: "recent", total: 1)
        servePage(on: service, table: "recent", columns: ["a"], rows: [[.text("x")]])
        let model = await loadedModel(service, tables: [("recent", "view")])

        await model.select(table: "recent")

        XCTAssertEqual(
            service.count(for: DatabaseQuery.rowIdProbe(table: "recent").sql),
            0,
            "A view's rows are computed; the listing already answered the question"
        )
        XCTAssertEqual(model.gridColumns, ["a"])
        XCTAssertEqual(model.rows, [[.text("x")]])
        XCTAssertEqual(model.rowIdentity, .unavailable(.view))
        XCTAssertFalse(model.canEdit(row: 0, column: 0))
        XCTAssertEqual(model.editRefusal(row: 0, column: 0), .unaddressableRow(.view))
        XCTAssertNil(model.errorMessage)
    }

    func testAWithoutRowIdTableFallsBackToItsWholeKeyWithNoBanner() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "pairs", columns: ["a", "b"], primaryKey: [0: 1, 1: 2])
        failProbe(on: service, table: "pairs")
        serveCount(on: service, table: "pairs", total: 1)
        servePage(on: service, table: "pairs", columns: ["a", "b"], rows: [[.integer(1), .text("x")]])
        let model = await loadedModel(service, tables: [("pairs", "table")])

        await model.select(table: "pairs")

        XCTAssertEqual(
            model.rowIdentity,
            .primaryKey(columns: [
                DatabaseKeyColumn(name: "a", resultIndex: 0),
                DatabaseKeyColumn(name: "b", resultIndex: 1),
            ])
        )
        XCTAssertFalse(
            service.runSQL.contains(pageSQL(table: "pairs", identity: .rowid)),
            "A key-addressed table appends nothing to its page"
        )
        XCTAssertEqual(model.gridColumns, ["a", "b"])
        XCTAssertEqual(model.rows, [[.integer(1), .text("x")]])
        XCTAssertTrue(model.rowIdentityValues.isEmpty)
        XCTAssertNil(model.errorMessage, "A probe that says no is the probe working, not a failure")
        XCTAssertTrue(model.canEdit(row: 0, column: 1))
    }

    func testATableWithNeitherARowIdNorAKeyReadsFineAndEditsNothing() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "loose", columns: ["a"], primaryKey: [:])
        failProbe(on: service, table: "loose")
        serveCount(on: service, table: "loose", total: 1)
        servePage(on: service, table: "loose", columns: ["a"], rows: [[.text("x")]])
        let model = await loadedModel(service, tables: [("loose", "table")])

        await model.select(table: "loose")

        XCTAssertEqual(model.rowIdentity, .unavailable(.noRowIdentity))
        XCTAssertEqual(model.rows, [[.text("x")]], "Reading is untouched by not being able to write")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.editRefusal(row: 0, column: 0), .unaddressableRow(.noRowIdentity))
    }

    func testTheProbeIsAskedOncePerSelectionAndNotOnEveryPage() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items", primaryKey: [:])
        serveProbe(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(
            on: service,
            table: "items",
            identity: .rowid,
            columns: ["id", "label", "rowid"],
            rows: [[.integer(1), .text("a"), .integer(1)]]
        )
        let model = await loadedModel(service)

        await model.select(table: "items")
        await model.goToPage(1)
        await model.goToPage(2)

        XCTAssertEqual(service.count(for: DatabaseQuery.rowIdProbe(table: "items").sql), 1)
        XCTAssertEqual(service.count(for: pageSQL(table: "items", identity: .rowid)), 3)
    }

    func testASortOrdinalStillNamesTheGridColumnWithTheIdentityColumnPresent() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items", primaryKey: [:])
        serveProbe(on: service, table: "items")
        serveCount(on: service, table: "items", total: 1)
        servePage(
            on: service,
            table: "items",
            identity: .rowid,
            columns: ["id", "label", "rowid"],
            rows: [[.integer(1), .text("a"), .integer(5)]]
        )
        servePage(
            on: service,
            table: "items",
            orderBy: 1,
            identity: .rowid,
            columns: ["id", "label", "rowid"],
            rows: [[.integer(2), .text("b"), .integer(6)]]
        )
        let model = await loadedModel(service)

        await model.select(table: "items")
        await model.toggleSort(column: "label", index: 1)

        // The appended column is last precisely so the 1-based ordinal the grid
        // clicked goes on meaning the column the grid drew.
        let sorted = pageSQL(table: "items", orderBy: 1, identity: .rowid)
        XCTAssertTrue(sorted.contains("SELECT *, rowid FROM"))
        XCTAssertTrue(sorted.contains("ORDER BY 2 ASC"))
        XCTAssertEqual(service.runSQL.last, sorted)
        XCTAssertEqual(model.sort, DatabaseSortState(column: "label", columnIndex: 1, direction: .ascending))
        XCTAssertEqual(model.gridColumns, ["id", "label"], "The sort survives against the grid, not the raw answer")
        XCTAssertEqual(model.rows, [[.integer(2), .text("b")]])
        XCTAssertEqual(model.rowIdentityValues, [.integer(6)])
    }

    func testACarriedSortIsCheckedAgainstTheGridShapeAndThePageStillCarriesItsIdentity() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items", primaryKey: [:])
        serveProbe(on: service, table: "items")
        serveCount(on: service, table: "items", total: 1)
        serveResultColumns(on: service, table: "items")
        servePage(
            on: service,
            table: "items",
            identity: .rowid,
            columns: ["id", "label", "rowid"],
            rows: [[.integer(1), .text("a"), .integer(5)]]
        )
        servePage(
            on: service,
            table: "items",
            orderBy: 1,
            identity: .rowid,
            columns: ["id", "label", "rowid"],
            rows: [[.integer(2), .text("b"), .integer(6)]]
        )
        let model = await loadedModel(service)

        await model.select(table: "items")
        await model.toggleSort(column: "label", index: 1)
        await model.select(table: "items")

        // The shape probe is `SELECT *` without the identity column — the grid's
        // own shape — which is what the carried ordinal has to be checked against.
        XCTAssertEqual(service.count(for: DatabaseQuery.resultColumns(table: "items").sql), 1)
        XCTAssertEqual(model.sort, DatabaseSortState(column: "label", columnIndex: 1, direction: .ascending))
        XCTAssertEqual(model.gridColumns, ["id", "label"])
        XCTAssertEqual(model.rowIdentityValues, [.integer(6)])
    }

    func testAFailedPageTurnKeepsTheIdentityOfTheRowsStillOnScreen() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items", primaryKey: [:])
        serveProbe(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(
            on: service,
            table: "items",
            identity: .rowid,
            columns: ["id", "label", "rowid"],
            rows: [[.integer(1), .text("a"), .integer(11)]]
        )
        let model = await loadedModel(service)
        await model.select(table: "items")
        // Re-scripting the page's key replaces its answer, so the *next* turn is
        // the one that fails — with a good page already on screen behind it.
        service.fail(pageSQL(table: "items", identity: .rowid), with: DatabaseError.busy(message: "database is locked"))

        await model.goToPage(1)

        XCTAssertEqual(model.errorMessage, "database is locked")
        XCTAssertEqual(model.rows, [[.integer(1), .text("a")]], "A failure never blanks a good page")
        XCTAssertEqual(model.rowIdentityValues, [.integer(11)], "…nor the identity that names its rows")
        XCTAssertEqual(model.rowIdentity, .rowid(alias: .rowid))
        XCTAssertEqual(model.page.index, 0)
    }

    // MARK: - What may be edited

    /// The whole point of matching a grid column to its schema column **by
    /// name**: `PRAGMA table_xinfo` lists a hidden column that `SELECT *` does
    /// not answer, so a positional map here would call grid column 0 the hidden
    /// one and refuse — or, worse, edit under the wrong name.
    func testAHiddenSchemaColumnAheadOfTheVisibleOnesDoesNotShiftWhatMayBeEdited() async {
        let service = ScriptedDatabaseService()
        serveSchema(
            on: service,
            table: "virt",
            columns: ["hidden_key", "id", "label"],
            primaryKey: [:],
            hidden: [0]
        )
        serveProbe(on: service, table: "virt")
        serveCount(on: service, table: "virt", total: 1)
        servePage(
            on: service,
            table: "virt",
            identity: .rowid,
            columns: ["id", "label", "rowid"],
            rows: [[.integer(1), .text("x"), .integer(3)]]
        )
        let model = await loadedModel(service, tables: [("virt", "table")])

        await model.select(table: "virt")

        XCTAssertEqual(model.columns.map(\.name), ["hidden_key", "id", "label"])
        XCTAssertTrue(model.columns[0].isHidden)
        XCTAssertEqual(model.gridColumns, ["id", "label"])
        XCTAssertTrue(model.canEdit(row: 0, column: 0))
        XCTAssertTrue(model.canEdit(row: 0, column: 1))
    }

    func testAGeneratedColumnAndABlobCellAndAnUnmatchedNameAreEachRefused() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items", columns: ["id", "label"], primaryKey: [:], hidden: [1])
        serveProbe(on: service, table: "items")
        serveCount(on: service, table: "items", total: 1)
        servePage(
            on: service,
            table: "items",
            identity: .rowid,
            columns: ["id", "label", "extra", "rowid"],
            rows: [[.blob(byteCount: 12), .text("x"), .text("y"), .integer(3)]]
        )
        let model = await loadedModel(service)

        await model.select(table: "items")

        XCTAssertEqual(model.gridColumns, ["id", "label", "extra"])
        XCTAssertEqual(model.editRefusal(row: 0, column: 0), .blobCell(column: "id"))
        XCTAssertEqual(model.editRefusal(row: 0, column: 1), .generatedColumn(name: "label"))
        XCTAssertEqual(model.editRefusal(row: 0, column: 2), .columnNotMatched(name: "extra"))
        XCTAssertEqual(model.editRefusal(row: 0, column: 3), .cellNotOnPage)
        XCTAssertEqual(model.editRefusal(row: 4, column: 0), .cellNotOnPage)
    }

    func testNothingIsEditableBeforeATableIsSelected() async {
        let service = ScriptedDatabaseService()
        let model = await loadedModel(service)

        XCTAssertNil(model.editTarget)
        XCTAssertEqual(model.rowIdentity, .unavailable(.noRowIdentity))
        XCTAssertFalse(model.canEdit(row: 0, column: 0))
        XCTAssertEqual(model.editRefusal(row: 0, column: 0), .cellNotOnPage)
    }

    func testMovingToAnotherTableForgetsThePreviousTablesIdentity() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items", primaryKey: [:])
        serveProbe(on: service, table: "items")
        serveCount(on: service, table: "items", total: 1)
        servePage(
            on: service,
            table: "items",
            identity: .rowid,
            columns: ["id", "label", "rowid"],
            rows: [[.integer(1), .text("a"), .integer(5)]]
        )
        serveSchema(on: service, table: "pairs", columns: ["a", "b"], primaryKey: [0: 1, 1: 2])
        failProbe(on: service, table: "pairs")
        serveCount(on: service, table: "pairs", total: 1)
        servePage(on: service, table: "pairs", columns: ["a", "b"], rows: [[.integer(1), .text("x")]])
        let model = await loadedModel(service, tables: [("items", "table"), ("pairs", "table")])

        await model.select(table: "items")
        await model.select(table: "pairs")

        XCTAssertTrue(model.rowIdentityValues.isEmpty, "An identity never outlives the page it addressed")
        XCTAssertEqual(
            model.rowIdentity,
            .primaryKey(columns: [
                DatabaseKeyColumn(name: "a", resultIndex: 0),
                DatabaseKeyColumn(name: "b", resultIndex: 1),
            ])
        )
        XCTAssertFalse(
            service.runSQL.contains(pageSQL(table: "pairs", identity: .rowid)),
            "The new table composes its own page, not the previous one's shape"
        )
    }

    func testASupersededSelectionPublishesNoneOfItsIdentity() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items", primaryKey: [:])
        serveProbe(on: service, table: "items")
        serveCount(on: service, table: "items", total: 1)
        servePage(
            on: service,
            table: "items",
            identity: .rowid,
            columns: ["id", "label", "rowid"],
            rows: [[.integer(1), .text("stale"), .integer(1)]]
        )
        serveSchema(on: service, table: "pairs", columns: ["a", "b"], primaryKey: [0: 1, 1: 2])
        failProbe(on: service, table: "pairs")
        serveCount(on: service, table: "pairs", total: 1)
        servePage(on: service, table: "pairs", columns: ["a", "b"], rows: [[.integer(9), .text("fresh")]])

        // Held inside the probe, which is the one hop this task added: a
        // selection superseded there must not latch its alias over the newer
        // selection's, or the next page would ask the new table for the old
        // table's shape.
        let gate = Gate()
        service.hold(DatabaseQuery.rowIdProbe(table: "items").sql, on: gate)
        let model = await loadedModel(service, tables: [("items", "table"), ("pairs", "table")])

        let held = Task { await model.select(table: "items") }
        await waitUntil { gate.reached }
        await model.select(table: "pairs")
        gate.release()
        await held.value

        XCTAssertEqual(model.selectedTable, "pairs")
        XCTAssertEqual(model.rows, [[.integer(9), .text("fresh")]])
        XCTAssertEqual(
            model.rowIdentity,
            .primaryKey(columns: [
                DatabaseKeyColumn(name: "a", resultIndex: 0),
                DatabaseKeyColumn(name: "b", resultIndex: 1),
            ])
        )
        XCTAssertTrue(model.rowIdentityValues.isEmpty, "The superseded selection's rowid never lands")
        XCTAssertNil(model.errorMessage)
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

    private func pageSQL(
        table: String,
        orderBy column: Int? = nil,
        ascending: Bool = true,
        identity: DatabaseRowIdAlias? = nil
    ) -> String {
        DatabaseQuery.page(
            table: table,
            orderByColumnIndex: column,
            ascending: ascending,
            limit: 1,
            offset: 0,
            identityAlias: identity
        ).sql
    }

    /// Answer the rowid probe — the "this table has a rowid" half of a selection.
    ///
    /// The answer is a shape and no rows, which is what `LIMIT 0` returns; the
    /// model reads nothing out of it and only cares that it did not throw.
    private func serveProbe(
        on service: ScriptedDatabaseService,
        table: String,
        alias: DatabaseRowIdAlias = .rowid
    ) {
        service.serve(DatabaseQuery.rowIdProbe(table: table, alias: alias).sql, columns: [alias.rawValue], rows: [])
    }

    /// Refuse the rowid probe the way a `WITHOUT ROWID` table does — at prepare
    /// time, in SQLite's own words.
    private func failProbe(
        on service: ScriptedDatabaseService,
        table: String,
        alias: DatabaseRowIdAlias = .rowid
    ) {
        service.fail(
            DatabaseQuery.rowIdProbe(table: table, alias: alias).sql,
            with: DatabaseError.sqlError(message: "no such column: rowid")
        )
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
    private func serveSchema(
        on service: ScriptedDatabaseService,
        table: String,
        columns names: [String] = ["id", "label"],
        primaryKey keyPositions: [Int: Int] = [0: 1],
        hidden: Set<Int> = []
    ) {
        let rows: [[DatabaseValue]] = names.enumerated().map { offset, name in
            [
                .text(name),
                .text(offset == 0 ? "INTEGER" : "TEXT"),
                .integer(offset == 0 ? 1 : 0),
                .null,
                .integer(Int64(keyPositions[offset] ?? 0)),
                .integer(hidden.contains(offset) ? 1 : 0),
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

    private func serveResultColumns(
        on service: ScriptedDatabaseService,
        table: String,
        columns names: [String] = ["id", "label"]
    ) {
        service.serve(DatabaseQuery.resultColumns(table: table).sql, columns: names, rows: [])
    }

    private func servePage(
        on service: ScriptedDatabaseService,
        table: String,
        orderBy column: Int? = nil,
        ascending: Bool = true,
        identity: DatabaseRowIdAlias? = nil,
        columns names: [String] = ["id", "label"],
        rows: [[DatabaseValue]]
    ) {
        service.serve(
            pageSQL(table: table, orderBy: column, ascending: ascending, identity: identity),
            columns: names,
            rows: rows
        )
    }
}
