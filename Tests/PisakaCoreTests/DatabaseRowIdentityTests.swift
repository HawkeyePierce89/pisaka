import XCTest
@testable import PisakaCore

/// How a table's rows are addressed — the decision every cell edit rests on.
///
/// The two rules that make this more than a lookup are asserted hardest: the
/// three rowid spellings can each be **shadowed** by a declared column of that
/// name, and a key column is located in the answered row **by name**, because the
/// schema's ordinals and `SELECT *`'s ordinals part company the moment a table
/// has a hidden column.
final class DatabaseRowIdentityTests: XCTestCase {

    // MARK: - Helpers

    private func column(
        _ name: String,
        type: String = "",
        key: Int? = nil,
        hidden: Bool = false
    ) -> DatabaseColumn {
        DatabaseColumn(name: name, declaredType: type, primaryKeyPosition: key, isHidden: hidden)
    }

    // MARK: - The probe's spelling

    func testTheProbeUsesTheFirstSpellingWhenNothingShadowsIt() {
        let columns = [column("id", key: 1), column("title")]

        XCTAssertEqual(DatabaseRowIdentity.probeAlias(columns: columns), .rowid)
    }

    /// A table may declare a column called `rowid`; SQLite then resolves the bare
    /// name to *that* column while `_rowid_` and `oid` still answer the true
    /// rowid. So the probe moves on rather than asking about the wrong column.
    func testAShadowedSpellingIsSkipped() {
        XCTAssertEqual(
            DatabaseRowIdentity.probeAlias(columns: [column("rowid"), column("v")]),
            .underscored
        )
        XCTAssertEqual(
            DatabaseRowIdentity.probeAlias(columns: [column("rowid"), column("_rowid_")]),
            .oid
        )
    }

    /// Identifier comparison in SQLite is case-insensitive, so `ROWID` shadows
    /// `rowid` exactly as `rowid` does.
    func testShadowingIsCaseInsensitive() {
        XCTAssertEqual(
            DatabaseRowIdentity.probeAlias(columns: [column("ROWID"), column("_RowId_")]),
            .oid
        )
    }

    func testAllThreeShadowedLeavesNothingToProbeWith() {
        let columns = [column("rowid"), column("_rowid_"), column("oid")]

        XCTAssertNil(DatabaseRowIdentity.probeAlias(columns: columns))
    }

    // MARK: - The strategy

    func testAPlainTableIsAddressedByRowId() {
        let identity = DatabaseRowIdentity.resolve(
            kind: .table,
            columns: [column("id", type: "INTEGER", key: 1), column("title", type: "TEXT")],
            answeredColumns: ["id", "title"],
            hasRowId: true
        )

        XCTAssertEqual(identity, .rowid(alias: .rowid))
    }

    /// The spelling the strategy carries is the one the probe was made with, so
    /// the page and the `WHERE` name the same column.
    func testTheStrategyCarriesTheUnshadowedSpelling() {
        let identity = DatabaseRowIdentity.resolve(
            kind: .table,
            columns: [column("rowid", type: "TEXT"), column("v")],
            answeredColumns: ["rowid", "v"],
            hasRowId: true
        )

        XCTAssertEqual(identity, .rowid(alias: .underscored))
    }

    /// A view's rows are computed. There is nothing to name, and no page of one
    /// carries an identity column.
    func testAViewIsNotAddressable() {
        let identity = DatabaseRowIdentity.resolve(
            kind: .view,
            columns: [column("id", key: 1)],
            answeredColumns: ["id"],
            hasRowId: true
        )

        XCTAssertEqual(identity, .unavailable(.view))
    }

    func testAWithoutRowIdTableIsAddressedByItsSingleKeyColumn() {
        let identity = DatabaseRowIdentity.resolve(
            kind: .table,
            columns: [column("code", type: "TEXT", key: 1), column("label", type: "TEXT")],
            answeredColumns: ["code", "label"],
            hasRowId: false
        )

        XCTAssertEqual(identity, .primaryKey(columns: [DatabaseKeyColumn(name: "code", resultIndex: 0)]))
    }

    /// Every key column, in **key order** — which is not the declaration order
    /// here, and is what the composite `WHERE` will be built in.
    func testACompositeKeyIsCarriedInKeyOrder() {
        let identity = DatabaseRowIdentity.resolve(
            kind: .table,
            columns: [
                column("part", type: "TEXT", key: 2),
                column("qty", type: "INTEGER"),
                column("order_id", type: "INTEGER", key: 1),
            ],
            answeredColumns: ["part", "qty", "order_id"],
            hasRowId: false
        )

        XCTAssertEqual(
            identity,
            .primaryKey(columns: [
                DatabaseKeyColumn(name: "order_id", resultIndex: 2),
                DatabaseKeyColumn(name: "part", resultIndex: 0),
            ])
        )
    }

