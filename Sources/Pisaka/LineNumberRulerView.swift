#if os(macOS)
import AppKit
import PisakaCore

/// A vertical ruler that draws right-aligned line numbers in the gutter of an
/// `NSTextView` (TextKit 1).
///
/// It walks the layout manager's line fragments for the visible range, draws the
/// 1-based source-line number beside each fragment's first line, and redraws when
/// the editor scrolls, resizes, or its text changes. The numbers follow the
/// editor's monospaced font (at a slightly smaller size) and the system
/// appearance via `NSColor.secondaryLabelColor`, so it stays correct on
/// light/dark switches.
///
/// It also hosts the git-blame **annotation column**, drawn to the *left* of the
/// numbers inside the same ruler and in the same pass, with the same `rulerFont`
/// and `NSColor.secondaryLabelColor`. With annotate off the column contributes 0
/// to the thickness and the gutter is byte-identical to a build without the
/// feature.
///
/// It also hosts a narrow fixed-width **diagnostic severity marker** column,
/// between the blame column and the numbers: one dot per line that carries a
/// diagnostic, in `SyntaxTheme`'s severity color. Unlike the blame column its
/// width is *constant* whether or not anything is ever reported — see
/// ``diagnosticColumnWidth`` for that trade — and each dot's size derives from
/// `rulerFont`, so it scales with the code zoom exactly like the numbers it
/// sits beside (`zoomSurfaceKind == .code` covers the whole gutter).
///
/// This is a pure view concern (no domain logic — the parsing lives in
/// `BlameParser` and the edit-driven shift in `BlameShift`), so it lives in the
/// `Pisaka` executable target rather than `PisakaCore`.
///
/// It declares itself a **code** zoom surface. The ruler is a sibling of the text
/// view (it is the scroll view's `verticalRulerView`), not a subview, so the
/// pointer walk cannot reach it through the editor; without the conformance a
/// gesture over the gutter or the blame column would find no candidate at all and
/// resize the whole application chrome instead — while the numbers it is over
/// draw at the code font and follow the code zone. The conformance carries no
/// behavior, exactly like the text views'.
@MainActor
final class LineNumberRulerView: NSRulerView, ZoomSurfaceProviding {
    let zoomSurfaceKind: ZoomSurfaceKind = .code

    /// The text view whose lines are numbered. Held weakly; the scroll view's
    /// view hierarchy owns it.
    private weak var textView: NSTextView?

    /// Horizontal padding between the numbers and each edge of the gutter.
    private let horizontalPadding: CGFloat = 4

    /// Gap between the annotation column and the line numbers, so the two read as
    /// separate columns rather than one run-on string.
    private let annotationGap: CGFloat = 8

    /// The author name is capped at this many characters (ellipsis included), so
    /// one long name cannot push the column across half the editor.
    private let maxAuthorCharacters = 20

    /// The blame annotation for every displayed line, in line order, `nil` where
    /// there is no data. Kept at exactly `lineCount` entries — `setAnnotations(_:)`
    /// places the git-numbered result onto the displayed line starts through
    /// `BlameAlignment.aligned`, which always returns one entry per line start, and
    /// `BlameShift.updated` preserves the invariant across every edit — so
    /// `drawHashMarksAndLabels` can index it by line number without bounds
    /// arithmetic of its own.
    private var annotations: [BlameLine?] = []

    /// Rendered label per commit hash — **strings only, never pixel widths**.
    ///
    /// A hash's label is font-independent; its rendered width is not, which is why
    /// the width lives in `annotationWidth` beside the size it was measured at
    /// rather than in here.
    private var labelMemo: [String: String] = [:]

    /// The measured annotation-column width, remembered together with the font
    /// size it was measured at.
    ///
    /// Both of its inputs change only at choke points — `labelMemo` in
    /// `setAnnotations(_:)`/`clearAnnotations()`, the font in
    /// `editorFontChanged()` — but `updateThickness()` is also called from
    /// `lineMapDidChange`, i.e. on **every keystroke**, and measuring there means
    /// one `NSString.size(withAttributes:)` per distinct commit per character
    /// typed. "Distinct commits touching one file" is dozens in a young file and
    /// several hundred in a long-lived one, which is milliseconds on the typing
    /// path for a width that provably did not move. So it is measured lazily and
    /// re-measured whenever the font size differs from the recorded one — which
    /// keeps the runtime font change (Preferences Stepper, Cmd+scroll) correct
    /// without needing `editorFontChanged()` to remember to invalidate anything.
    private var annotationWidth: (fontSize: CGFloat, width: CGFloat)?

