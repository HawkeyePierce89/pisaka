import XCTest
@testable import PisakaCore

/// The chrome's per-feature Core answers beside `diagnosticRole(for:)`: the
/// changed-file status (letter, word and role), the pull-request checks (glyph,
/// words and role, for both the summary and one job's bucket) and the diff row
/// wash and marker. Every answer is pinned verbatim over `allCases`, so a case
/// added to any of these vocabularies fails here until it is given one.
final class ChromeRoleMappingTests: XCTestCase {

    // MARK: - Changed-file status

    func testEveryFileStatusHasItsLetterWordAndRole() {
        let expected: [FileStatus: (letter: String, word: String, role: ChromeColorRole)] = [
            .modified: ("M", "Modified", .statusYellow),
            .added: ("A", "Added", .statusGreen),
            .deleted: ("D", "Deleted", .statusRed),
            .renamed: ("R", "Renamed", .statusYellow),
            .untracked: ("U", "Untracked", .textSecondary),
            .conflicted: ("C", "Conflicted", .statusRed),
        ]
        XCTAssertEqual(Set(expected.keys), Set(FileStatus.allCases))
        for status in FileStatus.allCases {
            let answer = expected[status]
            XCTAssertEqual(status.letter, answer?.letter, "\(status)")
            XCTAssertEqual(status.spokenName, answer?.word, "\(status)")
            XCTAssertEqual(ChromeColorRole.changedFileRole(for: status), answer?.role, "\(status)")
        }
    }

    /// The letter carries the identity: two statuses may share a colour, never
    /// a letter or a word.
    func testLettersAndWordsArePairwiseDistinct() {
        let letters = FileStatus.allCases.map(\.letter)
        let words = FileStatus.allCases.map(\.spokenName)
        XCTAssertEqual(Set(letters).count, letters.count, "\(letters)")
        XCTAssertEqual(Set(words).count, words.count, "\(words)")
    }

    // MARK: - Checks

    func testEveryChecksSummaryHasItsGlyphWordsAndRole() {
        let expected: [GitHubChecksSummary: (symbol: String, words: String, role: ChromeColorRole)] = [
            .noChecks: ("circle", "No checks", .textSecondary),
            .pending: ("clock", "Checks running", .statusYellow),
            .failure: ("xmark.circle.fill", "Checks failed", .statusRed),
            .success: ("checkmark.circle.fill", "Checks passed", .statusGreen),
        ]
        XCTAssertEqual(Set(expected.keys), Set(GitHubChecksSummary.allCases))
        for summary in GitHubChecksSummary.allCases {
            XCTAssertEqual(summary.symbolName, expected[summary]?.symbol, "\(summary)")
            XCTAssertEqual(summary.spokenWords, expected[summary]?.words, "\(summary)")
            XCTAssertEqual(ChromeColorRole.checksRole(for: summary), expected[summary]?.role, "\(summary)")
        }
    }

    func testEveryCheckBucketHasItsWordsAndRole() {
        let expected: [GitHubCheckBucket: (words: String, role: ChromeColorRole)] = [
            .pass: ("Passed", .statusGreen),
            .fail: ("Failed", .statusRed),
            .pending: ("Running", .statusYellow),
            .skipping: ("Skipped", .textSecondary),
            .cancel: ("Cancelled", .textSecondary),
        ]
        XCTAssertEqual(Set(expected.keys), Set(GitHubCheckBucket.allCases))
        for bucket in GitHubCheckBucket.allCases {
            XCTAssertEqual(bucket.spokenWords, expected[bucket]?.words, "\(bucket)")
            XCTAssertEqual(ChromeColorRole.checksRole(for: bucket), expected[bucket]?.role, "\(bucket)")
        }
    }

    // MARK: - Diff wash and marker

    /// One row of the side-by-side table: a kind, a side, and the two answers.
    private struct DiffCase {
        let kind: DiffRowKind
        let side: DiffSide
        let wash: ChromeColorRole?
        let marker: ChromeColorRole?
    }

    /// Exhaustive over every kind × side, written out; the filler cases (an
    /// added row's old side, a removed row's new side) and an unchanged row
    /// answer nil for both.
    func testTheSideBySideWashAndMarkerAreExhaustive() {
        let expected: [DiffCase] = [
            DiffCase(kind: .unchanged, side: .old, wash: nil, marker: nil),
            DiffCase(kind: .unchanged, side: .new, wash: nil, marker: nil),
            DiffCase(kind: .added, side: .old, wash: nil, marker: nil),
            DiffCase(kind: .added, side: .new, wash: .diffAddedBackground, marker: .statusGreen),
            DiffCase(kind: .removed, side: .old, wash: .diffRemovedBackground, marker: .statusRed),
            DiffCase(kind: .removed, side: .new, wash: nil, marker: nil),
            DiffCase(kind: .modified, side: .old, wash: .diffRemovedBackground, marker: .statusRed),
            DiffCase(kind: .modified, side: .new, wash: .diffAddedBackground, marker: .statusGreen),
        ]
        XCTAssertEqual(expected.count, DiffRowKind.allCases.count * DiffSide.allCases.count)
        XCTAssertEqual(DiffSide.allCases, [.old, .new])
        for row in expected {
            XCTAssertEqual(
                ChromeColorRole.diffWashRole(for: row.kind, side: row.side), row.wash,
                "wash \(row.kind)/\(row.side)"
            )
            XCTAssertEqual(
                ChromeColorRole.diffMarkerRole(for: row.kind, side: row.side), row.marker,
                "marker \(row.kind)/\(row.side)"
            )
        }
    }

    func testTheUnifiedWashCoversEveryLineKind() {
        let expected: [UnifiedDiffLine.Kind: ChromeColorRole?] = [
            .context: nil,
            .removed: .diffRemovedBackground,
            .added: .diffAddedBackground,
        ]
        XCTAssertEqual(Set(expected.keys), Set(UnifiedDiffLine.Kind.allCases))
        for kind in UnifiedDiffLine.Kind.allCases {
            XCTAssertEqual(ChromeColorRole.diffWashRole(for: kind), expected[kind] ?? nil, "\(kind)")
        }
    }
}
