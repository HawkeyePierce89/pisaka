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

        init(foldingRange: Bool = true) {
            transport.script(
                LSPMethod.initialize,
                .reply(ScriptedLSPTransport.initializeResult(foldingRange: foldingRange))
            )
            transport.script(LSPMethod.shutdown, .reply(.null))
        }

        func makeTransport(_ description: LSPServerDescription, _ root: URL) -> LSPTransport {
            launches += 1
            return transport
        }
    }

    /// Short enough that a wedged test fails in a second.
    private nonisolated static let quick = LSPSession.Budgets(
        handshake: 1,
        definition: 1,
        completion: 1,
        resolve: 1,
        hover: 1,
        references: 1,
        foldingRange: 1,
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

    private func makeWorkspace(
        root: URL? = nil,
        budgets: LSPSession.Budgets = LSPIntelligenceProviderTests.quick
    ) -> LSPWorkspace {
        let harness = self.harness
        let workspace = LSPWorkspace(
            budgets: budgets,
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
    /// Counts `loadText` calls from whatever thread the mapping runs on — the
    /// only way to assert "read once per file" rather than "read at all".
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []

        func record(_ path: String) {
            lock.lock()
            paths.append(path)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return paths.count
        }
    }

    private func makeProvider(
        files: [String: String] = [:],
        completionLimit: Int = SymbolIntelligenceProvider.defaultCompletionLimit,
        root: URL? = nil,
        budgets: LSPSession.Budgets = LSPIntelligenceProviderTests.quick
    ) -> LSPIntelligenceProvider {
        let canonical = Dictionary(
            files.map { (CanonicalPath.canonical(URL(fileURLWithPath: $0.key)).path, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        let workspace = makeWorkspace(root: root, budgets: budgets)
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
        member: IdentifierScanner.MemberContext? = nil,
        text: String? = nil
    ) -> CompletionRequest {
        CompletionRequest(
            prefix: prefix,
            fileURL: mainFile,
            text: text ?? typingSource,
            language: .swift,
            member: member,
            offset: offset
        )
    }

    /// A compose file mid-keystroke, `dep` typed four columns in — the shape the
    /// indentation rule exists for. The language stays `.swift` because nothing
    /// in this layer branches on it; what matters is the caret's column.
    private let nestedYAML = """
        services:
          web:
            image: nginx
            dep
        """

    /// Caret at the end of `dep`, column 7 of the last line.
    private var nestedCaret: Int { (nestedYAML as NSString).range(of: "dep", options: .backwards).location + 3 }
    /// Caret at column 0 of the same buffer.
    private var topLevelCaret: Int { 0 }

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
            "Sources/Core/Greeter.swift",
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
            "Greeter — Sources/Core/Greeter.swift:5",
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
                    "end": .object(["line": .int(3), "character": .int(11)]),
                ]),
            ]),
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

    // MARK: - Folding

    private func foldRequest(text: String? = nil, fileURL: URL? = nil) -> FoldRegionRequest {
        FoldRegionRequest(
            fileURL: fileURL ?? mainFile,
            text: text ?? mainSource,
            language: .swift,
            indentWidths: IndentLevelWidths(unitWidth: 4, tabWidth: 4)
        )
    }

    private func foldingRangeJSON(
        startLine: Int,
        startCharacter: Int? = nil,
        endLine: Int,
        endCharacter: Int? = nil,
        kind: String? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "startLine": .int(startLine),
            "endLine": .int(endLine),
        ]
        if let startCharacter { object["startCharacter"] = .int(startCharacter) }
        if let endCharacter { object["endCharacter"] = .int(endCharacter) }
        if let kind { object["kind"] = .string(kind) }
        return .object(object)
    }

    /// The specification's own defaults for the two optional characters, which are
    /// the hidden range this editor wants anyway: from the end of the start line's
    /// content to the end of the end line's. The header line stays visible in
    /// full, and the block's last line joins it behind the placeholder.
    func testAFoldingRangeWithNoCharactersHidesFromOneLineEndToTheOther() async throws {
        transport.script(LSPMethod.foldingRange, .reply(.array([
            foldingRangeJSON(startLine: 0, endLine: 1, kind: "imports"),
        ])))
        let provider = makeProvider()

        let regions = await provider.foldRegions(for: foldRequest())

        let region = try XCTUnwrap(regions.first)
        XCTAssertEqual(regions.count, 1)
        let source = mainSource as NSString
        XCTAssertEqual(
            region.hiddenRange,
            NSRange(
                location: NSMaxRange(source.range(of: "import Core")),
                length: "\nimport Foundation".utf16.count
            )
        )
        XCTAssertEqual(region.headerLine, 0)
        XCTAssertEqual(region.kind, .imports)
    }

    /// A character-precise server is taken at its word: the handshake said
    /// `lineFoldingOnly: false`, so a bound inside a line is a bound inside a line.
    func testTheServersCharactersAreUsedWhereItSendsThem() async throws {
        transport.script(LSPMethod.foldingRange, .reply(.array([
            foldingRangeJSON(startLine: 0, startCharacter: 6, endLine: 1, endCharacter: 6),
        ])))
        let provider = makeProvider()

        let regions = await provider.foldRegions(for: foldRequest())

        let region = try XCTUnwrap(regions.first)
        XCTAssertEqual(region.hiddenRange, NSRange(location: 6, length: 12))
        XCTAssertEqual(
            (mainSource as NSString).substring(with: region.hiddenRange),
            " Core\nimport"
        )
        XCTAssertEqual(region.headerLine, 0)
        // Nothing named it, and an unnamed block is still a block.
        XCTAssertNil(region.kind)
    }

    /// **A range this buffer cannot hold is dropped, and its siblings survive** —
    /// the rule `LSPFoldingRangeResponse` applies to an unreadable element,
    /// applied one layer up to a readable element whose numbers are wrong. A line
    /// past the end and an end before its start are the two shapes a server
    /// actually miscounts into.
    func testARangeOutsideTheBufferOrInvertedIsDroppedWhileItsSiblingsSurvive() async throws {
        transport.script(LSPMethod.foldingRange, .reply(.array([
            foldingRangeJSON(startLine: 0, endLine: 99),
            foldingRangeJSON(startLine: 3, endLine: 1),
            foldingRangeJSON(startLine: -1, endLine: 2),
            foldingRangeJSON(startLine: 3, endLine: 4),
        ])))
        let provider = makeProvider()

        let regions = await provider.foldRegions(for: foldRequest())

        let region = try XCTUnwrap(regions.first)
        XCTAssertEqual(regions.count, 1, "only the fourth range is one this buffer can hold")
        XCTAssertEqual(region.headerLine, 3)
    }

    /// A range whose two ends land on the same offset hides nothing, and a region
    /// that hides nothing is not representable — so it is dropped rather than
    /// drawn as a chevron with nothing behind it.
    func testARangeThatWouldHideNothingIsDropped() async {
        transport.script(LSPMethod.foldingRange, .reply(.array([
            foldingRangeJSON(startLine: 2, startCharacter: 0, endLine: 2, endCharacter: 0),
        ])))
        let provider = makeProvider()

        let regions = await provider.foldRegions(for: foldRequest())

        XCTAssertTrue(regions.isEmpty)
    }

    /// An answer made entirely of unusable ranges is an empty answer, which the
    /// router reads as "the server failed to answer" and sends to the scanner.
    func testAnAnswerOfOnlyUnusableRangesIsEmpty() async {
        transport.script(LSPMethod.foldingRange, .reply(.array([
            foldingRangeJSON(startLine: 40, endLine: 41),
        ])))
        let provider = makeProvider()

        let regions = await provider.foldRegions(for: foldRequest())

        XCTAssertTrue(regions.isEmpty)
        XCTAssertEqual(transport.requests(for: LSPMethod.foldingRange).count, 1)
    }

    /// The answer is sorted into `FoldRegion`'s own order — header lines
    /// ascending, the longer region first — whatever order the server sent it in,
    /// because every consumer of the list reads it as ordered.
    func testTheAnswerIsInFoldRegionsOrderWhateverOrderTheServerSentItIn() async {
        transport.script(LSPMethod.foldingRange, .reply(.array([
            foldingRangeJSON(startLine: 3, endLine: 4),
            foldingRangeJSON(startLine: 0, endLine: 1),
            foldingRangeJSON(startLine: 0, endLine: 4),
        ])))
        let provider = makeProvider()

        let regions = await provider.foldRegions(for: foldRequest())

        XCTAssertEqual(regions.map(\.headerLine), [0, 0, 3])
        XCTAssertEqual(regions, regions.sorted())
        XCTAssertGreaterThan(
            regions[0].hiddenRange.length,
            regions[1].hiddenRange.length,
            "the longer region on a shared header line comes first"
        )
    }

    /// A server that does not advertise `foldingRangeProvider` is not asked — the
    /// capability gate hover's path states, on a question that also fires behind
    /// every typing pause.
    func testAServerWithoutTheFoldingCapabilityIsNotAsked() async {
        harness = Harness(foldingRange: false)
        transport.script(LSPMethod.foldingRange, .reply(.array([
            foldingRangeJSON(startLine: 0, endLine: 1),
        ])))
        let provider = makeProvider()

        let regions = await provider.foldRegions(for: foldRequest())

        XCTAssertTrue(regions.isEmpty)
        XCTAssertTrue(transport.requests(for: LSPMethod.foldingRange).isEmpty)
    }

    /// An empty buffer folds nowhere, and the round trip that could only confirm
    /// that is not made — this question's reading of D2's guard, which has no
    /// offset to be inconsistent with.
    func testAnEmptyBufferIsNotAskedAbout() async {
        transport.script(LSPMethod.foldingRange, .reply(.array([
            foldingRangeJSON(startLine: 0, endLine: 1),
        ])))
        let provider = makeProvider()

        let regions = await provider.foldRegions(for: foldRequest(text: ""))

        XCTAssertTrue(regions.isEmpty)
        XCTAssertTrue(transport.requests(for: LSPMethod.foldingRange).isEmpty)
    }

    /// **The staleness gate on the folding path.** A fold is a *range in a
    /// buffer*, and a list computed for the folder the user has just left would
    /// hide text this one does not have.
    ///
    /// Staged through the transport's write hook rather than a delay: the request
    /// is held inside `send`, so the switch provably lands while the question is
    /// outstanding and the reply cannot arrive before it.
    func testFoldRegionsAreDroppedWhenTheFolderChangedWhileTheQuestionWasOutstanding() async throws {
        transport.script(LSPMethod.foldingRange, .reply(.array([
            foldingRangeJSON(startLine: 0, endLine: 1),
        ])))
        let provider = makeProvider()
        let workspace = try XCTUnwrap(lastWorkspace)
        let gate = Gate()
        transport.onSend { method in
            guard method == LSPMethod.foldingRange else { return }
            gate.wait()
        }

        let asking = Task { await provider.foldRegions(for: self.foldRequest()) }
        await gate.waitUntilReached()

        workspace.prepareForFolderChange(root: otherRoot)
        gate.release()

        let regions = await asking.value
        XCTAssertTrue(
            regions.isEmpty,
            "folds for a folder the user has left would hide text this buffer does not have"
        )
    }

    // MARK: - Hover

    private func hoverRequest(at offset: Int, text: String? = nil) -> HoverRequest {
        HoverRequest(fileURL: mainFile, offset: offset, text: text ?? mainSource)
    }

    /// A `MarkupContent` answer, with the range the server named: a fenced
    /// signature becomes a code segment and the paragraph under it prose, and the
    /// popover is anchored to the span the server said it was talking about.
    func testAHoverBecomesSegmentsAnchoredToTheRangeTheServerNamed() async throws {
        transport.script(LSPMethod.hover, .reply(.object([
            "contents": .object([
                "kind": .string("markdown"),
                "value": .string("```swift\npublic struct Greeter\n```\n\nA greeter used by the tests."),
            ]),
            // Line 3, characters 14…21: `Greeter` in `let greeter = Greeter()`.
            "range": .object([
                "start": .object(["line": .int(3), "character": .int(14)]),
                "end": .object(["line": .int(3), "character": .int(21)]),
            ]),
        ])))
        let provider = makeProvider()

        let hovered = await provider.hover(for: hoverRequest(at: greeterReference))

        let answer = try XCTUnwrap(hovered)
        XCTAssertEqual(answer.content.segments, [
            .code("public struct Greeter", language: "swift"),
            .prose("A greeter used by the tests."),
        ])
        XCTAssertFalse(answer.content.isTruncated)
        // Mapped back into the buffer, not left in the server's line/character
        // coordinates — the popover is drawn beside characters, not lines.
        XCTAssertEqual(answer.range, NSRange(location: greeterReference, length: 7))
        XCTAssertEqual((mainSource as NSString).substring(with: answer.range), "Greeter")
    }

    /// The `MarkedString[]` shape, and the range fallback: most servers send no
    /// `range`, so the answer is anchored to the identifier the pointer is over —
    /// which is the same span the editor resolved before deciding to ask.
    func testAMarkedStringArrayKeepsItsOrderAndFallsBackToTheIdentifierRange() async throws {
        transport.script(LSPMethod.hover, .reply(.object([
            "contents": .array([
                .object([
                    "language": .string("swift"),
                    "value": .string("func greet(_ name: String) -> String"),
                ]),
                .string("Returns a **greeting**."),
            ]),
        ])))
        let provider = makeProvider()

        let hovered = await provider.hover(for: hoverRequest(at: greeterReference))

        let answer = try XCTUnwrap(hovered)
        XCTAssertEqual(answer.content.segments, [
            .code("func greet(_ name: String) -> String", language: "swift"),
            .prose("Returns a greeting."),
        ])
        XCTAssertEqual((mainSource as NSString).substring(with: answer.range), "Greeter")
    }

    /// A range that does not cover the offset the question was about is not the
    /// answer's range. It is the shape a server gets wrong in the direction that
    /// costs most: the range is both where the popover is drawn and the editor's
    /// re-ask suppressor, so a degenerate `{0, 0}` would anchor the popover at the
    /// top of the file *and* make every mouse-moved event over the identifier ask
    /// again. Falls back to the identifier, exactly as no range at all does.
    func testAHoverRangeThatDoesNotCoverTheOffsetFallsBackToTheIdentifier() async throws {
        transport.script(LSPMethod.hover, .reply(.object([
            "contents": .object([
                "kind": .string("plaintext"),
                "value": .string("struct Greeter"),
            ]),
            // Line 0, characters 0…0: nowhere near the hovered offset.
            "range": .object([
                "start": .object(["line": .int(0), "character": .int(0)]),
                "end": .object(["line": .int(0), "character": .int(0)]),
            ]),
        ])))
        let provider = makeProvider()

        let hovered = await provider.hover(for: hoverRequest(at: greeterReference))

        let answer = try XCTUnwrap(hovered)
        XCTAssertEqual(answer.range, NSRange(location: greeterReference, length: 7))
        XCTAssertEqual((mainSource as NSString).substring(with: answer.range), "Greeter")
    }

    /// A server that does not advertise `hoverProvider` is never asked. Every
    /// other request in this layer would waste one round trip; this one fires
    /// whenever the pointer stops, so an unanswerable question is asked forever.
    func testAServerThatDoesNotAdvertiseHoverIsNeverAsked() async {
        transport.script(
            LSPMethod.initialize,
            .reply(ScriptedLSPTransport.initializeResult(hover: false))
        )
        transport.script(LSPMethod.hover, .reply(.object([
            "contents": .string("this must never be read")
        ])))
        let provider = makeProvider()

        let answer = await provider.hover(for: hoverRequest(at: greeterReference))

        XCTAssertNil(answer)
        // The server is still started and the buffer still flushed — the capability
        // is only knowable *after* the handshake — but nothing is asked.
        XCTAssertEqual(harness.launches, 1)
        XCTAssertTrue(transport.requests(for: LSPMethod.hover).isEmpty)
    }

    /// `null` — the answer every server gives for a keyword, a comment or a
    /// space. There is no empty popover, so there is no answer.
    func testANullHoverIsNoAnswer() async {
        transport.script(LSPMethod.hover, .reply(.null))
        let provider = makeProvider()

        let answer = await provider.hover(for: hoverRequest(at: greeterReference))

        XCTAssertNil(answer)
        XCTAssertEqual(transport.requests(for: LSPMethod.hover).count, 1)
    }

    /// And the shape that *is* an answer on the wire and nothing on screen: a
    /// server that replied, with content that normalizes away.
    func testAWhitespaceOnlyHoverIsNoAnswer() async {
        transport.script(LSPMethod.hover, .reply(.object([
            "contents": .object([
                "kind": .string("markdown"),
                "value": .string("   \n\n---\n\n \t \n"),
            ]),
        ])))
        let provider = makeProvider()

        let answer = await provider.hover(for: hoverRequest(at: greeterReference))

        XCTAssertNil(answer, "a rule and some whitespace is not a popover")
    }

    /// The staleness gate, hover's half: an answer about a document the server was
    /// talked out of underneath this question would anchor a popover to text that
    /// has moved.
    func testAHoverIsDroppedWhenAnotherRequestChangedTheServersDocumentUnderIt() async throws {
        transport.script(LSPMethod.hover, .reply(.object([
            "contents": .string("public struct Greeter")
        ]), after: 0.2))
        let provider = makeProvider()
        let workspace = try XCTUnwrap(lastWorkspace)

        let hovering = Task { await provider.hover(for: self.hoverRequest(at: self.greeterReference)) }
        try await Task.sleep(nanoseconds: 40_000_000)
        let interleaved = await workspace.prepare(
            url: mainFile,
            language: .swift,
            text: "// the document the server now holds\n"
        )
        XCTAssertEqual(interleaved?.version, 2, "the staging itself must have moved the server")

        let answer = await hovering.value
        XCTAssertNil(answer)
    }

    /// A folder switch mid-question drops it too — the same gate, the wider
    /// window.
    func testAHoverIsDroppedWhenTheFolderChangedWhileItWasOutstanding() async throws {
        transport.script(LSPMethod.hover, .reply(.object([
            "contents": .string("public struct Greeter")
        ]), after: 0.2))
        let provider = makeProvider()
        let workspace = try XCTUnwrap(lastWorkspace)

        let hovering = Task { await provider.hover(for: self.hoverRequest(at: self.greeterReference)) }
        try await Task.sleep(nanoseconds: 40_000_000)
        workspace.prepareForFolderChange(root: otherRoot)

        let answer = await hovering.value
        XCTAssertNil(answer)
    }

    /// A server that never answers costs its own budget and then nothing at all —
    /// no popover, no alert, no trace.
    func testAHoverThatTimesOutAnswersNothing() async {
        transport.script(LSPMethod.hover, .drop)
        let provider = makeProvider(
            budgets: LSPSession.Budgets(
                handshake: 1,
                definition: 1,
                completion: 1,
                resolve: 1,
                hover: 0.05,
                shutdown: 1
            )
        )

        let answer = await provider.hover(for: hoverRequest(at: greeterReference))

        XCTAssertNil(answer)
        XCTAssertEqual(transport.requests(for: LSPMethod.hover).count, 1)
    }

    // MARK: - Find usages

    private func usagesRequest(
        at offset: Int? = nil,
        text: String? = nil,
        openTexts: [URL: String] = [:]
    ) -> UsagesRequest {
        UsagesRequest(
            identifier: "Greeter",
            fileURL: mainFile,
            offset: offset ?? greeterReference,
            text: text ?? mainSource,
            openTexts: openTexts
        )
    }

    /// One `Location` on the wire.
    private func location(_ url: URL, line: Int, from: Int, to: Int) -> JSONValue {
        .object([
            "uri": .string(LSPWorkspace.documentURI(for: url)),
            "range": .object([
                "start": .object(["line": .int(line), "character": .int(from)]),
                "end": .object(["line": .int(line), "character": .int(to)]),
            ]),
        ])
    }

    /// The whole mapping in one case: two files, the requesting one included,
    /// each row carrying a buffer range, the gutter's line number, the project
    /// path and the single line the panel draws.
    func testReferencesBecomeRowsWithBufferRangesGutterLinesAndPreviews() async throws {
        transport.script(LSPMethod.references, .reply(.array([
            // `public struct Greeter` on line 2 of the declaring file.
            location(greeterFile, line: 1, from: 14, to: 21),
            // `let greeter = Greeter()` on line 4 of the requesting file.
            location(mainFile, line: 3, from: 14, to: 21),
        ])))
        let provider = makeProvider(files: [greeterFile.path: greeterSource])

        let usages = await provider.references(for: usagesRequest())

        XCTAssertEqual(usages.map(\.relativePath), [
            "Sources/Core/Greeter.swift",
            "Sources/App/main.swift",
        ])
        // 1-based display lines, derived from the offsets with `LineStartIndex`
        // (D1) rather than from the server's zero-based numbering.
        XCTAssertEqual(usages.map(\.line), [2, 4])
        XCTAssertEqual(usages.map(\.isTextual), [false, false])
        XCTAssertEqual(
            (greeterSource as NSString).substring(with: usages[0].range),
            "Greeter"
        )
        XCTAssertEqual(
            (mainSource as NSString).substring(with: usages[1].range),
            "Greeter"
        )
        // The preview is the row's whole logical line with the occurrence located
        // inside it — Find in Files' shape, so the two kinds of row read alike.
        XCTAssertEqual(usages.map(\.preview.text), [
            "public struct Greeter {",
            "let greeter = Greeter()",
        ])
        XCTAssertEqual(usages[0].preview.matchRange, NSRange(location: 14, length: 7))
        XCTAssertEqual(usages[1].preview.matchRange, NSRange(location: 14, length: 7))
    }

    /// The buffer beats the disk for the file the question came from — the index's
    /// rule, and here it decides both the range and the line number a row
    /// navigates by. The `loadText` copy is deliberately a *different* file: if it
    /// were consulted, every assertion below would land one line off.
    func testAUsageInTheRequestingFileIsMeasuredAgainstTheBufferNotTheDiskCopy() async {
        transport.script(LSPMethod.references, .reply(.array([
            location(mainFile, line: 3, from: 14, to: 21),
        ])))
        let staleOnDisk = "// a line the buffer does not have\n" + mainSource
        let provider = makeProvider(files: [mainFile.path: staleOnDisk])

        let usages = await provider.references(for: usagesRequest())

        XCTAssertEqual(usages.count, 1)
        XCTAssertEqual(usages.first?.line, 4)
        XCTAssertEqual(usages.first?.preview.text, "let greeter = Greeter()")
        XCTAssertEqual(
            (mainSource as NSString).substring(with: try XCTUnwrap(usages.first).range),
            "Greeter"
        )
    }

    /// A line whose characters are not one UTF-16 unit each: the position that
    /// comes back has to survive the round trip into buffer offsets, or every row
    /// in a file with an emoji in it points a few characters short.
    func testAUsageOnANonASCIILineMapsToTheRightBufferRange() async throws {
        let source = "let 🙂 = Greeter()\nlet other = Greeter()"
        transport.script(LSPMethod.references, .reply(.array([
            // `Greeter` on line 0, after a surrogate pair: UTF-16 characters 9…16.
            location(mainFile, line: 0, from: 9, to: 16),
            location(mainFile, line: 1, from: 12, to: 19),
        ])))
        let provider = makeProvider()

        let usages = await provider.references(for: usagesRequest(at: 9, text: source))

        XCTAssertEqual(usages.count, 2)
        let text = source as NSString
        XCTAssertEqual(text.substring(with: usages[0].range), "Greeter")
        XCTAssertEqual(text.substring(with: usages[1].range), "Greeter")
        XCTAssertEqual(usages.map(\.line), [1, 2])
        XCTAssertEqual(usages[0].preview.text, "let 🙂 = Greeter()")
        XCTAssertEqual(usages[0].preview.matchRange, NSRange(location: 9, length: 7))
    }

    /// A URI this editor cannot open, and a file whose text cannot be read, are
    /// each one fewer row — silently, and without costing their siblings. A row
    /// navigates by a *buffer range*, and there is no honest range to invent for
    /// either.
    func testAUsageWithAnUnopenableURIOrAnUnreadableFileIsDroppedSilently() async {
        transport.script(LSPMethod.references, .reply(.array([
            .object([
                "uri": .string("untitled:Untitled-1"),
                "range": .object([
                    "start": .object(["line": .int(0), "character": .int(0)]),
                    "end": .object(["line": .int(0), "character": .int(7)]),
                ]),
            ]),
            location(greeterFile, line: 1, from: 14, to: 21),
            location(mainFile, line: 3, from: 14, to: 21),
        ])))
        // `greeterFile` is deliberately absent from `files:`.
        let provider = makeProvider()

        let usages = await provider.references(for: usagesRequest())

        XCTAssertEqual(usages.map(\.relativePath), ["Sources/App/main.swift"])
    }

    /// A server that does not advertise `referencesProvider` is not asked. The
    /// gate is worth its line here for a reason hover's is not: the model's answer
    /// when this returns nothing is a walk of the whole project, and paying the
    /// budget first only delays the answer the user is going to get anyway.
    func testAServerWithoutTheReferencesCapabilityIsNotAsked() async {
        transport.script(LSPMethod.initialize, .reply(
            ScriptedLSPTransport.initializeResult(references: false)
        ))
        transport.script(LSPMethod.references, .reply(.array([
            location(mainFile, line: 3, from: 14, to: 21),
        ])))
        let provider = makeProvider()

        let usages = await provider.references(for: usagesRequest())

        XCTAssertTrue(usages.isEmpty)
        XCTAssertTrue(transport.requests(for: LSPMethod.references).isEmpty)
    }

    /// `null`, an empty array and a server error are the same answer here — and it
    /// is an *empty* answer rather than a converted one: what replaces it is
    /// `FindUsagesModel`'s decision, not this layer's (decision 1).
    func testAnEmptyNullOrFailedReferencesAnswerIsEmpty() async {
        transport.script(LSPMethod.references, [
            .reply(.null),
            .reply(.array([])),
            .fail(LSPResponseError(code: .internalError, message: "internal error")),
        ])
        let provider = makeProvider(files: [greeterFile.path: greeterSource])

        for _ in 1...3 {
            let usages = await provider.references(for: usagesRequest())
            XCTAssertTrue(usages.isEmpty)
        }
        XCTAssertEqual(transport.requests(for: LSPMethod.references).count, 3)
    }

    /// **The staleness gate on the usages path.** A row is a *range in a buffer*,
    /// and a list computed for the folder the user has just left points at files
    /// the window no longer shows.
    ///
    /// Staged through the transport's write hook rather than a delay: the request
    /// is held inside `send`, so the switch provably lands while the question is
    /// outstanding, and the reply cannot arrive before it.
    func testReferencesAreDroppedWhenTheFolderChangedWhileTheQuestionWasOutstanding() async throws {
        transport.script(LSPMethod.references, .reply(.array([
            location(greeterFile, line: 1, from: 14, to: 21),
        ])))
        let provider = makeProvider(files: [greeterFile.path: greeterSource])
        let workspace = try XCTUnwrap(lastWorkspace)
        let gate = Gate()
        transport.onSend { method in
            guard method == LSPMethod.references else { return }
            gate.wait()
        }

        let asking = Task { await provider.references(for: self.usagesRequest()) }
        await gate.waitUntilReached()

        workspace.prepareForFolderChange(root: otherRoot)
        gate.release()

        let usages = await asking.value
        XCTAssertTrue(
            usages.isEmpty,
            "rows for a folder the user has left would open files the window no longer shows"
        )
    }

    /// **One read and one line-start scan per file, whatever the row count.** The
    /// cache's whole reason: a busy identifier answers hundreds of rows in one
    /// file, and re-reading it per row is the difference between a list and a
    /// hang. The two spellings of `main.swift` are the second half of the rule —
    /// a server answers with the path *it* resolved, and `/tmp` vs `/private/tmp`
    /// is one file, not two.
    func testEachFileIsReadOnceForAWholeUsagesAnswerHoweverManyRowsItHas() async throws {
        transport.script(LSPMethod.references, .reply(.array([
            location(greeterFile, line: 1, from: 14, to: 21),
            location(greeterFile, line: 1, from: 14, to: 21),
            location(greeterFile, line: 1, from: 14, to: 21),
        ])))
        let counter = Counter()
        let workspace = makeWorkspace()
        lastWorkspace = workspace
        let source = greeterSource
        let canonicalGreeter = CanonicalPath.canonical(greeterFile).path
        let provider = LSPIntelligenceProvider(
            workspace: workspace,
            loadText: { url in
                counter.record(url.path)
                return CanonicalPath.canonical(url).path == canonicalGreeter ? source : nil
            }
        )

        let usages = await provider.references(for: usagesRequest())

        XCTAssertEqual(usages.count, 3)
        XCTAssertEqual(counter.count, 1, "three rows in one file must cost one read, not three")
    }

    /// The requesting file is seeded from the *buffer*, so however many rows land
    /// in it none of them is a disk read — the rule that makes a usages answer in
    /// the file being edited describe what the user is looking at.
    func testTheRequestingFileIsNeverLoadedFromDisk() async throws {
        transport.script(LSPMethod.references, .reply(.array([
            location(mainFile, line: 3, from: 14, to: 21),
            location(mainFile, line: 3, from: 14, to: 21),
        ])))
        let counter = Counter()
        let workspace = makeWorkspace()
        lastWorkspace = workspace
        let provider = LSPIntelligenceProvider(
            workspace: workspace,
            loadText: { url in
                counter.record(url.path)
                return nil
            }
        )

        let usages = await provider.references(for: usagesRequest())

        XCTAssertEqual(usages.count, 2)
        XCTAssertEqual(counter.count, 0, "the requesting file is the buffer, never a disk read")
    }

    /// **A dirty background tab is mapped against its buffer, not its disk copy.**
    ///
    /// The push channel (D29/D30) has already given the server that tab's text, so
    /// the coordinates it answers with are the *buffer's*. Reading the disk copy
    /// here is not a staleness detail but the wrong coordinate space: it produces a
    /// plausible-looking row on the wrong line, with a preview drawn from unrelated
    /// text, that the editor then refuses to reveal. The fixture makes the two
    /// spaces disagree by two lines, so a row mapped against the disk copy cannot
    /// accidentally pass.
    func testAnOpenTabsBufferIsPreferredOverItsDiskCopyWhenMappingUsages() async throws {
        let editedGreeter = """
            // A comment the user just typed.
            // And a second line of it.
            \(greeterSource)
            """
        // `public struct Greeter` sits on line 1 of the disk copy and line 3 of the
        // buffer; the server answers about the buffer, because that is what it has.
        transport.script(LSPMethod.references, .reply(.array([
            location(greeterFile, line: 3, from: 14, to: 21),
        ])))
        let counter = Counter()
        let workspace = makeWorkspace()
        lastWorkspace = workspace
        let source = greeterSource
        let provider = LSPIntelligenceProvider(
            workspace: workspace,
            loadText: { url in
                counter.record(url.path)
                return source
            }
        )

        let usages = await provider.references(
            for: usagesRequest(openTexts: [greeterFile: editedGreeter])
        )

        XCTAssertEqual(usages.count, 1)
        let row = try XCTUnwrap(usages.first)
        XCTAssertEqual(row.line, 4, "the display line is the buffer's, not the disk copy's")
        XCTAssertEqual(row.preview.text, "public struct Greeter {")
        XCTAssertEqual(
            (editedGreeter as NSString).substring(with: row.range),
            "Greeter",
            "the range must land on the symbol in the text the row was computed against"
        )
        XCTAssertEqual(counter.count, 0, "an open tab's text is never re-read from disk")
    }

    /// The same rule when the tab and the server spell the file differently —
    /// which they routinely do, since a server answers with the path *it*
    /// resolved. A lookup by raw `path` would miss the buffer and fall silently
    /// back to the disk copy, i.e. to exactly the wrong coordinate space the test
    /// above is about.
    func testAnOpenTabIsMatchedCanonicallyRatherThanBySpelling() async throws {
        let editedGreeter = """
            // A comment the user just typed.
            // And a second line of it.
            \(greeterSource)
            """
        let asOpened = URL(fileURLWithPath: "/private/tmp/lspfix/pkg/Sources/App/../Core/Greeter.swift")
        transport.script(LSPMethod.references, .reply(.array([
            location(greeterFile, line: 3, from: 14, to: 21),
        ])))
        let workspace = makeWorkspace()
        lastWorkspace = workspace
        let source = greeterSource
        let provider = LSPIntelligenceProvider(workspace: workspace, loadText: { _ in source })

        let usages = await provider.references(
            for: usagesRequest(openTexts: [asOpened: editedGreeter])
        )

        XCTAssertEqual(usages.first?.preview.text, "public struct Greeter {")
    }

    /// **A cancelled mapping stops reading the project.**
    ///
    /// `RoutingIntelligenceProvider` abandons this call at its budget and cancels
    /// the task around it, and `FindUsagesModel` starts the textual walk in its
    /// place. The mapping loop is unbounded — one file read and indexed per
    /// location a server named — so a loser that does not notice goes on reading
    /// the project alongside the walk that replaced it. The cancellation is staged
    /// causally, from inside the first file's read, so there is no window to miss.
    func testACancelledUsagesMappingStopsReadingFiles() async throws {
        let otherFile = root.appendingPathComponent("Sources/Core/Other.swift")
        transport.script(LSPMethod.references, .reply(.array([
            location(greeterFile, line: 1, from: 14, to: 21),
            location(otherFile, line: 1, from: 14, to: 21),
        ])))
        let workspace = makeWorkspace()
        lastWorkspace = workspace
        let counter = Counter()
        let source = greeterSource
        let provider = LSPIntelligenceProvider(
            workspace: workspace,
            loadText: { url in
                counter.record(url.path)
                // Cancelled from *inside* the loop, through the task running it,
                // so there is no handle to publish and no window between arming
                // the cancellation and the iteration that must observe it.
                withUnsafeCurrentTask { $0?.cancel() }
                return source
            }
        )

        let usages = await Task { await provider.references(for: self.usagesRequest()) }.value

        XCTAssertTrue(usages.isEmpty, "an abandoned mapping publishes nothing")
        XCTAssertEqual(counter.count, 1, "and reads no file after the cancellation")
    }

    // MARK: - Rename

    private func renameRequest(
        newName: String = "Welcomer",
        identifier: String = "Greeter",
        offset: Int? = nil,
        text: String? = nil
    ) -> RenameRequest {
        RenameRequest(
            identifier: identifier,
            fileURL: mainFile,
            offset: offset ?? greeterReference,
            text: text ?? mainSource,
            newName: newName
        )
    }

    /// The answer is the server's edit, carried through unmapped: turning
    /// `(line, character)` into buffer ranges needs the text of files no editor
    /// holds, so it happens once — in `RenameEditPlan`, where the refusals that
    /// depend on it live too.
    func testARenameAnswerCarriesTheServersEditVerbatim() async throws {
        transport.script(LSPMethod.rename, .reply(.object([
            "documentChanges": .array([
                .object([
                    "textDocument": .object([
                        "uri": .string(LSPWorkspace.documentURI(for: greeterFile)),
                        "version": .int(7),
                    ]),
                    "edits": .array([
                        .object([
                            "newText": .string("Welcomer"),
                            "range": .object([
                                "start": .object(["line": .int(1), "character": .int(14)]),
                                "end": .object(["line": .int(1), "character": .int(21)]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ])))
        let provider = makeProvider(files: [greeterFile.path: greeterSource])

        let renamed = await provider.renameEdits(for: renameRequest())

        let answer = try XCTUnwrap(renamed)
        XCTAssertEqual(answer.newName, "Welcomer")
        XCTAssertEqual(answer.edit.documents.count, 1)
        XCTAssertEqual(answer.edit.documents.first?.version, 7)
        XCTAssertEqual(answer.edit.documents.first?.edits.first?.newText, "Welcomer")
        XCTAssertEqual(
            answer.edit.documents.first?.edits.first?.range.start,
            LSPPosition(line: 1, character: 14)
        )
        // The new name reached the server as the new name.
        let sent = transport.requests(for: LSPMethod.rename).first
        XCTAssertEqual(sent?.params?["newName"]?.stringValue, "Welcomer")
    }

    /// A name that changes nothing is refused before the wire. A new name equal to
    /// the old one would come back as a `WorkspaceEdit` replacing text with
    /// itself, which passes every verification and rewrites a project's worth of
    /// files to no effect — taking each one's undo stack with it. An empty name is
    /// not a rename at all.
    func testARenameToTheSameNameOrToNothingAsksTheServerNothing() async {
        transport.script(LSPMethod.rename, .reply(.object(["changes": .object([:])])))
        let provider = makeProvider()

        let same = await provider.renameEdits(for: renameRequest(newName: "Greeter"))
        let empty = await provider.renameEdits(for: renameRequest(newName: ""))

        XCTAssertNil(same)
        XCTAssertNil(empty)
        XCTAssertEqual(harness.launches, 0)
        XCTAssertTrue(transport.requests(for: LSPMethod.rename).isEmpty)
    }

    /// A server that does not advertise `renameProvider` is not asked — and the
    /// command beeps, because there is nothing else it could do (decision 4).
    func testAServerWithoutTheRenameCapabilityIsNotAsked() async {
        transport.script(LSPMethod.initialize, .reply(
            ScriptedLSPTransport.initializeResult(rename: false)
        ))
        transport.script(LSPMethod.rename, .reply(.object(["changes": .object([:])])))
        let provider = makeProvider()

        let renamed = await provider.renameEdits(for: renameRequest())

        XCTAssertNil(renamed)
        XCTAssertTrue(transport.requests(for: LSPMethod.rename).isEmpty)
        // But the policy question the command asks *first* is still `true`: the
        // capability is only knowable from a started server, and starting one to
        // decide whether to show a dialog is what that check exists not to do.
        let offered = await provider.canRename(.swift)
        XCTAssertTrue(offered)
    }

    /// An answer with no edits in it, a `null` answer and a server error are one
    /// fact to every caller — the command beeps — and collapsing them here is what
    /// keeps the writer bracket from being raised around a plan that touches
    /// nothing.
    func testARenameAnsweringNoEditsAnswersNil() async {
        transport.script(LSPMethod.rename, [
            .reply(.object(["changes": .object([:])])),
            .reply(.object([
                "changes": .object([
                    LSPWorkspace.documentURI(for: greeterFile): .array([]),
                ]),
            ])),
            .reply(.null),
            .fail(LSPResponseError(code: .internalError, message: "internal error")),
        ])
        let provider = makeProvider(files: [greeterFile.path: greeterSource])

        for _ in 1...4 {
            let renamed = await provider.renameEdits(for: renameRequest())
            XCTAssertNil(renamed)
        }
        XCTAssertEqual(transport.requests(for: LSPMethod.rename).count, 4)
    }

    /// **The same gate, on the one answer that becomes a write.** Every other
    /// answer that survives a stale document is a wrong *reading*; this one would
    /// be a wrong write, applied project-wide inside the writer bracket.
    func testARenameIsDroppedWhenTheFolderChangedWhileTheQuestionWasOutstanding() async throws {
        transport.script(LSPMethod.rename, .reply(.object([
            "changes": .object([
                LSPWorkspace.documentURI(for: greeterFile): .array([
                    .object([
                        "newText": .string("Welcomer"),
                        "range": .object([
                            "start": .object(["line": .int(1), "character": .int(14)]),
                            "end": .object(["line": .int(1), "character": .int(21)]),
                        ]),
                    ]),
                ]),
            ]),
        ])))
        let provider = makeProvider(files: [greeterFile.path: greeterSource])
        let workspace = try XCTUnwrap(lastWorkspace)
        let gate = Gate()
        transport.onSend { method in
            guard method == LSPMethod.rename else { return }
            gate.wait()
        }

        let renaming = Task { await provider.renameEdits(for: self.renameRequest()) }
        await gate.waitUntilReached()

        workspace.prepareForFolderChange(root: otherRoot)
        gate.release()

        let renamed = await renaming.value
        XCTAssertNil(
            renamed,
            "a rename computed for a closed project may not become a write in the open one"
        )
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

    /// And the same rule for hover, which is a question about a position and
    /// nothing else: an empty buffer at a non-zero offset would clamp to `0:0` and
    /// describe the first thing in the file, under the pointer or not.
    func testAnEmptyBufferWithANonZeroOffsetAsksNoHover() async {
        transport.script(LSPMethod.hover, .reply(.object(["contents": .string("Greeter")])))
        let provider = makeProvider()

        let answer = await provider.hover(for: hoverRequest(at: 45, text: ""))

        XCTAssertNil(answer)
        XCTAssertEqual(harness.launches, 0)
        XCTAssertTrue(transport.requests(for: LSPMethod.hover).isEmpty)
    }

    /// And for the two commands, which are questions about a position exactly as
    /// hover is: an empty buffer at a non-zero offset would clamp to `0:0` and
    /// list — or rename — whatever stands at the top of the file.
    func testAnEmptyBufferWithANonZeroOffsetAsksNoUsagesAndNoRename() async {
        transport.script(LSPMethod.references, .reply(.array([])))
        transport.script(LSPMethod.rename, .reply(.object(["changes": .object([:])])))
        let provider = makeProvider()

        let usages = await provider.references(for: usagesRequest(at: 45, text: ""))
        let renamed = await provider.renameEdits(for: renameRequest(offset: 45, text: ""))

        XCTAssertTrue(usages.isEmpty)
        XCTAssertNil(renamed)
        XCTAssertEqual(harness.launches, 0)
        XCTAssertTrue(transport.requests(for: LSPMethod.references).isEmpty)
        XCTAssertTrue(transport.requests(for: LSPMethod.rename).isEmpty)
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

    /// The shape `yaml-language-server` really answers with: no `sortText` at all,
    /// so D6 ranks on `label`, and **every** property of the schema at the caret
    /// regardless of what is typed. Ranked on `label` alone and cut at the cap,
    /// the one key that answers `ima` is below the cut — which is the whole reason
    /// the matcher is consulted here at all.
    func testAnItemAnsweringTheTypedPrefixReachesTheCapBeforeOneThatDoesNot() async {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array(
                ["annotations", "attach", "blkio_config", "build", "image"]
                    .map(schemaPropertyItemJSON(label:))
            ),
        ])))
        let provider = makeProvider(completionLimit: 3)

        let items = await provider.completions(
            for: completionRequest(prefix: "ima", offset: identifierCaret)
        )

        // `image` first — not because the match is a ranking key, but because the
        // half of the list that answers `ima` is the half the cap reaches first.
        // The two rows left over are D6's order among the ones that do not.
        XCTAssertEqual(items.map(\.text), ["image:\n  ", "annotations:\n  ", "attach:\n  "])
    }

    /// The other half of the same rule: not matching is not a reason to be
    /// dropped. A server's own matching may be looser than this one's boundary
    /// rule — the recorded sourcekit-lsp transcript answers `Gree` with
    /// `VM_MEMORY_MALLOC_LARGE_REUSED` — and a list with room for those items
    /// still shows them, in D6's order, after the ones that answer.
    func testItemsThatMatchNothingAreOrderedLastRatherThanDropped() async {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array(
                ["annotations", "attach", "blkio_config", "build", "image"]
                    .map(schemaPropertyItemJSON(label:))
            ),
        ])))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(prefix: "ima", offset: identifierCaret)
        )

        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(
            items.map(\.text),
            ["image:\n  ", "annotations:\n  ", "attach:\n  ", "blkio_config:\n  ", "build:\n  "]
        )
    }

    /// An empty prefix puts every item in the same half, so D6's order is the
    /// whole order — the bare-dot member case, and the deliberate "show me
    /// everything".
    func testAnEmptyPrefixLeavesTheServersOrderAloneEntirely() async {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array(
                ["image", "annotations", "attach"].map(schemaPropertyItemJSON(label:))
            ),
        ])))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(prefix: "", offset: identifierCaret)
        )

        XCTAssertEqual(items.map(\.text), ["annotations:\n  ", "attach:\n  ", "image:\n  "])
    }

    // MARK: - Multi-line insertion

    /// `yaml-language-server` spells the lines after the first **relative to the
    /// item** — an object-valued property is `deploy:\n  ` at every nesting depth,
    /// verified against the pinned server — so inserting it verbatim four columns
    /// in would leave the caret at column 2, under the grandparent key. LSP's
    /// `insertTextMode.adjustIndentation` is applied here instead.
    func testMultiLineInsertedTextIsIndentedToTheLineItLandsOn() async {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array([schemaPropertyItemJSON(label: "deploy")])
        ])))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(prefix: "dep", offset: nestedCaret, text: nestedYAML)
        )

        XCTAssertEqual(items.map(\.text), ["deploy:\n      "])
    }

    /// The rule is the caret's line, not the item's: the same item at column 0
    /// inserts exactly what the server sent. Single-line text is the same string
    /// under either branch, which is the case every other server produces.
    func testInsertedTextAtColumnZeroAndSingleLineTextAreUntouched() async {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array([
                schemaPropertyItemJSON(label: "deploy"),
                completionItemJSON(label: "image", sortText: "zz", insertText: "image: "),
            ]),
        ])))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(prefix: "", offset: topLevelCaret, text: nestedYAML)
        )

        XCTAssertEqual(items.map(\.text), ["deploy:\n  ", "image: "])
    }

    /// The indentation the spec names is the line's **up to the cursor**, so a
    /// caret standing inside the leading run indents to where it stands rather
    /// than to where the run happens to end.
    func testIndentationIsMeasuredUpToTheInsertionPointRatherThanPastIt() async {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array([schemaPropertyItemJSON(label: "deploy")])
        ])))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(
                prefix: "",
                offset: nestedCaret - 5,
                text: nestedYAML
            )
        )

        XCTAssertEqual(items.map(\.text), ["deploy:\n    "])
    }

    /// CRLF is one `Character` and is not `"\n"`, so a grapheme test for the
    /// newline answers `false` for exactly the text the splitter goes on to split
    /// — the guard and the split have to agree on what a newline is, or a
    /// CRLF-spelled multi-line insertion is written to the file unindented.
    func testMultiLineInsertedTextIsIndentedWhenItsLineBreaksAreCRLF() async {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array([
                .object([
                    "label": .string("deploy"),
                    "insertText": .string("deploy:\r\n  "),
                    "insertTextFormat": .int(2),
                    "kind": .int(LSPCompletionItemKind.property.rawValue),
                ]),
            ]),
        ])))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(prefix: "dep", offset: nestedCaret, text: nestedYAML)
        )

        XCTAssertEqual(items.map(\.text), ["deploy:\r\n      "])
    }

    /// A line the server left empty stays empty: indenting it would write trailing
    /// whitespace into a blank line nobody asked to touch.
    func testABlankContinuationLineIsLeftEmptyRatherThanIndented() async {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array([
                .object([
                    "label": .string("deploy"),
                    "insertText": .string("deploy:\n\n  "),
                    "insertTextFormat": .int(2),
                    "kind": .int(LSPCompletionItemKind.property.rawValue),
                ]),
            ]),
        ])))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(prefix: "dep", offset: nestedCaret, text: nestedYAML)
        )

        XCTAssertEqual(items.map(\.text), ["deploy:\n\n      "])
    }

    /// The same rule under CRLF, where it is not the same test: splitting on `\n`
    /// leaves each line's terminating `\r` on the *previous* component, so a blank
    /// line arrives as `"\r"` and an `isEmpty` test would indent it — putting two
    /// spaces of trailing whitespace into the file on the one path in this layer
    /// that writes to it.
    func testABlankCRLFContinuationLineIsLeftEmptyRatherThanIndented() async {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array([
                .object([
                    "label": .string("deploy"),
                    "insertText": .string("deploy:\r\n\r\n  "),
                    "insertTextFormat": .int(2),
                    "kind": .int(LSPCompletionItemKind.property.rawValue),
                ]),
            ]),
        ])))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(prefix: "dep", offset: nestedCaret, text: nestedYAML)
        )

        XCTAssertEqual(items.map(\.text), ["deploy:\r\n\r\n      "])
    }

    /// `insertTextMode: 1` is `asIs` — the server stating that its continuation
    /// lines are already spelled against the buffer. Indenting those would indent
    /// them twice, so the item is taken at its word and inserted verbatim.
    func testAnItemThatAsksForAsIsInsertionIsNotIndented() async {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array([
                .object([
                    "label": .string("deploy"),
                    "insertText": .string("deploy:\n      "),
                    "insertTextFormat": .int(2),
                    "insertTextMode": .int(1),
                    "kind": .int(LSPCompletionItemKind.property.rawValue),
                ]),
            ]),
        ])))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(prefix: "dep", offset: nestedCaret, text: nestedYAML)
        )

        XCTAssertEqual(items.map(\.text), ["deploy:\n      "])
    }

    /// The other value, and the absent case the pinned servers all send, both go
    /// through the rule: `2` *is* `adjustIndentation`, and nothing is assumed from
    /// silence beyond what this client already does.
    func testAnItemThatAsksForAdjustedIndentationIsIndentedLikeOneThatSaysNothing() async {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array([
                .object([
                    "label": .string("deploy"),
                    "insertText": .string("deploy:\n  "),
                    "insertTextFormat": .int(2),
                    "insertTextMode": .int(2),
                    "kind": .int(LSPCompletionItemKind.property.rawValue),
                ]),
            ]),
        ])))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(prefix: "dep", offset: nestedCaret, text: nestedYAML)
        )

        XCTAssertEqual(items.map(\.text), ["deploy:\n      "])
    }

    /// The edit the editor applies carries the adjusted text too — the row, the
    /// dedup key and the buffer must be one string. An `additionalTextEdits`
    /// entry makes `edits(…)` non-empty, which is the path that writes the file
    /// itself rather than leaving the insertion to AppKit.
    func testTheEmittedEditCarriesTheIndentedTextRatherThanTheRawOne() async {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array([
                .object([
                    "label": .string("deploy"),
                    "insertTextFormat": .int(2),
                    "kind": .int(LSPCompletionItemKind.property.rawValue),
                    "insertText": .string("deploy:\n  "),
                    "additionalTextEdits": .array([
                        .object([
                            "newText": .string("# generated\n"),
                            "range": .object([
                                "start": .object(["line": .int(0), "character": .int(0)]),
                                "end": .object(["line": .int(0), "character": .int(0)]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ])))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(prefix: "dep", offset: nestedCaret, text: nestedYAML)
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(
            items.first?.edits.first { $0.role == .primary }?.newText,
            "deploy:\n      "
        )
    }

    /// Authored rather than recorded: this server produced no two items with the
    /// same `sortText`, and "preserve the server's order on a tie" is exactly the
    /// rule a non-stable sort would break.
    func testItemsTiedOnSortTextKeepTheServersOwnOrder() async {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array([
                completionItemJSON(label: "beta", sortText: "100"),
                completionItemJSON(label: "alpha", sortText: "100"),
                completionItemJSON(label: "gamma", sortText: "100"),
            ]),
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
                completionItemJSON(label: "Greeting", sortText: "400"),
            ]),
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
                completionItemJSON(
                    label: "Greeting",
                    sortText: "200",
                    insertText: "Greeting(${1:name})",
                    insertTextFormat: 2
                ),
                completionItemJSON(label: "GreeterBox", sortText: "300", insertTextFormat: 1),
            ]),
        ])))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(prefix: "Gree", offset: identifierCaret)
        )

        XCTAssertEqual(items.map(\.text), ["Greeter", "GreeterBox"])
    }

    /// The other half of the same rule, and the one that decides whether the
    /// provisioned YAML server contributes anything at all: it marks **every**
    /// property completion `Snippet` and never reads `snippetSupport`, so the
    /// flag on its own is not a fact. An item that claims snippet format but
    /// whose text contains neither of the grammar's two entry points (`$`, `\\`)
    /// is the same string under both formats — dropping it would throw away a
    /// completion for nothing.
    func testASnippetFormatItemWithNoSnippetSyntaxIsKeptAsLiteralText() async {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array([
                completionItemJSON(
                    label: "greeters",
                    sortText: "100",
                    insertText: "greeters:\n  ",
                    insertTextFormat: 2
                ),
                completionItemJSON(
                    label: "greeting",
                    sortText: "200",
                    insertText: "greeting: $1",
                    insertTextFormat: 2
                ),
                completionItemJSON(
                    label: "greetingEscaped",
                    sortText: "300",
                    insertText: "greetingEscaped: \\}",
                    insertTextFormat: 2
                ),
            ]),
        ])))
        let provider = makeProvider()

        let items = await provider.completions(
            for: completionRequest(prefix: "gree", offset: identifierCaret)
        )

        // Only the placeholder-free one survives, and it arrives verbatim — the
        // colon, newline and indent are what the server meant to insert, and what
        // makes this a schema completion rather than a word. It carries no edits,
        // so AppKit inserts `text` over the typed prefix itself, exactly as it
        // does for a tree-sitter item.
        XCTAssertEqual(items.map(\.text), ["greeters:\n  "])
        XCTAssertEqual(items.first?.displayText, "greeters:\n  ")
        XCTAssertEqual(items.first?.edits, [])
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
                ),
            ]),
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
                ),
            ]),
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
                ),
            ]),
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
                ),
            ]),
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

    /// Authored, and narrow on purpose: two items whose `newText` is the same
    /// string over *different* ranges are two different rows, because the head
    /// a row may drop is read off its own range. The first here reads as the
    /// typed word and is dropped; the second reads `.greet` and is a real
    /// candidate, so the dedup key must still be free when it is reached — a row
    /// nobody is offered may not spend it.
    func testARowDroppedOnItsDisplayDoesNotConsumeTheDedupKey() async throws {
        transport.script(LSPMethod.completion, .reply(.object([
            "items": .array([
                completionItemJSON(
                    label: "greet",
                    sortText: "100",
                    // The dot and the member standing after it: reads `greet`.
                    textEdit: (startLine: 4, startCharacter: 21, endLine: 4, endCharacter: 27),
                    textEditNewText: ".greet"
                ),
                completionItemJSON(
                    label: "greet",
                    sortText: "101",
                    // Empty, at the caret: nothing to drop, so it reads `.greet`.
                    textEdit: (startLine: 4, startCharacter: 27, endLine: 4, endCharacter: 27),
                    textEditNewText: ".greet"
                ),
            ]),
        ])))
        let provider = makeProvider()
        let caret = (mainSource as NSString).range(of: "greeter.greet").upperBound

        let items = await provider.completions(
            for: CompletionRequest(
                prefix: "greet",
                fileURL: mainFile,
                text: mainSource,
                language: .swift,
                member: IdentifierScanner.MemberContext(
                    receiver: "greeter",
                    prefixRange: NSRange(location: caret - 5, length: 5)
                ),
                offset: caret
            )
        )

        XCTAssertEqual(items.map(\.displayText), [".greet"])
        XCTAssertEqual(items.map(\.text), [".greet"])
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
                ],
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

    /// One `yaml-language-server` property completion, as that server really
    /// spells it: no `sortText`, no `filterText`, `insertTextFormat: 2` on text
    /// that carries no snippet syntax, and a value the schema wants indented
    /// under the key.
    private func schemaPropertyItemJSON(label: String) -> JSONValue {
        .object([
            "label": .string(label),
            "insertText": .string("\(label):\n  "),
            "insertTextFormat": .int(2),
            "kind": .int(LSPCompletionItemKind.property.rawValue),
        ])
    }

    /// One completion item as the wire spells it — the authored counterpart to
    /// the recorded fixtures, for the three shapes this server never produced.
    private func completionItemJSON(
        label: String,
        sortText: String,
        detail: String? = nil,
        insertText: String? = nil,
        insertTextFormat: Int? = 1,
        textEdit: (startLine: Int, startCharacter: Int, endLine: Int, endCharacter: Int)? = nil,
        textEditNewText: String? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "label": .string(label),
            "sortText": .string(sortText),
            "insertText": .string(insertText ?? label),
            "filterText": .string(label),
            "kind": .int(LSPCompletionItemKind.struct.rawValue),
        ]
        if let insertTextFormat { object["insertTextFormat"] = .int(insertTextFormat) }
        if let detail { object["detail"] = .string(detail) }
        if let textEdit {
            object["textEdit"] = .object([
                "newText": .string(textEditNewText ?? label),
                "range": .object([
                    "start": .object([
                        "line": .int(textEdit.startLine),
                        "character": .int(textEdit.startCharacter),
                    ]),
                    "end": .object([
                        "line": .int(textEdit.endLine),
                        "character": .int(textEdit.endCharacter),
                    ]),
                ]),
            ])
        }
        return .object(object)
    }
}
