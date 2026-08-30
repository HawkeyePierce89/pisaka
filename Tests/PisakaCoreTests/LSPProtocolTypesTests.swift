import XCTest
@testable import PisakaCore

/// The LSP message bodies, pinned against a **real** server's output.
///
/// The fixtures in `Fixtures/LSP/` were recorded from the `sourcekit-lsp` in
/// Xcode 26.6 and are read here through `#filePath`, in the same style as
/// `SymbolQueryTests` and `ReleaseMetadataTests` — Foundation only, no bundle, no
/// SwiftPM resource, and no process ever spawned by `swift test`. That is the
/// point: a decoder written against a remembered reading of the specification
/// passes its own tests and then meets a server that spells `result: null` where
/// an empty array was expected. `Fixtures/LSP/README.md` records how each file
/// was produced, and marks the two shapes that are authored rather than
/// recorded.
///
/// The suite runs in two halves. *Decoding* is asserted against those
/// transcripts. *Encoding* is asserted on exact bytes, because a request is
/// read by a program nobody here controls: the failure mode of a wrong capability
/// or a mis-spelled parameter is not a crash but silence — the server answers
/// something unhelpful, the provider falls back, and the feature simply never
/// works.
final class LSPProtocolTypesTests: XCTestCase {
    // MARK: - Fixtures

    /// The repository root, from this file's own compile-time path
    /// (`<root>/Tests/PisakaCoreTests/<this file>`).
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private static let fixtures = repositoryRoot
        .appendingPathComponent("Tests/PisakaCoreTests/Fixtures/LSP")

