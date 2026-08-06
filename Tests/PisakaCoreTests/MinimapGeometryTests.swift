import XCTest
import CoreGraphics
@testable import PisakaCore

final class MinimapGeometryTests: XCTestCase {
    private let accuracy: CGFloat = 1e-6

    // MARK: - Short file (content fits the minimap panel)

    func testShortFileNeverSlides() {
        // contentHeight (50) <= minimapHeight (100): nothing to slide.
        let geometry = MinimapGeometry(
            documentHeight: 1000,
            viewportHeight: 200,
            minimapHeight: 100,
            contentHeight: 50
        )

        for offset in stride(from: CGFloat(0), through: 800, by: 100) {
            XCTAssertEqual(
                geometry.minimapScrollTop(forScrollOffset: offset),
                0,
                accuracy: accuracy,
                "offset \(offset)"
            )
        }
    }

    func testShortFileViewportRectMapsDirectlyViaRatio() {
        let geometry = MinimapGeometry(
            documentHeight: 1000,
            viewportHeight: 200,
            minimapHeight: 100,
            contentHeight: 50
        )
        // documentToMinimap = 50/1000 = 0.05
        XCTAssertEqual(geometry.documentToMinimap, 0.05, accuracy: accuracy)

        let atTop = geometry.viewportRect(forScrollOffset: 0)
        XCTAssertEqual(atTop.y, 0, accuracy: accuracy)
        XCTAssertEqual(atTop.height, 10, accuracy: accuracy)

        let atBottom = geometry.viewportRect(forScrollOffset: 800)
        XCTAssertEqual(atBottom.y, 40, accuracy: accuracy) // 800 * 0.05
        XCTAssertEqual(atBottom.height, 10, accuracy: accuracy)
    }

    // MARK: - Long file (content overflows the minimap panel, slides)

    func testLongFileRatioIsConstant() {
        let geometry = MinimapGeometry(
            documentHeight: 1000,
            viewportHeight: 200,
            minimapHeight: 100,
            contentHeight: 300
        )
        XCTAssertEqual(geometry.documentToMinimap, 0.3, accuracy: accuracy)
    }

    func testLongFileSlidesTopToBottom() {
        let geometry = MinimapGeometry(
            documentHeight: 1000,
            viewportHeight: 200,
            minimapHeight: 100,
            contentHeight: 300
        )
        // maxScrollOffset = 800; slide range = contentHeight - minimapHeight = 200.

        XCTAssertEqual(geometry.minimapScrollTop(forScrollOffset: 0), 0, accuracy: accuracy)
        XCTAssertEqual(geometry.minimapScrollTop(forScrollOffset: 400), 100, accuracy: accuracy)
        XCTAssertEqual(geometry.minimapScrollTop(forScrollOffset: 800), 200, accuracy: accuracy)
        // Out-of-range offsets clamp.
        XCTAssertEqual(geometry.minimapScrollTop(forScrollOffset: -50), 0, accuracy: accuracy)
        XCTAssertEqual(geometry.minimapScrollTop(forScrollOffset: 5000), 200, accuracy: accuracy)
    }

    func testLongFileViewportRectStaysWithinPanel() {
        let geometry = MinimapGeometry(
            documentHeight: 1000,
            viewportHeight: 200,
            minimapHeight: 100,
            contentHeight: 300
        )
        // ratio = 0.3, viewport height in panel = 200 * 0.3 = 60.

        let atTop = geometry.viewportRect(forScrollOffset: 0)
        XCTAssertEqual(atTop.y, 0, accuracy: accuracy)
        XCTAssertEqual(atTop.height, 60, accuracy: accuracy)
        XCTAssertGreaterThanOrEqual(atTop.y, 0)
        XCTAssertLessThanOrEqual(atTop.y + atTop.height, geometry.minimapHeight + accuracy)

        let mid = geometry.viewportRect(forScrollOffset: 400)
        // y = 400*0.3 - 100 = 20
        XCTAssertEqual(mid.y, 20, accuracy: accuracy)
        XCTAssertEqual(mid.height, 60, accuracy: accuracy)
        XCTAssertGreaterThanOrEqual(mid.y, 0)
        XCTAssertLessThanOrEqual(mid.y + mid.height, geometry.minimapHeight + accuracy)

        let atBottom = geometry.viewportRect(forScrollOffset: 800)
        // y = 800*0.3 - 200 = 40; bottom = 40 + 60 = 100 = minimapHeight
        XCTAssertEqual(atBottom.y, 40, accuracy: accuracy)
        XCTAssertEqual(atBottom.height, 60, accuracy: accuracy)
        XCTAssertLessThanOrEqual(atBottom.y + atBottom.height, geometry.minimapHeight + accuracy)
    }

