import XCTest
@testable import PisakaCore

/// The one schema file, driven from the responses LeetCode actually sent.
///
/// Two halves, matching the two halves of `LeetCodeAPI`:
///
/// - **Requests** are asserted byte for byte — method, URL, every header, and the
///   serialised body — because the whole reason Core composes them itself is that
///   nothing else in the app is in a position to notice when a header goes
///   missing. A `Cookie` that lost its `csrftoken`, or an absent `Referer`, is a
///   403 at runtime and nothing at compile time.
/// - **Responses** are parsed from the recorded fixtures in `Fixtures/leetcode/`
///   (provenance and the authored/verbatim split in that directory's README), so
///   every shape assertion here is pinned against what the live endpoints
///   answered on the day the integration was written, not against a remembered
///   schema.
///
/// The violation fixtures matter as much as the good ones: with an unofficial API
/// the failure that has to be *loud* is the one where LeetCode changed something,
/// and the assertions below are about `apiChanged` naming the right key path — a
/// parser that quietly returned an empty catalog would pass every happy-path test
/// in this file.
final class LeetCodeAPITests: XCTestCase {

    // MARK: - Fixtures

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private static let fixtures = repositoryRoot
        .appendingPathComponent("Tests/PisakaCoreTests/Fixtures/leetcode")

    /// A 200 carrying the named fixture, which is how every recorded response
    /// except the schema-drift one arrived.
    private func response(
        _ name: String,
        statusCode: Int = 200,
        headers: [String: String] = [:]
    ) throws -> LeetCodeHTTPResponse {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
        return LeetCodeHTTPResponse(statusCode: statusCode, headers: headers, body: data)
    }

    private let credentials = LeetCodeCredentials(
        session: "session-value",
        csrfToken: "csrf-value"
    )

