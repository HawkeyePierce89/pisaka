import Foundation

/// Whether a list is **tight** or **loose** — CommonMark's own distinction,
/// decided here from the lines its items occupy.
///
/// CommonMark states the rule directly: a list is loose if any of its
/// constituent items are separated by blank lines, *or* if any item directly
/// contains two block-level elements with a blank line between them. Everything
/// else is tight. A tight list draws each item as a bare line; a loose one draws
/// every item's content as a paragraph, with the paragraph spacing that implies.
///
/// **The rule lives here because the parser cannot answer it.** cmark decides
/// looseness while parsing and keeps the answer on its own node
/// (`cmark_node_get_list_tight`); swift-markdown's tree carries no such flag and
/// exposes no way back to that node, so the distinction has to be recovered.
/// What *is* exposed is every node's source range, and the definition above is
/// stated entirely in terms of blank lines between blocks — which is a question
/// about line numbers and nothing else. So the parser reads the ranges and this
/// engine reads the rule off them, in Core, where `swift test` can see it.
///
/// **A gap is not evidence; a blank line is.** Two blocks whose spans end and
/// begin on consecutive lines are adjacent, so a gap is a precondition — but not
/// every line between two of a list's blocks is blank. A **link reference
/// definition** is written on a line of its own and leaves no node behind at all
/// (cmark consumes it into the document's link map), so the two blocks around it
/// are separated by a line the source wrote as content and cmark counts as
/// nothing. Reading the gap alone would call that list loose where cmark calls it
/// tight. The rule therefore asks the source directly: a gap loosens only when
/// one of the lines strictly inside it is blank, which is exactly the sentence
/// CommonMark states. This holds inside a block quote too, where the blank line
/// carries a `>` and ``blankLines(in:)`` reads it as blank. The mirror image — a
/// quote *inside* an item, whose trailing `>` is a line **of** the quote rather
/// than one between two of the item's blocks — is the caller's to keep within a
/// single span, and it does: a block quote's span is its own range, which covers
/// that line, so no `>` line is ever *strictly inside* a gap.
///
/// **"Directly contain" is the caller's half.** Each item reports the spans of
/// its *direct* block children, and a child that is itself a container reports
/// the lines its content occupies — so a blank line buried inside a nested list
/// falls within one span and never registers as a gap in the list holding it.
/// That is what makes the inner list loose and leaves the outer one tight, which
/// is what CommonMark says and what cmark does.
///
/// **One block kind cannot answer from its range alone**, and the two members
/// below are its answer: an *indented* code block's range swallows the blank
/// line that ended it (cmark strips trailing blanks from the content and closes
/// the node past them), and nothing on swift-markdown's `CodeBlock` tells an
/// indented block from a fenced one, whose range legitimately runs to its
/// closing fence. Rather than re-deciding the fence form, the span is trimmed of
/// trailing blank *source* lines. The source therefore reaches Core as
/// ``blankLines(in:)`` and nothing more — one reading, answering both this
/// question and the rule's own.
public enum MarkdownListTightness {

    /// Whether the list whose items occupy `itemSpans` is tight.
    ///
    /// `itemSpans` is one entry per list item, in source order: the 1-based,
    /// inclusive line spans of that item's direct block children, also in source
    /// order. Two obligations ride on the caller, both of them readings rather
    /// than decisions:
    ///
    /// - a span must cover the block's **content**, not any trailing blank line
    ///   a container node's own range absorbs (cmark closes a list item *after*
    ///   the blank line that ended it, so an item's own range is the wrong
    ///   answer and its children's are the right one);
    /// - an item must cover the line its **marker** was written on, that line
    ///   carrying content and so never being the blank one the rule looks for:
    ///   an item with no block children at all — `-` on a line by itself —
    ///   reports that line alone, and one whose content is written under the
    ///   marker rather than beside it reports from the marker down. Either way
    ///   the item separates its neighbours rather than letting them be compared
    ///   across a line that is not blank.
    ///
    /// `blankLines` is the document's own blank lines, as ``blankLines(in:)``
    /// reads them: what separates two blocks is asked of the source rather than
    /// inferred from the distance between them, so a line that carries a link
    /// reference definition — content to the source, nothing to the tree — is not
    /// mistaken for a blank one.
    ///
    /// Total, and tight is the answer whenever there is no evidence of a blank
    /// line: a list with no items, one item, or one block is tight, which is also
    /// what every renderer draws for them.
    public static func isTight(itemSpans: [[ClosedRange<Int>]], blankLines: Set<Int>) -> Bool {
        // One walk over every span in the list, in order, rather than one pass
        // between items and another within them: the two halves of CommonMark's
        // sentence ask the same question of adjacent blocks and only differ in
        // where the item boundary happens to fall.
        var previous: ClosedRange<Int>?
        for spans in itemSpans {
            for span in spans {
                if let previous,
                   holdsABlankLine(after: previous.upperBound, before: span.lowerBound, in: blankLines) {
                    return false
                }
                previous = span
            }
        }
        return true
    }

