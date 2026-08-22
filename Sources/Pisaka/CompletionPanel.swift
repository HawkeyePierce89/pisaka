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
        codeFontSize: CGFloat
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

        let width = min(Self.maximumWidth, contentView.measureWidth(for: rows, codeFontSize: codeFontSize))
        let visibleRows = min(rows.count, 30) // Cap visible size
        let height = contentView.rowHeight(codeFontSize: codeFontSize) * CGFloat(visibleRows)

        let contentSize = NSSize(width: width, height: height)
        panel.setContentSize(contentSize)

        contentView.update(
            rows: rows,
            selection: selection?.selectedIndex ?? 0,
            codeFontSize: codeFontSize,
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

    var onCommit: ((Int) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(rows: [CompletionRow], selection: Int, codeFontSize: CGFloat, width: CGFloat) {
        self.rows = rows
        self.selection = selection
        self.codeFontSize = codeFontSize

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

    func measureWidth(for rows: [CompletionRow], codeFontSize: CGFloat) -> CGFloat {
        let codeFont = NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular)
        var maxW: CGFloat = 0
        let attributes: [NSAttributedString.Key: Any] = [.font: codeFont]
        for row in rows {
            let textString = row.displayText as NSString
            let size = textString.size(withAttributes: attributes)
            maxW = max(maxW, size.width)
        }
        // width = badge + text + padding
        return maxW + 40 // simple extra space for badge and padding
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

            let badgeRect = NSRect(x: 8, y: originY + (rHeight - 14) / 2, width: 14, height: 14)
            if let image = NSImage(systemSymbolName: row.badge.symbolName, accessibilityDescription: nil) {
                let nsColor = color(for: row.badge.color)
                let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                    .applying(.init(paletteColors: [nsColor]))
                let configuredImage = image.withSymbolConfiguration(symbolConfig) ?? image
                configuredImage.draw(in: badgeRect)
            }

            let color = (index == selection) ? NSColor.selectedControlTextColor : NSColor.labelColor
            let attr = NSAttributedString(string: row.displayText, attributes: [
                .font: codeFont,
                .foregroundColor: color
            ])
            attr.draw(at: NSPoint(x: 28, y: originY + (rHeight - attr.size().height) / 2))
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
