import Foundation

/// The Local Changes panel's inline diff rule: whether the selected file's
/// published diff still describes it, so a refresh that changed nothing about
/// that file costs no read and no diff.
///
/// Pure and Foundation-only. `LocalChangesModel.loadSelectionDiff(token:)`
/// computes the current `Fingerprint` on the main actor (the stamp is one stat
/// call) and asks `needsRebuild`; only a `true` answer reads `HEAD`, reads the
/// working copy and runs `LineDiff`.
///
/// It also decides what a rebuild *shows*: `Content` is rows, or one of two
/// refusals — a binary side, or a side over `maxSideBytes` — so a file that
/// cannot be read line by line is never turned into lines.
public enum LocalChangesInlineDiff {
    /// The largest side, in bytes, the panel diffs inline.
    ///
    /// It is the commit dialog's `maxSelectableFileBytes`, so a file whose hunks
    /// the commit dialog refuses to split is a file the panel refuses to diff
    /// inline: one threshold for "too large to read line by line" across the two
    /// git surfaces. Restated rather than referenced so this pure rule never
    /// reaches into the main-actor dialog model; `LocalChangesInlineDiffTests`
    /// pins the two equal.
    public static let maxSideBytes = 1 << 20

    /// What the inline diff shows for one file.
    public enum Content: Equatable {
        /// The side-by-side rows, `HEAD` against the working copy.
        case rows([DiffRow])
        /// A side is binary — a NUL in its probed head, or not UTF-8.
        case binary
        /// A side is larger than `maxSideBytes`.
        case tooLarge
    }

    /// One side of the diff, classified before it is ever turned into lines.
    public enum Side: Equatable {
        /// The side does not exist: an added/untracked file's `HEAD` or a
        /// deleted file's working copy.
        case absent
        /// The side should exist but its read failed. Shown as an empty side,
        /// like `.absent`, but never remembered: `Fingerprint.remembering`
        /// forgets that side's identity, so the next load re-reads it rather
        /// than leaving one transient failure standing as the file's diff.
        case unreadable
        case text(String)
        case binary
        case tooLarge

        /// Whether the side refuses the inline diff by itself, so the other side
        /// need not be read.
        public var isRefusal: Bool {
            switch self {
            case .binary, .tooLarge: return true
            case .absent, .unreadable, .text: return false
            }
        }
    }

    /// The working copy of `file`, classified with **the cap decided before any
    /// read** wherever the size is known.
    ///
    /// A deleted file is `.absent`. A symlink is its **target string** — what git
    /// stores as the blob — never the dereferenced file's contents. A `stamp`
    /// over `maxSideBytes` is `.tooLarge` with no read at all; otherwise the file
    /// is read through `readTextIfNotBinary(url:maxBytes:)`, whose `nil` is
    /// `.binary` (an unknown size that turns out over the cap lands there too —
    /// either way there are no lines to show). A read that throws is
    /// `.unreadable`: shown as the empty side the diff has always shown for an
    /// unreadable file, but not remembered.
    ///
    /// Runs off the main actor: it touches nothing but `fileService`.
    public static func workingSide(
        for file: ChangedFile,
        url: URL,
        stamp: FileStamp?,
        fileService: FileServicing
    ) -> Side {
        guard file.status != .deleted else { return .absent }
        if let target = fileService.symbolicLinkDestination(at: url) { return .text(target) }
        if let stamp, stamp.byteCount > maxSideBytes { return .tooLarge }
        do {
            guard let text = try fileService.readTextIfNotBinary(url: url, maxBytes: maxSideBytes) else {
                return .binary
            }
            return .text(text)
        } catch {
            return .unreadable
        }
    }

    /// The `HEAD` blob, classified: over `maxSideBytes` is `.tooLarge`, otherwise
    /// `GitBlobText.classify` decides. `nil` (no object, or a read that failed)
    /// is `.absent` — unless the side was `expected` (`Fingerprint.hasHeadSide`),
    /// when it is `.unreadable`: `HEAD` holds a file of that status, so a missing
    /// answer is a failed read, not an empty side to remember.
    public static func headSide(_ data: Data?, expected: Bool = false) -> Side {
        if data == nil && expected { return .unreadable }
        if let data, data.count > maxSideBytes { return .tooLarge }
        switch GitBlobText.classify(data) {
        case .absent: return .absent
        case .binary: return .binary
        case .text(let text): return .text(text)
        }
    }

    /// What to show for the two classified sides.
    ///
    /// A refused working side wins outright — the model never reads `HEAD`
    /// after one. Otherwise an over-cap `HEAD` is `.tooLarge` and a binary one
    /// `.binary`; only two text-or-absent sides reach `LineDiff`, an absent side
    /// being empty.
    public static func content(head: Side, working: Side) -> Content {
        for side in [working, head] {
            switch side {
            case .tooLarge: return .tooLarge
            case .binary: return .binary
            case .absent, .unreadable, .text: continue
            }
        }
        return .rows(LineDiff.rows(old: head.text, new: working.text))
    }
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
            self.init(
                root: root,
                status: file.status,
                path: file.path,
                oldPath: file.oldPath,
                headObject: file.headObject,
                workingStamp: workingStamp
            )
        }

        private init(
            root: URL,
            status: FileStatus,
            path: String,
            oldPath: String?,
            headObject: String?,
            workingStamp: FileStamp?
        ) {
            self.root = root
            self.status = status
            self.path = path
            self.oldPath = oldPath
            self.headObject = headObject
            self.workingStamp = workingStamp
        }

        /// The fingerprint to publish with content built from `head` and
        /// `working`: this one, with the identity of each `.unreadable` side
        /// forgotten, so `needsRebuild` treats it as unknown and the next load
        /// re-reads it.
        public func remembering(head: Side, working: Side) -> Fingerprint {
            Fingerprint(
                root: root,
                status: status,
                path: path,
                oldPath: oldPath,
                headObject: head == .unreadable ? nil : headObject,
                workingStamp: working == .unreadable ? nil : workingStamp
            )
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

private extension LocalChangesInlineDiff.Side {
    /// The side's text for `LineDiff`; only text and absent sides are asked.
    var text: String {
        if case .text(let text) = self { return text }
        return ""
    }
}
