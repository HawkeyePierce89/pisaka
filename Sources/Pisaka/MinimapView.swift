#if os(macOS)
import AppKit
import PisakaCore

/// A VS Code-style minimap: a syntax-colored, fixed-row-height overview of the
/// file (sliding when it overflows the panel) with a draggable viewport
/// rectangle on top.
///
/// The view is *flipped* (`isFlipped == true`) so its y axis grows downward and
/// matches `MinimapGeometry`'s top-down convention exactly — a minimap y in the
/// view is a minimap y in the geometry, no conversion needed. The owning view
/// (`CodeEditorView`) handles the editor's flipped clip-view coordinates at the
/// boundary; here everything is already top-down.
///
/// Rendering is intentionally thin and *proportional* (VS Code-style): each
/// document line gets a fixed minimap row height (`minimapLineHeight`, ~3px)
/// rather than being stretched to fit. The full content (`lineCount *
/// minimapLineHeight`) may exceed the panel, so the whole drawing slides upward
/// by `minimapScrollTop` and rows outside the visible slice are culled. Per line
/// it draws small colored rectangles (~1pt/char) for each non-whitespace run.
/// Colors are resolved through `SyntaxTheme` at *draw time*, so the minimap
/// follows the system appearance like the editor.
///
/// It declares itself a **code** zoom surface. The minimap is a *sibling* of the
/// editor's scroll view inside `EditorContainerView`, so the pointer walk cannot
/// reach it through the text view; without the conformance a gesture over the
/// strip would find no candidate and resize the application chrome, even though
/// what it is over is a rendering of the code at the code zone's size.
@MainActor
final class MinimapView: NSView, ZoomSurfaceProviding {
    let zoomSurfaceKind: ZoomSurfaceKind = .code

    /// The line-indexed colored overview to draw. Replacing it redraws.
    var model: MinimapModel = .empty {
        didSet { if model != oldValue { needsDisplay = true } }
    }

    /// The scroll/viewport math, built from the current document/viewport/minimap
    /// heights by the owner. Replacing it redraws.
    var geometry: MinimapGeometry = MinimapGeometry(documentHeight: 0, viewportHeight: 0, minimapHeight: 0, contentHeight: 0) {
        didSet { if geometry != oldValue { needsDisplay = true } }
    }

    /// Document-space scroll offset (top of the visible viewport). Drives the
    /// position of the viewport rectangle. Replacing it redraws.
    var scrollOffset: CGFloat = 0 {
        didSet { if scrollOffset != oldValue { needsDisplay = true } }
    }

    /// Fixed minimap row height per document line, in points (~3px). Constant and
    /// independent of file length — the content slides instead of scaling.
    var minimapLineHeight: CGFloat = 0 {
        didSet { if minimapLineHeight != oldValue { needsDisplay = true } }
    }

    /// Reports the cursor's panel y (the desired viewport *center*) when the user
    /// clicks or drags on the minimap. The owner maps it to a document scroll
    /// offset through the geometry (which solves directly for the offset whose
    /// rectangle is centered there) and scrolls the editor; the viewport rectangle
    /// then follows via the editor's bounds-changed notification (closed loop).
    var onScroll: ((CGFloat) -> Void)?

    /// Reports a new document scroll offset when the user spins the mouse wheel
    /// over the minimap. Unlike `onScroll` (which reports a cursor *center* for
    /// click/drag), the wheel is a *relative* gesture: the view maps the event's
    /// panel-space delta through the geometry to an absolute offset and the owner
    /// scrolls the editor there (the viewport rectangle then follows via the
    /// editor's bounds-changed notification, the same closed loop).
    var onScrollToOffset: ((CGFloat) -> Void)?

    /// Minimap width per source character, in points. A coarse VS Code-like
    /// density; runs are clipped to the view width so long lines don't overflow.
    private let charWidth: CGFloat = 1

    /// The shared built-in theme; colors are appearance-aware and re-resolved at
    /// each `draw(_:)` (AppKit sets the view's effective appearance as current
    /// during drawing, so dynamic `NSColor`s pick the right light/dark variant).
    private let theme = SyntaxTheme.shared

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    /// Top-down coordinates so the view's y matches `MinimapGeometry`'s.
    override var isFlipped: Bool { true }

