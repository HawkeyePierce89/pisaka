import XCTest
@testable import PisakaCore

final class CaretReadoutTests: XCTestCase {
    private func readout(_ text: String, _ offset: Int, _ language: SyntaxLanguage? = .swift) -> String {
        CaretReadout.text(
            text: text as NSString,
            caretOffset: offset,
            language: language,
            encodingName: FileService.encodingName
        )
    }

    func testEncodingNameIsUTF8() {
        XCTAssertEqual(FileService.encodingName, "UTF-8")
    }

    func testFullShape() {
        XCTAssertEqual(readout("let x = 1\n", 4), "Ln 1, Col 5 · UTF-8 · Swift")
    }

    func testNoLanguageReadsPlainText() {
        XCTAssertEqual(readout("abc", 0, nil), "Ln 1, Col 1 · UTF-8 · Plain Text")
    }

    func testLanguageNameIsDisplayName() {
        XCTAssertEqual(readout("", 0, .javascript), "Ln 1, Col 1 · UTF-8 · JavaScript")
    }

    func testEmptyText() {
        XCTAssertEqual(readout("", 0), "Ln 1, Col 1 · UTF-8 · Swift")
    }

    func testASCIIColumnsAndLines() {
        let text = "abc\ndefg\nhi"
        XCTAssertEqual(readout(text, 0), "Ln 1, Col 1 · UTF-8 · Swift")
        XCTAssertEqual(readout(text, 3), "Ln 1, Col 4 · UTF-8 · Swift")
        XCTAssertEqual(readout(text, 4), "Ln 2, Col 1 · UTF-8 · Swift")
        XCTAssertEqual(readout(text, 6), "Ln 2, Col 3 · UTF-8 · Swift")
        XCTAssertEqual(readout(text, 9), "Ln 3, Col 1 · UTF-8 · Swift")
    }

    /// The last line has no terminator; a caret at its end is past its last
    /// character, not on a line beyond it.
    func testCaretAtEndOfUnterminatedLastLine() {
        let text = "abc\nhi"
        XCTAssertEqual(readout(text, 6), "Ln 2, Col 3 · UTF-8 · Swift")
    }

    /// A terminated last line leaves an empty line after it, as the gutter shows.
    func testCaretAfterTrailingSeparatorIsOnTheEmptyLastLine() {
        XCTAssertEqual(readout("abc\n", 4), "Ln 2, Col 1 · UTF-8 · Swift")
    }

    func testCRLFCountsOnce() {
        let text = "ab\r\ncd\r\nef"
        XCTAssertEqual(readout(text, 4), "Ln 2, Col 1 · UTF-8 · Swift")
        XCTAssertEqual(readout(text, 6), "Ln 2, Col 3 · UTF-8 · Swift")
        XCTAssertEqual(readout(text, 9), "Ln 3, Col 2 · UTF-8 · Swift")
    }

    /// A caret between a CR and its LF is still on the line the pair ends:
    /// the pair is one separator, so no line starts inside it.
    func testCaretInsideCRLFPairStaysOnItsLine() {
        XCTAssertEqual(readout("ab\r\ncd", 3), "Ln 1, Col 4 · UTF-8 · Swift")
    }

    /// The readout's line agrees with the gutter's index of the whole text at
    /// every offset, whatever the mix of separators.
    func testLineAgreesWithTheWholeTextIndexEverywhere() {
        let text = "a\r\nb\rc\n\u{0085}d\u{2028}\u{2029}e\r\n" as NSString
        let starts = LineStartIndex.offsets(in: text)
        for offset in 0...text.length {
            let expected = starts.lastIndex { $0 <= offset }! + 1
            XCTAssertEqual(CaretReadout.position(text: text, caretOffset: offset).line, expected, "offset \(offset)")
        }
    }

    /// The editor passes the gutter's table rather than letting the readout
    /// index the text; the line is read off that table.
    func testPositionReadsTheGivenTable() {
        let text = "abc\ndefg\nhi" as NSString
        let starts = LineStartIndex.offsets(in: text)
        XCTAssertTrue(CaretReadout.position(text: text, caretOffset: 6, lineStarts: starts) == (2, 3))
        XCTAssertTrue(CaretReadout.position(text: text, caretOffset: 11, lineStarts: starts) == (3, 3))
        XCTAssertEqual(
            CaretReadout.text(position: (2, 3), language: nil, encodingName: "UTF-8"),
            "Ln 2, Col 3 · UTF-8 · Plain Text"
        )
    }

