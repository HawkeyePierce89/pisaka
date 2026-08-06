import Foundation

/// Why "Push after commit" cannot be offered — or, for the last case, why an
/// offered push was not run after all — with the sentence the dialog shows beside
/// the disabled checkbox (the `CommitBlock.message` convention: the decision and
/// its wording are one rule, tested together).
public enum PushUnavailableReason: Equatable {
    /// HEAD is not on a branch (or the branch name could not be read), so there
    /// is nothing to name as the push target.
    case detachedHEAD
    /// The repository has no remote configured.
    case noRemote
    /// The current branch changed between the commit and the push, so the plan
    /// no longer describes the branch that received the commit.
    ///
    /// Unlike the two above, `plan(context:)` never produces this: it is the
    /// verdict of `CommitDialogModel.commit`'s re-read immediately before the
    /// push, which is the only place that can compare two readings of the
    /// repository. It lives here so its wording sits with the other push
    /// refusals rather than in the model.
    case branchChanged

    public var message: String {
        switch self {
        case .detachedHEAD:
            return "HEAD is detached — there is no branch to push."
        case .noRemote:
            return "This repository has no remote to push to."
        case .branchChanged:
            return "The current branch changed while the commit was being created, "
                + "so nothing was pushed. The commit was created — push it from the "
                + "branch that has it."
        }
    }
}

/// What "Push after commit" would do, decided from the repository state alone.
///
/// Pure and Foundation-only; `GitCLIService.push(_:root:)` turns the plan into a
/// command and nothing else decides anything about it.
///
/// **The plan describes the state *after* the commit**, which is why an unborn
/// HEAD is still pushable: git already knows the branch name the first commit
/// will create, so the very first commit of a fresh repository can create its
/// upstream in the same gesture.
public enum PushPlan: Equatable {
    /// The branch has an upstream — `git push` with no arguments, letting git
    /// use the configured tracking ref (which may well be named differently from
    /// the local branch, so naming a refspec here would be a guess). The
    /// `upstream` short ref is carried for display only.
    case push(upstream: String)
    /// No upstream yet — `git push --set-upstream <remote> <branch>`.
    case setUpstream(remote: String, branch: String)
    /// Push cannot be offered at all.
    case unavailable(reason: PushUnavailableReason)

    public var isAvailable: Bool {
        if case .unavailable = self { return false }
        return true
    }

    /// The three branches, in order.
    ///
    /// 1. An upstream exists → a plain push. This is decided **before** the
    ///    remote list, because a configured upstream is something git can push
    ///    through on its own; withdrawing the push because `git remote` came
    ///    back empty (or unread) would refuse an operation that works.
    /// 2. No upstream, but a remote exists → a push that creates the upstream.
    ///    `origin` is preferred; otherwise the first remote is used, which is a
    ///    stable choice because `git remote` prints its remotes sorted — and the
    ///    dialog names the target it picked rather than pushing somewhere
    ///    unannounced.
    /// 3. Otherwise → unavailable, with the reason. A detached (or unreadable)
    ///    HEAD is reported ahead of a missing remote: with no branch name there
    ///    is nothing to push even if a remote were configured.
    public static func plan(context: CommitContext) -> PushPlan {
        let upstream = (context.upstream ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !upstream.isEmpty { return .push(upstream: upstream) }

        let branch = (context.currentBranch ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if context.isDetachedHEAD || branch.isEmpty { return .unavailable(reason: .detachedHEAD) }

        let remotes = context.remotes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let remote = remotes.first(where: { $0 == "origin" }) ?? remotes.first else {
            return .unavailable(reason: .noRemote)
        }
        return .setUpstream(remote: remote, branch: branch)
    }
}
