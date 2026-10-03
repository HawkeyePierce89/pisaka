#if os(macOS)
import AppKit
import PisakaCore
import SwiftUI
import XCTest
@testable import Pisaka

/// The current-line highlight, sampled off the pixels both of its painters draw.
///
/// The editor's real TextKit 1 stack (`EditorLayoutHarness`) with a real
/// `LineNumberRulerView` tiled beside it, rendered through `cacheDisplay` — no
/// window, one bitmap per view per state. The line is handed over by a real
/// `CodeEditorView.Coordinator` whose text view and ruler are the harness's, through
/// `updateCurrentLine(of:)` itself, so the rule is exercised rather than restated.
/// A caret move must also *invalidate* both painters, and that case records what
/// each one is asked to redraw rather than reading a flag: the editor is built
/// around a text-view subclass recording every `setNeedsDisplay(_:)` rect and a
/// ruler subclass recording the same plus `needsDisplay = true` as its full
/// bounds. The records are cleared after the selection moves and before the
/// coordinator runs, so only the coordinator's own invalidation is read. The text
/// view's rects must cover **both bands** — the line the caret left and the line
/// it landed on, each `currentLineBand(for:)` offset by `textContainerOrigin` — and
/// the ruler's must cover both bands' vertical ranges; removing `previous` from
/// `setCurrentLine`'s loop or `ruler.needsDisplay = true` fails it. Recording a
/// call needs no window, so **this suite creates no window at all**.
/// The text side is
/// sampled far right of every line's text, which is what "full width" means; the
/// gutter at its leading edge, clear of the numbers.
@MainActor
final class CurrentLineHighlightTests: XCTestCase {
    private let text = "alpha\nbeta\ngamma\ndelta\n"

    func testTheCaretLineIsWashedInTheTextAreaAndTheGutter() throws {
        for appearance in ChromeAppearance.allCases {
            let editor = makeEditor(appearance)
            editor.select(NSRange(location: 8, length: 0))
            try editor.render { sample in
                XCTAssertTrue(sample.isCurrentLine(textLine: 1), "caret line's text area, \(appearance)")
                XCTAssertTrue(sample.isCurrentLine(gutterLine: 1), "caret line's gutter band, \(appearance)")
                XCTAssertFalse(sample.isCurrentLine(textLine: 2), "the neighbouring line, \(appearance)")
                XCTAssertFalse(sample.isCurrentLine(gutterLine: 2), "the neighbouring gutter row, \(appearance)")
                XCTAssertFalse(sample.isCurrentLine(textLine: 0), "the line above, \(appearance)")
            }
        }
    }

    func testASelectionWithinOneLineStillWashesIt() throws {
        let editor = makeEditor(.dark)
        editor.select(NSRange(location: 11, length: 3))
        try editor.render { sample in
            XCTAssertTrue(sample.isCurrentLine(textLine: 2))
            XCTAssertTrue(sample.isCurrentLine(gutterLine: 2))
        }
    }

    func testAMultiLineSelectionPaintsNoTint() throws {
        let editor = makeEditor(.dark)
        editor.select(NSRange(location: 8, length: 0))
        editor.select(NSRange(location: 2, length: 10))
        XCTAssertNil(editor.harness.layoutManager.currentLineRange)
        try editor.render { sample in
            for line in 0..<4 {
                XCTAssertFalse(sample.isCurrentLine(textLine: line), "text line \(line) under a multi-line selection")
                XCTAssertFalse(sample.isCurrentLine(gutterLine: line), "gutter row \(line) under a multi-line selection")
            }
        }
    }

    func testTheWashFollowsTheCaret() throws {
        let editor = makeEditor(.light)
        editor.select(NSRange(location: 1, length: 0))
        editor.select(NSRange(location: 18, length: 0))
        try editor.render { sample in
            XCTAssertFalse(sample.isCurrentLine(textLine: 0), "the line the caret left")
            XCTAssertTrue(sample.isCurrentLine(textLine: 3), "the line the caret landed on")
            XCTAssertTrue(sample.isCurrentLine(gutterLine: 3))
        }
    }

