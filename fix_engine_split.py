with open("Sources/PisakaCore/ToggleCommentEngine.swift", "r") as f:
    content = f.read()

import re

# split out the unwrap logic
unwrap_regex = re.compile(r"        if shouldUnwrap \{\n(.*?)        \} else \{", re.DOTALL)
unwrap_match = unwrap_regex.search(content)
if unwrap_match:
    unwrap_body = unwrap_match.group(1)
    
    wrap_regex = re.compile(r"        \} else \{\n(.*?)        \}\n\n        return createBlockEdit\(", re.DOTALL)
    wrap_match = wrap_regex.search(content)
    
    if wrap_match:
        wrap_body = wrap_match.group(1)
        
        # Replace the whole if/else
        new_block = """        let (newLines, caretDeltaForLastLine): ([LineInfo], Int)
        if shouldUnwrap {
            (newLines, caretDeltaForLastLine) = unwrapBlock(lines: lines, firstIdx: firstIdx, lastIdx: lastIdx, open: open, close: close)
        } else {
            (newLines, caretDeltaForLastLine) = wrapBlock(lines: lines, firstIdx: firstIdx, lastIdx: lastIdx, open: open, close: close)
        }
"""
        
        # We need to find the start of the `if shouldUnwrap {` and end of `}` before `return createBlockEdit`.
        replace_regex = re.compile(r"        if shouldUnwrap \{.*?\n        \}\n", re.DOTALL)
        content = replace_regex.sub(new_block, content)
        
        # Now append the helper functions before `createBlockEdit`
        helpers = """
    private static func unwrapBlock(lines: [LineInfo], firstIdx: Int, lastIdx: Int, open: String, close: String) -> ([LineInfo], Int) {
        var newLines = lines
        var caretDeltaForLastLine = 0
        let firstLine = lines[firstIdx]
        let lastLine = lines[lastIdx]
""" + unwrap_body + """        return (newLines, caretDeltaForLastLine)
    }

    private static func wrapBlock(lines: [LineInfo], firstIdx: Int, lastIdx: Int, open: String, close: String) -> ([LineInfo], Int) {
        var newLines = lines
        var caretDeltaForLastLine = 0
        let firstLine = lines[firstIdx]
        let lastLine = lines[lastIdx]
""" + wrap_body + """        return (newLines, caretDeltaForLastLine)
    }
"""
        
        content = content.replace("    private static func createBlockEdit(", helpers + "\n    private static func createBlockEdit(")
        
with open("Sources/PisakaCore/ToggleCommentEngine.swift", "w") as f:
    f.write(content)
