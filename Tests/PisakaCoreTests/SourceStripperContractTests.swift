import XCTest

/// The contract of `LSPSourceGatingTests.strippingCommentsAndStringLiterals(_:)`,
/// the one full stripper every source-gating suite matches against.
///
/// Those suites only ever ask it questions about real repository files, so a
/// change to how it treats a construct the repository happens not to contain
/// today would pass all of them. This suite pins the behaviour directly, one
/// construct per case, each asserting the **exact** output string — so a rewrite
/// of the stripper (for speed, or anything else) has to reproduce it byte for
/// byte, not merely keep the gating suites green.
///
/// Every case also asserts that the output has as many lines as the input:
/// newlines survive every construct, which is what lets the line-oriented
/// assertions elsewhere report the line a reader will find.
///
/// The fixtures are Swift raw-string literals in this file, so there is no
/// fixture file and no `exclude:` entry for one. The expected outputs are built
/// from explicit line arrays, because several end in a space a multi-line literal
/// would hide.
final class SourceStripperContractTests: XCTestCase {
    private func assertStrips(
        _ input: String,
        to expectedLines: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let output = LSPSourceGatingTests.strippingCommentsAndStringLiterals(input)
        let expected = expectedLines.joined(separator: "\n")
        XCTAssertEqual(output, expected, file: file, line: line)
        XCTAssertEqual(
            output.components(separatedBy: "\n").count,
            input.components(separatedBy: "\n").count,
            "the stripped text must keep the input's line count",
            file: file,
            line: line
        )
    }

    func testLineCommentsAreRemovedAndTheirNewlinesKept() {
        assertStrips(
            #"""
            let a = 1 // trailing
            // whole line
            let b = 2
            """#,
            to: ["let a = 1 ", "", "let b = 2"]
        )
    }

    func testABlockCommentIsRemovedKeepingOnlyItsNewlines() {
        assertStrips(
            #"""
            let a /* inline */ = 1
            /* spans
               two lines */let b = 2
            """#,
            to: ["let a  = 1", "", "let b = 2"]
        )
    }

    /// Swift block comments nest: the first `*/` closes only the inner one, so
    /// the text after it is still comment.
    func testANestedBlockCommentSpanningLinesIsRemovedWhole() {
        assertStrips(
            #"""
            let a = 1 /* outer
            /* inner */ still outer
            */ let b = 2
            """#,
            to: ["let a = 1 ", "", " let b = 2"]
        )
    }

    func testALiteralWithEscapedQuotesIsRemovedWhole() {
        assertStrips(
            #"""
            let s = "a \"b\" c" + t
            """#,
            to: ["let s =  + t"]
        )
    }

    func testAMultiLineLiteralIsRemovedKeepingItsNewlines() {
        assertStrips(
            #"""
            let s = """
                line one
                line "two"
                """
            let t = 1
            """#,
            to: ["let s = ", "", "", "", "let t = 1"]
        )
    }

    /// The lenient approximation the stripper's own doc comment states: an
    /// interpolation's contents go with the literal around them.
    func testAnInterpolationIsDroppedWithTheLiteralAroundIt() {
        assertStrips(
            #"""
            let s = "x \(y) z"; let n = 1
            """#,
            to: ["let s = ; let n = 1"]
        )
    }

    func testDoubleSlashInsideALiteralDoesNotStartAComment() {
        assertStrips(
            #"""
            let url = "https://example.com"; let n = 1
            """#,
            to: ["let url = ; let n = 1"]
        )
    }

    /// A lone `"` must not swallow the rest of the file: the literal bails back
    /// to code at the newline, and the next line survives intact.
    func testAnUnterminatedLiteralReturnsToCodeAtTheNewline() {
        assertStrips(
            #"""
            let q = "unterminated
            let r = 2
            """#,
            to: ["let q = ", "let r = 2"]
        )
    }

    /// A backslash inside a literal skips two characters, including when it is
    /// the last character of the input.
    func testABackslashAtTheEndOfInputEndsTheText() {
        assertStrips(#"let s = "a\"#, to: ["let s = "])
    }

    func testNewlinesSurviveEveryConstructInOneSource() {
        assertStrips(
            #"""
            import Foundation // a comment
            /* a block
               /* nested */
               comment */
            let plain = "plain \"quoted\" // not a comment"
            let interpolated = "value \(plain)"
            let multi = """
                body
                """
            let broken = "unterminated
            let last = 0
            """#,
            to: [
                "import Foundation ",
                "",
                "",
                "",
                "let plain = ",
                "let interpolated = ",
                "let multi = ",
                "",
                "",
                "let broken = ",
                "let last = 0",
            ]
        )
    }
}
