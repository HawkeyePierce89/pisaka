import Foundation

/// One row of the commit graph: where the commit's node sits and the line
/// segments leaving the *bottom* of the row toward the next row.
///
/// A row is the visual cell for a single commit. `column` is the lane (0-based
/// column) the node is drawn in and `colorIndex` is that lane's stable color
/// index (the view layer maps it to a concrete color, so Core stays color-free,
/// like `FileIconColor`/`SyntaxTokenKind`). `edges` are the segments in the gap
/// *below* this row — each runs from a column at this row's vertical center down
/// to a column at the next row's vertical center. The last row has no outgoing
/// edges (its lanes simply end, or run off the bottom when history is truncated).
///
/// A row's *incoming* segments are just the previous row's `edges` (the view
/// pairs a row with the one above it to draw a continuous line), so the layout
/// only needs to express outgoing edges.
public struct CommitGraphRow: Equatable {
    /// The lane (column) the commit's node is drawn in.
    public let column: Int
    /// The stable color index of the node's lane.
    public let colorIndex: Int
    /// Segments leaving the bottom of this row toward the next row.
    public let edges: [GraphEdge]

    public init(column: Int, colorIndex: Int, edges: [GraphEdge]) {
        self.column = column
        self.colorIndex = colorIndex
        self.edges = edges
    }
}

/// A single line segment in the gap below a row: from `fromColumn` at the row's
/// center down to `toColumn` at the next row's center, drawn in `colorIndex`'s
/// color. `fromColumn == toColumn` is a straight vertical (a lane continuing or
/// passing through); a difference is a diagonal (a branch opening from a merge,
/// or a branch merging back into an existing lane).
public struct GraphEdge: Equatable {
    public let fromColumn: Int
    public let toColumn: Int
    public let colorIndex: Int

    public init(fromColumn: Int, toColumn: Int, colorIndex: Int) {
        self.fromColumn = fromColumn
        self.toColumn = toColumn
        self.colorIndex = colorIndex
    }
}

/// The full laid-out graph for a list of commits.
public struct CommitGraph: Equatable {
    /// One row per input commit, in the same order.
    public let rows: [CommitGraphRow]
    /// The number of lanes (columns) the widest row uses — what the view reserves
    /// for the graph gutter. 0 for an empty graph.
    public let width: Int

    public init(rows: [CommitGraphRow], width: Int) {
        self.rows = rows
        self.width = width
    }

    public static let empty = CommitGraph(rows: [], width: 0)
}

