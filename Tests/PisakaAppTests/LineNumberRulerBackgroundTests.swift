#if os(macOS)
import AppKit
import XCTest
@testable import Pisaka

/// The gutter's background rectangle, pinned.
///
/// The first part of the chrome sweep gave the ruler a background of its own and
/// filled the rectangle `drawHashMarksAndLabels` is *handed* — which is not the
/// ruler's bounds. `NSRulerView` is asked to redraw a rectangle that regularly
/// spans the whole editor pane, so the fill painted the code and the minimap out
/// in `bgEditor`. Nothing in the pipeline could see it: the drawing itself cannot
/// be asserted, but the rectangle about to be drawn can, which is what
/// `backgroundRect(in:bounds:ruleThickness:)` exists for — the same argument
/// `numberAttributes` is `internal` for.
///
/// The same rectangle also reaches *above* the ruler, and since macOS 14
/// `clipsToBounds` defaults to `false`, so until 2026-10-04 the gutter's fill
/// and its hairline, which carried the handed rectangle's vertical half through
/// untouched, painted over the surface above the editor — the consent bar's
/// leading 48 points. The rule now clamps both halves to `bounds`, and
/// `testTheHookPaintsNothingAboveItsBounds` draws the hook itself into a bitmap
/// taller than the ruler, because the hairline is filled at the call site and
/// the rule's answer alone cannot see it.
final class LineNumberRulerBackgroundTests: XCTestCase {

    /// The bounds the pure cases hand the rule: a gutter 59 wide, taller than
    /// every rectangle below, so only the horizontal clamp is in play.
    private let tallBounds = NSRect(x: 0, y: 0, width: 59, height: 2000)

    /// The regression itself: a pane-wide dirty rectangle is clamped to the
    /// gutter's own width.
    func testPaneWideRectIsClampedToTheGutterWidth() {
        let answer = LineNumberRulerView.backgroundRect(
            in: NSRect(x: 0, y: 0, width: 742, height: 400),
            bounds: tallBounds,
            ruleThickness: 59
        )
        XCTAssertEqual(answer.minX, 0)
        XCTAssertEqual(answer.width, 59)
    }

    /// A rectangle already narrower than the gutter is its own answer.
    func testRectNarrowerThanTheGutterIsUnchanged() {
        let rect = NSRect(x: 0, y: 12, width: 20, height: 100)
        XCTAssertEqual(LineNumberRulerView.backgroundRect(in: rect, bounds: tallBounds, ruleThickness: 59), rect)
    }

    /// A partial dirty rectangle starting inside the gutter keeps its origin and
    /// stops at the gutter's trailing edge — the reason the rule clamps the
    /// trailing edge rather than answering `(0, ruleThickness)` outright.
    func testRectStartingInsideTheGutterKeepsItsOrigin() {
        let answer = LineNumberRulerView.backgroundRect(
            in: NSRect(x: 30, y: 0, width: 712, height: 400),
            bounds: tallBounds,
            ruleThickness: 59
        )
        XCTAssertEqual(answer.minX, 30)
        XCTAssertEqual(answer.maxX, 59)
        XCTAssertEqual(answer.width, 29)
    }

    /// A rectangle wholly to the right of the gutter paints nothing — and is a
    /// zero width, never a negative one.
    func testRectRightOfTheGutterIsEmptyRatherThanNegative() {
        let answer = LineNumberRulerView.backgroundRect(
            in: NSRect(x: 200, y: 0, width: 542, height: 400),
            bounds: tallBounds,
            ruleThickness: 59
        )
        XCTAssertEqual(answer.width, 0)
        XCTAssertFalse(answer.width < 0)
    }

    /// The vertical half is clamped to the bounds: a rectangle reaching above
    /// and below the ruler fills only the ruler's own vertical extent.
    func testVerticalGeometryIsClampedToTheBounds() {
        let answer = LineNumberRulerView.backgroundRect(
            in: NSRect(x: 0, y: -72, width: 742, height: 500),
            bounds: NSRect(x: 0, y: 0, width: 59, height: 300),
            ruleThickness: 59
        )
        XCTAssertEqual(answer.minY, 0)
        XCTAssertEqual(answer.height, 300)
    }

    /// A rectangle inside the bounds keeps its vertical geometry.
    func testVerticalGeometryInsideTheBoundsIsCarriedThrough() {
        let answer = LineNumberRulerView.backgroundRect(
            in: NSRect(x: 0, y: 137.5, width: 742, height: 102.25),
            bounds: NSRect(x: 0, y: 0, width: 59, height: 300),
            ruleThickness: 59
        )
        XCTAssertEqual(answer.minY, 137.5)
        XCTAssertEqual(answer.height, 102.25)
    }

