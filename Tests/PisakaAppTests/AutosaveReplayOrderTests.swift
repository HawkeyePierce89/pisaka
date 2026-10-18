#if os(macOS)
import XCTest
import PisakaCore
@testable import Pisaka

/// `AutosaveController`'s replay ordering, which `swift test` cannot see
/// because it lives in the controller's wiring rather than in Core:
///
/// - a trigger that fired while the writer gate was up is replayed on the
///   main-actor turn **after** `resume()`, never inside it — so a gated
///   operation's own resync, which runs in the same synchronous stretch as its
///   gate drop, reconciles a tab edited across it before the replay judges it;
/// - a gate raised again before that turn keeps the pending save, and the
///   save is replayed after the next drop.
///
/// Real files in a throwaway directory, through the real `FileService`; the
/// replay is observed through the autosave's save sink, never through a clock.
@MainActor
final class AutosaveReplayOrderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutosaveReplayOrderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, _ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func diskText(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func testTheReplayRunsAfterTheOperationsOwnResync() throws {
        let edited = try write("base\n", "edited.txt")
        let other = try write("other\n", "other.txt")
        let model = WorkspaceModel(fileService: FileService())
        let editedID = try model.open(url: edited).id
        let otherID = try model.open(url: other).id
        model.select(editedID)
        model.updateText("edited in the app\n", for: editedID)
        let autosave = AutosaveController()
        defer { autosave.stop() }
        let saved = expectation(description: "the replayed autosave wrote the edited tab")
        saved.assertForOverFulfill = false
        autosave.start(model: model, prepareForSave: { _, _ in }, onSaved: { urls, _, _ in
            if urls.contains(edited) { saved.fulfill() }
        })

        // The operation raises its gate, and a trigger fires under it.
        autosave.suspend()
        model.select(otherID)
        XCTAssertTrue(autosave.pendingAutosave)

        // The operation writes the file, then — in one synchronous stretch —
        // lowers the gate and resyncs the edited tab.
        _ = try write("written by the checkout\n", "edited.txt")
        autosave.resume()
        XCTAssertTrue(model.reconcileSavedBaseline(id: editedID))

        XCTAssertTrue(model.isDirty(for: editedID))
        XCTAssertFalse(model.isInExternalConflict(editedID))

        wait(for: [saved], timeout: 5)
        XCTAssertFalse(model.isInExternalConflict(editedID))
        XCTAssertFalse(model.isDirty(for: editedID))
        XCTAssertEqual(try diskText(edited), "edited in the app\n")
    }

    func testAGateRaisedBeforeTheReplaysTurnKeepsThePendingSave() throws {
        let edited = try write("base\n", "edited.txt")
        let other = try write("other\n", "other.txt")
        let model = WorkspaceModel(fileService: FileService())
        let editedID = try model.open(url: edited).id
        let otherID = try model.open(url: other).id
        model.select(editedID)
        model.updateText("edited in the app\n", for: editedID)
        let autosave = AutosaveController()
        defer { autosave.stop() }
        var savedEdited = false
        let saved = expectation(description: "the replay after the second drop wrote the edited tab")
        saved.assertForOverFulfill = false
        autosave.start(model: model, prepareForSave: { _, _ in }, onSaved: { urls, _, _ in
            if urls.contains(edited) {
                savedEdited = true
                saved.fulfill()
            }
        })

        autosave.suspend()
        model.select(otherID)
        XCTAssertTrue(autosave.pendingAutosave)

        // The gate drops and is raised again before the replay's turn.
        autosave.resume()
        autosave.suspend()

        // Main-actor jobs run in the order they were enqueued: this one runs
        // after the replay's turn has come and gone.
        let turnPassed = expectation(description: "the replay's turn has passed")
        Task { @MainActor in turnPassed.fulfill() }
        wait(for: [turnPassed], timeout: 5)

        XCTAssertTrue(autosave.pendingAutosave)
        XCTAssertFalse(savedEdited)
        XCTAssertTrue(model.isDirty(for: editedID))
        XCTAssertEqual(try diskText(edited), "base\n")

        autosave.resume()
        wait(for: [saved], timeout: 5)
        XCTAssertFalse(autosave.pendingAutosave)
        XCTAssertFalse(model.isDirty(for: editedID))
        XCTAssertEqual(try diskText(edited), "edited in the app\n")
    }
}

#endif
