#if os(macOS)
import AppKit

/// Shared Cmd+scroll → font-size-step handling for the code text views (the
/// editor, the diff panes, the merge panes).
///
/// When the Command modifier is held, step the shared editor font size by the
/// sign of the wheel's vertical delta (positive = larger) and *consume* the event
/// (no normal scroll), returning `true`. For an ordinary (no-Command) scroll it
/// returns `false` so the caller falls back to `super.scrollWheel(with:)`.
///
/// This deliberately lives on the *text* views, never on `MinimapView` — so it
/// can't conflict with the minimap's own wheel handler (which reports a scroll
/// offset) or with the diff/merge synced vertical scrolling: a Command scroll is
/// swallowed here before any of those paths see it.
@MainActor
func handleCommandScrollFontStep(_ event: NSEvent, step: ((Double) -> Void)?) -> Bool {
    guard event.modifierFlags.contains(.command) else { return false }
    // Consume the event even without a handler so a Command scroll never leaks
    // through as an ordinary scroll while the modifier is held.
    guard let step else { return true }
    let delta = event.scrollingDeltaY
    if delta > 0 {
        step(1)
    } else if delta < 0 {
        step(-1)
    }
    return true
}

#endif
