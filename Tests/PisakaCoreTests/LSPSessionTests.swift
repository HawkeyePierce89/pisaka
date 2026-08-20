import XCTest
@testable import PisakaCore

/// The protocol driver: one conversation, from `initialize` to whichever way it
/// ends.
///
/// Everything here runs against `ScriptedLSPTransport`, so no process is ever
/// spawned and every "the server is slow / silent / dead / rude" case is a
/// deterministic unit test. The cases are chosen around the two things a
/// correlating client gets wrong — an answer matched to the wrong question, and a
/// pending entry that outlives the request — plus the endings, because a session
/// that fails a continuation twice crashes and one that fails it never hangs the
/// editor.
final class LSPSessionTests: XCTestCase {
    // MARK: - Fixtures

    /// Budgets short enough that a hung test fails in a second rather than in
    /// twenty, and long enough that a loaded CI machine still wins the race.
    private static let quick = LSPSession.Budgets(
        handshake: 2,
        definition: 2,
        completion: 2,
        resolve: 2,
        hover: 2,
        shutdown: 1
    )

    private let documentURI = "file:///tmp/Project/Sources/App/main.swift"

    private var definitionParams: LSPTextDocumentPositionParams {
        LSPTextDocumentPositionParams(uri: documentURI, position: LSPPosition(line: 3, character: 12))
    }

    private var completionParams: LSPCompletionParams {
        LSPCompletionParams(
            uri: documentURI,
            position: LSPPosition(line: 3, character: 12),
            context: .dot
        )
    }

    private let definitionResult: JSONValue = .array([
        .object([
            "uri": .string("file:///tmp/Project/Sources/Greeter/Greeter.swift"),
            "range": .object([
                "start": .object(["line": .int(4), "character": .int(15)]),
                "end": .object(["line": .int(4), "character": .int(22)])
            ])
        ])
    ])

    private let hoverResult: JSONValue = .object([
        "contents": .object([
            "kind": .string("markdown"),
            "value": .string("```swift\nfunc greet()\n```")
        ]),
        "range": .object([
            "start": .object(["line": .int(3), "character": .int(12)]),
            "end": .object(["line": .int(3), "character": .int(17)])
        ])
    ])

    private let completionResult: JSONValue = .object([
        "isIncomplete": .bool(false),
        "items": .array([
            .object(["label": .string("greet()"), "sortText": .string("001")])
        ])
    ])

    // MARK: - Helpers

    /// A transport whose `initialize` already answers, so a test that is about
    /// something else does not have to say so.
    private func makeTransport() -> ScriptedLSPTransport {
        let transport = ScriptedLSPTransport()
        transport.script(LSPMethod.initialize, .reply(ScriptedLSPTransport.initializeResult()))
        return transport
    }

    @discardableResult
    private func start(
        _ transport: ScriptedLSPTransport,
        budgets: LSPSession.Budgets = LSPSessionTests.quick,
        configuration: JSONValue? = nil
    ) async throws -> LSPSession {
        let session = LSPSession(transport: transport, budgets: budgets)
        try await session.start(
            processID: 4242,
            rootURI: "file:///tmp/Project",
            rootPath: "/tmp/Project",
            configuration: configuration
        )
        return session
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @Sendable () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
    }

    // MARK: - Handshake

    func testStartSendsInitializeThenInitialized() async throws {
        let transport = makeTransport()
        let session = try await start(transport)

        XCTAssertEqual(transport.sentMethods, [LSPMethod.initialize, LSPMethod.initialized])
        let capabilities = await session.capabilities
        XCTAssertEqual(capabilities?.supportsDefinition, true)
        XCTAssertEqual(capabilities?.supportsHover, true)
        XCTAssertEqual(capabilities?.supportsCompletion, true)
        XCTAssertEqual(capabilities?.resolvesCompletionItems, true)
        XCTAssertEqual(capabilities?.completionTriggerCharacters, [".", "("])
        XCTAssertEqual(capabilities?.usesUTF16Positions, true)
    }