    /// Let a click start a drag even when the window isn't key, so the minimap
    /// behaves like a scrollbar.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Height changes the visible slice and the slide; the owner rebuilds
        // `geometry` on resize, but redraw regardless so a width-only change
        // repaints too.
        needsDisplay = true
    }

    /// Re-resolve theme colors for the new appearance by redrawing.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Subtle background so the overview reads as a distinct gutter.
        NSColor.textBackgroundColor.withAlphaComponent(0.5).setFill()
        context.fill(bounds)

        drawTokens(in: context)
        drawViewportRectangle(in: context)
    }

    /// Draw each document line's non-whitespace runs as thin colored bars at a
    /// fixed row height, slid up by the content slide and culled to the visible
    /// slice of the panel.
    private func drawTokens(in context: CGContext) {
        let lineCount = model.lineCount
        let rowHeight = minimapLineHeight
        guard lineCount > 0, rowHeight > 0 else { return }

        // How far the content has slid upward — derived from `geometry` and the
        // current `scrollOffset` (the same source the viewport rectangle uses),
        // so the bars and the rectangle can never disagree.
        let minimapScrollTop = geometry.minimapScrollTop(forScrollOffset: scrollOffset)

        // A 1pt gap between rows once they're tall enough to spare it.
        let gap: CGFloat = rowHeight > 2 ? 1 : 0
        let barHeight = max(rowHeight - gap, 1)
        let viewWidth = bounds.width
        let viewHeight = bounds.height

        // Iterate only the visible slice. Deriving the first/last visible line up
        // front (rather than `continue`-ing from line 0) keeps a redraw near the
        // bottom of a huge file O(visible rows), not O(lineCount). The bars start
        // at `y = line*rowHeight - minimapScrollTop + gap/2`; bound where
        // `y + barHeight >= 0` and `y <= viewHeight`, widened by one row each way
        // for safety. The per-row guards below remain as a backstop.
        let firstVisible = max(0, Int(((minimapScrollTop - barHeight) / rowHeight).rounded(.down)))
        let lastVisible = min(lineCount - 1, Int(((minimapScrollTop + viewHeight) / rowHeight).rounded(.up)))
        guard firstVisible <= lastVisible else { return }

        for line in firstVisible...lastVisible {
            let y = CGFloat(line) * rowHeight - minimapScrollTop + gap / 2
            // Cull rows above the visible slice; stop once past the bottom.
            if y + barHeight < 0 { continue }
            if y > viewHeight { break }

            let runs = model.runs[line]
            if runs.isEmpty { continue }
            for run in runs {
                let x = CGFloat(run.column) * charWidth
                if x >= viewWidth { continue }
                let width = min(CGFloat(run.length) * charWidth, viewWidth - x)
                if width <= 0 { continue }
                let color = theme.nsColor(for: run.kind)
                // Slightly translucent so overlapping/adjacent bars and the
                // viewport rectangle stay legible.
                color.withAlphaComponent(0.6).setFill()
                context.fill(NSRect(x: x, y: y, width: width, height: barHeight))
            }
        }
    }

    /// Draw the translucent, bordered viewport rectangle over the overview.
    private func drawViewportRectangle(in context: CGContext) {
        guard bounds.width > 0, geometry.minimapHeight > 0 else { return }

        let (y, height) = geometry.viewportRect(forScrollOffset: scrollOffset)
        guard height > 0 else { return }

        let rect = NSRect(x: 0, y: y, width: bounds.width, height: height)
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        context.fill(rect)
        NSColor.labelColor.withAlphaComponent(0.30).setStroke()
        let border = rect.insetBy(dx: 0.5, dy: 0.5)
        context.stroke(border, width: 1)
    }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        scroll(to: event)
    }

    override func mouseDragged(with event: NSEvent) {
        scroll(to: event)
    }

    /// Report the cursor's panel y (the desired viewport *center*); the owner maps
    /// it to a scroll offset through the geometry. Serves click-to-jump and drag.
    private func scroll(to event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onScroll?(point.y)
    }

    /// Map the wheel's vertical delta (panel points) to a new document offset and
    /// report it. `scrollingDeltaY` is positive when scrolling *up* (toward the
    /// top); the minimap is top-down (offset 0 = top), so a wheel-up should
    /// *decrease* the offset — hence the negation. The geometry divides the panel
    /// delta by `documentToMinimap` to reach document space and clamps the result.
    ///
    /// For a precise device (trackpad / Magic Mouse) `scrollingDeltaY` is already
    /// in points; for a traditional mouse wheel it is a *line* count (~1 per
    /// notch), so it is scaled by `minimapLineHeight` — the panel height of one
    /// document row — making a single notch advance the document by one line
    /// (`minimapLineHeight / documentToMinimap == one document line height`).
    override func scrollWheel(with event: NSEvent) {
        let rawDelta = event.scrollingDeltaY
        guard rawDelta != 0 else { return }
        let delta = event.hasPreciseScrollingDeltas ? rawDelta : rawDelta * minimapLineHeight
        let offset = geometry.scrollOffset(byMinimapDelta: -delta, from: scrollOffset)
        onScrollToOffset?(offset)
    }
}

#endif
