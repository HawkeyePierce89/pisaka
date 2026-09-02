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
/// message has. A failed read additionally puts the `page` and the `sort` back
/// onto **the rows that are actually on screen** (`shown`), since those two are
/// what the footer and the header arrow are drawn from and leaving them ahead of
/// the rows would have the chrome describing a page that is not on screen. The
/// rows on screen — never "the value the caller held before it moved" — because
/// the two part ways the moment two moves overlap: a superseded move publishes
/// nothing and undoes nothing, so the *next* failure's "previous" is a page that
/// was never drawn. The one deliberate exception is selecting a *different*
/// table, which clears the previous table's rows in its synchronous prefix:
/// leaving them under another table's name would be a lie the error message does
/// not correct.
///
/// **A failure is cleared by the load that caused it, and by no other.** The two
/// loads have their own tokens, so they have their own claim on the one message
/// slot too: `load()` runs again every time the tab is shown, and a listing that
/// refreshed successfully saying nothing about a page turn that failed would take
/// away the one sentence explaining the rows on screen.
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
    ///
    /// Not a `let`, because a tab outlives the path it was opened at: renaming
    /// the file (or any folder above it) retargets the tab, and the connection
    /// this model re-opens on `reload(at:)` has to follow it. The open handle
    /// answers off the inode and so survives a rename on its own, which is
    /// exactly what makes a stale URL here invisible until the day something
    /// re-opens it.
    public private(set) var fileURL: URL

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

    /// What the rows on screen were loaded with — the table they came from, the
    /// page they are and the sort they are in — or `nil` while the grid is empty.
    /// Written by `publish(_:table:)` alone, which is the only thing that puts
    /// rows on screen, and read by `restoreShownPosition()`.
    private var shown: Shown?

    /// Which of the two loads the current `errorMessage` belongs to, so a success
    /// on one of them cannot clear the other's message.
    private var errorSource: ErrorSource?

    private struct Shown {
        let table: String
        let page: DatabasePage
        let sort: DatabaseSortState?
    }

    private enum ErrorSource {
        case entries
        case rows
    }

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
            }
            // Recorded **only while this load is still the current one**. A
            // superseded load's open is a fact about a connection somebody else
            // has since replaced: `reload()` bumps this token, sets `isOpen`
            // false and *then* awaits `close()`, so a load resuming in between
            // that wrote `isOpen = true` would latch it true over a connection
            // the close is about to release — after which every statement throws
            // `.closed` for the life of the tab, because nothing outside
            // `reload()`/`close()` ever clears the flag again. The newest load
            // always re-asks `open` — which the seam requires to be harmless a
            // second time — and records it here, so nothing is lost by
            // discarding a superseded one's answer.
            guard generation == entriesGeneration else { return }
            isOpen = true

            let result = try await service.run(DatabaseQuery.tableListing)
            guard generation == entriesGeneration else { return }

            entries = try DatabaseSchema.entries(from: result)
            clearError(from: .entries)
            isLoadingEntries = false
        } catch {
            guard generation == entriesGeneration else { return }
            setError(error, from: .entries)
            isLoadingEntries = false
        }
    }

    /// Bump the rows token **synchronously**, ahead of the caller's `Task` hop,
    /// and hand back what the load it is about to spawn must present to be
    /// allowed to run.
    ///
    /// The `ProjectSearchModel.prepareForSearch(root:)` /
    /// `LocalChangesModel.refresh(root:requestGeneration:)` rule, and the reason
    /// the repository states it: unstructured `Task`s are not guaranteed to start
    /// in creation order, so a token bumped *inside* `select`/`toggleSort` is
    /// bumped when the task runs rather than when the click happened. Two quick
    /// sidebar clicks — table A, then B — could then start B-first, leaving A to
    /// bump last and win: the tab settles on the table the user clicked *first*,
    /// sidebar highlight, schema, rows and all, with nothing superseded and no
    /// error to say so. Captured here, the later click owns the newer token
    /// whatever order the two tasks are picked up in.
    ///
    /// A caller with nothing racing it — `reload`'s own re-selection, Core's
    /// tests — passes no request and is never rejected.
    @discardableResult
    public func prepareForRowsChange() -> Int {
        rowsGeneration += 1
        return rowsGeneration
    }

    /// Show `table`: its columns, its row count and its first page.
    ///
    /// Selecting a table the grid is already showing is a refresh — the sort
    /// survives and the page index does not reset — while moving to another table
    /// clears both (`DatabaseSortState.carriedOver`) along with the rows the
    /// previous table owned.
    public func select(table: String, request: Int? = nil) async {
        guard !isClosed else { return }
        if let request, request != rowsGeneration { return }
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
            shown = nil
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
            publish(result, table: table)
        } catch {
            guard generation == rowsGeneration else { return }
            setError(error, from: .rows)
            restoreShownPosition()
            isLoadingRows = false
        }
    }

    /// Move to page `index`, clamped to the pages that exist, and load it.
    ///
    /// A move to the page already shown is a no-op rather than a re-query: the
    /// paging controls are clickable at both ends and re-reading the same page
    /// because someone clicked "previous" on page 1 is work with no answer.
    ///
    /// `request` is the same token `select`/`toggleSort` take, and for the same
    /// reason. Two *paging* clicks do settle on the same index whichever order
    /// they are picked up in — but a paging click racing a **sidebar selection**
    /// does not: the paging task would read the newly selected table, move its
    /// still-uncounted page off index 0 and bump the token, discarding the
    /// select's schema and count and landing the tab on page 2 of a table whose
    /// schema pane is empty. The caller therefore captures both the target index
    /// and the token synchronously in the click, exactly as the other two do.
    public func goToPage(_ index: Int, request: Int? = nil) async {
        guard !isClosed else { return }
        if let request, request != rowsGeneration { return }
        guard let table = selectedTable else { return }
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
    public func toggleSort(column: String, request: Int? = nil) async {
        guard !isClosed else { return }
        if let request, request != rowsGeneration { return }
        guard let table = selectedTable else { return }
        sort = DatabaseSortState.toggled(sort, column: column)
        page.move(to: 0)
        rowsGeneration += 1
        let generation = rowsGeneration
        isLoadingRows = true
        await loadPage(table: table, generation: generation)
    }

    /// Re-open the file and re-read everything on screen — what an operation that
    /// rewrote the database under this tab calls.
    ///
    /// A viewer tab holds an open connection, and the operations that rewrite a
    /// worktree replace a file by renaming a new one over it, so the handle goes
    /// on answering out of the *unlinked* old file: after a checkout the grid, the
    /// sidebar and the schema would all describe the pre-checkout database with
    /// nothing on screen saying so. This is the viewer's `reloadFromDisk`, and
    /// like it the tab keeps its place: the selected table is re-selected when the
    /// new database still holds it, and re-selecting a table is a *refresh*, so
    /// the sort and the page index survive. A table the new database does not have
    /// is dropped, rows and all, since leaving them under a name nothing answers
    /// to is the lie a failed move already refuses to tell.
    ///
    /// A re-open that **fails** leaves the tab exactly as it was under the banner
    /// explaining why, rather than re-selecting into a closed connection and
    /// replacing the open's message with a second one about a statement.
    ///
    /// - Parameter url: where the file is *now*, when the caller knows. The tab's
    ///   url is the one thing about a viewer tab that can change under it —
    ///   `WorkspaceModel.applyRenamePlan` retargets a `.viewer` tab like any
    ///   other — and the open handle keeps answering off the renamed inode, so
    ///   the divergence surfaces only here, at the one moment the path is used
    ///   again. Re-opening the path the tab was *opened* at would report "unable
    ///   to open database file" over a file sitting in the tree under its new
    ///   name, and would go on reporting it for the life of the tab. `nil` keeps
    ///   the current url, for a caller with nothing newer to say.
    public func reload(at url: URL? = nil) async {
        guard !isClosed else { return }
        if let url { fileURL = url }
        let table = selectedTable
        entriesGeneration += 1
        rowsGeneration += 1
        isLoadingRows = false
        isOpen = false
        await service.close()
        await load()
        guard isOpen, let table else { return }
        guard entries.contains(where: { $0.name == table }) else {
            selectedTable = nil
            columns = []
            gridColumns = []
            rows = []
            sort = nil
            shown = nil
            page.reset()
            // The rows this tab was showing are gone, so a `.rows` message about
            // them goes with them: a banner left over from the page load before
            // the re-open would sit above an empty grid and an unselected sidebar,
            // explaining a state that no longer exists. `clearError` is
            // source-checked, so an `.entries` message the re-open itself set is
            // untouched.
            clearError(from: .rows)
            return
        }
        await select(table: table)
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
        shown = nil
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

    /// Load the page `page` and `sort` currently describe.
    ///
    /// A failure puts the `page` and the `sort` back onto the rows that are on
    /// screen: those two are what the footer and the header arrow are drawn from,
    /// so a page index that advanced while the rows did not would have the footer
    /// counting one page and the grid showing another, under an error banner
    /// explaining neither. A **superseded** load publishes nothing at all, and
    /// that includes not undoing state a newer request has already set.
    private func loadPage(table: String, generation: Int) async {
        do {
            let result = try await service.run(pageStatement(table: table))
            guard generation == rowsGeneration else { return }
            publish(result, table: table)
        } catch {
            guard generation == rowsGeneration else { return }
            setError(error, from: .rows)
            restoreShownPosition()
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

    private func publish(_ result: DatabaseResultSet, table: String) {
        gridColumns = result.columnNames
        rows = result.rows
        shown = Shown(table: table, page: page, sort: sort)
        clearError(from: .rows)
        isLoadingRows = false
    }

    /// Put the page and the sort back onto the rows that are actually on screen.
    ///
    /// An empty grid — nothing published yet, or a move to another table that
    /// cleared it — has no position to put back, so the page returns to uncounted
    /// and the footer says nothing rather than counting a table whose rows this
    /// model never got.
    private func restoreShownPosition() {
        guard let shown, shown.table == selectedTable else {
            page.reset()
            return
        }
        page = shown.page
        sort = shown.sort
    }

    // MARK: - The one message slot

    private func setError(_ error: Error, from source: ErrorSource) {
        errorMessage = Self.message(for: error)
        errorSource = source
    }

    /// Clear the message only when it is `source`'s own — see the type's note on
    /// why a listing refresh may not speak for a page load.
    private func clearError(from source: ErrorSource) {
        guard errorSource == source else { return }
        errorMessage = nil
        errorSource = nil
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
