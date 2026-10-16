#if os(macOS)
import AppKit
import XCTest
@testable import Pisaka

/// `TabMiddleClickView` claims a hit only for a center-button event, so every
/// other event falls through to the SwiftUI tab beneath it. The decision is the
/// static `claims(type:buttonNumber:)`; `hitTest` is asked with a synthesized
/// event through the view's injectable event source, so no window and no real
/// mouse are involved.
@MainActor
final class TabMiddleClickTests: XCTestCase {

    func testClaimsOnlyTheThreeOtherMouseTypesFromTheCenterButton() {
        for type: NSEvent.EventType in [.otherMouseDown, .otherMouseDragged, .otherMouseUp] {
            XCTAssertTrue(TabMiddleClickView.claims(type: type, buttonNumber: 2), "\(type)")
            XCTAssertFalse(TabMiddleClickView.claims(type: type, buttonNumber: 3), "\(type), button 3")
        }
        XCTAssertFalse(TabMiddleClickView.claims(type: .leftMouseDown, buttonNumber: 0))
        XCTAssertFalse(TabMiddleClickView.claims(type: .leftMouseUp, buttonNumber: 0))
        XCTAssertFalse(TabMiddleClickView.claims(type: .rightMouseDown, buttonNumber: 1))
        XCTAssertFalse(TabMiddleClickView.claims(type: .rightMouseUp, buttonNumber: 1))
        XCTAssertFalse(TabMiddleClickView.claims(type: .mouseMoved, buttonNumber: 2))
    }

    func testHitTestClaimsTheCenterButtonAndPassesEverythingElseThrough() throws {
        let view = TabMiddleClickView(frame: NSRect(x: 0, y: 0, width: 120, height: 30))
        let inside = NSPoint(x: 10, y: 10)

        let center = try mouseEvent(.otherMouseDown, button: .center)
        XCTAssertEqual(center.buttonNumber, 2)
        view.currentEvent = { center }
        XCTAssertTrue(view.hitTest(inside) === view, "a center-button press was not claimed")

        let left = try mouseEvent(.leftMouseDown, button: .left)
        view.currentEvent = { left }
        XCTAssertNil(view.hitTest(inside), "a left-button press was claimed")

        view.currentEvent = { nil }
        XCTAssertNil(view.hitTest(inside), "no event at all was claimed")
    }

    private func mouseEvent(_ type: CGEventType, button: CGMouseButton) throws -> NSEvent {
        let cgEvent = try XCTUnwrap(
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: button)
        )
        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }
}
#endif
