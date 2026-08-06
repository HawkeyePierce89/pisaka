#if os(macOS)
import AppKit
import PisakaCore

/// Drives the editor's two bracket overlays: it owns the cached
/// `BracketDepthScanner` result for the current buffer and turns both engines'
/// answers into the color/background writes `BracketOverlayLayoutManager` paints.
///
/// The split matches the rest of the editor: all the decisions are pure and live
/// in `PisakaCore` (`BracketDepthScanner` for the rainbow, `BracketMatchEngine`
/// for the caret's pair), while this class only schedules them, resolves colors
/// through `SyntaxTheme`, and hands ranges to the layout manager. It is therefore
/// thin, view-layer code and untested like the rest of `Sources/Pisaka`.
///
/// **Debounce and cache** follow the `MinimapTokenizer` precedent: a rescan is
/// keyed on (`fileID`, text length, edit epoch) so an unchanged buffer is a no-op,
/// coalesced by a short debounce so a burst of keystrokes scans once, and guarded
/// by a monotonic generation token so a deferred scan that a tab switch superseded
/// discards itself instead of painting the previous file's brackets. The key is an
/// O(1) identity rather than a content hash, which on this class's bridged-`NSString`
/// input would cost far more than the scan it guards — see `CacheKey`.
///
/// **Why the scan can stay on the main actor** — unlike the minimap's
/// tree-sitter parse, which is pushed off-main — is `BracketDepthScanner`'s
/// chunked `getCharacters(_:range:)` read: the pass is a plain memory walk with
/// `ceil(n / 4096)` objc message sends, not one per character, so even a
/// megabyte-scale file stays imperceptible after the debounce. Keeping it on the
/// main actor in turn means the token array is never read across actors.
///
/// **Attributes are applied to the visible range only.** The scan is over the
/// whole document (it has to be: depth at the top of the screen depends on every
/// bracket above it), but painting every bracket in a large file would be
/// pointless work — so `refreshVisible()` binary-searches the token array down to
/// the on-screen slice and hands only that to the layout manager. Scrolling
/// re-runs it (no rescan), which is what colors newly revealed brackets.
@MainActor
final class BracketHighlightController {
    /// The text view being highlighted. Held weakly: the view hierarchy owns it,
    /// exactly as the `Coordinator` holds it.
    private weak var textView: NSTextView?

    /// Every bracket in the current buffer, ascending by `location` (the scanner's
    /// own order, which `refreshVisible`'s binary search relies on).
    private var tokens: [BracketToken] = []

    /// Identifies the input `tokens` was built from, so an unchanged buffer is a
    /// no-op rather than a redundant rescan.
    private var cacheKey: CacheKey?

    /// The in-flight debounce task; cancelled when a newer update lands.
    private var pendingTask: Task<Void, Never>?

    /// Monotonic token guarding a deferred scan against a newer request (a tab
    /// switch, a further edit) that landed while it was waiting out the debounce.
    private var generation = 0

    /// Debounce before a (non-immediate) rescan, coalescing rapid keystrokes.
    private let debounceInterval: Duration = .milliseconds(100)

    /// Bumped by every character edit, so the cache key changes without having to
    /// fingerprint the buffer's contents. See `CacheKey`.
    private var editEpoch = 0

    /// Identifies the scanned input in O(1).
    ///
    /// Deliberately **not** a content hash, unlike the `MinimapTokenizer`
    /// precedent this class otherwise follows. `text` here is always
    /// `NSTextStorage.string` — a lazily-bridged `NSString` — and `String.hashValue`
    /// on one has to transcode the whole buffer: measured at ~57 ms for a 1.7 MB
    /// file, against ~1 ms for a native `String` of the same content and well under
    /// a millisecond for the bracket scan the key exists to avoid. It was computed
    /// eagerly, *before* the debounce, on both the edit and `updateNSView` paths —
    /// two full traversals per keystroke that no debounce could coalesce, which
    /// would have broken the plan's "typing in a megabyte-scale file doesn't lag"
    /// criterion outright.
    ///
    /// `editEpoch` replaces it because `noteEdit` already observes *every*
    /// character edit (the storage notification covers programmatic edits and
    /// buffer swaps too, and the observer is attached for the text view's lifetime),
    /// so a counter it bumps distinguishes buffers exactly as well. `textLength` is
    /// carried alongside as a free backstop — O(1) on a bridged `NSString` — so a
    /// length-changing edit that somehow bypassed the observer still invalidates.
    private struct CacheKey: Equatable {
        let fileID: UUID
        let textLength: Int
        let editEpoch: Int
    }

