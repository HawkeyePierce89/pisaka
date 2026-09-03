import XCTest
@testable import PisakaCore

/// The reader's whole read path: what a refresh asks, in what order, and what it
/// is allowed to publish.
///
/// Five properties carry the suite, and each of them is a rule that would fail
/// silently in production if it broke:
///
/// - **Availability is re-probed on every refresh and never more often.** `gh`
///   can be installed, upgraded or signed out from the embedded terminal between
///   two glances at the panel, and there is no event for any of it. The
///   assertions count the probes against the refreshes rather than asserting a
///   state, because the state would look right the moment after a stale one was
///   cached.
/// - **A superseded answer publishes nothing.** Staged with a `Gate` per key so
///   the race is causal — the second refresh starts *in the window* the first is
///   suspended in — never with a sleep.
/// - **A failure never blanks a good list.** Asserted as "the previous rows are
///   still there *and* the message is new", which is the pair that catches a
///   parser that started returning `[]` on a schema change.
/// - **`pr checks` is judged on stdout parsing, not on its exit status.** Exit 8
///   ("checks pending") and exit 1 ("some check failed") both print the JSON
///   this parses, so both are driven through as ordinary answers.
/// - **An empty `--head` array is "no pull request".** Most branches have none;
///   a model that read that as a failure would put a red sentence under every
///   ordinary branch.
///
/// Nothing here runs `gh`: every answer comes from `ScriptedGitHubCLI`, and the
/// fixtures are the same recorded `gh version 2.99.0` output `GitHubAPITests`
/// parses.
@MainActor
final class PullRequestModelTests: XCTestCase {

    // MARK: - Fixtures

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private static let fixtures = repositoryRoot
        .appendingPathComponent("Tests/PisakaCoreTests/Fixtures/github")

    private func fixture(_ name: String) throws -> String {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private let root = URL(fileURLWithPath: "/tmp/pisaka-github")

    private func makeModel(
        _ cli: ScriptedGitHubCLI,
        git: StubGit = StubGit(),
        isWriteBlocked: @escaping @MainActor () -> Bool = { false }
    ) -> PullRequestModel {
        let root = root
        return PullRequestModel(
            transport: cli,
            gitService: git,
            root: { root },
            isWriteBlocked: isWriteBlocked
        )
    }

    /// The one thing the model asks git for: the commit context the create
    /// plan's refusals are decided from, and the push that runs before
    /// `pr create`.
    ///
    /// Deliberately tiny — `GitServicing`'s protocol extension defaults the
    /// other twenty-odd members to `throw GitError.gitUnavailable`, so anything
    /// this feature reached for that is not one of these two would fail as a
    /// failure rather than answer emptiness.
    private final class StubGit: GitServicing {
        var context = CommitContext(
            isUnbornHEAD: false,
            isDetachedHEAD: false,
            currentBranch: "feature",
            upstream: "origin/feature",
            remotes: ["origin"],
            inProgress: nil
        )
        var contextError: Error?
        /// Runs *inside* `commitContext`, so a test can stage what lands while
        /// the create flow is suspended over it — the several-subprocess read is
        /// the window a branch switch is actually started in.
        var onContext: (@Sendable () -> Void)?
        var pushError: Error?
        /// Every plan handed to `push`, in call order.
        var pushedPlans: [PushPlan] = []
        /// Runs *inside* `push`, so a test can assert what has and has not been
        /// sent to `gh` at the moment the push is still in flight.
        var onPush: (@Sendable () -> Void)?
        /// Holds `push` until released — the window a test reads the write flag
        /// in from the main actor, which is free while the push blocks a
        /// cooperative-pool thread.
        var pushGate: Gate?

        func repositoryRoot(for url: URL) async throws -> URL { url }

        // The four members `GitServicing` does not default. None of them is
        // reachable from this feature; each answers the emptiest honest thing so
        // a stray call shows up as an empty answer rather than as a compile
        // error nobody reads.
        func changedFiles(root: URL) async throws -> [ChangedFile] { [] }
        func commits(filter: LogFilter, limit: Int, root: URL) async throws -> [Commit] { [] }
        func headContents(of path: String, root: URL) async throws -> String? { nil }
        func revert(_ file: ChangedFile, root: URL) async throws {}

        func commitContext(root: URL) async throws -> CommitContext {
            if let contextError { throw contextError }
            onContext?()
            return context
        }

        func push(_ plan: PushPlan, root: URL) async throws {
            pushedPlans.append(plan)
            onPush?()
            pushGate?.wait()
            if let pushError { throw pushError }
        }
    }

    /// The list command's own argument list, which is also its script key.
    private var listArguments: [String] { GitHubCommands.openPullRequests(root: root).arguments }

    private func headArguments(_ branch: String) -> [String] {
        GitHubCommands.pullRequest(forHeadBranch: branch, root: root).arguments
    }

    private func checksArguments(_ number: Int) -> [String] {
        GitHubCommands.checks(pullRequest: number, root: root).arguments
    }

    /// One open pull request, built by hand so a test can assert a list it did
    /// not have to record.
    private func listJSON(
        number: Int,
        head: String,
        title: String = "A change",
        rollup: String = "[]"
    ) -> String {
        """
        [{"number":\(number),"title":"\(title)","author":{"login":"someone"},
        "headRefName":"\(head)","baseRefName":"master","isDraft":false,
        "reviewDecision":"","url":"https://github.com/o/r/pull/\(number)",
        "state":"OPEN","statusCheckRollup":\(rollup)}]
        """
    }

    /// A one-job rollup, so a hand-built row claims checks and its expand is
    /// therefore expected to answer with jobs.
    private let runningRollup = """
    [{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":""}]
    """

    // MARK: - Availability

    func testRefreshWithoutGHReportsNotInstalledAndNeverAsksAnythingElse() async {
        let cli = ScriptedGitHubCLI()
        cli.fail(GitHubCommands.version(), with: GitHubCLIError.notInstalled)
        let model = makeModel(cli)

        await model.refresh(branch: "feature")

        XCTAssertEqual(model.availability, .notInstalled)
        XCTAssertFalse(model.isReady)
        // The version already settled it, so the sign-in is never asked and
        // neither is the list.
        XCTAssertEqual(cli.argumentLists, [["--version"]])
        // The state's own sentence says it in full; a second one would be noise.
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    func testTooOldGHIsRefusedBeforeTheSignInIsAsked() async {
        let cli = ScriptedGitHubCLI()
        cli.serve(GitHubCommands.version(), stdout: "gh version 2.49.9 (2024-05-01)\n")
        let model = makeModel(cli)

        await model.refresh(branch: "feature")

        XCTAssertEqual(
            model.availability,
            .tooOld(found: GitHubVersion(major: 2, minor: 49, patch: 9), minimum: GitHubVersion.minimum)
        )
        XCTAssertEqual(cli.argumentLists, [["--version"]])
    }

    func testSignedOutGHIsReportedAndNothingIsListed() async {
        let cli = ScriptedGitHubCLI()
        cli.serve(GitHubCommands.version(), stdout: "gh version 2.99.0 (2026-09-01)\n")
        cli.serve(GitHubCommands.authStatus(), stderr: "You are not logged into any GitHub hosts.\n", status: 1)
        let model = makeModel(cli)

        await model.refresh(branch: "feature")

        XCTAssertEqual(model.availability, .notSignedIn)
        XCTAssertEqual(cli.trace, ["--version", "auth status"])
        XCTAssertTrue(model.pullRequests.isEmpty)
    }

    func testAuthStatusIsJudgedByExitStatusAloneEvenWhenItWritesToStderr() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serve(GitHubCommands.version(), stdout: "gh version 2.99.0 (2026-09-01)\n")
        // `gh auth status` puts its *success* prose on stderr too. Reading the
        // text rather than the status would call this a failure.
        cli.serve(GitHubCommands.authStatus(), stderr: "github.com\n  ✓ Logged in to github.com\n", status: 0)
        cli.serve(listArguments, stdout: try fixture("pr-list-empty.json"))
        cli.serve(headArguments("feature"), stdout: "[]")
        let model = makeModel(cli)

        await model.refresh(branch: "feature")

        XCTAssertEqual(model.availability, .ready(version: GitHubVersion(major: 2, minor: 99, patch: 0)))
        XCTAssertNil(model.errorMessage)
    }

    func testAvailabilityIsReProbedOnEveryRefreshAndNotOtherwise() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-empty.json"))
        let model = makeModel(cli)

        await model.refresh(branch: nil)
        await model.refresh(branch: nil)
        await model.refresh(branch: nil)

        XCTAssertEqual(cli.count(for: GitHubCommands.version()), 3)
        XCTAssertEqual(cli.count(for: GitHubCommands.authStatus()), 3)

        // Expanding a row is not a refresh: it re-probes nothing.
        cli.serve(listArguments, stdout: listJSON(number: 7, head: "feature"))
        await model.refresh(branch: nil)
        cli.serve(checksArguments(7), stdout: try fixture("pr-checks.json"))
        await model.expand(7)

        XCTAssertEqual(cli.count(for: GitHubCommands.version()), 4)
        XCTAssertEqual(cli.count(for: GitHubCommands.authStatus()), 4)
        XCTAssertEqual(cli.count(for: checksArguments(7)), 1)
    }

    func testAGHThatBecomesSignedOutClearsTheRowsItHadListed() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serve(GitHubCommands.version(), stdout: "gh version 2.99.0 (2026-09-01)\n")
        cli.serve(GitHubCommands.authStatus(), sequence: [
            GitHubCommandResult(status: 0),
            GitHubCommandResult(standardError: "not logged in", status: 1),
        ])
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.serve(headArguments("feature"), stdout: "[]")
        let model = makeModel(cli)

        await model.refresh(branch: "feature")
        XCTAssertEqual(model.pullRequests.map(\.number), [53])

        await model.refresh(branch: "feature")

