import Foundation

/// Pure, testable window-title builder for the separate (non-modal) diff windows
/// opened on double-click — the Local Changes diff and a commit's file diff — and
/// for the external-change Compare window, which reuses the same window.
///
/// The title pairs the file path with its context so several open diff windows
/// stay distinguishable: a Local Changes diff carries the path the panel's
/// detail header shows — relative to the project folder when the file lies under
/// it, repository-relative otherwise (`ChangedFileGroups.displayPath`) — plus
/// "Local Changes"; a commit diff carries the path plus the commit's short hash
/// and subject. Foundation-only and color/UI-free (the `FileIcon`/`LogFilter`
/// move-logic-into-Core precedent), so the off-by-one-prone short-hash truncation
/// is unit-tested rather than living in the view layer.
public enum DiffWindowTitle {
    /// Number of leading hash characters shown (git's conventional short hash).
    public static let shortHashLength = 7

    /// Title for a Local Changes diff window: the repository-relative `path`,
    /// shown relative to the project folder `projectPrefix` names (`""` when the
    /// folder is the repository root) exactly as the panel's detail header shows
    /// it, plus "Local Changes". A file outside the project keeps its
    /// repository-relative path.
    public static func localChanges(path: String, projectPrefix: String = "") -> String {
        "\(ChangedFileGroups.displayPath(path, projectPrefix: projectPrefix)) — Local Changes"
    }

    /// Title for a commit's file diff window: the file path plus the commit's
    /// short hash and subject. The hash is truncated to `shortHashLength`
    /// characters (a full-length or already-short hash both produce a sensible
    /// prefix).
    public static func commit(path: String, hash: String, subject: String) -> String {
        let shortHash = String(hash.prefix(shortHashLength))
        return "\(path) — \(shortHash) \(subject)"
    }

    /// Title for the external-change Compare window: the open buffer (left)
    /// against the file as it now is on disk (right). `path` is whatever the
    /// caller shows for the tab — project-relative when the file lies under the
    /// project — and the suffix names both sides so the window cannot be mistaken
    /// for a Local Changes diff, whose right side is the worktree against `HEAD`.
    public static func externalChange(path: String) -> String {
        "\(path) — Editor vs. Disk"
    }
}
