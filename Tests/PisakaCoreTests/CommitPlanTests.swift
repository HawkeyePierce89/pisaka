import XCTest
@testable import PisakaCore

final class CommitPlanTests: XCTestCase {

    // MARK: - Helpers

    private func selection(
        path: String,
        status: FileStatus,
        oldPath: String? = nil,
        head: BlobText,
        worktree: BlobText,
        selectedUnits: Set<Int>? = nil,
        isChecked: Bool = true
    ) -> CommitFileSelection {
        let facts = CommitFileFacts(
            file: ChangedFile(path: path, status: status, oldPath: oldPath),
            head: head,
            worktree: worktree,
            rows: LineDiff.rows(old: head.text ?? "", new: worktree.text ?? "")
        )
        return CommitFileSelection(
            facts: facts,
            selectedUnits: selectedUnits ?? Set(facts.units),
            isChecked: isChecked
        )
    }

    // MARK: - Plan by status

    func testModifiedWholeFileIsAddedFromTheWorktree() {
        let file = selection(
            path: "a.swift",
            status: .modified,
            head: .text("one\ntwo\n"),
            worktree: .text("one\nTWO\n")
        )
        XCTAssertEqual(CommitPlan.build(selections: [file]).entries, [.addFromWorktree(path: "a.swift")])
    }

    func testAddedAndUntrackedWholeFilesAreAddedFromTheWorktree() {
        for status in [FileStatus.added, .untracked] {
            let file = selection(
                path: "new.txt",
                status: status,
                head: .absent,
                worktree: .text("hello\n")
            )
            XCTAssertEqual(
                CommitPlan.build(selections: [file]).entries,
                [.addFromWorktree(path: "new.txt")],
                "status \(status)"
            )
        }
    }

    func testPartialSelectionAssemblesContentWithTheModeFromHEAD() {
        // Two changed lines, only the first checked: the committed content is HEAD
        // with that one change applied, and the file's mode comes from the entry
        // that already exists in HEAD.
        let head = "one\ntwo\nthree\n"
        let worktree = "ONE\ntwo\nTHREE\n"
        let rows = LineDiff.rows(old: head, new: worktree)
        let units = CommitDiffUnits.selectableUnits(rows: rows)
        XCTAssertEqual(units.count, 2)
        let file = selection(
            path: "a.swift",
            status: .modified,
            head: .text(head),
            worktree: .text(worktree),
            selectedUnits: [units[0]]
        )
        XCTAssertEqual(
            CommitPlan.build(selections: [file]).entries,
            [.addContent(
                path: "a.swift",
                content: "ONE\ntwo\nthree\n",
                modeSource: .head(path: "a.swift")
            )]
        )
    }

    func testPartialSelectionOfAnUntrackedFileTakesTheModeFromTheWorktree() {
        // Nothing exists at this path in HEAD, so there is no recorded mode to
        // reuse — the working file's own mode is the only source.
        let worktree = "one\ntwo\n"
        let rows = LineDiff.rows(old: "", new: worktree)
        let units = CommitDiffUnits.selectableUnits(rows: rows)
        XCTAssertEqual(units.count, 2)
        let file = selection(
            path: "new.txt",
            status: .untracked,
            head: .absent,
            worktree: .text(worktree),
            selectedUnits: [units[0]]
        )
        XCTAssertEqual(
            CommitPlan.build(selections: [file]).entries,
            [.addContent(path: "new.txt", content: "one\n", modeSource: .worktree(path: "new.txt"))]
        )
    }

    func testDeletedFileRemovesThePath() {
        let file = selection(
            path: "gone.txt",
            status: .deleted,
            head: .text("one\n"),
            worktree: .absent
        )
        XCTAssertEqual(CommitPlan.build(selections: [file]).entries, [.removePath(path: "gone.txt")])
    }

    func testRenamedWholeFileRemovesTheOldPathAndAddsTheNewOne() {
        let file = selection(
            path: "new/name.swift",
            status: .renamed,
            oldPath: "old/name.swift",
            head: .text("one\n"),
            worktree: .text("one\ntwo\n")
        )
        XCTAssertEqual(
            CommitPlan.build(selections: [file]).entries,
            [.removePath(path: "old/name.swift"), .addFromWorktree(path: "new/name.swift")]
        )
    }

