import Foundation

/// Where the file mode of an assembled (partial) blob comes from.
///
/// A partial commit hashes content this app produced, so nothing on disk carries
/// its mode — it has to be named explicitly. An entry git already records keeps
/// the mode it has (so committing three lines of a file never silently drops its
/// executable bit); a path with no `HEAD` entry has only the working file to take
/// it from.
///
/// `.head` is the mode git *already records*, not an assertion about the working
/// file's current type: a path can change type between commits (a symlink
/// replaced by a regular file, or the reverse), which git reports as an ordinary
/// modification. Staging the recorded `120000` for what is now a regular file
/// would commit a symlink whose target is the file's entire text, so the executor
/// reconciles the recorded mode against the working file's actual type before
/// using it (`GitFileMode.reconciled(head:worktree:)`).
public enum CommitModeSource: Equatable {
    /// Read the mode git records for `path` at `HEAD` (for a rename this is the
    /// *old* path — the new one does not exist in `HEAD` at all), reconciled
    /// against the working file's type.
    case head(path: String)
    /// Stat the working file at `path`.
    case worktree(path: String)
}

/// One operation on the throw-away index a commit is built in.
///
/// The three cases are the whole vocabulary, and the split between the first two
/// is the substance of this type rather than an implementation detail:
///
/// - `.addFromWorktree` hands git the **working file** and lets it do everything
///   it normally does when staging — resolve the symlink, the exec bit, clean
///   filters, `core.autocrlf`. This is how *every* whole file enters the commit,
///   including a binary one, and it is what makes "everything selected = the
///   worktree bytes" a structural guarantee rather than a property of
///   `PartialCommitBuilder` (which, as its doc comment records, does not hold
///   that equality under mixed line endings).
/// - `.addContent` is the partial case and the only one that carries text this
///   app assembled; it needs an explicit `modeSource` because there is no file on
///   disk holding those bytes.
/// - `.removePath` drops a path from the index: a deletion, and the first half of
///   a rename.
public enum CommitPlanEntry: Equatable {
    case addFromWorktree(path: String)
    case addContent(path: String, content: String, modeSource: CommitModeSource)
    case removePath(path: String)
}

/// Everything about one file that the commit decision depends on, as read when
/// the dialog loaded it — and re-read immediately before the commit.
///
/// It is deliberately *only* the facts: no selection, no checkbox. That is what
/// lets `CommitStaleness` compare a snapshot against a fresh read without
/// comparing the user's own choices, and lets a selection be carried onto fresh
/// facts (`CommitFileSelection.withFacts(_:)`).
public struct CommitFileFacts: Equatable {
    /// The status entry (path, status, `oldPath` for a rename).
    public let file: ChangedFile
    /// The `HEAD` side, classified by `GitBlobText`.
    public let head: BlobText
    /// The working-tree side, classified the same way (`.absent` = no working
    /// file, `.binary` = binary, non-UTF-8 *or* unreadable).
    public let worktree: BlobText
    /// `LineDiff.rows(old: head text, new: worktree text)` — the rows whose
    /// indices a selection names.
    public let rows: [DiffRow]

    /// Whether this file's changes can be selected line by line at all.
    ///
    /// Derived once in `init` rather than computed per read: the facts are
    /// immutable, and both this and `units` sit on the dialog's hot path — SwiftUI
    /// re-evaluates the whole body on every keystroke in the message field, and
    /// each pass reads them several times per file (the file count, every row's
    /// checkbox state, the unified diff). Re-running `classify` and a full
    /// `rows.indices.filter` there put the diff's size on the typing path.
    public let eligibility: FileCommitEligibility

    /// The row indices that are real selection units, in row order — empty for
    /// every whole-only file, and also for a file whose only difference is
    /// something other than its lines.
    public let units: [Int]

    /// `units` as a set, for the membership tests `toggleUnit` and
    /// `effectiveUnits` would otherwise do against the array.
    let unitSet: Set<Int>

