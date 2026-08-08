import XCTest
@testable import PisakaCore

/// Covers the two pure primitives the whole code-intelligence feature stands on:
/// `SymbolKind`'s strict capture-name mapping, `Symbol`'s display helper, and
/// `SymbolIndex`'s replace/remove semantics, its two lookups and its
/// canonical-path keying.
final class SymbolIndexTests: XCTestCase {

    // MARK: - Helpers

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private func symbol(
        _ name: String,
        kind: SymbolKind = .function,
        at location: Int = 0,
        in file: String = "/tmp/pisaka-symbols/a.swift",
        container: String? = nil,
        line: Int = 1
    ) -> Symbol {
        Symbol(
            name: name,
            kind: kind,
            range: NSRange(location: location, length: name.utf16.count),
            fileURL: url(file),
            containerName: container,
            line: line
        )
    }

    // MARK: - SymbolKind

    func testCaptureNameResolvesEveryKind() {
        for kind in SymbolKind.allCases {
            XCTAssertEqual(SymbolKind(captureName: kind.captureName), kind)
            XCTAssertEqual(SymbolKind(captureName: "@" + kind.captureName), kind)
            // The `definition.` prefix is optional; the bare kind name resolves.
            XCTAssertEqual(SymbolKind(captureName: kind.rawValue), kind)
        }
    }

    /// Unknown captures are *dropped*, not degraded — the deliberate difference
    /// from `SyntaxTokenKind(captureName:)`, so a query typo cannot inject a
    /// garbage symbol into the jump list.
    func testUnknownCaptureNamesAreRejected() {
        XCTAssertNil(SymbolKind(captureName: "definition.klass"))
        XCTAssertNil(SymbolKind(captureName: "definition.type.nested"))
        XCTAssertNil(SymbolKind(captureName: "keyword"))
        XCTAssertNil(SymbolKind(captureName: ""))
        XCTAssertNil(SymbolKind(captureName: "@container"))
        XCTAssertNil(SymbolKind(captureName: SymbolKind.containerCaptureName))
    }

    func testCaptureNamesAreSpelledUnderTheDefinitionPrefix() {
        XCTAssertEqual(SymbolKind.type.captureName, "definition.type")
        XCTAssertEqual(SymbolKind.heading.captureName, "definition.heading")
    }

    func testQualifiedNameUsesTheContainerWhenPresent() {
        XCTAssertEqual(symbol("run", container: "Worker").qualifiedName, "Worker.run")
        XCTAssertEqual(symbol("run").qualifiedName, "run")
        XCTAssertEqual(symbol("run", container: "").qualifiedName, "run")
    }

    // MARK: - replace / remove

    func testReplaceLeavesNoResidueOfThePreviousCall() {
        var index = SymbolIndex()
        let file = "/tmp/pisaka-symbols/a.swift"
        index.replace(fileURL: url(file), symbols: [symbol("oldName", in: file)])
        XCTAssertEqual(index.symbols(named: "oldName").count, 1)

        index.replace(fileURL: url(file), symbols: [symbol("newName", in: file)])

        XCTAssertTrue(index.symbols(named: "oldName").isEmpty)
        XCTAssertTrue(index.symbols(matching: "old", limit: 10).isEmpty)
        XCTAssertEqual(index.symbols(named: "newName").count, 1)
        XCTAssertEqual(index.symbols(matching: "new", limit: 10).count, 1)
        XCTAssertEqual(index.symbols(inFile: url(file)).map(\.name), ["newName"])
        XCTAssertEqual(index.indexedFileCount, 1)
    }

    func testReplaceIsIdempotent() {
        var index = SymbolIndex()
        let file = "/tmp/pisaka-symbols/a.swift"
        let symbols = [symbol("run", in: file), symbol("stop", at: 10, in: file)]
        index.replace(fileURL: url(file), symbols: symbols)
        index.replace(fileURL: url(file), symbols: symbols)

        XCTAssertEqual(index.symbols(named: "run").count, 1)
        XCTAssertEqual(index.symbols(matching: "s", limit: 10).count, 1)
        XCTAssertEqual(index.symbols(inFile: url(file)).count, 2)
    }

