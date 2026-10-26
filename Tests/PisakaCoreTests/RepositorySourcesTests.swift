import XCTest

/// The shared reader's own contract: it serves what a direct read and a direct
/// strip would, it does each at most once per process — asserted by counting
/// the work, not by timing it — and it never caches a failure.
final class RepositorySourcesTests: XCTestCase {
    private static let sample = "Sources/PisakaCore/PisakaCore.swift"

    func testStrippedIsTheStripperOverTheRawText() throws {
        let raw = try RepositorySources.raw(at: Self.sample)
        XCTAssertEqual(
            try RepositorySources.stripped(at: Self.sample),
            LSPSourceGatingTests.strippingCommentsAndStringLiterals(raw)
        )
    }

    func testRawIsTheFileOnDisk() throws {
        let url = RepositorySources.url(Self.sample)
        XCTAssertEqual(try RepositorySources.raw(at: Self.sample), try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(try RepositorySources.raw(url), try String(contentsOf: url, encoding: .utf8))
    }

    /// Whatever earlier tests in this process asked for, the counts can only be
    /// exactly one afterwards: "at most once" is the property, and the asks
    /// here guarantee "at least once".
    func testConcurrentAsksReadAndStripOnce() throws {
        let key = "Sources/PisakaCore/WorkspaceModel.swift"
        let results = Results(count: 64)
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            results.set(index, try? RepositorySources.stripped(at: key))
        }
        let all = results.values
        XCTAssertEqual(all.count, 64)
        let first = try XCTUnwrap(all.first ?? nil, "the stripped text could not be read")
        XCTAssertTrue(all.allSatisfy { $0 == first }, "concurrent asks must all see the same text")
        XCTAssertEqual(RepositorySources.readCount(of: key), 1)
        XCTAssertEqual(RepositorySources.stripCount(of: key), 1)
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
