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
/// The same reasoning one level down makes `ranges(_:)` — the split as offsets,
/// which the save transform edits through — the primitive here, with `split(_:)`
/// projecting it. There is exactly one traversal that decides where a line ends.
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
        guard ns.length > 0 else { return [] }
        var ranges: [TerminatedLineRange] = []
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
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
