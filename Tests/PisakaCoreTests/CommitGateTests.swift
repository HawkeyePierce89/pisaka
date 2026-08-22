import XCTest
@testable import PisakaCore

/// Covers `InProgressOperation.detect(markerNames:)` (which lives in
/// `CommitContext.swift` but exists only to feed the gate) and
/// `CommitGate.evaluate(...)`.
final class CommitGateTests: XCTestCase {

    // MARK: - Helpers

    private func context(
        unborn: Bool = false,
        detached: Bool = false,
        branch: String? = "master",
        upstream: String? = "origin/master",
        remotes: [String] = ["origin"],
        inProgress: InProgressOperation? = nil
    ) -> CommitContext {
        CommitContext(
            isUnbornHEAD: unborn,
            isDetachedHEAD: detached,
            currentBranch: branch,
            upstream: upstream,
            remotes: remotes,
            inProgress: inProgress
        )
    }

    private var completeIdentity: CommitIdentity {
        CommitIdentity(
            name: "Anton Karmanov",
            email: "anton@work.example",
            nameSource: .local,
            emailSource: .local
        )
    }

    private func evaluate(
        context ctx: CommitContext? = nil,
        identity: CommitIdentity? = nil,
        message: String = "Fix the thing",
        selectedFileCount: Int = 1,
        amend: Bool = false,
        conflictedPaths: [String] = [],
        isRunning: Bool = false,
        isWritingIdentity: Bool = false
    ) -> CommitBlock? {
        CommitGate.evaluate(
            context: ctx ?? context(),
            identity: identity ?? completeIdentity,
            message: message,
            selectedFileCount: selectedFileCount,
            amend: amend,
            conflictedPaths: conflictedPaths,
            isRunning: isRunning,
            isWritingIdentity: isWritingIdentity
        )
    }

    // MARK: - InProgressOperation.detect

    func testDetectMergeHead() {
        XCTAssertEqual(InProgressOperation.detect(markerNames: ["MERGE_HEAD"]), .merge)
    }

    func testDetectCherryPickHead() {
        XCTAssertEqual(InProgressOperation.detect(markerNames: ["CHERRY_PICK_HEAD"]), .cherryPick)
    }

    func testDetectRevertHead() {
        XCTAssertEqual(InProgressOperation.detect(markerNames: ["REVERT_HEAD"]), .revert)
    }

    func testDetectRebaseMerge() {
        XCTAssertEqual(InProgressOperation.detect(markerNames: ["rebase-merge"]), .rebase)
    }

    func testDetectRebaseApply() {
        XCTAssertEqual(InProgressOperation.detect(markerNames: ["rebase-apply"]), .rebase)
    }

    func testDetectEmptyIsNil() {
        XCTAssertNil(InProgressOperation.detect(markerNames: []))
    }

    func testDetectIgnoresUnrelatedEntries() {
        // The caller lists the whole git dir, so the ordinary contents must not
        // be mistaken for an operation in progress.
        let names = ["HEAD", "config", "objects", "refs", "index", "COMMIT_EDITMSG", "hooks"]
        XCTAssertNil(InProgressOperation.detect(markerNames: names))
    }

    func testDetectIsCaseSensitive() {
        // git writes these names exactly; a lowercase `merge_head` is a file the
        // user happens to have, not an operation in progress.
        XCTAssertNil(InProgressOperation.detect(markerNames: ["merge_head"]))
    }

    func testDetectPrefersRebaseWhenSeveralMarkersArePresent() {
        // A rebase that stopped on a conflicting patch leaves both a rebase
        // directory and (for a merge-strategy rebase) other markers; git's own
        // status reports the rebase, so the block names the rebase too.
        let operation = InProgressOperation.detect(
            markerNames: ["MERGE_HEAD", "rebase-apply", "REVERT_HEAD"]
        )
        XCTAssertEqual(operation, .rebase)
    }

    func testDisplayNames() {
        XCTAssertEqual(InProgressOperation.merge.displayName, "merge")
        XCTAssertEqual(InProgressOperation.cherryPick.displayName, "cherry-pick")
        XCTAssertEqual(InProgressOperation.revert.displayName, "revert")
        XCTAssertEqual(InProgressOperation.rebase.displayName, "rebase")
    }

