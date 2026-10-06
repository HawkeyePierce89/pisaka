//
//  MainWindowFrameAutosave.swift
//  Pisaka
//
//  The main window's frame persistence: remember the size and position across
//  launches, under one stable key.
//
//  Why the standard window-frame autosave cannot do this here (both halves
//  verified live in the preferences domain):
//
//  1. With no explicit autosave name set, the framework derives the save key
//     from the mangled type name of the window's content view. Two types in
//     that chain are declared in private contexts (the sheet-selector enum
//     inside the `App`, and the interface-scale modifier applied to the sheet
//     content), and a private context renders in a mangled name as
//     `(unknown context at $<load-address>)` — a load address randomized by
//     ASLR on every launch. Each launch therefore saves under a fresh one-off
//     key and restores nothing.
//
//  2. Adopting an explicit autosave name does not fix it: the scene's window
//     *redirects the save machinery itself*. The adopted name sticks on the
//     window, but every frame save — the automatic ones and even a manual
//     `saveFrame(usingName:)` with the explicit name — lands under the derived
//     per-launch key anyway, and the explicit key is never written.
//
//  So the marker below bypasses that machinery entirely: it restores the frame
//  from its own defaults key on window attach, and writes the frame descriptor
//  back under that key itself on every move, resize and close. The descriptor
//  string carries the screen geometry, so restoring onto a changed display
//  arrangement is constrained to a screen by the same call that applies it,
//  and the content's `minWidth`/`minHeight` floor still clamps from below —
//  the two compose rather than fight.
//
//  With no saved frame at all (a first launch, or the key deleted), the window
//  opens where Core's `MainWindowInitialFrameRule` says — about 75% of the
//  screen's visible frame, centred, never below the content floor — instead of
//  the scene's small default. That is the missing-key path *only*: a saved
//  descriptor always wins, and `MainWindowFrameSourceGatingTests` pins that the
//  descriptor is applied first and the rule reached only past its `guard`.
//

#if os(macOS)
import AppKit
import PisakaCore
import SwiftUI

/// A non-drawing, hit-test-transparent marker attached to the main scene's
/// content purely to reach the hosting window and wire up the frame
/// persistence above.
///
/// Holds the shared store only to read the window's content floor at the
/// current interface scale (`ContentView.windowFloor`), which the first-launch
/// frame must not undercut.
struct MainWindowFrameAutosave: NSViewRepresentable {
    let settings: SettingsStore

    func makeNSView(context: Context) -> MainWindowFrameAutosaveView {
        let view = MainWindowFrameAutosaveView()
        view.contentMinimum = ContentView.windowFloor(settings.interfaceMetrics)
        return view
    }

    func updateNSView(_ nsView: MainWindowFrameAutosaveView, context: Context) {
        nsView.contentMinimum = ContentView.windowFloor(settings.interfaceMetrics)
    }
}

final class MainWindowFrameAutosaveView: NSView {
    /// The content floor the first-launch frame is raised to. Read once, at
    /// adoption; a later change only matters to a window that is already sized.
    var contentMinimum: CGSize = .zero

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = self.window, !window.isSheet else { return }
        MainWindowFramePersistence.adopt(window, contentMinimum: contentMinimum)
    }
}

/// The persistence itself, deliberately not tied to the marker view's
/// lifetime: the view can be recreated by the framework at any time, and a
/// recreation must neither re-restore the frame (yanking the window back over
/// a resize the user has since made) nor tear the observers down.
private enum MainWindowFramePersistence {
    /// The one chosen defaults key. Chosen, not derived — renaming it later is
    /// a deliberate, one-time loss of the saved frame. It deliberately does
    /// not use the `NSWindow Frame` prefix: that namespace belongs to the
    /// machinery this type exists to bypass.
    private static let defaultsKey = "MainWindowFrame"

    /// The windows already adopted, weakly held. Window-side state, so a
    /// recreated marker view finds the window configured and does nothing.
    private static let adopted = NSHashTable<NSWindow>.weakObjects()

    /// Observer tokens, kept for the app's lifetime. The app has exactly one
    /// main window per run, and the observers are keyed to that window object,
    /// so there is nothing to unregister early.
    private static var observers: [NSObjectProtocol] = []

    static func adopt(_ window: NSWindow, contentMinimum: CGSize) {
        guard !adopted.contains(window) else { return }
        adopted.add(window)

        // Restore before first paint: `viewDidMoveToWindow` fires before the
        // window is ordered front, so the saved frame lands invisibly. With no
        // saved frame the first-launch frame is computed once, here, so both
        // restores below apply the same answer.
        let initialFrame = firstLaunchFrame(for: window, contentMinimum: contentMinimum)
        restore(window, initialFrame: initialFrame)

        // The scene's own window setup continues after this callback and can
        // size the window once more. Re-apply on the next main-runloop turn
        // (idempotent when nothing intervened), and only then start observing
        // — observing from the start would let that setup-time resize
        // overwrite the saved frame with the default one.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            restore(window, initialFrame: initialFrame)
            observe(window)
        }
    }

    /// A saved descriptor always wins; only when the key is missing is the
    /// precomputed first-launch frame applied (and only if Core had an answer).
    private static func restore(_ window: NSWindow, initialFrame: NSRect?) {
        guard let descriptor = UserDefaults.standard.string(forKey: defaultsKey) else {
            if let initialFrame { window.setFrame(initialFrame, display: false) }
            return
        }
        window.setFrame(from: descriptor)
    }

    /// Core's first-launch frame for `window` on its screen, or `nil` when a
    /// frame is saved (the rule is not asked at all) or no screen is known.
    private static func firstLaunchFrame(for window: NSWindow, contentMinimum: CGSize) -> NSRect? {
        guard UserDefaults.standard.string(forKey: defaultsKey) == nil else { return nil }
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return nil }
        let minimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentMinimum)).size
        let frame = MainWindowInitialFrameRule.frame(
            visible: .init(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height),
            minimumWidth: minimum.width,
            minimumHeight: minimum.height
        )
        return frame.map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    }

    private static func observe(_ window: NSWindow) {
        let names: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.willCloseNotification,
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { notification in
                guard let window = notification.object as? NSWindow else { return }
                UserDefaults.standard.set(window.frameDescriptor, forKey: defaultsKey)
            }
            observers.append(token)
        }
    }
}
#endif
