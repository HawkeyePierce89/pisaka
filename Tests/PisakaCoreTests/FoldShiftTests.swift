import XCTest
@testable import PisakaCore

/// `FoldShift` — the three-way rule that keeps folds anchored between two
/// authored answers, and the fallback that refuses to guess.
///
/// The line-start tables are computed from real text through `LineStartIndex`
/// rather than written out, so a renumbering assertion is about the editor's own
/// numbering and not about a table the test invented.
final class FoldShiftTests: XCTestCase {

    // MARK: - Helpers

    private func region(_ location: Int, _ length: Int, header: Int, kind: FoldRegionKind? = nil) -> FoldRegion {
        FoldRegion(hiddenRange: NSRange(location: location, length: length), headerLine: header, kind: kind)!
    }

    private func starts(_ text: String) -> [Int] {
        LineStartIndex.offsets(in: text as NSString)
    }

    private func shifted(
        _ regions: [FoldRegion],
        from previous: String,
        to new: String,
        edited: NSRange,
        delta: Int
    ) -> [FoldRegion] {
        FoldShift.updated(
            regions,
            previousLineStarts: starts(previous),
            newLineStarts: starts(new),
            editedRange: edited,
            changeInLength: delta
        )
    }

    /// `"a\nfoo {\n  b\n}\n"` — the fold hides from the end of `foo {` (offset 7)
    /// to the end of `}` (offset 13).
    private let previousText = "a\nfoo {\n  b\n}\n"
    private var block: FoldRegion { region(7, 6, header: 1) }

    // MARK: - The three ways

    func testARegionEntirelyBeforeTheEditIsUntouched() {
        let previous = "{\n}\nxxxx\n"
        let before = region(1, 2, header: 0)
        // Typing at the very end, well past the region.
        let result = shifted([before], from: previous, to: "{\n}\nxxxxY\n", edited: NSRange(location: 8, length: 1), delta: 1)
        XCTAssertEqual(result, [before], "bounds and header line, byte for byte")
    }

    func testARegionEntirelyAfterTheEditIsShiftedAndRenumbered() {
        // A newline inserted at the very start pushes everything down one line.
        let result = shifted(
            [block],
            from: previousText,
            to: "\n" + previousText,
            edited: NSRange(location: 0, length: 1),
            delta: 1
        )
        XCTAssertEqual(result, [region(8, 6, header: 2)])
    }

    func testAShiftedRegionKeepsItsKind() {
        let named = region(7, 6, header: 1, kind: .comment)
        let result = shifted(
            [named],
            from: previousText,
            to: "\n" + previousText,
            edited: NSRange(location: 0, length: 1),
            delta: 1
        )
        XCTAssertEqual(result.first?.kind, .comment)
    }

    func testARegionIntersectingTheEditIsDropped() {
        // Replacing the block's body: the edit lands inside the hidden range.
        let result = shifted(
            [block],
            from: previousText,
            to: "a\nfoo {\n  zzz\n}\n",
            edited: NSRange(location: 10, length: 3),
            delta: 2
        )
        XCTAssertEqual(result, [], "that block unfolds")
    }

    func testADeletionCoveringTheWholeRegionDropsIt() {
        let result = shifted(
            [block],
            from: previousText,
            to: "a\n",
            edited: NSRange(location: 2, length: 0),
            delta: -12
        )
        XCTAssertEqual(result, [])
    }

    // MARK: - Both half-open edges

    /// A region ending exactly at the edit's location covers only characters the
    /// edit did not touch.
    func testARegionEndingExactlyAtTheEditSurvivesUnchanged() {
        let previous = "{\n}\ntail"
        let ending = region(1, 2, header: 0) // ends at 3, the separator before "tail"
        let result = shifted(
            [ending],
            from: previous,
            to: "{\n}\nXtail",
            edited: NSRange(location: 3, length: 1),
            delta: 1
        )
        XCTAssertEqual(result, [ending])
    }

    /// A region starting exactly at the pre-edit end of the replaced span covers
    /// only characters the edit did not remove — which is what makes typing at
    /// the end of a header line keep its block folded.
    func testARegionStartingExactlyAtTheReplacedEndSurvivesShifted() {
        // A pure insertion at offset 7 — the end of "foo {"'s content, i.e. the
        // fold's own start.
        let result = shifted(
            [block],
            from: previousText,
            to: "a\nfoo {!\n  b\n}\n",
            edited: NSRange(location: 7, length: 1),
            delta: 1
        )
        XCTAssertEqual(result, [region(8, 6, header: 1)], "the block stays folded over the same text")
    }

    func testAZeroLengthInsertionAtTheRegionsEndDoesNotDropIt() {
        // Insertion at 13, the fold's end: "entirely before" holds (`end <= loc`).
        let result = shifted(
            [block],
            from: previousText,
            to: "a\nfoo {\n  b\n}!\n",
            edited: NSRange(location: 13, length: 1),
            delta: 1
        )
        XCTAssertEqual(result, [block])
    }

    func testAnInsertionStrictlyInsideDropsTheRegion() {
        let result = shifted(
            [block],
            from: previousText,
            to: "a\nfoo {\n  b!\n}\n",
            edited: NSRange(location: 11, length: 1),
            delta: 1
        )
        XCTAssertEqual(result, [])
    }

