#if os(macOS)
import SwiftUI
import AppKit
import Neon
import PisakaCore

/// A side-by-side diff of a changed file: `HEAD` on the left, the working copy on
/// the right, rendered from a pre-computed `[DiffRow]` (built in `PisakaCore` by
/// `LineDiff`, so all the off-by-one line/alignment math is unit-tested there).
///
/// Two read-only `NSTextView`s sit side by side. Each row maps to exactly one
/// visual line in *both* panes — a `nil` side becomes an empty filler line — so
/// the two panes stay vertically aligned line-for-line. Each `DiffTextView` paints
/// a full-width per-row wash by `DiffRowKind` (removed/changed on the old side,
/// added/changed on the new side, a filler line plain — Core's
/// `ChromeColorRole.diffWashRole(for:side:)`), and a `DiffGutterView` draws that
/// side's 1-based line numbers (blank for a filler line) plus a thin change marker
/// (`ChromeColorRole.diffMarkerRole(for:side:)`). Vertical scrolling is mirrored between
/// the panes, and both panes get the same Neon tree-sitter highlighting the editor
/// uses (`SyntaxLanguageConfiguration` + `SyntaxTheme`).
///
/// The view holds no domain logic: it renders the rows it is handed and re-renders
/// when `fileID` or the rows change (the caller computes the rows off the
/// per-keystroke path — see `ContentView`'s diff wrapper).
struct DiffView: NSViewRepresentable {
    /// Identity of the changed file being diffed; a change means the user picked a
    /// different file, so the panes are rebuilt wholesale.
    let fileID: String

    /// The changed file's name (its last path component). Its extension selects the
    /// syntax language for both panes; an unknown extension shows plain text.
    let fileName: String

    /// The aligned side-by-side rows to render (old/`HEAD` vs new/working copy).
    let rows: [DiffRow]

    /// The shared editor font size (points). Owned by `SettingsStore`; a change
    /// re-applies the panes' font and refreshes the gutters in `updateNSView`.
    var fontSize: Double = Double(NSFont.systemFontSize)

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> DiffContainerView {
        let coordinator = context.coordinator

        let (leftScroll, leftText, leftGutter) = makePane(side: .old)
        let (rightScroll, rightText, rightGutter) = makePane(side: .new)

        coordinator.attach(
            leftScroll: leftScroll, leftText: leftText, leftGutter: leftGutter,
            rightScroll: rightScroll, rightText: rightText, rightGutter: rightGutter
        )

        let container = DiffContainerView(leftScroll: leftScroll, rightScroll: rightScroll)

        coordinator.appliedFontSize = CGFloat(fontSize)
        coordinator.fileID = fileID
        coordinator.loadContent(rows: rows, fileName: fileName)
        return container
    }

    func updateNSView(_ container: DiffContainerView, context: Context) {
        let coordinator = context.coordinator
        // Re-apply the shared font to both panes when its size changed (the
        // Stepper or a Cmd+scroll). Setting `.font` re-styles each pane's whole
        // buffer; the tree-sitter colors survive. The gutters re-derive their font
        // from their pane per draw, so a `refresh()` (thickness + redraw) re-syncs
        // them. The font is uniform across both panes, so rows stay aligned.
        let desiredFontSize = CGFloat(fontSize)
        if coordinator.appliedFontSize != desiredFontSize {
            coordinator.appliedFontSize = desiredFontSize
            let font = NSFont.monospacedSystemFont(ofSize: desiredFontSize, weight: .regular)
            coordinator.leftText?.font = font
            coordinator.rightText?.font = font
            coordinator.leftGutter?.refresh()
            coordinator.rightGutter?.refresh()
        }

        // Rebuild the panes only when the selected file changed or the rows differ
        // (e.g. the list refreshed after a save). The caller recomputes `rows`
        // outside the per-keystroke path, so an unchanged (fileID, rows) is a no-op.
        let fileChanged = coordinator.fileID != fileID
        if fileChanged || coordinator.rows != rows {
            coordinator.fileID = fileID
            coordinator.loadContent(rows: rows, fileName: fileName)
        }
    }

