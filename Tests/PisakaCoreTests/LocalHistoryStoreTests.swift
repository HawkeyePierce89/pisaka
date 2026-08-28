import XCTest
@testable import PisakaCore

/// The store is where the layout's name grammar and the policy's two rules meet
/// a file system, so what is asserted here is mostly *shape of disk traffic*
/// rather than return values: how many writes a dedup costs (none), how many
/// renames a capture costs (one), what an injected failure leaves behind
/// (nothing), and what pruning is allowed to touch (only what this feature
/// wrote).
///
/// Everything runs against `StubFileTree`, whose root stands in for the store's
/// own base directory — the project root is an ordinary path outside it, because
/// the store never reads a project file: it is handed text by its callers and
/// only ever touches its own area.
final class LocalHistoryStoreTests: XCTestCase {
    private let storeRoot = URL(fileURLWithPath: "/store")
    private let projectRoot = URL(fileURLWithPath: "/Users/someone/project")
    private let path = "Sources/App/main.swift"

    private var layout: LocalHistoryLayout {
        LocalHistoryLayout(base: storeRoot.appendingPathComponent("LocalHistory"))
    }

    private func makeTree() -> StubFileTree {
        StubFileTree(root: storeRoot, files: [:])
    }

    private func makeStore(_ tree: StubFileTree, policy: LocalHistoryPolicy = LocalHistoryPolicy()) -> LocalHistoryStore {
        LocalHistoryStore(layout: layout, fileService: tree, policy: policy)
    }

    /// The tree-relative path of one file's snapshot directory.
    private func fileDirectory(_ relativePath: String, in tree: StubFileTree) -> String {
        tree.relativePath(of: layout.fileDirectory(forRoot: projectRoot, relativePath: relativePath))
    }

    private func projectDirectory(in tree: StubFileTree) -> String {
        tree.relativePath(of: layout.projectDirectory(forRoot: projectRoot))
    }

    private func date(_ seconds: Double) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    // MARK: - Capture and listing

