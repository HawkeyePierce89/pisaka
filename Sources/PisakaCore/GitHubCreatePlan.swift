import Foundation

/// The New Pull Request sheet's pure half: may a pull request be opened from
/// here, into what, and what has to happen to the branch first (G11).
///
/// Pure and Foundation-only, the way `PushPlan` and `CommitGate` are: the sheet
/// draws what this decides and decides nothing itself, and
/// `PullRequestModel.create(title:body:base:draft:)` refuses on the very value
/// the sheet drew its disabled Create button from — one rule, read from both
/// sides, rather than a view-side guard and a model-side guard free to disagree.
///
/// **The refusals are `PushUnavailableReason`'s, verbatim** — `.detachedHEAD`
/// and `.noRemote`, with the sentences the commit dialog already shows. That is
/// not a convenience: they are literally the same two refusals. A pull request
/// is a request to merge a *branch* that exists *on a remote*, so a head that is
/// not a branch and a repository with nowhere to publish it are the same two
/// impossibilities the commit dialog's push half already names, and giving them
/// second wording here would mean two sentences for one state of the
/// repository. The third case, `.branchChanged`, is never produced here for the
/// reason `PushPlan.plan(context:)` never produces it either: it is a verdict
/// about two readings of the repository, and this plan is made from one.
///
/// **There is a third way Create is off, and it carries no sentence of its
/// own**: an empty ``base``. The base *default* is `gh repo view`'s answer and
/// nothing else (G11), so a `repo view` that failed leaves nothing selected and
/// Create disabled — with `gh`'s own words already in the model's one message
/// slot. Inventing a sentence here would print a second, vaguer explanation
/// underneath the real one. The picker itself still lists the local branches it
/// always lists, so a reader who knows the base can name it and go on; what a
/// failed `repo view` costs is the default, not the sheet.
///
/// **Every sentence names what will actually be done**, because the sheet's
/// Create button performs up to three operations the user did not separately ask
/// for: a push, possibly the creation of an upstream, and the pull request. The
/// base is stated because `gh`'s own default would be the *upstream* repository's
/// branch for a fork — a different pull request from the one the sheet is
/// describing, which is why the model always sends `--base` explicitly — and the
/// remote is stated because publishing a branch to a remote for the first time
/// is a visible, public act.
public struct GitHubCreatePlan: Equatable {

    /// The branch the pull request will be opened *into*, trimmed. Empty when
    /// `repo view` did not answer — the third way Create is off.
    public let base: String

    /// The branch it will be opened *from*, trimmed. Empty on a detached HEAD,
    /// which is also the `.detachedHEAD` refusal.
    ///
    /// The **local** short name — what the sheet's sentences name and what the
    /// reader is standing on. What `gh` is sent is ``remoteHeadBranch``.
    public let headBranch: String

    /// The branch the push above will actually publish, and therefore the one
    /// `--head` names — which is a *remote* ref name, not a local one.
    ///
    /// The two are the same for almost every branch, and deliberately not
    /// assumed to be: `PushPlan.push(upstream:)` is a bare `git push`, which
    /// publishes to the branch's configured tracking ref, and `PushPlan`'s own
    /// rule is that that ref "may well be named differently from the local
    /// branch" — which is why it composes no refspec. Sending the *local* name
    /// as `--head` would make exactly the guess `PushPlan` refuses to make, and
    /// on a branch pushed as `HEAD:other-name` (or a renamed local branch) it
    /// asks GitHub to open a pull request from a ref that is stale or absent:
    /// `gh` either refuses with "no commits between…" or opens the pull request
    /// from the wrong remote branch. The feature already knows `--head` is a
    /// remote ref — the checkout trigger names the pull request's own
    /// `headRefName` for that very reason (G9) — so the create half names it
    /// too.
    ///
    /// Derived, never guessed: the remote's name is stripped off the upstream
    /// short ref by matching it against the repository's own remote list, so a
    /// branch called `feature/x` under a remote called `origin` is read as
    /// `feature/x` and not as `x`. `setUpstream` publishes under the local name
    /// by construction (`git push --set-upstream <remote> <branch>`), and an
    /// upstream no remote in the list explains falls back to ``headBranch`` —
    /// the value that was sent before this was derived at all.
    public let remoteHeadBranch: String

    /// What has to happen to ``headBranch`` before `gh pr create` can run, and
    /// where the two refusals live.
    ///
    /// The commit dialog's plan, unchanged: the head branch is pushed on both of
    /// its available branches, because `gh pr create` compares a *remote* head
    /// against the base and a branch that was never pushed — or was pushed three
    /// commits ago — makes a pull request that is missing the work it was opened
    /// for.
    public let push: PushPlan