    func testReplaceLeavesNoResidueWhenAFileDeclaresTheSameNameTwice() {
        var index = SymbolIndex()
        let file = "/tmp/pisaka-symbols/a.swift"
        // Overloads, or a name declared once per `#if` branch: the purge sweeps
        // each bucket once per *distinct* name, so a repeated one must still take
        // all of its entries with it rather than the first sweep's worth.
        index.replace(
            fileURL: url(file),
            symbols: [symbol("run", in: file), symbol("run", at: 10, in: file), symbol("stop", at: 20, in: file)]
        )
        XCTAssertEqual(index.symbols(named: "run").count, 2)

        index.replace(fileURL: url(file), symbols: [symbol("run", in: file)])

        XCTAssertEqual(index.symbols(named: "run").count, 1)
        XCTAssertEqual(index.symbols(matching: "r", limit: 10).count, 1)
        XCTAssertTrue(index.symbols(named: "stop").isEmpty)
        XCTAssertTrue(index.symbols(matching: "s", limit: 10).isEmpty)
    }

    func testReplaceOnlyPurgesTheFileItRewrites() {
        var index = SymbolIndex()
        let a = "/tmp/pisaka-symbols/a.swift"
        let b = "/tmp/pisaka-symbols/b.swift"
        // Both files contribute to the same name and prefix buckets; rewriting one
        // must leave the other's entries in both.
        index.replace(fileURL: url(a), symbols: [symbol("run", in: a), symbol("rest", at: 10, in: a)])
        index.replace(fileURL: url(b), symbols: [symbol("run", in: b), symbol("rise", at: 10, in: b)])

        index.replace(fileURL: url(a), symbols: [])

        XCTAssertEqual(index.symbols(named: "run").map(\.fileURL), [url(b)])
        XCTAssertEqual(index.symbols(matching: "r", limit: 10).map(\.name), ["run", "rise"])
        XCTAssertTrue(index.symbols(named: "rest").isEmpty)
    }

    func testReplaceWithNoSymbolsStillCountsTheFileAsIndexed() {
        var index = SymbolIndex()
        index.replace(fileURL: url("/tmp/pisaka-symbols/empty.swift"), symbols: [])
        XCTAssertEqual(index.indexedFileCount, 1)
        XCTAssertFalse(index.isEmpty)
    }

    func testReplaceByKeyMatchesReplaceByURL() {
        let file = "/tmp/pisaka-symbols/a.swift"
        let key = SymbolIndex.fileKey(for: url(file))

        var byKey = SymbolIndex()
        byKey.replace(fileKey: key, symbols: [symbol("run", in: file)])
        var byURL = SymbolIndex()
        byURL.replace(fileURL: url(file), symbols: [symbol("run", in: file)])

        // The caller-supplied key is the one the URL would have resolved to, so
        // the two stores are indistinguishable — including to `remove(fileKey:)`,
        // which is what the index's bookkeeping owner calls to undo either.
        XCTAssertEqual(byKey, byURL)
        XCTAssertEqual(byKey.symbols(inFile: url(file)).map(\.name), ["run"])

        byKey.remove(fileKey: key)
        XCTAssertTrue(byKey.isEmpty)
    }

    func testRemoveErasesTheFileFromBothBuckets() {
        var index = SymbolIndex()
        let gone = "/tmp/pisaka-symbols/gone.swift"
        let kept = "/tmp/pisaka-symbols/kept.swift"
        index.replace(fileURL: url(gone), symbols: [symbol("shared", in: gone)])
        index.replace(fileURL: url(kept), symbols: [symbol("shared", in: kept)])

        index.remove(fileURL: url(gone))

        XCTAssertEqual(index.symbols(named: "shared").map(\.fileURL), [url(kept)])
        XCTAssertEqual(index.symbols(matching: "sh", limit: 10).map(\.fileURL), [url(kept)])
        XCTAssertTrue(index.symbols(inFile: url(gone)).isEmpty)
        XCTAssertEqual(index.indexedFileCount, 1)
    }

    func testRemovingAnUnknownFileIsANoOp() {
        var index = SymbolIndex()
        index.replace(fileURL: url("/tmp/pisaka-symbols/a.swift"), symbols: [symbol("run")])
        index.remove(fileURL: url("/tmp/pisaka-symbols/never-indexed.swift"))
        XCTAssertEqual(index.indexedFileCount, 1)
        XCTAssertEqual(index.symbols(named: "run").count, 1)
    }

