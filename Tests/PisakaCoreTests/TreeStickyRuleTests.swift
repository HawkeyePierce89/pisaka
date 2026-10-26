import XCTest
@testable import PisakaCore

/// `TreeStickyRule`'s stack: which expanded ancestors pin, in what order, where
/// each is drawn and how tall the stack is — and the scroll anchors that land
/// a row below the stack. Every extent is hand-computed with a row height of
/// 22; the viewport heights 66, 132, 198 and 264 make the cap one, two, three
/// and four rows (a third of the height, in whole rows).
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

    func testACappedCandidateJoinsExactlyOnceFullyUnderTheStack() {
        // Cap 2, c's real row is [66, 88). At 43 it still crosses the stack
        // [a, b]'s bottom edge (87): it shows itself and no copy is drawn.
        XCTAssertEqual(pinned(nested, top: 43, height: capTwo), [row("a", 0), row("b", 22)])
        // At 44 it lies exactly under b's copy, the last slot [66, 88): left
        // out, c would show neither its row nor a copy. It joins, a drops.
        XCTAssertEqual(pinned(nested, top: 44, height: capTwo), [row("b", 0), row("c", 22)])
        XCTAssertEqual(pinned(nested, top: 45, height: capTwo), [row("b", 0), row("c", 22)])
        // Cap 1: each deeper folder replaces the last one by one, at the point
        // its row lands exactly in the one slot.
        XCTAssertEqual(pinned(nested, top: 30, height: capOne), [row("a", 0)])
        XCTAssertEqual(pinned(nested, top: 43, height: capOne), [row("a", 0)])
        XCTAssertEqual(pinned(nested, top: 44, height: capOne), [row("b", 0)])
        XCTAssertEqual(pinned(nested, top: 66, height: capOne), [row("c", 0)])
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

    // MARK: - Scroll anchors

    /// A viewport of nine rows: the cap is three.
    private let capThree = 198.0

    /// root ⊃ a ⊃ b ⊃ c ⊃ d ⊃ e, each a deep expanded folder.
    private var deep: [Named] {
        [
            folder("root", depth: 0, 0, 5_000),
            folder("a", depth: 1, 22, 4_000),
            folder("b", depth: 2, 44, 3_500),
            folder("c", depth: 3, 66, 3_000),
            folder("d", depth: 4, 88, 2_500),
            folder("e", depth: 5, 110, 2_000),
        ]
    }

    private func anchorY(_ rowsAbove: Int, height: Double) -> Double {
        TreeStickyRule.anchorY(rowsAbove: rowsAbove, rowHeight: rowHeight, viewportHeight: height)
    }

    private func scrollAnchorY(_ named: [Named], rowAt rowTop: Double, height: Double) -> Double {
        TreeStickyRule.scrollAnchorY(
            forRowAt: rowTop, folders: named.map(\.folder), viewportHeight: height, rowHeight: rowHeight
        )
    }

    private func placement(_ named: [Named], rowAt rowTop: Double, top: Double, height: Double) -> Double? {
        TreeStickyRule.placement(
            ofRowAt: rowTop,
            folders: named.map(\.folder),
            viewport: TreeStickyRule.Viewport(top: top, height: height),
            rowHeight: rowHeight
        )
    }

    func testAnchorYLandsTheRowsTopKRowsBelowTheViewportTop() {
        // k·h / (H − h): `scrollTo` aligns the same unit point of the row and
        // of the viewport, so the row's top lands at y·(H − h).
        XCTAssertEqual(anchorY(0, height: capThree), 0)
        XCTAssertEqual(anchorY(1, height: capThree), 22.0 / 176.0)
        XCTAssertEqual(anchorY(3, height: capThree), 66.0 / 176.0)
        XCTAssertEqual(anchorY(3, height: capThree) * (capThree - rowHeight), 66, accuracy: 1e-9)
        // Clamped to 0…1.
        XCTAssertEqual(anchorY(8, height: capThree), 1)
        XCTAssertEqual(anchorY(20, height: capThree), 1)
        // A viewport no taller than one row has nowhere to place it.
        XCTAssertEqual(anchorY(1, height: rowHeight), 0)
        XCTAssertEqual(anchorY(1, height: 10), 0)
    }

    func testTheClickAnchorCountsEligibleAncestorsNotTheIndexInACappedStack() {
        // Cap 3. At 200 the chain reaches a, b, c, then d and e each drop the
        // outermost: the stack is [c, d, e].
        let answer = stack(deep, top: 200, height: capThree)
        XCTAssertEqual(answer.rows.map { deep[$0.index].name }, ["c", "d", "e"])
        // e sits at index 2, but it has four eligible ancestors, a to d, and
        // once its row is under the stack the cap's three slots are full: it
        // must land in slot 3, just under them.
        let innermost = answer.rows[2]
        XCTAssertEqual(innermost.scrollAnchorY, anchorY(3, height: capThree))
        XCTAssertNotEqual(innermost.scrollAnchorY, anchorY(2, height: capThree))
        XCTAssertEqual(innermost.scrollAnchorY, scrollAnchorY(deep, rowAt: 110, height: capThree))
        // c has a and b above it (slot 2); d has a, b, c (slot 3, the cap).
        XCTAssertEqual(
            answer.rows.map(\.scrollAnchorY),
            [anchorY(2, height: capThree), anchorY(3, height: capThree), anchorY(3, height: capThree)]
        )
    }

    func testAClickLeavesTheFolderAndItsInnermostAncestorsInSight() {
        // The round trip: scroll each copy's folder to its anchor and
        // recompute the stack there. The folder's real row must not be under
        // the stack, and nor may any of the ancestors the cap leaves room for:
        // each is either pinned or shows its real row below the stack — never
        // covered by another folder's copy, as the direct parent was when a
        // capped candidate exactly under the last slot was left out.
        let folders = deep.map(\.folder)
        for height in [capOne, capTwo, capThree, capFour] {
            let cap = TreeStickyRule.maximumRows(viewportHeight: height, rowHeight: rowHeight)
            for top in stride(from: 0.0, through: 400, by: 1) {
                for clicked in stack(deep, top: top, height: height).rows {
                    let landed = folders[clicked.index].top - clicked.scrollAnchorY * (height - rowHeight)
                    let after = stack(deep, top: landed, height: height)
                    let pinned = Set(after.rows.map(\.index))
                    func inSight(_ index: Int) -> Bool {
                        pinned.contains(index) || folders[index].top - landed >= after.height - 1e-9
                    }
                    let context = "\(deep[clicked.index].name) clicked at \(top), H \(height)"
                    XCTAssertFalse(pinned.contains(clicked.index), context)
                    XCTAssertTrue(inSight(clicked.index), context)
                    for ancestor in (1..<clicked.index).suffix(cap) {
                        XCTAssertTrue(inSight(ancestor), "\(deep[ancestor].name) covered — \(context)")
                    }
                }
            }
        }
    }

    func testWithNothingCappedTheClickAnchorIsTheIndexInTheStack() {
        let answer = stack(nested, top: 200, height: capFour)
        XCTAssertEqual(answer.rows.map { nested[$0.index].name }, ["a", "b", "c"])
        for (index, row) in answer.rows.enumerated() {
            XCTAssertEqual(row.scrollAnchorY, anchorY(index, height: capFour), "row \(index)")
        }
    }

    func testTheEligibleAncestorCountIgnoresTheRootCollapsedFoldersAndTheRowsOwnFolder() {
        let named = [
            folder("root", depth: 0, 0, 2_000),
            folder("a", depth: 1, 22, 1_500),
            folder("b", depth: 2, 44, 1_000, expanded: false),
            folder("c", depth: 2, 1_000, 1_400),
        ]
        let folders = named.map(\.folder)
        func count(_ rowTop: Double) -> Int {
            TreeStickyRule.eligibleAncestorCount(forRowAt: rowTop, folders: folders, rowHeight: rowHeight)
        }
        // Inside the collapsed b's claimed span: only a counts.
        XCTAssertEqual(count(66), 1)
        // a's own row: the root does not count and a is not its own ancestor.
        XCTAssertEqual(count(22), 0)
        // c's own row counts a alone; a row inside c counts a and c.
        XCTAssertEqual(count(1_000), 1)
        XCTAssertEqual(count(1_022), 2)
        // Past a's subtree: the root alone, which never counts.
        XCTAssertEqual(count(1_600), 0)
    }

    func testTheRevealCentreClearsTheCappedStackForEveryViewportHeight() {
        XCTAssertEqual(TreeStickyRule.revealAnchorY, 0.5)
        var checked = 0
        for height in stride(from: 3 * rowHeight, through: 60 * rowHeight, by: 1) {
            let cap = TreeStickyRule.maximumRows(viewportHeight: height, rowHeight: rowHeight)
            XCTAssertGreaterThanOrEqual(cap, 1, "viewport \(height)")
            let centredTop = TreeStickyRule.revealAnchorY * (height - rowHeight)
            XCTAssertGreaterThanOrEqual(centredTop, Double(cap) * rowHeight, "viewport \(height)")
            checked += 1
        }
        // 66 … 1,320 in one-point steps.
        XCTAssertEqual(checked, 1_255)
    }

    func testPlacementLeavesAClearRowAlone() {
        // Nothing pins at 0: the whole viewport [0, 198) is clear.
        XCTAssertNil(placement(deep, rowAt: 132, top: 0, height: capThree))
        XCTAssertNil(placement(deep, rowAt: 176, top: 0, height: capThree))
        // At 200 the stack [c, d, e] ends at 266: a row starting there is clear.
        XCTAssertNil(placement(deep, rowAt: 266, top: 200, height: capThree))
        XCTAssertNil(placement(deep, rowAt: 376, top: 200, height: capThree))
    }

    func testPlacementScrollsARowCrossingTheStacksBottomEdge() {
        // The stack at 200 ends at 266: a row one point higher is not clear.
        XCTAssertEqual(
            placement(deep, rowAt: 265, top: 200, height: capThree),
            scrollAnchorY(deep, rowAt: 265, height: capThree)
        )
    }

    func testPlacementScrollsARowUnderTheStackBelowIt() {
        // [230, 252) lies under the stack's 66 points. Five eligible ancestors
        // contain it; the cap holds the anchor at three rows.
        let anchor = placement(deep, rowAt: 230, top: 200, height: capThree)
        XCTAssertEqual(anchor, scrollAnchorY(deep, rowAt: 230, height: capThree))
        XCTAssertEqual(anchor, anchorY(3, height: capThree))
        XCTAssertNotEqual(anchor, anchorY(5, height: capThree))
    }

    func testPlacementScrollsARowBelowTheViewport() {
        // [377, 399) crosses the viewport's bottom edge at 398.
        XCTAssertEqual(
            placement(deep, rowAt: 377, top: 200, height: capThree),
            scrollAnchorY(deep, rowAt: 377, height: capThree)
        )
        // Past every folder but the root: no ancestor counts, so the anchor is
        // the viewport's top — non-nil, unlike a clear row.
        XCTAssertEqual(placement(deep, rowAt: 4_500, top: 200, height: capThree), 0)
    }
}
