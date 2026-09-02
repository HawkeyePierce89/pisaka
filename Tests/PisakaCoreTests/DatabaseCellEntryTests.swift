import XCTest
@testable import PisakaCore

/// The typing rule: what a string typed into a grid cell means as a bound value.
///
/// Two halves, tested apart because they fail apart: SQLite's affinity
/// determination (a documented rule this file re-implements, so the
/// documentation's own example table is the oracle) and the conversion from an
/// entry to a `DatabaseValue` (this project's decision, so the reasoning is
/// pinned case by case).
final class DatabaseCellEntryTests: XCTestCase {

    // MARK: - Affinity: SQLite's five ordered rules

    /// Rule 1. The documented INTEGER examples, verbatim from SQLite's table.
    func testIntegerAffinityExamples() {
        for declaration in [
            "INT", "INTEGER", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT",
            "UNSIGNED BIG INT", "INT2", "INT8",
        ] {
            XCTAssertEqual(DatabaseTypeAffinity(declaredType: declaration), .integer, declaration)
        }
    }

    /// Rule 2. The documented TEXT examples, verbatim.
    func testTextAffinityExamples() {
        for declaration in [
            "CHARACTER(20)", "VARCHAR(255)", "VARYING CHARACTER(255)", "NCHAR(55)",
            "NATIVE CHARACTER(70)", "NVARCHAR(100)", "TEXT", "CLOB",
        ] {
            XCTAssertEqual(DatabaseTypeAffinity(declaredType: declaration), .text, declaration)
        }
    }

    /// Rule 3, both halves: the keyword, and no declaration at all.
    func testBlobAffinityExamples() {
        XCTAssertEqual(DatabaseTypeAffinity(declaredType: "BLOB"), .blob)
        XCTAssertEqual(DatabaseTypeAffinity(declaredType: ""), .blob)
    }

    /// A declaration of nothing but whitespace is read as no declaration — the
    /// only reading that keeps a malformed schema from falling through five
    /// substring tests to NUMERIC.
    func testWhitespaceOnlyDeclarationIsUntyped() {
        XCTAssertEqual(DatabaseTypeAffinity(declaredType: "  "), .blob)
        XCTAssertEqual(DatabaseTypeAffinity(declaredType: "\n"), .blob)
    }

    /// Rule 4. The documented REAL examples, verbatim.
    func testRealAffinityExamples() {
        for declaration in ["REAL", "DOUBLE", "DOUBLE PRECISION", "FLOAT"] {
            XCTAssertEqual(DatabaseTypeAffinity(declaredType: declaration), .real, declaration)
        }
    }

    /// Rule 5. The documented NUMERIC examples, verbatim — `STRING` among them,
    /// which contains none of the four earlier rules' substrings however much it
    /// looks like a text type.
    func testNumericAffinityExamples() {
        for declaration in ["NUMERIC", "DECIMAL(10,5)", "BOOLEAN", "DATE", "DATETIME", "STRING"] {
            XCTAssertEqual(DatabaseTypeAffinity(declaredType: declaration), .numeric, declaration)
        }
    }

    /// The rules are ordered, and this is the case that proves it: `FLOATING
    /// POINT` matches rule 4's `FLOA` *and* rule 1's `INT` (inside `POINT`), and
    /// rule 1 wins. SQLite documents the same answer.
    func testRuleOrderDecidesFloatingPoint() {
        XCTAssertEqual(DatabaseTypeAffinity(declaredType: "FLOATING POINT"), .integer)
    }

    /// Two more collisions the order settles: a `BLOB` spelled with `INT` in it
    /// is an integer column, and `CHARINT` is not a text one.
    func testRuleOrderDecidesOtherCollisions() {
        XCTAssertEqual(DatabaseTypeAffinity(declaredType: "POINTBLOB"), .integer)
        XCTAssertEqual(DatabaseTypeAffinity(declaredType: "CHARINT"), .integer)
        XCTAssertEqual(DatabaseTypeAffinity(declaredType: "TEXTBLOB"), .text)
    }

