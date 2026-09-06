import Foundation

/// What is folded right now, in one value the whole feature reads.
///
/// The state is a set of ``FoldRegion``s — the regions the user collapsed — and
/// the **coverage** those regions hide, sorted and non-overlapping. Both halves
/// are stored, and the reason is nesting: an outer region's hidden range
/// subsumes an inner one's, so "which regions are folded" and "which offsets are
/// hidden" are genuinely two questions. Keeping the inner region is what lets
/// unfolding the outer one leave it folded; merging the coverage once, here, is
/// what keeps every reader (the caret rule, the gutter, the layout manager) from
/// re-deriving the same overlap arithmetic and disagreeing about it.
///
/// UTF-16 offsets into the whole buffer, like every other editor engine here.
/// Nothing in this file knows what the text says.
///
/// App-run lifetime, through ``FoldStateMemory`` — nothing is persisted, and the
/// buffer is never modified by any of it.
public struct FoldState: Equatable, Sendable {
    /// The folded regions, in ``FoldRegion``'s own order: header line ascending,
    /// then the longer region first. Never two equal entries.
    public private(set) var regions: [FoldRegion]

    /// What those regions hide, merged: ascending, non-overlapping, and with
    /// touching spans joined — two hidden spans that meet leave nothing visible
    /// between them, so answering "hidden" for the offset where they meet is the
    /// truth rather than a rounding of it.
    public private(set) var hiddenRanges: [NSRange]

    public init() {
        regions = []
        hiddenRanges = []
    }

    /// The state holding exactly `regions` — normalized on the way in, so a
    /// caller may hand over whatever order and duplicates it has.
    public init(regions: [FoldRegion]) {
        self.regions = FoldState.normalized(regions)
        hiddenRanges = FoldState.coverage(of: self.regions)
    }

    /// The state that folds every candidate — normalising and merging coverage
    /// exactly as `init(regions:)` does, so nested candidates collapse to one
    /// hidden set. An empty candidate list folds nothing.
    public init(foldingAll candidates: [FoldRegion]) {
        self.init(regions: candidates)
    }

    /// Nothing folded.
    public var isEmpty: Bool { regions.isEmpty }

    // MARK: - The three mutations

    /// Fold `region`. Folding one that is already folded changes nothing.
    public mutating func fold(_ region: FoldRegion) {
        guard !regions.contains(region) else { return }
        regions = FoldState.normalized(regions + [region])
        hiddenRanges = FoldState.coverage(of: regions)
    }

    /// Unfold `region` — the exact region, not whatever else covers it. An
    /// inner region stays folded when its outer one is unfolded, which is the
    /// whole reason the regions are stored beside their coverage.
    public mutating func unfold(_ region: FoldRegion) {
        guard let index = regions.firstIndex(of: region) else { return }
        regions.remove(at: index)
        hiddenRanges = FoldState.coverage(of: regions)
    }

    /// Fold `region` if it is not folded, unfold it if it is.
    public mutating func toggle(_ region: FoldRegion) {
        if isFolded(region) {
            unfold(region)
        } else {
            fold(region)
        }
    }

    // MARK: - The three questions

    /// Whether this exact region is folded. Bounds *and* header line — a region
    /// the scanner recomputed one line shorter is a different region, which is
    /// what ``reconciled(with:)`` exists to settle rather than to guess at here.
    public func isFolded(_ region: FoldRegion) -> Bool { regions.contains(region) }

    /// Whether `offset` sits **strictly inside** hidden text.
    ///
    /// Strictly: a hidden range runs from the end of its header line's content
    /// to the end of its last line's content, and both of those offsets are
    /// positions the caret may legitimately occupy — the first is where the
    /// placeholder is drawn, the second is where the text after the block
    /// resumes. Only what lies between them has no on-screen position at all,
    /// which is exactly what ``FoldCaretRule`` moves a caret out of.
    public func hides(offset: Int) -> Bool {
        for range in hiddenRanges {
            if offset <= range.location { return false }
            if offset < NSMaxRange(range) { return true }
        }
        return false
    }

