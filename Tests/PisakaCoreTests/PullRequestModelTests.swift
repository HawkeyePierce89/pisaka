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

    private func makeModel(_ cli: ScriptedGitHubCLI) -> PullRequestModel {
        let root = root
        return PullRequestModel(transport: cli, root: { root })
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
    private func listJSON(number: Int, head: String, title: String = "A change") -> String {
        """
        [{"number":\(number),"title":"\(title)","author":{"login":"someone"},
        "headRefName":"\(head)","baseRefName":"master","isDraft":false,
        "reviewDecision":"","url":"https://github.com/o/r/pull/\(number)",
        "state":"OPEN","statusCheckRollup":[]}]
        """
    }

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
        let model = PullRequestModel(transport: cli, root: { nil })

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
        cli.serve(listArguments, stdout: listJSON(number: 7, head: "feature"))
        cli.serve(headArguments("feature"), stdout: "[]")
        cli.serve(checksArguments(7), stderr: "no checks reported on the 'feature' branch\n", status: 1)
        let model = makeModel(cli)

        await model.refresh(branch: "feature")
        await model.expand(7)
        XCTAssertEqual(model.errorMessage, "no checks reported on the 'feature' branch")

        // The refresh succeeded, but it has nothing to say about the expand that
        // failed — the sentence under the open row is the only explanation the
        // reader has for its empty jobs list.
        await model.refresh(branch: "feature")
        XCTAssertEqual(model.errorMessage, "no checks reported on the 'feature' branch")
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

    // MARK: - The two tokens

    func testASupersededRefreshPublishesNothing() async throws {
        let cli = ScriptedGitHubCLI()
        cli.serveReady()
        cli.serve(listArguments, sequence: [
            GitHubCommandResult(standardOutput: try fixture("pr-list-merged.json")),
            GitHubCommandResult(standardOutput: listJSON(number: 99, head: "second")),
        ])
        let gate = Gate()
        cli.hold(listArguments, on: gate)
        let model = makeModel(cli)

        let first = Task { await model.refresh(branch: nil) }
        await gate.waitUntilReached()

        // The second refresh starts *in the window* the first is suspended in,
        // which is what makes this a race rather than a sequence.
        let second = Task { await model.refresh(branch: nil) }
        gate.release()
        gate.release()
        await first.value
        await second.value

        // The second answer is the one on screen; the first published nothing —
        // not its rows, not its loading flag.
        XCTAssertEqual(model.pullRequests.map(\.number), [99])
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
        cli.hold(listArguments, on: gate)
        let model = makeModel(cli)

        let first = Task { await model.refresh(branch: nil) }
        await gate.waitUntilReached()
        let second = Task { await model.refresh(branch: nil) }
        gate.release()
        gate.release()
        await first.value
        await second.value

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
        cli.hold(checksArguments(53), on: gate)
        let expand = Task { await model.expand(53) }
        await gate.waitUntilReached()

        // A refresh finishing mid-expand must not cancel the checks load: one
        // shared token would drop these rows on the floor.
        await model.refresh(branch: nil)
        gate.release()
        await expand.value

        XCTAssertEqual(model.checks[53]?.count, 4)
        XCTAssertEqual(model.expandedNumber, 53)
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
