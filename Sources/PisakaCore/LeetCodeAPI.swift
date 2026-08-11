import Foundation

/// Everything this app knows about LeetCode's wire format, in one file.
///
/// LeetCode publishes no API: no contract, no versioning, no deprecation notice.
/// The mitigation this area chose is *concentration* — every URL, every GraphQL
/// document, every header name and every JSON key path lives here, so a
/// LeetCode-side change is diagnosed and fixed in one place rather than hunted
/// through a request builder, three models and a view. `LeetCodeError.apiChanged`
/// carries the key path that did not match precisely so a bug report names the
/// line of *this* file to edit.
///
/// Two rules follow from that and are worth stating outright:
///
/// - **Nothing here shrugs.** A missing key, a null where a value belongs, an
///   unrecognised difficulty — all of them throw `apiChanged`. Returning an empty
///   catalog or an empty statement would be indistinguishable from a problem that
///   does not exist, and the user would be told the wrong thing forever.
/// - **Requests are composed byte for byte, not delegated.** Core builds the
///   `Cookie` header, the `x-csrftoken` LeetCode cross-checks it against, and the
///   `Referer` it refuses requests without — so the suite can assert them in a
///   target that cannot link `URLSession`, and so a cookie jar somewhere in the
///   app can never quietly substitute a different session.
///
/// The one deliberate leniency in the file is `status(fromRESTValue:)`; its
/// reasoning is written there.
///
/// Every call is made **signed in**: the credentials parameter is not optional
/// anywhere, because the product decision for this integration is that every
/// LeetCode operation requires a login (paid-only and solved status only exist
/// with one), and a signature that made the session optional would be an
/// invitation to re-litigate that per call site.
public enum LeetCodeAPI {

    // MARK: - Endpoints

    /// The site root — also the `Referer` LeetCode requires and the `<base href>`
    /// the statement document resolves relative CDN images against.
    public static let siteURL = URL(string: "https://leetcode.com/")!
    /// The single GraphQL endpoint both queries go to.
    public static let graphQLURL = URL(string: "https://leetcode.com/graphql")!
    /// The legacy REST catalog: the whole problem list — ~4000 rows, ~2 MB — in
    /// **one** response. The GraphQL equivalent is paged at 100 a time, i.e. ~41
    /// requests against an unofficial API for data that changes weekly; that is
    /// why this one endpoint of a different vintage is parsed alongside the
    /// GraphQL ones rather than for want of a modern alternative.
    public static let problemListURL = URL(string: "https://leetcode.com/api/problems/all/")!

    /// The browser LeetCode is told it is talking to.
    ///
    /// Sent because the session cookie was obtained in a real `WKWebView` and a
    /// request that carries it under an obviously non-browser agent is the kind of
    /// thing an unofficial endpoint blocks first. It is a plain, current Safari
    /// string — not an attempt to hide what the app is; the `Referer` and the
    /// session cookie already say the request came from the site.
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// The human-facing URL of a problem — what the seeded solution file's header
    /// comment points at.
    public static func problemURL(slug: String) -> URL {
        siteURL
            .appendingPathComponent("problems")
            .appendingPathComponent(slug)
    }

    // MARK: - GraphQL documents

    /// The login-confirmation query. `userStatus.isSignedIn` is the canonical
    /// logged-out signal for the whole integration — the one place login is
    /// decided, so a second source of truth (the REST catalog also reports a
    /// `user_name`) cannot disagree with it.
    public static let userStatusQuery = """
        query globalData {
          userStatus {
            username
            isSignedIn
            isPremium
          }
        }
        """

    /// Everything the open-problem flow needs about one problem, in one round
    /// trip: the number for the file name, the statement for the panel, the
    /// starter code to seed the file with, and the examples LC-2's Run will use.
    public static let questionDetailQuery = """
        query questionData($titleSlug: String!) {
          question(titleSlug: $titleSlug) {
            questionFrontendId
            title
            titleSlug
            content
            difficulty
            isPaidOnly
            exampleTestcaseList
            codeSnippets {
              lang
              langSlug
              code
            }
          }
        }
        """

