with open("Sources/PisakaCore/ToggleCommentEngine.swift", "r") as f:
    content = f.read()

content = content.replace(
    "        case .block:\n            // Implemented in Task 3\n            return nil",
    "        case .block(let open, let close):\n            return toggleBlockComment(text: text, lines: lines, open: open, close: close, range: range, touchedSpan: touchedSpan)"
)

with open("toggle_block_comment.swift", "r") as f:
    func_text = f.read()

func_text = func_text.replace("var firstNs", "let firstNs")
func_text = func_text.replace("var firstStr", "let firstStr")
func_text = func_text.replace("var lastStr", "let lastStr")
func_text = func_text.replace("var lastNs", "let lastNs")
func_text = func_text.replace("let terminatorLength = lastLine.content.utf16.count - (lastLine.contentsEnd - lastLine.start)", "")
func_text = func_text.replace("let lastLine = newLines.last!", "")
func_text = func_text.replace("// this is not quite right as the contentsEnd was relative to original, but we didn't update it in LineInfo", "")

lines = content.split("\n")
# find where enum ends
idx = -1
for i, line in enumerate(lines):
    if line.startswith("private struct LineInfo"):
        idx = i - 2
        break

lines.insert(idx, func_text)

with open("Sources/PisakaCore/ToggleCommentEngine.swift", "w") as f:
    f.write("\n".join(lines))
