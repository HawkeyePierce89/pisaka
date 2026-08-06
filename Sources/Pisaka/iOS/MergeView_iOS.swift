#if os(iOS)
import SwiftUI
import UIKit
import Neon
import PisakaCore

/// The iOS 3-pane conflict-resolution editor — the UIKit/SwiftUI peer of the macOS
/// `MergeView`. `ours | result | theirs`: the left/right panes are read-only views
/// of each side's full content (stable regions plus that side's version of every
/// conflict hunk); the middle pane is the live, *editable* merged result built from
/// `MergeDocument.resolvedText` (an unresolved conflict shows git-style markers).
/// Conflict regions are highlighted in all three panes.
///
/// Adaptive layout: on a regular width (iPad) the three panes sit side by side; on a
/// compact width (iPhone) they stack vertically (Ours / Result / Theirs), each
/// independently scrollable. A control bar drives per-conflict resolution
/// (◀ Ours / both orderings / Theirs ▶) and prev/next navigation; the route's
/// "Apply" button (gated on `MergeModel.isFullyResolved`) commits the resolution.
///
/// All domain logic lives in `PisakaCore` (`ThreeWayMerge`, `MergeDocument`,
/// `MergeModel`); this is a thin, intentionally untested view layer — the same split
/// as `DiffView_iOS`/`CodeEditorView_iOS`. Editing the result pane within a conflict
/// region feeds that region's text back into the model as `.custom`.
struct MergeView_iOS: View {
    @ObservedObject var model: MergeModel

    /// Shared user preferences, observed so the panes' font tracks the editor font
    /// size.
    @ObservedObject var settings: SettingsStore

    /// The conflict the control bar's accept buttons act on and that prev/next
    /// navigates between (conflict order). Owned by the route so the toolbar there
    /// can read it; clamped to the document's conflicts.
    @Binding var currentConflict: Int

