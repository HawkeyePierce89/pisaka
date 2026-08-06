#if os(macOS)
import AppKit
import Foundation
import PisakaCore

/// Drives the editor gutter's git-blame annotation column: it owns the per-tab
/// on/off state, issues the `git blame --porcelain` load for the displayed file,
/// and hands the result to `LineNumberRulerView`.
///
/// The split matches the rest of the editor: every decision that can be tested is
/// pure and lives in `PisakaCore` (`BlameParser` for the output, `BlameShift` for
/// the edit-driven shift the ruler applies), while this class only schedules the
/// load, guards it against supersession, and pushes the array into the ruler. It
/// is therefore thin, view-layer code and untested like the rest of
/// `Sources/Pisaka`, modeled on `BracketHighlightController` (weak view reference,
/// a monotonic `generation` token guarding async results, `attach`/`reset`).
///
/// **Three accepted inaccuracies, one rule: the column describes the file *on
/// disk*, as it was when the load was issued.** `GitServicing.blame(fileURL:)` is
/// a worktree blame, so an annotation always answers "who last changed this line
/// **in the file as git saw it then**". Reality can move out from under that
/// answer in three distinct ways — the buffer running ahead of the file (1 and 2)
/// or the *repository* changing beneath an unchanged file (3). All are accepted,
/// and they are stated together here so a reader meets them as one rule rather
/// than as three surprises.
///
/// 1. **A dirty, never-saved buffer.** Turning annotate on (or leaving it on)
///    while the buffer holds unsaved edits blames the *last saved* bytes, and
///    `BlameShift` only shifts annotations for edits made **after** the load — it
///    cannot know about line insertions/deletions the buffer already carried when
///    the load was issued. So on a dirty buffer the column can be **offset by
///    whole lines until the next autosave**: the load returns an array laid out
///    for the on-disk line numbering while the ruler indexes it by the buffer's
///    (`LineNumberRulerView.setAnnotations(_:)` places it through
///    `BlameAlignment.aligned`, which always yields exactly one entry per
///    displayed line, so a shorter or longer result bounds that into an offset
///    instead of a trap).
///    The window is short and closes without any user action:
///    `AutosaveController` fires after 2 s of idle, on a tab switch and on focus
///    loss, and every one of those advances `WorkspaceModel.diskRevisions`, which
///    reaches `sync(fileID:fileURL:diskRevision:contentReplaced:)` and recomputes.
///    The alternatives are worse than the symptom, which is why neither is built:
///    blaming a temp copy of the buffer through `git blame --contents -` would
///    blame a file git has never seen (every unsaved line comes back uncommitted
///    anyway, so the extra machinery buys a fraction of a second), and *saving on
///    toggle* would make a read-only inspection command write the user's file.
///    Blank-or-briefly-offset is the honest option.
/// 2. **Typing while a load is in flight.** The result describes the file as it
///    was on disk when the load was issued; on arrival it is installed against
///    whatever the buffer now holds. This is the same class of inaccuracy, and
///    likewise self-heals on the next save. The `generation` token guards against
///    *superseded loads and file switches*, deliberately not against edits made
///    while a load was in flight — cancelling on every keystroke would mean a file
///    being typed in never gets a column at all.
/// 3. **The repository changing while the file does not.** A `git commit`, `stash`,
///    `pull` or `rebase` run in the embedded terminal changes what `git blame`
///    answers *without* touching the buffer or its saved bytes, so no
///    `diskRevision` bump follows and `sync` issues no reload: freshly committed
///    lines keep rendering as uncommitted (blank) until the user switches tabs away
///    and back, or toggles annotate off and on. Unlike 1 and 2 this one does **not**
///    self-heal on a timer, and it is recorded rather than fixed because the app has
///    no signal to key it on: `treeRevision` is the only ambient
///    change notification, and `TreeRefreshFilter` deliberately drops everything
///    under the opened root's `.git` — the very rule that keeps a terminal
///    `git status` from flickering the project tree. Watching `.git` for this alone
///    would re-introduce that flicker's cost for an inspection affordance; the
///    honest trade is the stale column and this paragraph.
///
/// **Errors are swallowed.** A file outside a repository, an untracked file, a
/// missing `git` — all surface as a thrown `GitError`, which leaves the column
/// empty (and the toggle simply produces nothing). No alerts, no beeps: annotate
/// is an inspection affordance, not an operation the user asked to succeed.
@MainActor
final class BlameController {
    /// The gutter this controller feeds. Held weakly: the scroll view owns it,
    /// exactly as `Coordinator.lineNumberRuler` does.
    private weak var ruler: LineNumberRulerView?

