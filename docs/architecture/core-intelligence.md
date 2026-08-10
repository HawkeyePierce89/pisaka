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
  - `FuzzyMatch.swift` — the completion matcher: *"does this candidate answer
    what the user typed, and how well"*, as **one** subsequence walk shared by
    every candidate source (indexed symbols, language keywords, harvested buffer
    words), so a fuzzy hit means the same thing wherever it comes from and the
    ranking can compare across sources at all. Pure, Foundation-only, and
    working on `Character`s (grapheme clusters) rather than UTF-16 units —
    unlike every other editor engine in Core, deliberately: this type never
    reports a range back to a text view, it only compares two names and produces
    a sort key, so working in characters is what keeps a decomposed accent or an
    emoji in an identifier from being cut in half by the walk.
    **The file owns the one word-boundary rule**, and it lives here rather than
    in `SymbolIndex` because two very different things depend on it agreeing with
    itself: the index's lookup bucket is *keyed* by the boundary initials, and
    the ranking *prefers* a match whose characters land on them. A name's word
    starts are index 0 always (including a leading `_`, so `_private` is
    reachable by typing the underscore as well as by typing `p`); a camelCase
    hump — any uppercase not preceded by an uppercase (`arrayBuffer` → `B`) plus
    the *last* uppercase of an uppercase run followed by a lowercase
    (`URLSession` → `S`, not `R`/`L`); the character after a `_`/`-` separator
    (`snake_case` → `c`); and either side of a digit/letter transition
    (`base64Encoder` → `6`, `E`). `wordBoundaryInitials(of:)` returns them
    deduplicated, lowercased, in name order and capped at `maximumInitials` 8 —
    a generated or minified file can hold identifiers with dozens of humps and
    every initial is an entry appended to a project-wide bucket, while eight
    covers every hand-written name (`NSAttributedStringKey` has four); the kept
    eight are the *first* eight, so the cap is deterministic rather than
    dictionary-ordered, and `quality(of:matching:)` applies the **same** cap when
    it decides whether a query may anchor on a boundary — the two go through one
    private `boundaryInitials(of:boundaries:)` so they cannot drift apart, which
    is the whole reason the index's one-bucket lookup is exhaustive rather than
    merely usually right. Lowercasing is per-character and stays one character
    (`String.lowercased()` can widen `İ` to `i` + U+0307, which would
    desynchronize the lowercased array from the boundary flags computed over the
    original — and it agrees with how `SymbolIndex` derived its bucket key before
    this file existed).
    **A fuzzy match must *start* on a word boundary.** `buf` matches
    `ArrayBuffer` (the hump), `rray` does not. That is not a performance accident
    of the index's bucket — it is stated in the matcher precisely so a keyword and
    a buffer word, neither of which is looked up through a bucket, obey exactly
    the same rule as a symbol. It is also what keeps the candidate set
    intelligible: without it a three-letter query matches an appreciable fraction
    of every project's identifiers, and the popup stops being a ranking problem
    and becomes a lottery. It is the documented **limit** of the feature, stated
    in the README: the *first* typed character has to hit a boundary.
    `quality(of:matching:)` answers `nil` in exactly three cases and no others —
    an empty query, not a case-insensitive subsequence, or a first character that
    occurs only off a boundary — and otherwise a `Quality`, the ranking's first
    key, ordered best-first on `tier` (0 case-sensitive prefix, 1
    case-insensitive prefix, 2 fuzzy), then `offBoundary` (how many matched
    characters missed a boundary: `aBu` → `ArrayBuffer` hits two humps and reads
    as intentional, the same three characters scattered mid-name do not), then
    `span` (tighter over looser), then `start` (earlier over later). **For a
    prefix match the three fuzzy sub-keys are pinned to zero rather than
    computed**, and that is what keeps the pre-existing ranking intact
    bit-for-bit: with a literal prefix the whole key collapses to the two-valued
    case rank the provider ranked on before fuzzy matching existed, so every
    candidate that tied then still ties now and the later tie-breaks decide
    exactly as before. The walk itself is greedy, left-to-right and deliberately
    deterministic rather than optimal — for each query character it takes the next
    *boundary* occurrence if there is one and the next occurrence otherwise, and
    retries taking the leftmost throughout if that pass runs out of candidate.
    Two passes rather than a search because the candidate set is scanned once per
    keystroke: the pair answers "is this a subsequence at all" exactly, and only
    the *quality* of a pathological name (`abC_bx` against `abc`, where the
    boundary-preferring pass has to back off) depends on which pass succeeded.
    **Answering "no" must not cost an allocation**, and that is a stated
    requirement rather than a tuning detail: this function is asked about every
    harvested buffer word (up to 5 000), every keyword and — in member position —
    every member the index holds, on every completion tick, and rejection is by
    far the common answer. So the two-pass walk and the four arrays it needs sit
    behind two gates that allocate nothing: a first-character comparison before
    the case-insensitive prefix test's `lowercased()` pair, and
    `isSubsequence(_:of:)`, an in-place walk of the *necessary* half of what the
    positional pass decides (that one additionally demands a boundary anchor, so
    it can only reject more). Without them a rejection cost the same as a match —
    measured at ~100× the literal-prefix test the matcher replaced, over a
    5 000-word buffer, paid on the ordinary per-keystroke path and not only after
    a dot. The capped initials list is likewise deduplicated by a linear scan of
    at most eight characters rather than by a `Set`, which would allocate a hash
    table per candidate *and* per symbol on every re-index.
    `matches(_:query:)` is the same call without the key, for the filtering call
    sites that do not rank — `SymbolIndex`'s lookups and the iOS insertion guard.
  - `SymbolIndex.swift` — the project's symbol store: per-file symbol arrays plus
    the two buckets everything above asks questions through, *"who is named X"*
    (go-to-definition) and *"who could the typed text be reaching for"*
    (autocompletion, literal prefix or fuzzy alike). A **value
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
    symbol: `initialBucket[initial]` holds the entries of the whole project for
    that letter, so a per-symbol loop would rescan it end to end (and, bound with
    `var` while the dictionary still referenced it, copy it) once per symbol in
    the file — hundreds of full-bucket passes on every debounce tick while the
    user types in a large file, for a set of buckets a couple of dozen wide. The
    removals go through `dict[key]?.removeAll`, which mutates the stored array in
    place rather than copying it. The initials swept are collected with the very
    function `replace` filed them under
    (`FuzzyMatch.wordBoundaryInitials(of:)`), so a name that contributed several
    keys (`ArrayBuffer` → `a`, `b`) is swept out of *all* of them: deriving them
    any other way here would leave a hump-keyed entry behind and let a deleted
    symbol go on answering completion.
    The completion bucket is keyed by **every lowercased word-boundary initial**
    of a name (`ArrayBuffer` is filed under both `a` and `b`) — still a
    deliberately coarse index: it turns a completion query into a scan of one
    small slice instead of the whole project, at one array per distinct initial
    letter rather than one per distinct prefix (what a trie would cost, for a
    lookup already fast enough at this granularity). Filing under every boundary
    rather than only the first character is what makes **fuzzy lookup affordable
    without a new structure**: `symbols(matching:limit:)` still reads exactly
    *one* bucket — the one its first typed character names — and that bucket
    provably holds every candidate the matcher could accept, because
    `FuzzyMatch` requires the first matched character to land on a boundary
    **and on one of the first `maximumInitials` of them**. That second half is
    what makes "provably" true rather than nearly true: the cap is enforced
    inside `quality(of:matching:)`, not only in `wordBoundaryInitials(of:)`, so
    a name with nine or more distinct boundary initials cannot be a match the
    bucket has no entry for — otherwise the same query would find such a name as
    a keyword or a harvested buffer word and silently *not* as the identical
    indexed symbol, a hole indistinguishable from "not indexed yet". The
    price is bounded and paid in both directions: `FuzzyMatch.maximumInitials`
    caps a name at 8 keys and hand-written code averages two or three, so both
    the stored entries and the entries scanned per keystroke grow by that same
    small factor (~2–3×) rather than by the size of the project. The bucket
    character for a *query* is the first character *of the lowercased string*
    rather than the lowercased first character, so a multi-scalar lowercasing
    (`İ`) leaves both sides of the lookup agreeing — the same rule
    `wordBoundaryInitials` applies when it files a name.
    `symbols(named:)` is case-**sensitive** (`Foo` and `foo`
    are two declarations in every language indexed, and offering both would open a
    picker where the jump was unambiguous); `symbols(matching:limit:)` is the
    superset that replaced the old prefix lookup rather than a different rule —
    `arr` still finds `ArrayBuffer`, and now `aBu` and `buf` do too — and caps
    *after* ordering, so the cap is deterministic rather than "whichever matches
    were stored first". **The cap fills from the literal-prefix matches first**,
    which is a truncation rule and not a ranking (the returned array is still in
    the one documented order, and the provider still ranks it): fuzzy matching
    widened the matched set by one to two orders of magnitude for a short query
    while the caller's `limit` — a multiple of what the popup shows, not of the
    project — did not, so a cut made purely in file-key order would decide *which*
    matches the ranking ever sees by how paths happen to sort. A `setUp` in
    `zzTests/` is an exact prefix match for `se` that the pre-fuzzy lookup always
    offered and that a path-ordered cut would silently drop behind a few hundred
    unrelated `s…e…` names. The provider cannot repair this afterwards — by the
    time it sees the result the evicted candidate is simply absent — so it is
    fixed at the cut, at the cost of one extra partition of a set already in hand.
    An empty name or query yields nothing. `indexedFileCount`
    counts a walked file that yielded no symbols too: it *is* indexed, just empty.
    **Member lookup adds no index structure of its own**, deliberately: a
    *non-empty* member query reads the very same `initialBucket`
    `symbols(matching:limit:)` does, by the same argument (the matcher anchors the
    first matched character on a word boundary and every boundary is a bucket key,
    so that one bucket already holds every member that could match), with only the
    `.method`/`.property`/`.constant`-with-a-container filter applied on top, and
    it takes the same split cut through the one shared `cut(prefixes:fuzzy:limit:)`
    — the rule is a property of "fuzzy matching widened the set while the cap did
    not", which is as true of the member path as of its sibling, and two copies of
    it were free to drift, as they had. That
    routing is what keeps the member path off a project-wide scan while the user
    types, which is the case that would otherwise walk every symbol in the project
    once per keystroke and never reach its cap. The linear pass over the per-file
    storage (files by key, symbols in extraction order) is left to the **empty**
    query — the bare typed `.`, which has no first character to look a bucket up
    by — and is bounded from the other end instead: with no query every member
    counts, so it stops after seeing `limit` of them, which in a project large
    enough for the scan to hurt happens almost immediately.
    `members(inContainer:)` is the same kind filter restricted to one
    container name, case-**sensitively** (a type differing only in case is a
    different type, the `symbols(named:)` reasoning) and **uncapped**, because one
    type's member list is small by construction and truncating it is exactly what
    would make the receiver's own members — the ones the provider ranks first —
    go missing. A by-container bucket was rejected: it would cost memory on every
    keystroke to speed up a pass that compares a container name per symbol without
    running the matcher at all, and that runs only when the receiver spells a
    declared type. **An empty query matches every member** here and nowhere else in
    the type — that is the typed-dot case, where the user has committed to a
    member access and typed nothing, so the candidate set is bounded by the kind
    filter rather than by the text and the cap is what keeps it finite; that
    single difference is the whole reason it is a separate method. A
    container-less symbol is excluded even when its kind qualifies: a `.constant`
    at file scope is not reachable through a dot, and offering it after one is a
    worse answer than offering nothing. `declaresType(named:)` is the receiver
    heuristic's one question, and it asks specifically about a `.type` rather than
    about anything with that name — a *function* called `worker` says nothing
    about what `worker.` will offer, and promoting an unrelated container that
    happens to share the spelling would be worse than promoting nothing.
    **This type ranks nothing** — that holds for the fuzzy and member lookups
    too: they ask `FuzzyMatch` whether a candidate matches *at all* and throw the
    quality away, returning the stable documented order (file key, then position
    in the file, then name). Every relevance decision — current file first,
    case-sensitive before case-insensitive, the receiver's own container first,
    symbols before keywords before bare words —
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
    `rootGeneration` is also published as `currentRootGeneration`, for a reader
    *outside* the model: a definition surface pins it synchronously before its
    `Task` hop and drops the answer if it moved. That guard exists because neither
    provider's own staleness gate can reach past its own `return` — clearing the
    index here, and `LSPWorkspace.stillHolds(_:)` there, both stop an answer being
    *computed* for a folder the user has left, but the candidates cross one more
    main-actor hop before a surface opens them, and `openFolder` runs in a single
    synchronous turn that can land inside it. The published token is the *project*
    one, not `currentRequestGeneration`, for the reason above worn the other way
    round: a jump pinned to the request token would cancel itself whenever a
    refresh happened to start while the user waited for the answer
    (`testRootGenerationMovesOnlyWhenTheFolderActuallyChanges`).
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
    at worst cost one extra extraction — the safe direction — which is why the set
    is only emptied by the two resets that end its usefulness: the start of a walk,
    and `clearIndex` (the folder-change reset, and the one that matters with **no**
    folder open, where `refresh` is unreachable by construction and the set would
    otherwise accumulate one key per tab close for the whole session).
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
    identifier"*, shared by the four questions code intelligence asks of raw
    text: which word was ⌘-clicked (`identifier(in:at:)`), which partial word is
    being typed (`completionPrefixRange(in:at:)`), whether the caret sits after a
    member-access dot (`memberContext(in:at:)`), and which words this buffer
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
    AppKit unconditionally.
    `memberContext(in:at:)` answers the fourth question — is this caret in a
    *member position*, and if so what does the completion replace and what does
    the dot hang off — and it **extends the one boundary rule rather than
    inventing a second**: the member prefix is the same maximal run of
    continuation scalars `completionPrefixRange(in:at:)` takes (`MemberContext
    .prefixRange` is literally that call's answer, so the two paths can never
    insert at different places), and the receiver is the same run a ⌘-click would
    resolve. Accepted before the dot: an identifier (`worker.|`, receiver
    `worker`; `a.b.c|` therefore reports `b`) and the closing brackets `)`, `]`,
    `}` (`f().|`, `items[0].|`), whose expression yields *some* value while its
    spelling names no type — hence `receiver == nil` there, and no container
    promotion in the ranking. Rejected, all `nil`: a dot after whitespace
    (`foo .|`), after `(` or `,`, after another dot (`..|`), at the start of the
    file, and after a bare number — `1.|` is caught by the trim rule (a run of
    digits is not an identifier), so typing a decimal point never opens a member
    list. The same trim rule rejects a member prefix that does not **begin** where
    the dot ends, and that rejection is explicit rather than incidental — the
    guard is `prefixRange.location == start`, i.e. the trimmed identifier and the
    raw run after the dot start at the same offset. Two shapes fail it, both from
    digits. A run that is *all* digits (`pair.0|`, `ubuntu20.04|`) trims to
    nothing, so `prefixRange` would be the empty range **after** the digits —
    which the provider reads as "the dot was just typed" and answers with every
    member in the project, and which both editors insert at, turning `pair.0|`
    into `pair.0doWork`. A run that merely *starts* with digits
    (`ubuntu20.04lts|`, `v1.0beta|`) trims partway in, so a completion would
    replace `lts` three characters inside a token that is not a member access at
    all, rewriting the version to `ubuntu20.04doWork`. Swift tuple access hits the
    first shape on every keystroke. A leading `_` *is* an identifier start, so
    `worker._x|` is unaffected. Deleting the dot returns `nil` and the ordinary
    path resumes.
    **String and comment context is deliberately not detected**: a dot inside a
    string literal or a comment *does* report a member position, exactly as
    identifier completion already offers candidates while typing inside one —
    knowing better needs the syntax tree, which this Foundation-only scanner does
    not have, and it is the *provider's* rule (a bare dot offers members only,
    never buffer words) that keeps the resulting popup quiet.
    `words(in:limit:)` is the graceful-degradation half of
    completion — a language with no `symbols.scm`, or a file the index has not
    reached yet, still offers the buffer's own words, which is what every editor's
    "dumb" completion does. It de-duplicates, keeps first-occurrence order (a `Set`
    would reshuffle between runs and leave the ranking's tie-breaks as the only
    thing keeping the list stable) and **caps distinct words**, stopping as soon as
    the cap is reached: a minified bundle or a generated data file is one buffer
    with hundreds of thousands of tokens, and an uncapped harvest would allocate
    that set on every debounce tick.
  - `LanguageKeywords.swift` — completion's **third candidate source**: the
    reserved vocabulary of the language being typed in. Static per-language lists
    rather than anything derived from the parse tree, because a keyword is spelled
    the same in every file of a language, never moves, and is exactly what a
    project's *first* file — the one that declares nothing yet and whose buffer
    holds no words to harvest — has to offer, so the cheapest possible source is
    also the right one: no index, no read, no parse, just a filter over a sorted
    array behind the same `FuzzyMatch` every other source goes through. The lists
    are **curated, not generated** — the tokens a person types while writing the
    language (declaration and statement keywords, the literal spellings
    `true`/`nil`/`None`, the widely-used contextual keywords) and nothing more.
    They are deliberately not a standard-library index: `print`, `console` and
    `String` are declarations, and a project that uses them has them in its buffer
    or (for its own code) in its symbol index already. Go's list is what sharpens
    that rule into the one sentence the others were following implicitly: **an
    identifier belongs here when no source file can ever declare it.** That is why
    Go reaches past the 25 reserved words into the whole universe block — its 22
    predeclared types, 4 constants and 18 built-in functions, 69 entries in all —
    and why the reach is not a contradiction of the paragraph above even though it
    contains `print` and `println`. A universe-block name is declared in no file
    anywhere, so neither the symbol index nor the harvested buffer words can ever
    offer it, and leaving it out would make `len`, `error` and `nil`
    uncompletable in a Go project forever; `fmt.Println` *is* a declaration in a
    package and stays out, along with every other qualified name.
    `LanguageKeywordsTests` pins the Go list by **set equality** against those four
    families spelled out separately, because a subset check is what a hand edit
    slips through — dropping `close` or `float32` from 69 entries leaves every
    shape invariant true and silently loses a built-in nothing else can offer.
    Rust's list is Go's rule applied a second time, and the three lines it draws
    are what the rule looks like when it has to say *no*: 56 entries — the 38
    strict keywords of the 2021 edition, the **17 primitive type names**
    (`bool char str`, `f32 f64`, the ten sized integers, `isize`/`usize`), and the
    one contextual keyword `union`. The primitives are in because they are declared
    in no crate anywhere, not even `core`, so neither the symbol index nor the
    buffer-word harvest can ever offer them. **Reserved-but-unusable words are
    out** (`abstract`, `become`, `box`, `do`, `final`, `gen`, `macro`, `override`,
    `priv`, `try`, `typeof`, `unsized`, `virtual`, `yield`): they are reserved
    precisely so that no program may use them, so completing to one produces a
    compile error and nothing else — the inverse of the rule's purpose.
    **`union` is in and `macro_rules` is out**: `union` is contextual, following
    the precedent Python's soft keywords `match`/`case` already set, while the
    token a person actually types is `macro_rules!` and a bare identifier that
    completes to half of it is worse than offering nothing (the harvest picks it
    up the moment a file declares one). **The prelude stays out** — `Option`,
    `Result`, `Some`, `None`, `Ok`, `Err`, `String`, `Vec`, `Box` — for the reason
    `fmt.Println` stayed out of Go's: they are declarations in a crate, so
    rust-analyzer or the index is what should offer them. `f16`/`f128` are excluded
    as unstable and `_` per Go's precedent (punctuation typed directly), and `Self`
    sorts first because Swift orders uppercase before lowercase, exactly as
    Python's list opens with `False`/`None`/`True`. Pinned by set equality against
    the three families, with the count at 56 so a duplicate fails and with
    `abstract`/`virtual`/`yield`/`Option`/`Some`/`Vec`/`macro_rules` asserted
    absent, so each line above is a test rather than a comment. TypeScript is *composed*
    from JavaScript plus a type-level list and re-sorted, so there is one list to
    maintain instead of two that drift and the composition cannot break the sorted
    invariant. **A keyword is never a definition**: `SymbolIntelligenceProvider`'s
    go-to-definition path does not consult these lists, because a keyword has no
    declaration site to jump to — the two features sharing a provider is exactly
    why that is pinned by a test rather than left to convention.
    `languagesWithoutKeywords` records the absence as a *stated decision*, the way
    `SymbolIndexModel.unindexableLanguages` does, and for the same enforcement
    reason: `LanguageKeywordsTests` asserts by **set equality** against
    `SyntaxLanguage.allCases` that every case either has a non-empty list or is
    named there, so a language added to the enum fails `swift test` until someone
    decides which it is and can never silently complete to nothing. The reasons,
    by family — **JSON, YAML, dotenv** are data, not code: their grammar is
    punctuation, the only "keywords" (`true`/`false`/`null`, YAML's scalar
    spellings) are shorter than the popup they would open, and what a data file
    actually wants completed is the keys already in the buffer, which the
    harvested-word source offers; **Markdown** is prose with no reserved words at
    all; **gitignore** is patterns, with no vocabulary to complete (which is also
    why it is the one language the index skips); **HTML and CSS** have an open
    vocabulary a flat list would answer badly — element, attribute and property
    names are only meaningful *in position*, and several hundred names with no
    positional filter is noise rather than a spelling aid, so doing it properly is
    a structural completion belonging to whatever phase takes on typed context.
    The suite also pins that each list is sorted, duplicate-free and made of
    *insertable* tokens — every entry survives
    `IdentifierScanner.completionPrefixRange` unchanged, so a keyword the ranking
    offers can actually be typed and completed.
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
    `textDocument/definition` cannot be built without — plus the `text` phase 2a
    added: the buffer's **live** text, which an LSP provider must give the server
    before it can ask anything about `offset` (D2, `core-lsp.md` — document sync is
    request-driven, so the text travels with the question). It is defaulted to `""`
    so no call site written before phase 2a breaks, which makes a *forgotten* call
    site the real hazard, since an empty buffer clamps every position to `0:0` and
    answers confidently wrong; the LSP provider therefore treats "empty text,
    non-zero offset" as **unanswerable** and falls back rather than clamping, while
    the tree-sitter provider ignores the field entirely.
    `DefinitionCandidate` **stores what it displays and navigates by, not a
    `Symbol`** (D8). An LSP definition answer is a *location* — a file, a range and
    nothing else, with no declaration kind, because the server was asked "where", not
    "what" — and wrapping a `Symbol` would force one of two bad options: invent a
    synthetic `SymbolKind` case, which `SymbolQueryTests` compares by set equality
    against the shipped queries and would fail, or lie with an existing one. So
    `kind` is optional and the rest of the fields are flat (`name`, `containerName`,
    `fileURL`, `range`, `line`, `relativePath`), `init(symbol:relativePath:)` is
    retained so every *construction* site — the tree-sitter provider's included — is
    unchanged, and `displayLabel` (`Container.name — src/Worker.swift:42`) is
    byte-identical to what it produced before, so the macOS `NSMenu` and the iOS
    dialog show the same string and neither view decides what a candidate reads as.
    `relativePath` stays **precomputed** (the project root is the provider's
    knowledge, not the text view's), and `isOutsideProjectRoot` is precomputed for
    the same reason and one more: it decides *where the jump lands*, since D3 opens
    an out-of-root target in a separate read-only window instead of a tab. It is
    always `false` on the tree-sitter path — the index only ever walks the opened
    folder, so everything it can name is inside it.
    `CompletionRequest` carries the prefix, the file, and the buffer's **live
    text** — passed in rather than read from a model, because the buffer being
    typed in is always ahead of the index (the re-index debounce has not fired
    yet) and a name typed thirty seconds ago must still be completable — plus the
    two fields phase 1.5 added, `language` and `member`. `language` exists for the
    keyword source and nothing else, and `nil` means **no keywords at all** rather
    than some default language's: offering Swift's `guard` while typing in a file
    the editor could not classify is a worse answer than offering nothing (a
    language that *has* no list reaches the same outcome through
    `LanguageKeywords.languagesWithoutKeywords`). `member` is
    `IdentifierScanner.memberContext(in:at:)`'s answer, carried on the request
    rather than re-derived by the provider because the provider is given a prefix
    and a buffer, not a caret: the editor layer is the only place that knows where
    the caret is, and it already has to ask the question to decide whether to
    bypass its minimum-length trigger gate. Non-`nil` is also the one state in
    which `prefix` may legitimately be empty. Both are **defaulted to `nil`**, so
    every construction site that predates member completion — and every test that
    only cares about ranking — compiles and means exactly what it meant before.
    Note what grew: the *request*, not `CodeIntelligenceProviding`. The protocol
    still has the same two methods with the same shapes, so a phase-2 LSP provider
    implements the same contract and simply maps these two fields onto a
    completion-context parameter instead of onto an index lookup — which is the
    whole point of putting them here rather than in a second method. Phase 2a added
    a third defaulted field, `offset`: the caret the request was made from, without
    which a completion request has **no position in it at all** — and a position is
    the whole of what `textDocument/completion` asks about, since a prefix cannot be
    located in a buffer that may contain it a hundred times. `nil` is read by the LSP
    provider as **unanswerable, never as 0** (D2's guard applied to the other request
    kind); the tree-sitter provider ignores it, matching names rather than places, so
    a call site that predates phase 2a keeps meaning exactly what it meant and only
    the LSP answer is given up. Both editor call sites pass the caret they already
    have, so only a future one could trip the guard.
    `CompletionItem` is a string plus two ranking facts (`kind`,
    `isFromCurrentFile`): AppKit's stock popup shows strings only (plan Decision 2)
    and the iOS strip shows buttons, so the extra fields exist to make the
    *provider's* ranking testable and to give a later, richer popup its data
    without changing the seam. Phase 2a added two more, both defaulted so the
    tree-sitter provider and both iOS surfaces are untouched. `edits` is every buffer
    edit committing the item performs, in buffer (UTF-16) coordinates — the primary
    replacement plus any auto-import (D4) — and is **empty for a tree-sitter item**,
    which is only `text` replacing the typed prefix and so is inserted by AppKit's
    own machinery; a non-empty list is the editor's signal to apply the item itself
    through `CompletionEditPlan`, in one undo group. `resolveHandle` is an opaque
    token naming an item the server deferred to `completionItem/resolve`, opaque on
    purpose: the seam must not leak an `LSPCompletionItem` (Core's LSP types stay
    behind the provider), and the editor never interprets the number — it hands it
    straight back to the provider that issued it, through the protocol's third
    method. `resolveEdits(for:)` is **defaulted to "nothing to add"** because it is
    meaningful for exactly one implementation; an item the issuing provider does not
    recognise — a handle from a superseded list, or an item from a different provider
    — answers `[]`, which the caller reads as "insert the plain text and nothing
    else". The two providers that compose these answers, and the rules they follow,
    are in `core-lsp.md`.
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
    several-hundred-action sheet is a hang. **Only the index is consulted** for a
    definition — not the buffer's words, and not `LanguageKeywords`, which the
    completion path below *does* read: a keyword has no declaration site, so a
    `guard` under the caret must beep rather than open a picker, and the two
    features sharing this type is exactly why that is pinned by a test instead of
    left to convention. **Completions** merge three sources — the index's matches,
    the language's keywords and the buffer's harvested words — and rank by
    (1) **match quality**, `FuzzyMatch.Quality`, which is itself ordered
    case-sensitive prefix, then case-insensitive prefix, then fuzzy, and within
    fuzzy prefers a match landing on word boundaries, then a tighter span, then an
    earlier start: typing `arr` still surfaces `ArrayBuffer` but never above
    `arrayCount`, and a literal prefix always beats a scattered subsequence
    however short the scattered candidate is. For a literal prefix that key
    *collapses* to exactly the two-valued case rank this method ranked on before
    fuzzy matching existed, so every order that held then holds now — which is why
    the pre-existing ranking tests pass unedited;
    (2) current file before the rest of the project; (3) the **source**: a known
    symbol, then a language keyword, then a bare harvested word — a declaration is
    a fact, a keyword is a certainty about the language that says nothing about
    *this* project, and a word is a guess that only exists so query-less languages
    still complete; (4) shorter name — the shortest completion
    of a prefix is the most common intent and the cheapest to correct; (5)
    lexicographic, then kind, purely so two equally-ranked entries cannot swap
    places between keystrokes. **Keywords carry `isFromCurrentFile: true`**, so
    rule 2 puts them level with harvested words and rule 3 is what separates the
    two: a keyword belongs to the language of the file being typed in and is
    exactly as local as a word lifted out of it. Where rules 2 and 3 genuinely
    conflict — a keyword against a symbol declared in *another* file — the
    current-file rule wins, precisely as it already does between a harvested word
    and a project symbol; the keyword tests isolate rule 3 by putting everything
    in one file, the way `testSymbolsOutrankBareBufferWords` already does. A
    keyword is a `CompletionItem` with `kind == nil` and its source rank lives
    inside the private `Ranked` rather than on the seam, so `SymbolKind` — pinned
    by `SymbolQueryTests` against the shipped queries — gains no case for
    something no query emits and the public type gains no field nobody renders.
    The typed token itself is dropped (completing `foo`
    to `foo` inserts nothing and hides a real candidate behind it), duplicates
    collapse to their best-ranked entry (so a name both declared here and present
    in the buffer appears once, as the symbol — and `guard`, which a Swift buffer
    both contains and reserves, appears once as the keyword), and the result is
    capped — `defaultCompletionLimit` 30, because beyond a couple of dozen entries
    a list stops being a choice and the next keystroke narrows it anyway. The index
    is asked for **more than the cap** (`candidateLimit`) precisely because it
    orders by storage position: capping there would hand the ranking an arbitrary
    slice and the best candidate could be missing entirely. A generous multiple
    still is not a guarantee, and the one place that matters is the current file —
    storage order is *by file key*, so in a project with more matches than the
    pre-cap every match in a path sorting after the cut is invisible, and whether
    the file being typed in is one of them comes down to how its path happens to
    sort. Ranking rule 2 would then fail exactly where it is most load-bearing, so
    that file's own symbols are asked for separately (`symbols(inFile:)`, one
    dictionary hit) and re-matched in; the de-duplication above collapses the
    overlap with whatever the bucket already returned. Fuzzy matching *widens* the
    set the pre-cap slices, so that mitigation matters more now, not less: the cut
    falls earlier in file-key order and the current file is likelier to sit past
    it. The file-scoped lookup is unfiltered, so its symbols are re-matched rather
    than trusted wholesale — it is the matcher, applied to every source alike,
    that decides what is a candidate. The *other* half of that widening — a
    literal prefix match in some third file evicted by unrelated fuzzy matches
    from files that sort earlier — cannot be repaired here at all, because by the
    time this sees the result the evicted candidate is simply absent; it is
    handled at the cut instead, by `symbols(matching:limit:)` filling the cap from
    the prefix matches first.
    **Member mode is a branch, not a filter**, taken whenever `request.member` is
    non-`nil`, and it changes three things while reordering nothing. *The prefix
    may be empty*: a typed `.` is the user committing to a member access before
    typing anything, so "nothing typed, nothing to complete" — right everywhere
    else, and still enforced for a request with no member context — would answer
    the one unambiguous request with nothing; the candidate set is bounded by the
    member kinds instead (`SymbolIndex.members(matching:limit:)`, whose empty
    query matches every member). *The candidates are members only*, and **keywords
    are not offered at all**, for the same reason a type or a free function is
    not: no language lets `guard` follow a dot. *The receiver's own container
    ranks first* — one key **above** match quality and therefore above every other
    key, but only when the receiver spells a type the project declares
    (`index.declaresType(named:)`). That is a name-based heuristic and not type
    inference: `worker.` cannot be resolved without knowing what `worker` was
    assigned, while `Worker.` names the container outright, and a receiver naming a
    *function* promotes nothing. Below that one key every ordinary tie-break still
    applies unchanged, and on an ordinary request the key is constant 0, so the
    ranking outside member mode is bit-for-bit what it was before member completion
    existed. The promoted container's members are collected separately and
    uncapped so the pre-cap cannot drop the very members the request is about, and
    the **current file's** members are collected separately too
    (`SymbolIndex.members(inFile:)`) for exactly the reason `symbols(inFile:)` is
    added on the ordinary path: the pre-cap slices the project in file-key order,
    so without it the file being typed in can contribute nothing at all and
    ranking rule 2 fails where it matters most. The promoted-container rescue does
    not cover that case — it fires only when the receiver spells a declared type,
    while `worker.`, the common case, promotes nothing. Both extra lookups are
    re-matched like every other source, so being unfiltered cannot widen what
    counts as a candidate, and `assemble` collapses the overlap. The *third* way
    the pre-cap can lose a candidate — a literal prefix match evicted by unrelated
    fuzzy matches from earlier-sorting files — is not repairable here either, and
    is handled at the cut for the same reason and by the same shared rule the
    ordinary path uses: `members(matching:limit:)` fills the cap from the prefix
    matches first. Neither rescue above covers it, since a member of an
    un-promoted receiver declared in some third file is reached by neither.
    `memberCandidateLimit` 400 is a flat number rather than a multiple of the
    visible cap the way `candidateLimit(for:)` is, because that one slices a set
    the *query* already narrowed while a bare dot has no query at all — a few
    hundred members is far more than the popup can show and far less than a large
    project declares. That cap is also what bounds the bare-dot lookup's linear
    pass, which stops as soon as it has seen that many members; every *other*
    member request — `worker.n`, `worker.na`, i.e. every subsequent completion
    tick for as long as the caret sits after the dot — carries a query and is
    answered from the initial bucket instead of by a walk, which is what keeps the
    per-keystroke cost of member mode comparable to ordinary completion rather
    than proportional to the size of the project. The one exception is the
    promoted-container rescue: `SymbolIndex.members(inContainer:)` *is* a project
    walk, because a container name is not a bucket key and the answer has to be
    complete rather than capped. It fires only when the receiver spells a declared
    type (`Worker.n`, not `worker.n`) and does no matching — a kind test and a
    string compare per symbol — so it is left as a walk; a container bucket filed
    in `replace` and swept in `purge` is what would remove it if it ever measured. **The buffer-word fallback requires a non-empty member
    prefix**: words are offered only when the user has typed at least one character
    after the dot *and* no member matched it — the case where the project simply
    has not indexed the receiver's type and a word is better than an empty popup.
    With an empty prefix there is no fallback at all, because an empty query
    matches *every* word in the buffer and the scanner deliberately does not know
    about strings or comments, so a dot inside a JSON value, a URL in a comment or
    a decimal point would otherwise open a list of unrelated words exactly where
    the dot is least likely to be a member access; nothing at all is the honest
    answer there. A *single* matching member suppresses the fallback entirely, so
    words never dilute a real member list. Ranking facts are
    precomputed per candidate (`Ranked`) so the comparator does no string work
    across `O(n log n)` calls — with `sourceRank` *passed in* rather than derived
    from `item.kind`, since two of the three sources produce a kind-less item (a
    keyword and a harvested word are both "just a string") and the source is the
    caller's knowledge anyway — and canonical file keys are memoized
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
used by all thirteen files: **the captured node is always the name node**, the
capture name is the kind (`@definition.type`, `@definition.function`, …), and an
optional `@container` capture *in the same match* supplies the enclosing type's
name — which is why `SymbolExtractor` walks matches rather than captures.

