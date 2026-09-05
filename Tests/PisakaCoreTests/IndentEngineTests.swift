import XCTest
@testable import PisakaCore

final class IndentEngineTests: XCTestCase {
    private func inferUnit(_ s: String) -> String {
        IndentEngine.inferIndentUnit(text: s as NSString)
    }

    // MARK: - inferIndentUnit

    func testTabsDetected() {
        let text = "func f() {\n\tlet x = 1\n}\n"
        XCTAssertEqual(inferUnit(text), "\t")
    }

    func testTwoSpaceDetected() {
        let text = "func f() {\n  let x = 1\n}\n"
        XCTAssertEqual(inferUnit(text), "  ")
    }

    func testFourSpaceDetected() {
        let text = "func f() {\n    let x = 1\n}\n"
        XCTAssertEqual(inferUnit(text), "    ")
    }

    func testSmallestSpaceStepWins() {
        // Nested indentation: 2 then 4 spaces — the smallest step is the unit.
        let text = "a {\n  b {\n    c\n  }\n}\n"
        XCTAssertEqual(inferUnit(text), "  ")
    }

    func testEmptyFileFallsBackToFourSpaces() {
        XCTAssertEqual(inferUnit(""), "    ")
    }

    func testUnindentedFileFallsBackToFourSpaces() {
        let text = "let a = 1\nlet b = 2\n"
        XCTAssertEqual(inferUnit(text), "    ")
    }

    func testTabsWinOverSpaceLines() {
        // A file that indents with tabs but also has a space-prefixed line still
        // resolves to a tab unit.
        let text = "{\n\tx\n  y\n}\n"
        XCTAssertEqual(inferUnit(text), "\t")
    }

    func testSingleSpaceRunDoesNotSkewUnit() {
        // A four-space file carrying one C-family block comment: the ` * …`
        // continuation lines start with exactly one space, which is comment
        // alignment, not indentation. Counting it would infer a one-space unit —
        // Enter would then append one space after `{`, and the editor's
        // indentation-level painting would cycle its whole palette inside a
        // single level.
        let text = "/**\n * Does a thing.\n */\nfunction a() {\n    return 1;\n}\n"
        XCTAssertEqual(inferUnit(text), "    ")
    }

    func testTwoSpaceFileWithABlockCommentStillInfersTwo() {
        // The same skip must not floor the answer at anything: a genuinely
        // two-space file keeps its two-space unit.
        let text = "/**\n * Doc.\n */\nfunction a() {\n  return 1;\n}\n"
        XCTAssertEqual(inferUnit(text), "  ")
    }

    func testFileIndentedOnlyBySingleSpacesFallsBackToFourSpaces() {
        // Nothing is indented one space per level, so the run is not evidence of
        // a unit; the answer is the same fallback a file with no indentation at
        // all already gives, rather than a one-space unit.
        let text = "func f() {\n a()\n}\n"
        XCTAssertEqual(inferUnit(text), "    ")
    }

    func testWhitespaceOnlyLineDoesNotSkewUnit() {
        // A 4-space file with a blank line carrying 2 trailing spaces must still
        // infer a 4-space unit: that 2-space run is trailing whitespace, not
        // indentation, and must not be counted.
        let text = "func f() {\n    a()\n  \n    b()\n}\n"
        XCTAssertEqual(inferUnit(text), "    ")
    }

    func testWhitespaceOnlyTabLineDoesNotForceTabUnit() {
        // A blank line of tabs in an otherwise space-indented file must not make
        // the unit a tab — that tab run is trailing whitespace.
        let text = "func f() {\n    a()\n\t\n    b()\n}\n"
        XCTAssertEqual(inferUnit(text), "    ")
    }

    // MARK: - newlineIndentation

    private func newline(_ s: String, at location: Int, unit: String, selectionLength: Int = 0) -> NewlineEdit {
        let ns = s as NSString
        return IndentEngine.newlineIndentation(text: ns, location: location, unit: unit, selectionLength: selectionLength)
    }

