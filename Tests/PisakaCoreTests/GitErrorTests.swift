import XCTest
@testable import PisakaCore

final class GitErrorTests: XCTestCase {
    func testGitUnavailableDescription() {
        XCTAssertEqual(
            GitError.gitUnavailable.errorDescription,
            "Could not run “git”. Make sure it is installed and on your PATH."
        )
    }

    func testNotARepositoryWithNonEmptyStderrPassesItThroughTrimmed() {
        let error = GitError.notARepository(stderr: "  fatal: not a git repository\n")
        XCTAssertEqual(error.errorDescription, "fatal: not a git repository")
    }

    func testNotARepositoryWithEmptyStderrFallsBackToDefaultMessage() {
        XCTAssertEqual(
            GitError.notARepository(stderr: "").errorDescription,
            "This folder is not a git repository."
        )
    }

    func testNotARepositoryWithWhitespaceStderrFallsBackToDefaultMessage() {
        XCTAssertEqual(
            GitError.notARepository(stderr: "   \n\t ").errorDescription,
            "This folder is not a git repository."
        )
    }

    func testRevertFailedReturnsItsReason() {
        let reason = "Refusing to revert: oldPath is already occupied."
        XCTAssertEqual(GitError.revertFailed(reason: reason).errorDescription, reason)
    }

    func testCheckoutFailedReturnsItsReason() {
        let reason = "error: Your local changes to the following files would be "
            + "overwritten by checkout:\n\tREADME.md"
        XCTAssertEqual(GitError.checkoutFailed(reason: reason).errorDescription, reason)
    }

    func testFetchFailedReturnsItsReason() {
        let reason = "fatal: unable to access 'https://example.com/r.git/': timed out"
        XCTAssertEqual(GitError.fetchFailed(reason: reason).errorDescription, reason)
    }

    func testCommitFailedReturnsItsReason() {
        // The dialog shows git's own stderr verbatim: a failing pre-commit hook's
        // output is the only thing that explains why the commit was refused.
        let reason = "pre-commit hook failed:\nsrc/a.swift: 3 lint errors"
        XCTAssertEqual(GitError.commitFailed(reason: reason).errorDescription, reason)
    }

    func testPushFailedReturnsItsReason() {
        let reason = "fatal: unable to access 'https://example.com/r.git/': timed out"
        XCTAssertEqual(GitError.pushFailed(reason: reason).errorDescription, reason)
    }

    func testCommitAndPushFailuresAreDistinctCases() {
        // "Commit created, push failed" is a state of its own, so the two failures
        // must never be conflated even when they carry the same text.
        XCTAssertNotEqual(GitError.commitFailed(reason: "x"), GitError.pushFailed(reason: "x"))
    }

    func testCredentialsRequiredNamesHostAndDirectsToSettings() {
        XCTAssertEqual(
            GitError.credentialsRequired(host: "github.com").errorDescription,
            "Add a Personal Access Token for github.com in Settings."
        )
    }

    func testLocalizedDescriptionUsesErrorDescription() {
        // The model surfaces `error.localizedDescription`; confirm LocalizedError
        // wiring routes it to our human text rather than the generic fallback.
        XCTAssertEqual(
            (GitError.gitUnavailable as Error).localizedDescription,
            "Could not run “git”. Make sure it is installed and on your PATH."
        )
    }
}
