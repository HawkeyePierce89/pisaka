import XCTest
@testable import PisakaCore

/// Every statement the read-only viewer sends, asserted byte-for-byte with its
/// parameter list.
///
/// Byte-for-byte rather than "contains", because this is the one file in the
/// repository that writes SQL and the two things that can go wrong with it are
/// both invisible to a looser assertion: an identifier spliced without quoting
/// (which is an injection), and a bound value quietly becoming an interpolated
/// one (which is the same thing with an extra step).
final class DatabaseQueryTests: XCTestCase {

    // MARK: - Quoting

    func testQuotingWrapsAPlainIdentifier() {
        XCTAssertEqual(DatabaseQuery.quoted("albums"), "\"albums\"")
    }

    func testQuotingDoublesAnEmbeddedDoubleQuote() {
        XCTAssertEqual(DatabaseQuery.quoted("od\"d"), "\"od\"\"d\"")
        XCTAssertEqual(DatabaseQuery.quoted("\""), "\"\"\"\"")
        XCTAssertEqual(DatabaseQuery.quoted("\"\""), "\"\"\"\"\"\"")
    }

    /// The characters that would end a statement and start another one if the
    /// name were spliced raw. Quoted, they are just letters in a name.
    func testQuotingNeutralisesStatementPunctuation() {
        XCTAssertEqual(DatabaseQuery.quoted("drop; --"), "\"drop; --\"")
        XCTAssertEqual(DatabaseQuery.quoted("two words"), "\"two words\"")
        XCTAssertEqual(DatabaseQuery.quoted("it's"), "\"it's\"")
        XCTAssertEqual(DatabaseQuery.quoted("a\nb"), "\"a\nb\"")
    }

    /// Nothing is rejected: every string is a legal identifier once quoted, and a
    /// viewer that refused a table because of its name would be refusing to show a
    /// database SQLite is perfectly happy with.
    func testQuotingRefusesNothing() {
        XCTAssertEqual(DatabaseQuery.quoted(""), "\"\"")
        XCTAssertEqual(DatabaseQuery.quoted("日本語"), "\"日本語\"")
    }

    // MARK: - The listing

    func testTableListingIsWhatItIs() {
        XCTAssertEqual(
            DatabaseQuery.tableListing.sql,
            "SELECT name, type, sql FROM sqlite_master "
                + "WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' "
                + "ORDER BY name"
        )
        XCTAssertEqual(DatabaseQuery.tableListing.parameters, [])
    }

    /// The half of the pairing a test can see: the listing selects exactly the
    /// columns its parser reads, in that order. Renaming one without the other
    /// fails here rather than at a user's empty sidebar.
    func testTableListingSelectsExactlyWhatTheParserReads() {
        let selected = DatabaseSchema.entryColumns.joined(separator: ", ")
        XCTAssertTrue(
            DatabaseQuery.tableListing.sql.hasPrefix("SELECT \(selected) FROM "),
            DatabaseQuery.tableListing.sql
        )
    }

    /// The underscore in the reserved prefix is escaped: unescaped it is `LIKE`'s
    /// single-character wildcard, and the filter would then also hide a table
    /// named `sqliteX…`.
    func testTableListingEscapesTheWildcardInTheReservedPrefix() {
        XCTAssertTrue(DatabaseQuery.tableListing.sql.contains("'sqlite\\_%' ESCAPE '\\'"))
    }

    // MARK: - The column pragma

    func testColumnSchemaAsksTheExtendedPragma() {
        XCTAssertEqual(
            DatabaseQuery.columnSchema(table: "albums"),
            DatabaseStatement("PRAGMA table_xinfo(\"albums\")")
        )
    }

    func testColumnSchemaQuotesTheTableName() {
        XCTAssertEqual(
            DatabaseQuery.columnSchema(table: "od\"d name").sql,
            "PRAGMA table_xinfo(\"od\"\"d name\")"
        )
        XCTAssertEqual(DatabaseQuery.columnSchema(table: "od\"d name").parameters, [])
    }

    // MARK: - The row count

    func testRowCountCountsTheWholeTable() {
        XCTAssertEqual(
            DatabaseQuery.rowCount(table: "albums"),
            DatabaseStatement("SELECT count(*) FROM \"albums\"")
        )
        XCTAssertEqual(
            DatabaseQuery.rowCount(table: "drop; --").sql,
            "SELECT count(*) FROM \"drop; --\""
        )
    }

    // MARK: - The answer's shape