    func testInheritsPreviousLineIndent() {
        // Enter at the end of `    expect(foo)` lands the caret under `expect`.
        let text = "    expect(foo)"
        let edit = newline(text, at: (text as NSString).length, unit: "    ")
        XCTAssertEqual(edit, NewlineEdit(text: "\n    ", cursorOffset: 5))
    }

    func testAddsUnitAfterOpeningBrace() {
        let text = "func f() {"
        let edit = newline(text, at: (text as NSString).length, unit: "    ")
        XCTAssertEqual(edit, NewlineEdit(text: "\n    ", cursorOffset: 5))
    }

    func testAddsUnitAfterOpeningBraceWithExistingIndent() {
        let text = "    if x {"
        let edit = newline(text, at: (text as NSString).length, unit: "    ")
        XCTAssertEqual(edit, NewlineEdit(text: "\n        ", cursorOffset: 9))
    }

    func testAddsUnitAfterOpenerIgnoringTrailingWhitespace() {
        let text = "func f() {   "
        let edit = newline(text, at: (text as NSString).length, unit: "    ")
        XCTAssertEqual(edit, NewlineEdit(text: "\n    ", cursorOffset: 5))
    }

    func testAddsUnitAfterParenAndBracket() {
        let paren = "foo("
        XCTAssertEqual(
            newline(paren, at: (paren as NSString).length, unit: "  "),
            NewlineEdit(text: "\n  ", cursorOffset: 3)
        )
        let bracket = "let a = ["
        XCTAssertEqual(
            newline(bracket, at: (bracket as NSString).length, unit: "  "),
            NewlineEdit(text: "\n  ", cursorOffset: 3)
        )
    }

    func testBetweenBracketsSplit() {
        // Caret sits between `{` and `}`: "func f() {}" → `{` at index 9.
        let text = "func f() {}"
        let edit = newline(text, at: 10, unit: "    ")
        XCTAssertEqual(edit, NewlineEdit(text: "\n    \n", cursorOffset: 5))
    }

    func testBetweenBracketsSplitWithIndent() {
        // "    if x {}" → `{` at index 9, `}` at index 10.
        let text = "    if x {}"
        let edit = newline(text, at: 10, unit: "    ")
        XCTAssertEqual(edit, NewlineEdit(text: "\n        \n    ", cursorOffset: 9))
    }

    func testSelectedCloserDoesNotSplit() {
        // Selecting the `}` in `{}` and pressing Enter replaces the selection, so
        // the closer is consumed — there must be no between-brackets split (which
        // would leave an unwanted extra blank line and a missing closer). The
        // trailing `{` still indents one unit.
        let text = "func f() {}"
        // `}` is at index 10; select it (location 10, length 1).
        let edit = newline(text, at: 10, unit: "    ", selectionLength: 1)
        XCTAssertEqual(edit, NewlineEdit(text: "\n    ", cursorOffset: 5))
    }

    func testOpenerConsumesTrailingWhitespaceAfterCaret() {
        // Caret right after `{` with trailing spaces still on the line ("{    |").
        // The new line gets exactly one unit; the surviving spaces are reported via
        // `consumeAfter` so the caller deletes them instead of stacking them on the
        // unit (which would produce eight spaces and a caret wedged in the middle).
        let text = "func f() {    " // `{` at index 9, 4 trailing spaces (10..13)
        let edit = newline(text, at: 10, unit: "    ")
        XCTAssertEqual(edit, NewlineEdit(text: "\n    ", cursorOffset: 5, consumeAfter: 4))
    }

    func testSelectionDeletingTrailingWhitespaceNotCountedSurviving() {
        // Select the last two of four spaces and press Enter. The selected spaces
        // are deleted by the replacement, so they must not be counted as surviving
        // indentation — otherwise the caret offset overshoots the result.
        let edit = newline("    ", at: 2, unit: "    ", selectionLength: 2)
        XCTAssertEqual(edit, NewlineEdit(text: "\n  ", cursorOffset: 3))
    }

