import Foundation

/// One cell, as one of SQLite's five storage classes.
///
/// Closed on purpose: SQLite has exactly these five and nothing in the viewer
/// benefits from an "unknown" case — a column whose declared type is exotic
/// still *stores* one of these, and the app half reads the storage class back
/// rather than the declaration. A value that could not be classified is a bug in
/// the app half, reported as a `DatabaseError`, not smuggled through as a sixth
/// case nobody can render.
///
/// Rendering lives here rather than in the grid so that the grid and — in part 2
/// — the SQL console's result table give the **same** answer for the same value.
/// Two renderings of NULL would be two chances to disagree about the one
/// distinction the viewer must never blur.
public enum DatabaseValue: Equatable, Hashable, Sendable {
    case integer(Int64)
    case real(Double)
    case text(String)
    /// A blob, carried as its **size alone** — never its bytes.
    ///
    /// The viewer renders a blob as a placeholder naming its length, so the bytes
    /// are read by nobody; carrying them anyway would make a page of a table of
    /// images an unbounded read in a layer whose whole discipline is that every
    /// read is one bounded page. A blob cell may hold a gigabyte, and a page holds
    /// `DatabasePage.defaultSize` rows — the app half therefore asks SQLite for
    /// the length and copies nothing, so a page of blobs costs the same as a page
    /// of integers. Part 2's cell editor, when it needs a blob's contents, will
    /// ask for *that one cell* rather than have every page carry every blob.
    case blob(byteCount: Int)
    case null

    /// Whether this is SQL `NULL`.
    ///
    /// The grid styles a null cell differently *as well as* rendering
    /// `displayText`, because a text value that spells the marker is
    /// indistinguishable from NULL in text alone — this is the question that
    /// tells them apart, and no caller should re-derive it by comparing strings.
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// How NULL is written in the grid.
    ///
    /// Non-empty by construction, which is the property that matters: an empty
    /// `text("")` cell renders as the empty string and can therefore never be
    /// mistaken for a missing value. (No `String` marker can be unforgeable
    /// against a text value that spells it out; `isNull` is the honest answer,
    /// and this is only the ink.)
    public static let nullDisplayText = "NULL"

    /// How a blob of `byteCount` bytes is written in the grid.
    ///
    /// A placeholder rather than the bytes: a blob column holds images and
    /// archives, and pasting a megabyte of binary into a table cell renders
    /// nothing anyone can read while costing the row layout everything. The size
    /// is the one fact a reader can act on.
    public static func blobDisplayText(byteCount: Int) -> String {
        byteCount == 1 ? "BLOB (1 byte)" : "BLOB (\(byteCount) bytes)"
    }

    /// The cell's text in the grid.
    public var displayText: String {
        switch self {
        case .integer(let value):
            return String(value)
        case .real(let value):
            return String(value)
        case .text(let value):
            return value
        case .blob(let byteCount):
            return Self.blobDisplayText(byteCount: byteCount)
        case .null:
            return Self.nullDisplayText
        }
    }
}

/// One statement Core wants run: the SQL text and the values bound to its
/// parameters, in the order the placeholders appear.
///
/// Core composes every byte of `sql` (see `DatabaseQuery`) and every element of
/// `parameters`; the app half binds them through the library's typed calls and
/// knows nothing about what any of it means. Keeping the two apart in the value
/// is the whole reason a table name is quoted by hand while a `LIMIT` travels as
/// a bound value: identifiers cannot be parameters, everything else can and
/// therefore must be.
public struct DatabaseStatement: Equatable, Sendable {
    /// The SQL text, with `?` placeholders for each element of `parameters`.
    public var sql: String
    /// The bound values, positionally matched to the placeholders.
    public var parameters: [DatabaseValue]

    public init(_ sql: String, parameters: [DatabaseValue] = []) {
        self.sql = sql
        self.parameters = parameters
    }
}

/// What a statement answered: the column names it produced, its rows, and how
/// many rows it changed.
///
/// A statement that returns no rows (a pragma that matched nothing, or — in part
/// 2 — an `UPDATE`) is an empty `rows` with the column names it would have
/// produced, never an error: "no rows" is an answer.
public struct DatabaseResultSet: Equatable, Sendable {
    /// The result columns in order, named as the statement declared them.
    public var columnNames: [String]
    /// The rows, each holding exactly `columnNames.count` values.
    public var rows: [[DatabaseValue]]
    /// How many rows the statement inserted, updated or deleted.
    ///
    /// Zero for every read, which the seam's implementations must make true
    /// rather than inherit: SQLite's own counter is per-*connection* and survives
    /// the reads that follow a write, so an implementation that simply asks it
    /// after a `SELECT` reports the previous statement's number. Part 2's write
    /// path is the only caller that reads this, and it reads it as the check that
    /// an `UPDATE … WHERE` touched exactly the one row it named — which is why it
    /// is carried here from the start rather than added to the seam later, and
    /// why the zero is stated as a rule here instead of assumed there.
    public var affectedRows: Int

    public init(columnNames: [String] = [], rows: [[DatabaseValue]] = [], affectedRows: Int = 0) {
        self.columnNames = columnNames
        self.rows = rows
        self.affectedRows = affectedRows
    }

    /// Whether the statement produced no rows.
    public var isEmpty: Bool { rows.isEmpty }

    /// The value at `row`/`column`, or `nil` when either index is out of range.
    ///
    /// The parsers in `DatabaseSchema` read result sets whose shape they have
    /// already checked, but a result set arrives from a library and its shape is
    /// therefore an assumption; this keeps a malformed one from trapping in a
    /// layer whose job is to report it.
    public func value(row: Int, column: Int) -> DatabaseValue? {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return nil }
        return rows[row][column]
    }
}
