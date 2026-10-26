import Foundation

/// Which expanded ancestors the macOS project tree pins under its header while
/// scrolling, in what order, where each copy is drawn and how tall the stack is.
/// A navigation aid only: the answer changes nothing about what the tree holds
/// or what any operation addresses.
///
/// **Input.** Each `Folder` is one folder *node* as the tree measured it: its
/// depth (`0` is the project root), whether it is expanded, and the `top` and
/// `bottom` of the whole node — its row plus its expanded subtree — in content
/// coordinates. The row itself is taken to be `[top, top + rowHeight)`, and
/// `rowHeight` is also the height of a pinned copy. A chain row is one node and
/// one `Folder`, whatever its segment count. The input order is not trusted:
/// the rule orders folders by `top` ascending, then `depth` ascending, then
/// input index.
///
/// **Eligibility.** A folder may pin only when its depth is at least 1 (the
/// root never pins), it is expanded, and `bottom > top + rowHeight` — it has
/// at least one descendant row.
///
/// **Cap.** At most `maximumRows(viewportHeight:rowHeight:)` rows pin — a
/// third of the viewport (`capFraction`) in whole rows, `0` for a non-positive
/// row or viewport height. With `0`, nothing pins.
///
/// **The chain.** Level `i` has the nominal slot `S_i = viewport.top + i·rowHeight`.
/// The next member is the first eligible folder, in rule order, that lies inside
/// the previous member's subtree (deeper, `top ≥ previous.top + rowHeight` and
/// `bottom ≤ previous.bottom`; any eligible folder for the first) and satisfies
/// `top < S_i < bottom`. Spans containing one point nest, so the first match is
/// the outermost one and the members form an ancestor chain. Once the chain
/// holds `maximumRows`, a further candidate must satisfy
/// `top ≤ S_(maximumRows−1) < bottom` — `≤`, not `<`: at equality its real row
/// lies exactly under the last copy, and leaving it out would hide that folder
/// altogether; if it does, the **outermost** member is dropped and the
/// candidate appended, repeatedly. So a capped row joins once its real row is
/// fully under the stack — or no more than `slotTolerance` short of it — and a
/// copy is never drawn while more than that sliver of its real row shows below
/// the stack. The click anchor aims a capped folder's row at that equality and
/// the scroll settles it within the tolerance of it, so the folder above it is
/// pinned, not covered.
///
/// **Drawing.** Final index `j` is drawn at `min(S_j, folder.bottom − rowHeight)`,
/// reported relative to the viewport top — negative, or above the nominal slot,
/// while the row is being pushed out by the end of its subtree. The stack's
/// height is the largest drawn bottom, clamped to `≥ 0`, and `0` when empty.
/// Rows come outermost first, and are drawn outermost on top: a deeper row
/// whose subtree ends slides up under its parent.
///
/// **Scroll anchors.** `scrollAnchorY(forRowAt:folders:viewportHeight:rowHeight:)`
/// is the one answer to "where must this row land so the stack does not cover
/// it": the `UnitPoint.y` (`anchorY`) that puts its top as many rows below the
/// viewport top as it has eligible ancestors, capped at `maximumRows` — the
/// rows that will pin once it sits under them. The pinned-row click reads it
/// off each `Stack.Row` and the draft placement asks it directly; neither uses
/// a row's index in the current stack, which is wrong once the cap has dropped
/// outer rows. Reveal keeps the centre (`revealAnchorY`), which always clears
/// the largest stack the cap allows.
///
/// **Tolerance.** The edges are measured, not counted, and drift in the last
/// bit at a fractional scale. Eligibility, containment and the ancestor count
/// compare one row's edge with another's, and each allows
/// `measurementTolerance` across its boundary, so a last child whose bottom
/// measured one ulp past its parent's is still inside it. The full chain's `≤`
/// compares an edge with the scroll offset, a continuous quantity, so it
/// allows `slotTolerance`, half a point: SwiftUI's `scrollTo` rounds the click's
/// programmatic offset to the backing pixel, so at scale 1 the click can settle
/// half a point short of the equality, and a narrower margin would leave the
/// clicked folder's parent out and its row covered. The tolerance is sized to
/// that rounding, not to the drift; its cost is that a candidate joins — and
/// the outermost row drops — up to half a point early, while at most a
/// half-point sliver of its real row shows under its copy. The free slots' `<`
/// stays strict: a drift there pins a copy exactly over its own row, which
/// draws the same pixels.
///
/// Pure and Foundation-only. The stack is one sort and one forward pass; a
/// non-empty one adds two more sorts for the ancestor count, then two binary
/// searches per pinned row — `O(n log n)` for `n` folders.
public enum TreeStickyRule {
    /// The share of the viewport's height the stack may fill, in whole rows.
    public static let capFraction = 1.0 / 3.0

