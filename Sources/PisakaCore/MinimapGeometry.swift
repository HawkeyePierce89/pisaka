import CoreGraphics

/// Pure scroll/viewport math for a VS Code-style proportional minimap.
///
/// Unlike a stretch-to-fit minimap, each minimap line has a *fixed* height
/// (`minimapLineHeight`, owned by the view layer). The owner multiplies that by
/// the line count to get `contentHeight`, the full height of the minimap's
/// rendered content. When `contentHeight > minimapHeight` the content does not
/// fit the panel, so it *slides* vertically by `minimapScrollTop` — proportional
/// to the editor's scroll fraction — to keep the visible region in view. The
/// document→minimap ratio `documentToMinimap = contentHeight / documentHeight`
/// is constant and independent of file length.
///
/// UI-free (CoreGraphics/Foundation only, no AppKit/SwiftTreeSitter): the view
/// layer converts AppKit's flipped clip-view coordinates into this type's single
/// top-down convention (y grows downward; offset 0 = top of document) and back.
///
/// All heights are in points. `scrollOffset` is the document-space y of the top
/// of the visible viewport, in `[0, max(0, documentHeight - viewportHeight)]`.
/// `viewportRect` returns panel-space coordinates with the slide already applied.
public struct MinimapGeometry: Equatable {
    public let documentHeight: CGFloat
    public let viewportHeight: CGFloat
    public let minimapHeight: CGFloat
    public let contentHeight: CGFloat

    public init(
        documentHeight: CGFloat,
        viewportHeight: CGFloat,
        minimapHeight: CGFloat,
        contentHeight: CGFloat
    ) {
        self.documentHeight = documentHeight
        self.viewportHeight = viewportHeight
        self.minimapHeight = minimapHeight
        self.contentHeight = contentHeight
    }

    /// The largest valid scroll offset (top of the last viewport-worth of doc).
    public var maxScrollOffset: CGFloat {
        max(0, documentHeight - viewportHeight)
    }

    /// Minimap content-points per document-point. Constant ratio (independent of
    /// file length given a fixed per-line height). Zero when the document has no
    /// height.
    public var documentToMinimap: CGFloat {
        documentHeight > 0 ? contentHeight / documentHeight : 0
    }

    /// How far the minimap content has slid upward (in panel points) for a given
    /// editor scroll offset.
    ///
    /// Zero unless the content overflows the panel (`contentHeight > minimapHeight`)
    /// and there is something to scroll (`maxScrollOffset > 0`). Otherwise the
    /// content slides between 0 (top) and `contentHeight - minimapHeight` (bottom)
    /// proportionally to the editor's scroll fraction.
    public func minimapScrollTop(forScrollOffset offset: CGFloat) -> CGFloat {
        guard contentHeight > minimapHeight, maxScrollOffset > 0 else { return 0 }
        let clamped = min(max(offset, 0), maxScrollOffset)
        let fraction = clamped / maxScrollOffset
        return fraction * (contentHeight - minimapHeight)
    }

    /// The viewport rectangle in panel-space (y from the panel top, height), with
    /// the content slide already applied so it can be drawn directly.
    public func viewportRect(forScrollOffset offset: CGFloat) -> (y: CGFloat, height: CGFloat) {
        let clamped = min(max(offset, 0), maxScrollOffset)
        let ratio = documentToMinimap
        let y = clamped * ratio - minimapScrollTop(forScrollOffset: clamped)
        let height = viewportHeight * ratio
        return (y, height)
    }

    /// Map a panel y (the desired *center* of the viewport rectangle) to the
    /// document scroll offset whose viewport rectangle is centered there.
    ///
    /// Serves both click-to-jump and rectangle drag. It solves *directly* for the
    /// target offset rather than reading the current slide, so a single click
    /// lands the rectangle under the cursor and a drag tracks the cursor without
    /// converging over several frames. The rectangle center in panel space is
    /// `offset*ratio - minimapScrollTop(offset) + viewportHeight*ratio/2`, and the
    /// slide is linear in the offset (`slidePerOffset * offset` once it is active),
    /// so setting that equal to `centerY` gives a closed form. When the rectangle
    /// fills the whole panel (no room to position it) it falls back to a
    /// proportional map; the result is always clamped to the scrollable range.
    public func scrollOffset(forMinimapCenterY centerY: CGFloat) -> CGFloat {
        let ratio = documentToMinimap
        guard ratio > 0, maxScrollOffset > 0 else { return 0 }

        // How much the content slides per unit of scroll offset (0 when the
        // content fits the panel, matching `minimapScrollTop`).
        let slidePerOffset = contentHeight > minimapHeight
            ? (contentHeight - minimapHeight) / maxScrollOffset
            : 0

        // The rectangle center is `offset*(ratio - slidePerOffset) +
        // viewportHeight*ratio/2`; invert it for the offset.
        let denominator = ratio - slidePerOffset
        let offset: CGFloat
        if denominator > 1e-9 {
            offset = (centerY - viewportHeight * ratio / 2) / denominator
        } else if minimapHeight > 0 {
            // Degenerate: the rectangle fills the panel, so its center can't be
            // moved by positioning. Map the click proportionally instead.
            offset = (centerY / minimapHeight) * maxScrollOffset
        } else {
            offset = 0
        }
        return min(max(offset, 0), maxScrollOffset)
    }

    /// Convert a minimap-panel-space scroll delta to a new, clamped document
    /// scroll offset, starting from the current `offset`.
    ///
    /// Used by the minimap's mouse-wheel path: the wheel moves the cursor over
    /// minimap content, so the delta is expressed in panel points. Dividing by
    /// `documentToMinimap` maps it back to document points (a panel point covers
    /// `1/ratio` document points), adds it to the current offset, and clamps to
    /// the scrollable range. When the ratio is zero (degenerate/zero-height
    /// document) there is nowhere to scroll, so the offset is left clamped to
    /// `[0, maxScrollOffset]` (which is `0` for a zero-height document).
    public func scrollOffset(byMinimapDelta delta: CGFloat, from offset: CGFloat) -> CGFloat {
        let ratio = documentToMinimap
        guard ratio > 0 else { return min(max(offset, 0), maxScrollOffset) }
        let next = offset + delta / ratio
        return min(max(next, 0), maxScrollOffset)
    }
}
