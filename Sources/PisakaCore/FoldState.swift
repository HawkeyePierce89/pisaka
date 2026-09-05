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
    public func reconciled(with candidates: [FoldRegion]) -> FoldState {
        guard !regions.isEmpty else { return self }
        var byHeader: [Int: FoldRegion] = [:]
        for candidate in candidates.sorted() where byHeader[candidate.headerLine] == nil {
            byHeader[candidate.headerLine] = candidate
        }
        return FoldState(regions: regions.compactMap { byHeader[$0.headerLine] })
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
        return FoldState(regions: regions.compactMap { region in
            FoldRegion(
                hiddenRange: plan.remappedRange(region.hiddenRange),
                headerLine: region.headerLine,
                kind: region.kind
            )
        })
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
/// different set of files) and dies with the app run — nothing here is ever
/// written to the session.
public struct FoldStateMemory {
    private var states: [String: FoldState] = [:]

    public init() {}

    /// Remember what is folded in `key`. An empty state is stored rather than
    /// removed, so "unfolded everything" survives a tab switch as itself.
    public mutating func record(_ state: FoldState, for key: String) {
        states[key] = state
    }

    /// What was folded in `key`, made safe for a buffer of `length` UTF-16
    /// units, or `nil` when nothing was recorded — a file being shown for the
    /// first time, which the view layer opens unfolded.
    public func state(for key: String, clampedToLength length: Int) -> FoldState? {
        states[key]?.clamped(toLength: length)
    }

    /// Drop `key`'s entry — used when the file's text was replaced out from
    /// under a background tab, where the remembered folds describe text that no
    /// longer exists.
    public mutating func forget(_ key: String) {
        states.removeValue(forKey: key)
    }

    /// Drop everything, on a folder switch.
    public mutating func removeAll() {
        states.removeAll()
    }
}
