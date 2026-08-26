import Foundation

/// What height the bottom dock panel may have, given how much room the window
/// body has for the editor + divider + panel column.
///
/// One rule type rather than arithmetic spread through the view, for the same
/// reason `ZoomScaleRule` exists: the drag and the rendered frame must agree on
/// every number, and "what is a legal panel height" is a decision, not glue.
/// The view owns the events and the coordinate space; this type owns the height.
///
/// All three constants arrive **already interface-scaled** — the view scales
/// them through its metrics and hands the rule plain numbers, so Core stays
/// scale-agnostic and the rule can be reasoned about at 100%.
///
/// ## The two upper bounds
///
/// The panel's ceiling is `min(available / 2, available - dividerHeight -
/// editorMinimum)`. Half the available space is the aesthetic bound — the dock
/// is a dock, not a second editor — and it binds in every ordinary window. The
/// reservation bound is the structural one: it is what guarantees the editor
/// keeps a few lines when the panel is greedy, and it binds only in a short
/// area, where half of what is left would already eat into the editor.
///
/// `editorMinimum` is deliberately a *small* reservation and deliberately not
/// the window's minimum content height. The window minimum is stated on the
/// window body root, where it applies whether or not a panel is shown; reusing
/// that much larger number here would collapse the panel to nothing in any
/// window near its own floor, which is the opposite of what a dock is for.
///
/// ## The degenerate case
///
/// When the ceiling falls below `floor` — a short area at a large interface
/// scale, where the scaled floor alone can exceed what the reservation leaves —
/// the rule returns the **ceiling**, not the floor. A floor that does not fit is
/// not a floor; honoring it would hand the layout a height the space cannot
/// hold, and an unclipped column would then paint over the bar below it. So the
/// panel shrinks, and `height <= available` holds unconditionally.
///
/// ## Why one floor for every panel
///
/// The panel content is rendered into a slot of exactly this height. A minimum
/// stated *inside* that slot can never be satisfied: the slot's height is
/// decided here, a child that demands more cannot make it grow, and the only
/// outcome available to that child is to overflow — over the divider above and
/// over the bar below. The degenerate case above makes this unconditional
/// rather than a tuning question: on that path *no* per-panel number could be
/// honored either. So the floor is a single number for every panel, nothing
/// below the rule states a minimum of its own, and nothing in the slot is lost
/// at the floor — every panel in it is a scrollable list, table or terminal.
///
/// That clamp is the *behavior* and the absent inner minimums are its
/// *precondition*; the view additionally clips the column, which is the
/// *guarantee* — arithmetic and honored proposals can both be wrong, a clip
/// cannot.
public struct BottomPanelHeightRule: Equatable, Hashable, Sendable {
    /// The smallest height the panel is dragged to while it fits (see the
    /// degenerate case, which goes below it).
    public let floor: Double
    /// The divider strip's own height, which the column spends before either
    /// side gets anything.
    public let dividerHeight: Double
    /// What the editor keeps when the panel is at its ceiling. Not the window
    /// minimum — see above.
    public let editorMinimum: Double

    public init(floor: Double, dividerHeight: Double, editorMinimum: Double) {
        self.floor = floor
        self.dividerHeight = dividerHeight
        self.editorMinimum = editorMinimum
    }

    /// The tallest the panel may be in an area of `available` points.
    ///
    /// Never negative and never more than `available`, so the caller can use it
    /// as a frame height without a second check. A non-finite or non-positive
    /// `available` — a transient first layout pass reports zero — collapses to
    /// zero rather than propagating: `min`/`max` let NaN survive a clamp (every
    /// comparison with it is false), and a NaN frame height is a layout the view
    /// layer cannot recover from. Same guard, same reason, as
    /// `ZoomScaleRule.clamp`.
    public func upperBound(available: Double) -> Double {
        guard available.isFinite, available > 0 else { return 0 }
        let reserved = sanitized(dividerHeight) + sanitized(editorMinimum)
        let bound = Swift.min(available / 2, available - reserved)
        return Swift.min(Swift.max(bound, 0), available)
    }

    /// `proposed` brought into the legal range for an area of `available` points.
    ///
    /// A non-finite proposal falls back to the effective floor rather than
    /// surviving the clamp, for the reason stated on `upperBound(available:)`.
    public func height(proposed: Double, available: Double) -> Double {
        let upper = upperBound(available: available)
        // The floor yields when it does not fit; `upper` is then both bounds.
        let lower = Swift.min(sanitized(floor), upper)
        guard proposed.isFinite else { return lower }
        return Swift.min(Swift.max(proposed, lower), upper)
    }

    /// The height a divider drag has reached: `base` is the height captured at
    /// drag start, `dragTranslation` the gesture's cumulative vertical
    /// translation measured in a coordinate space that does not move with the
    /// divider.
    ///
    /// The translation is *subtracted* because the panel grows upward: dragging
    /// up is a negative translation. Inside the bounds the mapping is one-to-one
    /// — N points of pointer travel is N points of height — which is the whole
    /// point of applying a cumulative translation to a fixed base.
    ///
    /// A non-finite translation leaves the base where it is: an unusable gesture
    /// value must not move the panel at all, and clamping it to the floor would
    /// do exactly that.
    public func height(base: Double, dragTranslation: Double, available: Double) -> Double {
        guard dragTranslation.isFinite else { return height(proposed: base, available: available) }
        return height(proposed: base - dragTranslation, available: available)
    }

    /// A constant that arrived non-finite or negative contributes nothing rather
    /// than poisoning every comparison below it.
    private func sanitized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.max(value, 0)
    }
}
