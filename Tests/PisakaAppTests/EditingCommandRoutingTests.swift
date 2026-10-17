#if os(macOS)
import AppKit
import PisakaCore
import XCTest
@testable import Pisaka

/// The editing keys' app half: the coordinator's `doCommandBy` routing and the
/// one applier every multi-range command funnels through. The Core suites pin
/// the plans; this pins what only a real `NSTextView` shows.
///
/// What it pins:
/// - Tab on a block selection indents every touched line and one undo gives
///   the text back — the applier's raw storage edit is registered;
/// - Tab at a caret with no `.editorconfig` hands the key back, so the
///   inference alone never changes what that keystroke inserts;
/// - Shift+Tab outdents, and is consumed even when there is nothing to outdent;
/// - Backspace inside space indentation deletes to the previous indent stop,
///   and after a non-space hands the key back;
/// - ⌘D on two selections duplicates both and one undo gives the text back;
/// - the applier refuses while an input method is composing and changes
///   nothing;
/// - the applier posts one storage edit per plan edit, each with its own
///   exact range, so the fold and diagnostics shifts never see one span
///   running across the untouched text between two distant carets.
@MainActor
final class EditingCommandRoutingTests: XCTestCase {

    func testTabOnABlockIndentsEveryLineAndUndoesInOneStep() {
        let editor = makeEditor("a\nb\n")
        editor.select(NSRange(location: 0, length: 3))
        XCTAssertTrue(editor.command(#selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(editor.text, "    a\n    b\n")
        editor.undo()
        XCTAssertEqual(editor.text, "a\nb\n")
    }

    func testTabAtACaretWithoutAConfigHandsTheKeyBack() {
        let editor = makeEditor("    a\n    b\n")
        editor.select(NSRange(location: 4, length: 0))
        XCTAssertFalse(editor.command(#selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(editor.text, "    a\n    b\n")
    }

    func testShiftTabOutdentsAndIsAlwaysConsumed() {
        let editor = makeEditor("    a\n    b\n")
        editor.select(NSRange(location: 6, length: 0))
        XCTAssertTrue(editor.command(#selector(NSResponder.insertBacktab(_:))))
        XCTAssertEqual(editor.text, "    a\nb\n")

        let flat = makeEditor("a\n")
        flat.select(NSRange(location: 1, length: 0))
        XCTAssertTrue(flat.command(#selector(NSResponder.insertBacktab(_:))))
        XCTAssertEqual(flat.text, "a\n")
    }

    func testBackspaceInIndentationDeletesToTheIndentStop() {
        let editor = makeEditor("    a\n        b\n")
        editor.select(NSRange(location: 14, length: 0))
        XCTAssertTrue(editor.command(#selector(NSResponder.deleteBackward(_:))))
        XCTAssertEqual(editor.text, "    a\n    b\n")
        XCTAssertEqual(editor.selection, NSRange(location: 10, length: 0))

        editor.select(NSRange(location: 5, length: 0))
        XCTAssertFalse(editor.command(#selector(NSResponder.deleteBackward(_:))))
        XCTAssertEqual(editor.text, "    a\n    b\n")
    }

    func testDuplicateOnTwoSelectionsIsOneUndoStep() {
        // Two selections, not two carets: `NSTextView` keeps an empty range
        // only when it is the sole one.
        let editor = makeEditor("a\nb")
        editor.harness.textView.setSelectedRanges(
            [NSValue(range: NSRange(location: 0, length: 1)), NSValue(range: NSRange(location: 2, length: 1))],
            affinity: .downstream, stillSelecting: false
        )
        XCTAssertTrue(editor.grouped { editor.coordinator.duplicateSelection(in: editor.harness.textView) })
        XCTAssertEqual(editor.text, "aa\nbb")
        editor.undo()
        XCTAssertEqual(editor.text, "a\nb")
    }

    func testTheApplierRefusesDuringComposition() throws {
        let editor = makeEditor("ab")
        editor.select(NSRange(location: 2, length: 0))
        _ = editor.grouped {
            editor.harness.textView.setMarkedText(
                "k", selectedRange: NSRange(location: 1, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            return true
        }
        XCTAssertTrue(editor.harness.textView.hasMarkedText())
        let plan = try XCTUnwrap(RangeEditPlan(
            edits: [IndentReplacement(range: NSRange(location: 0, length: 0), replacement: "x")], selections: []
        ))
        XCTAssertFalse(editor.coordinator.apply(plan, in: editor.harness.textView))
        XCTAssertEqual(editor.text, "abk")
    }

    func testTheApplierPostsEachEditsOwnRange() throws {
        let editor = makeEditor("a\nfolded\nfolded\nb\n")
        let storage = try XCTUnwrap(editor.harness.textView.textStorage)
        var edited: [NSRange] = []
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { _ in
            MainActor.assumeIsolated { edited.append(storage.editedRange) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let plan = try XCTUnwrap(RangeEditPlan(
            edits: [
                IndentReplacement(range: NSRange(location: 0, length: 0), replacement: "// "),
                IndentReplacement(range: NSRange(location: 16, length: 0), replacement: "// "),
            ],
            selections: []
        ))
        XCTAssertTrue(editor.grouped { editor.coordinator.apply(plan, in: editor.harness.textView) })
        XCTAssertEqual(editor.text, "// a\nfolded\nfolded\n// b\n")
        XCTAssertEqual(edited, [NSRange(location: 16, length: 3), NSRange(location: 0, length: 3)])
    }

    // MARK: - Harness

    @MainActor
    private final class Editor {
        let harness = EditorLayoutHarness()
        let coordinator: CodeEditorView.Coordinator
        let undoManager: UndoManager

        init(text: String) {
            harness.textView.string = text
            harness.textView.allowsUndo = true
            coordinator = CodeEditorView.Coordinator(text: .constant(text))
            coordinator.textView = harness.textView
            coordinator.fileID = UUID()
            harness.textView.delegate = coordinator
            undoManager = coordinator.undoManager(for: harness.textView)!
            // No event loop runs here, so each command gets its group by hand.
            undoManager.groupsByEvent = false
        }

        var text: String { harness.textView.string }
        var selection: NSRange { harness.textView.selectedRange() }

        func select(_ range: NSRange) {
            harness.textView.setSelectedRange(range)
        }

        func grouped(_ body: () -> Bool) -> Bool {
            undoManager.beginUndoGrouping()
            defer { undoManager.endUndoGrouping() }
            return body()
        }

        func command(_ selector: Selector) -> Bool {
            grouped { coordinator.textView(harness.textView, doCommandBy: selector) }
        }

        func undo() {
            undoManager.undo()
        }
    }

    private func makeEditor(_ text: String) -> Editor {
        let editor = Editor(text: text)
        addTeardownBlock { @MainActor in
            editor.harness.textView.delegate = nil
        }
        return editor
    }
}

#endif
