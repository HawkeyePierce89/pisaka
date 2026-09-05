import XCTest
@testable import PisakaCore

/// The fold state, its three maintenance rules, and the two pure rules the view
/// layer asks before it moves a caret or jumps to a range.
///
/// Ranges are written as `(location, length)` pairs against small hand-counted
/// buffers, except where a rule is about a *real* engine's output — the
/// save-transform remap, which is asserted against a plan `SaveTransform.plan`
/// actually produced, so the two cannot drift apart in a fixture.
final class FoldStateTests: XCTestCase {

    // MARK: - Helpers

    private func region(_ location: Int, _ length: Int, header: Int, kind: FoldRegionKind? = nil) -> FoldRegion {
        // Force-unwrapped on purpose: every fixture here is a non-empty range,
        // and a nil would be a broken test rather than a case to handle.
        FoldRegion(hiddenRange: NSRange(location: location, length: length), headerLine: header, kind: kind)!
    }

    private func ranges(_ state: FoldState) -> [NSRange] { state.hiddenRanges }

    // MARK: - Fold, unfold, toggle

    func testFoldUnfoldAndToggleOneRegion() {
        let block = region(10, 8, header: 0)
        var state = FoldState()
        XCTAssertTrue(state.isEmpty)

        state.fold(block)
        XCTAssertTrue(state.isFolded(block))
        XCTAssertEqual(state.regions, [block])
        XCTAssertEqual(ranges(state), [NSRange(location: 10, length: 8)])

        state.unfold(block)
        XCTAssertTrue(state.isEmpty)
        XCTAssertEqual(ranges(state), [])

        state.toggle(block)
        XCTAssertTrue(state.isFolded(block))
        state.toggle(block)
        XCTAssertFalse(state.isFolded(block))
    }

    func testFoldingTheSameRegionTwiceChangesNothing() {
        let block = region(10, 8, header: 0)
        var state = FoldState()
        state.fold(block)
        state.fold(block)
        XCTAssertEqual(state.regions, [block])
    }

    func testUnfoldingSomethingNotFoldedChangesNothing() {
        let block = region(10, 8, header: 0)
        var state = FoldState(regions: [block])
        state.unfold(region(40, 3, header: 9))
        XCTAssertEqual(state.regions, [block])
    }

    /// Nested regions may both be folded, and unfolding the outer one leaves the
    /// inner one folded — the reason the regions are stored beside their merged
    /// coverage rather than as coverage alone.
    func testNestedRegionsBothFoldAndTheOuterUnfoldsAlone() {
        let outer = region(10, 20, header: 0)
        let inner = region(14, 6, header: 1)
        var state = FoldState()
        state.fold(outer)
        state.fold(inner)
        XCTAssertEqual(state.regions, [outer, inner])
        XCTAssertEqual(ranges(state), [NSRange(location: 10, length: 20)], "the outer subsumes the inner")

        state.unfold(outer)
        XCTAssertEqual(state.regions, [inner])
        XCTAssertEqual(ranges(state), [NSRange(location: 14, length: 6)])
    }

    func testCoverageMergesOverlappingAndTouchingRangesAndKeepsSeparateOnesApart() {
        let overlapping = FoldState(regions: [region(10, 10, header: 0), region(15, 10, header: 1)])
        XCTAssertEqual(ranges(overlapping), [NSRange(location: 10, length: 15)])

        let touching = FoldState(regions: [region(10, 5, header: 0), region(15, 5, header: 2)])
        XCTAssertEqual(ranges(touching), [NSRange(location: 10, length: 10)])

        let apart = FoldState(regions: [region(30, 5, header: 6), region(10, 5, header: 0)])
        XCTAssertEqual(ranges(apart), [NSRange(location: 10, length: 5), NSRange(location: 30, length: 5)])
    }

