import Foundation

/// One entry in a directory listing: a file or a subdirectory.
public struct DirectoryEntry: Identifiable, Equatable {
    public let url: URL
    public let isDirectory: Bool

    public init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    /// Stable identity from the file-system location.
    public var id: URL { url }

    /// The entry's display name (last path component).
    public var name: String { url.lastPathComponent }
}

/// A cheap "has this file changed?" fingerprint: its size and its modification
/// date, read together in one metadata call.
///
/// The symbol index compares this against the stamp it recorded when it last
/// extracted a file, and re-parses only on a difference — which is what keeps an
/// `npm i` (one FSEvents burst, thousands of untouched project files) from
/// re-running tree-sitter over the whole project. It is deliberately *not* a
/// content hash: hashing means reading every file, which is the cost the stamp
/// exists to avoid.
///
/// The accepted inaccuracy is the classic one: a write that preserves both size
/// and mtime looks unchanged. Only a deliberate `touch -t`/`utimes` does that,
/// the editor's own buffers are re-indexed from live text rather than from disk,
/// and the next genuine edit corrects the entry — so the failure mode is a
/// briefly stale symbol, not a wrong jump target.
public struct FileStamp: Equatable, Hashable, Sendable {
    /// The file's size in bytes.
    public let byteCount: Int
    /// The file's content-modification date, or `nil` when the volume did not
    /// report one (a stamp without a date still detects a size change).
    public let modificationDate: Date?

    public init(byteCount: Int, modificationDate: Date?) {
        self.byteCount = byteCount
        self.modificationDate = modificationDate
    }
}

/// Text I/O against the file system, abstracted so the model can be tested
/// with a stub that simulates read/write failures without touching disk.
public protocol FileServicing {
    /// Read the contents of `url` as text.
    func read(url: URL) throws -> String
    /// Write `text` to `url`, replacing any existing contents.
    func write(_ text: String, to url: URL) throws
    /// List the visible contents of the directory at `url`, sorted with
    /// directories first then files, alphabetically (case-insensitive).
    func contentsOfDirectory(at url: URL) throws -> [DirectoryEntry]

    /// Create an empty file at `url`. Throws if the path already exists or its
    /// parent directory is missing.
    func createFile(at url: URL) throws
    /// Create a directory at `url`. Throws if the path already exists or its
    /// parent directory is missing.
    func createDirectory(at url: URL) throws
    /// Ensure a directory exists at `url`, creating any missing intermediate
    /// directories. An existing directory is reused; a non-directory anywhere on
    /// the path throws `FileServiceError.notADirectory`.
    func ensureDirectory(at url: URL) throws
    /// Move/rename the item at `source` to `destination`. Throws on a collision
    /// (an existing destination is not clobbered).
    func move(from source: URL, to destination: URL) throws
    /// Delete the file or directory tree at `url`.
    func removeItem(at url: URL) throws

    /// The literal target path stored in the symbolic link at `url`, or `nil`
    /// when `url` is not a symbolic link.
    ///
    /// Git represents a symlink by its target string (its blob contents), so the
    /// diff layer compares against this rather than reading through the link.
    /// Defaulted to `nil` so non-symlink-aware stubs keep their behavior.
    func symbolicLinkDestination(at url: URL) -> String?

    /// The size of the file at `url` in bytes, or `nil` when it cannot be
    /// determined (the entry vanished, or the service does not track sizes).
    ///
    /// Defaulted to `nil` — "unknown", which callers must treat as "read it and
    /// find out" rather than as "empty".
    func fileByteCount(at url: URL) -> Int?

    /// The size + modification date of the file at `url`, or `nil` when it
    /// cannot be determined.
    ///
    /// Defaulted to `nil` for the same reason as `fileByteCount(at:)`, and with
    /// the same reading: **"unknown" means "re-read it"**. The symbol index's
    /// stamp gate treats a `nil` stamp as "always re-extract", so a partial stub
    /// — or a service on a volume that reports no metadata — degrades to
    /// correct-but-slower rather than to a stale index.
    func fileStamp(at url: URL) -> FileStamp?