    static func dismantleNSView(_ nsView: DiffContainerView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    /// Build one diff pane: a non-wrapping, read-only `DiffTextView` inside a
    /// scroll view with a `DiffGutterView` line-number ruler. Mirrors
    /// `CodeEditorView`'s TextKit 1 / no-soft-wrap setup so a logical line occupies
    /// exactly one visual row (the row-to-line alignment the diff depends on).
    private func makePane(side: DiffSide) -> (NSScrollView, DiffTextView, DiffGutterView) {
        let textView = DiffTextView(usingTextLayoutManager: false)
        textView.side = side

        // `CodeScrollView` so the pane's empty region — below the last line, right
        // of the longest one — is still the code zone (see `ZoomSurface`).
        let scrollView = CodeScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = textView
        CodePaneGround.apply(scrollView: scrollView, textView: textView)

        let maxSize = CGFloat.greatestFiniteMagnitude
        textView.minSize = .zero
        textView.maxSize = NSSize(width: maxSize, height: maxSize)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = NSSize(width: maxSize, height: maxSize)
        textView.layoutManager?.allowsNonContiguousLayout = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        // The colour of a character no capture covers — the same question
        // `SyntaxTokenKind.plain` answers — so it is read from the one table
        // rather than left on the text view's system-label default. That default
        // is not the design's value: the palette's plain row is `#1d1d1f`/
        // `#dfe1e5` and the label colour is pure black/white, so a character no
        // capture covers would sit a step off the table beside every character
        // one does.
        textView.textColor = SyntaxTheme.shared.color(for: .plain)

        let gutter = DiffGutterView(scrollView: scrollView, textView: textView, side: side)
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        return (scrollView, textView, gutter)
    }

    /// Owns the two panes, mirrors their vertical scroll, and holds each pane's
    /// Neon highlighter for the lifetime of the shown diff.
    @MainActor
    final class Coordinator: NSObject {
        var fileID: String?
        var rows: [DiffRow] = []

        /// The font size currently applied to both panes, so `updateNSView`
        /// re-applies the font (and refreshes the gutters) only on a real change.
        var appliedFontSize: CGFloat?

        weak var leftScroll: NSScrollView?
        weak var rightScroll: NSScrollView?
        weak var leftText: DiffTextView?
        weak var rightText: DiffTextView?
        weak var leftGutter: DiffGutterView?
        weak var rightGutter: DiffGutterView?

        // Highlighters install themselves as their text storage's delegate; held
        // strongly so they live as long as the diff is shown.
        private var leftHighlighter: TextViewHighlighter?
        private var rightHighlighter: TextViewHighlighter?

        /// Guards against the scroll-sync feedback loop (mirroring A→B must not
        /// bounce B→A).
        private var isSyncingScroll = false

        func attach(
            leftScroll: NSScrollView, leftText: DiffTextView, leftGutter: DiffGutterView,
            rightScroll: NSScrollView, rightText: DiffTextView, rightGutter: DiffGutterView
        ) {
            self.leftScroll = leftScroll
            self.leftText = leftText
            self.leftGutter = leftGutter
            self.rightScroll = rightScroll
            self.rightText = rightText
            self.rightGutter = rightGutter

            let center = NotificationCenter.default
            for clip in [leftScroll.contentView, rightScroll.contentView] {
                clip.postsBoundsChangedNotifications = true
                center.addObserver(
                    self,
                    selector: #selector(clipBoundsChanged(_:)),
                    name: NSView.boundsDidChangeNotification,
                    object: clip
                )
            }
        }

        /// One pane scrolled: mirror its vertical offset to the other pane so the
        /// two stay aligned. Horizontal scrolling is left independent.
        @objc private func clipBoundsChanged(_ notification: Notification) {
            guard !isSyncingScroll, let source = notification.object as? NSClipView else { return }
            let other: NSScrollView?
            if source === leftScroll?.contentView {
                other = rightScroll
            } else if source === rightScroll?.contentView {
                other = leftScroll
            } else {
                other = nil
            }
            guard let otherScroll = other else { return }
            let otherClip = otherScroll.contentView
            let y = source.bounds.origin.y
            guard abs(otherClip.bounds.origin.y - y) > 0.5 else { return }
            isSyncingScroll = true
            otherClip.scroll(to: NSPoint(x: otherClip.bounds.origin.x, y: y))
            otherScroll.reflectScrolledClipView(otherClip)
            isSyncingScroll = false
        }

        /// Replace both panes' contents from `rows`, rebuild the highlighters for
        /// the file's language, and refresh the gutters.
        func loadContent(rows: [DiffRow], fileName: String) {
            self.rows = rows
            let leftBody = rows.map { $0.left?.text ?? "" }.joined(separator: "\n")
            let rightBody = rows.map { $0.right?.text ?? "" }.joined(separator: "\n")

            // Detach the outgoing highlighters before swapping the buffers so a
            // stale grammar can't asynchronously repaint the incoming file (the
            // same cross-language race `CodeEditorView` guards against).
            detachHighlighters()

            leftText?.diffRows = rows
            leftText?.setDiffText(leftBody)
            rightText?.diffRows = rows
            rightText?.setDiffText(rightBody)

            let language = SyntaxLanguage(forFileName: fileName)
            if let leftText { leftHighlighter = makeHighlighter(for: leftText, language: language) }
            if let rightText { rightHighlighter = makeHighlighter(for: rightText, language: language) }

            leftGutter?.refresh()
            rightGutter?.refresh()
        }

        private func detachHighlighters() {
            leftHighlighter = nil
            leftText?.textStorage?.delegate = nil
            rightHighlighter = nil
            rightText?.textStorage?.delegate = nil
        }

        /// Build a Neon highlighter mapping each tree-sitter capture through
        /// `SyntaxTokenKind` to a `SyntaxTheme` color, exactly like the editor.
        /// Returns `nil` for plain text / a grammar that fails to load.
        private func makeHighlighter(for textView: NSTextView, language: SyntaxLanguage?) -> TextViewHighlighter? {
            guard
                let language,
                let languageConfiguration = SyntaxLanguageConfiguration.configuration(for: language)
            else { return nil }

            let theme = SyntaxTheme.shared
            let attributeProvider: TokenAttributeProvider = { token in
                [.foregroundColor: theme.nsColor(for: SyntaxTokenKind(captureName: token.name))]
            }
            let configuration = TextViewHighlighter.Configuration(
                languageConfiguration: languageConfiguration,
                attributeProvider: attributeProvider,
                languageProvider: { name in
                    SyntaxLanguageConfiguration.configuration(forInjectionName: name)
                },
                locationTransformer: { _ in nil }
            )
            return try? TextViewHighlighter(textView: textView, configuration: configuration)
        }

        func teardown() {
            NotificationCenter.default.removeObserver(self)
            detachHighlighters()
        }
    }
}

/// A read-only diff pane. Beyond an ordinary `NSTextView` it paints a full-width
/// per-row wash by `DiffRowKind` (so removed/added/changed rows read at a glance)
/// behind the glyphs and Neon's syntax colors. The wash is Core's answer,
/// `ChromeColorRole.diffWashRole(for:side:)`, resolved through the dynamic
/// `ChromePalette.nsColor(_:)`; a filler row carries none.
@MainActor
final class DiffTextView: NSTextView, ZoomSurfaceProviding {
    /// Which side of the diff this pane shows — Core's `DiffSide`, the one
    /// definition of a diff side, so the wash below asks Core with no mapping.
    var side: DiffSide = .old