    /// The `UnitPoint.y` a reveal scrolls its row to: the centre. A centred
    /// row's top, `(H − h) / 2`, is never above the largest stack the cap
    /// allows (`H / 3` at most) for any viewport that pins at all (`H ≥ 3h`),
    /// so a reveal always lands below the stack.
    public static let revealAnchorY = 0.5

    /// How far two measured edges may differ and still be the same edge, in
    /// points. The tree's frames are sums of scaled row heights, and at a
    /// fractional interface scale SwiftUI adds them in a different order than
    /// the rule would: a last child's bottom and its parent's can differ in the
    /// last bit (`246.40000000000003` against `246.4` at scale 1.1). Every
    /// comparison of one row's edge with another's — eligibility, containment
    /// and the ancestor count — allows this much (the full chain's last slot
    /// compares an edge with the scroll offset and allows `slotTolerance`);
    /// it is far above that drift and far below the smallest row (19.2 at the
    /// interface scale's 0.8 floor), so no two distinct rows ever blur.
    public static let measurementTolerance = 0.5

    /// How far a capped candidate's row may lie below the full chain's last
    /// slot and still count as under it, in points. Sized to the scroll's
    /// rounding, not to the measured edges' drift. The raw clip view keeps a
    /// programmatic offset as asked — at backing scale 1, `48.4`, `66.25` and
    /// `66.1` read back unchanged through `scroll(to:)` — but the click goes
    /// through `ScrollViewProxy.scrollTo`, which settled a target of `1165.5`
    /// at `1165.0` at backing scale 1: the backing pixel. Half a point is half
    /// a backing pixel at most for any scale ≥ 1, so a clicked folder settles
    /// within this of the equality, and it stays far below the smallest row
    /// (19.2 at the interface scale's 0.8 floor). The cost: a candidate joins
    /// up to half a point early, so at most a half-point sliver of its real
    /// row shows under the copy in its slot — the right trade against a
    /// covered row after a click.
    public static let slotTolerance = 0.5

    /// One folder node as the tree measured it, in content coordinates.
    public struct Folder: Equatable {
        /// `0` is the project root; a child is its parent's depth plus one.
        public var depth: Int
        public var isExpanded: Bool
        /// The node's top edge, which is also its row's top edge.
        public var top: Double
        /// The node's bottom edge: its row plus its expanded subtree.
        public var bottom: Double

        public init(depth: Int, isExpanded: Bool, top: Double, bottom: Double) {
            self.depth = depth
            self.isExpanded = isExpanded
            self.top = top
            self.bottom = bottom
        }
    }

    /// The visible part of the content: `top` is the content offset at the
    /// viewport's top edge.
    public struct Viewport: Equatable {
        public var top: Double
        public var height: Double

        public init(top: Double, height: Double) {
            self.top = top
            self.height = height
        }
    }

    /// The pinned rows, outermost first, and the stack's height.
    public struct Stack: Equatable {
        public var rows: [Row]
        /// The largest drawn bottom relative to the viewport top, `≥ 0`.
        public var height: Double

        public static let empty = Stack(rows: [], height: 0)
    }

    /// The most rows the stack may hold: `floor(viewportHeight / 3 / rowHeight)`,
    /// and `0` when `rowHeight ≤ 0` or `viewportHeight ≤ 0`.
    public static func maximumRows(viewportHeight: Double, rowHeight: Double) -> Int {
        guard rowHeight > 0, viewportHeight > 0 else { return 0 }
        // The tolerance keeps an exact multiple (66 / 3 / 22) from flooring
        // one row short through the fraction's binary rounding.
        let rows = (viewportHeight * capFraction / rowHeight + 1e-9).rounded(.down)
        return Int(rows)
    }

