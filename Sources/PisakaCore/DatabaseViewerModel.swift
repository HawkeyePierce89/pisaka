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
/// `select(table:)`, `goToPage(_:)` and `toggleSort(column:index:)`, which the reader
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
///
/// **Row identity is resolved once per selection and travels hidden.** Editing
/// one cell means naming one row, and which of SQLite's two ways of doing that
/// applies is a fact about the table (`DatabaseRowIdentity`). So a selection
/// asks the rowid probe once, alongside the schema, and every page it then
/// composes carries the answer as a **trailing** result column — appended last
/// precisely so every 1-based `ORDER BY` ordinal, every grid column position and
/// the shape probe go on meaning what they meant without it. The column is split
/// back off in `publish(_:table:)` **by position and count**, never by name: on a
/// table with an `INTEGER PRIMARY KEY` alias SQLite answers the appended column
/// under the *alias column's* name (`SELECT *, rowid FROM r` answers `id|v|id`),
/// so a name match would either find the wrong column or none. `rows` and
/// `gridColumns` are therefore exactly what part 1 published, and the grid shows
/// no column the reader did not ask for.
///
/// **A probe that fails is an answer, not a failure.** A `WITHOUT ROWID` table
/// refuses the probe at prepare time with SQLite's own `no such column: rowid`,
/// and that is the probe working: it degrades to the primary-key strategy and
/// publishes no banner, because *reading* the page still works and the refusal
/// (with its own sentence) is what the reader meets only if they try to edit.
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

    /// How the selected table's rows are addressed — the fact every cell edit is
    /// planned against, resolved once per selection.
    ///
    /// `.unavailable(.noRowIdentity)` while nothing is selected, which is the
    /// honest answer to "may a cell here be edited?" for a grid with no cells: a
    /// surface asking the question before a table is chosen is told no, and told
    /// it by the same value it would be told it by afterwards.
    @Published public private(set) var rowIdentity: DatabaseRowIdentity = .unavailable(.noRowIdentity)

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

    /// The table a `reload(at:)` means to put back once the file has been listed
    /// again, or `nil` when no reconnect is waiting on one.
    ///
    /// **The reconnect cannot read its own `load()`'s success off the model.** A
    /// second `load()` — the view's `.task`, fired the moment the reader selects
    /// this tab — can start while the reconnect's own load is suspended in
    /// `open`, superseding it; the superseded load then publishes nothing and
    /// records no open, so `isOpen` says "the re-open failed" about a re-open
    /// that is in fact about to succeed. Re-selecting off that flag would skip
    /// the re-selection on exactly the interleaving that needs it most: the
    /// sidebar refreshes to the new database while the schema, the rows and the
    /// sort go on describing the *pre-operation* one, with no banner and no
    /// spinner saying so — the silence `reload` exists to break.
    ///
    /// So the intent is recorded here instead of inferred, and consumed by
    /// whichever listing load actually lands. A load that *failed* leaves it
    /// standing, which is the documented "leave the tab as it was under the
    /// banner" for the re-open in front of it and a recovery for the next one.
    private var pendingReselection: String?

    /// The alias this selection's pages carry as their trailing identity column,
    /// or `nil` when they carry none (a view, a `WITHOUT ROWID` table, a table
    /// shadowing all three spellings).
    ///
    /// Written once per selection, from the probe, and read by every page load
    /// the selection then makes — the probe is a question about the *table*, so
    /// re-asking it on a page turn or a sort toggle would be one prepare per
    /// click for an answer that cannot have changed within one selection.
    private var identityAlias: DatabaseRowIdAlias?

    /// The identity value each published row carries, positionally parallel to
    /// `rows`, and empty when the page carried none.
    ///
    /// Kept beside the rows rather than inside them: a row on screen is exactly
    /// what the grid draws, and threading an extra value through it would make
    /// every column index in this file one that has to remember whether it is
    /// counting the identity or not.
    private(set) var rowIdentityValues: [DatabaseValue] = []

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
            // The listing that lands is the one that puts a reconnect's selection
            // back — never the reconnect's own load, which may not be it.
            await reselectIfPending()
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
    /// previous table owned. A *surviving* sort is checked against the shape the
    /// table answers now (`DatabaseQuery.resultColumns`) before the page is
    /// composed, because a refresh may be reading a database rebuilt under the
    /// tab.
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
            clearRowIdentity()
            shown = nil
            page.reset()
        }
        isLoadingRows = true

        do {
            let schema = try await service.run(DatabaseQuery.columnSchema(table: table))
            guard generation == rowsGeneration else { return }
            columns = try DatabaseSchema.columns(from: schema)

            // Asked here — once per selection, with the schema and before the
            // count — because its answer decides the *shape* of every page this
            // selection composes, and a page is composed three lines down. It is
            // deliberately not part of the `do` block's failure story: a probe
            // that fails has answered (`resolveIdentityAlias`), so nothing it
            // does can reach the `catch` and put a banner over a page that reads
            // perfectly well.
            let alias = await resolveIdentityAlias(table: table)
            guard generation == rowsGeneration else { return }
            identityAlias = alias

            let counted = try await service.run(DatabaseQuery.rowCount(table: table))
            guard generation == rowsGeneration else { return }
            let total = try Self.rowCount(from: counted)
            page.setTotalRows(total)

            // A carried sort is the one sort composed against an answer this load
            // has not seen: the re-selection `reload` makes is a refresh, and the
            // database underneath may have been rebuilt with the sorted column
            // dropped or moved. The ordinal is therefore checked against the
            // shape the table answers *now*, before the page is composed —
            // `publish`'s check runs on the page's own answer, which is one
            // statement too late for both halves of the problem: a dropped column
            // leaves an ordinal SQLite rejects at prepare time, so the refresh
            // fails outright instead of coming back unsorted, and a reordered one
            // succeeds and puts a page ordered by a column nobody clicked on
            // screen before anything can notice.
            if let carried = sort {
                let shape = try await service.run(DatabaseQuery.resultColumns(table: table))
                guard generation == rowsGeneration else { return }
                if !carried.survives(columnNames: shape.columnNames) { sort = nil }
            }

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
    /// because someone clicked "previous" on page 1 is work with no answer. It is
    /// not a no-op for the *state* the click already changed, though — see
    /// `settleConsumedRequest(_:)`.
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
        guard let table = selectedTable, page.move(to: index) else {
            settleConsumedRequest(request)
            return
        }
        rowsGeneration += 1
        let generation = rowsGeneration
        isLoadingRows = true
        await loadPage(table: table, generation: generation)
    }

    /// Sort by the column the grid drew at `index`, or flip the direction when it
    /// is already the sort column, and reload from the first page.
    ///
    /// The column is named by **position**, with `column` carried along as the
    /// name that position spelled: two headers may spell the same name and only
    /// the position tells them apart (`DatabaseSortState`).
    ///
    /// The **count is kept**: an `ORDER BY` reorders rows and does not change how
    /// many there are, so re-asking `count(*)` here would be a second full-table
    /// read for an answer already in hand. The page index resets because page 3
    /// of one ordering has nothing to do with page 3 of another.
    public func toggleSort(column: String, index: Int, request: Int? = nil) async {
        guard !isClosed else { return }
        if let request, request != rowsGeneration { return }
        guard let table = selectedTable else {
            // The same settle `goToPage` makes for the same reason: the click
            // already consumed the token, so the load it superseded will publish
            // nothing — including not clearing the spinner it left up.
            settleConsumedRequest(request)
            return
        }
        sort = DatabaseSortState.toggled(sort, column: column, index: index)
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
    /// The re-selection is *recorded*, not performed here: it is consumed by
    /// whichever listing load succeeds, because this one's own may be superseded
    /// by a `load()` the reader's tab selection started (`pendingReselection`).
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
        pendingReselection = selectedTable
        entriesGeneration += 1
        rowsGeneration += 1
        isLoadingRows = false
        isOpen = false
        await service.close()
        await load()
    }

    /// Put a reconnect's selection back, once there is a listing to put it back
    /// against — see `pendingReselection` for why this is not something `reload`
    /// can do for itself when its own `load()` returns.
    ///
    /// Run by the listing load that succeeded, on the main actor, so `entries` is
    /// the new database's answer by the time the table is looked for in it.
    private func reselectIfPending() async {
        guard let table = pendingReselection else { return }
        pendingReselection = nil
        // The reader may have selected something else while the re-open was in
        // flight, and what is on screen is their click, not this reconnect's
        // memory of a click before it: putting the old table back over it would
        // be the reconnect undoing a selection the reader just made.
        guard selectedTable == table else { return }
        guard entries.contains(where: { $0.name == table }) else {
            selectedTable = nil
            columns = []
            gridColumns = []
            rows = []
            clearRowIdentity()
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
        clearRowIdentity()
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

    // MARK: - What may be edited

    /// Everything an edit is planned against — the table, its schema, the grid's
    /// columns and how its rows are addressed — or `nil` while nothing is
    /// selected.
    ///
    /// Assembled here rather than in the surface so the question "may this cell
    /// be edited?" and the statement that edits it are answered from **one**
    /// value: the grid greys a cell out from `editRefusal(row:column:)`, the
    /// planner refuses from the same target, and the two therefore cannot come
    /// to different conclusions about the same cell.
    public var editTarget: DatabaseEditTarget? {
        guard let selectedTable else { return nil }
        return DatabaseEditTarget(
            table: selectedTable,
            columns: columns,
            gridColumns: gridColumns,
            identity: rowIdentity
        )
    }

    /// Why the cell at `row`/`column` may not be edited, or `nil` when it may.
    ///
    /// The whole decision, including the per-cell half of it: a table may be
    /// perfectly addressable while *this* cell is a blob or *this* column is
    /// generated. The surface never re-derives any of it — it draws this answer
    /// and shows the refusal's own sentence when the reader tries anyway.
    public func editRefusal(row: Int, column: Int) -> DatabaseEditRefusal? {
        guard let editTarget, rows.indices.contains(row) else { return .cellNotOnPage }
        return DatabaseUpdatePlanner.refusal(
            target: editTarget,
            row: rows[row],
            rowIdentity: rowIdentityValue(at: row),
            columnIndex: column
        )
    }

    /// Whether the cell at `row`/`column` may be edited.
    public func canEdit(row: Int, column: Int) -> Bool {
        editRefusal(row: row, column: column) == nil
    }

    /// The identity value the page answered for the row at `index`, or `nil`
    /// where the page carried none.
    func rowIdentityValue(at index: Int) -> DatabaseValue? {
        guard rowIdentityValues.indices.contains(index) else { return nil }
        return rowIdentityValues[index]
    }

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
    ///
    /// `identityAlias` appends the trailing identity column when this selection
    /// has one; `splitIdentity(from:)` takes it back off before anything is
    /// published, so nothing between here and the grid has to know it was there.
    private func pageStatement(table: String) -> DatabaseStatement {
        DatabaseQuery.page(
            table: table,
            orderByColumnIndex: sort?.columnIndex,
            ascending: sort?.direction.isAscending ?? true,
            limit: page.size,
            offset: page.offset,
            identityAlias: identityAlias
        )
    }

    /// Ask the database, once per selection, whether this table's rows can be
    /// addressed by rowid — and answer `nil` rather than throwing when they
    /// cannot.
    ///
    /// The probe is `SELECT <alias> FROM "t" LIMIT 0`: free on a rowid table,
    /// and a prepare-time failure on a `WITHOUT ROWID` one. **Every** failure is
    /// read the same way, "no rowid here", which is why this cannot fail: a
    /// connection that has gone away, a table dropped between the listing and the
    /// selection and a `WITHOUT ROWID` table are indistinguishable from here, and
    /// the two that are not really about identity will fail again — loudly, with
    /// a banner — on the count or the page a moment later.
    ///
    /// A view is never probed: a view's rows are computed and have no rowid, so
    /// the probe is a statement asked to confirm what the listing already said.
    /// Nor is a table shadowing all three spellings, because there is then no
    /// spelling left to ask with (`DatabaseRowIdentity.probeAlias(columns:)`).
    private func resolveIdentityAlias(table: String) async -> DatabaseRowIdAlias? {
        guard kind(of: table) == .table else { return nil }
        guard let candidate = DatabaseRowIdentity.probeAlias(columns: columns) else { return nil }
        do {
            _ = try await service.run(DatabaseQuery.rowIdProbe(table: table, alias: candidate))
            return candidate
        } catch {
            return nil
        }
    }

    /// What the listing says `table` is.
    ///
    /// A table the listing does not hold — dropped between the listing and the
    /// selection, or selected before a listing ever landed — is treated as a
    /// table, which is the safe half of the guess: the probe then answers for
    /// itself, and a view that reached here would fail the probe and report no
    /// primary key either, landing on `.unavailable(.noRowIdentity)` rather than
    /// on an editable grid.
    private func kind(of table: String) -> DatabaseTableEntry.Kind {
        entries.first { $0.name == table }?.kind ?? .table
    }

    /// Publish what a page read answered — and drop a sort the answer no longer
    /// carries.
    ///
    /// `carriedOver` keeps the sort across a *refresh* of the same table, and
    /// `reload` re-selects the table by name after re-opening the file, so a
    /// database rebuilt under the tab (a checkout, another process) can answer a
    /// table whose columns are no longer the ones the sort was made against —
    /// dropped, renamed, or merely reordered. The sort points at a *position*, so
    /// a reordered answer is the case that bites: the ordinal would still be in
    /// range and the next page would come back ordered by whatever now sits there,
    /// under an arrow still naming the column the reader chose.
    /// `survives(columnNames:)` requires both the position and the name at it, so
    /// every one of those lands here; cleared, the next page load asks for the
    /// order that is actually on screen.
    ///
    /// `select` asks the same question of `DatabaseQuery.resultColumns` *before*
    /// composing its page, which is what keeps a stale ordinal from ever reaching
    /// SQLite; this is the same rule read off the answer itself, and it is what
    /// still catches a page turn or a sort toggle whose table was rewritten with
    /// no re-selection in between — nothing re-checks the shape on those paths,
    /// because within one selection the ordinal came from the answer on screen.
    private func publish(_ result: DatabaseResultSet, table: String) {
        let answer = splitIdentity(from: result)
        gridColumns = answer.gridColumns
        // The **grid**'s columns, not the raw answer's: with an identity column
        // appended the raw list is one longer, so a sort at the last grid column
        // would be checked against the identity column's name and dropped on
        // every page load.
        if let current = sort, !current.survives(columnNames: answer.gridColumns) { sort = nil }
        rows = answer.rows
        rowIdentityValues = answer.identities
        rowIdentity = DatabaseRowIdentity.resolve(
            kind: kind(of: table),
            columns: columns,
            answeredColumns: answer.gridColumns,
            hasRowId: answer.carriesIdentity
        )
        shown = Shown(table: table, page: page, sort: sort)
        clearError(from: .rows)
        isLoadingRows = false
    }

    /// A page answer, separated into what the grid shows and what names its rows.
    private struct SplitAnswer {
        let gridColumns: [String]
        let rows: [[DatabaseValue]]
        let identities: [DatabaseValue]
        /// Whether the trailing identity column was actually found and taken off
        /// — which is what the identity strategy is resolved against, so a page
        /// that came back without the column it was asked for is *identity-less*
        /// rather than a `.rowid` strategy with no values behind it.
        let carriesIdentity: Bool
    }

    /// Take the trailing identity column off a page answer — **by position and
    /// count**, never by name.
    ///
    /// The name is not dependable and it is not a near miss: against a table with
    /// an `INTEGER PRIMARY KEY` alias, `SELECT *, rowid FROM r` answers its
    /// columns as `id|v|id`, so a split that looked for a column called `rowid`
    /// would find none there and would find the *first* `id` on a table that
    /// happened to declare one. The column this model appended is the last one,
    /// it appended exactly one, and that is the whole rule.
    ///
    /// An answer that is not one column wider than the rows it carries is left
    /// exactly as it arrived and reported identity-less. That cannot happen —
    /// `DatabaseResultSet` promises rectangular rows and SQLite answers the
    /// column that was asked for — which is precisely why the degradation is a
    /// whole, un-split answer rather than a repair: publishing a raw answer costs
    /// the reader one visible column they did not ask for, where publishing a
    /// half-split one would shift every cell in the grid.
    private func splitIdentity(from result: DatabaseResultSet) -> SplitAnswer {
        let unsplit = SplitAnswer(
            gridColumns: result.columnNames,
            rows: result.rows,
            identities: [],
            carriesIdentity: false
        )
        guard identityAlias != nil else { return unsplit }
        let width = result.columnNames.count
        guard width > 1, result.rows.allSatisfy({ $0.count == width }) else { return unsplit }
        return SplitAnswer(
            gridColumns: Array(result.columnNames.dropLast()),
            rows: result.rows.map { Array($0.dropLast()) },
            identities: result.rows.map { $0[width - 1] },
            carriesIdentity: true
        )
    }

    /// Forget everything about how the rows on screen were named — run wherever
    /// those rows are cleared, so an identity can never outlive the page it
    /// addressed.
    private func clearRowIdentity() {
        identityAlias = nil
        rowIdentityValues = []
        rowIdentity = .unavailable(.noRowIdentity)
    }

    /// Settle the state a request that turned out to be a no-op has already
    /// invalidated.
    ///
    /// The rows token is bumped in the click, synchronously, before this model is
    /// asked anything at all — `prepareForRowsChange()` says why it has to be. So
    /// by the time a request early-returns having done nothing, a load still in
    /// flight is *already* superseded, and a superseded load publishes nothing,
    /// which includes not clearing `isLoadingRows`. Nothing else would ever clear
    /// it: the footer spins for the life of the tab, over a page index the click
    /// before it moved off the rows on screen. That is reachable from two clicks
    /// on ◀ faster than the button redraws — the first moves to page 0 and starts
    /// its load, the second reads the index that click already changed, clamps
    /// onto it and lands here.
    ///
    /// Putting the position back onto the rows that are actually there is the
    /// failure path's answer to the same question; this is that answer asked for a
    /// request that neither failed nor ran.
    ///
    /// A caller that passed **no** token — `reload`'s own re-selection, Core's
    /// tests — consumed nothing and gets the plain no-op it asked for.
    private func settleConsumedRequest(_ request: Int?) {
        guard request != nil else { return }
        restoreShownPosition()
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
