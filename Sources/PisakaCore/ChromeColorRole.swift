import Foundation

/// A semantic colour role of the application chrome — everything drawn *around*
/// the code, never the code itself.
///
/// `PisakaCore` stays colour-free (the `FileIconColor` precedent): a role names
/// a *meaning*, and the view layer's `ChromePalette` is the one place that turns
/// a meaning into a concrete colour. A chrome view therefore never spells a
/// colour; it spells a role.
///
/// **The set is closed.** These 22 roles are the whole vocabulary of the chrome,
/// and the surface-by-surface sweep that follows adds *views*, never roles: a
/// surface that appears to need a twenty-third role has instead found a design
/// question, and the answer is to reuse one of these or to change the design —
/// not to grow the table. Some roles are consequently unused by the three
/// surfaces restyled first (`bgPopover`, `conflictBackground`,
/// `diffAddedBackground`, `diffRemovedBackground`, `statusGreen`, `textTertiary`,
/// `accentTint`, `bgSidebar`, `bgBar`); they are declared here nonetheless,
/// because the table is the design, not an inventory of today's call sites.
///
/// The raw values are the stable names the gating suite and the palette test
/// speak; they are not persisted anywhere, but renaming one is a documentation
/// change as much as a code change.
public enum ChromeColorRole: String, CaseIterable, Hashable, Sendable {
    // MARK: Backgrounds

    /// The editor's own background — and the gutter's, so the two agree.
    case bgEditor
    /// A dockable panel's background (the bottom dock, the side panels).
    case bgPanel
    /// The project tree's background.
    case bgSidebar
    /// A thin horizontal bar: the breadcrumb, the bottom bar.
    case bgBar
    /// A floating surface drawn above everything: a popover, a completion panel.
    case bgPopover

    // MARK: Text

    /// Chrome text at full weight: an active tab's label, a field's content.
    case textPrimary
    /// Chrome text that is present but not the subject: an inactive tab's label,
    /// a line number, an icon drawn monochrome.
    case textSecondary
    /// Chrome text at its faintest: a caption, a disabled control's label.
    case textTertiary

    // MARK: Lines and accent

    /// The one-pixel rule that separates two chrome zones.
    case hairline
    /// The accent at full strength: an active tab's underline, a focus ring.
    case accent
    /// The accent as a wash, for a surface that is merely *marked*.
    case accentTint
    /// The accent as a stronger wash: a selected row in a key window.
    case accentTintStrong

    // MARK: Row states

    /// The wash a row takes while the pointer is inside it.
    case hoverTint
    /// A selected row in a window that is not key — selection without focus.
    case selectionInactive
    /// The wash a row takes while a drag that *would be accepted* hovers it.
    /// Deliberately its own role rather than `accentTintStrong`: hover and drop
    /// are on at the same time and must be told apart at a glance.
    case dropTint

    // MARK: Status

    /// An error, a failure, a refused input.
    case statusRed
    /// A warning.
    case statusYellow
    /// Success.
    case statusGreen
    /// Information, and everything below a warning.
    case statusBlue

    // MARK: Diff and merge

    /// A line present only on the right-hand side of a diff.
    case diffAddedBackground
    /// A line present only on the left-hand side of a diff.
    case diffRemovedBackground
    /// A conflicted region in the merge editor.
    case conflictBackground
}
