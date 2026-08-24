with open("Sources/PisakaCore/ToggleCommentEngine.swift", "r") as f:
    lines = f.readlines()

import re

for i, line in enumerate(lines):
    if "LineInfo(start: firstLine.start, end: firstLine.end, contentsEnd: firstLine.contentsEnd, content:" in line:
        line = line.replace("LineInfo(start: firstLine.start, end: firstLine.end, contentsEnd: firstLine.contentsEnd, content:", "LineInfo(\n                    start: firstLine.start,\n                    end: firstLine.end,\n                    contentsEnd: firstLine.contentsEnd,\n                    content:")
        line = line.replace(", isCaretLine: firstLine.isCaretLine)", ",\n                    isCaretLine: firstLine.isCaretLine\n                )")
        lines[i] = line
    if "LineInfo(start: lastLine.start, end: lastLine.end, contentsEnd: lastLine.contentsEnd, content:" in line:
        line = line.replace("LineInfo(start: lastLine.start, end: lastLine.end, contentsEnd: lastLine.contentsEnd, content:", "LineInfo(\n                    start: lastLine.start,\n                    end: lastLine.end,\n                    contentsEnd: lastLine.contentsEnd,\n                    content:")
        line = line.replace(", isCaretLine: lastLine.isCaretLine)", ",\n                    isCaretLine: lastLine.isCaretLine\n                )")
        lines[i] = line
    if "let newLineContent = leadingSpacesFirst + contentBeforeLast + trailingSpacesLast + (firstLine.content as NSString).substring(from: firstLine.contentsEnd - firstLine.start)" in line:
        lines[i] = line.replace(
            "let newLineContent = leadingSpacesFirst + contentBeforeLast + trailingSpacesLast + (firstLine.content as NSString).substring(from: firstLine.contentsEnd - firstLine.start)",
            "let term = (firstLine.content as NSString).substring(from: firstLine.contentsEnd - firstLine.start)\n"
            "                let newLineContent = leadingSpacesFirst + contentBeforeLast + trailingSpacesLast + term"
        )
    if "let newFirstLineContent = newFirstContent + firstNs.substring(from: firstLine.contentsEnd - firstLine.start)" in line:
        lines[i] = line.replace(
            "let newFirstLineContent = newFirstContent + firstNs.substring(from: firstLine.contentsEnd - firstLine.start)",
            "let term = firstNs.substring(from: firstLine.contentsEnd - firstLine.start)\n"
            "                let newFirstLineContent = newFirstContent + term"
        )
    if "let newLastLineContent = contentBeforeLast + trailingSpacesLast + lastNs.substring(from: lastLine.contentsEnd - lastLine.start)" in line:
        lines[i] = line.replace(
            "let newLastLineContent = contentBeforeLast + trailingSpacesLast + lastNs.substring(from: lastLine.contentsEnd - lastLine.start)",
            "let term = lastNs.substring(from: lastLine.contentsEnd - lastLine.start)\n"
            "                let newLastLineContent = contentBeforeLast + trailingSpacesLast + term"
        )
    if "let newLineContent = newFirstContent + close + firstNs.substring(from: firstLine.contentsEnd - firstLine.start)" in line:
        lines[i] = line.replace(
            "let newLineContent = newFirstContent + close + firstNs.substring(from: firstLine.contentsEnd - firstLine.start)",
            "let term = firstNs.substring(from: firstLine.contentsEnd - firstLine.start)\n"
            "                let newLineContent = newFirstContent + close + term"
        )
    if "let newLastLineContent = lastStr + close + lastNs.substring(from: lastLine.contentsEnd - lastLine.start)" in line:
        lines[i] = line.replace(
            "let newLastLineContent = lastStr + close + lastNs.substring(from: lastLine.contentsEnd - lastLine.start)",
            "let term = lastNs.substring(from: lastLine.contentsEnd - lastLine.start)\n"
            "                let newLastLineContent = lastStr + close + term"
        )
    if "caretDeltaForLastLine = leadingSpacesFirst.utf16.count + contentAfterFirst.utf16.count - firstStr.utf16.count" in line:
        lines[i] = line.replace(
            "caretDeltaForLastLine = leadingSpacesFirst.utf16.count + contentAfterFirst.utf16.count - firstStr.utf16.count",
            "caretDeltaForLastLine = leadingSpacesFirst.utf16.count + contentAfterFirst.utf16.count\n"
            "                    caretDeltaForLastLine -= firstStr.utf16.count"
        )
    if "let restFirst = firstNs.substring(with: NSRange(location: firstNonSpaceIdx, length: firstNs.length - firstTerminatorLength - firstNonSpaceIdx))" in line:
        lines[i] = line.replace(
            "let restFirst = firstNs.substring(with: NSRange(location: firstNonSpaceIdx, length: firstNs.length - firstTerminatorLength - firstNonSpaceIdx))",
            "let restLength = firstNs.length - firstTerminatorLength - firstNonSpaceIdx\n"
            "            let restFirst = firstNs.substring(with: NSRange(location: firstNonSpaceIdx, length: restLength))"
        )
    if "shouldUnwrap = firstTrimmed.hasPrefix(open) && lastTrimmed.hasSuffix(close) && firstTrimmed.count >= open.count + close.count" in line:
        lines[i] = line.replace(
            "shouldUnwrap = firstTrimmed.hasPrefix(open) && lastTrimmed.hasSuffix(close) && firstTrimmed.count >= open.count + close.count",
            "let hasDelims = firstTrimmed.hasPrefix(open) && lastTrimmed.hasSuffix(close)\n            "
            "shouldUnwrap = hasDelims && firstTrimmed.count >= open.count + close.count"
        )

with open("Sources/PisakaCore/ToggleCommentEngine.swift", "w") as f:
    f.writelines(lines)
