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
///   autosave's save sink, never through a clock;
/// - the editor bar's two actions the controller owns: Reload is refused while
///   the writer gate is up and otherwise discards the edits for the disk's text,
///   and Compare opens the buffer against the disk side under the
///   external-change title, as `LineDiff`'s rows;
/// - the guarded save's question (`resolveBeforeSave`): each answer's
///   resolution, the side each answer captures into Local History first, an
///   unreadable disk side capturing nothing, and a clean tab over an unreadable
///   file answering `.leftAlone` without asking.
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

    /// Stage tab `a.txt` in conflict: opened on `base`, edited to `buffer`, the
    /// file rewritten to `disk` by another writer, and the disk checked.
    private func conflictedTab(
        base: String, buffer: String, disk: String
    ) throws -> (model: WorkspaceModel, id: UUID) {
        let url = try write(base, "a.txt")
        let model = WorkspaceModel(fileService: FileService())
        let id = try model.open(url: url).id
        model.updateText(buffer, for: id)
        _ = try write(disk, "a.txt")
        model.checkDisk(id: id)
        XCTAssertTrue(model.isInExternalConflict(id), "the staging left the tab out of conflict")
        return (model, id)
    }

    func testTheBarsReloadWaitsForTheWriterGateAndThenTakesTheDisksText() throws {
        let (model, id) = try conflictedTab(base: "base\n", buffer: "mine\n", disk: "theirs, longer\n")
        let gate = CurrentValueSubject<Bool, Never>(true)
        let controller = DiskSyncController(ask: { _ in
            XCTFail("the bar's Reload is already an answer")
            return .cancel
        })
        var reloads: [UUID] = []
        controller.start(model: model, localHistory: nil, gate: gate.eraseToAnyPublisher()) { reloadedID, _ in
            reloads.append(reloadedID)
        }
        defer { controller.stop() }

        controller.reloadFromBar(id)
        XCTAssertEqual(model.text(for: id), "mine\n", "a reload under the writer gate read a file git may be writing")
        XCTAssertTrue(model.isInExternalConflict(id))
        XCTAssertEqual(reloads, [])

        gate.send(false)
        controller.reloadFromBar(id)
        XCTAssertEqual(model.text(for: id), "theirs, longer\n")
        XCTAssertFalse(model.isInExternalConflict(id))
        XCTAssertEqual(model.openFiles.first?.isDirty, false)
        XCTAssertEqual(reloads, [id])
    }

    /// A controller over `model` whose question always answers `answer`, with a
    /// real Local History store under the throwaway directory.
    private func questioned(
        _ model: WorkspaceModel, answering answer: DiskSyncController.Answer
    ) -> (DiskSyncController, LocalHistoryModel) {
        model.openFolder(url: directory)
        let history = LocalHistoryModel(
            base: directory.appendingPathComponent(".history", isDirectory: true),
            fileService: FileService()
        )
        let controller = DiskSyncController(ask: { _ in answer })
        controller.start(model: model, localHistory: history, gate: Just(false).eraseToAnyPublisher()) { _, _ in }
        return (controller, history)
    }

    /// The newest revision of `a.txt` and its text.
    private func newestRevision(in history: LocalHistoryModel) -> (LocalHistorySnapshot, String?)? {
        guard let newest = history.store.revisions(root: directory, relativePath: "a.txt").first else { return nil }
        return (newest, history.store.content(of: newest, root: directory, relativePath: "a.txt"))
    }

    func testOverwriteCapturesTheDiskSideAndAnswersAnOverwritingWrite() async throws {
        let (model, id) = try conflictedTab(base: "base\n", buffer: "mine\n", disk: "theirs, longer\n")
        let (controller, history) = questioned(model, answering: .overwrite)
        defer { controller.stop() }

        XCTAssertEqual(controller.resolveBeforeSave(id), .write(.overwrite))

        await history.waitForQueuedWrites()
        let (snapshot, text) = try XCTUnwrap(newestRevision(in: history))
        XCTAssertEqual(snapshot.event, .overwrite)
        XCTAssertEqual(text, "theirs, longer\n")
        XCTAssertEqual(model.text(for: id), "mine\n")
    }

    func testReloadCapturesTheBufferAndReloadsTheDisksText() async throws {
        let (model, id) = try conflictedTab(base: "base\n", buffer: "mine\n", disk: "theirs, longer\n")
        let (controller, history) = questioned(model, answering: .reload)
        defer { controller.stop() }

        XCTAssertEqual(controller.resolveBeforeSave(id), .reloaded)

        await history.waitForQueuedWrites()
        let (snapshot, text) = try XCTUnwrap(newestRevision(in: history))
        XCTAssertEqual(snapshot.event, .discard)
        XCTAssertEqual(text, "mine\n")
        XCTAssertEqual(model.text(for: id), "theirs, longer\n")
        XCTAssertFalse(model.isInExternalConflict(id))
    }

    func testCancelCapturesNothingAndChangesNothing() async throws {
        let (model, id) = try conflictedTab(base: "base\n", buffer: "mine\n", disk: "theirs, longer\n")
        let (controller, history) = questioned(model, answering: .cancel)
        defer { controller.stop() }

        XCTAssertEqual(controller.resolveBeforeSave(id), .cancelled)

        await history.waitForQueuedWrites()
        XCTAssertNil(newestRevision(in: history))
        XCTAssertEqual(model.text(for: id), "mine\n")
        XCTAssertTrue(model.isInExternalConflict(id))
    }

    func testAnAnswerGivenByTheCallerIsNotAsked() throws {
        let (model, id) = try conflictedTab(base: "base\n", buffer: "mine\n", disk: "theirs, longer\n")
        let controller = DiskSyncController(ask: { _ in
            XCTFail("the bar's Overwrite is already an answer")
            return .cancel
        })
        controller.start(model: model, localHistory: nil, gate: Just(false).eraseToAnyPublisher()) { _, _ in }
        defer { controller.stop() }

        XCTAssertEqual(controller.resolveBeforeSave(id, answer: .overwrite), .write(.overwrite))
    }

    func testNoConflictWritesUnderTheRefusingPolicyWithoutAsking() throws {
        let url = try write("base\n", "a.txt")
        let model = WorkspaceModel(fileService: FileService())
        let id = try model.open(url: url).id
        model.updateText("mine\n", for: id)
        let controller = DiskSyncController(ask: { _ in
            XCTFail("a tab out of conflict is never asked about")
            return .cancel
        })
        controller.start(model: model, localHistory: nil, gate: Just(false).eraseToAnyPublisher()) { _, _ in }
        defer { controller.stop() }

        XCTAssertEqual(controller.resolveBeforeSave(id), .write(.refuse))
    }

    /// Overwriting a file the app cannot read stores no revision: the disk's text
    /// is not known, and an empty one would claim content the file never held.
    func testOverwritingAnUnreadableFileCapturesNothing() async throws {
        let (model, id) = try conflictedTab(base: "base\n", buffer: "mine\n", disk: "theirs, longer\n")
        let url = directory.appendingPathComponent("a.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let (controller, history) = questioned(model, answering: .overwrite)
        defer { controller.stop() }

        XCTAssertEqual(controller.resolveBeforeSave(id), .write(.overwrite))
        XCTAssertEqual(model.observedDiskSides[id], ObservedDiskSide(text: nil))

        await history.waitForQueuedWrites()
        XCTAssertNil(newestRevision(in: history))
    }

    /// A clean tab whose file became unreadable has nothing to write: the save
    /// succeeds without writing and without asking.
    func testACleanTabOverAnUnreadableFileIsLeftAlone() throws {
        let url = try write("base\n", "a.txt")
        let model = WorkspaceModel(fileService: FileService())
        let id = try model.open(url: url).id
        _ = try write("rewritten, longer\n", "a.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let controller = DiskSyncController(ask: { _ in
            XCTFail("a clean tab is never asked about")
            return .cancel
        })
        controller.start(model: model, localHistory: nil, gate: Just(false).eraseToAnyPublisher()) { _, _ in }
        defer { controller.stop() }

        XCTAssertEqual(controller.resolveBeforeSave(id), .leftAlone)
        XCTAssertEqual(model.text(for: id), "base\n")
        XCTAssertFalse(model.isInExternalConflict(id))
    }

    func testCompareShowsTheBufferAgainstTheDiskSideUnderTheExternalChangeTitle() async throws {
        let (model, id) = try conflictedTab(base: "one\ntwo\n", buffer: "one\nlet value = 1\n", disk: "one\nlet value = 22\n")
        let controller = DiskSyncController()
        controller.start(model: model, localHistory: nil, gate: Just(false).eraseToAnyPublisher()) { _, _ in }
        defer { controller.stop() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DiskSyncControllerTests-\(UUID().uuidString)"))
        let settings = SettingsStore(defaults: defaults)

        let compare = try XCTUnwrap(controller.compareContent(of: id, settings: settings))
        XCTAssertEqual(compare.title, DiffWindowTitle.externalChange(path: "a.txt"))
        let rows = await compare.content.load()
        XCTAssertEqual(rows, LineDiff.rows(old: "one\nlet value = 1\n", new: "one\nlet value = 22\n"))
        let modified = try XCTUnwrap(
            rows.first { $0.kind == .modified },
            "the buffer and the disk differ on one line, which Compare must pair as a modification"
        )
        XCTAssertNotNil(modified.words, "Compare carries the word emphasis LineDiff computes")

        // The texts were snapshotted when Compare was pressed.
        model.updateText("one\nchanged after the press\n", for: id)
        let again = await compare.content.load()
        XCTAssertEqual(again, rows)

        // A tab out of conflict opens nothing.
        model.updateText("one\nlet value = 22\n", for: id)
        XCTAssertFalse(model.isInExternalConflict(id))
        XCTAssertNil(controller.compareContent(of: id, settings: settings))
    }
}
#endif
