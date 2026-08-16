import Foundation

/// Observable state for the editor workspace: the set of open files and the
/// current selection. All mutation flows through here so the UI layer stays
/// thin and the behavior remains unit-testable.
public final class WorkspaceModel: ObservableObject {
    /// Open files, in the order they were opened (tab order).
    @Published public private(set) var openFiles: [OpenFile] = []

    /// Identity of the currently selected file, or `nil` when none are open.
    ///
    /// Read-only to outside callers: all selection changes go through `select(_:)`
    /// (which validates that the id belongs to an open file) or the internal
    /// mutators, so the invariant "selectedID always references an open file or is
    /// nil" cannot be broken from the UI layer.
    @Published public private(set) var selectedID: UUID?

    /// Root directory of the currently open project, or `nil` when no folder is
    /// open. Set via `openFolder(url:)`; the project tree is rendered from here.
    @Published public private(set) var projectRoot: URL?

    /// Monotonic token bumped after any successful file-system mutation made
    /// through the tree (create / rename / delete). The project tree refreshes its
    /// cached directory listings by observing this token rather than reopening the
    /// folder. Read-only to outside callers; the app bumps it via
    /// `bumpTreeRevision()` after a successful disk operation (never on failure).
    ///
    /// On macOS the app bumps it from two further, view-layer sources: the FSEvents
    /// `ProjectWatcher` (so a change made *outside* the app — a generator run in the
    /// embedded terminal, a Finder rename — reaches the tree on its own) and the
    /// tree header's manual Refresh button. Core stays unaware of all three: it only
    /// publishes the token. Nothing else here watches the filesystem — open tabs and
    /// `LocalChangesModel` still refresh on demand only — and on iOS the tree too
    /// refreshes only on the app's own operations.
    @Published public private(set) var treeRevision: Int = 0

    /// Per-file monotonic token bumped whenever a buffer's text is replaced
    /// *externally* — i.e. by something other than the user typing into the
    /// editor: a project-wide Replace All landing in an open tab
    /// (`replaceText(_:for:)`) or a reload from disk after a revert / merge apply
    /// (`reloadFromDisk(id:)`). Absent means "never externally replaced"; read it
    /// through `textReplacementRevision(for:)`, which reports `0` for an unknown
    /// id so a caller never has to distinguish "absent" from "unchanged".
    ///
    /// The view layer needs this because such a replacement invalidates that
    /// file's *undo stack*: the recorded actions name ranges in the pre-swap text,
    /// so replaying one afterwards corrupts the buffer (or raises an out-of-range
    /// exception when the new text is shorter). The editor can detect the
    /// replacement itself only for the tab it is *currently showing*; a background
    /// tab is replaced with no view update of its own, and by the time the user
    /// switches to it the swap is indistinguishable from an ordinary tab switch —
    /// which must *not* clear the stack, since that is exactly the per-file
    /// history the editor keeps. Comparing this token across a switch is what
    /// separates the two.
    @Published public private(set) var textReplacementRevisions: [UUID: Int] = [:]

    /// Per-file token whose change means exactly one thing: **the on-disk content
    /// this buffer corresponds to changed**. Read it through `diskRevision(for:)`,
    /// which reports `0` for an unknown id so a caller never has to distinguish
    /// "absent" from "unchanged".
    ///
    /// It is bumped at every site that assigns `savedText` — `markSaved`,
    /// `save(for:)`, `saveAllDirty()` (per successfully written file), `saveAs`,
    /// `reloadFromDisk` and `reconcileSavedBaseline` — which is precisely the set
    /// of moments the file the buffer stands for stopped being the file it was:
    /// a save, an autosave, a Save As, the post-revert reload, a merge apply, and
    /// a branch checkout (which resyncs clean tabs through `reloadFromDisk` and
    /// edited ones through `reconcileSavedBaseline`). It is *not* bumped by
    /// `updateText`/`replaceText`, which change the buffer while leaving the file
    /// on disk exactly as it was.
    ///
    /// The consumer is the gutter's git-blame annotation column, whose data is a
    /// **worktree** blame and so goes stale the instant the worktree file moves
    /// under it. This is deliberately *separate* from `textReplacementRevisions`,
    /// which answers a different question — "drop this file's undo stack" — and so
    /// fires on a disjoint set of events (an external buffer replacement, disk
    /// untouched).
    ///
    /// **The contract is "it changed", not "it went up by one."** Consumers only
    /// ever compare the token against the last value they saw, so the only
    /// observable properties are that an affected file's token differs afterwards
    /// and that no other file's does. Today every listed mutator assigns
    /// `savedText` directly and bumps once, but a future refactor routing one
    /// through another (a `save(for:)` that comes to delegate to `markSaved`, a
    /// `saveAllDirty()` that reuses `save(for:)`) would bump twice and change
    /// nothing anyone can observe — which is why the tests pin the observable
    /// contract and never the arithmetic.
    @Published public private(set) var diskRevisions: [UUID: Int] = [:]

    private let fileService: FileServicing

    public init(fileService: FileServicing = FileService()) {
        self.fileService = fileService
    }

    /// Create a new empty "Untitled" buffer and select it.
    @discardableResult
    public func newFile() -> OpenFile {
        let file = OpenFile()
        openFiles.append(file)
        selectedID = file.id
        return file
    }

