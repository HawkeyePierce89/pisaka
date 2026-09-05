#if os(macOS)
import AppKit
import PisakaCore

/// The editor's fold owner: it asks the intelligence seam where this file's
/// collapsible blocks are, holds the answer and what is folded of it, and pushes
/// both halves at the two views that draw them — the layout manager (which hides
/// the text) and the gutter (which draws the chevrons and skips the hidden
/// lines).
///
/// The split is the editor's usual one: every *decision* is pure and lives in
/// `PisakaCore` — `FoldRegionScanner`/a language server for the candidates,
/// `FoldState` for what is folded, `FoldShift` for what an edit does to both,
/// `FoldStateMemory` for what a tab switch keeps — while this class owns only
/// the scheduling, the AppKit references and the invalidations. It is therefore
/// thin, view-layer code and untested like the rest of `Sources/Pisaka`; the
/// rules it wires are covered by the Core suites and pinned by
/// `FoldingSourceGatingTests`.
///
/// **Shaped like `BracketHighlightController`**, deliberately: a cancellable
/// debounce task plus a monotonic generation token captured *synchronously*
/// before the hop, so an answer a tab switch or a further edit superseded
/// discards itself instead of drawing the previous file's chevrons. The debounce
/// is 400 ms — the same length as the diagnostics push sync's, and its own
/// scheduler rather than a chain onto it: document sync here is request-driven
/// (D2, the live buffer travels with the request through `LSPWorkspace.prepare`),
/// so there is nothing to wait for and one fewer coupling to maintain.
///
/// **Between two answers the candidates are shifted, never re-asked.** An edit
/// runs both the candidate list and the folded state through `FoldShift`, so a
/// chevron stays beside the block it names while the user types above it instead
/// of blinking out on every keystroke; the next answer to land replaces the
/// candidates and is reconciled with the folded state by header line.
///
/// **A reader.** It never raises the writer gate and is never gated by one — it
/// writes no file, registers no edit and touches the text storage not at all
/// (hiding is glyph generation, see `BracketOverlayLayoutManager`). Nothing it
/// holds is persisted: the memory is never written to the session, and it lives
/// exactly as long as the editor that owns this controller does — the viewport
/// memory's lifetime, beside which it sits (see `FoldStateMemory`).
@MainActor
final class FoldController {
    /// What a question needs, read at the moment one is asked rather than
    /// captured: the provider, the file, its language, and the indentation
    /// widths the fallback scanner measures blocks with.
    ///
    /// `HoverController.Source`'s shape and for its reason — a folder switch
    /// swaps the provider and the root under a live editor, and a closure that
    /// captured either would ask yesterday's question.
    struct Source {
        let provider: any CodeIntelligenceProviding
        let fileURL: URL?
        let language: SyntaxLanguage?
        let widths: IndentLevelWidths
    }

    /// Supplies the four inputs above, or `nil` when there is nothing to ask
    /// (a torn-down editor, an index controller that is gone). Set by the
    /// coordinator; nothing here knows where the values come from.
    var source: (() -> Source?)?

    /// The text view whose buffer is being folded, and the gutter drawing the
    /// chevrons. Held weakly: the view hierarchy owns both, exactly as the
    /// `Coordinator` and `BracketHighlightController` hold them.
    private weak var textView: NSTextView?
    private weak var ruler: LineNumberRulerView?

    /// Every block that *could* be folded in the shown buffer, in `FoldRegion`'s
    /// own order — the last answer, shifted across every edit since.
    private(set) var candidates: [FoldRegion] = []

    /// What is folded right now. The one live copy; every reader asks for it and
    /// every writer hands a whole new value back through ``apply(_:)``.
    private(set) var state = FoldState()

    /// What was folded in each file this run, keyed by the string the
    /// coordinator supplies (a canonical path, or a tab id for an unsaved
    /// buffer). Not pruned on close, cleared wholesale on a folder switch — see
    /// `FoldStateMemory`.
    private var memory = FoldStateMemory()

    /// The key `state` belongs to, i.e. the file on screen. `nil` before the
    /// first buffer is shown, which is the one state in which nothing is
    /// recorded and nothing is asked.
    private var key: String?

    /// The in-flight debounce/ask task; cancelled when a newer request lands.
    private var pendingTask: Task<Void, Never>?

    /// Monotonic token guarding a deferred ask against a newer one (a tab
    /// switch, a further edit) that landed while it was waiting out the debounce
    /// or the provider's answer.
    private var generation = 0

    /// Debounce before a non-immediate ask, coalescing a burst of keystrokes
    /// into one question.
    private let debounceInterval: Duration = .milliseconds(400)

    /// The layout manager currently installed on the text view — the half of
    /// hiding that owns the glyphs.
    ///
    /// Resolved dynamically rather than cached, for `BracketHighlightController`'s
    /// reason: `replaceLayoutManager` can swap it under the text view at any
    /// time, and a stale reference would hide text in a manager nothing draws
    /// from. A text view without the subclass installed simply folds nothing.
    private var overlayLayoutManager: BracketOverlayLayoutManager? {
        textView?.layoutManager as? BracketOverlayLayoutManager
    }