    /// Whether the file at `url` exists and this process may execute it.
    ///
    /// **Undefaulted, deliberately** (D22). Every other optional member of this
    /// protocol defaults to an answer that degrades safely — "unknown size",
    /// "unknown stamp", "not a symlink" — but this one is a *gate*: the install
    /// engine asks it before committing a downloaded binary, and a default would
    /// have to answer `false` (a gate that fails every install through a partial
    /// stub) or `true` (a gate that silently passes, which is worse than not
    /// having one). Two conformers ship in `Sources/` — this protocol's own
    /// implementation and the iOS security-scoped decorator — plus a handful of
    /// test stubs, so the compiler asking each of them is the cheap side of that
    /// trade.
    func isExecutableFile(at url: URL) -> Bool

    /// The contents of `url` as text, or `nil` when it should not be searched:
    /// a **binary** file (a NUL byte in its head, git's own heuristic) or one
    /// **larger than `maxBytes`**.
    ///
    /// The project-wide search reads every candidate file through this, so the
    /// "skip binaries and giant files" rule is one decision the service owns
    /// rather than something each caller re-derives. `nil` is "skip this file",
    /// distinct from a thrown error (unreadable/permission denied).
    func readTextIfNotBinary(url: URL, maxBytes: Int) throws -> String?
}

public extension FileServicing {
    func symbolicLinkDestination(at url: URL) -> String? { nil }

    /// Defaulted to "unknown", so a stub that keeps its files in memory needs no
    /// size bookkeeping; the real `FileService` reads the on-disk size.
    func fileByteCount(at url: URL) -> Int? { nil }

    /// Defaulted to "unknown", i.e. "this file always looks changed" — the safe
    /// direction for a cache gate.
    func fileStamp(at url: URL) -> FileStamp? { nil }

    /// A faithful default expressed in terms of `read(url:)` and
    /// `fileByteCount(at:)`, so *any* conforming type — an in-memory stub, the
    /// iOS security-scoped decorator — gets the correct binary/oversize
    /// semantics for free rather than a stub-only shortcut that would lie about
    /// the contract. The real `FileService` overrides it with a byte-level
    /// implementation that never decodes a file it is going to reject.
    ///
    /// Note the two size checks: the cheap pre-read one is skipped when the
    /// service cannot report a size, so the decoded text is measured as well —
    /// a caller can never be handed a buffer larger than it asked for.
    func readTextIfNotBinary(url: URL, maxBytes: Int) throws -> String? {
        if let byteCount = fileByteCount(at: url), byteCount > maxBytes { return nil }
        let text = try read(url: url)
        guard text.utf8.count <= maxBytes else { return nil }
        guard !text.utf8.prefix(FileService.binaryProbeBytes).contains(0) else { return nil }
        return text
    }

    /// Defaulted so stubs that never exercise the mutating operations (the
    /// read/write/listing-only fakes) keep compiling; the real `FileService`
    /// overrides each with a working `FileManager` implementation.
    func createFile(at url: URL) throws {
        throw FileServiceError.unsupported
    }
    func createDirectory(at url: URL) throws {
        throw FileServiceError.unsupported
    }
    func ensureDirectory(at url: URL) throws {
        throw FileServiceError.unsupported
    }
    func move(from source: URL, to destination: URL) throws {
        throw FileServiceError.unsupported
    }
    func removeItem(at url: URL) throws {
        throw FileServiceError.unsupported
    }
}

