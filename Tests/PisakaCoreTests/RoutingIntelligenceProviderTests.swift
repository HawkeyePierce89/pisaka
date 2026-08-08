import XCTest
@testable import PisakaCore

/// The composition the editor actually holds: a language server first, the
/// tree-sitter index whenever the server does not answer something usable in time.
///
/// Every case runs the *real* stack — `LSPIntelligenceProvider` over a real
/// `LSPWorkspace` and `LSPSession`, on a `ScriptedLSPTransport` — against a real
/// `SymbolIntelligenceProvider` over a small index, because what is under test is
/// which of two genuine answers comes back. The two are made deliberately easy to
/// tell apart: the server points at `Sources/Core/Greeter.swift`, the index at
/// `Sources/Legacy/Greeter.swift`, so no assertion here can be satisfied by the
/// wrong provider.
///
/// The load-bearing case is the *last* one: with no server registered for the
/// language, the output must equal the bare index provider's, asserted by
/// equality rather than by inspection — that is the promise that phase 2a changed
/// nothing for every language but Swift.
@MainActor
final class RoutingIntelligenceProviderTests: XCTestCase {

    // MARK: - The project

    /// Spelled canonically (`/private/tmp`, not `/tmp`) so the relative paths the
    /// candidates carry are predictable on a Mac.
    private let root = URL(fileURLWithPath: "/private/tmp/PisakaRouting/pkg", isDirectory: true)

    private var mainFile: URL { root.appendingPathComponent("Sources/App/main.swift") }
    /// Where the *server* says `Greeter` is declared.
    private var serverFile: URL { root.appendingPathComponent("Sources/Core/Greeter.swift") }
    /// Where the *index* says it is declared.
    private var indexFile: URL { root.appendingPathComponent("Sources/Legacy/Greeter.swift") }

    private let mainSource = """
        import Core

        let greeter = Greeter()
        """

    private let serverSource = """
        public struct Greeter {
            public init() {}
        }
        """

    /// Offset of `Greeter` in `mainSource`.
    private var greeterReference: Int { (mainSource as NSString).range(of: "Greeter()").location }
    /// A caret just after a typed `Gree`, for the completion requests.
    private var typedCaret: Int { greeterReference + 4 }

    // MARK: - Harness

    /// One scripted server, with a launch counter — the assertion behind "nothing
    /// was even attempted".
    private final class Harness {
        let transport = ScriptedLSPTransport()
        private(set) var launches = 0
        /// When set, every launch fails the way a missing executable does.
        var launchError: LSPTransportError?

        init() {
            transport.script(LSPMethod.initialize, .reply(ScriptedLSPTransport.initializeResult()))
            transport.script(LSPMethod.shutdown, .reply(.null))
        }

        func makeTransport(_ description: LSPServerDescription, _ root: URL) throws -> LSPTransport {
            launches += 1
            if let launchError { throw launchError }
            return transport
        }
    }

    /// Long enough that the *router's* deadline is always the one that fires, so a
    /// timeout case is testing the layer it says it is.
    private nonisolated static let patientSession = LSPSession.Budgets(
        handshake: 5,
        definition: 5,
        completion: 5,
        resolve: 5,
        shutdown: 1
    )

    private var harness = Harness()
    private var recordedDelays: [TimeInterval] = []

    private var transport: ScriptedLSPTransport { harness.transport }

    override func setUp() {
        super.setUp()
        harness = Harness()
        recordedDelays = []
    }

    // MARK: - Building the composition

    /// The index both the router's fallback and the bare comparison provider read.
    private func makeIndex() -> SymbolIndex {
        var index = SymbolIndex()
        index.replace(fileURL: indexFile, symbols: [
            Symbol(
                name: "Greeter",
                kind: .type,
                range: NSRange(location: 14, length: 7),
                fileURL: indexFile,
                line: 1
            ),
            Symbol(
                name: "Greeting",
                kind: .type,
                range: NSRange(location: 40, length: 8),
                fileURL: indexFile,
                line: 3
            )
        ])
        return index
    }

    private func makeFallback(_ index: SymbolIndex) -> SymbolIntelligenceProvider {
        SymbolIntelligenceProvider(index: index, projectRoot: root)
    }

