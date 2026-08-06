import XCTest
@testable import PisakaCore

final class AutoPairEngineTests: XCTestCase {
    private func action(_ s: String, caret: Int, length: Int = 0, typed: String) -> AutoPairAction {
        AutoPairEngine.action(
            text: s as NSString,
            selectedRange: NSRange(location: caret, length: length),
            typed: typed
        )
    }

    // MARK: - insertPair (each pair, at various closeable positions)

    func testInsertPairAtEndOfBuffer() {
        for (open, close) in [("(", ")"), ("[", "]"), ("{", "}"), ("\"", "\""), ("'", "'"), ("`", "`")] {
            XCTAssertEqual(action("", caret: 0, typed: open), .insertPair(close: close), "open=\(open)")
        }
    }

    func testInsertPairBeforeWhitespace() {
        // Caret before a space: "| foo"
        XCTAssertEqual(action(" foo", caret: 0, typed: "("), .insertPair(close: ")"))
        XCTAssertEqual(action(" foo", caret: 0, typed: "\""), .insertPair(close: "\""))
    }

    func testInsertPairBeforeCloser() {
        // "(|)" — typing '(' before an existing closer still auto-closes.
        XCTAssertEqual(action(")", caret: 0, typed: "("), .insertPair(close: ")"))
        XCTAssertEqual(action("]", caret: 0, typed: "{"), .insertPair(close: "}"))
    }

    func testInsertPairBeforeLineSeparator() {
        // Every separator LineStartIndex/IndentEngine split on: LF, CR, NEL, LS, PS.
        for sep in ["\n", "\r", "\u{85}", "\u{2028}", "\u{2029}"] {
            XCTAssertEqual(action("\(sep)foo", caret: 0, typed: "["), .insertPair(close: "]"), "sep=\(sep.unicodeScalars.first!.value)")
        }
    }

    func testInsertPairBeforeTab() {
        // Caret before a tab counts as a closeable position (whitespace).
        XCTAssertEqual(action("\tfoo", caret: 0, typed: "("), .insertPair(close: ")"))
    }

    func testOutOfBoundsSelectionIsClamped() {
        // A location/length past the buffer must clamp, not trap.
        XCTAssertEqual(action("ab", caret: 99, typed: "("), .insertPair(close: ")"))
        XCTAssertEqual(action("ab", caret: 0, length: 99, typed: "("), .wrap(open: "(", close: ")"))
    }

    func testDegenerateRangeDoesNotOverflow() {
        // NSNotFound (Int.max) location + length, and an Int.min length, must
        // clamp rather than trap on the location+length addition. NSNotFound
        // clamps to end-of-buffer (a closeable position); Int.min length clamps
        // to an empty selection.
        XCTAssertEqual(action("ab", caret: NSNotFound, length: 1, typed: "("), .insertPair(close: ")"))
        XCTAssertEqual(action("", caret: 0, length: Int.min, typed: "("), .insertPair(close: ")"))
    }

    // MARK: - opener before a word → passthrough

    func testOpenerBeforeWordPassesThrough() {
        XCTAssertEqual(action("foo", caret: 0, typed: "("), .passthrough)
        XCTAssertEqual(action("foo", caret: 0, typed: "{"), .passthrough)
    }

    // MARK: - typeOver

    func testTypeOverBracket() {
        // "(|)" then type ')' → step over.
        XCTAssertEqual(action("()", caret: 1, typed: ")"), .typeOver)
        XCTAssertEqual(action("[]", caret: 1, typed: "]"), .typeOver)
        XCTAssertEqual(action("{}", caret: 1, typed: "}"), .typeOver)
    }

    func testCloserWithoutMatchPassesThrough() {
        // Next char is not the typed closer.
        XCTAssertEqual(action("foo", caret: 0, typed: ")"), .passthrough)
        XCTAssertEqual(action("", caret: 0, typed: "]"), .passthrough)
    }

    func testTypeOverQuote() {
        // '"|"' then type '"' → step over the existing quote.
        XCTAssertEqual(action("\"\"", caret: 1, typed: "\""), .typeOver)
        XCTAssertEqual(action("``", caret: 1, typed: "`"), .typeOver)
    }

    func testApostropheTypeOver() {
        // "'|'" then type ' → step over the existing apostrophe.
        XCTAssertEqual(action("''", caret: 1, typed: "'"), .typeOver)
    }

    func testCloserWithSelectionPassesThrough() {
        // Select "abc" in "abc)" (range {0,3}) and type ')': the selection end
        // sits before an identical closer, but a non-empty selection must replace
        // rather than step over — so this passes through, not .typeOver.
        XCTAssertEqual(action("abc)", caret: 0, length: 3, typed: ")"), .passthrough)
        XCTAssertEqual(action("(x)", caret: 1, length: 1, typed: ")"), .passthrough)
    }

