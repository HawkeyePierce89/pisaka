//
//  MainWindowChrome.swift
//  Pisaka
//
//  The main window's own chrome: the title bar's ground.
//
//  A sibling of `MainWindowFrameAutosave`, not a change to it. The two answer
//  unrelated questions about the same window — where it sits, and what colour
//  it is — and a marker that did both would tie a colour decision to a
//  persistence contract that has its own gating suite and its own long
//  explanation of why the framework's machinery is bypassed.
//
//  **Why the title bar is `bgPanel` while the content root paints `bgCanvas`.**
//  The window's ground *is* the canvas, and it is seen at the no-file-open
//  placeholder, which is where the role earns its name; the dock's own empty
//  states read as canvas but sit on `bgPanel`, which the panel slot paints
//  under them (`core-theme.md`'s part-three window-ground entry carries the
//  accounting). The title bar is not that surface — it is the topmost of the
//  window's panel strips, and it sits directly above the tab strip and the
//  sidebar header, both of which draw `bgPanel`. Painting it the canvas value
//  would draw a band one step off the strips it touches; painting it `bgPanel`
//  makes the three read as one surface, which is what they are.
//
//  **Why the colour is dynamic.** `ChromePalette.nsColor(_:)` answers a colour
//  that resolves against the effective appearance whenever it is drawn, so a
//  Theme change repaints the title bar with no appearance observer here and no
//  cached value to invalidate — the rule `ChromePalette` states for every
//  AppKit chrome surface, spent at one more call site.
//
//  The title *text* and the window buttons are left alone: both are drawn by
//  the framework against the window's appearance, which the Theme preference
//  already sets at the content root, so they follow without being told.
//

#if os(macOS)
import AppKit
import SwiftUI

/// A non-drawing, hit-test-transparent marker attached to the main scene's
/// content purely to reach the hosting window and apply the chrome below.
///
/// `MainWindowFrameAutosave`'s mould, deliberately: the scene's content is the
/// one place in this app that can name the main window, and a marker is how a
/// SwiftUI scene reaches it.
struct MainWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> MainWindowChromeView {
        MainWindowChromeView()
    }

    func updateNSView(_ nsView: MainWindowChromeView, context: Context) {}

    /// Apply the chrome to a window.
    ///
    /// Idempotent, and the one place the window's chrome is configured — which
    /// is what `ChromeThemeSourceGatingTests`' ninth rule pins: a second setter
    /// of `titlebarAppearsTransparent` would compete with this one, and nothing
    /// in the compiler can see two of them.
    static func apply(to window: NSWindow) {
        // Transparent, so the window's own background colour *is* the title
        // bar's ground. Without this the framework draws its own material over
        // the strip and the colour below never shows.
        window.titlebarAppearsTransparent = true
        window.backgroundColor = ChromePalette.nsColor(.bgPanel)
    }
}

final class MainWindowChromeView: NSView {
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
        // Sheets are skipped for the frame marker's reason: a sheet is hosted by
        // its own window, and the commit dialog's chrome is not the main
        // window's.
        guard let window = self.window, !window.isSheet else { return }
        MainWindowChrome.apply(to: window)
    }
}
#endif
