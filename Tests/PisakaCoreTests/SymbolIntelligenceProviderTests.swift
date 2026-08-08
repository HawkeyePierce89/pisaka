import XCTest
@testable import PisakaCore

/// A mutable, main-actor-isolated snapshot holder — the shape
/// `SymbolIndexModel` presents to `SymbolIntelligenceProvider`'s index closure.
@MainActor
private final class IndexHolder {
    var index: SymbolIndex

    init(_ index: SymbolIndex) { self.index = index }
}

/// Pins every ranking rule the two editor surfaces depend on. The rules live in
/// pure `static` functions precisely so each tie-break can be exercised in
/// isolation with three symbols instead of a project — which is what these tests
/// do, one test per tie-break, plus the async protocol shell on top.
final class SymbolIntelligenceProviderTests: XCTestCase {

    // MARK: - Helpers

    private let root = URL(fileURLWithPath: "/proj")

    private func fileURL(_ relative: String) -> URL {
        root.appendingPathComponent(relative)
    }

    private func symbol(
        _ name: String,
        kind: SymbolKind = .function,
        in file: String,
        at location: Int = 0,
        line: Int = 1,
        container: String? = nil
    ) -> Symbol {
        Symbol(
            name: name,
            kind: kind,
            range: NSRange(location: location, length: name.utf16.count),
            fileURL: fileURL(file),
            containerName: container,
            line: line
        )
    }

    private func index(_ groups: [String: [Symbol]]) -> SymbolIndex {
        var index = SymbolIndex()
        for (file, symbols) in groups.sorted(by: { $0.key < $1.key }) {
            index.replace(fileURL: fileURL(file), symbols: symbols)
        }
        return index
    }

    private func definitionRequest(_ identifier: String, from file: String? = nil) -> DefinitionRequest {
        DefinitionRequest(identifier: identifier, fileURL: file.map(fileURL), offset: 0)
    }

    private func completionRequest(
        _ prefix: String,
        from file: String? = nil,
        text: String = ""
    ) -> CompletionRequest {
        CompletionRequest(prefix: prefix, fileURL: file.map(fileURL), text: text)
    }

    // MARK: - Definitions

    func testDefinitionsMatchExactlyAndCaseSensitively() {
        let store = index([
            "a.swift": [symbol("Worker", kind: .type, in: "a.swift")],
            "b.swift": [symbol("worker", in: "b.swift"), symbol("WorkerPool", kind: .type, in: "b.swift")]
        ])

        let found = SymbolIntelligenceProvider.definitions(
            for: definitionRequest("Worker"),
            in: store,
            projectRoot: root
        )
        XCTAssertEqual(found.map(\.symbol.name), ["Worker"])
        XCTAssertEqual(found.map(\.relativePath), ["a.swift"])
    }

    func testDefinitionsRankTheCurrentFileFirstThenPathThenLine() {
        let store = index([
            "z.swift": [symbol("run", in: "z.swift", at: 10, line: 2)],
            "a.swift": [
                symbol("run", in: "a.swift", at: 90, line: 9),
                symbol("run", in: "a.swift", at: 20, line: 3)
            ],
            "m.swift": [symbol("run", in: "m.swift", at: 0, line: 1)]
        ])

        let found = SymbolIntelligenceProvider.definitions(
            for: definitionRequest("run", from: "z.swift"),
            in: store,
            projectRoot: root
        )
        XCTAssertEqual(
            found.map { "\($0.relativePath):\($0.symbol.line)" },
            ["z.swift:2", "a.swift:3", "a.swift:9", "m.swift:1"]
        )
    }

    func testDefinitionsWithoutACurrentFileFallBackToPathOrder() {
        let store = index([
            "z.swift": [symbol("run", in: "z.swift")],
            "a.swift": [symbol("run", in: "a.swift")]
        ])

        let found = SymbolIntelligenceProvider.definitions(
            for: definitionRequest("run"),
            in: store,
            projectRoot: root
        )
        XCTAssertEqual(found.map(\.relativePath), ["a.swift", "z.swift"])
    }