    func testEmptyIndexAnswersEverythingEmpty() {
        let index = SymbolIndex()
        XCTAssertTrue(index.isEmpty)
        XCTAssertEqual(index.indexedFileCount, 0)
        XCTAssertTrue(index.symbols(named: "run").isEmpty)
        XCTAssertTrue(index.symbols(matching: "r", limit: 10).isEmpty)
        XCTAssertTrue(index.symbols(inFile: url("/tmp/pisaka-symbols/a.swift")).isEmpty)
        XCTAssertTrue(index.members(matching: "", limit: 10).isEmpty)
        XCTAssertTrue(index.members(inContainer: "Worker").isEmpty)
        XCTAssertFalse(index.declaresType(named: "Worker"))
    }

    // MARK: - Lookups

    /// Exact lookup is case-sensitive (`Foo` and `foo` are distinct
    /// declarations); completion lookup is not (typing `arr` must still offer
    /// `ArrayBuffer`).
    func testCaseHandlingDiffersBetweenExactAndPrefixLookup() {
        var index = SymbolIndex()
        let file = "/tmp/pisaka-symbols/case.swift"
        index.replace(
            fileURL: url(file),
            symbols: [
                symbol("Widget", kind: .type, at: 0, in: file),
                symbol("widget", kind: .variable, at: 20, in: file),
            ]
        )

        XCTAssertEqual(index.symbols(named: "Widget").map(\.kind), [.type])
        XCTAssertEqual(index.symbols(named: "widget").map(\.kind), [.variable])
        XCTAssertTrue(index.symbols(named: "WIDGET").isEmpty)

        XCTAssertEqual(index.symbols(matching: "wid", limit: 10).count, 2)
        XCTAssertEqual(index.symbols(matching: "WID", limit: 10).count, 2)
        XCTAssertEqual(index.symbols(matching: "Widg", limit: 10).count, 2)
    }

    func testPrefixLookupRejectsAnEmptyPrefixAndANonPositiveLimit() {
        var index = SymbolIndex()
        index.replace(fileURL: url("/tmp/pisaka-symbols/a.swift"), symbols: [symbol("run")])
        XCTAssertTrue(index.symbols(matching: "", limit: 10).isEmpty)
        XCTAssertTrue(index.symbols(matching: "r", limit: 0).isEmpty)
        XCTAssertTrue(index.symbols(named: "").isEmpty)
    }

    /// The lookup is a *superset* of the prefix lookup it replaced: a prefix
    /// still matches, a subsequence starting on a word boundary now matches too,
    /// and a name whose only occurrence of the first typed character sits inside
    /// a word still does not — the rule `FuzzyMatch` states and this bucket is
    /// keyed for.
    func testMatchingWidensPrefixLookupButStillAnchorsAtAWordBoundary() {
        var index = SymbolIndex()
        let file = "/tmp/pisaka-symbols/a.swift"
        index.replace(
            fileURL: url(file),
            symbols: [
                symbol("runLoop", in: file),
                symbol("rerun", at: 20, in: file),
                symbol("prerun", at: 40, in: file),
            ]
        )
        // `runLoop` by prefix, `rerun` as a subsequence anchored on its own `r`;
        // `prerun` contains "run" outright but cannot start the match on a
        // boundary, so it stays out.
        XCTAssertEqual(index.symbols(matching: "run", limit: 10).map(\.name), ["runLoop", "rerun"])
        XCTAssertEqual(index.symbols(matching: "runL", limit: 10).map(\.name), ["runLoop"])
    }

    /// The camelCase case the widened bucket exists for: a hump is a bucket key,
    /// so a query starting at the hump reaches the name — without giving up the
    /// plain prefix query, which reads the very same bucket.
    func testMatchingFindsACamelCaseNameFromAnyOfItsHumps() {
        var index = SymbolIndex()
        let file = "/tmp/pisaka-symbols/a.swift"
        index.replace(
            fileURL: url(file),
            symbols: [symbol("ArrayBuffer", kind: .type, in: file)]
        )

        for query in ["aBu", "arrBuf", "buf", "ArrayBuffer", "arr"] {
            XCTAssertEqual(
                index.symbols(matching: query, limit: 10).map(\.name),
                ["ArrayBuffer"],
                "expected \(query) to reach ArrayBuffer"
            )
        }
        // Off every boundary: the first typed character lands inside `Array`.
        XCTAssertTrue(index.symbols(matching: "rray", limit: 10).isEmpty)
    }