A second convention runs alongside it: **what is indexed is what someone
navigates to**, so every query that would otherwise match at arbitrary depth is
anchored to the file's top level. Swift anchors to `(source_file …)`, Python to
`(module …)`, JSON to `(document (object …))`, YAML to the top-level
`block_mapping`, and JavaScript/TypeScript anchor their `const`/`let`/`var`
bindings to `(program …)` plus the `(export_statement …)` wrapper an exported
binding nests under. Left unanchored, the binding patterns match every loop
counter and every intermediate inside every function, and common names (`config`,
`result`, `handler`) then fill the go-to-definition menu to its cap with locals,
pushing the real declaration out. Functions and classes are deliberately *not*
anchored in JS/TS: a nested function or class is a declaration worth finding,
while a block-scoped binding is not.

The HTML query filters attributes with `#match? @_attribute "^[iI][dD]$"` rather
than `#eq? … "id"` because **HTML attribute names are case-insensitive** — `ID=`
and `Id=` name the same attribute — while the anchors keep `data-id` and `idx`
out. `SwiftTreeSitter` evaluates `match?` with `firstMatch`, so the anchoring is
load-bearing rather than decorative.

A broken symbols query is quieter than a broken highlight query: an unhighlighted
file is visibly plain text, whereas an unindexed file looks exactly like a file
that declares nothing. All three tree-sitter failure modes are in play — an
unknown *node* name fails `ts_query_new` with `TSQueryErrorNodeType`, an unknown
*field* name fails it just as fatally with `TSQueryErrorField` (either way the
whole language indexes zero symbols), while a mistyped *capture* name compiles
and is then (correctly) dropped by `SymbolKind(captureName:)`, losing that one
declaration. None shows up in a build, in CI, or in a screenshot.
`SymbolQueryTests` closes the static half, Foundation-only through `#filePath`:
set equality of query directories against `SyntaxLanguage.allCases` (with
`.gitignore`'s absence asserted deliberately), every query non-empty, set
equality of emitted capture names against what `SymbolKind` resolves, each kind
capture resolving to *its own* kind, the single auxiliary capture
(`@_attribute`, the HTML `id` filter) pinned by its own set equality, the dotenv
query validated against the vendored grammar's own `node-types.json` under the
matching `named` flag *and* against its declared field table, and — for the
twelve remote grammars, whose sources are not in the repository — the node-name,
anonymous-literal and field-name sets pinned by hand, the way
`SyntaxTokenKindTests` pins the dockerfile captures, so a grammar update that
renames a node or a field fails with the language named.

**Fields are checked as a third kind, not folded into the node names**, for the
same reason the named and anonymous sets are read apart: they are validated by a
different table, and almost every pattern here hangs off one (`name:`, `body:`,
`key:`, `heading_content:`, `left:`, `value:`, `as:`). A `heading_content:`
mistyped to `heading_kontent:` compiles nowhere and indexes no Markdown heading,
yet leaves every node-name and capture-name assertion byte-identical — so
without the field set the widest hole in the static checks sat under the queries
that need them most. `ParsedQuery` recognizes a field as the only *bare*
identifier a query may contain (node names are parenthesized, captures follow an
`@`), by the `:` that follows it.

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

### `Resources/Queries/go/symbols.scm` — the four decisions and the confirmed captures

Go's query (grammar `tree-sitter/tree-sitter-go`, pinned `0.25.0`, revision
`1547678a…`) follows the shared convention and makes four decisions worth reading
as decisions rather than as accidents.

