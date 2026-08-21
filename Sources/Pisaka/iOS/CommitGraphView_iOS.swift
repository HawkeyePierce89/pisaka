#if os(iOS)
import SwiftUI
import UIKit
import PisakaCore

/// The branch-graph gutter for a single commit row — the UIKit peer of the macOS
/// `CommitGraphView`. The pure lane/edge layout lives in
/// `PisakaCore.CommitGraphLayout` (color-free, unit-tested); this view is the thin,
/// color-resolving counterpart, mapping a stable color *index* to a concrete
/// `UIColor` from a fixed palette at draw time so it follows the system appearance.
///
/// Each cell draws exactly one row of the graph in a fixed `rowHeight`. The node
/// sits at the vertical center; the row's own `edges` (leaving the *bottom*) are
/// drawn from center to the bottom edge, and the previous row's edges
/// (`incomingEdges`) are drawn as their continuation from the top edge to center.
/// Consecutive cells share a boundary, so a lane's bottom-half in one cell and
/// top-half in the next meet to form a continuous line. A plain `UIView` already
/// uses a top-left, y-down coordinate system (matching the macOS *flipped* view),
/// so the drawing math is identical to the AppKit counterpart.
struct CommitGraphView_iOS: UIViewRepresentable {
    /// This row's node + outgoing edges.
    let row: CommitGraphRow
    /// The previous row's outgoing edges (this row's incoming continuations);
    /// empty for the first row.
    let incomingEdges: [GraphEdge]
    /// The graph's total lane count, so every cell uses the same column spacing.
    let laneCount: Int
    /// The fixed row height the commit list uses, so the graph aligns with text.
    let rowHeight: CGFloat

    func makeUIView(context: Context) -> CommitGraphRowUIView {
        let view = CommitGraphRowUIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: CommitGraphRowUIView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: CommitGraphRowUIView) {
        view.row = row
        view.incomingEdges = incomingEdges
        view.laneCount = laneCount
        view.rowHeight = rowHeight
        view.setNeedsDisplay()
    }
}

/// The `UIView` that paints one graph row.
final class CommitGraphRowUIView: UIView {
    var row: CommitGraphRow = CommitGraphRow(column: 0, colorIndex: 0, edges: []) {
        didSet { setNeedsDisplay() }
    }
    var incomingEdges: [GraphEdge] = [] {
        didSet { setNeedsDisplay() }
    }
    var laneCount: Int = 1 {
        didSet { setNeedsDisplay() }
    }
    var rowHeight: CGFloat = 24 {
        didSet { setNeedsDisplay() }
    }

    /// Horizontal spacing between lanes, in points.
    private let laneSpacing: CGFloat = 14
    /// Radius of the commit node dot.
    private let nodeRadius: CGFloat = 3.5
    /// Stroke width of the edge lines.
    private let lineWidth: CGFloat = 1.5

    /// The x center of a lane column.
    private func columnX(_ column: Int) -> CGFloat {
        laneSpacing / 2 + CGFloat(column) * laneSpacing
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let height = bounds.height
        let midY = height / 2

        context.setLineWidth(lineWidth)
        context.setLineCap(.round)

        // Top half: the previous row's outgoing edges continue from the top edge
        // down to this row's center, landing at `toColumn` (the diagonal slope was
        // already drawn in the previous cell's bottom half).
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

    private func strokeLine(_ context: CGContext, color: UIColor, from: CGPoint, to: CGPoint) {
        context.setStrokeColor(color.cgColor)
        context.move(to: from)
        context.addLine(to: to)
        context.strokePath()
    }

    /// Resolve a stable color index to a concrete color from a fixed palette,
    /// cycling if there are more lanes than palette entries. Resolved at draw time
    /// so the graph follows light/dark appearance.
    private func color(for index: Int) -> UIColor {
        Self.palette[((index % Self.palette.count) + Self.palette.count) % Self.palette.count]
    }

    /// A small, visually distinct lane palette (the view layer owns color; Core
    /// stays color-free) — the iOS mirror of the macOS graph palette.
    private static let palette: [UIColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemPurple,
        .systemRed, .systemTeal, .systemPink, .systemYellow
    ]
}
#endif
