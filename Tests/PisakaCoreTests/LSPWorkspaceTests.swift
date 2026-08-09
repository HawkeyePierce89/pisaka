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
    /// Work run *inside* D7's backoff wait — the seam the "superseded while waiting
    /// out the backoff" case is staged through.
    private var onDelay: (@MainActor () async -> Void)?

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
            delay: { [weak self] seconds in
                self?.recordedDelays.append(seconds)
                if let hook = self?.onDelay { await hook() }
            }
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
        onDelay = nil
        backoffIsReleased = false
    }

    /// Flipped by the test to let a launch out of the staged backoff wait.
    private var backoffIsReleased = false

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

    /// Two requests for **one** file, resuming from one launch in the same turn,
    /// must not interleave their flushes.
    ///
    /// This is the ordinary shape, not a contrived one: a keystroke and a ⌘-click
    /// queue behind the same cold start, and both wake when the handshake lands.
    /// Interleaved they would each read `documents[uri]` as empty and each send a
    /// `didOpen` for the same URI at version 1 — two opens of one document, and a
    /// version that never advances past what the *second* one recorded.
    func testTwoRequestsForOneFileQueuedBehindALaunchDoNotInterleave() async throws {
        let harness = ServerHarness()
        harness.initializeDelay = 0.05
        let workspace = makeWorkspace(harness: harness)

        async let first = workspace.prepare(url: mainFile, language: .swift, text: "let a = 1")
        async let second = workspace.prepare(url: mainFile, language: .swift, text: "let a = 12")
        let prepared = await [first, second]

        XCTAssertEqual(harness.launches.count, 1)
        let transport = harness.latest
        XCTAssertEqual(
            transport.notifications(for: LSPMethod.didOpen).count, 1,
            "one document is opened once; the later text is a didChange"
        )
        XCTAssertEqual(transport.notifications(for: LSPMethod.didChange).count, 1)
        XCTAssertEqual(
            prepared.compactMap { $0?.version }.sorted(), [1, 2],
            "the versions the two requests were answered with are distinct and ordered"
        )
        // And the record agrees with the wire: the text the *second* notification
        // carried is the one a further request is compared against.
        let last = transport.notifications(for: LSPMethod.didChange).last
        let sent = try XCTUnwrap(last?.params?["contentChanges"]?[0]?["text"]?.stringValue)
        let repeated = await workspace.prepare(url: mainFile, language: .swift, text: sent)
        XCTAssertEqual(repeated?.version, 2)
        XCTAssertEqual(
            transport.notifications(for: LSPMethod.didChange).count, 1,
            "nothing is re-sent for text the server already holds"
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

    /// A tab closed **while the buffer is being flushed** must not leave the
    /// document recorded as open.
    ///
    /// The two are ordinary neighbours, not an exotic pair: closing a tab is one of
    /// the things that supersedes a completion, so a `didClose` landing while a
    /// `didChange` for the same file is in flight is the common shape. `send` is a
    /// read-modify-write over `documents[uri]` with an `await` in the middle, so a
    /// close that took no claim would drop the state and then have it written *back*
    /// by the notification already on its way — leaving a document the server has
    /// been told is closed recorded here as open, with exactly the text it holds.
    /// The next request reads that as "nothing to send", never re-`didOpen`s, and
    /// asks about a document the server dropped — silently, for the rest of the app
    /// run.
    func testATabClosedWhileTheBufferIsFlushingDoesNotLeaveTheDocumentRecordedAsOpen() async {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)
        _ = await workspace.prepare(url: mainFile, language: .swift, text: "let a = 1")

        // Hold the writer inside the `didChange`, which leaves the main actor free
        // — the window a close would otherwise interleave into.
        let reached = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        harness.latest.onSend { method in
            guard method == LSPMethod.didChange else { return }
            reached.signal()
            release.wait()
        }

        let flushing = Task { await workspace.prepare(url: mainFile, language: .swift, text: "let a = 2") }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                reached.wait()
                continuation.resume()
            }
        }

        let closing = Task { await workspace.didClose(url: mainFile) }
        // Let the close reach the point where it either takes the claim (and waits)
        // or walks straight into the middle of the flush.
        try? await Task.sleep(nanoseconds: 30_000_000)
        release.signal()
        _ = await flushing.value
        await closing.value
        harness.latest.onSend(nil)

        XCTAssertTrue(
            workspace.openDocumentURIs.isEmpty,
            "the close is the last word: nothing may be re-recorded behind it"
        )
        XCTAssertEqual(harness.latest.notifications(for: LSPMethod.didClose).count, 1)
        XCTAssertEqual(
            harness.latest.sentMethods.last, LSPMethod.didClose,
            "and it is the last thing the server was told about the document"
        )

        // The proof that the record and the server still agree: the next request
        // opens the document afresh rather than assuming it is still there.
        let reopened = await workspace.prepare(url: mainFile, language: .swift, text: "let a = 2")
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

    // MARK: - Termination

    func testTerminateNowStopsEveryServerWithoutAwaitingAnything() async {
        let fake = LSPServerDescription(
            id: "fake-pyls",
            languages: [.python],
            launch: .executable(path: "/usr/local/bin/fake-pyls"),
            arguments: [],
            initializationOptions: nil
        )
        let harness = ServerHarness()
        let workspace = makeWorkspace(
            harness: harness,
            registry: LSPServerRegistry([.sourcekitLSP, fake])
        )
        _ = await workspace.prepare(url: mainFile, language: .swift, text: "a")
        _ = await workspace.prepare(
            url: root.appendingPathComponent("app.py"),
            language: .python,
            text: "x = 1"
        )
        XCTAssertEqual(workspace.liveServerCount, 2)

        // The app's `willTerminateNotification` observer: no `await` is available
        // there, so everything this call has to do, it does synchronously.
        workspace.terminateNow()

        XCTAssertEqual(harness.transports.count, 2)
        XCTAssertTrue(harness.transports.allSatisfy(\.isTerminated))
        XCTAssertEqual(workspace.liveServerCount, 0)
        XCTAssertTrue(workspace.openDocumentURIs.isEmpty)
        // Unconditional, not a handshake: nothing polite was sent first.
        XCTAssertFalse(harness.latest.sentMethods.contains(LSPMethod.shutdown))
    }

    func testTerminateNowKillsAServerThatIsStillHandshaking() async {
        // The likeliest quit-time state: a first request has just launched a server
        // and sourcekit-lsp is resolving the build system, which is the slowest
        // thing this layer ever does.
        let harness = ServerHarness()
        harness.initializeDelay = 0.2
        let workspace = makeWorkspace(harness: harness)

        let pending = Task { await workspace.prepare(url: mainFile, language: .swift, text: "a") }
        await waitFor("the launch to start") { harness.launches.count == 1 }

        workspace.terminateNow()

        XCTAssertTrue(harness.latest.isTerminated)
        let prepared = await pending.value
        XCTAssertNil(prepared)
        XCTAssertEqual(workspace.liveServerCount, 0)
    }

    func testTerminateNowIsIdempotentAndSurvivesHavingNothingToDo() async {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)

        workspace.terminateNow()
        _ = await workspace.prepare(url: mainFile, language: .swift, text: "a")
        workspace.terminateNow()
        workspace.terminateNow()

        XCTAssertTrue(harness.latest.isTerminated)
        XCTAssertEqual(workspace.liveServerCount, 0)
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

    /// The same supersession, staged over the *widest* window this layer has.
    ///
    /// A launch waits out up to four seconds of D7's backoff before it touches
    /// anything, and a folder switch fits through that comfortably. The token has
    /// to be pinned before the wait, not after it: a launch that pinned the epoch
    /// the switch had already bumped would pass its own guard and file a session
    /// into the maps `shutdownAll()` just emptied — where the next visit to that
    /// folder finds a corpse and charges its death against the restart budget.
    func testAFolderSwitchDuringTheBackoffSupersedesTheRestart() async {
        let harness = ServerHarness()
        harness.launchError = .launchFailed("no toolchain")
        let workspace = makeWorkspace(harness: harness)

        // One failure, so the next launch has a backoff to be caught inside.
        _ = await workspace.prepare(url: mainFile, language: .swift, text: "a")
        harness.launchError = nil
        onDelay = { [weak self] in
            while self?.backoffIsReleased == false { await Task.yield() }
        }

        let pending = Task { await workspace.prepare(url: mainFile, language: .swift, text: "a") }
        await waitFor("the backoff to start") { self.recordedDelays == [1] }

        workspace.prepareForFolderChange(root: otherRoot)
        backoffIsReleased = true
        let prepared = await pending.value

        XCTAssertNil(prepared)
        XCTAssertEqual(workspace.liveServerCount, 0, "nothing may be filed under the old root")
        XCTAssertTrue(workspace.openDocumentURIs.isEmpty)
        // Superseded is not failed, so the *new* root starts with a full budget —
        // and the old one was never charged for a switch either.
        XCTAssertEqual(
            harness.launches.count, 1,
            "a switch during the wait must not launch a server for the old root"
        )
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

    /// Two requests in flight over one crash cost **one** restart between them.
    ///
    /// Both read the same live session and both suspend on `isRunning`, so both
    /// come back holding the same corpse — the interleaving D7's counter has to
    /// survive. Booking a failure twice for one death would spend the budget of
    /// three restarts in two crashes and mark the server unavailable early, which
    /// is silent and lasts the rest of the app run.
    func testTwoRequestsObservingOneCrashSpendOneRestartBetweenThem() async {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)

        _ = await workspace.prepare(url: mainFile, language: .swift, text: "a")
        await crash(harness.latest)

        async let first = workspace.prepare(url: mainFile, language: .swift, text: "a")
        async let second = workspace.prepare(url: greeterFile, language: .swift, text: "b")
        let answers = await [first, second]

        XCTAssertEqual(answers.compactMap { $0 }.count, 2, "both requests are served")
        XCTAssertEqual(harness.launches.count, 2, "one crash, one restart — not two servers")
        XCTAssertEqual(recordedDelays, [1], "one crash is one backoff")

        // The budget is intact: the second and third crashes are still restarted
        // from, at D7's own delays, and only the fourth is terminal.
        for expected in [2.0, 4.0] {
            await crash(harness.latest)
            let prepared = await workspace.prepare(url: mainFile, language: .swift, text: "a")
            XCTAssertNotNil(prepared)
            XCTAssertEqual(recordedDelays.last, expected)
            XCTAssertFalse(workspace.isUnavailable(.swift))
        }

        await crash(harness.latest)
        let givenUp = await workspace.prepare(url: mainFile, language: .swift, text: "a")
        XCTAssertNil(givenUp)
        XCTAssertTrue(workspace.isUnavailable(.swift))
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

    /// A factory that declines to answer *yet* is not a failure.
    ///
    /// The transport factory is `@MainActor` and called inside the launch turn, so
    /// the app's one cannot block on `xcrun --find`: an unresolved toolchain answers
    /// `notReady` and the lookup runs on a background queue. Charging that against
    /// D7's budget would let three ⌘-clicks in the first second after launch retire
    /// a perfectly good server for the whole app run — silently, and with nothing to
    /// undo it.
    func testAFactoryThatIsNotReadyYetCostsNoRestartBudget() async {
        let harness = ServerHarness()
        harness.launchError = .notReady
        let workspace = makeWorkspace(harness: harness)

        for _ in 1...5 {
            let prepared = await workspace.prepare(url: mainFile, language: .swift, text: "a")
            XCTAssertNil(prepared, "the request falls back to tree-sitter")
        }

        XCTAssertEqual(harness.launches.count, 5, "every request may try again")
        XCTAssertFalse(workspace.isUnavailable(.swift))
        XCTAssertTrue(workspace.canServe(.swift))
        XCTAssertTrue(recordedDelays.isEmpty, "nothing failed, so nothing is backed off from")

        // And the moment the lookup lands, the next request starts the server with
        // its budget untouched.
        harness.launchError = nil
        let prepared = await workspace.prepare(url: mainFile, language: .swift, text: "a")
        XCTAssertNotNil(prepared)
        XCTAssertTrue(recordedDelays.isEmpty)
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