    public init(file: ChangedFile, head: BlobText, worktree: BlobText, rows: [DiffRow]) {
        self.file = file
        self.head = head
        self.worktree = worktree
        self.rows = rows
        let eligibility = FileCommitEligibility.classify(
            status: file.status,
            head: head,
            worktree: worktree
        )
        self.eligibility = eligibility
        let units = CommitDiffUnits.selectableUnits(eligibility: eligibility, rows: rows)
        self.units = units
        self.unitSet = Set(units)
    }

    public var path: String { file.path }

    /// Why this file is committed as a whole, or `nil` when there are line units
    /// to check — i.e. the single question the dialog's right-hand panel asks
    /// before deciding whether to draw a diff or a placeholder.
    ///
    /// There are **three** such categories and they behave identically in the UI,
    /// which is why they are collapsed into one answer here rather than left for
    /// the view to re-derive: a deletion, a side that is not text, and a file that
    /// is perfectly selectable yet has **zero units** (only its line endings
    /// changed — `LineDiff` compares terminator-stripped lines). The last one is
    /// invisible to `FileCommitEligibility`, which never looks at the rows, and it
    /// is exactly the case that would otherwise reach the panel as a diff whose
    /// every checkbox is missing. A file with no clickable unit must never be
    /// drawn as a selection UI: it reads as broken, and for a binary file a naive
    /// old/new diff additionally reads as "every HEAD line removed".
    public var wholeOnlyReason: WholeOnlyReason? {
        if let reason = eligibility.reason { return reason }
        return units.isEmpty ? .noSelectableChanges : nil
    }
}

/// One file in the dialog: its facts plus what the user checked.
///
/// **Which of the two selection fields decides is not a matter of taste.** A file
/// that has at least one unit is decided by `selectedUnits` *alone* — the units
/// are the single source of truth and `isChecked` is derived from them
/// (`CheckboxState.of(_:)`), so a stale checkbox can never smuggle a file with
/// nothing selected into the commit. A file with **no** units — binary, deleted,
/// or differing only in line endings — has nothing to derive a state from, so
/// there `isChecked` is the only signal and the checkbox is an ordinary
/// two-state one.
public struct CommitFileSelection: Equatable {
    public let facts: CommitFileFacts
    /// The row indices the user checked. Indices that name no unit are ignored
    /// everywhere rather than trapping — a selection can outlive a re-diff, and
    /// catching that is `CommitStaleness`' job.
    public let selectedUnits: Set<Int>
    /// The file-level checkbox, meaningful only for a file with no units.
    public let isChecked: Bool

    public init(facts: CommitFileFacts, selectedUnits: Set<Int>, isChecked: Bool) {
        self.facts = facts
        self.selectedUnits = selectedUnits
        self.isChecked = isChecked
    }

    public var file: ChangedFile { facts.file }
    public var rows: [DiffRow] { facts.rows }
    public var path: String { facts.path }

    /// The same selection over freshly re-read facts.
    ///
    /// This is the other half of `CommitStaleness.check(planned:current:)`: the
    /// check guarantees the *decisions* still hold, and rebuilding onto the fresh
    /// facts guarantees the *bytes* committed are the ones on disk now rather than
    /// the ones the dialog happened to load minutes ago.
    public func withFacts(_ facts: CommitFileFacts) -> CommitFileSelection {
        CommitFileSelection(facts: facts, selectedUnits: selectedUnits, isChecked: isChecked)
    }

    /// The selected indices that are really units of the current rows.
    public var effectiveUnits: Set<Int> {
        selectedUnits.intersection(facts.unitSet)
    }