    /// The rendered width of the widest displayed line number, remembered by
    /// `updateThickness()` alongside the thickness it sizes. A drawing input
    /// only — the marker column hangs off the numbers' left edge — and never a
    /// second measurement: `updateThickness()` already measures it on every
    /// call, so this just keeps the value the draw loop would otherwise have to
    /// re-derive per visible line.
    private var numberBandWidth: CGFloat = 0

    /// Whether the annotation column is shown for the displayed file. Driven by
    /// `setAnnotations(_:)` / `clearAnnotations()`; it also picks the context
    /// menu's title.
    private(set) var isAnnotating = false

    /// Whether annotate is available at all for the displayed file — false for an
    /// untitled buffer, which names no file to blame. Set by
    /// `BlameController.sync(fileID:fileURL:diskRevision:contentReplaced:)` from
    /// the file's URL; it only greys the menu item out.
    var canAnnotate = false

    /// Invoked when the context menu's Annotate / Close Annotations item is
    /// chosen. The owner captures itself **weakly** when installing this (the
    /// retain-cycle reason documented on `EditorTextView.onDuplicate`): the ruler
    /// is retained by the scroll view, which the coordinator's collaborators reach.
    var onToggleAnnotate: (() -> Void)?

    /// One character edit landed in the buffer, reported with the two line-start
    /// tables this class maintains anyway (`previousLineStarts` pre-edit,
    /// `newLineStarts` post-edit) plus the text storage's edited range and length
    /// delta. The diagnostics channel consumes exactly this arithmetic —
    /// ``DiagnosticShift.updated`` is `BlameShift.updated`'s shape — so handing it
    /// over here means the shift never re-derives line geometry a second time.
    ///
    /// The owner captures itself **weakly** when installing this, for the same
    /// retain-cycle reason as `onToggleAnnotate` above.
    var onEdit: ((_ previousLineStarts: [Int], _ newLineStarts: [Int], _ editedRange: NSRange, _ changeInLength: Int) -> Void)?

    /// The worst diagnostic severity for every displayed line, in line order,
    /// `nil` where the line is clean — fed wholesale by the coordinator out of
    /// `DiagnosticsModel.worstSeverityPerLine(url:lineCount:lineStarts:)` on
    /// every model change, edit and tab switch, and cleared with everything
    /// else when a buffer is swapped. Kept at exactly `lineCount` entries — the
    /// store's query returns precisely the requested count, and the setter
    /// below refuses anything else rather than padding it into a lie — so the
    /// draw loop reads it by line number: the blame array's invariant,
    /// established at the setter instead of hoped for downstream.
    private var diagnosticSeverities: [DiagnosticSeverity?] = []

    /// Horizontal gap between the marker column and whatever sits beside it.
    /// Smaller than `annotationGap` on purpose: this column is always present,
    /// so every point of it is paid by every document, even a plain-text one no
    /// server will ever diagnose.
    private let diagnosticGap: CGFloat = 6

    /// Parses ``BlameLine/date``'s raw ISO-8601 string. One formatter, reused —
    /// a label is built once per *commit*, not per line, but the memo is rebuilt
    /// on every install.
    private let isoParser = ISO8601DateFormatter()

    /// Renders the parsed date in the user's locale, short form. Locale belongs to
    /// the view layer, which is why Core keeps the date as text.
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()

    /// Cached UTF-16 start offset of every displayed line, maintained on edits
    /// (not per scroll) via the shared `LineStartIndex`. It uses the *same*
    /// line-separator semantics as the `lineRange` calls in
    /// `drawHashMarksAndLabels` (LF, CR, CRLF, U+2028, U+2029, …), and includes a
    /// trailing entry at `length` when the document ends in a separator (the final
    /// empty line). `lineStartOffsets.count` is therefore the displayed line count,
    /// and a binary search yields the first visible line number in O(log n) — so a
    /// redraw near the bottom of a huge file stays O(visible lines), not O(length).
    /// Edits update it incrementally from the edited range (`LineStartIndex.updated`)
    /// so typing in a large file scans the edit, not the whole buffer; the initial
    /// build does a full scan, and a wholesale buffer swap arrives as one
    /// full-range edit notification that rebuilds it (no separate explicit scan).
    private var lineStartOffsets: [Int] = [0]

