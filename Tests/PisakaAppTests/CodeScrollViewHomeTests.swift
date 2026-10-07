#if os(macOS)
import AppKit
import XCTest
@testable import Pisaka

/// A code pane at home sits at `contentView.bounds.origin.x == -contentInsets.left`
/// after every tile — the invariant `CodeScrollView.tile()` owns (`core-zoom.md`).
///
/// A real `CodeScrollView` with a plain `NSRulerView` as its vertical ruler and a
/// document far wider and taller than the pane, so a horizontal scroll has room; no
/// window. The suite pins **the invariant, not the mechanism**: where the framework
/// tiles by narrowing the clip view's frame the inset is 0 and home is 0, so it
/// passes on the older CI runner untouched; on macOS 26+, where the ruler's
/// thickness arrives as a leading `contentInsets.left`, it exercises the
/// correction — first tile, a widened ruler, a narrowed one, and a pane scrolled
/// right that must not be re-homed.
@MainActor
final class CodeScrollViewHomeTests: XCTestCase {
    func testTheFirstTileLeavesThePaneAtHome() {
        let pane = makePane()
        assertAtHome(pane, "after the first tile")
    }

    func testWideningTheRulerKeepsAPaneAtHomeAtTheNewHome() {
        let pane = makePane()
        pane.verticalRulerView?.ruleThickness = 80
        pane.tile()
        assertAtHome(pane, "after widening the ruler")
    }

    func testNarrowingTheRulerKeepsAPaneAtHomeAtTheNewHome() {
        let pane = makePane()
        pane.verticalRulerView?.ruleThickness = 20
        pane.tile()
        assertAtHome(pane, "after narrowing the ruler")
    }

    /// A pane the user scrolled right is never sent home by a ruler change.
    ///
    /// The assertion is deliberately weaker than exact preservation of
    /// `bounds.origin.x`: what the framework does to a scrolled view's origin when
    /// its inset changes is the framework's, not ours, and it can differ between
    /// frame tiling on the CI runner and inset tiling on macOS 26+. The property
    /// this change owns is narrower — the offset from home shrinks by at most the
    /// inset's own change, so a scrolled pane is never re-homed.
    func testAPaneScrolledRightIsNotSentHomeByARulerChange() {
        let pane = makePane()
        let clip = pane.contentView
        let scrolled: CGFloat = 200
        clip.scroll(to: NSPoint(x: -clip.contentInsets.left + scrolled, y: clip.bounds.origin.y))
        pane.reflectScrolledClipView(clip)

        var offset = clip.bounds.origin.x + clip.contentInsets.left
        XCTAssertEqual(offset, scrolled, accuracy: 0.5, "the scroll itself")
        for thickness: CGFloat in [80, 20] {
            let oldInset = clip.contentInsets.left
            pane.verticalRulerView?.ruleThickness = thickness
            pane.tile()
            let newInset = clip.contentInsets.left
            let newOffset = clip.bounds.origin.x + newInset
            XCTAssertGreaterThanOrEqual(
                newOffset, offset - abs(newInset - oldInset) - 0.5,
                "ruler at \(thickness): offset from home \(newOffset), was \(offset)")
            XCTAssertGreaterThan(newOffset, 0, "ruler at \(thickness): the pane was sent home")
            offset = newOffset
        }
    }

    /// The completion panel's shape: no vertical ruler, so no inset and home is 0.
    func testAPaneWithoutARulerStaysAtZero() {
        let pane = CodeScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        pane.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 3000, height: 3000))
        pane.tile()
        XCTAssertEqual(pane.contentView.bounds.origin.x, 0)
        XCTAssertEqual(pane.contentView.contentInsets.left, 0)
    }

    private func makePane() -> CodeScrollView {
        let pane = CodeScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        pane.hasHorizontalScroller = true
        pane.hasVerticalScroller = true
        pane.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 3000, height: 3000))
        let ruler = NSRulerView(scrollView: pane, orientation: .verticalRuler)
        ruler.ruleThickness = 40
        pane.verticalRulerView = ruler
        pane.hasVerticalRuler = true
        pane.rulersVisible = true
        pane.tile()
        return pane
    }

    private func assertAtHome(
        _ pane: CodeScrollView, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let clip = pane.contentView
        XCTAssertEqual(
            clip.bounds.origin.x, -clip.contentInsets.left, accuracy: 0.5,
            "\(message): inset \(clip.contentInsets.left)", file: file, line: line)
    }
}
#endif
