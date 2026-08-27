#if os(macOS)
import AppKit
import SwiftUI

/// The root cause: without an explicit frame autosave name set, the framework derives
/// the key from the mangled type name of the window's content view. Two types in that chain
/// are declared in private contexts, and a private context renders in a mangled name as
/// `(unknown context at <address>)`. That placeholder is a load address, randomized by ASLR
/// on every launch. This is why the name must be explicit.
///
/// This chosen name replaces the framework-derived key. The framework writes it into the
/// preferences domain as `NSWindow Frame MainWindow`. Renaming it later is a deliberate,
/// one-time loss of the saved frame.
private let mainWindowFrameAutosaveName = "MainWindow"

/// A non-drawing, hit-test-transparent marker attached to a view purely to reach AppKit
/// and restore/adopt the main window's frame autosave name.
struct MainWindowFrameAutosave: NSViewRepresentable {
    func makeNSView(context: Context) -> MainWindowFrameAutosaveView {
        return MainWindowFrameAutosaveView()
    }

    func updateNSView(_ nsView: MainWindowFrameAutosaveView, context: Context) {}
}

final class MainWindowFrameAutosaveView: NSView {
    private var isAdopted = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard !isAdopted, let window = window, !window.isSheet else {
            return
        }

        // The order is the rule: restore first, then adopt.

        // 1. Restore first.
        // Applies the saved frame if one exists and does nothing on a first run.
        // Sizing interaction: viewDidMoveToWindow is the first moment a window exists and it
        // fires before the window is ordered front, so the restored frame lands before first
        // paint and wins over the content's minWidth/minHeight floor, which is a minimum and
        // not a preferred size - the two do not fight, they compose (a saved frame below the
        // floor is clamped up by setFrame, which honours minSize; a saved frame off the current
        // display arrangement is constrained to a screen by the same call).
        // Escalation ladder (if a visible jump appears): re-applying once on the next
        // main-runloop turn, and only then a one-shot NSWindow.didBecomeKeyNotification observer
        // (neither is implemented, because neither is needed unless a visible jump shows).
        _ = window.setFrameUsingName(mainWindowFrameAutosaveName)

        // 2. Adopt.
        // Registers the window to save on move/resize/close.
        // Adopting first can write the window's current (default) frame under the name
        // and destroy the value about to be read.
        guard window.setFrameAutosaveName(mainWindowFrameAutosaveName) else {
            // Returning false means another window already holds the name: leave the one-shot
            // flag down so a later viewDidMoveToWindow retries.
            return
        }

        // Set the one-shot flag only on success.
        // Restore is idempotent anyway (re-applying the same frame is a no-op).
        // The flag exists so a SwiftUI re-parent cannot undo a resize the user has since made.
        isAdopted = true
    }
}
#endif