    func testStartOfFileEmptyIndent() {
        let text = "hello"
        let edit = newline(text, at: 0, unit: "    ")
        XCTAssertEqual(edit, NewlineEdit(text: "\n", cursorOffset: 1))
    }

    func testEmptyLineEmptyIndent() {
        // Caret on the blank second line.
        let text = "let a = 1\n\nlet b = 2"
        let edit = newline(text, at: 10, unit: "    ")
        XCTAssertEqual(edit, NewlineEdit(text: "\n", cursorOffset: 1))
    }

    func testMixedTabsSpacesInheritedVerbatim() {
        let text = "\t  code"
        let edit = newline(text, at: (text as NSString).length, unit: "\t")
        XCTAssertEqual(edit, NewlineEdit(text: "\n\t  ", cursorOffset: 4))
    }

    func testCaretInsideLeadingWhitespaceDoesNotDoubleIndent() {
        // Caret wedged inside the 4-space indent of "    foo" (after 2 spaces).
        // The 2 spaces after the caret survive the insertion, so the inherited
        // base must be only the 2 spaces *before* the caret — otherwise the new
        // line would carry 6 spaces (4 inherited + 2 surviving). The caret is then
        // advanced over the 2 surviving spaces so it lands at the end of the
        // 4-space indent (cursorOffset 5), not wedged in its middle.
        let text = "    foo"
        let edit = newline(text, at: 2, unit: "    ")
        XCTAssertEqual(edit, NewlineEdit(text: "\n  ", cursorOffset: 5))
    }

    // Apply a NewlineEdit the way the view does (insert `text` at `location`,
    // caret = `location + cursorOffset`) and return the resulting buffer plus the
    // caret's UTF-16 index, so the *final* document/caret position is asserted —
    // not just the NewlineEdit value.
    private func applyNewline(_ s: String, at location: Int, unit: String) -> (text: String, caret: Int) {
        let ns = s as NSString
        let edit = IndentEngine.newlineIndentation(text: ns, location: location, unit: unit)
        let result = ns.replacingCharacters(in: NSRange(location: location, length: 0), with: edit.text)
        return (result, location + edit.cursorOffset)
    }

    func testCaretInsideLeadingWhitespaceLandsAtIndentEnd() {
        // End-to-end: "  |  foo" → the new line keeps a single 4-space indent and
        // the caret lands immediately before `foo`, not inside the whitespace.
        let (text, caret) = applyNewline("    foo", at: 2, unit: "    ")
        XCTAssertEqual(text, "  \n    foo")
        XCTAssertEqual(caret, 7)
        let ns = text as NSString
        // The caret prefix is exactly the leading whitespace; the next char is `f`.
        XCTAssertEqual(ns.substring(to: caret), "  \n    ")
        XCTAssertEqual(ns.substring(with: NSRange(location: caret, length: 1)), "f")
    }

    func testCaretAtStartOfIndentedLineLandsBeforeContent() {
        // Caret at column 0 of "    foo": the whole 4-space indent survives and the
        // caret advances over it to sit before `foo` on the pushed-down line.
        let (text, caret) = applyNewline("    foo", at: 0, unit: "    ")
        XCTAssertEqual(text, "\n    foo")
        XCTAssertEqual(caret, 5)
        XCTAssertEqual((text as NSString).substring(with: NSRange(location: caret, length: 1)), "f")
    }

    // Apply a NewlineEdit including a selection and `consumeAfter`, exactly as the
    // view does: replace [location, length + consumeAfter) with `text` and place the
    // caret at `location + cursorOffset`.
    private func applyNewlineFull(
        _ s: String,
        at location: Int,
        length: Int = 0,
        unit: String
    ) -> (text: String, caret: Int) {
        let ns = s as NSString
        let edit = IndentEngine.newlineIndentation(
            text: ns, location: location, unit: unit, selectionLength: length
        )
        let range = NSRange(location: location, length: length + edit.consumeAfter)
        let result = ns.replacingCharacters(in: range, with: edit.text)
        return (result, location + edit.cursorOffset)
    }

