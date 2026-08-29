# PisakaCore — Find in Files (gitignore matching + project search)

Design documentation moved verbatim from the root `CLAUDE.md` (which now holds only a one-line-per-file index). Each entry records a file's contract, invariants and the reasoning behind non-obvious decisions — read the relevant entry before modifying that file, and update it when behavior changes.

  - `GitignoreMatcher.swift` — pure, testable `.gitignore` pattern matching for
    the Find in Files traversal (Foundation only), following gitignore(5) and
    git's own `dir.c`/`wildmatch.c`. `GitignorePattern` parses one line into its
    four decisions *once* — `negated` (`!`), `anchored` (a `/` anywhere but the
    trailing position), `directoryOnly` (a trailing `/`), and the per-component
    globs — so matching a path is a walk over compiled tokens rather than a
    re-reading of the source text; `init?(line:)` returns `nil` for a blank line, a
    comment, or nothing but the markers. Grammar: `\#`/`\!` escape the two leading
    characters; trailing **spaces** are stripped unless backslash-escaped (git's
    `trim_trailing_spaces` verbatim — spaces only, so a trailing tab stays part of
    the name); `*` matches within one component, `?` one character, `[a-z]`/
    `[!a-z]`/`[^a-z]` a class, a backslash escapes the next character; `**` as a
    whole component matches zero or more components, *except* as the last
    component where it matches one or more (git's `abc/**` covers what is inside
    `abc`, not `abc` itself — spelled by inserting one `*` component in front of
    it rather than by a second rule in the matcher); an unanchored pattern is
    compiled to `**/pattern`, which is exactly what "matches at any depth" means.
    There is deliberately **no** leading-period rule: unlike shell globbing, `*`
    matches a dotfile, as `wildmatch` does. Both matchers are
    **dynamic-programming walks, not naive backtracking** — component-wise
    `O(pattern × path)` and, in `Glob`, `O(name × pattern)` — so a pathological
    `a*a*a*a*b` stays fast instead of going exponential (pinned by a test).
    `public enum Glob { static func matches(name:pattern:) -> Bool }` is the
    single-component rule exposed on its own because the Find in Files **file
    mask** (`*.ts,*.tsx`) is exactly that rule applied to a file name.
    `GitignoreRules(fileContents:)` parses one whole file (split on any Unicode
    line break, so CRLF contents leave no stray carriage return in a pattern) and
    `decision(relativePath:isDirectory:) -> Decision?` gives that file's verdict
    (`.ignored`/`.included`/`nil` when nothing matches) with **last match wins**
    inside the file (the patterns are walked in reverse). `GitignoreStack` layers
    the files of a directory walk: `appending(rules:relativeDirectory:)` must be
    fed **outermost first** (the order a top-down traversal discovers them; an
    empty file is dropped rather than stored, since it can never have an opinion),
    and `isExcluded(relativePath:isDirectory:)` applies git's three rules —
    *deeper overrides outer* (levels are read back to front, the first with an
    opinion decides, so `sub/.gitignore`'s `!important.log` re-includes what the
    root's `*.log` excluded), *last match wins inside one file* (delegated to
    `GitignoreRules`), and *an excluded directory is never re-opened from inside*
    (every ancestor is judged first and an excluded one short-circuits — git gets
    this for free by not descending at all, which is also why it never reads a
    nested `.gitignore` down there). A level applies only *strictly under* its own
    directory, matched as a whole-component prefix, which is what makes an
    anchored pattern in a nested file relative to *that* directory. **Scope
    limits, deliberate:** tree `.gitignore` files only — no `core.excludesFile`,
    no `.git/info/exclude`, no per-repo config — matching is case-sensitive (git
    with `core.ignorecase=false`), and `.git`/`.DS_Store` are **not** this
    matcher's business: the traversal excludes them via
    `FileService.isExcludedEntryName`. Unit-tested in `GitignoreMatcherTests`,
    including an **oracle table** of 43 (pattern, path, expected) rows captured
    from `git check-ignore` (git 2.55.0, `core.ignorecase=false`) with the exact
    command line and repo layout recorded in a comment; the one
    `check-ignore`-vs-traversal divergence (`abc/**` reported as matching the
    directory `abc/` itself) is held out of the table and documented in its own
    test with the `git status` evidence.
  - `ProjectSearchModel.swift` — the observable state of the project-wide Find in
    Files: the traversal of the opened folder, the search of every file worth
    reading, and the project-wide Replace All. Mirrors
    `LocalChangesModel`/`CommitLogModel`'s shape — `@MainActor ObservableObject`,
    I/O injected behind `FileServicing`, branching decisions as pure static
    helpers, overlapping operations ordered by a generation token captured
    *synchronously* before any `Task` hop — and stays pure Foundation with **no
    reference to `WorkspaceModel`**: open buffers reach it through injected
    closures (`openBuffers: () -> [URL: String]`, `applyBufferText: (URL, String)
    -> Bool`), so Core stays unaware of the workspace. `openBuffers` is a
    *whole-snapshot* closure rather than a per-URL lookup, and that shape is the
    load-bearing part: it reads the workspace, so it must run on the main actor,
    and deciding whether one candidate has a tab costs a
    `CanonicalPath.canonical` symlink resolution **per open tab** (measured ~15 µs
    each) — the same rule `WorkspaceModel.fileID(forURL:)` matches with. Asked per
    traversed file that is `files × (1 + tabs)` resolutions on the main thread,
    which on a project of ordinary source files exceeds the *off-main* read the
    chunk is dispatched to do, so the main actor ends up the search's bottleneck —
    exactly what the off-main design exists to prevent (seconds of cumulative
    main-thread work on a large repo, scaling invisibly with how many tabs happen
    to be open). Snapshotting once before the walk turns it into `tabs`
    resolutions on the main actor plus one *off-main* resolution per file, and the
    model re-keys the snapshot by `CanonicalPath.canonical(_:).path` off-main so a
    candidate is matched with a dictionary hit (skipped entirely when no tab is
    open). `replaceAll` deliberately keeps calling it *per file* — there the cost
    is bounded by the matched files rather than the whole project, and a fresh
    read is the point: a tab opened or edited mid-batch must be seen rather than
    written to disk behind the editor's back. `MatchPreview` is the clipped
    line a result row draws (`text` with its separator stripped, plus the match's
    range *within that window*) — clipped to `previewWindow` 300 UTF-16 units
    starting at most `previewLead` 40 before the match, so a minified single-line
    bundle cannot produce a 200 KB row. It is **no longer search-only**: a usages
    row carries one too, built by `preview(for:in:)` from `TextualUsageScanner` and
    from `LSPIntelligenceProvider`, so a Find in Files row and a Find Usages row
    clip identically by construction rather than by two rules that agree today; it
    is `Sendable` because usages rows are assembled off the main actor and published
    per chunk (`core-intelligence.md`); `FileSearchResult` carries `fileURL`, the
    `relativePath` group header, and `matches`/`previews` as **parallel arrays**
    (index *i* of one describes index *i* of the other) rather than pairs, so the
    view hands `matches` straight to the editor's selection path — the shape
    `TextSearchEngine` already speaks. Published: `results` (grouped by file in
    traversal order, republished *per chunk* so rows appear while the remaining
    files are still being searched — the directory walk itself completes first,
    since the file list is collected in one off-main pass before any chunk runs),
    `isSearching`, `truncated`, `errorMessage`, and the view-bound
    `query`/`fileMask`. `prepareForSearch(root:) -> Int` is the synchronous
    generation bump + stale-result clear (`LocalChangesModel
    .prepareForFolderChange`'s precedent and reason: the app calls it in the same
    main-actor turn that handles a folder open, before spawning any `Task`, so an
    in-flight search resumes to find itself superseded rather than publishing the
    previous project's files into the new one's window); a repeat call for the
    same folder is a no-op. It clears `query`/`fileMask` (and the private
    `resultsQuery` pair — see `replaceAll`) **together with**
    `results`, and that pairing is load-bearing rather than tidiness: those two
    record *what produced the rows*, which is how the view tells rows answering
    its current controls from stale ones, so leaving them describing a query the
    new project was never searched with — next to an empty `results` — reads as
    "that query genuinely matched nothing here". A Find in Files window left open
    across a folder switch would then state **"No results" about a project it
    never walked** (Enter would take the rows-are-current branch and do nothing,
    so recovery meant editing the query), with Replace All still armed from the
    folder the user just left. Cleared, the rows and the controls honestly
    disagree until a search actually runs. No search is spawned here — the window
    searches only when the user asks. `search(root:query:mask:request:) async` rejects a
    superseded `request` before any work, validates the pattern **once** by
    running the engine against an empty buffer (so it is judged by exactly the
    code that will search the files — an empty pattern clears silently, an invalid
    regex publishes its reason), then walks off-main and searches in chunks of
    `chunkSize` 32, re-checking the token after *every* `await` so a superseded
    search drops its partial results instead of interleaving them. The buffer
    lookup happens on the main actor *before* each chunk crosses to the queue (it
    reads the workspace); a dirty open buffer is searched instead of the file on
    disk, so results match what the user sees. Matches are capped at
    `defaultMaxMatches` 10 000 with `truncated` published (a one-character query on
    a large repo must not build a multi-million-row list), and a file's list may be
    clipped mid-way at the cap. The cap is enforced **twice, at two different
    layers**, and the inner one is a memory guard rather than a duplicate rule:
    `searchChunk` takes a `matchBudget` bounding what the chunk may *materialize*,
    because clipping only in the main-actor loop meant every match — and, far more
    expensively, its ~300-unit `MatchPreview` — was built for all `chunkSize` files
    before a single one was discarded, so one chunk holding a few megabyte-scale
    files (a lock file, a minified bundle, generated code) allocated hundreds of
    megabytes it immediately threw away. The caller passes `remaining + 1`, one
    *over* what it can still accept, so the surplus match keeps the outer loop's
    `> remaining` overflow test — and with it the `truncated` flag — working
    unchanged. **What is skipped, and by whom:** `.git`/`.DS_Store`
    by the traversal (`FileService.isExcludedEntryName` — checked here too, so a
    differently-behaving service cannot leak the repository's internals into the
    results), everything else by `GitignoreStack` (a directory's own `.gitignore`
    is read *before* its entries are judged, so it governs its own directory as
    git's does, and is passed down so nested files layer over outer ones), binary
    and oversize files by `FileServicing.readTextIfNotBinary` (`defaultMaxFileBytes`
    1 MiB), and **symlinks are skipped on both sides**: a symlinked *directory* is
    not descended into (it can point back up the tree — an unbounded walk — and its
    target is already reached under its real name), and a symlinked *file* is not
    collected, for the same two reasons plus a third. `isDirectory` comes from
    `.isDirectoryKey`, which dereferences the link, so a link to a file arrives in
    the listing indistinguishable from an ordinary entry — it would be searched
    (duplicating its target's matches under a second path, or pulling in content
    from outside the project) and, on Replace All, *overwritten*: `FileService
    .write` goes through `String.write(to:atomically:)`, which renames a temp file
    over the destination and so silently replaces the link itself with a regular
    file. The probe is one `symbolicLinkDestination(at:)` per mask-passing file,
    run off-main and dwarfed by the read that follows it.
    An unreadable directory is skipped rather than failing the search.
    Traversal emits a directory's own files *before* its subdirectories, so results
    stream root-first (`contentsOfDirectory` sorts directories first, which is
    right for a tree view and backwards for a result list), keeping the listing's
    alphabetical order within each group so the result order is deterministic.
    **The traversal itself now lives in `ProjectFileWalk`** (`collectFiles`,
    `matchesMask`, `relativePath`, moved verbatim — doc comments included — and
    called through from here), because the symbol index has to walk a project by
    exactly these rules: a file Find in Files refuses to search because a
    `.gitignore` excludes it must not turn up as a go-to-definition target either.
    Nothing above changed in the move; the reasoning stays written here, where it
    was, and `ProjectFileWalkTests` holds the traversal tests that moved with it.
    Its entry is in `core-intelligence.md`. The
    work runs on a private serial queue (`GitCLIService`'s `offMain` shape) while
    the model itself stays `@MainActor`. `replaceAll(template:originGeneration:)
    async -> ReplaceSummary` has **two branches and one rule**: a file with an open tab is
    replaced *in the buffer* through `applyBufferText` — *this batch* never writes
    it to disk — so the tab's own unsaved edits survive instead of being
    overwritten by a disk write behind the editor's back; every other
    file is read, rewritten and written back through `FileServicing`. The buffer
    branch is **not** a promise that the result stays unsaved: `replaceAllInProject`
    releases `autosave.suspend()` as soon as the batch ends and the replacement is
    an ordinary `updateText`, so autosave writes those buffers within its idle
    window like any other edit — the confirmation dialog and README say so rather
    than offering a chance to back out that does not exist. **Nothing is
    applied blind**: `results` is a snapshot and this is a destructive batch, so
    each file is re-read and re-matched immediately before its write
    (`LocalChangesModel.revert`'s per-file re-query, for the same reason — the
    window shrinks from "however long the list has been on screen" to the
    microseconds between the check and the write), and a file whose **leading**
    matches no longer sit exactly where the results say is skipped and counted, not
    clobbered. The comparison is on the *leading* matches because the cap can clip
    a file's list mid-way, and a match appearing after every captured one cannot
    invalidate any of them — while a shifted, resized, added-before or vanished
    match makes every later range suspect. The plan is built from the **fresh**
    scan (so a regex template's group references resolve against the text actually
    on disk) and applied last-to-first per `replacePlan`'s ordering guarantee. A
    per-file read/write failure is recorded and the batch continues — one
    permission-denied file must not strand the rest — and the **project** token is
    re-checked
    after every `await`, so a folder switch mid-batch stops the walk rather than
    continuing to rewrite a project the user left — returning the counts
    accumulated so far with `ReplaceSummary.abandoned` set, **not** a zeroed
    summary: the files written before the switch really were written, so reporting
    nothing would tell the user "no file matched" about a batch that had already
    changed their project *and* would skip the app's `filesChanged > 0`-gated Local
    Changes / tree refresh for them (`abandoned` also makes `isEmpty` false, so the
    view states plainly that the batch stopped early and the rest is untouched).
    The file already in flight keeps its write: this rolls nothing back, as `git
    checkout` does not either, and a partial batch that silently reverted would be
    worse than one that reports honestly. That token is a *second* generation
    counter (`rootGeneration`, bumped only by an actual folder change) rather than
    the search `generation`, for the reason `LocalChangesModel` keeps
    `rootRequestGeneration` apart from `operationGeneration`: the Find in Files
    query field stays live while a batch runs, so a keystroke there bumps the
    search generation — and a `generation`-keyed guard would abandon the batch and
    return a *zeroed* summary after N files had already been rewritten, telling the
    user nothing happened and skipping the app's Local Changes/tree refresh. A new
    query cannot invalidate the batch anyway: it works from a snapshot it already
    holds and re-verifies every file immediately before writing it. Those
    mid-batch re-checks start only once the batch does, which is why the *entry*
    is pinned as well: `originGeneration` is the `LocalChangesModel
    .revert(_:originGeneration:)` precedent — the project token the caller
    captured **synchronously**, in the same main-actor turn as the click that
    confirmed the batch and *before* the `Task` hop (`ProjectSearchView
    .confirmReplaceAll` reads `currentRootGeneration` right after the alert
    returns, since `replaceAllInProject`'s own synchronous prefix already runs
    *inside* that task and so could not close the gap). The body samples
    `rootGeneration` only when it actually starts — a later turn — so a folder
    switch that fully commits in between would otherwise let a batch issued for
    the previous project run against the newly opened one, rewriting files the
    user never searched. A mismatch returns `ReplaceSummary(abandoned: true)` —
    zeroed counts but **not** an empty summary, for the same reason the mid-batch
    bail does: the view then says the batch stopped because the folder changed
    rather than the misleading "no file matched"; nothing has run at that point,
    so `abandoned` alone carries the message. The `nil` default is never rejected
    (an unpinned call makes no claim about which project it was issued for, the
    path direct calls and the tests take). The pinned token is
    `currentRootGeneration` — the **project** token — and deliberately *not*
    `currentRequestGeneration`: a query change bumps the request token, and a
    batch pinned to that would abort itself the moment the user typed in the
    still-live query field, after files had already been rewritten. The
    staleness re-match likewise runs against a **snapshot of the query**, the
    private `resultsQuery`, rather than against `query` — *defense-in-depth for the
    fact that `query` is a settable public `@Published`*, not a live bug: nothing
    in this app writes it outside `search`/`prepareForSearch` (`ProjectSearchView`
    keeps its own `@State` for the field and only reads the model's), which is
    exactly what makes `model.query` "the query recorded at the start of the
    search" that the view's `resultsMatchControls` gate compares against — so the
    two are equal at every `replaceAll` entry today. A caller that instead *bound*
    a live field to `query` would make them diverge the moment the user edited it
    without re-searching (and would have to re-point `resultsMatchControls` at the
    snapshot too, or that gate becomes vacuously true). Judging a current result
    list by a pattern nothing was searched with makes *every* file fail the
    staleness check — the data stays safe, nothing is written, but the batch
    reports "everything skipped" about a perfectly current list, which reads as a
    defect in the replacement rather than as a field the user moved on from.
    `resultsQuery` is written wherever `results` is (`search` publishes both
    together, `prepareForSearch` clears both), so the pairing cannot drift — and
    it tracks the *latest* search rather than being captured once. The
    open-buffer branch re-reads the buffer *after* its off-main hop and skips a
    buffer that moved, for the same reason the disk branch re-reads inside the hop
    — the editor stays interactive, so applying text computed from the older buffer
    would silently drop whatever the user typed while the replacement was being
    built. The *disk* branch carries the same interactivity the other way: the
    branch is chosen before the hop, so a tab the user **opens while that file's
    write is in flight** read the pre-replacement text and is clean — nothing else
    would ever correct it, and a later save would put the stale text back over the
    batch's result. `.written` therefore carries the text on both sides of the
    write (one file's worth at a time, dropped at the end of its iteration) and
    `reconcileBufferOpenedDuringWrite(url:original:replaced:)` hands the
    replacement to that tab through `applyBufferText` — exactly where the buffer
    branch would have left it (changed in the tab, the save still the user's) —
    but only while the tab still holds precisely what was on disk, so one opened
    *and* typed into inside that window is left alone rather than clobbered.
    `ReplaceSummary` (`filesChanged`,
    `matchesReplaced`, `filesSkipped`, `errors`) keeps `filesSkipped` and `errors`
    **separate** on purpose: a *skipped* file is one the batch declined to touch
    because it no longer looks the way the results describe it (the `guardRevert`
    philosophy), while an *error* is a read or write that actually failed; neither
    stops the batch. `results` is deliberately left describing pre-replacement
    text, so the caller re-runs the search afterwards. Pure static helpers
    (`maskPatterns`, `searchChunk`, `preview`, `replacedText`, `replaceOnDisk`,
    plus the `ProjectFileWalk` trio it forwards to — `matchesMask`, `collectFiles`,
    `relativePath`) keep the branching under fast unit
    tests in `ProjectSearchModelTests` while only I/O and sequencing are async.
    **Known limits (accepted boundaries of Find in Files / Text Search)** — five
    behaviors that are deliberate rather than oversights, recorded so a reader
    does not re-derive them as bugs. (1) `reconcileBufferOpenedDuringWrite`
    **discards** the `applyBufferText` result (`_ = applyBufferText(url,
    replaced)`): a refusal there is silent, unlike the ordinary buffer branch,
    which records one in `ReplaceSummary.errors`. The file *was* written to disk
    correctly, so the batch's own report stays true; what is lost is the notice
    that a tab which opened mid-write could not be corrected — the narrow race
    the reconciliation exists for at all. (2) A **non-UTF-8** file is classified
    differently depending on which `readTextIfNotBinary` runs: the real
    `FileService` overrides it byte-level and returns `nil` (→ *skipped*, since
    `String(data:encoding:.utf8)` fails), while the protocol extension's default
    goes through `read(url:)` — `String(contentsOf:encoding:.utf8)` — which
    *throws*, so an in-memory stub or any other conforming type reports it as an
    *error* instead. Both outcomes are safe (the file is never searched and never
    written); only the summary's wording differs. (3) The **file mask is
    case-sensitive**: it is `GitignoreMatcher`'s `Glob` applied to one file name,
    and that matcher is case-sensitive throughout (git with
    `core.ignorecase=false`), so `*.TS` does not match `foo.ts`. (4) A
    **whitespace-only pattern** is rejected as `.emptyPattern` in *regex* mode
    too: `matches(in:query:)` trims and throws before it ever looks at
    `isRegex` ("an empty field is 'no query', not a search for spaces"), so a
    regular expression consisting only of literal spaces cannot be run — a
    character class or an escape (`[ ]`, `\s`, `\x20`) is the way to search for
    them. (5) **`^`/`$` anchor after a superset of the editor's line
    separators**: `.anchorsMatchLines` uses ICU's terminator set, which adds VT
    (U+000B) and FF (U+000C) to the LF/CR/CRLF/NEL/LS/PS that `LineStartIndex`
    splits on. In a file carrying a form feed (an Emacs-era page separator in C
    and Lisp sources) `^` can therefore match where the gutter, the minimap and
    `SearchMatch.lineNumber` all place the offset *inside* a line, and two such
    matches report the same line number. The ranges stay exact — a replacement
    rewrites precisely what matched — and ICU offers no option to exclude VT/FF
    alone, so it is recorded and pinned by a test
    (`testRegexAnchorsFollowICUTerminatorsIncludingFormFeed`) rather than fixed.