/// Errors raised by `FileService` for the create/move operations, distinct from
/// the underlying `FileManager`/`POSIX` errors so the view layer can present a
/// clear message (and tests can assert on the cause).
public enum FileServiceError: Error, Equatable, LocalizedError {
    /// The target path already exists (create or non-clobbering move collision).
    case alreadyExists
    /// A stub that does not implement a mutating operation was asked to perform it.
    case unsupported
    /// Something that is not a directory occupies a component of a path that has
    /// to be a directory chain. Carries the offending component's name so the
    /// message can point at it.
    case notADirectory(name: String)
    /// The file a caller asked to open is not there.
    ///
    /// Thrown by the **probe-only** open path alone: a database file is opened
    /// into a viewer tab without ever being read (its bytes are not text), so its
    /// existence is established with `fileStamp(at:)` and a `nil` stamp has to
    /// become an error here. The text path never needs this case — it learns the
    /// file is missing from `String(contentsOf:)`, which throws its own
    /// well-worded `NSError` — which is why the enum had no not-found case until
    /// the viewer arrived. Carries the file's name so the message can point at
    /// it.
    case missingFile(name: String)

    /// Human-readable text so `NSAlert(error:)` shows a clear message rather than
    /// the default "couldn't be completed (… error 0.)" fallback for a raw enum.
    public var errorDescription: String? {
        switch self {
        case .alreadyExists:
            return "An item with that name already exists."
        case .unsupported:
            return "This operation is not supported."
        case let .notADirectory(name):
            return "\"\(name)\" already exists and is not a folder."
        case let .missingFile(name):
            return "\"\(name)\" could not be found."
        }
    }
}

/// Pure, testable text I/O against the file system.
///
/// Kept free of UI so it can be exercised directly in unit tests via
/// temporary files.
public struct FileService: FileServicing {
    public init() {}