    func testInitializeCarriesTheRootTheProcessIDAndThisPhasesCapabilities() async throws {
        let transport = makeTransport()
        try await start(transport)

        let initialize = try XCTUnwrap(transport.requests(for: LSPMethod.initialize).first)
        let params = try XCTUnwrap(initialize.params)
        XCTAssertEqual(params["rootUri"]?.stringValue, "file:///tmp/Project")
        // Both spellings travel: pyright reads only the deprecated path form.
        XCTAssertEqual(params["rootPath"]?.stringValue, "/tmp/Project")
        XCTAssertEqual(params["processId"]?.intValue, 4242)
        XCTAssertEqual(params["clientInfo"]?["name"]?.stringValue, "Pisaka")

        // The promises D2/D5 make: utf-16 offsets, link support, no snippets.
        let capabilities = try XCTUnwrap(params["capabilities"])
        XCTAssertEqual(
            capabilities["general"]?["positionEncodings"],
            .array([.string("utf-16")])
        )
        XCTAssertEqual(
            capabilities["textDocument"]?["definition"]?["linkSupport"]?.boolValue,
            true
        )
        // D25: both formats are asked for — markdown because it is the only way a
        // server marks a signature as code, plaintext so a server without a
        // markdown renderer answers anyway.
        XCTAssertEqual(
            capabilities["textDocument"]?["hover"]?["contentFormat"],
            .array([.string("markdown"), .string("plaintext")])
        )
        XCTAssertEqual(
            capabilities["textDocument"]?["hover"]?["dynamicRegistration"]?.boolValue,
            false
        )
        let item = capabilities["textDocument"]?["completion"]?["completionItem"]
        XCTAssertEqual(item?["snippetSupport"]?.boolValue, false)
        XCTAssertEqual(
            item?["resolveSupport"]?["properties"],
            .array([.string("detail"), .string("additionalTextEdits")])
        )
    }

    func testAHandshakeThatNeverAnswersFailsAndLeavesNoLiveServer() async {
        let transport = ScriptedLSPTransport()
        transport.script(LSPMethod.initialize, .drop)
        let session = LSPSession(
            transport: transport,
            budgets: LSPSession.Budgets(handshake: 0.05)
        )

        do {
            try await session.start(processID: nil, rootURI: nil)
            XCTFail("A handshake that is never answered must not succeed")
        } catch {
            XCTAssertEqual(
                error as? LSPSessionError,
                .timedOut(method: LSPMethod.initialize)
            )
        }

        // The whole point of failing: nothing is left running.
        XCTAssertTrue(transport.isTerminated)
        let phase = await session.currentPhase
        XCTAssertEqual(phase, .terminated)
        let pending = await session.pendingRequestCount
        XCTAssertEqual(pending, 0)
    }

    func testAnInitializeAnswerThatIsNotAnInitializeResultIsRejected() async {
        let transport = ScriptedLSPTransport()
        transport.script(LSPMethod.initialize, .reply(.string("sure")))
        let session = LSPSession(transport: transport, budgets: LSPSessionTests.quick)

        do {
            try await session.start(processID: nil, rootURI: nil)
            XCTFail("A nonsense `initialize` result must not start a session")
        } catch {
            guard case .handshakeRejected = error as? LSPSessionError else {
                return XCTFail("Expected `handshakeRejected`, got \(error)")
            }
        }
        XCTAssertTrue(transport.isTerminated)
    }

    // MARK: - Round trips

    func testASuccessfulRequestReturnsItsOwnAnswer() async throws {
        let transport = makeTransport()
        transport.script(LSPMethod.definition, .reply(definitionResult))
        let session = try await start(transport)

        let response = try await session.definition(definitionParams)
        XCTAssertEqual(response.targets.count, 1)
        XCTAssertEqual(response.targets.first?.uri, "file:///tmp/Project/Sources/Greeter/Greeter.swift")
        XCTAssertEqual(
            response.targets.first?.jumpRange,
            LSPRange(
                start: LSPPosition(line: 4, character: 15),
                end: LSPPosition(line: 4, character: 22)
            )
        )
        let pending = await session.pendingRequestCount
        XCTAssertEqual(pending, 0)
    }

    func testANullResultIsAnEmptyAnswerRatherThanAFailure() async throws {
        let transport = makeTransport()
        transport.script(LSPMethod.definition, .reply(.null))
        let session = try await start(transport)

        let response = try await session.definition(definitionParams)
        XCTAssertTrue(response.isEmpty)
    }

