import Foundation

/// The typed vocabulary of a pull request and its checks (G2).
///
/// Foundation-only value types with no behaviour beyond naming themselves, in the
/// `LeetCodeJudge.swift` shape: the *wire* half — which JSON key holds which of
/// these, and which spelling maps to which case — stays in `GitHubAPI`, the one
/// schema file. These are what that file parses **into**, so the model, the panel
/// and the indicator can speak about a review decision or a checks summary
/// without ever having seen a JSON key.
///
/// Every vocabulary here is **closed**. `gh` hands back GitHub's own GraphQL
/// enums, which are documented and versioned, so a value outside the table is a
/// schema change and is reported as one (`GitHubSchemaError.unknownValue`) rather
/// than folded into a "other" case that would render as a green checkmark for a
/// state nobody has looked at. That is the same reasoning `LeetCodeAPI` records
/// for its own tables, applied to an API that — unlike LeetCode's — actually
/// publishes a contract, which is what makes strictness affordable here.

// MARK: - The two strict rollup tables

/// A `CheckRun`'s `status`: how far along GitHub Actions is with the job.
///
/// The first half of the first strict table. `status` says whether the job is
/// *finished*; `conclusion` says how it went, and is meaningless until this is
/// `.completed` — which is why the summary rule reads the two together and never
/// either alone.
public enum GitHubCheckStatus: String, CaseIterable, Sendable {
    case queued = "QUEUED"
    case inProgress = "IN_PROGRESS"
    case completed = "COMPLETED"
    case waiting = "WAITING"
    case pending = "PENDING"
    case requested = "REQUESTED"

    /// Whether the job has stopped running. The only question the summary rule
    /// asks of a status.
    public var isFinished: Bool { self == .completed }
}

/// A `CheckRun`'s `conclusion`: how a finished job went.
///
/// The second half of the first strict table. Absent — `gh` spells it `""` —
/// until the run completes, which is why every parse of it yields an *optional*
/// rather than a case: "not concluded yet" is a real state and modelling it as a
/// case would put it in the same table as GitHub's own verdicts.
public enum GitHubCheckConclusion: String, CaseIterable, Sendable {
    case success = "SUCCESS"
    case failure = "FAILURE"
    case neutral = "NEUTRAL"
    case cancelled = "CANCELLED"
    case timedOut = "TIMED_OUT"
    case actionRequired = "ACTION_REQUIRED"
    case skipped = "SKIPPED"
    case stale = "STALE"
    case startupFailure = "STARTUP_FAILURE"

    /// Whether this conclusion counts as "the job did not stand in the way".
    ///
    /// Three cases and no more: the job passed, GitHub declined to judge it
    /// (`NEUTRAL`), or it never ran (`SKIPPED`). Everything else — including
    /// `CANCELLED`, `STALE` and `ACTION_REQUIRED`, none of which is a *green*
    /// answer to "can this be merged" — is failing, which is the conservative
    /// direction: a summary that under-reports trouble is the one that costs
    /// somebody a merge.
    public var isPassing: Bool {
        switch self {
        case .success, .neutral, .skipped: return true
        case .failure, .cancelled, .timedOut, .actionRequired, .stale, .startupFailure: return false
        }
    }
}

/// A `StatusContext`'s `state`: the whole of the *second* strict table.
///
/// The legacy commit-status API, which is still what most non-Actions integrations
/// report through. It has no status/conclusion split — one value carries both —
/// so a rollup mixing the two kinds is decided over two different tables, which is
/// exactly why `GitHubRollupItem` keeps them apart instead of flattening them into
/// one "state" string.
public enum GitHubStatusContextState: String, CaseIterable, Sendable {
    case expected = "EXPECTED"
    case pending = "PENDING"
    case success = "SUCCESS"
    case failure = "FAILURE"
    case error = "ERROR"

    /// Whether the integration has reported a verdict yet.
    public var isFinished: Bool {
        switch self {
        case .expected, .pending: return false
        case .success, .failure, .error: return true
        }
    }
}

/// `gh pr checks --json`'s own five-way grouping of a job.
///
/// `gh`'s word, not GitHub's: the CLI collapses statuses and conclusions into
/// these five before printing, and since the per-row checks list is read straight
/// out of that command, this is the vocabulary the expanded rows are drawn from.
/// It is deliberately *not* reused for the summary — that is computed from the
/// rollup's own tables, so the two surfaces cannot disagree about what "pending"
/// means because one of them went through `gh`'s bucketing and the other did not.
public enum GitHubCheckBucket: String, CaseIterable, Sendable {
    case pass
    case fail
    case pending
    case skipping
    case cancel
}

