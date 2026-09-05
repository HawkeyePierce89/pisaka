import XCTest
@testable import PisakaCore

/// Where a fold list comes from: the language server that serves the file, or the
/// pure scanner everywhere else.
///
/// The composition under test is the real one — `LSPIntelligenceProvider` over a
/// real `LSPWorkspace`/`LSPSession` on a `ScriptedLSPTransport`, wrapped around a
/// real `SymbolIntelligenceProvider` — because what is being asserted is *which of
/// two genuine answers* comes back. The two are made impossible to confuse: the
/// scripted server names exactly one region, headed by line 1 and carrying a
/// `kind`, while the scanner finds several, headed by line 0 and carrying none. No
/// assertion here can be satisfied by the wrong source.
///
/// The load-bearing case is the equality one: for a language nothing serves, the
/// router's answer must *be* the scanner's, byte for byte — the same promise
/// `RoutingIntelligenceProviderTests` makes for definitions and completions, made
/// again for the question this feature adds.
@MainActor
final class FoldRoutingTests: XCTestCase {

    // MARK: - The project

    private let root = URL(fileURLWithPath: "/private/tmp/PisakaFolding/pkg", isDirectory: true)

    private var mainFile: URL { root.appendingPathComponent("Sources/App/Greeter.swift") }

    /// Two nested brace blocks, so the scanner has more than one thing to say and
    /// its answer cannot be mistaken for the server's single region.
    ///
    /// Lines: 0 `struct Greeter {`, 1 `    func greet() {`, 2 the `print`, 3 the
    /// inner `}`, 4 the outer `}`.
    private let mainSource = """
        struct Greeter {
            func greet() {
                print("hi")
            }
        }
        """

    private let widths = IndentLevelWidths(unitWidth: 4, tabWidth: 4)

    private func foldRequest(
        text: String? = nil,
        language: SyntaxLanguage? = .swift,
        fileURL: URL? = nil
    ) -> FoldRegionRequest {
        FoldRegionRequest(
            fileURL: fileURL ?? mainFile,
            text: text ?? mainSource,
            language: language,
            indentWidths: widths
        )
    }

    /// What the pure scanner says about `mainSource` — the answer every fallback
    /// case must reproduce exactly.
    private var scannerRegions: [FoldRegion] {
        FoldRegionScanner.scan(text: mainSource as NSString, widths: widths)
    }

    /// The server's single region: the body of `greet()`, headed by line 1 and
    /// named — three facts the scanner never produces together.
    private func serverFoldReply() -> JSONValue {
        .array([
            .object([
                "startLine": .int(1),
                "endLine": .int(3),
                "kind": .string("region"),
            ]),
        ])
    }

    /// The same region as a `FoldRegion`: from the end of line 1's content to the
    /// end of line 3's content, both characters absent so both default to the
    /// length of their line.
    private var serverRegion: FoldRegion {
        let source = mainSource as NSString
        let start = NSMaxRange(source.range(of: "    func greet() {"))
        let end = NSMaxRange(source.range(of: "    }"))
        // Force-unwrapped deliberately: a `nil` here would make every assertion
        // below vacuous rather than failing.
        return FoldRegion(
            hiddenRange: NSRange(location: start, length: end - start),
            headerLine: 1,
            kind: .region
        )!
    }

    // MARK: - Harness

    private final class Harness {
        let transport = ScriptedLSPTransport()
        private(set) var launches = 0

        init(foldingRange: Bool = true) {
            transport.script(
                LSPMethod.initialize,
                .reply(ScriptedLSPTransport.initializeResult(foldingRange: foldingRange))
            )
            transport.script(LSPMethod.shutdown, .reply(.null))
        }

        func makeTransport(_ description: LSPServerDescription, _ root: URL) throws -> LSPTransport {
            launches += 1
            return transport
        }
    }

    /// Long enough that the *router's* deadline is always the one that fires, so a
    /// timeout case tests the layer it claims to.
    private nonisolated static let patientSession = LSPSession.Budgets(
        handshake: 5,
        definition: 5,
        completion: 5,
        resolve: 5,
        hover: 5,
        references: 5,
        foldingRange: 5,
        shutdown: 1
    )

    private var harness = Harness()

    private var transport: ScriptedLSPTransport { harness.transport }

    /// The workspace the last router was built over — the only way to stage a
    /// folder switch while a question is outstanding, since the provider keeps its
    /// own private.
    private var lastWorkspace: LSPWorkspace?

    override func setUp() {
        super.setUp()
        harness = Harness()
        lastWorkspace = nil
    }

    private func makeFallback() -> SymbolIntelligenceProvider {
        SymbolIntelligenceProvider(index: SymbolIndex(), projectRoot: root)
    }

