import XCTest
@testable import PisakaCore

/// Tests for EditorConfig's own glob dialect, one construct at a time.
///
/// The cases mirror the official EditorConfig core test suite's glob file — its
/// *contents*, not its files: an actual `.editorconfig` committed under `Tests/`
/// would apply to this repository in every editor and every tool that reads the
/// format, so each case is spelled inline and named after the case it mirrors.
final class EditorConfigGlobTests: XCTestCase {

    // MARK: - Helpers

    private func matches(_ pattern: String, _ path: String) -> Bool {
        EditorConfigGlob(pattern: pattern).matches(relativePath: path)
    }

    // MARK: - Anchoring: "no slash ⇒ any depth" vs. "slash ⇒ anchored"

    func testPatternWithoutSlashMatchesAtAnyDepth() {
        XCTAssertFalse(EditorConfigGlob(pattern: "*.c").anchored)
        XCTAssertTrue(matches("*.c", "a.c"))
        XCTAssertTrue(matches("*.c", "sub/a.c"))
        XCTAssertTrue(matches("*.c", "deep/sub/a.c"))
    }

    func testLeadingSlashAnchorsToTheConfigsOwnDirectory() {
        XCTAssertTrue(EditorConfigGlob(pattern: "/*.c").anchored)
        XCTAssertTrue(matches("/*.c", "a.c"))
        XCTAssertFalse(matches("/*.c", "sub/a.c"))
    }

    func testInnerSlashAnchorsWithoutALeadingSlash() {
        XCTAssertTrue(EditorConfigGlob(pattern: "sub/*.c").anchored)
        XCTAssertTrue(matches("sub/*.c", "sub/a.c"))
        XCTAssertFalse(matches("sub/*.c", "a.c"))
        XCTAssertFalse(matches("sub/*.c", "deep/sub/a.c"))
    }

    func testEscapedSlashDoesNotAnchor() {
        XCTAssertFalse(EditorConfigGlob(pattern: "a\\/b").anchored)
    }

    // MARK: - Star

    func testStarMatchesAnyRunWithinOneComponent() {
        XCTAssertTrue(matches("a*e.c", "ace.c"))
        XCTAssertTrue(matches("a*e.c", "abcde.c"))
        XCTAssertFalse(matches("*.c", "a.cpp"))
    }

    func testStarDoesNotMatchOverASlash() {
        XCTAssertFalse(matches("/a*e.c", "a/e.c"))
        XCTAssertFalse(matches("/sub/*.c", "sub/deep/a.c"))
    }

    func testStarMatchesTheEmptyRun() {
        XCTAssertTrue(matches("/a*.c", "a.c"))
    }

    // MARK: - Double star

    func testDoubleStarMatchesOverSlashes() {
        XCTAssertTrue(matches("a**z.c", "az.c"))
        XCTAssertTrue(matches("a**z.c", "a/z.c"))
        XCTAssertTrue(matches("a**z.c", "a/b/c/z.c"))
    }

    func testDoubleStarIsNotBoundToWholePathComponents() {
        // Unlike gitignore's `**`, which is only meaningful as a whole
        // component, EditorConfig's may stand for part of one.
        XCTAssertTrue(matches("/b/**z.c", "b/deep/subz.c"))
    }

    func testDoubleStarBetweenSlashesSpansDirectories() {
        XCTAssertTrue(matches("b/**/z.c", "b/x/z.c"))
        XCTAssertTrue(matches("b/**/z.c", "b/x/y/z.c"))
        XCTAssertFalse(matches("b/**/z.c", "c/x/z.c"))
    }

    // MARK: - Question mark

    func testQuestionMarkMatchesExactlyOneCharacter() {
        XCTAssertTrue(matches("/?.c", "a.c"))
        XCTAssertFalse(matches("/?.c", "ab.c"))
        XCTAssertFalse(matches("/?.c", ".c"))
    }

    func testQuestionMarkDoesNotMatchASlash() {
        // The documented deliberate choice where the reference cores disagree.
        XCTAssertFalse(matches("/a?c.txt", "a/c.txt"))
    }

    // MARK: - Character classes

    func testCharacterClassMatchesOneListedCharacter() {
        XCTAssertTrue(matches("/[abc].c", "a.c"))
        XCTAssertTrue(matches("/[abc].c", "c.c"))
        XCTAssertFalse(matches("/[abc].c", "d.c"))
    }

    func testCharacterClassRange() {
        XCTAssertTrue(matches("/[a-z].c", "q.c"))
        XCTAssertFalse(matches("/[a-z].c", "Q.c"))
    }

    func testNegatedCharacterClass() {
        XCTAssertTrue(matches("/[!abc].c", "d.c"))
        XCTAssertFalse(matches("/[!abc].c", "a.c"))
        XCTAssertTrue(matches("/[^abc].c", "d.c"))
        XCTAssertFalse(matches("/[^abc].c", "b.c"))
    }

    func testUnclosedBracketIsALiteral() {
        XCTAssertTrue(matches("/[ab.c", "[ab.c"))
        XCTAssertFalse(matches("/[ab.c", "a.c"))
    }

    // MARK: - Braces: alternation