    /// The matcher and the bucket agree **at the cap**, which is what makes the
    /// one-bucket lookup exhaustive rather than nearly so.
    ///
    /// `wordBoundaryInitials` keeps only the first `maximumInitials` starts, and
    /// `symbols(matching:)` reads exactly the one bucket the query's first
    /// character names. If `FuzzyMatch.quality` accepted an anchor past the cap,
    /// a name with nine or more distinct boundary initials would be matchable but
    /// unreachable through the index — a hole that looks exactly like "not
    /// indexed yet", while the same query still found the name as a keyword or a
    /// harvested buffer word.
    func testTheMatcherAcceptsNoAnchorTheBucketCannotAnswer() {
        var index = SymbolIndex()
        let file = "/tmp/pisaka-symbols/a.swift"
        let name = "a_b_c_d_e_f_g_h_i_j"
        index.replace(fileURL: url(file), symbols: [symbol(name, kind: .type, in: file)])

        let initials = FuzzyMatch.wordBoundaryInitials(of: name)
        XCTAssertEqual(initials.count, FuzzyMatch.maximumInitials)
        for initial in initials {
            let query = String(initial)
            XCTAssertNotNil(FuzzyMatch.quality(of: name, matching: query), query)
            XCTAssertEqual(index.symbols(matching: query, limit: 10).map(\.name), [name], query)
        }
        // The boundaries past the cap: neither side may claim them.
        for query in ["i", "ij", "j"] {
            XCTAssertNil(FuzzyMatch.quality(of: name, matching: query), query)
            XCTAssertTrue(index.symbols(matching: query, limit: 10).isEmpty, query)
        }
    }

    /// A name filed under several humps has to be swept out of *all* of them, or
    /// a re-index leaves the old spelling answering a hump query forever.
    func testReplaceLeavesNoResidueInAnyHumpBucket() {
        var index = SymbolIndex()
        let file = "/tmp/pisaka-symbols/a.swift"
        index.replace(fileURL: url(file), symbols: [symbol("ArrayBuffer", kind: .type, in: file)])
        XCTAssertEqual(index.symbols(matching: "buf", limit: 10).count, 1)

        index.replace(fileURL: url(file), symbols: [symbol("ArrayView", kind: .type, in: file)])

        XCTAssertTrue(index.symbols(matching: "buf", limit: 10).isEmpty)
        XCTAssertTrue(index.symbols(matching: "aBu", limit: 10).isEmpty)
        XCTAssertEqual(index.symbols(matching: "vie", limit: 10).map(\.name), ["ArrayView"])
        XCTAssertEqual(index.symbols(matching: "arr", limit: 10).map(\.name), ["ArrayView"])
    }

    /// The cap is applied to the *ordered* result, so it is deterministic rather
    /// than "whichever matches happened to be stored first".
    func testPrefixLimitTruncatesTheOrderedResult() {
        var index = SymbolIndex()
        let file = "/tmp/pisaka-symbols/a.swift"
        index.replace(
            fileURL: url(file),
            symbols: (0..<5).map { symbol("run\($0)", at: $0 * 10, in: file) }
        )
        XCTAssertEqual(index.symbols(matching: "run", limit: 2).map(\.name), ["run0", "run1"])
    }

    /// The cut fills from the *literal prefix* matches first.
    ///
    /// Fuzzy matching widened the matched set by one to two orders of magnitude
    /// while the caller's cap did not, so a cut made purely in file-key order
    /// would decide which matches the ranking ever sees by how paths sort: here
    /// `setUp` is an exact prefix match for `se` and lives in the last-sorting
    /// file, behind more fuzzy-only matches than the cap allows. It has to
    /// survive anyway — the caller cannot rank a candidate it was never handed.
    func testTheLimitEvictsFuzzyMatchesBeforeLiteralPrefixMatches() {
        var index = SymbolIndex()
        let early = "/tmp/pisaka-symbols/aaa.swift"
        let late = "/tmp/pisaka-symbols/zzz.swift"
        // Fuzzy-only matches for `se`: an `s` word boundary, an `e` later on.
        index.replace(
            fileURL: url(early),
            symbols: (0..<10).map { symbol("sharedState\($0)", at: $0 * 10, in: early) }
        )
        index.replace(fileURL: url(late), symbols: [symbol("setUp", at: 0, in: late)])

        let found = index.symbols(matching: "se", limit: 3).map(\.name)
        XCTAssertTrue(found.contains("setUp"), "\(found)")
        XCTAssertEqual(found.count, 3)
        // The order handed back is still the one documented order, not the
        // split used to decide the cut.
        XCTAssertEqual(found, ["sharedState0", "sharedState1", "setUp"])
    }

