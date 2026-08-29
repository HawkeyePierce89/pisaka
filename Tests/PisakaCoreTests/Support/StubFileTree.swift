import Foundation
@testable import PisakaCore

/// A blocking rendezvous an off-main routine runs into, so a test can hold it
/// suspended while it changes model state on the main actor.
///
/// The `ProjectSearchModelTests.Gate` shape, lifted into shared support because
/// the traversal and the symbol index both need to stage "what happens when a
/// folder switch lands *during* this walk".
final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var reachedFlag = false

    /// Whether the gated code has been entered (readable from any thread).
    var reached: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachedFlag
    }

    func wait() {
        lock.lock()
        reachedFlag = true
        lock.unlock()
        semaphore.wait()
    }

    func release() { semaphore.signal() }

    /// Spin the caller's actor until the gated code has been entered, so a test
    /// never proceeds before the work it means to interrupt is actually running.
    func waitUntilReached() async {
        while !reached { await Task.yield() }
    }
}

/// An in-memory project tree behind `FileServicing`: `files` maps root-relative
/// paths to contents, and the directory listing is derived from those keys.
///
/// Deliberately *does not* filter `.git`/`.DS_Store` — that is the traversal's
/// job (`ProjectFileWalk`), and a test for it would be vacuous if the stub hid
/// them first. Equally deliberately, `fileStamp(at:)` is derived from the
/// contents rather than from a clock: an edit changes the stamp, and re-writing
/// identical text does not, which is exactly the property the symbol index's
/// stamp gate is asserted on.
final class StubFileTree: FileServicing, @unchecked Sendable {
    /// Mutable so a test can re-point the whole tree at a second folder, which is
    /// how the folder-switch tests give the *new* project real files to find.
    var root: URL
    var files: [String: String]
    /// Root-relative directory paths that exist in their own right.
    ///
    /// A tree derived from file paths alone cannot represent an *empty*
    /// directory, and the install engine creates several before it writes
    /// anything into them (a staging tree, an artifact's destination) — so
    /// `ensureDirectory`/`createDirectory` record them here and the listing reads
    /// both halves.
    var directories: Set<String> = []
    /// Root-relative paths reported as symbolic links.
    var symlinks: Set<String> = []
    /// Root-relative paths reported as executable — the injection point for the
    /// install engine's `.gzip` gate, which is a question no in-memory tree can
    /// derive from its contents. A file that is not in here is an ordinary,
    /// non-executable file, which is what an unpacker that forgot the mode leaves
    /// behind.
    var executableFiles: Set<String> = []
    /// Root-relative directory paths whose listing throws (`""` for the root).
    var unreadableDirectories: Set<String> = []
    /// Root-relative paths whose `read` throws.
    var unreadableFiles: Set<String> = []
    /// Root-relative paths `readTextIfNotBinary` declines (binary or oversize).
    var skippedFiles: Set<String> = []
    /// Stamps reported instead of the content-derived one, so a test can stage a
    /// file that changed without changing size.
    var stampOverrides: [String: FileStamp] = [:]
    /// When set, `fileStamp(at:)` reports "unknown" for every file — the
    /// degradation a partial stub or an uncooperative volume produces.
    var stampsAreUnavailable = false
    /// Root-relative *destination* paths whose `move` throws — the injection
    /// point for "the rename failed", which is the one install step that has
    /// already produced a complete tree by the time it can go wrong.
    ///
    /// Keyed by destination rather than by source on purpose: the destination is
    /// the version directory, which the manifest determines completely, while the
    /// source is a staging directory whose name carries an attempt counter no
    /// test should have to predict.
    var moveFailures: Set<String> = []
    /// Root-relative paths whose `write` throws — a read-only cache directory,
    /// a full volume, an iOS security scope that has lapsed. The injection point
    /// for "the write failed but the operation must still succeed", which is the
    /// LeetCode catalog's degradation rule: its cache is an optimisation, and
    /// failing to persist it may not fail the open the user asked for.
    var writeFailures: Set<String> = []
    /// Root-relative paths whose `removeItem` throws — a directory the volume
    /// will not let go of, which is the one way a Remove can fail after the
    /// registry push that stopped the server has already happened.
    var removeFailures: Set<String> = []
    /// Held on the *first* directory listing, if set.
    var listingGate: Gate?
    /// Re-spells the directory the listing's entry URLs hang off, without moving
    /// anything: the tree still answers to the paths it was given, only the URLs
    /// handed *back* read differently.
    ///
    /// The one thing an in-memory tree cannot otherwise reproduce about
    /// `FileManager.contentsOfDirectory(at:)`: it resolves the parent's symlinks
    /// in the URLs it returns, so a listing of `/tmp/x` comes back spelled
    /// `/private/tmp/x/…`. Code that compares a listed entry against a path it
    /// computed itself is wrong in exactly that case and correct in every case a
    /// stub without this hook can stage — see `LSPInstallEngine.sweepStaging`.
    var listingSpelling: ((URL) -> URL)?
    /// Called with the root-relative path at the *start* of every `write`,
    /// before the failure set is consulted.
    ///
    /// The hook for a write whose surroundings change *between* attempts — the
    /// file directory a concurrent sweep reclaimed, which `LocalHistoryStore
    /// .capture` answers with one retry. A path-keyed failure set cannot express
    /// it: those failures are permanent, and this one is exactly the transient
    /// kind the retry exists for.
    var onWrite: ((String) -> Void)?
    /// Called with the root-relative path at the *start* of every `removeItem`,
    /// before the failure set is consulted.
    ///
    /// The counterpart to `onWrite`, for the surroundings that change *during* a
    /// removal sequence: the quit-time capture that lands a snapshot in a file
    /// directory while `LocalHistoryStore.prune(directory:now:)` is clearing that
    /// directory's `.partial` debris, which the sweep answers by re-listing
    /// before it removes the directory itself.
    var onRemove: ((String) -> Void)?

