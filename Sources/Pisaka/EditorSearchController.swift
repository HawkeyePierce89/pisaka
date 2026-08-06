#if os(macOS)
import AppKit
import PisakaCore

/// The execution side of the editor's find/replace bar: it runs
/// `TextSearchEngine` against the live buffer, keeps the "current" match near the
/// caret, paints the matches through `BracketOverlayLayoutManager`, navigates,
/// and applies the two replace commands.
///
/// The split is the editor's usual one — every decision is pure and lives in
/// `PisakaCore` (`TextSearchEngine.matches`, `replacePlan`, `replacement`,
/// `index(nearestTo:in:forward:)`), while this class owns only the AppKit side:
/// the text view, the selection, scrolling, the undo grouping and the overlay
/// writes. It is therefore thin, view-layer code and untested like the rest of
/// `Sources/Pisaka`; `EditorSearchState` holds it weakly behind
/// `EditorSearchActions`.
///
/// **Only the on-screen matches are painted** — `BracketHighlightController`'s
/// rule, and for a sharper reason. The *scan* is whole-buffer (the counter and
/// ⌘G's wraparound both need every match), but each painted range costs an
/// `addTemporaryAttributes` call on the layout manager, and a one-character query
/// in a megabyte-scale file matches six figures of times: pushing the whole list
/// measured at ~230 ms per repaint for 180 000 matches in a 1.1 MB buffer, paid
/// on *every* keystroke in the bar and again on every caret move that changes the
/// bracket pair (`setPairRanges` repaints the same backgrounds). So
/// `applyHighlight` binary-searches the match array down to the visible character
/// range and hands the layout manager only that slice plus the current match;
/// `refreshVisibleHighlight()` re-pushes on scroll and resize (no re-scan), which
/// is what paints newly revealed matches.
///
/// **No debounce — a deliberate decision, not an oversight.** The search re-runs
/// *synchronously* on every field/toggle change and on every text edit, with no
/// timer and no generation token, unlike `MinimapTokenizer` and
/// `BracketHighlightController` which both debounce. The reason is that the work
/// is one pass of `NSString.range(of:options:range:)` over a single open file:
/// that is a memory scan, cheap enough per keystroke that coalescing it would buy
/// nothing while costing the bar its immediacy (a counter that lags the field
/// reads as broken). The **known headroom** is a heavy regular expression —
/// catastrophic backtracking, or simply an expensive pattern — over a
/// megabyte-scale file, where a per-keystroke re-run could become noticeable.
/// Nothing is built for that now; if it is ever reported, the fix is the
/// `MinimapTokenizer` shape: a short debounce plus a monotonic generation token
/// so a superseded run discards itself. Deliberately not pre-built, because the
/// debounce would otherwise be paid by every ordinary literal search.
@MainActor
final class EditorSearchController: EditorSearchActions {
    /// The editor's text view. Held weakly — the view hierarchy owns it, exactly
    /// as `Coordinator`/`BracketHighlightController` hold it.
    private weak var textView: NSTextView?

    /// The bar's observable state (window-scoped, owned by `PisakaApp`). Weak for
    /// symmetry; the app outlives this controller either way.
    private weak var state: EditorSearchState?

    /// Every match of `appliedQuery` in the buffer as of the last run, ascending
    /// by location (`TextSearchEngine.matches`' own order, which the layout
    /// manager's binary search relies on).
    private var matches: [SearchMatch] = []

    /// Index into `matches` of the one the bar considers current, or `nil` when
    /// there is none.
    private var currentIndex: Int?

    /// The query `matches` was produced for, so a view update that changed
    /// nothing is a no-op. `nil` means "nothing applied" (the bar is closed, or
    /// the buffer/state was just rebound).
    private var appliedQuery: SearchQuery?

    /// The message currently shown in the bar, re-published alongside every
    /// counter update so navigation never blanks a standing regex error.
    private var lastError: String?

    /// Whether an async refresh is already scheduled, so a burst of edits (a
    /// Replace All's plan, an IME commit) coalesces into one re-run.
    private var refreshScheduled = false

    /// Raised while this controller is applying a replacement through
    /// `insertText(_:replacementRange:)`.
    ///
    /// The editor's `Coordinator` checks it alongside its own
    /// `isApplyingProgrammaticEdit` for the same mandatory reason: `insertText`
    /// re-invokes `shouldChangeTextIn` synchronously, and the auto-pair
    /// interceptor fires on any single-character replacement — so replacing a
    /// match with `(` would otherwise auto-close it into `()`.
    private(set) var isApplyingEdit = false

