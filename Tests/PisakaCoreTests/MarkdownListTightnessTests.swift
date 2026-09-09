import XCTest
@testable import PisakaCore

/// The tight/loose rule, read off line spans alone.
///
/// The engine is deliberately blind to what a block *is* — it sees only where
/// each one starts and ends — so every case here is stated as spans rather than
/// as Markdown. The other half of the property, that the spans a real document
/// produces are the ones this rule expects, is `MarkdownParserTests`': it parses
/// the source and checks the answer end to end, against the same cases cmark's
/// own `list_tight` flag gives.
final class MarkdownListTightnessTests: XCTestCase {

    private func isTight(_ spans: [[ClosedRange<Int>]], blank: Set<Int> = []) -> Bool {
        MarkdownListTightness.isTight(itemSpans: spans, blankLines: blank)
    }

    // MARK: - The two halves of CommonMark's sentence

    /// Items on consecutive lines: nothing between them, so tight.
    func testItemsOnConsecutiveLinesAreTight() {
        XCTAssertTrue(isTight([[1...1], [2...2], [3...3]]))
    }

    /// One blank line between two items is enough.
    func testABlankLineBetweenAnyTwoItemsIsLoose() {
        XCTAssertFalse(isTight([[1...1], [3...3]], blank: [2]))
        // The gap need not be at the front: a list that starts tight and grows a
        // blank line three items in is loose as a whole.
        XCTAssertFalse(isTight([[1...1], [2...2], [4...4]], blank: [3]))
    }

    /// The second half: a blank line *inside* one item, between two of its own
    /// blocks.
    func testABlankLineInsideOneItemIsLoose() {
        XCTAssertFalse(isTight([[1...1, 3...3], [4...4]], blank: [2]))
    }

    /// A multi-line block is one span, so its own lines are not a separation: an
    /// item holding a fenced block that runs from line 2 to line 4 is still
    /// adjacent to the item starting on line 5, blank lines inside the fence and
    /// all.
    func testAMultiLineBlockIsNotAGap() {
        XCTAssertTrue(isTight([[1...1, 2...4], [5...5]], blank: [3]))
    }

    /// Adjacency is the first half of the question: spans one line apart enclose
    /// no line at all, so nothing the source says about those lines matters.
    func testAdjacentSpansEncloseNothingAndAreAlwaysTight() {
        XCTAssertTrue(isTight([[1...1], [2...2]], blank: [1, 2]))
        XCTAssertTrue(isTight([[1...2], [3...3]], blank: [2, 3]))
    }

    /// Several blank lines are no different from one — CommonMark's rule is
    /// "separated by blank lines", not "by how many".
    func testMoreThanOneBlankLineIsStillJustLoose() {
        XCTAssertFalse(isTight([[1...1], [5...5]], blank: [2, 3, 4]))
    }

    // MARK: - A gap is not evidence; a blank line is

    /// The rule's second half: a gap whose every line carries something is no
    /// separation at all. This is the shape a **link reference definition**
    /// writes — a line of content that leaves no node behind, so the blocks
    /// around it sit two apart with nothing blank between them, and cmark reads
    /// the list as tight.
    func testAGapOfNonBlankLinesIsTight() {
        XCTAssertTrue(isTight([[1...2, 4...4], [5...5]]))
        XCTAssertTrue(isTight([[1...1], [4...4]]))
    }

    /// One blank line anywhere inside the gap is enough, wherever in it it sits.
    func testOneBlankLineAnywhereInsideTheGapIsEnough() {
        XCTAssertFalse(isTight([[1...1], [5...5]], blank: [2]))
        XCTAssertFalse(isTight([[1...1], [5...5]], blank: [3]))
        XCTAssertFalse(isTight([[1...1], [5...5]], blank: [4]))
    }

    /// Only the lines *strictly* inside the gap are read: a span's own first and
    /// last lines belong to a block, whatever the source's blank-line reading
    /// says about them (an indented code block's last line can be one).
    func testTheSpansOwnLinesAreNotReadAsSeparators() {
        XCTAssertTrue(isTight([[1...3], [4...6]], blank: [3, 4]))
        XCTAssertFalse(isTight([[1...3], [5...6]], blank: [3, 4, 5]))
    }

    // MARK: - Degenerate input

    /// Nothing to compare is tight, which is also what every renderer draws.
    func testTooLittleToCompareIsTight() {
        XCTAssertTrue(isTight([]))
        XCTAssertTrue(isTight([[]]))
        XCTAssertTrue(isTight([[1...1]]))
    }

    /// An item that reports no span at all — nothing the caller could read a
    /// line from — drops out of the comparison rather than joining its
    /// neighbours' spans into one.
    func testAnItemWithNoSpansIsSkipped() {
        XCTAssertTrue(isTight([[1...1], [], [2...2]]))
        XCTAssertFalse(isTight([[1...1], [], [3...3]], blank: [2]))
    }