    /// The stack for `folders` scrolled to `viewport`.
    public static func stack(folders: [Folder], viewport: Viewport, rowHeight: Double) -> Stack {
        let cap = maximumRows(viewportHeight: viewport.height, rowHeight: rowHeight)
        guard cap > 0 else { return .empty }
        let order = folders.indices.sorted { lhs, rhs in
            let left = folders[lhs], right = folders[rhs]
            if left.top != right.top { return left.top < right.top }
            if left.depth != right.depth { return left.depth < right.depth }
            return lhs < rhs
        }

        var chain: [Int] = []
        for index in order {
            let candidate = folders[index]
            guard isEligible(candidate, rowHeight: rowHeight) else { continue }
            if let previous = chain.last,
               !lies(candidate, inside: folders[previous], rowHeight: rowHeight) {
                continue
            }
            let isFull = chain.count == cap
            let slot = viewport.top + Double(min(chain.count, cap - 1)) * rowHeight
            // A free slot takes a row that has started under it; the full
            // chain's last slot is already drawn, so a row under it — up to
            // the scroll's rounding short of it — is covered and must join.
            let hasReached = isFull ? candidate.top <= slot + slotTolerance : candidate.top < slot
            guard hasReached, slot < candidate.bottom else { continue }
            if isFull { chain.removeFirst() }
            chain.append(index)
        }

        guard !chain.isEmpty else { return .empty }
        var height = 0.0
        let ancestors = AncestorCounter(folders: folders, rowHeight: rowHeight)
        let rows = chain.enumerated().map { level, index in
            let nominal = Double(level) * rowHeight
            let folder = folders[index]
            let top = min(nominal, folder.bottom - rowHeight - viewport.top)
            height = max(height, top + rowHeight)
            let anchor = anchorY(
                rowsAbove: min(ancestors.count(forRowAt: folder.top), cap),
                rowHeight: rowHeight,
                viewportHeight: viewport.height
            )
            return Stack.Row(index: index, top: top, pushOffset: top - nominal, scrollAnchorY: anchor)
        }
        return Stack(rows: rows, height: height)
    }

    /// The `UnitPoint.y` that lands a row of height `rowHeight` with its top
    /// `rowsAbove` rows below the viewport top: `scrollTo` aligns the same unit
    /// point of the row and of the viewport, so the top lands at `y·(H − h)`,
    /// and `y = k·h / (H − h)`. Clamped to `0…1`, and `0` when `H ≤ h`.
    public static func anchorY(rowsAbove: Int, rowHeight: Double, viewportHeight: Double) -> Double {
        let travel = viewportHeight - rowHeight
        guard travel > 0 else { return 0 }
        return min(max(Double(rowsAbove) * rowHeight / travel, 0), 1)
    }

    /// How many eligible folders contain the row whose top is `rowTop`
    /// (`top < rowTop < bottom`): the rows that will qualify for the stack once
    /// that row sits under it, each then having its real row above the
    /// viewport and its subtree continuing below. A folder's own row is not
    /// inside its span, so a folder never counts itself.
    public static func eligibleAncestorCount(forRowAt rowTop: Double, folders: [Folder], rowHeight: Double) -> Int {
        AncestorCounter(folders: folders, rowHeight: rowHeight).count(forRowAt: rowTop)
    }

    /// `eligibleAncestorCount` for many rows over one set of folders, each
    /// answer two binary searches. An eligible folder ending at or above the
    /// row (`bottom − tolerance ≤ rowTop`) also starts above it, its span
    /// being taller than its row and its row taller than the tolerance, so the
    /// folders containing the row are those starting above it minus those
    /// ending at or above it — no nesting assumed.
    private struct AncestorCounter {
        /// Each eligible folder's `top + measurementTolerance`, ascending.
        private let starts: [Double]
        /// Each eligible folder's `bottom − measurementTolerance`, ascending.
        private let ends: [Double]

