import XCTest
@testable import PisakaCore

/// `TreeStickyRule`'s stack: which expanded ancestors pin, in what order, where
/// each is drawn and how tall the stack is. Every extent is hand-computed with
/// a row height of 22; the viewport heights 66, 132 and 264 make the cap one,
/// two and four rows (a third of the height, in whole rows).
final class TreeStickyRuleTests: XCTestCase {

    private let rowHeight = 22.0
    private let capOne = 66.0
    private let capTwo = 132.0
    private let capFour = 264.0

    // MARK: - Helpers

    private typealias Named = (name: String, folder: TreeStickyRule.Folder)

    private func folder(
        _ name: String, depth: Int, _ top: Double, _ bottom: Double, expanded: Bool = true
    ) -> Named {
        (name, TreeStickyRule.Folder(depth: depth, isExpanded: expanded, top: top, bottom: bottom))
    }

    private func stack(_ named: [Named], top: Double, height: Double) -> TreeStickyRule.Stack {
        TreeStickyRule.stack(
            folders: named.map(\.folder),
            viewport: TreeStickyRule.Viewport(top: top, height: height),
            rowHeight: rowHeight
        )
    }

    /// The pinned rows as (name, drawn top, push offset), outermost first.
    private func pinned(
        _ named: [Named], top: Double, height: Double
    ) -> [PinnedRow] {
        stack(named, top: top, height: height).rows.map {
            PinnedRow(name: named[$0.index].name, top: $0.top, pushOffset: $0.pushOffset)
        }
    }

    private struct PinnedRow: Equatable, CustomStringConvertible {
        let name: String
        let top: Double
        let pushOffset: Double
        var description: String { "\(name)@\(top)(\(pushOffset))" }
    }

    private func row(_ name: String, _ top: Double, _ pushOffset: Double = 0) -> PinnedRow {
        PinnedRow(name: name, top: top, pushOffset: pushOffset)
    }

    /// root ⊃ a ⊃ b ⊃ c, each a deep expanded folder, plus `d` under `c` whose
    /// subtree ended long ago and a sibling `e` of `a` far below.
    private var nested: [Named] {
        [
            folder("root", depth: 0, 0, 2_000),
            folder("a", depth: 1, 22, 1_500),
            folder("b", depth: 2, 44, 1_000),
            folder("c", depth: 3, 66, 800),
            folder("d", depth: 4, 88, 150),
            folder("e", depth: 1, 1_500, 2_000),
        ]
    }

    // MARK: - Nothing pins

    func testNothingPinsAtOffsetZero() {
        let answer = stack(nested, top: 0, height: capFour)
        XCTAssertEqual(answer.rows, [])
        XCTAssertEqual(answer.height, 0)
    }

    func testAFolderWhoseRealRowIsAtOrBelowItsSlotDoesNotPin() {
        // `a` holds one file, then `b` at [66, 88).
        let named = [
            folder("root", depth: 0, 0, 2_000),
            folder("a", depth: 1, 22, 1_500),
            folder("b", depth: 2, 66, 1_000),
        ]
        // `a`'s row starts exactly at the viewport's top edge: it shows itself.
        XCTAssertEqual(pinned(named, top: 22, height: capFour), [])
        // `b`'s row starts at or below slot 1 (S1 = top + 22): only `a` pins.
        XCTAssertEqual(pinned(named, top: 23, height: capFour), [row("a", 0)])
        XCTAssertEqual(pinned(named, top: 44, height: capFour), [row("a", 0)])
        // One point further, `b`'s row slides under slot 1 and its copy covers it.
        XCTAssertEqual(pinned(named, top: 45, height: capFour), [row("a", 0), row("b", 22)])
    }

    // MARK: - Pinning

    func testOnePinnedRowAtTheTop() {
        let named = [folder("root", depth: 0, 0, 2_000), folder("a", depth: 1, 22, 500)]
        let answer = stack(named, top: 100, height: capFour)
        XCTAssertEqual(pinned(named, top: 100, height: capFour), [row("a", 0)])
        XCTAssertEqual(answer.height, 22)
    }

    func testSeveralRowsStackOutermostFirst() {
        // S0 = 200, S1 = 222, S2 = 244, S3 = 266: `d` ended at 150, so three pin.
        XCTAssertEqual(
            pinned(nested, top: 200, height: capFour),
            [row("a", 0), row("b", 22), row("c", 44)]
        )
        XCTAssertEqual(stack(nested, top: 200, height: capFour).height, 66)
    }

