/// How a secondary surface (a diff viewer, the 3-pane merge editor, a commit's
/// detail) is presented, abstracting the macOS "separate window" model from the
/// iOS "sheet / navigation push" model so the call sites that open these surfaces
/// share one decision point.
///
/// On macOS the editor opens each in its own `NSWindow` (`DiffWindowController` /
/// `MergeWindowController`); on iOS there are no separate windows, so a surface is
/// either pushed onto the navigation stack (compact width — iPhone, or a narrow
/// iPad split) or shown as a modal sheet (regular width — iPad).
///
/// View-layer only: the lone branch is platform-conditional (macOS ignores its
/// input entirely), so there is no platform-neutral pure logic to unit-test in
/// Core — the iOS compact/regular mapping is a trivial one-liner exercised by the
/// iOS view layer in later phases.
enum RoutePresentation: Equatable {
    /// A separate top-level window (macOS).
    case window
    /// A modal sheet over the current screen (iOS regular width).
    case sheet
    /// A push onto the active navigation stack (iOS compact width).
    case navigation

    /// The presentation to use given the current horizontal size class. macOS is
    /// always `.window`; iOS chooses `.navigation` when compact (push onto the
    /// stack) and `.sheet` when regular (present a sheet).
    static func preferred(isCompactWidth: Bool) -> RoutePresentation {
        #if os(macOS)
        return .window
        #else
        return isCompactWidth ? .navigation : .sheet
        #endif
    }
}
