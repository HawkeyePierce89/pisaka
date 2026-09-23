import Foundation

/// How a file differs from `HEAD`, as surfaced in the Local Changes view.
///
/// A deliberately small, semantic enum (no git plumbing detail) mirroring the
/// pure-enum precedent of `FileStatus`'s siblings (`FileIconColor`,
/// `SyntaxTokenKind`). The view layer maps each case to an icon/color; Core
/// stays UI-free.
public enum FileStatus: Equatable, CaseIterable {
    case modified
    case added
    case deleted
    case renamed
    case untracked
    case conflicted
}

extension FileStatus {
    /// The one-letter mark a changed-file row draws beside its name. **The
    /// letter carries the identity and the colour carries the weight**: two
    /// statuses may share a colour (`ChromeColorRole.changedFileRole(for:)`),
    /// never a letter, so a row stays readable without its hue.
    public var letter: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "U"
        case .conflicted: return "C"
        }
    }

    /// The status as a word, for the row's accessibility value — what the
    /// letter means to someone who cannot see it.
    public var spokenName: String {
        switch self {
        case .modified: return "Modified"
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .untracked: return "Untracked"
        case .conflicted: return "Conflicted"
        }
    }
}

/// A single file that differs from `HEAD`.
///
/// `path` is repo-relative (the working-copy path; for a rename this is the new
/// path). `oldPath` is the pre-rename path, set only when `status == .renamed`.
/// Identity is the path, so the same file keeps a stable identity across
/// refreshes.
public struct ChangedFile: Identifiable, Equatable {
    public let path: String
    public let status: FileStatus
    public let oldPath: String?

    public init(path: String, status: FileStatus, oldPath: String? = nil) {
        self.path = path
        self.status = status
        self.oldPath = oldPath
    }

    /// Stable identity from the repo-relative path.
    public var id: String { path }
}
