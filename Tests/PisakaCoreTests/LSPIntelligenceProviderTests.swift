import XCTest
@testable import PisakaCore

/// The layer that turns a language server's answers into what the editor shows:
/// candidates with buffer ranges and gutter line numbers, completion items with
/// the server's own ranking and D4's edits.
///
/// Every case drives a real `LSPWorkspace`/`LSPSession` over a
/// `ScriptedLSPTransport` whose replies are the **recorded** sourcekit-lsp
/// transcripts in `Fixtures/LSP/` (provenance in that directory's README). So the
/// decoding, the position mapping and the ranking are all exercised against
/// output a real server produced, without `swift test` ever spawning one. The few
/// shapes that server never emitted — an item whose `textEdit` reaches past the
/// typed prefix, two items tied on `sortText`, a duplicate — are written inline
/// and say so.
///
/// The file texts are supplied through the provider's `loadText` seam rather than
/// written to disk: a definition answer points at files the test does not own
/// (another module's source, an SDK interface under `/var/folders`), and faking
/// the read is what keeps the suite offline and instant.
@MainActor
final class LSPIntelligenceProviderTests: XCTestCase {

    // MARK: - Fixtures

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private static let fixtures = repositoryRoot
        .appendingPathComponent("Tests/PisakaCoreTests/Fixtures/LSP")

    /// The `result` member of a recorded response envelope — what the scripted
    /// server replies with.
    private func fixtureResult(_ name: String) throws -> JSONValue {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
        let message = try LSPIncomingMessage.decode(data)
        guard case .response(let response) = message else {
            throw XCTSkip("\(name) is not a response")
        }
        return response.result ?? .null
    }

    // MARK: - The recorded project

    /// The root the fixtures' URIs point into, spelled the way the server wrote
    /// it — `/private/tmp`, resolved out of `/tmp`, which is exactly the case a
    /// lexical relative-path strip gets wrong.
    private let root = URL(fileURLWithPath: "/private/tmp/lspfix/pkg", isDirectory: true)
    /// The folder the user switches to mid-request.
    private let otherRoot = URL(fileURLWithPath: "/private/tmp/lspfix/other", isDirectory: true)

    private var mainFile: URL { root.appendingPathComponent("Sources/App/main.swift") }
    private var greeterFile: URL { root.appendingPathComponent("Sources/Core/Greeter.swift") }

    /// The recorded `main.swift`.
    private let mainSource = """
        import Core
        import Foundation

        let greeter = Greeter()
        let message = greeter.greet("world")
        print(message)
        """

    /// The same file mid-keystroke: `Gree` typed on line 3, a bare dot on line 4
    /// — the two positions every recorded completion fixture was captured at.
    private let typingSource = """
        import Core
        import Foundation

        let greeter = Gree
        let message = greeter.
        print(message)
        """

    /// Caret at the end of `Gree` on line 3 (offset 49 in `typingSource`).
    private var identifierCaret: Int { (typingSource as NSString).range(of: "Gree\n").location + 4 }
    /// Caret just after the dot on line 4.
    private var memberCaret: Int { (typingSource as NSString).range(of: "greeter.\n").location + 8 }
    /// Where `Greeter` is referenced on line 3 of `mainSource`.
    private var greeterReference: Int { (mainSource as NSString).range(of: "Greeter()").location }

    /// The recorded `Greeter.swift`, whose line numbering every definition
    /// fixture points into.
    private let greeterSource = """
        /// A greeter used by the recorded LSP fixtures.
        public struct Greeter {
            public let salutation: String

            public init(salutation: String = "Hello") {
                self.salutation = salutation
            }

            public func greet(_ name: String) -> String {
                "\\(salutation), \\(name)!"
            }
        }
        """

    /// The generated interface `definition-sdk.json` points at, long enough for
    /// its line 18545 to exist.
    private let sdkPath = "/var/folders/xq/wbrh3j0n07162c6gymb3f_bm0000gn/T/sourcekit-lsp"
        + "/GeneratedInterfaces/3496602203573370090/Swift.String.swiftinterface"

    // MARK: - Harness

    /// One scripted server, plus a count of how many times a launch was asked
    /// for — the assertion behind "nothing was sent".
    private final class Harness {
        let transport = ScriptedLSPTransport()
        private(set) var launches = 0

        init() {
            transport.script(LSPMethod.initialize, .reply(ScriptedLSPTransport.initializeResult()))
            transport.script(LSPMethod.shutdown, .reply(.null))
        }

        func makeTransport(_ description: LSPServerDescription, _ root: URL) -> LSPTransport {
            launches += 1
            return transport
        }
    }

    /// Short enough that a wedged test fails in a second.
    private static let quick = LSPSession.Budgets(
        handshake: 1,
        definition: 1,
        completion: 1,
        resolve: 1,
        shutdown: 1
    )

    private var harness = Harness()

    private var transport: ScriptedLSPTransport { harness.transport }

    /// The workspace the last `makeProvider` built. The provider keeps its own
    /// private — deliberately, so nothing above the seam can reach past it — which
    /// leaves a test no other way to stage a *second* request against the same
    /// document while the first one's question is outstanding.
    private var lastWorkspace: LSPWorkspace?

    override func setUp() {
        super.setUp()
        harness = Harness()
        lastWorkspace = nil
    }

