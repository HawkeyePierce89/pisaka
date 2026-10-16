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

    /// A key event must not be asked its `buttonNumber` (that raises), and a
    /// fourth button is not the center one: neither is claimed.
    func testHitTestPassesKeyEventsAndOtherButtonsThrough() throws {
        let view = TabMiddleClickView(frame: NSRect(x: 0, y: 0, width: 120, height: 30))
        let inside = NSPoint(x: 10, y: 10)

        let key = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
        ))
        view.currentEvent = { key }
        XCTAssertNil(view.hitTest(inside), "a key event was claimed")

        let fourth = try otherMouseEvent(.otherMouseDown, button: 3, at: inside)
        view.currentEvent = { fourth }
        XCTAssertNil(view.hitTest(inside), "a fourth-button press was claimed")
    }

    /// The tab closes on a center-button release inside it, and on nothing else.
    func testReleaseInsideClosesAndReleaseOutsideOrAnotherButtonDoesNot() throws {
        let view = TabMiddleClickView(frame: NSRect(x: 0, y: 0, width: 120, height: 30))
        var closes = 0
        view.onMiddleClick = { closes += 1 }

        view.otherMouseUp(with: try otherMouseEvent(.otherMouseUp, button: 2, at: NSPoint(x: 10, y: 10)))
        XCTAssertEqual(closes, 1, "a release inside did not close")
        view.otherMouseUp(with: try otherMouseEvent(.otherMouseUp, button: 2, at: NSPoint(x: 500, y: 10)))
        XCTAssertEqual(closes, 1, "a release outside closed")
        view.otherMouseUp(with: try otherMouseEvent(.otherMouseUp, button: 3, at: NSPoint(x: 10, y: 10)))
        XCTAssertEqual(closes, 1, "a fourth-button release closed")
    }

    /// An other-mouse event at `point` (window coordinates; the view has no
    /// window, so they are its own) from button `button`.
    private func otherMouseEvent(_ type: NSEvent.EventType, button: Int64, at point: NSPoint) throws -> NSEvent {
        let base = try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ))
        let cgEvent = try XCTUnwrap(base.cgEvent)
        cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: button)
        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }

    private func mouseEvent(_ type: CGEventType, button: CGMouseButton) throws -> NSEvent {
        let cgEvent = try XCTUnwrap(
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: button)
        )
        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }
}
#endif
