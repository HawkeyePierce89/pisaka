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
///
/// The title is the app's own label, centred in the title bar view, because
/// the framework draws its title leading-aligned whatever the toolbar state.
/// Its placement is measured on **one window created once for the suite** with
/// the app window's style mask: centred within a point, inside the title bar
/// band, following a resize, clear of the window buttons when truncated, and
/// still one label after a second `apply`.
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

    func testTheSystemTitleIsHiddenAndTheTitleApplied() {
        let window = makeWindow()
        MainWindowChrome.apply(to: window, title: "pisaka — ContentView.swift")
        XCTAssertEqual(window.title, "pisaka — ContentView.swift", "the window menu and accessibility read it here")
        XCTAssertEqual(
            window.titleVisibility, .hidden,
            "the framework draws its title leading-aligned, so the app hides it and draws its own centred label"
        )
    }

    // MARK: - The centred label's placement

    /// One window for the placement tests, created once for the suite — its
    /// style mask is the app window's.
    nonisolated(unsafe) private static var placementWindow: NSWindow?

    override static func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            placementWindow = window
        }
    }

    override static func tearDown() {
        MainActor.assumeIsolated {
            placementWindow?.close()
            placementWindow = nil
        }
        super.tearDown()
    }

    /// The label the chrome installed, its frame in window coordinates, and the
    /// title bar's band in window coordinates.
    private func titleLabel(in window: NSWindow) throws -> (label: NSTextField, frame: NSRect, band: NSRect) {
        let titleBar = try XCTUnwrap(window.standardWindowButton(.closeButton)?.superview)
        titleBar.layoutSubtreeIfNeeded()
        let labels = titleBar.subviews.filter { $0.identifier == MainWindowChrome.titleLabelIdentifier }
        XCTAssertEqual(labels.count, 1, "exactly one centred title label")
        let label = try XCTUnwrap(labels.first as? NSTextField)
        return (
            label,
            label.convert(label.bounds, to: nil),
            titleBar.convert(titleBar.bounds, to: nil)
        )
    }

    func testTheTitleLabelIsCentredInTheTitleBarAndFollowsAResize() throws {
        let window = try XCTUnwrap(Self.placementWindow)
        window.setContentSize(NSSize(width: 900, height: 600))
        MainWindowChrome.apply(to: window, title: "my-project — ContentView.swift")

        var placed = try titleLabel(in: window)
        XCTAssertEqual(placed.label.stringValue, "my-project — ContentView.swift")
        XCTAssertGreaterThan(placed.frame.width, 0, "the label has ink to centre")
        XCTAssertEqual(placed.frame.midX, window.frame.width / 2, accuracy: 1, "centred in the title bar")
        XCTAssertGreaterThanOrEqual(placed.frame.minY, placed.band.minY, "inside the title bar band")
        XCTAssertLessThanOrEqual(placed.frame.maxY, placed.band.maxY, "inside the title bar band")

        window.setContentSize(NSSize(width: 1200, height: 600))
        placed = try titleLabel(in: window)
        XCTAssertEqual(window.frame.width, 1200, accuracy: 1)
        XCTAssertEqual(placed.frame.midX, window.frame.width / 2, accuracy: 1, "the centre follows a resize")
    }

    func testALongTitleTruncatesClearOfTheWindowButtons() throws {
        let window = try XCTUnwrap(Self.placementWindow)
        window.setContentSize(NSSize(width: 900, height: 600))
        MainWindowChrome.apply(to: window, title: String(repeating: "very-long-project-name ", count: 20))

        let placed = try titleLabel(in: window)
        let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        let buttonsTrailing = zoom.convert(zoom.bounds, to: nil).maxX
        XCTAssertGreaterThanOrEqual(placed.frame.minX, buttonsTrailing, "never under the window buttons")
        XCTAssertEqual(placed.frame.midX, window.frame.width / 2, accuracy: 1, "a truncated title stays centred")
    }

    func testASecondApplyUpdatesTheOneLabel() throws {
        let window = try XCTUnwrap(Self.placementWindow)
        MainWindowChrome.apply(to: window, title: "first")
        MainWindowChrome.apply(to: window, title: "second")
        let placed = try titleLabel(in: window)
        XCTAssertEqual(placed.label.stringValue, "second", "a repeated apply updates the label")
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
        XCTAssertEqual(try labelString(in: window), MainWindowTitle.defaultTitle, "the label draws the same string")
        XCTAssertTrue(window.titlebarAppearsTransparent, "the title bar stays transparent")

        model.openFolder(url: folder)
        settle()
        XCTAssertEqual(window.title, "my-project", "a project with no file focused reads its name alone")
        XCTAssertEqual(try labelString(in: window), "my-project")

        let firstFile = try model.open(url: first)
        settle()
        XCTAssertEqual(window.title, "my-project — first.swift")

        _ = try model.open(url: second)
        settle()
        XCTAssertEqual(window.title, "my-project — second.md")

        model.select(firstFile.id)
        settle()
        XCTAssertEqual(window.title, "my-project — first.swift", "switching tabs re-titles the window")
        XCTAssertEqual(try labelString(in: window), "my-project — first.swift", "and re-labels it")
        XCTAssertTrue(window.titlebarAppearsTransparent, "re-titling leaves the title bar transparent")
    }

    /// The centred label's string.
    private func labelString(in window: NSWindow) throws -> String {
        let titleBar = try XCTUnwrap(window.standardWindowButton(.closeButton)?.superview)
        let label = titleBar.subviews.first { $0.identifier == MainWindowChrome.titleLabelIdentifier }
        return try XCTUnwrap(label as? NSTextField).stringValue
    }

    /// A few run-loop turns, enough for SwiftUI to deliver an observed change to
    /// the representable's `updateNSView`.
    private func settle() {
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
}
#endif