/// A pull request's `reviewDecision`.
///
/// `""` is the ordinary answer, not a violation: a repository with no required
/// review returns it for every pull request, so it maps to ``none`` rather than
/// throwing. That is the one place in this file where an empty string is a value
/// instead of an absence.
///
/// The case is spelled `none` because that is what GitHub means by `""` — no
/// decision has been made — with one caveat worth writing down: compared against
/// an *optional* of this type, a bare `.none` resolves to `Optional.none`, i.e.
/// `nil`. Spell it `GitHubReviewDecision.none` there. Every use inside this layer
/// is non-optional, where the bare form is unambiguous.
public enum GitHubReviewDecision: String, CaseIterable, Sendable {
    case none = ""
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}

// MARK: - The three merge tables

/// A pull request's `mergeable`: GitHub's verdict on whether the merge would
/// apply at all.
///
/// Three values and no more, and the third is a *state*, not a shrug: GitHub
/// computes mergeability lazily, so `UNKNOWN` means the answer is being worked
/// out and a later read will have it. That is why it is one of the two refusals
/// a wait may sit on rather than one it stops at.
public enum GitHubMergeability: String, CaseIterable, Sendable {
    case mergeable = "MERGEABLE"
    case conflicting = "CONFLICTING"
    case unknown = "UNKNOWN"
}

/// A pull request's `mergeStateStatus`: *why* GitHub would or would not take the
/// merge right now.
///
/// The second half of the pair, and the one that carries the repository's rules.
/// `mergeable` answers "would the diff apply"; this answers "will GitHub let you",
/// which is a different question — a pull request with no conflicts at all is
/// `BLOCKED` while a required review is missing and `BEHIND` when the base has
/// moved under a strict-status rule.
///
/// `HAS_HOOKS` and `UNSTABLE` are green here on purpose. `HAS_HOOKS` is a clean
/// state in a repository with pre-receive hooks — GitHub says so — and `UNSTABLE`
/// means non-required checks are failing or still running, which the checks
/// summary is separately, and more precisely, consulted about. Both are allowed
/// by ``GitHubMergePlan`` only *together with* a summary that is green.
///
/// **Eight values: every member GitHub's `MergeStateStatus` declares**, `DRAFT`
/// included. That value is *deprecated* — in favour of `isDraft`, with a removal
/// date long past — but deprecated is not removed, and the table is closed: a
/// value it does not know throws, and this field travels on **every** row of
/// `pr list`, so one draft pull request answering the word GitHub still declares
/// would take the whole list down — no rows, no indicator, no Checkout, no
/// Create — over a field that only gates one button. Carrying the declared
/// member costs a line; omitting it bets the panel on a deprecation notice.
///
/// It changes no decision: ``GitHubMergePlan`` decides a draft from `isDraft`
/// first, and this value reaches the same refusal rather than a second sentence.
public enum GitHubMergeStateStatus: String, CaseIterable, Sendable {
    /// The merge commit cannot be cleanly created.
    case dirty = "DIRTY"
    /// The state cannot be checked yet — the mergeability computation is still
    /// running. The other of the two states a later read can leave.
    case unknown = "UNKNOWN"
    /// Merging is blocked by the repository's own rules.
    case blocked = "BLOCKED"
    /// The head ref is out of date with the base under a strict-status rule.
    case behind = "BEHIND"
    /// Mergeable with non-passing (but not required) checks.
    case unstable = "UNSTABLE"
    /// Mergeable, and the repository has pre-receive hooks.
    case hasHooks = "HAS_HOOKS"
    /// Merging is blocked because the pull request is a draft — GitHub's
    /// deprecated spelling of what `isDraft` says in the field made for it.
    case draft = "DRAFT"
    /// Mergeable, with passing checks and no rule standing in the way.
    case clean = "CLEAN"
}

/// The three ways GitHub can merge a pull request.
///
/// Also what `repo view`'s `viewerDefaultMergeMethod` answers with, which is why
/// this table is read from two commands rather than composed from a picker's
/// index. The **flag** each maps to is deliberately *not* here: it is spelled in
/// `GitHubCommands`, the one file that spells a `gh` argument.
public enum GitHubMergeMethod: String, CaseIterable, Sendable {
    case merge = "MERGE"
    case squash = "SQUASH"
    case rebase = "REBASE"

    /// Whether GitHub composes a commit for this method — and therefore whether a
    /// subject and a body are values it has anywhere to put.
    ///
    /// A rebase replays the pull request's own commits onto the base and writes
    /// nothing of its own, so the merge sheet hides both fields for it and the
    /// command sends neither.
    public var composesACommit: Bool { self != .rebase }
}

// MARK: - The rollup