    func testACaretMoveInvalidatesBothPaintersAndMovesTheWash() throws {
        let textView = RecordingTextView(usingTextLayoutManager: false)
        let editor = makeEditor(.dark, textView: textView) { RecordingRuler(scrollView: $0, textView: $1) }
        let ruler = try XCTUnwrap(editor.ruler as? RecordingRuler)
        editor.select(NSRange(location: 1, length: 0))
        let layoutManager = editor.harness.layoutManager
        let oldLine = try XCTUnwrap(layoutManager.currentLineRange, "the caret on line 0 highlights no line")
        textView.setSelectedRange(NSRange(location: 18, length: 0))
        textView.invalidations.removeAll()
        ruler.invalidations.removeAll()

        editor.coordinator.updateCurrentLine(of: textView)

        let newLine = try XCTUnwrap(layoutManager.currentLineRange, "the caret on line 3 highlights no line")
        XCTAssertEqual(newLine.location, ruler.lineStarts[3], "the highlight did not move to line 3")
        let origin = textView.textContainerOrigin
        let bands = try [("old", oldLine), ("new", newLine)].map { name, line in
            let band = try XCTUnwrap(layoutManager.currentLineBand(for: line), "the \(name) line has no band")
            return (name, band.offsetBy(dx: origin.x, dy: origin.y))
        }
        for (name, band) in bands {
            XCTAssertTrue(
                textView.invalidations.contains { $0.insetBy(dx: -0.5, dy: -0.5).contains(band) },
                "the \(name) line's band \(band) is not invalidated in the text view: \(textView.invalidations)"
            )
            let rulerBand = ruler.convert(band, from: textView)
            XCTAssertTrue(
                ruler.invalidations.contains {
                    $0.minY <= rulerBand.minY + 0.5 && $0.maxY >= rulerBand.maxY - 0.5
                },
                "the \(name) line's rows \(rulerBand) are not invalidated in the ruler: \(ruler.invalidations)"
            )
        }
        try editor.render { sample in
            XCTAssertFalse(sample.isCurrentLine(textLine: 0), "the old line is still tinted")
            XCTAssertFalse(sample.isCurrentLine(gutterLine: 0), "the old gutter row is still tinted")
            XCTAssertTrue(sample.isCurrentLine(textLine: 3), "the new line is not tinted")
            XCTAssertTrue(sample.isCurrentLine(gutterLine: 3), "the new gutter row is not tinted")
        }
    }

    // MARK: - Recording views

    /// Records every rect it is asked to redraw.
    private final class RecordingTextView: NSTextView {
        var invalidations: [NSRect] = []

        override func setNeedsDisplay(_ invalidRect: NSRect) {
            invalidations.append(invalidRect)
            super.setNeedsDisplay(invalidRect)
        }
    }

    /// Records every rect it is asked to redraw, and a whole-view request as its
    /// full bounds.
    private final class RecordingRuler: LineNumberRulerView {
        var invalidations: [NSRect] = []

        override var needsDisplay: Bool {
            get { super.needsDisplay }
            set {
                if newValue { invalidations.append(bounds) }
                super.needsDisplay = newValue
            }
        }

        override func setNeedsDisplay(_ invalidRect: NSRect) {
            invalidations.append(invalidRect)
            super.setNeedsDisplay(invalidRect)
        }
    }

    // MARK: - Harness

    private func makeEditor(
        _ appearance: ChromeAppearance,
        textView: NSTextView = NSTextView(usingTextLayoutManager: false),
        ruler: @MainActor (NSScrollView, NSTextView) -> LineNumberRulerView = { LineNumberRulerView(scrollView: $0, textView: $1) }
    ) -> Editor {
        let editor = Editor(text: text, appearance: appearance, textView: textView, ruler: ruler)
        addTeardownBlock { @MainActor in editor.harness.scrollView.verticalRulerView = nil }
        return editor
    }