/// Pure, Foundation-only branch-graph layout — the off-by-one-prone lane/edge
/// bookkeeping that backs the Log view's graph gutter, unit-tested in Core while
/// the `NSView` that draws it stays a thin, color-resolving view layer (like the
/// minimap: color-free geometry here, palette at draw time).
///
/// ## Algorithm
///
/// The commits are expected in git's topological order — a commit appears
/// *before* (above) its parents, i.e. newest first. The layout walks rows
/// top-to-bottom maintaining a set of *active lanes*: each lane "seeks" a commit
/// hash it expects to reach further down (because some already-placed commit
/// named it as a parent). A lane is the vertical line of a branch.
///
/// For each commit:
/// - Its node sits in the lane already seeking its hash; if none seeks it (a
///   branch tip / disconnected head), a fresh lane and color are allocated.
/// - The lane is then vacated and the commit's parents are routed out of the
///   node: the first parent continues the node's lane (keeping its color) unless
///   another lane already seeks it (then it merges in); each additional parent
///   reuses an existing seeking lane or opens a new one with a fresh color.
/// - Lanes seeking other hashes pass straight through (a vertical edge in the
///   same column, keeping their color — so a branch's color is stable across the
///   rows it spans).
///
/// Because a parent is always merged into an existing seeking lane when one is
/// present, at most one lane ever seeks a given hash, so two children of a commit
/// share a single converging lane rather than two lanes that have to merge at the
/// node. Freed lane slots are reused (first nil slot) so the graph stays narrow.
public enum CommitGraphLayout {
    /// Lay out the branch graph for topologically ordered `commits`.
    public static func layout(_ commits: [Commit]) -> CommitGraph {
        guard !commits.isEmpty else { return .empty }

        // The hash each active lane currently seeks (nil = free slot), and that
        // lane's stable color index.
        var laneHash: [String?] = []
        var laneColor: [Int?] = []
        var nextColor = 0

        // First free slot, appending a new lane if none is free.
        func allocateLane(seeking hash: String, color: Int) -> Int {
            if let free = laneHash.firstIndex(where: { $0 == nil }) {
                laneHash[free] = hash
                laneColor[free] = color
                return free
            }
            laneHash.append(hash)
            laneColor.append(color)
            return laneHash.count - 1
        }

        var rows: [CommitGraphRow] = []
        rows.reserveCapacity(commits.count)

        for commit in commits {
            let hash = commit.hash

            // Place the node: the lane already seeking this commit, or a fresh one.
            let nodeColumn: Int
            if let existing = laneHash.firstIndex(where: { $0 == hash }) {
                nodeColumn = existing
            } else {
                let color = nextColor
                nextColor += 1
                nodeColumn = allocateLane(seeking: hash, color: color)
            }
            let nodeColor = laneColor[nodeColumn]!

            // Any *other* lane that also seeks this hash converges here; close it.
            // (With merge-into-existing routing below this is normally empty, but
            // closing keeps the invariant that one hash is sought by one lane.)
            for index in laneHash.indices where index != nodeColumn && laneHash[index] == hash {
                laneHash[index] = nil
                laneColor[index] = nil
            }

            // Vacate the node's lane so the first parent can reclaim its column.
            laneHash[nodeColumn] = nil
            laneColor[nodeColumn] = nil

            var edges: [GraphEdge] = []
            // Lane indices that received a parent edge this row (so they are not
            // also drawn as pass-throughs below).
            var routed: Set<Int> = []

            for (index, parent) in commit.parents.enumerated() {
                if let existing = laneHash.firstIndex(where: { $0 == parent }) {
                    // Another lane already heads to this parent: merge into it.
                    edges.append(GraphEdge(
                        fromColumn: nodeColumn,
                        toColumn: existing,
                        colorIndex: laneColor[existing]!
                    ))
                    routed.insert(existing)
                } else if index == 0 {
                    // First parent continues the node's lane, keeping its color.
                    laneHash[nodeColumn] = parent
                    laneColor[nodeColumn] = nodeColor
                    edges.append(GraphEdge(
                        fromColumn: nodeColumn,
                        toColumn: nodeColumn,
                        colorIndex: nodeColor
                    ))
                    routed.insert(nodeColumn)
                } else {
                    // An additional parent opens a new branch lane with a new color.
                    let color = nextColor
                    nextColor += 1
                    let lane = allocateLane(seeking: parent, color: color)
                    edges.append(GraphEdge(
                        fromColumn: nodeColumn,
                        toColumn: lane,
                        colorIndex: color
                    ))
                    routed.insert(lane)
                }
            }

            // Every still-active lane not touched above passes straight through.
            for index in laneHash.indices where !routed.contains(index) {
                guard laneHash[index] != nil else { continue }
                edges.append(GraphEdge(
                    fromColumn: index,
                    toColumn: index,
                    colorIndex: laneColor[index]!
                ))
            }

            rows.append(CommitGraphRow(column: nodeColumn, colorIndex: nodeColor, edges: edges))
        }

        // Width = the highest column index touched by any node or edge, + 1.
        var width = 0
        for row in rows {
            width = max(width, row.column + 1)
            for edge in row.edges {
                width = max(width, edge.fromColumn + 1, edge.toColumn + 1)
            }
        }

        return CommitGraph(rows: rows, width: width)
    }
}
