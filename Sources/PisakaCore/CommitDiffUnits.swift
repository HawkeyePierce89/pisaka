import Foundation

/// Why a file can only be committed as a whole, with the human text the dialog's
/// right-hand panel shows in place of a diff.
///
/// The text lives in Core for the same reason `GitError.errorDescription` and
/// `EntryPathIssue.message` do: the decision and its explanation are one rule,
/// unit-tested together, while the view stays a thin display of whatever the
/// classification returned.
///
/// **The last case is not one of `FileCommitEligibility.classify`'s answers.**
/// The first three are decided from the two *sides* and so come out of the
/// classification; `.noSelectableChanges` is decided from the *rows*, and is
/// produced by `CommitFileFacts.wholeOnlyReason` — the single place that answers
/// the panel's actual question, "is there a sentence to draw instead of a diff?".
public enum WholeOnlyReason: Equatable {
    /// The file is gone from the working tree — there is no new side to select
    /// lines from, only the deletion itself.
    case deleted
    /// The `HEAD` side is binary or not valid UTF-8.
    case binaryInHead
    /// The working-tree side is binary, not valid UTF-8, unreadable, or larger
    /// than `CommitDialogModel.maxSelectableFileBytes`.
    case binaryInWorktree
    /// The file is selectable in principle, yet no *line* of it is a change:
    /// `LineDiff` compares terminator-stripped lines, so a CRLF↔LF rewrite
    /// produces nothing but context rows — as do a mode-only change and a file
    /// staged and then restored in the working tree. Drawing them would be a diff
    /// with not one clickable checkbox in it.
    case noSelectableChanges

    /// The sentence shown in place of the diff.
    public var message: String {
        switch self {
        case .deleted:
            return "This file is deleted — it is committed as a whole."
        case .binaryInHead:
            return "This file is binary in HEAD — it is committed as a whole."
        case .binaryInWorktree:
            return "This file cannot be selected line by line (it is binary, "
                + "unreadable, or very large) — it is committed as a whole."
        case .noSelectableChanges:
            return "There are no line-level changes to select here (only something "
                + "other than the lines differs) — this file is committed as a whole."
        }
    }
}

/// Whether a file's changes can be selected line by line, or only committed whole.
///
/// A partial commit works by reassembling a file out of *lines*, so it is only
/// meaningful when both sides are text. When either side is not — or when there
/// is no working-tree side at all — the file still commits perfectly well, just
/// as an indivisible unit: the whole worktree file is handed to git (which
/// resolves modes, filters and `core.autocrlf` itself), or the path is removed.
///
/// The view must not draw a diff with unclickable checkboxes for such a file: a
/// selection UI that refuses every click reads as broken, and for a binary file
/// a naive old-side/new-side diff additionally reads as "every HEAD line
/// removed" — an invitation to exactly the silent corruption this type exists to
/// prevent. It draws `WholeOnlyReason.message` instead.
public enum FileCommitEligibility: Equatable {
    /// Both sides are text: the file's changed rows are selection units.
    case selectable
    /// The file is committed whole; `reason` is shown in place of the diff.
    case wholeOnly(reason: WholeOnlyReason)

    /// The reason this file is whole-only, or `nil` when it is selectable.
    public var reason: WholeOnlyReason? {
        if case let .wholeOnly(reason) = self { return reason }
        return nil
    }

    /// Classify a file from its status and the classification of both sides.
    ///
    /// `head` comes from `GitBlobText.classify(headBlob(...))`; `worktree` from
    /// the same classifier over the working file's bytes, where `.absent` means
    /// "no working file" and `.binary` covers binary, non-UTF-8 *and* unreadable
    /// (all three are "there is no text to select lines from").
    ///
    /// The order of the rules is the substance: a deletion is whole-only whatever
    /// the bytes were, then either side being **binary** disqualifies the file, and
    /// what is left is selectable. A missing working-tree side is treated as a
    /// deletion even when the status snapshot says otherwise (the file vanished
    /// since) — there is nothing to select either way.
    ///
    /// Note that an **absent `HEAD` side is not a disqualification**: an added or
    /// untracked file has no `HEAD` entry by definition and is exactly the case a
    /// per-line selection over an empty old side is *right* for (the builder takes
    /// `head: ""`). Only `worktree` absence is rejected, because there the missing
    /// side is the one being committed.
    public static func classify(
        status: FileStatus,
        head: BlobText,
        worktree: BlobText
    ) -> FileCommitEligibility {
        if status == .deleted { return .wholeOnly(reason: .deleted) }
        if head == .binary { return .wholeOnly(reason: .binaryInHead) }
        if worktree == .binary { return .wholeOnly(reason: .binaryInWorktree) }
        if worktree == .absent { return .wholeOnly(reason: .deleted) }
        return .selectable
    }
}

