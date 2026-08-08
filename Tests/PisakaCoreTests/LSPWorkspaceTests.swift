import XCTest
@testable import PisakaCore

/// The lifecycle layer: when a server starts, what it has been told, and when we
/// stop trying.
///
/// Every case runs on `ScriptedLSPTransport`, so "the server crashed four times"
/// is a deterministic unit test rather than something that needs a toolchain — and
/// the backoff is an injected closure, so D7's 1/2/4 seconds are *asserted* rather
/// than waited out.
@MainActor
final class LSPWorkspaceTests: XCTestCase {

    // MARK: - Harness

    /// The fake toolchain: one scripted transport per launch, with a record of who
    /// asked for what.
    private final class ServerHarness {
        private(set) var launches: [(id: String, root: URL)] = []
        private(set) var transports: [ScriptedLSPTransport] = []

        /// When set, every launch fails the way a missing executable does.
        var launchError: LSPTransportError?
        var initializeResult: JSONValue = ScriptedLSPTransport.initializeResult()
        /// How long the handshake takes — the seam the "superseded mid-launch"
        /// case is staged through.
        var initializeDelay: TimeInterval = 0
        /// Answer `initialize` at all. `false` stages a handshake that times out.
        var answersInitialize = true

        func makeTransport(
            _ description: LSPServerDescription,
            _ root: URL
        ) throws -> LSPTransport {
            launches.append((description.id, root))
            if let launchError { throw launchError }
            let transport = ScriptedLSPTransport()
            transport.script(
                LSPMethod.initialize,
                answersInitialize
                    ? .reply(initializeResult, after: initializeDelay)
                    : .drop
            )
            // So a `shutdownAll` in a test costs a round trip and not a budget.
            transport.script(LSPMethod.shutdown, .reply(.null))
            transports.append(transport)
            return transport
        }

        var latest: ScriptedLSPTransport {
            transports[transports.count - 1]
        }
    }

    /// Budgets short enough that a hung test fails in a second, long enough that a
    /// loaded machine still wins the race.
    private static let quick = LSPSession.Budgets(
        handshake: 1,
        definition: 1,
        completion: 1,
        resolve: 1,
        shutdown: 1
    )

    private let root = URL(fileURLWithPath: "/tmp/PisakaLSPWorkspace", isDirectory: true)
    private let otherRoot = URL(fileURLWithPath: "/tmp/PisakaLSPOther", isDirectory: true)

    private var mainFile: URL { root.appendingPathComponent("Sources/App/main.swift") }
    private var greeterFile: URL { root.appendingPathComponent("Sources/Greeter/Greeter.swift") }

    private var recordedDelays: [TimeInterval] = []

    /// A workspace already pointed at `root`, with the harness behind its factory.
    private func makeWorkspace(
        harness: ServerHarness,
        registry: LSPServerRegistry = .standard,
        root: URL? = nil
    ) -> LSPWorkspace {
        let workspace = LSPWorkspace(
            registry: registry,
            budgets: LSPWorkspaceTests.quick,
            processID: 4242,
            transportFactory: { [harness] description, launchRoot in
                try harness.makeTransport(description, launchRoot)
            },
            delay: { [weak self] seconds in self?.recordedDelays.append(seconds) }
        )
        workspace.prepareForFolderChange(root: root ?? self.root)
        return workspace
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
    }

    /// Kill the server behind `transport` and wait until the session has noticed.
    private func crash(_ transport: ScriptedLSPTransport) async {
        transport.closeStream()
        await waitFor("the session to notice EOF") { transport.isTerminated }
    }

    override func setUp() {
        super.setUp()
        recordedDelays = []
    }

    // MARK: - Lazy start

    func testTheFirstRequestStartsTheServerAndOpensTheDocument() async throws {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)

        let answer = await workspace.prepare(url: mainFile, language: .swift, text: "let a = 1\n")
        let prepared = try XCTUnwrap(answer)

        XCTAssertEqual(harness.launches.map(\.id), ["sourcekit-lsp"])
        XCTAssertEqual(harness.launches.first?.root, root)
        XCTAssertEqual(prepared.description.id, "sourcekit-lsp")
        XCTAssertEqual(prepared.uri, "file:///tmp/PisakaLSPWorkspace/Sources/App/main.swift")
        XCTAssertEqual(prepared.version, 1)

