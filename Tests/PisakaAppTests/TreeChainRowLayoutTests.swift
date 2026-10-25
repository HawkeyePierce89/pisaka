#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// A chain row (`TreeChainRule`), hosted in a real window and measured off a
/// rendered bitmap.
///
/// **The design.** A run of folders each holding nothing but the next one —
/// `a/b/c` — is drawn as **one** row, exactly one `rowHeight` tall, and costs
/// one indent step, not one per segment: its children sit one
/// `treeIndentStep` right of it, and the one `hairline` guide beside them
/// hangs from the chain row's own chevron. The inner segments are no nodes, so
/// they hang no guide of their own.
///
/// **How it is measured.** A real temporary project whose root holds only the
/// run `a/b/c`, and `c` two files; a Reveal in Project Tree request for one of
/// the files expands the chain through the reveal path. One window per scale —
/// two renders in all — and every sample is read out of its one bitmap:
/// - **Rows** are counted by ink: each row slot below the header is inked or
///   clean, ink being any pixel that differs from the row's ground at its
///   leading edge, as the glyph-slot suite reads it.
/// - **The chain row's height** is the distance between the tops of the two
///   guides: the root's starts at the chain row's top, the chain's at its
///   bottom.
/// - **The indent** is read off the glyphs: the chain's chevron and folder
///   glyph are the root's own artwork, so each sits exactly one step right of
///   the root's; the files' glyphs lie in the slot one step right of the
///   chain's.
/// - **The guide** is scanned down its column and across the first file's row,
///   and the column an inner segment's guide would take is scanned clean.
@MainActor
final class TreeChainRowLayoutTests: XCTestCase {

    func testAChainIsOneRowAndOneIndentStepAtScaleOne() throws {
        try assertChain(scale: 1)
    }

    func testAChainIsOneRowAndOneIndentStepAtScaleOnePointEight() throws {
        try assertChain(scale: 1.8)
    }

