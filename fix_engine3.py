with open("Sources/PisakaCore/ToggleCommentEngine.swift", "r") as f:
    lines = f.read().split("\n")

# Fix 1: leadingSpacesFirst for same line unwrap
for i in range(len(lines)):
    if "let newLineContent = contentBeforeLast + trailingSpacesLast + (firstLine.content as NSString).substring(from: firstLine.contentsEnd - firstLine.start)" in lines[i]:
        lines[i] = lines[i].replace("contentBeforeLast +", "leadingSpacesFirst + contentBeforeLast +")

# Fix 2: caretDeltaForLastLine logic
# For UNWRAP:
# We need to set caretDeltaForLastLine to the change at the start of the first line.
# If firstIdx == lastIdx, we can just use `-(firstLine.content.utf16.count - (firstNs.length - firstTerminatorLength) - leadingSpacesFirst.count - contentAfterFirst.count)`?
# Actually, the removed string at the start is just `(firstNs.length - firstTerminatorLength) - (leadingSpacesFirst.utf16.count + contentAfterFirst.utf16.count)`
# Let's replace:
# `caretDeltaForLastLine = newLineContent.utf16.count - firstLine.content.utf16.count` (in UNWRAP firstIdx == lastIdx)
# with:
# `caretDeltaForLastLine = leadingSpacesFirst.utf16.count + contentAfterFirst.utf16.count - (firstLine.end - firstLine.start - firstTerminatorLength)`
for i in range(len(lines)):
    if "caretDeltaForLastLine = newLineContent.utf16.count - firstLine.content.utf16.count" in lines[i]:
        # we have 4 occurrences (unwrap same, unwrap diff, wrap same, wrap diff)
        pass # we will manually replace below

content = "\n".join(lines)

# Wrap same line delta
content = content.replace(
    "caretDeltaForLastLine = newLineContent.utf16.count - firstLine.content.utf16.count",
    "caretDeltaForLastLine = open.utf16.count",
    1 # only first occurrence? wait, no.
)
