#if os(macOS)
import SwiftUI
import AppKit
import PisakaCore

/// The 3-pane conflict-resolution editor: `ours | result | theirs`. The left and
/// right panes are read-only views of each side's full content (stable regions
/// plus that side's version of every conflict hunk); the middle pane is the live,
/// *editable* merged result built from `MergeDocument.resolvedText` (an unresolved
/// conflict shows git-style markers). Conflict hunks are highlighted in all three
/// panes, and vertical scrolling is mirrored across them.
///
/// All domain logic lives in `PisakaCore` (`ThreeWayMerge`, `MergeDocument`,
/// `MergeModel`); this is a thin, intentionally untested view layer — the same
/// split as `DiffView`/`CodeEditorView`. A toolbar drives per-conflict resolution
/// (◀ ours / both orderings / theirs ▶), prev/next conflict navigation, and an
/// "Apply" affordance enabled only when every conflict is resolved
/// (`MergeModel.isFullyResolved`). Editing the middle pane within a conflict region
/// feeds that region's text back into the model as `.custom`.
struct MergeView: View {
    @ObservedObject var model: MergeModel

    /// Shared user preferences, observed so the separate merge window's pane fonts
    /// update live when the editor font size changes (Stepper or Cmd+scroll).
    @ObservedObject var settings: SettingsStore = SettingsStore()

    /// Invoked when the user presses "Apply" (only enabled when fully resolved).
    /// The owner runs `MergeModel.apply()`, closes the window, and refreshes Local
    /// Changes; a failure surfaces via `model.errorMessage`.
    var onApply: () -> Void = {}

    /// The conflict the toolbar's accept buttons act on and that prev/next
    /// navigates between (conflict order). Clamped to the document's conflicts.
    @State private var currentConflict = 0

