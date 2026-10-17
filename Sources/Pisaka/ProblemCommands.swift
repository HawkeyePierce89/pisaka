#if os(macOS)
import AppKit
import PisakaCore
import SwiftUI

/// The Find menu's *Next Problem* (⌘') and *Previous Problem* (⌘⇧').
///
/// Placed inside `PisakaApp`'s `CommandMenu("Find")` as one entry, because a
/// custom menu has no `CommandGroupPlacement` a separate `Commands` type could
/// name; the items, their action and the coordinator's half live here, since
/// `PisakaApp` and `CodeEditorView` are at their lint size caps.
///
/// Shaped like `LineCommands`: the items carry no state and reach whatever
/// editor holds the focus through the **first responder**
/// (`EditorCommandTarget.focusedEditor(in: NSApp.keyWindow)`), beeping through
/// `PlatformFeedback.warning()` when nothing focused can answer or the file has
/// no diagnostics. A move, not an edit, so a read-only editor answers too.
/// Where the caret goes is `DiagnosticNavigationRule`'s decision.
///
/// **The chords.** ⌘' and ⌘⇧' are claimed by nothing else in the app
/// (`MenuShortcutUniquenessTests`), and the text view's key bindings bind no
/// apostrophe with ⌘ held.
struct ProblemNavigationItems: View {
    /// No tab is open — the Find menu's usual gate.
    let isDisabled: Bool

    var body: some View {
        Divider()

        Button("Next Problem") { Self.go(.next) }
            .keyboardShortcut("'", modifiers: .command)
            .disabled(isDisabled)

        Button("Previous Problem") { Self.go(.previous) }
            .keyboardShortcut("'", modifiers: [.command, .shift])
            .disabled(isDisabled)
    }

    /// Step the focused editor's caret to the next or previous problem, or beep.
    @MainActor
    private static func go(_ direction: DiagnosticNavigationDirection) {
        guard let editor = EditorCommandTarget.focusedEditor(in: NSApp.keyWindow),
              let coordinator = editor.delegate as? CodeEditorView.Coordinator,
              coordinator.goToProblem(direction)
        else {
            PlatformFeedback.warning()
            return
        }
    }
}

extension CodeEditorView.Coordinator {
    /// Move the caret to the next or previous diagnostic and show its popover.
    ///
    /// Reads the store's entry for this file — already shifted across every
    /// edit by `DiagnosticShift` — and asks no server anything. The caret lands
    /// through the reveal funnel the Problems row uses (`revealRange(_:)`), so
    /// a problem inside a folded block unfolds by the reveal rule; the popover
    /// is presented afterwards, so the selection change's own dismissal has
    /// already run. `false` when there is no file, no editor, or no diagnostic.
    func goToProblem(_ direction: DiagnosticNavigationDirection) -> Bool {
        guard let textView, let fileURL,
              let diagnostics = diagnosticsModel?.store.entry(for: fileURL)?.diagnostics,
              let target = DiagnosticNavigationRule.target(
                  diagnostics: diagnostics,
                  caret: textView.selectedRange().location,
                  direction: direction
              ),
              target <= (textView.textStorage?.length ?? 0)
        else { return false }
        revealRange(NSRange(location: target, length: 0))
        hover.showDiagnostics(at: target, in: textView)
        return true
    }
}

#endif