        XCTAssertEqual(
            harness.latest.sentMethods,
            [LSPMethod.initialize, LSPMethod.initialized, LSPMethod.didOpen]
        )
        let didOpen = try XCTUnwrap(harness.latest.notifications(for: LSPMethod.didOpen).first)
        let document = try XCTUnwrap(didOpen.params?["textDocument"])
        XCTAssertEqual(document["uri"]?.stringValue, prepared.uri)
        XCTAssertEqual(document["languageId"]?.stringValue, "swift")
        XCTAssertEqual(document["version"]?.intValue, 1)
        XCTAssertEqual(document["text"]?.stringValue, "let a = 1\n")

        // The root the server was initialized with is the folder that is open,
        // spelled as a directory URI.
        let initialize = try XCTUnwrap(harness.latest.requests(for: LSPMethod.initialize).first)
        XCTAssertEqual(
            initialize.params?["rootUri"]?.stringValue,
            "file:///tmp/PisakaLSPWorkspace/"
        )
        XCTAssertEqual(initialize.params?["processId"]?.intValue, 4242)
    }

    func testTheServerStartsOnceForARootHoweverManyDocumentsAsk() async {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)

        _ = await workspace.prepare(url: mainFile, language: .swift, text: "a")
        _ = await workspace.prepare(url: greeterFile, language: .swift, text: "b")
        _ = await workspace.prepare(url: mainFile, language: .swift, text: "a")

        XCTAssertEqual(harness.launches.count, 1)
        XCTAssertEqual(workspace.liveServerCount, 1)
        XCTAssertEqual(harness.latest.requests(for: LSPMethod.initialize).count, 1)
        XCTAssertEqual(harness.latest.notifications(for: LSPMethod.didOpen).count, 2)
    }

    func testTwoRequestsRacingTheHandshakeStillStartOneServer() async {
        let harness = ServerHarness()
        harness.initializeDelay = 0.05
        let workspace = makeWorkspace(harness: harness)

        // The second request arrives while the first is still handshaking: it must
        // wait for that launch rather than start a second process.
        async let first = workspace.prepare(url: mainFile, language: .swift, text: "a")
        async let second = workspace.prepare(url: greeterFile, language: .swift, text: "b")
        let results = await [first, second]

        XCTAssertEqual(results.compactMap { $0 }.count, 2)
        XCTAssertEqual(harness.launches.count, 1)
        XCTAssertEqual(workspace.liveServerCount, 1)
    }

    func testALanguageNoServerClaimsIsNeverLaunchedFor() async {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)

        let prepared = await workspace.prepare(
            url: root.appendingPathComponent("app.py"),
            language: .python,
            text: "x = 1"
        )

        XCTAssertNil(prepared)
        XCTAssertTrue(harness.launches.isEmpty)
        XCTAssertFalse(workspace.canServe(.python))
        XCTAssertTrue(workspace.canServe(.swift))
    }

    func testNothingIsPreparedWithNoFolderOpen() async {
        let harness = ServerHarness()
        let workspace = LSPWorkspace(
            budgets: LSPWorkspaceTests.quick,
            transportFactory: { [harness] in try harness.makeTransport($0, $1) }
        )

        let prepared = await workspace.prepare(url: mainFile, language: .swift, text: "a")

        XCTAssertNil(prepared)
        XCTAssertTrue(harness.launches.isEmpty)
        XCTAssertFalse(workspace.canServe(.swift))
    }

    func testADocumentOutsideTheRootIsNeverOpened() async {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)
        _ = await workspace.prepare(url: mainFile, language: .swift, text: "a")

        // An SDK interface, a dependency checkout, a file from the folder the user
        // left: the server was initialized for *this* project and has no business
        // being told about any of them.
        let outside = URL(fileURLWithPath: "/tmp/Elsewhere/Other.swift")
        let prepared = await workspace.prepare(url: outside, language: .swift, text: "a")

        XCTAssertNil(prepared)
        XCTAssertEqual(harness.latest.notifications(for: LSPMethod.didOpen).count, 1)
        XCTAssertEqual(workspace.openDocumentURIs.count, 1)
    }

    // MARK: - A second server, by configuration alone

    func testAFakeSecondServerIsServedByConfigurationAlone() async throws {
        // D9's whole claim: phase 2b is a registry entry, not client code. Nothing
        // below this line knows what "pyright" is.
        let fake = LSPServerDescription(
            id: "fake-pyls",
            languages: [.python],
            launch: .executable(path: "/usr/local/bin/fake-pyls"),
            arguments: ["--stdio"],
            initializationOptions: .object(["strict": .bool(true)])
        )
        let harness = ServerHarness()
        let workspace = makeWorkspace(
            harness: harness,
            registry: LSPServerRegistry([.sourcekitLSP, fake])
        )

        let answer = await workspace.prepare(
            url: root.appendingPathComponent("app.py"),
            language: .python,
            text: "x = 1\n"
        )
        let prepared = try XCTUnwrap(answer)

        XCTAssertEqual(prepared.description.id, "fake-pyls")
        XCTAssertEqual(harness.launches.map(\.id), ["fake-pyls"])
        let didOpen = try XCTUnwrap(harness.latest.notifications(for: LSPMethod.didOpen).first)
        XCTAssertEqual(didOpen.params?["textDocument"]?["languageId"]?.stringValue, "python")

        // The description's options reach `initialize` verbatim.
        let initialize = try XCTUnwrap(harness.latest.requests(for: LSPMethod.initialize).first)
        XCTAssertEqual(
            initialize.params?["initializationOptions"],
            .object(["strict": .bool(true)])
        )

        // And the two servers coexist: a Swift file starts sourcekit-lsp beside it.
        _ = await workspace.prepare(url: mainFile, language: .swift, text: "a")
        XCTAssertEqual(harness.launches.map(\.id), ["fake-pyls", "sourcekit-lsp"])
        XCTAssertEqual(workspace.liveServerCount, 2)
    }

    // MARK: - Request-driven sync (D2)

    func testATextChangeFlushesExactlyOneDidChangeAndAnUnchangedTextFlushesNone() async throws {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)

        let opened = await workspace.prepare(url: mainFile, language: .swift, text: "let a = 1\n")
        let first = try XCTUnwrap(opened)
        XCTAssertEqual(first.version, 1)

        // Same text: the server already has it, so the request costs nothing.
        let repeated = await workspace.prepare(url: mainFile, language: .swift, text: "let a = 1\n")
        let unchanged = try XCTUnwrap(repeated)
        XCTAssertEqual(unchanged.version, 1)
        XCTAssertTrue(harness.latest.notifications(for: LSPMethod.didChange).isEmpty)

        let edited = await workspace.prepare(url: mainFile, language: .swift, text: "let a = 2\n")
        let changed = try XCTUnwrap(edited)
        XCTAssertEqual(changed.version, 2)

        let changes = harness.latest.notifications(for: LSPMethod.didChange)
        XCTAssertEqual(changes.count, 1)
        let params = try XCTUnwrap(changes.first?.params)
        XCTAssertEqual(params["textDocument"]?["version"]?.intValue, 2)
        XCTAssertEqual(params["textDocument"]?["uri"]?.stringValue, first.uri)
        // Full text sync (D2): one change entry, whole document, no `range`.
        XCTAssertEqual(params["contentChanges"]?.arrayValue?.count, 1)
        XCTAssertEqual(params["contentChanges"]?[0]?["text"]?.stringValue, "let a = 2\n")
        XCTAssertNil(params["contentChanges"]?[0]?["range"])

        XCTAssertEqual(
            harness.latest.sentMethods,
            [LSPMethod.initialize, LSPMethod.initialized, LSPMethod.didOpen, LSPMethod.didChange]
        )
    }

    func testClosingADocumentTellsTheServerOnceAndForgetsIt() async {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)
        _ = await workspace.prepare(url: mainFile, language: .swift, text: "a")

        await workspace.didClose(url: mainFile)

        XCTAssertEqual(harness.latest.notifications(for: LSPMethod.didClose).count, 1)
        XCTAssertTrue(workspace.openDocumentURIs.isEmpty)

        // A second close — a tab that was never opened, or one closed twice — is a
        // no-op rather than a notification for a document the server has dropped.
        await workspace.didClose(url: mainFile)
        await workspace.didClose(url: greeterFile)
        XCTAssertEqual(harness.latest.notifications(for: LSPMethod.didClose).count, 1)

        // Reopening starts the document over at version 1.
        let reopened = await workspace.prepare(url: mainFile, language: .swift, text: "b")
        XCTAssertEqual(reopened?.version, 1)
        XCTAssertEqual(harness.latest.notifications(for: LSPMethod.didOpen).count, 2)
    }

    // MARK: - Folder switch

    func testAFolderSwitchClosesEveryDocumentAndShutsEveryServerDown() async throws {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)
        _ = await workspace.prepare(url: mainFile, language: .swift, text: "a")
        _ = await workspace.prepare(url: greeterFile, language: .swift, text: "b")

        let before = workspace.currentRequestGeneration
        let token = workspace.prepareForFolderChange(root: otherRoot)
        XCTAssertGreaterThan(token, before)
        await workspace.shutdownAll()

        let closed = harness.latest.notifications(for: LSPMethod.didClose)
            .compactMap { $0.params?["textDocument"]?["uri"]?.stringValue }
        XCTAssertEqual(Set(closed).count, 2)
        XCTAssertEqual(
            harness.latest.sentMethods.suffix(2),
            [LSPMethod.shutdown, LSPMethod.exit]
        )
        XCTAssertTrue(harness.latest.isTerminated)
        XCTAssertEqual(workspace.liveServerCount, 0)
        XCTAssertTrue(workspace.openDocumentURIs.isEmpty)

        // The new folder gets its own server, and its own `(server, root)` budget.
        _ = await workspace.prepare(
            url: otherRoot.appendingPathComponent("main.swift"),
            language: .swift,
            text: "a"
        )
        XCTAssertEqual(harness.launches.count, 2)
        XCTAssertEqual(harness.launches.last?.root, otherRoot)
    }

    func testARepeatedFolderChangeForTheSameRootIsANoOp() {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)

        let first = workspace.prepareForFolderChange(root: root)
        let second = workspace.prepareForFolderChange(root: root)

        XCTAssertEqual(first, second)
        XCTAssertEqual(workspace.root, root)
    }

    func testAFolderSwitchSupersedesALaunchThatIsStillHandshaking() async {
        let harness = ServerHarness()
        harness.initializeDelay = 0.2
        let workspace = makeWorkspace(harness: harness)

        let pending = Task { await workspace.prepare(url: mainFile, language: .swift, text: "a") }
        await waitFor("the launch to start") { harness.launches.count == 1 }

        workspace.prepareForFolderChange(root: otherRoot)
        let prepared = await pending.value

        // The server finished starting into a project nobody is looking at: it
        // answers nothing, it is not stored, and — the part that matters — its
        // process does not survive the switch.
        XCTAssertNil(prepared)
        XCTAssertTrue(harness.latest.isTerminated)
        XCTAssertEqual(workspace.liveServerCount, 0)
        XCTAssertTrue(workspace.openDocumentURIs.isEmpty)

        // Superseded is not failed: the new root starts with a full restart budget.
        XCTAssertTrue(recordedDelays.isEmpty)
        _ = await workspace.prepare(
            url: otherRoot.appendingPathComponent("main.swift"),
            language: .swift,
            text: "a"
        )
        XCTAssertTrue(recordedDelays.isEmpty)
        XCTAssertEqual(harness.launches.count, 2)
    }

    // MARK: - Crash, backoff, giving up (D7)

    func testThreeCrashesRestartAndTheFourthMarksTheServerUnavailable() async {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)

        _ = await workspace.prepare(url: mainFile, language: .swift, text: "a")
        XCTAssertEqual(harness.launches.count, 1)

        for attempt in 1...3 {
            await crash(harness.latest)
            let prepared = await workspace.prepare(url: mainFile, language: .swift, text: "a")
            XCTAssertNotNil(prepared, "crash \(attempt) must be restarted from")
            XCTAssertEqual(harness.launches.count, attempt + 1)
        }

        // D7's numbers, in order, paid before each restart.
        XCTAssertEqual(recordedDelays, LSPWorkspace.backoffDelays)
        XCTAssertFalse(workspace.isUnavailable(.swift))

        await crash(harness.latest)
        let givenUp = await workspace.prepare(url: mainFile, language: .swift, text: "a")

        XCTAssertNil(givenUp)
        XCTAssertTrue(workspace.isUnavailable(.swift))
        XCTAssertFalse(workspace.canServe(.swift))
        XCTAssertEqual(harness.launches.count, 4, "the fourth failure must not launch again")
        XCTAssertEqual(recordedDelays, LSPWorkspace.backoffDelays, "no backoff is paid after giving up")

        // And it stays given up for the rest of the run.
        _ = await workspace.prepare(url: greeterFile, language: .swift, text: "b")
        XCTAssertEqual(harness.launches.count, 4)
    }

    func testARestartedServerIsToldAboutTheDocumentAgainRatherThanChangedAgainst() async throws {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)
        _ = await workspace.prepare(url: mainFile, language: .swift, text: "let a = 1\n")

        let first = harness.latest
        await crash(first)

        let answer = await workspace.prepare(url: mainFile, language: .swift, text: "let a = 2\n")
        let prepared = try XCTUnwrap(answer)

        // The new process has never heard of this file, so a version bump against
        // it would be a change to a document it does not have.
        XCTAssertEqual(prepared.version, 1)
        XCTAssertNotIdentical(harness.latest, first)
        XCTAssertEqual(harness.latest.notifications(for: LSPMethod.didOpen).count, 1)
        XCTAssertTrue(harness.latest.notifications(for: LSPMethod.didChange).isEmpty)
        XCTAssertEqual(
            harness.latest.notifications(for: LSPMethod.didOpen).first?
                .params?["textDocument"]?["text"]?.stringValue,
            "let a = 2\n"
        )
    }

    func testALaunchThatFailsSpendsTheSameBudgetAndNeverRetriesAfterwards() async {
        // A machine with no Xcode: `xcrun --find` answers nothing, so the factory
        // throws. That must stop, not retry once per keystroke.
        let harness = ServerHarness()
        harness.launchError = .launchFailed("sourcekit-lsp not found")
        let workspace = makeWorkspace(harness: harness)

        for _ in 1...4 {
            let prepared = await workspace.prepare(url: mainFile, language: .swift, text: "a")
            XCTAssertNil(prepared)
        }

        XCTAssertEqual(harness.launches.count, 4)
        XCTAssertTrue(workspace.isUnavailable(.swift))

        _ = await workspace.prepare(url: mainFile, language: .swift, text: "a")
        XCTAssertEqual(harness.launches.count, 4)
        XCTAssertEqual(recordedDelays, LSPWorkspace.backoffDelays)
    }

    func testAHandshakeThatNeverAnswersCountsAsAFailure() async {
        let harness = ServerHarness()
        harness.answersInitialize = false
        let workspace = makeWorkspace(harness: harness)

        let prepared = await workspace.prepare(url: mainFile, language: .swift, text: "a")

        XCTAssertNil(prepared)
        XCTAssertEqual(harness.launches.count, 1)
        // The handshake timing out kills the process rather than leaving the
        // orphan the release check greps for.
        XCTAssertTrue(harness.latest.isTerminated)
        XCTAssertEqual(workspace.liveServerCount, 0)
    }

    func testAServerThatChoosesAnotherPositionEncodingIsGivenUpOnImmediately() async {
        // Every offset in this codebase is UTF-16, and a server's answer here does
        // not change between restarts — so this is terminal, not countable.
        let harness = ServerHarness()
        harness.initializeResult = ScriptedLSPTransport.initializeResult(positionEncoding: "utf-8")
        let workspace = makeWorkspace(harness: harness)

        let prepared = await workspace.prepare(url: mainFile, language: .swift, text: "a")

        XCTAssertNil(prepared)
        XCTAssertTrue(workspace.isUnavailable(.swift))
        XCTAssertTrue(harness.latest.isTerminated)
        XCTAssertEqual(harness.launches.count, 1)

        _ = await workspace.prepare(url: mainFile, language: .swift, text: "a")
        XCTAssertEqual(harness.launches.count, 1)
        XCTAssertTrue(recordedDelays.isEmpty)
    }

    // MARK: - Paths

    func testTheSameFolderSpelledTwoWaysIsOneServer() async {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)

        _ = await workspace.prepare(url: mainFile, language: .swift, text: "a")
        // `/tmp/PisakaLSPWorkspace/Sources/App/../App/main.swift` is the same
        // document, and must not be opened a second time.
        let scenic = root.appendingPathComponent("Sources/App/../App/main.swift")
        let prepared = await workspace.prepare(url: scenic, language: .swift, text: "a")

        XCTAssertEqual(prepared?.uri, "file:///tmp/PisakaLSPWorkspace/Sources/App/main.swift")
        XCTAssertEqual(harness.latest.notifications(for: LSPMethod.didOpen).count, 1)
        XCTAssertEqual(workspace.openDocumentURIs.count, 1)
    }
}