    /// A table shadowing all three spellings has nothing to probe with, so the
    /// key is what is left — and it is enough.
    func testAllThreeShadowedFallsBackToThePrimaryKey() {
        let identity = DatabaseRowIdentity.resolve(
            kind: .table,
            columns: [column("rowid", key: 1), column("_rowid_"), column("oid")],
            answeredColumns: ["rowid", "_rowid_", "oid"],
            hasRowId: false
        )

        XCTAssertEqual(identity, .primaryKey(columns: [DatabaseKeyColumn(name: "rowid", resultIndex: 0)]))
    }

    /// Even if the probe answered — which it would, about the declared column —
    /// a table with no spelling left is addressed by its key and not by that
    /// column.
    func testAllThreeShadowedIgnoresAProbeThatAnswered() {
        let identity = DatabaseRowIdentity.resolve(
            kind: .table,
            columns: [column("rowid", key: 1), column("_rowid_"), column("oid")],
            answeredColumns: ["rowid", "_rowid_", "oid"],
            hasRowId: true
        )

        XCTAssertEqual(identity, .primaryKey(columns: [DatabaseKeyColumn(name: "rowid", resultIndex: 0)]))
    }

    func testATableWithNeitherRowIdNorKeyIsNotAddressable() {
        let identity = DatabaseRowIdentity.resolve(
            kind: .table,
            columns: [column("a"), column("b")],
            answeredColumns: ["a", "b"],
            hasRowId: false
        )

        XCTAssertEqual(identity, .unavailable(.noRowIdentity))
    }

    /// A key column the answer does not carry has no value on screen to put in a
    /// `WHERE`, so the table is refused rather than half-addressed.
    func testAKeyColumnAbsentFromTheAnswerRefuses() {
        let identity = DatabaseRowIdentity.resolve(
            kind: .table,
            columns: [column("code", key: 1), column("label")],
            answeredColumns: ["label"],
            hasRowId: false
        )

        XCTAssertEqual(identity, .unavailable(.keyColumnNotAnswered(name: "code")))
    }

    /// A generated key column is hidden from `SELECT *` and reaches the same
    /// refusal — the correct answer, arrived at without a second rule.
    func testAHiddenKeyColumnRefusesAsAbsent() {
        let identity = DatabaseRowIdentity.resolve(
            kind: .table,
            columns: [column("code", key: 1, hidden: true), column("label")],
            answeredColumns: ["label"],
            hasRowId: false
        )

        XCTAssertEqual(identity, .unavailable(.keyColumnNotAnswered(name: "code")))
    }

    /// Two answered columns spelling the key's name make "which one holds the
    /// key" a guess, and this layer guesses at nothing.
    func testAKeyColumnMatchingTwoAnsweredColumnsRefuses() {
        let identity = DatabaseRowIdentity.resolve(
            kind: .table,
            columns: [column("code", key: 1), column("label")],
            answeredColumns: ["code", "CODE", "label"],
            hasRowId: false
        )

        XCTAssertEqual(identity, .unavailable(.keyColumnAmbiguous(name: "code")))
    }

    /// The lookup is by name and case-insensitive, so a key declared `Code` is
    /// found under an answer spelling it `code`.
    func testAKeyColumnIsMatchedCaseInsensitively() {
        let identity = DatabaseRowIdentity.resolve(
            kind: .table,
            columns: [column("Code", key: 1)],
            answeredColumns: ["code"],
            hasRowId: false
        )

        XCTAssertEqual(identity, .primaryKey(columns: [DatabaseKeyColumn(name: "Code", resultIndex: 0)]))
    }

    /// The rule this whole by-name lookup exists for: a hidden column sits in the
    /// schema ahead of the visible ones, so schema position 1 is answer position
    /// 0. A positional map would put the wrong column in the `WHERE`.
    func testAHiddenColumnAheadOfTheKeyDoesNotShiftItsPosition() {
        let identity = DatabaseRowIdentity.resolve(
            kind: .table,
            columns: [
                column("computed", hidden: true),
                column("code", key: 1),
                column("label"),
            ],
            answeredColumns: ["code", "label"],
            hasRowId: false
        )

        XCTAssertEqual(identity, .primaryKey(columns: [DatabaseKeyColumn(name: "code", resultIndex: 0)]))
    }

    // MARK: - The shared lookup

    func testTheAnsweredLookupReportsItsThreeOutcomes() {
        XCTAssertEqual(DatabaseRowIdentity.answeredIndex(of: "b", in: ["a", "b", "c"]), .found(1))
        XCTAssertEqual(DatabaseRowIdentity.answeredIndex(of: "z", in: ["a", "b"]), .missing)
        XCTAssertEqual(DatabaseRowIdentity.answeredIndex(of: "a", in: ["a", "A"]), .ambiguous)
        XCTAssertEqual(DatabaseRowIdentity.answeredIndex(of: "a", in: []), .missing)
    }
}
