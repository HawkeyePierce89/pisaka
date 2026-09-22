import Foundation

/// A semantic colour role of the application chrome — everything drawn *around*
/// the code, never the code itself.
///
/// `PisakaCore` stays colour-free (the `FileIconColor` precedent): a role names
/// a *meaning*, and the view layer's `ChromePalette` is the one place that turns
/// a meaning into a concrete colour. A chrome view therefore never spells a
/// colour; it spells a role.
///
/// **The set is closed.** These 21 roles are the whole vocabulary of the chrome,
/// and the surface-by-surface sweep that follows adds *views*, never roles: a
/// surface that appears to need a twenty-second role has instead found a design
/// question, and the answer is to reuse one of these or to change the design —
/// not to grow the table. Some roles are consequently still unused after the
/// twelve surfaces restyled so far — six of them (`bgPopover`, `currentLine`,
/// `bracketMatch`, `diffAddedBackground`, `diffRemovedBackground`,
/// `conflictBackground`), each waiting for the surface that means it: the
/// popovers, the code zone's two line overlays, and the diff and merge panes.
/// They are declared here nonetheless, because the table is the design, not an
/// inventory of today's call sites.
///
/// The raw values are the stable names the gating suite and the palette test
/// speak; they are not persisted anywhere, but renaming one is a documentation
/// change as much as a code change.
public enum ChromeColorRole: String, CaseIterable, Hashable, Sendable {
    // MARK: Backgrounds

    /// The window's own ground, behind everything that has no surface of its
    /// own: the space around the panes, an empty pane's backdrop.
    case bgCanvas
    /// A dockable panel's background: the bottom dock, the side panels, the
    /// project tree, a thin horizontal bar.
    case bgPanel
    /// The editor's own background — and the gutter's, so the two agree.
    case bgEditor
    /// A floating surface drawn above everything: a popover, a completion panel.
    case bgPopover

    // MARK: Text

    /// Chrome text at full weight: an active tab's label, a field's content.
    case textPrimary
    /// Chrome text that is present but not the subject: an inactive tab's label,
    /// a line number, an icon drawn monochrome, a caption.
    case textSecondary
    /// Text and glyphs drawn *on* the accent at full strength, where the
    /// chrome's own text colours would be unreadable.
    case onAccent

    // MARK: Lines and accent

    /// The one-pixel rule that separates two chrome zones.
    case hairline
    /// The accent at full strength: an active tab's underline, a focus ring.
    case accent
    /// The accent as a wash, for a surface that is merely *marked*.
    case accentTint
    /// The accent as a stronger wash: a selected row in a key window.
    case accentTintStrong

    // MARK: Row and line states

    /// The wash a row takes while the pointer is inside it.
    case hoverTint
    /// A selected row in a window that is not key — selection without focus.
    case selectionInactive
    /// The line the caret is on, washed so it can be found at a glance.
    case currentLine
    /// The pair of brackets the caret sits between.
    case bracketMatch

    // MARK: Status

    /// Success.
    case statusGreen
    /// An error, a failure, a refused input.
    case statusRed
    /// A warning.
    case statusYellow

    // MARK: Diff and merge

    /// A line present only on the right-hand side of a diff.
    case diffAddedBackground
    /// A line present only on the left-hand side of a diff.
    case diffRemovedBackground
    /// A conflicted region in the merge editor.
    case conflictBackground
}
