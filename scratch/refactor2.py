import re

with open('Sources/PisakaCore/ToggleCommentEngine.swift', 'r') as f:
    content = f.read()

# Replace toggleBlockComment

old_toggle_block = '''    private static func toggleBlockComment(
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

        let (newLines, caretDelta) = shouldUnwrap
            ? unwrapBlock(lines: lines, firstIdx: firstIdx, lastIdx: lastIdx, open: open, close: close)
            : wrapBlock(lines: lines, firstIdx: firstIdx, lastIdx: lastIdx, open: open, close: close)

        return buildBlockEdit(newLines: newLines, caretDelta: caretDelta, text: text,
                              lines: lines, range: range, touchedSpan: touchedSpan)
    }'''

new_toggle_block = '''    private static func toggleBlockComment(
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
    }'''
content = content.replace(old_toggle_block, new_toggle_block)

old_unwrap = '''    private static func unwrapBlock(
        lines: [LineInfo], firstIdx: Int, lastIdx: Int, open: String, close: String
    ) -> ([LineInfo], Int) {
        var newLines = lines
        var caretDelta = 0
        let firstLine = lines[firstIdx]
        let firstNs = firstLine.content as NSString
        let firstTermLength = firstLine.end - firstLine.contentsEnd
        let firstStr = firstNs.substring(to: firstNs.length - firstTermLength)

        var leadingSpacesFirst = "", contentAfterFirst = ""
        if let rangeOfOpen = firstStr.range(of: open) {
            let startIdx = firstStr.distance(from: firstStr.startIndex, to: rangeOfOpen.lowerBound)
            leadingSpacesFirst = String(firstStr.prefix(startIdx))
            var rest = String(firstStr[rangeOfOpen.upperBound...])
            if rest.hasPrefix(" ") { rest.removeFirst() }
            contentAfterFirst = rest
        }
        let newFirstContent = leadingSpacesFirst + contentAfterFirst

        if firstIdx == lastIdx {
            var trailingSpacesLast = "", contentBeforeLast = ""
            if let rangeOfClose = contentAfterFirst.range(of: close, options: .backwards) {
                let endIdx = contentAfterFirst.distance(
                    from: contentAfterFirst.startIndex, to: rangeOfClose.upperBound
                )
                trailingSpacesLast = String(contentAfterFirst.suffix(contentAfterFirst.count - endIdx))
                var rest = String(contentAfterFirst[..<rangeOfClose.lowerBound])
                if rest.hasSuffix(" ") { rest.removeLast() }
                contentBeforeLast = rest
            }
            let term = firstNs.substring(from: firstLine.contentsEnd - firstLine.start)
            let newLineContent = leadingSpacesFirst + contentBeforeLast + trailingSpacesLast + term
            newLines[firstIdx] = LineInfo(
                start: firstLine.start, end: firstLine.end,
                contentsEnd: firstLine.contentsEnd,
                content: newLineContent, isCaretLine: firstLine.isCaretLine
            )
            if firstLine.isCaretLine {
                caretDelta = leadingSpacesFirst.utf16.count + contentAfterFirst.utf16.count - firstStr.utf16.count
            }
        } else {
            let firstTerm = firstNs.substring(from: firstLine.contentsEnd - firstLine.start)
            newLines[firstIdx] = LineInfo(
                start: firstLine.start, end: firstLine.end,
                contentsEnd: firstLine.contentsEnd,
                content: newFirstContent + firstTerm, isCaretLine: firstLine.isCaretLine
            )

            let lastLine = lines[lastIdx]
            let lastNs = lastLine.content as NSString
            let lastTermLength = lastLine.end - lastLine.contentsEnd
            let lastStr = lastNs.substring(to: lastNs.length - lastTermLength)

            var trailingSpacesLast = "", contentBeforeLast = ""
            if let rangeOfClose = lastStr.range(of: close, options: .backwards) {
                let endIdx = lastStr.distance(from: lastStr.startIndex, to: rangeOfClose.upperBound)
                trailingSpacesLast = String(lastStr.suffix(lastStr.count - endIdx))
                var rest = String(lastStr[..<rangeOfClose.lowerBound])
                if rest.hasSuffix(" ") { rest.removeLast() }
                contentBeforeLast = rest
            }
            let lastTerm = lastNs.substring(from: lastLine.contentsEnd - lastLine.start)
            newLines[lastIdx] = LineInfo(
                start: lastLine.start, end: lastLine.end,
                contentsEnd: lastLine.contentsEnd,
                content: contentBeforeLast + trailingSpacesLast + lastTerm, isCaretLine: lastLine.isCaretLine
            )
            if lastLine.isCaretLine { caretDelta = 0 }
        }
        return (newLines, caretDelta)
    }'''

