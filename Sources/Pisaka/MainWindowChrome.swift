//
//  MainWindowChrome.swift
//  Pisaka
//
//  The main window's own chrome: the title bar's ground and its title.
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
//  **The title.** `MainWindowTitle` decides the string — `<project> — <file>`,
//  the project alone, or the app's default — and this marker is what applies
//  it, so the window keeps one configurer. The marker observes the workspace
//  for that reason alone; an update that leaves the string unchanged writes
//  nothing.
//
//  **Why the app draws the title itself.** Measured on macOS 27.0.1: the
//  framework draws a title-bar title leading-aligned for every toolbar state —
//  a bare titled window, every toolbar style, with and without a toolbar. The
//  title starts at x = 82 in a 900-point window, and no public property moves
//  it. So the framework's title is hidden — `titleVisibility` is `.hidden` on
//  purpose — and the app draws its own label centred in the title bar view,
//  on every supported release, so the placement no longer depends on what the
//  framework does. `window.title` is still written: the window menu, window
//  switching and accessibility read it from there, which is also why the label
//  is not an accessibility element. The label is found again by a fixed
//  identifier, so a repeated `apply` updates it and never adds a second one;
//  it uses the system title font at its system size, unscaled like the title it
//  replaces, truncates in the middle, and is held clear of the window buttons
//  by a width cap that keeps it centred. Its colour is `textPrimary`, dynamic
//  like the ground; the window buttons are drawn by the framework against the
//  window's appearance, which the Theme preference already sets at the content
//  root, so they follow without being told.
//

#if os(macOS)
import AppKit
import PisakaCore
import SwiftUI

/// A non-drawing, hit-test-transparent marker attached to the main scene's
/// content purely to reach the hosting window and apply the chrome below.
///
/// `MainWindowFrameAutosave`'s mould, deliberately: the scene's content is the
/// one place in this app that can name the main window, and a marker is how a
/// SwiftUI scene reaches it.
struct MainWindowChrome: NSViewRepresentable {
    /// The workspace the title is read from.
    @ObservedObject var model: WorkspaceModel

    func makeNSView(context: Context) -> MainWindowChromeView {
        MainWindowChromeView(title: title)
    }

    func updateNSView(_ nsView: MainWindowChromeView, context: Context) {
        nsView.title = title
    }

    /// The title `MainWindowTitle` gives the workspace as it is now.
    private var title: String {
        MainWindowTitle.text(
            projectRoot: model.projectRoot,
            focusedFileName: model.selectedFile?.displayName
        )
    }

    /// Apply the chrome to a window.
    ///
    /// Idempotent, and the one place the window's chrome is configured — which
    /// is what `ChromeThemeSourceGatingTests`' ninth rule pins: a second setter
    /// of `titlebarAppearsTransparent` would compete with this one, and nothing
    /// in the compiler can see two of them.
    static func apply(to window: NSWindow, title: String) {
        // Transparent, so the window's own background colour *is* the title
        // bar's ground. Without this the framework draws its own material over
        // the strip and the colour below never shows.
        window.titlebarAppearsTransparent = true
        window.backgroundColor = ChromePalette.nsColor(.bgPanel)
        window.titleVisibility = .hidden
        if window.title != title { window.title = title }
        applyTitleLabel(to: window, title: title)
    }

    /// The identifier the centred title label is found again by.
    static let titleLabelIdentifier = NSUserInterfaceItemIdentifier("PisakaCentredWindowTitle")

    /// Gap between the window buttons' trailing edge and the label's drawn
    /// frame. Internal so the placement suite asserts against this value.
    static let titleLabelButtonGap: CGFloat = 8

    /// Install — or, on a repeated call, update — the one centred title label
    /// in the title bar view, the close button's superview. A window without
    /// one gets no label.
    private static func applyTitleLabel(to window: NSWindow, title: String) {
        guard let close = window.standardWindowButton(.closeButton),
              let titleBar = close.superview else { return }
        // Each button's extent converted into the title bar view — the space
        // the label's constraints live in — rather than read off `frame`, which
        // is only that space while the button is a direct subview.
        let buttonsTrailing = [NSWindow.ButtonType.miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .filter { $0.isDescendant(of: titleBar) }
            .reduce(close.convert(close.bounds, to: titleBar).maxX) {
                max($0, $1.convert($1.bounds, to: titleBar).maxX)
            }

        if let label = titleBar.subviews.first(where: { $0.identifier == titleLabelIdentifier }) as? NSTextField {
            if label.stringValue != title { label.stringValue = title }
            if let cap = titleBar.constraints.first(where: { $0.identifier == titleLabelIdentifier.rawValue }) {
                cap.constant = widthInset(buttonsTrailing: buttonsTrailing, label: label)
            }
            return
        }

        let label = NSTextField(labelWithString: title)
        label.identifier = titleLabelIdentifier
        label.font = NSFont.titleBarFont(ofSize: 0)
        label.textColor = ChromePalette.nsColor(.textPrimary)
        label.lineBreakMode = .byTruncatingMiddle
        label.setAccessibilityElement(false)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleBar.addSubview(label)
        let cap = label.widthAnchor.constraint(
            lessThanOrEqualTo: titleBar.widthAnchor,
            constant: widthInset(buttonsTrailing: buttonsTrailing, label: label)
        )
        cap.identifier = titleLabelIdentifier.rawValue
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: titleBar.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            cap,
        ])
    }

    /// The width cap's constant: the label stays centred, so it gives up the
    /// buttons' extent plus the gap on both sides. Constraints act on the
    /// label's alignment rect, which a label field draws inside by an inset of
    /// its own (two points a side, measured on macOS 27) — so the drawn frame
    /// would land that much closer than the gap without the inset charged too.
    private static func widthInset(buttonsTrailing: CGFloat, label: NSTextField) -> CGFloat {
        let insets = label.alignmentRectInsets
        return -2 * (buttonsTrailing + titleLabelButtonGap + max(insets.left, insets.right))
    }
}

final class MainWindowChromeView: NSView {
    /// The title to apply; re-applied to the window whenever it changes.
    var title: String {
        didSet {
            guard title != oldValue else { return }
            applyToWindow()
        }
    }

    init(title: String) {
        self.title = title
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
        applyToWindow()
    }

    private func applyToWindow() {
        // Sheets are skipped for the frame marker's reason: a sheet is hosted by
        // its own window, and the commit dialog's chrome is not the main
        // window's.
        guard let window = self.window, !window.isSheet else { return }
        MainWindowChrome.apply(to: window, title: title)
    }
}
#endif