**The pointer star is stripped by the grammar, not by us.** `*` is an anonymous
token inside `pointer_type`, so capturing the `type_identifier` *inside* it yields
`Worker`, not `*Worker` — which is the spelling the type itself is indexed under
and therefore the only one `SymbolIntelligenceProvider`'s receiver promotion
(`index.declaresType(named:)`) can look up. That is why the four receiver forms
(value, pointer, generic, pointer-to-generic) are four separate patterns:
`[(type_identifier) (pointer_type …)] @container` would capture the *`pointer_type`
node* in the pointer case and put the star back, and `*Worker` matches no declared
type.

**Interface methods are methods with the interface as their container**, so a
member completion after a value of interface type lists them. The node is
`method_elem`; it was `method_spec` in grammars before 0.25, which is exactly the
rename `SymbolQueryTests`' hand-pinned node set exists to surface on a pin bump.
An *embedded* interface (`fmt.Formatter`) is a `type_elem` and is deliberately not
matched — it declares nothing new.

**Consts and vars are anchored to `source_file`**, the JavaScript/TypeScript
reasoning verbatim: unanchored, `var_spec` matches every `var` inside every
function body and the index fills with locals. `var_spec_list` needs a second
pattern because a grouped `var ( … )` block nests one level deeper; a grouped
`const ( … )` does not. Types are *not* anchored, matching the JS/TS treatment of
nested classes — a `type` declared inside a function body is a declaration worth
finding (and so are its fields, which is why the struct and interface patterns
navigate from `type_spec` rather than from `type_declaration`), and is rare enough
that it cannot flood a picker the way a loop counter can. `function_declaration`
*is* anchored, and that costs nothing: Go has no nested function declarations at
all — a function inside a function is a `func_literal` bound to a variable, which
this query does not match either way — so the anchor is a statement of intent
rather than a filter that ever fires.

