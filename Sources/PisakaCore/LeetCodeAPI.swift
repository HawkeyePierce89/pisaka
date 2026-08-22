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

    /// The same page as a **directory** URL, i.e. with the trailing slash.
    ///
    /// Not cosmetic, and not the same value as ``problemURL(slug:)``: it is the
    /// `Referer` the three judge endpoints are sent with, and LeetCode's own
    /// browser sends exactly this spelling. The seeded header comment keeps the
    /// slash-less form because that is the link a human clicks, so the two are
    /// separate functions rather than one with a flag nobody would read.
    public static func problemPageURL(slug: String) -> URL {
        siteURL
            .appendingPathComponent("problems", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
    }

    /// `POST` here to run code against the example test cases.
    ///
    /// The trailing slash is load-bearing: Django's `APPEND_SLASH` answers the
    /// slash-less form with a 301, and a redirected `POST` is re-sent as a `GET`
    /// by every HTTP stack that follows RFC 9110's historical behaviour — which
    /// LeetCode then answers with a 405 that says nothing about the real cause.
    public static func interpretURL(slug: String) -> URL {
        problemPageURL(slug: slug).appendingPathComponent("interpret_solution", isDirectory: true)
    }

    /// `POST` here to submit against LeetCode's full test suite. Same trailing
    /// slash, same reason.
    public static func submitURL(slug: String) -> URL {
        problemPageURL(slug: slug).appendingPathComponent("submit", isDirectory: true)
    }

    /// `GET` here to ask how a run or a submission is getting on.
    ///
    /// One endpoint for both kinds — a run's id is a `runcode_…` string and a
    /// submission's is a number — which is exactly why the kind has to travel
    /// with the parse (`parseJudgeCheck(_:kind:)`): the response shapes differ
    /// and the URL does not say which one to expect.
    public static func checkURL(id: String) -> URL {
        siteURL
            .appendingPathComponent("submissions", isDirectory: true)
            .appendingPathComponent("detail", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("check", isDirectory: true)
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
    /// starter code to seed the file with, the examples Run prefills its input
    /// box from, and the internal id the judge payloads are addressed by.
    ///
    /// `questionId` and `questionFrontendId` are both asked for on purpose: they
    /// are different identifiers that agree on the old problems, and asking for
    /// only one of them would mean guessing the other (see
    /// `LeetCodeProblemDetail.questionID`).
    public static let questionDetailQuery = """
        query questionData($titleSlug: String!) {
          question(titleSlug: $titleSlug) {
            questionId
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
    /// hosts *within* it (`leetcode.com` → `www.leetcode.com`). It is deliberately
    /// **not** ``LeetCodeProblemInput``'s "is this a LeetCode URL" rule, which
    /// also accepts `leetcode.cn` — that is a different operator, and a session
    /// obtained on `.com` has no business being sent there. Scheme is checked too,
    /// so an `https` → `http` downgrade cannot carry the pair in clear text.
    ///
    /// **The containment is one-directional, and that is the whole point.** The
    /// mirror clause — "the original is within the new host" — reads as the same
    /// relaxation and is not: it walks *up* the name, so `leetcode.com` → `com`
    /// satisfies it and the pair goes to whoever answers for the public suffix.
    /// Nothing in this app currently redirects that way (the original request is
    /// always `leetcode.com`, so the only host the clause ever admitted was `com`
    /// itself), but this predicate is the one place the same-origin rule is
    /// written, and a rule that is right only because of its call site is not one.
    public static func redirectMayCarryCredentials(from originalURL: URL, to newURL: URL) -> Bool {
        guard let original = originalURL.host?.lowercased(),
              let new = newURL.host?.lowercased(),
              newURL.scheme?.lowercased() == originalURL.scheme?.lowercased()
        else { return false }
        return new == original || new.hasSuffix("." + original)
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
        commonHeaders(credentials: credentials, referer: siteURL.absoluteString)
    }

    /// The same headers with the `Referer` chosen by the caller.
    ///
    /// The GraphQL and catalog calls send the site root, which is what a browser
    /// sitting on the home page would send. The three judge endpoints send the
    /// **problem page**, because that is where a browser is when it runs or
    /// submits — and LeetCode's CSRF-protected POST views are the ones most
    /// likely to check that the referring page is the one that could plausibly
    /// have made the request. Overloading rather than defaulting the parameter
    /// keeps every existing call site's bytes provably unchanged.
    private static func commonHeaders(
        credentials: LeetCodeCredentials,
        referer: String
    ) -> [String: String] {
        [
            "Accept": "application/json",
            "Cookie": credentials.cookieHeaderValue,
            "Referer": referer,
            "User-Agent": userAgent,
            "x-csrftoken": credentials.csrfToken
        ]
    }

    // MARK: - Judge requests

    /// `interpret_solution` — run `code` against `input`, whatever the user has
    /// typed into the test-case box.
    ///
    /// `questionID` is LeetCode's **internal** id, not the number in the file
    /// name; the two agree on old problems and disagree on everything recent, so
    /// the parameter is spelled the way `LeetCodeProblemDetail.questionID` is and
    /// nothing here accepts an `Int`.
    public static func interpretRequest(
        slug: String,
        questionID: String,
        langSlug: String,
        code: String,
        input: String,
        credentials: LeetCodeCredentials
    ) -> LeetCodeHTTPRequest {
        judgeRequest(
            url: interpretURL(slug: slug),
            slug: slug,
            payload: [
                "data_input": input,
                "lang": langSlug,
                "question_id": questionID,
                "typed_code": code
            ],
            credentials: credentials
        )
    }

    /// `submit` — the same payload **without** `data_input`.
    ///
    /// Omitted rather than sent empty: a submission runs LeetCode's own suite,
    /// and a `data_input` key on this endpoint would be either ignored or, worse,
    /// honoured. The editable box has nothing to do with a submission, and the
    /// byte-exact request test is what keeps that true.
    public static func submitRequest(
        slug: String,
        questionID: String,
        langSlug: String,
        code: String,
        credentials: LeetCodeCredentials
    ) -> LeetCodeHTTPRequest {
        judgeRequest(
            url: submitURL(slug: slug),
            slug: slug,
            payload: [
                "lang": langSlug,
                "question_id": questionID,
                "typed_code": code
            ],
            credentials: credentials
        )
    }

    /// One poll of `submissions/detail/<id>/check/`.
    ///
    /// `slug` is carried only so the `Referer` can name the problem page the
    /// poll is nominally happening on — the URL itself does not mention the
    /// problem at all.
    public static func checkRequest(
        id: String,
        slug: String,
        credentials: LeetCodeCredentials
    ) -> LeetCodeHTTPRequest {
        LeetCodeHTTPRequest(
            method: "GET",
            url: checkURL(id: id),
            headers: commonHeaders(
                credentials: credentials,
                referer: problemPageURL(slug: slug).absoluteString
            )
        )
    }

    /// The shared body of the two judge POSTs — plain JSON, not GraphQL, and
    /// `.sortedKeys` for the same byte-reproducibility reason.
    private static func judgeRequest(
        url: URL,
        slug: String,
        payload: [String: String],
        credentials: LeetCodeCredentials
    ) -> LeetCodeHTTPRequest {
        let body = (try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
        var headers = commonHeaders(
            credentials: credentials,
            referer: problemPageURL(slug: slug).absoluteString
        )
        headers["Content-Type"] = "application/json"
        return LeetCodeHTTPRequest(method: "POST", url: url, headers: headers, body: body)
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
    /// question whose honest answer can be "nobody", and both callers of it —
    /// `LeetCodeModel.signIn(with:)` and `refreshUserStatus()` — need to hear that
    /// as a value, because what they do with it (sign out, or just flip the
    /// published state) is a decision this parser does not get to make.
    /// `throwIfSignedOut(_:)` below is the same verdict as the error the rest of
    /// the app speaks, for a caller that only needs the refusal.
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
        // Strict, and strict for every problem including a locked one: the judge
        // payloads carry no other spelling of *which* problem is being answered,
        // so a detail without it is a detail Run and Submit cannot use. Substituting
        // `questionFrontendId` would be the one repair that looks right on Two Sum
        // and judges some other problem on anything recent.
        let questionID = try question.opaqueIdentifier("questionId")
        let slug = try slug(
            fromWireValue: try question.optionalString("titleSlug"),
            path: question.path(of: "titleSlug")
        ) ?? requestedSlug
        let problem = LeetCodeProblem(
            frontendID: try frontendID(
                try question.integer("questionFrontendId"),
                path: question.path(of: "questionFrontendId")
            ),
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
            return LeetCodeProblemDetail(
                problem: problem,
                questionID: questionID,
                content: "",
                codeSnippets: [:]
            )
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

        // Absent or `null` is `apiChanged`, exactly like `codeSnippets` above and
        // for the same reason: an *empty* list is a legitimate answer, so folding
        // a missing key into `[]` would make "LeetCode renamed this field" and
        // "this problem ships no example input" the same value, with nothing left
        // to tell them apart. Nothing reads these yet — which is precisely why the
        // drift would be found late, by Run submitting an empty input.
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
        } else if !isPaidOnly {
            throw LeetCodeError.apiChanged(detail: question.path(of: "exampleTestcaseList"))
        }

        return LeetCodeProblemDetail(
            problem: problem,
            questionID: questionID,
            content: content,
            codeSnippets: snippets,
            exampleTestCases: examples
        )
    }

    // MARK: - Judge responses

    /// The id `interpret_solution` answered with — a `runcode_…` string that is
    /// the only handle on the run just started.
    ///
    /// Strict, and through `opaqueIdentifier` for the same reason `questionId` is:
    /// the value is never interpreted, only put back into the check URL, so its
    /// *form* is not a fact worth failing on — but its absence is, because a
    /// response without it means there is nothing to poll and the run silently
    /// never happened.
    ///
    /// LeetCode also answers this endpoint with `interpret_expected_id`, which is
    /// deliberately ignored: the expected output arrives inside the same check
    /// response the run's own id produces, so polling a second id would double
    /// the request rate for data already in hand.
    public static func parseInterpretID(_ response: LeetCodeHTTPResponse) throws -> String {
        let root = try jsonObject(response, context: "interpret_solution")
        return try judgeID(
            try root.opaqueIdentifier("interpret_id"),
            path: root.path(of: "interpret_id")
        )
    }

    /// The id `submit` answered with.
    ///
    /// Arrives as a JSON **number** where the run's id is a string, which is
    /// precisely what `opaqueIdentifier` exists to absorb: it is carried as the
    /// `String` the check URL needs either way, and nothing here does arithmetic
    /// with a submission id.
    public static func parseSubmissionID(_ response: LeetCodeHTTPResponse) throws -> String {
        let root = try jsonObject(response, context: "submit")
        return try judgeID(
            try root.opaqueIdentifier("submission_id"),
            path: root.path(of: "submission_id")
        )
    }

    /// The one shape rule for a judge id, applied where it leaves the wire.
    ///
    /// **Both ids become path components of the check URL**, and
    /// `appendingPathComponent` percent-encodes almost everything *except* the two
    /// spellings that matter here: it passes `/` and `..` through verbatim. An id
    /// of `../../logout`, or one carrying a slash, would therefore send this app's
    /// session cookie to a leetcode.com URL nothing in this file chose — the same
    /// hazard `normalizedSlug(_:)` exists to close for the other wire value that
    /// becomes a path component (L4), closed the same way rather than left to the
    /// URL loader's discretion.
    ///
    /// LeetCode spells a run's id as `runcode_1770000000.1234567_AbCdEfGhIj` and a
    /// submission's as a decimal number, so unreserved ASCII is not a guess about
    /// the format; it is what both are. Anything else is `apiChanged` naming the
    /// key, which is this file's standing answer to "the wire stopped looking like
    /// the wire".
    private static func judgeID(_ raw: String, path: String) throws -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard raw != ".", raw != "..", raw.allSatisfy({ allowed.contains($0) }) else {
            throw LeetCodeError.apiChanged(detail: "\(path) = \(raw)")
        }
        return raw
    }

    /// Parse one poll of the check endpoint, under the kind that started it.
    ///
    /// **Strict where the verdict lives, lenient around it.** `state` and
    /// `status_code` decide what the user is told, so an unrecognised value of
    /// either is `apiChanged` naming it — a tenth `status_code` rendered as some
    /// default would be a confidently wrong verdict on somebody's submission, and
    /// the whole point of this file is that such a thing must be loud. Every
    /// other member is a *display* field, read through the `display…` readers
    /// that never throw: LeetCode omits percentiles on a rejected submit, omits
    /// `code_answer` on a compile error, spells runtime as a string, and has
    /// changed which of those it sends more than once. Failing a correct verdict
    /// because a cosmetic key moved would be the same mistake the catalog's
    /// `status` leniency already exists to prevent.
    ///
    /// An absent optional stays `nil`. Nothing here substitutes a zero: a `0 ms`
    /// invented to fill a gap reads as a measurement.
    public static func parseJudgeCheck(
        _ response: LeetCodeHTTPResponse,
        kind: LeetCodeJudgeKind
    ) throws -> LeetCodeJudgeCheck {
        let root = try jsonObject(response, context: "check")
        let rawState = try root.string("state")
        guard let state = judgeState(fromWireValue: rawState) else {
            throw LeetCodeError.apiChanged(detail: "\(root.path(of: "state")) = \(rawState)")
        }

        switch state {
        case .pending: return .pending
        case .started: return .started
        case .failure: return .judgeFailed
        case .success:
            let verdict = try self.verdict(
                fromStatusCode: try root.integer("status_code"),
                path: root.path(of: "status_code")
            )
            switch kind {
            case .run: return .finishedRun(runResult(verdict: verdict, from: root))
            case .submit: return .finishedSubmit(submitResult(verdict: verdict, from: root))
            }
        }
    }

    /// The `state` strings, matched case-insensitively after trimming (decode
    /// leniently as to *form*), and `nil` for anything not in the table — which
    /// the caller turns into `apiChanged`.
    public static func judgeState(fromWireValue value: String) -> LeetCodeJudgeState? {
        LeetCodeJudgeState(
            rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        )
    }

    /// The numeric `status_code` table.
    ///
    /// No default, exactly like `difficulty(fromGraphQLName:)` and for a sharper
    /// version of the same reason: "every problem is Easy" is silent wrongness in
    /// a list, while a wrong verdict is silent wrongness about the thing the user
    /// just asked. A code this app does not know is reported as the schema change
    /// it is, naming the number.
    public static func verdict(
        fromStatusCode code: Int,
        path: String = "status_code"
    ) throws -> LeetCodeVerdict {
        guard let verdict = LeetCodeVerdict(rawValue: code) else {
            throw LeetCodeError.apiChanged(detail: "\(path) = \(code)")
        }
        return verdict
    }

    /// The run half of a finished check. Every field below is a display field;
    /// see `parseJudgeCheck` for why none of them throws.
    private static func runResult(
        verdict: LeetCodeVerdict,
        from root: JSONObjectReader
    ) -> LeetCodeRunResult {
        LeetCodeRunResult(
            verdict: verdict,
            // Read separately from `status_code` on purpose: on a run, code 10
            // means "it executed", and this is the only member that says whether
            // the output was right. Conflating them is the mistake this type's
            // documentation exists to prevent.
            matchedExpected: root.displayBool("correct_answer"),
            // LeetCode echoes the submitted input back on some shapes and not on
            // others; the flow model already knows what it sent, so an absence
            // costs nothing and is not worth failing on. Carried as the one block
            // it is on the wire — see `LeetCodeRunResult.input` for why splitting
            // it per case is wrong.
            input: root.displayString("test_case"),
            answers: root.displayStrings("code_answer"),
            expectedAnswers: root.displayStrings("expected_code_answer"),
            stdOutputs: root.displayStrings("std_output_list"),
            runtime: root.displayString("status_runtime"),
            memory: root.displayString("status_memory"),
            errorText: root.judgeErrorText()
        )
    }

    /// The submit half of a finished check.
    private static func submitResult(
        verdict: LeetCodeVerdict,
        from root: JSONObjectReader
    ) -> LeetCodeSubmitResult {
        LeetCodeSubmitResult(
            verdict: verdict,
            runtime: root.displayString("status_runtime"),
            runtimePercentile: root.displayNumber("runtime_percentile"),
            memory: root.displayString("status_memory"),
            memoryPercentile: root.displayNumber("memory_percentile"),
            totalCorrect: root.displayInteger("total_correct"),
            totalTestcases: root.displayInteger("total_testcases"),
            lastTestcaseInput: root.displayString("last_testcase"),
            codeOutput: root.displayString("code_output"),
            expectedOutput: root.displayString("expected_output"),
            stdOutput: root.displayString("std_output"),
            errorText: root.judgeErrorText()
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
                    frontendID: try frontendID(
                        try stat.integer("frontend_question_id"),
                        path: stat.path(of: "frontend_question_id")
                    ),
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
                    // Read without `optionalString`, which throws `apiChanged` on
                    // anything present that is not a string — that would have put
                    // the whole catalog back at the mercy of one row's `status`,
                    // which is the exact outcome `status(fromRESTValue:)` is
                    // documented to prevent. LeetCode already spells `difficulty`
                    // two different ways across its two endpoints; a `status` that
                    // arrives as a number one day must cost a badge, not the
                    // ability to open any problem at all.
                    status: status(fromRESTValue: pair.value["status"] as? String)
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

    /// A problem number as it has to be for the naming round trip to close.
    ///
    /// The number is the *other* half of a solution file's name, and
    /// `LeetCodeSolutionFile.parts(fromFileName:)` reads back only a positive one
    /// — so an id of `0` or less would compose a name (`0000-two-sum.swift`,
    /// `00-5-two-sum.swift`) that this app could never associate with a problem
    /// again: the statement panel would stay empty for that file forever, with
    /// nothing on screen to say why.
    ///
    /// Same rule as `requiredSlug(fromWireValue:path:)`, for the same reason —
    /// **the app must not write a name it would then fail to recognise** — and
    /// guarding only the slug half left the number half as the one door into name
    /// composition that shrugged.
    private static func frontendID(_ value: Int, path: String) throws -> Int {
        guard value > 0 else {
            throw LeetCodeError.apiChanged(detail: "\(path) = \(value)")
        }
        return value
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
    ///
    /// **Through `plausibleWait` like every other wait in this file**, and for a
    /// stronger reason than the message reading oddly: `TimeInterval(_: String)`
    /// accepts `inf`, `nan` and `1e400`, all of which are `> 0` and none of which
    /// survive the `Int(_:)` the message builder does with them. A header is the
    /// one wait that comes straight off the wire, so the value a CDN or a WAF in
    /// front of LeetCode can put here is entirely outside this app's control.
    private static func retryAfter(from response: LeetCodeHTTPResponse) -> TimeInterval? {
        guard let raw = response.headerValue(forName: "Retry-After") else { return nil }
        return plausibleWait(TimeInterval(raw.trimmingCharacters(in: .whitespaces)))
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

    /// An identifier this app never interprets and only ever sends back, carried
    /// as the `String` a request payload puts on the wire.
    ///
    /// Lenient about the *form* for the same reason `integer(_:)` is — LeetCode
    /// already spells one id as the string `"1"` and the same number as the JSON
    /// number `1` on its other endpoint, so which of the two `questionId` arrives
    /// as is not a fact worth failing on — and strict about there being a value at
    /// all: absent, null, an empty string or a non-scalar is `apiChanged` naming
    /// the key path.
    ///
    /// A non-numeric string is deliberately *accepted*. The value is opaque; this
    /// layer's only requirement is that it round-trips into a payload verbatim,
    /// and demanding digits would fail a perfectly usable id the day LeetCode
    /// changes what its keys look like.
    func opaqueIdentifier(_ key: String) throws -> String {
        guard let raw = value[key], !(raw is NSNull) else {
            throw LeetCodeError.apiChanged(detail: path(of: key))
        }
        if let string = raw as? String {
            guard !string.isEmpty else {
                throw LeetCodeError.apiChanged(detail: "\(path(of: key)) = \(raw)")
            }
            return string
        }
        if let number = raw as? NSNumber {
            return String(number.intValue)
        }
        throw LeetCodeError.apiChanged(detail: "\(path(of: key)) = \(raw)")
    }

    // MARK: Display fields

    // The readers below are the judge's deliberate leniency, and they are grouped
    // here so the asymmetry is visible: **none of them throws.** They read the
    // decorations around a verdict — a runtime string, a percentile, the printed
    // output — on an endpoint that omits half of them depending on the outcome
    // and has re-spelled several of them over the years. The verdict itself
    // (`state`, `status_code`) goes through the strict readers above, so a
    // schema change where it matters is still loud; a schema change in a
    // decoration costs that decoration and nothing else. The reasoning is the
    // catalog's `status(fromRESTValue:)` reasoning, applied where the same
    // trade-off appears: a missing detail line against no verdict at all.

    /// A string for display, or `nil`.
    ///
    /// Empty and whitespace-only fold into `nil` because LeetCode spells "no
    /// value" as `""` about as often as it omits the key (`last_testcase` on an
    /// Accepted submission is `""`), and a view has nothing to do with the
    /// difference. A number is rendered rather than refused — `display_runtime`
    /// has arrived both ways.
    func displayString(_ key: String) -> String? {
        guard let raw = value[key], !(raw is NSNull) else { return nil }
        let text: String
        if let string = raw as? String {
            text = string
        } else if let number = raw as? NSNumber {
            text = number.stringValue
        } else {
            return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// A list of strings for display; absent, null or anything not an array is
    /// `[]`.
    ///
    /// Every element **keeps its position**, which is the whole point: these
    /// arrays are read by index against each other and against the case count, so
    /// an element dropped for being an unexpected shape would silently shift every
    /// later case's output under the wrong heading. A `null` or an object LeetCode
    /// starts sending therefore becomes an empty string — an absence the surface
    /// already knows how to render as nothing — rather than a missing slot.
    func displayStrings(_ key: String) -> [String] {
        guard let array = value[key] as? [Any] else { return [] }
        return array.map { element in
            if let string = element as? String { return string }
            if let number = element as? NSNumber { return number.stringValue }
            return ""
        }
    }

    /// A number for display (a percentile), or `nil`.
    func displayNumber(_ key: String) -> Double? {
        guard let number = value[key] as? NSNumber, !(value[key] is NSString) else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// A count for display, or `nil` — never a substituted zero, because "0 of
    /// 63 passed" and "the judge never got that far" are different things to say.
    func displayInteger(_ key: String) -> Int? {
        if let number = value[key] as? NSNumber, !(value[key] is NSString) {
            return number.intValue
        }
        if let string = value[key] as? String { return Int(string) }
        return nil
    }

    /// A boolean for display, or `nil`.
    func displayBool(_ key: String) -> Bool? {
        guard let number = value[key] as? NSNumber else { return nil }
        return number.boolValue
    }

    /// The compile or runtime error, in the fullest form this response carries.
    ///
    /// The order is the point. LeetCode sends both a one-line summary and a full
    /// text for each, and the full one is the entire reason somebody would rather
    /// read the verdict here than in the browser — a compiler diagnostic cut to
    /// its first line is not a diagnosis. Compile is preferred over runtime
    /// because a response carrying both compiled nothing.
    func judgeErrorText() -> String? {
        for key in ["full_compile_error", "compile_error", "full_runtime_error", "runtime_error"] {
            if let text = displayString(key) { return text }
        }
        return nil
    }

    func optionalArray(_ key: String) throws -> [Any]? {
        guard let raw = value[key], !(raw is NSNull) else { return nil }
        guard let array = raw as? [Any] else {
            throw LeetCodeError.apiChanged(detail: path(of: key))
        }
        return array
    }
}
