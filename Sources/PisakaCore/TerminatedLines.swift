import Foundation

/// One line of a text, split into its content and the separator that terminated
/// it. The terminator is empty for the last line of a text that does not end in
/// a separator, so "missing final newline" is a value of the ordinary
/// representation rather than a special case any caller has to branch on.
public struct TerminatedLine: Equatable {
    /// The line's text with its separator stripped — exactly what
    /// `LineDiff.splitLines` yields for this line, and therefore what a diff row
    /// compares.
    public let content: String
    /// The separator that ended this line, verbatim: `"\n"`, `"\r"`, `"\r\n"`
    /// (the pair, never split), `"\u{0085}"`, `"\u{2028}"`, `"\u{2029}"`, or
    /// `""` for an unterminated final line.
    public let terminator: String

    public init(content: String, terminator: String) {
        self.content = content
        self.terminator = terminator
    }

    /// The line as it appears in the text: `content + terminator`.
    public var text: String { content + terminator }
}

/// The same line as a pair of ranges into the text it came from: the content,
/// and the separator that terminated it.
///
/// **Why the offsets are a separate type rather than a field of
/// `TerminatedLine`.** A consumer that only compares lines (the diff, the
/// partial-commit builder) wants the substrings and nothing else; a consumer
/// that *edits* the text — the save transform — needs the offsets and would
/// otherwise have to re-derive them by measuring the substrings it was handed,
/// which is a second definition of what a line is by another name. So the range
/// split is the primitive and `TerminatedLines.split(_:)` is its projection.
public struct TerminatedLineRange: Equatable {
    /// The line's text, separator excluded.
    public let content: NSRange
    /// The separator that ended this line — the CRLF pair as one range of
    /// length two, never two ranges. Empty, and located at the end of `content`,
    /// for an unterminated final line.
    public let terminator: NSRange

    public init(content: NSRange, terminator: NSRange) {
        self.content = content
        self.terminator = terminator
    }

    /// The line as it appears in the text, terminator included.
    public var enclosing: NSRange {
        NSRange(location: content.location, length: content.length + terminator.length)
    }
}

/// The single line representation shared by the diff and by the partial-commit
/// builder, Foundation-only.
///
/// **Why it exists.** A partial commit assembles a file out of lines taken from
/// two sides, and it must emit them *verbatim* — terminators included — or a
/// commit would silently rewrite line endings it was never asked to touch. The
/// diff, on the other hand, compares lines with their separators *stripped*, and
/// a selection unit is an index into `LineDiff.rows(old:new:)`. So the builder
/// indexes one splitter's output with another splitter's indices: if the two
/// disagreed about what a line is for even one separator, the builder would
/// assemble the wrong lines with no error anywhere.
///
/// **So there is one implementation, not two.** `LineDiff.splitLines` is a
/// *projection* of this function (`split(text).map(\.content)`), not an
/// independently written splitter that happens to agree today. The consistency
/// is structural; `TerminatedLinesTests` additionally fuzzes the two against each
/// other as a lock against a second implementation coming back.
///
/// The same reasoning one level down makes the split *as offsets* — which the
/// save transform edits through — the primitive here, with `split(_:)`
/// projecting it. One level down again, the offsets themselves are answered by
/// the **bounded** `ranges(in:range:)`, of which the whole-text `ranges(_:)` is
/// the full-range call: a consumer that only cares about the lines it is
/// drawing must not pay for a traversal of the file, and paying for one in a
/// second implementation of "where does a line end" would be worse still. There
/// is exactly one traversal that decides where a line ends.
///
/// The separator set is `NSString`'s own `.byLines` set — LF, CR, the CRLF pair
/// as *one* separator, NEL (U+0085), LS (U+2028) and PS (U+2029) — which is the
/// same set `LineStartIndex` splits on, so the gutter, the minimap, the diff and
/// the builder all count lines the same way.
public enum TerminatedLines {
    /// Split `text` into its lines, each carrying the separator that ended it.
    ///
    /// A projection of `ranges(_:)`, deliberately: the offsets are computed once
    /// and this function only reads the substrings they name, so the two can
    /// never drift apart about what a line is.
    ///
    /// The structural invariant, on which the builder's "an empty selection
    /// reproduces HEAD byte for byte" rests: concatenating every
    /// `content + terminator` reproduces `text` identically. Empty text yields no
    /// lines, and a trailing separator adds no phantom empty line — `"a\n"` and
    /// `"a"` both split to one line, differing only in that line's terminator.
    public static func split(_ text: String) -> [TerminatedLine] {
        let ns = text as NSString
        return ranges(text).map {
            TerminatedLine(content: ns.substring(with: $0.content), terminator: ns.substring(with: $0.terminator))
        }
    }

    /// The same split as ranges into `text`, for a caller that must *edit* the
    /// lines rather than compare them.
    ///
    /// The ranges tile the text exactly: each line's `enclosing` range starts
    /// where the previous one ended, and the last one ends at the text's end. An
    /// edit plan expressed against these offsets therefore has no gaps and no
    /// overlaps to reason about.
    public static func ranges(_ text: String) -> [TerminatedLineRange] {
        let ns = text as NSString
        return ranges(in: ns, range: NSRange(location: 0, length: ns.length))
    }

    /// The same split, bounded: the lines that `range` intersects, as ranges
    /// into `text`.
    ///
    /// **The range is expanded to whole lines before anything is enumerated**,
    /// through `NSString.lineRange(for:)` — a range that starts or ends
    /// mid-line answers that line whole, never a fragment of it. A caller
    /// asking about a *drawn* region therefore gets lines it can reason about
    /// without knowing where it cut; nothing is clipped on the way out either.
    /// `range` is clamped to the text first, so an out-of-bounds or negative
    /// request is answered rather than trapping.
    ///
    /// This is *the* primitive: `ranges(_:)` is this function over the full
    /// range, so there stays exactly one traversal that decides where a line
    /// ends. Bounding it is what keeps a redraw off a whole-file scan — the
    /// enumeration only ever visits the expanded span.
    public static func ranges(in text: NSString, range: NSRange) -> [TerminatedLineRange] {
        let length = text.length
        guard length > 0 else { return [] }
        let start = min(max(0, range.location), length)
        let end = min(max(start, range.location + max(0, range.length)), length)
        let expanded = text.lineRange(for: NSRange(location: start, length: end - start))
        guard expanded.length > 0 else { return [] }
        var ranges: [TerminatedLineRange] = []
        text.enumerateSubstrings(
            in: expanded,
            options: [.byLines]
        ) { _, substringRange, enclosingRange, _ in
            // The enclosing range covers the line *and* its separator; the part of
            // it past the substring is the terminator (empty for the final,
            // unterminated line). Taking it as a range difference rather than by
            // matching separator literals is what keeps the CRLF pair intact and
            // needs no separator table of its own.
            let contentEnd = NSMaxRange(substringRange)
            let enclosingEnd = NSMaxRange(enclosingRange)
            ranges.append(TerminatedLineRange(
                content: substringRange,
                terminator: NSRange(location: contentEnd, length: max(0, enclosingEnd - contentEnd))
            ))
        }
        return ranges
    }
}