    private func makeWorkspace(root: URL? = nil) -> LSPWorkspace {
        let harness = self.harness
        let workspace = LSPWorkspace(
            budgets: Self.quick,
            processID: 4242,
            transportFactory: { description, launchRoot in
                harness.makeTransport(description, launchRoot)
            }
        )
        workspace.prepareForFolderChange(root: root ?? self.root)
        return workspace
    }

    /// A provider whose target files are `files`, keyed by path.
    ///
    /// Both sides of the lookup are canonicalized, for the reason the recorded
    /// URIs exist at all: `/tmp` and `/private/tmp` are the same directory, and a
    /// fake that matched them by raw string would fail on the very paths this
    /// server really answers with.
    private func makeProvider(
        files: [String: String] = [:],
        completionLimit: Int = SymbolIntelligenceProvider.defaultCompletionLimit,
        root: URL? = nil
    ) -> LSPIntelligenceProvider {
        let canonical = Dictionary(
            files.map { (CanonicalPath.canonical(URL(fileURLWithPath: $0.key)).path, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        let workspace = makeWorkspace(root: root)
        lastWorkspace = workspace
        return LSPIntelligenceProvider(
            workspace: workspace,
            completionLimit: completionLimit,
            loadText: { canonical[CanonicalPath.canonical($0).path] }
        )
    }

    private func completionRequest(
        prefix: String,
        offset: Int?,
        member: IdentifierScanner.MemberContext? = nil
    ) -> CompletionRequest {
        CompletionRequest(
            prefix: prefix,
            fileURL: mainFile,
            text: typingSource,
            language: .swift,
            member: member,
            offset: offset
        )
    }

    // MARK: - Definitions

    func testACrossModuleDefinitionBecomesCandidatesInTheOtherModulesFile() async throws {
        transport.script(LSPMethod.definition, .reply(try fixtureResult("definition-cross-module.json")))
        let provider = makeProvider(files: [greeterFile.path: greeterSource])

        let candidates = await provider.definitions(
            for: DefinitionRequest(
                identifier: "Greeter",
                fileURL: mainFile,
                offset: greeterReference,
                text: mainSource
            )
        )

        // The recorded answer is two locations in one file: the type and its
        // memberwise initializer, in the server's own order.
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates.map(\.relativePath), [
            "Sources/Core/Greeter.swift",
            "Sources/Core/Greeter.swift"
        ])
        XCTAssertEqual(candidates.map(\.isOutsideProjectRoot), [false, false])
        // 1-based display lines, derived from the offsets with `LineStartIndex`
        // (D1) rather than from the server's zero-based numbering.
        XCTAssertEqual(candidates.map(\.line), [2, 5])
        XCTAssertEqual(candidates.map(\.name), ["Greeter", "Greeter"])
        // A location carries no declaration kind — the server was asked "where".
        XCTAssertEqual(candidates.compactMap(\.kind).count, 0)

        let source = greeterSource as NSString
        XCTAssertTrue(source.substring(from: candidates[0].range.location).hasPrefix("Greeter {"))
        XCTAssertTrue(source.substring(from: candidates[1].range.location).hasPrefix("init(salutation"))
        XCTAssertEqual(candidates.map(\.displayLabel), [
            "Greeter — Sources/Core/Greeter.swift:2",
            "Greeter — Sources/Core/Greeter.swift:5"
        ])
    }

    /// An answer computed against a document the server was talked *out of* while
    /// the question was outstanding is dropped, not mapped.
    ///
    /// `LSPWorkspace.prepare` releases the document's flush claim before it returns,
    /// so the flush guarantees the server's text at *prepare* time, not while the
    /// request is in flight. A second request carrying different text — one queued
    /// behind a launch, or one the router abandoned at its deadline and then resumed
    /// — sends its own `didChange` in between, and the locations that come back are
    /// then about a file the caller's buffer does not describe. That is the one
    /// failure this layer cannot afford to paper over: a wrong jump *is* an answer,
    /// so it never falls back, and the user lands somewhere plausible and wrong.
    func testAnAnswerIsDroppedWhenAnotherRequestChangedTheServersDocumentUnderIt() async throws {
        transport.script(
            LSPMethod.definition,
            .reply(try fixtureResult("definition-cross-module.json"), after: 0.2)
        )
        let provider = makeProvider(files: [greeterFile.path: greeterSource])
        let workspace = try XCTUnwrap(lastWorkspace)

        let jumping = Task {
            await provider.definitions(
                for: DefinitionRequest(
                    identifier: "Greeter",
                    fileURL: mainFile,
                    offset: greeterReference,
                    text: mainSource
                )
            )
        }
        // The jump has flushed its buffer and is waiting on the answer; this is the
        // other request arriving with a different one.
        try await Task.sleep(nanoseconds: 40_000_000)
        let interleaved = await workspace.prepare(
            url: mainFile,
            language: .swift,
            text: "// the document the server now holds\n"
        )
        XCTAssertEqual(interleaved?.version, 2, "the staging itself must have moved the server")

        let candidates = await jumping.value
        XCTAssertTrue(
            candidates.isEmpty,
            "an answer about a version the server no longer holds is no answer"
        )
    }

    /// A folder switch while the question is outstanding drops the answer too —
    /// the same gate, for the wider window.
    ///
    /// `LSPWorkspace.prepare` guards both sides of its flush, but the request that
    /// follows is the longest wait in the layer: a server is allowed to take seconds
    /// where a flush takes a write. A switch inside it leaves the document table
    /// untouched until the `shutdownAll()` it *schedules* runs, so the version still
    /// matches and this jump — computed by a server initialized for the folder the
    /// user has just left — would land the user in a closed project.
    func testAnAnswerIsDroppedWhenTheFolderChangedWhileTheQuestionWasOutstanding() async throws {
        transport.script(
            LSPMethod.definition,
            .reply(try fixtureResult("definition-cross-module.json"), after: 0.2)
        )
        let provider = makeProvider(files: [greeterFile.path: greeterSource])
        let workspace = try XCTUnwrap(lastWorkspace)

        let jumping = Task {
            await provider.definitions(
                for: DefinitionRequest(
                    identifier: "Greeter",
                    fileURL: mainFile,
                    offset: greeterReference,
                    text: mainSource
                )
            )
        }
        // The jump has flushed its buffer and is waiting on the answer; this is the
        // user opening another folder. Deliberately without the `shutdownAll()` the
        // app schedules alongside it — that teardown is a turn later, and this
        // window is the turns before it.
        try await Task.sleep(nanoseconds: 40_000_000)
        workspace.prepareForFolderChange(root: otherRoot)

        let candidates = await jumping.value
        XCTAssertTrue(
            candidates.isEmpty,
            "a jump into the folder the user just left is worse than no jump"
        )
    }

    /// The completion half of the same window, and the sharper one: a list's items
    /// carry *edits* in buffer coordinates, so an answer from the previous project's
    /// server does not merely display — it is applied to a file.
    func testACompletionListIsDroppedWhenTheFolderChangedWhileItWasOutstanding() async throws {
        transport.script(
            LSPMethod.completion,
            .reply(try fixtureResult("completion-identifier.json"), after: 0.2)
        )
        let provider = makeProvider()
        let workspace = try XCTUnwrap(lastWorkspace)

        let completing = Task {
            await provider.completions(
                for: self.completionRequest(prefix: "Gree", offset: self.identifierCaret)
            )
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        workspace.prepareForFolderChange(root: otherRoot)

        let items = await completing.value
        XCTAssertTrue(items.isEmpty, "edits from a closed project may not reach the buffer")
    }

    /// The `LocationLink[]` shape: the jump lands on `targetSelectionRange` (the
    /// identifier), not on `targetRange` (the whole declaration, which starts a
    /// line earlier here).
    func testALocationLinkJumpsToTheIdentifierRangeRatherThanTheWholeDeclaration() async throws {
        transport.script(LSPMethod.definition, .reply(try fixtureResult("definition-location-link.json")))
        let provider = makeProvider(files: [greeterFile.path: greeterSource])

        let candidates = await provider.definitions(
            for: DefinitionRequest(
                identifier: "Greeter",
                fileURL: mainFile,
                offset: greeterReference,
                text: mainSource
            )
        )

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidate.line, 2)
        XCTAssertEqual(
            (greeterSource as NSString).substring(with: candidate.range),
            "Greeter"
        )
        XCTAssertFalse(candidate.isOutsideProjectRoot)
    }

    func testAnSDKTargetIsFlaggedAsOutsideTheProjectRoot() async throws {
        transport.script(LSPMethod.definition, .reply(try fixtureResult("definition-sdk.json")))
        // A stand-in long enough that the recorded line 18545 exists in it.
        let interface = String(repeating: "// generated\n", count: 18_545)
            + "    public struct Index : Comparable {\n"
        let provider = makeProvider(files: [sdkPath: interface])

        let candidates = await provider.definitions(
            for: DefinitionRequest(
                identifier: "String",
                fileURL: mainFile,
                offset: greeterReference,
                text: mainSource
            )
        )

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertTrue(candidate.isOutsideProjectRoot)
        // Outside the root there is no relative path to show, only the file name.
        XCTAssertEqual(candidate.relativePath, "Swift.String.swiftinterface")
        XCTAssertEqual(candidate.line, 18_546)
    }

    func testANullDefinitionAnswerYieldsNoCandidates() async throws {
        transport.script(LSPMethod.definition, .reply(try fixtureResult("definition-none.json")))
        let provider = makeProvider(files: [greeterFile.path: greeterSource])

        let candidates = await provider.definitions(
            for: DefinitionRequest(
                identifier: "Greeter",
                fileURL: mainFile,
                offset: greeterReference,
                text: mainSource
            )
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    /// A target whose text cannot be read is dropped rather than approximated:
    /// without the file there is no offset, and every consumer navigates by one.
    func testATargetWhoseFileCannotBeReadIsDropped() async throws {
        transport.script(LSPMethod.definition, .reply(try fixtureResult("definition-cross-module.json")))
        let provider = makeProvider()

        let candidates = await provider.definitions(
            for: DefinitionRequest(
                identifier: "Greeter",
                fileURL: mainFile,
                offset: greeterReference,
                text: mainSource
            )
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    /// A jump *within* the file being edited is mapped against the live buffer,
    /// not against whatever the last save left on disk.
    func testATargetInTheEditedFileIsMappedAgainstTheRequestsOwnBuffer() async throws {
        // Line 3, character 4: `greeter` in `let greeter = Greeter()`.
        transport.script(LSPMethod.definition, .reply(.array([
            .object([
                "uri": .string(LSPWorkspace.documentURI(for: mainFile)),
                "range": .object([
                    "start": .object(["line": .int(3), "character": .int(4)]),
                    "end": .object(["line": .int(3), "character": .int(11)])
                ])
            ])
        ])))
        // Deliberately *not* in the loader: reading it would be the bug.
        let provider = makeProvider()

        let candidates = await provider.definitions(
            for: DefinitionRequest(
                identifier: "greeter",
                fileURL: mainFile,
                offset: greeterReference,
                text: mainSource
            )
        )

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual((mainSource as NSString).substring(with: candidate.range), "greeter")
        XCTAssertEqual(candidate.line, 4)
        XCTAssertEqual(candidate.relativePath, "Sources/App/main.swift")
    }

    // MARK: - The D2 guard

    /// The hazard `DefinitionRequest.text`'s default creates: a call site that
    /// forgets the buffer would otherwise clamp every position to `0:0` and get a
    /// confident, wrong answer — which never falls back, because it *is* an
    /// answer. Nothing is sent, and no server is even started.
    func testAnEmptyBufferWithANonZeroOffsetAsksTheServerNothing() async {
        transport.script(LSPMethod.definition, .reply(.array([])))
        let provider = makeProvider(files: [greeterFile.path: greeterSource])

        let candidates = await provider.definitions(
            for: DefinitionRequest(identifier: "Greeter", fileURL: mainFile, offset: 45)
        )

        XCTAssertTrue(candidates.isEmpty)
        XCTAssertEqual(harness.launches, 0)
        XCTAssertTrue(transport.requests(for: LSPMethod.definition).isEmpty)
    }

    /// A genuinely empty buffer is a legitimate document, and offset 0 is a
    /// legitimate position in it: the guard must not swallow that too.
    func testAnEmptyBufferAtOffsetZeroIsStillAnswerable() async {
        transport.script(LSPMethod.definition, .reply(.array([])))
        let provider = makeProvider()

        _ = await provider.definitions(
            for: DefinitionRequest(identifier: "Greeter", fileURL: mainFile, offset: 0, text: "")
        )

        XCTAssertEqual(harness.launches, 1)
        XCTAssertEqual(transport.requests(for: LSPMethod.definition).count, 1)
    }

    /// The same rule for completion, expressed the way that request can go wrong:
    /// no caret offset means no position, and a position is the whole question.
    func testACompletionRequestWithoutACaretOffsetAsksTheServerNothing() async {
        transport.script(LSPMethod.completion, .reply(.object(["items": .array([])])))
        let provider = makeProvider()

        let items = await provider.completions(for: completionRequest(prefix: "Gree", offset: nil))

        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(harness.launches, 0)
        XCTAssertTrue(transport.requests(for: LSPMethod.completion).isEmpty)
    }

    // MARK: - Completion: the request

    func testAMemberRequestIsSentAsADotTriggerAndAnOrdinaryOneIsNot() async throws {
        transport.script(LSPMethod.completion, .reply(try fixtureResult("completion-member.json")))
        let provider = makeProvider()

        _ = await provider.completions(
            for: completionRequest(
                prefix: "",
                offset: memberCaret,
                member: IdentifierScanner.MemberContext(
                    receiver: "greeter",
                    prefixRange: NSRange(location: memberCaret, length: 0)
                )
            )
        )
        _ = await provider.completions(for: completionRequest(prefix: "Gree", offset: identifierCaret))

        let requests = transport.requests(for: LSPMethod.completion)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].params?["context"]?["triggerKind"]?.intValue, 2)
        XCTAssertEqual(requests[0].params?["context"]?["triggerCharacter"]?.stringValue, ".")
        XCTAssertEqual(requests[0].params?["position"]?["line"]?.intValue, 4)
        XCTAssertEqual(requests[0].params?["position"]?["character"]?.intValue, 22)
        XCTAssertEqual(requests[1].params?["context"]?["triggerKind"]?.intValue, 1)
        XCTAssertNil(requests[1].params?["context"]?["triggerCharacter"])
        XCTAssertEqual(requests[1].params?["position"]?["line"]?.intValue, 3)
        XCTAssertEqual(requests[1].params?["position"]?["character"]?.intValue, 18)
    }

    // MARK: - Completion: ranking and hygiene

    /// The recorded member list, ordered by `sortText`: `salutation`
    /// (`4998.476…`) before `greet` (`4998.547…`) before `self` (`4998.582…`),
    /// which is *not* the order the server sent them in.
    func testMemberCompletionRanksBySortTextAndSpellsEachItemTheSpecsWay() async throws {
        transport.script(LSPMethod.completion, .reply(try fixtureResult("completion-member.json")))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(
                prefix: "",
                offset: memberCaret,
                member: IdentifierScanner.MemberContext(
                    receiver: "greeter",
                    prefixRange: NSRange(location: memberCaret, length: 0)
                )
            )
        )

        // `greet` spells itself three ways — label `greet(name: String)`,
        // filterText `greet(:)`, insertText `greet()` — and what goes in the
        // buffer is the insertText.
        XCTAssertEqual(items.map(\.text), ["salutation", "greet()", "self"])
        XCTAssertEqual(items.map(\.kind), [.property, .method, nil])
        // Every recorded item replaces exactly the range the client typed, so
        // there is nothing for the editor to apply itself: AppKit's own insertion
        // is already right.
        XCTAssertEqual(items.map(\.edits), [[], [], []])
    }

    /// The recorded identifier list puts `Greeter` **last** in the array with the
    /// **lowest** `sortText`, which is why D6 reads the key and never the order.
    func testIdentifierCompletionRanksBySortTextAndNotByArrayOrder() async throws {
        transport.script(LSPMethod.completion, .reply(try fixtureResult("completion-identifier.json")))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(prefix: "Gree", offset: identifierCaret)
        )

        XCTAssertEqual(items.count, 10)
        XCTAssertEqual(items.first?.text, "Greeter")
        XCTAssertEqual(items.first?.kind, .type)
        XCTAssertEqual(items.map(\.text).prefix(3), ["Greeter", "dsGreeting", "kCFStringTransformLatinGreek"])
    }

    func testTheListIsCappedAfterRankingRatherThanBefore() async throws {
        transport.script(LSPMethod.completion, .reply(try fixtureResult("completion-identifier.json")))
        let provider = makeProvider(completionLimit: 3)

        let items = await provider.completions(
            for: completionRequest(prefix: "Gree", offset: identifierCaret)
        )

        // The best three by `sortText` — including the one the server sent last.
        XCTAssertEqual(items.map(\.text), ["Greeter", "dsGreeting", "kCFStringTransformLatinGreek"])
    }

    /// Authored rather than recorded: this server produced no two items with the
    /// same `sortText`, and "preserve the server's order on a tie" is exactly the
    /// rule a non-stable sort would break.
    func testItemsTiedOnSortTextKeepTheServersOwnOrder() async {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array([
                completionItemJSON(label: "beta", sortText: "100"),
                completionItemJSON(label: "alpha", sortText: "100"),
                completionItemJSON(label: "gamma", sortText: "100")
            ])
        ])))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(prefix: "Gree", offset: identifierCaret)
        )

        XCTAssertEqual(items.map(\.text), ["beta", "alpha", "gamma"])
    }

    /// The typed token itself completes to nothing and would hide a real
    /// candidate; a duplicate collapses to its best-ranked spelling.
    func testTheTypedTokenIsDroppedAndDuplicatesCollapseToTheBestRanked() async {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array([
                completionItemJSON(label: "Gree", sortText: "100"),
                completionItemJSON(label: "Greeter", sortText: "300", detail: "second"),
                completionItemJSON(label: "Greeter", sortText: "200", detail: "first"),
                completionItemJSON(label: "Greeting", sortText: "400")
            ])
        ])))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(prefix: "Gree", offset: identifierCaret)
        )

        XCTAssertEqual(items.map(\.text), ["Greeter", "Greeting"])
    }

    /// D5 asks for `snippetSupport: false`, but that is a request the server is
    /// free to ignore — and an item is the one thing in this layer that gets
    /// *written to the file*, so a `${1:…}` placeholder must not reach the buffer
    /// verbatim. Absent means plain text (the spec's default) and is kept.
    func testAnItemClaimingSnippetFormatIsDroppedWhileAnAbsentFormatIsKept() async {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array([
                completionItemJSON(label: "Greeter", sortText: "100", insertTextFormat: nil),
                completionItemJSON(label: "Greeting", sortText: "200", insertTextFormat: 2),
                completionItemJSON(label: "GreeterBox", sortText: "300", insertTextFormat: 1)
            ])
        ])))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(prefix: "Gree", offset: identifierCaret)
        )

        XCTAssertEqual(items.map(\.text), ["Greeter", "GreeterBox"])
    }

    // MARK: - Completion: edits

    /// The auto-import shape (D4): a `textEdit` on the typed word plus an
    /// `import` line inserted *above* it — the case whose caret math is easy to
    /// get wrong, so the plan the editor will apply is asserted too.
    func testAnItemCarryingAnImportProducesBothEditsAndACaretAfterTheSymbol() async throws {
        transport.script(LSPMethod.completion, .reply(try fixtureResult("completion-auto-import.json")))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(prefix: "Gree", offset: identifierCaret)
        )

        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.text, "Greeter")
        XCTAssertEqual(item.edits.count, 2)

        let primary = try XCTUnwrap(item.edits.first { $0.role == .primary })
        let additional = try XCTUnwrap(item.edits.first { $0.role == .additional })
        XCTAssertEqual(primary.newText, "Greeter")
        XCTAssertEqual(primary.range, NSRange(location: identifierCaret - 4, length: 4))
        XCTAssertEqual(additional.newText, "import Core\n")
        // Line 1, character 0 — the start of `import Foundation`.
        XCTAssertEqual(
            additional.range,
            NSRange(location: (typingSource as NSString).range(of: "import Foundation").location, length: 0)
        )
        // Carrying its edits already, it has nothing left to resolve.
        XCTAssertNil(item.resolveHandle)

        let plan = try CompletionEditPlan.make(
            edits: item.edits,
            in: typingSource as NSString,
            replacing: NSRange(location: identifierCaret - 4, length: 4),
            typed: "Gree"
        ).get()
        // Last-to-first, and the caret lands after `Greeter` — shifted by the
        // import inserted above it, never at the import.
        XCTAssertEqual(plan.edits.map(\.role), [.primary, .additional])
        XCTAssertEqual(
            plan.caretOffset,
            identifierCaret - 4 + 7 + ("import Core\n" as NSString).length
        )
    }

    /// A server may choose a range wider than the client's prefix — it decides
    /// what the completion replaces. AppKit's own insertion would get that wrong,
    /// so the item carries its edit instead of degrading to the plain path.
    func testAnItemWhoseEditIsWiderThanTheTypedPrefixCarriesItsOwnEdit() async throws {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array([
                completionItemJSON(
                    label: "Greeter",
                    sortText: "100",
                    // Line 3, characters 13…18: one character further left than
                    // the typed `Gree`.
                    textEdit: (startLine: 3, startCharacter: 13, endLine: 3, endCharacter: 18)
                )
            ])
        ])))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(prefix: "Gree", offset: identifierCaret)
        )

        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.edits.count, 1)
        XCTAssertEqual(item.edits.first?.role, .primary)
        XCTAssertEqual(
            item.edits.first?.range,
            NSRange(location: identifierCaret - 5, length: 5)
        )
        // Wider is allowed; the plan only refuses an edit that reaches *less*
        // far than what was typed.
        XCTAssertNoThrow(
            try CompletionEditPlan.make(
                edits: item.edits,
                in: typingSource as NSString,
                replacing: NSRange(location: identifierCaret - 4, length: 4),
                typed: "Gree"
            ).get()
        )
    }

    // MARK: - Completion: what the row reads

    /// tsserver's member shape, authored rather than recorded (sourcekit-lsp
    /// never sends it): the `textEdit` covers the dot the user typed, so the
    /// item inserts `.greet` and a popup showing the inserted text would read
    /// every row under `greeter.` as `.greet`. The row drops the head that
    /// merely re-writes the dot already standing there; nothing about the edit
    /// moves.
    func testAMemberEditOverTheTypedDotIsDisplayedWithoutIt() async throws {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array([
                completionItemJSON(
                    label: "greet",
                    sortText: "100",
                    // Line 4, characters 21…22: the dot itself.
                    textEdit: (startLine: 4, startCharacter: 21, endLine: 4, endCharacter: 22),
                    textEditNewText: ".greet"
                )
            ])
        ])))
        let provider = makeProvider()
        let typedWord = NSRange(location: memberCaret, length: 0)

        let items = await provider.completions(
            for: completionRequest(
                prefix: "",
                offset: memberCaret,
                member: IdentifierScanner.MemberContext(receiver: "greeter", prefixRange: typedWord)
            )
        )

        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.text, ".greet")
        XCTAssertEqual(item.displayText, "greet")
        // The edit is the item's own, unchanged: the dot is replaced, and what
        // reaches the buffer is byte-identical to what it was before the row
        // learned to read differently.
        let primary = try XCTUnwrap(item.edits.first { $0.role == .primary })
        XCTAssertEqual(item.edits.count, 1)
        XCTAssertEqual(primary.range, NSRange(location: memberCaret - 1, length: 1))
        XCTAssertEqual(primary.newText, ".greet")

        // The safety rule, stated as the assertion it exists for: applying the
        // plan and letting AppKit insert the *displayed* string over the typed
        // word compose the same buffer — which is what makes the preview and the
        // rejected-plan fallback correct rather than merely prettier.
        let plan = try CompletionEditPlan.make(
            edits: item.edits,
            in: typingSource as NSString,
            replacing: typedWord,
            typed: ""
        ).get()
        let planned = NSMutableString(string: typingSource)
        for edit in plan.edits { planned.replaceCharacters(in: edit.range, with: edit.newText) }
        XCTAssertEqual(
            planned as String,
            (typingSource as NSString).replacingCharacters(in: typedWord, with: item.displayText)
        )
        XCTAssertTrue((planned as String).contains("greeter.greet"))
    }

    /// The counter-case over exactly the same range: an optional receiver's
    /// `?.` does not re-write what stands in the buffer — the buffer holds `.`,
    /// the edit writes `?.` — so the row keeps its full spelling and the user
    /// sees the rewrite that is about to happen.
    func testAnOptionalChainMemberEditKeepsItsFullSpellingInTheRow() async throws {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array([
                completionItemJSON(
                    label: "greet",
                    sortText: "100",
                    textEdit: (startLine: 4, startCharacter: 21, endLine: 4, endCharacter: 22),
                    textEditNewText: "?.greet"
                )
            ])
        ])))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(
                prefix: "",
                offset: memberCaret,
                member: IdentifierScanner.MemberContext(
                    receiver: "greeter",
                    prefixRange: NSRange(location: memberCaret, length: 0)
                )
            )
        )

        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.text, "?.greet")
        XCTAssertEqual(item.displayText, "?.greet")
    }

    /// The member the user already finished typing, over tsserver's dot-covering
    /// shape: `inserted` is `".greet"` and so passes the "completes to what is
    /// already typed" guard, but the *row* reads `greet` — the typed word itself.
    ///
    /// It is dropped on the displayed spelling for the same reason the inserted
    /// one is dropped, plus one the caller cannot defend against on its own:
    /// `CompletionController` keys its snapshot by the displayed string and
    /// AppKit hands Esc back through that table spelled as the typed word, so a
    /// row that answers to it turns a cancel into a commit — `import` line
    /// included. The list that comes back is the neighbours only.
    func testAMemberAlreadyTypedInFullIsDroppedOnWhatTheRowWouldRead() async throws {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array([
                completionItemJSON(
                    label: "greet",
                    sortText: "100",
                    // Line 4 of `mainSource`, characters 21…27: the dot the user
                    // typed *and* the whole member name standing after it.
                    textEdit: (startLine: 4, startCharacter: 21, endLine: 4, endCharacter: 27),
                    textEditNewText: ".greet"
                ),
                completionItemJSON(
                    label: "greeting",
                    sortText: "101",
                    textEdit: (startLine: 4, startCharacter: 21, endLine: 4, endCharacter: 27),
                    textEditNewText: ".greeting"
                )
            ])
        ])))
        let provider = makeProvider()
        let caret = (mainSource as NSString).range(of: "greeter.greet").upperBound
        let typedWord = NSRange(location: caret - 5, length: 5)

        let items = await provider.completions(
            for: CompletionRequest(
                prefix: "greet",
                fileURL: mainFile,
                text: mainSource,
                language: .swift,
                member: IdentifierScanner.MemberContext(
                    receiver: "greeter",
                    prefixRange: typedWord
                ),
                offset: caret
            )
        )

        XCTAssertEqual(items.map(\.displayText), ["greeting"])
        XCTAssertEqual(items.map(\.text), [".greeting"])
    }

    /// The common path, pinned by the recorded fixture: sourcekit-lsp's member
    /// items are zero-length `textEdit`s at the caret, so there is no head to
    /// drop and every row reads exactly what it inserts.
    func testTheRecordedMemberListDisplaysExactlyWhatItInserts() async throws {
        transport.script(LSPMethod.completion, .reply(try fixtureResult("completion-member.json")))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(
                prefix: "",
                offset: memberCaret,
                member: IdentifierScanner.MemberContext(
                    receiver: "greeter",
                    prefixRange: NSRange(location: memberCaret, length: 0)
                )
            )
        )

        XCTAssertEqual(items.map(\.displayText), items.map(\.text))
        XCTAssertEqual(items.map(\.displayText), ["salutation", "greet()", "self"])
    }

    /// The identifier path is untouched too, including the item that carries an
    /// auto-import: its primary edit starts at the typed word, so there is no
    /// gap and the row is the inserted text.
    func testAnIdentifierItemWithAnImportDisplaysWhatItInserts() async throws {
        transport.script(LSPMethod.completion, .reply(try fixtureResult("completion-auto-import.json")))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(prefix: "Gree", offset: identifierCaret)
        )

        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.displayText, "Greeter")
        XCTAssertEqual(item.displayText, item.text)
    }

    // MARK: - Resolve

    func testADeferredItemResolvesIntoItsImportEditAndEchoesTheServersDataVerbatim() async throws {
        transport.script(LSPMethod.completion, .reply(try fixtureResult("completion-identifier.json")))
        let resolved = try fixtureResult("completion-auto-import.json")["items"]?[0]
        transport.script(LSPMethod.resolveCompletionItem, .reply(try XCTUnwrap(resolved)))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(prefix: "Gree", offset: identifierCaret)
        )
        let item = try XCTUnwrap(items.first)
        // Every recorded item carries `data` and no `additionalTextEdits`: the
        // server kept something back, so each gets a handle.
        XCTAssertNotNil(item.resolveHandle)
        XCTAssertTrue(item.edits.isEmpty)

        let edits = await provider.resolveEdits(for: item)
        XCTAssertEqual(edits.map(\.role), [.primary, .additional])
        XCTAssertEqual(edits.first?.newText, "Greeter")
        XCTAssertEqual(edits.last?.newText, "import Core\n")

        // The item is echoed back untouched — `data` is how the server correlates
        // a resolve with the list it produced.
        let request = try XCTUnwrap(transport.requests(for: LSPMethod.resolveCompletionItem).first)
        XCTAssertEqual(request.params?["label"]?.stringValue, "Greeter")
        XCTAssertEqual(request.params?["data"]?["itemId"]?.intValue, 448)
        XCTAssertEqual(request.params?["sortText"]?.stringValue, "4939.67153671-Greeter")
    }

    /// A resolve contributes its `additionalTextEdits` and nothing else — the text
    /// the user committed is never re-derived from the answer.
    ///
    /// The spec does not let a resolve change what an item inserts, and
    /// sourcekit-lsp echoes the whole item back, so this is a guard against the
    /// *next* server rather than this one. A server that answers with a leaner item
    /// than it was sent — label, detail, the edits it kept back — would otherwise
    /// have `insertedText` fall through to `label`, and this is the one path in the
    /// layer whose result is written into the file rather than dropped: the popup
    /// says `Greeter`, the user commits it, and the buffer gets `Greeter(name:)`.
    func testAResolveThatDropsTheItemsOwnTextDoesNotChangeWhatIsInserted() async throws {
        transport.script(LSPMethod.completion, .reply(try fixtureResult("completion-identifier.json")))
        let lean: JSONValue = [
            "label": "Greeter(name:)",
            "detail": "Greeter",
            "additionalTextEdits": [
                [
                    "newText": "import Core\n",
                    "range": [
                        "start": ["line": 1, "character": 0],
                        "end": ["line": 1, "character": 0],
                    ],
                ]
            ],
        ]
        transport.script(LSPMethod.resolveCompletionItem, .reply(lean))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(prefix: "Gree", offset: identifierCaret)
        )
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.text, "Greeter")

        let edits = await provider.resolveEdits(for: item)
        XCTAssertEqual(edits.map(\.role), [.primary, .additional])
        XCTAssertEqual(
            edits.first?.newText, "Greeter",
            "the primary edit is the published item's, not the resolved item's label"
        )
        XCTAssertEqual(edits.last?.newText, "import Core\n", "the import is still picked up")
    }

    /// A handle from a superseded list names nothing: the table is replaced
    /// wholesale when a new list is published, and handles are never reused.
    func testAHandleFromASupersededListResolvesToNothing() async throws {
        transport.script(LSPMethod.completion, .reply(try fixtureResult("completion-identifier.json")))
        transport.script(LSPMethod.resolveCompletionItem, .reply(try fixtureResult("completion-resolve.json")))
        let provider = makeProvider()

        let first = await provider.completions(
            for: completionRequest(prefix: "Gree", offset: identifierCaret)
        )
        let stale = try XCTUnwrap(first.first)
        _ = await provider.completions(
            for: completionRequest(prefix: "Gree", offset: identifierCaret)
        )

        let staleEdits = await provider.resolveEdits(for: stale)
        XCTAssertTrue(staleEdits.isEmpty)
        XCTAssertTrue(transport.requests(for: LSPMethod.resolveCompletionItem).isEmpty)
    }

    /// A list that finished *late* must not take the handles of the list that
    /// superseded it.
    ///
    /// Two completion requests overlap as a matter of course — the router abandons
    /// one at its deadline and it keeps running, the next keystroke asks again —
    /// so the table has to be ordered by when each was *asked*, not by which
    /// happened to answer last. Ordered the other way, the older answer wipes the
    /// displayed list's handles on its way out and every one of its items resolves
    /// to nothing: D4's auto-import, lost silently, in the one case that looks
    /// exactly like a superseded handle.
    func testAnOlderListFinishingLateDoesNotTakeTheCurrentListsHandles() async throws {
        let list = try fixtureResult("completion-identifier.json")
        transport.script(LSPMethod.completion, [.reply(list, after: 0.2), .reply(list)])
        let resolved = try fixtureResult("completion-auto-import.json")["items"]?[0]
        transport.script(LSPMethod.resolveCompletionItem, .reply(try XCTUnwrap(resolved)))
        let provider = makeProvider()

        let slow = Task {
            await provider.completions(for: self.completionRequest(prefix: "Gree", offset: self.identifierCaret))
        }
        // The slow request has flushed its buffer and is waiting on its answer;
        // this is the keystroke behind it, asking the same question of the same
        // text (so no `didChange` moves the document under either of them).
        try await Task.sleep(nanoseconds: 40_000_000)
        let current = await provider.completions(
            for: completionRequest(prefix: "Gree", offset: identifierCaret)
        )
        let superseded = await slow.value

        XCTAssertFalse(current.isEmpty)
        XCTAssertFalse(superseded.isEmpty, "a superseded list is still returned to its own caller")
        let item = try XCTUnwrap(current.first)
        let edits = await provider.resolveEdits(for: item)
        XCTAssertEqual(edits.map(\.role), [.primary, .additional])
        XCTAssertEqual(edits.last?.newText, "import Core\n")
    }

    /// An item that never came from this provider — a tree-sitter one, say —
    /// resolves to nothing rather than to whatever sits at that number.
    func testAnItemWithNoHandleResolvesToNothing() async {
        let provider = makeProvider()
        let plain = CompletionItem(text: "Greeter", kind: .type, isFromCurrentFile: true)

        let edits = await provider.resolveEdits(for: plain)
        XCTAssertTrue(edits.isEmpty)
        XCTAssertEqual(harness.launches, 0)
    }

    /// The seam's default: every provider that is not this one answers "nothing
    /// to add", so the editor's insertion path needs no `is LSPIntelligenceProvider`
    /// check.
    func testTheTreeSitterProviderResolvesNothingByDefault() async {
        let provider = SymbolIntelligenceProvider(index: SymbolIndex())
        let item = CompletionItem(text: "Greeter", kind: .type, isFromCurrentFile: true, resolveHandle: 7)

        let edits = await provider.resolveEdits(for: item)
        XCTAssertTrue(edits.isEmpty)
    }

    // MARK: - No server

    /// A file the workspace will not serve — outside the opened root — is
    /// answered by nothing at all, and starts no server.
    func testAFileOutsideTheRootIsNotAskedAbout() async {
        transport.script(LSPMethod.definition, .reply(.array([])))
        let provider = makeProvider(root: URL(fileURLWithPath: "/private/tmp/other", isDirectory: true))

        let candidates = await provider.definitions(
            for: DefinitionRequest(
                identifier: "Greeter",
                fileURL: mainFile,
                offset: greeterReference,
                text: mainSource
            )
        )

        XCTAssertTrue(candidates.isEmpty)
        XCTAssertEqual(harness.launches, 0)
    }

    // MARK: - Inline item construction

    /// One completion item as the wire spells it — the authored counterpart to
    /// the recorded fixtures, for the three shapes this server never produced.
    private func completionItemJSON(
        label: String,
        sortText: String,
        detail: String? = nil,
        insertTextFormat: Int? = 1,
        textEdit: (startLine: Int, startCharacter: Int, endLine: Int, endCharacter: Int)? = nil,
        textEditNewText: String? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "label": .string(label),
            "sortText": .string(sortText),
            "insertText": .string(label),
            "filterText": .string(label),
            "kind": .int(LSPCompletionItemKind.struct.rawValue)
        ]
        if let insertTextFormat { object["insertTextFormat"] = .int(insertTextFormat) }
        if let detail { object["detail"] = .string(detail) }
        if let textEdit {
            object["textEdit"] = .object([
                "newText": .string(textEditNewText ?? label),
                "range": .object([
                    "start": .object([
                        "line": .int(textEdit.startLine),
                        "character": .int(textEdit.startCharacter)
                    ]),
                    "end": .object([
                        "line": .int(textEdit.endLine),
                        "character": .int(textEdit.endCharacter)
                    ])
                ])
            ])
        }
        return .object(object)
    }
}
