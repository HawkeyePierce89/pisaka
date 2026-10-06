import Foundation

/// A sheet's scaled minimum and ideal sizes, fitted to the screen it opens on.
///
/// A sheet sized through the interface metrics grows with the scale, and at the
/// zone's 1.5 resting value the two largest — the commit dialog and the LeetCode
/// login sheet — no longer fit a 1440×900 display. The rule caps each value to
/// the room actually available, **one axis at a time**: a size that fits comes
/// back unchanged, so at scale 1.0 on an ordinary screen nothing moves.
///
/// The ideal is capped to the available size; the minimum is capped to that
/// capped ideal, so the answer never hands SwiftUI a minimum above its ideal —
/// including when the input already did. An available extent that is zero,
/// negative or non-finite is "unknown" (no screen to ask), and that axis is
/// left uncapped rather than collapsed to nothing.
public enum ScaledFrameFitRule {
    /// A width and a height in points.
    public struct Size: Equatable {
        public let width: Double
        public let height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    /// The fitted pair handed to `.frame(minWidth:idealWidth:minHeight:idealHeight:)`.
    public struct Frame: Equatable {
        public let minimum: Size
        public let ideal: Size

        public init(minimum: Size, ideal: Size) {
            self.minimum = minimum
            self.ideal = ideal
        }
    }

    /// `minimum` and `ideal` (already scaled) fitted to `available`; `nil`
    /// available means no screen is known and the input comes back unchanged
    /// apart from the minimum ≤ ideal ordering.
    public static func fit(minimum: Size, ideal: Size, available: Size?) -> Frame {
        let width = fitAxis(minimum: minimum.width, ideal: ideal.width, available: available?.width)
        let height = fitAxis(minimum: minimum.height, ideal: ideal.height, available: available?.height)
        return Frame(
            minimum: Size(width: width.minimum, height: height.minimum),
            ideal: Size(width: width.ideal, height: height.ideal)
        )
    }

    private static func fitAxis(minimum: Double, ideal: Double, available: Double?) -> (minimum: Double, ideal: Double) {
        var cappedIdeal = ideal
        if let available, available.isFinite, available > 0 {
            cappedIdeal = min(ideal, available)
        }
        return (min(minimum, cappedIdeal), cappedIdeal)
    }
}