**The package clause is not indexed.** `package foo` repeats in every file of a
directory, so indexing it would put N identical `foo` symbols in the picker for a
name nobody jumps to.

One further asymmetry is the grammar's, and the runtime check is what found it:
the const pattern navigates by **position** (`(const_spec (identifier) @…)`) where
the var patterns navigate by field (`var_spec name: (identifier)`). `const_spec`'s
`name` field is declared to hold the separating `,` tokens as well as the
identifiers, and a field whose run of children is interrupted by an anonymous
token yields only its first named child to `name: (identifier)` — so
`const A, B = 1, 2` indexed `A` alone. Every direct `identifier` child of a
`const_spec` *is* a declared name (the initializers live one level down, inside
`value: (expression_list)`), so dropping the field is exact rather than merely
broader. `var_spec`'s `name` field holds identifiers only, and keeps the field.
The grammar declares exactly two such comma-carrying fields, `const_spec.name` and
`type_case.type`, and the query touches only the first.

The runtime half of the recipe was run with `tree-sitter query` 0.25.10 against
the resolved checkout (Core cannot link SwiftTreeSitter, so this is a throwaway
CLI run, not a test), over a fixture exercising every pattern. Confirmed
element by element:

| fixture declaration | capture | text |
|---|---|---|
| `type Worker struct { … }` | `@definition.type` | `Worker` |
| `Name string` | `@container` + `@definition.property` | `Worker` + `Name` |
| `count int` | `@container` + `@definition.property` | `Worker` + `count` |
| `X, Y int` | two `@definition.property` matches | `X`, `Y` |
| `Inner struct{ Z int }` | `@definition.property` | `Inner` (not `Z` — the nested anonymous struct is not a named `type_spec`) |
| `*Base` (embedded) | — | not captured; an embedded field declares no new name |
| `type Stringer interface { … }` | `@definition.type` | `Stringer` |
| `String() string` | `@container` + `@definition.method` | `Stringer` + `String` |
| `fmt.Formatter` (embedded) | — | not captured (`type_elem`) |
| `type Alias = Worker` | `@definition.type` | `Alias` |
| `type Pair[K, V] struct { Key K }` | `@definition.type`, then `@container` + `@definition.property` | `Pair`, `Pair` + `Key` |
| `const Version = "1.0"` | `@definition.constant` | `Version` |
| `const First, Second = 1, 2` | two `@definition.constant` matches | `First`, `Second` |
| `const ( Alpha = iota; Beta )` | two `@definition.constant` matches | `Alpha`, `Beta` |
| `var Registry = …` | `@definition.variable` | `Registry` |
| `var ( Global int; another string )` | two `@definition.variable` matches | `Global`, `another` |
| `func New(…) *Worker` | `@definition.function` | `New` |
| `local := 1` / `var localVar int` / `const localConst = 2` (inside `New`) | — | **not captured** — the `source_file` anchor at work |
| `func (w Worker) String()` | `@container` + `@definition.method` | `Worker` + `String` |
| `func (w *Worker) Increment()` | `@container` + `@definition.method` | `Worker` (no star) + `Increment` |
| `func (p Pair[K, V]) Get()` | `@container` + `@definition.method` | `Pair` + `Get` |
| `func (p *Pair[K, V]) Set(k K)` | `@container` + `@definition.method` | `Pair` + `Set` |
| `package demo` | — | not captured, by decision |

