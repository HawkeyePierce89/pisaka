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
                DatabaseQuery.rowIdProbe(table: "items", alias: .rowid).sql,
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

        service.serveCommittedWrite()
        await model.updateCell(row: 0, column: 1, entry: .typed("new"))
        await model.setCellToNull(row: 0, column: 1)

        XCTAssertEqual(service.runSQL.count, asked, "A closed tab runs nothing")
        XCTAssertEqual(service.writeCount, 0, "And writes nothing — a torn-down tab has no page to write against")
        XCTAssertFalse(model.isWriting, "Nothing raised it, so nothing is left latched")
        XCTAssertFalse(model.isLoadingRows)
        XCTAssertFalse(model.isLoadingEntries)
        XCTAssertEqual(
            model.rowIdentity,
            .unavailable(.noRowIdentity),
            "An identity must never outlive the page it addressed"
        )
        XCTAssertTrue(model.rowIdentityValues.isEmpty)
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

    /// `clearRowIdentity()`'s rule, asked of the console's own carried decision.
    ///
    /// A confirmation is the one thing on the pane that survives the window a git
    /// operation opens: the prompt describes a classification made against the
    /// database `reload` is about to replace, the gate `confirm()` asks is down
    /// again by the time the reader answers, and `fileURL()` already names the
    /// file the checkout put there. Agreeing would send the text to a database it
    /// was never classified against.
    func testReloadDropsAPendingConsoleConfirmationRatherThanLettingItLand() async {
        let service = ScriptedDatabaseService()
        let text = "DELETE FROM items"
        serveSchema(on: service, table: "items")
        serveCount(on: service, table: "items", total: 5)
        servePage(on: service, table: "items", rows: [[.integer(1), .text("one")]])
        service.serveClassification(text, kinds: [.write])
        service.serveCommittedConsoleWrite(affectedRows: 5)
        let model = await loadedModel(service)
        await model.select(table: "items")

        await model.console.run(text)
        XCTAssertNotNil(model.console.pendingConfirmation, "Staging: the reader is being asked")

        await model.reload(at: URL(fileURLWithPath: "/tmp/Project/renamed.sqlite"))
        await model.console.confirm()

        XCTAssertNil(model.console.pendingConfirmation)
        XCTAssertTrue(
            service.consoleTransactions.isEmpty,
            "A prompt about the database that was replaced may not be sent to the one that replaced it"
        )
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

    /// The rows survive a reconnect; the right to *edit* them does not.
    ///
    /// `reload` is what a git operation calls once the file on disk has been
    /// replaced, and it retargets `fileURL` before it re-opens anything. A page
    /// left addressable across that window would let an edit carry the old
    /// database's rowid and the old page's previous value into the new file,
    /// where the statement's `IS` guard cannot tell the two apart if the row it
    /// lands on happens to match. A failed re-open is the window at its widest:
    /// it lasts for the life of the tab.
    func testAReloadThatCannotReopenLeavesNoCellEditable() async {
        let service = ScriptedDatabaseService()
        let model = await editableModel(service)
        XCTAssertNil(model.editRefusal(row: 0, column: 1), "Editable before the reconnect")

        service.failOpen(with: DatabaseError.cannotOpen(message: "unable to open database file"))
        await model.reload()

        XCTAssertEqual(model.rows.count, 1, "A reconnect blanks no good page")
        XCTAssertEqual(model.rowIdentity, .unavailable(.noRowIdentity))
        XCTAssertEqual(model.editRefusal(row: 0, column: 1), .unaddressableRow(.noRowIdentity))

        service.serveCommittedWrite()
        await model.updateCell(row: 0, column: 1, entry: .typed("new"))

        XCTAssertEqual(service.writeCount, 0, "Nothing may be sent against a page nothing addresses")
        XCTAssertEqual(model.errorMessage, DatabaseEditRefusal.unaddressableRow(.noRowIdentity).message)
    }

    /// …and the re-selection puts it back, so the refusal above is the window and
    /// not a tab that can never be edited again.
    func testAReloadThatReopensMakesTheRowsEditableAgain() async {
        let service = ScriptedDatabaseService()
        let model = await editableModel(service)

        await model.reload()

        XCTAssertNil(model.editRefusal(row: 0, column: 1))
        service.serveCommittedWrite()
        await model.updateCell(row: 0, column: 1, entry: .typed("new"))
        XCTAssertEqual(service.writeCount, 1)
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
            service.count(for: DatabaseQuery.rowIdProbe(table: "recent", alias: .rowid).sql),
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

        XCTAssertEqual(service.count(for: DatabaseQuery.rowIdProbe(table: "items", alias: .rowid).sql), 1)
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
        // Asserted against what the model *sent*, not against the helper's own
        // output: the statement's text is `DatabaseQueryTests`' subject, and a
        // `contains` over a string this test just built would hold whatever the
        // model did with it.
        let sorted = pageSQL(table: "items", orderBy: 1, identity: .rowid)
        XCTAssertEqual(service.runSQL.last, sorted)
        XCTAssertEqual(service.runSQL.last?.contains("ORDER BY 2 ASC"), true, sorted)
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
        service.hold(DatabaseQuery.rowIdProbe(table: "items", alias: .rowid).sql, on: gate)
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

    // MARK: - Writing one cell

    func testACommittedEditSendsOneTransactionReQueriesThePageAndTellsTheApp() async {
        let service = ScriptedDatabaseService()
        var hookCount = 0
        let model = await editableModel(
            service,
            pages: [itemsPage(label: .text("old")), itemsPage(label: .text("new"))],
            didWrite: { hookCount += 1 }
        )
        service.serveCommittedWrite()

        await model.updateCell(row: 0, column: 1, entry: .typed("new"))

        XCTAssertEqual(service.writeCount, 1)
        let transaction = service.writeTransactions[0]
        XCTAssertEqual(transaction.url, url, "The write opens the tab's *current* url")
        XCTAssertEqual(transaction.requiredAffectedRows, 1)
        XCTAssertEqual(transaction.statements, [updateStatement(newValue: .text("new"))])
        XCTAssertEqual(hookCount, 1)
        XCTAssertEqual(model.rows, [[.integer(1), .text("new")]], "The committed page is re-read")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isWriting)
        XCTAssertEqual(
            service.count(for: DatabaseQuery.rowCount(table: "items").sql),
            1,
            "An UPDATE creates and deletes nothing, so the count is not re-asked"
        )
    }

    func testAnEditIsRefusedWhileTheWorktreeIsBeingRewrittenAndSendsNothing() async {
        let service = ScriptedDatabaseService()
        var blocked = true
        var hookCount = 0
        let model = await editableModel(service, isWriteBlocked: { blocked }, didWrite: { hookCount += 1 })
        service.serveCommittedWrite()

        await model.updateCell(row: 0, column: 1, entry: .typed("new"))

        XCTAssertEqual(model.errorMessage, DatabaseViewerModel.gateBlockedMessage)
        XCTAssertEqual(service.writeCount, 0, "Nothing is sent while the gate is up")
        XCTAssertEqual(hookCount, 0)
        XCTAssertEqual(model.rows, [[.integer(1), .text("old")]], "A refusal never blanks a good page")

        blocked = false
        await model.updateCell(row: 0, column: 1, entry: .typed("new"))

        XCTAssertEqual(service.writeCount, 1, "The gate is read at the moment of the edit, not latched")
        XCTAssertNil(model.errorMessage)
    }

    /// The three sentences the write path raises on its own — as opposed to the
    /// refusals, which carry theirs — say something, and say three different
    /// things. Every other assertion about them compares the banner against the
    /// very constant that produced it, which stays true if the constant empties.
    func testTheWritesOwnSentencesAreDistinctAndSayAnything() {
        let sentences = [
            DatabaseViewerModel.gateBlockedMessage,
            DatabaseViewerModel.writeInFlightMessage,
            DatabaseViewerModel.rollbackMessage(affectedRows: 0),
            DatabaseViewerModel.rollbackMessage(affectedRows: 3),
        ]

        XCTAssertEqual(Set(sentences).count, sentences.count)
        for sentence in sentences {
            XCTAssertGreaterThan(sentence.count, 20, sentence)
        }
        XCTAssertTrue(DatabaseViewerModel.gateBlockedMessage.contains("on disk"))
        XCTAssertTrue(DatabaseViewerModel.writeInFlightMessage.contains("still being written"))
        XCTAssertTrue(DatabaseViewerModel.rollbackMessage(affectedRows: 3).contains("3 rows"))
    }

    func testAViewRefusesTheEditInTheRefusalsOwnWords() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "recent", columns: ["a"], primaryKey: [:])
        serveCount(on: service, table: "recent", total: 1)
        servePage(on: service, table: "recent", columns: ["a"], rows: [[.text("x")]])
        let model = await loadedModel(service, tables: [("recent", "view")])
        await model.select(table: "recent")

        await model.updateCell(row: 0, column: 0, entry: .typed("y"))

        XCTAssertEqual(model.errorMessage, DatabaseEditRefusal.unaddressableRow(.view).message)
        XCTAssertEqual(service.writeCount, 0)
        XCTAssertEqual(model.rows, [[.text("x")]])
    }

    func testAGeneratedColumnABlobCellAndAnUnmatchedNameEachRefuseTheEdit() async {
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

        await model.updateCell(row: 0, column: 0, entry: .typed("z"))
        XCTAssertEqual(model.errorMessage, DatabaseEditRefusal.blobCell(column: "id").message)

        await model.updateCell(row: 0, column: 1, entry: .typed("z"))
        XCTAssertEqual(model.errorMessage, DatabaseEditRefusal.generatedColumn(name: "label").message)

        await model.updateCell(row: 0, column: 2, entry: .typed("z"))
        XCTAssertEqual(model.errorMessage, DatabaseEditRefusal.columnNotMatched(name: "extra").message)

        await model.updateCell(row: 4, column: 0, entry: .typed("z"))
        XCTAssertEqual(model.errorMessage, DatabaseEditRefusal.cellNotOnPage.message)

        XCTAssertEqual(service.writeCount, 0, "A refused plan reaches no connection")
    }

    func testARollbackAtZeroSaysTheRowChangedUnderneathAndKeepsThePage() async {
        let service = ScriptedDatabaseService()
        var hookCount = 0
        let model = await editableModel(service, didWrite: { hookCount += 1 })
        service.serveRolledBackWrite(affectedRows: 0)

        await model.updateCell(row: 0, column: 1, entry: .typed("new"))

        XCTAssertEqual(model.errorMessage, DatabaseViewerModel.rollbackMessage(affectedRows: 0))
        XCTAssertEqual(hookCount, 0, "Nothing was written, so nothing is stale")
        XCTAssertEqual(model.rows, [[.integer(1), .text("old")]])
        XCTAssertEqual(
            service.count(for: pageSQL(table: "items", identity: .rowid)),
            1,
            "A rollback re-reads nothing: the file is exactly as it was"
        )
        XCTAssertFalse(model.isWriting)
    }

    func testARollbackAtManySaysHowManyRowsItWouldHaveTouched() async {
        let service = ScriptedDatabaseService()
        let model = await editableModel(service)
        service.serveRolledBackWrite(affectedRows: 3)

        await model.updateCell(row: 0, column: 1, entry: .typed("new"))

        XCTAssertEqual(model.errorMessage, DatabaseViewerModel.rollbackMessage(affectedRows: 3))
        XCTAssertTrue(model.errorMessage?.contains("3 rows") == true)
        XCTAssertEqual(model.rows, [[.integer(1), .text("old")]])
    }

    func testAFailedWriteReportsSQLitesOwnWordsAndLeavesThePage() async {
        let service = ScriptedDatabaseService()
        let model = await editableModel(service)
        service.failWrite(with: DatabaseError.busy(message: "database is locked"))

        await model.updateCell(row: 0, column: 1, entry: .typed("new"))

        XCTAssertEqual(model.errorMessage, "database is locked")
        XCTAssertEqual(model.rows, [[.integer(1), .text("old")]])
        XCTAssertFalse(model.isWriting)
    }

    /// The one place NULL and the empty string have to stay apart, because the
    /// gesture and the empty field are one keystroke away from each other.
    func testTheNullGestureAndAnEmptyEntryAreWrittenDistinctly() async {
        let service = ScriptedDatabaseService()
        let model = await editableModel(
            service,
            pages: [
                itemsPage(label: .text("old")),
                itemsPage(label: .null),
                itemsPage(label: .text("")),
            ]
        )
        service.serveWrites(sequence: [
            DatabaseWriteOutcome(affectedRows: 1, isCommitted: true),
            DatabaseWriteOutcome(affectedRows: 1, isCommitted: true),
        ])

        await model.setCellToNull(row: 0, column: 1)
        XCTAssertEqual(model.rows, [[.integer(1), .null]])

        await model.updateCell(row: 0, column: 1, entry: .typed(""))
        XCTAssertEqual(model.rows, [[.integer(1), .text("")]])

        XCTAssertEqual(
            service.writeTransactions.flatMap(\.statements),
            [
                updateStatement(newValue: .null, previousValue: .text("old")),
                updateStatement(newValue: .text(""), previousValue: .null),
            ]
        )
    }

    /// The token is captured in the gesture, not inside the task the gesture
    /// spawns: a page that landed in between means the coordinate no longer names
    /// the row the reader was looking at, so the write is refused rather than
    /// re-aimed. Nothing is sent, and the plan is never even composed.
    func testAWriteCarryingAStaleRowsTokenIsRefusedAndSendsNothing() async {
        let service = ScriptedDatabaseService()
        var hookCount = 0
        let model = await editableModel(service, didWrite: { hookCount += 1 })
        service.serveCommittedWrite()

        let stale = await model.rowsToken
        _ = await model.prepareForRowsChange()

        await model.updateCell(row: 0, column: 1, entry: .typed("new"), request: stale)

        XCTAssertEqual(service.writeCount, 0, "Nothing is sent")
        XCTAssertEqual(hookCount, 0)
        let message = await model.errorMessage
        XCTAssertEqual(message, DatabaseEditRefusal.cellNotOnPage.message)
        let rows = await model.rows
        XCTAssertEqual(rows, [[.integer(1), .text("old")]], "A refusal never blanks the page")
        let isWriting = await model.isWriting
        XCTAssertFalse(isWriting)
    }

    /// A page **still in flight** refuses the write, and the token cannot be what
    /// refuses it.
    ///
    /// The load bumped the generation before its first hop, so a gesture made
    /// after it captured the very number the staleness check compares — the two
    /// are equal and that check passes. What is on screen is nonetheless the page
    /// the load is about to replace, so planning against it would carry a row's
    /// identity and previous value that nobody is looking at any more. The grid
    /// asks the same question before it opens an editor, but a view is not where
    /// the rule lives: this asserts the model refuses on its own.
    func testAWriteArrivingWhileAPageIsInFlightIsRefusedAndSendsNothing() async {
        let service = ScriptedDatabaseService()
        var hookCount = 0
        let model = await editableModel(service, didWrite: { hookCount += 1 })
        service.serveCommittedWrite()

        // A refresh of the table already shown: it re-reads the schema, the count
        // and the page, and suspends inside that last read with the rows the
        // reader is looking at still on screen.
        let gate = Gate()
        service.hold(pageSQL(table: "items", identity: .rowid), on: gate)
        let held = Task { await model.select(table: "items", request: model.prepareForRowsChange()) }
        await waitUntil { gate.reached }
        XCTAssertTrue(model.isLoadingRows)

        // The token a gesture would capture *now*, which is the load's own.
        let request = model.rowsToken
        await model.updateCell(row: 0, column: 1, entry: .typed("new"), request: request)

        XCTAssertEqual(service.writeCount, 0, "Nothing is sent while the rows underneath are leaving")
        XCTAssertEqual(hookCount, 0)
        XCTAssertEqual(model.errorMessage, DatabaseEditRefusal.cellNotOnPage.message)
        XCTAssertFalse(model.isWriting)

        gate.release()
        await held.value
        XCTAssertEqual(model.rows, [[.integer(1), .text("old")]], "A refusal never blanks the page")
    }

    /// The token the gesture actually captured still writes — the refusal above is
    /// about staleness, not about passing a token at all.
    func testAWriteCarryingTheCurrentRowsTokenIsSent() async {
        let service = ScriptedDatabaseService()
        let model = await editableModel(service)
        service.serveCommittedWrite()

        let request = await model.rowsToken
        await model.updateCell(row: 0, column: 1, entry: .typed("new"), request: request)

        XCTAssertEqual(service.writeCount, 1)
        XCTAssertEqual(
            service.writeTransactions.flatMap(\.statements),
            [updateStatement(newValue: .text("new"))]
        )
    }

    /// The page a committed write re-queries is a *new* page, so it carries a new
    /// token — and a gesture captured before that write is stale against it.
    ///
    /// The re-query is the one rows-replacing load with no gesture of its own to
    /// bump a token for it, so it has to bump its own. Left on the write's token,
    /// the second edit here would pass the staleness check and be planned against
    /// the row the re-query landed — a different row, since a sort on the edited
    /// column reorders the page around what just changed — carrying *that* row's
    /// identity and *that* row's previous value, and so committing over a row
    /// nobody looked at.
    func testAPageRePublishedByACommittedWriteInvalidatesTheOlderRowsToken() async {
        let service = ScriptedDatabaseService()
        let model = await editableModel(
            service,
            pages: [itemsPage(label: .text("old")), itemsPage(label: .text("someone else's"), rowid: 9)]
        )
        service.serveCommittedWrite()
        let request = await model.rowsToken

        await model.updateCell(row: 0, column: 1, entry: .typed("new"), request: request)
        let reloaded = await model.rows
        XCTAssertEqual(reloaded, [[.integer(1), .text("someone else's")]], "The commit re-queried the page")

        // The same token again, now that the page underneath it has been replaced.
        await model.updateCell(row: 0, column: 1, entry: .typed("second"), request: request)

        XCTAssertEqual(service.writeCount, 1, "The stale gesture sends nothing")
        let message = await model.errorMessage
        XCTAssertEqual(message, DatabaseEditRefusal.cellNotOnPage.message)
        let token = await model.rowsToken
        XCTAssertNotEqual(token, request, "The re-query published under a token of its own")
    }

    /// A rename moves the name and not the inode, so the connection is left alone
    /// — but the *write* opens a path of its own, and that path has to follow.
    func testARetargetedTabWritesToItsNewPath() async {
        let service = ScriptedDatabaseService()
        let model = await editableModel(service)
        service.serveCommittedWrite()
        let renamed = url.deletingLastPathComponent().appendingPathComponent("renamed.sqlite")

        await model.retarget(to: renamed)
        await model.updateCell(row: 0, column: 1, entry: .typed("new"))

        let current = await model.fileURL
        XCTAssertEqual(current, renamed)
        XCTAssertEqual(service.writeTransactions.map(\.url), [renamed])
        XCTAssertEqual(service.closeCount, 0, "Retargeting is not a reconnect")
    }

    /// The gesture that opens an editor is the same gesture on a cell that has
    /// none, so the refusal has to be said — and said without going near the
    /// write API, which would need an entry nobody typed to refuse.
    func testReportingARefusalSaysItAndSendsNothing() async {
        let service = ScriptedDatabaseService()
        let model = await editableModel(
            service,
            pages: [itemsPage(label: .blob(byteCount: 12))]
        )
        service.serveCommittedWrite()

        await model.reportEditRefusal(row: 0, column: 1)

        let message = await model.errorMessage
        XCTAssertEqual(message, DatabaseEditRefusal.blobCell(column: "label").message)
        XCTAssertEqual(service.writeCount, 0)
    }

    /// And a cell that may be edited has nothing to say, so nothing is said: the
    /// banner is not raised by asking the wrong question.
    func testReportingARefusalForAnEditableCellSaysNothing() async {
        let service = ScriptedDatabaseService()
        let model = await editableModel(service)

        await model.reportEditRefusal(row: 0, column: 1)

        let message = await model.errorMessage
        XCTAssertNil(message)
    }

    /// A page that came back without the identity column it was asked for is
    /// *identity-less*, not a rowid strategy with no values behind it: the raw
    /// answer is published unshifted, and the edit is refused rather than
    /// addressed by a value the page never carried.
    func testAPageMissingItsIdentityColumnPublishesUnsplitAndRefusesTheEdit() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items", columns: ["id"], primaryKey: [:])
        serveProbe(on: service, table: "items")
        serveCount(on: service, table: "items", total: 1)
        service.serve(
            pageSQL(table: "items", identity: .rowid),
            columns: ["id"],
            rows: [[.integer(1)]]
        )
        service.serveCommittedWrite()
        let model = await loadedModel(service)
        await model.select(table: "items")

        XCTAssertEqual(model.gridColumns, ["id"], "The raw answer is shown, never a column short")
        XCTAssertEqual(model.rows, [[.integer(1)]])
        XCTAssertTrue(model.rowIdentityValues.isEmpty)
        XCTAssertNotNil(model.editRefusal(row: 0, column: 0))

        await model.updateCell(row: 0, column: 0, entry: .typed("new"))

        XCTAssertEqual(service.writeCount, 0, "A refusal never reaches a database")
        XCTAssertNotNil(model.errorMessage)
    }

    /// The commit landed and the page it changed cannot be re-read: the write's
    /// own banner is cleared, the read's failure takes its place in SQLite's
    /// words, and nothing is left spinning.
    func testACommittedWriteWhoseReReadFailsSaysSoAndStopsSpinning() async {
        let service = ScriptedDatabaseService()
        var hookCount = 0
        let model = await editableModel(service, didWrite: { hookCount += 1 })
        service.serveCommittedWrite()
        service.fail(
            pageSQL(table: "items", identity: .rowid),
            with: DatabaseError.sqlError(message: "database is locked")
        )

        await model.updateCell(row: 0, column: 1, entry: .typed("new"))

        XCTAssertEqual(service.writeCount, 1)
        XCTAssertEqual(hookCount, 1, "The commit stands, so the file changed")
        XCTAssertEqual(model.errorMessage, "database is locked")
        XCTAssertFalse(model.isLoadingRows, "A failed re-read must not leave the grid spinning")
        XCTAssertFalse(model.isWriting)
        XCTAssertEqual(model.rows, [[.integer(1), .text("old")]], "A failed read never blanks a good page")
    }

    /// The composite-key path end to end, off a real page answer rather than off
    /// a synthetic target: every key column's value reaches the `WHERE` **in key
    /// order**, and no trailing identity column is expected or split off.
    func testAWithoutRowIdTableWritesItsWholeKeyInKeyOrder() async {
        let service = ScriptedDatabaseService()
        serveSchema(
            on: service,
            table: "rooms",
            columns: ["house", "room", "note"],
            primaryKey: [0: 1, 1: 2]
        )
        failProbe(on: service, table: "rooms")
        serveCount(on: service, table: "rooms", total: 1)
        servePage(
            on: service,
            table: "rooms",
            columns: ["house", "room", "note"],
            rows: [[.text("Ash"), .text("3"), .text("dusty")]]
        )
        service.serveCommittedWrite()
        let model = await loadedModel(service, tables: [("rooms", "table")])
        await model.select(table: "rooms")

        XCTAssertTrue(model.canEdit(row: 0, column: 2))
        await model.updateCell(row: 0, column: 2, entry: .typed("clean"))

        XCTAssertEqual(
            service.writeTransactions.flatMap(\.statements),
            [
                DatabaseQuery.update(
                    table: "rooms",
                    column: "note",
                    identity: .primaryKey([
                        DatabaseColumnValue(name: "house", value: .text("Ash")),
                        DatabaseColumnValue(name: "room", value: .text("3")),
                    ]),
                    newValue: .text("clean"),
                    previousValue: .text("dusty")
                ),
            ]
        )
    }

    func testASelectionThatOvertakesAWriteWinsAndTheWritePublishesNothing() async {
        let service = ScriptedDatabaseService()
        var hookCount = 0
        let model = await editableModel(service, didWrite: { hookCount += 1 })
        serveSchema(on: service, table: "orders")
        serveProbe(on: service, table: "orders")
        serveCount(on: service, table: "orders", total: 1)
        servePage(
            on: service,
            table: "orders",
            identity: .rowid,
            columns: ["id", "label", "rowid"],
            rows: [[.integer(9), .text("fresh"), .integer(11)]]
        )
        service.serveCommittedWrite()
        let gate = Gate()
        service.holdWrite(on: gate)

        let held = Task { await model.updateCell(row: 0, column: 1, entry: .typed("new")) }
        await waitUntil { gate.reached }
        await model.select(table: "orders")
        gate.release()
        await held.value

        XCTAssertEqual(model.selectedTable, "orders")
        XCTAssertEqual(model.rows, [[.integer(9), .text("fresh")]], "The newer state stays on screen")
        XCTAssertEqual(service.writeCount, 1, "The commit still stands — it is the publishing that is dropped")
        XCTAssertEqual(
            hookCount,
            1,
            "The hook is about the file on disk, not about the page: a committed edit changed a tracked file "
                + "whether or not this tab still shows what it changed"
        )
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isWriting, "The only thing that raised it is the only thing that can lower it")
    }

    func testASecondEditWhileOneIsInFlightIsRefusedAndSendsNothing() async {
        let service = ScriptedDatabaseService()
        let model = await editableModel(
            service,
            pages: [itemsPage(label: .text("old")), itemsPage(label: .text("new"))]
        )
        service.serveCommittedWrite()
        let gate = Gate()
        service.holdWrite(on: gate)

        let held = Task { await model.updateCell(row: 0, column: 1, entry: .typed("new")) }
        await waitUntil { gate.reached }
        await model.updateCell(row: 0, column: 1, entry: .typed("other"))

        XCTAssertEqual(model.errorMessage, DatabaseViewerModel.writeInFlightMessage)
        XCTAssertEqual(service.writeCount, 1, "The second edit is refused, not queued")

        gate.release()
        await held.value

        XCTAssertNil(model.errorMessage, "The write that succeeded clears its own slot")
        XCTAssertEqual(model.rows, [[.integer(1), .text("new")]])
    }

    func testAWriteMessageSurvivesAListingRefreshAndAPageTurnAndGoesWithATableMove() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveProbe(on: service, table: "items")
        serveCount(on: service, table: "items", total: 4)
        service.serve(pageSQL(table: "items", identity: .rowid), with: itemsPage(label: .text("old")))
        serveSchema(on: service, table: "orders")
        serveProbe(on: service, table: "orders")
        serveCount(on: service, table: "orders", total: 1)
        servePage(
            on: service,
            table: "orders",
            identity: .rowid,
            columns: ["id", "label", "rowid"],
            rows: [[.integer(9), .text("fresh"), .integer(11)]]
        )
        service.serveRolledBackWrite(affectedRows: 0)
        let model = await loadedModel(service)
        await model.select(table: "items")

        await model.updateCell(row: 0, column: 1, entry: .typed("new"))
        let message = DatabaseViewerModel.rollbackMessage(affectedRows: 0)
        XCTAssertEqual(model.errorMessage, message)

        await model.load()
        XCTAssertEqual(model.errorMessage, message, "A listing refresh says nothing about a cell")

        await model.goToPage(1)
        XCTAssertEqual(model.errorMessage, message, "Nor does a page turn")

        await model.select(table: "orders")
        XCTAssertNil(model.errorMessage, "Moving to another table takes the sentence with the rows")
    }

    /// The other half of that rule, and the one the message's own last sentence
    /// asks for: three of the write refusals end in "Reload the table and try
    /// again", so a reload that leaves the banner up accuses the reader of a
    /// stale row over rows that were just re-read.
    func testARefreshOfTheSameTableTakesTheWriteMessageWithTheRowsItReplaces() async {
        let service = ScriptedDatabaseService()
        let model = await editableModel(service)
        service.serveRolledBackWrite(affectedRows: 0)

        await model.updateCell(row: 0, column: 1, entry: .typed("new"))
        XCTAssertEqual(model.errorMessage, DatabaseViewerModel.rollbackMessage(affectedRows: 0))

        await model.select(table: "items")

        XCTAssertNil(
            model.errorMessage,
            "A refresh re-reads the schema, the count and the page, so the cell the sentence was about "
                + "is no longer on screen to be stale"
        )
        XCTAssertEqual(model.rows, [[.integer(1), .text("old")]])
    }

    /// The reachable form of the case above: the sidebar cannot re-select the row
    /// it already has, so the refresh a reader actually meets is the one a
    /// reconnect makes — `reload()` re-opening the file and putting the selection
    /// back through `select`.
    func testAReconnectTakesAWriteMessageWithTheTableItPutsBack() async {
        let service = ScriptedDatabaseService()
        let model = await editableModel(service)
        service.serveRolledBackWrite(affectedRows: 0)

        await model.updateCell(row: 0, column: 1, entry: .typed("new"))
        XCTAssertEqual(model.errorMessage, DatabaseViewerModel.rollbackMessage(affectedRows: 0))

        await model.reload()

        XCTAssertEqual(model.selectedTable, "items")
        XCTAssertNil(model.errorMessage, "The rows the sentence named were replaced by the re-open's own")
    }

    /// And when the reconnect finds the table gone, the sentence goes with the
    /// rows for the reason the page load's does: a banner over an empty grid and
    /// an unselected sidebar explains a state that no longer exists.
    func testAReconnectThatLosesTheTableTakesItsWriteMessageToo() async {
        let service = ScriptedDatabaseService()
        let model = await editableModel(service)
        service.serveRolledBackWrite(affectedRows: 0)

        await model.updateCell(row: 0, column: 1, entry: .typed("new"))
        XCTAssertEqual(model.errorMessage, DatabaseViewerModel.rollbackMessage(affectedRows: 0))

        serveListing(on: service, entries: [("orders", "table")])
        await model.reload()

        XCTAssertNil(model.selectedTable)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - The console the tab owns

    func testRefreshAfterWriteRereadsTheListingAndRefreshesTheSelection() async {
        let service = ScriptedDatabaseService()
        let model = await editableModel(
            service,
            pages: [itemsPage(label: .text("old")), itemsPage(label: .text("new"))]
        )
        let listings = service.count(for: DatabaseQuery.tableListing.sql)

        await model.refreshAfterWrite()

        XCTAssertEqual(
            service.count(for: DatabaseQuery.tableListing.sql),
            listings + 1,
            "The listing is re-read: a batch may have created or dropped a table"
        )
        XCTAssertEqual(model.selectedTable, "items")
        XCTAssertEqual(model.rows, [[.integer(1), .text("new")]], "…and the page is re-queried")
        XCTAssertEqual(service.openedURLs, [url], "A console write does not replace the file's inode")
    }

    func testRefreshAfterWriteKeepsTheSortAndThePageIndexBecauseItReselectsAsARefresh() async {
        let service = ScriptedDatabaseService()
        serveSchema(on: service, table: "items")
        serveProbe(on: service, table: "items")
        serveCount(on: service, table: "items", total: 4)
        serveResultColumns(on: service, table: "items")
        service.serve(
            pageSQL(table: "items", identity: .rowid),
            columns: ["id", "label", "rowid"],
            rows: [[.integer(1), .text("a"), .integer(7)]]
        )
        service.serve(
            pageSQL(table: "items", orderBy: 1, ascending: true, identity: .rowid),
            columns: ["id", "label", "rowid"],
            rows: [[.integer(2), .text("b"), .integer(8)]]
        )
        let model = await loadedModel(service, pageSize: 1)
        await model.select(table: "items")
        await model.toggleSort(column: "label", index: 1)
        await model.goToPage(1)

        await model.refreshAfterWrite()

        XCTAssertEqual(model.sort, DatabaseSortState(column: "label", columnIndex: 1, direction: .ascending))
        XCTAssertEqual(model.page.index, 1)
        XCTAssertEqual(model.page.totalRows, 4, "The count is re-queried, because a batch can add rows")
    }

    func testRefreshAfterWriteShowsATableTheBatchCreated() async {
        let service = ScriptedDatabaseService()
        let model = await editableModel(service)

        serveListing(on: service, entries: [("items", "table"), ("orders", "table"), ("made", "table")])
        await model.refreshAfterWrite()

        XCTAssertEqual(model.entries.map(\.name), ["items", "orders", "made"])
        XCTAssertEqual(model.selectedTable, "items", "…and the selection is untouched by a table appearing beside it")
    }

    func testRefreshAfterWriteThatLostTheSelectedTableLandsWhereALostReloadDoes() async {
        let service = ScriptedDatabaseService()
        let model = await editableModel(service)

        serveListing(on: service, entries: [("orders", "table")])
        await model.refreshAfterWrite()

        XCTAssertNil(model.selectedTable)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.columns.isEmpty)
        XCTAssertTrue(model.gridColumns.isEmpty)
        XCTAssertNil(model.sort)
        XCTAssertEqual(model.page.index, 0)
        XCTAssertNil(model.errorMessage)
    }

    /// The token bump supersedes a page load already in flight, and a superseded
    /// load publishes nothing — including not lowering the spinner. When the
    /// listing no longer holds the selected table the re-selection returns
    /// without raising a load of its own, so nothing else would ever lower it:
    /// the grid would spin for the life of the tab and every later cell edit
    /// would be refused.
    func testRefreshAfterWriteThatLostTheSelectedTableLowersASupersededLoadsSpinner() async {
        let service = ScriptedDatabaseService()
        let model = await editableModel(service)
        let sorted = pageSQL(table: "items", orderBy: 1, ascending: true, identity: .rowid)
        service.serve(sorted, columns: ["id", "label", "rowid"], rows: [[.integer(1), .text("old"), .integer(7)]])
        let gate = Gate()
        service.hold(sorted, on: gate)

        let held = Task { await model.toggleSort(column: "label", index: 1) }
        await waitUntil { gate.reached }
        XCTAssertTrue(model.isLoadingRows, "Staging: the page load this refresh is about to supersede")

        serveListing(on: service, entries: [("orders", "table")])
        await model.refreshAfterWrite()
        gate.release()
        await held.value

        XCTAssertNil(model.selectedTable)
        XCTAssertFalse(model.isLoadingRows, "The refresh raised no load of its own, so it owes the spinner it took over")
    }

    /// The same rule when the refresh's own listing fails: `reselectIfPending()`
    /// is never reached at all, so the spinner has nobody else to lower it.
    func testRefreshAfterWriteWhoseListingFailsLowersASupersededLoadsSpinner() async {
        let service = ScriptedDatabaseService()
        let model = await editableModel(service)
        let sorted = pageSQL(table: "items", orderBy: 1, ascending: true, identity: .rowid)
        service.serve(sorted, columns: ["id", "label", "rowid"], rows: [[.integer(1), .text("old"), .integer(7)]])
        let gate = Gate()
        service.hold(sorted, on: gate)

        let held = Task { await model.toggleSort(column: "label", index: 1) }
        await waitUntil { gate.reached }

        service.fail(DatabaseQuery.tableListing.sql, with: DatabaseError.busy(message: "database is locked"))
        await model.refreshAfterWrite()
        gate.release()
        await held.value

        XCTAssertEqual(model.errorMessage, "database is locked")
        XCTAssertFalse(model.isLoadingRows, "A refresh that never reached its re-selection still owes the spinner")
    }

    /// `reload(at:)`'s identity rule, asked of the path a console batch takes.
    ///
    /// The window is real and it is wide: `confirm()` lowers `isWriting` before
    /// it awaits the refresh, and the refresh lowers `isLoadingRows` with its
    /// token bump, so for the whole of the re-read the grid is idle to
    /// `updateCell` — a gesture made now even captures the freshly-bumped token,
    /// so that guard passes too. The rows on screen are still the batch's
    /// *previous* table, and a batch may have dropped and recreated it, so what
    /// must not survive is how those rows were addressed.
    func testRefreshAfterWriteRefusesEditsUntilTheReSelectionRepublishesAnIdentity() async {
        let service = ScriptedDatabaseService()
        let model = await editableModel(service)
        XCTAssertNil(model.editRefusal(row: 0, column: 1), "Staging: the cell is editable before the batch")

        let gate = Gate()
        service.hold(DatabaseQuery.tableListing.sql, on: gate)
        let refresh = Task { await model.refreshAfterWrite() }
        await waitUntil { gate.reached }

        XCTAssertFalse(model.isWriteInFlight, "Staging: the write is over before the refresh is awaited")
        XCTAssertFalse(model.isLoadingRows, "Staging: the refresh lowered the spinner with its token bump")
        XCTAssertNotNil(
            model.editRefusal(row: 0, column: 1),
            "The rows on screen are addressed by an identity the batch may have dropped"
        )

        await model.updateCell(row: 0, column: 1, entry: .typed("new"), request: model.rowsToken)
        XCTAssertTrue(service.writeTransactions.isEmpty, "No statement may be sent against the old page's rowid")

        gate.release()
        await refresh.value
    }

    func testACommittedConsoleMutationRefreshesTheTabThroughTheWiredClosure() async {
        let service = ScriptedDatabaseService()
        let text = "DROP TABLE items"
        var didWriteCount = 0
        let model = await editableModel(service, didWrite: { didWriteCount += 1 })
        service.serveClassification(text, kinds: [.write])
        service.serveCommittedConsoleWrite(affectedRows: 0)
        serveListing(on: service, entries: [("orders", "table")])

        await model.console.run(text)
        await model.console.confirm()

        XCTAssertEqual(service.consoleTransactions.map(\.text), [text])
        XCTAssertEqual(didWriteCount, 1, "A committed batch changed a tracked file on disk")
        XCTAssertNil(model.selectedTable, "…and the dropped table went with it")
        XCTAssertEqual(model.entries.map(\.name), ["orders"])
    }

    func testTheConsoleCarriesTheTabsCurrentURLAfterARename() async {
        let service = ScriptedDatabaseService()
        let text = "DELETE FROM items"
        let renamed = URL(fileURLWithPath: "/tmp/Project/renamed.sqlite")
        let model = await editableModel(service)
        service.serveClassification(text, kinds: [.write])
        service.serveCommittedConsoleWrite(affectedRows: 1)

        model.retarget(to: renamed)
        await model.console.run(text)
        await model.console.confirm()

        XCTAssertEqual(
            service.consoleTransactions.map(\.url),
            [renamed],
            "The URL is asked for at the moment the mutation is composed, never copied at construction"
        )
    }

    func testACellEditInFlightRefusesTheConsolesMutation() async {
        let service = ScriptedDatabaseService()
        let text = "DELETE FROM items"
        let gate = Gate()
        let model = await editableModel(service)
        service.serveCommittedWrite()
        service.holdWrite(on: gate)
        service.serveClassification(text, kinds: [.write])
        service.serveCommittedConsoleWrite(affectedRows: 1)

        let editing = Task { await model.updateCell(row: 0, column: 1, entry: .typed("new")) }
        await waitUntil { gate.reached }
        XCTAssertTrue(model.isWriteInFlight, "A cell edit is a write in flight for the whole tab")

        await model.console.run(text)
        await model.console.confirm()

        XCTAssertEqual(model.console.message, DatabaseConsolePlan.runInFlightMessage)
        XCTAssertEqual(service.consoleWriteCount, 0, "One write per tab")
        gate.release()
        await editing.value
    }

    /// The mirror of `testACellEditInFlightRefusesTheConsolesMutation`: "one
    /// write per tab" is one rule read from **both** sides, so a cell edit is
    /// refused while the console's batch is still running — in the tab's own
    /// words, and with nothing sent. Without this the grid would open a second
    /// read-write connection while the batch still holds the file's write lock.
    func testAConsoleMutationInFlightRefusesACellEdit() async {
        let service = ScriptedDatabaseService()
        let text = "DELETE FROM items"
        let gate = Gate()
        let model = await editableModel(service)
        service.serveClassification(text, kinds: [.write])
        service.serveCommittedConsoleWrite(affectedRows: 1)
        service.holdConsoleWrite(on: gate)
        // Scripted so that a write escaping the guard would land rather than
        // throw: the count below has to be able to reach one.
        service.serveCommittedWrite()

        await model.console.run(text)
        let writing = Task { await model.console.confirm() }
        await waitUntil { gate.reached }

        await model.updateCell(row: 0, column: 1, entry: .typed("new"))

        XCTAssertEqual(model.errorMessage, DatabaseViewerModel.writeInFlightMessage)
        XCTAssertEqual(service.writeCount, 0, "One write per tab, refused rather than queued")

        gate.release()
        await writing.value
    }

    func testIsWriteInFlightCoversTheConsolesMutationToo() async {
        let service = ScriptedDatabaseService()
        let text = "DELETE FROM items"
        let gate = Gate()
        let model = await editableModel(service)
        service.serveClassification(text, kinds: [.write])
        service.serveCommittedConsoleWrite(affectedRows: 1)
        service.holdConsoleWrite(on: gate)
        XCTAssertFalse(model.isWriteInFlight)

        await model.console.run(text)
        let writing = Task { await model.console.confirm() }
        await waitUntil { gate.reached }

        XCTAssertTrue(model.isWriteInFlight, "…which is what the paging buttons and the sort headers disable on")
        gate.release()
        await writing.value
        XCTAssertFalse(model.isWriteInFlight)
    }

    /// The console's slot and the tab's are independent **in both directions**:
    /// neither surface's failure may erase the other's only explanation.
    func testTheConsolesMessageSlotIsIndependentOfTheViewers() async {
        let service = ScriptedDatabaseService()
        let failing = "SELECT * FROM gone"
        let model = await editableModel(
            service,
            pages: [itemsPage(label: .text("old")), itemsPage(label: .text("old"))]
        )
        service.serveClassification(failing, kinds: [.read])
        service.failConsoleRead(failing, with: DatabaseError.sqlError(message: "no such table: gone"))
        service.serveRolledBackWrite(affectedRows: 0)

        await model.updateCell(row: 0, column: 1, entry: .typed("new"))
        await model.console.run(failing)

        XCTAssertEqual(model.errorMessage, DatabaseViewerModel.rollbackMessage(affectedRows: 0))
        XCTAssertEqual(model.console.message, "no such table: gone")

        // A page turn writes and clears neither: the console's sentence is not
        // about the rows, and the grid's is not about the text.
        await model.goToPage(0)

        XCTAssertEqual(model.console.message, "no such table: gone")
    }

    func testCloseStopsTheConsole() async {
        let service = ScriptedDatabaseService()
        let text = "SELECT 1"
        let model = await editableModel(service)
        service.serveClassification(text, kinds: [.read])
        service.serveConsoleRead(text, columns: ["1"], rows: [[.integer(1)]])

        await model.close()
        await model.console.run(text)

        XCTAssertEqual(service.classifiedTexts, [], "A stopped console sends nothing into a tab that is gone")
        XCTAssertFalse(model.console.isRunning)
        XCTAssertFalse(model.isWriteInFlight)
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
        pageSize: Int = 2,
        isWriteBlocked: @escaping @MainActor () -> Bool = { false },
        didWrite: @escaping @MainActor () -> Void = {}
    ) async -> DatabaseViewerModel {
        serveListing(on: service, entries: tables)
        let model = DatabaseViewerModel(
            fileURL: url,
            service: service,
            pageSize: pageSize,
            isWriteBlocked: isWriteBlocked,
            didWrite: didWrite
        )
        await model.load()
        return model
    }

    /// A model showing one editable row of `items`: rowid-addressed, `id`
    /// declared INTEGER and `label` declared TEXT, with `label` holding "old".
    ///
    /// Where every write test starts, because the interesting half of a write
    /// test is what the model does with the *outcome* and none of it is reachable
    /// without a cell the planner agrees to compose a statement for.
    private func editableModel(
        _ service: ScriptedDatabaseService,
        pages: [DatabaseResultSet]? = nil,
        isWriteBlocked: @escaping @MainActor () -> Bool = { false },
        didWrite: @escaping @MainActor () -> Void = {}
    ) async -> DatabaseViewerModel {
        serveSchema(on: service, table: "items")
        serveProbe(on: service, table: "items")
        serveCount(on: service, table: "items", total: 1)
        service.serve(
            pageSQL(table: "items", identity: .rowid),
            sequence: pages ?? [itemsPage(label: .text("old"))]
        )
        let model = await loadedModel(service, isWriteBlocked: isWriteBlocked, didWrite: didWrite)
        await model.select(table: "items")
        return model
    }

    /// One identity-carrying page of `items` — the trailing `rowid` column
    /// included, since that is what the model splits off.
    private func itemsPage(label: DatabaseValue, rowid: Int64 = 7) -> DatabaseResultSet {
        DatabaseResultSet(
            columnNames: ["id", "label", "rowid"],
            rows: [[.integer(1), label, .integer(rowid)]]
        )
    }

    /// The statement the planner composes for `label` of that one row.
    private func updateStatement(
        newValue: DatabaseValue,
        previousValue: DatabaseValue = .text("old"),
        rowid: Int64 = 7
    ) -> DatabaseStatement {
        DatabaseQuery.update(
            table: "items",
            column: "label",
            identity: .rowid(alias: .rowid, value: .integer(rowid)),
            newValue: newValue,
            previousValue: previousValue
        )
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
