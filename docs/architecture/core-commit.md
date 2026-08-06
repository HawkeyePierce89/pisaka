# PisakaCore — commit-dialog domain

Design documentation moved verbatim from the root `CLAUDE.md` (which now holds only a one-line-per-file index). Each entry records a file's contract, invariants and the reasoning behind non-obvious decisions — read the relevant entry before modifying that file, and update it when behavior changes.

  - `GitFileMode.swift` — the file mode a *partial* commit has to name
    explicitly, and the two decisions around it, pure and Foundation-only (in Core
    for the `ShellQuote`/`BlameParser`/`GitStatusParser` reason: the `Process` run
    and the `lstat` stay in `GitCLIService`, but a wrong mode fails **silently** —
    it drops an exec bit, or records a symlink whose target is a whole file's text,
    with the damage visible only on a later checkout). The three constants
    (`regular` `100644` / `executable` `100755` / `symlink` `120000`),
    `parse(lsTreeOutput:)` (the leading run of digits of a `git ls-tree` record;
    `nil` for empty or non-numeric output, so the caller falls back to the working
    file rather than inventing a mode), `worktree(isSymlink:isExecutable:)`, and
    `reconciled(head:worktree:)` — keep the *recorded* mode when the link/non-link
    type still matches (so committing three lines of an executable script never
    drops its exec bit, even where the working file's own permissions differ), and
    on a typechange record a **regular file whenever the worktree is the link**,
    the working file's mode otherwise (the case documented on `CommitModeSource`).
    Both directions of a typechange matter and only one of them is obvious. A link
    at `HEAD` replaced by a file is the stated case: keeping `120000` would record
    a symlink whose target is the assembled text. The *forward* direction — a
    regular file at `HEAD` replaced by a **link** — reaches the identical
    corruption from the other side, since both sides still classify as text (the
    worktree's being the link's target string), so a partial selection is offered
    and assembled while the *worktree* mode is `120000`; taking it wholesale would
    stage that assembled mixture as a link target. A blob this app assembled line
    by line is never a link target, so a typechange to a link resolves to
    `regular` — and the exec bit is not carried across one either, the working
    file being a link. git validates neither mode, so nothing reports the mistake:
    it surfaces only as a broken link on a later checkout. A whole file needs none of this: it enters the commit
    through `.addFromWorktree`, i.e. git stages the working file and resolves its
    own mode. Unit-tested in `GitFileModeTests`.
  - `GitBlobText.swift` — classifies raw git blob bytes for the commit dialog:
    `public enum BlobText: Equatable` (`.absent` / `.binary` / `.text(String)`,
    plus `text`) and `GitBlobText.classify(_ data: Data?) -> BlobText`.
    The three cases are deliberately distinct and **none is expressible through
    another**, which is the whole reason the type exists rather than a `String?`:
    `.absent` is a fact about the *repository* (git has no object at that path for
    that revision), decided by git's exit code in `headBlob`, while `.binary` and
    `.text` are facts about the *bytes*, decided here. Collapsing the first into
    the second — which `headContents(of:root:) -> String?` inevitably does — is
    what makes a file binary in `HEAD` and text in the worktree read as wholly
    *added*. The rule is exactly `FileService.readTextIfNotBinary`'s, shared
    rather than restated: a NUL inside the first `FileService.binaryProbeBytes`
    (8000, git's own `buffer_is_binary` window) ⇒ `.binary`, then strict UTF-8
    with a failure ⇒ `.binary` (an encoding the editor cannot round-trip must not
    be lossily decoded and written back), else `.text` — an empty blob included,
    since an empty file that exists at `HEAD` is an ordinary case rather than
    absence. Foundation-only, unit-tested in `GitBlobTextTests`.
  - `CommitDiffUnits.swift` — what a partial commit can *select*, and how it is
    presented (Foundation-only, the `LineDiff`/`DuplicateEngine` split: every
    decision here, the drawing in the view). `WholeOnlyReason`
    (`.deleted`, `.binaryInHead`, `.binaryInWorktree`, `.noSelectableChanges`)
    carries the sentence the dialog's right-hand panel shows in place of a diff —
    the text living in Core for the `GitError.errorDescription`/
    `EntryPathIssue.message` reason. `FileCommitEligibility`
    (`.selectable` / `.wholeOnly(reason:)`) is decided by
    `classify(status:head:worktree:)` from the two sides, in an order that is
    itself the substance: a deletion is whole-only whatever the bytes were, then
    either side being **binary** disqualifies the file, and what is left is
    selectable (a missing worktree side is treated as a deletion — the file
    vanished since the snapshot, and there is nothing to select either way). An
    **absent `HEAD` side is deliberately not a disqualification**: an added or
    untracked file has no `HEAD` entry by definition and is precisely the case a
    per-line selection over an empty old side is right for (the builder takes
    `head: ""`), so only *worktree* absence is rejected — there the missing side is
    the one being committed. `selectableUnits(rows:)` is every non-`unchanged` row
    index in row order — **a unit is a `LineDiff.rows` index**, not a line number
    on either side, which would be ambiguous for a `.modified` row that has one on
    each — and the `selectableUnits(eligibility:rows:)` overload returns `[]` for
    a whole-only file, enforcing that rule at the one place units are handed out
    rather than restating it per call site — which is why the unguarded
    `selectableUnits(rows:)` it delegates to is **internal**, not public: a public
    bypass is exactly the drift the guarded overload exists to prevent (the tests
    reach it through `@testable`). `UnifiedDiffLine`
    (`kind` `.context`/`.removed`/`.added`, `text`, `oldNumber`, `newNumber`,
    `unitIndex`) + `unified(rows:)` flatten the side-by-side rows into the
    dialog's single-column diff: a `.modified` row expands into a removed/added
    **pair sharing one `unitIndex`** (one change, one checkbox), and a context
    line carries no `unitIndex` so it can never be checked. **The line-endings
    boundary is deliberate:** `LineDiff` compares terminator-*stripped* lines, so
    a file whose only change is a CRLF↔LF rewrite produces no changed row and
    therefore **zero units** — it is committed whole or not at all, and the panel
    says so with a placeholder instead of a diff with not one clickable checkbox
    in it (the `.noSelectableChanges` case, which is decided from the *rows* and
    so is produced by `CommitFileFacts.wholeOnlyReason`, not by `classify`; its
    wording stays general because line endings are only its commonest cause —
    a mode-only change and a file staged and then restored in the worktree land
    there too).
  - `PartialCommitBuilder.swift` — the central new logic: assemble what a
    *partial* commit records for one file, i.e. the `HEAD` version with only the
    selected changes applied. `assemble(head:worktree:rows:selectedUnits:) ->
    String`, pure and Foundation-only. **The separator rule is one rule, not
    several:** every emitted line carries the terminator *of the side it came
    from* — an unchanged line and an unselected change from the old side verbatim,
    a selected change from the new side verbatim — and "the file lost or gained
    its final newline" is a value of that same rule rather than a branch, since
    `TerminatedLines` gives an unterminated final line an empty terminator.
    Nothing here invents, normalizes or drops a separator, because a commit must
    not rewrite line endings the user did not select. **The invariant: an empty
    selection reproduces the `HEAD` bytes identically** — structural, since
    `LineDiff` emits every old line exactly once and in order and each is emitted
    from the old side verbatim, so the concatenation is `head` by
    `TerminatedLines`' round-trip invariant. **The one separator it does supply:**
    only a side's *final* line can be unterminated, so emitting it and then
    emitting anything at all would fuse two lines into a third present on neither
    side — a `head` ending `"…\nb"` with `"c"` and `"d"` appended and only `"c"`
    checked assembled `"…\nbc\n"`, and since `CommitPlan` routes a *partial*
    selection through the builder, that line went into history (the "fully checked
    files bypass the builder" escape does not cover it). Whenever more follows an
    unterminated line the separator its **counterpart on the other side** carries
    is inserted first (a plain `"\n"` when there is none to borrow) — the
    separator the file gained by growing past that line, so a CRLF file does not
    silently acquire an LF. It never fires for an empty selection (nothing is
    emitted after `head`'s last line), so the invariant above is untouched.
    **The converse is deliberately *not*
    an invariant:** "selecting every unit yields the worktree bytes" holds only
    when every unchanged line is terminated the same way on both sides, because a
    line whose separator alone switched produces no changed row — there is no unit
    for it, nothing to check — and the rule above emits it from the old side with
    the old terminator. Where that stronger guarantee is actually needed it is
    obtained **structurally instead**: a fully checked file bypasses the builder
    entirely and is placed into the index from the working file by git itself (see
    `CommitPlan`). A selected
    index naming no row, or naming an `unchanged` one, is ignored rather than
    trapping — a selection can outlive a re-diff, and catching that is
    `CommitStaleness`' job, not this function's.
  - `CommitIdentity.swift` — the author of the future commit as the dialog shows
    it. `IdentityFieldSource` (`.local`/`.global`/`.unset` — `.global` being
    "everything above this repository", one answer as far as the dialog is
    concerned) and `CommitIdentity` (`name`, `email`, `nameSource`, `emailSource`,
    `isComplete`, `signature`) plus the pure
    `resolve(localName:localEmail:effectiveName:effectiveEmail:)`. The feature
    exists for one failure it must make impossible — a work repository silently
    committing under a personal *global* name because nothing on screen said which
    config the identity came from — so the source is carried **per field** and
    `signature` names a single source (`Name <email> (local)`) only when the two
    genuinely share one, spelling them separately (`Name (local) <email>
    (global)`) the moment they differ; a mixed pair is an ordinary state halfway
    through fixing a repository's identity, and a single "(local)" marker would
    misreport it. The **displayed value is the *effective* one** — what git will
    actually write — while the local read only decides the label. Invariant: a
    value is empty exactly when its source is `.unset`, normalized in both
    directions by the initializer, so no caller can construct an identity that
    displays a name while reporting it missing. **Editing writes the local config
    only** (`git config --local user.name/user.email`): nothing in this feature
    touches the global config, a deliberate limit rather than an omission — the
    global identity is a machine-wide setting and a commit dialog is the wrong
    place to change one.
  - `CommitContext.swift` — the repository state the dialog reads once on open
    (pure value type, the `BranchRef`/`ChangedFile` precedent): `isUnbornHEAD`,
    `isDetachedHEAD`, `currentBranch` (short name), `upstream` (short tracking
    ref), `remotes`, `inProgress`, and `headHash` (the commit `HEAD` resolved to,
    `nil` on an unborn/unreadable HEAD). `headHash` exists for exactly one job —
    **identifying the commit an amend would rewrite**. Every other field describes
    a *shape* the dialog reacts to, and none of them changes when `HEAD` merely
    moves, so a `git commit` run in the embedded terminal while the sheet is up
    left the pre-commit re-read entirely satisfied (`CommitStaleness` compares
    files) and `--amend` rewrote a commit the user had never seen, under the
    message of the one they had. `CommitDialogModel.commit` compares it against a
    fresh read *only when amending* — for an ordinary commit a moved HEAD is
    simply the new parent — and refuses with `CommitStaleReason.headMoved`. It
    costs no extra subprocess: `commitContext` already runs `rev-parse --verify
    --quiet HEAD` to decide `isUnbornHEAD`, and this is that command's own stdout.
    `InProgressOperation`
    (`.merge`/`.cherryPick`/`.revert`/`.rebase`) with
    `detect(markerNames:)` over the git directory's entry names, matched
    **exactly** as git writes them (so a user's own `merge_head` is not mistaken
    for a merge) and reporting a rebase first, since a rebase stopped on a
    conflicting patch can leave several markers at once. **Why an in-progress
    operation blocks the commit**, recorded here rather than only in the gate: the
    temporary-index mechanism means git never sees the *real* index and so never
    raises `error: you have unmerged files` nor `fatal: cannot do a partial commit
    during a merge` — both of which exist to stop a commit that silently drops the
    second parent or the conflict resolutions. With them bypassed, blocking is the
    only thing left between the user and a merge "finished" as an ordinary
    one-parent commit. **Consequence, deliberate: a merge commit cannot be created
    from the UI** — finishing a merge, rebase, cherry-pick or revert stays a
    console job. `isUnbornHEAD` is carried separately from `currentBranch` because
    an unborn HEAD still *has* a branch name (the one the first commit will
    create), which is what lets amend be blocked without withdrawing the push
    plan.
  - `CommitGate.swift` — the single decision "may this dialog commit right now,
    and if not, why". `CommitBlock` (`.noRepository`, `.alreadyRunning`,
    `.identityWriteInProgress`,
    `.operationInProgress(_)`, `.amendOnUnbornHEAD`, `.conflictedFiles([String])`,
    `.identityIncomplete`, `.emptyMessage`, `.nothingSelected`) with its `message`
    text in Core, and `evaluate(context:identity:message:selectedFileCount:amend:
    conflictedPaths:isRunning:isWritingIdentity:) -> CommitBlock?`.
    `isWritingIdentity` sits beside `isRunning` because it is the same kind of fact
    — an operation this dialog started is still in flight — and it blocks for a
    reason of its own: the author editor **dismisses on Save** while the write is
    still two sequential `git config --local` commands queued on the *same serial
    queue* as the commit's own steps, so an ungated Commit pressed in that window
    records the identity being replaced, or — landing between the two writes — the
    new name beside the old email. That is exactly the silent misattribution the
    author line exists to make impossible, so the gate closes the window rather than
    leaving it to how fast the user can click. Two of these blocks **stand in
    for protections git itself would normally provide** (see `CommitContext`),
    which is also why the conflict block does not care whether the conflicted file
    is *checked* — git refuses on the presence of unmerged entries, not on what
    the commit touches — and why `.operationInProgress` fires whatever the Amend
    checkbox says, so "amend during a merge" cannot slip past a rule written only
    for the ordinary path. `selectedFileCount` is exactly the number of files
    `CommitPlan` would include (a file checked whole — a binary or deleted one
    included — counts one, as does a file with at least one unit checked; a
    rename spends two *entries* but is one file), so "nothing selected" and "the
    plan is empty" cannot disagree. With amend on, an empty file selection is
    legal (a message-only amend) — and, since both entry points are gated on the
    project alone, reachable: a clean working tree is exactly when it is wanted.
    The check order is *mostly* "what the user cannot fix without leaving the
    dialog before what they can", with one deliberate exception —
    `.amendOnUnbornHEAD` sits among the first group although unchecking Amend fixes
    it in place, because it says the *combination* is impossible and must not hide
    behind a conflict the user would then resolve for nothing. A second entry
    point, `evaluateRepositoryState(context:conflictedPaths:)`, re-checks **only**
    the two blocks that stand in for git's own refusals, and `commit()` runs it
    against freshly read state immediately before committing: `evaluate` answers
    "is the button enabled" and so necessarily reads what the dialog loaded, but a
    `git merge`/`rebase`/`cherry-pick` started in a terminal while the sheet is up
    leaves it enabled — and the throw-away index stops git from refusing on its own
    — so without the re-check the merge would be recorded as an ordinary
    one-parent commit. The other blocks are deliberately *not* repeated: the
    identity, the message and the selection are the dialog's own state.
  - `PushPlan.swift` — what "Push after commit" would do, decided from the
    repository state alone (pure; `GitCLIService.push(_:root:)` turns the plan
    into a command and decides nothing). `PushUnavailableReason`
    (`.detachedHEAD`/`.noRemote`/`.branchChanged`, each with its `message` — the
    last one is never produced by `plan(context:)`, being the verdict of
    `CommitDialogModel.commit`'s re-read immediately before the push, and lives
    here so its wording sits with the other push refusals) and `PushPlan`
    (`.push(upstream:)` / `.setUpstream(remote:branch:)` /
    `.unavailable(reason:)`, plus `isAvailable`) built by
    `plan(context:)` in three ordered branches: an upstream exists → a plain `git
    push` (decided **before** the remote list, since a configured upstream is
    something git can push through on its own — withdrawing the push because `git
    remote` came back empty would refuse an operation that works; the `upstream`
    short ref is carried for display only, no refspec is guessed); no upstream but
    a remote exists → `--set-upstream`, preferring `origin` and otherwise the
    first remote (stable, since `git remote` prints sorted) with the dialog naming
    the target it picked; otherwise unavailable, a detached or unreadable HEAD
    reported ahead of a missing remote. **The plan describes the state *after* the
    commit**, which is why an unborn HEAD is still pushable — the very first
    commit of a fresh repository can create its upstream in the same gesture.
  - `CommitPlan.swift` — what the commit will do to the throw-away index, decided
    purely from the selection (the `PushPlan`/`CommitGate` split: the
    `GIT_INDEX_FILE` juggling lives in `GitCLIService` and decides nothing).
    `CommitPlanEntry` (`.addFromWorktree(path:)` / `.addContent(path:content:
    modeSource:)` / `.removePath(path:)`) and `CommitModeSource`
    (`.head(path:)`/`.worktree(path:)` — a partial blob is content this app
    produced, so no file on disk carries its mode; an entry git already records
    keeps the mode it has, so committing three lines never silently drops an exec
    bit). `.head` is the mode git *records*, **not** an assertion about the working
    file's current type, so the executor reconciles the two through the pure
    `GitFileMode.reconciled(head:worktree:)` before staging: a path that changed
    between a symlink and a regular file is reported as an ordinary modification
    (porcelain's `T`, which `GitStatusParser` maps to `.modified`) and so arrives
    as selectable text on both sides — the link's side being its target string —
    and staging the assembled text under *either* side's `120000` would record a
    symlink whose target is that whole text, silently, since git validates
    neither; so a typechange records a regular file whenever the link is the
    worktree, and the working file's mode otherwise (see `GitFileMode` for why
    both directions need saying). **The split between the first two cases is the substance of the
    type:**
    `.addFromWorktree` hands git the *working file* and lets it resolve the
    symlink, the exec bit, clean filters and `core.autocrlf` exactly as `git add`
    would, while `.addContent` is the only case carrying assembled text.
    `CommitFileFacts` (`file`, `head`, `worktree`, `rows` — deliberately *only*
    the facts, no selection, which is what lets `CommitStaleness` compare a
    snapshot against a fresh read without comparing the user's choices) exposes
    `eligibility`, `units`, and `wholeOnlyReason` — the single question the
    right-hand panel asks, collapsing all **three** whole-only categories
    (deleted; a side that is not text; a selectable file with **zero** units
    because something other than its lines changed, which `FileCommitEligibility`
    cannot see since it never looks at the rows) into one answer rather than
    letting the view re-derive them. `eligibility`/`units` are **derived once in
    `init`** rather than computed per read: the facts are immutable and both sit on
    the dialog's hot path, where SwiftUI re-evaluates the whole body on every
    keystroke in the message field and reads them several times per file, so
    re-running `classify` and a full `rows.indices.filter` there put the diff's
    size on the typing path. `CommitFileSelection` (facts + `selectedUnits` +
    `isChecked`, with `withFacts(_:)`, `effectiveUnits` and `isIncludedInCommit`):
    a file with units is decided by `selectedUnits` *alone* so a stale checkbox
    cannot smuggle in a file with nothing selected, while a file with **no** units
    has nothing to derive a state from and there `isChecked` is the only signal.
    `isIncludedInCommit` is that rule's **single implementation** — `CommitPlan
    .build` skips a file it reports `false` for and `CommitDialogModel
    .selectedFiles` (i.e. `CommitGate`'s `selectedFileCount`) counts the ones it
    reports `true` for, so "nothing selected" and "the plan is empty" agree by
    construction rather than by two copies being kept in step.
    `CheckboxState` (`.unchecked`/`.mixed`/`.checked`) follows that same fork —
    with no units the checkbox is two-state, since `.mixed` would claim a partial
    selection that cannot exist and make a binary or deleted file read as broken
    in the list. `CommitPlan.build(selections:)` walks the files in order: nothing
    selected → **no entry at all**; a rename removes its old path first; a deleted
    or vanished file removes its path; a file with no units or with every unit
    selected → `.addFromWorktree`; anything else → `PartialCommitBuilder` +
    `.addContent`. **Both boundaries are therefore structural**, which is the
    point of the type: "nothing selected = HEAD" cannot be got wrong by an
    assembly bug because no assembly happens, and "everything selected = the
    worktree" holds by construction rather than by the builder agreeing (it
    deliberately does not, under mixed line endings). **Two consequences of the
    model, recorded because they are surprising and deliberate:** (1) a manual
    `git add` from the terminal is *overwritten* by a commit from the dialog — the
    index is seeded with `read-tree HEAD` plus exactly what the UI shows as
    checked (the JetBrains model, "what you selected is what you committed"), and
    the staging itself is discarded by the `git reset --quiet` that follows a
    successful commit, though the changes remain in the working tree as ordinary
    local changes; (2) the *staged* effects of a formatting `pre-commit` hook are
    erased the same way — the commit does contain its edits (git runs the hook
    before reading the index it commits), the hook's **worktree** edits survive as
    local changes, and only the staging is unstaged. `CommitStaleness.check(
    planned:current:) -> CommitStaleReason?` is the check run immediately before
    the commit — the `LocalChangesModel.revert` per-file re-query applied to a
    batch, and for the same reason: the dialog's modality stops the app's *own*
    writers and nothing else (`git` in the embedded terminal, an external editor,
    a build script all keep running), and the selection names **row indices**, so
    a file re-diffed differently turns a checked line into a different line,
    silently, in the one direction where the mistake is written into history. It
    compares the *decisions* — status, the rename's old path, whether each side is
    absent/binary/text, and the rows — and deliberately **not** raw bytes (a whole
    file's bytes are read by git at commit time, exactly as `git add` would, and a
    partial file's content is assembled from the **fresh** facts via
    `withFacts(_:)`), so a rewrite leaving every row identical passes and is
    committed as it now stands. `CommitStaleReason` (`.vanished`,
    `.statusChanged`, `.renameChanged`, `.contentKindChanged`, `.diffChanged`,
    each naming the path in its `message`, plus `.headMoved`, which names none —
    it is a fact about the repository rather than about any one path, which is why
    `path` is `String?`). **The abort is the whole batch, not
    the file:** a commit is one atomic artifact, so applying the clean part of a
    stale plan would create a commit the user never composed — one reason comes
    back and nothing is written.
  - `CommitDialogModel.swift` — `@MainActor ObservableObject` for the commit
    dialog, mirroring `LocalChangesModel`/`MergeModel`'s shape (IO behind
    `GitServicing`/`FileServicing`, every *decision* a pure function from the
    types above, pure Foundation — no `Process`/AppKit/SwiftUI). Publishes
    `context`, `files` (`[CommitFileSelection]` in git's order), `identity`,
    `message`, `amend`, `pushAfterCommit`, `selectedPath`, `errorMessage`,
    `isLoading`, `isRunning` and `root`, with computed `selectedFiles`/
    `selectedFileCount`, `conflictedPaths`, `block`/`canCommit` (through
    `CommitGate`), `pushPlan`, `checkboxState(for:)`, `wholeOnlyMessage(for:)` and
    `unifiedLines(for:)` — the last **empty for every whole-only file** (asked
    after `wholeOnlyMessage`, so a line-endings-only change flattens nothing the
    panel would ignore) and **memoized by path**, invalidated from `files`'
    `didSet` so the cache cannot drift: the sheet's body re-evaluates on every
    keystroke in the message field, and rebuilding a `UnifiedDiffLine` per row
    there puts the diff's size on the typing path, the same reason
    `CommitFileFacts` derives `eligibility`/`units` once. **The diff is built here, not through
    `LocalChangesModel.rows(for:)`**: that path takes the old side from
    `headContents` and would turn a file binary in `HEAD` into "wholly added" with
    per-line units over a falsely empty old side — committing a subset of those
    "added" lines would write a truncated text file over binary content with
    nothing reporting an error — so this model classifies both sides itself
    (`headBlob` + `GitBlobText`, and the same rule over the working file, a
    symlink contributing its *target string* per `LocalChangesModel.workingText`'s
    rule) and builds `LineDiff.rows` **only** for a file that is text on both
    sides; a whole-only file gets no rows at all. An added/untracked file's HEAD
    side is `.absent` without asking git (neither can have a `HEAD` entry) — as is
    a **deleted** file's, for the opposite reason: it certainly has one, but
    `classify` decides `.wholeOnly(.deleted)` from the status before looking and
    `CommitPlan.build` emits `.removePath` without touching either side, so the
    subprocess only bought a decoded blob nothing reads and everything retains
    (800 of them for a `git rm -r` of 400 files, counting the pre-commit
    re-read) — and a
    worktree read failure is `.binary` — "there is no text to select lines from",
    the safe direction. `load(root:request:preselectedPath:)` resolves the repo top
    level first,
    reads the context/identity/HEAD message/changed files, and starts **every file
    fully checked** (a dialog opened and confirmed with no further clicks commits
    every local change) — unless `preselectedPath` names one, the JetBrains "Commit
    File" case where the dialog was opened from a single changed file's own context
    menu and **only that file starts checked**. The rule is the internal pure
    `selections(for:preselecting:)`: `nil` runs every file through
    `defaultSelection(for:)` (one implementation of "fully checked", so the ordinary
    opening is expressed through the same function rather than duplicated), a path
    gives that file the same full selection and every other one an empty one (no
    units, checkbox off), which `CommitFileSelection.isIncludedInCommit` reports
    `false` for under *both* of its branches. The comparison is by
    `ChangedFile.path`, i.e. the **new** path for a rename — the same value the
    Local Changes row carries and the same key `CommitStaleness`/`CommitPlan` index
    by, so a renamed file preselects under exactly the identity the rest of the
    pipeline uses. Two properties of *where* it is applied are load-bearing. It runs
    over the **freshly loaded** list rather than over whatever the caller was looking
    at — the dialog runs its own `git status`, so the right-clicked row may since
    have been reverted, renamed or committed elsewhere — and a path **absent** from
    that fresh list leaves *every* file unselected, the honest outcome
    (`CommitGate` then blocks with `.nothingSelected` and the user picks what they
    meant) rather than falling back to selecting everything, which would answer a
    request to commit one file by arming a commit of all of them — **named**, not
    silent: `load` publishes `vanishedPreselectMessage(path:)` into `errorMessage`
    (the wording in Core beside the rule, the `CommitBlock.message` precedent),
    because unselected *and unexplained* reads as the preselect having been
    ignored. The gate cannot carry that message itself: the field is empty at open,
    so its answer is `.emptyMessage` (or an earlier repository-state block), and
    `.nothingSelected` — the documented recovery — is not on screen until the user
    has typed a message, at which point the notice has already retired through the
    ordinary `clearStaleError()` path. The accepted cost: the view shows
    `errorMessage ?? block?.message`, so while the notice stands it *masks* the
    gate's own reason — including the blocks that precede `.emptyMessage`
    (`.operationInProgress`, `.conflictedFiles`, `.identityIncomplete`). It retires
    on the first keystroke or checkbox click and the button stays disabled
    throughout, so a block is delayed, never lost.
    And it is applied
    **inside the publish block** — the same main-actor iteration, *after* the
    `loadGeneration`/`rootRequestGeneration` guards — so the intermediate
    "everything checked" list is never published and the sheet cannot flash every
    file as selected. `selectedPath` follows it, showing the preselected file when
    it is really in the fresh list and otherwise `files.first?.path` (the
    no-preselect and vanished-path behaviour). Nothing downstream needs to know a
    preselect happened: `commit()` rebuilds each selection onto fresh facts by path
    through `CommitFileSelection.withFacts`, which carries
    `selectedUnits`/`isChecked` verbatim, so an unselected file stays unselected;
    `CommitPlan.build` skips every file `isIncludedInCommit` reports `false` for; and
    `CommitStaleness.check` only inspects the planned paths.
    `prepareForFolderChange(root:)` is the synchronous
    switch registration (the `LocalChangesModel` precedent, clearing the message
    along with the files — it was composed about another repository's changes).
    Its `reset()` also drops `root`, `isLoading` and `pushAfterCommit`, each for
    its own reason: `root` is what every mutation runs against, so keeping the
    previous one would let the still-open author editor write `git config --local`
    into the repository the user just left; a load *discarded* by this very switch
    returns without clearing `isLoading`, so leaving it raised strands the dialog
    on its loading placeholder with no path back; and "Push after commit" is a
    per-project opt-in that must not carry over silently. A *reopen for the same
    root* takes `prepareForFolderChange`'s no-op path and so runs no `reset()`,
    which is why `load` additionally clears `files`/`selectedPath`/`errorMessage`
    itself before its first `await`: leaving them published let the sheet draw the
    **previous** opening's rows and per-line checkboxes as current while the fresh
    read was in flight (the loading placeholder is gated on the list being
    *empty*), so a change made in the terminal between the two openings was
    invisible and a commit could be composed against a list the user had been shown
    as current — `CommitStaleness` then aborts it, quoting files they had no reason
    to doubt. `load` also unwinds **Amend** through `setAmend(false)` (so HEAD's
    auto-inserted message is withdrawn with it while anything the user typed is
    left alone): amend is an intent formed against the *previous* opening's HEAD,
    and a silently pre-ticked checkbox is how a history rewrite happens without
    anyone deciding to. Both sides of every file are
    capped at `maxSelectableFileBytes` (1 MiB, `ProjectSearchModel
    .defaultMaxFileBytes`' value): the load reads and diffs *every* changed file on
    the main actor and does it again before the commit, so past the cap a file
    classifies `.binary`, i.e. committed whole — which is both the safe outcome and
    the only one really on offer at that size. The cap covers the **`HEAD` blob as
    well as the working file**, symmetrically and for the same reason: applied only
    to the worktree, the `HEAD` side of a large tracked *text* file (an 8 MB lock
    file, a checked-in dump) was still read, decoded and then *retained* in `files`
    for the life of the dialog — and again by the pre-commit re-read — which is
    precisely the memory the cap exists to bound. The cap bounds *one* file and
    nothing bounds the **count**, so the loop hands the main actor back every
    `loadYieldStride` (32) files: its per-file work is not reliably suspending —
    `headSide` returns `.absent` **synchronously** for an added, untracked or
    deleted file and both the worktree read and `LineDiff.rows` are synchronous —
    so a change set of only those statuses ran the whole loop as one uninterrupted
    main-actor block, which is exactly an initial commit on an unborn HEAD (every
    file untracked) and a `git rm -r` (every file deleted), with the sheet already
    on screen and its spinner unable to animate through it. Nothing is published
    from inside the loop (both callers commit their state only after re-checking
    their generation), so the added suspension points change nothing observable —
    the `headBlob` awaits already interleave there for a modified file.
    A working file that is **not there** classifies `.absent`, not `.binary`, and
    that distinction is load-bearing rather than cosmetic. A status of `.deleted`
    is not the only route to a missing working copy: a path staged with `git add`
    and then deleted from the worktree is porcelain `AD`, which `GitStatusParser`
    maps to `.added` (it tests `A` before `D`). Read as `.binary` such a file was
    described to the user as "binary, unreadable, or very large" and, having no
    units, reached the executor as `.addFromWorktree` — `git update-index --add` on
    a path with no file, which exits 128 — and since the plan is applied atomically
    that aborted the **entire** commit, every other perfectly valid file included,
    leaving the user to work out from git's stderr which checkbox to clear. As
    `.absent` it takes `CommitPlan.build`'s existing `worktree == .absent` branch
    and is committed as the removal it is. The probe is the read's own error rather
    than a new `FileServicing` method (both the byte-level implementation and the
    protocol extension's default report a missing file as
    `CocoaError.fileReadNoSuchFile`); any *other* failure — a permission error, an
    I/O error — stays `.binary`, since "unreadable" and "absent" are different
    facts and committing the former as a deletion would be a silent removal.
    `toggleFile` makes a **mixed** file fully checked rather than clearing it (the
    JetBrains behaviour and the non-destructive reading of an ambiguous click);
    `toggleUnit` ignores an index that names no unit. All three selection mutators
    (and `setAmend`, and **`message`** through its own `didSet`, the field being
    bound straight to the published property) also **clear `errorMessage`**: the
    dialog shows `errorMessage
    ?? block?.message`, so a failure that outlived the state it described — a
    refused `pre-commit` hook, a `.stale` abort — kept masking the *live* reason
    the button is disabled, leaving it disabled with no visible explanation once
    the user unchecked everything. The message is the commonest case rather than
    merely the symmetric one: a `commit-msg` hook refuses the *message*, so
    rewriting it is the direct response to that failure, and *clearing* the field
    reproduces the no-visible-explanation state exactly (disabled for
    `.emptyMessage` under the old hook's output). `setAmend(_:)` moves the
    message field with the checkbox: turning it **on** offers `HEAD`'s message but
    only into a field empty after trimming, turning it **off** restores what was
    there before but only while the field still equals the inserted text
    *verbatim* — once edited it is the user's message. `setLocalIdentity(name:
    email:)` writes local config and re-reads the author line from git, so the
    dialog shows what git resolved rather than what was typed; it raises the
    published `isWritingIdentity` for that whole sequence (lowered by `defer` on
    every path), which the gate turns into `.identityWriteInProgress` — the author
    editor dismisses on Save while the two `git config --local` commands are still
    queued behind the commit's own serial queue, so an ungated Commit in that window
    records the identity being replaced, or the new name beside the old email. The
    "Edit…" button is disabled for the same window, so a second editor cannot be
    seeded from the identity being replaced. `commit(
    originGeneration:) -> CommitOutcome` sequences: the origin pin (the
    `revert(_:originGeneration:)` precedent — captured by the *view*, in the
    Commit button's action before its `Task` hop, since this body already runs
    inside that task and a token read here would only ever be compared against
    itself), the gate, the re-read of the **whole change list** (the list itself
    has to be fresh — a file that became conflicted since is not in the plan and
    would otherwise be invisible to the repository-state re-check — while the
    re-*diff* under it covers the **included** files only, since
    `CommitStaleness.check` and the `withFacts` rebuild both look up planned paths
    alone and a planned path missing from a filtered list reports `.vanished`
    identically; re-reading the rest spent a `git show` subprocess plus a
    main-actor LCS per unchecked file, again on every failed retry, for facts
    nothing consumes) with
    `CommitStaleness` aborting the whole batch, a re-check of the two "stand-in for
    git" blocks against freshly read repository state
    (`CommitGate.evaluateRepositoryState`), the plan built from the **fresh** facts
    — both lookups over those facts going through `CommitStaleness.indexed(_:)`, so
    the check and the plan cannot resolve one path to two different sets of rows —
    and only then the push — *whether* it runs being the `pushAfterCommit` value
    **pinned at entry** beside `amendNow`/`messageNow`/the file selection, since the
    switches stay live while the commit does (a sheet disables its own controls no
    more than it disables the main menu) and the commit is the long part: reading
    the flag afterwards let a tick made in that window publish to a remote the user
    had not armed when they pressed Commit, and an untick silently drop a push they
    had. The view disables **every control feeding a pinned input** while
    `isRunning` — the message field, the Amend and push switches, the file and
    per-line checkboxes, and the author "Edit…" button — so what is on screen
    cannot disagree with the pinned value. The message field is the case that
    loses work rather than merely misleading: the run *is* the long window (hooks,
    signing) in which a typo gets noticed, and on success the field is cleared and
    the sheet closes, so a correction typed there would vanish with nothing saying
    the commit had not carried it. The author button is the case that is not a
    display inconsistency at all — `setLocalIdentity` runs `git config --local` on
    the *same serial queue* as the commit's own steps, so a write landing between
    them would decide by scheduling which identity the commit records, the one
    thing that line exists to make certain. The plan it runs is a `PushPlan` built from a
    context read
    **immediately before it**, never the `pushPlan` the checkbox was drawn from at
    load, since the window everything else here is re-checked against applies to
    it too: a `git checkout` in the embedded terminal while the sheet is up leaves
    the load-time plan naming the *previous* branch, and `.setUpstream` spells that
    name out — so the push would create a tracking ref for, and push, a branch the
    new commit is not on while the commit itself stayed unpushed (a switch also
    changes *which* of the three branches the plan takes). The pre-commit read
    contributes **only the branch** to compare against — deliberately *not* a
    second availability gate: whether pushing is possible is the post-commit
    plan's decision alone, and gating on the earlier read as well added a
    *silent* outcome for that same condition (a push the user asked for skipped
    with no notice, reported as a plain `.committed`) beside the path that
    reports it properly. The plan that is executed comes from a second read after the commit, because the commit
    is itself the longest part of that window (a `pre-commit` hook, signing), and a
    branch that moved across it means the plan no longer names the branch that
    received the commit — so the push is refused with
    `PushUnavailableReason.branchChanged` and reported as
    `.committedPushFailed` rather than publishing somebody else's branch under a
    success message. The same reporting covers a plan that became `.unavailable`
    in that window (a remote removed mid-commit); the residual window is the push's
    own process launch. `CommitOutcome`
    (`.committed`, `.committedPushFailed(reason:)`, `.blocked(_)`, `.stale(_)`,
    `.failed(reason:)`, `.abandoned`) is deliberately not collapsed into
    succeeded/failed: the dialog closes on `.committed`, stays open showing git's
    stderr on `.failed`, and on `.committedPushFailed` must say *the commit
    exists* — retrying it as a commit would create a second one. `.abandoned`
    means **nothing ran**, so a project switch landing *after* the commit was
    created reports `.committed` instead (with the state mutations and the push
    skipped): reporting a real commit as "nothing ran" would make the caller skip
    its post-commit refreshes and leave a dialog whose Commit button makes a
    second one.
