import Foundation

/// What a project-tree row is currently *showing* — the one answer a row's
/// background is painted from.
///
/// Pure and total: the view layer asks `state(isSelected:isWindowKey:
/// isHovering:isDropTarget:)` and maps the answer to a role, so the precedence
/// between four simultaneously-true facts is stated once, here, and tested,
/// rather than re-derived by every row kind.
public enum TreeRowState: String, CaseIterable, Hashable, Sendable {
    /// Nothing is true of this row.
    case plain
    /// The pointer is inside the row.
    case hover
    /// The row is the active editor tab's file, in a key window.
    case selectedFocused
    /// The same row, in a window that is not key.
    case selectedUnfocused
    /// A drag that would be accepted is hovering this row.
    case dropTarget

    /// The precedence, highest first:
    ///
    /// 1. **drop target** — it answers "will this drop land here?", which is the
    ///    only question the user is asking while a drag is in flight, and hover
    ///    is necessarily true at the same moment (the pointer is inside the row),
    ///    so anything else would hide it;
    /// 2. **selection** — focused or unfocused by whether the window is key;
    ///    a selected row stays legible as selected while the pointer passes over
    ///    it, so selection outranks hover rather than being replaced by it;
    /// 3. **hover**;
    /// 4. **plain**.
    ///
    /// Selection is *derived*, never clicked: a row is selected when it is the
    /// file of the currently active editor tab, and folders are never selected.
    /// "Focused" likewise means the window is key. Both facts are the caller's
    /// to supply; this rule only orders them.
    public static func state(
        isSelected: Bool,
        isWindowKey: Bool,
        isHovering: Bool,
        isDropTarget: Bool
    ) -> TreeRowState {
        if isDropTarget { return .dropTarget }
        if isSelected { return isWindowKey ? .selectedFocused : .selectedUnfocused }
        return isHovering ? .hover : .plain
    }
}