    /// Both bounds are positions a caret may occupy; only what lies between them
    /// is hidden.
    func testHidesIsStrictlyInside() {
        let state = FoldState(regions: [region(10, 5, header: 0)])
        XCTAssertFalse(state.hides(offset: 9))
        XCTAssertFalse(state.hides(offset: 10))
        XCTAssertTrue(state.hides(offset: 11))
        XCTAssertTrue(state.hides(offset: 14))
        XCTAssertFalse(state.hides(offset: 15))
        XCTAssertFalse(state.hides(offset: 16))
    }

    func testFoldedContainingLineAnswersTheLongerRegionOnThatHeader() {
        let long = region(10, 20, header: 3)
        let short = region(10, 6, header: 3)
        let elsewhere = region(50, 4, header: 9)
        let state = FoldState(regions: [short, long, elsewhere])
        XCTAssertEqual(state.folded(containing: 3), long)
        XCTAssertEqual(state.folded(containing: 9), elsewhere)
        XCTAssertNil(state.folded(containing: 4))
    }

    // MARK: - Reconciliation

    func testReconciliationSurvivesMovesAndUnfolds() {
        let kept = region(10, 8, header: 1)
        let moved = region(40, 12, header: 5)
        let gone = region(90, 4, header: 12)
        let state = FoldState(regions: [kept, moved, gone])

        // The candidate on line 5 is one line shorter than the fold; line 12
        // has no candidate at all.
        let shorter = region(40, 7, header: 5)
        let reconciled = state.reconciled(with: [kept, shorter, region(70, 3, header: 8)])

        XCTAssertEqual(reconciled.regions, [kept, shorter])
        XCTAssertFalse(reconciled.isFolded(moved), "the stale bounds are gone")
        XCTAssertFalse(reconciled.isFolded(gone), "a fold whose header no candidate names unfolds")
    }

    func testReconciliationTakesTheLongerCandidateAndDedupesTwoFoldsOnOneHeader() {
        let state = FoldState(regions: [region(10, 20, header: 2), region(10, 6, header: 2)])
        let candidate = region(12, 30, header: 2)
        let reconciled = state.reconciled(with: [region(12, 9, header: 2), candidate])
        XCTAssertEqual(reconciled.regions, [candidate])
    }

    func testReconcilingAnEmptyStateAnswersItself() {
        let state = FoldState()
        XCTAssertEqual(state.reconciled(with: [region(10, 4, header: 0)]), state)
    }

    // MARK: - Clamping

    func testClampedDropsWhatCannotFitAndNeverTruncates() {
        let fits = region(10, 5, header: 0)
        let overflows = region(20, 10, header: 3)
        let state = FoldState(regions: [fits, overflows])

        let clamped = state.clamped(toLength: 25)
        XCTAssertEqual(clamped.regions, [fits], "a fold that cannot fit is dropped, not shortened")

        XCTAssertEqual(state.clamped(toLength: 30).regions, [fits, overflows], "exactly fitting is fitting")
        XCTAssertTrue(state.clamped(toLength: 0).isEmpty)
        XCTAssertTrue(state.clamped(toLength: -4).isEmpty)
    }

    // MARK: - The save-transform remap

    /// An autosave trimming trailing whitespace *inside* a folded block must
    /// leave it folded, with its end moved by exactly what the trim removed.
    func testRemapMovesAFoldAcrossATrailingWhitespaceTrimInsideIt() {
        let text = "func f() {\n    a   \n}"
        let plan = SaveTransform.plan(
            text: text,
            config: EditorConfigProperties(["trim_trailing_whitespace": "true"])
        )
        XCTAssertEqual(plan.text, "func f() {\n    a\n}", "the fixture must actually trim")

        // From the end of "func f() {" to the end of "}".
        let state = FoldState(regions: [region(10, 11, header: 0)])
        let remapped = state.remapped(through: plan)

        XCTAssertEqual(remapped.regions.count, 1)
        XCTAssertEqual(remapped.regions.first?.hiddenRange, NSRange(location: 10, length: 8))
        XCTAssertEqual(remapped.regions.first?.headerLine, 0, "no line count changed")
        XCTAssertEqual(
            (remapped.regions.first?.hiddenRange).map { (plan.text as NSString).substring(with: $0) },
            "\n    a\n}"
        )
    }

