import Foundation

/// The one reader every source-gating suite gets a repository file's text from:
/// read once, stripped once, walked once, per test process.
///
/// **What is memoized.** Three things, each computed at most once per process:
/// the walk of a source directory (`swiftFiles(under:)`), a file's raw text
/// (`raw(_:)`), and that text after
/// `LSPSourceGatingTests.strippingCommentsAndStringLiterals(_:)` (`stripped(_:)`).
/// Before this existed, every suite walked `Sources/` for itself and every test
/// re-read and re-stripped the same files; the stripper alone was reached from
/// close to a hundred sites in one suite, which is where most of the Core gate's
/// time went.
///
/// **The key** is the repository-relative path (`Sources/Pisaka/TabStripView.swift`):
/// a URL becomes its key by removing the root's standardized path as a prefix,
/// so the URL a walk hands back and the one a suite spells by hand meet in the
/// same entry. A path outside the root falls back to its absolute standardized
/// path. Walks are keyed by the relative directory they were asked for.
///
/// **One `NSLock`, held across the compute.** The dictionaries live in one
/// private class behind one lock, and the lock is held for the read and the
/// strip themselves rather than only for the lookup, so two threads asking for
/// the same key concurrently cannot both compute it — "at most once per process"
/// is the property, and `readCount(of:)` / `stripCount(of:)` exist so a test can
/// assert it by counting work rather than timing it. It is also the answer to the
/// warning in `CLAUDE.md`'s Tests section: two threads in one `Dictionary` is a
/// corrupted hash table, not a flaky assertion, so no mutable dictionary here is
/// ever reached without the lock. The internal helpers run with the lock already
/// held, and nothing takes it twice.
///
/// **Failures are not memoized.** A read that throws rethrows the same
/// `String(contentsOf:encoding: .utf8)` error on every call, and a walk whose
/// enumerator cannot be created answers `nil` every time, so a test that fails
/// on a missing file fails exactly as it did when it read the file itself. Each
/// caller keeps its own `XCTUnwrap` / `guard` message and its own "found no Swift
/// sources" assertion; this type asserts nothing.
///
/// **Per process, never on disk.** The memo is static storage and dies with the
/// process. Nothing is written anywhere, so no stale entry can outlive an edit.
///
/// **Two modes, and stripped is the default.** `stripped(_:)` is what a rule
/// about code reads — the class's first convention: match against comment- and
/// literal-stripped text, because these files quote their own settings in
/// comments. `raw(_:)` is only for a reading whose subject *is* a literal, and
/// such a reading keeps stating its reason at its own site, exactly as before.
///
/// **The comment-only scanner is not a mode.**
/// `GitHubSourceGatingTests.strippingComments(_:)` keeps string literals, and
/// its callers apply it themselves over `raw(_:)`. That is deliberate:
/// `ChromeThemeSourceGatingTests.testTheHeaderNamesEveryLiteralKeepingReading`
/// finds the literal-keeping readings *by the call's spelling* inside each test
/// body, so a reader mode would hide them from the inventory it holds equal to
/// that suite's stated exceptions.
enum RepositorySources {
    /// The repository root, derived from this file's own `#filePath`.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>
        .standardizedFileURL

    /// The URL of a repository-relative path.
    static func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    /// Every `.swift` file under `relativeDirectory`, at any depth, sorted by
    /// path; `nil` when the directory cannot be enumerated (not cached).
    static func swiftFiles(under relativeDirectory: String = "Sources") -> [URL]? {
        memo.withLock { $0.swiftFiles(under: relativeDirectory) }
    }

    /// A file's text, read at most once per process.
    static func raw(_ url: URL) throws -> String {
        try memo.withLock { try $0.raw(url) }
    }

    static func raw(at relativePath: String) throws -> String {
        try raw(url(relativePath))
    }

    /// A file's text with comments and string literals stripped, computed at
    /// most once per process.
    static func stripped(_ url: URL) throws -> String {
        try memo.withLock { try $0.stripped(url) }
    }

    static func stripped(at relativePath: String) throws -> String {
        try stripped(url(relativePath))
    }

    /// How many times the file behind `relativePath` was read from disk,
    /// failed attempts included.
    static func readCount(of relativePath: String) -> Int {
        memo.withLock { $0.reads[relativePath, default: 0] }
    }

    /// How many times the file behind `relativePath` was run through the stripper.
    static func stripCount(of relativePath: String) -> Int {
        memo.withLock { $0.strips[relativePath, default: 0] }
    }

    /// The memo key of a URL: repository-relative when under the root, absolute
    /// otherwise.
    static func key(of url: URL) -> String {
        let path = url.standardizedFileURL.path
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private static let memo = Memo()

    /// The dictionaries, reachable only through `withLock`.
    private final class Memo {
        private let lock = NSLock()
        private var walks: [String: [URL]] = [:]
        private var rawTexts: [String: String] = [:]
        private var strippedTexts: [String: String] = [:]
        private(set) var reads: [String: Int] = [:]
        private(set) var strips: [String: Int] = [:]

        func withLock<T>(_ body: (Memo) throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body(self)
        }

        // Everything below runs with the lock held.

        func swiftFiles(under relativeDirectory: String) -> [URL]? {
            if let cached = walks[relativeDirectory] { return cached }
            guard let enumerator = FileManager.default.enumerator(
                at: RepositorySources.url(relativeDirectory),
                includingPropertiesForKeys: nil
            ) else { return nil }
            let files = enumerator
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" }
                .sorted { $0.path < $1.path }
            walks[relativeDirectory] = files
            return files
        }

        func raw(_ url: URL) throws -> String {
            let key = RepositorySources.key(of: url)
            if let cached = rawTexts[key] { return cached }
            reads[key, default: 0] += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            rawTexts[key] = text
            return text
        }

        func stripped(_ url: URL) throws -> String {
            let key = RepositorySources.key(of: url)
            if let cached = strippedTexts[key] { return cached }
            let text = try raw(url)
            strips[key, default: 0] += 1
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(text)
            strippedTexts[key] = code
            return code
        }
    }
}
