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
        /// The descriptions themselves, in launch order — what the "a changed
        /// launch description restarts the server" case checks the *new* process
        /// was started from.
        private(set) var launched: [LSPServerDescription] = []
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
            launched.append(description)
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

        /// The transport handed over for the *first* launch of `id` — how the
        /// registry-update cases tell one server's process from another's without
        /// counting launches by hand.
        func firstTransport(of id: String) -> ScriptedLSPTransport? {
            guard let index = launches.firstIndex(where: { $0.id == id }) else { return nil }
            return index < transports.count ? transports[index] : nil
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
        // spelled as a directory URI *and* as the deprecated path — the second is
        // the only one pyright reads, and the two must name the same directory.
        let initialize = try XCTUnwrap(harness.latest.requests(for: LSPMethod.initialize).first)
        XCTAssertEqual(
            initialize.params?["rootUri"]?.stringValue,
            "file:///tmp/PisakaLSPWorkspace/"
        )
        XCTAssertEqual(
            initialize.params?["rootPath"]?.stringValue,
            "/tmp/PisakaLSPWorkspace"
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

    func testADescriptionsConfigurationReachesTheServerItWasWrittenFor() async throws {
        // The other half of the same claim: a server that needs a *setting* gets
        // it as data on its description too, with nothing here knowing what the
        // setting means.
        let settings: JSONValue = .object(["fake": .object(["schemaStore": .bool(true)])])
        let fake = LSPServerDescription(
            id: "fake-yamlls",
            languages: [.yaml],
            launch: .executable(path: "/usr/local/bin/fake-yamlls"),
            arguments: ["--stdio"],
            configuration: settings
        )
        let harness = ServerHarness()
        let workspace = makeWorkspace(
            harness: harness,
            registry: LSPServerRegistry([.sourcekitLSP, fake])
        )

        _ = await workspace.prepare(
            url: root.appendingPathComponent("compose.yml"),
            language: .yaml,
            text: "services:\n"
        )

        let pushed = try XCTUnwrap(
            harness.latest.notifications(for: LSPMethod.didChangeConfiguration).first
        )
        XCTAssertEqual(pushed.params?["settings"], settings)

        // sourcekit-lsp carries none, so its handshake gained nothing.
        _ = await workspace.prepare(url: mainFile, language: .swift, text: "a")
        XCTAssertTrue(
            harness.latest.notifications(for: LSPMethod.didChangeConfiguration).isEmpty
        )
    }

    /// `.tsx` and `.jsx` share a `SyntaxLanguage` case with their plain
    /// counterparts, and must not share a `languageId`.
    ///
    /// `typescript-language-server` hands the id straight to tsserver as a script
    /// kind, and corrects a wrong one only when it is not a mode it recognises —
    /// `"typescript"` is, so a `.tsx` announced that way is opened as
    /// `ScriptKind.TS`, whose variant parses no JSX. The server then *answers*,
    /// wrongly, about every identifier in the JSX half of the file, and an answer
    /// is the one thing `RoutingIntelligenceProvider` cannot fall back from.
    func testTheJSXAndTSXFlavoursAreOpenedUnderTheirOwnLanguageIDs() async throws {
        let cases: [(String, SyntaxLanguage, String)] = [
            ("view.tsx", .typescript, "typescriptreact"),
            ("view.ts", .typescript, "typescript"),
            ("view.jsx", .javascript, "javascriptreact"),
            ("view.js", .javascript, "javascript"),
            ("view.mjs", .javascript, "javascript")
        ]
        let fake = LSPServerDescription(
            id: "fake-tsls",
            languages: [.typescript, .javascript],
            launch: .executable(path: "/usr/local/bin/fake-tsls"),
            arguments: ["--stdio"]
        )
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness, registry: LSPServerRegistry([fake]))

        for (fileName, language, _) in cases {
            _ = await workspace.prepare(
                url: root.appendingPathComponent(fileName),
                language: language,
                text: "const a = 1\n"
            )
        }

        let opened = harness.latest.notifications(for: LSPMethod.didOpen)
        XCTAssertEqual(opened.count, cases.count)
        XCTAssertEqual(
            opened.map { $0.params?["textDocument"]?["languageId"]?.stringValue },
            cases.map(\.2)
        )
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

    /// A folder switch **while the buffer is being flushed** must not have the
    /// document written back behind it.
    ///
    /// The tab-close case above takes the per-document claim, so it queues. A
    /// folder switch cannot and does not: `shutdownAll()` drops every document
    /// synchronously, before its first `await`, because a crash and a quit do not
    /// wait for a keystroke. So the notification already on its way resumes into a
    /// world where its document was forgotten and re-records it — under the same
    /// `(server, root)` key the *next* server for that folder will be filed under,
    /// which has never heard of the file. Every later flush then reads "nothing to
    /// send" or bumps a version against a document that was never `didOpen`ed, and
    /// that file answers from tree-sitter for the life of the server. Silently.
    func testAFolderSwitchWhileTheBufferIsFlushingDoesNotLeaveTheDocumentRecordedAsOpen() async {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)
        _ = await workspace.prepare(url: mainFile, language: .swift, text: "let a = 1")

        // Hold the writer inside the `didChange`, which leaves the main actor free
        // — the window the switch interleaves into.
        let first = harness.latest
        let reached = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        first.onSend { method in
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

        workspace.prepareForFolderChange(root: otherRoot)
        let shuttingDown = Task { await workspace.shutdownAll() }
        // Let the shutdown run its synchronous clear and reach its first `await`,
        // so the notification resumes *after* the state it would resurrect is gone.
        try? await Task.sleep(nanoseconds: 30_000_000)
        release.signal()
        let prepared = await flushing.value
        await shuttingDown.value
        first.onSend(nil)

        XCTAssertNil(prepared, "a request whose server was shut down under it has no answer")
        XCTAssertTrue(
            workspace.openDocumentURIs.isEmpty,
            "the switch is the last word: nothing may be re-recorded behind it"
        )

        // The proof that the record and the next server agree: coming back to the
        // folder opens the document afresh rather than changing against a document
        // nothing has ever been told about.
        workspace.prepareForFolderChange(root: root)
        let reopened = await workspace.prepare(url: mainFile, language: .swift, text: "let a = 2")
        XCTAssertEqual(reopened?.version, 1)
        XCTAssertEqual(harness.latest.notifications(for: LSPMethod.didOpen).count, 1)
        XCTAssertTrue(harness.latest.notifications(for: LSPMethod.didChange).isEmpty)
    }

    /// The *second* observer of the crash that spent the last of D7's budget must
    /// not launch a server nothing will ever route to.
    ///
    /// `unavailable` is checked when `liveSession` is entered, and both requests
    /// pass that check together — the key is retired several suspension points
    /// later, by the one that books the death. The other resumes to find the slot
    /// empty (so neither the identity branch nor the replacement branch answers)
    /// and would start a server that `canServe` already says `false` for: a live
    /// `sourcekit-lsp` holding a build-system cache that nothing reaches until the
    /// next folder switch or the quit.
    func testTheSecondObserverOfTheFinalCrashLaunchesNothing() async {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)

        _ = await workspace.prepare(url: mainFile, language: .swift, text: "a")
        // Three crashes, three restarts: the budget is down to its last failure.
        for _ in 1...3 {
            await crash(harness.latest)
            _ = await workspace.prepare(url: mainFile, language: .swift, text: "a")
        }
        XCTAssertEqual(harness.launches.count, 4)
        XCTAssertFalse(workspace.isUnavailable(.swift))

        // Both requests read the same live session and both come back holding the
        // same corpse — `testTwoRequestsObservingOneCrashSpendOneRestartBetweenThem`'s
        // interleaving, on the crash that is terminal.
        await crash(harness.latest)
        async let first = workspace.prepare(url: mainFile, language: .swift, text: "a")
        async let second = workspace.prepare(url: greeterFile, language: .swift, text: "b")
        let answers = await [first, second]

        XCTAssertTrue(answers.allSatisfy { $0 == nil }, "the server has been given up on")
        XCTAssertTrue(workspace.isUnavailable(.swift))
        XCTAssertFalse(workspace.canServe(.swift))
        XCTAssertEqual(
            harness.launches.count, 4,
            "nothing is ever launched for a `(server, root)` that has been retired"
        )
        XCTAssertEqual(workspace.liveServerCount, 0)
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

    /// The window *before* the teardown, which the case above deliberately steps
    /// over: a flush that resumes after `prepareForFolderChange` but before the
    /// `shutdownAll()` it scheduled.
    ///
    /// The switch is two steps and only the first is synchronous, so this window
    /// is not exotic — it is every folder switch, for as long as one main-actor
    /// turn lasts. Inside it the flush's own defences all pass: the session is
    /// still filed under its key, so `isCurrent` is true and the notification is
    /// recorded rather than rejected. Without a second generation check the
    /// request would be handed a document for the root the user has just left and
    /// would go on to ask the *old* project's server where a symbol is declared —
    /// an answer naming a file under a closed folder, which nothing downstream can
    /// tell from a good one.
    func testAFlushFinishingBetweenTheSwitchAndTheTeardownAnswersNothing() async {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)
        _ = await workspace.prepare(url: mainFile, language: .swift, text: "let a = 1")

        // Held inside the `didChange`, exactly as the shutdown case above — the
        // difference is entirely in what happens while the writer is held.
        let first = harness.latest
        let reached = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        first.onSend { method in
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

        // The switch, and *nothing else*: no `shutdownAll()`, so the session is
        // still live and still filed under its key when the flush resumes.
        workspace.prepareForFolderChange(root: otherRoot)
        release.signal()
        let prepared = await flushing.value
        first.onSend(nil)

        XCTAssertNil(
            prepared,
            "a request pinned to the folder the user left may not be handed a document"
        )
        XCTAssertEqual(workspace.liveServerCount, 1, "the teardown is the caller's, not this method's")
    }

    // MARK: - Answer validity

    /// The same window one layer later: a request that was *already* prepared when
    /// the switch happened.
    ///
    /// `prepare`'s two guards cover the hops it makes itself; they cannot cover the
    /// request, which is the widest wait in the layer — a server is allowed to take
    /// seconds to answer where a flush takes a write. A folder switch inside it
    /// leaves `documents` exactly as it was until the scheduled `shutdownAll()`
    /// runs, so the version alone still matches and the answer — from a server
    /// initialized for the folder the user left — would publish.
    func testADocumentPreparedBeforeAFolderSwitchIsNoLongerCurrentAfterIt() async throws {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)
        let answer = await workspace.prepare(url: mainFile, language: .swift, text: "let a = 1")
        let prepared = try XCTUnwrap(answer)
        XCTAssertTrue(workspace.stillHolds(prepared))

        // The switch, and *nothing else*: the teardown it schedules runs a turn
        // later, which is the whole of the window being staged.
        workspace.prepareForFolderChange(root: otherRoot)

        XCTAssertTrue(
            workspace.openDocumentURIs.contains(prepared.uri),
            "the staging is only meaningful while the version half still matches"
        )
        XCTAssertFalse(
            workspace.stillHolds(prepared),
            "an answer from the server of a folder the user has left is no answer"
        )
    }

    /// Re-opening the same folder is not a switch, so nothing in flight is
    /// invalidated by it — the no-op path `prepareForFolderChange` shares with
    /// `SymbolIndexModel`.
    func testAPreparedDocumentSurvivesAPreparationForTheSameFolder() async throws {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)
        let answer = await workspace.prepare(url: mainFile, language: .swift, text: "let a = 1")
        let prepared = try XCTUnwrap(answer)

        workspace.prepareForFolderChange(root: root)

        XCTAssertTrue(workspace.stillHolds(prepared))
    }

    /// The version half, unchanged by the generation half: a second request that
    /// talked the server into different text invalidates the first one's answer.
    func testADocumentIsNoLongerCurrentOnceAnotherRequestChangedTheServersText() async throws {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)
        let firstAnswer = await workspace.prepare(url: mainFile, language: .swift, text: "let a = 1")
        let secondAnswer = await workspace.prepare(url: mainFile, language: .swift, text: "let a = 2")
        let first = try XCTUnwrap(firstAnswer)
        let second = try XCTUnwrap(secondAnswer)

        XCTAssertEqual(second.version, first.version + 1)
        XCTAssertFalse(workspace.stillHolds(first))
        XCTAssertTrue(workspace.stillHolds(second))
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

    /// The folder switch runs `shutdownAll()` from a detached `Task`, so a quit can
    /// land while it is parked on a server's goodbye. `terminateNow()` reaches a
    /// process only through `transports`, and the process is alive until that
    /// goodbye returns — so the map has to keep holding it until then, exactly as
    /// the registry-update path does.
    func testTerminateNowKillsAServerAFolderSwitchIsStillShuttingDown() async {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)

        _ = await workspace.prepare(url: mainFile, language: .swift, text: "a")
        let transport = harness.latest
        transport.script(LSPMethod.shutdown, .reply(.null, after: 0.5))

        async let teardown: Void = workspace.shutdownAll()
        await waitFor("the switch to reach the shutdown") {
            !transport.requests(for: LSPMethod.shutdown).isEmpty
        }
        XCTAssertFalse(transport.isTerminated, "the shutdown answered before the quit could land")

        workspace.terminateNow()
        XCTAssertTrue(
            transport.isTerminated,
            "a server a folder switch was still stopping was left out of terminateNow()'s reach"
        )

        await teardown
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

    /// A request *waiting on somebody else's launch* when the folder changes is
    /// answered by that launch's refusal and starts nothing of its own.
    ///
    /// The waiter is the second way into `liveSession`'s fall-through to a launch
    /// (the first is a session that turned out to be dead), and it is the one that
    /// resumes *after* the switch by construction: the launch it waits on runs to
    /// the end of its handshake first. Nothing may be started for the abandoned
    /// root at that point — a server filed into the maps `shutdownAll()` has just
    /// emptied is one nothing tears down until the next switch or the quit.
    func testAFolderSwitchWhileARequestWaitsOnALaunchStartsNothingForTheOldRoot() async {
        let harness = ServerHarness()
        harness.initializeDelay = 0.2
        let workspace = makeWorkspace(harness: harness)

        let first = Task { await workspace.prepare(url: mainFile, language: .swift, text: "a") }
        await waitFor("the launch to start") { harness.launches.count == 1 }

        // The second request finds that launch in flight and waits on it. It does
        // nothing observable while it waits, so the sync point is the main actor
        // being handed over: this task is already queued on it, and the sleep
        // below is many turns more than it needs to reach the wait.
        let second = Task { await workspace.prepare(url: greeterFile, language: .swift, text: "b") }
        try? await Task.sleep(nanoseconds: 20_000_000)

        workspace.prepareForFolderChange(root: otherRoot)
        let answers = await [first.value, second.value]

        XCTAssertTrue(answers.compactMap { $0 }.isEmpty, "neither request survives the switch")
        XCTAssertEqual(
            harness.launches.count, 1,
            "the waiter must not launch a server for the root the switch left"
        )
        XCTAssertEqual(workspace.liveServerCount, 0)
        XCTAssertTrue(harness.latest.isTerminated)
        XCTAssertTrue(recordedDelays.isEmpty, "superseded is not failed")
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

    // MARK: - Dynamic registration (D16)

    /// The description a 2b install produces: a real `.executable(path:)` under the
    /// install root, served for the languages that server covers.
    private func downloaded(
        id: String = "typescript-language-server",
        languages: Set<SyntaxLanguage> = [.typescript, .javascript],
        path: String = "/Application Support/LanguageServers/node/24.19.0/bin/node",
        arguments: [String] = ["--stdio"],
        options: JSONValue? = nil
    ) -> LSPServerDescription {
        LSPServerDescription(
            id: id,
            languages: languages,
            launch: .executable(path: path),
            arguments: arguments,
            initializationOptions: options
        )
    }

    private var appFile: URL { root.appendingPathComponent("src/app.ts") }

    func testARegistryUpdateMakesAServerServableAndUnmakesItAgain() async {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)

        // Nothing installed: 2a's registry, and TypeScript answers from tree-sitter.
        XCTAssertFalse(workspace.canServe(.typescript))
        XCTAssertFalse(workspace.canServe(.javascript))
        XCTAssertTrue(workspace.canServe(.swift))

        // The install finishes and the model pushes a registry through.
        await workspace.updateRegistry(LSPServerRegistry([.sourcekitLSP, downloaded()]))

        XCTAssertTrue(workspace.canServe(.typescript))
        XCTAssertTrue(workspace.canServe(.javascript))
        XCTAssertTrue(workspace.canServe(.swift), "the servers that were there stay there")

        // Servable means served: the very next request starts it, with no restart in
        // between.
        let prepared = await workspace.prepare(url: appFile, language: .typescript, text: "let a = 1")
        XCTAssertEqual(prepared?.description.id, "typescript-language-server")

        // …and the user removes it again.
        await workspace.updateRegistry(.standard)

        XCTAssertFalse(workspace.canServe(.typescript))
        XCTAssertFalse(workspace.canServe(.javascript))
        XCTAssertTrue(workspace.canServe(.swift))
    }

    /// Un-registering is not forgetting: the process has to stop, or it outlives the
    /// feature that started it and shows up in `pgrep` after the app quits.
    func testARemovedServerIsShutDownAndItsDocumentsForgotten() async throws {
        let harness = ServerHarness()
        let workspace = makeWorkspace(
            harness: harness,
            registry: LSPServerRegistry([.sourcekitLSP, downloaded()])
        )

        let prepared = await workspace.prepare(url: appFile, language: .typescript, text: "let a = 1")
        XCTAssertEqual(try XCTUnwrap(prepared).description.id, "typescript-language-server")
        XCTAssertEqual(workspace.liveServerCount, 1)
        let transport = try XCTUnwrap(harness.firstTransport(of: "typescript-language-server"))

        await workspace.updateRegistry(.standard)

        // Closed the way a folder switch closes it (D2), then shut down politely.
        XCTAssertEqual(
            transport.notifications(for: LSPMethod.didClose)
                .compactMap { $0.params?["textDocument"]?["uri"]?.stringValue },
            [LSPWorkspace.documentURI(for: appFile)]
        )
        XCTAssertEqual(transport.sentMethods.suffix(2), [LSPMethod.shutdown, LSPMethod.exit])
        XCTAssertTrue(transport.isTerminated)
        XCTAssertEqual(workspace.liveServerCount, 0)
        XCTAssertTrue(workspace.openDocumentURIs.isEmpty)

        // And nothing restarts it: the language is on tree-sitter from here.
        let afterRemoval = await workspace.prepare(url: appFile, language: .typescript, text: "let a = 1")
        XCTAssertNil(afterRemoval)
        XCTAssertEqual(harness.launches.count, 1)
    }

    func testAnUnchangedServerKeepsItsSessionAcrossARegistryUpdate() async throws {
        let harness = ServerHarness()
        let workspace = makeWorkspace(
            harness: harness,
            registry: LSPServerRegistry([.sourcekitLSP, downloaded()])
        )

        _ = await workspace.prepare(url: mainFile, language: .swift, text: "let a = 1")
        _ = await workspace.prepare(url: appFile, language: .typescript, text: "let b = 2")
        XCTAssertEqual(workspace.liveServerCount, 2)
        let swiftTransport = try XCTUnwrap(harness.firstTransport(of: "sourcekit-lsp"))

        await workspace.updateRegistry(.standard)

        // sourcekit-lsp was not touched by the swap, so nothing about it moves —
        // not the process, not the document it holds, not its restart budget.
        XCTAssertFalse(swiftTransport.isTerminated)
        XCTAssertTrue(swiftTransport.notifications(for: LSPMethod.didClose).isEmpty)
        XCTAssertEqual(workspace.liveServerCount, 1)
        XCTAssertEqual(workspace.openDocumentURIs, [LSPWorkspace.documentURI(for: mainFile)])

        // The next Swift request is answered by the session that was already there:
        // no relaunch, and no second `didOpen` for a document it still holds.
        let again = await workspace.prepare(url: mainFile, language: .swift, text: "let a = 1")
        XCTAssertEqual(try XCTUnwrap(again).version, 1)
        XCTAssertEqual(harness.launches.map(\.id), ["sourcekit-lsp", "typescript-language-server"])
        XCTAssertEqual(swiftTransport.notifications(for: LSPMethod.didOpen).count, 1)
    }

    /// Same id, different install — a version bump. The old process is running out
    /// of a directory the engine is about to delete, so "unchanged" has to mean the
    /// whole launch description and not just the name on it.
    func testAChangedLaunchDescriptionRestartsTheServer() async throws {
        let harness = ServerHarness()
        let workspace = makeWorkspace(
            harness: harness,
            registry: LSPServerRegistry([downloaded(path: "/servers/node/24.19.0/bin/node")])
        )

        _ = await workspace.prepare(url: appFile, language: .typescript, text: "let a = 1")
        let old = try XCTUnwrap(harness.firstTransport(of: "typescript-language-server"))

        await workspace.updateRegistry(
            LSPServerRegistry([downloaded(path: "/servers/node/24.20.0/bin/node")])
        )

        XCTAssertTrue(old.isTerminated)
        XCTAssertEqual(workspace.liveServerCount, 0)
        XCTAssertTrue(workspace.openDocumentURIs.isEmpty)

        // The language is still served — by the new install.
        XCTAssertTrue(workspace.canServe(.typescript))
        let prepared = await workspace.prepare(url: appFile, language: .typescript, text: "let a = 1")
        XCTAssertNotNil(prepared)
        XCTAssertEqual(harness.launches.count, 2)
        XCTAssertEqual(
            harness.launched.last?.launch,
            .executable(path: "/servers/node/24.20.0/bin/node")
        )
        XCTAssertTrue(recordedDelays.isEmpty, "an un-registration is not a crash")

        // The same holds for the parts of a description that are not the path: a
        // changed argument list or `initializationOptions` is a different server.
        await workspace.updateRegistry(
            LSPServerRegistry([
                downloaded(
                    path: "/servers/node/24.20.0/bin/node",
                    options: .object(["tsserver": .object(["path": .string("/servers/ts")])])
                )
            ])
        )
        XCTAssertEqual(workspace.liveServerCount, 0)
        _ = await workspace.prepare(url: appFile, language: .typescript, text: "let a = 1")
        XCTAssertEqual(harness.launches.count, 3)
    }

    /// D7's "never within a root" is about a server that keeps crashing on the same
    /// project. A server the user removed and installed again is a different server,
    /// and making someone relaunch the app to get a second chance after one bad
    /// download would be a silent dead end.
    func testAReAddedServerThatHadBeenGivenUpOnGetsAFreshBudget() async {
        let harness = ServerHarness()
        let live = LSPServerRegistry([.sourcekitLSP, downloaded()])
        let workspace = makeWorkspace(harness: harness, registry: live)

        _ = await workspace.prepare(url: appFile, language: .typescript, text: "a")
        for _ in 1...3 {
            await crash(harness.latest)
            _ = await workspace.prepare(url: appFile, language: .typescript, text: "a")
        }
        await crash(harness.latest)
        let givenUp = await workspace.prepare(url: appFile, language: .typescript, text: "a")
        XCTAssertNil(givenUp)
        XCTAssertTrue(workspace.isUnavailable(.typescript))
        XCTAssertEqual(harness.launches.count, 4)
        XCTAssertEqual(recordedDelays, LSPWorkspace.backoffDelays)

        // Removed, then installed again.
        await workspace.updateRegistry(.standard)
        await workspace.updateRegistry(live)

        XCTAssertTrue(workspace.canServe(.typescript))
        XCTAssertFalse(workspace.isUnavailable(.typescript))
        let retried = await workspace.prepare(url: appFile, language: .typescript, text: "a")
        XCTAssertNotNil(retried)
        XCTAssertEqual(harness.launches.count, 5)
        XCTAssertEqual(recordedDelays, LSPWorkspace.backoffDelays, "and no backoff is carried over")
    }

    /// A registry update is not a folder change. The generation orders *requests*
    /// against the project they were asked under, and a server appearing or
    /// disappearing does not change which folder is open — a Swift request in flight
    /// while a TypeScript server installs must still be readable when it lands.
    func testARegistryUpdateLeavesTheRequestGenerationAlone() async throws {
        let harness = ServerHarness()
        let workspace = makeWorkspace(harness: harness)

        let answer = await workspace.prepare(url: mainFile, language: .swift, text: "let a = 1")
        let prepared = try XCTUnwrap(answer)
        let generation = workspace.currentRequestGeneration

        await workspace.updateRegistry(LSPServerRegistry([.sourcekitLSP, downloaded()]))
        await workspace.updateRegistry(.standard)

        XCTAssertEqual(workspace.currentRequestGeneration, generation)
        XCTAssertTrue(workspace.stillHolds(prepared))
    }

    /// The server that is still handshaking when its description is withdrawn — the
    /// window a removal is most likely to land in, since starting a language server
    /// is the slowest thing this layer does.
    func testARegistryUpdateStopsAServerThatIsStillHandshaking() async throws {
        let harness = ServerHarness()
        harness.initializeDelay = 0.05
        let workspace = makeWorkspace(
            harness: harness,
            registry: LSPServerRegistry([.sourcekitLSP, downloaded()])
        )

        async let request = workspace.prepare(url: appFile, language: .typescript, text: "let a = 1")
        await waitFor("the launch to start") { harness.launches.count == 1 }

        await workspace.updateRegistry(.standard)
        let answer = await request

        XCTAssertNil(answer, "a request against a withdrawn server falls back")
        XCTAssertEqual(workspace.liveServerCount, 0)
        XCTAssertTrue(workspace.openDocumentURIs.isEmpty)
        XCTAssertTrue(try XCTUnwrap(harness.firstTransport(of: "typescript-language-server")).isTerminated)
    }

    /// Remove, then Install again from the Settings surface, fast enough that the
    /// first server is still handshaking when the second one starts. Two processes
    /// exist for one key, and the *newer* one is the one everything must point at:
    /// the launch that was withdrawn resumes on a main-actor turn arbitrarily
    /// later, and if it registers itself over the newer session — or if the
    /// removal's own cleanup clears the newer transport — the live process is left
    /// with nothing pointing at it, which is precisely the orphan `pgrep` finds
    /// after the app quits.
    func testAReinstallThatOverlapsARemovalLeavesTheNewProcessReachable() async throws {
        let harness = ServerHarness()
        harness.initializeDelay = 0.5
        let live = LSPServerRegistry([.sourcekitLSP, downloaded()])
        let workspace = makeWorkspace(harness: harness, registry: live)

        async let firstRequest = workspace.prepare(url: appFile, language: .typescript, text: "a")
        await waitFor("the first launch to start") { harness.launches.count == 1 }
        let first = try XCTUnwrap(harness.firstTransport(of: "typescript-language-server"))

        // Removed while it is still handshaking: this parks on the in-flight
        // launch, having already swapped the registry.
        async let removal: Void = workspace.updateRegistry(.standard)
        await waitFor("the removal to swap the registry") { !workspace.canServe(.typescript) }

        // …and reinstalled, with a request that starts a second process — all
        // before the first handshake returns.
        harness.initializeDelay = 0
        await workspace.updateRegistry(live)
        let second = await workspace.prepare(url: appFile, language: .typescript, text: "a")
        XCTAssertNotNil(second, "the reinstalled server did not start")
        XCTAssertEqual(harness.launches.count, 2)
        let live2 = try XCTUnwrap(harness.transports.last)
        XCTAssertFalse(live2 === first)

        _ = await firstRequest
        await removal

        // The withdrawn launch stood down without touching the newer server.
        XCTAssertTrue(first.isTerminated)
        XCTAssertFalse(live2.isTerminated)
        XCTAssertEqual(workspace.liveServerCount, 1)
        XCTAssertEqual(workspace.openDocumentURIs, [LSPWorkspace.documentURI(for: appFile)])

        // And the one thing all of this bookkeeping is for: a quit reaches it.
        workspace.terminateNow()
        XCTAssertTrue(live2.isTerminated, "the reinstalled server was left running with nothing pointing at it")
    }

    /// The same overlap, with the two handshakes finishing in the other order: the
    /// reinstalled server is still handshaking when the *withdrawn* one finishes and
    /// files itself under the key. That is the one moment the removal's own identity
    /// check cannot see, because it asks about the session and the disagreement is in
    /// the transport — a transport is registered before its handshake, a session only
    /// after, so `sessions[key]` is the withdrawn launch's while `transports[key]` is
    /// already the new one's. Clearing the entry on the session's say-so drops a live
    /// process out of `terminateNow()`'s reach for the rest of the app run.
    func testAReinstallStillHandshakingKeepsItsTransportWhenTheRemovalCleansUp() async throws {
        let harness = ServerHarness()
        let live = LSPServerRegistry([.sourcekitLSP, downloaded()])
        // A handshake budget wide enough that the two staged delays below are
        // ordering, not timeouts.
        let workspace = LSPWorkspace(
            registry: live,
            budgets: LSPSession.Budgets(
                handshake: 10,
                definition: 1,
                completion: 1,
                resolve: 1,
                shutdown: 1
            ),
            processID: 4242,
            transportFactory: { [harness] description, launchRoot in
                try harness.makeTransport(description, launchRoot)
            },
            delay: { _ in }
        )
        workspace.prepareForFolderChange(root: root)

        // Long enough to outlast the removal and the reinstall below, short enough
        // to land well before the second handshake.
        harness.initializeDelay = 0.5
        async let firstRequest = workspace.prepare(url: appFile, language: .typescript, text: "a")
        await waitFor("the first launch to start") { harness.launches.count == 1 }
        let first = try XCTUnwrap(harness.firstTransport(of: "typescript-language-server"))

        async let removal: Void = workspace.updateRegistry(.standard)
        await waitFor("the removal to swap the registry") { !workspace.canServe(.typescript) }

        // Reinstalled, and its launch is still handshaking when the withdrawn one
        // finishes — the ordering this case exists for.
        harness.initializeDelay = 1.5
        await workspace.updateRegistry(live)
        async let secondRequest = workspace.prepare(url: appFile, language: .typescript, text: "a")
        await waitFor("the second launch to start") { harness.launches.count == 2 }
        let second = try XCTUnwrap(harness.transports.last)
        XCTAssertFalse(second === first)

        _ = await firstRequest
        await removal
        XCTAssertTrue(first.isTerminated, "the withdrawn launch was left running")

        // The reinstalled server finishes and is the one serving the folder.
        let prepared = await secondRequest
        XCTAssertNotNil(prepared, "the reinstalled server did not start")
        XCTAssertFalse(second.isTerminated)
        XCTAssertEqual(workspace.liveServerCount, 1)

        workspace.terminateNow()
        XCTAssertTrue(
            second.isTerminated,
            "the removal cleared a transport belonging to a newer, still-handshaking launch"
        )
    }

    /// The quit lands *inside* a removal, while the withdrawn server is still
    /// handshaking. `updateRegistry` parks on that launch — the slowest thing this
    /// layer does — so the window is wide, and the process is alive for all of it.
    /// `terminateNow()` reads nothing but `transports`, so a removal that dropped
    /// the pending launch's transport on its way past would leave that process with
    /// nothing pointing at it: the orphan the method exists to kill, in the one
    /// moment (`willTerminateNotification`) with no further run-loop turn to catch
    /// it.
    func testAQuitDuringARemovalStillKillsTheServerThatWasHandshaking() async throws {
        let harness = ServerHarness()
        harness.initializeDelay = 0.5
        let workspace = makeWorkspace(
            harness: harness,
            registry: LSPServerRegistry([.sourcekitLSP, downloaded()])
        )

        async let request = workspace.prepare(url: appFile, language: .typescript, text: "a")
        await waitFor("the launch to start") { harness.launches.count == 1 }
        let transport = try XCTUnwrap(harness.firstTransport(of: "typescript-language-server"))

        async let removal: Void = workspace.updateRegistry(.standard)
        await waitFor("the removal to swap the registry") { !workspace.canServe(.typescript) }
        XCTAssertFalse(transport.isTerminated, "the launch finished before the quit could land in the window")

        workspace.terminateNow()
        XCTAssertTrue(
            transport.isTerminated,
            "a launch withdrawn by a registry update was left out of terminateNow()'s reach"
        )

        _ = await request
        await removal
    }

    /// The same quit, in the other half of the same window: the withdrawn server
    /// finished its handshake, so `updateRegistry` is parked on `session.shutdown()`
    /// rather than on a launch. That wait runs a whole request budget against a
    /// process that is still very much alive, and `terminateNow()` reads nothing but
    /// `transports` — so dropping the live session's transport on the way past
    /// leaves the same orphan the pending-launch branch is careful not to.
    func testAQuitWhileARemovedServerIsShuttingDownStillKillsIt() async throws {
        let harness = ServerHarness()
        let workspace = makeWorkspace(
            harness: harness,
            registry: LSPServerRegistry([.sourcekitLSP, downloaded()])
        )

        _ = await workspace.prepare(url: appFile, language: .typescript, text: "a")
        let transport = try XCTUnwrap(harness.firstTransport(of: "typescript-language-server"))

        // A goodbye the server takes its time over — the window a quit lands in.
        transport.script(LSPMethod.shutdown, .reply(.null, after: 0.5))

        async let removal: Void = workspace.updateRegistry(.standard)
        await waitFor("the removal to reach the shutdown") {
            !transport.requests(for: LSPMethod.shutdown).isEmpty
        }
        XCTAssertFalse(transport.isTerminated, "the shutdown answered before the quit could land")

        workspace.terminateNow()
        XCTAssertTrue(
            transport.isTerminated,
            "a session withdrawn by a registry update was left out of terminateNow()'s reach"
        )

        await removal
    }

    /// The third and last corner of the same window, and the one the other two
    /// leave open: the withdrawn server was still *launching* when the registry
    /// moved, so it is cleaned up by the pending-launch branch rather than the
    /// live-session one — but its handshake finished, so that branch is parked on
    /// `shutdown()`, not on the launch. The process is alive for that whole
    /// budget, and `terminateNow()` reads nothing but `transports`, so a branch
    /// that unregisters the transport on its way to the goodbye leaves exactly the
    /// orphan its two siblings are careful not to.
    func testAQuitWhileAWithdrawnLaunchIsShuttingDownStillKillsIt() async throws {
        let harness = ServerHarness()
        // Long enough that the removal below starts while the launch is still
        // pending — the branch this case is about — and short enough that the
        // handshake lands well inside it.
        harness.initializeDelay = 0.2
        let workspace = makeWorkspace(
            harness: harness,
            registry: LSPServerRegistry([.sourcekitLSP, downloaded()])
        )

        async let request = workspace.prepare(url: appFile, language: .typescript, text: "a")
        await waitFor("the launch to start") { harness.launches.count == 1 }
        let transport = try XCTUnwrap(harness.firstTransport(of: "typescript-language-server"))
        // A goodbye the server takes its time over, so the quit lands inside it
        // rather than after it.
        transport.script(LSPMethod.shutdown, .reply(.null, after: 0.5))

        async let removal: Void = workspace.updateRegistry(.standard)
        await waitFor("the removal to reach the withdrawn launch's shutdown") {
            !transport.requests(for: LSPMethod.shutdown).isEmpty
        }
        XCTAssertFalse(transport.isTerminated, "the shutdown answered before the quit could land")

        workspace.terminateNow()
        XCTAssertTrue(
            transport.isTerminated,
            "a launch withdrawn mid-handshake was dropped from terminateNow()'s reach "
                + "before its shutdown finished"
        )

        _ = await request
        await removal
    }

    /// `reachableDescriptions` is keyed off what the registry *routes to*, not off
    /// everything it holds: first registration wins per language, so a description
    /// that has been shadowed for every language it claims can never be launched
    /// again and its process has to go with it.
    func testAServerShadowedForEveryLanguageItServesIsShutDown() async throws {
        let harness = ServerHarness()
        let workspace = makeWorkspace(
            harness: harness,
            registry: LSPServerRegistry([.sourcekitLSP, downloaded()])
        )

        _ = await workspace.prepare(url: appFile, language: .typescript, text: "a")
        let shadowed = try XCTUnwrap(harness.firstTransport(of: "typescript-language-server"))
        XCTAssertEqual(workspace.liveServerCount, 1)

        // A hand-registered override for both of its languages, registered first.
        // The old description is still *in* the registry and still resolves for
        // nothing.
        await workspace.updateRegistry(
            LSPServerRegistry([.sourcekitLSP, downloaded(id: "override"), downloaded()])
        )

        XCTAssertTrue(shadowed.isTerminated, "a server nothing can route to was left running")
        XCTAssertEqual(workspace.liveServerCount, 0)
        XCTAssertTrue(workspace.openDocumentURIs.isEmpty)

        let prepared = await workspace.prepare(url: appFile, language: .typescript, text: "a")
        XCTAssertEqual(prepared?.description.id, "override")
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
