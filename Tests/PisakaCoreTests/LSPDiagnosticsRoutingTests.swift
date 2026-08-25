import XCTest
@testable import PisakaCore

/// The workspace half of the diagnostics channel: which pushes survive D31's
/// gates and reach the sink with buffer offsets, and which clears the teardown
/// paths owe the model (D33) — including the externally-killed-server case,
/// where the *stream's* termination is the signal and the consumer task speaks.
///
/// Every case runs on `ScriptedLSPTransport`, so "the server crashed" is a
/// deterministic unit test; the pushes travel through the session's read task,
/// the notification stream and the main-actor consumer.
///
/// **Staging Discipline**
///
/// A rendezvous is a wait on a signal that *must* arrive, never on a window
/// that may already have closed. The assertions poll for the sink's record rather
/// than assuming any particular hop count.
///
/// Audit inventory of `closeStream()` sites:
/// - `testACrashMidSessionClearsThatKey`: already sound — waits for the clear.
/// - `testAReplacementServersPushesSurviveTheDeadConsumersExit`: restaged —
///   close-then-`open`.
/// - `testACrashNoticedByTheNextRequestClearsBeforeTheRestart`: restaged —
///   the named defect.
/// - `testASpentCrashBudgetEmitsTheKeysClear` (loop): restaged —
///   close-then-`open`, ×3.
/// - `testASpentCrashBudgetEmitsTheKeysClear` (4th death): restaged —
///   close-then-`prepare`.
@MainActor
final class LSPDiagnosticsRoutingTests: XCTestCase {

    // MARK: - Harness

    /// Same shape as `LSPWorkspaceTests.ServerHarness`: one scripted transpor
    /// per launch, plus a record of who launched what.
    private final class ServerHarness {
        private(set) var launches: [(id: String, root: URL)] = []
        private(set) var transports: [ScriptedLSPTransport] = []

        /// When set, every launch fails the way a missing executable does.
        var launchError: LSPTransportError?
        var initializeResult = ScriptedLSPTransport.initializeResult()
        /// How long the handshake takes — the seam a launch is held in flight by.
        var initializeDelay: TimeInterval = 0

        func makeTransport(
            _ description: LSPServerDescription,
            _ root: URL
        ) throws -> LSPTransport {
            launches.append((description.id, root))
            if let launchError { throw launchError }
            let transport = ScriptedLSPTransport()
            transport.script(LSPMethod.initialize, .reply(initializeResult, after: initializeDelay))
            // So a teardown in a test costs a round trip and not a budget.
            transport.script(LSPMethod.shutdown, .reply(.null))
            transports.append(transport)
            return transport
        }

        var latest: ScriptedLSPTransport { transports[transports.count - 1] }

        /// The transport handed over for the *first* launch of `id`.
        func firstTransport(of id: String) -> ScriptedLSPTransport? {
            guard let index = launches.firstIndex(where: { $0.id == id }) else { return nil }
            return index < transports.count ? transports[index] : nil
        }
    }

    private static let quick = LSPSession.Budgets(
        handshake: 1,
        definition: 1,
        completion: 1,
        resolve: 1,
        hover: 1,
        shutdown: 1
    )

    private let root = URL(fileURLWithPath: "/tmp/PisakaDiagnostics", isDirectory: true)
    private let otherRoot = URL(fileURLWithPath: "/tmp/PisakaDiagnosticsOther", isDirectory: true)

    private var mainFile: URL { root.appendingPathComponent("Sources/App/main.swift") }
    private var utilFile: URL { root.appendingPathComponent("Sources/App/util.swift") }
    private var pythonFile: URL { root.appendingPathComponent("app.py") }

    private var harness: ServerHarness!
    private var workspace: LSPWorkspace!
    private var events: [LSPDiagnosticEvent] = []
    private var recordedDelays: [TimeInterval] = []

    override func setUp() {
        super.setUp()
        harness = ServerHarness()
        recordedDelays = []
        workspace = makeWorkspace()
        workspace.onDiagnostics = { [weak self] event in self?.events.append(event) }
    }

    override func tearDown() {
        // Terminated before the reference is dropped: every test here launches a
        // least one session, and a session left alive keeps a read task suspended
        // on a `ScriptedLSPTransport` stream nobody will ever close — one leaked
        // task per server per test, for the whole run.
        workspace.terminateNow()
        workspace.onDiagnostics = nil
        workspace = nil
        harness = nil
        super.tearDown()
    }

    /// A workspace pointed at `root`, with the harness behind its factory and
    /// D7's waits recorded rather than slept.
    private func makeWorkspace(
        registry: LSPServerRegistry = LSPServerRegistry([.sourcekitLSP])
    ) -> LSPWorkspace {
        let currentHarness = harness!
        let created = LSPWorkspace(
            registry: registry,
            budgets: LSPDiagnosticsRoutingTests.quick,
            processID: 4242,
            transportFactory: { description, launchRoot in
                try currentHarness.makeTransport(description, launchRoot)
            },
            delay: { [weak self] seconds in
                self?.recordedDelays.append(seconds)
            }
        )
        created.prepareForFolderChange(root: root)
        return created
    }

