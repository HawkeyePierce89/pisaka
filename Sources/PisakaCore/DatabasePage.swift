import Foundation

/// Where the grid is in a table, and how far it can move.
///
/// The whole of the viewer's paging arithmetic, kept out of the model so the
/// awkward cases are asserted directly rather than through three `await`s. Every
/// one of them is a case a real database produces: a table with no rows at all, a
/// last page shorter than the page size, and — the one that actually bites — a
/// total that **shrank** while the reader sat on a page past the new end, which
/// is what a second app deleting rows looks like from here.
///
/// **"Not yet counted" is a state, not a zero.** The count is a statement of its
/// own (`DatabaseQuery.rowCount`), so between selecting a table and its answer
/// arriving the total is genuinely unknown — and an unknown total that rendered
/// as `0` would draw "0 rows" over a table that has millions. It is therefore
/// `nil` here, `pageCount` is `nil` with it, and `hasNext` is `false`: refusing
/// to promise a next page for a moment is honest, claiming one that may not exist
/// is not.
public struct DatabasePage: Equatable, Sendable {

    /// How many rows one page holds.
    ///
    /// One number, referenced by the model and by the statement it builds rather
    /// than restated at either site: the `LIMIT` the page query binds and the
    /// arithmetic that decides which page a row is on must never be able to
    /// disagree. Large enough that ordinary tables are one or two pages, small
    /// enough that a page of a wide table is still one bounded read.
    public static let defaultSize = 200

    /// How many rows this page holds. Floored at 1 — a page of zero rows would
    /// make every page the same page and the offset arithmetic meaningless.
    public let size: Int

    /// The zero-based page index. Never negative; never past the last page once
    /// the total is known.
    public private(set) var index: Int

    /// The table's total row count, or `nil` while it has not been asked yet.
    public private(set) var totalRows: Int?

    public init(size: Int = DatabasePage.defaultSize, index: Int = 0, totalRows: Int? = nil) {
        self.size = max(1, size)
        self.totalRows = totalRows.map { max(0, $0) }
        // Assigned through the same clamp every later move uses, so a page
        // constructed out of range behaves exactly like one that drifted there.
        self.index = 0
        self.index = clamping(index)
    }

    // MARK: - Where the page is

    /// The row offset this page starts at — what the page query binds as its
    /// `OFFSET`.
    public var offset: Int { index * size }

    /// Whether the total has been counted.
    public var isCounted: Bool { totalRows != nil }

    /// How many pages the table has, or `nil` while uncounted.
    ///
    /// **A table with no rows still has one page**, which is the empty one the
    /// reader is looking at. Reporting zero pages would put the reader on page
    /// 1 of 0 and make the clamp below reject the only index that exists.
    public var pageCount: Int? {
        guard let totalRows else { return nil }
        // `(total - 1) / size + 1` rather than the more familiar
        // `(total + size - 1) / size`: the familiar one adds before it divides
        // and therefore overflows on a total near `Int.max`, which is precisely
        // what a `count(*)` clamped from SQLite's `Int64` is allowed to be. This
        // form never adds to `totalRows`, so no input can trap here. Zero is
        // handled by the guard rather than the arithmetic — see the note above on
        // why an empty table still has one page.
        guard totalRows > 0 else { return 1 }
        return (totalRows - 1) / size + 1
    }

    /// The last valid page index, or `nil` while uncounted.
    public var lastIndex: Int? { pageCount.map { $0 - 1 } }

    /// Whether a previous page exists.
    public var hasPrevious: Bool { index > 0 }

    /// Whether a next page exists — `false` while the total is unknown, which is
    /// this type's one deliberate under-promise.
    public var hasNext: Bool {
        guard let lastIndex else { return false }
        return index < lastIndex
    }

    // MARK: - Moving

    /// `candidate`, brought inside the range that exists.
    ///
    /// Clamps upward only once the total is known: before that there is no known
    /// last page to clamp against, and inventing one would refuse a jump the
    /// count is about to justify.
    public func clamping(_ candidate: Int) -> Int {
        let floored = max(0, candidate)
        guard let lastIndex else { return floored }
        return min(floored, lastIndex)
    }

    /// Move to `candidate`, clamped. Answers whether the index actually moved,
    /// so a caller can skip a re-query that would fetch the page it already has.
    @discardableResult
    public mutating func move(to candidate: Int) -> Bool {
        let clamped = clamping(candidate)
        guard clamped != index else { return false }
        index = clamped
        return true
    }

    /// Record the total the count answered, re-clamping the index onto it.
    ///
    /// This is where a shrunken table lands: a reader on page 40 of a table that
    /// now holds one page is moved to the page that exists rather than left
    /// looking at an offset past the end, which answers no rows and no
    /// explanation. Answers whether the index moved, which is the caller's cue
    /// that the page it is about to request is not the one it asked for.
    @discardableResult
    public mutating func setTotalRows(_ total: Int?) -> Bool {
        totalRows = total.map { max(0, $0) }
        let clamped = clamping(index)
        guard clamped != index else { return false }
        index = clamped
        return true
    }

