import XCTest
@testable import PisakaCore

/// The offset↔position bridge (D1).
///
/// Every number that crosses this file is a number the *other* side counted, so
/// the two things being pinned here are that the separator rule is LSP's and not
/// the editor's, and that a hostile or merely stale position from a server can
/// never produce an `NSString` index that traps.
final class LSPPositionMapTests: XCTestCase {
    private func map(_ text: String) -> NSString { text as NSString }

    /// Both directions agree for every offset in the buffer. This is the
    /// invariant the whole file exists to provide, so it is asserted
    /// exhaustively rather than at sampled points.
    ///
    /// One offset is excluded, and only one: the position *between* the CR and
    /// the LF of a CRLF. LSP counts that pair as a single separator, so the line
    /// it ends has no character index there to name — the offset is inside the
    /// separator, not inside the line. Both directions of this map agree that it
    /// is not addressable (`testAnOffsetInsideACRLFPairIsNotAnAddressablePosition`
    /// pins what they do instead), and the editor never puts a caret there either,
    /// because TextKit treats CRLF as one composed character.
    private func assertRoundTrip(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let content = map(text)
        for offset in 0...content.length where !isInsideCRLF(offset, in: content) {
            let position = LSPPositionMap.position(forOffset: offset, in: content)
            XCTAssertEqual(
                LSPPositionMap.offset(for: position, in: content),
                offset,
                "offset \(offset) → \(position) → not back again",
                file: file,
                line: line
            )
        }
    }

    private func isInsideCRLF(_ offset: Int, in content: NSString) -> Bool {
        offset > 0 && offset < content.length
            && content.character(at: offset - 1) == 0x000D
            && content.character(at: offset) == 0x000A
    }

    // MARK: - Line starts

    func testEmptyDocumentIsOneLine() {
        XCTAssertEqual(LSPPositionMap.lineStarts(in: map("")), [0])
        XCTAssertEqual(
            LSPPositionMap.position(forOffset: 0, in: map("")),
            LSPPosition(line: 0, character: 0)
        )
    }

    func testLineFeedStartsALine() {
        XCTAssertEqual(LSPPositionMap.lineStarts(in: map("ab\ncd")), [0, 3])
    }

    func testCarriageReturnLineFeedIsOneSeparator() {
        // Two code units, one line break: counting them separately would insert
        // a phantom empty line and shift every later line number by one.
        XCTAssertEqual(LSPPositionMap.lineStarts(in: map("ab\r\ncd")), [0, 4])
    }

    func testLoneCarriageReturnStartsALine() {
        XCTAssertEqual(LSPPositionMap.lineStarts(in: map("ab\rcd")), [0, 3])
    }

    func testTrailingSeparatorAddsTheEmptyLastLine() {
        // A server can legitimately point at the position after the final
        // newline; without this entry that position would clamp backwards.
        XCTAssertEqual(LSPPositionMap.lineStarts(in: map("ab\n")), [0, 3])
        XCTAssertEqual(
            LSPPositionMap.position(forOffset: 3, in: map("ab\n")),
            LSPPosition(line: 1, character: 0)
        )
    }

    func testNoTrailingSeparatorMeansNoExtraLine() {
        XCTAssertEqual(LSPPositionMap.lineStarts(in: map("ab")), [0])
        XCTAssertEqual(
            LSPPositionMap.position(forOffset: 2, in: map("ab")),
            LSPPosition(line: 0, character: 2)
        )
    }

    func testConsecutiveSeparatorsMakeEmptyLines() {
        XCTAssertEqual(LSPPositionMap.lineStarts(in: map("a\n\n\nb")), [0, 2, 3, 4])
    }

    func testMixedSeparatorsInOneDocument() {
        //  a \n  b \r\n  c \r  d
        //  0 1   2 3 4   5 6   7
        XCTAssertEqual(LSPPositionMap.lineStarts(in: map("a\nb\r\nc\rd")), [0, 2, 5, 7])
    }

    // MARK: - Offset → position

    func testPositionIsCountedWithinItsLine() {
        let content = map("let x = 1\nlet y = 2\n")
        XCTAssertEqual(
            LSPPositionMap.position(forOffset: 14, in: content),
            LSPPosition(line: 1, character: 4)
        )
    }

    func testPositionOfALineStart() {
        let content = map("one\ntwo\nthree")
        XCTAssertEqual(
            LSPPositionMap.position(forOffset: 8, in: content),
            LSPPosition(line: 2, character: 0)
        )
    }

    func testOffsetPastTheEndClampsToTheEnd() {
        let content = map("ab\ncd")
        XCTAssertEqual(
            LSPPositionMap.position(forOffset: 999, in: content),
            LSPPosition(line: 1, character: 2)
        )
    }

    func testNegativeOffsetClampsToTheStart() {
        XCTAssertEqual(
            LSPPositionMap.position(forOffset: -5, in: map("ab")),
            LSPPosition(line: 0, character: 0)
        )
    }

