#if os(macOS)
import AppKit
import XCTest
@testable import Pisaka
@testable import PisakaCore

/// The ruler's git change column: it adds no width, a click in it resolves to
/// the ruler line the marker was drawn beside (or `-1` for the wedge above
/// line 1), and its marks ride `LineShift` across edits between two installs.
///
/// The expected click points are derived here straight from the layout
/// manager's fragments, not from the ruler's own band seam, so the hit test's
/// mapping is checked against an independent reading of the same geometry.
@MainActor
final class LineNumberRulerChangeMarkerTests: XCTestCase {
    private struct Harness {
        let scrollView: NSScrollView
        let textView: NSTextView
        let ruler: LineNumberRulerView
    }

    // MARK: - Width

    func testThicknessIsIdenticalWithAndWithoutMarkers() {
        let harness = makeHarness(text: "one\ntwo\nthree\n")
        let before = harness.ruler.ruleThickness
        harness.ruler.setChangeMarkers(markers(count: harness.ruler.lineCount, [
            0: ChangeLineMarker(deletedAbove: true),
            1: ChangeLineMarker(strip: .modified, deletedBelow: true),
            2: ChangeLineMarker(strip: .added),
        ]))
        XCTAssertFalse(harness.ruler.changeMarkers.isEmpty)
        XCTAssertEqual(harness.ruler.ruleThickness, before)
        harness.ruler.clearChangeMarkers()
        XCTAssertTrue(harness.ruler.changeMarkers.isEmpty)
        XCTAssertEqual(harness.ruler.ruleThickness, before)
    }

    func testAnArrayOfTheWrongLengthIsRefused() {
        let harness = makeHarness(text: "one\ntwo")
        harness.ruler.setChangeMarkers([ChangeLineMarker(strip: .added)])
        XCTAssertTrue(harness.ruler.changeMarkers.isEmpty)
    }

    // MARK: - Hits

    func testAStripResolvesToItsLine() {
        let harness = makeHarness(text: "one\ntwo\nthree")
        harness.ruler.setChangeMarkers(markers(count: 3, [1: ChangeLineMarker(strip: .modified)]))
        XCTAssertEqual(harness.ruler.changeMarkerHit(at: point(harness, line: 1, fraction: 0.5)), 1)
        XCTAssertNil(harness.ruler.changeMarkerHit(at: point(harness, line: 2, fraction: 0.5)))
        XCTAssertNotNil(harness.ruler.changeMarkerRect(forHit: 1))
    }

    func testAWedgeAfterTheLastLineResolvesToTheLastLine() {
        let harness = makeHarness(text: "one\ntwo\nthree")
        harness.ruler.setChangeMarkers(markers(count: 3, [2: ChangeLineMarker(deletedBelow: true)]))
        XCTAssertEqual(harness.ruler.changeMarkerHit(at: point(harness, line: 2, fraction: 0.9)), 2)
        // Clamped inside the last fragment: the anchor rect ends at its bottom.
        let rect = harness.ruler.changeMarkerRect(forHit: 2)
        let band = harness.ruler.changeLineBand(forRulerLine: 2)
        XCTAssertNotNil(rect)
        XCTAssertEqual(rect?.maxY ?? 0, band?.maxY ?? -1, accuracy: 0.001)
    }

    func testAMidFileWedgeOverhangsTheNextLinesTop() {
        let harness = makeHarness(text: "one\ntwo\nthree")
        harness.ruler.setChangeMarkers(markers(count: 3, [0: ChangeLineMarker(deletedBelow: true)]))
        XCTAssertEqual(harness.ruler.changeMarkerHit(at: point(harness, line: 1, fraction: 0.05)), 0)
        XCTAssertNil(harness.ruler.changeMarkerHit(at: point(harness, line: 1, fraction: 0.9)))
    }

    func testAWedgeBeforeLineOneResolvesToMinusOne() {
        let harness = makeHarness(text: "one\ntwo")
        harness.ruler.setChangeMarkers(markers(count: 2, [0: ChangeLineMarker(deletedAbove: true)]))
        XCTAssertEqual(harness.ruler.changeMarkerHit(at: point(harness, line: 0, fraction: 0.2)), -1)
        // Alone on the line, the whole line answers the one wedge.
        XCTAssertEqual(harness.ruler.changeMarkerHit(at: point(harness, line: 0, fraction: 0.8)), -1)
        let rect = harness.ruler.changeMarkerRect(forHit: -1)
        let band = harness.ruler.changeLineBand(forRulerLine: 0)
        XCTAssertEqual(rect?.minY ?? 0, band?.minY ?? -1, accuracy: 0.001)
    }

    func testLineOneCarryingBothWedgesSplitsByHalf() {
        let harness = makeHarness(text: "one\ntwo")
        harness.ruler.setChangeMarkers(markers(count: 2, [0: ChangeLineMarker(deletedAbove: true, deletedBelow: true)]))
        XCTAssertEqual(harness.ruler.changeMarkerHit(at: point(harness, line: 0, fraction: 0.25)), -1)
        XCTAssertEqual(harness.ruler.changeMarkerHit(at: point(harness, line: 0, fraction: 0.75)), 0)
    }

