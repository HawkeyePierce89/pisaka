#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The Welcome screen, hosted in a real window at interface scales 0.8, 1.5 and
/// 2.0 and measured off a rendered bitmap — once at the window's content
/// minimum and once at a large size per scale.
///
/// **The size.** The minimum is the window floor ContentView declares
/// (640 × 400, scaled) less the bottom bar, which stays below the Welcome
/// screen: what is left is the area the screen is actually given. The large
/// size is 1800 × 1100 points, wider than the content cap at every scale.
///
/// **What it pins.**
/// - *Nothing is drawn outside the frame.* The view is framed at its size in
///   the middle of a larger host whose margin is painted a colour no role
///   carries; every sampled point of that margin must still read that colour.
///   (The host is a whole number of points: a fractional host leaves its edge
///   row undrawn, which reads as ink in the margin.) Inside the frame, every
///   point off the `bgCanvas` ground lies within the content padding
///   horizontally and below it at the top — so no part of the content is cut
///   by the frame's sides. The trailing band a legacy scroller may occupy is
///   left out of that scan.
/// - *The columns stack or scroll rather than overlap.* Each column is a card
///   on the `bgPanel` ground; the cards are the panel-coloured regions of the
///   bitmap, found as connected components of a sampling grid (a card's text
///   leaves holes in its region, never a cut, because the card's padding rings
///   it). The actions card is the first in reading order and is never cut by
///   the frame. When the recents card is not on screen too, the columns are
///   stacked past the viewport: the scroll view is driven to its end and the
///   recents card found there, uncut, and moved into the document's
///   coordinates. Either way the two boxes are disjoint, side by side or one
///   above the other — and at the large size, side by side.
/// - *The hint is present with empty recents.* The view is given no recent
///   project, so the recents card carries its caption and, below it, the
///   hint: at least two separate bands of ink rows inside the card, where a
///   card holding its caption alone draws one.
///
/// **Why no accessibility query.** Headless, SwiftUI builds no accessibility
/// nodes for the hosted tree (`LocalChangesLayoutTests`), so the frames of the
/// rows cannot be read by name; the bitmap is what the screen shows.
@MainActor
final class WelcomeLayoutTests: XCTestCase {

    /// The margin around the framed view, in points.
    private let margin: CGFloat = 40
    /// The sampling grid's step, in points, for the card regions.
    private let gridStep: CGFloat = 2

    func testTheWelcomeScreenAtScalePointEight() throws {
        try assertWelcome(scale: 0.8)
    }

    func testTheWelcomeScreenAtScaleOnePointFive() throws {
        try assertWelcome(scale: 1.5)
    }

    func testTheWelcomeScreenAtScaleTwo() throws {
        try assertWelcome(scale: 2.0)
    }

    private func assertWelcome(scale: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let metrics = InterfaceMetrics(scale: scale)
        let minimum = CGSize(
            width: metrics.scaled(640),
            height: metrics.scaled(400) - metrics.scaled(ChromeGeometry.bottomBarHeight)
        )
        try assertWelcome(scale: scale, size: minimum, label: "minimum", file: file, line: line)
        try assertWelcome(scale: scale, size: CGSize(width: 1800, height: 1100), label: "large", file: file, line: line)
    }

