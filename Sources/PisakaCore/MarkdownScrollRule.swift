import Foundation

/// The editor's scroll position, as the one number the page understands.
///
/// Scroll sync is deliberately **one-directional**: the editor is the document,
/// the preview is a view of it, and a view does not move its document. So this
/// file maps an offset to a line and there is no inverse — scrolling the preview
/// sends nothing back, which is also what keeps the two from chasing each other
/// through a feedback loop that neither side could damp.
///
/// The line is the *editor's* line: counted with ``LineStartIndex``' separator
/// set (LF, CR, CRLF, NEL, LS, PS) and numbered from 1, so it means the same
/// thing as the number in the gutter beside the caret. It meets the page as a
/// `data-line` attribute, which the renderer wrote from the parser's own
/// 1-based source lines, and the page's own rule (scroll to the last top-level
/// block at or before this line) is what absorbs the fact that most lines carry
/// no block of their own.
///
/// **NEL/LS/PS are this feature's one stated limit**, the same one
/// `end_of_line` records: the two numberings agree for every separator the
/// Markdown parser also breaks lines on — LF, CR and CRLF — and only for those.
/// A document containing U+0085, U+2028 or U+2029 is numbered one line higher
/// here per occurrence than in the tree the `data-line` values came from, so the
/// page scrolls to a block slightly earlier than the editor's top. Correcting it
/// would mean counting the sync line a *second* way, against a separator set
/// that is neither the gutter's nor any other engine's; the drift is silent,
/// bounded by the count of such characters, and costs a scroll position rather
/// than content.
public enum MarkdownScrollRule {

    /// The 1-based line containing `offset`.
    ///
    /// Total: a negative offset reads as the start of the document and an offset
    /// past the end as its last line, because both are things a scroll view can
    /// report during a live resize and neither is worth an optional the caller
    /// would have to invent an answer for. An empty `lineStarts` — which
    /// ``LineStartIndex/offsets(in:)`` never produces, even for empty text —
    /// reads as line 1.
    public static func line(forTopOffset offset: Int, lineStarts: [Int]) -> Int {
        guard !lineStarts.isEmpty else { return 1 }
        return LSPPositionMap.lineIndex(containing: max(0, offset), lineStarts: lineStarts) + 1
    }

    /// The same answer for a buffer whose line starts have not been cached.
    ///
    /// The editor has them already and passes them; this form is for callers
    /// that hold only the text, and it exists so no one is tempted to count
    /// lines a second way.
    public static func line(forTopOffset offset: Int, in content: NSString) -> Int {
        line(forTopOffset: offset, lineStarts: LineStartIndex.offsets(in: content))
    }
}
