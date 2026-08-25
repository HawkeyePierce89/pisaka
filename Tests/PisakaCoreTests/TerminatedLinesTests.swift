import XCTest
@testable import PisakaCore

final class TerminatedLinesTests: XCTestCase {

    // MARK: - Separators

    func testLF() {
        XCTAssertEqual(
            TerminatedLines.split("a\nb\n"),
            [
                TerminatedLine(content: "a", terminator: "\n"),
                TerminatedLine(content: "b", terminator: "\n"),
            ]
        )
    }

    func testCR() {
        XCTAssertEqual(
            TerminatedLines.split("a\rb\r"),
            [
                TerminatedLine(content: "a", terminator: "\r"),
                TerminatedLine(content: "b", terminator: "\r"),
            ]
        )
    }

    /// CRLF is *one* separator, never split into a CR line plus an LF line.
    func testCRLFIsOneSeparator() {
        XCTAssertEqual(
            TerminatedLines.split("a\r\nb\r\n"),
            [
                TerminatedLine(content: "a", terminator: "\r\n"),
                TerminatedLine(content: "b", terminator: "\r\n"),
            ]
        )
    }

    func testNEL() {
        XCTAssertEqual(
            TerminatedLines.split("a\u{0085}b\u{0085}"),
            [
                TerminatedLine(content: "a", terminator: "\u{0085}"),
                TerminatedLine(content: "b", terminator: "\u{0085}"),
            ]
        )
    }

    func testLineSeparator2028() {
        XCTAssertEqual(
            TerminatedLines.split("a\u{2028}b"),
            [
                TerminatedLine(content: "a", terminator: "\u{2028}"),
                TerminatedLine(content: "b", terminator: ""),
            ]
        )
    }

    func testParagraphSeparator2029() {
        XCTAssertEqual(
            TerminatedLines.split("a\u{2029}b"),
            [
                TerminatedLine(content: "a", terminator: "\u{2029}"),
                TerminatedLine(content: "b", terminator: ""),
            ]
        )
    }

    /// Mixed endings survive verbatim, each line keeping its own terminator.
    func testMixedSeparatorsKeepTheirOwnTerminator() {
        XCTAssertEqual(
            TerminatedLines.split("a\r\nb\nc\rd"),
            [
                TerminatedLine(content: "a", terminator: "\r\n"),
                TerminatedLine(content: "b", terminator: "\n"),
                TerminatedLine(content: "c", terminator: "\r"),
                TerminatedLine(content: "d", terminator: ""),
            ]
        )
    }

    // MARK: - Boundaries

    /// A file with no trailing newline: the last line's terminator is empty, which
    /// is what makes "missing final newline" fall out of the ordinary rule rather
    /// than needing a branch of its own.
    func testFinalLineWithoutTerminator() {
        XCTAssertEqual(
            TerminatedLines.split("a\nb"),
            [
                TerminatedLine(content: "a", terminator: "\n"),
                TerminatedLine(content: "b", terminator: ""),
            ]
        )
    }

    func testEmptyText() {
        XCTAssertEqual(TerminatedLines.split(""), [])
    }

    /// A trailing separator does not produce a phantom empty final line (the
    /// `LineDiff.splitLines` rule, inherited because that function is a projection
    /// of this one).
    func testTrailingSeparatorAddsNoPhantomLine() {
        XCTAssertEqual(TerminatedLines.split("a\n").count, 1)
    }

    func testSeparatorsOnly() {
        XCTAssertEqual(
            TerminatedLines.split("\n\r\n\r"),
            [
                TerminatedLine(content: "", terminator: "\n"),
                TerminatedLine(content: "", terminator: "\r\n"),
                TerminatedLine(content: "", terminator: "\r"),
            ]
        )
    }

    func testBlankLinesBetweenContent() {
        XCTAssertEqual(
            TerminatedLines.split("a\n\nb"),
            [
                TerminatedLine(content: "a", terminator: "\n"),
                TerminatedLine(content: "", terminator: "\n"),
                TerminatedLine(content: "b", terminator: ""),
            ]
        )
    }

    // MARK: - Round-trip invariant

