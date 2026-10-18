import CoreGraphics
import XCTest
@testable import PisakaCore

/// `PopoverPlacement` over literal frames in the window root's top-left, y-down
/// space: a 1000 × 700 window whose bar's top edge is at 672.
final class PopoverPlacementTests: XCTestCase {
    private let window = CGRect(x: 0, y: 0, width: 1000, height: 700)
    private let barTop: CGFloat = 672

    // MARK: - The popover

    func testOrdinaryCaseIsLeftAlignedFourAboveTheBarAtFullHeight() {
        let widget = CGRect(x: 12, y: 675, width: 120, height: 22)
        let anchoring = PopoverPlacement.popover(
            widget: widget, barTop: barTop, window: window, width: 300, maxHeight: 360, gap: 4
        )
        XCTAssertEqual(anchoring, PopoverAnchoring(x: 12, bottom: 668, availableHeight: 360))
    }

    func testWidgetNearTheRightEdgeShiftsThePopoverLeftToTheWindowsEdge() {
        let widget = CGRect(x: 850, y: 675, width: 120, height: 22)
        let anchoring = PopoverPlacement.popover(
            widget: widget, barTop: barTop, window: window, width: 300, maxHeight: 360, gap: 4
        )
        XCTAssertEqual(anchoring.x, 700)
        XCTAssertEqual(anchoring.x + 300, window.maxX)
        XCTAssertEqual(anchoring.bottom, 668)
    }

    func testWindowNarrowerThanThePopoverPinsItAtTheLeftEdge() {
        let narrow = CGRect(x: 0, y: 0, width: 250, height: 700)
        let widget = CGRect(x: 120, y: 675, width: 100, height: 22)
        let anchoring = PopoverPlacement.popover(
            widget: widget, barTop: barTop, window: narrow, width: 300, maxHeight: 360, gap: 4
        )
        XCTAssertEqual(anchoring.x, 0)
    }

    func testShortWindowCapsTheHeightAndKeepsTheBottomFourAboveTheBar() {
        let short = CGRect(x: 0, y: 0, width: 1000, height: 228)
        let widget = CGRect(x: 12, y: 203, width: 120, height: 22)
        let anchoring = PopoverPlacement.popover(
            widget: widget, barTop: 200, window: short, width: 300, maxHeight: 360, gap: 4
        )
        XCTAssertEqual(anchoring.bottom, 196)
        XCTAssertEqual(anchoring.availableHeight, 196)
        XCTAssertLessThan(anchoring.availableHeight, 360)
    }

    func testAvailableHeightIsNeverNegative() {
        let widget = CGRect(x: 12, y: 3, width: 120, height: 22)
        let anchoring = PopoverPlacement.popover(
            widget: widget, barTop: 2, window: window, width: 300, maxHeight: 360, gap: 4
        )
        XCTAssertEqual(anchoring.availableHeight, 0)
    }

    // MARK: - The submenu

    func testSubmenuFitsToTheRightWithItsTopAtTheAnchorRow() {
        let popover = CGRect(x: 12, y: 308, width: 300, height: 360)
        let frame = PopoverPlacement.submenu(
            popover: popover, anchorRowTop: 500, size: CGSize(width: 220, height: 62), window: window, gap: 4
        )
        XCTAssertEqual(frame, CGRect(x: 316, y: 500, width: 220, height: 62))
    }

    func testSubmenuFlipsToTheLeftWhenItDoesNotFitOnTheRight() {
        let popover = CGRect(x: 700, y: 308, width: 300, height: 360)
        let frame = PopoverPlacement.submenu(
            popover: popover, anchorRowTop: 500, size: CGSize(width: 220, height: 62), window: window, gap: 4
        )
        XCTAssertEqual(frame, CGRect(x: 476, y: 500, width: 220, height: 62))
    }

    func testSubmenuIsClampedUpFromTheWindowsBottom() {
        let popover = CGRect(x: 12, y: 308, width: 300, height: 360)
        let frame = PopoverPlacement.submenu(
            popover: popover, anchorRowTop: 660, size: CGSize(width: 220, height: 62), window: window, gap: 4
        )
        XCTAssertEqual(frame, CGRect(x: 316, y: 638, width: 220, height: 62))
        XCTAssertEqual(frame.maxY, window.maxY)
    }

