import Foundation

/// One row of `sqlite_master`, narrowed to what the viewer's sidebar lists.
///
/// The `definition` is carried **untouched** — the exact `CREATE` text SQLite
/// stored, not a re-rendering of it. Part 2's cell editing needs to know how a
/// column was declared (a generated column cannot be written, a `WITHOUT ROWID`
/// table is addressed differently), and the honest source for that is the
/// declaration itself. Re-composing it from the parsed columns would be this
/// layer inventing a fact it can only approximate.
public struct DatabaseTableEntry: Equatable, Hashable, Sendable, Identifiable {

    /// What the entry is. Closed at two cases because the listing query asks for
    /// exactly two: an index and a trigger are not things a grid can show.
    ///
    /// The raw value **is** `sqlite_master`'s `type` text, which is why it is
    /// spelled here and nowhere else — `DatabaseQuery.tableListing` and this
    /// parser are the only two readers of that vocabulary.
    public enum Kind: String, Equatable, Hashable, Sendable, CaseIterable {
        case table
        case view
    }

    /// The name as SQLite stored it — the spelling the sidebar shows and the one
    /// every later query quotes.
    public var name: String
    /// Table or view.
    public var kind: Kind
    /// The `CREATE` statement, verbatim, or `nil` where SQLite recorded none.
    public var definition: String?

    /// A name is unique across tables and views in one database, so it is the
    /// identity; nothing here needs a synthesised one.
    public var id: String { name }

    public init(name: String, kind: Kind, definition: String? = nil) {
        self.name = name
        self.kind = kind
        self.definition = definition
    }
}

/// One column of a table or view, as `PRAGMA table_xinfo` describes it.
public struct DatabaseColumn: Equatable, Hashable, Sendable, Identifiable {

    /// The column name, as declared.
    public var name: String
    /// The declared type, verbatim and possibly empty — SQLite's type affinity
    /// means a column may be declared with no type at all, which is a fact about
    /// the schema and not a parse failure.
    public var declaredType: String
    /// The column's 1-based position in the primary key, or `nil` when it is not
    /// part of one.
    ///
    /// An ordinal rather than a flag because a composite key's *order* is what
    /// part 2's `UPDATE … WHERE` will address a row by, and a `Bool` would throw
    /// it away here and force a second pragma later.
    public var primaryKeyPosition: Int?
    /// Whether the column carries `NOT NULL`.
    public var isNotNull: Bool
    /// The default as SQLite stored it — a SQL *expression* (`0`, `'x'`,
    /// `CURRENT_TIMESTAMP`), not an evaluated value, which is why it is a string
    /// and not a `DatabaseValue`.
    public var defaultExpression: String?
    /// Whether the column is hidden or generated — any non-zero `hidden` in the
    /// pragma, which covers a virtual table's hidden columns and both flavours of
    /// generated column.
    ///
    /// One flag rather than the pragma's four-way code because the only thing the
    /// viewer does with it is the same in every case: show the column, and (in
    /// part 2) refuse to write it.
    public var isHidden: Bool

    /// A column name is unique within its table.
    public var id: String { name }

    /// Whether the column is part of the primary key.
    public var isPrimaryKey: Bool { primaryKeyPosition != nil }

    public init(
        name: String,
        declaredType: String = "",
        primaryKeyPosition: Int? = nil,
        isNotNull: Bool = false,
        defaultExpression: String? = nil,
        isHidden: Bool = false
    ) {
        self.name = name
        self.declaredType = declaredType
        self.primaryKeyPosition = primaryKeyPosition
        self.isNotNull = isNotNull
        self.defaultExpression = defaultExpression
        self.isHidden = isHidden
    }
}

/// What a result set that the schema parsers cannot read says about itself.
///
/// The parsers **refuse rather than guess**. A result set arrives from a library
/// through the app half, so its shape is an assumption however carefully Core
/// composed the query that produced it; a missing column or a value of the wrong
/// storage class means the answer is not the one asked for, and inventing an
/// empty name or a `false` for it would put a lie on screen that no later layer
/// can detect. Each case names precisely what was looked for and where.
public enum DatabaseSchemaError: Error, Equatable, Sendable {
    /// A column the parser needs was not among the result set's columns.
    case missingColumn(name: String, found: [String])
    /// A value was not of the storage class its column must hold.
    case unexpectedValue(column: String, row: Int)
    /// `sqlite_master` named a `type` that is neither `table` nor `view`.
    case unknownEntryKind(String, row: Int)
}

extension DatabaseSchemaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingColumn(let name, let found):
            let listed = found.isEmpty ? "no columns" : found.joined(separator: ", ")
            return "The database answered without a “\(name)” column (it answered: \(listed))."
        case .unexpectedValue(let column, let row):
            return "The database answered an unreadable value in “\(column)” at row \(row + 1)."
        case .unknownEntryKind(let kind, let row):
            return "The database listed an unknown kind of entry, “\(kind)”, at row \(row + 1)."
        }
    }
}

/// The two pure parsers that turn a `DatabaseResultSet` into schema values.
///
/// Pure by construction: they take the result set the seam already answered and
/// never ask for another. That is what keeps every shape decision — including
/// every refusal — testable without SQLite, and it is why the column names each
/// parser reads are `public static let`s here rather than string literals buried
/// in the reading: `DatabaseQuery` composes the statements that produce these
/// result sets, and `DatabaseQueryTests` pins the two halves against each other
/// so a renamed column cannot drift past both.
public enum DatabaseSchema {

