#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The commit dialog's unified diff, hosted in a real window and read off a
/// rendered bitmap.
///
/// **The bug.** A short added or removed line's wash stopped where its text
/// ended. The rows sit in a `LazyVStack` inside a two-axis `ScrollView`, whose
/// horizontal axis proposes no width, so each row's `maxWidth: .infinity`
/// resolved to the content's own width and the `.background` wash followed it.
/// A second cause hid behind the first: a `LazyVStack` takes its width from its
/// first row, not its widest, so an overflowing line did not widen the content
/// either. Measured in this harness on the view as it was, the content was 161
/// points wide in a 600-point pane — with or without a line far wider than the
/// pane present — and neither diff scrolled horizontally.
///
/// **The rule now.** The scrolled content is as wide as the larger of the
/// pane's measured visible width and the widest realized row's natural width,
/// and every row fills it, so a wash reaches the pane's trailing edge — and,
/// when one line overflows, the trailing edge of the widest row, which is where
/// the pane's visible edge sits once it is scrolled all the way right. Verified
/// by mutation: with only the pane's width applied, the overflowing case stayed
/// 600 points wide and did not scroll; with neither, both cases fail.
///
/// **How it is measured.** A column a few points inside the window's trailing
/// edge is scanned for the `diffRemovedBackground` and `diffAddedBackground`
/// runs, each compared against a swatch of the same role rendered through the
/// same pipeline (the cached bitmap carries a colour-space conversion the
/// palette's raw values do not). The context row directly below them must carry
/// neither. The overflow case scrolls the hosted `NSScrollView` to its far right
/// before rendering.
@MainActor
final class CommitUnifiedDiffWashTests: XCTestCase {

    private static let short: [UnifiedDiffLine] = [
        UnifiedDiffLine(kind: .removed, text: "old", oldNumber: 1, newNumber: nil, unitIndex: 0),
        UnifiedDiffLine(kind: .added, text: "new", oldNumber: nil, newNumber: 1, unitIndex: 0),
        UnifiedDiffLine(kind: .context, text: "same", oldNumber: 2, newNumber: 2, unitIndex: nil),
    ]

    private static let overflowing: [UnifiedDiffLine] = short + [
        UnifiedDiffLine(
            kind: .context, text: String(repeating: "wide context line ", count: 12),
            oldNumber: 3, newNumber: 3, unitIndex: nil
        ),
    ]

    func testShortChangedLinesAreWashedToThePanesTrailingEdge() throws {
        let render = try DiffRender(lines: Self.short, scrollToTrailingEdge: false)
        addTeardownBlock { @MainActor in render.window.close() }
        // The fill comes from the pane's width, not from a wider guess: a diff
        // that does not overflow does not scroll.
        let contentWidth = try XCTUnwrap(render.contentWidth, "no hosted scroll view")
        XCTAssertEqual(contentWidth, render.width, accuracy: 0.5, "the content is not the pane's width")
        try assertWashedAtTrailingEdge(render)
    }

    func testShortChangedLinesAreWashedAtTheVisibleTrailingEdgeAfterScrollingAnOverflowingDiff() throws {
        let render = try DiffRender(lines: Self.overflowing, scrollToTrailingEdge: true)
        addTeardownBlock { @MainActor in render.window.close() }
        XCTAssertGreaterThan(render.scrolledBy, 0, "the overflowing diff did not scroll horizontally")
        try assertWashedAtTrailingEdge(render)
    }

