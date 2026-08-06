import Foundation

/// A persisted folder bookmark: the folder's on-disk `path` (its identity for
/// deduplication and display) paired with the opaque security-scoped `bookmark`
/// blob the platform produced for it.
///
/// The `bookmark` `Data` is created and resolved entirely in the iOS view layer
/// (`url.bookmarkData()` / `URL(resolvingBookmarkData:…)` — platform API kept out
/// of Core); Core only stores, orders, and hands it back. `Codable` so the store
/// can persist a list of them through `UserDefaults` as one property-list blob.
public struct FolderBookmark: Codable, Equatable {
    /// The folder's standardized absolute path — the dedup/identity key.
    public let path: String
    /// The opaque security-scoped bookmark blob (created by the view layer).
    public let bookmark: Data

    public init(path: String, bookmark: Data) {
        self.path = path
        self.bookmark = bookmark
    }
}

/// Pure, Foundation-only helpers backing iOS security-scoped file access (the
/// recents list ordering and the scope-coverage path check). Kept in Core — and
/// unit-tested — because both are off-by-one/edge-prone (dedup + cap ordering,
/// trailing-slash/ancestor path matching) while the actual bookmark creation,
/// `startAccessingSecurityScopedResource`, and `UIDocumentPicker` wiring stay in
/// the iOS view layer. The `FileIcon`/`LineDiff` "move the testable math into
/// Core" precedent.
public enum ScopedFileAccess {
    /// How many recently-opened folders to retain (oldest beyond this are dropped).
    public static let maxRecentFolders = 20

    /// Insert `folder` at the front of `existing`, deduplicated by `path` (a
    /// re-opened folder moves to the front rather than appearing twice), and cap
    /// the result at `max` most-recent entries.
    ///
    /// Most-recent-first ordering: the front is the last-opened folder, which the
    /// restore-on-launch path reopens. An existing entry with the same `path` is
    /// removed before the new one is inserted, so its bookmark blob is refreshed
    /// to the latest the view layer produced.
    public static func updatedRecents(
        _ existing: [FolderBookmark],
        remembering folder: FolderBookmark,
        max: Int = maxRecentFolders
    ) -> [FolderBookmark] {
        var result = existing.filter { $0.path != folder.path }
        result.insert(folder, at: 0)
        if max >= 0 && result.count > max {
            result = Array(result.prefix(max))
        }
        return result
    }

    /// Whether `target` is the same path as, or a descendant of, `root`.
    ///
    /// Used by the iOS security-scoped `FileServicing` decorator to find the
    /// registered scoped root (an opened folder, or a standalone opened file)
    /// whose access grant covers an operation's target url, so the operation can
    /// be bracketed by that root's `startAccessingSecurityScopedResource`; and by
    /// `TreeRefreshFilter` (the macOS project-tree watcher) to decide whether a
    /// changed path is inside the opened root or inside that root's `.git` — where
    /// the normalization below is what keeps `.gitignore`/`.github` from matching
    /// `.git`. Both
    /// sides are compared as absolute path strings with trailing slashes
    /// normalized away, so `/a/b/` and `/a/b` compare equal and `/a/b` is not
    /// considered to contain `/a/bc`.
    public static func path(_ target: String, isWithin root: String) -> Bool {
        let t = normalizedPath(target)
        let r = normalizedPath(root)
        // An empty root scopes nothing (a malformed/unresolved bookmark must not
        // silently widen access to every absolute path via the `hasPrefix("/")`
        // fallthrough below).
        if r.isEmpty { return false }
        if t == r { return true }
        // The filesystem root contains every absolute path.
        if r == "/" { return t.hasPrefix("/") }
        return t.hasPrefix(r + "/")
    }

    /// Strip trailing slashes (keeping a lone `/` for the filesystem root) so two
    /// spellings of the same directory path compare equal.
    private static func normalizedPath(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }
}

/// Persists the list of recently-opened folder bookmarks through an injected
/// `UserDefaults`, mirroring `SettingsStore`'s shape (Foundation-only,
/// `UserDefaults` injected so tests run against an isolated suite). The pure
/// ordering/cap logic lives in `ScopedFileAccess.updatedRecents`; this is the
/// thin persistence wrapper on top.
///
/// The iOS view layer creates/resolves the security-scoped bookmark blobs and
/// calls `rememberFolder` after a successful open; the restore-on-launch path
/// reads `folders().first` and resolves its blob back to a url.
public final class BookmarkStore: ObservableObject {
    /// Stable persisted key — must not be renamed.
    public enum Keys {
        public static let recentFolders = "bookmarks.recentFolders"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The persisted recent folders, most-recent-first. Empty when none are
    /// stored or the stored blob cannot be decoded.
    public func folders() -> [FolderBookmark] {
        guard
            let data = defaults.data(forKey: Keys.recentFolders),
            let decoded = try? PropertyListDecoder().decode([FolderBookmark].self, from: data)
        else { return [] }
        return decoded
    }

    /// The stored bookmark blob for `path`, or `nil` when that folder is not in
    /// the recents list.
    public func bookmark(forPath path: String) -> Data? {
        folders().first { $0.path == path }?.bookmark
    }

    /// Record (or refresh) a folder bookmark at the front of the recents list and
    /// persist. Returns the new list.
    @discardableResult
    public func rememberFolder(bookmark: Data, path: String) -> [FolderBookmark] {
        let updated = ScopedFileAccess.updatedRecents(
            folders(),
            remembering: FolderBookmark(path: path, bookmark: bookmark)
        )
        save(updated)
        return updated
    }

    /// Drop the folder at `path` from the recents list (e.g. after a stale/dangling
    /// bookmark fails to resolve) and persist. Returns the new list.
    @discardableResult
    public func forgetFolder(path: String) -> [FolderBookmark] {
        let updated = folders().filter { $0.path != path }
        save(updated)
        return updated
    }

    private func save(_ folders: [FolderBookmark]) {
        guard let data = try? PropertyListEncoder().encode(folders) else { return }
        defaults.set(data, forKey: Keys.recentFolders)
    }
}
