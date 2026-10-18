#if os(macOS)
import AppKit
import PisakaCore
import SwiftUI

/// The Git menu's change items: *Revert Change*, with no shortcut, and *Next
/// Change* (⌃⌥⇧↓) / *Previous Change* (⌃⌥⇧↑).
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
///
/// **The chords.** ⌃⌥⇧↓ / ⌃⌥⇧↑ avoid Mission Control's ⌃↑ / ⌃↓ and every
/// arrow chord the app already declares (`MenuShortcutUniquenessTests`), and
/// the text view's key bindings bind no arrow with all three of ⌃⌥⇧ held.
/// Navigation is a move, not an edit, so it neither consults the writer gate
/// nor needs an editable view.
struct ChangeCommandItems: View {
    /// No tab is open.
    let isDisabled: Bool

    var body: some View {
        Divider()

        Button("Revert Change") { Self.revert() }
            .disabled(isDisabled)

        Button("Next Change") { Self.go(.next) }
            .keyboardShortcut(.downArrow, modifiers: [.control, .option, .shift])
            .disabled(isDisabled)

        Button("Previous Change") { Self.go(.previous) }
            .keyboardShortcut(.upArrow, modifiers: [.control, .option, .shift])
            .disabled(isDisabled)
    }

    /// Step the focused editor's caret to the next or previous hunk, or beep.
    @MainActor
    private static func go(_ direction: DiagnosticNavigationDirection) {
        guard let coordinator = focusedCoordinator(), coordinator.goToChange(direction) else {
            PlatformFeedback.warning()
            return
        }
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
    /// Move the caret to the start of the next or previous hunk's stop line.
    ///
    /// Recomputes the hunks **now** from the held base and the live buffer, for
    /// the revert's reason, and asks `ChangeNavigationRule` where to go. The
    /// caret lands through the reveal funnel (`revealRange(_:)`), so a hunk
    /// inside a folded block unfolds. `false` — a beep — with no editor, no
    /// base or no hunk at all.
    func goToChange(_ direction: DiagnosticNavigationDirection) -> Bool {
        guard let textView else { return false }
        let buffer = textView.string
        let starts = LineStartIndex.offsets(in: buffer as NSString)
        let caretLine = Self.line(holding: textView.selectedRange().location, starts: starts)
        guard let line = ChangeNavigationRule.targetLine(
                  hunks: gitChanges.currentChanges(buffer: buffer).hunks,
                  caretLine: caretLine,
                  direction: direction
              ),
              starts.indices.contains(line)
        else { return false }
        revealRange(NSRange(location: starts[line], length: 0))
        return true
    }

    /// Revert the hunk behind the gutter marker the ruler answered `line` for —
    /// `-1` the deletion wedge above line 1 (`GutterChanges.hunk(atMarkerLine:)`).
    @discardableResult
    func revertChange(atMarker line: Int) -> ChangeRevertOutcome {
        revertChange { $0.hunk(atMarkerLine: line) }
    }

    /// Revert the hunk holding the caret's line (`GutterChanges.hunk(atLine:)`).
    func revertChangeAtCaret() -> ChangeRevertOutcome {
        guard let textView else { return .noHunk }
        let starts = LineStartIndex.offsets(in: textView.string as NSString)
        let line = Self.line(holding: textView.selectedRange().location, starts: starts)
        return revertChange { $0.hunk(atLine: line) }
    }

    /// The 0-based line whose start is the last one at or before `offset`.
    private static func line(holding offset: Int, starts: [Int]) -> Int {
        max(0, (starts.lastIndex { $0 <= offset }) ?? 0)
    }

    /// The one revert path: consult the gate, recompute the hunks **now** from
    /// the held base and the live buffer — never the drawn answer, which may be
    /// a quarter-second old — and apply `HunkRevertPlan`'s edit through the
    /// single-edit funnel: one undo step, the caret at the hunk's start, no disk
    /// write and no Local History capture (the next autosave captures the
    /// buffer as for any edit).
    private func revertChange(_ find: (GutterChanges) -> ChangeHunk?) -> ChangeRevertOutcome {
        guard !gitChanges.writeInFlight() else { return .refused }
        guard let textView, let base = gitChanges.commandBase else { return .noHunk }
        let buffer = textView.string
        guard let hunk = find(gitChanges.currentChanges(buffer: buffer)),
              let plan = HunkRevertPlan.plan(hunk: hunk, base: base, buffer: buffer),
              apply(plan, in: textView)
        else { return .noHunk }
        return .reverted
    }
}

#endif