All twelve patterns fired, so none is dead. The remaining manual step is the one
the recipe requires of every grammar update: open a `.go` file in a DEBUG build
and confirm its declarations answer ⌃⌘J — the CLI proves the query compiles and
captures, not that `SymbolQueryCatalog` found and loaded it.

### `Resources/Queries/rust/symbols.scm` — the six decisions and the confirmed captures

Rust's query (grammar `tree-sitter/tree-sitter-rust`, pinned `0.24.2`, revision
`77a3747266…`) follows the shared convention and makes six decisions.

**`impl Trait for Type` files under `Type`, not under `Trait`.** One rule covers
both impl forms and needs no second pattern, because `type:` is the *self* type
in `impl Type` and in `impl Trait for Type` alike — the trait sits in the
`trait:` field, which this query never navigates. It is also the rule the rest of
the stack already assumes: `SymbolIntelligenceProvider`'s member branch answers
"`.` after a value of type `Worker`" by looking up members whose container is
`Worker`, so a `fmt` filed under `Display` would never surface there.

**Generics are stripped by stepping through `generic_type`, not by editing the
text** — Go's pointer-star reasoning verbatim.
`[(type_identifier) (generic_type …)] @container` would capture the
*`generic_type` node* in the generic case and put `<T>` back, and `Worker<T>`
matches no declared type. So the three self-type shapes (bare, generic, scoped)
get one pattern each; `scoped_type_identifier` is stepped through the same way,
so `impl foo::Bar` files under `Bar`.

