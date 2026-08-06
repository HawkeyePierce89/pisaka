#if os(iOS)
import SwiftUI
import UIKit
import Neon
import PisakaCore

/// A side-by-side diff of a changed file — the UIKit peer of the macOS `DiffView`.
/// `HEAD` on the left, the working copy on the right, rendered from a pre-computed
/// `[DiffRow]` (built in `PisakaCore` by `LineDiff`, so all the off-by-one
/// line/alignment math is unit-tested there).
///
/// Two read-only `UITextView`s sit side by side. Each row maps to exactly one
/// visual line in *both* panes — a `nil` side becomes an empty filler line — so the
/// two panes stay vertically aligned line-for-line. Each `DiffTextView_iOS` paints a
/// per-row background by `DiffRowKind` (removed/changed → red on the left,
/// added/changed → green on the right, filler → a neutral "absent" tint) behind the
/// glyphs and draws that side's 1-based line numbers in a reserved left gutter
/// (blank for a filler line). Vertical scrolling is mirrored between the panes, and
/// both panes get the same Neon tree-sitter highlighting the editor uses
/// (`SyntaxLanguageConfiguration` + `SyntaxTheme`).
///
/// The view holds no domain logic: it renders the rows it is handed and re-renders
/// when `fileID` or the rows change.
struct DiffView_iOS: UIViewRepresentable {
    /// Identity of the changed file being diffed; a change means a different file,
    /// so the panes are rebuilt wholesale.
    let fileID: String

    /// The changed file's name (its last path component). Its extension selects the
    /// syntax language for both panes; an unknown extension shows plain text.
    let fileName: String

    /// The aligned side-by-side rows to render (old/`HEAD` vs new/working copy).
    let rows: [DiffRow]

    /// The shared editor font size (points). Owned by `SettingsStore`; a change
    /// re-applies the panes' font in `updateUIView`.
    let fontSize: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> DiffContainerView_iOS {
        let coordinator = context.coordinator
        let left = makePane(side: .left)
        let right = makePane(side: .right)
        coordinator.attach(left: left, right: right)

        let container = DiffContainerView_iOS(left: left, right: right)
        coordinator.appliedFontSize = CGFloat(fontSize)
        coordinator.fileID = fileID
        coordinator.loadContent(rows: rows, fileName: fileName)
        return container
    }

    func updateUIView(_ container: DiffContainerView_iOS, context: Context) {
        let coordinator = context.coordinator

        let desiredFontSize = CGFloat(fontSize)
        if coordinator.appliedFontSize != desiredFontSize {
            coordinator.appliedFontSize = desiredFontSize
            let font = UIFont.monospacedSystemFont(ofSize: desiredFontSize, weight: .regular)
            coordinator.left?.font = font
            coordinator.right?.font = font
            coordinator.left?.setNeedsLayout()
            coordinator.right?.setNeedsLayout()
        }

        let fileChanged = coordinator.fileID != fileID
        if fileChanged || coordinator.rows != rows {
            coordinator.fileID = fileID
            coordinator.loadContent(rows: rows, fileName: fileName)
        }
    }

    static func dismantleUIView(_ uiView: DiffContainerView_iOS, coordinator: Coordinator) {
        coordinator.teardown()
    }

    /// Build one read-only, non-wrapping diff pane (so a logical line occupies
    /// exactly one visual row — the row-to-line alignment the diff depends on),
    /// mirroring `CodeEditorView_iOS`'s TextKit 1 setup.
    private func makePane(side: DiffTextView_iOS.Side) -> DiffTextView_iOS {
        let textView = DiffTextView_iOS(usingTextLayoutManager: false)
        textView.side = side
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        textView.alwaysBounceVertical = true
        textView.textContainer.lineBreakMode = .byClipping
        textView.textContainer.widthTracksTextView = false
        textView.textContainer.size = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        return textView
    }

    /// Owns the two panes, mirrors their vertical scroll, and holds each pane's Neon
    /// highlighter for the lifetime of the shown diff.
    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var fileID: String?
        var rows: [DiffRow] = []
        var appliedFontSize: CGFloat?

        weak var left: DiffTextView_iOS?
        weak var right: DiffTextView_iOS?

        // Highlighters install themselves as their text storage's delegate; held
        // strongly so they live as long as the diff is shown.
        private var leftHighlighter: TextViewHighlighter?
        private var rightHighlighter: TextViewHighlighter?

        /// Guards against the scroll-sync feedback loop (mirroring A→B must not
        /// bounce B→A).
        private var isSyncingScroll = false