    private func makeRouter(
        index: SymbolIndex,
        registry: LSPServerRegistry = .standard,
        budgets: RoutingIntelligenceProvider.Budgets = .standard,
        sessionBudgets: LSPSession.Budgets = RoutingIntelligenceProviderTests.patientSession
    ) -> RoutingIntelligenceProvider {
        let harness = self.harness
        let workspace = LSPWorkspace(
            registry: registry,
            budgets: sessionBudgets,
            processID: 4242,
            transportFactory: { description, launchRoot in
                try harness.makeTransport(description, launchRoot)
            },
            delay: { [weak self] seconds in self?.recordedDelays.append(seconds) }
        )
        workspace.prepareForFolderChange(root: root)

        let source = serverSource
        let target = CanonicalPath.canonical(serverFile).path
        let lsp = LSPIntelligenceProvider(
            workspace: workspace,
            loadText: { url in
                CanonicalPath.canonical(url).path == target ? source : nil
            }
        )
        return RoutingIntelligenceProvider(
            lsp: lsp,
            fallback: makeFallback(index),
            budgets: budgets
        )
    }

    // MARK: - Requests

    private func definitionRequest(text: String? = nil) -> DefinitionRequest {
        DefinitionRequest(
            identifier: "Greeter",
            fileURL: mainFile,
            offset: greeterReference,
            text: text ?? mainSource
        )
    }

    private func completionRequest() -> CompletionRequest {
        CompletionRequest(
            prefix: "Gree",
            fileURL: mainFile,
            text: mainSource,
            language: .swift,
            offset: typedCaret
        )
    }

    /// The server's answer to `textDocument/definition`: line 0 of
    /// `Sources/Core/Greeter.swift`, i.e. somewhere the index has never heard of.
    private func serverDefinitionReply() -> JSONValue {
        .array([
            .object([
                "uri": .string(LSPWorkspace.documentURI(for: serverFile)),
                "range": .object([
                    "start": .object(["line": .int(0), "character": .int(14)]),
                    "end": .object(["line": .int(0), "character": .int(21)])
                ])
            ])
        ])
    }

    /// One completion item as the wire spells it.
    private func completionItemJSON(_ label: String) -> JSONValue {
        .object([
            "label": .string(label),
            "sortText": .string("100"),
            "insertText": .string(label),
            "filterText": .string(label),
            "kind": .int(LSPCompletionItemKind.struct.rawValue),
            "insertTextFormat": .int(1)
        ])
    }

    // MARK: - A live server wins

