import XCTest
@testable import PisakaCore

/// `TreeDiagnostics` — the project tree's per-row diagnostic lookup — and
/// `TreeDiagnosticMark`'s two accessors, one test per rule.
final class TreeDiagnosticsTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/pisaka-tree-diagnostics/project")
    private let serverKey = DiagnosticStore.ServerKey(serverID: "test-server", root: "/pisaka-tree-diagnostics/project")

    private func url(_ path: String, under folder: URL? = nil) -> URL {
        let base = folder ?? root
        return path.isEmpty ? base : base.appendingPathComponent(path)
    }

    private func mapped(_ url: URL, _ severity: DiagnosticSeverity, at location: Int = 0, line: Int = 0) -> Diagnostic {
        Diagnostic(
            range: NSRange(location: location, length: 3),
            line: line,
            severity: severity,
            message: "m",
            source: "test",
            fileURL: url
        )
    }

    private func positional(_ url: URL, _ severity: DiagnosticSeverity, line: Int = 0) -> PositionalDiagnostic {
        PositionalDiagnostic(
            range: LSPRange(start: LSPPosition(line: line, character: 0), end: LSPPosition(line: line, character: 3)),
            severity: severity,
            message: "m",
            source: "test",
            fileURL: url
        )
    }

    private func lookup(_ store: DiagnosticStore, folder: URL? = nil) -> TreeDiagnostics {
        TreeDiagnostics(store: store, root: TreeDiagnostics.Root(folder ?? root))
    }

    // MARK: - The mark

    func testMarkOrderAndAccessors() {
        XCTAssertGreaterThan(TreeDiagnosticMark.error, .warning)
        XCTAssertGreaterThan(TreeDiagnosticMark.warning, .none)
        XCTAssertEqual(TreeDiagnosticMark.error.severity, .error)
        XCTAssertEqual(TreeDiagnosticMark.warning.severity, .warning)
        XCTAssertNil(TreeDiagnosticMark.none.severity)
        XCTAssertEqual(TreeDiagnosticMark.error.spokenName, "has errors")
        XCTAssertEqual(TreeDiagnosticMark.warning.spokenName, "has warnings")
        XCTAssertNil(TreeDiagnosticMark.none.spokenName)
    }

    // MARK: - Files

    func testAFileTakesTheWorstOfItsOwnDiagnosticsOfEitherKind() {
        var store = DiagnosticStore()
        let open = url("open.swift")
        let closed = url("closed.py")
        store.replace(url: open, serverKey: serverKey, diagnostics: [
            mapped(open, .hint), mapped(open, .warning), mapped(open, .information),
        ])
        store.replace(url: closed, serverKey: serverKey, positional: [
            positional(closed, .warning), positional(closed, .error, line: 4),
        ])
        let tree = lookup(store)
        XCTAssertEqual(tree.mark(for: open), .warning)
        XCTAssertEqual(tree.mark(for: closed), .error)
        XCTAssertEqual(tree.mark(for: url("clean.swift")), .none)
    }

    func testErrorOutranksWarning() {
        var store = DiagnosticStore()
        let file = url("dir/a.swift")
        let sibling = url("dir/b.swift")
        store.replace(url: file, serverKey: serverKey, diagnostics: [mapped(file, .warning), mapped(file, .error)])
        store.replace(url: sibling, serverKey: serverKey, positional: [positional(sibling, .warning)])
        let tree = lookup(store)
        XCTAssertEqual(tree.mark(for: file), .error)
        XCTAssertEqual(tree.mark(for: sibling), .warning)
        XCTAssertEqual(tree.mark(for: url("dir")), .error)
    }

    func testInformationAndHintsGiveNone() {
        var store = DiagnosticStore()
        let file = url("dir/info.swift")
        let closed = url("dir/hint.py")
        store.replace(url: file, serverKey: serverKey, diagnostics: [mapped(file, .information), mapped(file, .hint)])
        store.replace(url: closed, serverKey: serverKey, positional: [positional(closed, .hint)])
        let tree = lookup(store)
        XCTAssertEqual(tree.mark(for: file), .none)
        XCTAssertEqual(tree.mark(for: closed), .none)
        XCTAssertEqual(tree.mark(for: url("dir")), .none)
        XCTAssertEqual(tree.mark(for: root), .none)
        XCTAssertEqual(tree, lookup(DiagnosticStore()))
    }

    // MARK: - Folders

    func testAFolderTakesTheWorstOfAllItsDescendantsTransitively() {
        var store = DiagnosticStore()
        let deepWarning = url("a/b/c/d/warn.swift")
        let shallowError = url("a/x/err.py")
        store.replace(url: deepWarning, serverKey: serverKey, diagnostics: [mapped(deepWarning, .warning)])
        store.replace(url: shallowError, serverKey: serverKey, positional: [positional(shallowError, .error)])
        let tree = lookup(store)
        for folder in ["a/b/c/d", "a/b/c", "a/b"] {
            XCTAssertEqual(tree.mark(for: url(folder)), .warning, folder)
        }
        XCTAssertEqual(tree.mark(for: url("a/x")), .error)
        XCTAssertEqual(tree.mark(for: url("a")), .error)
        XCTAssertEqual(tree.mark(for: root), .error)
        XCTAssertEqual(tree.mark(for: url("other")), .none)
    }

    /// Insertion order does not decide the answer: a weaker file recorded after
    /// a stronger one under the same folder leaves the folder at the stronger.
    func testAggregationIsIndependentOfRecordOrder() {
        for order in [[0, 1], [1, 0]] {
            var store = DiagnosticStore()
            let files = [url("d/e.swift"), url("d/w.swift")]
            let severities: [DiagnosticSeverity] = [.error, .warning]
            for index in order {
                store.replace(url: files[index], serverKey: serverKey, diagnostics: [mapped(files[index], severities[index])])
            }
            XCTAssertEqual(lookup(store).mark(for: url("d")), .error, "\(order)")
        }
    }

    // MARK: - The root

    func testADiagnosedFileOutsideTheRootContributesNothing() {
        var store = DiagnosticStore()
        let outside = URL(fileURLWithPath: "/pisaka-tree-diagnostics/dependency/lib.swift")
        let lookalike = URL(fileURLWithPath: "/pisaka-tree-diagnostics/projectx/a.swift")
        store.replace(url: outside, serverKey: serverKey, diagnostics: [mapped(outside, .error)])
        store.replace(url: lookalike, serverKey: serverKey, positional: [positional(lookalike, .error)])
        let tree = lookup(store)
        XCTAssertEqual(tree.mark(for: root), .none)
        XCTAssertEqual(tree.mark(for: outside), .none)
        XCTAssertEqual(tree.mark(for: lookalike), .none)
        XCTAssertEqual(tree, lookup(DiagnosticStore()))
    }

    func testAProjectOpenedThroughASymlinkMarksItsRowsThroughTheCanonicalSpelling() throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("TreeDiagnosticsTests-\(UUID().uuidString)")
        let real = scratch.appendingPathComponent("real")
        try fileManager.createDirectory(at: real.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let link = scratch.appendingPathComponent("link")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: real)

        let canonical = CanonicalPath.canonical(link)
        XCTAssertNotEqual(canonical.path, link.standardizedFileURL.path)

        // The server reports the resolved spelling; the user opened the link,
        // so the tree's rows are spelled under it.
        var store = DiagnosticStore()
        let reported = canonical.appendingPathComponent("src/a.swift")
        store.replace(url: reported, serverKey: serverKey, positional: [positional(reported, .error)])
        let tree = lookup(store, folder: link)
        XCTAssertEqual(tree.mark(for: link.appendingPathComponent("src/a.swift")), .error)
        XCTAssertEqual(tree.mark(for: link.appendingPathComponent("src")), .error)
        XCTAssertEqual(tree.mark(for: link), .error)
        // A row spelled under the resolved folder answers alike.
        XCTAssertEqual(tree.mark(for: canonical.appendingPathComponent("src")), .error)
    }

    func testRowURLsAreMatchedLexicallyAfterStandardizing() {
        var store = DiagnosticStore()
        let file = url("src/a.swift")
        store.replace(url: file, serverKey: serverKey, diagnostics: [mapped(file, .warning)])
        let tree = lookup(store)
        XCTAssertEqual(tree.mark(for: URL(fileURLWithPath: root.path + "/src/./a.swift")), .warning)
        XCTAssertEqual(tree.mark(for: URL(fileURLWithPath: root.path + "/src/", isDirectory: true)), .warning)
    }

    // MARK: - Equality

    /// A keystroke's shift moves a flagged file's offsets without changing its
    /// worst severity; the lookup built after it equals the one built before.
    func testAShiftThatKeepsTheWorstSeverityBuildsAnEqualLookup() {
        // "aaa\nbbb\nccc", then one character typed at offset 0.
        let file = url("src/a.swift")
        let before = [mapped(file, .error, at: 4, line: 1), mapped(file, .warning, at: 8, line: 2)]
        let shifted = DiagnosticShift.updated(
            before,
            previousLineStarts: [0, 4, 8],
            newLineStarts: [0, 5, 9],
            editedRange: NSRange(location: 0, length: 1),
            changeInLength: 1
        )
        var store = DiagnosticStore()
        store.replace(url: file, serverKey: serverKey, diagnostics: before)
        let lookupBefore = lookup(store)
        store.apply(shift: shifted, to: file)
        XCTAssertEqual(store.entry(for: file)?.mapped?.map(\.range.location), [5, 9])
        XCTAssertNotEqual(store.entry(for: file)?.mapped, before)
        XCTAssertEqual(lookup(store), lookupBefore)
    }

    func testDifferentWorstSeveritiesBuildUnequalLookups() {
        let file = url("a.swift")
        var store = DiagnosticStore()
        store.replace(url: file, serverKey: serverKey, diagnostics: [mapped(file, .warning)])
        let warning = lookup(store)
        store.replace(url: file, serverKey: serverKey, diagnostics: [mapped(file, .error)])
        XCTAssertNotEqual(lookup(store), warning)
    }

    // MARK: - Empty

    func testAnEmptyStoreOrTheEmptyLookupAnswersNoneEverywhere() {
        let rows = [root, url("a.swift"), url("a/b/c"), URL(fileURLWithPath: "/elsewhere/x.swift")]
        for tree in [lookup(DiagnosticStore()), TreeDiagnostics.empty] {
            for row in rows {
                XCTAssertEqual(tree.mark(for: row), .none, row.path)
            }
        }
        var store = DiagnosticStore()
        let file = url("a.swift")
        store.replace(url: file, serverKey: serverKey, diagnostics: [])
        XCTAssertEqual(lookup(store).mark(for: file), .none)
        XCTAssertEqual(lookup(store).mark(for: root), .none)
    }

    /// A lookup that marks nothing is `.empty` whatever folder it was built
    /// for — information alone, an all-clear entry or nothing at all — so the
    /// publisher sees no change between "no folder" and "a folder with nothing
    /// to mark".
    func testALookupThatMarksNothingEqualsTheEmptyLookup() {
        let file = url("a.swift")
        var store = DiagnosticStore()
        XCTAssertEqual(lookup(store), .empty)
        XCTAssertEqual(lookup(store, folder: URL(fileURLWithPath: "/elsewhere")), .empty)
        store.replace(url: file, serverKey: serverKey, diagnostics: [mapped(file, .information)])
        XCTAssertEqual(lookup(store), .empty)
        store.replace(url: file, serverKey: serverKey, diagnostics: [mapped(file, .warning)])
        XCTAssertNotEqual(lookup(store), .empty)
    }

    // MARK: - The incremental index

    /// Recording one file at a time — raising, lowering and clearing marks,
    /// two files holding one folder up — reaches exactly the lookup a full
    /// build over the same final store reaches, after every step.
    func testIncrementalRecordsMatchAFullBuildAfterEveryStep() {
        let a = url("src/a.swift")
        let b = url("src/b.swift")
        let c = url("lib/deep/c.swift")
        let outside = URL(fileURLWithPath: "/elsewhere/x.swift")
        let steps: [(URL, DiagnosticSeverity?)] = [
            (a, .warning), (b, .error), (c, .warning), (outside, .error),
            (a, .error), (b, nil), (a, .warning), (c, .information),
            (a, nil), (b, .warning), (c, .error), (b, nil), (c, nil),
        ]
        var store = DiagnosticStore()
        var index = TreeDiagnosticsIndex(root: TreeDiagnostics.Root(root))
        for (file, severity) in steps {
            if let severity {
                store.replace(url: file, serverKey: serverKey, positional: [positional(file, severity)])
            } else {
                store.clearMapped(url: file)
                store.replace(url: file, serverKey: serverKey, diagnostics: [])
            }
            index.record(TreeDiagnostics.mark(of: store.entry(for: file)), for: file)
            XCTAssertEqual(index.lookup, lookup(store), "\(file.lastPathComponent) → \(String(describing: severity))")
        }
        XCTAssertEqual(index.lookup, .empty)
    }

    /// The table's trie splits and collapses as keys come and go, and its shape
    /// is a function of the key set alone: past the leaf capacity, two indexes
    /// reaching the same marks by different histories hold equal lookups, and
    /// one whose marks are all withdrawn holds `.empty`.
    func testTheTableIsShapedByItsKeysAloneWhateverTheHistory() {
        let files = (0..<600).map { url("gen/d\($0 % 23)/f\($0).swift") }
        var grown = TreeDiagnosticsIndex(root: TreeDiagnostics.Root(root))
        for file in files { grown.record(.error, for: file) }
        XCTAssertGreaterThan(grown.lookup.table.depth, 0, "the burst really split the root")
        for file in files[..<300] { grown.record(.none, for: file) }

        var direct = TreeDiagnosticsIndex(root: TreeDiagnostics.Root(root))
        for file in files[300...].reversed() { direct.record(.error, for: file) }
        XCTAssertEqual(grown.lookup, direct.lookup)

        for file in files[300...] { grown.record(.none, for: file) }
        XCTAssertEqual(grown.lookup.table.depth, 0, "the withdrawals collapsed it again")
        XCTAssertEqual(grown.lookup, .empty)
    }

    // MARK: - Cost

    /// The tree holds every published lookup, so the first move after a
    /// publication is a copy-on-write — of the trie nodes on the written keys'
    /// paths and nothing else: at most a branch's children per level plus one
    /// leaf per key, charged by the ledger apart from the steps. The depth
    /// grows with the logarithm of the marked keys, so a push late in a burst
    /// thirty-two times larger copies at most one more level per key — where a
    /// flat table copies every key, and a fixed split a share growing with them.
    func testAMoveAfterAPublicationCopiesOnlyTheWrittenPaths() {
        func latePush(after fileCount: Int) -> (copied: Int, depth: Int, keys: Int) {
            var index = TreeDiagnosticsIndex(root: TreeDiagnostics.Root(root))
            var published = index.lookup
            func push(_ number: Int) -> Int {
                let before = index.copiedEntries
                index.record(.error, for: url("gen/d\(number % 37)/f\(number).swift"))
                published = index.lookup
                index.notePublished()
                return index.copiedEntries - before
            }
            for number in 0..<fileCount { _ = push(number) }
            let copied = push(fileCount)
            XCTAssertEqual(published, index.lookup)
            return (copied, index.lookup.table.depth, fileCount + 1 + 37 + 2)
        }
        let small = latePush(after: 1_000)
        let large = latePush(after: 32_000)
        for burst in [small, large] {
            let perPath = burst.depth * MarkTrie.fanout + MarkTrie.leafCapacity
            XCTAssertGreaterThan(burst.copied, 0, "the write really copied the shared table")
            XCTAssertLessThanOrEqual(burst.copied, perPath, "only the file's own key changed its mark")
        }
        XCTAssertLessThanOrEqual(large.depth, small.depth + 2)
        XCTAssertLessThanOrEqual(large.copied, small.copied + 2 * MarkTrie.fanout + MarkTrie.leafCapacity)
        XCTAssertLessThan(large.copied, large.keys / 32)
    }

    /// A row's read is one descent of the trie: the count `resolve(_:)` reports
    /// is the nodes that descent visited, bounded by the table's own depth —
    /// a structural walk the descent never calls. A store of seven keys keeps
    /// the root a single leaf, so every read costs exactly one node; ten
    /// thousand files split it, so every read costs more than one — which is
    /// what makes the bound a statement about the descent rather than a
    /// constant. A row under neither spelling reads nothing.
    func testProbeCountIsTheDescentBoundedByTheTablesDepth() {
        func probes(_ files: [URL]) -> (counts: [Int], depth: Int) {
            var store = DiagnosticStore()
            for file in files {
                store.replace(url: file, serverKey: serverKey, positional: [positional(file, .warning)])
            }
            let hit = url("hit/x.swift")
            store.replace(url: hit, serverKey: serverKey, diagnostics: [mapped(hit, .error)])
            let tree = lookup(store)
            let counts = [
                tree.resolve(hit).probes,
                tree.resolve(url("a/b/c/d.swift")).probes,
                tree.resolve(url("gen")).probes,
                tree.resolve(root).probes,
                tree.resolve(URL(fileURLWithPath: "/elsewhere/x.swift")).probes,
            ]
            return (counts, tree.table.depth)
        }
        let small = probes((0..<3).map { url("gen/f\($0).swift") })
        let large = probes((0..<10_000).map { url("gen/d\($0 % 37)/f\($0).swift") })
        XCTAssertEqual(small.depth, 0, "seven keys stay within one leaf")
        XCTAssertGreaterThanOrEqual(large.depth, 1, "ten thousand files split the root")

        for store in [small, large] {
            for count in store.counts {
                XCTAssertLessThanOrEqual(count, store.depth + 1)
            }
            XCTAssertEqual(store.counts.last, 0, "a row outside the folder reads nothing")
        }
        XCTAssertEqual(Array(small.counts.dropLast()), [1, 1, 1, 1])
        for count in large.counts.dropLast() {
            XCTAssertGreaterThan(count, 1, "a read below a branch visits it too")
        }
    }
}