    /// The hidden range that pulls the line starting at `lineStart` up onto the
    /// row above it, or `nil` when that line has a row of its own.
    ///
    /// **This is the layout's question, not the caret's**, which is why it is not
    /// ``hides(offset:)``. A line loses its own row exactly when the separator
    /// that would have broken it is hidden — the typesetter zero-advances every
    /// separator *inside* a hidden range, its first unit included — so the test is
    /// on the code unit immediately before the line's start, and it is
    /// **inclusive** of the range's own start, where the header's separator sits.
    /// The two answers diverge at exactly one shape — a hidden range ending *on*
    /// a line start, where `hides(offset: lineStart)` says "visible" about a line
    /// already laid out on the header's row and the gutter draws a second number
    /// on top of the header's. No producer makes that shape today: the scanner
    /// ends a region at its last line's content end by construction, and
    /// `LSPIntelligenceProvider.foldRegions(for:)` raises a server's end to the
    /// same place for the placeholder's sake. This still asks the layout's own
    /// question rather than borrowing the caret's, because the two are different
    /// questions and their agreeing is a property of today's producers rather
    /// than of the state.
    ///
    /// The range is returned rather than a `Bool` so a caller walking lines can
    /// skip the whole collapsed run at once instead of one hidden line at a time.
    public func hiddenRange(collapsingLineStartingAt lineStart: Int) -> NSRange? {
        guard lineStart > 0 else { return nil }
        let separator = lineStart - 1
        for range in hiddenRanges {
            if separator < range.location { return nil }
            if separator < NSMaxRange(range) { return range }
        }
        return nil
    }

    /// The folded region whose header is `line` — what the gutter asks to draw a
    /// collapsed chevron, and what the placeholder is measured from.
    ///
    /// "Containing" is the header's sense: a region *is* at the line that stays
    /// visible for it, the only line a ``FoldRegion`` names. When two folded
    /// regions share a header line (a server may report a block and a nested one
    /// opening together; the fallback scanner merges them and never can) the
    /// longer wins, because that is the one whose placeholder is drawn.
    public func folded(containing line: Int) -> FoldRegion? {
        regions.first { $0.headerLine == line }
    }

    // MARK: - The three maintenance rules

    /// This state re-anchored to a freshly computed set of candidates.
    ///
    /// A folded region survives only if a candidate with the **same header
    /// line** exists, and then takes that candidate's bounds — so a server that
    /// recomputed the block one line shorter leaves a fold that hides the right
    /// text rather than a phantom that hides one line too many. A folded region
    /// whose header line no candidate names is unfolded: the block it described
    /// is gone.
    ///
    /// The header line is the anchor rather than the bounds because it is the
    /// one thing the two sources agree on — the line the user pressed the
    /// chevron on. Bounds move whenever the block's last line does; the header
    /// only moves when the text above it does, and ``FoldShift`` has already
    /// renumbered it by then.
    ///
    /// **When a header line carries more than one candidate the closest in length
    /// wins.** The fallback scanner merges them and never offers two, but a server
    /// may report a block and a nested one opening on the same line
    /// (`list.forEach(function (x) {`), and ⌘⌥← deliberately collapses the
    /// *innermost* of those. Re-anchoring to the longest candidate would silently
    /// grow that fold to the outer block on the next answer — hiding code nobody
    /// asked to collapse. Ties keep ``FoldRegion``'s own order, so a header line
    /// with one candidate behaves exactly as it always did.
    public func reconciled(with candidates: [FoldRegion]) -> FoldState {
        guard !regions.isEmpty else { return self }
        var byHeader: [Int: [FoldRegion]] = [:]
        for candidate in candidates.sorted() {
            byHeader[candidate.headerLine, default: []].append(candidate)
        }
        return FoldState(regions: regions.compactMap { region in
            byHeader[region.headerLine]?.min {
                abs($0.hiddenRange.length - region.hiddenRange.length)
                    < abs($1.hiddenRange.length - region.hiddenRange.length)
            }
        })
    }

    /// This state made safe for a buffer of `length` UTF-16 units.
    ///
    /// ``EditorViewport/clamped(toLength:)``'s rule, applied to ranges rather
    /// than to a caret: a region that cannot fit is **dropped**, never truncated.
    /// A truncated fold would hide a span nobody computed — half a block, ending
    /// mid-line — which is a lie the layout would then draw. Dropping it merely
    /// shows the code.
    public func clamped(toLength length: Int) -> FoldState {
        let limit = max(0, length)
        return FoldState(regions: regions.filter { NSMaxRange($0.hiddenRange) <= limit })
    }

