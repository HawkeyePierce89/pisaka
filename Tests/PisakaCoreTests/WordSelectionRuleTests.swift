import XCTest
@testable import PisakaCore

/// Pins the double-click rule: a click selects one identifier by the scanner's
/// language-aware boundary rule, a drag snaps the ends that lie in one, and
/// anything with no identifier to answer keeps the platform's range.
final class WordSelectionRuleTests: XCTestCase {

    private let source = "res.status(200).json({ $store: #x })" as NSString

    private func select(
        _ proposed: NSRange, platform: NSRange = NSRange(location: 99, length: 1), language: SyntaxLanguage? = .javascript
    ) -> NSRange {
        WordSelectionRule.range(proposed: proposed, platformRange: platform, text: source, language: language)
    }

    func testClickOnAnIdentifierSelectsExactlyThatIdentifier() {
        XCTAssertEqual(select(NSRange(location: 1, length: 0)), NSRange(location: 0, length: 3))
        XCTAssertEqual(select(NSRange(location: 5, length: 1)), NSRange(location: 4, length: 6))
        XCTAssertEqual(select(NSRange(location: 17, length: 0)), NSRange(location: 16, length: 4))
    }

    func testClickOnDollarNameIsOneWordInJavaScriptAndSplitInSwift() {
        let dollar = source.range(of: "$store")
        XCTAssertEqual(select(NSRange(location: dollar.location, length: 0)), dollar)
        XCTAssertEqual(
            select(NSRange(location: dollar.location + 2, length: 0), language: .swift),
            NSRange(location: dollar.location + 1, length: 5)
        )
        let hash = source.range(of: "#x")
        XCTAssertEqual(select(NSRange(location: hash.location + 1, length: 0), language: .typescript), hash)
    }

    /// A click on the `.` right after `res` lands on no identifier, so the
    /// platform's answer stands — it does not select `res`.
    func testPunctuationClickReturnsThePlatformRange() {
        let platform = NSRange(location: 3, length: 1)
        XCTAssertEqual(select(NSRange(location: 3, length: 0), platform: platform), platform)
        XCTAssertEqual(select(NSRange(location: 10, length: 1), platform: NSRange(location: 10, length: 1)),
                       NSRange(location: 10, length: 1))
        // Digits are not an identifier either.
        XCTAssertEqual(select(NSRange(location: 12, length: 0), platform: NSRange(location: 11, length: 3)),
                       NSRange(location: 11, length: 3))
    }

    func testDragSnapsBothEndsThatLieInIdentifiers() {
        // From inside `res` to inside `status`.
        XCTAssertEqual(select(NSRange(location: 1, length: 6)), NSRange(location: 0, length: 10))
    }

    func testDragEndOutsideAnIdentifierKeepsThePlatformBound() {
        // From inside `status` to the `(` after it: the start snaps, the end is the platform's.
        let platform = NSRange(location: 0, length: 14)
        XCTAssertEqual(select(NSRange(location: 6, length: 6), platform: platform), NSRange(location: 4, length: 10))
        // From the `.` to inside `status`: the start is the platform's, the end snaps.
        XCTAssertEqual(
            select(NSRange(location: 3, length: 3), platform: NSRange(location: 2, length: 5)),
            NSRange(location: 2, length: 8)
        )
    }

    func testDragWithNoIdentifierAtEitherEndIsThePlatformRange() {
        let platform = NSRange(location: 10, length: 5)
        XCTAssertEqual(select(NSRange(location: 10, length: 5), platform: platform), platform)
    }

    func testOutOfRangeProposalDegradesToThePlatformRange() {
        let platform = NSRange(location: source.length, length: 0)
        XCTAssertEqual(select(NSRange(location: source.length, length: 0), platform: platform), platform)
    }
}
