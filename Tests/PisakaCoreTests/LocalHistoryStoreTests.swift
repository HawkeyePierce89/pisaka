import XCTest
@testable import PisakaCore

/// The store is where the layout's name grammar and the policy's two rules meet
/// a file system, so what is asserted here is mostly *shape of disk traffic*
/// rather than return values: how many writes a dedup costs (none), how many
/// renames a capture costs (one, plus one for the path record on a file's
/// first), what an injected failure leaves behind
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
        let directory = fileDirectory(path, in: tree)
        let before = try XCTUnwrap(
            store.capture(text: "before", root: projectRoot, relativePath: path, event: .save, now: date(1_000))
        )
        let after = try XCTUnwrap(
            store.capture(text: "after", root: projectRoot, relativePath: path, event: .save, now: date(2_000))
        )

        // Two snapshots and one path record — the record only on the first.
        XCTAssertEqual(tree.moves.map(\.to), [
            "\(directory)/\(before.fileName)",
            "\(directory)/\(LocalHistoryLayout.pathRecordName)",
            "\(directory)/\(after.fileName)",
        ])
        XCTAssertEqual(tree.writtenPaths.count, 3)
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

    /// The first capture of a file costs one `move` for the snapshot and one for
    /// its path record, each through its own temporary; every later capture
    /// costs the snapshot's alone and never reads the record.
    func testCaptureWritesThroughATemporaryNameAndOneMovePlusTheRecordOnTheFirst() throws {
        let tree = makeTree()
        let store = makeStore(tree)
        let directory = fileDirectory(path, in: tree)
        let suffix = LocalHistoryStore.temporarySuffix
        let record = "\(directory)/\(LocalHistoryLayout.pathRecordName)"

        let snapshot = try XCTUnwrap(
            store.capture(text: "hello", root: projectRoot, relativePath: path, event: .save, now: date(1_000))
        )

        let written = "\(directory)/\(snapshot.fileName)\(suffix)"
        XCTAssertEqual(tree.writtenPaths, [written, record + suffix])
        XCTAssertNil(LocalHistoryLayout.snapshot(fromFileName: (written as NSString).lastPathComponent))
        XCTAssertEqual(tree.moves, [
            StubFileTree.Move(from: written, to: "\(directory)/\(snapshot.fileName)"),
            StubFileTree.Move(from: record + suffix, to: record),
        ])
        XCTAssertNil(tree.files[written])
        XCTAssertNil(tree.files[record + suffix])
        XCTAssertEqual(tree.files[record], path)

        let second = try XCTUnwrap(
            store.capture(text: "changed", root: projectRoot, relativePath: path, event: .save, now: date(2_000))
        )
        XCTAssertEqual(tree.writtenPaths, [written, record + suffix, "\(directory)/\(second.fileName)\(suffix)"])
        XCTAssertEqual(tree.moves.count, 3)
        XCTAssertNil(store.capture(text: "changed", root: projectRoot, relativePath: path, event: .save, now: date(3_000)))
        XCTAssertEqual(tree.writtenPaths.count, 3)
        // Capture never reads a record's content, on any path through it.
        XCTAssertFalse(tree.readPaths.contains(record))
        XCTAssertEqual(tree.readPaths, [])
    }

    /// The path record is the digest's input in its normalised spelling, so a
    /// capture under a non-normalised path still records the one its directory
    /// was named from.
    func testTheRecordIsTheNormalisedPath() {
        let tree = makeTree()
        let store = makeStore(tree)
        store.capture(text: "x", root: projectRoot, relativePath: "Sources/./App//main.swift", event: .save, now: date(1))

        XCTAssertEqual(tree.files["\(fileDirectory(path, in: tree))/\(LocalHistoryLayout.pathRecordName)"], path)
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
        // Twice, because a failed attempt is retried once — and the point of the
        // assertion is that *every* attempt cleans up after itself, so a
        // permanently failing one still leaves nothing behind.
        XCTAssertEqual(
            tree.removedPaths,
            Array(repeating: "\(directory)/\(name)\(LocalHistoryStore.temporarySuffix)", count: 2)
        )
    }

    /// A capture whose directory vanishes mid-write is retried, once.
    ///
    /// The quit-time capture runs on the main thread while the store-wide sweep
    /// may be running on the model's queue, and the sweep reclaims a file
    /// directory it finds empty — which is precisely what `capture` created a
    /// moment earlier. Without the retry that window costs the last save before
    /// a quit, i.e. the one edit the synchronous path exists to guarantee.
    func testACaptureWhoseDirectoryIsReclaimedMidWriteIsRetriedAndSucceeds() throws {
        let tree = makeTree()
        let store = makeStore(tree)
        let directory = fileDirectory(path, in: tree)
        let temporary = "\(directory)/\(LocalHistoryLayout.snapshotFileName(timestamp: date(1_000), event: .save, contentHash: LocalHistoryLayout.contentHash(of: "hello")))\(LocalHistoryStore.temporarySuffix)"
        // The sweep gets in exactly once, between the create and the write.
        tree.writeFailures = [temporary]
        tree.onWrite = { [weak tree] written in
            guard written == temporary else { return }
            tree?.writeFailures = []
        }

        let snapshot = try XCTUnwrap(
            store.capture(text: "hello", root: projectRoot, relativePath: path, event: .save, now: date(1_000))
        )

        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path), [snapshot])
        XCTAssertEqual(store.content(of: snapshot, root: projectRoot, relativePath: path), "hello")
        XCTAssertEqual(tree.moves.first, StubFileTree.Move(from: temporary, to: "\(directory)/\(snapshot.fileName)"))
        XCTAssertEqual(tree.files["\(directory)/\(LocalHistoryLayout.pathRecordName)"], path)
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

    // MARK: - The path record

    private func recordPath(_ relativePath: String, in tree: StubFileTree) -> String {
        "\(fileDirectory(relativePath, in: tree))/\(LocalHistoryLayout.pathRecordName)"
    }

    /// A directory written before records existed gets its record from the first
    /// capture after the upgrade — even one the policy dedups, which writes no
    /// snapshot and still reads no content.
    func testADedupedCaptureIntoARecordlessDirectoryWritesTheRecord() {
        let tree = makeTree()
        let store = makeStore(tree)
        store.capture(text: "same", root: projectRoot, relativePath: path, event: .save, now: date(1_000))
        let record = recordPath(path, in: tree)
        tree.files[record] = nil
        let snapshotsBefore = store.revisions(root: projectRoot, relativePath: path)

        XCTAssertNil(store.capture(text: "same", root: projectRoot, relativePath: path, event: .save, now: date(2_000)))

        XCTAssertEqual(tree.files[record], path)
        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path), snapshotsBefore)
        XCTAssertEqual(tree.readPaths, [])
    }

    /// No snapshot, no record: a refused capture into a directory with no history
    /// writes nothing at all.
    func testARefusedCaptureIntoAnEmptyDirectoryWritesNoRecord() {
        let tree = makeTree()
        let store = makeStore(tree, policy: LocalHistoryPolicy(maxContentBytes: 1))

        XCTAssertNil(store.capture(text: "too long", root: projectRoot, relativePath: path, event: .save, now: date(1)))
        XCTAssertEqual(tree.writtenPaths, [])
    }

    /// Capture writes a record only where the listing shows none and never reads
    /// one back, so a wrong record survives every capture byte for byte — and the
    /// readers, which verify, treat its directory as record-less.
    func testAPresentButWrongRecordIsNotRewrittenByCaptureAndIsNotListed() {
        let tree = makeTree()
        let store = makeStore(tree)
        store.capture(text: "one", root: projectRoot, relativePath: path, event: .save, now: date(1_000))
        let record = recordPath(path, in: tree)
        tree.files[record] = "Elsewhere/other.swift"

        store.capture(text: "two", root: projectRoot, relativePath: path, event: .save, now: date(2_000))
        store.capture(text: "two", root: projectRoot, relativePath: path, event: .save, now: date(3_000))

        XCTAssertEqual(tree.files[record], "Elsewhere/other.swift")
        // The first capture's record, and no other.
        XCTAssertEqual(tree.writtenPaths.filter { $0 == record + LocalHistoryStore.temporarySuffix }.count, 1)
        XCTAssertEqual(store.recordedPaths(root: projectRoot), [])
        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path).count, 2, "Still readable forwards.")
    }

    // MARK: - Labels

    private func sidecarPath(of snapshot: LocalHistorySnapshot, _ relativePath: String, in tree: StubFileTree) -> String {
        "\(fileDirectory(relativePath, in: tree))/\(LocalHistoryLayout.labelFileName(forSnapshotFileName: snapshot.fileName))"
    }

    /// The sidecar lands before its snapshot, so no listing ever shows a labelled
    /// row ahead of its text.
    func testALabelledCaptureWritesTheSidecarBeforeTheSnapshot() throws {
        let tree = makeTree()
        let store = makeStore(tree)
        let directory = fileDirectory(path, in: tree)

        let snapshot = try XCTUnwrap(store.capture(
            text: "body", root: projectRoot, relativePath: path, event: .label, label: "Before refactor", now: date(1_000)
        ))

        let sidecar = sidecarPath(of: snapshot, path, in: tree)
        XCTAssertEqual(tree.moves.map(\.to), [
            sidecar,
            "\(directory)/\(snapshot.fileName)",
            "\(directory)/\(LocalHistoryLayout.pathRecordName)",
        ])
        XCTAssertEqual(tree.files[sidecar], "Before refactor")
        XCTAssertNil(tree.files[sidecar + LocalHistoryStore.temporarySuffix])
        XCTAssertEqual(store.labelText(of: snapshot, root: projectRoot, relativePath: path), "Before refactor")
        XCTAssertEqual(store.content(of: snapshot, root: projectRoot, relativePath: path), "body")
    }

    /// A label marks a moment the user chose, so the same text labelled twice is
    /// two revisions, each with its own text.
    func testTheSameTextLabelledTwiceIsTwoRevisions() throws {
        let tree = makeTree()
        let store = makeStore(tree)
        let first = try XCTUnwrap(store.capture(
            text: "same", root: projectRoot, relativePath: path, event: .label, label: "one", now: date(1_000)
        ))
        let second = try XCTUnwrap(store.capture(
            text: "same", root: projectRoot, relativePath: path, event: .label, label: "two", now: date(2_000)
        ))

        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path), [second, first])
        XCTAssertEqual(store.labelText(of: first, root: projectRoot, relativePath: path), "one")
        XCTAssertEqual(store.labelText(of: second, root: projectRoot, relativePath: path), "two")
    }

    /// The text reaching the disk is what the policy's label rule makes of it; a
    /// text it refuses writes no sidecar, and a label beside any other event is
    /// ignored outright.
    func testOnlyALabelThePolicyAcceptsReachesTheDisk() throws {
        let tree = makeTree()
        let store = makeStore(tree)
        let trimmed = try XCTUnwrap(store.capture(
            text: "a", root: projectRoot, relativePath: path, event: .label, label: "  padded \n", now: date(1_000)
        ))
        let refused = try XCTUnwrap(store.capture(
            text: "b", root: projectRoot, relativePath: path, event: .label, label: "   ", now: date(2_000)
        ))
        let saved = try XCTUnwrap(store.capture(
            text: "c", root: projectRoot, relativePath: path, event: .save, label: "ignored", now: date(3_000)
        ))

        XCTAssertEqual(tree.files[sidecarPath(of: trimmed, path, in: tree)], "padded")
        XCTAssertNil(tree.files[sidecarPath(of: refused, path, in: tree)])
        XCTAssertNil(tree.files[sidecarPath(of: saved, path, in: tree)])
    }

    /// A sidecar that cannot be written loses the revision: a labelled capture
    /// never lands without its label.
    func testASidecarThatCannotBeWrittenLosesTheRevision() {
        let tree = makeTree()
        let store = makeStore(tree)
        let directory = fileDirectory(path, in: tree)
        let name = LocalHistoryLayout.snapshotFileName(
            timestamp: date(1_000), event: .label, contentHash: LocalHistoryLayout.contentHash(of: "body")
        )
        tree.writeFailures = ["\(directory)/\(LocalHistoryLayout.labelFileName(forSnapshotFileName: name))\(LocalHistoryStore.temporarySuffix)"]

        XCTAssertNil(store.capture(
            text: "body", root: projectRoot, relativePath: path, event: .label, label: "kept", now: date(1_000)
        ))
        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path), [])
        XCTAssertEqual(tree.filePaths(under: directory), [])
    }

    func testRetentionAtCaptureTakesALabelsSidecarWithItsSnapshot() throws {
        let tree = makeTree()
        let store = makeStore(tree, policy: LocalHistoryPolicy(revisionsPerFile: 1))
        let labelled = try XCTUnwrap(store.capture(
            text: "one", root: projectRoot, relativePath: path, event: .label, label: "mark", now: date(1_000)
        ))
        let sidecar = sidecarPath(of: labelled, path, in: tree)
        XCTAssertNotNil(tree.files[sidecar])

        store.capture(text: "two", root: projectRoot, relativePath: path, event: .save, now: date(2_000))

        XCTAssertNil(tree.files[sidecar])
        XCTAssertNil(tree.files["\(fileDirectory(path, in: tree))/\(labelled.fileName)"])
    }

    func testTheSweepTakesALabelsSidecarWithItsSnapshot() throws {
        let tree = makeTree()
        let writer = makeStore(tree)
        let labelled = try XCTUnwrap(writer.capture(
            text: "one", root: projectRoot, relativePath: path, event: .label, label: "mark", now: date(1_000)
        ))
        let newest = try XCTUnwrap(writer.capture(
            text: "two", root: projectRoot, relativePath: path, event: .save, now: date(2_000)
        ))

        makeStore(tree, policy: LocalHistoryPolicy(revisionsPerFile: 1)).pruneAll(now: date(2_000))

        XCTAssertNil(tree.files[sidecarPath(of: labelled, path, in: tree)])
        XCTAssertEqual(writer.revisions(root: projectRoot, relativePath: path), [newest])
    }

    // MARK: - The sweep and the record

    /// A record with no revision beside it describes no history: record and
    /// directory both go, the record first.
    func testTheSweepReclaimsARecordOnlyDirectory() {
        let tree = makeTree()
        let store = makeStore(tree)
        let directory = fileDirectory(path, in: tree)
        let record = recordPath(path, in: tree)
        tree.directories.insert(directory)
        tree.files[record] = path

        store.prune(root: projectRoot, now: date(1_000))

        XCTAssertNil(tree.files[record])
        XCTAssertFalse(tree.hasDirectory(directory))
        XCTAssertEqual(Array(tree.removedPaths.prefix(2)), [record, directory])
    }

    /// Every debris shape this feature can leave — a snapshot, record or sidecar
    /// temporary, and a sidecar whose snapshot never landed — is reclaimed, while
    /// the revision, its own sidecar and the record are kept.
    func testTheSweepReclaimsOrphanSidecarsAndEveryOwnTemporary() throws {
        let tree = makeTree()
        let store = makeStore(tree)
        let directory = fileDirectory(path, in: tree)
        let labelled = try XCTUnwrap(store.capture(
            text: "one", root: projectRoot, relativePath: path, event: .label, label: "kept", now: date(1_000)
        ))
        let orphanSnapshot = LocalHistoryLayout.snapshotFileName(
            timestamp: date(5_000), event: .label, contentHash: LocalHistoryLayout.contentHash(of: "never landed")
        )
        let orphan = LocalHistoryLayout.labelFileName(forSnapshotFileName: orphanSnapshot)
        let suffix = LocalHistoryStore.temporarySuffix
        let debris = [
            orphan,
            LocalHistoryLayout.pathRecordName + suffix,
            orphan + suffix,
            orphanSnapshot + suffix,
        ]
        for name in debris { tree.files["\(directory)/\(name)"] = "debris" }

        store.prune(root: projectRoot, now: date(1_000))

        XCTAssertEqual(
            Set(tree.filePaths(under: directory)),
            [
                "\(directory)/\(labelled.fileName)",
                sidecarPath(of: labelled, path, in: tree),
                recordPath(path, in: tree),
            ]
        )
    }

    /// Something this feature did not write keeps its directory, record and all.
    func testTheSweepLeavesARecordBesideAForeignFileAlone() {
        let tree = makeTree()
        let store = makeStore(tree)
        let directory = fileDirectory(path, in: tree)
        let record = recordPath(path, in: tree)
        tree.files[record] = path
        tree.files["\(directory)/notes.txt"] = "somebody else's"

        store.prune(root: projectRoot, now: date(1_000))

        XCTAssertEqual(tree.files[record], path)
        XCTAssertEqual(tree.files["\(directory)/notes.txt"], "somebody else's")
        XCTAssertEqual(tree.removedPaths, [])
    }

    // MARK: - Readers

    func testRecordedPathsListsOnlyVerifiedRecords() {
        let tree = makeTree()
        let store = makeStore(tree)
        for relativePath in ["a.swift", "deep/b.swift", "wrong.swift", "pre-upgrade.swift", "empty.swift"] {
            store.capture(text: relativePath, root: projectRoot, relativePath: relativePath, event: .save, now: date(1))
        }
        tree.files[recordPath("wrong.swift", in: tree)] = "a.swift"
        tree.files[recordPath("pre-upgrade.swift", in: tree)] = nil
        tree.files[recordPath("empty.swift", in: tree)] = ""
        tree.files["\(projectDirectory(in: tree))/stray"] = "not a file directory"

        XCTAssertEqual(store.recordedPaths(root: projectRoot), ["a.swift", "deep/b.swift"])
    }

    func testRecordedPathsOfAnUnreadableOrAbsentAreaIsEmpty() {
        let tree = makeTree()
        let store = makeStore(tree)
        XCTAssertEqual(store.recordedPaths(root: projectRoot), [])

        store.capture(text: "x", root: projectRoot, relativePath: path, event: .save, now: date(1))
        tree.unreadableDirectories = [projectDirectory(in: tree)]
        XCTAssertEqual(store.recordedPaths(root: projectRoot), [])
    }

    /// Asked of the project's files, so this one needs a root the tree holds.
    func testIsMissingAsksWhetherTheFileIsOnDisk() {
        let tree = makeTree()
        let store = makeStore(tree)
        let workRoot = storeRoot.appendingPathComponent("work")
        tree.files["work/Sources/present.swift"] = "here"

        XCTAssertFalse(store.isMissing(root: workRoot, relativePath: "Sources/present.swift"))
        XCTAssertFalse(store.isMissing(root: workRoot, relativePath: "Sources/./present.swift"))
        XCTAssertTrue(store.isMissing(root: workRoot, relativePath: "Sources/gone.swift"))
    }

    func testLabelTextIsNilForAMissingOrInvalidSidecarAndReadsNothingForOtherEvents() throws {
        let tree = makeTree()
        let store = makeStore(tree)
        let labelled = try XCTUnwrap(store.capture(
            text: "one", root: projectRoot, relativePath: path, event: .label, label: "mark", now: date(1_000)
        ))
        let sidecar = sidecarPath(of: labelled, path, in: tree)

        for invalid in ["", "   ", "two\nlines", String(repeating: "x", count: LocalHistoryPolicy.maxLabelLength + 1)] {
            tree.files[sidecar] = invalid
            XCTAssertNil(store.labelText(of: labelled, root: projectRoot, relativePath: path), invalid)
        }
        tree.files[sidecar] = nil
        XCTAssertNil(store.labelText(of: labelled, root: projectRoot, relativePath: path))

        let saved = try XCTUnwrap(store.capture(
            text: "two", root: projectRoot, relativePath: path, event: .save, now: date(2_000)
        ))
        let readsBefore = tree.readPaths
        XCTAssertNil(store.labelText(of: saved, root: projectRoot, relativePath: path))
        XCTAssertEqual(tree.readPaths, readsBefore)
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
        XCTAssertEqual(
            Set(tree.filePaths(under: directory).map { ($0 as NSString).lastPathComponent }),
            Set(listed.map(\.fileName) + [LocalHistoryLayout.pathRecordName])
        )
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

    /// The sweep is asked of the store, not of a root: a project that is never
    /// opened again is reclaimed by nothing else, so a per-project sweep would
    /// leave its snapshots on disk past every stated bound.
    func testPruneAllBoundsAProjectAreaNoRootWasHandedFor() {
        let tree = makeTree()
        let writer = makeStore(tree)
        let otherRoot = URL(fileURLWithPath: "/Users/someone/other")
        for index in 1...3 {
            writer.capture(
                text: "v\(index)",
                root: otherRoot,
                relativePath: path,
                event: .save,
                now: date(1_000 + Double(index))
            )
        }
        XCTAssertEqual(writer.revisions(root: otherRoot, relativePath: path).count, 3)

        makeStore(tree, policy: LocalHistoryPolicy(revisionsPerFile: 1)).pruneAll(now: date(1_010))

        XCTAssertEqual(
            writer.revisions(root: otherRoot, relativePath: path).count,
            1,
            "Every project area is swept, including the ones no caller named."
        )
    }

    /// A whole area whose every file directory pruned away goes with them, so the
    /// store the user is invited to open in Finder does not keep a directory per
    /// project that no longer has any history at all.
    func testPruneAllRemovesAProjectAreaLeftEmpty() {
        let tree = makeTree()
        let store = makeStore(tree)
        let project = projectDirectory(in: tree)
        tree.directories.insert(project)
        tree.directories.insert("\(project)/0123456789abcdef0123456789abcdef")

        store.pruneAll(now: date(100_000))

        XCTAssertFalse(tree.hasDirectory(project))
    }

    /// A project area still holding something this feature did not write is left
    /// exactly as it is, area and all.
    func testPruneAllLeavesAnAreaHoldingAForeignEntryAlone() {
        let tree = makeTree()
        let store = makeStore(tree)
        let project = projectDirectory(in: tree)
        tree.files["\(project)/notes.txt"] = "somebody else's"

        store.pruneAll(now: date(100_000))

        XCTAssertTrue(tree.hasDirectory(project))
        XCTAssertEqual(tree.files["\(project)/notes.txt"], "somebody else's")
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

    /// The quit-time capture bypasses the write chain, so it can land a whole
    /// snapshot in a file directory *while* the sweep is clearing that
    /// directory's debris. Removing on the listing taken before that clearing
    /// would take the new snapshot with the directory — silently, and past any
    /// help from `capture`'s retry, which has already seen its `move` succeed.
    /// The snapshot at stake is the last save before a quit, which is the one
    /// the synchronous path exists to guarantee.
    ///
    /// `onRemove` stages exactly that interleaving: the capture runs at the
    /// moment the debris is removed, which is the last thing the sweep does
    /// before deciding the directory is empty.
    func testASnapshotLandingWhileTheSweepClearsDebrisSurvivesTheSweep() {
        let tree = makeTree()
        let store = makeStore(tree)
        let directory = fileDirectory(path, in: tree)
        let debris = "0000001772345678901-save-abcdef0123456789.snapshot\(LocalHistoryStore.temporarySuffix)"
        tree.directories.insert(directory)
        tree.files["\(directory)/\(debris)"] = "half a revision"

        tree.onRemove = { [weak tree] removed in
            guard removed == "\(directory)/\(debris)" else { return }
            tree?.onRemove = nil
            store.capture(text: "the last save", root: self.projectRoot, relativePath: self.path, event: .save, now: self.date(1_000))
        }
        store.prune(root: projectRoot, now: date(1_000))

        XCTAssertTrue(tree.hasDirectory(directory))
        let listed = store.revisions(root: projectRoot, relativePath: path)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(store.content(of: listed[0], root: projectRoot, relativePath: path), "the last save")
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

    /// The floor both user-facing docs now state: a sweep takes a path down to one
    /// revision and no further, so a fully expired area is *not* reclaimed — its
    /// file directory and the area around it survive every later sweep. Pinned
    /// because the two "left empty" branches read as if aging out could reach
    /// them, and because dropping the newest-survives rule to bound the store
    /// would have to change this documented consequence too.
    func testAFullyExpiredAreaSettlesAtOneRevisionAndIsNeverReclaimed() {
        let tree = makeTree()
        let store = makeStore(tree, policy: LocalHistoryPolicy(maxAge: 60))
        store.capture(text: "first", root: projectRoot, relativePath: path, event: .save, now: date(1_000))
        store.capture(text: "second", root: projectRoot, relativePath: path, event: .save, now: date(2_000))

        store.pruneAll(now: date(10_000_000))
        store.pruneAll(now: date(20_000_000))

        XCTAssertTrue(
            tree.hasDirectory(fileDirectory(path, in: tree)),
            "The file directory outlived a sweep that condemned every revision in it."
        )
        XCTAssertTrue(tree.hasDirectory(projectDirectory(in: tree)), "The project area outlived it too.")
        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path).map(\.contentHash).count, 1)
    }

    func testPruningANeverCapturedProjectDoesNothing() {
        let tree = makeTree()
        let store = makeStore(tree)

        store.prune(root: projectRoot, now: date(1_000))

        XCTAssertEqual(tree.removedPaths, [])
        XCTAssertEqual(tree.writtenPaths, [])
    }
}