        init(folders: [Folder], rowHeight: Double) {
            let eligible = folders.filter { TreeStickyRule.isEligible($0, rowHeight: rowHeight) }
            starts = eligible.map { $0.top + TreeStickyRule.measurementTolerance }.sorted()
            ends = eligible.map { $0.bottom - TreeStickyRule.measurementTolerance }.sorted()
        }

        /// The folders with `top + tolerance < rowTop < bottom − tolerance`.
        func count(forRowAt rowTop: Double) -> Int {
            Self.prefix(of: starts) { $0 < rowTop } - Self.prefix(of: ends) { $0 <= rowTop }
        }

        /// The length of `sorted`'s prefix satisfying `belongs`, which holds
        /// for a prefix and fails for the rest.
        private static func prefix(of sorted: [Double], where belongs: (Double) -> Bool) -> Int {
            var low = 0, high = sorted.count
            while low < high {
                let middle = (low + high) / 2
                if belongs(sorted[middle]) { low = middle + 1 } else { high = middle }
            }
            return low
        }
    }

    /// The one below-the-stack anchor: `anchorY` for the row's eligible
    /// ancestors, capped at `maximumRows`. Both the pinned-row click (through
    /// `Stack.Row.scrollAnchorY`) and the draft placement ask it, and neither
    /// reads the index in the current stack: with the cap dropping outer rows,
    /// the innermost copy sits at index `maximumRows − 1`, yet once its real
    /// row is scrolled under the stack its dropped ancestors pin again and
    /// fill every slot above it.
    public static func scrollAnchorY(
        forRowAt rowTop: Double, folders: [Folder], viewportHeight: Double, rowHeight: Double
    ) -> Double {
        let ancestors = eligibleAncestorCount(forRowAt: rowTop, folders: folders, rowHeight: rowHeight)
        let cap = maximumRows(viewportHeight: viewportHeight, rowHeight: rowHeight)
        return anchorY(rowsAbove: min(ancestors, cap), rowHeight: rowHeight, viewportHeight: viewportHeight)
    }

    /// Where a newly shown row — the create draft — must be scrolled to: `nil`
    /// when `[rowTop, rowTop + rowHeight)` already lies inside the uncovered
    /// part of the viewport, `[viewport.top + stack.height, viewport.top + H)`,
    /// so nothing scrolls; otherwise `scrollAnchorY(forRowAt:…)`, the anchor
    /// the pinned-row click uses.
    public static func placement(
        ofRowAt rowTop: Double, folders: [Folder], viewport: Viewport, rowHeight: Double
    ) -> Double? {
        let covered = stack(folders: folders, viewport: viewport, rowHeight: rowHeight).height
        let clear = rowTop >= viewport.top + covered && rowTop + rowHeight <= viewport.top + viewport.height
        if clear { return nil }
        return scrollAnchorY(
            forRowAt: rowTop, folders: folders, viewportHeight: viewport.height, rowHeight: rowHeight
        )
    }

    /// Expanded, below the root, with at least one descendant row.
    private static func isEligible(_ folder: Folder, rowHeight: Double) -> Bool {
        folder.depth >= 1 && folder.isExpanded && folder.bottom > folder.top + rowHeight + measurementTolerance
    }

    /// Whether `folder` lies inside `ancestor`'s subtree (below its row).
    private static func lies(_ folder: Folder, inside ancestor: Folder, rowHeight: Double) -> Bool {
        folder.depth > ancestor.depth
            && folder.top >= ancestor.top + rowHeight - measurementTolerance
            && folder.bottom <= ancestor.bottom + measurementTolerance
    }
}

extension TreeStickyRule.Stack {
    /// One pinned copy. Declared here rather than inside `Stack` so the type
    /// sits at the nesting depth the style rule allows.
    public struct Row: Equatable {
        /// The folder's index in the rule's input.
        public var index: Int
        /// Where the copy is drawn, relative to the viewport top.
        public var top: Double
        /// How far the copy is pushed up from its nominal slot (`≤ 0`).
        public var pushOffset: Double
        /// The `UnitPoint.y` a click on the copy scrolls its folder's real row
        /// to, so it lands just under the stack: `scrollAnchorY(forRowAt:)`
        /// for the folder's top, never its index here.
        public var scrollAnchorY: Double
    }
}