    /// The shape probe reads no rows: it is the page statement's `SELECT *` with
    /// the limit bound to zero, so SQLite answers the column names off the
    /// prepared statement and steps straight to done.
    func testResultColumnsAsksForNoRows() {
        XCTAssertEqual(
            DatabaseQuery.resultColumns(table: "albums"),
            DatabaseStatement("SELECT * FROM \"albums\" LIMIT ?", parameters: [.integer(0)])
        )
    }

    /// The zero is bound like every other bound this file writes, and the table
    /// name is spliced and therefore quoted.
    func testResultColumnsQuotesTheTableAndBindsTheZero() {
        let statement = DatabaseQuery.resultColumns(table: "od\"d")

        XCTAssertEqual(statement.sql, "SELECT * FROM \"od\"\"d\" LIMIT ?")
        XCTAssertFalse(statement.sql.contains("0"))
        XCTAssertEqual(statement.parameters, [.integer(0)])
    }

    /// It is not the page statement: a test — or a reader — that could not tell
    /// the two apart could not tell a probe from a read of the whole first page
    /// either.
    func testResultColumnsIsNotThePageStatement() {
        XCTAssertNotEqual(
            DatabaseQuery.resultColumns(table: "albums").sql,
            DatabaseQuery.page(table: "albums", limit: 0, offset: 0).sql
        )
    }

    // MARK: - The rowid probe

    /// One prepare, zero rows: the limit is bound to zero exactly as the shape
    /// probe's is, so a rowid table answers nothing and a `WITHOUT ROWID` table
    /// fails at prepare with SQLite's own `no such column: rowid`.
    func testRowIdProbeAsksForNoRows() {
        XCTAssertEqual(
            DatabaseQuery.rowIdProbe(table: "albums", alias: .rowid),
            DatabaseStatement("SELECT rowid FROM \"albums\" LIMIT ?", parameters: [.integer(0)])
        )
    }

    /// **The one unquoted name in the file.** Quoted, SQLite's
    /// double-quoted-string fallback re-reads an unresolved identifier as a
    /// string literal, so the probe would succeed against every `WITHOUT ROWID`
    /// table and answer the text `rowid` — classifying it as addressable and
    /// making every edit report that the row changed underneath the reader.
    func testRowIdProbeSplicesTheAliasBare() {
        let sql = DatabaseQuery.rowIdProbe(table: "albums", alias: .rowid).sql

        XCTAssertTrue(sql.hasPrefix("SELECT rowid FROM "), sql)
        XCTAssertFalse(sql.contains("\"rowid\""), sql)
        XCTAssertFalse(sql.contains(DatabaseQuery.quoted("rowid")), sql)
    }

    /// The other two spellings, spliced the same way — the one a table shadowing
    /// `rowid` is probed with.
    func testRowIdProbeSplicesEachSpellingBare() {
        XCTAssertEqual(
            DatabaseQuery.rowIdProbe(table: "t", alias: .underscored).sql,
            "SELECT _rowid_ FROM \"t\" LIMIT ?"
        )
        XCTAssertEqual(
            DatabaseQuery.rowIdProbe(table: "t", alias: .oid).sql,
            "SELECT oid FROM \"t\" LIMIT ?"
        )
    }

    /// The table name is not the alias: it is spliced and therefore quoted, so a
    /// name carrying a quote closes nothing.
    func testRowIdProbeQuotesTheTableName() {
        XCTAssertEqual(
            DatabaseQuery.rowIdProbe(table: "od\"d; --", alias: .rowid).sql,
            "SELECT rowid FROM \"od\"\"d; --\" LIMIT ?"
        )
    }

    /// A closed set of three, in the order the identity engine prefers them —
    /// and the constant is the enum's own raw values, so the two cannot drift.
    func testTheAliasSetIsClosedAtThreeSpellings() {
        XCTAssertEqual(DatabaseQuery.rowIdAliases, ["rowid", "_rowid_", "oid"])
        XCTAssertEqual(DatabaseRowIdAlias.allCases.map(\.rawValue), DatabaseQuery.rowIdAliases)
    }

    // MARK: - The page

    func testUnsortedPageIsBoundedAndBound() {
        XCTAssertEqual(
            DatabaseQuery.page(table: "albums", limit: 100, offset: 0),
            DatabaseStatement(
                "SELECT * FROM \"albums\" LIMIT ? OFFSET ?",
                parameters: [.integer(100), .integer(0)]
            )
        )
    }