    /// Whether this file contributes anything to the commit: at least one unit
    /// checked, or — for a file with no units at all (binary, deleted, or
    /// differing in something other than its lines) — the file-level checkbox.
    ///
    /// **The one implementation of that rule.** `CommitPlan.build` skips a file
    /// this reports `false` for, and `CommitDialogModel.selectedFileCount` — which
    /// is what `CommitGate` calls `selectedFileCount` — counts the files it reports
    /// `true` for, so "nothing selected" and "the plan is empty" agree by
    /// construction rather than by two copies of the rule being kept in step.
    ///
    /// Deliberately *not* written as `!effectiveUnits.isEmpty`: that materializes a
    /// whole intersected `Set` only to ask whether it is non-empty, and this is one
    /// of the hottest reads in the dialog — `TextEditor` writes the `@Published`
    /// message on every keystroke, so the view body re-evaluates and reaches
    /// `selectedFileCount` (directly, and again through `block` for both the status
    /// line and the Commit button) once per changed file each time. Short-circuiting
    /// keeps that O(files) rather than O(files × units) allocations per character
    /// typed, which is the same cost `CommitFileFacts` hoists out of `init`.
    public var isIncludedInCommit: Bool {
        facts.units.isEmpty ? isChecked : selectedUnits.contains(where: facts.unitSet.contains)
    }
}

/// A file-row checkbox: three states in the UI, two rules underneath.
public enum CheckboxState: Equatable {
    case unchecked
    case mixed
    case checked

    /// The primitive rule. With **no units** the checkbox is two-state and
    /// `isChecked` decides — `.mixed` there would claim a partial selection that
    /// cannot exist, which is exactly what makes a binary or deleted file read as
    /// broken in the list.
    private static func of(selectedUnitCount: Int, unitCount: Int, isChecked: Bool) -> CheckboxState {
        guard unitCount > 0 else { return isChecked ? .checked : .unchecked }
        if selectedUnitCount == 0 { return .unchecked }
        return selectedUnitCount >= unitCount ? .checked : .mixed
    }

    /// The state of one file's checkbox.
    public static func of(_ selection: CommitFileSelection) -> CheckboxState {
        of(
            selectedUnitCount: selection.effectiveUnits.count,
            unitCount: selection.facts.units.count,
            isChecked: selection.isChecked
        )
    }
}

/// What the commit will do to the throw-away index, decided purely from the
/// dialog's selection.
///
/// Pure and Foundation-only (the `PushPlan`/`CommitGate` split): the
/// `GIT_INDEX_FILE` juggling, `hash-object`, `update-index` and `git commit`
/// itself live in `GitCLIService`, and nothing there decides anything.
///
/// **The two boundaries are structural, and that is the point of this type.**
/// A file with nothing selected produces *no entry at all*, so the path never
/// enters the index and the commit records it exactly as `HEAD` already has it —
/// "nothing selected = HEAD" cannot be got wrong by an assembly bug because no
/// assembly happens. A file with everything selected produces
/// `.addFromWorktree`, so git places the working file's own bytes — "everything
/// selected = the worktree" likewise holds by construction rather than by
/// `PartialCommitBuilder` agreeing (it deliberately does not, under mixed line
/// endings). Only the genuinely partial case is assembled.
///
/// **Two consequences of the mechanism, recorded because they are surprising and
/// deliberate.**
///
/// 1. *A manual `git add` from the terminal is overwritten by a commit from the
///    dialog.* The commit is built from an index seeded with `read-tree HEAD`
///    plus exactly what the UI shows as checked — the JetBrains model, "what you
///    selected is what you committed" — so staged-but-unchecked changes are not
///    in it. They are not lost: they remain in the working tree as ordinary local
///    changes. What *is* discarded is the staging itself, by the `git reset
///    --quiet` that follows a successful commit — the single, deliberate touch of
///    the real index.
/// 2. *The staged effects of a formatting `pre-commit` hook are erased the same
///    way.* A hook that rewrites files and `git add`s them changes the temporary
///    index (so the commit does contain its edits, since git runs the hook before
///    reading the index it commits) but the subsequent `reset --quiet` unstages
///    everything; the hook's edits to the **working tree** survive and show up as
///    local changes. A hook that merely inspects and fails aborts the commit with
///    its own stderr and leaves both the real index and `HEAD` untouched.
public struct CommitPlan: Equatable {
    public let entries: [CommitPlanEntry]

