import XCTest
@testable import PisakaCore

/// The workspace half of the diagnostics channel: which pushes survive D31's
/// gates and reach the sink with buffer offsets, and which clears the teardown
/// paths owe the model (D33) — including the externally-killed-server case,
/// where the *stream's* termination is the signal and the consumer task speaks.
///
/// Every case runs on `ScriptedLSPTransport`, so "the server crashed" is a
/// deterministic unit test; the pushes travel through the session's read task,
/// the notification stream and the main-actor consumer, and the assertions
/// poll for the sink's record rather than assuming any particular hop count.
@MainActor
final class LSPDiagnosticsRoutingTests: XCTestCase {

    // MARK: - Harness

    /// Same shape as `LSPWorkspaceTests.ServerHarness`: one scripted transport
    /// per launch, plus a record of who launched what.
    private final class ServerHarness {
        private(set) var launches: [(id: String, root: URL)] = []
        private(set) var transports: [ScriptedLSPTransport] = []

        func makeTransport(
            _ description: LSPServerDescription,
            _ root: URL
        ) throws -> LSPTransport {
            launches.append((description.id, root))
            let transport = ScriptedLSPTransport()
            transport.script(LSPMethod.initialize, .reply(ScriptedLSPTransport.initializeResult()))
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
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
    }

    /// Let the pipeline drain, for asserting an absence.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    private func push(
        to transport: ScriptedLSPTransport,
        uri: String,
        version: Int?,
        _ entries: [(LSPPosition, LSPPosition, LSPDiagnosticSeverity?, String)]
    ) throws {
        // Built as a literal rather than encoded: the params type is
        // decode-only (the server initiates this conversation), so the test
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

        await waitFor("the mapped push") { !self.publishedEvents().isEmpty }

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
        harness.latest.push(method: "window/logMessage", params: .object(["message": .string("hi")]))

        await settle()

        XCTAssertTrue(events.isEmpty, "only publishDiagnostics is routed; the rest stay noise")
    }

    func testAPushWithoutAVersionIsAccepted() async throws {
        let prepared = try await open(mainFile, text: "a")
        try push(to: harness.latest, uri: prepared.uri, version: nil, [])

        await waitFor("the unversioned push") { !self.publishedEvents().isEmpty }

        XCTAssertNil(publishedEvents().first?.version, "the wire value travels verbatim; gating is downstream")
    }

    // MARK: - Dropped pushes

    func testAPushWithAStaleVersionIsDropped() async throws {
        let prepared = try await open(mainFile, text: "a")
        try pushToMainFile(version: prepared.version + 7, message: "m")

        await settle()

        XCTAssertTrue(publishedEvents().isEmpty, "a push for a version the server does not hold is noise")
    }

    func testAPushForAnUnopenedURIIsDropped() async throws {
        _ = try await open(mainFile, text: "a")
        try push(
            to: harness.latest,
            uri: LSPWorkspace.documentURI(for: utilFile),
            version: 1,
            [(LSPPosition(line: 0, character: 0), LSPPosition(line: 0, character: 1), nil, "m")]
        )

        await settle()

        XCTAssertTrue(
            publishedEvents().isEmpty,
            "the panel covers held documents only; a URI no server holds is dropped"
        )
    }

    // MARK: - Clears (D33)

    func testACrashMidSessionClearsThatKey() async throws {
        _ = try await open(mainFile, text: "a")
        try pushToMainFile(version: 1, message: "m")
        await waitFor("the push") { !self.publishedEvents().isEmpty }

        harness.latest.closeStream()
        await waitFor("the consumer to see the stream finish") {
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
        await waitFor("the old push") { !self.publishedEvents().isEmpty }

        // Crash, then let the next request notice the death and start over.
        harness.latest.closeStream()
        _ = try await open(mainFile, text: "b")
        XCTAssertEqual(harness.launches.count, 2)

        try pushToMainFile(version: 1, message: "new")
        await waitFor("the new push") {
            self.publishedEvents().last?.diagnostics.first?.message == "new"
        }
        await settle()

        // Whatever clears the dead life earned arrived *before* the new push;
        // nothing may land after it.
        let lastPublishedIndex = events.lastIndex { event in
            if case .published = event { return true }
            return false
        } ?? 0
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
        await waitFor("the push") { !self.publishedEvents().isEmpty }

        workspace.prepareForFolderChange(root: otherRoot)
        await workspace.shutdownAll()

        XCTAssertEqual(
            clearedServerIDs(),
            ["sourcekit-lsp"],
            "one clear per torn-down key, emitted synchronously by the teardown itself"
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
        await waitFor("both pushes") { self.publishedEvents().count == 2 }

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
        await waitFor("the survivor's push") { !self.publishedEvents().isEmpty }
        XCTAssertTrue(
            clearedServerIDs().isEmpty,
            "no clear may follow a surviving server's push"
        )
    }
}
