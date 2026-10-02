import Foundation

/// The vertical tab column's width bounds in its split view.
///
/// The column's minimum, ideal and maximum are interface-zone tokens scaled
/// like every other pane width, with one extra bound on the maximum: the column
/// never claims more than a third of the window, so on a narrow window it
/// cannot crowd the editor out. The answer is always a valid frame — the third
/// of a very narrow window can fall below the scaled minimum, and the maximum
/// is then held at the minimum, with the ideal clamped between the two, rather
/// than handing SwiftUI a frame whose maximum is below its minimum.
public enum TabColumnWidthRule {
    /// The column's unscaled minimum width.
    public static let minimum: Double = 180
    /// The column's unscaled default width.
    public static let ideal: Double = 220
    /// The column's unscaled maximum width, before the window bound.
    public static let maximum: Double = 320
    /// The share of the window's width the column may take at most.
    public static let windowFraction: Double = 1.0 / 3.0

    public struct Bounds: Equatable {
        public let minimum: Double
        public let ideal: Double
        public let maximum: Double

        public init(minimum: Double, ideal: Double, maximum: Double) {
            self.minimum = minimum
            self.ideal = ideal
            self.maximum = maximum
        }
    }

    /// The bounds under `metrics` in a window `windowWidth` points wide. The
    /// three tokens scale through `metrics.pt`, the grid every other pane
    /// width is on; the window's third is not a token and is taken as it is.
    public static func bounds(metrics: InterfaceMetrics, windowWidth: Double) -> Bounds {
        let scaledMinimum = metrics.pt(minimum)
        let maximum = max(scaledMinimum, min(metrics.pt(Self.maximum), windowWidth * windowFraction))
        let ideal = min(max(metrics.pt(Self.ideal), scaledMinimum), maximum)
        return Bounds(minimum: scaledMinimum, ideal: ideal, maximum: maximum)
    }
}
