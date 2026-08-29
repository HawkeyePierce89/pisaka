import XCTest
@testable import PisakaCore

/// The usages answer's three hygiene rules — dedup, ordering, the cap — which
/// are the whole reason `UsagesAnswer.make` exists rather than the panel
/// publishing whatever array reached it.
///
/// Every case here is about a shape *both* row sources can produce: a language
/// server answers with the paths it resolved (which may spell a file differently
/// than the user opened it) and the textual walk answers in walk order, so
/// neither arrives deduplicated, ordered or bounded.
final class UsageResultTests: XCTestCase {

    // MARK: - Fixtures

    private let root = URL(fileURLWithPath: "/p/root")

    private func row(
        _ path: String,
        at location: Int,
        length: Int = 3,
        line: Int = 1,
        relativePath: String? = nil,
        isTextual: Bool = false
    ) -> UsageResult {
        let url = URL(fileURLWithPath: path)
        return UsageResult(
            fileURL: url,
            range: NSRange(location: location, length: length),
            line: line,
            relativePath: relativePath ?? url.lastPathComponent,
            preview: MatchPreview(text: "foo", matchRange: NSRange(location: 0, length: 3)),
            isTextual: isTextual
        )
    }

    // MARK: - Dedup

    func testDedupRemovesTheSameRangeInTheSameFile() {
        let first = row("/p/root/a.swift", at: 10)
        let second = row("/p/root/a.swift", at: 10)

        let answer = UsagesAnswer.make(
            identifier: "foo",
            rows: [first, second],
            provenance: .semantic,
            requestingFile: nil
        )

        XCTAssertEqual(answer.rows, [first])
    }

    func testDedupKeepsRangesThatDifferOnlyInLength() {
        // A zero-length and a three-unit range at the same offset are two rows:
        // the key is the whole range, not its start.
        let short = row("/p/root/a.swift", at: 10, length: 0)
        let long = row("/p/root/a.swift", at: 10, length: 3)

        let answer = UsagesAnswer.make(
            identifier: "foo",
            rows: [short, long],
            provenance: .semantic,
            requestingFile: nil
        )

        XCTAssertEqual(answer.rows.count, 2)
    }

    func testDedupKeepsTheSameRangeInDifferentFiles() {
        let answer = UsagesAnswer.make(
            identifier: "foo",
            rows: [row("/p/root/a.swift", at: 10), row("/p/root/b.swift", at: 10)],
            provenance: .semantic,
            requestingFile: nil
        )

        XCTAssertEqual(answer.rows.map(\.relativePath), ["a.swift", "b.swift"])
    }

    func testDedupCollapsesTwoSpellingsOfTheSameFile() throws {
        // The case the canonical key exists for: a server answers with the path
        // it resolved, the walk with the path the user opened. Same bytes, two
        // spellings, one usage.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let real = dir.appendingPathComponent("real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let file = real.appendingPathComponent("a.swift")
        try Data().write(to: file)
        let link = dir.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let direct = row(file.path, at: 10, relativePath: "real/a.swift")
        let throughLink = row(link.appendingPathComponent("a.swift").path, at: 10, relativePath: "link/a.swift")

        let answer = UsagesAnswer.make(
            identifier: "foo",
            rows: [direct, throughLink],
            provenance: .semantic,
            requestingFile: nil
        )

        XCTAssertEqual(answer.rows, [direct], "the first spelling wins")
    }

    // MARK: - Ordering

    func testRequestingFileComesFirstEvenFromTheMiddleOfTheAlphabet() {
        let requesting = URL(fileURLWithPath: "/p/root/m.swift")
        let answer = UsagesAnswer.make(
            identifier: "foo",
            rows: [
                row("/p/root/a.swift", at: 0, relativePath: "a.swift"),
                row("/p/root/m.swift", at: 40, relativePath: "m.swift"),
                row("/p/root/z.swift", at: 0, relativePath: "z.swift"),
                row("/p/root/m.swift", at: 5, relativePath: "m.swift"),
            ],
            provenance: .semantic,
            requestingFile: requesting
        )

        XCTAssertEqual(
            answer.rows.map { "\($0.relativePath)@\($0.range.location)" },
            ["m.swift@5", "m.swift@40", "a.swift@0", "z.swift@0"]
        )
    }