/// One entry of a pull request's `statusCheckRollup`, kept in the shape its
/// `__typename` gave it.
///
/// The two kinds are **not** normalised into a common "state" on the way in.
/// GitHub genuinely reports them differently — a `CheckRun` is two fields, a
/// `StatusContext` is one — and any normalisation would have to pick a
/// vocabulary, at which point the choice of which table wins is buried in a
/// parser instead of stated in the summary rule where it belongs.
public enum GitHubRollupItem: Equatable, Sendable {
    /// A GitHub Actions (or Checks API) job.
    case checkRun(status: GitHubCheckStatus, conclusion: GitHubCheckConclusion?)
    /// A legacy commit status posted by an integration.
    case statusContext(state: GitHubStatusContextState)

    /// Whether this entry has stopped moving.
    ///
    /// A `CheckRun` that says `COMPLETED` and names no conclusion is reported as
    /// unfinished: GitHub does not do that, and if it ever does, "still running"
    /// is the honest reading of a verdict that is not there.
    public var isFinished: Bool {
        switch self {
        case .checkRun(let status, let conclusion):
            return status.isFinished && conclusion != nil
        case .statusContext(let state):
            return state.isFinished
        }
    }

    /// Whether a **finished** entry counts as passing. Meaningless — and never
    /// asked — while ``isFinished`` is `false`.
    public var isPassing: Bool {
        switch self {
        case .checkRun(_, let conclusion):
            return conclusion?.isPassing ?? false
        case .statusContext(let state):
            return state == .success
        }
    }
}

/// What a pull request's whole rollup adds up to — the one thing the panel row
/// and the bottom-bar indicator both draw.
public enum GitHubChecksSummary: String, CaseIterable, Sendable {
    /// The rollup is empty: this pull request has no checks at all. Distinct from
    /// ``success`` on purpose — "nothing ran" and "everything passed" look the
    /// same only to a badge that has stopped telling the truth.
    case noChecks
    /// At least one job has not finished.
    case pending
    /// Every job finished and at least one did not pass.
    case failure
    /// Every job finished and every one of them passed or was skipped.
    case success
}

// MARK: - The values the surfaces read

/// One open pull request, as the panel lists it.
///
/// The rollup is **not** carried: it is collapsed to ``summary`` at parse time and
/// the array is dropped. The panel shows a summary; the per-job detail an expanded
/// row shows comes from `gh pr checks`, which is a richer answer (it carries each
/// job's link and its workflow) fetched only for the row that was expanded. Keeping
/// both would mean two representations of the same jobs, drawn from two commands,
/// free to disagree.
public struct GitHubPullRequest: Equatable, Sendable, Identifiable {
    /// The pull request number — `#53` — and this value's identity everywhere.
    public let number: Int
    public let title: String
    /// The author's GitHub login. `gh` hands back an object with four keys; this
    /// is the only one the panel shows, and the only one read.
    public let authorLogin: String
    /// The branch the pull request is *from*.
    public let headRefName: String
    /// The branch the pull request is *into*.
    public let baseRefName: String
    public let isDraft: Bool
    public let reviewDecision: GitHubReviewDecision
    /// The `https://…/pull/N` page — what "Open in browser" opens, and the only
    /// URL this feature ever hands to a browser, always on an explicit gesture.
    public let url: String
    /// `OPEN`, `CLOSED` or `MERGED`, carried verbatim as `gh` spelled it.
    ///
    /// The one field in this type without a table behind it, deliberately: every
    /// list this app runs already carries `--state open`, so the value is a
    /// constant in practice and a sixth closed vocabulary would be five cases of
    /// ceremony guarding a filter that is on the command line.
    ///
    /// It is read exactly once, against ``openState``: `pr view <n>` — the merge
    /// wait's one read — is addressed by number rather than filtered by state, so
    /// it is the one command in this feature that can answer for a pull request
    /// somebody else has just merged or closed.
    public let state: String

    /// The one value of ``state`` this app ever compares against.
    ///
    /// A constant rather than a table, for the field's own reason: two callers
    /// spelling `"OPEN"` by hand is the accident a table would be over-built to
    /// prevent, and one of them is a wait whose ending depends on it.
    public static let openState = "OPEN"
    /// The rollup, collapsed by ``GitHubChecksSummary/summarise(_:)``.
    public let summary: GitHubChecksSummary
    /// The head branch's commit SHA **as this row was read**.
    ///
    /// Carried on every row rather than fetched for the row being merged, because
    /// it is the guard on the merge: every `gh pr merge` this app runs passes it
    /// as `--match-head-commit`, so a push that lands between the read the button
    /// was drawn from and the merge itself is refused by GitHub rather than
    /// merged. A wait re-reading the row every tick therefore merges against the
    /// head *that tick* saw, with no head-tracking rule of its own.
    public let headRefOid: String
    /// GitHub's verdict on whether the merge would apply.
    public let mergeable: GitHubMergeability
    /// GitHub's answer to why it would or would not take the merge now.
    public let mergeStateStatus: GitHubMergeStateStatus