    /// A degenerate `.renamed` record whose old path *is* its new path emits no
    /// removal. Without the guard the plan would be a self-cancelling
    /// `.removePath(p)` followed by `.addFromWorktree(p)`, whose net effect
    /// depends on the order `update-index` happens to apply them in.
    func testARenameToItsOwnPathRemovesNothing() {
        let file = selection(
            path: "same.swift",
            status: .renamed,
            oldPath: "same.swift",
            head: .text("one\n"),
            worktree: .text("one\ntwo\n")
        )
        XCTAssertEqual(
            CommitPlan.build(selections: [file]).entries,
            [.addFromWorktree(path: "same.swift")]
        )
    }

    func testRenamedPartialFileRemovesTheOldPathAndAddsAssembledContentWithTheOldPathMode() {
        let head = "one\ntwo\n"
        let worktree = "one\nTWO\nthree\n"
        let rows = LineDiff.rows(old: head, new: worktree)
        let units = CommitDiffUnits.selectableUnits(rows: rows)
        XCTAssertEqual(units.count, 2)
        let file = selection(
            path: "new/name.swift",
            status: .renamed,
            oldPath: "old/name.swift",
            head: .text(head),
            worktree: .text(worktree),
            selectedUnits: [units[1]]
        )
        XCTAssertEqual(
            CommitPlan.build(selections: [file]).entries,
            [
                .removePath(path: "old/name.swift"),
                .addContent(
                    path: "new/name.swift",
                    content: "one\ntwo\nthree\n",
                    // The mode git already records lives at the *old* path — the new
                    // one does not exist in HEAD at all.
                    modeSource: .head(path: "old/name.swift")
                )
            ]
        )
    }

    // MARK: - The two structural boundaries

    func testFileWithZeroSelectedUnitsDropsOutOfThePlanEntirely() {
        // "Nothing selected = HEAD" is structural: the path never enters the
        // temporary index, so no assembled content can be wrong about it.
        let file = selection(
            path: "a.swift",
            status: .modified,
            head: .text("one\ntwo\n"),
            worktree: .text("one\nTWO\n"),
            selectedUnits: []
        )
        XCTAssertTrue(CommitPlan.build(selections: [file]).isEmpty)
    }

    func testFileWithZeroSelectedUnitsDropsOutEvenWhenTheCheckboxSaysOtherwise() {
        // For a file that *has* units the units are the single source of truth;
        // a stale `isChecked` can never smuggle it into the plan.
        let file = selection(
            path: "a.swift",
            status: .modified,
            head: .text("one\ntwo\n"),
            worktree: .text("one\nTWO\n"),
            selectedUnits: [],
            isChecked: true
        )
        XCTAssertTrue(CommitPlan.build(selections: [file]).isEmpty)
    }

    func testFullySelectedFileIsAddedFromTheWorktreeRatherThanThroughTheBuilder() {
        // The other boundary, and the reason it is stated structurally: under mixed
        // line endings the builder's output is deliberately *not* the worktree
        // (`PartialCommitBuilder`'s documented counterexample), so a fully checked
        // file must bypass it and let git place the working file's own bytes.
        let head = "one\r\ntwo\r\n"
        let worktree = "one\r\nTWO\n"
        let rows = LineDiff.rows(old: head, new: worktree)
        let units = CommitDiffUnits.selectableUnits(rows: rows)
        XCTAssertEqual(units.count, 1)
        let assembled = PartialCommitBuilder.assemble(
            head: head,
            worktree: worktree,
            rows: rows,
            selectedUnits: Set(units)
        )
        XCTAssertEqual(assembled, worktree, "the builder happens to agree here")

        let file = selection(
            path: "a.swift",
            status: .modified,
            head: .text(head),
            worktree: .text(worktree),
            selectedUnits: Set(units)
        )
        XCTAssertEqual(CommitPlan.build(selections: [file]).entries, [.addFromWorktree(path: "a.swift")])
    }