    func testBraceAlternation() {
        XCTAssertTrue(matches("*.{c,cpp}", "a.c"))
        XCTAssertTrue(matches("*.{c,cpp}", "a.cpp"))
        XCTAssertFalse(matches("*.{c,cpp}", "a.h"))
    }

    func testNestedBraceAlternation() {
        XCTAssertTrue(matches("{a,{b,c}}.txt", "a.txt"))
        XCTAssertTrue(matches("{a,{b,c}}.txt", "b.txt"))
        XCTAssertTrue(matches("{a,{b,c}}.txt", "c.txt"))
        XCTAssertFalse(matches("{a,{b,c}}.txt", "d.txt"))
    }

    func testEmptyAlternativeMatchesNothingAtAll() {
        XCTAssertTrue(matches("{,b}.txt", ".txt"))
        XCTAssertTrue(matches("{,b}.txt", "b.txt"))
        XCTAssertFalse(matches("{,b}.txt", "c.txt"))
    }

    func testAlternativeThatWouldStrandTheRestFallsThroughToTheNext() {
        // `ab` must be tried after `a` fails to leave `b.txt` matchable.
        XCTAssertTrue(matches("{a,ab}.txt", "ab.txt"))
    }

    // MARK: - Braces: literal groups

    func testBraceGroupWithoutCommaOrRangeIsLiteralText() {
        XCTAssertTrue(matches("{single}.b", "{single}.b"))
        XCTAssertFalse(matches("{single}.b", "single.b"))
    }

    func testEmptyBraceGroupIsLiteralText() {
        XCTAssertTrue(matches("{}.b", "{}.b"))
    }

    func testUnmatchedOpeningBraceIsLiteralText() {
        XCTAssertTrue(matches("a{b,c", "a{b,c"))
    }

    func testNonIntegerRangeGroupIsLiteralText() {
        XCTAssertTrue(matches("{a..b}.txt", "{a..b}.txt"))
        XCTAssertFalse(matches("{a..b}.txt", "a.txt"))
    }

    // MARK: - Braces: numeric ranges

    func testNumericRangeMatchesEveryIntegerInIt() {
        XCTAssertTrue(matches("{1..3}.txt", "1.txt"))
        XCTAssertTrue(matches("{1..3}.txt", "2.txt"))
        XCTAssertTrue(matches("{1..3}.txt", "3.txt"))
        XCTAssertFalse(matches("{1..3}.txt", "4.txt"))
        XCTAssertFalse(matches("{1..3}.txt", "10.txt"))
    }

    func testNumericRangeMatchesMultiDigitIntegers() {
        XCTAssertTrue(matches("{1..100}.txt", "42.txt"))
        XCTAssertFalse(matches("{1..100}.txt", "101.txt"))
    }

    func testNumericRangeAcceptsNegativeBoundsAndAMatchedMinus() {
        XCTAssertTrue(matches("{-2..2}.txt", "-1.txt"))
        XCTAssertTrue(matches("{-2..2}.txt", "0.txt"))
        XCTAssertTrue(matches("{-2..2}.txt", "-2.txt"))
        XCTAssertFalse(matches("{-2..2}.txt", "-3.txt"))
    }

    func testNumericRangeRefusesANonInteger() {
        XCTAssertFalse(matches("{1..3}.txt", "a.txt"))
        XCTAssertFalse(matches("{1..3}.txt", ".txt"))
    }

    func testNumericRangeBacktracksOntoAShorterRun() {
        XCTAssertTrue(matches("{1..2}0.txt", "10.txt"))
    }

    // MARK: - Escapes

    func testBackslashEscapesTheNextCharacter() {
        XCTAssertTrue(matches("\\*.txt", "*.txt"))
        XCTAssertFalse(matches("\\*.txt", "a.txt"))
        XCTAssertTrue(matches("\\{a\\}.txt", "{a}.txt"))
        XCTAssertTrue(matches("\\?.txt", "?.txt"))
        XCTAssertFalse(matches("\\?.txt", "a.txt"))
    }

    func testEscapedCommaInsideAGroupIsALiteral() {
        XCTAssertTrue(matches("{a\\,b}.txt", "{a,b}.txt"))
    }

    // MARK: - The section-name length cap

    func testSectionNameAtTheLimitIsHonored() {
        let name = String(repeating: "a", count: 1020) + ".txt"
        XCTAssertEqual(name.count, EditorConfigGlob.maximumSectionNameLength)
        let glob = EditorConfigGlob(pattern: name)
        XCTAssertFalse(glob.exceedsLengthLimit)
        XCTAssertTrue(glob.matches(relativePath: name))
    }

    func testSectionNameBeyondTheLimitNeverMatches() {
        let name = String(repeating: "a", count: 1021) + ".txt"
        XCTAssertGreaterThan(name.count, EditorConfigGlob.maximumSectionNameLength)
        let glob = EditorConfigGlob(pattern: name)
        XCTAssertTrue(glob.exceedsLengthLimit)
        XCTAssertFalse(glob.matches(relativePath: name))
    }

    // MARK: - Identity

    func testEqualityIsTheSourceSpelling() {
        XCTAssertEqual(EditorConfigGlob(pattern: "*.c"), EditorConfigGlob(pattern: "*.c"))
        XCTAssertNotEqual(EditorConfigGlob(pattern: "*.c"), EditorConfigGlob(pattern: "*.h"))
    }
}
