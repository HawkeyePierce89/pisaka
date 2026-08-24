import XCTest
@testable import PisakaCore

/// The notification channel (D29): server-initiated notifications leave the
/// session on `notifications` instead of vanishing, in wire order, and the
/// stream's finish is the crash/exit signal.
///
/// Everything runs against `ScriptedLSPTransport`, so each ending — EOF, a
/// framing error, a graceful shutdown, a payload that decodes to nothing — is a
/// deterministic unit test. The consumer side mirrors what `LSPWorkspace` will
/// do: one iteration attached before `start`, run for the life of the session.
final class LSPSessionNotificationTests: XCTestCase {
    /// Budgets short enough that a hung test fails in a second rather than in
    /// twenty (the same numbers `LSPSessionTests` uses).
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

    private let definitionResult: JSONValue = .array([
        .object([
            "uri": .string("file:///tmp/Project/Sources/Greeter/Greeter.swift"),
            "range": .object([
                "start": .object(["line": .int(4), "character": .int(15)]),
                "end": .object(["line": .int(4), "character": .int(22)]),
            ]),
        ]),
    ])

    /// A diagnostics push shaped like the real thing, params and all.
    private func publishDiagnostics(severity: Int) -> JSONValue {
        .object([
            "uri": .string(documentURI),
            "version": .int(3),
            "diagnostics": .array([
                .object([
                    "range": .object([
                        "start": .object(["line": .int(0), "character": .int(0)]),
                        "end": .object(["line": .int(0), "character": .int(5)]),
                    ]),
                    "severity": .int(severity),
                    "message": .string("'foo' was not found in this scope"),
                ]),
            ]),
        ])
    }

    // MARK: - Helpers

    /// A transport whose `initialize` already answers, so a test that is about
    /// something else does not have to say so.
    private func makeTransport() -> ScriptedLSPTransport {
        let transport = ScriptedLSPTransport()
        transport.script(LSPMethod.initialize, .reply(ScriptedLSPTransport.initializeResult()))
        return transport
    }

    private func start(_ session: LSPSession) async throws {
        try await session.start(
            processID: 4242,
            rootURI: "file:///tmp/Project",
            rootPath: "/tmp/Project"
        )
    }