    func testOpenerWithTrailingWhitespaceEndToEnd() {
        // End-to-end: Enter right after `{` with trailing spaces leaves a single
        // 4-space indent (not eight) and lands the caret at its end.
        let (text, caret) = applyNewlineFull("func f() {    ", at: 10, unit: "    ")
        XCTAssertEqual(text, "func f() {\n    ")
        XCTAssertEqual(caret, 15)
        XCTAssertEqual((text as NSString).length, caret)
    }

    func testSelectionDeletingTrailingWhitespaceCaretInBounds() {
        // End-to-end: selecting two of four spaces and pressing Enter deletes them,
        // so the caret stays within the 5-character result rather than overshooting.
        let (text, caret) = applyNewlineFull("    ", at: 2, length: 2, unit: "    ")
        XCTAssertEqual(text, "  \n  ")
        XCTAssertEqual(caret, 5)
        XCTAssertLessThanOrEqual(caret, (text as NSString).length)
    }

    // MARK: - newlineIndentation: the spliced terminator

    // Apply a NewlineEdit under an explicit terminator exactly as the view does
    // (replace [location, length + consumeAfter) with `text`, caret at
    // `location + cursorOffset`), returning the result and the caret's index.
    private func applyNewline(
        _ s: String,
        at location: Int,
        length: Int = 0,
        unit: String,
        terminator: String
    ) -> (text: String, caret: Int) {
        let ns = s as NSString
        let edit = IndentEngine.newlineIndentation(
            text: ns, location: location, unit: unit,
            selectionLength: length, terminator: terminator
        )
        let range = NSRange(location: location, length: length + edit.consumeAfter)
        return (ns.replacingCharacters(in: range, with: edit.text), location + edit.cursorOffset)
    }

    // The caret's column: its UTF-16 distance from the start of the line it sits
    // on, under the editor's own separator set (so a CRLF pair counts as one
    // separator, not two lines). Comparing columns is how "the caret lands where
    // it does under LF" is asserted across terminators of differing lengths — the
    // absolute offset necessarily differs, the column must not.
    private func caretColumn(_ text: String, _ caret: Int) -> Int {
        let ns = text as NSString
        var lineStart = 0
        for s in LineStartIndex.offsets(in: ns) where s <= caret { lineStart = s }
        return caret - lineStart
    }

    func testTwoUnitTerminatorInheritsPreviousLineIndent() {
        // The plain inherit case: the whole terminator is spliced and the caret
        // still lands at the end of the inherited indent, not one unit short.
        let edit = IndentEngine.newlineIndentation(
            text: "    expect(foo)" as NSString, location: 15, unit: "    ", terminator: "\r\n"
        )
        XCTAssertEqual(edit, NewlineEdit(text: "\r\n    ", cursorOffset: 6))

        let (text, caret) = applyNewline("    expect(foo)", at: 15, unit: "    ", terminator: "\r\n")
        XCTAssertEqual(text, "    expect(foo)\r\n    ")
        XCTAssertEqual(caret, (text as NSString).length)

        let lf = applyNewline("    expect(foo)", at: 15, unit: "    ", terminator: "\n")
        XCTAssertEqual(caretColumn(text, caret), caretColumn(lf.text, lf.caret))
    }

    func testTwoUnitTerminatorAfterOpenerConsumesTrailingWhitespace() {
        // The opener case: one unit on the new line, the trailing spaces still
        // reported for consumption, and the caret at the indent's end.
        let edit = IndentEngine.newlineIndentation(
            text: "func f() {    " as NSString, location: 10, unit: "    ", terminator: "\r\n"
        )
        XCTAssertEqual(edit, NewlineEdit(text: "\r\n    ", cursorOffset: 6, consumeAfter: 4))

        let (text, caret) = applyNewline("func f() {    ", at: 10, unit: "    ", terminator: "\r\n")
        XCTAssertEqual(text, "func f() {\r\n    ")
        XCTAssertEqual(caret, (text as NSString).length)

        let lf = applyNewline("func f() {    ", at: 10, unit: "    ", terminator: "\n")
        XCTAssertEqual(caretColumn(text, caret), caretColumn(lf.text, lf.caret))
    }

