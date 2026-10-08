#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The unified diff's per-line checkbox, hosted in a real window and measured
/// off a rendered bitmap.
///
/// **The rule.** The box on a changed line is the shared checkbox shape's
/// code-zone entry, sized by `CodeZoneCheckboxRule` from the code font alone:
/// it grows with the diff's font size and does not move with the interface
/// scale, because the row it sits on is the code zone. A context line reserves
/// the rule's placeholder width in the box's place, so its text starts where a
/// changed line's does.
///
/// **How it is measured.** The checked box is the one `accent` thing a row
/// draws, so its side is the bounding box of the pixels matching an `accent`
/// swatch rendered through the same pipeline. The check glyph inside it and the
/// rounded corners do not move that box's edges. The side is compared with the
/// rule's, scaled by the bitmap's backing factor, within one pixel, which
/// leaves room for an edge that lands between two pixels. Text position is
/// the first bright pixel of the old-line number, which both rows give the same
/// value, read to the right of the box on the changed row.
@MainActor
final class CommitDiffCheckboxLayoutTests: XCTestCase {

    private static let lines: [UnifiedDiffLine] = [
        UnifiedDiffLine(kind: .removed, text: "old", oldNumber: 8, newNumber: nil, unitIndex: 0),
        UnifiedDiffLine(kind: .context, text: "same", oldNumber: 8, newNumber: 8, unitIndex: nil),
    ]

    func testTheCheckedBoxIsTheRulesSideAtEachFontSize() throws {
        for fontSize in [13.0, 20.0] {
            let render = try BoxRender(fontSize: fontSize, interfaceScale: 1)
            addTeardownBlock { @MainActor in render.window.close() }
            let box = try XCTUnwrap(render.accentBox(), "no checked box is drawn at \(fontSize) pt")
            let expected = CGFloat(CodeZoneCheckboxRule(fontSize: fontSize).side) * render.pixelScale
            XCTAssertEqual(CGFloat(box.width), expected, accuracy: 1, "the box's width is not the rule's side at \(fontSize) pt")
            XCTAssertEqual(CGFloat(box.height), expected, accuracy: 1, "the box's height is not the rule's side at \(fontSize) pt")
        }
    }

    func testTheBoxDoesNotFollowTheInterfaceScale() throws {
        var sides: [Int] = []
        for scale in [1.0, 1.5] {
            let render = try BoxRender(fontSize: 16, interfaceScale: scale)
            addTeardownBlock { @MainActor in render.window.close() }
            let box = try XCTUnwrap(render.accentBox(), "no checked box is drawn at interface scale \(scale)")
            sides.append(box.width)
        }
        XCTAssertEqual(sides[0], sides[1], "the code row's box moved with the interface scale")
    }

    func testAContextRowsTextStartsWhereAChangedRowsDoes() throws {
        let render = try BoxRender(fontSize: 20, interfaceScale: 1)
        addTeardownBlock { @MainActor in render.window.close() }
        let box = try XCTUnwrap(render.accentBox(), "no checked box is drawn")
        let rowHeight = CGFloat(box.maxY - box.minY) / render.pixelScale
        let changed = try XCTUnwrap(render.extent(of: .diffRemovedBackground), "the removed line is not washed")
        let context = (minY: changed.maxY, maxY: changed.maxY + (changed.maxY - changed.minY))
        XCTAssertGreaterThan(changed.maxY - changed.minY, rowHeight, "the row is not taller than its box")
        let changedText = try XCTUnwrap(
            render.firstBrightPixel(in: changed, from: box.maxX + 1), "the changed row's number is not drawn"
        )
        let contextText = try XCTUnwrap(render.firstBrightPixel(in: context, from: 0), "the context row's number is not drawn")
        XCTAssertEqual(
            CGFloat(contextText), CGFloat(changedText), accuracy: 1,
            "a context row's text does not start where a changed row's does — the placeholder is not the box's width"
        )
    }

    /// The two lines hosted as the commit dialog draws them, unit 0 checked, in a
    /// 600 × 200 window on a black ground in the dark appearance.
    @MainActor
    private final class BoxRender {
        private let render: HostedRender
        private let accent: NSColor
        var window: NSWindow { render.window }
        var pixelScale: CGFloat { render.pixelScale }

        init(fontSize: Double, interfaceScale: Double) throws {
            let root = CommitUnifiedDiffView(
                rows: CommitDiffCheckboxLayoutTests.lines.map { .line($0) }, selectedUnits: [0],
                wholeOnlyMessage: nil, fontSize: fontSize
            )
            .frame(width: 600, height: 200)
            .environment(\.chromeTheme, ChromeTheme(.dark))
            .environment(\.interfaceMetrics, InterfaceMetrics(scale: interfaceScale))
            .background(Color.black)
            render = try HostedRender(size: CGSize(width: 600, height: 200), root: root)
            accent = try XCTUnwrap(HostedRender.swatch(.accent, ground: nil), "no accent swatch")
        }

        /// A pixel bounding box, `maxX`/`maxY` exclusive.
        struct PixelBox {
            let minX: Int, maxX: Int, minY: Int, maxY: Int
            var width: Int { maxX - minX }
            var height: Int { maxY - minY }
        }

        /// The pixel bounding box of every `accent` pixel.
        func accentBox() -> PixelBox? {
            var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
            let rows = Int(render.bounds.height * pixelScale)
            for row in 0..<rows {
                autoreleasepool {
                    let y = CGFloat(row) / pixelScale
                    for pixel in 0..<render.pixelsWide where Self.close(render.color(atPixelX: pixel, y: y), accent) {
                        minX = min(minX, pixel)
                        maxX = max(maxX, pixel + 1)
                        minY = min(minY, row)
                        maxY = max(maxY, row + 1)
                    }
                }
            }
            guard minX <= maxX else { return nil }
            return PixelBox(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
        }

        func extent(of role: ChromeColorRole) -> (minY: CGFloat, maxY: CGFloat)? {
            render.extent(of: role, atX: 590, ground: .black)
        }

        /// The leftmost pixel column at or after `start` holding a bright,
        /// non-`accent` pixel inside the band, inset one point at each edge.
        func firstBrightPixel(in band: (minY: CGFloat, maxY: CGFloat), from start: Int) -> Int? {
            for pixel in start..<render.pixelsWide {
                for y in stride(from: band.minY + 1, to: band.maxY - 1, by: 1 / pixelScale) {
                    guard let color = render.color(atPixelX: pixel, y: y), !Self.close(color, accent) else { continue }
                    if max(color.redComponent, color.greenComponent, color.blueComponent) > 0.35 { return pixel }
                }
            }
            return nil
        }

        private static func close(_ color: NSColor?, _ expected: NSColor) -> Bool {
            guard let color else { return false }
            return abs(color.redComponent - expected.redComponent) < 0.02
                && abs(color.greenComponent - expected.greenComponent) < 0.02
                && abs(color.blueComponent - expected.blueComponent) < 0.02
        }
    }
}
#endif