    func testSubmenuTallerThanTheWindowNeverGoesAboveTheTop() {
        let short = CGRect(x: 0, y: 0, width: 1000, height: 50)
        let popover = CGRect(x: 12, y: 0, width: 300, height: 40)
        let frame = PopoverPlacement.submenu(
            popover: popover, anchorRowTop: 10, size: CGSize(width: 220, height: 62), window: short, gap: 4
        )
        XCTAssertEqual(frame.minY, 0)
    }

    func testSubmenuInAWindowTooNarrowForEitherSideIsClampedInside() {
        let narrow = CGRect(x: 0, y: 0, width: 400, height: 700)
        let popover = CGRect(x: 50, y: 308, width: 300, height: 360)
        let frame = PopoverPlacement.submenu(
            popover: popover, anchorRowTop: 500, size: CGSize(width: 220, height: 62), window: narrow, gap: 4
        )
        XCTAssertEqual(frame.minX, 0)
    }

    // MARK: - Beside an anchor (the gutter's change marker)

    func testBesideHangsDownFromTheAnchorsTopGapPastItsTrailingEdge() {
        let marker = CGRect(x: 40, y: 100, width: 2, height: 18)
        let placed = PopoverPlacement.beside(anchor: marker, window: window, width: 300, maxHeight: 360, gap: 4)
        XCTAssertEqual(placed, PopoverBesideAnchoring(x: 46, edge: 100, growsDown: true, availableHeight: 360))
    }

    func testBesideNearTheFootRisesFromTheAnchorsBottom() {
        let marker = CGRect(x: 40, y: 600, width: 2, height: 18)
        let placed = PopoverPlacement.beside(anchor: marker, window: window, width: 300, maxHeight: 360, gap: 4)
        XCTAssertEqual(placed, PopoverBesideAnchoring(x: 46, edge: 618, growsDown: false, availableHeight: 360))
    }

    func testBesideInAShortWindowTakesTheRoomierSideCappedByIt() {
        let short = CGRect(x: 0, y: 0, width: 1000, height: 300)
        let lower = PopoverPlacement.beside(
            anchor: CGRect(x: 40, y: 100, width: 2, height: 18), window: short, width: 300, maxHeight: 360, gap: 4
        )
        XCTAssertEqual(lower, PopoverBesideAnchoring(x: 46, edge: 100, growsDown: true, availableHeight: 200))
        let upper = PopoverPlacement.beside(
            anchor: CGRect(x: 40, y: 200, width: 2, height: 18), window: short, width: 300, maxHeight: 360, gap: 4
        )
        XCTAssertEqual(upper, PopoverBesideAnchoring(x: 46, edge: 218, growsDown: false, availableHeight: 218))
    }

    func testBesideEqualRoomHangsDown() {
        let short = CGRect(x: 0, y: 0, width: 1000, height: 200)
        let placed = PopoverPlacement.beside(
            anchor: CGRect(x: 40, y: 90, width: 2, height: 20), window: short, width: 300, maxHeight: 360, gap: 4
        )
        XCTAssertEqual(placed, PopoverBesideAnchoring(x: 46, edge: 90, growsDown: true, availableHeight: 110))
    }

    func testBesideKeepsInsideTheWindowHorizontally() {
        let nearRight = PopoverPlacement.beside(
            anchor: CGRect(x: 900, y: 100, width: 2, height: 18), window: window, width: 300, maxHeight: 360, gap: 4
        )
        XCTAssertEqual(nearRight.x, 700)
        let narrow = CGRect(x: 0, y: 0, width: 250, height: 700)
        let pinned = PopoverPlacement.beside(
            anchor: CGRect(x: 40, y: 100, width: 2, height: 18), window: narrow, width: 300, maxHeight: 360, gap: 4
        )
        XCTAssertEqual(pinned.x, 0)
    }
}
