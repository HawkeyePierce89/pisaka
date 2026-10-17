#if os(macOS)
import AppKit
import PisakaCore

/// The Edit menu's *Toggle Block Comment* (⌥⌘/), whose item sits beside
/// *Toggle Comment* in `PisakaApp`'s Edit block and whose action lives here.
///
/// Shaped like `LineCommands`: the command carries no state and reaches
/// whatever editor holds the focus through the **first responder**
/// (`EditorCommandTarget.focusedEditor(in: NSApp.keyWindow)`), beeping through
/// `PlatformFeedback.warning()` when the focus is not an editable editor, an
/// input method is mid-composition, or the editor answers that nothing changed
/// — json and markdown, which have no comment syntax. Every decision, the
/// line-toggle fallback included, is `BlockCommentEngine`'s.
enum CommentCommands {
    /// Toggle a block comment around the focused editor's selections, or beep.
    @MainActor
    static func toggleBlockComment() {
        guard let editor = EditorCommandTarget.focusedEditor(in: NSApp.keyWindow),
              editor.isEditable,
              !editor.hasMarkedText(),
              let coordinator = editor.delegate as? CodeEditorView.Coordinator,
              coordinator.toggleBlockComment(in: editor)
        else {
            PlatformFeedback.warning()
            return
        }
    }
}

extension CodeEditorView.Coordinator {
    /// Wrap or unwrap each selection, or drop an empty pair at each caret, as
    /// one undo step through the shared applier. JSX children are told apart
    /// through the same tree walk as ⌘/. `false` when the language has no
    /// comments at all or the plan could not be applied.
    func toggleBlockComment(in textView: NSTextView) -> Bool {
        let text = textView.string as NSString
        guard let plan = BlockCommentEngine.toggle(
            text: text,
            selectedRanges: (textView.selectedRanges as [NSValue]).map(\.rangeValue),
            language: language,
            context: CommentContextTreeWalk.resolver(
                snapshot: treeSnapshot, text: text, language: language, fileID: fileID
            )
        ) else { return false }
        return apply(plan, in: textView)
    }
}

#endif
