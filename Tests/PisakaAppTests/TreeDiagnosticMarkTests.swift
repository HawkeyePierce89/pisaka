#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The project tree's severity dot, hosted in a real window and measured off a
/// rendered bitmap.
///
/// **The design.** A row whose file — or anything below whose folder — carries
/// an error or a warning draws a dot `TreeRowLayout.diagnosticDotSize` across in
/// its glyph's bottom-trailing corner, in the severity's one role
/// (`ChromeColorRole.diagnosticRole(for:)`): `statusRed` for an error,
/// `statusYellow` for a warning. A collapsed folder answers for what it holds.
/// A clean row draws exactly as the tree without a lookup.
///
/// **How it is measured.** One window per scale, each rendered twice — first
/// with `.empty`, then with the lookup handed in through the same hosted view —
/// so four renders in all. The project is a root folder holding a collapsed
/// clean folder, a collapsed folder holding a warning file, a clean file, an
/// error file and a warning file, which list in that order (directories first,
/// then by name). The samples the comparison needs are copied out of the first
/// render before the second replaces it. The glyph slots are the ones
/// `TreeRowGlyphLayoutTests` pins.
@MainActor
final class TreeDiagnosticMarkTests: XCTestCase {

    func testRowsCarryTheirWorstSeverityAsADotOnTheGlyph() throws {
        let root = try makeProject()
        var store = DiagnosticStore()
        let serverKey = DiagnosticStore.ServerKey(serverID: "test-server", root: root.path)
        let errorFile = root.appendingPathComponent("error.swift")
        store.replace(url: errorFile, serverKey: serverKey, diagnostics: [
            Diagnostic(
                range: NSRange(location: 0, length: 3), line: 0, severity: .error,
                message: "m", source: "test", fileURL: errorFile
            ),
        ])
        for path in ["warning.swift", "flagged/inner.swift"] {
            let file = root.appendingPathComponent(path)
            store.replace(url: file, serverKey: serverKey, positional: [
                PositionalDiagnostic(
                    range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 3)),
                    severity: .warning, message: "m", source: "test", fileURL: file
                ),
            ])
        }
        let lookup = TreeDiagnostics(store: store, root: TreeDiagnostics.Root(root))

        let small = try assertTree(root, lookup: lookup, scale: 1)
        let large = try assertTree(root, lookup: lookup, scale: 1.8)
        XCTAssertGreaterThan(large, small, "the error dot did not grow with the interface scale")
    }

    /// Renders the tree at `scale` without and then with `lookup`, asserts every
    /// row's dot, and answers the error dot's measured height.
    private func assertTree(
        _ root: URL, lookup: TreeDiagnostics, scale: Double, file: StaticString = #filePath, line: UInt = #line
    ) throws -> CGFloat {
        let metrics = InterfaceMetrics(scale: scale)
        let model = WorkspaceModel()
        model.openFolder(url: root)
        let box = LookupBox()
        let render = try HostedRender(
            size: CGSize(width: metrics.scaled(240), height: metrics.scaled(240)),
            root: Host(model: model, box: box)
                .environment(\.interfaceMetrics, metrics)
                .environment(\.chromeTheme, ChromeTheme(.dark))
        )
        addTeardownBlock { @MainActor in render.window.close() }

        let rowHeight: CGFloat = metrics.scaled(ChromeGeometry.rowHeight)
        let padding: CGFloat = metrics.scaled(ChromeGeometry.rowPaddingX)
        let gutter: CGFloat = TreeRowLayout.chevronGutter(metrics)
        let slot: CGFloat = metrics.pt(TreeRowLayout.iconSize)
        let indent: CGFloat = metrics.scaled(ChromeGeometry.treeIndentStep)
        // The tree's rows start under the header and the list's top padding.
        let top: CGFloat = metrics.scaled(ChromeGeometry.sidebarHeaderHeight) + metrics.scaled(4)
        func row(_ index: Int) -> Range<CGFloat> {
            (top + CGFloat(index) * rowHeight)..<(top + CGFloat(index + 1) * rowHeight)
        }
        // The root's glyph slot, and every child's one indent step in.
        let rootSlot = (padding + gutter)..<(padding + gutter + slot)
        let childSlot = (indent + padding + gutter)..<(indent + padding + gutter + slot)
        /// The bottom-trailing quarter of a glyph slot on row `index`: the slot is
        /// centred in its row, the dot sits in its corner.
        func corner(_ x: Range<CGFloat>, row index: Int) -> (x: Range<CGFloat>, rows: Range<CGFloat>) {
            let glyphTop = row(index).lowerBound + (rowHeight - slot) / 2
            return ((x.lowerBound + slot / 2)..<x.upperBound, (glyphTop + slot / 2)..<(glyphTop + slot))
        }
        let rootRow = 0, cleanFolder = 1, flaggedFolder = 2, cleanFile = 3, errorFileRow = 4, warningFileRow = 5

        // Without the lookup: no dot anywhere, and the clean slots recorded.
        for (x, index) in [(rootSlot, rootRow), (childSlot, errorFileRow)] {
            let area = corner(x, row: index)
            XCTAssertFalse(contains(.statusRed, in: render, x: area.x, rows: area.rows),
                           "row \(index) drew statusRed with no lookup at scale \(scale)", file: file, line: line)
        }
        let cleanSlots = [cleanFolder, cleanFile].map { pixels(in: render, x: childSlot, rows: row($0)) }

        box.lookup = lookup
        render.settle(file: file, line: line)
        try render.capture()

        for (x, index, what) in [(rootSlot, rootRow, "root folder"), (childSlot, errorFileRow, "error file")] {
            let area = corner(x, row: index)
            XCTAssertTrue(contains(.statusRed, in: render, x: area.x, rows: area.rows),
                          "the \(what)'s glyph has no statusRed dot at scale \(scale)", file: file, line: line)
        }
        for (index, what) in [(flaggedFolder, "folder holding a warning"), (warningFileRow, "warning file")] {
            let area = corner(childSlot, row: index)
            XCTAssertTrue(contains(.statusYellow, in: render, x: area.x, rows: area.rows),
                          "the \(what)'s glyph has no statusYellow dot at scale \(scale)", file: file, line: line)
            XCTAssertFalse(contains(.statusRed, in: render, x: area.x, rows: area.rows),
                           "the \(what) drew an error's dot at scale \(scale)", file: file, line: line)
        }
        for (recorded, index) in zip(cleanSlots, [cleanFolder, cleanFile]) {
            XCTAssertTrue(
                same(recorded, pixels(in: render, x: childSlot, rows: row(index))),
                "the clean row \(index)'s glyph slot changed under the lookup at scale \(scale)", file: file, line: line
            )
        }

        // The error dot's height, down the column through its centre: the
        // file's dot is the only red one that column crosses.
        let dot: CGFloat = metrics.scaled(TreeRowLayout.diagnosticDotSize)
        let extent = try XCTUnwrap(
            render.extent(of: .statusRed, atX: childSlot.upperBound - dot / 2),
            "no statusRed down the error dot's centre at scale \(scale)", file: file, line: line
        )
        let height = extent.maxY - extent.minY
        XCTAssertEqual(height, dot, accuracy: 1.5, "the error dot is not \(dot) points tall at scale \(scale)",
                       file: file, line: line)
        return height
    }

    // MARK: - Helpers

    /// The lookup the hosted tree reads, swapped between the two renders.
    private final class LookupBox: ObservableObject {
        @Published var lookup: TreeDiagnostics = .empty
    }

    private struct Host: View {
        let model: WorkspaceModel
        @ObservedObject var box: LookupBox

        var body: some View {
            ProjectTreeView(model: model, diagnostics: box.lookup)
        }
    }

    /// Whether any pixel in `x` × `rows` is `role`. Reads the one bitmap.
    private func contains(
        _ role: ChromeColorRole, in render: HostedRender, x: Range<CGFloat>, rows: Range<CGFloat>
    ) -> Bool {
        let step = 1 / render.pixelScale
        for py in stride(from: rows.lowerBound, to: rows.upperBound, by: step) {
            for px in stride(from: x.lowerBound, to: x.upperBound, by: step)
            where render.matches(role, atX: px, y: py) {
                return true
            }
        }
        return false
    }

    /// Every pixel in `x` × `rows`, copied out of the current bitmap.
    private func pixels(in render: HostedRender, x: Range<CGFloat>, rows: Range<CGFloat>) -> [NSColor?] {
        let step = 1 / render.pixelScale
        return stride(from: rows.lowerBound, to: rows.upperBound, by: step).flatMap { py in
            stride(from: x.lowerBound, to: x.upperBound, by: step).map { render.color(atX: $0, y: py) }
        }
    }

    /// Whether two copied areas draw alike, pixel for pixel.
    private func same(_ lhs: [NSColor?], _ rhs: [NSColor?]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { a, b in
            guard let a, let b else { return false }
            return abs(a.redComponent - b.redComponent) <= 0.004
                && abs(a.greenComponent - b.greenComponent) <= 0.004
                && abs(a.blueComponent - b.blueComponent) <= 0.004
        }
    }

    /// A root folder holding a clean folder, a folder with one file, and three
    /// files, removed in teardown. Both folders stay collapsed.
    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TreeDiagnosticMarkTests-\(UUID().uuidString)", isDirectory: true)
        for folder in ["clean", "flagged"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder), withIntermediateDirectories: true
            )
        }
        for name in ["clean/inner.swift", "flagged/inner.swift", "clean.swift", "error.swift", "warning.swift"] {
            try Data("let x = 1\n".utf8).write(to: root.appendingPathComponent(name))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
#endif
