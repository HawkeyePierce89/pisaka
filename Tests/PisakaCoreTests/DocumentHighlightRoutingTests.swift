import XCTest
@testable import PisakaCore

/// Where an occurrence highlight comes from: the language server's
/// `textDocument/documentHighlight`, or the textual `OccurrenceScan`, and never
/// both (D45).
///
/// The composition is the real one, as in `FoldRoutingTests`:
/// `LSPIntelligenceProvider` over a real `LSPWorkspace`/`LSPSession` on a
/// `ScriptedLSPTransport`, wrapped around a real `SymbolIntelligenceProvider`. The
/// two answers cannot be confused. The scripted server names two occurrences, one
/// of them a write. The scan finds four, every one a read, and each answer carries
/// its provenance.
///
/// The router's one departure from folding is pinned here: **a server answer is
/// final, even an empty one.** Only `nil` falls back.
@MainActor
final class DocumentHighlightRoutingTests: XCTestCase {

    // MARK: - The project

    private let root = URL(fileURLWithPath: "/private/tmp/PisakaHighlight/pkg", isDirectory: true)

    private var mainFile: URL { root.appendingPathComponent("Sources/App/Counter.swift") }

    /// `count` four times as a word, and once inside `counter`, which the scan
    /// must not match.
    private let mainSource = """
        var count = 0
        count += 1
        let counter = count
        print(count)
        """

    private func request(
        text: String? = nil,
        offset: Int = 4,
        language: SyntaxLanguage? = .swift,
        fileURL: URL?? = .none
    ) -> DocumentHighlightRequest {
        DocumentHighlightRequest(
            identifier: "count",
            fileURL: fileURL ?? mainFile,
            offset: offset,
            text: text ?? mainSource,
            language: language
        )
    }

    /// What the scan says about `mainSource`: four reads.
    private var textualAnswer: DocumentHighlightAnswer {
        let ranges = OccurrenceScan.identifierMatches(of: "count", in: mainSource as NSString, language: .swift)
        return DocumentHighlightAnswer(
            provenance: .textual,
            highlights: (ranges ?? []).map { .init(range: $0, kind: .read) }
        )
    }

    private func lspRange(line: Int, from start: Int, to end: Int) -> JSONValue {
        .object([
            "start": .object(["line": .int(line), "character": .int(start)]),
            "end": .object(["line": .int(line), "character": .int(end)]),
        ])
    }

    /// Two occurrences, out of order, one named a write and one a plain text.
    private func serverReply() -> JSONValue {
        .array([
            .object(["range": lspRange(line: 1, from: 0, to: 5), "kind": .int(1)]),
            .object(["range": lspRange(line: 0, from: 4, to: 9), "kind": .int(3)]),
        ])
    }

    private var serverAnswer: DocumentHighlightAnswer {
        DocumentHighlightAnswer(provenance: .server, highlights: [
            .init(range: NSRange(location: 4, length: 5), kind: .write),
            .init(range: NSRange(location: 14, length: 5), kind: .read),
        ])
    }

    // MARK: - Harness

    private final class Harness {
        let transport = ScriptedLSPTransport()
        private(set) var launches = 0

        init(documentHighlight: Bool = true) {
            transport.script(
                LSPMethod.initialize,
                .reply(ScriptedLSPTransport.initializeResult(documentHighlight: documentHighlight))
            )
            transport.script(LSPMethod.shutdown, .reply(.null))
        }

        func makeTransport(_ description: LSPServerDescription, _ root: URL) throws -> LSPTransport {
            launches += 1
            return transport
        }
    }

    /// Long enough that the router's deadline is always the one that fires.
    private nonisolated static let patientSession = LSPSession.Budgets(
        handshake: 5,
        definition: 5,
        completion: 5,
        resolve: 5,
        hover: 5,
        references: 5,
        foldingRange: 5,
        documentHighlight: 5,
        shutdown: 1
    )

    private var harness = Harness()

    private var transport: ScriptedLSPTransport { harness.transport }

    private var lastWorkspace: LSPWorkspace?

    override func setUp() {
        super.setUp()
        harness = Harness()
        lastWorkspace = nil
    }

    private func makeFallback() -> SymbolIntelligenceProvider {
        SymbolIntelligenceProvider(index: SymbolIndex(), projectRoot: root)
    }

    private func makeLSP(registry: LSPServerRegistry = .standard) -> LSPIntelligenceProvider {
        let harness = self.harness
        let workspace = LSPWorkspace(
            registry: registry,
            budgets: DocumentHighlightRoutingTests.patientSession,
            processID: 4242,
            transportFactory: { description, launchRoot in
                try harness.makeTransport(description, launchRoot)
            },
            delay: { _ in }
        )
        workspace.prepareForFolderChange(root: root)
        lastWorkspace = workspace
        return LSPIntelligenceProvider(workspace: workspace, loadText: { _ in nil })
    }

