#if os(macOS)
import AppKit

/// A non-modal `NSWindow` that closes itself on Esc.
///
/// Used for the separate diff (`DiffWindowController`) and merge
/// (`MergeWindowController`) windows. When the user presses Esc, AppKit dispatches
/// `cancelOperation(_:)` down the responder chain; a plain `NSWindow` ignores it,
/// so the window stays open. Overriding it to call `performClose(_:)` routes the
/// close through the standard `windowShouldClose`/`windowWillClose` path — exactly
/// like clicking the close button — so the owning controller's `windowWillClose`
/// delegate still fires and releases the window from its retained set (no new
/// leaks).
final class EscClosableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

#endif
