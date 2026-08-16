import Foundation

/// The arithmetic every zoom zone shares: a range, a resting value, and a step.
///
/// One rule type rather than three sets of constants, because the three zones
/// differ only in their numbers — "clamp a value", "step it by N", "reset it"
/// are the same three operations everywhere, and the keyboard, the scroll/pinch
/// path and the Preferences steppers must all produce values from the same
/// grid. `SettingsStore` owns the persisted values; this type owns what a legal
/// value *is*.
public struct ZoomScaleRule: Equatable, Hashable, Sendable {
    public let minimum: Double
    public let maximum: Double
    public let defaultValue: Double
    public let step: Double

    public init(minimum: Double, maximum: Double, defaultValue: Double, step: Double) {
        self.minimum = minimum
        self.maximum = maximum
        self.defaultValue = defaultValue
        self.step = step
    }

    /// `value` brought into `[minimum, maximum]`.
    ///
    /// A non-finite value (NaN/±inf) collapses to `defaultValue` rather than
    /// being returned as-is: `min`/`max` propagate NaN (every comparison with it
    /// is false), so a NaN would survive the clamp and then make a
    /// clamp-in-`didSet` property's `clamped != value` (NaN != NaN) always true,
    /// recursing without bound. That guard predates this type — it is the
    /// editor font size's, moved here so all three zones inherit it.
    ///
    /// Deliberately *not* snapped to the step grid: an arbitrary value arriving
    /// from a slider, a stored preference or an older build stays where the user
    /// put it, and only stepping snaps.
    public func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return Swift.min(Swift.max(value, minimum), maximum)
    }

    /// `value` moved by `steps` whole steps (positive = larger), snapped to the
    /// step grid and clamped.
    ///
    /// The grid is anchored at `defaultValue`, and the result is computed from a
    /// whole step *index* rather than by repeatedly adding `step` to the running
    /// value. That is what makes the round trip exact: with `step` 0.1, adding
    /// and subtracting in sequence drifts (1.0 + 0.1 - 0.1 is not 1.0 in binary
    /// floating point) and the interface scale would never return to exactly
    /// 100%, while an index is recomputed from scratch every time and the small
    /// final rounding erases the representation error. So N steps up followed by
    /// N steps down returns *exactly* the starting value, for any starting value
    /// already on the grid and within range.
    ///
    /// A value that is *off* the grid (a hand-edited preference, a slider drag)
    /// is snapped to the nearest grid point by the first step; that is a
    /// deliberate one-time correction rather than a lost step, since the
    /// alternative is a grid per stored value and a reset that never lands.
    public func stepped(_ value: Double, by steps: Double) -> Double {
        guard step > 0 else { return clamp(value) }
        let base = clamp(value)
        guard steps.isFinite else { return base }
        let index = ((base - defaultValue) / step).rounded()
        let moved = defaultValue + (index + steps.rounded()) * step
        return clamp(ZoomScaleRule.tidy(moved))
    }

    /// Strip the binary-floating-point residue a multiply-and-add leaves, so a
    /// scale reads back as 1.2 rather than 1.2000000000000002 — in Preferences,
    /// in `UserDefaults`, and in the equality the round-trip property asserts.
    /// Six decimals is far finer than any step this app ships and far coarser
    /// than the error being removed.
    private static func tidy(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        return (value * 1_000_000).rounded() / 1_000_000
    }

    /// The shared editor font size — the **code** zone, and the same
    /// `[8, 32]`/13/1 constants `SettingsStore` has always used, now stated once.
    public static let editorFont = ZoomScaleRule(
        minimum: 8,
        maximum: 32,
        defaultValue: 13,
        step: 1
    )

    /// The terminal font size. The same range and step as the editor's, and a
    /// default of 13 because that is `NSFont.systemFontSize` — what SwiftTerm
    /// already draws at — so a fresh install at 100% looks exactly as it does
    /// today and nothing about the terminal changes until the user zooms it.
    public static let terminalFont = ZoomScaleRule(
        minimum: 8,
        maximum: 32,
        defaultValue: 13,
        step: 1
    )

    /// The interface scale, as a multiplier. `1.0` is "unchanged", which is what
    /// makes every metric derived from it identical to today's constant at rest.
    /// The range stops at 0.8 below (further down and the chrome stops being
    /// hittable) and 2.0 above (beyond it the smallest usable window no longer
    /// fits an ordinary screen), and the 0.1 step gives ten notches across the
    /// useful part of the range.
    public static let interfaceScale = ZoomScaleRule(
        minimum: 0.8,
        maximum: 2.0,
        defaultValue: 1.0,
        step: 0.1
    )

    /// The rule backing each zone. The single place the mapping lives, so the
    /// app layer can step a zone without knowing which property holds it.
    public static func rule(for zone: ZoomZone) -> ZoomScaleRule {
        switch zone {
        case .code: return .editorFont
        case .terminal: return .terminalFont
        case .interface: return .interfaceScale
        }
    }
}
