import XCTest
@testable import PisakaCore

/// The whole-word scan that answers Find Usages where no language server does.
///
/// The load-bearing cases are the boundary ones: this scanner delegates "where
/// does a word end" to `IdentifierScanner`, so what is pinned here is that the
/// delegation holds — including where the shared rule is surprising — rather than
/// a second rule restated in test form.
final class TextualUsageScannerTests: XCTestCase {

    private func ranges(of identifier: String, in text: String) -> [NSRange] {
        TextualUsageScanner.matches(of: identifier, in: text as NSString).map(\.range)
    }

    private func lines(of identifier: String, in text: String) -> [Int] {
        TextualUsageScanner.matches(of: identifier, in: text as NSString).map(\.line)
    }

    // MARK: - The boundary rule

    func testFindsAStandaloneOccurrence() {
        XCTAssertEqual(ranges(of: "foo", in: "let foo = 1"), [NSRange(location: 4, length: 3)])
    }

    func testRejectsAnOccurrenceInsideALongerWord() {
        XCTAssertEqual(ranges(of: "foo", in: "let foobar = 1"), [])
    }

    func testRejectsAnOccurrenceAfterAnUnderscore() {
        XCTAssertEqual(ranges(of: "foo", in: "let _foo = 1"), [])
    }

    func testRejectsAnOccurrenceFollowedByAnUnderscore() {
        XCTAssertEqual(ranges(of: "foo", in: "let foo_ = 1"), [])
    }

    func testRejectsAnOccurrenceFollowedByADigit() {
        XCTAssertEqual(ranges(of: "foo", in: "let foo2 = 1"), [])
    }

    func testAcceptsAnOccurrenceBeforeAMemberDot() {
        XCTAssertEqual(ranges(of: "foo", in: "foo.bar()"), [NSRange(location: 0, length: 3)])
    }

    func testAcceptsAnOccurrenceAfterAMemberDot() {
        XCTAssertEqual(ranges(of: "bar", in: "foo.bar()"), [NSRange(location: 4, length: 3)])
    }

    func testAcceptsAnOccurrenceAtTheVeryStartOfTheBuffer() {
        XCTAssertEqual(ranges(of: "foo", in: "foo()"), [NSRange(location: 0, length: 3)])
    }

    func testAcceptsAnOccurrenceAtTheVeryEndOfTheBuffer() {
        XCTAssertEqual(ranges(of: "foo", in: "call(foo"), [NSRange(location: 5, length: 3)])
    }

    func testTheWholeBufferBeingTheIdentifierIsOneMatch() {
        XCTAssertEqual(ranges(of: "foo", in: "foo"), [NSRange(location: 0, length: 3)])
    }

    func testAcceptsARunThatOnlyBecomesAnIdentifierAfterTheTrimRule() {
        // Inherited from `IdentifierScanner`, deliberately: a run beginning with
        // digits is not a name, so `foo` is the identifier in `123foo` — exactly
        // what a click on that `f` resolves. Delegating means inheriting this too.
        XCTAssertEqual(ranges(of: "foo", in: "x = 123foo"), [NSRange(location: 7, length: 3)])
    }

    func testFindsEveryOccurrenceInAscendingOrder() {
        let text = "foo(foo, foo)"
        XCTAssertEqual(
            ranges(of: "foo", in: text).map(\.location),
            [0, 4, 9]
        )
    }

    func testAdjacentOccurrencesSeparatedByOnePunctuationAreBothFound() {
        XCTAssertEqual(ranges(of: "a", in: "a.a").map(\.location), [0, 2])
    }

    func testRepeatedSpellingInsideOneWordIsNotAMatch() {
        // `foofoo` is one word; neither half is a usage, and the scan must not
        // find the second half by resuming one unit after the first.
        XCTAssertEqual(ranges(of: "foo", in: "foofoo"), [])
    }

    // MARK: - Unicode