    private func assertWelcome(
        scale: Double, size: CGSize, label: String, file: StaticString, line: UInt
    ) throws {
        let metrics = InterfaceMetrics(scale: scale)
        let theme = ChromeTheme(.dark)
        let context = "at scale \(scale), \(label) size"
        // The host is a whole number of points, or its edge row is left
        // undrawn; the view's frame is centred in it.
        let hostSize = CGSize(width: (size.width + 2 * margin).rounded(.up),
                              height: (size.height + 2 * margin).rounded(.up))
        let render = try HostedRender(
            size: hostSize,
            file: file, line: line,
            root: WelcomeView(recentProjects: { [] })
                .environment(\.interfaceMetrics, metrics)
                .environment(\.chromeTheme, theme)
                .frame(width: size.width, height: size.height)
                .frame(width: hostSize.width, height: hostSize.height)
                .background(Self.marginColor)
        )
        addTeardownBlock { @MainActor in render.window.close() }
        let frame = CGRect(x: (hostSize.width - size.width) / 2, y: (hostSize.height - size.height) / 2,
                           width: size.width, height: size.height)

        // Nothing outside the frame: the margin still reads the margin colour.
        let marginInk = marginPoints(around: frame, in: render).filter { !isMarginColor(render.color(atX: $0.x, y: $0.y)) }
        XCTAssertTrue(marginInk.isEmpty, "the Welcome screen drew outside its frame \(context): \(marginInk.prefix(5))",
                      file: file, line: line)

        // Inside the frame, the content keeps to its padding on both sides and
        // at the top.
        let padding = metrics.scaled(WelcomeLayout.contentPadding)
        let scrollerBand: CGFloat = 20
        let edge: CGFloat = 2
        let ink = try XCTUnwrap(
            inkBounds(in: render, rect: CGRect(x: frame.minX + edge, y: frame.minY + edge,
                                               width: frame.width - scrollerBand - edge,
                                               height: frame.height - edge)),
            "the Welcome screen drew nothing \(context)", file: file, line: line
        )
        XCTAssertGreaterThanOrEqual(ink.minX - frame.minX, padding - gridStep,
                                    "content cut or crowded at the leading side \(context)", file: file, line: line)
        XCTAssertLessThanOrEqual(ink.maxX - frame.minX, frame.width - padding + gridStep,
                                 "content cut or crowded at the trailing side \(context)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(ink.minY - frame.minY, padding - gridStep,
                                    "content cut or crowded at the top \(context)", file: file, line: line)

        // The two cards: both reachable, and disjoint in the scrolled
        // document — side by side, or one above the other.
        let top = panelRegions(in: render, rect: frame)
        let actions = try XCTUnwrap(top.first, "no actions card \(context)", file: file, line: line)
        XCTAssertLessThan(actions.maxY, frame.maxY - 1, "the actions card is cut by the frame \(context)",
                          file: file, line: line)
        var recents: CGRect
        var recentsRender = top
        if top.count >= 2 {
            recents = top[1]
        } else {
            // Stacked past the viewport: scroll to the bottom and find the
            // recents card there, in the document's coordinates.
            let offset = try scrollToBottom(render, file: file, line: line)
            XCTAssertGreaterThan(offset, 0, "only one card visible yet nothing to scroll \(context)",
                                 file: file, line: line)
            recentsRender = panelRegions(in: render, rect: frame)
            let last = try XCTUnwrap(recentsRender.last, "no recents card after scrolling \(context)",
                                     file: file, line: line)
            recents = last
            XCTAssertGreaterThan(recents.minY, frame.minY + 1, "the recents card is cut by the frame \(context)",
                                 file: file, line: line)
            recents.origin.y += offset
        }
        XCTAssertLessThanOrEqual(recentsRender.count, 2, "more than two cards \(context): \(recentsRender)",
                                 file: file, line: line)
        XCTAssertFalse(actions.intersects(recents), "the two columns overlap \(context): \(actions), \(recents)",
                       file: file, line: line)
        let sideBySide = actions.maxX <= recents.minX
        let stacked = actions.maxY <= recents.minY
        XCTAssertTrue(sideBySide || stacked,
                      "the columns neither stack nor sit side by side \(context): \(actions), \(recents)",
                      file: file, line: line)
        if label == "large" {
            XCTAssertTrue(sideBySide, "the columns should sit side by side \(context): \(actions), \(recents)",
                          file: file, line: line)
        }

        // The recents card holds the caption and the hint below it (sampled
        // in whichever render showed it).
        if top.count < 2 { recents.origin.y -= try XCTUnwrap(scrollOffset(render)) }
        let inset = metrics.scaled(WelcomeLayout.cardPadding) / 2
        let bands = inkRowBands(in: render, rect: recents.insetBy(dx: inset, dy: inset).intersection(frame))
        XCTAssertGreaterThanOrEqual(bands, 2, "the recents card shows no hint under its caption \(context)",
                                    file: file, line: line)
    }

