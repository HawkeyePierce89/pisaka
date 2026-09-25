import XCTest
@testable import PisakaCore

/// The chrome's per-feature Core answers beside `diagnosticRole(for:)`: the
/// changed-file status (letter, word and role), the pull-request checks (the
/// summary's glyph, words and role; one job's bucket's words and role — the job
/// row draws a dot, not a glyph) and the diff row
/// wash and marker, and the problem catalog's three (difficulty, problem
/// status and the judge verdict). Every answer is pinned verbatim over `allCases`, so a case
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

    /// The merge wash's first test of any kind: every line kind has its answer,
    /// and exactly the three conflicted kinds share the one conflict wash.
    func testTheMergeWashCoversEveryLineKind() {
        let expected: [MergeLineKind: ChromeColorRole?] = [
            .plain: nil,
            .ours: .conflictBackground,
            .theirs: .conflictBackground,
            .conflictUnresolved: .conflictBackground,
            .conflictResolved: .diffAddedBackground,
        ]
        XCTAssertEqual(Set(expected.keys), Set(MergeLineKind.allCases))
        for kind in MergeLineKind.allCases {
            XCTAssertEqual(ChromeColorRole.mergeWashRole(for: kind), expected[kind] ?? nil, "\(kind)")
        }
        XCTAssertEqual(
            Set(MergeLineKind.allCases.filter { ChromeColorRole.mergeWashRole(for: $0) == .conflictBackground }),
            [.ours, .theirs, .conflictUnresolved]
        )
    }

    // MARK: - Problem catalog

    func testEveryDifficultyHasItsRole() {
        let expected: [LeetCodeDifficulty: ChromeColorRole] = [
            .easy: .statusGreen,
            .medium: .statusYellow,
            .hard: .statusRed,
        ]
        XCTAssertEqual(Set(expected.keys), Set(LeetCodeDifficulty.allCases))
        for difficulty in LeetCodeDifficulty.allCases {
            XCTAssertEqual(ChromeColorRole.difficultyRole(for: difficulty), expected[difficulty], "\(difficulty)")
        }
    }

    func testEveryProblemStatusHasItsRole() {
        let expected: [LeetCodeProblemStatus: ChromeColorRole] = [
            .solved: .statusGreen,
            .attempted: .statusYellow,
            .notStarted: .textSecondary,
        ]
        XCTAssertEqual(Set(expected.keys), Set(LeetCodeProblemStatus.allCases))
        for status in LeetCodeProblemStatus.allCases {
            XCTAssertEqual(ChromeColorRole.problemStatusRole(for: status), expected[status], "\(status)")
        }
    }

    /// Every verdict × every match answer: green only for an accepted verdict
    /// whose run did not report a mismatch (a submit passes `nil`).
    func testEveryVerdictHasItsRoleForEveryMatchAnswer() {
        let matchAnswers: [Bool?] = [nil, true, false]
        for verdict in LeetCodeVerdict.allCases {
            for matched in matchAnswers {
                let expected: ChromeColorRole = verdict == .accepted && matched != false
                    ? .statusGreen : .statusRed
                XCTAssertEqual(
                    ChromeColorRole.verdictRole(for: verdict, matchedExpected: matched), expected,
                    "\(verdict)/\(String(describing: matched))"
                )
            }
        }
        XCTAssertEqual(ChromeColorRole.verdictRole(for: .accepted, matchedExpected: nil), .statusGreen)
        XCTAssertEqual(ChromeColorRole.verdictRole(for: .accepted, matchedExpected: true), .statusGreen)
        XCTAssertEqual(ChromeColorRole.verdictRole(for: .accepted, matchedExpected: false), .statusRed)
        XCTAssertEqual(ChromeColorRole.verdictRole(for: .wrongAnswer, matchedExpected: true), .statusRed)
    }
}
