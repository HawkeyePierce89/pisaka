import XCTest
@testable import PisakaCore

/// The judge half of the one schema file: the three endpoints Run and Submit
/// travel over, and the two very different finished shapes their one check
/// endpoint answers with.
///
/// Same two halves and the same discipline as `LeetCodeAPITests`. What is new
/// here is an asymmetry worth stating: this parser is **strict about the verdict
/// and lenient about everything around it**, and both halves are pinned. A
/// `status_code` this app does not know must be a loud `apiChanged` — a wrong
/// verdict on somebody's submission is the worst thing this integration could
/// say — while a missing percentile or a re-spelled runtime string must cost
/// that line of the display and nothing else. Tests that only covered the happy
/// path would let either rule quietly invert.
final class LeetCodeJudgeAPITests: XCTestCase {

    // MARK: - Fixtures

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private static let fixtures = repositoryRoot
        .appendingPathComponent("Tests/PisakaCoreTests/Fixtures/leetcode")

    private func response(
        _ name: String,
        statusCode: Int = 200,
        headers: [String: String] = [:]
    ) throws -> LeetCodeHTTPResponse {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
        return LeetCodeHTTPResponse(statusCode: statusCode, headers: headers, body: data)
    }

    private func body(_ json: String, statusCode: Int = 200) -> LeetCodeHTTPResponse {
        LeetCodeHTTPResponse(statusCode: statusCode, body: Data(json.utf8))
    }

    private let credentials = LeetCodeCredentials(
        session: "session-value",
        csrfToken: "csrf-value"
    )