    /// The removed and added rows are washed in a column just inside the
    /// trailing edge, in that order, and the context row under them is not.
    private func assertWashedAtTrailingEdge(
        _ render: DiffRender, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let x = render.width - 4
        let removed = try XCTUnwrap(
            render.extent(of: .diffRemovedBackground, atX: x),
            "the removed line is not washed at the trailing edge", file: file, line: line
        )
        let added = try XCTUnwrap(
            render.extent(of: .diffAddedBackground, atX: x),
            "the added line is not washed at the trailing edge", file: file, line: line
        )
        XCTAssertLessThan(removed.maxY, added.minY + 1, "the removed row is not above the added one", file: file, line: line)

        let contextY = added.maxY + (added.maxY - added.minY) / 2
        for role: ChromeColorRole in [.diffAddedBackground, .diffRemovedBackground] {
            XCTAssertFalse(
                render.matches(role, atX: x, y: contextY),
                "the context line is washed \(role.rawValue)", file: file, line: line
            )
            XCTAssertFalse(
                render.matches(role, atX: 40, y: contextY),
                "the context line is washed \(role.rawValue) near its leading edge", file: file, line: line
            )
        }
    }
}

/// The diff hosted in a borderless 600 × 300 window on a black ground, rendered
/// to a bitmap once its layout has settled.
@MainActor
private final class DiffRender {
    let window: NSWindow
    let width: CGFloat = 600
    private let height: CGFloat = 300
    private(set) var scrolledBy: CGFloat = 0
    /// The hosted scroll view's document width, or `nil` if none was found.
    private(set) var contentWidth: CGFloat?
    private var rep: NSBitmapImageRep
    private let pixelScale: CGFloat

    init(lines: [UnifiedDiffLine], scrollToTrailingEdge: Bool) throws {
        let root = CommitUnifiedDiffView(lines: lines, selectedUnits: [0], wholeOnlyMessage: nil, fontSize: 13)
            .frame(width: width, height: height)
            .environment(\.chromeTheme, ChromeTheme(.dark))
            .background(Color.black)
        let host = NSHostingView(rootView: root)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        Self.settle(host)
        contentWidth = Self.scrollView(in: host)?.documentView?.frame.width

        if scrollToTrailingEdge, let scroll = Self.scrollView(in: host), let document = scroll.documentView {
            let clip = scroll.contentView
            let x = max(0, document.frame.width - clip.bounds.width)
            clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
            scroll.reflectScrolledClipView(clip)
            scrolledBy = clip.bounds.origin.x
            Self.settle(host)
        }

        rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        pixelScale = CGFloat(rep.pixelsWide) / host.bounds.width
    }

    private static func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let found = scrollView(in: subview) { return found }
        }
        return nil
    }

    private func color(atX x: CGFloat, y: CGFloat) -> NSColor? {
        rep.colorAt(x: Int(x * pixelScale), y: Int(y * pixelScale))?.usingColorSpace(.sRGB)
    }

    /// Whether the pixel at (`x`, `y`) points is `role`'s dark value as a swatch
    /// of that role renders through this same pipeline.
    func matches(_ role: ChromeColorRole, atX x: CGFloat, y: CGFloat) -> Bool {
        guard let c = color(atX: x, y: y), let expected = Self.swatch(role) else { return false }
        return abs(c.redComponent - expected.redComponent) < 0.02
            && abs(c.greenComponent - expected.greenComponent) < 0.02
            && abs(c.blueComponent - expected.blueComponent) < 0.02
    }

    /// The vertical extent, in points, of the pixels painted `role` in column `x`.
    func extent(of role: ChromeColorRole, atX x: CGFloat) -> (minY: CGFloat, maxY: CGFloat)? {
        let rows = stride(from: 0, to: height, by: 1 / pixelScale).filter { matches(role, atX: x, y: $0) }
        guard let first = rows.first, let last = rows.last else { return nil }
        return (first, last + 1 / pixelScale)
    }

    private static var swatches: [ChromeColorRole: NSColor] = [:]

    private static func swatch(_ role: ChromeColorRole) -> NSColor? {
        if let cached = swatches[role] { return cached }
        // The wash roles are translucent, so the swatch sits on the same black
        // ground the diff is hosted on.
        let host = NSHostingView(rootView: Rectangle().fill(ChromeTheme(.dark).color(role))
            .frame(width: 4, height: 4)
            .background(Color.black))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 4, height: 4),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let value = rep.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB)
        swatches[role] = value
        return value
    }
}
#endif
