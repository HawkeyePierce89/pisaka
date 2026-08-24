import re
with open("Sources/PisakaCore/ToggleCommentEngine.swift", "r") as f:
    content = f.read()

content = re.sub(r'    private static func toggleBlockComment.*?return CommentToggleEdit\([^)]+\)\n    }\n', '', content, flags=re.DOTALL)

with open("toggle_block_comment.swift", "r") as f:
    func_text = f.read()

parts = content.split("private struct LineInfo {")
enum_part = parts[0]
last_brace_idx = enum_part.rfind("}")
if last_brace_idx != -1:
    new_enum_part = enum_part[:last_brace_idx] + func_text + "\n" + enum_part[last_brace_idx:]
    content = new_enum_part + "private struct LineInfo {" + parts[1]

with open("Sources/PisakaCore/ToggleCommentEngine.swift", "w") as f:
    f.write(content)
