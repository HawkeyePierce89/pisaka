import XCTest
@testable import PisakaCore

/// The value layer of the database viewer: the five storage classes, how each
/// renders in the grid, and the two carrier types the seam speaks in.
///
/// The rendering assertions are the load-bearing ones. `displayText` is the only
/// answer both the grid and (in part 2) the console will use, so the one
/// distinction it must never blur — a missing value against an empty one — is
/// pinned here rather than left to a view.
final class DatabaseValueTests: XCTestCase {

    // MARK: - Rendering

    func testIntegerRendersAsItsDigits() {
        XCTAssertEqual(DatabaseValue.integer(0).displayText, "0")
        XCTAssertEqual(DatabaseValue.integer(-42).displayText, "-42")
        XCTAssertEqual(DatabaseValue.integer(Int64.max).displayText, "9223372036854775807")
        XCTAssertEqual(DatabaseValue.integer(Int64.min).displayText, "-9223372036854775808")
    }

    func testRealRendersWithItsFractionalPart() {
        XCTAssertEqual(DatabaseValue.real(1.5).displayText, "1.5")
        XCTAssertEqual(DatabaseValue.real(-0.25).displayText, "-0.25")
    }

    /// A whole-numbered REAL must not read as an INTEGER: the storage class is
    /// part of what the viewer is for, and `1.0` collapsing to `1` would hide it.
    func testWholeNumberedRealKeepsItsPoint() {
        XCTAssertEqual(DatabaseValue.real(1).displayText, "1.0")
    }

    func testTextRendersVerbatim() {
        XCTAssertEqual(DatabaseValue.text("hello").displayText, "hello")
        XCTAssertEqual(DatabaseValue.text("  padded  ").displayText, "  padded  ")
        XCTAssertEqual(DatabaseValue.text("line\nbreak").displayText, "line\nbreak")
    }

    func testNullRendersAsANonEmptyMarker() {
        XCTAssertEqual(DatabaseValue.null.displayText, DatabaseValue.nullDisplayText)
        XCTAssertFalse(DatabaseValue.nullDisplayText.isEmpty)
    }

    /// The one distinction the grid must never blur: a column holding `''` and a
    /// column holding NULL are different facts about the row.
    func testNullIsDistinguishableFromTheEmptyString() {
        XCTAssertNotEqual(DatabaseValue.null.displayText, DatabaseValue.text("").displayText)
        XCTAssertEqual(DatabaseValue.text("").displayText, "")
        XCTAssertTrue(DatabaseValue.null.isNull)
        XCTAssertFalse(DatabaseValue.text("").isNull)
    }

    /// A text value *may* spell the marker — no `String` can be unforgeable — so
    /// `isNull` is the question, and it still separates the two.
    func testTextSpellingTheMarkerIsStillNotNull() {
        let impostor = DatabaseValue.text(DatabaseValue.nullDisplayText)
        XCTAssertEqual(impostor.displayText, DatabaseValue.null.displayText)
        XCTAssertFalse(impostor.isNull)
        XCTAssertNotEqual(impostor, .null)
    }

    func testBlobRendersAsAByteCountPlaceholder() {
        XCTAssertEqual(DatabaseValue.blob(Data()).displayText, "BLOB (0 bytes)")
        XCTAssertEqual(DatabaseValue.blob(Data([0x00])).displayText, "BLOB (1 byte)")
        XCTAssertEqual(DatabaseValue.blob(Data([0x01, 0x02, 0x03])).displayText, "BLOB (3 bytes)")
    }

    /// The bytes themselves never reach the grid — including bytes that would
    /// have decoded as perfectly readable text.
    func testBlobNeverRendersItsBytes() {
        let readable = DatabaseValue.blob(Data("secret".utf8))
        XCTAssertEqual(readable.displayText, "BLOB (6 bytes)")
        XCTAssertFalse(readable.displayText.contains("secret"))
    }

    func testEveryNonNullValueReportsItselfNotNull() {
        let values: [DatabaseValue] = [.integer(1), .real(1), .text("x"), .blob(Data([0x01]))]
        for value in values {
            XCTAssertFalse(value.isNull, "\(value) should not be null")
        }
    }

    // MARK: - Equality

    /// Storage class is part of identity: the same number as INTEGER and as REAL
    /// are different values, which is what keeps a type-affinity surprise
    /// visible in the viewer instead of silently equal.
    func testEqualityDistinguishesStorageClasses() {
        XCTAssertNotEqual(DatabaseValue.integer(1), .real(1))
        XCTAssertNotEqual(DatabaseValue.integer(1), .text("1"))
        XCTAssertNotEqual(DatabaseValue.text("1"), .real(1))
        XCTAssertNotEqual(DatabaseValue.blob(Data("1".utf8)), .text("1"))
    }

