import XCTest
@testable import PisakaCore

/// Exercises the per-language string/comment lexing that gates fallback
/// completion. Each rule in the plan's table gets its own test so a
/// failing case names the language and the delimiter that broke.
final class SyntaxContextScannerTests: XCTestCase {

    private func assertContext(
        _ text: String,
        at offset: Int,
        language: SyntaxLanguage,
        is expected: SyntaxContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ns = text as NSString
        let got = SyntaxContextScanner.context(in: ns, at: offset, language: language)
        XCTAssertEqual(got, expected, "text: \(text.debugDescription) offset: \(offset) language: \(language.rawValue)", file: file, line: line)
    }

    private func assertSuppress(
        _ text: String,
        at offset: Int,
        language: SyntaxLanguage,
        is expected: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ns = text as NSString
        let got = SyntaxContextScanner.suppressesCompletion(in: ns, at: offset, language: language)
        XCTAssertEqual(got, expected, "text: \(text.debugDescription) offset: \(offset) language: \(language.rawValue)", file: file, line: line)
    }

    // MARK: - Plain strings in each gated language

    func testSwiftDoubleQuotedString() {
        let text = "let s = \"hello\""
        //           0123456789 01234
        // indices: 0         1
        // s at offset inside string
        let inside = (text as NSString).range(of: "hello").location + 1
        assertContext(text, at: inside, language: .swift, is: .string)
        assertSuppress(text, at: inside, language: .swift, is: true)
        assertContext(text, at: 0, language: .swift, is: .code)
    }

    func testJavascriptSingleQuotedString() {
        let text = "const s = 'hello';"
        let inside = (text as NSString).range(of: "hello").location + 1
        assertContext(text, at: inside, language: .javascript, is: .string)
        assertSuppress(text, at: inside, language: .javascript, is: true)
    }

    func testTypeScriptDoubleQuotedString() {
        let text = "const s = \"hello\";"
        let inside = (text as NSString).range(of: "hello").location + 1
        assertContext(text, at: inside, language: .typescript, is: .string)
        assertSuppress(text, at: inside, language: .typescript, is: true)
    }

    func testPythonSingleQuotedString() {
        let text = "s = 'hello'"
        let inside = (text as NSString).range(of: "hello").location + 1
        assertContext(text, at: inside, language: .python, is: .string)
        assertSuppress(text, at: inside, language: .python, is: true)
    }

    func testGoDoubleQuotedString() {
        let text = "s := \"hello\""
        let inside = (text as NSString).range(of: "hello").location + 1
        assertContext(text, at: inside, language: .go, is: .string)
        assertSuppress(text, at: inside, language: .go, is: true)
    }

    func testRustDoubleQuotedString() {
        let text = "let s = \"hello\";"
        let inside = (text as NSString).range(of: "hello").location + 1
        assertContext(text, at: inside, language: .rust, is: .string)
        assertSuppress(text, at: inside, language: .rust, is: true)
    }

    func testCssSingleQuotedString() {
        let text = "@import 'hello';"
        let inside = (text as NSString).range(of: "hello").location + 1
        assertContext(text, at: inside, language: .css, is: .string)
        assertSuppress(text, at: inside, language: .css, is: true)
    }

    func testSqlSingleQuotedString() {
        let text = "SELECT 'hello'"
        let inside = (text as NSString).range(of: "hello").location + 1
        assertContext(text, at: inside, language: .sql, is: .string)
        assertSuppress(text, at: inside, language: .sql, is: true)
    }

    func testDockerfileDoubleQuotedString() {
        let text = "RUN echo \"hello\""
        let inside = (text as NSString).range(of: "hello").location + 1
        assertContext(text, at: inside, language: .dockerfile, is: .string)
        assertSuppress(text, at: inside, language: .dockerfile, is: true)
    }

    // MARK: - Multi-line forms

    func testSwiftTripleQuotedString() {
        let text = "let s = \"\"\"hello\nworld\"\"\""
        let inside = (text as NSString).range(of: "hello").location + 1
        assertContext(text, at: inside, language: .swift, is: .string)
    }

    func testPythonTripleQuotedString() {
        let text = "s = '''hello\nworld'''"
        let inside = (text as NSString).range(of: "hello").location + 1
        assertContext(text, at: inside, language: .python, is: .string)
    }

