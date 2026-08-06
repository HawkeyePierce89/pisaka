import XCTest
@testable import PisakaCore

final class ScopedFileAccessTests: XCTestCase {
    // MARK: - updatedRecents

    private func bookmark(_ path: String, _ marker: UInt8 = 0) -> FolderBookmark {
        FolderBookmark(path: path, bookmark: Data([marker]))
    }

    func testRememberingIntoEmptyListPutsItFirst() {
        let result = ScopedFileAccess.updatedRecents([], remembering: bookmark("/a"))
        XCTAssertEqual(result.map(\.path), ["/a"])
    }

    func testNewMostRecentGoesToFront() {
        let existing = [bookmark("/a"), bookmark("/b")]
        let result = ScopedFileAccess.updatedRecents(existing, remembering: bookmark("/c"))
        XCTAssertEqual(result.map(\.path), ["/c", "/a", "/b"])
    }

    func testReopeningExistingFolderMovesItToFrontWithoutDuplicating() {
        let existing = [bookmark("/a"), bookmark("/b"), bookmark("/c")]
        let result = ScopedFileAccess.updatedRecents(existing, remembering: bookmark("/b"))
        XCTAssertEqual(result.map(\.path), ["/b", "/a", "/c"])
    }

    func testReopeningRefreshesBookmarkBlob() {
        let existing = [bookmark("/a", 1)]
        let result = ScopedFileAccess.updatedRecents(existing, remembering: bookmark("/a", 99))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.bookmark, Data([99]))
    }

    func testCapDropsOldestBeyondMax() {
        let existing = (0..<5).map { bookmark("/old\($0)") }
        let result = ScopedFileAccess.updatedRecents(existing, remembering: bookmark("/new"), max: 3)
        XCTAssertEqual(result.map(\.path), ["/new", "/old0", "/old1"])
    }

    func testDefaultMaxIsTwenty() {
        XCTAssertEqual(ScopedFileAccess.maxRecentFolders, 20)
        let existing = (0..<20).map { bookmark("/f\($0)") }
        let result = ScopedFileAccess.updatedRecents(existing, remembering: bookmark("/new"))
        XCTAssertEqual(result.count, 20)
        XCTAssertEqual(result.first?.path, "/new")
        XCTAssertFalse(result.contains { $0.path == "/f19" })
    }

    func testCapOfZeroYieldsEmpty() {
        let result = ScopedFileAccess.updatedRecents([bookmark("/a")], remembering: bookmark("/b"), max: 0)
        XCTAssertTrue(result.isEmpty)
    }

    func testNegativeMaxDisablesCap() {
        // A negative max is the "no cap" contract — the whole list survives.
        let existing = (0..<30).map { bookmark("/f\($0)") }
        let result = ScopedFileAccess.updatedRecents(existing, remembering: bookmark("/new"), max: -1)
        XCTAssertEqual(result.count, 31)
        XCTAssertEqual(result.first?.path, "/new")
    }

    // MARK: - path(_:isWithin:)

    func testPathEqualIsWithin() {
        XCTAssertTrue(ScopedFileAccess.path("/a/b", isWithin: "/a/b"))
    }

    func testDescendantIsWithin() {
        XCTAssertTrue(ScopedFileAccess.path("/a/b/c.txt", isWithin: "/a/b"))
        XCTAssertTrue(ScopedFileAccess.path("/a/b/c/d.txt", isWithin: "/a/b"))
    }

    func testSiblingPrefixIsNotWithin() {
        // "/a/bc" must not be considered inside "/a/b".
        XCTAssertFalse(ScopedFileAccess.path("/a/bc", isWithin: "/a/b"))
    }

    func testUnrelatedIsNotWithin() {
        XCTAssertFalse(ScopedFileAccess.path("/x/y", isWithin: "/a/b"))
    }

    func testTrailingSlashesNormalized() {
        XCTAssertTrue(ScopedFileAccess.path("/a/b/", isWithin: "/a/b"))
        XCTAssertTrue(ScopedFileAccess.path("/a/b", isWithin: "/a/b/"))
        XCTAssertTrue(ScopedFileAccess.path("/a/b/c.txt", isWithin: "/a/b/"))
    }

    /// Exercises the multi-trailing-slash collapse loop (vs the single-slash cases
    /// above), so a regression in the `while p.count > 1 && p.hasSuffix("/")` guard
    /// would be caught.
    func testMultipleTrailingSlashesCollapse() {
        XCTAssertTrue(ScopedFileAccess.path("/a/b/c", isWithin: "/a/b//"))
        XCTAssertTrue(ScopedFileAccess.path("/a/b//", isWithin: "/a/b"))
        XCTAssertTrue(ScopedFileAccess.path("/a/b///", isWithin: "/a/b/"))
    }

    func testEmptyRootScopesNothing() {
        // An empty root must not match every absolute path (a malformed/unresolved
        // bookmark would otherwise silently widen scope).
        XCTAssertFalse(ScopedFileAccess.path("/a/b", isWithin: ""))
        XCTAssertFalse(ScopedFileAccess.path("/", isWithin: ""))
    }

    func testFilesystemRootContainsEverything() {
        XCTAssertTrue(ScopedFileAccess.path("/a/b", isWithin: "/"))
        XCTAssertTrue(ScopedFileAccess.path("/", isWithin: "/"))
    }

    func testParentIsNotWithinChild() {
        XCTAssertFalse(ScopedFileAccess.path("/a", isWithin: "/a/b"))
    }

    func testRelativeTargetIsNotWithinRoot() {
        // A non-absolute target against the filesystem root is rejected.
        XCTAssertFalse(ScopedFileAccess.path("relative/x", isWithin: "/"))
    }
}

