import Foundation

/// One of SQLite's three spellings of a rowid table's implicit key column.
///
/// A closed type rather than a `String` for one reason, and it is the same
/// reason `DatabaseQuery` exists at all: these three names are the **only**
/// identifiers this file ever splices *unquoted*, so nothing that could carry a
/// reader's text may ever reach that splice. A case cannot; a `String`
/// parameter could, one refactor later.
///
/// The three are interchangeable to SQLite — until a table declares a column of
/// its own by one of those names, which **shadows** that spelling for that table
/// while the other two go on answering the true rowid. Which of them a given
/// table can be addressed by is therefore a fact about its schema, decided by
/// `DatabaseRowIdentity`, not something a query composer may assume.
public enum DatabaseRowIdAlias: String, Equatable, Hashable, Sendable, CaseIterable {
    case rowid
    case underscored = "_rowid_"
    case oid
}

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

    /// The three spellings of the rowid alias, in the order the identity engine
    /// prefers them — **the one name in this file that is never quoted**.
    ///
    /// Everything else spliced here goes through `quoted(_:)`, and it must; this
    /// is the stated exception, and the exception is what makes the feature
    /// correct rather than merely tidy. SQLite's double-quoted-string
    /// misfeature says that a double-quoted identifier which resolves to nothing
    /// is re-read as a string *literal*: `SELECT "rowid" FROM w LIMIT 0` against
    /// a `WITHOUT ROWID` table therefore **succeeds**, answering the four
    /// characters `rowid`. Quoted, the rowid probe would classify every
    /// `WITHOUT ROWID` table as rowid-addressable, carry the literal text
    /// `'rowid'` as every row's identity, and make every edit report that the row
    /// changed underneath the reader. Bare, all three spellings fail honestly
    /// with `no such column: rowid`, which is the answer the probe is asking for.
    ///
    /// The exception is safe because the set is **closed and chosen here**: three
    /// literals of this file's own, spliced from a `CaseIterable` enum's raw
    /// values and never from anything a reader typed. `DatabaseQueryTests`
    /// asserts the bare spelling byte-for-byte, so a later tidy-up that routed
    /// these through `quoted(_:)` fails the suite instead of the user's edit.
    public static let rowIdAliases = DatabaseRowIdAlias.allCases.map(\.rawValue)

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

    /// Whether this table can be addressed by rowid at all, asked as a statement
    /// SQLite answers.
    ///
    /// `SELECT rowid FROM "t" LIMIT ?` bound to zero: it prepares, learns
    /// nothing, and steps straight to done on a rowid table; on a
    /// `WITHOUT ROWID` table it fails **at prepare** with SQLite's own
    /// `no such column: rowid`. One prepare, no rows, no version floor — and it
    /// asks the question the feature actually has ("can I address a row here?")
    /// rather than the schema trivia `PRAGMA table_list.wr` reports.
    ///
    /// The alias is spliced bare (see `rowIdAliases`) and the table name quoted,
    /// like everywhere else. `alias` is whichever spelling the table does not
    /// shadow — `DatabaseRowIdentity.probeAlias(columns:)` picks it — because a
    /// probe of a shadowed spelling answers about the declared column instead.
    public static func rowIdProbe(table: String, alias: DatabaseRowIdAlias = .rowid) -> DatabaseStatement {
        DatabaseStatement(
            "SELECT \(alias.rawValue) FROM \(quoted(table)) LIMIT ?",
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
    ///
    /// `identityAlias` appends the rowid alias as a **trailing** result column
    /// (`SELECT *, rowid FROM "t"`), which is how a row the reader edits is
    /// addressed later. Trailing, and never anywhere else, for three reasons that
    /// are one reason: every 1-based `ORDER BY` ordinal, every grid column
    /// position and the shape probe's answer all go on meaning exactly what they
    /// meant without it. The model splits the extra column off **by position and
    /// count** before publishing, so the grid shows no column nobody asked for —
    /// by position because the trailing column's *name* is not dependable:
    /// against a table with an `INTEGER PRIMARY KEY` alias, SQLite answers it
    /// under the alias column's own name (`SELECT *, rowid FROM r` answers
    /// `id|v|id`), and only where no such alias exists is it called `rowid`.
    public static func page(
        table: String,
        orderByColumnIndex column: Int? = nil,
        ascending: Bool = true,
        limit: Int,
        offset: Int,
        identityAlias: DatabaseRowIdAlias? = nil
    ) -> DatabaseStatement {
        var sql = "SELECT *"
        if let identityAlias {
            sql += ", \(identityAlias.rawValue)"
        }
        sql += " FROM \(quoted(table))"
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

    // MARK: - Writing

    /// One cell of one row, rewritten.
    ///
    /// `UPDATE "t" SET "c" = ? WHERE <identity IS ?…> AND "c" IS ?` — the only
    /// statement in this app that changes a database, and every part of it is
    /// here for a reason:
    ///
    /// - **The `WHERE` names the row twice over.** The identity (a rowid, or
    ///   every column of a `WITHOUT ROWID` table's key in key order) says *which*
    ///   row; the trailing term says the cell still holds what the grid was
    ///   showing when the reader started typing. A row somebody else changed in
    ///   between therefore matches nothing, the affected-row count comes back
    ///   zero, and the transaction rolls back — which is how "this changed
    ///   underneath you" is detected rather than guessed at.
    /// - **`IS`, not `=`.** Both the identity values and the previous value may
    ///   be NULL, and `= NULL` is NULL — never true — so an `=` here would make
    ///   every NULL cell silently unwritable. `IS` is SQLite's null-safe
    ///   comparison, and it is what keeps NULL and the empty string distinct
    ///   through a write.
    /// - **Every value is bound; only names are spliced.** The new value, the
    ///   identity values and the previous value are parameters, so a cell
    ///   spelling `'; DROP TABLE t; --` travels as data. The table and column
    ///   names go through `quoted(_:)`; the rowid alias is the one bare name
    ///   (see `rowIdAliases`), and it is bare here for the same reason it is bare
    ///   in the probe — quoted, it would compare against the *string* `rowid`.
    /// - **Binding order is fixed** and asserted in the tests: the `SET` value
    ///   first, then the identity values in address order, then the previous
    ///   value. The app half binds positionally and knows none of this.
    public static func update(
        table: String,
        column: String,
        identity: DatabaseRowAddress,
        newValue: DatabaseValue,
        previousValue: DatabaseValue
    ) -> DatabaseStatement {
        var conditions: [String] = []
        var parameters: [DatabaseValue] = [newValue]

        switch identity {
        case .rowid(let alias, let value):
            conditions.append("\(alias.rawValue) IS ?")
            parameters.append(value)
        case .primaryKey(let keyValues):
            for keyValue in keyValues {
                conditions.append("\(quoted(keyValue.name)) IS ?")
                parameters.append(keyValue.value)
            }
        }
        conditions.append("\(quoted(column)) IS ?")
        parameters.append(previousValue)

        return DatabaseStatement(
            "UPDATE \(quoted(table)) SET \(quoted(column)) = ? WHERE \(conditions.joined(separator: " AND "))",
            parameters: parameters
        )
    }

    /// The transaction a write runs inside — its three texts, here rather than in
    /// the app half, because this file is the only thing in the repository that
    /// writes SQL and a `BEGIN` is no less SQL than a `SELECT`.
    ///
    /// `IMMEDIATE` rather than a deferred `BEGIN`: a deferred transaction takes
    /// its write lock at the first statement that needs one, so a second writer
    /// arriving in between turns into a `SQLITE_BUSY` *mid*-transaction. Asking
    /// for the lock up front means the busy timeout is spent before anything has
    /// been written, which is the failure the reader can be told about plainly.
    public static let beginImmediate = DatabaseStatement("BEGIN IMMEDIATE")

    /// Run only when the accumulated affected-row count is the one the plan
    /// required.
    public static let commit = DatabaseStatement("COMMIT")

    /// Run on every other path — a count that does not match, and any failure.
    public static let rollback = DatabaseStatement("ROLLBACK")

    /// Fold a WAL database's committed frames back into the database file itself.
    ///
    /// Run **after** the commit and outside the transaction, and only when the
    /// transaction committed. Without it a WAL database's edit is complete and
    /// durable — and invisible to everything that reads the file's *bytes*: SQLite
    /// writes committed frames to the `-wal` sidecar and folds them back only when
    /// the last connection to the database closes, and the tab's own connection is
    /// still open (and, being read-only, could not checkpoint even if it were the
    /// last). The tracked `.db` would therefore be byte-for-byte unchanged, so the
    /// `didWrite` hook would refresh Local Changes into showing nothing, `git
    /// commit` would not contain the edit, and the one way the viewer says an edit
    /// can be undone — with git — would not have anything to undo.
    ///
    /// `FULL` rather than `PASSIVE`: passive copies only what no reader is holding
    /// and reports how much it skipped, which would make "did this reach the file?"
    /// depend on timing. `RESTART`/`TRUNCATE` additionally wait for every reader to
    /// leave the WAL, which is more than is needed — the sidecar may stay, the file
    /// may not be stale. On a database that is not in WAL mode it is a no-op that
    /// answers a row of `-1`s rather than failing, so it costs a rollback-journal
    /// database one statement and nothing else.
    public static let walCheckpoint = DatabaseStatement("PRAGMA wal_checkpoint(FULL)")
}
