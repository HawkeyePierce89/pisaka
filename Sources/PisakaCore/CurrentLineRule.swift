import Foundation

/// Which line the editor's current-line highlight washes, if any.
///
/// Pure, so every case is pinned here rather than in the two painters — the
/// layout manager's full-width band and the gutter's — which read one answer
/// and therefore can never disagree about the line:
/// - a caret highlights the line holding it;
/// - a selection within one line still highlights that line;
/// - a selection spanning more than one line highlights nothing, because the
///   selection itself already says where the user is;
/// - a selection ending exactly at the start of the next line — a whole line
///   selected together with its separator — covers one line, since its last
///   character is that line's separator;
/// - the trailing empty line of a document ending in a separator, and the one
///   line of an empty document, are lines like any other: the answer is the
///   zero-length range at their start.
///
/// `lineStarts` is `LineStartIndex.offsets(in:)`'s table — ascending, starting at
/// 0, with a trailing entry at `length` when the text ends in a separator — so
/// the line is split by the same six separators the gutter numbers by. A line's
/// range runs from its start to the next line's start, separator included; the
/// last line runs to `length`. Offsets outside the text clamp into it, so a stale
/// selection never answers a range past the end.
public enum CurrentLineRule {
    /// The UTF-16 range of the line holding the caret, or `nil` when `selection`
    /// spans more than one line.
    public static func highlightedLine(selection: NSRange, lineStarts: [Int], length: Int) -> NSRange? {
        let length = max(0, length)
        guard !lineStarts.isEmpty else { return NSRange(location: 0, length: length) }
        let start = min(max(0, selection.location), length)
        let end = min(max(start, NSMaxRange(selection)), length)
        let first = lineIndex(of: start, in: lineStarts)
        let last = end > start ? lineIndex(of: end - 1, in: lineStarts) : first
        guard first == last else { return nil }
        let lineStart = min(lineStarts[first], length)
        let lineEnd = first + 1 < lineStarts.count ? min(lineStarts[first + 1], length) : length
        return NSRange(location: lineStart, length: max(0, lineEnd - lineStart))
    }

    /// The index of the line holding `offset`: the last start at or before it,
    /// by binary search, so a caret move costs O(log lines).
    static func lineIndex(of offset: Int, in lineStarts: [Int]) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return max(0, low - 1)
    }
}