    /// Open the file at `url`, reading its contents into a new tab, and select it.
    ///
    /// If a tab for the same file is already open, that tab is selected and
    /// returned instead of opening a second buffer for the same file (which
    /// would risk one tab's save clobbering the other's edits). Equivalence is
    /// resolved by canonical path, so symlinks and unstandardized paths
    /// (e.g. `/tmp` vs `/private/tmp`, trailing slashes, `.`/`..`) match too.
    @discardableResult
    public func open(url: URL) throws -> OpenFile {
        let canonical = canonicalURL(url)
        if let existing = openFiles.first(where: { canonicalURL(of: $0) == canonical }) {
            selectedID = existing.id
            return existing
        }
        let contents = try fileService.read(url: url)
        let file = OpenFile(url: url, text: contents, savedText: contents)
        openFiles.append(file)
        selectedID = file.id
        return file
    }

    /// Open `url` as the project root, shown in the project tree.
    ///
    /// This still only sets `projectRoot`; the open tabs and selection are left
    /// untouched. That is not because tabs are unrelated to the folder — sessions
    /// *are* per-project — but because the two halves of a project switch have
    /// different owners: the tab half is `replaceSession(with:)`, driven by the app
    /// orchestration, which is the only layer that holds the `SessionStore` (and
    /// which must snapshot the outgoing project *before* this method moves
    /// `projectRoot`, or the snapshot would be filed under the incoming folder).
    /// Keeping the two separate is also what lets restore call this without
    /// disturbing tabs it is about to apply itself.
    ///
    /// **Only the macOS app drives that tab half today.** iOS has no `SessionStore`
    /// at all (session restore is macOS-only — on iOS just the folder comes back,
    /// through its security-scoped bookmark), so `FileAccessController.openFolder`
    /// calls this and stops, and a folder switch there leaves the previous project's
    /// tabs open. That is deliberate and depended upon — the scoped-access bookkeeping
    /// keeps a root registered exactly while a tab still lives under it — so "sessions
    /// are per-project" is a statement about the macOS layer until iOS grows a store.
    public func openFolder(url: URL) {
        projectRoot = url
    }

    /// Whether `url` names the folder already open as `projectRoot`.
    ///
    /// Compared canonically (the model's one rule — symlinks resolved, path
    /// standardized), so `/tmp` vs. `/private/tmp`, a trailing slash and a `.`/`..`
    /// detour all count as the same folder. `false` when no folder is open, so a
    /// first Open Folder reads as a switch rather than as a re-open.
    ///
    /// This is the test the app's folder-switch orchestration takes *first*:
    /// re-opening the current folder must stay a no-op for the tabs, while a real
    /// switch has to snapshot the outgoing session and apply the incoming one.
    public func isCurrentProjectRoot(_ url: URL) -> Bool {
        guard let root = projectRoot else { return false }
        return canonicalURL(root) == canonicalURL(url)
    }

    /// Swap the whole tab set for `session`'s: force-close everything currently
    /// open, then restore the incoming project's tabs and selection.
    ///
    /// The closes are **forced**, dirty tabs included, and that is safe only
    /// because of what the caller does first: the app refuses the switch outright
    /// while the disk-writer gate is up, flushes autosave, and refuses again —
    /// naming the files — if any dirty *titled* buffer is still unsaved afterwards.
    /// So by the time this runs, every titled buffer's text is on disk and every
    /// untitled one has already traveled into the outgoing project's snapshot. A
    /// `.needsConfirmation` path here would be the wrong shape anyway: the user
    /// already answered that question by choosing a different project.
    ///
    /// `closeFiles(ids:)` leaves `selectedID` `nil` once the last tab goes, so an
    /// **empty** incoming session — a folder opened for the first time — genuinely
    /// empties the editor rather than leaving `restoreSession`'s "empty session is a
    /// no-op" rule to preserve a stale selection.
    ///
    /// Applying the session goes through `restoreSession(_:)` verbatim, inheriting
    /// all of it: silent skipping of records this build cannot open, the
    /// canonical-path dedup, restored titled tabs clean and untitled ones dirty.
    /// `projectRoot` is deliberately **not** touched here either — for the reason
    /// `restoreSession(_:)` records, the folder is the app layer's job.
    public func replaceSession(with session: EditorSession) {
        closeFiles(ids: openFiles.map(\.id))
        restoreSession(session)
    }

