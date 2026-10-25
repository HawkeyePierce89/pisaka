#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The project tree's indent guide, hosted in a real window and measured off a
/// rendered bitmap.
///
/// **The design.** An expanded folder draws one `hairline`-coloured vertical
/// rule behind its children block, `hairlineWidth` wide at the interface
/// scale, on the centre of the folder's own chevron column — so it hangs from
/// the open chevron and runs down beside everything the folder holds. The
/// folder's own row carries no guide.
///
/// **How it is measured.** One tree per scale — a root folder holding two
/// files, the root expanded as it always opens — two renders in all, every
/// sample read out of its one bitmap. The guide's column is scanned top to
/// bottom across the root row, the children block and the empty space below
/// it; its width and centre are read off one horizontal scan through a child
/// row's middle, left of the child's own chevron gutter, where nothing else is
/// drawn.
@MainActor
final class TreeIndentGuideLayoutTests: XCTestCase {

    func testTheGuideHangsFromTheRootChevronAndMovesWithTheScale() throws {
        let atOne = try measureGuide(scale: 1)
        let atOnePointEight = try measureGuide(scale: 1.8)
        XCTAssertGreaterThan(atOnePointEight.centre, atOne.centre + 1,
                             "the guide stayed put while the interface scale grew")
        XCTAssertGreaterThan(atOnePointEight.width, atOne.width,
                             "the guide's thickness did not grow with the interface scale")
    }

    /// Renders the tree at `scale`, asserts the guide's vertical span, width
    /// and position, and returns the measured centre and width in points.
    private func measureGuide(
        scale: Double, file: StaticString = #filePath, line: UInt = #line
    ) throws -> (centre: CGFloat, width: CGFloat) {
        let metrics = InterfaceMetrics(scale: scale)
        let root = try makeProject()
        let model = WorkspaceModel()
        model.openFolder(url: root)

        let render = try HostedRender(
            size: CGSize(width: metrics.scaled(240), height: metrics.scaled(160)),
            root: ProjectTreeView(model: model)
                .environment(\.interfaceMetrics, metrics)
                .environment(\.chromeTheme, ChromeTheme(.dark))
        )
        addTeardownBlock { @MainActor in render.window.close() }

        let step = 1 / render.pixelScale
        let rowHeight = metrics.scaled(ChromeGeometry.rowHeight)
        let padding = metrics.scaled(ChromeGeometry.rowPaddingX)
        let chevron = metrics.scaled(TreeRowLayout.chevronWidth)
        let indent = metrics.scaled(ChromeGeometry.treeIndentStep)
        let thickness = metrics.scaled(ChromeGeometry.hairlineWidth)
        // The tree's rows start under the header and the list's top padding.
        let rootTop = metrics.scaled(ChromeGeometry.sidebarHeaderHeight) + metrics.scaled(4)
        let rootRow = rootTop..<(rootTop + rowHeight)
        let block = rootRow.upperBound..<(rootRow.upperBound + 2 * rowHeight)
        let centre = padding + chevron / 2

        func isGuide(_ y: CGFloat) -> Bool { render.matches(.hairline, atX: centre, y: y) }

        // Across the children block, edge to edge (a pixel's grace at each end
        // for the half-point grid).
        let blockSamples = Array(stride(from: block.lowerBound + step, to: block.upperBound - step, by: step))
        let missing = blockSamples.filter { !isGuide($0) }
        XCTAssertTrue(missing.isEmpty,
                      "the guide is missing across the children block at scale \(scale), first gap at y \(missing.first ?? 0)",
                      file: file, line: line)
        // Not on the root row itself, above the block it belongs to.
        let rootSamples = Array(stride(from: rootRow.lowerBound, to: rootRow.upperBound - step, by: step))
        XCTAssertFalse(rootSamples.contains(where: isGuide),
                       "the guide reaches into the expanded folder's own row at scale \(scale)", file: file, line: line)
        // And not past the block's end.
        let belowSamples = Array(stride(from: block.upperBound + step, to: render.bounds.height, by: step))
        XCTAssertFalse(belowSamples.contains(where: isGuide),
                       "the guide runs on below the children block at scale \(scale)", file: file, line: line)

        // One horizontal scan through the first child's middle, left of its own
        // chevron gutter: the guide is the only thing drawn there.
        let midY = block.lowerBound + rowHeight / 2
        let columns = stride(from: 0, to: indent + padding, by: step).filter {
            render.matches(.hairline, atX: $0, y: midY)
        }
        let first = try XCTUnwrap(columns.first, "no guide in the first child row at scale \(scale)",
                                  file: file, line: line)
        let last = try XCTUnwrap(columns.last)
        let width = last + step - first
        XCTAssertEqual(CGFloat(columns.count) * step, width, accuracy: step / 2,
                       "the guide is not one contiguous column at scale \(scale)", file: file, line: line)
        XCTAssertEqual(width, thickness, accuracy: step,
                       "the guide is not the scaled hairline width at scale \(scale)", file: file, line: line)
        let measuredCentre = (first + last + step) / 2
        XCTAssertEqual(measuredCentre, centre, accuracy: step,
                       "the guide is off the root chevron's centre at scale \(scale)", file: file, line: line)
        return (measuredCentre, width)
    }

    /// A root folder holding two files, removed in teardown.
    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TreeIndentGuideLayoutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("let a = 1\n".utf8).write(to: root.appendingPathComponent("a.swift"))
        try Data("let b = 2\n".utf8).write(to: root.appendingPathComponent("b.swift"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
#endif
