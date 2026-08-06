import Foundation

/// A git operation the repository is in the middle of, detected from the marker
/// files git leaves in the git directory.
///
/// It exists for one purpose: the commit dialog **refuses to commit while one is
/// in progress**. That refusal is not caution, it is a replacement for two of
/// git's own protections that the temporary-index mechanism switches off. A
/// commit from this dialog is made against an index seeded from `HEAD` in a
/// throw-away `GIT_INDEX_FILE`, so git never sees the *real* index and therefore
/// never raises `error: you have unmerged files` nor `fatal: cannot do a partial
/// commit during a merge`. Both of those exist to stop a commit that silently
/// drops the second parent, or the conflict resolutions, or both — and with them
/// bypassed, blocking here is the only thing left standing between the user and
/// a merge "finished" as an ordinary one-parent commit that quietly discards the
/// other side.
///
/// **Consequence, deliberate: a merge commit cannot be created from the UI.**
/// Finishing a merge, a rebase, a cherry-pick or a revert stays a console job.
/// That is a real limit of this feature rather than an oversight — a correct
/// merge commit needs the recorded parents and the whole resolved index, which
/// is precisely the state the dialog's mechanism sets aside. The 3-pane merge
/// editor still resolves and stages the conflicting files; committing the result
/// is `git commit` in the terminal.
public enum InProgressOperation: Equatable {
    case merge
    case cherryPick
    case revert
    case rebase

    /// The name used inside the block's sentence ("A **rebase** is in progress…").
    public var displayName: String {
        switch self {
        case .merge: return "merge"
        case .cherryPick: return "cherry-pick"
        case .revert: return "revert"
        case .rebase: return "rebase"
        }
    }

    /// Decide from the entry names present in the repository's git directory.
    ///
    /// The caller lists the git dir and hands over the names it found; the names
    /// are matched **exactly**, as git writes them, so a user's own
    /// `merge_head` file is not mistaken for a merge in progress. A rebase is
    /// reported ahead of the rest because a rebase that stopped on a conflicting
    /// patch can leave several markers at once and git's own status calls that
    /// state a rebase.
    public static func detect(markerNames: [String]) -> InProgressOperation? {
        let names = Set(markerNames)
        if names.contains("rebase-merge") || names.contains("rebase-apply") { return .rebase }
        if names.contains("MERGE_HEAD") { return .merge }
        if names.contains("CHERRY_PICK_HEAD") { return .cherryPick }
        if names.contains("REVERT_HEAD") { return .revert }
        return nil
    }
}

/// The repository state the commit dialog needs, read once when the dialog opens.
///
/// Pure value type (the `BranchRef`/`ChangedFile` precedent): the
/// `Process`-backed reads live in `GitCLIService.commitContext(root:)`, every
/// decision made from them lives in `CommitGate` and `PushPlan`.
///
/// `currentBranch` is the short name (`master`), `nil` on a detached HEAD;
/// `upstream` is the short tracking ref (`origin/master`), `nil` when the branch
/// has none. An **unborn** HEAD — a fresh repository with no commit yet — still
/// has a branch name (git's `symbolic-ref` reports the branch the first commit
/// will create), which is why `isUnbornHEAD` is carried separately: it blocks
/// amending (there is nothing to amend) without withdrawing the push plan.
public struct CommitContext: Equatable {
    /// HEAD points at a branch that has no commit yet.
    public let isUnbornHEAD: Bool
    /// HEAD is not on a branch.
    public let isDetachedHEAD: Bool
    /// The short branch name, `nil` when detached.
    public let currentBranch: String?
    /// The short upstream ref (`origin/master`), `nil` when the branch has none.
    public let upstream: String?
    /// The configured remotes, in `git remote` order (which is sorted).
    public let remotes: [String]
    /// The operation the repository is in the middle of, if any.
    public let inProgress: InProgressOperation?
    /// The commit `HEAD` resolved to when this context was read, `nil` on an
    /// unborn (or unreadable) HEAD.
    ///
    /// Carried for one job: **identifying the commit an amend would rewrite**.
    /// Every other field describes a *shape* the dialog reacts to, and none of them
    /// changes when `HEAD` merely moves — so without the hash a `git commit` run in
    /// the embedded terminal (or any external tool) while the sheet is up left
    /// `commit()`'s pre-commit re-read entirely satisfied, and `--amend` rewrote a
    /// commit the user had never seen, under the message of the one they had.
    /// `CommitDialogModel.commit` compares it against a fresh read and refuses with
    /// `CommitStaleReason.headMoved`. It is free to obtain: `commitContext` already
    /// runs `rev-parse --verify --quiet HEAD` to decide `isUnbornHEAD`, and this is
    /// that command's own stdout.
    public let headHash: String?

    public init(
        isUnbornHEAD: Bool,
        isDetachedHEAD: Bool,
        currentBranch: String?,
        upstream: String?,
        remotes: [String],
        inProgress: InProgressOperation?,
        headHash: String? = nil
    ) {
        self.isUnbornHEAD = isUnbornHEAD
        self.isDetachedHEAD = isDetachedHEAD
        self.currentBranch = currentBranch
        self.upstream = upstream
        self.remotes = remotes
        self.inProgress = inProgress
        self.headHash = headHash
    }
}
