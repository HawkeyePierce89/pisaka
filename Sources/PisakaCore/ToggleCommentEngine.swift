import Foundation

/// The text to splice in for one toggle comment edit plus where the selection should
/// land afterward.
public struct CommentToggleEdit: Equatable {
    public let replacementRange: NSRange
    public let text: String
    public let selectedRange: NSRange

    public init(replacementRange: NSRange, text: String, selectedRange: NSRange) {
        self.replacementRange = replacementRange
        self.text = text
        self.selectedRange = selectedRange
    }
}

public enum ToggleCommentEngine {
    /// Compute the comment toggle for `selectedRange` in `text` under `language`.
    ///
    /// Returns `nil` if `language` is `nil`, the language has no comment syntax,
    /// or the target contains no non-blank lines. A `nil` return is a silent no-op
    /// and means no edit *and* no caret move.
    public static func toggle(text: NSString, selectedRange: NSRange, language: SyntaxLanguage?) -> CommentToggleEdit? {
        guard let language = language, let style = CommentStyle.style(for: language) else {
            return nil
        }

        let range = clamped(selectedRange, length: text.length)
        let touchedSpan = computeTouchedSpan(text: text, range: range)

        // Split the span into lines
        var lines: [LineInfo] = []
        var currentIndex = touchedSpan.location
        while currentIndex < NSMaxRange(touchedSpan) {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: currentIndex, length: 0))

