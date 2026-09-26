import XCTest
@testable import PisakaCore

final class LeetCodeCredentialsTests: XCTestCase {
    /// A minimal in-memory store for flows that only need a session to exist.
    private final class MemoryStore: LeetCodeCredentialStore {
        var stored: LeetCodeCredentials?
        var clearCount = 0
        func load(_ read: LeetCodeCredentialRead) -> LeetCodeCredentials? { stored }
        func save(_ credentials: LeetCodeCredentials) throws { stored = credentials }
        func clear() throws {
            stored = nil
            clearCount += 1
        }
    }

    /// A store relying entirely on the protocol-extension defaults — confirms the
    /// defaults spell "signed out" rather than crashing or inventing a session.
    private struct EmptyDefaultStore: LeetCodeCredentialStore {}

    private func cookies(_ pairs: [(String, String)]) -> [(name: String, value: String)] {
        pairs.map { (name: $0.0, value: $0.1) }
    }

    // MARK: - cookies → credentials

    func testBothCookiesPresentProducesCredentials() {
        let result = LeetCodeCredentials.from(cookies: cookies([
            ("LEETCODE_SESSION", "sess-abc"),
            ("csrftoken", "csrf-xyz"),
        ]))
        XCTAssertEqual(result, LeetCodeCredentials(session: "sess-abc", csrfToken: "csrf-xyz"))
    }

    func testCookieOrderDoesNotMatter() {
        let result = LeetCodeCredentials.from(cookies: cookies([
            ("csrftoken", "csrf-xyz"),
            ("LEETCODE_SESSION", "sess-abc"),
        ]))
        XCTAssertEqual(result, LeetCodeCredentials(session: "sess-abc", csrfToken: "csrf-xyz"))
    }

    func testUnrelatedCookiesAreIgnored() {
        // LeetCode's store holds a dozen cookies; none of the others matter.
        let result = LeetCodeCredentials.from(cookies: cookies([
            ("__cf_bm", "whatever"),
            ("LEETCODE_SESSION", "sess-abc"),
            ("gr_user_id", "1234"),
            ("csrftoken", "csrf-xyz"),
            ("_gid", "GA1.2.3"),
        ]))
        XCTAssertEqual(result, LeetCodeCredentials(session: "sess-abc", csrfToken: "csrf-xyz"))
    }

    func testMissingSessionCookieIsNotSignedIn() {
        // `csrftoken` alone is what an anonymous visitor already has.
        XCTAssertNil(LeetCodeCredentials.from(cookies: cookies([("csrftoken", "csrf-xyz")])))
    }

    func testMissingCSRFCookieIsNotSignedIn() {
        XCTAssertNil(
            LeetCodeCredentials.from(cookies: cookies([("LEETCODE_SESSION", "sess-abc")]))
        )
    }

    func testNoCookiesAtAllIsNotSignedIn() {
        XCTAssertNil(LeetCodeCredentials.from(cookies: []))
    }

    func testEmptySessionValueIsTreatedAsAbsent() {
        // Signing out often blanks the cookie rather than deleting it; an accepted
        // empty session is a login that appears to work and fails on every call.
        XCTAssertNil(LeetCodeCredentials.from(cookies: cookies([
            ("LEETCODE_SESSION", ""),
            ("csrftoken", "csrf-xyz"),
        ])))
    }

    func testWhitespaceOnlyCSRFValueIsTreatedAsAbsent() {
        XCTAssertNil(LeetCodeCredentials.from(cookies: cookies([
            ("LEETCODE_SESSION", "sess-abc"),
            ("csrftoken", "   "),
        ])))
    }

    func testValuesAreTrimmed() {
        let result = LeetCodeCredentials.from(cookies: cookies([
            ("LEETCODE_SESSION", "  sess-abc\n"),
            ("csrftoken", " csrf-xyz "),
        ]))
        XCTAssertEqual(result, LeetCodeCredentials(session: "sess-abc", csrfToken: "csrf-xyz"))
    }

