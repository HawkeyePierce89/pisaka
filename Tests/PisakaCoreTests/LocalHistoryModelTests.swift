import XCTest
@testable import PisakaCore

/// The capture model is where Local History meets the app's timing, so what is
/// asserted here is *ordering and inputs* rather than storage shape (which
/// `LocalHistoryStoreTests` already pins): what a pre-operation capture reads and
/// what it refuses to read, that awaiting it really does mean the bytes are
/// stored, that the quit path is finished by the time it returns, and that two
/// overlapping captures of one file behave as one lane rather than two.
///
/// Everything runs against a single `StubFileTree` holding *both* halves — the
/// store's base at `/work/LocalHistory` and the project at `/work/project` —
/// because unlike the store, this model reads the user's files too.
///
/// Nothing here sleeps: the one test that has to observe work in flight holds it
/// on `StubFileTree.readGate` and waits for the gate to be entered.
@MainActor
final class LocalHistoryModelTests: XCTestCase {
    private let treeRoot = URL(fileURLWithPath: "/work")
    private let projectRoot = URL(fileURLWithPath: "/work/project")

    private var base: URL { treeRoot.appendingPathComponent("LocalHistory") }

    /// A clock that answers a new, strictly later instant on every call, so two
    /// captures inside one test are ordered by what they are rather than by how
    /// fast the machine ran. Timestamps are stored to the millisecond, and these
    /// are a second apart.
    private final class StepClock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: Double

        init(start: Double = 1_772_345_678) { seconds = start }

