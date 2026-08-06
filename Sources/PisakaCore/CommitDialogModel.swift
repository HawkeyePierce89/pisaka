import Foundation

/// Observable state for the commit dialog: the repository context, the changed
/// files with their per-line selection, the author, the message, the Amend and
/// "Push after commit" switches, and the commit itself.
///
/// Mirrors `LocalChangesModel`/`MergeModel`'s shape — an `@MainActor
/// ObservableObject` funnelling every mutation through testable methods, with all
/// I/O behind `GitServicing`/`FileServicing` so the real `Process`-backed service
/// runs in `Pisaka` and in-memory stubs run here. Every *decision* it makes is a
/// pure function from Tasks 2–6 (`GitBlobText`, `FileCommitEligibility`,
/// `CommitDiffUnits`, `PartialCommitBuilder`, `CommitGate`, `PushPlan`,
/// `CommitPlan`, `CommitStaleness`); this type only sequences them and holds the
/// result. Pure Foundation — no `Process`/AppKit/SwiftUI.
///
/// **The diff is built here, not through `LocalChangesModel.rows(for:)`.** That
/// path takes the old side from `headContents(of:root:) -> String?`, whose `nil`
/// means only "absent from `HEAD`" and which arrives lossily decoded — so a file
/// that is binary in `HEAD` and text in the worktree reads as wholly *added*, with
/// per-line units over a falsely empty old side, and committing a subset of those
/// "added" lines would write a truncated text file over binary content with
/// nothing reporting an error. This model classifies both sides itself
/// (`headBlob` + `GitBlobText`, and the same rule applied to the working file) and
/// builds `LineDiff.rows` only for a file that is text on both sides.
@MainActor
public final class CommitDialogModel: ObservableObject {
    /// How a `commit()` ended.
    ///
    /// The cases are deliberately not collapsed into "succeeded / failed": the
    /// dialog closes on `.committed`, stays open showing git's stderr on
    /// `.failed`, and on `.committedPushFailed` must say *the commit exists* —
    /// retrying it as a commit would create a second one.
    public enum CommitOutcome: Equatable {
        /// The commit was created (and pushed, if that was asked for).
        case committed
        /// The commit was created; the push that followed it failed.
        case committedPushFailed(reason: String)
        /// `CommitGate` refused; nothing ran.
        case blocked(CommitBlock)
        /// The repository no longer looks the way the dialog says; nothing ran.
        case stale(CommitStaleReason)
        /// git refused. `reason` is its stderr, verbatim.
        case failed(reason: String)
        /// The opened project changed out from under this commit **before** it
        /// ran; nothing was written. A switch landing after the commit was created
        /// reports `.committed` instead — the contract here is "nothing ran", and a
        /// caller that treats this as "no commit exists" must be able to.
        case abandoned
    }

    /// The repository state, or `nil` before a successful load (which is also what
    /// makes `block` report `.noRepository`).
    @Published public private(set) var context: CommitContext?

    /// The changed files with their selection, in the order git reported them.
    @Published public private(set) var files: [CommitFileSelection] = [] {
        didSet { unifiedCache = nil }
    }

    /// The last `unifiedLines(for:)` answer, memoized by path.
    ///
    /// The flattened diff depends only on a file's `rows`, so `files`' `didSet` is
    /// the **fail-safe default**: any mutation whatsoever drops the memo, and no
    /// future writer has to remember to invalidate it. The memo exists because the
    /// dialog's body is re-evaluated on every keystroke in the message field and
    /// every checkbox click, and rebuilding a `UnifiedDiffLine` per row of the
    /// selected file each time puts the diff's size on the typing path — the same
    /// reason `CommitFileFacts` derives `eligibility`/`units` once.
    ///
    /// The `didSet` alone is not enough, because a *selection* mutation is a
    /// mutation: `toggleFile`/`toggleUnit` assign through the subscript and so
    /// dropped the memo on every checkbox click — the interaction it most needs to
    /// survive. They provably cannot invalidate it (both rebuild the element from
    /// the element's own `facts`, leaving every `rows` identical), so they go
    /// through `preservingUnifiedCache` and put it back. The fail-safe stays the
    /// default; the exemption is stated at the one place it holds.
    private var unifiedCache: (path: String, lines: [UnifiedDiffLine])?

    /// The author of the future commit, per-field-sourced. Unset until loaded,
    /// which blocks the commit exactly as git itself would.
    @Published public private(set) var identity = CommitIdentity(
        name: "",
        email: "",
        nameSource: .unset,
        emailSource: .unset
    )

    /// The commit message, bound to the dialog's text view.
    ///
    /// Editing it supersedes the last failure exactly as a selection or Amend
    /// change does (`clearStaleError()`), and for the same reason — with one case
    /// that is not merely symmetric but the commonest of all: a `commit-msg` hook
    /// refuses the *message*, so rewriting it is the direct response to that
    /// failure, and without this the panel kept quoting the refusal over the
    /// corrected text. The empty-field case is the sharper one: clearing the field
    /// leaves the button disabled for `.emptyMessage` while the panel still shows
    /// the hook's output, i.e. disabled with no visible explanation — precisely
    /// what `clearStaleError()` exists to prevent, reached through a different
    /// edit. Safe at every internal assignment too: each one either follows an
    /// `errorMessage = nil` in the same turn (`load`, `reset`, the post-commit
    /// wipe) or is already preceded by `clearStaleError()` (`setAmend`), and no
    /// path publishes a failure and *then* writes the message.
    @Published public var message: String = "" {
        didSet { clearStaleError() }
    }

