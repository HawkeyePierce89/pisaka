import XCTest
@testable import PisakaCore

/// The bridge from continuous scroll/pinch deltas to the discrete steps the
/// keyboard produces: the thresholds, the remainder that must not be lost, and
/// the two places a remainder is deliberately thrown away.
final class ZoomGestureAccumulatorTests: XCTestCase {
    private let thresholds = ZoomGestureAccumulator.Thresholds.standard

    // MARK: - The shipped thresholds

    func testStandardThresholds() {
        // A pinch's threshold is the smallest of the three on purpose: a pinch's
        // whole travel is a magnification of about ±1.
        XCTAssertEqual(thresholds.preciseScrollPoints, 24)
        XCTAssertEqual(thresholds.scrollLines, 1)
        XCTAssertEqual(thresholds.magnification, 0.05)
        XCTAssertLessThan(thresholds.magnification, thresholds.scrollLines)
    }

    // MARK: - Reaching exactly N steps

    func testNThresholdsProduceExactlyNSteps() {
        // Fed one threshold at a time, in one sample each: the count must be
        // exact in both directions and for every input flavor, since this is
        // what keeps scroll-zoom on the same grid as ⌘=.
        for count in 1...12 {
            for sign in [1.0, -1.0] {
                var precise = ZoomGestureAccumulator()
                var lines = ZoomGestureAccumulator()
                var pinch = ZoomGestureAccumulator()
                var preciseSteps = 0, lineSteps = 0, pinchSteps = 0
                for _ in 0..<count {
                    preciseSteps += precise.accumulate(
                        .scroll(delta: sign * thresholds.preciseScrollPoints, precise: true)
                    )
                    lineSteps += lines.accumulate(
                        .scroll(delta: sign * thresholds.scrollLines, precise: false)
                    )
                    pinchSteps += pinch.accumulate(.magnification(sign * thresholds.magnification))
                }
                XCTAssertEqual(preciseSteps, Int(sign) * count, "precise, \(count)")
                XCTAssertEqual(lineSteps, Int(sign) * count, "lines, \(count)")
                XCTAssertEqual(pinchSteps, Int(sign) * count, "pinch, \(count)")
            }
        }
    }

    func testManySmallSamplesReachTheSameCount() {
        // The trackpad's real shape: a hundred tiny samples adding up to four
        // thresholds. Floating-point residue must not swallow the last step.
        var accumulator = ZoomGestureAccumulator()
        let total = thresholds.preciseScrollPoints * 4
        var steps = 0
        for _ in 0..<100 {
            steps += accumulator.accumulate(.scroll(delta: total / 100, precise: true))
        }
        XCTAssertEqual(steps, 4)
    }

    func testOneLargeSampleProducesEveryStepAtOnce() {
        // A flick, or a wheel that coalesced several detents into one event.
        var accumulator = ZoomGestureAccumulator()
        XCTAssertEqual(
            accumulator.accumulate(.scroll(delta: thresholds.preciseScrollPoints * 3.5, precise: true)),
            3
        )
        // …and the half step is kept, not dropped.
        XCTAssertEqual(
            accumulator.accumulate(.scroll(delta: thresholds.preciseScrollPoints * 0.5, precise: true)),
            1
        )
    }

    // MARK: - Sub-threshold deltas

    func testSubThresholdDeltasProduceNothingButAreNotLost() {
        var accumulator = ZoomGestureAccumulator()
        for _ in 0..<3 {
            XCTAssertEqual(
                accumulator.accumulate(.scroll(delta: thresholds.preciseScrollPoints / 4, precise: true)),
                0
            )
        }
        XCTAssertEqual(accumulator.pending, 0.75, accuracy: 1e-9)
        XCTAssertEqual(
            accumulator.accumulate(.scroll(delta: thresholds.preciseScrollPoints / 4, precise: true)),
            1
        )
        XCTAssertEqual(accumulator.pending, 0, accuracy: 1e-9)
    }

    func testZeroAndNonFiniteDeltasAreIgnoredWithoutDisturbingTheRemainder() {
        var accumulator = ZoomGestureAccumulator()
        _ = accumulator.accumulate(.scroll(delta: thresholds.preciseScrollPoints / 2, precise: true))
        let pending = accumulator.pending

        // macOS emits zero-delta events at the tail of momentum scrolling; a
        // NaN folded in would poison every later sample.
        XCTAssertEqual(accumulator.accumulate(.scroll(delta: 0, precise: true)), 0)
        XCTAssertEqual(accumulator.accumulate(.scroll(delta: .nan, precise: true)), 0)
        XCTAssertEqual(accumulator.accumulate(.magnification(.infinity)), 0)
        XCTAssertEqual(accumulator.pending, pending)

        XCTAssertEqual(
            accumulator.accumulate(.scroll(delta: thresholds.preciseScrollPoints / 2, precise: true)),
            1
        )
    }

