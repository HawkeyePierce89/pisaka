import XCTest
@testable import PisakaCore

/// Pins `completionReplaceRange(in:at:)` — Tab's commit range, the whole
/// identifier the caret sits in. Split from `IdentifierScannerTests` to keep
/// both files under the linter's size budgets; the boundary rule itself is the
/// same one the prefix tests there pin.
final class IdentifierScannerReplaceRangeTests: XCTestCase {

    private func text(_ string: String) -> NSString { string as NSString }

    func testCompletionReplaceRangeEqualsPrefixRangeWhenThereIsNoSuffix() {
        let source = text("foo.bar")
        XCTAssertEqual(
            IdentifierScanner.completionReplaceRange(in: source, at: 7),
            IdentifierScanner.completionPrefixRange(in: source, at: 7)
        )
    }

    func testCompletionReplaceRangeExtendsOverTheSuffix() {
        let source = text("CREATE_typo")
        // caret after CREATE (offset 6)
        XCTAssertEqual(
            IdentifierScanner.completionReplaceRange(in: source, at: 6),
            NSRange(location: 0, length: 11)
        )
    }

    func testCompletionReplaceRangeAtStartOfWordExtendsOverWholeWord() {
        let source = text("foo")
        XCTAssertEqual(
            IdentifierScanner.completionReplaceRange(in: source, at: 0),
            NSRange(location: 0, length: 3)
        )
    }

    func testCompletionReplaceRangeWithEmptyString() {
        let source = text("")
        XCTAssertEqual(
            IdentifierScanner.completionReplaceRange(in: source, at: 0),
            NSRange(location: 0, length: 0)
        )
    }

    func testCompletionReplaceRangeWithEmptyPrefixAndSuffixCoversSuffix() {
        let source = text("worker.foo")
        // caret after the dot (offset 7)
        XCTAssertEqual(
            IdentifierScanner.completionReplaceRange(in: source, at: 7),
            NSRange(location: 7, length: 3)
        )
    }

    func testCompletionReplaceRangeAtMemberPositionStopsAtDot() {
        let source = text("foo.bar.baz")
        // caret in bar (offset 5)
        XCTAssertEqual(
            IdentifierScanner.completionReplaceRange(in: source, at: 5),
            NSRange(location: 4, length: 3)
        )
    }

    func testCompletionReplaceRangeWithTrimmedHeadPreservesTheTrimmedStart() {
        let source = text("9foobar")
        // caret at 9foo|bar (offset 4)
        XCTAssertEqual(
            IdentifierScanner.completionReplaceRange(in: source, at: 4),
            NSRange(location: 1, length: 6) // "foobar"
        )
    }

    func testCompletionReplaceRangePastDotYieldsEmptyRange() {
        let source = text("worker.")
        // caret after the dot (offset 7)
        XCTAssertEqual(
            IdentifierScanner.completionReplaceRange(in: source, at: 7),
            NSRange(location: 7, length: 0)
        )
    }

    func testCompletionReplaceRangeClampsOffsetsAndAlignsScalars() {
        let source = text("var \u{1D400}bc = 1")
        // Caret in mid-surrogate (offset 5). The start is at 4, length is 4 ("\u{1D400}bc")
        XCTAssertEqual(
            IdentifierScanner.completionReplaceRange(in: source, at: 5),
            NSRange(location: 4, length: 4)
        )
        // Out of range negative clamps to 0
        XCTAssertEqual(
            IdentifierScanner.completionReplaceRange(in: source, at: -5),
            NSRange(location: 0, length: 3) // "var"
        )
        // End of buffer (clamps to length)
        XCTAssertEqual(
            IdentifierScanner.completionReplaceRange(in: source, at: 999),
            NSRange(location: source.length, length: 0)
        )
    }
}
