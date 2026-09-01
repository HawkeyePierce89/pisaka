import XCTest
@testable import PisakaCore

/// The two pure schema parsers: what they read out of a result set, and — the
/// half that matters more — what they refuse.
///
/// Both parsers stand between a C library and a grid, so every assertion here is
/// really one of two questions: does a well-formed answer survive intact
/// (ordinals, order, the empty declared type, the NULL default), and does a
/// malformed one become a *typed* failure rather than a plausible-looking row?
final class DatabaseSchemaTests: XCTestCase {

    // MARK: - Helpers

    private func listing(_ rows: [[DatabaseValue]]) -> DatabaseResultSet {
        DatabaseResultSet(columnNames: DatabaseSchema.entryColumns, rows: rows)
    }

    private func pragma(_ rows: [[DatabaseValue]]) -> DatabaseResultSet {
        // The real pragma answers `cid` first and the parser ignores it, so the
        // fixture carries it: reading by name rather than by position is the
        // property under test.
        DatabaseResultSet(
            columnNames: ["cid"] + DatabaseSchema.columnPragmaColumns,
            rows: rows
        )
    }

    /// `cid, name, type, notnull, dflt_value, pk, hidden`.
    private func pragmaRow(
        _ cid: Int64,
        _ name: String,
        _ type: DatabaseValue,
        notNull: Int64 = 0,
        defaultValue: DatabaseValue = .null,
        primaryKey: Int64 = 0,
        hidden: Int64 = 0
    ) -> [DatabaseValue] {
        [.integer(cid), .text(name), type, .integer(notNull), defaultValue, .integer(primaryKey), .integer(hidden)]
    }

    // MARK: - The listing

    func testListingReadsTablesAndViewsInTheOrderGiven() throws {
        let resultSet = listing([
            [.text("albums"), .text("table"), .text("CREATE TABLE albums (id INTEGER)")],
            [.text("recent"), .text("view"), .text("CREATE VIEW recent AS SELECT 1")],
            [.text("tracks"), .text("table"), .text("CREATE TABLE tracks (id INTEGER)")],
        ])

        let entries = try DatabaseSchema.entries(from: resultSet)

        XCTAssertEqual(entries.map(\.name), ["albums", "recent", "tracks"])
        XCTAssertEqual(entries.map(\.kind), [.table, .view, .table])
        XCTAssertEqual(entries[1].definition, "CREATE VIEW recent AS SELECT 1")
        XCTAssertEqual(entries[0].id, "albums")
    }

    /// The declaration is carried through **verbatim**, newlines and all: part 2
    /// reads it, and a re-rendering would be this layer inventing the schema.
    func testDefinitionIsCarriedVerbatim() throws {
        let declaration = "CREATE TABLE \"odd name\" (\n  \"a\"\tINTEGER PRIMARY KEY,\n  b TEXT DEFAULT 'x'\n)"
        let entries = try DatabaseSchema.entries(from: listing([
            [.text("odd name"), .text("table"), .text(declaration)],
        ]))

        XCTAssertEqual(entries.first?.definition, declaration)
    }

    func testListingAcceptsAMissingDeclaration() throws {
        let entries = try DatabaseSchema.entries(from: listing([
            [.text("shadow"), .text("table"), .null],
        ]))

        XCTAssertEqual(entries.first?.definition, nil)
        XCTAssertEqual(entries.first?.kind, .table)
    }

    func testEmptyListingIsAnEmptyDatabaseNotAFailure() throws {
        XCTAssertEqual(try DatabaseSchema.entries(from: listing([])), [])
        XCTAssertEqual(try DatabaseSchema.entries(from: DatabaseResultSet()), [])
    }

    func testListingRejectsAnEntryKindItDoesNotKnow() {
        let resultSet = listing([
            [.text("albums"), .text("table"), .null],
            [.text("albums_idx"), .text("index"), .null],
        ])

        XCTAssertThrowsError(try DatabaseSchema.entries(from: resultSet)) { error in
            XCTAssertEqual(error as? DatabaseSchemaError, .unknownEntryKind("index", row: 1))
        }
    }

    func testListingRejectsAResultSetMissingAColumn() {
        let resultSet = DatabaseResultSet(
            columnNames: ["name", "type"],
            rows: [[.text("albums"), .text("table")]]
        )

        XCTAssertThrowsError(try DatabaseSchema.entries(from: resultSet)) { error in
            XCTAssertEqual(error as? DatabaseSchemaError, .missingColumn(name: "sql", found: ["name", "type"]))
        }
    }

    func testListingRejectsANameThatIsNotText() {
        let resultSet = listing([
            [.text("albums"), .text("table"), .null],
            [.integer(7), .text("table"), .null],
        ])

        XCTAssertThrowsError(try DatabaseSchema.entries(from: resultSet)) { error in
            XCTAssertEqual(error as? DatabaseSchemaError, .unexpectedValue(column: "name", row: 1))
        }
    }

    /// A result set with the right columns but a short row is malformed, not a
    /// trap: `DatabaseResultSet.value(row:column:)` answers `nil` out of range and
    /// the parser turns that into the same typed refusal.
    func testListingRejectsAShortRowWithoutTrapping() {
        let resultSet = listing([[.text("albums")]])

        XCTAssertThrowsError(try DatabaseSchema.entries(from: resultSet)) { error in
            XCTAssertEqual(error as? DatabaseSchemaError, .unexpectedValue(column: "type", row: 0))
        }
    }

