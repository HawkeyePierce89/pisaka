import XCTest
@testable import PisakaCore

/// Pins the one identifier-boundary rule all of code intelligence shares: the
/// word a ⌘-click resolves, the prefix a keystroke completes, and the words the
/// buffer harvester offers. Boundary cases (`$`, `.`, digit-leading, Unicode,
/// surrogate pairs) are the whole point — they are what a hand-rolled scan in
/// each of the three call sites would have gotten subtly differently.
final class IdentifierScannerTests: XCTestCase {

    private func text(_ string: String) -> NSString { string as NSString }

    // MARK: - identifier(in:at:)

    func testIdentifierExpandsBothWaysFromAnyOffsetInsideIt() {
        let source = text("let workerCount = 3")
        for offset in 4...15 {
            let match = IdentifierScanner.identifier(in: source, at: offset)
            XCTAssertEqual(match?.text, "workerCount", "offset \(offset)")
            XCTAssertEqual(match?.range, NSRange(location: 4, length: 11), "offset \(offset)")
        }
    }

    /// The keyboard path: after typing a name the caret sits just past it, and
    /// ⌃⌘J must still resolve that word.
    func testIdentifierResolvesTheWordEndingAtTheCaret() {
        let source = text("Worker")
        XCTAssertEqual(IdentifierScanner.identifier(in: source, at: 6)?.text, "Worker")
    }

    func testIdentifierIsNilOffAnyName() {
        let source = text("a + b")
        XCTAssertNil(IdentifierScanner.identifier(in: source, at: 2))
        XCTAssertNil(IdentifierScanner.identifier(in: text("   "), at: 1))
        XCTAssertNil(IdentifierScanner.identifier(in: text(""), at: 0))
    }

    func testIdentifierStopsAtDotsAndDollars() {
        let source = text("foo.bar")
        XCTAssertEqual(IdentifierScanner.identifier(in: source, at: 5)?.text, "bar")
        XCTAssertEqual(IdentifierScanner.identifier(in: source, at: 1)?.text, "foo")
        XCTAssertEqual(IdentifierScanner.identifier(in: text("$FOO"), at: 2)?.text, "FOO")
    }

    /// Digits continue a name but cannot start one, so a leading run of them is
    /// trimmed and a pure number is not a name at all.
    func testDigitLeadingRunsAreTrimmedAndPureNumbersAreNotNames() {
        XCTAssertEqual(IdentifierScanner.identifier(in: text("9foo"), at: 0)?.text, "foo")
        XCTAssertEqual(IdentifierScanner.identifier(in: text("9foo"), at: 2)?.text, "foo")
        XCTAssertNil(IdentifierScanner.identifier(in: text("12345"), at: 2))
        XCTAssertEqual(IdentifierScanner.identifier(in: text("x2y"), at: 1)?.text, "x2y")
        XCTAssertEqual(IdentifierScanner.identifier(in: text("_private"), at: 0)?.text, "_private")
    }

    func testUnicodeNamesAreNotSplit() {
        XCTAssertEqual(IdentifierScanner.identifier(in: text("let имя = 1"), at: 5)?.text, "имя")
        XCTAssertEqual(IdentifierScanner.identifier(in: text("número"), at: 3)?.text, "número")
        XCTAssertEqual(IdentifierScanner.identifier(in: text("変数 = 1"), at: 0)?.text, "変数")
    }

    /// A non-BMP scalar occupies two UTF-16 units; neither an offset on its
    /// trailing half nor the surrounding scan may cut it in half.
    func testSurrogatePairsAreScannedWhole() {
        // U+1D400 MATHEMATICAL BOLD CAPITAL A is a letter, so it is a valid name.
        let source = text("var \u{1D400}bc = 1")
        XCTAssertEqual(IdentifierScanner.identifier(in: source, at: 4)?.text, "\u{1D400}bc")
        // Offset 5 is the trailing surrogate half: it resolves to the same name.
        XCTAssertEqual(IdentifierScanner.identifier(in: source, at: 5)?.text, "\u{1D400}bc")
        XCTAssertEqual(
            IdentifierScanner.identifier(in: source, at: 4)?.range,
            NSRange(location: 4, length: 4)
        )
    }

    func testOffsetsOutsideTheStringAreClamped() {
        let source = text("name")
        XCTAssertEqual(IdentifierScanner.identifier(in: source, at: 999)?.text, "name")
        XCTAssertEqual(IdentifierScanner.identifier(in: source, at: -5)?.text, "name")
    }

    // MARK: - completionPrefixRange(in:at:)

    func testCompletionPrefixTakesOnlyTheWordLeftOfTheCaret() {
        let source = text("foo.bar")
        XCTAssertEqual(
            IdentifierScanner.completionPrefixRange(in: source, at: 7),
            NSRange(location: 4, length: 3)
        )
        // Mid-word: only what is to the left is being completed.
        XCTAssertEqual(
            IdentifierScanner.completionPrefixRange(in: source, at: 6),
            NSRange(location: 4, length: 2)
        )
        XCTAssertEqual(
            IdentifierScanner.completionPrefixRange(in: text("$FOO"), at: 4),
            NSRange(location: 1, length: 3)
        )
    }