    /// The recorded project root the fixtures' URIs point into — `/tmp` as the
    /// server resolved it, `/private/tmp` and all.
    private static let recordedRoot = "file:///private/tmp/lspfix/pkg"

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
    }

    /// A fixture is a whole recorded *response envelope*; this is the two-step
    /// every test takes — envelope first, then the typed body — which is exactly
    /// the path `LSPSession` will take at runtime.
    private func result<T: Decodable>(of name: String, as type: T.Type) throws -> T {
        let message = try LSPIncomingMessage.decode(try fixture(name))
        guard case .response(let response) = message else {
            throw XCTSkip("\(name) is not a response")
        }
        XCTAssertNil(response.error, "\(name) recorded an error response")
        let value = try XCTUnwrap(response.result, "\(name) has no `result` member")
        return try value.decoded(as: T.self)
    }

    /// A bare JSON body — the `result` member of a response, written inline
    /// where a recorded transcript would be more ceremony than the shape being
    /// pinned deserves.
    private func decodeResult<T: Decodable>(_ body: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode([T].self, from: Data("[\(body)]".utf8))[0]
    }

    private func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Every fixture still parses as the kind of thing it was recorded as, so a
    /// file edited by hand into something illegal fails here rather than in
    /// whichever suite happens to read it next — including the ones later phases
    /// will add.
    ///
    /// Two kinds live in the directory: recorded *responses* (whole envelopes)
    /// and the one recorded set of request *params*, distinguished by a
    /// `-request` suffix. The distinction is real rather than cosmetic — params
    /// have no `jsonrpc`, no `id` and no `method`, so decoding one as a message
    /// is a decode failure, not a lenient no-op.
    func testEveryFixtureIsReadableAndIsWhatItsNameSaysItIs() throws {
        let names = try FileManager.default
            .contentsOfDirectory(atPath: Self.fixtures.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
        XCTAssertFalse(names.isEmpty, "the fixture directory is empty")
        for name in names {
            if name.hasSuffix("-request.json") {
                XCTAssertNoThrow(
                    try JSONDecoder().decode(
                        LSPCompletionItem.self,
                        from: try fixture(name)
                    ),
                    "\(name) does not decode as request params"
                )
            } else {
                XCTAssertNoThrow(
                    try LSPIncomingMessage.decode(try fixture(name)),
                    "\(name) does not decode as an LSP message"
                )
            }
        }
    }

    // MARK: - initialize

    func testInitializeResultDecodesTheCapabilitiesThisPhaseActsOn() throws {
        let result = try result(of: "initialize-result.json", as: LSPInitializeResult.self)
        XCTAssertTrue(result.capabilities.supportsDefinition)
        // The recorded sourcekit-lsp advertises `hoverProvider: true`; D25 asks
        // nothing at all of a server that does not.
        XCTAssertTrue(result.capabilities.supportsHover)
        XCTAssertTrue(result.capabilities.supportsCompletion)
        XCTAssertTrue(result.capabilities.resolvesCompletionItems)
        XCTAssertEqual(result.capabilities.completionTriggerCharacters, [".", "("])
    }

    /// The recorded server omits `positionEncoding` entirely, which the spec says
    /// means utf-16 — the encoding every offset in this codebase assumes. Absence
    /// must therefore read as agreement, not as "unknown, fall back".
    func testAnAbsentPositionEncodingMeansUTF16() throws {
        let result = try result(of: "initialize-result.json", as: LSPInitializeResult.self)
        XCTAssertNil(result.capabilities.positionEncoding)
        XCTAssertTrue(result.capabilities.usesUTF16Positions)
    }

    func testAnExplicitUTF8EncodingIsNotAccepted() throws {
        // The one answer that makes every position wrong in any file containing a
        // non-ASCII character — and wrong *quietly*, which is why it is a flag
        // the workspace can refuse on rather than something to paper over.
        let capabilities = try JSONDecoder().decode(
            LSPServerCapabilities.self,
            from: Data(#"{"positionEncoding":"utf-8","definitionProvider":true}"#.utf8)
        )
        XCTAssertFalse(capabilities.usesUTF16Positions)
    }

    func testProvidersSpelledAsOptionsObjectsCountAsSupported() throws {
        // `definitionProvider` is `boolean | DefinitionOptions`; a server sending
        // `{}` supports definitions. Reading only the boolean spelling would
        // silently disable the feature for every server that sends the other one.
        let capabilities = try JSONDecoder().decode(
            LSPServerCapabilities.self,
            from: (
                #"{"definitionProvider":{},"hoverProvider":{"workDoneProgress":true},"#
                    + #""completionProvider":{"resolveProvider":false}}"#
            ).utf8Data
        )
        XCTAssertTrue(capabilities.supportsDefinition)
        XCTAssertTrue(capabilities.supportsHover)
        XCTAssertTrue(capabilities.supportsCompletion)
        XCTAssertFalse(capabilities.resolvesCompletionItems)
    }

    func testAbsentOrFalseProvidersCountAsUnsupported() throws {
        let capabilities = try JSONDecoder().decode(
            LSPServerCapabilities.self,
            from: Data(#"{"definitionProvider":false,"hoverProvider":false}"#.utf8)
        )
        XCTAssertFalse(capabilities.supportsDefinition)
        // Both spellings of "no": stated false, and never mentioned at all.
        XCTAssertFalse(capabilities.supportsHover)
        XCTAssertFalse(capabilities.supportsCompletion)
    }

    func testReferencesAndRenameDecodeThroughTheSameCollapse() throws {
        // Both providers are `boolean | Options` like every other one here, and
        // `renameProvider`'s options spelling is the one servers actually use
        // (it is where `prepareProvider` lives).
        let optionsSpelling = try JSONDecoder().decode(
            LSPServerCapabilities.self,
            from: (
                #"{"referencesProvider":{"workDoneProgress":true},"#
                    + #""renameProvider":{"prepareProvider":true}}"#
            ).utf8Data
        )
        XCTAssertTrue(optionsSpelling.supportsReferences)
        XCTAssertTrue(optionsSpelling.supportsRename)

        let booleanSpelling = try JSONDecoder().decode(
            LSPServerCapabilities.self,
            from: Data(#"{"referencesProvider":true,"renameProvider":true}"#.utf8)
        )
        XCTAssertTrue(booleanSpelling.supportsReferences)
        XCTAssertTrue(booleanSpelling.supportsRename)

        let empty = try JSONDecoder().decode(
            LSPServerCapabilities.self,
            from: Data(#"{"referencesProvider":{},"renameProvider":{}}"#.utf8)
        )
        XCTAssertTrue(empty.supportsReferences)
        XCTAssertTrue(empty.supportsRename)
    }

    func testEveryWayOfSayingNoToReferencesAndRename() throws {
        // Stated false, explicitly null, and never mentioned at all — three
        // spellings of the same answer, and the initializer's own defaults are
        // the fourth.
        let stated = try JSONDecoder().decode(
            LSPServerCapabilities.self,
            from: Data(#"{"referencesProvider":false,"renameProvider":false}"#.utf8)
        )
        XCTAssertFalse(stated.supportsReferences)
        XCTAssertFalse(stated.supportsRename)

        let explicitNull = try JSONDecoder().decode(
            LSPServerCapabilities.self,
            from: Data(#"{"referencesProvider":null,"renameProvider":null}"#.utf8)
        )
        XCTAssertFalse(explicitNull.supportsReferences)
        XCTAssertFalse(explicitNull.supportsRename)

        let absent = try JSONDecoder().decode(
            LSPServerCapabilities.self,
            from: Data(#"{"definitionProvider":true}"#.utf8)
        )
        XCTAssertFalse(absent.supportsReferences)
        XCTAssertFalse(absent.supportsRename)

        XCTAssertFalse(LSPServerCapabilities().supportsReferences)
        XCTAssertFalse(LSPServerCapabilities().supportsRename)
    }

    func testAServerThatNeverMentionsHoverDoesNotSupportIt() throws {
        let capabilities = try JSONDecoder().decode(
            LSPServerCapabilities.self,
            from: Data(#"{"definitionProvider":true}"#.utf8)
        )
        XCTAssertTrue(capabilities.supportsDefinition)
        XCTAssertFalse(capabilities.supportsHover)
    }

    /// The capability block is asserted byte for byte because it is a *promise*:
    /// each flag tells the server what this editor can handle. Advertising
    /// `snippetSupport` would start `${1:placeholder}` arriving in `newText`
    /// (D5); dropping `linkSupport` would cost every jump its identifier range;
    /// omitting `resolveSupport` would mean auto-import edits never arrive at all
    /// (D4); and `workspace.workspaceEdit.resourceOperations: []` is what tells a
    /// server not to answer a rename with a create/rename/delete entry —
    /// `LSPWorkspaceEdit` drops one and applies the textual half, which for a
    /// module rename is every reference renamed and the file still under its old
    /// name. None of those fail a build or throw — they just make the feature
    /// quietly worse — so the exact promise is pinned here.
    func testClientCapabilitiesAdvertiseExactlyThisPhasesSurface() throws {
        XCTAssertEqual(
            try json(LSPClientCapabilities()),
            """
            {"general":{"positionEncodings":["utf-16"]},\
            "textDocument":{\
            "completion":{\
            "completionItem":{\
            "commitCharactersSupport":false,\
            "deprecatedSupport":false,\
            "documentationFormat":["plaintext"],\
            "insertReplaceSupport":false,\
            "preselectSupport":false,\
            "resolveSupport":{"properties":["detail","additionalTextEdits"]},\
            "snippetSupport":false},\
            "completionItemKind":{"valueSet":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25]},\
            "contextSupport":true,\
            "dynamicRegistration":false},\
            "definition":{"dynamicRegistration":false,"linkSupport":true},\
            "hover":{"contentFormat":["markdown","plaintext"],"dynamicRegistration":false},\
            "publishDiagnostics":{"relatedInformation":false,"versionSupport":true},\
            "references":{"dynamicRegistration":false},\
            "rename":{"dynamicRegistration":false,"honorsChangeAnnotations":false,\
            "prepareSupport":false},\
            "synchronization":{"didSave":false,"dynamicRegistration":false,\
            "willSave":false,"willSaveWaitUntil":false}},\
            "workspace":{"configuration":false,\
            "workspaceEdit":{"documentChanges":false,"failureHandling":"abort",\
            "normalizesLineEndings":false,"resourceOperations":[]},\
            "workspaceFolders":false}}
            """
        )
    }

    func testInitializeParamsWriteNullRatherThanOmittingProcessIdAndTheTwoRoots() throws {
        // All three are `T | null` in the spec, and a server may reject a request
        // that omits them outright — `encodeIfPresent` would do exactly that.
        let params = LSPInitializeParams(processId: nil, rootUri: nil)
        let encoded = try json(params)
        XCTAssertTrue(encoded.contains(#""processId":null"#), encoded)
        XCTAssertTrue(encoded.contains(#""rootUri":null"#), encoded)
        XCTAssertTrue(encoded.contains(#""rootPath":null"#), encoded)
        XCTAssertFalse(encoded.contains("initializationOptions"), encoded)
    }

    func testInitializeParamsCarryClientInfoAndInitializationOptions() throws {
        let params = LSPInitializeParams(
            processId: 4242,
            clientInfo: LSPClientInfo(name: "Pisaka", version: "1.0"),
            rootUri: Self.recordedRoot,
            initializationOptions: .object(["backgroundIndexing": .bool(true)])
        )
        let encoded = try json(params)
        XCTAssertTrue(encoded.contains(#""processId":4242"#), encoded)
        XCTAssertTrue(encoded.contains(#""clientInfo":{"name":"Pisaka","version":"1.0"}"#), encoded)
        XCTAssertTrue(encoded.contains(#""rootUri":"\#(Self.recordedRoot)""#), encoded)
        XCTAssertTrue(encoded.contains(#""initializationOptions":{"backgroundIndexing":true}"#), encoded)
    }

    /// The deprecated key is sent *as well as* `rootUri`, never instead of it:
    /// pyright reads only this one, sourcekit-lsp and typescript-language-server
    /// only the other. Dropping either half silently disables one of them.
    func testInitializeParamsCarryTheRootAsAPathBesideTheURI() throws {
        let params = LSPInitializeParams(
            processId: 4242,
            rootUri: Self.recordedRoot,
            rootPath: "/tmp/Project"
        )
        let encoded = try json(params)
        XCTAssertTrue(encoded.contains(#""rootUri":"\#(Self.recordedRoot)""#), encoded)
        XCTAssertTrue(encoded.contains(#""rootPath":"/tmp/Project""#), encoded)
    }

    // MARK: - Document sync (D2)

    func testDidOpenParamsEncodeTheWholeDocument() throws {
        let params = LSPDidOpenTextDocumentParams(
            textDocument: LSPTextDocumentItem(
                uri: "\(Self.recordedRoot)/Sources/App/main.swift",
                languageId: "swift",
                version: 1,
                text: "import Core\n"
            )
        )
        XCTAssertEqual(
            try json(params),
            """
            {"textDocument":{"languageId":"swift",\
            "text":"import Core\\n",\
            "uri":"file:///private/tmp/lspfix/pkg/Sources/App/main.swift",\
            "version":1}}
            """
        )
    }

    /// Full sync (D2): one change entry, no `range` member at all. A `range`
    /// present but null would be read as an incremental edit of nothing.
    func testDidChangeParamsSendTheWholeTextWithNoRange() throws {
        let params = LSPDidChangeTextDocumentParams(
            uri: "\(Self.recordedRoot)/Sources/App/main.swift",
            version: 7,
            fullText: "let a = 1\n"
        )
        XCTAssertEqual(
            try json(params),
            """
            {"contentChanges":[{"text":"let a = 1\\n"}],\
            "textDocument":{"uri":"file:///private/tmp/lspfix/pkg/Sources/App/main.swift","version":7}}
            """
        )
    }

    func testDidCloseParamsCarryOnlyTheURI() throws {
        XCTAssertEqual(
            try json(LSPDidCloseTextDocumentParams(uri: "file:///a/b.swift")),
            #"{"textDocument":{"uri":"file:///a/b.swift"}}"#
        )
    }

    func testAnIncrementalChangeEventStillRoundTrips() throws {
        // Never sent, but a transcript of some other client must not fail to
        // decode through these types.
        let event = LSPTextDocumentContentChangeEvent(
            range: LSPRange(
                start: LSPPosition(line: 1, character: 0),
                end: LSPPosition(line: 1, character: 4)
            ),
            text: "x"
        )
        let decoded = try JSONDecoder().decode(
            LSPTextDocumentContentChangeEvent.self,
            from: try JSONEncoder().encode(event)
        )
        XCTAssertEqual(decoded, event)
    }

    // MARK: - textDocument/definition

    func testDefinitionParamsEncodeAsAPositionRequest() throws {
        let params = LSPTextDocumentPositionParams(
            uri: "file:///a/b.swift",
            position: LSPPosition(line: 3, character: 16)
        )
        XCTAssertEqual(
            try json(params),
            #"{"position":{"character":16,"line":3},"textDocument":{"uri":"file:///a/b.swift"}}"#
        )
    }

    /// The recorded cross-module jump: `Greeter` in `main.swift`, answered with
    /// **two** plain `Location`s in another module's file (the type and its
    /// `init`). Two is not a mistake to collapse — it is why the picker exists.
    func testCrossModuleDefinitionDecodesEveryRecordedLocation() throws {
        let response = try result(of: "definition-cross-module.json", as: LSPDefinitionResponse.self)
        XCTAssertEqual(response.targets.count, 2)
        for target in response.targets {
            XCTAssertEqual(target.uri, "\(Self.recordedRoot)/Sources/Core/Greeter.swift")
            // A plain `Location` carries no identifier range, so a jump uses the
            // range it did send.
            XCTAssertNil(target.selectionRange)
            XCTAssertEqual(target.jumpRange, target.range)
        }
        XCTAssertEqual(response.targets[0].range, LSPRange(at: LSPPosition(line: 1, character: 14)))
        XCTAssertEqual(response.targets[1].range, LSPRange(at: LSPPosition(line: 4, character: 11)))
    }

    /// The SDK jump: a target under `/var/folders/…`, outside every project root
    /// — the case D3 routes to a read-only window. Nothing here decides that;
    /// what is pinned is that the URI survives intact so the decision *can* be
    /// made.
    func testSDKDefinitionDecodesATargetOutsideTheProjectRoot() throws {
        let response = try result(of: "definition-sdk.json", as: LSPDefinitionResponse.self)
        let target = try XCTUnwrap(response.targets.first)
        XCTAssertTrue(target.uri.hasSuffix("Swift.String.swiftinterface"), target.uri)
        XCTAssertFalse(target.uri.hasPrefix(Self.recordedRoot))
        XCTAssertEqual(target.range.start.line, 18545)
    }

    /// `"result": null` — a real answer meaning "nothing found", not a decode
    /// failure and not an error response.
    func testADefinitionThatFoundNothingDecodesAsNoTargets() throws {
        let response = try result(of: "definition-none.json", as: LSPDefinitionResponse.self)
        XCTAssertTrue(response.isEmpty)
    }

    /// `LocationLink[]` — the shape that carries `targetSelectionRange`, which is
    /// the identifier rather than the whole declaration, and so the better place
    /// to land a caret.
    func testLocationLinkResultPrefersTheSelectionRangeForJumping() throws {
        let response = try result(of: "definition-location-link.json", as: LSPDefinitionResponse.self)
        let target = try XCTUnwrap(response.targets.first)
        XCTAssertEqual(
            target.range,
            LSPRange(
                start: LSPPosition(line: 1, character: 0),
                end: LSPPosition(line: 11, character: 1)
            )
        )
        XCTAssertEqual(
            target.selectionRange,
            LSPRange(
                start: LSPPosition(line: 1, character: 14),
                end: LSPPosition(line: 1, character: 21)
            )
        )
        XCTAssertEqual(target.jumpRange, target.selectionRange)
        XCTAssertEqual(
            target.originSelectionRange,
            LSPRange(
                start: LSPPosition(line: 3, character: 14),
                end: LSPPosition(line: 3, character: 21)
            )
        )
    }

    func testASingleBareLocationDecodesToOneTarget() throws {
        // The third legal spelling, which no recorded fixture uses.
        let response = try JSONDecoder().decode(
            LSPDefinitionResponse.self,
            from: (
                #"{"uri":"file:///a.swift","range":{"start":{"line":2,"character":1},"#
                    + #""end":{"line":2,"character":5}}}"#
            ).utf8Data
        )
        XCTAssertEqual(response.targets.count, 1)
        XCTAssertEqual(response.targets[0].uri, "file:///a.swift")
    }

    func testAnEmptyArrayIsTheSameAnswerAsNull() throws {
        let response = try JSONDecoder().decode(LSPDefinitionResponse.self, from: Data("[]".utf8))
        XCTAssertTrue(response.isEmpty)
    }

    func testAnUnrecognisedDefinitionShapeThrowsRatherThanDecodingToNothing() {
        // "Nothing found" and "I could not read the answer" must stay
        // distinguishable: the first is a beep, the second is a fallback.
        XCTAssertThrowsError(
            try JSONDecoder().decode(LSPDefinitionResponse.self, from: Data(#""nonsense""#.utf8))
        )
    }

    // MARK: - textDocument/hover

    /// Hover asks the same question definition does — the params type is shared,
    /// so what is pinned here is that nothing extra is sent with it.
    func testHoverParamsEncodeAsAPlainPositionRequest() throws {
        let params = LSPTextDocumentPositionParams(
            uri: "file:///a/b.swift",
            position: LSPPosition(line: 7, character: 3)
        )
        XCTAssertEqual(
            try json(params),
            #"{"position":{"character":3,"line":7},"textDocument":{"uri":"file:///a/b.swift"}}"#
        )
    }

    private func hover(_ json: String) throws -> LSPHoverResponse {
        try JSONDecoder().decode(LSPHoverResponse.self, from: Data(json.utf8))
    }

    /// The shape sourcekit-lsp and rust-analyzer both answer with: one
    /// `MarkupContent`, the signature fenced inside it, plus the range of the
    /// identifier asked about.
    func testAMarkupContentHoverDecodesWithItsKindAndRange() throws {
        let response = try hover(
            #"{"contents":{"kind":"markdown","value":"```swift\nfunc greet()\n```"},"#
                + #""range":{"start":{"line":3,"character":14},"end":{"line":3,"character":19}}}"#
        )
        XCTAssertEqual(
            response.elements,
            [.markup(kind: .markdown, value: "```swift\nfunc greet()\n```")]
        )
        XCTAssertEqual(
            response.range,
            LSPRange(
                start: LSPPosition(line: 3, character: 14),
                end: LSPPosition(line: 3, character: 19)
            )
        )
    }

    /// A bare string is a `MarkedString`, and the spec says a bare
    /// `MarkedString` is markdown — reading it as plain text would leave every
    /// fence visible in the popover.
    func testABareStringContentsIsMarkdown() throws {
        let response = try hover(#"{"contents":"**Greeter**"}"#)
        XCTAssertEqual(response.elements, [.markup(kind: .markdown, value: "**Greeter**")])
        XCTAssertNil(response.range)
    }

    /// The other `MarkedString`: an object naming a language, which *is* a code
    /// block whole. The language is what the renderer distinguishes code from
    /// prose by, so it must survive the decode.
    func testAMarkedStringObjectDecodesAsCodeInItsLanguage() throws {
        let response = try hover(#"{"contents":{"language":"swift","value":"let a: Int"}}"#)
        XCTAssertEqual(response.elements, [.code(language: "swift", value: "let a: Int")])
    }

    /// gopls's shape: an array mixing both spellings. Order is the server's and
    /// is never rearranged — the signature comes first and its documentation
    /// after, and swapping them is a different answer.
    func testAnArrayMixingBothMarkedStringSpellingsKeepsOrderAndLanguages() throws {
        let response = try hover(
            #"{"contents":[{"language":"go","value":"func Greet(name string)"},"#
                + #""Greet writes a greeting.",{"language":"","value":"plain block"}]}"#
        )
        XCTAssertEqual(
            response.elements,
            [
                .code(language: "go", value: "func Greet(name string)"),
                .markup(kind: .markdown, value: "Greet writes a greeting."),
                // A `MarkedString` naming an empty language is still a code
                // block; it just does not say which language to colour it as.
                .code(language: nil, value: "plain block"),
            ]
        )
    }

    func testANullHoverResultIsNoElementsAndNoRange() throws {
        let response = try hover("null")
        XCTAssertTrue(response.isEmpty)
        XCTAssertNil(response.range)
    }

    func testAnEmptyContentsArrayIsTheSameAnswerAsNull() throws {
        let response = try hover(#"{"contents":[]}"#)
        XCTAssertTrue(response.isEmpty)
    }

    func testAHoverWithNoContentsMemberIsTheSameAnswerAsNull() throws {
        let response = try hover(#"{"range":{"start":{"line":0,"character":0},"#
            + #""end":{"line":0,"character":1}}}"#)
        XCTAssertTrue(response.isEmpty)
        // The range still decodes — this layer reports what arrived; whether it
        // is worth showing is `HoverContent`'s question.
        XCTAssertNotNil(response.range)
    }

    /// An empty string is a legal `MarkedString`. It stays an element here on
    /// purpose: the protocol layer reports what the server said, and "this
    /// normalizes to nothing, so show no popover" is the next layer's rule.
    func testAnEmptyStringContentsIsAnElementCarryingNothing() throws {
        let response = try hover(#"{"contents":""}"#)
        XCTAssertEqual(response.elements, [.markup(kind: .markdown, value: "")])
        XCTAssertFalse(response.isEmpty)
        XCTAssertEqual(response.elements.first?.value, "")
    }

    /// Lenient decoding, case one: a `kind` from a newer specification must not
    /// cost the answer. Plain text is the safe reading — the worst it does is
    /// leave a marker visible.
    func testAnUnknownMarkupKindDegradesToPlainText() throws {
        let response = try hover(#"{"contents":{"kind":"asciidoc","value":"= Title"}}"#)
        XCTAssertEqual(response.elements, [.markup(kind: .plaintext, value: "= Title")])
        XCTAssertEqual(LSPMarkupKind(spelling: nil), .plaintext)
        XCTAssertEqual(LSPMarkupKind(spelling: "markdown"), .markdown)
        XCTAssertEqual(LSPMarkupKind(spelling: "plaintext"), .plaintext)
    }

    /// Lenient decoding, case two: one unreadable element is dropped, and the
    /// elements around it still arrive. Failing the whole decode would trade a
    /// good signature for a server's stray `null`.
    func testAMalformedElementIsDroppedRatherThanFailingTheWholeAnswer() throws {
        let response = try hover(
            #"{"contents":[{"language":"swift","value":"let a: Int"},null,{"nope":1},"#
                + #""documentation"]}"#
        )
        XCTAssertEqual(
            response.elements,
            [
                .code(language: "swift", value: "let a: Int"),
                .markup(kind: .markdown, value: "documentation"),
            ]
        )
    }

    /// Neither `kind` nor `language`, but a `value` all the same. It did send
    /// text, so it is shown unstyled rather than thrown away.
    func testAnObjectWithOnlyAValueIsReadAsPlainText() throws {
        let response = try hover(#"{"contents":{"value":"Int"}}"#)
        XCTAssertEqual(response.elements, [.markup(kind: .plaintext, value: "Int")])
    }

    /// A `range` that does not parse costs the range, not the content: the caller
    /// falls back to the identifier range it asked about.
    func testARangeThatDoesNotParseLeavesTheContentIntact() throws {
        let response = try hover(#"{"contents":"Int","range":"everywhere"}"#)
        XCTAssertEqual(response.elements, [.markup(kind: .markdown, value: "Int")])
        XCTAssertNil(response.range)
    }

    func testAnUnrecognisedHoverShapeThrowsRatherThanDecodingToNothing() {
        // Same rule as definition: "nothing to show" and "I could not read the
        // answer" are different facts and must stay distinguishable.
        XCTAssertThrowsError(try hover(#""nonsense""#))
    }

    // MARK: - textDocument/references

    func testReferenceParamsAlwaysAskForTheDeclarationToo() throws {
        // The context is written every time, and `includeDeclaration` is `true`:
        // a usages list that omits the declaration the caret is sitting on reads
        // as a list that lost a row.
        XCTAssertEqual(
            try json(LSPReferenceParams(
                uri: "file:///a/b.swift",
                position: LSPPosition(line: 12, character: 4)
            )),
            #"{"context":{"includeDeclaration":true},"position":{"character":4,"line":12},"# +
                #""textDocument":{"uri":"file:///a/b.swift"}}"#
        )
    }

    func testAReferencesArrayDecodesEveryLocationInOrder() throws {
        let response = try decodeResult(
            """
            [
              {"uri":"file:///p/a.swift",
               "range":{"start":{"line":1,"character":2},"end":{"line":1,"character":5}}},
              {"uri":"file:///p/b.swift",
               "range":{"start":{"line":9,"character":0},"end":{"line":9,"character":3}}}
            ]
            """,
            as: LSPReferencesResponse.self
        )
        XCTAssertEqual(response.locations.map(\.uri), ["file:///p/a.swift", "file:///p/b.swift"])
        XCTAssertEqual(
            response.locations.first?.range,
            LSPRange(start: LSPPosition(line: 1, character: 2), end: LSPPosition(line: 1, character: 5))
        )
        XCTAssertFalse(response.isEmpty)
    }

    func testANullReferencesResultIsTheSameAnswerAsAnEmptyArray() throws {
        XCTAssertTrue(try decodeResult("null", as: LSPReferencesResponse.self).isEmpty)
        XCTAssertTrue(try decodeResult("[]", as: LSPReferencesResponse.self).isEmpty)
    }

    func testOneMalformedReferenceIsDroppedWhileItsSiblingsSurvive() throws {
        let response = try decodeResult(
            """
            [
              {"uri":"file:///p/a.swift","range":{"start":{"line":1}}},
              {"uri":"file:///p/b.swift",
               "range":{"start":{"line":9,"character":0},"end":{"line":9,"character":3}}}
            ]
            """,
            as: LSPReferencesResponse.self
        )
        XCTAssertEqual(response.locations.map(\.uri), ["file:///p/b.swift"])
    }

    func testAReferencesShapeThatIsNeitherNullNorAnArrayThrows() {
        // "found nothing" and "could not read the answer" stay different facts.
        XCTAssertThrowsError(
            try decodeResult(#"{"locations":[]}"#, as: LSPReferencesResponse.self)
        )
    }

    // MARK: - textDocument/rename

    func testRenameParamsCarryThePositionAndTheNewName() throws {
        XCTAssertEqual(
            try json(LSPRenameParams(
                uri: "file:///a/b.swift",
                position: LSPPosition(line: 12, character: 4),
                newName: "greeting"
            )),
            #"{"newName":"greeting","position":{"character":4,"line":12},"# +
                #""textDocument":{"uri":"file:///a/b.swift"}}"#
        )
    }

    func testAChangesMapDecodesEveryDocumentSortedByURI() throws {
        // A JSON object has no order of its own, so the same answer must not
        // produce two different plans on two runs: URI order is the tiebreak.
        let edit = try decodeResult(
            """
            {"changes":{
              "file:///p/z.swift":[{"range":{"start":{"line":0,"character":0},
                                             "end":{"line":0,"character":3}},"newText":"bar"}],
              "file:///p/a.swift":[{"range":{"start":{"line":4,"character":1},
                                             "end":{"line":4,"character":4}},"newText":"bar"},
                                   {"range":{"start":{"line":7,"character":2},
                                             "end":{"line":7,"character":5}},"newText":"bar"}]
            }}
            """,
            as: LSPWorkspaceEdit.self
        )
        XCTAssertEqual(edit.documents.map(\.uri), ["file:///p/a.swift", "file:///p/z.swift"])
        XCTAssertEqual(edit.documents.map(\.edits.count), [2, 1])
        XCTAssertEqual(edit.documents.map(\.version), [nil, nil])
        XCTAssertFalse(edit.isEmpty)
    }

    func testDocumentChangesDecodeWithTheirVersionsAndKeepWireOrder() throws {
        let edit = try decodeResult(
            """
            {"documentChanges":[
              {"textDocument":{"uri":"file:///p/z.swift","version":7},
               "edits":[{"range":{"start":{"line":0,"character":0},
                                  "end":{"line":0,"character":3}},"newText":"bar"}]},
              {"textDocument":{"uri":"file:///p/a.swift","version":null},
               "edits":[{"range":{"start":{"line":4,"character":1},
                                  "end":{"line":4,"character":4}},"newText":"bar"}]}
            ]}
            """,
            as: LSPWorkspaceEdit.self
        )
        XCTAssertEqual(edit.documents.map(\.uri), ["file:///p/z.swift", "file:///p/a.swift"])
        XCTAssertEqual(edit.documents.map(\.version), [7, nil])
    }

    func testDocumentChangesWinWhenAServerSendsBothSpellings() throws {
        let edit = try decodeResult(
            """
            {"changes":{"file:///p/legacy.swift":[{"range":{"start":{"line":0,"character":0},
                                                            "end":{"line":0,"character":3}},
                                                   "newText":"bar"}]},
             "documentChanges":[
              {"textDocument":{"uri":"file:///p/rich.swift","version":2},
               "edits":[{"range":{"start":{"line":0,"character":0},
                                  "end":{"line":0,"character":3}},"newText":"bar"}]}
            ]}
            """,
            as: LSPWorkspaceEdit.self
        )
        XCTAssertEqual(edit.documents.map(\.uri), ["file:///p/rich.swift"])
    }

    /// A server that offers to rename the *file* too, and one that sends an
    /// operation no version of the spec names. Both are ignored: the textual
    /// half of the answer is still exactly right, and refusing the whole edit
    /// would turn a helpful server into one that cannot rename at all.
    func testFileOperationsInDocumentChangesAreIgnoredRatherThanFailingTheDecode() throws {
        let edit = try decodeResult(
            """
            {"documentChanges":[
              {"kind":"create","uri":"file:///p/new.swift"},
              {"textDocument":{"uri":"file:///p/a.swift"},
               "edits":[{"range":{"start":{"line":4,"character":1},
                                  "end":{"line":4,"character":4}},"newText":"bar"}]},
              {"kind":"rename","oldUri":"file:///p/a.swift","newUri":"file:///p/b.swift"},
              {"kind":"teleport","uri":"file:///p/a.swift"},
              {"kind":"delete","uri":"file:///p/old.swift"}
            ]}
            """,
            as: LSPWorkspaceEdit.self
        )
        XCTAssertEqual(edit.documents.map(\.uri), ["file:///p/a.swift"])
        XCTAssertEqual(edit.documents.first?.edits.count, 1)
    }

    func testANullRenameResultAndAnEditWithNoChangesAreBothEmpty() throws {
        XCTAssertTrue(try decodeResult("null", as: LSPWorkspaceEdit.self).documents.isEmpty)
        XCTAssertTrue(try decodeResult("{}", as: LSPWorkspaceEdit.self).documents.isEmpty)
        // A document named with nothing to do in it is still nothing to apply.
        let empty = try decodeResult(
            #"{"documentChanges":[{"textDocument":{"uri":"file:///p/a.swift"},"edits":[]}]}"#,
            as: LSPWorkspaceEdit.self
        )
        XCTAssertEqual(empty.documents.count, 1)
        XCTAssertTrue(empty.isEmpty)
    }

    /// **An edit this cannot read fails the whole answer**, in both wire
    /// spellings. Dropping it and keeping its siblings would build a plan that
    /// passes every refusal in `RenameEditPlan` and renames a project in four
    /// places out of five — the half-renamed state the whole feature is built to
    /// refuse. The command's answer to a throw here is the beep it gives a server
    /// that refused outright.
    func testOneMalformedEditFailsTheWholeAnswer() {
        let documentChanges = """
            {"documentChanges":[
              {"textDocument":{"uri":"file:///p/a.swift"},
               "edits":[{"range":{"start":{"line":4,"character":1}},"newText":"bar"},
                        {"range":{"start":{"line":7,"character":2},
                                  "end":{"line":7,"character":5}},"newText":"bar"}]}
            ]}
            """
        XCTAssertThrowsError(try decodeResult(documentChanges, as: LSPWorkspaceEdit.self))

        let changes = """
            {"changes":{"file:///p/a.swift":[
               {"range":{"start":{"line":4,"character":1}},"newText":"bar"},
               {"range":{"start":{"line":7,"character":2},
                         "end":{"line":7,"character":5}},"newText":"bar"}]}}
            """
        XCTAssertThrowsError(try decodeResult(changes, as: LSPWorkspaceEdit.self))
    }

    /// A `changes` entry that is not an array of edits fails the whole decode
    /// too, and unlike `documentChanges` it has no file-operation reading to be
    /// tolerant of: every value in that map is one document's edits, so dropping
    /// the unreadable one would keep the other four documents and write exactly
    /// the half-renamed project the rule above refuses.
    func testAMalformedChangesEntryFailsTheWholeAnswer() {
        let changes = """
            {"changes":{
               "file:///p/a.swift":[{"range":{"start":{"line":1,"character":0},
                                              "end":{"line":1,"character":3}},"newText":"bar"}],
               "file:///p/b.swift":"not an array"}}
            """
        XCTAssertThrowsError(try decodeResult(changes, as: LSPWorkspaceEdit.self))
    }

    /// **An entry that claims to be a text edit and is not readable as one fails
    /// the whole answer too.** `textDocument` is what separates a document this
    /// rename must rewrite from a file operation it declines to perform, so an
    /// entry carrying one whose `uri` or `edits` cannot be read is a malformed
    /// answer and not a kind this client passes on. Reading it as a file
    /// operation would keep its sibling and write `b.swift` renamed while
    /// `a.swift` keeps the old name — one level up from the single dropped edit
    /// the case above refuses, and the same half-renamed project.
    func testADocumentChangesEntryNamingADocumentItCannotReadFailsTheWholeAnswer() {
        let unreadableEdits = """
            {"documentChanges":[
              {"textDocument":{"uri":"file:///p/a.swift"},"edits":null},
              {"textDocument":{"uri":"file:///p/b.swift"},
               "edits":[{"range":{"start":{"line":7,"character":2},
                                  "end":{"line":7,"character":5}},"newText":"bar"}]}
            ]}
            """
        XCTAssertThrowsError(try decodeResult(unreadableEdits, as: LSPWorkspaceEdit.self))

        let missingEdits = """
            {"documentChanges":[
              {"textDocument":{"uri":"file:///p/a.swift"}},
              {"textDocument":{"uri":"file:///p/b.swift"},
               "edits":[{"range":{"start":{"line":7,"character":2},
                                  "end":{"line":7,"character":5}},"newText":"bar"}]}
            ]}
            """
        XCTAssertThrowsError(try decodeResult(missingEdits, as: LSPWorkspaceEdit.self))

        let unreadableURI = """
            {"documentChanges":[
              {"textDocument":{"uri":42},
               "edits":[{"range":{"start":{"line":4,"character":1},
                                  "end":{"line":4,"character":4}},"newText":"bar"}]},
              {"textDocument":{"uri":"file:///p/b.swift"},
               "edits":[{"range":{"start":{"line":7,"character":2},
                                  "end":{"line":7,"character":5}},"newText":"bar"}]}
            ]}
            """
        XCTAssertThrowsError(try decodeResult(unreadableURI, as: LSPWorkspaceEdit.self))
    }

    /// **A `documentChanges` member that is present and is not an array fails
    /// the whole answer**, one level further out than the two cases above.
    /// Swallowing it falls through to `changes` and writes exactly the edit set
    /// `testDocumentChangesWinWhenAServerSendsBothSpellings` says is superseded
    /// — the unversioned, differently-shaped half of an answer whose richer half
    /// this client could not read — or, with no `changes` beside it, reports the
    /// empty answer a server gives when it recognised the symbol and has nothing
    /// to rewrite, so the command beeps as though the rename were a no-op rather
    /// than unreadable. A `changes` member that is not an object fails for the
    /// same reason.
    func testAMalformedDocumentChangesMemberFailsTheWholeAnswer() throws {
        let besideChanges = """
            {"changes":{"file:///p/legacy.swift":[{"range":{"start":{"line":0,"character":0},
                                                            "end":{"line":0,"character":3}},
                                                   "newText":"bar"}]},
             "documentChanges":{"textDocument":{"uri":"file:///p/a.swift"},"edits":[]}}
            """
        XCTAssertThrowsError(try decodeResult(besideChanges, as: LSPWorkspaceEdit.self))

        let alone = #"{"documentChanges":"nope"}"#
        XCTAssertThrowsError(try decodeResult(alone, as: LSPWorkspaceEdit.self))

        let malformedChanges = #"{"changes":"nope"}"#
        XCTAssertThrowsError(try decodeResult(malformedChanges, as: LSPWorkspaceEdit.self))

        // `null` and absent are still not present, which is what lets a server
        // spell "I have no rich answer" either way and be read as `changes`.
        let nullBesideChanges = try decodeResult(
            """
            {"documentChanges":null,
             "changes":{"file:///p/legacy.swift":[{"range":{"start":{"line":0,"character":0},
                                                            "end":{"line":0,"character":3}},
                                                   "newText":"bar"}]}}
            """,
            as: LSPWorkspaceEdit.self
        )
        XCTAssertEqual(nullBesideChanges.documents.map(\.uri), ["file:///p/legacy.swift"])
        XCTAssertTrue(
            try decodeResult(#"{"changes":null}"#, as: LSPWorkspaceEdit.self).documents.isEmpty
        )
    }

    /// The tolerance that *remains*: an entry that is not a text edit at all — a
    /// file operation, or a kind no version of the spec names — is ignored, and
    /// the textual half of the answer is still exactly right.
    func testFileOperationEntriesAreIgnoredRatherThanFailing() throws {
        let edit = try decodeResult(
            """
            {"documentChanges":[
              {"kind":"rename","oldUri":"file:///p/a.swift","newUri":"file:///p/b.swift"},
              {"textDocument":{"uri":"file:///p/a.swift"},
               "edits":[{"range":{"start":{"line":7,"character":2},
                                  "end":{"line":7,"character":5}},"newText":"bar"}]}
            ]}
            """,
            as: LSPWorkspaceEdit.self
        )
        XCTAssertEqual(edit.documents.count, 1)
        XCTAssertEqual(edit.documents.first?.edits.first?.range.start.line, 7)
    }

    // MARK: - textDocument/completion

    func testCompletionParamsCarryTheMemberTriggerCharacter() throws {
        let params = LSPCompletionParams(
            uri: "file:///a/b.swift",
            position: LSPPosition(line: 4, character: 22),
            context: .dot
        )
        XCTAssertEqual(
            try json(params),
            """
            {"context":{"triggerCharacter":".","triggerKind":2},\
            "position":{"character":22,"line":4},\
            "textDocument":{"uri":"file:///a/b.swift"}}
            """
        )
    }

    func testCompletionParamsForOrdinaryIdentifierCompletion() throws {
        let params = LSPCompletionParams(
            uri: "file:///a/b.swift",
            position: LSPPosition(line: 0, character: 4),
            context: .invoked
        )
        let encoded = try json(params)
        XCTAssertTrue(encoded.contains(#""context":{"triggerKind":1}"#), encoded)
        XCTAssertFalse(encoded.contains("triggerCharacter"), encoded)
    }

    /// The recorded member completion after `greeter.` — the payoff case for
    /// phase 2a, and the one tree-sitter cannot answer: these are the members of
    /// a *type*, not words that appear in the file.
    func testMemberCompletionDecodesTheRecordedItems() throws {
        let response = try result(of: "completion-member.json", as: LSPCompletionResponse.self)
        XCTAssertTrue(response.isIncomplete)
        XCTAssertEqual(response.items.map(\.label), ["self", "salutation", "greet(name: String)"])

        // Three different strings for one item, which is exactly why the seam
        // cannot collapse them: the server *displays* `greet(name: String)`,
        // *filters* on `greet(:)`, and *inserts* `greet()`. Using the label as
        // the inserted text — the obvious shortcut — would put a type annotation
        // in the buffer.
        let greet = try XCTUnwrap(response.items.last)
        XCTAssertEqual(greet.kind, .method)
        XCTAssertEqual(greet.label, "greet(name: String)")
        XCTAssertEqual(greet.filterText, "greet(:)")
        XCTAssertEqual(greet.insertText, "greet()")
        XCTAssertEqual(greet.sortText, "4998.54706250-greet(name: String)")
        XCTAssertEqual(greet.insertedText, "greet()")

        let salutation = try XCTUnwrap(response.items.dropFirst().first)
        XCTAssertEqual(salutation.kind, .property)
        XCTAssertEqual(salutation.detail, "String")
    }

    func testAMemberItemsTextEditReplacesTheCaretPosition() throws {
        let response = try result(of: "completion-member.json", as: LSPCompletionResponse.self)
        let edit = try XCTUnwrap(response.items.first?.textEdit)
        // An empty range right after the `.`: nothing typed yet, so nothing is
        // replaced.
        XCTAssertEqual(edit.range, LSPRange(at: LSPPosition(line: 4, character: 22)))
        XCTAssertNil(edit.insertRange)
        XCTAssertEqual(edit.newText, "self")
    }

    /// The recorded identifier completion, trimmed to ten items but *not*
    /// reordered — and its point is the last one. `Greeter` arrives last in the
    /// array and carries the lowest `sortText`, so D6's rule (rank by
    /// `sortText ?? label`, never by array order) is the difference between the
    /// one useful candidate being first and being tenth.
    func testIdentifierCompletionRanksBySortTextNotByServerArrayOrder() throws {
        let response = try result(of: "completion-identifier.json", as: LSPCompletionResponse.self)
        XCTAssertEqual(response.items.count, 10)
        XCTAssertEqual(response.items.last?.label, "Greeter")

        let ranked = response.items
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.rankingKey == rhs.element.rankingKey
                    ? lhs.offset < rhs.offset
                    : lhs.element.rankingKey < rhs.element.rankingKey
            }
            .map(\.element.label)
        XCTAssertEqual(ranked.first, "Greeter")
    }

    func testEveryRecordedItemHasTheKindAndEditTheProviderWillNeed() throws {
        let response = try result(of: "completion-identifier.json", as: LSPCompletionResponse.self)
        for item in response.items {
            XCTAssertNotNil(item.kind, item.label)
            XCTAssertNotNil(item.textEdit, item.label)
            XCTAssertEqual(item.insertTextFormat, 1, "\(item.label) is not plain text (D5)")
            XCTAssertFalse(item.insertedText.isEmpty, item.label)
        }
    }

    /// The rule `publish` reads a snippet-format item with, pinned directly
    /// because it is a one-line predicate standing between a server's mislabelled
    /// text and the user's file. `$` and `\\` are the snippet grammar's only two
    /// entry points, so text without them is the same string under both formats;
    /// the error, where there is one, is toward refusing.
    func testSnippetSyntaxIsDetectedFromTheGrammarsTwoEntryPointsAlone() {
        func item(_ inserted: String) -> LSPCompletionItem {
            LSPCompletionItem(label: "x", insertText: inserted)
        }

        // Expands: tab stops, placeholders, choices, variables — and the escape,
        // which is the half a `$`-only test would miss.
        XCTAssertTrue(item("greeting: $1").carriesSnippetSyntax)
        XCTAssertTrue(item("greeting: $0").carriesSnippetSyntax)
        XCTAssertTrue(item("greeting: ${1:name}").carriesSnippetSyntax)
        XCTAssertTrue(item("greeting: ${1|a,b|}").carriesSnippetSyntax)
        XCTAssertTrue(item("$TM_FILENAME").carriesSnippetSyntax)
        XCTAssertTrue(item("literal \\} brace").carriesSnippetSyntax)
        // A dollar that is only a dollar still answers `true`: one candidate is
        // the price of never guessing at an expansion.
        XCTAssertTrue(item("PATH=$HOME").carriesSnippetSyntax)

        // Literal under either format — including the shape yaml-language-server
        // mislabels, which is the whole reason the flag is not read alone.
        XCTAssertFalse(item("services:\n  ").carriesSnippetSyntax)
        XCTAssertFalse(item("services").carriesSnippetSyntax)
        XCTAssertFalse(item("").carriesSnippetSyntax)
        XCTAssertFalse(item("- (array item)").carriesSnippetSyntax)

        // It asks the text that will be *inserted*, by the spec's precedence, not
        // the label: a clean label over a placeholder edit must not pass.
        let mislabelled = LSPCompletionItem(
            label: "greeting",
            insertText: "greeting",
            textEdit: LSPCompletionEdit(
                range: LSPRange(
                    start: LSPPosition(line: 0, character: 0),
                    end: LSPPosition(line: 0, character: 8)
                ),
                newText: "greeting: ${1:name}"
            )
        )
        XCTAssertTrue(mislabelled.carriesSnippetSyntax)
    }

    func testATextEditRangeCanBeWiderThanASingleCaretPosition() throws {
        // The identifier fixture's edits replace the four characters already
        // typed, so the client's own prefix range is not what gets replaced —
        // the server's range is.
        let response = try result(of: "completion-identifier.json", as: LSPCompletionResponse.self)
        let edit = try XCTUnwrap(response.items.first?.textEdit)
        XCTAssertEqual(
            edit.range,
            LSPRange(
                start: LSPPosition(line: 3, character: 14),
                end: LSPPosition(line: 3, character: 18)
            )
        )
    }

    /// D4's shape: a primary edit at the completion point plus an
    /// `additionalTextEdits` entry inserting an `import` line *above* it.
    func testAutoImportItemCarriesItsAdditionalEdits() throws {
        let response = try result(of: "completion-auto-import.json", as: LSPCompletionResponse.self)
        let item = try XCTUnwrap(response.items.first)
        XCTAssertEqual(item.label, "Greeter")
        XCTAssertEqual(item.insertedText, "Greeter")

        let additional = try XCTUnwrap(item.additionalTextEdits)
        XCTAssertEqual(additional.count, 1)
        XCTAssertEqual(additional[0].newText, "import Core\n")
        XCTAssertEqual(additional[0].range, LSPRange(at: LSPPosition(line: 1, character: 0)))
        // The import comes before the completion point, which is the ordering
        // that makes naive edit application move the caret to the wrong place.
        XCTAssertLessThan(additional[0].range.start, try XCTUnwrap(item.textEdit).range.start)
    }

    func testAnItemThatAlreadyCarriesItsEditsNeedsNoResolve() throws {
        let response = try result(of: "completion-auto-import.json", as: LSPCompletionResponse.self)
        let item = try XCTUnwrap(response.items.first)
        XCTAssertNotNil(item.data)
        XCTAssertFalse(item.needsResolve)
    }

    func testAnItemWithOpaqueDataAndNoEditsNeedsResolve() throws {
        let response = try result(of: "completion-member.json", as: LSPCompletionResponse.self)
        for item in response.items {
            XCTAssertTrue(item.needsResolve, item.label)
        }
    }

    func testABareArrayResultIsACompletionList() throws {
        let response = try JSONDecoder().decode(
            LSPCompletionResponse.self,
            from: Data(#"[{"label":"one"},{"label":"two"}]"#.utf8)
        )
        XCTAssertFalse(response.isIncomplete)
        XCTAssertEqual(response.items.map(\.label), ["one", "two"])
    }

    func testANullCompletionResultIsAnEmptyList() throws {
        let response = try JSONDecoder().decode(
            LSPCompletionResponse.self,
            from: Data("null".utf8)
        )
        XCTAssertTrue(response.isEmpty)
    }

    func testAnItemWithNothingButALabelInsertsThatLabel() throws {
        let response = try JSONDecoder().decode(
            LSPCompletionResponse.self,
            from: Data(#"[{"label":"bare"}]"#.utf8)
        )
        XCTAssertEqual(response.items[0].insertedText, "bare")
        XCTAssertEqual(response.items[0].rankingKey, "bare")
        XCTAssertFalse(response.items[0].needsResolve)
    }

    /// `insertTextMode` is decoded because the multi-line rule reads it, and
    /// absent stays absent through the resolve round trip: an item this client
    /// sends back must not acquire a mode the server never stated.
    func testInsertTextModeDecodesAndAnAbsentOneIsNotEncodedBack() throws {
        let response = try JSONDecoder().decode(
            LSPCompletionResponse.self,
            from: Data(#"[{"label":"asIs","insertTextMode":1},{"label":"silent"}]"#.utf8)
        )
        XCTAssertEqual(response.items[0].insertTextMode, 1)
        XCTAssertNil(response.items[1].insertTextMode)

        let encoded = try JSONEncoder().encode(response.items[1])
        XCTAssertFalse(
            String(decoding: encoded, as: UTF8.self).contains("insertTextMode"),
            "an absent field must not round-trip as `null` — the resolve params are the item verbatim"
        )
    }

    func testAnUnknownItemKindDecodesInsteadOfDroppingTheItem() throws {
        // Open sets: a kind from a newer specification must not cost the user a
        // whole completion list.
        let response = try JSONDecoder().decode(
            LSPCompletionResponse.self,
            from: Data(#"[{"label":"future","kind":9999}]"#.utf8)
        )
        XCTAssertEqual(response.items[0].kind, LSPCompletionItemKind(rawValue: 9999))
    }

    func testAnInsertReplaceEditDecodesToItsReplaceRange() throws {
        // `insertReplaceSupport` is not advertised, so this should never arrive;
        // if it does, replacing the typed token is the behaviour that matches
        // what the primary edit does everywhere else.
        let response = try JSONDecoder().decode(
            LSPCompletionResponse.self,
            from: (
                #"[{"label":"x","textEdit":{"newText":"xy","#
                    + #""insert":{"start":{"line":0,"character":1},"end":{"line":0,"character":2}},"#
                    + #""replace":{"start":{"line":0,"character":1},"end":{"line":0,"character":5}}}}]"#
            ).utf8Data
        )
        let edit = try XCTUnwrap(response.items[0].textEdit)
        XCTAssertEqual(edit.range.end, LSPPosition(line: 0, character: 5))
        XCTAssertEqual(edit.insertRange?.end, LSPPosition(line: 0, character: 2))
        XCTAssertEqual(edit.newText, "xy")
    }

    // MARK: - completionItem/resolve

    /// Resolve echoes the item back. The `data` member is the server's own
    /// correlation key — `{sessionId, itemId, uri}` here — and re-encoding it as
    /// anything but what arrived (a float for an int, a reordered object) is how
    /// a resolve silently answers nothing.
    func testResolveParamsRoundTripTheItemVerbatim() throws {
        let original = try JSONDecoder().decode(
            LSPCompletionItem.self,
            from: try fixture("completion-resolve-request.json")
        )
        let reDecoded = try JSONDecoder().decode(
            LSPCompletionItem.self,
            from: try JSONEncoder().encode(original)
        )
        XCTAssertEqual(reDecoded, original)
        XCTAssertEqual(
            original.data,
            .object([
                "itemId": .int(13118),
                "sessionId": .int(0),
                "uri": .string("file:///tmp/lspfix/pkg/Sources/App/main.swift"),
            ])
        )
    }

    func testResolveResultDecodesAsACompletionItem() throws {
        let resolved = try result(of: "completion-resolve.json", as: LSPCompletionItem.self)
        let original = try JSONDecoder().decode(
            LSPCompletionItem.self,
            from: try fixture("completion-resolve-request.json")
        )
        // This server resolved the item to itself — nothing was being held back.
        // The provider must cope with that (no extra edits appear) as readily as
        // with a resolve that adds an import.
        XCTAssertEqual(resolved, original)
        XCTAssertNil(resolved.additionalTextEdits)
    }

    /// The other outcome of a resolve, and the one D4 exists for: the item comes
    /// back carrying edits it did not have. Both are the same decode, so the
    /// provider cannot tell them apart by type — only by whether
    /// `additionalTextEdits` appeared.
    func testAResolveThatAddsEditsIsWhatTheProviderIsWaitingFor() throws {
        let unresolved = try JSONDecoder().decode(
            LSPCompletionItem.self,
            from: try fixture("completion-resolve-request.json")
        )
        let enriched = try result(of: "completion-auto-import.json", as: LSPCompletionResponse.self)
        XCTAssertNil(unresolved.additionalTextEdits)
        XCTAssertEqual(enriched.items.first?.additionalTextEdits?.count, 1)
    }

    // MARK: - shutdown / cancel

    func testShutdownResultIsAPresentNull() throws {
        let message = try LSPIncomingMessage.decode(try fixture("shutdown-result.json"))
        guard case .response(let response) = message else {
            return XCTFail("shutdown-result.json is not a response")
        }
        // Present-and-null, not absent: the distinction `LSPResponseMessage`
        // keeps, and the difference between "the server agreed to shut down" and
        // "the server sent something we could not read".
        XCTAssertEqual(response.result, JSONValue.null)
        XCTAssertNil(response.error)
    }

    func testCancelParamsCarryTheRequestID() throws {
        XCTAssertEqual(try json(LSPCancelParams(id: .number(17))), #"{"id":17}"#)
        XCTAssertEqual(try json(LSPCancelParams(id: .string("abc"))), #"{"id":"abc"}"#)
    }

    func testMethodNamesAreSpelledAsTheSpecificationSpellsThem() {
        XCTAssertEqual(LSPMethod.initialize, "initialize")
        XCTAssertEqual(LSPMethod.initialized, "initialized")
        XCTAssertEqual(LSPMethod.shutdown, "shutdown")
        XCTAssertEqual(LSPMethod.exit, "exit")
        XCTAssertEqual(LSPMethod.cancelRequest, "$/cancelRequest")
        XCTAssertEqual(LSPMethod.didOpen, "textDocument/didOpen")
        XCTAssertEqual(LSPMethod.didChange, "textDocument/didChange")
        XCTAssertEqual(LSPMethod.didClose, "textDocument/didClose")
        XCTAssertEqual(LSPMethod.definition, "textDocument/definition")
        XCTAssertEqual(LSPMethod.hover, "textDocument/hover")
        XCTAssertEqual(LSPMethod.references, "textDocument/references")
        XCTAssertEqual(LSPMethod.rename, "textDocument/rename")
        XCTAssertEqual(LSPMethod.completion, "textDocument/completion")
        XCTAssertEqual(LSPMethod.resolveCompletionItem, "completionItem/resolve")
        XCTAssertEqual(LSPMethod.workspaceConfiguration, "workspace/configuration")
        XCTAssertEqual(LSPMethod.registerCapability, "client/registerCapability")
    }

    // MARK: - Geometry

    func testPositionsOrderByLineThenCharacter() {
        XCTAssertLessThan(LSPPosition(line: 1, character: 9), LSPPosition(line: 2, character: 0))
        XCTAssertLessThan(LSPPosition(line: 2, character: 1), LSPPosition(line: 2, character: 2))
        XCTAssertFalse(LSPPosition(line: 2, character: 2) < LSPPosition(line: 2, character: 2))
    }

    func testAZeroLengthRangeIsEmpty() {
        XCTAssertTrue(LSPRange(at: LSPPosition(line: 3, character: 3)).isEmpty)
        XCTAssertFalse(
            LSPRange(
                start: LSPPosition(line: 3, character: 3),
                end: LSPPosition(line: 3, character: 4)
            ).isEmpty
        )
    }
}

private extension String {
    /// The tests above build a few JSON literals by concatenation, which reads
    /// better than one unbroken line; this keeps the `Data(…)` conversion at the
    /// end where the literal finishes.
    var utf8Data: Data { Data(utf8) }
}
