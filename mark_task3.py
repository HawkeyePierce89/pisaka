with open("docs/plans/20260824-toggle-comment-cmd-slash.md", "r") as f:
    content = f.read()

import re

task3_pattern = re.compile(r"(### Task 3:.*?)(### Task 4:)", re.DOTALL)
match = task3_pattern.search(content)

if match:
    task3_text = match.group(1)
    new_task3_text = task3_text.replace("- [ ]", "- [x]")
    content = content[:match.start()] + new_task3_text + content[match.end(1):]
    
with open("docs/plans/20260824-toggle-comment-cmd-slash.md", "w") as f:
    f.write(content)