    // MARK: - Binding

    /// Bind the controller to the editor's text view and gutter (`makeNSView`).
    func attach(textView: NSTextView, ruler: LineNumberRulerView) {
        self.textView = textView
        self.ruler = ruler
    }

    // MARK: - Triggers

    /// The shown buffer changed under the user's fingers: ask again, behind the
    /// debounce. The candidates in hand were already shifted by ``noteEdit``, so
    /// nothing blinks in the meantime.
    func noteBufferChanged(text: String) {
        ask(text: text, immediate: false)
    }

    /// A different file is on screen — a tab switch, a tab open, or a retarget:
    /// record the outgoing file's folds, restore the incoming one's, and ask at
    /// once (waiting out the debounce would leave the previous file's chevrons
    /// on screen).
    ///
    /// The restored state is clamped to the incoming buffer here and reconciled
    /// against the real candidates when the answer lands — the two halves of
    /// making a remembered fold safe, in the order the information arrives.
    func noteBufferOpened(key newKey: String?, text: String) {
        if newKey != key {
            recordCurrent()
            key = newKey
            let length = (text as NSString).length
            state = newKey.flatMap { memory.state(for: $0, clampedToLength: length) } ?? FoldState()
            candidates = []
            publish()
        }
        ask(text: text, immediate: true)
    }

    /// Something the answer depends on that is not the text moved — the buffer's
    /// language, or the `.editorconfig` revision the indentation widths come
    /// from. Ask again at once: both are rare, and both change where blocks are.
    func noteConfigurationChanged(text: String) {
        ask(text: text, immediate: true)
    }

    /// One character edit landed: shift the candidates *and* the folded state
    /// across it through the one rule, so a collapsed block stays collapsed over
    /// the code it was collapsed over while the user types above it.
    ///
    /// What the edit touched is dropped by that rule, which for the folded state
    /// means the block springs open — the honest answer, since nobody knows
    /// where it ends until the next answer lands.
    func noteEdit(
        previousLineStarts: [Int],
        newLineStarts: [Int],
        editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard !candidates.isEmpty || !state.isEmpty else { return }
        candidates = FoldShift.updated(
            candidates,
            previousLineStarts: previousLineStarts,
            newLineStarts: newLineStarts,
            editedRange: editedRange,
            changeInLength: delta
        )
        let shifted = FoldShift.updated(
            state,
            previousLineStarts: previousLineStarts,
            newLineStarts: newLineStarts,
            editedRange: editedRange,
            changeInLength: delta
        )
        state = shifted
        // The one publish that runs inside `didProcessEditingNotification`: the
        // ruler's edit observer is what called this, and the layout manager has
        // not been told about the edit yet. Back the pre-edit extent out of the
        // storage's post-edit report — `Coordinator.bufferEdited`'s own
        // arithmetic, for the reason `setFoldedRanges(_:clampingInvalidationTo:)`
        // states.
        let postEditLength = textView?.textStorage?.length ?? 0
        publish(clampingInvalidationTo: max(0, postEditLength - delta))
    }

    // MARK: - Writing

    /// Install a whole new folded state — the one write every gesture funnels
    /// through, so the layout manager, the gutter and the memory can never
    /// disagree about what is hidden.
    ///
    /// The value comes from the caller: the caret rule and the reveal rule are
    /// applied in the coordinator (the one file that names them), and this is
    /// where their answers land.
    func apply(_ newState: FoldState) {
        guard newState != state else { return }
        state = newState
        publish()
    }

    /// Fold `region` if it is open, unfold it if it is folded — the chevron's
    /// gesture.
    ///
    /// One of the three places a `FoldState` mutation is spelled in the app
    /// layer, and this file is the only one that spells any of them: every other
    /// writer hands over a whole value.
    func toggleFold(_ region: FoldRegion) {
        var updated = state
        updated.toggle(region)
        apply(updated)
    }

    /// Collapse `region` — ⌘⌥←'s write, and the reason it is not `toggleFold`:
    /// *Fold* on an already-folded block must leave it folded rather than spring
    /// it open, which is what a toggle would do the moment the command is held
    /// down or pressed twice.
    func fold(_ region: FoldRegion) {
        var updated = state
        updated.fold(region)
        apply(updated)
    }

    /// Open `region` — ⌘⌥→'s write and the placeholder click's, for the mirror
    /// of the reason above.
    func unfold(_ region: FoldRegion) {
        var updated = state
        updated.unfold(region)
        apply(updated)
    }

    /// Move the fold bounds through one save's transform, exactly as the caret,
    /// the selection endpoints and the scroll anchor are moved.
    ///
    /// Deliberately the plan's remap and never ``FoldShift``: a save that trims
    /// trailing whitespace *inside* a folded block intersects it, and the shift
    /// rule would spring every collapsed block open on an unattended autosave
    /// tick. The reasoning lives on `FoldState.remapped(through:)`.
    func remap(through plan: SaveTransformPlan) {
        guard !plan.isEmpty, !state.isEmpty || !candidates.isEmpty else { return }
        // The candidates move too, and for a sharper reason than the folded state:
        // the edit shift is suppressed for a save rewrite (`isSwappingBuffer`), so
        // nothing else would move them until the next answer lands a debounce
        // later — and a chevron clicked in that window would fold a range measured
        // against the pre-save text.
        candidates = FoldRegion.remapped(candidates, through: plan)
        state = state.remapped(through: plan)
        publish()
    }