    /// The sort names its column by **1-based result ordinal**, not by name: a
    /// view may answer two columns spelling the same name and `ORDER BY "id"`
    /// would resolve to the first of them whichever header was clicked.
    func testSortedPageOrdersByTheResultColumnOrdinal() {
        XCTAssertEqual(
            DatabaseQuery.page(table: "albums", orderByColumnIndex: 0, ascending: true, limit: 50, offset: 150),
            DatabaseStatement(
                "SELECT * FROM \"albums\" ORDER BY 1 ASC LIMIT ? OFFSET ?",
                parameters: [.integer(50), .integer(150)]
            )
        )
        XCTAssertEqual(
            DatabaseQuery.page(table: "albums", orderByColumnIndex: 2, ascending: false, limit: 50, offset: 0),
            DatabaseStatement(
                "SELECT * FROM \"albums\" ORDER BY 3 DESC LIMIT ? OFFSET ?",
                parameters: [.integer(50), .integer(0)]
            )
        )
    }

    /// The table name is still spliced and therefore still quoted; the sort no
    /// longer splices anything at all, so a column named `col; drop` cannot reach
    /// the text however the grid drew it.
    func testSortedPageQuotesTheTableAndSplicesNoColumnName() {
        XCTAssertEqual(
            DatabaseQuery.page(table: "od\"d", orderByColumnIndex: 1, limit: 1, offset: 2).sql,
            "SELECT * FROM \"od\"\"d\" ORDER BY 2 ASC LIMIT ? OFFSET ?"
        )
    }

    /// A negative ordinal is not a column, and `ORDER BY 0` is out of range for
    /// every answer — so it orders by nothing rather than failing the read.
    func testNegativeSortColumnOrdersByNothing() {
        XCTAssertEqual(
            DatabaseQuery.page(table: "albums", orderByColumnIndex: -1, limit: 1, offset: 0).sql,
            "SELECT * FROM \"albums\" LIMIT ? OFFSET ?"
        )
    }

    /// SQLite reads a negative `LIMIT` as "no limit at all", so a negative
    /// reaching the text would turn the one statement that must always be bounded
    /// into a full-table select. Both bounds are floored at zero instead.
    func testNegativeBoundsAreFlooredRatherThanPassedThrough() {
        XCTAssertEqual(
            DatabaseQuery.page(table: "albums", limit: -1, offset: -10).parameters,
            [.integer(0), .integer(0)]
        )
    }

    /// Whatever the bounds are, the statement carries them as parameters and
    /// never as text — the property that keeps the page query one prepared
    /// statement rather than a new one per page.
    func testTheBoundsNeverReachTheText() {
        let statement = DatabaseQuery.page(table: "albums", orderByColumnIndex: 0, limit: 100, offset: 400)

        XCTAssertFalse(statement.sql.contains("100"))
        XCTAssertFalse(statement.sql.contains("400"))
        XCTAssertEqual(statement.parameters, [.integer(100), .integer(400)])
        XCTAssertEqual(statement.sql.filter { $0 == "?" }.count, statement.parameters.count)
    }

    // MARK: - The page's identity column

    /// The identity column is appended **last**, so the grid's columns are the
    /// first `n` of the answer and the split is by position and count.
    func testAnIdentityCarryingPageAppendsTheAliasLast() {
        XCTAssertEqual(
            DatabaseQuery.page(table: "albums", limit: 100, offset: 0, identityAlias: .rowid),
            DatabaseStatement(
                "SELECT *, rowid FROM \"albums\" LIMIT ? OFFSET ?",
                parameters: [.integer(100), .integer(0)]
            )
        )
    }

    /// Bare here too, and for the same reason it is bare in the probe: quoted, it
    /// would silently become the string `rowid` in every row.
    func testTheIdentityColumnIsSplicedBare() {
        let sql = DatabaseQuery.page(table: "albums", limit: 1, offset: 0, identityAlias: .rowid).sql

        XCTAssertTrue(sql.hasPrefix("SELECT *, rowid FROM "), sql)
        XCTAssertFalse(sql.contains("\"rowid\""), sql)
        XCTAssertEqual(
            DatabaseQuery.page(table: "t", limit: 1, offset: 0, identityAlias: .underscored).sql,
            "SELECT *, _rowid_ FROM \"t\" LIMIT ? OFFSET ?"
        )
        XCTAssertEqual(
            DatabaseQuery.page(table: "t", limit: 1, offset: 0, identityAlias: .oid).sql,
            "SELECT *, oid FROM \"t\" LIMIT ? OFFSET ?"
        )
    }

