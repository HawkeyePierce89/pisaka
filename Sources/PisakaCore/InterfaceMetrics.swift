import Foundation

/// The semantic text styles the macOS chrome actually draws with, each carrying
/// the point size AppKit/SwiftUI give it on macOS at the system's default text
/// size.
///
/// The sweep that puts every chrome view on the interface scale needs a *number*
/// for each style, because a scaled style is no longer `Font.caption` — it is
/// "caption's size, times the scale". Stating the sizes here rather than in the
/// views keeps the whole sweep arithmetic-free and, more importantly, keeps the
/// 100% guarantee checkable in `swift test`: at scale 1 every style must return
/// exactly the size SwiftUI would have used, or adopting the metrics would
/// silently restyle the app for users who never touch zoom.
///
/// The set is closed to what the macOS views use today (`.caption`, `.callout`,
/// `.headline` and friends); adding a view that wants another style adds a case
/// here with its documented base size.
public enum InterfaceTextStyle: String, CaseIterable, Hashable, Sendable {
    case largeTitle
    case title
    case title2
    case title3
    case headline
    case subheadline
    case body
    case callout
    case footnote
    case caption
    case caption2

    /// The macOS point size of this style. These are AppKit's macOS values —
    /// notably *not* iOS's (body is 13 here, 17 there), which is why this type
    /// is documented as the macOS chrome's table even though it compiles
    /// everywhere.
    public var basePointSize: Double {
        switch self {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline: return 13
        case .subheadline: return 11
        case .body: return 13
        case .callout: return 12
        case .footnote: return 10
        case .caption: return 10
        case .caption2: return 10
        }
    }
}

/// The interface zone's scale turned into concrete point sizes.
///
/// One value type, injected into every macOS SwiftUI root through the
/// `\.interfaceMetrics` environment, so a view asks for `metrics.font(.caption)`
/// or `metrics.pt(8)` and never multiplies anything itself. Two reasons that is
/// worth a type: the rounding rules below are a decision (and a testable one),
/// and a view that multiplies inline is a view that will be missed the next time
/// the rules change.
///
/// The code and terminal zones deliberately do **not** come through here — they
/// are font sizes the user sets directly, and multiplying them by the interface
/// scale would make the two zones interact.
public struct InterfaceMetrics: Equatable, Hashable, Sendable {
    /// The scale, clamped to `ZoomScaleRule.interfaceScale` — so a corrupt or
    /// non-finite value can never reach a layout, and metrics stay inside the
    /// range the settings store already guarantees.
    public let scale: Double

    public init(scale: Double) {
        self.scale = ZoomScaleRule.interfaceScale.clamp(scale)
    }

    /// The resting metrics: every value is its unscaled base. Exactly what a
    /// view that has not been reached by the sweep still draws.
    public static let unscaled = InterfaceMetrics(scale: 1)

    /// The point size to draw `style` at.
    ///
    /// Rounded to a whole point: font rasterization is crispest on integral
    /// sizes, fractional sizes buy nothing at these magnitudes, and a whole
    /// number is what makes `scale == 1` return the base size *identically*
    /// rather than within a tolerance.
    public func font(_ style: InterfaceTextStyle) -> Double {
        guard scale != 1 else { return style.basePointSize }
        let scaled = (style.basePointSize * scale).rounded()
        return Swift.max(1, scaled)
    }

    /// A layout metric — a padding, a fixed frame, an icon size, a row height,
    /// a minimum window width — scaled.
    ///
    /// Rounded to a half point rather than a whole one: layout, unlike text,
    /// benefits from the finer grid (a 2pt padding at 80% would otherwise jump
    /// to 2 or collapse to 1), and a half point is exactly one device pixel on
    /// the Retina displays this app is drawn on, so the result still lands on a
    /// pixel boundary. Zero stays zero, and a non-zero metric never rounds away
    /// to nothing — a hairline separator must survive the bottom of the range.
    /// Negative metrics (an inset offset) scale symmetrically.
    ///
    /// At scale 1 the value is returned untouched rather than round-tripped
    /// through the grid, so "nothing changes at 100%" holds for *any* metric,
    /// not only for one already on it. Growing the scale never shrinks a metric
    /// and vice versa — monotonicity that rests on the input being on the
    /// half-point grid, which every layout constant in this app is; an off-grid
    /// metric can round up to the nearest half point on its way down, which is
    /// a half point of noise and no reordering worth defending against.
    public func pt(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        guard value != 0 else { return 0 }
        guard scale != 1 else { return value }
        let scaled = (value * scale * 2).rounded() / 2
        if scaled == 0 { return value < 0 ? -0.5 : 0.5 }
        return scaled
    }
}