    /// Whether this commit amends `HEAD`. Read-only because turning it on and off
    /// also moves the message field — see `setAmend(_:)`.
    @Published public private(set) var amend = false

    /// Whether a successful commit is followed by a push.
    @Published public var pushAfterCommit = false

    /// The path shown in the right-hand diff panel, or `nil` when nothing is
    /// selected (no files, or the dialog was invalidated).
    @Published public private(set) var selectedPath: String?

    /// The last failure to surface, or `nil`.
    @Published public private(set) var errorMessage: String?

    /// `true` while a load is in flight (the dialog shows a placeholder).
    @Published public private(set) var isLoading = false

    /// `true` between the start and the end of a `commit()`. The gate reads it, so
    /// a second commit while one runs is `.blocked(.alreadyRunning)` rather than a
    /// second `git commit` against a half-built index.
    @Published public private(set) var isRunning = false

    /// `true` while `setLocalIdentity` is writing the repository's config and
    /// re-reading the author line. The gate reads it, so a Commit pressed in that
    /// window is `.blocked(.identityWriteInProgress)` rather than a commit recording
    /// the identity the write is in the middle of replacing — see `CommitGate` for
    /// the two ways that goes wrong.
    @Published public private(set) var isWritingIdentity = false

    private let gitService: GitServicing
    private let fileService: FileServicing

    /// The repository top level the dialog is loaded against.
    @Published public private(set) var root: URL?

    /// The `HEAD` commit's message, offered into an empty field by Amend.
    private var headMessage: String?

    /// The text Amend inserted, and what the field held before it did. Turning
    /// Amend off restores the latter *only* while the field still equals the
    /// former verbatim — once the user has edited it, it is theirs.
    private var autoInsertedMessage: String?
    private var messageBeforeAmend: String?

    /// The folder last requested, and the monotonic token that advances whenever
    /// it changes. Same rule as `LocalChangesModel`: the token is bumped
    /// *synchronously* (in `prepareForFolderChange`, or at load entry), before any
    /// suspension, so an in-flight `commit()` sees a project switch the instant it
    /// resumes rather than a turn later — and a commit pinned to the previous
    /// project bails instead of writing into the newly opened one.
    private var lastRequestedRoot: URL?
    private var rootRequestGeneration = 0

    /// Orders overlapping loads: a superseded one discards its result rather than
    /// publishing the previous folder's files over the current ones.
    private var loadGeneration = 0

    /// The largest working file the dialog will read in order to offer per-line
    /// selection (`ProjectSearchModel.defaultMaxFileBytes`' value and reason).
    ///
    /// The load reads and diffs **every** changed file, on the main actor, and does
    /// it again immediately before the commit, so an uncapped read put an
    /// arbitrarily large generated file (a lock file, a bundled asset, a fixture)
    /// wholly into memory twice and ran an LCS over it while the sheet was up. Past
    /// the cap the file classifies as `.binary`, i.e. *committed whole* — which is
    /// both the safe outcome and the only one that was ever really on offer for a
    /// file that size.
    public static let maxSelectableFileBytes = 1 << 20

    /// How many files `loadFacts` reads between hands back to the main actor
    /// (`ProjectSearchModel.chunkSize`' value).
    ///
    /// The loop is `@MainActor` and its per-file work is *not reliably*
    /// suspending: `headSide` returns `.absent` **synchronously** for an added,
    /// untracked or deleted file, and `worktreeSide` and `LineDiff.rows` are
    /// synchronous throughout — so a change set made only of those statuses runs
    /// the whole loop as one uninterrupted main-actor block. That is not a corner
    /// case: it is exactly an initial commit on an unborn HEAD (every file
    /// untracked) and a `git rm -r` (every file deleted), and the sheet is
    /// already on screen by then, so its `ProgressView` cannot even animate while
    /// several thousand files are read and diffed — and the pre-commit re-read
    /// runs the identical loop a second time. The per-file cap bounds one file,
    /// nothing bounds the count.
    static let loadYieldStride = 32

    public init(gitService: GitServicing, fileService: FileServicing = FileService()) {
        self.gitService = gitService
        self.fileService = fileService
    }

    // MARK: - Derived state

    /// The files the commit would touch — `CommitPlan.build`'s own inclusion rule
    /// (`CommitFileSelection.isIncludedInCommit`), so "nothing selected" and "the
    /// plan is empty" agree by construction rather than by two copies of it.
    public var selectedFiles: [CommitFileSelection] { files.filter(\.isIncludedInCommit) }

    /// How many files the commit would touch (a rename is one file, though the
    /// plan spends two entries on it).
    public var selectedFileCount: Int { selectedFiles.count }

    /// The paths still in a conflicted state — any of them blocks the commit,
    /// checked or not, because git's own "you have unmerged files" refusal is what
    /// this stands in for.
    public var conflictedPaths: [String] {
        files.filter { $0.file.status == .conflicted }.map(\.path)
    }

    /// Why the commit is blocked, or `nil` when it may proceed.
    public var block: CommitBlock? {
        CommitGate.evaluate(
            context: context,
            identity: identity,
            message: message,
            selectedFileCount: selectedFileCount,
            amend: amend,
            conflictedPaths: conflictedPaths,
            isRunning: isRunning,
            isWritingIdentity: isWritingIdentity
        )
    }

    /// Whether the Commit button is enabled.
    public var canCommit: Bool { block == nil }

    /// What "Push after commit" would do, or `nil` before a successful load.
    public var pushPlan: PushPlan? { context.map(PushPlan.plan) }

