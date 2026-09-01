import Foundation

/// One open database tab's state: the tables and views it lists, the selected
/// table's schema, the page of rows on screen, where the sort is, and what went
/// wrong.
///
/// `LocalChangesModel`'s shape — a `@MainActor ObservableObject` whose I/O is
/// injected behind a seam (`DatabaseServicing`), whose published state is only
/// ever touched on the main actor, and whose overlapping loads are ordered by
/// monotonic generation tokens. Foundation only: every statement it sends is
/// composed by `DatabaseQuery` and every answer is read by `DatabaseSchema`, so
/// nothing here knows SQLite exists.
///
/// **Two tokens, because there are two independently re-triggerable loads.** The
/// table listing is re-asked by `load()`; the schema-and-page load is re-asked by
/// `select(table:)`, `goToPage(_:)` and `toggleSort(column:)`, which the reader
/// can fire faster than a large table answers. One shared token would let a
/// finished listing cancel a page load that has nothing to do with it, so the two
/// are counted apart. Each token is bumped in its method's **synchronous
/// prefix** — the run of statements before the first `await`, which the main
/// actor executes without interruption — and every result is dropped unless the
/// token it captured is still the latest. A superseded load publishes *nothing*:
/// not its rows, not its error, not its loading flag.
///
/// **A failure never blanks a good answer.** Every seam failure lands in
/// `errorMessage` and leaves the rows, the schema and the listing exactly as they
/// were, because a page that failed to refresh is still the page the reader was
/// reading and replacing it with emptiness would destroy the only context the
/// message has. The one deliberate exception is selecting a *different* table,
/// which clears the previous table's rows in its synchronous prefix: leaving them
/// under another table's name would be a lie the error message does not correct.
///
/// **Every read is bounded.** The grid never asks for a table, only ever for one
/// page of it (`DatabaseQuery.page`, `LIMIT`/`OFFSET` bound), so opening a
/// hundred-million-row table costs one page-sized read and one `count(*)`.
///
/// **A reader, and only a reader.** Part 1 sends nothing but `SELECT`s and
/// pragmas; it neither raises the disk-writer gate nor waits on it, exactly like
/// the symbol index and the terminal. Part 2's writes arrive as new seam members
/// and will make that decision for themselves.
@MainActor
public final class DatabaseViewerModel: ObservableObject {

    /// The tables and views this database holds, in the listing's order.
    @Published public private(set) var entries: [DatabaseTableEntry] = []

    /// The selected table or view's name, or `nil` before anything is selected.
    @Published public private(set) var selectedTable: String?

    /// The selected table's columns, as the pragma described them.
    @Published public private(set) var columns: [DatabaseColumn] = []

    /// The grid's column headers — the names the **page statement** answered,
    /// which is what the rows are actually positioned against.
    ///
    /// Deliberately not `columns.map(\.name)`: a hidden column appears in the
    /// pragma and not in `SELECT *`, so reading the headers off the schema would
    /// shift every cell in such a table one column to the left.
    @Published public private(set) var gridColumns: [String] = []

    /// The page of rows on screen.
    @Published public private(set) var rows: [[DatabaseValue]] = []

    /// Where the grid is in the table.
    @Published public private(set) var page: DatabasePage

    /// The sort, or `nil` for the storage order.
    @Published public private(set) var sort: DatabaseSortState?

    /// The last failure's own words, or `nil` when the last thing that happened
    /// worked. Never a sentence this layer wrote: it is SQLite's message or the
    /// schema parser's description of the shape it could not read.
    @Published public private(set) var errorMessage: String?

    /// Whether the table listing is being loaded.
    @Published public private(set) var isLoadingEntries = false

    /// Whether the schema and page are being loaded.
    @Published public private(set) var isLoadingRows = false

    /// The database this tab is showing — the URL the tab was opened with,
    /// spelled as the user spelled it.
    public let fileURL: URL

    private let service: DatabaseServicing

    /// Ordering token for the table listing.
    private var entriesGeneration = 0
    /// Ordering token for the schema-and-page load.
    private var rowsGeneration = 0

    /// Whether `open(url:)` has already succeeded on this connection, so a second
    /// `load()` (a refresh) reuses it rather than opening the file twice.
    private var isOpen = false

    /// Whether `close()` has run. Latched, so the connection is released exactly
    /// once however many times the tab owner asks — it closes on tab close and
    /// again at termination rather than tracking which already happened.
    private var isClosed = false

    /// - Parameters:
    ///   - fileURL: the database file, stored as spelled.
    ///   - service: the seam. One instance per tab: a connection is one file.
    ///   - pageSize: how many rows a page holds; injectable so the paging tests
    ///     can use a page small enough to write by hand.
    public init(fileURL: URL, service: DatabaseServicing, pageSize: Int = DatabasePage.defaultSize) {
        self.fileURL = fileURL
        self.service = service
        self.page = DatabasePage(size: pageSize)
    }

    // MARK: - Loading

    /// Open the connection if it is not open yet, then list the tables and views.
    ///
    /// Safe to call again as a refresh: the file is opened once and the listing
    /// re-asked. A failure to open is reported and leaves `isOpen` false, so the
    /// next call retries rather than running statements against nothing.
    public func load() async {
        guard !isClosed else { return }
        entriesGeneration += 1
        let generation = entriesGeneration
        isLoadingEntries = true

        do {
            if !isOpen {
                try await service.open(url: fileURL)
                // A fact about the connection, not published state, so it is
                // recorded even when this load has been superseded — the file is
                // open either way and opening it twice is what must not happen.
                isOpen = true
            }
            guard generation == entriesGeneration else { return }

            let result = try await service.run(DatabaseQuery.tableListing)
            guard generation == entriesGeneration else { return }

            entries = try DatabaseSchema.entries(from: result)
            errorMessage = nil
            isLoadingEntries = false
        } catch {
            guard generation == entriesGeneration else { return }
            errorMessage = Self.message(for: error)
            isLoadingEntries = false
        }
    }