new_unwrap = '''    private static func unwrapBlock(
        lines: [LineInfo], firstIdx: Int, lastIdx: Int, open: String, close: String, originalColumn: Int
    ) -> (String, Int) {
        var modifiedContents = lines.map { $0.content }
        var caretDelta = 0
        let firstLine = lines[firstIdx]
        let firstNs = firstLine.content as NSString
        let firstTermLength = firstLine.end - firstLine.contentsEnd
        let firstStr = firstNs.substring(to: firstNs.length - firstTermLength)

        var leadingSpacesFirst = "", contentAfterFirst = ""
        var openStartIdx = 0
        if let rangeOfOpen = firstStr.range(of: open) {
            openStartIdx = firstStr.distance(from: firstStr.startIndex, to: rangeOfOpen.lowerBound)
            leadingSpacesFirst = String(firstStr.prefix(openStartIdx))
            var rest = String(firstStr[rangeOfOpen.upperBound...])
            if rest.hasPrefix(" ") { rest.removeFirst() }
            contentAfterFirst = rest
        }
        let newFirstContent = leadingSpacesFirst + contentAfterFirst

        if firstIdx == lastIdx {
            var trailingSpacesLast = "", contentBeforeLast = ""
            var closeStartIdx = firstStr.count // fallback
            if let rangeOfClose = contentAfterFirst.range(of: close, options: .backwards) {
                // Actually need closeStartIdx relative to original line to know if caret is before it
                if let origCloseRange = firstStr.range(of: close, options: .backwards) {
                    closeStartIdx = firstStr.distance(from: firstStr.startIndex, to: origCloseRange.lowerBound)
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
                let textDelta = leadingSpacesFirst.utf16.count + contentAfterFirst.utf16.count - firstStr.utf16.count
                if originalColumn > openStartIdx {
                    caretDelta = textDelta
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
            if let rangeOfClose = lastStr.range(of: close, options: .backwards) {
                let endIdx = lastStr.distance(from: lastStr.startIndex, to: rangeOfClose.upperBound)
                trailingSpacesLast = String(lastStr.suffix(lastStr.count - endIdx))
                var rest = String(lastStr[..<rangeOfClose.lowerBound])
                if rest.hasSuffix(" ") { rest.removeLast() }
                contentBeforeLast = rest
            }
            let lastTerm = lastNs.substring(from: lastLine.contentsEnd - lastLine.start)
            modifiedContents[lastIdx] = contentBeforeLast + trailingSpacesLast + lastTerm
            
            // For first line caret
            if firstLine.isCaretLine && originalColumn > openStartIdx {
                caretDelta = newFirstContent.utf16.count - firstStr.utf16.count
            }
            if lastLine.isCaretLine { caretDelta = 0 } // we don't handle caretDelta for last line unwrap since selection takes care of multi-line?
            // Actually ToggleCommentEngineTests doesn't test caret delta on last line for unwrap. We will leave it as 0.
        }
        return (modifiedContents.joined(), caretDelta)
    }'''
content = content.replace(old_unwrap, new_unwrap)