    /// This state moved through one save's transform.
    ///
    /// Fold bounds join the caret, each selection endpoint and the scroll
    /// anchor: the **same** ``SaveTransformPlan/remappedRange(_:)``, so nothing
    /// about a save can move them apart. Deliberately *not* ``FoldShift``'s
    /// three-way rule — a save that trims trailing whitespace *inside* a folded
    /// block intersects it, and dropping the fold there would spring every
    /// collapsed block open on an unattended autosave tick. A save rewrites what
    /// it was asked to rewrite and moves what it moved; it does not restructure
    /// anything, so remapping is exactly right and shifting is not.
    ///
    /// Header lines are carried unchanged: none of the three save transforms
    /// changes how many line separators precede a given line — `end_of_line`
    /// rewrites separators in place, trimming deletes only whitespace within a
    /// line, and the final newline is appended at the very end of the buffer.
    ///
    /// A region whose remapped range comes out empty is dropped, since an empty
    /// hidden range is not representable.
    public func remapped(through plan: SaveTransformPlan) -> FoldState {
        guard !plan.isEmpty, !regions.isEmpty else { return self }
        return FoldState(regions: FoldRegion.remapped(regions, through: plan))
    }

    // MARK: - Normalization

    private static func normalized(_ regions: [FoldRegion]) -> [FoldRegion] {
        var seen: Set<FoldRegion> = []
        return regions.sorted().filter { seen.insert($0).inserted }
    }

