import Foundation

/// Every `gh` argument list this app will ever run, composed in one place.
///
/// `DatabaseQuery`'s rule applied to a second composed language: **the app layer
/// spells no `gh` argument anywhere** (`GitHubSourceGatingTests` pins that by
/// reading the sources), so the whole vocabulary is here, in a target that can be
/// asserted byte for byte without linking `Process`. Seven `gh` commands are in
/// scope — `--version`, `auth status`, `pr list`, `pr checks`, `pr create`,
/// `pr checkout` and `repo view` — reached through eight factories, because the
/// current-branch lookup is `pr list` with a `--head` filter rather than a
/// command of its own.
///
/// Two things are deliberately absent. There is **no `--repo` anywhere** (G6):
/// every command runs with its working directory set to the repository root and
/// lets `gh` resolve the repository from the git remote that is already there,
/// which is what makes a GitHub Enterprise checkout work without this app ever
/// composing an `owner/repo` or learning a host. And there is **no `--web`**:
/// nothing here may open a browser, which is a decision the argument lists can
/// carry rather than a rule a view has to remember.
public enum GitHubCommands {
    // MARK: - The `--json` field lists

    /// The fields `pr list` is asked for, in order, shared with the list parser
    /// so the request and the schema it is read under cannot drift apart.
    ///
    /// Ordered rather than a `Set` because the list goes on a command line, and a
    /// suite that asserts the command byte for byte needs one spelling to assert.
    public static let pullRequestFields = [
        "number",
        "title",
        "author",
        "headRefName",
        "baseRefName",
        "isDraft",
        "reviewDecision",
        "url",
        "state",
        "statusCheckRollup",
    ]

    /// The nine fields `pr checks --json` publishes, in `gh`'s own order. Asking
    /// for all nine rather than a subset costs nothing on the wire and keeps the
    /// checks parser reading one shape.
    public static let checkFields = [
        "bucket",
        "completedAt",
        "description",
        "event",
        "link",
        "name",
        "startedAt",
        "state",
        "workflow",
    ]

    /// The two fields `repo view` is asked for: the default branch — which *is*
    /// the create sheet's base default — and the repository's name, for the
    /// panel's header.
    public static let repositoryFields = [
        "defaultBranchRef",
        "nameWithOwner",
    ]

    // MARK: - Deadlines

    /// How long a local, no-network command may take. Generous for a process
    /// launch and a `PATH` walk, and short enough that a hung one does not hold
    /// a refresh open.
    public static let localDeadline: TimeInterval = 15

    /// How long a command that talks to GitHub's API may take.
    public static let networkDeadline: TimeInterval = 30

    /// How long a command that performs *git* network work may take. `pr create`
    /// and `pr checkout` both fetch, which is a different order of magnitude from
    /// one API call.
    public static let gitNetworkDeadline: TimeInterval = 120

    /// How many open pull requests the panel lists. `gh`'s own default is 30; the
    /// panel scrolls, and a repository with more open pull requests than this has
    /// a browser for the rest.
    public static let openListLimit = 50

    // MARK: - The commands

    /// `gh --version`.
    ///
    /// **The one factory carrying `refreshesExecutableLocation`** (G7). It is the
    /// first command of every refresh, so making it the re-location trigger gives
    /// the transport exactly one discovery per refresh and still picks up a `gh`
    /// installed a moment ago from the embedded terminal.
    public static func version() -> GitHubCommand {
        GitHubCommand(
            arguments: ["--version"],
            workingDirectory: nil,
            deadline: localDeadline,
            refreshesExecutableLocation: true
        )
    }

    /// `gh auth status`, judged by exit status alone — its prose goes to stderr.
    public static func authStatus() -> GitHubCommand {
        GitHubCommand(arguments: ["auth", "status"], workingDirectory: nil, deadline: networkDeadline)
    }

    /// The panel's list: every open pull request, newest first as `gh` orders
    /// them.
    public static func openPullRequests(root: URL) -> GitHubCommand {
        GitHubCommand(
            arguments: [
                "pr", "list",
                "--state", "open",
                "--limit", String(openListLimit),
                "--json", pullRequestFields.joined(separator: ","),
            ],
            workingDirectory: root,
            deadline: networkDeadline
        )
    }

    /// The indicator's lookup: the open pull request whose head is `branch`, if
    /// there is one.
    ///
    /// An empty array is the ordinary answer here — most branches have no pull
    /// request — and is "no pull request", never an error.
    public static func pullRequest(forHeadBranch branch: String, root: URL) -> GitHubCommand {
        GitHubCommand(
            arguments: [
                "pr", "list",
                "--state", "open",
                "--head", branch,
                "--limit", "1",
                "--json", pullRequestFields.joined(separator: ","),
            ],
            workingDirectory: root,
            deadline: networkDeadline
        )
    }

    /// One row's per-job checks.
    ///
    /// The **one command whose exit status means nothing** (G3): `gh` documents
    /// exit 8 for "checks pending" and uses exit 1 for "some check failed", both
    /// of which are answers rather than failures. The parser decides on stdout
    /// parsing succeeding.
    public static func checks(pullRequest number: Int, root: URL) -> GitHubCommand {
        GitHubCommand(
            arguments: [
                "pr", "checks", String(number),
                "--json", checkFields.joined(separator: ","),
            ],
            workingDirectory: root,
            deadline: networkDeadline
        )
    }

    /// `gh pr create`, with `--base` **always** explicit.
    ///
    /// Never left to `gh`'s own default: that default is the upstream repository's
    /// branch for a fork, which is a different pull request from the one the sheet
    /// said it would open. The base the sentence names is the base that is sent.
    public static func createPullRequest(
        title: String,
        body: String,
        base: String,
        draft: Bool,
        root: URL
    ) -> GitHubCommand {
        var arguments = [
            "pr", "create",
            "--title", title,
            "--body", body,
            "--base", base,
        ]
        if draft { arguments.append("--draft") }
        return GitHubCommand(arguments: arguments, workingDirectory: root, deadline: gitNetworkDeadline)
    }

    /// `gh pr checkout <number>` — the one command in the vocabulary that
    /// rewrites the worktree, and therefore the only one that runs inside the
    /// writer bracket (G12).
    public static func checkoutPullRequest(number: Int, root: URL) -> GitHubCommand {
        GitHubCommand(
            arguments: ["pr", "checkout", String(number)],
            workingDirectory: root,
            deadline: gitNetworkDeadline
        )
    }

    /// `gh repo view` — the seventh command, and the only source of the create
    /// sheet's default base (G11).
    public static func repositoryView(root: URL) -> GitHubCommand {
        GitHubCommand(
            arguments: ["repo", "view", "--json", repositoryFields.joined(separator: ",")],
            workingDirectory: root,
            deadline: networkDeadline
        )
    }
}
