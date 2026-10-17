#if os(macOS)
import AppKit
import PisakaCore
import SwiftTreeSitter

/// Expand / Shrink Selection's editor side (R6): one per editor, owned by its
/// coordinator, holding the `SelectionExpansionHistory` Shrink walks back
/// along and asking `SelectionExpansionRule` for every step.
///
/// A language with a grammar climbs the coordinator's shared `treeSnapshot`
/// through `SelectionExpansionTreeWalk`; one without uses the rule's text-only
/// ladder. A tree not yet parsed is asked for off the main actor and the step
/// lands when it arrives — reading the selection *then*, so a second press
/// waiting on the same parse steps from wherever the first left it — and beeps
/// itself if the parse was superseded or nothing was left to take.
///
/// **The history.** Only this controller's own selection moves keep it; any
/// other selection change (a click, an arrow key, a find) and any character
/// edit reset it, observed from the text view's and the storage's own
/// notifications. A tab switch is a buffer swap, which is an edit. The
/// observers are installed on first use — before it the history is empty, so
/// there is nothing to reset — which is why the coordinator pays one lazy
/// property for the whole feature.
@MainActor
final class SelectionExpansionController {
    private weak var coordinator: CodeEditorView.Coordinator?
    private weak var observedTextView: NSTextView?

    private var history = SelectionExpansionHistory()

    /// The step waiting on an uncached parse, if any. `internal` for the
    /// app-layer test, which awaits it as the causal end of the cold path.
    private(set) var pendingStep: Task<Void, Never>?

    /// Set while this controller moves the selection, so the selection
    /// observer keeps the history for exactly those moves.
    private var isApplying = false

    init(coordinator: CodeEditorView.Coordinator) {
        self.coordinator = coordinator
    }

    /// The Edit menu's *Expand Selection* (⌃⌘→): widen the selection to the
    /// next rung, or answer `false` so the command beeps.
    func expand() -> Bool {
        guard let coordinator, let textView = observe(), let fileID = coordinator.fileID else { return false }
        guard let language = coordinator.language,
              SyntaxLanguageConfiguration.configuration(for: language) != nil else {
            return apply(SelectionExpansionRule.fallbackCandidates(
                text: textView.string as NSString,
                selection: textView.selectedRange(),
                language: coordinator.language
            ))
        }
        let snapshot = coordinator.treeSnapshot
        if let tree = snapshot.cached(language: language, fileID: fileID) {
            return expand(over: tree, language: language)
        }
        let text = textView.string
        let textGeneration = snapshot.editGeneration
        pendingStep = Task { [weak self] in
            let tree = await snapshot.tree(text: text, language: language, fileID: fileID, generation: textGeneration)
            guard let self, let tree, self.coordinator?.fileID == fileID, self.coordinator?.language == language,
                  self.expand(over: tree, language: language)
            else {
                PlatformFeedback.warning()
                return
            }
        }
        return true
    }

    /// The Edit menu's *Shrink Selection* (⌃⌘←): return to the selection the
    /// last expansion left, or answer `false` when there is none.
    func shrink() -> Bool {
        guard let textView = observe(), let previous = history.pop() else { return false }
        guard NSMaxRange(previous) <= (textView.string as NSString).length else {
            history.reset()
            return false
        }
        move(to: previous, in: textView)
        return true
    }

    /// One step over a tree that describes the buffer on screen.
    private func expand(over tree: Tree, language: SyntaxLanguage) -> Bool {
        guard let textView = observe() else { return false }
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let chain = SelectionExpansionTreeWalk.chain(in: tree, selection: selection, textLength: text.length)
        return apply(SelectionExpansionRule.candidates(
            text: text,
            selection: selection,
            language: language,
            ancestors: chain.ancestors,
            stringContent: chain.stringContent
        ))
    }

    private func apply(_ candidates: [NSRange]) -> Bool {
        guard let textView = observe() else { return false }
        let selection = textView.selectedRange()
        guard let next = SelectionExpansionRule.next(selection: selection, candidates: candidates) else {
            return false
        }
        history.push(selection)
        move(to: next, in: textView)
        return true
    }

    private func move(to range: NSRange, in textView: NSTextView) {
        isApplying = true
        defer { isApplying = false }
        // No scroll: a step only widens around a selection already on screen
        // or narrows back to one that was, and `scrollRangeToVisible` belongs
        // to the reveal funnel alone (`FoldingSourceGatingTests`), which this
        // must not take — it unfolds what it lands in, and the document rung
        // would spring every fold open.
        textView.setSelectedRange(range)
    }

    // MARK: - Observation

    /// The coordinator's text view, with this controller observing it and its
    /// storage — re-bound, and the history dropped, if the view changed.
    private func observe() -> NSTextView? {
        guard let textView = coordinator?.textView else { return nil }
        guard textView !== observedTextView else { return textView }
        let center = NotificationCenter.default
        center.removeObserver(self)
        history.reset()
        observedTextView = textView
        center.addObserver(
            self,
            selector: #selector(selectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
        if let storage = textView.textStorage {
            center.addObserver(
                self,
                selector: #selector(storageDidProcessEditing(_:)),
                name: NSTextStorage.didProcessEditingNotification,
                object: storage
            )
        }
        return textView
    }

    @objc private func selectionDidChange(_ notification: Notification) {
        if !isApplying { history.reset() }
    }

    @objc private func storageDidProcessEditing(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters) else { return }
        history.reset()
    }
}

#endif