    /// The merged coverage of already-sorted-by-``FoldRegion``-order regions:
    /// sorted by location, overlapping and touching spans joined.
    private static func coverage(of regions: [FoldRegion]) -> [NSRange] {
        var merged: [NSRange] = []
        for range in regions.map(\.hiddenRange).sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSRange(
                    location: last.location,
                    length: max(NSMaxRange(last), NSMaxRange(range)) - last.location
                )
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

/// Where a caret may rest when part of the buffer has no position on screen.
///
/// A **single caret** — a zero-length selection — may never sit strictly inside
/// hidden text: there is no glyph there to draw it beside, so it would either
/// vanish or be drawn at a lie. The rule is directional, because the two
/// answers mean opposite things to the person pressing the key: moving forward
/// into a folded block lands *past* it, moving backward lands *before* it, so
/// one arrow press steps over the whole block and the next press does not step
/// back into it.
///
/// A selection **with length** is returned untouched. Selecting across a folded
/// block is allowed and includes the hidden text — that is what makes copying a
/// collapsed block yield the whole block, which is the behaviour the buffer
/// being unmodified promises.
///
/// Pure, and the only place this decision is made: the view layer asks it and
/// applies the answer.
public enum FoldCaretRule {
    /// Where a caret asking to be at `proposed`, coming from `previous`, may
    /// actually rest in `state`.
    ///
    /// `previous` supplies the **direction** and nothing else: a proposed
    /// location greater than it reads as forward, smaller as backward. A request
    /// carrying no direction — a click, a programmatic selection — passes a
    /// `previous` whose location is `NSNotFound`, and lands at the hidden
    /// range's start, beside the placeholder the user clicked. Equal locations
    /// read as no direction for the same reason: nothing moved.
    ///
    /// `NSNotFound` or a negative `proposed` location names no position and is
    /// returned untouched.
    public static func caret(for proposed: NSRange, previous: NSRange, in state: FoldState) -> NSRange {
        guard proposed.length == 0, proposed.location != NSNotFound, proposed.location >= 0 else { return proposed }
        guard let hidden = state.hiddenRanges.first(where: {
            $0.location < proposed.location && proposed.location < NSMaxRange($0)
        }) else { return proposed }
        let movingForward = previous.location != NSNotFound
            && previous.location >= 0
            && proposed.location > previous.location
        let landing = movingForward ? NSMaxRange(hidden) : hidden.location
        return NSRange(location: landing, length: 0)
    }
}

/// Opening what a jump is about to land in.
///
/// Every jump-to-a-range in the editor — a find-bar match, a Find in Files row,
/// Go to Definition, a Problems row, a Usages row — goes through one funnel, and
/// this is the rule that funnel applies before it selects and scrolls. Revealing
/// a range that is hidden must *unhide* it first: scrolling to text with no
/// on-screen position lands the reader somewhere arbitrary.
public enum FoldReveal {
    /// `state` with every folded region that `range` reaches unfolded.
    ///
    /// **Every** intersecting region, in one pass, nested ones included:
    /// unfolding only the innermost would leave the text hidden by the outer one
    /// that still covers it, so a reveal that opened one fold would still land on
    /// nothing.
    ///
    /// The overlap test is `range.location < hiddenEnd && rangeEnd > hidden.location`,
    /// which is deliberately not `NSIntersectionRange`: a zero-length range — a
    /// caret reveal — shares no unit with anything and would never intersect,
    /// while this test unfolds exactly when that caret sits strictly inside. A
    /// range that only touches the header line's own text ends at or before the
    /// hidden range's start and unfolds nothing, which is right: it is already
    /// visible.
    public static func unfolding(_ range: NSRange, in state: FoldState) -> FoldState {
        guard range.location != NSNotFound, range.location >= 0, !state.isEmpty else { return state }
        let end = NSMaxRange(range)
        return FoldState(regions: state.regions.filter { region in
            let hidden = region.hiddenRange
            let reaches = range.location < NSMaxRange(hidden) && end > hidden.location
            return !reaches
        })
    }
}

/// The per-file fold store: "what was folded in each file this run?".
///
/// Keyed by a `String` the app supplies — the canonical path for a url-backed
/// file, the tab id for an unsaved buffer — because `OpenFile.id` is a fresh
/// `UUID` per open and closing a file would therefore lose its folds. The key is
/// the *file*, not the tab, so reopening one in the same run finds its folds
/// again.
///
/// **There is deliberately no `prune(keeping:)`**, which is where this diverges
/// from ``EditorViewportMemory``: a viewport is where you were reading and is
/// meaningless once you left, while a fold is a statement about the file's
/// structure that the user made on purpose. Closing a tab must not discard it.
/// The store is cleared wholesale on a folder switch (a different project is a
/// different set of files) and is never written to the session — nothing here is
/// persisted.
///
/// **It lives exactly as long as the editor that owns it**, which on macOS is
/// the same lifetime ``EditorViewportMemory`` has: the app holds one of these
/// per code editor, so dismantling that view — closing the *last* text tab, or
/// selecting a database-viewer tab, both of which replace the editor with
/// another surface — empties it along with everything else the view held. The
/// divergence above is about `prune(keeping:)` alone, and it is what makes
/// closing one tab of several, then reopening that file, find its folds again.
///
/// **Every entry carries the length of the buffer it was recorded against, and a
/// restore refuses when the incoming buffer is a different length.** That is the
/// one thing this store can check about text it does not hold, and it is needed
/// because the signal that invalidates folds elsewhere — `WorkspaceModel`'s
/// text-replacement token — exists only for *open* files: a file folded, closed,
/// rewritten on disk (a branch switch, an external editor) and reopened arrives
/// with a fresh `OpenFile.id` and no recorded token, so nothing else would ever
/// say that its regions describe text that is gone. Restoring them there is not
/// merely a stale range: ``FoldState/reconciled(with:)`` re-anchors by header
/// line, so the fold would latch onto whatever block now opens on that line and
/// stay collapsed over code nobody folded. A length is a coarse fingerprint and
/// deliberately so — it is O(1), and this is read on every publish — but it is
/// strictly stronger than ``FoldState/clamped(toLength:)``, which only asks
/// whether the regions still *fit*.
public struct FoldStateMemory {
    /// One file's entry: what was folded, and how long the buffer it was
    /// measured against was.
    private struct Entry {
        var state: FoldState
        var textLength: Int
    }

    private var states: [String: Entry] = [:]

    public init() {}

    /// Remember what is folded in `key`, in a buffer of `textLength` UTF-16
    /// units. An empty state is stored rather than removed, so "unfolded
    /// everything" survives a tab switch as itself.
    public mutating func record(_ state: FoldState, for key: String, textLength: Int) {
        states[key] = Entry(state: state, textLength: textLength)
    }

    /// What was folded in `key`, or `nil` when there is no usable answer — a
    /// file being shown for the first time, or one whose buffer is no longer the
    /// length it was folded in, both of which the view layer opens unfolded.
    ///
    /// The surviving state is still clamped: the two guards answer different
    /// questions — the length gate asks whether this is the same text at all,
    /// the clamp whether each region fits — and only the second of them is
    /// meaningful once a save's remap has moved the entry.
    public func state(for key: String, inBufferOfLength length: Int) -> FoldState? {
        guard let entry = states[key], entry.textLength == length else { return nil }
        return entry.state.clamped(toLength: length)
    }

    /// Drop `key`'s entry — used when the file's text was replaced out from
    /// under a background tab, where the remembered folds describe text that no
    /// longer exists.
    public mutating func forget(_ key: String) {
        states.removeValue(forKey: key)
    }

    /// Move `key`'s entry through one save's transform — the off-screen half of
    /// ``FoldState/remapped(through:)``.
    ///
    /// A save that reaches a tab no editor is showing rewrites it through the
    /// model, which is the same replacement signal a Replace All or a revert
    /// raises, and those *do* invalidate what was folded. A save does not: it
    /// moves text without restructuring it, so the folds this file remembers
    /// travel through the plan exactly as the shown buffer's do rather than being
    /// dropped — otherwise an unattended autosave would open every fold in a
    /// background tab, which is the very thing choosing the plan's remap over
    /// ``FoldShift`` exists to prevent.
    ///
    /// Nothing recorded for `key` is nothing to move: a file this store has never
    /// been told about is left absent rather than gaining an empty entry, which
    /// would claim "unfolded everything" for a file nobody has opened.
    ///
    /// The recorded length travels with the regions, taken from the plan's own
    /// resulting text: a save that trims whitespace or appends a final newline
    /// changes how long the buffer is, and an entry left claiming the pre-save
    /// length would be refused by the length gate on the next open — dropping
    /// precisely the folds this method exists to carry across.
    public mutating func remap(_ key: String, through plan: SaveTransformPlan) {
        guard let entry = states[key] else { return }
        states[key] = Entry(
            state: entry.state.remapped(through: plan),
            textLength: (plan.text as NSString).length
        )
    }

    /// Drop everything, on a folder switch.
    public mutating func removeAll() {
        states.removeAll()
    }
}

/// Which block *Fold* collapses and which one *Unfold* opens.
///
/// Both commands ask the same shape of question — "the innermost region the
/// caret is in" — of two different sets: *Fold* of the **candidates** (every
/// block that could be collapsed) and *Unfold* of the **folded** ones. Keeping
/// that one containment test here, rather than once per command in the view, is
/// what stops the keyboard and the gutter from disagreeing about which block the
/// caret is in.
///
/// **Containment is the block's whole extent, header line included.** A region
/// names one line (its header) and one span (what it hides, starting at the end
/// of that header's content), so a caret is inside it when it sits on the header
/// line *or* strictly past the hidden range's start and no further than its end
/// — the last of those being the end of the block's final line, which is still
/// the block. A caret on the line after the block is outside it.
///
/// **Innermost is the last in ``FoldRegion``'s own order.** That order is header
/// line ascending, then the longer region first, so within a nested chain — and
/// only a nested chain can contain one caret — the innermost region sorts last.
/// One ordering key, never a second notion of "smaller".
///
/// Pure, like every other decision here: the view resolves nothing, applies the
/// answer, and beeps when there is none.
public enum FoldCommandRule {
    /// The candidate *Fold* collapses, or `nil` when there is none to collapse
    /// and the command beeps.
    ///
    /// **The refusal**: a selection whose end reaches past the block is a
    /// statement about more text than the block holds, and collapsing the block
    /// would hide part of what the user has selected while leaving the rest on
    /// screen. Nothing here guesses at a bigger region to fold instead — the
    /// caret is the command's input, and a selection that disagrees with it is
    /// answered with "no", not with a different block.
    ///
    /// A zero-length selection — the ordinary caret — never refuses: it has no
    /// end to reach past.
    public static func regionToFold(
        selection: NSRange,
        lineStarts: [Int],
        in candidates: [FoldRegion]
    ) -> FoldRegion? {
        guard let region = innermost(candidates, containing: selection, lineStarts: lineStarts) else { return nil }
        guard selection.length == 0 || NSMaxRange(selection) <= NSMaxRange(region.hiddenRange) else { return nil }
        return region
    }

    /// The folded region *Unfold* opens, or `nil` when the caret is in no folded
    /// block and the command beeps.
    ///
    /// No refusal of its own: opening a block can never hide anything, so a
    /// selection reaching past it is no reason to say no.
    public static func regionToUnfold(
        selection: NSRange,
        lineStarts: [Int],
        in state: FoldState
    ) -> FoldRegion? {
        innermost(state.regions, containing: selection, lineStarts: lineStarts)
    }

    /// The innermost of `regions` containing `selection`'s **start**, or `nil`.
    ///
    /// The start rather than the whole selection, because that is where the
    /// caret is and both commands are about the caret; what the other end
    /// reaches is the refusal's question, not this one's. A selection naming no
    /// position at all is in no region.
    private static func innermost(
        _ regions: [FoldRegion],
        containing selection: NSRange,
        lineStarts: [Int]
    ) -> FoldRegion? {
        guard selection.location != NSNotFound, selection.location >= 0, !regions.isEmpty else { return nil }
        let offset = selection.location
        let line = LSPPositionMap.lineIndex(containing: offset, lineStarts: lineStarts)
        return regions.filter { region in
            region.headerLine == line
                || (offset > region.hiddenRange.location && offset <= NSMaxRange(region.hiddenRange))
        }.sorted().last
    }
}