    func testJavaScriptBacktickTemplate() {
        let text = "const s = `hello\nworld`"
        let inside = (text as NSString).range(of: "hello").location + 1
        assertContext(text, at: inside, language: .javascript, is: .string)
    }

    func testGoRawBacktickString() {
        let text = "s := `hello\nworld`"
        let inside = (text as NSString).range(of: "hello").location + 1
        assertContext(text, at: inside, language: .go, is: .string)
    }

    // MARK: - Raw and pound-padded

    func testSwiftPoundPaddedString() {
        let text = "let s = #\"hello\"#"
        let inside = (text as NSString).range(of: "hello").location + 1
        assertContext(text, at: inside, language: .swift, is: .string)
        assertSuppress(text, at: inside, language: .swift, is: true)
    }

    func testSwiftDoublePoundPaddedString() {
        let text = "let s = ##\"hello\"##"
        let inside = (text as NSString).range(of: "hello").location + 1
        assertContext(text, at: inside, language: .swift, is: .string)
    }

    func testPythonRawString() {
        let text = "s = r'hello'"
        let inside = (text as NSString).range(of: "hello").location + 1
        assertContext(text, at: inside, language: .python, is: .string)
    }

    func testRustRawString() {
        let text = "let s = r#\"hello\"#;"
        let inside = (text as NSString).range(of: "hello").location + 1
        assertContext(text, at: inside, language: .rust, is: .string)
    }

    // MARK: - Escaped quote and backslash

    func testEscapedQuoteDoesNotClose() {
        // "a\"b" -> closing quote after escaped one
        let text = "\"a\\\"b\""
        // indices: 0:" 1:a 2:\ 3:" 4:b 5:" . Inside after escaped quote should still be string
        // Offset 4 (b) is inside
        assertContext(text, at: 4, language: .swift, is: .string)
        // Offset after final close -> code
        assertContext(text, at: 6, language: .swift, is: .code)
    }

    func testEscapedBackslashCloses() {
        // "a\\" -> first \ escapes second, then " closes
        let text = "\"a\\\\\""
        // 0:" 1:a 2:\ 3:\ 4:" . Inside at 1 is string, after close is code
        assertContext(text, at: 2, language: .javascript, is: .string)
        assertContext(text, at: 5, language: .javascript, is: .code)
    }

    func testDoubledDelimiterEscapeSQL() {
        let text = "'a''b'"
        // ' a ' ' b '  -> first ' opens, '' is escaped, final ' closes
        // Offset at b (index 4) inside
        assertContext(text, at: 4, language: .sql, is: .string)
        assertContext(text, at: 6, language: .sql, is: .code)
    }

    func testDoubledDelimiterEscapeYAML() {
        let text = "'a''b'"
        assertContext(text, at: 4, language: .yaml, is: .string)
        // YAML strings are ungated
        assertSuppress(text, at: 4, language: .yaml, is: false)
    }

    // MARK: - Unterminated strings

    func testUnterminatedSingleLineEndsAtLineSeparator() {
        let text = "\"hello\nworld"
        // hello inside string, world after newline is code
        let helloInside = (text as NSString).range(of: "hello").location + 1
        assertContext(text, at: helloInside, language: .javascript, is: .string)
        let worldOffset = (text as NSString).range(of: "world").location + 1
        assertContext(text, at: worldOffset, language: .javascript, is: .code)
    }

    func testUnterminatedMultiLineRunsToEnd() {
        let text = "`hello"
        // backtick multi-line unterminated -> caret at end is inside
        assertContext(text, at: 3, language: .javascript, is: .string)
        assertContext(text, at: text.utf16.count, language: .javascript, is: .string)
    }

    // MARK: - Boundary offsets

    func testFourBoundariesAroundDelimiter() {
        let text = "\"a\""
        // 0:" 1:a 2:" len3
        assertContext(text, at: 0, language: .swift, is: .code) // before open
        assertContext(text, at: 1, language: .swift, is: .string) // after open
        assertContext(text, at: 2, language: .swift, is: .string) // before close (still inside)
        assertContext(text, at: 3, language: .swift, is: .code) // after close
    }

    func testCaretBetweenTwoCharsOfLineCommentIsCode() {
        let text = "// hello"
        assertContext(text, at: 0, language: .swift, is: .code)
        assertContext(text, at: 1, language: .swift, is: .code) // between //
        assertContext(text, at: 2, language: .swift, is: .comment)
    }

