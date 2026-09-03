import XCTest
@testable import PisakaCore

final class GitHubVersionTests: XCTestCase {
    // MARK: - Parsing `gh --version`

    func testParsesTheRealTwoLineOutput() {
        let output = """
        gh version 2.99.0 (2026-09-01)
        https://github.com/cli/cli/releases/tag/v2.99.0
        """
        XCTAssertEqual(GitHubVersion.parse(output), GitHubVersion(major: 2, minor: 99, patch: 0))
    }

    func testTheReleaseUrlOnLineTwoIsNeverTheAnswer() {
        // The URL contains `v2.99.0`; a substring search would find it. Only a
        // line whose first two words are `gh version` is read, so a first line
        // that names no version reports `nil` rather than the URL's number.
        let output = """
        something else entirely
        https://github.com/cli/cli/releases/tag/v2.99.0
        """
        XCTAssertNil(GitHubVersion.parse(output))
    }

    func testParsesAPrereleaseByDroppingTheSuffix() {
        // A 2.50.0 release candidate has the flag 2.50.0 has, so it must not be
        // ordered below 2.50.0 and refused.
        XCTAssertEqual(
            GitHubVersion.parse("gh version 2.50.0-rc.1 (2024-05-20)"),
            GitHubVersion(major: 2, minor: 50, patch: 0)
        )
        XCTAssertEqual(
            GitHubVersion.parse("gh version 2.50.0+build.7 (2024-05-20)"),
            GitHubVersion(major: 2, minor: 50, patch: 0)
        )
    }

    func testParsesALeadingVAndAMissingPatch() {
        XCTAssertEqual(GitHubVersion.parseNumber("v2.51.1"), GitHubVersion(major: 2, minor: 51, patch: 1))
        XCTAssertEqual(GitHubVersion.parseNumber("2.50"), GitHubVersion(major: 2, minor: 50, patch: 0))
    }

    func testGarbageAndAbsenceBothParseToNil() {
        XCTAssertNil(GitHubVersion.parse(""))
        XCTAssertNil(GitHubVersion.parse("   \n\n  "))
        XCTAssertNil(GitHubVersion.parse("gh version"))
        XCTAssertNil(GitHubVersion.parse("gh version notanumber (2026-09-01)"))
        XCTAssertNil(GitHubVersion.parse("git version 2.39.5"))
        XCTAssertNil(GitHubVersion.parseNumber("2"))
        XCTAssertNil(GitHubVersion.parseNumber(""))
    }

    func testExtraWhitespaceInTheLineIsToleratedButTheShapeIsNot() {
        XCTAssertEqual(
            GitHubVersion.parse("gh   version   2.60.2 (2025-01-01)"),
            GitHubVersion(major: 2, minor: 60, patch: 2)
        )
        // A leading token before `gh` is a different shape and is refused.
        XCTAssertNil(GitHubVersion.parse("$ gh version 2.60.2 (2025-01-01)"))
    }

    // MARK: - Comparison

    func testComparisonAcrossMajorMinorAndPatch() {
        XCTAssertTrue(GitHubVersion(major: 1, minor: 99, patch: 99) < GitHubVersion(major: 2, minor: 0, patch: 0))
        XCTAssertTrue(GitHubVersion(major: 2, minor: 49, patch: 99) < GitHubVersion(major: 2, minor: 50, patch: 0))
        XCTAssertTrue(GitHubVersion(major: 2, minor: 50, patch: 0) < GitHubVersion(major: 2, minor: 50, patch: 1))
        XCTAssertFalse(GitHubVersion(major: 2, minor: 50, patch: 0) < GitHubVersion(major: 2, minor: 50, patch: 0))
        XCTAssertTrue(GitHubVersion(major: 2, minor: 50, patch: 0) >= GitHubVersion.minimum)
        XCTAssertTrue(GitHubVersion(major: 10, minor: 0, patch: 0) > GitHubVersion(major: 9, minor: 99, patch: 99))
    }

    func testDescriptionIsAlwaysThreeComponents() {
        XCTAssertEqual(GitHubVersion(major: 2, minor: 50).description, "2.50.0")
        XCTAssertEqual("\(GitHubVersion.minimum)", "2.50.0")
    }

    // MARK: - The pin

    func testMinimumIsTheVersionThatFirstShippedChecksJson() {
        // cli/cli#9079 (merged 2024-05-16) added `pr checks --json`; the first tag
        // containing it is v2.50.0. Moving this number means redoing that check.
        XCTAssertEqual(GitHubVersion.minimum, GitHubVersion(major: 2, minor: 50, patch: 0))
    }
}
