#if os(macOS)
import AppKit

/// The editor's layout manager, extended with the overlays drawn on top of
/// Neon's syntax colors: the rainbow-by-depth bracket foregrounds
/// (`BracketDepthScanner`), the background behind the caret's matched pair
/// (`BracketMatchEngine`), and the search-bar match backgrounds
/// (`TextSearchEngine`, pushed by `EditorSearchController`).
///
/// **Why temporary attributes.** Both overlays are drawing state, not document
/// content: temporary attributes live on the layout manager rather than in the
/// text storage, so applying them registers no text edit — nothing lands in the
/// per-file undo manager and the SwiftUI binding never sees a change. (This is
/// also how Neon styles a TextKit 1 text view, so the two mechanisms share one
/// surface rather than fighting over the storage's attributes.)
///
/// **Why interception rather than an attribute provider.** Neon's
/// `LayoutManagerSystemInterface.applyStyles` writes *only* through
/// `setTemporaryAttributes(_:forCharacterRange:)`, and it **clears** the range
/// before each write — so any color applied out of band is wiped the next time
/// Neon validates that range (a scroll, an edit, a re-parse). Nor can the colors
/// come from Neon's own `attributeProvider`: a bracket has to be a *token* for
/// that to fire, and several grammars (JSON most visibly) don't capture brackets
/// at all, so the provider is never called for them. Overriding the one method
/// Neon writes through catches every write, whatever produced it, and mixes the
/// overlays back in — with `addTemporaryAttributes`, so Neon's syntax colors in
/// the same range are *merged*, never replaced.
///
/// The cached runs are the visible range's only (the owner recomputes on scroll),
/// so the per-write intersection stays small.
@MainActor
final class BracketOverlayLayoutManager: NSLayoutManager {
    /// One colored bracket: a length-1 character range and the color to paint it.
    typealias BracketRun = (range: NSRange, color: NSColor)

    /// The rainbow runs currently applied, sorted ascending by `range.location`
    /// (the owner hands over a `BracketDepthScanner` slice, which is already
    /// sorted). Sortedness is what lets `applyOverlays` binary-search rather than
    /// scan the whole slice on every one of Neon's per-token writes.
    private var rainbowRuns: [BracketRun] = []

    /// The caret's matched pair (0 or 2 length-1 ranges).
    private var pairRanges: [NSRange] = []

    /// Every search-bar match currently highlighted, sorted ascending by
    /// `location` and non-overlapping (`TextSearchEngine.matches` produces them in
    /// that order). Sortedness is what lets `paintBackgrounds` binary-search the
    /// slice intersecting a write instead of scanning every match in the file.
    private var searchRanges: [NSRange] = []

    /// The match the search bar considers current (⌘G's cursor), painted on top of
    /// its own `searchRanges` entry in a distinct color. `nil` while the bar is
    /// closed, the pattern matches nothing, or the query is invalid.
    private var currentSearchRange: NSRange?

    /// Guards against re-entering the override while *we* are the ones writing.
    /// `addTemporaryAttributes` is not documented to route through
    /// `setTemporaryAttributes`, but a subclass that recursed on its own writes
    /// would be an unbounded loop rather than a glitch, so the flag is cheap
    /// insurance — and it also keeps the bulk `setRainbowRuns`/`setPairRanges`
    /// applications from re-running the intersection logic per range.
    private var isApplyingOverlays = false

    // MARK: - Interception

    /// Neon (or anyone else) styled `charRange`: let the write land, then paint
    /// the bracket overlays that intersect it back on top.
    ///
    /// `super` clears the range and installs the incoming attributes; the overlays
    /// are then *added*, so a bracket keeps whatever else the write set for it and
    /// only its foreground/background are overridden.
    override func setTemporaryAttributes(
        _ attrs: [NSAttributedString.Key: Any],
        forCharacterRange charRange: NSRange
    ) {
        super.setTemporaryAttributes(attrs, forCharacterRange: charRange)
        applyOverlays(in: charRange)
    }

    // MARK: - Overlay state

    /// Replace the rainbow runs (the visible range's brackets) and paint them.
    ///
    /// The previous runs are not explicitly cleared: a run's color is only ever
    /// overwritten by the next write over the same character — either this one or
    /// Neon's, which repaints the visible range as it validates. `clearRainbow(in:)`
    /// covers the one case where that is not enough (an edit that stops a
    /// character being a bracket at all).
    func setRainbowRuns(_ runs: [BracketRun]) {
        rainbowRuns = runs
        withOverlayWrites {
            for run in runs {
                let range = clamped(run.range, to: storageLength)
                guard range.length > 0 else { continue }
                addTemporaryAttributes([.foregroundColor: run.color], forCharacterRange: range)
                invalidateDisplay(forCharacterRange: range)
            }
        }
    }

