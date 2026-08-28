import Foundation

/// What caused a Local History snapshot to be taken.
///
/// A **closed** enum with a stable lowercase `tag`, because the tag is not a
/// display detail — it is one of the three fields encoded into a snapshot's file
/// name (`LocalHistoryLayout`), so it is on-disk vocabulary. Renaming a case's
/// tag orphans every snapshot already written under the old one: the parse
/// refuses it, the listing drops it, and retention never reclaims it. Add cases
/// freely; change a `tag` only with that consequence in hand.
///
/// The titles are the window's row labels. Every one but `save` reads "Before …"
/// because a pre-operation snapshot holds what the file looked like *before* the
/// operation ran — that is the whole promise of the label, and phrasing it in the
/// enum keeps the window from inventing a second wording.
///
/// Both branch operations (switch and checkout-remote) share `branch`: they are
/// two call sites with two writer brackets, but from a file's point of view they
/// are the same event, and a user restoring a revision does not care which menu
/// item moved the worktree.
public enum LocalHistoryEvent: String, CaseIterable, Equatable, Sendable {
    /// The app wrote the buffer to disk — the ordinary path, and the only event
    /// that is not a pre-emption of something else.
    case save

    /// Before a project-wide Replace All rewrote matching files.
    case replace

    /// Before a revert threw away worktree changes.
    case revert

    /// Before a merge resolution was applied to the worktree.
    case merge

    /// Before a branch switch, a checkout of a remote branch, or a branch create.
    case branch

    /// Before a commit (which stages, and may rewrite the index through a
    /// temporary one).
    case commit

    /// Before Local History itself replaced a buffer from an older revision, so
    /// a restore is reversible from the history as well as by one ⌘Z.
    case restore

    /// The on-disk token. Lowercase ASCII with no `-`, because `-` is the file
    /// name's field separator.
    public var tag: String { rawValue }

    /// The inverse of `tag`; `nil` for anything this version does not know,
    /// which is how a snapshot written by a future version is ignored rather
    /// than mis-read.
    public init?(tag: String) {
        self.init(rawValue: tag)
    }

    /// The window's label for a revision taken under this event.
    public var title: String {
        switch self {
        case .save: return "Save"
        case .replace: return "Before Replace All"
        case .revert: return "Before Revert"
        case .merge: return "Before Merge Apply"
        case .branch: return "Before Branch Change"
        case .commit: return "Before Commit"
        case .restore: return "Before Restore"
        }
    }
}

/// One stored revision of one file, as it appears in a listing.
///
/// **The file name is the metadata.** Every field here is parsed out of the
/// snapshot's file name by `LocalHistoryLayout`, so listing a file's history is
/// one directory read and *no* content reads; the content is fetched only when a
/// revision is selected. There is no index file to fall out of step with the
/// disk — the disk is the state, and deleting the store's base directory forgets
/// the feature completely without breaking anything else.
///
/// `contentHash` is the first 16 hexadecimal characters of the SHA-256 of the
/// revision's UTF-8 bytes. Sixteen, not sixty-four, because of what it is asked:
/// "is this text byte-for-byte the newest revision already stored?" — a dedup
/// question against a handful of candidates, not a security boundary. A collision
/// costs one skipped snapshot of one file, and 64 bits of it is well past what a
/// file's thirty-revision history can produce by accident.
public struct LocalHistorySnapshot: Equatable, Sendable {
    /// The snapshot's file name inside its file directory, e.g.
    /// `0000001772345678901-save-3f8a1c04b7e29d16.snapshot`. Carried rather than
    /// re-derived so a listing can read a revision back without re-encoding a
    /// name it already has in hand.
    public let fileName: String

    /// When the snapshot was taken, to millisecond resolution — everything the
    /// file name preserves.
    public let timestamp: Date

    public let event: LocalHistoryEvent

    /// 16 lowercase hexadecimal characters. See the type's note.
    public let contentHash: String

    public init(fileName: String, timestamp: Date, event: LocalHistoryEvent, contentHash: String) {
        self.fileName = fileName
        self.timestamp = timestamp
        self.event = event
        self.contentHash = contentHash
    }

    /// Newest first — the one order this feature ever presents or prunes in.
    ///
    /// Sorted on the `timestamp` rather than on the (lexically equivalent) file
    /// name so a snapshot assembled by hand still orders by what it says it is,
    /// with the file name breaking exact ties **descending** so the order is
    /// total and stable: two snapshots of one file can share a millisecond, and a
    /// listing that reshuffles between two reads of an unchanged directory would
    /// make the window's selection jump.
    public static func sortedNewestFirst(_ snapshots: [LocalHistorySnapshot]) -> [LocalHistorySnapshot] {
        snapshots.sorted { left, right in
            if left.timestamp != right.timestamp { return left.timestamp > right.timestamp }
            return left.fileName > right.fileName
        }
    }
}
