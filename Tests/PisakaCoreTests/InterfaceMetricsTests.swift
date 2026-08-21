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

        // The half-point cases, which pin the rule as *nearest* rather than
        // truncation. Roughly half the shipped grid lands on a .5 for some style,
        // so without these every chrome font could silently lose a point across
        // half the range with this suite still green.
        XCTAssertEqual(InterfaceMetrics(scale: 1.5).font(.body), 20)      // 19.5
        XCTAssertEqual(InterfaceMetrics(scale: 1.5).font(.callout), 18)   // 18.0
        XCTAssertEqual(InterfaceMetrics(scale: 1.1).font(.title3), 17)    // 16.5
        XCTAssertEqual(InterfaceMetrics(scale: 1.5).font(.subheadline), 17) // 16.5
        XCTAssertEqual(InterfaceMetrics(scale: 0.9).font(.title), 20)     // 19.8
    }

    func testAScaleOfExactlyOneReturnsEveryBaseSizeIdentically() {
        // The resting metrics are the whole reason a view the sweep has not
        // reached still draws what it drew before this feature existed. Asserted
        // against `basePointSize` itself, not against restated numbers, so the
        // claim is "unchanged" rather than "equal to a second copy of the table".
        for style in InterfaceTextStyle.allCases {
            XCTAssertEqual(InterfaceMetrics.unscaled.font(style), style.basePointSize, "\(style)")
            XCTAssertEqual(InterfaceMetrics(scale: 1).font(style), style.basePointSize, "\(style)")
        }
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

    // MARK: - Composites the view sweep builds out of these metrics

    /// The Log's branch-graph gutter is the one place in the sweep where a
    /// metric is *composed* rather than applied once: the row reserves
    /// `lanes × laneSpacing + margin` points and the AppKit cell then draws its
    /// lanes and node dot inside exactly that width. Two independently scaled
    /// numbers that disagree would put the last lane's dot outside the gutter —
    /// so the composition, not just its parts, is pinned here.
    private func graphGutterWidth(lanes: Int, _ metrics: InterfaceMetrics) -> Double {
        Double(max(lanes, 1)) * metrics.pt(14) + metrics.pt(6)
    }

    func testTheCommitGraphGutterWidthIsUnchangedAtRestAndGrowsWithTheScale() {
        // Unchanged at 100%: the pre-sweep constants, verbatim.
        for lanes in 1...6 {
            XCTAssertEqual(
                graphGutterWidth(lanes: lanes, .unscaled),
                Double(lanes) * 14 + 6,
                "\(lanes) lanes"
            )
        }

        for lanes in 1...6 {
            var previous = 0.0
            for scale in gridScales {
                let width = graphGutterWidth(lanes: lanes, InterfaceMetrics(scale: scale))
                XCTAssertGreaterThanOrEqual(width, previous, "\(lanes) lanes at \(scale)")
                previous = width
            }
            XCTAssertLessThan(
                graphGutterWidth(lanes: lanes, InterfaceMetrics(scale: ZoomScaleRule.interfaceScale.minimum)),
                graphGutterWidth(lanes: lanes, InterfaceMetrics(scale: ZoomScaleRule.interfaceScale.maximum)),
                "\(lanes) lanes"
            )
        }
    }

    func testEveryLanesNodeDotFitsInsideTheGutterAtEveryScale() {
        // What the composition is *for*: lane `i`'s center sits at
        // `spacing/2 + i × spacing`, and its dot extends one radius past that.
        // The reserved width has to cover the last one at every scale, or the
        // rightmost branch is clipped exactly when the user zooms in to see it.
        for scale in gridScales {
            let metrics = InterfaceMetrics(scale: scale)
            let spacing = metrics.pt(14)
            let radius = metrics.pt(3.5)
            for lanes in 1...6 {
                let width = graphGutterWidth(lanes: lanes, metrics)
                let lastCenter = spacing / 2 + Double(lanes - 1) * spacing
                XCTAssertLessThanOrEqual(lastCenter + radius, width, "\(lanes) lanes at \(scale)")
            }
        }
    }

    func testTheGraphNodeStaysInsideItsRowAndItsLaneAtEveryScale() {
        // The gutter cell is drawn at the commit row's own height, from the same
        // base (24). A dot wider than its lane, or taller than the row, is what
        // scaling one of the three and forgetting the others looks like.
        for scale in gridScales {
            let metrics = InterfaceMetrics(scale: scale)
            let diameter = metrics.pt(3.5) * 2
            XCTAssertLessThan(diameter, metrics.pt(24), "row height at \(scale)")
            XCTAssertLessThan(diameter, metrics.pt(14), "lane spacing at \(scale)")
        }
    }

    /// A `.frame(minWidth:idealWidth:maxWidth:)` whose bounds cross is a layout
    /// the framework cannot satisfy, and the sweep scales all three of them
    /// independently — so the ordering has to survive the scaling rather than be
    /// assumed to. The triples are the real ones: the commit sheet's file list,
    /// the Acknowledgements dependency list, the sheet itself and the login sheet.
    func testScalingPreservesTheOrderingOfEverySizeTriple() {
        let triples: [(String, Double, Double, Double)] = [
            ("commit file list", 220, 280, 420),
            ("acknowledgements list", 180, 200, 280),
            ("browser number column", 48, 56, 90),
            ("browser difficulty column", 72, 88, 120),
            ("login sheet width", 520, 760, .infinity)
        ]
        for scale in gridScales {
            let metrics = InterfaceMetrics(scale: scale)
            for (name, minimum, ideal, maximum) in triples {
                XCTAssertLessThanOrEqual(metrics.pt(minimum), metrics.pt(ideal), "\(name) at \(scale)")
                XCTAssertLessThanOrEqual(metrics.pt(ideal), metrics.pt(maximum), "\(name) at \(scale)")
            }
        }
    }

    /// The commit sheet is the other composition the sweep builds: its own
    /// minimum width has to hold both panes of the `HSplitView` inside it at
    /// their own minimums, at every scale. Scaling the sheet and forgetting a
    /// pane — or rounding them apart — squeezes the diff out of a dialog whose
    /// whole point is the diff.
    func testTheCommitSheetsMinimumWidthHoldsBothPanesAtEveryScale() {
        for scale in gridScales {
            let metrics = InterfaceMetrics(scale: scale)
            let sheet = metrics.pt(900)
            let fileList = metrics.pt(220)
            let diff = metrics.pt(380)
            XCTAssertGreaterThanOrEqual(sheet, fileList + diff, "at \(scale)")
            // And the ideal is never narrower than the minimum it accompanies.
            XCTAssertGreaterThanOrEqual(metrics.pt(1000), sheet, "at \(scale)")
            XCTAssertGreaterThanOrEqual(metrics.pt(640), metrics.pt(560), "at \(scale)")
        }
    }

    /// Acknowledgements is a fixed-width pane holding a list beside a license.
    /// Both halves scale, so what has to be pinned is that the *remainder* — the
    /// room the license text is read in — never shrinks as the scale grows.
    func testTheAcknowledgementsDetailPaneKeepsItsRoomAtEveryScale() {
        var previousRemainder = 0.0
        for scale in gridScales {
            let metrics = InterfaceMetrics(scale: scale)
            let remainder = metrics.pt(640) - metrics.pt(280)
            XCTAssertGreaterThan(remainder, 0, "at \(scale)")
            XCTAssertGreaterThanOrEqual(remainder, previousRemainder, "at \(scale)")
            previousRemainder = remainder
        }
    }

    /// The one text size in the sweep that is handed to an AppKit view rather
    /// than to SwiftUI: the license pane takes a point size, and it has to be
    /// `NSFont.smallSystemFontSize` — 11 — at rest, or adopting the metrics
    /// silently restyles the longest text in Preferences.
    func testTheLicensePanesRestingSizeIsTheSmallSystemFontSize() {
        XCTAssertEqual(InterfaceMetrics.unscaled.font(.subheadline), 11)
        XCTAssertGreaterThan(
            InterfaceMetrics(scale: ZoomScaleRule.interfaceScale.maximum).font(.subheadline),
            11
        )
    }

    /// The pane's *margin* travels the same way and for the same reason: it is a
    /// `textContainerInset` set on a TextKit view rather than a SwiftUI padding,
    /// so nothing else in the sweep would move it. Both it and the header
    /// directly above it are `pt(12)`, which is what keeps the license text in
    /// line with its own header at every step; what is worth pinning is the two
    /// ends — 12 at rest, and genuinely larger at the top of the range, so a
    /// margin left behind at 200% fails here rather than only on screen.
    func testTheLicensePanesInsetRestsAtTwelveAndGrows() {
        XCTAssertEqual(InterfaceMetrics.unscaled.pt(12), 12)
        XCTAssertGreaterThan(
            InterfaceMetrics(scale: ZoomScaleRule.interfaceScale.maximum).pt(12),
            12
        )
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
