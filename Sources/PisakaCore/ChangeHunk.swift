import Foundation

/// What a gutter change marker says about the lines it stands beside: lines the
/// buffer has that `HEAD` does not (`added`), lines `HEAD` has that the buffer
/// does not (`deleted`), or lines both have in a different form (`modified`).
///
/// The one vocabulary of the change column — a hunk's kind, a line's strip and
/// the colour answer (`ChromeColorRole.changeMarkerRole(for:)`) all speak it, so
/// there is no mapping site between two spellings to drift.
public enum ChangeMarkerKind: Equatable, CaseIterable, Sendable {
    case added
    case modified
    case deleted
}

/// One maximal run of changed lines between `HEAD` (the old side) and the live
/// buffer (the new side), read off `LineDiff`'s rows — never a second diff.
///
/// Line indices are 0-based on both sides, in the same line semantics as
/// `LineDiff` (and so `TerminatedLines`): a trailing separator adds no line.
/// - `added`    → `oldLines` empty, `newLines` non-empty.
/// - `deleted`  → `newLines` empty, `oldLines` non-empty; the hunk sits after
///   buffer line `anchor`, and `anchor == -1` means before line 1.
/// - `modified` → both non-empty, with no constraint on their counts.
///
/// `anchor` is `newLines.lowerBound - 1` for every kind — the buffer line just
/// above the hunk — so it is total rather than meaningful only for a deletion.
public struct ChangeHunk: Equatable, Sendable {
    public let kind: ChangeMarkerKind
    public let newLines: Range<Int>
    public let anchor: Int
    public let oldLines: Range<Int>

    public init(kind: ChangeMarkerKind, newLines: Range<Int>, oldLines: Range<Int>) {
        self.kind = kind
        self.newLines = newLines
        self.anchor = newLines.lowerBound - 1
        self.oldLines = oldLines
    }

    /// The hunks of a diff, in order: each maximal run of non-`unchanged` rows,
    /// its kind decided by which sides the run carries. Pure; it does not re-diff.
    ///
    /// Line positions are tracked by counting each side's rows as they pass rather
    /// than read off `DiffLine.number`, because a deleted run carries no new-side
    /// line to say where it sits.
    public static func hunks(from rows: [DiffRow]) -> [ChangeHunk] {
        var hunks: [ChangeHunk] = []
        var oldIndex = 0
        var newIndex = 0
        var runOldStart = 0
        var runNewStart = 0
        var inRun = false

        func closeRun() {
            guard inRun else { return }
            inRun = false
            let oldLines = runOldStart..<oldIndex
            let newLines = runNewStart..<newIndex
            let kind: ChangeMarkerKind
            if oldLines.isEmpty {
                kind = .added
            } else if newLines.isEmpty {
                kind = .deleted
            } else {
                kind = .modified
            }
            hunks.append(ChangeHunk(kind: kind, newLines: newLines, oldLines: oldLines))
        }

        for row in rows {
            if row.kind == .unchanged {
                closeRun()
            } else if !inRun {
                inRun = true
                runOldStart = oldIndex
                runNewStart = newIndex
            }
            if row.left != nil { oldIndex += 1 }
            if row.right != nil { newIndex += 1 }
        }
        closeRun()
        return hunks
    }

    /// The change column's per-line answer, indexed by **ruler line** — one entry
    /// per `LineStartIndex.offsets` element, `lineCount` of them — so the array
    /// rides `LineShift` with its `result.count == newLineStarts.count` invariant.
    ///
    /// A trailing-separator buffer has one more ruler line than diff lines; that
    /// final empty line never carries a strip, though a deletion anchored after
    /// the last real line still sets `deletedBelow` on that real line. A deletion
    /// before line 1 sets `deletedAbove` on index 0 — including in an empty
    /// buffer, whose single ruler line is the only place left to say "HEAD had
    /// lines here". Anything indexing past `lineCount` is dropped rather than
    /// trapped, so a mismatched count draws less, never crashes.
    public static func lineMarkers(for hunks: [ChangeHunk], lineCount: Int) -> [ChangeLineMarker] {
        var markers = [ChangeLineMarker](repeating: ChangeLineMarker(), count: max(lineCount, 0))
        for hunk in hunks {
            switch hunk.kind {
            case .added, .modified:
                for line in hunk.newLines where markers.indices.contains(line) {
                    markers[line].strip = hunk.kind
                }
            case .deleted:
                if hunk.anchor < 0 {
                    if !markers.isEmpty { markers[0].deletedAbove = true }
                } else if markers.indices.contains(hunk.anchor) {
                    markers[hunk.anchor].deletedBelow = true
                }
            }
        }
        return markers
    }
}

/// One ruler line's change marks: an optional strip (`added` or `modified`,
/// never `deleted`) and the two deletion wedges — `deletedBelow`, lines removed
/// after this one, and `deletedAbove`, lines removed before it, which only line 1
/// ever carries (every other "before" is the previous line's "below").
public struct ChangeLineMarker: Equatable, Sendable {
    public var strip: ChangeMarkerKind?
    public var deletedAbove: Bool
    public var deletedBelow: Bool

    public init(strip: ChangeMarkerKind? = nil, deletedAbove: Bool = false, deletedBelow: Bool = false) {
        self.strip = strip
        self.deletedAbove = deletedAbove
        self.deletedBelow = deletedBelow
    }

    /// Whether this line draws anything at all.
    public var isEmpty: Bool {
        strip == nil && !deletedAbove && !deletedBelow
    }
}