    // MARK: - The columns

    func testColumnsPreserveACompositePrimaryKeysOrdinals() throws {
        let columns = try DatabaseSchema.columns(from: pragma([
            pragmaRow(0, "artist", .text("TEXT"), notNull: 1, primaryKey: 1),
            pragmaRow(1, "title", .text("TEXT"), notNull: 1, primaryKey: 2),
            pragmaRow(2, "year", .text("INTEGER")),
        ]))

        XCTAssertEqual(columns.map(\.name), ["artist", "title", "year"])
        XCTAssertEqual(columns.map(\.primaryKeyPosition), [1, 2, nil])
        XCTAssertEqual(columns.map(\.isPrimaryKey), [true, true, false])
        XCTAssertEqual(columns.map(\.isNotNull), [true, true, false])
        XCTAssertEqual(columns[2].id, "year")
    }

    func testColumnsReadTheDeclaredTypeAndTheDefaultExpression() throws {
        let columns = try DatabaseSchema.columns(from: pragma([
            pragmaRow(0, "id", .text("INTEGER"), primaryKey: 1),
            pragmaRow(1, "created", .text("TEXT"), defaultValue: .text("CURRENT_TIMESTAMP")),
            pragmaRow(2, "count", .text("INTEGER"), defaultValue: .text("0")),
        ]))

        XCTAssertEqual(columns.map(\.declaredType), ["INTEGER", "TEXT", "INTEGER"])
        XCTAssertEqual(columns.map(\.defaultExpression), [nil, "CURRENT_TIMESTAMP", "0"])
    }

    /// A column may be declared with no type at all. SQLite spells that as the
    /// empty string; a NULL is read as the same fact rather than as a failure.
    func testColumnsAcceptAnUndeclaredType() throws {
        let columns = try DatabaseSchema.columns(from: pragma([
            pragmaRow(0, "loose", .text("")),
            pragmaRow(1, "looser", .null),
        ]))

        XCTAssertEqual(columns.map(\.declaredType), ["", ""])
    }

    func testColumnsReadAnyNonZeroHiddenAsHidden() throws {
        let columns = try DatabaseSchema.columns(from: pragma([
            pragmaRow(0, "plain", .text("TEXT")),
            pragmaRow(1, "virtualTableHidden", .text("TEXT"), hidden: 1),
            pragmaRow(2, "storedGenerated", .text("TEXT"), hidden: 2),
            pragmaRow(3, "virtualGenerated", .text("TEXT"), hidden: 3),
        ]))

        XCTAssertEqual(columns.map(\.isHidden), [false, true, true, true])
    }

    func testEmptyPragmaIsATableWithNothingToDescribe() throws {
        XCTAssertEqual(try DatabaseSchema.columns(from: pragma([])), [])
        XCTAssertEqual(try DatabaseSchema.columns(from: DatabaseResultSet()), [])
    }

    func testColumnsRejectAResultSetMissingAColumn() {
        let resultSet = DatabaseResultSet(
            columnNames: ["cid", "name", "type", "notnull", "dflt_value", "pk"],
            rows: [[.integer(0), .text("id"), .text("INTEGER"), .integer(0), .null, .integer(1)]]
        )

        XCTAssertThrowsError(try DatabaseSchema.columns(from: resultSet)) { error in
            guard case .missingColumn(let name, _)? = error as? DatabaseSchemaError else {
                return XCTFail("expected a missingColumn failure, got \(error)")
            }
            XCTAssertEqual(name, "hidden")
        }
    }

    func testColumnsRejectAFlagThatIsNotAnInteger() {
        let resultSet = pragma([
            pragmaRow(0, "id", .text("INTEGER")),
            [.integer(1), .text("name"), .text("TEXT"), .text("yes"), .null, .integer(0), .integer(0)],
        ])

        XCTAssertThrowsError(try DatabaseSchema.columns(from: resultSet)) { error in
            XCTAssertEqual(error as? DatabaseSchemaError, .unexpectedValue(column: "notnull", row: 1))
        }
    }

    /// The pragma answers `cid` first; reading by name rather than by position is
    /// what lets the parser survive a column order it did not choose.
    func testColumnsAreReadByNameNotByPosition() throws {
        let resultSet = DatabaseResultSet(
            columnNames: ["hidden", "pk", "dflt_value", "notnull", "type", "name", "cid"],
            rows: [[.integer(0), .integer(2), .text("'x'"), .integer(1), .text("TEXT"), .text("title"), .integer(9)]]
        )

        let columns = try DatabaseSchema.columns(from: resultSet)

        XCTAssertEqual(columns, [
            DatabaseColumn(
                name: "title",
                declaredType: "TEXT",
                primaryKeyPosition: 2,
                isNotNull: true,
                defaultExpression: "'x'",
                isHidden: false
            ),
        ])
    }

    // MARK: - What a refusal says

    func testEveryRefusalDescribesItself() {
        let errors: [DatabaseSchemaError] = [
            .missingColumn(name: "sql", found: ["name", "type"]),
            .missingColumn(name: "sql", found: []),
            .unexpectedValue(column: "name", row: 0),
            .unknownEntryKind("index", row: 3),
        ]

        for error in errors {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty, "\(error) described itself with nothing")
            XCTAssertEqual(error.localizedDescription, description)
        }
        // Rows are counted from one where a human reads them.
        XCTAssertTrue(DatabaseSchemaError.unknownEntryKind("index", row: 3).localizedDescription.contains("row 4"))
    }
}
