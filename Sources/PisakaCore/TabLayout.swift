/// Pure, SwiftUI-free decision for how the open-tabs UI should be presented on
/// iOS, given the current horizontal size class and the user's `TabOrientation`
/// preference. Kept in Core — and unit-tested — because it is the one piece of
/// the iOS adaptive-tabs layout that is genuine branch logic (size class ×
/// orientation), while the actual SwiftUI strip/switcher views are thin wiring on
/// top (the `BottomPanel.toggled` / `RoutePresentation` precedent: testable
/// decision in Core, platform views in the app target).
///
/// macOS uses `TabListView` directly (vertical column or horizontal strip); this
/// helper exists only for the iOS view layer, but lives in Core so it stays
/// dependency-free and testable.
public enum TabLayout {
    /// The chosen presentation for the open-tabs UI.
    public enum Presentation: Equatable {
        /// Compact width (iPhone, or a narrow split): a single-row switcher
        /// (current file + a menu of the rest) rather than a full strip.
        case switcher
        /// Regular width with the horizontal preference: a scrolling horizontal
        /// strip of tabs above the editor.
        case horizontalStrip
        /// Regular width with the vertical preference: a vertical tab list in a
        /// narrow column beside the editor.
        case verticalColumn
    }

    /// Decide the tab presentation. Compact width always collapses to the
    /// space-efficient `.switcher` regardless of orientation (a strip/column does
    /// not fit a phone); at regular width the `TabOrientation` preference selects a
    /// horizontal strip or a vertical column.
    public static func presentation(
        isCompactWidth: Bool,
        orientation: TabOrientation
    ) -> Presentation {
        if isCompactWidth { return .switcher }
        switch orientation {
        case .horizontal: return .horizontalStrip
        case .vertical: return .verticalColumn
        }
    }
}
