import XCTest
@testable import PisakaCore

/// The one decision that turns an edited grid cell into a write — and, more
/// often, into a refusal.
///
/// Two properties are asserted hardest, because both are silent when wrong. The
/// grid column is matched to its schema column **by name**: a schema with a
/// hidden column ahead of a visible one makes the positional map name a
/// different column, and a plan built that way writes the wrong cell of the
/// right row. And nothing a reader typed ever reaches `sql`: the value spelling
/// a statement terminator travels bound, in a fixed position, like every other
/// value.
final class DatabaseUpdatePlanTests: XCTestCase {

    // MARK: - Helpers

    private func column(
        _ name: String,
        type: String = "",
        key: Int? = nil,
        hidden: Bool = false
    ) -> DatabaseColumn {
        DatabaseColumn(name: name, declaredType: type, primaryKeyPosition: key, isHidden: hidden)
    }

    /// An ordinary rowid table: `id INTEGER, title TEXT`, addressed by `rowid`.
    private func rowIdTarget(
        table: String = "albums",
        alias: DatabaseRowIdAlias = .rowid
    ) -> DatabaseEditTarget {
        DatabaseEditTarget(
            table: table,
            columns: [column("id", type: "INTEGER", key: 1), column("title", type: "TEXT")],
            gridColumns: ["id", "title"],
            identity: .rowid(alias: alias)
        )
    }

    /// A `WITHOUT ROWID` table with a composite key: `(house, room)` in key
    /// order, plus an ordinary column.
    private func compositeKeyTarget() -> DatabaseEditTarget {
        DatabaseEditTarget(
            table: "rooms",
            columns: [
                column("house", type: "TEXT", key: 1),
                column("room", type: "INTEGER", key: 2),
                column("note", type: "TEXT"),
            ],
            gridColumns: ["house", "room", "note"],
            identity: .primaryKey(columns: [
                DatabaseKeyColumn(name: "house", resultIndex: 0),
                DatabaseKeyColumn(name: "room", resultIndex: 1),
            ])
        )
    }

    private func planned(
        _ target: DatabaseEditTarget,
        row: [DatabaseValue],
        rowIdentity: DatabaseValue? = nil,
        columnIndex: Int,
        entry: DatabaseCellEntry
    ) -> Result<DatabaseUpdatePlan, DatabaseEditRefusal> {
        DatabaseUpdatePlanner.plan(
            target: target,
            row: row,
            rowIdentity: rowIdentity,
            columnIndex: columnIndex,
            entry: entry
        )
    }

