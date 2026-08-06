import XCTest
@testable import PisakaCore

final class GitRefNameTests: XCTestCase {
    func testAcceptsOrdinaryNames() {
        XCTAssertTrue(GitRefName.isValid("main"))
        XCTAssertTrue(GitRefName.isValid("feature-login"))
        XCTAssertTrue(GitRefName.isValid("release/1.0"))
        XCTAssertTrue(GitRefName.isValid("fix_123"))
        XCTAssertTrue(GitRefName.isValid("v2.0.1"))
        XCTAssertTrue(GitRefName.isValid("user/topic"))
    }

    func testRejectsEmptyOrWhitespace() {
        XCTAssertFalse(GitRefName.isValid(""))
        XCTAssertFalse(GitRefName.isValid("   "))
        XCTAssertFalse(GitRefName.isValid("\t"))
    }

    func testRejectsSpaces() {
        XCTAssertFalse(GitRefName.isValid("my branch"))
    }

    func testRejectsForbiddenCharacters() {
        XCTAssertFalse(GitRefName.isValid("foo~bar"))
        XCTAssertFalse(GitRefName.isValid("foo^bar"))
        XCTAssertFalse(GitRefName.isValid("foo:bar"))
        XCTAssertFalse(GitRefName.isValid("foo?bar"))
        XCTAssertFalse(GitRefName.isValid("foo*bar"))
        XCTAssertFalse(GitRefName.isValid("foo[bar"))
        XCTAssertFalse(GitRefName.isValid("foo\\bar"))
    }

    func testRejectsControlAndNul() {
        XCTAssertFalse(GitRefName.isValid("foo\u{01}bar"))
        XCTAssertFalse(GitRefName.isValid("foo\u{7F}bar"))
        XCTAssertFalse(GitRefName.isValid("foo\0bar"))
        XCTAssertFalse(GitRefName.isValid("foo\nbar"))
        XCTAssertFalse(GitRefName.isValid("foo\rbar"))
    }

    func testRejectsCRLFWhichIsOneGraphemeCarryingTwoScalars() {
        // `\r\n` is a *single* `Character`, so a `Character`-level control-char
        // scan skips it; the check must run over unicode scalars. Reachable by
        // pasting into the multiline "New Branch" field.
        XCTAssertEqual("foo\r\nbar".count, 7)
        XCTAssertFalse(GitRefName.isValid("foo\r\nbar"))
    }

    func testRejectsEveryLineBreakScalar() {
        // Three of `CharacterSet.newlines` — NEL, LINE SEPARATOR, PARAGRAPH
        // SEPARATOR — sit above the ASCII control range, so the control check
        // alone accepted them and a pasted break reached `git checkout -b`
        // (these dialogs pass no live validator). Mirrors
        // `FileNameTests.testValidatePathDetectsEveryLineBreakScalar`.
        for separator in ["\n", "\r", "\r\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"] {
            XCTAssertFalse(
                GitRefName.isValid("foo\(separator)bar"),
                "expected rejection for U+\(separator.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "+"))"
            )
        }
    }

    func testRejectsDotDot() {
        XCTAssertFalse(GitRefName.isValid("foo..bar"))
    }

    func testRejectsLeadingOrTrailingSlash() {
        XCTAssertFalse(GitRefName.isValid("/foo"))
        XCTAssertFalse(GitRefName.isValid("foo/"))
    }

    func testRejectsDoubledSlash() {
        XCTAssertFalse(GitRefName.isValid("foo//bar"))
    }

    func testRejectsLockSuffix() {
        XCTAssertFalse(GitRefName.isValid("foo.lock"))
        XCTAssertFalse(GitRefName.isValid("feature/foo.lock"))
    }

    func testRejectsAtBrace() {
        XCTAssertFalse(GitRefName.isValid("foo@{1}"))
    }

    func testRejectsLoneAt() {
        XCTAssertFalse(GitRefName.isValid("@"))
    }

    func testRejectsLeadingDotOrDotAfterSlash() {
        XCTAssertFalse(GitRefName.isValid(".foo"))
        XCTAssertFalse(GitRefName.isValid("foo/.bar"))
    }

    func testRejectsTrailingDot() {
        XCTAssertFalse(GitRefName.isValid("foo."))
    }

    func testRejectsLeadingDash() {
        // A dash-led name is mis-parsed as an option by `git checkout -b <name>`
        // on macOS and creates an unusable branch via libgit2 on iOS.
        XCTAssertFalse(GitRefName.isValid("-foo"))
        XCTAssertFalse(GitRefName.isValid("-"))
        XCTAssertFalse(GitRefName.isValid("--force"))
        // A dash elsewhere is fine.
        XCTAssertTrue(GitRefName.isValid("foo-bar"))
    }

    func testAcceptsInteriorAt() {
        // Only a lone `@` and the `@{` sequence are rejected — a mid-string `@`
        // is a valid branch-name character.
        XCTAssertTrue(GitRefName.isValid("foo@bar"))
    }
}
