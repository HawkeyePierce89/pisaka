import XCTest
@testable import PisakaCore

/// The model's half of the eighth gated operation (G12): everything about
/// `gh pr checkout` that is decided *before* the app's writer bracket, and
/// everything reported after it.
///
/// The app's half — suspending the disk writers, snapshotting the open tabs,
/// capturing Local History as the operation's first `await` and resyncing the
/// tabs afterwards — is `PisakaApp.runBranchOperation(_:_:)`, which this target
/// cannot link and `GitHubSourceGatingTests` pins statically instead. What is
/// asserted here is the seam between the two, and it is a seam with three
/// properties worth a suite of its own:
///
/// - **The gate is consulted before anything is sent.** A checkout landing in
///   the middle of a revert, a merge apply or a branch switch would move the
///   worktree out from under an operation already snapshotting it. The refusal
///   is asserted as "nothing was handed out *and* nothing reached `gh`", which
///   is the pair that catches a gate asked one line too late.
/// - **The operation is handed out exactly once.** A checkout is not a read that
///   can be re-run: handing it out twice would run two `gh pr checkout`s inside
///   two brackets, and the second would resync the open tabs against a worktree
///   the first was still moving.
/// - **The write flag is up from the hand-out and down on every exit path.** It
///   is the one term the panel's three buttons disable on and the term the
///   create flow refuses on, so a flag left up by a failed checkout would
///   disable the feature for the rest of the app run.
///
/// Nothing here runs `gh`, and nothing here runs a bracket: the bracket is a
/// closure the test keeps, so "handed out" and "run" are two separate moments an
/// assertion can sit between.
@MainActor
final class PullRequestCheckoutTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/tmp/pisaka-github")

    /// What a `runCheckout` closure records, and the model's whole answer to
    /// "did the checkout reach the writer bracket".
    private final class Bracket {
        /// Every operation handed out, in order. One per accepted checkout.
        var operations: [@MainActor () async -> String?] = []
        /// What each operation answered once it was run — `nil` for success and,
        /// for this feature, `""` for a failure already published in the model's
        /// own message slot.
        var answers: [String?] = []

        var runner: GitHubCheckoutRunner {
            { [self] operation in operations.append(operation) }
        }

        /// Run the operation handed out at `index`, as the bracket would.
        func run(_ index: Int = 0) async {
            answers.append(await operations[index]())
        }
    }

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

    /// The three members this feature reaches for are `commitContext` and
    /// `push`, neither of which a checkout touches; everything else is
    /// `GitServicing`'s defaulted refusal, so a checkout that reached for git at
    /// all would fail as a failure.
    private final class StubGit: GitServicing {
        func repositoryRoot(for url: URL) async throws -> URL { url }
        func changedFiles(root: URL) async throws -> [ChangedFile] { [] }
        func commits(filter: LogFilter, limit: Int, root: URL) async throws -> [Commit] { [] }
        func headContents(of path: String, root: URL) async throws -> String? { nil }
        func revert(_ file: ChangedFile, root: URL) async throws {}
    }

    private func checkoutArguments(_ number: Int) -> [String] {
        GitHubCommands.checkoutPullRequest(number: number, root: root).arguments
    }

    /// A model that has already refreshed against a signed-in `gh` with one open
    /// pull request — the state every checkout starts from, since the button
    /// lives on a listed row.
    private func readyModel(
        _ cli: ScriptedGitHubCLI,
        gate: WriteGate = WriteGate(),
        bracket: Bracket
    ) async -> PullRequestModel {
        let root = root
        cli.serveReady()
        cli.serve(GitHubCommands.openPullRequests(root: root), stdout: Self.listJSON)
        cli.serve(GitHubCommands.pullRequest(forHeadBranch: "master", root: root), stdout: "[]")
        let model = PullRequestModel(
            transport: cli,
            gitService: StubGit(),
            root: { root },
            isWriteBlocked: gate.question,
            runCheckout: bracket.runner
        )
        await model.refresh(branch: "master")
        return model
    }

    private static let listJSON = """
    [{"number":54,"title":"A change","author":{"login":"someone"},
    "headRefName":"feature","baseRefName":"master","isDraft":false,
    "reviewDecision":"","url":"https://github.com/o/r/pull/54",
    "state":"OPEN","statusCheckRollup":[],
    "headRefOid":"abc123","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}]
    """

    // MARK: - The gate

    func testTheGateIsAskedAndNothingIsSentWhileTheWorktreeIsBeingRewritten() async {
        let cli = ScriptedGitHubCLI()
        let gate = WriteGate()
        let bracket = Bracket()
        let model = await readyModel(cli, gate: gate, bracket: bracket)
        let sentByTheRefresh = cli.argumentLists.count
        // Counted from here: a refresh consults the gate once itself, to clear a
        // gate-refusal whose condition has since passed. What this asserts is the
        // checkout's own consult.
        let asksBeforeTheCheckout = gate.asks
        gate.isBlocked = true

        XCTAssertFalse(model.checkout(54))

        XCTAssertEqual(gate.asks - asksBeforeTheCheckout, 1, "the gate was not consulted")
        XCTAssertTrue(bracket.operations.isEmpty, "a refused checkout still reached the writer bracket")
        XCTAssertEqual(cli.argumentLists.count, sentByTheRefresh, "a refused checkout still ran a command")
        XCTAssertEqual(model.errorMessage, PullRequestModel.blockedMessage)
        // The refusal is this layer's own words because `gh` was never asked —
        // which is the whole point of asking the gate first.
        XCTAssertFalse(model.isWriteInFlight)
    }

    /// The gate is askable on its own, which is what lets the panel ask it
    /// *before* the dirty-tree confirmation — the order `switchBranch` and
    /// `checkoutRemote` already ask in, so a refusal is one alert rather than a
    /// confirmation the reader gives to an operation refused straight after.
    func testTheGateCanBeAskedOnItsOwnBeforeAnythingIsPutInFrontOfTheCheckout() async {
        let cli = ScriptedGitHubCLI()
        let gate = WriteGate()
        let bracket = Bracket()
        let model = await readyModel(cli, gate: gate, bracket: bracket)
        let asksBeforeTheCheckout = gate.asks
        gate.isBlocked = true

        XCTAssertTrue(model.checkoutIsBlocked())

        // The sentence is the model's, published from the one site `checkout`
        // itself refuses through.
        XCTAssertEqual(model.errorMessage, PullRequestModel.blockedMessage)
        XCTAssertEqual(gate.asks - asksBeforeTheCheckout, 1)
        XCTAssertTrue(bracket.operations.isEmpty)
        XCTAssertFalse(model.isWriteInFlight, "asking may not accept")

        // A clear gate answers `false` and says nothing.
        gate.isBlocked = false
        XCTAssertFalse(model.checkoutIsBlocked())
        XCTAssertEqual(gate.asks - asksBeforeTheCheckout, 2)
    }

    func testAClearGateLetsTheCheckoutThrough() async {
        let cli = ScriptedGitHubCLI()
        let gate = WriteGate()
        let bracket = Bracket()
        let model = await readyModel(cli, gate: gate, bracket: bracket)
        let asksBeforeTheCheckout = gate.asks

        XCTAssertTrue(model.checkout(54))

        XCTAssertEqual(gate.asks - asksBeforeTheCheckout, 1)
        XCTAssertEqual(bracket.operations.count, 1)
    }

    // MARK: - The hand-out

    func testTheOperationIsHandedOutExactlyOnceAndSendsNothingUntilItIsRun() async throws {
        let cli = ScriptedGitHubCLI()
        let bracket = Bracket()
        let model = await readyModel(cli, bracket: bracket)
        let sentByTheRefresh = cli.argumentLists.count
        cli.serve(checkoutArguments(54), stdout: "Switched to branch 'feature'\n")

        XCTAssertTrue(model.checkout(54))

        // Handed out, and not yet run: the app's bracket has work to do first —
        // the gates, the tab snapshot and Local History's capture all happen
        // before the command does.
        XCTAssertEqual(bracket.operations.count, 1)
        XCTAssertEqual(cli.argumentLists.count, sentByTheRefresh)

        await bracket.run()

        XCTAssertEqual(cli.argumentLists.count, sentByTheRefresh + 1)
        let sent = try XCTUnwrap(cli.commands.last)
        XCTAssertEqual(sent.arguments, ["pr", "checkout", "54"])
        XCTAssertEqual(sent.workingDirectory, root)
        XCTAssertEqual(bracket.answers, [nil], "a successful checkout has nothing to say to the bracket")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isWriteInFlight)
    }

    func testACheckoutIsRefusedWhileGHIsNotReady() async {
        let cli = ScriptedGitHubCLI()
        let bracket = Bracket()
        cli.fail(GitHubCommands.version(), with: GitHubCLIError.notInstalled)
        let root = root
        let model = PullRequestModel(
            transport: cli,
            gitService: StubGit(),
            root: { root },
            runCheckout: bracket.runner
        )
        await model.refresh(branch: "master")

        XCTAssertFalse(model.checkout(54))
        XCTAssertTrue(bracket.operations.isEmpty)
    }

    /// The root guard, exercised where it is the *only* thing that can refuse.
    ///
    /// A model built with `root: { nil }` never becomes ready — `refresh` returns
    /// at its own root guard with `availability == nil` — so a checkout on one is
    /// refused by the readiness guard a line earlier and says nothing about the
    /// root at all. The case that matters is the one the panel actually produces:
    /// a model that refreshed successfully, drew its rows, and then had its
    /// folder closed while the reader was looking at them.
    func testACheckoutIsRefusedWhenTheFolderWasClosedUnderAReadyPanel() async {
        let cli = ScriptedGitHubCLI()
        let bracket = Bracket()
        let root = root
        // A root that can be taken away, which is what a folder switch does.
        final class Box: @unchecked Sendable { var url: URL? }
        let box = Box()
        box.url = root
        cli.serveReady()
        cli.serve(GitHubCommands.openPullRequests(root: root), stdout: Self.listJSON)
        cli.serve(GitHubCommands.pullRequest(forHeadBranch: "master", root: root), stdout: "[]")
        let model = PullRequestModel(
            transport: cli,
            gitService: StubGit(),
            root: { box.url },
            runCheckout: bracket.runner
        )
        await model.refresh(branch: "master")
        XCTAssertTrue(model.isReady)
        let sentSoFar = cli.argumentLists.count

        box.url = nil

        XCTAssertFalse(model.checkout(54))
        XCTAssertTrue(bracket.operations.isEmpty)
        XCTAssertEqual(cli.argumentLists.count, sentSoFar, "nothing was sent")
        XCTAssertFalse(model.isWriteInFlight, "a refusal leaves the one-write flag down")
    }

    // MARK: - One write at a time

    func testTheWriteFlagIsUpFromTheHandOutUntilTheOperationFinishes() async {
        let cli = ScriptedGitHubCLI()
        let bracket = Bracket()
        let model = await readyModel(cli, bracket: bracket)
        cli.serve(checkoutArguments(54), stdout: "")

        XCTAssertTrue(model.checkout(54))
        // Up *before* the bracket has run anything, which is the earliest moment
        // it has to be up: the bracket's own prologue is already writing to disk.
        XCTAssertTrue(model.isWriteInFlight)

        await bracket.run()
        XCTAssertFalse(model.isWriteInFlight)
    }

    func testASecondCheckoutIsRefusedWhileTheFirstIsInFlight() async {
        let cli = ScriptedGitHubCLI()
        let bracket = Bracket()
        let model = await readyModel(cli, bracket: bracket)
        cli.serve(checkoutArguments(54), stdout: "")
        cli.serve(checkoutArguments(55), stdout: "")

        XCTAssertTrue(model.checkout(54))
        XCTAssertFalse(model.checkout(55), "two checkouts would run in two brackets over one worktree")
        XCTAssertEqual(bracket.operations.count, 1)

        await bracket.run()

        // And accepted again once the first has finished.
        XCTAssertTrue(model.checkout(55))
        XCTAssertEqual(bracket.operations.count, 2)
    }

    func testACreateIsRefusedWhileACheckoutIsInFlight() async {
        let cli = ScriptedGitHubCLI()
        let bracket = Bracket()
        let model = await readyModel(cli, bracket: bracket)
        cli.serve(checkoutArguments(54), stdout: "")

        XCTAssertTrue(model.checkout(54))
        let created = await model.create(title: "A change", body: "Why.", base: "master", draft: false)

        // One rule read from both sides: the create refuses on the same flag the
        // checkout raised, and it refused *before* git — the stub's defaulted
        // `commitContext` would have thrown.
        XCTAssertFalse(created)
        XCTAssertEqual(bracket.operations.count, 1)
    }

    // MARK: - Failure

    func testAFailedCheckoutReportsGHsStderrVerbatimAndSaysNothingTwice() async {
        let cli = ScriptedGitHubCLI()
        let bracket = Bracket()
        let model = await readyModel(cli, bracket: bracket)
        cli.serve(
            checkoutArguments(54),
            stderr: "failed to run git: error: Your local changes to the following files would be overwritten\n",
            status: 1
        )

        XCTAssertTrue(model.checkout(54))
        await bracket.run()

        XCTAssertEqual(
            model.errorMessage,
            "failed to run git: error: Your local changes to the following files would be overwritten"
        )
        // `""` rather than the sentence: the panel the reader clicked Checkout in
        // is showing `gh`'s own words, and a modal repeating them is not a second
        // piece of information.
        XCTAssertEqual(bracket.answers, [""])
        XCTAssertFalse(model.isWriteInFlight)
    }

    func testASilentNonZeroExitStillNamesItsStatus() async {
        let cli = ScriptedGitHubCLI()
        let bracket = Bracket()
        let model = await readyModel(cli, bracket: bracket)
        cli.serve(checkoutArguments(54), status: 3)

        XCTAssertTrue(model.checkout(54))
        await bracket.run()

        XCTAssertEqual(model.errorMessage, "The GitHub CLI exited with status 3.")
        XCTAssertEqual(bracket.answers, [""])
    }

    func testATransportFailureCarriesItsOwnSentence() async {
        let cli = ScriptedGitHubCLI()
        let bracket = Bracket()
        let model = await readyModel(cli, bracket: bracket)
        cli.fail(checkoutArguments(54), with: GitHubCLIError.timedOut(seconds: 120))

        XCTAssertTrue(model.checkout(54))
        await bracket.run()

        XCTAssertEqual(model.errorMessage, "The GitHub CLI did not answer within 120 seconds.")
        XCTAssertEqual(bracket.answers, [""])
        XCTAssertFalse(model.isWriteInFlight)
    }

    func testARefreshClearsAGateRefusalOnceTheGateIsDown() async throws {
        let cli = ScriptedGitHubCLI()
        let gate = WriteGate()
        let model = await readyModel(cli, gate: gate, bracket: Bracket())
        gate.isBlocked = true

        XCTAssertTrue(model.checkoutIsBlocked())
        XCTAssertEqual(model.errorMessage, PullRequestModel.blockedMessage)

        // Still up: the sentence is still true, so it stands.
        await model.refresh(branch: "master")
        XCTAssertEqual(model.errorMessage, PullRequestModel.blockedMessage)

        // The revert finished. Nothing tells this feature so — a refresh finding
        // the gate down is the only proof there is, and left to `checkout(_:)`
        // alone the sentence would sit above a clean list for the rest of the app
        // run, telling a reader who did exactly what it asked to keep waiting.
        gate.isBlocked = false
        await model.refresh(branch: "master")
        XCTAssertNil(model.errorMessage)
    }

    func testARefreshDoesNotClearACheckoutsSentence() async throws {
        let cli = ScriptedGitHubCLI()
        let bracket = Bracket()
        let model = await readyModel(cli, bracket: bracket)
        cli.serve(checkoutArguments(54), stderr: "the merge commit is not available\n", status: 1)

        XCTAssertTrue(model.checkout(54))
        await bracket.run()
        await model.refresh(branch: "master")

        // The refresh that succeeded says nothing about the checkout that
        // failed, and the row the reader clicked is still on screen.
        XCTAssertEqual(model.errorMessage, "the merge commit is not available")
        XCTAssertEqual(model.pullRequests.count, 1)
    }
}
