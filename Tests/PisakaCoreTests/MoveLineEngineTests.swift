import Foundation
@testable import PisakaCore
import XCTest

final class MoveLineEngineTests: XCTestCase {
    private func apply(_ plan: RangeEditPlan, to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in plan.edits.reversed() {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }

    private func move(
        _ text: String,
        _ ranges: [NSRange],
        _ direction: MoveLineDirection,
        folds: FoldState = FoldState()
    ) -> MoveLinePlan? {
        MoveLineEngine.move(text: text as NSString, ranges: ranges, direction: direction, folds: folds)
    }

    private func caret(_ offset: Int) -> NSRange { NSRange(location: offset, length: 0) }

    /// A folded region from `header` through `last`, shaped the way the scanner
    /// shapes one: from the header's content end to the last line's content end.
    private func fold(_ text: String, header: Int, last: Int) -> FoldRegion {
        let lines = TerminatedLines.ranges(text)
        let start = NSMaxRange(lines[header].content)
        let end = NSMaxRange(lines[last].content)
        return FoldRegion(hiddenRange: NSRange(location: start, length: end - start), headerLine: header)!
    }

    // MARK: - Single lines

    func testTheMiddleLineMovesDownWithTheCaretOnTheMovedText() throws {
        let plan = try XCTUnwrap(move("a\nb\nc\n", [caret(3)], .down))
        XCTAssertEqual(apply(plan.edit, to: "a\nb\nc\n"), "a\nc\nb\n")
        XCTAssertEqual(plan.edit.selections, [caret(5)])
        XCTAssertEqual(plan.edit.edits.count, 1)
    }

    func testTheMiddleLineMovesUp() throws {
        let plan = try XCTUnwrap(move("a\nb\nc\n", [caret(2)], .up))
        XCTAssertEqual(apply(plan.edit, to: "a\nb\nc\n"), "b\na\nc\n")
        XCTAssertEqual(plan.edit.selections, [caret(0)])
    }

    func testUpOnTheFirstLineIsANoOp() {
        XCTAssertNil(move("a\nb\nc\n", [caret(1)], .up))
    }

    func testDownOnTheLastLineIsANoOp() {
        XCTAssertNil(move("a\nb\nc", [caret(4)], .down))
        XCTAssertNil(move("a\nb\nc\n", [caret(4)], .down))
    }

    func testACaretOnThePhantomLineAfterAFinalSeparatorIsANoOp() {
        XCTAssertNil(move("a\nb\n", [caret(4)], .up))
        XCTAssertNil(move("a\nb\n", [caret(4)], .down))
    }

    func testOneBlockAtAnEdgeMakesTheWholeCommandANoOp() {
        XCTAssertNil(move("a\nb\nc\nd\n", [caret(0), caret(4)], .up))
    }

    func testAnEmptyFileAndASingleLineFileAreNoOps() {
        XCTAssertNil(move("", [caret(0)], .up))
        XCTAssertNil(move("", [caret(0)], .down))
        XCTAssertNil(move("abc", [caret(1)], .up))
        XCTAssertNil(move("abc", [caret(1)], .down))
        XCTAssertNil(move("abc\n", [caret(1)], .up))
        XCTAssertNil(move("abc\n", [caret(1)], .down))
    }

    // MARK: - Terminators

    func testTheUnterminatedLastLineMovesUpKeepingTheFileUnterminated() throws {
        let text = "a\nb\nc"
        let plan = try XCTUnwrap(move(text, [caret(5)], .up))
        let result = apply(plan.edit, to: text)
        XCTAssertEqual(result, "a\nc\nb")
        XCTAssertEqual(TerminatedLines.split(result).count, 3)
        XCTAssertEqual(TerminatedLines.split(result).last?.terminator, "")
        XCTAssertEqual(plan.edit.selections, [caret(3)])
    }

    func testALineMovesDownPastTheUnterminatedLastLine() throws {
        let text = "a\nb\nc"
        let plan = try XCTUnwrap(move(text, [caret(3)], .down))
        let result = apply(plan.edit, to: text)
        XCTAssertEqual(result, "a\nc\nb")
        XCTAssertEqual(TerminatedLines.split(result).count, 3)
        XCTAssertEqual(TerminatedLines.split(result).last?.terminator, "")
        XCTAssertEqual(plan.edit.selections, [caret(5)])
    }

    func testAPairReplacementKeepsTheSpanLength() throws {
        let plan = try XCTUnwrap(move("a\r\nbb\nc", [caret(4)], .down))
        for edit in plan.edit.edits {
            XCTAssertEqual((edit.replacement as NSString).length, edit.range.length)
        }
        XCTAssertEqual(apply(plan.edit, to: "a\r\nbb\nc"), "a\r\nc\nbb")
    }

    func testCRLFLinesSwapWholePairs() throws {
        let text = "a\r\nb\r\nc"
        let plan = try XCTUnwrap(move(text, [caret(0)], .down))
        XCTAssertEqual(apply(plan.edit, to: text), "b\r\na\r\nc")
        XCTAssertEqual(plan.edit.selections, [caret(3)])
    }

    func testEveryLineKeepsItsOwnTerminatorAcrossAllSixSeparators() throws {
        let separators = ["\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"]
        let contents = (0...separators.count).map { "l\($0)" }
        var text = ""
        for (index, content) in contents.enumerated() {
            text += content + (index < separators.count ? separators[index] : "")
        }
        let original = TerminatedLines.split(text)
        let starts = TerminatedLines.ranges(text).map(\.content.location)
        for line in 0..<(contents.count - 2) {
            let plan = try XCTUnwrap(move(text, [caret(starts[line])], .down))
            var expected = original
            expected.swapAt(line, line + 1)
            XCTAssertEqual(TerminatedLines.split(apply(plan.edit, to: text)), expected, "line \(line)")
        }
    }

    func testEverySeparatorIsHandedOverAtTheUnterminatedEnd() throws {
        for separator in ["\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"] {
            let text = "a" + separator + "b"
            let up = try XCTUnwrap(move(text, [caret((text as NSString).length)], .up))
            XCTAssertEqual(apply(up.edit, to: text), "b" + separator + "a")
            let down = try XCTUnwrap(move(text, [caret(0)], .down))
            XCTAssertEqual(apply(down.edit, to: text), "b" + separator + "a")
        }
    }

    // MARK: - Blocks

    func testAMultiLineSelectionMovesAndStaysSelected() throws {
        let text = "a\nb\nc\nd\n"
        let plan = try XCTUnwrap(move(text, [NSRange(location: 2, length: 3)], .down))
        let result = apply(plan.edit, to: text)
        XCTAssertEqual(result, "a\nd\nb\nc\n")
        XCTAssertEqual((result as NSString).substring(with: plan.edit.selections[0]), "b\nc")
    }

    func testASelectionEndingAtALineStartDoesNotCarryThatLine() throws {
        let text = "a\nb\nc\nd\n"
        let plan = try XCTUnwrap(move(text, [NSRange(location: 2, length: 2)], .down))
        let result = apply(plan.edit, to: text)
        XCTAssertEqual(result, "a\nc\nb\nd\n")
        XCTAssertEqual((result as NSString).substring(with: plan.edit.selections[0]), "b\n")
    }

    func testCaretsOnAdjacentLinesMergeIntoOneBlock() throws {
        let text = "a\nb\nc\nd\n"
        let plan = try XCTUnwrap(move(text, [caret(2), caret(4)], .up))
        XCTAssertEqual(plan.edit.edits.count, 1)
        XCTAssertEqual(apply(plan.edit, to: text), "b\nc\na\nd\n")
        XCTAssertEqual(plan.edit.selections, [caret(0), caret(2)])
    }

    func testTwoSeparateBlocksMoveIndependentlyInOnePlan() throws {
        let text = "a\nb\nc\nd\ne\n"
        let plan = try XCTUnwrap(move(text, [caret(0), caret(6)], .down))
        XCTAssertEqual(plan.edit.edits.count, 2)
        XCTAssertEqual(apply(plan.edit, to: text), "b\na\nc\ne\nd\n")
        XCTAssertEqual(plan.edit.selections, [caret(2), caret(8)])
    }

    func testBlocksOneLineApartDoNotCollide() throws {
        let text = "a\nb\nc\nd\n"
        let down = try XCTUnwrap(move(text, [caret(0), caret(4)], .down))
        XCTAssertEqual(apply(down.edit, to: text), "b\na\nd\nc\n")
        XCTAssertEqual(down.edit.selections, [caret(2), caret(6)])
        let up = try XCTUnwrap(move(text, [caret(2), caret(6)], .up))
        XCTAssertEqual(apply(up.edit, to: text), "b\na\nd\nc\n")
        XCTAssertEqual(up.edit.selections, [caret(0), caret(4)])
    }

    // MARK: - Folds

    func testAFoldedNeighbourIsSkippedWhole() throws {
        let text = "x\nfunc {\n  body\n}\ny\n"
        let folded = fold(text, header: 1, last: 3)
        let plan = try XCTUnwrap(move(text, [caret(18)], .up, folds: FoldState(regions: [folded])))
        let result = apply(plan.edit, to: text)
        XCTAssertEqual(result, "x\ny\nfunc {\n  body\n}\n")
        XCTAssertEqual(plan.edit.selections, [caret(2)])
        XCTAssertEqual(plan.folds, FoldState(regions: [fold(result, header: 2, last: 4)]))
        XCTAssertEqual(plan.folds.regions.first?.hiddenRange, NSRange(location: 10, length: 9))
    }

    func testAMovedBlockCarriesItsFold() throws {
        let text = "x\nfunc {\n  body\n}\ny\n"
        let folded = fold(text, header: 1, last: 3)
        let down = try XCTUnwrap(move(text, [caret(3)], .down, folds: FoldState(regions: [folded])))
        let downResult = apply(down.edit, to: text)
        XCTAssertEqual(downResult, "x\ny\nfunc {\n  body\n}\n")
        XCTAssertEqual(down.edit.selections, [caret(5)])
        XCTAssertEqual(down.folds, FoldState(regions: [fold(downResult, header: 2, last: 4)]))

        let up = try XCTUnwrap(move(text, [caret(3)], .up, folds: FoldState(regions: [folded])))
        let upResult = apply(up.edit, to: text)
        XCTAssertEqual(upResult, "func {\n  body\n}\nx\ny\n")
        XCTAssertEqual(up.folds, FoldState(regions: [fold(upResult, header: 0, last: 2)]))
    }

    func testACaretOnAFoldsLastLineMovesTheWholeFold() throws {
        let text = "x\nfunc {\n  body\n}\ny\n"
        let folded = fold(text, header: 1, last: 3)
        let plan = try XCTUnwrap(move(text, [caret(16)], .down, folds: FoldState(regions: [folded])))
        XCTAssertEqual(apply(plan.edit, to: text), "x\ny\nfunc {\n  body\n}\n")
    }

    func testANestedFoldMovesWithItsOuterFold() throws {
        let text = "x\nf {\n g {\n  h\n }\n}\ny\n"
        let outer = fold(text, header: 1, last: 5)
        let inner = fold(text, header: 2, last: 4)
        let plan = try XCTUnwrap(move(text, [caret(0)], .down, folds: FoldState(regions: [outer, inner])))
        let result = apply(plan.edit, to: text)
        XCTAssertEqual(result, "f {\n g {\n  h\n }\n}\nx\ny\n")
        XCTAssertEqual(
            plan.folds,
            FoldState(regions: [fold(result, header: 0, last: 4), fold(result, header: 1, last: 3)])
        )
    }

    func testFoldsOutsideTheMovedPairAreUnchanged() throws {
        let text = "a\nb\nc\ng {\n  z\n}\n"
        let untouched = fold(text, header: 3, last: 5)
        let plan = try XCTUnwrap(move(text, [caret(0)], .down, folds: FoldState(regions: [untouched])))
        XCTAssertEqual(apply(plan.edit, to: text), "b\na\nc\ng {\n  z\n}\n")
        XCTAssertEqual(plan.folds, FoldState(regions: [untouched]))
    }

    func testAFoldEndingTheUnterminatedFileMovesWithTheHandover() throws {
        let text = "y\nf {\n b\n}"
        let folded = fold(text, header: 1, last: 3)
        let plan = try XCTUnwrap(move(text, [caret(0)], .down, folds: FoldState(regions: [folded])))
        let result = apply(plan.edit, to: text)
        XCTAssertEqual(result, "f {\n b\n}\ny")
        XCTAssertEqual(plan.folds, FoldState(regions: [fold(result, header: 0, last: 2)]))
        XCTAssertEqual(plan.edit.selections, [caret(9)])
    }

    // MARK: - Undo

    /// Undo of a move is an ordinary edit: the inverse replacement (the pair's
    /// span in the moved text, given back the original pair text) runs through
    /// `FoldShift.updated` and nothing else. The fold inside the swapped span
    /// is dropped — it opens on undo — while a fold outside it shifts
    /// unchanged. No fold is ever registered in undo.
    func testUndoingAMoveReplaysTheInverseEditThroughTheShiftRule() throws {
        let text = "x\nfunc {\n  body\n}\ny\ng {\n  z\n}\n"
        let moved = fold(text, header: 1, last: 3)
        let outside = fold(text, header: 5, last: 7)
        let plan = try XCTUnwrap(move(text, [caret(3)], .down, folds: FoldState(regions: [moved, outside])))
        let result = apply(plan.edit, to: text)
        XCTAssertEqual(result, "x\ny\nfunc {\n  body\n}\ng {\n  z\n}\n")
        XCTAssertEqual(
            plan.folds,
            FoldState(regions: [fold(result, header: 2, last: 4), outside])
        )

        let edit = try XCTUnwrap(plan.edit.edits.first)
        XCTAssertEqual(plan.edit.edits.count, 1)
        let originalPair = (text as NSString).substring(with: edit.range)
        // The replacement is exactly as long as the span it replaced, so the
        // pair's span in the new text is the same range.
        let inverseRange = NSRange(location: edit.range.location, length: (edit.replacement as NSString).length)
        let undone = NSMutableString(string: result)
        undone.replaceCharacters(in: inverseRange, with: originalPair)
        XCTAssertEqual(undone as String, text)

        let afterUndo = FoldShift.updated(
            plan.folds,
            previousLineStarts: LineStartIndex.offsets(in: result as NSString),
            newLineStarts: LineStartIndex.offsets(in: undone),
            editedRange: NSRange(location: inverseRange.location, length: (originalPair as NSString).length),
            changeInLength: (originalPair as NSString).length - inverseRange.length
        )
        XCTAssertEqual(afterUndo, FoldState(regions: [outside]))
    }
}
