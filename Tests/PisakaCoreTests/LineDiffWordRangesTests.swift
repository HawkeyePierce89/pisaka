import XCTest
@testable import PisakaCore

/// `DiffRow.words` as `LineDiff.rows(old:new:)` fills it: on `.modified` rows
/// only, after pairing, and equal to what `WordDiff` answers for the pair.
final class LineDiffWordRangesTests: XCTestCase {

    func testModifiedRowCarriesTheWordRanges() {
        let rows = LineDiff.rows(old: "let a = 1\nkeep\n", new: "let b = 1\nkeep\n")
        XCTAssertEqual(rows.map(\.kind), [.modified, .unchanged])
        XCTAssertEqual(
            rows[0].words,
            WordDiffRanges(old: [NSRange(location: 4, length: 1)], new: [NSRange(location: 4, length: 1)])
        )
        XCTAssertEqual(rows[0].words, WordDiff.ranges(old: "let a = 1", new: "let b = 1"))
    }

    func testUnchangedAddedAndRemovedRowsNeverCarryRanges() {
        let rows = LineDiff.rows(old: "same\ngone\nsame2\n", new: "same\nsame2\nnew one\n")
        XCTAssertEqual(Set(rows.map(\.kind)), [.unchanged, .removed, .added])
        XCTAssertTrue(rows.allSatisfy { $0.words == nil })
    }

    func testRewrittenLineCarriesNone() {
        let rows = LineDiff.rows(old: "alpha beta gamma\n", new: "completely other text\n")
        XCTAssertEqual(rows.map(\.kind), [.modified])
        XCTAssertNil(rows[0].words)
    }

    func testPairingIsTheSameWithAndWithoutTheWordPass() {
        let old = "a\nlet value = one\nc\nd\n"
        let new = "a\nlet value = two\nx\ny\nz\nd\n"
        let withWords = LineDiff.rows(old: old, new: new)
        let without = LineDiff.rows(old: old, new: new, wordRanges: false)
        XCTAssertEqual(withWords.map(\.kind), without.map(\.kind))
        XCTAssertEqual(withWords.map(\.left), without.map(\.left))
        XCTAssertEqual(withWords.map(\.right), without.map(\.right))
        XCTAssertTrue(without.allSatisfy { $0.words == nil })
        XCTAssertNotNil(withWords[1].words)
    }

    func testOneBuildSharesOneCeiling() {
        // The two ends differ, so nothing strips and each row pays the full
        // ~300 × 300-token LCS: within the per-row ceiling, and a small change
        // under the threshold, yet sixty rows of it overrun the per-build one.
        let body = (0..<150).map { "w\($0)" }.joined(separator: " ")
        let oldLine = "first \(body) last"
        let newLine = "start \(body) end"
        let pair = WordDiff.ranges(old: oldLine, new: newLine)
        XCTAssertNotNil(pair)

        let count = 60
        let rows = LineDiff.rows(
            old: Array(repeating: oldLine, count: count).joined(separator: "\n"),
            new: Array(repeating: newLine, count: count).joined(separator: "\n")
        )
        XCTAssertEqual(rows.count, count)
        XCTAssertTrue(rows.allSatisfy { $0.kind == .modified })
        XCTAssertEqual(rows.first?.words, pair)
        XCTAssertNil(rows.last?.words)
    }
}