    /// The degenerate span an empty item reports — a single line — separates its
    /// neighbours like any other, which is the whole reason the caller invents
    /// it: without it `- a`/`-`/`- b` would compare line 1 against line 3, and a
    /// source that wrote line 2 blank two items further down would read loose.
    func testAnEmptyItemsOwnLineSeparatesItsNeighbours() {
        XCTAssertTrue(isTight([[1...1], [2...2], [3...3]]))
        XCTAssertFalse(isTight([[1...1], [3...3], [5...5]], blank: [2, 4]))
    }

    /// Spans are read in the order given and compared only to their immediate
    /// predecessor: a later item starting *above* an earlier one is impossible
    /// in a parsed document, and the rule does not go looking for it.
    func testComparisonIsAgainstTheImmediatePredecessorOnly() {
        // 1…9 then 10 — adjacent to the *end* of the long span, not its start.
        XCTAssertTrue(isTight([[1...9], [10...10]], blank: [2, 3]))
    }

    // MARK: - Blank lines

    private func blankLines(_ source: String) -> Set<Int> {
        MarkdownListTightness.blankLines(in: source)
    }

    func testABlankLineIsOneHoldingWhitespaceOrBlockQuoteMarkersOnly() {
        XCTAssertEqual(blankLines("a\n\nb\n"), [2, 4])
        XCTAssertEqual(blankLines("a\n   \t \nb\n"), [2, 4])
        // The line a blank line inside a block quote is actually written as.
        XCTAssertEqual(blankLines("> a\n>\n> b\n"), [2, 4])
        XCTAssertEqual(blankLines("> a\n> \n> b\n"), [2, 4])
        XCTAssertEqual(blankLines(">> a\n>>\n>> b\n"), [2, 4])
        XCTAssertEqual(blankLines("a\n> b\nc\n"), [4])
    }

    /// The separators are cmark's three and not the editor's set: a `NEL`, a
    /// `LS` or a `PS` is text to cmark, so counting one as a break would shift
    /// every line number below it away from the ones on the tree.
    func testTheSeparatorsAreTheOnesCmarkCounts() {
        XCTAssertEqual(blankLines("a\r\n\r\nb\r\n"), [2, 4])
        XCTAssertEqual(blankLines("a\r\rb\r"), [2, 4])
        XCTAssertEqual(blankLines("a\u{2028}\u{2028}b"), [])
        XCTAssertEqual(blankLines("a\u{85}\n\nb\n"), [2, 4])
    }

    func testTheLineAfterATrailingSeparatorIsBlankAndAnEmptySourceIsOneBlankLine() {
        XCTAssertEqual(blankLines(""), [1])
        XCTAssertEqual(blankLines("a"), [])
        XCTAssertEqual(blankLines("a\n"), [2])
    }

    // MARK: - A code block's content span

    private func codeSpan(_ range: ClosedRange<Int>,
                          _ code: String,
                          _ blanks: Set<Int>) -> ClosedRange<Int> {
        MarkdownListTightness.codeBlockContentSpan(range: range, code: code, blankLines: blanks)
    }

    /// A closed fence keeps its whole range: its last line is the closing fence,
    /// which is not blank, so the walk stops before it drops anything.
    func testAFencedBlockKeepsItsFences() {
        XCTAssertEqual(codeSpan(1...3, "x\n", []), 1...3)
        // …including one whose own content ends in blank lines, where the
        // ceiling has room to drop two and the fence still refuses the first.
        XCTAssertEqual(codeSpan(1...5, "x\n\n\n", [3, 4]), 1...5)
    }

    /// An indented block loses the blank lines cmark closed it past, which is
    /// the whole point: what is left is the line its content really ended on.
    func testAnIndentedBlockLosesTheBlankLinesThatEndedIt() {
        XCTAssertEqual(codeSpan(1...2, "code\n", [2]), 1...1)
        XCTAssertEqual(codeSpan(1...4, "code\n", [2, 3, 4]), 1...1)
        XCTAssertEqual(codeSpan(1...1, "code\n", []), 1...1)
        // Two content lines, one blank line past them.
        XCTAssertEqual(codeSpan(1...3, "a\nb\n", [3]), 1...2)
    }

    /// The ceiling is what keeps a blank-looking *content* line: an indented
    /// block whose last line is `>` occupies as many lines as its code does, so
    /// nothing may be dropped even though that line reads blank.
    func testNoMoreLinesAreDroppedThanTheRangeHoldsBeyondTheCode() {
        XCTAssertEqual(codeSpan(1...2, "a\n>\n", [2]), 1...2)
        XCTAssertEqual(codeSpan(1...3, "a\n>\n", [2, 3]), 1...2)
    }

    /// The first line is never dropped, however blank the source reads there.
    func testTheFirstLineSurvives() {
        XCTAssertEqual(codeSpan(1...1, "", [1]), 1...1)
        XCTAssertEqual(codeSpan(4...4, "", [4]), 4...4)
    }

    /// An unclosed fence at end of file ends on a line with no separator, which
    /// is still a line the code occupies.
    func testUnterminatedCodeStillOccupiesItsLastLine() {
        XCTAssertEqual(codeSpan(1...2, "x", []), 1...2)
        XCTAssertEqual(codeSpan(1...3, "x\ny", [3]), 1...2)
    }
}
