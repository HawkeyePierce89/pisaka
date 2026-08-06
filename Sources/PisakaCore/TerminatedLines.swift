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
/// The separator set is `NSString`'s own `.byLines` set — LF, CR, the CRLF pair
/// as *one* separator, NEL (U+0085), LS (U+2028) and PS (U+2029) — which is the
/// same set `LineStartIndex` splits on, so the gutter, the minimap, the diff and
/// the builder all count lines the same way.
public enum TerminatedLines {
    /// Split `text` into its lines, each carrying the separator that ended it.
    ///
    /// The structural invariant, on which the builder's "an empty selection
    /// reproduces HEAD byte for byte" rests: concatenating every
    /// `content + terminator` reproduces `text` identically. Empty text yields no
    /// lines, and a trailing separator adds no phantom empty line — `"a\n"` and
    /// `"a"` both split to one line, differing only in that line's terminator.
    public static func split(_ text: String) -> [TerminatedLine] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        var lines: [TerminatedLine] = []
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.byLines]
        ) { substring, substringRange, enclosingRange, _ in
            // The enclosing range covers the line *and* its separator; the part of
            // it past the substring is the terminator (empty for the final,
            // unterminated line). Taking it as a range difference rather than by
            // matching separator literals is what keeps the CRLF pair intact and
            // needs no separator table of its own.
            let contentEnd = NSMaxRange(substringRange)
            let enclosingEnd = NSMaxRange(enclosingRange)
            let terminator = enclosingEnd > contentEnd
                ? ns.substring(with: NSRange(location: contentEnd, length: enclosingEnd - contentEnd))
                : ""
            lines.append(TerminatedLine(content: substring ?? "", terminator: terminator))
        }
        return lines
    }
}