    /// The interface zone's metrics. Computed from the store rather than read
    /// from the environment because this view is the *root* of its own window and
    /// injects the value below (`SettingsStore.interfaceMetrics`). It reaches the
    /// toolbar, the pane labels and the window's minimum size; the three text
    /// panes stay on `settings.fontSize`, the code zone.
    private var metrics: InterfaceMetrics { settings.interfaceMetrics }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            header
            Divider()
            content
            if let message = model.errorMessage, model.document != nil {
                Divider()
                Text(message)
                    .font(metrics.scaledFont(.callout))
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, metrics.scaled(8))
                    .padding(.vertical, metrics.scaled(4))
            }
        }
        .frame(minWidth: metrics.scaled(720), minHeight: metrics.scaled(420))
        // Apply the theme preference here too, so a forced Light/Dark reaches this
        // separate merge window's hosted AppKit content (the main window does the
        // same on its root). The shared font size already propagates via `settings`.
        .preferredColorScheme(settings.themePreference.colorScheme)
        // This window is its own SwiftUI root — an `NSHostingController` created by
        // `MergeWindowController` — so it injects the interface scale itself.
        .interfaceScaled(settings)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: metrics.scaled(8)) {
            if let document = model.document, document.conflictCount > 0 {
                Button { navigate(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(currentConflict <= 0)
                Text("Conflict \(min(currentConflict + 1, document.conflictCount)) of \(document.conflictCount)")
                    .font(metrics.scaledFont(.callout).monospacedDigit())
                Button { navigate(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(currentConflict >= document.conflictCount - 1)

                Divider().frame(height: metrics.scaled(16))

                Button("◀ Ours") { accept(.ours) }
                Button("Ours+Theirs") { accept(.bothOursFirst) }
                Button("Theirs+Ours") { accept(.bothTheirsFirst) }
                Button("Theirs ▶") { accept(.theirs) }
            }

            Spacer()

            Text(statusText)
                .font(metrics.scaledFont(.callout))
                .foregroundStyle(model.isFullyResolved ? Color.green : Color.secondary)

            Button("Apply", action: onApply)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.isFullyResolved)
        }
        .font(metrics.scaledFont(.body))
        .padding(.horizontal, metrics.scaled(8))
        .padding(.vertical, metrics.scaled(6))
    }

    private var statusText: String {
        guard model.document != nil else { return "" }
        if model.isFullyResolved { return "All conflicts resolved" }
        let count = model.unresolvedCount
        return "\(count) unresolved conflict\(count == 1 ? "" : "s")"
    }

    private var header: some View {
        HStack(spacing: 0) {
            paneLabel("Ours")
            Divider()
            paneLabel("Result")
            Divider()
            paneLabel("Theirs")
        }
        .frame(height: metrics.scaled(22))
    }

    private func paneLabel(_ title: String) -> some View {
        Text(title)
            .font(metrics.scaledFont(.caption, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.document != nil {
            MergeThreePaneView(
                model: model,
                currentConflict: $currentConflict,
                fontSize: settings.fontSize
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(model.errorMessage ?? "Loading…")
                .font(metrics.scaledFont(.body))
                .foregroundStyle(model.errorMessage == nil ? Color.secondary : Color.red)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Actions

    private func navigate(_ delta: Int) {
        guard let document = model.document, document.conflictCount > 0 else { return }
        currentConflict = min(max(currentConflict + delta, 0), document.conflictCount - 1)
    }

    private func accept(_ resolution: Resolution) {
        guard let document = model.document, document.conflictCount > 0 else { return }
        let index = min(max(currentConflict, 0), document.conflictCount - 1)
        model.accept(resolution, at: index)
    }
}

/// Background highlight for a line in one of the three merge panes.
private enum MergeLineKind {
    case plain
    case ours
    case theirs
    case conflictUnresolved
    case conflictResolved
}

/// The merge panes' color scheme (kept in the view layer like `DiffColors`/
/// `SyntaxTheme`, so `PisakaCore` stays color-free).
private enum MergeColors {
    static func background(for kind: MergeLineKind) -> NSColor? {
        switch kind {
        case .plain: return nil
        case .ours: return ours
        case .theirs: return theirs
        case .conflictUnresolved: return unresolved
        case .conflictResolved: return resolved
        }
    }

    private static let ours = NSColor.systemBlue.withAlphaComponent(0.13)
    private static let theirs = NSColor.systemGreen.withAlphaComponent(0.13)
    private static let unresolved = NSColor.systemRed.withAlphaComponent(0.16)
    private static let resolved = NSColor.systemGreen.withAlphaComponent(0.10)
}

/// The three TextKit-1 panes, mirroring `DiffView`'s setup (non-wrapping,
/// monospaced, one logical line per visual row). `ours`/`theirs` are read-only;
/// `result` is editable and feeds per-conflict edits back into the model as
/// `.custom`. Vertical scroll is mirrored across the three panes.
private struct MergeThreePaneView: NSViewRepresentable {
    @ObservedObject var model: MergeModel
    @Binding var currentConflict: Int

    /// The shared editor font size (points). A change re-applies all three panes'
    /// font in `updateNSView`.
    var fontSize: Double = Double(NSFont.systemFontSize)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MergeContainerView {
        let coordinator = context.coordinator

        let (oursScroll, oursText) = Self.makePane(editable: false, fontSize: fontSize)
        let (resultScroll, resultText) = Self.makePane(editable: true, fontSize: fontSize)
        let (theirsScroll, theirsText) = Self.makePane(editable: false, fontSize: fontSize)

        coordinator.attach(
            oursScroll: oursScroll, oursText: oursText,
            resultScroll: resultScroll, resultText: resultText,
            theirsScroll: theirsScroll, theirsText: theirsText,
            model: model
        )

        let container = MergeContainerView(
            scrolls: [oursScroll, resultScroll, theirsScroll]
        )
        coordinator.appliedFontSize = CGFloat(fontSize)
        coordinator.update(currentConflict: currentConflict)
        return container
    }

    func updateNSView(_ nsView: MergeContainerView, context: Context) {
        context.coordinator.model = model
        // Re-apply the shared font to all three panes when its size changed. The
        // font is uniform across the panes, so rows stay aligned. Setting `.font`
        // re-styles each pane's whole buffer; the highlight tints survive.
        let desiredFontSize = CGFloat(fontSize)
        if context.coordinator.appliedFontSize != desiredFontSize {
            context.coordinator.appliedFontSize = desiredFontSize
            let font = NSFont.monospacedSystemFont(ofSize: desiredFontSize, weight: .regular)
            context.coordinator.oursText?.font = font
            context.coordinator.resultText?.font = font
            context.coordinator.theirsText?.font = font
        }
        context.coordinator.update(currentConflict: currentConflict)
    }

    static func dismantleNSView(_ nsView: MergeContainerView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    /// One non-wrapping TextKit-1 pane, mirroring `DiffView.makePane`.
    private static func makePane(
        editable: Bool,
        fontSize: Double
    ) -> (NSScrollView, MergePaneTextView) {
        let textView = MergePaneTextView(usingTextLayoutManager: false)

        // `CodeScrollView` so the pane's empty region — below the last line, right
        // of the longest one — is still the code zone (see `ZoomSurface`).
        let scrollView = CodeScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = textView

        let maxSize = CGFloat.greatestFiniteMagnitude
        textView.minSize = .zero
        textView.maxSize = NSSize(width: maxSize, height: maxSize)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = NSSize(width: maxSize, height: maxSize)
        textView.layoutManager?.allowsNonContiguousLayout = true

        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = editable
        textView.font = .monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)

        return (scrollView, textView)
    }

    /// A contiguous span of the result text and which conflict (if any) produced it.
    struct ResultSpan {
        let conflictIndex: Int?
        var range: NSRange
    }

    @MainActor
    final class Coordinator: NSObject {
        var model: MergeModel?

        weak var oursScroll: NSScrollView?
        weak var resultScroll: NSScrollView?
        weak var theirsScroll: NSScrollView?
        weak var oursText: MergePaneTextView?
        weak var resultText: MergePaneTextView?
        weak var theirsText: MergePaneTextView?

        private var didBuildSides = false
        private var lastScrolledConflict = -1
        private var resultSpans: [ResultSpan] = []

        /// The font size currently applied to the three panes, so `updateNSView`
        /// re-applies the font only on a real change.
        var appliedFontSize: CGFloat?

        /// True while we replace the result text programmatically, so the
        /// text-storage edit observer ignores our own change.
        private var isProgrammaticallySettingResult = false
        /// Guards the scroll-sync feedback loop (mirroring A→others must not bounce).
        private var isSyncingScroll = false

        func attach(
            oursScroll: NSScrollView, oursText: MergePaneTextView,
            resultScroll: NSScrollView, resultText: MergePaneTextView,
            theirsScroll: NSScrollView, theirsText: MergePaneTextView,
            model: MergeModel
        ) {
            self.oursScroll = oursScroll
            self.oursText = oursText
            self.resultScroll = resultScroll
            self.resultText = resultText
            self.theirsScroll = theirsScroll
            self.theirsText = theirsText
            self.model = model

            let center = NotificationCenter.default
            for clip in [oursScroll.contentView, resultScroll.contentView, theirsScroll.contentView] {
                clip.postsBoundsChangedNotifications = true
                center.addObserver(
                    self,
                    selector: #selector(clipBoundsChanged(_:)),
                    name: NSView.boundsDidChangeNotification,
                    object: clip
                )
            }
            // Observe the result storage's edits (carries the edited range, and
            // coexists with any storage delegate — the `LineNumberRulerView`
            // precedent) to feed conflict-region edits back as `.custom`.
            if let storage = resultText.textStorage {
                center.addObserver(
                    self,
                    selector: #selector(resultStorageDidProcess(_:)),
                    name: NSTextStorage.didProcessEditingNotification,
                    object: storage
                )
            }
        }

        /// Rebuild the side panes once, refresh the result pane when its content
        /// differs from the model (an accept action / first load — never our own
        /// in-place edit), and scroll to the current conflict when it changes.
        func update(currentConflict: Int) {
            guard let document = model?.document else { return }

            if !didBuildSides {
                buildSides(document)
                didBuildSides = true
            }

            let (text, kinds, spans) = Self.buildResult(document)
            if resultText?.string != text {
                isProgrammaticallySettingResult = true
                resultText?.setPaneText(text, kinds: kinds)
                isProgrammaticallySettingResult = false
                resultSpans = spans
            }

            if currentConflict != lastScrolledConflict {
                lastScrolledConflict = currentConflict
                scrollToConflict(currentConflict)
            }
        }

        // MARK: Pane content

        private func buildSides(_ document: MergeDocument) {
            var oursLines: [String] = []
            var oursKinds: [MergeLineKind] = []
            var theirsLines: [String] = []
            var theirsKinds: [MergeLineKind] = []

            for region in document.regions {
                switch region {
                case let .stable(lines):
                    oursLines.append(contentsOf: lines)
                    oursKinds.append(contentsOf: lines.map { _ in .plain })
                    theirsLines.append(contentsOf: lines)
                    theirsKinds.append(contentsOf: lines.map { _ in .plain })
                case let .conflict(hunk):
                    oursLines.append(contentsOf: hunk.ours)
                    oursKinds.append(contentsOf: hunk.ours.map { _ in .ours })
                    theirsLines.append(contentsOf: hunk.theirs)
                    theirsKinds.append(contentsOf: hunk.theirs.map { _ in .theirs })
                }
            }

            oursText?.setPaneText(oursLines.joined(separator: "\n"), kinds: oursKinds)
            theirsText?.setPaneText(theirsLines.joined(separator: "\n"), kinds: theirsKinds)
        }

        /// Build the editable result text, its per-line highlight kinds, and the
        /// contiguous region spans (used to map an edit back to a conflict).
        ///
        /// The text is assembled by *flattening* every region's logical lines into
        /// one array and joining once with `\n` — exactly as `MergeDocument`
        /// `resolvedText` does — so the pane's bytes match what `apply()` writes.
        /// (Joining per-region pieces would emit a phantom blank line for a region
        /// that contributes zero lines, e.g. a modify/delete resolved to the empty
        /// side.)
        private static func buildResult(_ document: MergeDocument) -> (String, [MergeLineKind], [ResultSpan]) {
            var allLines: [String] = []
            var kinds: [MergeLineKind] = []
            // (conflictIndex?, number of lines this region contributed), in order.
            var regions: [(conflictIndex: Int?, lineCount: Int)] = []
            var conflictIndex = 0

            for region in document.regions {
                switch region {
                case let .stable(lines):
                    allLines.append(contentsOf: lines)
                    kinds.append(contentsOf: lines.map { _ in .plain })
                    regions.append((nil, lines.count))
                case let .conflict(hunk):
                    let resolution = document.resolution(at: conflictIndex)
                    let lines = resolvedLines(for: hunk, resolution: resolution)
                    allLines.append(contentsOf: lines)
                    let kind: MergeLineKind = resolution == .unresolved ? .conflictUnresolved : .conflictResolved
                    kinds.append(contentsOf: lines.map { _ in kind })
                    regions.append((conflictIndex, lines.count))
                    conflictIndex += 1
                }
            }

            let text = allLines.joined(separator: "\n")

            // UTF-16 start offset of each flattened line in `text` (lines are
            // joined by a single "\n").
            var lineStarts: [Int] = []
            var offset = 0
            for line in allLines {
                lineStarts.append(offset)
                offset += (line as NSString).length + 1 // +1 for the joining "\n"
            }
            let textLength = (text as NSString).length

            var spans: [ResultSpan] = []
            var cursor = 0
            for region in regions {
                let start = cursor < lineStarts.count ? lineStarts[cursor] : textLength
                let length: Int
                if region.lineCount == 0 {
                    length = 0 // a region contributing no lines (e.g. accepted deletion)
                } else {
                    let lastLine = cursor + region.lineCount - 1
                    let lastEnd = lineStarts[lastLine] + (allLines[lastLine] as NSString).length
                    length = lastEnd - start
                }
                spans.append(ResultSpan(conflictIndex: region.conflictIndex, range: NSRange(location: start, length: length)))
                cursor += region.lineCount
            }
            return (text, kinds, spans)
        }

        /// The logical lines a conflict contributes for a given resolution. Reuses
        /// `MergeDocument.resolvedLines` (the single source of the marker text and
        /// ordering) so the result pane can never drift from `resolvedText`, and
        /// overrides only `.custom`: it splits on the same `\n` the editable pane
        /// inserts, so the round-trip (split → join by "\n") reproduces the typed
        /// text verbatim and the rebuild-vs-skip comparison in `update` is stable.
        private static func resolvedLines(for hunk: ConflictHunk, resolution: Resolution) -> [String] {
            if case let .custom(text) = resolution {
                return text.components(separatedBy: "\n")
            }
            return MergeDocument.resolvedLines(for: hunk, resolution: resolution)
        }

        private func scrollToConflict(_ index: Int) {
            guard
                let resultText,
                let span = resultSpans.first(where: { $0.conflictIndex == index })
            else { return }
            let length = resultText.string as NSString
            let safe = NSRange(
                location: min(span.range.location, length.length),
                length: min(span.range.length, max(0, length.length - min(span.range.location, length.length)))
            )
            resultText.scrollRangeToVisible(safe)
        }

        // MARK: Editing feedback

        @objc private func resultStorageDidProcess(_ notification: Notification) {
            guard
                !isProgrammaticallySettingResult,
                let storage = resultText?.textStorage,
                storage.editedMask.contains(.editedCharacters)
            else { return }
            commitEdit(editedRange: storage.editedRange, delta: storage.changeInLength)
        }

        /// Shift the cached spans by the edit, and — when the edit fell inside a
        /// conflict region — push that region's new text back to the model as
        /// `.custom`. An edit in a stable region only shifts ranges (it is not
        /// persisted, since `resolvedText` emits stable regions verbatim).
        private func commitEdit(editedRange: NSRange, delta: Int) {
            guard let model, let resultText else { return }
            resultText.refreshLineCache()
            let editStart = editedRange.location
            var containing: Int?

            for i in resultSpans.indices {
                var range = resultSpans[i].range
                if containing != nil || range.location > editStart {
                    // Already past the containing span (spans are ordered, so
                    // every later span starts at or after the edit), or strictly
                    // after the edit — shift. The `containing != nil` arm stops a
                    // *later* span that shares the edit offset from also growing:
                    // a zero-length conflict region (one resolved to its empty
                    // side) is coincident with the following region's start, and
                    // without this both would grow and the later one would steal
                    // `containing` — dropping the edit (a following stable region
                    // has no conflict index) or misattributing it. Using `>` (not
                    // `>=`) for the first match keeps a span that begins *exactly*
                    // at the edit offset (typing at the very start of a conflict
                    // region) growing below instead of being pushed right.
                    range.location += delta
                    resultSpans[i].range = range
                } else if range.location + range.length >= editStart {
                    range.length = max(0, range.length + delta)
                    resultSpans[i].range = range
                    containing = i
                }
                // else: span entirely before the edit — unchanged.
            }

            guard
                let ci = containing,
                let conflictIndex = resultSpans[ci].conflictIndex
            else { return }

            let ns = resultText.string as NSString
            let range = resultSpans[ci].range
            let safeLocation = min(max(0, range.location), ns.length)
            let safeLength = min(max(0, range.length), ns.length - safeLocation)
            let text = ns.substring(with: NSRange(location: safeLocation, length: safeLength))
            model.accept(.custom(text), at: conflictIndex)
        }

        // MARK: Scroll sync

        @objc private func clipBoundsChanged(_ notification: Notification) {
            guard !isSyncingScroll, let source = notification.object as? NSClipView else { return }
            let scrolls = [oursScroll, resultScroll, theirsScroll].compactMap { $0 }
            let y = source.bounds.origin.y
            isSyncingScroll = true
            for scroll in scrolls where scroll.contentView !== source {
                let clip = scroll.contentView
                guard abs(clip.bounds.origin.y - y) > 0.5 else { continue }
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                scroll.reflectScrolledClipView(clip)
            }
            isSyncingScroll = false
        }

        func teardown() {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

/// A merge pane: an `NSTextView` that paints a full-width per-line background by
/// `MergeLineKind` behind the glyphs (mirroring `DiffTextView`).
@MainActor
private final class MergePaneTextView: NSTextView, ZoomSurfaceProviding {
    fileprivate var lineKinds: [MergeLineKind] = []
    private(set) var lineStartOffsets: [Int] = [0]

    /// A merge pane draws with the shared editor font, so it is a *code* surface
    /// like the diff panes: a zoom gesture over any of the three grows the code
    /// zone. The Command-held `scrollWheel` override this replaced is gone — the
    /// app's single event monitor now sees the gesture first, so it can no longer
    /// race the synced vertical scrolling.
    let zoomSurfaceKind: ZoomSurfaceKind = .code

    func setPaneText(_ text: String, kinds: [MergeLineKind]) {
        string = text
        lineKinds = kinds
        lineStartOffsets = LineStartIndex.offsets(in: string as NSString)
        needsDisplay = true
    }

    /// Re-derive the line-start cache after an in-place (user) edit so background
    /// painting still maps glyph → line correctly. The kinds may lag the edited
    /// region until the next rebuild, which is harmless (only the highlight tint).
    func refreshLineCache() {
        lineStartOffsets = LineStartIndex.offsets(in: string as NSString)
        needsDisplay = true
    }

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
            !lineKinds.isEmpty
        else { return }

        let origin = textContainerOrigin
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
                row < self.lineKinds.count,
                let color = MergeColors.background(for: self.lineKinds[row])
            else { return }
            let fill = NSRect(
                x: 0,
                y: fragmentRect.minY + origin.y,
                width: self.bounds.width,
                height: fragmentRect.height
            )
            color.setFill()
            fill.fill()
        }
    }
}

/// Lays out the three merge panes side by side, split evenly with hairline
/// dividers (mirroring `DiffContainerView` for three columns).
@MainActor
final class MergeContainerView: NSView {
    private let scrolls: [NSScrollView]
    private let dividers: [NSBox]

    init(scrolls: [NSScrollView]) {
        self.scrolls = scrolls
        self.dividers = (0..<max(0, scrolls.count - 1)).map { _ in
            let box = NSBox()
            box.boxType = .separator
            return box
        }
        super.init(frame: .zero)
        for scroll in scrolls { addSubview(scroll) }
        for divider in dividers { addSubview(divider) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let count = scrolls.count
        guard count > 0 else { return }
        let height = bounds.height
        let dividerWidth: CGFloat = 1
        let totalDividers = dividerWidth * CGFloat(dividers.count)
        let paneWidth = max(0, (bounds.width - totalDividers) / CGFloat(count))

        var x: CGFloat = 0
        for (index, scroll) in scrolls.enumerated() {
            scroll.frame = NSRect(x: x, y: 0, width: paneWidth, height: height)
            x += paneWidth
            if index < dividers.count {
                dividers[index].frame = NSRect(x: x, y: 0, width: dividerWidth, height: height)
                x += dividerWidth
            }
        }
    }
}

#endif