    /// Run `body` and assert it threw exactly `expected`.
    private func assertThrows(
        _ expected: LeetCodeError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            XCTFail("expected \(expected), returned normally", file: file, line: line)
        } catch let error as LeetCodeError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), threw \(error)", file: file, line: line)
        }
    }

    /// Run `body` and assert it threw `apiChanged` whose detail *contains*
    /// `detail`. Containment rather than equality because several details carry
    /// the offending value alongside the key path, and the assertion that matters
    /// is that the key path is named at all.
    private func assertAPIChanged(
        containing detail: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            XCTFail("expected apiChanged(\(detail)), returned normally", file: file, line: line)
        } catch let LeetCodeError.apiChanged(reported) {
            XCTAssertTrue(
                reported.contains(detail),
                "apiChanged detail “\(reported)” does not name “\(detail)”",
                file: file,
                line: line
            )
        } catch {
            XCTFail("expected apiChanged(\(detail)), threw \(error)", file: file, line: line)
        }
    }

    // MARK: - Requests

    /// Every header on every call, spelled out. `csrftoken` appearing *twice* —
    /// once in `Cookie` and once as `x-csrftoken` — is not redundancy: Django
    /// compares the two and rejects the request when either is missing.
    func testEveryRequestCarriesTheSessionAndTheCSRFTokenTwice() {
        let expected = [
            "Accept": "application/json",
            "Cookie": "LEETCODE_SESSION=session-value; csrftoken=csrf-value",
            "Referer": "https://leetcode.com/",
            "User-Agent": LeetCodeAPI.userAgent,
            "x-csrftoken": "csrf-value"
        ]

        var post = expected
        post["Content-Type"] = "application/json"

        XCTAssertEqual(LeetCodeAPI.userStatusRequest(credentials: credentials).headers, post)
        XCTAssertEqual(
            LeetCodeAPI.questionDetailRequest(slug: "two-sum", credentials: credentials).headers,
            post
        )
        // The REST catalog is a GET: no body, so no `Content-Type`.
        XCTAssertEqual(LeetCodeAPI.problemListRequest(credentials: credentials).headers, expected)
    }

    func testUserStatusRequestIsExact() {
        let request = LeetCodeAPI.userStatusRequest(credentials: credentials)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://leetcode.com/graphql")
        XCTAssertEqual(
            request.body.flatMap { String(data: $0, encoding: .utf8) },
            #"{"operationName":"globalData","query":"query globalData {\n  userStatus {\n    username\n    isSignedIn\n    isPremium\n  }\n}","variables":{}}"#
        )
    }

    func testQuestionDetailRequestIsExact() {
        let request = LeetCodeAPI.questionDetailRequest(
            slug: "two-sum",
            credentials: credentials
        )
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://leetcode.com/graphql")
        XCTAssertEqual(
            request.body.flatMap { String(data: $0, encoding: .utf8) },
            #"{"operationName":"questionData","query":"query questionData($titleSlug: String!) {\n  question(titleSlug: $titleSlug) {\n    questionFrontendId\n    title\n    titleSlug\n    content\n    difficulty\n    isPaidOnly\n    exampleTestcaseList\n    codeSnippets {\n      lang\n      langSlug\n      code\n    }\n  }\n}","variables":{"titleSlug":"two-sum"}}"#
        )
    }

    func testProblemListRequestIsExact() {
        let request = LeetCodeAPI.problemListRequest(credentials: credentials)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, "https://leetcode.com/api/problems/all/")
        XCTAssertNil(request.body)
    }

    /// The body must be byte-reproducible across runs: `JSONSerialization` orders
    /// a dictionary by its hash table unless told otherwise, so without
    /// `.sortedKeys` the assertions above would pass or fail depending on the
    /// process. Two builds of the same request settle it.
    func testRequestBodiesAreDeterministic() {
        let first = LeetCodeAPI.questionDetailRequest(slug: "a", credentials: credentials).body
        let second = LeetCodeAPI.questionDetailRequest(slug: "a", credentials: credentials).body
        XCTAssertEqual(first, second)
        XCTAssertNotNil(first)
    }

    func testProblemURLIsTheHumanFacingOne() {
        XCTAssertEqual(
            LeetCodeAPI.problemURL(slug: "two-sum").absoluteString,
            "https://leetcode.com/problems/two-sum"
        )
    }

    // MARK: - Redirects

    /// The session travels as a manually set header rather than in a cookie jar,
    /// and `URLSession` re-sends those verbatim to whatever host a 30x names — so
    /// the same-origin rule a jar would have applied is written here instead. The
    /// names are the ones `commonHeaders` actually sends.
    func testTheCredentialHeadersAreTheOnesEveryRequestCarries() {
        let headers = LeetCodeAPI.problemListRequest(credentials: credentials).headers
        for name in LeetCodeAPI.credentialHeaderNames {
            XCTAssertNotNil(headers[name], name)
        }
        XCTAssertEqual(LeetCodeAPI.credentialHeaderNames, ["Cookie", "x-csrftoken"])
    }

    func testTheSessionFollowsARedirectOnlyWithinTheSameHost() {
        let origin = URL(string: "https://leetcode.com/graphql")!
        let carried = [
            "https://leetcode.com/accounts/login/",
            "https://leetcode.com/graphql?next=1",
            "https://www.leetcode.com/graphql"
        ]
        for target in carried {
            XCTAssertTrue(
                LeetCodeAPI.redirectMayCarryCredentials(
                    from: origin,
                    to: URL(string: target)!
                ),
                target
            )
        }

        let stripped = [
            // Another operator entirely, however LeetCode-shaped the name.
            "https://leetcode.cn/graphql",
            "https://leetcode.com.evil.example/graphql",
            "https://evil.example/graphql",
            // Containment runs one way only. Walking *up* the name reads like
            // the same relaxation and hands the session to whoever answers for
            // the public suffix.
            "https://com/graphql",
            // A scheme downgrade would put the pair on the wire in clear text.
            "http://leetcode.com/graphql"
        ]
        for target in stripped {
            XCTAssertFalse(
                LeetCodeAPI.redirectMayCarryCredentials(
                    from: origin,
                    to: URL(string: target)!
                ),
                target
            )
        }
    }

    // MARK: - User status

    func testSignedOutUserStatusIsAValueNotAnError() throws {
        let status = try LeetCodeAPI.parseUserStatus(response("user-status-signed-out.json"))
        XCTAssertFalse(status.isSignedIn)
        // The wire says `""`; an empty username is nobody, not a user named "".
        XCTAssertNil(status.username)
        // `isPremium` arrives as an explicit null for anonymous callers.
        XCTAssertNil(status.isPremium)
        // …but every other operation turns that verdict into `notLoggedIn`.
        assertThrows(.notLoggedIn) { try LeetCodeAPI.throwIfSignedOut(status) }
    }

    func testSignedInUserStatusCarriesTheUsername() throws {
        let status = try LeetCodeAPI.parseUserStatus(response("user-status-signed-in.json"))
        XCTAssertTrue(status.isSignedIn)
        XCTAssertEqual(status.username, "pisaka_tester")
        XCTAssertEqual(status.isPremium, false)
        XCTAssertNoThrow(try LeetCodeAPI.throwIfSignedOut(status))
    }

    func testUserStatusWithoutADataMemberIsAPIChanged() throws {
        let missing = try response("invalid-no-data.json")
        assertAPIChanged(containing: "data") { _ = try LeetCodeAPI.parseUserStatus(missing) }

        let null = try response("invalid-null-data.json")
        assertAPIChanged(containing: "data") { _ = try LeetCodeAPI.parseUserStatus(null) }
    }

    // MARK: - Question detail

    func testQuestionDetailParsesTheRecordedTwoSum() throws {
        let detail = try XCTUnwrap(
            try LeetCodeAPI.parseQuestionDetail(
                response("question-detail.json"),
                requestedSlug: "two-sum"
            )
        )

        XCTAssertEqual(detail.frontendID, 1)
        XCTAssertEqual(detail.slug, "two-sum")
        XCTAssertEqual(detail.title, "Two Sum")
        XCTAssertEqual(detail.difficulty, .easy)
        XCTAssertFalse(detail.isPaidOnly)

        // The statement is LeetCode's own fragment, kept verbatim for the panel.
        XCTAssertTrue(detail.content.hasPrefix("<p>You are given an array of integers"))

        // Snippets are keyed by LeetCode's language slug, which is what the
        // solution-file layer and the picker both speak.
        // Spelled with explicit escapes rather than as a multi-line literal: the
        // recorded snippet's body line is eight spaces of trailing whitespace,
        // which an editor, a linter or a source-formatting pass would silently
        // strip out of a literal — and then this assertion would be testing
        // something LeetCode never sent.
        XCTAssertEqual(
            detail.snippet(forLanguageSlug: "swift"),
            "class Solution {\n"
                + "    func twoSum(_ nums: [Int], _ target: Int) -> [Int] {\n"
                + "        \n"
                + "    }\n"
                + "}"
        )
        XCTAssertNotNil(detail.snippet(forLanguageSlug: "python3"))
        XCTAssertNotNil(detail.snippet(forLanguageSlug: "rust"))
        XCTAssertNil(detail.snippet(forLanguageSlug: "no-such-language"))

        XCTAssertEqual(detail.exampleTestCases, ["[2,7,11,15]\n9", "[3,2,4]\n6", "[3,3]\n6"])
    }

    /// A premium problem answers with the flag set and *null* `content` and
    /// `codeSnippets`. Parsing must survive that — the refusal is the model's job,
    /// one layer up, where a file was about to be written.
    func testPaidOnlyDetailKeepsTheFlagInsteadOfFailingToParse() throws {
        let detail = try XCTUnwrap(
            try LeetCodeAPI.parseQuestionDetail(
                response("question-detail-paid-only.json"),
                requestedSlug: "two-sum-iii-data-structure-design"
            )
        )
        XCTAssertTrue(detail.isPaidOnly)
        XCTAssertEqual(detail.frontendID, 170)
        XCTAssertEqual(detail.difficulty, .easy)
        XCTAssertEqual(detail.content, "")
        XCTAssertEqual(detail.codeSnippets, [:])
    }

    /// `{"data":{"question":null}}` is LeetCode saying "no such slug", with HTTP
    /// 200. Reporting that as `apiChanged` would tell somebody who mistyped a slug
    /// that the API had changed.
    func testUnknownSlugIsNilRatherThanAnError() throws {
        let detail = try LeetCodeAPI.parseQuestionDetail(
            response("question-detail-unknown-slug.json"),
            requestedSlug: "no-such-problem-xyzzy"
        )
        XCTAssertNil(detail)
    }

    func testMissingContentOnAFreeProblemIsAPIChanged() throws {
        let broken = try response("question-detail-missing-content.json")
        assertAPIChanged(containing: "data.question.content") {
            _ = try LeetCodeAPI.parseQuestionDetail(broken, requestedSlug: "two-sum")
        }
    }

    func testUnknownDifficultyNamesTheOffendingValue() throws {
        let broken = try response("question-detail-unknown-difficulty.json")
        assertAPIChanged(containing: "Fiendish") {
            _ = try LeetCodeAPI.parseQuestionDetail(broken, requestedSlug: "two-sum")
        }
        assertAPIChanged(containing: "data.question.difficulty") {
            _ = try LeetCodeAPI.parseQuestionDetail(broken, requestedSlug: "two-sum")
        }
    }

    func testANonNumericProblemNumberIsAPIChanged() throws {
        let broken = try response("question-detail-unnumbered.json")
        assertAPIChanged(containing: "data.question.questionFrontendId") {
            _ = try LeetCodeAPI.parseQuestionDetail(broken, requestedSlug: "two-sum")
        }
    }

    /// The recorded 400 LeetCode answers when the query asks for a field the
    /// schema no longer has — the exact failure the whole `apiChanged` design
    /// exists for. Its detail must carry LeetCode's own sentence, since that is
    /// what names the field to fix.
    func testSchemaDriftSurfacesLeetCodesOwnMessage() throws {
        let drift = try response("errors-schema-drift.json", statusCode: 400)
        assertAPIChanged(containing: "renamedFieldSinceThisAppShipped") {
            _ = try LeetCodeAPI.parseQuestionDetail(drift, requestedSlug: "two-sum")
        }
    }

    func testAuthenticationErrorArrayIsNotLoggedIn() throws {
        let unauthenticated = try response("errors-not-authenticated.json")
        assertThrows(.notLoggedIn) {
            _ = try LeetCodeAPI.parseQuestionDetail(unauthenticated, requestedSlug: "two-sum")
        }
    }

    func testPremiumErrorArrayIsPaidOnlyAndNamesTheSlug() throws {
        let premium = try response("errors-premium.json")
        assertThrows(.paidOnly(slug: "lru-cache")) {
            _ = try LeetCodeAPI.parseQuestionDetail(premium, requestedSlug: "lru-cache")
        }
    }

    // MARK: - Problem list

    func testProblemListParsesTheRecordedCatalog() throws {
        let problems = try LeetCodeAPI.parseProblemList(response("problem-list.json"))
        XCTAssertEqual(problems.count, 12)

        let first = try XCTUnwrap(problems.first)
        XCTAssertEqual(first.frontendID, 1)
        XCTAssertEqual(first.slug, "two-sum")
        XCTAssertEqual(first.title, "Two Sum")
        XCTAssertEqual(first.difficulty, .easy)
        XCTAssertFalse(first.isPaidOnly)
        XCTAssertEqual(first.status, .solved)

        XCTAssertEqual(problems[1].status, .attempted)
        // Anonymous rows report `status: null`, which is `.notStarted` — the
        // documented spelling, not an unknown value.
        XCTAssertEqual(problems[2].status, .notStarted)

        // All three levels, and the one premium row.
        XCTAssertEqual(problems.map(\.difficulty).filter { $0 == .easy }.count, 5)
        XCTAssertEqual(problems.map(\.difficulty).filter { $0 == .medium }.count, 3)
        XCTAssertEqual(problems.map(\.difficulty).filter { $0 == .hard }.count, 4)

        let premium = try XCTUnwrap(problems.first { $0.isPaidOnly })
        XCTAssertEqual(premium.frontendID, 170)
        XCTAssertEqual(premium.slug, "two-sum-iii-data-structure-design")

        // The order is LeetCode's own; nothing here sorts.
        XCTAssertEqual(problems.map(\.frontendID), [1, 2, 4, 23, 42, 121, 146, 170, 200, 297, 1071, 2000])
    }

    func testProblemListWithoutItsArrayIsAPIChanged() throws {
        let broken = try response("problem-list-missing-pairs.json")
        assertAPIChanged(containing: "stat_status_pairs") {
            _ = try LeetCodeAPI.parseProblemList(broken)
        }
    }

    /// The key path names the *row* as well as the key — with four thousand rows,
    /// "a slug is missing" without an index is not a diagnosis.
    func testMissingSlugNamesTheRow() throws {
        let broken = try response("problem-list-missing-slug.json")
        assertAPIChanged(containing: "stat_status_pairs[1].stat.question__title_slug") {
            _ = try LeetCodeAPI.parseProblemList(broken)
        }
    }

    func testUnknownDifficultyLevelIsAPIChanged() throws {
        let broken = try response("problem-list-unknown-level.json")
        assertAPIChanged(containing: "stat_status_pairs[2].difficulty.level = 7") {
            _ = try LeetCodeAPI.parseProblemList(broken)
        }
    }

    /// The one deliberate leniency in the file, pinned so it cannot be "tidied" up
    /// into strictness later: `status` is cosmetic and per-row, and failing the
    /// whole catalog over one odd value would mean no problem can be opened at
    /// all. Difficulty, which the same response carries, stays strict — the test
    /// above proves the asymmetry is intentional.
    func testUnknownStatusDegradesInsteadOfFailingTheWholeCatalog() throws {
        let odd = try response("problem-list-unknown-status.json")
        let problems = try LeetCodeAPI.parseProblemList(odd)
        XCTAssertEqual(problems.count, 12)
        XCTAssertEqual(problems[0].status, .notStarted)
    }

    // MARK: - HTTP-level failures

    func testTooManyRequestsIsThrottledWithTheServersWait() throws {
        let throttled = try response(
            "throttled.json",
            statusCode: 429,
            headers: ["Retry-After": "17"]
        )
        assertThrows(.throttled(retryAfter: 17)) {
            _ = try LeetCodeAPI.parseUserStatus(throttled)
        }
    }

    /// Header names are case-insensitive on the wire and stacks normalise them
    /// differently; the one header this layer reads must not depend on the
    /// spelling that arrived.
    func testRetryAfterIsReadCaseInsensitively() throws {
        let throttled = try response(
            "throttled.json",
            statusCode: 429,
            headers: ["retry-after": "5"]
        )
        assertThrows(.throttled(retryAfter: 5)) {
            _ = try LeetCodeAPI.parseUserStatus(throttled)
        }
    }

    /// A rate-limited LeetCode sometimes answers with an interstitial no JSON
    /// parse survives, so 429 is decided from the status alone — before the body
    /// is looked at — rather than being reported as a shape violation.
    func testThrottlingIsDecidedBeforeTheBodyIsParsed() {
        let html = LeetCodeHTTPResponse(
            statusCode: 429,
            headers: ["Content-Type": "text/html"],
            body: Data("<html><body>Too many requests</body></html>".utf8)
        )
        assertThrows(.throttled(retryAfter: nil)) { _ = try LeetCodeAPI.parseUserStatus(html) }
    }

    /// A 403 whose body is LeetCode's throttle sentence is throttling, not a
    /// login problem — and the wait is read out of the sentence when no header
    /// carried it.
    func testForbiddenWithAThrottleBodyIsThrottled() throws {
        let throttled = try response("throttled.json", statusCode: 403)
        assertThrows(.throttled(retryAfter: 42)) {
            _ = try LeetCodeAPI.parseProblemList(throttled)
        }
    }

    func testThrottleWithoutAWaitIsStillThrottled() throws {
        let throttled = try response("throttled-no-wait.json", statusCode: 403)
        assertThrows(.throttled(retryAfter: nil)) {
            _ = try LeetCodeAPI.parseProblemList(throttled)
        }
    }

    func testForbiddenWithAnAuthenticationBodyIsNotLoggedIn() throws {
        let forbidden = try response("rest-not-authenticated.json", statusCode: 403)
        assertThrows(.notLoggedIn) { _ = try LeetCodeAPI.parseProblemList(forbidden) }
    }

    /// A bare 401/403 with nothing useful in it is still a session problem; the
    /// recovery ("sign in again") is the same either way.
    func testBareUnauthorizedResponsesAreNotLoggedIn() {
        for status in [401, 403] {
            let bare = LeetCodeHTTPResponse(statusCode: status, body: Data("{}".utf8))
            assertThrows(.notLoggedIn) { _ = try LeetCodeAPI.parseUserStatus(bare) }
        }
    }

    func testAServerErrorIsAPIChangedNamingTheStatus() {
        let outage = LeetCodeHTTPResponse(
            statusCode: 502,
            body: Data("<html>Bad Gateway</html>".utf8)
        )
        assertAPIChanged(containing: "HTTP 502") { _ = try LeetCodeAPI.parseUserStatus(outage) }
    }

    func testASuccessfulNonJSONBodyIsAPIChanged() {
        let html = LeetCodeHTTPResponse(
            statusCode: 200,
            body: Data("<html>Are you a robot?</html>".utf8)
        )
        assertAPIChanged(containing: "not JSON") { _ = try LeetCodeAPI.parseUserStatus(html) }
    }

    /// The 403 counterpart of `testThrottlingIsDecidedBeforeTheBodyIsParsed`: the
    /// likeliest 403 from this stack is a WAF interstitial, which is HTML. It has
    /// to reach `notLoggedIn` the way a 403 with a JSON body does, or the bug
    /// report it produces sends somebody hunting a schema change.
    func testForbiddenWithANonJSONBodyIsStillNotLoggedIn() {
        let interstitial = LeetCodeHTTPResponse(
            statusCode: 403,
            body: Data("<html><title>Attention Required!</title></html>".utf8)
        )
        assertThrows(.notLoggedIn) { _ = try LeetCodeAPI.parseUserStatus(interstitial) }
        assertThrows(.notLoggedIn) { _ = try LeetCodeAPI.parseProblemList(interstitial) }
    }

    // MARK: - Slugs off the wire

    /// A `titleSlug` that is not a slug is a schema change, not a file name.
    ///
    /// The slug becomes a path component (`0001-two-sum.swift`, appended to the
    /// configured folder) and `appendingPathComponent` does not resolve `..`, so
    /// this is the check between a changed upstream and a file written outside
    /// the folder the user set aside — and, worse, one whose name the
    /// never-overwrite comparison could never match.
    func testAQuestionSlugThatIsNotASlugIsASchemaChange() throws {
        for wire in ["../../etc/passwd", "two/sum", "Two Sum", "-two-sum"] {
            let body = """
            {"data":{"question":{"questionFrontendId":"1","title":"Two Sum",\
            "titleSlug":"\(wire)","difficulty":"Easy","isPaidOnly":false,\
            "content":"<p>x</p>","codeSnippets":[],"exampleTestcaseList":[]}}}
            """
            let response = LeetCodeHTTPResponse(statusCode: 200, body: Data(body.utf8))
            assertAPIChanged(containing: "titleSlug") {
                _ = try LeetCodeAPI.parseQuestionDetail(response, requestedSlug: "two-sum")
            }
        }
    }

    /// The same rule on the catalog side, where the slug *is* the row's identity
    /// and becomes `resolveSlug`'s answer.
    func testACatalogSlugThatIsNotASlugIsASchemaChange() {
        let body = """
        {"stat_status_pairs":[{"stat":{"frontend_question_id":1,\
        "question__title_slug":"../escape","question__title":"Two Sum"},\
        "difficulty":{"level":1},"paid_only":false,"status":null}]}
        """
        let response = LeetCodeHTTPResponse(statusCode: 200, body: Data(body.utf8))
        assertAPIChanged(containing: "question__title_slug") {
            _ = try LeetCodeAPI.parseProblemList(response)
        }
    }

    /// The *number* half of the same naming round trip. `parts(fromFileName:)`
    /// reads back only a positive number, so `0` or a negative id would compose a
    /// file name this app could never associate with a problem again — the exact
    /// failure the slug check exists to prevent, through the other door.
    func testAQuestionNumberThatIsNotPositiveIsASchemaChange() {
        for wire in ["0", "-5"] {
            let body = """
            {"data":{"question":{"questionFrontendId":"\(wire)","title":"Two Sum",\
            "titleSlug":"two-sum","difficulty":"Easy","isPaidOnly":false,\
            "content":"<p>x</p>","codeSnippets":[],"exampleTestcaseList":[]}}}
            """
            let response = LeetCodeHTTPResponse(statusCode: 200, body: Data(body.utf8))
            assertAPIChanged(containing: "questionFrontendId") {
                _ = try LeetCodeAPI.parseQuestionDetail(response, requestedSlug: "two-sum")
            }
        }
    }

    /// The same rule on the catalog side, where the number is the row's other
    /// identity and becomes `slug(forNumber:)`'s key.
    func testACatalogNumberThatIsNotPositiveIsASchemaChange() {
        for wire in ["0", "-5"] {
            let body = """
            {"stat_status_pairs":[{"stat":{"frontend_question_id":\(wire),\
            "question__title_slug":"two-sum","question__title":"Two Sum"},\
            "difficulty":{"level":1},"paid_only":false,"status":null}]}
            """
            let response = LeetCodeHTTPResponse(statusCode: 200, body: Data(body.utf8))
            assertAPIChanged(containing: "frontend_question_id") {
                _ = try LeetCodeAPI.parseProblemList(response)
            }
        }
    }

    /// An *empty* example list is a legitimate answer, so an absent or null one
    /// cannot fold into the same `[]` — that would make a renamed field and a
    /// problem with no example input indistinguishable, and the drift would be
    /// found by Run submitting nothing.
    func testAnAbsentExampleTestcaseListOnAFreeProblemIsAPIChanged() {
        for wire in ["", "\"exampleTestcaseList\":null,"] {
            let body = """
            {"data":{"question":{"questionFrontendId":"1","title":"Two Sum",\
            "titleSlug":"two-sum","difficulty":"Easy","isPaidOnly":false,\
            "content":"<p>x</p>","codeSnippets":[],\(wire)"__pad":0}}}
            """
            let response = LeetCodeHTTPResponse(statusCode: 200, body: Data(body.utf8))
            assertAPIChanged(containing: "exampleTestcaseList") {
                _ = try LeetCodeAPI.parseQuestionDetail(response, requestedSlug: "two-sum")
            }
        }
    }

    /// A Premium problem answered to somebody who *is* subscribed: the flag is
    /// set and the content arrives anyway. The parser already tolerated both
    /// shapes; this pins the complete one, which is what the model's refusal now
    /// distinguishes.
    func testASubscribersPaidOnlyDetailCarriesItsContentAndSnippets() throws {
        let detail = try XCTUnwrap(
            try LeetCodeAPI.parseQuestionDetail(
                response("question-detail-paid-only-subscriber.json"),
                requestedSlug: "two-sum-iii-data-structure-design"
            )
        )
        XCTAssertTrue(detail.isPaidOnly)
        XCTAssertEqual(detail.frontendID, 170)
        XCTAssertFalse(detail.content.isEmpty)
        XCTAssertNotNil(detail.snippet(forLanguageSlug: "swift"))
    }

    /// An absent or empty `titleSlug` still falls back to what was asked for —
    /// the validation tightened the *shape* of a slug LeetCode sends, not the
    /// tolerance for it not sending one.
    func testAnAbsentQuestionSlugStillFallsBackToTheRequestedOne() throws {
        for wire in ["null", "\"\""] {
            let body = """
            {"data":{"question":{"questionFrontendId":"1","title":"Two Sum",\
            "titleSlug":\(wire),"difficulty":"Easy","isPaidOnly":false,\
            "content":"<p>x</p>","codeSnippets":[],"exampleTestcaseList":[]}}}
            """
            let response = LeetCodeHTTPResponse(statusCode: 200, body: Data(body.utf8))
            let detail = try LeetCodeAPI.parseQuestionDetail(response, requestedSlug: "two-sum")
            XCTAssertEqual(detail?.slug, "two-sum")
        }
    }

    /// A slug LeetCode spells in capitals is the same problem, normalized —
    /// `normalizedSlug` lowercases, and this is the one repair it makes.
    func testAQuestionSlugIsNormalizedRatherThanRefusedForCase() throws {
        let body = """
        {"data":{"question":{"questionFrontendId":"1","title":"Two Sum",\
        "titleSlug":"Two-Sum","difficulty":"Easy","isPaidOnly":false,\
        "content":"<p>x</p>","codeSnippets":[],"exampleTestcaseList":[]}}}
        """
        let response = LeetCodeHTTPResponse(statusCode: 200, body: Data(body.utf8))
        let detail = try LeetCodeAPI.parseQuestionDetail(response, requestedSlug: "two-sum")
        XCTAssertEqual(detail?.slug, "two-sum")
    }

    // MARK: - The wait named in a throttle message

    /// The wait is read from the number the *unit* belongs to, not from the first
    /// number in the sentence: the GraphQL end joins every error message
    /// together, so an unanchored scan turns "for user 12345 … in 30 seconds"
    /// into a three-and-a-half-hour wait and says so to the user.
    func testTheWaitIsReadFromTheNumberItsUnitFollows() {
        let body = """
        {"errors":[{"message":"Rate limit exceeded for user 12345. \
        Try again in 30 seconds."}]}
        """
        let response = LeetCodeHTTPResponse(statusCode: 200, body: Data(body.utf8))
        assertThrows(.throttled(retryAfter: 30)) {
            _ = try LeetCodeAPI.parseQuestionDetail(response, requestedSlug: "two-sum")
        }
    }

    /// A wait named in minutes is still a wait, in the seconds the error carries.
    func testAWaitNamedInMinutesIsConvertedToSeconds() {
        let body = """
        {"detail":"Request was throttled. Expected available in 2 minutes."}
        """
        let response = LeetCodeHTTPResponse(statusCode: 429, body: Data(body.utf8))
        // 429 is decided from the status before the body, and carries no header
        // here — the *message* path is the one under test, so use a 403.
        let forbidden = LeetCodeHTTPResponse(statusCode: 403, body: Data(body.utf8))
        assertThrows(.throttled(retryAfter: nil)) { _ = try LeetCodeAPI.parseProblemList(response) }
        assertThrows(.throttled(retryAfter: 120)) {
            _ = try LeetCodeAPI.parseProblemList(forbidden)
        }
    }

    /// A number with no unit, and a wait longer than an hour, are both `nil` —
    /// "in a moment" is strictly better than a number that is wrong.
    func testAnImplausibleOrUnanchoredWaitIsNoWaitAtAll() {
        for sentence in [
            "Request was throttled. Try again later. Ticket 90210.",
            "Request was throttled. Expected available in 99999 seconds.",
            "Request was throttled. Expected available in 0 seconds."
        ] {
            let body = "{\"detail\":\"\(sentence)\"}"
            let response = LeetCodeHTTPResponse(statusCode: 403, body: Data(body.utf8))
            assertThrows(.throttled(retryAfter: nil)) {
                _ = try LeetCodeAPI.parseProblemList(response)
            }
        }
    }

    // MARK: - Enumeration mappings

    /// Two wire spellings of one enum, and every case of it reachable from both —
    /// asserted by `allCases` so a fourth difficulty cannot be added to the model
    /// without a mapping.
    func testBothDifficultySpellingsCoverEveryCase() throws {
        var fromNames: Set<LeetCodeDifficulty> = []
        for name in ["Easy", "Medium", "Hard"] {
            fromNames.insert(try LeetCodeAPI.difficulty(fromGraphQLName: name))
        }
        XCTAssertEqual(fromNames, Set(LeetCodeDifficulty.allCases))

        var fromLevels: Set<LeetCodeDifficulty> = []
        for level in 1...3 {
            fromLevels.insert(try LeetCodeAPI.difficulty(fromRESTLevel: level))
        }
        XCTAssertEqual(fromLevels, Set(LeetCodeDifficulty.allCases))
    }

    func testDifficultyNamesAreMatchedLeniently() throws {
        XCTAssertEqual(try LeetCodeAPI.difficulty(fromGraphQLName: "EASY"), .easy)
        XCTAssertEqual(try LeetCodeAPI.difficulty(fromGraphQLName: " medium "), .medium)
    }

    /// No silent default: a fourth tier must be a loud failure, because "every
    /// problem is Easy" is exactly the kind of wrongness nobody reports.
    func testUnknownDifficultySpellingsThrow() {
        assertAPIChanged(containing: "= Insane") {
            _ = try LeetCodeAPI.difficulty(fromGraphQLName: "Insane")
        }
        for level in [0, 4, -1] {
            assertAPIChanged(containing: "= \(level)") {
                _ = try LeetCodeAPI.difficulty(fromRESTLevel: level)
            }
        }
    }

    func testStatusMapping() {
        XCTAssertEqual(LeetCodeAPI.status(fromRESTValue: "ac"), .solved)
        XCTAssertEqual(LeetCodeAPI.status(fromRESTValue: "notac"), .attempted)
        XCTAssertEqual(LeetCodeAPI.status(fromRESTValue: nil), .notStarted)
        XCTAssertEqual(LeetCodeAPI.status(fromRESTValue: "AC"), .solved)
        XCTAssertEqual(LeetCodeAPI.status(fromRESTValue: "whatever"), .notStarted)
    }
}