    /// Apply a persisted `EditorSession` to this (normally empty) model: reopen the
    /// recorded tabs in order and restore the selection.
    ///
    /// **Everything is silent.** A launch is the worst possible moment for a stack
    /// of alerts about files that moved since the last run, so a record this build
    /// cannot turn into a tab is skipped and the batch continues:
    ///
    /// - a titled record whose file is **missing or unreadable** (`fileService.read`
    ///   throws) — deleted, renamed, or on a volume that is not mounted;
    /// - a record naming **neither a path nor text**. That is the *future-version
    ///   tab* (see `SessionTab`): a kind added by a later build, whose fields this
    ///   one has no property for, so the keyed decoder skipped them and nothing is
    ///   left. The rule lives here rather than in the decoder because it is a
    ///   decision about what a record *means*, and it is what keeps such a session
    ///   loading with every other tab intact instead of failing wholesale.
    ///
    /// A titled record is opened *through* `open(url:)`, so it inherits that
    /// method's **canonical-path** dedup rather than restating it: a hand-edited blob
    /// carrying duplicates — or two different spellings of one file (`/tmp/a.txt` and
    /// `/private/tmp/a.txt`, a path through a symlink) — yields one tab, not two,
    /// whose saves cannot clobber each other. This is the read side of the snapshot's
    /// write-verbatim rule: paths are stored exactly as the tab spelled them and
    /// matched canonically, the same asymmetry `open(url:)` already has. A duplicate
    /// record is not "skipped" for the purpose of the selection — it resolves to the
    /// tab already restored for it. A restored titled tab is **clean** (`savedText`
    /// is the contents just read), so it neither prompts on close nor gets rewritten
    /// by the first autosave.
    ///
    /// An Untitled record becomes a **dirty** url-less buffer: `text` from the
    /// session, `savedText` empty, so closing it asks for confirmation exactly as an
    /// unsaved buffer that was typed in this run would. That is the whole point of
    /// storing it — an Untitled buffer has nowhere on disk to live, so autosave
    /// skips it and the session is the only thing that carries its text across a
    /// restart.
    ///
    /// `selectedIndex` is an index into the records **as stored**, read back exactly
    /// the way `snapshot` wrote it, so a skipped record neither shifts nor
    /// invalidates it: index 1 still names the second *record*, whatever this build
    /// could or could not turn into a tab before it. Only a `nil`, out-of-range, or
    /// skipped-record index falls back to the last restored tab rather than leaving
    /// nothing selected. A session that restored no tab at all leaves the selection
    /// untouched, so an empty session is a genuine no-op.
    ///
    /// `projectRoot` is deliberately **not** touched: opening the folder registers
    /// the change with Local Changes, the Git Log, the branch switcher, Project
    /// Search and the FSEvents watcher, none of which Core knows about, so it stays
    /// the app layer's job.
    public func restoreSession(_ session: EditorSession) {
        var restoredAny = false
        var selectedFileID: UUID?
        for (index, record) in session.tabs.enumerated() {
            let id: UUID
            if let path = record.path {
                // Delegated to `open(url:)` rather than re-derived here, so the
                // canonical-path tab identity has one implementation: `try?` is
                // exactly the "skip a file this build cannot read" semantics wanted,
                // and a dedup hit returns the tab already restored for that file.
                // `open` also assigns `selectedID`, which is irrelevant — the
                // selection is set explicitly below whenever anything restored.
                guard let file = try? open(url: URL(fileURLWithPath: path)) else { continue }
                id = file.id
            } else if let text = record.text {
                let file = OpenFile(url: nil, text: text, savedText: "")
                openFiles.append(file)
                id = file.id
            } else {
                continue
            }
            restoredAny = true
            if index == session.selectedIndex { selectedFileID = id }
        }
        // Nothing this build could turn into a tab — an empty session, or one whose
        // every record was skipped — leaves the selection exactly as it was.
        guard restoredAny else { return }
        selectedID = selectedFileID ?? openFiles.last?.id
    }

    /// Bump `treeRevision` so the project tree re-reads its cached directory
    /// listings. The app calls this after any successful create / rename / delete
    /// (never on a failed disk operation).
    public func bumpTreeRevision() {
        treeRevision += 1
    }

    /// A planned retarget of one open tab for a rename: the tab `id` and the
    /// `newURL` it should point at once the on-disk move completes.
    ///
    /// Produced by `planRename(from:to:)` and consumed by `applyRenamePlan(_:)`.
    /// The two are split so the *matching* (which canonicalizes urls, resolving
    /// symlinks against the current filesystem) runs *before* the disk move, while
    /// the *mutation* of tab state runs only after the move succeeds — see
    /// `planRename(from:to:)` for why the order matters.
    public struct RenameRetarget: Equatable {
        public let id: UUID
        public let newURL: URL

        public init(id: UUID, newURL: URL) {
            self.id = id
            self.newURL = newURL
        }
    }

    /// Compute the tab-retarget plan for a rename/move of `from` to `to`, matching
    /// open tabs against the *current* (pre-move) filesystem.
    ///
    /// A tab whose url is exactly `from` (a single-file rename) is retargeted to
    /// `to`. For a folder rename, every tab whose url lives *under* `from` is
    /// retargeted with its path prefix rewritten from `from` to `to` (so
    /// `from/a/b.swift` becomes `to/a/b.swift`). Matching uses the same
    /// canonical-url rule as `fileID(forURL:)`/`open(url:)`.
    ///
    /// **Call this before performing the on-disk move**, then apply the result with
    /// `applyRenamePlan(_:)` after the move succeeds. Canonicalization resolves
    /// symlinks against what is on disk *now*: a tab opened through a symlink that
    /// points at `from` (or into it) canonicalizes to `from` only while the target
    /// still exists. Once the move renames the target away, that symlink dangles
    /// and `resolvingSymlinksInPath()` can no longer resolve it — so matching after
    /// the move would silently miss the tab and leave it pointing at a dangling
    /// path. Capturing the plan first avoids that.
    public func planRename(from: URL, to: URL) -> [RenameRetarget] {
        var plan: [RenameRetarget] = []
        for file in openFiles {
            guard let fileURL = file.url else { continue }
            switch entryMatch(fileURL: fileURL, operation: from) {
            case .exact:
                plan.append(RenameRetarget(id: file.id, newURL: to))
            case .under(let suffix):
                var newURL = to
                for component in suffix {
                    newURL.appendPathComponent(component)
                }
                plan.append(RenameRetarget(id: file.id, newURL: newURL))
            case .none:
                break
            }
        }
        return plan
    }

