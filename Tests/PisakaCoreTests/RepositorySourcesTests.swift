import XCTest

/// The shared reader's own contract: it serves what a direct read and a direct
/// strip would, it does each at most once per process — asserted by counting
/// the work, not by timing it — and it never caches a failure.
final class RepositorySourcesTests: XCTestCase {
    private static let sample = "Sources/PisakaCore/PisakaCore.swift"

    /// Compared against a direct read of the disk, not against the cache's own
    /// raw text, so a stale or mis-keyed entry cannot agree with itself.
    func testStrippedIsTheStripperOverTheFileOnDisk() throws {
        let onDisk = try String(contentsOf: RepositorySources.url(Self.sample), encoding: .utf8)
        XCTAssertEqual(
            try RepositorySources.stripped(at: Self.sample),
            LSPSourceGatingTests.strippingCommentsAndStringLiterals(onDisk)
        )
    }

    func testRawIsTheFileOnDisk() throws {
        let url = RepositorySources.url(Self.sample)
        XCTAssertEqual(try RepositorySources.raw(at: Self.sample), try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(try RepositorySources.raw(url), try String(contentsOf: url, encoding: .utf8))
    }

    /// The file is written fresh under a name nothing else in the process can
    /// ask for, so every one of the 64 workers races for an empty entry — a
    /// repository file would already be cached by the sweeps that run earlier in
    /// a full run, and the counts would be one whatever the lock covered.
    func testConcurrentAsksReadAndStripOnce() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositorySourcesTests-\(UUID().uuidString).swift")
        try "let a = 1 // trailing\nlet s = \"literal\"\n".write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let key = RepositorySources.key(of: url)
        XCTAssertEqual(RepositorySources.readCount(of: key), 0)

        let results = Results(count: 64)
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            results.set(index, try? RepositorySources.stripped(url))
        }
        let all = results.values
        XCTAssertEqual(all.count, 64)
        let first = try XCTUnwrap(all.first ?? nil, "the stripped text could not be read")
        XCTAssertEqual(first, "let a = 1 \nlet s = \n")
        XCTAssertTrue(all.allSatisfy { $0 == first }, "concurrent asks must all see the same text")
        XCTAssertEqual(RepositorySources.readCount(of: key), 1)
        XCTAssertEqual(RepositorySources.stripCount(of: key), 1)
    }

    /// Two spellings of one file — a `..` detour and the plain relative path —
    /// meet in one entry, so the file is read once.
    func testEverySpellingOfAFileSharesOneEntry() throws {
        let plain = "Sources/PisakaCore/FileName.swift"
        let detour = RepositorySources.root
            .appendingPathComponent("Sources/PisakaCore/../PisakaCore/FileName.swift")
        XCTAssertEqual(RepositorySources.key(of: detour), plain)
        XCTAssertEqual(try RepositorySources.raw(detour), try RepositorySources.raw(at: plain))
        XCTAssertEqual(RepositorySources.readCount(of: plain), 1)
    }

    func testSwiftFilesWalkIsSortedSwiftOnlyAndStable() throws {
        let files = try XCTUnwrap(RepositorySources.swiftFiles(under: "Sources"), "cannot enumerate Sources/")
        XCTAssertFalse(files.isEmpty, "found no Swift sources under Sources/")
        XCTAssertEqual(files.map(\.path), files.map(\.path).sorted())
        XCTAssertTrue(files.allSatisfy { $0.pathExtension == "swift" })
        XCTAssertEqual(RepositorySources.swiftFiles(under: "Sources"), files)
        XCTAssertTrue(
            files.contains { RepositorySources.key(of: $0) == Self.sample },
            "a walked URL must key to the same entry as its spelled relative path"
        )
    }

    func testMissingFileThrowsEveryTime() {
        let missing = "Sources/PisakaCore/DoesNotExist-\(UUID().uuidString).swift"
        XCTAssertThrowsError(try RepositorySources.raw(at: missing))
        XCTAssertThrowsError(try RepositorySources.raw(at: missing))
        XCTAssertEqual(RepositorySources.readCount(of: missing), 2, "a failed read must not be cached")
    }

    func testMissingFileStrippedThrowsEveryTimeAndIsNeverStripped() {
        let missing = "Sources/PisakaCore/DoesNotExist-\(UUID().uuidString).swift"
        XCTAssertThrowsError(try RepositorySources.stripped(at: missing))
        XCTAssertThrowsError(try RepositorySources.stripped(at: missing))
        XCTAssertEqual(RepositorySources.readCount(of: missing), 2, "a failed read must not be cached")
        XCTAssertEqual(RepositorySources.stripCount(of: missing), 0)
    }

    /// `FileManager`'s enumerator answers an empty walk for a directory that
    /// does not exist; the reader must answer `nil` instead, and every time.
    func testMissingDirectoryWalkIsNilEveryTime() {
        let missing = "Sources/DoesNotExist-\(UUID().uuidString)"
        XCTAssertNil(RepositorySources.swiftFiles(under: missing))
        XCTAssertNil(RepositorySources.swiftFiles(under: missing))
    }

    func testURLResolvesUnderTheRoot() {
        let package = RepositorySources.url("Package.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
        XCTAssertEqual(RepositorySources.key(of: package), "Package.swift")
    }

    /// The concurrent test's sink: one lock, so the 64 workers never share an
    /// unguarded array.
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String?]

        init(count: Int) {
            storage = Array(repeating: nil, count: count)
        }

        func set(_ index: Int, _ value: String?) {
            lock.lock()
            defer { lock.unlock() }
            storage[index] = value
        }

        var values: [String?] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}
