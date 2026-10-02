#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The bottom dock's tab row, hosted in a real window and measured off a
/// rendered bitmap.
///
/// **The bug.** In a 1000-point row the six tabs spread across the whole width
/// instead of sitting together at the leading edge with the close action at the
/// trailing one. Each tab's label was a `VStack` of its title over a
/// `Rectangle` carrying only a height frame; a shape accepts any width it is
/// offered, so every tab became width-flexible and the outer `HStack` shared the
/// row's spare width among the six of them rather than giving it to the
/// `Spacer`. Measured in this harness on the row as it was, in a 1000-point
/// row at scale 1, every tab was 157 or 158 points wide against padded titles
/// of 41 to 103 points.
///
/// **The rule now.** The title alone sizes a tab; the strip takes its width from
/// the title and sits under it, so it can never ask for width of its own.
///
/// **How it is measured.** The hosted row exposes no accessibility children in
/// a headless window, and the plan forbids a test-only seam in the production
/// view, so everything here is read off pixels. The row is rendered once per
/// selection on a black ground; the selected tab's accent strip is the one run
/// of `accent` pixels along the bottom edge, so six renders give six tab
/// extents. A tab's *expected* width is computed independently — the title's
/// width in the system font at the scaled `.callout` size, plus the label
/// padding on both sides — so "the strip is as wide as its tab" is not the strip
/// measured against itself. The close action is the last run of ink at the
/// trailing end of the row's middle band. The row's private gaps
/// (`DockTabRowLayout`, 2 and 10 points) are restated here as literals.
@MainActor
final class DockTabRowLayoutTests: XCTestCase {

    func testTheTabsArePackedAtTheLeadingEdge() throws {
        try assertPacked(scale: 1)
    }

    func testTheTabsArePackedAtInterfaceScaleOnePointEight() throws {
        try assertPacked(scale: 1.8)
    }

    private func assertPacked(scale: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let metrics = InterfaceMetrics(scale: scale)
        let rowWidth = 1000 * CGFloat(scale)
        let paddingX = metrics.scaled(ChromeGeometry.dockTabRowPaddingX)
        let labelPaddingX = metrics.scaled(ChromeGeometry.dockTabLabelPaddingX)
        let tabGap = metrics.scaled(2)
        let closeGap = metrics.scaled(10)
        let font = NSFont.systemFont(ofSize: CGFloat(metrics.font(.callout)))

        var strips: [(panel: BottomPanel, minX: CGFloat, maxX: CGFloat)] = []
        var closeExtent: (minX: CGFloat, maxX: CGFloat)?
        for panel in BottomPanel.allCases {
            let render = try DockTabRowRender(selection: panel, metrics: metrics, width: rowWidth)
            addTeardownBlock { @MainActor in render.window.close() }
            let strip = try XCTUnwrap(
                render.accentRun(), "no accent strip drawn for \(panel)", file: file, line: line
            )
            strips.append((panel, strip.minX, strip.maxX))
            closeExtent = try XCTUnwrap(render.trailingInkRun(), "no close action drawn", file: file, line: line)
        }

        // Each strip is as wide as its tab: the padded title, measured apart.
        for strip in strips {
            let title = (strip.panel.title as NSString).size(withAttributes: [.font: font]).width
            let expected = title + 2 * labelPaddingX
            XCTAssertEqual(
                strip.maxX - strip.minX, expected, accuracy: 1.5,
                "the \(strip.panel) tab is not as wide as its padded title at scale \(scale)",
                file: file, line: line
            )
        }

        // Packed from the leading padding, neighbours one gap apart.
        XCTAssertEqual(
            strips[0].minX, paddingX, accuracy: 0.5,
            "the first tab does not start at the leading padding at scale \(scale)", file: file, line: line
        )
        for (previous, next) in zip(strips, strips.dropFirst()) {
            XCTAssertEqual(
                next.minX - previous.maxX, tabGap, accuracy: 0.5,
                "\(previous.panel) and \(next.panel) are not one tab gap apart at scale \(scale)",
                file: file, line: line
            )
        }

        // The close action at the trailing edge, and the rest of the row between.
        let close = try XCTUnwrap(closeExtent)
        XCTAssertEqual(
            close.maxX, rowWidth - paddingX, accuracy: metrics.scaled(3),
            "the close action does not sit at the trailing padding at scale \(scale)", file: file, line: line
        )
        let lastTabEnd = try XCTUnwrap(strips.last).maxX
        let closeWidth = close.maxX - close.minX
        XCTAssertLessThan(closeWidth, metrics.scaled(20), "the trailing ink run is not the close glyph alone")
        let rest = rowWidth - paddingX - lastTabEnd - closeWidth
        XCTAssertGreaterThan(rest, closeGap, "the row has no spare width — the case is not exercised")
        XCTAssertEqual(
            close.minX - lastTabEnd, rest, accuracy: metrics.scaled(3),
            "the space between the last tab and the close action is not the rest of the row at scale \(scale)",
            file: file, line: line
        )
    }
}

