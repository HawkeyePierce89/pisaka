import XCTest
@testable import PisakaCore

final class PartialCommitBuilderTests: XCTestCase {

    // MARK: - Helpers

    private func rows(_ head: String, _ worktree: String) -> [DiffRow] {
        LineDiff.rows(old: head, new: worktree)
    }

    private func units(_ rows: [DiffRow]) -> Set<Int> {
        Set(CommitDiffUnits.selectableUnits(rows: rows))
    }

    private func assemble(
        head: String,
        worktree: String,
        selecting select: (Set<Int>) -> Set<Int>
    ) -> String {
        let r = rows(head, worktree)
        return PartialCommitBuilder.assemble(
            head: head,
            worktree: worktree,
            rows: r,
            selectedUnits: select(units(r))
        )
    }

    private func assembleAll(head: String, worktree: String) -> String {
        assemble(head: head, worktree: worktree) { $0 }
    }

    private func assembleNone(head: String, worktree: String) -> String {
        assemble(head: head, worktree: worktree) { _ in [] }
    }

    // MARK: - The structural invariant

    /// The one invariant the whole mechanism rests on: with nothing selected the
    /// builder reproduces the `HEAD` bytes *identically* — not "equivalently", not
    /// "modulo line endings". A commit of an unchecked file must be a no-op for
    /// that path, and anything less would silently rewrite lines the user never
    /// touched.
    func testEmptySelectionReproducesHeadBytes() {
        let samples: [(head: String, worktree: String)] = [
            ("a\nb\nc\n", "a\nX\nc\n"),
            ("a\nb\n", "a\nb\nc\nd\n"),
            ("a\nb\nc\n", "a\n"),
            ("", "new\nfile\n"),
            ("gone\naway\n", ""),
        ]
        for sample in samples {
            XCTAssertEqual(
                assembleNone(head: sample.head, worktree: sample.worktree),
                sample.head,
                "empty selection changed HEAD for \(String(reflecting: sample.head))"
            )
        }
    }

    /// The same invariant where it is easiest to break: mixed separators and a
    /// missing final newline. Every unselected line is emitted from the old side
    /// verbatim, terminator included, so both survive untouched.
    func testEmptySelectionReproducesHeadBytesUnderMixedEndingsAndNoTrailingNewline() {
        let head = "a\r\nb\nc\rd\u{2028}e"
        let worktree = "a\nB\nc\nD\ne\nf"
        XCTAssertEqual(assembleNone(head: head, worktree: worktree), head)
    }

    func testEmptySelectionOnIdenticalTextsReproducesHead() {
        let head = "a\r\nb\r\n"
        XCTAssertEqual(assembleNone(head: head, worktree: head), head)
    }

    // MARK: - The converse, which holds only conditionally

    /// When every *unchanged* line is terminated the same way on both sides,
    /// selecting every unit does reproduce the worktree bytes — the changed lines
    /// come from the new side verbatim and the unchanged ones are byte-identical
    /// on either side, so which side they are taken from stops mattering.
    func testSelectingAllUnitsReproducesWorktreeWhenUnchangedLinesAgreeOnTerminators() {
        let samples: [(head: String, worktree: String)] = [
            ("a\nb\nc\n", "a\nX\nc\n"),
            ("a\nb\nc\n", "a\nc\n"),
            ("a\nc\n", "a\nb\nc\n"),
            ("a\r\nb\r\nc\r\n", "a\r\nX\r\nc\r\n"),
            ("a\nb", "a\nX"),
            ("", "x\ny\n"),
            ("x\ny\n", ""),
        ]
        for sample in samples {
            XCTAssertEqual(
                assembleAll(head: sample.head, worktree: sample.worktree),
                sample.worktree,
                "full selection did not reproduce the worktree for \(String(reflecting: sample.worktree))"
            )
        }
    }

    /// A *changed* line whose terminator differs is not a counterexample: it is
    /// taken from the new side, terminator and all — including the "the file lost
    /// its final newline" case.
    func testSelectedLineBringsTheNewSideTerminatorIncludingALostFinalNewline() {
        XCTAssertEqual(assembleAll(head: "a\nb\n", worktree: "a\nB"), "a\nB")
        XCTAssertEqual(assembleAll(head: "a\nb", worktree: "a\nB\n"), "a\nB\n")
    }