        func attach(left: DiffTextView_iOS, right: DiffTextView_iOS) {
            self.left = left
            self.right = right
            left.delegate = self
            right.delegate = self
        }

        /// One pane scrolled: mirror its vertical offset to the other so the two
        /// stay aligned. Horizontal scrolling is left independent.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isSyncingScroll else { return }
            let other: DiffTextView_iOS?
            if scrollView === left {
                other = right
            } else if scrollView === right {
                other = left
            } else {
                other = nil
            }
            guard let otherScroll = other else { return }
            let y = scrollView.contentOffset.y
            guard abs(otherScroll.contentOffset.y - y) > 0.5 else { return }
            isSyncingScroll = true
            otherScroll.contentOffset.y = y
            isSyncingScroll = false
        }

        /// Replace both panes' contents from `rows`, rebuild the highlighters for the
        /// file's language.
        func loadContent(rows: [DiffRow], fileName: String) {
            self.rows = rows
            let leftBody = rows.map { $0.left?.text ?? "" }.joined(separator: "\n")
            let rightBody = rows.map { $0.right?.text ?? "" }.joined(separator: "\n")

            // Detach the outgoing highlighters before swapping the buffers so a stale
            // grammar can't asynchronously repaint the incoming file (the same
            // cross-language race `CodeEditorView_iOS` guards against).
            detachHighlighters()

            left?.setDiffContent(rows: rows, text: leftBody)
            right?.setDiffContent(rows: rows, text: rightBody)

            let language = SyntaxLanguage(forFileName: fileName)
            if let left { leftHighlighter = makeHighlighter(for: left, language: language) }
            if let right { rightHighlighter = makeHighlighter(for: right, language: language) }
        }

        private func detachHighlighters() {
            leftHighlighter = nil
            left?.textStorage.delegate = nil
            rightHighlighter = nil
            right?.textStorage.delegate = nil
        }

        /// Build a Neon highlighter mapping each tree-sitter capture through
        /// `SyntaxTokenKind` to a `SyntaxTheme` color, exactly like the editor.
        /// Returns `nil` for plain text / a grammar that fails to load.
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

        func teardown() {
            detachHighlighters()
        }
    }
}

/// A read-only diff pane. Beyond an ordinary `UITextView` it paints a per-row
/// background by `DiffRowKind` and draws this side's 1-based line numbers in a
/// reserved left gutter — both rendered by a `DiffBackgroundView_iOS` inserted
/// *behind* the text-rendering subview (so it scrolls with the content and sits
/// under the glyphs and Neon's syntax colors).
@MainActor
final class DiffTextView_iOS: UITextView {
    /// Which side of the diff this pane shows.
    enum Side { case left, right }

    var side: Side = .left {
        didSet { background?.side = side }
    }

    /// Width of the reserved left gutter where line numbers are drawn.
    static let gutterWidth: CGFloat = 44

    /// The rows backing this pane, used to pick each line's background color and
    /// line number.
    private(set) var diffRows: [DiffRow] = []

    /// UTF-16 start offset of every line, so a glyph's character index maps to its
    /// row index in O(log n). Rebuilt whenever the text is replaced (via Core's
    /// `LineStartIndex`, matching the editor's line semantics).
    private(set) var lineStartOffsets: [Int] = [0]

    /// The view drawing per-row backgrounds + line numbers, kept behind the text.
    private var background: DiffBackgroundView_iOS?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func commonInit() {
        // Reserve space on the left for the line-number gutter.
        textContainerInset.left += Self.gutterWidth
        let bg = DiffBackgroundView_iOS(textView: self)
        bg.side = side
        bg.isUserInteractionEnabled = false
        bg.backgroundColor = .clear
        insertSubview(bg, at: 0)
        background = bg
    }

    /// Replace the pane's text + rows and rebuild the line-start cache.
    func setDiffContent(rows: [DiffRow], text: String) {
        diffRows = rows
        self.text = text
        lineStartOffsets = LineStartIndex.offsets(in: text as NSString)
        setNeedsLayout()
    }

    /// 0-based index of the line containing `charIndex` (count of line starts
    /// `<= charIndex`, minus one). Mirrors the macOS pane's binary search.
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