    /// Matching is case-insensitive, which is what makes a lower-cased schema
    /// behave identically to a shouted one.
    func testAffinityIsCaseInsensitive() {
        XCTAssertEqual(DatabaseTypeAffinity(declaredType: "integer"), .integer)
        XCTAssertEqual(DatabaseTypeAffinity(declaredType: "VarChar(10)"), .text)
        XCTAssertEqual(DatabaseTypeAffinity(declaredType: "blob"), .blob)
        XCTAssertEqual(DatabaseTypeAffinity(declaredType: "double"), .real)
        XCTAssertEqual(DatabaseTypeAffinity(declaredType: "boolean"), .numeric)
    }

    // MARK: - The NULL gesture

    /// NULL is reachable only as its own case — and it ignores both the column
    /// and the cell, because a column's affinity has nothing to say about the
    /// absence of a value.
    func testExplicitNullIsNullInEveryColumn() {
        for affinity in DatabaseTypeAffinity.allCases {
            XCTAssertEqual(DatabaseCellEntry.null.value(affinity: affinity, previousValue: .integer(42)), .null)
            XCTAssertEqual(DatabaseCellEntry.null.value(affinity: affinity, previousValue: .null), .null)
        }
    }

    /// The word is never the gesture: typing `NULL` stores the four characters,
    /// in every column that can hold text.
    func testTypingTheWordNullStoresText() {
        for entry in ["NULL", "null", "Null", "nil", "None"] {
            XCTAssertEqual(
                DatabaseCellEntry.typed(entry).value(affinity: .text, previousValue: .text("x")),
                .text(entry)
            )
            XCTAssertEqual(
                DatabaseCellEntry.typed(entry).value(affinity: .integer, previousValue: .integer(1)),
                .text(entry)
            )
            XCTAssertEqual(
                DatabaseCellEntry.typed(entry).value(affinity: .blob, previousValue: .integer(1)),
                .text(entry)
            )
        }
    }

    /// An empty entry is the empty string, never NULL — which is the one
    /// distinction the viewer must never blur, and the reason the gesture exists.
    func testEmptyEntryIsTheEmptyString() {
        for affinity in DatabaseTypeAffinity.allCases {
            XCTAssertEqual(DatabaseCellEntry.typed("").value(affinity: affinity, previousValue: .text("x")), .text(""))
        }
        XCTAssertNotEqual(DatabaseCellEntry.typed("").value(affinity: .text, previousValue: .null), .null)
    }

    // MARK: - TEXT affinity

    /// Text stores text, whatever it looks like.
    func testTextAffinityAlwaysStoresText() {
        for entry in ["42", "-1", "4.5", "1e3", "", " ", "x"] {
            XCTAssertEqual(
                DatabaseCellEntry.typed(entry).value(affinity: .text, previousValue: .integer(7)),
                .text(entry)
            )
        }
    }

    // MARK: - Numeric affinities

    func testNumericAffinitiesStoreWholeIntegers() {
        for affinity in [DatabaseTypeAffinity.integer, .real, .numeric] {
            XCTAssertEqual(DatabaseCellEntry.typed("43").value(affinity: affinity, previousValue: .null), .integer(43))
            XCTAssertEqual(DatabaseCellEntry.typed("-43").value(affinity: affinity, previousValue: .null), .integer(-43))
            XCTAssertEqual(DatabaseCellEntry.typed("+43").value(affinity: affinity, previousValue: .null), .integer(43))
            XCTAssertEqual(DatabaseCellEntry.typed("007").value(affinity: affinity, previousValue: .null), .integer(7))
            XCTAssertEqual(DatabaseCellEntry.typed("0").value(affinity: affinity, previousValue: .null), .integer(0))
        }
    }

