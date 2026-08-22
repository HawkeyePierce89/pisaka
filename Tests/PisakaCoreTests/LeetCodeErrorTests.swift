import XCTest
@testable import PisakaCore

final class LeetCodeErrorTests: XCTestCase {
    /// One representative value per case — the set every "non-empty and distinct"
    /// assertion runs over, so a new case added without a sentence fails here.
    private let samples: [LeetCodeError] = [
        .notLoggedIn,
        .network(reason: "The Internet connection appears to be offline."),
        .apiChanged(detail: "data.question.content"),
        .paidOnly(slug: "two-sum-ii"),
        .throttled(retryAfter: 30),
        .folderUnavailable,
        .fileSystem(reason: "You don’t have permission to save the file “0001-two-sum.swift”."),
    ]

    func testEveryErrorHasANonEmptyDescription() {
        for error in samples {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(
                description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(error) has no user-facing sentence"
            )
        }
    }

    func testEveryErrorDescriptionIsDistinct() {
        let descriptions = samples.compactMap(\.errorDescription)
        XCTAssertEqual(descriptions.count, samples.count)
        XCTAssertEqual(
            Set(descriptions).count,
            samples.count,
            "two different failures read identically to the user"
        )
    }

    func testNotLoggedInDirectsToSignIn() {
        XCTAssertEqual(
            LeetCodeError.notLoggedIn.errorDescription,
            "Not signed in to LeetCode. Sign in to open problems."
        )
    }

    func testNetworkCarriesItsReason() {
        let error = LeetCodeError.network(reason: "  timed out\n")
        XCTAssertEqual(error.errorDescription, "Could not reach LeetCode: timed out")
    }

    func testNetworkWithEmptyReasonStillReads() {
        XCTAssertEqual(
            LeetCodeError.network(reason: "   ").errorDescription,
            "Could not reach LeetCode."
        )
    }

    func testAPIChangedNamesTheOffendingKeyPath() {
        // With an unofficial API this string is the whole diagnosis, so it must
        // survive into the message the user can paste into a bug report.
        let description = LeetCodeError.apiChanged(detail: "data.question.content").errorDescription
        XCTAssertEqual(
            description,
            "LeetCode returned something Pisaka did not understand (data.question.content). "
                + "Its API may have changed."
        )
    }

    func testAPIChangedWithEmptyDetailStillReads() {
        XCTAssertEqual(
            LeetCodeError.apiChanged(detail: "").errorDescription,
            "LeetCode returned something Pisaka did not understand. Its API may have changed."
        )
    }

    func testPaidOnlyNamesTheProblem() {
        XCTAssertEqual(
            LeetCodeError.paidOnly(slug: "two-sum-ii").errorDescription,
            "“two-sum-ii” is available to LeetCode Premium subscribers only."
        )
    }

    func testPaidOnlyWithoutASlugStillReads() {
        XCTAssertEqual(
            LeetCodeError.paidOnly(slug: " ").errorDescription,
            "This problem is available to LeetCode Premium subscribers only."
        )
    }

    func testThrottledNamesTheWaitWhenTheServerSuppliedOne() {
        XCTAssertEqual(
            LeetCodeError.throttled(retryAfter: 30).errorDescription,
            "LeetCode is rate-limiting requests. Try again in 30 seconds."
        )
    }

    func testThrottledRoundsAPartialSecondUp() {
        // Rounding down would advise a retry that is still too early.
        XCTAssertEqual(
            LeetCodeError.throttled(retryAfter: 4.2).errorDescription,
            "LeetCode is rate-limiting requests. Try again in 5 seconds."
        )
    }

    func testThrottledUsesTheSingularForOneSecond() {
        XCTAssertEqual(
            LeetCodeError.throttled(retryAfter: 1).errorDescription,
            "LeetCode is rate-limiting requests. Try again in 1 second."
        )
    }

    func testThrottledWithoutARetryAfterOmitsTheWait() {
        XCTAssertEqual(
            LeetCodeError.throttled(retryAfter: nil).errorDescription,
            "LeetCode is rate-limiting requests. Try again in a moment."
        )
    }

    func testThrottledWithANonPositiveRetryAfterOmitsTheWait() {
        XCTAssertEqual(
            LeetCodeError.throttled(retryAfter: 0).errorDescription,
            "LeetCode is rate-limiting requests. Try again in a moment."
        )
    }

    /// This case is `public` and takes a bare `Double`, so the message builder
    /// cannot assume the parser's "a wait worth naming" cap already applied:
    /// `Int(.infinity)` and `Int(1e20)` are runtime traps, not large numbers.
    func testThrottledWithAnUnnameableRetryAfterOmitsTheWaitRatherThanTrapping() {
        for value in [Double.infinity, -.infinity, .nan, 1e20, -30, 3601] {
            XCTAssertEqual(
                LeetCodeError.throttled(retryAfter: value).errorDescription,
                "LeetCode is rate-limiting requests. Try again in a moment.",
                "retryAfter: \(value)"
            )
        }
    }

    func testFolderUnavailableDirectsToChooseAFolder() {
        XCTAssertEqual(
            LeetCodeError.folderUnavailable.errorDescription,
            "The LeetCode folder is unavailable. Choose a folder for your solutions."
        )
    }

    func testFileSystemPassesItsReasonThroughTrimmed() {
        let reason = "You don’t have permission to save the file “0001-two-sum.swift”."
        XCTAssertEqual(
            LeetCodeError.fileSystem(reason: "  \(reason)\n").errorDescription,
            reason
        )
    }

    func testFileSystemWithEmptyReasonStillReads() {
        XCTAssertEqual(
            LeetCodeError.fileSystem(reason: "").errorDescription,
            "Could not write the solution file."
        )
    }

    func testLocalizedDescriptionUsesErrorDescription() {
        // The models surface `error.localizedDescription`; confirm LocalizedError
        // wiring routes it to our text rather than the generic NSError fallback.
        XCTAssertEqual(
            (LeetCodeError.notLoggedIn as Error).localizedDescription,
            "Not signed in to LeetCode. Sign in to open problems."
        )
    }

    func testDistinctPayloadsAreDistinctValues() {
        XCTAssertNotEqual(LeetCodeError.network(reason: "x"), .fileSystem(reason: "x"))
        XCTAssertNotEqual(LeetCodeError.paidOnly(slug: "a"), .paidOnly(slug: "b"))
        XCTAssertEqual(LeetCodeError.throttled(retryAfter: nil), .throttled(retryAfter: nil))
    }
}
