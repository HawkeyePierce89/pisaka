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

    func testAFileOutsideTheProjectRootIsTargetedButUnkeyed() async {
        let model = makeModel()
        let outside = treeRoot.appendingPathComponent("elsewhere/a.swift")

        model.open(file: outside, root: projectRoot)

        // The file is remembered — the window has to say something *about* it,
        // and a window that forgot which file it was asked about can only be
        // blank — but it is not keyed, so it has no history and never will.
        XCTAssertEqual(model.fileURL, outside)
        XCTAssertNil(model.relativePath)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.isEmpty)
        XCTAssertTrue(model.isUnsupportedTarget)

        model.open(file: projectFile("a.swift"), root: nil)
        XCTAssertEqual(model.fileURL, projectFile("a.swift"))
        XCTAssertNil(model.relativePath)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.isUnsupportedTarget)
    }

    func testAFileWithNoHistoryIsNotAnUnsupportedTarget() async {
        let model = makeModel()

        model.open(file: projectFile("untouched.swift"), root: projectRoot)
        await waitUntil("the listing to land") { !model.isLoading }

        XCTAssertTrue(model.isEmpty)
        // The two empty states are different answers: this file gets a history
        // the moment the app writes it.
        XCTAssertFalse(model.isUnsupportedTarget)
    }

    func testClearingAnAlreadyClearSelectionCannotCancelTheListingInFlight() async {
        capture("one", "a.swift", at: 1)
        capture("two", "a.swift", at: 2)
        let model = makeModel()

        model.open(file: projectFile("a.swift"), root: projectRoot)
        // Exactly what a window holding its own selection state does one pass
        // after a retarget: echo the clear back. It must not count as a newer
        // question, or the listing just started is discarded and a file that has
        // history reads as a file that has none.
        model.select(nil, currentText: .text("whatever"))

        await waitUntil("the listing to land") { !model.isLoading }
        XCTAssertEqual(model.revisions.count, 2)
        XCTAssertFalse(model.isEmpty)
    }

    func testRetargetingClearsTheRowsBeforeTheNewListingLands() async {
        capture("one", "a.swift", at: 1)
        capture("two", "a.swift", at: 2)
        capture("b", "b.swift", event: .merge, at: 3)
        let model = makeModel()

        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the first listing to land") { model.revisions.count == 2 }
        model.select(model.revisions[0], currentText: .text("two"))
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

        model.select(model.revisions[0], currentText: .text("alpha\ngamma\n"))
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
        model.select(model.revisions[0], currentText: .text("beta"))
        await waitUntil("the content to land") { model.selectedContent != nil }

        model.select(nil, currentText: .text("beta"))

        XCTAssertNil(model.selected)
        XCTAssertNil(model.selectedContent)
        XCTAssertTrue(model.diffRows.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func testAStaleContentLoadIsDiscardedEvenWhenItFinishesLast() async {
        let older = capture("older text", "a.swift", at: 1)
        let newer = capture("newer text", "a.swift", at: 2)
        let model = makeModel()
        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 2 }

        var published: [String?] = []
        let subscription = model.$selectedContent.sink { published.append($0) }
        defer { subscription.cancel() }

        let gate = Gate()
        tree.readGate = (path: storagePath(of: older, "a.swift"), gate: gate)
        model.select(older, currentText: .text("in the buffer"))
        await gate.waitUntilReached()

        // The selection is cleared while the older revision's read is held, so
        // the work that is released *last* is the superseded one — the ordering
        // a serial queue cannot otherwise produce.
        model.select(nil, currentText: .text("in the buffer"))
        gate.release()

        // The signal waited on is a *later* load landing, never a count of hops:
        // the reads run on one serial queue, so the superseded one has both run
        // and had its chance to publish by the time this one's content arrives.
        model.select(newer, currentText: .text("in the buffer"))
        await waitUntil("the newer revision's content to land") { model.selectedContent == "newer text" }

        XCTAssertFalse(published.contains("older text"), "the superseded content reached the window: \(published)")
        XCTAssertTrue(
            tree.readPaths.contains(storagePath(of: older, "a.swift")),
            "the superseded read must actually have run, or this test proves nothing"
        )
    }

    func testARevisionReclaimedBetweenTheListingAndTheClickShowsNothing() async {
        let snapshot = capture("gone by then", "a.swift", at: 1)
        let model = makeModel()
        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 1 }

        // Retention ran between the listing the window is showing and the click.
        tree.files.removeValue(forKey: storagePath(of: snapshot, "a.swift"))

        model.select(snapshot, currentText: .text("current"))
        await waitUntil("the content load to finish") { !model.isLoading }

        XCTAssertNil(model.selectedContent)
        XCTAssertTrue(model.diffRows.isEmpty)
        XCTAssertNil(model.restorePlan)
    }

    // MARK: - Restore

    func testTheRestorePlanCarriesTheRevisionAndTheTextItDisplaces() async {
        let snapshot = capture("the old text", "dir/a.swift", at: 1)
        let model = makeModel()
        model.open(file: projectFile("dir/a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 1 }
        model.select(model.revisions[0], currentText: .text("the current text"))
        await waitUntil("the content to land") { model.selectedContent != nil }

        let plan = model.restorePlan

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

        XCTAssertNil(model.restorePlan, "nothing is selected yet")

        model.select(model.revisions[0], currentText: .text("identical"))
        await waitUntil("the content to land") { model.selectedContent != nil }

        XCTAssertNil(model.restorePlan, "the buffer already holds these bytes")
        // The plan is answered against the very text the diff was computed from,
        // so a buffer that has since been edited is a *new* selection, not a
        // second question asked of the old one.
        model.select(model.revisions[0], currentText: .text("edited since"))
        await waitUntil("the second content load to land") { !model.isLoading }
        XCTAssertNotNil(model.restorePlan)
    }

    /// The sameness test is over bytes, not over canonical equivalence.
    ///
    /// A revision is identified by a SHA-256 of its UTF-8 bytes, so a decomposed
    /// and a precomposed spelling of one word are two genuinely different
    /// revisions in the store — and Swift's `==` calls them equal. Comparing that
    /// way would arm the Restore button and then plan nothing: the click would do
    /// nothing at all, and the buffer would keep the encoding the user asked to
    /// replace.
    func testARevisionDifferingOnlyByUnicodeNormalizationIsStillRestorable() async {
        let precomposed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        XCTAssertEqual(precomposed, decomposed, "the two spellings are canonically equivalent")
        XCTAssertNotEqual(
            Array(precomposed.utf8),
            Array(decomposed.utf8),
            "…and are nevertheless different bytes, which is what the store keys on"
        )

        capture(precomposed, "a.swift", at: 1)
        let model = makeModel()
        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 1 }
        model.select(model.revisions[0], currentText: .text(decomposed))
        await waitUntil("the content to land") { model.selectedContent != nil }

        let plan = model.restorePlan
        XCTAssertEqual(plan?.text.utf8.map { $0 }, Array(precomposed.utf8))
        XCTAssertEqual(plan?.captureText.utf8.map { $0 }, Array(decomposed.utf8))
    }

    // MARK: - Refreshing the standing selection

    /// The plan is resolved once, when the selection lands — so the one part of
    /// this window that is an *action* can go stale while the panes merely look
    /// stale. Coming back to the window re-asks it.
    ///
    /// This is the case the published-plan design would otherwise be strictly
    /// worse at than the click-time question it replaced: a revision the buffer
    /// held when the row was clicked greys Restore out, and an edit made in
    /// another window afterwards would leave it greyed with nothing to un-grey
    /// it.
    func testRefreshingRearmsAPlanTheBufferHasSinceDivergedFrom() async {
        capture("identical", "a.swift", at: 1)
        let model = makeModel()
        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 1 }

        model.select(model.revisions[0], currentText: .text("identical"))
        await waitUntil("the content to land") { model.selectedContent != nil }
        XCTAssertNil(model.restorePlan, "the buffer holds these bytes, so there is nothing to restore")

        model.refreshSelection(currentText: .text("edited since"))
        await waitUntil("the refresh to land") { !model.isLoading }

        XCTAssertEqual(model.restorePlan?.text, "identical")
        XCTAssertEqual(model.restorePlan?.captureText, "edited since")
        XCTAssertEqual(model.selected, model.revisions[0], "the refresh must not move the selection")
    }

    /// The mirror direction, and the one the published-plan design was made for:
    /// a buffer that has come to *match* the selected revision disarms the button
    /// rather than leaving an armed one whose click does nothing.
    func testRefreshingDisarmsAPlanTheBufferHasComeToMatch() async {
        capture("the old text", "a.swift", at: 1)
        let model = makeModel()
        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 1 }

        model.select(model.revisions[0], currentText: .text("something else"))
        await waitUntil("the content to land") { model.selectedContent != nil }
        XCTAssertNotNil(model.restorePlan)

        model.refreshSelection(currentText: .text("the old text"))
        await waitUntil("the refresh to land") { model.restorePlan == nil }

        XCTAssertTrue(model.diffRows.allSatisfy { $0.kind == .unchanged }, "the pane must agree with the button")
    }

    /// No selection is no question — and therefore no read. The window becomes
    /// key every time the user clicks it, so a refresh that resolved a
    /// `.deferred` current text with nothing selected would read disk for an
    /// answer nothing could use.
    func testRefreshingWithNoSelectionAsksNothingAndReadsNothing() async {
        capture("the old text", "a.swift", at: 1)
        let model = makeModel()
        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 1 }

        let record = ThreadRecord()
        model.refreshSelection(currentText: .deferred {
            record.note(isMain: Thread.isMainThread)
            return "on disk"
        })

        XCTAssertEqual(record.calls, 0)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.restorePlan)
        XCTAssertEqual(model.revisions.count, 1, "the standing listing must survive a refresh that asks nothing")
    }

    /// A current text that has not moved is not a question either. The window
    /// becomes key on every focus of it, and re-running the hop regardless costs
    /// a store read and a whole-document diff per focus — and sets `isLoading`,
    /// so the footer's spinner flashes on an event carrying no news.
    ///
    /// `isLoading` is the assertion because `load` raises it *synchronously*: a
    /// refresh that took the hop would leave it true on the very next line.
    func testRefreshingWithAnUnchangedBufferTakesNoHopAtAll() async {
        capture("the old text", "a.swift", at: 1)
        let model = makeModel()
        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 1 }

        model.select(model.revisions[0], currentText: .text("in the buffer"))
        await waitUntil("the content to land") { model.selectedContent != nil }
        let plan = model.restorePlan
        XCTAssertNotNil(plan)

        model.refreshSelection(currentText: .text("in the buffer"))

        XCTAssertFalse(model.isLoading, "an unchanged current text must not re-enter the hop")
        XCTAssertEqual(model.restorePlan, plan, "and must leave the standing plan exactly as it was")
        XCTAssertEqual(model.selectedContent, "the old text")
    }

    /// The short-circuit is the `.text(_:)` case's alone: `.deferred(_:)` cannot
    /// be settled without the read it defers, so it re-asks even when the answer
    /// turns out to be the same text.
    func testRefreshingWithADeferredCurrentTextAlwaysReAsks() async {
        capture("the old text", "a.swift", at: 1)
        let model = makeModel()
        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 1 }

        model.select(model.revisions[0], currentText: .text("on disk"))
        await waitUntil("the content to land") { model.selectedContent != nil }

        let record = ThreadRecord()
        model.refreshSelection(currentText: .deferred {
            record.note(isMain: Thread.isMainThread)
            return "on disk"
        })
        await waitUntil("the refresh to land") { !model.isLoading }

        XCTAssertEqual(record.calls, 1)
        XCTAssertEqual(record.onMain, 0, "and it is still resolved off the main actor")
    }

    /// The sameness test the short-circuit makes is `NSString`'s, like every
    /// other one in this feature: a buffer rewritten from one Unicode spelling of
    /// a word to another *has* moved — the store keeps the two as different
    /// revisions — and Swift's canonical `==` would call it unchanged and skip
    /// the refresh the plan needs.
    func testRefreshingComparesTheCurrentTextByBytes() async {
        let precomposed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        capture(precomposed, "a.swift", at: 1)
        let model = makeModel()
        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 1 }

        model.select(model.revisions[0], currentText: .text(precomposed))
        await waitUntil("the content to land") { model.selectedContent != nil }
        XCTAssertNil(model.restorePlan, "the buffer holds these very bytes")

        model.refreshSelection(currentText: .text(decomposed))
        await waitUntil("the refresh to land") { model.restorePlan != nil }

        XCTAssertEqual(model.restorePlan?.text.utf8.map { $0 }, Array(precomposed.utf8))
        XCTAssertEqual(model.restorePlan?.captureText.utf8.map { $0 }, Array(decomposed.utf8))
    }

    /// A refresh takes the generation token on the same terms a selection does,
    /// so a refresh held up behind a slow read cannot publish over the selection
    /// that superseded it.
    func testASupersededRefreshPublishesNothing() async {
        let older = capture("older text", "a.swift", at: 1)
        let newer = capture("newer text", "a.swift", at: 2)
        let model = makeModel()
        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 2 }

        model.select(older, currentText: .text("in the buffer"))
        await waitUntil("the content to land") { model.selectedContent != nil }

        let gate = Gate()
        tree.readGate = (path: storagePath(of: older, "a.swift"), gate: gate)
        model.refreshSelection(currentText: .text("edited since"))
        await gate.waitUntilReached()

        model.select(newer, currentText: .text("in the buffer"))
        gate.release()

        await waitUntil("the newer revision's plan to land") { model.restorePlan?.snapshot == newer }
        XCTAssertEqual(model.selectedContent, "newer text")
        XCTAssertEqual(model.restorePlan?.captureText, "in the buffer")
    }

    // MARK: - The current-text seam

    /// A `.deferred` current text is a *disk read*, and the whole reason it is a
    /// closure rather than a `String` is that the window must not perform it on
    /// the main actor. Where it runs is therefore the contract, and it is
    /// recorded inside the closure itself: nothing observed afterwards could tell
    /// a read that happened on the main thread from one that did not.
    func testADeferredCurrentTextIsResolvedOffTheMainThread() async {
        capture("the old text", "a.swift", at: 1)
        let model = makeModel()
        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 1 }

        let record = ThreadRecord()
        model.select(model.revisions[0], currentText: .deferred {
            record.note(isMain: Thread.isMainThread)
            return "read from disk"
        })
        await waitUntil("the content to land") { !model.isLoading }

        XCTAssertEqual(record.calls, 1, "the deferred read runs exactly once per selection")
        XCTAssertEqual(record.onMain, 0, "the deferred read must not run on the main thread")
        // …and it is genuinely the text the diff and the plan were built from.
        XCTAssertEqual(model.diffRows, LineDiff.rows(old: "the old text", new: "read from disk"))
        XCTAssertEqual(model.restorePlan?.captureText, "read from disk")
    }

    /// The refusal the `.deferred` path actually exists for: a file no tab
    /// holds, whose disk copy already *is* the revision. The resolved text
    /// has to reach `plannedRestore()` — not just `diffRows` — or the button
    /// would be armed under a pane showing no differences.
    func testADeferredCurrentTextMatchingTheRevisionPlansNothing() async {
        capture("on disk", "a.swift", at: 1)
        let model = makeModel()
        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 1 }

        model.select(model.revisions[0], currentText: .deferred { "on disk" })
        await waitUntil("the content to land") { model.selectedContent != nil }

        XCTAssertNil(model.restorePlan, "the disk copy already holds these bytes")
        XCTAssertTrue(model.diffRows.allSatisfy { $0.kind == .unchanged })
    }

    /// Clearing the pane takes no hop, so it must not pay for one either: a
    /// deselection now costs no file read at all, where a `String` parameter made
    /// every one of them read disk before the call.
    func testDeselectingNeverResolvesTheDeferredRead() async {
        capture("the old text", "a.swift", at: 1)
        let model = makeModel()
        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 1 }
        model.select(model.revisions[0], currentText: .text("in the buffer"))
        await waitUntil("the content to land") { model.selectedContent != nil }

        let record = ThreadRecord()
        model.select(nil, currentText: .deferred {
            record.note(isMain: Thread.isMainThread)
            return "never asked for"
        })

        XCTAssertEqual(record.calls, 0)
        XCTAssertNil(model.selected)
    }

    // MARK: - The published restore plan

    /// The plan is state, not a question the view may ask later, so everything
    /// that clears the selection clears it too — a retarget and a deselection
    /// both, synchronously, before anything is in flight.
    func testTheRestorePlanClearsOnRetargetAndOnDeselect() async {
        capture("the old text", "a.swift", at: 1)
        capture("b", "b.swift", at: 2)
        let model = makeModel()
        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 1 }
        model.select(model.revisions[0], currentText: .text("the current text"))
        await waitUntil("the content to land") { model.selectedContent != nil }
        XCTAssertNotNil(model.restorePlan)

        model.select(nil, currentText: .text("the current text"))
        XCTAssertNil(model.restorePlan, "a deselection clears the plan synchronously")

        model.select(model.revisions[0], currentText: .text("the current text"))
        await waitUntil("the content to land again") { model.restorePlan != nil }

        model.open(file: projectFile("b.swift"), root: projectRoot)
        XCTAssertNil(model.restorePlan, "a retarget clears the plan synchronously")
        // …and it stays cleared once the new listing lands, because nothing is
        // selected in it yet.
        await waitUntil("the second listing to land") { !model.isLoading }
        XCTAssertNil(model.restorePlan)
    }

    /// A plan describes a *write*, so a superseded selection publishing one is
    /// worse than a superseded diff: the button would be armed with a revision
    /// of a file the window is no longer showing.
    func testASupersededSelectionPublishesNoRestorePlan() async {
        let older = capture("older text", "a.swift", at: 1)
        let newer = capture("newer text", "a.swift", at: 2)
        let model = makeModel()
        model.open(file: projectFile("a.swift"), root: projectRoot)
        await waitUntil("the listing to land") { model.revisions.count == 2 }

        var published: [LocalHistoryRestore?] = []
        let subscription = model.$restorePlan.sink { published.append($0) }
        defer { subscription.cancel() }

        let gate = Gate()
        tree.readGate = (path: storagePath(of: older, "a.swift"), gate: gate)
        model.select(older, currentText: .text("in the buffer"))
        await gate.waitUntilReached()

        // Superseded while its read is held, so the discarded work is the one
        // that finishes *last* on the serial queue.
        model.select(nil, currentText: .text("in the buffer"))
        gate.release()

        model.select(newer, currentText: .text("in the buffer"))
        await waitUntil("the newer revision's plan to land") { model.restorePlan?.snapshot == newer }

        XCTAssertFalse(
            published.contains { $0?.snapshot == older },
            "the superseded selection's plan reached the window: \(published)"
        )
    }
}

/// Where a `.deferred` current text ran, recorded from inside the closure.
///
/// A plain `final class` behind a lock rather than an actor: the closure is
/// synchronous by contract — it is what a `readTextIfNotBinary` call looks like —
/// so it cannot `await`, and the test reads the counts only after the selection
/// it belongs to has landed on the main actor.
private final class ThreadRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _onMain = 0

    var calls: Int { lock.withLock { _calls } }
    var onMain: Int { lock.withLock { _onMain } }

    func note(isMain: Bool) {
        lock.withLock {
            _calls += 1
            if isMain { _onMain += 1 }
        }
    }
}