    /// The real `git blame` runner. Its method is not `@MainActor`, so both the
    /// subprocess and the porcelain parse stay off the main thread (see
    /// `GitCLIService.blame(fileURL:)`).
    private let gitService = GitCLIService()

    /// The tabs the user turned annotate on for.
    ///
    /// **Deliberately never pruned on tab close** — recorded here so a reader does
    /// not re-derive it as an oversight. The set only ever grows, by one `UUID` per
    /// annotated tab, and is dropped wholesale in `reset()` when the editor is torn
    /// down. Three reasons:
    ///
    /// 1. **It cannot go wrong.** A `UUID` is never reused —
    ///    `WorkspaceModel.open(url:)` mints a fresh id even for a file that was
    ///    previously open and closed — so a stale entry can never match a live tab
    ///    and can never silently re-enable annotate for a different, or even for
    ///    the *same*, file. Closing and reopening a file starts with annotate off
    ///    either way, so pruning would change nothing a user can observe.
    /// 2. **The cost is a rounding error.** 16 bytes per entry, bounded by "tabs
    ///    annotated during this editor's lifetime" rather than by the project's
    ///    file count — a heavy session is a few kilobytes.
    /// 3. **Pruning is not free in the way it looks.** This controller knows only
    ///    the *displayed* file: it is handed a `fileID` per `sync`, never the
    ///    open-tab list, so an intersection-based prune would mean threading
    ///    `Set(model.openFiles.map(\.id))` from `ContentView` into `CodeEditorView`
    ///    on every body evaluation — a fresh set allocated on every keystroke,
    ///    since the editor binding republishes `openFiles` — plus a new view
    ///    parameter, to reclaim bytes.
    ///
    /// This deliberately **differs from `WorkspaceModel.removeFile`**, which *does*
    /// prune `textReplacementRevisions` and `diskRevisions`: those are `@Published`
    /// dictionaries in Core, live for the app's whole lifetime, and are pruned
    /// inside the exact method that learns about the close — one line at a site
    /// that already has the information, which this view-layer set has neither of.
    /// If a future feature ever hands the controller the open-tab list for its own
    /// reasons, pruning becomes the one-liner it is not today.
    private var enabledFileIDs: Set<UUID> = []

    /// The file whose blame is currently installed in the ruler, or `nil` when the
    /// column is empty. Compared against the displayed file in `sync` to reload on
    /// a tab switch.
    private var loadedFileID: UUID?

    /// The *path* the installed column was blamed at, or `nil` when the column is
    /// empty. Compared alongside `loadedFileID` in `sync`, because a tab's `url` can
    /// change while its id, its buffer and its `diskRevision` all stay put: a
    /// project-tree rename retargets the tab through
    /// `WorkspaceModel.applyRenamePlan(_:)`, which assigns `url` alone (`text` and
    /// `savedText` are deliberately untouched, so no `savedText` assigner runs and
    /// no disk-revision bump follows). Without this the reload decision would omit
    /// an input the *result* depends on, and the gutter would keep showing a blame
    /// taken at a path that no longer exists — until some unrelated later save
    /// happened to bump the revision.
    private var loadedFileURL: URL?