    /// Ordering is file key, then location, then name — regardless of the order
    /// the files were indexed in.
    func testLookupsAreOrderedByFileKeyThenLocation() {
        var index = SymbolIndex()
        let b = "/tmp/pisaka-symbols/b.swift"
        let a = "/tmp/pisaka-symbols/a.swift"
        index.replace(
            fileURL: url(b),
            symbols: [symbol("run", at: 5, in: b, line: 2)]
        )
        index.replace(
            fileURL: url(a),
            symbols: [symbol("run", at: 30, in: a, line: 4), symbol("run", at: 1, in: a, line: 1)]
        )

        let found = index.symbols(named: "run")
        XCTAssertEqual(found.map(\.fileURL.path), [a, a, b])
        XCTAssertEqual(found.map(\.line), [1, 4, 2])
    }

    func testSymbolsInFileKeepExtractionOrder() {
        var index = SymbolIndex()
        let file = "/tmp/pisaka-symbols/a.swift"
        index.replace(
            fileURL: url(file),
            symbols: [symbol("second", at: 50, in: file), symbol("first", at: 1, in: file)]
        )
        XCTAssertEqual(index.symbols(inFile: url(file)).map(\.name), ["second", "first"])
    }

    func testUnicodeIdentifiersAreFoundByPrefix() {
        var index = SymbolIndex()
        let file = "/tmp/pisaka-symbols/u.swift"
        index.replace(fileURL: url(file), symbols: [symbol("Ünicode", kind: .type, in: file)])
        XCTAssertEqual(index.symbols(matching: "ün", limit: 10).count, 1)
        XCTAssertEqual(index.symbols(matching: "Ü", limit: 10).count, 1)
        XCTAssertEqual(index.symbols(named: "Ünicode").count, 1)
    }

    // MARK: - Members

    /// A small two-file project holding one of everything the member filter has
    /// to decide about.
    private func memberIndex() -> SymbolIndex {
        var index = SymbolIndex()
        let a = "/tmp/pisaka-symbols/a.swift"
        let b = "/tmp/pisaka-symbols/b.swift"
        index.replace(
            fileURL: url(a),
            symbols: [
                symbol("Worker", kind: .type, at: 0, in: a),
                symbol("doRequest", kind: .method, at: 10, in: a, container: "Worker"),
                symbol("retries", kind: .property, at: 20, in: a, container: "Worker"),
                symbol("timeout", kind: .constant, at: 30, in: a, container: "Worker"),
                symbol("freeFunction", kind: .function, at: 40, in: a),
                symbol("looseConstant", kind: .constant, at: 50, in: a),
                symbol("emptyContainer", kind: .property, at: 60, in: a, container: ""),
            ]
        )
        index.replace(
            fileURL: url(b),
            symbols: [
                symbol("worker", kind: .function, at: 0, in: b),
                symbol("retries", kind: .property, at: 10, in: b, container: "Client"),
            ]
        )
        return index
    }

    /// The typed-dot case: an empty query matches every member, and *only*
    /// members — a type, a free function and a container-less symbol are not
    /// reachable through a dot.
    func testEmptyMemberQueryReturnsEveryContainerCarryingMember() {
        let found = memberIndex().members(matching: "", limit: 100)
        XCTAssertEqual(found.map(\.name), ["doRequest", "retries", "timeout", "retries"])
        XCTAssertEqual(found.map(\.containerName), ["Worker", "Worker", "Worker", "Client"])
    }

    func testMemberQueryFiltersFuzzilyAndCaps() {
        let index = memberIndex()
        XCTAssertEqual(index.members(matching: "dR", limit: 10).map(\.name), ["doRequest"])
        // Both `retries` by prefix, and `doRequest` too: its `R` hump is a word
        // boundary, so `ret` is an anchored subsequence of it.
        XCTAssertEqual(
            index.members(matching: "ret", limit: 10).map(\.name),
            ["doRequest", "retries", "retries"]
        )
        XCTAssertEqual(index.members(matching: "retr", limit: 10).map(\.name), ["retries", "retries"])
        // The cap stops the ordered pass, so it takes the first file's members.
        XCTAssertEqual(index.members(matching: "", limit: 2).map(\.name), ["doRequest", "retries"])
        XCTAssertTrue(index.members(matching: "", limit: 0).isEmpty)
        XCTAssertTrue(index.members(matching: "zzz", limit: 10).isEmpty)
    }

