import XCTest
@testable import PisakaCore

/// The judge's flow: what the buttons offer, what a poll publishes, and — mostly
/// — what it deliberately does *not* publish.
///
/// Three properties carry this suite, and they are the LC-1 rules applied on a
/// new axis:
///
/// - **A superseded or cancelled attempt publishes nothing at all.** Not a
///   verdict, not an error, not a spinner left running. A second Run, leaving the
///   surface, or a session change each invalidate the one in flight, and the
///   evidence is that the published state is untouched *and* the polling stopped.
/// - **A poll never hangs.** The budget is a deadline, so exhaustion is a typed,
///   user-facing failure with a number in it. The whole state machine — thirty
///   sleeps and all — runs through the injected clock, so this costs `swift test`
///   no wall-clock time.
/// - **What is judged is what is on screen.** The live buffer, never the saved
///   copy; the edited box verbatim on a Run and not at all on a Submit.
@MainActor
final class LeetCodeJudgeModelTests: XCTestCase {

    // MARK: - Harness

    private let credentials = LeetCodeCredentials(
        session: "session-value",
        csrfToken: "csrf-value"
    )

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private static func fixture(_ name: String) -> Data {
        let url = repositoryRoot
            .appendingPathComponent("Tests/PisakaCoreTests/Fixtures/leetcode")
            .appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            preconditionFailure("missing fixture \(name)")
        }
        return data
    }

    private static func response(
        _ name: String,
        statusCode: Int = 200,
        headers: [String: String] = [:]
    ) -> LeetCodeHTTPResponse {
        LeetCodeHTTPResponse(statusCode: statusCode, headers: headers, body: fixture(name))
    }

    private let treeRoot = URL(fileURLWithPath: "/leetcode-judge-tests")
    private var cacheBase: URL { treeRoot.appendingPathComponent("cache") }
    private var solutionsFolder: URL { treeRoot.appendingPathComponent("Solutions") }

    /// The id `judge-interpret-id.json` answers with, which is the check route's
    /// key for a Run.
    private let runID = "runcode_1770000000.1234567_AbCdEfGhIj"
    /// The id `judge-submit-id.json` answers with — a number on the wire, carried
    /// as a string.
    private let submissionID = "1234567890"

    /// The clock the deadline is measured against, advanced by the sleep seam so
    /// the poll loop runs at full speed and still respects its budget.
    private final class TestClock {
        var now = Date(timeIntervalSince1970: 1_786_000_000)
    }

    /// One prepared surface: a signed-in model, a scripted LeetCode, and an
    /// editor holding the solution file open.
    private struct World {
        let model: LeetCodeModel
        let transport: ScriptedLeetCodeTransport
        let tree: StubFileTree
        let workspace: WorkspaceModel
        let clock: TestClock
        let url: URL
        @MainActor var judge: LeetCodeJudgeModel { model.judge }
    }

    /// Build the world *without* preparing the judge, so a test can script the
    /// detail response first.
    private func makeWorld(
        fileName: String = "0001-two-sum.swift",
        savedText: String = "class Solution {}\n",
        signedIn: Bool = true
    ) throws -> World {
        let path = "Solutions/\(fileName)"
        let tree = StubFileTree(root: treeRoot, files: [path: savedText])
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.userStatus, body: Self.fixture("user-status-signed-in.json"))
        transport.serve(.question(slug: "two-sum"), body: Self.fixture("question-detail.json"))
        transport.serve(.interpret(slug: "two-sum"), body: Self.fixture("judge-interpret-id.json"))
        transport.serve(.submit(slug: "two-sum"), body: Self.fixture("judge-submit-id.json"))
        let model = LeetCodeModel(
            transport: transport,
            credentialStore: InMemoryLeetCodeCredentialStore(signedIn ? credentials : nil),
            fileService: tree,
            cacheLayout: LeetCodeCacheLayout(base: cacheBase),
            solutionsFolder: solutionsFolder,
            now: { Date(timeIntervalSince1970: 1_786_000_000) }
        )
        let workspace = WorkspaceModel(fileService: tree)
        let url = solutionsFolder.appendingPathComponent(fileName)
        try workspace.open(url: url)

        let clock = TestClock()
        model.judge.workspace = workspace
        model.judge.now = { clock.now }
        model.judge.sleep = { seconds in clock.now += seconds }
        return World(
            model: model,
            transport: transport,
            tree: tree,
            workspace: workspace,
            clock: clock,
            url: url
        )
    }

    /// The same world with the judge already pointed at the file — the state
    /// every flow test starts from.
    private func makePreparedWorld(
        fileName: String = "0001-two-sum.swift",
        savedText: String = "class Solution {}\n"
    ) async throws -> World {
        let world = try makeWorld(fileName: fileName, savedText: savedText)
        await world.judge.prepare(forFileAt: world.url, in: solutionsFolder)
        return world
    }

    /// Script the check endpoint for `id` with a sequence of recorded bodies, the
    /// last one sticking.
    private func serveChecks(
        _ world: World,
        id: String,
        _ fixtures: [String]
    ) {
        world.transport.serve(
            .check(id: id),
            sequence: fixtures.map { Self.response($0) }
        )
    }

    /// The JSON body of the one request that went to `route`.
    private func payload(
        _ world: World,
        _ route: ScriptedLeetCodeTransport.Route,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let requests = world.transport.requests(for: route)
        guard let body = requests.last?.body,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            XCTFail("no JSON body sent to \(route)", file: file, line: line)
            return [:]
        }
        return object
    }

    // MARK: - The availability table

    private var swift: LeetCodeLanguage { LeetCodeSolutionFile.defaultLanguage }

    func testAvailabilityIsReadyForASolutionFileInAnOfferedLanguage() {
        XCTAssertEqual(
            LeetCodeJudgeModel.availability(
                problemSlug: "two-sum",
                fileExtension: "swift",
                isSignedIn: true,
                isRunning: false
            ),
            .ready(swift)
        )
    }

    /// A file that names no problem — the stray `notes.md` the association rule
    /// deliberately admits, or any tab outside the LeetCode folder.
    func testAvailabilityRefusesAFileThatNamesNoProblem() {
        XCTAssertEqual(
            LeetCodeJudgeModel.availability(
                problemSlug: nil,
                fileExtension: "swift",
                isSignedIn: true,
                isRunning: false
            ),
            .notASolutionFile
        )
    }

    /// The not-offerable refusal: LeetCode accepts Ruby and C++, this app offers
    /// neither, so a `.rb` solution file is refused with a sentence naming the
    /// extension rather than submitted under a guessed language.
    func testAvailabilityRefusesALanguageThisAppDoesNotOffer() {
        XCTAssertEqual(
            LeetCodeJudgeModel.availability(
                problemSlug: "two-sum",
                fileExtension: "rb",
                isSignedIn: true,
                isRunning: false
            ),
            .unsupportedLanguage("rb")
        )
        XCTAssertEqual(
            LeetCodeJudgeModel.availability(
                problemSlug: "two-sum",
                fileExtension: "md",
                isSignedIn: true,
                isRunning: false
            )
            .reason,
            "LeetCode does not accept “.md” files."
        )
    }

    /// The file's own facts are reported before the session's: signing in cannot
    /// make a Markdown file submittable, so saying "sign in" about one would be
    /// true and useless.
    func testTheFilesOwnRefusalIsReportedBeforeTheSessionsAndTheRuns() {
        XCTAssertEqual(
            LeetCodeJudgeModel.availability(
                problemSlug: nil,
                fileExtension: "md",
                isSignedIn: false,
                isRunning: true
            ),
            .notASolutionFile
        )
        XCTAssertEqual(
            LeetCodeJudgeModel.availability(
                problemSlug: "two-sum",
                fileExtension: "swift",
                isSignedIn: false,
                isRunning: true
            ),
            .notSignedIn
        )
        XCTAssertEqual(
            LeetCodeJudgeModel.availability(
                problemSlug: "two-sum",
                fileExtension: "swift",
                isSignedIn: true,
                isRunning: true
            ),
            .busy
        )
    }

    /// Every refusal explains itself, and the one non-refusal explains nothing —
    /// which is what makes a disabled button with no tooltip impossible.
    func testEveryRefusalCarriesASentenceAndReadyCarriesNone() {
        let refusals: [LeetCodeJudgeAvailability] = [
            .notASolutionFile,
            .unsupportedLanguage("md"),
            .unsupportedLanguage(""),
            .notSignedIn,
            .busy
        ]
        for refusal in refusals {
            XCTAssertFalse(refusal.isReady, "\(refusal) must not be ready")
            XCTAssertNil(refusal.language)
            let reason = refusal.reason ?? ""
            XCTAssertFalse(
                reason.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(refusal) has nothing to say"
            )
        }
        XCTAssertNil(LeetCodeJudgeAvailability.ready(swift).reason)
        XCTAssertEqual(LeetCodeJudgeAvailability.ready(swift).language, swift)
        XCTAssertTrue(LeetCodeJudgeAvailability.ready(swift).isReady)
    }

    // MARK: - Preparing a surface

    func testPreparingPrefillsTheBoxFromTheProblemsExamples() async throws {
        let world = try await makePreparedWorld()

        XCTAssertEqual(world.judge.availability, .ready(swift))
        XCTAssertEqual(world.judge.testInput, "[2,7,11,15]\n9\n[3,2,4]\n6\n[3,3]\n6")
        XCTAssertEqual(world.judge.phase, .idle)
        XCTAssertNil(world.judge.lastError)
    }

    /// Re-preparing the same file is what the host view's `.task(id:)` does on
    /// every re-render, so it must cost nothing and — above all — must not throw
    /// away what the user typed into the box.
    func testRePreparingTheSameFileKeepsTheEditedInputAndAsksNothing() async throws {
        let world = try await makePreparedWorld()
        world.judge.testInput = "[1,2]\n3"

        await world.judge.prepare(forFileAt: world.url, in: solutionsFolder)

        XCTAssertEqual(world.judge.testInput, "[1,2]\n3")
        XCTAssertEqual(world.transport.count(for: .question(slug: "two-sum")), 1)
    }

    /// A different problem is a different box: the examples of the one on screen,
    /// never the ones the previous tab was showing.
    func testPreparingADifferentProblemResetsTheBox() async throws {
        let world = try await makePreparedWorld()
        world.judge.testInput = "edited"
        world.transport.serve(
            .question(slug: "score-of-a-string"),
            body: Self.fixture("question-detail-newer-problem.json")
        )
        let other = solutionsFolder.appendingPathComponent("3110-score-of-a-string.swift")

        await world.judge.prepare(forFileAt: other, in: solutionsFolder)

        XCTAssertEqual(world.judge.testInput, "\"hello\"\n\"zaz\"")
        XCTAssertNil(world.judge.lastRun)
    }

    /// A file whose name parses but whose problem LeetCode does not know is, as
    /// far as the judge is concerned, not a solution file — a value, not a schema
    /// change, and nothing is published as an error.
    func testAFileLeetCodeDoesNotKnowIsRefusedAsNotASolutionFile() async throws {
        let world = try makeWorld(fileName: "2024-notes.swift")
        world.transport.serve(
            .question(slug: "notes"),
            body: Self.fixture("question-detail-unknown-slug.json")
        )

        await world.judge.prepare(forFileAt: world.url, in: solutionsFolder)

        XCTAssertEqual(world.judge.availability, .notASolutionFile)
        XCTAssertNil(world.judge.lastError)
    }

    /// A language nothing can be submitted under costs no request at all: the
    /// refusal is decided from the file name alone.
    func testPreparingAnUnofferedLanguageAsksLeetCodeNothing() async throws {
        let world = try makeWorld(fileName: "0001-two-sum.md")

        await world.judge.prepare(forFileAt: world.url, in: solutionsFolder)

        XCTAssertEqual(world.judge.availability, .unsupportedLanguage("md"))
        XCTAssertEqual(world.transport.count(for: .question(slug: "two-sum")), 0)
        XCTAssertEqual(world.judge.testInput, "")
    }

    /// Leaving the surface entirely clears it.
    func testPreparingForNoFileClearsTheSurface() async throws {
        let world = try await makePreparedWorld()

        await world.judge.prepare(forFileAt: nil, in: solutionsFolder)

        XCTAssertEqual(world.judge.availability, .notASolutionFile)
        XCTAssertEqual(world.judge.testInput, "")
    }

    // MARK: - The poll machine

    func testARunPollsUntilSuccessAndPublishesTheVerdict() async throws {
        let world = try await makePreparedWorld()
        serveChecks(
            world,
            id: runID,
            ["judge-check-pending.json", "judge-check-started.json", "judge-check-run-accepted.json"]
        )

        await world.judge.run()

        XCTAssertEqual(world.judge.lastRun?.verdict, .accepted)
        XCTAssertEqual(world.judge.lastRun?.matchedExpected, true)
        XCTAssertEqual(world.judge.lastRun?.answers, ["[0,1]", "[1,2]", "[0,1]"])
        XCTAssertEqual(world.judge.lastRun?.runtime, "12 ms")
        XCTAssertNil(world.judge.lastSubmit, "a run is not a submission")
        XCTAssertNil(world.judge.lastError)
        XCTAssertEqual(world.judge.phase, .idle)
        XCTAssertEqual(world.judge.availability, .ready(swift))
        XCTAssertEqual(world.transport.count(for: .check(id: runID)), 3)
    }

    func testASubmitPollsUntilSuccessAndPublishesTheVerdict() async throws {
        let world = try await makePreparedWorld()
        serveChecks(
            world,
            id: submissionID,
            ["judge-check-pending.json", "judge-check-submit-accepted.json"]
        )

        await world.judge.submit()

        XCTAssertEqual(world.judge.lastSubmit?.verdict, .accepted)
        XCTAssertEqual(world.judge.lastSubmit?.totalCorrect, 63)
        XCTAssertEqual(world.judge.lastSubmit?.totalTestcases, 63)
        XCTAssertEqual(world.judge.lastSubmit?.runtimePercentile, 85.6421)
        XCTAssertNil(world.judge.lastRun)
        XCTAssertNil(world.judge.lastError)
        XCTAssertEqual(world.judge.phase, .idle)
        XCTAssertEqual(world.transport.count(for: .check(id: submissionID)), 2)
    }

    /// A wrong answer is a *result*, not a failure: nothing is published as an
    /// error, and the failing case is what the user is shown.
    func testAWrongAnswerIsAResultRatherThanAFailure() async throws {
        let world = try await makePreparedWorld()
        serveChecks(world, id: submissionID, ["judge-check-submit-wrong-answer.json"])

        await world.judge.submit()

        XCTAssertEqual(world.judge.lastSubmit?.verdict, .wrongAnswer)
        XCTAssertEqual(world.judge.lastSubmit?.lastTestcaseInput, "[3,2,4]\n6")
        XCTAssertNil(world.judge.lastError)
    }

    /// The judge's own `FAILURE`: terminal, stated in the user's words, and
    /// emphatically not reported as a schema change — LeetCode documents that
    /// state by sending it.
    func testAJudgeFailureIsStatedRatherThanReportedAsASchemaChange() async throws {
        let world = try await makePreparedWorld()
        serveChecks(world, id: runID, ["judge-check-failure.json"])

        await world.judge.run()

        guard case .judgeUnavailable(let reason) = world.judge.lastError else {
            return XCTFail("expected judgeUnavailable, got \(String(describing: world.judge.lastError))")
        }
        XCTAssertTrue(reason.contains("judge"), reason)
        XCTAssertNil(world.judge.lastRun)
        XCTAssertEqual(world.judge.phase, .idle)
    }

    /// Exhaustion is a typed failure naming the budget, never a hang — and the
    /// budget is a *deadline*, so the number of polls follows from the clock.
    func testABudgetThatRunsOutPublishesTheTypedTimeout() async throws {
        let world = try await makePreparedWorld()
        world.judge.budgets = LeetCodeJudgeModel.Budgets(run: 5, submit: 60)
        serveChecks(world, id: runID, ["judge-check-pending.json"])

        await world.judge.run()

        XCTAssertEqual(world.judge.lastError, .judgeTimedOut(seconds: 5))
        XCTAssertNil(world.judge.lastRun)
        XCTAssertEqual(world.judge.phase, .idle)
        // Five one-second waits fit inside a five-second budget, so the sixth
        // check is the one that finds the deadline spent.
        XCTAssertEqual(world.transport.count(for: .check(id: runID)), 6)
    }

    /// A throttle mid-poll is published and stops the loop: hammering an endpoint
    /// that just said "too many requests" is how an unofficial API stops
    /// answering at all.
    func testAThrottleMidPollIsPublishedAndStopsThePoll() async throws {
        let world = try await makePreparedWorld()
        world.transport.serve(
            .check(id: runID),
            sequence: [
                Self.response("judge-check-pending.json"),
                Self.response(
                    "throttled.json",
                    statusCode: 429,
                    headers: ["Retry-After": "42"]
                ),
                Self.response("judge-check-run-accepted.json")
            ]
        )

        await world.judge.run()

        XCTAssertEqual(world.judge.lastError, .throttled(retryAfter: 42))
        XCTAssertNil(world.judge.lastRun)
        XCTAssertEqual(world.transport.count(for: .check(id: runID)), 2)
    }

    /// A session LeetCode rejects mid-poll flips the account state, wherever the
    /// rejection arrives — the same rule every other operation follows.
    func testALoggedOutCheckFlipsTheAccountState() async throws {
        let world = try await makePreparedWorld()
        world.transport.serve(
            .check(id: submissionID),
            sequence: [
                Self.response("judge-check-pending.json"),
                Self.response("rest-not-authenticated.json", statusCode: 403)
            ]
        )

        await world.judge.submit()

        XCTAssertEqual(world.judge.lastError, .notLoggedIn)
        XCTAssertFalse(world.model.isSignedIn)
        XCTAssertEqual(world.judge.availability, .notSignedIn)
        XCTAssertNil(world.judge.lastSubmit)
    }

    /// A second Run while the first is still polling: the first publishes
    /// **nothing at all** and stops asking.
    ///
    /// Staged through the sleep seam, which is the one deterministic window
    /// between two polls. The two attempts are scripted to different verdicts, so
    /// a first attempt that carried on would be visible as the wrong one.
    func testASecondRunSupersedesTheFirstWhichPublishesNothing() async throws {
        let world = try await makePreparedWorld()
        serveChecks(
            world,
            id: runID,
            [
                "judge-check-pending.json",
                "judge-check-run-accepted.json",
                "judge-check-run-wrong-answer.json"
            ]
        )
        var restarted = false
        world.judge.sleep = { [judge = world.judge, clock = world.clock] seconds in
            clock.now += seconds
            guard !restarted else { return }
            restarted = true
            await judge.run()
        }

        await world.judge.run()

        XCTAssertEqual(world.judge.lastRun?.verdict, .accepted)
        XCTAssertEqual(world.judge.lastRun?.matchedExpected, true)
        XCTAssertNil(world.judge.lastError)
        XCTAssertEqual(world.judge.phase, .idle)
        // One from the superseded attempt, one from the replacement — the first
        // never asked again.
        XCTAssertEqual(world.transport.count(for: .check(id: runID)), 2)
    }

    /// Cancelling — leaving the surface, closing the tab — publishes nothing at
    /// all: no verdict, no error, and no spinner left running.
    func testACancelledRunPublishesNothing() async throws {
        let world = try await makePreparedWorld()
        serveChecks(
            world,
            id: runID,
            ["judge-check-pending.json", "judge-check-run-accepted.json"]
        )
        var cancelled = false
        world.judge.sleep = { [judge = world.judge, clock = world.clock] seconds in
            clock.now += seconds
            guard !cancelled else { return }
            cancelled = true
            judge.cancel()
        }

        await world.judge.run()

        XCTAssertNil(world.judge.lastRun)
        XCTAssertNil(world.judge.lastError)
        XCTAssertEqual(world.judge.phase, .idle)
        XCTAssertEqual(world.transport.count(for: .check(id: runID)), 1)
    }

    /// A sign-out mid-poll invalidates it exactly as it invalidates a fetch — the
    /// fourth generation token, bumped with the other three.
    func testASignOutMidPollPublishesNothing() async throws {
        let world = try await makePreparedWorld()
        serveChecks(
            world,
            id: runID,
            ["judge-check-pending.json", "judge-check-run-accepted.json"]
        )
        var signedOut = false
        world.judge.sleep = { [model = world.model, clock = world.clock] seconds in
            clock.now += seconds
            guard !signedOut else { return }
            signedOut = true
            model.signOut()
        }

        await world.judge.run()

        XCTAssertNil(world.judge.lastRun)
        XCTAssertNil(world.judge.lastError)
        XCTAssertEqual(world.judge.phase, .idle)
        XCTAssertEqual(world.judge.availability, .notSignedIn)
        XCTAssertEqual(world.transport.count(for: .check(id: runID)), 1)
    }

    // MARK: - What is sent

    /// The prefilled box, edited, reaches `data_input` verbatim — and the payload
    /// is addressed by LeetCode's *internal* question id, not the number in the
    /// file name.
    func testTheEditedTestInputReachesTheInterpretPayloadVerbatim() async throws {
        let world = try await makePreparedWorld()
        serveChecks(world, id: runID, ["judge-check-run-accepted.json"])
        world.judge.testInput = "[1,2,3]\n5\n[9]\n9"

        await world.judge.run()

        let body = try payload(world, .interpret(slug: "two-sum"))
        XCTAssertEqual(body["data_input"] as? String, "[1,2,3]\n5\n[9]\n9")
        XCTAssertEqual(body["question_id"] as? String, "1")
        XCTAssertEqual(body["lang"] as? String, "swift")
    }

    /// Submit ignores the box entirely: LeetCode's own suite is what a submission
    /// is judged against, and a `data_input` on that endpoint would be either
    /// ignored or, worse, honoured.
    func testSubmitSendsNoTestInputAtAll() async throws {
        let world = try await makePreparedWorld()
        serveChecks(world, id: submissionID, ["judge-check-submit-accepted.json"])
        world.judge.testInput = "[1,2,3]\n5"

        await world.judge.submit()

        let body = try payload(world, .submit(slug: "two-sum"))
        XCTAssertNil(body["data_input"])
        XCTAssertEqual(Set(body.keys), ["lang", "question_id", "typed_code"])
    }

    /// **The live buffer, not the saved copy.** A user who has not pressed ⌘S
    /// must not be told their previous attempt is wrong.
    func testTheLiveBufferIsWhatIsJudgedNotTheSavedCopy() async throws {
        let world = try await makePreparedWorld(savedText: "// the previous attempt\n")
        serveChecks(world, id: runID, ["judge-check-run-accepted.json"])
        let id = try XCTUnwrap(world.workspace.fileID(forURL: world.url))
        world.workspace.updateText("// what is on screen\n", for: id)
        XCTAssertTrue(world.workspace.isDirty(for: id), "the case only exists while dirty")

        await world.judge.run()

        let body = try payload(world, .interpret(slug: "two-sum"))
        XCTAssertEqual(body["typed_code"] as? String, "// what is on screen\n")
        XCTAssertEqual(
            world.tree.writtenPaths,
            [],
            "the judge is a reader: nothing is saved on the way to LeetCode"
        )
    }

    /// A file the editor has no buffer for is refused with a sentence rather than
    /// read off the disk — the judge does no file IO at all.
    func testAFileTheEditorDoesNotHoldIsRefusedRatherThanReadFromDisk() async throws {
        let world = try await makePreparedWorld()
        world.judge.workspace = nil

        await world.judge.run()

        guard case .judgeUnavailable = world.judge.lastError else {
            return XCTFail("expected judgeUnavailable, got \(String(describing: world.judge.lastError))")
        }
        XCTAssertEqual(world.transport.count(for: .interpret(slug: "two-sum")), 0)
    }

    /// Pressing Run on a surface whose buttons are disabled states the same
    /// refusal the tooltip does, rather than doing nothing.
    func testRunningAnUnavailableSurfaceStatesTheRefusal() async throws {
        let world = try makeWorld(fileName: "0001-two-sum.md")
        await world.judge.prepare(forFileAt: world.url, in: solutionsFolder)

        await world.judge.run()

        XCTAssertEqual(
            world.judge.lastError,
            .judgeUnavailable(reason: LeetCodeJudgeAvailability.unsupportedLanguage("md").reason ?? "")
        )
        XCTAssertEqual(world.transport.count(for: .interpret(slug: "two-sum")), 0)
    }

    /// Signing in while a solution file is on screen enables the buttons where
    /// they stood, with no tab switch and no second prepare.
    func testSigningInEnablesTheButtonsOnTheSurfaceAlreadyOnScreen() async throws {
        let world = try makeWorld(signedIn: false)
        await world.judge.prepare(forFileAt: world.url, in: solutionsFolder)
        XCTAssertEqual(world.judge.availability, .notSignedIn)

        try await world.model.signIn(with: credentials)

        XCTAssertEqual(world.judge.availability, .ready(swift))
    }

    /// The session arrived after the surface was prepared, so the context was
    /// never resolved — the run resolves it on the way, in one request.
    func testARunResolvesAContextThePreparedSurfaceCouldNotAsk() async throws {
        let world = try makeWorld(signedIn: false)
        await world.judge.prepare(forFileAt: world.url, in: solutionsFolder)
        XCTAssertEqual(world.transport.count(for: .question(slug: "two-sum")), 0)
        try await world.model.signIn(with: credentials)
        serveChecks(world, id: runID, ["judge-check-run-accepted.json"])

        await world.judge.run()

        XCTAssertEqual(world.transport.count(for: .question(slug: "two-sum")), 1)
        let body = try payload(world, .interpret(slug: "two-sum"))
        XCTAssertEqual(body["question_id"] as? String, "1")
        XCTAssertEqual(world.judge.lastRun?.verdict, .accepted)
    }
}
