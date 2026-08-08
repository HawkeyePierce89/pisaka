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
    often as the debounce fires safe; `remove(fileURL:)` erases a file from both.
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
    break completion in the very file being typed in. A refresh for a *different*
    root is a folder change wearing a refresh's clothes and runs as a `rebuild`: no
    stamp from the previous project may gate a file in this one. A `nil` stamp
    means "always re-extract" (see `FileStamp` in `core-workspace.md`), so a stub
    service degrades to correct-but-slower rather than to a stale index.
    **Buffers.** `reindexBuffer(url:text:language:)` re-extracts one file from live
    editor text — the extraction inside a one-file `offMain` block with a
    generation re-check after it, so a folder switch landing mid-parse discards the
    result — and marks the entry buffer-sourced; an unindexable language is dropped
    before any work. `forgetBuffer(url:)` is what a tab close means: the symbols
    *stay* (they are still the best knowledge available, and the file on disk is
    usually identical anyway), but the entry's owner changes and its stamp is
    cleared, so the next refresh re-extracts from disk unconditionally rather than
    concluding from an unchanged stamp that a buffer's version is current.
    **Buffer-over-disk precedence** is the rule that makes the two sources safe to
    mix: a disk-sourced outcome for a file a buffer already wrote is dropped in
    `apply`, because the chunk read that text *before* the edit and publishing it
    would undo the re-index the user's keystroke just caused. The stamp snapshot is
    taken per *chunk* rather than per walk for the same reason — a `reindexBuffer`
    landing between two chunks must be visible to the next one. A file that throws
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
    single identifiers; scanning is surrogate-pair aware, so a non-BMP scalar is
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
    opened in; reading a value type through a closure is also what makes the read
    lock-free, since the snapshot cannot change while a ranking pass walks it.
    **Definitions** are an exact, case-sensitive name match ordered current-file
    first, then by relative path, line, offset and name — current file first
    because a name declared in the file being read is nearly always the one meant,
    and the rest path-then-line so a rebuilt index cannot reshuffle the menu under
    the user's cursor. An empty identifier yields nothing: it is what
    `IdentifierScanner` reports for a click on whitespace, and "no name" must beep
    rather than open an empty menu. **Completions** merge the index's prefix
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
    and the best candidate could be missing entirely. Ranking facts are
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