    /// The counterexample to the *unconditional* reading of the rule above, and
    /// the reason it is stated conditionally in the doc comment rather than pinned
    /// as an invariant.
    ///
    /// `LineDiff` compares terminator-stripped lines, so a line whose terminator
    /// alone switched from CRLF to LF produces no changed row — there is no unit
    /// for it, nothing to check, and the separator rule emits it from the old side
    /// verbatim. Selecting every unit that *does* exist therefore yields a result
    /// that differs from the worktree exactly in that terminator. This is correct
    /// behaviour, not a bug: the builder rewrites only what was selected. In
    /// production the divergence is unobservable, because a fully checked file
    /// bypasses the builder entirely and its bytes are placed by git itself.
    func testUnchangedLineWhoseTerminatorSwitchedIsNotAUnitAndKeepsTheOldTerminator() {
        let head = "a\r\nb\r\n"
        let worktree = "a\nB\r\n"
        let r = rows(head, worktree)

        // Only the content change is a unit; the CRLF→LF rewrite of "a" is not.
        XCTAssertEqual(CommitDiffUnits.selectableUnits(rows: r).count, 1)

        let assembled = assembleAll(head: head, worktree: worktree)
        XCTAssertEqual(assembled, "a\r\nB\r\n")
        XCTAssertNotEqual(assembled, worktree)
    }

    /// The degenerate shape of the same boundary: a file whose *only* difference is
    /// its line endings has zero units, so "select everything" and "select nothing"
    /// are the same empty set and both reproduce HEAD.
    func testFileDifferingOnlyInLineEndingsHasNoUnitsAndAssemblesToHead() {
        let head = "a\r\nb\r\n"
        let worktree = "a\nb\n"
        let r = rows(head, worktree)

        XCTAssertTrue(CommitDiffUnits.selectableUnits(rows: r).isEmpty)
        XCTAssertEqual(assembleAll(head: head, worktree: worktree), head)
    }

    // MARK: - Combinations

    func testAddedOnly() {
        let head = "a\nb\n"
        let worktree = "a\nnew\nb\n"
        let r = rows(head, worktree)
        let added = CommitDiffUnits.selectableUnits(rows: r)
        XCTAssertEqual(added.count, 1)

        XCTAssertEqual(
            PartialCommitBuilder.assemble(head: head, worktree: worktree, rows: r, selectedUnits: Set(added)),
            "a\nnew\nb\n"
        )
        XCTAssertEqual(
            PartialCommitBuilder.assemble(head: head, worktree: worktree, rows: r, selectedUnits: []),
            head
        )
    }

    func testRemovedOnly() {
        let head = "a\nb\nc\n"
        let worktree = "a\nc\n"
        let r = rows(head, worktree)
        let removed = CommitDiffUnits.selectableUnits(rows: r)
        XCTAssertEqual(removed.count, 1)

        XCTAssertEqual(
            PartialCommitBuilder.assemble(head: head, worktree: worktree, rows: r, selectedUnits: Set(removed)),
            "a\nc\n"
        )
        XCTAssertEqual(
            PartialCommitBuilder.assemble(head: head, worktree: worktree, rows: r, selectedUnits: []),
            head
        )
    }

    func testModifiedOnly() {
        let head = "a\nb\nc\n"
        let worktree = "a\nB\nc\n"
        XCTAssertEqual(assembleAll(head: head, worktree: worktree), "a\nB\nc\n")
        XCTAssertEqual(assembleNone(head: head, worktree: worktree), head)
    }

    /// Two adjacent changes are two independent units: checking one must not drag
    /// its neighbour in.
    func testAdjacentChangesAreIndependentUnits() {
        let head = "a\nb\nc\nd\n"
        let worktree = "a\nX\nY\nd\n"
        let r = rows(head, worktree)
        let selectable = CommitDiffUnits.selectableUnits(rows: r)
        XCTAssertEqual(selectable.count, 2)

        XCTAssertEqual(
            PartialCommitBuilder.assemble(
                head: head, worktree: worktree, rows: r, selectedUnits: [selectable[0]]
            ),
            "a\nX\nc\nd\n"
        )
        XCTAssertEqual(
            PartialCommitBuilder.assemble(
                head: head, worktree: worktree, rows: r, selectedUnits: [selectable[1]]
            ),
            "a\nb\nY\nd\n"
        )
    }

    func testInterleavedSelectedAndUnselectedUnits() {
        let head = "1\n2\n3\n4\n5\n"
        let worktree = "1\nA\n3\nB\n5\n"
        let r = rows(head, worktree)
        let selectable = CommitDiffUnits.selectableUnits(rows: r)
        XCTAssertEqual(selectable.count, 2)

        XCTAssertEqual(
            PartialCommitBuilder.assemble(
                head: head, worktree: worktree, rows: r, selectedUnits: [selectable[0]]
            ),
            "1\nA\n3\n4\n5\n"
        )
        XCTAssertEqual(
            PartialCommitBuilder.assemble(
                head: head, worktree: worktree, rows: r, selectedUnits: [selectable[1]]
            ),
            "1\n2\n3\nB\n5\n"
        )
    }

