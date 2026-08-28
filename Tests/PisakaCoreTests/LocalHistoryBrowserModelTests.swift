import Combine
import XCTest
@testable import PisakaCore

/// The browser model is a reader whose every answer arrives late, so what is
/// asserted here is *what reaches the window* rather than what the store holds
/// (`LocalHistoryStoreTests` already pins that): that a retarget clears before it
/// loads, that a superseded listing or content load publishes nothing at all,
/// that a file nobody has ever saved is an empty window rather than an error, and
/// that the restore plan is the one place the two texts a restore needs are
/// carried together.
///
/// Staleness is staged causally, never with a delay: the work is held inside the
/// `StubFileTree` on a `Gate` while the model is retargeted on the main actor,
/// and the values that did (or did not) reach the published properties are
/// recorded through a Combine sink — the final state alone cannot tell a
/// discarded publish from one that was immediately overwritten.
@MainActor
final class LocalHistoryBrowserModelTests: XCTestCase {
    private let treeRoot = URL(fileURLWithPath: "/work")
    private let projectRoot = URL(fileURLWithPath: "/work/project")

    private var base: URL { treeRoot.appendingPathComponent("LocalHistory") }

    private var tree = StubFileTree(root: URL(fileURLWithPath: "/work"), files: [:])
    private var store = LocalHistoryStore(
        layout: LocalHistoryLayout(base: URL(fileURLWithPath: "/work/LocalHistory")),
        fileService: StubFileTree(root: URL(fileURLWithPath: "/work"), files: [:])
    )

    override func setUp() {
        super.setUp()
        tree = StubFileTree(root: treeRoot, files: [:])
        store = LocalHistoryStore(layout: LocalHistoryLayout(base: base), fileService: tree)
    }

    private func makeModel() -> LocalHistoryBrowserModel {
        LocalHistoryBrowserModel(store: store)
    }

    private func projectFile(_ relativePath: String) -> URL {
        projectRoot.appendingPathComponent(relativePath)
    }

    /// Put one revision of `relativePath` in the store, at a stated instant so
    /// the order the window sees is the order this file states.
    @discardableResult
    private func capture(
        _ text: String,
        _ relativePath: String,
        event: LocalHistoryEvent = .save,
        at seconds: Double
    ) -> LocalHistorySnapshot {
        let snapshot = store.capture(
            text: text,
            root: projectRoot,
            relativePath: relativePath,
            event: event,
            now: Date(timeIntervalSince1970: seconds)
        )
        guard let snapshot else {
            XCTFail("the fixture capture of \(relativePath) must land")
            return LocalHistorySnapshot(fileName: "", timestamp: .distantPast, event: event, contentHash: "")
        }
        return snapshot
    }

    /// Where the stub keeps one snapshot's bytes — the key `StubFileTree.readGate`
    /// is armed with.
    private func storagePath(of snapshot: LocalHistorySnapshot, _ relativePath: String) -> String {
        let directory = store.layout.fileDirectory(forRoot: projectRoot, relativePath: relativePath)
        return tree.relativePath(of: directory.appendingPathComponent(snapshot.fileName))
    }

