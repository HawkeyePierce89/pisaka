import Foundation

/// Pure, testable window-title builder for the separate (non-modal) diff windows
/// opened on double-click — both the Local Changes diff and a commit's file diff.
///
/// The title pairs the file path with its context so several open diff windows
/// stay distinguishable: a Local Changes diff carries the repo-relative path plus
/// "Local Changes"; a commit diff carries the path plus the commit's short hash
/// and subject. Foundation-only and color/UI-free (the `FileIcon`/`LogFilter`
/// move-logic-into-Core precedent), so the off-by-one-prone short-hash truncation
/// is unit-tested rather than living in the view layer.
public enum DiffWindowTitle {
    /// Number of leading hash characters shown (git's conventional short hash).
    public static let shortHashLength = 7

    /// Title for a Local Changes diff window: the file path plus "Local Changes".
    public static func localChanges(path: String) -> String {
        "\(path) — Local Changes"
    }

    /// Title for a commit's file diff window: the file path plus the commit's
    /// short hash and subject. The hash is truncated to `shortHashLength`
    /// characters (a full-length or already-short hash both produce a sensible
    /// prefix).
    public static func commit(path: String, hash: String, subject: String) -> String {
        let shortHash = String(hash.prefix(shortHashLength))
        return "\(path) — \(shortHash) \(subject)"
    }
}