    func testHoverSendsThePositionItWasAskedAboutAndDecodesTheAnswer() async throws {
        let transport = makeTransport()
        transport.script(LSPMethod.hover, .reply(hoverResult))
        let session = try await start(transport)

        let response = try await session.hover(definitionParams)
        XCTAssertEqual(
            response.elements,
            [.markup(kind: .markdown, value: "```swift\nfunc greet()\n```")]
        )
        XCTAssertEqual(
            response.range,
            LSPRange(
                start: LSPPosition(line: 3, character: 12),
                end: LSPPosition(line: 3, character: 17)
            )
        )

        // The question, spelled as `textDocument/hover` with nothing but the
        // document and the position — a mis-spelled method is answered by
        // silence, never by a build failure.
        let request = try XCTUnwrap(transport.requests(for: LSPMethod.hover).first)
        XCTAssertEqual(request.params?["textDocument"]?["uri"]?.stringValue, documentURI)
        XCTAssertEqual(request.params?["position"]?["line"]?.intValue, 3)
        XCTAssertEqual(request.params?["position"]?["character"]?.intValue, 12)
        XCTAssertEqual(request.params?.objectValue?.keys.sorted(), ["position", "textDocument"])

        let pending = await session.pendingRequestCount
        XCTAssertEqual(pending, 0)
    }

    func testANullHoverResultIsAnEmptyAnswerRatherThanAFailure() async throws {
        let transport = makeTransport()
        transport.script(LSPMethod.hover, .reply(.null))
        let session = try await start(transport)

        let response = try await session.hover(definitionParams)
        XCTAssertTrue(response.isEmpty)
        XCTAssertNil(response.range)
    }

    func testHoverTimesOutOnItsOwnBudgetWithoutDisturbingOtherRequests() async throws {
        let transport = makeTransport()
        transport.script(LSPMethod.hover, .drop)
        transport.script(LSPMethod.definition, .reply(definitionResult))
        // Every other budget is set far longer than this test may run, so the
        // assertion below can only hold if `hover` is the one being spent. D25's
        // rule is that hover has a budget *of its own* — asserting merely that a
        // dropped request eventually throws would pass just as well if the method
        // read `definition`'s three seconds, which is the mistake worth catching.
        let session = try await start(
            transport,
            budgets: LSPSession.Budgets(
                handshake: 2,
                definition: 30,
                completion: 30,
                resolve: 30,
                hover: 0.05
            )
        )

        let started = Date()
        do {
            _ = try await session.hover(definitionParams)
            XCTFail("A dropped hover must not hang forever")
        } catch {
            XCTAssertEqual(error as? LSPSessionError, .timedOut(method: LSPMethod.hover))
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 2,
            "hover spent a budget other than its own"
        )

        // Hover's budget is its own: a pointer resting on a wedged symbol must
        // cost one question, not the ⌘-click behind it.
        let cancels = transport.notifications(for: LSPMethod.cancelRequest)
        XCTAssertEqual(cancels.count, 1)
        XCTAssertEqual(cancels.first?.params?["id"]?.intValue, 2)

        let definitions = try await session.definition(definitionParams)
        XCTAssertEqual(definitions.targets.count, 1)
        let pending = await session.pendingRequestCount
        XCTAssertEqual(pending, 0)
    }

    /// The pointer moved on. The dwell task is cancelled, and the server is told
    /// to stop working on an answer nobody will ever see.
    func testACancelledHoverEmitsCancelRequestAndLeavesNoPendingEntry() async throws {
        let transport = makeTransport()
        transport.script(LSPMethod.hover, .drop)
        let session = try await start(transport)

        let params = definitionParams
        let task = Task { try await session.hover(params) }
        await waitFor("the hover to be in flight") { await session.pendingRequestCount == 1 }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled hover must not produce an answer")
        } catch {
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        }

