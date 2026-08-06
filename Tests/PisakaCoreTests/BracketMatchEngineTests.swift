import XCTest
@testable import PisakaCore

final class BracketMatchEngineTests: XCTestCase {
    private func pair(_ s: String, caret: Int, length: Int = 0) -> BracketPair? {
        BracketMatchEngine.pair(
            text: s as NSString,
            selectedRange: NSRange(location: caret, length: length)
        )
    }

    private func expected(open: Int, close: Int) -> BracketPair {
        BracketPair(
            open: NSRange(location: open, length: 1),
            close: NSRange(location: close, length: 1)
        )
    }

    // MARK: - The caret adjacent to one bracket

    func testCaretBeforeOpener() {
        // "|(a)" — the character after the caret is the opener.
        XCTAssertEqual(pair("(a)", caret: 0), expected(open: 0, close: 2))
        XCTAssertEqual(pair("[a]", caret: 0), expected(open: 0, close: 2))
        XCTAssertEqual(pair("{a}", caret: 0), expected(open: 0, close: 2))
    }

    func testCaretAfterOpener() {
        // "(|a)" — nothing bracket-ish after the caret, the opener sits before it.
        XCTAssertEqual(pair("(a)", caret: 1), expected(open: 0, close: 2))
        XCTAssertEqual(pair("[a]", caret: 1), expected(open: 0, close: 2))
        XCTAssertEqual(pair("{a}", caret: 1), expected(open: 0, close: 2))
    }

    func testCaretBeforeCloser() {
        // "(a|)" — the character after the caret is the closer; scan backward.
        XCTAssertEqual(pair("(a)", caret: 2), expected(open: 0, close: 2))
        XCTAssertEqual(pair("[a]", caret: 2), expected(open: 0, close: 2))
        XCTAssertEqual(pair("{a}", caret: 2), expected(open: 0, close: 2))
    }

    func testCaretAfterCloser() {
        // "(a)|" — end of buffer after the caret, the closer sits before it.
        XCTAssertEqual(pair("(a)", caret: 3), expected(open: 0, close: 2))
        XCTAssertEqual(pair("[a]", caret: 3), expected(open: 0, close: 2))
        XCTAssertEqual(pair("{a}", caret: 3), expected(open: 0, close: 2))
    }

    // MARK: - Brackets on both sides: the character *after* the caret wins

    func testBracketsOnBothSidesPrefersTheOneAfterTheCaret() {
        // "()|[]" — before: ')' of the first pair, after: '[' of the second.
        // VS Code order picks the character after the caret.
        XCTAssertEqual(pair("()[]", caret: 2), expected(open: 2, close: 3))
    }

    func testAdjacentClosingAndOpeningInsideNesting() {
        // "{()|()}" — again the opener after the caret wins over the closer before it.
        XCTAssertEqual(pair("{()()}", caret: 3), expected(open: 3, close: 4))
    }

    // MARK: - Nesting of the same kind

    func testSameKindNestingFromOuterBracket() {
        // "{a{b}c}" — 0:{ 1:a 2:{ 3:b 4:} 5:c 6:}
        XCTAssertEqual(pair("{a{b}c}", caret: 0), expected(open: 0, close: 6))
        XCTAssertEqual(pair("{a{b}c}", caret: 7), expected(open: 0, close: 6))
    }

    func testSameKindNestingFromInnerBracket() {
        XCTAssertEqual(pair("{a{b}c}", caret: 2), expected(open: 2, close: 4))
        XCTAssertEqual(pair("{a{b}c}", caret: 4), expected(open: 2, close: 4))
    }

    func testDeeperNestingBackwardScanCountsDepth() {
        // "((()))" — the caret before the last closer matches the outermost opener.
        XCTAssertEqual(pair("((()))", caret: 5), expected(open: 0, close: 5))
        XCTAssertEqual(pair("((()))", caret: 4), expected(open: 1, close: 4))
    }

    // MARK: - Mixed kinds

    func testMixedKindsDoNotConfuseTheScan() {
        // "{[a(b]}" — the '(' at 3 has no ')' anywhere, and neither neighbor of
        // the caret is another bracket, so there is nothing to highlight. A
        // kind-blind scan would happily pair that '(' with the ']'.
        XCTAssertNil(pair("{[a(b]}", caret: 3))
    }

    func testUnmatchedBracketAfterTheCaretFallsBackToTheOneBeforeIt() {
        // "{[(]}" — 0:{ 1:[ 2:( 3:] 4:}
        // The caret at 2 has the unmatched '(' after it and the '[' before it;
        // "after first, then before" means the '[' pair is shown rather than
        // nothing.
        XCTAssertEqual(pair("{[(]}", caret: 2), expected(open: 1, close: 3))
    }

    func testUnrelatedKindsAreSkippedWhileScanning() {
        // "[a(b)c]" — the '(' pair in the middle is irrelevant to the '[' pair.
        XCTAssertEqual(pair("[a(b)c]", caret: 0), expected(open: 0, close: 6))
    }

    /// The two Core bracket engines answer *different* questions and therefore
    /// count depth differently, which shows up on crossed (broken) input.
    ///
    /// `BracketMatchEngine` counts *its own kind only* (the
    /// `IndentEngine.dedentOnClosing` rule), so in `{[(]}` the `[` at 1 pairs with
    /// the `]` at 3 — ignoring the unrelated `(` between them.
    /// `BracketDepthScanner` keeps *one shared stack across all kinds* (JetBrains
    /// rainbow semantics), so it sees `]` arrive with `(` on top of the stack,
    /// reports it unmatched, and leaves every other bracket of `{[(]}` unmatched
    /// too — its mirror test is `testCrossedBracketsAllUnmatchedUnlikeMatchEngine`.
    ///
    /// The disagreement is intended: the caret at `[` can show a highlighted pair
    /// whose brackets are painted red. Neither answer is wrong for its own
    /// question, and the input is broken code mid-typing.
    func testCrossedBracketsPairPerKindUnlikeDepthScanner() {
        XCTAssertEqual(pair("{[(]}", caret: 1), expected(open: 1, close: 3))
        // Same story for the outer kind: '{' and '}' nest correctly once the
        // other kinds are ignored, while the scanner marks both unmatched.
        XCTAssertEqual(pair("{[(]}", caret: 4), expected(open: 0, close: 4))
    }

