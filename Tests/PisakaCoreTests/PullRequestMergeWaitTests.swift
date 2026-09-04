import XCTest
@testable import PisakaCore

/// *Merge when checks pass* — the bounded, visible, cancelable wait (G14).
///
/// Four properties carry the suite:
///
/// - **No wall clock.** The interval and the deadline are named constants, the
///   sleep is one injectable seam and the clock is another, so the whole state
///   machine — including a deadline sixty ticks deep — is exercised in
///   microseconds. Every test here asserts the *sleeps* rather than measuring
///   time, and a wait that reached a real `Task.sleep` would hang the suite
///   rather than pass it slowly.
/// - **One rule, one table.** Every tick is decided by `GitHubMergePlan` from a
///   row read by number, and `pr checks` is asserted **absent** from the call
///   log — a wait deciding "green" from the jobs table would hand a merge to a
///   plan that refuses it.
/// - **Exactly four endings**, each asserted as a published value *and* as what
///   did or did not reach the transport: a stop that still sent `pr merge` is
///   not a stop.
/// - **The head is this tick's.** `--match-head-commit` is asserted against the
///   oid the *poll* answered, not the one the arm was made with, which is the
///   only reason a push landing mid-wait is GitHub's refusal rather than a merge
///   of something nobody read.
@MainActor
final class PullRequestMergeWaitTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/tmp/pisaka-github")

    // MARK: - Stubs

    /// A clock the sleep seam winds forward, so "half an hour passed" is sixty
    /// function calls rather than half an hour.
    private final class StubClock {
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        var read: () -> Date { { [self] in date } }
    }

    private final class StubGit: GitServicing {
        var branch: String? = "feature"

        func repositoryRoot(for url: URL) async throws -> URL { url }
        func changedFiles(root: URL) async throws -> [ChangedFile] { [] }
        func commits(filter: LogFilter, limit: Int, root: URL) async throws -> [Commit] { [] }
        func headContents(of path: String, root: URL) async throws -> String? { nil }
        func revert(_ file: ChangedFile, root: URL) async throws {}

        func currentBranch(root: URL) async throws -> BranchRef? {
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

    private static let pendingRollup = """
    [{"__typename":"CheckRun","name":"build","workflowName":"CI",
    "status":"IN_PROGRESS","conclusion":"","detailsUrl":"https://x"}]
    """

    private static let failedRollup = """
    [{"__typename":"CheckRun","name":"build","workflowName":"CI",
    "status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://x"}]
    """

    private static let passedRollup = """
    [{"__typename":"CheckRun","name":"build","workflowName":"CI",
    "status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://x"}]
    """

    /// One row, as `pr list` prints it — the state a wait is armed from.
    private static func rowJSON(
        number: Int = 54,
        isDraft: Bool = false,
        head: String = "feature",
        base: String = "master",
        oid: String = "abc123",
        state: String = "OPEN",
        mergeable: String = "MERGEABLE",
        mergeState: String = "CLEAN",
        rollup: String = pendingRollup
    ) -> String {
        """
        {"number":\(number),"title":"A change","author":{"login":"someone"},
        "headRefName":"\(head)","baseRefName":"\(base)","isDraft":\(isDraft),
        "reviewDecision":"","url":"https://github.com/o/r/pull/\(number)",
        "state":"\(state)","statusCheckRollup":\(rollup),
        "headRefOid":"\(oid)","mergeable":"\(mergeable)","mergeStateStatus":"\(mergeState)"}
        """
    }

    /// The same row as `pr view <n>` prints it: one object, not an array.
    private static func viewJSON(
        oid: String = "abc123",
        state: String = "OPEN",
        isDraft: Bool = false,
        mergeable: String = "MERGEABLE",
        mergeState: String = "CLEAN",
        rollup: String = pendingRollup
    ) -> GitHubCommandResult {
        GitHubCommandResult(
            standardOutput: rowJSON(
                oid: oid,
                state: state,
                mergeable: mergeable,
                mergeState: mergeState,
                rollup: rollup
            ),
            standardError: "",
            status: 0
        )
    }

    private static let repositoryJSON = """
    {"nameWithOwner":"o/r","defaultBranchRef":{"name":"master"},
    "mergeCommitAllowed":true,"squashMergeAllowed":true,"rebaseMergeAllowed":true,
    "viewerDefaultMergeMethod":"SQUASH","deleteBranchOnMerge":false}
    """

    // MARK: - The harness

    private var viewCommand: GitHubCommand { GitHubCommands.pullRequest(number: 54, root: root) }

    private func mergeArguments(
        oid: String,
        method: GitHubMergeMethod = .squash,
        subject: String = "A change (#54)",
        body: String = ""
    ) -> [String] {
        GitHubCommands.mergePullRequest(
            number: 54,
            method: method,
            headRefOid: oid,
            subject: subject,
            body: body,
            root: root
        ).arguments
    }

    /// A model refreshed against a signed-in `gh` showing one row whose checks
    /// are still running — the one state a wait may be armed from — with its
    /// merge sheet prepared over it.
    private func armedModel(
        _ cli: ScriptedGitHubCLI,
        clock: StubClock,
        sleeps: SleepLog,
        list: String? = nil,
        currentRoot: (@MainActor () -> URL?)? = nil,
        isWriteBlocked: @escaping @MainActor () -> Bool = { false }
    ) async -> PullRequestModel {
        let root = root
        cli.serveReady()
        cli.serve(
            GitHubCommands.openPullRequests(root: root),
            stdout: list ?? "[\(Self.rowJSON())]"
        )
        for name in ["feature", "master"] {
            cli.serve(GitHubCommands.pullRequest(forHeadBranch: name, root: root), stdout: "[]")
        }
        cli.serve(GitHubCommands.repositoryView(root: root), stdout: Self.repositoryJSON)

        let model = PullRequestModel(
            transport: cli,
            gitService: StubGit(),
            root: currentRoot ?? { root },
            isWriteBlocked: isWriteBlocked
        )
        await model.refresh(branch: "feature")
        await model.prepareMerge(number: 54)
        model.mergeWait.now = clock.read
        model.mergeWait.sleep = { seconds in
            sleeps.record(seconds)
            clock.date.addTimeInterval(seconds)
        }
        return model
    }

    /// Every sleep the wait asked for, which is the suite's whole account of
    /// elapsed time.
    private final class SleepLog {
        private(set) var seconds: [TimeInterval] = []
        func record(_ value: TimeInterval) { seconds.append(value) }
    }

    /// Arm the prepared sheet's plan and run the loop to a standstill.
    @discardableResult
    private func arm(
        _ model: PullRequestModel,
        method: GitHubMergeMethod = .squash,
        subject: String = "A change (#54)",
        body: String = ""
    ) -> Bool {
        guard let plan = model.mergePlan else { return false }
        return model.mergeWait.arm(plan: plan, method: method, subject: subject, body: body)
    }

    private func settle(_ model: PullRequestModel) async {
        await model.mergeWait.runningTask?.value
    }

    // MARK: - The two numbers

    func testTheIntervalAndTheDeadlineAreNamedConstants() {
        XCTAssertEqual(PullRequestMergeWait.pollInterval, 30)
        XCTAssertEqual(PullRequestMergeWait.deadline, 30 * 60)
        // The sentence is built from the constant rather than spelling it again,
        // so the two cannot drift apart.
        XCTAssertTrue(PullRequestMergeWait.deadlineMessage.contains("30 minutes"))
    }

    // MARK: - Arming

    func testAWaitIsArmableOnlyWhileChecksAreStillRunning() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        let model = await armedModel(cli, clock: clock, sleeps: sleeps)

        XCTAssertEqual(model.mergePlan?.refusal, .checksRunning)
        XCTAssertTrue(model.mergeWait.arm(plan: model.mergePlan!, method: .squash, subject: "s", body: ""))
        XCTAssertTrue(model.mergeWait.isArmed)
        XCTAssertTrue(model.mergeWait.isWaiting(on: 54))
        XCTAssertFalse(model.mergeWait.isWaiting(on: 55))
        model.mergeWait.cancel()
    }

    func testAMergeablePlanAndAFailedOneAreBothUnarmable() async {
        for rollup in [Self.passedRollup, Self.failedRollup] {
            let cli = ScriptedGitHubCLI()
            let clock = StubClock()
            let sleeps = SleepLog()
            let model = await armedModel(
                cli,
                clock: clock,
                sleeps: sleeps,
                list: "[\(Self.rowJSON(rollup: rollup))]"
            )

            XCTAssertFalse(arm(model), "Only “checks are still running” is a state a reader waits through.")
            XCTAssertFalse(model.mergeWait.isArmed)
            XCTAssertNil(model.mergeWait.ending)
        }
    }

    func testAMethodTheRepositoryDoesNotAllowIsRefusedBeforeHalfAnHourIsSpent() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        cli.serveReady()
        cli.serve(GitHubCommands.openPullRequests(root: root), stdout: "[\(Self.rowJSON())]")
        cli.serve(GitHubCommands.pullRequest(forHeadBranch: "feature", root: root), stdout: "[]")
        cli.serve(
            GitHubCommands.repositoryView(root: root),
            stdout: """
            {"nameWithOwner":"o/r","defaultBranchRef":{"name":"master"},
            "mergeCommitAllowed":false,"squashMergeAllowed":true,"rebaseMergeAllowed":false,
            "viewerDefaultMergeMethod":"SQUASH","deleteBranchOnMerge":false}
            """
        )
        let model = PullRequestModel(transport: cli, gitService: StubGit(), root: { self.root })
        await model.refresh(branch: "feature")
        await model.prepareMerge(number: 54)
        model.mergeWait.now = clock.read
        model.mergeWait.sleep = { seconds in sleeps.record(seconds) }

        XCTAssertFalse(arm(model, method: .rebase))
        XCTAssertTrue(arm(model, method: .squash))
        model.mergeWait.cancel()
    }

    // MARK: - Ending one: the merge

    func testTheWaitMergesOnTheFirstGreenTickAndCarriesThatTicksHead() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        let model = await armedModel(cli, clock: clock, sleeps: sleeps)
        // Two ticks: still running, then green — and the head has moved between
        // the arm (`abc123`) and the green read.
        cli.serve(viewCommand, sequence: [
            Self.viewJSON(),
            Self.viewJSON(oid: "def456", rollup: Self.passedRollup),
        ])
        cli.serve(mergeArguments(oid: "def456"), stdout: "Merged\n")

        var merged: PullRequestModel.MergeOutcome?
        model.mergeWait.didMerge = { merged = $0 }
        XCTAssertTrue(arm(model))
        await settle(model)

        // Against a literal built here, not against the value the code under
        // test just handed to `didMerge` — that comparison holds for
        // `.merged(nil)` and `nil` just as well, so on its own it could never
        // fail.
        XCTAssertEqual(
            model.mergeWait.ending,
            .merged(PullRequestModel.MergeOutcome(
                number: 54,
                baseBranch: "master",
                isTailOwed: true,
                root: root
            ))
        )
        XCTAssertNil(model.mergeWait.ending?.message)
        XCTAssertFalse(model.mergeWait.isArmed)
        XCTAssertEqual(cli.count(for: viewCommand), 2)
        XCTAssertEqual(sleeps.seconds, [PullRequestMergeWait.pollInterval])
        // The head guard has no rule of its own: it is whatever the tick read.
        XCTAssertEqual(cli.count(for: mergeArguments(oid: "def456")), 1)
        XCTAssertEqual(cli.count(for: mergeArguments(oid: "abc123")), 0)
        XCTAssertEqual(merged?.number, 54)
        XCTAssertEqual(merged?.baseBranch, "master")
        XCTAssertTrue(merged?.isTailOwed == true)
        XCTAssertNil(model.mergeMessage)
    }

    func testGitHubsRefusalOfAMovedHeadEndsTheWaitInGitHubsOwnWords() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        let model = await armedModel(cli, clock: clock, sleeps: sleeps)
        cli.serve(viewCommand, Self.viewJSON(oid: "def456", rollup: Self.passedRollup))
        cli.serve(
            mergeArguments(oid: "def456"),
            stderr: "X Pull request #54 is not mergeable: the head commit has changed.",
            status: 1
        )

        var merged: PullRequestModel.MergeOutcome?
        model.mergeWait.didMerge = { merged = $0 }
        XCTAssertTrue(arm(model))
        await settle(model)

        // The merge *ran* — that is the ending — and `gh`'s words are where the
        // reader is looking. No tail is owed for a merge that did not land.
        XCTAssertEqual(model.mergeWait.ending, .merged(nil))
        XCTAssertNil(merged)
        XCTAssertEqual(
            model.mergeMessage,
            "X Pull request #54 is not mergeable: the head commit has changed."
        )
    }

    // MARK: - Ending two: a stop the plan named

    func testAFailingCheckStopsTheWaitWithThatRefusalsSentence() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        let model = await armedModel(cli, clock: clock, sleeps: sleeps)
        cli.serve(viewCommand, sequence: [
            Self.viewJSON(),
            Self.viewJSON(rollup: Self.failedRollup),
        ])

        XCTAssertTrue(arm(model))
        await settle(model)

        XCTAssertEqual(model.mergeWait.ending, .stopped(GitHubMergeRefusal.checksFailed.message))
        XCTAssertEqual(model.mergeWait.ending?.message, "Some checks did not pass.")
        XCTAssertFalse(model.mergeWait.isArmed)
        XCTAssertEqual(cli.count(for: mergeArguments(oid: "abc123")), 0)
    }

    /// The plan-driven table, tick by tick: what a wait sits through, and what it
    /// stops on — read off `mayResolveByWaiting` rather than restated here.
    func testEveryRefusalWaitingCannotChangeStopsTheWaitWithItsOwnSentence() async {
        let states: [(String, String, String, GitHubMergeRefusal)] = [
            ("CONFLICTING", "DIRTY", Self.passedRollup, .conflicts),
            ("MERGEABLE", "BEHIND", Self.passedRollup, .behind),
            ("MERGEABLE", "BLOCKED", Self.passedRollup, .blocked),
            ("MERGEABLE", "CLEAN", Self.failedRollup, .checksFailed),
        ]
        for (mergeable, mergeState, rollup, expected) in states {
            let cli = ScriptedGitHubCLI()
            let clock = StubClock()
            let sleeps = SleepLog()
            let model = await armedModel(cli, clock: clock, sleeps: sleeps)
            cli.serve(
                viewCommand,
                Self.viewJSON(mergeable: mergeable, mergeState: mergeState, rollup: rollup)
            )

            XCTAssertTrue(arm(model))
            await settle(model)

            XCTAssertFalse(expected.mayResolveByWaiting)
            XCTAssertEqual(model.mergeWait.ending, .stopped(expected.message))
            XCTAssertEqual(sleeps.seconds, [], "A state waiting cannot change is not slept on.")
            XCTAssertEqual(cli.count(for: mergeArguments(oid: "abc123")), 0)
        }
    }

    func testTheTwoComputingStatesAreSleptThroughRatherThanStoppedOn() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        let model = await armedModel(cli, clock: clock, sleeps: sleeps)
        cli.serve(viewCommand, sequence: [
            // Checks still running…
            Self.viewJSON(),
            // …then mergeability not computed yet…
            Self.viewJSON(mergeable: "UNKNOWN", mergeState: "UNKNOWN", rollup: Self.passedRollup),
            // …then green.
            Self.viewJSON(rollup: Self.passedRollup),
        ])
        cli.serve(mergeArguments(oid: "abc123"), stdout: "Merged\n")

        XCTAssertTrue(arm(model))
        await settle(model)

        XCTAssertTrue(GitHubMergeRefusal.checksRunning.mayResolveByWaiting)
        XCTAssertTrue(GitHubMergeRefusal.mergeabilityUnknown.mayResolveByWaiting)
        XCTAssertEqual(cli.count(for: viewCommand), 3)
        XCTAssertEqual(sleeps.seconds, [30, 30])
        XCTAssertEqual(cli.count(for: mergeArguments(oid: "abc123")), 1)
    }

    func testARowThatIsNoLongerOpenStopsTheWaitWithItsOwnSentence() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        let model = await armedModel(cli, clock: clock, sleeps: sleeps)
        cli.serve(
            viewCommand,
            Self.viewJSON(state: "MERGED", mergeable: "UNKNOWN", mergeState: "UNKNOWN")
        )

        XCTAssertTrue(arm(model))
        await settle(model)

        XCTAssertEqual(model.mergeWait.ending, .stopped(PullRequestMergeWait.noLongerOpenMessage))
        XCTAssertEqual(cli.count(for: mergeArguments(oid: "abc123")), 0)
    }

    func testAReadThatCouldNotBeMadeStopsTheWaitInGitHubsWords() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        let model = await armedModel(cli, clock: clock, sleeps: sleeps)
        cli.serve(viewCommand, stderr: "could not resolve to a PullRequest", status: 1)

        XCTAssertTrue(arm(model))
        await settle(model)

        XCTAssertEqual(model.mergeWait.ending, .stopped("could not resolve to a PullRequest"))
        XCTAssertEqual(sleeps.seconds, [], "A failing read is reported now, not in half an hour.")
    }

    // MARK: - Ending three: the deadline

    func testAWaitThatNeverGoesGreenEndsAtTheDeadline() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        let model = await armedModel(cli, clock: clock, sleeps: sleeps)
        cli.serve(viewCommand, Self.viewJSON())

        XCTAssertTrue(arm(model))
        await settle(model)

        XCTAssertEqual(model.mergeWait.ending, .deadline)
        XCTAssertEqual(model.mergeWait.ending?.message, PullRequestMergeWait.deadlineMessage)
        // Sixty sleeps of thirty seconds is the deadline exactly, so the
        // sixty-first read is the one that finds it spent.
        XCTAssertEqual(sleeps.seconds.count, 60)
        XCTAssertEqual(cli.count(for: viewCommand), 61)
        XCTAssertEqual(model.mergeWait.elapsed, PullRequestMergeWait.deadline)
        XCTAssertEqual(cli.count(for: mergeArguments(oid: "abc123")), 0)
        XCTAssertFalse(model.mergeWait.isArmed)
    }

    // MARK: - Ending four: cancellation

    func testCancellingAPollInFlightPublishesTheCancellationAndNothingElse() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        let model = await armedModel(cli, clock: clock, sleeps: sleeps)
        let gate = Gate()
        // The green answer is already scripted: if the resumed poll published
        // anything, it would publish a *merge*, which is the loudest possible
        // way for this assertion to fail.
        cli.serve(viewCommand, Self.viewJSON(rollup: Self.passedRollup))
        cli.serve(mergeArguments(oid: "abc123"), stdout: "Merged\n")
        cli.hold(viewCommand, on: gate)

        XCTAssertTrue(arm(model))
        let task = model.mergeWait.runningTask
        await gate.waitUntilReached()
        model.mergeWait.cancel()
        gate.release()
        await task?.value

        XCTAssertEqual(model.mergeWait.ending, .cancelled)
        XCTAssertNil(model.mergeWait.ending?.message)
        XCTAssertFalse(model.mergeWait.isArmed)
        XCTAssertEqual(cli.count(for: mergeArguments(oid: "abc123")), 0)
    }

    func testCancellingWithNothingArmedPublishesNoEnding() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        let model = await armedModel(cli, clock: clock, sleeps: sleeps)

        model.mergeWait.cancel()

        XCTAssertNil(model.mergeWait.ending)
    }

    func testArmingASecondWaitCancelsTheFirst() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        let model = await armedModel(cli, clock: clock, sleeps: sleeps)
        let gate = Gate()
        cli.serve(viewCommand, Self.viewJSON())
        cli.hold(viewCommand, on: gate, forCall: 0)

        XCTAssertTrue(arm(model))
        let first = model.mergeWait.runningTask
        await gate.waitUntilReached()
        XCTAssertTrue(arm(model, subject: "A second arming (#54)"))
        let second = model.mergeWait.runningTask
        XCTAssertNotEqual(first, second, "The second arming is a second loop, not a re-entry into the first.")
        gate.release()
        await first?.value

        // The first loop resumed into a moved token and published nothing: the
        // armed state is the second arming's, and no ending was recorded for a
        // wait that was replaced.
        XCTAssertEqual(model.mergeWait.armed?.subject, "A second arming (#54)")
        XCTAssertNil(model.mergeWait.ending)
        model.mergeWait.cancel()
        await second?.value
    }

    // MARK: - What a wait may not do

    func testNoTickEverComposesAChecksCommand() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        let model = await armedModel(cli, clock: clock, sleeps: sleeps)
        cli.serve(viewCommand, sequence: [
            Self.viewJSON(),
            Self.viewJSON(),
            Self.viewJSON(rollup: Self.passedRollup),
        ])
        cli.serve(mergeArguments(oid: "abc123"), stdout: "Merged\n")

        XCTAssertTrue(arm(model))
        await settle(model)

        XCTAssertFalse(
            cli.trace.contains("pr checks"),
            "The checks command cannot see mergeable or mergeStateStatus, so a wait deciding “green” from "
                + "it would hand a merge to a plan that refuses it. Every tick reads the row itself."
        )
        XCTAssertEqual(cli.count(for: GitHubCommands.checks(pullRequest: 54, root: root)), 0)
    }

    func testThePollsRaiseNoWriteFlagAndTheMergeAloneDoes() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        let model = await armedModel(cli, clock: clock, sleeps: sleeps)
        let gate = Gate()
        cli.serve(viewCommand, Self.viewJSON())
        cli.hold(viewCommand, on: gate, forCall: 0)

        XCTAssertTrue(arm(model))
        let task = model.mergeWait.runningTask
        await gate.waitUntilReached()

        // Armed, a read in flight — and Checkout, Create and refresh all still
        // available, because none of them is the merge this wait has not run yet.
        XCTAssertTrue(model.mergeWait.isArmed)
        XCTAssertFalse(model.isWriteInFlight)

        model.mergeWait.cancel()
        gate.release()
        await task?.value
        XCTAssertFalse(model.isWriteInFlight)
    }

    func testTheElapsedTimeIsPublishedFromTheWaitsOwnClock() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        let model = await armedModel(cli, clock: clock, sleeps: sleeps)
        cli.serve(viewCommand, sequence: [
            Self.viewJSON(),
            Self.viewJSON(),
            Self.viewJSON(rollup: Self.failedRollup),
        ])

        XCTAssertTrue(arm(model))
        await settle(model)

        // Three ticks: 0 s, 30 s, 60 s — read off the injected clock, so no view
        // has to run one of its own.
        XCTAssertEqual(model.mergeWait.elapsed, 2 * PullRequestMergeWait.pollInterval)
        // …and the row prints that, rather than formatting a duration of its own.
        XCTAssertEqual(model.mergeWait.elapsedLabel, "1:00")
    }

    // MARK: - What the surfaces read

    /// The row's label, over the values a wait actually publishes. A view that
    /// formatted this itself would be one step from a view that also advanced it.
    func testTheElapsedLabelIsMinutesAndPaddedSeconds() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        let model = await armedModel(cli, clock: clock, sleeps: sleeps)
        cli.serve(viewCommand, sequence: [
            Self.viewJSON(),
            Self.viewJSON(),
            Self.viewJSON(),
            Self.viewJSON(rollup: Self.failedRollup),
        ])

        XCTAssertEqual(model.mergeWait.elapsedLabel, "0:00")
        XCTAssertTrue(arm(model))
        await settle(model)

        // Three sleeps of 30 s: 1:30.
        XCTAssertEqual(model.mergeWait.elapsedLabel, "1:30")
    }

    /// The **one** disable term every row's Merge button reads, and both halves
    /// of it: this feature's one-write rule, and one armed wait disabling every
    /// row's Merge rather than only its own — the merge that wait will run is the
    /// one-write rule spent in advance.
    ///
    /// Asserted here rather than in the panel, which by convention has no tests:
    /// the term is Core's, so the view has nothing left to decide.
    func testOneArmedWaitDisablesEveryRowsMerge() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        let model = await armedModel(cli, clock: clock, sleeps: sleeps)
        let gate = Gate()
        cli.serve(viewCommand, Self.viewJSON())
        cli.hold(viewCommand, on: gate, forCall: 0)

        XCTAssertTrue(model.mergeIsAvailable)

        XCTAssertTrue(arm(model))
        let task = model.mergeWait.runningTask
        await gate.waitUntilReached()

        XCTAssertFalse(model.mergeIsAvailable, "Every row's Merge, not merely the row being waited on.")
        // …while nothing that is not a merge is touched by it.
        XCTAssertFalse(model.isWriteInFlight)
        XCTAssertFalse(model.checkoutIsBlocked())

        model.mergeWait.cancel()
        gate.release()
        await task?.value

        XCTAssertTrue(model.mergeIsAvailable, "Cancelling gives it back.")
    }

    /// The other half of the same term: a `gh` that is not ready has nothing to
    /// merge, which is the state the panel is already drawing its not-ready
    /// sentence for.
    func testMergeIsNotOfferedBeforeGhIsKnownToBeReady() {
        let model = PullRequestModel(transport: ScriptedGitHubCLI(), gitService: StubGit(), root: { self.root })

        XCTAssertFalse(model.isReady)
        XCTAssertFalse(model.mergeIsAvailable)
    }

    /// Two of the four endings land in a panel nobody was watching — a deadline
    /// half an hour later, a stop some tick decided — so their sentence stays
    /// until it is read, and there is one way to say it has been.
    func testAnEndingsSentenceStaysUntilItIsAcknowledged() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        let model = await armedModel(cli, clock: clock, sleeps: sleeps)
        cli.serve(viewCommand, Self.viewJSON(rollup: Self.failedRollup))

        XCTAssertTrue(arm(model))
        await settle(model)

        XCTAssertEqual(model.mergeWait.ending?.message, GitHubMergeRefusal.checksFailed.message)
        model.mergeWait.acknowledgeEnding()
        XCTAssertNil(model.mergeWait.ending)
        // Idempotent, and silent when there is nothing to acknowledge.
        model.mergeWait.acknowledgeEnding()
        XCTAssertNil(model.mergeWait.ending)
    }

    /// The two endings that speak for themselves say nothing: a merge has the
    /// whole panel to show for itself, and a cancellation is something the reader
    /// just did.
    func testAMergeAndACancellationLeaveNoSentenceToDismiss() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        let model = await armedModel(cli, clock: clock, sleeps: sleeps)
        cli.serve(viewCommand, Self.viewJSON())

        XCTAssertTrue(arm(model))
        model.mergeWait.cancel()
        await settle(model)

        XCTAssertEqual(model.mergeWait.ending, .cancelled)
        XCTAssertNil(model.mergeWait.ending?.message)
    }

    // MARK: - The token is checked after *every* suspension

    /// A wait spends all but a moment of every 30 seconds inside the sleep, so
    /// Cancel, a project switch and quit almost always land **there** rather
    /// than in the read. The suite's other cancellation test holds the `pr view`
    /// and so exercises the guard after the *read*; this one is the guard after
    /// the sleep, and without it a cancelled wait issues another `pr view` and
    /// republishes `elapsed` on a wait nothing is armed on.
    func testCancellingDuringTheSleepStopsTheLoopBeforeTheNextRead() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        let model = await armedModel(cli, clock: clock, sleeps: sleeps)
        cli.serve(viewCommand, Self.viewJSON())

        model.mergeWait.sleep = { seconds in
            sleeps.record(seconds)
            clock.date.addTimeInterval(seconds)
            // The window Cancel actually lands in.
            model.mergeWait.cancel()
        }

        XCTAssertTrue(arm(model))
        await settle(model)

        XCTAssertEqual(model.mergeWait.ending, .cancelled)
        XCTAssertFalse(model.mergeWait.isArmed)
        // One read, and no second one after the wait was cancelled.
        XCTAssertEqual(cli.count(for: viewCommand), 1)
        XCTAssertEqual(sleeps.seconds, [PullRequestMergeWait.pollInterval])
        XCTAssertEqual(cli.count(for: mergeArguments(oid: "abc123")), 0)
    }

    // MARK: - Ending two, reached from the top of the loop: the world is gone

    /// `gh` stopped being ready, the project closed, or the rows — and with them
    /// the repository the plan is decided against — were blanked. From inside the
    /// wait that is indistinguishable from the row having left, and it stops with
    /// the row's own sentence rather than returning silently.
    func testAWaitWhoseProjectIsSwitchedAwayFromStopsAndSaysSo() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        var current: URL? = root
        let model = await armedModel(
            cli,
            clock: clock,
            sleeps: sleeps,
            currentRoot: { current }
        )
        cli.serve(viewCommand, Self.viewJSON())

        model.mergeWait.sleep = { seconds in
            sleeps.record(seconds)
            clock.date.addTimeInterval(seconds)
            // The folder switch, as the model sees it: a new root, and the
            // blank that goes with it.
            current = URL(fileURLWithPath: "/tmp/pisaka-some-other-project")
            _ = model.prepareForRefresh()
        }

        XCTAssertTrue(arm(model))
        await settle(model)

        XCTAssertEqual(model.mergeWait.ending, .stopped(PullRequestMergeWait.stateLostMessage))
        XCTAssertEqual(model.mergeWait.ending?.message, PullRequestMergeWait.stateLostMessage)
        // Its own sentence, and not the sheet's: this one is drawn in the
        // panel's ending strip, where "close this sheet" names nothing.
        XCTAssertNotEqual(PullRequestMergeWait.stateLostMessage, PullRequestModel.mergeRowMissingMessage)
        XCTAssertFalse(model.mergeWait.isArmed)
        // The second tick got as far as the guard and no further: one read, and
        // above all no merge under a repository nobody opened.
        XCTAssertEqual(cli.count(for: viewCommand), 1)
        XCTAssertEqual(cli.count(for: mergeArguments(oid: "abc123")), 0)
    }

    /// **The wait outlives its model, and must survive doing so.** The running
    /// `Task` holds the wait strongly for the whole of a tick, so a wait
    /// suspended in a sleep is still there after the scene's `@StateObject` — and
    /// with it `PullRequestModel` — has been released. Quit and a project switch
    /// both cancel first; a closed window does not, and an `unowned` reference
    /// resumed into that world traps.
    ///
    /// Two properties, and neither alone is the test. The next tick must end with
    /// the sentence for exactly this state rather than dereferencing what is
    /// gone; and the model must be **deallocated by then** — the wait keeps no
    /// reference of its own, so a stored strong `owner` would leave the released
    /// model alive here and fail on that assertion instead.
    func testAWaitWhoseModelIsReleasedStopsAtTheNextTickRatherThanReadingIt() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        var model: PullRequestModel? = await armedModel(cli, clock: clock, sleeps: sleeps)
        cli.serve(viewCommand, Self.viewJSON())

        // Held here rather than through the model, which is the whole staging:
        // this is the reference the running loop has.
        let wait = model!.mergeWait
        weak var released = model
        wait.sleep = { seconds in
            sleeps.record(seconds)
            clock.date.addTimeInterval(seconds)
            // The window closed while this tick was suspended.
            model = nil
        }

        XCTAssertTrue(arm(model!))
        await wait.runningTask?.value

        XCTAssertNil(released, "the wait kept a reference of its own to the model")
        XCTAssertEqual(wait.ending, .stopped(PullRequestMergeWait.stateLostMessage))
        XCTAssertFalse(wait.isArmed)
        // One read, no second one, and above all no merge sent under a model
        // that is not there.
        XCTAssertEqual(cli.count(for: viewCommand), 1)
        XCTAssertEqual(cli.count(for: mergeArguments(oid: "abc123")), 0)
    }

    /// The create sheet is **not** the wait's world, and a base read that failed
    /// must not be reported as one.
    ///
    /// `prepareCreate()` reads `gh repo view` for the picker's default base, and
    /// that read fails for ordinary reasons — offline, or a remote `gh` cannot
    /// resolve. `PullRequestModel.repository` is *shared*: this loop reads it on
    /// every tick and treats `nil` as "the world this wait was armed in is gone".
    /// So the sheet plans from a local and leaves the published value alone, or
    /// pressing New Pull Request beside an armed wait ends it — with the row's
    /// own sentence, about a row that never left, and permanently when the read
    /// behind that sheet failed too.
    ///
    /// Staged in the sleep seam, which is the gap between two ticks: the first
    /// tick is still running its checks, the sheet opens and fails in the gap,
    /// and the second tick has to find the same world it left.
    func testACreateSheetOpenedBesideAnArmedWaitDoesNotEndIt() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        let model = await armedModel(cli, clock: clock, sleeps: sleeps)
        cli.serve(viewCommand, sequence: [
            Self.viewJSON(),
            Self.viewJSON(rollup: Self.passedRollup),
        ])
        cli.serve(mergeArguments(oid: "abc123"), stdout: "Merged\n")

        model.mergeWait.sleep = { seconds in
            sleeps.record(seconds)
            clock.date.addTimeInterval(seconds)
            // The New Pull Request sheet opens in the gap, and its `repo view`
            // cannot describe the repository.
            cli.serve(
                GitHubCommands.repositoryView(root: self.root),
                stderr: "could not determine base repository\n",
                status: 1
            )
            await model.prepareCreate()
            // The failure is the sheet's own, said in `gh`'s words...
            XCTAssertEqual(model.createMessage, "could not determine base repository")
            // ...and it left the one value three readers share standing.
            XCTAssertNotNil(model.repository)
        }

        XCTAssertTrue(arm(model))
        await settle(model)

        // The wait ran its own course: the second tick was green, so it merged.
        XCTAssertEqual(
            model.mergeWait.ending,
            .merged(PullRequestModel.MergeOutcome(
                number: 54,
                baseBranch: "master",
                isTailOwed: true,
                root: root
            ))
        )
        XCTAssertNotEqual(
            model.mergeWait.ending,
            .stopped(PullRequestMergeWait.stateLostMessage)
        )
        XCTAssertEqual(cli.count(for: viewCommand), 2)
        XCTAssertEqual(cli.count(for: mergeArguments(oid: "abc123")), 1)
    }

    // MARK: - The one ending published past a moved token

    /// Cancel cannot un-send a `pr merge` already sent, so the merge is published
    /// either way and the tail is owed off the back of it. What Cancel *does*
    /// still buy is the disarm, which respects the token — asserted here as
    /// "`didMerge` fired exactly once and the ending is the merge's".
    func testCancellingWhileTheMergeIsInFlightStillPublishesTheMerge() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        let gate = Gate()
        let model = await armedModel(cli, clock: clock, sleeps: sleeps)
        cli.serve(viewCommand, Self.viewJSON(rollup: Self.passedRollup))
        cli.serve(mergeArguments(oid: "abc123"), stdout: "Merged\n")
        cli.serve(GitHubCommands.openPullRequests(root: root), stdout: "[]")
        cli.hold(mergeArguments(oid: "abc123"), on: gate)

        var merges = 0
        model.mergeWait.didMerge = { _ in merges += 1 }
        XCTAssertTrue(arm(model))
        // Held before the cancel, because `cancel()` drops the model's own
        // reference to the task — `settle(_:)` would otherwise return before the
        // merge in flight had finished, and assert against a wait mid-write.
        let running = model.mergeWait.runningTask
        // The window: `pr merge` is in flight and the reader presses Cancel.
        await gate.waitUntilReached()
        model.mergeWait.cancel()
        gate.release()
        await running?.value

        XCTAssertEqual(merges, 1)
        XCTAssertEqual(cli.count(for: mergeArguments(oid: "abc123")), 1)
        XCTAssertFalse(model.mergeWait.isArmed)
        XCTAssertEqual(
            model.mergeWait.ending,
            .merged(PullRequestModel.MergeOutcome(
                number: 54,
                baseBranch: "master",
                isTailOwed: true,
                root: root
            ))
        )
    }

    // MARK: - The wait's merge asks the same gate the sheet's does

    /// The one ending where a wait spends its whole promise and merges nothing.
    /// It is `.merged(nil)` — the wait does not re-arm around a refusal it did
    /// not make — and the *sentence* is the model's, which is why a silent
    /// refusal there would leave this ending with nothing on screen at all.
    func testAWaitWhoseMergeTheGateRefusesEndsWithTheModelsOwnSentence() async {
        let cli = ScriptedGitHubCLI()
        let clock = StubClock()
        let sleeps = SleepLog()
        var isBlocked = false
        let model = await armedModel(
            cli,
            clock: clock,
            sleeps: sleeps,
            isWriteBlocked: { isBlocked }
        )
        cli.serve(viewCommand, Self.viewJSON(rollup: Self.passedRollup))
        cli.serve(mergeArguments(oid: "abc123"), stdout: "Merged\n")

        var merges = 0
        model.mergeWait.didMerge = { _ in merges += 1 }
        XCTAssertTrue(arm(model))
        isBlocked = true
        await settle(model)

        XCTAssertEqual(model.mergeWait.ending, .merged(nil))
        XCTAssertEqual(merges, 0)
        XCTAssertEqual(cli.count(for: mergeArguments(oid: "abc123")), 0)
        XCTAssertEqual(model.mergeMessage, PullRequestModel.mergeBlockedMessage)
        XCTAssertFalse(model.mergeWait.isArmed)
    }
}