    func testOrderingFallsBackToRelativePathThenOffset() {
        let answer = UsagesAnswer.make(
            identifier: "foo",
            rows: [
                row("/p/root/src/b.swift", at: 9, relativePath: "src/b.swift"),
                row("/p/root/src/a.swift", at: 90, relativePath: "src/a.swift"),
                row("/p/root/src/a.swift", at: 5, relativePath: "src/a.swift"),
            ],
            provenance: .textual,
            requestingFile: nil
        )

        XCTAssertEqual(
            answer.rows.map { "\($0.relativePath)@\($0.range.location)" },
            ["src/a.swift@5", "src/a.swift@90", "src/b.swift@9"]
        )
    }

    func testOrderingByOffsetIsNumericNotLexicographic() {
        let answer = UsagesAnswer.make(
            identifier: "foo",
            rows: [
                row("/p/root/a.swift", at: 100, relativePath: "a.swift"),
                row("/p/root/a.swift", at: 9, relativePath: "a.swift"),
            ],
            provenance: .textual,
            requestingFile: nil
        )

        XCTAssertEqual(answer.rows.map(\.range.location), [9, 100])
    }

    func testRequestingFileMatchesThroughADifferentSpelling() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let real = dir.appendingPathComponent("real")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        let file = real.appendingPathComponent("m.swift")
        try Data().write(to: file)
        let link = dir.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let answer = UsagesAnswer.make(
            identifier: "foo",
            rows: [
                row("/p/root/a.swift", at: 0, relativePath: "a.swift"),
                row(file.path, at: 0, relativePath: "real/m.swift"),
            ],
            provenance: .semantic,
            // Asked from the tab opened *through the symlink*.
            requestingFile: link.appendingPathComponent("m.swift")
        )

