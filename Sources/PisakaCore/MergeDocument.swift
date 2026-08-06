import Foundation

/// How one conflict hunk is resolved. `.unresolved` is the initial state (and
/// blocks apply); `.ours`/`.theirs` keep one side; `.bothOursFirst`/
/// `.bothTheirsFirst` concatenate both sides in the chosen order; `.custom`
/// carries the user's edited text for the span (split into logical lines when
/// the resolved text is assembled). Equatable, color/UI-free.
public enum Resolution: Equatable {
    case unresolved
    case ours
    case theirs
    case bothOursFirst
    case bothTheirsFirst
    case custom(String)
}

/// The editable state of a three-way merge: the ordered `[MergeRegion]` from
/// `ThreeWayMerge` plus a per-conflict `Resolution`, indexed in conflict order
/// (the i-th `.conflict` region uses `resolution(at: i)`). `resolvedText`
/// reassembles the document — stable regions verbatim, each conflict's chosen
/// content — joining logical lines with `\n` and reproducing the source's
/// trailing-newline state (`trailingNewline`) so apply writes faithful bytes.
/// Foundation-only, so it lives in `PisakaCore` and is unit-tested like
/// `ThreeWayMerge`.
public struct MergeDocument: Equatable {
    /// The merge regions in document order.
    public let regions: [MergeRegion]
    /// Whether the resolved text ends with a trailing newline (the source's
    /// no-newline-at-EOF state, decided by the loader).
    public let trailingNewline: Bool

    /// Per-conflict resolutions, in conflict order (one entry per `.conflict`
    /// region). Private so it is only mutated through `setResolution`.
    private var conflictResolutions: [Resolution]

    public init(regions: [MergeRegion], trailingNewline: Bool = true) {
        self.regions = regions
        self.trailingNewline = trailingNewline
        let conflictCount = regions.reduce(0) { count, region in
            if case .conflict = region { return count + 1 }
            return count
        }
        self.conflictResolutions = Array(repeating: .unresolved, count: conflictCount)
    }

    /// The number of conflict hunks in the document.
    public var conflictCount: Int { conflictResolutions.count }

    /// The current resolutions, in conflict order.
    public var resolutions: [Resolution] { conflictResolutions }

    /// The resolution of the conflict at `index` (conflict order). Traps on an
    /// out-of-range index (mirroring array subscript); callers pass a valid
    /// conflict index derived from the regions.
    public func resolution(at index: Int) -> Resolution {
        conflictResolutions[index]
    }

    /// Set the resolution of the conflict at `index` (conflict order). An
    /// out-of-range index is ignored, so a stale view index can't trap.
    public mutating func setResolution(_ resolution: Resolution, at index: Int) {
        guard conflictResolutions.indices.contains(index) else { return }
        conflictResolutions[index] = resolution
    }

    /// The number of still-unresolved conflicts.
    public var unresolvedCount: Int {
        conflictResolutions.lazy.filter { $0 == .unresolved }.count
    }

    /// True when every conflict has a resolution other than `.unresolved` (so
    /// the document may be applied).
    public var isFullyResolved: Bool { unresolvedCount == 0 }

    /// The merged document text. Stable regions are emitted verbatim; each
    /// conflict contributes its chosen content (an unresolved conflict emits
    /// git-style two-way markers so a partial result stays faithful and visibly
    /// unresolved). Logical lines join with `\n`, and a trailing `\n` is appended
    /// iff `trailingNewline` and the document is non-empty.
    public var resolvedText: String {
        var lines: [String] = []
        var conflictIndex = 0
        for region in regions {
            switch region {
            case let .stable(stableLines):
                lines.append(contentsOf: stableLines)
            case let .conflict(hunk):
                let resolution = conflictResolutions[conflictIndex]
                conflictIndex += 1
                lines.append(contentsOf: Self.resolvedLines(for: hunk, resolution: resolution))
            }
        }
        guard !lines.isEmpty else { return "" }
        var text = lines.joined(separator: "\n")
        if trailingNewline { text += "\n" }
        return text
    }

    /// The logical lines a conflict contributes to `resolvedText` for a given
    /// resolution. `public` so the view layer's result-pane builder reuses the
    /// exact same marker text / ordering rather than mirroring it (the one
    /// difference the view needs — splitting `.custom` on the literal `\n` the
    /// editable pane inserts, not `LineDiff.splitLines` — it overrides itself).
    public static func resolvedLines(for hunk: ConflictHunk, resolution: Resolution) -> [String] {
        switch resolution {
        case .unresolved:
            return ["<<<<<<< ours"] + hunk.ours + ["======="] + hunk.theirs + [">>>>>>> theirs"]
        case .ours:
            return hunk.ours
        case .theirs:
            return hunk.theirs
        case .bothOursFirst:
            return hunk.ours + hunk.theirs
        case .bothTheirsFirst:
            return hunk.theirs + hunk.ours
        case let .custom(text):
            return LineDiff.splitLines(text)
        }
    }
}
