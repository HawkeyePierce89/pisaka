import XCTest
@testable import PisakaCore

final class GitHubAvailabilityTests: XCTestCase {
    private let current = GitHubVersion(major: 2, minor: 99, patch: 0)

    func testNoGhAtAllIsNotInstalledWhateverTheAuthProbeSaid() {
        XCTAssertEqual(GitHubAvailability.decide(version: .unavailable, isSignedIn: false), .notInstalled)
        XCTAssertEqual(GitHubAvailability.decide(version: .unavailable, isSignedIn: true), .notInstalled)
    }

    func testAGhThatWillNotNameItselfIsAlsoNotInstalled() {
        XCTAssertEqual(GitHubAvailability.decide(version: .unreadable, isSignedIn: true), .notInstalled)
    }

    func testTooOldIsJudgedBeforeTheSignIn() {
        let old = GitHubVersion(major: 2, minor: 49, patch: 9)
        let expected = GitHubAvailability.tooOld(found: old, minimum: .minimum)
        XCTAssertEqual(GitHubAvailability.decide(version: .version(old), isSignedIn: true), expected)
        // Signed out as well: telling this user to run `gh auth login` would send
        // them down a road that ends in the same refusal.
        XCTAssertEqual(GitHubAvailability.decide(version: .version(old), isSignedIn: false), expected)
    }

    func testExactlyTheMinimumIsAccepted() {
        XCTAssertEqual(
            GitHubAvailability.decide(version: .version(.minimum), isSignedIn: true),
            .ready(version: .minimum)
        )
    }

    func testNewEnoughAndSignedOutIsNotSignedIn() {
        XCTAssertEqual(GitHubAvailability.decide(version: .version(current), isSignedIn: false), .notSignedIn)
    }

    func testNewEnoughAndSignedInIsReady() {
        XCTAssertEqual(GitHubAvailability.decide(version: .version(current), isSignedIn: true), .ready(version: current))
    }

    // MARK: - The sentences and the next steps

    func testEveryStateSentenceAndItsExactNextStep() {
        XCTAssertEqual(GitHubAvailability.notInstalled.message, "The GitHub CLI (gh) was not found.")
        XCTAssertEqual(GitHubAvailability.notInstalled.nextStep, "brew install gh")

        let tooOld = GitHubAvailability.tooOld(found: GitHubVersion(major: 2, minor: 40, patch: 1), minimum: .minimum)
        XCTAssertEqual(tooOld.message, "The GitHub CLI is version 2.40.1. Pisaka needs 2.50.0 or newer.")
        XCTAssertEqual(tooOld.nextStep, "brew upgrade gh")

        XCTAssertEqual(GitHubAvailability.notSignedIn.message, "The GitHub CLI is not signed in to GitHub.")
        XCTAssertEqual(GitHubAvailability.notSignedIn.nextStep, "gh auth login")

        XCTAssertEqual(GitHubAvailability.ready(version: current).message, "GitHub CLI 2.99.0.")
        XCTAssertNil(GitHubAvailability.ready(version: current).nextStep)
    }

    func testTheTooOldSentenceNamesBothVersions() {
        let found = GitHubVersion(major: 2, minor: 12, patch: 3)
        let message = GitHubAvailability.tooOld(found: found, minimum: .minimum).message
        XCTAssertTrue(message.contains("2.12.3"), message)
        XCTAssertTrue(message.contains("2.50.0"), message)
    }

    // MARK: - The two projections

    func testOnlyReadyIsReady() {
        XCTAssertTrue(GitHubAvailability.ready(version: current).isReady)
        XCTAssertFalse(GitHubAvailability.notInstalled.isReady)
        XCTAssertFalse(GitHubAvailability.notSignedIn.isReady)
        XCTAssertFalse(GitHubAvailability.tooOld(found: current, minimum: .minimum).isReady)
    }

    func testVersionIsCarriedByTheTwoStatesThatHaveOne() {
        XCTAssertEqual(GitHubAvailability.ready(version: current).version, current)
        XCTAssertEqual(GitHubAvailability.tooOld(found: current, minimum: .minimum).version, current)
        XCTAssertNil(GitHubAvailability.notInstalled.version)
        XCTAssertNil(GitHubAvailability.notSignedIn.version)
    }
}
