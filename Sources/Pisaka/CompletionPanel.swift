#if os(macOS)
import AppKit
import PisakaCore
import SwiftUI

@MainActor
final class CompletionPanel {
    /// The width cap at the unscaled interface; internal for the layout suite.
    static let maximumWidth: CGFloat = 520
    private static let gap: CGFloat = 4

    private var panel: PassThroughPanel?
    private var listContentView: CompletionListContentView?
    private weak var attachedParent: NSWindow?
    private var isShown = false
    private var eventMonitor: Any?

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    var isVisible: Bool { isShown }
    var onCommit: ((Int) -> Void)?

    /// A click anywhere outside the panel, fired before the panel hides itself.
    /// The controller forwards this to its own `dismiss()`: the panel going away
    /// alone would leave the pending request and the offered list alive, free to
    /// re-present themselves over whatever the click landed on.
    var onOutsideClick: (() -> Void)?

    func show(
        rows: [CompletionRow],
        selection: CompletionPopupSelection?,
        anchoredTo anchor: NSRect,
        in parent: NSWindow?,
        codeFont: NSFont,
        metrics: InterfaceMetrics
    ) {
        guard !rows.isEmpty else {
            dismiss()
            return
        }

        if panel == nil { makePanel() }
        guard let panel, let contentView = listContentView else { return }

        Self.match(panel, to: parent)
        // The corner radius rides the interface scale with every other chrome
        // measurement in this panel (the width cap below does the same). It is
        // a plain number, not a resolved CGColor, so it does not belong inside
        // the appearance block.
        panel.contentView?.layer?.cornerRadius = CGFloat(metrics.pt(ChromeGeometry.cornerRadiusMax))

        contentView.onCommit = { [weak self] index in
            self?.onCommit?(index)
        }

        // The width cap is chrome, so it rides the interface zone exactly as the
        // hover popover's does (`HoverPanel`). The row height and the anchor gap
        // stay raw: one tracks the code font's cell, the other is the same
        // class of fixed anchor offset `DiffView`'s code-side paddings are.
        let maximumWidth = CGFloat(metrics.pt(Double(Self.maximumWidth)))
        let width = CompletionRowLayout.measureWidth(
            for: rows,
            codeFont: codeFont,
            metrics: metrics,
            maximumWidth: maximumWidth
        )
        let rowHeight = contentView.rowHeight(codeFont: codeFont)
        // The provider's 30 is a *list* cap, not a visible one: at a zoomed code
        // font thirty rows outrun the screen, so the drawn count is bounded by
        // whatever space the anchor's screen actually has on either side. The
        // rest stays reachable through the scroll view, exactly as the plan
        // specifies ("rows beyond the visible cap scroll").
        let visibleRows = Self.visibleRowCount(rows.count, rowHeight: rowHeight, anchoredTo: anchor)
        let height = rowHeight * CGFloat(visibleRows)

        let contentSize = NSSize(width: width, height: height)
        panel.setContentSize(contentSize)

        contentView.update(
            rows: rows,
            selection: selection?.selectedIndex ?? 0,
            codeFont: codeFont,
            metrics: metrics,
            width: width
        )

        panel.setFrameOrigin(Self.origin(for: panel.frame.size, anchoredTo: anchor))

        if let parent {
            if attachedParent !== parent {
                attachedParent?.removeChildWindow(panel)
                parent.addChildWindow(panel, ordered: .above)
                attachedParent = parent
            }
        } else if let oldParent = attachedParent {
            oldParent.removeChildWindow(panel)
            attachedParent = nil
        }
        panel.orderFront(nil)
        isShown = true

        if eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                guard let self, let panel = self.panel else { return event }
                if event.window !== panel {
                    // The controller's dismissal first — it cancels the pending
                    // request and supersedes the list, which the panel hiding
                    // alone must not leave alive. Idempotent either way: if the
                    // callback already ran it, this hits the `isShown` guard.
                    self.onOutsideClick?()
                    self.dismiss()
                }
                return event
            }
        }
    }

    func dismiss() {
        guard let panel, isShown else { return }
        isShown = false
        attachedParent?.removeChildWindow(panel)
        attachedParent = nil
        panel.orderOut(nil)

        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private static func match(_ panel: PassThroughPanel, to parent: NSWindow?) {
        let appearance = parent?.effectiveAppearance ?? NSApp.effectiveAppearance
        guard panel.appearance?.name != appearance.name else { return }
        panel.appearance = appearance
        // Both are CGColors, so they are resolved once at assignment and must be
        // reset when the appearance changes — the same trap as the border, now
        // true of the background as well.
        appearance.performAsCurrentDrawingAppearance {
            panel.contentView?.layer?.borderColor = ChromePalette.nsColor(.hairline).cgColor
            panel.contentView?.layer?.backgroundColor = ChromePalette.nsColor(.bgPopover).cgColor
        }
    }

    private func makePanel() {
        let panel = PassThroughPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.maximumWidth, height: 0),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isExcludedFromWindowsMenu = true
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle]

        let background = NSView()
        background.wantsLayer = true
        // The hairline stays unscaled: one point by definition, the stated
        // exception in `ChromeGeometry`'s header (a code-zoom surface has no
        // interface metrics, and a hairline is not a measurement that grows).
        // The corner radius is not an exception and is scaled in `show(…)` where
        // the interface metrics are known.
        background.layer?.borderWidth = ChromeGeometry.hairlineWidth
        background.layer?.masksToBounds = true

        let contentView = CompletionListContentView()
        self.listContentView = contentView
        let scrollView = CodeScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.documentView = contentView

        background.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: background.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])

        panel.contentView = background
        self.panel = panel
    }

    private static func visibleFrame(for anchor: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        return screen?.visibleFrame ?? anchor
    }

    /// How many rows may be drawn at once: the provider's list cap, bounded by
    /// the room the anchor's screen has below or above the anchor (whichever is
    /// larger, since `origin(for:anchoredTo:)` flips sides when below fails).
    ///
    /// The floor keeps a cramped screen from degenerating into a zero-row
    /// panel — a too-tall popup clamps at the screen edge (the pre-existing
    /// behaviour) and stays usable, an empty one cannot.
    private static func visibleRowCount(_ totalRows: Int, rowHeight: CGFloat, anchoredTo anchor: NSRect) -> Int {
        guard rowHeight > 0 else { return min(totalRows, 30) }
        let visible = visibleFrame(for: anchor)
        let below = max(0, anchor.minY - gap - visible.minY)
        let above = max(0, visible.maxY - anchor.maxY - gap)
        let fitRows = Int(floor(max(below, above) / rowHeight))
        return min(totalRows, 30, max(fitRows, 5))
    }

    private static func origin(for size: NSSize, anchoredTo anchor: NSRect) -> NSPoint {
        let visible = visibleFrame(for: anchor)
        var originY = anchor.minY - gap - size.height
        if originY < visible.minY {
            let above = anchor.maxY + gap
            if above + size.height <= visible.maxY { originY = above }
        }
        let originX = min(max(anchor.minX, visible.minX), max(visible.minX, visible.maxX - size.width))
        return NSPoint(x: originX, y: max(originY, visible.minY))
    }
}

