#if os(macOS)
import AppKit
import SwiftUI

/// The Edit menu's *Expand Selection* (⌃⌘→) and *Shrink Selection* (⌃⌘←).
///
/// Shaped like `FoldCommands`: the two items carry no state and reach whatever
/// editor holds the focus through the **first responder**
/// (`EditorCommandTarget.focusedEditor(in: NSApp.keyWindow)`), beeping through
/// `PlatformFeedback.warning()` when the focus is not an editor or the editor
/// answers that there is no further step — a selection already the whole
/// document, or nothing expanded to shrink back from. Which range comes next is
/// `SelectionExpansionRule`'s decision, made in Core; the path Shrink walks
/// back is the editor's `SelectionExpansionHistory`.
///
/// **The chords.** Verified against every `keyboardShortcut` in the app
/// (`MenuShortcutUniquenessTests`): the only other arrow chords are
/// `FoldCommands`' ⌘⌥ and ⌘⌥⇧ pairs, and nothing else holds ⌃⌘. Against
/// AppKit's `StandardKeyBinding.dict` (read with `plutil`) the pair is **not**
/// free: `@^←` / `@^→` are `makeBaseWritingDirectionRightToLeft:` /
/// `makeBaseWritingDirectionLeftToRight:`. A menu key equivalent is matched
/// before the key event reaches the text view's key bindings, so the menu item
/// wins and the editor gives up only those two keystrokes — paragraph
/// direction is a rich-text attribute a plain-text code buffer neither shows
/// nor saves. No other binding in the dictionary uses ⌃⌘ with an arrow; ⌃← /
/// ⌃→ alone, the line-end moves, are untouched.
struct SelectionCommands: Commands {
    var body: some Commands {
        // Beside Fold and Toggle Comment: things done to the code in front of
        // you.
        CommandGroup(after: .pasteboard) {
            Button("Expand Selection") { expand() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])

            Button("Shrink Selection") { shrink() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
        }
    }

    /// Widen the focused editor's selection one step.
    private func expand() {
        if focusedEditor()?.selectionExpansion.expand() != true { PlatformFeedback.warning() }
    }

    /// Narrow the focused editor's selection back one step.
    private func shrink() {
        if focusedEditor()?.selectionExpansion.shrink() != true { PlatformFeedback.warning() }
    }

    /// The coordinator of the editor the keystroke belongs to, or `nil` when
    /// something else holds the focus or an input method is mid-composition.
    /// A read-only viewer is not refused: selecting changes nothing it shows.
    ///
    /// The responder is read through ``EditorCommandTarget``, as every editor
    /// command reads it; the coordinator is the text view's delegate, which
    /// `CodeEditorView.makeNSView` assigns, so the step is asked of the one
    /// object holding the buffer's language and tree without the text view
    /// relaying a closure for it.
    private func focusedEditor() -> CodeEditorView.Coordinator? {
        guard let editor = EditorCommandTarget.focusedEditor(in: NSApp.keyWindow),
              !editor.hasMarkedText()
        else { return nil }
        return editor.delegate as? CodeEditorView.Coordinator
    }
}

#endif
