import XCTest
@testable import PisakaCore

final class LeetCodeProblemInputTests: XCTestCase {

    // MARK: - Numbers

    func testBareNumber() {
        XCTAssertEqual(LeetCodeProblemInput.parse("1"), .number(1))
        XCTAssertEqual(LeetCodeProblemInput.parse("42"), .number(42))
        XCTAssertEqual(LeetCodeProblemInput.parse("3040"), .number(3040))
    }

    /// The file names this app writes are zero-padded, so a padded number is
    /// exactly what a user pastes back in.
    func testPaddedNumberDropsLeadingZeros() {
        XCTAssertEqual(LeetCodeProblemInput.parse("0001"), .number(1))
        XCTAssertEqual(LeetCodeProblemInput.parse("0042"), .number(42))
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(LeetCodeProblemInput.parse("  7  "), .number(7))
        XCTAssertEqual(LeetCodeProblemInput.parse("\ttwo-sum\n"), .slug("two-sum"))
    }

    func testZeroAndNegativeAndSignedNumbersRejected() {
        XCTAssertNil(LeetCodeProblemInput.parse("0"))
        XCTAssertNil(LeetCodeProblemInput.parse("0000"))
        XCTAssertNil(LeetCodeProblemInput.parse("-1"))
        XCTAssertNil(LeetCodeProblemInput.parse("+1"))
    }

    /// A 30-digit paste overflows `Int`; it must be `nil`, not a trap.
    func testAbsurdlyLongNumberIsRejected() {
        XCTAssertNil(LeetCodeProblemInput.parse("999999999999999999999999999999"))
    }

    func testNonASCIIDigitsRejected() {
        XCTAssertNil(LeetCodeProblemInput.parse("١٢٣"))
    }

    // MARK: - Slugs

    func testSlugForms() {
        XCTAssertEqual(LeetCodeProblemInput.parse("two-sum"), .slug("two-sum"))
        XCTAssertEqual(LeetCodeProblemInput.parse("3sum-closest"), .slug("3sum-closest"))
        XCTAssertEqual(LeetCodeProblemInput.parse("n-queens-ii"), .slug("n-queens-ii"))
        XCTAssertEqual(LeetCodeProblemInput.parse("candy"), .slug("candy"))
    }

    func testSlugIsLowercased() {
        XCTAssertEqual(LeetCodeProblemInput.parse("Two-Sum"), .slug("two-sum"))
        XCTAssertEqual(LeetCodeProblemInput.parse("TWO-SUM"), .slug("two-sum"))
    }

    /// A title is not a slug, and guessing the transform would produce a
    /// confident request for a problem that does not exist.
    func testTitleWithSpacesRejected() {
        XCTAssertNil(LeetCodeProblemInput.parse("two sum"))
        XCTAssertNil(LeetCodeProblemInput.parse("Add Two Numbers"))
    }

    func testMalformedSlugsRejected() {
        XCTAssertNil(LeetCodeProblemInput.parse(""))
        XCTAssertNil(LeetCodeProblemInput.parse("   "))
        XCTAssertNil(LeetCodeProblemInput.parse("-two-sum"))
        XCTAssertNil(LeetCodeProblemInput.parse("two-sum-"))
        XCTAssertNil(LeetCodeProblemInput.parse("-"))
        XCTAssertNil(LeetCodeProblemInput.parse("---"))
        XCTAssertNil(LeetCodeProblemInput.parse("two_sum"))
        XCTAssertNil(LeetCodeProblemInput.parse("two.sum"))
        XCTAssertNil(LeetCodeProblemInput.parse("two+sum"))
        XCTAssertNil(LeetCodeProblemInput.parse("два-числа"))
    }

    // MARK: - URLs

    func testCanonicalProblemURL() {
        XCTAssertEqual(
            LeetCodeProblemInput.parse("https://leetcode.com/problems/two-sum/"),
            .slug("two-sum")
        )
    }

