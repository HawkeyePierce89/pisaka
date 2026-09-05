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

    /// **The layout's question, not the caret's.** A line has no row of its own
    /// when the separator that would have broken it is hidden, which is the code
    /// unit *before* its start and is inclusive of the hidden range's own start —
    /// where the header's separator sits.
    func testTheCollapsingRangeIsTheOneCoveringTheSeparatorBeforeTheLine() {
        // "ab\ncd\nef\ngh", hiding from the end of line 0 through the end of
        // line 2: offsets 2..<8.
        let state = FoldState(regions: [region(2, 6, header: 0)])

        XCTAssertNil(state.hiddenRange(collapsingLineStartingAt: 0), "line 0 is the header")
        XCTAssertEqual(
            state.hiddenRange(collapsingLineStartingAt: 3),
            NSRange(location: 2, length: 6),
            "line 1's separator is the hidden range's own first unit"
        )
        XCTAssertEqual(state.hiddenRange(collapsingLineStartingAt: 6), NSRange(location: 2, length: 6))
        XCTAssertNil(state.hiddenRange(collapsingLineStartingAt: 9), "the line after the block breaks again")
    }

    /// The case `hides(offset:)` cannot answer: a hidden range ending exactly at
    /// a line start — the shape a server naming `endCharacter: 0` produces. That
    /// line is already laid out on the header's row, and answering "visible" for
    /// it stacks a second gutter number on the header's.
    func testALineStartingWhereAHiddenRangeEndsIsStillCollapsed() {
        let state = FoldState(regions: [region(2, 4, header: 0)])
        XCTAssertFalse(state.hides(offset: 6), "the caret may rest there")
        XCTAssertEqual(
            state.hiddenRange(collapsingLineStartingAt: 6),
            NSRange(location: 2, length: 4),
            "but the line starting there has no row of its own"
        )
    }

    func testNothingCollapsesTheFirstLineOrAnEmptyState() {
        XCTAssertNil(FoldState().hiddenRange(collapsingLineStartingAt: 5))
        XCTAssertNil(FoldState(regions: [region(2, 6, header: 0)]).hiddenRange(collapsingLineStartingAt: 0))
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

    /// One candidate on the header line is the fallback scanner's guarantee, and
    /// then every fold on that line re-anchors to it — two folds collapse into
    /// one, because there is only one block left to be folded.
    func testReconciliationCollapsesTwoFoldsOntoTheOneCandidateTheirHeaderHas() {
        let state = FoldState(regions: [region(10, 20, header: 2), region(10, 6, header: 2)])
        let candidate = region(12, 30, header: 2)
        let reconciled = state.reconciled(with: [candidate])
        XCTAssertEqual(reconciled.regions, [candidate])
    }

    /// **A nested fold is not promoted to its outer sibling.** A server may report
    /// a block and a nested one opening on the same line, and ⌘⌥← collapses the
    /// innermost of them; re-anchoring by header line alone would take the longest
    /// candidate on the next answer and silently grow the fold over code the user
    /// never collapsed. Each fold takes the candidate closest to its own length.
    func testReconciliationKeepsAnInnerFoldInnerWhenAHeaderCarriesTwoCandidates() {
        let outer = region(12, 30, header: 2)
        let inner = region(12, 9, header: 2)
        let state = FoldState(regions: [region(10, 6, header: 2)])

        let reconciled = state.reconciled(with: [inner, outer])

        XCTAssertEqual(reconciled.regions, [inner], "the short fold re-anchors to the short candidate")
        XCTAssertEqual(
            FoldState(regions: [region(10, 26, header: 2)]).reconciled(with: [inner, outer]).regions,
            [outer],
            "and the long one to the long candidate"
        )
    }

    /// Ties keep `FoldRegion`'s own order, so nothing about a header line with a
    /// single candidate changed: the longest still wins when the distances agree.
    func testReconciliationBreaksATieByTheOrderingKey() {
        let longer = region(10, 12, header: 0)
        let shorter = region(10, 8, header: 0)
        let state = FoldState(regions: [region(10, 10, header: 0)])
        XCTAssertEqual(state.reconciled(with: [shorter, longer]).regions, [longer])
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
        XCTAssertEqual(FoldRegion.remapped(state.regions, through: plan), state.regions)
    }

    /// **The candidate list takes the same remap the folded state does.** A save
    /// moves offsets under a list the next answer will not replace for another
    /// debounce, and a chevron clicked in that window would fold bounds measured
    /// against the pre-save text.
    func testTheCandidateListIsRemappedByTheSameRuleAndDropsWhatEmpties() {
        let text = "func f() {\n    a   \n}\nlet b = 1   \n"
        let plan = SaveTransform.plan(
            text: text,
            config: EditorConfigProperties(["trim_trailing_whitespace": "true"])
        )
        XCTAssertEqual(plan.text, "func f() {\n    a\n}\nlet b = 1\n")

        // The block, and a candidate covering only the three spaces the trim
        // deletes — which remaps to nothing and is dropped rather than kept empty.
        let block = region(10, 11, header: 0)
        let doomed = region(16, 3, header: 1)

        let remapped = FoldRegion.remapped([block, doomed], through: plan)

        XCTAssertEqual(remapped.map(\.hiddenRange), [NSRange(location: 10, length: 8)])
        XCTAssertEqual(remapped.map(\.headerLine), [0], "header lines are carried unchanged")
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

    /// A save that catches a tab no editor is showing rewrites it behind the
    /// editor, which is the same replacement signal a Replace All raises — and
    /// those *do* invalidate what was folded. A save does not, so the remembered
    /// folds take the plan's remap here exactly as a shown buffer's do; otherwise
    /// an unattended autosave would open every fold in a background tab.
    func testMemoryRemapsOneFilesFoldsThroughASavesPlan() {
        let text = "func f() {\n    a   \n}\n"
        let plan = SaveTransform.plan(
            text: text,
            config: EditorConfigProperties(["trim_trailing_whitespace": "true"])
        )
        XCTAssertEqual(plan.text, "func f() {\n    a\n}\n", "the fixture must actually trim")

        var memory = FoldStateMemory()
        // From the end of "func f() {" to the end of "}".
        let block = region(10, 11, header: 0)
        let untouched = FoldState(regions: [block])
        memory.record(untouched, for: "/saved.swift")
        memory.record(untouched, for: "/other.swift")

        memory.remap("/saved.swift", through: plan)

        XCTAssertEqual(
            memory.state(for: "/saved.swift", clampedToLength: (plan.text as NSString).length)?.regions.first?
                .hiddenRange,
            NSRange(location: 10, length: 8),
            "the trimmed run is taken out of the hidden range rather than springing the fold open"
        )
        XCTAssertEqual(
            memory.state(for: "/saved.swift", clampedToLength: (plan.text as NSString).length)?.regions.first?
                .headerLine,
            0,
            "no line count changed"
        )
        XCTAssertEqual(
            memory.state(for: "/other.swift", clampedToLength: 100),
            untouched,
            "one save moves one file's entry"
        )

        memory.remap("/never-opened.swift", through: plan)
        XCTAssertNil(
            memory.state(for: "/never-opened.swift", clampedToLength: 100),
            "a file this store was never told about stays absent rather than gaining an empty entry"
        )
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

    // MARK: - The two commands' decisions

    /// The fixture both commands are asked about — a function with a nested
    /// `if`, hand-counted so the offsets below mean what they say:
    ///
    /// ```
    /// 0  func a() {     0…9,   separator 10
    /// 1    if b {      11…18,  separator 19
    /// 2      c()       20…26,  separator 27
    /// 3    }           28…30,  separator 31
    /// 4  }             32
    /// ```
    private var commandLineStarts: [Int] { [0, 11, 20, 28, 32] }
    /// The whole function: from the end of line 0's content to the end of line 4's.
    private var outerBlock: FoldRegion { region(10, 23, header: 0) }
    /// The nested `if`: from the end of line 1's content to the end of line 3's.
    private var innerBlock: FoldRegion { region(19, 12, header: 1) }

    func testFoldTakesTheInnermostCandidateTheCaretIsIn() {
        let candidates = [outerBlock, innerBlock]

        // Inside the nested block: the inner one, not the function around it.
        XCTAssertEqual(
            FoldCommandRule.regionToFold(
                selection: NSRange(location: 22, length: 0),
                lineStarts: commandLineStarts,
                in: candidates
            ),
            innerBlock
        )

        // On the outer header line, which the inner block does not reach.
        XCTAssertEqual(
            FoldCommandRule.regionToFold(
                selection: NSRange(location: 3, length: 0),
                lineStarts: commandLineStarts,
                in: candidates
            ),
            outerBlock
        )

        // On the inner header line: the inner block is *at* it.
        XCTAssertEqual(
            FoldCommandRule.regionToFold(
                selection: NSRange(location: 13, length: 0),
                lineStarts: commandLineStarts,
                in: candidates
            ),
            innerBlock
        )

        // The block's last line is still the block; the inner one ended above it.
        XCTAssertEqual(
            FoldCommandRule.regionToFold(
                selection: NSRange(location: 32, length: 0),
                lineStarts: commandLineStarts,
                in: candidates
            ),
            outerBlock
        )
    }

    func testFoldAnswersNothingWhenTheCaretIsInNoCandidate() {
        XCTAssertNil(
            FoldCommandRule.regionToFold(
                selection: NSRange(location: 5, length: 0),
                lineStarts: commandLineStarts,
                in: []
            ),
            "no candidates, nothing to fold"
        )
        XCTAssertNil(
            FoldCommandRule.regionToFold(
                selection: NSRange(location: 22, length: 0),
                lineStarts: commandLineStarts,
                in: [region(40, 6, header: 5)]
            ),
            "a block the caret is nowhere near"
        )
        XCTAssertNil(
            FoldCommandRule.regionToFold(
                selection: NSRange(location: NSNotFound, length: 0),
                lineStarts: commandLineStarts,
                in: [outerBlock]
            ),
            "a selection naming no position is in no region"
        )
    }

    /// The refusal: a selection reaching past the block would leave half of what
    /// the user selected on screen and hide the rest.
    func testFoldRefusesASelectionThatExtendsBeyondTheRegion() {
        let candidates = [outerBlock, innerBlock]

        XCTAssertNil(
            FoldCommandRule.regionToFold(
                selection: NSRange(location: 13, length: 20),
                lineStarts: commandLineStarts,
                in: candidates
            ),
            "the selection ends past the inner block's last line"
        )

        // The same caret, selecting inside the block, is not a refusal — and
        // neither is the plain caret.
        XCTAssertEqual(
            FoldCommandRule.regionToFold(
                selection: NSRange(location: 13, length: 5),
                lineStarts: commandLineStarts,
                in: candidates
            ),
            innerBlock
        )
        XCTAssertEqual(
            FoldCommandRule.regionToFold(
                selection: NSRange(location: 13, length: 0),
                lineStarts: commandLineStarts,
                in: candidates
            ),
            innerBlock
        )
    }

    func testUnfoldTakesTheInnermostFoldedRegionTheCaretIsIn() {
        var state = FoldState(regions: [outerBlock, innerBlock])

        // The caret sits on the outer header line, the one line both folds leave
        // visible: the outer block is what opens.
        XCTAssertEqual(
            FoldCommandRule.regionToUnfold(
                selection: NSRange(location: 0, length: 0),
                lineStarts: commandLineStarts,
                in: state
            ),
            outerBlock
        )

        // With the outer one open the inner header line is reachable, and the
        // inner block is what the caret is now in.
        state.unfold(outerBlock)
        XCTAssertEqual(
            FoldCommandRule.regionToUnfold(
                selection: NSRange(location: 13, length: 0),
                lineStarts: commandLineStarts,
                in: state
            ),
            innerBlock
        )

        // Nothing folded, nothing to open — the command beeps.
        state.unfold(innerBlock)
        XCTAssertNil(
            FoldCommandRule.regionToUnfold(
                selection: NSRange(location: 13, length: 0),
                lineStarts: commandLineStarts,
                in: state
            )
        )
    }

    /// Unfold has no refusal of its own: opening a block can never hide anything.
    func testUnfoldAcceptsASelectionThatExtendsBeyondTheRegion() {
        XCTAssertEqual(
            FoldCommandRule.regionToUnfold(
                selection: NSRange(location: 13, length: 20),
                lineStarts: commandLineStarts,
                in: FoldState(regions: [innerBlock])
            ),
            innerBlock
        )
    }

    /// Where the caret lands after *Fold*: the start of the header line, which
    /// the region it just folded can never hide — so the caret rule, the one
    /// rule that moves a caret here, returns it untouched.
    func testTheHeaderLinesStartSurvivesFoldingThatRegion() {
        let none = NSRange(location: NSNotFound, length: 0)
        for block in [outerBlock, innerBlock] {
            let caret = NSRange(location: commandLineStarts[block.headerLine], length: 0)
            XCTAssertEqual(
                FoldCaretRule.caret(for: caret, previous: none, in: FoldState(regions: [block])),
                caret
            )
        }
    }
}