        let cancels = transport.notifications(for: LSPMethod.cancelRequest)
        XCTAssertEqual(cancels.count, 1)
        XCTAssertEqual(cancels.first?.params?["id"]?.intValue, 2)
        let pending = await session.pendingRequestCount
        XCTAssertEqual(pending, 0)
    }

    func testRequestIDsCountUpFromTheHandshake() async throws {
        let transport = makeTransport()
        transport.script(LSPMethod.definition, .reply(.null))
        let session = try await start(transport)

        _ = try await session.definition(definitionParams)
        _ = try await session.definition(definitionParams)

        XCTAssertEqual(
            transport.requests(for: LSPMethod.initialize).map(\.id),
            [.number(1)]
        )
        XCTAssertEqual(
            transport.requests(for: LSPMethod.definition).map(\.id),
            [.number(2), .number(3)]
        )
    }

    func testRepliesArrivingOutOfOrderEachResolveTheirOwnRequest() async throws {
        let transport = makeTransport()
        // The request sent first is answered last: correlation is by id, never by
        // arrival order.
        transport.script(LSPMethod.definition, .reply(definitionResult, after: 0.2))
        transport.script(LSPMethod.completion, .reply(completionResult, after: 0.02))
        let session = try await start(transport)

        async let definition = session.definition(definitionParams)
        async let completion = session.completion(completionParams)

        let (definitions, completions) = try await (definition, completion)
        XCTAssertEqual(definitions.targets.count, 1)
        XCTAssertEqual(completions.items.map(\.label), ["greet()"])
        let pending = await session.pendingRequestCount
        XCTAssertEqual(pending, 0)
    }

    func testAReplyToAnUnknownIDIsIgnoredAndTheSessionKeepsWorking() async throws {
        let transport = makeTransport()
        transport.script(LSPMethod.definition, .reply(definitionResult))
        let session = try await start(transport)

        // The answer to a request that already timed out — the ordinary case, not
        // a broken server.
        transport.emit(.response(LSPResponseMessage(id: .number(9_999), result: .null)))

        let response = try await session.definition(definitionParams)
        XCTAssertEqual(response.targets.count, 1)
    }

    func testAServerErrorIsThrownToTheCallerAsItself() async throws {
        let transport = makeTransport()
        transport.script(
            LSPMethod.definition,
            .fail(LSPResponseError(code: .requestFailed, message: "no index yet"))
        )
        let session = try await start(transport)

        do {
            _ = try await session.definition(definitionParams)
            XCTFail("A server error must not read as an answer")
        } catch {
            // Distinguishable from our own failures: this one says the *server*
            // refused, which is a different fact from a timeout.
            XCTAssertEqual(
                error as? LSPResponseError,
                LSPResponseError(code: .requestFailed, message: "no index yet")
            )
        }
        let pending = await session.pendingRequestCount
        XCTAssertEqual(pending, 0)
    }

    // MARK: - Budgets and cancellation

    func testATimeoutFailsOnlyItsOwnRequest() async throws {
        let transport = makeTransport()
        transport.script(LSPMethod.definition, .drop)
        transport.script(LSPMethod.completion, .reply(completionResult))
        let session = try await start(
            transport,
            budgets: LSPSession.Budgets(handshake: 2, definition: 0.05, completion: 2)
        )

        do {
            _ = try await session.definition(definitionParams)
            XCTFail("A dropped request must not hang forever")
        } catch {
            XCTAssertEqual(error as? LSPSessionError, .timedOut(method: LSPMethod.definition))
        }

        // The server is told to stop working on an answer nobody will read…
        let cancels = transport.notifications(for: LSPMethod.cancelRequest)
        XCTAssertEqual(cancels.count, 1)
        XCTAssertEqual(cancels.first?.params?["id"]?.intValue, 2)

        // …and the session is untouched: one slow answer is not a broken server.
        let completions = try await session.completion(completionParams)
        XCTAssertEqual(completions.items.map(\.label), ["greet()"])
        let pending = await session.pendingRequestCount
        XCTAssertEqual(pending, 0)
    }

    func testCancellationEmitsCancelRequestAndLeavesNoPendingEntry() async throws {
        let transport = makeTransport()
        transport.script(LSPMethod.definition, .drop)
        let session = try await start(transport)

        let params = definitionParams
        let task = Task { try await session.definition(params) }
        await waitFor("the request to be in flight") { await session.pendingRequestCount == 1 }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled request must not produce an answer")
        } catch {
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        }

        let cancels = transport.notifications(for: LSPMethod.cancelRequest)
        XCTAssertEqual(cancels.count, 1)
        XCTAssertEqual(cancels.first?.params?["id"]?.intValue, 2)
        // A leaked continuation is invisible until the process exits, so it is
        // asserted rather than assumed.
        let pending = await session.pendingRequestCount
        XCTAssertEqual(pending, 0)
    }

    // MARK: - Endings

    func testEOFMidFlightFailsPendingRequestsOnceAndClosesTheSession() async throws {
        let transport = makeTransport()
        transport.script(LSPMethod.definition, .drop)
        let session = try await start(transport)

        let params = definitionParams
        let first = Task { try await session.definition(params) }
        let second = Task { try await session.definition(params) }
        await waitFor("both requests to be in flight") { await session.pendingRequestCount == 2 }

        transport.closeStream()

        for task in [first, second] {
            do {
                _ = try await task.value
                XCTFail("A request in flight when the server dies must fail")
            } catch {
                XCTAssertEqual(error as? LSPSessionError, .connectionClosed)
            }
        }

        let phase = await session.currentPhase
        XCTAssertEqual(phase, .terminated)
        let pending = await session.pendingRequestCount
        XCTAssertEqual(pending, 0)

        // A second EOF (the stream finishing after `terminate()`, say) must not
        // resume anything a second time — that would be a crash, not a bug.
        transport.closeStream()

        let before = transport.sentMethods.count
        do {
            _ = try await session.definition(params)
            XCTFail("A terminated session must not answer")
        } catch {
            XCTAssertEqual(error as? LSPSessionError, .connectionClosed)
        }
        XCTAssertEqual(transport.sentMethods.count, before, "Nothing is written after the end")
    }

    func testAFramingErrorEndsTheConversationRatherThanDesyncingIt() async throws {
        let transport = makeTransport()
        transport.script(LSPMethod.definition, .raw(Data("garbage\r\n\r\n".utf8)))
        let session = try await start(transport)

        do {
            _ = try await session.definition(definitionParams)
            XCTFail("Bytes that are not LSP must not read as an answer")
        } catch {
            XCTAssertEqual(
                error as? LSPSessionError,
                .framing(.malformedHeader("garbage"))
            )
        }
        XCTAssertTrue(transport.isTerminated)
        let phase = await session.currentPhase
        XCTAssertEqual(phase, .terminated)
    }

    func testShutdownSendsShutdownThenExitThenTerminatesTheProcess() async throws {
        let transport = makeTransport()
        transport.script(LSPMethod.shutdown, .reply(.null))
        let session = try await start(transport)

        await session.shutdown()

        XCTAssertEqual(
            transport.sentMethods,
            [LSPMethod.initialize, LSPMethod.initialized, LSPMethod.shutdown, LSPMethod.exit]
        )
        // The order matters and so does the last step: `exit` is a request to
        // leave, `terminate()` is the guarantee.
        XCTAssertTrue(transport.isTerminated)
        let phase = await session.currentPhase
        XCTAssertEqual(phase, .terminated)
    }

    func testShutdownStillTerminatesAServerThatWillNotSayGoodbye() async throws {
        let transport = makeTransport()
        transport.script(LSPMethod.shutdown, .drop)
        let session = try await start(
            transport,
            budgets: LSPSession.Budgets(handshake: 2, shutdown: 0.05)
        )

        await session.shutdown()

        XCTAssertTrue(transport.isTerminated)
        XCTAssertEqual(transport.sentMethods.last, LSPMethod.exit)
    }

    func testARequestAfterShutdownIsRefusedWithoutTouchingTheWire() async throws {
        let transport = makeTransport()
        transport.script(LSPMethod.shutdown, .reply(.null))
        let session = try await start(transport)
        await session.shutdown()

        let before = transport.sentMethods.count
        do {
            _ = try await session.definition(definitionParams)
            XCTFail("A session that has shut down must not answer")
        } catch {
            XCTAssertEqual(error as? LSPSessionError, .notRunning)
        }
        XCTAssertEqual(transport.sentMethods.count, before)
    }

    // MARK: - Notifications out

    func testDocumentSyncNotificationsCarryTheirParamsAndExpectNoAnswer() async throws {
        let transport = makeTransport()
        let session = try await start(transport)

        try await session.didOpen(LSPDidOpenTextDocumentParams(
            textDocument: LSPTextDocumentItem(
                uri: documentURI,
                languageId: "swift",
                version: 1,
                text: "let a = 1\n"
            )
        ))
        try await session.didChange(LSPDidChangeTextDocumentParams(
            uri: documentURI,
            version: 2,
            fullText: "let a = 2\n"
        ))
        try await session.didClose(LSPDidCloseTextDocumentParams(uri: documentURI))

        XCTAssertEqual(
            transport.sentMethods,
            [
                LSPMethod.initialize, LSPMethod.initialized,
                LSPMethod.didOpen, LSPMethod.didChange, LSPMethod.didClose
            ]
        )
        let change = try XCTUnwrap(transport.notifications(for: LSPMethod.didChange).first)
        XCTAssertEqual(change.params?["textDocument"]?["version"]?.intValue, 2)
        XCTAssertEqual(
            change.params?["contentChanges"]?[0]?["text"]?.stringValue,
            "let a = 2\n"
        )
        // Full sync (D2): a whole-document change carries no `range`.
        XCTAssertNil(change.params?["contentChanges"]?[0]?["range"])

        // Notifications are one-way: nothing was answered.
        XCTAssertTrue(transport.sentResponses.isEmpty)
    }

    // MARK: - Server-initiated traffic

    func testRegisterCapabilityIsAcknowledged() async throws {
        let transport = makeTransport()
        // Held for the length of the test on purpose: the read task keeps the
        // session weakly (an unreferenced session must not keep a process alive),
        // so a discarded one stops answering.
        let session = try await start(transport)

        transport.emit(.request(LSPRequestMessage(
            id: .string("reg-1"),
            method: LSPMethod.registerCapability,
            params: .object(["registrations": .array([])])
        )))

        await waitFor("the registration to be answered") {
            !transport.sentResponses.isEmpty
        }
        let response = try XCTUnwrap(transport.sentResponses.first)
        XCTAssertEqual(response.id, .string("reg-1"))
        XCTAssertEqual(response.result, .null)
        XCTAssertNil(response.error)
        let isRunning = await session.isRunning
        XCTAssertTrue(isRunning)
    }

    func testWorkspaceConfigurationIsAnsweredWithOneAbsentValuePerItem() async throws {
        let transport = makeTransport()
        let session = try await start(transport)

        transport.emit(.request(LSPRequestMessage(
            id: .number(7),
            method: LSPMethod.workspaceConfiguration,
            params: .object([
                "items": .array([
                    .object(["section": .string("swift")]),
                    .object(["section": .string("sourcekit-lsp")])
                ])
            ])
        )))

        await waitFor("the configuration request to be answered") {
            !transport.sentResponses.isEmpty
        }
        let response = try XCTUnwrap(transport.sentResponses.first)
        XCTAssertEqual(response.id, .number(7))
        // One value per requested item, each of them "no setting" — a shorter
        // array is a protocol violation a server may treat as fatal.
        XCTAssertEqual(response.result, .array([.null, .null]))
        // And the handshake is byte-for-byte the one every server saw before
        // configuration existed: a session started without one pushes nothing.
        XCTAssertEqual(transport.sentMethods, [LSPMethod.initialize, LSPMethod.initialized])
        let isRunning = await session.isRunning
        XCTAssertTrue(isRunning)
    }

    // MARK: - Per-server configuration

    /// Shaped like the YAML server's, including a section whose name is not an
    /// identifier: a section is matched by its exact spelling, nothing else.
    private let scriptedConfiguration: JSONValue = .object([
        "yaml": .object([
            "schemaStore": .object(["enable": .bool(true)]),
            "completion": .bool(true)
        ]),
        "[yaml]": .object(["editor.tabSize": .int(2)])
    ])

    func testAConfiguredSessionPushesItsSettingsRightAfterInitialized() async throws {
        let transport = makeTransport()
        let session = try await start(transport, configuration: scriptedConfiguration)

        // After `initialized` and not before it: the spec forbids anything else
        // in between.
        XCTAssertEqual(
            transport.sentMethods,
            [LSPMethod.initialize, LSPMethod.initialized, LSPMethod.didChangeConfiguration]
        )
        let pushed = try XCTUnwrap(
            transport.notifications(for: LSPMethod.didChangeConfiguration).first
        )
        XCTAssertEqual(pushed.params?["settings"], scriptedConfiguration)
        let isRunning = await session.isRunning
        XCTAssertTrue(isRunning)
    }

    func testWorkspaceConfigurationIsAnsweredSectionBySectionFromTheConfiguration()
        async throws {
        let transport = makeTransport()
        let session = try await start(transport, configuration: scriptedConfiguration)

        transport.emit(.request(LSPRequestMessage(
            id: .number(9),
            method: LSPMethod.workspaceConfiguration,
            params: .object([
                "items": .array([
                    .object(["section": .string("yaml")]),
                    .object(["section": .string("http")]),
                    .object(["section": .string("[yaml]")]),
                    .object([:])
                ])
            ])
        )))

        await waitFor("the configuration pull to be answered") {
            !transport.sentResponses.isEmpty
        }
        let response = try XCTUnwrap(transport.sentResponses.first)
        XCTAssertEqual(response.id, .number(9))
        // In order, one per item: the named sections verbatim, `null` for the
        // section this server's configuration does not mention and for the item
        // that names no section at all.
        XCTAssertEqual(response.result, .array([
            try XCTUnwrap(scriptedConfiguration["yaml"]),
            .null,
            try XCTUnwrap(scriptedConfiguration["[yaml]"]),
            .null
        ]))
        let isRunning = await session.isRunning
        XCTAssertTrue(isRunning)
    }

    func testTheConfigurationAnswersEveryPullForTheLifeOfTheSession() async throws {
        let transport = makeTransport()
        // The pinned yaml-language-server pulls on `initialized` and re-pulls
        // whenever it is told settings changed, so answering once is not enough.
        let session = try await start(transport, configuration: scriptedConfiguration)

        for id in 1...2 {
            transport.emit(.request(LSPRequestMessage(
                id: .number(id),
                method: LSPMethod.workspaceConfiguration,
                params: .object(["items": .array([.object(["section": .string("yaml")])])])
            )))
            await waitFor("pull \(id) to be answered") {
                transport.sentResponses.count >= id
            }
        }

        XCTAssertEqual(transport.sentResponses.count, 2)
        for response in transport.sentResponses {
            XCTAssertEqual(
                response.result,
                .array([try XCTUnwrap(scriptedConfiguration["yaml"])])
            )
        }
        let isRunning = await session.isRunning
        XCTAssertTrue(isRunning)
    }

    func testAnUnknownServerRequestIsAnsweredWithMethodNotFound() async throws {
        let transport = makeTransport()
        let session = try await start(transport)

        transport.emit(.request(LSPRequestMessage(
            id: .number(11),
            method: "window/showMessageRequest",
            params: .object(["message": .string("pick one")])
        )))

        await waitFor("the unknown request to be answered") {
            !transport.sentResponses.isEmpty
        }
        let response = try XCTUnwrap(transport.sentResponses.first)
        XCTAssertEqual(response.id, .number(11))
        // Answered, not ignored: a server blocked on its own request stops
        // answering ours.
        XCTAssertEqual(response.error?.code, .methodNotFound)
        XCTAssertNil(response.result)
        let isRunning = await session.isRunning
        XCTAssertTrue(isRunning)
    }

    func testUnknownNotificationsAreIgnoredWithoutAReply() async throws {
        let transport = makeTransport()
        transport.script(LSPMethod.definition, .reply(.null))
        let session = try await start(transport)

        transport.emit(.notification(LSPNotificationMessage(
            method: "window/logMessage",
            params: .object(["type": .int(3), "message": .string("indexing")])
        )))
        transport.emit(.notification(LSPNotificationMessage(
            method: "textDocument/publishDiagnostics",
            params: .object(["uri": .string(documentURI), "diagnostics": .array([])])
        )))

        // Round-trips through the same read loop, so both notifications have been
        // seen by the time this returns.
        _ = try await session.definition(definitionParams)

        XCTAssertTrue(transport.sentResponses.isEmpty, "A notification wants no answer")
    }
}