        XCTAssertEqual(answer.rows.map(\.relativePath), ["real/m.swift", "a.swift"])
    }

    func testNilRequestingFileSimplyDropsTheFirstKey() {
        let answer = UsagesAnswer.make(
            identifier: "foo",
            rows: [
                row("/p/root/m.swift", at: 0, relativePath: "m.swift"),
                row("/p/root/a.swift", at: 0, relativePath: "a.swift"),
            ],
            provenance: .textual,
            requestingFile: nil
        )

        XCTAssertEqual(answer.rows.map(\.relativePath), ["a.swift", "m.swift"])
    }

    // MARK: - The cap

    func testCapIsTwoThousand() {
        XCTAssertEqual(UsagesAnswer.cap, 2_000)
    }

    func testAnswerExactlyAtTheCapIsNotTruncated() {
        let rows = (0..<UsagesAnswer.cap).map { row("/p/root/a.swift", at: $0 * 10, relativePath: "a.swift") }

        let answer = UsagesAnswer.make(
            identifier: "foo",
            rows: rows,
            provenance: .textual,
            requestingFile: nil
        )

        XCTAssertEqual(answer.rows.count, UsagesAnswer.cap)
        XCTAssertFalse(answer.isTruncated)
    }

    func testCapKeepsTheHeadOfTheOrderedListAndFlagsTruncation() {
        // Handed to `make` in *descending* order, so a cap applied before the
        // sort would keep the tail and this assertion would fail.
        let rows = (0...UsagesAnswer.cap).reversed().map {
            row("/p/root/a.swift", at: $0 * 10, relativePath: "a.swift")
        }

        let answer = UsagesAnswer.make(
            identifier: "foo",
            rows: rows,
            provenance: .textual,
            requestingFile: nil
        )

        XCTAssertEqual(answer.rows.count, UsagesAnswer.cap)
        XCTAssertTrue(answer.isTruncated)
        XCTAssertEqual(answer.rows.first?.range.location, 0)
        XCTAssertEqual(answer.rows.last?.range.location, (UsagesAnswer.cap - 1) * 10)
    }

    func testDuplicatesAreRemovedBeforeTheCapIsCounted() {
        // Two thousand distinct usages, each reported twice: the answer is
        // complete, not truncated.
        let distinct = (0..<UsagesAnswer.cap).map { row("/p/root/a.swift", at: $0 * 10, relativePath: "a.swift") }

        let answer = UsagesAnswer.make(
            identifier: "foo",
            rows: distinct + distinct,
            provenance: .semantic,
            requestingFile: nil
        )

        XCTAssertEqual(answer.rows.count, UsagesAnswer.cap)
        XCTAssertFalse(answer.isTruncated)
    }

    // MARK: - The answer itself

    func testAnswerCarriesTheIdentifierAndProvenanceUnchanged() {
        let answer = UsagesAnswer.make(
            identifier: "makeGreeter",
            rows: [row("/p/root/a.swift", at: 0, isTextual: true)],
            provenance: .textual,
            requestingFile: nil
        )

        XCTAssertEqual(answer.identifier, "makeGreeter")
        XCTAssertEqual(answer.provenance, .textual)
        XCTAssertFalse(answer.isEmpty)
    }

    func testEmptyRowsMakeAnEmptyAnswerThatIsStillAnAnswer() {
        let answer = UsagesAnswer.make(
            identifier: "foo",
            rows: [],
            provenance: .semantic,
            requestingFile: root.appendingPathComponent("a.swift")
        )

        XCTAssertTrue(answer.isEmpty)
        XCTAssertFalse(answer.isTruncated)
        XCTAssertEqual(answer.identifier, "foo")
    }

    // MARK: - Activating a row against the buffer as it then is

    /// The whole rule in its ordinary case: nothing changed, so the row reveals
    /// exactly the span it describes.
    func testARowRevealsItsRangeWhenTheTextStillSpellsTheIdentifier() {
        let text = "let foo = 1\nprint(foo)\n" as NSString
        let usage = row("/p/root/a.swift", at: 4, length: 3)

        XCTAssertEqual(
            usage.revealRange(naming: "foo", in: text),
            NSRange(location: 4, length: 3)
        )
    }

    /// The crash case. A row computed against a longer text is clicked after the
    /// file was shortened; `NSString.substring(with:)` would raise on the range,
    /// so the bound check has to come first.
    func testARowPastTheEndOfTheBufferRevealsNothing() {
        let text = "let foo = 1" as NSString
        let usage = row("/p/root/a.swift", at: 400, length: 3)

        XCTAssertNil(usage.revealRange(naming: "foo", in: text))
    }

    /// A range that *ends* past the buffer, with a start inside it — the other
    /// half of the same raise.
    func testARowOverhangingTheEndOfTheBufferRevealsNothing() {
        let text = "let foo" as NSString
        let usage = row("/p/root/a.swift", at: 5, length: 10)

        XCTAssertNil(usage.revealRange(naming: "foo", in: text))
    }

    /// The misleading case, and the reason the check is the text rather than the
    /// geometry: the range is perfectly valid and now covers something else.
    func testARowWhoseSpanNowHoldsOtherTextRevealsNothing() {
        // The row was computed against "let foo = 1"; someone renamed the
        // binding, so offset 4 now spells "bar".
        let text = "let bar = 1\nprint(bar)\n" as NSString
        let usage = row("/p/root/a.swift", at: 4, length: 3)

        XCTAssertNil(usage.revealRange(naming: "foo", in: text))
    }

    /// A span that merely *starts* with the identifier is not the identifier —
    /// the length is part of the comparison, so a longer name at the same offset
    /// is rejected rather than half-selected.
    func testARowWhoseSpanIsNowALongerNameRevealsNothing() {
        let text = "let foobar = 1" as NSString
        let usage = row("/p/root/a.swift", at: 4, length: 6)

        XCTAssertNil(usage.revealRange(naming: "foo", in: text))
    }

    /// An empty buffer is the degenerate shortening: every row is out of bounds,
    /// including one at offset 0.
    func testEveryRowRevealsNothingInAnEmptyBuffer() {
        let text = "" as NSString
        XCTAssertNil(row("/p/root/a.swift", at: 0, length: 3).revealRange(naming: "foo", in: text))
    }

    /// Non-ASCII text ahead of the match: the range is UTF-16, so the comparison
    /// must be made in the same units the row was computed in.
    func testTheComparisonIsMadeInUTF16Units() {
        let text = "\u{1F600} foo" as NSString   // one emoji is two UTF-16 units
        let usage = row("/p/root/a.swift", at: 3, length: 3)

        XCTAssertEqual(
            usage.revealRange(naming: "foo", in: text),
            NSRange(location: 3, length: 3)
        )
    }

    func testProvenanceRawValuesAreStable() {
        // The provenance is what the panel prints; the raw values are named here
        // so a rename of a case is a deliberate change rather than a silent one.
        XCTAssertEqual(UsageProvenance.semantic.rawValue, "semantic")
        XCTAssertEqual(UsageProvenance.textual.rawValue, "textual")
    }
}
