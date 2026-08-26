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