    func testAnEmptyBufferAgainstNonEmptyHeadIsHittable() {
        let harness = makeHarness(text: "")
        harness.ruler.setChangeMarkers([ChangeLineMarker(deletedAbove: true)])
        guard let band = harness.ruler.changeLineBand(forRulerLine: 0) else {
            return XCTFail("the empty buffer's extra fragment should be laid out")
        }
        let column = harness.ruler.ruleThickness - 2
        XCTAssertEqual(harness.ruler.changeMarkerHit(at: NSPoint(x: column, y: band.midY)), -1)
    }

    func testAClickOutsideTheColumnIsNotAHit() {
        let harness = makeHarness(text: "one\ntwo\nthree")
        harness.ruler.setChangeMarkers(markers(count: 3, [1: ChangeLineMarker(strip: .added)]))
        var inNumbers = point(harness, line: 1, fraction: 0.5)
        inNumbers.x = harness.ruler.ruleThickness - 8
        XCTAssertNil(harness.ruler.changeMarkerHit(at: inNumbers))
        var pastTheEdge = point(harness, line: 1, fraction: 0.5)
        pastTheEdge.x = harness.ruler.ruleThickness + 1
        XCTAssertNil(harness.ruler.changeMarkerHit(at: pastTheEdge))
    }

    // MARK: - Shift across edits

    func testMarkersShiftAcrossAnEnterAbove() {
        let harness = makeHarness(text: "a\nb\nc\nd")
        harness.ruler.setChangeMarkers(markers(count: 4, [2: ChangeLineMarker(strip: .modified)]))
        // Enter at the end of line 1: line 1's span becomes two lines and blanks,
        // and everything below moves down by one.
        harness.textView.textStorage?.replaceCharacters(in: NSRange(location: 1, length: 0), with: "\n")
        XCTAssertEqual(harness.ruler.lineCount, 5)
        XCTAssertEqual(harness.ruler.changeMarkers.count, 5)
        XCTAssertEqual(harness.ruler.changeMarkers[3], ChangeLineMarker(strip: .modified))
        XCTAssertNil(harness.ruler.changeMarkers[2])
    }

    func testAMultiLinePasteOverMarkedLinesBlanksThem() {
        let harness = makeHarness(text: "a\nb\nc\nd")
        harness.ruler.setChangeMarkers(markers(count: 4, [
            1: ChangeLineMarker(strip: .added),
            3: ChangeLineMarker(strip: .modified),
        ]))
        // Replace "b" with three lines: the span changes its line count.
        harness.textView.textStorage?.replaceCharacters(in: NSRange(location: 2, length: 1), with: "x\ny\nz")
        XCTAssertEqual(harness.ruler.changeMarkers.count, 6)
        XCTAssertNil(harness.ruler.changeMarkers[1])
        XCTAssertNil(harness.ruler.changeMarkers[2])
        XCTAssertNil(harness.ruler.changeMarkers[3])
        XCTAssertEqual(harness.ruler.changeMarkers[5], ChangeLineMarker(strip: .modified))
    }

    // MARK: - Helpers

    private func markers(count: Int, _ entries: [Int: ChangeLineMarker]) -> [ChangeLineMarker] {
        (0..<count).map { entries[$0] ?? ChangeLineMarker() }
    }

    /// A point inside the change column at `fraction` of ruler line `line`'s
    /// fragment height, read off the layout manager directly.
    private func point(_ harness: Harness, line: Int, fraction: CGFloat) -> NSPoint {
        let textView = harness.textView
        let content = textView.string as NSString
        let starts = LineStartIndex.offsets(in: content)
        let manager = textView.layoutManager!
        let glyph = manager.glyphIndexForCharacter(at: starts[line])
        let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let offset = harness.ruler.convert(NSPoint.zero, from: textView).y + textView.textContainerOrigin.y
        return NSPoint(
            x: harness.ruler.ruleThickness - 2,
            y: offset + fragment.minY + fragment.height * fraction
        )
    }

    private func makeHarness(text: String) -> Harness {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        let textView = NSTextView(usingTextLayoutManager: false)
        let manager = BracketOverlayLayoutManager()
        textView.textContainer?.replaceLayoutManager(manager)
        textView.layoutManager?.allowsNonContiguousLayout = true
        scroll.documentView = textView
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.string = text
        let ruler = LineNumberRulerView(scrollView: scroll, textView: textView)
        // Installed as the scroll view's ruler, as the editor does, so the
        // ruler and the text view share a hierarchy and `convert` is real.
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.layoutSubtreeIfNeeded()
        manager.ensureLayout(for: textView.textContainer!)
        return Harness(scrollView: scroll, textView: textView, ruler: ruler)
    }
}
#endif
