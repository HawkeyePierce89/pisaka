//
//  MainWindowFrameAutosave.swift
//  Pisaka
//
//  The explicit frame autosave mechanism for the main window.
//
//  Root cause: The framework-derived key for an autosave name embeds the mangled type
//  names of the window's content view. When a private context is involved (like
//  a sheet selector enum declared inside `App`, or an interface-scale modifier applied to it),
//  the name is rendered as `(unknown context at $<load-address>)`. Because this load
//  address is randomized by ASLR on every launch, the derived key is unstable.
//  Therefore, the main window uses an explicit, deliberately chosen frame autosave name,
//  so the key stops depending on modifier chain type names under ASLR or future refactors.
//

#if os(macOS)
import AppKit
import SwiftUI

/// The explicit autosave name used by the main window.
///
/// This name is chosen, not derived. The framework writes it into the preferences
/// domain as `NSWindow Frame MainWindow`. Renaming it later is a deliberate,
/// one-time loss of the saved frame.
private let mainWindowFrameAutosaveName = "MainWindow"

/// A non-drawing, hit-test-transparent marker attached purely to reach AppKit and
/// configure the main window's frame autosave name.
struct MainWindowFrameAutosave: NSViewRepresentable {
    func makeNSView(context: Context) -> MainWindowFrameAutosaveView {
        MainWindowFrameAutosaveView()
    }

    func updateNSView(_ nsView: MainWindowFrameAutosaveView, context: Context) {}
}

final class MainWindowFrameAutosaveView: NSView {
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

        guard let window = self.window else {
            return
        }

        if window.isSheet {
            window.setFrameAutosaveName("")
            return
        }

        // If this exact window already holds the name, it's a SwiftUI view recreation.
        // We shouldn't re-restore the frame because the user might have resized it since.
        if window.frameAutosaveName == mainWindowFrameAutosaveName {
            return
        }

        // Check if another window already holds the name globally to preserve
        // cascading for secondary windows in any multi-window scenarios.
        if NSApp.windows.contains(where: { $0.frameAutosaveName == mainWindowFrameAutosaveName && $0 != window }) {
            window.setFrameAutosaveName("")
            return
        }

        // Sizing interaction:
        // `viewDidMoveToWindow` is the first moment a window exists, firing before
        // the window is ordered front. The restored frame lands before first paint
        // and wins over the content's `minWidth`/`minHeight` floor, which is a minimum
        // and not a preferred size. The two do not fight, they compose: a saved frame
        // below the floor is clamped up by `setFrame`, which honours `minSize`; a saved
        // frame off the current display arrangement is constrained to a screen by the
        // same call.
        //
        // Escalation ladder (if a visible jump appears after first paint):
        // 1. Re-apply once on the next main-runloop turn.
        // 2. A one-shot `NSWindow.didBecomeKeyNotification` observer.
        // Neither is implemented, because neither is needed unless the manual check
        // in Post-Completion shows a visible jump.

        // Restore first: applies the saved frame if one exists (no-op on first run).
        // It is idempotent (re-applying the same frame is a no-op).
        _ = window.setFrameUsingName(mainWindowFrameAutosaveName)

        // Then adopt: registers the window to save on move/resize/close.
        // Adopting first can write the window's current (default) frame under the
        // name and destroy the value about to be read.
        guard window.setFrameAutosaveName(mainWindowFrameAutosaveName) else { return }
    }
}
#endif