    func testALiveServerAnswersTheDefinitionAndTheIndexIsNotConsulted() async throws {
        transport.script(LSPMethod.definition, .reply(serverDefinitionReply()))
        let router = makeRouter(index: makeIndex())

        let candidates = await router.definitions(for: definitionRequest())

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidate.relativePath, "Sources/Core/Greeter.swift")
        XCTAssertEqual((serverSource as NSString).substring(with: candidate.range), "Greeter")
        // A location carries no kind; the index's `Greeter` is a `.type`, so this
        // could not have come from there.
        XCTAssertNil(candidate.kind)
        XCTAssertEqual(harness.launches, 1)
    }

    func testALiveServerAnswersTheCompletionAndTheIndexIsNotConsulted() async {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array([completionItemJSON("GreeterFromTheServer")])
        ])))
        let router = makeRouter(index: makeIndex())

        let items = await router.completions(for: completionRequest())

        XCTAssertEqual(items.map(\.text), ["GreeterFromTheServer"])
    }

    // MARK: - Timeout

    /// The budget the *user* waits, which is the router's and not the session's:
    /// the answer comes from the index, and the abandoned question is withdrawn
    /// from the server rather than left running.
    func testATimeoutFallsBackToTheIndexAndCancelsTheLSPRequest() async throws {
        transport.script(LSPMethod.definition, .drop)
        let router = makeRouter(
            index: makeIndex(),
            budgets: RoutingIntelligenceProvider.Budgets(definition: 0.05)
        )

        let candidates = await router.definitions(for: definitionRequest())

        // The index's answer, not the server's.
        XCTAssertEqual(candidates.map(\.relativePath), ["Sources/Legacy/Greeter.swift"])
        XCTAssertEqual(candidates.first?.kind, .type)
        // The server was asked, and then told to stop — by the time the fallback
        // was returned, not at some later point.
        XCTAssertEqual(transport.requests(for: LSPMethod.definition).count, 1)
        XCTAssertEqual(transport.notifications(for: LSPMethod.cancelRequest).count, 1)
        let cancelled = transport.notifications(for: LSPMethod.cancelRequest)
            .first?.params?["id"]?.intValue
        XCTAssertEqual(
            transport.requests(for: LSPMethod.definition).first?.id,
            cancelled.map(LSPRequestID.number)
        )
    }

    /// Nothing is remembered: the next request asks the same server again. D7's
    /// only durable state is the restart budget, and a timeout is not a crash.
    func testATimeoutIsNotRememberedAndTheNextRequestAsksAgain() async {
        transport.script(LSPMethod.definition, [.drop, .reply(serverDefinitionReply())])
        let router = makeRouter(
            index: makeIndex(),
            budgets: RoutingIntelligenceProvider.Budgets(definition: 0.05)
        )

        let first = await router.definitions(for: definitionRequest())
        XCTAssertEqual(first.map(\.relativePath), ["Sources/Legacy/Greeter.swift"])

        let second = await router.definitions(
            for: DefinitionRequest(
                identifier: "Greeter",
                fileURL: mainFile,
                offset: greeterReference,
                text: mainSource
            )
        )
        XCTAssertEqual(second.map(\.relativePath), ["Sources/Core/Greeter.swift"])
        XCTAssertEqual(harness.launches, 1, "the server was never restarted")
    }

    // MARK: - A server that has been given up on

    func testAnUnavailableServerFallsBackWithoutAttemptingALaunch() async {
        // A machine with no Xcode: the factory throws, four times, and D7 gives up.
        harness.launchError = .launchFailed("sourcekit-lsp not found")
        let router = makeRouter(index: makeIndex())

        for _ in 1...4 {
            let candidates = await router.definitions(for: definitionRequest())
            XCTAssertEqual(candidates.map(\.relativePath), ["Sources/Legacy/Greeter.swift"])
        }
        XCTAssertEqual(harness.launches, 4)
        XCTAssertEqual(recordedDelays, LSPWorkspace.backoffDelays)

        let afterwards = await router.definitions(for: definitionRequest())
        let completions = await router.completions(for: completionRequest())

        XCTAssertEqual(afterwards.map(\.relativePath), ["Sources/Legacy/Greeter.swift"])
        // The index's two declarations plus the word the buffer itself contains —
        // exactly what the tree-sitter provider answers on its own.
        XCTAssertEqual(completions.map(\.text), ["Greeter", "Greeting", "greeter"])
        XCTAssertEqual(harness.launches, 4, "a server given up on is never launched again")
    }

    // MARK: - No server for the language

    /// The promise phase 2a must not break: for a language nothing serves, the
    /// router *is* the tree-sitter provider. Asserted by equality on both request
    /// kinds rather than by reading the answers, because equality is the only form
    /// of the claim that cannot drift.
    func testWithNoServerRegisteredTheOutputEqualsTheBareIndexProvidersOutput() async {
        let index = makeIndex()
        let router = makeRouter(index: index, registry: .empty)
        let bare = makeFallback(index)

        let routedDefinitions = await router.definitions(for: definitionRequest())
        let bareDefinitions = await bare.definitions(for: definitionRequest())
        let routedCompletions = await router.completions(for: completionRequest())
        let bareCompletions = await bare.completions(for: completionRequest())

        XCTAssertEqual(routedDefinitions, bareDefinitions)
        XCTAssertEqual(routedCompletions, bareCompletions)
        XCTAssertFalse(routedDefinitions.isEmpty)
        XCTAssertFalse(routedCompletions.isEmpty)
        // Not merely equal by luck: the LSP stack was never entered.
        XCTAssertEqual(harness.launches, 0)
        XCTAssertTrue(transport.sentMethods.isEmpty)
    }

    /// The same, for a language a server *could* serve nothing about: the request
    /// carries no language at all, which is a url-less scratch buffer.
    func testACompletionWithNoLanguageIsAnsweredByTheIndexAlone() async {
        let index = makeIndex()
        let router = makeRouter(index: index)
        let request = CompletionRequest(
            prefix: "Gree",
            fileURL: mainFile,
            text: mainSource,
            language: nil,
            offset: typedCaret
        )

        let routed = await router.completions(for: request)
        let bare = await makeFallback(index).completions(for: request)

        XCTAssertEqual(routed, bare)
        XCTAssertEqual(harness.launches, 0)
    }

    // MARK: - Empty answers

    /// A server that offers nothing has not answered better than the index; it has
    /// failed to answer.
    func testAnEmptyLSPCompletionFallsBackToANonEmptyIndexList() async {
        transport.script(LSPMethod.completion, .reply(.object(["items": .array([])])))
        let router = makeRouter(index: makeIndex())

        let items = await router.completions(for: completionRequest())

        XCTAssertEqual(items.map(\.text), ["Greeter", "Greeting", "greeter"])
        XCTAssertEqual(harness.launches, 1, "the server was asked first")
    }

    /// And when neither has anything, the answer is nothing — one beep, from one
    /// empty result, rather than two rounds of hoping.
    func testAnEmptyLSPDefinitionWithAnEmptyIndexStaysEmpty() async {
        transport.script(LSPMethod.definition, .reply(.null))
        let router = makeRouter(index: SymbolIndex())

        let candidates = await router.definitions(for: definitionRequest())

        XCTAssertTrue(candidates.isEmpty)
        XCTAssertEqual(transport.requests(for: LSPMethod.definition).count, 1)
    }

    // MARK: - D2's guard, routed

    /// A call site that forgot the buffer must not produce a confident, wrong LSP
    /// answer. The guard itself lives in `LSPIntelligenceProvider`; what is pinned
    /// here is where the request lands as a result — on the index, with nothing
    /// sent and no server started.
    func testADefinitionTrippingTheD2GuardIsAnsweredByTheIndex() async {
        transport.script(LSPMethod.definition, .reply(serverDefinitionReply()))
        let index = makeIndex()
        let router = makeRouter(index: index)
        let request = definitionRequest(text: "")

        let routed = await router.definitions(for: request)
        let bare = await makeFallback(index).definitions(for: request)

        XCTAssertEqual(routed, bare)
        XCTAssertEqual(routed.map(\.relativePath), ["Sources/Legacy/Greeter.swift"])
        XCTAssertEqual(harness.launches, 0)
        XCTAssertTrue(transport.requests(for: LSPMethod.definition).isEmpty)
    }

    // MARK: - Resolve

    /// The deferred-edits round trip reaches the provider that issued the item;
    /// an item from the index resolves to nothing, through the same call.
    func testResolveIsRoutedToTheProviderThatIssuedTheItem() async throws {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array([
                .object([
                    "label": .string("Greeter"),
                    "sortText": .string("100"),
                    "insertText": .string("Greeter"),
                    "kind": .int(LSPCompletionItemKind.struct.rawValue),
                    "data": .object(["itemId": .int(7)])
                ])
            ])
        ])))
        transport.script(LSPMethod.resolveCompletionItem, .reply(.object([
            "label": .string("Greeter"),
            "insertText": .string("Greeter"),
            "additionalTextEdits": .array([
                .object([
                    "newText": .string("import Core\n"),
                    "range": .object([
                        "start": .object(["line": .int(0), "character": .int(0)]),
                        "end": .object(["line": .int(0), "character": .int(0)])
                    ])
                ])
            ])
        ])))
        let router = makeRouter(index: makeIndex())

        let items = await router.completions(for: completionRequest())
        let item = try XCTUnwrap(items.first)
        XCTAssertNotNil(item.resolveHandle)

        let edits = await router.resolveEdits(for: item)
        XCTAssertEqual(edits.map(\.role), [.primary, .additional])
        XCTAssertEqual(edits.last?.newText, "import Core\n")

        let indexItem = CompletionItem(text: "Greeting", kind: .type, isFromCurrentFile: false)
        let none = await router.resolveEdits(for: indexItem)
        XCTAssertTrue(none.isEmpty)
    }
}