    /// `remoteHeadBranch` defaults to `headBranch`, which is what it resolves to
    /// for every branch whose tracking ref carries its own name.
    public init(base: String, headBranch: String, push: PushPlan, remoteHeadBranch: String? = nil) {
        self.base = base
        self.headBranch = headBranch
        self.push = push
        self.remoteHeadBranch = remoteHeadBranch ?? headBranch
    }

    /// Decide from the repository state the sheet opened over and the base the
    /// picker is showing.
    ///
    /// `base` is `gh repo view`'s default branch when the sheet opened, or
    /// whatever the picker has been moved to since; `nil` (or blank) is a
    /// `repo view` that did not answer.
    public static func plan(context: CommitContext, base: String?) -> GitHubCreatePlan {
        let push = PushPlan.plan(context: context)
        let headBranch = (context.currentBranch ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return GitHubCreatePlan(
            base: (base ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            headBranch: headBranch,
            push: push,
            remoteHeadBranch: remoteHead(push: push, remotes: context.remotes, headBranch: headBranch)
        )
    }

    /// The remote branch ``push`` will publish to — see ``remoteHeadBranch``.
    ///
    /// The remote list is matched **longest name first**, so a repository
    /// carrying both `origin` and `origin/mirror` as remote names strips the one
    /// that actually explains the upstream rather than whichever came first.
    private static func remoteHead(push: PushPlan, remotes: [String], headBranch: String) -> String {
        guard case .push(let upstream) = push else { return headBranch }
        let names = remotes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        for remote in names where upstream.hasPrefix(remote + "/") {
            let branch = String(upstream.dropFirst(remote.count + 1))
            return branch.isEmpty ? headBranch : branch
        }
        return headBranch
    }

    /// Why a pull request cannot be opened from here at all, or `nil` when it
    /// can be — an empty ``base`` is not one of these (see the type's note).
    public var refusal: PushUnavailableReason? {
        guard case .unavailable(let reason) = push else { return nil }
        return reason
    }

    /// Whether Create may run: no refusal, a head branch to open it from, and a
    /// base to open it into.
    public var canCreate: Bool {
        refusal == nil && !headBranch.isEmpty && !base.isEmpty
    }

    /// The sentence naming the base that will be used — `nil` when there is
    /// nothing truthful to name.
    ///
    /// Named rather than implied by the picker's selection because the picker is
    /// a control the eye slides over and this is the one irreversible choice on
    /// the sheet: a pull request opened into the wrong base is closed and
    /// reopened, not edited into place.
    /// **It names the branch GitHub will see.** When the tracking ref carries a
    /// different name from the local branch, the pull request really is opened
    /// from that ref, and a sentence naming the local one would describe a pull
    /// request nobody is about to create — so the local name is kept, in
    /// parentheses, as the thing the reader recognizes.
    public var baseSentence: String? {
        guard canCreate else { return nil }
        guard remoteHeadBranch == headBranch else {
            return "The pull request will be opened from “\(remoteHeadBranch)” "
                + "(the branch “\(headBranch)” tracks) into “\(base)”."
        }
        return "The pull request will be opened from “\(headBranch)” into “\(base)”."
    }

    /// The sentence naming what will happen to the branch before the pull
    /// request is created — `nil` when nothing will, which is only ever a
    /// refusal.
    ///
    /// Both available `PushPlan` branches get one, because the model pushes on
    /// both; the `setUpstream` wording is the one the ticket requires by name,
    /// since publishing a branch to a remote for the first time is the case
    /// where the user may not expect a remote to be touched at all.
    public var publishSentence: String? {
        switch push {
        case .setUpstream(let remote, let branch):
            return "“\(branch)” has no upstream yet — it will be published to “\(remote)” "
                + "before the pull request is created."
        case .push(let upstream):
            return "“\(headBranch)” will be pushed to “\(upstream)” before the pull request is created."
        case .unavailable:
            return nil
        }
    }

    /// The line every create sheet shows, whatever the repository state.
    ///
    /// A pull request is made of *pushed commits*, and the sheet is reached from
    /// an editor with a Local Changes panel one tab away: the reader who has just
    /// saved a file and opened this sheet is exactly the reader who assumes it
    /// ships what they are looking at. Stated once, always, rather than
    /// conditionally on a dirty worktree — a sentence that appears only sometimes
    /// is a sentence nobody has read before the one time it matters.
    public static let uncommittedChangesNote =
        "Uncommitted changes will not be part of the pull request."
}
