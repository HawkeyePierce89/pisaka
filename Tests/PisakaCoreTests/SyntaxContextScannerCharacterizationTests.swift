import XCTest
@testable import PisakaCore

/// Characterization goldens for `SyntaxContextScanner`.
///
/// These tests assert nothing about what is *right*. Every expectation in this
/// file was captured from the implementation as it stood before the scanner's
/// performance rework (the per-scan reader, the once-ordered string forms and
/// the two resumable validator cursors), and exists for exactly one purpose: to
/// prove that rework changed no answer anywhere. A golden that has to move is
/// therefore a behavior change, and must be justified by the item that changed
/// it — the intended-answer tests live in `SyntaxContextScannerTests` and
/// `SyntaxContextVocabularyTests`.
///
/// Each document is scanned at **every** offset `0…length` — not at a hand-
/// picked few — because the refactor's hazard is a boundary that shifts by one
/// character in a place nobody thought to sample. The resulting sequence is
/// run-length encoded (`12c,3s,5m` — `c` code, `s` string, `m` comment) so the
/// expectation stays readable and a diff names the run that moved.
///
/// The corpus is chosen to reach every validator branch rather than to look
/// like real files: quote-dense YAML with flow collections and comment-only
/// lines, HTML with attribute values, a `>` inside a value and an unclosed
/// comment, Swift pound padding and interpolation holes, Python prefixes and
/// f-string braces, Rust raw forms, Go raw literals, JSON, dotenv, gitignore,
/// editorconfig, Dockerfile, SQL, CSS, Markdown and a JavaScript template
/// literal.
///
/// To re-capture a golden after a *deliberate* behavior change: clear that
/// document's expectation to `[]`, run the suite, and read the `actual:` line
/// of the failure — it prints the encoding in the form this file commits.
final class SyntaxContextScannerCharacterizationTests: XCTestCase {

    // MARK: - Encoding

    private static func letter(_ context: SyntaxContext) -> String {
        switch context {
        case .code: return "c"
        case .string: return "s"
        case .comment: return "m"
        }
    }

    private static func encode(_ contexts: [SyntaxContext]) -> String {
        var runs: [String] = []
        var index = 0
        while index < contexts.count {
            var end = index + 1
            while end < contexts.count, contexts[end] == contexts[index] { end += 1 }
            runs.append("\(end - index)\(letter(contexts[index]))")
            index = end
        }
        return runs.joined(separator: ",")
    }

    /// The inverse of `encode`, used only to name the first offset that moved.
    private static func decode(_ golden: String) -> [SyntaxContext]? {
        var out: [SyntaxContext] = []
        for run in golden.split(separator: ",") {
            guard let last = run.last, let count = Int(run.dropLast()), count > 0 else { return nil }
            let context: SyntaxContext
            switch last {
            case "c": context = .code
            case "s": context = .string
            case "m": context = .comment
            default: return nil
            }
            out.append(contentsOf: Array(repeating: context, count: count))
        }
        return out
    }

    // MARK: - Assertion

    /// Scans `text` at every offset `0…length` and compares the run-length
    /// encoding against `golden` (whose fragments are concatenated, so a long
    /// expectation can wrap).
    private func assertGolden(
        _ name: String,
        _ text: String,
        language: SyntaxLanguage,
        golden: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ns = text as NSString
        var contexts: [SyntaxContext] = []
        contexts.reserveCapacity(ns.length + 1)
        for offset in 0...ns.length {
            contexts.append(SyntaxContextScanner.context(in: ns, at: offset, language: language))
        }
        let actual = Self.encode(contexts)
        let expected = golden.joined()
        guard actual != expected else { return }
        if let decoded = Self.decode(expected), decoded.count == contexts.count {
            for offset in 0...ns.length where decoded[offset] != contexts[offset] {
                XCTFail(
                    "\(name): offset \(offset) is \(contexts[offset]) but the golden says \(decoded[offset])",
                    file: file,
                    line: line
                )
                break
            }
        }
        XCTFail("\(name): golden mismatch\n  expected: \(expected)\n  actual:   \(actual)", file: file, line: line)
    }

    // MARK: - YAML

