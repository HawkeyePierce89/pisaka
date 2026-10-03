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
/// before rendering, and the legacy-scroller case sets that scroll view's
/// `scrollerStyle` directly, so no case depends on the machine's scroll-bar
/// setting or touches a preference.
///
/// **Header rows and the text tint.** Every diff is hosted as the panel draws
/// it, under its `---`/`+++` file headers and an `@@` hunk header, which must
/// carry no wash. An added line's text draws in `statusGreen` and a removed
/// line's in `statusRed` on top of the wash; a context line's text in neither.
/// The tint is read off one render as a channel's *dominance* — how far a
/// pixel's red (or green) rises above its other two channels — taken at the
/// band's strongest pixel. A grey stroke has none and the wash a little; a
/// stroke drawn in the tint reaches most of the tint's own dominance, read off
/// its swatch (the dark `statusGreen` rises only about 0.14 above its red, so
/// a fixed margin would not separate it from the wash). The font
/// is enlarged so a stroke's core is covered at either backing scale.
///
/// **Live updates.** The content's width is measured state, so the cases that
/// change the hosted diff in place — a file switch, a placeholder in between,
/// a font-size change — compare the width it settles at against a fresh render
/// of the same end state.
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

    /// Short lines enough to overflow the pane vertically, so a legacy vertical
    /// scroller is shown.
    private static let tall: [UnifiedDiffLine] = short + (3...60).map {
        UnifiedDiffLine(kind: .context, text: "line", oldNumber: $0, newNumber: $0, unitIndex: nil)
    }

    /// A wider overflowing diff whose line at index 3 is exactly as long as
    /// `overflowing`'s — the row whose width survives the switch.
    private static let wider: [UnifiedDiffLine] = overflowing + [
        UnifiedDiffLine(
            kind: .context, text: String(repeating: "wider context line ", count: 24),
            oldNumber: 4, newNumber: 4, unitIndex: nil
        ),
    ]

    /// The rows the panel draws for `lines`: the two file headers and one hunk
    /// header, then the lines.
    static func displayRows(_ lines: [UnifiedDiffLine]) -> [UnifiedDiffDisplayRow] {
        [.fileHeader("--- a/file.txt"), .fileHeader("+++ b/file.txt"), .hunkHeader("@@ -1,3 +1,3 @@")]
            + lines.map { .line($0) }
    }

    func testChangedLinesTextIsTintedOnTopOfItsWashAndContextTextIsNot() throws {
        let render = try DiffRender(lines: Self.short, fontSize: 28, scrollToTrailingEdge: false)
        addTeardownBlock { @MainActor in render.window.close() }
        let x = render.width - 4
        let removed = try XCTUnwrap(render.extent(of: .diffRemovedBackground, atX: x), "the removed line is not washed")
        let added = try XCTUnwrap(render.extent(of: .diffAddedBackground, atX: x), "the added line is not washed")
        let context = (minY: added.maxY, maxY: added.maxY + (added.maxY - added.minY))
        let removedWash = try XCTUnwrap(render.color(atX: x, y: (removed.minY + removed.maxY) / 2))
        let addedWash = try XCTUnwrap(render.color(atX: x, y: (added.minY + added.maxY) / 2))

        let red = try XCTUnwrap(HostedRender.swatch(.statusRed, ground: nil))
        let green = try XCTUnwrap(HostedRender.swatch(.statusGreen, ground: nil))
        XCTAssertGreaterThan(
            DiffRender.dominance(.green, of: green), DiffRender.dominance(.green, of: addedWash) * 3,
            "the tint does not stand out from its wash — the case is not exercised"
        )
        XCTAssertGreaterThan(
            render.dominance(.red, in: removed),
            max(DiffRender.dominance(.red, of: removedWash), DiffRender.dominance(.red, of: red) * 0.75),
            "the removed line's text is not tinted statusRed"
        )
        XCTAssertGreaterThan(
            render.dominance(.green, in: added),
            max(DiffRender.dominance(.green, of: addedWash), DiffRender.dominance(.green, of: green) * 0.75),
            "the added line's text is not tinted statusGreen"
        )
        XCTAssertLessThan(render.dominance(.green, in: removed), 0.05, "the removed line's text is green")
        XCTAssertLessThan(render.dominance(.red, in: added), 0.05, "the added line's text is red")
        for channel in [DiffRender.Channel.red, .green] {
            XCTAssertLessThan(render.dominance(channel, in: context), 0.05, "the context line's text is tinted \(channel)")
        }
    }

    /// The header rows above the first line carry no wash and no checkbox: the
    /// band above the removed row holds no wash pixel at the trailing edge and
    /// no accent pixel (the checked checkbox's colour) anywhere, and its text is
    /// drawn.
    func testHeaderRowsAreDrawnUnwashedAndWithoutACheckbox() throws {
        let render = try DiffRender(lines: Self.short, scrollToTrailingEdge: false)
        addTeardownBlock { @MainActor in render.window.close() }
        let x = render.width - 4
        let removed = try XCTUnwrap(render.extent(of: .diffRemovedBackground, atX: x), "the removed line is not washed")
        XCTAssertGreaterThan(removed.minY, 30, "no header rows above the first line")
        let headers = (minY: CGFloat(2), maxY: removed.minY - 1)
        for role: ChromeColorRole in [.diffAddedBackground, .diffRemovedBackground] {
            XCTAssertFalse(render.matches(role, atX: x, y: headers.maxY / 2), "a header row is washed \(role.rawValue)")
        }
        // The checked checkbox is the one blue thing a row draws.
        XCTAssertLessThan(render.dominance(.blue, in: headers), 0.05, "a header row draws a checkbox")
        XCTAssertGreaterThan(render.dominance(.blue, in: removed), 0.15, "the removed line's checkbox is not drawn")
        XCTAssertGreaterThan(render.brightest(in: headers), 0.3, "the header text is not drawn")
    }

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

    /// With legacy scroll bars ("Show scroll bars: Always") the vertical
    /// scroller takes part of the pane, so the content is as wide as the clip
    /// view, not as the pane: a diff whose lines all fit still does not scroll
    /// horizontally. The style is forced onto the hosted scroll view itself and
    /// re-applied after every settle, so the case depends on neither the
    /// machine's scroll-bar setting nor its input devices, and touches no
    /// preference. Verified by mutation: measured from the pane's frame — or
    /// from SwiftUI's `containerRelativeFrame`, which reports the same 600
    /// points — the content is wider than the clip view.
    func testShortChangedLinesDoNotScrollWithLegacyScrollers() throws {
        let render = try DiffRender(lines: Self.tall, scrollToTrailingEdge: false)
        addTeardownBlock { @MainActor in render.window.close() }
        try render.forceLegacyScrollers()
        let visible = try XCTUnwrap(render.visibleWidth, "no hosted scroll view")
        XCTAssertLessThan(visible, render.width - 1, "the scrollers are not legacy — the case is not exercised")
        let contentWidth = try XCTUnwrap(render.contentWidth, "no hosted scroll view")
        XCTAssertEqual(contentWidth, visible, accuracy: 0.5, "the content is wider than the visible pane")
    }

    // MARK: - Live updates

    /// Switching to a narrower diff whose widest row keeps its index and width
    /// leaves the content exactly as wide as a fresh render of that diff: the
    /// surviving row is measured again rather than forgotten, so the overflowing
    /// line stays in scroll reach, and the wider diff's width does not linger.
    func testSwitchingFilesMeasuresTheNewDiffsWidestRow() throws {
        let expected = try freshContentWidth(Self.overflowing)
        XCTAssertGreaterThan(expected, 600, "the narrower diff does not overflow — the case is not exercised")
        let render = try DiffRender(lines: Self.wider, scrollToTrailingEdge: false)
        addTeardownBlock { @MainActor in render.window.close() }
        try render.update { $0.lines = Self.overflowing }
        let contentWidth = try XCTUnwrap(render.contentWidth, "no hosted scroll view")
        XCTAssertEqual(contentWidth, expected, accuracy: 0.5, "the content is not the new diff's widest row")
        try render.scrollToTrailingEdge()
        try assertWashedAtTrailingEdge(render)
    }

    /// A file shown as a placeholder between two diffs does not carry the first
    /// diff's widest row into the second.
    func testADiffAfterAPlaceholderForgetsTheEarlierWidestRow() throws {
        let render = try DiffRender(lines: Self.wider, scrollToTrailingEdge: false)
        addTeardownBlock { @MainActor in render.window.close() }
        try render.update { $0.wholeOnlyMessage = "Committed as a whole." }
        try render.update {
            $0.wholeOnlyMessage = nil
            $0.lines = Self.short
        }
        let contentWidth = try XCTUnwrap(render.contentWidth, "no hosted scroll view")
        XCTAssertEqual(contentWidth, render.width, accuracy: 0.5, "the earlier diff's widest row lingered")
        try assertWashedAtTrailingEdge(render)
    }

    /// Shrinking the code font narrows the content to the rows' new width.
    func testAFontSizeChangeMeasuresTheRowsAgain() throws {
        let expected = try freshContentWidth(Self.wider)
        let render = try DiffRender(lines: Self.wider, fontSize: 20, scrollToTrailingEdge: false)
        addTeardownBlock { @MainActor in render.window.close() }
        let zoomed = try XCTUnwrap(render.contentWidth, "no hosted scroll view")
        XCTAssertGreaterThan(zoomed, expected + 1, "the larger font did not widen the content — the case is not exercised")
        try render.update { $0.fontSize = 13 }
        let contentWidth = try XCTUnwrap(render.contentWidth, "no hosted scroll view")
        XCTAssertEqual(contentWidth, expected, accuracy: 0.5, "the larger font's width lingered")
    }

    /// The content width of `lines` rendered fresh at the default font size.
    private func freshContentWidth(_ lines: [UnifiedDiffLine]) throws -> CGFloat {
        let render = try DiffRender(lines: lines, scrollToTrailingEdge: false)
        defer { render.window.close() }
        return try XCTUnwrap(render.contentWidth, "no hosted scroll view")
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

/// What the hosted diff is drawing, changed in place by the live-update cases
/// so the view keeps its identity and state across the change — the way the
/// commit dialog switches files under one `CommitUnifiedDiffView`.
@MainActor
private final class DiffInput: ObservableObject {
    @Published var lines: [UnifiedDiffLine]
    @Published var wholeOnlyMessage: String?
    @Published var fontSize: Double

    init(lines: [UnifiedDiffLine], fontSize: Double) {
        self.lines = lines
        self.fontSize = fontSize
    }
}

private struct DiffHost: View {
    @ObservedObject var input: DiffInput

    var body: some View {
        CommitUnifiedDiffView(
            rows: CommitUnifiedDiffWashTests.displayRows(input.lines), selectedUnits: [0],
            wholeOnlyMessage: input.wholeOnlyMessage, fontSize: input.fontSize
        )
    }
}

/// The diff hosted in a borderless 600 × 300 window on a black ground
/// (`HostedRender`).
@MainActor
private final class DiffRender {
    let width: CGFloat = 600
    let input: DiffInput
    private let render: HostedRender
    var window: NSWindow { render.window }
    private(set) var scrolledBy: CGFloat = 0

    init(lines: [UnifiedDiffLine], fontSize: Double = 13, scrollToTrailingEdge: Bool) throws {
        input = DiffInput(lines: lines, fontSize: fontSize)
        let root = DiffHost(input: input)
            .frame(width: width, height: 300)
            .environment(\.chromeTheme, ChromeTheme(.dark))
            .background(Color.black)
        render = try HostedRender(size: CGSize(width: width, height: 300), root: root)
        if scrollToTrailingEdge { try self.scrollToTrailingEdge() }
    }

    /// The hosted scroll view's document width, or `nil` if none is found.
    var contentWidth: CGFloat? { Self.scrollView(in: render.host)?.documentView?.frame.width }

    /// The hosted scroll view's clip width — the pane less any legacy scroller.
    var visibleWidth: CGFloat? { Self.scrollView(in: render.host)?.contentView.bounds.width }

    /// Applies `change` to the hosted input and lets the layout settle.
    func update(file: StaticString = #filePath, line: UInt = #line, _ change: (DiffInput) -> Void) throws {
        change(input)
        render.settle(file: file, line: line)
        try render.capture()
    }

    /// Sets the hosted scroll view's scroller style to `.legacy` and lets the
    /// layout settle, so the clip view shrinks by the vertical scroller's width
    /// and `VisibleWidthProbe` reports it. Should the hosting framework's own
    /// update pass reset the style, it is applied again and settled once more;
    /// the case's guard on the visible width catches a style that still did not
    /// hold.
    func forceLegacyScrollers() throws {
        guard let scroll = Self.scrollView(in: render.host) else { return }
        scroll.scrollerStyle = .legacy
        render.settle()
        if scroll.scrollerStyle != .legacy {
            scroll.scrollerStyle = .legacy
            render.settle()
        }
        try render.capture()
    }

    func scrollToTrailingEdge() throws {
        guard let scroll = Self.scrollView(in: render.host), let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let x = max(0, document.frame.width - clip.bounds.width)
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
        scroll.reflectScrolledClipView(clip)
        scrolledBy = clip.bounds.origin.x
        render.settle()
        try render.capture()
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let found = scrollView(in: subview) { return found }
        }
        return nil
    }

    // The wash roles are translucent, so they are compared on the same black
    // ground the diff is hosted on.

    func matches(_ role: ChromeColorRole, atX x: CGFloat, y: CGFloat) -> Bool {
        render.matches(role, atX: x, y: y, ground: .black)
    }

    func extent(of role: ChromeColorRole, atX x: CGFloat) -> (minY: CGFloat, maxY: CGFloat)? {
        render.extent(of: role, atX: x, ground: .black)
    }

    enum Channel { case red, green, blue }

    /// How far `channel` rises above the larger of `color`'s other two.
    static func dominance(_ channel: Channel, of color: NSColor) -> CGFloat {
        let (r, g, b) = (color.redComponent, color.greenComponent, color.blueComponent)
        switch channel {
        case .red: return r - max(g, b)
        case .green: return g - max(r, b)
        case .blue: return b - max(r, g)
        }
    }

    /// The largest `dominance` of `channel` over the pixels inside the band,
    /// inset one point at each edge so a neighbouring row never leaks in.
    func dominance(_ channel: Channel, in band: (minY: CGFloat, maxY: CGFloat)) -> CGFloat {
        scan(band) { Self.dominance(channel, of: $0) }
    }

    /// The largest channel value over the pixels inside the band — whether
    /// anything brighter than the black ground is drawn there.
    func brightest(in band: (minY: CGFloat, maxY: CGFloat)) -> CGFloat {
        scan(band) { max($0.redComponent, $0.greenComponent, $0.blueComponent) }
    }

    /// The largest `measure` over every pixel inside the band, read off the one
    /// bitmap already captured — no window, view or bitmap per pixel.
    private func scan(_ band: (minY: CGFloat, maxY: CGFloat), _ measure: (NSColor) -> CGFloat) -> CGFloat {
        let step = 1 / render.pixelScale
        var best = -CGFloat.infinity
        for y in stride(from: band.minY + 1, to: band.maxY - 1, by: step) {
            autoreleasepool {
                for pixel in 0..<render.pixelsWide {
                    guard let color = render.color(atPixelX: pixel, y: y) else { continue }
                    best = max(best, measure(color))
                }
            }
        }
        return best
    }

    func color(atX x: CGFloat, y: CGFloat) -> NSColor? { render.color(atX: x, y: y) }
}
#endif
