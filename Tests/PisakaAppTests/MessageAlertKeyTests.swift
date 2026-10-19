#if os(macOS)
import AppKit
import XCTest
@testable import Pisaka

/// The key rule behind Esc on the one-button message alert
/// (`PlatformAlert.answersAsDismiss`): an unmodified Esc key-down answers the
/// alert as its button; a chord containing Esc, Return, a letter and a key-up
/// do not.
///
/// **Why the rule and not the modal session.** `presentMessage` installs a local
/// key-down monitor around `runModal()` that stops the session and consumes the
/// event when this rule says so — which is what keeps the key away from the
/// commit dialog beneath. Running that session needs an active application, which
/// a test host is not, so the synthesized events pin the decision the monitor
/// delegates to; the monitor's wiring stays a manual check.
final class MessageAlertKeyTests: XCTestCase {
    func testEscAnswersTheAlert() throws {
        XCTAssertTrue(PlatformAlert.answersAsDismiss(try key("\u{1b}", code: 53)))
    }

    func testShiftEscStillAnswers() throws {
        XCTAssertTrue(PlatformAlert.answersAsDismiss(try key("\u{1b}", code: 53, modifiers: .shift)))
    }

    func testAChordContainingEscDoesNotAnswer() throws {
        for modifier in [NSEvent.ModifierFlags.command, .option, .control] {
            XCTAssertFalse(
                PlatformAlert.answersAsDismiss(try key("\u{1b}", code: 53, modifiers: modifier)),
                "Esc with \(modifier) must keep its own meaning"
            )
        }
    }

    func testReturnDoesNotAnswer() throws {
        XCTAssertFalse(PlatformAlert.answersAsDismiss(try key("\r", code: 36)))
    }

    func testALetterDoesNotAnswer() throws {
        XCTAssertFalse(PlatformAlert.answersAsDismiss(try key("a", code: 0)))
    }

    func testAKeyUpDoesNotAnswer() throws {
        XCTAssertFalse(PlatformAlert.answersAsDismiss(try key("\u{1b}", code: 53, type: .keyUp)))
    }

    private func key(
        _ characters: String,
        code: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        type: NSEvent.EventType = .keyDown
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        ))
    }
}
#endif