    /// The operation names sent alongside the documents. LeetCode logs and
    /// rate-limits by these, and the scripted transport keys its canned replies on
    /// them, so they are named constants rather than literals inside the builders.
    public static let userStatusOperationName = "globalData"
    public static let questionDetailOperationName = "questionData"

    // MARK: - Requests

    /// `globalData` — is this session signed in, and as whom.
    public static func userStatusRequest(
        credentials: LeetCodeCredentials
    ) -> LeetCodeHTTPRequest {
        graphQLRequest(
            operationName: userStatusOperationName,
            query: userStatusQuery,
            variables: [:],
            credentials: credentials
        )
    }

    /// `questionData(titleSlug:)` — the statement, the snippets and the flags.
    public static func questionDetailRequest(
        slug: String,
        credentials: LeetCodeCredentials
    ) -> LeetCodeHTTPRequest {
        graphQLRequest(
            operationName: questionDetailOperationName,
            query: questionDetailQuery,
            variables: ["titleSlug": slug],
            credentials: credentials
        )
    }

    /// The whole catalog, as one `GET`.
    public static func problemListRequest(
        credentials: LeetCodeCredentials
    ) -> LeetCodeHTTPRequest {
        LeetCodeHTTPRequest(
            method: "GET",
            url: problemListURL,
            headers: commonHeaders(credentials: credentials)
        )
    }

    /// The headers that carry the session, by name.
    ///
    /// Named here rather than at the transport because this file is where the
    /// decision that they *are* the session lives (`commonHeaders`): a fourth
    /// credential header added below would otherwise keep travelling across
    /// redirects that this list is what stops.
    public static let credentialHeaderNames = ["Cookie", "x-csrftoken"]

    /// Whether a redirect from `originalURL` to `newURL` may still carry
    /// ``credentialHeaderNames``.
    ///
    /// The transport follows redirects as a browser would (see its own note), and
    /// the session travels as a **manually set** `Cookie` header rather than in a
    /// jar — which is precisely the case `URLSession` re-sends verbatim to
    /// whatever host the 30x names, including a different one. A `Location` off
    /// `leetcode.com` therefore hands a third party a live, browser-equivalent
    /// LeetCode session; the jar this layer deliberately does not use is the very
    /// mechanism that would have applied a same-origin rule for us, so the rule
    /// has to be written down here.
    ///
    /// The rule is derived from the request rather than from `siteURL`: the
    /// credentials may travel to the host they were already being sent to, and to
    /// hosts within it (`leetcode.com` → `www.leetcode.com`). It is deliberately
    /// **not** ``LeetCodeProblemInput``'s "is this a LeetCode URL" rule, which
    /// also accepts `leetcode.cn` — that is a different operator, and a session
    /// obtained on `.com` has no business being sent there. Scheme is checked too,
    /// so an `https` → `http` downgrade cannot carry the pair in clear text.
    public static func redirectMayCarryCredentials(from originalURL: URL, to newURL: URL) -> Bool {
        guard let original = originalURL.host?.lowercased(),
              let new = newURL.host?.lowercased(),
              newURL.scheme?.lowercased() == originalURL.scheme?.lowercased()
        else { return false }
        return new == original
            || new.hasSuffix("." + original)
            || original.hasSuffix("." + new)
    }

    /// The headers every request carries, whatever its method.
    ///
    /// `csrftoken` goes out **twice** — inside `Cookie` and as `x-csrftoken` —
    /// because that is exactly how Django's CSRF check works: it compares the two
    /// and rejects the request when they disagree or either is missing. Sending
    /// only the cookie is the single most likely reason a hand-rolled LeetCode
    /// call gets a 403, which is why the pair is assembled here once and not at
    /// three call sites.
    private static func commonHeaders(
        credentials: LeetCodeCredentials
    ) -> [String: String] {
        [
            "Accept": "application/json",
            "Cookie": credentials.cookieHeaderValue,
            "Referer": siteURL.absoluteString,
            "User-Agent": userAgent,
            "x-csrftoken": credentials.csrfToken
        ]
    }

