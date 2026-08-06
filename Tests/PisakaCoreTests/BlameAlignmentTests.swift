import XCTest
@testable import PisakaCore

/// `BlameAlignment` places a git-blame result (numbered by LF-delimited lines)
/// onto the editor's line starts, which follow `LineStartIndex`'s wider separator
/// set. The cases below pin the identity mapping for the ordinary file, the real
/// misalignment it exists to prevent, and the degenerate inputs.
final class BlameAlignmentTests: XCTestCase {
    private func line(_ author: String) -> BlameLine {
        BlameLine(
            hash: String(repeating: "a", count: 40),
            author: author,
            date: "2026-08-04T19:55:07+03:00",
            summary: "s"
        )
    }

    private func aligned(_ text: String, _ lines: [BlameLine?]) -> [BlameLine?] {
        let content = text as NSString
        return BlameAlignment.aligned(
            lines,
            toLineStartsIn: content,
            lineStarts: LineStartIndex.offsets(in: content)
        )
    }

    // MARK: - The ordinary file is untouched

    func testPlainLFFileMapsIdentically() {
        let lines = [line("a"), line("b"), line("c")]
        let result = aligned("alpha\nbeta\ngamma\n", lines)
        // Three content lines plus the trailing empty line.
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0]?.author, "a")
        XCTAssertEqual(result[1]?.author, "b")
        XCTAssertEqual(result[2]?.author, "c")
        XCTAssertNil(result[3])
    }

    func testFileWithoutTrailingSeparatorMapsIdentically() {
        let result = aligned("alpha\nbeta", [line("a"), line("b")])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0]?.author, "a")
        XCTAssertEqual(result[1]?.author, "b")
    }

    func testCRLFFileMapsIdentically() {
        // TextKit lays `\r\n` out as one separator and git counts one LF, so the
        // two agree line for line.
        let result = aligned("alpha\r\nbeta\r\ngamma\r\n", [line("a"), line("b"), line("c")])
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0]?.author, "a")
        XCTAssertEqual(result[1]?.author, "b")
        XCTAssertEqual(result[2]?.author, "c")
        XCTAssertNil(result[3])
    }

    // MARK: - The divergence this exists for

    func testLoneCarriageReturnDoesNotShiftLaterAnnotations() {
        // `git blame` sees three lines here — "alpha\rbeta", "gamma", "delta" —
        // while the gutter displays four, because `LineStartIndex` splits at the
        // lone CR. Indexing by buffer line would give `gamma` the annotation of
        // git line 2 shifted onto it and `delta` line 3's, permanently.
        let lines = [line("one"), line("two"), line("three")]
        let result = aligned("alpha\rbeta\ngamma\ndelta\n", lines)
        XCTAssertEqual(result.count, 5)
        // Both halves of the CR-split line belong to git line 1.
        XCTAssertEqual(result[0]?.author, "one")
        XCTAssertEqual(result[1]?.author, "one")
        XCTAssertEqual(result[2]?.author, "two")
        XCTAssertEqual(result[3]?.author, "three")
        XCTAssertNil(result[4])
    }

    func testLineSeparatorU2028DoesNotShiftLaterAnnotations() {
        let lines = [line("one"), line("two")]
        let result = aligned("alpha\u{2028}beta\ngamma\n", lines)
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0]?.author, "one")
        XCTAssertEqual(result[1]?.author, "one")
        XCTAssertEqual(result[2]?.author, "two")
        XCTAssertNil(result[3])
    }

    func testNextLineU0085DoesNotShiftLaterAnnotations() {
        let result = aligned("alpha\u{0085}beta\ngamma\n", [line("one"), line("two")])
        XCTAssertEqual(result[0]?.author, "one")
        XCTAssertEqual(result[1]?.author, "one")
        XCTAssertEqual(result[2]?.author, "two")
    }

    // MARK: - Length invariant and degenerate inputs

    func testResultAlwaysMatchesLineStartCount() {
        // A blame shorter than the buffer (a dirty buffer that grew) pads with nil.
        let short = aligned("a\nb\nc\nd\n", [line("x")])
        XCTAssertEqual(short.count, 5)
        XCTAssertEqual(short[0]?.author, "x")
        XCTAssertNil(short[1])
        XCTAssertNil(short[4])

        // A blame longer than the buffer (a dirty buffer that shrank) truncates to
        // the displayed line count. Entries past it are dropped; the trailing empty
        // line still resolves to the git line its offset sits on, which is the
        // documented whole-line offset rather than a trap.
        let long = aligned("a\n", [line("x"), line("y"), line("z")])
        XCTAssertEqual(long.count, 2)
        XCTAssertEqual(long[0]?.author, "x")
        XCTAssertEqual(long[1]?.author, "y")
    }

    func testEmptyInputs() {
        XCTAssertEqual(aligned("", []).count, 1)
        XCTAssertNil(aligned("", []).first ?? nil)
        XCTAssertEqual(aligned("a\nb\n", []).count, 3)
        XCTAssertTrue(aligned("a\nb\n", []).allSatisfy { $0 == nil })

        let noStarts = BlameAlignment.aligned([line("a")], toLineStartsIn: "a\n", lineStarts: [])
        XCTAssertTrue(noStarts.isEmpty)
    }

    func testNilEntriesArePreserved() {
        let result = aligned("a\nb\nc\n", [line("x"), nil, line("z")])
        XCTAssertEqual(result[0]?.author, "x")
        XCTAssertNil(result[1])
        XCTAssertEqual(result[2]?.author, "z")
    }

    func testOutOfRangeLineStartsAreClampedNotTrapped() {
        let content = "a\nb\n" as NSString
        let result = BlameAlignment.aligned(
            [line("x"), line("y")],
            toLineStartsIn: content,
            lineStarts: [-5, 2, 9_999]
        )
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0]?.author, "x")   // clamped to 0
        XCTAssertEqual(result[1]?.author, "y")
        XCTAssertNil(result[2])                  // clamped to the end: 2 LFs, no entry
    }

    func testNonAscendingLineStartsDoNotTrap() {
        let content = "a\nb\nc\n" as NSString
        let result = BlameAlignment.aligned(
            [line("x"), line("y"), line("z")],
            toLineStartsIn: content,
            lineStarts: [0, 4, 2]
        )
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0]?.author, "x")
        XCTAssertEqual(result[1]?.author, "z")
        // The backwards entry reuses the count reached so far rather than rescanning.
        XCTAssertEqual(result[2]?.author, "z")
    }

    /// The scan reads in `chunkSize` blocks; a separator landing exactly on a seam
    /// must still be counted, so the placement cannot depend on the block size.
    func testCountingStraddlesChunkBoundaries() {
        let filler = String(repeating: "x", count: BlameAlignment.chunkSize - 1)
        let text = filler + "\n" + filler + "\nlast\n"
        let lines = [line("one"), line("two"), line("three")]
        let result = aligned(text, lines)
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0]?.author, "one")
        XCTAssertEqual(result[1]?.author, "two")
        XCTAssertEqual(result[2]?.author, "three")
        XCTAssertNil(result[3])
    }
}
