import Foundation

/// One folder row of the macOS Local Changes list and the files beneath it.
public struct ChangedFileGroup: Identifiable, Equatable {
    /// The repository-relative parent directory every file in the group shares,
    /// or `""` for files at the repository root. Unique across one grouping, so
    /// it is the row's identity.
    public let path: String
    /// What the folder row shows: the directory relative to the opened project
    /// folder, or the project folder's name for the project-root group; for a
    /// directory outside the project folder, the repository's name joined with
    /// `path` (the name alone for repository-root files).
    public let label: String
    /// The group's files, sorted by name.
    public let files: [ChangedFile]

    public var id: String { path }

    public init(path: String, label: String, files: [ChangedFile]) {
        self.path = path
        self.label = label
        self.files = files
    }
}

/// The macOS Local Changes list's one level of grouping: one folder row per
/// distinct parent directory.
///
/// Deliberately flatter than `ChangeTree`, which nests one node per path
/// component (and stays as iOS's by-folder grouping): the design draws each
/// changed file's directory as a single row showing its whole path, so a file
/// three folders deep sits one indent under one row, not three. A rename is
/// grouped by its *new* path — the file the worktree holds.
///
/// Ordering is total and deterministic, so the list never reshuffles between two
/// refreshes of the same status: groups by path, files by name, each compared
/// case-insensitively with digits read as numbers, and the exact path breaking
/// any tie (two names differing only in case). The project-root group sorts
/// before every other, so it always comes first.
///
/// Labels are relative to the **opened project folder**, which may sit below
/// the repository root: `projectPrefix` is that folder's repository-relative
/// path (`""` when the two are the same, which is the plain repository case).
/// A file under the prefix is grouped by its project-relative directory; a file
/// outside the project folder — the status is the whole repository's — keeps
/// its repository-relative directory, labelled with the repository's name in
/// front so it never reads as a project folder, and every such group sorts
/// after every project group. `ChangedFile.path` and each group's `path` stay
/// repository-relative: only what is *shown* changes, never what git is given.
public enum ChangedFileGroups {
    /// - Parameters:
    ///   - rootName: the project folder's name, the project-root group's label.
    ///   - projectPrefix: the project folder's repository-relative path.
    ///   - repositoryName: the repository's name, prefixed to the label of a
    ///     group outside the project folder; defaults to `rootName`, which is
    ///     the repository's name whenever `projectPrefix` is empty.
    public static func group(
        _ files: [ChangedFile],
        rootName: String,
        projectPrefix: String = "",
        repositoryName: String? = nil
    ) -> [ChangedFileGroup] {
        let byDirectory = Dictionary(grouping: files) { directory(of: $0.path) }
        let repository = repositoryName ?? rootName
        let keyed = byDirectory.keys.map { path -> (path: String, inside: String?) in
            (path, projectRelative(directory: path, projectPrefix: projectPrefix))
        }
        return keyed
            .sorted { lhs, rhs in
                switch (lhs.inside, rhs.inside) {
                case let (left?, right?): return ordered(left, right)
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): return ordered(lhs.path, rhs.path)
                }
            }
            .map { key in
                let members = (byDirectory[key.path] ?? []).sorted { lhs, rhs in
                    let left = name(of: lhs.path)
                    let right = name(of: rhs.path)
                    if left == right { return lhs.path < rhs.path }
                    return ordered(left, right)
                }
                let label: String
                if let inside = key.inside {
                    label = inside.isEmpty ? rootName : inside
                } else {
                    label = key.path.isEmpty ? repository : repository + "/" + key.path
                }
                return ChangedFileGroup(path: key.path, label: label, files: members)
            }
    }

    /// The detail header's text for a repository-relative `path`: relative to
    /// the project folder when the file lies under it, repository-relative
    /// otherwise.
    public static func displayPath(_ path: String, projectPrefix: String) -> String {
        guard !projectPrefix.isEmpty else { return path }
        let lead = projectPrefix + "/"
        guard path.hasPrefix(lead) else { return path }
        return String(path.dropFirst(lead.count))
    }

    /// A repository-relative directory relative to the project folder: `""`
    /// for the project folder itself, `nil` when the directory is outside it.
    /// Compared by whole components, so `app2` is not under `app`.
    static func projectRelative(directory: String, projectPrefix: String) -> String? {
        guard !projectPrefix.isEmpty else { return directory }
        if directory == projectPrefix { return "" }
        let lead = projectPrefix + "/"
        guard directory.hasPrefix(lead) else { return nil }
        return String(directory.dropFirst(lead.count))
    }

    /// The parent directory of a repository-relative path, `""` at the root.
    public static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// The last component of a repository-relative path.
    public static func name(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// Case-insensitive, numeric-aware ordering with an exact tie-break.
    private static func ordered(_ lhs: String, _ rhs: String) -> Bool {
        switch lhs.compare(rhs, options: [.caseInsensitive, .numeric]) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs < rhs
        }
    }
}
