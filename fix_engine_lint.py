with open("Sources/PisakaCore/ToggleCommentEngine.swift", "r") as f:
    content = f.read()

import re

# `let hasDelims = firstTrimmed.hasPrefix(open) && lastTrimmed.hasSuffix(close)\n            shouldUnwrap = hasDelims && firstTrimmed.count >= open.count + close.count`
content = content.replace("shouldUnwrap = hasDelims && firstTrimmed.count >= open.count + close.count", "shouldUnwrap = hasDelims &&\n                firstTrimmed.count >= open.count + close.count")

# Split `toggleBlockComment` by refactoring WRAP logic and UNWRAP logic into separate functions.
def replace_func(match):
    func_body = match.group(0)
    # We will split it into `unwrapBlock` and `wrapBlock`
    # Let's just find `if shouldUnwrap { ... } else { ... }`
    return func_body.replace("if shouldUnwrap {", "if shouldUnwrap {\n            // swiftlint:disable:next function_body_length\n") # Wait, NO NEW IN-FILE DISABLES.
    
content = content.replace("private static func toggleBlockComment(", "private static func toggleBlockComment(\n        text: NSString,\n        lines: [LineInfo],\n        open: String,\n        close: String,\n        range: NSRange,\n        touchedSpan: NSRange\n    ) -> CommentToggleEdit? {\n        let (firstIdx, lastIdx, shouldUnwrap) = analyzeBlock(lines: lines, open: open, close: close)\n        if firstIdx == -1 { return nil }\n\n        let newLinesAndDelta:\n            ([LineInfo], Int)\n        if shouldUnwrap {\n            newLinesAndDelta = unwrapBlock(lines, firstIdx, lastIdx, open, close)\n        } else {\n            newLinesAndDelta = wrapBlock(lines, firstIdx, lastIdx, open, close)\n        }\n\n        return applyBlockEdit(text, lines, newLinesAndDelta.0, newLinesAndDelta.1, range, touchedSpan)\n    }\n\n    private static func analyzeBlock(")

with open("Sources/PisakaCore/ToggleCommentEngine.swift", "w") as f:
    f.write(content)
