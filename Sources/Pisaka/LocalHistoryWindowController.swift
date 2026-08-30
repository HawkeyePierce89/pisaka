#if os(macOS)
import AppKit
import SwiftUI

/// Owns the single, non-modal Local History window (⌘⇧H).
///
/// `ProjectSearchWindowController` verbatim in shape — a retained
/// `EscClosableWindow` hosting a SwiftUI root through an `NSHostingController`,
/// released on close by a per-window delegate (`NSWindow.delegate` is `weak`, so
/// the delegate is held alongside) — and **one** window, for that controller's
/// reason with one of its own. There is a single `LocalHistoryBrowserModel`
/// behind it, carrying one target file, one revision list and one selection; two
/// windows over it would fight for that selection the way two Find in Files
/// windows would fight over one query. So the window is *retargeted* per file
/// rather than stacked: opening history for a second file replaces this window's
/// contents and focuses it.
///
/// The title carries the file, because the window's whole subject is one file and
/// the list inside it shows timestamps rather than names — a retarget that left
/// the title alone would be the one way to end up reading the wrong file's
/// revisions.
///
/// `closeAll()` is wired into the app's `willTerminateNotification` observer
/// alongside the diff/merge/search/browser/source-viewer controllers, so no
/// window lingers past termination.
@MainActor
final class LocalHistoryWindowController {
    private var window: NSWindow?
    private var hosting: NSHostingController<LocalHistoryView>?
    private var delegate: WindowDelegate?
    /// What to re-ask when the window becomes key. Held here rather than in the
    /// delegate because a retarget replaces it along with the root view — the
    /// closure carries the file the window now shows — while the delegate, like
    /// the window, outlives every retarget.
    private var onBecomeKey: (() -> Void)?

    /// Show the Local History window, creating it on first use and focusing it
    /// afterwards.
    ///
    /// An existing window has its root view *replaced* rather than reused as-is,
    /// for `ProjectSearchWindowController`'s reason: the content carries the
    /// app's current closures — and here also the file the title names — so a
    /// window left open across a retarget or a folder switch picks the new one
    /// up.
    ///
    /// `onBecomeKey` is what keeps the one part of this window that is an
    /// *action* from going stale with the rest of it: see
    /// `LocalHistoryBrowserModel.refreshSelection(currentText:)`. It is re-supplied
    /// on every retarget for the same reason the content is.
    func show(title: String, content: LocalHistoryView, onBecomeKey: @escaping () -> Void) {
        self.onBecomeKey = onBecomeKey
        if let window, let hosting {
            hosting.rootView = content
            window.title = title
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: content)
        let window = EscClosableWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 900, height: 560))
        window.center()

        let delegate = WindowDelegate(
            onClose: { [weak self] in self?.release() },
            onBecomeKey: { [weak self] in self?.onBecomeKey?() }
        )
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

    /// Drop the window the user closed, so the next ⌘⇧H builds a fresh one.
    private func release() {
        window = nil
        hosting = nil
        delegate = nil
        onBecomeKey = nil
    }

    /// Forwards `windowWillClose` to the controller's release hook and
    /// `windowDidBecomeKey` to its refresh hook.
    private final class WindowDelegate: NSObject, NSWindowDelegate {
        private let onClose: () -> Void
        private let onBecomeKey: () -> Void

        init(onClose: @escaping () -> Void, onBecomeKey: @escaping () -> Void) {
            self.onClose = onClose
            self.onBecomeKey = onBecomeKey
        }

        func windowWillClose(_ notification: Notification) {
            onClose()
        }

        func windowDidBecomeKey(_ notification: Notification) {
            onBecomeKey()
        }
    }
}

#endif