    func testFullySelectedFileBypassesTheBuilderWhereTheirResultsDiverge() {
        // The same rule where it actually bites: an *unchanged* line whose
        // terminator switched is no unit at all, so the builder keeps the old
        // terminator and its result differs from the worktree. The plan must not
        // go through it.
        let head = "one\r\ntwo\r\n"
        let worktree = "one\nTWO\n"
        let rows = LineDiff.rows(old: head, new: worktree)
        let units = CommitDiffUnits.selectableUnits(rows: rows)
        let assembled = PartialCommitBuilder.assemble(
            head: head,
            worktree: worktree,
            rows: rows,
            selectedUnits: Set(units)
        )
        XCTAssertNotEqual(assembled, worktree, "the divergence this test is about")

        let file = selection(
            path: "a.swift",
            status: .modified,
            head: .text(head),
            worktree: .text(worktree),
            selectedUnits: Set(units)
        )
        XCTAssertEqual(CommitPlan.build(selections: [file]).entries, [.addFromWorktree(path: "a.swift")])
    }

    // MARK: - Whole-only files

    func testBinaryFileEntersThePlanWholeOnly() {
        let file = selection(
            path: "image.png",
            status: .modified,
            head: .binary,
            worktree: .binary,
            isChecked: true
        )
        let entries = CommitPlan.build(selections: [file]).entries
        XCTAssertEqual(entries, [.addFromWorktree(path: "image.png")])
        XCTAssertFalse(entries.contains { if case .addContent = $0 { return true } else { return false } })
    }

    func testBinaryInHeadTextInWorktreeEntersThePlanWholeOnly() {
        // The regression `FileCommitEligibility` exists for, carried through to the
        // plan: no assembled content is ever produced for such a file.
        let file = selection(
            path: "blob.bin",
            status: .modified,
            head: .binary,
            worktree: .text("one\ntwo\n"),
            isChecked: true
        )
        XCTAssertEqual(
            CommitPlan.build(selections: [file]).entries,
            [.addFromWorktree(path: "blob.bin")]
        )
    }

    func testDeletedBinaryFileEntersThePlanAsARemoval() {
        let file = selection(
            path: "image.png",
            status: .deleted,
            head: .binary,
            worktree: .absent,
            isChecked: true
        )
        XCTAssertEqual(CommitPlan.build(selections: [file]).entries, [.removePath(path: "image.png")])
    }

    func testUncheckedWholeOnlyFileDropsOutOfThePlan() {
        let file = selection(
            path: "image.png",
            status: .modified,
            head: .binary,
            worktree: .binary,
            isChecked: false
        )
        XCTAssertTrue(CommitPlan.build(selections: [file]).isEmpty)
    }

    func testFileDifferingOnlyInLineEndingsIsCommittedWholeByItsCheckbox() {
        // `.selectable` yet with zero units: the third "whole only" category. It is
        // included by the file checkbox alone and, having no units, is placed from
        // the worktree — which is what makes committing it preserve its bytes.
        let file = selection(
            path: "a.swift",
            status: .modified,
            head: .text("one\r\ntwo\r\n"),
            worktree: .text("one\ntwo\n"),
            isChecked: true
        )
        XCTAssertEqual(
            CommitDiffUnits.selectableUnits(eligibility: .selectable, rows: file.rows),
            []
        )
        XCTAssertEqual(CommitPlan.build(selections: [file]).entries, [.addFromWorktree(path: "a.swift")])
    }

    // MARK: - Batch shape

    func testPlanPreservesInputOrderAndSkipsUnselectedFiles() {
        let first = selection(path: "a.txt", status: .modified, head: .text("a\n"), worktree: .text("A\n"))
        let skipped = selection(
            path: "b.txt",
            status: .modified,
            head: .text("b\n"),
            worktree: .text("B\n"),
            selectedUnits: []
        )
        let last = selection(path: "c.txt", status: .deleted, head: .text("c\n"), worktree: .absent)
        XCTAssertEqual(
            CommitPlan.build(selections: [first, skipped, last]).entries,
            [.addFromWorktree(path: "a.txt"), .removePath(path: "c.txt")]
        )
    }