    /// One GraphQL POST. The body is serialised with sorted keys so the bytes are
    /// reproducible and the suite can assert them literally — `JSONSerialization`
    /// otherwise orders a dictionary however the hash table felt that morning.
    private static func graphQLRequest(
        operationName: String,
        query: String,
        variables: [String: String],
        credentials: LeetCodeCredentials
    ) -> LeetCodeHTTPRequest {
        let payload: [String: Any] = [
            "operationName": operationName,
            "query": query,
            "variables": variables
        ]
        // `.sortedKeys` is the only reason this cannot fail: the payload is three
        // string-keyed members of JSON-legal types. An empty body would produce a
        // 400 the parser reports as `apiChanged`, which is a truthful — if
        // roundabout — answer to a serialisation bug that cannot happen.
        let body = (try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
        var headers = commonHeaders(credentials: credentials)
        headers["Content-Type"] = "application/json"
        return LeetCodeHTTPRequest(
            method: "POST",
            url: graphQLURL,
            headers: headers,
            body: body
        )
    }

    // MARK: - User status

    /// What `globalData` answered.
    ///
    /// Declared here rather than beside `LeetCodeProblem` because it is not a
    /// domain model — it is this endpoint's response shape, and it changes when
    /// LeetCode changes, which is the definition of what belongs in this file.
    public struct UserStatus: Equatable, Sendable {
        /// The account name, or `nil` when signed out (the wire says `""`).
        public let username: String?
        /// LeetCode's own verdict on the session — the canonical login signal.
        public let isSignedIn: Bool
        /// Whether the account has Premium. `nil` when LeetCode did not say, which
        /// it does not for anonymous callers.
        public let isPremium: Bool?

        public init(username: String?, isSignedIn: Bool, isPremium: Bool?) {
            self.username = username
            self.isSignedIn = isSignedIn
            self.isPremium = isPremium
        }
    }

    /// Parse a `globalData` response.
    ///
    /// A signed-out answer is **returned, not thrown**: "who am I" is the one
    /// question whose honest answer can be "nobody", and the sign-in flow needs to
    /// hear that as a value. Every *other* call turns the same verdict into
    /// `notLoggedIn`, via `throwIfSignedOut(_:)` below.
    public static func parseUserStatus(
        _ response: LeetCodeHTTPResponse
    ) throws -> UserStatus {
        let data = try graphQLData(response, context: "userStatus")
        let status = try data.object("userStatus")
        let isSignedIn = try status.bool("isSignedIn")
        let rawName = try status.optionalString("username") ?? ""
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return UserStatus(
            username: name.isEmpty ? nil : name,
            isSignedIn: isSignedIn,
            isPremium: try status.optionalBool("isPremium")
        )
    }

    /// Turn a signed-out user status into the error every non-login operation
    /// reports.
    public static func throwIfSignedOut(_ status: UserStatus) throws {
        guard status.isSignedIn else { throw LeetCodeError.notLoggedIn }
    }

    // MARK: - Question detail

    /// Parse a `questionData` response.
    ///
    /// - Returns: the detail, or `nil` when LeetCode answered `data.question:
    ///   null` — its recorded way of saying "no such slug". That is a legitimate
    ///   answer to a slug the user typed, not a shape violation, and conflating
    ///   the two would tell somebody who mistyped `two-sums` that LeetCode's API
    ///   had changed.
    /// - Throws: `paidOnly`/`notLoggedIn`/`throttled` when the response says so,
    ///   `apiChanged` for anything whose shape does not match.
    ///
    /// A premium problem is *not* rejected here. LeetCode answers it with
    /// `isPaidOnly: true` and null `content`/`codeSnippets`, so this parser
    /// tolerates both absences when the flag is set and hands the flag on; the
    /// refusal belongs to the model, which is the layer that knows a file was
    /// about to be written.
    public static func parseQuestionDetail(
        _ response: LeetCodeHTTPResponse,
        requestedSlug: String
    ) throws -> LeetCodeProblemDetail? {
        let data = try graphQLData(response, context: "question", slug: requestedSlug)
        guard let question = try data.optionalObject("question") else { return nil }

        let isPaidOnly = try question.bool("isPaidOnly")
        let slug = try slug(
            fromWireValue: try question.optionalString("titleSlug"),
            path: question.path(of: "titleSlug")
        ) ?? requestedSlug
        let problem = LeetCodeProblem(
            frontendID: try question.integer("questionFrontendId"),
            slug: slug,
            title: try question.string("title"),
            difficulty: try difficulty(
                fromGraphQLName: try question.string("difficulty"),
                path: question.path(of: "difficulty")
            ),
            isPaidOnly: isPaidOnly
        )

        // Premium: the two members below arrive as `null`, and demanding them
        // would report `apiChanged` for a problem that is merely locked.
        guard let content = try question.optionalString("content") else {
            guard isPaidOnly else {
                throw LeetCodeError.apiChanged(detail: question.path(of: "content"))
            }
            return LeetCodeProblemDetail(problem: problem, content: "", codeSnippets: [:])
        }

        var snippets: [String: String] = [:]
        if let rawSnippets = try question.optionalArray("codeSnippets") {
            for (index, element) in rawSnippets.enumerated() {
                let snippet = try question.child(
                    element,
                    path: "\(question.path(of: "codeSnippets"))[\(index)]"
                )
                snippets[try snippet.string("langSlug")] = try snippet.string("code")
            }
        } else if !isPaidOnly {
            throw LeetCodeError.apiChanged(detail: question.path(of: "codeSnippets"))
        }

        var examples: [String] = []
        if let rawExamples = try question.optionalArray("exampleTestcaseList") {
            for (index, element) in rawExamples.enumerated() {
                guard let text = element as? String else {
                    throw LeetCodeError.apiChanged(
                        detail: "\(question.path(of: "exampleTestcaseList"))[\(index)]"
                    )
                }
                examples.append(text)
            }
        }

        return LeetCodeProblemDetail(
            problem: problem,
            content: content,
            codeSnippets: snippets,
            exampleTestCases: examples
        )
    }

    // MARK: - Problem list

    /// Parse the legacy REST catalog into the problems the app knows about.
    ///
    /// The response's own `user_name` is deliberately **ignored**, even though it
    /// is empty exactly when the caller is signed out: login is decided in one
    /// place (`parseUserStatus`), and a second signal that can disagree with the
    /// first is a bug waiting for a slow afternoon.
    public static func parseProblemList(
        _ response: LeetCodeHTTPResponse
    ) throws -> [LeetCodeProblem] {
        let root = try jsonObject(response, context: "problems")
        guard let pairs = try root.optionalArray("stat_status_pairs") else {
            throw LeetCodeError.apiChanged(detail: root.path(of: "stat_status_pairs"))
        }

        var problems: [LeetCodeProblem] = []
        problems.reserveCapacity(pairs.count)
        for (index, element) in pairs.enumerated() {
            let path = "stat_status_pairs[\(index)]"
            let pair = try root.child(element, path: path)
            let stat = try pair.object("stat")
            let difficultyObject = try pair.object("difficulty")
            let level = try difficultyObject.integer("level")
            problems.append(
                LeetCodeProblem(
                    frontendID: try stat.integer("frontend_question_id"),
                    slug: try requiredSlug(
                        fromWireValue: try stat.string("question__title_slug"),
                        path: stat.path(of: "question__title_slug")
                    ),
                    title: try stat.string("question__title"),
                    difficulty: try difficulty(
                        fromRESTLevel: level,
                        path: difficultyObject.path(of: "level")
                    ),
                    isPaidOnly: try pair.bool("paid_only"),
                    status: status(fromRESTValue: try pair.optionalString("status"))
                )
            )
        }
        return problems
    }

    // MARK: - Slugs off the wire

    /// A slug LeetCode sent, checked against the one slug rule before anything
    /// else is allowed to treat it as one.
    ///
    /// **This is the boundary at which a wire string becomes a path component.**
    /// A slug travels from here into `LeetCodeSolutionFile.name(…)` and is
    /// appended to the configured folder, and into `LeetCodeCacheLayout`'s file
    /// names; `appendingPathComponent` does not resolve `..`, so a slug carrying
    /// `/` or `..` would write outside the folder the user set aside. Worse than
    /// the traversal: `performOpen` decides "does this file already exist" by
    /// comparing `lastPathComponent`, which a name containing a separator can
    /// never match — so the **never-overwrite** rule, the one failure in this
    /// integration a user could not undo, would stop holding for exactly the
    /// slugs that escape.
    ///
    /// The lesser half matters too: `LeetCodeSolutionFile.parts(fromFileName:)`
    /// validates with the same rule, so a slug outside `[a-z0-9-]` would name a
    /// file the statement panel could never associate back to its problem.
    /// Checking here is what makes "the app cannot write a name it would then
    /// fail to recognise" structural rather than hopeful.
    ///
    /// `apiChanged` rather than a repair, for this file's usual reason: a slug
    /// LeetCode spells in a way this app cannot use is a schema change, and
    /// silently rewriting it would produce a request for some other problem.
    private static func slug(
        fromWireValue value: String?,
        path: String
    ) throws -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard let slug = LeetCodeProblemInput.normalizedSlug(value) else {
            throw LeetCodeError.apiChanged(detail: "\(path) = \(value)")
        }
        return slug
    }

