import Foundation

/// *Revert Change*, answered: the one buffer edit that puts a hunk's `HEAD`
/// lines back, byte for byte, and the caret to leave behind.
///
/// Built from `TerminatedLines` on both sides, so every terminator in the
/// replacement is `HEAD`'s own, verbatim — a revert never normalizes a line
/// ending it was not asked to touch.
///
/// **The range.** A hunk that does not reach the end of the buffer replaces
/// exactly its new-side lines, terminators included, with its old-side lines;
/// a deletion inserts at the start of the line after its anchor (offset 0 for a
/// deletion before line 1). That is enough in the middle of a file, because
/// every line there is terminated on both sides.
///
/// **The end-of-text rule.** At the end it is not: the diff compares lines with
/// their separators stripped, so whether the last line carries a final newline
/// is invisible to the hunk, and a deletion anchored after an unterminated last
/// line would otherwise be glued onto it. So when the hunk reaches the end of
/// the buffer — a strip covering the last line, or a deletion anchored after it —
/// and there is a line before it, the replaced range starts at that preceding
/// line's terminator and the replacement starts with `HEAD`'s terminator for that
/// line. The presence or absence of a final newline comes back exactly, on
/// either side. With no line before it (the hunk is the whole buffer) the range
/// is the whole buffer and the replacement the hunk's whole old side, which
/// carries `HEAD`'s ending already.
///
/// **The caret** goes to the start of the hunk's first line in the resulting
/// text: the first restored line, or for an added hunk the line that now
/// follows the removed ones.
///
/// Pure: it applies nothing, raises no gate and takes no Local History capture —
/// the app applies the plan as one undo step through its edit funnel.
public enum HunkRevertPlan {

    /// The edit reverting `hunk`, or `nil` when the hunk does not fit the two
    /// texts — a stale answer computed against another buffer or base.
    public static func plan(hunk: ChangeHunk, base: String, buffer: String) -> RangeEditPlan? {
        let baseLines = TerminatedLines.ranges(base)
        let bufferLines = TerminatedLines.ranges(buffer)
        let old = hunk.oldLines
        let new = hunk.newLines
        guard old.lowerBound >= 0, old.upperBound <= baseLines.count,
              new.lowerBound >= 0, new.upperBound <= bufferLines.count else { return nil }

        let baseNS = base as NSString
        let bufferLength = (buffer as NSString).length

        // Offset of line `index`'s start, or the text's end past the last line.
        func start(of index: Int, in lines: [TerminatedLineRange], length: Int) -> Int {
            index < lines.count ? lines[index].content.location : length
        }

        var rangeStart = start(of: new.lowerBound, in: bufferLines, length: bufferLength)
        let rangeEnd = start(of: new.upperBound, in: bufferLines, length: bufferLength)
        let oldStart = start(of: old.lowerBound, in: baseLines, length: baseNS.length)
        let oldEnd = start(of: old.upperBound, in: baseLines, length: baseNS.length)
        var replacement = baseNS.substring(with: NSRange(location: oldStart, length: oldEnd - oldStart))
        var caretPrefix = 0

        if new.upperBound == bufferLines.count, new.lowerBound > 0 {
            // The line before the hunk is unchanged (hunks are maximal runs), so
            // it is old line `old.lowerBound - 1` on the HEAD side.
            guard old.lowerBound > 0 else { return nil }
            let headTerminator = baseNS.substring(with: baseLines[old.lowerBound - 1].terminator)
            rangeStart = bufferLines[new.lowerBound - 1].terminator.location
            replacement = headTerminator + replacement
            caretPrefix = (headTerminator as NSString).length
        }

        let edit = IndentReplacement(
            range: NSRange(location: rangeStart, length: rangeEnd - rangeStart),
            replacement: replacement
        )
        return RangeEditPlan(
            edits: [edit],
            selections: [NSRange(location: rangeStart + caretPrefix, length: 0)]
        )
    }
}