    // MARK: - scrollOffset(forMinimapCenterY:)

    func testScrollOffsetClampsAtTop() {
        let geometry = MinimapGeometry(
            documentHeight: 1000,
            viewportHeight: 200,
            minimapHeight: 100,
            contentHeight: 300
        )

        XCTAssertEqual(
            geometry.scrollOffset(forMinimapCenterY: 0),
            0,
            accuracy: accuracy
        )
        // Above the top is still clamped to 0.
        XCTAssertEqual(
            geometry.scrollOffset(forMinimapCenterY: -50),
            0,
            accuracy: accuracy
        )
    }

    func testScrollOffsetClampsAtBottom() {
        let geometry = MinimapGeometry(
            documentHeight: 1000,
            viewportHeight: 200,
            minimapHeight: 100,
            contentHeight: 300
        )
        let maxOffset: CGFloat = 800

        // A click below the lowest reachable rectangle center clamps to the end.
        XCTAssertEqual(
            geometry.scrollOffset(forMinimapCenterY: 100),
            maxOffset,
            accuracy: accuracy
        )
        XCTAssertEqual(
            geometry.scrollOffset(forMinimapCenterY: 200),
            maxOffset,
            accuracy: accuracy
        )
    }

    func testScrollOffsetRoundTrip() {
        let geometry = MinimapGeometry(
            documentHeight: 1000,
            viewportHeight: 200,
            minimapHeight: 100,
            contentHeight: 300
        )

        for offset in stride(from: CGFloat(0), through: 800, by: 50) {
            let rect = geometry.viewportRect(forScrollOffset: offset)
            let centerY = rect.y + rect.height / 2
            let recovered = geometry.scrollOffset(forMinimapCenterY: centerY)
            XCTAssertEqual(recovered, offset, accuracy: 1e-4, "offset \(offset)")
        }
    }

    func testScrollOffsetLandsRectangleUnderCursorInOneStep() {
        // A single click solves directly for the offset whose viewport rectangle is
        // centered under the cursor — no convergence over frames. For centerY 50 the
        // rectangle center equation `0.05*offset + 30 == 50` gives offset 400.
        let geometry = MinimapGeometry(
            documentHeight: 1000,
            viewportHeight: 200,
            minimapHeight: 100,
            contentHeight: 300
        )
        // ratio = 0.3, slidePerOffset = 200/800 = 0.25, maxScrollOffset = 800.

        let offset = geometry.scrollOffset(forMinimapCenterY: 50)
        XCTAssertEqual(offset, 400, accuracy: 1e-4)

        // The resulting rectangle is genuinely centered on the cursor in one step.
        let rect = geometry.viewportRect(forScrollOffset: offset)
        XCTAssertEqual(rect.y + rect.height / 2, 50, accuracy: 1e-4)
    }

    func testScrollOffsetIsIndependentOfPriorOffset() {
        // The result depends only on the cursor y, not on where the content has
        // currently slid: a held cursor lands the same offset and stays put when
        // fed back (no multi-frame convergence). centerY 40 → offset 200.
        let geometry = MinimapGeometry(
            documentHeight: 1000,
            viewportHeight: 200,
            minimapHeight: 100,
            contentHeight: 300
        )
        let centerY: CGFloat = 40

        let first = geometry.scrollOffset(forMinimapCenterY: centerY)
        XCTAssertEqual(first, 200, accuracy: 1e-4)
        // Re-applying for the same cursor is a fixed point (stable drag).
        let again = geometry.scrollOffset(forMinimapCenterY: centerY)
        XCTAssertEqual(again, first, accuracy: accuracy)
    }

    // MARK: - scrollOffset(byMinimapDelta:from:)