    /// Case-sensitive, for the same reason `symbols(named:)` is: the receiver's
    /// spelling *is* the question being asked.
    func testMembersInContainerAreCaseSensitive() {
        let index = memberIndex()
        XCTAssertEqual(
            index.members(inContainer: "Worker").map(\.name),
            ["doRequest", "retries", "timeout"]
        )
        XCTAssertTrue(index.members(inContainer: "worker").isEmpty)
        XCTAssertTrue(index.members(inContainer: "WORKER").isEmpty)
        XCTAssertTrue(index.members(inContainer: "").isEmpty)
        XCTAssertEqual(index.members(inContainer: "Client").map(\.name), ["retries"])
    }

    /// The receiver heuristic asks about *types* only: a function named `worker`
    /// says nothing about what `worker.` will offer.
    func testDeclaresTypeIgnoresSameNamedNonTypes() {
        let index = memberIndex()
        XCTAssertTrue(index.declaresType(named: "Worker"))
        XCTAssertFalse(index.declaresType(named: "worker"))
        XCTAssertFalse(index.declaresType(named: "doRequest"))
        XCTAssertFalse(index.declaresType(named: "never-declared"))
        XCTAssertFalse(index.declaresType(named: ""))
    }

    /// Members live in the per-file storage, so removing a file takes its
    /// members with it — there is no second structure to fall out of step.
    func testRemovingAFileRemovesItsMembers() {
        var index = memberIndex()
        index.remove(fileURL: url("/tmp/pisaka-symbols/a.swift"))
        XCTAssertEqual(index.members(matching: "", limit: 100).map(\.containerName), ["Client"])
        XCTAssertTrue(index.members(inContainer: "Worker").isEmpty)
        XCTAssertFalse(index.declaresType(named: "Worker"))
    }

    // MARK: - Canonical keying

    /// `/tmp/…` and `/private/tmp/…` are the same file, so indexing through both
    /// spellings must not double-index it — the rule
    /// `ProjectSearchModel.bufferKey(for:)` already applies to open buffers.
    /// `canonical(_:)`'s `/private` stripping consults the file system, so the
    /// file has to exist for the two spellings to converge (the same reason
    /// `CanonicalPathTests` works on a real temporary directory).
    func testCanonicalPathKeyingCollapsesEquivalentSpellings() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let spelled = root.appendingPathComponent("a.swift")
        try Data("func run() {}".utf8).write(to: spelled)
        let firmlinked = url("/private" + spelled.path)
        XCTAssertEqual(SymbolIndex.fileKey(for: spelled), SymbolIndex.fileKey(for: firmlinked))

        var index = SymbolIndex()
        index.replace(fileURL: spelled, symbols: [symbol("run", in: spelled.path)])
        index.replace(fileURL: firmlinked, symbols: [symbol("run", in: firmlinked.path)])

        XCTAssertEqual(index.indexedFileCount, 1)
        XCTAssertEqual(index.symbols(named: "run").count, 1)
        XCTAssertEqual(index.symbols(inFile: spelled).count, 1)
        XCTAssertEqual(index.symbols(inFile: firmlinked).count, 1)

        index.remove(fileURL: firmlinked)
        XCTAssertTrue(index.isEmpty)
    }

    /// The same collapse through a real symlink: a tab opened via a symlinked
    /// directory and the traversal's own spelling are one entry.
    func testCanonicalPathKeyingCollapsesASymlinkedSpelling() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root.appendingPathComponent("real"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("real/a.swift")
        try Data("func run() {}".utf8).write(to: file)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("real"))
        let throughLink = link.appendingPathComponent("a.swift")

        var index = SymbolIndex()
        index.replace(fileURL: file, symbols: [symbol("run", in: file.path)])
        index.replace(fileURL: throughLink, symbols: [symbol("run", in: throughLink.path)])

        XCTAssertEqual(index.indexedFileCount, 1)
        XCTAssertEqual(index.symbols(named: "run").count, 1)
    }

    /// Relative-component and trailing-slash spellings resolve to the same key.
    func testCanonicalKeyingIgnoresDotComponents() {
        var index = SymbolIndex()
        let direct = url("/tmp/pisaka-symbols/a.swift")
        let indirect = url("/tmp/pisaka-symbols/./sub/../a.swift")
        index.replace(fileURL: direct, symbols: [symbol("run")])
        index.replace(fileURL: indirect, symbols: [symbol("run")])
        XCTAssertEqual(index.indexedFileCount, 1)
    }
}
