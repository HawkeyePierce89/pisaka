import Foundation

/// A `GitServicing` failure the model can surface to the user.
///
/// Kept deliberately small: the view layer only needs to distinguish "this
/// folder is not a git repo (or `git` is unavailable)" from a generic failure
/// to decide what to show in the Changes panel.
///
/// Lives in `PisakaCore` (not the `Process`-backed `GitCLIService`) so its
/// human-readable `errorDescription` is unit-testable — `LocalChangesModel`
/// surfaces `error.localizedDescription` directly into `errorMessage`.
public enum GitError: Error, Equatable {
    /// `git` could not be launched (not installed / not on `PATH`).
    case gitUnavailable
    /// `git` ran but reported the directory is not inside a repository, or
    /// some other non-zero exit we cannot interpret.
    case notARepository(stderr: String)
    /// A revert could not be applied safely (e.g. the path recorded as an
    /// untracked file is now a directory, so deleting it would recurse).
    case revertFailed(reason: String)
    /// A checkout (switch or create+switch) was refused — typically a dirty
    /// working tree git will not overwrite. `reason` carries the exact git
    /// message, which names the conflicting files.
    case checkoutFailed(reason: String)
    /// A `fetch` failed (non-zero git exit or a network/transport error).
    case fetchFailed(reason: String)
    /// A commit could not be created. `reason` carries git's own stderr verbatim,
    /// because for the commonest failure — a `pre-commit`/`commit-msg` hook
    /// refusing — the hook's output *is* the explanation, and paraphrasing it
    /// would throw away the only thing that says what to fix.
    case commitFailed(reason: String)
    /// A push after a successful commit failed. Deliberately a separate case from
    /// `commitFailed`: "the commit was created, the push was not" is a distinct
    /// state the dialog has to report as such — the work is not lost and must not
    /// be retried as a commit.
    case pushFailed(reason: String)
    /// A `pull --ff-only` failed. Deliberately a separate case from `fetchFailed`:
    /// the commonest refusal here is not a network failure at all but git declining
    /// to fast-forward (the local branch has diverged from its upstream), and the
    /// post-merge tail reports that as its own step rather than as a failed merge.
    /// `reason` carries git's own words, which name the divergence.
    case pullFailed(reason: String)
    /// A network operation needs a Personal Access Token for `host` that is not
    /// stored (Part B, iOS HTTPS fetch of a private repo). The view layer directs
    /// the user to add one in Settings.
    case credentialsRequired(host: String)
}

extension GitError: LocalizedError {
    /// A human-readable message for the Changes panel. Without this, the model's
    /// `error.localizedDescription` would fall back to a generic "operation
    /// couldn't be completed (PisakaCore.GitError error N)" string, discarding the
    /// explicit `revertFailed` refusal reasons and the `git` stderr that explain
    /// *why* a refresh or revert failed.
    public var errorDescription: String? {
        switch self {
        case .gitUnavailable:
            return "Could not run “git”. Make sure it is installed and on your PATH."
        case .notARepository(let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "This folder is not a git repository." : trimmed
        case .revertFailed(let reason):
            return reason
        case .checkoutFailed(let reason):
            return reason
        case .fetchFailed(let reason):
            return reason
        case .commitFailed(let reason):
            return reason
        case .pushFailed(let reason):
            return reason
        case .pullFailed(let reason):
            return reason
        case .credentialsRequired(let host):
            return "Add a Personal Access Token for \(host) in Settings."
        }
    }
}