final class BookmarkStoreTests: XCTestCase {
    /// A fresh, isolated `UserDefaults` suite per test (the `SettingsStoreTests`
    /// precedent).
    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "BookmarkStoreTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testEmptyOnFreshStore() {
        let store = BookmarkStore(defaults: makeDefaults())
        XCTAssertTrue(store.folders().isEmpty)
        XCTAssertNil(store.bookmark(forPath: "/anything"))
    }

    func testRememberAndReadBack() {
        let store = BookmarkStore(defaults: makeDefaults())
        store.rememberFolder(bookmark: Data([1, 2, 3]), path: "/proj")
        XCTAssertEqual(store.folders().map(\.path), ["/proj"])
        XCTAssertEqual(store.bookmark(forPath: "/proj"), Data([1, 2, 3]))
    }

    func testRememberOrdersMostRecentFirst() {
        let store = BookmarkStore(defaults: makeDefaults())
        store.rememberFolder(bookmark: Data([1]), path: "/a")
        store.rememberFolder(bookmark: Data([2]), path: "/b")
        XCTAssertEqual(store.folders().map(\.path), ["/b", "/a"])
    }

    func testRememberRefreshesExisting() {
        let store = BookmarkStore(defaults: makeDefaults())
        store.rememberFolder(bookmark: Data([1]), path: "/a")
        store.rememberFolder(bookmark: Data([9]), path: "/a")
        XCTAssertEqual(store.folders().count, 1)
        XCTAssertEqual(store.bookmark(forPath: "/a"), Data([9]))
    }

    func testForgetRemoves() {
        let store = BookmarkStore(defaults: makeDefaults())
        store.rememberFolder(bookmark: Data([1]), path: "/a")
        store.rememberFolder(bookmark: Data([2]), path: "/b")
        store.forgetFolder(path: "/a")
        XCTAssertEqual(store.folders().map(\.path), ["/b"])
        XCTAssertNil(store.bookmark(forPath: "/a"))
    }

    func testForgetMissingPathIsNoOp() {
        let store = BookmarkStore(defaults: makeDefaults())
        store.rememberFolder(bookmark: Data([1]), path: "/a")
        store.forgetFolder(path: "/missing")
        XCTAssertEqual(store.folders().map(\.path), ["/a"])
    }

    func testCorruptBlobDecodesToEmpty() {
        let defaults = makeDefaults()
        // A garbage (non-property-list) blob under the recents key must not crash
        // or surface stale state — it decodes to an empty list.
        defaults.set(Data([0xFF, 0x00, 0x12]), forKey: BookmarkStore.Keys.recentFolders)
        let store = BookmarkStore(defaults: defaults)
        XCTAssertTrue(store.folders().isEmpty)
        XCTAssertNil(store.bookmark(forPath: "/anything"))
    }

    func testPersistenceRoundTripAcrossInstances() {
        let defaults = makeDefaults()
        let first = BookmarkStore(defaults: defaults)
        first.rememberFolder(bookmark: Data([7, 7]), path: "/proj")

        let second = BookmarkStore(defaults: defaults)
        XCTAssertEqual(second.folders().map(\.path), ["/proj"])
        XCTAssertEqual(second.bookmark(forPath: "/proj"), Data([7, 7]))
    }
}
