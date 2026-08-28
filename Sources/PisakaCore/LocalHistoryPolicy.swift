import Foundation

/// Why a candidate revision was not stored.
///
/// Every skip is **silent** — Local History is a safety net running behind
/// ordinary work, and a net that interrupts the work it is protecting is worse
/// than no net. The reasons exist so the store and the tests can say *which*
/// rule fired, not so a user can be told; nothing in the app surfaces one.
public enum LocalHistorySkipReason: Equatable, Sendable {
    /// The buffer has no file to belong to: an untitled tab, or a titled one with
    /// no project root open. There is nowhere in the store to put it — the store
    /// is keyed by (root, project-relative path) — and an untitled buffer has no
    /// identity that survives the session anyway.
    case untitled

    /// A relative path that leaves the project root: absolute, or escaping
    /// through `..`. The callers derive their paths with
    /// `ProjectFileWalk.relativePath(of:under:)`, which degrades an outside url
    /// to its bare file name rather than answering `nil`, so this is the guard
    /// that keeps a file the user opened from *elsewhere* out of this project's
    /// history — and, since the layout hashes whatever it is handed, the guard
    /// that keeps two unrelated files from sharing one history under the same
    /// bare name.
    case outsideProject

    /// The content's UTF-8 byte count exceeds `maxContentBytes`.
    case tooLarge(bytes: Int)

    /// The content hashes equal to the file's newest stored revision — the same
    /// bytes are already there. This is the common case on an aggressive
    /// autosave: most saves change nothing on disk that the previous snapshot
    /// does not already hold.
    case unchanged
}

/// The answer to "should this text be stored, and under what hash".
public enum LocalHistoryCaptureDecision: Equatable, Sendable {
    /// Store it. The hash is what the snapshot's file name carries, already
    /// truncated to `LocalHistoryLayout.contentHashLength`, so the caller never
    /// digests the text a second time.
    case capture(hash: String)

    case skip(LocalHistorySkipReason)

    /// Convenience for the call sites (and the tests) that only care whether
    /// bytes are about to be written.
    public var hash: String? {
        guard case .capture(let hash) = self else { return nil }
        return hash
    }
}

/// The one place Local History decides *whether* to keep bytes and *which* bytes
/// to keep — pure, Foundation-only, and holding no file system of its own.
///
/// Two questions, both answered here so neither the store, the capture model nor
/// the window can grow a second opinion:
///
/// - **Capture**: `capture(of:relativePath:latestHash:)` — the whole skip rule,
///   in one precedence order.
/// - **Retention**: `prune(_:now:)` — what a file's directory should still hold,
///   decided on snapshot *names* alone (which is what makes retention one
///   directory read; see `LocalHistoryLayout`).
///
/// The ceilings are instance properties with the stated defaults rather than
/// bare constants, because the store holds a policy value: the app builds the
/// default one and the tests build a small one, and neither has to restate the
/// rules to exercise them. There is **no settings UI** — these numbers are a
/// stated behaviour of the feature, not a preference. Whatever they are, the
/// newest revision of a file always survives both retention rules, so the safety
/// net never empties itself.
public struct LocalHistoryPolicy: Equatable, Sendable {
    /// The largest content that will ever be snapshotted, in UTF-8 bytes —
    /// 1 MiB, and deliberately *the same* 1 MiB Find in Files already refuses to
    /// read (`ProjectSearchModel.defaultMaxFileBytes`). One ceiling for "a text
    /// file this editor works on", asked in two places rather than guessed twice:
    /// a file too big for the search engine to scan is also one whose thirty
    /// revisions have no business sitting in Application Support.
    public static let defaultMaxContentBytes = ProjectSearchModel.defaultMaxFileBytes

    /// How long a revision is kept — 14 days. Long enough to cover "what did this
    /// look like before last week's refactor" (which is the accident this feature
    /// exists for), short enough that an ordinary project's history stays small
    /// without the user ever being asked about it.
    public static let defaultMaxAge: TimeInterval = 14 * 24 * 60 * 60

    /// How many revisions one file keeps — 30. The age bound alone is unbounded
    /// in *volume*: a file saved by an aggressive autosave can produce hundreds
    /// of revisions in an afternoon, and the oldest of those is worth far less
    /// than the fact that the last thirty are instant to list.
    public static let defaultRevisionsPerFile = 30

    /// How many files a single pre-operation capture will read **from disk** —
    /// 200. Not a storage bound but a latency one: the capture is awaited in
    /// front of a git command the user asked for, so a worktree with thousands of
    /// changed files must not put an unbounded read pass between the click and
    /// the operation. Buffers are not affected — they are already in memory, are
    /// what the user is actually editing, and are captured in full.
    public static let defaultMaxPreOperationFiles = 200

    public let maxContentBytes: Int
    public let maxAge: TimeInterval
    public let revisionsPerFile: Int
    public let maxPreOperationFiles: Int