    /// The whole point of appending it last: the sort ordinal goes on pointing at
    /// the column the grid drew, byte-for-byte the same `ORDER BY` as without it.
    func testTheAppendedColumnLeavesTheSortOrdinalAlone() {
        let sorted = DatabaseQuery.page(
            table: "albums",
            orderByColumnIndex: 2,
            ascending: false,
            limit: 50,
            offset: 150,
            identityAlias: .rowid
        )

        XCTAssertEqual(
            sorted,
            DatabaseStatement(
                "SELECT *, rowid FROM \"albums\" ORDER BY 3 DESC LIMIT ? OFFSET ?",
                parameters: [.integer(50), .integer(150)]
            )
        )
        let unsorted = DatabaseQuery.page(table: "albums", orderByColumnIndex: 2, ascending: false, limit: 50, offset: 150)
        XCTAssertEqual(
            sorted.sql.replacingOccurrences(of: "SELECT *, rowid", with: "SELECT *"),
            unsorted.sql
        )
        XCTAssertEqual(sorted.parameters, unsorted.parameters)
    }

    /// No alias is part 1's statement, unchanged — the default that keeps every
    /// existing call site meaning what it meant.
    func testNoIdentityAliasIsPartOnesStatement() {
        XCTAssertEqual(
            DatabaseQuery.page(table: "albums", limit: 10, offset: 0, identityAlias: nil),
            DatabaseQuery.page(table: "albums", limit: 10, offset: 0)
        )
        XCTAssertFalse(DatabaseQuery.page(table: "albums", limit: 10, offset: 0).sql.contains("rowid"))
    }

    /// The bounds stay bound with the identity column present: nothing about the
    /// floors or the parameter list moved.
    func testAnIdentityCarryingPageStillBindsItsBounds() {
        let statement = DatabaseQuery.page(table: "albums", limit: -1, offset: -10, identityAlias: .oid)

        XCTAssertEqual(statement.parameters, [.integer(0), .integer(0)])
        XCTAssertEqual(statement.sql.filter { $0 == "?" }.count, 2)
    }

    // MARK: - The update

    /// The one statement in this app that changes a database, byte-for-byte:
    /// the identity names the row, the trailing term says the cell still holds
    /// what the grid showed, and both are compared with `IS`.
    func testTheUpdateNamesTheRowAndTheOldValue() {
        XCTAssertEqual(
            DatabaseQuery.update(
                table: "albums",
                column: "title",
                identity: .rowid(alias: .rowid, value: .integer(7)),
                newValue: .text("new"),
                previousValue: .text("old")
            ),
            DatabaseStatement(
                "UPDATE \"albums\" SET \"title\" = ? WHERE rowid IS ? AND \"title\" IS ?",
                parameters: [.text("new"), .integer(7), .text("old")]
            )
        )
    }

    /// A composite key contributes one term per column, in the order it was
    /// handed — which is key order, decided by the identity engine.
    func testACompositeKeyContributesOneTermPerColumnInOrder() {
        XCTAssertEqual(
            DatabaseQuery.update(
                table: "rooms",
                column: "note",
                identity: .primaryKey([
                    DatabaseColumnValue(name: "house", value: .text("Ash")),
                    DatabaseColumnValue(name: "room", value: .integer(3)),
                ]),
                newValue: .text("clean"),
                previousValue: .null
            ),
            DatabaseStatement(
                "UPDATE \"rooms\" SET \"note\" = ? WHERE \"house\" IS ? AND \"room\" IS ? AND \"note\" IS ?",
                parameters: [.text("clean"), .text("Ash"), .integer(3), .null]
            )
        )
    }

    /// `IS`, never `=`. Both the identity and the previous value may be NULL, and
    /// `= NULL` is NULL — never true — so an `=` would make every NULL cell
    /// silently unwritable and every NULL-keyed row unnameable.
    func testTheUpdateComparesWithIsRatherThanEquals() {
        let sql = DatabaseQuery.update(
            table: "t",
            column: "c",
            identity: .rowid(alias: .rowid, value: .null),
            newValue: .null,
            previousValue: .null
        ).sql

        XCTAssertEqual(sql, "UPDATE \"t\" SET \"c\" = ? WHERE rowid IS ? AND \"c\" IS ?")
        XCTAssertFalse(sql.contains("IS NULL"), sql)
        XCTAssertFalse(sql.uppercased().contains("NULL"), sql)
    }

