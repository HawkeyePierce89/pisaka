import Foundation

/// The one traversal of an opened folder, shared by Find in Files and the symbol
/// index.
///
/// Both features ask the same question — *"which files under this root are worth
/// reading?"* — and both must answer it identically: a file Find in Files
/// refuses to search because a `.gitignore` excludes it must not turn up as a
/// go-to-definition target either. This type exists so that rule is written
/// once. It was lifted verbatim out of `ProjectSearchModel` (whose
/// `collectFiles`/`relativePath` these were), so the gitignore stack, the
/// `.git`/`.DS_Store` filter, the symlink rules and the deterministic ordering
/// are unchanged; the alternative — the index reaching into another model's
/// `nonisolated static` — is what this avoids.
///
/// Pure, Foundation-only and free of any actor isolation: every entry point is a
/// plain `static func` over an injected `FileServicing`, called from the private
/// serial queues both models dispatch their I/O to.
///
/// **What is skipped, and by whom.** `.git` and `.DS_Store` are skipped here
/// (`FileService.isExcludedEntryName`) — `GitignoreMatcher` deliberately says
/// nothing about them. Every other exclusion is a `.gitignore` decision,
/// composed down the tree by `GitignoreStack`. Binary and oversize files are
/// *not* this type's business: they are skipped by the callers'
/// `FileServicing.readTextIfNotBinary`, which is where the byte cap lives.
public enum ProjectFileWalk {

    /// The file name whose contents feed `GitignoreStack`.
    public static let gitignoreName = ".gitignore"

    /// Every file under `root` worth reading, depth-first with a directory's
    /// own files before its subdirectories — so results stream in as "this
    /// folder, then what is under it" rather than surfacing a deeply nested hit
    /// before the root's own (`contentsOfDirectory` sorts directories *first*,
    /// which is right for a tree view and backwards for a result list). Within
    /// each of the two groups the listing's alphabetical order is kept, so the
    /// result order is deterministic.
    ///
    /// A directory's own `.gitignore` is read *before* its entries are judged, so
    /// the file governs its own directory as git's does; the resulting
    /// `GitignoreStack` is passed down, so a nested file layers over the outer
    /// ones. An unreadable directory is skipped rather than failing the walk —
    /// one permission-denied folder must not blank the whole result list.
    ///
    /// `maskPatterns` is the Find-in-Files file mask; an empty array (what the
    /// symbol index passes) means every file.
    public static func collectFiles(
        root: URL,
        maskPatterns: [String],
        fileService: FileServicing
    ) -> [URL] {
        collectFilesIfReadable(root: root, maskPatterns: maskPatterns, fileService: fileService) ?? []
    }

    /// `collectFiles`, but answering `nil` when the **root itself** could not be
    /// listed rather than folding that into an empty result.
    ///
    /// The two are genuinely different questions, and only the root's answer is
    /// ambiguous: a nested directory that cannot be read is skipped on purpose
    /// (one permission-denied folder must not blank the whole result list), and
    /// the files it would have contributed are the only ones lost. A *root* that
    /// cannot be read loses everything, so `[]` there means either "this project
    /// has no files" or "ask again later" — and a caller that treats the two
    /// alike acts on the wrong one. `SymbolIndexModel.refresh` is why this exists:
    /// it removes every indexed file the walk stopped producing, so an empty walk
    /// it cannot distinguish empties the index outright, silently and for the rest
    /// of the session (an unindexed project looks exactly like one that declares
    /// nothing). Find in Files, whose empty result is visible and re-run by the
    /// next keystroke, keeps using `collectFiles`.
    public static func collectFilesIfReadable(
        root: URL,
        maskPatterns: [String],
        fileService: FileServicing
    ) -> [URL]? {
        var found: [URL] = []

        /// `false` when `directory` itself could not be listed; the recursive
        /// calls discard it, since only the root's answer is the caller's
        /// business.
        @discardableResult
        func walk(directory: URL, components: [String], ignores: GitignoreStack) -> Bool {
            guard let entries = try? fileService.contentsOfDirectory(at: directory) else { return false }

            var ignores = ignores
            if entries.contains(where: { !$0.isDirectory && $0.name == gitignoreName }),
               let contents = try? fileService.read(url: directory.appendingPathComponent(gitignoreName)) {
                ignores = ignores.appending(
                    rules: GitignoreRules(fileContents: contents),
                    relativeDirectory: components.joined(separator: "/")
                )
            }

            // `.git`/`.DS_Store` are the traversal's business, not the matcher's
            // (see `GitignoreRules`' scope note). The real `FileService` already
            // filters them from its listing; checking here too means a
            // differently-behaving service cannot leak the repository's
            // internals into the results.
            let visible = entries.filter { entry in
                guard !FileService.isExcludedEntryName(entry.name) else { return false }
                let relative = (components + [entry.name]).joined(separator: "/")
                return !ignores.isExcluded(relativePath: relative, isDirectory: entry.isDirectory)
            }

            for entry in visible where !entry.isDirectory {
                guard matchesMask(name: entry.name, patterns: maskPatterns) else { continue }
                // A symlinked *file* is skipped for the same reason a symlinked
                // directory is not descended into: a link pointing back inside
                // the tree duplicates a file already reached under its real
                // name, and one pointing outside is not part of this project.
                // `isDirectory` comes from `.isDirectoryKey`, which dereferences
                // the link, so a link to a file arrives here indistinguishable
                // from an ordinary one — and Replace All writes atomically
                // (`String.write(to:atomically:)` renames a temp file over the
                // destination), which would silently replace the link itself
                // with a regular file.
                guard fileService.symbolicLinkDestination(at: entry.url) == nil else { continue }
                found.append(entry.url)
            }
            for entry in visible where entry.isDirectory {
                // A symlinked directory is not descended into: it can point back
                // up the tree (an unbounded walk), and its target is already
                // reached under its real name.
                guard fileService.symbolicLinkDestination(at: entry.url) == nil else { continue }
                walk(directory: entry.url, components: components + [entry.name], ignores: ignores)
            }
            return true
        }

        guard walk(directory: root, components: [], ignores: GitignoreStack()) else { return nil }
        return found
    }

    /// Whether a file *name* passes the mask. No pattern is "everything"; a
    /// pattern is `Glob`'s single-component rule (the same one a `.gitignore`
    /// component uses), matched case-sensitively and against the name alone — a
    /// mask is a file-type filter, not a path selector.
    public static func matchesMask(name: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return true }
        return patterns.contains { Glob.matches(name: name, pattern: $0) }
    }

    /// `url`'s path below `root`. The URLs come from the traversal, which builds
    /// them by appending components to `root`, so a lexical strip is exact and
    /// needs no `CanonicalPath` round trip; an unexpected URL degrades to its own
    /// last component rather than to an absolute path.
    ///
    /// A `nil` root — no folder open, which only the definition picker can be
    /// asked about — degrades the same way, to the bare file name.
    public static func relativePath(of url: URL, under root: URL?) -> String {
        guard let root else { return url.lastPathComponent }
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(base) else { return url.lastPathComponent }
        return String(url.path.dropFirst(base.count))
    }
}