    func testScrollByDeltaForwardAndBackward() {
        let geometry = MinimapGeometry(
            documentHeight: 1000,
            viewportHeight: 200,
            minimapHeight: 100,
            contentHeight: 300
        )
        // ratio = 0.3, so a 30pt panel delta == 100pt of document scroll.

        // Forward (toward the bottom): from 0, +30 panel pts → 100 document pts.
        XCTAssertEqual(
            geometry.scrollOffset(byMinimapDelta: 30, from: 0),
            100,
            accuracy: accuracy
        )
        // Backward (toward the top): from 400, -30 panel pts → 300 document pts.
        XCTAssertEqual(
            geometry.scrollOffset(byMinimapDelta: -30, from: 400),
            300,
            accuracy: accuracy
        )
        // A zero delta leaves the (clamped) offset where it was.
        XCTAssertEqual(
            geometry.scrollOffset(byMinimapDelta: 0, from: 250),
            250,
            accuracy: accuracy
        )
    }

    func testScrollByDeltaClampsAtTopAndBottom() {
        let geometry = MinimapGeometry(
            documentHeight: 1000,
            viewportHeight: 200,
            minimapHeight: 100,
            contentHeight: 300
        )
        // maxScrollOffset = 800.

        // Scrolling far past the top clamps to 0.
        XCTAssertEqual(
            geometry.scrollOffset(byMinimapDelta: -10_000, from: 100),
            0,
            accuracy: accuracy
        )
        // Scrolling far past the bottom clamps to maxScrollOffset.
        XCTAssertEqual(
            geometry.scrollOffset(byMinimapDelta: 10_000, from: 700),
            800,
            accuracy: accuracy
        )
        // A starting offset already out of range is clamped even with no delta.
        XCTAssertEqual(
            geometry.scrollOffset(byMinimapDelta: 0, from: -50),
            0,
            accuracy: accuracy
        )
        XCTAssertEqual(
            geometry.scrollOffset(byMinimapDelta: 0, from: 5000),
            800,
            accuracy: accuracy
        )
    }

    func testScrollByDeltaZeroRatioAndZeroHeightGuards() {
        // Zero document height → ratio 0, maxScrollOffset 0: nowhere to scroll.
        let zeroDoc = MinimapGeometry(
            documentHeight: 0,
            viewportHeight: 200,
            minimapHeight: 100,
            contentHeight: 0
        )
        XCTAssertEqual(zeroDoc.scrollOffset(byMinimapDelta: 50, from: 0), 0, accuracy: accuracy)
        XCTAssertFalse(zeroDoc.scrollOffset(byMinimapDelta: 50, from: 0).isNaN)

        // Zero content height → ratio 0 even with a real document: the guard keeps
        // the offset clamped to the scrollable range rather than dividing by zero.
        let zeroContent = MinimapGeometry(
            documentHeight: 1000,
            viewportHeight: 200,
            minimapHeight: 100,
            contentHeight: 0
        )
        XCTAssertEqual(zeroContent.documentToMinimap, 0, accuracy: accuracy)
        let guarded = zeroContent.scrollOffset(byMinimapDelta: 50, from: 1000)
        XCTAssertFalse(guarded.isNaN)
        XCTAssertEqual(guarded, 800, accuracy: accuracy) // clamped to maxScrollOffset
    }

    // MARK: - Boundary: content exactly fills the panel

    func testContentHeightEqualToMinimapHeightNeverSlides() {
        // contentHeight == minimapHeight: the `contentHeight > minimapHeight` guard
        // is false, so the content sits flush and never slides at any offset.
        let geometry = MinimapGeometry(
            documentHeight: 1000,
            viewportHeight: 200,
            minimapHeight: 100,
            contentHeight: 100
        )
        XCTAssertEqual(geometry.documentToMinimap, 0.1, accuracy: accuracy)

        for offset in stride(from: CGFloat(0), through: 800, by: 100) {
            XCTAssertEqual(
                geometry.minimapScrollTop(forScrollOffset: offset),
                0,
                accuracy: accuracy,
                "offset \(offset)"
            )
        }

        // With no slide the viewport rect maps directly via the ratio.
        let mid = geometry.viewportRect(forScrollOffset: 400)
        XCTAssertEqual(mid.y, 40, accuracy: accuracy) // 400 * 0.1
        XCTAssertEqual(mid.height, 20, accuracy: accuracy) // 200 * 0.1

        let atBottom = geometry.viewportRect(forScrollOffset: 800)
        XCTAssertEqual(atBottom.y, 80, accuracy: accuracy)
        XCTAssertLessThanOrEqual(atBottom.y + atBottom.height, geometry.minimapHeight + accuracy)
    }