    /// The selection for `path`, or `nil` when no such file is loaded.
    public func selection(for path: String) -> CommitFileSelection? {
        files.first { $0.path == path }
    }

    /// The three-state checkbox for `path` (`.unchecked` for an unknown path).
    public func checkboxState(for path: String) -> CheckboxState {
        selection(for: path).map(CheckboxState.of) ?? .unchecked
    }

    /// The sentence the right-hand panel draws **instead of** a diff for `path`,
    /// or `nil` when the file has line units to check (and an unknown path, which
    /// names no file to say anything about).
    ///
    /// The panel asks this first and, given an answer, draws neither the diff nor
    /// a single line checkbox — the rule and its wording both being
    /// `CommitFileFacts.wholeOnlyReason`'s, so the view stays a display of
    /// whatever Core decided. It is asked *before* `unifiedLines`, which is why
    /// that one is empty for every whole-only file: a file differing only in its
    /// line endings does have rows, all of them context, and flattening them would
    /// build a per-line array the panel then ignores.
    public func wholeOnlyMessage(for path: String) -> String? {
        selection(for: path)?.facts.wholeOnlyReason?.message
    }

    /// The unified diff lines the right-hand panel draws for `path` — empty for a
    /// whole-only file, which the panel replaces with a placeholder rather than a
    /// diff whose checkboxes cannot be clicked.
    public func unifiedLines(for path: String) -> [UnifiedDiffLine] {
        if let cached = unifiedCache, cached.path == path { return cached.lines }
        guard let selection = selection(for: path) else { return [] }
        // Every whole-only category, not just an ineligible one: a file whose only
        // difference is its line endings *is* selectable and has rows, all of them
        // context, and the panel draws the placeholder instead — so flattening the
        // whole file per body pass built an array nobody reads.
        guard selection.facts.wholeOnlyReason == nil else { return [] }
        let lines = CommitDiffUnits.unified(rows: selection.rows)
        unifiedCache = (path, lines)
        return lines
    }

    /// The `rootRequestGeneration` the dialog's current contents correspond to.
    /// A caller deferring `commit()` across a `Task` hop captures this
    /// synchronously and passes it back as `commit(originGeneration:)`.
    public var currentRequestGeneration: Int { rootRequestGeneration }

    // MARK: - Loading

    /// Synchronously record that the opened project is switching to `root`,
    /// clearing everything the dialog holds about the previous one.
    ///
    /// The `LocalChangesModel.prepareForFolderChange` precedent and the same
    /// reason: the app calls this in the main-actor turn that handles the folder
    /// open, *before* spawning the `Task` that loads, so an in-flight `commit()`
    /// observes the switch the instant it resumes. The message is cleared along
    /// with the files — it was composed about changes in a repository the user has
    /// left, and leaving it beside another project's file list would invite
    /// committing it there. Returns the (possibly bumped) generation for the
    /// caller to pin its load to; a repeated same-folder call is a no-op.
    @discardableResult
    public func prepareForFolderChange(root: URL) -> Int {
        guard root != lastRequestedRoot else { return rootRequestGeneration }
        lastRequestedRoot = root
        rootRequestGeneration += 1
        reset()
        return rootRequestGeneration
    }

    private func reset() {
        // `root` goes too: it is what every mutation runs against, and leaving the
        // previous repository's here would let the still-open author editor write
        // `git config --local` into the project the user has just navigated away
        // from. `isLoading` goes for the same class of reason — an in-flight load
        // discarded by this switch returns without clearing it, so leaving it
        // raised strands the dialog on its loading placeholder. `pushAfterCommit`
        // is a per-project opt-in and must not carry over silently.
        root = nil
        context = nil
        files = []
        selectedPath = nil
        isLoading = false
        pushAfterCommit = false
        identity = CommitIdentity(name: "", email: "", nameSource: .unset, emailSource: .unset)
        message = ""
        amend = false
        headMessage = nil
        autoInsertedMessage = nil
        messageBeforeAmend = nil
        errorMessage = nil
    }

