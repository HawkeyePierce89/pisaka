import Foundation

/// Why a pull request cannot be merged from here — one closed table, each case
/// carrying the sentence the surfaces show and the two questions the wait asks
/// of it.
///
/// The sentences live on the refusal rather than in the sheet for the reason
/// `PushUnavailableReason`'s do: the model refuses on the same value the button
/// was drawn from, and a wait ticking every 30 s stops on it too, so three
/// readers would otherwise be free to word one state three ways.
///
/// **The two questions are answered here and re-derived nowhere.** A view asking
/// "should this button read *Merge when checks pass*" and a wait asking "is this
/// tick's answer one a later tick can leave" are asking about the *same* states,
/// and a second enumeration of them in either file is a table that can drift out
/// of step with this one.
public enum GitHubMergeRefusal: String, CaseIterable, Equatable, Sendable {

    /// The pull request is a draft.
    ///
    /// Decided from `isDraft` alone, never from `mergeStateStatus`: GitHub
    /// deprecated `DRAFT` in that enum in favour of `isDraft` and no longer emits
    /// it, so a draft answers `BLOCKED` there — which is a sentence about the
    /// repository's rules rather than about this pull request's state.
    case draft

    /// The diff no longer applies — `CONFLICTING`, or a `DIRTY` merge state.
    case conflicts

    /// At least one check has not finished.
    ///
    /// **Judged before ``blocked``**, which is the one ordering decision in the
    /// table that changes behaviour: a repository with a required check reports
    /// `BLOCKED` for the whole time that check is running, so reading the merge
    /// state first would stop a wait on "GitHub's rules are blocking the merge"
    /// in exactly the state the wait exists to sit through.
    case checksRunning

    /// Every check finished and at least one did not pass.
    case checksFailed

    /// GitHub has not finished computing mergeability — `UNKNOWN` on either
    /// field. A state, not a shrug: a later read has the answer.
    case mergeabilityUnknown

    /// The head is out of date with the base under a strict-status rule.
    case behind

    /// The repository's own rules stand in the way — a required review, a
    /// required check that has not been run at all, a ruleset.
    case blocked

    /// The sentence shown under the disabled button, in the sheet's message
    /// slot, and by the wait when it stops here.
    ///
    /// Two of them deliberately name no branch: this value is decided from one
    /// pull request but read by a wait that re-decides from another reading of
    /// it, so a sentence carrying a ref would have to be rebuilt on every tick
    /// to stay true. What the merge is *about* is stated once, by
    /// ``GitHubMergePlan/mergeSentence``, from the row in hand.
    public var message: String {
        switch self {
        case .draft:
            return "This pull request is a draft. Mark it ready for review on GitHub before merging."
        case .conflicts:
            return "This pull request has conflicts with its base branch. Resolve them before merging."
        case .checksRunning:
            return "Checks are still running."
        case .checksFailed:
            return "Some checks did not pass."
        case .mergeabilityUnknown:
            return "GitHub has not finished computing mergeability — refresh in a moment."
        case .behind:
            return "The head branch is behind its base branch. Update it on GitHub before merging."
        case .blocked:
            return "GitHub’s rules for this repository are blocking the merge — "
                + "a required review or a required check is missing."
        }
    }

    /// Whether a wait may be **armed** from this state — the sheet's *Merge when
    /// checks pass*.
    ///
    /// Checks still running, and nothing else. Unknown mergeability is a state a
    /// later tick can leave (see ``mayResolveByWaiting``) but it is not one a
    /// reader would ever *choose* to wait on: it clears in seconds, the button
    /// under it says to refresh, and offering to sit on it for half an hour
    /// would put a 30-minute promise behind a two-second computation.
    public var isArmable: Bool { self == .checksRunning }

    /// Whether a wait already armed may **keep** waiting on this tick's answer.
    ///
    /// The two computing states: checks still running, and mergeability not yet
    /// computed. Everything else is a fact about the pull request or the
    /// repository that a later read cannot change on its own, so a wait that sat
    /// on it would burn its whole deadline to end with the sentence it already
    /// had.
    public var mayResolveByWaiting: Bool {
        switch self {
        case .checksRunning, .mergeabilityUnknown: return true
        case .draft, .conflicts, .checksFailed, .behind, .blocked: return false
        }
    }
}