    /// Replace the caret's matched pair, repainting the backgrounds.
    ///
    /// An unchanged pair is a no-op: this is called on *every* caret move (the
    /// selection-change notification), while a repaint costs one write per
    /// highlighted search match — so with the find bar open, walking through plain
    /// text would otherwise repaint every on-screen match on every arrow key.
    /// Skipping is safe because the caches and the temporary attributes are only
    /// ever changed together (see `repaintBackgrounds`).
    func setPairRanges(_ ranges: [NSRange]) {
        guard ranges != pairRanges else { return }
        let cleared = backgroundRanges()
        pairRanges = ranges
        repaintBackgrounds(clearing: cleared, clampingTo: storageLength)
    }

    /// Replace the search bar's matches and its current one, repainting the
    /// backgrounds.
    ///
    /// `ranges` must be ascending by `location` and non-overlapping (what
    /// `TextSearchEngine.matches` returns, and what the visible slice
    /// `EditorSearchController.applyHighlight` takes of it preserves); `current`,
    /// when non-`nil`, is normally one of them — it is painted afterwards either
    /// way, so a `current` outside the set (one scrolled off screen) simply wins
    /// over whatever sits beneath it.
    ///
    /// The controller pushes only the *on-screen* matches, so `ranges` is bounded
    /// by the viewport rather than by the file; see its type comment for why
    /// pushing the whole list is not viable.
    ///
    /// An unchanged set is a no-op, for the same reason as `setPairRanges`: the
    /// controller re-runs and re-pushes on every view update *and* on every
    /// scroll, and each repaint costs one write per match.
    func setSearchRanges(_ ranges: [NSRange], current: NSRange?) {
        guard ranges != searchRanges || current != currentSearchRange else { return }
        let cleared = backgroundRanges()
        searchRanges = ranges
        currentSearchRange = current
        repaintBackgrounds(clearing: cleared, clampingTo: storageLength)
    }

    /// Clear *every* background overlay — the caret's pair and the search
    /// matches — in a coordinate space whose valid extent is `storageLength`,
    /// rather than the text storage's current length.
    ///
    /// This exists for the one caller that runs *inside*
    /// `NSTextStorage.didProcessEditingNotification`: the notification is posted
    /// before the storage notifies its layout managers, so the temporary
    /// attributes are still in **pre-edit** coordinates while `textStorage.length`
    /// already reports the **post-edit** length. Clamping the removal against the
    /// post-edit length silently drops a range that sits beyond it, and the shift
    /// then slides that character (background and all) back into a valid index —
    /// stranding a highlight the controller no longer tracks, so nothing ever
    /// removes it. Passing the pre-edit length keeps the removal in the same space
    /// as the attributes it is removing.
    ///
    /// Both overlays are dropped rather than shifted because both are recomputed
    /// immediately after the edit anyway: the caret's pair by the selection-change
    /// notification that follows, the search highlight by
    /// `EditorSearchController`'s re-run on the same edit.
    func clearBackgrounds(storageLength: Int) {
        let cleared = backgroundRanges()
        pairRanges = []
        searchRanges = []
        currentSearchRange = nil
        repaintBackgrounds(clearing: cleared, clampingTo: storageLength)
    }

    /// Drop the rainbow coloring over an edited range.
    ///
    /// Called from the text-storage edit observer, before the debounced rescan:
    /// the character that was a bracket a keystroke ago may not be one now, and a
    /// stale foreground would survive until something else repainted it. Removing
    /// `.foregroundColor` also drops Neon's syntax colors over the same range,
    /// which is harmless — Neon revalidates (and repaints) exactly the edited
    /// range anyway.
    ///
    /// The cached runs are dropped from the edit point *onward*, not just where
    /// they intersect: an insertion/deletion shifts every later location, so the
    /// tail of the cache no longer describes the buffer. The rescan replaces it.
    ///
    /// `range` and `storageLength` must both be in **pre-edit** coordinates, for
    /// the reason spelled out on `clearBackgrounds(storageLength:)`: this runs inside
    /// `didProcessEditingNotification`, where the temporary attributes have not yet
    /// been shifted by the edit. Handing it the raw post-edit `editedRange` would
    /// clear the characters the edit *displaced* instead of the ones it changed.
    func clearRainbow(in range: NSRange, storageLength: Int) {
        rainbowRuns.removeAll { NSMaxRange($0.range) > range.location }
        let clampedRange = clamped(range, to: storageLength)
        guard clampedRange.length > 0 else { return }
        withOverlayWrites {
            removeTemporaryAttribute(.foregroundColor, forCharacterRange: clampedRange)
        }
        invalidateDisplay(forCharacterRange: clampedRange)
    }