            let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)
            lines.append(LineInfo(
                start: lineStart,
                end: lineEnd,
                contentsEnd: contentsEnd,
                content: text.substring(with: lineRange),
                isCaretLine: range.length == 0 && range.location >= lineStart && range.location <= lineEnd
            ))
            currentIndex = lineEnd
        }

        switch style {
        case .line(let token):
            return toggleLineComment(text: text, lines: lines, token: token, range: range, touchedSpan: touchedSpan)
        case .block:
            // Implemented in Task 3
            return nil
        }
    }

    private static func toggleLineComment(
        text: NSString,
        lines: [LineInfo],
        token: String,
        range: NSRange,
        touchedSpan: NSRange
    ) -> CommentToggleEdit? {
        // Skip blank lines
        let nonBlankLines = lines.filter { !$0.isBlank }
        if nonBlankLines.isEmpty {
            return nil
        }

        // Check if all non-blank lines are commented
        let allCommented = nonBlankLines.allSatisfy { $0.isCommented(token: token) }

        var newText = ""
        var caretDeltaForLastLine = 0

        for line in lines {
            if line.isBlank {
                newText += line.content
                continue
            }
            if allCommented {
                // Uncomment
                let uncommented = line.uncommented(token: token)
                newText += uncommented
                if line.isCaretLine {
                    caretDeltaForLastLine = uncommented.utf16.count - line.content.utf16.count
                }
            } else {
                // Comment
                let commented = token + line.content
                newText += commented
                if line.isCaretLine {
                    caretDeltaForLastLine = token.utf16.count
                }
            }
        }

        let isSelection = range.length > 0
        let newSelectedRange: NSRange

        if isSelection {
            let newLength = newText.utf16.count
            // selection is post-edit whole-line span (terminator excluded for end?)
            // "selection placement, selection case — the post-edit whole-line span of
            // the touched lines: from the first touched line's start to the last touched
            // line's contents end (its terminator excluded)."

            // Wait, we need to find the new contentsEnd of the last line.
            // The last line's original terminator length is unchanged.
            let lastLine = lines.last!
            let terminatorLength = lastLine.end - lastLine.contentsEnd
            let newSpanLength = newLength - terminatorLength
            newSelectedRange = NSRange(location: touchedSpan.location, length: newSpanLength)
        } else {
            let line = lines[0]
            let originalColumn = range.location - line.start
            let isLastLine = line.end == text.length && line.end == line.contentsEnd

            if isLastLine {
                let delta = caretDeltaForLastLine
                // the new content length of this line (excluding terminator which is 0 anyway)
                // Actually newLength = newText.utf16.count
                let newContentLength = newText.utf16.count
                let newColumn = min(max(originalColumn + delta, 0), newContentLength)
                newSelectedRange = NSRange(location: touchedSpan.location + newColumn, length: 0)
            } else {
                // Find next line's start and contents length
                var nextLineStart = 0
                var nextLineEnd = 0
                var nextLineContentsEnd = 0
                text.getLineStart(
                    &nextLineStart,
                    end: &nextLineEnd,
                    contentsEnd: &nextLineContentsEnd,
                    for: NSRange(location: line.end, length: 0)
                )

                let nextLineContentLength = nextLineContentsEnd - nextLineStart
                let newColumn = min(originalColumn, nextLineContentLength)
                // post-edit coordinates!
                // touchedSpan.location + newText.length gives the exact start of the next line.
                let nextLineNewStart = touchedSpan.location + newText.utf16.count
                newSelectedRange = NSRange(location: nextLineNewStart + newColumn, length: 0)
            }
        }

        return CommentToggleEdit(
            replacementRange: touchedSpan,
            text: newText,
            selectedRange: newSelectedRange
        )
    }

    private static func computeTouchedSpan(text: NSString, range: NSRange) -> NSRange {
        var startLineStart = 0
        text.getLineStart(&startLineStart, end: nil, contentsEnd: nil, for: NSRange(location: range.location, length: 0))

        if range.length == 0 {
            var lineEnd = 0
            text.getLineStart(nil, end: &lineEnd, contentsEnd: nil, for: NSRange(location: range.location, length: 0))
            return NSRange(location: startLineStart, length: lineEnd - startLineStart)
        }

        // Selection ending exactly at a line start does not touch that line (if length > 0)
        let endLocation = NSMaxRange(range)
        var endLineStart = 0
        var endLineEnd = 0
        text.getLineStart(&endLineStart, end: &endLineEnd, contentsEnd: nil, for: NSRange(location: endLocation, length: 0))

        let actualEndLocation = (endLocation == endLineStart && endLocation > range.location) ? endLocation - 1 : endLocation
        text.getLineStart(nil, end: &endLineEnd, contentsEnd: nil, for: NSRange(location: actualEndLocation, length: 0))

        return NSRange(location: startLineStart, length: endLineEnd - startLineStart)
    }

    private static func clamped(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        let maxLength = length - location
        return NSRange(location: location, length: min(max(range.length, 0), maxLength))
    }
}

private struct LineInfo {
    let start: Int
    let end: Int
    let contentsEnd: Int
    let content: String
    let isCaretLine: Bool

    var isBlank: Bool {
        let nsString = content as NSString
        let contentsLength = contentsEnd - start
        let stringContent = nsString.substring(to: contentsLength)
        return stringContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func isCommented(token: String) -> Bool {
        let nsString = content as NSString
        let contentsLength = contentsEnd - start
        let stringContent = nsString.substring(to: contentsLength)
        let trimmed = stringContent.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(token)
    }

    func uncommented(token: String) -> String {
        let nsString = content as NSString
        let contentsLength = contentsEnd - start

        let terminator = nsString.substring(from: contentsLength)

        var i = 0
        while i < contentsLength {
            let unichar = nsString.character(at: i)
            if let scalar = Unicode.Scalar(unichar), CharacterSet.whitespaces.contains(scalar) {
                i += 1
            } else {
                break
            }
        }

        let leadingSpaces = nsString.substring(with: NSRange(location: 0, length: i))
        var rest = nsString.substring(with: NSRange(location: i, length: contentsLength - i))

        if rest.hasPrefix(token) {
            rest.removeFirst(token.count)
            if rest.hasPrefix(" ") {
                rest.removeFirst()
            }
        }

        return leadingSpaces + rest + terminator
    }
}
