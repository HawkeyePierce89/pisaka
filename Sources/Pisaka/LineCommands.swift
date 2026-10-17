#if os(macOS)
import AppKit
import PisakaCore
import SwiftUI

/// The Edit menu's *Move Line Up* (⌥⌘[) and *Move Line Down* (⌥⌘]).
///
/// Shaped like `FoldCommands` and `SelectionCommands`: the two items carry no
/// state and reach whatever editor holds the focus through the **first
/// responder** (`EditorCommandTarget.focusedEditor(in: NSApp.keyWindow)`),
/// beeping through `PlatformFeedback.warning()` when the focus is not an
/// editable editor or the editor answers that nothing moved — a block already
/// on the first or last line. Which lines move, and what happens to a fold, is
/// `MoveLineEngine`'s decision, made in Core; the coordinator only applies the
/// plan (`Coordinator.moveLines(_:)`).
///
/// **The chords.** Verified against every `keyboardShortcut` in the app
/// (`MenuShortcutUniquenessTests`): the only other bracket chords are tab
/// navigation's ⌘⇧[ / ⌘⇧], which hold Shift rather than Option, so the two
/// pairs are distinct key equivalents. The text view's key bindings claim no
/// bracket with ⌥⌘ held.
struct LineCommands: Commands {
    var body: some Commands {
        // Beside Fold, Expand Selection and Toggle Comment: things done to the
        // code in front of you.
        CommandGroup(after: .pasteboard) {
            Button("Move Line Up") { move(.up) }
                .keyboardShortcut("[", modifiers: [.command, .option])

            Button("Move Line Down") { move(.down) }
                .keyboardShortcut("]", modifiers: [.command, .option])
        }
    }

    /// Move the focused editor's touched lines one step, or beep.
    private func move(_ direction: MoveLineDirection) {
        if focusedEditor()?.moveLines(direction) != true { PlatformFeedback.warning() }
    }

    /// The coordinator of the editor the keystroke belongs to, or `nil` when
    /// something else holds the focus, the editor is a read-only viewer, or an
    /// input method is mid-composition — `toggleCommentAtCaret`'s reasons,
    /// since a move is an edit.
    ///
    /// The responder is read through ``EditorCommandTarget``, as every editor
    /// command reads it; the coordinator is the text view's delegate, which
    /// `CodeEditorView.makeNSView` assigns.
    private func focusedEditor() -> CodeEditorView.Coordinator? {
        guard let editor = EditorCommandTarget.focusedEditor(in: NSApp.keyWindow),
              editor.isEditable,
              !editor.hasMarkedText()
        else { return nil }
        return editor.delegate as? CodeEditorView.Coordinator
    }
}

#endif
