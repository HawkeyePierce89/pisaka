with open('Sources/PisakaCore/ToggleCommentEngine.swift', 'r') as f:
    content = f.read()

# Fix line mode wrap
old_line = '''                if line.isCaretLine && originalColumn > 0 {
                    caretDeltaForLastLine = token.utf16.count
                }'''
new_line = '''                if line.isCaretLine { // originalColumn >= 0 is always true
                    caretDeltaForLastLine = token.utf16.count
                }'''
content = content.replace(old_line, new_line)

# Fix block mode wrap
old_block_wrap1 = '''            if firstLine.isCaretLine && originalColumn > firstNonSpaceIdx { 
                caretDelta = open.utf16.count 
            }'''
new_block_wrap1 = '''            if firstLine.isCaretLine && originalColumn >= firstNonSpaceIdx { 
                caretDelta = open.utf16.count 
            }'''
content = content.replace(old_block_wrap1, new_block_wrap1)

with open('Sources/PisakaCore/ToggleCommentEngine.swift', 'w') as f:
    f.write(content)