    // MARK: - Mixed flavors

    func testMixedPreciseAndLineInputAccumulateInTheSameUnit() {
        // Half a precise threshold plus half a line threshold is one whole step:
        // normalization happens before accumulation, so the flavors are
        // commensurable.
        var accumulator = ZoomGestureAccumulator()
        XCTAssertEqual(
            accumulator.accumulate(.scroll(delta: thresholds.preciseScrollPoints / 2, precise: true)),
            0
        )
        XCTAssertEqual(
            accumulator.accumulate(.scroll(delta: thresholds.scrollLines / 2, precise: false)),
            1
        )
    }

    func testTheSameRawDeltaMeansDifferentThingsInTheTwoFlavors() {
        // A delta of 1 is one whole detent from a wheel and a single point of
        // trackpad travel; treating them alike is exactly the bug this flag
        // exists to prevent.
        var wheel = ZoomGestureAccumulator()
        var trackpad = ZoomGestureAccumulator()
        XCTAssertEqual(wheel.accumulate(.scroll(delta: 1, precise: false)), 1)
        XCTAssertEqual(trackpad.accumulate(.scroll(delta: 1, precise: true)), 0)
    }

    func testMixedPinchAndScrollAccumulate() {
        var accumulator = ZoomGestureAccumulator()
        XCTAssertEqual(accumulator.accumulate(.magnification(thresholds.magnification * 0.5)), 0)
        XCTAssertEqual(
            accumulator.accumulate(.scroll(delta: thresholds.preciseScrollPoints * 0.5, precise: true)),
            1
        )
    }

    // MARK: - Reset and direction reversal

    func testResetClearsTheRemainder() {
        // The pointer crossing into another zone, or the gesture ending: the
        // half step must not make an unrelated later flick step immediately.
        var accumulator = ZoomGestureAccumulator()
        _ = accumulator.accumulate(.scroll(delta: thresholds.preciseScrollPoints * 0.9, precise: true))
        accumulator.reset()
        XCTAssertEqual(accumulator.pending, 0)
        XCTAssertEqual(
            accumulator.accumulate(.scroll(delta: thresholds.preciseScrollPoints * 0.9, precise: true)),
            0
        )
    }

    func testDirectionReversalDropsTheRemainder() {
        // Pushing up 0.9 of a step then turning around must not step down on the
        // very first backwards sample (0.9 + -0.2 would otherwise still be
        // pending, and -1.0 would arrive a threshold late in the other case).
        var accumulator = ZoomGestureAccumulator()
        _ = accumulator.accumulate(.scroll(delta: thresholds.preciseScrollPoints * 0.9, precise: true))
        XCTAssertEqual(
            accumulator.accumulate(.scroll(delta: -thresholds.preciseScrollPoints * 0.2, precise: true)),
            0
        )
        XCTAssertEqual(accumulator.pending, -0.2, accuracy: 1e-9)
        XCTAssertEqual(
            accumulator.accumulate(.scroll(delta: -thresholds.preciseScrollPoints * 0.8, precise: true)),
            -1
        )
    }

    func testDirectionReversalNeverTakesBackAnAppliedStep() {
        var accumulator = ZoomGestureAccumulator()
        XCTAssertEqual(
            accumulator.accumulate(.scroll(delta: thresholds.preciseScrollPoints * 2, precise: true)),
            2
        )
        XCTAssertEqual(
            accumulator.accumulate(.scroll(delta: -thresholds.preciseScrollPoints * 0.5, precise: true)),
            0
        )
    }

    // MARK: - Configuration

    func testCustomThresholdsAreHonoredAndDegenerateOnesAreInert() {
        var accumulator = ZoomGestureAccumulator(
            thresholds: .init(preciseScrollPoints: 10, scrollLines: 2, magnification: 0.1)
        )
        XCTAssertEqual(accumulator.accumulate(.scroll(delta: 10, precise: true)), 1)
        XCTAssertEqual(accumulator.accumulate(.scroll(delta: 2, precise: false)), 1)
        XCTAssertEqual(accumulator.accumulate(.magnification(0.1)), 1)

        // A zero threshold must divide by nothing rather than produce infinity.
        var degenerate = ZoomGestureAccumulator(
            thresholds: .init(preciseScrollPoints: 0, scrollLines: 0, magnification: 0)
        )
        XCTAssertEqual(degenerate.accumulate(.scroll(delta: 100, precise: true)), 0)
        XCTAssertEqual(degenerate.accumulate(.scroll(delta: 100, precise: false)), 0)
        XCTAssertEqual(degenerate.accumulate(.magnification(100)), 0)
        XCTAssertEqual(degenerate.pending, 0)
    }
}
