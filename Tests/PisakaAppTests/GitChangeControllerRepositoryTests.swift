#if os(macOS)
import AppKit
import XCTest
@testable import Pisaka
@testable import PisakaCore

/// `GitChangeController` against the real `git`, in throwaway repositories:
/// the base is `git cat-file --filters HEAD:./<name>` run in the file's
/// directory (a CRLF checkout included, and a sibling of a switched file), an edit
/// produces a hunk once the coalescing delay elapses, the revert plan built from
/// that hunk restores the committed bytes exactly, and an untracked file draws
/// nothing.
///
/// The revert also runs end to end through the coordinator (Task 9's path): the
/// popover's request and the caret's menu item both land as **one undo step** —
/// undo brings the edit back, redo reverts again — and a raised writer gate
/// leaves the buffer untouched without raising anything itself. *Next Change* /
/// *Previous Change* step through the hunks recomputed from the live buffer,
/// wrap, answer `false` (a beep) with none, and ignore the gate, being a move.
///
/// Every wait is on `onChangesInstalled` — an answer that *must* reach the ruler
/// — never on a delay, so the 250 ms coalescing window is waited out causally.
@MainActor
final class GitChangeControllerRepositoryTests: XCTestCase {
    private var scratch: URL!
    private var controller: GitChangeController!
    /// Kept alive for the test's duration: the coordinator holds its text view
    /// weakly, and the controller its ruler.
    private var coordinators: [CodeEditorView.Coordinator] = []
    private var harnesses: [Harness] = []

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitChangeControllerRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        controller = GitChangeController()
    }

    override func tearDownWithError() throws {
        controller?.reset()
        controller = nil
        coordinators = []
        harnesses = []
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
        scratch = nil
    }

    private struct Harness {
        let scrollView: NSScrollView
        let textView: NSTextView
        let ruler: LineNumberRulerView
    }

    // MARK: - Tests

    func testTheBaseLoadsAndAnUnchangedBufferDrawsNothing() async throws {
        let (file, committed) = try committedFile(contents: "one\ntwo\nthree\n")
        let harness = makeHarness(text: committed)

        let changes = await install { self.sync(file, harness) }

        XCTAssertEqual(controller.base, committed)
        XCTAssertTrue(changes.hunks.isEmpty)
        XCTAssertTrue(harness.ruler.changeMarkers.isEmpty)
    }

    func testAnEditProducesAHunkAndItsRevertRestoresTheCommittedBytes() async throws {
        let (file, committed) = try committedFile(contents: "one\ntwo\nthree\n")
        let harness = makeHarness(text: committed)
        _ = await install { self.sync(file, harness) }

        let changes = await install {
            self.edit(harness, replacing: NSRange(location: 4, length: 3), with: "TWO\nmore")
        }

        XCTAssertEqual(changes.hunks.map(\.kind), [.modified])
        XCTAssertEqual(harness.ruler.changeMarkers[1]?.strip, .modified)
        XCTAssertEqual(harness.ruler.changeMarkers[2]?.strip, .modified)
        XCTAssertEqual(revertingFirstHunk(harness), committed)
    }

    func testARevertAtAnUnterminatedEndRestoresTheMissingNewline() async throws {
        let (file, committed) = try committedFile(contents: "one\ntwo")
        let harness = makeHarness(text: committed)
        _ = await install { self.sync(file, harness) }

        let changes = await install {
            self.edit(harness, replacing: NSRange(location: 7, length: 0), with: "\nthree\n")
        }

        XCTAssertEqual(changes.hunks.map(\.kind), [.added])
        XCTAssertEqual(revertingFirstHunk(harness), committed)
    }

    func testAnUntrackedFileDrawsNothing() async throws {
        let repo = try fixture.makeRepository("repo")
        try fixture.commitFile("tracked.txt", contents: "x\n", in: repo)
        let file = repo.appendingPathComponent("untracked.txt")
        try Data("new\n".utf8).write(to: file)
        let harness = makeHarness(text: "new\n")

        let changes = await install { self.sync(file, harness) }

        XCTAssertNil(controller.base)
        XCTAssertTrue(changes.hunks.isEmpty)
        XCTAssertTrue(harness.ruler.changeMarkers.isEmpty)
        XCTAssertTrue(controller.currentChanges(buffer: "anything\n").hunks.isEmpty)
    }

    func testAMovedGitRevisionAloneRereadsTheBase() async throws {
        let (file, committed) = try committedFile(contents: "one\n")
        let harness = makeHarness(text: committed)
        let fileID = UUID()
        controller.attach(ruler: harness.ruler, textView: harness.textView)
        _ = await install {
            self.controller.sync(fileID: fileID, fileURL: file, diskRevision: 0, gitRevision: 0, contentReplaced: true)
        }
        // A commit the buffer never saw: only the Local Changes refresh moves.
        try fixture.commitFile("file.txt", contents: "two\n", in: file.deletingLastPathComponent())

        let changes = await install {
            self.controller.sync(fileID: fileID, fileURL: file, diskRevision: 0, gitRevision: 1, contentReplaced: false)
        }

        XCTAssertEqual(controller.base, "two\n")
        XCTAssertEqual(changes.hunks.map(\.kind), [.modified])
        XCTAssertEqual(harness.ruler.changeMarkers.first??.strip, .modified)
    }

    func testASwitchWhileAReadIsInFlightInstallsOnlyTheNewFilesBase() async throws {
        let repo = try fixture.makeRepository("repo")
        try fixture.commitFile("a.txt", contents: "alpha\n", in: repo)
        try fixture.commitFile("b.txt", contents: "beta\n", in: repo)
        let harness = makeHarness(text: "beta\n")
        controller.attach(ruler: harness.ruler, textView: harness.textView)

        // `a`'s read is running when `b` is asked for, so `b` waits as the
        // pending read; `a`'s answer resumes stale and must be dropped.
        let changes = await install {
            self.controller.sync(
                fileID: UUID(), fileURL: repo.appendingPathComponent("a.txt"),
                diskRevision: 0, gitRevision: 0, contentReplaced: true
            )
            self.controller.sync(
                fileID: UUID(), fileURL: repo.appendingPathComponent("b.txt"),
                diskRevision: 0, gitRevision: 0, contentReplaced: true
            )
        }

        // The first answer to reach the ruler is `b`'s: `a`'s base against the
        // `beta` buffer would have been a modified hunk.
        XCTAssertTrue(changes.hunks.isEmpty, "the stale read reached the ruler")
        XCTAssertEqual(controller.base, "beta\n")
    }

    func testABufferSwapDropsTheMarksAndKeepsTheBase() async throws {
        let (file, committed) = try committedFile(contents: "one\ntwo\nthree\n")
        let harness = makeHarness(text: committed)
        _ = await install { self.sync(file, harness) }
        _ = await install {
            self.edit(harness, replacing: NSRange(location: 4, length: 3), with: "TWO")
        }
        XCTAssertFalse(harness.ruler.changeMarkers.isEmpty)

        controller.beginBufferSwap()

        XCTAssertTrue(harness.ruler.changeMarkers.isEmpty)
        XCTAssertEqual(controller.base, committed)
    }

    // MARK: - Revert through the coordinator

    func testAMarkerRevertIsOneUndoStepAndRedoRevertsAgain() async throws {
        let (file, committed) = try committedFile(contents: "one\ntwo\nthree\n")
        let editor = try await editedEditor(file: file, committed: committed)

        XCTAssertEqual(editor.grouped { editor.coordinator.revertChange(atMarker: 1) }, .reverted)
        XCTAssertEqual(editor.text, committed)
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 4, length: 0))

        editor.undoManager.undo()
        XCTAssertEqual(editor.text, editor.edited)
        editor.undoManager.redo()
        XCTAssertEqual(editor.text, committed)
    }

    func testTheCaretsRevertChangeRevertsItsHunk() async throws {
        let (file, committed) = try committedFile(contents: "one\ntwo\nthree\n")
        let editor = try await editedEditor(file: file, committed: committed)

        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.coordinator.revertChangeAtCaret(), .noHunk)
        XCTAssertEqual(editor.text, editor.edited)

        editor.textView.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertEqual(editor.grouped { editor.coordinator.revertChangeAtCaret() }, .reverted)
        XCTAssertEqual(editor.text, committed)
    }

    func testARaisedWriterGateLeavesTheBufferUntouched() async throws {
        let (file, committed) = try committedFile(contents: "one\ntwo\nthree\n")
        let editor = try await editedEditor(file: file, committed: committed)
        editor.coordinator.gitChanges.writeInFlight = { true }

        XCTAssertEqual(editor.coordinator.revertChange(atMarker: 1), .refused)
        editor.textView.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertEqual(editor.coordinator.revertChangeAtCaret(), .refused)
        XCTAssertEqual(editor.text, editor.edited)
        XCTAssertFalse(editor.undoManager.canUndo)
    }

    // MARK: - Next / Previous Change through the coordinator

    func testNextAndPreviousChangeStepThroughTheLiveHunksAndWrap() async throws {
        let (file, committed) = try committedFile(contents: "one\ntwo\nthree\nfour\n")
        let editor = try await editedEditor(file: file, committed: committed)
        // A second hunk, never waited for: the commands recompute from the live
        // buffer rather than from the drawn answer; "three" stays between the two.
        editor.textView.textStorage?.replaceCharacters(in: NSRange(location: 19, length: 4), with: "FOUR")
        XCTAssertEqual(editor.text, "one\nTWO\nmore\nthree\nFOUR\n")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertTrue(editor.coordinator.goToChange(.next))
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 4, length: 0))
        XCTAssertTrue(editor.coordinator.goToChange(.next))
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 19, length: 0))
        XCTAssertTrue(editor.coordinator.goToChange(.next), "next wraps to the first hunk")
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 4, length: 0))
        XCTAssertTrue(editor.coordinator.goToChange(.previous), "previous wraps to the last hunk")
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 19, length: 0))
        XCTAssertEqual(editor.text, "one\nTWO\nmore\nthree\nFOUR\n", "navigation edited the buffer")
    }

    func testChangeNavigationAnswersFalseWithNoHunks() async throws {
        let (file, committed) = try committedFile(contents: "one\ntwo\nthree\n")
        let editor = try await editedEditor(file: file, committed: committed)
        XCTAssertEqual(editor.grouped { editor.coordinator.revertChange(atMarker: 1) }, .reverted)
        editor.textView.setSelectedRange(NSRange(location: 2, length: 0))

        XCTAssertFalse(editor.coordinator.goToChange(.next))
        XCTAssertFalse(editor.coordinator.goToChange(.previous))
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 2, length: 0))
    }

    func testChangeNavigationIgnoresTheWriterGate() async throws {
        let (file, committed) = try committedFile(contents: "one\ntwo\nthree\n")
        let editor = try await editedEditor(file: file, committed: committed)
        editor.coordinator.gitChanges.writeInFlight = { true }
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertTrue(editor.coordinator.goToChange(.next), "a move is not a write")
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 4, length: 0))
    }

    func testAMarkerClickPresentsTheHeadLinesAndItsRevertGoesThroughTheCoordinator() async throws {
        let (file, committed) = try committedFile(contents: "one\ntwo\nthree\n")
        let editor = try await editedEditor(file: file, committed: committed)
        var requests: [ChangeHunkPopoverRequest] = []
        var dismissals = 0
        let controller = editor.coordinator.gitChanges
        controller.popover = ChangeHunkPopoverPresenting(
            present: { requests.append($0) },
            dismiss: { dismissals += 1 }
        )
        controller.revert = { [weak coordinator = editor.coordinator] in
            coordinator?.revertChange(atMarker: $0)
        }

        controller.markerClicked(line: 0, rect: .zero)
        XCTAssertTrue(requests.isEmpty, "an unmarked line opened a popover")
        controller.markerClicked(line: 2, rect: NSRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.headLines, ["two"])
        XCTAssertEqual(requests.first?.anchor, NSRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertTrue(requests.first?.anchorView === editor.ruler)

        editor.undoManager.beginUndoGrouping()
        requests.first?.revert()
        editor.undoManager.endUndoGrouping()
        XCTAssertEqual(editor.text, committed)

        // Any buffer change dismisses the popover.
        let before = dismissals
        controller.noteEdit()
        XCTAssertEqual(dismissals, before + 1)
    }

    // MARK: - Helpers

    /// A coordinator-driven editor over the committed `file`, whose line 2 has
    /// been rewritten as two lines (`"TWO\nmore"`) once the base loaded, the
    /// way `EditingCommandRoutingTests` wires one: the coordinator as delegate,
    /// undo on, grouping by hand since no event loop runs.
    private struct Editor {
        let coordinator: CodeEditorView.Coordinator
        let textView: NSTextView
        let ruler: LineNumberRulerView
        let undoManager: UndoManager
        let edited: String
        var text: String { textView.string }

        func grouped<T>(_ body: () -> T) -> T {
            undoManager.beginUndoGrouping()
            defer { undoManager.endUndoGrouping() }
            return body()
        }
    }

    private func editedEditor(file: URL, committed: String) async throws -> Editor {
        let harness = makeHarness(text: committed)
        harnesses.append(harness)
        let coordinator = CodeEditorView.Coordinator(text: .constant(committed))
        coordinator.textView = harness.textView
        coordinator.fileID = UUID()
        harness.textView.delegate = coordinator
        harness.textView.allowsUndo = true
        let undoManager = try XCTUnwrap(coordinator.undoManager(for: harness.textView))
        undoManager.groupsByEvent = false
        controller = coordinator.gitChanges
        coordinators.append(coordinator)
        _ = await install { self.sync(file, harness) }
        let changes = await install {
            self.edit(harness, replacing: NSRange(location: 4, length: 3), with: "TWO\nmore")
        }
        XCTAssertEqual(changes.hunks.map(\.kind), [.modified])
        return Editor(
            coordinator: coordinator,
            textView: harness.textView,
            ruler: harness.ruler,
            undoManager: undoManager,
            edited: harness.textView.string
        )
    }

    private var fixture: ThrowawayRepository { ThrowawayRepository(scratch: scratch) }

    /// A repository with `file.txt` committed as `contents`, read back from `HEAD`.
    private func committedFile(contents: String) throws -> (URL, String) {
        let repo = try fixture.makeRepository("repo")
        try fixture.commitFile("file.txt", contents: contents, in: repo)
        let committed = try fixture.git(["show", "HEAD:file.txt"], in: repo)
        XCTAssertEqual(committed, contents)
        return (repo.appendingPathComponent("file.txt"), committed)
    }

    private func sync(_ file: URL, _ harness: Harness) {
        controller.attach(ruler: harness.ruler, textView: harness.textView)
        controller.sync(fileID: UUID(), fileURL: file, diskRevision: 0, gitRevision: 0, contentReplaced: true)
    }

    /// An edit through the text storage, forwarded the way the coordinator's
    /// `bufferEdited` does.
    private func edit(_ harness: Harness, replacing range: NSRange, with replacement: String) {
        harness.textView.textStorage?.replaceCharacters(in: range, with: replacement)
        controller.noteEdit()
    }

    /// Run `action` and wait for the next answer to reach the ruler.
    private func install(_ action: @escaping () -> Void) async -> GutterChanges {
        let arrived = expectation(description: "an answer reaches the ruler")
        var answer = GutterChanges(hunks: [], lineCount: 0)
        controller.onChangesInstalled = { changes in
            answer = changes
            arrived.fulfill()
        }
        action()
        await fulfillment(of: [arrived], timeout: 10)
        controller.onChangesInstalled = nil
        return answer
    }

    /// The buffer after applying the revert plan for its first hunk, recomputed
    /// synchronously as the commands do.
    private func revertingFirstHunk(_ harness: Harness) -> String? {
        let buffer = harness.textView.string
        guard let base = controller.base,
              let hunk = controller.currentChanges(buffer: buffer).hunks.first,
              let plan = HunkRevertPlan.plan(hunk: hunk, base: base, buffer: buffer) else {
            XCTFail("no revert plan for the buffer's first hunk")
            return nil
        }
        let result = NSMutableString(string: buffer)
        for edit in plan.edits.reversed() {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }

    private func makeHarness(text: String) -> Harness {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.textContainer?.replaceLayoutManager(BracketOverlayLayoutManager())
        scroll.documentView = textView
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.string = text
        let ruler = LineNumberRulerView(scrollView: scroll, textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        return Harness(scrollView: scroll, textView: textView, ruler: ruler)
    }
}

#endif
