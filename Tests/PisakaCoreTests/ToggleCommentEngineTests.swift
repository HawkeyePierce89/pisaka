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
                text: "// let x = 1\n",
                selectedRange: NSRange(location: 17, length: 0)
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
        // Last line: the caret stays on its own line, shifted by "// " (+3).
        let text = "abc"
        assertToggle(
            text,
            selectedRange: NSRange(location: 2, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 3),
                text: "// abc",
                selectedRange: NSRange(location: 5, length: 0) // 2 + 3 = 5
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
                text: "// a\n// b\n",
                selectedRange: NSRange(location: 0, length: 9) // newLength 10 minus the final terminator
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
                selectedRange: NSRange(location: 0, length: 3) // newLength 4 minus the final terminator
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
                text: "// //a\n// b\n",
                selectedRange: NSRange(location: 0, length: 11)
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
                text: "// a\n\n// b",
                selectedRange: NSRange(location: 0, length: 10)
            )
        )
    }

    func testFirstAndLastLineOfDocument() {
        let text = "a\nb"
        // Caret on first line
        assertToggle(text, selectedRange: NSRange(location: 0, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 2),
                text: "// a\n",
                selectedRange: NSRange(location: 5, length: 0)
            )
        )

        // Caret on last line
        assertToggle(text, selectedRange: NSRange(location: 3, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 2, length: 1),
                text: "// b",
                selectedRange: NSRange(location: 6, length: 0)
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
                text: "// a\n",
                selectedRange: NSRange(location: 0, length: 4)
            )
        )
    }

    func testNonLFLineSeparators() {
        let textCRLF = "a\r\nb"
        assertToggle(
            textCRLF,
            selectedRange: NSRange(location: 0, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 3),
                text: "// a\r\n",
                selectedRange: NSRange(location: 6, length: 0)
            )
        )

        let textCR = "a\rb"
        assertToggle(
            textCR,
            selectedRange: NSRange(location: 0, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 2),
                text: "// a\r",
                selectedRange: NSRange(location: 5, length: 0)
            )
        )

        let textNEL = "a\u{0085}b"
        assertToggle(
            textNEL,
            selectedRange: NSRange(location: 0, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 2),
                text: "// a\u{0085}",
                selectedRange: NSRange(location: 5, length: 0)
            )
        )

        let textLS = "a\u{2028}b"
        assertToggle(
            textLS,
            selectedRange: NSRange(location: 0, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 2),
                text: "// a\u{2028}",
                selectedRange: NSRange(location: 5, length: 0)
            )
        )

        let textPS = "a\u{2029}b"
        assertToggle(
            textPS,
            selectedRange: NSRange(location: 0, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 2),
                text: "// a\u{2029}",
                selectedRange: NSRange(location: 5, length: 0)
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
        ) // caret inside the removed token snaps to its start

        let text2 = "// x"
        assertToggle(text2, selectedRange: NSRange(location: 1, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 4),
                text: "x",
                selectedRange: NSRange(location: 0, length: 0)
            )
        ) // caret inside the removed token snaps to its start
    }

    func testOtherLanguages() {
        let text = "a"
        assertToggle(text, selectedRange: NSRange(location: 0, length: 0), language: .python,
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 1),
                text: "# a",
                selectedRange: NSRange(location: 2, length: 0)
            )
        )
        assertToggle(text, selectedRange: NSRange(location: 0, length: 0), language: .sql,
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 1),
                text: "-- a",
                selectedRange: NSRange(location: 3, length: 0)
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
                text: "// a",
                selectedRange: NSRange(location: 4, length: 0)
            )
        )
        assertToggle(text, selectedRange: NSRange(location: NSNotFound, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 1),
                text: "// a",
                selectedRange: NSRange(location: 4, length: 0)
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
                text: "/* color: red; */",
                selectedRange: NSRange(location: 3, length: 0)
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
                text: "  <!-- <p>a</p> -->\n",
                selectedRange: NSRange(location: 6, length: 19)
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
                selectedRange: NSRange(location: 2, length: 0) // clamped to start of comment
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
                text: "/* a /* b */ c */",
                selectedRange: NSRange(location: 3, length: 0)
            )
        )
    }

    func testBlockBlankLinesAtEdges() {
        // " \n a \n "
        let text = " \n a \n "
        assertToggle(text, selectedRange: NSRange(location: 0, length: 7), language: .css,
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 7),
                text: " \n /* a  */\n ",
                selectedRange: NSRange(location: 0, length: 13)
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

    func testShellSelectionRoundTrips() {
        let text = "set -e\nmake build\n"
        let selection = NSRange(location: 0, length: (text as NSString).length)

        guard let commented = ToggleCommentEngine.toggle(
            text: text as NSString, selectedRange: selection, language: .shell
        ) else {
            return XCTFail("shell should have a comment style to toggle")
        }
        XCTAssertTrue(commented.text.contains("# set -e"))
        XCTAssertTrue(commented.text.contains("# make build"))

        let onceCommented = (text as NSString)
            .replacingCharacters(in: commented.replacementRange, with: commented.text) as NSString
        guard let uncommented = ToggleCommentEngine.toggle(
            text: onceCommented, selectedRange: commented.selectedRange, language: .shell
        ) else {
            return XCTFail("a commented shell selection should toggle back")
        }
        let restored = onceCommented
            .replacingCharacters(in: uncommented.replacementRange, with: uncommented.text)
        XCTAssertEqual(restored, text)
    }

    func testMakeCaretLineInsertsAndRemovesTheHash() {
        let text = "build:\n\tswift build\n"
        assertToggle(
            text,
            selectedRange: NSRange(location: 2, length: 0),
            language: .make,
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 7),
                text: "# build:\n",
                selectedRange: NSRange(location: 11, length: 0) // caret moves to the next line, column 2
            )
        )
        assertToggle(
            "# build:\n\tswift build\n",
            selectedRange: NSRange(location: 4, length: 0),
            language: .make,
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 9),
                text: "build:\n",
                selectedRange: NSRange(location: 11, length: 0) // next line starts at 7, column 4
            )
        )
    }

    /// A recipe line keeps its leading tab — the character that makes it a
    /// recipe line to make — and the hash goes after it, so toggling twice
    /// restores the original line exactly.
    func testMakeRecipeLineKeepsItsTabBeforeTheHash() {
        let text = "build:\n\tswift build\n"
        let edit = ToggleCommentEngine.toggle(
            text: text as NSString, selectedRange: NSRange(location: 9, length: 0), language: .make
        )
        XCTAssertEqual(edit?.replacementRange, NSRange(location: 7, length: 13))
        XCTAssertEqual(edit?.text, "\t# swift build\n")

        let commented = "build:\n\t# swift build\n"
        let restore = ToggleCommentEngine.toggle(
            text: commented as NSString, selectedRange: NSRange(location: 11, length: 0), language: .make
        )
        XCTAssertEqual(restore?.replacementRange, NSRange(location: 7, length: 15))
        XCTAssertEqual(restore?.text, "\tswift build\n")
    }

    // MARK: - Multi-range plan and alignment

    private func apply(_ plan: RangeEditPlan, to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in plan.edits.reversed() {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }

    private func plan(
        _ text: String, _ ranges: [NSRange], language: SyntaxLanguage? = .swift
    ) -> RangeEditPlan? {
        ToggleCommentEngine.toggle(text: text as NSString, selectedRanges: ranges, language: language)
    }

    private func carets(_ locations: Int...) -> [NSRange] {
        locations.map { NSRange(location: $0, length: 0) }
    }

    func testMarkersAlignAtTheMinimumIndentationAndUncommentRestoresBytes() throws {
        let text = "    a\n        b\n"
        let all = [NSRange(location: 0, length: (text as NSString).length)]
        let commented = try XCTUnwrap(plan(text, all))
        let once = apply(commented, to: text)
        XCTAssertEqual(once, "    // a\n    //     b\n")
        XCTAssertEqual(commented.edits, [
            IndentReplacement(range: NSRange(location: 4, length: 0), replacement: "// "),
            IndentReplacement(range: NSRange(location: 10, length: 0), replacement: "// "),
        ])
        let uncommented = try XCTUnwrap(plan(once, commented.selections))
        XCTAssertEqual(apply(uncommented, to: once), text)
    }

    /// The single-range entry point aligns too: it is composed from the plan.
    func testSingleRangeEntryPointAligns() {
        let text = "    a\n        b"
        assertToggle(
            text,
            selectedRange: NSRange(location: 0, length: 15),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 15),
                text: "    // a\n    //     b",
                selectedRange: NSRange(location: 0, length: 21)
            )
        )
    }

    func testTheOlderPerLineFormStillUncomments() throws {
        let text = "    // a\n        // b\n"
        let commented = try XCTUnwrap(plan(text, [NSRange(location: 0, length: 21)]))
        XCTAssertEqual(apply(commented, to: text), "    a\n        b\n")
    }

    /// A tab is one UTF-16 unit, so a tab-indented line aligns a space-indented
    /// one at column 1.
    func testATabCountsAsOneUnitOfIndentation() throws {
        let text = "\ta\n    b"
        let commented = try XCTUnwrap(plan(text, [NSRange(location: 0, length: 8)]))
        XCTAssertEqual(apply(commented, to: text), "\t// a\n //    b")
    }

    /// The caret moves with the marker only when it sits at or past the
    /// insertion column.
    func testCaretDeltaAppliesFromTheInsertionColumn() {
        assertToggle("    abc", selectedRange: NSRange(location: 2, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 7),
                text: "    // abc",
                selectedRange: NSRange(location: 2, length: 0)
            )
        )
        assertToggle("    abc", selectedRange: NSRange(location: 4, length: 0),
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 7),
                text: "    // abc",
                selectedRange: NSRange(location: 7, length: 0)
            )
        )
    }

    func testAColumnSelectionCommentsEveryLine() throws {
        let text = "abc\ndef\nghi"
        let column = [1, 5, 9].map { NSRange(location: $0, length: 1) }
        let commented = try XCTUnwrap(plan(text, column))
        XCTAssertEqual(apply(commented, to: text), "// abc\n// def\n// ghi")
        XCTAssertEqual(commented.selections, [
            NSRange(location: 0, length: 6),
            NSRange(location: 7, length: 6),
            NSRange(location: 14, length: 6),
        ])
    }

    /// The regression the multi-range plan exists for: before it, only the
    /// first range's line was toggled.
    func testEveryRangeIsToggledNotOnlyTheFirst() throws {
        let text = "a\nb\nc\n"
        let commented = try XCTUnwrap(plan(text, carets(0, 4)))
        XCTAssertEqual(apply(commented, to: text), "// a\nb\n// c\n")
        // Each caret moves to the line below, column kept, as a single caret does.
        XCTAssertEqual(commented.selections, carets(5, 12))
    }

    /// One all-commented decision across the union: a commented line beside an
    /// uncommented one gains a second marker, never loses its own.
    func testOneDecisionAcrossEveryRange() throws {
        let text = "// a\nb\nc\n"
        let commented = try XCTUnwrap(plan(text, carets(0, 7)))
        XCTAssertEqual(apply(commented, to: text), "// // a\nb\n// c\n")
    }

    func testCaretsOnOneLineToggleItOnce() throws {
        let text = "abc\n"
        let commented = try XCTUnwrap(plan(text, carets(1, 2)))
        XCTAssertEqual(apply(commented, to: text), "// abc\n")
        XCTAssertEqual(commented.edits.count, 1)
    }

    func testBlankLinesAreNeverTouched() throws {
        let text = "    a\n\n  \n    b"
        let commented = try XCTUnwrap(plan(text, [NSRange(location: 0, length: 15)]))
        XCTAssertEqual(apply(commented, to: text), "    // a\n\n  \n    // b")
        XCTAssertNil(plan("\n  \n", carets(0, 1)))
    }

    func testEverySeparatorAcrossSeveralCarets() throws {
        for separator in ["\n", "\r", "\r\n", "\u{0085}", "\u{2028}", "\u{2029}"] {
            let text = "  a" + separator + "    b" + separator + "c"
            let secondLine = 3 + (separator as NSString).length
            let commented = try XCTUnwrap(plan(text, carets(0, secondLine)))
            XCTAssertEqual(
                apply(commented, to: text),
                "  // a" + separator + "  //   b" + separator + "c",
                "separator \(separator.unicodeScalars.map { $0.value })"
            )
        }
    }

    func testTwoCSSBlocksWrapAndUnwrapInOnePlan() throws {
        let text = "a\nb\nc"
        let wrapped = try XCTUnwrap(plan(text, carets(0, 4), language: .css))
        let once = apply(wrapped, to: text)
        XCTAssertEqual(once, "/* a */\nb\n/* c */")
        XCTAssertEqual(wrapped.edits.count, 2)

        let unwrapped = try XCTUnwrap(plan(once, carets(0, 10), language: .css))
        XCTAssertEqual(apply(unwrapped, to: once), text)
        XCTAssertEqual(unwrapped.edits.count, 2)
    }

    /// Adjacent ranges merge into one block, wrapped once and left as one
    /// selection over it.
    func testAdjacentCSSRangesMergeIntoOneWrap() throws {
        let text = "a\nb\nc"
        let wrapped = try XCTUnwrap(plan(text, carets(0, 2), language: .css))
        XCTAssertEqual(apply(wrapped, to: text), "/* a\nb */\nc")
        XCTAssertEqual(wrapped.selections, [NSRange(location: 0, length: 9)])
    }

    func testAnExplicitStyleOverridesTheLanguage() throws {
        let text = "a"
        let wrapped = try XCTUnwrap(ToggleCommentEngine.toggle(
            text: text as NSString, selectedRanges: carets(0), language: .swift, style: .block(open: "{/*", close: "*/}")
        ))
        XCTAssertEqual(apply(wrapped, to: text), "{/* a */}")
        XCTAssertNil(plan(text, carets(0), language: nil))
        XCTAssertNil(plan(text, carets(0), language: .json))
        XCTAssertNil(plan(text, [], language: .swift))
    }

    /// With one range, the plan's text and selection are the single-range
    /// engine's, for both styles, across carets and selections.
    func testASingleRangePlanMatchesTheSingleRangeEngine() throws {
        let texts = ["", "a", "  a\n    b\n", "// a\n//b", "x\r\n  y\r\nz", "/* a */\nb", "  \n a \n "]
        for language in [SyntaxLanguage.swift, .css, .html] {
            for text in texts {
                let length = (text as NSString).length
                for location in 0...length {
                    for selectionLength in 0...(length - location) {
                        let range = NSRange(location: location, length: selectionLength)
                        let label = "\(language) \(text.debugDescription) \(range)"
                        let single = ToggleCommentEngine.toggle(text: text as NSString, selectedRange: range, language: language)
                        let multi = plan(text, [range], language: language)
                        guard let single else {
                            XCTAssertNil(multi, label)
                            continue
                        }
                        let expected = (text as NSString).replacingCharacters(in: single.replacementRange, with: single.text)
                        let actual = try XCTUnwrap(multi, label)
                        XCTAssertEqual(apply(actual, to: text), expected, label)
                        XCTAssertEqual(actual.selections, [single.selectedRange], label)
                    }
                }
            }
        }
    }

    // MARK: - Contextual JSX style

    /// Toggle with `jsxLines` (0-based line indices) answering `.jsxChildren`.
    private func jsxPlan(_ text: String, _ ranges: [NSRange], jsxLines: Set<Int>,
                         language: SyntaxLanguage = .tsx) -> RangeEditPlan? {
        let ns = text as NSString
        return ToggleCommentEngine.toggle(text: ns, selectedRanges: ranges, language: language) { offset in
            let line = ns.substring(to: offset).components(separatedBy: "\n").count - 1
            return jsxLines.contains(line) ? .jsxChildren : .code
        }
    }

    private let jsxSource = """
    return (
      <div>
        <span>a</span>
        text
      </div>
    );
    """

    func testJSXChildrenWrapAndUnwrapWithBraces() throws {
        let caret = (jsxSource as NSString).range(of: "<span>").location
        let wrapped = apply(try XCTUnwrap(jsxPlan(jsxSource, carets(caret), jsxLines: [2, 3])), to: jsxSource)
        XCTAssertTrue(wrapped.contains("\n    {/* <span>a</span> */}\n"), wrapped)
        let again = (wrapped as NSString).range(of: "{/*").location
        let unwrapped = apply(try XCTUnwrap(jsxPlan(wrapped, carets(again), jsxLines: [2, 3])), to: wrapped)
        XCTAssertEqual(unwrapped, jsxSource)
    }

    func testJSXChildrenNeverGetALineComment() throws {
        let source = jsxSource as NSString
        let selection = NSRange(location: source.range(of: "<span>").location,
                                length: source.range(of: "text").location + 4 - source.range(of: "<span>").location)
        let result = apply(try XCTUnwrap(jsxPlan(jsxSource, [selection], jsxLines: [2, 3])), to: jsxSource)
        XCTAssertFalse(result.contains("// "), result)
        XCTAssertTrue(result.contains("{/* <span>a</span>\n    text */}"), result)
    }

    func testTwoSeparateJSXBlocksGetTwoWrapsInOnePlan() throws {
        let source = """
        <div>
          <a />
          <hr />
          <b />
        </div>
        """
        let ns = source as NSString
        let ranges = carets(ns.range(of: "<a").location, ns.range(of: "<b").location)
        let plan = try XCTUnwrap(jsxPlan(source, ranges, jsxLines: [1, 2, 3]))
        XCTAssertEqual(plan.edits.count, 2)
        let wrapped = apply(plan, to: source)
        XCTAssertTrue(wrapped.contains("  {/* <a /> */}\n  <hr />\n  {/* <b /> */}"), wrapped)
        let wrappedNS = wrapped as NSString
        let again = carets(wrappedNS.range(of: "{/* <a").location, wrappedNS.range(of: "{/* <b").location)
        XCTAssertEqual(apply(try XCTUnwrap(jsxPlan(wrapped, again, jsxLines: [1, 2, 3])), to: wrapped), source)
    }

    func testABlockOnlyHalfInJSXChildrenTakesTheLineStyle() throws {
        let source = "  <span />\n  foo()\n"
        let selection = NSRange(location: 0, length: (source as NSString).length)
        let result = apply(try XCTUnwrap(jsxPlan(source, [selection], jsxLines: [0])), to: source)
        XCTAssertEqual(result, "  // <span />\n  // foo()\n")
    }

    func testCodeAndJSXBlocksMixInOnePlan() throws {
        let source = """
        const x = 1
        return (
          <div>
            <span />
          </div>
        )
        """
        let ns = source as NSString
        let codeCaret = 0
        let jsxCaret = ns.range(of: "<span").location
        let plan = try XCTUnwrap(jsxPlan(source, carets(codeCaret, jsxCaret), jsxLines: [3]))
        let result = apply(plan, to: source)
        XCTAssertTrue(result.hasPrefix("// const x = 1\n"), result)
        XCTAssertTrue(result.contains("\n    {/* <span /> */}\n"), result)
        // Each caret moves to the next line at its column, as the single-range rules do.
        let resultNS = result as NSString
        XCTAssertEqual(plan.selections, [
            NSRange(location: resultNS.range(of: "return").location, length: 0),
            NSRange(location: resultNS.range(of: "  </div>").location + 4, length: 0),
        ])
    }

    func testNoJSXBlockMatchesThePlainToggle() throws {
        let ranges = carets(0, (jsxSource as NSString).range(of: "<span>").location)
        XCTAssertEqual(jsxPlan(jsxSource, ranges, jsxLines: []), plan(jsxSource, ranges, language: .tsx))
    }

    func testANonJSXLanguageNeverAsksTheContext() throws {
        let result = ToggleCommentEngine.toggle(
            text: "let a = 1" as NSString, selectedRanges: carets(0), language: .swift
        ) { _ in
            XCTFail("swift has no contextual style")
            return .code
        }
        XCTAssertEqual(apply(try XCTUnwrap(result), to: "let a = 1"), "// let a = 1")
    }
}
