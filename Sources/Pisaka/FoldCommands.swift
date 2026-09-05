#if os(macOS)
import AppKit
import SwiftUI

/// The Edit menu's *Fold* (⌘⌥←) and *Unfold* (⌘⌥→).
///
/// **The whole menu surface of code folding lives here**, and `PisakaApp` names
/// this type exactly once — a rule `FoldingSourceGatingTests` pins, so a second
/// fold command cannot appear in the scene file where nothing else about folding
/// does.
///
/// The two items carry no state and are wired to nothing: like ⌘D and Toggle
/// Comment, they reach whatever editor holds the focus through the **first
/// responder** (`NSApp.keyWindow?.firstResponder as? EditorTextView`) and beep
/// through `PlatformFeedback.warning()` otherwise. That is what keeps the
/// commands correct with several windows open and with the terminal or the
/// project tree focused: an app-wide key equivalent fires wherever the keystroke
/// lands, and the responder is the only honest answer to "which editor?".
///
/// **One beep, two reasons.** The editor answers whether it folded anything, and
/// a `false` — no collapsible block at the caret, no folded block at the caret,
/// or a selection reaching past the block — beeps exactly as a focus that is not
/// an editor does. To the person pressing the key those are the same event:
/// nothing happened. Which block a press acts on, and when a selection refuses
/// it, is `FoldCommandRule`'s decision and is made in Core.
///
/// The shortcut pair was verified free against every `keyboardShortcut` in the
/// app (⌘⌥F, Find in Files, is the only other ⌘⌥ one) and against the text
/// view's own key handling, which claims no arrow key with ⌘⌥ held.
struct FoldCommands: Commands {
    var body: some Commands {
        // `after: .pasteboard` puts both items in the Edit menu beside Toggle
        // Comment, which is added to the same place — the group they belong to
        // is "things done to the code in front of you", not "things done to the
        // file".
        CommandGroup(after: .pasteboard) {
            Button("Fold") { fold() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

            Button("Unfold") { unfold() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        }
    }

    /// Collapse the innermost collapsible block the focused editor's caret is in.
    private func fold() {
        if focusedEditor()?.foldAtCaret() != true { PlatformFeedback.warning() }
    }

    /// Open the innermost folded block the focused editor's caret is in.
    private func unfold() {
        if focusedEditor()?.unfoldAtCaret() != true { PlatformFeedback.warning() }
    }

    /// The editor the keystroke belongs to, or `nil` when something else holds
    /// the focus.
    ///
    /// `isEditable` and `hasMarkedText()` are asked for `toggleCommentAtCaret`'s
    /// reasons: a read-only viewer is not this command's editor, and a keystroke
    /// arriving mid-composition belongs to the input method.
    private func focusedEditor() -> EditorTextView? {
        guard let editor = NSApp.keyWindow?.firstResponder as? EditorTextView,
              editor.isEditable,
              !editor.hasMarkedText()
        else { return nil }
        return editor
    }
}

#endif
