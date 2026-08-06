import XCTest
@testable import PisakaCore

final class MinimapModelTests: XCTestCase {
    /// Build a per-UTF-16-unit kind array of `.plain` for `text`.
    private func plainKinds(for text: String) -> [SyntaxTokenKind] {
        Array(repeating: .plain, count: (text as NSString).length)
    }

    func testEmptyTextIsOneEmptyLine() {
        let model = MinimapModel.build(text: "", kinds: [])
        XCTAssertEqual(model.runs, [[]])
        XCTAssertEqual(model.lineCount, 1)
    }

    func testSingleLineNoTrailingNewline() {
        let text = "abc"
        let model = MinimapModel.build(text: text, kinds: plainKinds(for: text))
        XCTAssertEqual(model.runs, [[MinimapTokenRun(column: 0, length: 3, kind: .plain)]])
    }

    func testTrailingNewlineAddsEmptyLine() {
        let text = "abc\n"
        let model = MinimapModel.build(text: text, kinds: plainKinds(for: text))
        XCTAssertEqual(model.lineCount, 2)
        XCTAssertEqual(model.runs[0], [MinimapTokenRun(column: 0, length: 3, kind: .plain)])
        XCTAssertEqual(model.runs[1], [])
    }

    func testAllWhitespaceLineHasNoRuns() {
        let text = "   \t  "
        let model = MinimapModel.build(text: text, kinds: plainKinds(for: text))
        XCTAssertEqual(model.runs, [[]])
    }

    func testLeadingAndTrailingWhitespaceColumns() {
        // "  ab  " → one run starting at column 2, length 2.
        let text = "  ab  "
        let model = MinimapModel.build(text: text, kinds: plainKinds(for: text))
        XCTAssertEqual(model.runs, [[MinimapTokenRun(column: 2, length: 2, kind: .plain)]])
    }

    func testWhitespaceSplitsRunsOnSameLine() {
        // "ab cd" → two runs separated by the space.
        let text = "ab cd"
        let model = MinimapModel.build(text: text, kinds: plainKinds(for: text))
        XCTAssertEqual(
            model.runs,
            [[
                MinimapTokenRun(column: 0, length: 2, kind: .plain),
                MinimapTokenRun(column: 3, length: 2, kind: .plain),
            ]]
        )
    }

    func testAdjacentRunsOfDifferentKindsSplitWithoutWhitespace() {
        // "ab" where 'a' is a keyword and 'b' is plain: split into two runs even
        // though no whitespace separates them.
        let text = "ab"
        var kinds = plainKinds(for: text)
        kinds[0] = .keyword
        let model = MinimapModel.build(text: text, kinds: kinds)
        XCTAssertEqual(
            model.runs,
            [[
                MinimapTokenRun(column: 0, length: 1, kind: .keyword),
                MinimapTokenRun(column: 1, length: 1, kind: .plain),
            ]]
        )
    }

    func testMultiLineMixColumnsAreLineRelative() {
        // Line 0: "x = 1", line 1: "  y" (indented). Columns reset per line.
        let text = "x = 1\n  y"
        let model = MinimapModel.build(text: text, kinds: plainKinds(for: text))
        XCTAssertEqual(model.lineCount, 2)
        XCTAssertEqual(
            model.runs[0],
            [
                MinimapTokenRun(column: 0, length: 1, kind: .plain), // x
                MinimapTokenRun(column: 2, length: 1, kind: .plain), // =
                MinimapTokenRun(column: 4, length: 1, kind: .plain), // 1
            ]
        )
        XCTAssertEqual(model.runs[1], [MinimapTokenRun(column: 2, length: 1, kind: .plain)]) // y at col 2
    }

    func testKindsShorterThanTextTreatedAsPlainWithoutCrashing() {
        // A short kinds array must not trap; missing positions default to .plain.
        // Position 0 is a keyword; positions 1-2 fall past the array → .plain, so
        // the kind change splits the line into two runs.
        let text = "abc"
        let model = MinimapModel.build(text: text, kinds: [.keyword])
        XCTAssertEqual(
            model.runs,
            [[
                MinimapTokenRun(column: 0, length: 1, kind: .keyword),
                MinimapTokenRun(column: 1, length: 2, kind: .plain),
            ]]
        )
    }

    func testUnicodeLineSeparatorsAreNotRenderedAsRuns() {
        // NEL / LINE SEPARATOR / PARAGRAPH SEPARATOR delimit lines (LineStartIndex
        // splits on them), and a line's span includes its trailing separator. They
        // are invisible, so they must not surface as a spurious one-character run
        // at the end of each line.
        for separator in ["\u{85}", "\u{2028}", "\u{2029}"] {
            let text = "a\(separator)b"
            let model = MinimapModel.build(text: text, kinds: plainKinds(for: text))
            XCTAssertEqual(model.lineCount, 2, "separator U+\(String(format: "%04X", (separator as NSString).character(at: 0)))")
            XCTAssertEqual(
                model.runs[0],
                [MinimapTokenRun(column: 0, length: 1, kind: .plain)],
                "line 0 should hold only 'a', not the separator"
            )
            XCTAssertEqual(model.runs[1], [MinimapTokenRun(column: 0, length: 1, kind: .plain)])
        }
    }

    func testEmptyModelHasNoLines() {
        XCTAssertEqual(MinimapModel.empty.lineCount, 0)
        XCTAssertEqual(MinimapModel.empty.runs, [])
    }
}