    func testNumericAffinitiesStoreFiniteReals() {
        XCTAssertEqual(DatabaseCellEntry.typed("4.5").value(affinity: .real, previousValue: .null), .real(4.5))
        XCTAssertEqual(DatabaseCellEntry.typed("-0.25").value(affinity: .numeric, previousValue: .null), .real(-0.25))
        XCTAssertEqual(DatabaseCellEntry.typed("1e3").value(affinity: .integer, previousValue: .null), .real(1000))
        XCTAssertEqual(DatabaseCellEntry.typed("5.").value(affinity: .integer, previousValue: .null), .real(5))
        XCTAssertEqual(DatabaseCellEntry.typed(".5").value(affinity: .integer, previousValue: .null), .real(0.5))
    }

    /// Anything that is not a whole numeral is text — including the shapes a
    /// permissive `Double` parser would otherwise accept.
    func testNumericAffinitiesStoreEverythingElseAsText() {
        for entry in ["4x", "4 5", "1,5", "0x10", "inf", "-inf", "nan", "NaN", "0x1p3", "1e", "+", ".", "--1", "1.2.3"] {
            XCTAssertEqual(
                DatabaseCellEntry.typed(entry).value(affinity: .integer, previousValue: .null),
                .text(entry),
                entry
            )
        }
    }

    /// A literal too large for a `Double` is not an infinity in the database; it
    /// is the text the reader typed.
    func testOverflowingRealStaysText() {
        XCTAssertEqual(
            DatabaseCellEntry.typed("1e400").value(affinity: .real, previousValue: .null),
            .text("1e400")
        )
    }

    /// Nothing is trimmed, so a padded number is not a number.
    func testWhitespaceIsPreservedAndDefeatsNumericParsing() {
        XCTAssertEqual(DatabaseCellEntry.typed(" 42 ").value(affinity: .integer, previousValue: .null), .text(" 42 "))
        XCTAssertEqual(DatabaseCellEntry.typed("42 ").value(affinity: .numeric, previousValue: .null), .text("42 "))
        XCTAssertEqual(DatabaseCellEntry.typed(" ").value(affinity: .text, previousValue: .null), .text(" "))
        XCTAssertEqual(DatabaseCellEntry.typed("\t42").value(affinity: .integer, previousValue: .null), .text("\t42"))
    }

    /// Non-ASCII digits parse as neither an integer nor a real, so they stay
    /// text rather than being classified as a numeral nobody can then read.
    func testNonASCIIDigitsStayText() {
        XCTAssertEqual(DatabaseCellEntry.typed("٤٢").value(affinity: .integer, previousValue: .null), .text("٤٢"))
    }

    /// The `Int64` boundary: the extremes are integers, and one past the top
    /// falls to a real rather than failing.
    func testInt64BoundaryValues() {
        XCTAssertEqual(
            DatabaseCellEntry.typed("9223372036854775807").value(affinity: .integer, previousValue: .null),
            .integer(Int64.max)
        )
        XCTAssertEqual(
            DatabaseCellEntry.typed("-9223372036854775808").value(affinity: .integer, previousValue: .null),
            .integer(Int64.min)
        )
        XCTAssertEqual(
            DatabaseCellEntry.typed("9223372036854775808").value(affinity: .integer, previousValue: .null),
            .real(9223372036854775808)
        )
        XCTAssertEqual(
            DatabaseCellEntry.typed("99999999999999999999").value(affinity: .integer, previousValue: .null),
            .real(99999999999999999999)
        )
    }

    // MARK: - The untyped column

    /// The rule both ways: the same entry over an integer cell and over a text
    /// cell stores two different things, because the column declares nothing and
    /// the cell is the only evidence of what it holds.
    func testUntypedColumnKeepsThePreviousStorageClass() {
        XCTAssertEqual(
            DatabaseCellEntry.typed("43").value(affinity: .blob, previousValue: .integer(42)),
            .integer(43)
        )
        XCTAssertEqual(
            DatabaseCellEntry.typed("43").value(affinity: .blob, previousValue: .text("42")),
            .text("43")
        )
        XCTAssertEqual(
            DatabaseCellEntry.typed("43").value(affinity: .blob, previousValue: .real(4.5)),
            .real(43)
        )
        XCTAssertEqual(
            DatabaseCellEntry.typed("4.5").value(affinity: .blob, previousValue: .real(1)),
            .real(4.5)
        )
    }

