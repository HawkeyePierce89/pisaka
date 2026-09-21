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
/// `backgroundRect(in:ruleThickness:)` exists for — the same argument
/// `numberAttributes` is `internal` for.
final class LineNumberRulerBackgroundTests: XCTestCase {

    /// The regression itself: a pane-wide dirty rectangle is clamped to the
    /// gutter's own width.
    func testPaneWideRectIsClampedToTheGutterWidth() {
        let answer = LineNumberRulerView.backgroundRect(
            in: NSRect(x: 0, y: 0, width: 742, height: 400),
            ruleThickness: 59
        )
        XCTAssertEqual(answer.minX, 0)
        XCTAssertEqual(answer.width, 59)
    }

    /// A rectangle already narrower than the gutter is its own answer.
    func testRectNarrowerThanTheGutterIsUnchanged() {
        let rect = NSRect(x: 0, y: 12, width: 20, height: 100)
        XCTAssertEqual(LineNumberRulerView.backgroundRect(in: rect, ruleThickness: 59), rect)
    }

    /// A partial dirty rectangle starting inside the gutter keeps its origin and
    /// stops at the gutter's trailing edge — the reason the rule clamps the
    /// trailing edge rather than answering `(0, ruleThickness)` outright.
    func testRectStartingInsideTheGutterKeepsItsOrigin() {
        let answer = LineNumberRulerView.backgroundRect(
            in: NSRect(x: 30, y: 0, width: 712, height: 400),
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
            ruleThickness: 59
        )
        XCTAssertEqual(answer.width, 0)
        XCTAssertFalse(answer.width < 0)
    }

    /// The vertical half of the rectangle is the scroll position's business and
    /// is carried through untouched.
    func testVerticalGeometryIsCarriedThrough() {
        let answer = LineNumberRulerView.backgroundRect(
            in: NSRect(x: 0, y: 137.5, width: 742, height: 402.25),
            ruleThickness: 59
        )
        XCTAssertEqual(answer.minY, 137.5)
        XCTAssertEqual(answer.height, 402.25)
    }
}
#endif
