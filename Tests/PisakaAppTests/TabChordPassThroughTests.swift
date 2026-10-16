#if os(macOS)
import AppKit
import XCTest
@testable import Pisaka

/// The tab-navigation chords reach the Window menu: neither of the app's two
/// `performKeyEquivalent` overrides — the editor's `EditorTextView` and Local
/// Changes' `LocalChangesFocusAnchorView` — consumes ⌘⇧], ⌘⇧[, ⌃Tab, ⌃⇧Tab,
/// ⌘1, ⌘8 or ⌘9 while it is the window's first responder.
///
/// The embedded terminal needs no case here: SwiftTerm 1.5.0's `TerminalView`
/// (`Sources/SwiftTerm/Mac/MacTerminalView.swift`) overrides `keyDown` but not
/// `performKeyEquivalent`, and the main menu is consulted before `keyDown`, so a
/// menu chord is never offered to the terminal at all.
@MainActor
final class TabChordPassThroughTests: XCTestCase {
    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    func testTheEditorPassesEveryTabChordThrough() throws {
        let editor = EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        editor.isEditable = true
        // A wired duplicate handler answering true, so a chord misread as ⌘D
        // would show up as a consumed event rather than fall through by accident.
        editor.onDuplicate = { _ in true }
        window.contentView?.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))

        try assertPassesThrough(editor)
        // The editor's own control: in this same setup it does consume ⌘D, so
        // the pass-through assertions above are not vacuous.
        XCTAssertTrue(editor.performKeyEquivalent(with: try keyEvent("d", keyCode: 2, modifiers: .command)),
                      "⌘D is the editor's own chord")
    }

    func testLocalChangesPassesEveryTabChordThrough() throws {
        let anchor = LocalChangesFocusAnchorView(
            selectedFile: nil,
            repositoryRoot: nil,
            onOpenDiff: { _ in },
            onResolveConflict: { _ in },
            onOpenFile: { _ in }
        )
        window.contentView?.addSubview(anchor)
        XCTAssertTrue(window.makeFirstResponder(anchor))

        try assertPassesThrough(anchor)
    }

    /// The control: the same harness *does* see a chord the anchor consumes,
    /// so the pass-through assertions above cannot be vacuous.
    func testTheHarnessSeesAConsumedChord() throws {
        let anchor = LocalChangesFocusAnchorView(
            selectedFile: nil,
            repositoryRoot: nil,
            onOpenDiff: { _ in },
            onResolveConflict: { _ in },
            onOpenFile: { _ in }
        )
        window.contentView?.addSubview(anchor)
        XCTAssertTrue(window.makeFirstResponder(anchor))

        let commandD = try keyEvent("d", keyCode: 2, modifiers: .command)
        XCTAssertTrue(anchor.performKeyEquivalent(with: commandD), "⌘D is the anchor's own chord")
    }

    // MARK: - Helpers

    private func assertPassesThrough(_ view: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
        let tab = String(UnicodeScalar(9))
        let chords: [(name: String, characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags)] = [
            ("⌘⇧]", "]", 30, [.command, .shift]),
            ("⌘⇧[", "[", 33, [.command, .shift]),
            ("⌃Tab", tab, 48, [.control]),
            ("⌃⇧Tab", tab, 48, [.control, .shift]),
            ("⌘1", "1", 18, [.command]),
            ("⌘8", "8", 28, [.command]),
            ("⌘9", "9", 25, [.command]),
        ]
        for chord in chords {
            let event = try keyEvent(chord.characters, keyCode: chord.keyCode, modifiers: chord.modifiers)
            XCTAssertFalse(view.performKeyEquivalent(with: event),
                           "\(chord.name) was consumed before the menu", file: file, line: line)
        }
    }

    private func keyEvent(
        _ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
#endif
