import XCTest
@testable import PisakaCore

final class CommitDiffUnitsTests: XCTestCase {

    // MARK: - FileCommitEligibility

    func testDeletedIsWholeOnly() {
        XCTAssertEqual(
            FileCommitEligibility.classify(status: .deleted, head: .text("a\n"), worktree: .absent),
            .wholeOnly(reason: .deleted)
        )
    }

    func testBinaryHeadSideIsWholeOnly() {
        XCTAssertEqual(
            FileCommitEligibility.classify(status: .modified, head: .binary, worktree: .text("a\n")),
            .wholeOnly(reason: .binaryInHead)
        )
    }

    func testBinaryWorktreeSideIsWholeOnly() {
        XCTAssertEqual(
            FileCommitEligibility.classify(status: .modified, head: .text("a\n"), worktree: .binary),
            .wholeOnly(reason: .binaryInWorktree)
        )
    }

    func testBothSidesBinaryIsWholeOnly() {
        XCTAssertEqual(
            FileCommitEligibility.classify(status: .modified, head: .binary, worktree: .binary),
            .wholeOnly(reason: .binaryInHead)
        )
    }

    func testBothSidesTextIsSelectable() {
        XCTAssertEqual(
            FileCommitEligibility.classify(status: .modified, head: .text("a\n"), worktree: .text("b\n")),
            .selectable
        )
    }

    func testUntrackedWithTextWorktreeIsSelectable() {
        // HEAD `.absent` is not "unreadable" — an added/untracked file simply has
        // no old side, and its added lines are ordinary selection units.
        XCTAssertEqual(
            FileCommitEligibility.classify(status: .untracked, head: .absent, worktree: .text("a\n")),
            .selectable
        )
        XCTAssertEqual(
            FileCommitEligibility.classify(status: .added, head: .absent, worktree: .text("a\n")),
            .selectable
        )
    }

    func testUntrackedBinaryWorktreeIsWholeOnly() {
        XCTAssertEqual(
            FileCommitEligibility.classify(status: .untracked, head: .absent, worktree: .binary),
            .wholeOnly(reason: .binaryInWorktree)
        )
    }

    func testMissingWorktreeSideIsWholeOnlyEvenWhenStatusSaysOtherwise() {
        // A file that vanished between the status snapshot and the read: there is
        // nothing to select, so it can only be committed whole (as a deletion).
        XCTAssertEqual(
            FileCommitEligibility.classify(status: .modified, head: .text("a\n"), worktree: .absent),
            .wholeOnly(reason: .deleted)
        )
    }

    func testWholeOnlyFileHasNoSelectableUnits() {
        let rows = LineDiff.rows(old: "a\n", new: "b\n")
        XCTAssertFalse(CommitDiffUnits.selectableUnits(rows: rows).isEmpty)
        XCTAssertEqual(
            CommitDiffUnits.selectableUnits(
                eligibility: .wholeOnly(reason: .binaryInHead),
                rows: rows
            ),
            []
        )
        XCTAssertEqual(
            CommitDiffUnits.selectableUnits(eligibility: .selectable, rows: rows),
            CommitDiffUnits.selectableUnits(rows: rows)
        )
    }