    // MARK: - Painting

    /// Paint every cached overlay intersecting `charRange`.
    private func applyOverlays(in charRange: NSRange) {
        guard !isApplyingOverlays else { return }
        let length = storageLength
        let range = clamped(charRange, to: length)
        guard range.length > 0 else { return }
        guard !rainbowRuns.isEmpty || hasBackgroundOverlays else { return }

        let end = NSMaxRange(range)
        withOverlayWrites {
            var index = firstRunIndex(endingAfter: range.location)
            while index < rainbowRuns.count, rainbowRuns[index].range.location < end {
                let intersection = NSIntersectionRange(rainbowRuns[index].range, range)
                if intersection.length > 0 {
                    addTemporaryAttributes(
                        [.foregroundColor: rainbowRuns[index].color],
                        forCharacterRange: intersection
                    )
                }
                index += 1
            }
            paintBackgrounds(clippedTo: range, clampingTo: length)
        }
    }

    /// **The only place in this class that adds a temporary `.backgroundColor`.**
    ///
    /// It walks the three background caches in one fixed order — pair, then
    /// matches, then the current match — so a later write wins: the current match
    /// sits on top of an ordinary match, which sits on top of the caret's pair
    /// highlight. Because that order lives in a single loop body shared by both
    /// paint paths (the state setters via `repaintBackgrounds`, and Neon's
    /// per-write repaint via `applyOverlays`), it is physically impossible for the
    /// two to disagree — the highlight cannot change color depending on whether a
    /// scroll, a re-parse, or a ⌘G painted it last. **No other method may call
    /// `addTemporaryAttributes(.backgroundColor)` directly.**
    ///
    /// The caller is responsible for the re-entrancy flag (`withOverlayWrites`)
    /// and for invalidating display; `applyOverlays` is already inside a write
    /// AppKit will draw from, while `repaintBackgrounds` invalidates explicitly.
    ///
    /// `clipRange` is the span to paint (the whole buffer for a state change, the
    /// styled range for a Neon write) and `length` its valid extent — a parameter
    /// rather than `storageLength` for the pre-edit reason spelled out on
    /// `clearBackgrounds(storageLength:)`.
    private func paintBackgrounds(clippedTo clipRange: NSRange, clampingTo length: Int) {
        let clip = clamped(clipRange, to: length)
        guard clip.length > 0 else { return }
        let theme = SyntaxTheme.shared
        let end = NSMaxRange(clip)

        for pair in pairRanges {
            let intersection = NSIntersectionRange(pair, clip)
            guard intersection.length > 0 else { continue }
            addTemporaryAttributes(
                [.backgroundColor: theme.nsMatchedPairBackground],
                forCharacterRange: intersection
            )
        }

        var index = firstSearchIndex(endingAfter: clip.location)
        while index < searchRanges.count, searchRanges[index].location < end {
            let intersection = NSIntersectionRange(searchRanges[index], clip)
            if intersection.length > 0 {
                addTemporaryAttributes(
                    [.backgroundColor: theme.nsSearchMatchBackground],
                    forCharacterRange: intersection
                )
            }
            index += 1
        }

        if let current = currentSearchRange {
            let intersection = NSIntersectionRange(current, clip)
            if intersection.length > 0 {
                addTemporaryAttributes(
                    [.backgroundColor: theme.nsCurrentSearchMatchBackground],
                    forCharacterRange: intersection
                )
            }
        }
    }

