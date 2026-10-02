#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The shared themed field, hosted in a real window and measured off a
/// rendered bitmap.
///
/// **The bug.** Callers framed the field's height from outside
/// (`.frame(height:)` around the field). That frame only added transparent room
/// around `ChromeControlBox`, whose ground and border hugged the padded text
/// line, so a "33-point" Find in Files field drew a one-line box.
///
/// **The rule now.** A caller with a height passes it to the field as `height:`;
/// the box frames itself at exactly that height and draws on it. A caller with
/// none gets a box one text line high. The box cannot fill whatever it is
/// offered instead: a stack's spare room reaches it exactly as a fixed frame
/// does, and a filling box grew the in-editor find bar, above the editor, from
/// about 29 to about 239 points in this harness — which is what the find-bar
/// case below holds down. Verified by mutation: with the box's height frame
/// removed, a field given 33 points measured a 15-point box at scale 1 (26
/// against 59.5 at 1.8).
///
/// **What is not measured here.** The platform's focus ring is drawn only on a
/// key window holding real first-responder focus, which a headless test cannot
/// reliably reach. The suppression (`.focusEffectDisabled()` on the inner field)
/// is pinned by `ChromeThemeSourceGatingTests`' rule forty-five and the live
/// check instead.
///
/// Colours are compared against a swatch of the same role rendered through the
/// same pipeline, because the cached bitmap applies a colour-space conversion
/// the palette's raw values do not carry.
@MainActor
final class ChromeThemedTextFieldLayoutTests: XCTestCase {

    private enum Focus: Hashable { case field }

    func testAFieldGivenAHeightPaintsItsBoxAcrossThatHeight() throws {
        try assertHeighted(scale: 1)
    }

    func testAFieldGivenAHeightPaintsItsBoxAcrossThatHeightAtInterfaceScaleOnePointEight() throws {
        try assertHeighted(scale: 1.8)
    }

    func testAFieldWithNoHeightKeepsItsSingleLineHeight() throws {
        try assertUnheighted(scale: 1)
    }

    func testAFieldWithNoHeightKeepsItsSingleLineHeightAtInterfaceScaleOnePointEight() throws {
        try assertUnheighted(scale: 1.8)
    }

    func testTheFindBarDoesNotGrowAboveAFlexibleSibling() throws {
        try assertFindBar(scale: 1)
    }

    func testTheFindBarDoesNotGrowAboveAFlexibleSiblingAtInterfaceScaleOnePointEight() throws {
        try assertFindBar(scale: 1.8)
    }

    // MARK: - Assertions

    /// A field given 33 points, hosted in a much taller window: its box spans
    /// exactly the 33 — not the window's spare room — with the `hairline` border
    /// at both edges and the `bgEditor` ground above and below the text line.
    private func assertHeighted(scale: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let metrics = InterfaceMetrics(scale: scale)
        let height = metrics.scaled(33)
        let width = metrics.scaled(240)
        let render = try FieldRender(metrics: metrics, size: CGSize(width: width + 20, height: height * 4)) {
            FieldHost(text: "query", height: 33).frame(width: width)
        }
        addTeardownBlock { @MainActor in render.window.close() }

        let extent = try XCTUnwrap(render.boxExtent(atX: 10 + metrics.scaled(3)), "no box drawn", file: file, line: line)
        XCTAssertEqual(
            extent.minY, 10, accuracy: 0.6,
            "the box does not start at the field's top at scale \(scale)", file: file, line: line
        )
        XCTAssertEqual(
            extent.maxY - extent.minY, height, accuracy: 0.6,
            "the box is not the 33 points it was given at scale \(scale)", file: file, line: line
        )

        let x = 10 + width / 2
        for y: CGFloat in [extent.minY + 0.5 / CGFloat(scale), extent.maxY - 0.5 / CGFloat(scale)] {
            XCTAssertTrue(
                render.matches(.hairline, atX: x, y: y),
                "no hairline border at y \(y), scale \(scale)", file: file, line: line
            )
        }
        for y: CGFloat in [extent.minY + metrics.scaled(3), extent.maxY - metrics.scaled(3)] {
            XCTAssertTrue(
                render.matches(.bgEditor, atX: x, y: y),
                "no bgEditor ground at y \(y), scale \(scale)", file: file, line: line
            )
        }
    }

    /// A field given no height is one text line high, hosted at a fixed width
    /// in a taller window.
    private func assertUnheighted(scale: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let metrics = InterfaceMetrics(scale: scale)
        let natural = try naturalLineHeight(metrics: metrics)
        let render = try FieldRender(
            metrics: metrics,
            size: CGSize(width: metrics.scaled(260), height: metrics.scaled(200))
        ) {
            FieldHost(text: "query", height: nil).frame(width: metrics.scaled(240))
        }
        addTeardownBlock { @MainActor in render.window.close() }

        let extent = try XCTUnwrap(render.boxExtent(atX: 10 + metrics.scaled(3)), "no box drawn", file: file, line: line)
        XCTAssertEqual(
            extent.maxY - extent.minY, natural, accuracy: 1,
            "a field with no height is not one text line high at scale \(scale)", file: file, line: line
        )
    }