    // MARK: - The allowing case

    func testNothingBlocksAnOrdinaryCommit() {
        XCTAssertNil(evaluate())
    }

    // MARK: - Each reason, separately

    func testNoRepositoryBlocks() {
        let block = CommitGate.evaluate(
            context: nil,
            identity: completeIdentity,
            message: "Fix the thing",
            selectedFileCount: 1,
            amend: false,
            conflictedPaths: [],
            isRunning: false,
            isWritingIdentity: false
        )
        XCTAssertEqual(block, .noRepository)
        XCTAssertEqual(block?.message, "This folder is not a git repository.")
    }

    func testUnsetIdentityBlocks() {
        let identity = CommitIdentity.resolve(
            localName: nil,
            localEmail: nil,
            effectiveName: nil,
            effectiveEmail: nil
        )
        let block = evaluate(identity: identity)
        XCTAssertEqual(block, .identityIncomplete)
        XCTAssertEqual(block?.message, "Set the commit author’s name and email first.")
    }

    func testPartiallyUnsetIdentityBlocks() {
        let identity = CommitIdentity.resolve(
            localName: nil,
            localEmail: nil,
            effectiveName: "Anton Karmanov",
            effectiveEmail: nil
        )
        XCTAssertEqual(evaluate(identity: identity), .identityIncomplete)
    }

    func testEmptyMessageBlocks() {
        let block = evaluate(message: "")
        XCTAssertEqual(block, .emptyMessage)
        XCTAssertEqual(block?.message, "Enter a commit message.")
    }

    func testWhitespaceOnlyMessageBlocks() {
        XCTAssertEqual(evaluate(message: "   \n\t "), .emptyMessage)
    }

    func testNonAmendWithNothingSelectedBlocks() {
        let block = evaluate(selectedFileCount: 0)
        XCTAssertEqual(block, .nothingSelected)
        XCTAssertEqual(block?.message, "Select at least one file or line to commit.")
    }

    func testConflictedFileBlocks() {
        let block = evaluate(conflictedPaths: ["src/app.swift"])
        XCTAssertEqual(block, .conflictedFiles(["src/app.swift"]))
        XCTAssertEqual(block?.message, "Resolve the conflict in “src/app.swift” first.")
    }

    func testSeveralConflictedFilesBlockWithACount() {
        let block = evaluate(conflictedPaths: ["a.swift", "b.swift", "c.swift"])
        XCTAssertEqual(block, .conflictedFiles(["a.swift", "b.swift", "c.swift"]))
        XCTAssertEqual(block?.message, "Resolve all 3 conflicts first.")
    }

    func testConflictedFileBlocksEvenWhenItIsNotSelected() {
        // The temporary index is seeded from HEAD, so git's own "you have
        // unmerged files" refusal never fires: an unresolved conflict anywhere in
        // the repository must be blocked here regardless of what is checked.
        let block = evaluate(selectedFileCount: 1, conflictedPaths: ["other.swift"])
        XCTAssertEqual(block, .conflictedFiles(["other.swift"]))
    }

    func testMergeInProgressBlocks() {
        let block = evaluate(context: context(inProgress: .merge))
        XCTAssertEqual(block, .operationInProgress(.merge))
        XCTAssertEqual(
            block?.message,
            "A merge is in progress — finish it from the terminal before committing."
        )
    }

    func testCherryPickInProgressBlocks() {
        let block = evaluate(context: context(inProgress: .cherryPick))
        XCTAssertEqual(block, .operationInProgress(.cherryPick))
        XCTAssertEqual(
            block?.message,
            "A cherry-pick is in progress — finish it from the terminal before committing."
        )
    }

    func testRevertInProgressBlocks() {
        let block = evaluate(context: context(inProgress: .revert))
        XCTAssertEqual(block, .operationInProgress(.revert))
    }

    func testRebaseInProgressBlocks() {
        let block = evaluate(context: context(inProgress: .rebase))
        XCTAssertEqual(block, .operationInProgress(.rebase))
    }

    func testAmendDuringAnOperationIsBlockedToo() {
        // The in-progress block subsumes "amend unavailable during a merge":
        // there is one rule, not two, so an amend cannot slip past it.
        let block = evaluate(context: context(inProgress: .merge), amend: true)
        XCTAssertEqual(block, .operationInProgress(.merge))
    }

