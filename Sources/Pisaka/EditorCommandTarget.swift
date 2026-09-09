#if os(macOS)
import AppKit

/// A view the caret commands are allowed to look *past*.
///
/// The one conformer is the Markdown preview's web view
/// (``MarkdownPreviewWKWebView``); the protocol lives here, beside the rule that
/// reads it, so the helper needs no WebKit import and the preview keeps its one
/// WebKit file.
///
/// It is a marker and nothing else: conforming says "focus inside me is still
/// focus on the document beside me", which is true of the preview because the
/// preview *is* the file the editor is showing, rendered. Nothing else in the
/// app may claim that, which is why the marker is a protocol with one conformer
/// rather than a class check the helper could widen by accident.
protocol EditorCommandFocusPassthrough: AnyObject {}

/// Which editor a caret command belongs to.
///
/// The six commands that act "at the caret" — Go to Definition, Find Usages,
/// Rename, Toggle Comment, Complete, and the four fold items through
/// ``FoldCommands`` — are app-wide key equivalents that carry no state, so the
/// **first responder** is the only honest answer to "which editor?". Each of
/// them used to spell `NSApp.keyWindow?.firstResponder as? EditorTextView`
/// itself; this is that expression's one definition, and
/// `MarkdownPreviewSourceGatingTests` pins that no other file spells it.
///
/// **Why the fallback is scoped to the preview and is not a general search.**
/// The Markdown preview is a focusable web view sitting beside the editor
/// showing the very file that editor holds; clicking into it to select a
/// sentence must not make ⌘/ beep. But "find *an* editor in the key window" is a
/// different and worse rule: the terminal, the project tree, the search field
/// and every other responder would then answer with an editor the keystroke was
/// never aimed at, silently editing a buffer the user is not looking at. So the
/// fallback is granted to exactly one region — the preview and its descendants,
/// recognised through ``EditorCommandFocusPassthrough`` — and every other
/// responder keeps beeping byte for byte as it does today.
///
/// The fallback searches the key window's content view for an
/// ``EditorTextView``. There is at most one per window: the editor zone hosts a
/// single text view, and the preview is its neighbour inside the same split, so
/// the search cannot pick a second editor over the one the preview is rendering.
@MainActor
enum EditorCommandTarget {

    /// The editor a caret command in `window` belongs to, or `nil` when the
    /// keystroke belongs to something else.
    ///
    /// The window is a parameter rather than read from `NSApp` here so the rule
    /// is assertable over a constructed hierarchy; every call site passes
    /// `NSApp.keyWindow`. The caller keeps its own extra guards — `isEditable`
    /// and `hasMarkedText()` are asked by the commands that edit, not by this.
    static func focusedEditor(in window: NSWindow?) -> EditorTextView? {
        guard let window else { return nil }
        if let editor = window.firstResponder as? EditorTextView { return editor }
        guard isPassthrough(window.firstResponder), let content = window.contentView else { return nil }
        return editorTextView(in: content)
    }

    /// Whether `responder` is a passthrough region or lives inside one.
    ///
    /// Walked up rather than tested directly because a web view's first
    /// responder is usually an internal subview of it, not the view the app
    /// made.
    private static func isPassthrough(_ responder: NSResponder?) -> Bool {
        var view = responder as? NSView
        while let current = view {
            if current is any EditorCommandFocusPassthrough { return true }
            view = current.superview
        }
        return false
    }

    /// The first ``EditorTextView`` in `view`'s subtree, `view` itself included.
    private static func editorTextView(in view: NSView) -> EditorTextView? {
        if let editor = view as? EditorTextView { return editor }
        for subview in view.subviews {
            if let editor = editorTextView(in: subview) { return editor }
        }
        return nil
    }
}

#endif
