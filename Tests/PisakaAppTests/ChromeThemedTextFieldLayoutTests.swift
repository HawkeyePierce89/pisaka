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
/// line, so a "33-point" Find in Files field drew a one-line box. The menu
/// field shares the box and had the same cause, so it is measured the same way.
///
/// **The rule now.** A caller with a height passes it to the field as `height:`;
/// the box frames itself at exactly that height and draws on it. A caller with
/// none gets a box one text line high. The box cannot fill whatever it is
/// offered instead: a stack's spare room reaches it exactly as a fixed frame
/// does, and a filling box grew the in-editor find bar, above the editor, from
/// about 29 (31 since the query toggles draw a 16-point glyph) to about 239
/// points in this harness — which is what the find-bar
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
/// Hosting, settling and colour comparison are `HostedRender`'s.
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

    func testAMenuFieldGivenAHeightPaintsItsBoxAcrossThatHeight() throws {
        try assertHeighted(scale: 1, menu: true)
    }

    func testAMenuFieldGivenAHeightPaintsItsBoxAcrossThatHeightAtInterfaceScaleOnePointEight() throws {
        try assertHeighted(scale: 1.8, menu: true)
    }

    func testTheFindBarDoesNotGrowAboveAFlexibleSibling() throws {
        try assertFindBar(scale: 1)
    }

    func testTheFindBarDoesNotGrowAboveAFlexibleSiblingAtInterfaceScaleOnePointEight() throws {
        try assertFindBar(scale: 1.8)
    }

    // MARK: - Assertions

    /// A field — or, with `menu`, the shared menu field, which shares the box —
    /// given 33 points, hosted in a much taller window: its box spans exactly
    /// the 33 — not the window's spare room — with the `hairline` border at both
    /// edges and the `bgEditor` ground above and below the text line.
    private func assertHeighted(
        scale: Double, menu: Bool = false, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let metrics = InterfaceMetrics(scale: scale)
        let height = metrics.scaled(33)
        let width = metrics.scaled(240)
        let render = try FieldRender(metrics: metrics, size: CGSize(width: width + 20, height: height * 4)) {
            if menu {
                // A title longer than the field, so the box spans the width
                // the column below samples (a box hugs its label horizontally).
                let title = String(repeating: "a long branch name ", count: 6)
                ChromeMenuField(
                    label: "Branch", options: [(value: 0, title: title)], selection: .constant(0),
                    currentTitle: title, height: 33
                )
                .frame(width: width, alignment: .leading)
            } else {
                FieldHost(text: "query", height: 33).frame(width: width)
            }
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
        // The bar is its tallest control plus its two 5-point paddings and its
        // hairline. The tallest is the field's line or, since the query toggles
        // draw a 16-point glyph, the toggle's 22-point square — a fixed size,
        // so the bound still holds the bar down against the spare room.
        let tallest = max(natural, metrics.scaled(ChromeQueryToggleLayout.side))
        XCTAssertLessThan(
            barHeight.maxY - barHeight.minY, tallest + metrics.scaled(14),
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

/// A view hosted in a borderless window on a black ground, inset by 10 points
/// from its top-leading corner (`HostedRender`).
@MainActor
private final class FieldRender {
    private let render: HostedRender
    var window: NSWindow { render.window }

    init<V: View>(metrics: InterfaceMetrics, size: CGSize, @ViewBuilder content: () -> V) throws {
        let root = content()
            .padding(10)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .environment(\.interfaceMetrics, metrics)
            .environment(\.chromeTheme, ChromeTheme(.dark))
            .background(Color.black)
        render = try HostedRender(size: size, root: root)
    }

    func matches(_ role: ChromeColorRole, atX x: CGFloat, y: CGFloat) -> Bool {
        render.matches(role, atX: x, y: y)
    }

    /// The vertical extent, in points, of the ink run in column `x`.
    func boxExtent(atX x: CGFloat) -> (minY: CGFloat, maxY: CGFloat)? {
        render.extent(atX: x) { c in
            guard let c else { return false }
            return c.redComponent + c.greenComponent + c.blueComponent > 0.05
        }
    }

    /// The vertical extent, in points, of the pixels painted `role` in column `x`.
    func extent(of role: ChromeColorRole, atX x: CGFloat) -> (minY: CGFloat, maxY: CGFloat)? {
        render.extent(of: role, atX: x)
    }
}
#endif