    /// A diff pane draws with the shared editor font, so it is a *code* surface:
    /// a zoom gesture over it grows the code zone, exactly as one over the editor
    /// does. The Command-held `scrollWheel` override this replaced is gone — the
    /// app's single event monitor now sees the gesture before this view does, so
    /// the synced vertical scrolling below never competes with it.
    let zoomSurfaceKind: ZoomSurfaceKind = .code

    /// The rows backing this pane, used to pick each line's background color. Set
    /// alongside `setDiffText` so the line count and rows agree.
    var diffRows: [DiffRow] = []

    /// UTF-16 start offset of every line, so a glyph's character index maps to its
    /// row index in O(log n). Rebuilt whenever the text is replaced (via Core's
    /// `LineStartIndex`, matching the gutter/editor line semantics).
    private(set) var lineStartOffsets: [Int] = [0]

    /// Replace the pane's text and rebuild the line-start cache.
    func setDiffText(_ text: String) {
        string = text
        lineStartOffsets = LineStartIndex.offsets(in: string as NSString)
        needsDisplay = true
    }

    /// 0-based index of the line containing `charIndex` (count of line starts
    /// `<= charIndex`, minus one). Mirrors the gutter's binary search.
    func lineIndex(forCharacterAt charIndex: Int) -> Int {
        var low = 0
        var high = lineStartOffsets.count
        while low < high {
            let mid = (low + high) / 2
            if lineStartOffsets[mid] <= charIndex {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return max(0, low - 1)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard
            let layoutManager = self.layoutManager,
            let textContainer = self.textContainer,
            !diffRows.isEmpty
        else { return }

        let origin = textContainerOrigin
        // Only paint rows in the visible glyph range, so scrolling a large diff
        // stays O(visible lines) (the same optimization the editor's ruler uses).
        let visible = visibleRect
        let boundingRect = NSRect(
            x: 0,
            y: visible.minY - origin.y,
            width: max(visible.width, bounds.width),
            height: visible.height
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: boundingRect, in: textContainer)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, lineGlyphRange, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: lineGlyphRange.location)
            let row = self.lineIndex(forCharacterAt: charIndex)
            guard
                row < self.diffRows.count,
                let role = ChromeColorRole.diffWashRole(for: self.diffRows[row].kind, side: self.side)
            else { return }
            let fill = NSRect(
                x: 0,
                y: fragmentRect.minY + origin.y,
                width: self.bounds.width,
                height: fragmentRect.height
            )
            ChromePalette.nsColor(role).setFill()
            fill.fill()
        }
    }
}

/// The per-side line-number gutter for a diff pane. Like `LineNumberRulerView` it
/// draws right-aligned 1-based numbers beside each visible line fragment, but the
/// number comes from the row's `DiffLine` for this side (blank for a filler line),
/// and it paints a thin change marker at the inner edge for non-`unchanged` rows.
///
/// A **code** zoom surface for `LineNumberRulerView`'s reason: the gutter is the
/// scroll view's `verticalRulerView` and therefore a sibling of the pane's text
/// view, so a gesture over it would otherwise find no candidate and target the
/// interface while the numbers under the pointer follow the code zone.
@MainActor
final class DiffGutterView: NSRulerView, ZoomSurfaceProviding {
    let zoomSurfaceKind: ZoomSurfaceKind = .code

