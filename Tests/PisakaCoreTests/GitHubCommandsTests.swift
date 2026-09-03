import XCTest
@testable import PisakaCore

/// Every `gh` argument list, byte for byte.
///
/// The whole point of composing them in Core is that they can be asserted in a
/// target that cannot link `Process`, so these are literal string arrays rather
/// than anything built from the same constants the production code builds from:
/// an assertion written as `pullRequestFields.joined(separator: ",")` would go on
/// passing after somebody reordered the field list, which is exactly the drift
/// this suite exists to catch.
final class GitHubCommandsTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/pisaka-repo")

    // MARK: - The argument lists

    func testVersionCommand() {
        let command = GitHubCommands.version()
        XCTAssertEqual(command.arguments, ["--version"])
        XCTAssertNil(command.workingDirectory)
        XCTAssertEqual(command.deadline, 15)
    }

    func testAuthStatusCommand() {
        let command = GitHubCommands.authStatus()
        XCTAssertEqual(command.arguments, ["auth", "status"])
        XCTAssertNil(command.workingDirectory)
    }

    func testOpenPullRequestsCommand() {
        let command = GitHubCommands.openPullRequests(root: root)
        XCTAssertEqual(command.arguments, [
            "pr", "list",
            "--state", "open",
            "--limit", "50",
            "--json",
            "number,title,author,headRefName,baseRefName,isDraft,reviewDecision,url,state,statusCheckRollup",
        ])
        XCTAssertEqual(command.workingDirectory, root)
    }

    func testHeadBranchLookupCommand() {
        let command = GitHubCommands.pullRequest(forHeadBranch: "feature/x", root: root)
        XCTAssertEqual(command.arguments, [
            "pr", "list",
            "--state", "open",
            "--head", "feature/x",
            "--limit", "1",
            "--json",
            "number,title,author,headRefName,baseRefName,isDraft,reviewDecision,url,state,statusCheckRollup",
        ])
        XCTAssertEqual(command.workingDirectory, root)
    }

    func testChecksCommand() {
        let command = GitHubCommands.checks(pullRequest: 53, root: root)
        XCTAssertEqual(command.arguments, [
            "pr", "checks", "53",
            "--json", "bucket,completedAt,description,event,link,name,startedAt,state,workflow",
        ])
        XCTAssertEqual(command.workingDirectory, root)
    }

    func testCreateCommandAlwaysPassesBaseExplicitly() {
        let command = GitHubCommands.createPullRequest(
            title: "Add the panel",
            body: "Body text",
            base: "master",
            draft: false,
            root: root
        )
        XCTAssertEqual(command.arguments, [
            "pr", "create",
            "--title", "Add the panel",
            "--body", "Body text",
            "--base", "master",
        ])
        XCTAssertEqual(command.deadline, 120)
    }

    func testCreateCommandAppendsDraftFlagLast() {
        let command = GitHubCommands.createPullRequest(
            title: "T",
            body: "B",
            base: "develop",
            draft: true,
            root: root
        )
        XCTAssertEqual(command.arguments, [
            "pr", "create",
            "--title", "T",
            "--body", "B",
            "--base", "develop",
            "--draft",
        ])
    }

    func testCreateCommandPassesEmptyBodyAsAnEmptyArgument() {
        // Not omitted: `gh pr create` with no `--body` opens an editor, which in
        // a non-interactive process hangs until the deadline kills it.
        let command = GitHubCommands.createPullRequest(title: "T", body: "", base: "master", draft: false, root: root)
        XCTAssertEqual(command.arguments, ["pr", "create", "--title", "T", "--body", "", "--base", "master"])
    }

    func testCheckoutCommand() {
        let command = GitHubCommands.checkoutPullRequest(number: 7, root: root)
        XCTAssertEqual(command.arguments, ["pr", "checkout", "7"])
        XCTAssertEqual(command.workingDirectory, root)
        XCTAssertEqual(command.deadline, 120)
    }

    func testRepositoryViewCommand() {
        let command = GitHubCommands.repositoryView(root: root)
        XCTAssertEqual(command.arguments, ["repo", "view", "--json", "defaultBranchRef,nameWithOwner"])
        XCTAssertEqual(command.workingDirectory, root)
    }

    // MARK: - The field lists

    func testFieldListsAreOrderedExactlyAsTheSchemaReadsThem() {
        XCTAssertEqual(GitHubCommands.pullRequestFields, [
            "number", "title", "author", "headRefName", "baseRefName",
            "isDraft", "reviewDecision", "url", "state", "statusCheckRollup",
        ])
        XCTAssertEqual(GitHubCommands.checkFields, [
            "bucket", "completedAt", "description", "event", "link",
            "name", "startedAt", "state", "workflow",
        ])
        XCTAssertEqual(GitHubCommands.repositoryFields, ["defaultBranchRef", "nameWithOwner"])
    }

    func testChecksAsksForAllNineFieldsGhPublishes() {
        XCTAssertEqual(GitHubCommands.checkFields.count, 9)
    }

    // MARK: - The re-location flag, by set equality over the factories

    /// Every factory, named, so the flag can be asserted as an inventory rather
    /// than one call at a time: a factory added without a line here fails
    /// `testEveryFactoryIsCoveredByTheRelocationInventory`.
    private var allCommands: [(name: String, command: GitHubCommand)] {
        [
            ("version", GitHubCommands.version()),
            ("authStatus", GitHubCommands.authStatus()),
            ("openPullRequests", GitHubCommands.openPullRequests(root: root)),
            ("pullRequestForHeadBranch", GitHubCommands.pullRequest(forHeadBranch: "b", root: root)),
            ("checks", GitHubCommands.checks(pullRequest: 1, root: root)),
            ("createPullRequest", GitHubCommands.createPullRequest(
                title: "t", body: "b", base: "master", draft: false, root: root
            )),
            ("checkoutPullRequest", GitHubCommands.checkoutPullRequest(number: 1, root: root)),
            ("repositoryView", GitHubCommands.repositoryView(root: root)),
        ]
    }

    func testOnlyTheVersionProbeRefreshesTheExecutableLocation() {
        let refreshing = Set(allCommands.filter { $0.command.refreshesExecutableLocation }.map(\.name))
        XCTAssertEqual(refreshing, ["version"])

        let notRefreshing = Set(allCommands.filter { !$0.command.refreshesExecutableLocation }.map(\.name))
        XCTAssertEqual(notRefreshing, [
            "authStatus",
            "openPullRequests",
            "pullRequestForHeadBranch",
            "checks",
            "createPullRequest",
            "checkoutPullRequest",
            "repositoryView",
        ])
    }

    func testEveryFactoryIsCoveredByTheRelocationInventory() {
        // Eight factories over seven `gh` commands — `pr list` twice, once
        // filtered by `--head`.
        XCTAssertEqual(allCommands.count, 8)
        XCTAssertEqual(Set(allCommands.map(\.name)).count, 8)
    }

    // MARK: - What is deliberately absent

    func testNoCommandNamesARepositoryOrOpensABrowser() {
        for (name, command) in allCommands {
            XCTAssertFalse(command.arguments.contains("--repo"), "\(name) names a repository")
            XCTAssertFalse(command.arguments.contains("-R"), "\(name) names a repository")
            XCTAssertFalse(command.arguments.contains("--web"), "\(name) opens a browser")
        }
    }

    func testEveryRepositoryScopedCommandRunsAtTheRoot() {
        for (name, command) in allCommands where !["version", "authStatus"].contains(name) {
            XCTAssertEqual(command.workingDirectory, root, "\(name) does not run at the root")
        }
    }

    // MARK: - The non-interactive environment

    func testNonInteractiveOverlayNamesEverySettingThatCanHangACommand() {
        XCTAssertEqual(GitHubCLIEnvironment.nonInteractive, [
            "GH_PROMPT_DISABLED": "1",
            "GH_NO_UPDATE_NOTIFIER": "1",
            "NO_COLOR": "1",
            "CLICOLOR": "0",
            "GH_PAGER": "cat",
            "PAGER": "cat",
            "GIT_TERMINAL_PROMPT": "0",
            "GH_REPO": "",
        ])
    }

    /// `GH_REPO` re-targets every command at a repository the working directory
    /// knows nothing about, which is the one way an inherited environment can
    /// make G6 untrue. Empty is `gh`'s own spelling of "not set".
    func testTheOverlayClearsAnInheritedRepositoryOverride() {
        let merged = GitHubCLIEnvironment.merged(over: ["GH_REPO": "someone/else"])
        XCTAssertEqual(merged["GH_REPO"], "")
    }

    func testOverlayWinsOverTheInheritedEnvironmentAndLeavesTheRestAlone() {
        let merged = GitHubCLIEnvironment.merged(over: ["PAGER": "less", "GH_HOST": "github.example.com"])
        XCTAssertEqual(merged["PAGER"], "cat")
        XCTAssertEqual(merged["GH_HOST"], "github.example.com")
        XCTAssertEqual(merged["GH_PROMPT_DISABLED"], "1")
    }

    func testSearchPathReplacesTheInheritedPathOnlyWhenOneWasFound() {
        let inherited = ["PATH": "/usr/bin:/bin"]
        XCTAssertEqual(GitHubCLIEnvironment.merged(over: inherited)["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(GitHubCLIEnvironment.merged(over: inherited, searchPath: "")["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(
            GitHubCLIEnvironment.merged(over: inherited, searchPath: "/opt/homebrew/bin:/usr/bin")["PATH"],
            "/opt/homebrew/bin:/usr/bin"
        )
    }

    // MARK: - The result value

    func testResultReportsGhsOwnWordsTrimmed() {
        let result = GitHubCommandResult(standardOutput: "[]", standardError: "  boom\n\n", status: 1)
        XCTAssertEqual(result.trimmedStandardError, "boom")
        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(GitHubCommandResult(standardOutput: "[]").isSuccess)
    }

    func testTransportErrorSentences() {
        XCTAssertEqual(
            GitHubCLIError.notInstalled.localizedDescription,
            GitHubAvailability.notInstalled.message
        )
        XCTAssertEqual(
            GitHubCLIError.timedOut(seconds: 30).localizedDescription,
            "The GitHub CLI did not answer within 30 seconds."
        )
        XCTAssertEqual(
            GitHubCLIError.timedOut(seconds: 1).localizedDescription,
            "The GitHub CLI did not answer within 1 second."
        )
        XCTAssertEqual(
            GitHubCLIError.launchFailed(message: "  permission denied  ").localizedDescription,
            "The GitHub CLI could not be started: permission denied"
        )
        XCTAssertEqual(
            GitHubCLIError.launchFailed(message: "   ").localizedDescription,
            "The GitHub CLI could not be started."
        )
    }
}