    /// Flow collections, a `#` inside a quoted scalar, doubled-quote escapes,
    /// a real trailing comment and a plain scalar whose quote is literal.
    func testYamlQuoteDenseGolden() {
        let text = [
            #"key: "value # not a comment""#,
            #"other: 'it''s fine'   # real comment"#,
            #"list: [a, "b # c", 'd']"#,
            #"map: {x: "1", y: '2'}"#,
            #"plain: say, "hello"#,
            #"# comment-only line"#,
            #"url: http://example.com#frag"#,
        ].joined(separator: "\n")
        assertGolden("yaml-flow", text, language: .yaml, golden: [
            "6c,22s,9c,3s,1c,7s,4c,14m,11c,6s,3c,2s,12c,2s,6c,2s,22c,19m,29c",
        ])
    }

    /// Block context: indentation, a block-sequence dash, a tight `key:"…"`
    /// (where the quote is literal) and an indented comment.
    func testYamlBlockGolden() {
        let text = [
            #"name: plain scalar"#,
            #"  nested: "q""#,
            #"- item one"#,
            #"- "quoted item""#,
            #"#leading hash"#,
            #"   # indented comment"#,
            #"key:"tight""#,
        ].joined(separator: "\n")
        assertGolden("yaml-block", text, language: .yaml, golden: [
            "30c,2s,15c,12s,2c,13m,4c,18m,12c",
        ])
    }

    // MARK: - HTML

    /// An attribute value holding `>`, a single-quoted attribute, a comment
    /// containing a quote, a quote outside any tag, an unclosed attribute and
    /// an unclosed comment running to the buffer end.
    func testHtmlGolden() {
        let text = [
            #"<div class="a > b" id='x'>"#,
            #"<!-- comment with " quote -->"#,
            #"<p>text "not an attribute"</p>"#,
            #"<input value="unclosed"#,
            #"<!-- unclosed comment"#,
        ].joined(separator: "\n")
        assertGolden("html", text, language: .html, golden: [
            "12c,6s,5c,2s,6c,25m,46c,9s,4c,18m",
        ])
    }

    // MARK: - Swift

    /// Interpolation, pound padding (which makes the hole inert at one pound
    /// count and live at another), both comment forms with nesting, and a
    /// multi-line literal.
    func testSwiftGolden() {
        let text = [
            #"let a = "hi \(name) there""#,
            ###"let b = #"raw \(no hole) here"#"###,
            ###"let c = ##"pad "# inside"##"###,
            #"// line comment "quoted""#,
            #"/* block /* nested */ still */"#,
            #"let d = """"""#,
            #"multi "line" here"#,
            #""""""#,
        ].joined(separator: "\n")
        assertGolden("swift", text, language: .swift, golden: [
            "9c,5s,5c,7s,11c,21s,12c,16s,3c,23m,2c,28m,12c,24s,1c,1s",
        ])
    }

    // MARK: - Python

    /// Prefixes in both cases, a raw literal where the backslash is inert, an
    /// f-string with a live hole and a doubled brace, and a triple-quoted
    /// literal spanning lines.
    func testPythonGolden() {
        let text = [
            #"s = 'single'"#,
            #"r = r'raw \' still'"#,
            #"f = f"val {x} and {{literal}}""#,
            #"t = '''tri"#,
            #"ple'''"#,
            #"# comment 'quoted'"#,
            #"b = B"bytes""#,
        ].joined(separator: "\n")
        assertGolden("python", text, language: .python, golden: [
            "5c,7s,7c,6s,7c,1s,6c,5s,2c,17s,7c,11s,2c,18m,6c,6s,1c",
        ])
    }

    // MARK: - Rust

    /// The escaped form, the pound-padded raw form, the byte-raw prefix and
    /// both comment forms including nesting.
    func testRustGolden() {
        let text = [
            #"let s = "esc \" in";"#,
            ###"let r = r#"raw "quote" here"#;"###,
            #"let b = br"bytes raw";"#,
            #"// comment "q""#,
            #"/* nested /* here */ done */"#,
        ].joined(separator: "\n")
        assertGolden("rust", text, language: .rust, golden: [
            "9c,10s,13c,18s,13c,10s,4c,13m,2c,26m,1c",
        ])
    }

