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
