#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The external-change bar, the shipped `ExternalChangeBar`, hosted in a real
/// window and measured off a rendered bitmap.
///
/// **Three buttons, none of them the default.** The bar's contract is three
/// equally weighted actions — Reload, Overwrite, Compare — with no side drawn as
/// the one to press. The shared secondary style is a `hairline` outline on the
/// bar's ground; the primary style is an `accent` fill. So:
///
/// - across the rows where the buttons' top edges lie (the scaled 28-point
///   button centred in the row above the rule, give or take a couple of points),
///   the right half of the bar carries exactly **three** long `hairline` runs —
///   one per outline's top edge, each at least the scaled 30 points a
///   two-padding label is wider than, and nothing else in the bar draws a
///   horizontal hairline that long there;
/// - no pixel of the bar above its rule is `accent`, so none of the three is
///   drawn as the offer.
///
/// **The ground and the rule** are the consent bar's: `bgPanel` from the
/// top-leading corner, and a `hairline` rule across the full width with the
/// window's ground below it, at both scales.
///
/// **What mutation showed.** Restyling Overwrite as `.chromePrimary` fails both
/// assertions — two outlines and an `accent` fill; dropping Compare leaves two
/// runs.
///
/// Hosting, settling and colour comparison are `HostedRender`'s.
@MainActor
final class ExternalChangeBarLayoutTests: XCTestCase {

    func testThreeEquallyWeightedButtonsAtScaleOne() throws {
        try assertBar(scale: 1)
    }

    func testThreeEquallyWeightedButtonsAtScaleOnePointEight() throws {
        try assertBar(scale: 1.8)
    }

    private func assertBar(scale: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let metrics = InterfaceMetrics(scale: scale)
        let width = metrics.scaled(1_100)
        let render = try render(width: width, metrics: metrics)
        let rule = try XCTUnwrap(
            render.extent(of: .hairline, atX: metrics.scaled(9)),
            "the bar drew no bottom rule in its leading padding", file: file, line: line
        )
        let step = 1 / render.pixelScale

        XCTAssertTrue(
            render.matches(.bgPanel, atX: 0.5, y: 0.5),
            "the window's top-leading corner is not bgPanel at scale \(scale)", file: file, line: line
        )
        let ruleY = (rule.minY + rule.maxY) / 2
        for x in [step / 2, width / 2, width - step / 2] {
            XCTAssertTrue(
                render.matches(.hairline, atX: x, y: ruleY),
                "the bottom rule at scale \(scale) is missing at x \(x)", file: file, line: line
            )
        }
        XCTAssertFalse(
            render.matches(.bgPanel, atX: width / 2, y: rule.maxY + step / 2),
            "below the rule at scale \(scale) is still bgPanel", file: file, line: line
        )

        // The buttons' top edges: centred in the row above the rule, so half a
        // button above the row's middle, searched a couple of points either way.
        let middle = rule.minY / 2
        let buttonTop = middle - metrics.scaled(ChromeGeometry.secondaryButtonHeight) / 2
        let minimumRun = metrics.scaled(30)
        var outlines = 0
        for y in stride(from: buttonTop - metrics.scaled(2), through: buttonTop + metrics.scaled(2), by: step) {
            outlines = max(outlines, longRuns(of: .hairline, in: render, y: y, from: width / 2, to: width, minimum: minimumRun))
        }
        XCTAssertEqual(
            outlines, 3,
            "the bar at scale \(scale) does not draw exactly three outlined secondary buttons", file: file, line: line
        )

        var accent = false
        for y in stride(from: step / 2, to: rule.minY, by: step) where !accent {
            var x = step / 2
            while x < width, !accent {
                accent = render.matches(.accent, atX: x, y: y)
                x += step
            }
        }
        XCTAssertFalse(
            accent,
            "the bar at scale \(scale) paints accent: one of its actions is drawn as the default", file: file, line: line
        )
    }

    /// The runs of `role` pixels along row `y` between `from` and `to` at least
    /// `minimum` points long.
    private func longRuns(
        of role: ChromeColorRole, in render: HostedRender, y: CGFloat, from: CGFloat, to: CGFloat, minimum: CGFloat
    ) -> Int {
        let step = 1 / render.pixelScale
        var runs = 0
        var length: CGFloat = 0
        var x = from
        while x < to {
            if render.matches(role, atX: x, y: y) {
                length += step
            } else {
                if length >= minimum { runs += 1 }
                length = 0
            }
            x += step
        }
        if length >= minimum { runs += 1 }
        return runs
    }

    /// The bar with no-op actions, pinned to the top of a window taller than it.
    private func render(width: CGFloat, metrics: InterfaceMetrics) throws -> HostedRender {
        let render = try HostedRender(
            size: CGSize(width: width, height: metrics.scaled(200)),
            root: ExternalChangeBar(fileName: "main.swift", onReload: {}, onOverwrite: {}, onCompare: {})
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .environment(\.interfaceMetrics, metrics)
                .environment(\.chromeTheme, ChromeTheme(.dark))
        )
        addTeardownBlock { @MainActor in render.window.close() }
        return render
    }
}

#endif