    // MARK: - Line and block comments

    func testLineCommentToEndOfLine() {
        let text = "code // comment\nnext"
        let inside = (text as NSString).range(of: "comment").location + 1
        assertContext(text, at: inside, language: .swift, is: .comment)
        assertSuppress(text, at: inside, language: .swift, is: true)
        let nextOffset = (text as NSString).range(of: "next").location + 1
        assertContext(text, at: nextOffset, language: .swift, is: .code)
    }

    func testBlockCommentAcrossLines() {
        let text = "code /* comment\nstill */ next"
        let inside = (text as NSString).range(of: "comment").location + 1
        assertContext(text, at: inside, language: .swift, is: .comment)
        let nextOffset = (text as NSString).range(of: "next").location + 1
        assertContext(text, at: nextOffset, language: .swift, is: .code)
    }

    func testNestedBlockCommentSwift() {
        let text = "/* outer /* inner */ still */ code"
        let inner = (text as NSString).range(of: "inner").location + 1
        assertContext(text, at: inner, language: .swift, is: .comment)
        let still = (text as NSString).range(of: "still").location + 1
        assertContext(text, at: still, language: .swift, is: .comment)
        let after = (text as NSString).range(of: "code").location + 1
        assertContext(text, at: after, language: .swift, is: .code)
    }

    func testNestedBlockCommentRust() {
        let text = "/* outer /* inner */ still */ code"
        let inner = (text as NSString).range(of: "inner").location + 1
        assertContext(text, at: inner, language: .rust, is: .comment)
    }

    func testNonNestingBlockComment() {
        let text = "/* outer /* inner */ code"
        // JS non-nesting: after first */ comment ends
        let codeOff = (text as NSString).range(of: "code").location + 1
        assertContext(text, at: codeOff, language: .javascript, is: .code)
    }

    func testHashInsideStringIsNotComment() {
        let text = "\"a # b\""
        let hashOff = (text as NSString).range(of: "#").location + 1
        assertContext(text, at: hashOff, language: .python, is: .string)
    }

    func testSlashSlashInsideStringIsNotComment() {
        let text = "\"a // b\""
        let slashOff = (text as NSString).range(of: "//").location + 1
        assertContext(text, at: slashOff, language: .swift, is: .string)
    }

    func testQuoteInsideCommentDoesNotOpenString() {
        let text = "// \"hello\""
        let helloOff = (text as NSString).range(of: "hello").location + 1
        assertContext(text, at: helloOff, language: .swift, is: .comment)
    }

    // MARK: - Interpolation holes

    func testJsTemplateHoleIsCode() {
        let text = "`a${b}c`"
        let bOff = (text as NSString).range(of: "b").location + 1
        assertContext(text, at: bOff, language: .javascript, is: .code)
        assertSuppress(text, at: bOff, language: .javascript, is: false)
    }

    func testSwiftInterpolationHoleIsCode() {
        let text = "\"a\\(b)c\""
        let bOff = (text as NSString).range(of: "b").location + 1
        // Need swift text with interpolation
        assertContext(text, at: bOff, language: .swift, is: .code)
        assertSuppress(text, at: bOff, language: .swift, is: false)
    }

    func testSwiftPoundInterpolationHoleIsCode() {
        let text = "#\"a\\#(b)c\"#"
        let bOff = (text as NSString).range(of: "b").location + 1
        assertContext(text, at: bOff, language: .swift, is: .code)
    }

    func testPythonFStringHoleIsCode() {
        let text = "f\"{user}\""
        let userOff = (text as NSString).range(of: "user").location + 1
        assertContext(text, at: userOff, language: .python, is: .code)
        assertSuppress(text, at: userOff, language: .python, is: false)
    }

    func testPythonDoubleBraceLiteralStaysString() {
        let text = "f\"{{hello}}\""
        let helloOff = (text as NSString).range(of: "hello").location + 1
        assertContext(text, at: helloOff, language: .python, is: .string)
        assertSuppress(text, at: helloOff, language: .python, is: true)
    }

    func testBraceDepthInsideHole() {
        let text = "`a${ {a: 1} }c`"
        // The inner `}` before space should still be inside hole (code)
        // Find the first `a:` location
        let aOff = (text as NSString).range(of: "a:").location + 1
        assertContext(text, at: aOff, language: .javascript, is: .code)
    }