    func testTwoUnitTerminatorBetweenBracketsSplit() {
        // The split case is the one that counts the terminator's length twice over
        // — once spliced, once in the caret offset. A hardcoded single unit would
        // wedge the caret one short of the middle line's indent.
        let edit = IndentEngine.newlineIndentation(
            text: "    if x {}" as NSString, location: 10, unit: "    ", terminator: "\r\n"
        )
        XCTAssertEqual(edit, NewlineEdit(text: "\r\n        \r\n    ", cursorOffset: 10))

        let (text, caret) = applyNewline("    if x {}", at: 10, unit: "    ", terminator: "\r\n")
        XCTAssertEqual(text, "    if x {\r\n        \r\n    }")
        // The caret sits at the end of the middle line's 8-space indent: everything
        // before it on that line is whitespace, and the terminator follows.
        XCTAssertEqual((text as NSString).substring(with: NSRange(location: caret - 8, length: 8)), "        ")
        XCTAssertEqual((text as NSString).substring(with: NSRange(location: caret, length: 2)), "\r\n")

        let lf = applyNewline("    if x {}", at: 10, unit: "    ", terminator: "\n")
        XCTAssertEqual(caretColumn(text, caret), caretColumn(lf.text, lf.caret))
    }

    func testCarriageReturnTerminatorSplicesItsOwnCharacter() {
        // The third `end_of_line` flavor: one unit like LF, but its own character.
        let (text, caret) = applyNewline("    if x {}", at: 10, unit: "  ", terminator: "\r")
        XCTAssertEqual(text, "    if x {\r      \r    }")
        XCTAssertEqual(caretColumn(text, caret), 6)

        let (plain, plainCaret) = applyNewline("    expect(foo)", at: 15, unit: "    ", terminator: "\r")
        XCTAssertEqual(plain, "    expect(foo)\r    ")
        XCTAssertEqual(plainCaret, (plain as NSString).length)
    }

    func testDefaultTerminatorReproducesLineFeedExactly() {
        // Every existing caller states no terminator; the default must be
        // byte-for-byte what an explicit LF produces, on every branch.
        let cases: [(String, Int, Int, String)] = [
            ("    expect(foo)", 15, 0, "    "),   // inherit
            ("func f() {", 10, 0, "    "),        // opener
            ("func f() {    ", 10, 0, "    "),    // opener + trailing whitespace
            ("    if x {}", 10, 0, "    "),       // between-brackets split
            ("func f() {}", 10, 1, "    "),       // selected closer, no split
            ("    foo", 2, 0, "    "),            // caret inside leading whitespace
            ("    ", 2, 2, "    "),               // selection deleting whitespace
            ("let a = 1\n\nlet b = 2", 10, 0, "\t"), // blank line, tab unit
        ]
        for (text, location, length, unit) in cases {
            let ns = text as NSString
            let byDefault = IndentEngine.newlineIndentation(
                text: ns, location: location, unit: unit, selectionLength: length
            )
            let explicit = IndentEngine.newlineIndentation(
                text: ns, location: location, unit: unit, selectionLength: length, terminator: "\n"
            )
            XCTAssertEqual(byDefault, explicit, "case \(text.debugDescription) at \(location)")
        }
    }

    // MARK: - dedentOnClosing

    private func dedent(_ s: String, at location: Int, closing: Character) -> IndentReplacement? {
        let ns = s as NSString
        return IndentEngine.dedentOnClosing(text: ns, location: location, closing: closing)
    }

