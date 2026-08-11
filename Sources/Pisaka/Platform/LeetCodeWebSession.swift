#if os(macOS) || os(iOS)
import Foundation
import PisakaCore
import WebKit

/// The web-view side of the LeetCode session: where the login page is, which
/// cookie store the two login views share, and the two operations both of them
/// perform on it — lift the session out, and purge it.
///
/// Lives in the non-gated `Platform/` layer for the same reason `LicenseTextView`
/// does: the *policy* is identical on macOS and iOS and only the view chrome
/// differs, so the two `LeetCodeLoginView`s are thin shells around this and
/// cannot drift apart in what counts as a successful login or what a sign-out
/// removes. It holds no state of its own — `WKWebsiteDataStore.default()` is the
/// state, and it lives on disk.
///
/// **Why a real web view at all.** LeetCode has no API key and no OAuth flow; a
/// session is two cookies a browser obtains, and a great many accounts are
/// Google/GitHub SSO, which a scripted username/password login could not drive
/// even in principle. So the user signs in exactly as they would in Safari and
/// the app only ever *watches* the cookie store — it never sees a password, and
/// there is nothing here to keep in step with LeetCode's login page markup.
///
/// **The store is persistent, deliberately.** `WKWebsiteDataStore.default()`
/// rather than `.nonPersistent()`: an SSO round trip leaves and re-enters the web
/// view through the provider's own domain, and providers keep their "you are
/// signed in here" state in cookies of their own. An ephemeral store would drop
/// those between the redirects that need them and turn a one-tap SSO sign-in into
/// a full re-authentication — sometimes into a loop. The cost is that cookies
/// outlive the sheet, which is exactly why `signOut` purges them rather than
/// relying on the store going away.
@MainActor
enum LeetCodeWebSession {
    /// The page the login view opens.
    static let loginURL = URL(string: "https://leetcode.com/accounts/login/")!

    /// The registrable domain the session cookies belong to.
    static let host = "leetcode.com"

    /// The one cookie store both login views read and both sign-outs purge.
    static var dataStore: WKWebsiteDataStore { .default() }

    /// The session the cookie store currently holds, or `nil` when the user is
    /// not (yet) signed in.
    ///
    /// The decision itself is Core's (`LeetCodeCredentials.from(cookies:)`) — the
    /// observers on both platforms are untested view code, so *when a login
    /// succeeded* must not be decided in either of them. What this adds is the
    /// domain filter, which Core cannot apply because a `(name, value)` pair
    /// carries no domain: an SSO detour visits the provider's own site inside this
    /// same web view, and a `csrftoken` set by whoever that is must not be mistaken
    /// for LeetCode's.
    static func credentials(in store: WKHTTPCookieStore) async -> LeetCodeCredentials? {
        let cookies = await allCookies(in: store)
        return LeetCodeCredentials.from(
            cookies: cookies
                .filter(isLeetCode)
                .map { (name: $0.name, value: $0.value) }
        )
    }

    /// Forget the session everywhere: the web view's cookies *and* the credential
    /// store, through the model.
    ///
    /// The two halves are one call because either alone leaves the user half
    /// signed in — a cleared Keychain with live cookies signs them straight back
    /// in the next time the login sheet opens, and live credentials with cleared
    /// cookies leave the app signed in to an account the login page no longer
    /// knows. Cookies go first: `LeetCodeModel.signOut()` is synchronous and
    /// publishes immediately, so doing it the other way round would leave a window
    /// in which the UI says "signed out" and the cookies are still there.
    static func signOut(model: LeetCodeModel) async {
        await clearCookies(in: dataStore.httpCookieStore)
        model.signOut()
    }

    /// Delete every `leetcode.com` cookie from `store`.
    ///
    /// Scoped to this host rather than
    /// `removeData(ofTypes:.allWebsiteDataTypes)`: the default data store is the
    /// process-wide one, and signing out of LeetCode is not a reason to sign the
    /// user out of every other site a web view in this app has ever loaded.
    static func clearCookies(in store: WKHTTPCookieStore) async {
        for cookie in await allCookies(in: store) where isLeetCode(cookie) {
            await deleteCookie(cookie, in: store)
        }
    }

