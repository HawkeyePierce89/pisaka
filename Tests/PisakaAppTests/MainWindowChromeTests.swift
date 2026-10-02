#if os(macOS)
import AppKit
import SwiftUI
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
///
/// The title is driven the way the app drives it: the representable is hosted
/// in a titled window over a real `WorkspaceModel`, and the window's title is
/// read back as the workspace opens a folder, opens files and switches between
/// them — so a marker that applied the title once and never again fails here.
@MainActor
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
        MainWindowChrome.apply(to: window, title: "Pisaka")
        XCTAssertTrue(
            window.titlebarAppearsTransparent,
            "without the transparency the framework's own material covers the ground below it"
        )
    }

    func testTheGroundResolvesToThePanelRoleInBothAppearances() throws {
        let window = makeWindow()
        MainWindowChrome.apply(to: window, title: "Pisaka")
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

    /// The path the app actually takes: nobody calls `apply(to:)` — a marker is
    /// attached to the scene's content and reaches its window on its own.
    ///
    /// The two property tests above call the static method, so both stay green
    /// with `viewDidMoveToWindow()` emptied and the shipped window keeping its
    /// platform title bar. This one drives the attachment instead: a real
    /// window, asserted opaque and un-themed first, then a marker added to its
    /// content view — which is the whole trigger — and the same two properties
    /// read back.
    func testAttachingTheMarkerAppliesTheChromeToItsWindow() throws {
        let window = makeWindow()
        let content = try XCTUnwrap(window.contentView)
        XCTAssertFalse(
            window.titlebarAppearsTransparent,
            "a freshly built window is opaque — otherwise the attachment proves nothing"
        )

        let marker = MainWindowChromeView(title: "project — file.swift")
        content.addSubview(marker)

        XCTAssertTrue(
            window.titlebarAppearsTransparent,
            "the marker must configure the window it moved to, without anyone calling apply(to:)"
        )
        let background = try XCTUnwrap(window.backgroundColor)
        let systemAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        var resolved = NSColor.clear
        var expected = NSColor.clear
        systemAppearance.performAsCurrentDrawingAppearance {
            resolved = background.usingColorSpace(.sRGB) ?? .clear
            expected = ChromePalette.nsColor(.bgPanel, in: .dark).usingColorSpace(.sRGB) ?? .clear
        }
        XCTAssertEqual(
            resolved.redComponent, expected.redComponent, accuracy: 0.001,
            "the attached marker paints the window's ground the bgPanel role"
        )
        XCTAssertEqual(
            resolved.greenComponent, expected.greenComponent, accuracy: 0.001,
            "the attached marker paints the window's ground the bgPanel role"
        )
        XCTAssertEqual(
            resolved.blueComponent, expected.blueComponent, accuracy: 0.001,
            "the attached marker paints the window's ground the bgPanel role"
        )
    }

    /// The marker is a marker: it must not take a click meant for the content
    /// below it. `MainWindowFrameAutosave`'s own rule, and this file is in that
    /// file's mould deliberately.
    ///
    /// Its second rule — the `setAccessibilityElement(false)` in the
    /// initialiser — is **not** asserted here, and deliberately so: a plain
    /// `NSView` already answers `false`, so an assertion on it passes with the
    /// line deleted. The line stays in the source because it states the intent
    /// beside the hit-test override, but this suite cannot pin it and does not
    /// pretend to.
    func testTheMarkerIsTransparentToTheUser() {
        let view = MainWindowChromeView(title: "Pisaka")
        view.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(
            view.hitTest(NSPoint(x: 50, y: 50)),
            "a marker that takes a click swallows one meant for the window's content"
        )
    }

    func testTheTitleIsVisibleAndApplied() {
        let window = makeWindow()
        window.titleVisibility = .hidden
        MainWindowChrome.apply(to: window, title: "pisaka — ContentView.swift")
        XCTAssertEqual(window.title, "pisaka — ContentView.swift")
        XCTAssertEqual(window.titleVisibility, .visible, "the design's title is shown, centred by the framework")
        XCTAssertNil(window.toolbar, "a toolbar would move the title off centre")
    }

    func testTheHostedChromeTitlesTheWindowFromTheWorkspace() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainWindowChromeTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("my-project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let first = folder.appendingPathComponent("first.swift")
        let second = folder.appendingPathComponent("second.md")
        try "let a = 1\n".write(to: first, atomically: true, encoding: .utf8)
        try "# b\n".write(to: second, atomically: true, encoding: .utf8)

        let model = WorkspaceModel()
        let window = makeWindow()
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.close() }
        window.contentView = NSHostingView(rootView: Color.clear.background(MainWindowChrome(model: model)))
        settle()
        XCTAssertEqual(window.title, MainWindowTitle.defaultTitle, "no project open reads the app's default")
        XCTAssertTrue(window.titlebarAppearsTransparent, "the title bar stays transparent")

        model.openFolder(url: folder)
        settle()
        XCTAssertEqual(window.title, "my-project", "a project with no file focused reads its name alone")

        let firstFile = try model.open(url: first)
        settle()
        XCTAssertEqual(window.title, "my-project — first.swift")

        _ = try model.open(url: second)
        settle()
        XCTAssertEqual(window.title, "my-project — second.md")

        model.select(firstFile.id)
        settle()
        XCTAssertEqual(window.title, "my-project — first.swift", "switching tabs re-titles the window")
        XCTAssertTrue(window.titlebarAppearsTransparent, "re-titling leaves the title bar transparent")
    }

    /// A few run-loop turns, enough for SwiftUI to deliver an observed change to
    /// the representable's `updateNSView`.
    private func settle() {
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
}
#endif
