import XCTest
@testable import PisakaCore

/// Pins which highlight a settled selection asks for — identifier occurrences,
/// selection matches or none — and the selection match's cap of fifty.
final class OccurrenceHighlightRuleTests: XCTestCase {

    private let text = "let total = price * count;\nreturn total  ;\n" as NSString

    private func mode(_ range: NSRange, language: SyntaxLanguage? = .typescript) -> OccurrenceHighlightRule.Mode {
        OccurrenceHighlightRule.mode(text: text, selection: range, language: language)
    }

    private func identifier(_ word: String, at location: Int) -> OccurrenceHighlightRule.Mode {
        .identifier(IdentifierScanner.Match(text: word, range: NSRange(location: location, length: word.count)))
    }

    // MARK: - Identifier

    func testCaretInsideAnIdentifier() {
        XCTAssertEqual(mode(NSRange(location: 6, length: 0)), identifier("total", at: 4))
    }

    func testCaretTouchingAnIdentifierAtEitherEnd() {
        XCTAssertEqual(mode(NSRange(location: 4, length: 0)), identifier("total", at: 4))
        XCTAssertEqual(mode(NSRange(location: 9, length: 0)), identifier("total", at: 4))
    }

    func testCaretAwayFromAnyIdentifierIsNone() {
        XCTAssertEqual(mode(NSRange(location: 11, length: 0)), .none)
    }

    func testSelectionOfExactlyOneIdentifierIsTheIdentifierNotASelectionMatch() {
        XCTAssertEqual(mode(NSRange(location: 4, length: 5)), identifier("total", at: 4))
    }

    func testDollarIdentifierInTypeScript() {
        let source = "const $x = 1;" as NSString
        XCTAssertEqual(
            OccurrenceHighlightRule.mode(text: source, selection: NSRange(location: 7, length: 0), language: .typescript),
            .identifier(IdentifierScanner.Match(text: "$x", range: NSRange(location: 6, length: 2)))
        )
    }

    // MARK: - Selection match eligibility

    func testPartOfAnIdentifierIsASelectionMatch() {
        XCTAssertEqual(mode(NSRange(location: 4, length: 3)), .selectionMatch("tot"))
    }

    func testAnExpressionWithinOneLineIsASelectionMatch() {
        XCTAssertEqual(mode(NSRange(location: 12, length: 7)), .selectionMatch("price *"))
    }

    func testAMultiLineSelectionIsNone() {
        XCTAssertEqual(mode(NSRange(location: 20, length: 12)), .none)
        // A selection that merely ends with the line break is multi-line too.
        XCTAssertEqual(mode(NSRange(location: 20, length: 7)), .none)
    }

    func testEveryLineSeparatorEndsTheLine() {
        for separator in ["\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"] {
            let source = "ab\(separator)cd" as NSString
            XCTAssertEqual(
                OccurrenceHighlightRule.mode(
                    text: source, selection: NSRange(location: 1, length: source.length - 2), language: nil
                ),
                .none,
                "separator \(separator.unicodeScalars.map(\.value))"
            )
        }
    }

    func testAOneUnitSelectionIsNone() {
        XCTAssertEqual(mode(NSRange(location: 18, length: 1)), .none)
    }

    func testAnAllWhitespaceSelectionIsNone() {
        let spaces = text.range(of: "  ;")
        XCTAssertEqual(mode(NSRange(location: spaces.location, length: 2)), .none)
        let tabs = "a\t\t b" as NSString
        XCTAssertEqual(
            OccurrenceHighlightRule.mode(text: tabs, selection: NSRange(location: 1, length: 3), language: nil),
            .none
        )
    }

    func testASelectionOutOfTheTextIsNone() {
        XCTAssertEqual(mode(NSRange(location: text.length, length: 2)), .none)
        XCTAssertEqual(mode(NSRange(location: NSNotFound, length: 0)), .none)
    }

    // MARK: - Cap

    func testSelectionMatchesAtTheCapArePainted() {
        let source = String(repeating: "a + b\n", count: 50) as NSString
        XCTAssertEqual(OccurrenceHighlightRule.selectionMatchCap, 50)
        XCTAssertEqual(OccurrenceHighlightRule.selectionMatches(of: "a + b", in: source)?.count, 50)
    }

    func testSelectionMatchesPastTheCapAreEmpty() {
        let source = String(repeating: "a + b\n", count: 51) as NSString
        XCTAssertEqual(OccurrenceHighlightRule.selectionMatches(of: "a + b", in: source), [])
    }

    func testSelectionMatchesReportBudgetExhaustion() {
        let source = (String(repeating: "x", count: 100_000) + "a + b") as NSString
        XCTAssertNil(OccurrenceHighlightRule.selectionMatches(of: "a + b", in: source, budget: 1_000))
    }
}
