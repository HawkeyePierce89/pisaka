import Foundation
@testable import PisakaCore
import XCTest

final class BlockIndentEngineTests: XCTestCase {
    private func apply(_ plan: RangeEditPlan, to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in plan.edits.reversed() {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }

    private func indent(_ text: String, _ ranges: [NSRange], unit: String = "    ") -> RangeEditPlan {
        BlockIndentEngine.indent(text: text as NSString, ranges: ranges, unit: unit)
    }

    private func outdent(_ text: String, _ ranges: [NSRange], unit: String = "    ") -> RangeEditPlan {
        BlockIndentEngine.outdent(text: text as NSString, ranges: ranges, unit: unit)
    }

    private func selected(_ plan: RangeEditPlan, in text: String) -> [String] {
        let result = apply(plan, to: text) as NSString
        return plan.selections.map { result.substring(with: $0) }
    }

    // MARK: - isBlockSelection

    func testACaretIsNotABlockSelection() {
        XCTAssertFalse(BlockIndentEngine.isBlockSelection(text: "a\nb", ranges: [NSRange(location: 1, length: 0)]))
    }

    func testASelectionInsideOneLineIsNotABlockSelection() {
        XCTAssertFalse(BlockIndentEngine.isBlockSelection(text: "abc\nd", ranges: [NSRange(location: 0, length: 3)]))
    }

    func testASelectionAcrossTwoLinesIsABlockSelection() {
        XCTAssertTrue(BlockIndentEngine.isBlockSelection(text: "abc\ndef", ranges: [NSRange(location: 1, length: 4)]))
    }

    func testAWholeLineWithItsTerminatorIsABlockSelection() {
        XCTAssertTrue(BlockIndentEngine.isBlockSelection(text: "abc\ndef", ranges: [NSRange(location: 0, length: 4)]))
    }

    func testAWholeLastLineWithoutATerminatorIsNotABlockSelection() {
        XCTAssertFalse(BlockIndentEngine.isBlockSelection(text: "abc\ndef", ranges: [NSRange(location: 4, length: 3)]))
    }

    func testOneBlockRangeAmongCaretsMakesTheWholeSetABlock() {
        let ranges = [NSRange(location: 0, length: 0), NSRange(location: 4, length: 4)]
        XCTAssertTrue(BlockIndentEngine.isBlockSelection(text: "abc\ndef\ng", ranges: ranges))
    }

    func testIsBlockSelectionOnAnEmptyFileIsFalse() {
        XCTAssertFalse(BlockIndentEngine.isBlockSelection(text: "", ranges: [NSRange(location: 0, length: 0)]))
    }

    func testEverySeparatorMakesAWholeLineABlock() {
        for separator in ["\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"] {
            let text = "abc" + separator + "def"
            let length = 3 + (separator as NSString).length
            XCTAssertTrue(
                BlockIndentEngine.isBlockSelection(text: text as NSString, ranges: [NSRange(location: 0, length: length)]),
                separator.debugDescription
            )
        }
    }

    func testHalfACRLFPairIsNotAWholeLine() {
        XCTAssertFalse(BlockIndentEngine.isBlockSelection(text: "abc\r\ndef", ranges: [NSRange(location: 0, length: 4)]))
    }

    // MARK: - Indent

    func testThreeLinesIndentWithTheSelectionPreservedAndOutdentRestoresThem() {
        let text = "one\ntwo\nthree\nfour"
        let range = NSRange(location: 0, length: 14) // "one\ntwo\nthree\n"
        let indented = indent(text, [range])

        XCTAssertEqual(apply(indented, to: text), "    one\n    two\n    three\nfour")
        XCTAssertEqual(selected(indented, in: text), ["    one\n    two\n    three\n"])

        let indentedText = apply(indented, to: text)
        let outdented = outdent(indentedText, indented.selections)
        XCTAssertEqual(apply(outdented, to: indentedText), text)
        XCTAssertEqual(outdented.selections, [range])
    }

    func testAMidLineSelectionKeepsCoveringTheSameText() {
        let text = "alpha\nbeta\ngamma"
        let range = NSRange(location: 2, length: 7) // "pha\nbet"
        let plan = indent(text, [range])

        XCTAssertEqual(apply(plan, to: text), "    alpha\n    beta\ngamma")
        XCTAssertEqual(selected(plan, in: text), ["pha\n    bet"])
    }

    func testTabUnit() {
        let text = "a\nb\n"
        let plan = indent(text, [NSRange(location: 0, length: 3)], unit: "\t")
        XCTAssertEqual(apply(plan, to: text), "\ta\n\tb\n")
    }

    func testBlankAndWhitespaceOnlyLinesAreSkipped() {
        let text = "a\n\n   \nb\n"
        let plan = indent(text, [NSRange(location: 0, length: (text as NSString).length)])
        XCTAssertEqual(apply(plan, to: text), "    a\n\n   \n    b\n")
    }

    func testASelectionEndingAtALineStartDoesNotTouchThatLine() {
        let text = "a\nb\nc"
        let plan = indent(text, [NSRange(location: 0, length: 4)]) // "a\nb\n"
        XCTAssertEqual(apply(plan, to: text), "    a\n    b\nc")
        XCTAssertEqual(selected(plan, in: text), ["    a\n    b\n"])
    }

    func testOverlappingAndAdjacentRangesIndentEachLineOnce() {
        let text = "a\nb\nc\nd"
        let ranges = [
            NSRange(location: 0, length: 3), // a, b
            NSRange(location: 2, length: 3), // b, c — overlaps
            NSRange(location: 6, length: 1), // d — adjacent line
        ]
        let plan = indent(text, ranges)
        XCTAssertEqual(apply(plan, to: text), "    a\n    b\n    c\n    d")
        XCTAssertEqual(plan.edits.count, 4)
        XCTAssertEqual(plan.selections.count, 3)
    }

    func testIndentingAnEmptyFileIsANoOp() {
        XCTAssertTrue(indent("", [NSRange(location: 0, length: 0)]).isEmpty)
    }

    func testIndentFirstAndLastLineWithoutATrailingNewline() {
        let text = "first\nlast"
        let plan = indent(text, [NSRange(location: 0, length: 10)])
        XCTAssertEqual(apply(plan, to: text), "    first\n    last")
        XCTAssertEqual(selected(plan, in: text), ["    first\n    last"])
    }

    func testIndentWithCRLFLeavesTheTerminatorsAlone() {
        let text = "a\r\nb\r\nc"
        let plan = indent(text, [NSRange(location: 0, length: 6)])
        XCTAssertEqual(apply(plan, to: text), "    a\r\n    b\r\nc")
    }

    func testIndentAndOutdentUnderEachSeparator() {
        for separator in ["\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"] {
            let text = ["a", "b", "c"].joined(separator: separator)
            let whole = NSRange(location: 0, length: (text as NSString).length)
            let plan = indent(text, [whole], unit: "  ")
            let expected = ["  a", "  b", "  c"].joined(separator: separator)
            XCTAssertEqual(apply(plan, to: text), expected, separator.debugDescription)

            let back = outdent(expected, plan.selections, unit: "  ")
            XCTAssertEqual(apply(back, to: expected), text, separator.debugDescription)
        }
    }

    func testTheOldTabReplacedTheBlockAndIndentDoesNot() {
        // Regression: Tab on a multi-line selection used to replace it with one
        // unit. The block path must keep every character of the selection.
        let text = "let a = 1\nlet b = 2\n"
        let range = NSRange(location: 0, length: (text as NSString).length)
        let old = IndentUnitRule.tabInsertionPlan(ranges: [range], insertion: "    ")
        let replaced = NSMutableString(string: text)
        for edit in old.replacements.reversed() {
            replaced.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        XCTAssertEqual(replaced as String, "    ", "the stock plan replaces — which is why the block path exists")

        XCTAssertTrue(BlockIndentEngine.isBlockSelection(text: text as NSString, ranges: [range]))
        let indented = apply(indent(text, [range]), to: text)
        XCTAssertEqual(indented, "    let a = 1\n    let b = 2\n")
        XCTAssertNotEqual(indented, replaced as String)
    }

    // MARK: - Outdent

    func testOutdentRemovesOneUnitOfSpaces() {
        let text = "        deep\n    shallow"
        let plan = outdent(text, [NSRange(location: 0, length: 23)])
        XCTAssertEqual(apply(plan, to: text), "    deep\nshallow")
    }

    func testOutdentRemovesALeadingTabWhateverTheUnit() {
        let text = "\t\tx\n\ty"
        let plan = outdent(text, [NSRange(location: 0, length: 6)], unit: "  ")
        XCTAssertEqual(apply(plan, to: text), "\tx\ny")
    }

    func testOutdentWithATabUnitRemovesUpToFourSpaces() {
        let text = "      x"
        let plan = outdent(text, [NSRange(location: 6, length: 0)], unit: "\t")
        XCTAssertEqual(apply(plan, to: text), "  x")
    }

    func testOutdentOfMixedIndentationRemovesOnlyTheLeadingSpaceRun() {
        let text = "  \tx"
        let plan = outdent(text, [NSRange(location: 4, length: 0)])
        XCTAssertEqual(apply(plan, to: text), "\tx")
    }

    func testOutdentOfAShortRunRemovesWhatExists() {
        let text = "  a\n b\nc"
        let plan = outdent(text, [NSRange(location: 0, length: 8)])
        XCTAssertEqual(apply(plan, to: text), "a\nb\nc")
    }

    func testACaretOutdentsItsLineAndShiftsLeft() {
        let text = "x\n    let y\nz"
        let plan = outdent(text, [NSRange(location: 8, length: 0)]) // after "let"
        XCTAssertEqual(apply(plan, to: text), "x\nlet y\nz")
        XCTAssertEqual(plan.selections, [NSRange(location: 4, length: 0)])
    }

    func testACaretInsideTheRemovedIndentationClampsToTheLineStart() {
        let text = "x\n    y"
        let plan = outdent(text, [NSRange(location: 4, length: 0)])
        XCTAssertEqual(apply(plan, to: text), "x\ny")
        XCTAssertEqual(plan.selections, [NSRange(location: 2, length: 0)])
    }

    func testOutdentWithNothingToRemoveAnswersAnEmptyPlan() {
        XCTAssertTrue(outdent("a\nb", [NSRange(location: 0, length: 3)]).isEmpty)
        XCTAssertTrue(outdent("", [NSRange(location: 0, length: 0)]).isEmpty)
        XCTAssertTrue(outdent("\n\n", [NSRange(location: 0, length: 2)]).isEmpty)
    }

    func testOutdentAcrossSeveralCaretsOnOneLineEditsItOnce() {
        let text = "    ab"
        let plan = outdent(text, [NSRange(location: 4, length: 0), NSRange(location: 5, length: 0)])
        XCTAssertEqual(apply(plan, to: text), "ab")
        XCTAssertEqual(plan.edits.count, 1)
        XCTAssertEqual(plan.selections, [NSRange(location: 0, length: 0), NSRange(location: 1, length: 0)])
    }

    func testOutdentLastLineWithoutATrailingNewlineAndCRLF() {
        let text = "    a\r\n    b"
        let plan = outdent(text, [NSRange(location: 0, length: 12)])
        XCTAssertEqual(apply(plan, to: text), "a\r\nb")
        XCTAssertEqual(selected(plan, in: text), ["a\r\nb"])
    }

    func testOutOfBoundsRangesAreClamped() {
        let text = "    a"
        let plan = outdent(text, [NSRange(location: 99, length: 5)])
        XCTAssertEqual(apply(plan, to: text), "a")
        XCTAssertEqual(plan.selections, [NSRange(location: 1, length: 0)])
    }
}
