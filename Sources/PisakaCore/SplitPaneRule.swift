import Foundation

/// What extent the leading (or top) pane of a two-pane split may have, given
/// how much room the two panes share and where a divider drag has reached.
///
/// The shared split's one sizing decision, kept in Core for the reason
/// `BottomPanelHeightRule` is: the drag and the rendered frame must agree on
/// every number, and "what is a legal pane extent" is a decision, not glue. The
/// view owns the events and the coordinate space; this type owns the extent.
///
/// Every value arrives **already interface-scaled** — the view scales the
/// bounds its caller states and hands the rule plain numbers, so Core stays
/// scale-agnostic.
///
/// ## What `available` is
///
/// The extent the *two panes* share along the split's axis — the divider's own
/// strip already deducted by the caller. So `leading + trailing == available`
/// whenever the trailing pane takes what is left, and the rule never needs to
/// know how wide the strip is.
///
/// ## When space runs short
///
/// The leading pane's ceiling is `min(maximum, available - trailingMinimum)`.
/// When that falls below the leading pane's own `minimum` — a narrow window —
/// the **trailing pane's minimum wins**: the rule returns the ceiling, not the
/// floor, so the trailing pane keeps what it needs and the leading one is the
/// pane squeezed. When even the trailing minimum does not fit, the leading pane
/// collapses to zero rather than going negative. Either way the answer lies in
/// `0...available`, so the caller can use it as a frame without a second check.
public struct SplitPaneRule: Equatable, Hashable, Sendable {
    /// The smallest the leading pane is dragged to while it fits.
    public let minimum: Double
    /// Where the leading pane starts before anything has been dragged.
    public let ideal: Double
    /// The largest the leading pane is dragged to.
    public let maximum: Double
    /// What the trailing pane keeps when the leading pane is at its ceiling.
    public let trailingMinimum: Double

    public init(minimum: Double, ideal: Double, maximum: Double, trailingMinimum: Double) {
        self.minimum = minimum
        self.ideal = ideal
        self.maximum = maximum
        self.trailingMinimum = trailingMinimum
    }

    /// The largest the leading pane may be when the panes share `available`.
    ///
    /// A non-finite or non-positive `available` — a transient first layout pass
    /// reports zero — collapses to zero rather than propagating a NaN through
    /// the clamp, `BottomPanelHeightRule.upperBound(available:)`'s guard.
    public func upperBound(available: Double) -> Double {
        guard available.isFinite, available > 0 else { return 0 }
        let bound = Swift.min(sanitized(maximum), available - sanitized(trailingMinimum))
        return Swift.min(Swift.max(bound, 0), available)
    }

    /// `proposed` brought into the legal range when the panes share `available`.
    /// A non-finite proposal falls back to the ideal.
    public func extent(proposed: Double, available: Double) -> Double {
        let upper = upperBound(available: available)
        // The floor yields when it does not fit: the trailing minimum wins.
        let lower = Swift.min(sanitized(minimum), upper)
        let wanted = proposed.isFinite ? proposed : sanitized(ideal)
        return Swift.min(Swift.max(wanted, lower), upper)
    }

    /// The extent a divider drag has reached: `base` is the extent captured at
    /// drag start, `dragTranslation` the gesture's cumulative translation along
    /// the axis, measured in a space that does not move with the divider.
    ///
    /// The leading pane is the one before the divider, so a positive
    /// translation — rightward or downward — grows it, one point per point
    /// inside the bounds. A zero translation, as on a drag's opening frame,
    /// changes nothing beyond the clamp the base already satisfies, and a
    /// non-finite one leaves the base where it is.
    public func extent(base: Double, dragTranslation: Double, available: Double) -> Double {
        guard dragTranslation.isFinite else { return extent(proposed: base, available: available) }
        return extent(proposed: base + dragTranslation, available: available)
    }

    /// A bound that arrived non-finite or negative contributes nothing rather
    /// than poisoning every comparison below it.
    private func sanitized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.max(value, 0)
    }
}