    private func makeRouter(
        registry: LSPServerRegistry = .standard,
        budgets: RoutingIntelligenceProvider.Budgets = .standard,
        fallback: (any CodeIntelligenceProviding)? = nil
    ) -> RoutingIntelligenceProvider {
        let harness = self.harness
        let workspace = LSPWorkspace(
            registry: registry,
            budgets: FoldRoutingTests.patientSession,
            processID: 4242,
            transportFactory: { description, launchRoot in
                try harness.makeTransport(description, launchRoot)
            },
            delay: { _ in }
        )
        workspace.prepareForFolderChange(root: root)
        lastWorkspace = workspace
        return RoutingIntelligenceProvider(
            lsp: LSPIntelligenceProvider(workspace: workspace, loadText: { _ in nil }),
            fallback: fallback ?? makeFallback(),
            budgets: budgets
        )
    }

    // MARK: - A live server wins, whole

    func testAServedLanguageAnswersTheServersRegionsAndTheScannerIsNotConsulted() async {
        transport.script(LSPMethod.foldingRange, .reply(serverFoldReply()))
        let router = makeRouter()

        let regions = await router.foldRegions(for: foldRequest())

        XCTAssertEqual(regions, [serverRegion])
        XCTAssertEqual(harness.launches, 1)
        XCTAssertEqual(transport.requests(for: LSPMethod.foldingRange).count, 1)
    }

    /// **Never a mixture.** One source or the other, whole: a list carrying both
    /// the server's region and the scanner's would put two regions on header lines
    /// that disagree about where a block ends, and `FoldState` reconciles folds by
    /// header line.
    func testAServersAnswerIsNeverMergedWithTheScannersCandidates() async {
        transport.script(LSPMethod.foldingRange, .reply(serverFoldReply()))
        let router = makeRouter()

        let regions = await router.foldRegions(for: foldRequest())
        let scanner = scannerRegions

        XCTAssertEqual(regions.count, 1)
        XCTAssertGreaterThan(scanner.count, 1, "the scanner must have had more to say")
        XCTAssertFalse(
            regions.contains(where: { $0.headerLine == 0 }),
            "the outer block is the scanner's candidate and the server never named it"
        )
        for region in scanner {
            XCTAssertFalse(regions.contains(region), "a scanner candidate reached a served answer")
        }
    }

    // MARK: - No server for the language

    /// The promise this feature must not break: where nothing serves the file, the
    /// router *is* the scanner. Asserted by equality rather than by inspection,
    /// because equality is the only form of the claim that cannot drift.
    func testWithNoServerRegisteredTheOutputEqualsTheBareScannersOutput() async {
        transport.script(LSPMethod.foldingRange, .reply(serverFoldReply()))
        let router = makeRouter(registry: .empty)
        let bare = makeFallback()

        let routed = await router.foldRegions(for: foldRequest())
        let unrouted = await bare.foldRegions(for: foldRequest())

        XCTAssertEqual(routed, unrouted)
        XCTAssertEqual(routed, scannerRegions)
        XCTAssertFalse(routed.isEmpty)
        // Not merely equal by luck: the LSP stack was never entered.
        XCTAssertEqual(harness.launches, 0)
        XCTAssertTrue(transport.sentMethods.isEmpty)
    }

    /// A buffer with no language at all — a scratch file — is the scanner's alone,
    /// and costs no hop to establish.
    func testARequestWithNoLanguageIsAnsweredByTheScannerAlone() async {
        transport.script(LSPMethod.foldingRange, .reply(serverFoldReply()))
        let router = makeRouter()
        let request = foldRequest(language: nil)

        let routed = await router.foldRegions(for: request)

        XCTAssertEqual(routed, scannerRegions)
        XCTAssertEqual(harness.launches, 0)
    }

    /// A url-less buffer is unanswerable by a server and perfectly answerable by
    /// the scanner — which is the routing the request's optional `fileURL` exists
    /// for. The language still says "Swift", so this is the LSP provider refusing
    /// rather than the router never asking.
    func testAUrllessBufferFallsThroughToTheScanner() async {
        transport.script(LSPMethod.foldingRange, .reply(serverFoldReply()))
        let router = makeRouter()
        let request = FoldRegionRequest(
            fileURL: nil,
            text: mainSource,
            language: .swift,
            indentWidths: widths
        )

        let routed = await router.foldRegions(for: request)

        XCTAssertEqual(routed, scannerRegions)
        XCTAssertTrue(transport.requests(for: LSPMethod.foldingRange).isEmpty)
    }

    // MARK: - The server does not answer

    /// A server that offers nothing has not answered better than the scanner; it
    /// has failed to answer. A file with braces in it folds *somewhere*.
    func testAnEmptyServerAnswerFallsThroughToTheScanner() async {
        transport.script(LSPMethod.foldingRange, .reply(.array([])))
        let router = makeRouter()

        let regions = await router.foldRegions(for: foldRequest())

        XCTAssertEqual(regions, scannerRegions)
        XCTAssertEqual(harness.launches, 1, "the server was asked first")
        XCTAssertEqual(transport.requests(for: LSPMethod.foldingRange).count, 1)
    }

