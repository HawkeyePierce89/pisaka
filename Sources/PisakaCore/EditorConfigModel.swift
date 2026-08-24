import Foundation

/// The editor's one entry point to `.editorconfig`: a per-file cache of resolved
/// properties over `EditorConfigResolver`, plus the two invalidation points the
/// app already has a place to call.
///
/// **Synchronous on purpose.** The two consumers — Enter's auto-indent and the
/// Tab key — run inside the text view's own key handling, which cannot await, so
/// `properties(for:)` answers immediately and resolves on a cache miss. A
/// resolution is a handful of small reads of files that are almost always in the
/// page cache, and the miss happens once per file per invalidation; making it
/// async would buy nothing and would force the key handlers to guess an answer
/// and correct it later.
///
/// **A reader**, like the symbol index. It opens files and writes none, so it
/// neither raises the disk-writer gate (`autosave.suspend()` +
/// `localChanges.beginRevert()`) nor is gated by it. A resolution landing in the
/// middle of a revert or a branch switch is harmless: the worst case is one
/// stale answer, which the `noteProjectFilesChanged()` that follows every such
/// rewrite corrects. Nothing here may grow a writer bracket.
///
/// **Invalidation is wholesale**, both times. `noteProjectRoot(_:)` clears the
/// cache before it can serve anything for the new project, so a config resolved
/// under a previously open folder is never returned for a file in this one.
/// `noteProjectFilesChanged()` clears it too, rather than filtering by path:
/// deciding which cached files a given `.editorconfig` edit could have affected
/// means re-walking each of their hierarchies, which is the very work the filter
/// would be saving. Wholesale, the next keystroke in the front tab pays for one
/// re-resolution and nothing else does.
@MainActor
public final class EditorConfigModel {

    private let fileService: FileServicing
    /// The opened folder, in the spelling the caller passed — the walk's stop and
    /// the containment test both go through it.
    public private(set) var projectRoot: URL?
    private var cache: [URL: EditorConfigProperties] = [:]

    public init(fileService: FileServicing, projectRoot: URL? = nil) {
        self.fileService = fileService
        self.projectRoot = projectRoot
    }

    /// The merged properties that apply to `fileURL`, resolved on a miss.
    ///
    /// Empty for a `nil` url, a `nil` root and a file outside the root — the
    /// three "there is no project answer here" cases the resolver already folds
    /// together. An empty answer is cached like any other: a project with no
    /// `.editorconfig` at all is the common case, and it may not re-walk the
    /// hierarchy on every Enter.
    public func properties(for fileURL: URL?) -> EditorConfigProperties {
        guard let fileURL else { return EditorConfigProperties() }
        if let cached = cache[fileURL] { return cached }
        let resolved = EditorConfigResolver.resolve(
            fileURL: fileURL,
            projectRoot: projectRoot,
            fileService: fileService
        )
        cache[fileURL] = resolved
        return resolved
    }

    /// Point the model at a (possibly `nil`) project root.
    ///
    /// A *different* root — including switching to or from `nil` — clears the
    /// whole cache before anything can be served, which is the
    /// never-serve-a-previous-project guarantee. The same root again is a no-op,
    /// so the idle re-assignments a SwiftUI `onChange` can produce do not throw
    /// the cache away.
    public func noteProjectRoot(_ root: URL?) {
        guard !isSameRoot(root, projectRoot) else { return }
        projectRoot = root
        cache.removeAll()
    }

    /// Something under the project changed on disk: drop every resolved answer.
    ///
    /// Called from the places that already know — the file-system watcher on
    /// macOS, the explicit "the worktree was rewritten" notifications on iOS — so
    /// that editing a `.editorconfig` takes effect on the next keystroke without
    /// reopening the project.
    public func noteProjectFilesChanged() {
        cache.removeAll()
    }

    /// Whether two roots name the same folder, asked canonically so a
    /// re-spelling (a trailing slash, `/tmp` vs. `/private/tmp`) is not mistaken
    /// for a folder switch.
    private func isSameRoot(_ lhs: URL?, _ rhs: URL?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        // Compared by `path` rather than by url equality: two urls naming the
        // same folder still differ as values when one carries a directory hint
        // the other does not, and a folder is not re-opened by a trailing slash.
        case let (lhs?, rhs?):
            return CanonicalPath.canonical(lhs).path == CanonicalPath.canonical(rhs).path
        default: return false
        }
    }
}