    func testStringNestedInsideHole() {
        let text = "`a${ \"b\" }c`"
        let bOff = (text as NSString).range(of: "\"b\"").location + 2 // inside b
        // The b is inside a string inside a hole -> string context, gated
        // Note: scanner should report .string for b because hole contains string
        // Use JS language
        assertContext(text, at: bOff, language: .javascript, is: .string)
        assertSuppress(text, at: bOff, language: .javascript, is: true)
    }

    // MARK: - Anchored comments

    func testDockerfileHashMidLineNotComment() {
        let text = "RUN echo hi # comment"
        let hashOff = (text as NSString).range(of: "#").location + 1
        assertContext(text, at: hashOff, language: .dockerfile, is: .code)
        assertSuppress(text, at: hashOff, language: .dockerfile, is: false)
    }

    func testDockerfileHashAtLineStartIsComment() {
        let text = "# comment"
        let comOff = (text as NSString).range(of: "comment").location + 1
        assertContext(text, at: comOff, language: .dockerfile, is: .comment)
        assertSuppress(text, at: comOff, language: .dockerfile, is: true)
    }

    func testGitignoreHashMidLineNotComment() {
        let text = "foo # bar"
        let hashOff = (text as NSString).range(of: "#").location + 1
        assertContext(text, at: hashOff, language: .gitignore, is: .code)
    }

    /// gitignore(5): a line is a comment only when it *begins* with `#`.
    func testGitignoreHashAtTrueLineStartIsComment() {
        let text = "build/\n# comment\n*.log"
        let comOff = (text as NSString).range(of: "comment").location + 1
        assertContext(text, at: comOff, language: .gitignore, is: .comment)
        assertSuppress(text, at: comOff, language: .gitignore, is: true)
    }

    /// The indented `#` is a literal pattern character — it matches a file whose
    /// name starts with a hash — so completion is offered on that line.
    func testGitignoreIndentedHashIsPatternNotComment() {
        let text = "build/\n  # indented\n*.log"
        let patOff = (text as NSString).range(of: "indented").location + 1
        assertContext(text, at: patOff, language: .gitignore, is: .code)
        assertSuppress(text, at: patOff, language: .gitignore, is: false)
    }

    /// A gitignore `#` at the very first offset of the buffer is a comment too —
    /// offset 0 is a true line start with no separator before it.
    func testGitignoreHashAtBufferStartIsComment() {
        let text = "# comment\nbuild/"
        let comOff = (text as NSString).range(of: "comment").location + 1
        assertContext(text, at: comOff, language: .gitignore, is: .comment)
    }

    func testEditorconfigHashMidLineNotComment() {
        let text = "key = value # comment"
        let hashOff = (text as NSString).range(of: "#").location + 1
        assertContext(text, at: hashOff, language: .editorconfig, is: .code)
    }

    /// The three `.afterIndent` languages skip leading whitespace before the
    /// comment token, the way each format's own reader does — editorconfig's
    /// citation being this repository's `EditorConfigFile`, which trims the line
    /// and then tests `#`/`;`.
    func testIndentedHashIsCommentForTheAfterIndentLanguages() {
        for language in [SyntaxLanguage.dockerfile, .dotenv, .editorconfig] as [SyntaxLanguage] {
            let text = "A=1\n   # indented\nB=2"
            let comOff = (text as NSString).range(of: "indented").location + 1
            assertContext(text, at: comOff, language: language, is: .comment)
        }
    }

    func testEditorconfigIndentedSemicolonIsComment() {
        let text = "root = true\n  ; indented\n[*]"
        let comOff = (text as NSString).range(of: "indented").location + 1
        assertContext(text, at: comOff, language: .editorconfig, is: .comment)
    }

    /// dotenv declares `.none` for both quote forms, so the first matching quote
    /// closes the literal and a backslash before it escapes nothing. The `x`
    /// after that quote is therefore code, not a continuation of the string.
    func testDotenvLiteralClosesAtFirstMatchingQuote() {
        let text = "KEY=\"a\\\"x\""
        let ns = text as NSString
        let aOff = ns.range(of: "a").location + 1
        let xOff = ns.range(of: "x").location + 1
        assertContext(text, at: aOff, language: .dotenv, is: .string)
        assertContext(text, at: xOff, language: .dotenv, is: .code)
    }

