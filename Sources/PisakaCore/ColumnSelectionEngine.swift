import Foundation
import CoreGraphics

/// Evaluates column selection boundaries and character ranges for the macOS
/// middle-mouse-drag gesture.
///
/// The engine is split into two pure functions to isolate the domain logic from
/// `NSLayoutManager`'s glyph traversal. The first function normalizes an anchor
/// and a head point into ordered horizontal/vertical bounds. The view then probes
/// its layout manager across those bounds (specifically their enclosing `CGRect`),
/// discovering which line fragments intersect the rectangle, and resolving the
/// left and right horizontal bounds into UTF-16 character offsets on each line.
///
/// The second function takes those per-line answers and forms the final ordered
/// `selectedRanges`. It requires the view to supply the character range of each
/// line fragment rather than attempting to infer the line from an offset: a point
/// visually to the right of a short line resolves to an offset past the line's
/// content, and inferring the line from that offset alone would attach the range
/// to the *next* line, colliding with its own entry.
public struct ColumnSelectionBounds: Equatable {
    public var left: CGFloat
    public var right: CGFloat
    public var top: CGFloat
    public var bottom: CGFloat

    /// The enclosing rectangle spanning these bounds. The view uses this to
    /// ask the layout manager for the line fragments to enumerate.
    public var rect: CGRect {
        CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

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

public enum ColumnSelectionEngine {
    /// Normalizes two drag corners (in the text view's coordinate space) into
    /// ordered bounds.
    public static func bounds(anchor: CGPoint, head: CGPoint) -> ColumnSelectionBounds {
        let left = min(anchor.x, head.x)
        let right = max(anchor.x, head.x)
        let top = min(anchor.y, head.y)
        let bottom = max(anchor.y, head.y)
        return ColumnSelectionBounds(left: left, right: right, top: top, bottom: bottom)
    }

    /// Turns the layout manager's per-line answers into the ordered `selectedRanges`.
    ///
    /// Clamps each line range into the text's bounds, trims the trailing line
    /// terminator so it is never swallowed (treating CRLF as a single separator),
    /// clamps the resolved offset pair inside that line's content bounds, orders
    /// the pair, and returns the deduplicated ranges ascending by location.
    public static func ranges(for lines: [ColumnSelectionLine], in text: NSString) -> [NSRange] {
        let textLength = text.length
        guard !lines.isEmpty else { return [] }

        var result = [NSRange]()
        for line in lines {
            // Clamp the reported line range to the text length
            let lineLoc = max(0, min(textLength, line.lineRange.location))
            let lineMax = max(lineLoc, min(textLength, NSMaxRange(line.lineRange)))

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

        // Sort ascending by location, then de-duplicate.
        // AppKit requires ordered, non-overlapping ranges.
        result.sort {
            if $0.location == $1.location {
                return $0.length < $1.length
            }
            return $0.location < $1.location
        }
        var deduplicated = [NSRange]()
        var lastAdded: NSRange?

        for r in result where r != lastAdded {
            deduplicated.append(r)
            lastAdded = r
        }

        return deduplicated
    }
}
