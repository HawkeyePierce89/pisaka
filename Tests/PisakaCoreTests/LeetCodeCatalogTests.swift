import XCTest
@testable import PisakaCore

/// The catalog is the only part of this integration that decides *not* to ask
/// LeetCode something, so almost every assertion here is a request count.
///
/// The behaviour under test is a policy, not a parse (that is
/// `LeetCodeAPITests`): a day-long cache so opening a problem costs one request,
/// one forced refresh when a number is missing so a problem added yesterday still
/// opens, and no second refresh after that so a typo'd number cannot become a
/// request per keystroke. Each of those is a `count(for: .problemList)` below.
///
/// The other half is degradation. A cache file can be absent, truncated,
/// written by another version, or impossible to write at all, and none of those
/// may fail the open the user actually asked for — the catalog is an
/// optimisation, and a broken one costs a request rather than a feature.
@MainActor
final class LeetCodeCatalogTests: XCTestCase {

    // MARK: - Harness

    /// A clock the tests move by hand: staleness is the subject here, and a real
    /// one would make "a day later" untestable.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        var onFirstRead: (() -> Void)?

        init(_ value: Date) { self.value = value }

        var now: Date {
            get {
                lock.lock()
                let hook = onFirstRead
                onFirstRead = nil
                defer { lock.unlock() }
                hook?()
                return value
            }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    private static let iso = ISO8601DateFormatter()

    private static func date(_ text: String) -> Date {
        guard let date = iso.date(from: text) else {
            preconditionFailure("bad fixture date \(text)")
        }
        return date
    }

    /// Noon on the day the fixtures were recorded — the tests' "now".
    private let now = LeetCodeCatalogTests.date("2026-08-11T12:00:00Z")

    private let credentials = LeetCodeCredentials(
        session: "session-value",
        csrfToken: "csrf-value"
    )

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    /// The recorded 12-row catalog — the one response in these tests that is
    /// LeetCode's own bytes rather than the minimal ones composed below.
    private static let recordedProblemList = try! Data(
        contentsOf: repositoryRoot
            .appendingPathComponent("Tests/PisakaCoreTests/Fixtures/leetcode/problem-list.json")
    )

    private let treeRoot = URL(fileURLWithPath: "/leetcode-tests")

    /// The cache root inside the stub tree; every path assertion below is
    /// relative to it.
    private var cacheBase: URL { treeRoot.appendingPathComponent("cache") }
    private let catalogPath = "cache/catalog.json"

    private func makeTree(_ files: [String: String] = [:]) -> StubFileTree {
        StubFileTree(root: treeRoot, files: files)
    }

    private func makeCatalog(
        tree: StubFileTree,
        transport: ScriptedLeetCodeTransport,
        clock: Clock
    ) -> LeetCodeCatalog {
        LeetCodeCatalog(
            layout: LeetCodeCacheLayout(base: cacheBase),
            fileService: tree,
            transport: transport,
            now: { clock.now }
        )
    }

    /// A minimal REST catalog body: the keys `LeetCodeAPI.parseProblemList`
    /// reads and nothing else, so a test that is about *policy* does not restate
    /// a 2 MB schema. The recorded fixture is what pins the real shape.
    ///
    /// `status` is a parameter because it is the one field in this response that
    /// is **per account**, which is what makes two sessions' answers to the same
    /// request distinguishable.
    private func problemListJSON(
        _ rows: [(id: Int, slug: String)],
        status: String? = nil
    ) -> String {
        let statusJSON = status.map { "\"\($0)\"" } ?? "null"
        let pairs = rows.map { row in
            """
            {"stat":{"frontend_question_id":\(row.id),\
            "question__title":"\(row.slug)",\
            "question__title_slug":"\(row.slug)"},\
            "status":\(statusJSON),"difficulty":{"level":1},"paid_only":false}
            """
        }
        return "{\"user_name\":\"\",\"stat_status_pairs\":[\(pairs.joined(separator: ","))]}"
    }

    /// A cache file in the documented on-disk shape, hand-written rather than
    /// produced by the encoder — so the format is pinned by something other than
    /// the code that writes it, and a change to it fails here first.
    private func cacheJSON(
        fetchedAt: String,
        rows: [(id: Int, slug: String)],
        schemaVersion: Int = 1,
        difficulty: String = "easy",
        status: String = "notStarted"
    ) -> String {
        let problems = rows.map { row in
            """
            {"difficulty":"\(difficulty)","id":\(row.id),"isPaidOnly":false,\
            "slug":"\(row.slug)","status":"\(status)","title":"\(row.slug)"}
            """
        }
        return """
            {"fetchedAt":"\(fetchedAt)","problems":[\(problems.joined(separator: ","))],\
            "schemaVersion":\(schemaVersion)}
            """
    }

    /// `XCTAssertEqual` over the resolution — spelled as a helper because the
    /// assertion macros take autoclosures, which cannot carry an `await`.
    private func assertResolves(
        _ catalog: LeetCodeCatalog,
        number: Int,
        to expected: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let slug = try await catalog.resolveSlug(forNumber: number, credentials: credentials)
        XCTAssertEqual(slug, expected, file: file, line: line)
    }

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

    // MARK: - The layout

    func testLayoutPlacesTheCatalogAndStatementsUnderOneBase() {
        let layout = LeetCodeCacheLayout(base: URL(fileURLWithPath: "/support/Pisaka/LeetCode"))
        XCTAssertEqual(layout.catalogFile.path, "/support/Pisaka/LeetCode/catalog.json")
        XCTAssertEqual(layout.statementsDirectory.path, "/support/Pisaka/LeetCode/Statements")
        XCTAssertEqual(
            layout.statementFile(forSlug: "two-sum")?.path,
            "/support/Pisaka/LeetCode/Statements/two-sum.html"
        )
    }

    func testLayoutNormalisesItsBaseLexically() {
        let direct = LeetCodeCacheLayout(base: URL(fileURLWithPath: "/support/LeetCode"))
        let roundabout = LeetCodeCacheLayout(
            base: URL(fileURLWithPath: "/support/./Servers/../LeetCode/")
        )
        XCTAssertEqual(direct, roundabout)
    }

    /// The one thing that must not be a path component without being checked: a
    /// slug arrives off the network and out of a file name, and the statement
    /// cache turns it into a write.
    func testLayoutRefusesASlugThatIsNotOne() {
        let layout = LeetCodeCacheLayout(base: URL(fileURLWithPath: "/support/LeetCode"))
        for hostile in ["../secrets", "..", "a/b", "", "   ", "/etc/passwd", "two sum", "two.sum"] {
            XCTAssertNil(
                layout.statementFile(forSlug: hostile),
                "\(hostile) must not become a file name"
            )
        }
        // And the normalisation the input field applies is the same one here, so
        // a slug typed in capitals caches where it will later be looked up.
        XCTAssertEqual(
            layout.statementFile(forSlug: "Two-Sum")?.lastPathComponent,
            "two-sum.html"
        )
    }

    func testLayoutContainmentCoversItsOwnTreeOnly() {
        let layout = LeetCodeCacheLayout(base: URL(fileURLWithPath: "/support/LeetCode"))
        XCTAssertTrue(layout.contains(layout.catalogFile))
        XCTAssertTrue(layout.contains(layout.statementsDirectory))
        XCTAssertFalse(layout.contains(URL(fileURLWithPath: "/support/LeetCodeOther/x")))
        XCTAssertFalse(layout.contains(URL(fileURLWithPath: "/support")))
    }

    // MARK: - Cold start

    func testColdStartFetchesOnceAndCachesWhatItFetched() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, body: Self.recordedProblemList)
        let clock = Clock(now)
        let catalog = makeCatalog(tree: tree, transport: transport, clock: clock)