    func testWholeOnlyReasonsCarryDistinctHumanText() {
        let reasons: [WholeOnlyReason] = [
            .deleted, .binaryInHead, .binaryInWorktree, .noSelectableChanges
        ]
        let messages = reasons.map(\.message)
        XCTAssertEqual(Set(messages).count, reasons.count)
        for message in messages {
            XCTAssertFalse(message.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - The "committed as a whole" placeholder, all three categories

    // The right-hand panel must never draw a diff whose checkboxes cannot be
    // clicked: a selection UI that refuses every click reads as broken, and for a
    // binary file a naive old/new diff additionally reads as "every HEAD line
    // removed". There are exactly three categories, and `wholeOnlyReason` is the
    // one place that decides between them (and supplies the sentence shown).

    private func facts(
        status: FileStatus,
        head: BlobText,
        worktree: BlobText
    ) -> CommitFileFacts {
        let eligibility = FileCommitEligibility.classify(
            status: status,
            head: head,
            worktree: worktree
        )
        let rows = eligibility == .selectable
            ? LineDiff.rows(old: head.text ?? "", new: worktree.text ?? "")
            : []
        return CommitFileFacts(
            file: ChangedFile(path: "a.txt", status: status),
            head: head,
            worktree: worktree,
            rows: rows
        )
    }

    func testWholeOnlyReasonForADeletedFile() {
        let facts = facts(status: .deleted, head: .text("a\n"), worktree: .absent)
        XCTAssertEqual(facts.wholeOnlyReason, .deleted)
    }

    func testWholeOnlyReasonForABinaryFile() {
        XCTAssertEqual(
            facts(status: .modified, head: .binary, worktree: .text("a\n")).wholeOnlyReason,
            .binaryInHead
        )
        XCTAssertEqual(
            facts(status: .modified, head: .text("a\n"), worktree: .binary).wholeOnlyReason,
            .binaryInWorktree
        )
    }

    func testWholeOnlyReasonForAFileDifferingOnlyInLineEndings() {
        // The third category: the file *is* selectable (both sides are text) yet
        // has zero units, because `LineDiff` compares terminator-stripped lines.
        // Its rows are all context, so the panel would otherwise draw a diff with
        // not a single checkbox in it.
        let facts = facts(status: .modified, head: .text("a\r\nb\r\n"), worktree: .text("a\nb\n"))
        XCTAssertEqual(facts.eligibility, .selectable)
        XCTAssertEqual(facts.units, [])
        XCTAssertFalse(facts.rows.isEmpty)
        XCTAssertEqual(facts.wholeOnlyReason, .noSelectableChanges)
    }

    func testAFileWithUnitsHasNoWholeOnlyReason() {
        let facts = facts(status: .modified, head: .text("a\n"), worktree: .text("b\n"))
        XCTAssertFalse(facts.units.isEmpty)
        XCTAssertNil(facts.wholeOnlyReason)
    }

    // MARK: - The regression this classification exists for

    func testBinaryInHeadTextInWorktreeIsWholeOnlyNotWhollyAdded() {
        // The original trap: `headContents` returns `String?` whose `nil` means
        // only "absent from HEAD", and stdout is decoded lossily — so a HEAD blob
        // that is binary arrives either as garbage text or as indistinguishable
        // from absence. Under the latter reading the file looked *wholly added*,
        // offering per-line units against a falsely empty old side: selecting a
        // subset would have written a truncated file over binary content.
        let eligibility = FileCommitEligibility.classify(
            status: .modified,
            head: GitBlobText.classify(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x1A])),
            worktree: GitBlobText.classify(Data("line one\nline two\n".utf8))
        )
        XCTAssertEqual(eligibility, .wholeOnly(reason: .binaryInHead))
        let rows = LineDiff.rows(old: "", new: "line one\nline two\n")
        XCTAssertEqual(CommitDiffUnits.selectableUnits(eligibility: eligibility, rows: rows), [])
    }

    // MARK: - selectableUnits

    func testSelectableUnitsAreTheChangedRowIndices() {
        let rows = [
            DiffRow(kind: .unchanged, left: DiffLine(number: 1, text: "a"), right: DiffLine(number: 1, text: "a")),
            DiffRow(kind: .modified, left: DiffLine(number: 2, text: "b"), right: DiffLine(number: 2, text: "B")),
            DiffRow(kind: .removed, left: DiffLine(number: 3, text: "c"), right: nil),
            DiffRow(kind: .added, left: nil, right: DiffLine(number: 3, text: "d")),
            DiffRow(kind: .unchanged, left: DiffLine(number: 4, text: "e"), right: DiffLine(number: 4, text: "e"))
        ]
        XCTAssertEqual(CommitDiffUnits.selectableUnits(rows: rows), [1, 2, 3])
    }

    func testUnchangedRowsAreNotUnits() {
        let rows = LineDiff.rows(old: "a\nb\n", new: "a\nb\n")
        XCTAssertEqual(CommitDiffUnits.selectableUnits(rows: rows), [])
    }

    func testEmptyRowsYieldNoUnits() {
        XCTAssertEqual(CommitDiffUnits.selectableUnits(rows: []), [])
    }

    func testFileDifferingOnlyInLineEndingsYieldsNoUnits() {
        // The boundary recorded in the doc comment: `LineDiff` compares
        // terminator-*stripped* lines, so a CRLF→LF rewrite produces no changed
        // row at all — the file has zero selection units and can therefore only be
        // committed whole.
        let rows = LineDiff.rows(old: "a\r\nb\r\n", new: "a\nb\n")
        XCTAssertEqual(CommitDiffUnits.selectableUnits(rows: rows), [])
    }

    // MARK: - Unified representation

    func testUnifiedContextRemovedAdded() {
        let rows = [
            DiffRow(kind: .unchanged, left: DiffLine(number: 1, text: "a"), right: DiffLine(number: 1, text: "a")),
            DiffRow(kind: .removed, left: DiffLine(number: 2, text: "b"), right: nil),
            DiffRow(kind: .added, left: nil, right: DiffLine(number: 2, text: "c"))
        ]
        XCTAssertEqual(
            CommitDiffUnits.unified(rows: rows),
            [
                UnifiedDiffLine(kind: .context, text: "a", oldNumber: 1, newNumber: 1, unitIndex: nil),
                UnifiedDiffLine(kind: .removed, text: "b", oldNumber: 2, newNumber: nil, unitIndex: 1),
                UnifiedDiffLine(kind: .added, text: "c", oldNumber: nil, newNumber: 2, unitIndex: 2)
            ]
        )
    }

    func testModifiedRowExpandsIntoAPairSharingOneUnitIndex() {
        let rows = [
            DiffRow(kind: .modified, left: DiffLine(number: 7, text: "old"), right: DiffLine(number: 9, text: "new"))
        ]
        let unified = CommitDiffUnits.unified(rows: rows)
        XCTAssertEqual(
            unified,
            [
                UnifiedDiffLine(kind: .removed, text: "old", oldNumber: 7, newNumber: nil, unitIndex: 0),
                UnifiedDiffLine(kind: .added, text: "new", oldNumber: nil, newNumber: 9, unitIndex: 0)
            ]
        )
        XCTAssertEqual(Set(unified.compactMap(\.unitIndex)).count, 1)
    }

    func testUnifiedPreservesRowOrderAndNumbering() {
        let rows = LineDiff.rows(old: "a\nb\nc\n", new: "a\nB\nc\nd\n")
        let unified = CommitDiffUnits.unified(rows: rows)
        XCTAssertEqual(unified.map(\.text), ["a", "b", "B", "c", "d"])
        XCTAssertEqual(unified.map(\.kind), [.context, .removed, .added, .context, .added])
        XCTAssertEqual(unified.map(\.oldNumber), [1, 2, nil, 3, nil])
        XCTAssertEqual(unified.map(\.newNumber), [1, nil, 2, 3, 4])
        // Every unit index the unified view offers is one `selectableUnits` reports,
        // so a checkbox can never name a row that is not a unit.
        XCTAssertEqual(
            Set(unified.compactMap(\.unitIndex)),
            Set(CommitDiffUnits.selectableUnits(rows: rows))
        )
    }

    func testUnifiedOfUnchangedFileIsAllContextWithNoUnits() {
        let rows = LineDiff.rows(old: "a\nb\n", new: "a\nb\n")
        let unified = CommitDiffUnits.unified(rows: rows)
        XCTAssertEqual(unified.map(\.kind), [.context, .context])
        XCTAssertTrue(unified.allSatisfy { $0.unitIndex == nil })
    }

    func testUnifiedOfEmptyRowsIsEmpty() {
        XCTAssertEqual(CommitDiffUnits.unified(rows: []), [])
    }

    /// A row missing the side its kind requires — which `LineDiff` never produces,
    /// so only a hand-built row or a future refactor can reach it — contributes
    /// nothing rather than trapping. The well-formed rows around it still come
    /// through, and their unit indices stay the *row* indices they always were.
    func testUnifiedSkipsMalformedRowsWithoutTrapping() {
        let line = DiffLine(number: 1, text: "x")
        let malformed: [DiffRow] = [
            DiffRow(kind: .unchanged, left: line, right: nil),
            DiffRow(kind: .unchanged, left: nil, right: line),
            DiffRow(kind: .removed, left: nil, right: nil),
            DiffRow(kind: .added, left: nil, right: nil),
            DiffRow(kind: .modified, left: nil, right: nil)
        ]
        XCTAssertEqual(CommitDiffUnits.unified(rows: malformed), [])

        // One half of a `.modified` row present: only that half is emitted, and it
        // keeps the row's own index as its unit.
        let halfRemoved = [DiffRow(kind: .modified, left: line, right: nil)]
        XCTAssertEqual(CommitDiffUnits.unified(rows: halfRemoved).map(\.kind), [.removed])
        let halfAdded = [DiffRow(kind: .modified, left: nil, right: line)]
        XCTAssertEqual(CommitDiffUnits.unified(rows: halfAdded).map(\.kind), [.added])

        let mixed: [DiffRow] = [
            DiffRow(kind: .removed, left: nil, right: nil),
            DiffRow(kind: .added, left: nil, right: line)
        ]
        let unified = CommitDiffUnits.unified(rows: mixed)
        XCTAssertEqual(unified.map(\.kind), [.added])
        XCTAssertEqual(unified.map(\.unitIndex), [1])
    }
}
