import Foundation
import CoreGraphics

/// Evaluates column (rectangular) selections during a middle-mouse drag.
///
/// The engine separates visual geometry from textual boundaries: it first normalizes
/// arbitrary drag corners into a probe rectangle (`bounds`), and then resolves the
/// line fragments' raw layout answers into a valid array of textual `selectedRanges`
/// (`ranges(for:in:)`).
///
/// The view layer supplies each line's exact character range directly from its glyph
/// fragment, rather than letting the engine infer it from an offset. A coordinate to
/// the right of a short line resolves to an offset past its content, which migh
/// structurally belong to the next line; passing the line range directly ensures
/// the range remains bound to the physical line the pointer was over.
public struct ColumnSelectionBounds: Equatable {
    public let left: CGFloa
    public let right: CGFloa
    public let top: CGFloa
    public let bottom: CGFloa
    public let rect: CGRec
}

public struct ColumnSelectionLine: Equatable {
    public let lineRange: NSRange
    public let leftOffset: In
    public let rightOffset: In

    public init(lineRange: NSRange, leftOffset: Int, rightOffset: Int) {
        self.lineRange = lineRange
        self.leftOffset = leftOffse
        self.rightOffset = rightOffse
    }
}

public enum ColumnSelectionEngine {

    /// Normalizes a drag between any two points into an ordered set of edges and the
    /// enclosing rectangle to be probed.
    public static func bounds(anchor: CGPoint, head: CGPoint) -> ColumnSelectionBounds {
        let left = min(anchor.x, head.x)
        let right = max(anchor.x, head.x)
        let top = min(anchor.y, head.y)
        let bottom = max(anchor.y, head.y)

        let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)

        return ColumnSelectionBounds(
            left: left,
            right: right,
            top: top,
            bottom: bottom,
            rect: rec
        )
    }

    /// Resolves layout offsets into standard selection ranges.
    ///
    /// Trims line separators (so a trailing newline is never swallowed), clamps
    /// each range to its line's content length, orders reversed drags, and returns
    /// sorted, de-duplicated ranges.
    public static func ranges(for lines: [ColumnSelectionLine], in text: NSString) -> [NSRange] {
        guard !lines.isEmpty else { return [] }

        let textLength = text.length
        var resultRanges = [NSRange]()

        for line in lines {
            // Clamp lineRange to valid text bounds
            let safeLineLoc = min(max(line.lineRange.location, 0), textLength)
            let safeLineLen = min(max(line.lineRange.length, 0), textLength - safeLineLoc)
            let safeLineRange = NSRange(location: safeLineLoc, length: safeLineLen)

            // Trim terminator
            var contentEnd = safeLineLoc + safeLineLen
            if contentEnd > safeLineLoc {
                let lastChar = text.character(at: contentEnd - 1)
                if LineStartIndex.isLineSeparator(lastChar) {
                    contentEnd -= 1
                    // Handle CRLF
                    if contentEnd > safeLineLoc {
                        let secondToLast = text.character(at: contentEnd - 1)
                        if secondToLast == 0x0D && lastChar == 0x0A {
                            contentEnd -= 1
                        }
                    }
                }
            }

            // Clamp offsets inside [safeLineLoc, contentEnd]
            let left = min(max(line.leftOffset, safeLineLoc), contentEnd)
            let right = min(max(line.rightOffset, safeLineLoc), contentEnd)

            let start = min(left, right)
            let end = max(left, right)

            resultRanges.append(NSRange(location: start, length: end - start))
        }

        // Sort and deduplicate
        resultRanges.sort { $0.location < $1.location }

        var uniqueRanges = [NSRange]()
        for r in resultRanges {
            if uniqueRanges.isEmpty || uniqueRanges.last! != r {
                uniqueRanges.append(r)
            }
        }

        return uniqueRanges
    }
}
