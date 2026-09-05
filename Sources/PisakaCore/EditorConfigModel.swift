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
/// re-resolution and nothing else does. Both go through one `invalidate()`,
/// which also bumps `revision` — the integer a reader caching something derived
/// from an answer compares to notice that its own copy is stale.
@MainActor
public final class EditorConfigModel {

    private let fileService: FileServicing
    /// The opened folder, in the spelling the caller passed — the walk's stop and
    /// the containment test both go through it.
    public private(set) var projectRoot: URL?
    private var cache: [URL: EditorConfigProperties] = [:]

    /// How many times every cached answer has been thrown away.
    ///
    /// A monotonic counter, bumped by both wholesale invalidations and by
    /// nothing else, so a reader that caches something *derived* from an answer
    /// — the editor's indentation widths are the one such reader today — can
    /// tell in a single integer comparison that what it is holding predates the
    /// invalidation, without re-asking for the answer to compare it against.
    ///
    /// It counts invalidations, not changes: a `noteProjectFilesChanged()` for a
    /// file that has nothing to do with `.editorconfig` bumps it too, and the
    /// reader then recomputes an identical answer. That is the cheap direction
    /// of the trade — the expensive one would be missing a change — and it is
    /// the same wholesale reasoning the cache itself is built on.
    ///
    /// The model stays a plain class and stays unobserved: this is a value to be
    /// *asked* for on a path that already runs, never a publisher anything
    /// subscribes to.
    public private(set) var revision: Int = 0

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
        invalidate()
    }

    /// Something under the project changed on disk: drop every resolved answer.
    ///
    /// Called from the places that already know — the file-system watcher on
    /// macOS, the explicit "the worktree was rewritten" notifications on iOS — so
    /// that editing a `.editorconfig` takes effect on the next keystroke without
    /// reopening the project.
    public func noteProjectFilesChanged() {
        invalidate()
    }

    /// Throw every resolved answer away and record that it happened.
    ///
    /// The one place the cache is cleared, so the revision cannot be bumped
    /// without the clear or the clear performed without the bump — the two are
    /// one act, and a second invalidation point added later gets both by
    /// calling this rather than by remembering to.
    private func invalidate() {
        cache.removeAll()
        revision += 1
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
            // The identical spelling is answered without touching the disk. iOS
            // re-states the root from `updateUIView`, which SwiftUI runs on every
            // keystroke, and `CanonicalPath.canonical` is
            // `resolvingSymlinksInPath()` — a `readlink` per path component,
            // twice per call — for a question that is almost always "the same
            // string as last time". `standardizedFileURL` is purely lexical, so
            // this fast path also absorbs the trailing-slash re-spelling; only a
            // genuinely different spelling reaches the filesystem.
            if lhs.standardizedFileURL.path == rhs.standardizedFileURL.path { return true }
            return CanonicalPath.canonical(lhs).path == CanonicalPath.canonical(rhs).path
        default: return false
        }
    }
}
