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

        XCTAssertEqual(store.entry(for: mainURL)?.diagnostics, secondPush)
    }

    /// The "all clear" push is an empty *entry*, not a missing one: provenance
    /// survives so a teardown keyed by the same server still finds the document.
    func testAnEmptyPushLandsAsAnEmptyEntryWithProvenance() {
        var store = DiagnosticStore()
        store.replace(url: mainURL, serverKey: swiftKey, diagnostics: [])

        let entry = store.entry(for: mainURL)
        XCTAssertEqual(entry?.diagnostics, [])
        XCTAssertEqual(entry?.serverKey, swiftKey)
    }

    // MARK: - Clearing

    func testClearByURLRemovesOnlyThatDocument() {
        var store = DiagnosticStore()
        store.replace(url: mainURL, serverKey: swiftKey, diagnostics: [diagnostic(at: 0, line: 0)])
        store.replace(url: utilURL, serverKey: swiftKey, diagnostics: [diagnostic(at: 4, line: 1)])
        store.clear(url: mainURL)

        XCTAssertNil(store.entry(for: mainURL))
        XCTAssertEqual(store.entry(for: utilURL)?.diagnostics.count, 1)
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
        XCTAssertEqual(entry?.diagnostics, shiftedSet)
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
    /// only; and a diagnostic whose stored start line sits past the requested
    /// window is skipped rather than clamped onto line 0.
    func testSpanEdgesAndOutOfRangeLinesStayHonest() {
        var store = DiagnosticStore()
        store.replace(
            url: mainURL,
            serverKey: swiftKey,
            diagnostics: [
                // Ends exactly where line 1 starts.
                diagnostic(at: 0, length: 4, line: 0, severity: .warning),
                // Stored line 9 of a 3-line request.
                diagnostic(at: 8, line: 9, severity: .error),
            ]
        )

        XCTAssertEqual(
            store.worstSeverityPerLine(url: mainURL, lineCount: 3, lineStarts: lineStarts),
            [.warning, nil, nil]
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
        XCTAssertEqual(rows[0].rows.map(\.range.location), [0, 4], "within a file, orderingKey order")
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
        XCTAssertEqual(row.range, NSRange(location: 4, length: 3))
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
}