    /// Repaint every background overlay after a state change.
    ///
    /// The clear is a blanket `removeTemporaryAttribute(.backgroundColor,…)` over
    /// the ranges that *were* painted: nothing else in the editor sets a temporary
    /// `.backgroundColor` (Neon's attribute provider returns a foreground only, and
    /// the selection highlight is drawn by the text view, not through attributes),
    /// so removing the key outright cannot erase someone else's styling — which is
    /// exactly why `paintBackgrounds` must stay this class's sole writer of it.
    ///
    /// The clear and the invalidation are each **one** call over the bounding span
    /// of the ranges involved rather than one call per range. That matters because
    /// a search over a large file highlights every match in it: a per-range walk
    /// spent three AppKit calls per match on every keystroke in the find bar and
    /// every caret move, which is the difference between a responsive bar and a
    /// stalled one. Clearing the whole span (including the gaps between matches)
    /// is safe for the same reason the blanket key removal is — this class is the
    /// sole writer of temporary `.backgroundColor` — and `paintBackgrounds`
    /// immediately below restores everything that should still be painted.
    private func repaintBackgrounds(clearing cleared: [NSRange], clampingTo length: Int) {
        let clearSpan = boundingRange(cleared, clampingTo: length)
        withOverlayWrites {
            if clearSpan.length > 0 {
                removeTemporaryAttribute(.backgroundColor, forCharacterRange: clearSpan)
            }
            paintBackgrounds(clippedTo: NSRange(location: 0, length: length), clampingTo: length)
            let paintedSpan = boundingRange(backgroundRanges(), clampingTo: length)
            let dirty = union(clearSpan, paintedSpan)
            if dirty.length > 0 {
                invalidateDisplay(forCharacterRange: dirty)
            }
        }
    }

    /// The smallest range covering every non-empty entry of `ranges` (clamped to
    /// `length`), or a zero-length range when there is nothing to cover.
    private func boundingRange(_ ranges: [NSRange], clampingTo length: Int) -> NSRange {
        var lower = Int.max
        var upper = 0
        for range in ranges {
            let clampedRange = clamped(range, to: length)
            guard clampedRange.length > 0 else { continue }
            lower = min(lower, clampedRange.location)
            upper = max(upper, NSMaxRange(clampedRange))
        }
        guard lower < upper else { return NSRange(location: 0, length: 0) }
        return NSRange(location: lower, length: upper - lower)
    }

    /// `NSUnionRange` that treats a zero-length range as "nothing" rather than as
    /// a point at location 0 (which would stretch the union back to the start of
    /// the buffer).
    private func union(_ lhs: NSRange, _ rhs: NSRange) -> NSRange {
        guard lhs.length > 0 else { return rhs }
        guard rhs.length > 0 else { return lhs }
        return NSUnionRange(lhs, rhs)
    }

    /// Every range the background caches currently describe, in no particular
    /// order — what a repaint has to clear before it repaints.
    private func backgroundRanges() -> [NSRange] {
        var ranges = pairRanges
        ranges.append(contentsOf: searchRanges)
        if let currentSearchRange { ranges.append(currentSearchRange) }
        return ranges
    }

    /// Whether any background overlay is currently set (so a Neon write over a
    /// buffer with none skips the whole intersection walk).
    private var hasBackgroundOverlays: Bool {
        !pairRanges.isEmpty || !searchRanges.isEmpty || currentSearchRange != nil
    }

    /// Index of the first run whose range ends after `location` (the runs are
    /// sorted by `location`, so everything before it is entirely behind us).
    private func firstRunIndex(endingAfter location: Int) -> Int {
        var low = 0
        var high = rainbowRuns.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(rainbowRuns[mid].range) <= location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// `firstRunIndex(endingAfter:)` for the search matches, which are sorted the
    /// same way — so a file with thousands of matches costs a binary search per
    /// Neon write rather than a full scan.
    private func firstSearchIndex(endingAfter location: Int) -> Int {
        var low = 0
        var high = searchRanges.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(searchRanges[mid]) <= location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// The current text storage's length — the valid extent for every write that
    /// does *not* run inside `didProcessEditingNotification`.
    private var storageLength: Int { textStorage?.length ?? 0 }

    /// `range` narrowed to `length`, so a stale range (a cached run whose
    /// characters a concurrent edit removed) can never raise.
    ///
    /// The extent is a parameter rather than read from `textStorage` because the
    /// edit-path clears run while the storage already reports its post-edit length
    /// but the temporary attributes are still in pre-edit coordinates; see
    /// `clearBackgrounds(storageLength:)`.
    private func clamped(_ range: NSRange, to length: Int) -> NSRange {
        guard range.location != NSNotFound, length > 0 else { return NSRange(location: 0, length: 0) }
        return NSIntersectionRange(range, NSRange(location: 0, length: length))
    }

    /// Run `body` with the re-entrancy flag raised.
    private func withOverlayWrites(_ body: () -> Void) {
        isApplyingOverlays = true
        defer { isApplyingOverlays = false }
        body()
    }
}

#endif
