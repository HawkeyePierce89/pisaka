#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The project tree's design glyphs, hosted in a real window and measured off a
/// rendered bitmap.
///
/// **The design.** A folder row leads with its disclosure chevron in a
/// 12-point slot, a 4-point gap, then its folder glyph in a 14-point slot; a
/// file row leaves the chevron column blank and draws its file glyph in the
/// same 14-point slot, one indent step in.
///
/// **How it is measured.** One tree is rendered per scale — a root folder
/// holding one Swift file, the root expanded as it always opens — and every
/// sample is read out of that one bitmap. Ink is any pixel that differs from
/// the row's own ground, sampled at the row's leading edge; each slot's inked
/// bounding box must be non-empty and lie inside the slot, and the gap between
/// the chevron and the folder glyph must stay clean.
@MainActor
final class TreeRowGlyphLayoutTests: XCTestCase {

    func testTheTreesGlyphSlotsAtScaleOne() throws {
        try assertTree(scale: 1)
    }

    func testTheTreesGlyphSlotsAtScaleOnePointEight() throws {
        try assertTree(scale: 1.8)
    }

    private func assertTree(scale: Double, file: StaticString = #filePath, line: UInt = #line) throws {
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

        let rowHeight = metrics.scaled(ChromeGeometry.rowHeight)
        let padding = metrics.scaled(ChromeGeometry.rowPaddingX)
        let chevron = metrics.scaled(TreeRowLayout.chevronWidth)
        let gap = metrics.scaled(TreeRowLayout.chevronSpacing)
        let icon = metrics.scaled(TreeRowLayout.iconSize)
        let indent = metrics.scaled(ChromeGeometry.treeIndentStep)
        // The tree's rows start under the header and the list's top padding.
        let rootTop = metrics.scaled(ChromeGeometry.sidebarHeaderHeight) + metrics.scaled(4)
        let rootRow = rootTop..<(rootTop + rowHeight)
        let fileRow = rootRow.upperBound..<(rootRow.upperBound + rowHeight)

        // The root folder row: chevron, gap, folder glyph.
        let chevronSlot = padding..<(padding + chevron)
        let folderSlot = (chevronSlot.upperBound + gap)..<(chevronSlot.upperBound + gap + icon)
        let chevronInk = try XCTUnwrap(
            ink(in: render, x: chevronSlot, rows: rootRow), "the folder row drew no chevron at scale \(scale)",
            file: file, line: line
        )
        assertInside(chevronInk, slot: chevronSlot, side: chevron, "chevron", scale: scale, file: file, line: line)
        let folderInk = try XCTUnwrap(
            ink(in: render, x: folderSlot, rows: rootRow), "the folder row drew no folder glyph at scale \(scale)",
            file: file, line: line
        )
        assertInside(folderInk, slot: folderSlot, side: icon, "folder glyph", scale: scale, file: file, line: line)
        XCTAssertGreaterThan(folderInk.width, icon * 0.6, "the folder glyph is drawn far smaller than 14 points",
                             file: file, line: line)
        XCTAssertNil(
            ink(in: render, x: (chevronSlot.upperBound + 0.5)..<(folderSlot.lowerBound - 0.5), rows: rootRow),
            "ink in the gap between the chevron and the folder glyph at scale \(scale)", file: file, line: line
        )

        // The file row, one indent in: a blank chevron column, then its glyph.
        let fileChevronSlot = (indent + padding)..<(indent + padding + chevron)
        let fileSlot = (fileChevronSlot.upperBound + gap)..<(fileChevronSlot.upperBound + gap + icon)
        XCTAssertNil(ink(in: render, x: fileChevronSlot, rows: fileRow),
                     "a file row drew something in its chevron column at scale \(scale)", file: file, line: line)
        let fileInk = try XCTUnwrap(
            ink(in: render, x: fileSlot, rows: fileRow), "the file row drew no file glyph at scale \(scale)",
            file: file, line: line
        )
        assertInside(fileInk, slot: fileSlot, side: icon, "file glyph", scale: scale, file: file, line: line)
        XCTAssertGreaterThan(fileInk.height, icon * 0.6, "the file glyph is drawn far smaller than 14 points",
                             file: file, line: line)
    }

    // MARK: - Helpers

    /// The bounding box of every pixel in `x` × `rows` that differs from the
    /// row's ground — sampled at the row's leading edge, inside the padding —
    /// or `nil` when the region is clean. Reads the one bitmap; creates nothing.
    private func ink(in render: HostedRender, x: Range<CGFloat>, rows: Range<CGFloat>) -> CGRect? {
        let step = 1 / render.pixelScale
        guard let ground = render.color(atX: step, y: (rows.lowerBound + rows.upperBound) / 2) else { return nil }
        var box: CGRect?
        for py in stride(from: rows.lowerBound, to: rows.upperBound, by: step) {
            for px in stride(from: x.lowerBound, to: x.upperBound, by: step) {
                guard let color = render.color(atX: px, y: py), differs(color, ground) else { continue }
                let pixel = CGRect(x: px, y: py, width: step, height: step)
                box = box.map { $0.union(pixel) } ?? pixel
            }
        }
        return box
    }

    private func differs(_ color: NSColor, _ ground: NSColor) -> Bool {
        abs(color.redComponent - ground.redComponent) > 0.08
            || abs(color.greenComponent - ground.greenComponent) > 0.08
            || abs(color.blueComponent - ground.blueComponent) > 0.08
    }

    private func assertInside(
        _ box: CGRect, slot: Range<CGFloat>, side: CGFloat, _ what: String, scale: Double,
        file: StaticString, line: UInt
    ) {
        XCTAssertGreaterThanOrEqual(box.minX, slot.lowerBound - 1, "the \(what) spills left of its slot at scale \(scale)",
                                    file: file, line: line)
        XCTAssertLessThanOrEqual(box.maxX, slot.upperBound + 1, "the \(what) spills right of its slot at scale \(scale)",
                                 file: file, line: line)
        XCTAssertLessThanOrEqual(box.height, side + 1, "the \(what) is taller than its slot at scale \(scale)",
                                 file: file, line: line)
    }

    /// A root folder holding one Swift file, removed in teardown.
    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TreeRowGlyphLayoutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("let x = 1\n".utf8).write(to: root.appendingPathComponent("main.swift"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
#endif