        let slug = try await catalog.resolveSlug(forNumber: 1, credentials: credentials)
        XCTAssertEqual(slug, "two-sum")
        XCTAssertEqual(transport.count(for: .problemList), 1)
        XCTAssertEqual(tree.writtenPaths, [catalogPath])
        XCTAssertEqual(catalog.fetchedAt, now)
        XCTAssertFalse(catalog.lastCacheWriteFailed)

        // A second number is answered out of the same fetch.
        let second = try await catalog.resolveSlug(forNumber: 170, credentials: credentials)
        XCTAssertEqual(second, "two-sum-iii-data-structure-design")
        XCTAssertEqual(transport.count(for: .problemList), 1)
    }

    /// The recorded catalog carries more than the slug, and the lookups are what
    /// the later problem list will be built on.
    func testLookupsAnswerFromTheFetchedCatalog() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, body: Self.recordedProblemList)
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        _ = try await catalog.resolveSlug(forNumber: 1, credentials: credentials)

        XCTAssertEqual(catalog.problems.count, 12)
        XCTAssertEqual(catalog.slug(forNumber: 42), "trapping-rain-water")
        XCTAssertNil(catalog.slug(forNumber: 43))

        let twoSum = catalog.problem(forSlug: "two-sum")
        XCTAssertEqual(twoSum?.frontendID, 1)
        XCTAssertEqual(twoSum?.title, "Two Sum")
        XCTAssertEqual(twoSum?.difficulty, .easy)
        XCTAssertEqual(twoSum?.status, .solved)
        // The slug rule is one rule: a lookup spelled the way a person types it
        // finds the same row.
        XCTAssertEqual(catalog.problem(forSlug: "Two-Sum")?.slug, "two-sum")

        let premium = catalog.problem(forNumber: 170)
        XCTAssertEqual(premium?.isPaidOnly, true)
        XCTAssertEqual(catalog.problem(forNumber: 4)?.difficulty, .hard)
    }

    /// A slug is already the key every request is made by, so resolving one must
    /// touch neither the disk nor the network — that is what makes opening a
    /// pasted link work offline and work for a problem newer than the catalog.
    func testASlugInputNeedsNeitherDiskNorNetwork() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        let slug = try await catalog.resolveSlug(
            for: .slug("some-brand-new-problem"),
            credentials: credentials
        )
        XCTAssertEqual(slug, "some-brand-new-problem")
        XCTAssertEqual(transport.sent.count, 0)
        XCTAssertEqual(tree.readPaths, [])
    }

    // MARK: - Staleness

    func testWarmCacheWithinTheDayMakesNoRequest() async throws {
        let tree = makeTree([
            catalogPath: cacheJSON(
                fetchedAt: "2026-08-11T11:00:00Z",
                rows: [(1, "two-sum")]
            ),
        ])
        let transport = ScriptedLeetCodeTransport()
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        let slug = try await catalog.resolveSlug(forNumber: 1, credentials: credentials)
        XCTAssertEqual(slug, "two-sum")
        XCTAssertEqual(transport.sent.count, 0)
        XCTAssertEqual(tree.readPaths, [catalogPath])
        XCTAssertEqual(tree.writtenPaths, [])
        XCTAssertEqual(catalog.fetchedAt, Self.date("2026-08-11T11:00:00Z"))
        XCTAssertFalse(catalog.isStale)
    }

    func testACacheOlderThanADayIsRefreshed() async throws {
        let tree = makeTree([
            catalogPath: cacheJSON(
                fetchedAt: "2026-08-10T10:00:00Z",
                rows: [(1, "stale-two-sum")]
            ),
        ])
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, json: problemListJSON([(1, "two-sum")]))
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        let slug = try await catalog.resolveSlug(forNumber: 1, credentials: credentials)
        XCTAssertEqual(slug, "two-sum")
        XCTAssertEqual(transport.count(for: .problemList), 1)
        XCTAssertEqual(catalog.fetchedAt, now)
        XCTAssertEqual(tree.writtenPaths, [catalogPath])
    }

    /// A `fetchedAt` in the future is stale too: a clock that moved backwards
    /// would otherwise pin the catalog until the calendar caught up.
    func testACacheFromTheFutureIsTreatedAsStale() async throws {
        let tree = makeTree([
            catalogPath: cacheJSON(
                fetchedAt: "2027-01-01T00:00:00Z",
                rows: [(1, "stale-two-sum")]
            ),
        ])
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, json: problemListJSON([(1, "two-sum")]))
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        try await assertResolves(catalog, number: 1, to: "two-sum")
        XCTAssertEqual(transport.count(for: .problemList), 1)
    }

    /// Time passing between two opens re-arms the daily refresh.
    func testTheCatalogAgesOutWhileTheAppRuns() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, json: problemListJSON([(1, "two-sum")]))
        let clock = Clock(now)
        let catalog = makeCatalog(tree: tree, transport: transport, clock: clock)

        _ = try await catalog.resolveSlug(forNumber: 1, credentials: credentials)
        XCTAssertEqual(transport.count(for: .problemList), 1)

        clock.now = now.addingTimeInterval(LeetCodeCatalog.maximumAge + 1)
        XCTAssertTrue(catalog.isStale)
        _ = try await catalog.resolveSlug(forNumber: 1, credentials: credentials)
        XCTAssertEqual(transport.count(for: .problemList), 2)
    }

    // MARK: - The miss path

    /// A problem added since the cache was written is exactly what a warm cache
    /// is missing, so a miss forces one refresh rather than reporting "no such
    /// problem" about something the user is looking at on the site.
    func testANumberMissingFromAWarmCacheForcesExactlyOneRefresh() async throws {
        let tree = makeTree([
            catalogPath: cacheJSON(
                fetchedAt: "2026-08-11T11:00:00Z",
                rows: [(1, "two-sum")]
            ),
        ])
        let transport = ScriptedLeetCodeTransport()
        transport.serve(
            .problemList,
            json: problemListJSON([(1, "two-sum"), (3500, "brand-new-problem")])
        )
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        let slug = try await catalog.resolveSlug(forNumber: 3500, credentials: credentials)
        XCTAssertEqual(slug, "brand-new-problem")
        XCTAssertEqual(transport.count(for: .problemList), 1)
        XCTAssertEqual(tree.writtenPaths, [catalogPath])
    }

    /// …and one refresh only. A number that is still absent afterwards is
    /// reported absent, and the next mistyped number does not fetch again — the
    /// difference between a typo costing nothing and a typo costing 2 MB per
    /// attempt.
    func testANumberStillMissingAfterTheRefreshDoesNotRefreshAgain() async throws {
        let tree = makeTree([
            catalogPath: cacheJSON(
                fetchedAt: "2026-08-11T11:00:00Z",
                rows: [(1, "two-sum")]
            ),
        ])
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, json: problemListJSON([(1, "two-sum")]))
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        let first = try await catalog.resolveSlug(forNumber: 999_999, credentials: credentials)
        XCTAssertNil(first)
        XCTAssertEqual(transport.count(for: .problemList), 1)

        let second = try await catalog.resolveSlug(forNumber: 999_998, credentials: credentials)
        XCTAssertNil(second)
        XCTAssertEqual(transport.count(for: .problemList), 1)
    }

    /// Not-found is a value. `apiChanged` stays reserved for LeetCode having
    /// changed shape, so a typo does not report a broken API.
    func testAMissingNumberIsNotAnError() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, json: problemListJSON([(1, "two-sum")]))
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        let slug = try await catalog.resolveSlug(for: .number(4242), credentials: credentials)
        XCTAssertNil(slug)
    }

    /// A slug input is re-checked against the one slug rule on the way out, and a
    /// spelling this app cannot use is "no such problem" — not a request, and
    /// certainly not a path component.
    ///
    /// `LeetCodeProblemInput.slug` is a public case with a plain `String`
    /// payload, and what this method returns is appended to the user's folder by
    /// `LeetCodeSolutionFile.name(…)`, where `appendingPathComponent` does not
    /// resolve `..`. A separator getting through would also defeat the
    /// never-overwrite rule, which compares `lastPathComponent`. The rule must
    /// hold here rather than only in `parse(_:)`, which happens to be the one
    /// producer today.
    func testASlugInputThatIsNotASlugResolvesToNothing() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, json: problemListJSON([(1, "two-sum")]))
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        for spelling in ["../../etc/passwd", "two/sum", "..", "two sum", ""] {
            let slug = try await catalog.resolveSlug(
                for: .slug(spelling),
                credentials: credentials
            )
            XCTAssertNil(slug, "\(spelling) is not a slug this app can request")
        }
        // A slug never costs a catalog download, refused or not.
        XCTAssertEqual(transport.count(for: .problemList), 0)
    }

    /// The same check is the identity function on a slug that *is* one — modulo
    /// the case-folding `normalizedSlug` has always applied.
    func testAWellSpelledSlugInputIsReturnedNormalized() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        let slug = try await catalog.resolveSlug(for: .slug("Two-Sum"), credentials: credentials)
        XCTAssertEqual(slug, "two-sum")
        XCTAssertEqual(transport.count(for: .problemList), 0)
    }

    // MARK: - A cache that cannot be trusted

    func testACorruptCacheIsDiscardedAndRefetched() async throws {
        let tree = makeTree([catalogPath: "{\"schemaVersion\": 1, \"problems\": [{\"id\""])
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, json: problemListJSON([(1, "two-sum")]))
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        try await assertResolves(catalog, number: 1, to: "two-sum")
        XCTAssertEqual(transport.count(for: .problemList), 1)
        // …and the half-written file is replaced by one that reads back.
        XCTAssertEqual(tree.writtenPaths, [catalogPath])
    }

    func testACacheWrittenByAnotherSchemaVersionIsIgnored() async throws {
        let tree = makeTree([
            catalogPath: cacheJSON(
                fetchedAt: "2026-08-11T11:00:00Z",
                rows: [(1, "two-sum")],
                schemaVersion: 99
            ),
        ])
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, json: problemListJSON([(1, "refetched-two-sum")]))
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        try await assertResolves(catalog, number: 1, to: "refetched-two-sum")
        XCTAssertEqual(transport.count(for: .problemList), 1)
    }

    /// A row this build cannot map invalidates the whole file rather than being
    /// dropped: a catalog silently missing problems answers "no such problem"
    /// forever, which is worse than one extra request.
    func testACacheRowWithAnUnknownEnumerationIsIgnored() async throws {
        let tree = makeTree([
            catalogPath: cacheJSON(
                fetchedAt: "2026-08-11T11:00:00Z",
                rows: [(1, "two-sum")],
                difficulty: "impossible"
            ),
        ])
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, json: problemListJSON([(1, "refetched-two-sum")]))
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        try await assertResolves(catalog, number: 1, to: "refetched-two-sum")
        XCTAssertEqual(transport.count(for: .problemList), 1)
    }

    /// A restored slug is what the next detail request is made by and — through
    /// the parser's `requestedSlug` fallback — what a file name is composed from,
    /// so the cache is held to the same slug rule the wire is. A row that is not
    /// normalized invalidates the file, exactly as an unknown difficulty does.
    func testACacheRowWhoseSlugIsNotNormalizedIsIgnored() async throws {
        for slug in ["../../escape", "Two-Sum", "two sum", "-two-sum"] {
            let tree = makeTree([
                catalogPath: cacheJSON(
                    fetchedAt: "2026-08-11T11:00:00Z",
                    rows: [(1, slug)]
                ),
            ])
            let transport = ScriptedLeetCodeTransport()
            transport.serve(.problemList, json: problemListJSON([(1, "refetched-two-sum")]))
            let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

            try await assertResolves(catalog, number: 1, to: "refetched-two-sum")
            XCTAssertEqual(transport.count(for: .problemList), 1, "slug \(slug)")
        }
    }

    /// "An empty catalog is never published or cached" has to hold at the *disk*
    /// door as well as the network one.
    ///
    /// A zero-row file decodes cleanly — the row validation simply has nothing to
    /// run over — and publishing it made a recent `fetchedAt` mean "not stale", so
    /// `loadIfNeeded` returned without fetching and the browser sat on "No problems
    /// loaded." with no error for a day. `resolveSlug(forNumber:)` had the
    /// forced-refresh-on-miss escape hatch; `loadIfNeeded` has none, which is why
    /// the rule belongs on the file rather than on either reader.
    func testAnEmptyCacheFileIsTreatedAsAbsent() async throws {
        let tree = makeTree([
            catalogPath: cacheJSON(fetchedAt: "2026-08-11T11:00:00Z", rows: [])
        ])
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, json: problemListJSON([(1, "refetched-two-sum")]))
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        // The browser's door: a fresh-looking but empty file must not suppress it.
        try await catalog.loadIfNeeded(credentials: credentials)
        XCTAssertEqual(transport.count(for: .problemList), 1)
        XCTAssertEqual(catalog.problems.map(\.slug), ["refetched-two-sum"])
    }

    func testAnUnreadableCacheIsTreatedAsAbsent() async throws {
        let tree = makeTree([
            catalogPath: cacheJSON(fetchedAt: "2026-08-11T11:00:00Z", rows: [(1, "two-sum")])
        ])
        tree.unreadableFiles = [catalogPath]
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, json: problemListJSON([(1, "refetched-two-sum")]))
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        try await assertResolves(catalog, number: 1, to: "refetched-two-sum")
        XCTAssertEqual(transport.count(for: .problemList), 1)
    }

    /// What one run writes, the next run reads — the round trip through the
    /// encoder that the hand-written fixtures above cannot assert.
    func testTheWrittenCacheIsReadBackByAFreshCatalog() async throws {
        let tree = makeTree()
        let writing = ScriptedLeetCodeTransport()
        writing.serve(.problemList, body: Self.recordedProblemList)
        let first = makeCatalog(tree: tree, transport: writing, clock: Clock(now))
        _ = try await first.resolveSlug(forNumber: 1, credentials: credentials)

        // A second session, one minute later, with a transport that would fail
        // if it were asked anything at all.
        let offline = ScriptedLeetCodeTransport()
        offline.fail(.problemList)
        let second = makeCatalog(
            tree: tree,
            transport: offline,
            clock: Clock(now.addingTimeInterval(60))
        )

        try await assertResolves(second, number: 170, to: "two-sum-iii-data-structure-design")
        XCTAssertEqual(second.problem(forNumber: 170)?.isPaidOnly, true)
        XCTAssertEqual(second.problem(forSlug: "two-sum")?.status, .solved)
        XCTAssertEqual(offline.sent.count, 0)
    }

    // MARK: - Writing the cache may fail

    func testAFailedCacheWriteLeavesTheCatalogUsableInMemory() async throws {
        let tree = makeTree()
        tree.writeFailures = [catalogPath]
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, json: problemListJSON([(1, "two-sum"), (2, "add-two-numbers")]))
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        try await assertResolves(catalog, number: 1, to: "two-sum")
        XCTAssertTrue(catalog.lastCacheWriteFailed)
        XCTAssertNil(tree.files[catalogPath])
        // The session runs on the in-memory catalog: no second fetch.
        try await assertResolves(catalog, number: 2, to: "add-two-numbers")
        XCTAssertEqual(transport.count(for: .problemList), 1)
    }

    /// The other half of the same degradation: the cache *directory* cannot be
    /// created, because something else already occupies its path.
    func testAnUncreatableCacheDirectoryDoesNotFailTheResolution() async throws {
        let tree = makeTree(["cache": "not a directory"])
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, json: problemListJSON([(1, "two-sum")]))
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        try await assertResolves(catalog, number: 1, to: "two-sum")
        XCTAssertTrue(catalog.lastCacheWriteFailed)
    }

    // MARK: - Failures that are the user's business

    /// A shape-valid catalog with no rows would cache "there are no problems"
    /// for a day and make every open fail with "no such problem". It is reported
    /// as the API having changed, and nothing is published or written.
    func testAnEmptyCatalogIsReportedRatherThanCached() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, json: problemListJSON([]))
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        await assertThrows(.apiChanged(detail: "stat_status_pairs: empty")) {
            _ = try await catalog.resolveSlug(forNumber: 1, credentials: self.credentials)
        }
        XCTAssertEqual(tree.writtenPaths, [])
        XCTAssertTrue(catalog.problems.isEmpty)
        XCTAssertNil(catalog.fetchedAt)
    }

    func testThrottlingSurfacesAsThrottled() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(
            .problemList,
            json: "{\"detail\":\"Request was throttled.\"}",
            statusCode: 429,
            headers: ["Retry-After": "30"]
        )
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        await assertThrows(.throttled(retryAfter: 30)) {
            _ = try await catalog.resolveSlug(forNumber: 1, credentials: self.credentials)
        }
    }

    func testASignedOutCatalogRequestSurfacesAsNotLoggedIn() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(
            .problemList,
            json: "{\"detail\":\"Authentication credentials were not provided.\"}",
            statusCode: 403
        )
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        await assertThrows(.notLoggedIn) {
            _ = try await catalog.resolveSlug(forNumber: 1, credentials: self.credentials)
        }
    }

    /// A transport that throws something other than a `LeetCodeError` — which
    /// the real one does not, but a decorator or a stub might — still reads as
    /// "could not reach LeetCode" rather than escaping this layer's error type.
    func testATransportFailureBecomesANetworkError() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.fail(.problemList)
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        do {
            _ = try await catalog.resolveSlug(forNumber: 1, credentials: credentials)
            XCTFail("expected a network error")
        } catch let error as LeetCodeError {
            guard case .network(let reason) = error else {
                return XCTFail("expected .network, got \(error)")
            }
            XCTAssertFalse(reason.isEmpty)
        }
        // Nothing was published, so the next attempt tries again.
        XCTAssertTrue(catalog.problems.isEmpty)
        transport.serve(.problemList, json: problemListJSON([(1, "two-sum")]))
        try await assertResolves(catalog, number: 1, to: "two-sum")
        XCTAssertEqual(transport.count(for: .problemList), 2)
    }

    /// A `LeetCodeError` thrown by the transport travels unchanged — it is
    /// already this layer's vocabulary.
    func testATransportsOwnNetworkErrorIsNotRewrapped() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.fail(.problemList, with: LeetCodeError.network(reason: "offline"))
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        await assertThrows(.network(reason: "offline")) {
            _ = try await catalog.resolveSlug(forNumber: 1, credentials: self.credentials)
        }
    }

    // MARK: - A refresh that could not be made

    /// A stale cache that could not be refreshed still answers.
    ///
    /// The catalog endpoint is the legacy REST one and 2 MB — the likeliest
    /// thing here to be throttled or blocked while GraphQL still answers — and
    /// throwing its failure out would refuse a number whose slug is on disk and
    /// whose detail request would have succeeded. Age is a reason to *try* for
    /// something newer, not to throw away what answers the question.
    func testAStaleCacheStillAnswersWhenTheRefreshFails() async throws {
        let tree = makeTree([
            catalogPath: cacheJSON(
                fetchedAt: "2026-08-01T10:00:00Z",
                rows: [(1, "two-sum")]
            ),
        ])
        let transport = ScriptedLeetCodeTransport()
        transport.serve(
            .problemList,
            json: "{\"detail\":\"Request was throttled.\"}",
            statusCode: 429
        )
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        try await assertResolves(catalog, number: 1, to: "two-sum")
        XCTAssertEqual(transport.count(for: .problemList), 1)
        // The refresh was attempted and failed, so nothing was cached over the
        // snapshot that answered.
        XCTAssertTrue(tree.writtenPaths.isEmpty)
    }

    /// The fallback is per *number*, not blanket: a failure with nothing on disk
    /// that answers is still the failure, or a throttle would read as "no such
    /// problem" and the user would go looking for a typo.
    func testAFailedRefreshStillThrowsForANumberTheCacheDoesNotHold() async throws {
        let tree = makeTree([
            catalogPath: cacheJSON(
                fetchedAt: "2026-08-01T10:00:00Z",
                rows: [(1, "two-sum")]
            ),
        ])
        let transport = ScriptedLeetCodeTransport()
        transport.fail(.problemList, with: LeetCodeError.network(reason: "offline"))
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        await assertThrows(.network(reason: "offline")) {
            _ = try await catalog.resolveSlug(forNumber: 2, credentials: self.credentials)
        }
    }

    /// With no cache at all there is nothing to fall back to, and the failure is
    /// the answer — the pre-existing behaviour, pinned so the fallback above
    /// cannot grow into swallowing it.
    func testAFailedRefreshWithNoCacheThrows() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.fail(.problemList, with: LeetCodeError.network(reason: "offline"))
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        await assertThrows(.network(reason: "offline")) {
            _ = try await catalog.resolveSlug(forNumber: 1, credentials: self.credentials)
        }
    }

    // MARK: - Browsing

    /// The browser's entry point pays the same price every other reader does:
    /// inside the staleness window, nothing at all.
    func testLoadIfNeededServesAWarmCacheWithoutARequest() async throws {
        let tree = makeTree([
            catalogPath: cacheJSON(
                fetchedAt: "2026-08-11T11:00:00Z",
                rows: [(1, "two-sum"), (2, "add-two-numbers")]
            ),
        ])
        let transport = ScriptedLeetCodeTransport()
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        try await catalog.loadIfNeeded(credentials: credentials)

        XCTAssertEqual(transport.count(for: .problemList), 0)
        XCTAssertEqual(catalog.problems.map(\.slug), ["two-sum", "add-two-numbers"])
        XCTAssertEqual(catalog.fetchedAt, Self.date("2026-08-11T11:00:00Z"))
        XCTAssertEqual(tree.readPaths, [catalogPath])
        XCTAssertEqual(tree.writtenPaths, [])

        // …and a second surface appearing costs nothing either: the list is now in
        // memory and the disk is not consulted twice.
        try await catalog.loadIfNeeded(credentials: credentials)
        XCTAssertEqual(transport.count(for: .problemList), 0)
        XCTAssertEqual(tree.readPaths, [catalogPath])
    }

    /// No cache is stale, so the first open of the browser fetches — once.
    func testLoadIfNeededFetchesOnceWithNoCache() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, body: Self.recordedProblemList)
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        try await catalog.loadIfNeeded(credentials: credentials)

        XCTAssertEqual(transport.count(for: .problemList), 1)
        XCTAssertEqual(catalog.problems.count, 12)
        XCTAssertEqual(catalog.fetchedAt, now)
        XCTAssertEqual(tree.writtenPaths, [catalogPath])

        // The fetch it just made is warm, so re-entering the surface is free.
        try await catalog.loadIfNeeded(credentials: credentials)
        XCTAssertEqual(transport.count(for: .problemList), 1)
    }

    /// A cache past `maximumAge` is refreshed, and the rows the browser then reads
    /// are the fetched ones rather than the file's.
    func testLoadIfNeededRefreshesACacheOlderThanADay() async throws {
        let tree = makeTree([
            catalogPath: cacheJSON(
                fetchedAt: "2026-08-10T10:00:00Z",
                rows: [(1, "stale-two-sum")]
            ),
        ])
        let transport = ScriptedLeetCodeTransport()
        transport.serve(
            .problemList,
            json: problemListJSON([(1, "two-sum"), (3500, "brand-new-problem")])
        )
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        try await catalog.loadIfNeeded(credentials: credentials)

        XCTAssertEqual(transport.count(for: .problemList), 1)
        XCTAssertEqual(catalog.problems.map(\.slug), ["two-sum", "brand-new-problem"])
        XCTAssertEqual(catalog.fetchedAt, now)
        XCTAssertEqual(tree.writtenPaths, [catalogPath])
    }

    /// Two surfaces appearing at once — the window and a `.task` on the list —
    /// download the 2 MB catalog once, because this method adds no fetch of its
    /// own and joins the coalesced one.
    func testOverlappingLoadIfNeededCallsShareOneFetch() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, json: problemListJSON([(1, "two-sum")]))
        let gate = Gate()
        transport.hold(.problemList, on: gate)
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        let first = Task { try await catalog.loadIfNeeded(credentials: credentials) }
        await gate.waitUntilReached()
        let second = Task { try await catalog.loadIfNeeded(credentials: credentials) }
        // Let the second run up to the point where it joins the in-flight refresh
        // rather than starting its own.
        await Task.yield()
        await Task.yield()
        // Released twice so a *broken* coalescer fails the count assertion below
        // instead of deadlocking the suite.
        gate.release()
        gate.release()

        try await first.value
        try await second.value
        XCTAssertEqual(transport.count(for: .problemList), 1)
        XCTAssertEqual(catalog.problems.map(\.slug), ["two-sum"])
    }

    /// The one place this method deliberately does *not* apply `resolveSlug`'s
    /// degradation rule: a refresh that could not be made throws, and the rows the
    /// disk had are still there for the caller to keep showing beside the error.
    func testLoadIfNeededThrowsButLeavesAWarmCachePopulated() async throws {
        let tree = makeTree([
            catalogPath: cacheJSON(
                fetchedAt: "2026-08-01T10:00:00Z",
                rows: [(1, "two-sum"), (2, "add-two-numbers")]
            ),
        ])
        let transport = ScriptedLeetCodeTransport()
        transport.fail(.problemList, with: LeetCodeError.network(reason: "offline"))
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        await assertThrows(.network(reason: "offline")) {
            try await catalog.loadIfNeeded(credentials: self.credentials)
        }

        XCTAssertEqual(transport.count(for: .problemList), 1)
        XCTAssertEqual(catalog.problems.map(\.slug), ["two-sum", "add-two-numbers"])
        XCTAssertEqual(catalog.fetchedAt, Self.date("2026-08-01T10:00:00Z"))
        // Nothing was written over the snapshot that survived.
        XCTAssertEqual(tree.writtenPaths, [])
    }

    // MARK: - Overlapping work

    /// Two problems opened at once download the 2 MB list once.
    func testOverlappingResolutionsShareOneFetch() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(
            .problemList,
            json: problemListJSON([(1, "two-sum"), (2, "add-two-numbers")])
        )
        let gate = Gate()
        transport.hold(.problemList, on: gate)
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        let first = Task { try await catalog.resolveSlug(forNumber: 1, credentials: credentials) }
        await gate.waitUntilReached()
        let second = Task { try await catalog.resolveSlug(forNumber: 2, credentials: credentials) }
        // Let the second task run up to the point where it joins the in-flight
        // refresh rather than starting its own.
        await Task.yield()
        await Task.yield()
        // Released twice so a *broken* coalescer fails the count assertion below
        // instead of deadlocking the suite.
        gate.release()
        gate.release()

        let slugs = [try await first.value, try await second.value]
        XCTAssertEqual(slugs, ["two-sum", "add-two-numbers"])
        XCTAssertEqual(transport.count(for: .problemList), 1)
    }

    /// A lookup that arrives while the disk read is decoding waits for it instead
    /// of concluding there is no cache.
    ///
    /// The decode is a suspension point, and the two callers here are the ordinary
    /// overlapping pair: the statement panel asking for a title by slug, and an
    /// open resolving a number. With the "consulted" flag raised before the
    /// decode, the second read a fresh cache as absent and downloaded the 2 MB
    /// list it was about to be handed.
    func testALookupDuringTheDiskReadWaitsForItInsteadOfRefetching() async throws {
        let tree = makeTree([
            catalogPath: cacheJSON(
                fetchedAt: "2026-08-11T11:00:00Z",
                rows: [(1, "two-sum"), (2, "add-two-numbers")]
            ),
        ])
        let transport = ScriptedLeetCodeTransport()
        transport.serve(
            .problemList,
            json: problemListJSON([(1, "two-sum"), (2, "add-two-numbers")])
        )
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        // The first suspends inside the decode; the second then runs on the same
        // actor and must join that read rather than start a fetch.
        let first = Task { await catalog.cachedProblem(forSlug: "two-sum") }
        let second = Task { try await catalog.resolveSlug(forNumber: 2, credentials: credentials) }

        let cached = await first.value
        let resolved = try await second.value
        XCTAssertEqual(cached?.slug, "two-sum")
        XCTAssertEqual(resolved, "add-two-numbers")
        // The cache is a day fresh: nothing had any business asking the network.
        XCTAssertEqual(transport.count(for: .problemList), 0)
        // And the catalog in memory is the one that was on disk, not a fetch that
        // landed and was then overwritten by it.
        XCTAssertEqual(catalog.problems.count, 2)
    }

    // MARK: - Coalescing is per session

    /// A refresh under a *different* session does not join the one in flight.
    ///
    /// The coalescing exists so two opens cost one download, and every caller in
    /// that case holds the same session. A caller holding another one is a
    /// different question: the rows carry a per-account `status`, so handing it the
    /// previous account's fetch publishes that account's solved marks under the new
    /// account's name — and the publish stamps a fresh `fetchedAt`, so the browser's
    /// Refresh, which is the documented way out of exactly that (L24), would have
    /// been the thing that pinned it for a day.
    func testARefreshUnderANewSessionDoesNotJoinThePreviousAccountsFetch() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(
            .problemList,
            sequence: [
                LeetCodeHTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(problemListJSON([(1, "two-sum")], status: "ac").utf8)
                ),
                LeetCodeHTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(problemListJSON([(1, "two-sum")], status: nil).utf8)
                ),
            ]
        )
        let gate = Gate()
        transport.hold(.problemList, on: gate)
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        let other = LeetCodeCredentials(session: "other-session", csrfToken: "other-csrf")
        let first = Task { try await catalog.refresh(credentials: credentials) }
        await gate.waitUntilReached()
        let second = Task { try await catalog.refresh(credentials: other) }
        // Let the second run up to the point where it would have joined.
        await Task.yield()
        await Task.yield()
        gate.release()
        gate.release()

        try await first.value
        try await second.value

        XCTAssertEqual(transport.count(for: .problemList), 2)
        // The newer session's answer is the published one, whichever download
        // happened to land last.
        XCTAssertEqual(catalog.problems.map(\.status), [.notStarted])
        XCTAssertEqual(catalog.problem(forSlug: "two-sum")?.status, .notStarted)
    }

    /// The superseded fetch does not reach the disk either: a cache file carrying
    /// the previous account's marks would survive the launch and be restored as if
    /// it were the current account's.
    func testASupersededRefreshWritesNoCache() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(
            .problemList,
            sequence: [
                LeetCodeHTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(problemListJSON([(1, "two-sum")], status: "ac").utf8)
                ),
                LeetCodeHTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(problemListJSON([(1, "two-sum")], status: nil).utf8)
                ),
            ]
        )
        let gate = Gate()
        transport.hold(.problemList, on: gate)
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        let other = LeetCodeCredentials(session: "other-session", csrfToken: "other-csrf")
        let first = Task { try await catalog.refresh(credentials: credentials) }
        await gate.waitUntilReached()
        let second = Task { try await catalog.refresh(credentials: other) }
        await Task.yield()
        await Task.yield()
        gate.release()
        gate.release()

        try await first.value
        try await second.value

        // One write, and it is the newer session's rows — read back the way the
        // next launch would read them.
        XCTAssertEqual(tree.writtenPaths, [catalogPath])
        let offline = ScriptedLeetCodeTransport()
        offline.fail(.problemList)
        let restored = makeCatalog(tree: tree, transport: offline, clock: Clock(now))
        let row = await restored.cachedProblem(forSlug: "two-sum")
        XCTAssertEqual(row?.status, .notStarted)
        XCTAssertEqual(offline.count(for: .problemList), 0)
    }

    /// The previous session's fetch landing **last** still publishes nothing.
    ///
    /// The other half of the key: two fetches can now be alive at once, so the
    /// order they come back in is the network's to decide. Staged deterministically
    /// — each request is held on its own gate, and the older one is released after
    /// the newer has already published — because "whichever finished last wins"
    /// would put the previous account's marks back over the current account's, with
    /// a fresh `fetchedAt` keeping them for a day.
    func testThePreviousSessionsFetchLandingLastPublishesNothing() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(
            .problemList,
            sequence: [
                LeetCodeHTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(problemListJSON([(1, "two-sum")], status: "ac").utf8)
                ),
                LeetCodeHTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(problemListJSON([(1, "two-sum")], status: nil).utf8)
                ),
            ]
        )
        let old = Gate()
        transport.hold(.problemList, on: old)
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        let other = LeetCodeCredentials(session: "other-session", csrfToken: "other-csrf")
        let first = Task { try await catalog.refresh(credentials: credentials) }
        await old.waitUntilReached()
        // The second request is held on a gate of its own, so the two can be
        // released in the order this test is about.
        let new = Gate()
        transport.hold(.problemList, on: new)
        let second = Task { try await catalog.refresh(credentials: other) }
        await new.waitUntilReached()

        new.release()
        try await second.value
        XCTAssertEqual(catalog.problems.map(\.status), [.notStarted])

        old.release()
        try await first.value
        XCTAssertEqual(catalog.problems.map(\.status), [.notStarted])
        XCTAssertEqual(catalog.fetchedAt, now)
        // And the late one wrote nothing over the cache the newer session left.
        XCTAssertEqual(tree.writtenPaths, [catalogPath])
    }

    /// The same session still coalesces — the behaviour the key above must not
    /// have cost, restated against `refresh` itself rather than through
    /// `loadIfNeeded`.
    func testTwoRefreshesUnderOneSessionStillShareOneFetch() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, json: problemListJSON([(1, "two-sum")]))
        let gate = Gate()
        transport.hold(.problemList, on: gate)
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        let first = Task { try await catalog.refresh(credentials: credentials) }
        await gate.waitUntilReached()
        let second = Task { try await catalog.refresh(credentials: credentials) }
        await Task.yield()
        await Task.yield()
        // Released twice so a *broken* coalescer fails the count assertion below
        // instead of deadlocking the suite.
        gate.release()
        gate.release()

        try await first.value
        try await second.value
        XCTAssertEqual(transport.count(for: .problemList), 1)
    }

    /// Coalescing must not make one caller's Esc into another caller's failure.
    ///
    /// The cancellation in `refresh` reaches the *shared* task, so pressing Esc in
    /// the Open Problem sheet used to kill a download the browser had merely joined
    /// — and the browser, never cancelled itself, published
    /// `network(reason: "cancelled")` about a question its user never asked, over
    /// an empty list that only a by-hand Refresh re-armed. The survivor asks again
    /// on its own behalf instead: two requests, one of them nobody's failure.
    func testACallerThatJoinedACancelledFetchAsksAgainRatherThanFailing() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.fail(
            .problemList,
            once: LeetCodeError.network(reason: "cancelled"),
            thenServe: LeetCodeHTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(problemListJSON([(1, "two-sum")]).utf8)
            )
        )
        let gate = Gate()
        transport.hold(.problemList, on: gate)
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        let first = Task { try await catalog.refresh(credentials: credentials) }
        await gate.waitUntilReached()
        let second = Task { try await catalog.refresh(credentials: credentials) }
        // Let the second run up to the point where it joins the in-flight refresh.
        await Task.yield()
        await Task.yield()
        first.cancel()
        // Once for the fetch that was cancelled, once for the retry — and released
        // unconditionally so a regression fails the assertions below instead of
        // deadlocking the suite.
        gate.release()
        gate.release()

        do {
            try await first.value
            XCTFail("the caller that withdrew still gets its failure")
        } catch {}
        // The one that did not withdraw gets the catalog.
        try await second.value
        XCTAssertEqual(transport.count(for: .problemList), 2)
        XCTAssertEqual(catalog.problems.map(\.slug), ["two-sum"])
    }

    /// And a refresh started *after* the previous one finished reuses nothing:
    /// the slot is open again, so the second session fetches on its own.
    func testARefreshAfterASessionChangeFetchesAgain() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, json: problemListJSON([(1, "two-sum")], status: "ac"))
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        try await catalog.refresh(credentials: credentials)
        transport.serve(.problemList, json: problemListJSON([(1, "two-sum")]))
        let other = LeetCodeCredentials(session: "other-session", csrfToken: "other-csrf")
        try await catalog.refresh(credentials: other)

        XCTAssertEqual(transport.count(for: .problemList), 2)
        XCTAssertEqual(catalog.problems.map(\.status), [.notStarted])
    }

    // MARK: - Which session is the current one

    /// A refresh under a session this app has replaced is **not made at all**.
    ///
    /// The hole the generation above cannot see: it orders refreshes by the moment
    /// they *start*, and a caller holding the previous session can start one last —
    /// every door into this type suspends before it fetches, so a straggler resumes
    /// after the new session has already asked. By start order it would be the
    /// newest and would publish the previous account's `status` column over the
    /// current account's. Which session is current is a question only the app can
    /// answer, so it says so, and the answer is what decides this.
    ///
    /// Not made rather than merely not published, because the request would carry a
    /// cookie the user has replaced and LeetCode's 403 to it is classified as
    /// `notLoggedIn` — a sentence about the *current* session that is not true of
    /// it.
    func testARefreshUnderAReplacedSessionIsNeverMade() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, json: problemListJSON([(1, "two-sum")], status: "ac"))
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        let other = LeetCodeCredentials(session: "other-session", csrfToken: "other-csrf")
        catalog.sessionDidChange(to: other)
        try await catalog.refresh(credentials: credentials)

        XCTAssertEqual(transport.count(for: .problemList), 0)
        XCTAssertTrue(catalog.problems.isEmpty)
        XCTAssertNil(catalog.fetchedAt)
        XCTAssertTrue(tree.writtenPaths.isEmpty)
    }

    /// And the straggler does not disturb the current session's fetch either — the
    /// half a "last refresh wins" rule gets wrong in the other direction.
    ///
    /// Staged as the app stages it: the current session's download is in flight,
    /// the previous session's caller resumes and asks, and the current one then
    /// lands. It must publish, because nothing newer ever happened — the later
    /// refresh was answering for a session that no longer exists.
    func testAStragglerFromTheOldSessionDoesNotSupersedeTheCurrentFetch() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(
            .problemList,
            sequence: [
                LeetCodeHTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(problemListJSON([(1, "two-sum")]).utf8)
                ),
                // Only a regression asks for this one, and it is deliberately
                // distinguishable so the assertions below say which fetch published.
                LeetCodeHTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(problemListJSON([(2, "add-two-numbers")], status: "ac").utf8)
                ),
            ]
        )
        let gate = Gate()
        transport.hold(.problemList, on: gate)
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        let other = LeetCodeCredentials(session: "other-session", csrfToken: "other-csrf")
        catalog.sessionDidChange(to: other)
        let current = Task { try await catalog.refresh(credentials: other) }
        await gate.waitUntilReached()
        // The previous session's caller, resuming from its own suspension after the
        // current one had already started. Driven as a task and released twice so a
        // regression fails the count below instead of deadlocking the suite.
        let straggler = Task { try await catalog.refresh(credentials: credentials) }
        await Task.yield()
        await Task.yield()
        gate.release()
        gate.release()
        try await current.value
        try await straggler.value

        XCTAssertEqual(transport.count(for: .problemList), 1)
        XCTAssertEqual(catalog.problems.map(\.slug), ["two-sum"])
        XCTAssertEqual(catalog.fetchedAt, now)
        XCTAssertEqual(tree.writtenPaths, [catalogPath])
    }

    /// A session replaced **while a fetch is in flight** takes that fetch with it,
    /// even though no newer refresh was ever started.
    ///
    /// A sign-out starts nothing, so the generation never moves and the download
    /// already running would otherwise land the departing account's solved marks in
    /// the cache — with a fresh `fetchedAt`, so the next account inherits them for a
    /// day (the L24 window) instead of fetching its own.
    func testAFetchInFlightWhenTheSessionGoesAwayPublishesNothing() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, json: problemListJSON([(1, "two-sum")], status: "ac"))
        let gate = Gate()
        transport.hold(.problemList, on: gate)
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        catalog.sessionDidChange(to: credentials)
        let refresh = Task { try await catalog.refresh(credentials: credentials) }
        await gate.waitUntilReached()
        catalog.sessionDidChange(to: nil)
        gate.release()
        try await refresh.value

        XCTAssertEqual(transport.count(for: .problemList), 1)
        XCTAssertTrue(catalog.problems.isEmpty)
        XCTAssertNil(catalog.fetchedAt)
        XCTAssertTrue(tree.writtenPaths.isEmpty)
    }

    /// And a session replaced **while the cache is being encoded** — the suspension
    /// on the far side of the guard — reaches the disk no more than one replaced
    /// mid-fetch does.
    ///
    /// The narrow window the guard before the publish cannot see: the ~2 MB encode
    /// hands the actor back, and a sign-out runs on it. The in-memory publish has
    /// already happened and stands (it was correct when it happened, and it dies
    /// with the process); the file must not, because `fetchedAt = now` in
    /// `catalog.json` is what carries the departing account's solved marks into the
    /// next launch and pins them under the next account's name for a day.
    ///
    /// Staged deterministically on a causal rendezvous, not a timed one: the fetch's
    /// last act before publishing is reading the clock, so giving that read a hook
    /// enqueues the sign-out to run as soon as the actor becomes free, which is exactly
    /// the encode's suspension. `Gate` cannot stage this window because it would block
    /// the thread while the encode completes, deadlocking the actor and freezing the
    /// sign-out.
    func testASessionReplacedWhileTheCacheIsEncodedIsNeverWritten() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, json: problemListJSON([(1, "two-sum")], status: "ac"))
        let clock = Clock(now)
        let catalog = makeCatalog(tree: tree, transport: transport, clock: clock)

        catalog.sessionDidChange(to: credentials)

        final class HookState: @unchecked Sendable { var fired = false }
        let state = HookState()

        clock.onFirstRead = {
            state.fired = true
            Task { @MainActor in
                catalog.sessionDidChange(to: nil)
            }
        }

        try await catalog.refresh(credentials: credentials)

        XCTAssertTrue(state.fired, "The clock read hook must fire to trigger the sign-out")
        XCTAssertEqual(catalog.problems.map(\.slug), ["two-sum"])
        XCTAssertEqual(catalog.fetchedAt, now)
        XCTAssertEqual(transport.count(for: .problemList), 1)
        XCTAssertTrue(tree.writtenPaths.isEmpty)
        XCTAssertFalse(catalog.lastCacheWriteFailed)
    }

    /// The current session's own refresh is untouched by any of it, and so is a
    /// catalog nobody has told about sessions at all — the state every other test
    /// in this file runs in, pinned here so "undeclared" cannot quietly become
    /// "blocked".
    func testTheDeclaredSessionRefreshesAndAnUndeclaredOneIsUnconstrained() async throws {
        let tree = makeTree()
        let transport = ScriptedLeetCodeTransport()
        transport.serve(.problemList, json: problemListJSON([(1, "two-sum")], status: "ac"))
        let catalog = makeCatalog(tree: tree, transport: transport, clock: Clock(now))

        try await catalog.refresh(credentials: credentials)
        XCTAssertEqual(catalog.problems.map(\.status), [.solved])

        let told = makeCatalog(tree: makeTree(), transport: transport, clock: Clock(now))
        told.sessionDidChange(to: credentials)
        try await told.refresh(credentials: credentials)
        XCTAssertEqual(told.problems.map(\.status), [.solved])
        XCTAssertEqual(transport.count(for: .problemList), 2)
    }
}