    func testTheInputOrderIsNotTrusted() {
        let expected = pinned(nested, top: 200, height: capFour)
        let shuffled = [nested[3], nested[5], nested[0], nested[4], nested[2], nested[1]]
        XCTAssertEqual(pinned(shuffled, top: 200, height: capFour), expected)
        XCTAssertEqual(pinned(nested.reversed(), top: 200, height: capFour), expected)
    }

    func testTheRowsCarryTheirInputIndex() {
        let shuffled = [nested[3], nested[5], nested[0], nested[4], nested[2], nested[1]]
        let answer = stack(shuffled, top: 200, height: capFour)
        XCTAssertEqual(answer.rows.map(\.index), [5, 4, 0])
    }

    // MARK: - Push-out

    func testTheLastDescendantInsideTheSlotPushesTheRowOut() {
        // `a` ends at 300. At 278 its last row fills slot 0 exactly; past that
        // the copy is pushed up by the overlap.
        let named = [folder("root", depth: 0, 0, 2_000), folder("a", depth: 1, 22, 300)]
        XCTAssertEqual(pinned(named, top: 278, height: capFour), [row("a", 0)])
        XCTAssertEqual(pinned(named, top: 290, height: capFour), [row("a", -12, -12)])
        XCTAssertEqual(stack(named, top: 290, height: capFour).height, 10)
        // The subtree ended at the viewport top: nothing left to pin.
        XCTAssertEqual(pinned(named, top: 300, height: capFour), [])
    }

    func testAChildEndingWithItsParentSlidesUnderItThenTheParentIsPushed() {
        let named = [
            folder("root", depth: 0, 0, 2_000),
            folder("a", depth: 1, 22, 400),
            folder("b", depth: 2, 44, 400),
        ]
        // S1 = 382, b's last row starts at 378: b slides 4 points under a.
        XCTAssertEqual(pinned(named, top: 360, height: capFour), [row("a", 0), row("b", 18, -4)])
        XCTAssertEqual(stack(named, top: 360, height: capFour).height, 40)
        // b's slot reached the end of its subtree: b is gone, a sits in slot 0.
        XCTAssertEqual(pinned(named, top: 378, height: capFour), [row("a", 0)])
        XCTAssertEqual(stack(named, top: 378, height: capFour).height, 22)
        // Then a alone is pushed out by the row that follows.
        XCTAssertEqual(pinned(named, top: 390, height: capFour), [row("a", -12, -12)])
    }

    func testADeeperRowEndingFirstSlidesUnderItsParent() {
        let named = [
            folder("root", depth: 0, 0, 2_000),
            folder("a", depth: 1, 22, 800),
            folder("b", depth: 2, 44, 300),
        ]
        // b's last row starts at 278; S1 = 272 + 22 = 294 → b drawn at 6.
        XCTAssertEqual(pinned(named, top: 272, height: capFour), [row("a", 0), row("b", 6, -16)])
        XCTAssertEqual(stack(named, top: 272, height: capFour).height, 28)
    }

    // MARK: - The cap

    func testTheCapDropsTheOutermostFirst() {
        // At 50 the rows of a, b, c and d start above S0…S3 respectively, so
        // cap 4 pins all four. Cap 2 (stack bottom at 94): c replaces a, its
        // real row [66, 88) being fully under the stack, and d stays out, its
        // row [88, 110) still crossing the stack's bottom edge.
        XCTAssertEqual(
            pinned(nested, top: 50, height: capFour),
            [row("a", 0), row("b", 22), row("c", 44), row("d", 66)]
        )
        XCTAssertEqual(pinned(nested, top: 50, height: capTwo), [row("b", 0), row("c", 22)])
        XCTAssertEqual(stack(nested, top: 50, height: capTwo).height, 44)
    }

    func testACappedCandidateJoinsOnlyOnceFullyUnderTheStack() {
        // Cap 2, c's real row is [66, 88). At 44 it sits exactly under the stack
        // [a, b] (which ends at 88): it shows itself and no copy is drawn.
        XCTAssertEqual(pinned(nested, top: 44, height: capTwo), [row("a", 0), row("b", 22)])
        // One point further its row is fully under the stack: it joins, a drops.
        XCTAssertEqual(pinned(nested, top: 45, height: capTwo), [row("b", 0), row("c", 22)])
        // Cap 1: each deeper folder replaces the last one by one.
        XCTAssertEqual(pinned(nested, top: 30, height: capOne), [row("a", 0)])
        XCTAssertEqual(pinned(nested, top: 45, height: capOne), [row("b", 0)])
        XCTAssertEqual(pinned(nested, top: 67, height: capOne), [row("c", 0)])
    }

