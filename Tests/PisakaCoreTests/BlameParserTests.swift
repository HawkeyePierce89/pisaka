import XCTest
@testable import PisakaCore

/// Tests for ``BlameParser`` — the pure `git blame --porcelain` parser.
///
/// Every fixture keeps the real TAB-prefixed content line each blamed line
/// carries in porcelain output, because that prefix is the only thing separating
/// file content from the metadata grammar and several tests exist precisely to
/// pin that it is honoured before anything else.
final class BlameParserTests: XCTestCase {
    // MARK: - Fixture helpers

    private let hashA = "1111111111111111111111111111111111111111"
    private let hashB = "2222222222222222222222222222222222222222"
    private let zeroHash = "0000000000000000000000000000000000000000"

    /// One full porcelain group: header + metadata block + the TAB-prefixed
    /// source line. Mirrors what `git blame --porcelain` emits for the first
    /// line attributed to a commit.
    private func group(
        hash: String,
        origLine: Int,
        finalLine: Int,
        numLines: Int? = nil,
        author: String = "Ada Lovelace",
        time: Int = 1_717_171_717,
        tz: String? = "+0000",
        summary: String = "Do the thing",
        extraFields: [String] = [],
        content: String
    ) -> String {
        var lines: [String] = []
        var header = "\(hash) \(origLine) \(finalLine)"
        if let numLines { header += " \(numLines)" }
        lines.append(header)
        lines.append("author \(author)")
        lines.append("author-mail <ada@example.com>")
        lines.append("author-time \(time)")
        if let tz { lines.append("author-tz \(tz)") }
        lines.append("committer Someone Else")
        lines.append("committer-mail <else@example.com>")
        lines.append("committer-time \(time)")
        lines.append("committer-tz +0000")
        lines.append("summary \(summary)")
        lines.append(contentsOf: extraFields)
        lines.append("filename src/main.swift")
        lines.append("\t\(content)")
        return lines.joined(separator: "\n")
    }

    /// A repeat group: porcelain emits commit metadata only once per commit, so
    /// later lines of the same commit carry just the header and the content.
    private func repeatGroup(hash: String, origLine: Int, finalLine: Int, content: String) -> String {
        "\(hash) \(origLine) \(finalLine)\n\t\(content)"
    }

    // MARK: - Basics

    func testEmptyOutputIsEmptyArray() {
        XCTAssertEqual(BlameParser.parse(""), [])
        XCTAssertEqual(BlameParser.parse("\n"), [])
        XCTAssertEqual(BlameParser.parse("   \n  \n"), [])
    }

