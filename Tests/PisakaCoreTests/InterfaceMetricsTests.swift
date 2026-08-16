import XCTest
@testable import PisakaCore

/// The interface zone's scale turned into point sizes: the base table, the
/// "nothing changes at 100%" guarantee the whole view sweep rests on, and the
/// rounding rules.
final class InterfaceMetricsTests: XCTestCase {
    /// The scales the interface zone can actually hold: its grid from the
    /// minimum to the maximum.
    private var gridScales: [Double] {
        let rule = ZoomScaleRule.interfaceScale
        var scales: [Double] = []
        var value = rule.minimum
        while value <= rule.maximum + 1e-9 {
            scales.append((value * 1_000_000).rounded() / 1_000_000)
            value += rule.step
        }
        return scales
    }

    /// The layout constants the macOS views pass to `pt(_:)` — all on the
    /// half-point grid, as every real one is.
    private let metrics: [Double] = [0.5, 1, 2, 3, 4, 6, 8, 10, 12, 16, 20, 24, 44, 120, 320, 640]

    // MARK: - The base table

    func testBasePointSizesAreTheMacOSValues() {
        // AppKit's macOS sizes, not iOS's: body is 13 here and 17 there, so a
        // copied iOS table would restyle the whole app at 100%.
        XCTAssertEqual(InterfaceTextStyle.largeTitle.basePointSize, 26)
        XCTAssertEqual(InterfaceTextStyle.title.basePointSize, 22)
        XCTAssertEqual(InterfaceTextStyle.title2.basePointSize, 17)
        XCTAssertEqual(InterfaceTextStyle.title3.basePointSize, 15)
        XCTAssertEqual(InterfaceTextStyle.headline.basePointSize, 13)
        XCTAssertEqual(InterfaceTextStyle.body.basePointSize, 13)
        XCTAssertEqual(InterfaceTextStyle.callout.basePointSize, 12)
        XCTAssertEqual(InterfaceTextStyle.subheadline.basePointSize, 11)
        XCTAssertEqual(InterfaceTextStyle.footnote.basePointSize, 10)
        XCTAssertEqual(InterfaceTextStyle.caption.basePointSize, 10)
        XCTAssertEqual(InterfaceTextStyle.caption2.basePointSize, 10)
    }

    func testBaseSizesOrderTheStylesTheWayTheirNamesDo() {
        XCTAssertGreaterThan(
            InterfaceTextStyle.largeTitle.basePointSize,
            InterfaceTextStyle.title.basePointSize
        )
        XCTAssertGreaterThan(
            InterfaceTextStyle.body.basePointSize,
            InterfaceTextStyle.callout.basePointSize
        )
        XCTAssertGreaterThan(
            InterfaceTextStyle.callout.basePointSize,
            InterfaceTextStyle.caption.basePointSize
        )
    }

    // MARK: - Nothing changes at 100%

    func testScaleOneReturnsEveryStylesBaseSizeUnchanged() {
        // The guarantee the whole sweep rests on: adopting the metrics must not
        // restyle the app for a user who never zooms.
        let metricsAtRest = InterfaceMetrics(scale: 1)
        for style in InterfaceTextStyle.allCases {
            XCTAssertEqual(metricsAtRest.font(style), style.basePointSize, "\(style)")
        }
        XCTAssertEqual(InterfaceMetrics.unscaled, metricsAtRest)
    }

    func testScaleOneReturnsEveryMetricUnchangedIncludingOffGridOnes() {
        let metricsAtRest = InterfaceMetrics.unscaled
        for value in metrics + [1.3, 7.25, -3.75, 0] {
            XCTAssertEqual(metricsAtRest.pt(value), value, "\(value)")
        }
    }

    func testTheDefaultScaleIsTheRestingOne() {
        XCTAssertEqual(ZoomScaleRule.interfaceScale.defaultValue, 1)
        XCTAssertEqual(InterfaceMetrics(scale: ZoomScaleRule.interfaceScale.defaultValue), .unscaled)
    }

    // MARK: - The scale itself

    func testTheScaleIsClampedAndNonFiniteCollapsesToTheDefault() {
        // A stored value is clamped by `SettingsStore` too, but the metrics must
        // be safe on their own: a NaN reaching a frame is an unlaid-out window.
        XCTAssertEqual(InterfaceMetrics(scale: 5).scale, ZoomScaleRule.interfaceScale.maximum)
        XCTAssertEqual(InterfaceMetrics(scale: 0).scale, ZoomScaleRule.interfaceScale.minimum)
        XCTAssertEqual(InterfaceMetrics(scale: -1).scale, ZoomScaleRule.interfaceScale.minimum)
        // Non-finite collapses to the default rather than to a bound, which is
        // `ZoomScaleRule.clamp`'s rule — inherited here rather than restated.
        XCTAssertEqual(InterfaceMetrics(scale: .nan).scale, 1)
        XCTAssertEqual(InterfaceMetrics(scale: .infinity).scale, 1)
        XCTAssertEqual(InterfaceMetrics(scale: -.infinity).scale, 1)
    }

