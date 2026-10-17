#if os(macOS)
import AppKit
import PisakaCore
import XCTest
@testable import Pisaka

/// The occurrence highlight's app half: `OccurrenceHighlightController` over the
/// editor's real TextKit 1 stack (`EditorLayoutHarness`), no window.
///
/// What it pins:
/// - a published answer is painted, but only its **on-screen** slice is pushed
///   to the layout manager — an occurrence far below the viewport is neither
///   pushed nor painted;
/// - publishing and painting are a **reader**: no undo entry, no character edit
///   in the text storage, no `textDidChange` (the coordinator's dirty path), and
///   the string unchanged;
/// - an edit and a reset clear the layer, and an answer for another buffer
///   paints nothing.
///
/// The causal hop is the model's own settle task, awaited, and the assertion is
/// on its published state — never a sleep. The 75 ms debounce in front of it is
/// the coordinator's trigger and is not under test here.
@MainActor
final class OccurrenceHighlightControllerTests: XCTestCase {
    /// Far more lines than the 800-point viewport shows, each naming `value`.
    private let text = String(repeating: "let value = value + 1\n", count: 400)
    private let fileID = UUID()

    // MARK: - Painting

    func testOnlyTheOnScreenSliceIsPushed() async throws {
        let (harness, controller) = makeController()
        let all = occurrences(of: "value")
        harness.textView.setSelectedRange(NSRange(location: all[0].location + 1, length: 0))

        await settle(controller)

        XCTAssertEqual(controller.model.highlights.count, all.count, "the model published the whole answer")
        let pushed = controller.pushedRuns
        XCTAssertFalse(pushed.isEmpty, "nothing on screen was pushed")
        XCTAssertLessThan(pushed.count, all.count, "off-screen occurrences were pushed")
        let visible = visibleRange(harness)
        for run in pushed {
            XCTAssertGreaterThan(NSMaxRange(run.range), visible.location, "a pushed run ends above the viewport")
            XCTAssertLessThan(run.range.location, NSMaxRange(visible), "a pushed run starts below the viewport")
            XCTAssertEqual(run.kind, .read)
        }
        XCTAssertNotNil(background(harness, at: all[0].location), "the first occurrence is not painted")
        XCTAssertNil(background(harness, at: all[all.count - 1].location), "an off-screen occurrence is painted")
    }

    func testScrollingPushesTheNewSlice() async throws {
        let (harness, controller) = makeController()
        let all = occurrences(of: "value")
        harness.textView.setSelectedRange(NSRange(location: all[0].location, length: 0))
        await settle(controller)
        let last = try XCTUnwrap(all.last)
        XCTAssertFalse(controller.pushedRuns.contains { $0.range == last })

        harness.textView.scroll(NSPoint(x: 0, y: harness.textView.bounds.height - 10))
        controller.refreshVisible()

        XCTAssertTrue(controller.pushedRuns.contains { $0.range == last }, "the scrolled-to slice was not pushed")
        XCTAssertFalse(controller.pushedRuns.contains { $0.range == all[0] }, "the scrolled-off slice is still pushed")
    }

    func testTheWriteKindIsPaintedAsAWrite() async throws {
        let (harness, controller) = makeController(writeAt: 0)
        let all = occurrences(of: "value")
        harness.textView.setSelectedRange(NSRange(location: all[0].location, length: 0))
        await settle(controller)
        XCTAssertEqual(controller.pushedRuns.first?.kind, .write)
        XCTAssertEqual(controller.pushedRuns.dropFirst().first?.kind, .read)
    }

    func testASelectionMatchIsPaintedInItsOwnKind() async throws {
        // Three matches, under the 50 cap (the long buffer's 400 are past it).
        let short = String(repeating: "let value = value + 1\n", count: 3)
        let (harness, controller) = makeController(text: short)
        // `= value` spans more than one identifier: a selection match.
        let selected = (short as NSString).range(of: "= value")
        harness.textView.setSelectedRange(selected)
        await settle(controller)
        XCTAssertEqual(controller.pushedRuns.count, 3)
        XCTAssertTrue(controller.pushedRuns.allSatisfy { $0.kind == .selectionMatch })
    }

    // MARK: - A reader

    func testPublishingNeverEditsOrDirtiesTheBuffer() async throws {
        let (harness, controller) = makeController()
        let probe = EditProbe(harness)
        harness.textView.setSelectedRange(NSRange(location: 5, length: 0))

        await settle(controller)
        XCTAssertFalse(controller.pushedRuns.isEmpty, "nothing was painted, so the probe saw nothing to refuse")
        controller.noteEdit()
        await settle(controller)
        controller.reset()

        XCTAssertEqual(harness.textView.string, text, "the string changed")
        XCTAssertFalse(probe.undoManager.canUndo, "painting registered an undo entry")
        XCTAssertFalse(probe.sawCharacterEdit, "painting edited the storage's characters")
        XCTAssertFalse(probe.sawTextDidChange, "painting reached the dirty path")
    }

