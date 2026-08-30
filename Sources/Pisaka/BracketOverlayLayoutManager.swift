#if os(macOS)
import AppKit
import PisakaCore

/// The editor's layout manager, extended with the overlays drawn on top of
/// Neon's syntax colors: the rainbow-by-depth bracket foregrounds
/// (`BracketDepthScanner`), the background behind the caret's matched pair
/// (`BracketMatchEngine`), the search-bar match backgrounds (`TextSearchEngine`,
/// pushed by `EditorSearchController`), and the diagnostic squiggle underlines
/// (pushed by `CodeEditorView.Coordinator` out of `DiagnosticsModel`).
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

    /// Every diagnostic underline currently shown, sorted ascending by
    /// `range.location` and **non-overlapping** — `setDiagnosticRuns` merges the
    /// incoming set so every character is covered by exactly one span carrying
    /// the worst severity that covers it (the rule `drawUnderline` also applies
    /// when a fragment straddles two adjacent merged runs). Sortedness and non-overlap
    /// are what let both paint paths binary-search the cache the way they search
    /// the rainbow runs.
    private var diagnosticRuns: [DiagnosticRun] = []

    /// Set when `clearDiagnostics` drops cached runs whose underline attributes
    /// may outlive them, and consumed by the next `setDiagnosticRuns`.
    ///
    /// Truncating the cache removes the *cache* entries, not the temporary
    /// attributes over them: TextKit shifts attributes across an edit like any
    /// other state, so the surviving tail of a dropped run stays painted even
    /// though nothing in the store will repaint or describe it (`drawUnderline`
    /// draws nothing on a cache miss, but the attribute is still there for any
    /// future reader). The next wholesale push must therefore clear from the
    /// first dropped character onward — not merely over what the truncated
    /// cache says was painted, which is exactly the bookkeeping that was lost.
    private var stalePaintStart: Int?

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

    // MARK: - Diagnostics

    /// The underline style a diagnostic is painted with. `[.single, .patternDot]`
    /// is a **marker**, not a look: nothing else in this editor sets a temporary
    /// `.underlineStyle` (spelling, grammar and text substitution are off in the
    /// editor; Neon writes colors only), so the dotted pattern doubles as an
    /// unambiguous "this underline is ours" bit that `drawUnderline` tests before
    /// drawing its wave — AppKit would otherwise have rendered it as a dotted
    /// straight line.
    static let diagnosticUnderlineStyle: NSUnderlineStyle = [.single, .patternDot]

    /// Forget what the cache believes is painted, ahead of a wholesale buffer
    /// replacement.
    ///
    /// Replacing the text view's whole `string` makes TextKit drop every
    /// temporary attribute over the replaced characters, so *nothing* is
    /// painted afterwards — but the cache still describes the outgoing
    /// document, and `setDiagnosticRuns` returns early when the incoming
    /// document's merged runs happen to equal it. Two files with the same error
    /// at the same offset (the same bad `import` on line 1, say) are exactly
    /// that case, and the switch would land on an unpainted buffer whose gutter
    /// still shows the severity dots — the ruler draws from its own array, which
    /// the swap does not wipe.
    ///
    /// Called on **every** content replacement, including the plain tab switch
    /// where the outgoing document's *store entry* deliberately survives: what
    /// survives there is the model's set, not this view's paint, and the
    /// repaint that follows the swap restores it.
    ///
    /// No attribute is removed here — the swap has already removed them all —
    /// so `stalePaintStart` is cleared with the cache rather than widened.
    func invalidateDiagnosticPaint() {
        diagnosticRuns = []
        stalePaintStart = nil
    }

    /// Replace the diagnostic underlines wholesale and repaint them.
    ///
    /// The incoming runs may overlap freely (a server can publish nested spans);
    /// `DiagnosticRun.merged(_:)` — Core's, with the whole algorithm and its
    /// zero-length rule — puts them into the cache's canonical non-overlapping
    /// form: sorted by location, each overlapping stretch carrying the *worst* of
    /// the severities that touched it (`DiagnosticSeverity` orders by
    /// seriousness). Resolving at the single write boundary means every later
    /// reader — the per-write repaint below, and the zigzag in `drawUnderline`
    /// when a fragment straddles two adjacent merged runs — sees one severity per
    /// character and cannot disagree about which color wins.
    ///
    /// An unchanged set is a no-op: this runs on every diagnostics-model change
    /// and every keystroke-driven shift re-push, while a repaint costs one clear
    /// span plus one write per run.
    ///
    /// Unlike the rainbow setter this one *removes* the old underline attributes
    /// first, over the bounding span of what was painted before: the diagnostic
    /// cache covers the whole document rather than the visible slice, so there is
    /// no Neon revalidation guaranteed to sweep a run that just went away. The
    /// removal is safe because this class is the only writer of the marker style
    /// (see `diagnosticUnderlineStyle`). When `clearDiagnostics` truncated the
    /// cache since the last push, the clear widens to everything from the first
    /// dropped character onward (`stalePaintStart`) — the truncated cache no
    /// longer knows what was painted past it.
    func setDiagnosticRuns(_ runs: [DiagnosticRun]) {
        let merged = DiagnosticRun.merged(runs)
        guard merged != diagnosticRuns || stalePaintStart != nil else { return }
        let previous = diagnosticRanges()
        diagnosticRuns = merged

        let length = storageLength
        let previousSpan = boundingRange(previous, clampingTo: length)
        var clearedSpan = previousSpan
        if let staleStart = stalePaintStart {
            stalePaintStart = nil
            // The residue sits anywhere from `stalePaintStart` to the end of
            // the (post-edit) buffer — TextKit shifted it across the edit, and
            // `clearDiagnostics` floored the recorded value at the edit's own
            // location so a deletion's leftward shift stays inside the span.
            // One removal over that whole span costs no more than the
            // bounding-span clear it replaces, and over-clearing is safe: this
            // class is the sole writer of these keys, and the paint below
            // restores every survivor immediately.
            let start = previousSpan.length > 0 ? min(previousSpan.location, staleStart) : staleStart
            clearedSpan = start < length ? NSRange(location: start, length: length - start) : clearedSpan
        }
        withOverlayWrites {
            if clearedSpan.length > 0 {
                removeTemporaryAttribute(.underlineStyle, forCharacterRange: clearedSpan)
                removeTemporaryAttribute(.underlineColor, forCharacterRange: clearedSpan)
            }
            paintDiagnosticUnderlines(clippedTo: NSRange(location: 0, length: length), clampingTo: length)
        }
        let paintedSpan = boundingRange(diagnosticRanges(), clampingTo: length)
        let dirty = union(clearedSpan, paintedSpan)
        if dirty.length > 0 {
            invalidateDisplay(forCharacterRange: dirty)
        }
    }

    /// Drop the diagnostic coloring over an edited range, ahead of the deferred
    /// re-push from the store.
    ///
    /// The cached runs are dropped from the edit point *onward*, like
    /// `clearRainbow`'s: an insertion/deletion shifts every later location, so
    /// the tail of the cache no longer describes the buffer. What survives is
    /// repainted by the coordinator's next push, which rebuilds the cache from
    /// `DiagnosticsModel` — where ``DiagnosticShift.updated`` has already applied
    /// exactly the same shift-and-drop arithmetic to the stored set — and that
    /// push also clears what this truncation strands: a dropped run's attribute
    /// survives the edit (shifted with its characters) but not in any cache, so
    /// the first dropped run's start is handed to `setDiagnosticRuns` through
    /// `stalePaintStart`.
    ///
    /// `range` and `storageLength` must both be in **pre-edit** coordinates, for
    /// the reason spelled out on `clearBackgrounds(storageLength:)` — this runs
    /// inside `didProcessEditingNotification`, where the temporary attributes
    /// have not yet been shifted by the edit.
    func clearDiagnostics(in range: NSRange, storageLength: Int) {
        if let firstDropped = diagnosticRuns.first(where: { NSMaxRange($0.range) > range.location })?.range.location {
            // Floored at the edit's own location, which is the one offset both
            // coordinate systems agree on. `firstDropped` is a *pre-edit* start
            // and the residue is read back in *post-edit* space: a deletion
            // shifts the surviving tail of a dropped run left, to below that
            // start, so recording it alone would clear from above the residue
            // and leave the squiggle painted under text that no longer carries a
            // diagnostic. Nothing can shift below `range.location` — everything
            // from there to the edit's end is cleared outright here — so the
            // floor is exact, not merely safe. The `min` with `firstDropped`
            // still matters for a run straddling the edit's start, whose head
            // survives *unmoved* at a lower offset than the edit.
            stalePaintStart = min(stalePaintStart ?? Int.max, min(firstDropped, range.location))
        }
        diagnosticRuns.removeAll { NSMaxRange($0.range) > range.location }
        let clampedRange = clamped(range, to: storageLength)
        guard clampedRange.length > 0 else { return }
        withOverlayWrites {
            removeTemporaryAttribute(.underlineStyle, forCharacterRange: clampedRange)
            removeTemporaryAttribute(.underlineColor, forCharacterRange: clampedRange)
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
        guard !rainbowRuns.isEmpty || !diagnosticRuns.isEmpty || hasBackgroundOverlays else { return }

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
            paintDiagnosticUnderlines(clippedTo: range, clampingTo: length)
            paintBackgrounds(clippedTo: range, clampingTo: length)
        }
    }

    /// Paint the diagnostic underlines intersecting `clipRange` — the fourth
    /// overlay cache's writer, called from both paint paths (`applyOverlays` for
    /// Neon's per-write repaint and `setDiagnosticRuns` after a state change) so
    /// a squiggle cannot vanish because Neon revalidated its characters.
    ///
    /// The underline lives on `.underlineStyle`/`.underlineColor`, keys neither
    /// Neon nor any other editor component writes, so this cannot fight the
    /// foreground/background writers and the class's "sole writer of
    /// `.backgroundColor`" rule is untouched. The color resolves at write time
    /// through `SyntaxTheme`'s dynamic colors, so an appearance switch re-renders
    /// without a re-push.
    private func paintDiagnosticUnderlines(clippedTo clipRange: NSRange, clampingTo length: Int) {
        guard !diagnosticRuns.isEmpty else { return }
        let clip = clamped(clipRange, to: length)
        guard clip.length > 0 else { return }
        let theme = SyntaxTheme.shared
        let end = NSMaxRange(clip)
        var index = firstDiagnosticIndex(endingAfter: clip.location)
        while index < diagnosticRuns.count, diagnosticRuns[index].range.location < end {
            let intersection = NSIntersectionRange(diagnosticRuns[index].range, clip)
            if intersection.length > 0 {
                addTemporaryAttributes(
                    [
                        .underlineStyle: Self.diagnosticUnderlineStyle.rawValue,
                        .underlineColor: theme.nsDiagnosticColor(for: diagnosticRuns[index].severity),
                    ],
                    forCharacterRange: intersection
                )
            }
            index += 1
        }
    }

    /// Every range the diagnostic cache currently describes — what a wholesale
    /// replacement has to clear before it repaints.
    private func diagnosticRanges() -> [NSRange] {
        diagnosticRuns.map(\.range)
    }

    /// `firstRunIndex(endingAfter:)` for the diagnostic runs, which are sorted
    /// the same way — one binary search per styled span rather than a scan of
    /// every squiggle in the file.
    private func firstDiagnosticIndex(endingAfter location: Int) -> Int {
        var low = 0
        var high = diagnosticRuns.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(diagnosticRuns[mid].range) <= location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// The worst severity among cached runs covering `charRange` — what
    /// `drawUnderline` paints a fragment straddling two adjacent merged runs
    /// with. Overlapping diagnostics within one stretch were already resolved by
    /// `setDiagnosticRuns`' merge; this answers the same question across a
    /// boundary.
    private func worstSeverity(in charRange: NSRange) -> DiagnosticSeverity? {
        guard charRange.length > 0 else { return nil }
        let end = NSMaxRange(charRange)
        var index = firstDiagnosticIndex(endingAfter: charRange.location)
        var worst: DiagnosticSeverity?
        while index < diagnosticRuns.count, diagnosticRuns[index].range.location < end {
            if NSIntersectionRange(diagnosticRuns[index].range, charRange).length > 0 {
                worst = max(worst ?? diagnosticRuns[index].severity, diagnosticRuns[index].severity)
            }
            index += 1
        }
        return worst
    }

    /// Draw a diagnostic's underline as a **zigzag** along the fragment's
    /// baseline instead of AppKit's straight line.
    ///
    /// **Why an override at all:** AppKit has no wavy underline pattern —
    /// `NSUnderlineStyle` offers only solid/dash/dot patterns, so the wave has
    /// to be stroked here. When the style carries our marker bit
    /// (`diagnosticUnderlineStyle`, whose dotted pattern nothing else in this
    /// text view ever sets) we replace the straight line; anything else falls
    /// through to `super`.
    ///
    /// **Which severity wins:** overlapping diagnostics were already coalesced
    /// per character by `setDiagnosticRuns`, so a single run answers for most
    /// fragments; when one glyph fragment straddles two adjacent runs,
    /// `worstSeverity(in:)` picks the more serious of the two — the same rule
    /// the merge applies inside a stretch, extended across its edge. A fragment
    /// under no cached run draws nothing (the attribute was written by someone
    /// else or the cache moved on; both self-correct on the next push).
    ///
    /// Geometry: `boundingRect(forGlyphRange:)` gives the x extent in *container*
    /// coordinates; the drawing context here is the text view's, so the wave is
    /// translated by the `containerOrigin` the call hands over (the same
    /// convention `drawBackground(at:)` documents). The wave rides just above
    /// the line fragment's bottom, where the descent ends, so it sits under the
    /// glyphs like AppKit's own underline.
    override func drawUnderline(
        forGlyphRange glyphRange: NSRange,
        underlineType underlineVal: NSUnderlineStyle,
        baselineOffset: CGFloat,
        lineFragmentRect lineRect: NSRect,
        lineFragmentGlyphRange lineGlyphRange: NSRange,
        containerOrigin: NSPoint
    ) {
        guard underlineVal.contains(Self.diagnosticUnderlineStyle) else {
            super.drawUnderline(
                forGlyphRange: glyphRange,
                underlineType: underlineVal,
                baselineOffset: baselineOffset,
                lineFragmentRect: lineRect,
                lineFragmentGlyphRange: lineGlyphRange,
                containerOrigin: containerOrigin
            )
            return
        }
        let charRange = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard let severity = worstSeverity(in: charRange) else { return }
        // One container per editor (`makeNSView`'s TextKit 1 construction swaps
        // in exactly one), so "the container this fragment belongs to" is the
        // first one.
        guard let container = textContainers.first else { return }
        let bounds = boundingRect(forGlyphRange: glyphRange, in: container)
        guard bounds.width > 0 else { return }

        // Wave parameters tuned against the code font at default zoom: small
        // enough to read as decoration over dense text, deep enough to tell a
        // warning from a hint at arm's length.
        let amplitude: CGFloat = 1.5
        let wavelength: CGFloat = 4
        let lineWidth: CGFloat = 1
        let baselineY = max(lineRect.minY, min(lineRect.maxY - amplitude - lineWidth, lineRect.maxY))
            + containerOrigin.y

        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        var x = bounds.minX + containerOrigin.x
        let maxX = bounds.maxX + containerOrigin.x
        var up = true
        path.move(to: NSPoint(x: x, y: baselineY))
        while x < maxX {
            x = min(x + wavelength / 2, maxX)
            path.line(to: NSPoint(x: x, y: up ? baselineY - amplitude : baselineY + amplitude))
            up.toggle()
        }
        SyntaxTheme.shared.nsDiagnosticColor(for: severity).setStroke()
        path.stroke()
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
