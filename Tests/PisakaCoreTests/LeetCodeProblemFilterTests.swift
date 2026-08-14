import XCTest
@testable import PisakaCore

/// The browser's whole search behaviour, as a table over one fixed row set.
///
/// The rows are **deliberately not in number order**: catalog order is what the
/// filter must preserve, and a sorted fixture could not tell the difference
/// between preserving it and re-sorting by number.
final class LeetCodeProblemFilterTests: XCTestCase {

    // MARK: - Fixture

    private let threeSum = LeetCodeProblem(
        frontendID: 15, slug: "3sum", title: "3Sum",
        difficulty: .medium, isPaidOnly: false, status: .attempted
    )
    private let twoSum = LeetCodeProblem(
        frontendID: 1, slug: "two-sum", title: "Two Sum",
        difficulty: .easy, isPaidOnly: false, status: .solved
    )
    private let read4 = LeetCodeProblem(
        frontendID: 158,
        slug: "read-n-characters-given-read4-ii-call-multiple-times",
        title: "Read N Characters Given Read4 II - Call Multiple Times",
        difficulty: .hard, isPaidOnly: true, status: .notStarted
    )
    private let median = LeetCodeProblem(
        frontendID: 4, slug: "median-of-two-sorted-arrays",
        title: "Median of Two Sorted Arrays",
        difficulty: .hard, isPaidOnly: false, status: .notStarted
    )
    private let twoDistinct = LeetCodeProblem(
        frontendID: 159,
        slug: "longest-substring-with-at-most-two-distinct-characters",
        title: "Longest Substring with At Most Two Distinct Characters",
        difficulty: .medium, isPaidOnly: true, status: .attempted
    )
    private let addTwoNumbers = LeetCodeProblem(
        frontendID: 2, slug: "add-two-numbers", title: "Add Two Numbers",
        difficulty: .medium, isPaidOnly: false, status: .notStarted
    )
    private let upsideDown = LeetCodeProblem(
        frontendID: 156, slug: "binary-tree-upside-down", title: "Binary Tree Upside Down",
        difficulty: .medium, isPaidOnly: true, status: .solved
    )
    private let container = LeetCodeProblem(
        frontendID: 11, slug: "container-with-most-water", title: "Container With Most Water",
        difficulty: .medium, isPaidOnly: false, status: .attempted
    )

    private var rows: [LeetCodeProblem] {
        [threeSum, twoSum, read4, median, twoDistinct, addTwoNumbers, upsideDown, container]
    }

    private func ids(
        query: String = "",
        difficulties: Set<LeetCodeDifficulty> = [],
        statuses: Set<LeetCodeProblemStatus> = []
    ) -> [Int] {
        let filter = LeetCodeProblemFilter(
            query: query, difficulties: difficulties, statuses: statuses
        )
        return filter.apply(to: rows).map(\.frontendID)
    }

    // MARK: - The query as a number

    /// `1` answers problem 1 — not the rows whose number merely *starts* with a
    /// 1, which is the whole point of matching a number exactly.
    func testNumberQueryMatchesExactlyAndNotByPrefix() {
        XCTAssertEqual(ids(query: "1"), [1])
        XCTAssertEqual(ids(query: "15"), [15])
        XCTAssertEqual(ids(query: "4"), [4])
    }

    /// L4's padding rule arrives here for free through `LeetCodeProblemInput`.
    func testPaddedNumberQueryMatches() {
        XCTAssertEqual(ids(query: "0001"), [1])
    }

    func testNumberQueryWithNoSuchProblemMatchesNothing() {
        XCTAssertEqual(ids(query: "999"), [])
    }

    /// A number reaches a Premium row like any other: the browser never hides one.
    func testNumberQueryReachesPaidRow() {
        XCTAssertEqual(ids(query: "158"), [158])
    }

    /// `0` is not a problem number, and an all-digit query is a number attempt and
    /// nothing else — so it matches nothing rather than searching for the
    /// character.
    func testZeroIsARejectedNumberAndMatchesNothing() {
        XCTAssertEqual(ids(query: "0"), [])
    }

    /// The same rule where it is actually visible: LeetCode really does ship a
    /// problem whose slug is `01-matrix`, so a `0` that fell through to the
    /// substring branch would answer a query the user typed as a number with a row
    /// whose number is 542.
    func testARejectedNumberIsNotSearchedForAsText() {
        let matrix = LeetCodeProblem(
            frontendID: 542, slug: "01-matrix", title: "01 Matrix",
            difficulty: .medium, isPaidOnly: false, status: .notStarted
        )
        let filter = LeetCodeProblemFilter(query: "0")
        XCTAssertEqual(filter.apply(to: rows + [matrix]).map(\.frontendID), [])
    }

    /// More digits than an `Int` holds is the other input `parse` rejects, and it
    /// is the same answer for the same reason — not a substring search for a
    /// thirty-character number.
    func testADigitStringPastIntMatchesNothing() {
        XCTAssertEqual(ids(query: String(repeating: "1", count: 30)), [])
    }

    // MARK: - The query as text

    func testTitleSubstring() {
        XCTAssertEqual(ids(query: "two"), [1, 4, 159, 2])
    }

    /// Hyphens appear in slugs and in no title here, so this can only be a slug
    /// match.
    func testSlugSubstring() {
        XCTAssertEqual(ids(query: "-two-"), [4, 159, 2])
        XCTAssertEqual(ids(query: "binary-tree"), [156])
    }