    /// An addition and a removal selected independently of one another.
    func testMixedAdditionAndRemovalSelectedSeparately() {
        let head = "keep\ndrop\ntail\n"
        let worktree = "keep\nadded\ntail\nmore\n"
        let r = rows(head, worktree)

        // Everything: the removal applies and both additions land.
        XCTAssertEqual(assembleAll(head: head, worktree: worktree), worktree)

        // Only the trailing addition: "drop" survives because its removal is not
        // selected.
        let trailing = r.indices.filter { r[$0].kind != .unchanged && r[$0].right?.text == "more" }
        XCTAssertEqual(trailing.count, 1)
        XCTAssertEqual(
            PartialCommitBuilder.assemble(
                head: head, worktree: worktree, rows: r, selectedUnits: Set(trailing)
            ),
            "keep\ndrop\ntail\nmore\n"
        )
    }

    // MARK: - Separators

    func testCRLFFileKeepsCRLF() {
        let head = "a\r\nb\r\nc\r\n"
        let worktree = "a\r\nB\r\nc\r\n"
        XCTAssertEqual(assembleAll(head: head, worktree: worktree), worktree)
        XCTAssertEqual(assembleNone(head: head, worktree: worktree), head)
    }

    /// The separator rule in one assertion: the selected line arrives with the new
    /// side's terminator while every unselected line keeps the old side's.
    func testSelectedLineBringsNewTerminatorUnselectedKeepsOld() {
        let head = "a\nb\nc\n"
        let worktree = "a\r\nB\r\nc\r\n"
        let r = rows(head, worktree)
        let selectable = CommitDiffUnits.selectableUnits(rows: r)
        XCTAssertEqual(selectable.count, 1)

        XCTAssertEqual(
            PartialCommitBuilder.assemble(
                head: head, worktree: worktree, rows: r, selectedUnits: Set(selectable)
            ),
            "a\nB\r\nc\n"
        )
    }

    /// An unselected *removal* is emitted from the old side verbatim, so its own
    /// terminator survives even when it differs from everything around it.
    func testUnselectedRemovalKeepsItsOwnTerminator() {
        let head = "a\nb\r\nc\n"
        let worktree = "a\nc\n"
        XCTAssertEqual(assembleNone(head: head, worktree: worktree), head)
    }

    func testNoTrailingNewlineOnBothSides() {
        let head = "a\nb"
        let worktree = "a\nB"
        XCTAssertEqual(assembleAll(head: head, worktree: worktree), "a\nB")
        XCTAssertEqual(assembleNone(head: head, worktree: worktree), head)
    }

    /// A final newline appearing only on one side is carried by whichever side the
    /// line is taken from — the "missing final newline" case is a value of the
    /// ordinary separator rule, not a branch of its own.
    func testTrailingNewlineOnOneSideOnly() {
        XCTAssertEqual(assembleAll(head: "a\nb\n", worktree: "a\nB"), "a\nB")
        XCTAssertEqual(assembleNone(head: "a\nb\n", worktree: "a\nB"), "a\nb\n")
        XCTAssertEqual(assembleAll(head: "a\nb", worktree: "a\nB\n"), "a\nB\n")
        XCTAssertEqual(assembleNone(head: "a\nb", worktree: "a\nB\n"), "a\nb")
    }

    /// An appended line where the previous last line had no terminator: the
    /// worktree gave that line a terminator, which is itself a change, so both
    /// rows are units and checking only the appended one is impossible without
    /// also taking the terminator. Pinned so the behaviour is visible rather than
    /// surprising.
    func testAppendingAfterAnUnterminatedFinalLine() {
        let head = "a\nb"
        let worktree = "a\nb\nc\n"
        let r = rows(head, worktree)
        // "b" itself is unchanged as *content*, so only the new line is a unit.
        let selectable = CommitDiffUnits.selectableUnits(rows: r)
        XCTAssertEqual(selectable.count, 1)
        // Selecting it emits "b" from the old side — which carries no terminator —
        // followed by the new line. The separator the worktree gives "b" now that
        // it is no longer last is inserted between them, so the two do not fuse
        // into "bc", a line present on neither side.
        XCTAssertEqual(
            PartialCommitBuilder.assemble(
                head: head, worktree: worktree, rows: r, selectedUnits: Set(selectable)
            ),
            "a\nb\nc\n"
        )
    }

