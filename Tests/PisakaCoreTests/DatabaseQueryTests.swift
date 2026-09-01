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

    func testSortedPageOrdersByAQuotedColumn() {
        XCTAssertEqual(
            DatabaseQuery.page(table: "albums", orderBy: "title", ascending: true, limit: 50, offset: 150),
            DatabaseStatement(
                "SELECT * FROM \"albums\" ORDER BY \"title\" ASC LIMIT ? OFFSET ?",
                parameters: [.integer(50), .integer(150)]
            )
        )
        XCTAssertEqual(
            DatabaseQuery.page(table: "albums", orderBy: "title", ascending: false, limit: 50, offset: 0),
            DatabaseStatement(
                "SELECT * FROM \"albums\" ORDER BY \"title\" DESC LIMIT ? OFFSET ?",
                parameters: [.integer(50), .integer(0)]
            )
        )
    }

    func testSortedPageQuotesBothIdentifiers() {
        XCTAssertEqual(
            DatabaseQuery.page(table: "od\"d", orderBy: "col; drop", limit: 1, offset: 2).sql,
            "SELECT * FROM \"od\"\"d\" ORDER BY \"col; drop\" ASC LIMIT ? OFFSET ?"
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
        let statement = DatabaseQuery.page(table: "albums", orderBy: "title", limit: 100, offset: 400)

        XCTAssertFalse(statement.sql.contains("100"))
        XCTAssertFalse(statement.sql.contains("400"))
        XCTAssertEqual(statement.parameters, [.integer(100), .integer(400)])
        XCTAssertEqual(statement.sql.filter { $0 == "?" }.count, statement.parameters.count)
    }
}