    /// Return to the first page — what selecting a table or changing the sort
    /// does, since neither leaves the old offset meaning anything.
    public mutating func reset(totalRows: Int? = nil) {
        index = 0
        self.totalRows = totalRows.map { max(0, $0) }
    }

    // MARK: - What the footer says

    /// The 1-based, inclusive range of table rows this page is showing, given
    /// that `loaded` rows actually came back, or `nil` when none did.
    ///
    /// Driven by what arrived rather than by the page size, because the last page
    /// is short and a range computed from the size alone would claim rows the
    /// grid is not drawing.
    public func displayedRows(loaded: Int) -> ClosedRange<Int>? {
        guard loaded > 0 else { return nil }
        return (offset + 1)...(offset + loaded)
    }
}

/// Which column the grid is sorted by, and which way.
///
/// Separate from `DatabasePage` because the two answer different questions and
/// change on different events, but kept in the same file: a sort change resets
/// the page and a table change clears the sort, so the two rules are read
/// together or not at all.
///
/// **A column is identified by its position, not by its name.** A view may
/// legally answer two columns with the same name (`SELECT t.id, u.id FROM t JOIN
/// u` produces two columns both called `id`), which the grid already draws by
/// position for exactly that reason. A sort keyed by the name alone would sort by
/// whichever of them SQLite resolved the name to — the first — while the arrow
/// appeared on *every* header spelling it, so clicking the second `id` would
/// silently order by the first and say it had done what was asked. The position
/// is unambiguous, and it is what `DatabaseQuery.page` orders by.
public struct DatabaseSortState: Equatable, Sendable {

    /// Ascending or descending — SQLite's two, since `ORDER BY` has no third.
    public enum Direction: String, Equatable, Sendable, CaseIterable {
        case ascending
        case descending

        /// Whether this is `ASC`, which is what the page query binds.
        public var isAscending: Bool { self == .ascending }

        /// The other one.
        public var flipped: Direction { self == .ascending ? .descending : .ascending }
    }

    /// The sorted column's zero-based position among the result columns — the
    /// grid's own column identity, and what `DatabaseQuery.page` turns into the
    /// statement's `ORDER BY` ordinal.
    public var columnIndex: Int
    /// The name at that position, as the answer spelled it. Carried alongside the
    /// position rather than instead of it: the position is what orders the rows,
    /// the name is what the header draws and what `survives(columnNames:)` checks
    /// a refreshed answer against.
    public var column: String
    /// Which way.
    public var direction: Direction

    public init(column: String, columnIndex: Int, direction: Direction = .ascending) {
        self.column = column
        self.columnIndex = max(0, columnIndex)
        self.direction = direction
    }

    /// The state a click on the header at `index` produces.
    ///
    /// A **new** column sorts ascending — the reader asked to see that column
    /// ordered, and ascending is the order they mean. The **same** column flips,
    /// with no third click that clears the sort: an unsorted grid shows SQLite's
    /// arbitrary storage order, and cycling back into it through a header nobody
    /// aimed at would look like the sort had failed. Clearing is what selecting
    /// another table does, and that is the only thing that does it.
    ///
    /// "Same" is the same *position*, per the type's note: two headers may spell
    /// the same name, and flipping on the name would make a click on one of them
    /// flip the other.
    public static func toggled(
        _ current: DatabaseSortState?,
        column: String,
        index: Int
    ) -> DatabaseSortState {
        guard let current, current.columnIndex == index else {
            return DatabaseSortState(column: column, columnIndex: index, direction: .ascending)
        }
        return DatabaseSortState(column: column, columnIndex: index, direction: current.direction.flipped)
    }

    /// Whether this sort still describes a column of `columnNames`.
    ///
    /// Both halves must hold: the position must exist, and the name at it must be
    /// the one the sort was made against. A refresh can answer fewer columns (the
    /// file was replaced under the tab) or the same count in a different order,
    /// and either would leave the ordinal pointing at a column nobody asked to
    /// sort by — which is worse than no sort, because the arrow would still name
    /// the column the reader chose.
    public func survives(columnNames: [String]) -> Bool {
        columnNames.indices.contains(columnIndex) && columnNames[columnIndex] == column
    }

    /// The sort that survives a move from `previous` to `table`.
    ///
    /// Nothing survives a genuine table change: a column name is meaningful only
    /// inside its own table, so carrying `ORDER BY "price"` into a table with no
    /// `price` would order the next page by a column the reader never asked about
    /// — and not even reliably as an error, since SQLite's double-quoted-string
    /// fallback reinterprets an identifier that resolves to nothing as a string
    /// literal and sorts every row by the same constant. Re-selecting the table
    /// already showing keeps the sort, because that is a refresh and not a move;
    /// the column can nonetheless disappear under a refresh (`reload` re-selects
    /// by name after re-opening the file), which is why
    /// `DatabaseViewerModel.publish` drops a sort the answered columns no longer
    /// carry (`survives(columnNames:)`).
    public static func carriedOver(
        _ sort: DatabaseSortState?,
        from previous: String?,
        to table: String
    ) -> DatabaseSortState? {
        previous == table ? sort : nil
    }
}
