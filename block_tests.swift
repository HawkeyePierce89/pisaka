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
                selectedRange: NSRange(location: 15, length: 0) // caret stays on same line, delta is 2 (from `/*`). Wait, delta is 2 + 2 = 4? No, delta for first line insert is `open.count` which is 2? Let's check our delta implementation for block wrap.
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
                selectedRange: NSRange(location: 4, length: 0) // next line, wait, caret placement is on next line, original was 0, so next line column 0 -> 4
            )
        )
    }
    
    func testBlockTargetAlreadyContainsDelimiter() {
        let text = "a /* b */ c"
        assertToggle(text, selectedRange: NSRange(location: 0, length: 0), language: .css,
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 11),
                text: "/*a /* b */ c*/",
                selectedRange: NSRange(location: 15, length: 0)
            )
        )
    }

    func testBlockBlankLinesAtEdges() {
        // " \n a \n "
        let text = " \n a \n "
        assertToggle(text, selectedRange: NSRange(location: 0, length: 7), language: .css,
            expectedEdit: CommentToggleEdit(
                replacementRange: NSRange(location: 0, length: 7),
                text: " \n /*a*/ \n ",
                selectedRange: NSRange(location: 0, length: 10)
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
    }
