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
        "reverse-prefix-of-word",
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

    /// A catalog response in the wire shape, for the one thing the recorded
    /// fixture cannot express: the *same* rows under a different account's status
    /// marks, which is what the second fetch in the cross-account test returns.
    private func problemListJSON(
        _ rows: [(id: Int, slug: String)],
        status: String = "null"
    ) -> String {
        let pairs = rows.map { row in
            """
            {"stat":{"frontend_question_id":\(row.id),\
            "question__title":"\(row.slug)",\
            "question__title_slug":"\(row.slug)"},\
            "status":\(status),"difficulty":{"level":1},"paid_only":false}
            """
        }
        return "{\"user_name\":\"\",\"stat_status_pairs\":[\(pairs.joined(separator: ","))]}"
    }

    /// A cache written an hour ago: warm, so nothing may be fetched for it.
    private func warmCache() -> [String: String] {
        [
            catalogPath: cacheJSON(
                fetchedAt: "2026-08-11T11:00:00Z",
                rows: [(1, "two-sum"), (2, "add-two-numbers")]
            ),
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

    /// The spinner is on **while** the fetch is out, not merely off once it lands.
    ///
    /// Asserted mid-flight because every surface hangs something on it that the
    /// end state cannot see: the macOS footer's `ProgressView` and its "Loading…"
    /// line, its disabled Refresh button, and the iOS empty-state overlay, which is
    /// suppressed by exactly this flag — with it stuck off, a cold first fetch
    /// renders "No problems loaded" over a list that is on its way.
    func testTheSpinnerIsOnWhileTheFetchIsInFlight() async {
        let tree = makeTree()
        let transport = makeTransport()
        let gate = Gate()
        transport.hold(.problemList, on: gate)
        let model = makeModel(tree: tree, transport: transport)
        let browser = model.browser

        let load = Task { await browser.load() }
        await gate.waitUntilReached()

        XCTAssertTrue(browser.isLoading)
        XCTAssertTrue(browser.problems.isEmpty)
        XCTAssertNil(browser.lastError)

        gate.release()
        await load.value

        XCTAssertFalse(browser.isLoading)
        XCTAssertEqual(browser.problems.count, 12)
    }

    /// The view's task went away mid-fetch (the window closed, the screen was
    /// popped): that publishes **nothing** — the user withdrew the question — but
    /// the spinner still has to come down, because nobody else will lower it.
    func testACancelledLoadPublishesNothingAndStillClearsTheSpinner() async {
        let tree = makeTree()
        let transport = makeTransport()
        let gate = Gate()
        transport.hold(.problemList, on: gate)
        let model = makeModel(tree: tree, transport: transport)
        let browser = model.browser

        let load = Task { await browser.load() }
        await gate.waitUntilReached()
        load.cancel()
        gate.release()
        await load.value

        XCTAssertEqual(transport.count(for: .problemList), 1)
        XCTAssertTrue(browser.problems.isEmpty)
        XCTAssertTrue(browser.visibleProblems.isEmpty)
        XCTAssertNil(browser.fetchedAt)
        // A cancellation is not a failure the user asked about, so no sentence is
        // published for it either.
        XCTAssertNil(browser.lastError)
        XCTAssertFalse(browser.isLoading)
        XCTAssertEqual(browser.availability, .ready)
    }

    /// The browser's cancellation stops at the browser: the **shared** catalog
    /// fetch it was waiting on runs on to completion.
    ///
    /// `LeetCodeCatalog.refresh` cancels the one coalesced 2 MB download when the
    /// caller awaiting it is cancelled — right for the Open Problem sheet, whose
    /// canceller is an explicit Esc. This surface's canceller is SwiftUI tearing
    /// down a `.task` because a window closed, and an open coalesced onto the same
    /// download would then have failed with "cancelled" for a question its user
    /// never withdrew. A *sleeping* delay rather than `Gate`, for the reason
    /// `LeetCodeModelTests` states: only a cancellable wait can show whether
    /// cancellation reached the request.
    func testACancelledLoadLeavesTheSharedCatalogFetchRunning() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.userStatus, body: Self.fixture("user-status-signed-in.json"))
        transport.serve(.problemList, body: Self.fixture("problem-list.json"), delay: 0.2)
        let model = makeModel(tree: tree, transport: transport)

        let load = Task { await model.browser.load() }
        while transport.count(for: .problemList) == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        load.cancel()
        await load.value

        // The browser itself publishes nothing — its own question was withdrawn.
        XCTAssertTrue(model.browser.problems.isEmpty)
        XCTAssertNil(model.browser.lastError)
        XCTAssertFalse(model.browser.isLoading)
        // But the download landed, so anything coalesced onto it was answered
        // rather than failed.
        XCTAssertEqual(model.catalog.problems.count, 12)
        XCTAssertEqual(transport.count(for: .problemList), 1)
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

    /// **Signing in under a flag that is already raised still clears the rows.**
    ///
    /// The hole the `isSignedIn` observer alone leaves: its `didSet` is guarded on
    /// the flag *moving*, and `signIn(with:)` is reached with it already `true`
    /// whenever `markSessionAccepted()` has put a rejected session back — the
    /// ordinary shape when a request answers while the login sheet the rejection
    /// opened is still up. Without the second hook
    /// (`LeetCodeModel.invalidateInFlightWork()` → `browser`), the previous
    /// account's rows and its per-account solved marks stayed standing under the
    /// next account's name, which is the one wrong thing this list can show.
    func testSigningInUnderAnAlreadyRaisedFlagStillClearsTheRows() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)
        let browser = model.browser

        await browser.load()
        XCTAssertEqual(browser.problems.first?.status, .solved)
        XCTAssertNotNil(browser.fetchedAt)

        // No sign-out in between: the flag never moves, so the observer never runs.
        XCTAssertTrue(model.isSignedIn)
        try await model.signIn(with: credentials)
        XCTAssertTrue(model.isSignedIn)

        XCTAssertEqual(browser.availability, .ready)
        XCTAssertTrue(browser.problems.isEmpty)
        XCTAssertTrue(browser.visibleProblems.isEmpty)
        XCTAssertNil(browser.fetchedAt)
        XCTAssertNil(browser.lastError)
        XCTAssertFalse(browser.isLoading)
    }

    /// **Clearing the rows re-arms the load.** The other half of the hook above:
    /// both surfaces run their automatic load from `.task(id: browser.loadKey)`,
    /// so a session replacement that cleared the rows without moving that key
    /// would leave the browser sitting on an empty list after a *successful*
    /// sign-in until the user pressed Refresh by hand.
    ///
    /// `availability` alone cannot be that key, and this is exactly the case that
    /// proves it: it is `.ready` on both sides of the replacement. The epoch is
    /// what moves.
    func testSigningInUnderAnAlreadyRaisedFlagReArmsTheLoad() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)
        let browser = model.browser

        await browser.load()
        let before = browser.loadKey
        XCTAssertEqual(before.availability, .ready)

        XCTAssertTrue(model.isSignedIn)
        try await model.signIn(with: credentials)
        XCTAssertTrue(model.isSignedIn)

        // Availability did not move — the whole point — so the key had to.
        XCTAssertEqual(browser.loadKey.availability, .ready)
        XCTAssertNotEqual(browser.loadKey, before)
        XCTAssertGreaterThan(browser.loadKey.sessionEpoch, before.sessionEpoch)

        // And the re-armed load is the one that puts the rows back.
        await browser.load()
        XCTAssertEqual(browser.problems.count, 12)
        XCTAssertEqual(browser.visibleProblems.count, 12)
        XCTAssertNotNil(browser.fetchedAt)
    }

    /// Signing out moves the key too, so the surface's task re-runs and answers
    /// the sign-in offer rather than holding the previous account's list.
    func testSigningOutMovesTheLoadKey() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)
        let browser = model.browser

        await browser.load()
        let before = browser.loadKey

        model.signOut()
        XCTAssertNotEqual(browser.loadKey, before)
        XCTAssertEqual(browser.loadKey.availability, .notSignedIn)
    }

    /// The same hole on the token's axis: a load held mid-fetch while a sign-in
    /// under an already-raised flag replaces the session publishes **nothing at
    /// all** — the rule `testALoadSupersededByASignOutPublishesNothing` states,
    /// through the door the observer cannot see.
    func testALoadSupersededBySigningInUnderARaisedFlagPublishesNothing() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let gate = Gate()
        transport.hold(.problemList, on: gate)
        let model = makeModel(tree: tree, transport: transport)
        let browser = model.browser

        let load = Task { await browser.load() }
        await gate.waitUntilReached()
        try await model.signIn(with: credentials)
        gate.release()
        await load.value

        // The catalog published — it is a cache, not a surface — and the browser,
        // whose rows are per-account, did not.
        XCTAssertEqual(model.catalog.problems.count, 12)
        XCTAssertTrue(browser.problems.isEmpty)
        XCTAssertTrue(browser.visibleProblems.isEmpty)
        XCTAssertNil(browser.fetchedAt)
        XCTAssertNil(browser.lastError)
        XCTAssertFalse(browser.isLoading)
        XCTAssertEqual(browser.availability, .ready)
    }

    /// A catalog response that says logged-out flips the account state here too —
    /// the rule the model and the judge both follow, on the browser's axis.
    ///
    /// **And the sentence survives the flip**, which is the assertion with teeth:
    /// `markSessionRejected()` re-enters `sessionDidChange()`, which clears
    /// `lastError` with the rows, so recording the failure *before* it — the order
    /// `LeetCodeModel.publish` happens to use — would leave the footer blank about
    /// a browser that had just emptied itself.
    func testANotLoggedInCatalogFailureFlipsTheAccountAndKeepsTheSentence() async {
        let tree = makeTree(warmCache())
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)
        let browser = model.browser

        await browser.load()
        XCTAssertEqual(browser.problems.count, 2)

        transport.fail(.problemList, with: LeetCodeError.notLoggedIn)
        await browser.refresh()

        XCTAssertFalse(model.isSignedIn)
        XCTAssertEqual(browser.availability, .notSignedIn)
        XCTAssertEqual(browser.lastError, .notLoggedIn)
        // The rows went with the session: the status column is per-account.
        XCTAssertTrue(browser.problems.isEmpty)
        XCTAssertTrue(browser.visibleProblems.isEmpty)
        XCTAssertNil(browser.fetchedAt)
        XCTAssertFalse(browser.isLoading)
    }

    /// The limit L24 states rather than hides: the catalog's cache is per *app*,
    /// not per account, so signing in as somebody else inside the staleness window
    /// republishes the previous account's marks — and Refresh is what corrects
    /// them. Pinned in both directions so neither half can drift from the doc.
    func testAnotherAccountSeesTheCachedMarksUntilARefresh() async throws {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)
        let browser = model.browser

        await browser.load()
        XCTAssertEqual(browser.problems.first?.status, .solved)
        XCTAssertEqual(transport.count(for: .problemList), 1)

        model.signOut()
        try await model.signIn(with: credentials)
        // The next account solved none of them.
        transport.serve(
            .problemList,
            json: problemListJSON([(1, "two-sum"), (2, "add-two-numbers")])
        )

        await browser.load()
        // Still warm, so no request was made and the marks are the last account's.
        XCTAssertEqual(transport.count(for: .problemList), 1)
        XCTAssertEqual(browser.problems.count, 12)
        XCTAssertEqual(browser.problems.first?.status, .solved)

        await browser.refresh()

        XCTAssertEqual(transport.count(for: .problemList), 2)
        XCTAssertEqual(browser.problems.map(\.slug), ["two-sum", "add-two-numbers"])
        XCTAssertEqual(browser.problems.map(\.status), [.notStarted, .notStarted])
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

        // **Nor did the catalog**, which is the one place a superseded session can
        // still do damage: those rows carry the departing account's `status`, and
        // publishing them stamps a fresh `fetchedAt` on a cache the *next* account
        // then inherits for a day (the L24 window) instead of fetching its own. A
        // sign-out starts no refresh of its own, so the catalog's generation never
        // moves and only the session it was told about answers this.
        XCTAssertTrue(model.catalog.problems.isEmpty)
        XCTAssertTrue(browser.problems.isEmpty)
        XCTAssertTrue(browser.visibleProblems.isEmpty)
        XCTAssertNil(browser.fetchedAt)
        XCTAssertNil(browser.lastError)
        XCTAssertFalse(browser.isLoading)
        XCTAssertEqual(browser.availability, .notSignedIn)
    }

    // MARK: - Filtering

    /// Rows landing under a filter that is *already* set arrive narrowed.
    ///
    /// The realistic first run, and the one order the "set the filter, then look"
    /// test cannot see: the surface appears, the cold fetch goes out, the user
    /// starts typing, and the rows come back. Adopting the catalog has to re-run
    /// the filter rather than show everything until the next keystroke.
    func testRowsLandingUnderAFilterAlreadySetArriveNarrowed() async {
        let tree = makeTree()
        let transport = makeTransport()
        let model = makeModel(tree: tree, transport: transport)
        let browser = model.browser

        browser.filter.query = "two"
        await browser.load()

        XCTAssertEqual(browser.problems.count, 12)
        XCTAssertEqual(
            browser.visibleProblems.map(\.slug),
            [
                "two-sum",
                "add-two-numbers",
                "median-of-two-sorted-arrays",
                "two-sum-iii-data-structure-design",
            ]
        )
    }

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
                "two-sum-iii-data-structure-design",
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
