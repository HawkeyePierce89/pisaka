#if os(macOS)
import AppKit
import SwiftUI

/// Owns the single, non-modal Find in Files window (⌘⇧F).
///
/// The `DiffWindowController` shape — a retained `EscClosableWindow` hosting a
/// SwiftUI root through an `NSHostingController`, released on close by a
/// per-window delegate (`NSWindow.delegate` is `weak`, so the delegate is held
/// alongside) — with one deliberate difference: there is exactly **one** window.
/// A diff is *about* a file, so several make sense; a project search is about the
/// project, so a repeat ⌘⇧F focuses the window that already exists instead of
/// stacking duplicates over one shared `ProjectSearchModel` (two windows would
/// fight over its single query and result list).
///
/// `closeAll()` is wired into the app's `willTerminateNotification` observer
/// alongside the diff/merge controllers, so no window lingers past termination.
@MainActor
final class ProjectSearchWindowController {
    private var window: NSWindow?
    private var hosting: NSHostingController<ProjectSearchView>?
    private var delegate: WindowDelegate?

    /// What to run as the window goes away, wired by the caller.
    ///
    /// The controller **records nothing itself**: it owns no model and no query,
    /// so it cannot know what was searched for. It only guarantees that every
    /// close path fires this hook exactly once — the user closing the window, and
    /// the termination sweep below, which invokes it explicitly before it drops
    /// the delegate that would otherwise have.
    private var onWillClose: () -> Void = {}

    /// Show the Find in Files window, creating it on first use and focusing it
    /// afterwards.
    ///
    /// An existing window has its root view *replaced* rather than reused as-is:
    /// the content carries the app's current closures (and, through them, whatever
    /// the app now considers the project root), so a window left open across a
    /// folder switch picks the new one up on the next ⌘⇧F. `onWillClose` is
    /// replaced on every call for the same reason, and from the same source.
    func show(content: ProjectSearchView, onWillClose: @escaping () -> Void = {}) {
        self.onWillClose = onWillClose

        if let window, let hosting {
            hosting.rootView = content
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: content)
        let window = EscClosableWindow(contentViewController: hosting)
        window.title = "Find in Files"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 520))
        window.center()

        let delegate = WindowDelegate { [weak self] in
            self?.onWillClose()
            self?.release()
        }
        window.delegate = delegate

        self.window = window
        self.hosting = hosting
        self.delegate = delegate

        window.makeKeyAndOrderFront(nil)
    }

    /// Close the window if it is open (app-termination path).
    ///
    /// The delegate is dropped before the close, so the hook is invoked here by
    /// hand: a query left in an open window is recorded when the app quits, just
    /// as it is when the user closes the window.
    func closeAll() {
        guard let window else { return }
        onWillClose()
        window.delegate = nil
        window.close()
        release()
    }

    /// Drop the window the user closed, so the next ⌘⇧F builds a fresh one.
    private func release() {
        window = nil
        hosting = nil
        delegate = nil
        onWillClose = {}
    }

    /// Forwards `windowWillClose` to the controller's close hook and its release.
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