    /// The same check where the slug is not optional — the catalog's rows, whose
    /// slug *is* the identity the row exists to provide.
    private static func requiredSlug(
        fromWireValue value: String,
        path: String
    ) throws -> String {
        guard let slug = LeetCodeProblemInput.normalizedSlug(value) else {
            throw LeetCodeError.apiChanged(detail: "\(path) = \(value)")
        }
        return slug
    }

    // MARK: - Enumeration mappings

    /// GraphQL's difficulty spelling.
    ///
    /// Matched case-insensitively (decode leniently), but an unrecognised value is
    /// `apiChanged` rather than a default: "every problem is Easy" is precisely
    /// the silent wrongness an unofficial API produces when it grows a fourth
    /// tier, and nobody would ever report it as a bug.
    public static func difficulty(
        fromGraphQLName name: String,
        path: String = "difficulty"
    ) throws -> LeetCodeDifficulty {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "easy": return .easy
        case "medium": return .medium
        case "hard": return .hard
        default: throw LeetCodeError.apiChanged(detail: "\(path) = \(name)")
        }
    }

    /// The REST catalog's numeric spelling of the same three values.
    public static func difficulty(
        fromRESTLevel level: Int,
        path: String = "difficulty.level"
    ) throws -> LeetCodeDifficulty {
        switch level {
        case 1: return .easy
        case 2: return .medium
        case 3: return .hard
        default: throw LeetCodeError.apiChanged(detail: "\(path) = \(level)")
        }
    }

    /// This account's progress on a problem, from the catalog's `status`.
    ///
    /// **The one place in this file that defaults instead of throwing**, and the
    /// exception is deliberate. `status` is per-row, per-account and purely
    /// cosmetic — it decorates a list the user has not seen yet. Treating an
    /// unrecognised value the way `difficulty` is treated would mean one odd row
    /// out of four thousand failing the entire catalog parse, and with the catalog
    /// gone *no problem can be opened at all*. So the failure modes are weighed
    /// rather than the rule applied: a missing badge against a dead feature.
    /// `nil` (which is what LeetCode sends for a problem never touched, and for
    /// every row when signed out) is not an unknown value at all — it is the
    /// documented spelling of `.notStarted`.
    public static func status(fromRESTValue value: String?) -> LeetCodeProblemStatus {
        switch value?.lowercased() {
        case "ac": return .solved
        case "notac": return .attempted
        default: return .notStarted
        }
    }

    // MARK: - Envelope handling

    /// The `data` member of a GraphQL response, after every failure shape the
    /// endpoint can answer with has been ruled out.
    ///
    /// `slug` is threaded through only so a paid-only verdict can name the problem
    /// in the sentence the user reads.
    private static func graphQLData(
        _ response: LeetCodeHTTPResponse,
        context: String,
        slug: String = ""
    ) throws -> JSONObjectReader {
        let root = try jsonObject(response, context: context, slug: slug)

        // A GraphQL endpoint can answer 200 with errors and no data, so the errors
        // array is inspected before the status code is trusted.
        if let errors = try root.optionalArray("errors"), !errors.isEmpty {
            throw classify(graphQLErrors: errors, slug: slug)
        }
        guard let data = try root.optionalObject("data") else {
            throw LeetCodeError.apiChanged(detail: "data")
        }
        return data
    }

    /// Decode a response body to a JSON object, mapping every non-2xx shape this
    /// stack produces onto its own error first.
    ///
    /// The order is not arbitrary. Throttling is decided from the *status and
    /// headers* before the body is looked at, because a rate-limited LeetCode
    /// sometimes answers with an HTML interstitial that no JSON parse survives —
    /// deciding `throttled` from the body alone would report that as `apiChanged`
    /// and send whoever reads the bug report hunting a schema change that never
    /// happened.
    private static func jsonObject(
        _ response: LeetCodeHTTPResponse,
        context: String,
        slug: String = ""
    ) throws -> JSONObjectReader {
        if response.statusCode == 429 {
            throw LeetCodeError.throttled(retryAfter: retryAfter(from: response))
        }

        let parsed = try? JSONSerialization.jsonObject(with: response.body)
        let object = parsed as? [String: Any]

        // Django REST Framework answers both throttling and missing credentials
        // with `{"detail": …}`; the two are told apart by the sentence, which is
        // the only thing that distinguishes them at the HTTP level (both can be a
        // 403 depending on the endpoint's throttle class).
        if let detail = object?["detail"] as? String {
            if isThrottleMessage(detail) {
                throw LeetCodeError.throttled(
                    retryAfter: retryAfter(from: response) ?? seconds(inThrottleMessage: detail)
                )
            }
            if isAuthenticationMessage(detail) {
                throw LeetCodeError.notLoggedIn
            }
        }

        if response.statusCode == 401 {
            throw LeetCodeError.notLoggedIn
        }

        guard let object else {
            // The same reasoning the 429 branch above is written on, for the
            // other status this stack answers with a body no JSON parse
            // survives: a 403 from a WAF or a Cloudflare interstitial is HTML,
            // and reporting it as `apiChanged` would send whoever reads the bug
            // report hunting a schema change instead of a dead session. With a
            // JSON body a 403 is still decided *below*, after the GraphQL
            // `errors` array, because that array is the more specific answer
            // (a premium refusal arrives as one).
            if response.statusCode == 403 {
                throw LeetCodeError.notLoggedIn
            }
            guard response.isSuccess else {
                throw LeetCodeError.apiChanged(
                    detail: "\(context): HTTP \(response.statusCode)"
                )
            }
            throw LeetCodeError.apiChanged(detail: "\(context): response body is not JSON")
        }

        let root = JSONObjectReader(value: object, path: "")
        // A non-2xx that *did* carry a GraphQL errors array is classified by the
        // array — that is where "schema drift" lives, as a 400.
        if !response.isSuccess, let errors = object["errors"] as? [Any], !errors.isEmpty {
            throw classify(graphQLErrors: errors, slug: slug)
        }
        if response.statusCode == 403 {
            throw LeetCodeError.notLoggedIn
        }
        guard response.isSuccess else {
            throw LeetCodeError.apiChanged(detail: "\(context): HTTP \(response.statusCode)")
        }
        return root
    }

    /// Which error a GraphQL `errors` array means.
    ///
    /// Phrase matching, because that is all the endpoint offers: LeetCode's
    /// Graphene layer sends no machine-readable code, so the alternative to
    /// reading the sentence is reporting everything as `apiChanged`. The
    /// **fallback is `apiChanged`**, which keeps that honest — a phrasing this
    /// list does not know produces the loud, self-diagnosing error carrying
    /// LeetCode's own message rather than a confidently wrong verdict.
    private static func classify(graphQLErrors errors: [Any], slug: String) -> LeetCodeError {
        let messages = errors.compactMap { ($0 as? [String: Any])?["message"] as? String }
        let joined = messages.joined(separator: " | ")
        let lowered = joined.lowercased()

        if isThrottleMessage(lowered) {
            return .throttled(retryAfter: seconds(inThrottleMessage: lowered))
        }
        // Premium is checked before authentication: its phrasings ("subscription",
        // "premium") are specific, while the auth list contains "not authorized",
        // which a premium refusal can also say.
        for needle in ["premium", "subscription", "subscriber", "paid only"]
        where lowered.contains(needle) {
            return .paidOnly(slug: slug)
        }
        if isAuthenticationMessage(lowered) {
            return .notLoggedIn
        }
        return .apiChanged(detail: joined.isEmpty ? "errors" : joined)
    }

    private static func isThrottleMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("throttl")
            || lowered.contains("too many requests")
            || lowered.contains("rate limit")
    }

    private static func isAuthenticationMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("authentication")
            || lowered.contains("not authenticated")
            || lowered.contains("not signed in")
            || lowered.contains("please log in")
            || lowered.contains("login required")
            || lowered.contains("not authorized")
            || lowered.contains("unauthorized")
    }

    /// The server's `Retry-After`, in seconds.
    ///
    /// RFC 9110 allows an HTTP-date as well as a delta; only the delta is read,
    /// and a date form answers `nil` — which is not a loss, because `nil` already
    /// has a well-defined meaning here ("throttled, wait unknown") and the message
    /// simply says "in a moment" instead of naming a number.
    private static func retryAfter(from response: LeetCodeHTTPResponse) -> TimeInterval? {
        guard let raw = response.headerValue(forName: "Retry-After") else { return nil }
        guard let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              seconds > 0 else { return nil }
        return seconds
    }

    /// The wait named inside DRF's own sentence ("Expected available in 42
    /// seconds."), for the case where the header was absent.
    ///
    /// **Anchored on the unit, not on "the first number in the string."** The
    /// caller at the GraphQL end passes *every* error message joined together, so
    /// an unanchored scan would read "Rate limit exceeded for user 12345. Try
    /// again in 30 seconds." as a three-and-a-half-hour wait and say so to the
    /// user. Only a digit run immediately followed by the word it is a count of
    /// counts, and anything longer than an hour is refused as well: `nil` already
    /// means "throttled, wait unknown" and renders as "in a moment", which is
    /// strictly better than a confidently wrong number.
    private static func seconds(inThrottleMessage message: String) -> TimeInterval? {
        let lowered = message.lowercased()
        let characters = Array(lowered)
        var index = 0
        while index < characters.count {
            guard characters[index].isNumber else {
                index += 1
                continue
            }
            var end = index
            while end < characters.count, characters[end].isNumber { end += 1 }
            let digits = String(characters[index..<end])
            var unitStart = end
            while unitStart < characters.count, characters[unitStart] == " " { unitStart += 1 }
            let rest = String(characters[unitStart...])
            if rest.hasPrefix("second") || rest.hasPrefix("sec") {
                return plausibleWait(TimeInterval(digits))
            }
            if rest.hasPrefix("minute") || rest.hasPrefix("min") {
                return plausibleWait(TimeInterval(digits).map { $0 * 60 })
            }
            index = end
        }
        return nil
    }

    /// A wait worth naming: positive, and no longer than the hour beyond which
    /// "try again in N seconds" stops being advice a user can act on.
    private static func plausibleWait(_ seconds: TimeInterval?) -> TimeInterval? {
        guard let seconds, seconds > 0, seconds <= 3600 else { return nil }
        return seconds
    }
}

