import XCTest
@testable import PisakaCore

/// The browser is the fifth generation token and the second reader in this area,
/// so this suite is about *what reaches the screen* rather than about filtering
/// (that is `LeetCodeProblemFilterTests`, a pure table) or about the catalog's
/// policy (that is `LeetCodeCatalogTests`, a request count).
///
/// Three properties carry it:
///
/// - **The browser adds no wire surface.** Re-entering it inside the staleness
///   window costs nothing at all, and typing in the search field costs nothing
///   ever — both asserted as `count(for: .problemList)`.
/// - **A refresh that could not be made keeps the rows it has.** The list somebody
///   is reading must not blank because the network went away; the typed error goes
///   *beside* the rows, and only stands alone when there are none.
/// - **A session change wins over anything in flight.** Signing out clears the
///   per-account status marks and bumps the token, and a load held mid-fetch then
///   publishes nothing at all — not rows, not an error, not a spinner left
///   running.
@MainActor
final class LeetCodeBrowserModelTests: XCTestCase {

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

    private static let iso = ISO8601DateFormatter()

    private static func date(_ text: String) -> Date {
        guard let date = iso.date(from: text) else {
            preconditionFailure("bad fixture date \(text)")
        }
        return date
    }

    /// The tests' "now" — the catalog's staleness clock is injected through the
    /// model, so "a cache written an hour ago" and "one written last week" are
    /// both a string in the file rather than a wait.
    private let now = LeetCodeBrowserModelTests.date("2026-08-11T12:00:00Z")

    private let treeRoot = URL(fileURLWithPath: "/leetcode-browser-tests")
    private var cacheBase: URL { treeRoot.appendingPathComponent("cache") }
    private var solutionsFolder: URL { treeRoot.appendingPathComponent("Solutions") }
    private let catalogPath = "cache/catalog.json"

    /// Every slug in the recorded 12-row catalog, in LeetCode's own order — the
    /// order the browser must preserve.
    private let recordedSlugs = [
        "two-sum",
        "add-two-numbers",
        "median-of-two-sorted-arrays",
        "merge-k-sorted-lists",
        "trapping-rain-water",
        "best-time-to-buy-and-sell-stock",
        "lru-cache",
        "two-sum-iii-data-structure-design",
        "number-of-islands",
        "serialize-and-deserialize-binary-tree",
        "greatest-common-divisor-of-strings",
        "reverse-prefix-of-word"
    ]

    private func makeTree(_ files: [String: String] = [:]) -> StubFileTree {
        StubFileTree(root: treeRoot, files: files)
    }