    func testEmptySelectionsYieldAnEmptyPlan() {
        XCTAssertTrue(CommitPlan.build(selections: []).isEmpty)
    }

    func testStaleUnitIndicesAreIgnoredRatherThanTrapping() {
        // A selection set can name a row that no longer exists (or an unchanged
        // one); the plan degrades to "the units that are real" instead of crashing —
        // catching the divergence is `CommitStaleness`' job.
        let file = selection(
            path: "a.swift",
            status: .modified,
            head: .text("one\ntwo\n"),
            worktree: .text("one\nTWO\n"),
            selectedUnits: [0, 99]
        )
        // Row 0 is unchanged context, 99 names nothing: no real unit is selected.
        XCTAssertTrue(CommitPlan.build(selections: [file]).isEmpty)
    }

    // MARK: - Checkbox state

    func testCheckboxIsCheckedWhenEveryUnitIsSelected() {
        let file = selection(
            path: "a.swift",
            status: .modified,
            head: .text("one\ntwo\n"),
            worktree: .text("ONE\nTWO\n")
        )
        XCTAssertEqual(CheckboxState.of(file), .checked)
    }

    func testCheckboxIsMixedWhenSomeUnitsAreSelected() {
        let head = "one\ntwo\n"
        let worktree = "ONE\nTWO\n"
        let units = CommitDiffUnits.selectableUnits(rows: LineDiff.rows(old: head, new: worktree))
        XCTAssertEqual(units.count, 2)
        let file = selection(
            path: "a.swift",
            status: .modified,
            head: .text(head),
            worktree: .text(worktree),
            selectedUnits: [units[0]]
        )
        XCTAssertEqual(CheckboxState.of(file), .mixed)
    }

    func testCheckboxIsUncheckedWhenNoUnitIsSelected() {
        let file = selection(
            path: "a.swift",
            status: .modified,
            head: .text("one\ntwo\n"),
            worktree: .text("ONE\nTWO\n"),
            selectedUnits: []
        )
        XCTAssertEqual(CheckboxState.of(file), .unchecked)
    }

    func testWholeOnlyFileWithZeroUnitsIsCheckedNotMixed() {
        // The rule the dialog depends on: a binary/deleted file's checkbox is an
        // ordinary two-state one. "Mixed" would claim a partial selection that
        // cannot exist.
        let checked = selection(
            path: "image.png",
            status: .modified,
            head: .binary,
            worktree: .binary,
            isChecked: true
        )
        XCTAssertEqual(CheckboxState.of(checked), .checked)

        let unchecked = selection(
            path: "image.png",
            status: .modified,
            head: .binary,
            worktree: .binary,
            isChecked: false
        )
        XCTAssertEqual(CheckboxState.of(unchecked), .unchecked)
    }

    func testCheckboxOfAZeroUnitSelectableFileIsAlsoTwoState() {
        let file = selection(
            path: "a.swift",
            status: .modified,
            head: .text("one\r\n"),
            worktree: .text("one\n"),
            isChecked: true
        )
        XCTAssertEqual(CheckboxState.of(file), .checked)
    }

    func testCheckboxIgnoresStaleUnitIndices() {
        let file = selection(
            path: "a.swift",
            status: .modified,
            head: .text("one\ntwo\n"),
            worktree: .text("one\nTWO\n"),
            selectedUnits: [0, 99]
        )
        XCTAssertEqual(CheckboxState.of(file), .unchecked)
    }

    // MARK: - Staleness

    private func facts(_ selection: CommitFileSelection) -> CommitFileFacts { selection.facts }

    func testMatchingSnapshotProceeds() {
        let a = selection(path: "a.txt", status: .modified, head: .text("a\n"), worktree: .text("A\n"))
        let b = selection(path: "b.txt", status: .deleted, head: .text("b\n"), worktree: .absent)
        XCTAssertNil(CommitStaleness.check(planned: [a, b], current: [facts(a), facts(b)]))
    }