    func testEqualityWithinAStorageClass() {
        XCTAssertEqual(DatabaseValue.integer(7), .integer(7))
        XCTAssertNotEqual(DatabaseValue.integer(7), .integer(8))
        XCTAssertEqual(DatabaseValue.real(0.5), .real(0.5))
        XCTAssertEqual(DatabaseValue.text("a"), .text("a"))
        XCTAssertNotEqual(DatabaseValue.text("a"), .text("A"))
        XCTAssertEqual(DatabaseValue.blob(Data([0x01])), .blob(Data([0x01])))
        XCTAssertNotEqual(DatabaseValue.blob(Data([0x01])), .blob(Data([0x02])))
        XCTAssertEqual(DatabaseValue.null, .null)
    }

    func testValuesAreHashableAsASet() {
        let values: Set<DatabaseValue> = [.integer(1), .integer(1), .real(1), .text("1"), .null, .null]
        XCTAssertEqual(values.count, 4)
    }

    // MARK: - Statements

    func testStatementDefaultsToNoParameters() {
        let statement = DatabaseStatement("SELECT 1")
        XCTAssertEqual(statement.sql, "SELECT 1")
        XCTAssertEqual(statement.parameters, [])
    }

    func testStatementCarriesItsParametersInOrder() {
        let statement = DatabaseStatement(
            "SELECT * FROM \"t\" LIMIT ? OFFSET ?",
            parameters: [.integer(100), .integer(200)]
        )
        XCTAssertEqual(statement.parameters, [.integer(100), .integer(200)])
        XCTAssertNotEqual(
            statement,
            DatabaseStatement("SELECT * FROM \"t\" LIMIT ? OFFSET ?", parameters: [.integer(200), .integer(100)])
        )
    }

    // MARK: - Result sets

    func testEmptyResultSetIsAnAnswerNotAFailure() {
        let empty = DatabaseResultSet(columnNames: ["id", "name"], rows: [])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.columnNames, ["id", "name"])
        XCTAssertEqual(empty.affectedRows, 0)
    }

    func testResultSetIndexedAccessIsBoundsChecked() {
        let result = DatabaseResultSet(
            columnNames: ["id", "name"],
            rows: [[.integer(1), .text("one")], [.integer(2), .null]]
        )
        XCTAssertEqual(result.value(row: 0, column: 1), .text("one"))
        XCTAssertEqual(result.value(row: 1, column: 1), .null)
        XCTAssertNil(result.value(row: 2, column: 0))
        XCTAssertNil(result.value(row: 0, column: 2))
        XCTAssertNil(result.value(row: -1, column: 0))
        XCTAssertNil(result.value(row: 0, column: -1))
    }

    /// A ragged result set is malformed, not a trap: the accessor reports the
    /// missing cell so the layer that can say so does the reporting.
    func testRaggedResultSetReportsTheMissingCell() {
        let ragged = DatabaseResultSet(columnNames: ["a", "b"], rows: [[.integer(1)]])
        XCTAssertEqual(ragged.value(row: 0, column: 0), .integer(1))
        XCTAssertNil(ragged.value(row: 0, column: 1))
    }

    func testAffectedRowsIsCarriedForPartTwo() {
        let write = DatabaseResultSet(affectedRows: 1)
        XCTAssertTrue(write.isEmpty)
        XCTAssertEqual(write.affectedRows, 1)
        XCTAssertNotEqual(write, DatabaseResultSet(affectedRows: 2))
    }

    // MARK: - Errors

    /// Four of the five cases exist to carry SQLite's own sentence; the test that
    /// matters is that none of them rewrites it.
    func testEveryLibraryFailureSurfacesItsMessageVerbatim() {
        let cases: [DatabaseError] = [
            .cannotOpen(message: "unable to open database file"),
            .notADatabase(message: "file is not a database"),
            .busy(message: "database is locked"),
            .sqlError(message: "no such column: nope"),
        ]
        let expected = [
            "unable to open database file",
            "file is not a database",
            "database is locked",
            "no such column: nope",
        ]
        XCTAssertEqual(cases.map(\.message), expected)
        XCTAssertEqual(cases.map { $0.errorDescription }, expected)
        XCTAssertEqual(cases.map { ($0 as Error).localizedDescription }, expected)
    }

    /// `closed` is ours, so it says so in our words rather than quoting a library
    /// that was never asked.
    func testClosedCarriesOurOwnSentence() {
        XCTAssertFalse(DatabaseError.closed.message.isEmpty)
        XCTAssertEqual(DatabaseError.closed.errorDescription, DatabaseError.closed.message)
        XCTAssertEqual((DatabaseError.closed as Error).localizedDescription, DatabaseError.closed.message)
    }

    func testErrorsWithTheSameMessageAreStillDistinguishedByCase() {
        XCTAssertNotEqual(DatabaseError.cannotOpen(message: "x"), .notADatabase(message: "x"))
        XCTAssertNotEqual(DatabaseError.busy(message: "x"), .sqlError(message: "x"))
        XCTAssertEqual(DatabaseError.busy(message: "x"), .busy(message: "x"))
    }
}
