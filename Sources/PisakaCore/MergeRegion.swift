import Foundation

/// A single unresolved three-way conflict: the three versions of one base span,
/// each as logical lines (separator-stripped, like the editor's lines — see
/// `LineDiff.splitLines`). A side is an empty array when it is empty there:
/// `base == []` is an add/add (no common ancestor for the span); `ours == []`
/// or `theirs == []` is a modify/delete (one side removed what the other
/// changed). Color/UI-free, so it lives in `PisakaCore`.
public struct ConflictHunk: Equatable {
    public let base: [String]
    public let ours: [String]
    public let theirs: [String]

    public init(base: [String], ours: [String], theirs: [String]) {
        self.base = base
        self.ours = ours
        self.theirs = theirs
    }
}

/// One region of a three-way merge, in document order.
///
/// `.stable` is content that needs no decision — identical in all three, or
/// changed by only one side (auto-merged to that side's content), or changed
/// identically by both. Its `[String]` is the final logical lines verbatim.
/// `.conflict` is a span both sides changed differently; the view layer lets the
/// user pick ours/theirs/both or edit it. Equatable, color-free.
public enum MergeRegion: Equatable {
    case stable([String])
    case conflict(ConflictHunk)
}