    func testCurrentMayCarryFilesThePlanDoesNotTouch() {
        let a = selection(path: "a.txt", status: .modified, head: .text("a\n"), worktree: .text("A\n"))
        let other = selection(path: "z.txt", status: .modified, head: .text("z\n"), worktree: .text("Z\n"))
        XCTAssertNil(CommitStaleness.check(planned: [a], current: [other.facts, a.facts]))
    }

    func testVanishedFileAborts() {
        let a = selection(path: "a.txt", status: .modified, head: .text("a\n"), worktree: .text("A\n"))
        XCTAssertEqual(CommitStaleness.check(planned: [a], current: []), .vanished(path: "a.txt"))
    }

    func testChangedStatusAborts() {
        let a = selection(path: "a.txt", status: .untracked, head: .absent, worktree: .text("A\n"))
        let now = selection(path: "a.txt", status: .added, head: .absent, worktree: .text("A\n"))
        XCTAssertEqual(
            CommitStaleness.check(planned: [a], current: [now.facts]),
            .statusChanged(path: "a.txt")
        )
    }

    func testChangedOldPathAborts() {
        let a = selection(
            path: "new.txt",
            status: .renamed,
            oldPath: "old.txt",
            head: .text("a\n"),
            worktree: .text("A\n")
        )
        let now = selection(
            path: "new.txt",
            status: .renamed,
            oldPath: "other.txt",
            head: .text("a\n"),
            worktree: .text("A\n")
        )
        XCTAssertEqual(
            CommitStaleness.check(planned: [a], current: [now.facts]),
            .renameChanged(path: "new.txt")
        )
    }

    func testChangedDiffAborts() {
        let a = selection(path: "a.txt", status: .modified, head: .text("a\n"), worktree: .text("A\n"))
        let now = selection(path: "a.txt", status: .modified, head: .text("a\n"), worktree: .text("A\nB\n"))
        XCTAssertEqual(
            CommitStaleness.check(planned: [a], current: [now.facts]),
            .diffChanged(path: "a.txt")
        )
    }

    func testSideBecomingBinaryAborts() {
        let a = selection(path: "a.txt", status: .modified, head: .text("a\n"), worktree: .text("A\n"))
        let now = selection(path: "a.txt", status: .modified, head: .text("a\n"), worktree: .binary)
        XCTAssertEqual(
            CommitStaleness.check(planned: [a], current: [now.facts]),
            .contentKindChanged(path: "a.txt")
        )
    }

    func testHeadSideBecomingAbsentAborts() {
        let a = selection(path: "a.txt", status: .modified, head: .text("a\n"), worktree: .text("A\n"))
        let now = selection(path: "a.txt", status: .modified, head: .absent, worktree: .text("A\n"))
        XCTAssertEqual(
            CommitStaleness.check(planned: [a], current: [now.facts]),
            .contentKindChanged(path: "a.txt")
        )
    }

    func testOneDivergingFileAbortsTheWholeBatchAndNamesThatPath() {
        // The abort is a property of the batch, not of the file: the caller gets a
        // single reason and commits nothing at all, so a plan is never applied
        // half-way.
        let clean = selection(path: "a.txt", status: .modified, head: .text("a\n"), worktree: .text("A\n"))
        let stale = selection(path: "b.txt", status: .modified, head: .text("b\n"), worktree: .text("B\n"))
        let staleNow = selection(path: "b.txt", status: .modified, head: .text("b\n"), worktree: .text("BB\n"))
        let reason = CommitStaleness.check(
            planned: [clean, stale],
            current: [clean.facts, staleNow.facts]
        )
        XCTAssertEqual(reason, .diffChanged(path: "b.txt"))
        XCTAssertEqual(reason?.path, "b.txt")
        XCTAssertTrue(reason?.message.contains("b.txt") ?? false)
    }