    func testEachRegionIsJudgedOnItsOwn() {
        let early = region(1, 2, header: 0)
        let late = region(21, 2, header: 2)
        let previous = "{\n}\nxxxxxxxxxxxxxxxx{\n}\n"
        let new = "{\n}\nYxxxxxxxxxxxxxxxx{\n}\n"
        let result = shifted([early, late], from: previous, to: new, edited: NSRange(location: 4, length: 1), delta: 1)
        XCTAssertEqual(result, [early, region(22, 2, header: 2)])
    }

    // MARK: - The fallback

    func testAnInconsistentLineStartTableAnswersNothingFolded() {
        let edited = NSRange(location: 0, length: 1)
        XCTAssertEqual(
            FoldShift.updated([block], previousLineStarts: [], newLineStarts: [0], editedRange: edited, changeInLength: 1),
            []
        )
        XCTAssertEqual(
            FoldShift.updated([block], previousLineStarts: [0], newLineStarts: [4], editedRange: edited, changeInLength: 1),
            []
        )
    }

    func testANegativeEditedRangeAnswersNothingFolded() {
        XCTAssertEqual(
            FoldShift.updated(
                [block],
                previousLineStarts: [0],
                newLineStarts: [0],
                editedRange: NSRange(location: -1, length: 1),
                changeInLength: 0
            ),
            []
        )
        XCTAssertEqual(
            FoldShift.updated(
                [block],
                previousLineStarts: [0],
                newLineStarts: [0],
                editedRange: NSRange(location: 0, length: -1),
                changeInLength: 0
            ),
            []
        )
    }

    func testAnOldEndBeforeTheEditsLocationAnswersNothingFolded() {
        XCTAssertEqual(
            FoldShift.updated(
                [block],
                previousLineStarts: [0],
                newLineStarts: [0],
                editedRange: NSRange(location: 0, length: 0),
                changeInLength: 5
            ),
            []
        )
    }

    func testADegenerateEditedRangeAnswersNothingFoldedRatherThanTrapping() {
        XCTAssertEqual(
            FoldShift.updated(
                [block],
                previousLineStarts: [0],
                newLineStarts: [0],
                editedRange: NSRange(location: 1, length: NSNotFound),
                changeInLength: 0
            ),
            []
        )
    }

    func testARegionWhoseEndOverflowsAnswersNothingFolded() {
        let degenerate = region(Int.max - 1, 4, header: 0)
        XCTAssertEqual(
            FoldShift.updated(
                [block, degenerate],
                previousLineStarts: [0],
                newLineStarts: [0],
                editedRange: NSRange(location: 0, length: 1),
                changeInLength: 1
            ),
            [],
            "one bad entry poisons the whole answer"
        )
    }

    func testAShiftOverflowingARegionsBoundsAnswersNothingFolded() {
        let high = region(Int.max - 10, 4, header: 0)
        XCTAssertEqual(
            FoldShift.updated(
                [high],
                previousLineStarts: [0],
                newLineStarts: [0],
                editedRange: NSRange(location: 0, length: 30),
                changeInLength: 20
            ),
            [],
            "the region is after the edit, and shifting it would overflow"
        )
    }

    /// A survivor can never land at a negative offset: "entirely after" means
    /// `start >= oldEnd = loc + length - delta`, so a shifted start is at least
    /// `loc`, which the gate already refused to let be negative. The initializer
    /// refusal in the shift is therefore handled and unreachable — asserted here
    /// as the property it is, rather than as a case with no input.
    func testEveryShiftedSurvivorLandsAtANonNegativeOffset() {
        let far = region(60, 4, header: 0)
        let result = FoldShift.updated(
            [far],
            previousLineStarts: [0],
            newLineStarts: [0],
            editedRange: NSRange(location: 0, length: 10),
            changeInLength: -50
        )
        XCTAssertEqual(result, [region(10, 4, header: 0)])
    }

    // MARK: - The state overload

    func testTheStateOverloadKeepsSurvivorsAndRederivesTheCoverage() {
        let outer = region(7, 6, header: 1)
        let inner = region(9, 3, header: 2)
        let state = FoldState(regions: [outer, inner])
        let result = FoldShift.updated(
            state,
            previousLineStarts: starts(previousText),
            newLineStarts: starts("\n" + previousText),
            editedRange: NSRange(location: 0, length: 1),
            changeInLength: 1
        )
        XCTAssertEqual(result.regions, [region(8, 6, header: 2), region(10, 3, header: 3)])
        XCTAssertEqual(result.hiddenRanges, [NSRange(location: 8, length: 6)], "the merge is redone, not shifted")
    }

    func testTheStateOverloadDropsAnIntersectingFold() {
        let state = FoldState(regions: [block])
        let result = FoldShift.updated(
            state,
            previousLineStarts: starts(previousText),
            newLineStarts: starts("a\nfoo {\n  bb\n}\n"),
            editedRange: NSRange(location: 11, length: 1),
            changeInLength: 1
        )
        XCTAssertTrue(result.isEmpty)
    }
}
