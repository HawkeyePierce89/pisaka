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

/// Pure Toggle Comment (⌘/): which lines gain or lose a comment marker, and
/// where every caret and selection lands afterward.
///
/// **Line-style languages** (`//`, `#`, `--`) decide once for the whole target:
/// when every non-blank touched line already starts with the token after its
/// own indentation, each loses it — plus one following space, so both `//x`
/// and `// x` uncomment — and otherwise every non-blank touched line gains
/// `token + " "`. The marker is **aligned**: it is inserted at the *minimum*
/// leading-whitespace length of the non-blank touched lines, counted in UTF-16
/// units, so a tab counts as one unit like a space. Lines indented 4 and 8 both
/// get `//` at column 4. Uncommenting strips the token after each line's *own*
/// indentation, so the aligned form and the older per-line form (marker after
/// each line's indentation) both uncomment. Blank lines are never touched.
///
/// **Block-style languages** (css, html) wrap the first and last non-blank
/// touched lines in the open/close delimiters, or unwrap them when they are
/// already wrapped.
public enum ToggleCommentEngine {
    /// Compute the comment toggle for `selectedRange` in `text` under `language`.
    ///
    /// Returns `nil` if `language` is `nil`, the language has no comment syntax,
    /// or the target contains no non-blank lines. A `nil` return is a silent no-op
    /// and means no edit *and* no caret move.
    ///
    /// The line-style answer is composed from the multi-range plan for this one
    /// range, so the two entry points cannot drift apart: the replacement covers
    /// the touched lines, and its text is that span with the plan's edits applied.
    public static func toggle(text: NSString, selectedRange: NSRange, language: SyntaxLanguage?) -> CommentToggleEdit? {
        guard let language = language, let style = CommentStyle.style(for: language) else {
            return nil
        }

        let range = clamped(selectedRange, length: text.length)
        let touchedSpan = computeTouchedSpan(text: text, range: range)

        switch style {
        case .line(let token):
            guard let plan = lineToggle(text: text, ranges: [range], token: token),
                  let selection = plan.selections.first else { return nil }
            let span = NSMutableString(string: text.substring(with: touchedSpan))
            for edit in plan.edits.reversed() {
                let local = NSRange(location: edit.range.location - touchedSpan.location, length: edit.range.length)
                span.replaceCharacters(in: local, with: edit.replacement)
            }
            return CommentToggleEdit(replacementRange: touchedSpan, text: span as String, selectedRange: selection)
        case .block(let open, let close):
            let lines = lineInfos(text: text, span: touchedSpan, range: range)
            return toggleBlockComment(text: text, lines: lines, open: open, close: close, range: range, touchedSpan: touchedSpan)
        }
    }

    /// Toggle the comment state of every line any of `selectedRanges` touches,
    /// as one plan — so several carets, a column selection and disjoint
    /// selections all comment in one undo step.
    ///
    /// `style` overrides the language's own style when given (the contextual
    /// style a caller resolved); `nil` reads `CommentStyle.style(for:)`. Returns
    /// `nil` — a silent no-op — when there is no style or no non-blank line to
    /// act on.
    ///
    /// Touched lines follow `BlockIndentEngine`'s rule (a non-empty range ending
    /// exactly at a line start does not touch that line), and lines touched by
    /// several ranges are touched once.
    ///
    /// - **Line style**: the line set is the union across every range, and one
    ///   all-commented decision and one alignment column apply across that
    ///   union. Every edit is per line: a zero-length insertion of
    ///   `token + " "`, or the deletion of the token plus an optional space.
    /// - **Block style**: the touched lines are merged into contiguous line
    ///   blocks, and each block is wrapped — or unwrapped when already wrapped —
    ///   separately, one replacement per block, all in one plan.
    ///
    /// Selections are mapped through the plan with the single-range rules: a
    /// selection becomes its touched lines' post-edit span, terminator of the
    /// last excluded; a caret moves to the next line at the same column
    /// (clamped), or — on a terminator-less last line — stays on its line,
    /// following its text. Identical results collapse into one. With one range
    /// the answer equals `toggle(text:selectedRange:language:)`'s text and
    /// selection.
    public static func toggle(
        text: NSString,
        selectedRanges: [NSRange],
        language: SyntaxLanguage?,
        style: CommentStyle? = nil
    ) -> RangeEditPlan? {
        let ranges = selectedRanges.map { clamped($0, length: text.length) }
        guard !ranges.isEmpty, let style = style ?? language.flatMap(CommentStyle.style(for:)) else { return nil }
        switch style {
        case .line(let token):
            return lineToggle(text: text, ranges: ranges, token: token)
        case .block(let open, let close):
            return blockToggle(text: text, ranges: ranges, open: open, close: close)
        }
    }

    // MARK: - Line style