    /// Whether any line strictly between `after` and `before` is blank. Adjacent
    /// spans enclose no line at all and so can never be separated.
    private static func holdsABlankLine(after previous: Int,
                                        before next: Int,
                                        in blankLines: Set<Int>) -> Bool {
        guard next > previous + 1 else { return false }
        return ((previous + 1)..<next).contains { blankLines.contains($0) }
    }

    /// The 1-based lines of `source` that hold nothing a block could be built
    /// from — whitespace and block-quote markers only.
    ///
    /// **`>` counts as nothing** because a blank line inside a block quote is
    /// written as one: `>` on a line of its own is what the quote's content
    /// reads as blank, and that is the line a code block inside a quoted list
    /// ends on. Outside a quote no such line can be mistaken for content either
    /// — a lone `>` opens an empty block quote, which no code block's range
    /// covers.
    ///
    /// **The separators are cmark's**, deliberately not the editor-wide set
    /// `TerminatedLines` splits on: these numbers are compared against the ones
    /// cmark wrote onto the tree, and cmark ends a line at LF, CR or CRLF and at
    /// nothing else. A `NEL`, `LS` or `PS` is ordinary text to it, so counting
    /// one as a break here would shift every line number below it. Swift's
    /// grapheme breaking already reads `CRLF` as one `Character`, which is why
    /// the set has three members and no look-ahead.
    ///
    /// **The whitespace is cmark's too**, for the same reason and by the same
    /// argument: CommonMark's blank line holds spaces and tabs and nothing else,
    /// so the test names those two rather than asking `Character.isWhitespace`,
    /// whose set is Unicode's. That set contains `NBSP`, `U+2007`, `U+202F`,
    /// `U+3000` — and `NEL`, `LS` and `PS`, which this very function refuses to
    /// read as separators. A line holding one pasted `NBSP` is content to cmark
    /// and would be blank here: the enclosing list would render loose against a
    /// tree that says it is tight, and a code block's span would be trimmed into
    /// its own content.
    public static func blankLines(in source: String) -> Set<Int> {
        var blanks: Set<Int> = []
        var line = 1
        var isBlank = true
        for character in source {
            if lineSeparators.contains(character) {
                if isBlank { blanks.insert(line) }
                line += 1
                isBlank = true
            } else if character != " ", character != "\t", character != ">" {
                isBlank = false
            }
        }
        if isBlank { blanks.insert(line) }
        return blanks
    }

    /// The lines a code block's **content** occupies, given the range cmark
    /// closed it on, the code it holds and the document's blank lines.
    ///
    /// Two readings, and the answer is exact for both fence forms without either
    /// one having to name them:
    ///
    /// - **At most as many lines may be dropped as the range holds beyond the
    ///   code's own.** A closed fence spends two of them on its fences, an
    ///   indented block spends them on the blank lines cmark closed it past. The
    ///   count is a ceiling, never an instruction: it is what stops a fenced
    ///   block whose *content* ends in blank lines from being trimmed into that
    ///   content, the closing fence being the first line the walk meets.
    /// - **Only a line the source wrote blank is dropped.** A closing fence is
    ///   not blank, so a fenced block keeps its whole range; the blank line that
    ///   ended an indented block is, so that block loses it.
    ///
    /// The first line is never dropped: a block occupies the line it began on
    /// whatever it holds.
    public static func codeBlockContentSpan(range: ClosedRange<Int>,
                                            code: String,
                                            blankLines: Set<Int>) -> ClosedRange<Int> {
        var last = range.upperBound
        var droppable = range.count - lineCount(of: code)
        while droppable > 0, last > range.lowerBound, blankLines.contains(last) {
            last -= 1
            droppable -= 1
        }
        return range.lowerBound...last
    }

    /// The number of source lines `code` occupies. cmark terminates code with a
    /// newline, so the count is its separators — except for the unterminated
    /// text an unclosed fence at end of file produces, whose last line has no
    /// separator to be counted by.
    private static func lineCount(of code: String) -> Int {
        guard let last = code.last else { return 0 }
        let separators = code.reduce(into: 0) { $0 += lineSeparators.contains($1) ? 1 : 0 }
        return lineSeparators.contains(last) ? separators : separators + 1
    }

    private static let lineSeparators: Set<Character> = ["\n", "\r\n", "\r"]
}
