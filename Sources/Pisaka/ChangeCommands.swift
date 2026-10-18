#if os(macOS)
import AppKit
import PisakaCore
import SwiftUI

/// The Git menu's change items: *Revert Change*, with no shortcut.
///
/// Placed inside `PisakaApp`'s `CommandMenu("Git")` as one entry, for
/// `ProblemNavigationItems`' reason: a custom menu has no
/// `CommandGroupPlacement` a separate `Commands` type could name, and
/// `PisakaApp` and `CodeEditorView` are at their lint size caps, so the items,
/// their action and the coordinator's half live here.
///
/// Shaped like `ProblemNavigationItems`: stateless items reaching whatever
/// editor holds the focus through the **first responder**
/// (`EditorCommandTarget.focusedEditor(in: NSApp.keyWindow)`), disabled with no
/// open tab — the only state a menu item can observe — and beeping through
/// `PlatformFeedback.warning()` when no editor is focused or the caret is in no
/// hunk. A raised writer gate is the one refusal that stays **silent**.
struct ChangeCommandItems: View {
    /// No tab is open.
    let isDisabled: Bool

    var body: some View {
        Divider()

        Button("Revert Change") { Self.revert() }
            .disabled(isDisabled)
    }

    /// Revert the hunk holding the focused editor's caret, or beep.
    @MainActor
    private static func revert() {
        guard let coordinator = focusedCoordinator() else {
            PlatformFeedback.warning()
            return
        }
        if coordinator.revertChangeAtCaret() == .noHunk { PlatformFeedback.warning() }
    }

    /// The focused editor's coordinator — the one place these items ask.
    @MainActor
    private static func focusedCoordinator() -> CodeEditorView.Coordinator? {
        EditorCommandTarget.focusedEditor(in: NSApp.keyWindow)?.delegate as? CodeEditorView.Coordinator
    }
}

/// What a hunk revert came to.
enum ChangeRevertOutcome: Equatable {
    /// The hunk's `HEAD` lines are back in the buffer, as one undo step.
    case reverted
    /// A worktree-mutating git operation holds the writer gate: nothing changed,
    /// and nothing is said — the gate is consulted, never raised.
    case refused
    /// No hunk where asked, no base, no editor, or the edit funnel declined
    /// (mid-composition, a read-only view).
    case noHunk
}

extension CodeEditorView.Coordinator {
    /// Revert the hunk behind the gutter marker the ruler answered `line` for —
    /// `-1` the deletion wedge above line 1 (`GutterChanges.hunk(atMarkerLine:)`).
    @discardableResult
    func revertChange(atMarker line: Int) -> ChangeRevertOutcome {
        revertChange { $0.hunk(atMarkerLine: line) }
    }

    /// Revert the hunk holding the caret's line (`GutterChanges.hunk(atLine:)`).
    func revertChangeAtCaret() -> ChangeRevertOutcome {
        guard let textView else { return .noHunk }
        let caret = textView.selectedRange().location
        let starts = LineStartIndex.offsets(in: textView.string as NSString)
        let line = max(0, (starts.lastIndex { $0 <= caret }) ?? 0)
        return revertChange { $0.hunk(atLine: line) }
    }

    /// The one revert path: consult the gate, recompute the hunks **now** from
    /// the held base and the live buffer — never the drawn answer, which may be
    /// a quarter-second old — and apply `HunkRevertPlan`'s edit through the
    /// single-edit funnel: one undo step, the caret at the hunk's start, no disk
    /// write and no Local History capture (the next autosave captures the
    /// buffer as for any edit).
    private func revertChange(_ find: (GutterChanges) -> ChangeHunk?) -> ChangeRevertOutcome {
        guard !gitChanges.writeInFlight() else { return .refused }
        guard let textView, let base = gitChanges.base else { return .noHunk }
        let buffer = textView.string
        guard let hunk = find(gitChanges.currentChanges(buffer: buffer)),
              let plan = HunkRevertPlan.plan(hunk: hunk, base: base, buffer: buffer),
              apply(plan, in: textView)
        else { return .noHunk }
        return .reverted
    }
}

#endif