/// The merge sheet's pure half: may this pull request be merged from here, by
/// which methods, and what does the sheet say above the button (G13).
///
/// `GitHubCreatePlan`'s shape, and for the same reason: the sheet draws what
/// this decides and decides nothing itself, `PullRequestModel.merge(…)` refuses
/// on the very value the disabled button was drawn from, and — the part this
/// plan has that the create plan does not — **every tick of
/// `PullRequestMergeWait` re-decides through this same value**. One rule, three
/// readers, no second table.
///
/// **That the wait reads this and not `gh pr checks` is the feature's
/// load-bearing decision.** The checks command answers about *jobs*; it cannot
/// see `mergeable` or `mergeStateStatus`, so checks can turn green while GitHub
/// still answers `BLOCKED`, `BEHIND` or `UNKNOWN`. A wait deciding "green" from
/// the jobs table would hand a merge to a plan that refuses it, and the merge
/// would be refused by `gh` in words about a state the wait never looked at.
///
/// **The enabled rule is a conjunction of four facts** — not a draft, the diff
/// applies, GitHub's merge state is one of the three green ones, and the checks
/// summary is green or empty — and every other combination is one of the seven
/// refusals above, in the order this file states.
public struct GitHubMergePlan: Equatable, Sendable {

    /// The row the plan was decided from — the same value the button is drawn
    /// from, and, in a wait, the row *this tick* read.
    ///
    /// Carried whole rather than reduced to the four fields the rule reads,
    /// because the merge is guarded by this row's ``GitHubPullRequest/headRefOid``
    /// and the sheet's sentences name this row's refs: a plan and a head from two
    /// different readings is the one mismatch `--match-head-commit` exists to
    /// prevent.
    public let pullRequest: GitHubPullRequest

    /// What `gh repo view` answered — the three method flags, the viewer's
    /// default, and whether GitHub deletes the head branch itself.
    public let repository: GitHubRepository

    /// The branch checked out in the working directory when the plan was made,
    /// trimmed; empty on a detached HEAD or when it could not be read.
    ///
    /// Read only to decide whether the post-merge tail is owed: merging a row
    /// whose head is some other branch moves nothing local.
    public let checkedOutBranch: String

    /// Private, so ``plan(pullRequest:repository:checkedOutBranch:)`` is the one
    /// way a plan is made: the trimming it does is not cosmetic —
    /// ``isTailOwed`` is an exact comparison against a branch name, and a plan
    /// built around this would decide the post-merge tail from an untrimmed one.
    private init(
        pullRequest: GitHubPullRequest,
        repository: GitHubRepository,
        checkedOutBranch: String
    ) {
        self.pullRequest = pullRequest
        self.repository = repository
        self.checkedOutBranch = checkedOutBranch
    }