    func testURLWithoutTrailingSlashAndWithoutScheme() {
        XCTAssertEqual(
            LeetCodeProblemInput.parse("https://leetcode.com/problems/two-sum"),
            .slug("two-sum")
        )
        XCTAssertEqual(
            LeetCodeProblemInput.parse("leetcode.com/problems/two-sum"),
            .slug("two-sum")
        )
        XCTAssertEqual(
            LeetCodeProblemInput.parse("http://leetcode.com/problems/two-sum/"),
            .slug("two-sum")
        )
    }

    func testURLWithWWWHost() {
        XCTAssertEqual(
            LeetCodeProblemInput.parse("https://www.leetcode.com/problems/two-sum/"),
            .slug("two-sum")
        )
    }

    func testChinaHostAccepted() {
        XCTAssertEqual(
            LeetCodeProblemInput.parse("https://leetcode.cn/problems/two-sum/"),
            .slug("two-sum")
        )
    }

    func testURLWithTrailingPathQueryAndFragment() {
        XCTAssertEqual(
            LeetCodeProblemInput.parse("https://leetcode.com/problems/two-sum/description/"),
            .slug("two-sum")
        )
        XCTAssertEqual(
            LeetCodeProblemInput.parse(
                "https://leetcode.com/problems/two-sum/?envType=study-plan-v2&envId=top-100"
            ),
            .slug("two-sum")
        )
        XCTAssertEqual(
            LeetCodeProblemInput.parse("https://leetcode.com/problems/two-sum/#solutions"),
            .slug("two-sum")
        )
        XCTAssertEqual(
            LeetCodeProblemInput.parse(
                "https://leetcode.com/problems/two-sum/solutions/1234/hi/?x=1#y"
            ),
            .slug("two-sum")
        )
    }

    /// A contest URL nests `/problems/` deeper; the slug is still the component
    /// after the marker.
    func testContestURL() {
        XCTAssertEqual(
            LeetCodeProblemInput.parse(
                "https://leetcode.com/contest/weekly-contest-380/problems/two-sum/"
            ),
            .slug("two-sum")
        )
    }

    func testURLHostIsCaseInsensitive() {
        XCTAssertEqual(
            LeetCodeProblemInput.parse("HTTPS://LeetCode.com/Problems/Two-Sum/"),
            .slug("two-sum")
        )
    }

    func testURLWithPortStillResolves() {
        XCTAssertEqual(
            LeetCodeProblemInput.parse("https://leetcode.com:443/problems/two-sum/"),
            .slug("two-sum")
        )
    }

    /// Anything with a path shape that did not name a LeetCode problem is
    /// rejected outright rather than falling through to the slug rule.
    func testForeignAndIncompleteURLsRejected() {
        XCTAssertNil(LeetCodeProblemInput.parse("https://example.com/problems/two-sum/"))
        XCTAssertNil(LeetCodeProblemInput.parse("https://notleetcode.com/problems/two-sum/"))
        XCTAssertNil(LeetCodeProblemInput.parse("https://leetcode.com/"))
        XCTAssertNil(LeetCodeProblemInput.parse("https://leetcode.com/problems/"))
        XCTAssertNil(LeetCodeProblemInput.parse("https://leetcode.com/problemset/all/"))
        XCTAssertNil(LeetCodeProblemInput.parse("problems/two-sum"))
        XCTAssertNil(LeetCodeProblemInput.parse("two-sum/"))
        XCTAssertNil(LeetCodeProblemInput.parse("/"))
    }

    /// The URL rule runs first precisely so a URL containing digits is not read
    /// as a number.
    func testURLIsPreferredOverItsOwnDigits() {
        XCTAssertEqual(
            LeetCodeProblemInput.parse("https://leetcode.com/problems/3sum/"),
            .slug("3sum")
        )
    }

    // MARK: - normalizedSlug

    func testNormalizedSlugIsTheSharedRule() {
        XCTAssertEqual(LeetCodeProblemInput.normalizedSlug(" Two-Sum "), "two-sum")
        XCTAssertEqual(LeetCodeProblemInput.normalizedSlug("3sum"), "3sum")
        XCTAssertNil(LeetCodeProblemInput.normalizedSlug(""))
        XCTAssertNil(LeetCodeProblemInput.normalizedSlug("--"))
        XCTAssertNil(LeetCodeProblemInput.normalizedSlug("two sum"))
    }
}