@MainActor
private final class PassThroughPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CompletionListContentView: NSView, ZoomSurfaceProviding {
    let zoomSurfaceKind: ZoomSurfaceKind = .code

    private var rows: [CompletionRow] = []
    private var selection: Int = 0
    private var codeFont: NSFont = EditorFont.font(size: 13, family: nil)
    private var metrics: InterfaceMetrics = .unscaled

    var onCommit: ((Int) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(
        rows: [CompletionRow],
        selection: Int,
        codeFont: NSFont,
        metrics: InterfaceMetrics,
        width: CGFloat
    ) {
        self.rows = rows
        self.selection = selection
        self.codeFont = codeFont
        self.metrics = metrics

        let height = rowHeight(codeFont: codeFont) * CGFloat(rows.count)
        self.frame = NSRect(x: 0, y: 0, width: width, height: height)

        needsDisplay = true
        scrollToSelection()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    func rowHeight(codeFont: NSFont) -> CGFloat {
        // monospaced font + padding
        return ceil(codeFont.ascender - codeFont.descender) + 6 // padding
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let rHeight = rowHeight(codeFont: codeFont)
        let index = Int(point.y / rHeight)
        if index >= 0 && index < rows.count {
            onCommit?(index)
        }
    }

    private func scrollToSelection() {
        let rHeight = rowHeight(codeFont: codeFont)
        let rect = NSRect(x: 0, y: CGFloat(selection) * rHeight, width: bounds.width, height: rHeight)
        scrollToVisible(rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rHeight = rowHeight(codeFont: codeFont)

        for (index, row) in rows.enumerated() {
            let originY = CGFloat(index) * rHeight
            let rect = NSRect(x: 0, y: originY, width: bounds.width, height: rHeight)
            guard dirtyRect.intersects(rect) else { continue }

            if index == selection {
                ChromePalette.nsColor(.accent).setFill()
                rect.fill()
            }

            // The badge column is interface chrome and rides the interface
            // zone's metrics; its vertical centering stays inside the row,
            // whose height belongs to the code font.
            let badgeSide = CGFloat(metrics.pt(14))
            let badgeRect = NSRect(
                x: CGFloat(metrics.pt(8)),
                y: originY + (rHeight - badgeSide) / 2,
                width: badgeSide,
                height: badgeSide
            )
            if let image = NSImage(systemSymbolName: row.badge.symbolName, accessibilityDescription: nil) {
                let badgeColor = (index == selection)
                    ? ChromePalette.nsColor(.onAccent) : ChromePalette.nsColor(.textSecondary)
                let symbolConfig = NSImage.SymbolConfiguration(
                    pointSize: CGFloat(metrics.pt(12)),
                    weight: .regular
                )
                .applying(.init(paletteColors: [badgeColor]))
                let configuredImage = image.withSymbolConfiguration(symbolConfig) ?? image
                configuredImage.draw(in: badgeRect)
            }

            let layout = CompletionRowLayout.make(
                label: row.displayText,
                detail: row.item.detail,
                codeFont: codeFont,
                metrics: metrics,
                width: bounds.width
            )
            let color = (index == selection) ? ChromePalette.nsColor(.onAccent) : ChromePalette.nsColor(.textPrimary)
            let attr = NSAttributedString(string: layout.label, attributes: [
                .font: codeFont,
                .foregroundColor: color,
            ])
            attr.draw(at: NSPoint(x: layout.labelX, y: originY + (rHeight - attr.size().height) / 2))

            // Dimmed in the same role the badge uses off the selection, and on
            // the selection the same contrast role the label takes there.
            if let detail = layout.detail {
                let detailColor = (index == selection)
                    ? ChromePalette.nsColor(.onAccent) : ChromePalette.nsColor(.textSecondary)
                let detailString = NSAttributedString(string: detail, attributes: [
                    .font: codeFont,
                    .foregroundColor: detailColor,
                ])
                detailString.draw(at: NSPoint(
                    x: layout.detailX,
                    y: originY + (rHeight - detailString.size().height) / 2
                ))
            }
        }
    }
}

/// One row's horizontal layout: the label at its column, untruncated, and the
/// item's `detail` right-aligned in whatever room the label leaves.
///
/// **The label keeps priority.** It is what the commit inserts and what the
/// user is choosing between, so it is never shortened for the detail; the
/// detail takes what is left and is truncated at its *leading* edge, because
/// the tail of a signature (`-> String`, the module) is the part that tells two
/// overloads apart. No room for even one character after the ellipsis draws no
/// detail at all. The panel's width is measured here too, so the one place
/// that knows the columns is also the one that caps them at `maximumWidth`.
///
/// Internal rather than private so the app-layer bundle can measure a row
/// headlessly (`CompletionPanelDetailLayoutTests`).
struct CompletionRowLayout: Equatable {
    /// The label as drawn: the display text projected onto one line.
    let label: String
    let labelX: CGFloat
    /// The detail as drawn — head-truncated with a leading `…` when it did not
    /// fit — or `nil` when the item has none or no room is left for it.
    let detail: String?
    let detailX: CGFloat

    /// Where the label starts: right of the badge column (interface chrome).
    static func labelX(metrics: InterfaceMetrics) -> CGFloat { CGFloat(metrics.pt(28)) }
    /// The padding right of the last column.
    static func trailingInset(metrics: InterfaceMetrics) -> CGFloat { CGFloat(metrics.pt(12)) }
    /// The least space kept between the label's end and the detail's start.
    static func columnGap(metrics: InterfaceMetrics) -> CGFloat { CGFloat(metrics.pt(16)) }

    static func make(
        label: String,
        detail: String?,
        codeFont: NSFont,
        metrics: InterfaceMetrics,
        width: CGFloat
    ) -> CompletionRowLayout {
        let attributes: [NSAttributedString.Key: Any] = [.font: codeFont]
        let shownLabel = singleLineDisplay(label)
        let labelX = labelX(metrics: metrics)
        let labelEnd = labelX + (shownLabel as NSString).size(withAttributes: attributes).width
        let trailingEdge = width - trailingInset(metrics: metrics)
        guard let detail = detail.map(singleLineDisplay), !detail.isEmpty else {
            return CompletionRowLayout(label: shownLabel, labelX: labelX, detail: nil, detailX: trailingEdge)
        }
        let room = trailingEdge - labelEnd - columnGap(metrics: metrics)
        guard let fitted = headTruncated(detail, toWidth: room, attributes: attributes) else {
            return CompletionRowLayout(label: shownLabel, labelX: labelX, detail: nil, detailX: trailingEdge)
        }
        let fittedWidth = (fitted as NSString).size(withAttributes: attributes).width
        return CompletionRowLayout(
            label: shownLabel,
            labelX: labelX,
            detail: fitted,
            detailX: trailingEdge - fittedWidth
        )
    }

    /// The panel's content width for `rows`: the widest label-plus-detail row,
    /// never more than `maximumWidth`. A detail that would push past the cap is
    /// what gets truncated when drawn, never the label.
    static func measureWidth(
        for rows: [CompletionRow],
        codeFont: NSFont,
        metrics: InterfaceMetrics,
        maximumWidth: CGFloat
    ) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: codeFont]
        var widest: CGFloat = 0
        for row in rows {
            var rowWidth = (singleLineDisplay(row.displayText) as NSString).size(withAttributes: attributes).width
            if let detail = row.item.detail.map(singleLineDisplay), !detail.isEmpty {
                rowWidth += columnGap(metrics: metrics)
                    + (detail as NSString).size(withAttributes: attributes).width
            }
            widest = max(widest, rowWidth)
        }
        let width = labelX(metrics: metrics) + widest + trailingInset(metrics: metrics)
        return min(maximumWidth, width)
    }

    /// `text` when it fits `width`; otherwise its longest tail that fits behind
    /// a leading `…`; `nil` when not even one character does.
    private static func headTruncated(
        _ text: String,
        toWidth width: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) -> String? {
        guard width > 0 else { return nil }
        func fits(_ candidate: String) -> Bool {
            (candidate as NSString).size(withAttributes: attributes).width <= width
        }
        if fits(text) { return text }
        let characters = Array(text)
        // Binary search over how many leading characters are dropped: more
        // dropped never makes the string wider, so the fitting set is a suffix.
        var low = 1
        var high = characters.count - 1
        var best: String?
        while low <= high {
            let dropped = (low + high) / 2
            let candidate = "…" + String(characters[dropped...])
            if fits(candidate) {
                best = candidate
                high = dropped - 1
            } else {
                low = dropped + 1
            }
        }
        return best
    }

    /// The row's text projected onto one line.
    ///
    /// An LSP item's display text is what the server inserts, and a YAML
    /// property completion legitimately carries newlines (`services:\n  `).
    /// Drawing that verbatim paints over the rows below and desyncs the visual
    /// list from click hit-testing, which divides the row height evenly. The
    /// popup shows single-line choices: the first line stands in for the whole
    /// insertion, marked with an ellipsis. Display-only — the committed text
    /// and every key built on it stay the full string.
    static func singleLineDisplay(_ text: String) -> String {
        guard text.contains("\n") || text.contains("\r") else { return text }
        var head = text.components(separatedBy: .newlines)[0]
        while let last = head.last, last == " " || last == "\t" {
            head.removeLast()
        }
        return head + "…"
    }
}
#endif
