#if os(iOS)
import Foundation
import PisakaCore

/// iOS security-scoped bookmark creation/resolution — the platform API kept out
/// of `PisakaCore` (which only stores/orders the opaque blobs via `BookmarkStore`).
///
/// On iOS a url handed back by `UIDocumentPickerViewController` is security-scoped:
/// you must `startAccessingSecurityScopedResource()` before touching it and stop
/// when done. To regain access in a later launch you persist a bookmark created
/// while access is held, then resolve it (which yields a fresh security-scoped
/// url to start accessing again). Unlike macOS, iOS bookmark creation/resolution
/// take no `.withSecurityScope` option — a plain `bookmarkData()` /
/// `URL(resolvingBookmarkData:…)` is already security-scoped.
enum SecurityScopedBookmarks {
    /// Create a persistable bookmark for `url`, bracketing the creation with a
    /// security-scope access grant. Returns `nil` if access can't be acquired or
    /// the bookmark can't be created.
    static func makeBookmark(for url: URL) -> Data? {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        return try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolve a persisted bookmark back to a security-scoped url, or `nil` if it
    /// can no longer be resolved (the folder moved/was deleted — the caller should
    /// `BookmarkStore.forgetFolder` it). `isStale` reports that the OS produced a
    /// usable url but the stored blob should be refreshed (the caller re-bookmarks).
    static func resolve(_ data: Data, isStale: inout Bool) -> URL? {
        var stale = false
        let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        isStale = stale
        return url
    }
}

/// Brackets a closure with the security-scoped access grant covering a target url.
///
/// `LibGit2Service` does filesystem access (open the repo, read/write the working
/// tree, mutate the index) directly via `FileManager`/libgit2 rather than through
/// `FileServicing`, so it cannot rely on `SecurityScopedFileService`'s per-op
/// bracketing. It instead takes a `SecurityScopeProviding` so every git operation
/// runs under the same grant — without it, on a real device the picked folder is
/// inaccessible outside an active scope and Local Changes / Log / revert / merge
/// staging would fail. `SecurityScopedFileService` is the concrete provider.
protocol SecurityScopeProviding: AnyObject {
    /// Run `body` with the registered scope covering `target` active (if any),
    /// stopping it afterward.
    func withSecurityScope<T>(covering target: URL, _ body: () throws -> T) throws -> T
}

/// A `FileServicing` decorator that brackets every read/write/list/create/move/
/// remove with the `startAccessingSecurityScopedResource` grant of whichever
/// registered scoped url (an opened folder root, or a standalone opened file)
/// covers the operation's target — so the underlying `FileService`
/// (`FileManager`) calls succeed on iOS, where bare access to a picked url is
/// denied outside an active scope. It also vends that same bracketing to
/// `LibGit2Service` (which bypasses `FileServicing`) via `SecurityScopeProviding`.
///
/// The "which scoped root covers this target" decision is the pure, tested
/// `ScopedFileAccess.path(_:isWithin:)` in Core; this view-layer wrapper only
/// owns the registry and the start/stop bracketing. An operation with no covering
/// registered scope falls through to the base service unbracketed (the simulator,
/// app-container paths, and the unit tests need no scope), so it never blocks a
/// legitimately-accessible path.
///
/// The registry is read from `LibGit2Service`'s serial git queue while it is
/// mutated on the main actor (folder open/close), so a lock guards `scopedURLs`;
/// the bracketing itself (`startAccessingSecurityScopedResource`) is process-wide.
final class SecurityScopedFileService: FileServicing, SecurityScopeProviding, @unchecked Sendable {
    private let base: FileServicing
    /// Registered security-scoped urls (opened folder roots / standalone files),
    /// most-recently-registered first so the narrowest/newest grant is tried first.
    private var scopedURLs: [URL] = []
    /// Guards `scopedURLs` against concurrent access from the main actor (register/
    /// unregister) and `LibGit2Service`'s serial queue (scope lookups).
    private let lock = NSLock()

    init(base: FileServicing = FileService()) {
        self.base = base
    }

    /// Register a security-scoped url (from the picker or a resolved bookmark) so
    /// operations on it and its descendants are bracketed by its access grant.
    func register(_ url: URL) {
        let standardized = url.standardizedFileURL
        lock.lock()
        defer { lock.unlock() }
        scopedURLs.removeAll { $0 == standardized }
        scopedURLs.insert(standardized, at: 0)
    }

    /// Drop a previously registered scoped url (e.g. when its folder/file closes).
    func unregister(_ url: URL) {
        let standardized = url.standardizedFileURL
        lock.lock()
        defer { lock.unlock() }
        scopedURLs.removeAll { $0 == standardized }
    }

    /// The registered scoped url that covers `target` (equal or an ancestor), or
    /// `nil` when none do.
    private func scope(covering target: URL) -> URL? {
        let targetPath = target.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        return scopedURLs.first { ScopedFileAccess.path(targetPath, isWithin: $0.path) }
    }

    /// Run `body` with the covering scope (if any) active, stopping it afterward.
    private func withScope<T>(_ target: URL, _ body: () throws -> T) rethrows -> T {
        guard let scoped = scope(covering: target) else { return try body() }
        let granted = scoped.startAccessingSecurityScopedResource()
        defer { if granted { scoped.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    // MARK: - SecurityScopeProviding

    func withSecurityScope<T>(covering target: URL, _ body: () throws -> T) throws -> T {
        try withScope(target, body)
    }

    func read(url: URL) throws -> String {
        try withScope(url) { try base.read(url: url) }
    }

    func write(_ text: String, to url: URL) throws {
        try withScope(url) { try base.write(text, to: url) }
    }

    func contentsOfDirectory(at url: URL) throws -> [DirectoryEntry] {
        try withScope(url) { try base.contentsOfDirectory(at: url) }
    }

    func createFile(at url: URL) throws {
        try withScope(url) { try base.createFile(at: url) }
    }

    func createDirectory(at url: URL) throws {
        try withScope(url) { try base.createDirectory(at: url) }
    }

    /// Forwarded (rather than inheriting the protocol extension's `.unsupported`
    /// default) so the whole chain is created under the covering scope's grant,
    /// like every other mutating method on this decorator.
    func ensureDirectory(at url: URL) throws {
        try withScope(url) { try base.ensureDirectory(at: url) }
    }

    func move(from source: URL, to destination: URL) throws {
        // Brackets the source's scope; a move within one opened folder keeps both
        // ends under the same registered root.
        try withScope(source) { try base.move(from: source, to: destination) }
    }

    func removeItem(at url: URL) throws {
        try withScope(url) { try base.removeItem(at: url) }
    }

    func symbolicLinkDestination(at url: URL) -> String? {
        withScope(url) { base.symbolicLinkDestination(at: url) }
    }

    /// Forwarded (rather than inheriting the protocol extension's `nil` default)
    /// so the size check in `readTextIfNotBinary` actually fires on iOS: `nil`
    /// means "unknown", and the default implementation then decodes the whole file
    /// into memory before measuring it — on a picked folder containing a large
    /// binary, exactly the read the cap exists to avoid.
    func fileByteCount(at url: URL) -> Int? {
        withScope(url) { base.fileByteCount(at: url) }
    }

    /// Forwarded for the same reason, and with the same stakes as
    /// `fileStamp(at:)`'s own note: `nil` reads as "this file always looks
    /// changed", so inheriting the default would make every symbol-index refresh
    /// on iOS re-read and re-parse the entire project.
    func fileStamp(at url: URL) -> FileStamp? {
        withScope(url) { base.fileStamp(at: url) }
    }
}
#endif