    private func assertThrows(
        _ expected: LeetCodeError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ work: () throws -> Void
    ) {
        do {
            try work()
            XCTFail("expected \(expected), returned normally", file: file, line: line)
        } catch let error as LeetCodeError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), threw \(error)", file: file, line: line)
        }
    }

    private func assertAPIChanged(
        containing detail: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ work: () throws -> Void
    ) {
        do {
            try work()
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

    /// Unwrap a check that must have finished as a run.
    private func runResult(
        _ check: LeetCodeJudgeCheck,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> LeetCodeRunResult {
        guard case .finishedRun(let result) = check else {
            XCTFail("expected a finished run, got \(check)", file: file, line: line)
            throw LeetCodeError.apiChanged(detail: "not a finished run")
        }
        return result
    }

    private func submitResult(
        _ check: LeetCodeJudgeCheck,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> LeetCodeSubmitResult {
        guard case .finishedSubmit(let result) = check else {
            XCTFail("expected a finished submit, got \(check)", file: file, line: line)
            throw LeetCodeError.apiChanged(detail: "not a finished submit")
        }
        return result
    }

    // MARK: - Endpoints

    /// The trailing slashes are load-bearing, not cosmetic: Django answers the
    /// slash-less form with a 301, and a redirected POST is re-sent as a GET,
    /// which LeetCode then rejects with a 405 that says nothing about the cause.
    func testTheJudgeURLsCarryTheirTrailingSlashes() {
        XCTAssertEqual(
            LeetCodeAPI.interpretURL(slug: "two-sum").absoluteString,
            "https://leetcode.com/problems/two-sum/interpret_solution/"
        )
        XCTAssertEqual(
            LeetCodeAPI.submitURL(slug: "two-sum").absoluteString,
            "https://leetcode.com/problems/two-sum/submit/"
        )
        XCTAssertEqual(
            LeetCodeAPI.checkURL(id: "runcode_1770000000.1234567_AbCdEfGhIj").absoluteString,
            "https://leetcode.com/submissions/detail/runcode_1770000000.1234567_AbCdEfGhIj/check/"
        )
        XCTAssertEqual(
            LeetCodeAPI.problemPageURL(slug: "two-sum").absoluteString,
            "https://leetcode.com/problems/two-sum/"
        )
        // …and the human-facing link the seeded header points at is *not* the
        // same value, which is why the two are separate functions.
        XCTAssertEqual(
            LeetCodeAPI.problemURL(slug: "two-sum").absoluteString,
            "https://leetcode.com/problems/two-sum"
        )
    }

    // MARK: - The scripted transport's routes

    /// The fake recognises the three judge endpoints from the URLs `LeetCodeAPI`
    /// actually composes.
    ///
    /// Asserted here rather than in the model suite because it is a statement
    /// about the *wire*: the routing reads the slug and the id back out of the
    /// path, so a builder that changed shape — or a trailing slash that turned
    /// into a path component of its own — would land every judge request in
    /// `.other(path:)` and take a whole suite's scripts down with it. Getting a
    /// named failure for that is the point of the `.other` fallback, and this is
    /// what keeps it a fallback rather than the normal case.
    func testTheScriptedTransportRecognisesTheJudgeEndpoints() {
        let interpret = LeetCodeAPI.interpretRequest(
            slug: "two-sum",
            questionID: "1",
            langSlug: "swift",
            code: "class Solution {}",
            input: "[2,7,11,15]\n9",
            credentials: credentials
        )
        let submit = LeetCodeAPI.submitRequest(
            slug: "score-of-a-string",
            questionID: "3403",
            langSlug: "swift",
            code: "class Solution {}",
            credentials: credentials
        )
        let runCheck = LeetCodeAPI.checkRequest(
            id: "runcode_1770000000.1234567_AbCdEfGhIj",
            slug: "two-sum",
            credentials: credentials
        )
        let submitCheck = LeetCodeAPI.checkRequest(
            id: "1234567890",
            slug: "two-sum",
            credentials: credentials
        )

        XCTAssertEqual(
            ScriptedLeetCodeTransport.route(of: interpret),
            .interpret(slug: "two-sum")
        )
        XCTAssertEqual(
            ScriptedLeetCodeTransport.route(of: submit),
            .submit(slug: "score-of-a-string")
        )
        XCTAssertEqual(
            ScriptedLeetCodeTransport.route(of: runCheck),
            .check(id: "runcode_1770000000.1234567_AbCdEfGhIj")
        )
        XCTAssertEqual(
            ScriptedLeetCodeTransport.route(of: submitCheck),
            .check(id: "1234567890")
        )
        // The endpoints that existed before still route where they did — the new
        // path-shape branch runs after them and must not have caught either.
        XCTAssertEqual(
            ScriptedLeetCodeTransport.route(
                of: LeetCodeAPI.questionDetailRequest(slug: "two-sum", credentials: credentials)
            ),
            .question(slug: "two-sum")
        )
        XCTAssertEqual(
            ScriptedLeetCodeTransport.route(
                of: LeetCodeAPI.problemListRequest(credentials: credentials)
            ),
            .problemList
        )
    }

    // MARK: - Requests

    /// The judge calls send the **problem page** as `Referer` where the GraphQL
    /// and catalog calls send the site root — that is what a browser does when it
    /// runs or submits, and these are the CSRF-protected views most likely to
    /// check it. The session pair still travels exactly as everywhere else.
    func testTheJudgeCallsRefererIsTheProblemPage() {
        let expected = [
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Cookie": "LEETCODE_SESSION=session-value; csrftoken=csrf-value",
            "Referer": "https://leetcode.com/problems/two-sum/",
            "User-Agent": LeetCodeAPI.userAgent,
            "x-csrftoken": "csrf-value",
        ]

        XCTAssertEqual(
            LeetCodeAPI.interpretRequest(
                slug: "two-sum",
                questionID: "1",
                langSlug: "swift",
                code: "class Solution {}",
                input: "[2,7,11,15]\n9",
                credentials: credentials
            ).headers,
            expected
        )
        XCTAssertEqual(
            LeetCodeAPI.submitRequest(
                slug: "two-sum",
                questionID: "1",
                langSlug: "swift",
                code: "class Solution {}",
                credentials: credentials
            ).headers,
            expected
        )

        // The check is a GET: no body, so no `Content-Type` — and the same
        // problem-page `Referer`, even though its URL never names the problem.
        var get = expected
        get["Content-Type"] = nil
        XCTAssertEqual(
            LeetCodeAPI.checkRequest(id: "17", slug: "two-sum", credentials: credentials).headers,
            get
        )
    }

    /// The interpret payload, byte for byte. `question_id` is LeetCode's
    /// **internal** id — the number in the file name would address a different
    /// problem on anything recent — and `data_input` is whatever the user typed.
    func testInterpretRequestIsExact() {
        let request = LeetCodeAPI.interpretRequest(
            slug: "score-of-a-string",
            questionID: "3403",
            langSlug: "swift",
            code: "class Solution {\n    func f() {}\n}",
            input: "[2,7,11,15]\n9",
            credentials: credentials
        )
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(
            request.url.absoluteString,
            "https://leetcode.com/problems/score-of-a-string/interpret_solution/"
        )
        XCTAssertEqual(
            request.body.flatMap { String(data: $0, encoding: .utf8) },
            #"{"data_input":"[2,7,11,15]\n9","lang":"swift","question_id":"3403","#
                + #""typed_code":"class Solution {\n    func f() {}\n}"}"#
        )
    }

    /// The submit payload carries **no** `data_input` at all. Not an empty one:
    /// a submission runs LeetCode's own suite, and the editable box has nothing
    /// to do with it — a key that was either ignored or, worse, honoured is the
    /// difference between the two buttons.
    func testSubmitRequestCarriesNoTestInput() {
        let request = LeetCodeAPI.submitRequest(
            slug: "two-sum",
            questionID: "1",
            langSlug: "python3",
            code: "class Solution:\n    pass",
            credentials: credentials
        )
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(
            request.url.absoluteString,
            "https://leetcode.com/problems/two-sum/submit/"
        )
        let text = try? XCTUnwrap(request.body.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(
            text,
            #"{"lang":"python3","question_id":"1","typed_code":"class Solution:\n    pass"}"#
        )
        XCTAssertFalse(text?.contains("data_input") ?? true)
    }

    func testCheckRequestIsABodylessGET() {
        let request = LeetCodeAPI.checkRequest(
            id: "1234567890",
            slug: "two-sum",
            credentials: credentials
        )
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(
            request.url.absoluteString,
            "https://leetcode.com/submissions/detail/1234567890/check/"
        )
        XCTAssertNil(request.body)
    }

    /// `.sortedKeys` again: without it these assertions would pass or fail
    /// depending on how the hash table felt that morning.
    func testJudgeRequestBodiesAreDeterministic() {
        let build = {
            LeetCodeAPI.interpretRequest(
                slug: "two-sum",
                questionID: "1",
                langSlug: "swift",
                code: "x",
                input: "y",
                credentials: self.credentials
            ).body
        }
        XCTAssertEqual(build(), build())
        XCTAssertNotNil(build())
    }

    /// The credential headers this file names are on the judge calls too — the
    /// redirect rule is written in terms of that list, so a judge call that
    /// carried the session under some other name would escape it.
    func testTheJudgeCallsCarryTheNamedCredentialHeaders() {
        let headers = LeetCodeAPI.checkRequest(
            id: "1",
            slug: "two-sum",
            credentials: credentials
        ).headers
        for name in LeetCodeAPI.credentialHeaderNames {
            XCTAssertNotNil(headers[name], name)
        }
    }

    // MARK: - The two ids

    /// A run's handle is a `runcode_…` string; a submission's is a JSON number.
    /// Both are carried as the `String` the check URL needs, and neither is ever
    /// interpreted — which is the whole reason one reader serves both.
    func testBothJudgeIdsAreReadWhicheverFormTheyArriveIn() throws {
        XCTAssertEqual(
            try LeetCodeAPI.parseInterpretID(response("judge-interpret-id.json")),
            "runcode_1770000000.1234567_AbCdEfGhIj"
        )
        XCTAssertEqual(
            try LeetCodeAPI.parseSubmissionID(response("judge-submit-id.json")),
            "1234567890"
        )
    }

    /// Without an id there is nothing to poll, so the run silently never
    /// happened — the one shape here that must not be shrugged off.
    func testAMissingJudgeIdIsAPIChanged() {
        for wire in ["{}", #"{"interpret_id":null}"#, #"{"interpret_id":""}"#] {
            assertAPIChanged(containing: "interpret_id") {
                _ = try LeetCodeAPI.parseInterpretID(self.body(wire))
            }
        }
        assertAPIChanged(containing: "submission_id") {
            _ = try LeetCodeAPI.parseSubmissionID(self.body("{}"))
        }
    }

    // MARK: - States

    /// The two non-terminal states arrive as a body carrying **nothing but
    /// `state`**, which is what proves the parser does not demand a
    /// `status_code` the judge has not produced yet.
    func testPendingAndStartedCarryNothingButTheState() throws {
        for (fixture, expected) in [
            ("judge-check-pending.json", LeetCodeJudgeCheck.pending),
            ("judge-check-started.json", LeetCodeJudgeCheck.started),
        ] {
            for kind in LeetCodeJudgeKind.allCases {
                let check = try LeetCodeAPI.parseJudgeCheck(response(fixture), kind: kind)
                XCTAssertEqual(check, expected, "\(fixture) as \(kind)")
                XCTAssertFalse(check.isTerminal, fixture)
            }
        }
    }

    /// `FAILURE` is LeetCode's own judge giving up. Terminal, and deliberately
    /// *not* reported as a schema change — LeetCode documents it by sending it,
    /// and telling the user "the API changed" would send them to a bug report
    /// instead of to the retry that fixes it.
    func testTheJudgeGivingUpIsAStateAndNotASchemaChange() throws {
        for kind in LeetCodeJudgeKind.allCases {
            let check = try LeetCodeAPI.parseJudgeCheck(
                response("judge-check-failure.json"),
                kind: kind
            )
            XCTAssertEqual(check, .judgeFailed)
            XCTAssertTrue(check.isTerminal)
        }
    }

    func testStateSpellingIsMatchedLeniently() {
        XCTAssertEqual(LeetCodeAPI.judgeState(fromWireValue: "success"), .success)
        XCTAssertEqual(LeetCodeAPI.judgeState(fromWireValue: " PENDING "), .pending)
        XCTAssertNil(LeetCodeAPI.judgeState(fromWireValue: "QUEUED"))
    }

    /// A fifth state names itself. No default: "not finished yet" guessed wrong
    /// is an endless poll, and "finished" guessed wrong is a verdict read out of
    /// a half-built response.
    func testAnUnknownStateIsAPIChanged() throws {
        let unknown = try response("judge-check-unknown-state.json")
        assertAPIChanged(containing: "state = QUEUED") {
            _ = try LeetCodeAPI.parseJudgeCheck(unknown, kind: .run)
        }
        assertAPIChanged(containing: "state") {
            _ = try LeetCodeAPI.parseJudgeCheck(self.body("{}"), kind: .run)
        }
    }

    // MARK: - Verdicts

    /// Every case of the table is reachable from its wire code, and every one of
    /// them says something — asserted by `allCases` so a tenth verdict cannot be
    /// added to the model without a code and a name.
    func testEveryVerdictIsReachableFromItsStatusCodeAndNamesItself() throws {
        var seen: Set<LeetCodeVerdict> = []
        for verdict in LeetCodeVerdict.allCases {
            seen.insert(try LeetCodeAPI.verdict(fromStatusCode: verdict.rawValue))
            XCTAssertFalse(verdict.displayName.isEmpty, "\(verdict)")
        }
        XCTAssertEqual(seen, Set(LeetCodeVerdict.allCases))
        XCTAssertTrue(LeetCodeVerdict.accepted.isAccepted)
        XCTAssertFalse(LeetCodeVerdict.wrongAnswer.isAccepted)
    }

    /// A code this app does not map is a schema change naming the number. There
    /// is no default and no `unknown` case, because LeetCode already *has* an
    /// "Unknown Error" (21) it sends on purpose — folding a tenth code into it
    /// would make the two indistinguishable and the user would be told the wrong
    /// thing about their submission with nothing on screen to say so.
    func testAnUnknownStatusCodeIsAPIChanged() throws {
        let unknown = try response("judge-check-unknown-status.json")
        for kind in LeetCodeJudgeKind.allCases {
            assertAPIChanged(containing: "status_code = 7") {
                _ = try LeetCodeAPI.parseJudgeCheck(unknown, kind: kind)
            }
        }
        for code in [0, 17, 22, -1] {
            assertAPIChanged(containing: "status_code = \(code)") {
                _ = try LeetCodeAPI.verdict(fromStatusCode: code)
            }
        }
        // …and 21 is LeetCode's own, not this app's fallback.
        XCTAssertEqual(try LeetCodeAPI.verdict(fromStatusCode: 21), .unknownError)
    }

    /// A `SUCCESS` with no `status_code` at all is a shape violation, not a
    /// verdict: the strict half stays strict even when the state says finished.
    func testAFinishedCheckWithoutAStatusCodeIsAPIChanged() {
        assertAPIChanged(containing: "status_code") {
            _ = try LeetCodeAPI.parseJudgeCheck(
                self.body(#"{"state":"SUCCESS"}"#),
                kind: .run
            )
        }
    }

    // MARK: - Finished runs

    func testAnAcceptedRunCarriesItsAnswersAndItsMatch() throws {
        let result = try runResult(
            try LeetCodeAPI.parseJudgeCheck(
                response("judge-check-run-accepted.json"),
                kind: .run
            )
        )
        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(result.matchedExpected, true)
        XCTAssertEqual(result.answers, ["[0,1]", "[1,2]", "[0,1]"])
        XCTAssertEqual(result.expectedAnswers, ["[0,1]", "[1,2]", "[0,1]"])
        XCTAssertEqual(result.stdOutputs.count, 4)
        XCTAssertEqual(result.runtime, "12 ms")
        XCTAssertEqual(result.memory, "14.4 MB")
        XCTAssertNil(result.errorText)
    }

    /// The case the run shape exists for. `status_code` is **still 10** — the
    /// code ran — and `correct_answer` is the only member that says the output
    /// was wrong. A view that read the headline off the verdict alone would call
    /// this Accepted, which is why the two are separate properties with the
    /// distinction written on both.
    func testAWrongRunIsStillStatusCodeTenAndSaysSoOnlyInCorrectAnswer() throws {
        let result = try runResult(
            try LeetCodeAPI.parseJudgeCheck(
                response("judge-check-run-wrong-answer.json"),
                kind: .run
            )
        )
        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertTrue(result.verdict.isAccepted)
        XCTAssertEqual(result.matchedExpected, false)
        XCTAssertEqual(result.answers, ["[0,1]", "[]", "[0,1]"])
        XCTAssertEqual(result.expectedAnswers, ["[0,1]", "[1,2]", "[0,1]"])
        // Indexed defensively: a trap here takes the whole test binary down with
        // it, and a length this parser got wrong is exactly what would trip it.
        XCTAssertEqual(result.stdOutputs.dropFirst().first, "nums = [3, 2, 4]\n")
    }

    /// Nothing measurable, and nothing invented: LeetCode spells the runtime
    /// `"N/A"` and sends an empty answer list, so the display strings are what
    /// arrived and no zero is substituted anywhere.
    func testATimedOutRunReportsNoMeasurements() throws {
        let result = try runResult(
            try LeetCodeAPI.parseJudgeCheck(
                response("judge-check-run-time-limit-exceeded.json"),
                kind: .run
            )
        )
        XCTAssertEqual(result.verdict, .timeLimitExceeded)
        XCTAssertEqual(result.matchedExpected, false)
        XCTAssertTrue(result.answers.isEmpty)
        XCTAssertEqual(result.runtime, "N/A")
        XCTAssertNil(result.errorText)
    }

    /// The full trace, not the one-line summary — a compiler or runtime
    /// diagnostic cut to its first line is not a diagnosis, and reading it in
    /// full is the reason somebody stays in the editor instead of opening the
    /// browser.
    func testARunErrorPrefersTheFullText() throws {
        let runtime = try runResult(
            try LeetCodeAPI.parseJudgeCheck(
                response("judge-check-run-runtime-error.json"),
                kind: .run
            )
        )
        XCTAssertEqual(runtime.verdict, .runtimeError)
        XCTAssertEqual(
            runtime.errorText,
            "Solution.swift:7: Fatal error: Index out of range\n"
                + "Current runtime error:\n    Line 7: Fatal error: Index out of range"
        )

        let compile = try runResult(
            try LeetCodeAPI.parseJudgeCheck(
                response("judge-check-run-compile-error.json"),
                kind: .run
            )
        )
        XCTAssertEqual(compile.verdict, .compileError)
        XCTAssertTrue(compile.errorText?.hasPrefix("Solution.swift:4:5: error:") ?? false)
        XCTAssertTrue(compile.errorText?.contains("note: to match this opening") ?? false)
        // Nothing executed, so there is no verdict on the output at all — which
        // is a different statement from "the output did not match".
        XCTAssertNil(compile.matchedExpected)
        XCTAssertTrue(compile.answers.isEmpty)
    }

    /// The short spellings are used when the full ones are absent, and compile
    /// wins over runtime because a response carrying both compiled nothing.
    func testTheErrorTextFallsBackAndPrefersCompileOverRuntime() throws {
        let short = try runResult(
            try LeetCodeAPI.parseJudgeCheck(
                body(#"{"state":"SUCCESS","status_code":15,"runtime_error":"boom"}"#),
                kind: .run
            )
        )
        XCTAssertEqual(short.errorText, "boom")

        let both = try runResult(
            try LeetCodeAPI.parseJudgeCheck(
                body(
                    #"{"state":"SUCCESS","status_code":20,"runtime_error":"boom","#
                        + #""compile_error":"expected '}'"}"#
                ),
                kind: .run
            )
        )
        XCTAssertEqual(both.errorText, "expected '}'")
    }

    /// LeetCode echoes the submitted input back on some shapes and not others.
    /// When it does it is **one block**, kept verbatim rather than split: the two
    /// cases below are four lines, because `data_input` spells one line per
    /// *parameter*, so lines and cases are not the same thing and pairing them
    /// would label the wrong text as each case's input.
    func testAnEchoedInputIsKeptWholeAndAnAbsentOneIsNil() throws {
        let echoed = try runResult(
            try LeetCodeAPI.parseJudgeCheck(
                body(
                    #"{"state":"SUCCESS","status_code":10,"correct_answer":true,"#
                        + #""test_case":"[2,7,11,15]\n9\n[3,3]\n6"}"#
                ),
                kind: .run
            )
        )
        XCTAssertEqual(echoed.input, "[2,7,11,15]\n9\n[3,3]\n6")

        let silent = try runResult(
            try LeetCodeAPI.parseJudgeCheck(
                response("judge-check-run-accepted.json"),
                kind: .run
            )
        )
        XCTAssertNil(silent.input)
    }

    /// The case count comes off the two per-case arrays and deliberately ignores
    /// `std_output_list`, which LeetCode sends one element longer than there are
    /// cases on an accepted run — the shipped fixture has four entries for three.
    /// Taking the longest array would render a phantom empty final case on the
    /// happy path, every time.
    func testTheCaseCountIgnoresTheTrailingExtraStandardOutput() throws {
        let accepted = try runResult(
            try LeetCodeAPI.parseJudgeCheck(
                response("judge-check-run-accepted.json"),
                kind: .run
            )
        )
        XCTAssertEqual(accepted.stdOutputs.count, 4)
        XCTAssertEqual(accepted.answers.count, 3)
        XCTAssertEqual(accepted.caseCount, 3)

        // A compile error executed nothing, so `code_answer` is absent — the
        // expected answers are what still say how many cases there were.
        let compileError = try runResult(
            try LeetCodeAPI.parseJudgeCheck(
                response("judge-check-run-compile-error.json"),
                kind: .run
            )
        )
        XCTAssertTrue(compileError.answers.isEmpty)
        XCTAssertEqual(compileError.caseCount, 3)

        // Nothing at all: no case rows rather than a row of empty fields.
        XCTAssertEqual(LeetCodeRunResult(verdict: .accepted).caseCount, 0)
    }

    /// A display array keeps every element's **position**. These arrays are read
    /// by index against each other, so an element dropped for being an unexpected
    /// shape would shift every later case's output under the wrong heading —
    /// which is why an unreadable element is an empty slot and not a missing one.
    func testADisplayArrayKeepsUnreadableElementsAsEmptySlots() throws {
        let result = try runResult(
            try LeetCodeAPI.parseJudgeCheck(
                body(
                    #"{"state":"SUCCESS","status_code":10,"correct_answer":true,"#
                        + #""code_answer":["a",null,{"x":1},2,"b"]}"#
                ),
                kind: .run
            )
        )
        XCTAssertEqual(result.answers, ["a", "", "", "2", "b"])
    }

    // MARK: - The ids that become path components

    /// Both judge ids are appended to the check URL as path components, and
    /// `appendingPathComponent` passes `/` and `..` through unencoded — so an id
    /// carrying either would send the session cookie to a URL nothing in this app
    /// chose. The same discipline the slug rule applies (L4), on the two other
    /// wire values that become path components.
    func testAJudgeIDThatCouldTraverseTheCheckPathIsRejected() throws {
        for hostile in ["../../logout", "a/b", "..", "."] {
            let escaped = hostile.replacingOccurrences(of: "\\", with: "\\\\")
            XCTAssertThrowsError(
                try LeetCodeAPI.parseInterpretID(body(#"{"interpret_id":"\#(escaped)"}"#)),
                "interpret_id \(hostile)"
            ) { error in
                guard case .apiChanged(let detail)? = error as? LeetCodeError else {
                    return XCTFail("expected apiChanged, got \(error)")
                }
                XCTAssertTrue(detail.contains("interpret_id"), detail)
            }
            XCTAssertThrowsError(
                try LeetCodeAPI.parseSubmissionID(body(#"{"submission_id":"\#(escaped)"}"#)),
                "submission_id \(hostile)"
            )
        }
    }

    /// The shapes LeetCode actually sends still pass, including the run's dotted,
    /// underscored, mixed-case token and the submission's bare number.
    func testTheRealJudgeIDShapesArePassedThrough() throws {
        XCTAssertEqual(
            try LeetCodeAPI.parseInterpretID(response("judge-interpret-id.json")),
            "runcode_1770000000.1234567_AbCdEfGhIj"
        )
        XCTAssertEqual(
            try LeetCodeAPI.parseSubmissionID(response("judge-submit-id.json")),
            "1234567890"
        )
    }

    // MARK: - Finished submissions

    func testAnAcceptedSubmissionCarriesItsPercentiles() throws {
        let result = try submitResult(
            try LeetCodeAPI.parseJudgeCheck(
                response("judge-check-submit-accepted.json"),
                kind: .submit
            )
        )
        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertEqual(result.runtime, "12 ms")
        XCTAssertEqual(result.memory, "14.4 MB")
        XCTAssertEqual(try XCTUnwrap(result.runtimePercentile), 85.6421, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.memoryPercentile), 60.2117, accuracy: 0.0001)
        XCTAssertEqual(result.totalCorrect, 63)
        XCTAssertEqual(result.totalTestcases, 63)
        // `""` is LeetCode's spelling of "not applicable" on an accepted
        // submission, and a view has nothing to do with the difference between
        // that and an absent key.
        XCTAssertNil(result.lastTestcaseInput)
        XCTAssertNil(result.expectedOutput)
        XCTAssertNil(result.codeOutput)
        XCTAssertNil(result.errorText)
    }

    /// The single most useful failure in the whole integration: which case broke,
    /// what it expected and what the code produced. The percentiles are **absent**
    /// rather than zero — LeetCode has none for a submission that failed, and a
    /// `0%` invented here would read as a measurement.
    func testAWrongSubmissionNamesTheFailingCaseAndOmitsThePercentiles() throws {
        let result = try submitResult(
            try LeetCodeAPI.parseJudgeCheck(
                response("judge-check-submit-wrong-answer.json"),
                kind: .submit
            )
        )
        XCTAssertEqual(result.verdict, .wrongAnswer)
        XCTAssertEqual(result.lastTestcaseInput, "[3,2,4]\n6")
        XCTAssertEqual(result.expectedOutput, "[1,2]")
        XCTAssertEqual(result.codeOutput, "[]")
        XCTAssertEqual(result.stdOutput, "nums = [3, 2, 4]\n")
        XCTAssertEqual(result.totalCorrect, 3)
        XCTAssertEqual(result.totalTestcases, 63)
        XCTAssertNil(result.runtimePercentile)
        XCTAssertNil(result.memoryPercentile)
    }

    func testATimedOutSubmissionStillNamesTheCaseItDiedOn() throws {
        let result = try submitResult(
            try LeetCodeAPI.parseJudgeCheck(
                response("judge-check-submit-time-limit-exceeded.json"),
                kind: .submit
            )
        )
        XCTAssertEqual(result.verdict, .timeLimitExceeded)
        XCTAssertEqual(result.totalCorrect, 12)
        XCTAssertEqual(result.lastTestcaseInput, "[1,3,5,7,9,11,13,15,17,19]\n28")
        XCTAssertNil(result.runtimePercentile)
    }

    func testASubmissionErrorPrefersTheFullText() throws {
        let runtime = try submitResult(
            try LeetCodeAPI.parseJudgeCheck(
                response("judge-check-submit-runtime-error.json"),
                kind: .submit
            )
        )
        XCTAssertEqual(runtime.verdict, .runtimeError)
        XCTAssertTrue(runtime.errorText?.hasPrefix("Solution.swift:7:") ?? false)
        XCTAssertEqual(runtime.lastTestcaseInput, "[3,3]\n6")

        let compile = try submitResult(
            try LeetCodeAPI.parseJudgeCheck(
                response("judge-check-submit-compile-error.json"),
                kind: .submit
            )
        )
        XCTAssertEqual(compile.verdict, .compileError)
        XCTAssertTrue(compile.errorText?.contains("expected '}' in class") ?? false)
        // Nothing reached a test case, so there are no counts — `nil`, not `0`,
        // because "0 of 63 passed" is a different sentence from "it never ran".
        XCTAssertNil(compile.totalCorrect)
        XCTAssertNil(compile.totalTestcases)
        XCTAssertNil(compile.lastTestcaseInput)
    }

    // MARK: - The leniency around the verdict

    /// The display half never fails a verdict. LeetCode has moved, renamed and
    /// re-typed these members more than once; losing a detail line is an
    /// acceptable cost, losing the verdict is not. This is the catalog's
    /// `status` leniency applied where the same trade-off appears.
    func testARespelledDisplayFieldCostsThatFieldAndNotTheVerdict() throws {
        let odd = body(
            #"{"state":"SUCCESS","status_code":10,"status_runtime":{"ms":12},"#
                + #""status_memory":[],"runtime_percentile":"85.6","total_correct":"63","#
                + #""total_testcases":63,"code_output":7}"#
        )
        let result = try submitResult(try LeetCodeAPI.parseJudgeCheck(odd, kind: .submit))
        XCTAssertEqual(result.verdict, .accepted)
        XCTAssertNil(result.runtime)
        XCTAssertNil(result.memory)
        // A percentile spelled as a string is not a number this app will invent
        // a value for…
        XCTAssertNil(result.runtimePercentile)
        // …while a *count* spelled as a numeric string is the same tolerance the
        // problem number already needs, and a number is rendered for display.
        XCTAssertEqual(result.totalCorrect, 63)
        XCTAssertEqual(result.codeOutput, "7")
    }

    /// Where a percentile out of `Double`'s range actually stops, recorded
    /// because it is not where one would guess.
    ///
    /// `JSONSerialization` refuses the *document* rather than handing back an
    /// infinity, so a number like `1e400` never reaches the display readers at
    /// all — it costs the whole check, reported as `apiChanged`. That is a known
    /// limit of the leniency below rather than a hole in it: the leniency covers
    /// keys that moved or changed type, not bytes Foundation will not parse. The
    /// readers' own non-finite guard stays as the belt to that braces, and this
    /// test exists so nobody re-derives the interaction from the guard's
    /// existence and concludes the value is tolerated end to end.
    func testAPercentileOutsideDoubleRangeFailsAtTheJSONLayer() {
        let odd = body(#"{"state":"SUCCESS","status_code":10,"runtime_percentile":1e400}"#)
        assertAPIChanged(containing: "not JSON") {
            _ = try LeetCodeAPI.parseJudgeCheck(odd, kind: .submit)
        }
    }

    /// A percentile that *is* representable is carried verbatim, however
    /// implausible — nothing here decides what a percentile ought to look like.
    func testALargeButRepresentablePercentileIsCarried() throws {
        let odd = body(#"{"state":"SUCCESS","status_code":10,"runtime_percentile":1e300}"#)
        let result = try submitResult(try LeetCodeAPI.parseJudgeCheck(odd, kind: .submit))
        XCTAssertEqual(result.runtimePercentile, 1e300)
    }

    // MARK: - HTTP-level failures on a check

    /// A poll is a plain REST call, so the throttle and auth shapes it meets are
    /// DRF's own — and they are classified by the same envelope handling every
    /// other call in this file goes through. The GraphQL errors-array branch
    /// simply never fires here.
    func testAThrottledCheckIsThrottledAndNotASchemaChange() throws {
        let throttled = try response(
            "throttled.json",
            statusCode: 429,
            headers: ["Retry-After": "17"]
        )
        assertThrows(.throttled(retryAfter: 17)) {
            _ = try LeetCodeAPI.parseJudgeCheck(throttled, kind: .submit)
        }

        // A rate-limited LeetCode sometimes answers with an interstitial that no
        // JSON parse survives; the poll loop must hear "throttled", not "the API
        // changed", or it reports a schema bug for a busy afternoon.
        let html = LeetCodeHTTPResponse(
            statusCode: 429,
            body: Data("<html><body>Too many requests</body></html>".utf8)
        )
        assertThrows(.throttled(retryAfter: nil)) {
            _ = try LeetCodeAPI.parseJudgeCheck(html, kind: .run)
        }
    }

    /// A session that expired mid-poll answers DRF's authentication body. That
    /// has to arrive as `notLoggedIn` so the flow can flip the account state,
    /// rather than as an unexplained parse failure.
    func testAnUnauthenticatedCheckIsNotLoggedIn() throws {
        let forbidden = try response("rest-not-authenticated.json", statusCode: 403)
        assertThrows(.notLoggedIn) {
            _ = try LeetCodeAPI.parseJudgeCheck(forbidden, kind: .run)
        }
        assertThrows(.notLoggedIn) {
            _ = try LeetCodeAPI.parseInterpretID(forbidden)
        }
        assertThrows(.notLoggedIn) {
            _ = try LeetCodeAPI.parseSubmissionID(forbidden)
        }
    }

    // MARK: - The two new refusals

    /// Both new cases are product refusals, and both must read as sentences a
    /// user can act on rather than as `LeetCodeError error 8`.
    func testTheJudgeRefusalsExplainThemselves() {
        XCTAssertEqual(
            LeetCodeError.judgeTimedOut(seconds: 30).errorDescription,
            "LeetCode did not return a result within 30 seconds. "
                + "LeetCode still has the submission — its result is on the site."
        )
        XCTAssertEqual(
            LeetCodeError.judgeTimedOut(seconds: 1).errorDescription,
            "LeetCode did not return a result within 1 second. "
                + "LeetCode still has the submission — its result is on the site."
        )
        // The sentence says the submission was *not* undone, because it was not:
        // budget exhaustion stops this app waiting, not LeetCode judging.
        XCTAssertTrue(
            LeetCodeError.judgeTimedOut(seconds: 60).errorDescription?
                .contains("still has the submission") ?? false
        )

        XCTAssertEqual(
            LeetCodeError.judgeUnavailable(reason: "Open a LeetCode solution file to run it.")
                .errorDescription,
            "Open a LeetCode solution file to run it."
        )
        XCTAssertEqual(
            LeetCodeError.judgeUnavailable(reason: "   ").errorDescription,
            "This file cannot be run on LeetCode."
        )
    }

    /// The same trap the throttle case is guarded against, through the other
    /// door: `Int(_:)` on an infinite or over-`Int.max` `Double` terminates the
    /// process, and this is a `public` case anyone can build.
    func testAnImplausibleJudgeBudgetDoesNotTrapTheFormatter() {
        for seconds in [Double.infinity, -Double.infinity, Double.nan, 1e300, 0, -5] {
            XCTAssertEqual(
                LeetCodeError.judgeTimedOut(seconds: seconds).errorDescription,
                "LeetCode did not return a result in time. "
                    + "LeetCode still has the submission — its result is on the site.",
                "\(seconds)"
            )
        }
    }
}