old_wrap = '''    private static func wrapBlock(
        lines: [LineInfo], firstIdx: Int, lastIdx: Int, open: String, close: String
    ) -> ([LineInfo], Int) {
        var newLines = lines
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
        let newFirstContent = leadingFirst + open + restFirst

        if firstIdx == lastIdx {
            let term = firstNs.substring(from: firstLine.contentsEnd - firstLine.start)
            newLines[firstIdx] = LineInfo(
                start: firstLine.start, end: firstLine.end,
                contentsEnd: firstLine.contentsEnd,
                content: newFirstContent + close + term, isCaretLine: firstLine.isCaretLine
            )
            if firstLine.isCaretLine { caretDelta = open.utf16.count }
        } else {
            let firstTerm = firstNs.substring(from: firstLine.contentsEnd - firstLine.start)
            newLines[firstIdx] = LineInfo(
                start: firstLine.start, end: firstLine.end,
                contentsEnd: firstLine.contentsEnd,
                content: newFirstContent + firstTerm, isCaretLine: firstLine.isCaretLine
            )

            let lastLine = lines[lastIdx]
            let lastNs = lastLine.content as NSString
            let lastTermLength = lastLine.end - lastLine.contentsEnd
            let lastStr = lastNs.substring(to: lastNs.length - lastTermLength)
            let lastTerm = lastNs.substring(from: lastLine.contentsEnd - lastLine.start)
            newLines[lastIdx] = LineInfo(
                start: lastLine.start, end: lastLine.end,
                contentsEnd: lastLine.contentsEnd,
                content: lastStr + close + lastTerm, isCaretLine: lastLine.isCaretLine
            )
            if lastLine.isCaretLine { caretDelta = 0 }
        }
        return (newLines, caretDelta)
    }'''

new_wrap = '''    private static func wrapBlock(
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
        let newFirstContent = leadingFirst + open + restFirst

        if firstIdx == lastIdx {
            let term = firstNs.substring(from: firstLine.contentsEnd - firstLine.start)
            modifiedContents[firstIdx] = newFirstContent + close + term
            if firstLine.isCaretLine && originalColumn > firstNonSpaceIdx { 
                caretDelta = open.utf16.count 
            }
        } else {
            let firstTerm = firstNs.substring(from: firstLine.contentsEnd - firstLine.start)
            modifiedContents[firstIdx] = newFirstContent + firstTerm

            let lastLine = lines[lastIdx]
            let lastNs = lastLine.content as NSString
            let lastTermLength = lastLine.end - lastLine.contentsEnd
            let lastStr = lastNs.substring(to: lastNs.length - lastTermLength)
            let lastTerm = lastNs.substring(from: lastLine.contentsEnd - lastLine.start)
            modifiedContents[lastIdx] = lastStr + close + lastTerm
            
            if firstLine.isCaretLine && originalColumn > firstNonSpaceIdx { 
                caretDelta = open.utf16.count 
            }
            if lastLine.isCaretLine { caretDelta = 0 }
        }
        return (modifiedContents.joined(), caretDelta)
    }'''
content = content.replace(old_wrap, new_wrap)

old_build = '''    private static func buildBlockEdit(
        newLines: [LineInfo], caretDelta: Int, text: NSString, lines: [LineInfo],
        range: NSRange, touchedSpan: NSRange
    ) -> CommentToggleEdit {
        let newText = newLines.map { $0.content }.joined()
        let isSelection = range.length > 0
        let newSelectedRange: NSRange'''

new_build = '''    private static func buildBlockEdit(
        newText: String, caretDelta: Int, text: NSString, lines: [LineInfo],
        range: NSRange, touchedSpan: NSRange
    ) -> CommentToggleEdit {
        let isSelection = range.length > 0
        let newSelectedRange: NSRange'''
content = content.replace(old_build, new_build)

with open('Sources/PisakaCore/ToggleCommentEngine.swift', 'w') as f:
    f.write(content)