    /// The result columns `entries(from:)` reads — exactly what
    /// `DatabaseQuery.tableListing` selects, in that order.
    public static let entryColumns = ["name", "type", "sql"]

    /// The `PRAGMA table_xinfo` columns `columns(from:)` reads. The pragma
    /// answers `cid` first and this parser ignores it: a column's position is its
    /// position in the array, and carrying SQLite's id would be a second identity
    /// for the same thing.
    public static let columnPragmaColumns = ["name", "type", "notnull", "dflt_value", "pk", "hidden"]

    /// Read the table/view listing.
    ///
    /// - Throws: `DatabaseSchemaError` describing the shape it could not read.
    public static func entries(from resultSet: DatabaseResultSet) throws -> [DatabaseTableEntry] {
        guard !isShapeless(resultSet) else { return [] }
        let nameIndex = try index(of: entryColumns[0], in: resultSet)
        let kindIndex = try index(of: entryColumns[1], in: resultSet)
        let sqlIndex = try index(of: entryColumns[2], in: resultSet)

        return try resultSet.rows.indices.map { row in
            let name = try text(row: row, column: nameIndex, named: entryColumns[0], in: resultSet)
            let kindText = try text(row: row, column: kindIndex, named: entryColumns[1], in: resultSet)
            guard let kind = DatabaseTableEntry.Kind(rawValue: kindText) else {
                throw DatabaseSchemaError.unknownEntryKind(kindText, row: row)
            }
            let definition = try optionalText(row: row, column: sqlIndex, named: entryColumns[2], in: resultSet)
            return DatabaseTableEntry(name: name, kind: kind, definition: definition)
        }
    }

    /// Read one table's or view's columns, in the order the pragma listed them —
    /// which is the order they were declared in, and therefore the order the grid
    /// shows and `SELECT *` returns.
    ///
    /// - Throws: `DatabaseSchemaError` describing the shape it could not read.
    public static func columns(from resultSet: DatabaseResultSet) throws -> [DatabaseColumn] {
        // A pragma naming a table SQLite does not know answers with no columns at
        // all, not with an error. That is "there is nothing to describe", which is
        // an answer — the caller selected the table out of a listing, so a table
        // that vanished between the two is a race, not a malformed result set.
        guard !isShapeless(resultSet) else { return [] }
        let indices = try columnPragmaColumns.map { try index(of: $0, in: resultSet) }

        return try resultSet.rows.indices.map { row in
            let name = try text(row: row, column: indices[0], named: columnPragmaColumns[0], in: resultSet)
            // A column declared without a type answers as the empty string on
            // every SQLite this app runs against; NULL is accepted as the same
            // fact rather than as a failure, because "no declared type" is what
            // both spellings mean.
            let declaredType = try optionalText(row: row, column: indices[1], named: columnPragmaColumns[1], in: resultSet)
            let notNull = try integer(row: row, column: indices[2], named: columnPragmaColumns[2], in: resultSet)
            let defaultExpression = try optionalText(row: row, column: indices[3], named: columnPragmaColumns[3], in: resultSet)
            let primaryKey = try integer(row: row, column: indices[4], named: columnPragmaColumns[4], in: resultSet)
            let hidden = try integer(row: row, column: indices[5], named: columnPragmaColumns[5], in: resultSet)

            return DatabaseColumn(
                name: name,
                declaredType: declaredType ?? "",
                primaryKeyPosition: primaryKey > 0 ? Int(primaryKey) : nil,
                isNotNull: notNull != 0,
                defaultExpression: defaultExpression,
                isHidden: hidden != 0
            )
        }
    }

    // MARK: - Reading one value

    /// Whether the result set declares nothing at all — no columns and no rows.
    private static func isShapeless(_ resultSet: DatabaseResultSet) -> Bool {
        resultSet.columnNames.isEmpty && resultSet.rows.isEmpty
    }

    private static func index(of column: String, in resultSet: DatabaseResultSet) throws -> Int {
        guard let found = resultSet.columnNames.firstIndex(of: column) else {
            throw DatabaseSchemaError.missingColumn(name: column, found: resultSet.columnNames)
        }
        return found
    }

    private static func text(row: Int, column: Int, named name: String, in resultSet: DatabaseResultSet) throws -> String {
        guard case .text(let value)? = resultSet.value(row: row, column: column) else {
            throw DatabaseSchemaError.unexpectedValue(column: name, row: row)
        }
        return value
    }

    private static func optionalText(
        row: Int,
        column: Int,
        named name: String,
        in resultSet: DatabaseResultSet
    ) throws -> String? {
        switch resultSet.value(row: row, column: column) {
        case .text(let value):
            return value
        case .null:
            return nil
        default:
            throw DatabaseSchemaError.unexpectedValue(column: name, row: row)
        }
    }

    private static func integer(row: Int, column: Int, named name: String, in resultSet: DatabaseResultSet) throws -> Int64 {
        guard case .integer(let value)? = resultSet.value(row: row, column: column) else {
            throw DatabaseSchemaError.unexpectedValue(column: name, row: row)
        }
        return value
    }
}
