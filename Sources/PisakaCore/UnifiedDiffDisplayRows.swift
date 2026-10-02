import Foundation

/// One row the commit dialog's unified diff draws: a file header, a hunk header,
/// or one diff line.
///
/// The two header kinds are **display only**. They carry no `unitIndex`, so no
/// checkbox is drawn beside them and no click on them selects anything. The
/// selection units stay `CommitDiffUnits`' alone.
public enum UnifiedDiffDisplayRow: Equatable {
    /// `--- a/<path>` or `+++ b/<path>`, or `/dev/null` for a missing side.
    case fileHeader(String)
    /// `@@ -a,b +c,d @@`.
    case hunkHeader(String)
    /// One line of the diff, exactly as `CommitDiffUnits.unified(rows:)` built it.
    case line(UnifiedDiffLine)

    /// The line this row draws, or `nil` for a header row.
    public var line: UnifiedDiffLine? {
        if case let .line(line) = self { return line }
        return nil
    }
}

/// Lays a file's unified lines out the way a unified diff reads: two file
/// header rows, then each hunk as an `@@` row followed by its lines.
///
/// Pure and Foundation-only. It reads the lines `CommitDiffUnits.unified(rows:)`
/// returns and changes none of them. The selection units and what a partial
/// commit assembles (`PartialCommitBuilder`) do not depend on this layout.
///
/// **A hunk is a run of changed lines with up to `contextLines` context lines on
/// each side**, git's default of three. Two runs whose gap is at most twice that
/// many context lines share one hunk, so no context line is drawn twice. Context
/// further from every change is not drawn. Changed lines are never dropped.
///
/// **Hunk numbers follow git's rule.** The start of a side is its first line's
/// number in the hunk. For a side with no line in the hunk (a pure addition or
/// removal) it is the number of that side's lines before the hunk, so a new file
/// reads `@@ -0,0 +1,N @@`. The counts are always written, `,1` included.
public enum UnifiedDiffDisplayRows {
    /// git's default context width.
    public static let defaultContextLines = 3

    /// The rows for `file`'s unified `lines`. Empty when `lines` holds no changed
    /// line, because then there is no hunk to draw.
    ///
    /// The old side is `/dev/null` for an added or untracked file and the new
    /// side is `/dev/null` for a deleted one. A rename's old side names its
    /// `oldPath`.
    public static func rows(
        for file: ChangedFile,
        lines: [UnifiedDiffLine],
        contextLines: Int = defaultContextLines
    ) -> [UnifiedDiffDisplayRow] {
        let hunks = hunkRanges(lines, contextLines: max(0, contextLines))
        guard !hunks.isEmpty else { return [] }
        var rows: [UnifiedDiffDisplayRow] = [
            .fileHeader("--- " + oldName(file)),
            .fileHeader("+++ " + newName(file)),
        ]
        // Running counts of each side's lines before the current position, so a
        // side with no line in a hunk can still say where the hunk sits.
        var oldBefore = 0
        var newBefore = 0
        var position = 0
        for hunk in hunks {
            for index in position..<hunk.lowerBound {
                count(lines[index], old: &oldBefore, new: &newBefore)
            }
            var oldCount = 0
            var newCount = 0
            var oldFirst: Int?
            var newFirst: Int?
            for index in hunk {
                let line = lines[index]
                if oldFirst == nil, let number = line.oldNumber { oldFirst = number }
                if newFirst == nil, let number = line.newNumber { newFirst = number }
                count(line, old: &oldCount, new: &newCount)
            }
            let oldStart = oldFirst ?? oldBefore
            let newStart = newFirst ?? newBefore
            rows.append(.hunkHeader("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"))
            rows.append(contentsOf: hunk.map { .line(lines[$0]) })
            oldBefore += oldCount
            newBefore += newCount
            position = hunk.upperBound
        }
        return rows
    }

    /// The index ranges of `lines` each hunk covers, in order.
    static func hunkRanges(_ lines: [UnifiedDiffLine], contextLines: Int) -> [Range<Int>] {
        let changed = lines.indices.filter { lines[$0].kind != .context }
        guard let first = changed.first else { return [] }
        var ranges: [Range<Int>] = []
        var start = first
        var end = first
        for index in changed.dropFirst() {
            // The context lines between two changes are `index - end - 1`; up to
            // twice the context width they all belong to one hunk.
            if index - end - 1 > 2 * contextLines {
                ranges.append(widened(start, end, contextLines, lines.count))
                start = index
            }
            end = index
        }
        ranges.append(widened(start, end, contextLines, lines.count))
        return ranges
    }

    private static func widened(_ start: Int, _ end: Int, _ context: Int, _ count: Int) -> Range<Int> {
        max(0, start - context)..<min(count, end + context + 1)
    }

    private static func count(_ line: UnifiedDiffLine, old: inout Int, new: inout Int) {
        switch line.kind {
        case .context:
            old += 1
            new += 1
        case .removed:
            old += 1
        case .added:
            new += 1
        }
    }

    private static func oldName(_ file: ChangedFile) -> String {
        switch file.status {
        case .added, .untracked: return "/dev/null"
        default: return "a/" + (file.oldPath ?? file.path)
        }
    }

    private static func newName(_ file: ChangedFile) -> String {
        file.status == .deleted ? "/dev/null" : "b/" + file.path
    }
}
