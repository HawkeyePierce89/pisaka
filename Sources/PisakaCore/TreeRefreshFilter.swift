import Foundation

/// Decides whether a batch of changed paths reported by the filesystem watcher is
/// worth re-reading the project tree for.
///
/// The watcher itself (`ProjectWatcher`, macOS-only, FSEvents) lives in the view
/// layer and does nothing but deliver paths; this pure, Foundation-only decision
/// lives in Core so its off-by-one-prone path matching (trailing slashes,
/// same-or-descendant vs. raw string prefix) is unit-tested — the
/// `ScopedFileAccess`/`FileIcon`/`LineDiff` "testable math in Core, IO in the view
/// layer" precedent. It performs **string comparison only, no disk access**: an
/// FSEvents callback has no business touching the filesystem.
///
/// A batch refreshes the tree when at least one of its paths is not ignored (an
/// empty batch refreshes nothing). The three ignore rules, and how reachable each
/// one actually is under the flags `ProjectWatcher` creates its stream with:
///
/// - **Same-or-descendant of the opened root's `.git` — live.** Without
///   `kFSEventStreamCreateFlagFileEvents` FSEvents reports the *directory* in which
///   something changed, and a `git` run writes into `root/.git`,
///   `root/.git/objects/xx`, `root/.git/refs/heads` — all covered — so a
///   `git commit` / `git status` in the embedded terminal is dropped and the tree
///   does not flicker. Only the *opened root's top-level* `.git` is ignored: a
///   nested `deps/foo/.git` is an ordinary part of the visible tree.
/// - **Not same-or-descendant of `root` — live.** FSEvents can deliver such paths
///   around a stream move/recreate; they are not this project, so they are dropped.
/// - **A last component of `.DS_Store` — dormant** under the watcher's current
///   dir-level flags: the `.DS_Store` file's own path is never delivered (the
///   containing directory is reported instead), so a Finder write still passes this
///   filter and causes one harmless bump — the listing excludes `.DS_Store`, so the
///   children array is unchanged and nothing visibly moves. The rule is kept purely
///   as defense-in-depth should the stream ever switch to
///   `kFSEventStreamCreateFlagFileEvents`; it is not live behavior today.
///
/// `root` must be **canonical** (symlink-resolved). The filter cannot resolve it —
/// it is deliberately disk-free — and FSEvents reports realpath-spelled paths, so a
/// non-canonical root would fail the "same-or-descendant of `root`" rule for every
/// path and drop every batch. `ProjectWatcher.start` canonicalizes before the root
/// gets here.
///
/// The filter deliberately says nothing about *who* produced an event.
/// Self-generated writes (the app's own create/rename/delete, autosave, Save As)
/// are excluded at the stream level via `kFSEventStreamCreateFlagIgnoreSelf` — see
/// `ProjectWatcher` — so this stays a pure path decision.
public enum TreeRefreshFilter {
    /// Whether `changedPaths` contains at least one change worth re-reading the
    /// tree for, given the opened project `root` (which must be canonical — see the
    /// type doc comment). `false` for an empty batch or one made entirely of ignored
    /// paths (see the type doc comment for the rules).
    public static func shouldRefresh(changedPaths: [String], root: URL) -> Bool {
        let rootPath = root.path
        let gitPath = root.appendingPathComponent(".git").path
        return changedPaths.contains { path in
            // Outside the opened project — not ours.
            guard ScopedFileAccess.path(path, isWithin: rootPath) else { return false }
            // The opened root's own git service directory (and everything under it).
            if ScopedFileAccess.path(path, isWithin: gitPath) { return false }
            // Finder's service file (dormant under dir-level events). FSEvents
            // reports directories with a trailing slash, which `lastPathComponent`
            // normalizes away, so `a/.DS_Store/` and `a/.DS_Store` agree.
            if (path as NSString).lastPathComponent == ".DS_Store" { return false }
            return true
        }
    }
}