    override func layoutSubviews() {
        super.layoutSubviews()
        // Size the background to the full content (so it scrolls with the text and
        // never needs a per-scroll redraw) and refresh it.
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

/// Draws the per-row backgrounds and the line-number gutter for a diff pane. Sized
/// to the pane's full content and inserted behind the text-rendering subview, so it
/// scrolls with the content and sits under the glyphs.
@MainActor
final class DiffBackgroundView_iOS: UIView {
    private weak var textView: DiffTextView_iOS?
    var side: DiffTextView_iOS.Side = .left

    init(textView: DiffTextView_iOS) {
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
            !textView.diffRows.isEmpty
        else { return }
        let textContainer = textView.textContainer
        let inset = textView.textContainerInset
        let gutterRight = DiffTextView_iOS.gutterWidth - 4

        let numberFont = UIFont.monospacedDigitSystemFont(
            ofSize: max((textView.font?.pointSize ?? UIFont.systemFontSize) - 2, UIFont.smallSystemFontSize),
            weight: .regular
        )
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: UIColor.secondaryLabel,
        ]

        let glyphRange = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, lineGlyphRange, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: lineGlyphRange.location)
            let rowIndex = textView.lineIndex(forCharacterAt: charIndex)
            guard rowIndex < textView.diffRows.count else { return }
            let row = textView.diffRows[rowIndex]
            let y = fragmentRect.minY + inset.top

            // Full-width per-row background.
            if let color = DiffColors_iOS.background(for: row, side: self.side) {
                color.setFill()
                UIRectFill(CGRect(x: 0, y: y, width: self.bounds.width, height: fragmentRect.height))
            }

            // Change marker strip at the gutter's inner edge.
            if let markerColor = DiffColors_iOS.markerColor(for: row, side: self.side) {
                markerColor.setFill()
                UIRectFill(CGRect(
                    x: DiffTextView_iOS.gutterWidth - 2,
                    y: y,
                    width: 2,
                    height: fragmentRect.height
                ))
            }

            // Line number for this side (filler lines have none).
            guard let line = (self.side == .left ? row.left : row.right) else { return }
            let label = "\(line.number)" as NSString
            let labelSize = label.size(withAttributes: numberAttributes)
            let labelX = gutterRight - labelSize.width
            let labelY = y + (fragmentRect.height - labelSize.height) / 2
            label.draw(at: CGPoint(x: labelX, y: labelY), withAttributes: numberAttributes)
        }
    }
}

/// Lays out the two diff panes side by side, split evenly with a hairline divider —
/// the UIKit peer of `DiffContainerView`.
@MainActor
final class DiffContainerView_iOS: UIView {
    private let left: DiffTextView_iOS
    private let right: DiffTextView_iOS
    private let divider = UIView()

    init(left: DiffTextView_iOS, right: DiffTextView_iOS) {
        self.left = left
        self.right = right
        super.init(frame: .zero)
        divider.backgroundColor = .separator
        addSubview(left)
        addSubview(divider)
        addSubview(right)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let dividerWidth: CGFloat = 1
        let paneWidth = max(0, (bounds.width - dividerWidth) / 2)
        left.frame = CGRect(x: 0, y: 0, width: paneWidth, height: bounds.height)
        divider.frame = CGRect(x: paneWidth, y: 0, width: dividerWidth, height: bounds.height)
        right.frame = CGRect(x: paneWidth + dividerWidth, y: 0, width: bounds.width - paneWidth - dividerWidth, height: bounds.height)
    }
}

/// The diff's color scheme on iOS — a full-width row background and a gutter change
/// marker per `DiffRow`/side. Kept in the view layer (like `SyntaxTheme`) so
/// `PisakaCore` stays color-free, mirroring the macOS `DiffColors` tones (removed/
/// changed read red on the old side, added/changed read green on the new side, a
/// filler/absent line reads a neutral gray).
enum DiffColors_iOS {
    static func background(for row: DiffRow, side: DiffTextView_iOS.Side) -> UIColor? {
        switch side {
        case .left:
            switch row.kind {
            case .unchanged: return nil
            case .removed, .modified: return removed
            case .added: return filler
            }
        case .right:
            switch row.kind {
            case .unchanged: return nil
            case .added, .modified: return added
            case .removed: return filler
            }
        }
    }

    static func markerColor(for row: DiffRow, side: DiffTextView_iOS.Side) -> UIColor? {
        switch side {
        case .left:
            switch row.kind {
            case .unchanged, .added: return nil
            case .removed, .modified: return .systemRed
            }
        case .right:
            switch row.kind {
            case .unchanged, .removed: return nil
            case .added, .modified: return .systemGreen
            }
        }
    }

    private static let removed = UIColor.systemRed.withAlphaComponent(0.15)
    private static let added = UIColor.systemGreen.withAlphaComponent(0.15)
    private static let filler = UIColor.gray.withAlphaComponent(0.12)
}
#endif
