#if os(macOS)
import AppKit
import SwiftUI

/// Owns the single, non-modal LeetCode problem browser window (⌘⇧B).
///
/// `ProjectSearchWindowController` verbatim in shape — a retained
/// `EscClosableWindow` hosting a SwiftUI root through an `NSHostingController`,
/// released on close by a per-window delegate (`NSWindow.delegate` is `weak`, so
/// the delegate is held alongside), with exactly **one** window — and for exactly
/// its reason. The browser has one `LeetCodeBrowserModel` behind it, carrying one
/// filter and one row list; two windows over it would fight over that single
/// filter the way two Find in Files windows would fight over one query. A repeat
/// ⌘⇧B therefore focuses the window that already exists.
///
/// `closeAll()` is wired into the app's `willTerminateNotification` observer
/// alongside the diff/merge/search/source-viewer controllers, so no window
/// lingers past termination.
@MainActor
final class LeetCodeBrowserWindowController {
    private var window: NSWindow?
    private var hosting: NSHostingController<LeetCodeBrowserView>?
    private var delegate: WindowDelegate?

    /// The window's AppKit number while it is open, or `nil`.
    ///
    /// Exposed for one caller: opening a problem from a row raises the editor
    /// window *behind* this one, which is an `orderWindow(.below, relativeTo:)`
    /// and so needs the number. The rule for which window that is stays in
    /// `PisakaApp`, where it is used.
    var windowNumber: Int? { window?.windowNumber }

    /// Show the browser window, creating it on first use and focusing it
    /// afterwards.
    ///
    /// An existing window has its root view *replaced* rather than reused as-is,
    /// for `ProjectSearchWindowController`'s reason: the content carries the app's
    /// current closures, so a window left open across whatever the app has since
    /// changed picks it up on the next ⌘⇧B.
    func show(content: LeetCodeBrowserView) {
        if let window, let hosting {
            hosting.rootView = content
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: content)
        let window = EscClosableWindow(contentViewController: hosting)
        window.title = "LeetCode Problems"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 820, height: 560))
        window.center()

        let delegate = WindowDelegate { [weak self] in self?.release() }
        window.delegate = delegate

        self.window = window
        self.hosting = hosting
        self.delegate = delegate

        window.makeKeyAndOrderFront(nil)
    }

    /// Close the window if it is open (app-termination path).
    func closeAll() {
        guard let window else { return }
        window.delegate = nil
        window.close()
        release()
    }

    /// Drop the window the user closed, so the next ⌘⇧B builds a fresh one.
    private func release() {
        window = nil
        hosting = nil
        delegate = nil
    }

    /// Forwards `windowWillClose` to the controller's release hook.
    private final class WindowDelegate: NSObject, NSWindowDelegate {
        private let onClose: () -> Void

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        func windowWillClose(_ notification: Notification) {
            onClose()
        }
    }
}

#endif
