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
/// surfaces restyled so far — two of them (`currentLine`, `bracketMatch`),
/// both waiting for the surface that means them: the code zone's two line
/// overlays. `conflictBackground` was the third and is spent by the merge
/// panes, through `mergeWashRole(for:)`, in part five (b); `bgPopover` was the
/// fourth and is spent by the popovers — the completion panel, the hover
/// popover, the two switcher popovers and the Log calendar — in part five (a);
/// the two diff backgrounds are spent by the diff pane and the unified diff,
/// through `diffWashRole(for:side:)` / `diffWashRole(for:)`.
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

extension ChromeColorRole {
    /// Severity → the chrome role a severity mark is drawn in. Total over the
    /// closed severity set, like `SyntaxTheme`'s own answer — and deliberately
    /// *not* that one: the squiggle under the text is the code zone and stays on
    /// `SyntaxTheme.diagnosticColor(for:)` alone, so a chrome severity mark and
    /// the underline below it read from two tables on purpose.
    ///
    /// This is the chrome's **one** answer, and two surfaces read it: the
    /// gutter's severity dot (`LineNumberRulerView`) and the Problems panel's
    /// header badges and row glyphs. Neither keeps a table of its own.
    ///
    /// The four answers are three status roles and one text role. *Information*
    /// takes `accent` — the chrome has exactly one blue, and a notice is the
    /// thing the accent is for — and a *hint* takes `textSecondary`, because a
    /// hint is a remark rather than a condition and is drawn in the same tone the
    /// line numbers beside it are.
    public static func diagnosticRole(for severity: DiagnosticSeverity) -> ChromeColorRole {
        switch severity {
        case .error: return .statusRed
        case .warning: return .statusYellow
        case .information: return .accent
        case .hint: return .textSecondary
        }
    }

    /// Changed-file status → the role its letter is drawn in. The chrome's **one**
    /// answer, read by the Log's detail pane, the Local Changes panel and the
    /// commit dialog; none of them keeps a table of its own. Colour carries the
    /// weight, not the identity — `FileStatus.letter` does that — so two
    /// statuses sharing a role is by design: a rename is as much a change as an
    /// edit, and a conflict is as urgent as a deletion.
    public static func changedFileRole(for status: FileStatus) -> ChromeColorRole {
        switch status {
        case .added: return .statusGreen
        case .modified, .renamed: return .statusYellow
        case .deleted, .conflicted: return .statusRed
        case .untracked: return .textSecondary
        }
    }

    /// A pull request's checks summary → its glyph's role. One answer for the
    /// Pull Requests panel's rows and the bottom-bar indicator.
    public static func checksRole(for summary: GitHubChecksSummary) -> ChromeColorRole {
        switch summary {
        case .noChecks: return .textSecondary
        case .pending: return .statusYellow
        case .failure: return .statusRed
        case .success: return .statusGreen
        }
    }

    /// One job's bucket → its dot's role, in an expanded pull-request row. A
    /// skipped or cancelled job is a remark, not a verdict, and is drawn in
    /// `textSecondary`.
    public static func checksRole(for bucket: GitHubCheckBucket) -> ChromeColorRole {
        switch bucket {
        case .pass: return .statusGreen
        case .fail: return .statusRed
        case .pending: return .statusYellow
        case .skipping, .cancel: return .textSecondary
        }
    }

    /// A problem's difficulty → the role its word is drawn in. The chrome's
    /// **one** answer, read by the problem-catalog browser's rows alone; the
    /// view keeps the word, never a colour table. There is no orange role, so
    /// medium takes `statusYellow` — the same role an attempted problem takes.
    public static func difficultyRole(for difficulty: LeetCodeDifficulty) -> ChromeColorRole {
        switch difficulty {
        case .easy: return .statusGreen
        case .medium: return .statusYellow
        case .hard: return .statusRed
        }
    }

    /// How far the account has got with a problem → its status cell's role. One
    /// answer, read by the problem-catalog browser's rows alone; the glyph and
    /// the word stay the view's. A problem never started is a remark, not a
    /// condition, and is drawn in `textSecondary`.
    public static func problemStatusRole(for status: LeetCodeProblemStatus) -> ChromeColorRole {
        switch status {
        case .solved: return .statusGreen
        case .attempted: return .statusYellow
        case .notStarted: return .textSecondary
        }
    }

    /// A judge verdict → the role its header is drawn in. One answer, read by
    /// the judge section alone, and it carries the "good" rule with it: a
    /// verdict is good when it is `.accepted` **and** the run did not report
    /// a mismatch against the expected output (`matchedExpected == false`). A
    /// run passes its own `matchedExpected`; a submit, which compares against
    /// no expected output, passes `nil`. Every other verdict is `statusRed`.
    public static func verdictRole(for verdict: LeetCodeVerdict, matchedExpected: Bool?) -> ChromeColorRole {
        verdict == .accepted && matchedExpected != false ? .statusGreen : .statusRed
    }

    /// A side-by-side diff row's wash on one side, or `nil` for a plain row.
    /// A modified row is washed on both sides; an added row only on the new
    /// side and a removed row only on the old — the opposite side's filler row
    /// stays plain.
    public static func diffWashRole(for kind: DiffRowKind, side: DiffSide) -> ChromeColorRole? {
        switch (kind, side) {
        case (.unchanged, _): return nil
        case (.removed, .old), (.modified, .old): return .diffRemovedBackground
        case (.added, .new), (.modified, .new): return .diffAddedBackground
        case (.added, .old), (.removed, .new): return nil
        }
    }

    /// A unified diff line's wash, or `nil` for a context line.
    public static func diffWashRole(for kind: UnifiedDiffLine.Kind) -> ChromeColorRole? {
        switch kind {
        case .context: return nil
        case .removed: return .diffRemovedBackground
        case .added: return .diffAddedBackground
        }
    }

    /// A merge-pane line's wash, or `nil` for a plain line.
    ///
    /// **One wash, not two.** The design draws the differing lines of the two
    /// read-only panes and the unresolved region of the result pane identically,
    /// in `conflictBackground`: the *pane* is what tells ours from theirs from
    /// the result, so a second colour would restate what the layout already
    /// says. A resolved region takes the diff's added wash — it is now content
    /// the result carries.
    public static func mergeWashRole(for kind: MergeLineKind) -> ChromeColorRole? {
        switch kind {
        case .plain: return nil
        case .ours, .theirs, .conflictUnresolved: return .conflictBackground
        case .conflictResolved: return .diffAddedBackground
        }
    }

    /// The gutter marker's role on one side of a side-by-side diff row, or `nil`
    /// where no marker is drawn: red on the old side of a removal or
    /// modification, green on the new side of an addition or modification.
    public static func diffMarkerRole(for kind: DiffRowKind, side: DiffSide) -> ChromeColorRole? {
        switch (kind, side) {
        case (.removed, .old), (.modified, .old): return .statusRed
        case (.added, .new), (.modified, .new): return .statusGreen
        case (.unchanged, _), (.added, .old), (.removed, .new): return nil
        }
    }
}