    /// Read the contents of `url` as UTF-8 text.
    public func read(url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// Write `text` to `url` as UTF-8, replacing any existing contents.
    public func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// How many leading bytes are probed for a NUL when deciding whether a file
    /// is binary. git uses the same "first 8000 bytes" window in
    /// `buffer_is_binary`, and the point of a *head* probe (rather than a whole
    /// scan) is that it stays O(1) for a large file.
    static let binaryProbeBytes = 8000

    /// The size of the file at `url` in bytes, or `nil` when it cannot be read
    /// (the entry vanished, or its metadata is inaccessible).
    public func fileByteCount(at url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    /// Whether the file at `url` exists and this process may execute it —
    /// `access(2)`'s `X_OK`, as `FileManager` spells it.
    ///
    /// Answers the question the install engine actually has ("can what I just
    /// unpacked be run?") rather than "is the `x` bit set in its mode", which is
    /// the same thing for the binaries this app installs and not the same thing on
    /// a `noexec` mount or under a sandbox that denies it. A directory answers
    /// `false`: `FileManager` reports search permission for one, and a directory
    /// where an executable was expected is exactly the outcome the gate is for.
    public func isExecutableFile(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// The size + modification date of the file at `url`, read in **one**
    /// metadata call — the whole point of the pair being one type: the symbol
    /// index stamps every walked file on every refresh, so two separate `stat`s
    /// per file would double the syscall cost of the gate that exists to save
    /// work.
    ///
    /// `FileManager.attributesOfItem` rather than `URL.resourceValues`, and that
    /// is not a style choice: a `URL` **caches** the resource values it has
    /// already been asked for, so stamping the same `URL` instance twice can
    /// return the first answer even after the file has been rewritten — which in
    /// a cache gate means "unchanged" forever. Reading through the path is
    /// stateless, so a stamp always describes the file as it is now.
    ///
    /// `nil` when the size is unavailable (the entry vanished between the walk
    /// and the stamp, or its metadata is inaccessible), which the index reads as
    /// "re-extract". A missing *date* alone is not `nil`: size changes still
    /// detect the common edit.
    public func fileStamp(at url: URL) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let byteCount = attributes[.size] as? Int
        else { return nil }
        return FileStamp(
            byteCount: byteCount,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }

    /// The contents of `url` as UTF-8 text, or `nil` when the file must not be
    /// searched.
    ///
    /// Three `nil` cases, in the order they are cheapest to detect: the recorded
    /// size exceeds `maxBytes` (no read at all); the loaded data exceeds it (the
    /// size was unavailable, or the file grew between the two); a NUL byte sits
    /// in the first `binaryProbeBytes` bytes (binary); or the bytes are not valid
    /// UTF-8 (a non-UTF-8 encoding is not something the editor can round-trip, so
    /// it is skipped rather than lossily decoded). A genuine read failure still
    /// *throws* — "skip this file" and "this file could not be read" stay
    /// distinguishable.
    public func readTextIfNotBinary(url: URL, maxBytes: Int) throws -> String? {
        if let byteCount = fileByteCount(at: url), byteCount > maxBytes { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= maxBytes else { return nil }
        guard !data.prefix(Self.binaryProbeBytes).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Entries never shown in the project tree: service entries that belong to
    /// the tooling, not the project. Compared by *exact* name — every other
    /// dotfile (`.gitignore`, `.github`, …) is an ordinary, editable entry.
    static let excludedEntryNames: Set<String> = [".git", ".DS_Store"]

    /// Whether an entry named `name` is hidden from the project tree.
    ///
    /// The single source of truth for the exclusion rule, shared by the listing
    /// and by the tree's *rename* validation — an entry the tree would never show
    /// must not be reachable through it either, or it would vanish silently.
    /// Create-path validation uses the stricter, case-insensitive
    /// `isReservedCreateName(_:)` over the same set; see its doc comment for why.
    public static func isExcludedEntryName(_ name: String) -> Bool {
        excludedEntryNames.contains(name)
    }

    /// Whether `name` is a service name the tree must refuse to *create*.
    ///
    /// The same `excludedEntryNames` set as `isExcludedEntryName(_:)`, but
    /// compared *case-insensitively* — create-time validation is deliberately
    /// stricter than the listing. On a case-insensitive volume (the APFS
    /// default) a component spelled `.GIT` resolves onto an existing `.git`, so
    /// creating through it would silently write inside the hidden repository
    /// directory and the new entry would never appear in the tree. The listing
    /// predicate stays exact-match: git and Finder write the exact names, and
    /// hiding a user's own `.Git` folder from the tree would be wrong.
    public static func isReservedCreateName(_ name: String) -> Bool {
        excludedEntryNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// List the visible contents of the directory at `url`.
    ///
    /// Dotfiles are visible; only the entries named in `excludedEntryNames` are
    /// hidden (exact-name comparison). The result is sorted directories-first,
    /// then by name case-insensitively.
    public func contentsOfDirectory(at url: URL) throws -> [DirectoryEntry] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        let entries = urls.compactMap { child -> DirectoryEntry? in
            guard !Self.isExcludedEntryName(child.lastPathComponent) else { return nil }
            guard let isDir = isDirectory(child) else { return nil }
            return DirectoryEntry(url: child, isDirectory: isDir)
        }
        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Create an empty file at `url`.
    ///
    /// Throws `FileServiceError.alreadyExists` if anything already occupies the
    /// path (so an existing file/directory is never clobbered) and lets the
    /// underlying `FileManager` write error propagate when the parent directory
    /// is missing or unwritable.
    public func createFile(at url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw FileServiceError.alreadyExists
        }
        try Data().write(to: url, options: .withoutOverwriting)
    }

    /// Create a directory at `url` (no intermediate directories — the parent must
    /// exist). Throws `FileServiceError.alreadyExists` if the path is occupied.
    public func createDirectory(at url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw FileServiceError.alreadyExists
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
    }

    /// Ensure a directory exists at `url`, creating every missing directory on
    /// the way (the `mkdir -p` shape the tree's relative-path create needs).
    ///
    /// Recursion runs *upward* first: an existing directory returns immediately,
    /// an existing non-directory throws `FileServiceError.notADirectory` naming
    /// that component, and a missing one ensures its parent before creating
    /// itself. So a file sitting anywhere on the path is detected before any
    /// directory is written — nothing lands on disk for a chain that cannot be
    /// completed at that component or above it.
    ///
    /// Directories created before a *later* step fails are **not** rolled back,
    /// matching `mkdir -p` (and VS Code): a failure leaves whatever prefix
    /// already succeeded.
    ///
    /// A **symlink to a directory** on the path is *reused*, not refused: the
    /// existence/type probe dereferences the link, so the chain simply continues
    /// inside the link's target. This is deliberate (again `mkdir -p` behavior),
    /// not an oversight.
    ///
    /// The probe-then-create pair is not atomic, so a failed create is
    /// reconciled against a fresh probe (see
    /// `reconcileDirectoryCreateFailure(at:error:)`): the postcondition is "a
    /// directory exists here", and a concurrent writer that created the very
    /// same directory in between satisfies it rather than failing the create.
    public func ensureDirectory(at url: URL) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw FileServiceError.notADirectory(name: url.lastPathComponent)
            }
            return
        }
        let parent = url.deletingLastPathComponent()
        // Guard the fixed point at the filesystem root (and any degenerate URL
        // whose parent is itself), where recursing would never terminate.
        if parent.path != url.path {
            try ensureDirectory(at: parent)
        }
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false
            )
        } catch {
            try reconcileDirectoryCreateFailure(at: url, error: error)
        }
    }

