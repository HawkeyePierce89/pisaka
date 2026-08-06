import Foundation

/// Observable state for the 3-pane conflict-resolution editor: the loaded
/// `MergeDocument` (regions + per-conflict resolutions), the file/root being
/// resolved, and any error to surface.
///
/// Mirrors `LocalChangesModel`'s shape — an `@MainActor ObservableObject` that
/// funnels mutation through testable methods and injects its I/O behind protocols
/// (`GitServicing` to read the merge index stages and stage the result,
/// `FileServicing` to write the resolved working file) so the real,
/// `Process`-backed service is used in `Pisaka` and an in-memory stub in tests.
/// Pure Foundation — no `Process`/AppKit/SwiftUI.
///
/// `@MainActor`-isolated: published state is mutated on the main actor while the
/// injected `GitServicing`/`FileServicing` run their blocking work off-main (the
/// methods `await` it), so the main thread never blocks on a subprocess.
@MainActor
public final class MergeModel: ObservableObject {
    /// The loaded merge document, or `nil` before the first successful `load`.
    ///
    /// Read-only to callers: mutated only through `load` and the accept actions
    /// (`accept(_:at:)`), so the invariant "the document reflects the loaded file"
    /// holds.
    @Published public private(set) var document: MergeDocument?

    /// A human-readable description of the last `load`/`apply` failure, or `nil`
    /// after a successful operation.
    @Published public private(set) var errorMessage: String?

    /// The conflicted file currently loaded, or `nil` before the first `load`.
    @Published public private(set) var file: ChangedFile?

    /// The repository root the loaded file is resolved against.
    @Published public private(set) var root: URL?

    private let gitService: GitServicing
    private let fileService: FileServicing

    /// Which side of a modify/delete conflict is the *deleted* one, or `nil` when
    /// the load is not a modify/delete. A modify/delete keeps the base plus exactly
    /// one of ours/theirs (the modified side); the deleted side's stage is absent
    /// from the merge index, so its `Resolution` selects empty content. `apply`
    /// stages a *deletion* only when the user actually resolved to this side — not
    /// merely because the result is empty (a modified side that is itself empty, or
    /// a custom resolution edited down to empty, are empty-*file* results the user
    /// chose to keep, not deletions).
    private var deletedSide: ConflictSide?

    /// One side of a conflict, used to record which side a modify/delete deleted.
    private enum ConflictSide { case ours, theirs }

    public init(gitService: GitServicing, fileService: FileServicing) {
        self.gitService = gitService
        self.fileService = fileService
    }

    /// Whether every conflict in the loaded document has a resolution (so it may
    /// be applied). `false` when no document is loaded.
    public var isFullyResolved: Bool {
        guard let document else { return false }
        return document.isFullyResolved
    }

    /// The number of still-unresolved conflicts in the loaded document (0 when
    /// none is loaded).
    public var unresolvedCount: Int { document?.unresolvedCount ?? 0 }

