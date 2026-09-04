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
            "number,title,author,headRefName,baseRefName,isDraft,reviewDecision,url,state,statusCheckRollup,"
                + "headRefOid,mergeable,mergeStateStatus",
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
            "number,title,author,headRefName,baseRefName,isDraft,reviewDecision,url,state,statusCheckRollup,"
                + "headRefOid,mergeable,mergeStateStatus",
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

    func testCreateCommandAlwaysPassesTheBaseExplicitly() {
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

    /// The head is deliberately **not** an argument, which is the base's reason
    /// read the other way round: a `--head` value names a ref in the *base*
    /// repository (`gh`'s own help: it "supports `<user>:<branch>` syntax to
    /// select a head repo owned by `<user>`"), so a bare branch name sent from a
    /// fork checkout asks GitHub for that branch in the parent. This layer
    /// composes no `owner/repo` and has no reading of the push remote's owner, so
    /// the resolution is left to `gh`, which reads the branch's tracking
    /// configuration — and the branch-switch window that buys is closed by
    /// `PullRequestModel.create` re-reading the branch after the push instead.
    func testCreateCommandNeverPinsTheHead() {
        let command = GitHubCommands.createPullRequest(
            title: "T",
            body: "B",
            base: "master",
            draft: true,
            root: root
        )
        XCTAssertFalse(command.arguments.contains("--head"))
        XCTAssertFalse(command.arguments.contains("-H"))
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
        let command = GitHubCommands.createPullRequest(
            title: "T",
            body: "",
            base: "master",
            draft: false,
            root: root
        )
        XCTAssertEqual(
            command.arguments,
            ["pr", "create", "--title", "T", "--body", "", "--base", "master"]
        )
    }

    func testCheckoutCommand() {
        let command = GitHubCommands.checkoutPullRequest(number: 7, root: root)
        XCTAssertEqual(command.arguments, ["pr", "checkout", "7"])
        XCTAssertEqual(command.workingDirectory, root)
        XCTAssertEqual(command.deadline, 120)
    }

    func testRepositoryViewCommand() {
        let command = GitHubCommands.repositoryView(root: root)
        XCTAssertEqual(command.arguments, [
            "repo", "view",
            "--json",
            "defaultBranchRef,nameWithOwner,mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed,"
                + "viewerDefaultMergeMethod,deleteBranchOnMerge",
        ])
        XCTAssertEqual(command.workingDirectory, root)
    }

    // MARK: - The wait's one read

    /// `pr view <n>`, not `pr list --head <branch> --limit 1`: a branch name is
    /// not unique across repositories, and a `--head` list of an already-merged
    /// pull request comes back empty rather than answering.
    func testSinglePullRequestCommandAddressesByNumber() {
        let command = GitHubCommands.pullRequest(number: 54, root: root)
        XCTAssertEqual(command.arguments, [
            "pr", "view", "54",
            "--json",
            "number,title,author,headRefName,baseRefName,isDraft,reviewDecision,url,state,statusCheckRollup,"
                + "headRefOid,mergeable,mergeStateStatus",
        ])
        XCTAssertEqual(command.workingDirectory, root)
        XCTAssertEqual(command.deadline, 30)
    }

    /// The one read the wait polls asks for the *same* fields the panel's list
    /// does, which is what makes the row it re-reads the same value the Merge
    /// button was drawn from.
    func testTheSingleReadAsksForTheSameFieldsTheListDoes() {
        let list = GitHubCommands.openPullRequests(root: root)
        let view = GitHubCommands.pullRequest(number: 1, root: root)
        XCTAssertEqual(
            list.arguments[list.arguments.count - 1],
            view.arguments[view.arguments.count - 1]
        )
    }

    func testTheSingleReadNeverFiltersByHeadOrState() {
        let command = GitHubCommands.pullRequest(number: 1, root: root)
        XCTAssertFalse(command.arguments.contains("--head"))
        XCTAssertFalse(command.arguments.contains("--state"))
        XCTAssertFalse(command.arguments.contains("--limit"))
    }

    // MARK: - `pr merge`

    func testMergeCommandSpellsTheMethodAndAlwaysMatchesTheHead() {
        let command = GitHubCommands.mergePullRequest(
            number: 54,
            method: .squash,
            headRefOid: "999005649c31b9c493e8cefac074297a7d304b49",
            subject: "Add the panel (#54)",
            body: "",
            root: root
        )
        XCTAssertEqual(command.arguments, [
            "pr", "merge", "54",
            "--squash",
            "--match-head-commit", "999005649c31b9c493e8cefac074297a7d304b49",
            "--subject", "Add the panel (#54)",
        ])
        XCTAssertEqual(command.workingDirectory, root)
        XCTAssertEqual(command.deadline, 120)
    }

    func testMergeCommandAppendsABodyOnlyWhenThereIsOne() {
        let command = GitHubCommands.mergePullRequest(
            number: 7,
            method: .merge,
            headRefOid: "abc123",
            subject: "S",
            body: "Two paragraphs.",
            root: root
        )
        XCTAssertEqual(command.arguments, [
            "pr", "merge", "7",
            "--merge",
            "--match-head-commit", "abc123",
            "--subject", "S",
            "--body", "Two paragraphs.",
        ])
    }

    /// Unlike `pr create`, whose missing `--body` opens an editor and therefore
    /// hangs a non-interactive process, `pr merge` composes GitHub's own default
    /// body when none is given — so an empty one is omitted rather than sent.
    func testMergeCommandOmitsAnEmptyBodyRatherThanSendingOne() {
        let command = GitHubCommands.mergePullRequest(
            number: 7, method: .merge, headRefOid: "abc123", subject: "S", body: "", root: root
        )
        XCTAssertFalse(command.arguments.contains("--body"))
    }

    /// A rebase composes no commit at all, so neither field is a value GitHub has
    /// anywhere to put — and both are absent even when the caller passes them.
    func testRebaseCarriesNeitherSubjectNorBody() {
        let command = GitHubCommands.mergePullRequest(
            number: 7,
            method: .rebase,
            headRefOid: "abc123",
            subject: "S",
            body: "B",
            root: root
        )
        XCTAssertEqual(command.arguments, [
            "pr", "merge", "7",
            "--rebase",
            "--match-head-commit", "abc123",
        ])
        XCTAssertFalse(command.arguments.contains("--subject"))
        XCTAssertFalse(command.arguments.contains("--body"))
    }

    func testEveryMethodSpellsExactlyOneOfTheThreeFlags() {
        let flags = ["--merge", "--squash", "--rebase"]
        for method in GitHubMergeMethod.allCases {
            let command = GitHubCommands.mergePullRequest(
                number: 1, method: method, headRefOid: "oid", subject: "s", body: "", root: root
            )
            XCTAssertEqual(
                command.arguments.filter { flags.contains($0) }.count,
                1,
                "\(method) spells more or fewer than one merge-method flag"
            )
        }
    }

    /// The three flags that never appear, on any method: merging past the rules
    /// the enabled rule just checked, a server-side promise this app cannot show
    /// or cancel, and a branch deletion this layer does not do.
    func testMergeNeverAdministersAutoMergesOrDeletesABranch() {
        for method in GitHubMergeMethod.allCases {
            let command = GitHubCommands.mergePullRequest(
                number: 1, method: method, headRefOid: "oid", subject: "s", body: "b", root: root
            )
            for banned in ["--admin", "--auto", "--delete-branch", "-d", "--disable-auto", "--body-file"] {
                XCTAssertFalse(command.arguments.contains(banned), "\(method) passes \(banned)")
            }
        }
    }

    /// The head guard is unconditional: there is no method, and no combination of
    /// subject and body, that produces a merge without it.
    func testEveryMergeCarriesTheHeadItWasDecidedFrom() {
        for method in GitHubMergeMethod.allCases {
            for body in ["", "b"] {
                let command = GitHubCommands.mergePullRequest(
                    number: 1, method: method, headRefOid: "deadbeef", subject: "s", body: body, root: root
                )
                let index = command.arguments.firstIndex(of: "--match-head-commit")
                XCTAssertNotNil(index, "\(method) merges without a head guard")
                if let index { XCTAssertEqual(command.arguments[index + 1], "deadbeef") }
            }
        }
    }

    // MARK: - The field lists

    func testFieldListsAreOrderedExactlyAsTheSchemaReadsThem() {
        XCTAssertEqual(GitHubCommands.pullRequestFields, [
            "number", "title", "author", "headRefName", "baseRefName",
            "isDraft", "reviewDecision", "url", "state", "statusCheckRollup",
            "headRefOid", "mergeable", "mergeStateStatus",
        ])
        XCTAssertEqual(GitHubCommands.checkFields, [
            "bucket", "completedAt", "description", "event", "link",
            "name", "startedAt", "state", "workflow",
        ])
        XCTAssertEqual(GitHubCommands.repositoryFields, [
            "defaultBranchRef", "nameWithOwner",
            "mergeCommitAllowed", "squashMergeAllowed", "rebaseMergeAllowed",
            "viewerDefaultMergeMethod", "deleteBranchOnMerge",
        ])
    }

    /// The three fields a merge decision is made of, asked for on **every** row —
    /// the button that offers Merge and the merge itself read the same value.
    func testEveryRowCarriesTheThreeFieldsAMergeIsDecidedFrom() {
        for field in ["headRefOid", "mergeable", "mergeStateStatus"] {
            XCTAssertTrue(GitHubCommands.pullRequestFields.contains(field))
        }
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
            ("pullRequestByNumber", GitHubCommands.pullRequest(number: 1, root: root)),
            ("mergePullRequest", GitHubCommands.mergePullRequest(
                number: 1, method: .squash, headRefOid: "oid", subject: "s", body: "", root: root
            )),
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
            "pullRequestByNumber",
            "mergePullRequest",
        ])
    }

    func testEveryFactoryIsCoveredByTheRelocationInventory() {
        // Ten factories over nine `gh` commands — `pr list` twice, once filtered
        // by `--head`. The wait re-reads a row through `pr view <n>` rather than
        // through a second `pr checks`, which is why the tenth factory is a read.
        XCTAssertEqual(allCommands.count, 10)
        XCTAssertEqual(Set(allCommands.map(\.name)).count, 10)
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
