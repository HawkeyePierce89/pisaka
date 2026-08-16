import Foundation

/// The signed-in LeetCode session: the two cookies every authenticated call
/// needs.
///
/// LeetCode authenticates a browser with `LEETCODE_SESSION` and cross-checks
/// mutating calls against `csrftoken`, which must be sent *both* as a cookie and
/// as the `x-csrftoken` header. There is no API key and no OAuth flow to obtain
/// them: the user signs in through a real `WKWebView` — including Google/GitHub
/// SSO, which is precisely why a scripted username/password login is not an
/// option — and the app lifts the pair out of the cookie store afterwards.
///
/// **Holding the pair is not the same as being signed in.** LeetCode hands out a
/// `LEETCODE_SESSION` for an *anonymous* Django session too — django-allauth
/// creates one at `/accounts/<provider>/login/`, on the way out to the SSO
/// provider — so what the cookie store produces is a candidate that
/// `LeetCodeLoginGate` confirms with LeetCode before anything adopts it (L26).
/// Once adopted, a value of this type is the session every authenticated call
/// sends.
///
/// `Codable` because the Keychain item is one JSON blob (`LeetCodeKeychainStore`),
/// with explicit keys so a rename here cannot silently invalidate everyone's
/// stored session.
public struct LeetCodeCredentials: Equatable, Sendable, Codable {
    /// The `LEETCODE_SESSION` cookie value — the session itself.
    public let session: String
    /// The `csrftoken` cookie value, sent as a cookie *and* as `x-csrftoken`.
    public let csrfToken: String

    public init(session: String, csrfToken: String) {
        self.session = session
        self.csrfToken = csrfToken
    }

    private enum CodingKeys: String, CodingKey {
        case session
        case csrfToken
    }

    /// The name of the session cookie in LeetCode's cookie store.
    public static let sessionCookieName = "LEETCODE_SESSION"
    /// The name of the CSRF cookie in LeetCode's cookie store.
    public static let csrfCookieName = "csrftoken"

    /// The pair rendered as a `Cookie` header value.
    ///
    /// Lives here rather than in `LeetCodeAPI` so the two cookie *names* are
    /// written down exactly once: the same constants that find the cookies in the
    /// `WKWebView` store put them back on the wire, and a LeetCode rename is a
    /// one-line fix that cannot leave the two halves disagreeing.
    public var cookieHeaderValue: String {
        "\(Self.sessionCookieName)=\(session); \(Self.csrfCookieName)=\(csrfToken)"
    }

    /// Turn the cookies a `WKWebView` store handed over into a **candidate** pair,
    /// or `nil` when the two cookies are not both there.
    ///
    /// The one rule both platforms' login views share, and the reason it is pure:
    /// the observers on macOS and iOS are untested view code, so nothing about
    /// what a login *is* may live in either of them. What it answers is "are both
    /// cookies present and non-empty", which is necessary and **not sufficient**:
    /// whether that pair is a signed-in session is `LeetCodeLoginGate`'s question
    /// to ask LeetCode (L26).
    ///
    /// - Both cookies are required. LeetCode sets `csrftoken` for anonymous
    ///   visitors too, so seeing it alone means nothing; `LEETCODE_SESSION` alone
    ///   cannot make a mutating call. Anything short of both is "no candidate".
    /// - Values are trimmed and an empty value counts as absent — a sign-out
    ///   clears cookies by *blanking* them as often as by deleting them, and a
    ///   `LEETCODE_SESSION=""` accepted as a session is a login that appears to
    ///   work and then fails on every call.
    /// - Cookies with any other name are ignored; there are a dozen of them and
    ///   none matter here.
    /// - When a name appears more than once (a store mid-refresh can hold both the
    ///   old and the new cookie), the **last** non-empty value wins, matching the
    ///   order a jar appends refreshed cookies in.
    public static func from(cookies: [(name: String, value: String)]) -> LeetCodeCredentials? {
        var session: String?
        var csrf: String?
        for cookie in cookies {
            let value = cookie.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            switch cookie.name {
            case sessionCookieName: session = value
            case csrfCookieName: csrf = value
            default: continue
            }
        }
        guard let session, let csrf else { return nil }
        return LeetCodeCredentials(session: session, csrfToken: csrf)
    }
}

/// Where the LeetCode session is kept between launches.
///
/// The pure, testable seam over the Keychain wrapper (`LeetCodeKeychainStore`,
/// Task 7). Every member is defaulted so a partial in-memory stub compiles by
/// implementing only what it needs — the `CredentialStore`/`GitServicing`
/// precedent — and, as there, the defaults are chosen so that *absence is the
/// explicit signal*: a store that implements nothing reads as "signed out", which
/// is the safe verdict, since every LeetCode operation in this integration
/// requires a session and reports `notLoggedIn` without one.
public protocol LeetCodeCredentialStore {
    /// The stored session, or `nil` when none is stored — or when it is
    /// unreadable, which is deliberately not distinguished: an unreadable session
    /// cannot be used, and the recovery for both is the same sign-in.
    func load() -> LeetCodeCredentials?
    /// Persist `credentials`, replacing any previously stored pair.
    func save(_ credentials: LeetCodeCredentials) throws
    /// Remove the stored session (a no-op when none is stored). Sign-out calls
    /// this *and* clears the web view's cookies; either alone leaves the user
    /// half signed in.
    func clear() throws
}

public extension LeetCodeCredentialStore {
    func load() -> LeetCodeCredentials? { nil }
    func save(_ credentials: LeetCodeCredentials) throws {}
    func clear() throws {}
}