    private func makeTransport() -> ScriptedLeetCodeTransport {
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.userStatus, body: Self.fixture("user-status-signed-in.json"))
        transport.serve(.problemList, body: Self.fixture("problem-list.json"))
        return transport
    }

    private func makeModel(
        tree: StubFileTree,
        transport: ScriptedLeetCodeTransport,
        signedIn: Bool = true
    ) -> LeetCodeModel {
        LeetCodeModel(
            transport: transport,
            credentialStore: InMemoryLeetCodeCredentialStore(signedIn ? credentials : nil),
            fileService: tree,
            cacheLayout: LeetCodeCacheLayout(base: cacheBase),
            solutionsFolder: solutionsFolder,
            now: { self.now }
        )
    }

    /// A cache file in the documented on-disk shape, hand-written for the same
    /// reason `LeetCodeCatalogTests` writes one: the format is pinned by something
    /// other than the code that writes it.
    private func cacheJSON(
        fetchedAt: String,
        rows: [(id: Int, slug: String)],
        status: String = "notStarted"
    ) -> String {
        let problems = rows.map { row in
            """
            {"difficulty":"easy","id":\(row.id),"isPaidOnly":false,\
            "slug":"\(row.slug)","status":"\(status)","title":"\(row.slug)"}
            """
        }
        return """
            {"fetchedAt":"\(fetchedAt)","problems":[\(problems.joined(separator: ","))],\
            "schemaVersion":1}
            """
    }

    /// A cache written an hour ago: warm, so nothing may be fetched for it.
    private func warmCache() -> [String: String] {
        [
            catalogPath: cacheJSON(
                fetchedAt: "2026-08-11T11:00:00Z",
                rows: [(1, "two-sum"), (2, "add-two-numbers")]
            )
        ]
    }

    // MARK: - Loading

    /// The browser adds no wire surface: a catalog inside the staleness window is
    /// read off the disk and the list is on screen without a request.
    func testAWarmDiskCacheLoadsWithoutARequest() async {
        let tree = makeTree(warmCache())
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        await model.browser.load()

        let browser = model.browser
        XCTAssertEqual(transport.count(for: .problemList), 0)
        XCTAssertEqual(browser.problems.map(\.slug), ["two-sum", "add-two-numbers"])
        XCTAssertEqual(browser.visibleProblems.map(\.slug), ["two-sum", "add-two-numbers"])
        XCTAssertEqual(browser.fetchedAt, Self.date("2026-08-11T11:00:00Z"))
        XCTAssertEqual(browser.availability, .ready)
        XCTAssertNil(browser.availability.reason)
        XCTAssertNil(browser.lastError)
        XCTAssertFalse(browser.isLoading)
    }

    /// No cache is stale, so the first appearance fetches — once, and re-entering
    /// the surface afterwards costs nothing.
    func testAColdBrowserFetchesOnceAndPublishesTheRows() async {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        await model.browser.load()

        let browser = model.browser
        XCTAssertEqual(transport.count(for: .problemList), 1)
        XCTAssertEqual(browser.problems.map(\.slug), recordedSlugs)
        XCTAssertEqual(browser.visibleProblems.map(\.slug), recordedSlugs)
        XCTAssertEqual(browser.fetchedAt, now)
        XCTAssertNil(browser.lastError)
        XCTAssertFalse(browser.isLoading)
        // The per-account column arrived with the same response — this is the
        // freshness the surface labels with `fetchedAt`.
        XCTAssertEqual(browser.problems.first?.status, .solved)
        XCTAssertEqual(browser.problems.dropFirst().first?.status, .attempted)
        // The Premium row is in the list, at its own number, exactly as LeetCode
        // orders it: it is marked, never hidden.
        XCTAssertEqual(browser.problems.first { $0.isPaidOnly }?.frontendID, 170)

        await model.browser.load()
        XCTAssertEqual(transport.count(for: .problemList), 1)
    }

    /// The explicit affordance: Refresh fetches whatever the age, which is the
    /// only way a solved mark from five minutes ago reaches the screen.
    func testRefreshFetchesInsideTheStalenessWindow() async {
        let tree = makeTree(warmCache())
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        await model.browser.load()
        XCTAssertEqual(transport.count(for: .problemList), 0)

        await model.browser.refresh()

        let browser = model.browser
        XCTAssertEqual(transport.count(for: .problemList), 1)
        XCTAssertEqual(browser.problems.map(\.slug), recordedSlugs)
        XCTAssertEqual(browser.fetchedAt, now)
        XCTAssertNil(browser.lastError)
        XCTAssertFalse(browser.isLoading)
    }

    // MARK: - Degradation

    /// `resolveSlug`'s rule on a new axis: a refresh that could not be made must
    /// not blank the list somebody is reading.
    func testAFailingRefreshKeepsTheRowsAndPublishesTheError() async {
        let tree = makeTree(warmCache())
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)

        await model.browser.load()
        transport.fail(.problemList, with: LeetCodeError.network(reason: "offline"))
        await model.browser.refresh()

        let browser = model.browser
        XCTAssertEqual(transport.count(for: .problemList), 1)
        XCTAssertEqual(browser.problems.map(\.slug), ["two-sum", "add-two-numbers"])
        XCTAssertEqual(browser.visibleProblems.map(\.slug), ["two-sum", "add-two-numbers"])
        XCTAssertEqual(browser.fetchedAt, Self.date("2026-08-11T11:00:00Z"))
        XCTAssertEqual(browser.lastError, .network(reason: "offline"))
        XCTAssertEqual(browser.availability, .ready)
        XCTAssertFalse(browser.isLoading)
    }

    /// With no rows anywhere the error stands alone — the other half of the same
    /// rule.
    func testAFailingFirstLoadPublishesTheErrorWithNoRows() async {
        let tree = makeTree()
        let transport = makeTransport()
        transport.fail(.problemList, with: LeetCodeError.throttled(retryAfter: 30))
        let model = makeModel(tree: tree, transport: transport)

        await model.browser.load()

        let browser = model.browser
        XCTAssertEqual(transport.count(for: .problemList), 1)
        XCTAssertTrue(browser.problems.isEmpty)
        XCTAssertTrue(browser.visibleProblems.isEmpty)
        XCTAssertNil(browser.fetchedAt)
        XCTAssertEqual(browser.lastError, .throttled(retryAfter: 30))
        // Signed in and simply unable to fetch: the offer to sign in would be the
        // wrong sentence here.
        XCTAssertEqual(browser.availability, .ready)
        XCTAssertFalse(browser.isLoading)
    }

    // MARK: - The session

    /// Signed out is a value the surface renders, not an error dump — and it
    /// costs no request.
    func testSignedOutPublishesTheOfferAndMakesNoRequest() async {
        let tree = makeTree(warmCache())
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport, signedIn: false)

        await model.browser.load()

        let browser = model.browser
        XCTAssertEqual(transport.count(for: .problemList), 0)
        XCTAssertEqual(browser.availability, .notSignedIn)
        XCTAssertEqual(browser.availability.reason, "Sign in to LeetCode to browse problems.")
        XCTAssertTrue(browser.problems.isEmpty)
        XCTAssertNil(browser.lastError)
        XCTAssertFalse(browser.isLoading)
        // Nothing was read off the disk either: the offer is answered before the
        // catalog is consulted at all.
        XCTAssertEqual(tree.readPaths, [])
    }

    /// Signing in re-arms the surface, and signing out takes the rows with it: the
    /// status column is per-account, and one account's solved marks under
    /// another's name is the one wrong thing this list could show.
    func testSigningInReArmsAvailabilityAndSigningOutClearsTheRows() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport, signedIn: false)
        let browser = model.browser

        XCTAssertEqual(browser.availability, .notSignedIn)

        try await model.signIn(with: credentials)
        XCTAssertEqual(browser.availability, .ready)

        await browser.load()
        XCTAssertEqual(browser.problems.count, 12)
        XCTAssertEqual(browser.visibleProblems.count, 12)
        XCTAssertNotNil(browser.fetchedAt)

        model.signOut()
        XCTAssertEqual(browser.availability, .notSignedIn)
        XCTAssertTrue(browser.problems.isEmpty)
        XCTAssertTrue(browser.visibleProblems.isEmpty)
        XCTAssertNil(browser.fetchedAt)
        XCTAssertNil(browser.lastError)
        XCTAssertFalse(browser.isLoading)
    }

    /// The fifth generation token: a load held mid-fetch while the session goes
    /// away publishes **nothing at all** — not the rows it fetched, not an error,
    /// and not a spinner left running.
    func testALoadSupersededByASignOutPublishesNothing() async {
        let tree = makeTree()
        let transport = makeTransport()
        let gate = Gate()
        transport.hold(.problemList, on: gate)
        let model = makeModel(tree: tree, transport: transport)
        let browser = model.browser

        let load = Task { await browser.load() }
        await gate.waitUntilReached()
        model.signOut()
        gate.release()
        await load.value

        // The catalog itself did publish — it is a cache, not a surface — and the
        // browser deliberately did not.
        XCTAssertEqual(model.catalog.problems.count, 12)
        XCTAssertTrue(browser.problems.isEmpty)
        XCTAssertTrue(browser.visibleProblems.isEmpty)
        XCTAssertNil(browser.fetchedAt)
        XCTAssertNil(browser.lastError)
        XCTAssertFalse(browser.isLoading)
        XCTAssertEqual(browser.availability, .notSignedIn)
    }

    // MARK: - Filtering

    /// Setting the filter republishes the visible rows and touches nothing else —
    /// the browser searches instantly because the whole list is already in hand.
    func testSettingTheFilterRepublishesWithoutTouchingTheTransport() async {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)
        let browser = model.browser

        await browser.load()
        XCTAssertEqual(transport.count(for: .problemList), 1)

        browser.filter.query = "two"
        XCTAssertEqual(
            browser.visibleProblems.map(\.slug),
            [
                "two-sum",
                "add-two-numbers",
                "median-of-two-sorted-arrays",
                "two-sum-iii-data-structure-design"
            ]
        )

        // A second dimension narrows the same rows further, and the Premium one is
        // still there to be marked.
        browser.filter.difficulties = [.easy]
        XCTAssertEqual(
            browser.visibleProblems.map(\.slug),
            ["two-sum", "two-sum-iii-data-structure-design"]
        )

        browser.filter = LeetCodeProblemFilter()
        XCTAssertEqual(browser.visibleProblems.map(\.slug), recordedSlugs)

        // Every one of those was a pure pass over rows in hand.
        XCTAssertEqual(transport.count(for: .problemList), 1)
        XCTAssertEqual(browser.problems.count, 12)
    }
}