    // MARK: - Rounding

    func testFontSizesAreWholePointsAndGrowWithTheScale() {
        for scale in gridScales {
            let metrics = InterfaceMetrics(scale: scale)
            for style in InterfaceTextStyle.allCases {
                let size = metrics.font(style)
                XCTAssertEqual(size, size.rounded(), "\(style) at \(scale)")
                XCTAssertGreaterThanOrEqual(size, 1, "\(style) at \(scale)")
            }
        }

        XCTAssertEqual(InterfaceMetrics(scale: 1.5).font(.caption), 15)
        XCTAssertEqual(InterfaceMetrics(scale: 2.0).font(.callout), 24)
        // 13 × 0.8 = 10.4, rounded to a whole point.
        XCTAssertEqual(InterfaceMetrics(scale: 0.8).font(.body), 10)
    }

    func testMetricsLandOnTheHalfPointGridAndNeverCollapseToZero() {
        for scale in gridScales {
            let metrics = InterfaceMetrics(scale: scale)
            XCTAssertEqual(metrics.pt(0), 0, "zero at \(scale)")
            for value in self.metrics {
                let scaled = metrics.pt(value)
                XCTAssertEqual(scaled * 2, (scaled * 2).rounded(), "\(value) at \(scale)")
                // A hairline must survive the bottom of the range.
                XCTAssertGreaterThanOrEqual(scaled, 0.5, "\(value) at \(scale)")
            }
        }

        XCTAssertEqual(InterfaceMetrics(scale: 1.5).pt(8), 12)
        XCTAssertEqual(InterfaceMetrics(scale: 1.5).pt(1), 1.5)
        // 0.5 × 0.8 = 0.4, back up to the nearest half point: the thinnest
        // separator this app draws still draws at the bottom of the range.
        XCTAssertEqual(InterfaceMetrics(scale: 0.8).pt(0.5), 0.5)
        // Only a metric far below a device pixel reaches the floor at all, and
        // it is bounded by a half point in either direction.
        XCTAssertEqual(InterfaceMetrics(scale: 0.8).pt(0.1), 0.5)
        XCTAssertEqual(InterfaceMetrics(scale: 0.8).pt(-0.1), -0.5)
    }

    func testNegativeMetricsScaleSymmetrically() {
        for scale in gridScales {
            let metrics = InterfaceMetrics(scale: scale)
            for value in self.metrics {
                XCTAssertEqual(metrics.pt(-value), -metrics.pt(value), "\(value) at \(scale)")
            }
        }
    }

    func testNonFiniteMetricsPassThroughUntouched() {
        // Views do pass `.infinity` as a frame dimension; multiplying it must
        // not turn it into a NaN.
        let metrics = InterfaceMetrics(scale: 1.5)
        XCTAssertEqual(metrics.pt(.infinity), .infinity)
        XCTAssertTrue(metrics.pt(.nan).isNaN)
    }

    // MARK: - Monotonicity

    func testScalingIsMonotonicAcrossTheWholeRange() {
        // Growing the scale must never shrink anything: the sweep's whole claim
        // is that 150% is proportionally bigger than 100% everywhere.
        var previousFonts: [Double] = InterfaceTextStyle.allCases.map { _ in 0 }
        var previousMetrics: [Double] = metrics.map { _ in 0 }
        for scale in gridScales {
            let scaled = InterfaceMetrics(scale: scale)
            for (index, style) in InterfaceTextStyle.allCases.enumerated() {
                let size = scaled.font(style)
                XCTAssertGreaterThanOrEqual(size, previousFonts[index], "\(style) at \(scale)")
                previousFonts[index] = size
            }
            for (index, value) in metrics.enumerated() {
                let size = scaled.pt(value)
                XCTAssertGreaterThanOrEqual(size, previousMetrics[index], "\(value) at \(scale)")
                previousMetrics[index] = size
            }
        }
    }

    func testTheExtremesActuallyDiffer() {
        // Monotonic but flat would satisfy the property above and change
        // nothing on screen.
        let small = InterfaceMetrics(scale: ZoomScaleRule.interfaceScale.minimum)
        let large = InterfaceMetrics(scale: ZoomScaleRule.interfaceScale.maximum)
        for style in InterfaceTextStyle.allCases {
            XCTAssertLessThan(small.font(style), large.font(style), "\(style)")
        }
        for value in metrics {
            XCTAssertLessThan(small.pt(value), large.pt(value), "\(value)")
        }
    }
}