    /// Apply a rename plan captured by `planRename(from:to:)`, retargeting each
    /// listed tab to its `newURL`.
    ///
    /// Dirty state is preserved (only `url` changes — `text`/`savedText` are
    /// untouched — and `displayName` re-derives from `url`). A plan entry for a tab
    /// that has since closed is ignored. Call only after the on-disk move succeeds,
    /// so a failed move never leaves tabs pointing at a path that does not exist.
    public func applyRenamePlan(_ plan: [RenameRetarget]) {
        for retarget in plan {
            guard let index = indexOf(retarget.id) else { continue }
            openFiles[index].url = retarget.newURL
        }
    }

    /// Reconcile open tabs after a file or folder at `from` was renamed/moved to
    /// `to`. A convenience wrapper over `planRename(from:to:)` +
    /// `applyRenamePlan(_:)` for callers that reconcile against in-memory urls
    /// (no symlink-dangling concern). Disk-backed call sites should instead
    /// `planRename` *before* the move and `applyRenamePlan` after — see
    /// `planRename(from:to:)`.
    public func renamePath(from: URL, to: URL) {
        applyRenamePlan(planRename(from: from, to: to))
    }

    /// The ids of the open tabs that deleting the item at `url` should close: the
    /// tab whose url is exactly `url` (a single-file delete) and, for a folder
    /// delete, every tab whose url lives *under* `url`. Matching uses the same
    /// canonical-url rule as `fileID(forURL:)`.
    ///
    /// **Call this before removing the item from disk**, for the same reason as
    /// `planRename(from:to:)`: a tab opened through a symlink pointing at (or into)
    /// the deleted item canonicalizes to it only while it still exists, so matching
    /// after the removal would miss that tab and leave it open on a dangling path.
    public func tabIDs(under url: URL) -> [UUID] {
        return openFiles.compactMap { file -> UUID? in
            guard let fileURL = file.url else { return nil }
            return entryMatch(fileURL: fileURL, operation: url) == nil ? nil : file.id
        }
    }

    /// Force-close every open tab whose id is in `ids`.
    ///
    /// Used to close the tabs a delete affects, captured beforehand by
    /// `tabIDs(under:)`. The selection is kept valid via the existing
    /// close/selection logic. Closes are forced (the file is already gone from
    /// disk, so there is nothing to save). An id for an already-closed tab is
    /// ignored.
    public func closeFiles(ids: [UUID]) {
        for id in ids {
            close(id: id, force: true)
        }
    }

    /// Force-close every open tab affected by deleting the item at `url`. A
    /// convenience wrapper over `tabIDs(under:)` + `closeFiles(ids:)` for callers
    /// reconciling against in-memory urls; disk-backed call sites should capture
    /// `tabIDs(under:)` *before* the removal and `closeFiles(ids:)` after — see
    /// `tabIDs(under:)`.
    public func closeFiles(under url: URL) {
        closeFiles(ids: tabIDs(under: url))
    }

    /// How an open tab relates to the entry a tree rename/delete targets.
    private enum EntryMatch: Equatable {
        /// The tab *is* the operated entry (a single-file rename/delete).
        case exact
        /// The tab lives under the operated entry (a folder rename/delete); the
        /// associated value is the trailing path components below the entry, used
        /// to rebuild the tab's url for a rename.
        case under([String])
    }