    /// The canonical root string the events key their clears by (`ServerKey.root`).
    private var serverRoot: String { LSPWorkspace.rootKey(for: root) }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
    }

    private func push(
        to transport: ScriptedLSPTransport,
        uri: String,
        version: Int?,
        _ entries: [(LSPPosition, LSPPosition, LSPDiagnosticSeverity?, String)]
    ) throws {
        // Built as a literal rather than encoded: the params type is
        // decode-only (the server initiates this conversation), so the tes
        // speaks the wire shape the decoder reads.
        var payload: [String: JSONValue] = [
            "uri": .string(uri),
            "diagnostics": .array(entries.map { start, end, severity, message in
                var item: [String: JSONValue] = [
                    "range": .object([
                        "start": .object(["line": .int(start.line), "character": .int(start.character)]),
                        "end": .object(["line": .int(end.line), "character": .int(end.character)]),
                    ]),
                    "message": .string(message),
                ]
                if let severity { item["severity"] = .int(severity.rawValue) }
                return JSONValue.object(item)
            }),
        ]
        if let version { payload["version"] = .int(version) }
        transport.push(method: LSPMethod.publishDiagnostics, params: .object(payload))
    }

    private func pushToMainFile(version: Int?, message: String) throws {
        try push(
            to: harness.latest,
            uri: LSPWorkspace.documentURI(for: mainFile),
            version: version,
            [(LSPPosition(line: 0, character: 0), LSPPosition(line: 0, character: 1), nil, message)]
        )
    }

    private func publishedEvents() -> [(url: URL, diagnostics: [Diagnostic], version: Int?)] {
        events.compactMap {
            if case .published(let url, _, _, let version, let diagnostics) = $0 {
                return (url, diagnostics, version)
            }
            return nil
        }
    }

    private func clearedServerIDs() -> [String] {
        events.compactMap {
            if case .cleared(.server(let serverID, _)) = $0 { return serverID }
            return nil
        }
    }

    /// Open `url` with `text`, waiting until the server holds it.
    @discardableResult
    private func open(_ url: URL, language: SyntaxLanguage = .swift, text: String) async throws -> LSPWorkspace.PreparedDocument {
        let prepared = await workspace.prepare(url: url, language: language, text: text)
        return try XCTUnwrap(prepared, "prepare returned nothing for \(url.lastPathComponent)")
    }

    // MARK: - Accepted pushes

    func testAPushForAnOpenDocumentReachesTheSinkWithBufferOffsets() async throws {
        let prepared = try await open(mainFile, text: "let a = 1\nlet b = 2\n")
        try push(
            to: harness.latest,
            uri: prepared.uri,
            version: prepared.version,
            [
                (LSPPosition(line: 0, character: 4), LSPPosition(line: 0, character: 9), .error, "first"),
                (LSPPosition(line: 1, character: 4), LSPPosition(line: 1, character: 9), .warning, "second"),
            ]
        )

        try await waitFor("the mapped push") { !self.publishedEvents().isEmpty }

        let received = publishedEvents().first!
        XCTAssertEqual(received.url, mainFile.standardizedFileURL)
        XCTAssertEqual(received.version, 1)
        XCTAssertEqual(received.diagnostics.count, 2)
        // Mapped against the text the server was told: line 0 starts at 0,
        // line 1 at 10 ("let a = 1\n"), each span five UTF-16 units long.
        XCTAssertEqual(received.diagnostics[0].range, NSRange(location: 4, length: 5))
        XCTAssertEqual(received.diagnostics[0].line, 0)
        XCTAssertEqual(received.diagnostics[0].severity, .error)
        XCTAssertEqual(received.diagnostics[1].range, NSRange(location: 14, length: 5))
        XCTAssertEqual(received.diagnostics[1].line, 1)
        XCTAssertEqual(received.diagnostics[1].severity, .warning)

        // And every event carries the provenance the store keys its entries by.
        guard case .published(_, let serverID, let pushedRoot, _, _)? = events.first else {
            return XCTFail("expected a published event")
        }
        XCTAssertEqual(serverID, "sourcekit-lsp")
        XCTAssertEqual(pushedRoot, serverRoot)
    }

    func testANotificationNobodyRoutesIsIgnored() async throws {
        _ = try await open(mainFile, text: "a")
        try pushToMainFile(version: 1, message: "live")
        try await waitFor("the live push") { !self.publishedEvents().isEmpty }

        harness.latest.push(method: "window/logMessage", params: .object(["message": .string("hi")]))
        let countBefore = publishedEvents().count
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(publishedEvents().count, countBefore, "only publishDiagnostics is routed; the rest stay noise")
    }

    /// A URI one server holds, pushed through a *different* server's transport,
    /// is noise: the provenance gate (`state.serverKey == key`) stops one
    /// server's answers overwriting another's for the same file.
    func testAPushForAnotherServersDocumentIsDropped() async throws {
        let fake = LSPServerDescription(
            id: "fake-pyls",
            languages: [.python],
            launch: .executable(path: "/usr/local/bin/fake-pyls"),
            arguments: ["--stdio"]
        )
        workspace = makeWorkspace(registry: LSPServerRegistry([.sourcekitLSP, fake]))
        workspace.onDiagnostics = { [weak self] event in self?.events.append(event) }

        let swift = try await open(mainFile, text: "a")
        _ = try await open(pythonFile, language: .python, text: "x = 1")
        XCTAssertEqual(workspace.liveServerCount, 2)

        // The python transport speaks about main.swift — the exact shape of a
        // cross-server overwrite if the gate ever goes away or inverts.
        try push(
            to: harness.firstTransport(of: "fake-pyls")!,
            uri: swift.uri,
            version: swift.version,
            [(LSPPosition(line: 0, character: 0), LSPPosition(line: 0, character: 1), nil, "impostor")]
        )
        let countBefore = publishedEvents().count
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(publishedEvents().count, countBefore, "one server must not answer for another's document")
    }

    /// The silent-drop paths in `route` (undecodable params, no `uri`, a URI
    /// that does not parse) each drop *one notification* — they must never kill
    /// the consumer task, whose continued life is what makes D33's stream-finish
    /// clear fire on a later crash.
    func testMalformedPushesAreDroppedAndTheConsumerSurvives() async throws {
        let prepared = try await open(mainFile, text: "a")

        // Not decodable as LSPPublishDiagnosticsParams at all.
        harness.latest.push(method: LSPMethod.publishDiagnostics, params: .object(["nope": .int(1)]))
        // Decodes, but carries no `uri`.
        harness.latest.push(
            method: LSPMethod.publishDiagnostics,
            params: .object(["version": .int(1), "diagnostics": .array([])])
        )
        // A `uri` no URL can parse.
        harness.latest.push(
            method: LSPMethod.publishDiagnostics,
            params: .object(["uri": .string("::not a uri::"), "diagnostics": .array([])])
        )
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(publishedEvents().isEmpty, "none of the three malformed pushes may route")

        // A well-formed push still lands: the consumer is alive.
        try push(to: harness.latest, uri: prepared.uri, version: prepared.version, [
            (LSPPosition(line: 0, character: 0), LSPPosition(line: 0, character: 1), nil, "alive")
        ])
        try await waitFor("the post-malformed push") {
            self.publishedEvents().last?.diagnostics.first?.message == "alive"
        }
    }

    func testAPushWithoutAVersionIsAccepted() async throws {
        let prepared = try await open(mainFile, text: "a")
        try push(to: harness.latest, uri: prepared.uri, version: nil, [])

        try await waitFor("the unversioned push") { !self.publishedEvents().isEmpty }

        XCTAssertNil(publishedEvents().first?.version, "the wire value travels verbatim; gating is downstream")
    }

    // MARK: - Dropped pushes

    /// Each absence proof first proves the pipeline *live* with a good push, so
    /// a fixed sleep can never mask a violation arriving just after it.
    func testAPushWithAStaleVersionIsDropped() async throws {
        let prepared = try await open(mainFile, text: "a")
        try pushToMainFile(version: prepared.version, message: "live")
        try await waitFor("the live push") { !self.publishedEvents().isEmpty }

        try pushToMainFile(version: prepared.version + 7, message: "m")
        let countBefore = publishedEvents().count
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(publishedEvents().count, countBefore, "a push for a version the server does not hold is noise")
    }

    func testAPushForAnUnopenedURIIsDropped() async throws {
        _ = try await open(mainFile, text: "a")
        try pushToMainFile(version: 1, message: "live")
        try await waitFor("the live push") { !self.publishedEvents().isEmpty }

        try push(
            to: harness.latest,
            uri: LSPWorkspace.documentURI(for: utilFile),
            version: 1,
            [(LSPPosition(line: 0, character: 0), LSPPosition(line: 0, character: 1), nil, "m")]
        )
        let countBefore = publishedEvents().count
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(
            publishedEvents().count,
            countBefore,
            "the panel covers held documents only; a URI no server holds is dropped"
        )
    }

    /// A server may re-spell the URI it was handed — a different but equivalen
    /// percent-encoding is the ordinary case — and the push must still find its
    /// document. Matching the raw strings alone would drop every diagnostic for
    /// that file, silently, for the whole session.
    func testAPushRespellingTheURIStillFindsItsDocument() async throws {
        let plusFile = root.appendingPathComponent("Sources/App/a+b.swift")
        let prepared = try await open(plusFile, text: "let a = 1\n")
        // What we sent the server; what it echoes differs only in the encoding
        // of the `+`, which needs no escaping and is therefore free to carry one.
        XCTAssertEqual(prepared.uri, LSPWorkspace.documentURI(for: plusFile))
        let respelled = prepared.uri.replacingOccurrences(of: "a+b.swift", with: "a%2Bb.swift")
        XCTAssertNotEqual(respelled, prepared.uri, "the two spellings must actually differ")

        try push(
            to: harness.latest,
            uri: respelled,
            version: prepared.version,
            [(LSPPosition(line: 0, character: 4), LSPPosition(line: 0, character: 5), .error, "respelled")]
        )

        try await waitFor("the re-spelled push") { !self.publishedEvents().isEmpty }
        let received = publishedEvents().first!
        XCTAssertEqual(received.url.standardizedFileURL, plusFile.standardizedFileURL)
        XCTAssertEqual(received.diagnostics.map(\.message), ["respelled"])
    }

    // MARK: - The forced flush (the sync's supply)

    /// The providers keep D2's no-op: their question needs no second
    /// notification when another flusher already delivered this exact text.
    func testAnUnforcedPrepareOnIdenticalTextIsStillANoOp() async throws {
        _ = try await open(mainFile, text: "let a = 1\n")
        XCTAssertEqual(harness.latest.notifications(for: LSPMethod.didChange).count, 0)

        let again = await workspace.prepare(url: mainFile, language: .swift, text: "let a = 1\n")
        XCTAssertEqual(again?.version, 1)
        XCTAssertEqual(
            harness.latest.notifications(for: LSPMethod.didChange).count,
            0,
            "an identical-text request sends nothing — the provider path's contract"
        )
    }

    /// The diagnostics sync declines that no-op (`forceFlush: true`): a
    /// push-only server publishes only when a notification arrives, so the
    /// settling flush must leave the server one more to answer even when the
    /// bytes are identical — otherwise the push its gate would accept never
    /// exists.
    func testAForcedPrepareRepublishesIdenticalTextAtANewVersion() async throws {
        _ = try await open(mainFile, text: "let a = 1\n")

        let forcedPrepare = await workspace.prepare(
            url: mainFile,
            language: .swift,
            text: "let a = 1\n",
            forceFlush: true
        )
        let forced = try XCTUnwrap(forcedPrepare)

        XCTAssertEqual(forced.version, 2)
        XCTAssertTrue(workspace.stillHolds(forced), "the document state moved with the bump")
        let changes = harness.latest.notifications(for: LSPMethod.didChange)
        XCTAssertEqual(changes.count, 1, "one full-text didChange for the identical text")
        let change = try XCTUnwrap(changes.first)
        XCTAssertEqual(change.params?["textDocument"]?["version"]?.intValue, 2)
        XCTAssertEqual(change.params?["contentChanges"]?[0]?["text"]?.stringValue, "let a = 1\n")
    }

    /// The starvation shape the forced flag exists for: a provider flush (a
    /// completion at its shorter debounce) delivers the typed text before the
    /// diagnostics debounce fires, and its publish dies at the model's gate —
    /// version past the record, revision moved. An unforced settling sync would
    /// then find nothing to send and nothing coming, stranding the pre-typing
    /// set on all three surfaces; with the forced republish the burst always
    /// ends in a push the gate accepts.
    func testAProviderFlushCannotStarveTheSettlingSyncsPush() async throws {
        let model = DiagnosticsModel()
        workspace.onDiagnostics = { [weak model] event in model?.receive(event) }

        let first = try await open(mainFile, text: "a")
        model.noteSynced(url: mainFile, version: first.version, revision: 0)
        try push(to: harness.latest, uri: first.uri, version: 1, [
            (LSPPosition(line: 0, character: 0), LSPPosition(line: 0, character: 1), .error, "old"),
        ])
        try await waitFor("the first push") { !self.publishedEntries(in: model).isEmpty }

        // The keystroke bumps the revision; the provider (unforced prepare)
        // delivers the new text…
        model.noteEdit(
            url: mainFile,
            previousLineStarts: [0],
            newLineStarts: [0],
            editedRange: NSRange(location: 1, length: 0),
            changeInLength: 1
        )
        let provider = try await open(mainFile, text: "ab")
        XCTAssertEqual(provider.version, 2)

        // …and the publish it provokes lands while the record still names the
        // first sync: rejected by the gate.
        try push(to: harness.latest, uri: provider.uri, version: 2, [
            (LSPPosition(line: 0, character: 0), LSPPosition(line: 0, character: 2), .warning, "mid"),
        ])
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(
            publishedEntries(in: model).contains { $0.message == "mid" },
            "the provider-provoked push is stale against the record — rejected"
        )

        // The settling sync forces the identical-text republish and records it;
        // the answer to *that* is what the surfaces finally show.
        let settledPrepare = await workspace.prepare(
            url: mainFile,
            language: .swift,
            text: "ab",
            forceFlush: true
        )
        let settled = try XCTUnwrap(settledPrepare)
        XCTAssertEqual(settled.version, 3)
        model.noteSynced(url: mainFile, version: settled.version, revision: 1)
        try push(to: harness.latest, uri: settled.uri, version: settled.version, [
            (LSPPosition(line: 0, character: 0), LSPPosition(line: 0, character: 2), .warning, "new"),
        ])
        try await waitFor("the post-settle push") { self.publishedEntries(in: model).first?.message == "new" }

        // And the typed text genuinely travelled twice — the transport-level
        // fact a push-only server's next publish depends on.
        XCTAssertEqual(harness.latest.notifications(for: LSPMethod.didChange).count, 2)
    }

    // MARK: - Clears (D33)

    /// Kills the live server and waits until its death has been processed.
    /// The consumer's clear is the observable proof that `phase == .terminated` is reached.
    private func killServerAndWaitForDeathProcessing() async throws {
        let eventsBefore = events.count
        harness.latest.closeStream()
        try await waitFor("the consumer to process the death") {
            self.events.dropFirst(eventsBefore).contains { event in
                if case .cleared(.server) = event { return true }
                return false
            }
        }
    }

    func testACrashMidSessionClearsThatKey() async throws {
        _ = try await open(mainFile, text: "a")
        try pushToMainFile(version: 1, message: "m")
        try await waitFor("the push") { !self.publishedEvents().isEmpty }

        harness.latest.closeStream()
        try await waitFor("the consumer to see the stream finish") {
            self.clearedServerIDs() == ["sourcekit-lsp"]
        }

        guard case .cleared(.server(let serverID, let clearedRoot))? = events.last else {
            return XCTFail("expected a cleared event")
        }
        XCTAssertEqual(serverID, "sourcekit-lsp")
        XCTAssertEqual(clearedRoot, serverRoot)
    }

    /// A replacement session re-publishes under the same key; the dead
    /// predecessor's consumer must not wipe those answers when its own stream
    /// finally finishes under it.
    func testAReplacementServersPushesSurviveTheDeadConsumersExit() async throws {
        _ = try await open(mainFile, text: "a")
        try pushToMainFile(version: 1, message: "old")
        try await waitFor("the old push") { !self.publishedEvents().isEmpty }

        let oldSession = harness.latest
        oldSession.failWrites(with: .writeFailed("broken pipe"))

        _ = await workspace.prepare(url: mainFile, language: .swift, text: "b")
        _ = try await open(mainFile, text: "b")
        XCTAssertEqual(harness.launches.count, 2)

        try pushToMainFile(version: 1, message: "new")
        try await waitFor("the new push") {
            self.publishedEvents().last?.diagnostics.first?.message == "new"
        }

        oldSession.closeStream()
        try await Task.sleep(nanoseconds: 150_000_000)

        // The dead consumer must not emit a clear after the replacement's publish.
        let lastPublishedIndex = events.lastIndex { event in
            if case .published = event { return true }
            return false
        }!
        XCTAssertNil(
            events.dropFirst(lastPublishedIndex + 1).first { event in
                if case .cleared = event { return true }
                return false
            },
            "the dead consumer must not clear a replacement's answers"
        )
    }

    func testAFolderSwitchClearsEverythingExactlyOncePerKey() async throws {
        _ = try await open(mainFile, text: "a")
        _ = try await open(utilFile, text: "b")
        try pushToMainFile(version: 1, message: "m")
        try await waitFor("the push") { !self.publishedEvents().isEmpty }

        workspace.prepareForFolderChange(root: otherRoot)
        await workspace.shutdownAll()

        XCTAssertEqual(
            clearedServerIDs(),
            ["sourcekit-lsp"],
            "one clear per torn-down key, emitted synchronously by the teardown itself"
        )
    }

    /// The folder switch is two steps — `prepareForFolderChange` synchronously,
    /// `shutdownAll()` a turn later — and an old project's consumer task is
    /// still running inside that window, its documents still filed. A push i
    /// routes there must never reach the sink: the model's bookkeeping is
    /// already cleared, so the event would be *held*, and a next project tha
    /// contains the same absolute path could then reconcile the old project's
    /// set onto the new file under the old server's provenance.
    func testAStragglersPushBetweenTheFolderSwitchsStepsNeverRoutes() async throws {
        let prepared = try await open(mainFile, text: "a")

        // Liveness first, so the absence below is a fact about the folder switch
        // rather than about routing having broken wholesale.
        try push(to: harness.latest, uri: prepared.uri, version: prepared.version, [
            (LSPPosition(line: 0, character: 0), LSPPosition(line: 0, character: 1), nil, "before"),
        ])
        try await waitFor("the pre-switch push") { !self.publishedEvents().isEmpty }
        let countBefore = publishedEvents().count

        workspace.prepareForFolderChange(root: otherRoot)

        try push(to: harness.latest, uri: prepared.uri, version: prepared.version, [
            (LSPPosition(line: 0, character: 0), LSPPosition(line: 0, character: 1), nil, "straggler"),
        ])
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(
            publishedEvents().count,
            countBefore,
            "an old root's server has nothing to say to this workspace"
        )
    }

    func testTerminateNowEmitsTheKeySynchronously() async throws {
        _ = try await open(mainFile, text: "a")

        workspace.terminateNow()

        XCTAssertEqual(clearedServerIDs(), ["sourcekit-lsp"])
        XCTAssertTrue(workspace.openDocumentURIs.isEmpty)
    }

    func testADidCloseClearsOneDocumentAndNotTheServer() async throws {
        _ = try await open(mainFile, text: "a")
        _ = try await open(utilFile, text: "b")

        await workspace.didClose(url: mainFile)
        // A second close of the same document is the guard's early return: i
        // must not emit a duplicate document-scoped clear.
        await workspace.didClose(url: mainFile)

        XCTAssertEqual(events.count, 1)
        guard case .cleared(.document(let closedURL))? = events.first else {
            return XCTFail("expected a document-scoped clear")
        }
        XCTAssertEqual(closedURL, mainFile.standardizedFileURL)
        XCTAssertTrue(workspace.openDocumentURIs.contains(LSPWorkspace.documentURI(for: utilFile)))
        XCTAssertEqual(workspace.liveServerCount, 1, "the server itself survives a document close")
    }

    func testUpdateRegistryRemovingAServerClearsItsDocumentsAndNotAnothers() async throws {
        let fake = LSPServerDescription(
            id: "fake-pyls",
            languages: [.python],
            launch: .executable(path: "/usr/local/bin/fake-pyls"),
            arguments: ["--stdio"]
        )
        workspace = makeWorkspace(registry: LSPServerRegistry([.sourcekitLSP, fake]))
        workspace.onDiagnostics = { [weak self] event in self?.events.append(event) }

        _ = try await open(mainFile, text: "a")
        let python = try await open(pythonFile, language: .python, text: "x = 1")
        XCTAssertEqual(workspace.liveServerCount, 2)
        try push(
            to: harness.firstTransport(of: "sourcekit-lsp")!,
            uri: LSPWorkspace.documentURI(for: mainFile),
            version: 1,
            [(LSPPosition(line: 0, character: 0), LSPPosition(line: 0, character: 1), nil, "swift")]
        )
        try push(
            to: harness.firstTransport(of: "fake-pyls")!,
            uri: python.uri,
            version: python.version,
            [(LSPPosition(line: 0, character: 0), LSPPosition(line: 0, character: 5), nil, "python")]
        )
        try await waitFor("both pushes") { self.publishedEvents().count == 2 }

        // Remove sourcekit-lsp from the registry; the fake python server survives.
        events.removeAll()
        await workspace.updateRegistry(LSPServerRegistry([fake]))

        XCTAssertEqual(
            clearedServerIDs(),
            ["sourcekit-lsp"],
            "the removed server's key is cleared, exactly once"
        )

        // The survivor's channel is untouched: its pushes still route, and no
        // clear for it ever lands behind them.
        events.removeAll()
        try push(
            to: harness.firstTransport(of: "fake-pyls")!,
            uri: python.uri,
            version: python.version,
            [(LSPPosition(line: 0, character: 0), LSPPosition(line: 0, character: 6), nil, "again")]
        )
        try await waitFor("the survivor's push") { !self.publishedEvents().isEmpty }
        XCTAssertTrue(
            clearedServerIDs().isEmpty,
            "no clear may follow a surviving server's push"
        )
    }

    /// A launch withdrawn by `updateRegistry` while it is still handshaking runs
    /// to completion — the epoch is deliberately *not* bumped for it (D16) — so
    /// it files itself and opens its push channel **after** this method's
    /// up-front cancellation has already run. The consumer that late attach
    /// leaves behind belongs to a session the in-flight teardown is about to shu
    /// down: unless that branch cancels it too, it outlives its session in
    /// `notificationTasks` and speaks the stream-finish clear (D33) for a key the
    /// same call already cleared.
    func testAWithdrawnInFlightLaunchClearsItsKeyExactlyOnce() async throws {
        let fake = LSPServerDescription(
            id: "fake-pyls",
            languages: [.python],
            launch: .executable(path: "/usr/local/bin/fake-pyls"),
            arguments: ["--stdio"]
        )
        workspace = makeWorkspace(registry: LSPServerRegistry([.sourcekitLSP, fake]))
        workspace.onDiagnostics = { [weak self] event in self?.events.append(event) }
        harness.initializeDelay = 0.2

        async let request = workspace.prepare(url: pythonFile, language: .python, text: "x = 1")
        try await waitFor("the launch to start") { self.harness.launches.count == 1 }

        await workspace.updateRegistry(LSPServerRegistry([.sourcekitLSP]))
        let answer = await request
        XCTAssertNil(answer, "a request against a withdrawn server falls back")
        XCTAssertEqual(workspace.liveServerCount, 0)

        // The stream finishes under the orphan's consumer inside the teardown
        // above; the clear it would emit lands on a later main-actor turn.
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(
            clearedServerIDs(),
            ["fake-pyls"],
            "the withdrawn launch's key is cleared once, by updateRegistry — never again by an orphaned consumer"
        )
    }

    // MARK: - D33's remaining clear sites

    /// A crash noticed by the *next request* (not by the stream's consumer)
    /// still clears synchronously inside `noteDeath`, before the restart — so
    /// by the time `open` returns, a clear for the dead life has landed.
    ///
    /// Staged causally, not timed: draining the events after waiting for the
    /// dead life's clear ensures the remaining clear is unambiguously the
    /// synchronous one emitted by `noteDeath` before the restart.
    ///
    /// The other legal interleaving — where the next request acquires a session
    /// whose death has not been noticed — is idempotent by the product's own
    /// at-least-once clear rule, and pinned by `testAWriteFailureLeavesTheSessionTerminalAndTheNextRequestRestartsIt`.
    func testACrashNoticedByTheNextRequestClearsBeforeTheRestart() async throws {
        _ = try await open(mainFile, text: "a")
        try pushToMainFile(version: 1, message: "m")
        try await waitFor("the push") { !self.publishedEvents().isEmpty }

        try await killServerAndWaitForDeathProcessing()
        events.removeAll()
        _ = try await open(mainFile, text: "b")
        XCTAssertEqual(harness.launches.count, 2, "the request that noticed the death restarted the server")

        XCTAssertFalse(
            clearedServerIDs().isEmpty,
            "noteDeath's synchronous clear must precede the replacement"
        )
        XCTAssertTrue(
            clearedServerIDs().allSatisfy { $0 == "sourcekit-lsp" },
            "only the dead key's clear may fire"
        )
    }

    /// The other interleaving of a crash: the pipe went away without an EOF, so
    /// a request acquires a session whose death has not been noticed yet. Its write
    /// fails, and it answers `nil` (the contract: "the session has already gone
    /// terminal; the next request restarts it"). Nothing relaunches on that request.
    ///
    /// The *next* request restarts the server, emitting the dead key's clear
    /// synchronously before it does.
    ///
    /// Together with `testACrashNoticedByTheNextRequestClearsBeforeTheRestart`
    /// (which pins the stream-finish-first interleaving), this pair documents why
    /// each interleaving is legal.
    func testAWriteFailureLeavesTheSessionTerminalAndTheNextRequestRestartsIt() async throws {
        _ = try await open(mainFile, text: "a")
        try pushToMainFile(version: 1, message: "m")
        try await waitFor("the push") { !self.publishedEvents().isEmpty }

        harness.latest.failWrites(with: .writeFailed("broken pipe"))

        let prepared1 = await workspace.prepare(url: mainFile, language: .swift, text: "b")
        XCTAssertNil(prepared1, "the request whose write fails must answer nil")
        XCTAssertEqual(harness.launches.count, 1, "nothing relaunches on the failing request")

        events.removeAll()

        let prepared2 = await workspace.prepare(url: mainFile, language: .swift, text: "c")
        XCTAssertNotNil(prepared2, "the *next* request restarts the server")
        XCTAssertEqual(harness.launches.count, 2, "the next request must trigger the relaunch")

        XCTAssertFalse(
            clearedServerIDs().isEmpty,
            "noteDeath's synchronous clear must precede the replacement"
        )
        XCTAssertTrue(
            clearedServerIDs().allSatisfy { $0 == "sourcekit-lsp" },
            "only the dead key's clear may fire"
        )
    }

    /// The spent-budget path (`noteFailure`'s fourth-failure unavailability) is
    /// a teardown site even though no session ever died there: a predecessor's
    /// answers may still be on screen when the key retires.
    ///
    /// Draining the consumer's clear before each request ensures the remaining
    /// clears are provably the budget path's own (staged causally).
    func testASpentCrashBudgetEmitsTheKeysClear() async throws {
        // Three crashes are restarted from (D7's budget is three).
        for attempt in 1...3 {
            _ = try await open(mainFile, text: "a\(attempt)")
            try await killServerAndWaitForDeathProcessing()
            events.removeAll()
            _ = try await open(mainFile, text: "a\(attempt + 1)")
            XCTAssertEqual(harness.launches.count, attempt + 1)
        }
        XCTAssertEqual(workspace.liveServerCount, 1)

        // The fourth death spends the budget: the request that notices i
        // retires the key, answers nothing from then on, and emits its clear.
        try await killServerAndWaitForDeathProcessing()
        events.removeAll()
        let prepared = await workspace.prepare(url: mainFile, language: .swift, text: "a5")
        XCTAssertNil(prepared, "the fourth failure must retire the key")
        XCTAssertEqual(harness.launches.count, 4, "nothing launches once the budget is spent")

        let clears = clearedServerIDs()
        XCTAssertFalse(clears.isEmpty, "the spent-budget path must speak")
        XCTAssertTrue(clears.allSatisfy { $0 == "sourcekit-lsp" })
    }

    /// A handshake whose capability answer names an encoding every offset in
    /// this codebase would misread (`utf-8`) never launches — and the key is
    /// retired with its clear, though nothing was ever opened or published.
    func testANonUTF16HandshakeRetiresTheKeyWithAClear() async throws {
        harness.initializeResult = ScriptedLSPTransport.initializeResult(positionEncoding: "utf-8")

        let prepared = await workspace.prepare(url: mainFile, language: .swift, text: "a")

        XCTAssertNil(prepared, "a server this client cannot address offsets for must not start")
        XCTAssertEqual(harness.launches.count, 1)
        XCTAssertEqual(clearedServerIDs(), ["sourcekit-lsp"])
    }

    /// A transport factory that cannot hand out a process at all (the missing-
    /// executable case) counts like a crash: three attempts are retried, and the
    /// fourth spends the budget and emits the key's clear — though nothing ever
    /// opened or published, a predecessor life's answers may be on screen.
    func testALaunchFailureSpendsIntoTheKeysClear() async throws {
        harness.launchError = .launchFailed("sourcekit-lsp not found")

        for _ in 1...3 {
            let prepared = await workspace.prepare(url: mainFile, language: .swift, text: "a")
            XCTAssertNil(prepared)
        }
        XCTAssertTrue(clearedServerIDs().isEmpty, "retries are not teardowns")

        let spent = await workspace.prepare(url: mainFile, language: .swift, text: "a")
        XCTAssertNil(spent)
        XCTAssertEqual(clearedServerIDs(), ["sourcekit-lsp"])
    }

    // MARK: - Composition (workspace → model)

    /// The whole channel over one scripted server, wired exactly as `PisakaApp`
    /// composes it — the workspace sink into `DiagnosticsModel.receive`, the
    /// sync reported as `LSPDocumentSyncController` reports it — so neither
    /// half can drift from the other: not the event shape, and not the roo
    /// spelling (`rootKey`'s canonical form, `/private/tmp/…` here) the clears
    /// are keyed by.
    func testTheWholeChannelFromPushToStoreAndBackToEmpty() async throws {
        let model = DiagnosticsModel()
        workspace.onDiagnostics = { [weak model] event in model?.receive(event) }

        let prepared = try await open(mainFile, text: "let a = 1\nlet b = 2\n")
        // The controller's report verbatim: prepare's version, the revision
        // pinned synchronously before its hop (zero — nothing edited yet).
        model.noteSynced(url: mainFile, version: prepared.version, revision: 0)

        try push(to: harness.latest, uri: prepared.uri, version: prepared.version, [
            (LSPPosition(line: 0, character: 4), LSPPosition(line: 0, character: 5), .error, "e"),
            (LSPPosition(line: 1, character: 4), LSPPosition(line: 1, character: 5), .warning, "w"),
        ])
        try await waitFor("the push in the store") { !self.publishedEntries(in: model).isEmpty }

        let entry = try XCTUnwrap(model.store.entry(for: mainFile))
        XCTAssertEqual(entry.serverKey.root, serverRoot, "the store keys by the canonical root, as the clears will")
        XCTAssertEqual(entry.diagnostics.count, 2)
        XCTAssertEqual(model.counts, DiagnosticStore.Counts(errors: 1, warnings: 1))

        // And D33 empties it through the same wiring.
        await workspace.shutdownAll()
        XCTAssertTrue(model.rows(relativeTo: root).isEmpty)
        XCTAssertEqual(model.counts, DiagnosticStore.Counts(errors: 0, warnings: 0))
    }

    /// The report-vs-push race at full composition: the workspace committed
    /// the flushed version and routes the server's answer before the
    /// controller's task has resumed far enough to report the sync (its own
    /// doc comment concedes a real server pushes "well before the flush tha
    /// carried it returns"). The event reaches the sink, the model has no
    /// record yet — and when the report lands it must admit the held push,
    /// with no second notification arriving to save it.
    func testAPushThatBeatsItsSyncsReportStillLandsInTheStore() async throws {
        let model = DiagnosticsModel()
        workspace.onDiagnostics = { [weak self, weak model] event in
            self?.events.append(event)
            model?.receive(event)
        }

        let prepared = try await open(mainFile, text: "let a = 1\n")
        try push(to: harness.latest, uri: prepared.uri, version: prepared.version, [
            (LSPPosition(line: 0, character: 4), LSPPosition(line: 0, character: 5), .error, "early"),
        ])
        try await waitFor("the sink to see the early push") { !self.publishedEvents().isEmpty }
        XCTAssertTrue(
            publishedEntries(in: model).isEmpty,
            "routed before its report exists: nothing on the surfaces yet"
        )

        // The controller's report, exactly as `schedule` makes it — after the
        // push, which is the ordering the race produces.
        model.noteSynced(url: mainFile, version: prepared.version, revision: 0)

        let diagnostics = publishedEntries(in: model)
        XCTAssertEqual(diagnostics.count, 1, "the landing report admits the held push")
        XCTAssertEqual(diagnostics.first?.message, "early")
        XCTAssertEqual(model.counts, DiagnosticStore.Counts(errors: 1, warnings: 0))
    }

    private func publishedEntries(in model: DiagnosticsModel) -> [Diagnostic] {
        model.store.entry(for: mainFile)?.diagnostics ?? []
    }
}
