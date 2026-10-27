import Combine
import XCTest
@testable import PisakaCore

/// The model half of the diagnostics channel: the D32 acceptance gate (a push
/// lands only when its version is the last synced one and nothing was typed
/// between that sync and the push), the incremental shift across edits, the
/// wholesale-replacement clear, document independence, and the folder change
/// that drops every push until the controller re-syncs.
///
/// Pure main-actor tests — no transport, no awaits; the events are built by
/// hand exactly as `LSPWorkspace.route` emits them.
@MainActor
final class DiagnosticsModelTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/pkg/Sources/App/main.swift")
    private let otherURL = URL(fileURLWithPath: "/tmp/pkg/Sources/App/util.swift")
    private let root = URL(fileURLWithPath: "/tmp/pkg", isDirectory: true)
    private let serverID = "sourcekit-lsp"

    /// "aaa\nbbb\nccc\n" — lines at [0, 4, 8, 12].
    private let lineStarts = [0, 4, 8, 12]

    private var model: DiagnosticsModel!

    private var serverKey: DiagnosticStore.ServerKey {
        DiagnosticStore.ServerKey(serverID: serverID, root: root.path)
    }

    override func setUp() {
        super.setUp()
        model = DiagnosticsModel()
    }

    // MARK: - Fixtures

    /// The edit inserting "XX" at offset 5: new text "aaa\nXXbbb\nccc\n".
    /// The touched pre-edit span is empty ([5, 5)), so only diagnostics
    /// *overlapping* offset 5 drop.
    private func insertAtFive() -> (previous: [Int], new: [Int], range: NSRange, delta: Int) {
        (lineStarts, [0, 4, 10, 14], NSRange(location: 5, length: 2), 2)
    }

    private func diagnostic(
        _ fileURL: URL? = nil,
        at location: Int,
        length: Int,
        line: Int,
        severity: DiagnosticSeverity = .error,
        message: String
    ) -> Diagnostic {
        Diagnostic(
            range: NSRange(location: location, length: length),
            line: line,
            severity: severity,
            message: message,
            source: serverID,
            fileURL: fileURL ?? url
        )
    }

    private func published(
        _ entries: [Diagnostic],
        version: Int?,
        url: URL? = nil
    ) -> LSPDiagnosticEvent {
        .published(
            url: url ?? self.url,
            serverID: serverID,
            root: root.path,
            version: version,
            diagnostics: entries
        )
    }

    /// Sync `url` at version 1, revision 0 — the state a first debounced flush
    /// leaves behind.
    private func syncAtVersionOne(_ target: URL? = nil) {
        model.noteSynced(url: target ?? url, version: 1, revision: 0)
    }

    private func entry(_ target: URL? = nil) -> DiagnosticStore.Entry? {
        model.store.entry(for: target ?? url)
    }

    // MARK: - Acceptance

    func testAPushIsAcceptedWhenNothingWasEditedSinceTheSync() {
        syncAtVersionOne()
        let set = [
            diagnostic(at: 0, length: 3, line: 0, message: "one"),
            diagnostic(at: 8, length: 3, line: 2, severity: .warning, message: "two"),
        ]
        model.receive(published(set, version: 1))

        XCTAssertEqual(entry()?.mapped, set)
        XCTAssertEqual(entry()?.serverKey, serverKey)
    }

    /// A different `(server, root)` becoming the reporter wholesale-swaps the
    /// entry — one set per document, keyed by its *current* answerer, never the
    /// old server's set beside the new one.
    func testAPushFromAnotherServerReplacesTheProvenanceAndTheSet() {
        syncAtVersionOne()
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "swift")], version: 1))

        let goID = "gopls"
        model.noteSynced(url: url, version: 1, revision: 0)
        model.receive(.published(
            url: url,
            serverID: goID,
            root: root.path,
            version: 1,
            diagnostics: [diagnostic(at: 4, length: 3, line: 1, message: "go")]
        ))

        XCTAssertEqual(entry()?.mapped?.count, 1)
        XCTAssertEqual(entry()?.mapped?.first?.message, "go")
        XCTAssertEqual(entry()?.serverKey.serverID, goID)
    }

    func testTheSamePushIsDroppedOnceTheRevisionMoved() {
        syncAtVersionOne()
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "first")], version: 1))

        let edit = insertAtFive()
        model.noteEdit(
            url: url,
            previousLineStarts: edit.previous,
            newLineStarts: edit.new,
            editedRange: edit.range,
            changeInLength: edit.delta
        )

        // A late replay of the very same wire push must not overwrite what the
        // shift produced.
        model.receive(published(
            [diagnostic(at: 0, length: 3, line: 0, message: "replay")],
            version: 1
        ))

        XCTAssertEqual(entry()?.mapped?.count, 1)
        XCTAssertEqual(entry()?.mapped?.first?.message, "first")
    }

    /// A versioned push whose version the *current* record does not name cannot
    /// be condemned outright — with nothing typed, it is either a late replay or
    /// the settling flush's own publish beating its report home — so it is
    /// held, shown nowhere, and judged when the record that names its version
    /// lands.
    func testAPushForAMismatchedVersionAgainstACurrentRecordIsHeldThenJudged() {
        syncAtVersionOne()
        let set = [diagnostic(at: 0, length: 3, line: 0, message: "m")]
        model.receive(published(set, version: 2))
        XCTAssertNil(entry(), "held, not shown")

        model.noteSynced(url: url, version: 2, revision: 0)
        XCTAssertEqual(entry()?.mapped, set, "the landing report admits it")
    }

    /// The replay half of the same hold: a push for a version no sync ever
    /// records stays unreplayed after the landing report discards it.
    func testAHeldReplayAgainstACurrentRecordStaysDroppedAfterTheReportLands() {
        syncAtVersionOne()
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "replay")], version: 2))
        XCTAssertNil(entry())

        // The next sync settles at yet another version; the reconcile's version
        // half discards the held push, and the ordinary gate carries the live one.
        model.noteSynced(url: url, version: 3, revision: 0)
        XCTAssertNil(entry())

        let set = [diagnostic(at: 4, length: 3, line: 1, severity: .warning, message: "fresh")]
        model.receive(published(set, version: 3))
        XCTAssertEqual(entry()?.mapped, set)
    }

    /// The forced-flush race ``LSPWorkspace/prepare(forceFlush:)``'s invariant
    /// promises to cover: the settling sync bumps the server's version while the
    /// previous record still stands (nothing was typed), the server's answer is
    /// routed before the controller's report lands, and the landing report must
    /// admit it — no second notification arrives to save the surfaces.
    func testASettlingSyncsPublishBeatingItsReportHomeIsAdmittedByTheReport() {
        syncAtVersionOne()
        let set = [diagnostic(at: 4, length: 3, line: 1, severity: .warning, message: "settled")]
        model.receive(published(set, version: 2))
        XCTAssertNil(entry(), "the answer outran its own report: nothing on the surfaces yet")

        model.noteSynced(url: url, version: 2, revision: 0)
        XCTAssertEqual(entry()?.mapped, set)
        XCTAssertEqual(model.counts.warnings, 1)
    }

    func testAPushWithoutAVersionIsAcceptedOnTheRevisionHalfAlone() {
        syncAtVersionOne()
        let set = [diagnostic(at: 4, length: 3, line: 1, severity: .warning, message: "unversioned")]
        model.receive(published(set, version: nil))

        XCTAssertEqual(entry()?.mapped, set)
    }

    // MARK: - The hold-and-reconcile step

    /// The race the hold exists for: the workspace committed the flushed
    /// version and routed the answer, but the controller's report has not
    /// landed yet (several main-actor hops behind the commit). Dropping here
    /// would strand the document blank until the next interaction.
    func testAPushThatArrivesBeforeItsSyncIsAppliedWhenTheSyncRecordsIt() {
        let set = [diagnostic(at: 0, length: 3, line: 0, message: "first")]
        model.receive(published(set, version: 1))
        XCTAssertNil(entry(), "nothing is stored while no record exists")

        model.noteSynced(url: url, version: 1, revision: 0)

        XCTAssertEqual(entry()?.mapped, set, "the landing record admits the held push")
        XCTAssertEqual(entry()?.serverKey, serverKey)
    }

    /// sourcekit-lsp sends no version: the reconcile must work on the revision
    /// half alone, or the primary server never passes the gate.
    func testAnUnversionedPushHeldBeforeItsSyncIsAppliedOnTheRevisionHalfAlone() {
        let set = [diagnostic(at: 4, length: 3, line: 1, severity: .warning, message: "unversioned")]
        model.receive(published(set, version: nil))

        model.noteSynced(url: url, version: 1, revision: 0)

        XCTAssertEqual(entry()?.mapped, set)
    }

    /// The hold is judged against the record that lands, verbatim: a push
    /// describing another sync's text is discarded unreplayed, and the channel
    /// stays live for pushes the ordinary gate admits.
    func testAHeldPushForAMismatchedVersionIsDiscardedWhenTheRecordLands() {
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "future")], version: 2))

        model.noteSynced(url: url, version: 1, revision: 0)
        XCTAssertNil(entry())

        let set = [diagnostic(at: 0, length: 3, line: 0, message: "now")]
        model.receive(published(set, version: 1))
        XCTAssertEqual(entry()?.mapped, set)
    }

    /// The starvation shape (iteration two's fix, finished): a provider flush
    /// bumped the server past the recorded version while a keystroke moved the
    /// buffer, so the record is stale on both halves — and the settling sync's
    /// forced republish provokes a push that lands *before* that sync's report
    /// does. Held, then admitted by the landing report.
    func testAHeldPushAgainstAStaleRecordIsJudgedByTheLandingReport() {
        syncAtVersionOne()
        model.noteEdit(
            url: url,
            previousLineStarts: lineStarts,
            newLineStarts: lineStarts,
            editedRange: NSRange(location: 5, length: 2),
            changeInLength: 0
        )
        // The provider's push: version past the record, revision moved.
        model.receive(published(
            [diagnostic(at: 0, length: 3, line: 0, message: "mid")],
            version: 2
        ))
        XCTAssertNil(entry(), "the stale-record push is held, not shown")

        // The settling sync forces the republish (version 3) and its answer
        // beats the report across the hops.
        let set = [diagnostic(at: 4, length: 3, line: 1, severity: .warning, message: "settled")]
        model.receive(published(set, version: 3))
        XCTAssertNil(entry())

        model.noteSynced(url: url, version: 3, revision: 1)
        XCTAssertEqual(entry()?.mapped, set, "the settling sync's own push is what lands")
    }

    /// An edit between the hold and the report condemns the held set: it
    /// describes text nobody can shift it across (D32).
    func testAnEditAfterTheHoldDropsIt() {
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "held")], version: 1))

        let edit = insertAtFive()
        model.noteEdit(
            url: url,
            previousLineStarts: edit.previous,
            newLineStarts: edit.new,
            editedRange: edit.range,
            changeInLength: edit.delta
        )

        // Even a report whose version matches cannot resurrect it…
        model.noteSynced(url: url, version: 1, revision: 1)
        XCTAssertNil(entry())

        // …and the channel is alive for the next cycle's own push.
        model.noteSynced(url: url, version: 2, revision: 1)
        let set = [diagnostic(at: 6, length: 3, line: 1, message: "fresh")]
        model.receive(published(set, version: 2))
        XCTAssertEqual(entry()?.mapped, set)
    }

    /// A wholesale replacement between the hold and the report drops the held
    /// set like any other content of the replaced buffer.
    func testABufferReplacementDropsTheHeldPush() {
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "held")], version: 1))

        model.noteBufferReplaced(url: url)
        model.noteSynced(url: url, version: 1, revision: 1)

        XCTAssertNil(entry())
    }

    /// A folder change drops every hold along with the bookkeeping: no
    /// old-project push may land through the new project's first sync.
    func testAFolderChangeDropsHeldPushes() {
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "old")], version: 1))
        model.receive(published(
            [diagnostic(at: 0, length: 3, line: 0, message: "old other")],
            version: 1,
            url: otherURL
        ))

        model.prepareForFolderChange(root: root)

        model.noteSynced(url: url, version: 1, revision: 0)
        XCTAssertNil(entry())
        XCTAssertTrue(model.store.rows(relativeTo: root).isEmpty)
    }

    /// Each teardown scope condemns only its own holds: a document clear takes
    /// that document's, a server clear takes that server's, and a different
    /// server's held push survives to be judged by its own record.
    func testClearsDropOnlyTheirOwnScopeOfHeldPushes() {
        let goID = "gopls"
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "swift")], version: 1))
        model.receive(.published(
            url: otherURL,
            serverID: goID,
            root: root.path,
            version: 1,
            diagnostics: [diagnostic(otherURL, at: 0, length: 3, line: 0, message: "go")]
        ))

        // Another server's document clear does not touch the Swift hold…
        model.receive(.cleared(.document(url: otherURL)))
        model.noteSynced(url: url, version: 1, revision: 0)
        XCTAssertEqual(entry()?.mapped?.first?.message, "swift")
        // …while its own hold is condemned: the record it was waiting for lands,
        // and nothing is admitted against it. Asserted by *landing that record*,
        // because the entry simply not existing yet would satisfy any weaker
        // check whether or not the hold was ever dropped.
        model.noteSynced(url: otherURL, version: 1, revision: 0)
        XCTAssertNil(model.store.entry(for: otherURL), "a closed document's hold dies with it")

        // …and the server clear takes exactly that server's remaining hold.
        model.receive(.published(
            url: otherURL,
            serverID: goID,
            root: root.path,
            version: 2,
            diagnostics: [diagnostic(otherURL, at: 0, length: 3, line: 0, message: "go again")]
        ))
        model.receive(.cleared(.server(serverID: goID, root: root.path)))
        model.noteSynced(url: otherURL, version: 2, revision: 0)
        XCTAssertNil(model.store.entry(for: otherURL), "a condemned server's hold dies with it")
    }

    /// One hold per document, newest wins: the settling push replaces whatever
    /// earlier push was waiting, so a superseded set can never land.
    func testASecondPushReplacesTheOneHeldForItsDocument() {
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "stale")], version: 1))
        let set = [diagnostic(at: 4, length: 3, line: 1, severity: .warning, message: "newest")]
        model.receive(published(set, version: 2))

        model.noteSynced(url: url, version: 2, revision: 0)

        XCTAssertEqual(entry()?.mapped, set)
    }

    /// Task 5's contract, pinned here where it is consumed: a sync reported for
    /// a revision that has since moved is recorded, but its pushes are rejected
    /// until a fresh sync pins the current revision.
    func testASyncReportedForAMovedRevisionRecordsButItsPushesAreRejected() {
        model.noteEdit(
            url: url,
            previousLineStarts: lineStarts,
            newLineStarts: lineStarts,
            editedRange: NSRange(location: 5, length: 2),
            changeInLength: 0
        )
        model.noteEdit(
            url: url,
            previousLineStarts: lineStarts,
            newLineStarts: lineStarts,
            editedRange: NSRange(location: 5, length: 2),
            changeInLength: 0
        )
        // The controller pinned revision 0 before its hop; two edits have since
        // moved the buffer to revision 2.
        syncAtVersionOne()

        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "stale")], version: 1))

        XCTAssertNil(entry(), "a push against text the buffer moved past is dropped outright")

        // Self-correcting: the next debounce re-syncs at the current revision.
        model.noteSynced(url: url, version: 2, revision: 2)
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "fresh")], version: 2))
        XCTAssertEqual(entry()?.mapped?.first?.message, "fresh")
    }

    // MARK: - The sync controller's pin (Task 5)

    /// A revision starts implicitly at zero — what an untouched document's first
    /// sync records.
    func testCurrentRevisionIsZeroUntilAnEditTouchesTheDocument() {
        XCTAssertEqual(model.currentRevision(for: url), 0)
        XCTAssertEqual(model.currentRevision(for: otherURL), 0)
    }

    /// Each edit bumps exactly its own document's revision, by exactly one.
    func testEachEditBumpsOnlyThatDocumentsRevision() {
        let edit = insertAtFive()
        model.noteEdit(
            url: url,
            previousLineStarts: edit.previous,
            newLineStarts: edit.new,
            editedRange: edit.range,
            changeInLength: edit.delta
        )
        model.noteEdit(
            url: url,
            previousLineStarts: edit.previous,
            newLineStarts: edit.new,
            editedRange: edit.range,
            changeInLength: edit.delta
        )
        model.noteSynced(url: otherURL, version: 1, revision: model.currentRevision(for: otherURL))

        XCTAssertEqual(model.currentRevision(for: url), 2)
        XCTAssertEqual(model.currentRevision(for: otherURL), 0)
    }

    /// The controller's sequence when typing continues across a flush: the pin
    /// taken before the hop goes stale, so the flush that completes afterwards
    /// records it and every push it produces is rejected — until the next
    /// debounce re-pins the moved revision.
    func testAPinTakenBeforeEditsRejectsTheFlushesPushesUntilItRePins() {
        // Scheduling time: the pin is read synchronously.
        let pinned = model.currentRevision(for: url)
        XCTAssertEqual(pinned, 0)

        // Two keystrokes land while the debounce/flush is in flight.
        let edit = insertAtFive()
        for _ in 0..<2 {
            model.noteEdit(
                url: url,
                previousLineStarts: edit.previous,
                newLineStarts: edit.new,
                editedRange: edit.range,
                changeInLength: edit.delta
            )
        }

        // Flush completes and reports the pinned revision verbatim.
        model.noteSynced(url: url, version: 1, revision: pinned)

        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "mid-flight")], version: 1))
        XCTAssertNil(entry(), "pushes from a flush that raced a keystroke are dropped")

        // The next debounce re-pins the current revision and the channel opens.
        model.noteSynced(url: url, version: 2, revision: model.currentRevision(for: url))
        let fresh = [diagnostic(at: 4, length: 3, line: 1, severity: .warning, message: "settled")]
        model.receive(published(fresh, version: 2))
        XCTAssertEqual(entry()?.mapped, fresh)
    }

    /// A wholesale replacement moves the revision too — so a sync pinned before
    /// the replacement cannot accept anything after it.
    func testABufferReplacementMovesTheRevisionTheControllerPinned() {
        let pinned = model.currentRevision(for: url)

        model.noteBufferReplaced(url: url)

        XCTAssertNotEqual(model.currentRevision(for: url), pinned)

        // The stale pin cannot open the gate even for a matching version: the
        // replacement also dropped the sync record, which is the working half
        // here — pinned only as the second line of defence.
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "m")], version: nil))
        XCTAssertNil(entry())
    }

    /// A folder change resets every document's revision to zero, so a sync
    /// recorded before the switch can never equal a post-switch revision.
    func testAFolderChangeResetsEveryRevision() {
        let edit = insertAtFive()
        model.noteEdit(
            url: url,
            previousLineStarts: edit.previous,
            newLineStarts: edit.new,
            editedRange: edit.range,
            changeInLength: edit.delta
        )

        model.prepareForFolderChange(root: root)

        XCTAssertEqual(model.currentRevision(for: url), 0)
        XCTAssertEqual(model.currentRevision(for: otherURL), 0)
    }

    // MARK: - Shifting (D32)

    func testAnEditShiftsASetAndDropsWhatItTouched() {
        syncAtVersionOne()
        let before = diagnostic(at: 0, length: 3, line: 0, message: "before")
        let touched = diagnostic(at: 4, length: 3, line: 1, message: "touched")
        let after = diagnostic(at: 8, length: 3, line: 2, message: "after")
        model.receive(published([before, touched, after], version: 1))

        let edit = insertAtFive()
        model.noteEdit(
            url: url,
            previousLineStarts: edit.previous,
            newLineStarts: edit.new,
            editedRange: edit.range,
            changeInLength: edit.delta
        )

        XCTAssertEqual(entry()?.mapped?.count, 2)
        // Untouched survivor keeps everything, including its stored line.
        XCTAssertEqual(entry()?.mapped?.first, before)
        // Shifted survivor moves by the delta and renumbers from the new table:
        // offset 10 sits on new line 2 ("aaa\nXXbbb\n" ends at 10).
        let shifted = entry()?.mapped?.last
        XCTAssertEqual(shifted?.range, NSRange(location: 10, length: 3))
        XCTAssertEqual(shifted?.line, 2)
        XCTAssertEqual(shifted?.message, "after")
    }

    // MARK: - Wholesale replacement

    func testABufferReplacementClearsAndItsPushesAreRejectedAfterwards() {
        syncAtVersionOne()
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "m")], version: 1))
        XCTAssertNotNil(entry())

        model.noteBufferReplaced(url: url)

        XCTAssertNil(entry(), "the replaced buffer's set is dropped outright")

        // The revision moved and the sync record died with the replacement, so
        // even a replay of the old push cannot resurrect anything.
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "m")], version: 1))
        XCTAssertNil(entry())

        // And the next real sync makes the channel live again: the server's
        // version moved with the replacement, and the buffer's revision stands
        // at one.
        model.noteSynced(url: url, version: 2, revision: 1)
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "next")], version: 2))
        XCTAssertEqual(entry()?.mapped?.first?.message, "next")
    }

    // MARK: - Document independence

    func testTwoDocumentsAreKeptIndependent() {
        syncAtVersionOne()
        model.noteSynced(url: otherURL, version: 1, revision: 0)

        let mainSet = [diagnostic(at: 0, length: 3, line: 0, message: "main")]
        let otherSet = [
            diagnostic(otherURL, at: 4, length: 3, line: 1, severity: .warning, message: "other"),
        ]
        model.receive(published(mainSet, version: 1))
        model.receive(published(otherSet, version: 1, url: otherURL))

        // An edit to one document shifts one document's set and gates only its
        // own pushes.
        let edit = insertAtFive()
        model.noteEdit(
            url: url,
            previousLineStarts: edit.previous,
            newLineStarts: edit.new,
            editedRange: edit.range,
            changeInLength: edit.delta
        )
        model.receive(published(mainSet, version: 1)) // gated: revision moved
        model.receive(published(otherSet, version: 1, url: otherURL)) // still fresh

        XCTAssertEqual(model.store.entry(for: otherURL)?.mapped, otherSet)
        XCTAssertEqual(entry()?.mapped?.map(\.message), ["main"])
        XCTAssertEqual(model.counts.errors, 1)
        XCTAssertEqual(model.counts.warnings, 1)
    }

    // MARK: - Folder change

    func testAFolderChangeDropsEveryPushUntilANewSyncArrives() {
        syncAtVersionOne()
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "old project")], version: 1))
        model.noteSynced(url: otherURL, version: 3, revision: 0)

        model.prepareForFolderChange(root: root)

        XCTAssertNil(entry())
        XCTAssertTrue(model.store.rows(relativeTo: root).isEmpty)
        XCTAssertEqual(model.counts.errors, 0)

        // Both pushes replayed from the old folder's servers — versions match
        // their old syncs, but no sync record survived the move.
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "late")], version: 1))
        model.receive(published(
            [diagnostic(at: 0, length: 3, line: 0, message: "late other")],
            version: 3,
            url: otherURL
        ))
        XCTAssertTrue(model.store.rows(relativeTo: root).isEmpty, "no push survives a folder change")
    }

    // MARK: - Clear routing

    /// A document clear drops the bookkeeping and keeps the set — the file's
    /// problems outlive its tab — while a server clear removes the set.
    func testClearEventsRouteIntoTheStoreByDocumentThenByServer() {
        syncAtVersionOne()
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "m")], version: 1))

        model.receive(.cleared(.document(url: url)))
        XCTAssertEqual(entry()?.mapped?.map(\.message), ["m"], "closing keeps the set")

        // Re-sync and re-publish, then tear the whole server down.
        syncAtVersionOne()
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "m")], version: 1))
        model.receive(.cleared(.server(serverID: serverID, root: root.path)))
        XCTAssertNil(entry())
    }

    /// Closing a document drops its bookkeeping and keeps its set: the sync
    /// record and the revision describe a buffer the editor no longer holds, so
    /// keeping them would both gate the file's next life against its previous
    /// one and grow the two maps by every file the session ever opened — while
    /// the set is still the file's problems, which the panel and the tree keep
    /// listing.
    func testClosingADocumentDropsItsSyncRecordAndRevision() {
        model.noteEdit(
            url: url,
            previousLineStarts: lineStarts,
            newLineStarts: lineStarts,
            editedRange: NSRange(location: 0, length: 0),
            changeInLength: 0
        )
        XCTAssertEqual(model.currentRevision(for: url), 1, "the edit bumped the revision")
        model.noteSynced(url: url, version: 1, revision: 1)
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "m")], version: 1))
        XCTAssertNotNil(entry())

        model.receive(.cleared(.document(url: url)))
        XCTAssertEqual(entry()?.mapped?.map(\.message), ["m"], "closing keeps the set")
        XCTAssertEqual(model.currentRevision(for: url), 0, "a closed document is gated from zero again")

        // And the sync record is gone with it: a push naming the version the
        // *closed* document was last synced at finds no record to pass, so it is
        // held as a first report rather than admitted.
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "late")], version: 1))
        XCTAssertEqual(
            entry()?.mapped?.map(\.message), ["m"],
            "no surviving record can admit a push for the closed document"
        )

        // Reopening the file replaces the buffer wholesale: the kept mapped set
        // goes (its offsets describe the buffer being replaced) and so does the
        // stale hold, so the reopened document's first record admits nothing
        // from the closed one's life.
        model.noteBufferReplaced(url: url)
        XCTAssertNil(entry(), "the kept mapped set described the buffer being replaced")
        model.noteSynced(url: url, version: 1, revision: model.currentRevision(for: url))
        XCTAssertNil(entry(), "the closed document's late push is not admitted by the reopened one's record")
    }

    /// The close prune is reachable **without** a workspace event, because the
    /// workspace emits `.cleared(.document)` only for a URI it still held: every
    /// teardown wipes its document table first, so a crash-then-close emits
    /// nothing, and a file no server ever served was never in that table at all.
    /// The app calls this directly from its "no tab shows this file" guard, so
    /// the maps stay bounded by the open tabs either way.
    func testClosingADocumentDirectlyDropsTheBookkeepingNoEventWouldHaveCleared() {
        model.noteEdit(
            url: url,
            previousLineStarts: lineStarts,
            newLineStarts: lineStarts,
            editedRange: NSRange(location: 0, length: 0),
            changeInLength: 0
        )
        model.noteSynced(url: url, version: 3, revision: 1)
        XCTAssertEqual(model.currentRevision(for: url), 1)

        model.noteDocumentClosed(url: url)
        XCTAssertEqual(model.currentRevision(for: url), 0, "a closed document is gated from zero again")

        // The sync record went with it: a push naming the version the closed
        // document was last synced at finds no record to pass and is held.
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "late")], version: 3))
        XCTAssertNil(entry(), "no surviving record can admit a push for the closed document")

        // Idempotent: arriving a second time (the workspace's own clear, when it
        // does fire) costs nothing.
        model.noteDocumentClosed(url: url)
        XCTAssertEqual(model.currentRevision(for: url), 0)
    }

    /// A removal is not a close: the app deleted or moved the file away, so
    /// both kinds of entry at or under the old path go — a kept mapped set and
    /// a closed file's positional one under a removed folder alike — while a
    /// file elsewhere keeps its set.
    func testARemovedItemTakesItsEntriesOfBothKinds() {
        let closed = root.appendingPathComponent("Sources/App/closed.swift")
        let elsewhere = root.appendingPathComponent("Other/kept.swift")
        syncAtVersionOne()
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "m")], version: 1))
        model.noteDocumentClosed(url: url)
        model.receive(positional([positionalDiagnostic(line: 0, character: 0, message: "c")], url: closed))
        model.receive(positional([positionalDiagnostic(line: 0, character: 0, message: "e")], url: elsewhere))
        XCTAssertNotNil(entry(), "closing kept the set")

        model.noteItemRemoved(at: url)
        XCTAssertNil(entry(), "the removed file's kept set")
        XCTAssertNotNil(entry(closed))

        model.noteItemRemoved(at: root.appendingPathComponent("Sources", isDirectory: true))
        XCTAssertNil(entry(closed), "a closed file under the removed folder")
        XCTAssertNotNil(entry(elsewhere))
    }

    /// A removal leaves a tombstone, not only a one-time clear: a report the
    /// server queued before the removal — or a stale one from a server never
    /// told about it — arriving afterwards must not resurrect the path, at the
    /// file or under a removed folder. The disk is asked only on a tombstone's
    /// match, and a path that exists again takes reports again; the folder
    /// change forgets every tombstone.
    func testALateReportCannotResurrectARemovedPath() {
        var existing: Set<String> = []
        var probes: [String] = []
        model = DiagnosticsModel(fileExists: { url in
            probes.append(url.path)
            return existing.contains(url.path)
        })
        let folder = root.appendingPathComponent("Gone", isDirectory: true)
        let underFolder = folder.appendingPathComponent("inner.swift")
        let elsewhere = root.appendingPathComponent("Other/kept.swift")
        let report = [positionalDiagnostic(line: 0, character: 0, message: "late")]

        model.receive(positional(report))
        model.noteItemRemoved(at: url)
        model.noteItemRemoved(at: folder)
        XCTAssertNil(entry())

        model.receive(positional(report))
        model.receive(positional(report, url: underFolder))
        model.receive(positional(report, url: elsewhere))
        XCTAssertNil(entry(), "the removed file stays removed")
        XCTAssertNil(entry(underFolder), "so does a file under the removed folder")
        XCTAssertNotNil(entry(elsewhere))
        XCTAssertEqual(probes, [url.path, underFolder.path], "the disk is asked on a tombstone's match alone")

        existing.insert(url.path)
        model.receive(positional(report))
        XCTAssertNotNil(entry(), "a path that exists again takes reports again")
        probes.removeAll()
        model.receive(positional(report))
        XCTAssertEqual(probes, [], "and its exact tombstone was lifted")

        model.prepareForFolderChange(root: root)
        model.receive(positional(report, url: underFolder))
        XCTAssertNotNil(entry(underFolder), "the folder change forgets every tombstone")
    }

    /// A file found under a removed folder is one file back, not the folder:
    /// the folder's tombstone stays, so a never-opened sibling — which the
    /// delete call sites give no tombstone of its own — is still probed and
    /// refused. The file found is remembered, so its next report lands without
    /// asking the disk again, until a removal at or above it forgets it.
    func testAFileFoundUnderARemovedFolderLeavesTheFolderTombstoned() {
        var probes: [String] = []
        let folder = root.appendingPathComponent("Gone", isDirectory: true)
        let inner = folder.appendingPathComponent("inner.swift")
        let sibling = folder.appendingPathComponent("sibling.swift")
        model = DiagnosticsModel(fileExists: { url in
            probes.append(url.path)
            return url == inner
        })
        let report = [positionalDiagnostic(line: 0, character: 0, message: "back")]
        let folderTombstone = [folder.standardizedFileURL.pathComponents]

        model.noteItemRemoved(at: folder)
        model.receive(positional(report, url: inner))
        XCTAssertNotNil(entry(inner), "the file exists, so its report lands")
        XCTAssertEqual(model.removedPaths, folderTombstone, "the folder above the file found stays tombstoned")
        XCTAssertEqual(model.foundAgain, [inner.standardizedFileURL.pathComponents])

        model.receive(positional(report, url: sibling))
        XCTAssertNil(entry(sibling), "a late report for a never-opened sibling still gone is refused")
        XCTAssertEqual(probes, [inner.path, sibling.path])

        model.receive(positional(report, url: inner))
        XCTAssertEqual(probes, [inner.path, sibling.path], "the file found again does not probe twice")

        model.noteItemRemoved(at: folder)
        XCTAssertEqual(model.foundAgain, [], "a removal at or above the file forgets it")
        XCTAssertEqual(model.removedPaths, folderTombstone)
        model.receive(positional(report, url: inner))
        XCTAssertEqual(probes, [inner.path, sibling.path, inner.path], "so its next report is probed again")
    }

    /// A removal already recorded exactly adds no second tombstone, while a
    /// file under a removed folder still adds its own — and every removal
    /// still clears the store under its own path.
    func testARepeatedRemovalAddsNoTombstoneButStillClears() {
        let folder = root.appendingPathComponent("Gone", isDirectory: true)
        let file = folder.appendingPathComponent("a.swift")
        let other = folder.appendingPathComponent("b.swift")
        let set = [diagnostic(at: 0, length: 3, line: 0, message: "m")]

        model.noteItemRemoved(at: folder)
        XCTAssertEqual(model.removedPaths, [folder.standardizedFileURL.pathComponents])

        // A mapped push for a synced buffer is gated by its record, not by a
        // tombstone, so it plants an entry under the removed folder.
        syncAtVersionOne(file)
        model.receive(published(set, version: 1, url: file))
        XCTAssertNotNil(entry(file))
        model.noteItemRemoved(at: file)
        XCTAssertNil(entry(file), "the removal under the folder still clears its entry")
        XCTAssertEqual(
            model.removedPaths,
            [folder.standardizedFileURL.pathComponents, file.standardizedFileURL.pathComponents],
            "a file under a removed folder keeps a tombstone of its own"
        )

        syncAtVersionOne(other)
        model.receive(published(set, version: 1, url: other))
        XCTAssertNotNil(entry(other))
        model.noteItemRemoved(at: folder)
        XCTAssertNil(entry(other), "the repeated removal still clears under the folder")
        XCTAssertEqual(model.removedPaths.count, 2, "the same folder again adds no tombstone")
    }

    /// Finding a file lifts only its own tombstone: the folder above it, a
    /// file removed with it — before or after the folder, the delete call
    /// sites passing the folder first — and an unrelated removal stay
    /// tombstoned, so a late report for any of them is still probed and
    /// refused.
    func testFindingAFileKeepsEveryOtherTombstone() {
        let folder = root.appendingPathComponent("Gone", isDirectory: true)
        let removedAfter = folder.appendingPathComponent("a.swift")
        let removedBefore = folder.appendingPathComponent("z.swift")
        let recreated = folder.appendingPathComponent("b.swift")
        let unrelated = root.appendingPathComponent("Other/x.swift")
        var probes: [String] = []
        model = DiagnosticsModel(fileExists: { url in
            probes.append(url.path)
            return url == recreated
        })
        let report = [positionalDiagnostic(line: 0, character: 0, message: "late")]

        model.noteItemRemoved(at: removedBefore)
        model.noteItemRemoved(at: folder)
        model.noteItemRemoved(at: removedAfter)
        model.noteItemRemoved(at: unrelated)
        XCTAssertEqual(model.removedPaths.count, 4)

        model.receive(positional(report, url: recreated))
        XCTAssertNotNil(entry(recreated), "the recreated file's report lands")
        XCTAssertEqual(
            model.removedPaths,
            [removedBefore, folder, removedAfter, unrelated].map(\.standardizedFileURL.pathComponents),
            "the recreated file had no tombstone of its own, so none is lifted"
        )

        for gone in [removedAfter, removedBefore, unrelated] {
            model.receive(positional(report, url: gone))
            XCTAssertNil(entry(gone), "a late report for a file still gone is refused")
        }
        XCTAssertEqual(probes, [recreated, removedAfter, removedBefore, unrelated].map(\.path))
    }

    /// The default probe counts a file, not any item: a folder recreated at a
    /// removed file's path does not lift its tombstone.
    func testTheDefaultProbeAcceptsAFileButNotADirectory() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let path = scratch.appendingPathComponent("gone.swift")

        XCTAssertFalse(DiagnosticsModel.isFile(path), "nothing there")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        XCTAssertFalse(DiagnosticsModel.isFile(path), "a directory is not the file")
        try FileManager.default.removeItem(at: path)
        try Data().write(to: path)
        XCTAssertTrue(DiagnosticsModel.isFile(path))
    }

    // MARK: - The panel's rows

    /// The panel re-reads its rows on every publication, so a one-document
    /// mutation rebuilds that document's group alone — and the incremental
    /// answer is the store's own full build at every step: across a burst, a
    /// shift, a replacement that empties a file, a bulk clear and a root change.
    func testThePanelRowsRebuildOnlyTheTouchedFileAndMatchTheFullBuild() {
        model.prepareForFolderChange(root: root)
        XCTAssertEqual(model.rows(relativeTo: root), [])

        func push(_ index: Int, severity: DiagnosticSeverity = .error) -> Int {
            let file = root.appendingPathComponent("gen/d\(index % 7)/f\(index).swift")
            model.receive(positional(
                [positionalDiagnostic(line: index % 5, character: 0, severity: severity, message: "m\(index)")],
                url: file
            ))
            let before = model.panelFileBuilds
            XCTAssertEqual(model.rows(relativeTo: root), model.store.rows(relativeTo: root), "push \(index)")
            return model.panelFileBuilds - before
        }
        let first = push(0)
        for index in 1..<300 { _ = push(index) }
        XCTAssertEqual(first, 1)
        XCTAssertEqual(push(300), 1, "the three-hundred-and-first push builds its own file alone")
        XCTAssertEqual(push(17, severity: .warning), 1, "a replacement too")

        let before = model.panelFileBuilds
        _ = model.rows(relativeTo: root)
        XCTAssertEqual(model.panelFileBuilds, before, "an unchanged store builds nothing")

        syncAtVersionOne()
        model.receive(published([diagnostic(at: 8, length: 3, line: 2, message: "m")], version: 1))
        XCTAssertEqual(model.rows(relativeTo: root), model.store.rows(relativeTo: root))
        let edit = insertAtFive()
        model.noteEdit(
            url: url,
            previousLineStarts: edit.previous,
            newLineStarts: edit.new,
            editedRange: edit.range,
            changeInLength: edit.delta
        )
        XCTAssertEqual(model.rows(relativeTo: root), model.store.rows(relativeTo: root), "a shift")
        model.receive(positional([], url: root.appendingPathComponent("gen/d3/f3.swift")))
        XCTAssertEqual(model.rows(relativeTo: root), model.store.rows(relativeTo: root), "an emptied file")

        let other = URL(fileURLWithPath: "/tmp", isDirectory: true)
        XCTAssertEqual(model.rows(relativeTo: other), model.store.rows(relativeTo: other), "another root")
        model.noteItemRemoved(at: root.appendingPathComponent("gen/d2", isDirectory: true))
        XCTAssertEqual(model.rows(relativeTo: root), model.store.rows(relativeTo: root), "a removal")
        model.receive(.cleared(.server(serverID: serverID, root: root.path)))
        XCTAssertEqual(model.rows(relativeTo: root), [], "a server's teardown")
    }

    // MARK: - The positional lane

    private func positionalDiagnostic(
        line: Int,
        character: Int,
        severity: DiagnosticSeverity = .error,
        message: String
    ) -> PositionalDiagnostic {
        PositionalDiagnostic(
            range: LSPRange(
                start: LSPPosition(line: line, character: character),
                end: LSPPosition(line: line, character: character + 3)
            ),
            severity: severity,
            message: message,
            source: serverID,
            fileURL: url
        )
    }

    private func positional(
        _ entries: [PositionalDiagnostic],
        url: URL? = nil,
        serverID: String? = nil
    ) -> LSPDiagnosticEvent {
        .positional(
            url: url ?? self.url,
            serverID: serverID ?? self.serverID,
            root: root.path,
            diagnostics: entries
        )
    }

    /// A report for a document no buffer holds needs no sync: it lands at once,
    /// under the pushing server's provenance, and the next one replaces it
    /// wholesale.
    func testAPositionalReportIsAcceptedWithNoSyncRecordAndReplacesTheEntry() {
        let first = [positionalDiagnostic(line: 2, character: 4, message: "first")]
        model.receive(positional(first))
        XCTAssertEqual(entry()?.positional, first)
        XCTAssertNil(entry()?.mapped, "a positional entry is unreachable from the editor accessor")
        XCTAssertEqual(entry()?.serverKey, serverKey)

        let second = [
            positionalDiagnostic(line: 0, character: 0, severity: .warning, message: "second"),
            positionalDiagnostic(line: 5, character: 1, message: "third"),
        ]
        model.receive(positional(second))
        XCTAssertEqual(entry()?.positional, second)
    }

    /// While a sync record exists a buffer is open, and the mapped lane is the
    /// document's one answerer: a positional report would draw the server's
    /// positions over offsets the editor is shifting.
    func testAPositionalReportIsDroppedWhenASyncRecordExists() {
        let mapped = [diagnostic(at: 0, length: 3, line: 0, message: "mapped")]
        syncAtVersionOne()
        model.receive(published(mapped, version: 1))

        model.receive(positional([positionalDiagnostic(line: 1, character: 0, message: "positional")]))
        XCTAssertEqual(entry()?.mapped, mapped)
        XCTAssertNil(entry()?.positional)

        // The record alone closes the lane, with no entry beside it.
        model.noteSynced(url: otherURL, version: 1, revision: 0)
        model.receive(positional([positionalDiagnostic(line: 1, character: 0, message: "other")], url: otherURL))
        XCTAssertNil(entry(otherURL))
    }

    /// An all-clear report about a closed file installs an empty entry, so the
    /// file's provenance survives exactly as an all-clear mapped push's does.
    func testAnEmptyPositionalReportInstallsAnEmptyEntry() {
        model.receive(positional([positionalDiagnostic(line: 0, character: 0, message: "gone soon")]))
        model.receive(positional([]))

        XCTAssertEqual(entry()?.positional, [])
        XCTAssertEqual(entry()?.serverKey, serverKey)
        XCTAssertEqual(model.counts, DiagnosticStore.Counts(errors: 0, warnings: 0))
    }

    /// Opening the file: the replacement keeps the positional record, and the
    /// first mapped report that passes the gate replaces it.
    func testALaterMappedReportReplacesAPositionalEntry() {
        model.receive(positional([positionalDiagnostic(line: 1, character: 0, message: "closed")]))
        model.noteBufferReplaced(url: url)
        XCTAssertEqual(entry()?.positional?.map(\.message), ["closed"])

        let mapped = [diagnostic(at: 4, length: 3, line: 1, message: "open")]
        model.noteSynced(url: url, version: 1, revision: model.currentRevision(for: url))
        model.receive(published(mapped, version: 1))

        XCTAssertEqual(entry()?.mapped, mapped)
        XCTAssertNil(entry()?.positional)
    }

    /// A wholesale replacement condemns offsets, and a positional entry has
    /// none: it stays, while a mapped one is still dropped.
    func testABufferReplacementKeepsAPositionalEntryAndDropsAMappedOne() {
        model.receive(positional([positionalDiagnostic(line: 0, character: 0, message: "positional")]))
        syncAtVersionOne(otherURL)
        model.receive(published(
            [diagnostic(otherURL, at: 0, length: 3, line: 0, message: "mapped")],
            version: 1,
            url: otherURL
        ))

        model.noteBufferReplaced(url: url)
        model.noteBufferReplaced(url: otherURL)

        XCTAssertEqual(entry()?.positional?.map(\.message), ["positional"])
        XCTAssertNil(entry(otherURL))
    }

    /// Closing the last tab opens the document's positional lane: the record
    /// that closed it is gone, so the server's next report about the closed
    /// file lands — while a mapped report is held as a first report.
    func testClosingTheLastTabOpensThePositionalLane() {
        syncAtVersionOne()
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "open")], version: 1))

        model.noteDocumentClosed(url: url)
        XCTAssertEqual(entry()?.mapped?.map(\.message), ["open"], "closing keeps the set")
        XCTAssertEqual(model.currentRevision(for: url), 0)

        model.receive(positional([positionalDiagnostic(line: 0, character: 0, message: "closed")]))
        XCTAssertEqual(entry()?.positional?.map(\.message), ["closed"])
    }

    /// A mapped set kept from a closed tab is dropped when the file is shown
    /// again — its offsets describe a buffer that is gone — while a tab merely
    /// switched back to keeps its set, and a positional entry stays either way.
    func testShowingAReopenedFileDropsTheMappedSetItsClosedTabLeftBehind() {
        syncAtVersionOne()
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "kept")], version: 1))

        model.noteDocumentShown(url: url)
        XCTAssertEqual(entry()?.mapped?.map(\.message), ["kept"], "a switched-back tab keeps its set")

        model.noteDocumentClosed(url: url)
        XCTAssertEqual(entry()?.mapped?.map(\.message), ["kept"], "closing keeps the set")
        model.noteDocumentShown(url: url)
        XCTAssertNil(entry(), "the reopened file shows nothing until the next push")
        XCTAssertEqual(model.currentRevision(for: url), 0, "no revision bump: a sync already scheduled still lands")

        model.receive(positional([positionalDiagnostic(line: 0, character: 0, message: "closed")]))
        model.noteDocumentShown(url: url)
        XCTAssertEqual(entry()?.positional?.map(\.message), ["closed"])
    }

    /// The positional lane neither creates nor drops a hold: a mapped push
    /// waiting for its first record is still judged when that record lands.
    func testAPositionalReportLeavesAnExistingHoldUntouched() {
        let mapped = [diagnostic(at: 0, length: 3, line: 0, message: "held")]
        model.receive(published(mapped, version: 1))
        XCTAssertNil(entry(), "no record yet, so the push is held")

        model.receive(positional([positionalDiagnostic(line: 0, character: 0, message: "positional")]))
        XCTAssertEqual(entry()?.positional?.map(\.message), ["positional"])

        syncAtVersionOne()
        XCTAssertEqual(entry()?.mapped, mapped, "the hold survived the positional report")
    }

    /// Both teardowns remove positional entries: a server's clear takes only
    /// its own, and the folder change takes everything.
    func testAServerClearAndAFolderChangeRemovePositionalEntries() {
        let goID = "gopls"
        model.receive(positional([positionalDiagnostic(line: 0, character: 0, message: "swift")]))
        model.receive(positional(
            [positionalDiagnostic(line: 0, character: 0, message: "go")],
            url: otherURL,
            serverID: goID
        ))

        model.receive(.cleared(.server(serverID: serverID, root: root.path)))
        XCTAssertNil(entry())
        XCTAssertEqual(entry(otherURL)?.positional?.map(\.message), ["go"])

        model.prepareForFolderChange(root: root)
        XCTAssertNil(entry(otherURL))
        XCTAssertTrue(model.store.rows(relativeTo: root).isEmpty)
    }

    // MARK: - Republishing

    /// Typing in a document with **no** stored entry publishes nothing, and
    /// neither does typing in one whose entry is empty — which is the steady
    /// state of every file that currently compiles, since an all-clear push
    /// installs an entry holding no diagnostics. Shifting an empty set can only
    /// produce an empty set, so the skip is behaviour-preserving; without it
    /// every keystroke in a clean served file wakes the panel's rows and counts
    /// and the editor's whole-document gutter pass for a store that did not
    /// change.
    func testAnEditPublishesOnlyWhenThereIsSomethingToShift() {
        var publishes = 0
        let subscription = model.objectWillChange.sink { _ in publishes += 1 }
        defer { subscription.cancel() }

        let edit = insertAtFive()
        func type() {
            model.noteEdit(
                url: url,
                previousLineStarts: edit.previous,
                newLineStarts: edit.new,
                editedRange: edit.range,
                changeInLength: edit.delta
            )
        }

        type()
        XCTAssertEqual(publishes, 0, "an undiagnosed document has nothing to shift")

        // An all-clear push: an entry exists, holding nothing.
        model.noteSynced(url: url, version: 1, revision: model.currentRevision(for: url))
        model.receive(published([], version: 1))
        XCTAssertEqual(entry()?.mapped, [])
        publishes = 0

        type()
        XCTAssertEqual(publishes, 0, "an empty entry has nothing to shift either")

        // ...and a document that *does* hold something still publishes its shift.
        model.noteSynced(url: url, version: 2, revision: model.currentRevision(for: url))
        model.receive(published([diagnostic(at: 8, length: 3, line: 2, message: "m")], version: 2))
        publishes = 0
        type()
        XCTAssertEqual(publishes, 1, "a non-empty set is shifted and republished")
        XCTAssertEqual(entry()?.mapped?.count, 1)
    }

    // MARK: - The tree's lookup

    private var lookup: TreeDiagnostics { model.treeDiagnostics.lookup }

    /// The rows from the diagnosed file up to the root: the file, its two
    /// folders and the root itself.
    private var markedRows: [URL] {
        [
            url,
            root.appendingPathComponent("Sources/App", isDirectory: true),
            root.appendingPathComponent("Sources", isDirectory: true),
            root,
        ]
    }

    /// Both lanes publish: a positional report about a closed file marks it and
    /// every folder above it, and the accepted mapped push that replaces it
    /// re-marks them with its own worst severity.
    func testAPositionalReportAndAnAcceptedMappedPushEachPublishALookupMarkingTheFileAndItsFolders() {
        model.prepareForFolderChange(root: root)
        XCTAssertEqual(lookup, .empty)

        model.receive(positional([positionalDiagnostic(line: 0, character: 0, severity: .warning, message: "w")]))
        for row in markedRows {
            XCTAssertEqual(lookup.mark(for: row), .warning, row.path)
        }

        model.noteBufferReplaced(url: url)
        model.noteSynced(url: url, version: 1, revision: model.currentRevision(for: url))
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, severity: .error, message: "e")], version: 1))
        XCTAssertNotNil(entry()?.mapped)
        for row in markedRows {
            XCTAssertEqual(lookup.mark(for: row), .error, row.path)
        }
        XCTAssertEqual(lookup.mark(for: root.appendingPathComponent("Tests", isDirectory: true)), .none)
    }

    /// A keystroke shifts the stored set — the store republishes — but every
    /// file keeps its worst severity, so the holder publishes nothing and the
    /// tree does not re-render per keystroke.
    func testAKeystrokeShiftThatKeepsTheWorstSeverityDoesNotPublishTheLookup() {
        model.prepareForFolderChange(root: root)
        syncAtVersionOne()
        model.receive(published([diagnostic(at: 8, length: 3, line: 2, message: "m")], version: 1))
        let before = lookup
        XCTAssertEqual(before.mark(for: url), .error)

        var storePublishes = 0
        var lookupPublishes = 0
        let storeSubscription = model.objectWillChange.sink { _ in storePublishes += 1 }
        let lookupSubscription = model.treeDiagnostics.objectWillChange.sink { _ in lookupPublishes += 1 }
        defer {
            storeSubscription.cancel()
            lookupSubscription.cancel()
        }

        let edit = insertAtFive()
        model.noteEdit(
            url: url,
            previousLineStarts: edit.previous,
            newLineStarts: edit.new,
            editedRange: edit.range,
            changeInLength: edit.delta
        )

        XCTAssertEqual(entry()?.mapped?.map(\.range.location), [10], "the shift really moved the set")
        XCTAssertEqual(storePublishes, 1)
        XCTAssertEqual(lookupPublishes, 0)
        XCTAssertEqual(lookup, before)

        // ...while a change of worst severity does publish, once.
        model.noteSynced(url: url, version: 2, revision: model.currentRevision(for: url))
        model.receive(published([diagnostic(at: 10, length: 3, line: 2, severity: .warning, message: "m")], version: 2))
        XCTAssertEqual(lookupPublishes, 1)
        XCTAssertEqual(lookup.mark(for: url), .warning)
    }

    /// Pushes and keystrokes touch one document each, so they move the lookup
    /// for that file alone: across a workspace-sized burst and a shift the
    /// lookup is never rebuilt after the folder change's own build, and each
    /// push visits only its file's ancestry — counted apart from the table it
    /// writes, whatever the store already holds.
    func testOneDocumentsMutationMovesTheLookupWithoutARebuild() {
        model.prepareForFolderChange(root: root)
        XCTAssertEqual(model.treeRebuilds, 1)

        func push(_ index: Int) -> Int {
            let before = model.treeIndex?.steps ?? 0
            let file = root.appendingPathComponent("gen/d\(index % 37)/f\(index).swift")
            model.receive(positional([positionalDiagnostic(line: 0, character: 0, message: "e")], url: file))
            return (model.treeIndex?.steps ?? 0) - before
        }
        let first = push(0)
        for index in 1..<2_000 { _ = push(index) }
        let last = push(2_000)
        XCTAssertEqual(first, 4, "the file, its two folders and the root")
        XCTAssertEqual(last, first)

        // The tree holds every published lookup, so each push's write is a
        // copy-on-write — of the trie nodes on the file key's path, never of
        // the whole table: a single dictionary would copy every marked key
        // (2,040 by the end) on every push.
        func copied(_ index: Int) -> Int {
            let before = model.treeIndex?.copiedEntries ?? 0
            _ = push(index)
            return (model.treeIndex?.copiedEntries ?? 0) - before
        }
        let tableKeys = 2_001 + 37 + 2
        let late = copied(2_001)
        let depth = model.treeIndex?.lookup.table.depth ?? 0
        XCTAssertGreaterThan(late, 0, "the write really copied the shared table")
        XCTAssertLessThanOrEqual(late, depth * MarkTrie.fanout + MarkTrie.leafCapacity)
        XCTAssertLessThan(late, tableKeys / 16)
        XCTAssertEqual(lookup.mark(for: root.appendingPathComponent("gen/d5", isDirectory: true)), .error)

        syncAtVersionOne()
        model.receive(published([diagnostic(at: 8, length: 3, line: 2, message: "m")], version: 1))
        let edit = insertAtFive()
        model.noteEdit(
            url: url,
            previousLineStarts: edit.previous,
            newLineStarts: edit.new,
            editedRange: edit.range,
            changeInLength: edit.delta
        )
        XCTAssertEqual(model.treeRebuilds, 1)

        // A bulk clear is the one mutation that rebuilds — and its answer is
        // the same one the incremental moves would have reached.
        model.receive(.cleared(.server(serverID: serverID, root: root.path)))
        XCTAssertEqual(model.treeRebuilds, 2)
        XCTAssertEqual(lookup, .empty)
    }

    /// The folder change empties the lookup in its own turn — no hop between
    /// the call and the empty value.
    func testAFolderChangeResetsTheLookupToEmptySynchronously() {
        model.prepareForFolderChange(root: root)
        model.receive(positional([positionalDiagnostic(line: 0, character: 0, message: "e")]))
        XCTAssertEqual(lookup.mark(for: root), .error)

        model.prepareForFolderChange(root: URL(fileURLWithPath: "/tmp/other", isDirectory: true))
        XCTAssertEqual(lookup, .empty)
        XCTAssertEqual(lookup.mark(for: url), .none)
    }

    /// A server's teardown removes what that server marked, and only that.
    func testAServerClearRemovesItsMarks() {
        let goID = "gopls"
        let goFile = root.appendingPathComponent("cmd/main.go")
        model.prepareForFolderChange(root: root)
        model.receive(positional([positionalDiagnostic(line: 0, character: 0, message: "swift")]))
        model.receive(positional(
            [positionalDiagnostic(line: 0, character: 0, severity: .warning, message: "go")],
            url: goFile,
            serverID: goID
        ))
        XCTAssertEqual(lookup.mark(for: root), .error)

        model.receive(.cleared(.server(serverID: serverID, root: root.path)))
        XCTAssertEqual(lookup.mark(for: url), .none)
        XCTAssertEqual(lookup.mark(for: root), .warning)
        XCTAssertEqual(lookup.mark(for: goFile), .warning)

        model.receive(.cleared(.server(serverID: goID, root: root.path)))
        XCTAssertEqual(lookup, .empty)
    }

    /// With no folder recorded, the store still holds what arrives but the
    /// lookup has no spellings to place it under: it stays empty.
    func testWithNoRootTheLookupIsEmpty() {
        model.receive(positional([positionalDiagnostic(line: 0, character: 0, message: "e")]))
        XCTAssertNotNil(entry())
        XCTAssertEqual(lookup, .empty)
        XCTAssertEqual(lookup.mark(for: root), .none)
    }

    // MARK: - Query forwarding

    func testTheViewQueriesReadTheStore() {
        syncAtVersionOne()
        model.receive(published([
            diagnostic(at: 4, length: 3, line: 1, severity: .error, message: "err"),
            diagnostic(at: 8, length: 3, line: 2, severity: .hint, message: "tip"),
        ], version: 1))

        XCTAssertEqual(model.diagnostics(at: 5, in: url).map(\.message), ["err"])
        XCTAssertEqual(model.diagnostics(at: 9, in: url).map(\.message), ["tip"])
        XCTAssertEqual(
            model.worstSeverityPerLine(url: url, lineCount: 4, lineStarts: lineStarts),
            [nil, .error, .hint, nil]
        )
        XCTAssertEqual(model.rows(relativeTo: root).count, 1)
        XCTAssertEqual(model.rows(relativeTo: root).first?.rows.count, 2)
        XCTAssertEqual(model.counts.errors, 1)
        XCTAssertEqual(model.counts.warnings, 0)
    }

    /// The overlay's lookup (Task 6): the whole held set for one document —
    /// exact ranges and severities, not the per-line worst the gutter reads —
    /// and an empty array, never a trap, for a document nothing was received
    /// for.
    func testDiagnosticsInHandsTheDocumentsWholeSetForTheOverlay() {
        XCTAssertTrue(model.diagnostics(in: url).isEmpty)

        let set = [
            diagnostic(at: 4, length: 3, line: 1, severity: .error, message: "err"),
            diagnostic(at: 8, length: 3, line: 2, severity: .warning, message: "warn"),
        ]
        syncAtVersionOne()
        model.receive(published(set, version: 1))
        syncAtVersionOne(otherURL)
        model.receive(published(
            [diagnostic(at: 0, length: 1, line: 0, message: "other")],
            version: 1,
            url: otherURL
        ))

        XCTAssertEqual(model.diagnostics(in: url), set)
        XCTAssertEqual(model.diagnostics(in: otherURL).map(\.message), ["other"])
        // Closing keeps the set; a server clear empties the query like it
        // empties every other view surface.
        model.receive(.cleared(.document(url: url)))
        XCTAssertEqual(model.diagnostics(in: url), set)
        model.receive(.cleared(.server(serverID: serverID, root: root.path)))
        XCTAssertTrue(model.diagnostics(in: url).isEmpty)
    }

    /// The reconcile's *revision* clause, which the ordinary hold tests cannot
    /// reach because every one of them lands a report pinned to the current
    /// revision.
    ///
    /// The reachable failing case is a late report: two keystrokes move the
    /// buffer to revision 2, a push is held against it, and then a flush that
    /// began before those keystrokes finally reports, pinned to revision 1. Its
    /// record describes text the buffer has already moved past, so admitting the
    /// held set against it would paint squiggles at offsets nobody mapped — D32's
    /// whole prohibition. Without the clause the set lands; with it the hold is
    /// consumed and discarded, and the channel stays live for the next report.
    func testAHeldPushIsDiscardedWhenTheLandingReportIsPinnedToAMovedPastRevision() {
        let edit = insertAtFive()
        model.noteEdit(
            url: url,
            previousLineStarts: edit.previous,
            newLineStarts: edit.new,
            editedRange: edit.range,
            changeInLength: edit.delta
        )
        model.noteEdit(
            url: url,
            previousLineStarts: edit.new,
            newLineStarts: edit.new,
            editedRange: NSRange(location: 0, length: 0),
            changeInLength: 0
        )
        XCTAssertEqual(model.currentRevision(for: url), 2)

        // No record yet, so the push is held rather than dropped.
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "held")], version: 2))
        XCTAssertNil(entry())

        // The late report: pinned to revision 1, which the buffer has left.
        model.noteSynced(url: url, version: 2, revision: 1)
        XCTAssertNil(entry(), "a report describing moved-past text cannot admit a held set")

        // …and the channel is still live: the next current report's own push lands.
        model.noteSynced(url: url, version: 3, revision: 2)
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "fresh")], version: 3))
        XCTAssertEqual(entry()?.mapped?.map(\.message), ["fresh"])
    }

    // MARK: - Documents inside dependencies

    /// A model whose listing seam answers the root's listing with
    /// `rootListing` and every other directory with nothing, recording the
    /// last component of each directory asked. Keyed by last component because
    /// the rule asks with the canonical root, whose spelling of `/tmp` is the
    /// resolver's, not this suite's.
    private func dependencyModel(rootListing: [String]) -> (DiagnosticsModel, () -> [String]) {
        var asked: [String] = []
        let rootName = root.lastPathComponent
        let model = DiagnosticsModel(listNames: { directory in
            asked.append(directory.lastPathComponent)
            return directory.lastPathComponent == rootName ? rootListing : nil
        })
        return (model, { asked })
    }

    private var declarationFile: URL {
        root.appendingPathComponent("node_modules/x/index.d.ts")
    }

    /// The burst the drop exists for: a server reporting positionally on a
    /// declaration file under `node_modules`, beside `package.json`. Nothing
    /// lands — not the store, so not the panel's rows nor the tree's lookup —
    /// and the question cost one listing, the root's.
    func testAPositionalReportInsideDependenciesIsDropped() {
        let (dependencyModel, asked) = dependencyModel(rootListing: ["package.json", "node_modules", "Sources"])
        model = dependencyModel
        model.prepareForFolderChange(root: root)

        model.receive(positional(
            [positionalDiagnostic(line: 0, character: 0, message: "in a dependency")],
            url: declarationFile
        ))

        XCTAssertNil(entry(declarationFile))
        XCTAssertTrue(model.store.entriesByURL.isEmpty)
        XCTAssertTrue(model.rows(relativeTo: root).isEmpty)
        XCTAssertEqual(model.treeDiagnostics.lookup, .empty)
        XCTAssertEqual(asked(), ["pkg"], "one listing per table-named ancestor, the root's")
    }

    /// A published report about the same file is dropped before the gate, and
    /// is **not held**: neither with a current record present nor with none, so
    /// a later matching sync — the hold's admission moment — admits nothing.
    func testAPublishedReportInsideDependenciesIsDroppedAndNotHeld() {
        let (dependencyModel, _) = dependencyModel(rootListing: ["package.json", "node_modules"])
        model = dependencyModel
        model.prepareForFolderChange(root: root)
        let set = [diagnostic(declarationFile, at: 0, length: 3, line: 0, message: "in a dependency")]

        syncAtVersionOne(declarationFile)
        model.receive(published(set, version: 1, url: declarationFile))
        XCTAssertNil(entry(declarationFile), "dropped even against a current record")

        let unsynced = root.appendingPathComponent("node_modules/x/other.d.ts")
        model.receive(published(set, version: 1, url: unsynced))
        model.noteSynced(url: unsynced, version: 1, revision: 0)
        model.noteSynced(url: declarationFile, version: 1, revision: 0)
        XCTAssertNil(entry(unsynced), "nothing was held for the matching sync to admit")
        XCTAssertNil(entry(declarationFile))
        XCTAssertTrue(model.store.entriesByURL.isEmpty)
    }

    /// A marker created beside the folder mid-session: the set that landed
    /// while the folder was ordinary source is forgotten by the next report
    /// about that document, which is dropped, so no stale row outlives it.
    func testADroppedReportForgetsTheSetThatLandedBeforeTheMarkerAppeared() {
        var listing = ["vendor"]
        let rootName = root.lastPathComponent
        model = DiagnosticsModel(listNames: { directory in
            directory.lastPathComponent == rootName ? listing : nil
        })
        model.prepareForFolderChange(root: root)
        let file = root.appendingPathComponent("vendor/a.go")

        model.receive(positional([positionalDiagnostic(line: 0, character: 0, message: "before")], url: file))
        XCTAssertNotNil(entry(file))

        listing.append("go.mod")
        model.receive(positional([positionalDiagnostic(line: 0, character: 0, message: "after")], url: file))

        XCTAssertNil(entry(file))
        XCTAssertTrue(model.rows(relativeTo: root).isEmpty)
        XCTAssertEqual(model.treeDiagnostics.lookup, .empty)
    }

    /// A name alone is never enough: a `vendor` folder beside no marker is
    /// ordinary source, so its report lands, after the one listing that said so.
    func testAReportUnderAVendorFolderBesideNoMarkerLands() {
        let (dependencyModel, asked) = dependencyModel(rootListing: ["vendor", "README.md"])
        model = dependencyModel
        model.prepareForFolderChange(root: root)
        let file = root.appendingPathComponent("vendor/a.go")

        model.receive(positional([positionalDiagnostic(line: 0, character: 0, message: "mine")], url: file))

        XCTAssertNotNil(entry(file))
        XCTAssertEqual(asked(), ["pkg"])
    }

    /// An ordinary report, both kinds, lands and asks no listing at all: no
    /// component of its path is a table name.
    func testAnOrdinaryReportLandsWithoutAListing() {
        let (dependencyModel, asked) = dependencyModel(rootListing: ["package.json", "node_modules"])
        model = dependencyModel
        model.prepareForFolderChange(root: root)

        syncAtVersionOne()
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "mapped")], version: 1))
        model.receive(positional([positionalDiagnostic(line: 0, character: 0, message: "closed")], url: otherURL))

        XCTAssertEqual(entry()?.mapped?.map(\.message), ["mapped"])
        XCTAssertNotNil(entry(otherURL))
        XCTAssertEqual(asked(), [])
    }

    /// With no folder prepared there is no root to be inside dependencies
    /// under, so even a `node_modules` report lands, and nothing is listed.
    func testWithNoRootPreparedAReportInsideNodeModulesLands() {
        let (dependencyModel, asked) = dependencyModel(rootListing: ["package.json", "node_modules"])
        model = dependencyModel

        model.receive(positional(
            [positionalDiagnostic(line: 0, character: 0, message: "no root")],
            url: declarationFile
        ))

        XCTAssertNotNil(entry(declarationFile))
        XCTAssertEqual(asked(), [])
    }

    /// Clears are untouched by the drop: a server's teardown still empties
    /// what it reported, and a document clear asks no listing either.
    func testClearsAreNotAskedAboutDependencies() {
        let (dependencyModel, asked) = dependencyModel(rootListing: ["package.json", "node_modules"])
        model = dependencyModel
        model.prepareForFolderChange(root: root)
        model.receive(positional([positionalDiagnostic(line: 0, character: 0, message: "kept")], url: otherURL))

        model.receive(.cleared(.document(url: declarationFile)))
        model.receive(.cleared(.server(serverID: serverID, root: root.path)))

        XCTAssertNil(entry(otherURL))
        XCTAssertEqual(asked(), [])
    }
}
