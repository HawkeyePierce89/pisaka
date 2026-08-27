# Pisaka app (macOS) — git UI & GitCLIService

Design documentation moved verbatim from the root `CLAUDE.md` (which now holds only a one-line-per-file index). Each entry records a file's contract, invariants and the reasoning behind non-obvious decisions — read the relevant entry before modifying that file, and update it when behavior changes.

  - `FilePanels.swift` — wrappers over `NSOpenPanel`/`NSSavePanel`
    (`showOpenFolderPanel(directoryURL:message:)` chooses a directory — **both
    parameters defaulted to today's "Open Folder…" behaviour**, so no existing call
    site changes and, in particular, `canCreateDirectories` is raised *only* when a
    directory is suggested, keeping the New Folder button out of every
    "open a project" panel; the LeetCode folder chooser is the one caller that
    supplies them, because it *suggests* `~/Documents/LeetCode` rather than asking
    the user to find something — see `core-leetcode.md`), the confirm-close `NSAlert`,
    and `confirmRevert(fileNames:)` — a warning-style destructive-confirm
    `NSAlert` (listing the affected files in `informativeText`, "Revert"/"Cancel"
    buttons, returning `true` only on Revert), mirroring `confirmClose`. For the
    writable project tree it adds `confirmDelete(fileNames:) -> Bool` — a warning-style
    destructive-confirm `NSAlert` listing the target(s), returning `true` only on
    Delete, mirroring `confirmClose`/`confirmRevert`. It also holds
    `promptName(title:defaultValue:validator:) -> String?` — an `NSAlert` hosting a
    wide (400 pt) *wrapping multiline* `NSTextField` accessory (made the initial
    first responder), returning the entered string on OK (pre-filled with
    `defaultValue`) or `nil` on Cancel. This function now serves only the two branch prompts (New Branch / Branch from Remote); the project tree operations have migrated to inline naming, but `promptName` remains live code for branches.
    `promptName`'s field *wraps* instead of scrolling (`usesSingleLineMode =
    false`, wrapping non-scrollable cell, `maximumNumberOfLines = 0`,
    `preferredMaxLayoutWidth` set — all of which a plain `NSTextField()` already
    does, stated explicitly because multiline input is the point of the field), so
    even a long pasted string is visible in full rather than
    scrolled out of a narrow one-line field (the tree's relative-path create was
    the original motivation; a long branch name is what reaches it today); a private
    `promptFieldHeight(of:)` measures the wrapped content and drives a height
    constraint (clamped to 1…6 lines) that the delegate updates — re-laying out the
    alert only when the height actually changed — so the dialog grows with the
    input. The cell stays non-scrollable because `NSCell`'s `isScrollable` and
    `wraps` are mutually exclusive, so the six-line clamp is a hard cap: a longer
    input keeps its tail out of view (accepted — the whole point is that ordinary
    paths fit, and validation still judges the full string). The field and reason
    label are laid out with constraints inside an accessory *container* that
    deliberately stays **frame-based** (`translatesAutoresizingMaskIntoConstraints`
    left `true`), because `NSAlert` sizes its window from the accessory view's
    `frame` and never from its `fittingSize`: handed a constraint-driven container
    with the default zero frame the alert opens at its *minimum* width (measured
    260 pt) with the 400 pt field starting at x=130, i.e. mostly outside the
    window, and `runModal()`'s single layout pass does not correct it. A private
    `syncContainerFrame(_:)` (`layoutSubtreeIfNeeded` + `frame = fittingSize`)
    resolves the constraints into that frame once before the container is handed
    over and again in `controlTextDidChange` whenever the field height or the
    reason line changed, so the dialog opens at the right size and grows in one
    pass. Under the field sits a wrapping red (`systemRed`, small system font) reason
    label, only *hidden* rather than removed from the layout so the dialog does not
    jump as a reason appears and disappears. `validator: (String) -> String?`
    returns `nil` for a valid input or the reason text to show; it is **required**
    (no default — `defaultValue` keeps its `= ""`) so every call site must state
    its validation intent and a new one cannot silently forget it. All the rules
    and their wording come from Core (`EntryPathIssue.message` via
    `validateRelativeEntryPath` / `validateSingleEntryName`); the *only* decision
    made in the view is the single explicit blank-input branch in
    `PromptNameDelegate.revalidate(text:)` — blank/whitespace-only input disables
    OK but shows **no** reason (incomplete input, not an error) — everything else
    just displays what the validator returned and sets `alert.buttons[0].isEnabled`.
    Both mechanisms are dormant rather than dead: no surviving call site passes a
    reasoned validator (see the branch dialogs below), and the rules they once
    displayed now reach the user through the tree's inline draft instead
    (`app-window.md`), which re-implements the wrapping/height idea in
    `NSViewRepresentable` shape and deliberately shares only the six-line clamp.
    The private `PromptNameDelegate` (an `NSTextFieldDelegate` retained by
    `promptName` for the lifetime of the modal, since `NSTextField.delegate` is
    weak) re-validates on `controlTextDidChange`, and `promptName` calls
    `revalidate(text: defaultValue)` once *before* `runModal()` so the initial
    state is right (the retired tree prompts opened a pre-filled Rename with OK
    enabled and an empty create with OK disabled; the two surviving branch prompts
    pass no validator, so their initial state comes from the blank-input branch
    alone — pre-filled ⇒ enabled, empty ⇒ disabled). `revalidate` and the field-resize step each report whether they
    changed anything and `controlTextDidChange` calls `alert.layout()` when either
    did — the reason line is a *wrapping* label, so a message that needs two lines
    (the retired tree rename's `.separatorInName` text did) grows the accessory
    view, and without an explicit re-layout the alert keeps its old height and
    clips the second line.
    Because the field is multiline, every line-break-inserting command would
    otherwise put a newline in the name:
    `control(_:textView:doCommandBy:)` intercepts `insertNewline:`,
    `insertNewlineIgnoringFieldEditor:`, `insertLineBreak:` (Control-Return, per
    `StandardKeyBinding.dict`) and `insertParagraphSeparator:`, clicking OK when it
    is enabled and
    swallowing the key otherwise — so Enter is always confirm-or-nothing and a
    newline never reaches the field from the keyboard (a pasted one still can, which
    is exactly why Core has `EntryPathIssue.lineBreak`). The delegate is kept alive
    across the modal with `withExtendedLifetime` rather than by the local's scope:
    `NSTextField.delegate` is weak and ARC may release a local after its last use,
    which would silently drop both the live validation and this interception.
    The two "New Branch" dialogs (`newBranch` / `createBranchFromRemote`) pass an
    explicit `validator: { _ in nil }`: they share the wide multiline field, Enter
    = OK, and blank-blocks-OK, but have **no live reason line** — a deliberate
    minimal-scope decision, not an omission, with `GitRefName.isValid` remaining
    the sole (post-OK) reporter. Known possible follow-up: a reasoned `GitRefName`
    validator (the `EntryPathIssue` shape applied to `GitRefName`'s stricter
    grammar) would let those dialogs adopt the same live validation with **no view
    change at all**, since `validator` is already threaded through.
  - `BranchSwitcherView.swift` — the macOS branch-switcher widget in the
    always-visible bottom bar (JetBrains status-bar convention): the current branch
    label, clicked to a popover with the Local/Remote branch list (the current one
    marked), a filter field, and a "New Branch…" item (name only, created from
    `HEAD`). A remote-branch row is a two-item `Menu` — "Checkout" (git DWIM via
    `onCheckoutRemote`) and "New Branch from '\(shortName)'…" (the create dialog
    pre-filled with the default name, `origin/master` → `master`, via
    `onCreateFromRemote`), each dismissing the popover on selection; local-branch rows
    are unchanged. On a dirty tree a checkout warns it may be blocked (git decides — a
    real refusal shows git's `errorMessage` naming the conflicting files). Thin
    `@ObservedObject BranchSwitcherModel` view
    (untested; all logic in Core), calling `onSwitchBranch`/`onCreateBranch`/
    `onCheckoutRemote` back to `PisakaApp`'s gated orchestration.
  - `GitCLIService.swift` — `Process`-backed `async` `GitServicing` (the real,
    macOS-only counterpart to Core's pure parser/model). The blocking `Process`
    work never runs on a cooperative-pool (or main) thread: the private `run(_:in:)`
    dispatches its synchronous `Process` body onto a dedicated serial
    `DispatchQueue` and resumes a `withCheckedThrowingContinuation`, so callers
    `await` it (the serial queue also serializes repository access). Every method
    and helper that calls `run` is correspondingly `async`/`await`
    (`repositoryRoot`, `changedFiles`, `headContents`, `revert`, `checkout`,
    `move`, `worktreeMatchesHead`, `remove`, `revertRename`), while
    `removeUntracked` (pure syscalls) stays synchronous and `InterruptedRevert`/
    `RemoveFailure` are unchanged. `repositoryRoot(for:)`
    runs `git rev-parse --show-toplevel` (so the model normalizes a nested opened
    folder to the repo top level before any other call). `changedFiles(root:)`
    runs `git status --porcelain=v2 -uall` and feeds stdout to
    `GitStatusParser.parse`; `headContents(of:root:)` runs `git show HEAD:<path>`
    and maps a non-zero exit (missing object → new/untracked file) to `nil`
    rather than throwing. `revert(_:root:)` dispatches on `file.status`:
    `.modified`/`.deleted` → `git checkout HEAD -- <path>` (restores index +
    working tree) — `checkout` is *not* atomic (it writes the worktree before
    committing the index), so on a non-zero exit it asks `git diff --quiet HEAD --
    <path>` whether the worktree now matches `HEAD`. "Matches now" alone is
    insufficient: a `.modified` file can be staged-only (index differs while the
    worktree already equals `HEAD`), and a failed checkout there reset only the
    index. So it records whether the worktree matched `HEAD` *before* the checkout
    and reports the path via `InterruptedRevert` (so a clean tab reloads instead of
    silently re-saving stale content over the restore) only on an actual
    differ→match transition — otherwise reports nothing (reloading would discard
    unsaved edits for a worktree it never wrote). `.renamed` →
    `git checkout HEAD -- <oldPath>` plus
    `git rm -f -- <path>` (undoes both sides) — but first *refuses* if `oldPath`
    is already occupied in the working tree (a staged rename can coexist with a
    new untracked file recreated at the old path, which `git checkout` would
    silently overwrite); the occupancy check is `lstat` (a `private pathExists`)
    not `FileManager.fileExists` so a *dangling* symlink there is still caught
    (`fileExists` dereferences and would miss it). A between-steps failure is
    wrapped in `InterruptedRevert` (conforms to Core's `PartialRevertError`)
    reporting which paths actually changed. `.added` → `git rm -f -- <path>` (no
    `HEAD` version); `.untracked` → delete the working file anchored to `root`:
    walk each path component with `openat(O_NOFOLLOW | O_DIRECTORY)` (a parent dir
    swapped for a symlink-to-outside fails with `ELOOP`/`ENOTDIR` instead of being
    followed, so the delete can't escape the repo) then `unlinkat(..., 0)` the
    final name — `unlinkat` removes a single entry and never recurses, so a path
    that has since become a directory throws `GitError.revertFailed` (`EPERM`/
    `EISDIR`) rather than being recursively wiped, and `ENOENT`/already-vanished is
    a no-op. `git rm` is *not* atomic across worktree and index — it unlinks the
    worktree file before the index write that may fail — so on a non-zero `git rm`
    exit (the `.added` case and the rename's second step) the worktree is probed
    via `pathExists` *before and after* and the path is reported as changed only on
    an actual existed→gone transition (a stale `.added` snapshot whose file already
    vanished out of band would otherwise be reported as removed by the failed `rm`,
    closing a tab the revert never touched), so the model closes a now-deleted
    file's tab without ever reloading (and discarding edits in) an untouched tab.
    The rename path likewise *merges* any `PartialRevertError` thrown by its
    `oldPath` checkout into the changed set, so a non-atomic checkout failure that
    already restored the old path still resyncs it. A non-zero git exit
    throws `GitError` (now defined in `PisakaCore`, resolved here via
    `import PisakaCore`) so the model surfaces its human-readable
    `localizedDescription`.
    Launches `git` via `/usr/bin/env`, reads stdout/stderr
    before `waitUntilExit` so a large diff can't deadlock the pipe, and throws a
    typed `GitError` (`gitUnavailable` / `notARepository`) the model surfaces.
    `-z`/NUL output is unnecessary — porcelain v2 keeps paths on the line tail
    and the parser reads them as the unsplit remainder. The Log view adds four more
    `run`-backed methods: `commits(filter:limit:root:)` runs `git log --topo-order
    --parents -n <limit> --pretty=format:<Commit.prettyFormat>` plus
    `filter.gitArguments()` and feeds stdout to `Commit.parse` (`--topo-order` +
    `--parents` give the graph layout its ordering and parent decoration);
    `references(root:)` runs `git for-each-ref --format=%(refname)` over
    `refs/heads`, `refs/remotes`, then `refs/tags`, returning *full* refnames
    (`refs/heads/main`, …) rather than `:short` so a branch and a tag sharing a
    short name stay unambiguous as a `git log` revision — the filter bar shortens
    them for display only; `commitChanges(hash:root:)` runs
    `git diff-tree --no-commit-id --name-status -r -M -m --first-parent --root <hash>`
    and feeds stdout to `CommitChangesParser.parse` (`-m --first-parent` = merge
    shows the mainline diff — `--first-parent` alone is insufficient because
    `diff-tree` suppresses a merge's diff entirely unless `-m`/`-c`/`--cc` is given,
    so without `-m` a merge would show "No changed files"; `-m` is paired with
    `--first-parent` to keep just the mainline side and is a no-op for a non-merge or
    root commit; `--root` diffs a root commit against the empty tree); and
    `fileContents(at:path:root:)` runs `git show <revision>:<path>`, mapping a
    non-zero exit (missing object) to `nil`. All pass `-c core.quotePath=false` so
    paths with non-ASCII bytes are not octal-escaped. The conflict resolver adds
    three more: `blob(stage:path:root:)` runs `git show :<N>:<path>` (the merge index
    stage), mapping a non-zero exit (absent stage) to `nil` like `headContents`; the
    mutating `stage(path:root:)` runs `git add -- <path>`; and the mutating
    `stageRemoval(path:root:)` runs `git rm -f -- <path>` (removes the working file
    and stages its deletion, for a modify/delete resolved to the deleted side). Both
    mutating calls throw `GitError` on a non-zero exit. The branch-switcher adds four
    more through the same serial `run(_:in:)`: `currentBranch(root:)` runs
    `git symbolic-ref --short HEAD` → a `BranchRef` for the current local branch (a
    detached HEAD → `nil`); `checkout(branch:root:)` runs `git checkout <branch>` and
    on a non-zero exit throws `GitError.checkoutFailed(reason: stderr)` (stderr names
    the conflicting files); `createAndCheckout(name:startPoint:root:)` runs
    `git checkout -b <name> <startPoint>`; and `fetch(remote:root:)` runs
    `git fetch <remote>` (inheriting the system git credentials), a non-zero exit →
    `GitError.fetchFailed`. The gutter's annotate column adds one more:
    `blame(fileURL:)` runs `git -c core.quotePath=false blame --porcelain --
    <lastPathComponent>` with the file's **parent directory** as the working
    directory — the protocol's deliberate `fileURL`-instead-of-`(path:root:)`
    deviation, so git discovers the repository itself and the editor needs no
    `repositoryRoot(for:)` round-trip for a file it is only looking at — mapping a
    non-zero exit to `GitError.notARepository(stderr:)`. The stdout is fed to
    `BlameParser.parse` **inside this method**, deliberately rather than in the
    caller: the method is not `@MainActor` and runs on the cooperative pool, so both
    the subprocess and the parse of a possibly megabyte-scale output stay off the
    main thread (a `@MainActor` `BlameController` doing the parse would put it right
    back on it). No `--contents` variant: the command blames the **on-disk** file by
    design — the dirty-buffer trade recorded on `BlameController`. It is also the
    one call here that does **not** run on the shared serial `queue`: it takes a
    second serial `blameQueue` (via `run`'s `on:` parameter, defaulted to the shared
    one so every other call site is untouched). `blame --porcelain` is the slowest
    command in the file *and* the only one issued automatically — the column
    reloads on every tab switch to an annotated file and on every `diskRevision`
    bump, i.e. on every autosave — so on the shared queue it head-of-line blocked
    the whole git surface (the post-save Local Changes refresh, the Log fetch, the
    branch widget, a checkout) on work the user did not ask for and whose result is
    often discarded as superseded. Splitting it off is safe precisely because blame
    is **read-only**: the shared queue's serialization exists so two calls cannot
    race the same `.git` state, and a read overlapping a mutation can at worst
    observe the repository mid-change — a stale or failed blame, both of which the
    controller already swallows into an empty column. It stays *serial*, so several
    blames still cannot stack subprocesses.
    The **commit dialog** adds seven more methods and two amendments to the
    process plumbing itself. (1) `ProcessResult` now stores the raw
    `stdoutData`/`stderrData` and exposes `stdout`/`stderr` as **computed**
    properties over them, because the decode
    (`String(decoding:as: UTF8.self)`, U+FFFD for invalid bytes) is right for
    every text-producing call here and wrong for `headBlob`, whose whole contract
    is "the bytes as they are" — decoding *eagerly* meant the one method added to
    avoid a lossy decode still allocated a multi-megabyte U+FFFD string for every
    binary blob it fetched, once per changed file per load and again per
    pre-commit re-read; no call site reads either property more than a couple of
    times per result, so computing on demand costs nothing measurable and the
    binary path stops decoding at all. (2) `run`/`runBlocking` take `environment:
    [String: String] = [:]`, which is an **override merged over the inherited
    environment, never a replacement** — load-bearing rather than stylistic: the
    launch goes through `/usr/bin/env` and `Process.environment` is otherwise
    never assigned, so assigning it (say `["GIT_INDEX_FILE": …]`) would wipe
    `PATH` (`/usr/bin/env git` would stop finding git at all), `HOME` (git would
    lose the global config, taking author resolution and credential helpers with
    it) and everything a `pre-commit` hook expects when it shells out to a
    formatter. The empty default reproduces today's plain inheritance exactly, so
    no existing call site changed. `headBlob(of:root:)` runs the same `git show
    HEAD:<path>` as `headContents` with two deliberate differences — absence is
    decided by the **exit code** alone (a blob that happens not to decode is
    emphatically *not* reported missing) and the bytes come back through
    `stdoutData`. `commitContext(root:)` is six independent reads, because
    conflating them is how a fresh repository gets misread: `rev-parse
    --absolute-git-dir` (also the one probe distinguishing "not a repository"),
    `rev-parse --verify --quiet HEAD` (fails exactly on an **unborn** HEAD),
    `symbolic-ref --short --quiet HEAD` (fails exactly on a **detached** one — and
    still *succeeds* on an unborn one, which is why the two flags cannot come from
    a single call), `@{upstream}`, `git remote`, and the git directory's entry
    names fed to `InProgressOperation.detect` — that last listing **failing
    closed**, since collapsing an unreadable git directory into an empty marker
    list reads as "no operation in progress", and with git's own `cannot do a
    partial commit during a merge` bypassed by the throw-away index that block is
    the last line of defence; the throw surfaces as the dialog's `errorMessage`
    instead of quietly recording a merge as a one-parent commit. `identity(root:)` is four reads per
    `CommitIdentity.resolve`'s contract (`config --local --get` per field says
    whether *this repository* supplied it, `config --get` says what git resolved
    to), `setLocalIdentity` writes `--local` always, and `headMessage(root:)` is
    `log -1 --pretty=%B` with a non-zero exit (an unborn HEAD) mapping to an
    honest `nil`. `commit(_:message:amend:root:)` is the **temporary-index
    mechanism**: a scratch directory holds a throw-away index pointed at by a
    `GIT_INDEX_FILE` override on every step, seeded with `read-tree HEAD`
    (`read-tree --empty` on an unborn HEAD) so it starts as an exact copy of what
    is already committed; the plan's entries are applied to it
    (`update-index --add -- <path>` for a whole file, `hash-object -w
    --path=<repo path>` — the `--path` making the scratch file irrelevant, since
    git applies the filters and `core.autocrlf` rules belonging to the *committed*
    path — plus `update-index --add --cacheinfo <mode>,<sha>,<path>` for assembled
    content, `update-index --force-remove` for a removal); then a **real `git
    commit -F <message file>`** (`+ --amend`) runs against it. A real commit rather
    than `commit-tree` deliberately: plumbing would produce the same object and
    lose everything around it — `pre-commit`/`commit-msg` hooks would not run and
    git's own author/committer resolution would have to be reimplemented — and as
    a bonus, since the hooks inherit `GIT_INDEX_FILE`, a hook running `git diff
    --cached` sees exactly the content being committed. The **real index is
    touched once, on success**, by a `git reset --quiet` with *no* override (the
    deliberate discard `CommitPlan` documents); that reset's own failure is **not**
    propagated, because the commit already exists and reporting a failure would
    invite a retry that commits twice. Any failure *before* the commit throws
    `GitError.commitFailed` carrying git's own output — through a `failureReason`
    helper that prefers stderr but **does not ignore stdout**, since a `pre-commit`
    hook explaining itself on stdout is the commonest failure this feature has —
    with the real index and `HEAD` untouched, and the scratch directory is removed
    on every outcome via `defer`. `fileMode` supplies an assembled blob's mode: it
    always `lstat`s the **entry's own** path (which for a rename is not the path
    the mode is read from — the working file exists only under the new name) and,
    for a `.head` source, reconciles that against `ls-tree HEAD`'s record through
    `GitFileMode.parse`/`.reconciled`, so an exec bit is inherited while a
    symlink↔regular typechange is not. `push(_:root:)` executes a `PushPlan` (`git
    push`, or `push --set-upstream <remote> <branch>`), a non-zero exit throwing
    `GitError.pushFailed`. **`GIT_TERMINAL_PROMPT=0`** is passed by the two
    calls that can be prompted at — push, because it is the one command that
    routinely needs authentication, and `commit`, alongside its `GIT_INDEX_FILE`,
    because it executes the repository's own `pre-commit`/`commit-msg` hooks and
    signs when `commit.gpgsign` is on. Without it, anything that decides to prompt
    blocks on a question nothing can answer, and since every call shares the serial
    `queue`, the Local Changes refresh, the Log, the branch
    widget and every later git operation queue behind it and silently stop working
    (`isRunning` also stays raised, so the sheet's Commit button is disabled
    forever — and Cancel is disabled with it, so the sheet cannot even be
    dismissed). Credential *helpers* still answer, needing no terminal, and the
    variable is inherited by the hooks and by any git they shell out to. The mirror
    of the override is `run`/`runBlocking`'s `unsetting:` parameter — keys **removed**
    from the inherited environment before the override is layered on, which is not
    the same as setting them empty (an exported-but-empty `GIT_AUTHOR_NAME` is a name
    git will try to use). Its only caller is the `git commit` step, which unsets
    `identityEnvironmentKeys` — `GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL`,
    `GIT_COMMITTER_NAME`/`GIT_COMMITTER_EMAIL` and `EMAIL` — so that **git config is
    what the dialog says it is**. `identity(root:)` resolves the author line from
    `git config` alone and the dialog labels the level each field came from, but git
    *prefers* those variables over config (and falls back to `EMAIL` for an unset
    `user.email`), and every call here inherits the app's environment — which carries
    them whenever Pisaka was launched from a shell that exported them. Left in place
    they break the line in **both** directions: the dialog shows the config identity
    while git records the environment's one, and a repository with no configured
    identity blocks with `.identityIncomplete` although git would have committed
    happily. Unsetting them makes the displayed identity the recorded one and the
    block a true statement; the hooks inherit the scrubbed environment too.
    `GIT_AUTHOR_DATE`/`GIT_COMMITTER_DATE` are deliberately left alone — they set the
    commit's dates, which the dialog neither shows nor claims anything about. For the same
    class of reason `runBlocking` points `standardInput` at `FileHandle
    .nullDevice`: no command here reads stdin, and inheriting the app's would hand
    git or `ssh` a controlling terminal to prompt on whenever the app was launched
    from a shell.
  - `CommitDialogView.swift` — the commit dialog: an IDEA-style modal **sheet** on
    the main window. Left, the changed files with three-state checkboxes and
    status badges (reusing `LocalChangesView`'s `statusColor`/`statusLetter`,
    which became internal for exactly that — two lists of changed files
    disagreeing about what "M" looks like would be a needless inconsistency)
    inside a `ScrollViewReader` whose one job is the **preselect**: opened from a
    file's Commit… item the single checked row is the only thing the user came for,
    and on a change list taller than the panel it would otherwise sit off screen
    under a column of unchecked rows, reading as if the preselect had been ignored,
    so an `onAppear` scrolls `model.selectedPath` to the center (a no-preselect
    opening simply scrolls to its own first row). The scroll is **deferred one
    main-actor turn** rather than issued from `onAppear` directly, which is what
    makes it work at all: `onAppear` runs before the subtree's first layout pass
    and the rows live in a `LazyVStack` that has realized nothing yet, so
    `scrollTo` would name an id that does not exist and be dropped — precisely in
    the case the scroll exists for (a row far down a list taller than the panel).
    It may fire more than once per opening — a *reopen for the same root* takes
    `prepareForFolderChange`'s no-op path, so the first frame still draws the
    previous opening's `files` (the load that empties them runs a later turn) and
    this branch is built, then rebuilt when the fresh list is published — and the
    last firing carries the fresh `selectedPath`, so the list settles on the
    requested row;
    right, the selected file's unified diff; at the bottom the multiline message
    field, the author line with a two-field local-config editor
    (`AuthorEditorView` → `CommitDialogModel.setLocalIdentity`, an unset identity
    shown in red and blocking Commit) — labelled **"Committer:" while Amend is
    ticked**, with a "(amend keeps the original author)" note beside it, because
    `git commit --amend` without `--reset-author` keeps the amended commit's
    author name, email and date and replaces only the committer: calling that line
    "Author" would state something git will not record, which is the same failure
    the per-field source labelling exists to prevent, only with the screen
    confidently wrong rather than silent (a user who fixes their local identity
    and amends to re-attribute the commit does not re-attribute it). The identity
    is still required and still blocks Commit when unset — git needs a committer
    either way — and naming the role costs no further git read, whereas showing
    the amended commit's own author would — the Amend and "Push after commit" switches,
    and Commit/Cancel with the blocked reason shown on its own line above them —
    `model.errorMessage ?? model.block?.message`, i.e. the last *failure* (red)
    takes precedence over `CommitGate`'s reason (secondary), which is why every
    selection/Amend mutator clears it. The gate half is **silent until the
    repository has been read** (a private `isAwaitingLoad`, which is also what
    gates the loading placeholder): `CommitGate` reports `.noRepository` from a
    `nil` context, and during a load that means "not read yet", so the sheet
    otherwise asserted *"This folder is not a git repository."* beside its own
    spinner for however long reading every changed file takes. `isLoading` alone
    is not that question — `openCommitDialog` presents the sheet and *then* spawns
    the load, so the first frame renders with it still `false` — and a folder that
    genuinely is not a repository arrives as `errorMessage`, which both takes
    precedence and ends the wait. Commit is **⌘Return**, not Return: the
    message field is a multiline editor where Return has to insert a newline.
    Cancel is Esc, and is disabled while `model.isRunning` — dismissing mid-commit
    would fire `onDismiss` and release the modal autosave suspension in the middle
    of git reading the working tree into the temporary index, while cancelling
    nothing, since the commit carries on regardless. Thin and untested like the
    rest of the view layer: what may
    be committed, what a checkbox's state is, what a whole-only file says instead
    of a diff and what a push would do are all decided in Core; the commit itself
    is handed back to `PisakaApp` through `onCommit`, which owns the writer
    coordination and the post-success refreshes.
  - `CommitUnifiedDiffView.swift` — the dialog's right-hand panel: a **unified**
    (single-column) diff of one file with a checkbox on every changed line. A
    standalone SwiftUI panel rather than an extension of the AppKit `DiffView`,
    because neither of that view's properties survives here — it is a read-only
    *side-by-side* renderer over two `NSTextView`s, while the dialog needs one
    column (a `.modified` row showing its old and new line one above the other,
    sharing a single checkbox) and per-line hit targets. **The "committed as a
    whole" branch is the substance of this view, not a fallback:** when
    `CommitDialogModel.wholeOnlyMessage(for:)` is non-`nil` it draws that sentence
    and *nothing else* — no diff, and not a single line checkbox. Three
    unrelated-looking cases arrive that way and all three behave identically (a
    deleted file, a binary/non-UTF-8 side, and a file whose only difference is its
    line endings), the one decision being `CommitFileFacts.wholeOnlyReason`.
    Drawing their diff instead would put a selection UI on screen in which every
    click does nothing — which reads as broken — and for a binary file a naive
    old/new diff additionally reads as "every HEAD line removed", i.e. as an
    invitation to exactly the silent corruption the classification exists to
    prevent. Such a file's checkbox in the left-hand list is an ordinary checked
    state, never mixed (`CheckboxState`'s rule).
    **Zones.** The sheet's chrome follows the interface zone (it inherits
    `\.interfaceMetrics` from the main window, which is what the placeholder here
    reads), but the *diff itself* is the code zone: every row's text draws at
    `settings.fontSize`, so the diff carries `ZoomSurfaceMarker(kind: .code)` and
    a gesture over it grows the code rather than the sheet. The commit **message**
    `TextEditor` in `CommitDialogView` is the same thing for the same reason. The
    fixed geometry inside a row (the checkbox column, the number gutter's width,
    the row's own spacing and padding) is deliberately on *neither* scale: it is
    chrome belonging to a code row, and scaling it with the interface would make
    the two zones interact (`docs/architecture/core-zoom.md`).
  - `MergeView.swift` — the 3-pane conflict-resolution editor (`ours | result |
    theirs`): the left/right panes are read-only views of each side's full content
    (stable regions plus that side's version of every conflict hunk), the middle
    pane is the live editable merged result built from `MergeDocument.resolvedText`
    (an unresolved conflict shows git-style markers), conflict hunks highlighted in
    all three panes with vertical scrolling mirrored across them. A thin,
    intentionally untested `@ObservedObject MergeModel` view (the same split as
    `DiffView`/`CodeEditorView` — all domain logic is in Core). It also takes an
    observed `settings: SettingsStore` and applies its shared `fontSize` uniformly
    across all three panes (so rows stay aligned). Each pane
    (`MergePaneTextView`) declares itself a **code** zoom surface
    (`ZoomSurfaceProviding`, `zoomSurfaceKind = .code`) rather than overriding
    `scrollWheel` as it once did — the app's single `NSEvent` monitor owns every
    zoom gesture now (`docs/architecture/core-zoom.md`) — and the window is one of
    the `NSHostingController` roots that applies `.interfaceScaled(settings)`, so
    its chrome follows the interface zone while the panes follow the code zone.
    A forced theme reaches the window via `.preferredColorScheme`. A toolbar drives
    per-conflict resolution (◀ ours / both orderings / theirs ▶), prev/next conflict
    navigation, and an "Apply" affordance enabled only when
    `MergeModel.isFullyResolved`; editing the middle pane within a conflict region
    feeds that region's text back into the model as `.custom`. The result pane's
    text is assembled by *flattening* every region's logical lines into one array
    and joining once with `\n` — exactly as `MergeDocument.resolvedText` does — so
    the pane's bytes match what Apply writes (joining per-region pieces would emit a
    phantom blank line for a region contributing zero lines, e.g. a modify/delete
    resolved to the empty side). It reuses `MergeDocument.resolvedLines(for:
    resolution:)` (made `public static` so the marker text/ordering have a single
    source and the pane can't drift from `resolvedText`), overriding only `.custom`
    (split on the literal `\n` the editable pane inserts, not `LineDiff.splitLines`).
    The edit-to-conflict span tracker grows the span that begins exactly at the edit
    offset (using `location > editStart`, not `>=`) so typing at the very start of a
    conflict region is attributed to it rather than dropped.
  - `MergeWindowController.swift` — owns the separate, non-modal merge windows
    opened from the Local Changes "Resolve" entry, mirroring `DiffWindowController`:
    each `open(title:model:settings:onApply:)` creates a fresh resizable `EscClosableWindow`
    (see below — so Esc closes the window) hosting
    `MergeView` via an `NSHostingController`, retains it (and additionally the
    per-window `MergeModel`, which `MergeView`'s `@ObservedObject` does not retain)
    for the window's lifetime, and drops both on close (release on close, delegate
    held alongside since `NSWindow.delegate` is `weak`). `onApply` is the owner's
    *guarded* apply (`PisakaApp.applyMerge` — it suspends autosave / the disk-writer
    gate around `MergeModel.apply()`, then refreshes Local Changes and resyncs the
    tab; the controller cannot do this because it owns neither the autosave
    controller nor the workspace) and returns whether it succeeded; on `true` the
    window closes itself, a failed apply leaves it open with `errorMessage` shown.
    `closeAll()` closes every retained window (the app calls it on
    `willTerminateNotification`).
  - `EscClosableWindow.swift` — a tiny `final class EscClosableWindow: NSWindow`
    used for the separate diff (`DiffWindowController`), merge
    (`MergeWindowController`), Find in Files (`ProjectSearchWindowController`),
    LeetCode problem browser (`LeetCodeBrowserWindowController`) and source viewer
    (`SourceViewerWindowController`) windows so Esc closes them. It overrides
    `cancelOperation(_:)` (which AppKit dispatches down the responder chain on Esc,
    and a plain `NSWindow` ignores) to call `performClose(_:)`, routing the close
    through the standard `windowShouldClose`/`windowWillClose` path — exactly like
    clicking the close button — so each controller's `windowWillClose` delegate
    still fires and releases the window from its retained set (no new leaks). Pure
    view layer (AppKit only), so it is untested like the windows/controllers
    themselves.
  - `LocalChangesView.swift` — the Local Changes bottom dock panel (no longer a
    left-panel mode). Observes
    `LocalChangesModel` and renders `changedFiles` flat or grouped by folder
    (`ChangeTree`, recursing in-memory `ChangeNode.children` via
    `DisclosureGroup`s — no disk read), per `model.groupingMode`. A segmented
    control toggles flat/by-folder and a button refreshes against the project
    root; it also auto-refreshes on appear and on `projectRoot` change. That
    **change handler refreshes the root its parameter carries**, never
    `self.projectRoot`: `projectRoot` is a plain stored property of the view value
    and macOS 13's `onChange(of:perform:)` runs the closure captured *before* the
    change, so off `self` it is still the folder the user just left. The pinned
    request generation does not cover that case — the folder-open path has already
    bumped it, so a stale-root refresh pinning the *current* generation is accepted,
    re-derives a switch back inside `refreshImpl` and strands the panel on the
    previous repository. `refreshIfPossible` (the `onAppear`/manual-button form,
    where the property is current) now forwards to the same `refresh(root:)`. Each row
    (`ChangedFileRow`, used by both the flat list and the by-folder
    `ChangeNodeView` leaf) shows a leading checkbox bound to
    `model.revertSelection` (toggled via `model.toggleChecked(file)`) for
    multi-file revert, a `FileIcon(for:)` tinted by git status, plus a one-letter
    badge (M/A/D/R/U/C), with VCS-convention colors (added → green, deleted → red,
    modified → blue, renamed → orange, untracked → gray, conflicted → purple).
    Four triggers share one activation path through `LocalChangesModel`: (1) a
    *double*-click (`.onTapGesture(count: 2)`, declared before the single-tap
    select) calls `onSelect()` first (so the panel focuses on that row) then
    `activate()`, which switches on `LocalChangesModel.activation(for:)` and calls
    `onOpenDiff()` or `onResolveConflict()`; (2) the "Show Diff" context-menu
    item calls the same `activate()` (shown only when
    `LocalChangesModel.offersShowDiff(for:)` is true, i.e. not for conflicted
    rows, which keep their existing "Resolve…" + `Divider()`); (3) Cmd+D while
    the panel has keyboard focus (see the focus anchor below); (4) the "Jump to
    Source" context-menu item (shown only when
    `LocalChangesModel.offersJumpToSource(for:)` is true, i.e. not for deleted
    rows) resolves the file against `model.root` and calls the same `onOpenFile`
    the project tree uses. The context menu order for non-conflicted rows is:
    Show Diff, Jump to Source, Commit…, Revert — non-destructive items above the
    destructive one. A `.contextMenu` **Commit…**
    item calls `onCommitFile(file)` and a **Revert**
    item calls `onRevert(file)`. The
    callbacks are threaded `PisakaApp → ContentView → LocalChangesView` down
    through the rows (and through `ChangeNodeView`, recursively, for the by-folder
    mode; same shape as `onOpenFile`/`onOpenFolder`). `onJumpToSource` is threaded
    the same way and, in `ContentView`, resolves
    `LocalChangesModel.jumpToSourceURL(for:root:)` against `localChanges.root`
    before calling the existing `onOpenFile` — no new callback from `PisakaApp`, no
    second open path. **Commit…** is JetBrains'
    "Commit File": it opens the ordinary commit dialog with *only that file*
    preselected, through the very same `PisakaApp.openCommitDialog` the header
    button and ⌘K run (see there — the preselect is its only parameter, so the
    gates, the autosave flush, the modal suspension and the generation pinning are
    shared rather than duplicated). It carries **no enablement condition of its
    own**, deliberately: a row exists only when a folder is open, which is exactly
    the header Commit button's single condition, and `openCommitDialog` re-checks
    the project root and every one of its gates anyway. The **focus anchor** is a
    private `LocalChangesFocusAnchor: NSViewRepresentable` and its `NSView`
    (`LocalChangesFocusAnchorView`), placed behind the panel's outer `VStack` via
    `.background(...)` — not on the list — so focus survives placeholder states and
    an empty change list. The `NSView` is non-drawing, answers `nil` from
    `hitTest` (never stands between the pointer and a row), hidden from
    accessibility, and `acceptsFirstResponder == true`. A `@State focusRequest`
    token bumped in each row's `onSelect` closure drives `updateNSView` to call
    `window?.makeFirstResponder(nsView)` (dispatched asynchronously so the
    responder change does not land inside a SwiftUI update pass); a value change is
    the only signal a representable receives, hence the token. The view overrides
    `performKeyEquivalent(with:)` with the same gate shape as `EditorTextView`:
    `charactersIgnoringModifiers?.lowercased() == "d"`, modifier mask equals
    `.command` only, and `window?.firstResponder === self`. When the gate passes it
    invokes the handler via `LocalChangesModel.shortcutActivation(selected:)` and
    routes the result through the same `onOpenDiff`/`onResolveConflict` closures
    the double-click uses; `nil` (no selection) does nothing but still returns
    `true` so the focused panel owns the key and the keystroke does not beep or
    reach any other surface. A second gate in the same `performKeyEquivalent`
    catches Cmd+Down: only the character comparison differs (to
    `NSDownArrowFunctionKey`), because an arrow event carries `.function` and
    `.numericPad` in `modifierFlags` and the existing
    `intersection([.command, .shift, .option, .control])` already masks those out
    (stated in a comment so the next reader does not "fix" it into a
    `deviceIndependentFlagsMask` equality). The handler resolves the selected file
    against the repository root via
    `LocalChangesModel.shortcutJumpToSourceURL(selected:root:)`, calls the same
    `onOpenFile` the project tree uses, and then hands keyboard focus to the
    editor: one small `focusEditor()` method walks the window's content view for
    the first `EditorTextView` descendant and `makeFirstResponder`s it, dispatched
    asynchronously on the main queue so the tab SwiftUI is about to build exists by
    then. Finding nothing (no folder open, or the open failed — which already beeps
    in `openFile(url:)`) leaves focus where it is; one honest limitation: the
    handoff cannot see whether the open succeeded, so a failed open with another
    tab already showing focuses that tab's editor — the beep is the failure signal.
    The context-menu "Jump to Source" item does *not* move focus, matching every
    existing item in this menu (Show Diff, Resolve…, Commit…), which is
    pointer-driven activation and leaves keyboard focus where the user put it. The anchor is chrome, not a zoom surface — it draws at
    no font at all, so it does not declare `ZoomSurfaceProviding`. Placeholders
    cover no-folder / error / no-changes. The header also holds a **Commit** button
    (`checkmark.circle`) calling `onCommit()` — the same handler
    the ⌘K menu item runs, so button and command behave identically — disabled on
    exactly the one condition that item is (no project root; see there for why an
    empty change list deliberately does *not* disable it).
    Its `statusColor(_:)`/`statusLetter(_:)` helpers are **internal** rather than
    file-private so the commit dialog's file list draws the same badge: the mapping
    is one rule, and two lists of changed files disagreeing about it would be a
    needless inconsistency.
  - `DiffView.swift` — `NSViewRepresentable` rendering a pre-computed `[DiffRow]`
    (`HEAD` left, working copy right) as two side-by-side read-only TextKit-1
    `NSTextView`s (no soft-wrap, so one logical line = one visual row and the
    panes stay aligned). Each row maps to exactly one line in *both* panes (a
    `nil` side becomes an empty filler line). `DiffTextView` overrides
    `drawBackground` to paint a full-width per-row background by `DiffRowKind`
    (removed/changed → red on the left, added/changed → green on the right,
    filler → neutral gray), iterating only the visible glyph range and mapping a
    glyph's char index to its row via a `LineStartIndex`-built offset cache.
    `DiffGutterView` (an `NSRulerView`, like `LineNumberRulerView`) draws this
    side's 1-based numbers (blank for a filler line) plus a thin change marker.
    `DiffTextView` and `DiffGutterView` both declare `zoomSurfaceKind = .code`
    (`ZoomSurfaceProviding`); the pane no longer overrides `scrollWheel` for the
    font step, and the gutter needs its own conformance because an `NSRulerView`
    is a *sibling* of the text view, so the pointer walk cannot reach it through
    the pane (`docs/architecture/core-zoom.md`).
    The `Coordinator` mirrors vertical scroll between the panes (guarded against
    the sync feedback loop), and builds a Neon `TextViewHighlighter` per pane
    (same `SyntaxLanguageConfiguration` + `SyntaxTheme` mapping as the editor),
    detaching the outgoing highlighters before a buffer swap to avoid the stale
    cross-language race. `DiffColors` keeps the row/marker color scheme in the
    view layer so Core stays color-free; `DiffContainerView` lays the two panes
    side by side with a hairline divider.
  - `CommitLogView.swift` — the Git Log view (shown in the bottom dock panel): a
    JetBrains-style read-only
    commit table (a fixed-`rowHeight` list of short hash, ref badges, subject,
    author, date) observing `CommitLogModel`, with row selection setting
    `model.selected`. Each row's leading cell is the branch-graph gutter — the view
    lays the graph out once (`CommitGraphLayout.layout`) and threads each row plus
    the previous row's edges into `CommitGraphView` so cells align. The graph is
    suppressed (laid out over `[]`) whenever the shown list is *not* contiguous
    history — a non-blank message search or a commit-limiting server filter
    (`model.filter.mayProduceNonContiguousHistory`, i.e. author/date) — since a
    layout over an excluded-parent slice would draw dangling lanes. A "Load more"
    affordance (shown only when the last fetch filled the limit) bumps the `git log
    -n` limit and re-fetches the whole list (no incremental paging — the model
    replaces `commits` wholesale). Refreshes on `onAppear` and `onChange(projectRoot)`
    (idempotent backstops; the model's generation guard handles ordering). The
    **change handler refreshes the root its parameter carries**, never
    `self.projectRoot` — the same stale-stored-property rule `LogFilterBar` states,
    and here the stakes are higher than a lagging display: `prepareForRefresh`
    *bumps* the request generation, so a stale-root refresh supersedes the correct
    one the folder-open path launched, rewrites `lastRequestedRoot` back to the old
    folder and leaves the panel showing the previous repository's history.
    `refreshIfPossible` (the `onAppear`/manual-button form) forwards to the same
    `refresh(root:)`. Selecting
    a commit opens `CommitDetailPane` — now a *files-list only* (the old `VSplitView`
    over an inline `CommitDiffPane` is gone; the `CommitDiffPane` struct was removed)
    — beside the list in an `HSplitView`. Double-clicking a `CommitFileRow` calls a
    threaded `onOpenCommitDiff(file, commit)` that opens the commit-vs-first-parent
    diff in a separate window (single-click selects/highlights). The file list
    (`model.changes(for:)`) is still cached behind a `@State` generation token like
    `DiffPane`; the per-file diff rows (`model.rows(for:in:)`) now load inside the
    separate diff window (`DiffWindowContent`) rather than here. `CommitDetailPane`
    clears its `files`/`selectedFile` *synchronously* when the selected `commit`
    changes (before the async `changes(for:)` fetch): `@State` persists across the
    pane's recreation with a new `commit`, so without the clear it would briefly show
    the previous commit's files. `onOpenCommitDiff` is threaded `PisakaApp →
    ContentView → CommitLogView → CommitDetailPane → CommitFileRow`. The
    filter/search bar (`LogFilterBar`) sits above the table once a repo is open.
  - `CommitGraphView.swift` — the branch-graph gutter, a thin color-resolving
    `NSViewRepresentable` (`CommitGraphRowNSView`) over the color-free
    `CommitGraphLayout`, like the minimap: it consumes a `colorIndex` and maps it to
    a concrete `NSColor` from a fixed palette at draw time so the graph follows the
    system appearance. One flipped (y-down) fixed-height cell per row draws the
    node dot at the vertical center, this row's `edges` from center to the bottom
    edge, and the previous row's edges (`incomingEdges`) from the top edge to
    center — so a lane's bottom-half in one cell meets its top-half in the next to
    form a continuous line without any view owning the whole list.
  - `LogFilterBar.swift` — the Log filter/search bar above the commit table. A thin
    (untested) view whose server-side dimensions live in a single `@State private
    var draft: LogFilterDraft` plus a separate `search: String` (message search is
    not a `LogFilter` dimension). **Seeding rule:** a seed *assigns* the
    draft/search directly and is therefore structurally unable to reach the apply
    path — every apply lives only in a user-intent binding setter or an explicit
    `onSubmit`, and is handed the new value explicitly. The preserved day
    (`LogFilterDraft.seed(from:)`) is scoped to **this view's lifetime**: the bar's
    `draft` is `@State` and `ContentView.panelContent` is a `switch` in a
    `@ViewBuilder` under `if let panel = visiblePanel`, so each dock panel is its
    own structural branch — switching away from Log or hiding the dock destroys the
    state, and `onAppear` re-parks both pickers on today. Making the memory
    app-lifetime would mean holding the two days on `CommitLogModel` beside
    `filter`; not done, and the limit is stated in `docs/FEATURES.md` rather than
    left to be inferred. **Change handlers seed from
    their parameter; the view's observed property is stale inside the handler.**
    `.onChange(of: filter) { newFilter in seed(from: newFilter) }` calls
    `draft.seed(from: newFilter)` and `.onChange(of: searchQuery) { newQuery in
    search = newQuery }` assigns that parameter — never `self.filter` /
    `self.searchQuery`, which inside a change handler still carry the *previous*
    value (documented SwiftUI behavior, and the reason the closure is handed the
    new one). Re-reading the property seeds the bar one publish behind forever, and
    the next apply — assembled from the lagging draft — writes that stale state
    back, which is how a branch pick was silently dropped by a following Since
    toggle. `onAppear` is the **one exception** and reads `filter`/`searchQuery`
    directly (`draft = LogFilterDraft(filter: filter, defaultDate: Date())`),
    because at appearance the properties are current — and a bar that has never
    been shown also has no chosen day to preserve, which is exactly the
    from-scratch seeding form's case. The **single-parameter `onChange` spelling is
    deliberate**, not an inconsistency with the iOS bar: the deployment target is
    macOS 13, whose only overload is `onChange(of:perform:)` and whose one closure
    parameter *is* the new value; the two-parameter form is macOS 14+ and will not
    compile here. No value-equality suppression is involved anywhere: the
    previous mirrored-`@State` + `.onChange` construction *was* suppressed by value
    equality, which failed under interleaved applies when the published `filter`
    lagged `requestedFilter` and an echo built from the published value was accepted
    — the draft removes that hazard structurally. The Since/Until toggles and both
    date pickers are wired through a single `draftBinding(for:)` helper whose `get`
    reads the draft and whose `set` writes the mutated draft *and* calls
    `onApplyFilter(draft.filter())` with the new value (no re-read of stale state);
    the `.onChange` handlers on those controls are deleted. The branch picker is
    likewise a computed binding: `get` is `draft.displayRefTag(amongKnown:
    references)` (via `LogFilter.resolvedRef` → `LogFilterDraft.allRefsTag` for
    "All") and `set` is `draft.selectRef(tag:)` + `onApplyFilter(draft.filter())` —
    the selection is carried **verbatim** so an apply driven by a date/author/path
    edit while `references` is still empty cannot collapse the chosen branch to
    "All" (the old `applyFilter(refOverride:)` re-derived through `resolvedRef` and
    had exactly that bug; the picker values are still the **full** refnames
    `references` supplies, the unambiguous `git log` revision). `shortLabel(for:)`
    strips `refs/heads/`/`refs/remotes/`/`refs/tags/` for display, suffixing a tag
    " (tag)" so a branch and a tag sharing a short name stay distinct. Author/path
    are plain draft projections (`$draft.author`/`$draft.path`) with an `onSubmit`
    that applies `draft.filter()` once — typing alone does not re-fetch. The search
    field is routed through `searchBinding` (`set` → assign + `onSearch(newValue)`)
    so the `.onChange(of: search)` echo is deleted and the `.onChange(of:
    searchQuery)` seed (direct assignment) cannot masquerade as a user edit. The
    draft owns all the decisions the view previously duplicated: trimming
    (blank → `nil`), `since` → start-of-day / `until` → last-second-of-day via
    `Calendar.current` (the inclusive upper boundary git's `--until` expects, so it
    includes every commit on the selected day but none at the next midnight; `filter`
    then formats the absolute instants in UTC), verbatim ref preservation, and the
    `allRefsTag`/`displayRefTag`/`selectRef` seam. The inclusive `until` instant is
    still on the selected day, so re-seeding is verbatim and the round-trip is
    idempotent — `since`'s `startOfDay` likewise. That holds only because
    `endOfDay` derives the next day's *own* `startOfDay` rather than subtracting a
    second from "same wall-clock time, one day on": in a zone whose DST jump is at
    midnight the following day starts at 01:00, and the naive form would land on
    that next day and walk the picker forward one day per apply. And a re-seed whose incoming
    bound is *absent* clears the toggle but leaves the day the picker already
    shows, so unticking and re-ticking Since/Until offers the chosen day back
    instead of today (the rule lives in `LogFilterDraft.seed(from:)`). All the
    testable
    argument-building/search/normalization logic lives in `PisakaCore.LogFilter` and
    `PisakaCore.LogFilterDraft`.

