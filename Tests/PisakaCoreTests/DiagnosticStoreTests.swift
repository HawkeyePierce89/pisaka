import XCTest
@testable import PisakaCore

/// The store: wholesale replacement, the three clearing rules keyed by url /
/// server / everything, the per-line worst-severity query the ruler indexes by,
/// the hover lookup's containment rules, the panel's grouped rows and counts.
final class DiagnosticStoreTests: XCTestCase {
    private let mainURL = URL(fileURLWithPath: "/tmp/pkg/Sources/App/main.swift")
    private let utilURL = URL(fileURLWithPath: "/tmp/pkg/Sources/App/util.swift")
    private let rootURL = URL(fileURLWithPath: "/tmp/pkg")
    /// "aaa\nbbb\nccc" — three lines at [0, 4, 8].
    private let lineStarts = [0, 4, 8]

    private var swiftKey: DiagnosticStore.ServerKey {
        DiagnosticStore.ServerKey(serverID: "sourcekit-lsp", root: "/tmp/pkg")
    }

    private var goKey: DiagnosticStore.ServerKey {
        DiagnosticStore.ServerKey(serverID: "gopls", root: "/tmp/pkg")
    }

    private func diagnostic(
        _ fileURL: URL = URL(fileURLWithPath: "/tmp/pkg/Sources/App/main.swift"),
        at location: Int,
        length: Int = 3,
        line: Int,
        severity: DiagnosticSeverity = .error,
        message: String = "m"
    ) -> Diagnostic {
        Diagnostic(
            range: NSRange(location: location, length: length),
            line: line,
            severity: severity,
            message: message,
            source: "test",
            fileURL: fileURL
        )
    }

    // MARK: - Wholesale replacement

    func testReplaceIsWholesaleLSPSemantics() {
        var store = DiagnosticStore()
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [
                diagnostic(at: 0, line: 0),
                diagnostic(at: 4, line: 1),
            ]
        )
        let secondPush = [diagnostic(at: 8, line: 2)]
        store.replace(url: mainURL, serverKey: swiftKey, diagnostics: secondPush)

