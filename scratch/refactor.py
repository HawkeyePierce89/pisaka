import re

with open('Sources/PisakaCore/ToggleCommentEngine.swift', 'r') as f:
    content = f.read()

# Fix 1: uncommented returns tuple
content = content.replace(
'''    func uncommented(token: String) -> String {''',
'''    func uncommented(token: String) -> (String, Int) {''')

content = content.replace(
'''        return leadingSpaces + rest + terminator
    }''',
'''        return (leadingSpaces + rest + terminator, i)
    }''')

# Fix 2: toggleLineComment
old_loop = '''        for line in lines {
            if line.isBlank {
                newText += line.content
                continue
            }
            if allCommented {
                // Uncomment
                let uncommented = line.uncommented(token: token)
                newText += uncommented
                if line.isCaretLine {
                    caretDeltaForLastLine = uncommented.utf16.count - line.content.utf16.count
                }
            } else {
                // Comment
                let commented = token + line.content
                newText += commented
                if line.isCaretLine {
                    caretDeltaForLastLine = token.utf16.count
                }
            }
        }'''

new_loop = '''        let originalColumn = range.length == 0 ? range.location - lines[0].start : 0
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
                    caretDeltaForLastLine = uncommented.utf16.count - line.content.utf16.count
                }
            } else {
                // Comment
                let commented = token + line.content
                newText += commented
                if line.isCaretLine && originalColumn > 0 {
                    caretDeltaForLastLine = token.utf16.count
                }
            }
        }'''

content = content.replace(old_loop, new_loop)

# Let's save and we'll deal with block mode next
with open('Sources/PisakaCore/ToggleCommentEngine.swift', 'w') as f:
    f.write(content)