    /// An entry that does not parse as the previous class is text — a cell that
    /// used to hold a number and now holds a word is not a failure, it is an
    /// edit.
    func testUntypedColumnFallsToTextWhenTheEntryDoesNotParse() {
        XCTAssertEqual(
            DatabaseCellEntry.typed("4x").value(affinity: .blob, previousValue: .integer(42)),
            .text("4x")
        )
        XCTAssertEqual(
            DatabaseCellEntry.typed("4.5").value(affinity: .blob, previousValue: .integer(42)),
            .text("4.5")
        )
        XCTAssertEqual(
            DatabaseCellEntry.typed("x").value(affinity: .blob, previousValue: .real(4.5)),
            .text("x")
        )
    }

    /// A previous NULL or blob has no storage class worth preserving — one is
    /// the absence of a value and the other is bytes nobody typed — so both
    /// store text.
    func testUntypedColumnWithNothingToPreserveStoresText() {
        XCTAssertEqual(
            DatabaseCellEntry.typed("43").value(affinity: .blob, previousValue: .null),
            .text("43")
        )
        XCTAssertEqual(
            DatabaseCellEntry.typed("43").value(affinity: .blob, previousValue: .blob(byteCount: 8)),
            .text("43")
        )
    }

    /// An integer entry that overflows `Int64` does not parse as an integer, so
    /// it does not silently become a real in a column whose evidence says
    /// integer — it is text, and the digits survive exactly.
    func testUntypedIntegerColumnDoesNotWidenAnOverflowingEntry() {
        XCTAssertEqual(
            DatabaseCellEntry.typed("99999999999999999999").value(affinity: .blob, previousValue: .integer(42)),
            .text("99999999999999999999")
        )
    }

    // MARK: - The round trip the editor depends on

    /// The property the cell editor rests on: a cell is seeded from
    /// `DatabaseValue.displayText` and committed back through the typing rule,
    /// so **committing an untouched draft must not change the value**. Asserted
    /// across the storage classes and the numeric affinities together, because
    /// the failure it guards is silent — the `WHERE` binds the value and matches,
    /// so a broken round trip retypes the cell and reports success.
    ///
    /// The non-finite reals are deliberately *absent* from the list: their
    /// rendering (`inf`, `-inf`, `nan`) is not a numeral and cannot round-trip,
    /// which is why `DatabaseUpdatePlanner` refuses such a cell outright rather
    /// than letting an editor open over it (`DatabaseEditRefusal
    /// .nonFiniteRealCell`, pinned in `DatabaseUpdatePlanTests`).
    func testRenderedValuesRoundTripThroughTheTypingRule() {
        let reals: [Double] = [1.5, 0, -0.0, 42, 1e300, 5e-324, .greatestFiniteMagnitude, .pi]
        let integers: [Int64] = [0, -1, 42, .min, .max]
        var values: [DatabaseValue] = reals.map { .real($0) } + integers.map { .integer($0) }
        values += [.text(""), .text(" 42 "), .text("hello"), .text("NULL")]

        for affinity in [DatabaseTypeAffinity.integer, .real, .numeric] {
            for value in values where !value.isNull {
                // A text cell in a numeric column is the one shape that legitimately
                // does not round-trip as itself: the column's affinity is what says
                // `42` there means the number, and SQLite would have retyped the
                // stored text the same way. Every other value must come back whole.
                if case .text = value { continue }
                XCTAssertEqual(
                    DatabaseCellEntry.typed(value.displayText).value(affinity: affinity, previousValue: value),
                    value,
                    "\(affinity) / \(value)"
                )
            }
            // …and in a TEXT column every rendering comes back as its own text,
            // which is the same statement about the rendering being faithful.
            for value in values {
                XCTAssertEqual(
                    DatabaseCellEntry.typed(value.displayText).value(affinity: .text, previousValue: value),
                    .text(value.displayText),
                    "\(value)"
                )
            }
        }
    }
}
