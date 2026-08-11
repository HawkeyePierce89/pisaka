import Foundation

/// One HTTP request Core wants performed, described in nothing but Foundation
/// values.
///
/// Deliberately *not* a `URLRequest`. The whole point of this seam is that Core
/// composes every byte it cares about — the `Cookie` header carrying the session,
/// the `x-csrftoken` LeetCode cross-checks it against, the `Referer` it refuses
/// requests without, and the GraphQL document itself — so the schema suite can
/// assert them byte for byte in a target that cannot link `URLSession`. The app
/// side (`LeetCodeURLSessionTransport`) translates this into a `URLRequest` and
/// knows nothing about what any of it means, exactly as `LSPProcessTransport`
/// knows nothing about JSON-RPC.
public struct LeetCodeHTTPRequest: Equatable, Sendable {
    /// The HTTP method, upper-cased as it goes on the wire (`"GET"`, `"POST"`).
    public var method: String
    /// The absolute URL to request.
    public var url: URL
    /// Every header Core wants sent, verbatim. The transport adds nothing of its
    /// own beyond what the platform forces (`Host`, `Content-Length`), and in
    /// particular must not attach cookies from a jar: the only session cookie in
    /// play is the one spelled out here.
    public var headers: [String: String]
    /// The request body, or `nil` for a body-less method.
    public var body: Data?

    public init(
        method: String = "GET",
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// What came back: a status code, the response headers, and the raw bytes.
///
/// The body stays `Data` rather than a decoded value because *every* LeetCode
/// response shape — the GraphQL envelope, the legacy REST catalog, and the HTML
/// throttle page LeetCode serves instead of JSON when it is rate-limiting — is
/// interpreted in one place (`LeetCodeAPI`), and that place needs the bytes.
public struct LeetCodeHTTPResponse: Equatable, Sendable {
    /// The HTTP status code. A non-HTTP response never reaches here — the app-side
    /// transport turns that into `LeetCodeError.network` instead of inventing one.
    public var statusCode: Int
    /// The response headers as delivered. Header names are case-insensitive on the
    /// wire, so read them through `headerValue(forName:)` rather than subscripting.
    public var headers: [String: String]
    /// The response body, possibly empty.
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// Whether the status code is in the 2xx range.
    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// The value of `name`, matched case-insensitively.
    ///
    /// RFC 9110 field names are case-insensitive and different stacks normalise
    /// them differently (`Retry-After` vs. `retry-after`), so the one header this
    /// layer actually reads must not depend on which spelling arrived.
    public func headerValue(forName name: String) -> String? {
        let wanted = name.lowercased()
        for (key, value) in headers where key.lowercased() == wanted {
            return value
        }
        return nil
    }
}

/// The whole app/Core boundary of the LeetCode integration: one request in, one
/// response out.
///
/// Core owns everything interesting — which URL, which GraphQL document, which
/// headers, and what the answer means — and knows nothing about how the bytes
/// travel. The app owns a `URLSession` and knows nothing about what they say.
/// That is the same split `LSPTransport`/`LSPProcessTransport` and
/// `GitServicing`/`GitCLIService` already make, for the same reason: it keeps the
/// decidable half unit-testable behind a scripted fake.
///
/// A transport never retries, never follows a LeetCode-specific redirect, and
/// never interprets a status code: a 429 is delivered as a 429 and the decision
/// to call that `throttled` belongs to `LeetCodeAPI`, which is the only thing
/// that knows LeetCode's throttle shapes. The one interpretation it *does* make
/// is that a failure to get any HTTP response at all — DNS, TLS, timeout, a
/// non-HTTP response — is `LeetCodeError.network`.
public protocol LeetCodeTransport: Sendable {
    /// Perform `request` and return whatever the server answered.
    ///
    /// - Throws: `LeetCodeError.network` when no HTTP response could be obtained.
    ///   A non-2xx response is *not* a throw — it is a `LeetCodeHTTPResponse` the
    ///   caller inspects.
    func send(_ request: LeetCodeHTTPRequest) async throws -> LeetCodeHTTPResponse
}