    func testDefinitionsOfAnEmptyIdentifierYieldNothing() {
        let store = index(["a.swift": [symbol("run", in: "a.swift")]])
        XCTAssertTrue(
            SymbolIntelligenceProvider.definitions(
                for: definitionRequest(""),
                in: store,
                projectRoot: root
            ).isEmpty
        )
    }

    func testRelativePathDegradesToTheFileNameOutsideTheRoot() {
        let store = index(["a.swift": []])
        var outside = SymbolIndex()
        let external = URL(fileURLWithPath: "/elsewhere/deep/Other.swift")
        outside.replace(
            fileURL: external,
            symbols: [
                Symbol(
                    name: "run",
                    kind: .function,
                    range: NSRange(location: 0, length: 3),
                    fileURL: external,
                    line: 1
                )
            ]
        )
        XCTAssertTrue(store.symbols(named: "run").isEmpty)

        let withRoot = SymbolIntelligenceProvider.definitions(
            for: definitionRequest("run"),
            in: outside,
            projectRoot: root
        )
        XCTAssertEqual(withRoot.map(\.relativePath), ["Other.swift"])

        let withoutRoot = SymbolIntelligenceProvider.definitions(
            for: definitionRequest("run"),
            in: outside,
            projectRoot: nil
        )
        XCTAssertEqual(withoutRoot.map(\.relativePath), ["Other.swift"])
    }

    func testDefinitionLabelShowsContainerPathAndLine() {
        let candidate = DefinitionCandidate(
            symbol: symbol("run", kind: .method, in: "src/Worker.swift", line: 42, container: "Worker"),
            relativePath: "src/Worker.swift"
        )
        XCTAssertEqual(candidate.displayLabel, "Worker.run — src/Worker.swift:42")
    }

