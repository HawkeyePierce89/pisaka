import Foundation

/// The Local Changes panel's inline diff rule: whether the selected file's
/// published diff still describes it, so a refresh that changed nothing about
/// that file costs no read and no diff.
///
/// Pure and Foundation-only. `LocalChangesModel.loadSelectionDiff(token:)`
/// computes the current `Fingerprint` on the main actor (the stamp is one stat
/// call) and asks `needsRebuild`; only a `true` answer reads `HEAD`, reads the
/// working copy and runs `LineDiff`.
public enum LocalChangesInlineDiff {
    /// Everything the inline diff of one file was computed from, as far as it
    /// can be known without reading either side.
    ///
    /// - `status`, `path` and `oldPath` decide *which* sides are read and from
    ///   where.
    /// - `headObject` is status's `hH`: the only cheap signal that the `HEAD`
    ///   side changed while everything else did not — a partial commit of the
    ///   selected file moves `HEAD` and leaves the working copy untouched.
    /// - `workingStamp` is the working copy's size + modification date
    ///   (`FileServicing.fileStamp`).
    /// - `root` is the repository the paths are relative to, so a same-path file
    ///   in another repository never matches a diff published for this one.
    public struct Fingerprint: Equatable {
        public let root: URL
        public let status: FileStatus
        public let path: String
        public let oldPath: String?
        public let headObject: String?
        public let workingStamp: FileStamp?

        public init(file: ChangedFile, root: URL, workingStamp: FileStamp?) {
            self.root = root
            self.status = file.status
            self.path = file.path
            self.oldPath = file.oldPath
            self.headObject = file.headObject
            self.workingStamp = workingStamp
        }

        /// Whether the diff reads a working copy: every status but `.deleted`.
        public var hasWorkingSide: Bool { status != .deleted }

        /// Whether the diff reads `HEAD`: the statuses whose file exists there.
        /// Added and untracked files have an empty old side.
        public var hasHeadSide: Bool {
            switch status {
            case .modified, .deleted, .renamed, .conflicted: return true
            case .added, .untracked: return false
            }
        }
    }

    /// Whether the diff must be (re)built for `current`, given the fingerprint of
    /// the diff on screen.
    ///
    /// `true` when nothing is published, when the fingerprints differ, and
    /// whenever a side the diff reads has an unknown identity: a `nil` working
    /// stamp for a file with a working side, or a `nil` head object for a file
    /// with a `HEAD` side. **Unknown means re-read** — the `FileServicing.fileStamp`
    /// convention — so a stub, a volume without metadata or a producer without
    /// `hH` (the iOS service, an unmerged record) degrades to always correct,
    /// never to a stale diff. `false` only for an equal fingerprint whose every
    /// read side is known.
    public static func needsRebuild(published: Fingerprint?, current: Fingerprint) -> Bool {
        guard let published, published == current else { return true }
        if current.hasWorkingSide && current.workingStamp == nil { return true }
        if current.hasHeadSide && current.headObject == nil { return true }
        return false
    }
}
