#if os(macOS)
import AppKit
import PisakaCore

/// The hover popover: a borderless panel that draws a `HoverContent` beside the
/// identifier the pointer is resting on.
///
/// **The pointer cannot reach it, and that is the whole design.** The panel sets
/// `ignoresMouseEvents = true`, so every click, ⌘-click, drag-selection and
/// context menu passes straight through to the code beneath it, and a pointer
/// that appears to move "onto" the popover is in fact still over the text view —
/// which simply updates or dismisses the answer. Three properties fall out of
/// that one line and none of them has to be arranged separately:
///
/// - **It is chrome, not a code surface** (`ZoomSurface.swift`'s "unreachable ≡
///   chrome" rule). Nothing here conforms to `ZoomSurfaceProviding`, because a
///   zoom gesture aimed at where the popover *appears* to be is a gesture over
///   the editor, which is exactly the zone the user means.
/// - **It cannot take focus.** The panel is non-activating and refuses to become
///   key or main, so typing never stops going where it was going.
/// - **It cannot scroll**, which is why `HoverContent` truncates by line count
///   instead: a scrollable popover would need the pointer inside it, and would
///   undo all three of these at once.
///
/// Thin, untested view-layer glue by convention. Every decision it draws —
/// what a segment is, which of them are code, how many lines fit, whether the
/// answer was cut — arrives already made from `PisakaCore`; this file owns only
/// fonts, padding and where on screen the thing goes.
@MainActor
final class HoverPanel {

    /// The widest the popover may be, in points at the resting interface scale.
    ///
    /// A cap rather than a fit: a one-line generic signature can be hundreds of
    /// characters wide, and a popover that grows to the width of the screen is
    /// unreadable long before it is informative. Prose wraps at this width; a
    /// code line is truncated at it, because wrapping a signature mid-type is
    /// worse than showing its head.
    private static let maximumWidth: CGFloat = 520

    /// The inset between the panel's edge and its text.
    private static let padding: CGFloat = 8

    /// The gap between the anchored line and the popover's nearest edge, so the
    /// panel never sits directly on the glyphs it describes.
    private static let gap: CGFloat = 4

    /// The panel, built on first use and reused for the lifetime of the editor —
    /// a hover is shown and dismissed constantly, and a fresh `NSPanel` per
    /// dwell is a window-server round trip per identifier.
    private var panel: PassThroughPanel?

    /// The window the panel is currently a child of, so `dismiss()` can detach it
    /// from the same one it was attached to even after the editor moved windows.
    private weak var attachedParent: NSWindow?

    /// Whether a popover is on screen right now.
    var isVisible: Bool { panel?.isVisible ?? false }