    /// Show `table`: its columns, its row count and its first page.
    ///
    /// Selecting a table the grid is already showing is a refresh — the sort
    /// survives and the page index does not reset — while moving to another table
    /// clears both (`DatabaseSortState.carriedOver`) along with the rows the
    /// previous table owned.
    public func select(table: String) async {
        guard !isClosed else { return }
        rowsGeneration += 1
        let generation = rowsGeneration
        let previous = selectedTable
        let isMove = previous != table

        selectedTable = table
        sort = DatabaseSortState.carriedOver(sort, from: previous, to: table)
        if isMove {
            columns = []
            gridColumns = []
            rows = []
            page.reset()
        }
        isLoadingRows = true

        do {
            let schema = try await service.run(DatabaseQuery.columnSchema(table: table))
            guard generation == rowsGeneration else { return }
            columns = try DatabaseSchema.columns(from: schema)

            let counted = try await service.run(DatabaseQuery.rowCount(table: table))
            guard generation == rowsGeneration else { return }
            let total = try Self.rowCount(from: counted)
            page.setTotalRows(total)

            let result = try await service.run(pageStatement(table: table))
            guard generation == rowsGeneration else { return }
            publish(result)
        } catch {
            guard generation == rowsGeneration else { return }
            errorMessage = Self.message(for: error)
            isLoadingRows = false
        }
    }

    /// Move to page `index`, clamped to the pages that exist, and load it.
    ///
    /// A move to the page already shown is a no-op rather than a re-query: the
    /// paging controls are clickable at both ends and re-reading the same page
    /// because someone clicked "previous" on page 1 is work with no answer.
    public func goToPage(_ index: Int) async {
        guard !isClosed, let table = selectedTable else { return }
        guard page.move(to: index) else { return }
        rowsGeneration += 1
        let generation = rowsGeneration
        isLoadingRows = true
        await loadPage(table: table, generation: generation)
    }

    /// Sort by `column`, or flip the direction when it is already the sort
    /// column, and reload from the first page.
    ///
    /// The **count is kept**: an `ORDER BY` reorders rows and does not change how
    /// many there are, so re-asking `count(*)` here would be a second full-table
    /// read for an answer already in hand. The page index resets because page 3
    /// of one ordering has nothing to do with page 3 of another.
    public func toggleSort(column: String) async {
        guard !isClosed, let table = selectedTable else { return }
        sort = DatabaseSortState.toggled(sort, column: column)
        page.move(to: 0)
        rowsGeneration += 1
        let generation = rowsGeneration
        isLoadingRows = true
        await loadPage(table: table, generation: generation)
    }

    /// Release the connection.
    ///
    /// Latched, so the tab owner may call it on tab close and again at
    /// termination. Both tokens are bumped first: a load still in flight resumes
    /// to find itself superseded and publishes nothing into a tab that is gone.
    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        isOpen = false
        entriesGeneration += 1
        rowsGeneration += 1
        isLoadingEntries = false
        isLoadingRows = false
        await service.close()
    }

    // MARK: - Reading

    /// The entry `selectedTable` names, or `nil` when nothing is selected or the
    /// listing does not hold it (the table was dropped between listing and
    /// selection).
    public var selectedEntry: DatabaseTableEntry? {
        guard let selectedTable else { return nil }
        return entries.first { $0.name == selectedTable }
    }

    /// The 1-based row range on screen, or `nil` when the page is empty.
    public var displayedRows: ClosedRange<Int>? { page.displayedRows(loaded: rows.count) }

    // MARK: - One page

    private func loadPage(table: String, generation: Int) async {
        do {
            let result = try await service.run(pageStatement(table: table))
            guard generation == rowsGeneration else { return }
            publish(result)
        } catch {
            guard generation == rowsGeneration else { return }
            errorMessage = Self.message(for: error)
            isLoadingRows = false
        }
    }

    /// The one statement a page load sends — always `LIMIT`ed, never a bare
    /// `SELECT *`.
    private func pageStatement(table: String) -> DatabaseStatement {
        DatabaseQuery.page(
            table: table,
            orderBy: sort?.column,
            ascending: sort?.direction.isAscending ?? true,
            limit: page.size,
            offset: page.offset
        )
    }

    private func publish(_ result: DatabaseResultSet) {
        gridColumns = result.columnNames
        rows = result.rows
        errorMessage = nil
        isLoadingRows = false
    }

    /// The single integer `count(*)` answered.
    ///
    /// Refuses rather than guesses, like the schema parsers: a count that did not
    /// arrive as an integer is not a zero, and publishing it as one would tell the
    /// reader an occupied table is empty.
    private static func rowCount(from resultSet: DatabaseResultSet) throws -> Int {
        guard case .integer(let value)? = resultSet.value(row: 0, column: 0) else {
            throw DatabaseSchemaError.unexpectedValue(column: "count(*)", row: 0)
        }
        return Int(clamping: value)
    }

    /// What the error says — SQLite's own sentence for a `DatabaseError`, the
    /// parser's for a shape it could not read.
    private static func message(for error: Error) -> String {
        error.localizedDescription
    }
}