    func testRemapCarriesAFoldAcrossAnInsertedFinalNewline() {
        let text = "func f() {\n    a\n}"
        let plan = SaveTransform.plan(
            text: text,
            config: EditorConfigProperties(["insert_final_newline": "true"])
        )
        XCTAssertEqual(plan.text, "func f() {\n    a\n}\n", "the fixture must actually append")

        let block = region(10, 8, header: 0, kind: .region)
        let remapped = FoldState(regions: [block]).remapped(through: plan)
        XCTAssertEqual(remapped.regions, [block], "an insertion at the fold's end moves nothing, kind included")
    }

    func testRemapThroughAnEmptyPlanAnswersItself() {
        let plan = SaveTransform.plan(text: "a\nb", config: EditorConfigProperties())
        let state = FoldState(regions: [region(1, 2, header: 0)])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(state.remapped(through: plan), state)
    }

    // MARK: - The caret rule

    func testCaretMovingForwardLandsPastTheHiddenRange() {
        let state = FoldState(regions: [region(10, 8, header: 0)])
        let moved = FoldCaretRule.caret(
            for: NSRange(location: 12, length: 0),
            previous: NSRange(location: 9, length: 0),
            in: state
        )
        XCTAssertEqual(moved, NSRange(location: 18, length: 0))
    }

    func testCaretMovingBackwardLandsBeforeTheHiddenRange() {
        let state = FoldState(regions: [region(10, 8, header: 0)])
        let moved = FoldCaretRule.caret(
            for: NSRange(location: 16, length: 0),
            previous: NSRange(location: 18, length: 0),
            in: state
        )
        XCTAssertEqual(moved, NSRange(location: 10, length: 0))
    }

    /// A request carrying no direction — a click on the placeholder, or a
    /// programmatic selection — lands at the start.
    func testCaretWithNoDirectionLandsAtTheStart() {
        let state = FoldState(regions: [region(10, 8, header: 0)])
        let clicked = FoldCaretRule.caret(
            for: NSRange(location: 14, length: 0),
            previous: NSRange(location: NSNotFound, length: 0),
            in: state
        )
        XCTAssertEqual(clicked, NSRange(location: 10, length: 0))

        let unmoved = FoldCaretRule.caret(
            for: NSRange(location: 14, length: 0),
            previous: NSRange(location: 14, length: 0),
            in: state
        )
        XCTAssertEqual(unmoved, NSRange(location: 10, length: 0))
    }

    func testCaretMovingForwardIntoNestedFoldsLandsPastTheOutermost() {
        let state = FoldState(regions: [region(10, 20, header: 0), region(14, 6, header: 1)])
        let moved = FoldCaretRule.caret(
            for: NSRange(location: 15, length: 0),
            previous: NSRange(location: 10, length: 0),
            in: state
        )
        XCTAssertEqual(moved, NSRange(location: 30, length: 0), "the merged coverage decides, not the inner region")
    }

    func testASelectionWithLengthIsReturnedUntouched() {
        let state = FoldState(regions: [region(10, 8, header: 0)])
        let spanning = NSRange(location: 5, length: 20)
        XCTAssertEqual(
            FoldCaretRule.caret(for: spanning, previous: NSRange(location: 5, length: 0), in: state),
            spanning
        )
        let inside = NSRange(location: 12, length: 2)
        XCTAssertEqual(
            FoldCaretRule.caret(for: inside, previous: NSRange(location: 0, length: 0), in: state),
            inside
        )
    }

