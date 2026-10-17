#if os(macOS)
import AppKit
import PisakaCore
import XCTest
@testable import Pisaka

/// A retarget of the shown tab (R2/R5): the coordinator's
/// `resetCaretHighlights(ifRetargeted:language:)`, which `updateNSView` calls
/// for a URL, root or language change, and `scheduleCaretHighlightSettle()`,
/// which it calls after any buffer swap.
///
/// What it pins:
/// - a retarget drops the painted answer, and the settle scheduled afterwards
///   brings the caret's highlight back without the caret moving — observed on
///   the matching-tag controller, which needs no provider;
/// - why the settle is scheduled *after* the swap: the swap's edit cancels a
///   settle queued before it, so reset → swap → schedule repaints the incoming
///   text while nothing moves the caret;
/// - an update that retargets nothing, and changes no language, leaves the
///   painted answer alone.
///
/// The first paint is the controller's own settle task, awaited. The
/// repaint goes through the 75 ms debounce, so the assertion polls for the
/// controller's record and fails loudly on timeout.
@MainActor
final class CaretHighlightRetargetTests: XCTestCase {

    func testARetargetRepaintsWithoutACaretMove() async throws {
        let editor = try await makeEditor()
        XCTAssertFalse(editor.coordinator.tagHighlight.paintedRanges.isEmpty, "the first settle painted nothing")

        XCTAssertTrue(editor.coordinator.resetCaretHighlights(ifRetargeted: true, language: .html))
        XCTAssertTrue(editor.coordinator.tagHighlight.paintedRanges.isEmpty, "a retarget kept the old answer")

        editor.coordinator.scheduleCaretHighlightSettle()
        await waitFor("the retarget's settle to repaint") {
            !editor.coordinator.tagHighlight.paintedRanges.isEmpty
        }
    }

    func testASettleScheduledAfterTheSwapSurvivesIt() async throws {
        let editor = try await makeEditor()
        let selection = editor.harness.textView.selectedRange()
        XCTAssertTrue(editor.coordinator.resetCaretHighlights(ifRetargeted: true, language: .html))

        // The same text reinstalled, as a switch to a tab holding it would:
        // the storage still posts its full-range edit, which clears.
        editor.harness.textView.string = editor.harness.textView.string
        editor.harness.textView.setSelectedRange(selection)
        XCTAssertTrue(editor.coordinator.tagHighlight.paintedRanges.isEmpty, "the swap left a paint behind")

        editor.coordinator.scheduleCaretHighlightSettle()
        await waitFor("the post-swap settle to repaint") {
            !editor.coordinator.tagHighlight.paintedRanges.isEmpty
        }
    }

    func testAnUpdateThatRetargetsNothingKeepsThePaint() async throws {
        let editor = try await makeEditor()
        let painted = editor.coordinator.tagHighlight.paintedRanges
        XCTAssertFalse(painted.isEmpty, "the first settle painted nothing")

        XCTAssertFalse(editor.coordinator.resetCaretHighlights(ifRetargeted: false, language: .html))
        XCTAssertEqual(editor.coordinator.tagHighlight.paintedRanges, painted)
    }

    // MARK: - Harness

    @MainActor
    private final class Editor {
        let harness = EditorLayoutHarness()
        let coordinator: CodeEditorView.Coordinator

        init(text: String) {
            harness.textView.string = text
            coordinator = CodeEditorView.Coordinator(text: .constant(text))
            coordinator.textView = harness.textView
            coordinator.fileID = UUID()
            coordinator.language = .html
            coordinator.attachBracketHighlighting(textView: harness.textView)
        }
    }

    private func makeEditor() async throws -> Editor {
        let editor = Editor(text: try fixture("tags.html"))
        addTeardownBlock { @MainActor in editor.coordinator.teardown() }
        let text = editor.harness.textView.string as NSString
        let caret = text.range(of: "<div class=\"inner\"").location + 2
        editor.harness.textView.setSelectedRange(NSRange(location: caret, length: 0))
        await editor.coordinator.tagHighlight.settleNow()?.value
        return editor
    }

    private func waitFor(
        _ description: String,
        timeout: Duration = .seconds(5),
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("timed out waiting for \(description)")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

#endif