    func testSingleCommitSingleLine() {
        let output = group(
            hash: hashA,
            origLine: 1,
            finalLine: 1,
            author: "Ada Lovelace",
            time: 1_717_171_717,
            tz: "+0000",
            summary: "Do the thing",
            content: "let x = 1"
        )

        let lines = BlameParser.parse(output)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]?.hash, hashA)
        XCTAssertEqual(lines[0]?.author, "Ada Lovelace")
        XCTAssertEqual(lines[0]?.date, "2024-05-31T16:08:37+00:00")
        XCTAssertEqual(lines[0]?.summary, "Do the thing")
        XCTAssertEqual(lines[0]?.isUncommitted, false)
    }

    func testSeveralCommitsInterleaved() {
        let output = [
            group(hash: hashA, origLine: 1, finalLine: 1, author: "Ada", summary: "First", content: "line one"),
            group(hash: hashB, origLine: 4, finalLine: 2, author: "Grace", summary: "Second", content: "line two"),
            repeatGroup(hash: hashA, origLine: 2, finalLine: 3, content: "line three"),
            group(hash: hashB, origLine: 5, finalLine: 4, author: "Grace", summary: "Second", content: "line four")
        ].joined(separator: "\n")

        let lines = BlameParser.parse(output)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.map { $0?.hash }, [hashA, hashB, hashA, hashB])
        XCTAssertEqual(lines.map { $0?.author }, ["Ada", "Grace", "Ada", "Grace"])
        XCTAssertEqual(lines.map { $0?.summary }, ["First", "Second", "First", "Second"])
    }

    /// The whole reason `--porcelain` is used over `--line-porcelain`: a commit's
    /// metadata block appears once, later lines carry the hash alone and must
    /// resolve through the parser's `hash → metadata` table.
    func testRepeatedCommitWithoutMetadataResolvesThroughHashTable() {
        let output = [
            group(hash: hashA, origLine: 1, finalLine: 1, author: "Ada", summary: "First", content: "one"),
            repeatGroup(hash: hashA, origLine: 2, finalLine: 2, content: "two"),
            repeatGroup(hash: hashA, origLine: 3, finalLine: 3, content: "three")
        ].joined(separator: "\n")

        let lines = BlameParser.parse(output)
        XCTAssertEqual(lines.count, 3)
        for line in lines {
            XCTAssertEqual(line?.hash, hashA)
            XCTAssertEqual(line?.author, "Ada")
            XCTAssertEqual(line?.summary, "First")
            XCTAssertEqual(line?.date, "2024-05-31T16:08:37+00:00")
        }
    }

    /// A metadata block that arrives *after* an earlier header-only reference to
    /// the same commit still resolves it: placement and metadata are reconciled
    /// once the whole output has been read.
    func testMetadataArrivingAfterAnEarlierHeaderStillResolves() {
        let output = [
            repeatGroup(hash: hashA, origLine: 1, finalLine: 1, content: "one"),
            group(hash: hashA, origLine: 2, finalLine: 2, author: "Ada", summary: "First", content: "two")
        ].joined(separator: "\n")

        let lines = BlameParser.parse(output)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0]?.author, "Ada")
        XCTAssertEqual(lines[1]?.author, "Ada")
    }

    func testUncommittedLines() {
        let output = [
            group(hash: hashA, origLine: 1, finalLine: 1, author: "Ada", summary: "First", content: "one"),
            group(
                hash: zeroHash,
                origLine: 2,
                finalLine: 2,
                author: "Not Committed Yet",
                summary: "Version of main.swift from src/main.swift",
                content: "brand new"
            )
        ].joined(separator: "\n")

        let lines = BlameParser.parse(output)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0]?.isUncommitted, false)
        XCTAssertEqual(lines[1]?.isUncommitted, true)
        XCTAssertEqual(lines[1]?.author, "Not Committed Yet")
    }

    func testUnicodeAuthorAndSummaryWithSpaces() {
        let output = group(
            hash: hashA,
            origLine: 1,
            finalLine: 1,
            author: "Анто́н Карма́нов",
            summary: "Исправил всё — и ещё чуть-чуть",
            content: "print(\"привет\")"
        )

        let lines = BlameParser.parse(output)
        XCTAssertEqual(lines[0]?.author, "Анто́н Карма́нов")
        XCTAssertEqual(lines[0]?.summary, "Исправил всё — и ещё чуть-чуть")
    }

    func testGroupHeaderCarryingNumLinesCount() {
        let output = [
            group(hash: hashA, origLine: 1, finalLine: 1, numLines: 2, author: "Ada", content: "one"),
            repeatGroup(hash: hashA, origLine: 2, finalLine: 2, content: "two")
        ].joined(separator: "\n")

        let lines = BlameParser.parse(output)
        // `num-lines` describes the group; every line still carries its own
        // header, so nothing is expanded from the count.
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map { $0?.author }, ["Ada", "Ada"])
    }

    // MARK: - Robustness

    /// Output cut off mid-metadata-block must still yield a well-formed array.
    func testTruncatedOutputMidGroup() {
        let output = """
        \(hashA) 1 1
        author Ada
        author-mail <ada@example.com>
        author-time 1717171717
        author-tz +0000
        summary First
        filename src/main.swift
        \tone
        \(hashB) 4 2
        author Grace
        author-tim
        """

        let lines = BlameParser.parse(output)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0]?.author, "Ada")
        // The truncated group still knows its hash; the missing fields are empty
        // rather than the entry being dropped.
        XCTAssertEqual(lines[1]?.hash, hashB)
        XCTAssertEqual(lines[1]?.author, "Grace")
        XCTAssertEqual(lines[1]?.date, "")
        XCTAssertEqual(lines[1]?.summary, "")
    }

    func testGarbageLinesAreSkipped() {
        let output = [
            "this is not a header at all",
            "zzzz 1 2 3",
            group(hash: hashA, origLine: 1, finalLine: 1, author: "Ada", content: "one"),
            "   ",
            "notahash notanumber notanumber"
        ].joined(separator: "\n")

        let lines = BlameParser.parse(output)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]?.author, "Ada")
    }

    /// Entries are placed by the header's *final* line number, so a gap in the
    /// output leaves a `nil` rather than shifting later lines up.
    func testGapsStayNil() {
        let output = [
            group(hash: hashA, origLine: 1, finalLine: 1, author: "Ada", content: "one"),
            repeatGroup(hash: hashA, origLine: 5, finalLine: 4, content: "four")
        ].joined(separator: "\n")

        let lines = BlameParser.parse(output)
        XCTAssertEqual(lines.count, 4)
        XCTAssertNotNil(lines[0])
        XCTAssertNil(lines[1])
        XCTAssertNil(lines[2])
        XCTAssertNotNil(lines[3])
    }

    func testNonPositiveFinalLineNumberIsIgnored() {
        let output = [
            group(hash: hashA, origLine: 1, finalLine: 0, author: "Ada", content: "bogus"),
            group(hash: hashB, origLine: 1, finalLine: 1, author: "Grace", content: "one")
        ].joined(separator: "\n")

        let lines = BlameParser.parse(output)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]?.author, "Grace")
    }

    // MARK: - Date synthesis

    func testISODateSynthesisWithNonUTCTimeZone() {
        let output = group(
            hash: hashA,
            origLine: 1,
            finalLine: 1,
            time: 1_785_862_507,
            tz: "+0300",
            content: "one"
        )
        XCTAssertEqual(BlameParser.parse(output)[0]?.date, "2026-08-04T19:55:07+03:00")
    }

    func testISODateSynthesisWithNegativeHalfHourTimeZone() {
        let output = group(
            hash: hashA,
            origLine: 1,
            finalLine: 1,
            time: 1_717_171_717,
            tz: "-0530",
            content: "one"
        )
        XCTAssertEqual(BlameParser.parse(output)[0]?.date, "2024-05-31T10:38:37-05:30")
    }

    func testISODateSynthesisWithMissingTimeZoneFallsBackToUTC() {
        let output = group(
            hash: hashA,
            origLine: 1,
            finalLine: 1,
            time: 1_717_171_717,
            tz: nil,
            content: "one"
        )
        XCTAssertEqual(BlameParser.parse(output)[0]?.date, "2024-05-31T16:08:37+00:00")
    }

    func testISODateSynthesisWithMalformedTimeZoneFallsBackToUTC() {
        for tz in ["nonsense", "+03", "++0300", "0300", ""] {
            let output = group(
                hash: hashA,
                origLine: 1,
                finalLine: 1,
                time: 1_717_171_717,
                tz: tz,
                content: "one"
            )
            XCTAssertEqual(
                BlameParser.parse(output)[0]?.date,
                "2024-05-31T16:08:37+00:00",
                "malformed tz \(tz) should fall back to +00:00"
            )
        }
    }

    /// `offsetSeconds` accepts any syntactically valid `±HHMM`, but
    /// `TimeZone(secondsFromGMT:)` rejects anything beyond ±18 h, so the time is
    /// rendered in UTC — and the spelled offset must say so rather than repeat the
    /// rejected number, which would name an instant days away from the real one.
    func testISODateSynthesisWithOutOfRangeTimeZoneFallsBackToUTCConsistently() {
        for tz in ["+9999", "-9999", "+2400"] {
            let output = group(
                hash: hashA,
                origLine: 1,
                finalLine: 1,
                time: 1_717_171_717,
                tz: tz,
                content: "one"
            )
            XCTAssertEqual(
                BlameParser.parse(output)[0]?.date,
                "2024-05-31T16:08:37+00:00",
                "out-of-range tz \(tz) should render and label as UTC"
            )
        }
    }

    func testMissingAuthorTimeYieldsEmptyDate() {
        let output = """
        \(hashA) 1 1
        author Ada
        author-tz +0300
        summary First
        filename src/main.swift
        \tone
        """
        let lines = BlameParser.parse(output)
        XCTAssertEqual(lines[0]?.author, "Ada")
        XCTAssertEqual(lines[0]?.date, "")
    }

    // MARK: - The TAB rule: content is recognized before anything else

    /// A source line spelled exactly like an `author` field must not overwrite
    /// the group's real author. Only the TAB prefix distinguishes them.
    func testContentLineSpelledLikeAnAuthorFieldIsInert() {
        let output = group(
            hash: hashA,
            origLine: 1,
            finalLine: 1,
            author: "Ada Lovelace",
            content: "author Evil <x@y>"
        )

        let lines = BlameParser.parse(output)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]?.author, "Ada Lovelace")
    }

    /// A source line spelled exactly like a group header must neither create a
    /// group nor move any line's placement.
    func testContentLineSpelledLikeAHeaderIsInert() {
        let output = group(
            hash: hashA,
            origLine: 1,
            finalLine: 1,
            author: "Ada",
            content: "\(zeroHash) 1 2 3"
        )

        let lines = BlameParser.parse(output)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]?.hash, hashA)
        XCTAssertEqual(lines[0]?.author, "Ada")
        XCTAssertEqual(lines[0]?.isUncommitted, false)
    }

    func testContentLineSpelledLikeASummaryFieldIsInert() {
        let output = group(
            hash: hashA,
            origLine: 1,
            finalLine: 1,
            summary: "Real summary",
            content: "summary not a real summary"
        )
        XCTAssertEqual(BlameParser.parse(output)[0]?.summary, "Real summary")
    }

    /// An empty source line is emitted as a bare TAB; it is consumed as content
    /// and must not disturb the following group.
    func testBareTabIsConsumedAsAnEmptyContentLine() {
        let output = [
            group(hash: hashA, origLine: 1, finalLine: 1, author: "Ada", content: ""),
            group(hash: hashB, origLine: 2, finalLine: 2, author: "Grace", content: "two")
        ].joined(separator: "\n")

        let lines = BlameParser.parse(output)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map { $0?.author }, ["Ada", "Grace"])
    }

    /// The composite case: a file whose own text impersonates every part of the
    /// grammar at once still parses exactly as if the lines were ordinary code.
    func testFileImpersonatingTheWholeGrammarIsInert() {
        let output = [
            group(hash: hashA, origLine: 1, finalLine: 1, author: "Ada", summary: "First", content: "author Evil <x@y>"),
            repeatGroup(hash: hashA, origLine: 2, finalLine: 2, content: "author-time 1"),
            repeatGroup(hash: hashA, origLine: 3, finalLine: 3, content: "author-tz +0900"),
            repeatGroup(hash: hashA, origLine: 4, finalLine: 4, content: "summary evil"),
            repeatGroup(hash: hashA, origLine: 5, finalLine: 5, content: "\(zeroHash) 9 9 9")
        ].joined(separator: "\n")

        let lines = BlameParser.parse(output)
        XCTAssertEqual(lines.count, 5)
        for line in lines {
            XCTAssertEqual(line?.hash, hashA)
            XCTAssertEqual(line?.author, "Ada")
            XCTAssertEqual(line?.summary, "First")
            XCTAssertEqual(line?.date, "2024-05-31T16:08:37+00:00")
        }
    }

    /// A content line closes the group's metadata block, so a *field-shaped* line
    /// appearing after it — with no TAB, and before the next header — must not
    /// overwrite the group's metadata.
    ///
    /// This is the TAB branch's one effect the other fixtures cannot observe: they
    /// are inert for the unrelated reason that a TAB-prefixed line yields a
    /// 41-character "hash" and a `"\tauthor"` field key, both of which fall through
    /// anyway. Only a line that would otherwise parse as a real field, reached
    /// after the block was closed, distinguishes `inMetadataBlock = false` from a
    /// no-op — which is why the truncated/garbage output this simulates is pinned
    /// here rather than left to the composite fixture.
    func testFieldLineAfterContentDoesNotReopenTheMetadataBlock() {
        let output = [
            group(hash: hashA, origLine: 1, finalLine: 1, author: "Ada", summary: "First", content: "one"),
            "author Evil <x@y>",
            "summary evil"
        ].joined(separator: "\n")

        let lines = BlameParser.parse(output)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]?.author, "Ada")
        XCTAssertEqual(lines[0]?.summary, "First")
    }

    // MARK: - Line endings

    /// A file checked out with CRLF endings: git emits each blamed line's source
    /// text verbatim, so every content line carries its own CR before git's LF.
    ///
    /// Splitting the output by *grapheme cluster* would not break the `\r\n` pair,
    /// fusing each content line with the following group header — which, starting
    /// with a TAB, would then be eaten as content. The symptom is silent and total:
    /// line 1 keeps its annotation and every later line comes back `nil`.
    func testCRLFContentLinesDoNotSwallowTheFollowingHeader() {
        let output = [
            group(hash: hashA, origLine: 1, finalLine: 1, author: "Ada", summary: "First", content: "line one\r"),
            group(hash: hashB, origLine: 2, finalLine: 2, author: "Grace", summary: "Second", content: "line two\r"),
            repeatGroup(hash: hashA, origLine: 3, finalLine: 3, content: "line three\r")
        ].joined(separator: "\n")

        let lines = BlameParser.parse(output)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.map { $0?.hash }, [hashA, hashB, hashA])
        XCTAssertEqual(lines.map { $0?.author }, ["Ada", "Grace", "Ada"])
        XCTAssertEqual(lines.map { $0?.summary }, ["First", "Second", "First"])
    }

    /// The whole output CRLF-terminated — the shape a `core.autocrlf` checkout
    /// produces end to end. Every record ends in a CR that must be stripped before
    /// the grammar sees it, or no header, hash or field matches at all.
    func testWhollyCRLFTerminatedOutputParses() {
        let output = [
            group(hash: hashA, origLine: 1, finalLine: 1, author: "Ada", summary: "First", content: "line one"),
            group(hash: hashB, origLine: 2, finalLine: 2, author: "Grace", summary: "Second", content: "line two")
        ]
        .joined(separator: "\n")
        .replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"

        let lines = BlameParser.parse(output)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map { $0?.hash }, [hashA, hashB])
        XCTAssertEqual(lines.map { $0?.author }, ["Ada", "Grace"])
        // Asserted through `map` rather than `lines[0]`: a regression here empties
        // the array, and subscripting it would trap and abort the whole run
        // instead of reporting this one failure.
        XCTAssertEqual(
            lines.map { $0?.date },
            ["2024-05-31T16:08:37+00:00", "2024-05-31T16:08:37+00:00"]
        )
    }

    // MARK: - The two extra headers git emits: `boundary` and `previous`

    /// `boundary` is a lone keyword line with no value; it must be skipped
    /// without disturbing the group it sits in.
    func testBoundaryKeywordIsIgnored() {
        let output = group(
            hash: hashA,
            origLine: 1,
            finalLine: 1,
            author: "Ada",
            summary: "First",
            extraFields: ["boundary"],
            content: "one"
        )

        let lines = BlameParser.parse(output)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]?.hash, hashA)
        XCTAssertEqual(lines[0]?.author, "Ada")
        XCTAssertEqual(lines[0]?.summary, "First")
    }

    /// `previous <40-hex sha> <path>` starts with a token that looks like a hash;
    /// it must neither create a group nor become the group's own hash.
    func testPreviousFieldIsIgnored() {
        let output = group(
            hash: hashA,
            origLine: 1,
            finalLine: 1,
            author: "Ada",
            summary: "First",
            extraFields: ["previous \(hashB) src/main.swift"],
            content: "one"
        )

        let lines = BlameParser.parse(output)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]?.hash, hashA)
        XCTAssertEqual(lines[0]?.author, "Ada")
    }

    /// The same two shapes appearing as *source text* are inert too.
    func testContentLinesSpelledLikeBoundaryAndPreviousAreInert() {
        let output = [
            group(hash: hashA, origLine: 1, finalLine: 1, author: "Ada", summary: "First", content: "boundary"),
            repeatGroup(hash: hashA, origLine: 2, finalLine: 2, content: "previous \(hashB) src/x.swift")
        ].joined(separator: "\n")

        let lines = BlameParser.parse(output)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map { $0?.hash }, [hashA, hashA])
        XCTAssertEqual(lines.map { $0?.author }, ["Ada", "Ada"])
    }

    // MARK: - `BlameLine` itself

    func testIsUncommittedIsTheAllZeroHash() {
        let uncommitted = BlameLine(hash: zeroHash, author: "Not Committed Yet", date: "", summary: "")
        XCTAssertTrue(uncommitted.isUncommitted)

        let committed = BlameLine(hash: hashA, author: "Ada", date: "", summary: "")
        XCTAssertFalse(committed.isUncommitted)

        // An empty hash is "no hash", not "the zero hash".
        let empty = BlameLine(hash: "", author: "", date: "", summary: "")
        XCTAssertFalse(empty.isUncommitted)
    }
}