    // MARK: - Memory

    /// Record the shown file's folds under its key. Called by the funnel above
    /// and, explicitly, on the switch away from a tab — the moment the
    /// coordinator knows about and this class does not.
    func recordCurrent() {
        guard let key else { return }
        memory.record(state, for: key)
    }

    /// Drop one file's remembered folds — its text was replaced out from under
    /// it, so they describe a buffer that no longer exists. Beside
    /// `forgetViewport(for:)` and on exactly the same signal.
    func forget(key droppedKey: String) {
        memory.forget(droppedKey)
        guard droppedKey == key else { return }
        candidates = []
        state = FoldState()
        // Published unconditionally rather than through `apply(_:)`, whose
        // no-change guard would skip it whenever nothing was folded — the common
        // case — and leave the gutter drawing chevrons for a buffer that has just
        // been replaced.
        publish()
    }

    /// Drop every remembered fold, on a folder switch: a different project is a
    /// different set of files.
    ///
    /// The key goes with the entries. The coordinator clears the memory *before*
    /// it records the outgoing tab and before the incoming buffer is announced,
    /// so leaving the key behind would let either of those `recordCurrent()` calls
    /// write the previous project's file straight back into the store that was
    /// just emptied — "cleared wholesale" in the doc and one stale entry per
    /// switch in fact. A `nil` key makes both a no-op, and the announcement that
    /// follows installs the incoming file's (empty) state.
    func forgetAll() {
        memory.removeAll()
        key = nil
    }

    /// Teardown: cancel a pending ask, supersede one in flight, and empty both
    /// views — a torn-down tab must not leave a closed file's text hidden in the
    /// view that replaces it.
    func reset() {
        pendingTask?.cancel()
        pendingTask = nil
        generation += 1
        key = nil
        candidates = []
        state = FoldState()
        publish()
    }

    // MARK: - Internals

    /// Ask the seam where this buffer's blocks are, debounced unless
    /// `immediate`, and publish the answer if nothing superseded it.
    ///
    /// The token is captured **before** the hop, like every other async reader
    /// here: a tab switch during the debounce or during the provider's own wait
    /// bumps the counter, and the answer computed for the previous buffer is
    /// dropped rather than drawn over the new one. The key is compared too, so
    /// an answer cannot land on a file it was not asked about even if the
    /// counter happened to agree.
    private func ask(text: String, immediate: Bool) {
        generation += 1
        let token = generation
        pendingTask?.cancel()
        pendingTask = nil
        let askedKey = key
        let interval = debounceInterval
        pendingTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
            }
            guard let self, token == self.generation else { return }
            // Read **after** the debounce, not before it. Deriving the widths is a
            // full-buffer pass (`IndentEngine.inferIndentUnit`) over one more
            // whole-buffer `textView.string` copy, and doing it up front would
            // charge every keystroke for a question the debounce exists to ask
            // once. Nothing is lost by waiting: a newer ask would have bumped the
            // token above, so the buffer these inputs describe is still `text`.
            guard let source = self.source?() else { return }
            let request = FoldRegionRequest(
                fileURL: source.fileURL,
                text: text,
                language: source.language,
                indentWidths: source.widths
            )
            let regions = await source.provider.foldRegions(for: request)
            guard token == self.generation, askedKey == self.key else { return }
            self.pendingTask = nil
            self.applyCandidates(regions)
        }
    }

    /// A fresh answer landed: it replaces the candidates wholesale, and the
    /// folded state is re-anchored to it by header line
    /// (`FoldState.reconciled(with:)`) — so a block the source recomputed one
    /// line shorter keeps its fold over the right text, and one it no longer
    /// reports springs open.
    private func applyCandidates(_ regions: [FoldRegion]) {
        candidates = regions
        state = state.reconciled(with: regions)
        publish()
    }

    /// Hand both halves to the two views that draw them and record the result.
    ///
    /// One method rather than three call sites, because the gutter's chevrons,
    /// the hidden glyphs and the remembered state answer the same question and
    /// must never be one frame apart. Both views treat unchanged input as a
    /// no-op, so this is cheap to call unconditionally.
    ///
    /// `validExtent` is `nil` for every caller but ``noteEdit(previousLineStarts:newLineStarts:editedRange:changeInLength:)``,
    /// the one that runs inside the storage's edit notification; see
    /// `BracketOverlayLayoutManager.setFoldedRanges(_:clampingInvalidationTo:)`.
    private func publish(clampingInvalidationTo validExtent: Int? = nil) {
        overlayLayoutManager?.setFoldedRanges(state.hiddenRanges, clampingInvalidationTo: validExtent)
        ruler?.setFoldRegions(candidates, folded: state)
        recordCurrent()
    }
}

#endif