    /// Draw `content` next to `anchor` (a rect in **screen** coordinates, which
    /// is what `NSTextView.firstRect(forCharacterRange:actualRange:)` answers).
    ///
    /// `codeFontSize` is the editor's own `SettingsStore.fontSize` — the code
    /// zone's size, passed through untouched, because a type signature drawn at
    /// anything other than the size the code beside it is drawn at reads as a
    /// different file. `metrics` is the *interface* zone's, and only prose uses
    /// it: the two zones stay independent inside one popover, exactly as they do
    /// everywhere else.
    func show(
        _ content: HoverContent,
        anchoredTo anchor: NSRect,
        in parent: NSWindow?,
        codeFontSize: CGFloat,
        metrics: InterfaceMetrics
    ) {
        let text = Self.attributedString(
            for: content,
            codeFontSize: codeFontSize,
            metrics: metrics
        )
        let inset = CGFloat(metrics.pt(Double(Self.padding)))
        let maximumWidth = CGFloat(metrics.pt(Double(Self.maximumWidth)))
        let bounding = text.boundingRect(
            with: NSSize(width: maximumWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let contentSize = NSSize(
            width: min(maximumWidth, ceil(bounding.width)),
            height: ceil(bounding.height)
        )
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.setContentSize(
            NSSize(width: contentSize.width + inset * 2, height: contentSize.height + inset * 2)
        )
        panel.label.attributedStringValue = text
        panel.label.frame = NSRect(
            x: inset,
            y: inset,
            width: contentSize.width,
            height: contentSize.height
        )
        panel.setFrameOrigin(Self.origin(for: panel.frame.size, anchoredTo: anchor))

        // Attached to the editor's window so the popover travels with it, orders
        // out with it and cannot outlive it. Re-attached only when the parent
        // actually changed: `addChildWindow` on the current parent re-orders the
        // whole child list on every dwell.
        if let parent, attachedParent !== parent {
            attachedParent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
            attachedParent = parent
        }
        panel.orderFront(nil)
    }

    /// Take the popover down. **Idempotent**: dismissal arrives from a dozen
    /// unrelated places (a scroll, an edit, a tab switch, teardown) and several
    /// of them routinely fire when nothing is on screen.
    func dismiss() {
        guard let panel else { return }
        attachedParent?.removeChildWindow(panel)
        attachedParent = nil
        panel.orderOut(nil)
    }

    // MARK: - Building the panel

    private func makePanel() -> PassThroughPanel {
        let panel = PassThroughPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.maximumWidth, height: 0),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        // The one line the whole design rests on: the popover is a purely visual
        // overlay, so it is not a hit-test obstacle, not a focus target and not a
        // zoom surface. See this type's documentation.
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Not in the window cycle, not in the accessibility hierarchy of things
        // that can be moved to, and not restored across launches: it is a
        // transient annotation of the editor, not a window the user owns.
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
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        background.layer?.masksToBounds = true
        background.addSubview(panel.label)
        panel.contentView = background
        return panel
    }

    // MARK: - Drawing the content

    /// The whole popover as one attributed string: code segments monospaced at
    /// the editor's size, prose in the interface font, and — when Core says the
    /// answer was cut — a trailing ellipsis line.
    ///
    /// Per-segment paragraph styles rather than one for the string, because the
    /// two kinds want opposite line-breaking: prose wraps (a paragraph is meant
    /// to be read at whatever width there is) and code truncates (a wrapped
    /// signature invents indentation the language never had).
    private static func attributedString(
        for content: HoverContent,
        codeFontSize: CGFloat,
        metrics: InterfaceMetrics
    ) -> NSAttributedString {
        let codeFont = NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular)
        let proseFont = NSFont.systemFont(ofSize: CGFloat(metrics.font(.body)))

        let codeParagraph = NSMutableParagraphStyle()
        codeParagraph.lineBreakMode = .byTruncatingTail
        let proseParagraph = NSMutableParagraphStyle()
        proseParagraph.lineBreakMode = .byWordWrapping

        let result = NSMutableAttributedString()
        for (index, segment) in content.segments.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let isCode = segment.isCode
            result.append(
                NSAttributedString(
                    string: segment.text,
                    attributes: [
                        .font: isCode ? codeFont : proseFont,
                        .foregroundColor: isCode ? NSColor.labelColor : NSColor.secondaryLabelColor,
                        .paragraphStyle: isCode ? codeParagraph : proseParagraph,
                    ]
                )
            )
        }
        if content.isTruncated {
            result.append(
                NSAttributedString(
                    string: "\n\u{2026}",
                    attributes: [
                        .font: proseFont,
                        .foregroundColor: NSColor.tertiaryLabelColor,
                        .paragraphStyle: proseParagraph,
                    ]
                )
            )
        }
        return result
    }

    // MARK: - Placement

    /// Where a panel of `size` goes for an anchor line at `anchor`, in screen
    /// coordinates.
    ///
    /// Below the line by default and flipped above it when the popover would run
    /// off the bottom of the screen — the same rule a menu follows, and the one a
    /// user reading downward expects. The horizontal position is clamped rather
    /// than flipped: a popover pushed left to stay on screen still points at the
    /// right line, while one flipped to the other side of the identifier would
    /// not.
    private static func origin(for size: NSSize, anchoredTo anchor: NSRect) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor

        var y = anchor.minY - gap - size.height
        if y < visible.minY {
            let above = anchor.maxY + gap
            // Only flip when the flipped position is genuinely better: on a
            // screen too short for the popover either way, hanging below the
            // anchor at least keeps its first line — the signature — visible.
            if above + size.height <= visible.maxY { y = above }
        }
        let x = min(max(anchor.minX, visible.minX), max(visible.minX, visible.maxX - size.width))
        return NSPoint(x: x, y: max(y, visible.minY))
    }
}

/// The popover's window: borderless, non-activating, and incapable of taking
/// focus away from the editor.
///
/// `canBecomeKey`/`canBecomeMain` are overridden to `false` rather than left to
/// the style mask: a borderless panel is *already* refused key status by AppKit
/// today, and this states the requirement instead of depending on that. Nothing
/// in the popover is interactive, so there is nothing key status would buy.
@MainActor
private final class PassThroughPanel: NSPanel {
    /// The one thing drawn in the panel. An `NSTextField` label rather than a
    /// text view: it draws an attributed string, measures itself, and — being
    /// non-editable and non-selectable — carries none of a text view's input
    /// machinery into a window that ignores mouse events anyway.
    let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        return label
    }()

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

#endif