    private weak var diffTextView: DiffTextView?
    private let side: DiffSide
    private let horizontalPadding: CGFloat = 4
    /// Width of the change marker strip drawn at the gutter's inner edge.
    private let markerWidth: CGFloat = 2

    init(scrollView: NSScrollView, textView: DiffTextView, side: DiffSide) {
        self.diffTextView = textView
        self.side = side
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView

        let center = NotificationCenter.default
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        clipView.postsFrameChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        center.addObserver(self, selector: #selector(visibleAreaChanged), name: NSView.boundsDidChangeNotification, object: clipView)
        center.addObserver(self, selector: #selector(visibleAreaChanged), name: NSView.frameDidChangeNotification, object: clipView)
        center.addObserver(self, selector: #selector(visibleAreaChanged), name: NSView.frameDidChangeNotification, object: textView)
        refresh()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private var rulerFont: NSFont {
        let editorSize = diffTextView?.font?.pointSize ?? NSFont.systemFontSize
        let size = max(editorSize - 2, NSFont.smallSystemFontSize)
        return .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    @objc private func visibleAreaChanged() {
        needsDisplay = true
    }

    /// Resize the gutter to fit the widest number on this side, then redraw. Called
    /// when the rows change.
    func refresh() {
        updateThickness()
        needsDisplay = true
    }

    private func updateThickness() {
        let widestNumber = diffTextView?.diffRows.reduce(0) { current, row in
            let number = (side == .old ? row.left?.number : row.right?.number) ?? 0
            return max(current, number)
        } ?? 0
        let widest = "\(max(1, widestNumber))" as NSString
        let width = widest.size(withAttributes: [.font: rulerFont]).width
        let thickness = ceil(width) + horizontalPadding * 2 + markerWidth
        if ruleThickness != thickness {
            ruleThickness = thickness
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard
            let textView = diffTextView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer,
            !textView.diffRows.isEmpty
        else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: rulerFont,
            .foregroundColor: ChromePalette.nsColor(.textSecondary),
        ]
        let textOrigin = textView.textContainerOrigin
        let relativePoint = convert(NSPoint.zero, from: textView)

        let visible = textView.visibleRect
        let boundingRect = NSRect(
            x: 0,
            y: visible.minY - textOrigin.y,
            width: max(visible.width, textView.bounds.width),
            height: visible.height
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: boundingRect, in: textContainer)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, lineGlyphRange, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: lineGlyphRange.location)
            let rowIndex = textView.lineIndex(forCharacterAt: charIndex)
            guard rowIndex < textView.diffRows.count else { return }
            let row = textView.diffRows[rowIndex]
            let y = relativePoint.y + textOrigin.y + fragmentRect.minY

            // Change marker: a thin colored strip at the gutter's inner edge.
            if let markerRole = ChromeColorRole.diffMarkerRole(for: row.kind, side: self.side) {
                ChromePalette.nsColor(markerRole).setFill()
                NSRect(
                    x: self.ruleThickness - self.markerWidth,
                    y: y,
                    width: self.markerWidth,
                    height: fragmentRect.height
                ).fill()
            }

            // Line number for this side (filler lines have none).
            guard let line = (self.side == .old ? row.left : row.right) else { return }
            let label = "\(line.number)" as NSString
            let labelSize = label.size(withAttributes: attributes)
            let labelY = y + (fragmentRect.height - labelSize.height) / 2
            let labelX = self.ruleThickness - self.markerWidth - labelSize.width - self.horizontalPadding
            label.draw(at: NSPoint(x: labelX, y: labelY), withAttributes: attributes)
        }
    }
}

/// Lays out the two diff panes side by side, split evenly with a hairline divider.
///
/// The divider is a plain view filled with the `hairline` role, drawn
/// `ChromeGeometry.hairlineWidth` wide *unscaled*: the panes are a code-zoom
/// surface with no interface scale to ask, which is the token's one stated
/// exception (`LineNumberRulerView`'s own edge rule, for the same reason).
@MainActor
final class DiffContainerView: NSView {
    private let leftScroll: NSScrollView
    private let rightScroll: NSScrollView
    private let divider = DiffDividerView()

    init(leftScroll: NSScrollView, rightScroll: NSScrollView) {
        self.leftScroll = leftScroll
        self.rightScroll = rightScroll
        super.init(frame: .zero)
        addSubview(leftScroll)
        addSubview(divider)
        addSubview(rightScroll)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        let dividerWidth = CGFloat(ChromeGeometry.hairlineWidth)
        let paneWidth = max(0, (width - dividerWidth) / 2)
        leftScroll.frame = NSRect(x: 0, y: 0, width: paneWidth, height: height)
        divider.frame = NSRect(x: paneWidth, y: 0, width: dividerWidth, height: height)
        rightScroll.frame = NSRect(x: paneWidth + dividerWidth, y: 0, width: width - paneWidth - dividerWidth, height: height)
    }
}

/// The hairline between the two panes. Fills itself on every draw, so the
/// dynamic colour resolves against the current appearance with no observer.
@MainActor
final class DiffDividerView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        ChromePalette.nsColor(.hairline).setFill()
        dirtyRect.fill()
    }
}

/// A code pane's ground: the one definition of what a pane hosting code sits on.
///
/// The text view, the scroll view and that scroll view's clip view are set
/// together, because each draws part of the pane — the text view its own bounds,
/// the clip view everything the content does not cover, the scroll view the
/// rest. The role is `bgEditor` because the editor's gutter
/// (`LineNumberRulerView`) fills itself with it: an editor pane left on the
/// system's `textBackgroundColor` would show the gutter as a visibly lighter
/// band beside the text in the dark appearance, the two colours being different
/// greys. The other panes take the same ground so every code pane matches —
/// `DiffGutterView` fills nothing (it overrides only `drawHashMarksAndLabels`),
/// so what shows behind it is the scroll view's ground this helper sets, and the
/// three merge panes have no ruler at all. The colour is dynamic, so no caller
/// observes an appearance change.
///
/// Four callers: the editor (`CodeEditorView.makeNSView`), the diff
/// panes (`DiffView.makePane`), the three merge panes (`MergeThreePaneView
/// .makePane`) and the out-of-project source viewer (`SourceViewerContent`).
@MainActor
enum CodePaneGround {
    static func apply(scrollView: NSScrollView, textView: NSTextView) {
        let ground = ChromePalette.nsColor(.bgEditor)
        textView.backgroundColor = ground
        scrollView.backgroundColor = ground
        scrollView.contentView.backgroundColor = ground
    }
}

#endif