        func next() -> Date {
            lock.lock()
            defer { lock.unlock() }
            let value = seconds
            seconds += 1
            return Date(timeIntervalSince1970: value)
        }
    }

    private func makeTree(files: [String: String] = [:]) -> StubFileTree {
        StubFileTree(root: treeRoot, files: files)
    }

    private func makeModel(
        _ tree: StubFileTree,
        policy: LocalHistoryPolicy = LocalHistoryPolicy(),
        clock: StepClock = StepClock()
    ) -> LocalHistoryModel {
        LocalHistoryModel(base: base, fileService: tree, policy: policy, now: clock.next)
    }

    private func projectFile(_ relativePath: String) -> URL {
        projectRoot.appendingPathComponent(relativePath)
    }

    private func revisions(_ model: LocalHistoryModel, _ relativePath: String) -> [LocalHistorySnapshot] {
        model.store.revisions(root: projectRoot, relativePath: relativePath)
    }

    private func contents(_ model: LocalHistoryModel, _ relativePath: String) -> [String] {
        revisions(model, relativePath).compactMap {
            model.store.content(of: $0, root: projectRoot, relativePath: relativePath)
        }
    }

    /// Drain the fire-and-forget chain — the causal equivalent of "the save
    /// capture has happened", with no delay anywhere.
    private func drain(_ model: LocalHistoryModel) async {
        await model.chain?.value
    }

    // MARK: - Before a worktree operation

    func testCaptureBeforeOperationReturnsOnlyOnceEveryByteIsStored() async {
        let tree = makeTree(files: ["project/disk.swift": "on disk"])
        let gate = Gate()
        tree.readGate = (path: "project/disk.swift", gate: gate)
        let model = makeModel(tree)

        let capture = Task {
            await model.captureBeforeOperation(
                event: .commit,
                root: projectRoot,
                bufferTexts: [projectFile("buffer.swift"): "in a buffer"],
                diskTargets: [projectFile("disk.swift")]
            )
        }

        await gate.waitUntilReached()
        // The read is held, so the operation is demonstrably still in flight —
        // and the disk target is demonstrably not stored yet.
        XCTAssertTrue(revisions(model, "disk.swift").isEmpty)
        gate.release()
        await capture.value

        XCTAssertEqual(contents(model, "buffer.swift"), ["in a buffer"])
        XCTAssertEqual(contents(model, "disk.swift"), ["on disk"])
        XCTAssertEqual(revisions(model, "disk.swift").map(\.event), [.commit])
    }

    func testAFileWithBothABufferAndADiskTargetIsCapturedOnceFromTheBuffer() async {
        let tree = makeTree(files: ["project/a.swift": "the disk version"])
        let model = makeModel(tree)

        await model.captureBeforeOperation(
            event: .revert,
            root: projectRoot,
            bufferTexts: [projectFile("a.swift"): "the buffer version"],
            diskTargets: [projectFile("a.swift")]
        )

        XCTAssertEqual(contents(model, "a.swift"), ["the buffer version"])
        // Not merely deduplicated after the fact: the file was never read.
        XCTAssertFalse(tree.readPaths.contains("project/a.swift"))
    }

    func testABinaryOrUnreadableDiskTargetIsSilentlyAbsent() async {
        let tree = makeTree(files: [
            "project/image.png": "\u{0}binary",
            "project/locked.swift": "text",
            "project/fine.swift": "kept",
        ])
        tree.skippedFiles = ["project/image.png"]
        tree.unreadableFiles = ["project/locked.swift"]
        let model = makeModel(tree)

        await model.captureBeforeOperation(
            event: .merge,
            root: projectRoot,
            bufferTexts: [:],
            diskTargets: [projectFile("image.png"), projectFile("locked.swift"), projectFile("fine.swift")]
        )

        XCTAssertTrue(revisions(model, "image.png").isEmpty)
        XCTAssertTrue(revisions(model, "locked.swift").isEmpty)
        XCTAssertEqual(contents(model, "fine.swift"), ["kept"])
    }

    func testTheDiskTargetCapIsEnforcedAndEveryBufferStillLands() async {
        let names = (1...5).map { "project/file\($0).swift" }
        let tree = makeTree(files: Dictionary(uniqueKeysWithValues: names.map { ($0, "disk \($0)") }))
        let model = makeModel(tree, policy: LocalHistoryPolicy(maxPreOperationFiles: 2))

        await model.captureBeforeOperation(
            event: .branch,
            root: projectRoot,
            bufferTexts: [
                projectFile("buffer1.swift"): "one",
                projectFile("buffer2.swift"): "two",
                projectFile("buffer3.swift"): "three",
            ],
            diskTargets: (1...5).map { projectFile("file\($0).swift") }
        )

        XCTAssertEqual(contents(model, "file1.swift"), ["disk project/file1.swift"])
        XCTAssertEqual(contents(model, "file2.swift"), ["disk project/file2.swift"])
        for index in 3...5 {
            XCTAssertTrue(revisions(model, "file\(index).swift").isEmpty, "file\(index) is past the cap")
        }
        // Buffers are never capped: they are already in memory and are what the
        // user would actually lose.
        XCTAssertEqual(contents(model, "buffer1.swift"), ["one"])
        XCTAssertEqual(contents(model, "buffer2.swift"), ["two"])
        XCTAssertEqual(contents(model, "buffer3.swift"), ["three"])
    }

    func testADiskTargetOutsideTheProjectRootIsSkipped() async {
        let tree = makeTree(files: ["elsewhere/stray.swift": "not this project's"])
        let model = makeModel(tree)

        await model.captureBeforeOperation(
            event: .commit,
            root: projectRoot,
            bufferTexts: [:],
            diskTargets: [treeRoot.appendingPathComponent("elsewhere/stray.swift")]
        )

        XCTAssertTrue(tree.writtenPaths.isEmpty)
        XCTAssertFalse(tree.readPaths.contains("elsewhere/stray.swift"))
    }

    func testCaptureBeforeOperationWithNoProjectRootDoesNothing() async {
        let tree = makeTree(files: ["project/a.swift": "text"])
        let model = makeModel(tree)

        await model.captureBeforeOperation(
            event: .commit,
            root: nil,
            bufferTexts: [projectFile("a.swift"): "buffered"],
            diskTargets: [projectFile("a.swift")]
        )

        XCTAssertTrue(tree.writtenPaths.isEmpty)
    }

    // MARK: - Saves

    func testTwoOverlappingSaveCapturesOfOneFileStoreOneRevisionForIdenticalText() async {
        let tree = makeTree()
        let model = makeModel(tree)
        let url = projectFile("a.swift")

        // Both are queued before either runs: the chain, not the caller, is what
        // keeps the second from reading the newest revision before the first
        // wrote it.
        model.captureSaves(urls: [url], root: projectRoot, texts: [url: "same"])
        model.captureSaves(urls: [url], root: projectRoot, texts: [url: "same"])
        await drain(model)

        XCTAssertEqual(contents(model, "a.swift"), ["same"])
    }

    func testTwoOverlappingSaveCapturesOfOneFileStoreBothOrderedForDifferentText() async {
        let tree = makeTree()
        let model = makeModel(tree)
        let url = projectFile("a.swift")

        model.captureSaves(urls: [url], root: projectRoot, texts: [url: "first"])
        model.captureSaves(urls: [url], root: projectRoot, texts: [url: "second"])
        await drain(model)

        XCTAssertEqual(contents(model, "a.swift"), ["second", "first"])
        XCTAssertEqual(revisions(model, "a.swift").map(\.event), [.save, .save])
    }

    func testASaveCaptureSkipsUrlsWithNoTextAndUrlsOutsideTheRoot() async {
        let tree = makeTree()
        let model = makeModel(tree)
        let inside = projectFile("a.swift")
        let outside = treeRoot.appendingPathComponent("elsewhere/a.swift")

        model.captureSaves(
            urls: [inside, outside, projectFile("untouched.swift")],
            root: projectRoot,
            texts: [inside: "kept", outside: "dropped"]
        )
        await drain(model)

        XCTAssertEqual(contents(model, "a.swift"), ["kept"])
        XCTAssertTrue(revisions(model, "untouched.swift").isEmpty)
        // The outside url keys to the bare name `a.swift` through
        // `ProjectFileWalk.relativePath`; refusing it is what keeps it from
        // sharing the real `a.swift`'s history.
        XCTAssertEqual(revisions(model, "a.swift").count, 1)
    }

    func testCaptureBuffersLabelsTheRevisionWithTheGivenEvent() async {
        let tree = makeTree()
        let model = makeModel(tree)
        let url = projectFile("a.swift")

        model.captureBuffers(event: .restore, urls: [url], root: projectRoot, texts: [url: "before the restore"])
        await drain(model)

        XCTAssertEqual(revisions(model, "a.swift").map(\.event), [.restore])
    }

    // MARK: - The quit path

    func testTheSynchronousCaptureHasStoredEverythingByTheTimeItReturns() async {
        let tree = makeTree()
        let model = makeModel(tree)
        let one = projectFile("a.swift")
        let two = projectFile("b.swift")

        model.captureSavesSynchronously(
            urls: [one, two],
            root: projectRoot,
            texts: [one: "a text", two: "b text"]
        )
        // No await between the call and these reads: the whole point of the quit
        // path is that the bytes are already in the store when it returns.
        XCTAssertEqual(contents(model, "a.swift"), ["a text"])
        XCTAssertEqual(contents(model, "b.swift"), ["b text"])
    }

    func testTheSynchronousCaptureDedupsAgainstWhatAnEarlierSaveCaptureWrote() async {
        let tree = makeTree()
        let model = makeModel(tree)
        let url = projectFile("a.swift")

        model.captureSaves(urls: [url], root: projectRoot, texts: [url: "final text"])
        await drain(model)
        let writesBefore = tree.writtenPaths.count

        model.captureSavesSynchronously(urls: [url], root: projectRoot, texts: [url: "final text"])
        XCTAssertEqual(contents(model, "a.swift"), ["final text"])
        XCTAssertEqual(tree.writtenPaths.count, writesBefore, "an identical quit-time capture writes nothing")

        model.captureSavesSynchronously(urls: [url], root: projectRoot, texts: [url: "one last edit"])
        XCTAssertEqual(contents(model, "a.swift"), ["one last edit", "final text"])
    }

    func testTheSynchronousCaptureWithNoProjectRootDoesNothing() {
        let tree = makeTree()
        let model = makeModel(tree)
        let url = projectFile("a.swift")

        model.captureSavesSynchronously(urls: [url], root: nil, texts: [url: "text"])

        XCTAssertTrue(tree.writtenPaths.isEmpty)
    }

    // MARK: - Retention

    func testPruningTheProjectBoundsEveryFileInTheArea() async {
        let tree = makeTree()
        let model = makeModel(tree, policy: LocalHistoryPolicy(revisionsPerFile: 2))
        let store = model.store

        for index in 1...4 {
            store.capture(
                text: "a\(index)",
                root: projectRoot,
                relativePath: "a.swift",
                event: .save,
                now: Date(timeIntervalSince1970: Double(index))
            )
            store.capture(
                text: "b\(index)",
                root: projectRoot,
                relativePath: "nested/b.swift",
                event: .save,
                now: Date(timeIntervalSince1970: Double(index))
            )
        }
        // Captured through the store directly, so the per-file prune each capture
        // does has already run — what follows asserts the sweep, not that.
        XCTAssertEqual(contents(model, "a.swift"), ["a4", "a3"])

        let stale = LocalHistoryModel(
            base: base,
            fileService: tree,
            policy: LocalHistoryPolicy(revisionsPerFile: 1)
        )
        stale.pruneProject(root: projectRoot)
        await drain(stale)

        XCTAssertEqual(contents(stale, "a.swift"), ["a4"])
        XCTAssertEqual(contents(stale, "nested/b.swift"), ["b4"])
    }

    func testPruningWithNoProjectRootDoesNothing() async {
        let tree = makeTree()
        let model = makeModel(tree)

        model.pruneProject(root: nil)
        await drain(model)

        XCTAssertTrue(tree.removedPaths.isEmpty)
    }
}
