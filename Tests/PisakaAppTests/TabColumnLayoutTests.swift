#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The vertical tab column, hosted in a real window and measured off a rendered
/// bitmap.
///
/// **The design.** The first row sits flush under the title bar — the column
/// has no top inset — every row is 28 points tall with a one-point `hairline`
/// rule along its bottom edge, and the selected row's ground is the column's
/// own: it is marked by its leading `accent` bar alone.
///
/// **How it is measured.** The column is rendered once per scale over three
/// open files with the first selected. The selected row's leading accent bar
/// spans exactly its row, so its extent at the leading edge is the first row's
/// top offset and height. The hairlines are the runs of `hairline` pixels in a
/// column right of every label and left of every trailing mark; their spacing
/// is the row height measured a second, independent way. The selected row's
/// middle, sampled in that same column, must read the column's `bgPanel`
/// ground rather than a fill of its own.
@MainActor
final class TabColumnLayoutTests: XCTestCase {

    func testTheColumnsRowsAtScaleOne() throws {
        try assertColumn(scale: 1)
    }

    func testTheColumnsRowsAtScaleOnePointEight() throws {
        try assertColumn(scale: 1.8)
    }

    private func assertColumn(scale: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let metrics = InterfaceMetrics(scale: scale)
        let rowHeight = metrics.scaled(28)
        let hairline = metrics.scaled(1)
        let width = metrics.scaled(220)
        let model = try makeModel(fileNames: ["a.swift", "b.md", "c.txt"])
        let panel = ChromeTheme(.dark).color(.bgPanel)

        let render = try HostedRender(
            size: CGSize(width: width, height: metrics.scaled(200)),
            root: TabListView(model: model)
                .environment(\.interfaceMetrics, metrics)
                .environment(\.chromeTheme, ChromeTheme(.dark))
        )
        addTeardownBlock { @MainActor in render.window.close() }

        // The first (selected) row: flush under the top edge, 28 tall.
        let accent = try XCTUnwrap(
            render.extent(of: .accent, atX: metrics.scaled(1), ground: panel),
            "no accent bar drawn on the selected row", file: file, line: line
        )
        XCTAssertEqual(accent.minY, 0, accuracy: 0.5, "the first row is not flush under the title bar", file: file, line: line)
        XCTAssertEqual(
            accent.maxY - accent.minY, rowHeight, accuracy: 0.5,
            "the selected row is not 28 points tall at scale \(scale)", file: file, line: line
        )

        // One hairline along each row's bottom edge.
        let probeX = width * 0.7
        let runs = hairlineRuns(in: render, atX: probeX, ground: panel)
        XCTAssertEqual(runs.count, 3, "one hairline per row: \(runs)", file: file, line: line)
        for (index, run) in runs.enumerated() {
            let rowBottom = rowHeight * CGFloat(index + 1)
            XCTAssertEqual(run.maxY, rowBottom, accuracy: 0.5, "row \(index)'s rule is not at its bottom", file: file, line: line)
            XCTAssertEqual(run.maxY - run.minY, hairline, accuracy: 0.5, "row \(index)'s rule is not a hairline", file: file, line: line)
        }

        // The selected row keeps the column's ground.
        XCTAssertTrue(
            render.matches(.bgPanel, atX: probeX, y: rowHeight / 2),
            "the selected row's ground changed", file: file, line: line
        )
    }

    /// The runs of `hairline` pixels down column `x`, read off the one bitmap.
    private func hairlineRuns(in render: HostedRender, atX x: CGFloat, ground: Color) -> [(minY: CGFloat, maxY: CGFloat)] {
        let step = 1 / render.pixelScale
        var runs: [(minY: CGFloat, maxY: CGFloat)] = []
        var start: CGFloat?
        for y in stride(from: 0, to: render.bounds.height, by: step) {
            let hit = render.matches(.hairline, atX: x, y: y, ground: ground)
            if hit, start == nil { start = y }
            if !hit, let open = start {
                runs.append((open, y))
                start = nil
            }
        }
        if let open = start { runs.append((open, render.bounds.height)) }
        return runs
    }

    private func makeModel(fileNames: [String]) throws -> WorkspaceModel {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TabColumnLayoutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let model = WorkspaceModel()
        model.openFolder(url: folder)
        var ids: [UUID] = []
        for name in fileNames {
            let url = folder.appendingPathComponent(name)
            try "x\n".write(to: url, atomically: true, encoding: .utf8)
            ids.append(try model.open(url: url).id)
        }
        model.select(ids[0])
        return model
    }
}
#endif