    /// The overlay layout manager currently installed on the text view.
    ///
    /// Resolved dynamically rather than cached, for the same reason the gutter and
    /// Neon do: `replaceLayoutManager` can swap the manager under the text view at
    /// any time, and a stale cached reference would paint into a manager nothing
    /// draws from. A text view without the subclass installed simply disables the
    /// overlays instead of crashing.
    private var overlayLayoutManager: BracketOverlayLayoutManager? {
        textView?.layoutManager as? BracketOverlayLayoutManager
    }

    /// Bind the controller to the editor's text view.
    func attach(textView: NSTextView) {
        self.textView = textView
    }

    // MARK: - Rainbow

    /// Rescan `text` for brackets, debounced unless `immediate` (a tab switch or a
    /// wholesale buffer swap, which must not show the previous file's colors for
    /// the length of the debounce).
    ///
    /// A request matching the cached key does nothing — except cancel a scan for a
    /// *different* key that is still pending, which would otherwise land its tokens
    /// on a buffer they no longer describe (the A→B→A tab dance the
    /// `MinimapTokenizer` guards the same way).
    func update(text: String, fileID: UUID, immediate: Bool) {
        let key = CacheKey(fileID: fileID, textLength: (text as NSString).length, editEpoch: editEpoch)
        if key == cacheKey {
            if pendingTask != nil {
                pendingTask?.cancel()
                pendingTask = nil
                generation += 1
            }
            return
        }

        generation += 1
        let token = generation
        pendingTask?.cancel()
        pendingTask = nil

        if immediate {
            applyScan(text: text, key: key)
            return
        }

        let interval = debounceInterval
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            guard let self, token == self.generation else { return }
            self.pendingTask = nil
            self.applyScan(text: text, key: key)
        }
    }

    /// An edit landed: drop the cached tokens it invalidated and clear the stale
    /// coloring over the edited range, ahead of the rescan.
    ///
    /// The tokens are dropped from the edit point *onward*, not just where they
    /// intersect: an insertion or deletion shifts every later location, so the tail
    /// of the cache no longer describes the buffer. (The layout manager trims its
    /// own applied-run cache by the same rule.) Painting is left to the rescan.
    ///
    /// `cacheKey` is cleared with them, and that is load-bearing: the truncated
    /// `tokens` now describe *no* text, so leaving the key in place would let
    /// `update` take its equal-key early return — cancelling the pending rescan and
    /// never scheduling another — for an edit that happens to restore the cached
    /// text (a typo plus Backspace inside the 100 ms debounce, an undo, an
    /// auto-paired insert immediately deleted). Every bracket past the edit point
    /// would then stay uncolored for the rest of the session. This is the one place
    /// the `MinimapTokenizer` precedent does not carry over unchanged: that class
    /// only ever replaces `model` together with its key, so its equal-key branch is
    /// always safe.
    ///
    /// The background overlays — the caret's pair *and* the search bar's matches —
    /// are cleared here too, and this is the only moment their remembered ranges are
    /// still valid: `NSTextStorage.processEditing()` posts the
    /// notification that brings us here *before* it notifies its layout managers, so
    /// the temporary attributes have not yet been shifted by the edit. Clearing
    /// later (from `updateSelection`, once the caret moved off the pair) would
    /// remove `.backgroundColor` at pre-shift coordinates and strand the highlight
    /// on whatever the edit pushed it onto. The following selection-change
    /// notification re-adds the pair at its new location, and the search highlight
    /// is restored by `EditorSearchController`'s re-run on this same edit.
    /// `editedRange`/`changeInLength` are the text storage's own, i.e. **post-edit**
    /// coordinates, while the temporary attributes this clears are still pre-edit
    /// (see above). The two are reconciled here: the pre-edit length is
    /// `postLength - changeInLength`, and the pre-edit span of the edit is the
    /// edited range with the length delta backed out — so an insertion of *k* at
    /// *L* resolves to `(L, 0)` (nothing existed there to clear, and inserted text
    /// does not inherit temporary attributes), a deletion of *k* to `(L, k)`, and a
    /// same-length replacement to itself.
    func noteEdit(in editedRange: NSRange, changeInLength: Int, postEditLength: Int) {
        guard editedRange.location != NSNotFound else { return }
        tokens.removeAll { $0.location >= editedRange.location }
        cacheKey = nil
        editEpoch &+= 1

        let preEditLength = max(0, postEditLength - changeInLength)
        let preEditRange = NSRange(
            location: editedRange.location,
            length: max(0, editedRange.length - changeInLength)
        )
        overlayLayoutManager?.clearRainbow(in: preEditRange, storageLength: preEditLength)
        overlayLayoutManager?.clearBackgrounds(storageLength: preEditLength)
    }

    /// Re-resolve and re-apply the rainbow colors for the currently visible range.
    ///
    /// Called on scroll/resize (no rescan — the tokens are unchanged, only which
    /// of them are on screen) and after every scan.
    func refreshVisible() {
        guard
            let textView,
            let layoutManager = overlayLayoutManager,
            let textContainer = textView.textContainer
        else { return }

        let theme = SyntaxTheme.shared
        var runs: [BracketOverlayLayoutManager.BracketRun] = []
        let charRange = visibleCharacterRange(textView: textView, layoutManager: layoutManager, textContainer: textContainer)
        if charRange.length > 0 {
            let end = NSMaxRange(charRange)
            var index = firstTokenIndex(atOrAfter: charRange.location)
            while index < tokens.count, tokens[index].location < end {
                let token = tokens[index]
                let color = token.isUnmatched
                    ? theme.nsUnmatchedBracketColor
                    : theme.nsBracketColor(forDepth: token.depth)
                runs.append((range: NSRange(location: token.location, length: 1), color: color))
                index += 1
            }
        }
        layoutManager.setRainbowRuns(runs)
    }

    // MARK: - Caret pair

    /// Highlight the pair `BracketMatchEngine` matches for `selectedRange`, or
    /// clear the previous one when it matches nothing (the caret moved away, or
    /// the user made a selection — which the engine deliberately declines).
    func updateSelection(_ selectedRange: NSRange) {
        guard let textView, let layoutManager = overlayLayoutManager else { return }
        guard let pair = BracketMatchEngine.pair(
            text: textView.string as NSString,
            selectedRange: selectedRange
        ) else {
            layoutManager.setPairRanges([])
            return
        }
        layoutManager.setPairRanges([pair.open, pair.close])
    }

    // MARK: - Teardown

    /// Drop the cache and cancel a pending rescan (tab teardown).
    func reset() {
        pendingTask?.cancel()
        pendingTask = nil
        generation += 1
        cacheKey = nil
        tokens = []
    }

    // MARK: - Internals

    /// Scan the buffer and repaint the visible slice.
    private func applyScan(text: String, key: CacheKey) {
        tokens = BracketDepthScanner.scan(text: text as NSString)
        cacheKey = key
        refreshVisible()
    }

    /// The character range currently on screen.
    ///
    /// Mirrors `LineNumberRulerView`'s visible-range math: the rect is converted
    /// into *text-container* coordinates, and x is pinned to 0 across the full
    /// content width (lines do not wrap) so a horizontal scroll can never drop a
    /// bracket that sits left of the visible horizontal slice but whose row is on
    /// screen. An unlaid-out view reports an empty rect, which yields an empty
    /// range — the frame-change notification refreshes once layout happens.
    private func visibleCharacterRange(
        textView: NSTextView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRange {
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

    /// Index of the first token at or after `location`, by binary search (the
    /// tokens are sorted by `location`), so a large file's off-screen brackets are
    /// never walked.
    private func firstTokenIndex(atOrAfter location: Int) -> Int {
        var low = 0
        var high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if tokens[mid].location < location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

#endif