    private func plan(
        _ target: DatabaseEditTarget,
        row: [DatabaseValue],
        rowIdentity: DatabaseValue? = nil,
        columnIndex: Int,
        entry: DatabaseCellEntry,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> DatabaseUpdatePlan {
        switch planned(target, row: row, rowIdentity: rowIdentity, columnIndex: columnIndex, entry: entry) {
        case .success(let plan):
            return plan
        case .failure(let refusal):
            XCTFail("expected a plan, got \(refusal)", file: file, line: line)
            throw refusal
        }
    }

    private func refusal(
        _ target: DatabaseEditTarget,
        row: [DatabaseValue],
        rowIdentity: DatabaseValue? = nil,
        columnIndex: Int,
        entry: DatabaseCellEntry = .typed("x"),
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> DatabaseEditRefusal? {
        switch planned(target, row: row, rowIdentity: rowIdentity, columnIndex: columnIndex, entry: entry) {
        case .success(let plan):
            XCTFail("expected a refusal, got \(plan.statement.sql)", file: file, line: line)
            return nil
        case .failure(let refusal):
            return refusal
        }
    }

    // MARK: - The rowid plan

    func testARowIdTablesPlanAddressesTheRowAndTheOldValue() throws {
        let plan = try plan(
            rowIdTarget(),
            row: [.integer(1), .text("Kind of Blue")],
            rowIdentity: .integer(7),
            columnIndex: 1,
            entry: .typed("Blue Train")
        )

        XCTAssertEqual(
            plan.statement,
            DatabaseStatement(
                "UPDATE \"albums\" SET \"title\" = ? WHERE rowid IS ? AND \"title\" IS ?",
                parameters: [.text("Blue Train"), .integer(7), .text("Kind of Blue")]
            )
        )
        XCTAssertEqual(plan.requiredAffectedRows, 1)
        XCTAssertEqual(plan.newValue, .text("Blue Train"))
    }

    /// The alias is whichever spelling the table does not shadow, and it is
    /// spliced **bare** here for the same reason it is bare in the probe: quoted,
    /// it would compare the row against the four-character string `rowid`, match
    /// nothing, and report that every row changed underneath the reader.
    func testTheRowIdAliasIsSplicedBareInWhicheverSpelling() throws {
        for alias in DatabaseRowIdAlias.allCases {
            let plan = try plan(
                rowIdTarget(alias: alias),
                row: [.integer(1), .text("t")],
                rowIdentity: .integer(7),
                columnIndex: 1,
                entry: .typed("u")
            )

            XCTAssertTrue(plan.statement.sql.contains("WHERE \(alias.rawValue) IS ?"), plan.statement.sql)
            XCTAssertFalse(plan.statement.sql.contains(DatabaseQuery.quoted(alias.rawValue)), plan.statement.sql)
        }
    }

    /// Editing a key column of a rowid table is ordinary: the row is still named
    /// by its rowid, and the old value still guards the write.
    func testAKeyColumnOfARowIdTableIsWritableLikeAnyOther() throws {
        let plan = try plan(
            rowIdTarget(),
            row: [.integer(1), .text("t")],
            rowIdentity: .integer(7),
            columnIndex: 0,
            entry: .typed("2")
        )

        XCTAssertEqual(
            plan.statement,
            DatabaseStatement(
                "UPDATE \"albums\" SET \"id\" = ? WHERE rowid IS ? AND \"id\" IS ?",
                parameters: [.integer(2), .integer(7), .integer(1)]
            )
        )
    }

    // MARK: - The composite-key plan

    /// Every key column, **in key order**, and the edited column's old value
    /// last — the binding order the app half relies on without knowing it.
    func testACompositeKeyPlanNamesEveryKeyColumnInKeyOrder() throws {
        let plan = try plan(
            compositeKeyTarget(),
            row: [.text("Ash"), .integer(3), .text("dusty")],
            columnIndex: 2,
            entry: .typed("clean")
        )

        XCTAssertEqual(
            plan.statement,
            DatabaseStatement(
                "UPDATE \"rooms\" SET \"note\" = ? WHERE \"house\" IS ? AND \"room\" IS ? AND \"note\" IS ?",
                parameters: [.text("clean"), .text("Ash"), .integer(3), .text("dusty")]
            )
        )
        XCTAssertEqual(plan.requiredAffectedRows, 1)
    }

    /// A key column's value is read from the row at the position the identity
    /// engine recorded — which is a **result** position, not a schema one.
    func testKeyValuesComeFromTheRecordedResultPositions() throws {
        var target = compositeKeyTarget()
        target.gridColumns = ["note", "house", "room"]
        target.identity = .primaryKey(columns: [
            DatabaseKeyColumn(name: "house", resultIndex: 1),
            DatabaseKeyColumn(name: "room", resultIndex: 2),
        ])

        let plan = try plan(
            target,
            row: [.text("dusty"), .text("Ash"), .integer(3)],
            columnIndex: 0,
            entry: .typed("clean")
        )

        XCTAssertEqual(plan.statement.parameters, [.text("clean"), .text("Ash"), .integer(3), .text("dusty")])
    }

    // MARK: - Name matching, not position

    /// The property this whole decision exists for. `PRAGMA table_xinfo` lists a
    /// generated column that `SELECT *` does not answer, so a hidden column ahead
    /// of a visible one shifts every later schema ordinal. Grid column 1 is
    /// `title` here; positionally it would be `slug`, and a plan built that way
    /// would write the wrong column of the right row, silently.
    func testAHiddenColumnAheadOfTheVisibleOnesDoesNotShiftTheMatch() throws {
        let target = DatabaseEditTarget(
            table: "albums",
            columns: [
                column("id", type: "INTEGER", key: 1),
                column("slug", type: "TEXT", hidden: true),
                column("title", type: "TEXT"),
            ],
            gridColumns: ["id", "title"],
            identity: .rowid(alias: .rowid)
        )

        let plan = try plan(
            target,
            row: [.integer(1), .text("old")],
            rowIdentity: .integer(7),
            columnIndex: 1,
            entry: .typed("new")
        )

        XCTAssertTrue(plan.statement.sql.contains("SET \"title\" = ?"), plan.statement.sql)
        XCTAssertFalse(plan.statement.sql.contains("slug"), plan.statement.sql)
    }

    /// Matching is case-insensitive, as SQLite's identifier comparison is — and
    /// the statement quotes the **schema's** spelling, not the answer's.
    func testTheMatchIsCaseInsensitiveAndQuotesTheDeclaredSpelling() throws {
        var target = rowIdTarget()
        target.gridColumns = ["id", "TITLE"]

        let plan = try plan(
            target,
            row: [.integer(1), .text("old")],
            rowIdentity: .integer(7),
            columnIndex: 1,
            entry: .typed("new")
        )

        XCTAssertTrue(plan.statement.sql.contains("SET \"title\" = ?"), plan.statement.sql)
    }

    /// No match at all is a refusal, never a guess: a grid column the schema
    /// cannot name is a column nobody can write.
    func testAnUnmatchedColumnNameRefuses() {
        var target = rowIdTarget()
        target.gridColumns = ["id", "titel"]

        XCTAssertEqual(
            refusal(target, row: [.integer(1), .text("old")], rowIdentity: .integer(7), columnIndex: 1),
            .columnNotMatched(name: "titel")
        )
    }

    /// Two schema columns spelling the same name (case-insensitively) is not
    /// something a table can normally hold, but it is exactly the shape that
    /// makes a "unique match" rule worth having — refused rather than resolved to
    /// the first.
    func testAnAmbiguousColumnNameRefuses() {
        var target = rowIdTarget()
        target.columns = [column("id", type: "INTEGER", key: 1), column("title"), column("TITLE")]

        XCTAssertEqual(
            refusal(target, row: [.integer(1), .text("old")], rowIdentity: .integer(7), columnIndex: 1),
            .columnNotMatched(name: "title")
        )
    }

    // MARK: - Every refusal

    func testAViewRefusesWholesale() {
        var target = rowIdTarget()
        target.identity = .unavailable(.view)

        XCTAssertEqual(
            refusal(target, row: [.integer(1), .text("old")], columnIndex: 1),
            .unaddressableRow(.view)
        )
    }

    func testATableWithNoIdentityRefuses() {
        var target = rowIdTarget()
        target.identity = .unavailable(.noRowIdentity)

        XCTAssertEqual(
            refusal(target, row: [.integer(1), .text("old")], columnIndex: 1),
            .unaddressableRow(.noRowIdentity)
        )
    }

    /// A `WITHOUT ROWID` table whose key the page does not carry in full: the
    /// identity engine's own gap, forwarded rather than restated.
    func testAWithoutRowIdTableWithAnIncompleteKeyRefuses() {
        var target = compositeKeyTarget()
        target.identity = .unavailable(.keyColumnNotAnswered(name: "room"))

        XCTAssertEqual(
            refusal(target, row: [.text("Ash"), .integer(3), .text("dusty")], columnIndex: 2),
            .unaddressableRow(.keyColumnNotAnswered(name: "room"))
        )

        target.identity = .unavailable(.keyColumnAmbiguous(name: "room"))
        XCTAssertEqual(
            refusal(target, row: [.text("Ash"), .integer(3), .text("dusty")], columnIndex: 2),
            .unaddressableRow(.keyColumnAmbiguous(name: "room"))
        )
    }

    func testAGeneratedColumnRefuses() {
        var target = rowIdTarget()
        target.columns = [column("id", type: "INTEGER", key: 1), column("title", type: "TEXT", hidden: true)]

        XCTAssertEqual(
            refusal(target, row: [.integer(1), .text("old")], rowIdentity: .integer(7), columnIndex: 1),
            .generatedColumn(name: "title")
        )
    }

    /// A page carries a blob's length and never its bytes, so there is nothing to
    /// put in the `WHERE` — and nothing a text field could sensibly replace.
    func testABlobCellRefuses() {
        XCTAssertEqual(
            refusal(
                rowIdTarget(),
                row: [.integer(1), .blob(byteCount: 4096)],
                rowIdentity: .integer(7),
                columnIndex: 1
            ),
            .blobCell(column: "title")
        )
    }

    /// A binary primary key — a content-addressed `WITHOUT ROWID` table — makes
    /// the whole *row* unaddressable, not one cell of it: the bytes a `WHERE`
    /// would name it with never left the database. Refused for every column,
    /// including the ordinary text one beside the key.
    func testABlobPrimaryKeyRefusesEveryCellOfTheRow() {
        let target = DatabaseEditTarget(
            table: "blobs",
            columns: [column("h", type: "BLOB", key: 1), column("v", type: "TEXT")],
            gridColumns: ["h", "v"],
            identity: .primaryKey(columns: [DatabaseKeyColumn(name: "h", resultIndex: 0)])
        )
        let row: [DatabaseValue] = [.blob(byteCount: 32), .text("payload")]

        XCTAssertEqual(refusal(target, row: row, columnIndex: 0), .blobRowIdentity(column: "h"))
        XCTAssertEqual(refusal(target, row: row, columnIndex: 1), .blobRowIdentity(column: "h"))
    }

    /// And nothing is composed for one — the refusal is what stops a statement
    /// binding a value that carries its length and not its bytes.
    func testABlobPrimaryKeyComposesNoStatement() {
        let target = DatabaseEditTarget(
            table: "blobs",
            columns: [column("h", type: "BLOB", key: 1), column("v", type: "TEXT")],
            gridColumns: ["h", "v"],
            identity: .primaryKey(columns: [DatabaseKeyColumn(name: "h", resultIndex: 0)])
        )

        let result = DatabaseUpdatePlanner.plan(
            target: target,
            row: [.blob(byteCount: 32), .text("payload")],
            rowIdentity: nil,
            columnIndex: 1,
            entry: .typed("new")
        )

        guard case .failure(let refusal) = result else {
            return XCTFail("expected a refusal, got \(result)")
        }
        XCTAssertEqual(refusal, .blobRowIdentity(column: "h"))
    }

    /// A key column that happens to hold something bindable is untouched by the
    /// rule above: the refusal is about the *value* on screen, not about the
    /// column's declared type.
    func testAKeyColumnHoldingATextValueStillWrites() throws {
        let plan = try plan(
            compositeKeyTarget(),
            row: [.text("Ash"), .integer(3), .text("dusty")],
            columnIndex: 2,
            entry: .typed("clean")
        )

        XCTAssertEqual(
            plan.statement.parameters,
            [.text("clean"), .text("Ash"), .integer(3), .text("dusty")]
        )
    }

    /// A rowid table whose row arrived without an identity value: the page was
    /// split as though it carried none, so this row cannot be named.
    func testARowWithoutItsIdentityValueRefuses() {
        XCTAssertEqual(
            refusal(rowIdTarget(), row: [.integer(1), .text("old")], rowIdentity: nil, columnIndex: 1),
            .rowIdentityMissing
        )
    }

    func testACellOffThePageRefuses() {
        XCTAssertEqual(
            refusal(rowIdTarget(), row: [.integer(1), .text("old")], rowIdentity: .integer(7), columnIndex: 2),
            .cellNotOnPage
        )
        XCTAssertEqual(
            refusal(rowIdTarget(), row: [.integer(1)], rowIdentity: .integer(7), columnIndex: 1),
            .cellNotOnPage
        )
    }

    /// The one discriminator this file keeps, and the reason it is a `switch`
    /// with no `default`: `DatabaseEditRefusal` carries associated values and so
    /// cannot be `CaseIterable`, which would leave "every refusal has a sentence
    /// of its own" a claim about however many literals somebody remembered to
    /// list. A case added to the enum stops *this file* compiling until it is
    /// named here, and the test below then insists it is in the sample list too.
    private func tag(_ refusal: DatabaseEditRefusal) -> String {
        switch refusal {
        case .unaddressableRow(let gap): return "unaddressableRow.\(gap)"
        case .rowIdentityMissing: return "rowIdentityMissing"
        case .columnNotMatched: return "columnNotMatched"
        case .generatedColumn: return "generatedColumn"
        case .blobCell: return "blobCell"
        case .blobRowIdentity: return "blobRowIdentity"
        case .cellNotOnPage: return "cellNotOnPage"
        }
    }

    /// Every refusal says something, and says it about the thing that was
    /// refused — the surface has one place to read the sentence from.
    func testEveryRefusalCarriesItsOwnSentence() {
        let refusals: [DatabaseEditRefusal] = [
            .unaddressableRow(.view),
            .unaddressableRow(.noRowIdentity),
            .unaddressableRow(.keyColumnNotAnswered(name: "room")),
            .unaddressableRow(.keyColumnAmbiguous(name: "room")),
            .rowIdentityMissing,
            .columnNotMatched(name: "titel"),
            .generatedColumn(name: "slug"),
            .blobCell(column: "cover"),
            .blobRowIdentity(column: "digest"),
            .cellNotOnPage,
        ]
        var seen: Set<String> = []
        var tags: Set<String> = []

        for refusal in refusals {
            XCTAssertFalse(refusal.message.isEmpty, "\(refusal)")
            XCTAssertEqual(refusal.errorDescription, refusal.message)
            XCTAssertTrue(seen.insert(refusal.message).inserted, refusal.message)
            XCTAssertTrue(tags.insert(tag(refusal)).inserted, "listed twice: \(tag(refusal))")
        }
        // The sample list carries one of every case: the `tag(_:)` switch above
        // cannot compile without naming a new case, and this count cannot pass
        // without a sample of it being listed.
        XCTAssertEqual(tags.count, refusals.count)
        XCTAssertEqual(
            tags,
            [
                "unaddressableRow.view",
                "unaddressableRow.noRowIdentity",
                "unaddressableRow.keyColumnNotAnswered(name: \"room\")",
                "unaddressableRow.keyColumnAmbiguous(name: \"room\")",
                "rowIdentityMissing",
                "columnNotMatched",
                "generatedColumn",
                "blobCell",
                "blobRowIdentity",
                "cellNotOnPage",
            ]
        )
        XCTAssertTrue(DatabaseEditRefusal.generatedColumn(name: "slug").message.contains("slug"))
        XCTAssertTrue(DatabaseEditRefusal.columnNotMatched(name: "titel").message.contains("titel"))
        XCTAssertTrue(DatabaseEditRefusal.blobCell(column: "cover").message.contains("cover"))
        XCTAssertTrue(DatabaseEditRefusal.blobRowIdentity(column: "digest").message.contains("digest"))
        XCTAssertTrue(DatabaseEditRefusal.unaddressableRow(.keyColumnAmbiguous(name: "room")).message.contains("room"))
    }

    /// The surface asks the same question the planner asks, so a cell the grid
    /// lets someone type into is never refused after they have typed.
    ///
    /// Asserted by asking **both** halves about the same cell rather than by
    /// asking one twice: for every column of a table carrying a blob, a hidden
    /// column and a name the schema cannot match, `refusal(…)` answering `nil`
    /// must mean `plan(…)` composes, and `refusal(…)` answering must mean
    /// `plan(…)` fails with *that same* refusal.
    func testTheSurfacesQuestionAgreesWithThePlanner() {
        var target = rowIdTarget()
        target.columns = [
            column("id", type: "INTEGER", key: 1),
            column("title", type: "TEXT"),
            column("slug", type: "TEXT", hidden: true),
            column("cover", type: "BLOB"),
        ]
        target.gridColumns = ["id", "title", "slug", "cover", "titel"]
        let row: [DatabaseValue] = [
            .integer(1), .text("old"), .text("generated"), .blob(byteCount: 2), .text("stray"),
        ]

        for columnIndex in 0...row.count {
            let refused = DatabaseUpdatePlanner.refusal(
                target: target,
                row: row,
                rowIdentity: .integer(7),
                columnIndex: columnIndex
            )
            let composed = DatabaseUpdatePlanner.plan(
                target: target,
                row: row,
                rowIdentity: .integer(7),
                columnIndex: columnIndex,
                entry: .typed("new")
            )
            switch (refused, composed) {
            case (nil, .success):
                continue
            case (let refusal?, .failure(let planned)):
                XCTAssertEqual(refusal, planned, "column \(columnIndex)")
            default:
                XCTFail("column \(columnIndex): the surface said \(String(describing: refused)), the planner \(composed)")
            }
        }
        // And the fixture is one that actually exercises both answers, so the
        // loop above cannot pass by refusing everything.
        XCTAssertNil(DatabaseUpdatePlanner.refusal(target: target, row: row, rowIdentity: .integer(7), columnIndex: 1))
        XCTAssertEqual(
            DatabaseUpdatePlanner.refusal(target: target, row: row, rowIdentity: .integer(7), columnIndex: 3),
            .blobCell(column: "cover")
        )
    }

    /// The two backstops in `address(…)`: an empty key list and a key column
    /// whose position is past the row on screen. Neither can arrive from
    /// `DatabaseRowIdentity.resolve(…)`, and both exist so that no other
    /// construction of a strategy can compose a `WHERE` naming no row — which
    /// would be an `UPDATE` matching every row in the table.
    func testAnUnusableKeyStrategyComposesNoStatement() {
        var target = compositeKeyTarget()
        let row: [DatabaseValue] = [.text("Ash"), .integer(3), .text("dusty")]

        target.identity = .primaryKey(columns: [])
        guard case .failure(let empty) = DatabaseUpdatePlanner.plan(
            target: target, row: row, rowIdentity: nil, columnIndex: 2, entry: .typed("clean")
        ) else {
            return XCTFail("an empty key list must compose nothing")
        }
        XCTAssertEqual(empty, .cellNotOnPage)

        target.identity = .primaryKey(columns: [DatabaseKeyColumn(name: "house", resultIndex: 9)])
        guard case .failure(let outOfRange) = DatabaseUpdatePlanner.plan(
            target: target, row: row, rowIdentity: nil, columnIndex: 2, entry: .typed("clean")
        ) else {
            return XCTFail("a key column off the page must compose nothing")
        }
        XCTAssertEqual(outOfRange, .cellNotOnPage)
    }

    // MARK: - NULL on either side

    /// `IS`, not `=`: a NULL previous value is matched honestly instead of
    /// matching nothing, which is what makes a NULL cell writable at all.
    func testANullPreviousValueIsMatchedWithIs() throws {
        let plan = try plan(
            rowIdTarget(),
            row: [.integer(1), .null],
            rowIdentity: .integer(7),
            columnIndex: 1,
            entry: .typed("filled in")
        )

        XCTAssertEqual(
            plan.statement,
            DatabaseStatement(
                "UPDATE \"albums\" SET \"title\" = ? WHERE rowid IS ? AND \"title\" IS ?",
                parameters: [.text("filled in"), .integer(7), .null]
            )
        )
        XCTAssertFalse(plan.statement.sql.contains("= ? AND"), plan.statement.sql)
        XCTAssertFalse(plan.statement.sql.contains("NULL"), plan.statement.sql)
    }

    /// NULL is reachable only through the gesture, and it arrives bound like
    /// every other value — the word never reaches the text.
    func testTheNullGestureBindsNullRatherThanSplicingIt() throws {
        let plan = try plan(
            rowIdTarget(),
            row: [.integer(1), .text("old")],
            rowIdentity: .integer(7),
            columnIndex: 1,
            entry: .null
        )

        XCTAssertEqual(plan.newValue, .null)
        XCTAssertEqual(plan.statement.parameters, [.null, .integer(7), .text("old")])
        XCTAssertFalse(plan.statement.sql.uppercased().contains("NULL"), plan.statement.sql)
    }

    /// An empty entry is the empty string, and the two are distinguishable all
    /// the way through: `text("")` is not `null`.
    func testAnEmptyEntryIsTheEmptyStringAndNotNull() throws {
        let plan = try plan(
            rowIdTarget(),
            row: [.integer(1), .text("old")],
            rowIdentity: .integer(7),
            columnIndex: 1,
            entry: .typed("")
        )

        XCTAssertEqual(plan.newValue, .text(""))
        XCTAssertNotEqual(plan.newValue, .null)
    }

    // MARK: - The typing rule reaches the plan

    /// The plan does not re-decide what a typed string means: it asks
    /// `DatabaseCellEntry`, so a declared INTEGER column stores an integer and a
    /// TEXT column stores the characters.
    func testTheColumnsAffinityDecidesWhatIsBound() throws {
        var target = rowIdTarget()
        target.columns = [column("id", type: "INTEGER", key: 1), column("title", type: "VARCHAR(255)")]

        let integerCell = try plan(
            target,
            row: [.integer(1), .text("t")],
            rowIdentity: .integer(7),
            columnIndex: 0,
            entry: .typed("42")
        )
        let textCell = try plan(
            target,
            row: [.integer(1), .text("t")],
            rowIdentity: .integer(7),
            columnIndex: 1,
            entry: .typed("42")
        )

        XCTAssertEqual(integerCell.newValue, .integer(42))
        XCTAssertEqual(textCell.newValue, .text("42"))
    }

    /// An untyped column keeps the cell's storage class when the entry parses as
    /// it — the rule that stops one edit retyping a whole ad-hoc column.
    func testAnUntypedColumnKeepsTheCellsStorageClass() throws {
        var target = rowIdTarget()
        target.columns = [column("id", type: "INTEGER", key: 1), column("title")]

        let overInteger = try plan(
            target,
            row: [.integer(1), .integer(42)],
            rowIdentity: .integer(7),
            columnIndex: 1,
            entry: .typed("43")
        )
        let overText = try plan(
            target,
            row: [.integer(1), .text("42")],
            rowIdentity: .integer(7),
            columnIndex: 1,
            entry: .typed("43")
        )

        XCTAssertEqual(overInteger.newValue, .integer(43))
        XCTAssertEqual(overText.newValue, .text("43"))
    }

    // MARK: - Nothing typed reaches the text

    /// The injection test, stated as the property rather than as a blocklist: a
    /// cell's content is a **parameter**, in a fixed position, and the statement
    /// text is byte-for-byte the one an innocuous value produces.
    func testNoCellContentEverReachesTheStatementText() throws {
        let hostile = "'; DROP TABLE albums; --"
        let hostilePlan = try plan(
            rowIdTarget(),
            row: [.integer(1), .text(hostile)],
            rowIdentity: .integer(7),
            columnIndex: 1,
            entry: .typed(hostile)
        )
        let innocuous = try plan(
            rowIdTarget(),
            row: [.integer(1), .text("old")],
            rowIdentity: .integer(7),
            columnIndex: 1,
            entry: .typed("new")
        )

        XCTAssertEqual(hostilePlan.statement.sql, innocuous.statement.sql)
        XCTAssertFalse(hostilePlan.statement.sql.contains("DROP"))
        XCTAssertEqual(hostilePlan.statement.parameters, [.text(hostile), .integer(7), .text(hostile)])
        XCTAssertEqual(
            hostilePlan.statement.sql.filter { $0 == "?" }.count,
            hostilePlan.statement.parameters.count
        )
    }

    /// Identifiers *are* spliced, because they cannot be parameters — so they are
    /// quoted, and a name carrying a quote, a space or a semicolon closes
    /// nothing.
    func testIdentifiersHoldingQuotesAndSpacesAreQuoted() throws {
        let target = DatabaseEditTarget(
            table: "od\"d; --",
            columns: [column("k", type: "INTEGER", key: 1), column("two \"words\"", type: "TEXT")],
            gridColumns: ["k", "two \"words\""],
            identity: .rowid(alias: .rowid)
        )

        let plan = try plan(
            target,
            row: [.integer(1), .text("old")],
            rowIdentity: .integer(7),
            columnIndex: 1,
            entry: .typed("new")
        )

        XCTAssertEqual(
            plan.statement.sql,
            "UPDATE \"od\"\"d; --\" SET \"two \"\"words\"\"\" = ? "
                + "WHERE rowid IS ? AND \"two \"\"words\"\"\" IS ?"
        )
    }
}
