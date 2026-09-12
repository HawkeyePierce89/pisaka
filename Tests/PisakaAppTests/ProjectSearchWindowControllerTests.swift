#if os(macOS)
import AppKit
import PisakaCore
import XCTest
@testable import Pisaka

/// `ProjectSearchWindowController`'s close hook — the Find in Files half of the
/// shared search query history's dismissal recording.
///
/// **The rule is about `NSWindow` teardown, so `swift test` cannot see it**: the
/// controller is AppKit, and what it guarantees is a *sequence* — the hook fires
/// on the window delegate's `windowWillClose`, fires on the termination sweep
/// because `closeAll()` invokes it by hand before dropping the delegate that
/// would otherwise have, and fires **once** either way. Every one of those is a
/// silent regression: dropping `closeAll()`'s call loses only the quit-time
/// recording, and firing twice records a query the user searched for once.
@MainActor
final class ProjectSearchWindowControllerTests: XCTestCase {

    private var controller: ProjectSearchWindowController!
    private var settings: SettingsStore!
    private var model: ProjectSearchModel!

    override func setUp() {
        super.setUp()
        controller = ProjectSearchWindowController()
        // A volatile domain: this suite never reads a preference, but a store
        // built on `.standard` would write the test host's own domain.
        settings = SettingsStore(defaults: UserDefaults(suiteName: "ProjectSearchWindowControllerTests")!)
        model = ProjectSearchModel()
    }

    override func tearDown() {
        controller.closeAll()
        controller = nil
        settings = nil
        model = nil
        super.tearDown()
    }

    /// The window's content. Nothing in this suite drives the view; it exists
    /// because the controller hosts one.
    private func content() -> ProjectSearchView {
        ProjectSearchView(
            model: model,
            settings: settings,
            root: { nil },
            onActivate: { _, _ in },
            onReplaceAll: { _, _ in nil }
        )
    }

    /// The shown window, found through `NSApp` because the controller keeps its
    /// own reference private — which is the point: the test drives the window the
    /// way the user does and leaves the controller to notice.
    /// Only a **visible** window qualifies: `isReleasedWhenClosed` is `false`, so
    /// the windows earlier tests closed can still be in `NSApp.windows` with a
    /// `nil` delegate, and closing one of those would assert nothing.
    private func shownWindow() throws -> NSWindow {
        let window = NSApp.windows.last { $0.title == "Find in Files" && $0.isVisible }
        return try XCTUnwrap(window, "the controller ordered no window front")
    }

    func testTheUserClosingTheWindowFiresTheHookOnce() throws {
        var calls = 0
        controller.show(content: content()) { calls += 1 }

        try shownWindow().close()

        XCTAssertEqual(calls, 1)
    }

    /// The delegate path releases the window, so the termination sweep that
    /// follows finds nothing to close — a query the user already dismissed is
    /// recorded once, not again at quit.
    func testTheSweepAfterAUserCloseRecordsNothing() throws {
        var calls = 0
        controller.show(content: content()) { calls += 1 }

        try shownWindow().close()
        controller.closeAll()

        XCTAssertEqual(calls, 1)
    }

    /// The termination sweep is the whole reason `closeAll()` invokes the hook
    /// itself: it drops the delegate before closing, so nothing else would.
    func testTheTerminationSweepFiresTheHookOnceAndOnlyWhileAWindowIsOpen() {
        var calls = 0
        controller.show(content: content()) { calls += 1 }

        controller.closeAll()
        controller.closeAll()

        XCTAssertEqual(calls, 1, "a second sweep has no window and must record nothing")
    }

    /// `show(...)` replaces the hook like it replaces the root view, and from the
    /// same source — so a window carried across a folder switch records through
    /// the current wiring, never the previous one's.
    func testShowingAgainReplacesTheHook() {
        var first = 0
        var second = 0
        controller.show(content: content()) { first += 1 }
        controller.show(content: content()) { second += 1 }

        controller.closeAll()

        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 1)
    }

    /// Each window gets its own recording: a reopened window that is closed again
    /// records a second time rather than reusing the first's spent hook.
    func testReopeningAndClosingRecordsAgain() {
        var calls = 0
        controller.show(content: content()) { calls += 1 }
        controller.closeAll()
        controller.show(content: content()) { calls += 1 }
        controller.closeAll()

        XCTAssertEqual(calls, 2)
    }
}

#endif