    /// Decide whether the open tab at `fileURL` is, or lives under, the entry a
    /// tree operation targets at `operation`, returning `nil` for no relation.
    ///
    /// Three identities are tested so symlinks resolve correctly in *both*
    /// directions:
    /// - the tab's *canonical* path (symlinks resolved) against the operation's
    ///   `entryURL` (parent canonicalized, final component kept literal). This
    ///   matches a tab opened *through* a symlink to a real renamed/deleted
    ///   target — the target's own final component is not a symlink, so its
    ///   `entryURL` equals its canonical url, which the tab canonicalizes to.
    /// - the tab's *lexical* path (standardized, symlinks **un**resolved) against
    ///   the operation's lexical path. This matches a tab opened *directly on the
    ///   operated symlink itself* (or nested under an operated
    ///   symlink-to-directory): such a tab canonicalizes to its referent, so the
    ///   canonical test misses it, yet the operation renames/deletes the very
    ///   link the tab points at and so the tab must be reconciled. Because lexical
    ///   path equality means the *same* literal entry, this can never match a tab
    ///   pointing at a different file (e.g. a tab opened on the referent while the
    ///   symlink is operated on stays excluded).
    /// - the tab's *entry* identity at each of its lexical ancestors: walking the
    ///   tab's lexical path from the full url upward, each ancestor's entry
    ///   identity (its parent canonicalized, its final component kept literal) is
    ///   compared against the operation's entry identity (the same shape — see
    ///   `entryURL(_:)`). The lexical test above only matches a tab opened on (or
    ///   under) the operated symlink when the tab and the operation *spell their
    ///   shared ancestors the same way*. When they differ — the tree operates
    ///   through a symlinked project root (`/link/mylink`) while the tab remembers
    ///   the canonical parent (`/real/mylink`) for the same operated symlink entry,
    ///   or a tab descends *through* an operated symlink directory reached via an
    ///   aliased root (`/link/mydir/a.txt` vs the operation on `/realalias/mydir`) —
    ///   the lexical paths diverge at the ancestor and the canonical test resolves
    ///   the operated symlink to its referent, so neither matches. Canonicalizing
    ///   the shared ancestors on *both* sides while keeping the operated component
    ///   literal makes the two entry identities equal, so the operated symlink (and
    ///   any tab nested below it) is still matched, with the suffix below it taken
    ///   from the tab's lexical components. The ancestors are compared one at a
    ///   time rather than aligning by component count, because an alias and its
    ///   target can differ in path *depth* (`/short` → `/deep/project/root`): the
    ///   matching ancestor is found by entry-identity equality regardless of depth,
    ///   not assumed to sit at the operation entry's component index. A tab opened
    ///   on the *referent* keeps a final component equal to the referent's own
    ///   name, so its entry identity still differs and it stays excluded.
    private func entryMatch(fileURL: URL, operation: URL) -> EntryMatch? {
        let entryComponents = entryURL(operation).pathComponents
        let canonical = canonicalURL(fileURL).pathComponents
        if canonical == entryComponents { return .exact }
        if let suffix = relativeComponents(of: canonical, under: entryComponents) {
            return .under(suffix)
        }
        let standardizedTab = fileURL.standardizedFileURL
        let lexicalEntry = operation.standardizedFileURL.pathComponents
        let lexical = standardizedTab.pathComponents
        if lexical == lexicalEntry { return .exact }
        if let suffix = relativeComponents(of: lexical, under: lexicalEntry) {
            return .under(suffix)
        }
        // (3) Entry identity of each of the tab's lexical ancestors: walk the
        // tab's lexical path from the full url upward, comparing each ancestor's
        // entry identity (its parent canonicalized, its final component kept
        // literal) against the operation entry. Unlike (2) this canonicalizes the
        // *shared ancestors* on both sides, so it still matches when the tree
        // reaches the entry through a differently-spelled (e.g. symlinked-root)
        // ancestor — both for the operated entry itself and for a tab nested
        // *under* an operated symlink directory reached via an aliased root. The
        // operated component must stay literal: canonicalizing it (as the tab's
        // full canonical path in (1) does) would resolve the link to its referent
        // and miss the tab whose remembered path descends through the link.
        //
        // Ancestors are compared one by one rather than aligning by component
        // count: an alias and its target can have *different* path depths
        // (`/short` → `/deep/project/root`), so picking the ancestor at the
        // operation entry's component count would land on the wrong ancestor — or,
        // when the tab's lexical path is shorter than the canonical operation
        // entry, skip the comparison entirely. Comparing each ancestor's *entry
        // identity* (which canonicalizes its parent, absorbing any depth
        // difference) finds the genuine match regardless of how the shared
        // ancestors are spelled. The first (deepest) matching ancestor wins; the
        // suffix below it is taken from the tab's lexical components, so a rename
        // retargets to the path the tab remembers.
        var ancestor = standardizedTab
        var ancestorCount = lexical.count
        while ancestorCount >= 2 {
            if entryURL(ancestor).pathComponents == entryComponents {
                let suffix = Array(lexical.dropFirst(ancestorCount))
                return suffix.isEmpty ? .exact : .under(suffix)
            }
            ancestor = ancestor.deletingLastPathComponent()
            ancestorCount -= 1
        }
        return nil
    }

    /// If `components` live strictly under `ancestorComponents`, the trailing
    /// components (the part below the ancestor); otherwise `nil`. Used to detect
    /// and rewrite tabs nested inside a renamed/deleted folder.
    ///
    /// Delegates to `CanonicalPath`, the single source of truth this model shares
    /// with the breadcrumb `DisplayPath` — see the type's doc comment.
    private func relativeComponents(of components: [String], under ancestorComponents: [String]) -> [String]? {
        CanonicalPath.relativeComponents(of: components, under: ancestorComponents)
    }

    /// List the visible contents of the directory at `url`, for the project
    /// tree. A thin pass-through to the file service so the view goes through
    /// the model rather than touching the service directly.
    public func children(of url: URL) throws -> [DirectoryEntry] {
        try fileService.contentsOfDirectory(at: url)
    }

    /// The currently selected file, or `nil` when none is selected.
    public var selectedFile: OpenFile? {
        guard let selectedID else { return nil }
        return openFiles.first { $0.id == selectedID }
    }

    /// The current editor text of the open file identified by `id`, or `nil`
    /// when no open tab has that id.
    ///
    /// Lets a caller snapshot a buffer's contents and later detect whether the
    /// user changed it in between (e.g. an edit made during an async operation
    /// that should not be silently overwritten by a follow-up reload).
    public func text(for id: UUID) -> String? {
        openFiles.first { $0.id == id }?.text
    }

