#if os(macOS)
import AppKit
import PisakaCore
import XCTest
@testable import Pisaka

/// The current-line highlight, sampled off the pixels both of its painters draw.
///
/// The editor's real TextKit 1 stack (`EditorLayoutHarness`) with a real
/// `LineNumberRulerView` tiled beside it, rendered through `cacheDisplay` — no
/// window, one bitmap per view per state. The line is handed over the way
/// `CodeEditorView.Coordinator.updateCurrentLine(of:)` hands it: `CurrentLineRule`
/// over the selection and the ruler's own line-start table. The text side is
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

    // MARK: - Harness

    private func makeEditor(_ appearance: ChromeAppearance) -> Editor {
        let editor = Editor(text: text, appearance: appearance)
        addTeardownBlock { @MainActor in editor.harness.scrollView.verticalRulerView = nil }
        return editor
    }

    @MainActor
    private final class Editor {
        let harness = EditorLayoutHarness()
        let ruler: LineNumberRulerView
        let appearance: ChromeAppearance

        init(text: String, appearance: ChromeAppearance) {
            self.appearance = appearance
            harness.scrollView.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
            harness.textView.minSize = NSSize(width: 500, height: 400)
            harness.textView.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
            harness.textView.drawsBackground = false
            harness.textView.string = text
            harness.layOut()
            ruler = LineNumberRulerView(scrollView: harness.scrollView, textView: harness.textView)
            harness.scrollView.hasVerticalRuler = true
            harness.scrollView.verticalRulerView = ruler
            harness.scrollView.rulersVisible = true
            harness.scrollView.tile()
        }

        /// Select, then hand the highlight its line exactly as the coordinator does.
        func select(_ range: NSRange) {
            harness.textView.setSelectedRange(range)
            harness.layoutManager.setCurrentLine(
                CurrentLineRule.highlightedLine(
                    selection: range,
                    lineStarts: ruler.lineStarts,
                    length: harness.textStorage.length
                )
            )
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