    /// Decide from the row the panel listed and the repository `gh repo view`
    /// described.
    public static func plan(
        pullRequest: GitHubPullRequest,
        repository: GitHubRepository,
        checkedOutBranch: String?
    ) -> GitHubMergePlan {
        GitHubMergePlan(
            pullRequest: pullRequest,
            repository: repository,
            checkedOutBranch: (checkedOutBranch ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - The one rule

    /// The three merge states GitHub itself calls mergeable.
    ///
    /// `HAS_HOOKS` is a clean state in a repository with pre-receive hooks, and
    /// `UNSTABLE` means non-required checks are failing or still running — which
    /// is a question the checks summary answers far more precisely, and does,
    /// in the same conjunction.
    private static let greenMergeStates: Set<GitHubMergeStateStatus> = [.clean, .hasHooks, .unstable]

    /// Why the merge cannot run, or `nil` when it can.
    ///
    /// The order below **is** the rule: draft, conflicts, checks, mergeability,
    /// behind, blocked. Only one pair of it is load-bearing — checks before
    /// blocked, for the reason ``GitHubMergeRefusal/checksRunning`` records —
    /// and the rest is written most-specific-first so the sentence names the
    /// thing the reader can act on.
    public var refusal: GitHubMergeRefusal? {
        if pullRequest.isDraft { return .draft }
        if pullRequest.mergeable == .conflicting || pullRequest.mergeStateStatus == .dirty {
            return .conflicts
        }
        if pullRequest.summary == .pending { return .checksRunning }
        if pullRequest.summary == .failure { return .checksFailed }
        if pullRequest.mergeable == .unknown || pullRequest.mergeStateStatus == .unknown {
            return .mergeabilityUnknown
        }
        if pullRequest.mergeStateStatus == .behind { return .behind }
        if !Self.greenMergeStates.contains(pullRequest.mergeStateStatus) { return .blocked }
        return nil
    }

    /// Whether Merge may run: no refusal, and a method to run it by.
    ///
    /// The second term is the create plan's empty base read again — the way this
    /// is off *without a sentence*. A repository that allows none of the three
    /// methods offers nothing to send, and GitHub does not permit that state, so
    /// inventing a sentence for it would be a line nobody will ever read
    /// explaining a configuration nobody can make. What it must not do is enable
    /// a button whose command has no flag.
    public var canMerge: Bool {
        refusal == nil && !allowedMethods.isEmpty
    }

    // MARK: - The methods

    /// The methods this repository allows, in `GitHubMergeMethod`'s own
    /// declaration order — merge, squash, rebase.
    ///
    /// A stated order rather than an incidental one: it is what the picker shows
    /// and what ``defaultMethod`` falls back through, so it is read off the one
    /// table both facts already come from rather than composed here.
    public var allowedMethods: [GitHubMergeMethod] {
        GitHubMergeMethod.allCases.filter { method in
            switch method {
            case .merge: return repository.mergeCommitAllowed
            case .squash: return repository.squashMergeAllowed
            case .rebase: return repository.rebaseMergeAllowed
            }
        }
    }

    /// The method the sheet opens on: the viewer's own default when the
    /// repository still allows it, otherwise the first allowed one.
    ///
    /// The fallback is not defensive dressing — GitHub answers
    /// `viewerDefaultMergeMethod` from a stored preference that a repository can
    /// have disallowed since, and opening the sheet on a method whose flag is off
    /// would send a `gh pr merge` GitHub refuses.
    public var defaultMethod: GitHubMergeMethod? {
        let allowed = allowedMethods
        if allowed.contains(repository.viewerDefaultMergeMethod) {
            return repository.viewerDefaultMergeMethod
        }
        return allowed.first
    }

    /// Whether the sheet shows a method picker at all.
    ///
    /// A property of the plan rather than a `count > 1` in the view, because it
    /// is a statement about the repository — one allowed method is not a choice,
    /// and a picker with one row is a control that asks a question with one
    /// answer.
    public var showsMethodPicker: Bool { allowedMethods.count > 1 }

    // MARK: - The sheet's sentences

    /// The pre-filled commit subject — GitHub's own default, `<title> (#N)`.
    ///
    /// Sent for the two commit-producing methods and for neither rebase field
    /// (`GitHubMergeMethod.composesACommit`); pre-filled rather than left empty
    /// so a reader who changes nothing gets the subject GitHub would have
    /// written anyway.
    public var defaultSubject: String {
        "\(pullRequest.title) (#\(pullRequest.number))"
    }

    /// The line naming what will be merged into what.
    ///
    /// Shown **whether or not Merge is enabled**, which is where it parts
    /// company with `GitHubCreatePlan.baseSentence`: that sheet's base comes from
    /// a picker whose default can be missing, while these two refs are read off
    /// the row the sheet was opened on and are true even while the button under
    /// them is greyed out — which is exactly when a reader is looking for what
    /// the sheet is about.
    public var mergeSentence: String {
        "“\(pullRequest.headRefName)” will be merged into “\(pullRequest.baseRefName)”."
    }

    /// The line naming GitHub's own branch deletion — `nil` when the repository
    /// does not do it.
    ///
    /// Stated because it is a destructive act this app neither performs nor can
    /// prevent: nothing here passes `--delete-branch`, so the sentence says who
    /// is doing it.
    public var deleteBranchSentence: String? {
        guard repository.deleteBranchOnMerge else { return nil }
        return "This repository deletes head branches on merge — "
            + "GitHub will delete “\(pullRequest.headRefName)” once the merge lands."
    }

    /// Whether the post-merge tail is owed: the merged head is the branch the
    /// working directory is standing on.
    ///
    /// Exact, case-sensitive comparison, because git's refs are.
    ///
    /// **A name, and deliberately not a repository — the feature's one stated
    /// limit here.** `headRefName` is a branch name in whichever repository the
    /// pull request was opened from, so a pull request from a *fork* whose head
    /// is spelled the same as the local branch reads as owed when nothing local
    /// moved. It is the ambiguity `pr list --head` already carries for
    /// ``PullRequestModel/currentBranchPullRequest`` (a fork's head ref both
    /// names a branch this checkout did not create and is free to match another
    /// fork's pull request of the same name), reached through a second door —
    /// and it is left standing rather than closed with a `isCrossRepository`
    /// field for what it actually costs: the common shape, a contributor's fork
    /// `main` merged into `main` while standing on `main`, resolves to a switch
    /// to the branch already checked out and a `--ff-only` pull of the base that
    /// was just merged into, which is what the tail is *for*. The misfire that
    /// remains — a fork head sharing a name with some *other* local branch the
    /// reader happens to be on — moves the worktree, and everything that move
    /// costs is bounded by the two guards it still passes: the dirty-tree
    /// confirmation ahead of the switch, and a pull that is `--ff-only` and can
    /// therefore rewrite nothing.
    public var isTailOwed: Bool {
        !checkedOutBranch.isEmpty && pullRequest.headRefName == checkedOutBranch
    }

    // MARK: - The button, decided here

    /// What the sheet's primary button says when pressing it merges now.
    public static let mergeButtonTitle = "Merge"

    /// What it says when pressing it arms a wait instead.
    ///
    /// The label *is* the promise the wait then keeps, which is why it is stated
    /// beside the rule that decides between the two rather than in the view: a
    /// button reading "Merge" that quietly armed a half-hour wait, or one reading
    /// "Merge when checks pass" that merged immediately, are the same bug written
    /// two ways.
    public static let armButtonTitle = "Merge when checks pass"

    /// Whether pressing the button **arms a wait** rather than merging now.
    ///
    /// The plan's refusal being ``GitHubMergeRefusal/isArmable`` — checks still
    /// running, and nothing else — plus the second term ``canMerge`` carries for
    /// the same reason: a repository that allows no merge method has nothing to
    /// send now and nothing to send in half an hour either, and
    /// ``PullRequestMergeWait/arm(plan:method:subject:body:)`` refuses it
    /// silently, which from a button that offered it would look like a press that
    /// did nothing.
    public var armsWait: Bool {
        refusal?.isArmable == true && !allowedMethods.isEmpty
    }

    /// The button's label: ``mergeButtonTitle`` or ``armButtonTitle``.
    public var buttonTitle: String {
        armsWait ? Self.armButtonTitle : Self.mergeButtonTitle
    }

    /// Whether the button does anything at all in this state — merge now, or arm
    /// a wait. Every other refusal disables it, under its own sentence.
    public var buttonIsOffered: Bool { canMerge || armsWait }

    /// The button's whole gate, including the two things only the open sheet
    /// knows: which method is selected, and what has been typed into the subject.
    ///
    /// Here rather than in the view for `GitHubCreatePlan`'s reason: the method
    /// must be one this repository allows — the same refusal
    /// ``PullRequestModel/merge(number:method:subject:body:)`` makes, and the one
    /// the wait's arming makes — and a commit-producing method needs a subject to
    /// put in the commit, since `--subject ""` is a merge commit with no message.
    /// A rebase needs neither field and is never held up by an empty one.
    public func buttonIsEnabled(method: GitHubMergeMethod, subject: String) -> Bool {
        guard buttonIsOffered, allowedMethods.contains(method) else { return false }
        guard method.composesACommit else { return true }
        return Self.hasSubject(subject)
    }

    /// Whether `subject` is a subject at all.
    ///
    /// Its own member because three callers ask it and a rule enforced only by
    /// which button is greyed out is a rule the next caller walks past — the
    /// reason ``PullRequestModel/mergeMethodMissingMessage`` exists beside it:
    /// ``buttonIsEnabled(method:subject:)`` draws the button,
    /// `PullRequestModel.merge(number:method:subject:body:)` refuses the write
    /// and ``PullRequestMergeWait/arm(plan:method:subject:body:)`` refuses the
    /// arming, all three reading one definition of blank.
    public static func hasSubject(_ subject: String) -> Bool {
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The line naming the tail — `nil` when the merge moves nothing local.
    ///
    /// Named on the sheet rather than announced afterwards because the tail is
    /// two worktree operations the user did not separately ask for: a branch
    /// switch and a pull.
    public var tailSentence: String? {
        guard isTailOwed else { return nil }
        return "After merging, Pisaka will switch to “\(pullRequest.baseRefName)” and pull it."
    }
}
