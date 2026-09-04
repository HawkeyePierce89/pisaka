import XCTest
@testable import PisakaCore

/// The model's half of the merge — the feature's third write (G13).
///
/// Four properties carry the suite, and each is a rule that fails silently if it
/// breaks:
///
/// - **Nothing is sent until every refusal has been asked.** The gate, the
///   one-write flag, the row still being in the list and the plan re-deciding as
///   mergeable are all asserted as "no `pr merge` reached the transport" rather
///   than as a returned `nil`, which is the pair that catches a guard asked one
///   line too late.
/// - **The command carries the row's own head.** `--match-head-commit` is the
///   whole guard against merging something other than what was read, so the
///   argument list is asserted byte for byte against the row the plan was
///   decided from.
/// - **The one message slot is scoped.** A merge refusal is readable through
///   ``PullRequestModel/mergeMessage`` and a refresh failure is not, and
///   `dismissMerge()` clears the first without touching the second.
/// - **The outcome names the tail, and only the model decides whether it is
///   owed.** The coordinator that runs the post-merge tail reads this answer and
///   re-derives nothing, so the head/checked-out comparison is asserted here.
///
/// Nothing here runs `gh` and nothing here runs a bracket: every answer comes
/// from `ScriptedGitHubCLI`, keyed by the argument list `GitHubCommands`
/// composes.
@MainActor
final class PullRequestMergeTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/tmp/pisaka-github")

    // MARK: - Stubs

    /// The gate, and a count of how often it was asked.
    private final class WriteGate {
        var isBlocked = false
        var asks = 0

        var question: @MainActor () -> Bool {
            { [self] in
                asks += 1
                return isBlocked
            }
        }
    }

    /// `currentBranch` is the one member the merge flow reaches for — twice: once
    /// as the sheet is prepared, and once as the last read before the command is
    /// composed, which is the whole of the tail decision.
    private final class StubGit: GitServicing {
        var branch: String? = "feature"
        var branchError: Error?
        /// Every `currentBranch` call, so "read again before sending" is a count
        /// rather than a hope.
        var branchReads = 0

        func repositoryRoot(for url: URL) async throws -> URL { url }
        func changedFiles(root: URL) async throws -> [ChangedFile] { [] }
        func commits(filter: LogFilter, limit: Int, root: URL) async throws -> [Commit] { [] }
        func headContents(of path: String, root: URL) async throws -> String? { nil }
        func revert(_ file: ChangedFile, root: URL) async throws {}

        func currentBranch(root: URL) async throws -> BranchRef? {
            branchReads += 1
            if let branchError { throw branchError }
            guard let branch, !branch.isEmpty else { return nil }
            return BranchRef(
                name: "refs/heads/\(branch)",
                isRemote: false,
                remoteName: nil,
                shortName: branch,
                isCurrent: true
            )
        }
    }

    // MARK: - Rows

    /// One open, mergeable pull request whose head is `feature` — the state every
    /// merge starts from, since the button lives on a listed row.
    private static func listJSON(
        number: Int = 54,
        isDraft: Bool = false,
        head: String = "feature",
        base: String = "master",
        oid: String = "abc123",
        mergeable: String = "MERGEABLE",
        mergeState: String = "CLEAN",
        rollup: String = "[]"
    ) -> String {
        """
        [{"number":\(number),"title":"A change","author":{"login":"someone"},
        "headRefName":"\(head)","baseRefName":"\(base)","isDraft":\(isDraft),
        "reviewDecision":"","url":"https://github.com/o/r/pull/\(number)",
        "state":"OPEN","statusCheckRollup":\(rollup),
        "headRefOid":"\(oid)","mergeable":"\(mergeable)","mergeStateStatus":"\(mergeState)"}]
        """
    }

    /// A rollup with one job still running, which is the `checksRunning` refusal
    /// and the one state a wait may be armed from.
    private static let pendingRollup = """
    [{"__typename":"CheckRun","name":"build","workflowName":"CI",
    "status":"IN_PROGRESS","conclusion":"","detailsUrl":"https://x"}]
    """

    /// A rollup with one job that finished red.
    private static let failedRollup = """
    [{"__typename":"CheckRun","name":"build","workflowName":"CI",
    "status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://x"}]
    """

    private static let repositoryJSON = """
    {"nameWithOwner":"o/r","defaultBranchRef":{"name":"master"},
    "mergeCommitAllowed":true,"squashMergeAllowed":true,"rebaseMergeAllowed":true,
    "viewerDefaultMergeMethod":"SQUASH","deleteBranchOnMerge":true}
    """

    /// A repository that allows squash-merging and nothing else.
    private static let squashOnlyJSON = """
    {"nameWithOwner":"o/r","defaultBranchRef":{"name":"master"},
    "mergeCommitAllowed":false,"squashMergeAllowed":true,"rebaseMergeAllowed":false,
    "viewerDefaultMergeMethod":"MERGE","deleteBranchOnMerge":false}
    """

    // MARK: - Model

    private func mergeArguments(
        number: Int = 54,
        method: GitHubMergeMethod = .squash,
        oid: String = "abc123",
        subject: String = "A change (#54)",
        body: String = ""
    ) -> [String] {
        GitHubCommands.mergePullRequest(
            number: number,
            method: method,
            headRefOid: oid,
            subject: subject,
            body: body,
            root: root
        ).arguments
    }

    /// A model that has refreshed against a signed-in `gh` with one open pull
    /// request, and — unless `prepare` says otherwise — has had its merge sheet
    /// prepared over that row.
    private func readyModel(
        _ cli: ScriptedGitHubCLI,
        git: StubGit = StubGit(),
        gate: WriteGate = WriteGate(),
        list: String? = nil,
        repository: String? = nil,
        branch: String = "master",
        prepare: Bool = true
    ) async -> PullRequestModel {
        let root = root
        cli.serveReady()
        cli.serve(GitHubCommands.openPullRequests(root: root), stdout: list ?? Self.listJSON())
        // Every branch a test in this suite stands on: the refresh a merge runs
        // afterwards reads the indicator's row for whatever branch was checked
        // out then, and an unscripted call would fail as a failure.
        for name in [branch, "master", "feature", "some-other-branch"] {
            cli.serve(GitHubCommands.pullRequest(forHeadBranch: name, root: root), stdout: "[]")
        }
        cli.serve(
            GitHubCommands.repositoryView(root: root),
            stdout: repository ?? Self.repositoryJSON
        )
        let model = PullRequestModel(
            transport: cli,
            gitService: git,
            root: { root },
            isWriteBlocked: gate.question
        )
        await model.refresh(branch: branch)
        if prepare { await model.prepareMerge(number: 54) }
        return model
    }

    // MARK: - The sheet's read

    func testPreparingTheSheetPublishesAPlanReadFromRepoViewAndTheCheckedOutBranch() async {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        let model = await readyModel(cli, git: git)

        let plan = model.mergePlan
        XCTAssertEqual(plan?.pullRequest.number, 54)
        XCTAssertEqual(plan?.checkedOutBranch, "feature")
        XCTAssertTrue(plan?.canMerge == true)
        XCTAssertEqual(plan?.defaultMethod, .squash)
        XCTAssertEqual(plan?.allowedMethods, [.merge, .squash, .rebase])
        XCTAssertEqual(plan?.defaultSubject, "A change (#54)")
        XCTAssertNotNil(plan?.deleteBranchSentence)
        // The head *is* the checked-out branch, so the sheet says the tail is owed.
        XCTAssertEqual(plan?.tailSentence, "After merging, Pisaka will switch to “master” and pull it.")
        XCTAssertNil(model.mergeMessage)
        XCTAssertEqual(cli.count(for: GitHubCommands.repositoryView(root: root)), 1)
    }

    func testAFailedRepoViewLeavesNoPlanAndGitHubsOwnWordsInTheSheetsSlot() async {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(GitHubCommands.openPullRequests(root: root), stdout: Self.listJSON())
        cli.serve(GitHubCommands.pullRequest(forHeadBranch: "master", root: root), stdout: "[]")
        cli.serve(
            GitHubCommands.repositoryView(root: root),
            stderr: "could not resolve to a Repository",
            status: 1
        )
        let model = PullRequestModel(transport: cli, gitService: StubGit(), root: { self.root })
        await model.refresh(branch: "master")

        await model.prepareMerge(number: 54)

        XCTAssertNil(model.mergePlan)
        XCTAssertEqual(model.mergeMessage, "could not resolve to a Repository")
    }

    func testAFailedBranchReadStillPublishesAPlanWithNoTailAndSaysWhy() async {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        git.branchError = GitError.gitUnavailable
        let model = await readyModel(cli, git: git)

        XCTAssertNotNil(model.mergePlan)
        XCTAssertTrue(model.mergePlan?.canMerge == true)
        XCTAssertEqual(model.mergePlan?.checkedOutBranch, "")
        XCTAssertNil(model.mergePlan?.tailSentence)
        XCTAssertEqual(model.mergeMessage, GitError.gitUnavailable.errorDescription)
    }

    func testPreparingTheSheetForARowThatIsNotListedPublishesNothingAndSendsNothing() async {
        let cli = ScriptedGitHubCLI()
        let model = await readyModel(cli, prepare: false)

        await model.prepareMerge(number: 999)

        XCTAssertNil(model.mergePlan)
        XCTAssertNil(model.mergeMessage)
        XCTAssertEqual(cli.count(for: GitHubCommands.repositoryView(root: root)), 0)
    }

    /// The fourth token: a sheet read suspended in `repo view` may not publish a
    /// plan over rows that have since been blanked.
    func testASheetReadSupersededByANotReadyRefreshPublishesNothing() async {
        let cli = ScriptedGitHubCLI()
        let gate = Gate()
        let model = await readyModel(cli, prepare: false)
        cli.hold(GitHubCommands.repositoryView(root: root), on: gate)

        let prepared = Task { await model.prepareMerge(number: 54) }
        // The window: `repo view` is suspended, and `gh` signs out behind it.
        await gate.waitUntilReached()
        cli.serve(GitHubCommands.authStatus(), status: 1)
        await model.refresh(branch: "master")
        gate.release()
        await prepared.value

        XCTAssertNil(model.mergePlan)
        XCTAssertTrue(model.pullRequests.isEmpty)
    }

    // MARK: - The refusals

    func testTheGateIsAskedAndNothingIsSentWhileTheWorktreeIsBeingRewritten() async {
        let cli = ScriptedGitHubCLI()
        let gate = WriteGate()
        let model = await readyModel(cli, gate: gate)
        gate.isBlocked = true
        let asksBefore = gate.asks

        let outcome = await model.merge(number: 54, method: .squash, subject: "s", body: "")

        XCTAssertNil(outcome)
        XCTAssertGreaterThan(gate.asks, asksBefore)
        XCTAssertEqual(cli.count(for: mergeArguments()), 0)
        XCTAssertEqual(model.mergeMessage, PullRequestModel.mergeBlockedMessage)
        XCTAssertFalse(model.isWriteInFlight)
    }

    func testAMergeIsRefusedWhileAnotherOfTheFeaturesWritesIsInFlight() async {
        let cli = ScriptedGitHubCLI()
        let gate = Gate()
        let model = await readyModel(cli)
        cli.serve(mergeArguments(), stdout: "")
        cli.hold(mergeArguments(), on: gate)

        let first = Task {
            await model.merge(number: 54, method: .squash, subject: "A change (#54)", body: "")
        }
        // The window the first merge is suspended in — the transport blocks a
        // cooperative-pool thread while the main actor stays free, which is what
        // makes the second press a real second press rather than a hope.
        await gate.waitUntilReached()
        XCTAssertTrue(model.isWriteInFlight)

        // The second press, while the first is still in flight.
        let second = await model.merge(number: 54, method: .merge, subject: "A change (#54)", body: "")
        XCTAssertNil(second)
        XCTAssertEqual(cli.count(for: mergeArguments(method: .merge, subject: "A change (#54)")), 0)

        // And a checkout and a create are refused on the same flag.
        XCTAssertFalse(model.checkout(54))
        let created = await model.create(title: "t", body: "", base: "master", draft: false)
        XCTAssertFalse(created)

        gate.release()
        _ = await first.value
        XCTAssertFalse(model.isWriteInFlight)
    }

    func testAMergeIsRefusedWithASentenceWhenGitHubStoppedBeingReady() async {
        let cli = ScriptedGitHubCLI()
        let model = await readyModel(cli)
        cli.serve(GitHubCommands.authStatus(), status: 1)
        await model.refresh(branch: "master")

        let outcome = await model.merge(number: 54, method: .squash, subject: "s", body: "")

        XCTAssertNil(outcome)
        XCTAssertEqual(model.mergeMessage, PullRequestModel.unavailableMessage)
        XCTAssertEqual(cli.count(for: mergeArguments()), 0)
    }

    func testAMergeIsRefusedWhenTheRowHasLeftTheListBehindTheSheet() async {
        let cli = ScriptedGitHubCLI()
        let model = await readyModel(cli)
        // Somebody else merged it: the next refresh drops the row.
        cli.serve(GitHubCommands.openPullRequests(root: root), stdout: "[]")
        await model.refresh(branch: "master")

        let outcome = await model.merge(number: 54, method: .squash, subject: "s", body: "")

        XCTAssertNil(outcome)
        XCTAssertEqual(model.mergeMessage, PullRequestModel.mergeRowMissingMessage)
        XCTAssertEqual(cli.count(for: mergeArguments()), 0)
    }

    /// The plan is re-decided from the row the list holds *now*, so a check that
    /// went red behind an open sheet refuses rather than sends.
    func testAMergeIsRefusedWithThePlansOwnSentenceWhenTheRowWentRedBehindTheSheet() async {
        let cli = ScriptedGitHubCLI()
        let model = await readyModel(cli)
        cli.serve(
            GitHubCommands.openPullRequests(root: root),
            stdout: Self.listJSON(mergeState: "UNSTABLE", rollup: Self.failedRollup)
        )
        await model.refresh(branch: "master")

        let outcome = await model.merge(number: 54, method: .squash, subject: "s", body: "")

        XCTAssertNil(outcome)
        XCTAssertEqual(model.mergeMessage, GitHubMergeRefusal.checksFailed.message)
        XCTAssertEqual(cli.count(for: mergeArguments()), 0)
        XCTAssertEqual(model.mergePlan?.refusal, .checksFailed)
    }

    func testAMergeIsRefusedWhileChecksAreStillRunningAndTheRefusalIsTheArmableOne() async {
        let cli = ScriptedGitHubCLI()
        let model = await readyModel(
            cli,
            list: Self.listJSON(mergeState: "BLOCKED", rollup: Self.pendingRollup)
        )

        let outcome = await model.merge(number: 54, method: .squash, subject: "s", body: "")

        XCTAssertNil(outcome)
        XCTAssertEqual(model.mergeMessage, GitHubMergeRefusal.checksRunning.message)
        XCTAssertTrue(model.mergePlan?.refusal?.isArmable == true)
        XCTAssertEqual(cli.count(for: mergeArguments()), 0)
    }

    func testAMergeIsRefusedWhenTheMethodIsNotOneTheRepositoryAllows() async {
        let cli = ScriptedGitHubCLI()
        let model = await readyModel(cli, repository: Self.squashOnlyJSON)
        XCTAssertEqual(model.mergePlan?.allowedMethods, [.squash])
        XCTAssertFalse(model.mergePlan?.showsMethodPicker == true)

        let outcome = await model.merge(number: 54, method: .rebase, subject: "s", body: "")

        XCTAssertNil(outcome)
        XCTAssertEqual(model.mergeMessage, PullRequestModel.mergeMethodMissingMessage)
        XCTAssertEqual(cli.count(for: mergeArguments(method: .rebase, subject: "s")), 0)
    }

    // MARK: - What is sent

    func testTheCommandCarriesTheRowsOwnHeadAndTheSheetsSubjectAndBody() async {
        let cli = ScriptedGitHubCLI()
        let model = await readyModel(cli, list: Self.listJSON(oid: "deadbeef"))
        let expected = mergeArguments(oid: "deadbeef", subject: "Squashed (#54)", body: "Why.")
        cli.serve(expected, stdout: "")
        cli.serve(GitHubCommands.openPullRequests(root: root), stdout: "[]")

        let outcome = await model.merge(
            number: 54,
            method: .squash,
            subject: "Squashed (#54)",
            body: "Why."
        )

        XCTAssertNotNil(outcome)
        XCTAssertEqual(
            cli.argumentLists.last(where: { $0.prefix(2) == ["pr", "merge"] }),
            [
                "pr", "merge", "54", "--squash",
                "--match-head-commit", "deadbeef",
                "--subject", "Squashed (#54)",
                "--body", "Why.",
            ]
        )
    }

    func testARebaseSendsNeitherSubjectNorBody() async {
        let cli = ScriptedGitHubCLI()
        let model = await readyModel(cli)
        let expected = mergeArguments(method: .rebase, subject: "A change (#54)", body: "Why.")
        cli.serve(expected, stdout: "")
        cli.serve(GitHubCommands.openPullRequests(root: root), stdout: "[]")

        _ = await model.merge(number: 54, method: .rebase, subject: "A change (#54)", body: "Why.")

        let sent = cli.argumentLists.last(where: { $0.prefix(2) == ["pr", "merge"] })
        XCTAssertEqual(sent, ["pr", "merge", "54", "--rebase", "--match-head-commit", "abc123"])
        XCTAssertFalse(sent?.contains("--subject") == true)
        XCTAssertFalse(sent?.contains("--body") == true)
    }

    /// The branch is read again as the last thing before the command is composed:
    /// the sheet can stand open while the widget switches branches behind it, and
    /// the tail is decided from that reading.
    func testTheCheckedOutBranchIsReadAgainBeforeTheMergeIsSent() async {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        let model = await readyModel(cli, git: git)
        let readsAfterPreparing = git.branchReads
        cli.serve(mergeArguments(), stdout: "")
        cli.serve(GitHubCommands.openPullRequests(root: root), stdout: "[]")

        // The branch moved off the head while the sheet stood open.
        git.branch = "master"
        let outcome = await model.merge(number: 54, method: .squash, subject: "A change (#54)", body: "")

        XCTAssertGreaterThan(git.branchReads, readsAfterPreparing)
        XCTAssertEqual(outcome?.isTailOwed, false)
    }

    // MARK: - The outcome

    func testASuccessfulMergeOwesTheTailWhenTheMergedHeadIsTheCheckedOutBranch() async {
        let cli = ScriptedGitHubCLI()
        let model = await readyModel(cli)
        cli.serve(mergeArguments(), stdout: "")
        cli.serve(GitHubCommands.openPullRequests(root: root), stdout: "[]")

        let outcome = await model.merge(number: 54, method: .squash, subject: "A change (#54)", body: "")

        XCTAssertEqual(
            outcome,
            PullRequestModel.MergeOutcome(
                number: 54,
                headBranch: "feature",
                baseBranch: "master",
                isTailOwed: true
            )
        )
        // The merged row left the list through the ordinary refresh, which is
        // also how the bottom-bar indicator clears.
        XCTAssertTrue(model.pullRequests.isEmpty)
        XCTAssertFalse(model.isWriteInFlight)
        XCTAssertNil(model.mergeMessage)
    }

    func testMergingARowWhoseHeadIsNotCheckedOutOwesNoTail() async {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        git.branch = "some-other-branch"
        let model = await readyModel(cli, git: git)
        cli.serve(mergeArguments(), stdout: "")
        cli.serve(GitHubCommands.openPullRequests(root: root), stdout: "[]")

        let outcome = await model.merge(number: 54, method: .squash, subject: "A change (#54)", body: "")

        XCTAssertEqual(outcome?.isTailOwed, false)
        XCTAssertEqual(outcome?.baseBranch, "master")
        XCTAssertNil(model.mergePlan?.tailSentence)
    }

    func testAFailedMergeKeepsTheRowAndSaysWhyInGitHubsOwnWords() async {
        let cli = ScriptedGitHubCLI()
        let model = await readyModel(cli)
        cli.serve(
            mergeArguments(),
            stderr: "Head branch was modified. Review and try the merge again.",
            status: 1
        )

        let outcome = await model.merge(number: 54, method: .squash, subject: "A change (#54)", body: "")

        XCTAssertNil(outcome)
        XCTAssertEqual(model.mergeMessage, "Head branch was modified. Review and try the merge again.")
        XCTAssertEqual(model.pullRequests.map(\.number), [54])
        XCTAssertFalse(model.isWriteInFlight)
    }

    func testATransportFailureLowersTheWriteFlagAndCarriesItsOwnSentence() async {
        let cli = ScriptedGitHubCLI()
        let model = await readyModel(cli)
        cli.fail(mergeArguments(), with: GitHubCLIError.notInstalled)

        let outcome = await model.merge(number: 54, method: .squash, subject: "A change (#54)", body: "")

        XCTAssertNil(outcome)
        XCTAssertEqual(model.mergeMessage, GitHubCLIError.notInstalled.errorDescription)
        XCTAssertFalse(model.isWriteInFlight)
    }

    // MARK: - The one message slot

    func testTheSheetsSlotShowsOnlyTheMergesOwnSentences() async {
        let cli = ScriptedGitHubCLI()
        let model = await readyModel(cli)
        // A background refresh fails behind the open sheet.
        cli.serve(GitHubCommands.openPullRequests(root: root), stderr: "network is down", status: 1)
        await model.refresh(branch: "master")

        XCTAssertEqual(model.errorMessage, "network is down")
        XCTAssertNil(model.mergeMessage)
    }

    func testDismissingTheSheetClearsOnlyItsOwnSentence() async {
        let cli = ScriptedGitHubCLI()
        let model = await readyModel(cli)
        cli.serve(mergeArguments(), stderr: "Pull request is not mergeable", status: 1)
        _ = await model.merge(number: 54, method: .squash, subject: "A change (#54)", body: "")
        XCTAssertEqual(model.mergeMessage, "Pull request is not mergeable")

        model.dismissMerge()
        XCTAssertNil(model.mergeMessage)
        XCTAssertNil(model.errorMessage)

        // A refresh failure landing behind the sheet is not the sheet's to clear.
        cli.serve(GitHubCommands.openPullRequests(root: root), stderr: "network is down", status: 1)
        await model.refresh(branch: "master")
        model.dismissMerge()
        XCTAssertEqual(model.errorMessage, "network is down")
    }

    // MARK: - The tail's one refusal

    func testTheTailsRefusalNamesTheBaseAndSaysTheMergeLanded() {
        let sentence = PullRequestModel.tailBranchMissingMessage(base: "master")

        XCTAssertTrue(sentence.contains("“master”"))
        XCTAssertTrue(sentence.contains("merged"))
    }
}