    /// The overlay layout manager currently installed on the text view, resolved
    /// dynamically rather than cached (the `BracketHighlightController` rule: a
    /// `replaceLayoutManager` can swap it at any time, and a text view without the
    /// subclass simply gets no highlight instead of a crash).
    private var overlayLayoutManager: BracketOverlayLayoutManager? {
        textView?.layoutManager as? BracketOverlayLayoutManager
    }

    // MARK: - Binding

    /// Bind the controller to the editor's text view (`makeNSView`).
    func attach(textView: NSTextView) {
        self.textView = textView
        appliedQuery = nil
    }

    /// Bind (or rebind) the bar's state and register this controller as its
    /// executor. Cheap and idempotent, so both `makeNSView` and `updateNSView`
    /// may call it; a genuinely new state invalidates the applied query so the
    /// next refresh re-runs from scratch.
    func bind(state: EditorSearchState) {
        guard self.state !== state else { return }
        self.state?.unregister(actions: self)
        self.state = state
        state.register(actions: self)
        appliedQuery = nil
    }

    /// Drop the highlight and forget the cached matches (tab teardown).
    func reset() {
        clearHighlight()
        state?.unregister(actions: self)
        state = nil
        textView = nil
    }

    // MARK: - Running the search

    /// Re-run the search if anything it depends on changed.
    ///
    /// `force` is for the two cases the query comparison cannot see: a text edit
    /// and a wholesale buffer swap (a tab switch), where the pattern is unchanged
    /// but its matches are not. A closed bar clears instead of searching.
    func refresh(force: Bool = false) {
        guard let state else { return }
        guard state.isVisible else {
            clearHighlight()
            return
        }
        let query = state.currentQuery
        guard force || query != appliedQuery else { return }
        run(query: query)
    }

