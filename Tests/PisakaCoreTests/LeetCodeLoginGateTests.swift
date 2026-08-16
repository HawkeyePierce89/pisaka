import XCTest
@testable import PisakaCore

/// The gate is the whole of "did the login succeed", so this suite is where that
/// decision is pinned — the login views are untested view code and hold no latch
/// of their own.
///
/// Two things are asserted about every case: what `offer(_:)` answers, **and how
/// many `userStatus` requests it took**. The count is not decoration. The failure
/// this file exists to fix is an SSO round trip firing the observer four or five
/// times, so "rejected values are remembered" and "at most one confirmation is in
/// flight" are the difference between one request and a confirmation storm
/// against an endpoint LeetCode rate-limits by operation name.
@MainActor
final class LeetCodeLoginGateTests: XCTestCase {

    // MARK: - Harness

    /// The pair allauth's anonymous session produces on the way *out* to the
    /// provider — cookies that exist and mean nothing.
    private let anonymous = LeetCodeCredentials(
        session: "anonymous-session",
        csrfToken: "csrf-value"
    )

    /// The pair that exists after the round trip: Django rotates the session key
    /// on login, which is what makes the rejected-value memo safe.
    private let rotated = LeetCodeCredentials(
        session: "rotated-session",
        csrfToken: "csrf-value"
    )

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    /// A recorded response, read through `#filePath` like every other fixture in
    /// this target (they are `exclude:`d from the package, never bundled).
    private static func fixture(_ name: String) -> Data {
        let url = repositoryRoot
            .appendingPathComponent("Tests/PisakaCoreTests/Fixtures/leetcode")
            .appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            preconditionFailure("missing fixture \(name)")
        }
        return data
    }

    private static var signedIn: LeetCodeHTTPResponse {
        LeetCodeHTTPResponse(statusCode: 200, body: fixture("user-status-signed-in.json"))
    }

    private static var signedOut: LeetCodeHTTPResponse {
        LeetCodeHTTPResponse(statusCode: 200, body: fixture("user-status-signed-out.json"))
    }

    // MARK: - The happy path

    /// Email/password: the very first candidate the cookie store produces is
    /// already a session, so it is confirmed once and handed straight back.
    func testAConfirmedCandidateIsHandedBackOnTheFirstOffer() async {
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.userStatus, with: Self.signedIn)
        let gate = LeetCodeLoginGate(transport: transport)

        let captured = await gate.offer(rotated)

        XCTAssertEqual(captured, rotated)
        XCTAssertEqual(transport.count(for: .userStatus), 1)
    }

    /// The one-shot: the sheet fires `onCredentials` once, and the observer's two
    /// check points (`didCommit`, `didFinish`) both see the same pair.
    func testAConfirmedCandidateIsHandedOutExactlyOnce() async {
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.userStatus, with: Self.signedIn)
        let gate = LeetCodeLoginGate(transport: transport)

        let first = await gate.offer(rotated)
        let again = await gate.offer(rotated)
        let other = await gate.offer(anonymous)

        XCTAssertEqual(first, rotated)
        XCTAssertNil(again, "the latch let a second capture through")
        XCTAssertNil(other, "the latch is the gate's, not the value's")
        XCTAssertEqual(
            transport.count(for: .userStatus),
            1,
            "a consumed latch must not cost a confirmation"
        )
    }

    // MARK: - The SSO failure this file fixes

    /// The whole bug in one test: the anonymous session allauth creates before
    /// redirecting to GitHub must not dismiss the sheet, and — the half that makes
    /// the fix usable — must not consume the one-shot either, or the real session
    /// arriving one navigation later would have nothing left to fire.
    func testAnAnonymousCandidateIsRejectedWithoutConsumingTheLatch() async {
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.userStatus, sequence: [Self.signedOut, Self.signedIn])
        let gate = LeetCodeLoginGate(transport: transport)

        let mid = await gate.offer(anonymous)
        let final = await gate.offer(rotated)

        XCTAssertNil(mid, "an anonymous session dismissed the sheet")
        XCTAssertEqual(final, rotated, "the latch did not survive a rejection")
        XCTAssertEqual(transport.count(for: .userStatus), 2)
    }

    /// An OAuth round trip is a chain of navigations and every one of them is a
    /// check. Re-confirming the same rejected value each time would be a
    /// confirmation storm against a rate-limited endpoint; the memo makes it one
    /// request, and the rotation that ends the flow is what keeps that safe.
    func testARejectedValueIsRememberedAndCostsOneConfirmation() async {
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.userStatus, sequence: [Self.signedOut, Self.signedIn])
        let gate = LeetCodeLoginGate(transport: transport)

        for _ in 0..<3 {
            let answer = await gate.offer(anonymous)
            XCTAssertNil(answer)
        }
        XCTAssertEqual(transport.count(for: .userStatus), 1, "the memo did not hold")

        let confirmed = await gate.offer(rotated)
        XCTAssertEqual(confirmed, rotated)
        XCTAssertEqual(transport.count(for: .userStatus), 2, "a rotated value must be re-asked")
    }

    // MARK: - Overlapping offers

    /// `didCommit` and `didFinish` land back to back, so a second offer routinely
    /// arrives while the first confirmation is still on the wire. It must wait for
    /// that answer rather than issue its own.
    func testAnOverlappingOfferOfTheSameValueWaitsInsteadOfAsking() async {
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.userStatus, with: Self.signedIn)
        let hold = Gate()
        transport.hold(.userStatus, on: hold)
        let gate = LeetCodeLoginGate(transport: transport)

        let first = Task { await gate.offer(rotated) }
        await hold.waitUntilReached()
        let second = Task { await gate.offer(rotated) }
        // Let the second offer reach its wait before the first one is answered;
        // otherwise this would only be testing the memo again.
        for _ in 0..<4 { await Task.yield() }
        hold.release()

        let captured = [await first.value, await second.value].compactMap { $0 }
        XCTAssertEqual(captured, [rotated], "exactly one offer must be handed the pair")
        XCTAssertEqual(transport.count(for: .userStatus), 1, "the two offers raced to the wire")
    }

    /// The reason waiting is not "drop while busy": the offer that arrives during
    /// a slow confirmation of the anonymous session is the *real* one. Dropping it
    /// would leave the sheet open forever with nothing left to retrigger it.
    func testAnOverlappingOfferOfARotatedValueIsStillConfirmed() async {
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.userStatus, sequence: [Self.signedOut, Self.signedIn])
        let hold = Gate()
        transport.hold(.userStatus, on: hold)
        let gate = LeetCodeLoginGate(transport: transport)

        let first = Task { await gate.offer(anonymous) }
        await hold.waitUntilReached()
        let second = Task { await gate.offer(rotated) }
        for _ in 0..<4 { await Task.yield() }
        // Twice: the held route stops the second confirmation as well.
        hold.release()
        hold.release()

        let firstAnswer = await first.value
        let secondAnswer = await second.value
        XCTAssertNil(firstAnswer)
        XCTAssertEqual(secondAnswer, rotated, "the real candidate was dropped")
        XCTAssertEqual(transport.count(for: .userStatus), 2)
    }

    // MARK: - Only an answer rejects

    /// An unreachable LeetCode is not a rejection. The candidate came out of a
    /// browser the user was just signing in with, so the gate behaves exactly as
    /// the shipped dismiss-first code did and `signIn(with:)`'s own tolerant
    /// confirmation takes it from there.
    func testATransportFailureAcceptsTheCandidate() async {
        let transport = ScriptedLeetCodeTransport()
        transport.fail(.userStatus)
        let gate = LeetCodeLoginGate(transport: transport)

        let accepted = await gate.offer(anonymous)
        let afterwards = await gate.offer(rotated)

        XCTAssertEqual(accepted, anonymous)
        XCTAssertNil(afterwards, "an accepted candidate must consume the latch")
        XCTAssertEqual(transport.count(for: .userStatus), 1)
    }

    /// The same tolerance for every failure that is not an answer: a `LeetCodeError`
    /// the gate cannot read as a rejection, and a response whose shape it cannot
    /// parse at all.
    func testEveryNonAnswerFailureAcceptsTheCandidate() async {
        let failures: [(String, (ScriptedLeetCodeTransport) -> Void)] = [
            ("network", { $0.fail(.userStatus, with: LeetCodeError.network(reason: "offline")) }),
            ("throttled", { $0.serve(.userStatus, body: Self.fixture("throttled.json")) }),
            ("apiChanged", { $0.serve(.userStatus, body: Self.fixture("invalid-no-data.json")) }),
            ("garbage", { $0.serve(.userStatus, json: "not json at all") }),
            ("500", { $0.serve(.userStatus, json: "{}", statusCode: 500) })
        ]
        for (name, script) in failures {
            let transport = ScriptedLeetCodeTransport()
            script(transport)
            let gate = LeetCodeLoginGate(transport: transport)

            let answer = await gate.offer(rotated)
            XCTAssertEqual(answer, rotated, name)
            XCTAssertEqual(transport.count(for: .userStatus), 1, name)
        }
    }

    /// LeetCode rejects a dead session with a 401/403 or an auth `errors` array as
    /// readily as with `isSignedIn: false` — the same conflation `signIn(with:)`
    /// makes, so the gate and the adoption path cannot disagree about what a dead
    /// session looks like.
    func testAnAuthenticationRefusalRejectsTheCandidate() async {
        let refusals: [(String, LeetCodeHTTPResponse)] = [
            (
                "graphql errors",
                LeetCodeHTTPResponse(
                    statusCode: 200,
                    body: Self.fixture("errors-not-authenticated.json")
                )
            ),
            ("401", LeetCodeHTTPResponse(statusCode: 401)),
            ("403", LeetCodeHTTPResponse(statusCode: 403))
        ]
        for (name, response) in refusals {
            let transport = ScriptedLeetCodeTransport()
            transport.serve(.userStatus, with: response)
            let gate = LeetCodeLoginGate(transport: transport)

            let answer = await gate.offer(anonymous)
            XCTAssertNil(answer, name)
            XCTAssertEqual(transport.count(for: .userStatus), 1, name)
        }
    }
}