    func testDedentsToOpenerIndent() {
        // `{` opener on an unindented line; typing `}` on the blank line below
        // dedents to column 0.
        let prefix = "func f() {\n"
        let text = prefix + "    "
        let loc = (text as NSString).length
        let lineStart = (prefix as NSString).length
        XCTAssertEqual(
            dedent(text, at: loc, closing: "}"),
            IndentReplacement(range: NSRange(location: lineStart, length: 4), replacement: "")
        )
    }

    func testNestingPicksCorrectOpener() {
        // The inner `{}` pair is closed, so `}` matches the outer opener and
        // dedents to the outer line's 4-space indent.
        let prefix = "    outer {\n        inner {\n        }\n"
        let text = prefix + "        "
        let loc = (text as NSString).length
        let lineStart = (prefix as NSString).length
        XCTAssertEqual(
            dedent(text, at: loc, closing: "}"),
            IndentReplacement(range: NSRange(location: lineStart, length: 8), replacement: "    ")
        )
    }

    func testNoMatchingOpenerReturnsNil() {
        let text = "    "
        XCTAssertNil(dedent(text, at: (text as NSString).length, closing: "}"))
    }

    func testMismatchedOpenerKindReturnsNil() {
        // Only a `(` is open; a `}` has no matching `{`.
        let prefix = "foo(\n"
        let text = prefix + "    "
        XCTAssertNil(dedent(text, at: (text as NSString).length, closing: "}"))
    }

    func testNonWhitespacePrefixReturnsNil() {
        let prefix = "func f() {\n"
        let text = prefix + "    x"
        XCTAssertNil(dedent(text, at: (text as NSString).length, closing: "}"))
    }

    func testReplacementPreservesOpenerStyle() {
        // Opener line is tab-indented; the dedent replacement is a single tab.
        let prefix = "\tif x {\n"
        let text = prefix + "\t\t"
        let loc = (text as NSString).length
        let lineStart = (prefix as NSString).length
        XCTAssertEqual(
            dedent(text, at: loc, closing: "}"),
            IndentReplacement(range: NSRange(location: lineStart, length: 2), replacement: "\t")
        )
    }

    func testDedentsParenToOpenerIndent() {
        // The `)` closer matches its `(` opener (not handled by the `}` tests).
        let prefix = "    foo(\n"
        let text = prefix + "        "
        let loc = (text as NSString).length
        let lineStart = (prefix as NSString).length
        XCTAssertEqual(
            dedent(text, at: loc, closing: ")"),
            IndentReplacement(range: NSRange(location: lineStart, length: 8), replacement: "    ")
        )
    }

    func testUnknownClosingReturnsNil() {
        // A non-bracket character is never a known closer.
        XCTAssertNil(dedent("foo {\n    ", at: 9, closing: ">"))
    }

    // MARK: - Non-BMP (surrogate pair) safety

    // A character outside the BMP (e.g. an emoji) occupies two UTF-16 units, each
    // a surrogate half for which `UnicodeScalar(UInt16)` is nil. These exercise the
    // caret landing adjacent to such a character so a regression to force-unwrapping
    // would crash rather than fall through to inherited indentation.

    func testNewlineAfterNonBMPCharDoesNotCrash() {
        // Caret immediately after a trailing emoji.
        let text = "let x = 😀"
        let edit = newline(text, at: (text as NSString).length, unit: "    ")
        XCTAssertEqual(edit, NewlineEdit(text: "\n", cursorOffset: 1))
    }

    func testNewlineBetweenSurrogateHalvesDoesNotCrash() {
        // Caret wedged between the two surrogate halves of a leading emoji.
        let text = "😀x"
        let edit = newline(text, at: 1, unit: "    ")
        XCTAssertEqual(edit, NewlineEdit(text: "\n", cursorOffset: 1))
    }

    func testNewlineBeforeNonBMPCharDoesNotCrash() {
        // Caret immediately before a leading emoji.
        let text = "😀"
        let edit = newline(text, at: 0, unit: "    ")
        XCTAssertEqual(edit, NewlineEdit(text: "\n", cursorOffset: 1))
    }
}