        XCTAssertEqual(store.entry(for: mainURL)?.mapped, secondPush)
    }

    /// The "all clear" push is an empty *entry*, not a missing one: provenance
    /// survives so a teardown keyed by the same server still finds the document.
    func testAnEmptyPushLandsAsAnEmptyEntryWithProvenance() {
        var store = DiagnosticStore()
        store.replace(url: mainURL, serverKey: swiftKey, diagnostics: [])

        let entry = store.entry(for: mainURL)
        XCTAssertEqual(entry?.mapped, [])
        XCTAssertEqual(entry?.serverKey, swiftKey)
    }

    // MARK: - Clearing

    func testMappedClearRemovesOnlyThatDocument() {
        var store = DiagnosticStore()
        store.replace(url: mainURL, serverKey: swiftKey, diagnostics: [diagnostic(at: 0, line: 0)])
        store.replace(url: utilURL, serverKey: swiftKey, diagnostics: [diagnostic(at: 4, line: 1)])
        store.clearMapped(url: mainURL)

        XCTAssertNil(store.entry(for: mainURL))
        XCTAssertEqual(store.entry(for: utilURL)?.mapped?.count, 1)
    }

    func testClearByServerKeyLeavesAnotherServersDocumentsAlone() {
        var store = DiagnosticStore()
        store.replace(url: mainURL, serverKey: swiftKey, diagnostics: [diagnostic(at: 0, line: 0)])
        store.replace(url: utilURL, serverKey: goKey, diagnostics: [diagnostic(at: 4, line: 1)])

        store.clear(serverKey: swiftKey)

        XCTAssertNil(store.entry(for: mainURL))
        XCTAssertEqual(store.entry(for: utilURL)?.serverKey, goKey, "gopls's answers survive sourcekit's teardown")
    }

    func testClearAllEmptiesEverything() {
        var store = DiagnosticStore()
        store.replace(url: mainURL, serverKey: swiftKey, diagnostics: [diagnostic(at: 0, line: 0)])
        store.replace(url: utilURL, serverKey: goKey, diagnostics: [diagnostic(at: 4, line: 1)])
        store.clearAll()

        XCTAssertNil(store.entry(for: mainURL))
        XCTAssertNil(store.entry(for: utilURL))
        XCTAssertEqual(store.counts, DiagnosticStore.Counts(errors: 0, warnings: 0))
    }

    // MARK: - Shift application

    func testApplyReplacesTheSetButKeepsTheProvenance() {
        var store = DiagnosticStore()
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [diagnostic(at: 0, line: 0)]
        )
        let shiftedSet = [diagnostic(at: 5, line: 1)]
        store.apply(shift: shiftedSet, to: mainURL)

        let entry = store.entry(for: mainURL)
        XCTAssertEqual(entry?.mapped, shiftedSet)
        XCTAssertEqual(entry?.serverKey, swiftKey)
    }

    func testApplyToADocumentNoServerAnsweredForIsANoOp() {
        var store = DiagnosticStore()
        store.apply(shift: [diagnostic(at: 5, line: 1)], to: mainURL)
        XCTAssertNil(store.entry(for: mainURL), "shifting must not mint provenance nobody reported")
    }

    // MARK: - Hover containment

    func testHoverLookupFollowsHalfOpenContainment() {
        var store = DiagnosticStore()
        // Covers offsets 4–6.
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [diagnostic(at: 4, line: 1)]
        )

        XCTAssertEqual(store.diagnostics(at: 3, in: mainURL).count, 0, "just before the range")
        XCTAssertEqual(store.diagnostics(at: 4, in: mainURL).count, 1, "the first covered offset")
        XCTAssertEqual(store.diagnostics(at: 6, in: mainURL).count, 1, "the last covered offset")
        XCTAssertEqual(store.diagnostics(at: 7, in: mainURL).count, 0, "one past the end is outside — half-open")
    }

    func testAZeroLengthDiagnosticContainsExactlyItsOwnOffset() {
        var store = DiagnosticStore()
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [diagnostic(at: 5, length: 0, line: 1)]
        )

        XCTAssertEqual(store.diagnostics(at: 5, in: mainURL).count, 1, "otherwise it could never be hovered")
        XCTAssertEqual(store.diagnostics(at: 4, in: mainURL).count, 0)
        XCTAssertEqual(store.diagnostics(at: 6, in: mainURL).count, 0)
    }

    func testHoverLookupIsScopedToOneDocumentAndOrderedByKey() {
        var store = DiagnosticStore()
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [
                diagnostic(at: 4, line: 1, severity: .warning),
                diagnostic(at: 4, line: 1, severity: .error),
            ]
        )

        let hits = store.diagnostics(at: 4, in: mainURL)
        XCTAssertEqual(hits.map(\.severity), [.error, .warning], "orderingKey: most severe first at one offset")
        XCTAssertTrue(store.diagnostics(at: 4, in: utilURL).isEmpty)
    }

    // MARK: - Worst severity per line

    func testWorstSeverityPerLineTakesTheMostSeriousOnEachLine() {
        var store = DiagnosticStore()
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [
                diagnostic(at: 4, line: 1, severity: .warning),
                diagnostic(at: 5, line: 1, severity: .error),
                diagnostic(at: 8, line: 2, severity: .hint),
            ]
        )

        let perLine = store.worstSeverityPerLine(url: mainURL, lineCount: 3, lineStarts: lineStarts)
        XCTAssertEqual(perLine.count, 3, "exactly lineCount entries — the ruler indexes by line")
        XCTAssertEqual(perLine, [nil, .error, .hint])
    }

    func testAMultiLineDiagnosticMarksEveryLineItSpans() {
        var store = DiagnosticStore()
        // Spans from inside line 0 into line 1 (offsets 1–5).
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [diagnostic(at: 1, length: 5, line: 0, severity: .warning)]
        )

        XCTAssertEqual(
            store.worstSeverityPerLine(url: mainURL, lineCount: 3, lineStarts: lineStarts),
            [.warning, .warning, nil]
        )
    }

    /// A span ending exactly on a separator covers through the previous line
    /// only; and a diagnostic starting past the requested window is skipped
    /// rather than clamped onto line 0.
    func testSpanEdgesAndOutOfRangeLinesStayHonest() {
        var store = DiagnosticStore()
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [
                // Ends exactly where line 1 starts.
                diagnostic(at: 0, length: 4, line: 0, severity: .warning),
                // Starts on line 2 of the table — outside a two-line window.
                diagnostic(at: 8, line: 2, severity: .error),
            ]
        )

        XCTAssertEqual(
            store.worstSeverityPerLine(url: mainURL, lineCount: 2, lineStarts: lineStarts),
            [.warning, nil]
        )
    }

    /// The marked band is derived from the **caller's** table at both ends, so
    /// the stored ``Diagnostic/line`` — which counts by LSP's separator set and
    /// is only ever printed — cannot stretch a one-line diagnostic across the
    /// gap between the two numberings.
    ///
    /// The setup is the divergence itself: a buffer whose lines are separated by
    /// U+2028, which the editor's table splits on and the mapping's does not. A
    /// diagnostic on the editor's line 2 therefore carries a stored `line` of 0.
    func testTheMarkedBandIgnoresTheStoredLSPLineNumber() {
        var store = DiagnosticStore()
        // "aa\u{2028}bb\u{2028}cc" — the editor sees three lines at [0, 3, 6];
        // the LSP mapping sees one, so every diagnostic in it carries line 0.
        let editorLineStarts = [0, 3, 6]
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [diagnostic(at: 6, length: 2, line: 0, severity: .error)]
        )

        XCTAssertEqual(
            store.worstSeverityPerLine(url: mainURL, lineCount: 3, lineStarts: editorLineStarts),
            [nil, nil, .error],
            "marked where the editor draws it, not where LSP numbered it"
        )
    }

    func testWorstSeverityPerLineDegradesHonestlyOnOddGeometry() {
        var store = DiagnosticStore()
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [diagnostic(at: 0, line: 0)]
        )

        XCTAssertEqual(store.worstSeverityPerLine(url: mainURL, lineCount: 0, lineStarts: lineStarts), [])
        XCTAssertEqual(store.worstSeverityPerLine(url: mainURL, lineCount: -1, lineStarts: lineStarts), [])
        XCTAssertEqual(
            store.worstSeverityPerLine(url: mainURL, lineCount: 2, lineStarts: []),
            [nil, nil],
            "a broken table blanks the column at the right length"
        )
        XCTAssertEqual(
            store.worstSeverityPerLine(url: mainURL, lineCount: 2, lineStarts: [1, 5]),
            [nil, nil],
            "an unanchored table blanks the column at the right length"
        )
        XCTAssertEqual(store.worstSeverityPerLine(url: utilURL, lineCount: 3, lineStarts: lineStarts), [nil, nil, nil])
    }

    /// The ruler indexes the result by line, so a span that runs through the
    /// document's final line must mark every line from its start through that
    /// last one — at exactly `lineCount` entries.
    func testASpanReachingTheLastLineMarksEveryLineThroughIt() {
        var store = DiagnosticStore()
        // Spans from the start of line 1 across the separator into line 2 —
        // the last line of the three-line document.
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [diagnostic(at: 4, length: 6, line: 1, severity: .warning)]
        )

        let perLine = store.worstSeverityPerLine(url: mainURL, lineCount: 3, lineStarts: lineStarts)
        XCTAssertEqual(perLine.count, 3, "exactly lineCount entries")
        XCTAssertEqual(perLine, [nil, .warning, .warning])

        // A span covering the whole buffer marks all three lines.
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [diagnostic(at: 0, length: 11, line: 0, severity: .error)]
        )
        XCTAssertEqual(
            store.worstSeverityPerLine(url: mainURL, lineCount: 3, lineStarts: lineStarts),
            [.error, .error, .error]
        )
    }

    /// A one-line document and an empty one are both marked honestly: the
    /// single displayed line carries its worst severity, and a span running
    /// past the end of such a buffer is clamped into the window rather than
    /// trapping or vanishing. An empty document asked as zero lines answers
    /// zero entries.
    func testSingleLineAndEmptyDocumentsAreMarkedAtExactlyTheirLength() {
        var store = DiagnosticStore()

        // One line ("hello"): two severities on it, worst wins.
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [
                diagnostic(at: 0, length: 3, line: 0, severity: .warning),
                diagnostic(at: 4, length: 3, line: 0),
            ]
        )
        XCTAssertEqual(
            store.worstSeverityPerLine(url: mainURL, lineCount: 1, lineStarts: [0]),
            [.error]
        )

        // An empty document still displays one line; a zero-length diagnostic
        // at offset 0 marks it.
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [diagnostic(at: 0, length: 0, line: 0)]
        )
        XCTAssertEqual(store.worstSeverityPerLine(url: mainURL, lineCount: 1, lineStarts: [0]), [.error])

        // A span running far past that one-line buffer's end is clamped onto
        // the window rather than indexing out of it.
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [diagnostic(at: 0, length: 50, line: 0)]
        )
        XCTAssertEqual(store.worstSeverityPerLine(url: mainURL, lineCount: 1, lineStarts: [0]), [.error])

        // The same document asked for zero lines yields zero entries.
        XCTAssertEqual(store.worstSeverityPerLine(url: mainURL, lineCount: 0, lineStarts: []), [])
    }

    // MARK: - Panel rows

    func testRowsGroupAcrossTwoFilesInPathOrder() {
        var store = DiagnosticStore()
        store.replace(
            url: utilURL,
            serverKey: swiftKey,
            diagnostics: [diagnostic(utilURL, at: 4, line: 1)]
        )
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [
                diagnostic(mainURL, at: 4, line: 1, severity: .hint),
                diagnostic(mainURL, at: 0, line: 0),
            ]
        )

        let rows = store.rows(relativeTo: rootURL)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].url, mainURL.standardizedFileURL)
        XCTAssertEqual(rows[0].pathComponents, ["Sources", "App", "main.swift"])
        XCTAssertEqual(
            rows[0].rows.map(\.target),
            [.offsets(NSRange(location: 0, length: 3)), .offsets(NSRange(location: 4, length: 3))],
            "within a file, orderingKey order"
        )
        XCTAssertEqual(rows[1].url, utilURL.standardizedFileURL)
        XCTAssertEqual(rows[1].pathComponents, ["Sources", "App", "util.swift"])
    }

    /// A clear document contributes no group — the panel lists problems, not
    /// files a server happens to hold open.
    func testAClearedDocumentContributesNoRowGroup() {
        var store = DiagnosticStore()
        store.replace(url: mainURL, serverKey: swiftKey, diagnostics: [])
        XCTAssertTrue(store.rows(relativeTo: rootURL).isEmpty)
    }

    /// The rendered shape: every flattened field the panel draws comes through,
    /// and two diagnostics sharing one offset list most-severe-first.
    func testRowsCarryTheRenderedFieldsAndOrderMostSevereFirstAtOneOffset() {
        var store = DiagnosticStore()
        let error = Diagnostic(
            range: NSRange(location: 4, length: 3),
            line: 1,
            severity: .error,
            message: "cannot find value",
            source: "swiftc",
            fileURL: mainURL
        )
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [
                diagnostic(at: 4, line: 1, severity: .warning, message: "unused"),
                error,
            ]
        )

        let groups = store.rows(relativeTo: rootURL)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(
            groups[0].rows.map(\.message),
            ["cannot find value", "unused"],
            "orderingKey puts the error above the warning sharing its start"
        )
        let row = groups[0].rows[0]
        XCTAssertEqual(row.severity, .error)
        XCTAssertEqual(row.message, "cannot find value")
        XCTAssertEqual(row.target, .offsets(NSRange(location: 4, length: 3)))
        XCTAssertEqual(row.line, 1)
    }

    func testRowsCarryRelativePathsInsideTheRootAndAbsoluteOutside() {
        var store = DiagnosticStore()
        let nested = URL(fileURLWithPath: "/tmp/pkg/Sources/App/main.swift")
        let atRoot = URL(fileURLWithPath: "/tmp/pkg/main.swift")
        let outside = URL(fileURLWithPath: "/tmp/outside/other.swift")
        for url in [nested, atRoot, outside] {
            store.replace(
                url: url,
                serverKey: swiftKey,
                diagnostics: [diagnostic(url, at: 0, line: 0)]
            )
        }

        let rows = store.rows(relativeTo: rootURL)
        // Byte-wise component order: "Sources" < "main" < "tmp".
        XCTAssertEqual(rows.map(\.pathComponents), [
            ["Sources", "App", "main.swift"],
            ["main.swift"],
            ["tmp", "outside", "other.swift"],
        ])
    }

    /// Byte-identical rows collapse to one — the rendering rule the view's
    /// content-keyed `ForEach` rides on (`Row`'s note): two equal elements
    /// under `id: \.self` are undefined behavior, not a merge. The collapse is
    /// the *query's*, not the store's — the entry keeps both, so hover and the
    /// per-line folding still see them, and ``counts`` still counts each.
    func testByteIdenticalRowsCollapseToOne() {
        var store = DiagnosticStore()
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [
                diagnostic(at: 4, line: 1),
                diagnostic(at: 4, line: 1),
                // Same span and severity but a different message: a distinct
                // row, not a duplicate.
                diagnostic(at: 4, line: 1, message: "other"),
                diagnostic(at: 8, line: 2),
            ]
        )

        let groups = store.rows(relativeTo: rootURL)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].rows.count, 3, "the exact duplicate collapses; distinct rows survive")
        XCTAssertEqual(groups[0].rows.map(\.line), [1, 1, 2])
        XCTAssertEqual(groups[0].rows.map(\.message), ["m", "other", "m"])

        // The entry itself is untouched by the rendering rule.
        XCTAssertEqual(store.entry(for: mainURL)?.mapped?.count, 4)
        XCTAssertEqual(store.counts.errors, 4)
    }

    /// Two diagnostics that differ only in hidden metadata (here: `source`,
    /// which no surface shows) flatten to identical rows and so collapse too —
    /// they render identically and reveal identically.
    func testRowsDifferingOnlyInHiddenMetadataCollapse() {
        var store = DiagnosticStore()
        let clang = Diagnostic(
            range: NSRange(location: 4, length: 3),
            line: 1,
            severity: .warning,
            message: "unused variable",
            source: "clang",
            fileURL: mainURL
        )
        let swiftc = Diagnostic(
            range: NSRange(location: 4, length: 3),
            line: 1,
            severity: .warning,
            message: "unused variable",
            source: "swiftc",
            fileURL: mainURL
        )
        store.replace(url: mainURL, serverKey: swiftKey, diagnostics: [clang, swiftc])

        let groups = store.rows(relativeTo: rootURL)
        XCTAssertEqual(groups[0].rows.count, 1)
        XCTAssertEqual(store.entry(for: mainURL)?.mapped?.count, 2)
    }

    // MARK: - Counts

    func testCountsCoverErrorsAndWarningsOnly() {
        var store = DiagnosticStore()
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [
                diagnostic(at: 0, line: 0, severity: .error),
                diagnostic(at: 4, line: 1, severity: .warning),
                diagnostic(at: 8, line: 2, severity: .information),
                diagnostic(utilURL, at: 0, line: 0, severity: .error),
                diagnostic(utilURL, at: 4, line: 1, severity: .hint),
            ]
        )

        XCTAssertEqual(store.counts, DiagnosticStore.Counts(errors: 2, warnings: 1))
    }

    // MARK: - Row ordering and path components

    /// Files whose display components are *identical* still order
    /// deterministically, because the group sort falls through to the absolute
    /// URL. Without the tie-break the panel's list is left in the store
    /// dictionary's iteration order, which Swift re-seeds per process — so the
    /// same store would render in a different order from one launch to the next.
    ///
    /// Each pair is a file inside the root whose relative components happen to
    /// spell an absolute path outside it — `/tmp/pkg/tmp/outN/x.swift` flattens
    /// to `["tmp", "outN", "x.swift"]`, and so does `/tmp/outN/x.swift`, which is
    /// shown absolutely. Five collisions rather than one on purpose: with the
    /// tie-break gone the surviving order is a hash-seeded permutation, and one
    /// pair would coincide with the right answer half the time.
    func testGroupsWithIdenticalPathComponentsOrderByAbsoluteURL() {
        var store = DiagnosticStore()
        var expectedComponents: [[String]] = []
        var expectedURLs: [URL] = []
        for index in 0..<5 {
            let inside = URL(fileURLWithPath: "/tmp/pkg/tmp/out\(index)/x.swift")
            let outside = URL(fileURLWithPath: "/tmp/out\(index)/x.swift")
            for url in [inside, outside] {
                store.replace(url: url, serverKey: swiftKey, diagnostics: [diagnostic(url, at: 0, line: 0)])
            }
            expectedComponents.append(["tmp", "out\(index)", "x.swift"])
            expectedComponents.append(["tmp", "out\(index)", "x.swift"])
            // Components decide the pair's position; inside the pair the
            // absolute URL decides, and `/tmp/out…` precedes `/tmp/pkg/…`.
            expectedURLs.append(outside)
            expectedURLs.append(inside)
        }

        let groups = store.rows(relativeTo: rootURL)
        XCTAssertEqual(groups.map(\.pathComponents), expectedComponents)
        XCTAssertEqual(groups.map(\.url), expectedURLs)
    }

    /// A file reached through a *symlinked* spelling of the root still shows
    /// relative components: the lexical probe misses, and the canonical probe
    /// behind it is what stops the row from falling back to an absolute path
    /// that would disagree with the breadcrumb for the same file.
    func testRelativeComponentsSurviveASymlinkedSpellingOfTheRoot() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diagnostic-store-symlink-\(UUID().uuidString)", isDirectory: true)
        let real = base.appendingPathComponent("real", isDirectory: true)
        let sources = real.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        // The file is named through the *real* path, the root through the link.
        let file = sources.appendingPathComponent("main.swift")
        var store = DiagnosticStore()
        store.replace(url: file, serverKey: swiftKey, diagnostics: [diagnostic(file, at: 0, line: 0)])

        XCTAssertEqual(store.rows(relativeTo: link).map(\.pathComponents), [["Sources", "main.swift"]])
    }

    // MARK: - Degenerate geometry

    /// A negative *location* is skipped, not indexed with — the marked band is
    /// derived from offsets, so the offset is what the lower-bound guard screens
    /// (the stored `line` is never read as geometry here). Unreachable through
    /// the mapping — which never mints one — but `Diagnostic` is a public value
    /// type with a public memberwise init, and the query promises "never a crash
    /// indexing past the array" to callers it never met. A nonsense `line` beside
    /// a sound offset is simply ignored, which is the same promise from the other
    /// side.
    func testANegativeLocationIsSkippedRatherThanIndexedWith() {
        var store = DiagnosticStore()
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [
                diagnostic(at: -1, line: 0, severity: .error),
                diagnostic(at: 4, line: -1, severity: .warning),
            ]
        )

        XCTAssertEqual(
            store.worstSeverityPerLine(url: mainURL, lineCount: 3, lineStarts: lineStarts),
            [nil, .warning, nil]
        )
    }

    /// A span whose end overflows `Int` is skipped like any other garbage
    /// geometry — the guard's counterpart to `DiagnosticShift`'s two.
    func testAnOverflowingSpanIsSkippedRatherThanTrapping() {
        var store = DiagnosticStore()
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [
                Diagnostic(
                    range: NSRange(location: Int.max - 1, length: 5),
                    line: 0,
                    severity: .error,
                    message: "overflow",
                    source: "test",
                    fileURL: mainURL
                ),
                diagnostic(at: 8, line: 2, severity: .warning),
            ]
        )

        XCTAssertEqual(
            store.worstSeverityPerLine(url: mainURL, lineCount: 3, lineStarts: lineStarts),
            [nil, nil, .warning]
        )
    }

    // MARK: - Positional entries

    private func positional(
        _ fileURL: URL = URL(fileURLWithPath: "/tmp/pkg/Sources/App/main.swift"),
        line: Int,
        character: Int = 0,
        severity: DiagnosticSeverity = .error,
        message: String = "p"
    ) -> PositionalDiagnostic {
        PositionalDiagnostic(
            range: LSPRange(
                start: LSPPosition(line: line, character: character),
                end: LSPPosition(line: line, character: character + 3)
            ),
            severity: severity,
            message: message,
            source: "test",
            fileURL: fileURL
        )
    }

    func testAPositionalEntryInstallsWithItsProvenanceAndNoMappedSet() {
        var store = DiagnosticStore()
        let set = [positional(line: 1), positional(line: 2, severity: .warning)]
        store.replace(url: mainURL, serverKey: goKey, positional: set)

        let entry = store.entry(for: mainURL)
        XCTAssertEqual(entry?.positional, set)
        XCTAssertNil(entry?.mapped, "a positional entry has no mapped set, by type")
        XCTAssertEqual(entry?.serverKey, goKey)
    }

    func testAnEmptyPositionalReportInstallsAnEmptyEntry() {
        var store = DiagnosticStore()
        store.replace(url: mainURL, serverKey: goKey, positional: [])

        let entry = store.entry(for: mainURL)
        XCTAssertEqual(entry?.positional, [])
        XCTAssertEqual(entry?.serverKey, goKey)
    }

    func testEitherKindReplacesTheOtherWholesale() {
        var store = DiagnosticStore()
        store.replace(url: mainURL, serverKey: goKey, positional: [positional(line: 0)])
        let mapped = [diagnostic(at: 0, line: 0)]
        store.replace(url: mainURL, serverKey: goKey, diagnostics: mapped)
        XCTAssertEqual(store.entry(for: mainURL)?.mapped, mapped)

        store.replace(url: mainURL, serverKey: goKey, positional: [positional(line: 2)])
        XCTAssertNil(store.entry(for: mainURL)?.mapped)
        XCTAssertEqual(store.entry(for: mainURL)?.positional?.count, 1)
    }

    /// The editor queries read mapped sets only: a positional entry draws no
    /// squiggle, answers no hover and marks no gutter line.
    func testEditorQueriesSeeNothingOfAPositionalEntry() {
        var store = DiagnosticStore()
        store.replace(
            url: mainURL,
            serverKey: goKey,
            positional: [positional(line: 0), positional(line: 1, character: 1, severity: .warning)]
        )

        XCTAssertTrue(store.diagnostics(at: 0, in: mainURL).isEmpty)
        XCTAssertTrue(store.diagnostics(at: 5, in: mainURL).isEmpty)
        XCTAssertEqual(
            store.worstSeverityPerLine(url: mainURL, lineCount: 3, lineStarts: lineStarts),
            [nil, nil, nil]
        )
    }

    func testAShiftDoesNotTouchAPositionalEntry() {
        var store = DiagnosticStore()
        let set = [positional(line: 1)]
        store.replace(url: mainURL, serverKey: goKey, positional: set)

        store.apply(shift: [diagnostic(at: 5, line: 1)], to: mainURL)

        XCTAssertEqual(store.entry(for: mainURL)?.positional, set)
        XCTAssertNil(store.entry(for: mainURL)?.mapped, "a shift must not turn a positional entry into a mapped one")
    }

    func testTheMappedClearLeavesAPositionalEntryAndRemovesAMappedOne() {
        var store = DiagnosticStore()
        store.replace(url: mainURL, serverKey: goKey, positional: [positional(line: 1)])
        store.replace(url: utilURL, serverKey: goKey, diagnostics: [diagnostic(utilURL, at: 0, line: 0)])

        store.clearMapped(url: mainURL)
        store.clearMapped(url: utilURL)

        XCTAssertEqual(store.entry(for: mainURL)?.positional?.count, 1)
        XCTAssertNil(store.entry(for: utilURL))
    }

    /// A removed file or folder takes every entry at or under its path, both
    /// kinds, by whole component — a sibling whose name merely starts with the
    /// removed one's keeps its entry.
    func testTheRemovalClearTakesEveryEntryAtOrUnderThePath() {
        var store = DiagnosticStore()
        let sibling = URL(fileURLWithPath: "/tmp/pkg/Sources/AppExtra/x.swift")
        let other = URL(fileURLWithPath: "/tmp/pkg/README.md")
        store.replace(url: mainURL, serverKey: swiftKey, diagnostics: [diagnostic(at: 0, line: 0)])
        store.replace(url: utilURL, serverKey: goKey, positional: [positional(utilURL, line: 0)])
        store.replace(url: sibling, serverKey: goKey, positional: [positional(sibling, line: 0)])
        store.replace(url: other, serverKey: goKey, positional: [positional(other, line: 0)])

        store.clear(under: URL(fileURLWithPath: "/tmp/pkg/Sources/App/main.swift"))
        XCTAssertNil(store.entry(for: mainURL), "the file itself")
        XCTAssertNotNil(store.entry(for: utilURL))

        store.clear(under: URL(fileURLWithPath: "/tmp/pkg/Sources/App/", isDirectory: true))
        XCTAssertNil(store.entry(for: utilURL), "a closed file under a removed folder")
        XCTAssertNotNil(store.entry(for: sibling), "a name sharing the folder's prefix is not under it")
        XCTAssertNotNil(store.entry(for: other))
    }

    func testTheServerClearRemovesPositionalEntries() {
        var store = DiagnosticStore()
        store.replace(url: mainURL, serverKey: goKey, positional: [positional(line: 1)])
        store.replace(url: utilURL, serverKey: swiftKey, positional: [positional(utilURL, line: 0)])

        store.clear(serverKey: goKey)

        XCTAssertNil(store.entry(for: mainURL))
        XCTAssertEqual(store.entry(for: utilURL)?.serverKey, swiftKey, "another server's positional entry survives")
    }

    func testClearAllRemovesPositionalEntries() {
        var store = DiagnosticStore()
        store.replace(url: mainURL, serverKey: goKey, positional: [positional(line: 1)])
        store.replace(url: utilURL, serverKey: swiftKey, diagnostics: [diagnostic(utilURL, at: 0, line: 0)])

        store.clearAll()

        XCTAssertNil(store.entry(for: mainURL))
        XCTAssertNil(store.entry(for: utilURL))
    }

    func testCountsSpanBothKindsAndExcludeInformationAndHints() {
        var store = DiagnosticStore()
        store.replace(
            url: mainURL,
            serverKey: goKey,
            positional: [
                positional(line: 0, severity: .error),
                positional(line: 1, severity: .error),
                positional(line: 2, severity: .warning),
                positional(line: 3, severity: .information),
                positional(line: 4, severity: .hint),
            ]
        )
        store.replace(
            url: utilURL,
            serverKey: goKey,
            diagnostics: [
                diagnostic(utilURL, at: 0, line: 0, severity: .error),
                diagnostic(utilURL, at: 4, line: 1, severity: .warning),
                diagnostic(utilURL, at: 8, line: 2, severity: .hint),
            ]
        )

        XCTAssertEqual(store.counts, DiagnosticStore.Counts(errors: 3, warnings: 2))
    }

    // MARK: - Rows for both kinds

    /// A closed file's rows carry the server's own start line and its range as
    /// the reveal target, and the header counts include them.
    func testAClosedFilesRowsCarryTheServersLineAndCountInTheHeader() {
        var store = DiagnosticStore()
        store.replace(
            url: utilURL,
            serverKey: goKey,
            positional: [positional(utilURL, line: 7, character: 2, severity: .warning, message: "unused")]
        )
        store.replace(url: mainURL, serverKey: swiftKey, diagnostics: [diagnostic(at: 0, line: 0)])

        let groups = store.rows(relativeTo: rootURL)
        XCTAssertEqual(groups.map(\.pathComponents), [
            ["Sources", "App", "main.swift"],
            ["Sources", "App", "util.swift"],
        ], "a closed file lists beside an open one, in path order")
        let row = groups[1].rows[0]
        XCTAssertEqual(row.line, 7, "the server's zero-based start line")
        XCTAssertEqual(row.severity, .warning)
        XCTAssertEqual(row.message, "unused")
        XCTAssertEqual(
            row.target,
            .position(LSPRange(start: LSPPosition(line: 7, character: 2), end: LSPPosition(line: 7, character: 5)))
        )
        XCTAssertEqual(store.counts, DiagnosticStore.Counts(errors: 1, warnings: 1))
    }

    /// An empty positional report contributes no group, like an empty mapped one.
    func testAnEmptyPositionalEntryContributesNoRowGroup() {
        var store = DiagnosticStore()
        store.replace(url: utilURL, serverKey: goKey, positional: [])
        XCTAssertTrue(store.rows(relativeTo: rootURL).isEmpty)
    }

    /// Byte-identical positional rows collapse exactly as mapped ones do.
    func testByteIdenticalPositionalRowsCollapseToOne() {
        var store = DiagnosticStore()
        store.replace(
            url: mainURL,
            serverKey: goKey,
            positional: [positional(line: 1), positional(line: 1), positional(line: 1, message: "other")]
        )
        XCTAssertEqual(store.rows(relativeTo: rootURL)[0].rows.map(\.message), ["other", "p"])
    }

    /// The same diagnostics, held as a positional set (file closed) and as a
    /// mapped set (file open), list in the same order — including same-line
    /// ties broken by column, then severity, then span — whatever order the
    /// push arrived in.
    func testBothKindsOfTheSameDiagnosticsYieldTheSameRowOrder() {
        let text = "let alpha = 1\nlet beta = alpha + gamma\nprint(beta)\n" as NSString
        func lsp(
            _ line: Int, _ start: Int, _ endLine: Int, _ end: Int,
            _ severity: LSPDiagnosticSeverity, _ message: String
        ) -> LSPDiagnostic {
            LSPDiagnostic(
                range: LSPRange(
                    start: LSPPosition(line: line, character: start),
                    end: LSPPosition(line: endLine, character: end)
                ),
                severity: severity,
                message: message
            )
        }
        let pushed = [
            lsp(2, 0, 2, 5, .information, "print"),
            lsp(1, 19, 1, 24, .error, "gamma"),
            lsp(1, 4, 1, 8, .warning, "beta-short"),
            lsp(1, 4, 2, 3, .warning, "beta-multiline"),
            lsp(1, 4, 1, 24, .error, "beta-error"),
            lsp(1, 11, 1, 16, .hint, "alpha-use"),
            lsp(0, 4, 0, 9, .warning, "alpha"),
        ]
        let lineStarts = LSPPositionMap.lineStarts(in: text)
        var positionalStore = DiagnosticStore()
        positionalStore.replace(
            url: mainURL,
            serverKey: swiftKey,
            positional: pushed.map { PositionalDiagnostic.make(from: $0, url: mainURL) }
        )
        var mappedStore = DiagnosticStore()
        mappedStore.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: pushed.compactMap {
                Diagnostic.make(from: $0, in: text, lineStarts: lineStarts, url: mainURL)
            }
        )

        let expected = ["alpha", "beta-error", "beta-short", "beta-multiline", "alpha-use", "gamma", "print"]
        let positionalRows = positionalStore.rows(relativeTo: rootURL)[0].rows
        let mappedRows = mappedStore.rows(relativeTo: rootURL)[0].rows
        XCTAssertEqual(positionalRows.map(\.message), expected)
        XCTAssertEqual(mappedRows.map(\.message), expected)
        XCTAssertEqual(positionalRows.map(\.line), mappedRows.map(\.line))
        XCTAssertEqual(positionalRows.map(\.severity), mappedRows.map(\.severity))
    }

    // MARK: - Reveal range

    private func revealRow(
        positional range: LSPRange
    ) -> DiagnosticStore.Row {
        var store = DiagnosticStore()
        store.replace(
            url: mainURL,
            serverKey: goKey,
            positional: [
                PositionalDiagnostic(range: range, severity: .error, message: "m", source: nil, fileURL: mainURL),
            ]
        )
        return store.rows(relativeTo: rootURL)[0].rows[0]
    }

    /// A positional row maps onto the buffer the file opened with.
    func testTheRevealRangeMapsAPositionalRowOntoTheBuffer() {
        let text = "aaa\nbbbbb\r\nccc" as NSString
        let row = revealRow(positional: LSPRange(
            start: LSPPosition(line: 1, character: 1),
            end: LSPPosition(line: 2, character: 2)
        ))
        XCTAssertEqual(row.rangeToReveal(in: text), NSRange(location: 5, length: 8))
    }

    /// A line past the end lands at the end of the buffer; a character past
    /// its line lands at that line's end, before the separator.
    func testTheRevealRangeClampsAPositionPastTheEnd() {
        let text = "aaa\nbbbbb\r\nccc" as NSString
        let pastTheEnd = revealRow(positional: LSPRange(
            start: LSPPosition(line: 40, character: 0),
            end: LSPPosition(line: 41, character: 3)
        ))
        XCTAssertEqual(pastTheEnd.rangeToReveal(in: text), NSRange(location: text.length, length: 0))

        let pastTheLine = revealRow(positional: LSPRange(
            start: LSPPosition(line: 1, character: 99),
            end: LSPPosition(line: 1, character: 120)
        ))
        XCTAssertEqual(pastTheLine.rangeToReveal(in: text), NSRange(location: 9, length: 0), "the end of \"bbbbb\", before CRLF")
    }

    /// A mapped row's in-range range comes back unchanged; one the buffer no
    /// longer reaches is clamped into it rather than trapping.
    func testTheRevealRangeReturnsAnInRangeMappedRangeUnchangedAndClampsTheRest() {
        let text = "aaa\nbbb\nccc" as NSString
        var store = DiagnosticStore()
        store.replace(url: mainURL, serverKey: swiftKey, diagnostics: [diagnostic(at: 4, length: 3, line: 1)])
        let inRange = store.rows(relativeTo: rootURL)[0].rows[0]
        XCTAssertEqual(inRange.rangeToReveal(in: text), NSRange(location: 4, length: 3))

        store.replace(url: mainURL, serverKey: swiftKey, diagnostics: [diagnostic(at: 9, length: 10, line: 2)])
        let overhanging = store.rows(relativeTo: rootURL)[0].rows[0]
        XCTAssertEqual(overhanging.rangeToReveal(in: text), NSRange(location: 9, length: 2))

        store.replace(url: mainURL, serverKey: swiftKey, diagnostics: [diagnostic(at: 50, length: 3, line: 9)])
        let beyond = store.rows(relativeTo: rootURL)[0].rows[0]
        XCTAssertEqual(beyond.rangeToReveal(in: text), NSRange(location: text.length, length: 0))
    }
}