    // MARK: - Go

    /// A raw backtick literal spanning lines, a rune literal and both comments.
    func testGoGolden() {
        let text = [
            #"s := "esc \" here""#,
            "r := `raw",
            "multi`",
            #"c := 'x'"#,
            #"// comment"#,
            #"/* block */"#,
        ].joined(separator: "\n")
        assertGolden("go", text, language: .go, golden: [
            "6c,12s,7c,10s,7c,2s,3c,9m,2c,9m,1c",
        ])
    }

    // MARK: - JSON

    /// Keys, values, an escaped quote and a `#` that is never a comment.
    func testJsonGolden() {
        let text = [
            #"{"key": "value", "n": 12,"#,
            ##" "nested": {"a": "b \" c"}, "hash": "# no"}"##,
        ].joined(separator: "\n")
        assertGolden("json", text, language: .json, golden: [
            "2c,4s,3c,6s,3c,2s,8c,7s,4c,2s,3c,7s,4c,5s,3c,5s,2c",
        ])
    }

    // MARK: - dotenv

    /// A trailing `#`, a `#` inside a quoted value, a full-line comment and an
    /// indented one.
    func testDotenvGolden() {
        let text = [
            #"KEY=value # comment"#,
            #"Q="quoted # not""#,
            #"S='single'"#,
            #"# full line"#,
            #"  INDENTED=1 # trailing"#,
        ].joined(separator: "\n")
        assertGolden("dotenv", text, language: .dotenv, golden: [
            "23c,13s,4c,7s,2c,11m,24c",
        ])
    }

    // MARK: - gitignore

    /// A true comment, an indented `#`, a negation and a trailing `#`.
    ///
    /// This is the one golden in the file that legitimately moved: the anchor
    /// vocabulary re-pointed gitignore from "first non-whitespace on the line"
    /// to true column zero, because gitignore(5) reads an indented `#` as a
    /// literal pattern rather than a comment. The `  # indented hash` run is
    /// therefore code now — the `15m` run in the previous expectation
    /// (`1c,9m,10c,15m,31c`) is gone and the code around it coalesced into one
    /// `56c`, while every other language's golden stays byte-identical.
    func testGitignoreGolden() {
        let text = [
            #"# comment"#,
            #"build/"#,
            #"  # indented hash"#,
            #"*.log"#,
            #"!keep.txt"#,
            #"path/with#hash"#,
        ].joined(separator: "\n")
        assertGolden("gitignore", text, language: .gitignore, golden: [
            "1c,9m,56c",
        ])
    }

    // MARK: - editorconfig

    /// Both comment tokens, a trailing `;` and an indented `;`.
    func testEditorconfigGolden() {
        let text = [
            #"root = true"#,
            #"[*.swift]"#,
            #"indent_style = space ; trailing"#,
            #"; comment"#,
            #"# hash comment"#,
            #"  ; indented"#,
        ].joined(separator: "\n")
        assertGolden("editorconfig", text, language: .editorconfig, golden: [
            "55c,9m,1c,14m,3c,10m",
        ])
    }

    // MARK: - Dockerfile

    /// A leading comment, a `#` inside a quoted argument, a trailing `#` and an
    /// indented comment.
    func testDockerfileGolden() {
        let text = [
            #"# comment"#,
            #"FROM alpine"#,
            #"RUN echo "hi # there""#,
            #"  # indented comment"#,
            #"LABEL x='y' # trailing"#,
        ].joined(separator: "\n")
        assertGolden("dockerfile", text, language: .dockerfile, golden: [
            "1c,9m,22c,11s,4c,18m,9c,2s,12c",
        ])
    }

    // MARK: - SQL

    /// The doubled-delimiter escape, the line comment, the block comment and a
    /// literal spanning lines.
    func testSqlGolden() {
        let text = [
            #"SELECT 'it''s' -- comment"#,
            #"FROM t /* block */"#,
            #"WHERE a = 'multi"#,
            #"line'"#,
        ].joined(separator: "\n")
        assertGolden("sql", text, language: .sql, golden: [
            "8c,3s,1c,2s,3c,9m,9c,9m,12c,11s,1c",
        ])
    }

