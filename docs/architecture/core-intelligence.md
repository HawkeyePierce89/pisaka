# PisakaCore — code intelligence (symbol index, go-to-definition, completion)

Design documentation moved verbatim from the root `CLAUDE.md` (which now holds only a one-line-per-file index). Each entry records a file's contract, invariants and the reasoning behind non-obvious decisions — read the relevant entry before modifying that file, and update it when behavior changes.

  - `Symbol.swift` — the two value types the whole feature stands on.
    `SymbolKind` is a closed, color-free enum of what the shipped queries can
    actually distinguish (`type`, `function`, `method`, `property`, `constant`,
    `variable`, `heading`, `selector`, `key`, `stage`, `anchor`) plus the
    capture-name mapping `init?(captureName:)`. It mirrors
    `SyntaxTokenKind(captureName:)`'s role with **one deliberate inversion**: that
    initializer *degrades* an unknown capture to `.plain`, because mis-coloring a
    token is harmless, whereas this one is **failable and strict** — a symbol
    carries a jump target and a place in the completion list, so an unrecognized
    capture is *dropped* rather than filed under a plausible-looking kind. A typo
    in a query therefore costs one missing declaration instead of injecting a
    garbage entry into go-to-definition. A leading `@`/`.` is ignored and the
    `definition.` prefix (`SymbolKind.capturePrefix`, so the queries' `@definition.
    type` reads distinctly from the auxiliary `@container`) is optional, but
    matching is otherwise **exact**: there is no longest-prefix fallback, since a
    partially-recognized capture (`definition.type.foo`) is a query bug and the
    only safe reading of a query bug is "emit no symbol".
    `SymbolQueryTests` asserts by *set equality* that the captures the shipped
    queries emit are exactly the ones this enum resolves, so a query that gains a
    capture fails `swift test` until a case is added. `Symbol` is `name`, `kind`,
    `range`, `fileURL`, `containerName` and a 1-based `line`. Two things about it
    are load-bearing: `range` is the range of the **name node**, not of the whole
    declaration, so a jump lands the caret on the identifier itself rather than on
    a `func` keyword or an attribute list above it — which is exactly what a Find
    in Files match range is, and the reason both can share `EditorRevealState`;
    and offsets are UTF-16 (`NSRange`), the editor's own coordinate space, so
    nothing converts between the extractor and the text view. `line` is
    precomputed at extraction time because the picker shows it and recomputing it
    later would mean re-reading the file the symbol came from. `qualifiedName`
    (`Container.name`, or the bare name) is the label both platforms' pickers lead
    a row with.
  - `SymbolIndex.swift` — the project's symbol store: per-file symbol arrays plus
    the two buckets everything above asks questions through, *"who is named X"*
    (go-to-definition) and *"who starts with X"* (autocompletion). A **value
    type** on purpose: `SymbolIndexModel` mutates a working copy off the main
    actor and publishes snapshots, so the reader — `SymbolIntelligenceProvider`,
    on the main actor, between keystrokes — never sees a half-applied chunk and
    never needs a lock. Files are keyed by `CanonicalPath.canonical(_:).path`, the
    same key `ProjectSearchModel.bufferKey(for:)` and `WorkspaceModel
    .fileID(forURL:)` use, so the traversal's spelling of a file and a tab opened
    through a symlink (or `/private/tmp` vs `/tmp`) collapse to one entry instead
    of double-indexing it and offering every symbol in it twice. `replace(fileURL:
    symbols:)` is idempotent and *total* for that file (it purges the previous
    contribution from both buckets first), which is what makes re-indexing as
    often as the debounce fires safe; `remove(fileKey:)` erases a file from both,
    and `remove(fileURL:)` is the convenience that derives the key first. Removal
    by *key* is the one a caller holding it must use, because removal is exactly
    where re-deriving is unsafe: `fileKey(for:)` resolves symlinks against the
    file system, so a file that has just been deleted can canonicalize to a
    different string than the entry was stored under — and the purge would then
    quietly match nothing, leaving a vanished file's symbols answering
    go-to-definition until the folder was reopened. `SymbolIndexModel.removeFiles`
    therefore keeps the keys (`indexedFiles` is a `Set<String>`, not a key→URL
    map) and passes them straight back, which also drops a syscall per removed
    file from the main actor. `replace(fileKey:symbols:)` is the *insert* side of
    the same rule, and `replace(fileURL:symbols:)` now delegates to it: the walk
    already resolved every candidate's key off-main (that is what `IndexCandidate`
    carries it for), so re-deriving it in `apply` would put one symlink resolution
    per indexed file back on the main actor — and could file the entry under a key
    that `indexedFiles`/`stamps`/`bufferSourced` never recorded, which no later
    `remove(fileKey:)` would find.
    That purge sweeps **one bucket per distinct name and initial**, not one per
    symbol: `prefixBucket[initial]` holds the entries of the whole project for
    that letter, so a per-symbol loop would rescan it end to end (and, bound with
    `var` while the dictionary still referenced it, copy it) once per symbol in
    the file — hundreds of full-bucket passes on every debounce tick while the
    user types in a large file, for a set of buckets a couple of dozen wide. The
    removals go through `dict[key]?.removeAll`, which mutates the stored array in
    place rather than copying it.
    The prefix bucket is keyed by **lowercased first character only** — a
    deliberately coarse index: it turns a prefix query into a scan of one small
    slice instead of the whole project, at one array per distinct initial letter
    rather than one per distinct prefix (what a trie would cost, for a lookup
    already fast enough at this granularity). The bucket character is the first
    character *of the lowercased string* rather than the lowercased first
    character, so a multi-scalar lowercasing (`İ`) leaves both sides of the
    comparison agreeing. `symbols(named:)` is case-**sensitive** (`Foo` and `foo`
    are two declarations in every language indexed, and offering both would open a
    picker where the jump was unambiguous); `symbols(withPrefix:limit:)` is
    case-**in**sensitive (typing `arr` should still surface `ArrayBuffer`) and caps
    *after* ordering, so the cap is deterministic rather than "whichever matches
    were stored first". An empty name or prefix yields nothing. `indexedFileCount`
    counts a walked file that yielded no symbols too: it *is* indexed, just empty.
    **This type ranks nothing** — lookups return a stable, documented order (file
    key, then position in the file, then name), and every relevance decision
    belongs to the provider. Keeping the two apart is what lets the ranking rules
    be pinned by tests that build three symbols instead of a project, and what
    lets a phase-2 LSP provider reuse the ranking over a different source of
    truth.
  - `ProjectFileWalk.swift` — the **one** traversal of an opened folder, shared by
    Find in Files and the symbol index. Both ask the same question ("which files
    under this root are worth reading?") and both must answer it identically: a
    file Find in Files refuses to search because a `.gitignore` excludes it must
    not turn up as a go-to-definition target either. `collectFiles(root:
    maskPatterns:fileService:)`, `matchesMask(name:patterns:)` and
    `relativePath(of:under:)` were lifted **verbatim** out of `ProjectSearchModel`
    (doc comments included) and that model now calls through, so the gitignore
    stack, the `.git`/`.DS_Store` filter, the symlink rules on both sides and the
    deterministic root-first ordering are unchanged — the full reasoning behind
    each of those still lives in the `ProjectSearchModel` entry in
    `core-search.md`, which is where it was written. The alternative, the index
    reaching into another model's `nonisolated static`, is what this file avoids.
    Pure, Foundation-only and free of actor isolation: every entry point is a
    plain `static func` over an injected `FileServicing`, called from the private
    serial queues both models dispatch their I/O to. The symbol index passes an
    empty `maskPatterns` (every file); binary and oversize files are *not* this
    type's business — they are skipped by the callers'
    `FileServicing.readTextIfNotBinary`, where the byte cap lives. `relativePath`
    accepts a `nil` root (only the definition picker can be asked about one) and
    degrades to the bare file name, as it already did for a URL outside the root.
    **`collectFilesIfReadable` is the same walk with the root's failure kept
    distinguishable.** An unreadable directory *below* the root is skipped on
    purpose — one permission-denied folder must not blank the whole result list —
    and only the files it would have contributed are lost. An unreadable *root*
    loses everything, so folding it into `[]` makes "this project has no files"
    and "ask again later" the same answer, and a caller that acts on the wrong one
    acts destructively: `SymbolIndexModel.refresh` removes every indexed file the
    walk stopped producing, so one transient failure (a revoked iOS security
    scope, an unmounted volume, a permissions blip mid-checkout) would empty the
    index outright — silently, because an unindexed project looks exactly like one
    that declares nothing, and for the rest of the session, because nothing else
    schedules a refresh (iOS has no watcher at all). `collectFilesIfReadable`
    therefore answers `nil` for that one case and `collectFiles` stays the
    `?? []` wrapper Find in Files keeps using, whose empty result is visible on
    screen and re-run by the next keystroke.
  - `SymbolIndexModel.swift` — observable state for the project-wide index: the
    traversal, the extraction of every file worth indexing, and the bookkeeping
    that keeps the index honest while the project changes under it. Modelled
    directly on `ProjectSearchModel` — `@MainActor ObservableObject`, I/O injected
    behind `FileServicing`, branching decisions as pure `nonisolated static`
    helpers, off-main work on a private serial queue, overlapping operations
    ordered by a generation token captured *synchronously* before any `Task` hop —
    and it walks through the very same `ProjectFileWalk.collectFiles`.
    **It is a reader.** It never writes to disk, never mutates a buffer, and
    therefore never takes the autosave/revert gate every git-mutating operation
    raises: a refresh landing in the middle of a revert or a branch switch costs at
    worst one entry extracted mid-rewrite, which the next refresh corrects. Nothing
    here may grow a `beginRevert()`/`suspend()` bracket — a reader that took the
    writer gate would serialize the editor behind a background walk for no
    benefit. **The extractor seam is synchronous, and there is no extractor
    actor** (plan Decision 7): `extractSymbols: @Sendable (String, SyntaxLanguage,
    URL) -> [Symbol]` is the app layer's tree-sitter bridge — the only reason Core
    stays Foundation-only — and it is *never awaited*. It is called exclusively
    from inside this model's own `offMain { … }` blocks, so the private serial
    queue is the single serialization authority and the `offMain(whole chunk) →
    re-check generation` shape is preserved exactly as project search writes it.
    An async closure awaited *per file* was considered and rejected on two
    grounds: it would have to be lifted out of the chunk body, turning one hop and
    one generation re-check per chunk into one of each per file, and it would add a
    second ordering authority on top of a queue that already provides one. Thread
    safety is the `MinimapTokenizer.computeModel` arrangement this repository
    already relies on — each call builds its own parser and cursor and only *reads*
    the lock-guarded grammar caches (`SymbolExtractor` states that contract). Note
    the scope: this is the *indexing* seam only. The user-facing
    `CodeIntelligenceProviding` protocol stays async, and that is the seam a
    phase-2 language server slots into. The default extractor is "no symbols", so
    Core's own tests and any caller without a tree-sitter layer get an index that
    is empty rather than absent. **What is indexed:** `indexableLanguage(
    forFileName:)` gates each candidate *before any read*, so a file whose name
    resolves to no `SyntaxLanguage`, or to one in `unindexableLanguages`
    (`.gitignore` — it declares nothing a jump could land on), costs one name
    lookup instead of a read and a parse. That set lives here rather than on
    `SyntaxLanguage` because it is a statement about the shipped *query
    resources*, and Core cannot read the app bundle: `SymbolQueryTests` asserts by
    set equality that `Resources/Queries` holds a query for every language except
    these, so a language added to the enum fails `swift test` until either its
    query exists or it is listed here — it can never silently index to nothing.
    **Lifecycle.** `prepareForFolderChange(root:)` bumps the generation and clears
    the index *synchronously*, in the same main-actor turn as the folder open and
    before any `Task` (the `ProjectSearchModel.prepareForSearch` /
    `LocalChangesModel` precedent), so an in-flight walk finds itself superseded
    when it resumes; the index is cleared because a definition that opens a file
    from the folder the user just left is worse than no definition at all. A repeat
    call for the same folder is a no-op, and `currentRequestGeneration` lets a
    caller pin a deferred rebuild. `rebuild(root:request:)` rejects a superseded
    request before doing any work (the `LocalChangesModel.refresh(root:
    requestGeneration:)` rule — unstructured `Task`s are not guaranteed to start in
    creation order, so two rapid folder opens could otherwise settle on the older
    one), clears index/stamps/buffer marks up front, then walks off-main and
    extracts in chunks of 32 (project search's `chunkSize`, for the same reason:
    small enough that the index is usable while the walk continues, large enough
    that the per-hop cost is negligible next to the parses), **republishing after
    every chunk** and re-checking the generation after every await. The queue runs
    at `.utility` rather than project search's `.userInitiated`: nobody is waiting
    on a screenful of results, and a background index must not compete with the
    editor for cores while the user types. `refresh(root:)` is the **stamp-gated**
    re-walk an FSEvents burst runs (debounced by `SymbolIndexController`): the
    watcher reports only "something under the root changed", so the alternative is
    re-parsing the whole project, which an `npm i` would then trigger every second.
    Three rules, in order of how often they fire — a file whose `(byteCount,
    modificationDate)` stamp equals the recorded one is skipped without being read;
    a **buffer-sourced** file is skipped entirely (the buffer is ahead of disk);
    and a file the walk no longer produces (deleted, renamed, newly gitignored) is
    removed by set difference, unless a buffer owns it, since an open tab may
    legitimately name a file outside the walked root and removing its symbols would
    break completion in the very file being typed in. A `nil` stamp
    means "always re-extract" (see `FileStamp` in `core-workspace.md`), so a stub
    service degrades to correct-but-slower rather than to a stale index.
    That third rule is only sound when the walk actually *looked*, which is why
    the traversal runs through `ProjectFileWalk.collectFilesIfReadable` and the
    removal pass is skipped entirely when the root could not be listed: a walk that
    produced nothing because it could not see is not a project that emptied, and
    removing what it failed to see would drop every non-buffer entry on one
    transient failure — permanently, since nothing schedules the corrective
    refresh. Keeping the entries costs at worst stale symbols the next successful
    refresh replaces. The buffer half of the walk still runs in that case (an open
    tab is readable however the root is faring), and the *next* readable refresh
    removes what really went away.
    **A refresh naming a root the model is not currently indexing is discarded**,
    and that *is* its stale-token guard — which is why it takes no `request:`
    counterpart to `rebuild`'s: the root is the token. A refresh is only ever
    issued for a root someone is already watching, and a folder change always
    issues its own `prepareForFolderChange` + `rebuild` in the switching turn, so a
    refresh for another root can only be a callback from the folder the user just
    left. Treating it as a folder change and rebuilding for it (what this used to
    do) would clear the index the switch just filled and repopulate it from the
    *previous* project, leaving every definition and completion answering out of a
    folder that is no longer open with nothing to correct it until the next folder
    change. That is reachable, not theoretical: the FSEvents callback hops to the
    main actor with `DispatchQueue.main.async`, so a batch enqueued while
    `openFolder` runs is delivered *after* it — with the previous root captured —
    however promptly the watcher was re-subscribed
    (`testARefreshForTheFolderTheUserJustLeftIsDiscarded`).
    **Two generation tokens, not one.** `generation` orders *walks* and is bumped
    by `prepareForFolderChange`, `rebuild` and `refresh`; `rootGeneration` is
    bumped only when the opened folder actually changes. The buffer re-index below
    is gated on `rootGeneration` precisely because gating it on `generation`
    conflates "the user left the project" with "a refresh started": an FSEvents
    burst (a save, a build, an `npm i`) landing mid-parse would then discard the
    very edits being typed, and nothing retries them until the next keystroke.
    **Buffers.** `reindexBuffer(url:text:language:)` re-extracts one file from live
    editor text — the extraction inside a one-file `offMain` block with a
    `rootGeneration` re-check after it, so a folder switch landing mid-parse
    discards the
    result — and marks the entry buffer-sourced; an unindexable language is dropped
    before any work. **A tab close is two calls, and both are needed.**
    `forgetBuffer(url:)` gives up the *ownership*: the symbols stay for the moment
    (they are still the best knowledge available, and the file on disk is usually
    identical anyway), but the entry's owner changes and its stamp is cleared, so
    any later refresh re-extracts from disk unconditionally rather than concluding
    from an unchanged stamp that a buffer's version is current.
    `reindexFromDisk(url:)` is what actually performs the hand-off, and it exists
    because "any later refresh" is not something a close may rely on: a tab close
    writes nothing, so no watcher fires, and with no folder open — a standalone
    file, `lastRoot == nil` — `refresh` is unreachable by construction, its `root
    == lastRoot` guard rejecting every call. Without it, a buffer whose changes
    were *discarded*, or whose last keystrokes the close cancelled out of the
    debounce, would go on answering go-to-definition and completion with text that
    exists nowhere, for the rest of the session. It re-reads the one file through
    `extractChunk` itself (no known stamp, no buffers), so a hand-off reads, gates
    and classifies exactly as a refresh does; a file that can no longer be read —
    deleted, or closed *because* it was deleted — is dropped from the index by
    `dropIfUnowned`, the single-file `removeFiles`, since with neither a buffer nor
    a file behind it there is nothing left the entry could be true of. One file per
    close rather than a project walk per close is the whole reason it is a separate
    entry point. It is ordered against the buffer path exactly as `reindexBuffer`
    is — `rootGeneration` re-check, cancellation honoured after the read — and both
    of its branches stand aside for a file that has become buffer-sourced again
    (a tab reopened while the read was in flight), so the editor's text always
    outranks the disk copy.
    **Cancellation is honoured after the parse**, and that half is load-bearing
    rather than a courtesy: `SymbolIndexController.noteBufferClosed` cancels the
    in-flight re-index and then calls `forgetBuffer`, and without the re-check a
    parse already past its debounce would resume afterwards and re-insert the file
    into `bufferSourced` — pinning the index to text no editor holds, so every
    later refresh would skip that file and `removeFiles` would go on exempting it,
    leaving a since-deleted file answering go-to-definition until the folder was
    reopened. The check and `apply` are one main-actor run with no suspension
    between them, so a cancellation lands either before it (nothing is published)
    or after the entry was applied (and `forgetBuffer` then clears it).
    **The walk has the same window, and `buffersClosedDuringWalk` is its guard.**
    A chunk carries `.walkBuffer` outcomes for the tabs that were open when the
    walk read the workspace; if one of those closes while the chunk is in flight,
    `forgetBuffer` runs first (clearing a mark that was never set) and `apply`
    lands afterwards — re-creating exactly the frozen entry the cancellation check
    above exists to prevent, with no cancellation anywhere to catch it, since the
    walk is not the tab's task. `forgetBuffer` therefore records the key in a set
    that `walk` clears at its start, and `apply` **drops** a `.walkBuffer` outcome
    whose key is in it — text and ownership alike, not merely demoting it to
    `.disk`. Demoting would fix the ownership and still republish the closed
    buffer's text, and that is not a harmless staleness: the same close runs
    `reindexFromDisk`, whose one-file read can finish *first* (the walk's chunk is
    already extracted and only waiting on the main actor), so the outcome would
    land on top of the correct disk symbols with nothing scheduled to correct it —
    a close writes nothing, so no watcher fires
    (`testAWalkChunkDoesNotUndoTheDiskHandOffOfATabClosedMidWalk`). Dropping is
    safe for exactly that reason: the hand-off a close guarantees re-derives the
    entry from disk in whichever order the two land, so no walk snapshot of a
    closed buffer is ever the best text anyone has. A stale key in that set could
    at worst cost one extra extraction — the safe direction.
    **Buffer-over-disk precedence** is the rule that makes the two sources safe to
    mix, and it turns on *where the text came from*, which is why `FileOutcome`
    carries a three-case `OutcomeSource` rather than a `fromBuffer` flag: `.disk`,
    `.walkBuffer` (the walk-time snapshot of an open tab) and `.liveBuffer` (a
    `reindexBuffer` of what the editor holds now). Both buffer cases take
    ownership of the entry, but only the live one is *current* — the walk reads
    the workspace once, before it starts, so a chunk's buffer text can be several
    keystrokes old by the time it is applied. `apply` therefore rejects **every
    walk outcome**, disk-read and walk-snapshot alike, for a file already marked
    buffer-sourced; only a `.liveBuffer` outcome may overwrite one. A flag that
    said merely "from a buffer" would have let a chunk republish walk-time text
    over the keystrokes a `reindexBuffer` had just published — and, the file being
    buffer-owned afterwards, no refresh would ever have corrected it.
    `extractChunk` additionally checks `bufferSourced` **before** consulting the
    buffer snapshot, so a file the buffer already owns is skipped entirely,
    without being read or re-parsed, which is what the refresh rules above
    promise; a file with buffer text that is *not* yet buffer-sourced is the first
    walk to see that tab, so its text is indexed and takes ownership. That check
    is a cheap short-circuit, not the guarantee: the snapshot it reads is taken
    per *chunk*, so it closes the window only
    up to the chunk's dispatch and `apply`'s guard is what covers a
    `reindexBuffer` landing while the chunk runs. The **stamp** snapshot, by
    contrast, is taken once for the whole walk: a candidate appears in exactly one
    chunk and `apply` writes stamps only for chunks already processed, so a
    per-chunk copy would decide nothing differently — while a second reference to
    the dictionary held across `apply`'s mutation forces a full copy of it per
    chunk, i.e. O(files²/32) element copies on the main actor for the pass whose
    whole purpose is to avoid work. `apply` and `removeFiles` avoid that same
    trap on `index` itself by assembling the batch in a local and writing it back
    **once**: `@Published` exposes only a get/set pair, so an `index.replace(…)`
    per file would be a get-mutate-set that copies all of `SymbolIndex`'s
    dictionaries every iteration — and would republish the whole index per file
    rather than the per-chunk republication documented above.
    **A walk also indexes the open tabs it cannot reach.** `bufferCandidates`
    appends one candidate per open buffer the traversal did not produce — a tab on
    a file under the folder the user just left, or one this project's `.gitignore`
    excludes — under the same language gate and the same canonical key, ordered by
    key so a walk stays deterministic. Without it, `prepareForFolderChange`
    (which clears the buffer marks along with the index) would leave the file the
    user is *looking at* answering nothing until they switched tabs and back,
    since the walk is the only thing that runs on a folder switch. These
    candidates carry no on-disk existence claim: `extractChunk` finds each of them
    in the buffer snapshot and never reaches its disk branch. It is the same rule
    `removeFiles` already states from the other side — such a tab is exempt from
    removal.
    A file that throws
    on read produces no outcome at all (it keeps whatever the index holds and is
    retried next refresh), while one the service declines to hand over — binary or
    oversize — is indexed as *empty*, so it is not re-read on every refresh only to
    be rejected again. The `openBuffers` snapshot is read **once** on the main
    actor per walk and re-keyed canonically off-main
    (`bufferIndex`/`SymbolIndex.fileKey`), exactly as project search does, so no
    per-file symlink resolution lands on the main thread. The model owns the
    `provider` (lazily, with `[weak self]` closures so it can outlive a torn-down
    model and answer "nothing" instead of resurrecting it) so the app holds exactly
    one object rather than a separately-constructed provider that would capture a
    stale index value.
  - `IdentifierScanner.swift` — the editor's single definition of *"what is an
    identifier"*, shared by the three questions code intelligence asks of raw
    text: which word was ⌘-clicked (`identifier(in:at:)`), which partial word is
    being typed (`completionPrefixRange(in:at:)`), and which words this buffer
    contains (`words(in:limit:)`). Pure and Foundation-only over an `NSString` and
    UTF-16 offsets like every other editor engine (`DuplicateEngine`,
    `BracketMatchEngine`, `AutoPairEngine`), so a range it returns can be handed
    straight to the text view — and to `EditorRevealState`. **One boundary rule**
    serves all three, deliberately, so the word a click resolves, the prefix a
    keystroke completes and the words the harvester offers can never disagree: an
    identifier starts with a Unicode letter or `_`, continues with letters, digits,
    combining marks and `_`, and a run whose leading scalars cannot *start* a name
    is trimmed from the left (so `9foo` yields `foo` and a bare `123` yields
    nothing). Classification is Unicode-based (`CharacterSet.letters` /
    `.alphanumerics`, which covers Letter/Mark/Number, so a decomposed accent keeps
    its name in one piece) rather than ASCII, so `имя`, `número` and `変数` are
    single identifiers — though the **ASCII range short-circuits to two range
    compares** before either set is consulted, which is a pure optimization pinned
    by an exhaustive 0..<128 equivalence test: `CharacterSet.letters` and
    `.alphanumerics` are computed properties that *build* a bridged set per access,
    and `words(in:limit:)` asks the question once per scalar of the whole buffer on
    every completion tick (its `limit` counts *distinct* words, so it does not
    bound the scan), which is the same reason `BracketDepthScanner` reads in bulk;
    the two Unicode sets are held in `static let`s for everything else. Scanning is
    surrogate-pair aware, so a non-BMP scalar is
    never cut in half, and a caret sitting on a trailing surrogate half (only
    reachable through a stale offset) is moved back onto the boundary rather than
    becoming a dead spot inside a name. `identifier(in:at:)` probes twice — the
    identifier *containing* the offset, then the one *ending* at it — and the
    second probe is what makes the keyboard path work: after typing a name the
    caret sits just past its last character (`Worker|`), and ⌃⌘J must resolve that
    word rather than nothing, while a click, which lands *on* a character, is
    answered by the first. `completionPrefixRange(in:at:)` takes the **left side
    only**, because completion replaces what has been typed and leaves the rest of
    the line alone: `foo.bar|` completes `bar` and `$FOO|` completes `FOO`. That is
    exactly what `NSTextView.rangeForUserCompletion` must report, and returning the
    whole dotted expression there is the classic reason a popup offers nothing. It
    returns an **empty range at the caret**, never `nil`, so callers can hand it to
    AppKit unconditionally. `words(in:limit:)` is the graceful-degradation half of
    completion — a language with no `symbols.scm`, or a file the index has not
    reached yet, still offers the buffer's own words, which is what every editor's
    "dumb" completion does. It de-duplicates, keeps first-occurrence order (a `Set`
    would reshuffle between runs and leave the ranking's tie-breaks as the only
    thing keeping the list stable) and **caps distinct words**, stopping as soon as
    the cap is reached: a minified bundle or a generated data file is one buffer
    with hundreds of thousands of tokens, and an uncapped harvest would allocate
    that set on every debounce tick.
  - `CodeIntelligence.swift` — the seam between the editor surfaces and whatever
    knows about code: the two questions, their requests and their results, in one
    file, so the platform layers depend on *this* and never on the index and
    swapping the implementation is a construction change rather than a UI rewrite.
    `CodeIntelligenceProviding` is **async by design even though phase 1 answers
    synchronously**: an LSP provider must await a socket, and retrofitting async
    later would touch every call site in both platform layers — exactly the churn
    this seam exists to prevent. The cost today is one suspension point on a value
    the provider already has, which is also what lets the macOS completion
    controller compute candidates *before* AppKit's synchronous delegate asks for
    them. `DefinitionRequest` carries the identifier (already resolved by
    `IdentifierScanner`, so the provider never re-parses text), the file it was
    asked from, and the caret `offset` — unused by phase 1's name-based lookup and
    carried anyway, because it is the one piece of context an LSP
    `textDocument/definition` cannot be built without. `DefinitionCandidate` pairs
    the `Symbol` with a **precomputed** `relativePath` (the project root is the
    provider's knowledge, not the text view's) and exposes `displayLabel`
    (`Container.name — src/Worker.swift:42`), so the macOS `NSMenu` and the iOS
    dialog show the same string and neither view decides what a candidate reads as.
    `CompletionRequest` carries the prefix, the file, and the buffer's **live
    text** — passed in rather than read from a model, because the buffer being
    typed in is always ahead of the index (the re-index debounce has not fired
    yet) and a name typed thirty seconds ago must still be completable.
    `CompletionItem` is deliberately just a string plus two ranking facts (`kind`,
    `isFromCurrentFile`): AppKit's stock popup shows strings only (plan Decision 2)
    and the iOS strip shows buttons, so the extra fields exist to make the
    *provider's* ranking testable and to give a later, richer popup its data
    without changing the seam.
  - `SymbolIntelligenceProvider.swift` — the index-backed
    `CodeIntelligenceProviding` implementation and the home of **every ranking
    rule**, all of it `static` and pure over an index value, with the instance
    methods a thin async shell — so each tie-break is pinned by a test that builds
    three symbols instead of a project. The index is read through a **closure
    rather than stored**: the model publishes a fresh snapshot after every chunk,
    and a provider holding a copy would answer from the state the folder was
    opened in. **The read is `@MainActor`; the ranking is not.** The two protocol
    methods are `nonisolated async`, so (SE-0338) their bodies run on the
    cooperative pool rather than on the caller's actor — while the closures reach
    into a `@MainActor` model that republishes `index` after every chunk. Taking
    both reads in one `MainActor.run` is what keeps a completion request typed
    *during* an index build from walking the model's dictionaries while `apply`
    mutates them; one hop rather than two so a request cannot straddle a chunk
    publication and pair one walk's index with the next one's root. Only the read
    hops — `SymbolIndex` is a value type, so the ranking pass that follows walks a
    private copy off-main and nothing can change under it. (The closures are
    therefore typed `@Sendable @MainActor`, which costs nothing: a `@MainActor`
    class is itself `Sendable`.)
    **Definitions** are an exact, case-sensitive name match ordered current-file
    first, then by relative path, line, offset and name — current file first
    because a name declared in the file being read is nearly always the one meant,
    and the rest path-then-line so a rebuilt index cannot reshuffle the menu under
    the user's cursor. An empty identifier yields nothing: it is what
    `IdentifierScanner` reports for a click on whitespace, and "no name" must beep
    rather than open an empty menu. They are capped *after* ranking at
    `defaultDefinitionLimit` 50, so what survives is the best of them rather than
    an arbitrary slice: both surfaces build one UI element per candidate — an
    `NSMenuItem` in `DefinitionPicker`, a `confirmationDialog` button on iOS — and
    neither bounds the list itself, while the index is fed by more than tidy
    declarations (`symbols.scm` also captures Markdown headings, top-level
    JSON/YAML keys and CSS selectors), so a docs-heavy or multi-package project
    really can hold hundreds of declarations of `name`, `id` or `Overview`. Past a
    screenful the menu has stopped disambiguating anything, and on iPhone a
    several-hundred-action sheet is a hang. **Completions** merge the index's prefix
    matches with the buffer's harvested words and rank by (1) case-sensitive prefix
    match before merely case-insensitive — the user's capitalization is a signal,
    so `arr` still surfaces `ArrayBuffer` but never above `arrayCount`; (2) current
    file before the rest of the project; (3) a known symbol before a bare word — a
    declaration is a fact, a word is a guess, and the guess is only there so
    query-less languages still complete; (4) shorter name — the shortest completion
    of a prefix is the most common intent and the cheapest to correct; (5)
    lexicographic, then kind, purely so two equally-ranked entries cannot swap
    places between keystrokes. The typed token itself is dropped (completing `foo`
    to `foo` inserts nothing and hides a real candidate behind it), duplicates
    collapse to their best-ranked entry (so a name both declared here and present
    in the buffer appears once, as the symbol), and the result is capped —
    `defaultCompletionLimit` 30, because beyond a couple of dozen entries a list
    stops being a choice and the next keystroke narrows it anyway. The index is
    asked for **more than the cap** (`candidateLimit`) precisely because it orders
    by storage position: capping there would hand the ranking an arbitrary slice
    and the best candidate could be missing entirely. A generous multiple still is
    not a guarantee, and the one place that matters is the current file — storage
    order is *by file key*, so in a project with more prefix matches than the
    pre-cap every match in a path sorting after the cut is invisible, and whether
    the file being typed in is one of them comes down to how its path happens to
    sort. Ranking rule 2 would then fail exactly where it is most load-bearing, so
    that file's own symbols are asked for separately (`symbols(inFile:)`, one
    dictionary hit) and prefix-filtered in; the de-duplication above collapses the
    overlap with whatever the bucket already returned. Ranking facts are
    precomputed per candidate (`Ranked`) so the comparator does no string work
    across `O(n log n)` calls, and canonical file keys are memoized
    (`FileKeyCache`) because `SymbolIndex.fileKey(for:)` resolves symlinks — i.e.
    touches the file system — and a completion pass compares hundreds of candidates
    from a handful of files on every debounce tick. `defaultBufferWordLimit` 5 000
    is high enough that no hand-written file is truncated and low enough that a
    minified bundle cannot turn a tick into a large allocation. Paths come from
    `ProjectFileWalk.relativePath(of:under:)`, the very helper Find in Files labels
    its result groups with, so a definition row and a search row cannot spell one
    file two ways.

## The query resources, and the runtime half `swift test` cannot reach

The language knowledge itself lives outside Core, in
`Resources/Queries/<language>/symbols.scm` — one query per `SyntaxLanguage` except
`.gitignore`, wired into the bundle as a **folder reference** in `project.yml`
(like `Resources/Licenses`, so adding a language's query needs no `xcodegen
generate`) and loaded by `SymbolQueryCatalog`. One convention, authored once and
used by all eleven files: **the captured node is always the name node**, the
capture name is the kind (`@definition.type`, `@definition.function`, …), and an
optional `@container` capture *in the same match* supplies the enclosing type's
name — which is why `SymbolExtractor` walks matches rather than captures.

A broken symbols query is quieter than a broken highlight query: an unhighlighted
file is visibly plain text, whereas an unindexed file looks exactly like a file
that declares nothing. Both tree-sitter failure modes are in play — an unknown
*node* name fails `ts_query_new`, so the whole language indexes zero symbols,
while a mistyped *capture* name compiles and is then (correctly) dropped by
`SymbolKind(captureName:)`, losing that one declaration. Neither shows up in a
build, in CI, or in a screenshot. `SymbolQueryTests` closes the static half,
Foundation-only through `#filePath`: set equality of query directories against
`SyntaxLanguage.allCases` (with `.gitignore`'s absence asserted deliberately),
every query non-empty, set equality of emitted capture names against what
`SymbolKind` resolves, each kind capture resolving to *its own* kind, the single
auxiliary capture (`@_attribute`, the HTML `id` filter) pinned by its own set
equality, the dotenv query validated against the vendored grammar's own
`node-types.json` under the matching `named` flag, and — for the nine remote
grammars, whose sources are not in the repository — the node-name and
anonymous-literal sets pinned by hand, the way `SyntaxTokenKindTests` pins the
dockerfile captures, so a grammar update that renames a node fails with the
language named.

**What stays manual**, because verifying it needs SwiftTreeSitter and Core
deliberately does not link it: that each query actually *compiles* against its
grammar, and that every element of a real fixture is captured. Two things cover
it. `SymbolQueryCatalog` trips an `assertionFailure` naming the language in DEBUG
builds, so a developer running a debug build hits a missing or uncompilable query
on the first file of that type. And on **every grammar update** — a pin bump in
`project.yml`, or a re-vendored package under `Vendor/` — open a file of that
language in a debug build and confirm its declarations answer ⌃⌘J and appear in
the completion list, exactly as `Vendor/TreeSitterGitignore/VENDORED.md` requires
for the highlight query it holds. A pinned-node-name test failing is the *cheap*
signal; this is the one that catches a node whose meaning changed while its name
did not.