    /// Load everything the dialog shows for the repository containing `root`.
    ///
    /// Resolves the repo top level first (so every path is repo-root-relative, the
    /// `LocalChangesModel.refresh` rule), then reads the context, the identity, the
    /// `HEAD` message and the changed files, and classifies both sides of each
    /// file. Every file starts fully checked: a dialog opened and confirmed with no
    /// further clicks commits every local change.
    ///
    /// `preselectedPath` is the JetBrains "Commit File" case — the dialog opened
    /// from one changed file's own context menu, where that file alone starts
    /// checked and every other one starts empty (`selections(for:preselecting:)`
    /// owns the rule, including what a path absent from the fresh list means). It is
    /// applied over the **freshly loaded** list, never over whatever the caller was
    /// looking at: the dialog runs its own `git status`, so the row that was
    /// right-clicked may since have been reverted, renamed or committed elsewhere,
    /// and matching against the fresh facts is what keeps the preselect honest. It
    /// is applied inside the publish block — the same main-actor iteration, *after*
    /// the generation guards — so the intermediate "everything checked" list is
    /// never published and the sheet cannot flash every file as selected.
    ///
    /// Nothing downstream needs to know a preselect happened: `commit()` rebuilds
    /// each selection onto fresh facts by path through
    /// `CommitFileSelection.withFacts`, which carries `selectedUnits`/`isChecked`
    /// verbatim, so an unselected file stays unselected; `CommitPlan.build` skips
    /// every file `isIncludedInCommit` reports `false` for; and
    /// `CommitStaleness.check` only inspects the planned paths.
    ///
    /// `request` is a generation captured synchronously by the caller; a load whose
    /// folder-open request a newer one superseded is rejected before doing any
    /// work, and a result that arrives after a newer load or a folder switch is
    /// discarded rather than published. A failure clears the state and surfaces the
    /// message — never crashing the view.
    public func load(root: URL, request: Int? = nil, preselectedPath: String? = nil) async {
        if let request, request != rootRequestGeneration { return }
        loadGeneration += 1
        let generation = loadGeneration
        // Register the switch through the one implementation of that rule rather
        // than restating it here: it is idempotent, so a load for the folder
        // already requested falls through to the per-open clear below.
        _ = prepareForFolderChange(root: root)
        // Reopening for the *same* project skips `reset()` above, so clear what
        // describes the previous read before this one starts. Leaving it published
        // let the sheet render the earlier snapshot's rows and per-line checkboxes
        // while the fresh read was still in flight — the loading placeholder is
        // gated on the list being empty — so a change made in the terminal between
        // the two openings was invisible and the user could compose a commit
        // against a list they had been shown as current (`CommitStaleness` then
        // aborts it, with a message about files they had no reason to doubt). A
        // leftover `errorMessage` from the previous attempt was displayed over the
        // fresh load for the same reason.
        files = []
        selectedPath = nil
        errorMessage = nil
        // Amend must not survive a Cancel: it is an intent formed against the HEAD
        // of the *previous* opening, and a silently pre-ticked checkbox is how a
        // history rewrite happens without anyone deciding to. Routed through
        // `setAmend(false)` so the message field is unwound exactly as unticking it
        // by hand would — HEAD's auto-inserted message withdrawn, anything the user
        // has since typed left alone.
        setAmend(false)
        let rootGeneration = rootRequestGeneration
        isLoading = true
        do {
            let repoRoot = try await gitService.repositoryRoot(for: root)
            let context = try await gitService.commitContext(root: repoRoot)
            let identity = try await gitService.identity(root: repoRoot)
            let headMessage = try? await gitService.headMessage(root: repoRoot)
            let changed = try await gitService.changedFiles(root: repoRoot)
            let facts = try await loadFacts(files: changed, root: repoRoot)
            guard generation == loadGeneration, rootGeneration == rootRequestGeneration else {
                return
            }
            self.root = repoRoot
            self.context = context
            self.identity = identity
            self.headMessage = headMessage ?? nil
            self.files = Self.selections(for: facts, preselecting: preselectedPath)
            // Show the file the user asked to commit, when it is really in the
            // fresh list; otherwise the first row, which is what every other
            // opening does — and say why, because leaving nothing selected is only
            // the *honest* outcome while something states it. The gate cannot carry
            // that message itself: the message field is empty at open, so its
            // answer is `.emptyMessage` (or an earlier repository-state block), and
            // the documented `.nothingSelected` recovery is not on screen until the
            // user has typed one — so without this the dialog would open with every
            // box clear, name no file, and read as if the preselect had simply been
            // ignored, inviting exactly the hand-checking the rule exists to avoid.
            //
            // The cost, accepted: the view shows `errorMessage ?? block?.message`,
            // so while this notice stands it *masks* the gate's own reason —
            // including the repository-state blocks that precede `.emptyMessage`
            // (`.operationInProgress`, `.conflictedFiles`, `.identityIncomplete`).
            // It is a notice about the opening rather than a failure, it retires
            // like any other `errorMessage` on the first keystroke or checkbox
            // click (`clearStaleError`), and the button stays disabled throughout —
            // so the block is delayed, never lost.
            if let preselectedPath, !self.files.contains(where: { $0.path == preselectedPath }) {
                self.selectedPath = self.files.first?.path
                self.errorMessage = Self.vanishedPreselectMessage(path: preselectedPath)
            } else {
                self.selectedPath = preselectedPath ?? self.files.first?.path
                self.errorMessage = nil
            }
            self.isLoading = false
        } catch {
            guard generation == loadGeneration, rootGeneration == rootRequestGeneration else {
                return
            }
            self.root = nil
            self.context = nil
            self.files = []
            self.selectedPath = nil
            self.errorMessage = error.localizedDescription
            self.isLoading = false
        }
    }

    /// The initial selection for a freshly loaded file list.
    ///
    /// With no `path` every file goes through `defaultSelection(for:)` — the one
    /// implementation of "fully checked", so the ordinary opening is expressed here
    /// rather than duplicated. With a `path`, that file gets the same full
    /// selection and every other one gets an empty selection (no units, checkbox
    /// off), which `CommitFileSelection.isIncludedInCommit` reports `false` for
    /// under both of its branches — a file with units because none is checked, one
    /// without because the file-level box is off.
    ///
    /// The comparison is by `ChangedFile.path`, i.e. the **new** path for a rename
    /// — the same value the Local Changes row carries and the same key
    /// `CommitStaleness`/`CommitPlan` index by, so a renamed file preselects under
    /// exactly the identity the rest of the pipeline uses.
    ///
    /// A `path` absent from the list (the row was reverted, committed elsewhere or
    /// renamed again between the right-click and the dialog's own `git status`)
    /// simply leaves **every** file unselected. That is the honest outcome:
    /// `CommitGate` then blocks with `.nothingSelected` and the user picks what they
    /// meant, whereas falling back to selecting everything would answer a request to
    /// commit one file by arming a commit of all of them. `load` additionally names
    /// the missing path in `errorMessage` (`vanishedPreselectMessage(path:)`) —
    /// unselected *and unexplained* would read as the preselect having been ignored,
    /// since with an empty message field the gate's first answer is `.emptyMessage`
    /// rather than `.nothingSelected`.
    static func selections(
        for facts: [CommitFileFacts],
        preselecting path: String?
    ) -> [CommitFileSelection] {
        guard let path else { return facts.map(defaultSelection(for:)) }
        return facts.map { fact in
            fact.path == path
                ? defaultSelection(for: fact)
                : CommitFileSelection(facts: fact, selectedUnits: [], isChecked: false)
        }
    }

