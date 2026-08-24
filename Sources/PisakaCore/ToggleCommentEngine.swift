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
        case .block(let open, let close):
            return toggleBlockComment(text: text, lines: lines, open: open, close: close, range: range, touchedSpan: touchedSpan)
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

        let originalColumn = range.length == 0 ? range.location - lines[0].start : 0
        for line in lines {
            if line.isBlank {
                newText += line.content
                continue
            }
            if allCommented {
                // Uncomment
                let (uncommented, removedIdx) = line.uncommented(token: token)
                newText += uncommented
                if line.isCaretLine && originalColumn > removedIdx {
                    let fullDelta = uncommented.utf16.count - line.content.utf16.count
                    if originalColumn < removedIdx - fullDelta {
                        caretDeltaForLastLine = removedIdx - originalColumn
                    } else {
                        caretDeltaForLastLine = fullDelta
                    }
                }
            } else {
                // Comment
                let nsString = line.content as NSString
                let contentsLength = line.contentsEnd - line.start
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
                let rest = nsString.substring(from: i)
                let commented = leadingSpaces + token + " " + rest
                newText += commented
                if line.isCaretLine {
                    if originalColumn >= i {
                        caretDeltaForLastLine = token.utf16.count + 1
                    } else {
                        caretDeltaForLastLine = 0
                    }
                }
            }
        }

        let isSelection = range.length > 0
        let newSelectedRange: NSRange

        if isSelection {
            let newLength = newText.utf16.count
            // The selection becomes the touched lines' post-edit whole-line span
            // with the final terminator excluded; the edit never rewrites
            // terminators, so the last line's original terminator length still
            // holds post-edit.
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
                // A terminator-less last line, so newText is pure content.
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
                // Post-edit, the next line starts right after the replacement.
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

    private static func toggleBlockComment(
        text: NSString,
        lines: [LineInfo],
        open: String,
        close: String,
        range: NSRange,
        touchedSpan: NSRange
    ) -> CommentToggleEdit? {
        let nonBlankIndices = lines.enumerated().filter { !$0.element.isBlank }.map { $0.offset }
        guard let firstIdx = nonBlankIndices.first, let lastIdx = nonBlankIndices.last else { return nil }

        let firstLine = lines[firstIdx]
        let lastLine = lines[lastIdx]

        let firstContentStr = (firstLine.content as NSString).substring(to: firstLine.contentsEnd - firstLine.start)
        let lastContentStr = (lastLine.content as NSString).substring(to: lastLine.contentsEnd - lastLine.start)

        let firstTrimmed = firstContentStr.trimmingCharacters(in: .whitespaces)
        let lastTrimmed = lastContentStr.trimmingCharacters(in: .whitespaces)

        let shouldUnwrap: Bool
        if firstIdx == lastIdx {
            let hasDelims = firstTrimmed.hasPrefix(open) && lastTrimmed.hasSuffix(close)
            shouldUnwrap = hasDelims && firstTrimmed.count >= open.count + close.count
        } else {
            shouldUnwrap = firstTrimmed.hasPrefix(open) && lastTrimmed.hasSuffix(close)
        }

        let originalColumn = range.length == 0 ? range.location - lines[0].start : 0
        let (newText, caretDelta) = shouldUnwrap
            ? unwrapBlock(lines: lines, firstIdx: firstIdx, lastIdx: lastIdx, open: open, close: close, originalColumn: originalColumn)
            : wrapBlock(lines: lines, firstIdx: firstIdx, lastIdx: lastIdx, open: open, close: close, originalColumn: originalColumn)

        return buildBlockEdit(newText: newText, caretDelta: caretDelta, text: text,
                              lines: lines, range: range, touchedSpan: touchedSpan)
    }

    private static func unwrapBlock(
        lines: [LineInfo], firstIdx: Int, lastIdx: Int, open: String, close: String, originalColumn: Int
    ) -> (String, Int) {
        var modifiedContents = lines.map { $0.content }
        var caretDelta = 0
        let firstLine = lines[firstIdx]
        let firstNs = firstLine.content as NSString
        let firstTermLength = firstLine.end - firstLine.contentsEnd
        let firstStr = firstNs.substring(to: firstNs.length - firstTermLength)

        var leadingSpacesFirst = "", contentAfterFirst = ""
        var openStartIdx16 = 0
        if let rangeOfOpen = firstStr.range(of: open) {
            openStartIdx16 = firstStr.utf16.distance(from: firstStr.utf16.startIndex, to: rangeOfOpen.lowerBound)
            let openStartIdx = firstStr.distance(from: firstStr.startIndex, to: rangeOfOpen.lowerBound)
            leadingSpacesFirst = String(firstStr.prefix(openStartIdx))
            var rest = String(firstStr[rangeOfOpen.upperBound...])
            if rest.hasPrefix(" ") { rest.removeFirst() }
            contentAfterFirst = rest
        }
        let newFirstContent = leadingSpacesFirst + contentAfterFirst

        if firstIdx == lastIdx {
            var trailingSpacesLast = "", contentBeforeLast = ""
            var closeStartIdx16 = firstStr.utf16.count // fallback
            if let rangeOfClose = contentAfterFirst.range(of: close, options: .backwards) {
                if let origCloseRange = firstStr.range(of: close, options: .backwards) {
                    closeStartIdx16 = firstStr.utf16.distance(from: firstStr.utf16.startIndex, to: origCloseRange.lowerBound)
                }
                let endIdx = contentAfterFirst.distance(
                    from: contentAfterFirst.startIndex, to: rangeOfClose.upperBound
                )
                trailingSpacesLast = String(contentAfterFirst.suffix(contentAfterFirst.count - endIdx))
                var rest = String(contentAfterFirst[..<rangeOfClose.lowerBound])
                if rest.hasSuffix(" ") { rest.removeLast() }
                contentBeforeLast = rest
            }
            let term = firstNs.substring(from: firstLine.contentsEnd - firstLine.start)
            modifiedContents[firstIdx] = leadingSpacesFirst + contentBeforeLast + trailingSpacesLast + term

            if firstLine.isCaretLine {
                let fullDelta = (leadingSpacesFirst + contentBeforeLast + trailingSpacesLast).utf16.count - firstStr.utf16.count
                let openDelta = newFirstContent.utf16.count - firstStr.utf16.count
                if originalColumn > closeStartIdx16 {
                    let newClosePos = (leadingSpacesFirst + contentBeforeLast).utf16.count
                    if originalColumn + fullDelta < newClosePos {
                        caretDelta = newClosePos - originalColumn
                    } else {
                        caretDelta = fullDelta
                    }
                } else if originalColumn > openStartIdx16 {
                    if originalColumn + openDelta < openStartIdx16 {
                        caretDelta = openStartIdx16 - originalColumn
                    } else {
                        caretDelta = openDelta
                    }
                }
            }
        } else {
            let firstTerm = firstNs.substring(from: firstLine.contentsEnd - firstLine.start)
            modifiedContents[firstIdx] = newFirstContent + firstTerm

            let lastLine = lines[lastIdx]
            let lastNs = lastLine.content as NSString
            let lastTermLength = lastLine.end - lastLine.contentsEnd
            let lastStr = lastNs.substring(to: lastNs.length - lastTermLength)

            var trailingSpacesLast = "", contentBeforeLast = ""
            // No caret delta here: a caret target is always a single line, so
            // the multi-line branch only ever serves a selection.
            if let rangeOfClose = lastStr.range(of: close, options: .backwards) {
                let endIdx = lastStr.distance(from: lastStr.startIndex, to: rangeOfClose.upperBound)
                trailingSpacesLast = String(lastStr.suffix(lastStr.count - endIdx))
                var rest = String(lastStr[..<rangeOfClose.lowerBound])
                if rest.hasSuffix(" ") { rest.removeLast() }
                contentBeforeLast = rest
            }
            let lastTerm = lastNs.substring(from: lastLine.contentsEnd - lastLine.start)
            let newLastContent = contentBeforeLast + trailingSpacesLast
            modifiedContents[lastIdx] = newLastContent + lastTerm

        }
        return (modifiedContents.joined(), caretDelta)
    }

    private static func wrapBlock(
        lines: [LineInfo], firstIdx: Int, lastIdx: Int, open: String, close: String, originalColumn: Int
    ) -> (String, Int) {
        var modifiedContents = lines.map { $0.content }
        var caretDelta = 0
        let firstLine = lines[firstIdx]
        let firstNs = firstLine.content as NSString
        let firstTermLength = firstLine.end - firstLine.contentsEnd

        var firstNonSpaceIdx = 0
        while firstNonSpaceIdx < firstNs.length - firstTermLength {
            let unichar = firstNs.character(at: firstNonSpaceIdx)
            if let scalar = Unicode.Scalar(unichar), CharacterSet.whitespaces.contains(scalar) {
                firstNonSpaceIdx += 1
            } else { break }
        }

        let leadingFirst = firstNs.substring(to: firstNonSpaceIdx)
        let restLength = firstNs.length - firstTermLength - firstNonSpaceIdx
        let restFirst = firstNs.substring(with: NSRange(location: firstNonSpaceIdx, length: restLength))
        let newFirstContent = leadingFirst + open + " " + restFirst

        if firstIdx == lastIdx {
            let term = firstNs.substring(from: firstLine.contentsEnd - firstLine.start)
            modifiedContents[firstIdx] = newFirstContent + " " + close + term
            if firstLine.isCaretLine && originalColumn >= firstNonSpaceIdx {
                caretDelta = open.utf16.count + 1
            }
        } else {
            let firstTerm = firstNs.substring(from: firstLine.contentsEnd - firstLine.start)
            modifiedContents[firstIdx] = newFirstContent + firstTerm

            let lastLine = lines[lastIdx]
            let lastNs = lastLine.content as NSString
            let lastTermLength = lastLine.end - lastLine.contentsEnd
            let lastStr = lastNs.substring(to: lastNs.length - lastTermLength)
            let lastTerm = lastNs.substring(from: lastLine.contentsEnd - lastLine.start)
            modifiedContents[lastIdx] = lastStr + " " + close + lastTerm

        }
        return (modifiedContents.joined(), caretDelta)
    }

    private static func buildBlockEdit(
        newText: String, caretDelta: Int, text: NSString, lines: [LineInfo],
        range: NSRange, touchedSpan: NSRange
    ) -> CommentToggleEdit {
        let isSelection = range.length > 0
        let newSelectedRange: NSRange

        if isSelection {
            let newLength = newText.utf16.count
            let originalLastLine = lines.last!
            let originalTerminatorLength = originalLastLine.end - originalLastLine.contentsEnd
            let newSpanLength = newLength - originalTerminatorLength
            newSelectedRange = NSRange(location: touchedSpan.location, length: newSpanLength)
        } else {
            let line = lines[0]
            let originalColumn = range.location - line.start
            let isLastLine = line.end == text.length && line.end == line.contentsEnd

            if isLastLine {
                let newContentLength = newText.utf16.count
                let newColumn = min(max(originalColumn + caretDelta, 0), newContentLength)
                newSelectedRange = NSRange(location: touchedSpan.location + newColumn, length: 0)
            } else {
                var nextLineStart = 0, nextLineEnd = 0, nextLineContentsEnd = 0
                text.getLineStart(&nextLineStart, end: &nextLineEnd, contentsEnd: &nextLineContentsEnd,
                                  for: NSRange(location: line.end, length: 0))
                let nextLineContentLength = nextLineContentsEnd - nextLineStart
                let newColumn = min(originalColumn, nextLineContentLength)
                let nextLineNewStart = touchedSpan.location + newText.utf16.count
                newSelectedRange = NSRange(location: nextLineNewStart + newColumn, length: 0)
            }
        }

        return CommentToggleEdit(replacementRange: touchedSpan, text: newText, selectedRange: newSelectedRange)
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

    func uncommented(token: String) -> (String, Int) {
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

        return (leadingSpaces + rest + terminator, i)
    }
}