    /// Whether the open file identified by `id` has unsaved edits
    /// (`text != savedText`), or `false` when no open tab has that id.
    ///
    /// Lets a caller decide whether a tab is safe to silently reload from disk: a
    /// clean tab can be reloaded over, while a dirty one holds unsaved edits that
    /// a reload would discard without a prompt.
    public func isDirty(for id: UUID) -> Bool {
        openFiles.first { $0.id == id }?.isDirty ?? false
    }

    /// Select the file identified by `id`, if it is open.
    public func select(_ id: UUID) {
        guard indexOf(id) != nil else { return }
        selectedID = id
    }

    /// Replace the editor text for the file identified by `id`.
    ///
    /// This is the *editing* path — the editor binding routes every keystroke
    /// through it — so it deliberately does **not** bump
    /// `textReplacementRevisions`. A caller replacing a buffer from outside the
    /// editor must use `replaceText(_:for:)` instead.
    public func updateText(_ text: String, for id: UUID) {
        guard let index = indexOf(id) else { return }
        openFiles[index].text = text
    }

    /// The external-replacement token of the file identified by `id`, or `0` when
    /// it has never been externally replaced (or is not open).
    ///
    /// See `textReplacementRevisions` for what the token means and why the view
    /// layer compares it across a tab switch.
    public func textReplacementRevision(for id: UUID) -> Int {
        textReplacementRevisions[id] ?? 0
    }

    /// Replace the editor text for the file identified by `id` from *outside* the
    /// editor, bumping its `textReplacementRevisions` token.
    ///
    /// The text-mutating counterpart of `updateText(_:for:)` for callers that are
    /// not the user's own typing — currently the project-wide Replace All, which
    /// applies to every matching open tab, including ones that are not on screen.
    /// The bump is what lets the editor drop that file's now-invalid undo stack
    /// when the tab is next displayed. Returns `false` (and changes nothing) when
    /// no open tab has that id.
    ///
    /// Like `updateText`, this leaves `savedText` alone, so the tab becomes dirty
    /// and saving stays the user's call.
    @discardableResult
    public func replaceText(_ text: String, for id: UUID) -> Bool {
        guard let index = indexOf(id) else { return false }
        openFiles[index].text = text
        bumpTextReplacementRevision(id)
        return true
    }

    private func bumpTextReplacementRevision(_ id: UUID) {
        textReplacementRevisions[id, default: 0] += 1
    }

    /// The disk-content token of the file identified by `id`, or `0` when the
    /// on-disk content it corresponds to has never changed (or it is not open).
    ///
    /// See `diskRevisions` for what the token means; compare it against the last
    /// value you saw rather than expecting any particular increment.
    public func diskRevision(for id: UUID) -> Int {
        diskRevisions[id] ?? 0
    }

    /// Record that the on-disk content the buffer `id` corresponds to changed.
    /// Called from every site that assigns `savedText`.
    private func bumpDiskRevision(_ id: UUID) {
        diskRevisions[id, default: 0] += 1
    }

    /// Mark the file identified by `id` as saved (clears the dirty flag).
    public func markSaved(for id: UUID) {
        guard let index = indexOf(id) else { return }
        openFiles[index].savedText = openFiles[index].text
        bumpDiskRevision(id)
    }

    /// Reload the open file identified by `id` from its on-disk contents,
    /// discarding any in-memory edits.
    ///
    /// Used after an external change to the file (e.g. a revert that restored it
    /// from `HEAD`) so the open tab matches what is on disk. On success both
    /// `text` and `savedText` are replaced with the disk contents, so the file
    /// becomes not-dirty, and `true` is returned. An unknown id or a url-less
    /// ("Untitled") buffer has nothing to read and is a no-op returning `false`.
    /// A read failure leaves the buffer untouched and returns `false` (reported,
    /// not fatal).
    ///
    /// **The two tokens answer different questions here, so a byte-identical read
    /// moves exactly one of them.** `textReplacementRevisions` means "this buffer
    /// was replaced", and a read that returns what the buffer already holds
    /// replaced nothing: every caller resyncs *every* open tab under the
    /// repository after an operation that only *may* have rewritten some of them
    /// (a commit ordinarily rewrites none, a checkout only the files that differ
    /// between the branches), so bumping it unconditionally made `CodeEditorView`
    /// drop that file's undo stack on the next tab switch — silently, since the
    /// text is unchanged there is nothing to see. `diskRevisions` means "the
    /// on-disk content this buffer corresponds to changed", and that is what the
    /// *caller* has just asserted by asking for a reload at all: after a commit or
    /// a branch checkout a file whose bytes are identical still belongs to
    /// different history, so its worktree `git blame` genuinely moved. Skipping
    /// that bump left the gutter naming the previous branch's authors on a file it
    /// had no other reason to reload — and a wrong author is the one thing the
    /// annotation column refuses to show. A byte-identical read is a successful
    /// reload either way, so it still returns `true` — callers read `false` as
    /// "could not be read" and close the tab.
    ///
    /// The two assignments are therefore judged **separately**, because they can
    /// diverge: a *dirty* buffer whose `text` already equals the disk contents (the
    /// user typed exactly what a checkout or a formatting hook then wrote) still
    /// has a stale `savedText`, so the baseline must advance — but nothing replaced
    /// the buffer, and bumping the replacement token there is the same silent
    /// undo-stack loss on a screen where nothing changed.
    @discardableResult
    public func reloadFromDisk(id: UUID) -> Bool {
        guard let index = indexOf(id) else { return false }
        guard let url = openFiles[index].url else { return false }
        guard let contents = try? fileService.read(url: url) else { return false }
        if openFiles[index].text != contents {
            openFiles[index].text = contents
            // An external replacement like any other: the tab may not be on screen,
            // and its undo stack now names ranges in text that is gone.
            bumpTextReplacementRevision(id)
        }
        if openFiles[index].savedText != contents {
            // The baseline alone: `isDirty` must reflect the file as it is now even
            // when the buffer already matched it.
            openFiles[index].savedText = contents
        }
        // The bytes this buffer stands for may be new ones, and the history behind
        // them certainly may be (a revert, a merge apply, a commit, a branch
        // checkout), so any worktree-derived annotation is stale.
        bumpDiskRevision(id)
        return true
    }

