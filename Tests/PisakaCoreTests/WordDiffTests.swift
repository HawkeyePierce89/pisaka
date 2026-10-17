import Foundation
@testable import PisakaCore
import XCTest

/// `WordDiff`: the tokenizer, the ranges on both sides, the 60% rewrite
/// threshold, and the two charged ceilings.
///
/// The budget tests assert the *work*, never a clock: a ceiling driven to
/// exhaustion **and** the cells the LCS really filled (`Work.performed`), booked
/// apart from the charge, so a deleted or undersized `spend` shows up as
/// performed work the ceiling never paid for.
final class WordDiffTests: XCTestCase {

    private func r(_ location: Int, _ length: Int) -> NSRange {
        NSRange(location: location, length: length)
    }

    // MARK: - Ranges

    func testOneChangedWordMarksBothSides() {
        let result = WordDiff.ranges(old: "let value = compute(x)", new: "let total = compute(x)")
        XCTAssertEqual(result, WordDiffRanges(old: [r(4, 5)], new: [r(4, 5)]))
    }

    func testPunctuationIsOneTokenPerCharacter() {
        let tokens = WordDiff.tokens("a+=b;")
        XCTAssertEqual(tokens.map(\.range), [r(0, 1), r(1, 1), r(2, 1), r(3, 1), r(4, 1)])
        // Only the changed operator character is marked, not the run.
        XCTAssertEqual(
            WordDiff.ranges(old: "a += b", new: "a -= b"),
            WordDiffRanges(old: [r(2, 1)], new: [r(2, 1)])
        )
    }

    func testWhitespaceRunsAreOneToken() {
        let tokens = WordDiff.tokens("a  \tb")
        XCTAssertEqual(tokens.map(\.range), [r(0, 1), r(1, 3), r(4, 1)])
        XCTAssertEqual(
            WordDiff.ranges(old: "foo bar baz", new: "foo   bar baz"),
            WordDiffRanges(old: [r(3, 1)], new: [r(3, 3)])
        )
    }

    func testNonASCIILettersAreWordCharacters() {
        let tokens = WordDiff.tokens("привет_мир1 x")
        XCTAssertEqual(tokens.map(\.range), [r(0, 11), r(11, 1), r(12, 1)])
        XCTAssertEqual(
            WordDiff.ranges(old: "значение = один", new: "значение = два"),
            WordDiffRanges(old: [r(11, 4)], new: [r(11, 3)])
        )
    }

    func testSurrogatePairsAreMeasuredInUTF16() {
        // 😀 is one scalar, two UTF-16 units, and a token of its own.
        XCTAssertEqual(WordDiff.tokens("😀ab").map(\.range), [r(0, 2), r(2, 2)])
        XCTAssertEqual(
            WordDiff.ranges(old: "😀 one two", new: "😀 one three"),
            WordDiffRanges(old: [r(7, 3)], new: [r(7, 5)])
        )
    }

    func testTokensCompareByUnitsNotCanonicalEquivalence() {
        let precomposed = "caf\u{00E9} and some more words"
        let decomposed = "cafe\u{0301} and some more words"
        XCTAssertEqual(
            WordDiff.ranges(old: precomposed, new: decomposed),
            WordDiffRanges(old: [r(0, 4)], new: [r(0, 5)])
        )
    }

    func testTouchingChangedTokensMergeIntoOneRange() {
        // "b.c" → "x-y": three tokens changed back to back, one range each side.
        XCTAssertEqual(
            WordDiff.ranges(old: "aaaa b.c dddd eeee ffff", new: "aaaa x-y dddd eeee ffff"),
            WordDiffRanges(old: [r(5, 3)], new: [r(5, 3)])
        )
    }

    func testSeparatedChangesStayApart() {
        XCTAssertEqual(
            WordDiff.ranges(old: "one two three four five", new: "uno two three four cinco"),
            WordDiffRanges(old: [r(0, 3), r(19, 4)], new: [r(0, 3), r(19, 5)])
        )
    }

    func testAnInsertionMarksTheNewSideAlone() {
        XCTAssertEqual(
            WordDiff.ranges(old: "call(a, b, c, d)", new: "call(a, b, x, c, d)"),
            WordDiffRanges(old: [], new: [r(11, 3)])
        )
    }

    func testIdenticalSidesHaveNoRanges() {
        XCTAssertEqual(WordDiff.ranges(old: "same line", new: "same line"), WordDiffRanges(old: [], new: []))
    }

    func testEmptySides() {
        XCTAssertEqual(WordDiff.ranges(old: "", new: ""), WordDiffRanges(old: [], new: []))
        // Everything on the new side changed: a rewrite.
        XCTAssertNil(WordDiff.ranges(old: "", new: "abc"))
        XCTAssertNil(WordDiff.ranges(old: "abc", new: ""))
        // Whitespace-only changes carry no non-whitespace share.
        XCTAssertEqual(WordDiff.ranges(old: "", new: "   "), WordDiffRanges(old: [], new: [r(0, 3)]))
    }

