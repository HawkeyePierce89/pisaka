import Foundation

/// The editor's change column, answered: the live buffer against the file's
/// `HEAD` text, as hunks plus one marker per ruler line.
///
/// Pure and `Sendable`, so the app's controller runs `compute` on a detached
/// task for drawing and on the main thread for a command — the same answer either
/// way, read off `LineDiff`'s rows through `ChangeHunk` and never a second diff.
public enum GutterChangeModel {
    /// The largest side, in UTF-8 bytes, the column diffs.
    ///
    /// It is `LocalChangesInlineDiff.maxSideBytes`, so a file the Local Changes
    /// panel refuses to diff inline is a file the gutter draws nothing for: one
    /// threshold for "too large to read line by line" across the git surfaces.
    /// Restated rather than referenced so this rule names no panel policy;
    /// `GutterChangeModelTests` pins the two equal.
    public static let maxSideBytes = 1 << 20

    /// The column's answer for `buffer` against `base`.
    ///
    /// No base — an untracked file, a failed or non-text read — is empty, as is
    /// either side over `maxSideBytes`: the column says nothing rather than
    /// something partial. Markers are indexed by ruler line
    /// (`LineStartIndex.offsets(in: buffer)`), so their count always equals the
    /// buffer's ruler line count, even when the answer is empty.
    public static func compute(base: String?, buffer: String) -> GutterChanges {
        let lineCount = LineStartIndex.offsets(in: buffer as NSString).count
        guard let base,
              base.utf8.count <= maxSideBytes,
              buffer.utf8.count <= maxSideBytes else {
            return GutterChanges(hunks: [], lineCount: lineCount)
        }
        let rows = LineDiff.rows(old: base, new: buffer, wordRanges: false)
        return GutterChanges(hunks: ChangeHunk.hunks(from: rows), lineCount: lineCount)
    }
}

/// One `GutterChangeModel` answer: the hunks in order, and their projection onto
/// ruler lines (`ChangeHunk.lineMarkers(for:lineCount:)`).
public struct GutterChanges: Equatable, Sendable {
    public let hunks: [ChangeHunk]
    public let markers: [ChangeLineMarker]

    public init(hunks: [ChangeHunk], lineCount: Int) {
        self.hunks = hunks
        self.markers = ChangeHunk.lineMarkers(for: hunks, lineCount: lineCount)
    }

    /// The hunk a click or the caret on ruler line `line` (0-based) means: the
    /// hunk whose new-side lines contain it, or a deleted hunk anchored at that
    /// line's boundary — after it (`anchor == line`), or before line 1
    /// (`anchor == -1`, asked as line 0). The first in order wins, so line 1
    /// carrying both wedges answers the one above it; a caller that can tell the
    /// two wedges apart (the ruler's hit test) picks by line and half itself.
    public func hunk(atLine line: Int) -> ChangeHunk? {
        hunks.first { hunk in
            if hunk.newLines.contains(line) { return true }
            guard hunk.kind == .deleted else { return false }
            return hunk.anchor == line || (hunk.anchor == -1 && line == 0)
        }
    }
}