    /// Reconcile the saved baseline of the open file `id` against its current
    /// on-disk contents, *without* touching the in-memory `text`.
    ///
    /// Used by the post-revert resync for a buffer the user edited while an
    /// async revert was in flight: that buffer must be *preserved* (reloading it
    /// would discard the edit), but its `savedText` may now be stale. If the
    /// user also *saved* during the revert, `savedText` equals `text` — the tab
    /// looks clean — even though `git` has since overwritten (or deleted) the
    /// file on disk; closing such a tab would skip the unsaved-changes
    /// confirmation and silently lose the preserved edit. Replacing `savedText`
    /// with what is actually on disk makes `isDirty` reflect the true
    /// buffer-vs-disk difference, so the tab becomes dirty and closing it
    /// prompts to save. A deleted (or unreadable) file is treated as empty
    /// on-disk content, so a non-empty buffer becomes dirty while an empty one
    /// stays clean. No-op returning `false` for an unknown id or a url-less
    /// ("Untitled") buffer.
    @discardableResult
    public func reconcileSavedBaseline(id: UUID) -> Bool {
        guard let index = indexOf(id) else { return false }
        guard let url = openFiles[index].url else { return false }
        openFiles[index].savedText = (try? fileService.read(url: url)) ?? ""
        bumpDiskRevision(id)
        return true
    }

    /// Outcome of attempting to save a file.
    public enum SaveResult: Equatable {
        /// The file was written to its existing url.
        case saved
        /// The file has no url yet; the caller must prompt for a location
        /// (Save As) and then call `saveAs(url:for:)`.
        case needsSaveAs
    }

    /// Save the file identified by `id`.
    ///
    /// If the file already has a url, its contents are written to disk and the
    /// dirty flag is cleared. If it has no url (a new "Untitled" buffer), no
    /// write happens and `.needsSaveAs` is returned so the UI can present a
    /// save panel.
    @discardableResult
    public func save(for id: UUID) throws -> SaveResult {
        guard let index = indexOf(id) else { return .needsSaveAs }
        guard let url = openFiles[index].url else { return .needsSaveAs }
        try fileService.write(openFiles[index].text, to: url)
        openFiles[index].savedText = openFiles[index].text
        bumpDiskRevision(id)
        return .saved
    }

    /// Save every dirty file that already has a url, skipping the rest, and
    /// return the urls actually written.
    ///
    /// This is the autosave action: unlike `save(for:)` it never returns
    /// `.needsSaveAs` and never prompts. A url-less ("Untitled") buffer is
    /// skipped entirely (JetBrains-style autosave must not pop a Save As panel),
    /// and a clean file is skipped because there is nothing to write. For each
    /// remaining file the `text` is written via `fileService.write(_:to:)` and
    /// `savedText` advanced to match, clearing the dirty flag.
    ///
    /// A per-file write failure is swallowed: that file is left untouched (it
    /// stays dirty) and omitted from the returned list, and the batch continues
    /// with the rest — autosave fires unattended and must never abort the batch
    /// or surface a modal on one bad write. Because a successful save clears the
    /// dirty flag, the method is idempotent: an immediate second call finds
    /// nothing dirty and returns `[]` without writing. The returned urls let the
    /// caller refresh Local Changes only when something actually changed on disk.
    @discardableResult
    public func saveAllDirty() -> [URL] {
        var savedURLs: [URL] = []
        for index in openFiles.indices {
            guard openFiles[index].isDirty, let url = openFiles[index].url else { continue }
            do {
                try fileService.write(openFiles[index].text, to: url)
                openFiles[index].savedText = openFiles[index].text
                bumpDiskRevision(openFiles[index].id)
                savedURLs.append(url)
            } catch {
                // Leave this file dirty and keep going; never abort the batch.
                continue
            }
        }
        return savedURLs
    }

    /// Errors that can prevent a Save As.
    public enum SaveAsError: Error, Equatable {
        /// Another open tab already targets the destination url. Writing here
        /// would leave two buffers pointing at the same file, so either tab's
        /// later save could clobber the other's edits. Rejected before writing.
        case destinationAlreadyOpen
    }

