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
public enum ChromeGeometry {
    /// A tree or list row's total height, hover highlight included.
    public static let rowHeight: Double = 24
    /// A row's horizontal padding, inside its highlight.
    public static let rowPaddingX: Double = 8
    /// How far one level of nesting insets a project-tree child from its parent.
    public static let treeIndentStep: Double = 16
    /// The largest corner radius the chrome uses. Chrome corners are either
    /// square or this; there is no intermediate radius.
    public static let cornerRadiusMax: Double = 6
    /// The width of a hairline separating two chrome zones.
    public static let hairlineWidth: Double = 1
    /// The horizontal tab strip's height.
    public static let tabStripHeight: Double = 32
    /// One row's height in the vertical tab column.
    public static let verticalTabRowHeight: Double = 28
    /// One tab's height in the bottom dock's tab bar.
    public static let dockTabRowHeight: Double = 28
    /// The window's bottom bar height.
    public static let bottomBarHeight: Double = 28
    /// The breadcrumb strip's height, above the editor.
    public static let breadcrumbHeight: Double = 24
    /// The side of a square toggle button in the bottom bar.
    public static let bottomBarToggleSide: Double = 22
    /// That toggle's corner radius.
    public static let bottomBarToggleRadius: Double = 4
    /// The thickness of the accent indicator marking the active tab.
    public static let accentIndicator: Double = 2
}
