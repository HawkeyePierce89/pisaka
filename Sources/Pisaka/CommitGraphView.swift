#if os(macOS)
import AppKit
import SwiftUI
import PisakaCore

/// The branch-graph gutter for a single commit row, drawn as a thin AppKit view
/// beside the row's text columns in `CommitLogView`.
///
/// The pure lane/edge layout lives in `PisakaCore.CommitGraphLayout` (color-free,
/// unit-tested); this view is the thin, color-resolving counterpart — like the
/// minimap, it consumes a color *index* and maps it to a concrete `NSColor` from
/// a fixed palette at draw time so it follows the system appearance.
///
/// Each cell draws exactly one row of the graph in a fixed `rowHeight`. The node
/// sits at the vertical center; the row's own `edges` (the segments leaving the
/// *bottom*, from `CommitGraphRow.edges`) are drawn from center to the bottom
/// edge, and the previous row's edges — passed in as `incomingEdges` — are drawn
/// as their continuation from the top edge to center. Because consecutive cells
/// share a boundary, a lane's bottom-half in one cell and top-half in the next
/// meet to form a continuous line without the view ever owning the whole list.
struct CommitGraphView: NSViewRepresentable {
    /// This row's node + outgoing edges.
    let row: CommitGraphRow
    /// The previous row's outgoing edges (this row's incoming continuations);
    /// empty for the first row.
    let incomingEdges: [GraphEdge]
    /// The graph's total lane count, so every cell uses the same column spacing.
    let laneCount: Int
    /// The fixed row height the commit list uses, so the graph aligns with text.
    let rowHeight: CGFloat

    func makeNSView(context: Context) -> CommitGraphRowNSView {
        let view = CommitGraphRowNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: CommitGraphRowNSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: CommitGraphRowNSView) {
        view.row = row
        view.incomingEdges = incomingEdges
        view.laneCount = laneCount
        view.rowHeight = rowHeight
        view.needsDisplay = true
    }
}

/// The `NSView` that paints one graph row. Flipped so y grows downward, matching
/// the top-down row order of the commit list.
final class CommitGraphRowNSView: NSView {
    var row: CommitGraphRow = CommitGraphRow(column: 0, colorIndex: 0, edges: []) {
        didSet { needsDisplay = true }
    }
    var incomingEdges: [GraphEdge] = [] {
        didSet { needsDisplay = true }
    }
    var laneCount: Int = 1 {
        didSet { needsDisplay = true }
    }
    var rowHeight: CGFloat = 24 {
        didSet { needsDisplay = true }
    }

    /// Horizontal spacing between lanes, in points.
    private let laneSpacing: CGFloat = 14
    /// Radius of the commit node dot.
    private let nodeRadius: CGFloat = 3.5
    /// Stroke width of the edge lines.
    private let lineWidth: CGFloat = 1.5

    override var isFlipped: Bool { true }

    /// The x center of a lane column.
    private func columnX(_ column: Int) -> CGFloat {
        laneSpacing / 2 + CGFloat(column) * laneSpacing
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let height = bounds.height
        let midY = height / 2

        context.setLineWidth(lineWidth)
        context.setLineCap(.round)

        // Top half: the previous row's outgoing edges continue from the top edge
        // down to this row's center. The diagonal slope (if any) was already drawn
        // in the previous cell's bottom half, which lands at `toColumn`'s x on the
        // shared boundary, so here the lane simply runs straight down that column.
        for edge in incomingEdges {
            let x = columnX(edge.toColumn)
            strokeLine(context, color: color(for: edge.colorIndex),
                       from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: midY))
        }

        // Bottom half: this row's outgoing edges leave the center for the bottom
        // edge at their destination column.
        for edge in row.edges {
            strokeLine(context, color: color(for: edge.colorIndex),
                       from: CGPoint(x: columnX(edge.fromColumn), y: midY),
                       to: CGPoint(x: columnX(edge.toColumn), y: height))
        }

        // The commit node dot, on top of the lines, in its lane's color.
        let center = CGPoint(x: columnX(row.column), y: midY)
        let dot = CGRect(
            x: center.x - nodeRadius, y: center.y - nodeRadius,
            width: nodeRadius * 2, height: nodeRadius * 2
        )
        context.setFillColor(color(for: row.colorIndex).cgColor)
        context.fillEllipse(in: dot)
    }

    private func strokeLine(_ context: CGContext, color: NSColor, from: CGPoint, to: CGPoint) {
        context.setStrokeColor(color.cgColor)
        context.move(to: from)
        context.addLine(to: to)
        context.strokePath()
    }

    /// Resolve a stable color index to a concrete color from a fixed palette,
    /// cycling if there are more lanes than palette entries. Resolved at draw time
    /// so the graph follows light/dark appearance.
    private func color(for index: Int) -> NSColor {
        Self.palette[((index % Self.palette.count) + Self.palette.count) % Self.palette.count]
    }

    /// A small, visually distinct lane palette (the view layer owns color; Core
    /// stays color-free).
    private static let palette: [NSColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple,
        .systemRed, .systemTeal, .systemPink, .systemYellow,
    ]
}

#endif