    /// Consume the session's notification stream from the beginning — the shape
    /// `LSPWorkspace` will use, attached before `start`.
    private func consume(_ session: LSPSession) -> NotificationRecorder {
        let recorder = NotificationRecorder()
        Task {
            let stream = await session.notifications
            for await notification in stream {
                recorder.record(notification)
            }
            recorder.markFinished()
        }
        return recorder
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

    // MARK: - Delivery

    func testANotificationIsDeliveredWithItsMethodAndParamsIntact() async throws {
        let transport = makeTransport()
        let session = LSPSession(transport: transport, budgets: Self.quick)
        let recorder = consume(session)
        try await start(session)

        let params = publishDiagnostics(severity: 1)
        transport.push(method: LSPMethod.publishDiagnostics, params: params)

        await waitFor("the notification to be delivered") { recorder.values.count == 1 }
        let delivered = try XCTUnwrap(recorder.values.first)
        XCTAssertEqual(delivered.method, LSPMethod.publishDiagnostics)
        XCTAssertEqual(delivered.params, params)
        // Delivered ≠ ended: the session lives on after a push, as before D29.
        XCTAssertFalse(recorder.isFinished)
        let phase = await session.currentPhase
        XCTAssertEqual(phase, .running)
    }

    func testTwoNotificationsArriveInSendOrder() async throws {
        let transport = makeTransport()
        let session = LSPSession(transport: transport, budgets: Self.quick)
        let recorder = consume(session)
        try await start(session)

        // One immediately, one right behind it, one delayed past both: send
        // order is delivery order in every case, which is the property D29's
        // ordering argument needs from the channel.
        transport.push(method: "window/logMessage", params: .object([
            "type": .int(3),
            "message": .string("indexing"),
        ]))
        transport.push(method: LSPMethod.publishDiagnostics, params: publishDiagnostics(severity: 1))
        transport.pushAfter(
            delay: 0.05,
            method: LSPMethod.publishDiagnostics,
            params: publishDiagnostics(severity: 2)
        )

        await waitFor("all three notifications") { recorder.values.count == 3 }
        XCTAssertEqual(
            recorder.values.map(\.method),
            ["window/logMessage", LSPMethod.publishDiagnostics, LSPMethod.publishDiagnostics]
        )
        // And the delayed one carried its own payload, not the first push's.
        XCTAssertEqual(recorder.values.last?.params?["diagnostics"]?[0]?["severity"]?.intValue, 2)
    }

    /// A hundred pushes emitted before the consumer's *first* hop must all
    /// arrive, in send order — the unbounded-buffering claim D29's ordering
    /// argument rests on (a coalescing policy would strand all but the last).
    func testABurstEmittedBeforeTheConsumerRunsArrivesCompleteAndInOrder() async throws {
        let transport = makeTransport()
        let session = LSPSession(transport: transport, budgets: Self.quick)
        try await start(session)

        // Every push is enqueued while nobody consumes: the recorder attaches
        // only after the whole burst is already in the stream.
        for index in 0..<100 {
            transport.push(
                method: LSPMethod.publishDiagnostics,
                params: .object(["burst": .int(index)])
            )
        }

        let recorder = consume(session)
        await waitFor("the whole burst") { recorder.values.count == 100 }
        let indexes = recorder.values.compactMap { $0.params?["burst"]?.intValue }
        XCTAssertEqual(indexes, Array(0..<100), "delivery order is wire order, with nothing stranded")
    }

    func testANotificationInterleavedWithAResponseDoesNotDisturbThePendingTable() async throws {
        let transport = makeTransport()
        // The answer is still in flight when the pushes land.
        transport.script(LSPMethod.definition, .reply(definitionResult, after: 0.15))
        let session = LSPSession(transport: transport, budgets: Self.quick)
        let recorder = consume(session)
        try await start(session)

        let params = definitionParams
        let request = Task { try await session.definition(params) }
        await waitFor("the request to be in flight") { await session.pendingRequestCount == 1 }

        transport.push(method: LSPMethod.publishDiagnostics, params: publishDiagnostics(severity: 1))
        transport.pushAfter(delay: 0.02, method: "window/logMessage", params: .null)

        // The interleaved notifications cost the round trip nothing…
        let response = try await request.value
        XCTAssertEqual(response.targets.count, 1)
        // …and the pending table is empty afterwards: no continuation leaked,
        // no answer was misrouted into the notification channel or vice versa.
        let pending = await session.pendingRequestCount
        XCTAssertEqual(pending, 0)
        await waitFor("both notifications") { recorder.values.count == 2 }
        XCTAssertEqual(
            recorder.values.map(\.method),
            [LSPMethod.publishDiagnostics, "window/logMessage"]
        )
    }

    // MARK: - Endings finish the stream

    func testTheStreamFinishesOnEOF() async throws {
        let transport = makeTransport()
        let session = LSPSession(transport: transport, budgets: Self.quick)
        let recorder = consume(session)
        try await start(session)

        transport.push(method: LSPMethod.publishDiagnostics, params: publishDiagnostics(severity: 1))
        await waitFor("the push to arrive") { recorder.values.count == 1 }

        transport.closeStream()

        await waitFor("the stream to finish") { recorder.isFinished }
        let phase = await session.currentPhase
        XCTAssertEqual(phase, .terminated)
    }

    func testTheStreamFinishesOnAFramingError() async throws {
        let transport = makeTransport()
        transport.script(LSPMethod.definition, .raw(Data("garbage\r\n\r\n".utf8)))
        let session = LSPSession(transport: transport, budgets: Self.quick)
        let recorder = consume(session)
        try await start(session)

        do {
            _ = try await session.definition(definitionParams)
            XCTFail("Bytes that are not LSP must not read as an answer")
        } catch {
            XCTAssertEqual(
                error as? LSPSessionError,
                .framing(.malformedHeader("garbage"))
            )
        }

        // The framing error closed the session, so it also ended the channel:
        // D33's signal that this server's diagnostics must be cleared.
        await waitFor("the stream to finish") { recorder.isFinished }
    }

    func testTheStreamFinishesOnShutdown() async throws {
        let transport = makeTransport()
        transport.script(LSPMethod.shutdown, .reply(.null))
        let session = LSPSession(transport: transport, budgets: Self.quick)
        let recorder = consume(session)
        try await start(session)

        await session.shutdown()

        await waitFor("the stream to finish") { recorder.isFinished }
        XCTAssertTrue(transport.isTerminated)
    }

    // MARK: - Bad payloads

    func testAMalformedNotificationPayloadIsDroppedWithoutEndingTheStream() async throws {
        let transport = makeTransport()
        let session = LSPSession(transport: transport, budgets: Self.quick)
        let recorder = consume(session)
        try await start(session)

        // Framed correctly, undecodable as JSON-RPC (`{}` has neither `method`
        // nor `id`): exactly one message lost, the stream still in sync.
        let body = Data("{}".utf8)
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        transport.write(frame)

        // A well-formed push behind it proves both halves of that: it arrives…
        transport.push(method: LSPMethod.publishDiagnostics, params: publishDiagnostics(severity: 1))
        await waitFor("the good push to arrive") { recorder.values.count == 1 }
        XCTAssertEqual(recorder.values.first?.method, LSPMethod.publishDiagnostics)
        // …and nothing ended: no spurious value stood in for the dropped one,
        // and the conversation is still open for business.
        XCTAssertFalse(recorder.isFinished)
        let phase = await session.currentPhase
        XCTAssertEqual(phase, .running)
        transport.script(LSPMethod.definition, .reply(definitionResult))
        let response = try await session.definition(definitionParams)
        XCTAssertEqual(response.targets.count, 1)
    }
}

/// Thread-safe landing pad for one consumed notification stream: the values in
/// arrival order plus whether the stream has finished.
///
/// `@unchecked Sendable` over an `NSLock`, like `ScriptedLSPTransport`: the
/// session yields from its read task, the recording is read from the test task.
private final class NotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [LSPServerNotification] = []
    private var finished = false

    func record(_ value: LSPServerNotification) {
        lock.lock()
        received.append(value)
        lock.unlock()
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    var values: [LSPServerNotification] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}