    private static func lineToggle(text: NSString, ranges: [NSRange], token: String) -> RangeEditPlan? {
        let lines = BlockIndentEngine.Lines(text: text)
        let nonBlank = BlockIndentEngine.touchedLines(lines: lines, ranges: ranges).filter { !lines.isBlank($0) }
        guard let firstLine = nonBlank.first else { return nil }

        let tokenLength = (token as NSString).length
        let isCommented: (Int) -> Bool = { line in
            let start = lines.start(of: line) + indentation(text: text, lines: lines, line: line)
            guard start + tokenLength <= lines.contentsEnd(of: line) else { return false }
            return text.substring(with: NSRange(location: start, length: tokenLength)) == token
        }

        var edits: [IndentReplacement] = []
        if nonBlank.allSatisfy(isCommented) {
            for line in nonBlank {
                let start = lines.start(of: line) + indentation(text: text, lines: lines, line: line)
                var length = tokenLength
                if start + length < lines.contentsEnd(of: line), text.character(at: start + length) == 0x20 {
                    length += 1
                }
                edits.append(IndentReplacement(range: NSRange(location: start, length: length), replacement: ""))
            }
        } else {
            let column = nonBlank.reduce(indentation(text: text, lines: lines, line: firstLine)) {
                min($0, indentation(text: text, lines: lines, line: $1))
            }
            for line in nonBlank {
                let location = lines.start(of: line) + column
                edits.append(IndentReplacement(range: NSRange(location: location, length: 0), replacement: token + " "))
            }
        }

        guard let shell = RangeEditPlan(edits: edits, selections: []) else { return nil }
        var selections: [NSRange] = []
        for range in ranges {
            let selection = mappedSelection(range, text: text, lines: lines, plan: shell)
            if !selections.contains(selection) { selections.append(selection) }
        }
        return RangeEditPlan(edits: edits, selections: selections)
    }

    /// Where one range lands after the toggle, by the single-range rules.
    private static func mappedSelection(
        _ range: NSRange, text: NSString, lines: BlockIndentEngine.Lines, plan: RangeEditPlan
    ) -> NSRange {
        let first = lines.index(of: range.location)
        if range.length > 0 {
            var last = lines.index(of: NSMaxRange(range))
            if NSMaxRange(range) == lines.start(of: last) { last = max(first, last - 1) }
            let start = plan.mapped(offset: lines.start(of: first), bias: .before)
            let end = plan.mapped(offset: lines.contentsEnd(of: last), bias: .before)
            return NSRange(location: start, length: max(0, end - start))
        }
        let column = range.location - lines.start(of: first)
        let isLastLine = first == lines.starts.count - 1 && lines.contentsEnd(of: first) == text.length
        if isLastLine {
            return NSRange(location: plan.mapped(offset: range.location, bias: .after), length: 0)
        }
        let next = first + 1
        let nextColumn = min(column, lines.contentsEnd(of: next) - lines.start(of: next))
        return NSRange(location: plan.mapped(offset: lines.start(of: next) + nextColumn, bias: .after), length: 0)
    }

    /// The line's leading-whitespace length in UTF-16 units: a tab is one unit.
    private static func indentation(text: NSString, lines: BlockIndentEngine.Lines, line: Int) -> Int {
        let start = lines.start(of: line)
        let end = lines.contentsEnd(of: line)
        var offset = start
        while offset < end,
              let scalar = Unicode.Scalar(text.character(at: offset)),
              CharacterSet.whitespaces.contains(scalar) {
            offset += 1
        }
        return offset - start
    }

    // MARK: - Block style

    /// One wrap or unwrap per contiguous block of touched lines.
    ///
    /// A block holding exactly one range is answered by the single-range block
    /// toggle with that range, so its edit and selection are the single-range
    /// ones; a block several ranges merged into is answered as one selection
    /// over the whole block, and leaves that one selection behind.
    private static func blockToggle(text: NSString, ranges: [NSRange], open: String, close: String) -> RangeEditPlan? {
        let lines = BlockIndentEngine.Lines(text: text)
        let touched = BlockIndentEngine.touchedLines(lines: lines, ranges: ranges)
        var blocks: [ClosedRange<Int>] = []
        for line in touched {
            if let last = blocks.last, last.upperBound + 1 == line {
                blocks[blocks.count - 1] = last.lowerBound...line
            } else {
                blocks.append(line...line)
            }
        }

        var edits: [IndentReplacement] = []
        var selections: [NSRange] = []
        var shift = 0
        for block in blocks {
            let spanStart = lines.start(of: block.lowerBound)
            let spanEnd = block.upperBound + 1 < lines.starts.count ? lines.start(of: block.upperBound + 1) : text.length
            let span = NSRange(location: spanStart, length: spanEnd - spanStart)
            let members = ranges.filter { block.contains(lines.index(of: $0.location)) }
            let range = members.count == 1 ? members[0] : span
            let infos = lineInfos(text: text, span: span, range: range)
            guard let edit = toggleBlockComment(
                text: text, lines: infos, open: open, close: close, range: range, touchedSpan: span
            ) else { continue }
            edits.append(IndentReplacement(range: edit.replacementRange, replacement: edit.text))
            let selection = NSRange(location: edit.selectedRange.location + shift, length: edit.selectedRange.length)
            if !selections.contains(selection) { selections.append(selection) }
            shift += (edit.text as NSString).length - edit.replacementRange.length
        }
        guard !edits.isEmpty else { return nil }
        return RangeEditPlan(edits: edits, selections: selections)
    }

    /// Split `span`, a run of whole lines, into the block toggle's line records.
    private static func lineInfos(text: NSString, span: NSRange, range: NSRange) -> [LineInfo] {
        var lines: [LineInfo] = []
        var currentIndex = span.location
        repeat {
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
        } while currentIndex < NSMaxRange(span)
        return lines
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
}