    func testYamlHashAfterWhitespaceIsComment() {
        let text = "key: value # comment"
        let comOff = (text as NSString).range(of: "comment").location + 1
        assertContext(text, at: comOff, language: .yaml, is: .comment)
        assertSuppress(text, at: comOff, language: .yaml, is: true)
    }

    func testYamlHashMidLineWithoutWhitespaceNotComment() {
        let text = "key: value#not"
        let hashOff = (text as NSString).range(of: "#").location + 1
        assertContext(text, at: hashOff, language: .yaml, is: .code)
    }

    func testYamlHashInsideQuotedScalarNotComment() {
        let text = "key: \"a # b\""
        let hashOff = (text as NSString).range(of: "#").location + 1
        assertContext(text, at: hashOff, language: .yaml, is: .string)
        assertSuppress(text, at: hashOff, language: .yaml, is: false)
    }

    // MARK: - Rust lifetime

    func testRustLifetimeLeavesRestAsCode() {
        let text = "fn foo(x: &'a str) {}"
        // The 'a is lifetime, not string; after it, code
        let after = (text as NSString).range(of: "str").location + 1
        assertContext(text, at: after, language: .rust, is: .code)
        // The single quote itself should not open string
        let quoteOff = (text as NSString).range(of: "'a").location + 1 // at a
        assertContext(text, at: quoteOff, language: .rust, is: .code)
    }

    // MARK: - Markdown always code

    func testMarkdownAlwaysCode() {
        let text = "\"hello\" // comment /* block */"
        for off in [1, 5, 10, 15, text.utf16.count] {
            assertContext(text, at: off, language: .markdown, is: .code)
            assertSuppress(text, at: off, language: .markdown, is: false)
        }
    }

    // MARK: - JSON

    func testJsonStringReportedButNotGated() {
        let text = "{\"key\": \"value\"}"
        let valOff = (text as NSString).range(of: "value").location + 1
        assertContext(text, at: valOff, language: .json, is: .string)
        assertSuppress(text, at: valOff, language: .json, is: false)
    }

    func testYamlStringNotGated() {
        let text = "'hello'"
        let inside = (text as NSString).range(of: "hello").location + 1
        assertContext(text, at: inside, language: .yaml, is: .string)
        assertSuppress(text, at: inside, language: .yaml, is: false)
    }

    func testHtmlStringNotGated() {
        let text = "<div class=\"foo\">"
        let fooOff = (text as NSString).range(of: "foo").location + 1
        assertContext(text, at: fooOff, language: .html, is: .string)
        assertSuppress(text, at: fooOff, language: .html, is: false)
    }

    func testDotenvStringNotGated() {
        let text = "KEY=\"value\""
        let valOff = (text as NSString).range(of: "value").location + 1
        assertContext(text, at: valOff, language: .dotenv, is: .string)
        assertSuppress(text, at: valOff, language: .dotenv, is: false)
    }

    func testHtmlBlockComment() {
        let text = "<!-- comment --> code"
        let comOff = (text as NSString).range(of: "comment").location + 1
        assertContext(text, at: comOff, language: .html, is: .comment)
        assertSuppress(text, at: comOff, language: .html, is: true)
    }

    // MARK: - Chunk boundaries

    /// The per-scan reader loads `chunkSize` UTF-16 units at a time and the
    /// sequential outer loop is the only thing that moves the window; every
    /// look-ahead past its end and every backwards walk below its start falls
    /// back to a direct `NSString` read. **Nothing else in this suite is long
    /// enough to leave one chunk** — the goldens' documents are tens of
    /// characters and the scaling documents assert only a step count — so these
    /// are the only tests that exercise the fallback at all. Replacing it with a
    /// constant leaves every other scanner test in the repository green.
    ///
    /// Each case therefore places a delimiter *across* the boundary rather than
    /// merely past it, which is the hazard the refactor's doc comment names.

    private func assertContextAtBoundary(
        _ text: String,
        at offset: Int,
        language: SyntaxLanguage,
        is expected: SyntaxContext,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let got = SyntaxContextScanner.context(in: text as NSString, at: offset, language: language)
        XCTAssertEqual(got, expected, "\(what) (offset \(offset))", file: file, line: line)
    }

