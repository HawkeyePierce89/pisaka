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
    /// Root-relative paths reported as symbolic links.
    var symlinks: Set<String> = []
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
    /// Held on the *first* directory listing, if set.
    var listingGate: Gate?
    /// Held on the read of this exact root-relative path, once.
    var readGate: (path: String, gate: Gate)?

    private let lock = NSLock()
    private var readPathsStorage: [String] = []
    private var stampPathsStorage: [String] = []
    private var writtenPathsStorage: [String] = []

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

    init(root: URL, files: [String: String]) {
        self.root = root
        self.files = files
    }

    /// The absolute URL of a root-relative path in this tree.
    func url(_ path: String) -> URL {
        root.appendingPathComponent(path)
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
        return names
            .map { DirectoryEntry(url: url.appendingPathComponent($0.key), isDirectory: $0.value) }
            .sorted { lhs, rhs in
                lhs.isDirectory != rhs.isDirectory
                    ? lhs.isDirectory
                    : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func symbolicLinkDestination(at url: URL) -> String? {
        symlinks.contains(relative(url)) ? "elsewhere" : nil
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
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(base) else { return "" }
        return String(url.path.dropFirst(base.count))
    }
}