    public init(entries: [CommitPlanEntry]) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Build the plan, in the order the files were given.
    ///
    /// Per file, in order:
    /// - it contributes nothing when nothing of it is selected (no unit checked,
    ///   or — for a file with no units — the checkbox is off);
    /// - a rename first removes its old path, whatever else it does;
    /// - a deleted (or vanished) file removes its path;
    /// - a file with no units, or with every unit selected, is added from the
    ///   worktree;
    /// - anything else is assembled by `PartialCommitBuilder` and added as
    ///   content.
    public static func build(selections: [CommitFileSelection]) -> CommitPlan {
        var entries: [CommitPlanEntry] = []
        for selection in selections {
            guard selection.isIncludedInCommit else { continue }

            let facts = selection.facts
            let units = facts.units
            let selected = selection.effectiveUnits
            let path = facts.path
            if let oldPath = facts.file.oldPath, facts.file.status == .renamed, oldPath != path {
                entries.append(.removePath(path: oldPath))
            }

            // A deletion is the one entry that has no new side to add. `.absent`
            // covers a file that vanished after the status snapshot was taken —
            // there is nothing on disk for git to stage either way.
            if facts.file.status == .deleted || facts.worktree == .absent {
                entries.append(.removePath(path: path))
                continue
            }

            if units.isEmpty || selected.count >= units.count {
                entries.append(.addFromWorktree(path: path))
                continue
            }

            let content = PartialCommitBuilder.assemble(
                head: facts.head.text ?? "",
                worktree: facts.worktree.text ?? "",
                rows: facts.rows,
                selectedUnits: selected
            )
            let modeSource: CommitModeSource = facts.head == .absent
                ? .worktree(path: path)
                : .head(path: facts.file.oldPath ?? path)
            entries.append(.addContent(path: path, content: content, modeSource: modeSource))
        }
        return CommitPlan(entries: entries)
    }
}

/// Why a commit was abandoned before it started, with the sentence the dialog
/// shows (the `CommitBlock.message` convention — the decision and its wording are
/// one rule, tested together).
public enum CommitStaleReason: Equatable {
    /// The file is no longer among the repository's changes at all.
    case vanished(path: String)
    /// Its status changed (staged, reverted, deleted, …).
    case statusChanged(path: String)
    /// It is no longer the same rename.
    case renameChanged(path: String)
    /// One of its sides is no longer what it was — text became binary, or a
    /// `HEAD` side appeared or disappeared.
    case contentKindChanged(path: String)
    /// Its diff changed, so the checked row indices no longer name the lines the
    /// user checked.
    case diffChanged(path: String)
    /// `HEAD` moved since the dialog read it, so the commit Amend would rewrite is
    /// no longer the one it offered. Names no file — it is a fact about the
    /// repository, not about any one path.
    case headMoved

    /// The path the reason is about, `nil` for a repository-wide reason.
    public var path: String? {
        switch self {
        case let .vanished(path), let .statusChanged(path), let .renameChanged(path),
             let .contentKindChanged(path), let .diffChanged(path):
            return path
        case .headMoved:
            return nil
        }
    }

    public var message: String {
        switch self {
        case let .vanished(path):
            return "“\(path)” is no longer among the changes — nothing was committed."
        case let .statusChanged(path):
            return "The status of “\(path)” changed on disk — nothing was committed."
        case let .renameChanged(path):
            return "“\(path)” is no longer the same rename — nothing was committed."
        case let .contentKindChanged(path):
            return "“\(path)” is no longer the same kind of file — nothing was committed."
        case let .diffChanged(path):
            return "“\(path)” changed on disk, so the selected lines no longer match — "
                + "nothing was committed."
        case .headMoved:
            return "A new commit was created in this repository since this dialog was opened, "
                + "so Amend would rewrite a different commit — nothing was committed."
        }
    }
}