    /// The current file is matched through the canonical key, so a tab opened at
    /// a firmlinked/symlinked spelling still ranks its own declarations first.
    func testCurrentFileIsMatchedCanonically() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }

        let spelled = directory.appendingPathComponent("a.swift")
        try Data("func run() {}".utf8).write(to: spelled)
        let firmlinked = URL(fileURLWithPath: "/private" + spelled.path)

        var store = SymbolIndex()
        store.replace(
            fileURL: URL(fileURLWithPath: "/proj/aaa.swift"),
            symbols: [symbol("run", in: "aaa.swift")]
        )
        store.replace(
            fileURL: spelled,
            symbols: [
                Symbol(
                    name: "run",
                    kind: .function,
                    range: NSRange(location: 5, length: 3),
                    fileURL: spelled,
                    line: 1
                )
            ]
        )

        let found = SymbolIntelligenceProvider.definitions(
            for: DefinitionRequest(identifier: "run", fileURL: firmlinked, offset: 0),
            in: store,
            projectRoot: directory
        )
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.first?.symbol.fileURL, spelled)
    }

    // MARK: - Completions: tie-breaks, one at a time

    func testCaseSensitivePrefixOutranksCaseInsensitive() {
        let store = index([
            "a.swift": [symbol("Arrays", kind: .type, in: "a.swift")],
            "b.swift": [symbol("arrayCount", in: "b.swift")]
        ])
        let items = SymbolIntelligenceProvider.completions(
            for: completionRequest("arr"),
            in: store
        )
        XCTAssertEqual(items.map(\.text), ["arrayCount", "Arrays"])
    }

    func testCurrentFileOutranksTheRestOfTheProject() {
        let store = index([
            "a.swift": [symbol("runAll", in: "a.swift")],
            "z.swift": [symbol("run", in: "z.swift")]
        ])
        let items = SymbolIntelligenceProvider.completions(
            for: completionRequest("ru", from: "a.swift"),
            in: store
        )
        // `runAll` is longer, so only the current-file rule can put it first.
        XCTAssertEqual(items.map(\.text), ["runAll", "run"])
        XCTAssertEqual(items.map(\.isFromCurrentFile), [true, false])
    }

    /// Isolated from the current-file rule, which outranks it: the symbol and the
    /// words all belong to the same file here, so only the source rule can decide.
    func testSymbolsOutrankBareBufferWords() {
        let store = index(["a.swift": [symbol("total", kind: .variable, in: "a.swift")]])
        let items = SymbolIntelligenceProvider.completions(
            for: completionRequest("to", from: "a.swift", text: "touch tone"),
            in: store
        )
        // `tone` is *shorter* than `total`, and length is a later tie-break than
        // source, so the symbol still leads.
        XCTAssertEqual(items.first?.text, "total")
        XCTAssertEqual(items.first?.kind, .variable)
        XCTAssertEqual(Set(items.map(\.text)), ["total", "touch", "tone"])
    }

    func testShorterNamesOutrankLongerOnes() {
        let store = index([
            "a.swift": [
                symbol("runEverythingNow", in: "a.swift", at: 0),
                symbol("run", in: "a.swift", at: 40),
                symbol("runAll", in: "a.swift", at: 80)
            ]
        ])
        let items = SymbolIntelligenceProvider.completions(
            for: completionRequest("run", from: "a.swift"),
            in: store
        )
        // `run` itself is the typed token and is dropped.
        XCTAssertEqual(items.map(\.text), ["runAll", "runEverythingNow"])
    }

    func testEqualRankFallsBackToLexicographicOrder() {
        let store = index([
            "a.swift": [
                symbol("runB", in: "a.swift", at: 0),
                symbol("runA", in: "a.swift", at: 40)
            ]
        ])
        let items = SymbolIntelligenceProvider.completions(
            for: completionRequest("run", from: "a.swift"),
            in: store
        )
        XCTAssertEqual(items.map(\.text), ["runA", "runB"])
    }

    // MARK: - Completions: dedup, caps, degradation

    func testDuplicateNamesCollapseToTheirBestRankedEntry() {
        let store = index([
            "a.swift": [symbol("total", kind: .property, in: "a.swift")],
            "z.swift": [symbol("total", kind: .variable, in: "z.swift")]
        ])
        let items = SymbolIntelligenceProvider.completions(
            for: completionRequest("tot", from: "a.swift", text: "total total"),
            in: store
        )
        XCTAssertEqual(items.map(\.text), ["total"])
        // The current-file symbol wins over both the project symbol and the word.
        XCTAssertEqual(items.first?.kind, .property)
        XCTAssertEqual(items.first?.isFromCurrentFile, true)
    }

    func testTheTypedTokenItselfIsDropped() {
        let store = index(["a.swift": [symbol("count", in: "a.swift")]])
        let items = SymbolIntelligenceProvider.completions(
            for: completionRequest("count", from: "a.swift", text: "count = count + 1"),
            in: store
        )
        XCTAssertTrue(items.isEmpty)

        // A differently-cased name is a real candidate, not the typed token.
        let cased = SymbolIntelligenceProvider.completions(
            for: completionRequest("count", from: "a.swift", text: "Count"),
            in: store
        )
        XCTAssertEqual(cased.map(\.text), ["Count"])
    }

    func testResultsAreCappedAtTheLimit() {
        let symbols = (0..<40).map { symbol("run\($0)aaa", in: "a.swift", at: $0 * 100) }
        let store = index(["a.swift": symbols])
        let items = SymbolIntelligenceProvider.completions(
            for: completionRequest("run", from: "a.swift"),
            in: store,
            limit: 5
        )
        XCTAssertEqual(items.count, 5)

        XCTAssertTrue(
            SymbolIntelligenceProvider.completions(
                for: completionRequest("run", from: "a.swift"),
                in: store,
                limit: 0
            ).isEmpty
        )
    }

    func testTheBestCandidateSurvivesAPrefixMatchSetLargerThanTheCap() {
        // The index orders prefix matches by storage position, so the shortest —
        // and therefore best-ranked — name is deliberately put *last*. Asking the
        // index for only `limit` matches would hand the ranking a slice that does
        // not contain it, which is the whole reason `candidateLimit(for:)` asks
        // for a generous multiple instead.
        var symbols = (0..<20).map { symbol("runnerNumber\($0)", in: "a.swift", at: $0 * 100) }
        symbols.append(symbol("run", in: "a.swift", at: 10_000))

        let items = SymbolIntelligenceProvider.completions(
            for: completionRequest("ru", from: "a.swift"),
            in: index(["a.swift": symbols]),
            limit: 2
        )

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.text, "run")
    }

    func testAnEmptyPrefixYieldsNothing() {
        let store = index(["a.swift": [symbol("run", in: "a.swift")]])
        XCTAssertTrue(
            SymbolIntelligenceProvider.completions(
                for: completionRequest("", from: "a.swift", text: "run"),
                in: store
            ).isEmpty
        )
    }

    /// The graceful-degradation guarantee: a language with no `symbols.scm` (or a
    /// file the walk has not reached) still completes from the buffer's words.
    func testAnEmptyIndexStillOffersBufferWords() {
        let items = SymbolIntelligenceProvider.completions(
            for: completionRequest("wor", from: "a.swift", text: "worker workshop wonder"),
            in: SymbolIndex()
        )
        XCTAssertEqual(items.map(\.text), ["worker", "workshop"])
        XCTAssertEqual(items.map(\.kind), [nil, nil])
        XCTAssertEqual(items.map(\.isFromCurrentFile), [true, true])
    }

    func testBufferWordHarvestIsCappedIndependently() {
        let text = (0..<50).map { "word\($0)zzz" }.joined(separator: " ")
        let items = SymbolIntelligenceProvider.completions(
            for: completionRequest("wor", from: "a.swift", text: text),
            in: SymbolIndex(),
            bufferWordLimit: 3
        )
        XCTAssertEqual(items.count, 3)
    }

    // MARK: - The async protocol shell

    @MainActor
    func testTheProviderAnswersThroughTheProtocolFromTheCurrentSnapshot() async {
        // The holder stands in for `SymbolIndexModel`'s published `index`, and is
        // `@MainActor` for the same reason the model is: that is where the
        // provider's closures read, so the ranking pass off-main can only ever see
        // a copy.
        let holder = IndexHolder(index(["a.swift": [symbol("Worker", kind: .type, in: "a.swift", line: 7)]]))
        let root = self.root
        let provider = SymbolIntelligenceProvider(index: { holder.index }, projectRoot: { root })

        let definitions = await provider.definitions(for: definitionRequest("Worker", from: "a.swift"))
        XCTAssertEqual(definitions.map(\.displayLabel), ["Worker — a.swift:7"])

        let completions = await provider.completions(
            for: completionRequest("Wor", from: "a.swift", text: "Worker")
        )
        XCTAssertEqual(completions.map(\.text), ["Worker"])

        // The snapshot is read per request, so a rebuilt index is picked up
        // without reconstructing the provider.
        holder.index = index(["a.swift": [symbol("Worker2", kind: .type, in: "a.swift")]])
        let afterRebuild = await provider.definitions(for: definitionRequest("Worker"))
        XCTAssertTrue(afterRebuild.isEmpty)
    }

    func testTheFixedSnapshotConvenienceInitializerAnswersTheSameWay() async {
        let store = index(["a.swift": [symbol("run", in: "a.swift", line: 3)]])
        let provider = SymbolIntelligenceProvider(index: store, projectRoot: root)
        let definitions = await provider.definitions(for: definitionRequest("run"))
        XCTAssertEqual(definitions.map(\.displayLabel), ["run — a.swift:3"])
    }

    /// Both questions answered through the *existential*, which is how both
    /// platform layers hold the provider. The point is substitutability rather
    /// than the answers — phase 2 swaps an LSP-backed implementation in behind
    /// this protocol, so a call that only ever type-checks against the concrete
    /// type would not prove the seam carries the feature.
    func testBothQuestionsAnswerThroughTheExistentialSeam() async {
        let store = index(["a.swift": [symbol("Worker", kind: .type, in: "a.swift", line: 7)]])
        let provider: any CodeIntelligenceProviding = SymbolIntelligenceProvider(
            index: store,
            projectRoot: root
        )

        let definitions = await provider.definitions(for: definitionRequest("Worker", from: "a.swift"))
        XCTAssertEqual(definitions.map(\.displayLabel), ["Worker — a.swift:7"])

        let completions = await provider.completions(
            for: completionRequest("Wor", from: "a.swift", text: "Worker")
        )
        XCTAssertEqual(completions, [CompletionItem(text: "Worker", kind: .type, isFromCurrentFile: true)])
    }
}
