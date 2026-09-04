import Foundation

/// Every `gh` argument list this app will ever run, composed in one place.
///
/// `DatabaseQuery`'s rule applied to a second composed language: **the app layer
/// spells no `gh` argument anywhere** (`GitHubSourceGatingTests` pins that by
/// reading the sources), so the whole vocabulary is here, in a target that can be
/// asserted byte for byte without linking `Process`. Nine `gh` commands are in
/// scope — `--version`, `auth status`, `pr list`, `pr view`, `pr checks`,
/// `pr create`, `pr checkout`, `pr merge` and `repo view` — reached through ten
/// factories, because the current-branch lookup is `pr list` with a `--head`
/// filter rather than a command of its own.
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

    /// The fields a pull request row is asked for, in order, shared by the list
    /// parser **and** the one-row `pr view` the merge wait polls, so the request
    /// and the schema it is read under cannot drift apart.
    ///
    /// The last three are what a merge decision is made of: the head commit the
    /// row was drawn from (which every merge carries as `--match-head-commit`),
    /// GitHub's mergeability verdict and its merge-state status. They are asked
    /// for on *every* row rather than only on the row being merged, because the
    /// button that offers Merge is drawn from the same value the merge is decided
    /// from — one rule, one table.
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
        "headRefOid",
        "mergeable",
        "mergeStateStatus",
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

    /// The seven fields `repo view` is asked for: the default branch — which *is*
    /// the create sheet's base default — the repository's name, for the panel's
    /// header, and the repository's own merge policy, which is the whole source of
    /// which methods the merge sheet may offer and which one it starts on.
    ///
    /// `deleteBranchOnMerge` is read but never *acted* on: no command here passes
    /// `--delete-branch`, so the flag exists only so the sheet can say what GitHub
    /// is going to do on its own side after the merge.
    public static let repositoryFields = [
        "defaultBranchRef",
        "nameWithOwner",
        "mergeCommitAllowed",
        "squashMergeAllowed",
        "rebaseMergeAllowed",
        "viewerDefaultMergeMethod",
        "deleteBranchOnMerge",
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

    /// `gh pr create`, with `--base` explicit and **the head deliberately left to
    /// `gh`**.
    ///
    /// The base is never left to `gh`'s own default, which for a fork is the
    /// upstream repository's branch — a different pull request from the one the
    /// sheet said it would open.
    ///
    /// The head is the opposite call, and for the reason `--base` exists: a
    /// `--head` argument names a ref **in the base repository**, and `gh`'s own
    /// help says so — it "supports `<user>:<branch>` syntax to select a head repo
    /// owned by `<user>`", which is the only way to name a ref anywhere else.
    /// Sending a bare branch name from a fork checkout therefore asks GitHub for
    /// that branch *in the parent*, where it either does not exist ("no commits
    /// between…") or, worse, is a same-named branch whose commits are somebody
    /// else's. This layer cannot compose the qualified form: it never composes an
    /// `owner/repo` (G6, `GitHubAPI`), the owner of the *push* remote is not in
    /// anything read here, and `gh` does not accept an organization as the
    /// `<user>` at all. Left implicit, `gh` reads the checked-out branch's
    /// tracking configuration and qualifies it itself, which is the one place
    /// that answer is known.
    ///
    /// What the implicit head costs is the branch-switch window — `gh` resolves
    /// the current branch at *its own* launch, and Create pushes first, which
    /// over a slow network is seconds during which the sheet can be dismissed and
    /// a branch switched from the widget or the embedded terminal. That is paid
    /// for where the window is, not here: `PullRequestModel.create` re-reads the
    /// checked-out branch once the push has returned and **refuses** when it is no
    /// longer the branch the sheet's sentence named. Refusing is what an argument
    /// could not do anyway — a pinned `--head` in that situation would have opened
    /// a pull request against a stale remote ref rather than stopping.
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

    /// One pull request, addressed by number — **the merge wait's one read**, and
    /// the only command in the vocabulary that answers for a single row.
    ///
    /// Deliberately `pr view <n>` rather than `pr list --head <branch> --limit 1`.
    /// A `--head` value names a *branch*, and a branch name is not unique across
    /// repositories: a fork's head branch can be spelled exactly like another
    /// one, and `--limit 1` then hands back whichever GitHub happened to order
    /// first, which would turn an ordinary case into a stop with nothing useful to
    /// say. Addressing by number is exact, answers with one object rather than an
    /// array, and needs no discard rule. It also answers for a pull request that
    /// is **no longer open**, which is precisely the "somebody else merged it"
    /// ending the wait has to recognise — a `--head --state open` list would just
    /// come back empty and be indistinguishable from a branch that never had one.
    ///
    /// The field list is ``pullRequestFields``, so the row the wait re-reads is
    /// the same shape, read by the same parser, as the row the button was drawn
    /// from. ``pullRequest(forHeadBranch:root:)`` is untouched and stays the
    /// bottom-bar indicator's.
    public static func pullRequest(number: Int, root: URL) -> GitHubCommand {
        GitHubCommand(
            arguments: [
                "pr", "view", String(number),
                "--json", pullRequestFields.joined(separator: ","),
            ],
            workingDirectory: root,
            deadline: networkDeadline
        )
    }

    /// `gh pr merge <number>` — the feature's third write, and the second command
    /// that changes anything on GitHub's side.
    ///
    /// Four decisions are carried by the argument list rather than by a rule some
    /// view has to remember:
    ///
    /// - **Exactly one method**, spelled from ``GitHubMergeMethod``. `gh` accepts
    ///   at most one of the three and refuses interactively when given none, which
    ///   in a non-interactive process is a hang until the deadline.
    /// - **`--match-head-commit` always**, carrying the head commit the row this
    ///   merge was decided from was drawn with. That is the whole guard against
    ///   merging something other than what was read: a push landing between the
    ///   read and the merge is refused by *GitHub*, in GitHub's words, rather than
    ///   silently merged. It is why ``GitHubPullRequest/headRefOid`` is asked for
    ///   on every row.
    /// - **`--subject`/`--body` only for the two commit-producing methods.** A
    ///   rebase composes no commit at all, so a subject sent with it is a value
    ///   GitHub has nowhere to put. An empty body is *omitted* rather than sent
    ///   empty — unlike `pr create`, whose missing `--body` opens an editor,
    ///   `pr merge` composes GitHub's own default body when none is given.
    /// - **Three flags that never appear**: `--admin` (merging past the repository
    ///   rules the enabled rule just checked), `--auto` (a server-side promise this
    ///   app cannot show, cancel or account for — the wait is the visible,
    ///   cancelable answer to the same question) and `--delete-branch` (this layer
    ///   deletes no branch, local or remote; GitHub's own `deleteBranchOnMerge` is
    ///   read only so the sheet can say what GitHub will do by itself).
    public static func mergePullRequest(
        number: Int,
        method: GitHubMergeMethod,
        headRefOid: String,
        subject: String,
        body: String,
        root: URL
    ) -> GitHubCommand {
        var arguments = [
            "pr", "merge", String(number),
            methodFlag(method),
            "--match-head-commit", headRefOid,
        ]
        if method.composesACommit {
            arguments.append(contentsOf: ["--subject", subject])
            if !body.isEmpty { arguments.append(contentsOf: ["--body", body]) }
        }
        return GitHubCommand(arguments: arguments, workingDirectory: root, deadline: gitNetworkDeadline)
    }

    /// The one place a merge method is spelled as a `gh` flag.
    ///
    /// On the factory rather than on ``GitHubMergeMethod`` for the same reason the
    /// whole file exists: the vocabulary is asserted byte for byte in one file, and
    /// a flag spelled on the vocabulary type would be a `gh` argument living
    /// somewhere the vocabulary rule does not read.
    private static func methodFlag(_ method: GitHubMergeMethod) -> String {
        switch method {
        case .merge: return "--merge"
        case .squash: return "--squash"
        case .rebase: return "--rebase"
        }
    }

    /// `gh repo view` — the only source of the create sheet's default base (G11)
    /// and of the merge sheet's method list.
    public static func repositoryView(root: URL) -> GitHubCommand {
        GitHubCommand(
            arguments: ["repo", "view", "--json", repositoryFields.joined(separator: ",")],
            workingDirectory: root,
            deadline: networkDeadline
        )
    }
}
