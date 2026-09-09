import Foundation

/// How the editor/preview split divides the width available to a Markdown tab.
///
/// `BottomPanelHeightRule`'s shape, turned on its side and expressed as a
/// *fraction* rather than as a point width, for one reason: the panel's height
/// is a thing the user set once and wants back at that many points, while this
/// split is remembered across windows and across resizes, where a stored point
/// width would either overflow a narrower window or leave a gap in a wider one.
/// The fraction survives every resize; the widths are derived from it here.
///
/// Like the panel rule, `paneMinimum` arrives **already interface-scaled** — the
/// view scales it through its metrics and hands the rule a plain number — so
/// Core stays scale-agnostic and the rule can be reasoned about at 100%. The
/// fraction bounds carry no points and are therefore constants.
///
/// ## The two lower bounds, twice over
///
/// A legal fraction is at least `Self.minimumFraction` and at least
/// `paneMinimum / available`, and symmetrically at most `Self.maximumFraction`
/// and at most `1 - paneMinimum / available`. The proportional bound is the
/// aesthetic one — neither side may become a sliver of the window, whatever the
/// window's size — and it binds in every ordinary window; the point bound is the
/// structural one, and it binds only in a narrow one, where a fifth of the width
/// is already less than a pane can show anything in.
///
/// ## The degenerate case
///
/// When the window cannot hold two minimums — `available < 2 * paneMinimum`, a
/// narrow window at a large interface scale — the two bounds cross and there is
/// no legal fraction at all. The rule then answers `Self.defaultFraction`: the
/// split is even, both panes are equally too narrow, and no stored preference
/// silently becomes an invisible pane the user cannot drag back. It is the same
/// answer as for a non-finite or non-positive `available`, which is the same
/// question asked by a transient first layout pass.
///
/// Half of nothing is nothing, so `editorWidth + previewWidth <= available`
/// still holds on that path and the caller can use both as frame widths without
/// a second check.
public struct MarkdownPreviewWidthRule: Equatable, Hashable, Sendable {
    /// The narrowest the editor may be, as a share of the available width.
    public static let minimumFraction: Double = 0.2
    /// The widest the editor may be, as a share of the available width — the
    /// preview's own `minimumFraction`, read from the other end.
    public static let maximumFraction: Double = 0.8
    /// The resting split, and the answer whenever no legal fraction exists.
    public static let defaultFraction: Double = 0.5
    /// The shipping pane minimum, unscaled.
    public static let defaultPaneMinimum: Double = 240

    /// The fewest points each half keeps while the window can afford it.
    public let paneMinimum: Double

    public init(paneMinimum: Double = MarkdownPreviewWidthRule.defaultPaneMinimum) {
        self.paneMinimum = paneMinimum
    }

    /// `proposed` — the *editor's* share of the width — brought into the legal
    /// range for an area of `available` points.
    ///
    /// A non-finite proposal falls back to `defaultFraction` rather than
    /// surviving the clamp (`min`/`max` let NaN through every comparison, and a
    /// NaN frame width is a layout the view layer cannot recover from) and
    /// rather than falling back to a *bound*, which is what the panel rule does:
    /// there, the floor is the resting state; here, either bound is a pane
    /// squeezed to its limit, and an unusable input must not be answered with an
    /// extreme.
    public func fraction(proposed: Double, available: Double) -> Double {
        guard available.isFinite, available > 0 else { return Self.defaultFraction }
        let minimum = sanitized(paneMinimum)
        // The two bounds cross exactly when two minimums do not fit; the even
        // split is then the whole answer.
        guard available >= 2 * minimum else { return Self.defaultFraction }
        let lower = Swift.max(Self.minimumFraction, minimum / available)
        let upper = Swift.min(Self.maximumFraction, 1 - minimum / available)
        guard lower <= upper else { return Self.defaultFraction }
        guard proposed.isFinite else { return Self.defaultFraction }
        return Swift.min(Swift.max(proposed, lower), upper)
    }

    /// The fraction a divider drag has reached: `base` is the fraction captured
    /// at drag start, `dragTranslation` the gesture's cumulative *horizontal*
    /// translation measured in a coordinate space that does not move with the
    /// divider.
    ///
    /// The translation is *added* because the editor is on the left and grows
    /// rightward. Inside the bounds the mapping is one-to-one — N points of
    /// pointer travel is N points of editor width — which is the whole point of
    /// applying a cumulative translation to a fixed base.
    ///
    /// A non-finite translation, or a width there is nothing to divide, leaves
    /// the base where it is.
    public func fraction(base: Double, dragTranslation: Double, available: Double) -> Double {
        guard dragTranslation.isFinite, available.isFinite, available > 0 else {
            return fraction(proposed: base, available: available)
        }
        return fraction(proposed: base + dragTranslation / available, available: available)
    }

    /// What the editor gets, in points, for a fraction the rule has clamped
    /// itself — so no caller can turn an out-of-range preference into a width.
    public func editorWidth(fraction proposed: Double, available: Double) -> Double {
        guard available.isFinite, available > 0 else { return 0 }
        return available * fraction(proposed: proposed, available: available)
    }

    /// What the preview gets, in points: the rest of the same clamped split, so
    /// the two widths always sum to `available` exactly.
    public func previewWidth(fraction proposed: Double, available: Double) -> Double {
        guard available.isFinite, available > 0 else { return 0 }
        return available - editorWidth(fraction: proposed, available: available)
    }

    /// The width-free half of the clamp — everything that can be decided without
    /// knowing how wide the window is.
    ///
    /// This is what `SettingsStore` persists through: at write time there is no
    /// window, so the proportional bounds are the whole rule and the point
    /// minimums are re-applied by `fraction(proposed:available:)` at layout time.
    public static func clampFraction(_ value: Double) -> Double {
        guard value.isFinite else { return defaultFraction }
        return Swift.min(Swift.max(value, minimumFraction), maximumFraction)
    }

    /// A constant that arrived non-finite or negative contributes nothing rather
    /// than poisoning every comparison below it.
    private func sanitized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.max(value, 0)
    }
}