    // MARK: - No pair

    func testUnbalancedBufferYieldsNil() {
        XCTAssertNil(pair("(", caret: 0))
        XCTAssertNil(pair(")", caret: 1))
        XCTAssertNil(pair("((a)", caret: 0))
        XCTAssertNil(pair("(a))", caret: 4))
    }

    func testNoBracketAdjacentToTheCaretYieldsNil() {
        XCTAssertNil(pair("abc", caret: 1))
        XCTAssertNil(pair("(abc)", caret: 3))
    }

    func testEmptyBufferYieldsNil() {
        XCTAssertNil(pair("", caret: 0))
    }

    // MARK: - Selection and degenerate ranges

    func testNonEmptySelectionYieldsNil() {
        // Highlighting a pair is a caret affordance; a selection replaces it.
        XCTAssertNil(pair("(a)", caret: 0, length: 1))
        XCTAssertNil(pair("(a)", caret: 0, length: 3))
        XCTAssertNil(pair("(a)", caret: 2, length: 1))
    }

    func testOutOfBoundsLocationYieldsNilWithoutTrapping() {
        XCTAssertNil(pair("(a)", caret: NSNotFound))
        XCTAssertNil(pair("(a)", caret: Int.max))
        XCTAssertNil(pair("(a)", caret: -1))
        XCTAssertNil(pair("(a)", caret: Int.min))
        XCTAssertNil(pair("(a)", caret: 4))
        XCTAssertNil(pair("", caret: 1))
    }

    func testDegenerateLengthYieldsNilWithoutTrapping() {
        XCTAssertNil(pair("(a)", caret: 0, length: -1))
        XCTAssertNil(pair("(a)", caret: 0, length: Int.max))
    }

    // MARK: - Surrogate pairs

    func testBracketAfterSurrogatePairIsReadCorrectly() {
        // "😀(a)" — the emoji is two UTF-16 units, so '(' sits at index 2.
        XCTAssertEqual(pair("\u{1F600}(a)", caret: 2), expected(open: 2, close: 4))
        XCTAssertEqual(pair("\u{1F600}(a)", caret: 5), expected(open: 2, close: 4))
    }

    func testSurrogateHalvesInsideTheScanAreNotMistakenForBrackets() {
        // "(😀)" — the scan walks over both surrogate halves and still finds ')'.
        XCTAssertEqual(pair("(\u{1F600})", caret: 0), expected(open: 0, close: 3))
        XCTAssertEqual(pair("(\u{1F600})", caret: 3), expected(open: 0, close: 3))
    }

    // MARK: - Quotes and angle brackets are not pairs

    func testQuotesAreNeverMatched() {
        // A quote is its own closer, so "which one closes this one" has no answer
        // without a lexer — the tables deliberately exclude them (unlike
        // `AutoPairEngine`, which *does* auto-close quotes).
        for quote in ["\"", "'", "`"] {
            let text = "\(quote)a\(quote)"
            for caret in 0...(text as NSString).length {
                XCTAssertNil(pair(text, caret: caret), "\(quote) at caret \(caret)")
            }
        }
    }

    func testAngleBracketsAreNeverMatched() {
        // `<`/`>` are comparison operators far more often than brackets, so they
        // are not in the tables.
        XCTAssertNil(pair("<a>", caret: 0))
        XCTAssertNil(pair("<a>", caret: 3))
    }

    // MARK: - Chunked outward scan

    func testMatchFarBeyondOneChunkIsFound() {
        // The outward scans read in 4096-unit chunks; a pair whose halves sit many
        // chunks apart must still match, and the seam must not shift the offsets.
        let filler = String(repeating: "a", count: 10_000)
        let text = "(" + filler + ")"
        let closeIndex = (text as NSString).length - 1
        XCTAssertEqual(pair(text, caret: 0), expected(open: 0, close: closeIndex))
        XCTAssertEqual(pair(text, caret: closeIndex + 1), expected(open: 0, close: closeIndex))
    }

    func testNestingSpanningChunksCountsDepthAcrossTheSeam() {
        // The depth counter carries across chunk boundaries: the inner pair opens
        // in one chunk and closes in another, so the outer bracket must skip it.
        let filler = String(repeating: "a", count: 5_000)
        let text = "(" + filler + "(" + filler + ")" + filler + ")"
        let closeIndex = (text as NSString).length - 1
        XCTAssertEqual(pair(text, caret: 0), expected(open: 0, close: closeIndex))
        XCTAssertEqual(pair(text, caret: closeIndex + 1), expected(open: 0, close: closeIndex))
    }

    func testUnmatchedBracketFarFromTheCaretYieldsNilAfterScanningTheWholeBuffer() {
        // The mid-typing case the chunked read exists for: an unmatched opener next
        // to the caret sends the scan to the end of the buffer.
        let text = "(" + String(repeating: "a", count: 10_000)
        XCTAssertNil(pair(text, caret: 0))
        XCTAssertNil(pair(text, caret: 1))

        let backward = String(repeating: "a", count: 10_000) + ")"
        let closerIndex = (backward as NSString).length - 1
        XCTAssertNil(pair(backward, caret: closerIndex))
    }
}