    /// A rectangle wholly above the bounds is empty, never a negative height.
    func testRectWhollyOutsideTheBoundsIsEmpty() {
        let answer = LineNumberRulerView.backgroundRect(
            in: NSRect(x: 0, y: -72, width: 742, height: 60),
            bounds: NSRect(x: 0, y: 0, width: 59, height: 300),
            ruleThickness: 59
        )
        XCTAssertEqual(answer.height, 0)
        XCTAssertEqual(answer.width, 0)
    }

    /// The hook itself, drawn: nothing lands above the ruler's bounds.
    ///
    /// A ruler 59×300 is drawn into a bitmap 59 wide and 372 tall, pre-filled
    /// with a sentinel no role resolves to (pure magenta), and translated so the
    /// ruler's bounds occupy the bitmap's bottom 300 points. The hook is handed
    /// a rectangle starting 72 points above the bounds and spanning the pane's
    /// width — the shape the scroll view hands it beneath the consent bar.
    ///
    /// Which way "above" is: the bitmap context is unflipped (y up), and
    /// `NSBitmapImageRep.colorAt(x:y:)` counts rows from the top, so "above the
    /// bounds" is always bitmap **rows 0 ..< 72**. The ruler is flipped (y
    /// down), so in its own coordinates above is `minY - 72 ..< minY`, and the
    /// translation flips the context to match; an unflipped ruler would need
    /// none, and the test handles both rather than assuming either.
    ///
    /// Teeth both ways: every pixel of the 72 rows above must still be the
    /// sentinel, and a pixel inside the bounds must be `bgEditor`, so a hook
    /// that drew nothing at all fails as surely as one that drew everywhere.
    /// Verified by mutation: carrying the handed `minY`/`height` through the
    /// rule again turns the first half red.
    @MainActor
    func testTheHookPaintsNothingAboveItsBounds() throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.textContainer?.replaceLayoutManager(BracketOverlayLayoutManager())
        scroll.documentView = textView
        textView.string = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let ruler = LineNumberRulerView(scrollView: scroll, textView: textView)
        ruler.frame = NSRect(x: 0, y: 0, width: 59, height: 300)
        let above: CGFloat = 72
        let height = ruler.bounds.height + above

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 59, pixelsHigh: Int(height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )?.retagging(with: .sRGB))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        let sentinel = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        sentinel.setFill()
        NSRect(x: 0, y: 0, width: 59, height: height).fill()
        let transform = NSAffineTransform()
        let handed: NSRect
        if ruler.isFlipped {
            // Ruler y 0 lands at the bounds' top edge (bitmap y 300), y grows down.
            transform.translateX(by: 0, yBy: ruler.bounds.height)
            transform.scaleX(by: 1, yBy: -1)
            handed = NSRect(x: 0, y: ruler.bounds.minY - above, width: 600, height: height)
        } else {
            handed = NSRect(x: 0, y: ruler.bounds.minY, width: 600, height: height)
        }
        transform.concat()
        appearance.performAsCurrentDrawingAppearance {
            ruler.drawHashMarksAndLabels(in: handed)
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var painted: [String] = []
        for row in 0..<Int(above) {
            for column in 0..<59 where !Self.matches(rep, x: column, y: row, sentinel) {
                painted.append("(\(column), \(row))")
            }
        }
        XCTAssertTrue(
            painted.isEmpty,
            "the gutter painted \(painted.count) pixels above its bounds, first \(painted.prefix(5))"
        )
        let editor = ChromePalette.nsColor(.bgEditor, in: .light)
        XCTAssertTrue(
            Self.matches(rep, x: 2, y: Int(height) - 150, editor),
            "a pixel inside the bounds is not bgEditor — the hook drew nothing, and the first half proves nothing"
        )
    }

    /// Whether the pixel at `(x, y)` — rows counted from the top — is
    /// `expected`, compared as raw bytes in the bitmap's own colour space, so no
    /// conversion on the way out can move the sentinel.
    private static func matches(_ rep: NSBitmapImageRep, x: Int, y: Int, _ expected: NSColor) -> Bool {
        guard let expected = expected.usingColorSpace(rep.colorSpace) else { return false }
        var pixel = [Int](repeating: 0, count: rep.samplesPerPixel)
        rep.getPixel(&pixel, atX: x, y: y)
        let wanted = [expected.redComponent, expected.greenComponent, expected.blueComponent]
        return zip(pixel, wanted).allSatisfy { abs(CGFloat($0) / 255 - $1) <= 3 / 255 }
    }
}
#endif