    /// Whether a cookie belongs to LeetCode.
    ///
    /// Cookie domains carry a leading dot when they were set for subdomains too;
    /// matching the bare host *or* a `.leetcode.com` suffix accepts both spellings
    /// while rejecting a lookalike registrable domain that merely ends in the same
    /// letters.
    private static func isLeetCode(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.hasPrefix(".")
            ? String(cookie.domain.dropFirst())
            : cookie.domain
        return domain.caseInsensitiveCompare(host) == .orderedSame
            || domain.lowercased().hasSuffix("." + host)
    }

    /// `WKHTTPCookieStore`'s two callback APIs, awaited.
    ///
    /// Spelled out with continuations rather than relying on the compiler's
    /// generated `async` overloads, because those are named by a renaming rule
    /// (`getAllCookies(_:)` → `allCookies()`) that is invisible at the call site
    /// and has changed spelling across SDKs. Both completion handlers are
    /// delivered on the main thread, which is where this enum already is.
    private static func allCookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private static func deleteCookie(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            store.delete(cookie) { continuation.resume() }
        }
    }
}

/// The login web view and the watcher on its cookie store: everything about
/// signing in that is not view chrome.
///
/// Both platforms' `LeetCodeLoginView`s are a `View`Representable around *this* —
/// they supply a sheet or a full-screen cover and nothing else — so the part that
/// could actually be wrong (when to look, what to look at, how many times to fire)
/// is written once. It is a `WKNavigationDelegate` rather than a KVO observer on
/// the cookie store because `WKHTTPCookieStore`'s change notifications require
/// registering an observer object and fire for every cookie the page sets; a
/// navigation boundary is both cheaper and the moment the interesting cookies
/// have actually landed.
///
/// **Checked at two points per navigation, and fired at most once.** `didCommit`
/// is when the response's `Set-Cookie` headers have been applied and the page has
/// begun rendering; `didFinish` is when its subresources are done. LeetCode's
/// sign-in posts and then redirects, so in practice `didCommit` of the
/// post-login page already carries the session — but a page that stalls on a
/// slow subresource would otherwise delay the sheet's dismissal for no reason,
/// and one that sets the cookie from script after load is caught by the later
/// check. `hasCaptured` makes the pair idempotent: the sign-in confirmation is a
/// network call and a Keychain write, and firing it twice would race two
/// `signIn`s against each other for no gain.
@MainActor
final class LeetCodeLoginObserver: NSObject, WKNavigationDelegate {
    /// Handed the session the moment one appears — exactly once.
    var onCredentials: (LeetCodeCredentials) -> Void

    private var hasCaptured = false

    init(onCredentials: @escaping (LeetCodeCredentials) -> Void) {
        self.onCredentials = onCredentials
    }

    /// A web view on LeetCode's login page, sharing the persistent cookie store.
    ///
    /// Created here rather than in either representable so both platforms get the
    /// same configuration — in particular the same data store, which is what makes
    /// `LeetCodeWebSession.signOut` purge the cookies this view will read next
    /// time.
    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = LeetCodeWebSession.dataStore
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.load(URLRequest(url: LeetCodeWebSession.loginURL))
        return webView
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        captureIfSignedIn(in: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        captureIfSignedIn(in: webView)
    }

    private func captureIfSignedIn(in webView: WKWebView) {
        guard !hasCaptured else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        Task { @MainActor in
            // Re-checked after the hop: two navigations can be in flight, and the
            // store read suspends.
            guard !self.hasCaptured,
                  let credentials = await LeetCodeWebSession.credentials(in: store)
            else { return }
            self.hasCaptured = true
            self.onCredentials(credentials)
        }
    }
}
#endif