    // MARK: - CSS

    /// Both quote forms and the one comment form, including a quote inside it.
    func testCssGolden() {
        let text = [
            #".a { content: "x"; }"#,
            #"/* comment "q" */"#,
            #".b::after { content: 'y'; }"#,
        ].joined(separator: "\n")
        assertGolden("css", text, language: .css, golden: [
            "15c,2s,6c,15m,23c,2s,4c",
        ])
    }

    // MARK: - Markdown

    /// No vocabulary at all: every offset must be code.
    func testMarkdownGolden() {
        let text = [
            #"# Heading"#,
            #"Some `code` and "quotes"."#,
            #"<!-- an html comment -->"#,
        ].joined(separator: "\n")
        assertGolden("markdown", text, language: .markdown, golden: [
            "61c",
        ])
    }

    // MARK: - JavaScript

    /// A template literal with a live hole, an escaped single quote and both
    /// comment forms (non-nesting).
    func testJavascriptGolden() {
        let text = [
            "const a = `tpl ${x + 1} end`;",
            #"const b = 'sq \' esc';"#,
            #"// line "q""#,
            #"/* block /* not nested */ out"#,
            #"const c = "dq";"#,
        ].joined(separator: "\n")
        assertGolden("javascript", text, language: .javascript, golden: [
            "11c,6s,6c,5s,13c,10s,4c,10m,2c,23m,16c,3s,2c",
        ])
    }

    // MARK: - Scaling

    /// The two validated-open walks — YAML flow depth and HTML inside-tag —
    /// must cost the scan roughly one visit per character, not one walk per
    /// candidate quote.
    ///
    /// Both used to restart from offset zero for every candidate, which is
    /// quadratic: a 4× document cost about 16× the character visits, and a
    /// quote-dense one much worse. The assertion is therefore a *shape*
    /// assertion — a 4× document must cost well under 6× the steps — and it
    /// reads `validatorStepCount`, a counter of characters actually visited,
    /// rather than a clock. That matters twice over: a wall-clock bound on a
    /// shared CI machine is noise the size of the effect it measures, and a
    /// re-walk from zero blows this count by an order of magnitude, which no
    /// scheduling jitter can either hide or fake.
    ///
    /// The upper bound is deliberately loose. Resuming is not free of constant
    /// factors — a query clamped by its own target leaves the cursor a few
    /// characters back and the next query re-walks them — so the measured
    /// ratio sits near 4 and the bound at 6 is the band between "linear with
    /// slack" and "quadratic".
    private func assertValidatorStepsScaleLinearly(
        _ name: String,
        block: String,
        language: SyntaxLanguage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        func steps(repeating count: Int) -> Int {
            let text = Array(repeating: block, count: count).joined(separator: "\n") as NSString
            return SyntaxContextScanner.validatorStepCount(in: text, at: text.length, language: language)
        }
        let small = steps(repeating: 16)
        let large = steps(repeating: 64)
        XCTAssertGreaterThan(
            small, 0,
            "\(name): the corpus must actually reach the validators, or the ratio proves nothing",
            file: file, line: line
        )
        XCTAssertLessThan(
            large, small * 6,
            "\(name): a 4× document cost \(large) validator steps against \(small) — "
                + "that is the walk-from-zero shape, not a resumed cursor",
            file: file, line: line
        )
    }

    func testYamlValidatorStepsScaleLinearly() {
        assertValidatorStepsScaleLinearly("yaml", block: [
            #"list: [a, "b # c", 'd']"#,
            #"map: {x: "1", y: '2'}"#,
            #"key: "value # not a comment""#,
            #"other: 'it''s fine'   # real comment"#,
        ].joined(separator: "\n"), language: .yaml)
    }

    func testHtmlValidatorStepsScaleLinearly() {
        assertValidatorStepsScaleLinearly("html", block: [
            #"<div class="a > b" id='x'>text</div>"#,
            #"<!-- comment with " quote -->"#,
            #"<input value="v" name='n'>"#,
        ].joined(separator: "\n"), language: .html)
    }
}
