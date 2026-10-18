#if os(macOS)
import AppKit
import XCTest
@testable import Pisaka
@testable import PisakaCore

/// `GitChangeController` against the real `git`, in throwaway repositories:
/// the base is `git show HEAD:./<name>` run in the file's directory, an edit
/// produces a hunk once the coalescing delay elapses, the revert plan built from
/// that hunk restores the committed bytes exactly, and an untracked file draws
/// nothing.
///
/// Every wait is on `onChangesInstalled` — an answer that *must* reach the ruler
/// — never on a delay, so the 250 ms coalescing window is waited out causally.
@MainActor
final class GitChangeControllerRepositoryTests: XCTestCase {
    private var scratch: URL!
    private var controller: GitChangeController!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitChangeControllerRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        controller = GitChangeController()
    }

    override func tearDownWithError() throws {
        controller?.reset()
        controller = nil
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

    // MARK: - Helpers

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
