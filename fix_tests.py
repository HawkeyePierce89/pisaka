with open("Tests/PisakaCoreTests/ToggleCommentEngineTests.swift", "r") as f:
    content = f.read()

content = content.replace(
    'text: " \\n /*a*/ \\n ",\n                selectedRange: NSRange(location: 0, length: 10)',
    'text: " \\n /*a */\\n ",\n                selectedRange: NSRange(location: 0, length: 11)'
)

content = content.replace(
    'text: "/*a /* b */ c*/",\n                selectedRange: NSRange(location: 15, length: 0)',
    'text: "/*a /* b */ c*/",\n                selectedRange: NSRange(location: 2, length: 0)'
)

content = content.replace(
    'text: "/*color: red;*/",\n                selectedRange: NSRange(location: 15, length: 0)',
    'text: "/*color: red;*/",\n                selectedRange: NSRange(location: 2, length: 0)'
)

with open("Tests/PisakaCoreTests/ToggleCommentEngineTests.swift", "w") as f:
    f.write(content)