    /// What the dialog says when it was opened from one file's Commit… item and
    /// that file is not in the list its own `git status` produced.
    ///
    /// The wording lives in Core beside the rule it explains, for the same reason
    /// `CommitBlock.message` and `CommitStaleReason.message` do: the decision and
    /// its explanation are one thing, unit-tested together, while the sheet stays a
    /// thin display of whatever it is handed.
    static func vanishedPreselectMessage(path: String) -> String {
        "\"\(path)\" is no longer among the local changes, so nothing is selected."
    }

    /// A freshly loaded file, fully checked.
    private static func defaultSelection(for facts: CommitFileFacts) -> CommitFileSelection {
        CommitFileSelection(
            facts: facts,
            selectedUnits: Set(facts.units),
            isChecked: true
        )
    }

    /// Read and classify both sides of every file, and diff the ones that are text
    /// on both sides.
    ///
    /// A whole-only file gets **no rows at all** rather than rows over decoded
    /// garbage: they would be meaningless (and expensive) for a binary file, and
    /// `CommitFileFacts.units` already refuses to hand out units for one. Both the
    /// load and the pre-commit re-read go through this same function, so the
    /// staleness comparison is between two answers produced the same way.
    ///
    /// It yields to the main actor every `loadYieldStride` files (see there for
    /// why the loop cannot be relied on to suspend on its own). Nothing is
    /// published from inside the loop — both callers commit their state only after
    /// re-checking their generation — so the extra suspension points change what
    /// is *observable* not at all, exactly as the `headBlob` awaits already
    /// interleaved here do.
    private func loadFacts(files: [ChangedFile], root: URL) async throws -> [CommitFileFacts] {
        var result: [CommitFileFacts] = []
        result.reserveCapacity(files.count)
        for (index, file) in files.enumerated() {
            if index > 0, index % Self.loadYieldStride == 0 { await Task.yield() }
            let head = try await headSide(for: file, root: root)
            let worktree = worktreeSide(for: file, root: root)
            let eligibility = FileCommitEligibility.classify(
                status: file.status,
                head: head,
                worktree: worktree
            )
            let rows = eligibility == .selectable
                ? LineDiff.rows(old: head.text ?? "", new: worktree.text ?? "")
                : []
            result.append(
                CommitFileFacts(file: file, head: head, worktree: worktree, rows: rows)
            )
        }
        return result
    }

    /// The `HEAD` side of `file`, classified from raw bytes.
    ///
    /// A rename is read from its *old* path — the new one does not exist at `HEAD`.
    /// An added or untracked file is `.absent` without asking git: neither can have
    /// a `HEAD` entry (a path present at `HEAD` and staged is reported *modified*),
    /// so the subprocess would only confirm what the status already says, once per
    /// untracked file.
    ///
    /// A **deleted** file is `.absent` for a different reason — it certainly *has*
    /// a `HEAD` entry, but nothing ever reads it. `FileCommitEligibility.classify`
    /// returns `.wholeOnly(reason: .deleted)` from the status before looking at
    /// `head`, so no units are handed out and no rows are diffed, and
    /// `CommitPlan.build` emits `.removePath` before touching either side. Asking
    /// git anyway meant one `git show HEAD:<path>` per deleted file at open **and**
    /// again in the pre-commit re-read — 800 subprocesses for a `git rm -r` of a
    /// 400-file directory — each result decoded and then retained, up to
    /// `maxSelectableFileBytes` apiece, for the life of the dialog. The only
    /// consumer was `CommitStaleness.sameKind`, which compares two answers produced
    /// by this same function and so is unaffected by both sides becoming `.absent`.
    ///
    /// `maxSelectableFileBytes` is applied **here as well as** to the working file,
    /// so the cap covers both sides symmetrically. Capping only the worktree left
    /// the `HEAD` blob of a large tracked text file (an 8 MB lock file, a checked-in
    /// dump) read, decoded and then *retained* in `files` for the life of the
    /// dialog — twice over, since `commit()` re-reads every file before it writes —
    /// which is exactly the memory the cap exists to bound. Past the cap the side
    /// classifies `.binary`, i.e. the file is committed whole and no LCS runs over
    /// it, the same outcome the worktree cap already produces.
    private func headSide(for file: ChangedFile, root: URL) async throws -> BlobText {
        switch file.status {
        case .added, .untracked, .deleted:
            return .absent
        case .modified, .renamed, .conflicted:
            let path = file.oldPath ?? file.path
            let data = try await gitService.headBlob(of: path, root: root)
            if let data, data.count > Self.maxSelectableFileBytes { return .binary }
            return GitBlobText.classify(data)
        }
    }