    func testDuplicateCookieNameTakesTheLastNonEmptyValue() {
        // A store mid-refresh can hold the old and the new cookie at once.
        let result = LeetCodeCredentials.from(cookies: cookies([
            ("LEETCODE_SESSION", "stale"),
            ("csrftoken", "csrf-xyz"),
            ("LEETCODE_SESSION", "fresh"),
        ]))
        XCTAssertEqual(result?.session, "fresh")
    }

    func testDuplicateCookieNameSkipsABlankedLaterValue() {
        let result = LeetCodeCredentials.from(cookies: cookies([
            ("LEETCODE_SESSION", "sess-abc"),
            ("LEETCODE_SESSION", ""),
            ("csrftoken", "csrf-xyz"),
        ]))
        XCTAssertEqual(result?.session, "sess-abc")
    }

    func testCookieNameMatchingIsCaseSensitive() {
        // These are the exact names LeetCode sets; a differently-cased cookie is a
        // different cookie, not this one.
        XCTAssertNil(LeetCodeCredentials.from(cookies: cookies([
            ("leetcode_session", "sess-abc"),
            ("CSRFToken", "csrf-xyz"),
        ])))
    }

    // MARK: - header rendering

    func testCookieHeaderValueSpellsBothCookies() {
        let credentials = LeetCodeCredentials(session: "sess-abc", csrfToken: "csrf-xyz")
        XCTAssertEqual(credentials.cookieHeaderValue, "LEETCODE_SESSION=sess-abc; csrftoken=csrf-xyz")
    }

    func testCookieNameConstantsAreTheWireNames() {
        XCTAssertEqual(LeetCodeCredentials.sessionCookieName, "LEETCODE_SESSION")
        XCTAssertEqual(LeetCodeCredentials.csrfCookieName, "csrftoken")
    }

    // MARK: - Codable (the Keychain's one JSON item)

    func testCredentialsRoundTripThroughJSON() throws {
        let original = LeetCodeCredentials(session: "sess-abc", csrfToken: "csrf-xyz")
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(LeetCodeCredentials.self, from: data), original)
    }

    func testCredentialsJSONKeysAreStable() throws {
        let data = try JSONEncoder().encode(
            LeetCodeCredentials(session: "s", csrfToken: "c")
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        XCTAssertEqual(object, ["session": "s", "csrfToken": "c"])
    }

    // MARK: - the store protocol

    /// The default answers `nil` for *both* kinds — a store that implements
    /// nothing is signed out, and in particular never "ask the user".
    func testDefaultStoreReadsAsSignedOutForBothReadKinds() {
        let store = EmptyDefaultStore()
        XCTAssertNil(store.load(.unattended))
        XCTAssertNil(store.load(.attended))
        XCTAssertNoThrow(try store.save(LeetCodeCredentials(session: "s", csrfToken: "c")))
        XCTAssertNoThrow(try store.clear())
        XCTAssertNil(store.load(.unattended))
        XCTAssertNil(store.load(.attended))
    }

    func testMemoryStoreSavesLoadsAndClears() throws {
        let store = MemoryStore()
        XCTAssertNil(store.load(.attended))
        let credentials = LeetCodeCredentials(session: "sess-abc", csrfToken: "csrf-xyz")
        try store.save(credentials)
        XCTAssertEqual(store.load(.attended), credentials)
        XCTAssertEqual(store.load(.unattended), credentials)
        try store.clear()
        XCTAssertNil(store.load(.attended))
        XCTAssertEqual(store.clearCount, 1)
    }

    // MARK: - the scripted store's permission switch

    /// The shared test store's "keychain wants permission" switch: an unattended
    /// read is refused, an attended one answers the stored pair — and every read
    /// is logged by kind, with `loadCount` the log's count.
    func testScriptedStoreRefusesUnattendedReadsWhenPermissionIsWanted() {
        let credentials = LeetCodeCredentials(session: "s", csrfToken: "c")
        let store = InMemoryLeetCodeCredentialStore(credentials)
        XCTAssertEqual(store.load(.unattended), credentials)
        store.wantsPermission = true
        XCTAssertNil(store.load(.unattended))
        XCTAssertEqual(store.load(.attended), credentials)
        XCTAssertEqual(store.reads, [.unattended, .unattended, .attended])
        XCTAssertEqual(store.loadCount, 3)
    }
}