    /// `null` is the same empty answer, and takes the same route.
    func testANullServerAnswerFallsThroughToTheScanner() async {
        transport.script(LSPMethod.foldingRange, .reply(.null))
        let router = makeRouter()

        let regions = await router.foldRegions(for: foldRequest())

        XCTAssertEqual(regions, scannerRegions)
    }

    /// The budget the *user* waits: the answer comes from the scanner, and the
    /// abandoned question is withdrawn from the server rather than left running.
    func testATimeoutFallsBackToTheScannerAndCancelsTheRequest() async {
        transport.script(LSPMethod.foldingRange, .drop)
        let router = makeRouter(budgets: RoutingIntelligenceProvider.Budgets(foldingRange: 0.05))

        let regions = await router.foldRegions(for: foldRequest())

        XCTAssertEqual(regions, scannerRegions)
        XCTAssertEqual(transport.requests(for: LSPMethod.foldingRange).count, 1)
        // Waited for rather than asserted outright: `withBudget` leaves the losing
        // racer unstructured, so by the time the caller holds the fallback the
        // cancellation is scheduled and not yet on the wire.
        await untilTrue("the abandoned fold question is cancelled") {
            self.transport.notifications(for: LSPMethod.cancelRequest).count == 1
        }
    }

    /// A server that does not advertise `foldingRangeProvider` is not asked at
    /// all — the capability gate hover's path states, applied to a question that
    /// also fires behind every typing pause.
    func testAServerWithoutTheCapabilityIsNeverAskedAndTheScannerAnswers() async {
        harness = Harness(foldingRange: false)
        transport.script(LSPMethod.foldingRange, .reply(serverFoldReply()))
        let router = makeRouter()

        let regions = await router.foldRegions(for: foldRequest())

        XCTAssertEqual(regions, scannerRegions)
        XCTAssertEqual(harness.launches, 1, "the server started; it was simply not asked")
        XCTAssertTrue(transport.requests(for: LSPMethod.foldingRange).isEmpty)
    }

    /// An empty buffer has no second line, so both answers to it are the same
    /// empty list — and the round trip that could only confirm that is not made.
    func testAnEmptyBufferAsksNothingAndFoldsNowhere() async {
        transport.script(LSPMethod.foldingRange, .reply(serverFoldReply()))
        let router = makeRouter()

        let regions = await router.foldRegions(for: foldRequest(text: ""))

        XCTAssertTrue(regions.isEmpty)
        XCTAssertTrue(transport.requests(for: LSPMethod.foldingRange).isEmpty)
    }

    // MARK: - A stale answer

    /// **The staleness gate, staged causally.** The fold question is held inside
    /// `send`, so the folder switch provably lands while it is outstanding and the
    /// reply cannot arrive before it. The server's list is then about a document
    /// the window has left, and hiding text by it would hide the wrong text — so
    /// the scanner's answer, computed against the buffer in hand, is what the
    /// caller gets.
    func testAnAnswerForAFolderTheUserHasLeftIsDroppedForTheScanners() async throws {
        transport.script(LSPMethod.foldingRange, .reply(serverFoldReply()))
        let router = makeRouter()
        let workspace = try XCTUnwrap(lastWorkspace)
        let gate = Gate()
        transport.onSend { method in
            guard method == LSPMethod.foldingRange else { return }
            gate.wait()
        }

        let asking = Task { await router.foldRegions(for: self.foldRequest()) }
        await gate.waitUntilReached()

        workspace.prepareForFolderChange(
            root: URL(fileURLWithPath: "/private/tmp/PisakaFolding/other", isDirectory: true)
        )
        gate.release()

        let regions = await asking.value
        XCTAssertEqual(regions, scannerRegions)
        XCTAssertNotEqual(regions, [serverRegion])
    }

    // MARK: - The budget

    /// One number, spelled in two places that must agree: the session bounds the
    /// server's part of the exchange, the router the whole attempt.
    func testTheFoldingBudgetIsCompletionsAndMatchesTheSessions() {
        XCTAssertEqual(RoutingIntelligenceProvider.Budgets.standard.foldingRange, 1.5)
        XCTAssertEqual(
            RoutingIntelligenceProvider.Budgets.standard.foldingRange,
            LSPSession.Budgets.standard.foldingRange
        )
        XCTAssertEqual(
            RoutingIntelligenceProvider.Budgets.standard.foldingRange,
            RoutingIntelligenceProvider.Budgets.standard.completion
        )
    }

    // MARK: - Waiting

    /// Poll `condition` until it holds, or fail after `timeout` seconds — the
    /// honest shape for work the router runs unstructured.
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
