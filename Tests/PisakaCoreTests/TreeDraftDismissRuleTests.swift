import XCTest
@testable import PisakaCore

/// The project tree's inline-naming dismiss rule.
///
/// Three questions, in the order the rule asks them: is the click even in the
/// draft's window, is it inside the draft's measured region, and what does a
/// region with no area mean. The view layer supplies the AppKit facts and holds
/// no policy, so everything the feature decides about a stray click is asserted
/// here.
///
/// The rectangle used throughout is `(10, 20, 100, 40)` — a non-zero origin on
/// purpose, so a test that passes only because the origin is the zero point
/// cannot pass.
final class TreeDraftDismissRuleTests: XCTestCase {

    private let bounds = CGRect(x: 10, y: 20, width: 100, height: 40)

    private func decision(at point: CGPoint, sameWindow: Bool = true, in rect: CGRect? = nil) -> TreeDraftClickDecision {
        TreeDraftDismissRule.decision(
            clickedWindowIsDraftWindow: sameWindow,
            point: point,
            draftBounds: rect ?? bounds
        )
    }

    // MARK: - Another window

    func testAClickInAnotherWindowIsIgnoredEvenWhereTheDraftIs() {
        // The point is squarely inside the rectangle and still irrelevant: the
        // window check comes first, because two windows' coordinate spaces
        // overlap and a Find in Files click must not reach the draft.
        XCTAssertEqual(decision(at: CGPoint(x: 60, y: 40), sameWindow: false), .ignore)
    }

    func testAClickInAnotherWindowIsIgnoredFarOutsideTheDraft() {
        XCTAssertEqual(decision(at: CGPoint(x: -500, y: 900), sameWindow: false), .ignore)
    }

    func testAClickInAnotherWindowIsIgnoredEvenWithNoMeasuredArea() {
        // The empty-rect rule must not overtake the window rule: a diff window's
        // click cannot cancel a draft that has not laid out yet either.
        XCTAssertEqual(decision(at: .zero, sameWindow: false, in: .zero), .ignore)
    }

    // MARK: - Inside the draft

    func testAClickInsideTheDraftIsIgnored() {
        XCTAssertEqual(decision(at: CGPoint(x: 60, y: 40)), .ignore)
    }

    func testAClickOnTheOriginCornerIsInside() {
        // `CGRect.contains` is half-open: the origin edges belong to the rect.
        XCTAssertEqual(decision(at: CGPoint(x: 10, y: 20)), .ignore)
    }

    func testAClickOnTheFarCornerIsOutside() {
        // The other half of half-open: `maxX`/`maxY` are the first points out.
        XCTAssertEqual(decision(at: CGPoint(x: 110, y: 60)), .cancel)
    }

    func testAClickJustInsideTheFarEdgeIsIgnored() {
        XCTAssertEqual(decision(at: CGPoint(x: 109.9, y: 59.9)), .ignore)
    }

    // MARK: - Outside, on each side

    func testAClickAboveTheDraftCancels() {
        XCTAssertEqual(decision(at: CGPoint(x: 60, y: 10)), .cancel)
    }

    func testAClickBelowTheDraftCancels() {
        XCTAssertEqual(decision(at: CGPoint(x: 60, y: 100)), .cancel)
    }

    func testAClickLeftOfTheDraftCancels() {
        XCTAssertEqual(decision(at: CGPoint(x: 0, y: 40)), .cancel)
    }

    func testAClickRightOfTheDraftCancels() {
        XCTAssertEqual(decision(at: CGPoint(x: 200, y: 40)), .cancel)
    }

    // MARK: - A region with no area

    func testAnEmptyRectangleCancels() {
        // The state between the draft appearing and its first layout pass: a
        // draft with no measured area cannot own a click, and treating it as
        // "inside" would make the draft briefly uncancellable.
        XCTAssertEqual(decision(at: CGPoint(x: 10, y: 20), in: CGRect(x: 10, y: 20, width: 0, height: 0)), .cancel)
    }

    func testAZeroHeightRectangleCancels() {
        XCTAssertEqual(decision(at: CGPoint(x: 60, y: 20), in: CGRect(x: 10, y: 20, width: 100, height: 0)), .cancel)
    }

    func testAZeroWidthRectangleCancels() {
        // The axis companion: a draft clipped to nothing horizontally — the
        // shape `bounds.intersection(visibleRect)` produces for a draft scrolled
        // out of the tree's clip view — owns no click either.
        XCTAssertEqual(decision(at: CGPoint(x: 10, y: 40), in: CGRect(x: 10, y: 20, width: 0, height: 40)), .cancel)
    }

    func testANullRectangleCancels() {
        XCTAssertEqual(decision(at: CGPoint(x: 60, y: 40), in: .null), .cancel)
    }

    func testAnInfiniteRectangleIgnores() {
        // Not a case the view can produce, but the boundary companion to `.null`:
        // whatever the caller measures, the answer comes from `contains` alone.
        XCTAssertEqual(decision(at: CGPoint(x: 60, y: 40), in: .infinite), .ignore)
    }
}
