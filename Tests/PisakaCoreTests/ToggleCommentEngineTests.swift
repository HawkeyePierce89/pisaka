import XCTest
@testable import PisakaCore

final class ToggleCommentEngineTests: XCTestCase {

    private func assertToggle(
        _ text: String,
        selectedRange: NSRange,
        language: SyntaxLanguage? = .swift,
        expectedEdit: CommentToggleEdit?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let nsText = text as NSString
        let edit = ToggleCommentEngine.toggle(text: nsText, selectedRange: selectedRange, language: language)
        XCTAssertEqual(edit, expectedEdit, file: file, line: line)
    }

    func testCaretOnUncommentedLine() {
        let text = "let x = 1\nlet y = 2"
        assertToggle(
            text,
            selectedRange: NSRange(location: 4, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 10),
                text: "//let x = 1\n",
                selectedRange: NSRange(location: 16, length: 0)
            )
        )
    }

    func testCaretOnAlreadyCommentedLine() {
        let text = "//let x = 1\nlet y = 2"
        assertToggle(
            text,
            selectedRange: NSRange(location: 6, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 12),
                text: "let x = 1\n",
                selectedRange: NSRange(location: 16, length: 0) // next line begins at 10. column was 6. 10 + 6 = 16
            )
        )
    }

    func testCaretColumnPreservationAndLastLine() {
        // Last line case. "abc" length 3. Caret at 2. Add "//" -> 5. Caret should be at 4.
        let text = "abc"
        assertToggle(
            text,
            selectedRange: NSRange(location: 2, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 3),
                text: "//abc",
                selectedRange: NSRange(location: 4, length: 0) // 2 + 2 = 4
            )
        )

        let textUncomment = "//abc"
        assertToggle(
            textUncomment,
            selectedRange: NSRange(location: 4, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 5),
                text: "abc",
                selectedRange: NSRange(location: 2, length: 0) // 4 - 2 = 2
            )
        )
    }

    func testSelectionOverUncommentedLines() {
        // "a\nb\nc" length 5. select "a\nb" (range 0..3). lines a, b touched.
        let text = "a\nb\nc"
        assertToggle(
            text,
            selectedRange: NSRange(location: 0, length: 3),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 4),
                text: "//a\n//b\n",
                selectedRange: NSRange(location: 0, length: 7) // text: "//a\n//b\n", newLength = 8, terminator is 1, so length 7
            )
        )
    }

    func testSelectionOverFullyCommentedLines() {
        let text = "//a\n//b\nc"
        assertToggle(
            text,
            selectedRange: NSRange(location: 0, length: 7),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 8),
                text: "a\nb\n",
                selectedRange: NSRange(location: 0, length: 3) // text: "a\nb\n", newLength = 4, terminator is 1, so length 3
            )
        )
    }

    func testSelectionOverMixedLines() {
        // Mixed should comment all.
        let text = "//a\nb\nc"
        assertToggle(
            text,
            selectedRange: NSRange(location: 0, length: 5),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 6),
                text: "////a\n//b\n",
                selectedRange: NSRange(location: 0, length: 9)
            )
        )
    }

    func testBlankLinesInsideSelection() {
        let text = "a\n\nb" // length 4
        assertToggle(
            text,
            selectedRange: NSRange(location: 0, length: 4),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 4),
                text: "//a\n\n//b",
                selectedRange: NSRange(location: 0, length: 8)
            )
        )
    }

    func testFirstAndLastLineOfDocument() {
        let text = "a\nb"
        // Caret on first line
        assertToggle(text, selectedRange: NSRange(location: 0, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 2),
                text: "//a\n",
                selectedRange: NSRange(location: 4, length: 0)
            )
        )

        // Caret on last line
        assertToggle(text, selectedRange: NSRange(location: 3, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 2, length: 1),
                text: "//b",
                selectedRange: NSRange(location: 5, length: 0)
            )
        )
    }

    func testSelectionEndingExactlyAtLineStart() {
        // "a\nb\n"
        // selection from 0 to 2 ("a\n") ends exactly at start of "b\n". Should not touch "b\n"
        let text = "a\nb\n"
        assertToggle(
            text,
            selectedRange: NSRange(location: 0, length: 2),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 2),
                text: "//a\n",
                selectedRange: NSRange(location: 0, length: 3)
            )
        )
    }

    func testCRLFCRNELLineSeparators() {
        let textCRLF = "a\r\nb"
        assertToggle(
            textCRLF,
            selectedRange: NSRange(location: 0, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 3),
                text: "//a\r\n",
                selectedRange: NSRange(location: 5, length: 0)
            )
        )

        let textCR = "a\rb"
        assertToggle(
            textCR,
            selectedRange: NSRange(location: 0, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 2),
                text: "//a\r",
                selectedRange: NSRange(location: 4, length: 0)
            )
        )

        let textNEL = "a\u{0085}b"
        assertToggle(
            textNEL,
            selectedRange: NSRange(location: 0, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 2),
                text: "//a\u{0085}",
                selectedRange: NSRange(location: 4, length: 0)
            )
        )
    }

    func testIndentedTokens() {
        let text = "  // a"
        assertToggle(
            text,
            selectedRange: NSRange(location: 0, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 6),
                text: "  a",
                selectedRange: NSRange(location: 0, length: 0)
            )
        )
    }

    func testBothRemovalSpellings() {
        // "//x" and "// x"
        let text1 = "//x"
        assertToggle(text1, selectedRange: NSRange(location: 1, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 3),
                text: "x",
                selectedRange: NSRange(location: 0, length: 0)
            )
        ) // 1 - 2 = 0

        let text2 = "// x"
        assertToggle(text2, selectedRange: NSRange(location: 1, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 4),
                text: "x",
                selectedRange: NSRange(location: 0, length: 0)
            )
        ) // 1 - 3 = 0
    }

    func testOtherLanguages() {
        let text = "a"
        assertToggle(text, selectedRange: NSRange(location: 0, length: 0), language: .python,
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 1),
                text: "#a",
                selectedRange: NSRange(location: 1, length: 0)
            )
        )
        assertToggle(text, selectedRange: NSRange(location: 0, length: 0), language: .sql,
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 1),
                text: "--a",
                selectedRange: NSRange(location: 2, length: 0)
            )
        )
    }

    func testEmptyDocument() {
        let text = ""
        assertToggle(text, selectedRange: NSRange(location: 0, length: 0), expectedEdit: nil)
    }

    func testBlankCaretLine() {
        let text = "   \n"
        assertToggle(text, selectedRange: NSRange(location: 0, length: 0), expectedEdit: nil)
    }

    func testJsonMarkdownNilLanguage() {
        let text = "a"
        assertToggle(text, selectedRange: NSRange(location: 0, length: 0), language: .json, expectedEdit: nil)
        assertToggle(text, selectedRange: NSRange(location: 0, length: 0), language: .markdown, expectedEdit: nil)
        assertToggle(text, selectedRange: NSRange(location: 0, length: 0), language: nil, expectedEdit: nil)
    }

    func testOutOfRangeSelection() {
        let text = "a"
        assertToggle(text, selectedRange: NSRange(location: 10, length: 10),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 1),
                text: "//a",
                selectedRange: NSRange(location: 3, length: 0)
            )
        )
        assertToggle(text, selectedRange: NSRange(location: NSNotFound, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 1),
                text: "//a",
                selectedRange: NSRange(location: 3, length: 0)
            )
        )
    }
    // MARK: - Block Mode Tests

    func testBlockWrapSingleCaretLine() {
        let text = "color: red;"
        assertToggle(
            text,
            selectedRange: NSRange(location: 0, length: 0),
            language: .css,
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 11),
                text: "/*color: red;*/",
                selectedRange: NSRange(location: 2, length: 0)
            )
        )
    }

    func testBlockUnwrapSingleCaretLine() {
        let text = "/* color: red; */"
        assertToggle(
            text,
            selectedRange: NSRange(location: 4, length: 0),
            language: .css,
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 17),
                text: "color: red;",
                selectedRange: NSRange(location: 1, length: 0) // removed "/* ", delta is -3
            )
        )
    }

    func testBlockWrapMultiLineSelection() {
        let text = "<div>\n  <p>a</p>\n</div>"
        // Select "<p>a</p>" (line 1)
        assertToggle(
            text,
            selectedRange: NSRange(location: 6, length: 10), // length of "  <p>a</p>" is 10
            language: .html,
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 6, length: 11),
                text: "  <!--<p>a</p>-->\n",
                selectedRange: NSRange(location: 6, length: 17)
            )
        )
    }

    func testBlockIndentedOpener() {
        let text = "  /* a */"
        assertToggle(
            text,
            selectedRange: NSRange(location: 3, length: 0),
            language: .css,
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 9),
                text: "  a",
                selectedRange: NSRange(location: 0, length: 0) // 3 - 3 = 0
            )
        )
    }

    func testBlockBothRemovalSpellings() {
        assertToggle("/*x*/", selectedRange: NSRange(location: 2, length: 0), language: .css,
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 5),
                text: "x",
                selectedRange: NSRange(location: 0, length: 0)
            )
        )
        assertToggle("/* x */", selectedRange: NSRange(location: 3, length: 0), language: .css,
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 7),
                text: "x",
                selectedRange: NSRange(location: 0, length: 0)
            )
        )
    }

    func testBlockTrailingWhitespaceAfterCloser() {
        let text = "/* a */  \n"
        assertToggle(text, selectedRange: NSRange(location: 0, length: 0), language: .css,
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 10),
                text: "a  \n",
                selectedRange: NSRange(location: 4, length: 0)
            )
        )
    }

    func testBlockTargetAlreadyContainsDelimiter() {
        let text = "a /* b */ c"
        assertToggle(text, selectedRange: NSRange(location: 0, length: 0), language: .css,
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 11),
                text: "/*a /* b */ c*/",
                selectedRange: NSRange(location: 2, length: 0)
            )
        )
    }

    func testBlockBlankLinesAtEdges() {
        // " \n a \n "
        let text = " \n a \n "
        assertToggle(text, selectedRange: NSRange(location: 0, length: 7), language: .css,
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 7),
                text: " \n /*a */\n ",
                selectedRange: NSRange(location: 0, length: 11)
            )
        )
    }

    func testBlockWhollyBlankTarget() {
        assertToggle("   \n  ", selectedRange: NSRange(location: 0, length: 6), language: .css, expectedEdit: nil)
    }

    func testBlockWrapUnwrapRoundTrip() {
        let original = "  a\n  b"
        let edit1 = ToggleCommentEngine.toggle(text: original as NSString, selectedRange: NSRange(location: 0, length: 7), language: .css)!
        let edit2 = ToggleCommentEngine.toggle(text: edit1.text as NSString, selectedRange: edit1.selectedRange, language: .css)!
        XCTAssertEqual(edit2.text, original)
        XCTAssertEqual(edit2.selectedRange, NSRange(location: 0, length: 7))
    }
}
