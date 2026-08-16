import Foundation

/// Turns the continuous deltas of a scroll or a pinch into the *same* discrete
/// steps the keyboard produces.
///
/// The three zoom zones have one arithmetic (`ZoomScaleRule`) and therefore one
/// grid of legal values; a trackpad that reports fractions of a point must
/// nonetheless land on that grid, or scroll-zoom and ⌘= would drift apart and
/// ⌘0 would be the only way back. This type is the bridge: it accumulates
/// normalized fractions of a step and hands back whole steps as they complete,
/// keeping the sub-step remainder so a slow drag feels continuous rather than
/// dropping everything below the threshold on the floor.
///
/// It is a value type with no knowledge of `NSEvent`: the app layer passes the
/// raw delta plus a flag saying which flavor of scroll it was, and *every*
/// decision — how many points make a step, how a wheel notch compares to a
/// trackpad swipe, how sensitive a pinch is — lives here, tested.
///
/// One accumulator per zone, owned by the app's zoom controller: the pointer
/// moving from the editor to the terminal mid-gesture must not carry the
/// editor's half-finished step into the terminal (see `reset()`).
public struct ZoomGestureAccumulator: Equatable, Hashable, Sendable {
    /// One continuous gesture sample, in the units the platform reports it.
    ///
    /// **Sign convention: positive means zoom in.** On macOS a scroll upwards
    /// and a pinch outwards both report positive deltas, so the app hands the
    /// event's value straight through and the convention is stated once, here.
    public enum Input: Equatable, Hashable, Sendable {
        /// A scroll delta. `precise` distinguishes the two flavors macOS
        /// reports: a trackpad (and a Magic Mouse) sends *points* of travel,
        /// many small samples per gesture, while an ordinary wheel sends
        /// *lines* — roughly one whole unit per detent. The two need different
        /// divisors, and choosing between them is this type's job, not the
        /// caller's: the app only forwards `NSEvent.hasPreciseScrollingDeltas`.
        case scroll(delta: Double, precise: Bool)
        /// A pinch's magnification delta, as a fraction of the current size.
        case magnification(Double)
    }

    /// How much of each input flavor makes one whole zoom step.
    public struct Thresholds: Equatable, Hashable, Sendable {
        /// Points of precise (trackpad) scroll per step.
        public let preciseScrollPoints: Double
        /// Lines of wheel scroll per step. One detent is one line on a typical
        /// mouse, so a notch is a step — which is what makes ⌃-wheel feel like
        /// the keyboard rather than like a slider.
        public let scrollLines: Double
        /// Magnification per step. Deliberately the smallest of the three: a
        /// pinch's whole comfortable travel is a magnification of about ±1, so
        /// a larger threshold would make the gesture reach two or three steps
        /// at full stretch and feel dead.
        public let magnification: Double

        public init(preciseScrollPoints: Double, scrollLines: Double, magnification: Double) {
            self.preciseScrollPoints = preciseScrollPoints
            self.scrollLines = scrollLines
            self.magnification = magnification
        }

        /// The shipped numbers. 24 points is about a third of a comfortable
        /// two-finger swipe, so a full swipe crosses two or three steps; 1 line
        /// is one wheel detent; 0.05 magnification gives a pinch roughly the
        /// same reach as that swipe.
        public static let standard = Thresholds(
            preciseScrollPoints: 24,
            scrollLines: 1,
            magnification: 0.05
        )
    }

    public let thresholds: Thresholds

    /// The unspent fraction of a step, signed. Exposed so the reset rules are
    /// observable; nothing outside this type may write it.
    public private(set) var pending: Double = 0

    public init(thresholds: Thresholds = .standard) {
        self.thresholds = thresholds
    }

    /// Fold one sample in and return the whole steps it completed (positive =
    /// zoom in). The fractional leftover stays in `pending` for the next
    /// sample.
    ///
    /// **Direction reversal drops the remainder.** A gesture that was pushing
    /// up and turns around starts from zero rather than first paying off the
    /// leftover of the other direction: otherwise the first backwards step
    /// arrives either instantly (leftover nearly a full step) or a whole
    /// threshold late, which reads as the gesture ignoring the user. Steps
    /// already applied are never taken back — only the unspent fraction is
    /// discarded.
    ///
    /// A non-finite or zero delta is ignored entirely, leaving `pending` alone:
    /// a `NaN` folded in would poison every later sample, and macOS does emit
    /// zero-delta scroll events at the momentum phase's tail.
    public mutating func accumulate(_ input: Input) -> Int {
        let fraction = ZoomGestureAccumulator.normalize(input, thresholds: thresholds)
        guard fraction.isFinite, fraction != 0 else { return 0 }

        if pending != 0, (fraction < 0) != (pending < 0) { pending = 0 }

        let total = pending + fraction
        let steps = ZoomGestureAccumulator.wholeSteps(total)
        pending = total - Double(steps)
        return steps
    }

    /// Forget the unspent fraction.
    ///
    /// Called when a gesture ends and when the pointer crosses out of the zone
    /// mid-gesture. Both are the same statement: a remainder only means
    /// anything within one continuous gesture over one zone, and carrying it
    /// across either boundary makes a later, unrelated flick step immediately.
    public mutating func reset() {
        pending = 0
    }

    /// Every input flavor expressed in the one unit the accumulator counts:
    /// fractions of a whole zoom step.
    private static func normalize(_ input: Input, thresholds: Thresholds) -> Double {
        switch input {
        case .scroll(let delta, let precise):
            let threshold = precise ? thresholds.preciseScrollPoints : thresholds.scrollLines
            guard threshold > 0 else { return 0 }
            return delta / threshold
        case .magnification(let delta):
            guard thresholds.magnification > 0 else { return 0 }
            return delta / thresholds.magnification
        }
    }

    /// The whole part of `total`, truncated towards zero, with a tolerance so
    /// that N samples of exactly one threshold each yield exactly N steps.
    /// Without it, `0.1 * 10` being 0.9999999999999999 would swallow the tenth
    /// step and leave a remainder that never spends.
    private static func wholeSteps(_ total: Double) -> Int {
        guard total.isFinite else { return 0 }
        let magnitude = (abs(total) + 1e-9).rounded(.down)
        guard magnitude >= 1 else { return 0 }
        // Guard the conversion: a single absurd delta must not trap on
        // `Int(_:)`'s overflow precondition.
        guard magnitude < Double(Int.max) else {
            return total < 0 ? Int.min : Int.max
        }
        return total < 0 ? -Int(magnitude) : Int(magnitude)
    }
}