    func testFindsANonASCIIIdentifier() {
        let text = "let имя = имя + 1"
        let found = TextualUsageScanner.matches(of: "имя", in: text as NSString)
        XCTAssertEqual(found.count, 2)
        for match in found {
            XCTAssertEqual((text as NSString).substring(with: match.range), "имя")
        }
    }

    func testRejectsANonASCIIIdentifierInsideALongerNonASCIIWord() {
        XCTAssertEqual(ranges(of: "имя", in: "let имяФайла = 1"), [])
    }

    func testANonBMPScalarInANeighbouringWordDoesNotSplitTheBoundaryCheck() {
        // The emoji is not an identifier scalar, so the name beside it stands
        // alone — and the surrogate pair must not be read as half a character.
        let text = "// 🚀 foo"
        XCTAssertEqual(ranges(of: "foo", in: text).map(\.location), [(text as NSString).length - 3])
    }

    // MARK: - Refused queries

    func testEmptyQueryFindsNothing() {
        XCTAssertEqual(ranges(of: "", in: "foo foo foo"), [])
    }

    func testEmptyTextFindsNothing() {
        XCTAssertEqual(ranges(of: "foo", in: ""), [])
    }

    func testQueryLongerThanTheTextFindsNothing() {
        XCTAssertEqual(ranges(of: "identifier", in: "id"), [])
    }

    func testNonIdentifierQueryFindsNothingEvenWhereItOccurs() {
        // Each of these occurs verbatim in its text; none of them is a word this
        // editor can recognize, so a match would be a different command's answer.
        XCTAssertEqual(ranges(of: "run(_:)", in: "call run(_:) here"), [])
        XCTAssertEqual(ranges(of: ".btn-primary", in: "a .btn-primary b"), [])
        XCTAssertEqual(ranges(of: "9foo", in: "x = 9foo"), [])
        XCTAssertEqual(ranges(of: "two words", in: "two words here"), [])
    }

    // MARK: - Line numbers

    func testLineNumbersUseTheEditorsOwnSeparators() {
        XCTAssertEqual(lines(of: "foo", in: "foo\nfoo\nfoo"), [1, 2, 3])
    }

    func testCRLFIsOneBreak() {
        XCTAssertEqual(lines(of: "foo", in: "foo\r\nfoo\r\nfoo"), [1, 2, 3])
    }

    func testLoneCarriageReturnIsALineBreak() {
        XCTAssertEqual(lines(of: "foo", in: "foo\rfoo"), [1, 2])
    }

    func testTheEditorsFullSeparatorSetCounts() {
        // NEL, LS and PS are line breaks to the gutter (`LineStartIndex`) even
        // though the protocol does not know them (D1); the row must print the
        // number the gutter prints.
        let text = "foo\u{0085}foo\u{2028}foo\u{2029}foo"
        XCTAssertEqual(lines(of: "foo", in: text), [1, 2, 3, 4])
    }

    // MARK: - Previews

    func testPreviewIsTheMatchsLineWithoutItsSeparator() {
        let matches = TextualUsageScanner.matches(of: "foo", in: "first\nlet foo = 1\nlast" as NSString)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.preview.text, "let foo = 1")
        XCTAssertEqual(matches.first?.preview.matchRange, NSRange(location: 4, length: 3))
    }

    func testPreviewOfACRLFLineDropsBothUnits() {
        let matches = TextualUsageScanner.matches(of: "foo", in: "let foo = 1\r\nnext" as NSString)
        XCTAssertEqual(matches.first?.preview.text, "let foo = 1")
    }

    func testPreviewOfAVeryLongLineIsClipped() throws {
        let padding = String(repeating: "x", count: 5_000)
        let text = "\(padding) foo \(padding)"
        let matches = TextualUsageScanner.matches(of: "foo", in: text as NSString)
        XCTAssertEqual(matches.count, 1)

        let preview = try XCTUnwrap(matches.first).preview
        let window = preview.text as NSString
        XCTAssertLessThanOrEqual(window.length, 300)
        // Whatever the window, it still frames the match itself.
        XCTAssertEqual(window.substring(with: preview.matchRange), "foo")
    }
}
