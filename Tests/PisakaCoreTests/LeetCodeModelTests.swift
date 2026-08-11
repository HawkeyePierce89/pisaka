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
    func testBusyTracksOverlappingOperations() async throws {
        let tree = makeTree([twoSumPath: "solution"])
        let transport = makeTransport()
        let gate = Gate()
        transport.hold(.question(slug: "two-sum"), on: gate)
        let model = makeModel(tree: tree, transport: transport)

        XCTAssertFalse(model.isBusy)
        let running = Task {
            try await model.openProblem(input: .slug("two-sum"), language: swift)
        }
        await gate.waitUntilReached()
        XCTAssertTrue(model.isBusy)
        gate.release()
        _ = try await running.value
        XCTAssertFalse(model.isBusy)
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
