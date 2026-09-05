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
    ///
    /// The projection check alone is a tautology while `split` is written as that
    /// map, so the same random texts are also held against an **independent**
    /// statement of what `ranges(_:)` must be — one that never mentions `split`:
    /// the enclosing ranges tile the text from 0 to its end with no gap and no
    /// overlap, every terminator is drawn from the editor's own separator set,
    /// and the line starts are exactly `LineStartIndex.offsets(in:)`. Those are
    /// the offsets `SaveTransform` edits through, so they are the half that has to
    /// be fuzzed against something other than itself.
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
                let ranges = TerminatedLines.ranges(text)
                let label = "seed=\(String(format: "%016x", seed)) text=\(String(reflecting: text))"

                // The independent half: what the ranges must be, said without
                // reference to `split`.
                let separators: Set<String> = ["\n", "\r", "\r\n", "\u{0085}", "\u{2028}", "\u{2029}"]
                var cursor = 0
                for range in ranges {
                    XCTAssertEqual(range.content.location, cursor, "no gap, no overlap — \(label)")
                    XCTAssertEqual(range.terminator.location, NSMaxRange(range.content), "terminator abuts content — \(label)")
                    let terminator = ns.substring(with: range.terminator)
                    XCTAssertTrue(
                        terminator.isEmpty || separators.contains(terminator),
                        "terminator \(String(reflecting: terminator)) — \(label)"
                    )
                    cursor = NSMaxRange(range.enclosing)
                }
                XCTAssertEqual(cursor, ns.length, "the ranges tile the whole text — \(label)")
                // `LineStartIndex` is the editor's other traversal of the same
                // separator set, and it *does* carry the phantom final empty line
                // a trailing separator creates. Removing exactly that entry is
                // what "a trailing separator adds no phantom line" means here.
                var expectedStarts = ns.length == 0 ? [] : LineStartIndex.offsets(in: ns)
                if LineStartIndex.endsWithLineSeparator(ns) { expectedStarts.removeLast() }
                XCTAssertEqual(ranges.map(\.content.location), expectedStarts, "line starts — \(label)")

                let projected = ranges.map {
                    TerminatedLine(
                        content: ns.substring(with: $0.content),
                        terminator: ns.substring(with: $0.terminator)
                    )
                }
                XCTAssertEqual(projected, TerminatedLines.split(text), label)
            }
        }
    }

    // MARK: - The bounded primitive

    /// Over the full range the primitive tiles the text exactly: the enclosing
    /// ranges abut with no gap and no overlap, and concatenating them
    /// reproduces the input character for character.
    ///
    /// Deliberately *not* a comparison against `ranges(_:)`: that form is now
    /// literally this call over the full range, so the two agreeing proves
    /// nothing about either. Fuzzed over the same separator alphabet the
    /// projection fuzz uses.
    func testBoundedRangesOverTheFullRangeTileTheText() {
        var rng = LCG(state: 0x5eed_1234_5678_9abc)
        for _ in 0..<400 {
            let text = Self.fuzzText(&rng)
            let ns = text as NSString
            let ranges = TerminatedLines.ranges(in: ns, range: NSRange(location: 0, length: ns.length))
            let label = String(reflecting: text)
            var next = 0
            var rebuilt = ""
            for line in ranges {
                XCTAssertEqual(line.content.location, next, label)
                XCTAssertEqual(line.terminator.location, NSMaxRange(line.content), label)
                rebuilt += ns.substring(with: line.content) + ns.substring(with: line.terminator)
                next = NSMaxRange(line.terminator)
            }
            XCTAssertEqual(next, ns.length, label)
            XCTAssertEqual(rebuilt, text, label)
        }
    }

    /// **The bounding itself**, which is the whole reason the primitive exists:
    /// asking about a sub-range answers exactly the lines of the full split that
    /// the range's line-expanded span covers — no more (the point: a redraw does
    /// not walk the file) and no fewer (a line the range touches is never
    /// dropped). Fuzzed over random sub-ranges of random texts.
    ///
    /// A reimplementation that enumerated the whole file and filtered would pass
    /// this; what it pins is the *answer*, and the "no more" half is what a
    /// clipped-instead-of-expanded regression breaks.
    func testBoundedRangesAnswerExactlyTheLinesTheRangeCovers() {
        var rng = LCG(state: 0xb0_1ded_1234_5678)
        for _ in 0..<400 {
            let text = Self.fuzzText(&rng)
            let ns = text as NSString
            guard ns.length > 0 else { continue }
            let location = rng.next(ns.length)
            let length = rng.next(ns.length - location + 1)
            let asked = NSRange(location: location, length: length)
            let label = "\(String(reflecting: text)) \(NSStringFromRange(asked))"
            let expanded = ns.lineRange(for: asked)
            let expected = TerminatedLines.ranges(in: ns, range: NSRange(location: 0, length: ns.length))
                .filter { NSMaxRange($0.terminator) > expanded.location && $0.content.location < NSMaxRange(expanded) }
            XCTAssertEqual(TerminatedLines.ranges(in: ns, range: asked), expected, label)
        }
    }

    /// The conventional "not found" range shape. Its location is `Int.max`, so a
    /// clamp that sums location and length before bounding either overflows and
    /// traps — where this function documents an answer.
    func testBoundedRangesOfANotFoundRangeAreAnswered() {
        let text = "one\ntwo" as NSString
        XCTAssertEqual(
            TerminatedLines.ranges(in: text, range: NSRange(location: NSNotFound, length: 1)).map { text.substring(with: $0.content) },
            ["two"]
        )
        XCTAssertEqual(
            TerminatedLines.ranges(in: text, range: NSRange(location: 1, length: Int.max)).map { text.substring(with: $0.content) },
            ["one", "two"]
        )
    }

    /// The alphabet both bounded fuzzes draw from: every separator in the
    /// editor's set, the CRLF pair, and a non-BMP character so a UTF-16 pair is
    /// never split.
    private static func fuzzText(_ rng: inout LCG) -> String {
        let alphabet = [
            "a", "b", " ", "\t", "\n", "\r", "\r\n",
            "\u{0085}", "\u{2028}", "\u{2029}", "🙂",
        ]
        var text = ""
        for _ in 0..<rng.next(20) {
            text += alphabet[rng.next(alphabet.count)]
        }
        return text
    }

    /// A range that starts and ends mid-line answers those lines *whole* —
    /// never a fragment — which is what lets a caller reason about a drawn
    /// region without knowing where it cut.
    func testBoundedRangesExpandAMidLineRangeToWholeLines() {
        let text = "alpha\nbravo\ncharlie\n" as NSString
        // From inside "alpha" to inside "bravo".
        let ranges = TerminatedLines.ranges(in: text, range: NSRange(location: 2, length: 6))
        XCTAssertEqual(ranges.map { text.substring(with: $0.content) }, ["alpha", "bravo"])
        XCTAssertEqual(ranges.map { text.substring(with: $0.terminator) }, ["\n", "\n"])
    }

    /// Only the lines the range touches are visited — the point of bounding it.
    func testBoundedRangesVisitOnlyTheLinesTheRangeTouches() {
        let text = "one\ntwo\nthree\nfour\n" as NSString
        let ranges = TerminatedLines.ranges(in: text, range: NSRange(location: 4, length: 1))
        XCTAssertEqual(ranges.map { text.substring(with: $0.content) }, ["two"])
    }

    /// A zero-length range still names the line it sits in.
    func testBoundedRangesOfACaretAnswerItsLine() {
        let text = "one\ntwo\n" as NSString
        let ranges = TerminatedLines.ranges(in: text, range: NSRange(location: 5, length: 0))
        XCTAssertEqual(ranges.map { text.substring(with: $0.content) }, ["two"])
    }

    /// Out-of-bounds and negative requests are clamped, not trapped.
    func testBoundedRangesClampAnOutOfBoundsRequest() {
        let text = "one\ntwo" as NSString
        XCTAssertEqual(
            TerminatedLines.ranges(in: text, range: NSRange(location: 0, length: 999)),
            TerminatedLines.ranges("one\ntwo")
        )
        // Clamped to a caret at the end of the text, which names the last line.
        XCTAssertEqual(
            TerminatedLines.ranges(in: text, range: NSRange(location: 99, length: 5)).map { text.substring(with: $0.content) },
            ["two"]
        )
        XCTAssertEqual(
            TerminatedLines.ranges(in: text, range: NSRange(location: -4, length: 2)).map { text.substring(with: $0.content) },
            ["one"]
        )
    }

    func testBoundedRangesOfAnEmptyTextAreEmpty() {
        XCTAssertEqual(TerminatedLines.ranges(in: "" as NSString, range: NSRange(location: 0, length: 0)), [])
    }
}