    private func assertChain(scale: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let metrics = InterfaceMetrics(scale: scale)
        let root = try makeProject()
        let model = WorkspaceModel()
        model.openFolder(url: root)
        let reveal = try XCTUnwrap(
            TreeRevealRequest(after: nil, revealing: root.appendingPathComponent("a/b/c/one.swift"), root: root)
        )

        let render = try HostedRender(
            size: CGSize(width: metrics.scaled(240), height: metrics.scaled(220)),
            root: ProjectTreeView(model: model, reveal: reveal)
                .environment(\.interfaceMetrics, metrics)
                .environment(\.chromeTheme, ChromeTheme(.dark))
        )
        addTeardownBlock { @MainActor in render.window.close() }

        let step = 1 / render.pixelScale
        let rowHeight = metrics.scaled(ChromeGeometry.rowHeight)
        let padding = metrics.scaled(ChromeGeometry.rowPaddingX)
        let chevron = metrics.scaled(TreeRowLayout.chevronWidth)
        let gap = metrics.scaled(TreeRowLayout.chevronSpacing)
        let icon = metrics.scaled(TreeRowLayout.iconSize)
        let indent = metrics.scaled(ChromeGeometry.treeIndentStep)
        let thickness = metrics.scaled(ChromeGeometry.hairlineWidth)
        // The tree's rows start under the header and the list's top padding.
        let top = metrics.scaled(ChromeGeometry.sidebarHeaderHeight) + metrics.scaled(4)
        func row(_ index: Int) -> Range<CGFloat> {
            (top + CGFloat(index) * rowHeight)..<(top + CGFloat(index + 1) * rowHeight)
        }
        func chevronSlot(depth: Int) -> Range<CGFloat> {
            let start = CGFloat(depth) * indent + padding
            return start..<(start + chevron)
        }
        func glyphSlot(depth: Int) -> Range<CGFloat> {
            let start = chevronSlot(depth: depth).upperBound + gap
            return start..<(start + icon)
        }
        func guideCentre(depth: Int) -> CGFloat { CGFloat(depth) * indent + padding + chevron / 2 }

        // Exactly four rows — the root, the chain, the two files — and every
        // row slot below them clean.
        let slots = Int((render.bounds.height - top) / rowHeight)
        XCTAssertGreaterThan(slots, 5, "the window leaves no room below the rows at scale \(scale)",
                             file: file, line: line)
        let inked = (0..<slots).map { ink(in: render, x: 0..<render.bounds.width, rows: row($0)) != nil }
        XCTAssertEqual(inked, [true, true, true, true] + Array(repeating: false, count: slots - 4),
                       "the tree did not draw exactly four rows at scale \(scale)", file: file, line: line)

        // The chain row's glyphs are the root's own, exactly one step in.
        let rootChevron = try XCTUnwrap(ink(in: render, x: chevronSlot(depth: 0), rows: row(0)),
                                        "the root row drew no chevron at scale \(scale)", file: file, line: line)
        let chainChevron = try XCTUnwrap(ink(in: render, x: chevronSlot(depth: 1), rows: row(1)),
                                         "the chain row drew no chevron at scale \(scale)", file: file, line: line)
        XCTAssertEqual(chainChevron.minX - rootChevron.minX, indent, accuracy: step,
                       "the chain's chevron is not one indent step right of the root's at scale \(scale)",
                       file: file, line: line)
        let rootGlyph = try XCTUnwrap(ink(in: render, x: glyphSlot(depth: 0), rows: row(0)),
                                      "the root row drew no folder glyph at scale \(scale)", file: file, line: line)
        let chainGlyph = try XCTUnwrap(ink(in: render, x: glyphSlot(depth: 1), rows: row(1)),
                                       "the chain row drew no folder glyph at scale \(scale)", file: file, line: line)
        XCTAssertEqual(chainGlyph.minX - rootGlyph.minX, indent, accuracy: step,
                       "the chain's folder glyph is not one indent step right of the root's at scale \(scale)",
                       file: file, line: line)

        // Each file's glyph sits in the slot one step right of the chain's —
        // never a step per segment — and the two share one column.
        var fileGlyphs: [CGRect] = []
        for index in [2, 3] {
            let fileGlyph = try XCTUnwrap(ink(in: render, x: glyphSlot(depth: 2), rows: row(index)),
                                          "file row \(index) drew no glyph one step in at scale \(scale)",
                                          file: file, line: line)
            let slot = glyphSlot(depth: 2)
            XCTAssertGreaterThanOrEqual(fileGlyph.minX, slot.lowerBound - 1,
                                        "file row \(index)'s glyph spills left of its slot at scale \(scale)",
                                        file: file, line: line)
            XCTAssertLessThanOrEqual(fileGlyph.maxX, slot.upperBound + 1,
                                     "file row \(index)'s glyph spills right of its slot at scale \(scale)",
                                     file: file, line: line)
            fileGlyphs.append(fileGlyph)
        }
        XCTAssertEqual(fileGlyphs[0].minX, fileGlyphs[1].minX, accuracy: step / 2,
                       "the two files' glyphs are not in one column at scale \(scale)", file: file, line: line)

        // The guides: the root's runs beside the chain and the files; the
        // chain's starts at the chain row's bottom and runs beside the files.
        let rootGuide = try XCTUnwrap(guideRun(in: render, atX: guideCentre(depth: 0), from: top),
                                      "the root hangs no guide at scale \(scale)", file: file, line: line)
        let chainGuide = try XCTUnwrap(guideRun(in: render, atX: guideCentre(depth: 1), from: top),
                                       "the chain row hangs no guide at scale \(scale)", file: file, line: line)
        XCTAssertEqual(chainGuide.lowerBound - rootGuide.lowerBound, rowHeight, accuracy: step,
                       "the chain row is not exactly one row tall at scale \(scale)", file: file, line: line)
        XCTAssertEqual(rootGuide.lowerBound, row(1).lowerBound, accuracy: step,
                       "the root's guide does not start at the chain row at scale \(scale)", file: file, line: line)
        XCTAssertEqual(chainGuide.lowerBound, row(2).lowerBound, accuracy: step,
                       "the chain's guide does not start below its own row at scale \(scale)", file: file, line: line)
        XCTAssertEqual(chainGuide.upperBound, row(3).upperBound, accuracy: step,
                       "the chain's guide does not end with its children at scale \(scale)", file: file, line: line)
        XCTAssertEqual(rootGuide.upperBound, chainGuide.upperBound, accuracy: step,
                       "the root's guide does not end with the tree's last row at scale \(scale)",
                       file: file, line: line)
        let gaps = stride(from: chainGuide.lowerBound + step, to: chainGuide.upperBound - step, by: step)
            .filter { !render.matches(.hairline, atX: guideCentre(depth: 1), y: $0) }
        XCTAssertTrue(gaps.isEmpty, "the chain's guide has a gap at y \(gaps.first ?? 0) at scale \(scale)",
                      file: file, line: line)

        // One horizontal scan through the first file's middle, right of the
        // root's guide and left of the file's own chevron gutter: the chain's
        // guide is the only thing drawn there.
        let midY = row(2).lowerBound + rowHeight / 2
        let columns = stride(from: indent, to: chevronSlot(depth: 2).lowerBound, by: step).filter {
            render.matches(.hairline, atX: $0, y: midY)
        }
        let first = try XCTUnwrap(columns.first, "no guide beside the first file at scale \(scale)",
                                  file: file, line: line)
        let last = try XCTUnwrap(columns.last)
        let width = last + step - first
        XCTAssertEqual(CGFloat(columns.count) * step, width, accuracy: step / 2,
                       "the chain's guide is not one contiguous column at scale \(scale)", file: file, line: line)
        XCTAssertEqual(width, thickness, accuracy: step,
                       "the chain's guide is not the scaled hairline width at scale \(scale)", file: file, line: line)
        XCTAssertEqual((first + last + step) / 2, guideCentre(depth: 1), accuracy: step,
                       "the chain's guide is off the chain row's chevron centre at scale \(scale)",
                       file: file, line: line)

        // No guide for an inner segment: the column `b` would hang one from,
        // were it a node of its own, is clean from the first row down.
        XCTAssertNil(guideRun(in: render, atX: guideCentre(depth: 2), from: top),
                     "an inner segment hangs a guide of its own at scale \(scale)", file: file, line: line)
    }

    // MARK: - Helpers

    /// The vertical span, in points, of the `hairline` pixels in column `x` at
    /// or below `y` — first to last — or nil for none. Starting below the
    /// header keeps its own bottom rule out of the span. Reads the one bitmap.
    private func guideRun(in render: HostedRender, atX x: CGFloat, from y: CGFloat) -> Range<CGFloat>? {
        let step = 1 / render.pixelScale
        let hits = stride(from: y, to: render.bounds.height, by: step).filter {
            render.matches(.hairline, atX: x, y: $0)
        }
        guard let first = hits.first, let last = hits.last else { return nil }
        return first..<(last + step)
    }

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

    /// A root folder holding only the run `a/b/c`, `c` holding two files,
    /// removed in teardown.
    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TreeChainRowLayoutTests-\(UUID().uuidString)", isDirectory: true)
        let tail = root.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: tail, withIntermediateDirectories: true)
        try Data("let one = 1\n".utf8).write(to: tail.appendingPathComponent("one.swift"))
        try Data("let two = 2\n".utf8).write(to: tail.appendingPathComponent("two.swift"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
#endif