    // MARK: - Position → offset

    func testOffsetOfAPosition() {
        let content = map("one\ntwo\nthree")
        XCTAssertEqual(LSPPositionMap.offset(for: LSPPosition(line: 1, character: 2), in: content), 6)
    }

    func testCharacterPastTheEndOfItsLineClampsToTheLineEnd() {
        // Not to the end of the *document*: a stale position must not smear a
        // jump across the rest of the file.
        let content = map("ab\ncdef")
        XCTAssertEqual(LSPPositionMap.offset(for: LSPPosition(line: 0, character: 99), in: content), 2)
    }

    /// The clamp has to survive numbers no real server sends, because it is the
    /// boundary an untrusted one crosses.
    ///
    /// `character` is an `Int` decoded off the wire, so `start + character` is an
    /// overflow away from trapping — and a trap here is a hard crash of the editor
    /// on one malformed response, on the one path where every other failure
    /// degrades quietly to tree-sitter.
    func testAnAbsurdCharacterClampsInsteadOfOverflowing() {
        let content = map("ab\ncdef")
        XCTAssertEqual(
            LSPPositionMap.offset(for: LSPPosition(line: 0, character: .max), in: content), 2
        )
        XCTAssertEqual(
            LSPPositionMap.offset(for: LSPPosition(line: 1, character: .max), in: content), 7
        )
        XCTAssertEqual(
            LSPPositionMap.range(
                for: LSPRange(
                    start: LSPPosition(line: 0, character: .max),
                    end: LSPPosition(line: 1, character: .max)
                ),
                in: content
            ),
            NSRange(location: 2, length: 5)
        )
    }

    func testCharacterPastTheEndOfACRLFLineStopsBeforeTheCR() {
        // The dangerous clamp: stopping one unit short would land *between* CR
        // and LF, an offset the editor treats as inside a single character.
        let content = map("ab\r\ncd")
        XCTAssertEqual(LSPPositionMap.offset(for: LSPPosition(line: 0, character: 99), in: content), 2)
    }

    /// The one offset the two directions cannot round-trip, stated outright.
    ///
    /// Between the CR and the LF there is no line and no character: LSP counts
    /// the pair as one separator. Mapping outward yields a character past the
    /// line's content, and mapping that back clamps to the line's end — the same
    /// answer a caret one unit earlier gives. The alternative would be to invent
    /// a position inside a separator, which is what desynchronises a client from
    /// a server that never agreed such a position exists.
    func testAnOffsetInsideACRLFPairIsNotAnAddressablePosition() {
        let content = map("ab\r\ncd")
        let position = LSPPositionMap.position(forOffset: 3, in: content)
        XCTAssertEqual(position, LSPPosition(line: 0, character: 3))
        XCTAssertEqual(LSPPositionMap.offset(for: position, in: content), 2)
    }

    func testLinePastTheEndClampsToTheDocumentEnd() {
        let content = map("ab\ncd")
        XCTAssertEqual(LSPPositionMap.offset(for: LSPPosition(line: 42, character: 0), in: content), 5)
    }

    func testNegativeCoordinatesClampToZero() {
        let content = map("ab\ncd")
        XCTAssertEqual(LSPPositionMap.offset(for: LSPPosition(line: -1, character: 3), in: content), 0)
        XCTAssertEqual(LSPPositionMap.offset(for: LSPPosition(line: 1, character: -4), in: content), 3)
    }

    func testEmptyDocumentAnswersZeroForAnyPosition() {
        let content = map("")
        XCTAssertEqual(LSPPositionMap.offset(for: LSPPosition(line: 0, character: 0), in: content), 0)
        XCTAssertEqual(LSPPositionMap.offset(for: LSPPosition(line: 9, character: 9), in: content), 0)
    }

    // MARK: - Round trips

    func testRoundTripAcrossLineFeeds() {
        assertRoundTrip("let a = 1\nlet b = 2\nlet c = 3")
    }

    func testRoundTripAcrossCRLF() {
        assertRoundTrip("first\r\nsecond\r\nthird")
    }

    func testRoundTripAcrossALoneCarriageReturn() {
        assertRoundTrip("first\rsecond\rthird")
    }

    func testRoundTripWithEmptyLines() {
        assertRoundTrip("a\n\n\nb\n")
    }

    func testRoundTripAtEOFWithATrailingNewline() {
        assertRoundTrip("value\n")
    }

    func testRoundTripAtEOFWithoutATrailingNewline() {
        assertRoundTrip("value")
    }

    // MARK: - UTF-16

    func testCharactersAreUTF16CodeUnitsNotCharacters() {
        // "é" is one UTF-16 unit; "🎉" is two. Counting Swift `Character`s here
        // would put every later position on the line one short.
        let content = map("let e = \"é🎉\" // tail")
        XCTAssertEqual(content.length, 21)
        XCTAssertEqual(
            LSPPositionMap.position(forOffset: 13, in: content),
            LSPPosition(line: 0, character: 13)
        )
        XCTAssertEqual(
            LSPPositionMap.offset(for: LSPPosition(line: 0, character: 13), in: content),
            13
        )
    }