/// One line of the dialog's **unified** (single-column) diff.
///
/// The right-hand panel is a unified view rather than the side-by-side
/// `DiffView`, so a `.modified` row expands into *two* lines — the old one and
/// the new one — which nevertheless share **one** `unitIndex`: the pair is one
/// change and one checkbox, exactly as the underlying `DiffRow` is one selection
/// unit. A context line carries no `unitIndex`, so it can never be checked.
public struct UnifiedDiffLine: Equatable {
    public enum Kind: Equatable {
        case context
        case removed
        case added
    }

    public let kind: Kind
    /// The line's text, separator stripped (what the diff compares).
    public let text: String
    /// 1-based line number on the old (`HEAD`) side, `nil` for an added line.
    public let oldNumber: Int?
    /// 1-based line number on the new (worktree) side, `nil` for a removed line.
    public let newNumber: Int?
    /// The `LineDiff.rows` index this line belongs to — the selection unit —
    /// or `nil` for a context line.
    public let unitIndex: Int?

    public init(kind: Kind, text: String, oldNumber: Int?, newNumber: Int?, unitIndex: Int?) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.unitIndex = unitIndex
    }
}

/// The selection units of a partial commit and their unified presentation, pure
/// and Foundation-only (the `LineDiff`/`DuplicateEngine` split: every decision
/// here, the drawing in the view).
///
/// **A unit is a row index in `LineDiff.rows(old:new:)`** — not a line number on
/// either side, which would be ambiguous for a `.modified` row that has one on
/// each. The content of a partial commit is then assembled by
/// `PartialCommitBuilder` from `TerminatedLines`, of which `LineDiff.splitLines`
/// is a projection, so the indices and the lines they name cannot drift apart.
///
/// **The line-endings boundary, deliberate:** `LineDiff` compares
/// terminator-*stripped* lines, so a file whose only change is a CRLF→LF (or
/// reverse) rewrite produces no changed row at all and therefore **zero units**.
/// Such a file is committed whole or not at all, and the dialog says so with a
/// placeholder rather than showing a diff nothing in it can be checked.
public enum CommitDiffUnits {
    /// The row indices that are selectable units: every `added`/`removed`/
    /// `modified` row, in row order. `unchanged` rows are context and are not
    /// units.
    ///
    /// Deliberately **internal**: this is the row rule alone, with no whole-only
    /// guard, so leaving it public would be exactly the bypass the guarded
    /// overload below exists to prevent. Tests reach it through `@testable`.
    static func selectableUnits(rows: [DiffRow]) -> [Int] {
        rows.indices.filter { rows[$0].kind != .unchanged }
    }

    /// The selectable units of a file with the given `eligibility` — always empty
    /// for a `.wholeOnly` file, whatever its rows happen to look like.
    ///
    /// The whole-only rule is enforced *here*, at the one place units are handed
    /// out, rather than being restated at each call site: a binary file's rows are
    /// meaningless (they diff decoded garbage, or an empty old side), so nothing
    /// downstream may offer them.
    public static func selectableUnits(
        eligibility: FileCommitEligibility,
        rows: [DiffRow]
    ) -> [Int] {
        guard eligibility == .selectable else { return [] }
        return selectableUnits(rows: rows)
    }

    /// Flatten side-by-side rows into the unified lines the dialog draws, in row
    /// order: `unchanged` → one context line, `removed`/`added` → one line each,
    /// `modified` → a removed/added pair sharing the row's unit index.
    ///
    /// A row missing the side its kind requires (which `LineDiff` never produces)
    /// simply contributes nothing rather than trapping.
    public static func unified(rows: [DiffRow]) -> [UnifiedDiffLine] {
        var lines: [UnifiedDiffLine] = []
        for (index, row) in rows.enumerated() {
            switch row.kind {
            case .unchanged:
                if let left = row.left, let right = row.right {
                    lines.append(UnifiedDiffLine(
                        kind: .context,
                        text: left.text,
                        oldNumber: left.number,
                        newNumber: right.number,
                        unitIndex: nil
                    ))
                }
            case .removed:
                if let left = row.left {
                    lines.append(UnifiedDiffLine(
                        kind: .removed,
                        text: left.text,
                        oldNumber: left.number,
                        newNumber: nil,
                        unitIndex: index
                    ))
                }
            case .added:
                if let right = row.right {
                    lines.append(UnifiedDiffLine(
                        kind: .added,
                        text: right.text,
                        oldNumber: nil,
                        newNumber: right.number,
                        unitIndex: index
                    ))
                }
            case .modified:
                if let left = row.left {
                    lines.append(UnifiedDiffLine(
                        kind: .removed,
                        text: left.text,
                        oldNumber: left.number,
                        newNumber: nil,
                        unitIndex: index
                    ))
                }
                if let right = row.right {
                    lines.append(UnifiedDiffLine(
                        kind: .added,
                        text: right.text,
                        oldNumber: nil,
                        newNumber: right.number,
                        unitIndex: index
                    ))
                }
            }
        }
        return lines
    }
}