    public var id: Int { number }

    public init(
        number: Int,
        title: String,
        authorLogin: String,
        headRefName: String,
        baseRefName: String,
        isDraft: Bool,
        reviewDecision: GitHubReviewDecision,
        url: String,
        state: String,
        summary: GitHubChecksSummary,
        headRefOid: String,
        mergeable: GitHubMergeability,
        mergeStateStatus: GitHubMergeStateStatus
    ) {
        self.number = number
        self.title = title
        self.authorLogin = authorLogin
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.url = url
        self.state = state
        self.summary = summary
        self.headRefOid = headRefOid
        self.mergeable = mergeable
        self.mergeStateStatus = mergeStateStatus
    }
}

/// One job in an expanded row's checks list — a row of `gh pr checks --json`.
public struct GitHubCheckRow: Equatable, Sendable {
    /// The job's name (`build-macos`).
    public let name: String
    /// The workflow it belongs to (`CI`), empty for a status context.
    public let workflow: String
    /// `gh`'s five-way grouping — what the row's marker is drawn from.
    public let bucket: GitHubCheckBucket
    /// `gh`'s own word for the state (`SUCCESS`, `IN_PROGRESS`, …), carried
    /// verbatim and shown as text.
    ///
    /// Not a table: `gh` fills this from a conclusion, a status *or* a context
    /// state depending on the row, so the closed vocabulary that would cover it is
    /// the union of three tables — and ``bucket``, which is what the row is
    /// actually decided by, is already strict.
    public let state: String
    /// The integration's own one-line summary, frequently empty.
    public let description: String
    /// The job's page. Empty when the integration published none, which is why
    /// the panel offers the link conditionally.
    public let link: String
    /// When the job started, or `nil` when it has not.
    public let startedAt: Date?
    /// When the job finished, or `nil` when it has not.
    public let completedAt: Date?

    public init(
        name: String,
        workflow: String,
        bucket: GitHubCheckBucket,
        state: String,
        description: String,
        link: String,
        startedAt: Date?,
        completedAt: Date?
    ) {
        self.name = name
        self.workflow = workflow
        self.bucket = bucket
        self.state = state
        self.description = description
        self.link = link
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

/// What `gh repo view` answered: the repository's name and its default branch.
///
/// The default branch is the *only* source of the create sheet's base (G11), and
/// the reason `repo view` is the seventh command in scope at all.
public struct GitHubRepository: Equatable, Sendable {
    /// `owner/repo`, as GitHub spells it — read from `gh`, never composed here
    /// (G6).
    public let nameWithOwner: String
    /// The default branch's name (`master`).
    public let defaultBranch: String
    /// Whether the repository allows an ordinary merge commit.
    public let mergeCommitAllowed: Bool
    /// Whether the repository allows squash-merging.
    public let squashMergeAllowed: Bool
    /// Whether the repository allows rebase-merging.
    public let rebaseMergeAllowed: Bool
    /// The method GitHub would start this viewer on, whatever the three flags
    /// above say.
    ///
    /// Read rather than guessed: a repository can allow all three and still have
    /// a preferred one, and the merge sheet opening on something other than what
    /// GitHub itself would have chosen is a surprise nobody asked for. It is
    /// nonetheless *checked* against the allowed set — GitHub has been known to
    /// answer with a method the repository has since disallowed — which is
    /// ``GitHubMergePlan``'s job, not this value's.
    public let viewerDefaultMergeMethod: GitHubMergeMethod
    /// Whether GitHub deletes the head branch by itself once the merge lands.
    ///
    /// Read only so the merge sheet can *say* so. Nothing here passes
    /// `--delete-branch`: this layer deletes no branch, local or remote.
    public let deleteBranchOnMerge: Bool

    public init(
        nameWithOwner: String,
        defaultBranch: String,
        mergeCommitAllowed: Bool,
        squashMergeAllowed: Bool,
        rebaseMergeAllowed: Bool,
        viewerDefaultMergeMethod: GitHubMergeMethod,
        deleteBranchOnMerge: Bool
    ) {
        self.nameWithOwner = nameWithOwner
        self.defaultBranch = defaultBranch
        self.mergeCommitAllowed = mergeCommitAllowed
        self.squashMergeAllowed = squashMergeAllowed
        self.rebaseMergeAllowed = rebaseMergeAllowed
        self.viewerDefaultMergeMethod = viewerDefaultMergeMethod
        self.deleteBranchOnMerge = deleteBranchOnMerge
    }
}