    public init(
        maxContentBytes: Int = LocalHistoryPolicy.defaultMaxContentBytes,
        maxAge: TimeInterval = LocalHistoryPolicy.defaultMaxAge,
        revisionsPerFile: Int = LocalHistoryPolicy.defaultRevisionsPerFile,
        maxPreOperationFiles: Int = LocalHistoryPolicy.defaultMaxPreOperationFiles
    ) {
        self.maxContentBytes = maxContentBytes
        self.maxAge = maxAge
        self.revisionsPerFile = revisionsPerFile
        self.maxPreOperationFiles = maxPreOperationFiles
    }

    // MARK: - Capture

    /// Whether `text` should be stored as the next revision of `relativePath`.
    ///
    /// `relativePath` is `nil` when the caller could not produce one — an
    /// untitled buffer, or no project root open. `latestHash` is the
    /// `contentHash` of that file's newest stored revision, or `nil` when the
    /// file has no history yet; it is a *name* the caller already had in hand
    /// from a directory listing, never a content read.
    ///
    /// The precedence is deliberate and is what the tests pin: identity first
    /// (there is nowhere to write), then containment, then size, then sameness.
    /// The digest is computed last, so the two cheap refusals never pay for one,
    /// and a 1 MiB ceiling is checked before hashing a file that could be far
    /// larger.
    ///
    /// One skip listed in the design does **not** appear here: content that is
    /// not decodable UTF-8. It cannot be — this takes a `String`. It is reachable
    /// only on the disk-read capture path, where `FileServicing
    /// .readTextIfNotBinary(url:maxBytes:)` is the gate that answers `nil`, and
    /// that call is also where the byte ceiling is enforced a second time before
    /// a big file is ever pulled into memory.
    public func capture(
        of text: String,
        relativePath: String?,
        latestHash: String?
    ) -> LocalHistoryCaptureDecision {
        guard let relativePath, !relativePath.isEmpty else { return .skip(.untitled) }
        guard Self.isInsideProject(relativePath) else { return .skip(.outsideProject) }

        let bytes = text.utf8.count
        guard bytes <= maxContentBytes else { return .skip(.tooLarge(bytes: bytes)) }

        let hash = LocalHistoryLayout.contentHash(of: text)
        guard hash != latestHash else { return .skip(.unchanged) }
        return .capture(hash: hash)
    }

    /// Whether a project-relative path stays inside the project.
    ///
    /// Lexical, like every other containment question this feature asks: an
    /// absolute path is out, and a path is out the moment its `..` components
    /// pop past the root. `.` components and empty ones are noise and are
    /// dropped, matching the normalisation `LocalHistoryLayout` applies before it
    /// digests the path — so a path this accepts is a path the layout can key.
    private static func isInsideProject(_ relativePath: String) -> Bool {
        guard !relativePath.hasPrefix("/") else { return false }
        var depth = 0
        for component in relativePath.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                depth -= 1
                if depth < 0 { return false }
            default:
                depth += 1
            }
        }
        return depth > 0
    }

    // MARK: - Retention

    /// What one file's directory should still hold, and what may be deleted.
    ///
    /// Three rules in order:
    ///
    /// 1. **Age** — anything older than `maxAge` goes.
    /// 2. **Count** — of what is left after age, only the newest
    ///    `revisionsPerFile` stay.
    /// 3. **The newest always survives**, unconditionally, even when the first
    ///    two rules just condemned it. This is the rule that makes the feature
    ///    trustworthy rather than merely tidy: a file edited once and then left
    ///    alone for a month still has the revision from before that edit. It is
    ///    applied as a reinstatement rather than as an exception inside the other
    ///    two so that the two remain plain and the guarantee is stated once.
    ///
    /// Both returned arrays are newest-first. An event label buys nothing here —
    /// a `save` and a `commit` snapshot age out on identical terms — because a
    /// label describes *why* a revision was taken, not how much it is worth, and
    /// privileging labelled ones would quietly make a busy repository's history
    /// mostly pre-operation snapshots of files nobody edited.
    ///
    /// `now` is passed in rather than read, so retention is a pure function of
    /// its inputs and the boundary cases are testable without waiting.
    public func prune(
        _ snapshots: [LocalHistorySnapshot],
        now: Date
    ) -> (keep: [LocalHistorySnapshot], delete: [LocalHistorySnapshot]) {
        let ordered = LocalHistorySnapshot.sortedNewestFirst(snapshots)
        guard let newest = ordered.first else { return (keep: [], delete: []) }

        var keep: [LocalHistorySnapshot] = []
        var delete: [LocalHistorySnapshot] = []
        var kept = 0
        for snapshot in ordered {
            let expired = now.timeIntervalSince(snapshot.timestamp) > maxAge
            let overflowing = kept >= revisionsPerFile
            if expired || overflowing {
                delete.append(snapshot)
            } else {
                keep.append(snapshot)
                kept += 1
            }
        }

        // Rule 3. Only ever moves the single newest revision, and only when the
        // rules above condemned it, so `keep` stays newest-first by construction.
        if keep.isEmpty {
            keep = [newest]
            delete.removeAll { $0 == newest }
        }
        return (keep: keep, delete: delete)
    }
}
