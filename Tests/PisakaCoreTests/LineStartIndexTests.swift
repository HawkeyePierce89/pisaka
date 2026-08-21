import XCTest
@testable import PisakaCore

final class LineStartIndexTests: XCTestCase {
    private func offsets(_ s: String) -> [Int] {
        LineStartIndex.offsets(in: s as NSString)
    }

    // MARK: - offsets(in:)

    func testEmptyTextIsOneLine() {
        XCTAssertEqual(offsets(""), [0])
    }

    func testSingleLineNoTrailingSeparator() {
        XCTAssertEqual(offsets("abc"), [0])
    }

    func testTrailingLFAddsEmptyLine() {
        XCTAssertEqual(offsets("abc\n"), [0, 4])
    }

    func testMultipleLFLines() {
        XCTAssertEqual(offsets("a\nbb\nc"), [0, 2, 5])
    }

    func testCRLFCountsAsOneSeparator() {
        // "a\r\nb": the CRLF pair is a single separator, so two lines start at 0
        // and 3 (not an extra empty line between \r and \n).
        XCTAssertEqual(offsets("a\r\nb"), [0, 3])
    }

    func testBareCRSplitsLines() {
        // Classic-Mac line ending: LF-only counting would see one line; the
        // shared index splits on CR like the editor/ruler do.
        XCTAssertEqual(offsets("a\rb"), [0, 2])
    }

    func testUnicodeLineAndParagraphSeparatorsSplitLines() {
        XCTAssertEqual(offsets("a\u{2028}b"), [0, 2])
        XCTAssertEqual(offsets("a\u{2029}b"), [0, 2])
    }

    func testTrailingCRAddsEmptyLine() {
        XCTAssertEqual(offsets("a\r"), [0, 2])
    }

    // MARK: - endsWithLineSeparator

    func testEndsWithLineSeparator() {
        XCTAssertFalse(LineStartIndex.endsWithLineSeparator("" as NSString))
        XCTAssertFalse(LineStartIndex.endsWithLineSeparator("abc" as NSString))
        XCTAssertTrue(LineStartIndex.endsWithLineSeparator("abc\n" as NSString))
        XCTAssertTrue(LineStartIndex.endsWithLineSeparator("abc\r\n" as NSString))
        XCTAssertTrue(LineStartIndex.endsWithLineSeparator("abc\u{2029}" as NSString))
    }

    // MARK: - updated(...) basic cases

    /// Apply a replacement to `start`, then assert the incremental update matches
    /// a full rebuild of the resulting string.
    private func assertIncrementalMatchesFull(
        start: String,
        replace range: NSRange,
        with insertion: String,
        line: UInt = #line
    ) {
        let mutable = NSMutableString(string: start)
        let previous = LineStartIndex.offsets(in: mutable)
        let insertionNS = insertion as NSString
        mutable.replaceCharacters(in: range, with: insertion)
        let updated = LineStartIndex.updated(
            previous: previous,
            editedRange: NSRange(location: range.location, length: insertionNS.length),
            changeInLength: insertionNS.length - range.length,
            newText: mutable
        )
        XCTAssertEqual(updated, LineStartIndex.offsets(in: mutable), "text=\(mutable)", line: line)
    }

    func testInsertPlainCharacterNoNewLine() {
        assertIncrementalMatchesFull(start: "abc\ndef", replace: NSRange(location: 1, length: 0), with: "X")
    }

    func testInsertNewlineSplitsLine() {
        assertIncrementalMatchesFull(start: "abc\ndef", replace: NSRange(location: 1, length: 0), with: "\n")
    }

    func testInsertMultipleLines() {
        assertIncrementalMatchesFull(start: "abc\ndef", replace: NSRange(location: 2, length: 0), with: "1\n2\n3")
    }

    func testDeleteAcrossNewline() {
        assertIncrementalMatchesFull(start: "abc\ndef\nghi", replace: NSRange(location: 2, length: 4), with: "")
    }

    func testDeleteTrailingNewline() {
        assertIncrementalMatchesFull(start: "abc\n", replace: NSRange(location: 3, length: 1), with: "")
    }

    func testEditAtDocumentStart() {
        assertIncrementalMatchesFull(start: "abc\ndef", replace: NSRange(location: 0, length: 0), with: "Z\n")
    }

    func testEditAtDocumentEnd() {
        assertIncrementalMatchesFull(start: "abc\ndef", replace: NSRange(location: 7, length: 0), with: "\nghi")
    }

    func testInsertCRBeforeLFFormsCRLF() {
        // Inserting a CR immediately before an existing LF forms a CRLF pair,
        // which must collapse to a single separator (no spurious empty line).
        assertIncrementalMatchesFull(start: "a\nb", replace: NSRange(location: 1, length: 0), with: "\r")
    }

    func testFullReplacement() {
        assertIncrementalMatchesFull(start: "a\nb\nc", replace: NSRange(location: 0, length: 5), with: "x\ny")
    }

    // MARK: - updated(...) shift-only fast path