    /// Bare here too — quoted, the alias would compare each row against the
    /// four-character string `rowid`, match nothing, and report that every row
    /// changed underneath the reader.
    func testTheUpdateSplicesEachAliasSpellingBare() {
        for alias in DatabaseRowIdAlias.allCases {
            let sql = DatabaseQuery.update(
                table: "t",
                column: "c",
                identity: .rowid(alias: alias, value: .integer(1)),
                newValue: .text("v"),
                previousValue: .text("u")
            ).sql

            XCTAssertEqual(sql, "UPDATE \"t\" SET \"c\" = ? WHERE \(alias.rawValue) IS ? AND \"c\" IS ?")
            XCTAssertFalse(sql.contains(DatabaseQuery.quoted(alias.rawValue)), sql)
        }
    }

    /// Every identifier is spliced and therefore quoted; a key column's name is
    /// no different from the table's.
    func testTheUpdateQuotesEveryIdentifierItSplices() {
        let sql = DatabaseQuery.update(
            table: "od\"d; --",
            column: "two words",
            identity: .primaryKey([DatabaseColumnValue(name: "k\"ey", value: .integer(1))]),
            newValue: .text("v"),
            previousValue: .text("u")
        ).sql

        XCTAssertEqual(
            sql,
            "UPDATE \"od\"\"d; --\" SET \"two words\" = ? WHERE \"k\"\"ey\" IS ? AND \"two words\" IS ?"
        )
    }

    /// Values never reach the text, and the binding order is fixed: the `SET`
    /// value, the identity values in address order, the previous value.
    func testTheUpdateBindsEveryValueInAFixedOrder() {
        let statement = DatabaseQuery.update(
            table: "t",
            column: "c",
            identity: .primaryKey([
                DatabaseColumnValue(name: "a", value: .text("'; DROP TABLE t; --")),
                DatabaseColumnValue(name: "b", value: .real(1.5)),
            ]),
            newValue: .text("42"),
            previousValue: .integer(41)
        )

        XCTAssertEqual(
            statement.parameters,
            [.text("42"), .text("'; DROP TABLE t; --"), .real(1.5), .integer(41)]
        )
        XCTAssertEqual(statement.sql.filter { $0 == "?" }.count, statement.parameters.count)
        XCTAssertFalse(statement.sql.contains("DROP"))
        XCTAssertFalse(statement.sql.contains("42"))
        XCTAssertFalse(statement.sql.contains("1.5"))
    }

    // MARK: - The transaction

    /// The three texts live here, like every other byte of SQL in this app —
    /// `IMMEDIATE` so the write lock is taken before anything is written and a
    /// busy database fails plainly rather than mid-transaction.
    func testTheTransactionTextsAreWhatTheyAre() {
        XCTAssertEqual(DatabaseQuery.beginImmediate, DatabaseStatement("BEGIN IMMEDIATE"))
        XCTAssertEqual(DatabaseQuery.commit, DatabaseStatement("COMMIT"))
        XCTAssertEqual(DatabaseQuery.rollback, DatabaseStatement("ROLLBACK"))
        XCTAssertEqual(DatabaseQuery.beginImmediate.parameters, [])
        XCTAssertEqual(DatabaseQuery.commit.parameters, [])
        XCTAssertEqual(DatabaseQuery.rollback.parameters, [])
    }

    /// Foreign keys are the one declared constraint SQLite leaves off unless a
    /// connection asks, so the write path asks — and pinned by text because `ON`
    /// silently becoming `OFF` is a write that orphans a row and reports success.
    func testForeignKeyEnforcementIsAskedForAndCarriesNoParameters() {
        XCTAssertEqual(DatabaseQuery.foreignKeysOn, DatabaseStatement("PRAGMA foreign_keys = ON"))
        XCTAssertEqual(DatabaseQuery.foreignKeysOn.parameters, [])
    }

    /// `FULL`, and pinned by text: a committed edit that never leaves the `-wal`
    /// sidecar is invisible to Local Changes, to `git commit` and therefore to the
    /// only undo the viewer offers. `PASSIVE` would make reaching the file depend
    /// on what a reader happened to be holding.
    func testTheCheckpointIsFullAndCarriesNoParameters() {
        XCTAssertEqual(DatabaseQuery.walCheckpoint, DatabaseStatement("PRAGMA wal_checkpoint(FULL)"))
        XCTAssertEqual(DatabaseQuery.walCheckpoint.parameters, [])
    }
}
