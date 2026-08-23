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

        XCTAssertEqual(entry()?.diagnostics, set)
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

        XCTAssertEqual(entry()?.diagnostics.count, 1)
        XCTAssertEqual(entry()?.diagnostics.first?.message, "go")
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

        XCTAssertEqual(entry()?.diagnostics.count, 1)
        XCTAssertEqual(entry()?.diagnostics.first?.message, "first")
    }

    func testAPushForAMismatchedVersionIsDropped() {
        syncAtVersionOne()
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "m")], version: 2))

        XCTAssertNil(entry())
    }

    func testAPushWithoutAVersionIsAcceptedOnTheRevisionHalfAlone() {
        syncAtVersionOne()
        let set = [diagnostic(at: 4, length: 3, line: 1, severity: .warning, message: "unversioned")]
        model.receive(published(set, version: nil))

        XCTAssertEqual(entry()?.diagnostics, set)
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

        XCTAssertEqual(entry()?.diagnostics, set, "the landing record admits the held push")
        XCTAssertEqual(entry()?.serverKey, serverKey)
    }

    /// sourcekit-lsp sends no version: the reconcile must work on the revision
    /// half alone, or the primary server never passes the gate.
    func testAnUnversionedPushHeldBeforeItsSyncIsAppliedOnTheRevisionHalfAlone() {
        let set = [diagnostic(at: 4, length: 3, line: 1, severity: .warning, message: "unversioned")]
        model.receive(published(set, version: nil))

        model.noteSynced(url: url, version: 1, revision: 0)

        XCTAssertEqual(entry()?.diagnostics, set)
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
        XCTAssertEqual(entry()?.diagnostics, set)
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
        XCTAssertEqual(entry()?.diagnostics, set, "the settling sync's own push is what lands")
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
        XCTAssertEqual(entry()?.diagnostics, set)
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

        model.prepareForFolderChange()

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
        XCTAssertEqual(entry()?.diagnostics.first?.message, "swift")
        XCTAssertTrue(model.store.entry(for: otherURL)?.diagnostics.isEmpty ?? true)

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

        XCTAssertEqual(entry()?.diagnostics, set)
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
        XCTAssertEqual(entry()?.diagnostics.first?.message, "fresh")
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
        XCTAssertEqual(entry()?.diagnostics, fresh)
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

        model.prepareForFolderChange()

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

        XCTAssertEqual(entry()?.diagnostics.count, 2)
        // Untouched survivor keeps everything, including its stored line.
        XCTAssertEqual(entry()?.diagnostics.first, before)
        // Shifted survivor moves by the delta and renumbers from the new table:
        // offset 10 sits on new line 2 ("aaa\nXXbbb\n" ends at 10).
        let shifted = entry()?.diagnostics.last
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
        XCTAssertEqual(entry()?.diagnostics.first?.message, "next")
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

        XCTAssertEqual(model.store.entry(for: otherURL)?.diagnostics, otherSet)
        XCTAssertEqual(entry()?.diagnostics.map(\.message), ["main"])
        XCTAssertEqual(model.counts.errors, 1)
        XCTAssertEqual(model.counts.warnings, 1)
    }

    // MARK: - Folder change

    func testAFolderChangeDropsEveryPushUntilANewSyncArrives() {
        syncAtVersionOne()
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "old project")], version: 1))
        model.noteSynced(url: otherURL, version: 3, revision: 0)

        model.prepareForFolderChange()

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

    func testClearEventsRouteIntoTheStoreByDocumentThenByServer() {
        syncAtVersionOne()
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "m")], version: 1))

        model.receive(.cleared(.document(url: url)))
        XCTAssertNil(entry())

        // Re-sync and re-publish, then tear the whole server down.
        syncAtVersionOne()
        model.receive(published([diagnostic(at: 0, length: 3, line: 0, message: "m")], version: 1))
        model.receive(.cleared(.server(serverID: serverID, root: root.path)))
        XCTAssertNil(entry())
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
        // A clear empties the query like it empties every other view surface.
        model.receive(.cleared(.document(url: url)))
        XCTAssertTrue(model.diagnostics(in: url).isEmpty)
    }
}
