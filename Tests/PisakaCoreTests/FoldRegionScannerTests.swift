import XCTest
@testable import PisakaCore

/// The fallback fold scanner and the value it answers.
///
/// Every expectation is written as "the block headed by line H ends on line L",
/// resolved to offsets through `TerminatedLines` — the same splitter the scanner
/// itself is built on, so the assertions stay readable when a fixture grows a
/// character. The nested-bracket case additionally pins the raw offsets by hand,
/// which is what keeps the helper honest.
final class FoldRegionScannerTests: XCTestCase {

    // MARK: - Helpers

    private func scan(_ text: String, unit: Int = 4, tab: Int = 4) -> [FoldRegion] {
        FoldRegionScanner.scan(
            text: text as NSString,
            widths: IndentLevelWidths(unitWidth: unit, tabWidth: tab)
        )
    }

    /// The region hiding everything from the end of line `header`'s content to
    /// the end of line `last`'s content.
    private func region(_ header: Int, _ last: Int, in text: String) -> FoldRegion {
        let lines = TerminatedLines.ranges(text)
        let start = NSMaxRange(lines[header].content)
        let end = NSMaxRange(lines[last].content)
        return FoldRegion(
            hiddenRange: NSRange(location: start, length: end - start),
            headerLine: header,
            kind: nil
        )!
    }

    // MARK: - The value

    func testAnEmptyHiddenRangeIsNotRepresentable() {
        XCTAssertNil(FoldRegion(hiddenRange: NSRange(location: 4, length: 0), headerLine: 0))
    }

    func testNegativeInputsAreRefused() {
        XCTAssertNil(FoldRegion(hiddenRange: NSRange(location: -1, length: 3), headerLine: 0))
        XCTAssertNil(FoldRegion(hiddenRange: NSRange(location: 0, length: 3), headerLine: -1))
    }

    /// The ordering key: header line ascending, then the longer region first.
    func testOrderingKeyIsHeaderLineThenLongerFirst() {
        let early = FoldRegion(hiddenRange: NSRange(location: 10, length: 2), headerLine: 1)!
        let lateShort = FoldRegion(hiddenRange: NSRange(location: 20, length: 2), headerLine: 2)!
        let lateLong = FoldRegion(hiddenRange: NSRange(location: 20, length: 9), headerLine: 2)!
        XCTAssertEqual([lateShort, lateLong, early].sorted(), [early, lateLong, lateShort])
    }

    func testKindIsAbsentByDefaultAndCarriedWhenNamed() {
        let plain = FoldRegion(hiddenRange: NSRange(location: 0, length: 1), headerLine: 0)
        XCTAssertNil(plain?.kind)
        let named = FoldRegion(hiddenRange: NSRange(location: 0, length: 1), headerLine: 0, kind: .imports)
        XCTAssertEqual(named?.kind, .imports)
    }

    // MARK: - Degenerate texts

    func testEmptyTextHasNoRegions() {
        XCTAssertEqual(scan(""), [])
    }

    func testASingleLineHasNoRegions() {
        XCTAssertEqual(scan("{ a }"), [])
        XCTAssertEqual(scan("    indented, but alone"), [])
    }

    // MARK: - Brackets

    /// The offsets, by hand: `{\n{\n}\n}` hides 1..<7 for the outer pair and
    /// 3..<5 for the inner one. The header line keeps its brace; the closer's
    /// line joins it.
    func testNestedBracketsAnswerBothPairs() {
        let text = "{\n{\n}\n}"
        XCTAssertEqual(
            scan(text),
            [
                FoldRegion(hiddenRange: NSRange(location: 1, length: 6), headerLine: 0)!,
                FoldRegion(hiddenRange: NSRange(location: 3, length: 2), headerLine: 1)!,
            ]
        )
        // …and the helper agrees with the hand-written offsets.
        XCTAssertEqual(scan(text), [region(0, 3, in: text), region(1, 2, in: text)])
    }

    func testASingleLinePairYieldsNothing() {
        XCTAssertEqual(scan("call({ a: 1 })\nnext()"), [])
    }

    /// The hidden range runs to the end of the closer's *line*, not to the
    /// closer, so whatever trails the closer folds away with it.
    func testTheHiddenRangeReachesTheEndOfTheClosersLine() {
        let text = "call({\n  a: 1\n}, other)\n"
        XCTAssertEqual(scan(text), [region(0, 2, in: text)])
    }

    func testAnUnmatchedOpenerIsSkippedWhileMatchedPairsSurvive() {
        let text = "[\n(\n)"
        XCTAssertEqual(scan(text), [region(1, 2, in: text)])
    }

    func testAnUnmatchedOpenerAloneFoldsNothing() {
        XCTAssertEqual(scan("{\nalpha\n"), [])
    }

    /// Crossed brackets are every-bracket-unmatched to `BracketDepthScanner`,
    /// and this engine takes no second opinion on that pairing — so nothing is
    /// foldable here, and the indentation half has nothing deeper to offer.
    func testCrossedBracketsFoldNothing() {
        XCTAssertEqual(scan("{\n[\n(\n]\n}"), [])
    }

    // MARK: - Indentation

    func testASpaceIndentedBlock() {
        let text = "def f():\n    a\n    b\nc\n"
        XCTAssertEqual(scan(text), [region(0, 2, in: text)])
    }

