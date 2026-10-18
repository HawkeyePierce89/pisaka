#if os(macOS)
import Combine
import XCTest
import PisakaCore
@testable import Pisaka

/// `DiskSyncController`'s two app-layer rules, which `swift test` cannot see
/// because both live in the controller's wiring rather than in Core:
///
/// - a pass requested while the writer gate is up is **deferred**, and runs once
///   when the gate comes down;
/// - a watcher pass over unchanged files publishes nothing, so a burst of them
///   does **not re-arm the autosave idle debounce** — observed through
///   autosave's save sink, never through a clock.
///
/// Real files in a throwaway directory, through the real `FileService`.
@MainActor
final class DiskSyncControllerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSyncControllerTests-\(UUID().uuidString)", isDirectory: true)
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

    func testAPassRequestedWhileTheGateIsUpRunsOnceWhenItComesDown() throws {
        let url = try write("before", "a.txt")
        let model = WorkspaceModel(fileService: FileService())
        let id = try model.open(url: url).id
        let gate = CurrentValueSubject<Bool, Never>(true)
        let controller = DiskSyncController(ask: { _ in
            XCTFail("a clean tab is reloaded, never asked about")
            return .cancel
        })
        var reloads: [UUID] = []
        controller.start(model: model, localHistory: nil, gate: gate.eraseToAnyPublisher()) { reloadedID, _ in
            reloads.append(reloadedID)
        }
        defer { controller.stop() }
        _ = try write("after, from a tool", "a.txt")

        controller.requestPass()
        controller.requestPass()

        XCTAssertTrue(controller.passPending)
        XCTAssertEqual(model.text(for: id), "before")
        XCTAssertEqual(reloads, [])

        gate.send(false)

        XCTAssertFalse(controller.passPending)
        XCTAssertEqual(model.text(for: id), "after, from a tool")
        XCTAssertEqual(reloads, [id])

        // Nothing is owed any more: raising and lowering the gate again runs no pass.
        _ = try write("changed again, but no pass was asked for", "a.txt")
        gate.send(true)
        gate.send(false)
        XCTAssertEqual(model.text(for: id), "after, from a tool")
        XCTAssertEqual(reloads, [id])
    }

    /// A dirty, unrelated tab still autosaves while unchanged-file passes keep
    /// arriving faster than the idle debounce. A pass that republished
    /// `$openFiles` would re-arm the debounce each time, and the save sink would
    /// never be reached; the expectation is that sink.
    func testWatcherPassesOverUnchangedFilesDoNotHoldOffTheIdleAutosave() throws {
        let edited = try write("original", "edited.txt")
        let untouched = try write("untouched", "untouched.txt")
        let model = WorkspaceModel(fileService: FileService())
        let editedID = try model.open(url: edited).id
        try model.open(url: untouched)
        let controller = DiskSyncController()
        controller.start(model: model, localHistory: nil, gate: Just(false).eraseToAnyPublisher()) { _, _ in }
        defer { controller.stop() }
        let autosave = AutosaveController()
        defer { autosave.stop() }
        let saved = expectation(description: "the idle autosave wrote the dirty tab")
        autosave.start(model: model, prepareForSave: { _, _ in }, onSaved: { urls, _, _ in
            if urls.contains(edited) { saved.fulfill() }
        })

        model.updateText("edited in the app", for: editedID)
        var passes = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                controller.requestPass()
                passes += 1
            }
        }
        defer { timer.invalidate() }

        wait(for: [saved], timeout: 15)
        XCTAssertGreaterThan(passes, 0)
        XCTAssertEqual(try String(contentsOf: edited, encoding: .utf8), "edited in the app")
    }
}
#endif