    private func makeRouter(
        registry: LSPServerRegistry = .standard,
        budgets: RoutingIntelligenceProvider.Budgets = .standard
    ) -> RoutingIntelligenceProvider {
        RoutingIntelligenceProvider(
            lsp: makeLSP(registry: registry),
            fallback: makeFallback(),
            budgets: budgets
        )
    }

    // MARK: - The server's answer, whole

    func testAServedLanguageAnswersTheServersHighlightsWithServerProvenance() async {
        transport.script(LSPMethod.documentHighlight, .reply(serverReply()))
        let router = makeRouter()

        let answer = await router.documentHighlights(for: request())

        XCTAssertEqual(answer, serverAnswer)
        let sent = transport.requests(for: LSPMethod.documentHighlight)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.params?["position"]?["line"]?.intValue, 0)
        XCTAssertEqual(sent.first?.params?["position"]?["character"]?.intValue, 4)
    }

    /// `Write` is a write. `Read`, `Text`, an absent kind and an unnamed number
    /// are all reads.
    func testKindsMapWriteToWriteAndEverythingElseToRead() async {
        transport.script(LSPMethod.documentHighlight, .reply(.array([
            .object(["range": lspRange(line: 0, from: 4, to: 9), "kind": .int(3)]),
            .object(["range": lspRange(line: 1, from: 0, to: 5), "kind": .int(2)]),
            .object(["range": lspRange(line: 2, from: 14, to: 19)]),
            .object(["range": lspRange(line: 3, from: 6, to: 11), "kind": .int(1)]),
            .object(["range": lspRange(line: 3, from: 0, to: 5), "kind": .int(42)]),
        ])))
        let router = makeRouter()

        let answer = await router.documentHighlights(for: request())

        XCTAssertEqual(answer?.provenance, .server)
        XCTAssertEqual(answer?.highlights.map(\.kind), [.write, .read, .read, .read, .read])
        XCTAssertEqual(
            answer?.highlights.map(\.range.location),
            [4, 14, 39, 45, 51],
            "ascending, mapped through LSPPositionMap"
        )
    }

    /// **Never a mixture.** The scan would add two more `count`s; none of them
    /// may reach a served answer, and no answer carries a second provenance.
    func testAServersAnswerIsNeverMergedWithTheScan() async {
        transport.script(LSPMethod.documentHighlight, .reply(serverReply()))
        let router = makeRouter()

        let answer = await router.documentHighlights(for: request())
        let scan = textualAnswer

        XCTAssertEqual(answer?.highlights.count, 2)
        XCTAssertEqual(scan.highlights.count, 4, "the scan must have had more to say")
        let served = Set(answer?.highlights.map(\.range) ?? [])
        XCTAssertFalse(served.contains(NSRange(location: 39, length: 5)))
        XCTAssertFalse(served.contains(NSRange(location: 51, length: 5)))
    }

    /// **An empty server answer is final**, unlike folding's. The server
    /// resolved the symbol and found nothing else, which is an answer.
    func testAnEmptyServerAnswerIsFinalAndTheScanIsNotConsulted() async {
        transport.script(LSPMethod.documentHighlight, .reply(.array([])))
        let router = makeRouter()

        let answer = await router.documentHighlights(for: request())

        XCTAssertEqual(answer, DocumentHighlightAnswer(provenance: .server, highlights: []))
    }

    func testANullServerAnswerIsTheSameFinalEmptyAnswer() async {
        transport.script(LSPMethod.documentHighlight, .reply(.null))
        let router = makeRouter()

        let answer = await router.documentHighlights(for: request())

        XCTAssertEqual(answer, DocumentHighlightAnswer(provenance: .server, highlights: []))
    }

    // MARK: - Falling back, silently

    func testAFailedRequestFallsBackToTheScan() async {
        transport.script(
            LSPMethod.documentHighlight,
            .fail(LSPResponseError(code: .internalError, message: "internal error"))
        )
        let router = makeRouter()

        let answer = await router.documentHighlights(for: request())

        XCTAssertEqual(answer, textualAnswer)
        XCTAssertEqual(transport.requests(for: LSPMethod.documentHighlight).count, 1)
    }

    func testATimeoutFallsBackToTheScanAndCancelsTheRequest() async {
        transport.script(LSPMethod.documentHighlight, .drop)
        let router = makeRouter(budgets: RoutingIntelligenceProvider.Budgets(documentHighlight: 0.05))

        let answer = await router.documentHighlights(for: request())

        XCTAssertEqual(answer, textualAnswer)
        await untilTrue("the abandoned highlight question is cancelled") {
            self.transport.notifications(for: LSPMethod.cancelRequest).count == 1
        }
    }

    func testAServerWithoutTheCapabilityIsNeverAskedAndTheScanAnswers() async {
        harness = Harness(documentHighlight: false)
        transport.script(LSPMethod.documentHighlight, .reply(serverReply()))
        let router = makeRouter()

        let answer = await router.documentHighlights(for: request())

        XCTAssertEqual(answer, textualAnswer)
        XCTAssertEqual(harness.launches, 1, "the server started; it was simply not asked")
        XCTAssertTrue(transport.requests(for: LSPMethod.documentHighlight).isEmpty)
    }

    /// Where nothing serves the file the router *is* the scan, byte for byte,
    /// and the LSP stack is never entered.
    func testWithNoServerRegisteredTheAnswerEqualsTheBareScan() async {
        let router = makeRouter(registry: .empty)

        let routed = await router.documentHighlights(for: request())
        let bare = await makeFallback().documentHighlights(for: request())

        XCTAssertEqual(routed, bare)
        XCTAssertEqual(routed, textualAnswer)
        XCTAssertEqual(harness.launches, 0)
        XCTAssertTrue(transport.sentMethods.isEmpty)
    }

    func testARequestWithNoLanguageIsTheScansAlone() async {
        let router = makeRouter()

        let answer = await router.documentHighlights(for: request(language: nil))

        XCTAssertEqual(answer?.provenance, .textual)
        XCTAssertEqual(answer?.highlights.count, 4)
        XCTAssertEqual(harness.launches, 0)
    }

    func testAUrllessBufferFallsThroughToTheScan() async {
        transport.script(LSPMethod.documentHighlight, .reply(serverReply()))
        let router = makeRouter()

        let answer = await router.documentHighlights(for: request(fileURL: .some(nil)))

        XCTAssertEqual(answer, textualAnswer)
        XCTAssertTrue(transport.requests(for: LSPMethod.documentHighlight).isEmpty)
    }

    // MARK: - A stale buffer

    /// The question is held inside `send` while the folder switches, so the
    /// reply provably arrives for a document the window has left. The LSP
    /// provider answers `nil`, and the router falls back to the scan of the
    /// buffer in hand.
    func testAnAnswerForABufferNoLongerHeldIsNilAndTheRouterScans() async throws {
        transport.script(LSPMethod.documentHighlight, .reply(serverReply()))
        let lsp = makeLSP()
        let router = RoutingIntelligenceProvider(lsp: lsp, fallback: makeFallback())
        let workspace = try XCTUnwrap(lastWorkspace)
        let gate = Gate()
        transport.onSend { method in
            guard method == LSPMethod.documentHighlight else { return }
            gate.wait()
        }

        let asking = Task { await lsp.documentHighlights(for: self.request()) }
        await gate.waitUntilReached()
        workspace.prepareForFolderChange(
            root: URL(fileURLWithPath: "/private/tmp/PisakaHighlight/other", isDirectory: true)
        )
        gate.release()

        let direct = await asking.value
        XCTAssertNil(direct)
        // The workspace has left the folder, so the router no longer asks at all.
        let routed = await router.documentHighlights(for: request())
        XCTAssertEqual(routed, textualAnswer)
    }

    // MARK: - The textual provider

    func testTheScanAnswersEveryWholeWordAsAReadWithTextualProvenance() async {
        let answer = await makeFallback().documentHighlights(for: request())

        XCTAssertEqual(answer?.provenance, .textual)
        XCTAssertEqual(answer?.highlights.map(\.range.location), [4, 14, 39, 51])
        XCTAssertTrue(answer?.highlights.allSatisfy { $0.kind == .read } ?? false)
    }

    /// One identifier run longer than the production ceiling exhausts the
    /// scan's budget, and an exhausted budget is `nil`, never a partial list.
    func testAnExhaustedScanBudgetIsNil() async {
        let text = String(repeating: "a", count: OccurrenceScan.maximumWorkUnits + 16)
        let answer = await makeFallback().documentHighlights(for: DocumentHighlightRequest(
            identifier: "a",
            fileURL: nil,
            offset: 0,
            text: text,
            language: .swift
        ))
        XCTAssertNil(answer)
    }

    // MARK: - The budget

    func testTheBudgetIsCompletionsAndMatchesTheSessions() {
        XCTAssertEqual(RoutingIntelligenceProvider.Budgets.standard.documentHighlight, 1.5)
        XCTAssertEqual(
            RoutingIntelligenceProvider.Budgets.standard.documentHighlight,
            LSPSession.Budgets.standard.documentHighlight
        )
        XCTAssertEqual(
            RoutingIntelligenceProvider.Budgets.standard.documentHighlight,
            RoutingIntelligenceProvider.Budgets.standard.completion
        )
    }

    // MARK: - Waiting

    private func untilTrue(
        _ what: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting until \(what)", file: file, line: line)
    }
}