    /// Whether the horizontal size class is compact (iPhone) — picks the stacked vs
    /// side-by-side pane layout.
    let isCompact: Bool

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            content
            if let message = model.errorMessage, model.document != nil {
                Divider()
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Control bar

    @ViewBuilder
    private var controlBar: some View {
        if let document = model.document, document.conflictCount > 0 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button { navigate(-1) } label: { Image(systemName: "chevron.up") }
                        .disabled(currentConflict <= 0)
                    Text("Conflict \(min(currentConflict + 1, document.conflictCount)) of \(document.conflictCount)")
                        .font(.callout.monospacedDigit())
                        .fixedSize()
                    Button { navigate(1) } label: { Image(systemName: "chevron.down") }
                        .disabled(currentConflict >= document.conflictCount - 1)

                    Divider().frame(height: 16)

                    Button("◀ Ours") { accept(.ours) }
                    Button("Ours+Theirs") { accept(.bothOursFirst) }
                    Button("Theirs+Ours") { accept(.bothTheirsFirst) }
                    Button("Theirs ▶") { accept(.theirs) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        } else {
            HStack {
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private var statusText: String {
        guard model.document != nil else { return "" }
        if model.isFullyResolved { return "All conflicts resolved" }
        let count = model.unresolvedCount
        return "\(count) unresolved conflict\(count == 1 ? "" : "s")"
    }

    // MARK: - Panes

    @ViewBuilder
    private var content: some View {
        if model.document != nil {
            if isCompact {
                VStack(spacing: 0) {
                    labeledPane("Ours", role: .ours)
                    Divider()
                    labeledPane("Result", role: .result)
                    Divider()
                    labeledPane("Theirs", role: .theirs)
                }
            } else {
                HStack(spacing: 0) {
                    labeledPane("Ours", role: .ours)
                    Divider()
                    labeledPane("Result", role: .result)
                    Divider()
                    labeledPane("Theirs", role: .theirs)
                }
            }
        } else {
            Text(model.errorMessage ?? "Loading…")
                .foregroundStyle(model.errorMessage == nil ? Color.secondary : Color.red)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func labeledPane(_ title: String, role: MergePaneRole) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
            MergePaneView_iOS(
                role: role,
                model: model,
                fileName: (model.file?.path as NSString?)?.lastPathComponent ?? "",
                fontSize: settings.fontSize
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

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

/// Which of the three merge panes a `MergePaneView_iOS` renders.
enum MergePaneRole { case ours, result, theirs }

/// Background highlight for a line in one of the merge panes (view-layer, so Core
/// stays color-free — the `DiffColors_iOS`/`SyntaxTheme` precedent).
enum MergeLineKind_iOS {
    case plain
    case ours
    case theirs
    case conflictUnresolved
    case conflictResolved
}

/// The merge panes' color scheme, mirroring the macOS `MergeColors` tones.
enum MergeColors_iOS {
    static func background(for kind: MergeLineKind_iOS) -> UIColor? {
        switch kind {
        case .plain: return nil
        case .ours: return ours
        case .theirs: return theirs
        case .conflictUnresolved: return unresolved
        case .conflictResolved: return resolved
        }
    }

    private static let ours = UIColor.systemBlue.withAlphaComponent(0.13)
    private static let theirs = UIColor.systemGreen.withAlphaComponent(0.13)
    private static let unresolved = UIColor.systemRed.withAlphaComponent(0.16)
    private static let resolved = UIColor.systemGreen.withAlphaComponent(0.10)
}

/// Builds the per-pane line content + highlight kinds from a `MergeDocument`,
/// shared by the three `MergePaneView_iOS` roles (the iOS counterpart of the macOS
/// `MergeThreePaneView.Coordinator.buildSides`/`buildResult`).
enum MergePaneContent {
    /// A contiguous span of the result text and which conflict (if any) produced it.
    struct ResultSpan {
        let conflictIndex: Int?
        var range: NSRange
    }

    /// One side pane's flattened lines + per-line highlight kinds.
    static func side(_ document: MergeDocument, role: MergePaneRole) -> (text: String, kinds: [MergeLineKind_iOS]) {
        var lines: [String] = []
        var kinds: [MergeLineKind_iOS] = []
        for region in document.regions {
            switch region {
            case let .stable(stableLines):
                lines.append(contentsOf: stableLines)
                kinds.append(contentsOf: stableLines.map { _ in .plain })
            case let .conflict(hunk):
                let sideLines = role == .ours ? hunk.ours : hunk.theirs
                let kind: MergeLineKind_iOS = role == .ours ? .ours : .theirs
                lines.append(contentsOf: sideLines)
                kinds.append(contentsOf: sideLines.map { _ in kind })
            }
        }
        return (lines.joined(separator: "\n"), kinds)
    }

    /// The editable result text, its per-line highlight kinds, and the contiguous
    /// region spans (used to map an edit back to a conflict). Flattens every
    /// region's logical lines and joins once with `\n` — exactly as
    /// `MergeDocument.resolvedText` does — so the pane's bytes match what `apply()`
    /// writes.
    static func result(_ document: MergeDocument) -> (text: String, kinds: [MergeLineKind_iOS], spans: [ResultSpan]) {
        var allLines: [String] = []
        var kinds: [MergeLineKind_iOS] = []
        var regions: [(conflictIndex: Int?, lineCount: Int)] = []
        var conflictIndex = 0

        for region in document.regions {
            switch region {
            case let .stable(stableLines):
                allLines.append(contentsOf: stableLines)
                kinds.append(contentsOf: stableLines.map { _ in .plain })
                regions.append((nil, stableLines.count))
            case let .conflict(hunk):
                let resolution = document.resolution(at: conflictIndex)
                let lines = resolvedLines(for: hunk, resolution: resolution)
                allLines.append(contentsOf: lines)
                let kind: MergeLineKind_iOS = resolution == .unresolved ? .conflictUnresolved : .conflictResolved
                kinds.append(contentsOf: lines.map { _ in kind })
                regions.append((conflictIndex, lines.count))
                conflictIndex += 1
            }
        }

        let text = allLines.joined(separator: "\n")

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
                length = 0
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
    /// `MergeDocument.resolvedLines` (the single source of marker text + ordering)
    /// so the result pane can never drift from `resolvedText`, overriding only
    /// `.custom` — split on the same `\n` the editable pane inserts.
    static func resolvedLines(for hunk: ConflictHunk, resolution: Resolution) -> [String] {
        if case let .custom(text) = resolution {
            return text.components(separatedBy: "\n")
        }
        return MergeDocument.resolvedLines(for: hunk, resolution: resolution)
    }
}

/// One merge pane: a non-wrapping TextKit-1 `UITextView` painting per-line
/// backgrounds by `MergeLineKind_iOS`. `ours`/`theirs` are read-only; `result` is
/// editable and feeds per-conflict edits back into the model as `.custom`.
struct MergePaneView_iOS: UIViewRepresentable {
    let role: MergePaneRole
    @ObservedObject var model: MergeModel
    let fileName: String
    let fontSize: Double

    func makeCoordinator() -> Coordinator { Coordinator(role: role, model: model) }

    func makeUIView(context: Context) -> MergePaneTextView_iOS {
        let textView = MergePaneTextView_iOS(usingTextLayoutManager: false)
        textView.isEditable = role == .result
        textView.isSelectable = true
        textView.allowsEditingTextAttributes = false
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.spellCheckingType = .no
        textView.font = .monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        textView.alwaysBounceVertical = true
        textView.textContainer.lineBreakMode = .byClipping
        textView.textContainer.widthTracksTextView = false
        textView.textContainer.size = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.delegate = context.coordinator
        context.coordinator.attach(textView: textView, fileName: fileName)
        context.coordinator.appliedFontSize = CGFloat(fontSize)
        context.coordinator.refresh()
        return textView
    }

    func updateUIView(_ textView: MergePaneTextView_iOS, context: Context) {
        context.coordinator.model = model
        let desiredFontSize = CGFloat(fontSize)
        if context.coordinator.appliedFontSize != desiredFontSize {
            context.coordinator.appliedFontSize = desiredFontSize
            textView.font = .monospacedSystemFont(ofSize: desiredFontSize, weight: .regular)
        }
        context.coordinator.fileName = fileName
        context.coordinator.refresh()
    }

    static func dismantleUIView(_ textView: MergePaneTextView_iOS, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        let role: MergePaneRole
        var model: MergeModel
        var fileName: String = ""
        var appliedFontSize: CGFloat?

        private weak var textView: MergePaneTextView_iOS?
        private var highlighter: TextViewHighlighter?
        private var resultSpans: [MergePaneContent.ResultSpan] = []
        /// True while we set the text programmatically, so the edit observer ignores
        /// our own change.
        private var isProgrammaticallySetting = false
        /// The most recent user edit captured in `shouldChangeText` (UTF-16 start of
        /// the replaced range + the net length change), applied in `didChange`.
        private var pendingEdit: (editStart: Int, delta: Int)?

        init(role: MergePaneRole, model: MergeModel) {
            self.role = role
            self.model = model
        }

        func attach(textView: MergePaneTextView_iOS, fileName: String) {
            self.textView = textView
            self.fileName = fileName
        }

        /// Rebuild the pane's content from the model's document when it differs from
        /// what is shown (an accept action / first load / font change — never our own
        /// in-place edit of the result pane).
        func refresh() {
            guard let textView, let document = model.document else { return }
            let language = SyntaxLanguage(forFileName: fileName)

            switch role {
            case .ours, .theirs:
                let (text, kinds) = MergePaneContent.side(document, role: role)
                if textView.text != text {
                    setText(text, kinds: kinds, language: language)
                }
            case .result:
                let (text, kinds, spans) = MergePaneContent.result(document)
                if textView.text != text {
                    setText(text, kinds: kinds, language: language)
                    resultSpans = spans
                } else if resultSpans.isEmpty {
                    resultSpans = spans
                }
            }
        }

        private func setText(_ text: String, kinds: [MergeLineKind_iOS], language: SyntaxLanguage?) {
            guard let textView else { return }
            // Detach the outgoing highlighter before swapping the buffer so a stale
            // grammar can't asynchronously repaint the incoming content.
            highlighter = nil
            textView.textStorage.delegate = nil

            isProgrammaticallySetting = true
            textView.setPaneText(text, kinds: kinds)
            isProgrammaticallySetting = false

            highlighter = makeHighlighter(for: textView, language: language)
        }

        private func makeHighlighter(for textView: UITextView, language: SyntaxLanguage?) -> TextViewHighlighter? {
            guard
                let language,
                let languageConfiguration = SyntaxLanguageConfiguration.configuration(for: language)
            else { return nil }
            let theme = SyntaxTheme.shared
            let attributeProvider: TokenAttributeProvider = { token in
                [.foregroundColor: theme.color(for: SyntaxTokenKind(captureName: token.name))]
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

        // MARK: Editing feedback (result pane only)

        /// Capture the user's edit (the replaced range's UTF-16 start and the net
        /// length change) before the text view applies it, so `didChange` can shift
        /// the cached spans and attribute the edit to a conflict region — the iOS
        /// analogue of the macOS text-storage `editedRange`/`changeInLength`.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard role == .result, !isProgrammaticallySetting else { return true }
            let delta = (text as NSString).length - range.length
            pendingEdit = (editStart: range.location, delta: delta)
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            guard role == .result, !isProgrammaticallySetting,
                  let pane = textView as? MergePaneTextView_iOS,
                  let edit = pendingEdit else { return }
            pendingEdit = nil
            pane.refreshLineCache()
            commitEdit(pane: pane, editStart: edit.editStart, delta: edit.delta)
        }

        /// Shift the cached spans by the edit, and — when the edit fell inside a
        /// conflict region — push that region's new text back to the model as
        /// `.custom`. An edit in a stable region only shifts ranges (it is not
        /// persisted, since `resolvedText` emits stable regions verbatim). This
        /// mirrors the macOS `MergeThreePaneView.Coordinator.commitEdit`.
        private func commitEdit(pane: MergePaneTextView_iOS, editStart: Int, delta: Int) {
            var containing: Int?
            for i in resultSpans.indices {
                var range = resultSpans[i].range
                if containing != nil || range.location > editStart {
                    // Already past the containing span, or strictly after the edit —
                    // shift. The `containing != nil` arm stops a later span that shares
                    // the edit offset (a zero-length conflict coincident with the next
                    // region) from also growing. Using `>` keeps a span that begins
                    // exactly at the edit offset growing below, not pushed right.
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

            let ns = pane.text as NSString
            let range = resultSpans[ci].range
            let safeLocation = min(max(0, range.location), ns.length)
            let safeLength = min(max(0, range.length), ns.length - safeLocation)
            let text = ns.substring(with: NSRange(location: safeLocation, length: safeLength))
            model.accept(.custom(text), at: conflictIndex)
        }

        func teardown() {
            highlighter = nil
            textView?.textStorage.delegate = nil
        }
    }
}

/// A merge pane text view that paints a full-width per-line background by
/// `MergeLineKind_iOS` behind the glyphs, via a `MergeBackgroundView_iOS` inserted
/// behind the text (mirroring `DiffTextView_iOS`).
@MainActor
final class MergePaneTextView_iOS: UITextView {
    fileprivate var lineKinds: [MergeLineKind_iOS] = []
    private(set) var lineStartOffsets: [Int] = [0]
    private var background: MergeBackgroundView_iOS?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func commonInit() {
        let bg = MergeBackgroundView_iOS(textView: self)
        bg.isUserInteractionEnabled = false
        bg.backgroundColor = .clear
        insertSubview(bg, at: 0)
        background = bg
    }

    func setPaneText(_ text: String, kinds: [MergeLineKind_iOS]) {
        self.text = text
        lineKinds = kinds
        lineStartOffsets = LineStartIndex.offsets(in: text as NSString)
        setNeedsLayout()
    }

    /// Re-derive the line-start cache after an in-place (user) edit so background
    /// painting still maps glyph → line correctly. The kinds may lag the edited
    /// region until the next rebuild (only the highlight tint), which is harmless.
    func refreshLineCache() {
        lineStartOffsets = LineStartIndex.offsets(in: text as NSString)
        setNeedsLayout()
    }

    func lineIndex(forCharacterAt charIndex: Int) -> Int {
        var low = 0
        var high = lineStartOffsets.count
        while low < high {
            let mid = (low + high) / 2
            if lineStartOffsets[mid] <= charIndex { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bgFrame = CGRect(
            x: 0,
            y: 0,
            width: max(contentSize.width, bounds.width),
            height: max(contentSize.height, bounds.height)
        )
        if background?.frame != bgFrame {
            background?.frame = bgFrame
        }
        background?.setNeedsDisplay()
    }
}

/// Draws the per-row merge backgrounds for a pane. Sized to the pane's full content
/// and inserted behind the text-rendering subview (the `DiffBackgroundView_iOS`
/// pattern).
@MainActor
final class MergeBackgroundView_iOS: UIView {
    private weak var textView: MergePaneTextView_iOS?

    init(textView: MergePaneTextView_iOS) {
        self.textView = textView
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard
            let textView,
            let layoutManager = textView.layoutManager as NSLayoutManager?,
            !textView.lineKinds.isEmpty
        else { return }
        let textContainer = textView.textContainer
        let inset = textView.textContainerInset

        let glyphRange = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, lineGlyphRange, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: lineGlyphRange.location)
            let row = textView.lineIndex(forCharacterAt: charIndex)
            guard
                row < textView.lineKinds.count,
                let color = MergeColors_iOS.background(for: textView.lineKinds[row])
            else { return }
            color.setFill()
            UIRectFill(CGRect(
                x: 0,
                y: fragmentRect.minY + inset.top,
                width: self.bounds.width,
                height: fragmentRect.height
            ))
        }
    }
}
#endif