    /// The working-tree side of `file`, classified by the same rule.
    ///
    /// A symlink contributes its **target string** — what git stores as the blob —
    /// rather than the contents of whatever it points at, so the diff compares what
    /// would be committed instead of pulling in a file from outside the repository
    /// (`LocalChangesModel.workingText`'s rule).
    ///
    /// A read failure is `.binary`, i.e. "there is no text to select lines from",
    /// which is the safe direction: the file is offered whole rather than as
    /// selectable lines over content nobody could read.
    ///
    /// **A file that is not there is `.absent`, not `.binary`**, and that
    /// distinction is load-bearing rather than cosmetic. A status of `.deleted` is
    /// not the only way to reach a missing working file: a path staged with `git
    /// add` and then deleted from the worktree is porcelain `AD`, which
    /// `GitStatusParser` maps to `.added` (it tests `A` before `D`). Classified
    /// `.binary` such a file was described to the user as "binary, unreadable, or
    /// very large" and — being whole-only with no units — reached the executor as
    /// `.addFromWorktree`, i.e. `git update-index --add` on a path with no file,
    /// which exits 128 (`does not exist and --remove not passed`). Since the plan is
    /// applied atomically that aborted the **entire** commit, including every other
    /// perfectly valid file, leaving the user to work out from git's stderr which
    /// checkbox to clear. As `.absent` it takes `CommitPlan.build`'s existing
    /// `worktree == .absent` branch and is committed as the removal it is.
    ///
    /// The probe is the read's own error rather than a new `FileServicing` method:
    /// both the real byte-level implementation (`Data(contentsOf:)`) and the
    /// protocol extension's default (`String(contentsOf:)`) report a missing file as
    /// `CocoaError.fileReadNoSuchFile`. Any *other* failure — permissions, an I/O
    /// error — stays `.binary`, the conservative reading.
    private func worktreeSide(for file: ChangedFile, root: URL) -> BlobText {
        guard file.status != .deleted else { return .absent }
        let url = root.appendingPathComponent(file.path)
        if let target = fileService.symbolicLinkDestination(at: url) { return .text(target) }
        do {
            let text = try fileService.readTextIfNotBinary(
                url: url,
                maxBytes: Self.maxSelectableFileBytes
            )
            guard let text else { return .binary }
            return .text(text)
        } catch {
            return Self.isNoSuchFile(error) ? .absent : .binary
        }
    }

    /// Whether `error` means "there is no file at that path".
    private static func isNoSuchFile(_ error: Error) -> Bool {
        let code = (error as NSError).code
        guard (error as NSError).domain == NSCocoaErrorDomain else { return false }
        return code == CocoaError.fileReadNoSuchFile.rawValue
            || code == CocoaError.fileNoSuchFile.rawValue
    }

    // MARK: - Selection

    /// Drop the last failure once the user acts on it.
    ///
    /// The dialog shows `errorMessage ?? block?.message`, so a failure that
    /// outlived the state it described — a refused `pre-commit` hook, a `.stale`
    /// abort — kept masking the *live* reason the Commit button is disabled. After
    /// unchecking everything the button would be disabled for `.nothingSelected`
    /// while the panel still quoted the hook, i.e. disabled with no visible
    /// explanation. Any selection, Amend or **message** change supersedes the
    /// report — the last of those through `message`'s own `didSet`, since the
    /// field is bound straight to the published property.
    private func clearStaleError() {
        if errorMessage != nil { errorMessage = nil }
    }

    /// Show `path` in the right-hand panel (a no-op for an unknown path).
    public func select(path: String) {
        guard files.contains(where: { $0.path == path }) else { return }
        selectedPath = path
    }

    /// Toggle a whole file: a fully checked file clears, anything else — including
    /// a **mixed** one — becomes fully checked. Clicking a partially selected
    /// file's checkbox therefore selects the rest of it rather than discarding what
    /// was already picked, which is the JetBrains behaviour and the non-destructive
    /// reading of an ambiguous click.
    public func toggleFile(path: String) {
        guard let index = files.firstIndex(where: { $0.path == path }) else { return }
        clearStaleError()
        let selection = files[index]
        let checkAll = CheckboxState.of(selection) != .checked
        preservingUnifiedCache {
            files[index] = CommitFileSelection(
                facts: selection.facts,
                selectedUnits: checkAll ? Set(selection.facts.units) : [],
                isChecked: checkAll
            )
        }
    }

    /// Run `mutation`, putting the memoized unified diff back afterwards.
    ///
    /// Only for a mutation that provably leaves every file's `rows` untouched —
    /// see `unifiedCache`, whose `didSet` invalidation this deliberately opts out
    /// of. The two selection mutators qualify because each rebuilds its element
    /// from that element's own `facts`.
    private func preservingUnifiedCache(_ mutation: () -> Void) {
        let cached = unifiedCache
        mutation()
        unifiedCache = cached
    }

    /// Toggle one line unit of `path`.
    ///
    /// An index that names no unit — a context row, an out-of-range index, a
    /// whole-only file's row — is ignored rather than trapping: the view can hold a
    /// row index across a reload, and degrading here must never mean crashing.
    public func toggleUnit(_ index: Int, path: String) {
        guard let fileIndex = files.firstIndex(where: { $0.path == path }) else { return }
        let selection = files[fileIndex]
        guard selection.facts.unitSet.contains(index) else { return }
        clearStaleError()
        var units = selection.selectedUnits
        if units.contains(index) {
            units.remove(index)
        } else {
            units.insert(index)
        }
        preservingUnifiedCache {
            files[fileIndex] = CommitFileSelection(
                facts: selection.facts,
                selectedUnits: units,
                isChecked: selection.isChecked
            )
        }
    }

    // MARK: - Amend

