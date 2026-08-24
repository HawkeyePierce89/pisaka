with open("Sources/PisakaCore/ToggleCommentEngine.swift", "r") as f:
    content = f.read()

content = content.replace("let term = firstNs.substring(from: firstLine.contentsEnd - firstLine.start)", "let firstTerm = firstNs.substring(from: firstLine.contentsEnd - firstLine.start)")
content = content.replace("let newFirstLineContent = newFirstContent + term", "let newFirstLineContent = newFirstContent + firstTerm")
content = content.replace("let newFirstLineContent = newFirstContent + close + term", "let newFirstLineContent = newFirstContent + close + firstTerm")

content = content.replace("let term = lastNs.substring(from: lastLine.contentsEnd - lastLine.start)", "let lastTerm = lastNs.substring(from: lastLine.contentsEnd - lastLine.start)")
content = content.replace("let newLastLineContent = contentBeforeLast + trailingSpacesLast + term", "let newLastLineContent = contentBeforeLast + trailingSpacesLast + lastTerm")
content = content.replace("let newLastLineContent = lastStr + close + term", "let newLastLineContent = lastStr + close + lastTerm")

with open("Sources/PisakaCore/ToggleCommentEngine.swift", "w") as f:
    f.write(content)