/// The check run immediately before a commit: does the repository still look the
/// way the dialog says it does?
///
/// It exists because the dialog's modality stops the app's *own* writers
/// (autosave, the project tree, a revert) and nothing else: `git` in the embedded
/// terminal, an external editor and a build script all keep running. The
/// selection names **row indices**, so a file re-diffed differently turns a
/// checked line into a different line — silently, and in the one direction where
/// the mistake is written into history. This is the `LocalChangesModel.revert`
/// per-file re-query applied to a batch, and for the same reason: it collapses
/// the window from "however long the dialog has been open" to the milliseconds
/// between the check and the commit.
///
/// **The abort is the whole batch, not the file.** A commit is one atomic
/// artifact, so applying the clean part of a stale plan would create a commit the
/// user never composed. One reason comes back, naming the path, and nothing is
/// written.
///
/// **What it compares, and what it deliberately does not.** It compares the
/// *decisions* — status, the rename's old path, whether each side is
/// absent/binary/text, and the diff rows — because those are what the plan
/// encodes. It does **not** compare raw bytes: a whole file's bytes are read by
/// git at commit time (so a change landing in that instant is committed, exactly
/// as `git add` would), and a partial file's content is assembled from the
/// **fresh** facts via `CommitFileSelection.withFacts(_:)`. So a rewrite that
/// leaves every row identical — a line-ending-only pass, say — passes the check
/// and is committed as it now stands, which is the correct outcome rather than a
/// gap.
public enum CommitStaleness {
    /// The first divergence found, or `nil` when the plan may proceed.
    ///
    /// - Parameters:
    ///   - planned: the files the commit will act on, as the dialog holds them.
    ///   - current: freshly read facts. It may legitimately carry files the plan
    ///     does not touch (it is simply the current change list); only the planned
    ///     ones are compared.
    ///
    /// `git status` emits one record per path, so a duplicate is not something
    /// this can meet in practice — but the tie-break still has to be *stated*,
    /// because the caller rebuilds the plan through a second lookup over the same
    /// array and the two disagreeing would validate one set of rows and then
    /// assemble a different one. **Last wins**, here and in
    /// `CommitDialogModel.commit`, via the shared `indexed(_:)`.
    public static func check(
        planned: [CommitFileSelection],
        current: [CommitFileFacts]
    ) -> CommitStaleReason? {
        let byPath = indexed(current)

        for selection in planned {
            let path = selection.path
            guard let now = byPath[path] else { return .vanished(path: path) }
            let before = selection.facts
            if before.file.status != now.file.status { return .statusChanged(path: path) }
            if before.file.oldPath != now.file.oldPath { return .renameChanged(path: path) }
            if !sameKind(before.head, now.head) || !sameKind(before.worktree, now.worktree) {
                return .contentKindChanged(path: path)
            }
            if before.rows != now.rows { return .diffChanged(path: path) }
        }
        return nil
    }

    /// Freshly read facts keyed by path, **last occurrence winning**. Shared with
    /// `CommitDialogModel.commit`'s rebuild so the check and the plan can never
    /// resolve one path to two different sets of rows.
    public static func indexed(_ facts: [CommitFileFacts]) -> [String: CommitFileFacts] {
        var byPath: [String: CommitFileFacts] = [:]
        for entry in facts { byPath[entry.path] = entry }
        return byPath
    }

    /// Absent / binary / text, ignoring the text itself — the classification the
    /// eligibility rule and the unit list are derived from.
    private static func sameKind(_ lhs: BlobText, _ rhs: BlobText) -> Bool {
        switch (lhs, rhs) {
        case (.absent, .absent), (.binary, .binary), (.text, .text):
            return true
        default:
            return false
        }
    }
}
