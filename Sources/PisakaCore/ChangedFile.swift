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
///
/// `headObject` is the object name of the file in `HEAD` as status reported it
/// (porcelain v2's `hH`), or `nil` when the producer did not supply one. It is
/// the one cheap signal that the `HEAD` side changed while status, path and
/// working copy did not — a partial commit of the file — so the inline diff's
/// "unchanged" rule reads it (`LocalChangesInlineDiff`). Defaulted to `nil`, so
/// every construction that predates it, iOS's included, compiles unchanged and
/// reads as "unknown".
public struct ChangedFile: Identifiable, Equatable {
    public let path: String
    public let status: FileStatus
    public let oldPath: String?
    public let headObject: String?

    public init(path: String, status: FileStatus, oldPath: String? = nil, headObject: String? = nil) {
        self.path = path
        self.status = status
        self.oldPath = oldPath
        self.headObject = headObject
    }

    /// Stable identity from the repo-relative path.
    public var id: String { path }
}

/// One `git status` answer: the files differing from `HEAD`, and — beside them,
/// never inside them — the repo-relative paths git reports as ignored.
///
/// `ignoredPaths` holds plain paths: a wholly ignored directory arrives as one
/// entry with its trailing `/` already stripped (`GitStatusParser.parseSnapshot`),
/// so it stands for itself and everything below it. `changedFiles` is exactly the
/// list `changedFiles(root:)` answers, which is why a producer that cannot see
/// ignored entries can still build an honest snapshot with an empty ignored list.
public struct GitStatusSnapshot: Equatable {
    public let changedFiles: [ChangedFile]
    public let ignoredPaths: [String]

    public init(changedFiles: [ChangedFile], ignoredPaths: [String]) {
        self.changedFiles = changedFiles
        self.ignoredPaths = ignoredPaths
    }
}