    /// The same shape with *two* appended lines and only one checked — the case a
    /// full selection cannot route around, since `CommitPlan` sends a partial
    /// selection through the builder. Without the borrowed separator this
    /// assembled "a\nbc\n", fusing the old final line with a selected new one and
    /// committing a line present on neither side.
    func testPartialAppendAfterUnterminatedFinalLineDoesNotFuseLines() {
        let head = "a\nb"
        let worktree = "a\nb\nc\nd\n"
        let r = rows(head, worktree)
        let selectable = CommitDiffUnits.selectableUnits(rows: r)
        XCTAssertEqual(selectable.count, 2)

        XCTAssertEqual(
            PartialCommitBuilder.assemble(
                head: head, worktree: worktree, rows: r, selectedUnits: [selectable[0]]
            ),
            "a\nb\nc\n"
        )
        XCTAssertEqual(
            PartialCommitBuilder.assemble(
                head: head, worktree: worktree, rows: r, selectedUnits: [selectable[1]]
            ),
            "a\nb\nd\n"
        )
        // Still HEAD byte for byte with nothing checked: the pending separator is
        // only ever flushed by a *following* emission, and none happens here.
        XCTAssertEqual(
            PartialCommitBuilder.assemble(
                head: head, worktree: worktree, rows: r, selectedUnits: []
            ),
            head
        )
    }

    /// The borrowed separator is the counterpart's, verbatim — a CRLF file does
    /// not silently gain an LF where its last line grew a terminator.
    func testBorrowedSeparatorFollowsTheCounterpartsLineEnding() {
        let head = "a\r\nb"
        let worktree = "a\r\nb\r\nc\r\nd\r\n"
        let r = rows(head, worktree)
        let selectable = CommitDiffUnits.selectableUnits(rows: r)
        XCTAssertEqual(selectable.count, 2)

        XCTAssertEqual(
            PartialCommitBuilder.assemble(
                head: head, worktree: worktree, rows: r, selectedUnits: [selectable[0]]
            ),
            "a\r\nb\r\nc\r\n"
        )
    }

    /// The mirror image: a *selected* change whose new-side line is unterminated,
    /// followed by an old line that survives. Without the separator the two ran
    /// together as "cb".
    func testUnterminatedSelectedLineFollowedBySurvivingOldLine() {
        let head = "a\nb\n"
        let worktree = "x"
        let r = rows(head, worktree)
        // "a" → "x" is a modification; "b" is removed.
        let selectable = CommitDiffUnits.selectableUnits(rows: r)
        XCTAssertEqual(selectable.count, 2)

        // Take the modification, leave the deletion: "b" must survive on its own
        // line rather than being glued onto "x".
        XCTAssertEqual(
            PartialCommitBuilder.assemble(
                head: head, worktree: worktree, rows: r, selectedUnits: [selectable[0]]
            ),
            "x\nb\n"
        )
    }

    // MARK: - Degenerate cases

    /// Untracked: HEAD is empty, every line is an added unit, and a subset of them
    /// can be committed on its own.
    func testUntrackedFileSelectingASubsetOfAddedUnits() {
        let head = ""
        let worktree = "x\ny\nz\n"
        let r = rows(head, worktree)
        let selectable = CommitDiffUnits.selectableUnits(rows: r)
        XCTAssertEqual(selectable.count, 3)

        XCTAssertEqual(
            PartialCommitBuilder.assemble(
                head: head, worktree: worktree, rows: r, selectedUnits: [selectable[0], selectable[2]]
            ),
            "x\nz\n"
        )
        XCTAssertEqual(
            PartialCommitBuilder.assemble(head: head, worktree: worktree, rows: r, selectedUnits: []),
            ""
        )
        XCTAssertEqual(assembleAll(head: head, worktree: worktree), worktree)
    }

    func testEmptyRowsYieldEmptyText() {
        XCTAssertEqual(
            PartialCommitBuilder.assemble(head: "", worktree: "", rows: [], selectedUnits: []),
            ""
        )
    }

    /// A selection carrying indices that name no row (a stale set kept across a
    /// re-diff) is ignored rather than trapping — the staleness check is a separate
    /// gate, and the builder must degrade instead of crashing.
    func testOutOfRangeSelectedIndicesAreIgnored() {
        let head = "a\nb\n"
        let worktree = "a\nB\n"
        let r = rows(head, worktree)
        XCTAssertEqual(
            PartialCommitBuilder.assemble(
                head: head, worktree: worktree, rows: r, selectedUnits: [99, 1000]
            ),
            head
        )
    }

    /// A row naming a line number neither side has (which `LineDiff` never
    /// produces) contributes nothing instead of trapping.
    func testRowsNamingMissingLinesContributeNothing() {
        let rows = [
            DiffRow(kind: .unchanged, left: DiffLine(number: 1, text: "a"), right: DiffLine(number: 1, text: "a")),
            DiffRow(kind: .modified, left: DiffLine(number: 9, text: "?"), right: DiffLine(number: 9, text: "?")),
        ]
        XCTAssertEqual(
            PartialCommitBuilder.assemble(head: "a\n", worktree: "a\n", rows: rows, selectedUnits: [1]),
            "a\n"
        )
        XCTAssertEqual(
            PartialCommitBuilder.assemble(head: "a\n", worktree: "a\n", rows: rows, selectedUnits: []),
            "a\n"
        )
    }
}
