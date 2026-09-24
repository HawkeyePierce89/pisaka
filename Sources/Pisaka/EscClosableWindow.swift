#if os(macOS)
import AppKit
import PisakaCore

/// A non-modal `NSWindow` that closes itself on Esc and paints the chrome's
/// window ground.
///
/// Used for every secondary window: the diff (`DiffWindowController`), merge
/// (`MergeWindowController`), Local History (`LocalHistoryWindowController`),
/// out-of-project source viewer (`SourceViewerWindowController`), Find in Files
/// (`ProjectSearchWindowController`) and problem browser
/// (`LeetCodeBrowserWindowController`) windows. When the user presses Esc, AppKit
/// dispatches `cancelOperation(_:)` down the responder chain; a plain `NSWindow`
/// ignores it, so the window stays open. Overriding it to call `performClose(_:)`
/// routes the close through the standard `windowShouldClose`/`windowWillClose`
/// path — exactly like clicking the close button — so the owning controller's
/// `windowWillClose` delegate still fires and releases the window from its
/// retained set (no new leaks).
///
/// **The window's ground is set here, and only here.** A window's ground is a
/// property of the window, not of whichever controller builds it, and two
/// setters compete silently — the later one wins and nothing says so. It is
/// `bgPanel` through `ChromePalette.nsColor(_:)`, a *dynamic* colour, so an
/// appearance change recolours it with nothing watching, and a live resize never
/// shows the system window colour in the strip the content has not yet filled.
/// The sibling of `MainWindowChrome.swift`'s rule for the main window.
final class EscClosableWindow: NSWindow {
    /// The designated initializer, so it covers both construction paths:
    /// `NSWindow(contentViewController:)` is a convenience initializer that goes
    /// through it (five controllers), and the merge controller calls it directly
    /// with a rectangle.
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        backgroundColor = ChromePalette.nsColor(.bgPanel)
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

#endif
