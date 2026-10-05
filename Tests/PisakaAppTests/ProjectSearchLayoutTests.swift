#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The Find in Files window, hosted in a real window and measured off a
/// rendered bitmap.
///
/// **The design.** The three query toggles close the query row, each a
/// 16-point glyph in its own slot; Replace All sits at the trailing end of the
/// replace row, under them; a file's match lines sit beneath its header,
/// indented 34.
///
/// **How it is measured.** The window is rendered once per scale over a small
/// project on disk — two files, one match each, searched through the real
/// model — with the replace row open, and every sample is read out of that one
/// bitmap. Ink is any pixel off the `bgPanel` ground. The toggles are checked
/// slot by slot: every inked column at the query row's trailing end lies inside
/// one of the three glyph slots, and each slot holds ink. The match indent is
/// the leftmost `textSecondary` pixel of the rows whose ink does not start at
/// the header's glyph — the line number, drawn leading in its column. The
/// query toggle's on state is rendered once on its own: the glyph in `accent`
/// inside its slot, on the `accentTint` ground.
@MainActor
final class ProjectSearchLayoutTests: XCTestCase {

    private var project: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        project = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectSearchLayoutTests-\(UUID().uuidString)")
        let sources = project.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        // Line 2 in both, so the line number's first digit is a `2`: a digit
        // whose ink starts at its cell's leading edge, unlike a centred `1`.
        try "let a = 1\nlet needle = 2\n".write(
            to: sources.appendingPathComponent("Main.swift"), atomically: true, encoding: .utf8
        )
        try "# Notes\nneedle here\n".write(
            to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8
        )
    }

    override func tearDownWithError() throws {
        if let project { try? FileManager.default.removeItem(at: project) }
        project = nil
        try super.tearDownWithError()
    }

    func testTheWindowAtScaleOne() async throws {
        try await assertWindow(scale: 1)
    }

    func testTheWindowAtScaleOnePointEight() async throws {
        try await assertWindow(scale: 1.8)
    }

    func testAnOnToggleDrawsItsGlyphInAccentOnTheTint() throws {
        for scale in [1.0, 1.8] {
            let metrics = InterfaceMetrics(scale: scale)
            let theme = ChromeTheme(.dark)
            let panel = theme.color(.bgPanel)
            let side = metrics.scaled(ChromeQueryToggleLayout.side)
            let render = try HostedRender(
                size: CGSize(width: side, height: side),
                root: ChromeQueryToggle(glyph: .caseSensitive, isOn: .constant(true), help: "Match case")
                    .background(panel)
                    .environment(\.interfaceMetrics, metrics)
                    .environment(\.chromeTheme, theme)
            )
            addTeardownBlock { @MainActor in render.window.close() }

            // The ground: the tint along the inset band, clear of the rounded corners.
            let inset = metrics.scaled(ChromeQueryToggleLayout.inset)
            XCTAssertTrue(
                render.matches(.accentTint, atX: side / 2, y: inset / 2, ground: panel),
                "an on toggle has no accentTint ground at scale \(scale)"
            )
            // The glyph: accent pixels, every one inside the 16-point slot.
            let step = 1 / render.pixelScale
            var accent: [(CGFloat, CGFloat)] = []
            for x in stride(from: 0, to: side, by: step) {
                for y in stride(from: 0, to: side, by: step)
                where render.matches(.accent, atX: x, y: y, ground: theme.color(.accentTint)) {
                    accent.append((x, y))
                }
            }
            XCTAssertFalse(accent.isEmpty, "an on toggle draws no accent glyph at scale \(scale)")
            let slot = (inset - step)...(side - inset + step)
            XCTAssertTrue(
                accent.allSatisfy { slot.contains($0.0) && slot.contains($0.1) },
                "an on toggle's glyph leaves its 16-point slot at scale \(scale)"
            )
        }
    }

    private func assertWindow(scale: Double, file: StaticString = #filePath, line: UInt = #line) async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ProjectSearchLayoutTests-\(scale)"))
        defaults.removePersistentDomain(forName: "ProjectSearchLayoutTests-\(scale)")
        let settings = SettingsStore(defaults: defaults)
        settings.themePreference = .dark
        settings.interfaceScale = scale
        let metrics = settings.interfaceMetrics
        XCTAssertEqual(metrics.scale, scale, accuracy: 0.001, file: file, line: line)

        let model = ProjectSearchModel()
        let root = try XCTUnwrap(project)
        await model.search(root: root, query: SearchQuery(pattern: "needle"), mask: "")
        XCTAssertEqual(model.results.map(\.matchCount), [1, 1], file: file, line: line)

        let width = metrics.scaled(720)
        let render = try HostedRender(
            size: CGSize(width: width, height: metrics.scaled(420)),
            root: ProjectSearchView(
                model: model, settings: settings, root: { root },
                onActivate: { _, _ in }, onReplaceAll: { _, _ in nil },
                replaceExpanded: true
            )
        )
        addTeardownBlock { @MainActor in render.window.close() }
        let ground = try XCTUnwrap(HostedRender.swatch(.bgPanel, ground: nil))
        let step = 1 / render.pixelScale
        func inked(_ x: CGFloat, _ y: CGFloat) -> Bool {
            guard let c = render.color(atX: x, y: y) else { return false }
            return abs(c.redComponent - ground.redComponent) > 0.06
                || abs(c.greenComponent - ground.greenComponent) > 0.06
                || abs(c.blueComponent - ground.blueComponent) > 0.06
        }
        func inkedColumn(_ x: CGFloat, rows: Range<CGFloat>) -> Bool {
            stride(from: rows.lowerBound, to: rows.upperBound, by: step).contains { inked(x, $0) }
        }

        let padding = metrics.scaled(16)
        let fieldHeight = metrics.scaled(33)
        let gap = metrics.scaled(12)
        let trailing = width - padding

        // The query row's trailing end: three toggles, 10 apart, glyph slot by slot.
        let queryRow = padding..<(padding + fieldHeight)
        let side = metrics.scaled(ChromeQueryToggleLayout.side)
        let toggleGap = metrics.scaled(10)
        let inset = metrics.scaled(ChromeQueryToggleLayout.inset)
        let slots: [ClosedRange<CGFloat>] = (0..<3).map { index in
            let right = trailing - CGFloat(index) * (side + toggleGap)
            return (right - side + inset - step)...(right - inset + step)
        }
        let region = (trailing - 3 * side - 2 * toggleGap)..<trailing
        var columns: [CGFloat] = []
        for x in stride(from: region.lowerBound, to: region.upperBound, by: step)
        where inkedColumn(x, rows: queryRow) {
            columns.append(x)
        }
        XCTAssertFalse(columns.isEmpty, "no toggles at the query row's trailing end at scale \(scale)",
                       file: file, line: line)
        let stray = columns.filter { x in !slots.contains { $0.contains(x) } }
        XCTAssertTrue(stray.isEmpty, "ink outside the toggles' 16-point glyph slots at scale \(scale): \(stray.prefix(5))",
                      file: file, line: line)
        for (index, slot) in slots.enumerated() {
            XCTAssertTrue(columns.contains { slot.contains($0) },
                          "toggle slot \(index) from the trailing end is empty at scale \(scale)", file: file, line: line)
        }

        // The replace row: Replace All ends at the row's trailing edge.
        let replaceRow = (padding + fieldHeight + gap)..<(padding + 2 * fieldHeight + gap)
        let lastInk = try XCTUnwrap(
            stride(from: width - step, to: width / 2, by: -step).first { inkedColumn($0, rows: replaceRow) },
            "nothing drawn in the replace row's trailing half at scale \(scale)", file: file, line: line
        )
        XCTAssertLessThanOrEqual(lastInk, trailing + step, "Replace All overruns the padding at scale \(scale)",
                                 file: file, line: line)
        // The button's own border is its last ink, so its edge is the row's.
        XCTAssertGreaterThanOrEqual(
            lastInk, trailing - metrics.scaled(1.5),
            "Replace All does not sit at the replace row's trailing end at scale \(scale)", file: file, line: line
        )

        // The results. A match row is told from a header by the hit's highlight
        // — the only warm, saturated pixels in the window — so a header whose
        // path starts at 36, just past the 34, cannot stand in for a match line.
        let resultsTop = padding + 3 * fieldHeight + 3 * gap + metrics.scaled(24)
        let indent = metrics.scaled(34)
        let panel = ChromeTheme(.dark).color(.bgPanel)
        var matchStarts: [CGFloat] = []
        var headerStarts: [CGFloat] = []
        for y in stride(from: resultsTop, to: render.bounds.height - metrics.scaled(40), by: step) {
            let highlighted = stride(from: indent, to: width / 2, by: step).contains { x in
                guard let c = render.color(atX: x, y: y) else { return false }
                return c.redComponent > 0.45 && c.blueComponent < 0.25 && c.redComponent - c.blueComponent > 0.3
            }
            let start = stride(from: 0, to: indent + metrics.scaled(20), by: step).first {
                render.matches(.textSecondary, atX: $0, y: y, ground: panel)
            }
            guard let start else { continue }
            if highlighted {
                matchStarts.append(start)
            } else if start < indent - metrics.scaled(4) {
                headerStarts.append(start)
            }
        }
        let headerStart = try XCTUnwrap(headerStarts.min(), "no group header glyph at scale \(scale)", file: file, line: line)
        // The glyph's ink starts inside its slot by the drawing's own margin,
        // so the slot is what is checked: its leading edge at the content padding.
        let glyphSlot = padding...(padding + metrics.scaled(SearchLayout.headerGlyphSlot) / 2)
        XCTAssertTrue(glyphSlot.contains(headerStart),
                      "the header glyph \(headerStart) is not in its slot at the content padding at scale \(scale)",
                      file: file, line: line)
        let matchStart = try XCTUnwrap(matchStarts.min(), "no match line ink at scale \(scale)", file: file, line: line)
        XCTAssertEqual(matchStart, indent, accuracy: 2,
                       "match lines are not indented 34 at scale \(scale)", file: file, line: line)
    }
}
#endif
