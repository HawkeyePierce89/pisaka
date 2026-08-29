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

    /// The ceiling is enforced by the *read*, before a big file is ever pulled
    /// into memory — the stated reason `readTextIfNotBinary(url:maxBytes:)` is
    /// the one gate on this path rather than the policy's size rule, which only
    /// ever sees a `String` that has already been read.
    func testAnOversizeDiskTargetIsNeverReadIntoMemory() async {
        let tree = makeTree(files: [
            "project/huge.swift": String(repeating: "x", count: 200),
            "project/small.swift": "kept",
        ])
        let model = makeModel(tree, policy: LocalHistoryPolicy(maxContentBytes: 100))

        await model.captureBeforeOperation(
            event: .replace,
            root: projectRoot,
            bufferTexts: [:],
            diskTargets: [projectFile("huge.swift"), projectFile("small.swift")]
        )

        XCTAssertTrue(revisions(model, "huge.swift").isEmpty)
        XCTAssertEqual(contents(model, "small.swift"), ["kept"])
    }

    /// A url reaching the root through `..` keys to its *bare name* through
    /// `ProjectFileWalk.relativePath(of:under:)`, which degrades rather than
    /// refusing. Keyed on that answer the file would share its history with a
    /// root-level file of the same name — two unrelated files, one directory,
    /// each one's revisions offered as the other's. Canonicalizing first settles
    /// it by resolving the `..` outright, so the file is keyed where it actually
    /// lives rather than being either refused or collided.
    func testAUrlThatReachesTheRootThroughDotDotIsKeyedWhereTheFileActuallyLives() async {
        let tree = makeTree(files: ["project/sub/a.swift": "the real one"])
        let model = makeModel(tree)
        let sideways = treeRoot.appendingPathComponent("other/../project/sub/a.swift")
        XCTAssertEqual(ProjectFileWalk.relativePath(of: sideways, under: projectRoot), "a.swift")

        XCTAssertEqual(LocalHistoryModel.relativePath(of: sideways, under: projectRoot), "sub/a.swift")

        model.captureSaves(urls: [sideways], root: projectRoot, texts: [sideways: "edited"])
        await drain(model)

        XCTAssertTrue(revisions(model, "a.swift").isEmpty, "No history under the bare name.")
        XCTAssertEqual(contents(model, "sub/a.swift"), ["edited"])
    }

    /// The disk targets of four of the six pre-operation captures are built from
    /// the repository root `git rev-parse --show-toplevel` reports, which is
    /// always *physical*, while `projectRoot` is stored as the user spelled it.
    /// Compared lexically those two directories are different, and every disk
    /// target would be dropped — silently, leaving the labelled capture with open
    /// buffers only. Staged with a real symlink, because that divergence is only
    /// reproducible through one: the resolution is the file system's, not a
    /// string rule this test could imitate.
    func testDiskTargetsSpelledAsGitReportsThemAreCapturedUnderTheUsersSpelling() async throws {
        let manager = FileManager.default
        let physical = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("local-history-\(UUID().uuidString)", isDirectory: true)
        let symlinked = physical.deletingLastPathComponent()
            .appendingPathComponent(physical.lastPathComponent + "-link", isDirectory: true)
        // The project itself exists on disk too, because that is what the
        // resolution needs: `URL.resolvingSymlinksInPath()` resolves nothing for
        // a path that is not there. The *contents* still come from the stub.
        try manager.createDirectory(
            at: physical.appendingPathComponent("project", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data().write(to: physical.appendingPathComponent("project/a.swift"))
        try manager.createSymbolicLink(at: symlinked, withDestinationURL: physical)
        defer {
            try? manager.removeItem(at: symlinked)
            try? manager.removeItem(at: physical)
        }

        // The tree — like the disk, and like what `git rev-parse --show-toplevel`
        // reports — knows only the physical spelling; the user opened the folder
        // through the symlink, so that is what `projectRoot` holds.
        let tree = StubFileTree(root: physical, files: ["project/a.swift": "on disk"])
        let model = LocalHistoryModel(
            base: physical.appendingPathComponent("LocalHistory"),
            fileService: tree,
            policy: LocalHistoryPolicy(),
            now: StepClock().next
        )
        let userRoot = symlinked.appendingPathComponent("project", isDirectory: true)

        await model.captureBeforeOperation(
            event: .revert,
            root: userRoot,
            bufferTexts: [:],
            diskTargets: [physical.appendingPathComponent("project/a.swift")]
        )

        XCTAssertEqual(
            model.store.revisions(root: userRoot, relativePath: "a.swift").map(\.event),
            [.revert],
            "The disk target was dropped because the two roots were compared lexically."
        )
    }

    /// The wait is on everything already queued — including the project-open
    /// sweep — so an operation with nothing to capture must not join the queue at
    /// all: it is holding the writer bracket while it waits.
    func testCaptureBeforeOperationWithNothingToCaptureDoesNotJoinTheChain() async {
        let tree = makeTree(files: ["project/a.swift": "text"])
        let model = makeModel(tree)

        let gate = Gate()
        tree.listingGate = gate
        model.pruneStore()
        await gate.waitUntilReached()

        // The sweep is demonstrably mid-read. A capture with no buffers and no
        // disk targets must return anyway — the deadline is what turns "it joined
        // the queue" into a failure instead of a hang.
        let returned = expectation(description: "the capture returns while the sweep is held")
        Task {
            await model.captureBeforeOperation(
                event: .commit,
                root: projectRoot,
                bufferTexts: [:],
                diskTargets: []
            )
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 5)

        gate.release()
        await drain(model)
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

    /// The quit capture bypasses the chain by design, so a capture queued behind
    /// something slow — here the store-wide sweep — can reach the disk *after* it.
    /// What keeps that from filing older bytes as the newest revision is that the
    /// timestamp is read in the entry point, before the work joins the chain: the
    /// held unit carries the instant its text was handed over, not the instant it
    /// finally ran.
    func testACaptureHeldBehindTheSweepDoesNotOutStampTheQuitCapture() async {
        let tree = makeTree()
        let model = makeModel(tree)
        let url = projectFile("a.swift")

        // The sweep occupies the chain and is held on its very first listing, so
        // the save capture queued behind it has not started at all.
        let gate = Gate()
        tree.listingGate = gate
        model.pruneStore()
        await gate.waitUntilReached()
        model.captureSaves(urls: [url], root: projectRoot, texts: [url: "older"])

        // The user edits again and quits while that is still queued.
        model.captureSavesSynchronously(urls: [url], root: projectRoot, texts: [url: "newer"])
        XCTAssertEqual(contents(model, "a.swift"), ["newer"])

        gate.release()
        await drain(model)

        XCTAssertEqual(
            contents(model, "a.swift"),
            ["newer", "older"],
            "the held capture lands last but is older, and must be listed as such"
        )
    }

    func testTheSynchronousCaptureWithNoProjectRootDoesNothing() {
        let tree = makeTree()
        let model = makeModel(tree)
        let url = projectFile("a.swift")

        model.captureSavesSynchronously(urls: [url], root: nil, texts: [url: "text"])

        XCTAssertTrue(tree.writtenPaths.isEmpty)
    }

    // MARK: - Retention

    func testPruningTheStoreBoundsEveryFileInTheArea() async {
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
        stale.pruneStore()
        await drain(stale)

        XCTAssertEqual(contents(stale, "a.swift"), ["a4"])
        XCTAssertEqual(contents(stale, "nested/b.swift"), ["b4"])
    }

    func testPruningAnEmptyStoreDoesNothing() async {
        let tree = makeTree()
        let model = makeModel(tree)

        model.pruneStore()
        await drain(model)

        XCTAssertTrue(tree.removedPaths.isEmpty)
    }

    /// The sweep takes no root, and this is why: a project that is never opened
    /// again is reclaimed by nothing else, so its history would outlive every
    /// stated retention bound.
    func testPruningTheStoreReclaimsAProjectThatIsNotTheOneBeingOpened() async {
        let tree = makeTree()
        let model = makeModel(tree, policy: LocalHistoryPolicy(revisionsPerFile: 1))
        let store = model.store
        let abandoned = URL(fileURLWithPath: "/abandoned")

        for index in 1...3 {
            store.capture(
                text: "old\(index)",
                root: abandoned,
                relativePath: "a.swift",
                event: .save,
                now: Date(timeIntervalSince1970: Double(index))
            )
        }
        // Captured through the store directly, so each capture's own per-file
        // prune has already run; a second store with the tighter policy is what
        // makes the sweep the only thing that can bound what is there.
        let stale = LocalHistoryModel(
            base: base,
            fileService: tree,
            policy: LocalHistoryPolicy(revisionsPerFile: 1)
        )
        XCTAssertEqual(
            stale.store.revisions(root: abandoned, relativePath: "a.swift").count,
            1
        )

        for index in 1...3 {
            store.capture(
                text: "new\(index)",
                root: abandoned,
                relativePath: "a.swift",
                event: .save,
                now: Date(timeIntervalSince1970: Double(10 + index))
            )
        }

        // The folder being opened is a different project entirely.
        model.pruneStore()
        await drain(model)

        XCTAssertEqual(
            store.revisions(root: abandoned, relativePath: "a.swift").map(\.contentHash).count,
            1,
            "The abandoned project's area was swept even though nothing opened it."
        )
    }

    /// A project area with nothing left in it is removed, so the store the user is
    /// invited to inspect in Finder does not accumulate empty directories for
    /// projects that are gone. Staged with `.partial` debris rather than by aging
    /// revisions out, because retention alone cannot empty a directory holding a
    /// real snapshot: the newest one always survives.
    func testPruningTheStoreRemovesAProjectAreaLeftEmpty() async {
        let tree = makeTree()
        let model = makeModel(tree)
        let store = model.store
        let abandoned = URL(fileURLWithPath: "/abandoned")

        store.capture(
            text: "gone",
            root: abandoned,
            relativePath: "a.swift",
            event: .save,
            now: Date(timeIntervalSince1970: 0)
        )
        // Everything in the area is a leftover from an interrupted write, so the
        // file directory prunes to nothing and the area follows it.
        let directory = store.layout.fileDirectory(forRoot: abandoned, relativePath: "a.swift")
        let name = store.revisions(root: abandoned, relativePath: "a.swift")[0].fileName
        try? tree.move(
            from: directory.appendingPathComponent(name),
            to: directory.appendingPathComponent(name + ".partial")
        )

        model.pruneStore()
        await drain(model)

        let project = store.layout.projectDirectory(forRoot: abandoned)
        XCTAssertTrue(
            tree.removedPaths.contains { $0.hasSuffix(project.lastPathComponent) },
            "The project area itself was removed, not just the file directory inside it."
        )
    }
}