    /// Decide whether a `createDirectory` failure inside `ensureDirectory` is a
    /// real failure, by re-probing the path.
    ///
    /// `ensureDirectory`'s contract is idempotent — "a directory exists at
    /// `url`" — but its existence probe and its create are two separate
    /// syscalls. Another writer (a build or a `git` run in the embedded
    /// terminal, a sync daemon) can create the same directory in that window,
    /// and the create then fails with `EEXIST` even though the postcondition
    /// now holds; failing the whole relative-path create there would be
    /// spurious. So: a directory now at the path is success, a *non*-directory
    /// raises the same `.notADirectory` the up-front probe would have raised,
    /// and a path that is still absent (a missing or unwritable parent, a
    /// dangling symlink occupying the name) rethrows the original error.
    ///
    /// Internal rather than private so the branches are unit-testable without
    /// staging a real race.
    func reconcileDirectoryCreateFailure(at url: URL, error: Error) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw error
        }
        guard isDir.boolValue else {
            throw FileServiceError.notADirectory(name: url.lastPathComponent)
        }
    }

    /// Move/rename the item at `source` to `destination`, refusing to overwrite
    /// an existing destination (`FileManager.moveItem` would throw on collision,
    /// but the explicit check yields the typed `alreadyExists` error).
    ///
    /// A destination that resolves to the *same* on-disk item as the source is
    /// not a collision: on a case-insensitive volume a case-only rename
    /// (`file.txt` → `File.txt`) reports the destination as already existing
    /// because it matches the source, yet `moveItem` performs it correctly.
    public func move(from source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path),
           !isSameItem(source, destination) {
            throw FileServiceError.alreadyExists
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    /// Whether two URLs refer to the same on-disk item, compared by file
    /// resource identifier (so a case-insensitive-equivalent destination is
    /// recognised as the source itself rather than a different file).
    private func isSameItem(_ a: URL, _ b: URL) -> Bool {
        guard
            let idA = (try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]))?
                .fileResourceIdentifier,
            let idB = (try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]))?
                .fileResourceIdentifier
        else { return false }
        return idA.isEqual(idB)
    }

    /// Delete the file or directory tree at `url`.
    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// The target path of the symbolic link at `url`, or `nil` when `url` is not
    /// a symbolic link (or cannot be read). `destinationOfSymbolicLink` throws for
    /// a non-link, which `try?` maps to `nil`; it inspects the final path
    /// component only, so it does not dereference the link's target.
    public func symbolicLinkDestination(at url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    /// Decide whether `url` is a directory. Prefers the value prefetched by the
    /// directory enumeration; if that is unavailable (a metadata read that
    /// returned no `isDirectory`), falls back to a direct `FileManager` check.
    /// Returns `nil` when the type genuinely cannot be determined (the entry
    /// vanished or could not be inspected) so the caller can omit it rather
    /// than silently treating an undetermined type as a file.
    private func isDirectory(_ url: URL) -> Bool? {
        if let cached = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory {
            return cached
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return nil
        }
        return isDir.boolValue
    }
}
