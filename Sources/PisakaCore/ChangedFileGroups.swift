import Foundation

/// One folder row of the macOS Local Changes list and the files beneath it.
public struct ChangedFileGroup: Identifiable, Equatable {
    /// The repository-relative parent directory every file in the group shares,
    /// or `""` for files at the repository root. Unique across one grouping, so
    /// it is the row's identity.
    public let path: String
    /// What the folder row shows: `path`, or the project folder's name for the
    /// root-level group.
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
/// any tie (two names differing only in case). The root group's path is `""`,
/// which sorts before every other, so it always comes first.
public enum ChangedFileGroups {
    public static func group(_ files: [ChangedFile], rootName: String) -> [ChangedFileGroup] {
        let byDirectory = Dictionary(grouping: files) { directory(of: $0.path) }
        return byDirectory.keys
            .sorted(by: ordered)
            .map { path in
                let members = (byDirectory[path] ?? []).sorted { lhs, rhs in
                    let left = name(of: lhs.path)
                    let right = name(of: rhs.path)
                    if left == right { return lhs.path < rhs.path }
                    return ordered(left, right)
                }
                return ChangedFileGroup(path: path, label: path.isEmpty ? rootName : path, files: members)
            }
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
