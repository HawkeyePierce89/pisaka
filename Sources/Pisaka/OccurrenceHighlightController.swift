#if os(macOS)
import AppKit
import Combine
import PisakaCore

/// Drives the editor's occurrence and selection-match highlight (R2/R3): it
/// schedules `OccurrenceHighlightModel.settle` behind a short debounce, and
/// paints what the model publishes through `BracketOverlayLayoutManager`'s
/// lowest background layer.
///
/// Every decision is the model's — which mode a selection asks for, where the
/// answer comes from, which answer is stale — so this class only schedules,
/// slices and paints. Owned by `CodeEditorView`'s coordinator **alone**: the
/// source viewer, diff/merge, the Markdown preview and the database viewer never
/// get one.
///
/// **A reader.** It writes temporary attributes only, through the layout
/// manager: no undo entry, no dirty flag, no path to the save funnel.
///
/// **Edits.** The coordinator calls `noteEdit()` from the text storage's
/// edit notification *after* `BracketHighlightController.noteEdit` has dropped
/// every background overlay in pre-edit coordinates. The model's clear then
/// reaches `setOccurrenceRuns([])` as a no-op, so this class never removes an
/// attribute at post-edit offsets the storage has not shifted yet.
///
/// **On-screen slice.** Like the search bar's matches, only the runs that
/// intersect the visible character range are pushed — `refreshVisible()` is
/// re-run on every publish, scroll and resize — so a name used ten thousand
/// times costs one write per occurrence on screen, not per occurrence in the
/// file.
@MainActor
final class OccurrenceHighlightController {
    /// The model deciding what is painted. Exposed for the app-layer test,
    /// which awaits its published state rather than a clock.
    let model: OccurrenceHighlightModel

    /// The text view being highlighted, held weakly like every editor
    /// controller's.
    private weak var textView: NSTextView?

    /// The buffer the editor is showing and its language and URL, read at the
    /// moment a settle is asked rather than cached, so a tab switch never
    /// settles one file under another's identity.
    var fileID: () -> UUID? = { nil }
    var language: () -> SyntaxLanguage? = { nil }
    var fileURL: () -> URL? = { nil }

    /// The debounce between a selection change and the settle it schedules.
    static let debounceInterval: Duration = .milliseconds(75)

    /// The scheduled settle; cancelled by any newer selection change, an edit
    /// or a reset.
    private var pendingTask: Task<Void, Never>?

    /// The model's published answer, as last delivered to the subscription.
    /// Kept here because `@Published` delivers in `willSet`, before the model's
    /// own property holds the new value.
    private var highlights: [OccurrenceHighlight] = []
    private var highlightsFileID: UUID?

    private var subscription: AnyCancellable?

    /// The runs last handed to the layout manager. `internal` for the
    /// app-layer test, which asserts only on-screen runs are pushed.
    private(set) var pushedRuns: [BracketOverlayLayoutManager.OccurrenceRun] = []

    /// Resolved dynamically, for `BracketHighlightController`'s reason:
    /// `replaceLayoutManager` can swap the manager under the text view.
    private var overlayLayoutManager: BracketOverlayLayoutManager? {
        textView?.layoutManager as? BracketOverlayLayoutManager
    }

    /// The code-intelligence seam, read at each settle. Set by the coordinator
    /// after construction (it reads `symbolIndex.provider`), and by the test.
    var provider: () -> CodeIntelligenceProviding? {
        get { model.provider }
        set { model.provider = newValue }
    }

    init() {
        model = OccurrenceHighlightModel()
        subscription = model.$highlights
            .combineLatest(model.$fileID)
            .sink { [weak self] highlights, fileID in
                MainActor.assumeIsolated {
                    self?.highlights = highlights
                    self?.highlightsFileID = fileID
                    self?.refreshVisible()
                }
            }
    }

    /// Bind the controller to the editor's text view.
    func attach(textView: NSTextView) {
        self.textView = textView
    }

    // MARK: - Triggers

    /// The selection moved: settle after the debounce. Any settle already
    /// scheduled is superseded.
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

    /// Ask the model now, for the live buffer and selection. The debounced path
    /// lands here; the test calls it directly and awaits the returned task.
    @discardableResult
    func settleNow() -> Task<Void, Never>? {
        guard let textView, let fileID = fileID() else { return nil }
        return model.settle(
            text: textView.string,
            selection: textView.selectedRange(),
            language: language(),
            fileURL: fileURL(),
            fileID: fileID
        )
    }

    /// A character edit landed: drop the scheduled settle and everything
    /// published or in flight. The selection change that follows schedules the
    /// next settle.
    func noteEdit() {
        pendingTask?.cancel()
        pendingTask = nil
        model.noteEdit()
    }

    /// A tab switch or teardown: nothing published or scheduled survives.
    func reset() {
        pendingTask?.cancel()
        pendingTask = nil
        model.reset()
    }

    // MARK: - Painting

    /// Push the on-screen slice of the published answer to the layout manager.
    ///
    /// Called on every publish and by the coordinator on scroll and resize. An
    /// answer for a buffer other than the shown one paints nothing.
    ///
    /// An empty or foreign answer never asks the layout manager anything: the
    /// edit-time clear publishes from inside the storage's edit notification,
    /// before the layout manager has processed the edit, and a visible-range
    /// query there would read glyphs against post-edit characters.
    func refreshVisible() {
        guard let textView, let layoutManager = overlayLayoutManager else { return }
        var runs: [BracketOverlayLayoutManager.OccurrenceRun] = []
        let length = textView.textStorage?.length ?? 0
        if !highlights.isEmpty, highlightsFileID != nil, highlightsFileID == fileID(),
           case let visible = visibleCharacterRange(textView: textView, layoutManager: layoutManager),
           visible.length > 0 {
            let end = NSMaxRange(visible)
            var index = firstHighlightIndex(endingAfter: visible.location)
            while index < highlights.count, highlights[index].range.location < end {
                let highlight = highlights[index]
                if NSMaxRange(highlight.range) <= length, highlight.range.length > 0 {
                    runs.append(.init(range: highlight.range, kind: Self.runKind(highlight.kind)))
                }
                index += 1
            }
        }
        pushedRuns = runs
        layoutManager.setOccurrenceRuns(runs)
    }

    // MARK: - Internals

    private static func runKind(_ kind: OccurrenceHighlight.Kind) -> BracketOverlayLayoutManager.OccurrenceKind {
        switch kind {
        case .read: .read
        case .write: .write
        case .selectionMatch: .selectionMatch
        }
    }

    /// Index of the first highlight ending after `location`, by binary search
    /// over the ascending answer (`EditorSearchController`'s rule: "ends
    /// after", so a run straddling the top edge is kept).
    private func firstHighlightIndex(endingAfter location: Int) -> Int {
        var low = 0
        var high = highlights.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(highlights[mid].range) <= location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// The character range on screen — the `BracketHighlightController` /
    /// `LineNumberRulerView` math, pinned across the full content width.
    private func visibleCharacterRange(textView: NSTextView, layoutManager: NSLayoutManager) -> NSRange {
        guard let textContainer = textView.textContainer else { return NSRange(location: 0, length: 0) }
        let visibleRect = textView.visibleRect
        guard visibleRect.height > 0 else { return NSRange(location: 0, length: 0) }
        let origin = textView.textContainerOrigin
        let boundingRect = NSRect(
            x: 0,
            y: visibleRect.minY - origin.y,
            width: max(visibleRect.width, textView.bounds.width),
            height: visibleRect.height
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: boundingRect, in: textContainer)
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }
}

#endif
