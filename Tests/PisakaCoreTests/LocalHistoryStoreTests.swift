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
        let suffix = LocalHistoryLayout.temporarySuffix
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
        tree.writeFailures = ["\(directory)/\(name)\(LocalHistoryLayout.temporarySuffix)"]

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
            Array(repeating: "\(directory)/\(name)\(LocalHistoryLayout.temporarySuffix)", count: 2)
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
        let temporary = "\(directory)/\(LocalHistoryLayout.snapshotFileName(timestamp: date(1_000), event: .save, contentHash: LocalHistoryLayout.contentHash(of: "hello")))\(LocalHistoryLayout.temporarySuffix)"
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
        XCTAssertEqual(tree.writtenPaths.filter { $0 == record + LocalHistoryLayout.temporarySuffix }.count, 1)
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
        XCTAssertNil(tree.files[sidecar + LocalHistoryLayout.temporarySuffix])
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
        tree.writeFailures = ["\(directory)/\(LocalHistoryLayout.labelFileName(forSnapshotFileName: name))\(LocalHistoryLayout.temporarySuffix)"]

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
        let suffix = LocalHistoryLayout.temporarySuffix
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

    // MARK: - Migration

    /// A rename carries the directory whole: every revision keeps its name, so
    /// its timestamp and event, and its label; only the record changes.
    func testARenameCarriesEveryRevisionAndRewritesTheRecord() throws {
        let tree = makeTree()
        let store = makeStore(tree)
        let renamed = "Sources/App/entry.swift"
        store.capture(text: "one", root: projectRoot, relativePath: path, event: .save, now: date(1_000))
        store.capture(text: "two", root: projectRoot, relativePath: path, event: .commit, now: date(2_000))
        let labelled = try XCTUnwrap(store.capture(
            text: "three", root: projectRoot, relativePath: path, event: .label, label: "mark", now: date(3_000)
        ))
        let before = store.revisions(root: projectRoot, relativePath: path)
        let contents = before.compactMap { store.content(of: $0, root: projectRoot, relativePath: path) }

        store.migrate(root: projectRoot, from: path, to: renamed, now: date(4_000))

        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: renamed), before)
        XCTAssertEqual(
            before.compactMap { store.content(of: $0, root: projectRoot, relativePath: renamed) },
            contents
        )
        XCTAssertEqual(store.labelText(of: labelled, root: projectRoot, relativePath: renamed), "mark")
        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path), [])
        XCTAssertFalse(tree.hasDirectory(fileDirectory(path, in: tree)))
        XCTAssertEqual(tree.files[recordPath(renamed, in: tree)], renamed)
        XCTAssertEqual(store.recordedPaths(root: projectRoot), [renamed])
    }

    /// A folder move re-keys every recorded descendant at any depth; a
    /// descendant with no verified record stays under its old key, readable
    /// forwards.
    func testAFolderMoveRekeysEveryRecordedDescendantAndLeavesARecordlessOneBehind() {
        let tree = makeTree()
        let store = makeStore(tree)
        for relativePath in ["lib/a.swift", "lib/deep/b.swift", "lib/old.swift", "other/c.swift"] {
            store.capture(text: relativePath, root: projectRoot, relativePath: relativePath, event: .save, now: date(1))
        }
        tree.files[recordPath("lib/old.swift", in: tree)] = nil

        store.migrate(root: projectRoot, from: "lib", to: "src/lib", now: date(2))

        XCTAssertEqual(
            store.recordedPaths(root: projectRoot),
            ["other/c.swift", "src/lib/a.swift", "src/lib/deep/b.swift"]
        )
        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: "src/lib/deep/b.swift").count, 1)
        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: "lib/old.swift").count, 1)
        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: "src/lib/old.swift"), [])
    }

    /// The prefix is matched at a `/` boundary, in the records' own spelling.
    func testAPrefixMovesOnlyAtAComponentBoundary() {
        let tree = makeTree()
        let store = makeStore(tree)
        for relativePath in ["a/x.swift", "ab/x.swift"] {
            store.capture(text: relativePath, root: projectRoot, relativePath: relativePath, event: .save, now: date(1))
        }

        store.migrate(root: projectRoot, from: "./a/", to: "z", now: date(2))

        XCTAssertEqual(store.recordedPaths(root: projectRoot), ["ab/x.swift", "z/x.swift"])
    }

    /// A move onto a path with a history of its own merges the two: one list,
    /// the destination's copy winning a name clash, pruned by the per-file rule.
    func testAMergeIntoAnExistingHistoryKeepsTheDestinationsCopyAndPrunesTheMergedList() throws {
        let tree = makeTree()
        let store = makeStore(tree, policy: LocalHistoryPolicy(revisionsPerFile: 4))
        let target = "Sources/App/target.swift"
        store.capture(text: "one", root: projectRoot, relativePath: path, event: .save, now: date(1_000))
        store.capture(text: "two", root: projectRoot, relativePath: target, event: .save, now: date(2_000))
        store.capture(text: "three", root: projectRoot, relativePath: path, event: .save, now: date(3_000))
        store.capture(text: "four", root: projectRoot, relativePath: target, event: .save, now: date(4_000))
        let clash = try XCTUnwrap(store.capture(
            text: "clash", root: projectRoot, relativePath: target, event: .commit, now: date(5_000)
        ))
        store.capture(text: "clash", root: projectRoot, relativePath: path, event: .commit, now: date(5_000))
        tree.files["\(fileDirectory(target, in: tree))/\(clash.fileName)"] = "destination copy"
        tree.files["\(fileDirectory(path, in: tree))/\(clash.fileName)"] = "source copy"

        store.migrate(root: projectRoot, from: path, to: target, now: date(6_000))

        let merged = store.revisions(root: projectRoot, relativePath: target)
        XCTAssertEqual(merged.map(\.timestamp), [date(5_000), date(4_000), date(3_000), date(2_000)])
        XCTAssertEqual(store.content(of: clash, root: projectRoot, relativePath: target), "destination copy")
        XCTAssertFalse(tree.hasDirectory(fileDirectory(path, in: tree)))
        XCTAssertEqual(tree.files[recordPath(target, in: tree)], target)
        XCTAssertEqual(store.recordedPaths(root: projectRoot), [target])
        XCTAssertEqual(
            Set(tree.filePaths(under: fileDirectory(target, in: tree)).map { ($0 as NSString).lastPathComponent }),
            Set(merged.map(\.fileName) + [LocalHistoryLayout.pathRecordName])
        )
    }

    /// The merge is the one thing that corrects a wrong record.
    func testAMergeIntoADestinationWithAWrongRecordLeavesACorrectOne() {
        let tree = makeTree()
        let store = makeStore(tree)
        let target = "target.swift"
        store.capture(text: "old", root: projectRoot, relativePath: target, event: .save, now: date(1_000))
        tree.files[recordPath(target, in: tree)] = "somewhere/else.swift"
        store.capture(text: "moved", root: projectRoot, relativePath: path, event: .save, now: date(2_000))

        store.migrate(root: projectRoot, from: path, to: target, now: date(3_000))

        XCTAssertEqual(tree.files[recordPath(target, in: tree)], target)
        XCTAssertEqual(store.recordedPaths(root: projectRoot), [target])
        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: target).count, 2)
    }

    /// Sidecars travel with their snapshots through a merge too, and land first.
    func testAMergeCarriesLabelSidecarsAheadOfTheirSnapshots() throws {
        let tree = makeTree()
        let store = makeStore(tree)
        let target = "target.swift"
        store.capture(text: "there", root: projectRoot, relativePath: target, event: .save, now: date(1_000))
        let labelled = try XCTUnwrap(store.capture(
            text: "here", root: projectRoot, relativePath: path, event: .label, label: "mark", now: date(2_000)
        ))
        let movesBefore = tree.moves.count

        store.migrate(root: projectRoot, from: path, to: target, now: date(3_000))

        let directory = fileDirectory(target, in: tree)
        let carried = tree.moves.dropFirst(movesBefore).map(\.to)
        XCTAssertEqual(Array(carried.prefix(2)), [
            "\(directory)/\(LocalHistoryLayout.labelFileName(forSnapshotFileName: labelled.fileName))",
            "\(directory)/\(labelled.fileName)",
        ])
        XCTAssertEqual(store.labelText(of: labelled, root: projectRoot, relativePath: target), "mark")
        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: target).count, 2)
    }

    /// A `move` that fails with nothing to merge into leaves the source exactly
    /// where it was, still listed under its old key.
    func testAFailedMoveLeavesTheSourceIntactUnderItsOldKey() {
        let tree = makeTree()
        let store = makeStore(tree)
        let target = "target.swift"
        store.capture(text: "one", root: projectRoot, relativePath: path, event: .save, now: date(1_000))
        store.capture(text: "two", root: projectRoot, relativePath: path, event: .save, now: date(2_000))
        let source = fileDirectory(path, in: tree)
        let filesBefore = tree.filePaths(under: source)
        let revisionsBefore = store.revisions(root: projectRoot, relativePath: path)
        tree.moveFailures = [fileDirectory(target, in: tree)]

        store.migrate(root: projectRoot, from: path, to: target, now: date(3_000))

        XCTAssertEqual(tree.filePaths(under: source), filesBefore)
        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path), revisionsBefore)
        XCTAssertEqual(store.recordedPaths(root: projectRoot), [path])
        XCTAssertFalse(tree.hasDirectory(fileDirectory(target, in: tree)))
    }

    /// An entry a merge cannot move stays in the source, and so does the record
    /// that still names it.
    func testAMergedEntryThatCannotMoveStaysBehindUnderItsRecord() throws {
        let tree = makeTree()
        let store = makeStore(tree)
        let target = "target.swift"
        store.capture(text: "there", root: projectRoot, relativePath: target, event: .save, now: date(1_000))
        let stuck = try XCTUnwrap(store.capture(
            text: "stuck", root: projectRoot, relativePath: path, event: .save, now: date(2_000)
        ))
        store.capture(text: "carried", root: projectRoot, relativePath: path, event: .save, now: date(3_000))
        tree.moveFailures = ["\(fileDirectory(target, in: tree))/\(stuck.fileName)"]

        store.migrate(root: projectRoot, from: path, to: target, now: date(4_000))

        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path), [stuck])
        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: target).count, 2)
        XCTAssertEqual(store.recordedPaths(root: projectRoot), [path, target].sorted())
    }

    /// What the merge did not write is not its to remove: a foreign file keeps
    /// the source's record and directory where they are, while the merge's own
    /// debris is discarded and every revision is still carried.
    func testAMergeLeavesASourceHoldingAForeignFileUnderItsRecordAndDiscardsItsOwnDebris() throws {
        let tree = makeTree()
        let store = makeStore(tree)
        let target = "target.swift"
        store.capture(text: "there", root: projectRoot, relativePath: target, event: .save, now: date(1_000))
        let carried = try XCTUnwrap(store.capture(
            text: "here", root: projectRoot, relativePath: path, event: .save, now: date(2_000)
        ))
        let source = fileDirectory(path, in: tree)
        let foreign = "\(source)/notes.txt"
        let debris = "\(source)/\(carried.fileName)\(LocalHistoryLayout.temporarySuffix)"
        tree.files[foreign] = "not ours"
        tree.files[debris] = "half a revision"

        store.migrate(root: projectRoot, from: path, to: target, now: date(3_000))

        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: target).count, 2)
        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path), [])
        XCTAssertNil(tree.files[debris])
        XCTAssertEqual(tree.files[foreign], "not ours")
        XCTAssertEqual(tree.files[recordPath(path, in: tree)], path)
        XCTAssertEqual(store.recordedPaths(root: projectRoot), [path, target].sorted())
    }

    /// An empty directory under the new key — what a capture that failed after
    /// its `ensureDirectory` leaves — is merged into like any other, so the
    /// history follows the move instead of staying under the old key for good.
    func testAMoveOntoAnEmptyHistoryDirectoryCarriesTheHistory() throws {
        let tree = makeTree()
        let store = makeStore(tree)
        let target = "target.swift"
        let labelled = try XCTUnwrap(store.capture(
            text: "one", root: projectRoot, relativePath: path, event: .label, label: "mark", now: date(1_000)
        ))
        let revisionsBefore = store.revisions(root: projectRoot, relativePath: path)
        tree.directories.insert(fileDirectory(target, in: tree))

        store.migrate(root: projectRoot, from: path, to: target, now: date(2_000))

        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: target), revisionsBefore)
        XCTAssertEqual(store.labelText(of: labelled, root: projectRoot, relativePath: target), "mark")
        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path), [])
        XCTAssertFalse(tree.hasDirectory(fileDirectory(path, in: tree)))
        XCTAssertEqual(store.recordedPaths(root: projectRoot), [target])
    }

    /// A sidecar that cannot be carried keeps its snapshot at the source with
    /// it: the pair strands together, still labelled, and nothing half-moved is
    /// left under the new key.
    func testAMergedSidecarThatCannotMoveKeepsItsSnapshotBesideIt() throws {
        let tree = makeTree()
        let store = makeStore(tree)
        let target = "target.swift"
        store.capture(text: "there", root: projectRoot, relativePath: target, event: .save, now: date(1_000))
        let labelled = try XCTUnwrap(store.capture(
            text: "here", root: projectRoot, relativePath: path, event: .label, label: "mark", now: date(2_000)
        ))
        let sidecar = LocalHistoryLayout.labelFileName(forSnapshotFileName: labelled.fileName)
        let destination = fileDirectory(target, in: tree)
        tree.moveFailures = ["\(destination)/\(sidecar)"]

        store.migrate(root: projectRoot, from: path, to: target, now: date(3_000))

        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path), [labelled])
        XCTAssertEqual(store.labelText(of: labelled, root: projectRoot, relativePath: path), "mark")
        XCTAssertNil(tree.files["\(destination)/\(labelled.fileName)"])
        XCTAssertEqual(store.recordedPaths(root: projectRoot), [path, target].sorted())
    }

    /// A snapshot that cannot be carried takes back the sidecar that went ahead
    /// of it, so the source keeps a labelled row and the destination no orphan.
    func testAMergedLabelledSnapshotThatCannotMoveTakesItsSidecarBack() throws {
        let tree = makeTree()
        let store = makeStore(tree)
        let target = "target.swift"
        store.capture(text: "there", root: projectRoot, relativePath: target, event: .save, now: date(1_000))
        let labelled = try XCTUnwrap(store.capture(
            text: "here", root: projectRoot, relativePath: path, event: .label, label: "mark", now: date(2_000)
        ))
        let sidecar = LocalHistoryLayout.labelFileName(forSnapshotFileName: labelled.fileName)
        let destination = fileDirectory(target, in: tree)
        tree.moveFailures = ["\(destination)/\(labelled.fileName)"]

        store.migrate(root: projectRoot, from: path, to: target, now: date(3_000))

        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path), [labelled])
        XCTAssertEqual(store.labelText(of: labelled, root: projectRoot, relativePath: path), "mark")
        XCTAssertNil(tree.files["\(destination)/\(sidecar)"])
        XCTAssertEqual(store.recordedPaths(root: projectRoot), [path, target].sorted())
    }

    /// A revision the destination already holds is carried only by removing the
    /// source's copy; a copy that cannot be removed strands like a failed move —
    /// still labelled, under the record that names it, with no orphan label
    /// copy left at the destination.
    func testADuplicateThatCannotBeRemovedStrandsWithItsSidecarAndRecord() throws {
        let tree = makeTree()
        let store = makeStore(tree)
        let target = "target.swift"
        store.capture(text: "there", root: projectRoot, relativePath: target, event: .save, now: date(1_000))
        let labelled = try XCTUnwrap(store.capture(
            text: "here", root: projectRoot, relativePath: path, event: .label, label: "mark", now: date(2_000)
        ))
        let sidecar = LocalHistoryLayout.labelFileName(forSnapshotFileName: labelled.fileName)
        let source = fileDirectory(path, in: tree)
        let destination = fileDirectory(target, in: tree)
        tree.files["\(destination)/\(labelled.fileName)"] = "here"
        tree.removeFailures = ["\(source)/\(labelled.fileName)"]

        store.migrate(root: projectRoot, from: path, to: target, now: date(3_000))

        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path), [labelled])
        XCTAssertEqual(store.labelText(of: labelled, root: projectRoot, relativePath: path), "mark")
        XCTAssertNil(tree.files["\(destination)/\(sidecar)"])
        XCTAssertEqual(tree.files[recordPath(path, in: tree)], path)
        XCTAssertEqual(store.recordedPaths(root: projectRoot), [path, target].sorted())
    }

    /// A labelled snapshot that stays behind keeps its own sidecar even when the
    /// destination already holds one of the same name.
    func testAStrandedLabelledSnapshotKeepsItsSidecarOverADestinationCopy() throws {
        let tree = makeTree()
        let store = makeStore(tree)
        let target = "target.swift"
        store.capture(text: "there", root: projectRoot, relativePath: target, event: .save, now: date(1_000))
        let labelled = try XCTUnwrap(store.capture(
            text: "here", root: projectRoot, relativePath: path, event: .label, label: "mark", now: date(2_000)
        ))
        let sidecar = LocalHistoryLayout.labelFileName(forSnapshotFileName: labelled.fileName)
        let destination = fileDirectory(target, in: tree)
        tree.files["\(destination)/\(sidecar)"] = "mark"
        tree.moveFailures = ["\(destination)/\(labelled.fileName)"]

        store.migrate(root: projectRoot, from: path, to: target, now: date(3_000))

        XCTAssertEqual(store.labelText(of: labelled, root: projectRoot, relativePath: path), "mark")
    }

    /// The copy that went ahead of a snapshot that cannot move is discarded; if
    /// that discard fails too, the original still sits beside its snapshot, so
    /// the label survives at the source whatever the destination is left with.
    func testAFailedCleanupAfterAStrandedSnapshotKeepsItsLabelAtTheSource() throws {
        let tree = makeTree()
        let store = makeStore(tree)
        let target = "target.swift"
        store.capture(text: "there", root: projectRoot, relativePath: target, event: .save, now: date(1_000))
        let labelled = try XCTUnwrap(store.capture(
            text: "here", root: projectRoot, relativePath: path, event: .label, label: "mark", now: date(2_000)
        ))
        let sidecar = LocalHistoryLayout.labelFileName(forSnapshotFileName: labelled.fileName)
        let destination = fileDirectory(target, in: tree)
        // Every way back fails too: nothing may move the sidecar home, and the
        // copy at the destination cannot be removed.
        tree.moveFailures = ["\(destination)/\(labelled.fileName)", "\(fileDirectory(path, in: tree))/\(sidecar)"]
        tree.removeFailures = ["\(destination)/\(sidecar)"]

        store.migrate(root: projectRoot, from: path, to: target, now: date(3_000))

        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path), [labelled])
        XCTAssertEqual(store.labelText(of: labelled, root: projectRoot, relativePath: path), "mark")
    }

    /// Only a listing that succeeded says what a destination holds: a file
    /// sitting where the new key's directory belongs is neither removed nor
    /// merged into, and the history stays under the old key.
    func testAMoveOntoAFileAtTheDestinationKeyLeavesBothAlone() {
        let tree = makeTree()
        let store = makeStore(tree)
        let target = "target.swift"
        store.capture(text: "one", root: projectRoot, relativePath: path, event: .save, now: date(1_000))
        let revisionsBefore = store.revisions(root: projectRoot, relativePath: path)
        let destination = fileDirectory(target, in: tree)
        tree.files[destination] = "not ours"

        store.migrate(root: projectRoot, from: path, to: target, now: date(2_000))

        XCTAssertEqual(tree.files[destination], "not ours")
        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path), revisionsBefore)
        XCTAssertEqual(store.recordedPaths(root: projectRoot), [path])
    }

    /// A destination directory that cannot be listed is not taken for an empty
    /// one: it is left in place, and so is the source.
    func testAMoveOntoAnUnreadableDestinationLeavesBothAlone() {
        let tree = makeTree()
        let store = makeStore(tree)
        let target = "target.swift"
        store.capture(text: "there", root: projectRoot, relativePath: target, event: .save, now: date(1_000))
        store.capture(text: "here", root: projectRoot, relativePath: path, event: .save, now: date(2_000))
        let revisionsBefore = store.revisions(root: projectRoot, relativePath: path)
        let destination = fileDirectory(target, in: tree)
        let destinationFiles = tree.filePaths(under: destination)
        tree.unreadableDirectories = [destination]

        store.migrate(root: projectRoot, from: path, to: target, now: date(3_000))

        XCTAssertEqual(tree.filePaths(under: destination), destinationFiles)
        XCTAssertEqual(store.revisions(root: projectRoot, relativePath: path), revisionsBefore)
    }

    func testMigratingAPathOntoItselfDoesNothing() {
        let tree = makeTree()
        let store = makeStore(tree)
        store.capture(text: "one", root: projectRoot, relativePath: path, event: .save, now: date(1_000))
        let movesBefore = tree.moves

        store.migrate(root: projectRoot, from: path, to: "./\(path)", now: date(2_000))

        XCTAssertEqual(tree.moves, movesBefore)
        XCTAssertEqual(tree.readPaths, [])
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
        let debris = "0000001772345678901-save-abcdef0123456789.snapshot\(LocalHistoryLayout.temporarySuffix)"
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
        let debris = "0000001772345678901-commit-abcdef0123456789.snapshot\(LocalHistoryLayout.temporarySuffix)"
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
        let debris = "0000001772345678901-save-abcdef0123456789.snapshot\(LocalHistoryLayout.temporarySuffix)"
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

    /// The record-only reclamation has the same race, removing the record where
    /// the debris case removes a temporary: a quit-time capture landing as the
    /// record goes keeps its snapshot and its directory, and the next capture's
    /// listing shows the record gone and writes it again.
    func testASnapshotLandingWhileTheSweepRemovesARecordSurvivesAndTheRecordComesBack() {
        let tree = makeTree()
        let store = makeStore(tree)
        let directory = fileDirectory(path, in: tree)
        let record = recordPath(path, in: tree)
        tree.directories.insert(directory)
        tree.files[record] = path

        tree.onRemove = { [weak tree] removed in
            guard removed == record else { return }
            tree?.onRemove = nil
            store.capture(text: "the last save", root: self.projectRoot, relativePath: self.path, event: .save, now: self.date(1_000))
        }
        store.prune(root: projectRoot, now: date(1_000))

        XCTAssertTrue(tree.hasDirectory(directory))
        let listed = store.revisions(root: projectRoot, relativePath: path)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(store.content(of: listed[0], root: projectRoot, relativePath: path), "the last save")
        XCTAssertNil(tree.files[record])

        store.capture(text: "the next save", root: projectRoot, relativePath: path, event: .save, now: date(2_000))
        XCTAssertEqual(tree.files[record], path)
        XCTAssertEqual(store.recordedPaths(root: projectRoot), [path])
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
