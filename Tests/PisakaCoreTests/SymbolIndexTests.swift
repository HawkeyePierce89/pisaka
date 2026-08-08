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
        XCTAssertTrue(index.symbols(withPrefix: "old", limit: 10).isEmpty)
        XCTAssertEqual(index.symbols(named: "newName").count, 1)
        XCTAssertEqual(index.symbols(withPrefix: "new", limit: 10).count, 1)
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
        XCTAssertEqual(index.symbols(withPrefix: "s", limit: 10).count, 1)
        XCTAssertEqual(index.symbols(inFile: url(file)).count, 2)
    }

    func testReplaceWithNoSymbolsStillCountsTheFileAsIndexed() {
        var index = SymbolIndex()
        index.replace(fileURL: url("/tmp/pisaka-symbols/empty.swift"), symbols: [])
        XCTAssertEqual(index.indexedFileCount, 1)
        XCTAssertFalse(index.isEmpty)
    }

    func testRemoveErasesTheFileFromBothBuckets() {
        var index = SymbolIndex()
        let gone = "/tmp/pisaka-symbols/gone.swift"
        let kept = "/tmp/pisaka-symbols/kept.swift"
        index.replace(fileURL: url(gone), symbols: [symbol("shared", in: gone)])
        index.replace(fileURL: url(kept), symbols: [symbol("shared", in: kept)])

        index.remove(fileURL: url(gone))

        XCTAssertEqual(index.symbols(named: "shared").map(\.fileURL), [url(kept)])
        XCTAssertEqual(index.symbols(withPrefix: "sh", limit: 10).map(\.fileURL), [url(kept)])
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
        XCTAssertTrue(index.symbols(withPrefix: "r", limit: 10).isEmpty)
        XCTAssertTrue(index.symbols(inFile: url("/tmp/pisaka-symbols/a.swift")).isEmpty)
    }

    // MARK: - Lookups

    /// Exact lookup is case-sensitive (`Foo` and `foo` are distinct
    /// declarations); prefix lookup is not (typing `arr` must still offer
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

        XCTAssertEqual(index.symbols(withPrefix: "wid", limit: 10).count, 2)
        XCTAssertEqual(index.symbols(withPrefix: "WID", limit: 10).count, 2)
        XCTAssertEqual(index.symbols(withPrefix: "Widg", limit: 10).count, 2)
    }

    func testPrefixLookupRejectsAnEmptyPrefixAndANonPositiveLimit() {
        var index = SymbolIndex()
        index.replace(fileURL: url("/tmp/pisaka-symbols/a.swift"), symbols: [symbol("run")])
        XCTAssertTrue(index.symbols(withPrefix: "", limit: 10).isEmpty)
        XCTAssertTrue(index.symbols(withPrefix: "r", limit: 0).isEmpty)
        XCTAssertTrue(index.symbols(named: "").isEmpty)
    }

    func testPrefixLookupMatchesOnlyPrefixesNotSubstrings() {
        var index = SymbolIndex()
        let file = "/tmp/pisaka-symbols/a.swift"
        index.replace(
            fileURL: url(file),
            symbols: [symbol("runLoop", in: file), symbol("rerun", at: 20, in: file)]
        )
        XCTAssertEqual(index.symbols(withPrefix: "run", limit: 10).map(\.name), ["runLoop"])
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
        XCTAssertEqual(index.symbols(withPrefix: "run", limit: 2).map(\.name), ["run0", "run1"])
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
        XCTAssertEqual(index.symbols(withPrefix: "ün", limit: 10).count, 1)
        XCTAssertEqual(index.symbols(withPrefix: "Ü", limit: 10).count, 1)
        XCTAssertEqual(index.symbols(named: "Ünicode").count, 1)
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