    /// The `WorkspaceModel.diskRevision(for:)` value last seen for each file this
    /// controller has been asked about — the `Coordinator.noteExternalTextRevision`
    /// precedent. The token's contract is *"it changed"*, never "+1", so this is
    /// only ever compared for (in)equality.
    ///
    /// **Also deliberately never pruned**, for the three reasons spelled out on
    /// `enabledFileIDs` above — with one asymmetry worth stating so it is not
    /// re-derived as an oversight: `sync` records the revision *before* the
    /// `enabledFileIDs` guard, so unlike that set this grows by one entry per tab
    /// the editor ever **displays**, whether or not annotate was used on it. The
    /// write has to come first because it is what makes the *next* `sync` able to
    /// tell "this file's disk content moved" from "nothing happened" — a file
    /// annotated after several saves must not reload against a revision it never
    /// saw. The cost stays a rounding error (a `UUID` plus an `Int` per displayed
    /// tab, dropped wholesale in `reset()`), and a stale entry is inert: it is only
    /// ever read for a `fileID` that is being displayed right now.
    private var lastSeenDiskRevisions: [UUID: Int] = [:]

    /// Monotonic token guarding an in-flight load against a newer request: a tab
    /// switch, a further save, a toggle-off, or teardown. A load that resumes with
    /// a stale token discards its result instead of painting it onto a file it does
    /// not describe.
    private var generation = 0

    /// Whether a `git blame` subprocess is currently running for this controller.
    ///
    /// The `generation` token alone guards the *result*, not the *execution*: it
    /// discards a superseded answer but the subprocess still runs to completion.
    /// `blame --porcelain` is the slowest git command in the app and is issued
    /// automatically — every autosave of an annotated file bumps `diskRevision`
    /// and so requests a reload — so on a large file in a deep history, where one
    /// blame outlasts the 2 s autosave window, unguarded issuing would queue
    /// subprocesses on `GitCLIService.blameQueue` faster than they drain: a
    /// monotonically growing backlog burning a core on answers that are discarded
    /// on arrival, with the visible column lagging by the whole queue rather than
    /// by one load. So at most **one** blame is ever in flight.
    private var isLoading = false

    /// The one request held back while `isLoading`, or `nil`.
    ///
    /// Only the newest is kept — an older one describes a state the newer request
    /// already supersedes — so the backlog is bounded at one running plus one
    /// waiting. Its `token` is the `generation` value stamped when it was
    /// recorded, so a `clearColumn()`/`reset()` in the meantime (a toggle-off,
    /// a buffer swap, teardown) drops it instead of re-annotating a file the user
    /// switched off.
    private var pending: PendingLoad?

    private struct PendingLoad {
        let token: Int
        let fileID: UUID
        let fileURL: URL
        let diskRevision: Int
    }

    /// Bind the controller to the editor's gutter (`makeNSView`).
    func attach(ruler: LineNumberRulerView) {
        self.ruler = ruler
    }

    /// The gutter's context-menu action for the displayed file: turn the column on
    /// (loading it) or off.
    ///
    /// A `nil` `fileURL` (an untitled buffer) is ignored — the menu item is already
    /// disabled through `LineNumberRulerView.canAnnotate`, so this is only the
    /// backstop for a programmatic call.
    func toggle(fileID: UUID, fileURL: URL?) {
        if enabledFileIDs.contains(fileID) {
            enabledFileIDs.remove(fileID)
            clearColumn()
            return
        }
        guard let fileURL else { return }
        enabledFileIDs.insert(fileID)
        let revision = lastSeenDiskRevisions[fileID] ?? 0
        lastSeenDiskRevisions[fileID] = revision
        load(fileID: fileID, fileURL: fileURL, diskRevision: revision)
    }

    /// Reconcile the column with the file the editor is showing (`updateNSView`,
    /// so this runs on every view update and must be cheap when nothing moved).
    ///
    /// A reload is issued only for an *enabled* file, and only when the shown file
    /// changed, its *path* changed (a project-tree rename — see `loadedFileURL`),
    /// its buffer was wholesale-replaced, or its `diskRevision` differs
    /// from the last value seen for it (a save, an autosave, a Save As, a
    /// post-revert reload, a merge apply, a branch checkout). Between them those
    /// cover every way the file *this editor* is looking at moves under the column;
    /// what they deliberately do not cover is the repository moving underneath an
    /// unchanged file — see inaccuracy 3 on the type. Everything else returns after recording the
    /// token. A per-file annotation cache is deliberately not kept: a reload is one
    /// short async subprocess, and reloading is also what keeps a tab correct after
    /// it was saved or checked out while off screen.
    func sync(fileID: UUID, fileURL: URL?, diskRevision: Int, contentReplaced: Bool) {
        ruler?.canAnnotate = fileURL != nil
        let previousRevision = lastSeenDiskRevisions[fileID]
        lastSeenDiskRevisions[fileID] = diskRevision

        guard enabledFileIDs.contains(fileID), let fileURL else {
            if loadedFileID != nil { clearColumn() }
            return
        }

        let needsReload = loadedFileID != fileID
            || loadedFileURL != fileURL
            || contentReplaced
            || previousRevision != diskRevision
        guard needsReload else { return }
        load(fileID: fileID, fileURL: fileURL, diskRevision: diskRevision)
    }

