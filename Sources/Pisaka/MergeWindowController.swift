#if os(macOS)
import AppKit
import SwiftUI
import PisakaCore

/// Owns the separate, non-modal merge windows opened when the user resolves a
/// conflicted file (the "Resolve" entry in Local Changes). Each `open(...)` creates
/// a fresh resizable `NSWindow` hosting a SwiftUI `MergeView` via an
/// `NSHostingController`, retains it (and its `MergeModel`) for the window's
/// lifetime, and drops both when the user closes it (release on close). This
/// mirrors `DiffWindowController` exactly, adding only the per-window `MergeModel`
/// retention (the model is referenced by `MergeView` via `@ObservedObject`, which
/// does not retain it) and the Apply flow that closes the window on success.
///
/// `closeAll()` closes every retained window; the app calls it on
/// `willTerminateNotification` so no merge windows linger past termination.
@MainActor
final class MergeWindowController {
    /// The currently-open merge windows, retained so they stay alive while shown.
    private var windows: [NSWindow] = []

    /// The `MergeModel` backing each window, keyed by window identity, retained so
    /// it outlives the SwiftUI `@ObservedObject` reference.
    private var models: [ObjectIdentifier: MergeModel] = [:]

    /// One `NSWindowDelegate` per window, forwarding `windowWillClose` so the
    /// window/model are released (held here because `NSWindow.delegate` is `weak`).
    private var delegates: [ObjectIdentifier: WindowDelegate] = [:]

    /// Open a merge window titled `title` resolving `model`. `onApply` performs the
    /// full guarded apply (the owner suspends autosave / the disk-writer gate around
    /// `MergeModel.apply()`, then refreshes Local Changes and resyncs any open tab —
    /// the same coordination the revert path uses, which the controller cannot do
    /// because it owns neither the autosave controller nor the workspace) and returns
    /// whether it succeeded. On success the window closes automatically; a failed
    /// apply leaves it open with `model.errorMessage` shown.
    func open(
        title: String,
        model: MergeModel,
        settings: SettingsStore,
        onApply: @escaping () async -> Bool
    ) {
        let window = EscClosableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        let content = MergeView(model: model, settings: settings, onApply: { [weak self, weak window] in
            guard let window else { return }
            Task { @MainActor in
                if await onApply() {
                    self?.close(window)
                }
            }
        })

        window.contentViewController = NSHostingController(rootView: content)
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()

        let delegate = WindowDelegate { [weak self] closed in
            self?.release(closed)
        }
        window.delegate = delegate
        let id = ObjectIdentifier(window)
        delegates[id] = delegate
        models[id] = model
        windows.append(window)

        window.makeKeyAndOrderFront(nil)
    }

    /// Close every open merge window (app-termination path).
    func closeAll() {
        for window in windows {
            window.delegate = nil
            window.close()
        }
        windows.removeAll()
        models.removeAll()
        delegates.removeAll()
    }

    /// Close a specific window (the Apply-success path).
    private func close(_ window: NSWindow) {
        window.close()
    }

    /// Drop a window the user (or Apply) closed from the retained sets.
    private func release(_ window: NSWindow) {
        windows.removeAll { $0 === window }
        let id = ObjectIdentifier(window)
        models[id] = nil
        delegates[id] = nil
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
