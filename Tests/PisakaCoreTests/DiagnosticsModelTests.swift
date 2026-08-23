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

    private var serverKey: DiagnosticStore.ServerKey {
        DiagnosticStore.ServerKey(serverID: serverID, root: root.path)
    }

    override func setUp() {
        super.setUp()
        model = DiagnosticsModel()
    }

    private var model = DiagnosticsModel()

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
        XCTAssertEqual(entry()?.version, 1)
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
}