    /// Typing a plain character into the middle of a long single line (a
    /// minified-file stand-in) must not introduce or drop any line start.
    func testInsertPlainCharIntoLongSingleLine() {
        let line = String(repeating: "abc;", count: 5000) // one ~20k-char line, no breaks
        assertIncrementalMatchesFull(start: line, replace: NSRange(location: 10_000, length: 0), with: "Z")
    }

    /// Deleting a run of plain characters from a single line is also structure-
    /// preserving and must match a full rebuild.
    func testDeletePlainRunFromSingleLine() {
        let line = String(repeating: "abc;", count: 5000)
        assertIncrementalMatchesFull(start: line, replace: NSRange(location: 8_000, length: 50), with: "")
    }

    /// Inserting a plain character immediately before an existing LF shifts that
    /// line start by the delta without altering the line count.
    func testInsertPlainCharBeforeLF() {
        assertIncrementalMatchesFull(start: "abc\ndef", replace: NSRange(location: 3, length: 0), with: "X")
    }

    /// Inserting a plain character immediately after a bare CR must take the
    /// rescanning path (the CR could pair into a CRLF) yet still match a rebuild.
    func testInsertPlainCharAfterBareCR() {
        assertIncrementalMatchesFull(start: "a\rb", replace: NSRange(location: 2, length: 0), with: "X")
    }

    /// Deleting the CR of a CRLF pair (leaving a lone LF) keeps the line count and
    /// merely shifts the following line start.
    func testDeleteCROfCRLF() {
        assertIncrementalMatchesFull(start: "a\r\nb", replace: NSRange(location: 1, length: 1), with: "")
    }

    // MARK: - updated(...) fuzz equivalence

    /// A tiny deterministic LCG so the fuzz run is reproducible across machines.
    private struct LCG {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return bound <= 0 ? 0 : Int((state >> 33) % UInt64(bound))
        }
    }

    func testIncrementalMatchesFullRebuildUnderRandomEdits() {
        // Mix of plain text and every separator the index understands, including
        // the CRLF pair, so edits land on and across line boundaries. The cache is
        // carried forward (as in production) so a single drift would cascade and
        // is caught immediately.
        let alphabet = ["a", "b", "c", " ", "\t", "\n", "\r", "\r\n", "\u{2028}", "\u{2029}", "x", "y"]
        let seeds: [UInt64] = [0x1234_5678_9abc_def0, 0xdead_beef_cafe_babe, 0x0f0f_0f0f_f0f0_f0f0]

        for seed in seeds {
            var rng = LCG(state: seed)
            let text = NSMutableString(string: "the quick\nbrown\r\nfox\u{2028}jumps")
            var previous = LineStartIndex.offsets(in: text)

            for _ in 0..<3000 {
                let length = text.length
                let loc = rng.next(length + 1)
                let deleteLength = rng.next(length - loc + 1)
                var insertion = ""
                for _ in 0..<rng.next(4) {
                    insertion += alphabet[rng.next(alphabet.count)]
                }
                let insertionNS = insertion as NSString

                text.replaceCharacters(in: NSRange(location: loc, length: deleteLength), with: insertion)
                let updated = LineStartIndex.updated(
                    previous: previous,
                    editedRange: NSRange(location: loc, length: insertionNS.length),
                    changeInLength: insertionNS.length - deleteLength,
                    newText: text
                )
                let expected = LineStartIndex.offsets(in: text)
                guard updated == expected else {
                    let scalars = (0..<text.length)
                        .map { String(format: "%04x", text.character(at: $0)) }
                        .joined(separator: " ")
                    XCTFail("""
                        seed=\(String(format: "%016x", seed)) \
                        loc=\(loc) del=\(deleteLength) insLen=\(insertionNS.length)
                        text=[\(scalars)]
                        updated=\(updated)
                        expected=\(expected)
                        """)
                    return
                }
                previous = updated
            }
        }
    }

    // MARK: - isLineSeparator(_:)

    /// The predicate must answer exactly the set `offsets(in:)` splits on — asserted
    /// *against* `offsets` rather than against a second literal list, since a copy of
    /// the set in the test is the very duplication the predicate exists to remove.
    func testIsLineSeparatorAgreesWithLineSplitting() {
        let candidates: [unichar] = [
            0x0A, 0x0D, 0x85, 0x2028, 0x2029,   // the separators
            0x09, 0x0B, 0x0C, 0x20, 0x41, 0x7A // tab, VT, FF, space, letters
        ]
        for ch in candidates {
            let text = "a\(Character(UnicodeScalar(ch)!))b" as NSString
            let splits = LineStartIndex.offsets(in: text).count > 1
            XCTAssertEqual(
                LineStartIndex.isLineSeparator(ch),
                splits,
                "U+\(String(format: "%04X", ch))"
            )
        }
    }

    /// CRLF is two separator characters even though it is one line break, which is
    /// what the callers reading a single `unichar` need it to be.
    func testIsLineSeparatorAnswersBothHalvesOfCRLF() {
        XCTAssertTrue(LineStartIndex.isLineSeparator(0x0D))
        XCTAssertTrue(LineStartIndex.isLineSeparator(0x0A))
        XCTAssertEqual(offsets("a\r\nb"), [0, 3])
    }
}
