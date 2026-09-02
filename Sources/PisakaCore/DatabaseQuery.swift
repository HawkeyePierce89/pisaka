import Foundation

/// The only thing in the repository that writes SQL.
///
/// Every byte the database viewer sends is composed here and asserted
/// byte-for-byte in `DatabaseQueryTests`; the app half is handed a finished
/// `DatabaseStatement` and binds it. That split has one consequence worth
/// stating plainly, because it is the reason this type exists at all:
///
/// **Identifiers cannot be parameters.** A table or column name is part of the
/// statement's *grammar*, so no `?` can stand in for it and the name must be
/// spliced into the text — which is exactly the shape an injection takes. Hence
/// `quoted(_:)`: one function, used by every splice in this file, that wraps in
/// double quotes and doubles the embedded ones, so a name containing a quote, a
/// semicolon or a space closes nothing and starts nothing. Everything that
/// *can* be a parameter therefore **must** be one, which is why `LIMIT` and
/// `OFFSET` — plain integers that would be trivial to interpolate — travel as
/// bound values instead.
public enum DatabaseQuery {

    /// `identifier`, quoted for use as a table or column name.
    ///
    /// SQL's own escape: wrap in double quotes, and double any double quote
    /// inside. Nothing is rejected — every string is a legal SQLite identifier
    /// once quoted, and a viewer that refused to open a table because of its name
    /// would be refusing to show a database SQLite is perfectly happy with.
    public static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Every table and view the viewer lists.
    ///
    /// `sqlite_master` rather than `sqlite_schema` (the modern alias) so the text
    /// runs against every SQLite this app may meet. Internal tables are excluded
    /// by their reserved `sqlite_` prefix — `sqlite_sequence` and the `sqlite_stat`
    /// family are bookkeeping, not the user's data, and the prefix is reserved, so
    /// no table of the user's can be hidden by that filter. Ordering is by name
    /// alone: grouping tables and views apart is the sidebar's presentation
    /// decision, not something to bake into the answer.
    public static let tableListing = DatabaseStatement(
        "SELECT name, type, sql FROM sqlite_master "
            + "WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' "
            + "ORDER BY name"
    )

    /// One table's or view's columns.
    ///
    /// `table_xinfo` rather than `table_info`: it answers the same rows plus the
    /// `hidden` column, which is the only way to learn that a column is generated
    /// — the fact part 2 needs in order to refuse to write it.
    ///
    /// A pragma takes no parameters, so the name is quoted, which is the whole
    /// reason `quoted(_:)` is tested as hard as it is.
    public static func columnSchema(table: String) -> DatabaseStatement {
        DatabaseStatement("PRAGMA table_xinfo(\(quoted(table)))")
    }

    /// How many rows a table or view holds.
    ///
    /// Asked separately from the page rather than derived from it, because a page
    /// is a `LIMIT`ed window and knows nothing about what lies past its end — and
    /// the paging controls need the total to say where the reader is.
    public static func rowCount(table: String) -> DatabaseStatement {
        DatabaseStatement("SELECT count(*) FROM \(quoted(table))")
    }

    /// The columns `SELECT *` answers for a table or view, and no rows.
    ///
    /// The shape of the answer, asked without reading it. A page's sort names its
    /// column by **result ordinal**, so a sort carried across a refresh has to be
    /// checked against the columns the refreshed answer actually has *before* the
    /// page is composed: an ordinal the answer lost is rejected at prepare time
    /// (`ORDER BY 2` against a one-column `SELECT *` is an error, not an
    /// unsorted page), and an ordinal some other column moved into succeeds while
    /// ordering by a column nobody clicked. Neither is something a page's own
    /// answer can be asked about, because by then the statement has already run.
    ///
    /// `LIMIT ?` bound to zero, per this file's rule that everything that can be
    /// a parameter must be one — and zero is what makes it free: SQLite prepares
    /// the statement, learns the column names from it, and steps straight to
    /// done without touching a row.
    public static func resultColumns(table: String) -> DatabaseStatement {
        DatabaseStatement(
            "SELECT * FROM \(quoted(table)) LIMIT ?",
            parameters: [.integer(0)]
        )
    }

    /// One page of a table or view, optionally sorted.
    ///
    /// `limit` and `offset` are **bound**, and both are floored at zero. The floor
    /// is not defensive tidiness: SQLite reads a *negative* `LIMIT` as "no limit
    /// at all", so a negative slipping through here would turn the one statement
    /// that must always be bounded into a full-table select — the failure this
    /// layer exists to make impossible. A zero limit is an honest empty page.
    ///
    /// The sort names its column by **result-column ordinal** (`ORDER BY 3`),
    /// which is SQLite's own way of pointing at the third column of the answer,
    /// rather than by name. `SELECT *` over a view may answer two columns with the
    /// same name, and `ORDER BY "id"` against such an answer silently resolves to
    /// the first of them — ordering by a column the reader did not click. The
    /// ordinal is exactly the position the grid drew, so the two cannot disagree;
    /// it is 1-based, so `orderByColumnIndex` (the grid's zero-based position) has
    /// one added to it here. An ordinal is a number, not an identifier, so nothing
    /// is spliced and `quoted(_:)` has one caller fewer.
    public static func page(
        table: String,
        orderByColumnIndex column: Int? = nil,
        ascending: Bool = true,
        limit: Int,
        offset: Int
    ) -> DatabaseStatement {
        var sql = "SELECT * FROM \(quoted(table))"
        if let column, column >= 0 {
            sql += " ORDER BY \(column + 1) \(ascending ? "ASC" : "DESC")"
        }
        sql += " LIMIT ? OFFSET ?"
        return DatabaseStatement(
            sql,
            parameters: [
                .integer(Int64(max(0, limit))),
                .integer(Int64(max(0, offset))),
            ]
        )
    }
}