    func testAPositionInsideASurrogatePairIsAddressable() {
        // A server is entitled to point between the halves of a pair; that is a
        // legal `NSString` index and must map to itself, not be rounded away.
        let content = map("🎉x")
        XCTAssertEqual(
            LSPPositionMap.offset(for: LSPPosition(line: 0, character: 1), in: content),
            1
        )
        XCTAssertEqual(
            LSPPositionMap.position(forOffset: 1, in: content),
            LSPPosition(line: 0, character: 1)
        )
    }

    func testRoundTripAcrossSurrogatePairs() {
        assertRoundTrip("emoji 🎉 and 👩‍💻 then\nmore 🎉\n")
    }

    // MARK: - The documented divergence (D1)

    /// NEL, U+2028 and U+2029 are line separators to `LineStartIndex` (and to
    /// TextKit, and so to the gutter) and are **not** line separators to LSP.
    ///
    /// This is asserted rather than assumed because it is the one place the
    /// editor and the server are knowingly allowed to disagree, and the shape of
    /// the disagreement is what bounds its consequences: the *offsets* stay
    /// exact, so every jump and every edit lands correctly; only the two line
    /// numberings differ, and no LSP line number is ever displayed. If a future
    /// change made this file use `LineStartIndex`, this test would fail — which
    /// is the point.
    func testUnicodeSeparatorsDivergeFromTheEditorsLineCount() {
        let content = map("alpha\u{2028}beta\u{2029}gamma\u{0085}delta")

        // The editor sees four lines…
        XCTAssertEqual(LineStartIndex.offsets(in: content).count, 4)
        // …and LSP sees one.
        XCTAssertEqual(LSPPositionMap.lineStarts(in: content), [0])

        // The numbering differs: "beta" starts the editor's line 1 and is still
        // on LSP's line 0.
        let betaOffset = content.range(of: "beta").location
        XCTAssertEqual(LineStartIndex.offsets(in: content)[1], betaOffset)
        XCTAssertEqual(
            LSPPositionMap.position(forOffset: betaOffset, in: content),
            LSPPosition(line: 0, character: betaOffset)
        )

        // The offset does not: a round trip through the LSP position recovers
        // exactly the offset it started from, which is why the divergence costs
        // a displayed number and never a wrong jump.
        assertRoundTrip("alpha\u{2028}beta\u{2029}gamma\u{0085}delta")
    }

    func testUnicodeSeparatorsStillRoundTripWhenMixedWithRealOnes() {
        assertRoundTrip("a\u{2028}b\nc\u{0085}d\r\ne")
    }

    // MARK: - Ranges

    func testRangeMapsBothEnds() {
        let content = map("one\ntwo\nthree")
        let range = LSPPositionMap.range(
            for: LSPRange(
                start: LSPPosition(line: 0, character: 1),
                end: LSPPosition(line: 2, character: 3)
            ),
            in: content
        )
        XCTAssertEqual(range, NSRange(location: 1, length: 10))
    }

    func testReversedRangeCollapsesInsteadOfGoingNegative() {
        // `NSRange` has no negative length; a reversed range from a confused
        // server must degrade to a caret, not trap at the call site.
        let content = map("one\ntwo")
        let range = LSPPositionMap.range(
            for: LSPRange(
                start: LSPPosition(line: 1, character: 2),
                end: LSPPosition(line: 0, character: 0)
            ),
            in: content
        )
        XCTAssertEqual(range, NSRange(location: 6, length: 0))
    }

    func testEmptyRangeIsACaretPosition() {
        let content = map("one\ntwo")
        let range = LSPPositionMap.range(
            for: LSPRange(at: LSPPosition(line: 1, character: 1)),
            in: content
        )
        XCTAssertEqual(range, NSRange(location: 5, length: 0))
    }

    // MARK: - Precomputed line starts

    func testPrecomputedLineStartsAgreeWithTheOneShotForm() {
        let content = map("alpha\nbeta\r\ngamma\rdelta\n")
        let starts = LSPPositionMap.lineStarts(in: content)
        for offset in 0...content.length {
            XCTAssertEqual(
                LSPPositionMap.position(
                    forOffset: offset,
                    lineStarts: starts,
                    length: content.length
                ),
                LSPPositionMap.position(forOffset: offset, in: content)
            )
        }
        for line in 0..<starts.count {
            for character in [0, 1, 3, 99] {
                let position = LSPPosition(line: line, character: character)
                XCTAssertEqual(
                    LSPPositionMap.offset(for: position, in: content, lineStarts: starts),
                    LSPPositionMap.offset(for: position, in: content)
                )
            }
        }
    }
}