    private func assertFindBar(scale: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let metrics = InterfaceMetrics(scale: scale)
        let natural = try naturalLineHeight(metrics: metrics)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ChromeThemedTextFieldLayoutTests"))
        defaults.removePersistentDomain(forName: "ChromeThemedTextFieldLayoutTests")
        let settings = SettingsStore(defaults: defaults)
        let search = EditorSearchState()
        let render = try FieldRender(metrics: metrics, size: CGSize(width: metrics.scaled(700), height: metrics.scaled(500))) {
            VStack(spacing: 0) {
                SearchBarView(search: search, settings: settings)
                Color.black
            }
        }
        addTeardownBlock { @MainActor in render.window.close() }

        let barHeight = try XCTUnwrap(render.extent(of: .bgPanel, atX: 10 + metrics.scaled(2)), "no find bar drawn", file: file, line: line)
        // The bar is the field's line plus its two 5-point paddings and its hairline.
        XCTAssertLessThan(
            barHeight.maxY - barHeight.minY, natural + metrics.scaled(14),
            "the find bar grew above a flexible sibling at scale \(scale)", file: file, line: line
        )
    }

    /// A single line of the field's own font, measured on a bare plain field —
    /// independent of the box under test.
    private func naturalLineHeight(metrics: InterfaceMetrics) throws -> CGFloat {
        let reference = NSHostingView(rootView: TextField("", text: .constant("query"))
            .textFieldStyle(.plain)
            .font(metrics.scaledFont(.callout)))
        return reference.fittingSize.height
    }
}

/// A field with its own focus state, the way every caller holds one.
private struct FieldHost: View {
    @State var text: String
    let height: Double?
    @FocusState private var focus: Bool?

    var body: some View {
        ChromeThemedTextField(title: "Query", text: $text, focus: $focus, focusedEquals: true, height: height)
    }
}

/// A view hosted in a borderless window on a black ground, rendered to a bitmap
/// once its layout has settled, inset by 10 points from its top-leading corner.
@MainActor
private final class FieldRender {
    let window: NSWindow
    private let rep: NSBitmapImageRep
    private let pixelScale: CGFloat
    private let height: CGFloat

    init<V: View>(metrics: InterfaceMetrics, size: CGSize, @ViewBuilder content: () -> V) throws {
        let root = content()
            .padding(10)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .environment(\.interfaceMetrics, metrics)
            .environment(\.chromeTheme, ChromeTheme(.dark))
            .background(Color.black)
        let host = NSHostingView(rootView: root)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        height = host.bounds.height
        rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        pixelScale = CGFloat(rep.pixelsWide) / host.bounds.width
    }

    private func color(atX x: CGFloat, y: CGFloat) -> NSColor? {
        rep.colorAt(x: Int(x * pixelScale), y: Int(y * pixelScale))?.usingColorSpace(.sRGB)
    }

    private func isInk(_ c: NSColor?) -> Bool {
        guard let c else { return false }
        return c.redComponent + c.greenComponent + c.blueComponent > 0.05
    }

    /// Whether the pixel at (`x`, `y`) points is `role`'s dark value, as a
    /// swatch of that role renders through this same pipeline — the cached
    /// bitmap carries a colour-space conversion the palette's raw values do not.
    func matches(_ role: ChromeColorRole, atX x: CGFloat, y: CGFloat) -> Bool {
        guard let c = color(atX: x, y: y), let expected = Self.swatch(role) else { return false }
        return abs(c.redComponent - expected.redComponent) < 0.02
            && abs(c.greenComponent - expected.greenComponent) < 0.02
            && abs(c.blueComponent - expected.blueComponent) < 0.02
    }

    private static var swatches: [ChromeColorRole: NSColor] = [:]

    private static func swatch(_ role: ChromeColorRole) -> NSColor? {
        if let cached = swatches[role] { return cached }
        let host = NSHostingView(rootView: Rectangle().fill(ChromeTheme(.dark).color(role)).frame(width: 4, height: 4))
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

    /// The vertical extent, in points, of the ink run in column `x`.
    func boxExtent(atX x: CGFloat) -> (minY: CGFloat, maxY: CGFloat)? {
        let rows = stride(from: 0, to: height, by: 1 / pixelScale).filter { isInk(color(atX: x, y: $0)) }
        guard let first = rows.first, let last = rows.last else { return nil }
        return (first, last + 1 / pixelScale)
    }

    /// The vertical extent, in points, of the pixels painted `role` in column `x`.
    func extent(of role: ChromeColorRole, atX x: CGFloat) -> (minY: CGFloat, maxY: CGFloat)? {
        let rows = stride(from: 0, to: height, by: 1 / pixelScale).filter { matches(role, atX: x, y: $0) }
        guard let first = rows.first, let last = rows.last else { return nil }
        return (first, last + 1 / pixelScale)
    }
}
#endif
