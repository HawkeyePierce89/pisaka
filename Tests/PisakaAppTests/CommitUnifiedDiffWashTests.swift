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
/// neither. The pane-width case runs in both appearances, one render each, the
/// light one on a white ground against light swatches. The overflow case scrolls the hosted `NSScrollView` to its far right
/// before rendering. Every render holds that scroll view's `scrollerStyle` —
/// `.overlay`, or `.legacy` once the legacy-scroller case asks for it — and
/// re-applies it after every settle, so no case depends on the machine's
/// scroll-bar setting or touches a preference. Left to the machine, macOS 26
/// (measured on its hosted image) resolved the style to legacy: beside the
/// overflowing diff it tiled a 17-point vertical scroller, the clip view ended
/// at 583 points, and the column at 596 read the scroller's strip — which
/// draws nothing into the cached bitmap — instead of the content, whose wash
/// did reach the clip view's last column. Held at overlay, the clip view is
/// the whole pane on every OS, so the column stays 4 points inside the edge.
/// Every capture also hides the scrollers for its own duration: a scroller is
/// chrome over the content, not its wash, and hiding triggers no retile.
///
/// **A failed read explains itself.** When the trailing-edge read finds no
/// wash, its message carries the render's geometry — the scrollers' style,
/// frames and visibility, the clip view's bounds right after the scroll and
/// after settle, the document frame, the bitmap's scale — and the bitmap it
/// read is attached to the result as `trailing-edge-<test>.png`. Both stay
/// permanently, so a failure seen only on CI's OS is diagnosable from that
/// run's log and `PisakaAppTests-xcresult` artifact alone, with no round trip.
/// Nothing of it is built while the read passes, and
/// `testTheTrailingEdgeDiagnosisReportsTheScrollersAndTheClipGeometry` keeps
/// it from printing nothing.
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
///
/// **Vertical alignment.** A one-row diff, hosted without its header rows, must
/// paint its wash from the pane's top edge (within the 2-point padding); before
/// the content's minimum height was the visible height it began 141 points
/// down, centred — and `.defaultScrollAnchor(.topLeading)` cured that on macOS
/// 26 only, and left macOS 15 at the same 141. The placeholder must stay
/// centred about the pane's middle.
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

    /// In both appearances, one render each: the light washes are compared
    /// against light swatches on the light render's white ground.
    func testShortChangedLinesAreWashedToThePanesTrailingEdge() throws {
        for appearance in ChromeAppearance.allCases {
            let render = try DiffRender(lines: Self.short, appearance: appearance, scrollToTrailingEdge: false)
            addTeardownBlock { @MainActor in render.window.close() }
            // The fill comes from the pane's width, not from a wider guess: a diff
            // that does not overflow does not scroll.
            let contentWidth = try XCTUnwrap(render.contentWidth, "no hosted scroll view")
            XCTAssertEqual(contentWidth, render.width, accuracy: 0.5, "the content is not the pane's width, \(appearance)")
            try assertWashedAtTrailingEdge(render)
        }
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

    // MARK: - Vertical alignment

    /// A diff shorter than its pane starts at the pane's top: one added row, no
    /// header rows, so the first thing painted is that row's wash, and it begins
    /// within the content's 2-point vertical padding of the top edge. A
    /// two-axis `ScrollView` centres content shorter than its viewport, which
    /// put a one-line diff in the middle of the 300-point pane; the content's
    /// measured minimum height leaves nothing shorter than the viewport.
    func testAShortDiffStartsAtThePanesTop() throws {
        let line = UnifiedDiffLine(kind: .added, text: "new", oldNumber: nil, newNumber: 1, unitIndex: 0)
        let render = try DiffRender(lines: [line], headers: false, scrollToTrailingEdge: false)
        addTeardownBlock { @MainActor in render.window.close() }
        let added = try XCTUnwrap(
            render.extent(of: .diffAddedBackground, atX: render.width - 4), "the added line is not washed"
        )
        XCTAssertLessThan(added.maxY - added.minY, 100, "the wash fills the pane — the case is not exercised")
        XCTAssertLessThanOrEqual(added.minY, 2.5, "the diff does not start at the pane's top")
    }

    /// The placeholder is a separate view and keeps its centred layout: its
    /// glyph and sentence sit about the pane's vertical middle.
    func testThePlaceholderStaysCentredVertically() throws {
        let render = try DiffRender(lines: [], scrollToTrailingEdge: false)
        addTeardownBlock { @MainActor in render.window.close() }
        try render.update { $0.wholeOnlyMessage = "Committed as a whole." }
        let ink = try XCTUnwrap(render.inkExtent(atX: render.width / 2), "the placeholder draws nothing")
        XCTAssertGreaterThan(ink.minY, 60, "the placeholder is pinned to the top")
        XCTAssertEqual((ink.minY + ink.maxY) / 2, 150, accuracy: 20, "the placeholder is not centred vertically")
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

    // MARK: - Failure diagnosis

    /// The diagnosis a failed trailing-edge read prints is not vacuous: on an
    /// unscrolled render it finds the hosted scroll view, reports the vertical
    /// scroller either way, and carries the clip view's bounds and the
    /// document's frame.
    func testTheTrailingEdgeDiagnosisReportsTheScrollersAndTheClipGeometry() throws {
        let render = try DiffRender(lines: Self.short, scrollToTrailingEdge: false)
        addTeardownBlock { @MainActor in render.window.close() }
        let diagnosis = render.diagnosis(atX: render.width - 4)
        XCTAssertTrue(
            diagnosis.contains("vertical scroller: frame in host ") || diagnosis.contains("no vertical scroller"),
            "the diagnosis does not report the vertical scroller:\n\(diagnosis)"
        )
        for expected in [
            "scroll view: scrollerStyle ",
            "clip bounds right after the scroll: none (not scrolled), after settle: ",
            "document frame ",
        ] {
            XCTAssertTrue(diagnosis.contains(expected), "the diagnosis lacks \"\(expected)\":\n\(diagnosis)")
        }
    }

    /// The removed and added rows are washed in a column just inside the
    /// trailing edge, in that order, and the context row under them is not.
    /// Should either wash be missing, the bitmap read is attached to the result
    /// and the message carries the render's geometry (`DiffRender.diagnosis`).
    private func assertWashedAtTrailingEdge(
        _ render: DiffRender, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let x = render.width - 4
        let removedExtent = render.extent(of: .diffRemovedBackground, atX: x)
        let addedExtent = render.extent(of: .diffAddedBackground, atX: x)
        if removedExtent == nil || addedExtent == nil, let png = render.pngData() {
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "trailing-edge-\(testMethodName).png"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let removed = try XCTUnwrap(
            removedExtent,
            "the removed line is not washed at the trailing edge\n\(render.diagnosis(atX: x))", file: file, line: line
        )
        let added = try XCTUnwrap(
            addedExtent,
            "the added line is not washed at the trailing edge\n\(render.diagnosis(atX: x))", file: file, line: line
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

    /// The running test's method name, out of XCTest's `-[Class method]`.
    private var testMethodName: String {
        String(name.split(separator: " ").last?.dropLast() ?? Substring(name))
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
    /// Whether the file and hunk header rows are drawn above the lines.
    let headers: Bool

    init(lines: [UnifiedDiffLine], fontSize: Double, headers: Bool = true) {
        self.lines = lines
        self.fontSize = fontSize
        self.headers = headers
    }
}

private struct DiffHost: View {
    @ObservedObject var input: DiffInput

    var body: some View {
        CommitUnifiedDiffView(
            rows: input.headers
                ? CommitUnifiedDiffWashTests.displayRows(input.lines) : input.lines.map { .line($0) },
            selectedUnits: [0],
            wholeOnlyMessage: input.wholeOnlyMessage, fontSize: input.fontSize
        )
    }
}

/// The diff hosted in a borderless 600 × 300 window (`HostedRender`), on a
/// black ground in dark and a white one in light.
@MainActor
private final class DiffRender {
    let width: CGFloat = 600
    let input: DiffInput
    let appearance: ChromeAppearance
    private let ground: Color
    private let render: HostedRender
    var window: NSWindow { render.window }
    private(set) var scrolledBy: CGFloat = 0
    /// The clip view's bounds right after the last programmatic scroll, before
    /// the layout settled; `nil` if the render was never scrolled.
    private var clipBoundsAfterScroll: CGRect?
    /// The scroller style forced onto the hosted scroll view and re-applied
    /// after every settle: `.overlay` from the start, `.legacy` once the legacy
    /// case asks for it.
    private var scrollerStyle: NSScroller.Style = .overlay

    init(
        lines: [UnifiedDiffLine], fontSize: Double = 13, appearance: ChromeAppearance = .dark,
        headers: Bool = true, scrollToTrailingEdge: Bool
    ) throws {
        input = DiffInput(lines: lines, fontSize: fontSize, headers: headers)
        self.appearance = appearance
        ground = appearance == .dark ? .black : .white
        let root = DiffHost(input: input)
            .frame(width: width, height: 300)
            .environment(\.chromeTheme, ChromeTheme(appearance))
            .background(ground)
        render = try HostedRender(size: CGSize(width: width, height: 300), root: root)
        settleHoldingScrollerStyle()
        try capture()
        if scrollToTrailingEdge { try self.scrollToTrailingEdge() }
    }

    /// The hosted scroll view's document width, or `nil` if none is found.
    var contentWidth: CGFloat? { Self.scrollView(in: render.host)?.documentView?.frame.width }

    /// The hosted scroll view's clip width — the pane less any legacy scroller.
    var visibleWidth: CGFloat? { Self.scrollView(in: render.host)?.contentView.bounds.width }

    /// Applies `change` to the hosted input and lets the layout settle.
    func update(file: StaticString = #filePath, line: UInt = #line, _ change: (DiffInput) -> Void) throws {
        change(input)
        settleHoldingScrollerStyle(file: file, line: line)
        try capture()
    }

    /// Holds the hosted scroll view at `.legacy` from now on and lets the
    /// layout settle, so the clip view shrinks by the vertical scroller's width
    /// and `VisibleSizeProbe` reports it. The case's guard on the visible width
    /// catches a style that did not hold.
    func forceLegacyScrollers() throws {
        scrollerStyle = .legacy
        settleHoldingScrollerStyle()
        try capture()
    }

    /// Sets the hosted scroll view's scroller style to the held one and lets
    /// the layout settle. Should the hosting framework's own update pass reset
    /// the style, it is applied again and settled once more.
    ///
    /// Every render is held at `.overlay` unless the legacy case asks
    /// otherwise, because the trailing-edge read samples a column 4 points
    /// inside the pane: left to the machine, a runner whose preferred style is
    /// legacy (measured on macOS 26) tiled a 17-point vertical scroller beside
    /// an overflowing diff, the clip view ended at 583 points and the sampled
    /// column lay in the scroller's strip — never the content. With overlay
    /// scrollers the clip view is the whole pane on every machine, which is the
    /// visible trailing edge the contract names.
    private func settleHoldingScrollerStyle(file: StaticString = #filePath, line: UInt = #line) {
        guard let scroll = Self.scrollView(in: render.host) else {
            render.settle(file: file, line: line)
            return
        }
        scroll.scrollerStyle = scrollerStyle
        render.settle(file: file, line: line)
        if scroll.scrollerStyle != scrollerStyle {
            scroll.scrollerStyle = scrollerStyle
            render.settle(file: file, line: line)
        }
    }

    func scrollToTrailingEdge() throws {
        guard let scroll = Self.scrollView(in: render.host), let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let x = max(0, document.frame.width - clip.bounds.width)
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
        scroll.reflectScrolledClipView(clip)
        scrolledBy = clip.bounds.origin.x
        clipBoundsAfterScroll = clip.bounds
        settleHoldingScrollerStyle()
        try capture()
    }

    /// Re-renders the bitmap with every `NSScroller` of the hosted scroll view
    /// hidden for the capture alone, each restored to its own `isHidden`
    /// afterwards — the one capture every read of this render goes through. A
    /// scroller is chrome drawn over the content, not the content's wash: an
    /// overlay scroller a programmatic scroll flashes sits exactly over the
    /// sampled column, for as long as the system keeps it shown. Hiding a view
    /// triggers no retile, so the clip view's width — and the legacy case's —
    /// is the one the layout settled at.
    private func capture() throws {
        let scrollers = Self.scrollView(in: render.host).map(Self.scrollers(in:)) ?? []
        let wasHidden = scrollers.map(\.isHidden)
        for scroller in scrollers { scroller.isHidden = true }
        defer { for (scroller, hidden) in zip(scrollers, wasHidden) { scroller.isHidden = hidden } }
        try render.capture()
    }

    /// The bitmap last captured, as PNG.
    func pngData() -> Data? { render.pngData() }

    // MARK: Failure diagnosis

    /// The render's geometry, for the message of a failed read in column `x`:
    /// the hosted scroll view's scroller configuration, each scroller's frame
    /// (in the host's coordinates) and visibility, the clip view's bounds right
    /// after the last scroll and now, the document view's frame and the
    /// bitmap's scale. Built only when a read fails — a passing test pays
    /// nothing for it.
    func diagnosis(atX x: CGFloat) -> String {
        var lines = ["diagnosis of the read at x = \(x) in a \(width)-point pane, pixelScale \(render.pixelScale)"]
        if let scroll = Self.scrollView(in: render.host) {
            let style: String
            switch scroll.scrollerStyle {
            case .overlay: style = "overlay"
            case .legacy: style = "legacy"
            @unknown default: style = "unknown (\(scroll.scrollerStyle.rawValue))"
            }
            lines.append(
                "scroll view: scrollerStyle \(style), hasVerticalScroller \(scroll.hasVerticalScroller), "
                    + "hasHorizontalScroller \(scroll.hasHorizontalScroller), autohidesScrollers \(scroll.autohidesScrollers)"
            )
            for (axis, scroller) in [("vertical", scroll.verticalScroller), ("horizontal", scroll.horizontalScroller)] {
                lines.append(scroller.map { "\(axis) scroller: " + describe($0) } ?? "no \(axis) scroller")
            }
            let subviewScrollers = Self.scrollers(in: scroll)
            lines.append("NSScrollers among the scroll view's subviews: \(subviewScrollers.count)")
            lines += subviewScrollers.map { "  \(type(of: $0)): " + describe($0) }
            let clip = scroll.contentView
            lines.append(
                "clip bounds right after the scroll: "
                    + (clipBoundsAfterScroll.map { "\($0)" } ?? "none (not scrolled)") + ", after settle: \(clip.bounds)"
            )
            lines.append(
                scroll.documentView.map { "document frame \($0.frame), isFlipped \($0.isFlipped)" } ?? "no document view"
            )
        } else {
            lines.append("no hosted scroll view")
        }
        return lines.joined(separator: "\n")
    }

    /// `scroller`'s frame in the host's coordinates, its visibility and its knob.
    private func describe(_ scroller: NSScroller) -> String {
        let frame = scroller.convert(scroller.bounds, to: render.host)
        let opacity = scroller.layer.map { "\($0.opacity)" } ?? "no layer"
        return "frame in host \(frame), isHidden \(scroller.isHidden), alphaValue \(scroller.alphaValue), "
            + "layer opacity \(opacity), knobProportion \(scroller.knobProportion), doubleValue \(scroller.doubleValue)"
    }

    /// Every `NSScroller` in `view`'s subtree, `view` itself excluded.
    private static func scrollers(in view: NSView) -> [NSScroller] {
        view.subviews.flatMap { subview in
            (subview as? NSScroller).map { [$0] + scrollers(in: $0) } ?? scrollers(in: subview)
        }
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let found = scrollView(in: subview) { return found }
        }
        return nil
    }

    // The wash roles are translucent, so they are compared on the same ground
    // the diff is hosted on, against a swatch of the render's own appearance.

    func matches(_ role: ChromeColorRole, atX x: CGFloat, y: CGFloat) -> Bool {
        render.matches(role, atX: x, y: y, ground: ground, appearance: appearance)
    }

    func extent(of role: ChromeColorRole, atX x: CGFloat) -> (minY: CGFloat, maxY: CGFloat)? {
        render.extent(of: role, atX: x, ground: ground, appearance: appearance)
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

    /// The vertical extent of anything drawn brighter than the dark render's
    /// black ground in column `x`.
    func inkExtent(atX x: CGFloat) -> (minY: CGFloat, maxY: CGFloat)? {
        render.extent(atX: x) { color in
            guard let color else { return false }
            return max(color.redComponent, color.greenComponent, color.blueComponent) > 0.15
        }
    }
}
#endif
