import Foundation
import CoreGraphics

/// A single line's contribution to a column selection, resolved by the view's
/// layout manager.
public struct ColumnSelectionLine: Equatable {
    /// The full character range of the line, including any terminator.
    public var lineRange: NSRange
    /// The UTF-16 character offset for the left edge of the column rectangle on this line.
    public var leftOffset: Int
    /// The UTF-16 character offset for the right edge of the column rectangle on this line.
    public var rightOffset: Int

    public init(lineRange: NSRange, leftOffset: Int, rightOffset: Int) {
        self.lineRange = lineRange
        self.leftOffset = leftOffset
        self.rightOffset = rightOffset
    }
}
public struct ColumnSelectionBounds: Equatable {
    public var left: CGFloat
    public var right: CGFloat
    public var top: CGFloat
    public var bottom: CGFloat
    public var rect: CGRect

    public init(left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat, rect: CGRect) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
        self.rect = rect
    }
}

public enum ColumnSelectionEngine {
    public static func bounds(anchor: CGPoint, head: CGPoint) -> ColumnSelectionBounds {
        let left = min(anchor.x, head.x)
        let right = max(anchor.x, head.x)
        let top = min(anchor.y, head.y)
        let bottom = max(anchor.y, head.y)
        let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        return ColumnSelectionBounds(left: left, right: right, top: top, bottom: bottom, rect: rect)
    }

    /// Turns the layout manager's per-line answers into the ordered `selectedRanges`.
    ///
    /// Trims the trailing line terminator so it is never swallowed (treating CRLF
    /// as a single separator), clamps the resolved offset pair inside that line's
    /// content bounds, orders the pair, and returns the ranges.
    public static func ranges(for lines: [ColumnSelectionLine], in text: NSString) -> [NSRange] {
        let textLength = text.length
        guard !lines.isEmpty else { return [] }

        var result = [NSRange]()
        for line in lines {
            // Assume lineRange is valid and fail fast if it exceeds the text length
            let lineLoc = line.lineRange.location
            let lineMax = NSMaxRange(line.lineRange)
            guard lineMax <= textLength else { continue }

            // Find the content end by trimming the trailing separator
            var contentEnd = lineMax
            if contentEnd > lineLoc {
                let lastChar = text.character(at: contentEnd - 1)
                if LineStartIndex.isLineSeparator(lastChar) {
                    contentEnd -= 1
                    // Handle CRLF
                    if contentEnd > lineLoc,
                       lastChar == 0x0A,
                       text.character(at: contentEnd - 1) == 0x0D {
                        contentEnd -= 1
                    }
                }
            }

            // Clamp offsets to [lineLoc, contentEnd]
            let clampedLeft = max(lineLoc, min(contentEnd, line.leftOffset))
            let clampedRight = max(lineLoc, min(contentEnd, line.rightOffset))

            // Order the pair
            let start = min(clampedLeft, clampedRight)
            let end = max(clampedLeft, clampedRight)

            let range = NSRange(location: start, length: end - start)
            result.append(range)
        }

        result.sort { $0.location < $1.location }

        var deduplicated = [NSRange]()
        var lastAdded: NSRange?

        for r in result where r != lastAdded {
            deduplicated.append(r)
            lastAdded = r
        }

        return deduplicated
    }
}