    // MARK: - Scrolling

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(scrollView(in:)).first
    }

    /// The scroll view's current offset from the document's top, in points.
    private func scrollOffset(_ render: HostedRender) -> CGFloat? {
        guard let scroll = scrollView(in: render.host), let document = scroll.documentView else { return nil }
        let clip = scroll.contentView.bounds
        return document.isFlipped ? clip.minY : document.frame.height - clip.maxY
    }

    /// Scrolls the Welcome screen's scroll view to its end, re-renders, and
    /// returns the offset scrolled.
    private func scrollToBottom(_ render: HostedRender, file: StaticString, line: UInt) throws -> CGFloat {
        let scroll = try XCTUnwrap(scrollView(in: render.host), "the Welcome screen has no scroll view",
                                   file: file, line: line)
        let document = try XCTUnwrap(scroll.documentView, file: file, line: line)
        let clipHeight = scroll.contentView.bounds.height
        let target = document.isFlipped ? max(0, document.frame.height - clipHeight) : 0
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
        render.settle(file: file, line: line)
        try render.capture()
        return try XCTUnwrap(scrollOffset(render), file: file, line: line)
    }

    // MARK: - Sampling

    /// A colour no chrome role carries.
    private static let marginColor = Color(red: 1, green: 0, blue: 1)

    private func isMarginColor(_ color: NSColor?) -> Bool {
        guard let color else { return false }
        return color.redComponent > 0.8 && color.greenComponent < 0.4 && color.blueComponent > 0.8
    }

    /// Every grid point in the margin band around `frame`.
    private func marginPoints(around frame: CGRect, in render: HostedRender) -> [CGPoint] {
        let bounds = render.bounds
        var points: [CGPoint] = []
        for y in stride(from: 0, to: bounds.height, by: gridStep) {
            for x in stride(from: 0, to: bounds.width, by: gridStep)
            where !frame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: x, y: y)) {
                points.append(CGPoint(x: x, y: y))
            }
        }
        return points
    }

    private func close(_ color: NSColor?, _ expected: NSColor?, tolerance: CGFloat = 0.02) -> Bool {
        guard let color, let expected else { return false }
        return abs(color.redComponent - expected.redComponent) < tolerance
            && abs(color.greenComponent - expected.greenComponent) < tolerance
            && abs(color.blueComponent - expected.blueComponent) < tolerance
    }

    private var canvas: NSColor? { HostedRender.swatch(.bgCanvas, ground: nil) }
    private var panel: NSColor? { HostedRender.swatch(.bgPanel, ground: nil) }

    /// The bounding box, in points, of every grid point in `rect` off the
    /// `bgCanvas` ground.
    private func inkBounds(in render: HostedRender, rect: CGRect) -> CGRect? {
        var bounds: CGRect?
        for y in stride(from: rect.minY, to: rect.maxY, by: gridStep) {
            for x in stride(from: rect.minX, to: rect.maxX, by: gridStep)
            where !close(render.color(atX: x, y: y), canvas) {
                let point = CGRect(x: x, y: y, width: gridStep, height: gridStep)
                bounds = bounds.map { $0.union(point) } ?? point
            }
        }
        return bounds
    }

    /// The bounding boxes of the large `bgPanel` regions in `rect`, in reading
    /// order: the 4-connected components of the grid points painted
    /// `bgPanel`, keeping those at least 40 points on each side.
    private func panelRegions(in render: HostedRender, rect: CGRect) -> [CGRect] {
        let columns = Int(rect.width / gridStep)
        let rows = Int(rect.height / gridStep)
        var isPanel = [Bool](repeating: false, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let x = rect.minX + CGFloat(column) * gridStep
                let y = rect.minY + CGFloat(row) * gridStep
                isPanel[row * columns + column] = close(render.color(atX: x, y: y), panel)
            }
        }
        var seen = [Bool](repeating: false, count: columns * rows)
        var regions: [CGRect] = []
        for start in isPanel.indices where isPanel[start] && !seen[start] {
            var stack = [start]
            seen[start] = true
            var minColumn = columns, maxColumn = 0, minRow = rows, maxRow = 0
            while let index = stack.popLast() {
                let row = index / columns, column = index % columns
                minColumn = min(minColumn, column); maxColumn = max(maxColumn, column)
                minRow = min(minRow, row); maxRow = max(maxRow, row)
                let neighbours = [
                    column > 0 ? index - 1 : nil, column < columns - 1 ? index + 1 : nil,
                    row > 0 ? index - columns : nil, row < rows - 1 ? index + columns : nil,
                ].compactMap { $0 }
                for next in neighbours where isPanel[next] && !seen[next] {
                    seen[next] = true
                    stack.append(next)
                }
            }
            let region = CGRect(
                x: rect.minX + CGFloat(minColumn) * gridStep,
                y: rect.minY + CGFloat(minRow) * gridStep,
                width: CGFloat(maxColumn - minColumn + 1) * gridStep,
                height: CGFloat(maxRow - minRow + 1) * gridStep
            )
            if region.width >= 40 && region.height >= 40 { regions.append(region) }
        }
        return regions.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    /// How many separate bands of rows in `rect` hold any point off the
    /// `bgPanel` ground.
    private func inkRowBands(in render: HostedRender, rect: CGRect) -> Int {
        var bands = 0
        var inBand = false
        for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
            let inked = stride(from: rect.minX, to: rect.maxX, by: 1).contains {
                !close(render.color(atX: $0, y: y), panel, tolerance: 0.05)
            }
            if inked && !inBand { bands += 1 }
            inBand = inked
        }
        return bands
    }
}
#endif