    func testVisibleCaretsAndBothBoundariesAreUntouched() {
        let state = FoldState(regions: [region(10, 8, header: 0)])
        for proposed in [0, 9, 10, 18, 19] {
            let range = NSRange(location: proposed, length: 0)
            XCTAssertEqual(
                FoldCaretRule.caret(for: range, previous: NSRange(location: 0, length: 0), in: state),
                range,
                "offset \(proposed) has a position on screen"
            )
        }
        let nowhere = NSRange(location: NSNotFound, length: 0)
        XCTAssertEqual(FoldCaretRule.caret(for: nowhere, previous: nowhere, in: state), nowhere)
    }

    // MARK: - The reveal rule

    func testRevealUnfoldsEveryIntersectingRegionIncludingTheOuterOne() {
        let outer = region(10, 20, header: 0)
        let inner = region(14, 6, header: 1)
        let elsewhere = region(50, 4, header: 9)
        let state = FoldState(regions: [outer, inner, elsewhere])

        let revealed = FoldReveal.unfolding(NSRange(location: 15, length: 2), in: state)
        XCTAssertEqual(revealed.regions, [elsewhere], "both nested folds open, the untouched one stays")
    }

    func testRevealOfAZeroLengthCaretInsideAFoldOpensIt() {
        let block = region(10, 8, header: 0)
        let state = FoldState(regions: [block])
        XCTAssertTrue(FoldReveal.unfolding(NSRange(location: 14, length: 0), in: state).isEmpty)
    }

    func testRevealOfARangeTouchingOnlyTheHeaderLineChangesNothing() {
        let block = region(10, 8, header: 0)
        let state = FoldState(regions: [block])
        XCTAssertEqual(FoldReveal.unfolding(NSRange(location: 0, length: 10), in: state), state)
        XCTAssertEqual(FoldReveal.unfolding(NSRange(location: 10, length: 0), in: state), state, "at the start")
        XCTAssertEqual(FoldReveal.unfolding(NSRange(location: 18, length: 4), in: state), state, "at the end")
        let nowhere = NSRange(location: NSNotFound, length: 0)
        XCTAssertEqual(FoldReveal.unfolding(nowhere, in: state), state)
    }

    // MARK: - The memory

    func testMemoryRecordsClampsForgetsAndClears() {
        let block = region(10, 8, header: 0)
        let far = region(40, 6, header: 5)
        var memory = FoldStateMemory()

        XCTAssertNil(memory.state(for: "/a.swift", clampedToLength: 100))

        memory.record(FoldState(regions: [block, far]), for: "/a.swift")
        XCTAssertEqual(memory.state(for: "/a.swift", clampedToLength: 100)?.regions, [block, far])
        XCTAssertEqual(
            memory.state(for: "/a.swift", clampedToLength: 30)?.regions,
            [block],
            "a shortened buffer drops what no longer fits"
        )

        memory.record(FoldState(), for: "/b.swift")
        XCTAssertEqual(memory.state(for: "/b.swift", clampedToLength: 100), FoldState(), "unfolded is a recorded answer")

        memory.forget("/a.swift")
        XCTAssertNil(memory.state(for: "/a.swift", clampedToLength: 100))
        XCTAssertNotNil(memory.state(for: "/b.swift", clampedToLength: 100))

        memory.removeAll()
        XCTAssertNil(memory.state(for: "/b.swift", clampedToLength: 100))
    }

    /// The deliberate divergence from `EditorViewportMemory`: there is nothing
    /// to prune with, because a closed file's folds must survive its reopening
    /// in the same run.
    func testTheMemoryKeepsAClosedFilesFolds() {
        var memory = FoldStateMemory()
        let block = region(10, 8, header: 0)
        memory.record(FoldState(regions: [block]), for: "/closed.swift")
        // Nothing here is told the file closed; reopening finds its folds.
        XCTAssertEqual(memory.state(for: "/closed.swift", clampedToLength: 100)?.regions, [block])
    }
}