        // The stated exception to "a failure never blanks a good list": this is
        // a different world, not a failed read.
        XCTAssertEqual(model.availability, .notSignedIn)
        XCTAssertTrue(model.pullRequests.isEmpty)
    }

    func testATimedOutVersionProbeShowsTheTransportsOwnSentenceBesideTheState() async {
        let cli = ScriptedGitHubCLI()
        cli.fail(GitHubCommands.version(), with: GitHubCLIError.timedOut(seconds: 15))
        let model = makeModel(cli)

        await model.refresh(branch: nil)

        XCTAssertEqual(model.availability, .notInstalled)
        XCTAssertEqual(model.errorMessage, "The GitHub CLI did not answer within 15 seconds.")
    }

    // MARK: - The list

    func testARefreshListsTheOpenPullRequestsAndTheCurrentBranchsOwn() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.serve(
            headArguments("database-viewer-part-2b-sql-console"),
            stdout: try fixture("pr-list-merged.json")
        )
        let model = makeModel(cli)

        await model.refresh(branch: "database-viewer-part-2b-sql-console")

        XCTAssertEqual(model.pullRequests.map(\.number), [53])
        XCTAssertEqual(model.pullRequests.first?.summary, .success)
        XCTAssertEqual(model.currentBranchPullRequest?.number, 53)
        XCTAssertEqual(cli.trace, ["--version", "auth status", "pr list", "pr list"])
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    func testEveryCommandRunsInTheRepositoryRootExceptTheTwoProbes() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.serve(headArguments("feature"), stdout: "[]")
        cli.serve(checksArguments(53), stdout: try fixture("pr-checks.json"))
        let model = makeModel(cli)

        await model.refresh(branch: "feature")
        await model.expand(53)

        let directories = cli.commands.map(\.workingDirectory)
        // `--version` and `auth status` are about the binary and the account,
        // not about a repository; everything else resolves `owner/repo` from the
        // remote of the directory it runs in, which is why no `--repo` exists.
        XCTAssertEqual(directories, [nil, nil, root, root, root])
    }

    func testAnEmptyHeadArrayIsNoPullRequestAndNotAnError() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.serve(headArguments("no-pr-branch"), stdout: "[]\n")
        let model = makeModel(cli)

        await model.refresh(branch: "no-pr-branch")

        XCTAssertNil(model.currentBranchPullRequest)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.pullRequests.map(\.number), [53])
    }

    func testADetachedHEADNeverAsksForAHeadBranchAtAll() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        let model = makeModel(cli)

        await model.refresh(branch: nil)

        XCTAssertEqual(cli.trace, ["--version", "auth status", "pr list"])
        XCTAssertNil(model.currentBranchPullRequest)
        XCTAssertNil(model.errorMessage)
    }

    func testTheCurrentBranchsPullRequestIsForgottenWhenTheBranchNoLongerHasOne() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.serve(headArguments("feature"), stdout: try fixture("pr-list-merged.json"))
        cli.serve(headArguments("master"), stdout: "[]")
        let model = makeModel(cli)

        await model.refresh(branch: "feature")
        XCTAssertEqual(model.currentBranchPullRequest?.number, 53)

        await model.refresh(branch: "master")
        XCTAssertNil(model.currentBranchPullRequest)
    }

    func testNoProjectRootAsksNothingAndDecidesNoAvailability() async {
        let cli = ScriptedGitHubCLI()
        let model = PullRequestModel(transport: cli, gitService: StubGit(), root: { nil })

        await model.refresh(branch: "feature")

        XCTAssertNil(model.availability)
        XCTAssertTrue(cli.commands.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    // MARK: - A failure never blanks a good list

    func testAFailedListKeepsThePreviousRowsAndAddsGHsOwnSentence() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, sequence: [
            GitHubCommandResult(standardOutput: try fixture("pr-list-merged.json")),
            GitHubCommandResult(standardError: "could not resolve to a Repository\n", status: 1),
        ])
        cli.serve(headArguments("feature"), stdout: "[]")
        let model = makeModel(cli)

        await model.refresh(branch: "feature")
        XCTAssertEqual(model.pullRequests.map(\.number), [53])

        await model.refresh(branch: "feature")

        XCTAssertEqual(model.pullRequests.map(\.number), [53])
        XCTAssertEqual(model.errorMessage, "could not resolve to a Repository")
        XCTAssertFalse(model.isLoading)
    }

    func testANonZeroExitWithNothingOnStderrStillNamesItsStatus() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, status: 4)
        let model = makeModel(cli)

        await model.refresh(branch: nil)

        XCTAssertEqual(model.errorMessage, "The GitHub CLI exited with status 4.")
    }

    func testASchemaRefusalSurfacesAsTheTypedErrorsSentenceNamingTheKeyPath() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-unknown-conclusion.json"))
        let model = makeModel(cli)

        await model.refresh(branch: nil)

        let expected = GitHubSchemaError.unknownValue(
            keyPath: "pr list[0].statusCheckRollup[0].conclusion",
            value: "TELEPORTED"
        )
        XCTAssertEqual(model.errorMessage, expected.errorDescription)
        XCTAssertTrue(model.pullRequests.isEmpty)
    }

    func testAFailedHeadLookupKeepsTheListItJustRead() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.serve(headArguments("feature"), stderr: "network is unreachable\n", status: 1)
        let model = makeModel(cli)

        await model.refresh(branch: "feature")

        XCTAssertEqual(model.pullRequests.map(\.number), [53])
        XCTAssertEqual(model.errorMessage, "network is unreachable")
    }

    func testAFailedHeadLookupForgetsThePreviousBranchsPullRequest() async throws {
        // The one value here that is scoped to a *branch* rather than to the
        // repository, so the one the "a failure never blanks a good answer" rule
        // cannot keep: left standing after a branch change whose `--head` lookup
        // failed, it makes the bottom-bar indicator assert the pull request of
        // the branch the user just *left* — with no message slot of its own to
        // qualify it, and a click opening the panel on a row this branch never
        // opened.
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.serve(headArguments("feature"), stdout: try fixture("pr-list-merged.json"))
        cli.serve(headArguments("other"), stderr: "network is unreachable\n", status: 1)
        let model = makeModel(cli)

        await model.refresh(branch: "feature")
        XCTAssertEqual(model.currentBranchPullRequest?.number, 53)

        await model.refresh(branch: "other")

        XCTAssertNil(
            model.currentBranchPullRequest,
            "A `--head other` that failed says nothing about `other`, and certainly not that it has "
                + "`feature`'s pull request open."
        )
        XCTAssertEqual(
            model.pullRequests.map(\.number),
            [53],
            "The list is the repository's, not the branch's, so the rule still keeps it."
        )
        XCTAssertEqual(model.errorMessage, "network is unreachable")
    }

    func testAThrownHeadLookupAlsoForgetsThePreviousBranchsPullRequest() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.serve(headArguments("feature"), stdout: try fixture("pr-list-merged.json"))
        let model = makeModel(cli)

        await model.refresh(branch: "feature")
        XCTAssertEqual(model.currentBranchPullRequest?.number, 53)

        cli.fail(headArguments("other"), with: GitHubCLIError.timedOut(seconds: 30))
        await model.refresh(branch: "other")

        XCTAssertNil(model.currentBranchPullRequest)
        XCTAssertEqual(model.pullRequests.map(\.number), [53])
    }

    func testASuccessfulRefreshClearsItsOwnPreviousMessage() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, sequence: [
            GitHubCommandResult(standardError: "boom\n", status: 1),
            GitHubCommandResult(standardOutput: try fixture("pr-list-merged.json")),
        ])
        let model = makeModel(cli)

        await model.refresh(branch: nil)
        XCTAssertEqual(model.errorMessage, "boom")

        await model.refresh(branch: nil)
        XCTAssertNil(model.errorMessage)
    }

    func testARefreshDoesNotClearAChecksFailuresSentence() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: listJSON(number: 7, head: "feature", rollup: runningRollup))
        cli.serve(headArguments("feature"), stdout: "[]")
        cli.serve(checksArguments(7), stderr: "the server is having a moment\n", status: 1)
        let model = makeModel(cli)

        await model.refresh(branch: "feature")
        await model.expand(7)
        XCTAssertEqual(model.errorMessage, "the server is having a moment")

        // The refresh succeeded, but it has nothing to say about the expand that
        // failed — the sentence under the open row is the only explanation the
        // reader has for its empty jobs list.
        await model.refresh(branch: "feature")
        XCTAssertEqual(model.errorMessage, "the server is having a moment")
    }

    // MARK: - The checks list

    func testExpandingARowReadsItsChecksAndCollapsingForgetsNothing() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.serve(checksArguments(53), stdout: try fixture("pr-checks.json"))
        let model = makeModel(cli)

        await model.refresh(branch: nil)
        await model.expand(53)

        XCTAssertEqual(model.expandedNumber, 53)
        XCTAssertEqual(model.checks[53]?.map(\.name), ["build-macos", "build-ios", "lint", "test"])
        XCTAssertEqual(model.checks[53]?.first?.bucket, .pass)

        await model.expand(nil)
        XCTAssertNil(model.expandedNumber)
        // The rows stay cached: re-expanding must not blank the list while the
        // network answers again.
        XCTAssertEqual(model.checks[53]?.count, 4)
        XCTAssertEqual(cli.count(for: checksArguments(53)), 1)
    }

    /// One job, so a test can tell two answers to the same `pr checks` apart.
    private func checksJSON(name: String, bucket: String, state: String) -> String {
        """
        [{"bucket":"\(bucket)","completedAt":"","description":"","event":"pull_request",
        "link":"https://github.com/o/r/runs/1","name":"\(name)","startedAt":"2026-09-02T19:19:39Z",
        "state":"\(state)","workflow":"CI"}]
        """
    }

    /// The badge and the jobs underneath it are read by two different commands,
    /// and a refresh that re-read only the first would leave them contradicting
    /// each other on screen — a green summary over a list still saying
    /// "pending", with Refresh appearing to do nothing to the detail the reader
    /// is actually watching.
    func testARefreshReReadsTheExpandedRowsJobs() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        let passingRollup = """
        [{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]
        """
        cli.serve(listArguments, sequence: [
            GitHubCommandResult(standardOutput: listJSON(number: 7, head: "feature", rollup: runningRollup)),
            GitHubCommandResult(standardOutput: listJSON(number: 7, head: "feature", rollup: passingRollup)),
        ])
        cli.serve(checksArguments(7), sequence: [
            GitHubCommandResult(standardOutput: checksJSON(name: "test", bucket: "pending", state: "PENDING")),
            GitHubCommandResult(standardOutput: checksJSON(name: "test", bucket: "pass", state: "SUCCESS")),
        ])
        let model = makeModel(cli)

        await model.refresh(branch: nil)
        await model.expand(7)
        XCTAssertEqual(model.checks[7]?.first?.bucket, .pending)
        XCTAssertEqual(model.pullRequests.first?.summary, .pending)

        // CI finished between the two glances at the panel.
        await model.refresh(branch: nil)

        XCTAssertEqual(model.pullRequests.first?.summary, .success)
        XCTAssertEqual(model.checks[7]?.first?.bucket, .pass, "the jobs are re-read with the badge above them")
        XCTAssertEqual(cli.count(for: checksArguments(7)), 2)
        XCTAssertEqual(model.expandedNumber, 7)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    /// The re-read is scoped to a row that is still both expanded and open: a
    /// collapsed panel costs a refresh nothing, and a row `pruneChecks` has just
    /// collapsed is not read for.
    func testARefreshReadsNoJobsWhenNoRowIsExpanded() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, sequence: [
            GitHubCommandResult(standardOutput: listJSON(number: 7, head: "feature", rollup: runningRollup)),
            GitHubCommandResult(standardOutput: "[]"),
        ])
        cli.serve(checksArguments(7), stdout: checksJSON(name: "test", bucket: "pending", state: "PENDING"))
        let model = makeModel(cli)

        await model.refresh(branch: nil)
        await model.refresh(branch: nil)
        XCTAssertEqual(cli.count(for: checksArguments(7)), 0)

        // And a row that was expanded but has since been merged away is
        // collapsed by `pruneChecks` before the re-read is considered.
        let second = ScriptedGitHubCLI()
        second.serveReady()
        second.serve(listArguments, sequence: [
            GitHubCommandResult(standardOutput: listJSON(number: 7, head: "feature", rollup: runningRollup)),
            GitHubCommandResult(standardOutput: "[]"),
        ])
        second.serve(checksArguments(7), stdout: checksJSON(name: "test", bucket: "pending", state: "PENDING"))
        let closing = makeModel(second)
        await closing.refresh(branch: nil)
        await closing.expand(7)
        await closing.refresh(branch: nil)

        XCTAssertNil(closing.expandedNumber)
        XCTAssertEqual(second.count(for: checksArguments(7)), 1, "the row closed, so nothing is read for it")
    }

    func testToggleExpansionOpensThenCloses() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.serve(checksArguments(53), stdout: try fixture("pr-checks.json"))
        let model = makeModel(cli)

        await model.refresh(branch: nil)
        await model.toggleExpansion(53)
        XCTAssertEqual(model.expandedNumber, 53)

        await model.toggleExpansion(53)
        XCTAssertNil(model.expandedNumber)
    }

    /// `gh pr checks` documents exit 8 for "checks pending" and uses exit 1 for
    /// "some check failed" — and prints the JSON either way. The status is not
    /// read; the parse is.
    func testChecksExitEightAndExitOneStillParse() async throws {
        for status: Int32 in [8, 1] {
            let cli = ScriptedGitHubCLI()
            cli.serveReady()
            cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
            cli.serve(checksArguments(53), stdout: try fixture("pr-checks.json"), status: status)
            let model = makeModel(cli)

            await model.refresh(branch: nil)
            await model.expand(53)

            XCTAssertEqual(model.checks[53]?.count, 4, "exit \(status)")
            XCTAssertNil(model.errorMessage, "exit \(status)")
        }
    }

    func testChecksWithNoJSONAtAllShowsGHsOwnSentenceAndKeepsWhatWasThere() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.serve(checksArguments(53), sequence: [
            GitHubCommandResult(standardOutput: try fixture("pr-checks.json")),
            GitHubCommandResult(standardError: "no checks reported\n", status: 1),
        ])
        let model = makeModel(cli)

        await model.refresh(branch: nil)
        await model.expand(53)
        XCTAssertEqual(model.checks[53]?.count, 4)

        await model.expand(nil)
        await model.expand(53)

        XCTAssertEqual(model.errorMessage, "no checks reported")
        XCTAssertEqual(model.checks[53]?.count, 4)
    }

    func testAPullRequestWithNoChecksAnswersAnEmptyListRatherThanAFailure() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        // An empty rollup, so the row's own summary is `.noChecks`…
        cli.serve(listArguments, stdout: listJSON(number: 7, head: "feature"))
        cli.serve(headArguments("feature"), stdout: "[]")
        // …and `gh pr checks` answers a pull request without CI the only way it
        // can: non-zero, a sentence on stderr and no JSON at all.
        cli.serve(checksArguments(7), stderr: "no checks reported on the 'feature' branch\n", status: 1)
        let model = makeModel(cli)

        await model.refresh(branch: "feature")
        XCTAssertEqual(model.pullRequests.first?.summary, .noChecks)

        await model.expand(7)

        // The empty list the panel has a state for — not the spinner of an
        // unset entry, and not the failure of a row that could not be read.
        XCTAssertEqual(model.checks[7], [])
        XCTAssertFalse(model.checksFailures.contains(7))
        XCTAssertNil(model.errorMessage)
    }

    func testAnEmptyChecksAnswerIsStillAFailureWhenTheRowClaimsChecks() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        // The row says a job is running, so `gh` printing nothing is `gh`
        // declining to answer and not the shape above.
        cli.serve(listArguments, stdout: listJSON(number: 7, head: "feature", rollup: runningRollup))
        cli.serve(headArguments("feature"), stdout: "[]")
        cli.serve(checksArguments(7), stderr: "could not reach github.com\n", status: 1)
        let model = makeModel(cli)

        await model.refresh(branch: "feature")
        await model.expand(7)

        XCTAssertNil(model.checks[7])
        XCTAssertTrue(model.checksFailures.contains(7))
        XCTAssertEqual(model.errorMessage, "could not reach github.com")
    }

    func testReExpandingARowDropsThePreviousReadsFailureBeforeReadingAgain() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.fail(checksArguments(53), with: GitHubCLIError.timedOut(seconds: 30))
        let model = makeModel(cli)
        await model.refresh(branch: nil)

        await model.expand(53)
        XCTAssertTrue(model.checksFailures.contains(53))

        // The read is held open, so the assertion lands while the *new* read is
        // in flight: the row may not go on claiming the old read's failure for
        // the whole of it, or "could not read checks" would outlive its reason.
        let gate = Gate()
        cli.hold(checksArguments(53), on: gate, forCall: 1)
        await model.expand(nil)
        let expanding = Task { await model.expand(53) }
        await gate.waitUntilReached()
        XCTAssertFalse(model.checksFailures.contains(53))
        gate.release()
        await expanding.value

        // …and the second read failed too, so it says so again on its own.
        XCTAssertTrue(model.checksFailures.contains(53))
    }

    func testChecksThatDidNotParseNameTheKeyPath() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.serve(checksArguments(53), stdout: """
        [{"bucket":"ascended","completedAt":"","description":"","event":"push","link":"",
        "name":"x","startedAt":"","state":"SUCCESS","workflow":"CI"}]
        """)
        let model = makeModel(cli)

        await model.refresh(branch: nil)
        await model.expand(53)

        let message = try XCTUnwrap(model.errorMessage)
        XCTAssertTrue(message.contains("pr checks[0].bucket"), message)
        XCTAssertNil(model.checks[53])
        // …and the row is told, so it stops claiming it is still reading.
        XCTAssertTrue(model.checksFailures.contains(53))
    }

    func testAChecksFailureIsRecordedAgainstItsRowAndClearedByASuccess() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.serve(checksArguments(53), sequence: [
            GitHubCommandResult(standardError: "no checks reported on the 'feature' branch\n", status: 1),
            GitHubCommandResult(standardOutput: try fixture("pr-checks.json")),
        ])
        let model = makeModel(cli)
        await model.refresh(branch: nil)

        await model.expand(53)
        // `checks[53]` is still unset, which is what the row would draw a
        // never-ending spinner from; the failure set is the third answer.
        XCTAssertNil(model.checks[53])
        XCTAssertTrue(model.checksFailures.contains(53))
        XCTAssertEqual(model.errorMessage, "no checks reported on the 'feature' branch")

        await model.expand(nil)
        await model.expand(53)

        XCTAssertNotNil(model.checks[53])
        XCTAssertFalse(model.checksFailures.contains(53))
    }

    func testAThrownChecksReadIsRecordedAgainstItsRow() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.fail(checksArguments(53), with: GitHubCLIError.timedOut(seconds: 30))
        let model = makeModel(cli)
        await model.refresh(branch: nil)

        await model.expand(53)

        XCTAssertNil(model.checks[53])
        XCTAssertTrue(model.checksFailures.contains(53))
    }

    func testAClosedPullRequestsChecksAreDroppedByTheNextRefresh() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, sequence: [
            GitHubCommandResult(standardOutput: try fixture("pr-list-merged.json")),
            GitHubCommandResult(standardOutput: "[]"),
        ])
        cli.serve(checksArguments(53), stdout: try fixture("pr-checks.json"))
        let model = makeModel(cli)

        await model.refresh(branch: nil)
        await model.expand(53)
        XCTAssertEqual(model.expandedNumber, 53)

        await model.refresh(branch: nil)

        XCTAssertNil(model.checks[53])
        XCTAssertNil(model.expandedNumber)
        XCTAssertFalse(model.checksFailures.contains(53))
    }

    func testExpandingIsRefusedWhileGHIsNotReady() async {
        let cli = ScriptedGitHubCLI()
        cli.fail(GitHubCommands.version(), with: GitHubCLIError.notInstalled)
        let model = makeModel(cli)

        await model.refresh(branch: nil)
        await model.expand(53)

        XCTAssertEqual(cli.argumentLists, [["--version"]])
        XCTAssertNil(model.checks[53])
    }

    func testExpandingWhileGHIsNotReadyRecordsNoExpansionRatherThanASpinner() async {
        let cli = ScriptedGitHubCLI()
        cli.fail(GitHubCommands.version(), with: GitHubCLIError.notInstalled)
        let model = makeModel(cli)
        await model.refresh(branch: nil)
        XCTAssertFalse(model.isReady)

        await model.expand(7)

        // The panel draws a row whose checks are neither loaded nor failed as
        // "Reading checks…", so an expansion recorded for a read the guard
        // refused to send would spin for a command nobody ran.
        XCTAssertNil(model.expandedNumber)
        XCTAssertNil(model.checks[7])
        XCTAssertEqual(cli.count(for: checksArguments(7)), 0)
    }

    func testChecksLandingAfterTheRowsAreBlankedPublishNothing() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serve(GitHubCommands.version(), stdout: "gh version 2.99.0 (2026-09-01)\n")
        cli.serve(GitHubCommands.authStatus(), sequence: [
            GitHubCommandResult(standardError: "✓ Logged in\n"),
            GitHubCommandResult(standardError: "You are not logged into any GitHub hosts.\n", status: 1),
        ])
        cli.serve(listArguments, stdout: listJSON(number: 7, head: "feature", rollup: runningRollup))
        cli.serve(headArguments("feature"), stdout: "[]")
        let model = makeModel(cli)
        await model.refresh(branch: "feature")
        XCTAssertEqual(model.pullRequests.map(\.number), [7])

        // A checks read is suspended mid-flight…
        let gate = Gate()
        cli.hold(checksArguments(7), on: gate)
        cli.serve(checksArguments(7), stderr: "could not read checks", status: 1)
        let expanding = Task { await model.expand(7) }
        await gate.waitUntilReached()

        // …while a refresh finds a `gh` that is no longer signed in and blanks
        // everything the checks read was about.
        await model.refresh(branch: "feature")
        XCTAssertEqual(model.availability, .notSignedIn)
        XCTAssertNil(model.errorMessage)

        gate.release()
        await expanding.value

        // The blanking is a supersession like any other: the load that resumes
        // afterwards may publish neither its jobs nor — above all — its
        // sentence, which would sit in the one message slot contradicting the
        // not-ready state's own next step.
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.checks.isEmpty)
        XCTAssertNil(model.expandedNumber)
    }

    // MARK: - The two tokens

    /// The stale run must resume **last**, or the assertion is vacuous.
    ///
    /// Holding the whole key suspends both racers, and releasing twice resumes
    /// them in call order — so the stale answer publishes first and the fresh one
    /// lands on top of it regardless of any token. Only the first call is held
    /// here: the second refresh runs to completion while the first is still on
    /// the wire, and the first then resumes with nothing left to publish over.
    func testASupersededRefreshPublishesNothing() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, sequence: [
            GitHubCommandResult(standardOutput: try fixture("pr-list-merged.json")),
            GitHubCommandResult(standardOutput: listJSON(number: 99, head: "second")),
        ])
        let gate = Gate()
        cli.hold(listArguments, on: gate, forCall: 0)
        let model = makeModel(cli)

        let first = Task { await model.refresh(branch: nil) }
        await gate.waitUntilReached()

        // The second refresh starts *in the window* the first is suspended in,
        // which is what makes this a race rather than a sequence — and it is
        // awaited to completion here, so the stale run is the one that finishes
        // last.
        let second = Task { await model.refresh(branch: nil) }
        await second.value
        XCTAssertEqual(model.pullRequests.map(\.number), [99])

        gate.release()
        await first.value

        // The stale answer arrived after the fresh one and published nothing —
        // not its rows, not its loading flag. `[53]` is the fixture's number,
        // which is to say the stale run's distinctive value.
        XCTAssertEqual(model.pullRequests.map(\.number), [99])
        XCTAssertFalse(model.pullRequests.contains { $0.number == 53 })
        XCTAssertFalse(model.isLoading)
    }

    func testASupersededRefreshsFailureNeverReachesTheMessageSlot() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, sequence: [
            GitHubCommandResult(standardError: "the stale failure\n", status: 1),
            GitHubCommandResult(standardOutput: try fixture("pr-list-merged.json")),
        ])
        let gate = Gate()
        cli.hold(listArguments, on: gate, forCall: 0)
        let model = makeModel(cli)

        let first = Task { await model.refresh(branch: nil) }
        await gate.waitUntilReached()
        let second = Task { await model.refresh(branch: nil) }
        await second.value
        XCTAssertEqual(model.pullRequests.map(\.number), [53])

        // The failing run resumes after the successful one. Its sentence must
        // not reach the slot the fresh read just cleared.
        gate.release()
        await first.value

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.pullRequests.map(\.number), [53])
    }

    func testASupersededChecksLoadPublishesNothing() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.serve(checksArguments(53), stdout: try fixture("pr-checks.json"))
        let model = makeModel(cli)
        await model.refresh(branch: nil)

        let gate = Gate()
        cli.hold(checksArguments(53), on: gate)

        let expand = Task { await model.expand(53) }
        await gate.waitUntilReached()
        // The reader closed the row while its jobs were still on the wire.
        let collapse = Task { await model.expand(nil) }
        gate.release()
        await expand.value
        await collapse.value

        XCTAssertNil(model.expandedNumber)
        XCTAssertNil(model.checks[53])
    }

    func testTheTwoTokensAreCountedApart() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.serve(checksArguments(53), stdout: try fixture("pr-checks.json"))
        let model = makeModel(cli)
        await model.refresh(branch: nil)

        let gate = Gate()
        // Only the expand's own call is held: the refresh re-reads the expanded
        // row's jobs itself, and holding the key would suspend that read too —
        // on the main actor, with nobody left to release it.
        cli.hold(checksArguments(53), on: gate, forCall: 0)
        let expand = Task { await model.expand(53) }
        await gate.waitUntilReached()

        // A refresh finishing mid-expand must not cancel the *list*: one shared
        // token would drop these rows on the floor. It does supersede the checks
        // read, and replaces it with one of its own in the same breath — which is
        // what keeps the jobs agreeing with the badge above them — so the rows
        // are here either way, and the two tokens are still counted apart.
        await model.refresh(branch: nil)
        XCTAssertEqual(model.checks[53]?.count, 4)

        gate.release()
        await expand.value

        XCTAssertEqual(model.checks[53]?.count, 4)
        XCTAssertEqual(model.expandedNumber, 53)
    }

    // MARK: - The create flow

    private var repositoryArguments: [String] { GitHubCommands.repositoryView(root: root).arguments }

    private func createArguments(
        title: String = "A change",
        body: String = "Why.",
        base: String = "master",
        head: String = "feature",
        draft: Bool = false
    ) -> [String] {
        GitHubCommands.createPullRequest(
            title: title,
            body: body,
            base: base,
            head: head,
            draft: draft,
            root: root
        ).arguments
    }

    /// A ready model whose sheet has been prepared over `git`'s context.
    private func preparedModel(
        _ cli: ScriptedGitHubCLI,
        git: StubGit,
        repositoryJSON: String? = nil,
        isWriteBlocked: @escaping @MainActor () -> Bool = { false }
    ) async throws -> PullRequestModel {
        cli.serveReady()
        cli.serve(listArguments, stdout: "[]")
        // The refresh a successful create ends with re-asks the current
        // branch's lookup, so every create test needs it answered.
        cli.serve(headArguments("feature"), stdout: "[]")
        if let repositoryJSON {
            cli.serve(repositoryArguments, stdout: repositoryJSON)
        }
        let model = makeModel(cli, git: git, isWriteBlocked: isWriteBlocked)
        await model.refresh(branch: nil)
        await model.prepareCreate()
        return model
    }

    func testTheBaseDefaultComesFromRepoView() async throws {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        let model = try await preparedModel(cli, git: git, repositoryJSON: try fixture("repo-view.json"))

        XCTAssertEqual(model.repository?.defaultBranch, "master")
        XCTAssertEqual(model.repository?.nameWithOwner, "HawkeyePierce89/pisaka")
        XCTAssertEqual(model.createPlan?.base, "master")
        XCTAssertEqual(model.createPlan?.headBranch, "feature")
        XCTAssertTrue(model.createPlan?.canCreate == true)
        XCTAssertNil(model.errorMessage)
    }

    func testTheBaseIsAlwaysPassedExplicitly() async throws {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        let model = try await preparedModel(cli, git: git, repositoryJSON: try fixture("repo-view.json"))
        cli.serve(createArguments(), stdout: "https://github.com/o/r/pull/54\n")

        let created = await model.create(title: "A change", body: "Why.", base: "master", draft: false)
        XCTAssertTrue(created)

        // Never left to `gh`'s own default, which is the upstream repository's
        // branch for a fork — a different pull request from the one the sheet
        // described.
        let sent = try XCTUnwrap(cli.argumentLists.last { $0.contains("create") })
        let baseIndex = try XCTUnwrap(sent.firstIndex(of: "--base"))
        XCTAssertEqual(sent[baseIndex + 1], "master")
    }

    /// The head travels as an argument, pinned to the reading the plan was made
    /// from — not left to `gh`'s "whatever branch is checked out now" default.
    ///
    /// Staged as the race it exists for: the push is held while the repository
    /// moves to another branch, which is exactly what a reader who dismissed the
    /// sheet and used the branch widget does. The pull request must still be the
    /// one the sheet's sentence described, carrying the title and base typed for
    /// it, and never one opened from the branch that happens to be current when
    /// `pr create` finally runs.
    func testTheHeadIsPinnedToThePlanEvenIfTheBranchMovesDuringThePush() async throws {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        let model = try await preparedModel(cli, git: git, repositoryJSON: try fixture("repo-view.json"))
        cli.serve(createArguments(), stdout: "https://github.com/o/r/pull/54\n")

        let pushGate = Gate()
        git.pushGate = pushGate
        let create = Task {
            await model.create(title: "A change", body: "Why.", base: "master", draft: false)
        }

        // The branch moves while the push is on the wire. The push itself reads
        // nothing more from the context, and nothing after it re-reads the
        // repository — the head was decided before the first `await`.
        await pushGate.waitUntilReached()
        git.context = CommitContext(
            isUnbornHEAD: false,
            isDetachedHEAD: false,
            currentBranch: "unrelated",
            upstream: "origin/unrelated",
            remotes: ["origin"],
            inProgress: nil
        )
        pushGate.release()

        let created = await create.value
        XCTAssertTrue(created)

        let sent = try XCTUnwrap(cli.argumentLists.last { $0.contains("create") })
        let headIndex = try XCTUnwrap(sent.firstIndex(of: "--head"))
        XCTAssertEqual(sent[headIndex + 1], "feature")
    }

    func testARepoViewFailureDisablesCreate() async throws {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        cli.serveReady()
        cli.serve(listArguments, stdout: "[]")
        cli.serve(repositoryArguments, stderr: "could not determine base repository\n", status: 1)
        let model = makeModel(cli, git: git)
        await model.refresh(branch: nil)
        await model.prepareCreate()

        XCTAssertNil(model.repository)
        XCTAssertEqual(model.createPlan?.base, "")
        XCTAssertFalse(model.createPlan?.canCreate == true)
        // `gh`'s own words, and no second sentence invented beside them.
        XCTAssertEqual(model.errorMessage, "could not determine base repository")
        XCTAssertNil(model.createPlan?.refusal)

        // And the write refuses on the same rule the disabled button reads.
        let refused = await model.create(title: "A change", body: "Why.", base: "", draft: false)
        XCTAssertFalse(refused)
        XCTAssertFalse(cli.argumentLists.contains { $0.contains("create") })
    }

    func testDetachedHEADRefusesWithTheCommitDialogsOwnSentence() async throws {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        git.context = CommitContext(
            isUnbornHEAD: false,
            isDetachedHEAD: true,
            currentBranch: nil,
            upstream: nil,
            remotes: ["origin"],
            inProgress: nil
        )
        let model = try await preparedModel(cli, git: git, repositoryJSON: try fixture("repo-view.json"))

        XCTAssertEqual(model.createPlan?.refusal, .detachedHEAD)
        let refused = await model.create(title: "A change", body: "Why.", base: "master", draft: false)
        XCTAssertFalse(refused)

        XCTAssertEqual(model.errorMessage, PushUnavailableReason.detachedHEAD.message)
        XCTAssertTrue(git.pushedPlans.isEmpty)
        XCTAssertFalse(cli.argumentLists.contains { $0.contains("create") })
    }

    func testNoRemoteRefusesWithTheCommitDialogsOwnSentence() async throws {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        git.context = CommitContext(
            isUnbornHEAD: false,
            isDetachedHEAD: false,
            currentBranch: "feature",
            upstream: nil,
            remotes: [],
            inProgress: nil
        )
        let model = try await preparedModel(cli, git: git, repositoryJSON: try fixture("repo-view.json"))

        XCTAssertEqual(model.createPlan?.refusal, .noRemote)
        let refused = await model.create(title: "A change", body: "Why.", base: "master", draft: false)
        XCTAssertFalse(refused)

        XCTAssertEqual(model.errorMessage, PushUnavailableReason.noRemote.message)
        XCTAssertTrue(git.pushedPlans.isEmpty)
        XCTAssertFalse(cli.argumentLists.contains { $0.contains("create") })
    }

    func testThePushRunsBeforeCreateOnAnUpstreamBranch() async throws {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        let model = try await preparedModel(cli, git: git, repositoryJSON: try fixture("repo-view.json"))
        cli.serve(createArguments(), stdout: "https://github.com/o/r/pull/54\n")

        var sentWhenPushRan: [[String]] = []
        git.onPush = { [weak cli] in sentWhenPushRan = cli?.argumentLists ?? [] }

        let created = await model.create(title: "A change", body: "Why.", base: "master", draft: false)
        XCTAssertTrue(created)

        XCTAssertEqual(git.pushedPlans, [.push(upstream: "origin/feature")])
        // Read out of the log rather than out of a flag: at the moment the push
        // was running, nothing had been sent to `gh pr create` yet.
        XCTAssertFalse(sentWhenPushRan.contains { $0.contains("create") })
        XCTAssertTrue(cli.argumentLists.contains { $0.contains("create") })
    }

    func testThePushRunsBeforeCreateOnASetUpstreamBranch() async throws {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        git.context = CommitContext(
            isUnbornHEAD: false,
            isDetachedHEAD: false,
            currentBranch: "feature",
            upstream: nil,
            remotes: ["origin"],
            inProgress: nil
        )
        let model = try await preparedModel(cli, git: git, repositoryJSON: try fixture("repo-view.json"))
        cli.serve(createArguments(), stdout: "https://github.com/o/r/pull/54\n")

        var sentWhenPushRan: [[String]] = []
        git.onPush = { [weak cli] in sentWhenPushRan = cli?.argumentLists ?? [] }

        let created = await model.create(title: "A change", body: "Why.", base: "master", draft: false)
        XCTAssertTrue(created)

        XCTAssertEqual(git.pushedPlans, [.setUpstream(remote: "origin", branch: "feature")])
        XCTAssertFalse(sentWhenPushRan.contains { $0.contains("create") })
        XCTAssertTrue(cli.argumentLists.contains { $0.contains("create") })
    }

    func testAPushFailureNeverReachesCreate() async throws {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        git.pushError = GitError.pushFailed(reason: "rejected: non-fast-forward")
        let model = try await preparedModel(cli, git: git, repositoryJSON: try fixture("repo-view.json"))

        let refused = await model.create(title: "A change", body: "Why.", base: "master", draft: false)
        XCTAssertFalse(refused)

        XCTAssertEqual(git.pushedPlans.count, 1)
        // The difference between "nothing happened" and a pull request opened
        // against commits the remote has never seen.
        XCTAssertFalse(cli.argumentLists.contains { $0.contains("create") })
        XCTAssertEqual(model.errorMessage, GitError.pushFailed(reason: "rejected: non-fast-forward").errorDescription)
    }

    func testTheNewNumberIsParsedFromTheURLAndTheRowSelected() async throws {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        let model = try await preparedModel(cli, git: git, repositoryJSON: try fixture("repo-view.json"))
        cli.serve(
            createArguments(),
            stdout: """
            Creating pull request for feature into master in o/r

            https://github.com/o/r/pull/54
            """
        )
        // The refresh that follows lists the new row, which is what the
        // selection points into.
        cli.serve(listArguments, stdout: listJSON(number: 54, head: "feature"))
        cli.serve(headArguments("feature"), stdout: listJSON(number: 54, head: "feature"))

        let created = await model.create(title: "A change", body: "Why.", base: "master", draft: false)
        XCTAssertTrue(created)

        XCTAssertEqual(model.selectedNumber, 54)
        XCTAssertEqual(model.pullRequests.map(\.number), [54])
        XCTAssertNil(model.errorMessage)
    }

    func testADraftPullRequestCarriesTheDraftFlag() async throws {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        let model = try await preparedModel(cli, git: git, repositoryJSON: try fixture("repo-view.json"))
        cli.serve(createArguments(draft: true), stdout: "https://github.com/o/r/pull/54\n")

        let created = await model.create(title: "A change", body: "Why.", base: "master", draft: true)
        XCTAssertTrue(created)

        let sent = try XCTUnwrap(cli.argumentLists.last { $0.contains("create") })
        XCTAssertTrue(sent.contains("--draft"))
    }

    func testACreateFailurePublishesGhsWordsAndCreatesNothing() async throws {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        let model = try await preparedModel(cli, git: git, repositoryJSON: try fixture("repo-view.json"))
        cli.serve(createArguments(), stderr: "pull request already exists for o:feature\n", status: 1)

        let refused = await model.create(title: "A change", body: "Why.", base: "master", draft: false)
        XCTAssertFalse(refused)

        XCTAssertEqual(model.errorMessage, "pull request already exists for o:feature")
        XCTAssertNil(model.selectedNumber)
        XCTAssertFalse(model.isWriteInFlight)
    }

    func testTheWriteFlagIsUpForTheWholeFlowAndDownOnEveryExitPath() async throws {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        let model = try await preparedModel(cli, git: git, repositoryJSON: try fixture("repo-view.json"))
        cli.serve(createArguments(), stdout: "https://github.com/o/r/pull/54\n")

        let pushGate = Gate()
        let createGate = Gate()
        git.pushGate = pushGate
        cli.hold(createArguments(), on: createGate)

        let create = Task {
            await model.create(title: "A change", body: "Why.", base: "master", draft: false)
        }
        // Up while the *push* is still running — before `gh` has been asked for
        // anything, which is the earliest moment the flag has to be up.
        await pushGate.waitUntilReached()
        XCTAssertTrue(model.isWriteInFlight)
        pushGate.release()

        // And still up while `pr create` is on the wire, which is what the
        // panel's disabled Checkout and refresh buttons read.
        await createGate.waitUntilReached()
        XCTAssertTrue(model.isWriteInFlight)
        createGate.release()
        let created = await create.value
        XCTAssertTrue(created)

        XCTAssertFalse(model.isWriteInFlight)
        git.pushGate = nil

        // Down after a refusal, after a push failure and after a failed command.
        git.pushError = GitError.pushFailed(reason: "no")
        let refused = await model.create(title: "A change", body: "Why.", base: "master", draft: false)
        XCTAssertFalse(refused)
        XCTAssertFalse(model.isWriteInFlight)

        git.pushError = nil
        git.contextError = GitError.gitUnavailable
        let refusedAgain = await model.create(title: "A change", body: "Why.", base: "master", draft: false)
        XCTAssertFalse(refusedAgain)
        XCTAssertFalse(model.isWriteInFlight)
    }

    func testASecondCreateIsRefusedWhileTheFirstIsInFlight() async throws {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        let model = try await preparedModel(cli, git: git, repositoryJSON: try fixture("repo-view.json"))
        cli.serve(createArguments(), stdout: "https://github.com/o/r/pull/54\n")

        let gate = Gate()
        cli.hold(createArguments(), on: gate)
        let first = Task {
            await model.create(title: "A change", body: "Why.", base: "master", draft: false)
        }
        await gate.waitUntilReached()

        let refused = await model.create(title: "A change", body: "Why.", base: "master", draft: false)
        XCTAssertFalse(refused)
        gate.release()
        let created = await first.value
        XCTAssertTrue(created)

        // One push, one create: the refused second flow sent nothing at all.
        XCTAssertEqual(git.pushedPlans.count, 1)
        XCTAssertEqual(cli.argumentLists.filter { $0.contains("create") }.count, 1)
    }

    func testMovingTheBasePickerRePlansWithoutASecondGitRead() async throws {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        let model = try await preparedModel(cli, git: git, repositoryJSON: try fixture("repo-view.json"))

        model.setCreateBase("develop")

        XCTAssertEqual(model.createPlan?.base, "develop")
        XCTAssertEqual(
            model.createPlan?.baseSentence,
            "The pull request will be opened from “feature” into “develop”."
        )
    }

    func testACreateFailureIsNotClearedByASucceedingRefresh() async throws {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        let model = try await preparedModel(cli, git: git, repositoryJSON: try fixture("repo-view.json"))
        cli.serve(createArguments(), stderr: "pull request already exists for o:feature\n", status: 1)

        let refused = await model.create(title: "A change", body: "Why.", base: "master", draft: false)
        XCTAssertFalse(refused)
        await model.refresh(branch: nil)

        // The refresh that succeeded says nothing about the create that failed,
        // and the sheet is still open showing the fields it refused.
        XCTAssertEqual(model.errorMessage, "pull request already exists for o:feature")
    }

    // MARK: - The third token

    /// `repo view`'s answer, with a default branch a test can tell apart.
    private func repositoryJSON(defaultBranch: String) -> String {
        """
        {"defaultBranchRef": {"name": "\(defaultBranch)"}, "nameWithOwner": "o/r"}
        """
    }

    /// The stale read resumes **last**, which is the only staging in which the
    /// token is doing any work: held key-wide, both sheet reads resume in call
    /// order and the fresh one lands on top regardless.
    func testASupersededSheetReadPublishesNothing() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: "[]")
        cli.serve(repositoryArguments, sequence: [
            GitHubCommandResult(standardOutput: repositoryJSON(defaultBranch: "stale")),
            GitHubCommandResult(standardOutput: repositoryJSON(defaultBranch: "fresh")),
        ])
        let model = makeModel(cli, git: StubGit())
        await model.refresh(branch: nil)

        let gate = Gate()
        cli.hold(repositoryArguments, on: gate, forCall: 0)

        // The sheet was opened, cancelled and opened again — two independently
        // re-triggerable reads, with no refresh between them.
        let first = Task { await model.prepareCreate() }
        await gate.waitUntilReached()
        let second = Task { await model.prepareCreate() }
        await second.value
        XCTAssertEqual(model.repository?.defaultBranch, "fresh")

        gate.release()
        await first.value

        XCTAssertEqual(model.repository?.defaultBranch, "fresh")
        XCTAssertEqual(model.createPlan?.base, "fresh")
    }

    func testASheetReadStillInFlightCannotPublishOverACreatesOwnPlan() async throws {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        cli.serveReady()
        cli.serve(listArguments, stdout: "[]")
        cli.serve(headArguments("feature"), stdout: "[]")
        cli.serve(repositoryArguments, stdout: repositoryJSON(defaultBranch: "stale"))
        cli.serve(createArguments(base: "chosen"), stdout: "https://github.com/o/r/pull/54\n")
        let model = makeModel(cli, git: git)
        await model.refresh(branch: nil)

        let gate = Gate()
        cli.hold(repositoryArguments, on: gate, forCall: 0)
        let opening = Task { await model.prepareCreate() }
        await gate.waitUntilReached()

        // The reader pressed Create while the sheet's own read was still on the
        // wire. `create` re-plans from a fresh commit context and its base.
        let created = await model.create(title: "A change", body: "Why.", base: "chosen", draft: false)
        XCTAssertTrue(created)
        XCTAssertEqual(model.createPlan?.base, "chosen")

        gate.release()
        await opening.value

        // The sheet read lands afterwards and must not replace the plan the
        // write decided from, nor blank the picker under it.
        XCTAssertEqual(model.createPlan?.base, "chosen")
    }

    func testACreatedRowThatIsNoLongerOpenLosesTheSelection() async throws {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        let model = try await preparedModel(cli, git: git, repositoryJSON: try fixture("repo-view.json"))
        cli.serve(createArguments(), stdout: "https://github.com/o/r/pull/54\n")
        cli.serve(listArguments, sequence: [
            GitHubCommandResult(standardOutput: listJSON(number: 54, head: "feature")),
            GitHubCommandResult(standardOutput: "[]"),
        ])

        let created = await model.create(title: "A change", body: "Why.", base: "master", draft: false)
        XCTAssertTrue(created)
        XCTAssertEqual(model.selectedNumber, 54)

        // The pull request was merged from the browser; the next refresh does
        // not list it.
        await model.refresh(branch: nil)

        XCTAssertNil(model.selectedNumber, "a selection may not outlive the rows it points into")
        XCTAssertTrue(model.pullRequests.isEmpty)
    }

    // MARK: - The message slot's four sources

    func testGoingNotReadyClearsASentenceLeftByAnotherSource() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serve(GitHubCommands.version(), sequence: [
            GitHubCommandResult(standardOutput: "gh version 2.99.0 (2026-09-01)\n"),
            GitHubCommandResult(standardOutput: "gh version 2.99.0 (2026-09-01)\n"),
        ])
        cli.serve(GitHubCommands.authStatus(), sequence: [
            GitHubCommandResult(standardError: "github.com\n  ✓ Logged in to github.com account someone\n"),
            GitHubCommandResult(standardError: "You are not logged into any GitHub hosts.\n", status: 1),
        ])
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.serve(checksArguments(53), stderr: "could not reach github.com\n", status: 1)
        let model = makeModel(cli)

        await model.refresh(branch: nil)
        await model.expand(53)
        XCTAssertEqual(model.errorMessage, "could not reach github.com")

        // `gh auth logout` between the two refreshes. The not-ready state blanks
        // the rows, and the checks sentence was about those rows: leaving it
        // standing would put "could not reach github.com" above a panel whose
        // own next step is `gh auth login`.
        await model.refresh(branch: nil)

        XCTAssertEqual(model.availability, .notSignedIn)
        XCTAssertTrue(model.pullRequests.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testClosingTheProjectClearsASentenceLeftByAnotherSource() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.serve(checksArguments(53), stderr: "could not reach github.com\n", status: 1)
        var currentRoot: URL? = root
        let model = PullRequestModel(transport: cli, gitService: StubGit(), root: { currentRoot })

        await model.refresh(branch: nil)
        await model.expand(53)
        XCTAssertEqual(model.errorMessage, "could not reach github.com")

        currentRoot = nil
        await model.refresh(branch: nil)

        XCTAssertNil(model.availability)
        XCTAssertTrue(model.pullRequests.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testTheCreateSheetOnlySeesTheCreatesOwnSentence() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.serve(checksArguments(53), stderr: "no checks reported on the 'feature' branch\n", status: 1)
        cli.serve(repositoryArguments, stdout: try fixture("repo-view.json"))
        let model = makeModel(cli, git: StubGit())
        await model.refresh(branch: nil)
        await model.expand(53)

        // The one slot now holds a *checks* failure, which `prepareCreate()`
        // may not clear — it is not the create's to clear.
        XCTAssertEqual(model.errorMessage, "no checks reported on the 'feature' branch")

        await model.prepareCreate()

        // The sheet draws `createMessage`, which is empty: nothing has been
        // submitted, so nothing has been refused.
        XCTAssertEqual(model.errorMessage, "no checks reported on the 'feature' branch")
        XCTAssertNil(model.createMessage)

        let refused = await model.create(title: "", body: "Why.", base: "master", draft: false)
        XCTAssertFalse(refused)
        XCTAssertEqual(model.createMessage, PullRequestModel.untitledMessage)
    }

    func testAnUntitledPullRequestIsRefusedBeforeAnythingIsPushed() async throws {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        let model = try await preparedModel(cli, git: git, repositoryJSON: try fixture("repo-view.json"))

        let refused = await model.create(title: "   ", body: "Why.", base: "master", draft: false)

        XCTAssertFalse(refused)
        XCTAssertEqual(model.errorMessage, PullRequestModel.untitledMessage)
        // Nothing was pushed and nothing was sent: the refusal is the model's,
        // not a `gh` failure reported after the branch had already moved.
        XCTAssertTrue(git.pushedPlans.isEmpty)
        XCTAssertFalse(cli.argumentLists.contains { $0.contains("create") })
        XCTAssertFalse(model.isWriteInFlight)
    }

    // MARK: - A project switch

    func testAProjectSwitchDropsThePreviousProjectsRowsEvenWhenTheNewOnesListFails() async throws {
        // The rule "a failure never blanks a good list" is about *one*
        // repository. Rows read under a different root are not this repository's
        // stale answer, and leaving them would list project A's pull requests
        // under project B — with Checkout composing A's number in B's worktree.
        let first = URL(fileURLWithPath: "/tmp/pisaka-github")
        let second = URL(fileURLWithPath: "/tmp/pisaka-other")
        var current = first
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(GitHubCommands.openPullRequests(root: first), stdout: listJSON(number: 7, head: "feature"))
        cli.serve(
            GitHubCommands.pullRequest(forHeadBranch: "feature", root: first),
            stdout: listJSON(number: 7, head: "feature")
        )
        let model = PullRequestModel(transport: cli, gitService: StubGit(), root: { current })

        await model.refresh(branch: "feature")
        XCTAssertEqual(model.pullRequests.map(\.number), [7])
        XCTAssertEqual(model.currentBranchPullRequest?.number, 7)

        // The folder switch, and a new project that is not a GitHub repository.
        current = second
        cli.serve(
            GitHubCommands.openPullRequests(root: second),
            stderr: "no git remotes found in the current directory",
            status: 1
        )
        cli.serve(
            GitHubCommands.pullRequest(forHeadBranch: "feature", root: second),
            stderr: "no git remotes found in the current directory",
            status: 1
        )
        await model.refresh(branch: "feature")

        XCTAssertTrue(
            model.pullRequests.isEmpty,
            "The previous project's rows must go with the project: the panel would otherwise list a "
                + "repository the window has left, under a message about the one it is showing."
        )
        XCTAssertNil(
            model.currentBranchPullRequest,
            "…and so must the indicator's row, which is the one of the two that is always on screen."
        )
        XCTAssertEqual(model.errorMessage, "no git remotes found in the current directory")
    }

    func testTheSynchronousPrepareDropsThePreviousProjectsRowsBeforeAnyRead() async throws {
        // The coordinator calls this in the folder switch's own main-actor turn,
        // which is what makes the rows gone *before* the panel can draw them
        // again or Checkout can compose one — a `Task` start later is already
        // too late.
        let first = URL(fileURLWithPath: "/tmp/pisaka-github")
        var current = first
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(GitHubCommands.openPullRequests(root: first), stdout: listJSON(number: 7, head: "feature"))
        cli.serve(
            GitHubCommands.pullRequest(forHeadBranch: "feature", root: first),
            stdout: listJSON(number: 7, head: "feature")
        )
        let model = PullRequestModel(transport: cli, gitService: StubGit(), root: { current })
        await model.refresh(branch: "feature")
        XCTAssertEqual(model.pullRequests.map(\.number), [7])

        current = URL(fileURLWithPath: "/tmp/pisaka-other")
        model.prepareForRefresh()

        XCTAssertTrue(model.pullRequests.isEmpty)
        XCTAssertNil(model.currentBranchPullRequest)
        XCTAssertNil(model.availability)
        XCTAssertFalse(model.isReady)
        // Nothing was asked: this is an invalidation, not a fourth trigger.
        XCTAssertEqual(cli.count(for: GitHubCommands.version()), 1)
    }

    func testAListReadInFlightWhenTheFolderChangedPublishesNothingAfterwards() async throws {
        // Blanking what is published is only half of a folder switch. A `pr
        // list` already suspended in the transport captured the *previous*
        // root's token, and if nothing supersedes it, it resumes after the clear
        // and puts project A's rows back — under project B, where Checkout would
        // compose `gh pr checkout <A's number>`.
        let first = URL(fileURLWithPath: "/tmp/pisaka-github")
        var current = first
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(GitHubCommands.openPullRequests(root: first), stdout: listJSON(number: 7, head: "feature"))
        cli.serve(
            GitHubCommands.pullRequest(forHeadBranch: "feature", root: first),
            stdout: listJSON(number: 7, head: "feature")
        )
        let model = PullRequestModel(transport: cli, gitService: StubGit(), root: { current })

        let gate = Gate()
        cli.hold(GitHubCommands.openPullRequests(root: first), on: gate)
        let reading = Task { await model.refresh(branch: "feature") }
        await gate.waitUntilReached()

        // The folder switch, in the turn the coordinator registers it in.
        current = URL(fileURLWithPath: "/tmp/pisaka-other")
        model.prepareForRefresh()

        gate.release()
        await reading.value

        XCTAssertTrue(
            model.pullRequests.isEmpty,
            "A read of the project that was left is not a stale answer worth keeping: it is another "
                + "repository's numbers, and the clear must supersede it, not merely outrun it."
        )
        XCTAssertNil(model.currentBranchPullRequest)
        XCTAssertNil(model.availability)
        XCTAssertFalse(model.isReady)
    }

    func testAFolderSwitchLowersTheLoadingFlagOfTheReadItSuperseded() async throws {
        // The clear supersedes whatever was in flight — and a superseded run
        // publishes *nothing*, including its own `isLoading = false`. The root
        // observer calls `prepareForRefresh()` without starting a replacement
        // read, on purpose, so nothing else would ever lower the flag: the panel
        // spins on "Reading…" for a command nobody sent, for the rest of the app
        // run. Reachable on exactly the switch the root observer exists for —
        // one `nil` branch to another, where the branch sink never fires.
        let first = URL(fileURLWithPath: "/tmp/pisaka-github")
        var current = first
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(GitHubCommands.openPullRequests(root: first), stdout: listJSON(number: 7, head: "feature"))
        let model = PullRequestModel(transport: cli, gitService: StubGit(), root: { current })

        let gate = Gate()
        cli.hold(GitHubCommands.openPullRequests(root: first), on: gate)
        let reading = Task { await model.refresh(branch: nil) }
        await gate.waitUntilReached()
        XCTAssertTrue(model.isLoading)

        current = URL(fileURLWithPath: "/tmp/pisaka-other")
        model.prepareForRefresh()
        XCTAssertFalse(
            model.isLoading,
            "No read of *this* project is in flight once the tokens have moved, so the honest answer is "
                + "that nothing is loading."
        )

        gate.release()
        await reading.value

        XCTAssertFalse(
            model.isLoading,
            "The superseded run returns at its token guard and publishes nothing, so it cannot lower the "
                + "flag on its way out either."
        )
        XCTAssertTrue(model.pullRequests.isEmpty)
    }

    func testASheetReadInFlightWhenTheFolderChangedPublishesNothingAfterwards() async throws {
        // The same hole in the third token: `repo view` answers the create
        // sheet's default base, and a base read under the project that was left
        // is a pull request opened into another repository's branch name.
        let first = URL(fileURLWithPath: "/tmp/pisaka-github")
        var current = first
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(GitHubCommands.openPullRequests(root: first), stdout: "[]")
        cli.serve(GitHubCommands.repositoryView(root: first), stdout: try fixture("repo-view.json"))
        let model = PullRequestModel(transport: cli, gitService: StubGit(), root: { current })
        await model.refresh(branch: nil)

        let gate = Gate()
        cli.hold(GitHubCommands.repositoryView(root: first), on: gate)
        let preparing = Task { await model.prepareCreate() }
        await gate.waitUntilReached()

        current = URL(fileURLWithPath: "/tmp/pisaka-other")
        model.prepareForRefresh()

        gate.release()
        await preparing.value

        XCTAssertNil(model.repository)
        XCTAssertNil(model.createPlan)
    }

    func testARootThatHasNotChangedKeepsEverythingTheRefreshJustPublished() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: listJSON(number: 7, head: "feature"))
        cli.serve(headArguments("feature"), stdout: listJSON(number: 7, head: "feature"))
        let model = makeModel(cli)

        await model.refresh(branch: "feature")
        model.prepareForRefresh()

        // Idempotent: the coordinator calls it before *every* refresh, not only
        // after a folder switch, so a same-root call may cost nothing but a
        // comparison — blanking here would flash the panel empty on every
        // branch change.
        XCTAssertEqual(model.pullRequests.map(\.number), [7])
        XCTAssertEqual(model.currentBranchPullRequest?.number, 7)
        XCTAssertEqual(model.availability, .ready(version: GitHubVersion(major: 2, minor: 99, patch: 0)))
    }

    func testARefreshWhoseTaskStartedAfterANewerTriggerPublishesNothing() async throws {
        // The token is taken in the trigger's own turn and travels into the
        // read, because unstructured tasks are not guaranteed to start in the
        // order they were created. Staged here the way an out-of-order start
        // looks from the model's side: both tokens taken first, then the reads
        // run in the reverse order.
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: listJSON(number: 7, head: "old"))
        cli.serve(headArguments("old"), stdout: listJSON(number: 7, head: "old"))
        cli.serve(headArguments("new"), stdout: "[]")
        let model = makeModel(cli)

        let stale = model.prepareForRefresh()
        let fresh = model.prepareForRefresh()

        await model.refresh(branch: "new", token: fresh)
        XCTAssertNil(model.currentBranchPullRequest)

        await model.refresh(branch: "old", token: stale)

        XCTAssertNil(
            model.currentBranchPullRequest,
            "The older trigger's read is superseded by the token the newer one took, so it may not "
                + "leave the indicator naming a pull request of the branch that was left."
        )
        XCTAssertEqual(
            cli.count(for: headArguments("old")),
            0,
            "A superseded refresh returns at its token guard, before it spends a single `gh`."
        )
        XCTAssertEqual(
            cli.count(for: GitHubCommands.version()),
            1,
            "Availability is re-probed once per refresh that actually runs — never for one already "
                + "superseded before it began."
        )
    }

    func testTheTokenIsBumpedEvenWhenTheRootDidNotChange() async throws {
        // The clear is conditional on the root; the bump is not. Superseding
        // whatever read is in flight is right for every refresh, and a bump that
        // only happened on a folder switch would let a `pr list` suspended in the
        // transport publish over the branch change that replaced it.
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: listJSON(number: 7, head: "feature"))
        cli.serve(headArguments("feature"), stdout: listJSON(number: 7, head: "feature"))
        cli.serve(headArguments("other"), stdout: "[]")
        let model = makeModel(cli)

        let gate = Gate()
        // The first run only: the fresh read below must reach the transport.
        cli.hold(listArguments, on: gate, forCall: 0)
        let stale = model.prepareForRefresh()
        let reading = Task { await model.refresh(branch: "feature", token: stale) }
        await gate.waitUntilReached()

        // The branch change, in the turn the coordinator registers it in — same
        // root, so nothing is blanked, but the read in flight is superseded.
        let fresh = model.prepareForRefresh()
        XCTAssertNotEqual(stale, fresh)

        gate.release()
        await reading.value

        XCTAssertNil(
            model.currentBranchPullRequest,
            "The superseded read publishes nothing, even though the root it was reading is still the "
                + "open project."
        )
        XCTAssertTrue(model.pullRequests.isEmpty)

        await model.refresh(branch: "other", token: fresh)
        XCTAssertNil(model.currentBranchPullRequest)
    }

    // MARK: - Availability going not-ready

    func testAnAuthStatusThatCouldNotRunIsNotASignIn() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serve(GitHubCommands.version(), stdout: "gh version 2.99.0 (2026-09-01)\n")
        cli.fail(GitHubCommands.authStatus(), with: GitHubCLIError.timedOut(seconds: 30))
        let model = makeModel(cli)

        await model.refresh(branch: "feature")

        // A probe that could not run is the safe reading, not an optimistic one:
        // reporting `.ready` here sends every following command to a `gh` that
        // cannot answer, and the reader gets a raw command failure instead of
        // "sign in to GitHub".
        XCTAssertEqual(model.availability, .notSignedIn)
        XCTAssertEqual(model.errorMessage, GitHubCLIError.timedOut(seconds: 30).errorDescription)
        XCTAssertEqual(cli.trace, ["--version", "auth status"])
    }

    func testGoingNotReadyDisablesAnOpenSheetRatherThanRefusingItSilently() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serve(GitHubCommands.version(), sequence: [
            GitHubCommandResult(standardOutput: "gh version 2.99.0 (2026-09-01)\n"),
            GitHubCommandResult(standardOutput: "gh version 2.99.0 (2026-09-01)\n"),
        ])
        cli.serve(GitHubCommands.authStatus(), sequence: [
            GitHubCommandResult(standardError: "✓ Logged in\n"),
            GitHubCommandResult(
                standardError: "You are not logged into any GitHub hosts.\n",
                status: 1
            ),
        ])
        cli.serve(listArguments, stdout: "[]")
        cli.serve(repositoryArguments, stdout: try fixture("repo-view.json"))
        let model = makeModel(cli, git: StubGit())
        await model.refresh(branch: nil)
        await model.prepareCreate()
        XCTAssertTrue(model.createPlan?.canCreate == true)

        // A background refresh finds a `gh` that is no longer signed in while
        // the sheet is still open.
        await model.refresh(branch: nil)

        XCTAssertEqual(model.availability, .notSignedIn)
        // The sheet's Create button reads `createPlan`, so the plan has to go
        // with the rows: a plan left standing is an enabled button over a
        // `create` that would now return at its readiness guard without a word.
        XCTAssertNil(model.createPlan)
        XCTAssertNil(model.repository)
    }

    /// The other half of the rule above, and the half a token has to carry: the
    /// sheet's read is *in flight* when `gh` goes not-ready, so blanking the
    /// plan is not enough — the read has to be superseded, or it resumes and
    /// puts the plan back.
    func testASheetReadInFlightWhenGHGoesNotReadyPublishesNothing() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serve(GitHubCommands.version(), stdout: "gh version 2.99.0 (2026-09-01)\n")
        cli.serve(GitHubCommands.authStatus(), sequence: [
            GitHubCommandResult(standardError: "✓ Logged in\n"),
            GitHubCommandResult(standardError: "You are not logged into any GitHub hosts.\n", status: 1),
        ])
        cli.serve(listArguments, stdout: "[]")
        cli.serve(repositoryArguments, stdout: try fixture("repo-view.json"))
        let model = makeModel(cli, git: StubGit())
        await model.refresh(branch: nil)

        // The sheet is opened, and its `repo view` is held on the wire.
        let gate = Gate()
        cli.hold(repositoryArguments, on: gate, forCall: 0)
        let opening = Task { await model.prepareCreate() }
        await gate.waitUntilReached()

        // A branch-change or panel-shown refresh lands in that window and finds
        // a signed-out `gh`.
        await model.refresh(branch: nil)
        XCTAssertEqual(model.availability, .notSignedIn)
        XCTAssertNil(model.createPlan)

        gate.release()
        await opening.value

        // The held read resumes against a moved token and publishes nothing. A
        // plan re-published here is an enabled Create button over a `create`
        // that refuses — the very state the refresh just cleared.
        XCTAssertNil(model.createPlan)
        XCTAssertNil(model.repository)
    }

    /// Every exit from `create` leaves a sentence, this one included: a reader
    /// who presses Create after `gh` went away gets an explanation rather than a
    /// button that does nothing at all.
    /// A create asks the writer gate, and it asks it *before the push*.
    ///
    /// The push is the half neither the fresh context nor the pinned `--head`
    /// can protect: `PushPlan.push(upstream:)` is a plain `git push`, which
    /// resolves HEAD when its own process launches rather than from the plan, so
    /// a branch switch landing between the context read and the push publishes a
    /// branch this flow never planned while `--head` still opens the pull request
    /// from the one it did. Asserted by what was *not* done — no push, no
    /// `pr create` — because the refusal has to happen before the first of them,
    /// not between them.
    func testACreateIsRefusedWhileTheWorktreeIsBeingRewritten() async throws {
        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        var blocked = false
        let model = try await preparedModel(
            cli,
            git: git,
            repositoryJSON: try fixture("repo-view.json"),
            isWriteBlocked: { blocked }
        )
        cli.serve(createArguments(), stdout: "https://github.com/o/r/pull/54\n")

        blocked = true
        let refused = await model.create(title: "A change", body: "Why.", base: "master", draft: false)

        XCTAssertFalse(refused)
        XCTAssertEqual(model.errorMessage, PullRequestModel.createBlockedMessage)
        XCTAssertEqual(git.pushedPlans, [])
        XCTAssertFalse(cli.argumentLists.contains { $0.contains("create") })
        XCTAssertFalse(model.isWriteInFlight)

        // And the very same create runs once the gate comes down: the refusal is
        // a "not now", not a state the sheet has to be reopened out of.
        blocked = false
        let created = await model.create(title: "A change", body: "Why.", base: "master", draft: false)
        XCTAssertTrue(created)
        XCTAssertEqual(git.pushedPlans, [.push(upstream: "origin/feature")])
    }

    /// A worktree-mutating operation that starts *while the create is suspended*
    /// is refused too — which is the reading that actually matters.
    ///
    /// The consult at the top of `create` answers only for a rewrite already in
    /// flight. The flow then awaits `commitContext`, which is several `git`
    /// subprocesses long with the main actor free throughout, and none of the
    /// app's branch-change entry points consults this feature's own one-write
    /// flag — they refuse on the writer gate, which this flow never raises. So a
    /// branch switch started in that window would run, and a plain `git push`
    /// resolves HEAD at its own process launch: it would publish the branch the
    /// switch moved to while the pinned `--head` opened the pull request from the
    /// one the plan named. Staged by raising the gate from inside the context
    /// read, and asserted by what was *not* done — the refusal has to land before
    /// the push, not between the push and `pr create`.
    func testACreateIsRefusedWhenTheGateGoesUpWhileItIsSuspended() async throws {
        /// Written from the cooperative pool (inside `commitContext`) and read
        /// from the main actor (the gate closure), so the Bool is locked rather
        /// than shared bare.
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            var isRaised: Bool {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            func raise() {
                lock.lock()
                value = true
                lock.unlock()
            }
        }

        let cli = ScriptedGitHubCLI()
        let git = StubGit()
        let flag = Flag()
        let model = try await preparedModel(
            cli,
            git: git,
            repositoryJSON: try fixture("repo-view.json"),
            isWriteBlocked: { flag.isRaised }
        )
        cli.serve(createArguments(), stdout: "https://github.com/o/r/pull/54\n")

        // The gate was down when Create was pressed and goes up during the read
        // the flow is suspended over — a branch switch initiated in that window.
        git.onContext = { flag.raise() }

        let created = await model.create(title: "A change", body: "Why.", base: "master", draft: false)

        XCTAssertFalse(created)
        XCTAssertEqual(model.errorMessage, PullRequestModel.createBlockedMessage)
        XCTAssertEqual(git.pushedPlans, [], "the push must not run: it would publish the switched-to branch")
        XCTAssertFalse(cli.argumentLists.contains { $0.contains("create") })
        XCTAssertFalse(model.isWriteInFlight)
    }

    func testACreateRefusedForWantOfAReadyGHSaysSo() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serve(GitHubCommands.version(), stdout: "gh version 2.49.0 (2024-01-01)\n")
        let model = makeModel(cli, git: StubGit())
        await model.refresh(branch: nil)
        XCTAssertFalse(model.isReady)

        let created = await model.create(title: "A change", body: "Why.", base: "master", draft: false)

        XCTAssertFalse(created)
        XCTAssertEqual(model.errorMessage, PullRequestModel.unavailableMessage)
        // And nothing was sent: the refusal is decided before any command.
        XCTAssertFalse(cli.argumentLists.contains { $0.contains("create") })
        XCTAssertFalse(model.isWriteInFlight)
    }

    // MARK: - The reader rule

    func testNoReadPathEverRaisesTheWriteFlag() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.serve(headArguments("feature"), stdout: "[]")
        cli.serve(checksArguments(53), stdout: try fixture("pr-checks.json"))
        let model = makeModel(cli)

        await model.refresh(branch: "feature")
        await model.expand(53)
        await model.expand(nil)

        XCTAssertFalse(model.isWriteInFlight)
    }

    func testNothingARefreshRunsIsAWritingCommand() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, stdout: try fixture("pr-list-merged.json"))
        cli.serve(headArguments("feature"), stdout: "[]")
        cli.serve(checksArguments(53), stdout: try fixture("pr-checks.json"))
        let model = makeModel(cli)

        await model.refresh(branch: "feature")
        await model.expand(53)

        // `pr create` and `pr checkout` are the feature's only two writes, and
        // neither is anywhere in a read path's call log.
        for arguments in cli.argumentLists {
            XCTAssertFalse(arguments.contains("create"), "\(arguments)")
            XCTAssertFalse(arguments.contains("checkout"), "\(arguments)")
        }
    }
}