    @MainActor
    private final class Editor {
        let harness: EditorLayoutHarness
        let ruler: LineNumberRulerView
        let coordinator: CodeEditorView.Coordinator
        let appearance: ChromeAppearance

        init(
            text: String,
            appearance: ChromeAppearance,
            textView: NSTextView,
            ruler makeRuler: @MainActor (NSScrollView, NSTextView) -> LineNumberRulerView
        ) {
            harness = EditorLayoutHarness(textView: textView)
            self.appearance = appearance
            coordinator = CodeEditorView.Coordinator(text: .constant(text))
            harness.scrollView.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
            harness.textView.minSize = NSSize(width: 500, height: 400)
            harness.textView.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
            harness.textView.drawsBackground = false
            harness.textView.string = text
            harness.layOut()
            ruler = makeRuler(harness.scrollView, harness.textView)
            harness.scrollView.hasVerticalRuler = true
            harness.scrollView.verticalRulerView = ruler
            harness.scrollView.rulersVisible = true
            harness.scrollView.tile()
            coordinator.textView = harness.textView
            coordinator.lineNumberRuler = ruler
        }

        /// Select, then let the coordinator hand the highlight its line.
        func select(_ range: NSRange) {
            harness.textView.setSelectedRange(range)
            coordinator.updateCurrentLine(of: harness.textView)
        }

        func render(_ body: (Sample) throws -> Void) throws {
            try autoreleasepool {
                let textView = harness.textView
                let text = try Self.bitmap(of: textView, appearance: appearance)
                let gutter = try Self.bitmap(of: ruler, appearance: appearance)
                try body(Sample(editor: self, text: text, gutter: gutter))
            }
        }

        /// The vertical centre of `line`'s fragment, in text-view coordinates.
        func lineMidY(_ line: Int) -> CGFloat {
            let start = ruler.lineStarts[line]
            let glyph = harness.layoutManager.glyphIndexForCharacter(at: start)
            let fragment = harness.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return fragment.midY + harness.textView.textContainerOrigin.y
        }

        private static func bitmap(of view: NSView, appearance: ChromeAppearance) throws -> NSBitmapImageRep {
            XCTAssertGreaterThan(view.bounds.width, 0, "\(type(of: view)) was not laid out")
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            let drawing = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)!
            drawing.performAsCurrentDrawingAppearance {
                view.cacheDisplay(in: view.bounds, to: rep)
            }
            return rep
        }
    }

    @MainActor
    private struct Sample {
        let editor: Editor
        let text: NSBitmapImageRep
        let gutter: NSBitmapImageRep

        func isCurrentLine(textLine line: Int) -> Bool {
            let view = editor.harness.textView
            return matches(text, in: view, x: view.bounds.width - 20, y: editor.lineMidY(line))
        }

        func isCurrentLine(gutterLine line: Int) -> Bool {
            let y = editor.ruler.convert(NSPoint(x: 0, y: editor.lineMidY(line)), from: editor.harness.textView).y
            return matches(gutter, in: editor.ruler, x: 2, y: y)
        }

        private func matches(_ rep: NSBitmapImageRep, in view: NSView, x: CGFloat, y: CGFloat) -> Bool {
            let scale = CGFloat(rep.pixelsWide) / view.bounds.width
            let row = view.isFlipped ? Int(y * scale) : rep.pixelsHigh - 1 - Int(y * scale)
            guard let color = rep.colorAt(x: Int(x * scale), y: row)?.usingColorSpace(.sRGB),
                  let expected = ChromePalette.nsColor(.currentLine, in: editor.appearance).usingColorSpace(.sRGB)
            else { return false }
            let tolerance: CGFloat = 3 / 255
            return abs(color.redComponent - expected.redComponent) <= tolerance
                && abs(color.greenComponent - expected.greenComponent) <= tolerance
                && abs(color.blueComponent - expected.blueComponent) <= tolerance
        }
    }
}
#endif
