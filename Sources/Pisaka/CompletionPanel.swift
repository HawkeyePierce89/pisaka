#if os(macOS)
import AppKit
import PisakaCore
import SwiftUI

@MainActor
final class CompletionPanel {
    private static let maximumWidth: CGFloat = 520
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
        codeFontSize: CGFloat,
        metrics: InterfaceMetrics
    ) {
        guard !rows.isEmpty else {
            dismiss()
            return
        }

        if panel == nil { makePanel() }
        guard let panel, let contentView = listContentView else { return }

        Self.match(panel, to: parent)

        contentView.onCommit = { [weak self] index in
            self?.onCommit?(index)
        }

        // The width cap is chrome, so it rides the interface zone exactly as the
        // hover popover's does (`HoverPanel`). The row height and the anchor gap
        // stay raw: one tracks the code font's cell, the other is the same
        // class of fixed anchor offset `DiffView`'s code-side paddings are.
        let maximumWidth = CGFloat(metrics.pt(Double(Self.maximumWidth)))
        let width = min(maximumWidth, contentView.measureWidth(for: rows, codeFontSize: codeFontSize, metrics: metrics))
        let rowHeight = contentView.rowHeight(codeFontSize: codeFontSize)
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
            codeFontSize: codeFontSize,
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
        appearance.performAsCurrentDrawingAppearance {
            panel.contentView?.layer?.borderColor = NSColor.separatorColor.cgColor
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

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.borderWidth = 1
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
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor)
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
    private var codeFontSize: CGFloat = 13
    private var metrics: InterfaceMetrics = .unscaled

    var onCommit: ((Int) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(
        rows: [CompletionRow],
        selection: Int,
        codeFontSize: CGFloat,
        metrics: InterfaceMetrics,
        width: CGFloat
    ) {
        self.rows = rows
        self.selection = selection
        self.codeFontSize = codeFontSize
        self.metrics = metrics

        let height = rowHeight(codeFontSize: codeFontSize) * CGFloat(rows.count)
        self.frame = NSRect(x: 0, y: 0, width: width, height: height)

        needsDisplay = true
        scrollToSelection()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    func rowHeight(codeFontSize: CGFloat) -> CGFloat {
        // monospaced font + padding
        let codeFont = NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular)
        return ceil(codeFont.ascender - codeFont.descender) + 6 // padding
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
    private static func singleLineDisplay(_ text: String) -> String {
        guard text.contains("\n") || text.contains("\r") else { return text }
        var head = text.components(separatedBy: .newlines)[0]
        while let last = head.last, last == " " || last == "\t" {
            head.removeLast()
        }
        return head + "…"
    }

    func measureWidth(for rows: [CompletionRow], codeFontSize: CGFloat, metrics: InterfaceMetrics) -> CGFloat {
        let codeFont = NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular)
        var maxW: CGFloat = 0
        let attributes: [NSAttributedString.Key: Any] = [.font: codeFont]
        for row in rows {
            let textString = Self.singleLineDisplay(row.displayText) as NSString
            let size = textString.size(withAttributes: attributes)
            maxW = max(maxW, size.width)
        }
        // width = badge column + text + padding — interface chrome, so scaled
        return maxW + CGFloat(metrics.pt(40))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let rHeight = rowHeight(codeFontSize: codeFontSize)
        let index = Int(point.y / rHeight)
        if index >= 0 && index < rows.count {
            onCommit?(index)
        }
    }

    private func scrollToSelection() {
        let rHeight = rowHeight(codeFontSize: codeFontSize)
        let rect = NSRect(x: 0, y: CGFloat(selection) * rHeight, width: bounds.width, height: rHeight)
        scrollToVisible(rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rHeight = rowHeight(codeFontSize: codeFontSize)
        let codeFont = NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular)

        for (index, row) in rows.enumerated() {
            let originY = CGFloat(index) * rHeight
            let rect = NSRect(x: 0, y: originY, width: bounds.width, height: rHeight)
            guard dirtyRect.intersects(rect) else { continue }

            if index == selection {
                NSColor.selectedContentBackgroundColor.setFill()
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
                let nsColor = color(for: row.badge.color)
                let symbolConfig = NSImage.SymbolConfiguration(
                    pointSize: CGFloat(metrics.pt(12)),
                    weight: .regular
                )
                .applying(.init(paletteColors: [nsColor]))
                let configuredImage = image.withSymbolConfiguration(symbolConfig) ?? image
                configuredImage.draw(in: badgeRect)
            }

            let color = (index == selection) ? NSColor.selectedControlTextColor : NSColor.labelColor
            let attr = NSAttributedString(string: Self.singleLineDisplay(row.displayText), attributes: [
                .font: codeFont,
                .foregroundColor: color
            ])
            attr.draw(at: NSPoint(x: CGFloat(metrics.pt(28)), y: originY + (rHeight - attr.size().height) / 2))
        }
    }

    private func color(for token: FileIconColor) -> NSColor {
        switch token {
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .blue: return .systemBlue
        case .green: return .systemGreen
        case .purple: return .systemPurple
        case .red: return .systemRed
        case .pink: return .systemPink
        case .gray: return .systemGray
        case .accent: return .controlAccentColor
        }
    }
}
#endif
