import Foundation

/// Where Local History keeps its snapshots, as pure path math over a base
/// directory the app supplies.
///
/// **No file system access, on purpose** — the `LSPInstallLayout` /
/// `LeetCodeCacheLayout` discipline, restated for a third root: nothing here
/// stats, reads, creates or deletes, so the store's tests can reason about paths
/// against a `StubFileTree` while the app points the same math at
/// `~/Library/Application Support/Pisaka/LocalHistory`. A method that answers a
/// `URL` is not claiming anything is there.
///
/// The shape it describes:
///
/// ```text
/// <base>/                                   ~/Library/Application Support/Pisaka/LocalHistory
///   <rootName>-<16 hex of sha256(root path)>/          one per project root
///     <32 hex of sha256(project-relative path)>/       one per file
///       0000001772345678901-save-3f8a1c04b7e29d16.snapshot
///       0000001772345699999-commit-9b1d0e6a5c74f382.snapshot
/// ```
///
/// Three properties carry the design.
///
/// **The snapshot file *is* the content.** Its exact UTF-8 text, nothing
/// prepended and nothing wrapped — so a revision can be read with one `read` and
/// compared with one `==`, and a snapshot directory is intelligible to anyone who
/// opens it in a text editor.
///
/// **The metadata is the file name.** Timestamp, event and content hash live in
/// the name, so listing a file's history is one directory read with no content
/// reads, dedup against the newest revision is a string comparison, and retention
/// prunes on names alone. There is no index file that can fall out of step with
/// the disk.
///
/// **Directories are hashed, not spelled.** A project-relative path contains
/// `/`, may be arbitrarily deep, and can exceed a file name's length on its own;
/// mirroring the tree would also make the store's layout leak the project's
/// structure into a directory anyone can list. One 32-hex digest is a legal,
/// fixed-width, flat component. The cost is that the store cannot be read
/// backwards — given a snapshot directory you cannot say which file it belongs
/// to — which is acceptable because every reader arrives holding the file it is
/// asking about. The project directory keeps a *readable* prefix (the root's own
/// name) in front of its digest purely so a human deleting one project's history
/// by hand can find it; the digest alone is the identity.
public struct LocalHistoryLayout: Equatable, Sendable {
    /// The store root — `…/Application Support/Pisaka/LocalHistory` in the app, a
    /// temporary directory in the tests.
    public let base: URL

    /// `base` is normalised lexically (`.`/`..` resolved, no `realpath(3)` and no
    /// `stat(2)`) and re-spelled as a directory URL, so two spellings of one root
    /// compare equal — this is a value the models hold and compare.
    ///
    /// `URL.standardizedFileURL` is deliberately not what does that: it consults
    /// the disk under `/private/{tmp,var,etc}`, which is the bug
    /// `LSPInstallLayout.normalisedComponents(of:)` records at length.
    public init(base: URL) {
        self.base = URL(
            fileURLWithPath: "/" + Self.pathComponents(of: base.path).joined(separator: "/"),
            isDirectory: true
        )
    }

    /// The directory name the app appends to its Application Support directory.
    /// Here rather than in the app so the one place that spells it is the one
    /// place the "delete this to forget everything" instruction points at.
    public static let directoryName = "LocalHistory"

    /// The extension every snapshot file carries. A directory entry without it is
    /// not ours and is left alone.
    public static let snapshotExtension = "snapshot"

    /// Hexadecimal characters of the content digest kept in a file name. See
    /// `LocalHistorySnapshot.contentHash` for why 16 is enough.
    public static let contentHashLength = 16

    /// Hexadecimal characters of the digest naming a project's directory. The
    /// readable root name in front of it means a human can find the directory;
    /// these 64 bits are what makes it unique.
    public static let projectHashLength = 16

    /// Hexadecimal characters of the digest naming a file's directory. Longer
    /// than the project's because it is the *whole* identity — nothing readable
    /// precedes it, and a collision here would merge two files' histories.
    public static let fileHashLength = 32

    /// Digits of the millisecond timestamp a snapshot's name opens with. Nineteen
    /// zero-padded digits is the width of `Int64.max`, so **every** representable
    /// timestamp encodes to the same width and lexical order over names is
    /// chronological order — which is what lets the store sort a directory
    /// listing without parsing, and lets retention find the newest revision by
    /// looking at names.
    public static let timestampDigits = 19

    /// How much of a project root's own name is kept in front of its digest,
    /// **in UTF-8 bytes**. A file name is bounded (255 bytes on APFS) and a
    /// directory name can be long; the prefix is a human hint, not identity, so
    /// truncating it costs nothing.
    ///
    /// Bytes rather than characters because that is what the bound is measured
    /// in: 64 emoji are 64 `Character`s and 256 bytes, which with the digest
    /// after them names a directory the file system refuses to create — and a
    /// project whose directory cannot be created has no history at all, silently.
    private static let projectNamePrefixBytes = 64

    // MARK: - Directories

    /// The area holding every snapshot taken for files under `root`.
    ///
    /// The digest is over the root's *lexically* normalised path, matching this
    /// type's no-disk rule. Its stated limit is `LSPInstallLayout`'s: two
    /// spellings of one directory (`/tmp/x` and `/private/tmp/x`) name two areas.
    /// Reachable only by opening one project under two spellings, and it costs a
    /// second history rather than a wrong one.
    public func projectDirectory(forRoot root: URL) -> URL {
        let components = Self.pathComponents(of: root.path)
        let path = "/" + components.joined(separator: "/")
        let digest = Self.digest(of: path, length: Self.projectHashLength)
        let name = Self.readableName(components.last ?? "")
        return base.appendingPathComponent("\(name)-\(digest)", isDirectory: true)
    }

