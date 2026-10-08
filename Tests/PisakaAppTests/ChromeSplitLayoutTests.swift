#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The shared two-pane split, hosted in a real window and measured off a
/// rendered bitmap.
///
/// **The rule.** The divider is one `hairline` line at the scaled
/// `hairlineWidth`, centred in a clear drag strip, in both appearances; the
/// panes are sized by `SplitPaneRule`, so in a narrow window each keeps its
/// minimum while both fit, and the trailing pane's minimum wins when they do
/// not.
///
/// **How it is measured.** The leading pane is filled with `accent` and the
/// trailing one with `statusGreen` over a black ground, so each pane's extent
/// is the run of pixels matching its swatch, and the divider is the run
/// matching `hairline` between them. Every swatch is rendered through the same
/// pipeline (`HostedRender.swatch`), and widths are compared within one pixel.
@MainActor
final class ChromeSplitLayoutTests: XCTestCase {

    /// The bounds every case states: 100/240/360 against a trailing 150.
    private static let minimum: CGFloat = 100
    private static let ideal: CGFloat = 240
    private static let maximum: CGFloat = 360
    private static let trailingMinimum: CGFloat = 150

    func testTheHorizontalDividerIsOneHairlineInBothAppearances() throws {
        for appearance in [ChromeAppearance.dark, .light] {
            let render = try SplitRender(axis: .horizontal, size: CGSize(width: 600, height: 80), appearance: appearance)
            addTeardownBlock { @MainActor in render.window.close() }
            let line = try XCTUnwrap(render.run(of: .hairline), "no hairline drawn in \(appearance)")
            XCTAssertEqual(
                CGFloat(line.count), render.pixelScale * CGFloat(ChromeGeometry.hairlineWidth), accuracy: 1,
                "the divider is not one hairline wide in \(appearance)"
            )
            let leading = try XCTUnwrap(render.run(of: .accent), "the leading pane is not drawn")
            let trailing = try XCTUnwrap(render.run(of: .statusGreen), "the trailing pane is not drawn")
            XCTAssertEqual(CGFloat(leading.count), Self.ideal * render.pixelScale, accuracy: 1, "the leading pane is not at its ideal")
            XCTAssertGreaterThan(line.lowerBound, leading.upperBound, "the hairline does not sit after the leading pane")
            XCTAssertLessThan(line.upperBound, trailing.lowerBound, "the hairline does not sit before the trailing pane")
            // The strip around the line is clear: the ground shows through it.
            XCTAssertEqual(
                CGFloat(trailing.lowerBound - leading.upperBound), 5 * render.pixelScale, accuracy: 1,
                "the drag strip is not five points"
            )
        }
    }

    func testTheVerticalDividerIsOneHairlineInBothAppearances() throws {
        for appearance in [ChromeAppearance.dark, .light] {
            let render = try SplitRender(axis: .vertical, size: CGSize(width: 80, height: 600), appearance: appearance)
            addTeardownBlock { @MainActor in render.window.close() }
            let line = try XCTUnwrap(render.run(of: .hairline), "no hairline drawn in \(appearance)")
            XCTAssertEqual(
                CGFloat(line.count), render.pixelScale * CGFloat(ChromeGeometry.hairlineWidth), accuracy: 1,
                "the divider is not one hairline tall in \(appearance)"
            )
            let leading = try XCTUnwrap(render.run(of: .accent), "the top pane is not drawn")
            XCTAssertEqual(CGFloat(leading.count), Self.ideal * render.pixelScale, accuracy: 1, "the top pane is not at its ideal")
        }
    }

    func testThePanesKeepTheirMinimumsAtANarrowWidth() throws {
        // 260 wide: the panes share 255, so the leading pane stops at 105 —
        // above its own 100 — and the trailing pane keeps its 150.
        let render = try SplitRender(axis: .horizontal, size: CGSize(width: 260, height: 80), appearance: .dark)
        addTeardownBlock { @MainActor in render.window.close() }
        let leading = try XCTUnwrap(render.run(of: .accent), "the leading pane is not drawn")
        let trailing = try XCTUnwrap(render.run(of: .statusGreen), "the trailing pane is not drawn")
        XCTAssertGreaterThanOrEqual(CGFloat(leading.count) + 1, Self.minimum * render.pixelScale)
        XCTAssertEqual(CGFloat(leading.count), 105 * render.pixelScale, accuracy: 1)
        XCTAssertEqual(CGFloat(trailing.count), Self.trailingMinimum * render.pixelScale, accuracy: 1)
    }

    func testTheTrailingMinimumWinsWhenBothCannotFit() throws {
        // 200 wide: the panes share 195, and the trailing pane's 150 is kept
        // at the cost of the leading pane's minimum.
        let render = try SplitRender(axis: .horizontal, size: CGSize(width: 200, height: 80), appearance: .dark)
        addTeardownBlock { @MainActor in render.window.close() }
        let leading = try XCTUnwrap(render.run(of: .accent), "the leading pane is not drawn")
        let trailing = try XCTUnwrap(render.run(of: .statusGreen), "the trailing pane is not drawn")
        XCTAssertEqual(CGFloat(trailing.count), Self.trailingMinimum * render.pixelScale, accuracy: 1)
        XCTAssertEqual(CGFloat(leading.count), 45 * render.pixelScale, accuracy: 1)
    }

    /// A `ChromeSplitView` of two filled panes on a black ground.
    @MainActor
    private final class SplitRender {
        private let render: HostedRender
        private let axis: Axis
        private let appearance: ChromeAppearance
        var window: NSWindow { render.window }
        var pixelScale: CGFloat { render.pixelScale }

        init(axis: Axis, size: CGSize, appearance: ChromeAppearance) throws {
            self.axis = axis
            self.appearance = appearance
            let theme = ChromeTheme(appearance)
            let root = ChromeSplitView(
                axis,
                minimum: ChromeSplitLayoutTests.minimum,
                ideal: ChromeSplitLayoutTests.ideal,
                maximum: ChromeSplitLayoutTests.maximum,
                trailingMinimum: ChromeSplitLayoutTests.trailingMinimum
            ) {
                Rectangle().fill(theme.color(.accent))
            } trailing: {
                Rectangle().fill(theme.color(.statusGreen))
            }
            .environment(\.interfaceMetrics, InterfaceMetrics(scale: 1))
            .environment(\.chromeTheme, theme)
            .frame(width: size.width, height: size.height)
            .background(Color.black)
            render = try HostedRender(size: size, root: root)
        }

        /// The pixel range, along the split's axis through the middle of the
        /// cross axis, painted `role` over black.
        func run(of role: ChromeColorRole) -> Range<Int>? {
            guard let expected = HostedRender.swatch(role, ground: .black, appearance: appearance) else { return nil }
            let bounds = render.bounds
            let length = Int((axis == .horizontal ? bounds.width : bounds.height) * pixelScale)
            let matching = (0..<length).filter { pixel in
                let point = CGFloat(pixel) / pixelScale
                let color = axis == .horizontal
                    ? render.color(atPixelX: pixel, y: bounds.midY)
                    : render.color(atX: bounds.midX, y: point)
                guard let color else { return false }
                return abs(color.redComponent - expected.redComponent) < 0.02
                    && abs(color.greenComponent - expected.greenComponent) < 0.02
                    && abs(color.blueComponent - expected.blueComponent) < 0.02
            }
            guard let first = matching.first, let last = matching.last else { return nil }
            return first..<(last + 1)
        }
    }
}
#endif