    /// Every case, `.headMoved` included: it is the one abort the user has no
    /// other way to diagnose, so an empty explanation there is the worst of the
    /// six. It is also the only one that names no path — it is a fact about the
    /// repository — which is what `path` reports and what this pins.
    func testEveryStaleReasonCarriesDistinctNonEmptyText() {
        let pathReasons: [CommitStaleReason] = [
            .vanished(path: "p"),
            .statusChanged(path: "p"),
            .renameChanged(path: "p"),
            .contentKindChanged(path: "p"),
            .diffChanged(path: "p")
        ]
        let reasons = pathReasons + [.headMoved]
        let messages = reasons.map(\.message)
        XCTAssertEqual(Set(messages).count, reasons.count)
        for message in messages {
            XCTAssertFalse(message.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        for reason in pathReasons {
            XCTAssertEqual(reason.path, "p")
            XCTAssertTrue(reason.message.contains("p"))
        }
        XCTAssertNil(CommitStaleReason.headMoved.path)
        XCTAssertFalse(
            CommitStaleReason.headMoved.message
                .trimmingCharacters(in: .whitespaces).isEmpty
        )
    }

    func testCheckPassesWhenOnlyTerminatorsMovedAndTheRebuiltPlanUsesTheFreshBytes() {
        // The check compares the *decisions* (status, rename, text-or-not, rows),
        // deliberately not raw bytes — which is why it is paired with rebuilding the
        // plan onto the fresh facts: a line-ending-only rewrite of the worktree
        // passes the check, and the content committed is then assembled from the
        // bytes that are on disk now, not from the snapshot's.
        let head = "one\ntwo\n"
        let planned = selection(
            path: "a.swift",
            status: .modified,
            head: .text(head),
            worktree: .text("one\nTWO\nthree\n"),
            selectedUnits: [2]
        )
        let fresh = selection(
            path: "a.swift",
            status: .modified,
            head: .text(head),
            worktree: .text("one\r\nTWO\r\nthree\r\n")
        ).facts
        XCTAssertNil(CommitStaleness.check(planned: [planned], current: [fresh]))

        XCTAssertEqual(
            CommitPlan.build(selections: [planned.withFacts(fresh)]).entries,
            [.addContent(
                path: "a.swift",
                content: "one\ntwo\nthree\r\n",
                modeSource: .head(path: "a.swift")
            )]
        )
    }

    func testWithFactsKeepsTheSelectionAndReplacesTheFacts() {
        let planned = selection(
            path: "a.swift",
            status: .modified,
            head: .text("one\ntwo\n"),
            worktree: .text("ONE\ntwo\n"),
            selectedUnits: [1],
            isChecked: false
        )
        let fresh = selection(
            path: "a.swift",
            status: .modified,
            head: .text("one\ntwo\n"),
            worktree: .text("ONE\nTWO\n")
        ).facts
        let rebased = planned.withFacts(fresh)
        XCTAssertEqual(rebased.selectedUnits, [1])
        XCTAssertFalse(rebased.isChecked)
        XCTAssertEqual(rebased.facts, fresh)
    }
    /// `git status` emits one record per path, so a duplicate is not something
    /// the check meets in practice — but the tie-break still has to be *pinned*,
    /// because `CommitDialogModel.commit` rebuilds the plan through a second
    /// lookup over the same array. If the two disagreed, the check would validate
    /// one set of rows and the commit would then assemble a different one: the
    /// exact "a checked line becomes a different line" mistake `CommitStaleness`
    /// exists to stop, reintroduced through the back door. Both go through
    /// `indexed(_:)`, and **last wins**.
    func testDuplicatePathsResolveToTheLastEntryInBothLookups() {
        let planned = selection(
            path: "a.swift",
            status: .modified,
            head: .text("one\n"),
            worktree: .text("ONE\n")
        )
        let stale = facts(planned)
        let current = CommitFileFacts(
            file: ChangedFile(path: "a.swift", status: .modified),
            head: .text("one\n"),
            worktree: .text("SOMETHING ELSE\n"),
            rows: LineDiff.rows(old: "one\n", new: "SOMETHING ELSE\n")
        )

        XCTAssertEqual(CommitStaleness.indexed([stale, current])["a.swift"], current)
        // …and the check agrees with it: judged against the *last* entry, whose
        // rows differ from the plan's, this is stale.
        XCTAssertEqual(
            CommitStaleness.check(planned: [planned], current: [stale, current]),
            .diffChanged(path: "a.swift")
        )
    }
}
