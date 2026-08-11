import XCTest
@testable import PisakaCore

/// The model is where the LeetCode area stops being pure, so this suite is about
/// *sequence and consequence* rather than about parsing (`LeetCodeAPITests`) or
/// policy (`LeetCodeCatalogTests`).
///
/// Three properties carry most of it:
///
/// - **Nothing is written until every refusal has passed.** Signed out, no
///   folder, Premium, throttled, offline, a changed API — each has to leave the
///   folder exactly as it found it, because the alternative is a half-seeded file
///   the user then edits.
/// - **An existing file is never rewritten.** The naming rule's whole purpose is
///   that reopening a problem returns you to your work, and re-seeding would
///   delete it silently.
/// - **Superseded work publishes nothing.** The generation tokens are asserted by
///   holding a request open, starting a second operation, and checking that the
///   first one neither publishes nor writes.
@MainActor
final class LeetCodeModelTests: XCTestCase {

    // MARK: - Harness

    private let credentials = LeetCodeCredentials(
        session: "session-value",
        csrfToken: "csrf-value"
    )

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    /// A recorded response, read through `#filePath` like every other fixture in
    /// this target (they are `exclude:`d from the package, never bundled).
    private static func fixture(_ name: String) -> Data {
        let url = repositoryRoot
            .appendingPathComponent("Tests/PisakaCoreTests/Fixtures/leetcode")
            .appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            preconditionFailure("missing fixture \(name)")
        }
        return data
    }

    private let treeRoot = URL(fileURLWithPath: "/leetcode-model-tests")
    private var cacheBase: URL { treeRoot.appendingPathComponent("cache") }
    private var solutionsFolder: URL { treeRoot.appendingPathComponent("Solutions") }
    private let catalogPath = "cache/catalog.json"
    private let statementPath = "cache/Statements/two-sum.html"
    private let twoSumPath = "Solutions/0001-two-sum.swift"

    private var swift: LeetCodeLanguage { LeetCodeSolutionFile.defaultLanguage }
    private var python: LeetCodeLanguage {
        LeetCodeSolutionFile.language(forLangSlug: "python3")!
    }

    private func makeTree(_ files: [String: String] = [:]) -> StubFileTree {
        StubFileTree(root: treeRoot, files: files)
    }

    /// The scripted world every test starts from: a signed-in session, a catalog
    /// that answers, and Two Sum's recorded detail.
    private func makeTransport() -> ScriptedLeetCodeTransport {
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.userStatus, body: Self.fixture("user-status-signed-in.json"))
        transport.serve(.problemList, body: Self.fixture("problem-list.json"))
        transport.serve(.question(slug: "two-sum"), body: Self.fixture("question-detail.json"))
        return transport
    }

    private func makeModel(
        tree: StubFileTree,
        transport: ScriptedLeetCodeTransport,
        store: LeetCodeCredentialStore? = nil,
        folder: URL? = nil
    ) -> LeetCodeModel {
        LeetCodeModel(
            transport: transport,
            credentialStore: store ?? InMemoryLeetCodeCredentialStore(credentials),
            fileService: tree,
            cacheLayout: LeetCodeCacheLayout(base: cacheBase),
            solutionsFolder: folder ?? solutionsFolder,
            now: { Date(timeIntervalSince1970: 1_786_000_000) }
        )
    }

    /// `XCTAssertThrowsError` cannot carry an `await`, and every failure path here
    /// is asynchronous.
    private func assertThrows(
        _ expected: LeetCodeError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected), returned normally", file: file, line: line)
        } catch let error as LeetCodeError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), threw \(error)", file: file, line: line)
        }
    }

    /// The paths the model wrote that are *solution files* — the assertion "no
    /// partial file was left" is about the folder, not about the cache, which
    /// every successful fetch legitimately touches.
    private func solutionWrites(_ tree: StubFileTree) -> [String] {
        tree.writtenPaths.filter { $0.hasPrefix("Solutions/") }
    }

    // MARK: - Opening a problem: the happy paths

    func testOpeningByNumberCreatesTheSeededFile() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        let outcome = try await model.openProblem(input: .number(1), language: swift)

        XCTAssertTrue(outcome.wasCreated)
        XCTAssertEqual(outcome.solution?.url, treeRoot.appendingPathComponent(twoSumPath))
        XCTAssertEqual(outcome.solution?.problem.frontendID, 1)
        XCTAssertEqual(outcome.solution?.problem.title, "Two Sum")
        XCTAssertEqual(outcome.solution?.language, swift)
        XCTAssertNil(model.lastError)
        XCTAssertFalse(model.isBusy)

        let contents = try XCTUnwrap(tree.files[twoSumPath])
        XCTAssertEqual(
            contents.components(separatedBy: "\n").first,
            "// 1. Two Sum — https://leetcode.com/problems/two-sum"
        )
        XCTAssertTrue(
            contents.contains("class Solution {\n    func twoSum(_ nums: [Int], _ target: Int)"),
            "the snippet must be seeded verbatim"
        )
        XCTAssertTrue(contents.hasSuffix("\n"))
        // The number resolved through the catalog, the detail through GraphQL —
        // one of each, and nothing else.
        XCTAssertEqual(transport.count(for: .problemList), 1)
        XCTAssertEqual(transport.count(for: .question(slug: "two-sum")), 1)
        XCTAssertEqual(transport.count(for: .userStatus), 0)
    }

    /// A slug is already the key the detail request is made by, so opening one
    /// must not download the 2 MB catalog — the property `LeetCodeCatalog`
    /// establishes, asserted here through the whole flow.
    func testOpeningBySlugDoesNotTouchTheCatalog() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        let outcome = try await model.openProblem(input: .slug("two-sum"), language: swift)

        XCTAssertTrue(outcome.wasCreated)
        XCTAssertEqual(transport.count(for: .problemList), 0)
        XCTAssertNotNil(tree.files[twoSumPath])
    }

    func testOpeningByPastedURLResolvesTheSameProblem() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        let input = try XCTUnwrap(
            LeetCodeProblemInput.parse("https://leetcode.com/problems/two-sum/description/?envType=x")
        )
        let outcome = try await model.openProblem(input: input, language: swift)

        XCTAssertEqual(outcome.solution?.url.lastPathComponent, "0001-two-sum.swift")
        XCTAssertEqual(transport.count(for: .problemList), 0)
    }

    /// The language decides the extension, the comment token and which snippet is
    /// seeded — all three, from one row.
    func testTheChosenLanguageDecidesTheNameAndTheSnippet() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        let outcome = try await model.openProblem(input: .slug("two-sum"), language: python)

        XCTAssertEqual(outcome.solution?.url.lastPathComponent, "0001-two-sum.py")
        let contents = try XCTUnwrap(tree.files["Solutions/0001-two-sum.py"])
        XCTAssertTrue(contents.hasPrefix("# 1. Two Sum — "))
        XCTAssertTrue(contents.contains("class Solution:\n    def twoSum(self"))
    }

    /// The one destructive thing this integration could do, and the one it must
    /// never do: an existing file comes back untouched.
    func testReopeningAProblemLeavesTheExistingFileByteIdentical() async throws {
        let mine = "// my own work\nclass Solution { /* half finished */ }\n"
        let tree = makeTree([twoSumPath: mine])
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        let outcome = try await model.openProblem(input: .number(1), language: swift)

        guard case .resumed(let solution) = outcome else {
            return XCTFail("expected .resumed, got \(outcome)")
        }
        XCTAssertEqual(solution.url, treeRoot.appendingPathComponent(twoSumPath))
        XCTAssertEqual(tree.files[twoSumPath], mine)
        XCTAssertEqual(solutionWrites(tree), [], "an existing solution file was written to")
    }

    /// The same rule, on the volume the user actually has: APFS and HFS+ are
    /// case-insensitive by default, so a solution renamed to a different case is
    /// still *the same file* — and an exact-name comparison would report it
    /// absent and then write straight over it. The tab that opens is the name on
    /// disk, which is what makes the answer right on a case-sensitive volume too.
    func testACaseOnlyRenamedSolutionIsResumedRatherThanOverwritten() async throws {
        let mine = "// my own work, under a name I typed myself\n"
        let renamed = "Solutions/0001-Two-Sum.swift"
        let tree = makeTree([renamed: mine])
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        let outcome = try await model.openProblem(input: .number(1), language: swift)

        guard case .resumed(let solution) = outcome else {
            return XCTFail("expected .resumed, got \(outcome)")
        }
        XCTAssertEqual(solution.url, treeRoot.appendingPathComponent(renamed))
        XCTAssertEqual(tree.files[renamed], mine)
        XCTAssertNil(tree.files[twoSumPath], "the lowercase name was written anyway")
        XCTAssertEqual(solutionWrites(tree), [], "an existing solution file was written to")
    }

    /// Opening a problem populates the panel and the offline cache in the same
    /// step — the statement is already in hand, and fetching it twice would be a
    /// second request for bytes we have.
    func testOpeningAProblemCachesAndPublishesItsStatement() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        _ = try await model.openProblem(input: .slug("two-sum"), language: swift)

        XCTAssertEqual(model.statement?.slug, "two-sum")
        XCTAssertEqual(model.statement?.number, 1)
        XCTAssertEqual(model.statement?.title, "Two Sum")
        XCTAssertEqual(model.statement?.isFromCache, false)
        XCTAssertTrue(model.statement?.fragment.contains("<p>You are given an array") == true)
        XCTAssertEqual(tree.files[statementPath], model.statement?.fragment)
    }

    // MARK: - Opening a problem: every refusal

    func testAProblemNobodyKnowsIsNotAnError() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        let outcome = try await model.openProblem(input: .number(999_999), language: swift)

        XCTAssertEqual(outcome, .noSuchProblem)
        XCTAssertNil(model.lastError, "a typo must not be reported as a failure")
        XCTAssertEqual(solutionWrites(tree), [])
    }

    /// The slug half of the same answer: LeetCode says `data.question: null`, and
    /// that is "no such problem", not a schema change.
    func testASlugLeetCodeDoesNotKnowIsNotAnError() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        transport.serve(
            .question(slug: "two-sums"),
            body: Self.fixture("question-detail-unknown-slug.json")
        )
        let model = makeModel(tree: tree, transport: transport)

        let outcome = try await model.openProblem(input: .slug("two-sums"), language: swift)

        XCTAssertEqual(outcome, .noSuchProblem)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(solutionWrites(tree), [])
    }

    func testAPremiumProblemIsRefusedBeforeAnythingIsWritten() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        transport.serve(
            .question(slug: "two-sum-iii-data-structure-design"),
            body: Self.fixture("question-detail-paid-only.json")
        )
        let model = makeModel(tree: tree, transport: transport)

        await assertThrows(.paidOnly(slug: "two-sum-iii-data-structure-design")) {
            _ = try await model.openProblem(input: .number(170), language: self.swift)
        }
        XCTAssertEqual(model.lastError, .paidOnly(slug: "two-sum-iii-data-structure-design"))
        XCTAssertEqual(solutionWrites(tree), [])
        XCTAssertNil(model.statement)
    }

    func testThrottlingSurfacesAndWritesNothing() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        transport.serve(
            .question(slug: "two-sum"),
            body: Self.fixture("throttled.json"),
            statusCode: 429,
            headers: ["Retry-After": "30"]
        )
        let model = makeModel(tree: tree, transport: transport)

        await assertThrows(.throttled(retryAfter: 30)) {
            _ = try await model.openProblem(input: .slug("two-sum"), language: self.swift)
        }
        XCTAssertEqual(model.lastError, .throttled(retryAfter: 30))
        XCTAssertEqual(solutionWrites(tree), [])
    }

    func testATransportFailureSurfacesAsNetworkAndWritesNothing() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        transport.fail(.question(slug: "two-sum"))
        let model = makeModel(tree: tree, transport: transport)

        do {
            _ = try await model.openProblem(input: .slug("two-sum"), language: swift)
            XCTFail("expected a network error")
        } catch let error as LeetCodeError {
            guard case .network(let reason) = error else {
                return XCTFail("expected .network, got \(error)")
            }
            XCTAssertFalse(reason.isEmpty)
        }
        XCTAssertEqual(solutionWrites(tree), [])
        XCTAssertFalse(model.isBusy)
    }

    func testAChangedAPISurfacesAsApiChangedAndWritesNothing() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        transport.serve(.question(slug: "two-sum"), body: Self.fixture("invalid-null-data.json"))
        let model = makeModel(tree: tree, transport: transport)

        await assertThrows(.apiChanged(detail: "data")) {
            _ = try await model.openProblem(input: .slug("two-sum"), language: self.swift)
        }
        XCTAssertEqual(solutionWrites(tree), [])
    }

    func testOpeningWithNoFolderConfiguredReportsFolderUnavailable() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let model = LeetCodeModel(
            transport: transport,
            credentialStore: InMemoryLeetCodeCredentialStore(credentials),
            fileService: tree,
            cacheLayout: LeetCodeCacheLayout(base: cacheBase)
        )

        await assertThrows(.folderUnavailable) {
            _ = try await model.openProblem(input: .slug("two-sum"), language: self.swift)
        }
        XCTAssertEqual(model.lastError, .folderUnavailable)
        // The refusal comes before any request: there is nowhere to put the answer.
        XCTAssertEqual(transport.sent.count, 0)
    }

    /// Something that is not a directory occupying the folder's path is the same
    /// answer as no folder at all — and it is reached *after* the fetch, so the
    /// assertion is that it still leaves nothing behind.
    func testAnUnusableFolderReportsFolderUnavailable() async throws {
        let tree = makeTree(["Solutions": "not a directory"])
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        await assertThrows(.folderUnavailable) {
            _ = try await model.openProblem(input: .slug("two-sum"), language: self.swift)
        }
        XCTAssertEqual(solutionWrites(tree), [])
    }

    func testAFailedWriteSurfacesAsFileSystem() async throws {
        let tree = makeTree()
        tree.writeFailures = [twoSumPath]
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        do {
            _ = try await model.openProblem(input: .slug("two-sum"), language: swift)
            XCTFail("expected a file-system error")
        } catch let error as LeetCodeError {
            guard case .fileSystem(let reason) = error else {
                return XCTFail("expected .fileSystem, got \(error)")
            }
            XCTAssertFalse(reason.isEmpty)
        }
        XCTAssertNil(tree.files[twoSumPath])
        // The panel is published globally, not per tab: a statement adopted on a
        // path that then threw would sit beside whatever unrelated file is open,
        // describing a problem the user has no file for and with nothing to clear
        // it until they switch tabs.
        XCTAssertNil(model.statement, "a failed open published a statement anyway")
    }

    /// A language LeetCode does not offer this problem in still produces the file
    /// — the name, the header and the panel are all correct, and a refusal here
    /// would be a dead end the user cannot act on.
    func testALanguageWithNoSnippetStillSeedsTheHeader() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        transport.serve(
            .question(slug: "two-sum"),
            json: """
                {"data":{"question":{"questionFrontendId":"1","title":"Two Sum",\
                "titleSlug":"two-sum","content":"<p>x</p>","difficulty":"Easy",\
                "isPaidOnly":false,"exampleTestcaseList":[],"codeSnippets":[]}}}
                """
        )
        let model = makeModel(tree: tree, transport: transport)

        let outcome = try await model.openProblem(input: .slug("two-sum"), language: swift)

        XCTAssertTrue(outcome.wasCreated)
        XCTAssertEqual(
            tree.files[twoSumPath],
            "// 1. Two Sum — https://leetcode.com/problems/two-sum\n"
        )
    }

    // MARK: - Being signed out

    func testOpeningWhileSignedOutReportsNotLoggedInAndAsksNothing() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(
            tree: tree,
            transport: transport,
            store: InMemoryLeetCodeCredentialStore()
        )

        XCTAssertFalse(model.isSignedIn)
        await assertThrows(.notLoggedIn) {
            _ = try await model.openProblem(input: .slug("two-sum"), language: self.swift)
        }
        XCTAssertEqual(model.lastError, .notLoggedIn)
        XCTAssertEqual(transport.sent.count, 0)
        XCTAssertEqual(solutionWrites(tree), [])
    }

    func testSigningOutThenOpeningReportsNotLoggedIn() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let store = InMemoryLeetCodeCredentialStore(credentials)
        let model = makeModel(tree: tree, transport: transport, store: store)

        XCTAssertTrue(model.isSignedIn)
        model.signOut()
        XCTAssertFalse(model.isSignedIn)
        XCTAssertNil(store.stored, "sign-out left the session in the store")

        await assertThrows(.notLoggedIn) {
            _ = try await model.openProblem(input: .slug("two-sum"), language: self.swift)
        }
        XCTAssertEqual(transport.sent.count, 0)
    }

    /// LeetCode's own verdict, wherever it appears, is what decides login — so a
    /// rejected request flips the published state as well as reporting.
    func testARejectedRequestFlipsTheSignedInState() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        transport.serve(
            .question(slug: "two-sum"),
            body: Self.fixture("errors-not-authenticated.json")
        )
        let model = makeModel(tree: tree, transport: transport)
        XCTAssertTrue(model.isSignedIn)

        await assertThrows(.notLoggedIn) {
            _ = try await model.openProblem(input: .slug("two-sum"), language: self.swift)
        }
        XCTAssertFalse(model.isSignedIn)
        XCTAssertNil(model.signedInUsername)
    }

    // MARK: - Signing in

    func testSigningInConfirmsTheSessionAndStoresIt() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let store = InMemoryLeetCodeCredentialStore()
        let model = makeModel(tree: tree, transport: transport, store: store)

        let username = try await model.signIn(with: credentials)

        XCTAssertEqual(username, "pisaka_tester")
        XCTAssertEqual(model.signedInUsername, "pisaka_tester")
        XCTAssertTrue(model.isSignedIn)
        XCTAssertEqual(store.stored, credentials)
        XCTAssertFalse(model.lastCredentialSaveFailed)
        XCTAssertNil(model.lastError)
    }

    /// A session LeetCode rejects at the moment it was obtained is not worth
    /// keeping: nothing is left stored and the state stays signed out.
    func testASessionLeetCodeRejectsIsNotKept() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        transport.serve(.userStatus, body: Self.fixture("user-status-signed-out.json"))
        let store = InMemoryLeetCodeCredentialStore()
        let model = makeModel(tree: tree, transport: transport, store: store)

        await assertThrows(.notLoggedIn) {
            _ = try await model.signIn(with: self.credentials)
        }
        XCTAssertFalse(model.isSignedIn)
        XCTAssertNil(model.signedInUsername)
        XCTAssertNil(store.stored)
        XCTAssertEqual(model.lastError, .notLoggedIn)
    }

    /// The other half of the same rule: LeetCode rejects a session as readily
    /// with a 401/403 or an auth `errors` array as with `isSignedIn: false`, and
    /// a *thrown* rejection must leave exactly as little behind as the parsed
    /// one. Recording the failure and keeping the pair would put the Keychain
    /// item and every "Signed in" surface behind a session that is already dead.
    func testASessionRejectedByAnErrorIsNotKeptEither() async throws {
        let rejections: [(String, LeetCodeHTTPResponse)] = [
            (
                "graphql errors",
                LeetCodeHTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Self.fixture("errors-not-authenticated.json")
                )
            ),
            ("401", LeetCodeHTTPResponse(statusCode: 401, headers: [:], body: Data())),
            ("403", LeetCodeHTTPResponse(statusCode: 403, headers: [:], body: Data()))
        ]
        for (name, response) in rejections {
            let tree = makeTree()
            let transport = makeTransport()
            transport.serve(.userStatus, with: response)
            let store = InMemoryLeetCodeCredentialStore()
            let model = makeModel(tree: tree, transport: transport, store: store)

            await assertThrows(.notLoggedIn) {
                _ = try await model.signIn(with: self.credentials)
            }
            XCTAssertFalse(model.isSignedIn, name)
            XCTAssertNil(model.signedInUsername, name)
            XCTAssertNil(store.stored, name)
            XCTAssertEqual(model.lastError, .notLoggedIn, name)
        }
    }

    /// …and a failure that is *not* a rejection leaves the session alone: the
    /// cookies came out of a browser that had just signed in, and being offline
    /// says nothing about them.
    func testASignInThatCouldNotBeConfirmedKeepsTheSession() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        transport.fail(.userStatus, with: LeetCodeError.network(reason: "offline"))
        let store = InMemoryLeetCodeCredentialStore()
        let model = makeModel(tree: tree, transport: transport, store: store)

        await assertThrows(.network(reason: "offline")) {
            _ = try await model.signIn(with: self.credentials)
        }
        XCTAssertTrue(model.isSignedIn)
        XCTAssertEqual(store.stored, credentials)
        XCTAssertEqual(model.lastError, .network(reason: "offline"))
    }

    /// A Keychain that will not take the item does not undo a sign-in that
    /// worked; the session runs for this launch, exactly as a catalog whose cache
    /// cannot be written runs in memory.
    func testAKeychainFailureDoesNotFailTheSignIn() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let store = InMemoryLeetCodeCredentialStore()
        store.saveFails = true
        let model = makeModel(tree: tree, transport: transport, store: store)

        let username = try await model.signIn(with: credentials)

        XCTAssertEqual(username, "pisaka_tester")
        XCTAssertTrue(model.isSignedIn)
        XCTAssertTrue(model.lastCredentialSaveFailed)
        // …and the in-memory copy is what the next operation uses.
        let outcome = try await model.openProblem(input: .slug("two-sum"), language: swift)
        XCTAssertTrue(outcome.wasCreated)
    }

    func testRefreshingUserStatusFillsInTheNameAndCanClearIt() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        // A stored session is optimistically "signed in" before anything is
        // confirmed; the name arrives with the refresh.
        XCTAssertTrue(model.isSignedIn)
        XCTAssertNil(model.signedInUsername)

        _ = await model.refreshUserStatus()
        XCTAssertEqual(model.signedInUsername, "pisaka_tester")

        transport.serve(.userStatus, body: Self.fixture("user-status-signed-out.json"))
        _ = await model.refreshUserStatus()
        XCTAssertFalse(model.isSignedIn)
        XCTAssertNil(model.signedInUsername)
    }

    /// The launch call must not produce an alert: a refresh that could not be made
    /// leaves the state alone and reports nothing.
    func testAFailedUserStatusRefreshIsSilent() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        transport.fail(.userStatus)
        let model = makeModel(tree: tree, transport: transport)

        let status = await model.refreshUserStatus()

        XCTAssertNil(status)
        XCTAssertTrue(model.isSignedIn, "an unreachable LeetCode is not a sign-out")
        XCTAssertNil(model.lastError)
    }

    // MARK: - The statement panel

    func testAStatementIsServedFromTheCacheAndRefreshedBehindIt() async throws {
        let cached = "<p>yesterday's statement</p>"
        let tree = makeTree([twoSumPath: "solution", statementPath: cached])
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        let published = await model.statement(
            forFileAt: treeRoot.appendingPathComponent(twoSumPath),
            in: solutionsFolder
        )

        // What came back is the refreshed one; the cached one was published first
        // and then replaced.
        XCTAssertEqual(published?.isFromCache, false)
        XCTAssertNotEqual(published?.fragment, cached)
        XCTAssertEqual(model.statement?.slug, "two-sum")
        XCTAssertEqual(model.statement?.number, 1)
        XCTAssertEqual(tree.files[statementPath], published?.fragment)
    }

    /// The offline reopen: no network, a cached fragment, and — the point — **no
    /// error**, because the user is looking at the statement either way.
    func testACachedStatementSurvivesAnOfflineRefresh() async throws {
        let cached = "<p>yesterday's statement</p>"
        let tree = makeTree([twoSumPath: "solution", statementPath: cached])
        let transport = makeTransport()
        transport.fail(.question(slug: "two-sum"))
        let model = makeModel(tree: tree, transport: transport)

        let published = await model.statement(
            forFileAt: treeRoot.appendingPathComponent(twoSumPath),
            in: solutionsFolder
        )

        XCTAssertEqual(published?.fragment, cached)
        XCTAssertEqual(published?.isFromCache, true)
        XCTAssertEqual(model.statement?.fragment, cached)
        XCTAssertNil(model.lastError, "a failure behind a cached statement is not an error")
    }

    /// …and without a cache, the same failure *is* worth reporting: the panel has
    /// nothing to show.
    func testAFailedStatementWithNoCacheReportsTheFailure() async throws {
        let tree = makeTree([twoSumPath: "solution"])
        let transport = makeTransport()
        transport.fail(.question(slug: "two-sum"), with: LeetCodeError.network(reason: "offline"))
        let model = makeModel(tree: tree, transport: transport)

        let published = await model.statement(
            forFileAt: treeRoot.appendingPathComponent(twoSumPath),
            in: solutionsFolder
        )

        XCTAssertNil(published)
        XCTAssertNil(model.statement)
        XCTAssertEqual(model.lastError, .network(reason: "offline"))
    }

    /// Association is by file name **and** by location: the name rule alone is
    /// deliberately permissive, so a file of the same shape outside the LeetCode
    /// folder is not a LeetCode problem.
    func testAFileOutsideTheFolderIsNotAssociated() async throws {
        let outside = "Elsewhere/0001-two-sum.swift"
        let tree = makeTree([outside: "solution", statementPath: "<p>cached</p>"])
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        let published = await model.statement(
            forFileAt: treeRoot.appendingPathComponent(outside),
            in: solutionsFolder
        )

        XCTAssertNil(published)
        XCTAssertNil(model.statement)
        XCTAssertEqual(transport.sent.count, 0)
    }

    func testAFileWhoseNameIsNotOursIsNotAssociated() async throws {
        let tree = makeTree(["Solutions/notes.txt": "x"])
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        let published = await model.statement(
            forFileAt: treeRoot.appendingPathComponent("Solutions/notes.txt"),
            in: solutionsFolder
        )

        XCTAssertNil(published)
        XCTAssertEqual(transport.sent.count, 0)
    }

    func testSwitchingToANonLeetCodeTabClearsThePanel() async throws {
        let tree = makeTree([twoSumPath: "solution"])
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        _ = await model.statement(
            forFileAt: treeRoot.appendingPathComponent(twoSumPath),
            in: solutionsFolder
        )
        XCTAssertNotNil(model.statement)

        _ = await model.statement(forFileAt: nil, in: solutionsFolder)
        XCTAssertNil(model.statement)
    }

    /// The association is a pure question and is asked as one — both halves, in
    /// both directions.
    func testTheAssociationRuleReadsNameAndLocationTogether() {
        let tree = makeTree()
        let model = makeModel(tree: tree, transport: makeTransport())

        let parts = model.associatedProblem(
            forFileAt: treeRoot.appendingPathComponent(twoSumPath),
            in: solutionsFolder
        )
        XCTAssertEqual(parts?.number, 1)
        XCTAssertEqual(parts?.slug, "two-sum")

        XCTAssertNil(
            model.associatedProblem(
                forFileAt: treeRoot.appendingPathComponent("Elsewhere/0001-two-sum.swift"),
                in: solutionsFolder
            )
        )
        XCTAssertNil(
            model.associatedProblem(forFileAt: solutionsFolder, in: solutionsFolder),
            "the folder itself is not a solution file"
        )
    }

    // MARK: - Overlapping work

    /// Two opens in flight: the first one comes back to find the counter moved,
    /// so it publishes nothing and — because the write is on the far side of the
    /// last checkpoint — creates nothing either.
    func testASupersededOpenPublishesAndWritesNothing() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        transport.serve(
            .question(slug: "add-two-numbers"),
            json: """
                {"data":{"question":{"questionFrontendId":"2","title":"Add Two Numbers",\
                "titleSlug":"add-two-numbers","content":"<p>second</p>","difficulty":"Medium",\
                "isPaidOnly":false,"exampleTestcaseList":[],"codeSnippets":[\
                {"lang":"Swift","langSlug":"swift","code":"class Solution {}"}]}}}
                """
        )
        let gate = Gate()
        transport.hold(.question(slug: "two-sum"), on: gate)
        let model = makeModel(tree: tree, transport: transport)

        let first = Task { try await model.openProblem(input: .slug("two-sum"), language: swift) }
        await gate.waitUntilReached()
        // The second open starts while the first is suspended in its detail
        // request, which is what bumps the counter under it.
        let second = try await model.openProblem(
            input: .slug("add-two-numbers"),
            language: swift
        )
        gate.release()

        let firstOutcome = try await first.value
        XCTAssertEqual(firstOutcome, .superseded)
        XCTAssertTrue(second.wasCreated)
        XCTAssertNil(tree.files[twoSumPath], "a superseded open wrote its file anyway")
        XCTAssertEqual(tree.files["Solutions/0002-add-two-numbers.swift"]?.isEmpty, false)
        XCTAssertEqual(model.statement?.slug, "add-two-numbers")
    }

    /// The busy flag is a count, so the first of two overlapping operations
    /// finishing does not switch the spinner off under the second.
    ///
    /// Two operations are genuinely started, because one proves nothing about a
    /// counter: a plain `Bool` would pass a single-operation test identically.
    /// The statement refresh and the open are held on the same route, released
    /// one at a time.
    func testBusyTracksOverlappingOperations() async throws {
        let tree = makeTree([twoSumPath: "solution"])
        let transport = makeTransport()
        let gate = Gate()
        transport.hold(.question(slug: "two-sum"), on: gate)
        let model = makeModel(tree: tree, transport: transport)

        XCTAssertFalse(model.isBusy)
        let refresh = Task {
            await model.statement(
                forFileAt: self.solutionsFolder.appendingPathComponent("0001-two-sum.swift"),
                in: self.solutionsFolder
            )
        }
        await gate.waitUntilReached()
        XCTAssertTrue(model.isBusy)

        let opening = Task {
            try await model.openProblem(input: .slug("two-sum"), language: self.swift)
        }
        await gate.waitUntilReached()

        // The first of the two finishes; the counter must keep `isBusy` up for
        // the one still in flight.
        gate.release()
        _ = await refresh.value
        XCTAssertTrue(model.isBusy)

        gate.release()
        _ = try await opening.value
        XCTAssertFalse(model.isBusy)
    }

    /// `isOpening` is the counter the entry sheets bind to, and a statement
    /// refresh must not raise it.
    ///
    /// A single flag meant that selecting a LeetCode tab on a slow link and then
    /// pressing ⌘⇧P produced a sheet with a disabled field and a dead Open
    /// button, waiting on a request for a different tab.
    func testAStatementRefreshIsBusyButNotOpening() async throws {
        let tree = makeTree([twoSumPath: "solution"])
        let transport = makeTransport()
        let gate = Gate()
        transport.hold(.question(slug: "two-sum"), on: gate)
        let model = makeModel(tree: tree, transport: transport)

        let refresh = Task {
            await model.statement(
                forFileAt: self.solutionsFolder.appendingPathComponent("0001-two-sum.swift"),
                in: self.solutionsFolder
            )
        }
        await gate.waitUntilReached()
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.isOpening)
        gate.release()
        _ = await refresh.value
        XCTAssertFalse(model.isOpening)
    }

    func testOpeningRaisesIsOpening() async throws {
        let tree = makeTree([twoSumPath: "solution"])
        let transport = makeTransport()
        let gate = Gate()
        transport.hold(.question(slug: "two-sum"), on: gate)
        let model = makeModel(tree: tree, transport: transport)

        XCTAssertFalse(model.isOpening)
        let opening = Task {
            try await model.openProblem(input: .slug("two-sum"), language: self.swift)
        }
        await gate.waitUntilReached()
        XCTAssertTrue(model.isOpening)
        gate.release()
        _ = try await opening.value
        XCTAssertFalse(model.isOpening)
    }

    // MARK: - Not asking twice

    /// Opening a problem and then activating the tab it opened is **one**
    /// `questionData` request.
    ///
    /// `openProblem` already fetched the detail and cached it; the panel's
    /// refresh runs off a tab change, so without a record of what came off the
    /// network this run every open cost a second round trip against a
    /// rate-limited, unofficial API.
    func testOpeningAProblemDoesNotRefetchItsStatement() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        let outcome = try await model.openProblem(input: .number(1), language: swift)
        let url = try XCTUnwrap(outcome.solution?.url)
        XCTAssertEqual(transport.count(for: .question(slug: "two-sum")), 1)

        let published = await model.statement(forFileAt: url, in: solutionsFolder)
        XCTAssertEqual(published?.slug, "two-sum")
        XCTAssertEqual(transport.count(for: .question(slug: "two-sum")), 1)
    }

    /// Switching away from a LeetCode tab and back does not re-fetch either —
    /// the same rule, applied to the way the panel is actually driven.
    func testSwitchingBackToATabDoesNotRefetch() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        transport.serve(
            .question(slug: "add-two-numbers"),
            body: Self.fixture("question-detail.json")
        )
        let model = makeModel(tree: tree, transport: transport)

        let first = try await model.openProblem(input: .number(1), language: swift)
        let twoSum = try XCTUnwrap(first.solution?.url)
        let other = solutionsFolder.appendingPathComponent("0002-add-two-numbers.swift")

        _ = await model.statement(forFileAt: other, in: solutionsFolder)
        _ = await model.statement(forFileAt: twoSum, in: solutionsFolder)
        XCTAssertEqual(transport.count(for: .question(slug: "two-sum")), 1)
    }

    /// The panel's title survives a tab switch for a problem opened by slug.
    ///
    /// Two sources know a title and neither is available on that path: the
    /// catalog is only ever loaded to resolve a *number* (a slug resolves to
    /// itself), and the disk fragment cache stores markup with no title in it.
    /// So the refresh that a switch back is answered from had nothing but the
    /// slug to fall back on, and the header degraded from "1. Two Sum" to
    /// "1. two-sum" for the rest of the run — permanently, because that same
    /// refresh short-circuits before any fetch that could correct it.
    func testTheStatementTitleSurvivesATabSwitchWhenOpenedBySlug() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        let outcome = try await model.openProblem(input: .slug("two-sum"), language: swift)
        let url = try XCTUnwrap(outcome.solution?.url)
        XCTAssertEqual(model.statement?.title, "Two Sum")
        XCTAssertEqual(
            transport.count(for: .problemList),
            0,
            "a slug resolves to itself; the catalog is never loaded on this path"
        )

        _ = await model.statement(forFileAt: nil, in: solutionsFolder)
        let published = await model.statement(forFileAt: url, in: solutionsFolder)

        XCTAssertEqual(published?.title, "Two Sum")
        XCTAssertEqual(published?.isFromCache, true)
        XCTAssertEqual(model.statement?.title, "Two Sum")
    }

    /// A slug this run has *not* fetched is still fetched, cache or no cache —
    /// the disk cache is a head start, not a substitute for a refresh.
    func testACachedStatementFromALaunchAgoIsStillRefreshed() async throws {
        let tree = makeTree([statementPath: "<p>yesterday</p>"])
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)
        let url = solutionsFolder.appendingPathComponent("0001-two-sum.swift")

        let published = await model.statement(forFileAt: url, in: solutionsFolder)
        XCTAssertEqual(published?.isFromCache, false)
        XCTAssertEqual(transport.count(for: .question(slug: "two-sum")), 1)
    }

    /// Signing out forgets what was fetched, so the next session re-fetches
    /// rather than showing the previous account's cache as current.
    func testSigningOutForgetsWhatWasFetchedThisRun() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let store = InMemoryLeetCodeCredentialStore(credentials)
        let model = makeModel(tree: tree, transport: transport, store: store)

        let outcome = try await model.openProblem(input: .number(1), language: swift)
        let url = try XCTUnwrap(outcome.solution?.url)
        model.signOut()
        try await model.signIn(with: credentials)

        _ = await model.statement(forFileAt: url, in: solutionsFolder)
        XCTAssertEqual(transport.count(for: .question(slug: "two-sum")), 2)
    }

    /// A file whose name parses but whose problem does not exist is asked about
    /// **once**.
    ///
    /// The association rule is deliberately permissive, so a `2024-notes.md`
    /// dropped in the LeetCode folder is a plausible tab — and the panel's
    /// refresh runs on every tab change, which without a recorded negative would
    /// be one request per switch to it, forever, against a rate-limited API.
    func testASlugLeetCodeSaysDoesNotExistIsAskedAboutOnce() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        transport.serve(
            .question(slug: "notes"),
            body: Self.fixture("question-detail-unknown-slug.json")
        )
        let model = makeModel(tree: tree, transport: transport)
        let url = solutionsFolder.appendingPathComponent("2024-notes.md")
        let other = solutionsFolder.appendingPathComponent("0001-two-sum.swift")

        let first = await model.statement(forFileAt: url, in: solutionsFolder)
        _ = await model.statement(forFileAt: other, in: solutionsFolder)
        let second = await model.statement(forFileAt: url, in: solutionsFolder)

        XCTAssertNil(first)
        XCTAssertNil(second)

        XCTAssertEqual(transport.count(for: .question(slug: "notes")), 1)
    }

    /// A detail with **no content** is the other answer LeetCode gives about a
    /// slug, and is remembered the same way.
    ///
    /// A Premium problem answers `isPaidOnly: true` with a null `content`. The
    /// model refuses to *open* one, but a solution file for it can reach the
    /// folder another way (copied in, or written by hand), and without this the
    /// tab would issue a request that is permanently going to answer nothing,
    /// once per switch to it.
    func testAPremiumStatementIsAskedAboutOnce() async throws {
        let slug = "two-sum-iii-data-structure-design"
        let tree = makeTree()
        let transport = makeTransport()
        transport.serve(
            .question(slug: slug),
            body: Self.fixture("question-detail-paid-only.json")
        )
        let model = makeModel(tree: tree, transport: transport)
        let url = solutionsFolder.appendingPathComponent("0170-\(slug).swift")
        let other = solutionsFolder.appendingPathComponent("0001-two-sum.swift")

        let first = await model.statement(forFileAt: url, in: solutionsFolder)
        _ = await model.statement(forFileAt: other, in: solutionsFolder)
        let second = await model.statement(forFileAt: url, in: solutionsFolder)

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(transport.count(for: .question(slug: slug)), 1)
    }

    /// Signing *in* starts this run's conclusions over, exactly as signing out
    /// does — the two sets are the session's, not the app run's.
    ///
    /// The case that needs it: a session can end without a sign-out. LeetCode
    /// rejects one mid-run, the published state flips (the stored pair stays),
    /// and the user signs in again through the login sheet — with no `signOut()`
    /// anywhere in between. Without this, every slug this run had concluded was
    /// Premium-locked or absent under the dead session stays short-circuited for
    /// the rest of the app run, so a user who subscribes and signs back in never
    /// sees the statement the second session would have answered with.
    func testSigningInStartsThisRunsConclusionsOver() async throws {
        let slug = "two-sum-iii-data-structure-design"
        let tree = makeTree()
        let transport = makeTransport()
        transport.serve(
            .question(slug: slug),
            body: Self.fixture("question-detail-paid-only.json")
        )
        let model = makeModel(tree: tree, transport: transport)
        let url = solutionsFolder.appendingPathComponent("0170-\(slug).swift")

        _ = await model.statement(forFileAt: url, in: solutionsFolder)
        XCTAssertEqual(transport.count(for: .question(slug: slug)), 1)

        try await model.signIn(with: credentials)
        _ = await model.statement(forFileAt: url, in: solutionsFolder)

        XCTAssertEqual(transport.count(for: .question(slug: slug)), 2)
    }

    /// Only those two answers are remembered: offline is a failure to *ask*, so
    /// the next switch to the tab asks again.
    func testAStatementThatCouldNotBeFetchedIsRetried() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        transport.fail(.question(slug: "two-sum"), with: LeetCodeError.network(reason: "offline"))
        let model = makeModel(tree: tree, transport: transport)
        let url = solutionsFolder.appendingPathComponent("0001-two-sum.swift")

        _ = await model.statement(forFileAt: url, in: solutionsFolder)
        _ = await model.statement(forFileAt: nil, in: solutionsFolder)
        _ = await model.statement(forFileAt: url, in: solutionsFolder)

        XCTAssertEqual(transport.count(for: .question(slug: "two-sum")), 2)
    }

    /// Signing out does not blank the description panel.
    ///
    /// The statement is public content that is still in the fragment cache and is
    /// republished from it with no session at all — and the panel's refresh is
    /// keyed on the *file*, which a sign-out does not change, so clearing it here
    /// would leave the pane empty until the user switched tabs and back.
    func testSigningOutLeavesTheStatementStanding() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        _ = try await model.openProblem(input: .number(1), language: swift)
        XCTAssertEqual(model.statement?.slug, "two-sum")

        model.signOut()

        XCTAssertEqual(model.statement?.slug, "two-sum")
        XCTAssertFalse(model.isSignedIn)
    }

    /// Signing in re-asks the question the signed-out session could not answer.
    ///
    /// The panel's refresh is keyed on the tab and the folder, and a sign-in
    /// changes neither — so without this the user who signs in *because* the pane
    /// said they had to gets no statement until they switch tabs and back.
    func testSigningInReAsksTheStatementTheSignedOutSessionCouldNotFetch() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(
            tree: tree,
            transport: transport,
            store: InMemoryLeetCodeCredentialStore()
        )
        let url = solutionsFolder.appendingPathComponent("0001-two-sum.swift")

        let published = await model.statement(forFileAt: url, in: solutionsFolder)
        XCTAssertNil(published)
        XCTAssertNil(model.statement)
        XCTAssertEqual(model.lastError, .notLoggedIn)
        XCTAssertEqual(transport.count(for: .question(slug: "two-sum")), 0)

        try await model.signIn(with: credentials)

        XCTAssertEqual(model.statement?.slug, "two-sum")
        XCTAssertEqual(model.statement?.title, "Two Sum")
        XCTAssertEqual(transport.count(for: .question(slug: "two-sum")), 1)
        XCTAssertNil(model.lastError)
    }

    /// A tab that is not a solution file is not a question, so a sign-in has
    /// nothing to re-ask and asks nothing.
    func testSigningInWithNoStatementQuestionAsksNothing() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(
            tree: tree,
            transport: transport,
            store: InMemoryLeetCodeCredentialStore()
        )

        _ = await model.statement(forFileAt: nil, in: solutionsFolder)
        try await model.signIn(with: credentials)

        XCTAssertNil(model.statement)
        XCTAssertEqual(transport.count(for: .question(slug: "two-sum")), 0)
    }

    /// A refresh nobody is waiting for reports nothing.
    ///
    /// The panel's request lives in a view's `.task`, cancelled when the window
    /// closes or the app is backgrounded mid-fetch; `URLSession` then throws and
    /// the failure arrives here as an ordinary network error. The generation guard
    /// does not cover it — there is no *replacement* request to bump the token —
    /// so without the cancellation check a "could not reach LeetCode: cancelled"
    /// would sit on `lastError` until the next operation cleared it.
    func testACancelledStatementRefreshReportsNothing() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        transport.fail(
            .question(slug: "two-sum"),
            with: LeetCodeError.network(reason: "cancelled")
        )
        let gate = Gate()
        transport.hold(.question(slug: "two-sum"), on: gate)
        let model = makeModel(tree: tree, transport: transport)

        let refresh = Task {
            await model.statement(
                forFileAt: self.solutionsFolder.appendingPathComponent("0001-two-sum.swift"),
                in: self.solutionsFolder
            )
        }
        await gate.waitUntilReached()
        refresh.cancel()
        gate.release()
        let published = await refresh.value

        XCTAssertNil(published)
        XCTAssertNil(model.lastError)
        XCTAssertTrue(model.isSignedIn, "a request nobody waited for says nothing about the session")
    }

    /// A statement that arrived clears a sentence describing a failure that is
    /// no longer the state of anything.
    func testASuccessfulStatementRefreshClearsAStaleError() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        transport.fail(.question(slug: "two-sum"), with: LeetCodeError.network(reason: "offline"))
        let model = makeModel(tree: tree, transport: transport)
        let url = solutionsFolder.appendingPathComponent("0001-two-sum.swift")

        _ = await model.statement(forFileAt: url, in: solutionsFolder)
        XCTAssertEqual(model.lastError, .network(reason: "offline"))

        transport.serve(.question(slug: "two-sum"), body: Self.fixture("question-detail.json"))
        _ = await model.statement(forFileAt: url, in: solutionsFolder)
        XCTAssertNil(model.lastError)
    }

    // MARK: - The account, when the world does not cooperate

    /// A launch-time refresh that LeetCode *rejects* flips the published state.
    ///
    /// Swallowing it with the failures that are genuinely silent (offline,
    /// throttled) left a dead session reading as signed in — account name in the
    /// menu and all — until the user tried to open something.
    func testARejectedUserStatusRefreshFlipsSignedIn() async throws {
        for status in [401, 403] {
            let tree = makeTree()
            let transport = ScriptedLeetCodeTransport()
            transport.serve(.userStatus, json: "{}", statusCode: status)
            let model = makeModel(tree: tree, transport: transport)

            XCTAssertTrue(model.isSignedIn)
            let answer = await model.refreshUserStatus()
            XCTAssertNil(answer)
            XCTAssertFalse(model.isSignedIn, "HTTP \(status) left the session looking alive")
            XCTAssertNil(model.signedInUsername)
        }
    }

    /// Everything that is *not* a rejection stays silent and optimistic: the
    /// session is probably fine and the app must not show "signed out" because a
    /// train went into a tunnel.
    func testAFailedUserStatusRefreshLeavesTheSessionAlone() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.fail(.userStatus)
        let model = makeModel(tree: tree, transport: transport)

        _ = await model.refreshUserStatus()
        XCTAssertTrue(model.isSignedIn)
    }

    /// A refresh superseded by a sign-out publishes nothing — the account
    /// generation, which nothing else asserts.
    func testASupersededUserStatusRefreshPublishesNothing() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let gate = Gate()
        transport.hold(.userStatus, on: gate)
        let model = makeModel(tree: tree, transport: transport)

        let refresh = Task { await model.refreshUserStatus() }
        await gate.waitUntilReached()
        model.signOut()
        gate.release()
        _ = await refresh.value

        // The fixture names an account; the sign-out must survive it landing.
        XCTAssertFalse(model.isSignedIn)
        XCTAssertNil(model.signedInUsername)
    }

    /// Signing out holds even when the Keychain refuses the delete.
    ///
    /// Every credential lookup falls back to the store, so a `clear()` that
    /// threw used to leave the pair on disk for the very next open to read back
    /// out — succeeding, and writing a file, while the app showed "signed out".
    func testSigningOutHoldsWhenTheKeychainRefusesTheDelete() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let store = InMemoryLeetCodeCredentialStore(credentials)
        store.clearFails = true
        let model = makeModel(tree: tree, transport: transport, store: store)

        model.signOut()
        XCTAssertFalse(model.isSignedIn)
        XCTAssertNotNil(store.stored, "the stub must still be holding the pair")

        await assertThrows(.notLoggedIn) {
            _ = try await model.openProblem(input: .number(1), language: self.swift)
        }
        XCTAssertTrue(self.solutionWrites(tree).isEmpty)
    }

    /// Signing back in after that re-arms the store: the flag is about the
    /// sign-out, not a permanent refusal to read the Keychain.
    func testSigningInAfterAFailedClearWorksAgain() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let store = InMemoryLeetCodeCredentialStore(credentials)
        store.clearFails = true
        let model = makeModel(tree: tree, transport: transport, store: store)

        model.signOut()
        try await model.signIn(with: credentials)
        let outcome = try await model.openProblem(input: .number(1), language: swift)
        XCTAssertTrue(outcome.wasCreated)
    }

    // MARK: - Never overwrite

    /// A folder whose listing fails refuses the write rather than assuming the
    /// file is not there.
    ///
    /// This is the one irreversible action in the integration. A folder that is
    /// searchable but not readable used to take the identical path an absent
    /// file takes — straight to `write` — and silently replace a half-finished
    /// solution with a fresh snippet.
    func testAnUnlistableFolderRefusesToWriteRatherThanOverwrite() async throws {
        let tree = makeTree([twoSumPath: "// the user's half-finished solution"])
        tree.unreadableDirectories = ["Solutions"]
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        do {
            _ = try await model.openProblem(input: .number(1), language: swift)
            XCTFail("expected the open to refuse")
        } catch let error as LeetCodeError {
            guard case .fileSystem = error else {
                return XCTFail("expected .fileSystem, got \(error)")
            }
        }
        XCTAssertTrue(solutionWrites(tree).isEmpty)
        XCTAssertEqual(tree.files[twoSumPath], "// the user's half-finished solution")
    }

    // MARK: - Not a writer

    /// The model is a reader with exactly one create: the only things it writes
    /// are its own cache and the solution file, and only when that file does not
    /// exist.
    func testTheOnlyFilesWrittenAreTheCacheAndTheNewSolution() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        _ = try await model.openProblem(input: .number(1), language: swift)

        XCTAssertEqual(
            Set(tree.writtenPaths),
            [catalogPath, statementPath, twoSumPath]
        )
    }
}