    /// Ask for a refresh on the next main-loop turn, coalescing a burst into one.
    ///
    /// This exists for the text-edit trigger, which fires inside
    /// `NSTextStorage.didProcessEditingNotification` — posted *before* the storage
    /// notifies its layout managers, so the temporary attributes have not yet been
    /// shifted by the edit. Painting fresh (post-edit) match backgrounds there
    /// would have the layout manager shift them straight off their characters, the
    /// mirror image of the pre-edit coordinate problem
    /// `BracketOverlayLayoutManager.clearBackgrounds(storageLength:)` documents.
    /// Hopping out of the notification lets the whole edit cycle finish first.
    ///
    /// This is *not* the debounce the type-level comment rules out: there is no
    /// timer and no delay the user can perceive — the re-run still lands in the
    /// same run-loop iteration, before anything is drawn.
    func setNeedsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh(force: true)
        }
    }

    /// Run `query` over the live buffer, keep the current match near the caret,
    /// repaint, and publish the counters.
    private func run(query: SearchQuery) {
        guard let textView else { return }
        appliedQuery = query
        let text = textView.string as NSString
        do {
            matches = try TextSearchEngine.matches(in: text, query: query)
            lastError = nil
        } catch TextSearchError.emptyPattern {
            // An empty field is incomplete input, not a mistake: blank the
            // counter, show no reason.
            matches = []
            lastError = nil
        } catch {
            matches = []
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        // Keep the cursor where the caret is rather than resetting to the first
        // match: an edit, a toggle, or a widened pattern should leave the user
        // looking at the same place in the file.
        currentIndex = TextSearchEngine.currentIndex(
            forCaretAt: textView.selectedRange().location,
            in: matches
        )
        applyHighlight()
        publish()
    }

    // MARK: - Navigation

    func findNext() { navigate(forward: true) }

    func findPrevious() { navigate(forward: false) }

    /// Step to the neighbouring match and select it, wrapping around the ends
    /// (`TextSearchEngine.index(nearestTo:in:forward:)` owns the wraparound).
    ///
    /// The origin is the selection's *end* going forward and its *start* going
    /// back, so stepping off the currently selected match works in both
    /// directions.
    private func navigate(forward: Bool) {
        refresh()
        guard let textView, !matches.isEmpty else { return }
        let selection = textView.selectedRange()
        let origin = forward ? NSMaxRange(selection) : selection.location
        guard let index = TextSearchEngine.index(nearestTo: origin, in: matches, forward: forward) else { return }
        currentIndex = index
        select(matches[index])
        applyHighlight()
        publish()
    }

    /// Select a match and scroll it into view. The range is clamped so a match
    /// list the buffer has since outgrown can never trap.
    private func select(_ match: SearchMatch) {
        guard let textView else { return }
        let range = clamped(match.range)
        guard range.location != NSNotFound else { return }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    // MARK: - Replace

    /// Replace the current match, then step to the next one.
    ///
    /// The edit is a single `insertText(_:replacementRange:)`, so the per-file
    /// undo manager records it as one ordinary undoable step, and it runs under
    /// `isApplyingEdit` so the auto-pair interceptor doesn't fire on a
    /// single-character replacement.
    func replaceCurrent() {
        guard let state, state.isVisible, let textView else { return }
        // Re-run first: the results may pre-date an edit made since, and
        // replacing a stale range would overwrite text the user never matched.
        refresh(force: true)
        guard let index = currentIndex, matches.indices.contains(index) else { return }
        let match = matches[index]
        let text = textView.string as NSString
        guard match.range.location != NSNotFound, NSMaxRange(match.range) <= text.length else { return }

        let replacement = TextSearchEngine.replacement(
            for: match,
            in: text,
            query: state.currentQuery,
            template: state.template
        )
        withProgrammaticEdit {
            textView.insertText(replacement, replacementRange: match.range)
        }
        textView.setSelectedRange(
            NSRange(location: match.range.location + (replacement as NSString).length, length: 0)
        )
        // The buffer changed under us: re-run, then advance from the new caret.
        refresh(force: true)
        navigate(forward: true)
    }

    /// Replace every match in the file as **one** undoable edit.
    ///
    /// `TextSearchEngine.replacePlan` returns the edits strictly last-to-first,
    /// so each one lies entirely before those already applied and no pending
    /// offset is ever invalidated by a length change — the plan can be walked in
    /// order against a single mutable buffer.
    ///
    /// That walk deliberately runs against an **in-memory `NSMutableString` of the
    /// spanned range**, not against the text view: the whole batch is then
    /// installed with *one* `insertText(_:replacementRange:)`. Applying the plan
    /// edit-by-edit through the text view would cost a full TextKit edit cycle per
    /// match — a tail memmove in the storage, an undo registration, the gutter's
    /// `LineStartIndex.updated` suffix shift and `BracketHighlightController`'s
    /// token trim — i.e. O(buffer × matches) on the main thread with nothing
    /// capping the match count, so a one-character query in a megabyte-scale file
    /// (the 180 000-match case this type's highlight rule already has to reckon
    /// with) would hang the app for minutes with no way to cancel.
    ///
    /// The replaced range is the *span* from the first replacement to the last
    /// rather than the whole document, so a handful of clustered matches still
    /// costs a small edit and only a file-spanning batch relayouts everything.
    /// One edit is also one undo registration — the `beginUndoGrouping` pair is
    /// kept so it can never coalesce into the user's preceding typing — so a
    /// single ⌘Z still reverses the entire replacement. The caret is left just
    /// past the first (document-order) replacement, where the per-edit walk used
    /// to leave it.
    func replaceAll() {
        guard let state, state.isVisible, let textView else { return }
        refresh(force: true)
        guard !matches.isEmpty else { return }
        let text = textView.string as NSString
        let plan = TextSearchEngine.replacePlan(
            matches: matches,
            in: text,
            query: state.currentQuery,
            template: state.template
        )
        // `first` is the greatest location and `last` the smallest — the plan is
        // strictly last-to-first — and the edits never overlap, so the batch lies
        // entirely inside `[last.location, NSMaxRange(first))`.
        guard let firstEdit = plan.first, let lastEdit = plan.last else { return }
        let spanStart = lastEdit.range.location
        let spanEnd = NSMaxRange(firstEdit.range)
        guard spanStart >= 0, spanEnd >= spanStart, spanEnd <= text.length else { return }
        let span = NSRange(location: spanStart, length: spanEnd - spanStart)

        let rewritten = NSMutableString(string: text.substring(with: span))
        for edit in plan {
            rewritten.replaceCharacters(
                in: NSRange(location: edit.range.location - spanStart, length: edit.range.length),
                with: edit.replacement
            )
        }

        let undoManager = textView.undoManager
        undoManager?.beginUndoGrouping()
        withProgrammaticEdit {
            textView.insertText(rewritten as String, replacementRange: span)
        }
        undoManager?.endUndoGrouping()

        textView.setSelectedRange(
            NSRange(location: spanStart + (lastEdit.replacement as NSString).length, length: 0)
        )
        refresh(force: true)
    }

    /// Run `body` with the programmatic-edit flag raised, so the editor's
    /// auto-pair/dedent interceptors let the replacement through untouched.
    private func withProgrammaticEdit(_ body: () -> Void) {
        isApplyingEdit = true
        defer { isApplyingEdit = false }
        body()
    }

    // MARK: - Highlight

    /// Drop every match highlight and forget the cached results.
    ///
    /// Idempotent: called from `close()`, from a refresh that finds the bar
    /// hidden, and from teardown.
    func clearHighlight() {
        guard appliedQuery != nil || !matches.isEmpty || currentIndex != nil else {
            publish()
            return
        }
        matches = []
        currentIndex = nil
        appliedQuery = nil
        lastError = nil
        overlayLayoutManager?.setSearchRanges([], current: nil)
        publish()
    }

    /// Re-derive the current match from the caret, without re-scanning.
    ///
    /// The buffer is unchanged by a mere caret move, so the match list still
    /// stands — only *which* of them is current moves. This is not cosmetic:
    /// `replaceCurrent()` re-runs first, and `run(query:)` re-derives
    /// `currentIndex` from the live caret, so without this the counter and the
    /// orange current-match highlight would keep naming the match the last run
    /// chose while Replace edited whichever match the caret had since moved to —
    /// an edit landing somewhere the user was not looking. The highlighted match
    /// and the replaced match must never disagree.
    ///
    /// Skipped while a programmatic edit is in flight: the match list is stale
    /// mid-edit and both callers re-run immediately afterwards.
    func selectionChanged() {
        guard !isApplyingEdit, let textView, let state, state.isVisible else { return }
        guard !matches.isEmpty else { return }
        let index = TextSearchEngine.currentIndex(
            forCaretAt: textView.selectedRange().location,
            in: matches
        )
        guard index != currentIndex else { return }
        currentIndex = index
        applyHighlight()
        publish()
    }

    /// Re-push the highlight for a changed visible range (a scroll or a resize),
    /// without re-running the search — the matches are unchanged, only *which* of
    /// them are on screen. The editor's `Coordinator` calls this from the same two
    /// hooks that drive `BracketHighlightController.refreshVisible()`.
    func refreshVisibleHighlight() {
        guard appliedQuery != nil else { return }
        applyHighlight()
    }

    /// Push the on-screen results into the overlay layout manager, which owns the
    /// pair → matches → current painting order.
    ///
    /// Only the matches intersecting the visible character range are handed over —
    /// see the type-level comment for why painting the whole list is not viable —
    /// found by binary search so a large file's off-screen matches are never
    /// walked. The slice keeps the ascending, non-overlapping order
    /// `setSearchRanges` requires. The current match is passed separately and is
    /// *not* clipped: navigation scrolls it into view before repainting, and the
    /// layout manager paints a `current` outside the set on top regardless.
    private func applyHighlight() {
        guard let layoutManager = overlayLayoutManager else { return }

        var ranges: [NSRange] = []
        let visible = visibleCharacterRange()
        if visible.length > 0 {
            let end = NSMaxRange(visible)
            var index = firstMatchIndex(endingAfter: visible.location)
            while index < matches.count, matches[index].range.location < end {
                let range = clamped(matches[index].range)
                if range.location != NSNotFound, range.length > 0 {
                    ranges.append(range)
                }
                index += 1
            }
        }

        let current = currentIndex.flatMap { index -> NSRange? in
            guard matches.indices.contains(index) else { return nil }
            let range = clamped(matches[index].range)
            return range.location != NSNotFound && range.length > 0 ? range : nil
        }
        layoutManager.setSearchRanges(ranges, current: current)
    }

    /// Index of the first match whose range ends after `location`, by binary
    /// search over the ascending `matches` array.
    ///
    /// "Ends after", not "starts at or after", so a match straddling the top edge
    /// of the viewport is included rather than dropped.
    private func firstMatchIndex(endingAfter location: Int) -> Int {
        var low = 0
        var high = matches.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(matches[mid].range) <= location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// The character range currently on screen, or a zero-length range when the
    /// view has no layout yet.
    ///
    /// The bounding rectangle is pinned across the full content width (the
    /// `BracketHighlightController`/`LineNumberRulerView` rule) so a horizontal
    /// scroll cannot drop a match whose row is visible.
    private func visibleCharacterRange() -> NSRange {
        guard
            let textView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
        else { return NSRange(location: 0, length: 0) }

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

    /// `range` narrowed to the live buffer, so a match list the buffer outgrew
    /// (an edit landing between a run and its use) can never raise.
    private func clamped(_ range: NSRange) -> NSRange {
        let length = textView?.textStorage?.length ?? 0
        guard range.location != NSNotFound, range.location >= 0, range.location <= length else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSIntersectionRange(range, NSRange(location: 0, length: length))
    }

    // MARK: - Publishing

    /// Hand the counters and the error text to the bar.
    ///
    /// Always through `DispatchQueue.main.async`: the common caller is a refresh
    /// driven by `updateNSView`, i.e. from *within* a SwiftUI view update, where
    /// a direct `@Published` write draws the "Publishing changes from within view
    /// updates" runtime warning (and can re-enter the update). The state drops
    /// unchanged values, so the hop settles after one pass.
    private func publish() {
        guard let state else { return }
        let count = matches.count
        let index = currentIndex
        let error = lastError
        DispatchQueue.main.async { [weak state] in
            state?.updateResults(matchCount: count, currentIndex: index, errorText: error)
        }
    }
}

#endif
