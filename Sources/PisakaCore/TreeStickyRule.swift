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
/// the rule orders folders by `top` ascending, then `depth` ascending.
///
/// **Eligibility.** A folder may pin only when its depth is at least 1 (the
/// root never pins), it is expanded, and `bottom > top + rowHeight` — it has
/// at least one descendant row.
///
/// **Cap.** At most `maximumRows(viewportHeight:rowHeight:)` rows pin — a
/// third of the viewport (`capFraction`) in whole rows, `0` for a non-positive
/// row height. With `0`, nothing pins.
///
/// **The chain.** Level `i` has the nominal slot `S_i = viewport.top + i·rowHeight`.
/// The next member is the first eligible folder, in rule order, that lies inside
/// the previous member's subtree (deeper, `top ≥ previous.top + rowHeight` and
/// `bottom ≤ previous.bottom`; any eligible folder for the first) and satisfies
/// `top < S_i < bottom`. Spans containing one point nest, so the first match is
/// the outermost one and the members form an ancestor chain. Once the chain
/// holds `maximumRows`, a further candidate must satisfy
/// `top < S_(maximumRows−1) < bottom`; if it does, the **outermost** member is
/// dropped and the candidate appended, repeatedly. So a capped row joins only
/// once its real row is fully under the stack, and a copy is never drawn while
/// its real row shows below the stack.
///
/// **Drawing.** Final index `j` is drawn at `min(S_j, folder.bottom − rowHeight)`,
/// reported relative to the viewport top — negative, or above the nominal slot,
/// while the row is being pushed out by the end of its subtree. The stack's
/// height is the largest drawn bottom, clamped to `≥ 0`, and `0` when empty.
/// Rows come outermost first, and are drawn outermost on top: a deeper row
/// whose subtree ends slides up under its parent.
///
/// Pure and Foundation-only; one sort plus one forward pass.
public enum TreeStickyRule {
    /// The share of the viewport's height the stack may fill, in whole rows.
    public static let capFraction = 1.0 / 3.0

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
    /// and `0` when `rowHeight ≤ 0`.
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
            let slot = viewport.top + Double(min(chain.count, cap - 1)) * rowHeight
            guard candidate.top < slot, slot < candidate.bottom else { continue }
            if chain.count == cap { chain.removeFirst() }
            chain.append(index)
        }

        var height = 0.0
        let rows = chain.enumerated().map { level, index in
            let nominal = Double(level) * rowHeight
            let top = min(nominal, folders[index].bottom - rowHeight - viewport.top)
            height = max(height, top + rowHeight)
            return Stack.Row(index: index, top: top, pushOffset: top - nominal)
        }
        return Stack(rows: rows, height: height)
    }

    /// Expanded, below the root, with at least one descendant row.
    private static func isEligible(_ folder: Folder, rowHeight: Double) -> Bool {
        folder.depth >= 1 && folder.isExpanded && folder.bottom > folder.top + rowHeight
    }

    /// Whether `folder` lies inside `ancestor`'s subtree (below its row).
    private static func lies(_ folder: Folder, inside ancestor: Folder, rowHeight: Double) -> Bool {
        folder.depth > ancestor.depth
            && folder.top >= ancestor.top + rowHeight
            && folder.bottom <= ancestor.bottom
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
    }
}
