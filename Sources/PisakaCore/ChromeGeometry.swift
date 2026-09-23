import Foundation

/// The chrome's geometry tokens: the unscaled point values every chrome surface
/// measures itself with.
///
/// Two rules, both load-bearing:
///
/// 1. **Every token is scaled at its use site**, through
///    `InterfaceMetrics.scaled(_:)`. No view multiplies one of these numbers by
///    anything itself, and none of them is pre-scaled here — the interface zoom
///    is the view layer's business and the rounding it applies (a half-point
///    grid) only composes correctly when it is applied once, at the end.
///    **One stated exception: `hairlineWidth` on an AppKit code-zoom surface.**
///    A hairline is one point by definition — the thinnest rule the chrome
///    draws, not a measurement that grows with the interface — and a code-zoom
///    surface such as the line-number ruler has no `InterfaceMetrics` to ask in
///    the first place, the interface scale being a different zone from the one
///    it lives in (`core-zoom.md`). It is therefore used unscaled there, and the
///    next AppKit chrome surface follows this precedent rather than inventing a
///    second answer.
/// 2. **There is no font size here, and there will not be one.** The chrome's
///    type scale already exists as `InterfaceTextStyle` — `.body` is 13,
///    `.callout` 12 and `.subheadline` 11, exactly the three sizes the chrome
///    draws with — reached through `InterfaceMetrics.font(_:)`. A second table
///    of those numbers would be a second opinion about them.
///
/// The inventory below is the whole table, and it is pinned by set equality in
/// `ChromeThemeTests` — a token added here without its test fails the suite.
/// Six of them are insets rather than sizes (`rowPaddingX`, `barPaddingX`,
/// `panelHeaderPaddingX`, `dockTabRowPaddingX`, `dockTabLabelPaddingX`,
/// `buttonPaddingX`) and
/// they are deliberately distinct tokens for distinct measurements, even where
/// two values coincide; see `barPaddingX`'s own comment.
public enum ChromeGeometry {
    /// A tree or list row's total height, hover highlight included.
    public static let rowHeight: Double = 24
    /// A row's horizontal padding, inside its highlight.
    public static let rowPaddingX: Double = 8
    /// How far one level of nesting insets a project-tree child from its parent.
    public static let treeIndentStep: Double = 16
    /// The largest corner radius the chrome uses. A chrome surface's corners are
    /// either square or this; the only smaller radii are the small controls'
    /// own, each a token of its own (`bottomBarToggleRadius`,
    /// `buttonCornerRadius`) — never one computed from this.
    public static let cornerRadiusMax: Double = 6
    /// The width of a hairline separating two chrome zones.
    public static let hairlineWidth: Double = 1
    /// The horizontal tab strip's height.
    public static let tabStripHeight: Double = 32
    /// One row's height in the vertical tab column.
    public static let verticalTabRowHeight: Double = 28
    /// One tab's height in the bottom dock's tab bar.
    public static let dockTabRowHeight: Double = 28
    /// The project sidebar's header strip height.
    public static let sidebarHeaderHeight: Double = 32
    /// The window's bottom bar height.
    public static let bottomBarHeight: Double = 28
    /// The horizontal inset of a header or a bar — one measurement, drawn on the
    /// sidebar header and on the bottom bar. Deliberately *not* `rowPaddingX`
    /// (8), which is a row's padding inside its own highlight: a strip's inset
    /// from the window edge and a row's inset from its highlight are two
    /// measurements that happen to be small, not one measurement used twice.
    public static let barPaddingX: Double = 12
    /// The breadcrumb strip's height, above the editor.
    public static let breadcrumbHeight: Double = 24
    /// The side of a square toggle button in the bottom bar.
    public static let bottomBarToggleSide: Double = 22
    /// That toggle's corner radius.
    public static let bottomBarToggleRadius: Double = 4
    /// A dock panel's header strip height — the strip across the top of a
    /// panel's interior that carries its title and its own controls.
    public static let panelHeaderHeight: Double = 28
    /// A dock panel header's horizontal inset from the panel's edge. Its own
    /// measurement, like `barPaddingX`: a panel header is not the bottom bar.
    public static let panelHeaderPaddingX: Double = 14
    /// The dock tab row's horizontal inset from the dock's edge. Deliberately
    /// *not* `dockTabLabelPaddingX`, although the two are equal today: the row's
    /// inset from the window edge and a label's box around its text are two
    /// measurements, the argument `barPaddingX`'s comment makes.
    public static let dockTabRowPaddingX: Double = 10
    /// A dock tab's horizontal padding around its label — the box the accent
    /// indicator spans. Deliberately *not* `dockTabRowPaddingX`; see that
    /// token's comment.
    public static let dockTabLabelPaddingX: Double = 10
    /// The thickness of the accent indicator marking the active tab.
    public static let accentIndicator: Double = 2
    /// A chrome push button's horizontal padding around its label — one
    /// measurement, drawn on the Local Changes toolbar and on the pull-request
    /// rows. Deliberately *not* `dockTabRowPaddingX` / `dockTabLabelPaddingX`,
    /// although all three are equal today: a button's box around its label is
    /// a third measurement, the argument `barPaddingX`'s comment makes.
    public static let buttonPaddingX: Double = 10
    /// A chrome push button's corner radius.
    public static let buttonCornerRadius: Double = 5
    /// A text field's corner radius.
    public static let fieldCornerRadius: Double = 4
    /// A focused text field's border width.
    public static let fieldFocusedBorderWidth: Double = 2
    /// A text field's horizontal padding.
    public static let fieldPaddingX: Double = 10
    /// A secondary button's height.
    public static let secondaryButtonHeight: Double = 28
    /// A secondary button's horizontal padding.
    public static let secondaryButtonPaddingX: Double = 14
}