    // MARK: - quote heuristics

    func testApostropheInWordPassesThrough() {
        // "don|" then type ' → passthrough, not don''
        XCTAssertEqual(action("don", caret: 3, typed: "'"), .passthrough)
    }

    func testQuoteBeforeWordPassesThrough() {
        // "|word" then type '"' → real content follows, passthrough.
        XCTAssertEqual(action("word", caret: 0, typed: "\""), .passthrough)
    }

    func testQuoteAfterNonAlphanumericInserts() {
        // "(|" then type '"' — preceding char is '(', not alphanumeric → insert.
        XCTAssertEqual(action("(", caret: 1, typed: "\""), .insertPair(close: "\""))
    }

    func testApostropheAfterAstralLetterPassesThrough() {
        // An astral (non-BMP) letter occupies two UTF-16 units; the preceding-char
        // check must combine the surrogate pair and see it as alphanumeric, so a
        // quote after it passes through rather than auto-closing.
        let astral = "\u{1D400}" // MATHEMATICAL BOLD CAPITAL A — alphanumeric
        XCTAssertEqual(action(astral, caret: 2, typed: "'"), .passthrough)
        XCTAssertEqual(action(astral, caret: 2, typed: "\""), .passthrough)
    }

    func testQuoteAfterAstralNonLetterInserts() {
        // An astral *non*-alphanumeric (an emoji) does not block auto-closing.
        let emoji = "\u{1F600}" // 😀
        XCTAssertEqual(action(emoji, caret: 2, typed: "\""), .insertPair(close: "\""))
    }

    func testInsertPairBeforeUnicodeWhitespace() {
        // NBSP (and other Unicode Zs) is whitespace, not real content, so an
        // opener before it still auto-closes.
        XCTAssertEqual(action("\u{00A0}foo", caret: 0, typed: "("), .insertPair(close: ")"))
    }

    // MARK: - wrap

    func testWrapSelectionWithBracket() {
        // Select "foo" in "foo", type '(' → wrap.
        XCTAssertEqual(action("foo", caret: 0, length: 3, typed: "("), .wrap(open: "(", close: ")"))
    }

    func testWrapSelectionWithQuote() {
        XCTAssertEqual(action("foo", caret: 0, length: 3, typed: "\""), .wrap(open: "\"", close: "\""))
    }

    func testWrapSelectionEvenBeforeWord() {
        // A selection wraps regardless of what follows it.
        XCTAssertEqual(action("foobar", caret: 0, length: 3, typed: "["), .wrap(open: "[", close: "]"))
    }

    // MARK: - non-single-character typed

    func testMultiCharacterTypedPassesThrough() {
        XCTAssertEqual(action("", caret: 0, typed: "()"), .passthrough)
        XCTAssertEqual(action("", caret: 0, typed: ""), .passthrough)
    }

    func testNonPairCharacterPassesThrough() {
        XCTAssertEqual(action("", caret: 0, typed: "a"), .passthrough)
    }

    // MARK: - shouldDeletePair

    private func shouldDelete(_ s: String, at location: Int) -> Bool {
        AutoPairEngine.shouldDeletePair(text: s as NSString, location: location)
    }

    func testShouldDeleteEmptyBracketPair() {
        XCTAssertTrue(shouldDelete("()", at: 1))
        XCTAssertTrue(shouldDelete("[]", at: 1))
        XCTAssertTrue(shouldDelete("{}", at: 1))
    }

    func testShouldDeleteEmptyQuotePair() {
        XCTAssertTrue(shouldDelete("\"\"", at: 1))
        XCTAssertTrue(shouldDelete("''", at: 1))
        XCTAssertTrue(shouldDelete("``", at: 1))
    }

    func testShouldNotDeleteNonEmptyPair() {
        // "(x|)" — content between the brackets.
        XCTAssertFalse(shouldDelete("(x)", at: 2))
        // "(|x)" — caret right after the opener but next char isn't the closer.
        XCTAssertFalse(shouldDelete("(x)", at: 1))
    }

    func testShouldNotDeleteMismatchedPair() {
        XCTAssertFalse(shouldDelete("(]", at: 1))
        XCTAssertFalse(shouldDelete("\"'", at: 1))
    }

    func testShouldNotDeleteAtBoundaries() {
        XCTAssertFalse(shouldDelete("()", at: 0)) // nothing before
        XCTAssertFalse(shouldDelete("()", at: 2)) // nothing after
        XCTAssertFalse(shouldDelete("", at: 0))
        XCTAssertFalse(shouldDelete("()", at: Int.min)) // must not underflow
        XCTAssertFalse(shouldDelete("()", at: Int.max)) // must not overflow
    }

    func testShouldNotDeleteWhenNotBetweenPair() {
        XCTAssertFalse(shouldDelete("ab", at: 1))
    }
}