    func testCompletionPrefixIsEmptyAtTheCaretWhenThereIsNothingToComplete() {
        XCTAssertEqual(
            IdentifierScanner.completionPrefixRange(in: text("foo "), at: 4),
            NSRange(location: 4, length: 0)
        )
        XCTAssertEqual(
            IdentifierScanner.completionPrefixRange(in: text(""), at: 0),
            NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(
            IdentifierScanner.completionPrefixRange(in: text("foo("), at: 4),
            NSRange(location: 4, length: 0)
        )
        // A bare number cannot start a name, so there is no prefix to complete.
        XCTAssertEqual(
            IdentifierScanner.completionPrefixRange(in: text("x = 123"), at: 7),
            NSRange(location: 7, length: 0)
        )
    }

    func testCompletionPrefixTrimsALeadingDigitRun() {
        XCTAssertEqual(
            IdentifierScanner.completionPrefixRange(in: text("9foo"), at: 4),
            NSRange(location: 1, length: 3)
        )
    }

    // MARK: - words(in:limit:)

    func testWordsHarvestsDistinctNamesInFirstOccurrenceOrder() {
        let source = text("let count = count + total // count")
        XCTAssertEqual(IdentifierScanner.words(in: source, limit: 100), ["let", "count", "total"])
    }

    func testWordsAppliesTheSameBoundaryRule() {
        let source = text("foo.bar $BAZ 9qux 123 _x 変数")
        XCTAssertEqual(
            IdentifierScanner.words(in: source, limit: 100),
            ["foo", "bar", "BAZ", "qux", "_x", "変数"]
        )
    }

    func testWordsCapsDistinctEntriesAndStopsScanning() {
        let source = text("aa bb cc dd ee")
        XCTAssertEqual(IdentifierScanner.words(in: source, limit: 3), ["aa", "bb", "cc"])
        XCTAssertEqual(IdentifierScanner.words(in: source, limit: 0), [])
        XCTAssertEqual(IdentifierScanner.words(in: text(""), limit: 10), [])
    }

    /// The cap counts distinct words, so repetition does not consume it — the
    /// reason a large generated file with few unique tokens still harvests fully.
    func testWordsCapCountsDistinctNamesOnly() {
        let source = text(Array(repeating: "same", count: 500).joined(separator: " ") + " other")
        XCTAssertEqual(IdentifierScanner.words(in: source, limit: 2), ["same", "other"])
    }

    // MARK: - The shared classification

    func testClassificationExcludesDigitsFromStartsButNotFromContinuations() {
        XCTAssertTrue(IdentifierScanner.isIdentifierStart("a"))
        XCTAssertTrue(IdentifierScanner.isIdentifierStart("_"))
        XCTAssertTrue(IdentifierScanner.isIdentifierStart("я"))
        XCTAssertFalse(IdentifierScanner.isIdentifierStart("7"))
        XCTAssertFalse(IdentifierScanner.isIdentifierStart("$"))
        XCTAssertFalse(IdentifierScanner.isIdentifierStart("."))

        XCTAssertTrue(IdentifierScanner.isIdentifierContinuation("7"))
        XCTAssertTrue(IdentifierScanner.isIdentifierContinuation("_"))
        XCTAssertFalse(IdentifierScanner.isIdentifierContinuation("-"))
        XCTAssertFalse(IdentifierScanner.isIdentifierContinuation(" "))
    }

    /// The ASCII fast path must be a pure optimization: over the whole ASCII
    /// range both rules have to answer exactly what `CharacterSet.letters` /
    /// `.alphanumerics` do, or the scanner would quietly disagree with itself
    /// about a character source code is full of. Checked exhaustively rather than
    /// by sampling — the range is 128 values, and an off-by-one at a boundary
    /// (`@`/`A`, `Z`/`[`, `` ` ``/`a`, `z`/`{`, `/`/`0`, `9`/`:`) is precisely the
    /// mistake a hand-written range compare makes.
    func testASCIIClassificationMatchesTheUnicodeSetsItShortCircuits() {
        for value in 0..<128 {
            let scalar = UnicodeScalar(UInt8(value))
            XCTAssertEqual(
                IdentifierScanner.isIdentifierStart(scalar),
                scalar == "_" || CharacterSet.letters.contains(scalar),
                "start rule disagrees for U+\(String(value, radix: 16))"
            )
            XCTAssertEqual(
                IdentifierScanner.isIdentifierContinuation(scalar),
                scalar == "_" || CharacterSet.alphanumerics.contains(scalar),
                "continuation rule disagrees for U+\(String(value, radix: 16))"
            )
        }
    }
}