    /// Load the conflicted `file` from the repository at `root`: read the three
    /// merge index stages (`:1` base, `:2` ours, `:3` theirs) off-main and build a
    /// `MergeDocument` via `ThreeWayMerge`.
    ///
    /// A missing stage (add/add has no base, modify/delete has one empty side) is
    /// treated as empty content — `ThreeWayMerge` represents those as a conflict
    /// whose corresponding span is empty rather than special-casing them away. The
    /// document's trailing-newline state is taken from the resolved sides (ours,
    /// then theirs, then base) so apply reproduces faithful bytes. On a read
    /// failure the document is cleared and `errorMessage` set.
    public func load(file: ChangedFile, root: URL) async {
        self.file = file
        self.root = root
        do {
            let base = try await gitService.blob(stage: 1, path: file.path, root: root)
            let ours = try await gitService.blob(stage: 2, path: file.path, root: root)
            let theirs = try await gitService.blob(stage: 3, path: file.path, root: root)
            // Both "ours" and "theirs" stages absent means there is no real merge
            // conflict for this path (a stale Local Changes snapshot pointing at a
            // file that is no longer conflicted, or a delete/delete git resolves on
            // its own). Building a document anyway would yield a zero-conflict,
            // trivially "fully resolved" empty document whose Apply writes "" over a
            // perfectly good file — refuse instead.
            guard ours != nil || theirs != nil else {
                document = nil
                deletedSide = nil
                errorMessage = "This file is not in a merge conflict."
                return
            }
            // A modify/delete conflict keeps the common ancestor (base) plus exactly
            // one of ours/theirs (the side that modified the file); the other side's
            // stage is absent because it deleted the file. (At most one can be `nil`
            // here — the guard above rejects both-absent.)
            if base != nil, ours == nil {
                deletedSide = .ours
            } else if base != nil, theirs == nil {
                deletedSide = .theirs
            } else {
                deletedSide = nil
            }
            let regions = ThreeWayMerge.regions(
                base: base ?? "",
                ours: ours ?? "",
                theirs: theirs ?? ""
            )
            document = MergeDocument(
                regions: regions,
                trailingNewline: Self.trailingNewline(ours: ours, theirs: theirs, base: base)
            )
            errorMessage = nil
        } catch {
            document = nil
            deletedSide = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Set the `resolution` of the conflict at `index` (conflict order). A no-op
    /// when no document is loaded or the index is out of range.
    public func accept(_ resolution: Resolution, at index: Int) {
        guard var doc = document else { return }
        doc.setResolution(resolution, at: index)
        document = doc
    }

    /// Apply the fully-resolved document: write `resolvedText` to the working file
    /// and stage it. Refuses (sets `errorMessage`, writes nothing) while any
    /// conflict is unresolved, and surfaces a write/stage failure without claiming
    /// success. Returns `true` only on a successful write + stage.
    @discardableResult
    public func apply() async -> Bool {
        guard let document, let file, let root else {
            errorMessage = "No merge is loaded."
            return false
        }
        guard document.isFullyResolved else {
            errorMessage = "Resolve all conflicts before applying."
            return false
        }
        let url = root.appendingPathComponent(file.path)
        do {
            // A modify/delete conflict the user resolved to the *deleted* side is a
            // deletion, not an empty file: writing "" and `git add`ing it would stage
            // an empty file instead of the removal the user chose, so stage the
            // deletion directly. The decision keys off *which resolution was selected*
            // (every conflict resolved to the absent side), not the output bytes —
            // an empty `resolvedText` can also come from a modified side that is
            // itself empty or a custom resolution edited down to empty, both of which
            // the user means to keep as an empty tracked file, so those still write +
            // stage. A degenerate zero-conflict modify/delete (both sides empty)
            // likewise writes the empty file rather than guessing a deletion.
            if deletionChosen(in: document) {
                try await gitService.stageRemoval(path: file.path, root: root)
            } else {
                try fileService.write(document.resolvedText, to: url)
                try await gitService.stage(path: file.path, root: root)
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Whether the user resolved a modify/delete conflict to its deleted (absent)
    /// side — the only case `apply` stages a removal rather than writing a file.
    ///
    /// True only when this is a modify/delete (`deletedSide` set), the document has
    /// at least one conflict, and *every* conflict is resolved to the deleted side
    /// (`.ours` when ours was deleted, `.theirs` when theirs was). A zero-conflict
    /// load (both sides emptied to the same content) is not a chosen deletion, and
    /// neither is any resolution to the present side, both sides, or a custom edit —
    /// even when the resulting text happens to be empty.
    private func deletionChosen(in document: MergeDocument) -> Bool {
        guard let deletedSide, document.conflictCount > 0 else { return false }
        let deletedResolution: Resolution = deletedSide == .ours ? .ours : .theirs
        return document.resolutions.allSatisfy { $0 == deletedResolution }
    }

    /// Whether the resolved text should end with a trailing newline, decided from
    /// the loaded sides in preference order (ours, then theirs, then base). A side
    /// is consulted only when present and non-empty; if none qualifies (all empty
    /// or missing) the default is `true` (git blobs conventionally end in a
    /// newline).
    private static func trailingNewline(ours: String?, theirs: String?, base: String?) -> Bool {
        for side in [ours, theirs, base] {
            if let side, let last = side.last {
                return last.isNewline
            }
        }
        return true
    }
}