// MARK: - Key-path-naming JSON reader

/// A `[String: Any]` that remembers where it came from, so every failure can name
/// the key path that did not match.
///
/// Foundation-only by necessity — `PisakaCore` links nothing — but the naming is
/// the actual point: `Codable` would give "keyNotFound(CodingKeys(...))" buried in
/// a `DecodingError`, and this layer's whole contract is that the error string the
/// user pastes into a bug report says `data.question.content` and nothing else.
private struct JSONObjectReader {
    let value: [String: Any]
    /// The dotted path of this object itself; empty at the root.
    let path: String

    /// The path of `key` within this object, as the error message spells it.
    func path(of key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    /// A sibling reader for an element pulled out of an array here.
    func child(_ element: Any, path elementPath: String) throws -> JSONObjectReader {
        guard let object = element as? [String: Any] else {
            throw LeetCodeError.apiChanged(detail: elementPath)
        }
        return JSONObjectReader(value: object, path: elementPath)
    }

    func object(_ key: String) throws -> JSONObjectReader {
        guard let object = try optionalObject(key) else {
            throw LeetCodeError.apiChanged(detail: path(of: key))
        }
        return object
    }

    /// The object at `key`, or `nil` when the key is absent **or explicitly
    /// null** — the two are not distinguished, because on this API they mean the
    /// same thing everywhere they are read optionally (`data.question: null` is
    /// "no such problem"; a missing `question` is the same absence).
    func optionalObject(_ key: String) throws -> JSONObjectReader? {
        guard let raw = value[key], !(raw is NSNull) else { return nil }
        guard let object = raw as? [String: Any] else {
            throw LeetCodeError.apiChanged(detail: path(of: key))
        }
        return JSONObjectReader(value: object, path: path(of: key))
    }

    func string(_ key: String) throws -> String {
        guard let string = try optionalString(key) else {
            throw LeetCodeError.apiChanged(detail: path(of: key))
        }
        return string
    }

    func optionalString(_ key: String) throws -> String? {
        guard let raw = value[key], !(raw is NSNull) else { return nil }
        guard let string = raw as? String else {
            throw LeetCodeError.apiChanged(detail: path(of: key))
        }
        return string
    }

    func bool(_ key: String) throws -> Bool {
        guard let bool = try optionalBool(key) else {
            throw LeetCodeError.apiChanged(detail: path(of: key))
        }
        return bool
    }

    func optionalBool(_ key: String) throws -> Bool? {
        guard let raw = value[key], !(raw is NSNull) else { return nil }
        guard let number = raw as? NSNumber else {
            throw LeetCodeError.apiChanged(detail: path(of: key))
        }
        return number.boolValue
    }

    /// An integer that may arrive as a JSON number *or* as a numeric string.
    ///
    /// Not gratuitous leniency: GraphQL spells the very same problem number as the
    /// string `"1"` (`questionFrontendId`) while the REST catalog spells it as the
    /// number `1` (`frontend_question_id`), and both are recorded in the fixtures.
    /// A non-numeric string is still `apiChanged`, naming the value.
    func integer(_ key: String) throws -> Int {
        guard let raw = value[key], !(raw is NSNull) else {
            throw LeetCodeError.apiChanged(detail: path(of: key))
        }
        if let number = raw as? NSNumber, !(raw is NSString) {
            return number.intValue
        }
        if let string = raw as? String, let parsed = Int(string) {
            return parsed
        }
        throw LeetCodeError.apiChanged(detail: "\(path(of: key)) = \(raw)")
    }

    func optionalArray(_ key: String) throws -> [Any]? {
        guard let raw = value[key], !(raw is NSNull) else { return nil }
        guard let array = raw as? [Any] else {
            throw LeetCodeError.apiChanged(detail: path(of: key))
        }
        return array
    }

    init(value: [String: Any], path: String) {
        self.value = value
        self.path = path
    }
}
