import XCTest
@testable import PisakaCore

/// The summary rule, driven table by table.
///
/// `GitHubAPITests` pins the rule as it arrives *through the parser*, off the
/// recorded fixtures. This suite drives it off the value types directly, which is
/// the only way to reach the combinations no repository in reach publishes — a
/// cancelled job, a stale one, a `StatusContext` in `EXPECTED` — and to assert the
/// **ordering** the rule depends on: unfinished outranks failed, and `noChecks` is
/// its own answer rather than a green one.
///
/// The two `isPassing` / `isFinished` tables are asserted by `allCases`, so a case
/// added to either enum without a decision fails here rather than silently
/// inheriting whichever branch of a `default:` it lands in.
final class GitHubChecksSummaryTests: XCTestCase {

    // MARK: - Shorthands

    private func run(_ status: GitHubCheckStatus, _ conclusion: GitHubCheckConclusion? = nil) -> GitHubRollupItem {
        .checkRun(status: status, conclusion: conclusion)
    }

    private func context(_ state: GitHubStatusContextState) -> GitHubRollupItem {
        .statusContext(state: state)
    }

    // MARK: - The four outcomes

    func testAnEmptyRollupIsNoChecks() {
        XCTAssertEqual(GitHubChecksSummary.summarise([]), .noChecks)
    }

    func testEverythingPassedIsSuccess() {
        XCTAssertEqual(
            GitHubChecksSummary.summarise([run(.completed, .success), run(.completed, .success)]),
            .success
        )
    }

    /// Skipped and neutral are passing: the job did not stand in the way. A rollup
    /// of nothing but skips is still `success` — it *finished*, which is what
    /// separates it from `noChecks`.
    func testSkippedAndNeutralCountAsSuccess() {
        XCTAssertEqual(
            GitHubChecksSummary.summarise([run(.completed, .skipped), run(.completed, .neutral)]),
            .success
        )
    }

    func testAFailedJobIsFailure() {
        XCTAssertEqual(
            GitHubChecksSummary.summarise([run(.completed, .success), run(.completed, .failure)]),
            .failure
        )
    }

    /// Cancelled, timed out, stale, startup failure and action required are all
    /// failing. None of them is a green answer to "can this be merged", and the
    /// conservative direction is the one that does not cost somebody a merge.
    func testEveryNonPassingConclusionIsFailure() {
        for conclusion in [GitHubCheckConclusion.cancelled, .timedOut, .stale, .startupFailure, .actionRequired] {
            XCTAssertEqual(
                GitHubChecksSummary.summarise([run(.completed, conclusion)]),
                .failure,
                "\(conclusion.rawValue) should not summarise as success"
            )
        }
    }

    func testAnUnfinishedJobIsPending() {
        for status in [GitHubCheckStatus.queued, .inProgress, .waiting, .pending, .requested] {
            XCTAssertEqual(
                GitHubChecksSummary.summarise([run(status, nil)]),
                .pending,
                "\(status.rawValue) should summarise as pending"
            )
        }
    }

    /// The ordering, and it is the rule: a rollup with one failure already in and
    /// one job still running has not decided anything. GitHub's own badge makes the
    /// same call, and a red marker here would be a verdict on a run that has not
    /// finished.
    func testUnfinishedOutranksFailed() {
        XCTAssertEqual(
            GitHubChecksSummary.summarise([run(.completed, .failure), run(.inProgress, nil)]),
            .pending
        )
    }

    /// A `COMPLETED` run with no conclusion is read as unfinished. GitHub does not
    /// send that; if it ever does, "still running" is the honest reading of a
    /// verdict that is not there — and it is the reading that does not invent one.
    func testACompletedRunWithNoConclusionIsPending() {
        XCTAssertEqual(GitHubChecksSummary.summarise([run(.completed, nil)]), .pending)
    }

    // MARK: - The second table

    func testStatusContextsAreDecidedByStateAlone() {
        XCTAssertEqual(GitHubChecksSummary.summarise([context(.success)]), .success)
        XCTAssertEqual(GitHubChecksSummary.summarise([context(.failure)]), .failure)
        XCTAssertEqual(GitHubChecksSummary.summarise([context(.error)]), .failure)
        XCTAssertEqual(GitHubChecksSummary.summarise([context(.pending)]), .pending)
        XCTAssertEqual(GitHubChecksSummary.summarise([context(.expected)]), .pending)
    }

    // MARK: - Mixed arrays

    func testAMixedArrayIsDecidedOverBothTables() {
        XCTAssertEqual(
            GitHubChecksSummary.summarise([run(.completed, .success), context(.success)]),
            .success
        )
        XCTAssertEqual(
            GitHubChecksSummary.summarise([run(.completed, .success), context(.failure)]),
            .failure
        )
        XCTAssertEqual(
            GitHubChecksSummary.summarise([run(.completed, .failure), context(.pending)]),
            .pending,
            "unfinished still outranks failed across the two kinds"
        )
        XCTAssertEqual(
            GitHubChecksSummary.summarise([run(.inProgress, nil), context(.success)]),
            .pending
        )
    }

    // MARK: - The tables themselves

    func testEveryConclusionDeclaresWhetherItPasses() {
        let passing = Set(GitHubCheckConclusion.allCases.filter(\.isPassing).map(\.rawValue))
        XCTAssertEqual(passing, ["SUCCESS", "NEUTRAL", "SKIPPED"])
    }

    func testCompletedIsTheOnlyFinishedStatus() {
        let finished = Set(GitHubCheckStatus.allCases.filter(\.isFinished).map(\.rawValue))
        XCTAssertEqual(finished, ["COMPLETED"])
    }

    func testExpectedAndPendingAreTheOnlyUnfinishedContextStates() {
        let unfinished = Set(GitHubStatusContextState.allCases.filter { !$0.isFinished }.map(\.rawValue))
        XCTAssertEqual(unfinished, ["EXPECTED", "PENDING"])
    }

    /// The buckets are `gh`'s own five words, lowercase, and the parser reads them
    /// verbatim — so the raw values are the wire format, not a rendering.
    func testTheBucketVocabularyIsGhsFiveWords() {
        XCTAssertEqual(
            Set(GitHubCheckBucket.allCases.map(\.rawValue)),
            ["pass", "fail", "pending", "skipping", "cancel"]
        )
    }

    func testTheReviewDecisionVocabularyIncludesTheEmptyAnswer() {
        XCTAssertEqual(
            Set(GitHubReviewDecision.allCases.map(\.rawValue)),
            ["", "APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED"]
        )
        XCTAssertEqual(GitHubReviewDecision(rawValue: ""), GitHubReviewDecision.none)
    }
}
