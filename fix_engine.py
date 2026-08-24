import re

with open("Sources/PisakaCore/ToggleCommentEngine.swift", "r") as f:
    content = f.read()

# Remove the function if it's there
content = re.sub(r'    private static func toggleBlockComment.*?return CommentToggleEdit\([^)]+\)\n    }\n', '', content, flags=re.DOTALL)
# Also remove the extraneous '}' at top level
content = content.replace("}\n}\n\nprivate struct LineInfo {", "}\n\nprivate struct LineInfo {")

with open("toggle_block_comment.swift", "r") as f:
    func_text = f.read()

# Replace variables to `let` as requested
func_text = func_text.replace("var firstNs", "let firstNs")
func_text = func_text.replace("var firstStr", "let firstStr")
func_text = func_text.replace("var lastStr", "let lastStr")
func_text = func_text.replace("var lastNs", "let lastNs")
func_text = func_text.replace("let terminatorLength = lastLine.content.utf16.count - (lastLine.contentsEnd - lastLine.start)", "")
func_text = func_text.replace("// this is not quite right as the contentsEnd was relative to original, but we didn't update it in LineInfo\n", "")

# insert func_text before the last '}' of ToggleCommentEngine
parts = content.split("private struct LineInfo {")
enum_part = parts[0]
last_brace_idx = enum_part.rfind("}")
if last_brace_idx != -1:
    new_enum_part = enum_part[:last_brace_idx] + func_text + "\n" + enum_part[last_brace_idx:]
    content = new_enum_part + "private struct LineInfo {" + parts[1]

with open("Sources/PisakaCore/ToggleCommentEngine.swift", "w") as f:
    f.write(content)