    // MARK: - maxScrollOffset

    func testMaxScrollOffset() {
        let scrollable = MinimapGeometry(
            documentHeight: 1000, viewportHeight: 200, minimapHeight: 100, contentHeight: 300
        )
        XCTAssertEqual(scrollable.maxScrollOffset, 800, accuracy: accuracy)

        // Document exactly the viewport height: nothing to scroll.
        let exact = MinimapGeometry(
            documentHeight: 200, viewportHeight: 200, minimapHeight: 100, contentHeight: 60
        )
        XCTAssertEqual(exact.maxScrollOffset, 0, accuracy: accuracy)

        // Shorter than the viewport: max offset floored at 0 (never negative).
        let shorter = MinimapGeometry(
            documentHeight: 100, viewportHeight: 200, minimapHeight: 100, contentHeight: 30
        )
        XCTAssertEqual(shorter.maxScrollOffset, 0, accuracy: accuracy)
    }

    // MARK: - Degenerate inputs

    func testZeroDocumentHeightDoesNotDivideByZero() {
        let geometry = MinimapGeometry(
            documentHeight: 0,
            viewportHeight: 200,
            minimapHeight: 100,
            contentHeight: 0
        )

        XCTAssertEqual(geometry.documentToMinimap, 0, accuracy: accuracy)
        XCTAssertEqual(
            geometry.scrollOffset(forMinimapCenterY: 50),
            0,
            accuracy: accuracy
        )
        let rect = geometry.viewportRect(forScrollOffset: 0)
        XCTAssertFalse(rect.y.isNaN)
        XCTAssertFalse(rect.height.isNaN)
        XCTAssertFalse(geometry.minimapScrollTop(forScrollOffset: 0).isNaN)
    }

    func testZeroMinimapHeightDoesNotDivideByZero() {
        let geometry = MinimapGeometry(
            documentHeight: 1000,
            viewportHeight: 200,
            minimapHeight: 0,
            contentHeight: 300
        )

        let offset = geometry.scrollOffset(forMinimapCenterY: 0)
        XCTAssertFalse(offset.isNaN)

        let rect = geometry.viewportRect(forScrollOffset: 100)
        XCTAssertFalse(rect.y.isNaN)
        XCTAssertFalse(rect.height.isNaN)
        XCTAssertFalse(geometry.minimapScrollTop(forScrollOffset: 100).isNaN)
    }

    func testZeroContentHeightDoesNotDivideByZero() {
        let geometry = MinimapGeometry(
            documentHeight: 1000,
            viewportHeight: 200,
            minimapHeight: 100,
            contentHeight: 0
        )

        XCTAssertEqual(geometry.documentToMinimap, 0, accuracy: accuracy)
        XCTAssertEqual(geometry.minimapScrollTop(forScrollOffset: 400), 0, accuracy: accuracy)
        let rect = geometry.viewportRect(forScrollOffset: 400)
        XCTAssertEqual(rect.y, 0, accuracy: accuracy)
        XCTAssertEqual(rect.height, 0, accuracy: accuracy)
        XCTAssertEqual(
            geometry.scrollOffset(forMinimapCenterY: 50),
            0,
            accuracy: accuracy
        )
    }

    // MARK: - Equatable

    func testEquatable() {
        let a = MinimapGeometry(documentHeight: 1000, viewportHeight: 200, minimapHeight: 100, contentHeight: 300)
        let b = MinimapGeometry(documentHeight: 1000, viewportHeight: 200, minimapHeight: 100, contentHeight: 300)
        let differentMinimap = MinimapGeometry(documentHeight: 1000, viewportHeight: 200, minimapHeight: 50, contentHeight: 300)
        let differentContent = MinimapGeometry(documentHeight: 1000, viewportHeight: 200, minimapHeight: 100, contentHeight: 250)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, differentMinimap)
        XCTAssertNotEqual(a, differentContent)
    }
}
