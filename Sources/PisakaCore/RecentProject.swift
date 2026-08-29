import Foundation

/// One row in the recents list.
public struct RecentProject: Identifiable, Equatable {
    /// The canonical identity.
    public var id: String {
        path
    }

    /// The url built from the verbatim stored path.
    public let url: URL

    /// The folder's last path component, falling back to the whole path when there is none.
    public let name: String

    /// The stored spelling, verbatim — no tilde abbreviation, no canonicalization.
    public let path: String

    /// Whether this row is the current project.
    public let isCurrent: Bool

    public init(url: URL, name: String, path: String, isCurrent: Bool) {
        self.url = url
        self.name = name
        self.path = path
        self.isCurrent = isCurrent
    }

    /// The projection from a stored session catalog to the display list.
    ///
    /// MRU order preserved as the catalog stores it. The `nil`-folder entry is
    /// excluded before anything else (and never handed to `folderExists`). Each
    /// remaining entry is kept only when `folderExists` says its url is still there.
    /// `isCurrent` is decided by comparing `CanonicalPath.canonical(_:).path`
    /// against `currentRoot`, so any spelling of the open folder marks its row.
    ///
    /// `folderExists` has no default, so every call site states its answer. The list
    /// is read at display time and may trail the live catalog by one debounce of the
    /// session writer (acceptable; the button's own label comes from the live project
    /// root, never from the catalog's head). The remaining race (a folder deleted
    /// between display and click) is settled by the funnel's refusal on the other end.
    public static func rows(
        catalog: SessionCatalog,
        currentRoot: URL?,
        folderExists: (URL) -> Bool
    ) -> [RecentProject] {
        let rootKey = currentRoot.map { CanonicalPath.canonical($0).path }

        var rows: [RecentProject] = []
        for entry in catalog.entries {
            guard let folderPath = entry.folderPath else { continue }
            let url = URL(fileURLWithPath: folderPath)
            guard folderExists(url) else { continue }

            let name = url.lastPathComponent

            let isCurrent = CanonicalPath.canonical(url).path == rootKey

            rows.append(RecentProject(
                url: url,
                name: name,
                path: folderPath,
                isCurrent: isCurrent
            ))
        }
        return rows
    }
}
