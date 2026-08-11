import Foundation
import PisakaCore

/// The real `LeetCodeTransport`: one `URLSession`, one request, one response.
///
/// The app half of the LeetCode seam, and the exact counterpart of
/// `LSPDownloadService` on the provisioning one — Core owns *which* URL, *which*
/// GraphQL document, *which* headers and *what the answer means*
/// (`LeetCodeAPI`); this file owns the socket and knows none of it. Untested by
/// repository convention, so it is kept to the three decisions it actually
/// makes: how the session is configured, what counts as "no response at all",
/// and how a `LeetCodeHTTPRequest` becomes a `URLRequest`.
///
/// Compiled on **both** destinations. Nothing here is platform-specific: the
/// login web views differ per platform, the bytes do not.
///
/// **The cookie jar is switched off at both ends, on purpose.** The one session
/// cookie in play is the one Core spells out in the `Cookie` header
/// (`LeetCodeCredentials.cookieHeaderValue`), and the whole seam exists so that
/// pair is auditable in a unit test. A jar would make a *second* source of
/// cookies — the `WKWebView` login store's copies migrate into a shared
/// `HTTPCookieStorage` readily — and then "which session did that request
/// actually use" would have two answers, one of them invisible. Worse, a stale
/// jar cookie can outlive a sign-out and keep an account signed in after the
/// Keychain item is gone. So: an `.ephemeral` configuration (no persistent jar
/// by construction), `httpCookieStorage = nil` and `httpCookieAcceptPolicy =
/// .never` (nothing is *kept* from a response), and `httpShouldHandleCookies =
/// false` per request (nothing is *attached* to one). Four statements of one
/// intent, the way `LSPDownloadService` states "nothing is cached" three times.
///
/// **Redirects are followed, as a browser would — but the session does not
/// follow them off LeetCode.** LeetCode answers some signed-out states with a 302
/// to the login page rather than a JSON error, and what `LeetCodeAPI` then parses
/// — an HTML body where JSON was expected — already has an answer (`apiChanged`),
/// while the authoritative signed-out verdict comes from
/// `userStatus.isSignedIn`. Suppressing redirects would change one confusing case
/// into a different confusing case and buy nothing. What a browser *also* does,
/// and `URLSession` does not do for a manually set header, is scope the cookie to
/// its origin: a `Location` pointing at another host would otherwise be answered
/// with the `Cookie` and `x-csrftoken` pair copied verbatim, handing that host a
/// live LeetCode session. `RedirectGuard` strips them per
/// `LeetCodeAPI.redirectMayCarryCredentials(from:to:)`, which is where the rule
/// is written and tested.
///
/// `@unchecked Sendable` over immutable `let`s, the `LSPProcessTransport` /
/// `LSPDownloadService` arrangement: there is no mutable state here at all, and
/// `URLSession` is documented as safe to use from multiple threads.
final class LeetCodeURLSessionTransport: LeetCodeTransport, @unchecked Sendable {
    /// How long one request may go without progress. LeetCode's GraphQL calls
    /// answer in well under a second; the 2 MB catalog is the slow one, and 30 s
    /// is "the connection has gone away" rather than "this is taking a while".
    private static let requestTimeout: TimeInterval = 30

    /// The ceiling on one whole exchange. The largest body this layer ever
    /// fetches is the ~2 MB problem list, so a minute is generous even on a poor
    /// link — and a request that trips it fails exactly like any other, which is
    /// to say the sheet shows `network` and the user can try again.
    private static let resourceTimeout: TimeInterval = 60

    private let session: URLSession

    /// Handed to each task rather than installed on the session, so the session
    /// does not hold it for the app's lifetime and nothing here has to be
    /// invalidated. It is stateless, so one instance serves every request.
    private let redirectGuard = RedirectGuard()

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        // Nothing here is worth re-serving from a cache: the catalog has its own
        // once-a-day staleness rule on disk (`LeetCodeCatalog`) and a statement
        // has its own cached fragment, both of which would be silently shadowed
        // by a URL cache answering a "refresh" with the bytes it already had.
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        // The model never has more than a couple of calls in flight (an open is a
        // strictly serial resolve → detail sequence, and a statement refresh is
        // one request), so this bounds nothing in practice. It is here so a burst
        // can never look like a scraper to the one endpoint in this integration
        // that rate-limits.
        configuration.httpMaximumConnectionsPerHost = 2
        // `waitsForConnectivity` stays off: offline must fail now and surface
        // `network`, not sit silently until the resource timeout. The user is
        // watching a spinner in a sheet.
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// Perform `request`.
    ///
    /// A non-2xx response is *not* a throw — it comes back as a
    /// `LeetCodeHTTPResponse` and `LeetCodeAPI` decides whether a 429 is
    /// `throttled` or a 403 is a throttle in disguise. The one interpretation
    /// made here is the one the protocol reserves for this side: a failure to
    /// obtain any HTTP response — DNS, TLS, timeout, a non-HTTP response — is
    /// `LeetCodeError.network`, carrying `URLError`'s own sentence ("The
    /// Internet connection appears to be offline."), which is better than
    /// anything this file could write and is what the user ends up reading.
    func send(_ request: LeetCodeHTTPRequest) async throws -> LeetCodeHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest, delegate: redirectGuard)
        } catch {
            throw LeetCodeError.network(reason: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LeetCodeError.network(reason: "The server did not answer with a web response.")
        }

        // Header names arrive in whatever case the server sent them, which is why
        // `LeetCodeHTTPResponse.headerValue(forName:)` matches case-insensitively
        // rather than this converting them to some canonical spelling: the one
        // header this layer reads (`Retry-After`) must be found either way, and a
        // normalisation here would be a second rule to keep in step with that one.
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String else { continue }
            headers[name] = String(describing: value)
        }

        return LeetCodeHTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}

/// Lets a redirect proceed, minus the session when it leaves LeetCode.
///
/// The redirect is *followed* either way — refusing it would turn LeetCode's own
/// "302 to the login page" into an empty body rather than the HTML the parser
/// already reports as `apiChanged`, and would suppress the ordinary
/// `leetcode.com` → `www.leetcode.com` hop as well. Only the credentials are
/// withheld, so an off-site hop answers as a signed-out request would: the
/// response is meaningless to `LeetCodeAPI` and reads as `apiChanged` or
/// `notLoggedIn`, which is what a request that could not be made *as this user*
/// should say.
///
/// `@unchecked Sendable` over no stored state at all: the decision is a pure
/// function of the two URLs.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalURL = task.originalRequest?.url, let newURL = request.url else {
            // No URL to compare means no basis for trusting the hop with the
            // session; strip and continue rather than guess.
            completionHandler(stripped(request))
            return
        }
        guard LeetCodeAPI.redirectMayCarryCredentials(from: originalURL, to: newURL) else {
            completionHandler(stripped(request))
            return
        }
        completionHandler(request)
    }

    private func stripped(_ request: URLRequest) -> URLRequest {
        var request = request
        for name in LeetCodeAPI.credentialHeaderNames {
            request.setValue(nil, forHTTPHeaderField: name)
        }
        return request
    }
}