    /// A stale table never reads a line start past the caret, and an empty one
    /// reads the whole text as one line.
    func testStaleOrEmptyTableStaysInsideTheText() {
        let text = "ab" as NSString
        XCTAssertTrue(CaretReadout.position(text: text, caretOffset: 2, lineStarts: [0, 10]) == (1, 3))
        XCTAssertTrue(CaretReadout.position(text: text, caretOffset: 9, lineStarts: [0, 1, 2, 3]) == (3, 1))
        XCTAssertTrue(CaretReadout.position(text: text, caretOffset: 1, lineStarts: []) == (1, 2))
    }

    func testBareCRSplits() {
        XCTAssertEqual(readout("ab\rcd", 4), "Ln 2, Col 2 · UTF-8 · Swift")
    }

    func testNELLineSeparatorAndParagraphSeparatorSplit() {
        let text = "a\u{0085}b\u{2028}c\u{2029}d"
        XCTAssertEqual(readout(text, 2), "Ln 2, Col 1 · UTF-8 · Swift")
        XCTAssertEqual(readout(text, 4), "Ln 3, Col 1 · UTF-8 · Swift")
        XCTAssertEqual(readout(text, 6), "Ln 4, Col 1 · UTF-8 · Swift")
        XCTAssertEqual(readout(text, 7), "Ln 4, Col 2 · UTF-8 · Swift")
    }

    /// An emoji is two UTF-16 units (a family emoji many more) but one column.
    func testEmojiIsOneColumn() {
        let text = "a😀b" as NSString
        XCTAssertEqual(readout(text as String, 3), "Ln 1, Col 3 · UTF-8 · Swift")
        let family = "👨‍👩‍👧x"
        let afterFamily = (family as NSString).length - 1
        XCTAssertEqual(readout(family, afterFamily), "Ln 1, Col 2 · UTF-8 · Swift")
    }

    /// A letter and its combining mark are one grapheme cluster, so one column.
    func testCombiningMarkIsOneColumn() {
        let text = "e\u{0301}x"
        XCTAssertEqual(readout(text, 2), "Ln 1, Col 2 · UTF-8 · Swift")
        XCTAssertEqual(readout(text, 3), "Ln 1, Col 3 · UTF-8 · Swift")
    }

    func testTabIsOneColumn() {
        XCTAssertEqual(readout("\t\tx", 2), "Ln 1, Col 3 · UTF-8 · Swift")
    }

    func testOffsetBeyondTextClampsToEnd() {
        XCTAssertEqual(readout("abc\nde", 99), "Ln 2, Col 3 · UTF-8 · Swift")
        XCTAssertEqual(readout("abc", -5), "Ln 1, Col 1 · UTF-8 · Swift")
    }

    // MARK: - The incremental column

