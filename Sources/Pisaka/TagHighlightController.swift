#if os(macOS)
import AppKit
import PisakaCore

/// Drives the editor's matching-tag highlight (R5): on the same 75 ms settle as
/// the occurrence highlight, it reads the caret's enclosing elements off the
/// shared `SyntaxTreeSnapshot`, asks `TagMatchRule` what to paint, and paints it
/// through `BracketOverlayLayoutManager.setTagRanges`.
///
/// Every decision is the rule's — which names, and whether the tag pair takes
/// the bracket pair's place — so this class only schedules, extracts and
/// paints. When the rule suppresses the bracket pair it says so through
/// `onBracketPairSuppression`, which the coordinator routes to
/// `BracketHighlightController`.
///
/// **A reader.** Temporary attributes only: no undo entry, no dirty flag, no
/// path to the save funnel.
///
/// **Edits.** `noteEdit()` is called after `BracketHighlightController.noteEdit`
/// has dropped every background overlay in pre-edit coordinates, so clearing
/// here reaches the layout manager as a no-op. A settle in flight is discarded
/// by its generation token.
@MainActor
final class TagHighlightController {
    /// The debounce between a selection change and the settle it schedules —
    /// the occurrence highlight's, so both land together.
    static let debounceInterval = OccurrenceHighlightController.debounceInterval

    private weak var textView: NSTextView?

    /// The tree shared with Expand / Shrink Selection. Set by the coordinator.
    var snapshot: SyntaxTreeSnapshot?

    /// The shown buffer's identity and language, read at each settle.
    var fileID: () -> UUID? = { nil }
    var language: () -> SyntaxLanguage? = { nil }

    /// Told whether the bracket pair is suppressed, after every settle and
    /// every clear.
    var onBracketPairSuppression: (Bool) -> Void = { _ in }

    /// The ranges last handed to the layout manager. `internal` for the
    /// app-layer test.
    private(set) var paintedRanges: [NSRange] = []

    private var pendingTask: Task<Void, Never>?

    /// Monotonic token, captured synchronously before the tree hop; a settle
    /// that a newer one, an edit or a reset superseded paints nothing.
    private var generation = 0

    private var overlayLayoutManager: BracketOverlayLayoutManager? {
        textView?.layoutManager as? BracketOverlayLayoutManager
    }

    func attach(textView: NSTextView) {
        self.textView = textView
    }

    // MARK: - Triggers

    /// The selection moved: settle after the debounce.
    func selectionChanged() {
        pendingTask?.cancel()
        let interval = Self.debounceInterval
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            guard let self else { return }
            self.pendingTask = nil
            self.settleNow()
        }
    }

    /// Settle now for the live buffer and caret. The debounced path lands here;
    /// the test calls it directly and awaits the returned task.
    @discardableResult
    func settleNow() -> Task<Void, Never>? {
        generation += 1
        let token = generation
        guard let textView, let snapshot, let fileID = fileID(),
              let language = language(), TagElementExtraction.supports(language) else {
            apply(.none)
            return nil
        }
        let selection = textView.selectedRange()
        guard selection.length == 0, selection.location != NSNotFound else {
            apply(.none)
            return nil
        }
        let text = textView.string
        let caret = selection.location
        return Task { [weak self] in
            let tree = await snapshot.tree(text: text, language: language, fileID: fileID)
            guard let self, token == self.generation else { return }
            guard let tree else {
                self.apply(.none)
                return
            }
            let enclosing = TagElementExtraction.enclosingElements(in: tree, language: language, at: caret)
            let pairActive = BracketMatchEngine.pair(text: text as NSString, selectedRange: selection) != nil
            self.apply(TagMatchRule.highlight(caret: caret, enclosing: enclosing, bracketPairActive: pairActive))
        }
    }

    /// A character edit landed: drop what is scheduled, in flight and painted.
    func noteEdit() {
        clear()
    }

    /// A tab switch or teardown.
    func reset() {
        clear()
    }

    // MARK: - Internals

    private func clear() {
        pendingTask?.cancel()
        pendingTask = nil
        generation += 1
        apply(.none)
    }

    private func apply(_ highlight: TagMatchRule.Highlight) {
        let length = textView?.textStorage?.length ?? 0
        let ranges = highlight.tagRanges.filter { $0.length > 0 && NSMaxRange($0) <= length }
        paintedRanges = ranges
        overlayLayoutManager?.setTagRanges(ranges)
        onBracketPairSuppression(highlight.suppressBracketPair)
    }
}

#endif
