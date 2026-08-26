# PisakaCore — Local Changes, Log & branch-switcher models

Design documentation moved verbatim from the root `CLAUDE.md` (which now holds only a one-line-per-file index). Each entry records a file's contract, invariants and the reasoning behind non-obvious decisions — read the relevant entry before modifying that file, and update it when behavior changes.

  - `LocalChangesModel.swift` — `@MainActor` `ObservableObject` for the Local
    Changes view, mirroring `WorkspaceModel`'s shape. Injects `GitServicing` (repo
    access) and `FileServicing` (working copy) so the real services run in `Pisaka`
    and in-memory stubs in tests. Publishes `changedFiles`, `groupingMode`
    (`flat`/`byFolder`), `selected`, `errorMessage`, and `root`. The `git`-touching
    entry points are `async` (the underlying `GitServicing` runs off the main
    thread): `refresh(root:) async`, `revert(_:) async -> [URL]`,
    `rows(for:) async -> [DiffRow]`, and `selectedRows() async -> [DiffRow]`;
    `toggleChecked`, `filesToRevert`, `select`, `tree`, and the *synchronous*
    `prepareForFolderChange(root:)` (see below) stay synchronous. The
    branch-heavy decision logic is factored into pure synchronous static helpers so
    it stays under fast unit tests while only IO/sequencing is async: `reconcile`
    (the refresh state-reconciliation — clear selection/revertSelection on a root
    change, else intersect with current ids, plus the selection re-bind),
    `guardRevert` returning a `RevertGuard` (`.proceed`/`.abort(reason:)` —
    "current exists and status + oldPath match, else abort"), and `revertedURLs`
    (the new path plus the restored old path for a rename). `refresh(root:)`
    first resolves the repo top level (`repositoryRoot(for:)`) and stores it as
    `root` — so an opened subfolder still diffs against repo-root-relative paths —
    then re-queries the repo, replacing `changedFiles` and re-binding the
    selection (via `reconcile`) to its refreshed `ChangedFile` (keeping its status
    current, e.g. a file that flips deleted→modified) or clearing it when gone, on
    success; on failure it clears state and sets `errorMessage` (never crashing the
    view). Overlapping refreshes are guarded by a monotonic generation token:
    `refresh` captures it at entry and, after each `await`ed IO resolves, commits
    the published state only if the token is still the latest — so a superseded
    refresh discards its result instead of clobbering a newer one. A *change of
    opened folder* (the raw requested root differs from `lastRequestedRoot`) also
    clears `changedFiles`/`selected`/`revertSelection`/`errorMessage`
    *synchronously at entry*, before the first `await`: the previous project's
    files belong to a different repo and must not stay actionable
    (selectable/revertable) during the query for the new repo's status. A
    same-root refresh (a save, the manual refresh button) skips this so the
    list/selection do not flicker on the common path.
    `select(_:)` validates the file is current; `tree` builds the `ChangeTree`;
    `rows(for:)`/`selectedRows()` build the side-by-side diff via `LineDiff` — old
    side from `HEAD` (empty for added/untracked, read from `oldPath` for a
    rename), new side from the working copy (a changed symlink uses its target
    string — what git stores — not the dereferenced target file; empty for a
    deleted file). It also publishes `isReverting` (read-only, backed by a
    re-entrant counter driven by `beginRevert()`/`endRevert()` so overlapping
    reverts each balance their own pair and the flag clears only when the last
    ends): the app raises it synchronously around the revert `Task` and gates the
    project-tree file operations (create / rename / delete) on it, refusing them
    while a revert's off-main `git` mutations are in flight — a second,
    uncoordinated disk writer would otherwise race `git checkout`/`git rm` (the
    same reason autosave is `suspend()`ed around a revert). Revert: publishes
    `revertSelection` (`Set<String>` of checked
    file ids, read-only to callers) toggled by `toggleChecked(_:)`;
    `filesToRevert(contextFile:)` is the pure batch-vs-single resolution (if the
    context row is checked, revert every checked file, else just that row);
    `revert(_:)` *re-queries* the repo (`changedFiles`) immediately before *each*
    file's mutation — the displayed list is a snapshot and nothing watches the
    filesystem on its behalf (the macOS FSEvents watcher feeds the *project tree*
    only, never this list), so a destructive revert verifies each file still has the same
    `status`/`oldPath` against fresh state and aborts the batch (with
    `errorMessage`) on any file that changed (e.g. an untracked/added file that
    became tracked and modified, which a stale revert would delete, discarding the
    new content; this per-file check goes through the pure `guardRevert` helper).
    The re-query is per file, not once before the loop: reverting the
    earlier files takes time during which a later file can change out of band, so a
    single up-front snapshot would leave a window that grows with the batch size;
    this collapses a possibly-minutes-old snapshot to the milliseconds between each
    file's re-query and its revert (the residual window is git's own). It calls
    `gitService.revert` once per remaining file, collecting the absolute
    URLs it reverted, then on full success clears `errorMessage`, `refresh`es
    (dropping the reverted files and re-binding/clearing the selection), and
    `subtract`s the reverted files from `revertSelection` (only those, not the
    whole set — the main actor processes UI events during the awaits, so a file
    the user checks while the trailing refresh runs is preserved rather than
    erased) — the first failure (or stale file) instead sets
    `errorMessage` and stops (leaving the checked set for a retry), and it returns
    the absolute URLs whose on-disk state changed so the app can resync open tabs.
    The *row-activation* decision — what opening a changed-file row means — lives
    here as pure static rules: `RowActivation` (`.diff` / `.resolveConflict`),
    `activation(for:)` returning `.resolveConflict` for a `.conflicted` file and
    `.diff` for every other status, `shortcutActivation(selected:)` returning
    `nil` for no selection (the keystroke is consumed but does nothing — a
    deliberate no-op) and `activation(for:)` for a selection, and
    `offersShowDiff(for:)` returning `false` for `.conflicted` rows (they already
    offer "Resolve…" which opens the same window — two names for one action would
    be noise). A parallel set of rules handles *jump to source* — opening the
    changed file itself rather than its diff: `offersJumpToSource(for:)` returning
    `false` for `.deleted` rows (a deleted file has no worktree source; the item
    is omitted rather than disabled, matching `offersShowDiff`'s precedent),
    `jumpToSourceURL(for:root:)` resolving the file against the repository root
    (for the same reason `revertedURLs(for:root:)` takes one — the opened folder
    may be a subdirectory of the repository) and returning the *new* path for a
    renamed file (never `oldPath`, which no longer exists on disk), and
    `shortcutJumpToSourceURL(selected:root:)` returning `nil` when either
    argument is `nil` (the keystroke is consumed but does nothing, the same
    deliberate no-op `shortcutActivation(selected:)` documents). These five entry
    points are the single routing point shared by the double-click, the "Show
    Diff" / "Jump to Source" context-menu items and the Cmd+D / Cmd+Down keyboard
    shortcuts; no view-layer code duplicates the decision.
    The whole batch is also guarded against a *mid-revert opened-folder switch*
    via a `rootRequestGeneration` token bumped *synchronously at refresh entry*
    whenever the requested folder changes: `revert` captures it at entry and,
    before each file's mutation and before every published-state commit, bails if
    it no longer matches — so a folder change that commits a new repo while the
    revert is suspended on off-main git I/O neither mutates the repo the user just
    left nor lets the trailing `refresh(root:)` re-publish it over the newly-opened
    project (whose own refresh owns that state). The detector is the *request
    generation*, not the published `self.root`: `refresh(B)` records the switch and
    clears state synchronously at entry but only commits `self.root = B` after its
    own `await`ed git I/O resolves, so a `self.root`-keyed guard would miss the
    window in between and let the suspended revert through against the old repo.
    A revert that *starts* in that same window (after `refresh(B)` bumped the
    request generation but before it committed `self.root = B`) is caught by a
    companion `publishedRootGeneration` token — the request-generation value the
    currently published `root` corresponds to, committed with `self.root` after the
    git I/O resolves. While a switch is pending it lags the request generation, so
    `revert` bails at entry when they disagree (otherwise it would capture the
    already-bumped generation next to the stale root and every `projectStillCurrent`
    check would pass). Each post-`await refresh` state write inside `revert`
    re-checks `projectStillCurrent` before committing — the awaited refresh can
    suspend long enough for a switch to land, and its own generation guard discards
    the stale result, so an unguarded trailing `errorMessage`/`revertSelection`
    write would clobber the new project's freshly published state. Those same
    trailing writes are *also* gated on `operationStillLatest()` (an
    `operationGeneration` token bumped by every public `refresh` and every `revert`
    at entry — but *not* by `revert`'s own internal trailing refreshes, which go
    through the non-bumping private `refreshImpl`): the UI lets *same-project*
    operations overlap (a save's auto-refresh, the manual-refresh button, a second
    context-menu revert), so an older failed revert suspended on its internal
    `await refreshImpl` can resume after a newer refresh/revert already published —
    and without this guard would restore its now-stale `errorMessage` over the
    newer result. `projectStillCurrent` only catches *folder* switches; this catches
    same-folder supersession. (The trailing refresh inside `revert` goes through
    `refreshImpl` precisely so a revert never makes *itself* look superseded.) The
    synchronous `prepareForFolderChange(root:)` is the counterpart of `refresh`'s
    switch-handling entry block (set `lastRequestedRoot`, bump
    `rootRequestGeneration`, clear list/selection/checks/error): the app calls it in
    the same main-actor turn that handles a folder open, *before* spawning the
    `Task`-wrapped `refresh`, so an in-flight revert observes the switch the instant
    it resumes rather than a turn later (a `refresh` that then runs for the same
    `lastRequestedRoot` no-ops the block). `prepareForFolderChange` *returns* the
    `rootRequestGeneration` its bump produced, which the app passes back into
    `refresh(root:requestGeneration:)`: unstructured `Task`s are not guaranteed to
    start in creation order, so two rapid folder opens (B then C) can run B's
    refresh task *after* C's — and without a pinned generation B's refresh would
    re-derive the switch from `root != lastRequestedRoot`, rewrite
    `lastRequestedRoot` back to B, win `refreshGeneration`, and leave the Changes
    panel on a different repo than the workspace. `refresh` rejects a passed
    generation that no longer equals `rootRequestGeneration` (before bumping
    `operationGeneration`, so a dropped refresh supersedes nothing). *Every* app
    refresh call site — folder-open, the post-save refresh, the manual refresh
    button, and the view's `onAppear`/`onChange` backstop — pins the generation it
    captured synchronously, so any refresh that ends up running after a newer folder
    switch is rejected here rather than entering `refreshImpl`, where its stale root
    (`!= lastRequestedRoot`) would be misread as a switch *back* to the old repo —
    rewriting `lastRequestedRoot`, bumping the request generation, rejecting the new
    folder's legitimate refresh, and stranding the panel on the previous repository.
    A refresh with no pinned generation (only the tests construct one) is never
    rejected. Separately, the refresh commit guard also discards a result whose
    captured `rootGeneration != rootRequestGeneration`: a folder switch bumps the
    request generation (not `refreshGeneration`) and clears the previous project's
    files up front, so an *already in-flight* refresh of the old folder that resolves
    after the switch must not re-publish them. Symmetrically, `revert(_:originGeneration:)` takes the
    generation the app captured *synchronously* from `currentRequestGeneration`
    before its own `Task` hop and bails at entry if it no longer matches: the revert
    body samples `root`/`rootRequestGeneration` only when it starts (a later
    main-actor turn), so a folder switch that fully commits in the gap would
    otherwise let a revert of the old project's `files` run against the newly opened
    repo (a path-equal, same-status file passing `guardRevert`). The trailing
    refreshes also run against the *requested* folder (`lastRequestedRoot`), not the
    resolved repo `root`: for a subfolder open the two differ, and passing the
    resolved root would look like a folder switch to `refresh` (spuriously clearing
    state and bumping the request generation against a project that never changed).
    Already-reverted files still stand and are returned for tab resync.
    On full success a
    file reports the new path (and, for a rename, *both* the deleted new path and
    the restored old path); on a *failure* the model resyncs only what the service
    says it changed — a thrown `PartialRevertError` (Core protocol) carries the
    repo-relative paths already changed before the failure (a rename revert is two
    on-disk steps and can fail between them, and a `checkout` writes the worktree
    before a late index-write failure), and a non-conforming failure changed
    nothing, so the model never reloads/closes
    a tab the revert never touched. Pure Foundation — no `Process`/AppKit/SwiftUI.
  - `Commit.swift` — the Log view's value type + `git log` parser. `public struct
    Commit: Identifiable, Equatable` (`hash` (identity), `parents: [String]` —
    first parent first, empty for a root commit, 2+ for a merge — `author`, raw
    ISO-8601 `date` string (kept as text so Core stays locale/format-free; the view
    formats it), single-line `subject`, decoded `refs: [String]`). The service runs
    `git log` with the exact `Commit.prettyFormat`
    (`"%H%x00%P%x00%an%x00%aI%x00%s%x00%D%x1e"` — NUL `%x00` field separators, RS
    `%x1e` record terminator, neither of which can appear inside a hash/name/date/
    subject/ref so a subject or ref containing spaces survives splitting). Pure
    `static func parse(_:) -> [Commit]` splits on RS, then NUL into six fields
    (skipping a wrong-field-count record); parents are space-split; `parseRefs`
    decodes the `%D` decoration (comma-split, stripping `HEAD -> ` and `tag: `
    prefixes and dropping a lone detached-`HEAD` entry). Empty output → `[]`.
    Foundation-only; the `Process` call lives in `GitCLIService`.
  - `CommitChangesParser.swift` — pure `static func parse(_:) -> [ChangedFile]`
    over `git diff-tree --name-status` output (a commit's files vs its first
    parent), mirroring `GitStatusParser`'s shape and reusing its `FileStatus`/
    `ChangedFile` types. Maps the leading status code per TAB-separated line:
    `M`/`T` → `.modified`, `A` → `.added`, `D` → `.deleted`, `R<score>` →
    `.renamed` (carrying `oldPath`), `C<score>` (copy) → `.added` of the new path
    with no `oldPath` (the source is untouched — same as `GitStatusParser`). Splits
    on `Character.isNewline` (so a CRLF grapheme splits cleanly with no trailing
    CR); blank/short lines skipped; empty output → `[]`. Foundation-only.
  - `CommitGraphLayout.swift` — pure, Foundation-only branch-graph layout for the
    Log view's graph gutter (color-free geometry, palette resolved at draw time —
    the minimap precedent). `pure enum CommitGraphLayout { static func layout(_:
    [Commit]) -> CommitGraph }` over topologically ordered commits (newest first,
    parents below). `CommitGraph` = `rows: [CommitGraphRow]` (one per input commit,
    same order) + `width` (lane count of the widest row, 0 for `.empty`).
    `CommitGraphRow` = node `column` (0-based lane) + stable `colorIndex` + `edges`
    (the segments leaving the *bottom* of the row toward the next; a row's
    *incoming* segments are just the previous row's `edges`, so only outgoing are
    expressed). `GraphEdge` = `fromColumn`/`toColumn`/`colorIndex`
    (`from == to` → vertical lane continuation/pass-through, a difference →
    diagonal branch-open or merge). Algorithm: walk rows top-down maintaining
    *active lanes*, each "seeking" a parent hash a placed commit named. A node sits
    in the lane already seeking its hash (else a fresh lane+color is allocated);
    the first parent continues the node's lane keeping its color (unless another
    lane already seeks it, then it merges in), each additional parent reuses a
    seeking lane or opens a fresh-colored one, and untouched lanes pass straight
    through keeping their color (so a branch's color is stable across rows). At most
    one lane ever seeks a given hash (two children converge into one lane); freed
    slots are reused (first nil slot) to keep the graph narrow. Unit-tested like
    `MinimapModel`/`LineDiff`.
  - `LogFilter.swift` — the server-side history-query constraints + a client-side
    message-search predicate, pure and unit-tested (the `Process` consumer lives in
    `GitCLIService`). `public struct LogFilter: Equatable` carries four *server*
    dimensions — `refSelection` (`RefSelection.all` → `--all`, the default
    "All" selection; `.ref(String)` → a positional revision), `author`, `since`,
    `until` (`Date?`), and `path` — and builds `gitArguments() -> [String]` in
    git's grammar order: option filters first, then a named ref's positional
    revision behind `--end-of-options`, then the pathspec last behind a `--`
    separator. `.all` emits `--all` (itself an option, so it leads); a named ref is
    emitted *after* all options and prefixed with `--end-of-options` because a ref
    name may legitimately begin with `--` (git's `check-ref-format` accepts e.g. a
    tag `--max-count=0`) and passed bare would be parsed as a command-overriding
    option — and because everything after `--end-of-options` must be positional, the
    `--author`/`--since`/`--until` options are placed before it. Blank author/path
    (after trimming) and a blank `.ref` name contribute nothing (a blank ref
    degrades to `--all` so the query is never silently narrowed to HEAD); dates
    format as strict UTC ISO-8601. `mayProduceNonContiguousHistory` reports whether
    the filter can leave a shown commit pointing at an excluded parent — true for the
    commit-limiting `author`/`since`/`until` (which omit commits without rewriting
    parents), false for `.all`/`.ref` (connected ancestry) and `path` (parent-
    rewritten by `--parents`) — so the view suppresses the branch graph when it would
    otherwise draw dangling lanes (the same reason it suppresses for message search).
    The
    message search is deliberately **not** a field (so a search change never
    re-fetches): `static func search(_ commits:, query:) -> [Commit]` filters by
    case-insensitive subject substring over already-loaded commits, blank query =
    pass-through. A companion pure helper `resolvedRef(amongKnown references:
    [String]) -> String?` is the branch picker's read seam: `.all` → `nil` ("all
    refs", which the view maps onto its own "All" sentinel tag), `.ref(name)` →
    `name` only when `references.contains(name)`, else `nil` (an unknown/dangling
    ref — e.g. a stale selection left from a previous folder — degrades to "all",
    mirroring `gitArguments()`'s refusal to silently narrow the query). It is a
    *display* resolution only: the picker reads through
    `LogFilterDraft.displayRefTag(amongKnown:)` which delegates here, while the write
    path (`LogFilterDraft.selectRef(tag:)` → `filter.refSelection`) carries the
    selection verbatim so an apply fired before the ref list arrives cannot collapse
    the branch to "All".
  - `LogFilterDraft.swift` — the Log filter bar's single editable draft, shared by
    the macOS bar and the iOS advanced-filter form. Pure, Foundation-only, fully
    unit-tested; the view layer holds one `LogFilterDraft` value (plus a separate
    `search` string — message search is not a `LogFilter` dimension) and applies
    only from user-intent bindings. Holds `refSelection: LogFilter.RefSelection`,
    `author`/`path: String` (verbatim/untrimmed as typed), `sinceEnabled`/`since:
    Date`, `untilEnabled`/`until: Date`. The seed/assemble pair is
    `init(filter: LogFilter, defaultDate: Date)` and `filter(calendar: Calendar) ->
    LogFilter`: `init` seeds every dimension from `filter`, parking a disabled
    picker's date on `defaultDate`; a present bound is seeded verbatim (the inclusive
    last-second-of-day instant for `until` is still on the selected day, so
    `filter()` re-derives the same bound — the round-trip is idempotent and needs no
    inverse, as `since`'s start-of-day already is). `filter(calendar:)` trims
    author/path (blank → `nil`), normalizes `since` to `calendar.startOfDay(for:)`
    and `until` to the last second of the selected day (`Calendar` so "the selected
    day" is the user's local day; git's `--until` is inclusive — the end-of-day
    includes every commit on that day but none at the next midnight), and carries
    `refSelection` through verbatim — never re-resolved against the known refs,
    which is what the old `applyFilter` got wrong by routing through
    `resolvedRef(amongKnown:)`. The picker seam is `static let allRefsTag = ""`,
    `displayRefTag(amongKnown:) -> String` (via `LogFilter.resolvedRef`, mapping
    `nil` onto the sentinel) and `mutating selectRef(tag:)` (empty tag → `.all`,
    else `.ref(tag)`). The draft is the value a user-intent binding writes and
    applies, so seeding the view's state (`draft = LogFilterDraft(filter:,
    defaultDate:)`) can never reach the apply path — the structural cure for the
    seed/echo loop, replacing the value-equality suppression that failed under
    interleaved applies.
  - `CommitLogModel.swift` — `@MainActor ObservableObject` for the Log view,
    mirroring `LocalChangesModel`'s shape: injects `GitServicing`, funnels mutation
    through testable methods, pure Foundation. Publishes `commits` (most recent
    first), `selected` (read-only — set via `select(_:)` which validates membership,
    or reconciled by refresh), `errorMessage`, `root`, `isLoading`, `filter`
    (`LogFilter`), `searchQuery`, and `references` (refs for the filter picker);
    `visibleCommits` is the computed `commits` narrowed by `LogFilter.search`. The
    one git entry point `refresh(root:limit:request:) async` resolves the repo top
    level, fetches commits + (best-effort) refs off-main, and on success replaces
    `commits`/`references`, reconciles the selection (pure `reconcileSelection`),
    and clears `errorMessage` — on failure clears state and sets `errorMessage`
    *and* clears the stale `references` (so the old repo's branches don't linger in
    an actionable picker over a log stuck in an error state), never crashing the
    view. Ordering uses a single monotonic `requestGeneration` token captured
    **synchronously** via `prepareForRefresh(root:) -> Int` (called on the
    main-actor turn that *creates* the refresh `Task`, before any `await`, and
    passed back as `request:`): unstructured `Task`s are not guaranteed to start in
    creation order, so a token bumped only inside the async body could let a
    superseded folder/filter change win — capturing it synchronously orders requests
    by creation. `refresh` bails at entry when a newer request superseded it and
    re-checks the token after every `await` to discard a slower, superseded fetch on
    both the success and failure paths (a direct call may omit `request:`, then a
    fresh token is bumped at entry). `prepareForRefresh` also resets the previous
    repo's state (filter → default `--all`, search, ref list, selection, error, and
    the commit list itself) on a folder switch (the requested root differs), so a
    stale `.ref` never queries a branch the new repo lacks and the previous repo's
    history is neither shown nor selectable (querying detail against the now-stale
    `root`) during the window until the new fetch resolves — mirroring
    `LocalChangesModel`, which clears `changedFiles` on a switch; `refresh` repeats
    the same folder-switch reset as defense-in-depth for a direct call.
    `prepareForFilter(_:root:) -> Int?` is the synchronous no-op/ordering gate:
    it compares against `requestedFilter` (the latest synchronously requested filter),
    not the published `filter` which lags by one phase while a fetch is in flight;
    on a real change it bumps `requestGeneration` via `prepareForRefresh` and stores
    `requestedFilter`. `applyFilter(_:root:limit:request:)` publishes `filter =
    newFilter` synchronously at task start then re-`refresh`es (threading the token).
    The guard **cannot** suppress a view echo: when two applies interleave the publish
    lags the latest request, so an echo built from the published `filter` is a
    genuinely different filter and is accepted — it would spawn a fetch. Not echoing
    is the view's obligation, achieved structurally by `LogFilterDraft` / user-intent
    bindings (every apply lives in a `Binding.set`/`onSubmit`, `seedFromFilter`
    assigns the draft directly and is structurally unable to reach the apply path;
    value-equality suppression was tried and failed under interleaving — the reason
    the draft exists). Exposes `currentRequestedFilter` alongside
    `currentRequestGeneration` so the publish-lags-request contract is readable and
    assertable. `setSearchQuery(_:)` just updates the query (no git call). Commit
    detail: `changes(for:) async -> [ChangedFile]` (via `commitChanges`) and
    `rows(for:in:) async -> [DiffRow]` build the commit-vs-first-parent diff via
    `LineDiff` — old side from `commit.parents.first` (empty for `.added`, a root
    commit, or a failed read; reads `oldPath` for a rename), new side from
    `commit.hash` (empty for `.deleted`). Both swallow errors / return `[]` before
    the first refresh, mirroring `LocalChangesModel`.
  - `BranchSwitcherModel.swift` — `@MainActor ObservableObject` for the
    branch-switcher widget, mirroring `LocalChangesModel`/`CommitLogModel`'s shape:
    injects `GitServicing`, funnels mutation through testable methods, pure
    Foundation. Publishes `branches` (locals-first, then remotes, in
    `BranchRef.build` order), `current` (the checked-out local branch, `nil` for a
    detached/unborn HEAD), `filterText` (a mutable binding), `isWorkingTreeDirty`
    (any `changedFiles` — the widget warns a checkout may be blocked), `errorMessage`,
    and `root`; plus computed `filteredLocalBranches`/`filteredRemoteBranches`. The
    branch *list* is built from the existing `references(root:)` (full refnames) fed
    through `BranchRef.build(fromRefnames:current:)` — no `branches(...)` git method;
    only `currentBranch` is queried in addition. `refresh(root:request:) async`
    resolves the repo top level, loads refnames + `currentBranch` + `changedFiles`
    off-main, and on success replaces the list/current/dirty flag; on failure it
    clears state and sets `errorMessage`. Ordering uses a monotonic
    `refreshGeneration` token captured **synchronously** via
    `prepareForRefresh(root:) -> Int` — called on the main-actor turn that *creates*
    the refresh `Task`, before any `await`, and passed back as `request:` — so two
    rapid folder opens settle on the latest even when their unstructured tasks start
    out of creation order (a token bumped only inside the async body would let the
    earlier folder's task win); a superseded `request` bails at entry.
    `prepareForRefresh` also clears the previous repo's branch list synchronously on
    a folder switch so the widget is never actionable against a repo the user left
    (the `LocalChangesModel`/`CommitLogModel` precedent). A direct `refresh` (tests,
    the internal trailing refresh after a switch/create) may omit `request:`. `switchTo(_:) async -> Bool` checks out a *local* branch (git's
    short name) and refreshes on success, putting git's message (naming the
    conflicting files on a `checkoutFailed`) into `errorMessage` on failure.
    `createBranch(name:from:fetchRemote:) async -> CreateOutcome` validates the name
    (`GitRefName.isValid`, else `.invalidName`), fetches first when starting from a
    remote ref (unless `fetchRemote: false`) — a failed fetch returns
    `.fetchUnavailable(GitError)` *without* setting `errorMessage` (a recoverable
    choice: the caller retries with `fetchRemote: false` to create from the local
    tracking ref, or cancels; the payload lets it special-case `credentialsRequired`
    → Settings) — then `createAndCheckout`s at the start point and refreshes
    (`.created`, or `.failed` with git's message in `errorMessage`).
    `checkoutRemote(_:originGeneration:) async -> Bool` is the "click Checkout on a
    remote branch" (git DWIM) entry point: it computes `remoteCheckoutDecision(for:
    among:)` over the current `branches` in the task body and executes it through the
    *existing* paths — `.checkoutLocal(local)` → `switchTo(local, originGeneration:)`,
    `.createLocal(name, from)` → `createBranch(name:from:.ref(from),fetchRemote:
    false,originGeneration:)` (return `== .created`) — so both paths inherit the
    delegate's origin-generation pinning and trailing refresh, and **no fetch** is
    performed (Checkout is immediate). Threading `originGeneration` straight through
    means a folder switch that committed across the app's `Task` hop makes the
    delegate bail before any git call with `errorMessage` untouched; the decision is
    computed *after* that clears `branches`, so it degrades to `.createLocal` whose
    `createBranch` then bails on the generation mismatch — a superseded checkout never
    reaches git. Pure static
    helpers make the branching decisions testable without IO:
    `defaultBranchName(forRemote:)` (the pre-filled create name — `origin/master` →
    `master`); the `RemoteCheckoutDecision` enum (`.checkoutLocal(BranchRef)` when a
    same-named local already exists, `.createLocal(name:from:)` otherwise) + the pure
    `remoteCheckoutDecision(for:among:)` that decides between them (target local name
    = `defaultBranchName(forRemote:)`; a matching `BranchRef.locals` short name →
    `.checkoutLocal`, else `.createLocal` from the remote ref — no fetch, a decision
    over the passed list only, the `StartPoint`/`defaultBranchName` precedent).
    `StartPoint` (`.head`/`.ref(BranchRef)`) exposes the
    git `revision` (`HEAD` or the full refname). Pure Foundation — no
    `Process`/AppKit/SwiftUI.
