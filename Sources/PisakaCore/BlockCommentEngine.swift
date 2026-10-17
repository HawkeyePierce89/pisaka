import Foundation

/// Toggle Block Comment (⌥⌘/): wrap each selection in the language's block
/// delimiters, unwrap one that already is, and drop an empty pair at a caret.
///
/// Every range is answered on its own, all in one `RangeEditPlan`, so the
/// command is one undo step however many carets there are:
/// - a selection that starts with `open` and ends with `close` — at least
///   `open + close` long, so the two never share characters — unwraps, taking
///   one optional inner space on each side with it; the selection then covers
///   what was inside;
/// - any other selection is wrapped as `open + " " + text + " " + close`, and
///   the selection then covers the whole wrapped text, so a second press
///   unwraps it;
/// - a caret inserts `open` + two spaces + `close` (`/*  */`) and lands between
///   the two spaces.
///
/// Identical carets are answered once, and a range overlapping an earlier one
/// (which `NSTextView` never hands over) is dropped rather than producing an
/// overlapping plan.
public enum BlockCommentEngine {

    /// The block toggle under one pair of delimiters for every range.
    public static func toggle(
        text: NSString,
        selectedRanges: [NSRange],
        delimiters: BlockCommentDelimiters
    ) -> RangeEditPlan {
        toggle(text: text, selectedRanges: selectedRanges) { _ in delimiters }
    }

    /// The whole ⌥⌘/ command for `language`, or `nil` when it has nothing to
    /// do there — json and markdown, which have no comment syntax, and no
    /// language at all — which the view answers with a beep.
    ///
    /// The chosen fallback: a language with a line comment but no block syntax
    /// (the `#` and `--` languages) runs the line-comment toggle instead, so the
    /// key still comments something rather than beeping in a file that has
    /// comments.
    ///
    /// `context` is asked, exactly as the line toggle asks it, for the offset of
    /// the **first non-whitespace character** of each range's starting line,
    /// and only in a language whose JSX-children delimiters differ from its
    /// code ones (the JavaScript family); a range starting in JSX children is
    /// wrapped `{/* … */}`.
    public static func toggle(
        text: NSString,
        selectedRanges: [NSRange],
        language: SyntaxLanguage?,
        context: (Int) -> CommentContext
    ) -> RangeEditPlan? {
        guard let language else { return nil }
        guard let code = CommentStyle.blockDelimiters(for: language, context: .code) else {
            guard CommentStyle.style(for: language) != nil else { return nil }
            return ToggleCommentEngine.toggle(
                text: text, selectedRanges: selectedRanges, language: language, context: context
            )
        }
        guard let jsx = CommentStyle.blockDelimiters(for: language, context: .jsxChildren), jsx != code else {
            return toggle(text: text, selectedRanges: selectedRanges, delimiters: code)
        }
        let lines = BlockIndentEngine.Lines(text: text)
        return toggle(text: text, selectedRanges: selectedRanges) { range in
            let line = lines.index(of: range.location)
            let offset = lines.start(of: line)
                + ToggleCommentEngine.indentation(text: text, lines: lines, line: line)
            return context(offset) == .jsxChildren ? jsx : code
        }
    }

    private static func toggle(
        text: NSString,
        selectedRanges: [NSRange],
        delimiters: (NSRange) -> BlockCommentDelimiters
    ) -> RangeEditPlan {
        let ranges = selectedRanges
            .map { clamped($0, length: text.length) }
            .sorted { ($0.location, $0.length) < ($1.location, $1.length) }
        var edits: [IndentReplacement] = []
        var selections: [NSRange] = []
        var previous: NSRange?
        var shift = 0
        for range in ranges {
            if let previous {
                if range == previous { continue }
                if range.location < NSMaxRange(previous) { continue }
            }
            previous = range
            let pair = delimiters(range)
            let open = (pair.open as NSString).length
            let close = (pair.close as NSString).length
            let start = range.location + shift
            if range.length == 0 {
                edits.append(IndentReplacement(
                    range: NSRange(location: range.location, length: 0),
                    replacement: pair.open + "  " + pair.close
                ))
                selections.append(NSRange(location: start + open + 1, length: 0))
                shift += open + 2 + close
            } else if let unwrap = unwrapping(text: text, range: range, pair: pair) {
                edits.append(IndentReplacement(range: unwrap.head, replacement: ""))
                edits.append(IndentReplacement(range: unwrap.tail, replacement: ""))
                let inner = range.length - unwrap.head.length - unwrap.tail.length
                selections.append(NSRange(location: start, length: inner))
                shift -= unwrap.head.length + unwrap.tail.length
            } else {
                edits.append(IndentReplacement(
                    range: NSRange(location: range.location, length: 0), replacement: pair.open + " "
                ))
                edits.append(IndentReplacement(
                    range: NSRange(location: NSMaxRange(range), length: 0), replacement: " " + pair.close
                ))
                let added = open + 1 + 1 + close
                selections.append(NSRange(location: start, length: range.length + added))
                shift += added
            }
        }
        return RangeEditPlan(edits: edits, selections: selections) ?? .empty
    }

    /// The two ranges an unwrap deletes — `open` plus one optional space after
    /// it, one optional space before `close` plus `close` — or `nil` when the
    /// selection is not one whole block comment.
    private static func unwrapping(
        text: NSString, range: NSRange, pair: BlockCommentDelimiters
    ) -> (head: NSRange, tail: NSRange)? {
        let open = (pair.open as NSString).length
        let close = (pair.close as NSString).length
        guard range.length >= open + close else { return nil }
        let selected = text.substring(with: range) as NSString
        guard selected.hasPrefix(pair.open), selected.hasSuffix(pair.close) else { return nil }
        var head = open
        var tail = close
        let inner = range.length - open - close
        if inner > 0, selected.character(at: open) == 0x20 { head += 1 }
        if inner - (head - open) > 0, selected.character(at: range.length - close - 1) == 0x20 { tail += 1 }
        return (
            NSRange(location: range.location, length: head),
            NSRange(location: NSMaxRange(range) - tail, length: tail)
        )
    }

    private static func clamped(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        return NSRange(location: location, length: min(max(range.length, 0), length - location))
    }
}