    /// The structural invariant the partial-commit builder rests on: concatenating
    /// every `content + terminator` reproduces the input byte for byte. Without it
    /// an "assemble from the old side verbatim" step could not be trusted to leave
    /// untouched lines untouched.
    func testConcatenationReproducesInput() {
        let samples = [
            "",
            "a",
            "a\n",
            "a\nb",
            "a\r\nb\r\n",
            "\n\n\n",
            "a\r\nb\nc\rd\u{2028}e\u{2029}f\u{0085}g",
            "\r\n\r\n",
            "line with spaces   \n\ttabbed\n",
            "🙂\n🙃",
        ]
        for text in samples {
            let rebuilt = TerminatedLines.split(text).map { $0.content + $0.terminator }.joined()
            XCTAssertEqual(rebuilt, text, "round-trip failed for \(String(reflecting: text))")
        }
    }

    // MARK: - Consistency with LineDiff.splitLines

    /// Deterministic LCG (the `LineStartIndexTests` style) so the fuzz run is
    /// reproducible across machines.
    private struct LCG {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return bound <= 0 ? 0 : Int((state >> 33) % UInt64(bound))
        }
    }

    /// `TerminatedLines.split` and `LineDiff.splitLines` must agree on what a line
    /// *is* for every separator and every mixture of them: the diff's row indices
    /// are the selection units, while the builder assembles bytes through this
    /// splitter, so a single disagreement would silently assemble the wrong lines.
    ///
    /// This test has two lives. It was written and run **before** `splitLines` was
    /// rewritten, against its own independent implementation — there it pinned the
    /// refactor, proving two separate algorithms agreed on random mixtures of every
    /// separator. Now that `splitLines` is a projection of `split`, it is a
    /// tautology, and that is deliberate: its role became a regression lock against
    /// *un-projecting* — reintroducing a second, independently written line splitter
    /// that could drift from this one.
    func testSplitContentsMatchLineDiffSplitLines() {
        let alphabet = [
            "a", "b", "c", " ", "\t", "\n", "\r", "\r\n",
            "\u{0085}", "\u{2028}", "\u{2029}", "x", "🙂",
        ]
        let seeds: [UInt64] = [0x1234_5678_9abc_def0, 0xdead_beef_cafe_babe, 0x0f0f_0f0f_f0f0_f0f0]

        for seed in seeds {
            var rng = LCG(state: seed)
            for _ in 0..<400 {
                var text = ""
                for _ in 0..<rng.next(24) {
                    text += alphabet[rng.next(alphabet.count)]
                }
                let contents = TerminatedLines.split(text).map(\.content)
                XCTAssertEqual(
                    contents,
                    LineDiff.splitLines(text),
                    "seed=\(String(format: "%016x", seed)) text=\(String(reflecting: text))"
                )
                // The round-trip must hold on the same random input, so the fuzz
                // covers the terminators too and not only the contents.
                XCTAssertEqual(
                    TerminatedLines.split(text).map { $0.content + $0.terminator }.joined(),
                    text
                )
            }
        }
    }

    /// Fixed mixtures that the random fuzz would only hit by luck, kept as an
    /// explicit table so a failure names the exact separator combination.
    func testSplitContentsMatchLineDiffSplitLinesOnFixedMixtures() {
        let samples = [
            "",
            "\n",
            "\r",
            "\r\n",
            "a\r\n\nb",
            "a\n\rb",
            "\r\r\n\n",
            "a\u{0085}\u{2028}\u{2029}b",
            "no terminator at all",
        ]
        for text in samples {
            XCTAssertEqual(
                TerminatedLines.split(text).map(\.content),
                LineDiff.splitLines(text),
                "mismatch for \(String(reflecting: text))"
            )
        }
    }

    // MARK: - Ranges

    /// The range split is the same split, carrying offsets: the content range is
    /// the line, the terminator range the separator that ended it (empty, and
    /// pinned to the content's end, for an unterminated final line).
    func testRangesCarryContentAndTerminatorOffsets() {
        XCTAssertEqual(
            TerminatedLines.ranges("ab\ncd"),
            [
                TerminatedLineRange(content: NSRange(location: 0, length: 2), terminator: NSRange(location: 2, length: 1)),
                TerminatedLineRange(content: NSRange(location: 3, length: 2), terminator: NSRange(location: 5, length: 0)),
            ]
        )
    }

    /// The CRLF pair is one terminator of length two, never a CR line plus an LF
    /// line — the offsets inherit the splitter's rule rather than restating it.
    func testRangesKeepTheCRLFPairInOneTerminatorRange() {
        XCTAssertEqual(
            TerminatedLines.ranges("a\r\nb"),
            [
                TerminatedLineRange(content: NSRange(location: 0, length: 1), terminator: NSRange(location: 1, length: 2)),
                TerminatedLineRange(content: NSRange(location: 3, length: 1), terminator: NSRange(location: 4, length: 0)),
            ]
        )
    }

    /// Every separator in the editor's set is one terminator range of its own
    /// UTF-16 length.
    func testRangesCoverEverySeparatorInTheEditorsSet() {
        let separators = ["\n", "\r", "\r\n", "\u{0085}", "\u{2028}", "\u{2029}"]
        for separator in separators {
            let text = "a" + separator + "b"
            let ranges = TerminatedLines.ranges(text)
            XCTAssertEqual(ranges.count, 2, "for \(String(reflecting: separator))")
            XCTAssertEqual(
                ranges.first?.terminator,
                NSRange(location: 1, length: (separator as NSString).length),
                "for \(String(reflecting: separator))"
            )
        }
    }

    func testRangesOfAnEmptyTextAreEmpty() {
        XCTAssertEqual(TerminatedLines.ranges(""), [])
    }

    /// The last line of a text that does not end in a separator carries an empty
    /// terminator range at end of file, so "missing final newline" is readable as
    /// `terminator.length == 0` with no separate branch.
    func testRangesOfAnUnterminatedFinalLine() {
        let ranges = TerminatedLines.ranges("a\nbc")
        XCTAssertEqual(ranges.last?.content, NSRange(location: 2, length: 2))
        XCTAssertEqual(ranges.last?.terminator, NSRange(location: 4, length: 0))
    }

    /// `enclosing` is the line as it appears in the text, terminator included.
    func testEnclosingCoversContentAndTerminator() {
        let ranges = TerminatedLines.ranges("ab\r\ncd")
        XCTAssertEqual(ranges.first?.enclosing, NSRange(location: 0, length: 4))
        XCTAssertEqual(ranges.last?.enclosing, NSRange(location: 4, length: 2))
    }

    /// The ranges tile the text: every enclosing range starts where the previous
    /// one ended, and together they cover it exactly. This is what lets an edit
    /// plan be expressed against original offsets with no gaps or overlaps.
    func testRangesTileTheWholeText() {
        let samples = [
            "",
            "a",
            "a\n",
            "a\r\nb\nc\rd\u{2028}e\u{2029}f\u{0085}g",
            "\n\n\n",
            "🙂\n🙃",
        ]
        for text in samples {
            var expected = 0
            for range in TerminatedLines.ranges(text) {
                XCTAssertEqual(range.content.location, expected, "for \(String(reflecting: text))")
                XCTAssertEqual(range.terminator.location, NSMaxRange(range.content), "for \(String(reflecting: text))")
                expected = NSMaxRange(range.terminator)
            }
            XCTAssertEqual(expected, (text as NSString).length, "for \(String(reflecting: text))")
        }
    }

    /// `split(_:)` must stay a *projection* of the range split rather than a
    /// second traversal that agrees today: the same regression-lock role the
    /// `LineDiff.splitLines` fuzz above plays one level down.
    func testSplitIsAProjectionOfTheRangeSplit() {
        let alphabet = [
            "a", "b", "c", " ", "\t", "\n", "\r", "\r\n",
            "\u{0085}", "\u{2028}", "\u{2029}", "x", "🙂",
        ]
        let seeds: [UInt64] = [0x1234_5678_9abc_def0, 0xdead_beef_cafe_babe, 0x0f0f_0f0f_f0f0_f0f0]

        for seed in seeds {
            var rng = LCG(state: seed)
            for _ in 0..<400 {
                var text = ""
                for _ in 0..<rng.next(24) {
                    text += alphabet[rng.next(alphabet.count)]
                }
                let ns = text as NSString
                let projected = TerminatedLines.ranges(text).map {
                    TerminatedLine(
                        content: ns.substring(with: $0.content),
                        terminator: ns.substring(with: $0.terminator)
                    )
                }
                XCTAssertEqual(
                    projected,
                    TerminatedLines.split(text),
                    "seed=\(String(format: "%016x", seed)) text=\(String(reflecting: text))"
                )
            }
        }
    }
}