    func testQueryMatchingOnlyPaidRows() {
        XCTAssertEqual(ids(query: "upside"), [156])
        XCTAssertEqual(ids(query: "read4"), [158])
    }

    func testMatchIsCaseInsensitiveBothWays() {
        XCTAssertEqual(ids(query: "TWO SUM"), [1])
        XCTAssertEqual(ids(query: "two sum"), [1])
        XCTAssertEqual(ids(query: "tWo SuM"), [1])
        XCTAssertEqual(ids(query: "3SUM"), [15])
        XCTAssertEqual(ids(query: "3sum"), [15])
    }

    func testQueryIsTrimmed() {
        XCTAssertEqual(ids(query: "  two-sum  "), [1])
        XCTAssertEqual(ids(query: "\t1\n"), [1])
    }

    func testEmptyAndAllWhitespaceQueryMatchEverything() {
        XCTAssertEqual(ids(query: ""), rows.map(\.frontendID))
        XCTAssertEqual(ids(query: "   \n\t "), rows.map(\.frontendID))
    }

    /// The Open Problem field is the surface that understands a pasted URL; here
    /// it is just text, and no title or slug contains it.
    func testPastedProblemURLMatchesNothing() {
        XCTAssertEqual(ids(query: "https://leetcode.com/problems/two-sum/"), [])
    }

    // MARK: - Difficulty

    func testEachDifficultySet() {
        XCTAssertEqual(ids(difficulties: [.easy]), [1])
        XCTAssertEqual(ids(difficulties: [.medium]), [15, 159, 2, 156, 11])
        XCTAssertEqual(ids(difficulties: [.hard]), [158, 4])
    }

    func testTwoElementDifficultySet() {
        XCTAssertEqual(ids(difficulties: [.easy, .hard]), [1, 158, 4])
    }

    /// Nothing selected and everything selected must behave identically — that
    /// is what a row of toggles needs.
    func testEmptyAndFullDifficultySetsAgree() {
        XCTAssertEqual(ids(difficulties: []), rows.map(\.frontendID))
        XCTAssertEqual(ids(difficulties: Set(LeetCodeDifficulty.allCases)), rows.map(\.frontendID))
    }

    // MARK: - Status

    func testEachStatusSet() {
        XCTAssertEqual(ids(statuses: [.solved]), [1, 156])
        XCTAssertEqual(ids(statuses: [.attempted]), [15, 159, 11])
        XCTAssertEqual(ids(statuses: [.notStarted]), [158, 4, 2])
    }

    func testEmptyAndFullStatusSetsAgree() {
        XCTAssertEqual(ids(statuses: []), rows.map(\.frontendID))
        XCTAssertEqual(ids(statuses: Set(LeetCodeProblemStatus.allCases)), rows.map(\.frontendID))
    }

    // MARK: - Combined

    func testQueryAndDifficultyAndStatusCombined() {
        XCTAssertEqual(ids(query: "two", difficulties: [.medium]), [159, 2])
        XCTAssertEqual(ids(query: "two", difficulties: [.medium], statuses: [.attempted]), [159])
        XCTAssertEqual(ids(query: "two", statuses: [.notStarted]), [4, 2])
    }

    func testCombinationThatMatchesNothing() {
        XCTAssertEqual(ids(query: "two", difficulties: [.easy], statuses: [.notStarted]), [])
    }

    // MARK: - Premium rows are never hidden

    /// Every combination that a Premium row satisfies keeps it: `isPaidOnly` is
    /// not a dimension of the filter at all.
    func testPaidRowsSurviveEveryCombination() {
        XCTAssertTrue(ids().contains(158))
        XCTAssertTrue(ids(difficulties: [.hard]).contains(158))
        XCTAssertTrue(ids(statuses: [.notStarted]).contains(158))
        XCTAssertTrue(ids(query: "two").contains(159))
        XCTAssertTrue(ids(query: "two", difficulties: [.medium], statuses: [.attempted]).contains(159))
        XCTAssertTrue(ids(statuses: [.solved]).contains(156))
    }

    // MARK: - Order

    /// The filter is one pass, so the answer is a subsequence of the input — and
    /// the input here is not sorted by number.
    func testCatalogOrderIsPreserved() {
        XCTAssertEqual(ids(), [15, 1, 158, 4, 159, 2, 156, 11])
        XCTAssertEqual(ids(difficulties: [.medium, .hard]), [15, 158, 4, 159, 2, 156, 11])
        XCTAssertNotEqual(ids(), ids().sorted())
    }

    func testEmptyInputYieldsEmptyOutput() {
        XCTAssertEqual(LeetCodeProblemFilter(query: "two").apply(to: []), [])
    }

    // MARK: - isEmpty

    func testIsEmpty() {
        XCTAssertTrue(LeetCodeProblemFilter().isEmpty)
        XCTAssertTrue(LeetCodeProblemFilter(query: "  \n ").isEmpty)
        XCTAssertFalse(LeetCodeProblemFilter(query: "two").isEmpty)
        XCTAssertFalse(LeetCodeProblemFilter(difficulties: [.easy]).isEmpty)
        XCTAssertFalse(LeetCodeProblemFilter(statuses: [.solved]).isEmpty)
    }

    func testEquatable() {
        XCTAssertEqual(
            LeetCodeProblemFilter(query: "two", difficulties: [.easy], statuses: [.solved]),
            LeetCodeProblemFilter(query: "two", difficulties: [.easy], statuses: [.solved])
        )
        XCTAssertNotEqual(
            LeetCodeProblemFilter(query: "two"),
            LeetCodeProblemFilter(query: "three")
        )
    }
}