    /// Spin the main actor until `condition` holds, failing loudly rather than
    /// hanging or passing vacuously. The model exposes no task handle — it is the
    /// window's state that is the contract — so the published value *is* the
    /// signal waited on.
    private func waitUntil(
        _ description: String,
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(description)", file: file, line: line)
                return
            }
            await Task.yield()
        }
    }

    // MARK: - Targeting

    func testOpeningAFileListsItsRevisionsNewestFirst() async {
        capture("one", "a.swift", at: 1)
        capture("two", "a.swift", event: .commit, at: 2)
        let model = makeModel()

        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { !model.isLoading }

        XCTAssertEqual(model.fileURL, projectFile("a.swift"))
        XCTAssertEqual(model.relativePath, "a.swift")
        XCTAssertEqual(model.revisions.map(\.event), [.commit, .save])
        XCTAssertFalse(model.isEmpty)
    }

    func testAFileWithNoHistoryIsEmptyRatherThanAnError() async {
        capture("elsewhere", "other.swift", at: 1)
        let model = makeModel()

        model.open(file: projectFile("untouched.swift"), root: projectRoot)
        await waitUntil("the listing to land") { !model.isLoading }

        XCTAssertTrue(model.revisions.isEmpty)
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.relativePath, "untouched.swift")
    }

    func testAFileOutsideTheProjectRootIsRefusedWithoutTargetingAnything() async {
        let model = makeModel()

        model.open(file: treeRoot.appendingPathComponent("elsewhere/a.swift"), root: projectRoot)

        XCTAssertNil(model.fileURL)
        XCTAssertNil(model.relativePath)
        XCTAssertFalse(model.isLoading)
        // Nothing is targeted, so the window is not "empty" either — there is no
        // file whose history could be shown.
        XCTAssertFalse(model.isEmpty)

        model.open(file: projectFile("a.swift"), root: nil)
        XCTAssertNil(model.fileURL)
        XCTAssertFalse(model.isLoading)
    }

    func testRetargetingClearsTheRowsBeforeTheNewListingLands() async {
        capture("one", "a.swift", at: 1)
        capture("two", "a.swift", at: 2)
        capture("b", "b.swift", event: .merge, at: 3)
        let model = makeModel()

        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the first listing to land") { model.revisions.count == 2 }
        model.select(model.revisions[0], currentText: "two")
        await waitUntil("the content to land") { model.selectedContent != nil }

        let gate = Gate()
        tree.listingGate = gate
        model.open(file: projectFile("b.swift"), root: projectRoot)

        // Synchronously, before the new listing has read anything: the previous
        // file's rows, selection and diff are gone.
        XCTAssertTrue(model.revisions.isEmpty)
        XCTAssertNil(model.selected)
        XCTAssertNil(model.selectedContent)
        XCTAssertTrue(model.diffRows.isEmpty)
        XCTAssertEqual(model.fileURL, projectFile("b.swift"))

        gate.release()
        await waitUntil("the second listing to land") { !model.isLoading }
        XCTAssertEqual(model.revisions.map(\.event), [.merge])
    }

    func testAStaleListingCannotPublishOverANewerOne() async {
        capture("one", "a.swift", at: 1)
        capture("two", "a.swift", at: 2)
        capture("b", "b.swift", event: .merge, at: 3)
        let model = makeModel()

        var published: [[LocalHistorySnapshot]] = []
        let subscription = model.$revisions.sink { published.append($0) }
        defer { subscription.cancel() }

        let gate = Gate()
        tree.listingGate = gate
        model.open(file: projectFile("a.swift"), root: projectRoot)
        await gate.waitUntilReached()

        // The window is retargeted while the first listing is held mid-read.
        model.open(file: projectFile("b.swift"), root: projectRoot)
        gate.release()

        await waitUntil("the second listing to land") { model.revisions.count == 1 }
        XCTAssertEqual(model.revisions.map(\.event), [.merge])
        // The queue is serial, so the superseded listing finished *before* the
        // one that won: had it published, its two rows would be in the record.
        XCTAssertTrue(published.allSatisfy { $0.count != 2 }, "the stale listing published \(published)")
    }

    // MARK: - Selection

    func testSelectingARevisionProducesTheDiffAgainstTheCurrentText() async {
        capture("alpha\nbeta\n", "a.swift", at: 1)
        let model = makeModel()
        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 1 }

        model.select(model.revisions[0], currentText: "alpha\ngamma\n")
        await waitUntil("the content to land") { !model.isLoading }

        XCTAssertEqual(model.selectedContent, "alpha\nbeta\n")
        XCTAssertEqual(model.diffRows, LineDiff.rows(old: "alpha\nbeta\n", new: "alpha\ngamma\n"))
        XCTAssertEqual(model.diffRows.map(\.kind), [.unchanged, .modified])
    }

    func testSelectingNothingClearsThePaneWithoutAHop() async {
        capture("alpha", "a.swift", at: 1)
        let model = makeModel()
        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 1 }
        model.select(model.revisions[0], currentText: "beta")
        await waitUntil("the content to land") { model.selectedContent != nil }

        model.select(nil, currentText: "beta")

        XCTAssertNil(model.selected)
        XCTAssertNil(model.selectedContent)
        XCTAssertTrue(model.diffRows.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func testAStaleContentLoadIsDiscardedEvenWhenItFinishesLast() async {
        let older = capture("older text", "a.swift", at: 1)
        capture("newer text", "a.swift", at: 2)
        let model = makeModel()
        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 2 }

        var published: [String?] = []
        let subscription = model.$selectedContent.sink { published.append($0) }
        defer { subscription.cancel() }

        let gate = Gate()
        tree.readGate = (path: storagePath(of: older, "a.swift"), gate: gate)
        model.select(older, currentText: "in the buffer")
        await gate.waitUntilReached()

        // The selection is cleared while the older revision's read is held, so
        // the work that is released *last* is the superseded one — the ordering
        // a serial queue cannot otherwise produce.
        model.select(nil, currentText: "in the buffer")
        gate.release()

        let storagePath = storagePath(of: older, "a.swift")
        await waitUntil("the released read to have run") { self.tree.readPaths.contains(storagePath) }
        // One more turn of the main actor than the discarded publish would have
        // needed, and it still never arrives.
        await Task.yield()
        await Task.yield()

        XCTAssertNil(model.selectedContent)
        XCTAssertTrue(model.diffRows.isEmpty)
        XCTAssertFalse(published.contains("older text"), "the superseded content reached the window: \(published)")
    }

    func testARevisionReclaimedBetweenTheListingAndTheClickShowsNothing() async {
        let snapshot = capture("gone by then", "a.swift", at: 1)
        let model = makeModel()
        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 1 }

        // Retention ran between the listing the window is showing and the click.
        tree.files.removeValue(forKey: storagePath(of: snapshot, "a.swift"))

        model.select(snapshot, currentText: "current")
        await waitUntil("the content load to finish") { !model.isLoading }

        XCTAssertNil(model.selectedContent)
        XCTAssertTrue(model.diffRows.isEmpty)
        XCTAssertNil(model.restore(currentText: "current"))
    }

    // MARK: - Restore

    func testTheRestorePlanCarriesTheRevisionAndTheTextItDisplaces() async {
        let snapshot = capture("the old text", "dir/a.swift", at: 1)
        let model = makeModel()
        model.open(file: projectFile("dir/a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 1 }
        model.select(model.revisions[0], currentText: "the current text")
        await waitUntil("the content to land") { model.selectedContent != nil }

        let plan = model.restore(currentText: "the current text")

        XCTAssertEqual(plan?.fileURL, projectFile("dir/a.swift"))
        XCTAssertEqual(plan?.root, projectRoot)
        XCTAssertEqual(plan?.relativePath, "dir/a.swift")
        XCTAssertEqual(plan?.snapshot, snapshot)
        XCTAssertEqual(plan?.text, "the old text")
        // The pre-restore capture is part of the plan, not a step the caller has
        // to remember: the bytes it displaces travel with it.
        XCTAssertEqual(plan?.captureText, "the current text")
        XCTAssertEqual(LocalHistoryRestore.event, .restore)
    }

    func testTheRestorePlanIsNilWithNoSelectionAndForAnIdenticalRevision() async {
        capture("identical", "a.swift", at: 1)
        let model = makeModel()
        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 1 }

        XCTAssertNil(model.restore(currentText: "identical"), "nothing is selected yet")

        model.select(model.revisions[0], currentText: "identical")
        await waitUntil("the content to land") { model.selectedContent != nil }

        XCTAssertNil(model.restore(currentText: "identical"), "the buffer already holds these bytes")
        XCTAssertNotNil(model.restore(currentText: "edited since"))
    }
}