    func testATabIndentedBlock() {
        let text = "if x:\n\ta\n\tb\ndone\n"
        XCTAssertEqual(scan(text), [region(0, 2, in: text)])
    }

    func testNestedIndentationAnswersBothBlocks() {
        let text = "a\n    b\n        c\n    d\ne\n"
        XCTAssertEqual(scan(text), [region(0, 3, in: text), region(1, 2, in: text)])
    }

    func testTwoLinesAtTheSameLevelAreNotABlock() {
        XCTAssertEqual(scan("a\nb\n"), [])
    }

    func testABlockRunningToTheEndOfTheTextIsStillABlock() {
        let text = "a\n    b\n"
        XCTAssertEqual(scan(text), [region(0, 1, in: text)])
    }

    /// A blank line inside the block belongs to it; the blank lines after it are
    /// trimmed, so the block ends on its last real line.
    func testBlankLinesInsideBelongAndTrailingBlanksAreTrimmed() {
        let text = "a\n    b\n\n    c\n\nd\n"
        XCTAssertEqual(scan(text), [region(0, 3, in: text)])
    }

    func testTrailingBlankLinesAtTheEndOfTheTextAreTrimmed() {
        let text = "a\n    b\n\n\n"
        XCTAssertEqual(scan(text), [region(0, 1, in: text)])
    }

    /// A whitespace-only line is blank too — it neither ends a block nor opens
    /// one, however deep its own whitespace happens to be.
    func testAWhitespaceOnlyLineIsBlank() {
        let text = "a\n    b\n            \n    c\nd\n"
        XCTAssertEqual(scan(text), [region(0, 3, in: text)])
    }

    /// Any deeper column opens a block, whatever the unit happens to be: two
    /// spaces are deeper than none at a unit of two and at a unit of eight
    /// alike.
    func testAnyDeeperColumnOpensABlock() {
        let text = "a\n  b\nc\n"
        XCTAssertEqual(scan(text, unit: 2, tab: 2), [region(0, 1, in: text)])
        XCTAssertEqual(scan(text, unit: 8, tab: 8), [region(0, 1, in: text)])
    }

    /// Nesting is read as a **column**, never as a level quantized by the unit:
    /// a two-space file keeps both of its blocks at a unit of four, where a
    /// level would have put the header and its child in the same bucket and lost
    /// the inner one. The unit belongs to what Enter appends; how deeply a file
    /// is nested is a fact about the file.
    func testNestingFinerThanTheUnitIsStillNested() {
        let text = "def a:\n  def b:\n    c\nd\n"
        let expected = [region(0, 2, in: text), region(1, 2, in: text)]
        XCTAssertEqual(scan(text, unit: 4, tab: 4), expected)
        XCTAssertEqual(scan(text, unit: 2, tab: 2), expected)
        XCTAssertEqual(scan(text, unit: 8, tab: 8), expected)
    }

    /// The tab stop is the one width the nesting does read: a tab and the spaces
    /// it expands to sit at the same column and so do not nest, while spaces
    /// past that stop do.
    func testTheTabStopDecidesWhereATabLands() {
        let text = "a\n\tb\n    c\n      d\ne\n"
        XCTAssertEqual(
            scan(text, unit: 4, tab: 4),
            [region(0, 3, in: text), region(2, 3, in: text)]
        )
    }

    /// Widths that cannot describe an indentation answer the bracket half alone
    /// — never a trap, never a loop.
    func testUnusableWidthsAnswerTheBracketHalfAlone() {
        let text = "{\n    a\n}\n"
        XCTAssertEqual(scan(text, unit: 0, tab: 0), [region(0, 2, in: text)])
    }

    // MARK: - The merge

    /// The two sources disagree about the end — indentation stops before the
    /// closing brace, the bracket pair includes it — and the bracket wins.
    func testBracketWinsAHeaderLineTheTwoSourcesDisagreeAbout() {
        let text = "foo {\n    a\n}\n"
        let regions = scan(text)
        XCTAssertEqual(regions, [region(0, 2, in: text)])
        XCTAssertNotEqual(regions, [region(0, 1, in: text)])
    }

    /// Two brackets opening on one line are one chevron: the longer wins.
    func testTwoBracketsOnOneHeaderLineMergeToTheLongerOne() {
        let text = "f(g(\n  x\n),\ny)\n"
        XCTAssertEqual(scan(text), [region(0, 3, in: text)])
    }

    // MARK: - Separators

    /// Lines come from `TerminatedLines`, so all six separators are handled by
    /// use rather than by a table of this engine's own — CRLF included, as one
    /// separator and not two.
    func testEverySeparatorSplitsLinesTheSameWay() {
        for separator in ["\n", "\r", "\r\n", "\u{0085}", "\u{2028}", "\u{2029}"] {
            let text = "{" + separator + "a" + separator + "}"
            XCTAssertEqual(scan(text), [region(0, 2, in: text)], "separator \(separator.unicodeScalars.map(\.value))")
        }
    }

    func testEverySeparatorSplitsIndentedLinesTheSameWay() {
        for separator in ["\n", "\r", "\r\n", "\u{0085}", "\u{2028}", "\u{2029}"] {
            let text = "a" + separator + "    b" + separator + "c"
            XCTAssertEqual(scan(text), [region(0, 1, in: text)], "separator \(separator.unicodeScalars.map(\.value))")
        }
    }
}