    /// The directory holding one file's revisions.
    ///
    /// `relativePath` is the project-relative path `ProjectFileWalk
    /// .relativePath(of:under:)` produces — the one relative-path helper in this
    /// codebase — and is normalised here the same way the roots are, so
    /// `a/./b.swift` and `a/b.swift` are one file rather than two histories.
    public func fileDirectory(forRoot root: URL, relativePath: String) -> URL {
        let normalised = Self.pathComponents(of: relativePath).joined(separator: "/")
        let digest = Self.digest(of: normalised, length: Self.fileHashLength)
        return projectDirectory(forRoot: root).appendingPathComponent(digest, isDirectory: true)
    }

    /// Whether `url` is inside the store — the assertion that this layer only
    /// ever writes its own files.
    ///
    /// Lexical, like everything else here, and asked through `LSPInstallLayout`'s
    /// implementation so that "inside my root" is one comparison in this codebase
    /// rather than three that could drift apart.
    public func contains(_ url: URL) -> Bool {
        LSPInstallLayout.directory(base, contains: url)
    }

    // MARK: - Snapshot names

    /// The content hash a snapshot's name carries: the first
    /// `contentHashLength` hexadecimal characters of the SHA-256 of `text`'s
    /// UTF-8 bytes.
    ///
    /// The one producer, so the truncation length is stated once. The policy asks
    /// for it and the store compares its answer against the newest revision's
    /// `contentHash` — a name comparison, never a content read.
    public static func contentHash(of text: String) -> String {
        digest(of: text, length: contentHashLength)
    }

    /// The file name a snapshot is written under.
    ///
    /// `contentHash` must be what `contentHash(of:)` answered; the parse refuses
    /// anything else, which would leave the snapshot invisible to listing and to
    /// retention. It is not sanitised here because there is exactly one producer
    /// and pretending otherwise would hide a caller bug behind a silently
    /// different name.
    ///
    /// Timestamps before 1970 clamp to zero rather than emitting a `-` that would
    /// break both the field split and the lexical ordering. Unreachable — a
    /// snapshot is stamped when it is taken — and a clamp keeps the invariant
    /// total.
    public static func snapshotFileName(
        timestamp: Date,
        event: LocalHistoryEvent,
        contentHash: String
    ) -> String {
        let milliseconds = max(0, Int64((timestamp.timeIntervalSince1970 * 1000).rounded()))
        let stamp = String(format: "%0\(timestampDigits)lld", milliseconds)
        return "\(stamp)-\(event.tag)-\(contentHash).\(snapshotExtension)"
    }

    /// The inverse: a directory entry's name back into a snapshot, or `nil`.
    ///
    /// **`nil` is the whole error handling of a listing.** Anything malformed —
    /// a foreign file someone dropped in, a partially written name from a
    /// crashed older build, a tag a future version invented, a nested path — is
    /// ignored rather than reported, because a history listing has no useful way
    /// to complain and the alternative (a partially filled snapshot) would let a
    /// wrong timestamp or a wrong hash reach dedup and retention. Every field is
    /// checked: exactly three `-`-separated fields, exactly 19 ASCII digits, a
    /// known tag, exactly 16 lowercase hex characters, and the exact extension.
    public static func snapshot(fromFileName name: String) -> LocalHistorySnapshot? {
        guard !name.contains("/") else { return nil }
        let suffix = ".\(snapshotExtension)"
        guard name.hasSuffix(suffix) else { return nil }
        let stem = String(name.dropLast(suffix.count))
        let fields = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }

        let stamp = fields[0]
        guard stamp.count == timestampDigits, stamp.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard let milliseconds = Int64(stamp) else { return nil }
        guard let event = LocalHistoryEvent(tag: String(fields[1])) else { return nil }

        let hash = String(fields[2])
        guard hash.count == contentHashLength, hash.allSatisfy(isLowercaseHexadecimal) else { return nil }

        return LocalHistorySnapshot(
            fileName: name,
            timestamp: Date(timeIntervalSince1970: Double(milliseconds) / 1000),
            event: event,
            contentHash: hash
        )
    }

    // MARK: - Private

    private static func isLowercaseHexadecimal(_ character: Character) -> Bool {
        character.isASCII && (character.isNumber || ("a"..."f").contains(character))
    }

    /// The lexical path split every method here shares: `/`-separated, `.`
    /// dropped, `..` popped, empty components dropped. Applied to absolute paths
    /// and to project-relative ones alike — the caller decides whether to put a
    /// leading `/` back.
    private static func pathComponents(of path: String) -> [String] {
        var components: [String] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(String(component))
            }
        }
        return components
    }

    private static func digest(of text: String, length: Int) -> String {
        String(SHA256.hexadecimalDigest(of: Data(text.utf8)).prefix(length))
    }

    /// A project root's own name, made safe to be one directory component: the
    /// two characters a POSIX/HFS path can read as a separator replaced, the
    /// result truncated to a bounded width, and an empty result named outright.
    /// Only ever a hint — nothing parses it back, and the digest beside it is
    /// the identity.
    private static func readableName(_ name: String) -> String {
        var truncated = ""
        var bytes = 0
        for character in name {
            let cleaned: Character = (character == "/" || character == ":") ? "_" : character
            // Whole characters only: a name cut mid-scalar is not a name, and the
            // point of the prefix is that a human can read it.
            let width = String(cleaned).utf8.count
            guard bytes + width <= projectNamePrefixBytes else { break }
            truncated.append(cleaned)
            bytes += width
        }
        return truncated.isEmpty ? "project" : truncated
    }
}