    /// `/*` split across the boundary: the `/` is the last unit of one chunk and
    /// the `*` the first of the next, so recognizing the opener needs the read
    /// past the chunk's end.
    func testABlockCommentOpenerStraddlingTheChunkBoundaryStillOpens() {
        let boundary = SyntaxContextScanner.chunkSize
        let text = String(repeating: "x", count: boundary - 1) + "/* comment */ after"
        XCTAssertEqual((text as NSString).character(at: boundary - 1), 47, "the `/` must sit at the last unit")

        assertContextAtBoundary(
            text, at: boundary + 4, language: .swift, is: .comment,
            "a block comment whose opener straddles the chunk boundary"
        )
        assertContextAtBoundary(
            text, at: (text as NSString).length, language: .swift, is: .code,
            "…and still closes"
        )
    }

    /// The mirror: `*/` split across the boundary. A closer that is not seen
    /// leaves the rest of the file inside a comment forever.
    func testABlockCommentCloserStraddlingTheChunkBoundaryStillCloses() {
        let boundary = SyntaxContextScanner.chunkSize
        let head = "/*"
        let text = head + String(repeating: "x", count: boundary - 1 - head.count) + "*/ after"
        XCTAssertEqual((text as NSString).character(at: boundary - 1), 42, "the `*` must sit at the last unit")

        assertContextAtBoundary(
            text, at: boundary - 10, language: .swift, is: .comment,
            "inside the comment, before the boundary"
        )
        assertContextAtBoundary(
            text, at: (text as NSString).length, language: .swift, is: .code,
            "a block comment whose closer straddles the chunk boundary must still close"
        )
    }

    /// A three-unit opener (`"""`) split two-one across the boundary — the
    /// longest delimiter the vocabulary orders first, and the one whose partial
    /// match would otherwise read as an empty `""` literal.
    func testAMultiLineStringOpenerStraddlingTheChunkBoundaryStillOpens() {
        let boundary = SyntaxContextScanner.chunkSize
        let text = String(repeating: "x", count: boundary - 2) + "\"\"\"\nbody\n\"\"\" after"

        assertContextAtBoundary(
            text, at: boundary + 3, language: .swift, is: .string,
            "a multi-line string whose opener straddles the chunk boundary"
        )
        assertContextAtBoundary(
            text, at: (text as NSString).length, language: .swift, is: .code,
            "…and still closes"
        )
    }

    /// The *backwards* direction, which no forward look-ahead covers: an
    /// `.afterIndent` comment token whose line begins in the previous chunk, so
    /// deciding whether only whitespace precedes it reads below the window's
    /// start.
    func testAnAfterIndentCommentWhoseLineBeganInThePreviousChunkStillOpens() {
        let boundary = SyntaxContextScanner.chunkSize
        let lineStart = boundary - 96
        let filler = String(repeating: "x\n", count: lineStart / 2)
        XCTAssertEqual((filler as NSString).length, lineStart)

        let indent = String(repeating: " ", count: 300)
        let text = filler + indent + "# comment"
        let hash = lineStart + indent.count
        XCTAssertGreaterThan(hash, boundary, "the token must be read from the second chunk")
        XCTAssertLessThan(lineStart, boundary, "…while its line begins in the first")

        assertContextAtBoundary(
            text, at: hash + 3, language: .editorconfig, is: .comment,
            "an indented comment whose line begins in the previous chunk"
        )
    }

    // MARK: - Out of range

    func testNegativeOffsetIsCode() {
        assertContext("hello", at: -1, language: .swift, is: .code)
        assertSuppress("hello", at: -1, language: .swift, is: false)
    }

    func testOutOfRangeOffsetIsCode() {
        let text = "hello"
        assertContext(text, at: 100, language: .swift, is: .code)
        assertSuppress(text, at: 100, language: .swift, is: false)
    }

    func testZeroOffsetIsCode() {
        assertContext("\"hello\"", at: 0, language: .swift, is: .code)
    }

    // MARK: - Comment gating still true

    func testYamlCommentGated() {
        let text = "# comment\nother"
        let comOff = (text as NSString).range(of: "comment").location + 1
        assertContext(text, at: comOff, language: .yaml, is: .comment)
        assertSuppress(text, at: comOff, language: .yaml, is: true)
    }

    func testJsonNoComment() {
        let text = "// comment"
        assertContext(text, at: 5, language: .json, is: .code)
    }
}