**`mod_item body:` is anchored beside `source_file`, while `impl` and `trait`
bodies are not.** All three hold a `declaration_list`, so naming the parent is
the only thing that tells them apart exactly. The rule: an inline `mod` is a
*namespace*, so a `fn`, `const` or `static` written there is as top-level as one
in the file; an `impl` or `trait` body is a *container*, whose functions are
methods and so reach the container patterns instead; a *function* body holds
locals and is anchored out, for the reason every other language's bindings are.
Types are deliberately not anchored at all — a `struct` declared inside a
function is a declaration worth finding, and is rare enough that it cannot flood
a picker the way a loop counter can.

**`const` is a constant, `static` is a variable.** A `static` is Rust's global
binding and `static mut` its mutable one — Go's package-level `var`, and the same
mapping.

**Trait members need two patterns**, because a provided method (with a body) is a
`function_item` and a required one (a signature and a `;`) is a
`function_signature_item`. Both are methods of the trait, so a member completion
after a value of that trait's type lists both.

**Not indexed, deliberately:** `macro_rules!` definitions, associated `const`s
and associated types inside `impl`/`trait` bodies, `use` aliases, tuple-struct
positional fields (`ordered_field_declaration_list` declares no names to
capture), the fields of a struct-shaped enum variant, `union` fields, and `impl`
blocks whose self type is a reference, tuple, slice or `dyn` type. Each is a real
declaration; none is a name a reader jumps to often enough to pay for a pattern,
and recording them is what keeps the list a decision rather than an oversight.

