#if os(macOS)
import AppKit
import SwiftUI

/// Owns the separate, non-modal diff windows opened on double-click (a Local
/// Changes row, or a commit's file in Git Log). Each `open(...)` creates a fresh
/// resizable `NSWindow` hosting a SwiftUI `DiffWindowContent` via an
/// `NSHostingController` and retains it for its lifetime; the window drops itself
/// from the retained set when the user closes it (release on close). Multiple
/// windows are allowed — there is no dedup/reuse (out of scope) — so double-clicking
/// the same file twice yields two windows.
///
/// `closeAll()` closes every retained window, mirroring
/// `TerminalSessionsModel.terminateAll()`; the app calls it on
/// `willTerminateNotification` so no diff windows linger past termination.
@MainActor
final class DiffWindowController {
    /// The currently-open diff windows, retained so they stay alive while shown.
    private var windows: [NSWindow] = []

    /// One `NSWindowDelegate` per window, forwarding `windowWillClose` back to the
    /// controller so the window is released. Held alongside the window because
    /// `NSWindow.delegate` is `weak`.
    private var delegates: [ObjectIdentifier: WindowDelegate] = [:]

    /// Open a new diff window titled `title` showing `content`.
    func open(title: String, content: DiffWindowContent) {
        let hosting = NSHostingController(rootView: content)
        let window = EscClosableWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 900, height: 600))
        window.center()

        let delegate = WindowDelegate { [weak self] closed in
            self?.release(closed)
        }
        window.delegate = delegate
        delegates[ObjectIdentifier(window)] = delegate
        windows.append(window)

        window.makeKeyAndOrderFront(nil)
    }

    /// Close every open diff window (app-termination path).
    func closeAll() {
        for window in windows {
            window.delegate = nil
            window.close()
        }
        windows.removeAll()
        delegates.removeAll()
    }

    /// Drop a window the user closed from the retained set.
    private func release(_ window: NSWindow) {
        windows.removeAll { $0 === window }
        delegates[ObjectIdentifier(window)] = nil
    }

    /// Forwards `windowWillClose` to the controller's release hook.
    private final class WindowDelegate: NSObject, NSWindowDelegate {
        private let onClose: (NSWindow) -> Void

        init(onClose: @escaping (NSWindow) -> Void) {
            self.onClose = onClose
        }

        func windowWillClose(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            onClose(window)
        }
    }
}

#endif