    /// Save the file identified by `id` to `url` (Save As).
    ///
    /// Assigns the url, writes the contents to disk, updates the display name
    /// (derived from the url), and clears the dirty flag.
    ///
    /// If a *different* open tab already targets `url` (compared canonically,
    /// matching `open(url:)`), the save is rejected with
    /// `SaveAsError.destinationAlreadyOpen` and nothing is written — this mirrors
    /// `open(url:)`'s guard against two buffers sharing one path.
    public func saveAs(url: URL, for id: UUID) throws {
        guard let index = indexOf(id) else { return }
        let canonical = canonicalURL(url)
        if openFiles.contains(where: { $0.id != id && canonicalURL(of: $0) == canonical }) {
            throw SaveAsError.destinationAlreadyOpen
        }
        try fileService.write(openFiles[index].text, to: url)
        openFiles[index].url = url
        openFiles[index].savedText = openFiles[index].text
        bumpDiskRevision(id)
    }

    /// Outcome of attempting to close a file.
    public enum CloseResult: Equatable {
        /// The tab was removed.
        case closed
        /// The file has unsaved changes; the caller must confirm with the user
        /// (Save / Don't Save / Cancel) before the tab can be removed.
        case needsConfirmation
    }

    /// Close the file identified by `id`.
    ///
    /// A clean file is removed immediately. A dirty file is left untouched and
    /// `.needsConfirmation` is returned so the UI can present a confirmation
    /// dialog; pass `force: true` (after the user chooses "Don't Save") to
    /// remove it without saving. Closing the selected tab moves the selection
    /// to a neighboring tab, or clears it when the last tab is closed.
    @discardableResult
    public func close(id: UUID, force: Bool = false) -> CloseResult {
        guard let index = indexOf(id) else { return .closed }
        if openFiles[index].isDirty && !force {
            return .needsConfirmation
        }
        removeFile(at: index)
        return .closed
    }

    private func removeFile(at index: Int) {
        let removed = openFiles[index]
        openFiles.remove(at: index)
        // Drop the closed tab's external-replacement token so the map doesn't
        // accumulate entries for files that are no longer open. A future tab for
        // the same file gets a fresh id (and so a fresh token) anyway.
        textReplacementRevisions[removed.id] = nil
        // Same reasoning for the disk-content token.
        diskRevisions[removed.id] = nil
        guard selectedID == removed.id else { return }
        if openFiles.isEmpty {
            selectedID = nil
        } else {
            // Select the tab that shifted into this slot (the next neighbor),
            // or the new last tab when the closed one was at the end.
            selectedID = openFiles[min(index, openFiles.count - 1)].id
        }
    }

    private func indexOf(_ id: UUID) -> Int? {
        openFiles.firstIndex { $0.id == id }
    }

    /// The id of the open file whose url refers to the same file as `url`, or
    /// `nil` when no open tab targets it.
    ///
    /// Matches on the *canonical* url (same rule as `open(url:)`), so a lookup
    /// built from a different-but-equivalent path form — `/tmp` vs `/private/tmp`,
    /// a symlinked or unstandardized path, or a repo-root-relative url that
    /// differs from how the tab was opened — still finds the tab. Lets callers
    /// resync a specific tab without depending on fragile raw `URL` equality.
    public func fileID(forURL url: URL) -> UUID? {
        let canonical = canonicalURL(url)
        return openFiles.first { canonicalURL(of: $0) == canonical }?.id
    }

    /// Canonical form of a url for identity comparison: resolves symlinks and
    /// standardizes the path so `/tmp` vs `/private/tmp`, trailing slashes, and
    /// `.`/`..` components all compare equal.
    ///
    /// Delegates to `CanonicalPath`, the single source of truth this model shares
    /// with the breadcrumb `DisplayPath` — see the type's doc comment (including
    /// why `resolvingSymlinksInPath()` rather than `realpath(3)` is the right
    /// transform here, unlike in `ProjectWatcher`).
    private func canonicalURL(_ url: URL) -> URL {
        CanonicalPath.canonical(url)
    }

    /// Identity of the directory *entry* at `url` for matching open tabs against a
    /// tree rename/delete: the parent directory is canonicalized (resolving
    /// symlinks and standardizing) but the final path component is kept *literal*,
    /// so a symlink entry is distinguished from the item it points at.
    ///
    /// A tree operation acts on the named entry itself: renaming or deleting a
    /// symlink touches only the link, never its referent. Matching the operation's
    /// *fully* canonical url would resolve the link to its target and so capture a
    /// tab opened directly on that target — which the operation does not touch —
    /// and force-close it (losing edits) or retarget it. Keeping the final
    /// component literal excludes such tabs. The canonical-tab vs entry comparison
    /// in `entryMatch(fileURL:operation:)` still matches a tab opened *through* a
    /// symlink to a real renamed/deleted target: that target's own final component
    /// is not a symlink, so its entry url equals its full canonical url, which the
    /// tab canonicalizes to. A tab opened *directly on the operated symlink itself*
    /// is matched by `entryMatch`'s companion lexical comparison — it must be
    /// reconciled (retargeted on rename, closed on delete), since the very link it
    /// points at is the entry being renamed/deleted (and its now-dangling url would
    /// otherwise be recreated by a later save).
    private func entryURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        return canonicalURL(standardized.deletingLastPathComponent())
            .appendingPathComponent(standardized.lastPathComponent, isDirectory: false)
    }

    /// Canonical url of an open file, or `nil` when it has no url yet.
    private func canonicalURL(of file: OpenFile) -> URL? {
        file.url.map(canonicalURL)
    }
}