The static half of the recipe found nothing to correct here: all 22 node names
are declared `named: true` in the pinned checkout's `src/node-types.json`, the
anonymous set is empty (every distinction this query draws is drawn by a named
node or a field, never by a literal token), and each of the three fields —
`name`, `body`, `type` — is declared on the node the query hangs it off.

The runtime half was run against the resolved checkout by compiling the
tree-sitter runtime with the pinned grammar's `parser.c` **and `scanner.c`** into
a throwaway C harness over `ts_query_new`/`ts_query_cursor` — Core cannot link
SwiftTreeSitter, and no `tree-sitter` CLI is needed for this — over a fixture
exercising every pattern. The query compiled (18 patterns, 7 captures) and
**every one of the 18 fired**, so none is dead. Confirmed element by element:

| fixture declaration | capture | text |
|---|---|---|
| `pub struct Worker { … }` | `@definition.type` | `Worker` |
| `pub name: String` | `@container` + `@definition.property` | `Worker` + `name` |
| `count: usize` | `@container` + `@definition.property` | `Worker` + `count` |
| `pub struct Pair(pub i32, pub i32)` | `@definition.type` only | `Pair` — the positional fields declare no names |
| `pub enum State { … }` | `@definition.type` | `State` |
| `Idle` / `Busy { depth: u8 }` / `Done(i32)` | three `@container` + `@definition.constant` | `State` + `Idle`, `Busy`, `Done` (not `depth`) |
| `pub union Slot { int, float }` | `@definition.type` only | `Slot` — union fields are not indexed |
| `pub trait Runner { … }` | `@definition.type` | `Runner` |
| `fn start(&self);` (required) | `@container` + `@definition.method` | `Runner` + `start` |
| `fn stop(&self) { … }` (provided) | `@container` + `@definition.method` | `Runner` + `stop` |
| `const LIMIT: usize;` / `type Output;` (associated) | — | not captured, by decision |
| `pub type Alias = Worker` | `@definition.type` | `Alias` |
| `impl Worker { pub fn new(…) }` | `@container` + `@definition.method` | `Worker` + `new` |
| `fn helper()` / `const LOCAL` (inside `new`) | — | **not captured** — the function body is not a `mod` |
| `impl<T> Holder<T> { pub fn get(…) }` | `@container` + `@definition.method` | `Holder` (no `<T>`) + `get` |
| `impl fmt::Display for Worker { fn fmt(…) }` | `@container` + `@definition.method` | `Worker` (**not** `Display`) + `fmt` |
| `impl deep::Nested { pub fn ping(…) }` | `@container` + `@definition.method` | `Nested` (path stepped through) + `ping` |
| `pub fn main_entry()` | `@definition.function` | `main_entry` |
| `fn nested()` / `const NESTED_CONST` (inside `main_entry`) | — | **not captured** — the `source_file` anchor at work |
| `pub mod outer { pub fn helper() }` | `@definition.function` | `helper` — a `mod` is a namespace, so its `fn` is top-level |
| `pub const INNER_MAX` / `pub static INNER_FLAG` (in `mod outer`) | `@definition.constant` / `@definition.variable` | `INNER_MAX`, `INNER_FLAG` |
| `pub const VERSION` | `@definition.constant` | `VERSION` |
| `static REGISTRY` / `pub static mut COUNTER` | two `@definition.variable` | `REGISTRY`, `COUNTER` |
| `use std::collections::HashMap as Map` | — | not captured, by decision |
| `macro_rules! shout { … }` | — | not captured, by decision |

The remaining manual step is the one the recipe requires of every grammar update:
open a `.rs` file in a DEBUG build and confirm its declarations answer ⌃⌘J — the
harness proves the query compiles and captures, not that `SymbolQueryCatalog`
found and loaded it.
