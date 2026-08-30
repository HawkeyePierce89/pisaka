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
        hover: 5,
        references: 5,
        shutdown: 1
    )

    /// A fallback that *would* answer the three questions no real one does —
    /// hover, references and rename.
    ///
    /// The only way to assert "the wrapped provider is never consulted" rather
    /// than merely observe that nothing came back: with a stock
    /// `SymbolIntelligenceProvider` underneath, a routed `nil` and a fallen-through
    /// `nil` are the same value, and the rules with no fallback would be the rules
    /// in this file no test could see.
    private final class AnsweringFallback: CodeIntelligenceProviding {
        let wrapped: SymbolIntelligenceProvider
        private(set) var hoverCalls = 0
        private(set) var referencesCalls = 0
        private(set) var renameCalls = 0

        init(_ wrapped: SymbolIntelligenceProvider) { self.wrapped = wrapped }

        func references(for request: UsagesRequest) async -> [UsageResult] {
            referencesCalls += 1
            return [
                UsageResult(
                    fileURL: URL(fileURLWithPath: "/private/tmp/PisakaRouting/pkg/from-the-index.swift"),
                    range: NSRange(location: 0, length: 7),
                    line: 1,
                    relativePath: "from-the-index.swift",
                    preview: MatchPreview(text: "Greeter", matchRange: NSRange(location: 0, length: 7)),
                    isTextual: true
                ),
            ]
        }

        func renameEdits(for request: RenameRequest) async -> RenameAnswer? {
            renameCalls += 1
            return RenameAnswer(
                newName: request.newName,
                edit: LSPWorkspaceEdit(documents: [
                    LSPDocumentEdits(
                        uri: "file:///private/tmp/PisakaRouting/pkg/from-the-index.swift",
                        edits: [
                            LSPTextEdit(
                                range: LSPRange(
                                    start: LSPPosition(line: 0, character: 0),
                                    end: LSPPosition(line: 0, character: 7)
                                ),
                                newText: request.newName
                            ),
                        ]
                    ),
                ])
            )
        }

        func definitions(for request: DefinitionRequest) async -> [DefinitionCandidate] {
            await wrapped.definitions(for: request)
        }

        func completions(for request: CompletionRequest) async -> [CompletionItem] {
            await wrapped.completions(for: request)
        }

        func hover(for request: HoverRequest) async -> HoverAnswer? {
            hoverCalls += 1
            // Force-unwrapped deliberately: a literal segment cannot normalize
            // away, and a `nil` here would silently make the assertion vacuous.
            return HoverAnswer(
                content: HoverContent(segments: [.prose("from the index")])!,
                range: NSRange(location: 0, length: 1)
            )
        }
    }

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
            ),
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
        sessionBudgets: LSPSession.Budgets = RoutingIntelligenceProviderTests.patientSession,
        fallback: (any CodeIntelligenceProviding)? = nil
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
            fallback: fallback ?? makeFallback(index),
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
                    "end": .object(["line": .int(0), "character": .int(21)]),
                ]),
            ]),
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
            "insertTextFormat": .int(1),
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

    // MARK: - Hover: the server or nothing

    private func hoverRequest() -> HoverRequest {
        HoverRequest(fileURL: mainFile, offset: greeterReference, text: mainSource)
    }

    /// The server's answer to `textDocument/hover`: a `MarkedString` naming the
    /// language, over the `Greeter` reference on line 2.
    private func serverHoverReply() -> JSONValue {
        .object([
            "contents": .array([
                .object([
                    "language": .string("swift"),
                    "value": .string("public struct Greeter"),
                ]),
            ]),
            "range": .object([
                "start": .object(["line": .int(2), "character": .int(14)]),
                "end": .object(["line": .int(2), "character": .int(21)]),
            ]),
        ])
    }

    func testALiveServerAnswersTheHover() async throws {
        transport.script(LSPMethod.hover, .reply(serverHoverReply()))
        let router = makeRouter(index: makeIndex())

        let hovered = await router.hover(for: hoverRequest())

        let answer = try XCTUnwrap(hovered)
        XCTAssertEqual(answer.content.segments, [.code("public struct Greeter", language: "swift")])
        XCTAssertEqual((mainSource as NSString).substring(with: answer.range), "Greeter")
        XCTAssertEqual(harness.launches, 1)
    }

    /// The rule this layer states for hover and for nothing else: the wrapped
    /// provider is **never** consulted, because tree-sitter knows names and not
    /// types. A server with nothing to say is the end of the question.
    func testAServerWithNothingToSayIsNotFollowedByTheIndex() async {
        transport.script(LSPMethod.hover, .reply(.null))
        let fallback = AnsweringFallback(makeFallback(makeIndex()))
        let router = makeRouter(index: makeIndex(), fallback: fallback)

        let answer = await router.hover(for: hoverRequest())

        XCTAssertNil(answer)
        XCTAssertEqual(transport.requests(for: LSPMethod.hover).count, 1)
        XCTAssertEqual(fallback.hoverCalls, 0, "hover has no fallback")
    }

    /// A language nothing serves costs one function call and never enters the LSP
    /// stack — the same `canServe` gate the other requests take, before the budget
    /// is spent.
    func testAHoverForALanguageWithNoServerNeverEntersTheStack() async {
        transport.script(LSPMethod.hover, .reply(serverHoverReply()))
        let fallback = AnsweringFallback(makeFallback(makeIndex()))
        let router = makeRouter(index: makeIndex(), registry: .empty, fallback: fallback)

        let answer = await router.hover(for: hoverRequest())

        XCTAssertNil(answer)
        XCTAssertEqual(harness.launches, 0)
        XCTAssertTrue(transport.sentMethods.isEmpty)
        XCTAssertEqual(fallback.hoverCalls, 0)
    }

    /// A server that does not answer in time shows nothing, and the abandoned
    /// question is withdrawn rather than left running — the same race, on hover's
    /// own budget.
    func testAHoverTimeoutShowsNothingAndCancelsTheRequest() async {
        transport.script(LSPMethod.hover, .drop)
        // The other three budgets are set far past this test's own runtime, so
        // the elapsed-time assertion is what pins *which* budget the whole-attempt
        // race is run against — without it, reading `completion`'s or
        // `definition`'s would pass this test unchanged.
        let router = makeRouter(
            index: makeIndex(),
            budgets: RoutingIntelligenceProvider.Budgets(
                definition: 30,
                completion: 30,
                resolve: 30,
                hover: 0.05
            )
        )

        let started = Date()
        let answer = await router.hover(for: hoverRequest())

        XCTAssertNil(answer)
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 2,
            "the hover attempt was raced against a budget other than its own"
        )
        XCTAssertEqual(transport.requests(for: LSPMethod.hover).count, 1)
        await untilTrue("the abandoned hover is cancelled") {
            self.transport.notifications(for: LSPMethod.cancelRequest).count == 1
        }
    }

    /// The acceptance criterion: D7's restart budget is spent by *hover* requests
    /// like any other, and once a `(server, root)` has been given up on, hovering
    /// asks nothing at all — no launch, no process, no cost per pointer stop.
    func testFourFailedLaunchesDrivenByHoverRetireTheKey() async {
        harness.launchError = .launchFailed("sourcekit-lsp not found")
        let router = makeRouter(index: makeIndex())

        for _ in 1...4 {
            let answer = await router.hover(for: hoverRequest())
            XCTAssertNil(answer)
        }
        XCTAssertEqual(harness.launches, 4)
        XCTAssertEqual(recordedDelays, LSPWorkspace.backoffDelays)

        let afterwards = await router.hover(for: hoverRequest())
        XCTAssertNil(afterwards)
        XCTAssertEqual(harness.launches, 4, "a server given up on is never launched again")
        // And the retirement is the key's, not hover's: the other requests are
        // answered by the index from here on, exactly as they are when the four
        // failures came from ⌘-clicks.
        let candidates = await router.definitions(for: definitionRequest())
        XCTAssertEqual(candidates.map(\.relativePath), ["Sources/Legacy/Greeter.swift"])
        XCTAssertEqual(harness.launches, 4)
    }

    // MARK: - Usages and rename: the server or nothing

    private func usagesRequest(text: String? = nil) -> UsagesRequest {
        UsagesRequest(
            identifier: "Greeter",
            fileURL: mainFile,
            offset: greeterReference,
            text: text ?? mainSource
        )
    }

    private func renameRequest(newName: String = "Welcomer") -> RenameRequest {
        RenameRequest(
            identifier: "Greeter",
            fileURL: mainFile,
            offset: greeterReference,
            text: mainSource,
            newName: newName
        )
    }

    /// The server's answer: the declaration in `Greeter.swift` plus the use on
    /// line 2 of `main.swift`, which is the file the question came from.
    private func serverReferencesReply() -> JSONValue {
        .array([
            .object([
                "uri": .string(LSPWorkspace.documentURI(for: serverFile)),
                "range": .object([
                    "start": .object(["line": .int(0), "character": .int(14)]),
                    "end": .object(["line": .int(0), "character": .int(21)]),
                ]),
            ]),
            .object([
                "uri": .string(LSPWorkspace.documentURI(for: mainFile)),
                "range": .object([
                    "start": .object(["line": .int(2), "character": .int(14)]),
                    "end": .object(["line": .int(2), "character": .int(21)]),
                ]),
            ]),
        ])
    }

    private func serverRenameReply() -> JSONValue {
        .object([
            "changes": .object([
                LSPWorkspace.documentURI(for: serverFile): .array([
                    .object([
                        "newText": .string("Welcomer"),
                        "range": .object([
                            "start": .object(["line": .int(0), "character": .int(14)]),
                            "end": .object(["line": .int(0), "character": .int(21)]),
                        ]),
                    ]),
                ]),
            ]),
        ])
    }

    func testALiveServerAnswersTheUsagesAndTheIndexIsNotConsulted() async throws {
        transport.script(LSPMethod.references, .reply(serverReferencesReply()))
        let fallback = AnsweringFallback(makeFallback(makeIndex()))
        let router = makeRouter(index: makeIndex(), fallback: fallback)

        let usages = await router.references(for: usagesRequest())

        XCTAssertEqual(usages.map(\.relativePath), [
            "Sources/Core/Greeter.swift",
            "Sources/App/main.swift",
        ])
        // Every row is a resolved reference — the flag is what the panel says out
        // loud, so a semantic answer that claimed to be textual would be a lie in
        // the safe direction and still a lie.
        XCTAssertEqual(usages.map(\.isTextual), [false, false])
        XCTAssertEqual(fallback.referencesCalls, 0, "references has no provider fallback")
        XCTAssertEqual(harness.launches, 1)
    }

    func testALiveServerAnswersTheRenameAndTheIndexIsNotConsulted() async throws {
        transport.script(LSPMethod.rename, .reply(serverRenameReply()))
        let fallback = AnsweringFallback(makeFallback(makeIndex()))
        let router = makeRouter(index: makeIndex(), fallback: fallback)

        let renamed = await router.renameEdits(for: renameRequest())
        let answer = try XCTUnwrap(renamed)

        XCTAssertEqual(answer.newName, "Welcomer")
        XCTAssertEqual(answer.edit.documents.count, 1)
        XCTAssertEqual(answer.edit.documents.first?.edits.map(\.newText), ["Welcomer"])
        XCTAssertEqual(fallback.renameCalls, 0, "rename has no fallback at all")
    }

    /// The rule this layer states for both new questions: a server with nothing to
    /// say ends them. For rename that is the whole story; for usages it is only
    /// this layer's half — the honest second answer is a project walk, and that is
    /// `FindUsagesModel`'s to run, not a provider's (decision 1).
    func testAServerWithNothingToSayIsNotFollowedByTheIndexForEitherQuestion() async {
        transport.script(LSPMethod.references, .reply(.null))
        transport.script(LSPMethod.rename, .reply(.null))
        let fallback = AnsweringFallback(makeFallback(makeIndex()))
        let router = makeRouter(index: makeIndex(), fallback: fallback)

        let usages = await router.references(for: usagesRequest())
        let renamed = await router.renameEdits(for: renameRequest())

        XCTAssertTrue(usages.isEmpty)
        XCTAssertNil(renamed)
        XCTAssertEqual(transport.requests(for: LSPMethod.references).count, 1)
        XCTAssertEqual(transport.requests(for: LSPMethod.rename).count, 1)
        XCTAssertEqual(fallback.referencesCalls, 0)
        XCTAssertEqual(fallback.renameCalls, 0)
    }

    /// A language nothing serves never enters the LSP stack, for these two exactly
    /// as for the other four — and the answers are the *untouched* ones: an empty
    /// list and no rename, equal to what a provider that implements neither
    /// returns, rather than to what the probe underneath would have said.
    func testUsagesAndRenameForALanguageWithNoServerNeverEnterTheStack() async {
        transport.script(LSPMethod.references, .reply(serverReferencesReply()))
        transport.script(LSPMethod.rename, .reply(serverRenameReply()))
        let fallback = AnsweringFallback(makeFallback(makeIndex()))
        let router = makeRouter(index: makeIndex(), registry: .empty, fallback: fallback)

        let usages = await router.references(for: usagesRequest())
        let renamed = await router.renameEdits(for: renameRequest())

        XCTAssertTrue(usages.isEmpty)
        XCTAssertNil(renamed)
        XCTAssertEqual(harness.launches, 0)
        XCTAssertTrue(transport.sentMethods.isEmpty)
        XCTAssertEqual(fallback.referencesCalls, 0)
        XCTAssertEqual(fallback.renameCalls, 0)
        // And the command asks the same question before it would show a dialog:
        // free, and `false` for a language nothing serves.
        let offered = await router.canRename(.swift)
        XCTAssertFalse(offered)
        XCTAssertEqual(harness.launches, 0)
    }

    /// A server that does not answer in time answers nothing — raced against
    /// `references`' own budget rather than a definition's or a hover's.
    func testATimeoutOnUsagesAnswersNothingAndCancelsTheRequest() async {
        transport.script(LSPMethod.references, .drop)
        // Every other span — rename's included — is set far past this test's own
        // runtime, so the elapsed assertion pins *which* budget the whole-attempt
        // race is run against.
        let router = makeRouter(
            index: makeIndex(),
            budgets: RoutingIntelligenceProvider.Budgets(
                definition: 30,
                completion: 30,
                resolve: 30,
                hover: 30,
                references: 0.05,
                rename: 30
            )
        )

        let started = Date()
        let usages = await router.references(for: usagesRequest())

        XCTAssertTrue(usages.isEmpty)
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 2,
            "the attempt was raced against a budget other than its own"
        )
        await untilTrue("the abandoned question is cancelled") {
            self.transport.notifications(for: LSPMethod.cancelRequest).count == 1
        }
    }

    /// **Rename is raced against a budget of its own, not `references`'.**
    ///
    /// The two are the same act asked two ways, but only one of them has a second
    /// answer behind it: a references timeout degrades to `FindUsagesModel`'s
    /// textual walk, while a rename timeout is a bare refusal of a command the
    /// user has already filled in a modal dialog for. Asserted the same way round
    /// — rename's span is the small one here and `references`' is wide, so a
    /// router still sharing one number would overrun.
    func testATimeoutOnRenameAnswersNothingAndCancelsTheRequest() async {
        transport.script(LSPMethod.rename, .drop)
        let router = makeRouter(
            index: makeIndex(),
            budgets: RoutingIntelligenceProvider.Budgets(
                definition: 30,
                completion: 30,
                resolve: 30,
                hover: 30,
                references: 30,
                rename: 0.05
            )
        )

        let started = Date()
        let renamed = await router.renameEdits(for: renameRequest())

        XCTAssertNil(renamed)
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 2,
            "the attempt was raced against a budget other than its own"
        )
        await untilTrue("the abandoned question is cancelled") {
            self.transport.notifications(for: LSPMethod.cancelRequest).count == 1
        }
    }

    /// The default table gives rename materially more room than every reading
    /// question, which is the whole point of splitting it out.
    func testTheDefaultRenameBudgetIsWiderThanTheReadingBudgets() {
        let standard = RoutingIntelligenceProvider.Budgets.standard
        XCTAssertGreaterThan(standard.rename, standard.references)
        XCTAssertGreaterThan(standard.rename, standard.definition)
        XCTAssertGreaterThanOrEqual(standard.rename, 15)
    }

    /// `canRename` is the free policy answer the command asks before it puts a
    /// dialog on screen (decision 4): `true` where a server serves the language,
    /// and asking it starts nothing.
    func testCanRenameIsTrueForAServedLanguageAndStartsNothing() async {
        let router = makeRouter(index: makeIndex())

        let offered = await router.canRename(.swift)

        XCTAssertTrue(offered)
        XCTAssertEqual(harness.launches, 0, "a policy answer starts no process")
        XCTAssertTrue(transport.sentMethods.isEmpty)
    }

    // MARK: - Waiting

    /// Poll `condition` until it holds, or fail after `timeout` seconds.
    ///
    /// The honest shape for asserting on work this layer runs *unstructured*: the
    /// router hands the caller its answer and lets the loser unwind on its own, so
    /// "the cancellation reached the wire" and "the handshake finished" are things
    /// that become true shortly afterwards rather than at a moment a test can name.
    /// A fixed `Task.sleep` in their place is a bet on how busy the machine is, and
    /// this class lost that bet whenever the case before it left work running.
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
        // The server was asked, and then told to stop.
        //
        // **Waited for rather than asserted outright.** `withBudget` says so in as
        // many words: the losing racer is an unstructured task, so by the time the
        // caller sees the fallback the cancellation is *scheduled* and not yet
        // written to the wire. Asserting it synchronously is a race against the
        // cooperative pool that this class loses whenever the case before it left
        // work running — which is exactly why it passed alone and failed with its
        // own suite. What is under test is that the question is withdrawn at all;
        // that it is withdrawn within a beat of the fallback is the strongest
        // statement the implementation actually makes.
        XCTAssertEqual(transport.requests(for: LSPMethod.definition).count, 1)
        await untilTrue("the abandoned definition is cancelled") {
            self.transport.notifications(for: LSPMethod.cancelRequest).count == 1
        }
        let cancelled = transport.notifications(for: LSPMethod.cancelRequest)
            .first?.params?["id"]?.intValue
        XCTAssertEqual(
            transport.requests(for: LSPMethod.definition).first?.id,
            cancelled.map(LSPRequestID.number)
        )
    }

    /// The cold-start promise: a server that is still *starting* costs the
    /// router's budget, not the handshake's.
    ///
    /// The load-bearing case of the whole layer, and the one a task group could
    /// not keep: waiting for a launch in flight is `await Task.value` on a
    /// non-throwing task, which ignores cancellation, so a group's implicit drain
    /// held the caller until sourcekit-lsp had resolved the build system — up to
    /// twenty seconds of a ⌘-click that answered nothing at all, where the index
    /// had the answer in hand the whole time.
    func testAServerStillStartingFallsBackWithinTheBudgetRatherThanWaitingItOut() async {
        transport.script(
            LSPMethod.initialize,
            .reply(ScriptedLSPTransport.initializeResult(), after: 1)
        )
        transport.script(LSPMethod.definition, .reply(serverDefinitionReply()))
        let router = makeRouter(
            index: makeIndex(),
            budgets: RoutingIntelligenceProvider.Budgets(definition: 0.05)
        )

        let started = Date()
        let candidates = await router.definitions(for: definitionRequest())
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(candidates.map(\.relativePath), ["Sources/Legacy/Greeter.swift"])
        // Asserted by *content* rather than by the stopwatch alone: the answer
        // arrived while `initialize` was still the only thing on the wire, i.e.
        // before the handshake this attempt gave up on could possibly have
        // finished. A run that waited it out would have sent `initialized` and a
        // `didOpen` by now.
        XCTAssertEqual(transport.sentMethods, [LSPMethod.initialize])
        XCTAssertLessThan(elapsed, 0.5, "the budget bounds the whole attempt, handshake included")

        // And abandoning the attempt did not abandon the launch: it is an
        // unstructured task the workspace owns, so the next jump is semantic.
        // Waited for rather than slept through: the scripted `initialize` reply is
        // a second of wall clock, and a fixed sleep only a little longer than that
        // is a bet on the machine being idle.
        await untilTrue("the handshake the abandoned attempt started completes") {
            self.transport.sentMethods.contains(LSPMethod.initialized)
        }
        let afterwards = await router.definitions(for: definitionRequest())
        XCTAssertEqual(afterwards.map(\.relativePath), ["Sources/Core/Greeter.swift"])
        XCTAssertEqual(harness.launches, 1, "the server was started once and kept")
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
                    "data": .object(["itemId": .int(7)]),
                ]),
            ]),
        ])))
        transport.script(LSPMethod.resolveCompletionItem, .reply(.object([
            "label": .string("Greeter"),
            "insertText": .string("Greeter"),
            "additionalTextEdits": .array([
                .object([
                    "newText": .string("import Core\n"),
                    "range": .object([
                        "start": .object(["line": .int(0), "character": .int(0)]),
                        "end": .object(["line": .int(0), "character": .int(0)]),
                    ]),
                ]),
            ]),
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

    // MARK: - The provisioned languages (phase 2b)

    /// Phase 2b can add entries to the registry at runtime, which makes the 2a
    /// promise above a moving target: the set of languages that route to a server
    /// is no longer fixed at build time. So the promise is re-stated here in the
    /// two forms that can now break.
    ///
    /// **Nothing installed changes nothing.** A `.ts` or `.py` file on a machine
    /// where no server has been provisioned must answer *the bare index
    /// provider's* answer, and a `.swift` file must still reach sourcekit-lsp —
    /// asserted by equality and by the launch counter rather than by reading the
    /// candidates, because a downloadable entry that leaked into the base registry
    /// would produce answers that still look plausible.
    ///
    /// **An install is scoped to its own languages.** Provisioning pyright must
    /// leave a TypeScript answer and a Swift answer byte-identical to what they
    /// were before it, which is the property that makes "one more manifest record"
    /// a safe way to add the tenth server.

    private var typescriptFile: URL { root.appendingPathComponent("src/app.ts") }
    private var pythonFile: URL { root.appendingPathComponent("src/app.py") }
    private var typescriptDeclarationFile: URL { root.appendingPathComponent("src/greeter.ts") }
    private var pythonDeclarationFile: URL { root.appendingPathComponent("src/greeter.py") }

    private let typescriptSource = "const greeter = new TSGreeter()"
    private let pythonSource = "greeter = PyGreeter()"

    /// An index of a project written in the two downloadable languages, so the
    /// fallback's answers are about the language under test rather than about
    /// Swift. Deliberately *not* `makeIndex()`: the names are distinct per
    /// language, so a candidate can only have come from the file it belongs to.
    private func makeProvisionedLanguagesIndex() -> SymbolIndex {
        var index = SymbolIndex()
        index.replace(fileURL: typescriptDeclarationFile, symbols: [
            Symbol(
                name: "TSGreeter",
                kind: .type,
                range: NSRange(location: 13, length: 9),
                fileURL: typescriptDeclarationFile,
                line: 1
            ),
        ])
        index.replace(fileURL: pythonDeclarationFile, symbols: [
            Symbol(
                name: "PyGreeter",
                kind: .type,
                range: NSRange(location: 6, length: 9),
                fileURL: pythonDeclarationFile,
                line: 1
            ),
        ])
        return index
    }

    private func typescriptDefinitionRequest() -> DefinitionRequest {
        DefinitionRequest(
            identifier: "TSGreeter",
            fileURL: typescriptFile,
            offset: (typescriptSource as NSString).range(of: "TSGreeter()").location,
            text: typescriptSource
        )
    }

    private func pythonDefinitionRequest() -> DefinitionRequest {
        DefinitionRequest(
            identifier: "PyGreeter",
            fileURL: pythonFile,
            offset: (pythonSource as NSString).range(of: "PyGreeter()").location,
            text: pythonSource
        )
    }

    private func typescriptCompletionRequest() -> CompletionRequest {
        CompletionRequest(
            prefix: "TSGre",
            fileURL: typescriptFile,
            text: typescriptSource,
            language: .typescript,
            offset: (typescriptSource as NSString).range(of: "TSGreeter()").location + 5
        )
    }

    private func pythonCompletionRequest() -> CompletionRequest {
        CompletionRequest(
            prefix: "PyGre",
            fileURL: pythonFile,
            text: pythonSource,
            language: .python,
            offset: (pythonSource as NSString).range(of: "PyGreeter()").location + 5
        )
    }

    /// The registry `LSPProvisioningModel` publishes once `server` is installed,
    /// built the way the model builds it: the base, plus the manifest's own
    /// description. The shipped manifest and a made-up install root, because the
    /// description is pure path math and nothing here starts anything.
    private func registryInstalling(_ server: LSPDownloadableServer) throws -> LSPServerRegistry {
        let layout = LSPInstallLayout(
            base: URL(fileURLWithPath: "/private/tmp/PisakaRouting/LanguageServers", isDirectory: true)
        )
        let description = try XCTUnwrap(
            server.serverDescription(manifest: .standard, layout: layout)
        )
        return LSPServerRegistry(LSPServerRegistry.standard.descriptions + [description])
    }

    func testWithNothingProvisionedTheDownloadableLanguagesEqualTheBareIndexProvidersOutput() async {
        transport.script(LSPMethod.definition, .reply(serverDefinitionReply()))
        let index = makeProvisionedLanguagesIndex()
        // `.standard` is the registry of a machine that has provisioned nothing:
        // sourcekit-lsp and no more.
        let router = makeRouter(index: index)
        let bare = makeFallback(index)

        for request in [typescriptDefinitionRequest(), pythonDefinitionRequest()] {
            let routed = await router.definitions(for: request)
            let expected = await bare.definitions(for: request)
            XCTAssertEqual(routed, expected, "\(request.identifier)")
            XCTAssertFalse(routed.isEmpty, "\(request.identifier)")
        }
        for request in [typescriptCompletionRequest(), pythonCompletionRequest()] {
            let routed = await router.completions(for: request)
            let expected = await bare.completions(for: request)
            XCTAssertEqual(routed, expected, "\(request.prefix)")
            XCTAssertFalse(routed.isEmpty, "\(request.prefix)")
        }

        // Not equal by luck: neither language entered the LSP stack at all.
        XCTAssertEqual(harness.launches, 0)
        XCTAssertTrue(transport.sentMethods.isEmpty)

        // And 2a's one language is untouched by their presence in the enum.
        let swift = await router.definitions(for: definitionRequest())
        XCTAssertEqual(swift.map(\.relativePath), ["Sources/Core/Greeter.swift"])
        XCTAssertEqual(harness.launches, 1)
    }

    func testInstallingThePythonServerLeavesTypeScriptAndSwiftByteIdentical() async throws {
        try await assertInstallingChangesNothingElse(
            .python,
            definition: typescriptDefinitionRequest(),
            completion: typescriptCompletionRequest()
        )
    }

    func testInstallingTheTypeScriptServerLeavesPythonAndSwiftByteIdentical() async throws {
        try await assertInstallingChangesNothingElse(
            .typescript,
            definition: pythonDefinitionRequest(),
            completion: pythonCompletionRequest()
        )
    }

    /// Install `server`, and assert that a language it does *not* serve — plus
    /// Swift — answers exactly what it answered before.
    ///
    /// Staged as two routers over two `Harness`es rather than one router whose
    /// registry is swapped: the point is a whole editor run with the server
    /// provisioned, and a fresh harness is what makes the launch counter mean
    /// "this run started one server" rather than "two runs started two".
    private func assertInstallingChangesNothingElse(
        _ server: LSPDownloadableServer,
        definition: DefinitionRequest,
        completion: CompletionRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let index = makeProvisionedLanguagesIndex()

        transport.script(LSPMethod.definition, .reply(serverDefinitionReply()))
        let before = makeRouter(index: index)
        let swiftBefore = await before.definitions(for: definitionRequest())
        let definitionsBefore = await before.definitions(for: definition)
        let completionsBefore = await before.completions(for: completion)
        XCTAssertEqual(harness.launches, 1, file: file, line: line)

        // The next run of the editor, with the server on disk and registered.
        harness = Harness()
        transport.script(LSPMethod.definition, .reply(serverDefinitionReply()))
        let registry = try registryInstalling(server)
        for language in server.languages {
            XCTAssertTrue(registry.servesLanguage(language), "\(language)", file: file, line: line)
        }
        let after = makeRouter(index: index, registry: registry)

        let swiftAfter = await after.definitions(for: definitionRequest())
        let definitionsAfter = await after.definitions(for: definition)
        let completionsAfter = await after.completions(for: completion)
        let bare = makeFallback(index)
        let bareDefinitions = await bare.definitions(for: definition)
        let bareCompletions = await bare.completions(for: completion)

        // Swift still reaches sourcekit-lsp, and reaches it with the same answer.
        XCTAssertEqual(swiftAfter, swiftBefore, file: file, line: line)
        XCTAssertEqual(
            swiftAfter.map(\.relativePath),
            ["Sources/Core/Greeter.swift"],
            file: file,
            line: line
        )
        XCTAssertEqual(registry.description(for: .swift), .sourcekitLSP, file: file, line: line)

        // The other downloadable language is still the bare index provider's,
        // byte for byte — before the install and after it.
        XCTAssertEqual(definitionsAfter, definitionsBefore, file: file, line: line)
        XCTAssertEqual(definitionsAfter, bareDefinitions, file: file, line: line)
        XCTAssertFalse(definitionsAfter.isEmpty, file: file, line: line)
        XCTAssertEqual(completionsAfter, completionsBefore, file: file, line: line)
        XCTAssertEqual(completionsAfter, bareCompletions, file: file, line: line)
        XCTAssertFalse(completionsAfter.isEmpty, file: file, line: line)

        // The Swift request is the only thing that started a server: the
        // unserved language never reached the installed one.
        XCTAssertEqual(harness.launches, 1, file: file, line: line)
    }
}