    /// The memoised position, asserted against the full count; returns the next memo.
    @discardableResult
    private func incremental(
        _ text: NSString,
        _ offset: Int,
        memo: CaretReadout.ColumnMemo?,
        editFloor: Int? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (memo: CaretReadout.ColumnMemo, work: Int) {
        let starts = LineStartIndex.offsets(in: text)
        let result = CaretReadout.countedPosition(
            text: text, caretOffset: offset, lineStarts: starts, memo: memo, editFloor: editFloor
        )
        let full = CaretReadout.position(text: text, caretOffset: offset, lineStarts: starts)
        XCTAssertEqual(result.line, full.line, "line at \(offset)", file: file, line: line)
        XCTAssertEqual(result.column, full.column, "column at \(offset)", file: file, line: line)
        XCTAssertEqual(result.memo.column, full.column, file: file, line: line)
        return (result.memo, result.work)
    }

    private func memo(_ text: NSString, at offset: Int) -> CaretReadout.ColumnMemo {
        CaretReadout.position(
            text: text, caretOffset: offset, lineStarts: LineStartIndex.offsets(in: text), memo: nil, editFloor: nil
        ).memo
    }

    func testIncrementalSameLineForwards() {
        let text = "let 😀 = e\u{0301}xample + value\nnext" as NSString
        var current = memo(text, at: 2)
        for offset in 3...20 {
            current = incremental(text, offset, memo: current).memo
        }
    }

    func testIncrementalSameLineBackwards() {
        let text = "let 😀 = e\u{0301}xample + value\nnext" as NSString
        var current = memo(text, at: 25)
        for offset in stride(from: 24, through: 0, by: -1) {
            current = incremental(text, offset, memo: current).memo
        }
    }

    func testIncrementalAcrossLines() {
        let text = "first line\nsecond 😀 line\r\nthird" as NSString
        let start = memo(text, at: 5)
        incremental(text, 18, memo: start)
        let onSecond = incremental(text, 14, memo: start).memo
        incremental(text, 3, memo: onSecond)
        incremental(text, text.length, memo: onSecond)
    }

    /// An edit before the old offset invalidates the memo's prefix: the column
    /// is recounted from the line start, and must not drift.
    func testEditBeforeTheOldOffsetFallsBack() {
        let before = "abcdefghij" as NSString
        let old = memo(before, at: 8)
        let after = "a😀bcdefghij" as NSString
        let result = incremental(after, 9, memo: old, editFloor: 1)
        XCTAssertEqual(result.work, 9, "the full count ran")
    }

    /// Typing at the caret leaves `[lineStart, old)` untouched, so the
    /// incremental path is taken with the floor at the old offset.
    func testTypingAtTheCaretTakesTheIncrementalPath() {
        let prefix = String(repeating: "x", count: 500)
        let before = (prefix + "\n") as NSString
        let old = memo(before, at: 500)
        let after = (prefix + "y\n") as NSString
        let result = incremental(after, 501, memo: old, editFloor: 500)
        XCTAssertLessThan(result.work, 10)
        // A combining mark typed at the caret joins the cluster before it.
        let accented = (prefix + "e") as NSString
        let onE = memo(accented, at: 501)
        incremental((prefix + "e\u{0301}") as NSString, 502, memo: onE, editFloor: 501)
    }

    func testCaretInsideASurrogatePair() {
        let text = "ab😀cd😀ef" as NSString
        let inside = 3
        incremental(text, inside, memo: memo(text, at: 7))
        incremental(text, 8, memo: memo(text, at: inside))
        incremental(text, 0, memo: memo(text, at: inside))
    }

    func testCaretInsideACombiningSequence() {
        let text = "abe\u{0301}\u{0302}cd" as NSString
        incremental(text, 4, memo: memo(text, at: 7))
        incremental(text, 7, memo: memo(text, at: 4))
        incremental(text, 1, memo: memo(text, at: 3))
    }

    /// Every (old, new) pair over strings built from the clusters whose
    /// boundaries are context-dependent; the column always equals the full count.
    func testEveryPairAgreesWithTheFullCount() {
        for sample in Self.sweepSamples {
            let text = sample as NSString
            for old in 0...text.length {
                let start = memo(text, at: old)
                for new in 0...text.length {
                    incremental(text, new, memo: start)
                }
            }
        }
    }

    /// The incremental path charges only what moved: the counted units plus the
    /// anchor search, never the line's prefix — and the full count, at the same
    /// caret, charges the whole prefix, so the seam does count it when scanned.
    func testIncrementalWorkIsChargedNotTheLinePrefix() {
        let text = String(repeating: "a", count: 4_000_000) as NSString
        let starts = LineStartIndex.offsets(in: text)
        let old = CaretReadout.ColumnMemo(lineStart: 0, offset: 2_000_000, column: 2_000_001)
        let moved = CaretReadout.countedPosition(
            text: text, caretOffset: 2_000_005, lineStarts: starts, memo: old, editFloor: nil
        )
        XCTAssertEqual(moved.column, 2_000_006)
        XCTAssertLessThanOrEqual(moved.work, 5 + CaretReadout.anchorLookback + 2)
        let full = CaretReadout.countedPosition(
            text: text, caretOffset: 2_000_005, lineStarts: starts, memo: nil, editFloor: nil
        )
        XCTAssertEqual(full.column, 2_000_006)
        XCTAssertGreaterThanOrEqual(full.work, 2_000_000)
    }

    /// With no ASCII anchor within the lookback, the full count runs.
    func testNoAnchorNearbyFallsBack() {
        let text = (String(repeating: "x", count: 10) + String(repeating: "é", count: 200)) as NSString
        let old = memo(text, at: 150)
        let result = incremental(text, 160, memo: old)
        XCTAssertGreaterThanOrEqual(result.work, 160)
    }

    // MARK: - The pre-edit rebase

    private static let sweepSamples = [
        "ab e\u{0301}\u{0301} cd",
        "x😀y👍🏽 z",
        "go 🇫🇷🇩🇪🇯🇵 now",
        "a 👨‍👩‍👧 b👩🏽‍💻c",
        "\u{1100}\u{1161}\u{11A8} ab \u{1100}\u{1161}",
        "ab \u{0915}\u{094D}\u{0937} cd \u{0915}\u{094D}x",
        "a \u{0600}1 b\u{0600}\u{0600}23 c",
        "plain ascii only here",
        "ab\u{0301}\ncd 😀\r\nef",
    ]

    /// Deletes `[editStart, caret)` from `before` with the memo at `caret`:
    /// rebases on the pre-edit text, then reads the post-edit caret through the
    /// memoised path, asserted against the full count. Returns the total work,
    /// or `nil` when the rebase declined.
    @discardableResult
    private func deleteEndingAtCaret(
        _ before: NSString,
        caret: Int,
        editStart: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int? {
        let old = memo(before, at: caret)
        let rebased = CaretReadout.countedRebasedMemo(old, text: before, editStart: editStart)
        guard let moved = rebased.memo else { return nil }
        XCTAssertLessThanOrEqual(moved.offset, editStart, file: file, line: line)
        let after = before.replacingCharacters(in: NSRange(location: editStart, length: caret - editStart), with: "")
            as NSString
        let result = incremental(after, editStart, memo: moved, editFloor: editStart, file: file, line: line)
        return rebased.work + result.work
    }

    /// One unit, a word and a selection, each ending at the caret, over every
    /// caret of the sweep strings: the column always equals the full count.
    /// A declined rebase asserts nothing, so each sample must also rebase at
    /// least once mid-line — or the sweep would quietly check ASCII alone.
    func testDeletionsEndingAtTheCaretAgreeWithTheFullCount() {
        for sample in Self.sweepSamples {
            let text = sample as NSString
            var midLineRebases = 0
            for caret in 1...text.length {
                for width in [1, 5, caret] where width <= caret {
                    let work = deleteEndingAtCaret(text, caret: caret, editStart: caret - width)
                    if work != nil, width < caret { midLineRebases += 1 }
                }
            }
            XCTAssertGreaterThan(midLineRebases, 0, "no deletion rebased mid-line in \(sample.debugDescription)")
        }
    }

    /// The rebase plus the next readout, on a 4,000,000-unit line with the memo
    /// at its end, charges the deleted span and two bounded searches — never
    /// the line's prefix.
    func testRebaseWorkIsChargedNotTheLinePrefix() {
        let length = 4_000_000
        let text = String(repeating: "a", count: length) as NSString
        let searches = 2 * (CaretReadout.anchorLookback + 2) + 1
        for (width, bound) in [(1, searches), (5, 5 + searches), (1_000, 1_000 + searches)] {
            let work = deleteEndingAtCaret(text, caret: length, editStart: length - width)
            XCTAssertNotNil(work, "width \(width) rebased")
            XCTAssertLessThanOrEqual(work ?? .max, bound, "width \(width)")
        }
    }

    func testAnEditAtOrPastTheMemoLeavesItUnchangedForFree() {
        let text = "abc def" as NSString
        let old = memo(text, at: 4)
        for start in [4, 6] {
            let rebased = CaretReadout.countedRebasedMemo(old, text: text, editStart: start)
            XCTAssertEqual(rebased.memo, old)
            XCTAssertEqual(rebased.work, 0)
        }
    }

    /// Idempotent: a second rebase at the same start returns the first answer.
    func testRebaseIsIdempotent() {
        let text = "let value = 42" as NSString
        let old = memo(text, at: 14)
        let once = CaretReadout.rebasedMemo(old, text: text, editStart: 10)
        XCTAssertNotNil(once)
        XCTAssertEqual(once.flatMap { CaretReadout.rebasedMemo($0, text: text, editStart: 10) }, once)
    }

    /// An edit starting before the memo's line start crosses a line start.
    func testAnEditBeforeTheLineStartDeclines() {
        let text = "first\nsecond line" as NSString
        let old = memo(text, at: 12)
        XCTAssertEqual(old.lineStart, 6)
        XCTAssertNil(CaretReadout.rebasedMemo(old, text: text, editStart: 4))
    }

    /// A deletion back to the line start is correct, and its anchor is the line
    /// start, so it pays for the whole prefix.
    func testADeletionBackToTheLineStartCountsThePrefix() {
        let text = "first\n" + String(repeating: "é😀", count: 50) as NSString
        let work = deleteEndingAtCaret(text, caret: text.length, editStart: 6)
        XCTAssertGreaterThanOrEqual(work ?? 0, text.length - 6)
    }

    /// With no ASCII anchor within the lookback below the edit, the rebase
    /// declines and the next readout takes the full count.
    func testNoAnchorBelowTheEditDeclines() {
        let text = (String(repeating: "x", count: 10) + String(repeating: "é", count: 200)) as NSString
        XCTAssertNil(deleteEndingAtCaret(text, caret: 200, editStart: 199))
    }
}