/// `DockTabRow` hosted in a borderless window on a black ground, rendered to a
/// bitmap once its layout has settled.
@MainActor
private final class DockTabRowRender {
    let window: NSWindow
    private let rep: NSBitmapImageRep
    /// Bitmap pixels per point.
    private let pixelScale: CGFloat
    private let rowHeight: CGFloat

    init(selection: BottomPanel, metrics: InterfaceMetrics, width: CGFloat) throws {
        rowHeight = metrics.scaled(ChromeGeometry.dockTabRowHeight)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: rowHeight),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let root = DockTabRow(selection: selection, onSelect: { _ in }, onClose: {})
            .environment(\.interfaceMetrics, metrics)
            .environment(\.chromeTheme, ChromeTheme(.dark))
            .frame(width: width, height: rowHeight)
            .background(Color.black)
        let host = NSHostingView(rootView: root)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        pixelScale = CGFloat(rep.pixelsWide) / host.bounds.width
    }

    private func color(atPixelX x: Int, y: CGFloat) -> NSColor? {
        let row = Int(y * pixelScale)
        return rep.colorAt(x: x, y: row)?.usingColorSpace(.sRGB)
    }

    /// The x extent, in points, of the accent run one point above the row's
    /// bottom edge — inside the two-point strip, above the hairline's one.
    func accentRun() -> (minX: CGFloat, maxX: CGFloat)? {
        let y = rowHeight - 1
        let columns = (0..<rep.pixelsWide).filter { x in
            guard let c = color(atPixelX: x, y: y) else { return false }
            // The dark accent, 0x4F8DFF, against black, the hairline and the
            // secondary text — all of which are grey.
            return c.blueComponent > 0.9 && c.redComponent < 0.45 && c.greenComponent > 0.45
                && c.greenComponent < 0.65
        }
        guard let first = columns.first, let last = columns.last else { return nil }
        return (CGFloat(first) / pixelScale, CGFloat(last + 1) / pixelScale)
    }

    /// The x extent, in points, of the last run of ink across the row's middle
    /// band: the close glyph.
    func trailingInkRun() -> (minX: CGFloat, maxX: CGFloat)? {
        let band = stride(from: rowHeight * 0.25, through: rowHeight * 0.7, by: 1 / pixelScale)
        func inked(_ x: Int) -> Bool {
            band.contains { y in
                guard let c = color(atPixelX: x, y: y) else { return false }
                return c.redComponent + c.greenComponent + c.blueComponent > 0.3
            }
        }
        guard let last = (0..<rep.pixelsWide).reversed().first(where: inked) else { return nil }
        var first = last
        while first > 0, inked(first - 1) { first -= 1 }
        return (CGFloat(first) / pixelScale, CGFloat(last + 1) / pixelScale)
    }
}
#endif