    func testMaximumRowsIsAThirdOfTheViewportInWholeRows() {
        XCTAssertEqual(TreeStickyRule.capFraction, 1.0 / 3.0)
        XCTAssertEqual(TreeStickyRule.maximumRows(viewportHeight: 65.9, rowHeight: rowHeight), 0)
        XCTAssertEqual(TreeStickyRule.maximumRows(viewportHeight: capOne, rowHeight: rowHeight), 1)
        XCTAssertEqual(TreeStickyRule.maximumRows(viewportHeight: 131.9, rowHeight: rowHeight), 1)
        XCTAssertEqual(TreeStickyRule.maximumRows(viewportHeight: capTwo, rowHeight: rowHeight), 2)
        XCTAssertEqual(TreeStickyRule.maximumRows(viewportHeight: capFour, rowHeight: rowHeight), 4)
        XCTAssertEqual(TreeStickyRule.maximumRows(viewportHeight: 300, rowHeight: 0), 0)
        XCTAssertEqual(TreeStickyRule.maximumRows(viewportHeight: 300, rowHeight: -22), 0)
        XCTAssertEqual(TreeStickyRule.maximumRows(viewportHeight: 0, rowHeight: rowHeight), 0)
    }

    func testBelowThreeRowsHeightNothingPins() {
        let answer = stack(nested, top: 200, height: 65)
        XCTAssertEqual(answer.rows, [])
        XCTAssertEqual(answer.height, 0)
    }

    // MARK: - Eligibility

    func testACollapsedAncestorNeverPins() {
        let named = [
            folder("root", depth: 0, 0, 2_000),
            folder("a", depth: 1, 22, 500, expanded: false),
        ]
        XCTAssertEqual(pinned(named, top: 100, height: capFour), [])
    }

    func testTheRootNeverPins() {
        let named = [folder("root", depth: 0, 0, 2_000)]
        XCTAssertEqual(pinned(named, top: 100, height: capFour), [])
    }

    func testAnExpandedEmptyFolderNeverPins() {
        // Expanded with no descendant row: its node is its row alone.
        let named = [folder("root", depth: 0, 0, 2_000), folder("a", depth: 1, 22, 44)]
        XCTAssertEqual(pinned(named, top: 30, height: capFour), [])
    }

    func testAChainRowPinsAsExactlyOneRow() {
        // `a/b/c` is one row and one `Folder`; its tail's child `d` is depth 2.
        let named = [
            folder("root", depth: 0, 0, 2_000),
            folder("a/b/c", depth: 1, 22, 900),
            folder("d", depth: 2, 44, 800),
        ]
        XCTAssertEqual(
            pinned(named, top: 300, height: capFour),
            [row("a/b/c", 0), row("d", 22)]
        )
    }

    func testASiblingAfterAPinnedFoldersSubtreeNeverStacksUnderIt() {
        let named = [
            folder("root", depth: 0, 0, 2_000),
            folder("a", depth: 1, 22, 180),
            folder("b", depth: 1, 180, 800),
        ]
        // S0 = 170 lies in a; S1 = 192 lies in b's span, but b is not inside a.
        XCTAssertEqual(pinned(named, top: 170, height: capFour), [row("a", -12, -12)])
        // Once a has gone, b pins in slot 0 on its own.
        XCTAssertEqual(pinned(named, top: 190, height: capFour), [row("b", 0)])
    }

    func testASiblingOfAPinnedChildStacksAfterTheChildEnds() {
        let named = [
            folder("root", depth: 0, 0, 2_000),
            folder("a", depth: 1, 22, 1_000),
            folder("b", depth: 2, 44, 200),
            folder("c", depth: 2, 200, 900),
        ]
        XCTAssertEqual(pinned(named, top: 100, height: capFour), [row("a", 0), row("b", 22)])
        XCTAssertEqual(pinned(named, top: 300, height: capFour), [row("a", 0), row("c", 22)])
    }

    // MARK: - Height

    func testStackHeight() {
        XCTAssertEqual(stack(nested, top: 0, height: capFour).height, 0)
        XCTAssertEqual(stack(nested, top: 50, height: capFour).height, 88)
        XCTAssertEqual(stack(nested, top: 50, height: capTwo).height, 44)
        let pushed = [folder("root", depth: 0, 0, 2_000), folder("a", depth: 1, 22, 300)]
        XCTAssertEqual(stack(pushed, top: 299, height: capFour).height, 1)
    }
}