    // MARK: - Threshold

    /// 100 one-letter words; `changed` of them replaced, spread through the line
    /// so neither the prefix nor the suffix strip absorbs them.
    private func line(replacing changed: Int) -> (old: String, new: String) {
        let old = Array(repeating: "a", count: 100)
        var new = old
        for index in 0..<changed { new[1 + index] = "b" }
        return (old.joined(separator: " "), new.joined(separator: " "))
    }

    func testExactlySixtyPercentIsKept() {
        let pair = line(replacing: 60)
        let result = WordDiff.ranges(old: pair.old, new: pair.new)
        // The shared spaces between the replaced words keep each word its own range.
        XCTAssertEqual(result?.old.count, 60)
        XCTAssertEqual(result?.new.count, 60)
    }

    func testJustBelowSixtyPercentIsKept() {
        let pair = line(replacing: 59)
        XCTAssertNotNil(WordDiff.ranges(old: pair.old, new: pair.new))
    }

    func testJustAboveSixtyPercentIsARewrite() {
        let pair = line(replacing: 61)
        XCTAssertNil(WordDiff.ranges(old: pair.old, new: pair.new))
    }

    func testTheThresholdIsMeasuredOnTheLongerSide() {
        // The new side is longer by one unit, so it decides: two of its 34
        // non-whitespace units changed.
        let old = "aaaa bbbb cccc dddd eeee ffff gggg hhhh x"
        let new = "aaaa bbbb cccc dddd eeee ffff gggg hhhh yy"
        XCTAssertEqual(WordDiff.ranges(old: old, new: new), WordDiffRanges(old: [r(40, 1)], new: [r(40, 2)]))
        // A short line growing into a long one is judged on the long one.
        XCTAssertNil(WordDiff.ranges(old: "x", new: "x and a great deal of new text"))
    }

    // MARK: - Budget

    /// A minified line, ~20k UTF-16 units and ~10k tokens, and a near-copy whose
    /// first and last tokens differ — so the strips leave the whole line in the
    /// middle and the LCS would be ~10^8 cells.
    private func minifiedPair() -> (old: String, new: String) {
        let body = (0..<2_500).map { "v\($0)=\($0);" }.joined()
        return ("w" + body + "!", "q" + body + "?")
    }

    func testAMinifiedLineExhaustsThePerRowCeiling() {
        let pair = minifiedPair()
        XCTAssertGreaterThan(pair.old.utf16.count, 20_000)
        var work = WordDiff.Work(budget: WordDiff.maximumRowCells)
        XCTAssertNil(WordDiff.ranges(old: pair.old, new: pair.new, rowWork: &work))
        XCTAssertLessThanOrEqual(work.budget, 0)
        // Cells filled are booked apart from the charge: never more than was
        // charged, and the bulk of the ceiling really was worked through.
        XCTAssertGreaterThan(work.performed, 0)
        XCTAssertLessThanOrEqual(work.performed, work.charged)
        XCTAssertGreaterThanOrEqual(work.performed, WordDiff.maximumRowCells / 2)
    }

    func testThePerBuildCeilingStopsLaterRows() {
        let pair = minifiedPair()
        let small = (old: "let a = b + c", new: "let a = b - c")
        XCTAssertNotNil(WordDiff.ranges(old: small.old, new: small.new))

        var build = WordDiff.Work(budget: WordDiff.maximumBuildCells)
        var rows = 0
        while !build.isExhausted {
            XCTAssertNil(WordDiff.ranges(old: pair.old, new: pair.new, work: &build))
            rows += 1
            if rows > 100 { return XCTFail("the per-build ceiling never ran out") }
        }
        // Each pathological row is held to its own ceiling, so the build takes
        // several of them to spend.
        XCTAssertGreaterThanOrEqual(rows, WordDiff.maximumBuildCells / (WordDiff.maximumRowCells + 20_000))
        XCTAssertGreaterThan(build.performed, 0)
        XCTAssertLessThanOrEqual(build.performed, build.charged)
        // The same cheap row that answered on its own now gets nothing.
        XCTAssertNil(WordDiff.ranges(old: small.old, new: small.new, work: &build))
    }

    func testAnOrdinaryRowFitsTheCeiling() {
        let old = String(repeating: "token ", count: 200) + "end"
        let new = String(repeating: "token ", count: 200) + "finish"
        var work = WordDiff.Work(budget: WordDiff.maximumRowCells)
        XCTAssertEqual(
            WordDiff.ranges(old: old, new: new, rowWork: &work),
            WordDiffRanges(old: [r(1_200, 3)], new: [r(1_200, 6)])
        )
        XCTAssertGreaterThan(work.budget, 0)
    }

    func testTheCeilingsAreTheStatedConstants() {
        XCTAssertEqual(WordDiff.maximumRowCells, 250_000)
        XCTAssertEqual(WordDiff.maximumBuildCells, 4_000_000)
    }
}
