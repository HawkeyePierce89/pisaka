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

    /// `language` defaults to `nil` — the state every pre-fuzzy test was written
    /// in, and the one in which no keyword is offered.
    private func completionRequest(
        _ prefix: String,
        from file: String? = nil,
        text: String = "",
        language: SyntaxLanguage? = nil
    ) -> CompletionRequest {
        CompletionRequest(prefix: prefix, fileURL: file.map(fileURL), text: text, language: language)
    }

    /// A request in *member* position — what the editor builds after a typed
    /// `.`. `prefixRange` is irrelevant to the provider (only the two editor
    /// layers insert), so it is the empty range the scanner reports for an
    /// unrelated offset.
    private func memberRequest(
        _ prefix: String = "",
        receiver: String?,
        from file: String? = nil,
        text: String = "",
        language: SyntaxLanguage? = nil
    ) -> CompletionRequest {
        CompletionRequest(
            prefix: prefix,
            fileURL: file.map(fileURL),
            text: text,
            language: language,
            member: IdentifierScanner.MemberContext(
                receiver: receiver,
                prefixRange: NSRange(location: 0, length: prefix.utf16.count)
            )
        )
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

    func testDefinitionsAreCappedAfterRanking() {
        // `symbols.scm` captures Markdown headings and top-level JSON/YAML keys
        // too, so one name really can be declared by hundreds of files — and both
        // surfaces build one menu item or dialog button per candidate.
        var groups: [String: [Symbol]] = [:]
        for i in 0..<120 {
            let file = String(format: "f%03d.md", i)
            groups[file] = [symbol("Overview", kind: .type, in: file)]
        }
        // Sorts last by path, so it can only survive the cap by being ranked first.
        groups["zzz.md"] = [symbol("Overview", kind: .type, in: "zzz.md")]
        let store = index(groups)

        let found = SymbolIntelligenceProvider.definitions(
            for: definitionRequest("Overview", from: "zzz.md"),
            in: store,
            projectRoot: root
        )
        XCTAssertEqual(found.count, SymbolIntelligenceProvider.defaultDefinitionLimit)
        XCTAssertEqual(found.first?.relativePath, "zzz.md")

        XCTAssertEqual(
            SymbolIntelligenceProvider.definitions(
                for: definitionRequest("Overview"),
                in: store,
                projectRoot: root,
                limit: 3
            ).map(\.relativePath),
            ["f000.md", "f001.md", "f002.md"]
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

    // MARK: - Completions: fuzzy matching

    /// The headline of the phase: a camelCase query reaches a name it is not a
    /// prefix of at all.
    func testACamelCaseQueryReachesAHumpedName() {
        let store = index(["a.swift": [symbol("ArrayBuffer", kind: .type, in: "a.swift")]])
        for query in ["aBu", "arrBuf", "buf"] {
            let items = SymbolIntelligenceProvider.completions(
                for: completionRequest(query, from: "a.swift"),
                in: store
            )
            XCTAssertEqual(items.map(\.text), ["ArrayBuffer"], "query \(query)")
        }
        // …and the rule that keeps the widened set intelligible: the first typed
        // character has to land on a word boundary.
        XCTAssertTrue(
            SymbolIntelligenceProvider.completions(
                for: completionRequest("rray", from: "a.swift"),
                in: store
            ).isEmpty
        )
    }

    /// Both candidates are fuzzy, in the same file, from the same source, so only
    /// the `offBoundary` sub-key can decide — and it puts the intentional-looking
    /// match first even though the scattered one is *shorter*.
    func testBoundaryHittingFuzzyMatchesOutrankScatteredOnes() {
        let store = index([
            "a.swift": [
                symbol("aBigCat", kind: .type, in: "a.swift", at: 0),
                symbol("aback", in: "a.swift", at: 40)
            ]
        ])
        let items = SymbolIntelligenceProvider.completions(
            for: completionRequest("abc", from: "a.swift"),
            in: store
        )
        XCTAssertEqual(items.map(\.text), ["aBigCat", "aback"])
    }

    /// Match quality is the *first* key, so a literal prefix wins over a fuzzy
    /// match that every later tie-break would have preferred: the fuzzy candidate
    /// here is shorter, alphabetically earlier, and equally local.
    func testAnExactCasePrefixOutranksAShorterFuzzyMatch() {
        let store = index([
            "a.swift": [
                symbol("arrayBuffer", in: "a.swift", at: 0),
                symbol("aRowRef", in: "a.swift", at: 40)
            ]
        ])
        let items = SymbolIntelligenceProvider.completions(
            for: completionRequest("arr", from: "a.swift"),
            in: store
        )
        // `aRowRef` is a boundary-clean fuzzy match (a·R·R), shorter, and sorts
        // first lexicographically — every later key prefers it, and it still loses.
        XCTAssertEqual(items.map(\.text), ["arrayBuffer", "aRowRef"])
    }

    // MARK: - Completions: the keyword source

    func testKeywordsOfTheRequestedLanguageAreOffered() {
        let items = SymbolIntelligenceProvider.completions(
            for: completionRequest("gua", from: "a.swift", language: .swift),
            in: SymbolIndex()
        )
        XCTAssertEqual(items.map(\.text), ["guard"])
        // A keyword is not a declaration — nothing to jump to, nothing to render
        // an icon for.
        XCTAssertEqual(items.first?.kind, nil)
    }

    /// Isolated from the current-file rule, which outranks the source rule: the
    /// symbol, the keyword and the word all belong to the same file here, the way
    /// `testSymbolsOutrankBareBufferWords` isolates its own rule.
    func testKeywordsRankBelowSymbolsAndAboveBareBufferWords() {
        let store = index(["a.swift": [symbol("gutter", kind: .property, in: "a.swift")]])
        let items = SymbolIntelligenceProvider.completions(
            for: completionRequest("gu", from: "a.swift", text: "gulp", language: .swift),
            in: store
        )
        // Length runs the other way (gulp 4 < guard 5 < gutter 6), so only the
        // source rule can produce this order.
        XCTAssertEqual(items.map(\.text), ["gutter", "guard", "gulp"])
        XCTAssertEqual(items.map(\.isFromCurrentFile), [true, true, true])
    }

    /// A symbol in *another* file loses to a keyword: rule 2 (current file)
    /// outranks rule 3 (source), and a keyword is as local as the file's language.
    func testAKeywordOutranksASymbolDeclaredInAnotherFile() {
        let store = index(["z.swift": [symbol("guardian", kind: .type, in: "z.swift")]])
        let items = SymbolIntelligenceProvider.completions(
            for: completionRequest("guar", from: "a.swift", language: .swift),
            in: store
        )
        XCTAssertEqual(items.map(\.text), ["guard", "guardian"])
    }

    func testAKeywordAlsoPresentInTheBufferAppearsOnce() {
        let items = SymbolIntelligenceProvider.completions(
            for: completionRequest("gua", from: "a.swift", text: "guard let x = y", language: .swift),
            in: SymbolIndex()
        )
        XCTAssertEqual(items.map(\.text), ["guard"])
    }

    /// A language the editor could not resolve contributes no vocabulary at all —
    /// Swift's `guard` while typing in an unclassified buffer is a worse answer
    /// than nothing.
    func testANilLanguageYieldsNoKeywords() {
        XCTAssertTrue(
            SymbolIntelligenceProvider.completions(
                for: completionRequest("gua", from: "a.swift"),
                in: SymbolIndex()
            ).isEmpty
        )
        // The same holds for a language that deliberately has no list.
        XCTAssertTrue(
            SymbolIntelligenceProvider.completions(
                for: completionRequest("tru", from: "a.json", language: .json),
                in: SymbolIndex()
            ).isEmpty
        )
    }

    /// The separation the two features share a provider across: keywords feed
    /// completion only, because a keyword has no declaration site to jump to.
    func testDefinitionsNeverContainKeywords() {
        let store = index(["a.swift": [symbol("guardian", kind: .type, in: "a.swift")]])
        for spelling in ["guard", "func", "return"] {
            XCTAssertTrue(
                SymbolIntelligenceProvider.definitions(
                    for: definitionRequest(spelling, from: "a.swift"),
                    in: store,
                    projectRoot: root
                ).isEmpty,
                "definitions for \(spelling)"
            )
        }
    }

    // MARK: - Completions: member mode

    /// The headline of the member branch: a typed dot with nothing after it
    /// still answers, and it answers with members *only* — the kinds that hang
    /// off a type and actually name one.
    func testATypedDotListsMembersAndExcludesEverythingElse() {
        let store = index([
            "a.swift": [
                symbol("Worker", kind: .type, in: "a.swift", at: 0),
                symbol("run", kind: .method, in: "a.swift", at: 20, container: "Worker"),
                symbol("total", kind: .property, in: "a.swift", at: 40, container: "Worker"),
                symbol("max", kind: .constant, in: "a.swift", at: 60, container: "Worker"),
                symbol("helper", in: "a.swift", at: 80),
                // A file-scope constant: the right *kind*, but nothing to hang
                // off, so a dot cannot reach it.
                symbol("limit", kind: .constant, in: "a.swift", at: 100)
            ]
        ])
        let items = SymbolIntelligenceProvider.completions(
            for: memberRequest(receiver: nil),
            in: store
        )
        // Every candidate ties on quality (nothing typed) and on container rank
        // (no receiver), so the ordinary length-then-lexicographic keys decide.
        XCTAssertEqual(items.map(\.text), ["max", "run", "total"])
    }

    /// The receiver heuristic, isolated: `alpha` is shorter, alphabetically
    /// earlier and just as local, so only the container key can put `zeta` first.
    func testTheReceiversOwnContainerRanksFirst() {
        let store = index([
            "a.swift": [
                symbol("Worker", kind: .type, in: "a.swift", at: 0),
                symbol("zeta", kind: .method, in: "a.swift", at: 20, container: "Worker"),
                symbol("Other", kind: .type, in: "a.swift", at: 40),
                symbol("alpha", kind: .property, in: "a.swift", at: 60, container: "Other")
            ]
        ])
        let items = SymbolIntelligenceProvider.completions(
            for: memberRequest(receiver: "Worker"),
            in: store
        )
        XCTAssertEqual(items.map(\.text), ["zeta", "alpha"])
    }

    /// Two containers declaring the same member name collapse to one entry — and
    /// the survivor is the receiver's, which is the whole point of the boost.
    func testAnIdenticallyNamedMemberResolvesToTheReceiversOwn() {
        let store = index([
            "a.swift": [
                symbol("Worker", kind: .type, in: "a.swift", at: 0),
                symbol("run", kind: .method, in: "a.swift", at: 20, container: "Worker")
            ],
            // Sorts *before* the receiver's file, so storage order alone would
            // have offered this one.
            "0.swift": [
                symbol("Other", kind: .type, in: "0.swift", at: 0),
                symbol("run", kind: .property, in: "0.swift", at: 20, container: "Other")
            ]
        ])
        let items = SymbolIntelligenceProvider.completions(
            for: memberRequest(receiver: "Worker"),
            in: store
        )
        XCTAssertEqual(items.map(\.text), ["run"])
        XCTAssertEqual(items.first?.kind, .method)
    }

    /// The heuristic is name-based but not credulous: it asks whether the
    /// receiver spells a *type*. A function of the same name promotes nothing.
    func testAReceiverNamingAFunctionGetsNoContainerBoost() {
        func store(receiverKind: SymbolKind) -> SymbolIndex {
            index([
                "a.swift": [
                    symbol("worker", kind: receiverKind, in: "a.swift", at: 0),
                    symbol("longMember", kind: .method, in: "a.swift", at: 20, container: "worker"),
                    symbol("Other", kind: .type, in: "a.swift", at: 40),
                    symbol("ab", kind: .property, in: "a.swift", at: 60, container: "Other")
                ]
            ])
        }

        // A function named `worker` says nothing about what `worker.` offers, so
        // the ordinary keys decide and the shorter name leads.
        XCTAssertEqual(
            SymbolIntelligenceProvider.completions(
                for: memberRequest(receiver: "worker"),
                in: store(receiverKind: .function)
            ).map(\.text),
            ["ab", "longMember"]
        )
        // The identical project with `worker` declared as a type flips it — which
        // is what proves the first assertion is the boost's absence and not some
        // other rule.
        XCTAssertEqual(
            SymbolIntelligenceProvider.completions(
                for: memberRequest(receiver: "worker"),
                in: store(receiverKind: .type)
            ).map(\.text),
            ["longMember", "ab"]
        )
    }

    /// A member prefix narrows the list with the same matcher as everything else,
    /// fuzzy tiers included.
    func testAMemberPrefixFiltersFuzzily() {
        let store = index([
            "a.swift": [
                symbol("doRequest", kind: .method, in: "a.swift", at: 0, container: "Worker"),
                symbol("total", kind: .property, in: "a.swift", at: 20, container: "Worker")
            ]
        ])
        let items = SymbolIntelligenceProvider.completions(
            for: memberRequest("dR", receiver: "worker"),
            in: store
        )
        XCTAssertEqual(items.map(\.text), ["doRequest"])
    }

    /// No language lets a keyword follow a dot, so the keyword source is not
    /// consulted in member mode at all — even with a language on the request and a
    /// prefix that would otherwise match one.
    func testKeywordsAreNeverOfferedAfterADot() {
        let store = index([
            "a.swift": [symbol("guardValue", kind: .property, in: "a.swift", container: "Worker")]
        ])
        let items = SymbolIntelligenceProvider.completions(
            for: memberRequest("gua", receiver: "worker", from: "a.swift", language: .swift),
            in: store
        )
        XCTAssertEqual(items.map(\.text), ["guardValue"])
    }

    /// The stricter half of the fallback rule: a bare dot the index cannot answer
    /// shows **nothing**, rather than every word in the buffer. A dot inside a
    /// JSON value or a comment is exactly this request.
    func testABareDotWithNoMatchingMemberOffersNothingAtAll() {
        let items = SymbolIntelligenceProvider.completions(
            for: memberRequest(receiver: nil, from: "a.json", text: "worker workshop wonder"),
            in: SymbolIndex()
        )
        XCTAssertTrue(items.isEmpty)
    }

    /// …while a member prefix the index cannot answer *does* fall back: the user
    /// typed real characters, and a word from the buffer beats an empty popup
    /// when the receiver's type simply is not indexed.
    func testANonEmptyMemberPrefixFallsBackToBufferWords() {
        let items = SymbolIntelligenceProvider.completions(
            for: memberRequest("wor", receiver: "thing", from: "a.swift", text: "worker workshop"),
            in: SymbolIndex()
        )
        XCTAssertEqual(items.map(\.text), ["worker", "workshop"])
        XCTAssertEqual(items.map(\.kind), [nil, nil])
    }

    /// And the fallback is a fallback: one matching member is enough to suppress
    /// it entirely, so the buffer's words never dilute a real member list.
    func testTheFallbackIsSuppressedWhenAnyMemberMatches() {
        let store = index([
            "a.swift": [symbol("workUnit", kind: .method, in: "a.swift", container: "Worker")]
        ])
        let items = SymbolIntelligenceProvider.completions(
            for: memberRequest("wor", receiver: nil, from: "a.swift", text: "worker workshop"),
            in: store
        )
        XCTAssertEqual(items.map(\.text), ["workUnit"])
    }

    func testMemberResultsAreCappedAndDeduplicated() {
        var groups: [String: [Symbol]] = [:]
        for container in 0..<10 {
            let file = String(format: "f%02d.swift", container)
            groups[file] = (0..<10).map { member in
                symbol(
                    "member\(member)",
                    kind: .method,
                    in: file,
                    at: member * 20,
                    container: "C\(container)"
                )
            }
        }
        let items = SymbolIntelligenceProvider.completions(
            for: memberRequest(receiver: nil),
            in: index(groups),
            limit: 5
        )
        XCTAssertEqual(items.count, 5)
        // Ten containers declare each of these names; each appears once.
        XCTAssertEqual(Set(items.map(\.text)).count, 5)
        XCTAssertEqual(items.map(\.text), (0..<5).map { "member\($0)" })
    }

    /// The container key sits **above** match quality, so a fuzzy match in the
    /// receiver's own type outranks a literal prefix match elsewhere.
    ///
    /// Every other member test passes an empty prefix, where `memberQuality` is a
    /// constant for every candidate and the quality key cannot discriminate at
    /// all — so swapping the first two comparisons in `isOrderedBefore` would
    /// pass them. This one is the discriminating case.
    func testTheContainerKeyOutranksMatchQuality() {
        let store = index([
            "a.swift": [
                symbol("Worker", kind: .type, in: "a.swift", at: 0),
                // `dr` reaches this only as a subsequence (fuzzy tier).
                symbol("doRequest", kind: .method, in: "a.swift", at: 20, container: "Worker"),
                symbol("Other", kind: .type, in: "a.swift", at: 40),
                // …while `dr` is a literal, case-sensitive prefix of this one.
                symbol("drab", kind: .property, in: "a.swift", at: 60, container: "Other")
            ]
        ])
        let items = SymbolIntelligenceProvider.completions(
            for: memberRequest("dr", receiver: "Worker"),
            in: store
        )
        XCTAssertEqual(items.map(\.text), ["doRequest", "drab"])
    }

    /// Member mode honours ranking rule 2 (current file first) like every other
    /// path — and reports `isFromCurrentFile` for the surfaces that render it.
    ///
    /// `al` is a case-sensitive prefix of both, so the quality key ties;
    /// `alphaValue` is the *longer* name, so only the file key can put it first.
    func testAMemberInTheCurrentFileOutranksAnEqualMatchElsewhere() {
        let store = index([
            "a.swift": [
                symbol("A", kind: .type, in: "a.swift", at: 0),
                symbol("alphaValue", kind: .method, in: "a.swift", at: 20, container: "A")
            ],
            "z.swift": [
                symbol("Z", kind: .type, in: "z.swift", at: 0),
                symbol("alp", kind: .property, in: "z.swift", at: 20, container: "Z")
            ]
        ])
        let items = SymbolIntelligenceProvider.completions(
            for: memberRequest("al", receiver: nil, from: "a.swift"),
            in: store
        )
        XCTAssertEqual(items.map(\.text), ["alphaValue", "alp"])
        XCTAssertEqual(items.map(\.isFromCurrentFile), [true, false])
    }

    /// The current file's members survive a member set larger than the pre-cap —
    /// the member-path twin of
    /// `testCurrentFileSymbolsSurviveAPrefixMatchSetLargerThanThePreCap`.
    ///
    /// `members(matching:limit:)` walks the project in file-key order and stops at
    /// `memberCandidateLimit`, so without the separate `members(inFile:)` lookup
    /// the file being typed in contributes nothing whenever its path sorts after
    /// the cut — and the promoted-container rescue does not help, because a
    /// lowercase receiver spells no declared type.
    func testCurrentFileMembersSurviveAMemberSetLargerThanThePreCap() {
        var groups: [String: [Symbol]] = [:]
        for container in 0..<50 {
            let file = String(format: "f%02d.swift", container)
            groups[file] = (0..<10).map { member in
                symbol(
                    "filler\(container)_\(member)",
                    kind: .method,
                    in: file,
                    at: member * 20,
                    container: "C\(container)"
                )
            }
        }
        // Sorts last, well past the 400-member pre-cap.
        groups["zzz.swift"] = [
            symbol("myOwnMethod", kind: .method, in: "zzz.swift", at: 0, container: "Mine")
        ]

        let items = SymbolIntelligenceProvider.completions(
            for: memberRequest(receiver: "thing", from: "zzz.swift"),
            in: index(groups)
        )
        XCTAssertEqual(items.first?.text, "myOwnMethod")
        XCTAssertEqual(items.first?.isFromCurrentFile, true)
    }

    /// The promoted container's members are collected uncapped, so the receiver's
    /// own type is answered however its file happens to sort.
    ///
    /// Without that separate lookup, `Worker.` in a project with more than
    /// `memberCandidateLimit` members offers an alphabetical slice of other
    /// types' members and none of `Worker`'s — the exact failure the boost exists
    /// to prevent.
    func testThePromotedContainersMembersSurviveThePreCap() {
        var groups: [String: [Symbol]] = [:]
        for container in 0..<50 {
            let file = String(format: "f%02d.swift", container)
            groups[file] = (0..<10).map { member in
                symbol(
                    "filler\(container)_\(member)",
                    kind: .method,
                    in: file,
                    at: member * 20,
                    container: "C\(container)"
                )
            }
        }
        groups["zzz.swift"] = [
            symbol("Worker", kind: .type, in: "zzz.swift", at: 0),
            symbol("workerOnly", kind: .method, in: "zzz.swift", at: 20, container: "Worker")
        ]

        let items = SymbolIntelligenceProvider.completions(
            for: memberRequest(receiver: "Worker"),
            in: index(groups)
        )
        XCTAssertEqual(items.first?.text, "workerOnly")
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

    func testCurrentFileSymbolsSurviveAPrefixMatchSetLargerThanThePreCap() {
        // The index truncates prefix matches in *file-key* order, so in a project
        // with more matches than the pre-cap the current file is included or not
        // depending on how its path happens to sort. Here it sorts last and is
        // pushed well past the cut, which is precisely the case where ranking rule
        // 2 — current file first — matters most.
        var groups: [String: [Symbol]] = [:]
        for i in 0..<400 {
            let file = String(format: "a%03d.swift", i)
            groups[file] = [symbol("runnerNumber\(i)", in: file)]
        }
        groups["zzz.swift"] = [symbol("runnerLocal", kind: .property, in: "zzz.swift")]

        let items = SymbolIntelligenceProvider.completions(
            for: completionRequest("runner", from: "zzz.swift"),
            in: index(groups),
            limit: 5
        )

        XCTAssertEqual(items.first?.text, "runnerLocal")
        XCTAssertEqual(items.first?.isFromCurrentFile, true)
        // It arrives as the declaration it is, not as a bare harvested word — the
        // buffer text is empty here, so nothing else could have supplied it.
        XCTAssertEqual(items.first?.kind, .property)
        // And it is not duplicated by the bucket's own copy of it.
        XCTAssertEqual(items.filter { $0.text == "runnerLocal" }.count, 1)
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
        // `wonder` is a *fuzzy* match for `wor` (w-o…r), so the widened matcher
        // offers it too — but strictly behind both literal prefixes, because
        // match quality is the first ranking key.
        XCTAssertEqual(items.map(\.text), ["worker", "workshop", "wonder"])
        XCTAssertEqual(items.map(\.kind), [nil, nil, nil])
        XCTAssertEqual(items.map(\.isFromCurrentFile), [true, true, true])
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
