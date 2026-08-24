with open("Sources/PisakaCore/ToggleCommentEngine.swift", "r") as f:
    content = f.read()
    
# Fix line length first
content = content.replace("LineInfo(start: firstLine.start, end: firstLine.end, contentsEnd: firstLine.contentsEnd, content:", "LineInfo(\n                    start: firstLine.start,\n                    end: firstLine.end,\n                    contentsEnd: firstLine.contentsEnd,\n                    content:")
content = content.replace(", isCaretLine: firstLine.isCaretLine)", ",\n                    isCaretLine: firstLine.isCaretLine\n                )")
content = content.replace("LineInfo(start: lastLine.start, end: lastLine.end, contentsEnd: lastLine.contentsEnd, content:", "LineInfo(\n                    start: lastLine.start,\n                    end: lastLine.end,\n                    contentsEnd: lastLine.contentsEnd,\n                    content:")
content = content.replace(", isCaretLine: lastLine.isCaretLine)", ",\n                    isCaretLine: lastLine.isCaretLine\n                )")

content = content.replace("let newLineContent = leadingSpacesFirst + contentBeforeLast + trailingSpacesLast + (firstLine.content as NSString).substring(from: firstLine.contentsEnd - firstLine.start)", "let term = (firstLine.content as NSString).substring(from: firstLine.contentsEnd - firstLine.start)\n                let newLineContent = leadingSpacesFirst + contentBeforeLast + trailingSpacesLast + term")
content = content.replace("let newFirstLineContent = newFirstContent + firstNs.substring(from: firstLine.contentsEnd - firstLine.start)", "let term = firstNs.substring(from: firstLine.contentsEnd - firstLine.start)\n                let newFirstLineContent = newFirstContent + term")
content = content.replace("let newLastLineContent = contentBeforeLast + trailingSpacesLast + lastNs.substring(from: lastLine.contentsEnd - lastLine.start)", "let term = lastNs.substring(from: lastLine.contentsEnd - lastLine.start)\n                let newLastLineContent = contentBeforeLast + trailingSpacesLast + term")
content = content.replace("let newLineContent = newFirstContent + close + firstNs.substring(from: firstLine.contentsEnd - firstLine.start)", "let term = firstNs.substring(from: firstLine.contentsEnd - firstLine.start)\n                let newLineContent = newFirstContent + close + term")
content = content.replace("let newLastLineContent = lastStr + close + lastNs.substring(from: lastLine.contentsEnd - lastLine.start)", "let term = lastNs.substring(from: lastLine.contentsEnd - lastLine.start)\n                let newLastLineContent = lastStr + close + term")
content = content.replace("caretDeltaForLastLine = leadingSpacesFirst.utf16.count + contentAfterFirst.utf16.count - firstStr.utf16.count", "caretDeltaForLastLine = leadingSpacesFirst.utf16.count + contentAfterFirst.utf16.count - firstStr.utf16.count\n")
content = content.replace("let restFirst = firstNs.substring(with: NSRange(location: firstNonSpaceIdx, length: firstNs.length - firstTerminatorLength - firstNonSpaceIdx))", "let restLength = firstNs.length - firstTerminatorLength - firstNonSpaceIdx\n            let restFirst = firstNs.substring(with: NSRange(location: firstNonSpaceIdx, length: restLength))")
content = content.replace("shouldUnwrap = firstTrimmed.hasPrefix(open) && lastTrimmed.hasSuffix(close) && firstTrimmed.count >= open.count + close.count", "let hasDelims = firstTrimmed.hasPrefix(open) && lastTrimmed.hasSuffix(close)\n            shouldUnwrap = hasDelims && firstTrimmed.count >= open.count + close.count")
content = content.replace("shouldUnwrap = hasDelims && firstTrimmed.count >= open.count + close.count", "shouldUnwrap = hasDelims &&\n                firstTrimmed.count >= open.count + close.count")

# Split function
import re

func_regex = re.compile(r"    private static func toggleBlockComment.*?return CommentToggleEdit\([^)]+\)\n    }", re.DOTALL)
match = func_regex.search(content)

if match:
    func_text = match.group(0)
    
    # We will just split `toggleBlockComment` by pulling out the `if isSelection { ... } else { ... } return CommentToggleEdit(...)` part.
    # We'll put it in `createBlockEdit(...)`.
    tail_regex = re.compile(r"        let newText = newLines\.map \{ \$0\.content \}\.joined\(\).*?return CommentToggleEdit\([^)]+\)\n    }", re.DOTALL)
    tail_match = tail_regex.search(func_text)
    
    if tail_match:
        tail_text = tail_match.group(0)
        
        # Replace tail with `return createBlockEdit(text: text, lines: lines, newLines: newLines, touchedSpan: touchedSpan, range: range, caretDeltaForLastLine: caretDeltaForLastLine)\n    }`
        new_func_text = func_text[:tail_match.start()] + "        return createBlockEdit(text: text, lines: lines, newLines: newLines, touchedSpan: touchedSpan, range: range, caretDeltaForLastLine: caretDeltaForLastLine)\n    }"
        
        create_block_edit = """
    private static func createBlockEdit(
        text: NSString,
        lines: [LineInfo],
        newLines: [LineInfo],
        touchedSpan: NSRange,
        range: NSRange,
        caretDeltaForLastLine: Int
    ) -> CommentToggleEdit {
""" + tail_text.replace("    }", "") + "    }"
        
        content = content[:match.start()] + new_func_text + "\n" + create_block_edit + content[match.end():]

with open("Sources/PisakaCore/ToggleCommentEngine.swift", "w") as f:
    f.write(content)