    /// Held on the read of this exact root-relative path, once.
    var readGate: (path: String, gate: Gate)?

    /// One completed rename, as root-relative paths.
    struct Move: Equatable {
        let from: String
        let to: String
    }

    private let lock = NSLock()
    private var readPathsStorage: [String] = []
    private var stampPathsStorage: [String] = []
    private var writtenPathsStorage: [String] = []
    private var removedPathsStorage: [String] = []
    private var movesStorage: [Move] = []

    /// The root-relative paths whose contents were read, in call order.
    var readPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return readPathsStorage
    }

    /// The root-relative paths written to, in call order — how a reader-only
    /// model proves it is one.
    var writtenPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return writtenPathsStorage
    }

    /// The root-relative paths whose stamp was asked for, in call order.
    var stampPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stampPathsStorage
    }

    /// The root-relative paths deleted, in call order — how "the staging tree was
    /// removed and nothing else was" is asserted.
    var removedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return removedPathsStorage
    }

    /// The renames that succeeded, in call order — how "the version directory
    /// came into existence in **one** `move`" (D13) is asserted as a count
    /// rather than inferred from the tree that resulted.
    var moves: [Move] {
        lock.lock()
        defer { lock.unlock() }
        return movesStorage
    }

    init(root: URL, files: [String: String]) {
        self.root = root
        self.files = files
    }

    /// The absolute URL of a root-relative path in this tree.
    func url(_ path: String) -> URL {
        root.appendingPathComponent(path)
    }

    /// The key this tree stores `url` under — the inverse of `url(_:)`, which the
    /// scripted seams need to record something about a file they just wrote (the
    /// executable bit) without knowing how the tree spells paths.
    func relativePath(of url: URL) -> String {
        relative(url)
    }

    enum StubError: Error, LocalizedError {
        case missing
        case denied

        var errorDescription: String? {
            switch self {
            case .missing: return "No such file."
            case .denied: return "Permission denied."
            }
        }
    }

    func read(url: URL) throws -> String {
        let path = relative(url)
        if let readGate, readGate.path == path {
            self.readGate = nil
            readGate.gate.wait()
        }
        guard !unreadableFiles.contains(path) else { throw StubError.denied }
        guard let contents = files[path] else { throw StubError.missing }
        lock.lock()
        readPathsStorage.append(path)
        lock.unlock()
        return contents
    }

    func write(_ text: String, to url: URL) throws {
        let path = relative(url)
        onWrite?(path)
        guard !writeFailures.contains(path) else { throw StubError.denied }
        files[path] = text
        lock.lock()
        writtenPathsStorage.append(path)
        lock.unlock()
    }

    func readTextIfNotBinary(url: URL, maxBytes: Int) throws -> String? {
        guard !skippedFiles.contains(relative(url)) else { return nil }
        let text = try read(url: url)
        return text.utf8.count <= maxBytes ? text : nil
    }

    func contentsOfDirectory(at url: URL) throws -> [DirectoryEntry] {
        if let listingGate {
            self.listingGate = nil
            listingGate.wait()
        }
        let relativePath = relative(url)
        guard !unreadableDirectories.contains(relativePath) else { throw StubError.missing }
        let prefix = relativePath.isEmpty ? [] : relativePath.split(separator: "/").map(String.init)

        var names: [String: Bool] = [:]
        for path in files.keys {
            let components = path.split(separator: "/").map(String.init)
            guard components.count > prefix.count,
                  Array(components.prefix(prefix.count)) == prefix
            else { continue }
            let name = components[prefix.count]
            let isDirectory = components.count > prefix.count + 1
            names[name] = (names[name] ?? false) || isDirectory
        }
        // The explicitly created directories, including the ones that hold no
        // file — a version directory whose contents are all deeper, an empty
        // staging tree.
        for path in directories {
            let components = path.split(separator: "/").map(String.init)
            guard components.count > prefix.count,
                  Array(components.prefix(prefix.count)) == prefix
            else { continue }
            names[components[prefix.count]] = true
        }
        let listedURL = listingSpelling?(url) ?? url
        return names
            .map { DirectoryEntry(url: listedURL.appendingPathComponent($0.key), isDirectory: $0.value) }
            .sorted { lhs, rhs in
                lhs.isDirectory != rhs.isDirectory
                    ? lhs.isDirectory
                    : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func symbolicLinkDestination(at url: URL) -> String? {
        symlinks.contains(relative(url)) ? "elsewhere" : nil
    }

    /// Executable only when a test said so *and* something is really there — the
    /// real `FileService` answers `false` for a missing file, and a stub that said
    /// `true` for a path nobody wrote would make the engine's gate untestable in
    /// the direction that matters.
    func isExecutableFile(at url: URL) -> Bool {
        let path = relative(url)
        return files[path] != nil && executableFiles.contains(path)
    }

    // MARK: - Mutating the tree
    //
    // Enough of a file system for the install engine's atomicity rules to mean
    // something: a directory can exist while empty, a rename moves a whole
    // subtree in one step, a delete takes the subtree with it, and none of them
    // clobbers or reaches outside the root. Everything is compared by
    // root-relative path — there is no inode, no case folding and no symlink
    // resolution, none of which the engine depends on.

    func createDirectory(at url: URL) throws {
        guard let path = relativeIfInside(url), !path.isEmpty else { throw StubError.missing }
        guard !exists(path) else { throw FileServiceError.alreadyExists }
        let parent = parentPath(path)
        guard parent.isEmpty || hasDirectory(parent) else { throw StubError.missing }
        directories.insert(path)
    }

    func ensureDirectory(at url: URL) throws {
        guard var path = relativeIfInside(url) else { throw StubError.missing }
        while !path.isEmpty {
            guard files[path] == nil else {
                throw FileServiceError.notADirectory(name: path.split(separator: "/").last.map(String.init) ?? path)
            }
            directories.insert(path)
            path = parentPath(path)
        }
    }

    func move(from source: URL, to destination: URL) throws {
        guard let from = relativeIfInside(source), !from.isEmpty,
              let to = relativeIfInside(destination), !to.isEmpty
        else { throw StubError.missing }
        guard !moveFailures.contains(to) else { throw StubError.denied }
        guard exists(from) else { throw StubError.missing }
        guard !exists(to) else { throw FileServiceError.alreadyExists }
        let parent = parentPath(to)
        guard parent.isEmpty || hasDirectory(parent) else { throw StubError.missing }

        let prefix = from + "/"
        for key in files.keys where key == from || key.hasPrefix(prefix) {
            files[to + key.dropFirst(from.count)] = files.removeValue(forKey: key)
        }
        for directory in directories where directory == from || directory.hasPrefix(prefix) {
            directories.remove(directory)
            directories.insert(to + directory.dropFirst(from.count))
        }
        // The mode travels with the file, as a rename does on a real volume —
        // otherwise a binary unpacked into staging would arrive at its version
        // directory unexecutable, which is a property of this stub and of nothing
        // else.
        for executable in executableFiles where executable == from || executable.hasPrefix(prefix) {
            executableFiles.remove(executable)
            executableFiles.insert(to + executable.dropFirst(from.count))
        }
        lock.lock()
        movesStorage.append(Move(from: from, to: to))
        lock.unlock()
    }

    func removeItem(at url: URL) throws {
        guard let path = relativeIfInside(url), !path.isEmpty else { throw StubError.missing }
        onRemove?(path)
        guard !removeFailures.contains(path) else { throw StubError.denied }
        guard exists(path) else { throw StubError.missing }
        let prefix = path + "/"
        for key in files.keys where key == path || key.hasPrefix(prefix) {
            files[key] = nil
        }
        for directory in directories where directory == path || directory.hasPrefix(prefix) {
            directories.remove(directory)
        }
        for executable in executableFiles where executable == path || executable.hasPrefix(prefix) {
            executableFiles.remove(executable)
        }
        lock.lock()
        removedPathsStorage.append(path)
        lock.unlock()
    }

    /// Whether anything at all occupies this root-relative path.
    func exists(_ path: String) -> Bool {
        files[path] != nil || hasDirectory(path)
    }

    /// Whether `path` is a directory — recorded as one, or implied by something
    /// living under it.
    func hasDirectory(_ path: String) -> Bool {
        guard !path.isEmpty else { return true }
        if directories.contains(path) { return true }
        let prefix = path + "/"
        return files.keys.contains { $0.hasPrefix(prefix) } || directories.contains { $0.hasPrefix(prefix) }
    }

    /// The root-relative paths of every file under `path`, sorted — what "left
    /// byte-for-byte" is asserted against.
    func filePaths(under path: String) -> [String] {
        let prefix = path.isEmpty ? "" : path + "/"
        return files.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    private func parentPath(_ path: String) -> String {
        var components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return "" }
        components.removeLast()
        return components.joined(separator: "/")
    }

    /// Size-derived by default, so "the file changed" and "the stamp changed"
    /// mean the same thing in a test without a real clock.
    func fileStamp(at url: URL) -> FileStamp? {
        let path = relative(url)
        lock.lock()
        stampPathsStorage.append(path)
        lock.unlock()
        guard !stampsAreUnavailable else { return nil }
        if let override = stampOverrides[path] { return override }
        guard let contents = files[path] else { return nil }
        return FileStamp(byteCount: contents.utf8.count, modificationDate: nil)
    }

    private func relative(_ url: URL) -> String {
        relativeIfInside(url) ?? ""
    }

    /// The root-relative path, or `nil` when `url` is not inside the tree at all.
    ///
    /// The distinction `relative(_:)` cannot make: it answers `""` both for the
    /// root itself and for something outside it, which is harmless for a read and
    /// catastrophic for a delete. Every mutating operation goes through this one.
    private func relativeIfInside(_ url: URL) -> String? {
        let path = url.standardizedFileURL.path
        if path == root.standardizedFileURL.path { return "" }
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard path.hasPrefix(base) else { return nil }
        return String(path.dropFirst(base.count))
    }
}