    func testCommitAlreadyRunningBlocks() {
        let block = evaluate(isRunning: true)
        XCTAssertEqual(block, .alreadyRunning)
        XCTAssertEqual(block?.message, "A commit is already in progress.")
    }

    /// The author editor dismisses on Save while its two `git config --local`
    /// writes are still queued, so an ungated Commit in that window records the old
    /// identity — or the new name beside the old email, between the two writes.
    func testIdentityWriteInProgressBlocks() {
        let block = evaluate(isWritingIdentity: true)
        XCTAssertEqual(block, .identityWriteInProgress)
        XCTAssertEqual(block?.message, "Saving the commit author…")
    }

    /// The identity being *rewritten* blocks even though the identity currently
    /// held is complete: the point is that it is about to stop being the one git
    /// would record.
    func testIdentityWriteBlocksEvenWithACompleteIdentity() {
        XCTAssertEqual(evaluate(identity: completeIdentity, isWritingIdentity: true),
                       .identityWriteInProgress)
    }

    // MARK: - Amend

    func testAmendWithNoFilesSelectedIsLegal() {
        // A message-only amend touches no file at all.
        XCTAssertNil(evaluate(selectedFileCount: 0, amend: true))
    }

    func testAmendStillNeedsAMessage() {
        XCTAssertEqual(evaluate(message: " ", selectedFileCount: 0, amend: true), .emptyMessage)
    }

    func testAmendOnUnbornHEADIsUnavailable() {
        let block = evaluate(context: context(unborn: true, upstream: nil), amend: true)
        XCTAssertEqual(block, .amendOnUnbornHEAD)
        XCTAssertEqual(block?.message, "There is no commit to amend yet.")
    }

    func testUnbornHEADWithoutAmendIsFine() {
        XCTAssertNil(evaluate(context: context(unborn: true, upstream: nil)))
    }

    // MARK: - Precedence

    func testRepositoryLevelBlocksWinOverDialogLevelOnes() {
        // The order is deliberate: the user can fix the message or the selection
        // in the dialog, but an in-progress operation or an unresolved conflict
        // has to be dealt with outside it, so those are named first.
        let block = evaluate(
            context: context(inProgress: .rebase),
            identity: CommitIdentity.resolve(
                localName: nil, localEmail: nil, effectiveName: nil, effectiveEmail: nil
            ),
            message: "",
            selectedFileCount: 0,
            conflictedPaths: ["a.swift"]
        )
        XCTAssertEqual(block, .operationInProgress(.rebase))
    }

    func testRunningCommitWinsOverEverythingButAMissingRepository() {
        let block = evaluate(
            context: context(inProgress: .merge),
            message: "",
            selectedFileCount: 0,
            isRunning: true
        )
        XCTAssertEqual(block, .alreadyRunning)
    }

    func testConflictWinsOverMessageAndSelection() {
        let block = evaluate(
            message: "",
            selectedFileCount: 0,
            conflictedPaths: ["a.swift"]
        )
        XCTAssertEqual(block, .conflictedFiles(["a.swift"]))
    }

    func testIdentityWinsOverMessageAndSelection() {
        let identity = CommitIdentity.resolve(
            localName: nil, localEmail: nil, effectiveName: nil, effectiveEmail: nil
        )
        XCTAssertEqual(evaluate(identity: identity, message: "", selectedFileCount: 0),
                       .identityIncomplete)
    }

    // MARK: - Messages are never empty

    func testEveryBlockCarriesText() {
        let blocks: [CommitBlock] = [
            .noRepository,
            .alreadyRunning,
            .identityWriteInProgress,
            .operationInProgress(.merge),
            .operationInProgress(.cherryPick),
            .operationInProgress(.revert),
            .operationInProgress(.rebase),
            .amendOnUnbornHEAD,
            .conflictedFiles(["a.swift"]),
            .conflictedFiles(["a.swift", "b.swift"]),
            .identityIncomplete,
            .emptyMessage,
            .nothingSelected,
        ]
        for block in blocks {
            XCTAssertFalse(
                block.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(block) has no message"
            )
        }
    }
}