    /// Turn Amend on or off, moving the message field with it.
    ///
    /// Turning it **on** offers `HEAD`'s message, but only into a field that is
    /// empty after trimming — text the user has already typed is never overwritten.
    /// Turning it **off** restores what the field held before, but only while it
    /// still equals the inserted text *verbatim*: once the user edited it, it is
    /// their message and restoring would delete their work.
    public func setAmend(_ on: Bool) {
        guard on != amend else { return }
        clearStaleError()
        amend = on
        if on {
            guard message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let headMessage,
                  !headMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            messageBeforeAmend = message
            message = headMessage
            autoInsertedMessage = headMessage
        } else {
            if let autoInsertedMessage, message == autoInsertedMessage {
                message = messageBeforeAmend ?? ""
            }
            autoInsertedMessage = nil
            messageBeforeAmend = nil
        }
    }

    // MARK: - Identity

    /// Write `name`/`email` into the repository's **local** config and re-read the
    /// author line from git, so the dialog shows what git resolved rather than what
    /// was typed. Returns whether the write succeeded; a failure surfaces its
    /// message and leaves the identity as it was.
    ///
    /// `isWritingIdentity` is raised for the whole sequence, which the gate turns
    /// into `.identityWriteInProgress`: the write is two sequential `git config
    /// --local` commands sharing the commit's serial queue, so a Commit pressed
    /// before they land would record the old identity — or, between them, the new
    /// name beside the old email. A re-entrant call cannot happen (the "Edit…"
    /// button is disabled while the flag is up) but is harmless if one ever does:
    /// the flag is lowered by `defer` on every path, and the last writer wins on a
    /// value that was going to be re-read from git anyway.
    @discardableResult
    public func setLocalIdentity(name: String, email: String) async -> Bool {
        guard let root else {
            errorMessage = CommitBlock.noRepository.message
            return false
        }
        isWritingIdentity = true
        defer { isWritingIdentity = false }
        do {
            try await gitService.setLocalIdentity(name: name, email: email, root: root)
            identity = try await gitService.identity(root: root)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Commit

    /// Create the commit the dialog describes, and push it when asked to.
    ///
    /// The order is the substance:
    ///
    /// 1. **Pinning.** `originGeneration` is the project token the caller captured
    ///    synchronously, in the same main-actor turn as the click — this body runs
    ///    a later turn, so without it a folder switch committed in between would
    ///    let a commit composed for one repository run against another
    ///    (`LocalChangesModel.revert(_:originGeneration:)`'s precedent).
    /// 2. **The gate**, which also rejects a second commit while one runs.
    /// 3. **The re-read.** The dialog's modality stops the app's own writers and
    ///    nothing else — `git` in the embedded terminal, an external editor, a
    ///    build script all keep running — and the selection names *row indices*, so
    ///    a file re-diffed differently turns a checked line into a different one.
    ///    The whole change *list* is re-read — it has to be fresh, since a file
    ///    that became conflicted since is not in the plan and would otherwise be
    ///    invisible — while the re-diff covers the *included* files, which are the
    ///    only ones anything compares. Any divergence aborts the **whole batch**: a commit is one
    ///    atomic artifact, so applying the clean part of a stale plan would create a
    ///    commit nobody composed. The repository state is re-read with it and the
    ///    two "stand-in for git" blocks re-checked
    ///    (`CommitGate.evaluateRepositoryState`).
    /// 4. **The plan**, built from the *fresh* facts — the check guarantees the
    ///    decisions still hold, rebuilding onto fresh facts guarantees the bytes
    ///    are the ones on disk now.
    /// 5. **The push**, only after the commit exists and only when asked —
    ///    running the plan built from a *second* context read taken immediately
    ///    before it, and refusing when the current branch moved in between (the
    ///    commit runs hooks and signing, which is time enough for a checkout
    ///    elsewhere to make the branch this commit is on a different one). A plan
    ///    that is not available, a branch that moved and a failed push are all
    ///    reported as `.committedPushFailed`; a push the user asked for is never
    ///    skipped silently.
    @discardableResult
    public func commit(originGeneration: Int? = nil) async -> CommitOutcome {
        if let originGeneration, originGeneration != rootRequestGeneration { return .abandoned }
        guard let root else { return .blocked(.noRepository) }
        if let block { return .blocked(block) }

        let requestGeneration = rootRequestGeneration
        func projectStillCurrent() -> Bool { rootRequestGeneration == requestGeneration }

        isRunning = true
        defer { isRunning = false }

        let planned = selectedFiles
        let amendNow = amend
        let messageNow = message
        // Pinned at entry with the rest of the intent, not re-read after the
        // commit. The switches stay live while this runs (a sheet disables the main
        // menu no more than it disables its own controls), and the commit is the
        // long part — hooks, signing — so reading it afterwards let a tick made in
        // that window publish to a remote the user had not armed at the moment they
        // pressed Commit, and an untick silently drop a push they had. Every other
        // input above is pinned for exactly this reason; the view disables the
        // toggle while `isRunning` so what is on screen cannot disagree with it.
        let pushNow = pushAfterCommit
        // The branch the push is decided *for*, read now rather than taken from
        // the `context` published at load: a `git checkout` in the embedded
        // terminal while the sheet was up leaves the load-time plan naming the
        // *previous* branch, and `.setUpstream` spells that name out — so the push
        // would create a tracking ref for, and push, a branch the new commit is not
        // on, while the commit itself stays unpushed.
        //
        // Only the branch is carried forward. Whether pushing is *possible* is
        // deliberately not decided here: the plan the push runs is re-derived after
        // the commit anyway, and that path already reports an unavailable plan as
        // `.committedPushFailed`. Gating on a pre-commit plan as well added a
        // second, *silent* outcome for the same condition — a push the user asked
        // for skipped with no notice, reported as a plain `.committed` — which is
        // strictly less informative than the path it duplicated.
        var pushBranch: String?
        do {
            let freshContext = try await gitService.commitContext(root: root)
            pushBranch = freshContext.currentBranch
            let current = try await gitService.changedFiles(root: root)
            // The *list* has to be fresh in full — a file that became conflicted
            // since is not in the plan and would otherwise be invisible to
            // `evaluateRepositoryState` below — but the expensive part, reading
            // both sides and running an LCS over them, is only ever consumed for
            // the **included** files: `CommitStaleness.check` looks up `planned`
            // paths alone (a planned path absent from the re-read is `.vanished`,
            // which a filtered list reports identically), and so does the
            // `withFacts` rebuild under it. Re-reading the rest cost a `git show`
            // subprocess plus a main-actor LCS per unchecked file, paid again on
            // every failed retry, for facts nothing reads.
            let plannedPaths = Set(planned.map(\.path))
            let facts = try await loadFacts(
                files: current.filter { plannedPaths.contains($0.path) },
                root: root
            )
            guard projectStillCurrent() else { return .abandoned }
            // The two blocks that stand in for git's own refusals, re-checked
            // against state read just now rather than when the dialog opened: a
            // merge or rebase started in a terminal since then would otherwise be
            // recorded as an ordinary one-parent commit, which is precisely what
            // the throw-away index stops git from refusing on its own.
            let freshConflicts = current.filter { $0.status == .conflicted }.map(\.path)
            if let block = CommitGate.evaluateRepositoryState(
                context: freshContext,
                conflictedPaths: freshConflicts
            ) {
                errorMessage = block.message
                return .blocked(block)
            }
            // Amend rewrites whatever `HEAD` is at the instant git runs, so the
            // commit it replaces has to be pinned as deliberately as the files are.
            // Nothing above catches a moved HEAD: `CommitStaleness` compares files,
            // and every other `CommitContext` field describes a shape that an
            // ordinary `git commit` in the embedded terminal leaves untouched. Only
            // checked while amending — for a normal commit HEAD moving is simply the
            // new parent, which is correct.
            if amendNow,
               let planned = context?.headHash,
               let now = freshContext.headHash,
               planned != now {
                errorMessage = CommitStaleReason.headMoved.message
                return .stale(.headMoved)
            }
            if let reason = CommitStaleness.check(planned: planned, current: facts) {
                errorMessage = reason.message
                return .stale(reason)
            }
            let byPath = CommitStaleness.indexed(facts)
            let fresh = planned.map { selection in
                byPath[selection.path].map(selection.withFacts) ?? selection
            }
            try await gitService.commit(
                CommitPlan.build(selections: fresh),
                message: messageNow,
                amend: amendNow,
                root: root
            )
        } catch {
            guard projectStillCurrent() else { return .abandoned }
            let reason = error.localizedDescription
            errorMessage = reason
            return .failed(reason: reason)
        }

        // The commit exists from here on: every path below reports that, and none
        // of them may present itself as `.abandoned`, whose contract is "nothing
        // ran". A project switch landing in this window means the dialog's fields
        // belong to a repository that is no longer open — `reset()` has already
        // cleared them and the push would target the previous root — so the state
        // mutations and the push are skipped, but the outcome is still the truth:
        // a commit was created.
        guard projectStillCurrent() else { return .committed }
        errorMessage = nil
        message = ""
        autoInsertedMessage = nil
        messageBeforeAmend = nil
        amend = false

        if pushNow {
            do {
                // Re-read immediately before the push, and push the plan *that*
                // read produces. Building the command from the pre-commit read
                // leaves a window as long as the commit itself — hooks and signing
                // can take seconds — in which a `git checkout` from the embedded
                // terminal or another tool makes the plan name a branch that is no
                // longer current: `.setUpstream` would then publish, and set a
                // tracking ref on, a branch that did *not* receive this commit,
                // while the commit stayed unpushed and the dialog reported success.
                // Reading again costs a handful of local git calls in front of a
                // network operation, and closes the window down to the push's own
                // process launch.
                let pushContext = try await gitService.commitContext(root: root)
                guard pushContext.currentBranch == pushBranch else {
                    // The commit exists but is on a different branch than the one
                    // the push was decided for. Refusing is the honest outcome:
                    // pushing now would publish somebody else's branch, and the
                    // dialog reports "commit created, push failed" so the user can
                    // push it from where it actually is.
                    let reason = PushUnavailableReason.branchChanged.message
                    if projectStillCurrent() { errorMessage = reason }
                    return .committedPushFailed(reason: reason)
                }
                let plan = PushPlan.plan(context: pushContext)
                guard case let .unavailable(reason) = plan else {
                    try await gitService.push(plan, root: root)
                    return .committed
                }
                // The branch is the same one, but pushing it stopped being
                // possible (a remote removed while the commit ran). Same reporting
                // rule: the commit exists, the push did not happen, say which.
                if projectStillCurrent() { errorMessage = reason.message }
                return .committedPushFailed(reason: reason.message)
            } catch {
                let reason = error.localizedDescription
                if projectStillCurrent() { errorMessage = reason }
                return .committedPushFailed(reason: reason)
            }
        }
        return .committed
    }
}
