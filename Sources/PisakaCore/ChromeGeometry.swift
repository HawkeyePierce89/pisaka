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
/// Some of them are insets, paddings, gaps or spacings rather than sizes
/// (`rowPaddingX`, `barPaddingX`, `panelHeaderPaddingX`, `dockTabRowPaddingX`,
/// `dockTabLabelPaddingX`, `buttonPaddingX`, `fieldPaddingX`,
/// `secondaryButtonPaddingX`, `segmentedControlInset`, `segmentGap`,
/// `segmentPaddingX`, `stepperPaddingX`, `stepperPartGap`, `switchInset`,
/// `settingsTabBarPaddingX`, `settingsTabGap`, `settingsTabLabelPaddingX`,
/// `settingsPagePadding`, `settingsRowSpacing`, `settingsLabelGap`) and they
/// are deliberately distinct tokens for distinct measurements, even where two
/// values coincide; see `barPaddingX`'s own comment. The list carries no count:
/// a stated count fell behind the table twice, and the test's set is the count.
///
/// The Preferences window's tab bar carries measurements of its own
/// (`settingsTabBarHeight`, `settingsTabBarPaddingX`, `settingsTabGap`,
/// `settingsTabLabelPaddingX`), deliberately *not* the dock tab row's: the two
/// rows are drawn from one pattern — an accent indicator under the selected
/// label, `accentIndicator` on both — but they are two surfaces measured by two
/// designs, and sharing a token would make one of them move whenever the other
/// is retuned. The shared shapes' radii are reused rather than duplicated: the
/// segmented control's outer corner is `cornerRadiusMax` and its segments'
/// `fieldCornerRadius`, and the stepper's box is `fieldCornerRadius` too.
public enum ChromeGeometry {
    /// A tree or list row's total height, hover highlight included.
    public static let rowHeight: Double = 24
    /// A row's horizontal padding, inside its highlight.
    public static let rowPaddingX: Double = 8
    /// How far one level of nesting insets a project-tree child from its parent.
    public static let treeIndentStep: Double = 16
    /// The largest corner radius the chrome uses. A chrome surface's corners are
    /// either square or this; each small control's radius is a token of its
    /// own, never one computed from this.
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
    /// A dialog's edge strip height: the commit dialog's header and the merge window's status strip.
    public static let dialogEdgeStripHeight: Double = 44
    /// The side of the chrome's square checkbox.
    public static let checkboxSide: Double = 14
    /// The chrome checkbox's corner radius.
    public static let checkboxCornerRadius: Double = 3
    /// The shared segmented control's outer height. Equal to `menuFieldHeight`,
    /// but a measurement of its own: no surface draws both today, and the menu
    /// field's 26 was chosen to agree with this should a page ever draw both.
    /// Its outer corner is `cornerRadiusMax`, not a token of its own.
    public static let segmentedControlHeight: Double = 26
    /// One segment's height inside the control. Its corner is
    /// `fieldCornerRadius`, not a token of its own.
    public static let segmentHeight: Double = 22
    /// The inset between the segmented control's edge and its segments.
    /// Equal to `segmentGap`, but the edge's inset, not the gap between two
    /// segments.
    public static let segmentedControlInset: Double = 2
    /// The gap between two adjacent segments. Equal to `segmentedControlInset`;
    /// see that token's comment.
    public static let segmentGap: Double = 2
    /// A segment's horizontal padding around its title. Equal to `barPaddingX`,
    /// but a segment's box around its title, not a strip's inset.
    public static let segmentPaddingX: Double = 12
    /// The shared stepper's height. Its corner is `fieldCornerRadius`, not a
    /// token of its own.
    public static let stepperHeight: Double = 24
    /// The stepper's horizontal padding inside its box. Equal to `rowPaddingX`,
    /// but a control's padding, not a row's.
    public static let stepperPaddingX: Double = 8
    /// The gap between the stepper's parts: the decrement glyph, the value and
    /// the increment glyph.
    public static let stepperPartGap: Double = 10
    /// The shared switch's track width.
    public static let switchWidth: Double = 36
    /// The shared switch's track height.
    public static let switchHeight: Double = 20
    /// The inset between the switch's track and its knob. Equal to
    /// `segmentedControlInset`, but the switch's own measurement.
    public static let switchInset: Double = 2
    /// The side of the switch's round knob. A token of its own: the knob is
    /// not computed from `switchHeight` and `switchInset`.
    public static let switchKnobSide: Double = 16
    /// The Preferences window's tab bar height. Deliberately *not*
    /// `dockTabRowHeight`; see the type's doc comment.
    public static let settingsTabBarHeight: Double = 36
    /// The settings tab bar's horizontal inset from the window edge. Equal to
    /// `treeIndentStep`, but a strip's inset, not a nesting step.
    public static let settingsTabBarPaddingX: Double = 16
    /// The gap between two settings tabs.
    public static let settingsTabGap: Double = 4
    /// A settings tab's horizontal padding around its label — the box the
    /// accent indicator spans. Equal to `dockTabLabelPaddingX`, but deliberately
    /// not it; see the type's doc comment.
    public static let settingsTabLabelPaddingX: Double = 10
    /// A settings page's padding on every edge.
    public static let settingsPagePadding: Double = 28
    /// The vertical spacing between two settings rows.
    public static let settingsRowSpacing: Double = 22
    /// The width of a settings row's label column.
    public static let settingsLabelColumnWidth: Double = 180
    /// The gap between a settings row's label column and its control. Equal to
    /// `settingsTabBarPaddingX`, but a column gap, not a strip's inset.
    public static let settingsLabelGap: Double = 16
    /// The shared menu field's height. Equal to `segmentedControlHeight`, but a
    /// measurement of its own — two shapes are two measurements. The design
    /// draws no menu field on a settings page and no surface draws both today;
    /// 26 is chosen to agree with the segmented control should a page ever do.
    public static let menuFieldHeight: Double = 26
}