    /// Drop the column ahead of a wholesale `textView.string = text` assignment.
    ///
    /// That assignment posts a single full-range edit notification, which the
    /// ruler would otherwise run `BlameShift` over — shifting annotations across a
    /// whole-document replacement. Clearing first makes the shift a no-op; the
    /// following `sync` (with `contentReplaced: true`) reloads.
    func beginBufferSwap() {
        guard loadedFileID != nil else { return }
        clearColumn()
    }

    /// Drop all state and supersede any in-flight load (editor teardown).
    func reset() {
        generation += 1
        pending = nil
        enabledFileIDs = []
        lastSeenDiskRevisions = [:]
        loadedFileID = nil
        loadedFileURL = nil
        // Unconditional, so "no column installed" and "nothing running" always mean
        // the same thing. Today `reset()` is terminal (only `Coordinator.teardown()`
        // calls it, and the coordinator is discarded right after), so leaving this
        // `true` is unreachable rather than wrong — but a re-attached controller
        // would park its first `load` in `pending` forever, since only a *running*
        // load's completion drains it. The invariant costs one line; depending on a
        // call-site fact stated nowhere in the class does not.
        isLoading = false
        ruler?.clearAnnotations()
        ruler = nil
    }

    // MARK: - Internals

    /// Empty the column and supersede whatever load was feeding it.
    private func clearColumn() {
        generation += 1
        pending = nil
        loadedFileID = nil
        loadedFileURL = nil
        ruler?.clearAnnotations()
    }

    /// Run the blame for `fileURL` and install the result, unless a newer request
    /// superseded it in the meantime.
    ///
    /// A failure installs an *empty* array rather than leaving the column
    /// untouched: the file is enabled, so the ruler must be in the annotating state
    /// its context menu reports ("Close Annotations"), and an all-`nil` array of the
    /// displayed length draws nothing and contributes no width.
    ///
    /// A request arriving while another blame is running is *held* rather than
    /// issued (see `isLoading`/`pending`), so a session of repeated autosaves can
    /// never outrun the subprocess.
    private func load(fileID: UUID, fileURL: URL, diskRevision: Int) {
        generation += 1
        let token = generation
        loadedFileID = fileID
        loadedFileURL = fileURL
        lastSeenDiskRevisions[fileID] = diskRevision
        // Report annotate as on *now*, not when the subprocess returns: the file is
        // enabled from this point, and the gutter menu reads its title from the
        // ruler. See `LineNumberRulerView.beginAnnotating()`.
        ruler?.beginAnnotating()

        guard !isLoading else {
            pending = PendingLoad(
                token: token,
                fileID: fileID,
                fileURL: fileURL,
                diskRevision: diskRevision
            )
            return
        }
        run(fileURL: fileURL, token: token)
    }

    /// Issue the subprocess for one request and, once it resolves, install its
    /// result (when still current) and drain whatever was held back meanwhile.
    private func run(fileURL: URL, token: Int) {
        isLoading = true
        let service = gitService
        Task { [weak self] in
            let lines = try? await service.blame(fileURL: fileURL)
            guard let self else { return }
            self.isLoading = false
            if token == self.generation {
                self.ruler?.setAnnotations(lines ?? [])
            }
            self.runPendingLoad()
        }
    }

    /// Start the held-back request, unless something superseded it while it waited
    /// (a toggle-off, a buffer swap, teardown — each bumps `generation`).
    private func runPendingLoad() {
        guard let next = pending else { return }
        pending = nil
        guard next.token == generation else { return }
        run(fileURL: next.fileURL, token: next.token)
    }
}

#endif