    /// The current displayed line count, maintained incrementally on every edit
    /// via `LineStartIndex` (the same separator semantics as the minimap and
    /// TextKit). Exposed so the minimap geometry can scale from a *synchronous*
    /// document line count rather than the minimap's asynchronously-tokenized
    /// model, which is `.empty` for plain/unsupported files and briefly stale on a
    /// tab switch.
    var lineCount: Int { lineStartOffsets.count }

    /// The cached UTF-16 line-start offsets, read-only: the coordinator passes
    /// them straight to `DiagnosticsModel.worstSeverityPerLine` when it feeds
    /// the marker column, so the store maps a span's end onto a line with the
    /// exact table this class draws by — never a second, possibly divergent,
    /// copy.
    var lineStarts: [Int] { lineStartOffsets }

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView

        let center = NotificationCenter.default
        // Redraw on scroll (clip view bounds), resize (clip view frame), and on
        // text changes / document height growth (text view frame + text change).
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        clipView.postsFrameChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        // Scroll (clip-view bounds) and resize (clip-view / text-view frame) only
        // move the visible window — the line count is unchanged, so they merely
        // invalidate display without rescanning the buffer.
        center.addObserver(
            self,
            selector: #selector(visibleAreaChanged),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
        center.addObserver(
            self,
            selector: #selector(visibleAreaChanged),
            name: NSView.frameDidChangeNotification,
            object: clipView
        )
        center.addObserver(
            self,
            selector: #selector(visibleAreaChanged),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
        // A character edit is the only event that can alter the line count, so it
        // is the only one that touches the cached line-start offsets and gutter
        // width. Observe the *text storage* rather than `NSText.didChange`: the
        // storage notification carries the edited range and length delta (and
        // covers programmatic edits too), letting us update the cache
        // incrementally instead of rescanning the whole document on every
        // keystroke. It is a notification, so it coexists with Neon owning the
        // storage's `delegate`.
        if let textStorage = textView.textStorage {
            center.addObserver(
                self,
                selector: #selector(lineMapDidChange(_:)),
                name: NSTextStorage.didProcessEditingNotification,
                object: textStorage
            )
        }
        textContentChanged()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The font the numbers are drawn in: the editor font at a smaller size, so
    /// the gutter stays compact and visually subordinate to the code.
    private var rulerFont: NSFont {
        let editorSize = textView?.font?.pointSize ?? NSFont.systemFontSize
        let size = max(editorSize - 2, NSFont.smallSystemFontSize)
        return .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    /// Redraw for a scroll/resize. The visible window moved but the line count
    /// did not, so the cached offsets and gutter width are still valid — no buffer
    /// scan, keeping scrolling O(visible lines) even in a large file.
    @objc private func visibleAreaChanged() {
        needsDisplay = true
    }

    /// Re-sync after the editor font size changed: `rulerFont` re-derives from the
    /// text view's `pointSize` per draw, so the digit width (and thus the gutter
    /// thickness) shifts. Recompute the thickness and redraw. The cached line-start
    /// offsets are font-independent, so they need no rebuild.
    func editorFontChanged() {
        updateThickness()
        needsDisplay = true
    }

    /// Enter the annotating state *before* the blame result arrives.
    ///
    /// Annotate is turned on synchronously by `BlameController.toggle`, but the
    /// array only lands when the subprocess returns — seconds later on a large
    /// file with deep history. Without this the context menu would keep offering
    /// "Annotate with Git Blame" for that whole window while choosing it took the
    /// already-enabled branch and turned annotate *off*: the item would say one
    /// thing and do the opposite, with nothing on screen to explain it. The column
    /// stays visually absent meanwhile — there is nothing in `labelMemo` yet, so it
    /// contributes no width, and `drawAnnotation` finds no entry to draw — so this
    /// changes the reported state and nothing else.
    func beginAnnotating() {
        isAnnotating = true
    }

    /// Install a freshly loaded blame result and show the annotation column.
    ///
    /// The array arrives numbered by git's **LF-delimited** lines, so it is placed
    /// onto the buffer's line starts through `BlameAlignment.aligned` rather than
    /// indexed by buffer line directly: the gutter also splits on a lone CR, NEL,
    /// LS and PS, and a file carrying any of those would otherwise show every
    /// annotation past that character against the wrong line — permanently, since
    /// no recompute corrects it (see `BlameAlignment`).
    ///
    /// The mapping is also what **bounds the array to the current `lineCount`**,
    /// which is what makes a disk-shaped result safe to index by buffer line: a
    /// blame describes the file *on disk*, so a dirty buffer's array can be shorter
    /// or longer than what is displayed (see `BlameController`'s accepted
    /// inaccuracies). Bounding it here turns that into a column offset by whole
    /// lines until the next recompute — the documented, self-healing symptom —
    /// rather than an out-of-range trap, and it re-establishes the
    /// `annotations.count == lineCount` invariant `BlameShift` then maintains.
    func setAnnotations(_ lines: [BlameLine?]) {
        let content = (textView?.string ?? "") as NSString
        let placed = BlameAlignment.aligned(
            lines,
            toLineStartsIn: content,
            lineStarts: lineStartOffsets
        )
        annotations = placed
        labelMemo = Self.labels(
            for: placed,
            maxAuthorCharacters: maxAuthorCharacters,
            isoParser: isoParser,
            dateFormatter: dateFormatter
        )
        annotationWidth = nil
        isAnnotating = true
        updateThickness()
        needsDisplay = true
    }

    /// Hide the annotation column and drop its state. Also the pre-buffer-swap
    /// call: a wholesale `textView.string` assignment posts a full-range edit that
    /// would otherwise run the shift over a whole-document replacement.
    func clearAnnotations() {
        guard isAnnotating || !annotations.isEmpty else { return }
        annotations = []
        labelMemo = [:]
        annotationWidth = nil
        isAnnotating = false
        updateThickness()
        needsDisplay = true
    }

    /// Install the per-line worst severities for the displayed document and
    /// redraw. The array arrives exactly ``lineCount`` long — the caller passes
    /// this ruler's own count and line starts to the store's query, which
    /// returns precisely that many entries; anything else would be a caller
    /// bug, and is refused rather than padded into a lie (the draw loop bounds
    /// -checks its index regardless).
    ///
    /// Thickness is deliberately *not* touched: the column's width does not
    /// depend on its contents (see ``diagnosticColumnWidth``), so only a redraw
    /// is needed. An unchanged array is a no-op — this runs on every
    /// diagnostics-model mutation and every keystroke-driven repaint.
    func setDiagnosticSeverities(_ severities: [DiagnosticSeverity?]) {
        guard severities.count == lineStartOffsets.count else { return }
        guard severities != diagnosticSeverities else { return }
        diagnosticSeverities = severities
        needsDisplay = true
    }

    /// Build the `hash → label` memo for the distinct commits in `lines`.
    ///
    /// The label is `"<author> <short date>"`. Uncommitted lines are skipped: they
    /// draw nothing, so memoizing git's `Not Committed Yet` would widen the column
    /// for a label that is never rendered. The date is formatted **once per
    /// commit**, falling back to the ISO string's leading `yyyy-MM-dd` when it
    /// cannot be parsed (the parser leaves it empty when the output carried no
    /// `author-time`, in which case the label is the author alone).
    private static func labels(
        for lines: [BlameLine?],
        maxAuthorCharacters: Int,
        isoParser: ISO8601DateFormatter,
        dateFormatter: DateFormatter
    ) -> [String: String] {
        var memo: [String: String] = [:]
        for case let line? in lines where !line.isUncommitted && !line.hash.isEmpty {
            guard memo[line.hash] == nil else { continue }
            var author = line.author
            if author.count > maxAuthorCharacters {
                author = String(author.prefix(maxAuthorCharacters - 1)) + "…"
            }
            let date: String
            if let parsed = isoParser.date(from: line.date) {
                date = dateFormatter.string(from: parsed)
            } else {
                date = String(line.date.prefix(10))
            }
            memo[line.hash] = date.isEmpty ? author : "\(author) \(date)"
        }
        return memo
    }

    /// Fully rebuild the cached line-start offsets and gutter width, then redraw.
    /// Used for the initial build; edits — including a wholesale buffer swap, which
    /// the text storage posts as one full-range edit — go through `lineMapDidChange`.
    @objc private func textContentChanged() {
        recomputeLineStartOffsets()
        updateThickness()
        needsDisplay = true
    }

    /// Update the cached line starts incrementally from the edited range, then
    /// resize/redraw. Only character edits change the line map; attribute-only
    /// edits (e.g. styling) are ignored. Updating from the edited span avoids
    /// rescanning the whole document on every keystroke: a structure-preserving
    /// edit shifts the cached suffix without scanning any line (O(suffix line
    /// count) for the flat-array shift, not O(document length)), and only an edit
    /// that adds or removes a line break rescans the affected span.
    /// `LineStartIndex.updated` falls back to a full rebuild for any edit it
    /// can't apply incrementally, so the cache can never drift.
    @objc private func lineMapDidChange(_ notification: Notification) {
        guard
            let textStorage = notification.object as? NSTextStorage,
            textStorage.editedMask.contains(.editedCharacters)
        else { return }
        let content = textStorage.string as NSString
        let previousLineStarts = lineStartOffsets
        lineStartOffsets = LineStartIndex.updated(
            previous: lineStartOffsets,
            editedRange: textStorage.editedRange,
            changeInLength: textStorage.changeInLength,
            newText: content
        )
        // Shift the annotations across the same edit, from the two line-start
        // arrays this method already holds — so the column keeps pointing at the
        // lines it was loaded for while the user types, instead of sliding onto
        // their neighbours. `BlameShift` guarantees the result is exactly as long
        // as the new line-start array, so the draw loop's indexing stays safe.
        if !annotations.isEmpty {
            annotations = BlameShift.updated(
                previous: annotations,
                previousLineStarts: previousLineStarts,
                newLineStarts: lineStartOffsets,
                editedRange: textStorage.editedRange,
                changeInLength: textStorage.changeInLength
            )
        }
        // The diagnostics shift consumes the same tables (see `onEdit`). Fired
        // for every character edit, including the full-range edit a wholesale
        // buffer swap posts — the coordinator ignores that one edit (a plain
        // tab switch keeps the outgoing document's set; a genuine replacement
        // has nothing left to shift), so the shift never sees swap geometry.
        onEdit?(previousLineStarts, lineStartOffsets, textStorage.editedRange, textStorage.changeInLength)
        updateThickness()
        needsDisplay = true
    }

    /// Size the gutter to fit the widest line number (the total line count) plus
    /// the annotation column, the diagnostic-marker column, and padding on both
    /// sides.
    private func updateThickness() {
        let lineCount = max(1, lineStartOffsets.count)
        let widest = "\(lineCount)" as NSString
        let font = rulerFont
        let width = widest.size(withAttributes: [.font: font]).width
        numberBandWidth = ceil(width)
        let thickness = ceil(width)
            + annotationColumnWidth(font: font)
            + diagnosticColumnWidth
            + horizontalPadding * 2
        if ruleThickness != thickness {
            ruleThickness = thickness
        }
    }

    /// The marker column's contribution to the gutter: one marker cell plus its
    /// gap. **Constant for a given font size** — deliberately independent of
    /// whether any diagnostic exists.
    ///
    /// The trade is worth spelling out: the alternative — contributing 0 while
    /// the document has no diagnostics, like the blame column does — would make
    /// the whole editor text jump horizontally the moment a language server
    /// first reports (and again when it goes all-clear), on every server start,
    /// stop, and re-diagnosis. A few points of permanent gutter for everyone
    /// buys a gutter that never moves under the pointer. The blame column could
    /// stay conditional because *the user* turns it on and off; diagnostics
    /// arrive on their own schedule and must not move the page when they do.
    ///
    /// Both inputs derive from `rulerFont`, so the column scales with the code
    /// zoom exactly like the numbers beside it and is re-measured by the same
    /// `editorFontChanged()` path.
    private var diagnosticColumnWidth: CGFloat {
        diagnosticMarkerSide + diagnosticGap
    }

    /// Side of the dot drawn for a line carrying a diagnostic. Derived from the
    /// ruler font rather than fixed in points so it tracks the code zoom; never
    /// an absolute pixel size.
    private var diagnosticMarkerSide: CGFloat {
        ceil(rulerFont.pointSize * 0.5)
    }

    /// Width of the annotation column at `font` — the widest memoized label plus
    /// the gap — or 0 when not annotating, so the gutter is unchanged with the
    /// feature off.
    ///
    /// The measurement is memoized in `annotationWidth` against the font size it
    /// was taken at (see that property for why the per-keystroke measure had to
    /// go), so a repeat call at an unchanged size is a dictionary-free comparison
    /// and a font change re-measures on the next `updateThickness()`.
    private func annotationColumnWidth(font: NSFont) -> CGFloat {
        guard isAnnotating, !labelMemo.isEmpty else { return 0 }
        if let cached = annotationWidth, cached.fontSize == font.pointSize {
            return cached.width
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var widest: CGFloat = 0
        for label in labelMemo.values {
            widest = max(widest, (label as NSString).size(withAttributes: attributes).width)
        }
        let width = ceil(widest) + annotationGap
        annotationWidth = (font.pointSize, width)
        return width
    }

    /// Rebuild `lineStartOffsets` from the current text via the shared
    /// `LineStartIndex`, so the line count and gutter width agree with the
    /// `lineRange` math in `drawHashMarksAndLabels` (and with the minimap) for
    /// every standard separator — not just `\n`. A trailing offset at `length`
    /// marks the final empty line when the document ends in a separator.
    private func recomputeLineStartOffsets() {
        lineStartOffsets = LineStartIndex.offsets(in: (textView?.string ?? "") as NSString)
    }

    /// Whether the document ends with a line separator (and so has a trailing
    /// empty line) — the same check the cache uses, recognizing every standard
    /// separator, so the draw loop's trailing-line handling stays consistent.
    private func endsWithLineSeparator(_ content: NSString) -> Bool {
        LineStartIndex.endsWithLineSeparator(content)
    }

    /// 1-based line number of the line whose start offset is `offset`, via binary
    /// search of the cached starts (count of starts `<= offset`). O(log n).
    private func lineNumber(forLineStart offset: Int) -> Int {
        var low = 0
        var high = lineStartOffsets.count
        while low < high {
            let mid = (low + high) / 2
            if lineStartOffsets[mid] <= offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return max(1, low)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard
            let textView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
        else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: rulerFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        let content = textView.string as NSString
        let textOrigin = textView.textContainerOrigin
        // The ruler is laid out in the scroll view's coordinate space; translate
        // each glyph's y by the clip view's scroll position so numbers track the
        // visible region.
        let relativePoint = convert(NSPoint.zero, from: textView)

        // Only enumerate the glyphs currently visible, so scrolling a large file
        // stays O(visible lines). `glyphRange(forBoundingRect:)` wants the rect in
        // *text-container* coordinates, so shift the visible rect by
        // `textContainerOrigin`. Pin x to 0 and span the full content width (lines
        // do not wrap) so that horizontal scrolling — which slides the visible
        // rect's x — can never drop a short line that sits left of the visible
        // horizontal slice but whose row is still on screen.
        let visibleRect = textView.visibleRect
        let boundingRect = NSRect(
            x: 0,
            y: visibleRect.minY - textOrigin.y,
            width: max(visibleRect.width, textView.bounds.width),
            height: visibleRect.height
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: boundingRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Determine the 1-based line number of the first visible line. Anchor to
        // the *start* of the line containing `charRange.location` — the same snap
        // the draw loop applies below — then look it up in the cached line starts
        // (O(log n)) instead of rescanning the buffer from offset 0.
        let firstLineStart = content.lineRange(
            for: NSRange(location: min(charRange.location, content.length), length: 0)
        ).location
        var lineNumber = self.lineNumber(forLineStart: firstLineStart)

        // Walk each line in the visible range, drawing its number beside the
        // first line fragment of the line.
        var index = charRange.location
        let end = charRange.location + charRange.length
        while index < content.length && index < end {
            let lineRange = content.lineRange(for: NSRange(location: index, length: 0))
            let firstGlyph = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            var effectiveRange = NSRange(location: 0, length: 0)
            let fragmentRect = layoutManager.lineFragmentRect(
                forGlyphAt: firstGlyph,
                effectiveRange: &effectiveRange
            )

            drawLineNumber(
                lineNumber,
                fragmentRect: fragmentRect,
                textOrigin: textOrigin,
                relativePoint: relativePoint,
                attributes: attributes
            )
            drawAnnotation(
                forLine: lineNumber,
                fragmentRect: fragmentRect,
                textOrigin: textOrigin,
                relativePoint: relativePoint,
                attributes: attributes
            )
            drawDiagnosticMarker(
                forLine: lineNumber,
                fragmentRect: fragmentRect,
                textOrigin: textOrigin,
                relativePoint: relativePoint
            )

            lineNumber += 1
            index = NSMaxRange(lineRange)
        }

        // Draw the trailing line number when the document is empty or ends in a
        // line separator (the final empty line), matching editor behavior. Uses
        // `lineRange` semantics (any standard separator), not just `\n`.
        if end >= content.length && (content.length == 0 || endsWithLineSeparator(content)) {
            let extraRect = layoutManager.extraLineFragmentRect
            if extraRect.height > 0 {
                drawLineNumber(
                    lineNumber,
                    fragmentRect: extraRect,
                    textOrigin: textOrigin,
                    relativePoint: relativePoint,
                    attributes: attributes
                )
                drawAnnotation(
                    forLine: lineNumber,
                    fragmentRect: extraRect,
                    textOrigin: textOrigin,
                    relativePoint: relativePoint,
                    attributes: attributes
                )
                drawDiagnosticMarker(
                    forLine: lineNumber,
                    fragmentRect: extraRect,
                    textOrigin: textOrigin,
                    relativePoint: relativePoint
                )
            }
        }
    }

    /// Draw a single right-aligned line number aligned to a line fragment.
    private func drawLineNumber(
        _ number: Int,
        fragmentRect: NSRect,
        textOrigin: NSPoint,
        relativePoint: NSPoint,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let label = "\(number)" as NSString
        let labelSize = label.size(withAttributes: attributes)
        let y = relativePoint.y + textOrigin.y + fragmentRect.minY
            + (fragmentRect.height - labelSize.height) / 2
        let x = ruleThickness - labelSize.width - horizontalPadding
        label.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
    }

    /// Draw one line's blame label, left-aligned in the annotation column beside
    /// its line fragment. A `nil` entry (no data for this line) and an
    /// uncommitted one (in the working tree, in no commit) both draw nothing —
    /// they are different facts, but neither has an author to attribute.
    private func drawAnnotation(
        forLine number: Int,
        fragmentRect: NSRect,
        textOrigin: NSPoint,
        relativePoint: NSPoint,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard isAnnotating else { return }
        let index = number - 1
        guard index >= 0, index < annotations.count,
              let annotation = annotations[index],
              let label = labelMemo[annotation.hash]
        else { return }
        let text = label as NSString
        let labelSize = text.size(withAttributes: attributes)
        let y = relativePoint.y + textOrigin.y + fragmentRect.minY
            + (fragmentRect.height - labelSize.height) / 2
        text.draw(at: NSPoint(x: horizontalPadding, y: y), withAttributes: attributes)
    }

    /// Draw one line's severity marker, centered in the fixed marker column
    /// beside its line fragment. A line without a diagnostic draws nothing —
    /// the column is blank, not absent, which is what keeps the gutter's width
    /// independent of whether a server has reported yet. Overlapping
    /// diagnostics on one line were already resolved to the worst severity by
    /// the store's per-line query, so one dot answers for the line.
    private func drawDiagnosticMarker(
        forLine number: Int,
        fragmentRect: NSRect,
        textOrigin: NSPoint,
        relativePoint: NSPoint
    ) {
        let index = number - 1
        guard index >= 0, index < diagnosticSeverities.count,
              let severity = diagnosticSeverities[index]
        else { return }
        let side = diagnosticMarkerSide
        // The column hangs off the numbers' left edge: right-aligned numbers
        // end at `ruleThickness - padding`, their band is `numberBandWidth`
        // wide, and the gap separates the two columns.
        let x = ruleThickness - horizontalPadding - numberBandWidth - diagnosticGap - side
        let y = relativePoint.y + textOrigin.y + fragmentRect.minY
            + (fragmentRect.height - side) / 2
        SyntaxTheme.shared.nsDiagnosticColor(for: severity).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: side, height: side)).fill()
    }

    // MARK: - Context menu

    /// A one-item gutter menu toggling the annotation column, disabled for a
    /// buffer that names no file to blame (`canAnnotate == false`).
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        // Without this AppKit re-derives enablement from the responder chain and
        // would override `isEnabled` below.
        menu.autoenablesItems = false
        let item = NSMenuItem(
            title: isAnnotating ? "Close Annotations" : "Annotate with Git Blame",
            action: #selector(toggleAnnotate(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.isEnabled = canAnnotate
        menu.addItem(item)
        return menu
    }

    @objc private func toggleAnnotate(_ sender: Any?) {
        onToggleAnnotate?()
    }
}

#endif
