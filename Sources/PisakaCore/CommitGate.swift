import Foundation

/// Why the Commit button is disabled, with the sentence shown next to it.
///
/// The text lives in Core for the reason `GitError.errorDescription` and
/// `EntryPathIssue.message` do: the decision and its explanation are one rule,
/// unit-tested together, while the view stays a thin display of whatever the
/// gate returned.
public enum CommitBlock: Equatable {
    /// No repository is loaded (no folder open, or the folder is not a git
    /// working tree).
    case noRepository
    /// A commit started from this dialog is still running.
    case alreadyRunning
    /// The author editor's `git config --local` write has not finished yet.
    case identityWriteInProgress
    /// The repository is in the middle of a merge/rebase/cherry-pick/revert.
    case operationInProgress(InProgressOperation)
    /// Amend is checked but there is no commit to amend.
    case amendOnUnbornHEAD
    /// At least one file is still in a conflicted state.
    case conflictedFiles([String])
    /// git has no author name and/or email.
    case identityIncomplete
    /// The message field is empty after trimming.
    case emptyMessage
    /// Nothing is checked, and this is not a message-only amend.
    case nothingSelected

    /// The sentence the dialog shows in place of "ready to commit".
    public var message: String {
        switch self {
        case .noRepository:
            return "This folder is not a git repository."
        case .alreadyRunning:
            return "A commit is already in progress."
        case .identityWriteInProgress:
            return "Saving the commit author…"
        case .operationInProgress(let operation):
            return "A \(operation.displayName) is in progress — "
                + "finish it from the terminal before committing."
        case .amendOnUnbornHEAD:
            return "There is no commit to amend yet."
        case .conflictedFiles(let paths):
            if paths.count == 1 {
                return "Resolve the conflict in “\(paths[0])” first."
            }
            return "Resolve all \(paths.count) conflicts first."
        case .identityIncomplete:
            return "Set the commit author’s name and email first."
        case .emptyMessage:
            return "Enter a commit message."
        case .nothingSelected:
            return "Select at least one file or line to commit."
        }
    }
}

/// The single decision "may this dialog commit right now, and if not, why".
///
/// Pure and Foundation-only; every input is a value the model already holds, so
/// the whole enablement rule is one testable function rather than a condition
/// spread across the sheet.
///
/// **Two of these blocks stand in for protections git itself would normally
/// provide.** The commit is built in a throw-away `GIT_INDEX_FILE` seeded from
/// `HEAD`, so git never inspects the real index and never refuses on its own
/// account: neither `you have unmerged files` (unresolved conflicts) nor
/// `cannot do a partial commit during a merge` can fire. `.conflictedFiles` and
/// `.operationInProgress` are those refusals, reimplemented here — which is also
/// why the conflict block does not care whether the conflicted file is *checked*:
/// git refuses on the presence of unmerged entries, not on what the commit
/// touches. And because `.operationInProgress` fires whatever the Amend
/// checkbox says, there is one rule rather than two, so "amend during a merge"
/// cannot slip past a rule written only for the ordinary path.
///
/// The consequence — a merge cannot be finished from the UI — is stated on
/// `InProgressOperation` and is deliberate.
public enum CommitGate {
    /// The first reason the commit is blocked, or `nil` when it may proceed.
    ///
    /// `selectedFileCount` counts the files the commit would *touch*: a file
    /// checked whole (including a binary or deleted one, which has no line units
    /// at all) counts as one, as does a file with at least one line unit
    /// checked; a file with nothing checked counts zero. So it is exactly the
    /// number of files `CommitPlan` would include (a rename contributes two
    /// *entries* — a removal and an add — but one file), and "nothing selected"
    /// is the same question as "the plan is empty".
    ///
    /// The order of the checks is *mostly* "what the user cannot fix without
    /// leaving the dialog before what they can" — a missing repository, a running
    /// commit, an operation in progress and an unresolved conflict ahead of the
    /// identity, the message and the selection. The one deliberate exception is
    /// `.amendOnUnbornHEAD`, which sits among the first group although unchecking
    /// Amend fixes it in place: it says the *combination* is impossible, so
    /// reporting it before the state-of-the-repository blocks keeps "you asked to
    /// amend a commit that does not exist" from being hidden behind a conflict the
    /// user would then resolve for nothing.
    ///
    /// `isWritingIdentity` sits beside `isRunning` because it is the same kind of
    /// fact — an operation this dialog started is still in flight — and it has to
    /// block for a reason of its own. The author editor dismisses on Save while the
    /// write runs as two sequential `git config --local` commands on the *same
    /// serial queue* as the commit's own steps, so an ungated Commit pressed in that
    /// window records the previous identity, or (between the two writes) the new
    /// name beside the old email. That is precisely the silent misattribution the
    /// author line exists to make impossible, so the gate closes it rather than
    /// leaving it to how fast the user can click.
    public static func evaluate(
        context: CommitContext?,
        identity: CommitIdentity,
        message: String,
        selectedFileCount: Int,
        amend: Bool,
        conflictedPaths: [String],
        isRunning: Bool,
        isWritingIdentity: Bool
    ) -> CommitBlock? {
        guard let context else { return .noRepository }
        if isRunning { return .alreadyRunning }
        if isWritingIdentity { return .identityWriteInProgress }
        if let operation = context.inProgress { return .operationInProgress(operation) }
        if amend, context.isUnbornHEAD { return .amendOnUnbornHEAD }
        if !conflictedPaths.isEmpty { return .conflictedFiles(conflictedPaths) }
        if !identity.isComplete { return .identityIncomplete }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyMessage }
        if !amend, selectedFileCount == 0 { return .nothingSelected }
        return nil
    }

    /// Re-check *only* the two blocks that stand in for git's own refusals, from
    /// freshly read repository state, immediately before the commit runs.
    ///
    /// `evaluate` answers "is the Commit button enabled", so it necessarily runs
    /// against what the dialog loaded. But the dialog's modality stops the app's
    /// own writers and nothing else: a `git merge`, `rebase` or `cherry-pick`
    /// started in a terminal while the sheet is up leaves the button enabled, and
    /// because the commit is built in a throw-away index git will not refuse
    /// either — so the merge would be recorded as an ordinary one-parent commit,
    /// dropping the second parent and the conflict resolutions. That is exactly
    /// what these two blocks exist to prevent, so they are the two the pre-commit
    /// re-read repeats.
    ///
    /// The other blocks deliberately are **not** repeated: the identity, the
    /// message and the selection are the dialog's own state, unchanged since it
    /// was evaluated, and re-deriving them here would only duplicate the rule.
    public static func evaluateRepositoryState(
        context: CommitContext?,
        conflictedPaths: [String]
    ) -> CommitBlock? {
        guard let context else { return .noRepository }
        if let operation = context.inProgress { return .operationInProgress(operation) }
        if !conflictedPaths.isEmpty { return .conflictedFiles(conflictedPaths) }
        return nil
    }
}