    func testACapturedRevisionIsListedAndReadBack() throws {
        let tree = makeTree()
        let store = makeStore(tree)
        let now = date(1_772_345_678.901)

        let snapshot = try XCTUnwrap(
            store.capture(text: "hello", root: projectRoot, relativePath: path, event: .save, now: now)
        )
        XCTAssertEqual(snapshot.event, .save)
        XCTAssertEqual(snapshot.contentHash, LocalHistoryLayout.contentHash(of: "hello"))
        XCTAssertEqual(snapshot.timestamp, now)

        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path), [snapshot])
        XCTAssertEqual(store.content(of: snapshot, root: projectRoot, relativePath: path), "hello")
    }

    func testRevisionsAreListedNewestFirstAcrossEvents() throws {
        let tree = makeTree()
        let store = makeStore(tree)
        store.capture(text: "one", root: projectRoot, relativePath: path, event: .save, now: date(1_000))
        store.capture(text: "two", root: projectRoot, relativePath: path, event: .commit, now: date(2_000))
        store.capture(text: "three", root: projectRoot, relativePath: path, event: .branch, now: date(3_000))

        let listed = store.revisions(root: projectRoot, relativePath: path)
        XCTAssertEqual(listed.map(\.event), [.branch, .commit, .save])
        XCTAssertEqual(listed.map(\.timestamp), [date(3_000), date(2_000), date(1_000)])
        XCTAssertEqual(
            listed.compactMap { store.content(of: $0, root: projectRoot, relativePath: path) },
            ["three", "two", "one"]
        )
    }

    func testListingAFileThatWasNeverCapturedIsEmptyAndReadsNothing() {
        let tree = makeTree()
        let store = makeStore(tree)

        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path), [])
        XCTAssertEqual(tree.readPaths, [])
    }

    func testASecondIdenticalCaptureWritesNothing() {
        let tree = makeTree()
        let store = makeStore(tree)
        store.capture(text: "same", root: projectRoot, relativePath: path, event: .save, now: date(1_000))
        let writesAfterFirst = tree.writtenPaths

        XCTAssertNil(store.capture(text: "same", root: projectRoot, relativePath: path, event: .save, now: date(2_000)))
        XCTAssertEqual(tree.writtenPaths, writesAfterFirst)
        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path).count, 1)
        // Dedup is a *name* comparison: nothing in the store's directory was read.
        XCTAssertEqual(tree.readPaths, [])
    }

    func testAChangedCaptureWritesOneMoreFile() throws {
        let tree = makeTree()
        let store = makeStore(tree)
        store.capture(text: "before", root: projectRoot, relativePath: path, event: .save, now: date(1_000))
        let after = try XCTUnwrap(
            store.capture(text: "after", root: projectRoot, relativePath: path, event: .save, now: date(2_000))
        )

        XCTAssertEqual(tree.writtenPaths.count, 2)
        XCTAssertEqual(tree.moves.count, 2)
        let listed = store.revisions(root: projectRoot, relativePath: path)
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(listed.first, after)
    }

    func testOneChangedByteIsANewRevision() {
        let tree = makeTree()
        let store = makeStore(tree)
        store.capture(text: "let a = 1", root: projectRoot, relativePath: path, event: .save, now: date(1_000))
        store.capture(text: "let a = 2", root: projectRoot, relativePath: path, event: .save, now: date(2_000))

        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path).count, 2)
    }

    func testTwoFilesKeepSeparateHistories() {
        let tree = makeTree()
        let store = makeStore(tree)
        store.capture(text: "a", root: projectRoot, relativePath: "a.swift", event: .save, now: date(1_000))
        store.capture(text: "b", root: projectRoot, relativePath: "b.swift", event: .save, now: date(1_000))

        XCTAssertEqual(
            store.revisions(root: projectRoot, relativePath: "a.swift").compactMap {
                store.content(of: $0, root: projectRoot, relativePath: "a.swift")
            },
            ["a"]
        )
        XCTAssertEqual(
            store.revisions(root: projectRoot, relativePath: "b.swift").compactMap {
                store.content(of: $0, root: projectRoot, relativePath: "b.swift")
            },
            ["b"]
        )
    }

    // MARK: - Atomicity

    func testCaptureWritesThroughATemporaryNameAndExactlyOneMove() throws {
        let tree = makeTree()
        let store = makeStore(tree)
        let directory = fileDirectory(path, in: tree)

        let snapshot = try XCTUnwrap(
            store.capture(text: "hello", root: projectRoot, relativePath: path, event: .save, now: date(1_000))
        )

        let written = try XCTUnwrap(tree.writtenPaths.first)
        XCTAssertEqual(tree.writtenPaths.count, 1)
        XCTAssertEqual(written, "\(directory)/\(snapshot.fileName)\(LocalHistoryStore.temporarySuffix)")
        XCTAssertNil(LocalHistoryLayout.snapshot(fromFileName: (written as NSString).lastPathComponent))
        XCTAssertEqual(tree.moves, [StubFileTree.Move(from: written, to: "\(directory)/\(snapshot.fileName)")])
        XCTAssertNil(tree.files[written])
    }

    func testAnInjectedWriteFailureLosesTheRevisionAndNothingElse() {
        let tree = makeTree()
        let store = makeStore(tree)
        let directory = fileDirectory(path, in: tree)
        let name = LocalHistoryLayout.snapshotFileName(
            timestamp: date(1_000),
            event: .save,
            contentHash: LocalHistoryLayout.contentHash(of: "hello")
        )
        tree.writeFailures = ["\(directory)/\(name)\(LocalHistoryStore.temporarySuffix)"]

        XCTAssertNil(store.capture(text: "hello", root: projectRoot, relativePath: path, event: .save, now: date(1_000)))
        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path), [])
        XCTAssertEqual(tree.filePaths(under: directory), [])
        XCTAssertEqual(tree.moves, [])
    }

    func testAnInjectedMoveFailureLeavesNoPartialFileBehind() {
        let tree = makeTree()
        let store = makeStore(tree)
        let directory = fileDirectory(path, in: tree)
        let name = LocalHistoryLayout.snapshotFileName(
            timestamp: date(1_000),
            event: .save,
            contentHash: LocalHistoryLayout.contentHash(of: "hello")
        )
        tree.moveFailures = ["\(directory)/\(name)"]

        XCTAssertNil(store.capture(text: "hello", root: projectRoot, relativePath: path, event: .save, now: date(1_000)))
        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path), [])
        XCTAssertEqual(tree.filePaths(under: directory), [])
        XCTAssertEqual(tree.removedPaths, ["\(directory)/\(name)\(LocalHistoryStore.temporarySuffix)"])
    }

    func testADirectoryThatCannotBeCreatedLosesTheRevisionSilently() {
        let tree = makeTree()
        let store = makeStore(tree)
        // A plain file where the project's area should be: `ensureDirectory`
        // throws `notADirectory` on the way down.
        tree.files[projectDirectory(in: tree)] = "not a directory"

        XCTAssertNil(store.capture(text: "hello", root: projectRoot, relativePath: path, event: .save, now: date(1_000)))
        XCTAssertEqual(tree.writtenPaths, [])
        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path), [])
    }

    // MARK: - The policy's refusals reach the disk

    func testAPathOutsideTheProjectIsRefusedAndNothingIsWritten() {
        let tree = makeTree()
        let store = makeStore(tree)

        XCTAssertNil(store.capture(text: "hello", root: projectRoot, relativePath: "../elsewhere.swift", event: .save, now: date(1)))
        XCTAssertNil(store.capture(text: "hello", root: projectRoot, relativePath: "", event: .save, now: date(1)))
        XCTAssertEqual(tree.writtenPaths, [])
        XCTAssertEqual(tree.moves, [])
    }

    func testContentOverTheCeilingIsRefusedAndNothingIsWritten() {
        let tree = makeTree()
        let store = makeStore(tree, policy: LocalHistoryPolicy(maxContentBytes: 8))

        XCTAssertNil(store.capture(text: "123456789", root: projectRoot, relativePath: path, event: .save, now: date(1)))
        XCTAssertEqual(tree.writtenPaths, [])
        XCTAssertNotNil(store.capture(text: "12345678", root: projectRoot, relativePath: path, event: .save, now: date(1)))
    }

    // MARK: - Retention

    func testCapturePrunesTheSameFilesExcessRevisions() {
        let tree = makeTree()
        let store = makeStore(tree, policy: LocalHistoryPolicy(revisionsPerFile: 3))
        let directory = fileDirectory(path, in: tree)
        for index in 1...5 {
            store.capture(
                text: "revision \(index)",
                root: projectRoot,
                relativePath: path,
                event: .save,
                now: date(Double(index) * 1_000)
            )
        }

        let listed = store.revisions(root: projectRoot, relativePath: path)
        XCTAssertEqual(
            listed.compactMap { store.content(of: $0, root: projectRoot, relativePath: path) },
            ["revision 5", "revision 4", "revision 3"]
        )
        XCTAssertEqual(tree.filePaths(under: directory).count, 3)
    }

    func testCaptureDoesNotPruneAnotherFilesRevisions() {
        let tree = makeTree()
        let store = makeStore(tree, policy: LocalHistoryPolicy(maxAge: 60))
        store.capture(text: "old", root: projectRoot, relativePath: "other.swift", event: .save, now: date(1_000))
        store.capture(text: "new", root: projectRoot, relativePath: path, event: .save, now: date(1_000_000))

        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: "other.swift").count, 1)
    }

    func testPruneBoundsAWholeProjectAreaAndLeavesTheNewestOfEachFile() {
        let tree = makeTree()
        let store = makeStore(tree, policy: LocalHistoryPolicy(maxAge: 60))
        for path in ["a.swift", "deep/b.swift"] {
            store.capture(text: "one", root: projectRoot, relativePath: path, event: .save, now: date(1_000))
            store.capture(text: "two", root: projectRoot, relativePath: path, event: .save, now: date(1_010))
            XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path).count, 2)
        }

        store.prune(root: projectRoot, now: date(100_000))

        for path in ["a.swift", "deep/b.swift"] {
            let listed = store.revisions(root: projectRoot, relativePath: path)
            XCTAssertEqual(listed.count, 1, path)
            XCTAssertEqual(listed.first.flatMap { store.content(of: $0, root: projectRoot, relativePath: path) }, "two")
        }
    }

    func testPruneLeavesAnotherProjectsAreaAlone() {
        let tree = makeTree()
        let store = makeStore(tree, policy: LocalHistoryPolicy(maxAge: 60))
        let otherRoot = URL(fileURLWithPath: "/Users/someone/other")
        store.capture(text: "one", root: otherRoot, relativePath: path, event: .save, now: date(1_000))
        store.capture(text: "two", root: otherRoot, relativePath: path, event: .save, now: date(1_010))

        store.prune(root: projectRoot, now: date(100_000))

        XCTAssertEqual(store.revisions(root: otherRoot, relativePath: path).count, 2)
    }

    func testPruneRemovesAFileDirectoryLeftEmpty() {
        let tree = makeTree()
        let store = makeStore(tree)
        let empty = "\(projectDirectory(in: tree))/0123456789abcdef0123456789abcdef"
        tree.directories.insert(empty)

        store.prune(root: projectRoot, now: date(100_000))

        XCTAssertFalse(tree.hasDirectory(empty))
        XCTAssertEqual(tree.removedPaths, [empty])
    }

    func testAForeignFileIsIgnoredByListingAndLeftAloneByPruning() {
        let tree = makeTree()
        let store = makeStore(tree, policy: LocalHistoryPolicy(revisionsPerFile: 1))
        let directory = fileDirectory(path, in: tree)
        store.capture(text: "one", root: projectRoot, relativePath: path, event: .save, now: date(1_000))
        tree.files["\(directory)/notes.txt"] = "somebody else's"
        // Ends in the suffix but is not a snapshot name with it: not ours, so
        // not ours to delete either.
        tree.files["\(directory)/notes.txt.partial"] = "somebody else's too"

        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path).count, 1)

        store.capture(text: "two", root: projectRoot, relativePath: path, event: .save, now: date(2_000))
        store.prune(root: projectRoot, now: date(2_000))

        XCTAssertEqual(
            store.revisions(root: projectRoot, relativePath: path)
                .compactMap { store.content(of: $0, root: projectRoot, relativePath: path) },
            ["two"]
        )
        XCTAssertEqual(tree.files["\(directory)/notes.txt"], "somebody else's")
        XCTAssertEqual(tree.files["\(directory)/notes.txt.partial"], "somebody else's too")
    }

    /// The one entry in this store that nothing else can reclaim: listing looks
    /// through it (that is what the suffix is for) and so does retention, so
    /// without the sweep an interrupted write would sit here for the life of the
    /// store — and keep its directory from ever counting as empty.
    func testTheSweepReclaimsAnInterruptedWriteNothingElseCanSee() {
        let tree = makeTree()
        let store = makeStore(tree)
        let directory = fileDirectory(path, in: tree)
        let debris = "0000001772345678901-save-abcdef0123456789.snapshot\(LocalHistoryStore.temporarySuffix)"
        store.capture(text: "one", root: projectRoot, relativePath: path, event: .save, now: date(1_000))
        tree.files["\(directory)/\(debris)"] = "half a revision"

        store.prune(root: projectRoot, now: date(1_000))

        XCTAssertNil(tree.files["\(directory)/\(debris)"])
        // The revision beside it is untouched: the sweep reclaims debris, it does
        // not take the newest revision with it.
        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path).count, 1)
    }

    func testADirectoryHoldingNothingButInterruptedWritesIsRemovedWholesale() {
        let tree = makeTree()
        let store = makeStore(tree)
        let directory = fileDirectory(path, in: tree)
        let debris = "0000001772345678901-commit-abcdef0123456789.snapshot\(LocalHistoryStore.temporarySuffix)"
        tree.directories.insert(directory)
        tree.files["\(directory)/\(debris)"] = "half a revision"

        store.prune(root: projectRoot, now: date(1_000))

        XCTAssertNil(tree.files["\(directory)/\(debris)"])
        XCTAssertFalse(tree.hasDirectory(directory))
    }

    func testPruningLeavesTheNewestRevisionHoweverOldItIs() {
        let tree = makeTree()
        let store = makeStore(tree, policy: LocalHistoryPolicy(maxAge: 60))
        store.capture(text: "only", root: projectRoot, relativePath: path, event: .save, now: date(1_000))

        store.prune(root: projectRoot, now: date(10_000_000))

        let listed = store.revisions(root: projectRoot, relativePath: path)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first.flatMap { store.content(of: $0, root: projectRoot, relativePath: path) }, "only")
    }

    func testPruningANeverCapturedProjectDoesNothing() {
        let tree = makeTree()
        let store = makeStore(tree)

        store.prune(root: projectRoot, now: date(1_000))

        XCTAssertEqual(tree.removedPaths, [])
        XCTAssertEqual(tree.writtenPaths, [])
    }
}
