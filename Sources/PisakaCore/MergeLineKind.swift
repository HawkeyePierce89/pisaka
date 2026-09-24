import Foundation

/// What a line in one of the three merge panes is, for the wash drawn behind it.
///
/// The merge editor's view *derives* which line is which kind from the
/// `MergeDocument` it is showing; Core owns only this vocabulary and the one
/// mapping from it to a chrome role, `ChromeColorRole.mergeWashRole(for:)`.
public enum MergeLineKind: Sendable, CaseIterable {
    /// A line outside every conflict — no wash.
    case plain
    /// A conflicted line on the read-only *ours* pane.
    case ours
    /// A conflicted line on the read-only *theirs* pane.
    case theirs
    /// A result-pane line inside a conflict that is not yet resolved.
    case conflictUnresolved
    /// A result-pane line inside a conflict that has been resolved.
    case conflictResolved
}
