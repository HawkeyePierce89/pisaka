#if os(macOS)
import AppKit
import XCTest
import PisakaCore
@testable import Pisaka

/// The main window's chrome, applied to a real `NSWindow`.
///
/// `MainWindowChrome.apply(to:)` is two property assignments, which is exactly
/// why it is worth a suite: nothing in the compiler, and nothing in the static
/// gating rule that pins *where* the transparency is set, can see what the
/// window's ground actually resolves to. The colour is dynamic by design — the
/// rule `ChromePalette` states for every AppKit chrome surface — so the check
/// that matters is that it answers the palette's own value **in both
/// appearances**, which is the property a frozen, once-resolved colour would
/// fail while still looking right in whichever appearance the reviewer is in.
final class MainWindowChromeTests: XCTestCase {

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
    }

    func testTheTitleBarIsTransparent() {
        let window = makeWindow()
        XCTAssertFalse(
            window.titlebarAppearsTransparent,
            "a freshly built window is opaque — otherwise this suite would pass without the call"
        )
        MainWindowChrome.apply(to: window)
        XCTAssertTrue(
            window.titlebarAppearsTransparent,
            "without the transparency the framework's own material covers the ground below it"
        )
    }

    func testTheGroundResolvesToThePanelRoleInBothAppearances() throws {
        let window = makeWindow()
        MainWindowChrome.apply(to: window)
        let background = try XCTUnwrap(window.backgroundColor)

        for (appearance, name) in [
            (ChromeAppearance.dark, NSAppearance.Name.darkAqua),
            (ChromeAppearance.light, NSAppearance.Name.aqua),
        ] {
            let systemAppearance = try XCTUnwrap(NSAppearance(named: name))
            var resolved = NSColor.clear
            var expected = NSColor.clear
            systemAppearance.performAsCurrentDrawingAppearance {
                resolved = background.usingColorSpace(.sRGB) ?? .clear
                expected = ChromePalette.nsColor(.bgPanel, in: appearance)
                    .usingColorSpace(.sRGB) ?? .clear
            }
            XCTAssertEqual(
                resolved.redComponent, expected.redComponent, accuracy: 0.001,
                "the window's ground is the bgPanel role's \(appearance) value"
            )
            XCTAssertEqual(
                resolved.greenComponent, expected.greenComponent, accuracy: 0.001,
                "the window's ground is the bgPanel role's \(appearance) value"
            )
            XCTAssertEqual(
                resolved.blueComponent, expected.blueComponent, accuracy: 0.001,
                "the window's ground is the bgPanel role's \(appearance) value"
            )
        }
    }

    /// The marker is a marker: it must not take a click meant for the content
    /// below it, and it must not appear to assistive technology as an element of
    /// its own. `MainWindowFrameAutosave`'s two rules, and it is in that file's
    /// mould deliberately.
    func testTheMarkerIsTransparentToTheUser() {
        let view = MainWindowChromeView()
        view.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(
            view.hitTest(NSPoint(x: 50, y: 50)),
            "a marker that takes a click swallows one meant for the window's content"
        )
        XCTAssertFalse(
            view.isAccessibilityElement(),
            "a non-drawing marker announces nothing"
        )
    }
}
#endif
