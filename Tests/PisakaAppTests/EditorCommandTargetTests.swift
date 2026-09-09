#if os(macOS)
import AppKit
import XCTest
@testable import Pisaka

/// `EditorCommandTarget` over a constructed window hierarchy.
///
/// **The rule is about a responder, so it needs a window**: `swift test` cannot
/// see this file at all — `EditorTextView`, `NSWindow` and the first-responder
/// chain are AppKit — which is why it lives in the app-layer bundle beside the
/// TextKit suites rather than in Core.
///
/// What is asserted is the whole of the helper's contract, and the negative half
/// is the load-bearing one: the preview's fallback must not become "find an
/// editor in the key window". An unrelated responder answering `nil` is what
/// keeps every existing beep — the terminal's, the project tree's, a text
/// field's — byte for byte what it was.
@MainActor
final class EditorCommandTargetTests: XCTestCase {

    // MARK: - The hierarchy

    /// A stand-in for the preview's web view: the marker is all the helper reads,
    /// so the test needs no WebKit and no loaded page.
    private final class PassthroughStandIn: NSView, EditorCommandFocusPassthrough {
        override var acceptsFirstResponder: Bool { true }
    }

    /// A responder that is neither the editor nor inside the preview — the
    /// terminal, the project tree, a text field, all of them at once.
    private final class UnrelatedView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private var window: NSWindow!
    private var editor: EditorTextView!
    private var passthrough: PassthroughStandIn!
    private var insidePassthrough: UnrelatedView!
    private var unrelated: UnrelatedView!

    override func setUp() {
        super.setUp()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = content

        // The editor zone: a text view inside a scroll view, as the real one is.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        editor = EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        editor.isEditable = true
        scroll.documentView = editor
        content.addSubview(scroll)

        // The preview beside it, with a subview standing in for the web view's
        // own internal content view — which is what actually takes the focus.
        passthrough = PassthroughStandIn(frame: NSRect(x: 400, y: 0, width: 400, height: 600))
        insidePassthrough = UnrelatedView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        passthrough.addSubview(insidePassthrough)
        content.addSubview(passthrough)

        // Something else entirely in the same window.
        unrelated = UnrelatedView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        content.addSubview(unrelated)
    }

    override func tearDown() {
        window = nil
        editor = nil
        passthrough = nil
        insidePassthrough = nil
        unrelated = nil
        super.tearDown()
    }

    // MARK: - The three answers

    func testTheEditorItselfIsTheAnswer() {
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(EditorCommandTarget.focusedEditor(in: window) === editor)
    }

    func testThePreviewAnswersTheEditorBesideIt() {
        XCTAssertTrue(window.makeFirstResponder(passthrough))
        XCTAssertTrue(EditorCommandTarget.focusedEditor(in: window) === editor)
    }

    func testADescendantOfThePreviewAnswersTheEditorToo() {
        XCTAssertTrue(window.makeFirstResponder(insidePassthrough))
        XCTAssertTrue(EditorCommandTarget.focusedEditor(in: window) === editor)
    }

    func testAnUnrelatedResponderAnswersNothing() {
        XCTAssertTrue(window.makeFirstResponder(unrelated))
        XCTAssertNil(EditorCommandTarget.focusedEditor(in: window))
    }

    func testNoWindowAnswersNothing() {
        XCTAssertNil(EditorCommandTarget.focusedEditor(in: nil))
    }
}

#endif
