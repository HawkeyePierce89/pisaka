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
}

public enum ColumnSelectionEngine {
    public static func bounds(anchor: CGPoint, head: CGPoint) -> ColumnSelectionBounds {
        let left = min(anchor.x, head.x)
        let right = max(anchor.x, head.x)
        let top = min(anchor.y, head.y)
        let bottom = max(anchor.y, head.y)
        return ColumnSelectionBounds(
            left: left,
            right: right,
            top: top,
            bottom: bottom,
            rect: CGRect(x: left, y: top, width: right - left, height: bottom - top)
        )
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
            let lineLoc = line.lineRange.location
            guard lineLoc != NSNotFound, lineLoc >= 0, lineLoc <= textLength, line.lineRange.length >= 0 else { continue }

            let lineMax = NSMaxRange(line.lineRange)
            let clampedLineMax = min(textLength, lineMax)

            var contentsEnd = 0
            text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: lineLoc, length: 0))
            let contentEnd = min(clampedLineMax, contentsEnd)

            // Clamp offsets to [lineLoc, contentEnd]
            let clampedLeft = max(lineLoc, min(contentEnd, line.leftOffset))
            let clampedRight = max(lineLoc, min(contentEnd, line.rightOffset))

            // Order the pair
            let start = min(clampedLeft, clampedRight)
            let end = max(clampedLeft, clampedRight)

            let range = NSRange(location: start, length: end - start)
            result.append(range)
        }

        // Sort by location, then length to guarantee deterministic ordering
        result.sort {
            if $0.location != $1.location {
                return $0.location < $1.location
            }
            return $0.length < $1.length
        }

        var deduplicated = [NSRange]()
        for r in result {
            if let last = deduplicated.last {
                let lastMax = NSMaxRange(last)
                // `setSelectedRanges` requires ordered, non-overlapping ranges, so
                // anything overlapping or contiguous is merged into its predecessor.
                if r.location <= lastMax {
                    let rMax = NSMaxRange(r)
                    if rMax > lastMax {
                        deduplicated[deduplicated.count - 1] = NSRange(location: last.location, length: rMax - last.location)
                    }
                    continue
                }
            }
            deduplicated.append(r)
        }

        return deduplicated
    }
}