    // MARK: - Clearing

    func testAnEditAndAResetClearTheLayer() async throws {
        let (harness, controller) = makeController()
        harness.textView.setSelectedRange(NSRange(location: 5, length: 0))
        await settle(controller)
        XCTAssertFalse(controller.pushedRuns.isEmpty)

        controller.noteEdit()
        XCTAssertTrue(controller.model.highlights.isEmpty)
        XCTAssertTrue(controller.pushedRuns.isEmpty, "an edit left the layer painted")
        XCTAssertNil(background(harness, at: 4))

        await settle(controller)
        XCTAssertFalse(controller.pushedRuns.isEmpty)
        controller.reset()
        XCTAssertTrue(controller.pushedRuns.isEmpty, "a reset left the layer painted")
    }

    func testAnAnswerForAnotherBufferPaintsNothing() async throws {
        let (harness, controller) = makeController()
        harness.textView.setSelectedRange(NSRange(location: 5, length: 0))
        await settle(controller)
        XCTAssertFalse(controller.pushedRuns.isEmpty)

        // The editor now shows another buffer; the published answer is not its.
        let other = UUID()
        controller.fileID = { other }
        controller.refreshVisible()
        XCTAssertTrue(controller.pushedRuns.isEmpty)
    }

    // MARK: - Harness

    /// Answers `documentHighlights` with every whole-word occurrence, read, or
    /// write at the given index.
    private final class StubProvider: CodeIntelligenceProviding {
        let writeAt: Int?

        init(writeAt: Int?) { self.writeAt = writeAt }

        func definitions(for request: DefinitionRequest) async -> [DefinitionCandidate] { [] }
        func completions(for request: CompletionRequest) async -> [CompletionItem] { [] }

        func documentHighlights(for request: DocumentHighlightRequest) async -> DocumentHighlightAnswer? {
            let ranges = OccurrenceScan.identifierMatches(
                of: request.identifier, in: request.text as NSString, language: request.language
            ) ?? []
            return DocumentHighlightAnswer(
                provenance: .server,
                highlights: ranges.enumerated().map { index, range in
                    .init(range: range, kind: index == writeAt ? .write : .read)
                }
            )
        }
    }

    /// Hands the text view a fixed undo manager and records every storage edit
    /// and every `textDidChange`.
    private final class EditProbe: NSObject, NSTextViewDelegate {
        let undoManager = UndoManager()
        private(set) var sawCharacterEdit = false
        private(set) var sawTextDidChange = false
        private var observer: NSObjectProtocol?

        init(_ harness: EditorLayoutHarness) {
            super.init()
            harness.textView.allowsUndo = true
            harness.textView.delegate = self
            observer = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification,
                object: harness.textStorage,
                queue: nil
            ) { [weak self] note in
                guard let storage = note.object as? NSTextStorage else { return }
                if storage.editedMask.contains(.editedCharacters) {
                    MainActor.assumeIsolated { self?.sawCharacterEdit = true }
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

        func textDidChange(_ notification: Notification) {
            sawTextDidChange = true
        }
    }

    private func makeController(
        text: String? = nil,
        writeAt: Int? = nil
    ) -> (EditorLayoutHarness, OccurrenceHighlightController) {
        let harness = EditorLayoutHarness()
        harness.textView.string = text ?? self.text
        harness.layOut()
        harness.textView.sizeToFit()
        let controller = OccurrenceHighlightController()
        let provider = StubProvider(writeAt: writeAt)
        controller.provider = { provider }
        let fileID = fileID
        controller.fileID = { fileID }
        controller.language = { .typescript }
        controller.attach(textView: harness.textView)
        return (harness, controller)
    }

    /// Settle now and wait for the model's own task: the causal hop.
    private func settle(_ controller: OccurrenceHighlightController) async {
        await controller.settleNow()?.value
    }

    private func occurrences(of needle: String) -> [NSRange] {
        OccurrenceScan.identifierMatches(of: needle, in: text as NSString, language: .typescript) ?? []
    }

    private func visibleRange(_ harness: EditorLayoutHarness) -> NSRange {
        let rect = harness.textView.visibleRect
        let glyphs = harness.layoutManager.glyphRange(
            forBoundingRect: NSRect(x: 0, y: rect.minY, width: rect.width, height: rect.height),
            in: harness.textContainer
        )
        return harness.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    private func background(_ harness: EditorLayoutHarness, at index: Int) -> NSColor? {
        harness.layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil)
            as? NSColor
    }
}
#endif
