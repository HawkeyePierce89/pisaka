# PisakaCore — Local History (automatic per-file snapshots, browse and restore)

Design documentation for the layer that keeps local, per-file copies of every
buffer the app writes, labeled copies of every file six worktree-mutating git
operations are about to overwrite, and a macOS window that lists those revisions,
diffs one against what the file holds now, and restores it. Each entry records a
file's contract, invariants and the reasoning behind non-obvious decisions —
read the relevant entry before modifying that file, and update it when behavior
changes.

**What this layer is.** A safety net that is *independent of git*: it captures
what the user is about to lose regardless of whether the file is tracked, staged,
committed or ignored, and regardless of whether git is what is doing the
overwriting. Six Foundation-only Core files — the vocabulary, the path math, the
policy, the `FileServicing` engine and two `@MainActor` observable models — plus
three macOS app files (the support directory, the window controller, the view)
and capture calls at three save sites and six gated-operation sites. **Nothing
new compiles on iOS**: there is no iOS window to browse a history in and no iOS
caller of the capture model, so building the store on that destination would
create a directory nothing ever writes to.

**The disk is the state.** There is no index, no database and no manifest: a
snapshot is a file whose *name* carries its timestamp, its event label and its
content hash, and whose *bytes are exactly the revision's text*. Listing a
file's history is one directory read and no content reads; dedup is a string
comparison; retention prunes on names alone. Deleting
`~/Library/Application Support/Pisaka/LocalHistory` forgets the whole feature and
breaks nothing else.

**A reader of the user's files and a writer only of its own store.** Local
History never mutates a buffer of its own accord, never touches the worktree and
never writes a file outside its store, so it takes no
`autosave.suspend()` / `localChanges.beginRevert()` gate and is not gated by one
— the position the symbol index, the `.editorconfig` cache and the LSP client
already hold, for the same reason: taking the gate would serialise a safety net
behind the operations it is protecting the user from. What it *does* take from
the six gated operations is **timing**, and only that; see "The pre-operation
capture is race-free by construction" below. The one write it causes to a user's
file is a **restore**, which is a buffer edit through the live text view — the
ordinary save funnel puts it on disk when the user saves or the autosave fires.

**Every failure is silent, all the way down.** A listing that cannot be read is
an empty history; a write that cannot land loses one revision; a delete that
fails leaves one file for the next prune; a binary, oversized, untitled or
outside-the-project buffer is skipped without a word. This is deliberate and is
stated once here rather than re-argued in each entry: a net that interrupts the
work it is protecting is worse than no net, and there is no answer a user could
usefully give to "one of your snapshots did not save". There is no error state in
this feature at all — not in the store, not in either model, not in the window.

**The stack, bottom to top.** `LocalHistorySnapshot` (+ `LocalHistoryEvent`, the
vocabulary) → `LocalHistoryLayout` (where things go, and the name↔snapshot codec)
→ `LocalHistoryPolicy` (whether they go there at all, and what stays) →
`LocalHistoryStore` (the one type that touches `FileServicing`) →
`LocalHistoryModel` (the capture side: the serial write chain, the three save
sites, the pre-operation capture, the store sweep) + `LocalHistoryBrowserModel`
(the window's companion reader, and the restore *plan*) → the three macOS app
files.

**Nothing new is bundled and nothing new is linked.** `project.yml`,
`Package.resolved` and `Resources/Licenses/licenses.json` are untouched: the
whole feature is Foundation plus the AppKit/SwiftUI the app already links.
(Adding an app-layer *file* still needs `xcodegen generate` before a build —
XcodeGen enumerates the source directory at generation time — but no manifest
changes.)

## The store, on disk

```text
~/Library/Application Support/Pisaka/LocalHistory/     the base (the app's half)
  pisaka-4f2c9a1b3d7e0865/                             one per project root
    3f8a1c04b7e29d165b0e7a2c94d1f680/                  one per file
      0000001772345678901-save-3f8a1c04b7e29d16.snapshot
      0000001772345699999-commit-9b1d0e6a5c74f382.snapshot
```

- A **project directory** is the root's own (sanitised, truncated) name, a `-`,
  and 16 hex characters of the SHA-256 of the root's lexically normalised path.
  The readable prefix is a hint for a human deleting one project's history by
  hand; the digest is the identity. It is truncated to 64 **UTF-8 bytes**, whole
  characters only — bytes because that is the unit the 255-byte file-name bound
  is measured in (64 emoji are 64 `Character`s and 256 bytes), and a project
  whose directory cannot be created would have no history at all, silently.
- A **file directory** is 32 hex characters of the SHA-256 of the
  project-relative path, and nothing else. Directories are hashed rather than
  spelled because a relative path contains `/`, can be deeper than one component
  and can exceed a file name's length on its own — and because mirroring the tree
  would leak the project's structure into a directory anyone can list. The cost:
  the store cannot be read backwards, which is acceptable because every reader
  arrives holding the file it is asking about.
- A **snapshot file name** is `<19 digits of ms>-<event tag>-<16 hex>.snapshot`.
  Nineteen zero-padded digits is the width of `Int64.max`, so every representable
  timestamp encodes to the same width and **lexical order over names is
  chronological order**. `-` is the field separator, which is why every event tag
  is lowercase ASCII without one.
- A **snapshot's bytes are the revision's text**, verbatim UTF-8, nothing
  prepended and nothing wrapped.

## Files

### `PisakaCore`

  - `LocalHistorySnapshot.swift` — the vocabulary. `LocalHistoryEvent` is a
    **closed** enum of seven cases (`save`, `replace`, `revert`, `merge`,
    `branch`, `commit`, `restore`) with a stable lowercase `tag`, an `init?(tag:)`
    inverse and a display `title`. The tag is not a display detail: it is one of
    the three fields encoded into a snapshot's file name, so it is **on-disk
    vocabulary** — renaming a case's tag orphans every snapshot already written
    under the old one (the parse refuses it, the listing drops it, retention never
    reclaims it). Add cases freely; change a tag only with that consequence in
    hand. `init?(tag:)` answering `nil` for an unknown tag is also how a snapshot
    written by a *future* version is ignored rather than mis-read. Every title but
    `save`'s reads "Before …", because a pre-operation snapshot holds what the
    file looked like *before* the operation ran — that is the whole promise of the
    label, and phrasing it in the enum keeps the window from inventing a second
    wording. Both branch operations (switch and checkout-remote) share `branch`:
    two call sites and two writer brackets, but from a file's point of view one
    event, and a user restoring a revision does not care which menu item moved the
    worktree. `LocalHistorySnapshot` is the `Equatable, Sendable` row —
    `fileName`, `timestamp`, `event`, `contentHash` — every field of which is
    parsed out of the file name, which is what makes a listing content-read-free.
    `contentHash` is the first **16** hexadecimal characters of the SHA-256 of the
    UTF-8 bytes: sixteen and not sixty-four because of what it is asked ("is this
    text byte-for-byte the newest revision already stored?"), a dedup question
    against a handful of candidates rather than a security boundary — a collision
    costs one skipped snapshot of one file, and 64 bits is well past what a
    thirty-revision history produces by accident. `sortedNewestFirst(_:)` is the
    one order this feature ever presents or prunes in; it sorts on the
    **timestamp** (so a snapshot assembled by hand orders by what it says it is)
    with the file name breaking exact ties **descending**, because two snapshots
    of one file can share a millisecond and a listing that reshuffled between two
    reads of an unchanged directory would make the window's selection jump.
  - `LocalHistoryLayout.swift` — pure path math over a `base` the app supplies,
    plus the file-name codec. **No file system access, on purpose** — the
    `LSPInstallLayout` / `LeetCodeCacheLayout` discipline restated for a third
    root: nothing here stats, reads, creates or deletes, so the store's tests
    reason about paths against a `StubFileTree` while the app points the same math
    at Application Support; a method that answers a `URL` claims nothing is there.
    `base` is normalised **lexically** in `init` (`.`/`..` resolved, no
    `realpath(3)` and no `stat(2)`) and re-spelled as a directory URL so two
    spellings of one root compare equal — `URL.standardizedFileURL` is
    deliberately not what does that, because it consults the disk under
    `/private/{tmp,var,etc}` (the bug `LSPInstallLayout.normalisedComponents(of:)`
    records at length). `directoryName = "LocalHistory"` lives here rather than in
    the app so the one place that spells it is the one place the "delete this to
    forget everything" instruction points at. `projectDirectory(forRoot:)` and
    `fileDirectory(forRoot:relativePath:)` produce the two levels above; the
    relative path is normalised the same lexical way the roots are, so `a/./b.swift`
    and `a/b.swift` are one file rather than two histories. `contains(_:)` — the
    assertion the store makes before every delete — is asked **through**
    `LSPInstallLayout.directory(_:contains:)`, so "inside my root" is one
    comparison in this codebase rather than three that could drift apart. Its
    stated limit is `LSPInstallLayout`'s: two spellings of one directory
    (`/tmp/x` and `/private/tmp/x`) name two areas, reachable only by opening one
    project under two spellings, and it costs a second history rather than a wrong
    one. `contentHash(of:)` is the **one** producer of a snapshot's hash, so the
    truncation length is stated once. `snapshotFileName(timestamp:event:contentHash:)`
    encodes and `snapshot(fromFileName:)` parses; the parse checks every field
    (exactly three `-`-separated fields, exactly 19 ASCII digits, a known tag,
    exactly 16 lowercase hex characters, the exact extension, no `/`) and answers
    `nil` for anything else. **`nil` is the whole error handling of a listing**: a
    foreign file someone dropped in, a `.partial` from an interrupted write, a tag
    a future version invented — all ignored rather than reported, because a
    history listing has no useful way to complain and the alternative (a partially
    filled snapshot) would let a wrong timestamp or a wrong hash reach dedup and
    retention. Timestamps before 1970 clamp to zero rather than emitting a `-`
    that would break both the field split and the lexical ordering (unreachable —
    a snapshot is stamped when it is taken — and a clamp keeps the invariant
    total).
  - `LocalHistoryPolicy.swift` — the one place that decides *whether* to keep
    bytes and *which* bytes to keep. Two questions, both answered here so neither
    the store, the capture model nor the window can grow a second opinion:
    `capture(of:relativePath:latestHash:)` (the whole skip rule) and
    `prune(_:now:)` (retention, decided on snapshot *names* alone). The ceilings
    are instance properties with stated defaults rather than bare constants,
    because the store holds a policy *value*: the app builds the default one and
    the tests build a small one, and neither has to restate the rules to exercise
    them. **There is no settings UI** — these numbers are a stated behavior of the
    feature, not a preference.
    - `defaultMaxContentBytes` = `ProjectSearchModel.defaultMaxFileBytes` (1 MiB),
      deliberately *the same* ceiling Find in Files already refuses to read: one
      ceiling for "a text file this editor works on", asked in two places rather
      than guessed twice.
    - `defaultMaxAge` = **14 days**. Long enough to cover "what did this look like
      before last week's refactor" — the accident this feature exists for — short
      enough that an ordinary project's history stays small without the user ever
      being asked.
    - `defaultRevisionsPerFile` = **30**. The age bound alone is unbounded in
      *volume*: an aggressive autosave can produce hundreds of revisions of one
      file in an afternoon, and the oldest of those is worth far less than the
      fact that the last thirty are instant to list.
    - `defaultMaxPreOperationFiles` = **200**. Not a storage bound but a latency
      one: that capture is awaited in front of a git command the user asked for,
      so a worktree with thousands of changed files must not put an unbounded read
      pass between the click and the operation. **Buffers are never capped** —
      they are already in memory and are what the user is actually editing.

    The **skip precedence** is deliberate and is what the tests pin: identity
    first (`.untitled` — no url, or no project root: there is nowhere in the store
    to put it, and an untitled buffer has no identity that survives the session
    anyway), then containment (`.outsideProject`), then size (`.tooLarge`), then
    sameness (`.unchanged`). The digest is computed **last**, so the two cheap
    refusals never pay for one and a 1 MiB ceiling is checked before hashing a
    file that could be far larger. `.outsideProject` is load-bearing rather than
    defensive: `ProjectFileWalk.relativePath(of:under:)` *degrades* an outside url
    to its bare file name rather than answering `nil`, so without this guard a
    file opened from elsewhere would share a history with the project file that
    happens to have that name. One skip the design names does **not** appear here
    — content that is not decodable UTF-8 — because it cannot: this takes a
    `String`. It is reachable only on the disk-read path, where
    `FileServicing.readTextIfNotBinary(url:maxBytes:)` is the gate for both binary
    content and the byte ceiling, checked there before a big file is pulled into
    memory at all.

    **Retention is three rules in order**: age, then the count cap over what
    survived it, then the **unconditional reinstatement of the newest revision**.
    The third rule is what makes the feature trustworthy rather than merely tidy —
    a file edited once and then left alone for a month still has the revision from
    before that edit — and it is applied as a reinstatement rather than as an
    exception inside the other two so that those two stay plain and the guarantee
    is stated once. An **event label buys nothing here**: a `save` and a `commit`
    snapshot age out on identical terms, because a label describes *why* a
    revision was taken rather than how much it is worth, and privileging labeled
    ones would quietly make a busy repository's history mostly pre-operation
    snapshots of files nobody edited. `now` is a parameter, so retention is a pure
    function of its inputs and every boundary case is testable without waiting.
  - `LocalHistoryStore.swift` — the disk half: the one type that lists, reads,
    writes and prunes, expressed entirely in terms of `FileServicing`, the layout
    (where things go) and the policy (whether they go there at all). **A value
    type with synchronous, `nonisolated` methods**, the `SymbolIndexModel` shape:
    nothing here hops, so *the caller owns the hop* — the capture model runs these
    on a private queue for every ordinary capture, and the quit path, where a
    `Task` is not guaranteed to run before the process exits, calls the very same
    methods inline on the main actor. A store that owned an actor of its own could
    not offer that second guarantee, and an `async` one would make the quit-time
    write impossible to state. `revisions(root:relativePath:)` is **one directory
    read and no content reads** — the property the whole layout exists to buy —
    with a missing directory (the overwhelmingly common case: most files in a
    project have no history) answering an empty list rather than an error, as does
    an unreadable one. `content(of:root:relativePath:)` answers `nil` for a
    revision that is no longer there, which is genuinely reachable: retention can
    delete one between the listing the window is showing and the row the user
    clicks. `capture(text:root:relativePath:event:now:)` is a fixed sequence —
    **list, ask, write, rename, prune** — where the listing is what supplies the
    newest revision's hash, so dedup (by far the most common outcome on an
    aggressive autosave) costs one directory read and no content read at all; the
    name it is about to write is **parsed back** before use, so what it returns is
    exactly what a listing will report and a name this version could not read back
    is never written. **A snapshot appears in one `move`**: bytes are written
    under a `.partial` name that deliberately does not parse and are renamed into
    place, so a listing never sees a half-written revision and an interrupted
    capture leaves debris that listing ignores and retention ignores —
    `LSPInstallEngine`'s atomicity rule at the scale of one file. **The sweep is
    what reclaims that debris**, and nothing else can: everything else looks
    through a `.partial` by design, so an unreclaimed one would sit there for the
    life of the store and keep its directory from ever counting as empty. Only a
    name this feature could itself have written is removed — a parseable snapshot
    name plus the suffix — so a foreign file that happens to end in `.partial` is
    left alone like any other foreign entry, and a directory holding nothing but
    debris is removed wholesale. The temporary is derived from the destination name
    rather than randomised precisely so a retry reuses it instead of accumulating.
    **The create-write-rename is attempted twice**, and the second attempt is not
    optimism about a failing disk: the sweep above reclaims a file directory it
    finds empty, which is exactly what the `ensureDirectory` of a concurrent
    capture just created — and the capture that can be concurrent with it is the
    quit-time one, whose revision is the last save before termination. Every
    attempt discards its own temporary, so a permanently failing write still
    leaves nothing behind. The **mirror ordering** — the sweep reclaiming that
    directory *after* the `move` has landed — is out of the retry's reach, since
    by then the loop has seen its `move` succeed and broken out, so it is answered
    on the sweep's side instead: the empty-directory removal re-lists immediately
    before it removes and reclaims nothing it can still see something in. Deciding
    on the stale listing would take a just-written snapshot with the directory,
    silently, and that snapshot is the last save before a quit.
    Pruning runs here on the one file just captured, because that is the file
    whose count just changed, and it prunes the list already in hand rather than
    re-reading the directory it just wrote to. `pruneAll(now:)` is the store-wide
    sweep that reclaims everything *else*, including the history of files nobody
    has touched since their revisions aged out; `prune(root:now:)` is the one
    project area it is made of, kept public because it is the smallest thing the
    rule can be stated and tested against. A file directory left with no entries
    at all is removed, then a project area left with no file directories, while
    one still holding something foreign is left exactly as it is, because this
    feature deletes only what it wrote. Retention alone never empties a directory
    holding a real snapshot, so those two branches in practice reclaim a directory
    left with nothing but `.partial` debris. **The sweep is asked of the store,
    not of a root**, and that is load-bearing: retention is the only thing that
    bounds a store kept outside every project, and a sweep keyed to whichever
    project is being opened bounds nothing at all for a project cloned, edited
    once and never opened again — its whole history would sit there for the life
    of the machine. **What no sweep reclaims**, by design, is the newest revision
    of every path ever captured (policy rule 3), including paths whose file was
    since renamed, moved or deleted: the store settles at one revision per such
    path rather than at nothing, which is what the newest-survives guarantee costs
    and why both user-facing docs state the retention numbers with that rule
    beside them instead of promising unconditional reclamation.
    Every deletion goes through one `discard(_:)` that asserts
    `layout.contains(_:)` first — `LSPInstallEngine`'s rule, for its reason: a
    layout bug or a caller passing a url from somewhere else must not turn into
    `rm` on a user's file. **URLs from a listing are never used to read**: the
    listing's spelling has the parent's symlinks resolved into it by
    `FileManager` (`StubFileTree.listingSpelling` stages exactly that), so every
    read and delete re-derives its URL from the layout.
  - `LocalHistoryModel.swift` — the capture side, and the object the app holds for
    the whole session. `@MainActor final class … ObservableObject` that
    **publishes nothing**: it owns the store (built over the base the app
    supplies — Core never names `~/Library/Application Support`), a private serial
    utility queue, and the **write chain**. The chain is what makes two captures
    of one file safe: every capture is list → decide → write and the listing is
    what supplies the dedup hash, so two interleaved captures would each see the
    state before the other and store the same bytes twice; each unit of work is
    therefore *appended* to a single `Task` chain (a new task that first awaits its
    predecessor) rather than started independently. It is per-model rather than
    per-file because captures are rare, small and already off the main actor, and
    one lane is cheaper to reason about than a map of them. `append(_:)` captures
    no `self` — the work already holds the store it needs — so a model released
    mid-flight still finishes what it promised rather than dropping a revision.
    The entry points:
    - `captureSaves(urls:root:texts:)` — fire-and-forget: a save must not wait on
      a safety net. A url with no entry in `texts` is skipped rather than read
      back from disk, because the text the app just wrote is the text that belongs
      in history and re-reading it would race the next edit. It is called **after**
      the write on purpose: a pre-write capture would store bytes a failed write
      never landed, and the content is already post-`SaveTransform` because that
      funnel runs before every write on every path.
    - `captureBuffers(event:urls:root:texts:)` — the general form under any label.
      Its one other caller is Restore.
    - `captureSavesSynchronously(urls:root:texts:)` — the **quit** path, and the
      one place in this feature that does disk work on the main thread.
      `willTerminateNotification` runs on the main thread and the process exits
      when the observer returns, so a `Task` hop is not guaranteed to run at all —
      the last save before a quit, which is exactly the edit a safety net is for,
      would be the one that never lands. `FileServicing.write` is synchronous and
      throwing, so calling the same store methods inline is both possible and
      sufficient. The cost is bounded and paid once per quit: at most one
      directory read plus one ≤1 MiB write per dirty titled buffer, and dedup
      usually makes it zero writes. It **bypasses the chain**, which cannot
      deadlock it and cannot be waited on — whatever is queued there is about to
      be discarded with the process — so it is the one capture that can run
      *beside* another, ordinarily one still on the chain or the folder-open
      sweep. A corrupt snapshot is still unreachable (a snapshot appears in one
      `move`); the two outcomes that are reachable are the same bytes captured
      twice — harmless either way, and which way depends only on whether the two
      clock reads rounded to the same millisecond: different ones leave two
      adjacent revisions of identical content, which retention reclaims like any
      other, and the same one makes the loser's `move` refuse an existing
      destination, so it stores nothing and answers a `nil` nobody reads — and
      the sweep reclaiming the directory this is writing into, which the store's
      one retry answers before the `move` and the sweep's own re-list answers
      after it. A third — **a queued capture of older text landing after
      this one** — is answered upstream by the enqueue-time timestamp (below)
      rather than here: this path cannot wait for the chain (that is its whole
      point) and cannot cancel it (the write may already be in the kernel).
    - `captureBeforeOperation(event:root:bufferTexts:diskTargets:)` — awaited, and
      that is what makes it race-free (below). Three rules decide what is read:
      **buffers win** (a file with an open tab is captured from its buffer and not
      read from disk, so one operation never leaves two same-labeled snapshots of
      one file — and the buffer is what the user would lose); **binary and
      oversize files are skipped** by `readTextIfNotBinary(url:maxBytes:)`, the one
      gate for both; and **the disk set is capped** at `maxPreOperationFiles`.
      **Nothing to capture returns without touching the chain**: the await is on
      everything already queued — including the folder-open sweep — and paying
      that to store zero bytes would put this feature's housekeeping in front of
      an operation the user asked for, with the writer bracket already raised.
    - `pruneStore()` — the folder-open sweep, fire-and-forget on the chain (so
      the folder open itself waits on nothing) with one stated cost: a gated
      operation started while the sweep is still running waits for it, because
      `captureBeforeOperation` is awaited and the chain is serial. Retention gets
      a lane of its own nowhere, deliberately — it deletes names it has already
      condemned, but it deletes them *between* another capture's
      list-decide-write, so a second lane would trade a bounded wait for a dedup
      reading a directory another unit is mutating. It takes **no root**: `LocalHistoryStore.pruneAll(now:)` sweeps every
      project area, because retention is promised to the user without a condition
      and a sweep keyed to the root being opened can never reach the history of a
      project that is not opened again. No generation token, deliberately: it
      publishes nothing and reads nothing anyone displays, so there is no
      superseded state it could write over.

    `relativePath(of:under:)` is the one keying rule, and it is two questions that
    must both answer yes: `LSPInstallLayout.directory(_:contains:)` for
    containment, then `ProjectFileWalk.relativePath(of:under:)` for the path —
    with a check that it did not *degrade* (`root` re-joined to the answer must
    spell the url again), since that helper answers a bare file name rather than
    `nil` for a url it did not expect.

    **Both questions are asked twice: of the raw spellings, and — only if that
    refuses — of `CanonicalPath.canonical(_:)` of each.** The second attempt is
    what makes the disk half of a pre-operation capture work at all.
    `projectRoot` is stored as the user spelled it, while the disk targets of four
    of the six captures are built from the repository root `git rev-parse
    --show-toplevel` reports, which is always *physical*: a project opened through
    a symlink (or under `/tmp`) comes back spelled a second way, and a purely
    lexical comparison calls the two different directories. Every disk target
    would then be dropped and the labelled capture would silently degrade to open
    buffers only — the failure this feature must not have.
    `resyncOpenTabsAfterCheckout` resolves both sides before asking the same
    question, for the same reason.

    The **order** carries its own reason, and it is not "cheapest first". The raw
    attempt is the whole answer whenever the two arrive spelled alike (every
    ordinary project) and touches no disk; canonicalizing *unconditionally* would
    be a regression, because `URL.resolvingSymlinksInPath()` resolves nothing for
    a path that does not exist — under a symlinked root it would refuse a buffer
    whose file has been deleted out from under it, i.e. the one tab holding the
    last copy of that file, which is exactly what a safety net is for. Raw first
    keeps that case byte-for-byte as it was and adds the canonical one only where
    raw refuses. Both attempts answer the *same* relative path for a given file,
    so the store key stays stable however the url was spelled — and a url reaching
    the root through `..`, which the degrade check refuses on the raw pass, falls
    through to the canonical one and is keyed where the file actually lives rather
    than under its bare name. The store's own path math (`LocalHistoryLayout`)
    keeps asking `LSPInstallLayout` raw and only raw: those paths are the app's
    own, under Application Support, and never arrive in two spellings.

    It is internal rather than private because
    `LocalHistoryBrowserModel` must key a file **exactly** as this side did: a
    second, separately maintained copy of the rule would show an empty history for
    a file that has one. `clock` is injectable for the store's reason one level up
    — it is what lets a test give two overlapping captures two distinct
    milliseconds instead of racing the clock.

    **Every capture reads the clock in its entry point, synchronously, before the
    work joins the chain** — never inside `write`, one hop later. A snapshot's
    timestamp is *when the app had those bytes in hand*, which is the instant the
    caller handed them over, and taking it at write time would let a unit that
    waited behind the store sweep out-stamp bytes that are genuinely newer.
    `captureSavesSynchronously` is what makes that reachable rather than
    theoretical: it bypasses the chain by design, so a queued capture of *older*
    text can — and at quit routinely does — reach the disk after it, and a
    write-time read would file that older text as the newest revision, where both
    the window's ordering and retention's "the newest always survives" would
    believe it. `pruneStore()` is the one caller that still reads the clock on the
    chain, and the exception proves the rule: a capture's instant answers *when
    were these bytes in hand*, fixed at the entry point, while retention asks
    *what is old now*, which is only true of the moment the sweep runs. One
    consequence of one instant per call: every unit of a single call shares it —
    which costs nothing, because each keys to a different file, so their snapshots
    land in different directories and no ordering, dedup or name-collision
    question spans two of them.

    The clock's stated limit in production: two
    captures of one file inside the same millisecond order by file name (event
    tag first, content hash second) rather than chronologically, because that is
    all the name preserves — reachable only for two *different* texts of one file
    handed over within a millisecond of each other, and it costs a row's position
    in a list, never a wrong or missing revision.
  - `LocalHistoryBrowserModel.swift` — the window's state and the restore *plan*.
    A **pure reader over the store the capture model already owns**: it is handed
    the same `LocalHistoryStore` value — one store, one layout, one policy,
    however many readers — and it never captures, never prunes and never writes,
    so like the symbol index it neither raises the writer gate nor is gated by it.
    Published: `fileURL`, `relativePath`, `revisions`, `selected`,
    `selectedContent`, `diffRows`, `isLoading`, plus the computed `isEmpty` (a
    file is targeted, its listing has landed, and there is nothing in it) and
    `isUnsupportedTarget` (a file is targeted and could not be keyed at all).
    **The selection is one of those published values on purpose**, rather than
    `@State` in the window beside them: a retarget clears it synchronously, and a
    window holding its own copy would have to echo that clear back through
    `select(_:currentText:)` one SwiftUI pass later — which, sharing the token
    below, would discard the listing the retarget had just started and show a
    file that *has* history as a file that has none. One owner, no echo; the
    window's `List` binds its selection straight to `selected?.fileName`. For the
    same reason `select(_:currentText:)` treats **clearing an already-clear pane
    as no question at all** and returns without bumping the token. **One
    monotonic generation token, captured synchronously before every hop** —
    listing, content load and diff are all off-main work whose result may come
    back to a window that has since been retargeted or moved to another revision;
    superseded work publishes **nothing at all**, not the rows, not the diff and
    not `isLoading`, so the newest work in flight is always the one that turns the
    spinner off. The token is shared by listing and selection rather than split in
    two, because the two are one conversation: a selection only exists against a
    listing, and a retarget must cancel an in-flight content load as surely as an
    in-flight listing. **Retargeting clears before it loads** — `open(file:root:)`
    empties the rows, the selection and the diff synchronously, so the window
    never shows one file's revisions, or one file's content diffed against
    another's buffer, while the new listing is in flight. A url that is not a file
    under the root (or no root at all) is **targeted but unkeyed** — the same
    refusal the capture side makes — which is what `isUnsupportedTarget` reports:
    `fileURL` still holds the file, because the window has to say something
    *about* it and a window that forgot which file it was asked about can only be
    blank, while `relativePath` and the held root are `nil`, so nothing can be
    listed, selected or restored.
    `select(_:currentText:)` moves `selected` synchronously so the highlight
    follows the click, and loads the content and computes
    `LineDiff.rows(old:new:)` off the main actor through the
    `ProjectSearchModel.offMain(_:)` shape. `restore(currentText:)` is pure and
    answers `nil` in the two cases where a restore would be a no-op the user could
    not tell from a bug: nothing selected (or its content not in hand — a revision
    reclaimed between the listing and the click), and a revision whose text the
    buffer already holds; refusing the identical case is what keeps a restore from
    marking a clean tab dirty and writing a `.restore` snapshot of bytes that are
    already the newest revision. That sameness test is `NSString`'s, not Swift's:
    `==` on `String` compares by canonical equivalence, while a revision is
    identified by a SHA-256 over its *UTF-8 bytes*, so a decomposed and a
    precomposed spelling are two real revisions the store keeps apart — and a
    canonical comparison would arm Restore and then plan nothing, which is the
    one no-op that *is* a bug (`SaveTransformController.applyRestore` guards the
    same hazard one layer up). `LocalHistoryRestore` is **a plan, not an
    action** — the `SaveTransformPlan` / `PushPlan` shape — because only the app
    layer can replace a buffer through the live text view. It carries *both* texts
    on purpose: `text` is what the buffer becomes and `captureText` is what the
    *window* was showing as "now", which the app captures under
    `LocalHistoryRestore.event` (`.restore`, a constant rather than a field, so
    there is one wording) before it replaces anything. Pairing them in one value
    is what keeps the pre-restore capture from being a step a caller can forget:
    there is no way to hold a restore plan and not hold the bytes it is about to
    displace. `captureText` is nonetheless the **fallback** rather than the
    authority — see `restoreFromLocalHistory` below: the window reads disk under a
    1 MiB ceiling and `WorkspaceModel.open` has none, so a buffer the app had to
    open can hold text the window could only show as the empty string, and
    snapshotting the window's answer would file an empty `Before Restore` revision
    for a megabyte of text.

### `Pisaka` (app layer — macOS only, every file inside `#if os(macOS)`)

  - `LocalHistorySupportDirectory.swift` — the one place that answers "where does
    Local History keep its snapshots on *this* platform":
    `…/Application Support/Pisaka/LocalHistory`, so the snapshots sit **beside**
    `LanguageServers/` and `LeetCode/` under one app directory, and
    `LocalHistoryLayout.directoryName` is the only component this file adds. The
    `LeetCodeSupportDirectory` shape restated for the third such root — the layout
    is pure path math precisely so the platform-specific half is a handful of
    lines in the app rather than a `#if` inside Core. **Application Support rather
    than Caches**, and here the reasoning is neither `LSPInstallLayout`'s (a
    re-download) nor `LeetCodeSupportDirectory`'s (an offline pane): these bytes
    are the *only* copy of a text nobody else kept, so a purge would silently
    empty the safety net exactly when it is asked for, with nothing able to put a
    single revision back. **Nothing is created here** — the URL is a location, and
    the store calls `ensureDirectory` before its first write, which is what makes
    a first run work at all. The unreachable fallback (every Mac has an
    Application Support directory) exists so this is a `URL` rather than an
    optional threaded through the layout, the store and both models, matching
    `PisakaApp.languageServerInstallRoot`.
  - `LocalHistoryWindowController.swift` — the single, non-modal history window
    (⌘⇧H). `ProjectSearchWindowController` verbatim in shape: a retained
    `EscClosableWindow` hosting a SwiftUI root through an `NSHostingController`,
    released on close by a per-window delegate held alongside it (`NSWindow
    .delegate` is `weak`). **One** window, for that controller's reason with one
    of its own — there is a single `LocalHistoryBrowserModel` behind it carrying
    one target file, one revision list and one selection, and two windows over it
    would fight for that selection the way two Find in Files windows would fight
    over one query. So the window is **retargeted** per file rather than stacked:
    opening history for a second file replaces its contents, its title and its
    focus. An existing window has its root view *replaced* rather than reused,
    because the content carries the app's current closures — and here also the
    file the title names — so a window left open across a retarget or a folder
    switch picks the new one up. The title carries the file because the window's
    whole subject is one file while the list inside it shows timestamps rather
    than names; a retarget that left the title alone would be the one way to end
    up reading the wrong file's revisions. `closeAll()` is wired into the app's
    `willTerminateNotification` observer alongside the diff/merge/search/browser/
    source-viewer controllers.
  - `LocalHistoryView.swift` — the window's contents: revisions on the left, the
    selected one diffed against what the file holds *now* on the right, a Restore
    button under the list. **It observes `LocalHistoryBrowserModel` alone** — the
    capture model publishes nothing and a window that observed it would re-render
    on captures it does not show, which is the whole reason the browser is a
    companion model rather than more members on its owner. **The current text
    arrives as a closure, read at the moment it is needed**: the window outlives
    edits to the file it is showing and outlives a folder switch, so the "new"
    side of every diff has to be asked for rather than captured. Each row shows
    the event title and the timestamp **twice** — relative ("2 hours ago") is how
    a user finds the edit they remember making, absolute is how they tell two of
    them apart. The `DiffView` is keyed by the revision's own file name (so
    switching rows rebuilds the panes wholesale) but named with the *file's* name
    (which is what selects the syntax language; a snapshot's own name is a
    timestamp with a `.snapshot` extension and would highlight as nothing).
    Restore is armed by the *loaded content* rather than by the selection, since
    the content is what a restore writes and it arrives a hop after the click;
    `restore(currentText:)` still has the last word, asked when the button is
    pressed rather than on every body evaluation because that answer costs a read
    of the current text. Pressing it also re-asks `select(_:currentText:)` with
    the restored text, because the rows on screen were diffed against the buffer
    the restore has just replaced: left alone they would describe a state that no
    longer exists, which reads as "the restore did nothing". Two empty states,
    because they are two different answers: "No history for this file yet." for a
    file inside the project (not an error — almost every file in a project has
    never been saved by this app, and it gets a history the moment one is) and
    "This file is not in the open project, so it has no history." for an
    `isUnsupportedTarget` one, which never will. It is the **root of its own
    window**, so it applies
    `.interfaceScaled(settings)` and `.preferredColorScheme` itself like
    `DiffWindowContent`, with the diff panes staying on `settings.fontSize` (the
    code zone). It holds **no selection state of its own** — the `List` binds
    straight to the model's `selected` — which is what keeps a retarget from
    cancelling its own listing; see the browser model's entry. Thin and untested
    like the rest of `Sources/Pisaka`: every decision is Core's.

### The wiring in `PisakaApp` and `AutosaveController`

  - **The model is a plain stored `let`** on `PisakaApp`, like `commitDialog` and
    `leetCode`: it publishes nothing this scene's `body` reads, so observing it
    would put `ContentView` back on an update path for a value nothing shows — and
    it *has* to be a stable instance, because it owns the serial write chain that
    keeps two captures of one file from each dedup'ing against the state before
    the other. The browser model is a second `let` beside it, built over
    `localHistory.store` so both halves share one store value.
  - **Three save sites, and only three.** `save(id:)` — after a successful write,
    so ⌘S, the close prompt's Save and the `runFile`/`testFile` pre-run saves all
    inherit it; `saveAs(id:)` — where a formerly untitled buffer first enters
    history, under the destination it just took; and the `onSaved` binding, which
    covers every autosave trigger *and the quit flush*.
  - **`AutosaveController.onSaved` is now
    `(_ saved: [URL], _ createdFile: Bool, _ isTerminating: Bool) -> Void`, invoked
    on every write path.** Before this feature the quit flush wrote bytes and told
    nobody, which is how a write path silently loses its safety net; now it
    reports with `createdFile: false` (the missing-file probe is still skipped —
    one `stat` per dirty titled buffer to answer a question that has no meaning
    once the run loop is ending) and `isTerminating: true`. One callback on every
    path with a flag saying which, rather than a second hook the next write path
    could again forget. At the caller, `isTerminating` splits the work in two:
    everything that exists to keep *this session's UI* honest — the Local Changes
    re-query, the tree bump, the `.editorconfig` cache drop — runs only when the
    session continues, while the Local History capture runs on both paths,
    synchronously on the way out.
  - **Six gated operations, six pre-operation captures**: `commitFromDialog`
    (pre-empting a formatting `pre-commit` hook — the one way a commit rewrites
    the working tree, and the reason the open-tab resync is not enough on its own,
    since the resync can put the hook's text into the tab but the *pre-hook* text
    is then gone from everywhere), `replaceAllInProject` (the one worktree writer
    here that is not git, and the one whose result no `git checkout` can undo),
    `revertChanges` (the operation whose whole purpose is to destroy text, so the
    one a safety net most owes an escape hatch), `createBranch` and
    `runBranchOperation` (two functions, two brackets, one shared `.branch`
    label), and `applyMerge` (one target: the file being resolved, whose conflict
    markers and any hand-editing inside them vanish the moment the apply
    succeeds). Each is one line through a private `captureBeforeOperation(_:buffers:targets:)`
    helper that adds no decision of its own, so each site reads as a statement of
    what it is pre-empting. The buffer half is `openBufferTexts()` (every open
    titled tab, collected in the same synchronous stretch as `openTabSnapshot()`)
    and the disk half is `changedFileURLs(_:root:)` over rows Local Changes
    already holds — no second traversal and no new git call — except Replace All,
    which uses `ProjectSearchModel.results`, and the merge apply, which names one
    file.
  - **The restore action is three steps, and the order is the design** — behind
    one refusal that comes before all of them. **The plan's root must still be the
    open project** (`model.isCurrentProjectRoot(plan.root)`, the same canonical
    comparison the folder-switch path itself uses), and that check is what makes
    the window's survival of a folder switch safe. Everything else the window does
    is read-only, so outliving the switch costs nothing; Restore is the one thing
    that is not, and a plan made under the previous root names a file no longer in
    the project. Carrying it out would put that file into `WorkspaceModel` through
    `model.open` — the hazard `viewDefinitionOutsideProject` exists to avoid,
    since the autosave, the session snapshot and ⌘S would then all apply to a file
    outside the opened folder — and would file the `.restore` capture under the
    old root while every later save of that buffer keys to nothing, making the
    restore the one edit in that file with no history behind it. So it beeps and
    stops, like the two refusals below. Then: open a tab
    if none holds the file (`model.open` re-selects an existing one, so it is also
    the right call when one is there; an unreadable file beeps and stops, since
    there is nothing to restore *into*), capture the displaced text under
    `.restore` — read back off the buffer **after** the open, `model.text(for:)`
    being exactly what `applyRestore` displaces, with the plan's `captureText` as
    the fallback when there is no buffer to ask; taking the plan's answer outright
    would store the empty string the *window* had to show for a file that has
    since grown past its 1 MiB read ceiling, which is the one place in this
    feature a capture could lose what it exists to keep — then
    `saveTransform.applyRestore(…)`. **A restore the policy would refuse to
    capture does not happen at all**: the displaced text is put to
    `store.policy.capture(of:relativePath:latestHash: nil)` first, and a refusal
    beeps and stops exactly as an unreadable file does. Reading the buffer back
    fixes *what* is snapshotted, not whether it can be — a file that had history
    when it was small and has since grown past `maxContentBytes` is captured by
    nothing, so going ahead would replace megabytes with one ⌘Z as the only copy,
    and it is also the case the window renders least honestly (the same ceiling
    makes the current side of the diff the empty string, so the revision showed
    as wholly added). `latestHash: nil` asks the one question that matters —
    *may* these bytes be stored — rather than whether they would be
    deduplicated, which is a skip that loses nothing. The tab is
    left **dirty**: the ordinary save funnel puts the restored text on disk when
    the user saves or the autosave fires, which is what keeps this feature a
    reader that takes no writer gate.
  - **Two open sites, one window.** File ▸ Local History… (⌘⇧H), disabled without
    a *titled* selected tab — stricter than every other item in that group on
    purpose, because an enabled item over an untitled buffer would open a window
    saying the file has no history when what is true is that it has no file — and
    a "Local History" item on a project-tree file row's context menu, threaded
    from `ContentView` as `onShowLocalHistory`. Both go through one
    `showLocalHistory(for:)`, which starts the listing *before* showing the window
    (one directory read on a background queue) so an already-open window never
    shows the previous file's revisions for a frame.
  - **The store sweep** runs from the folder-open path (`pruneStore()`),
    fire-and-forget: capture already prunes the one file it just wrote, and
    without this a project abandoned for a month would keep every snapshot
    forever. It sweeps the **whole store**, not the project being opened — the
    per-project sweep it replaced could not reclaim a project nobody reopens,
    which is precisely the case the retention promise is made for — and it removes
    a file directory, then a project area, left with nothing in it.

## The pre-operation capture is race-free by construction

Every one of the six gated operations already has the shape this needs, because
the disk-writer bracket demands it: `autosave.suspend()` and
`localChanges.beginRevert()` are raised **synchronously**, before the first
`await`, and the open-tab snapshot is collected in that same synchronous stretch.
Local History's inputs — `openBufferTexts()` and the target urls — are collected
right there beside `openTabSnapshot()`, and
`await localHistory.captureBeforeOperation(…)` is then the **first `await` in the
task body**, ahead of the operation's own.

That is the whole argument. There is no clock involved, no ordering heuristic,
and no gate of Local History's own: the bytes handed to the store were read
before any suspension point at which the operation could have started, and the
call does not return until every one of them is stored. `captureBeforeOperation`
being `async` is not incidental — it is the mechanism.

The buffers-win rule closes the second half of it: a file with an open tab is
captured from the buffer and excluded from the disk pass, so one operation never
produces two same-labeled snapshots of one file, and the copy that is kept is the
one that exists nowhere else.

## How the quit-time write is guaranteed to land

Three facts, and each is load-bearing:

1. `NSApplication.willTerminateNotification` is delivered **on the main thread**
   as the run loop ends. A `Task` scheduled from an observer is not guaranteed to
   run before the process exits.
2. `AutosaveController.flushNow()` on that path writes the dirty titled buffers
   **synchronously** and now **reports them** (`isTerminating: true`).
3. `LocalHistoryModel.captureSavesSynchronously(…)` calls the store's synchronous,
   `nonisolated` methods **inline on the main actor**, so the bytes reach the
   kernel before the observer returns.

Fact 3 is only expressible because the store is a synchronous value type rather
than an actor — the caller owns the hop, so the caller can choose not to hop.
The cost is one directory read plus at most one ≤1 MiB write per dirty titled
buffer, once per quit, with dedup usually making it zero writes; the call
bypasses the write chain, whose queued work the process is about to discard
anyway, and the two outcomes of running beside another capture are the same
bytes captured twice (harmless: two clock reads a millisecond apart leave two
identical revisions retention reclaims, the same millisecond makes the loser's
`move` refuse an existing destination and store nothing) and the store-wide
sweep reclaiming the directory this is writing into, which `capture` retries
over. The third outcome — a capture queued behind the sweep reaching the disk
*after* this one, carrying older text — is settled by fact 4: every capture's
timestamp is read in its entry point, before the work joins the chain, so the
held unit files under the instant its bytes were handed over rather than the
instant it finally ran. Its snapshot is a real revision that belongs in the
history, just not the newest one.

## Tests

133 tests across seven suites in `Tests/PisakaCoreTests/`, all against
`StubFileTree` or pure values — no temporary directories and no real clock:

  - `LocalHistorySnapshotTests` — the tag vocabulary by set equality, every event
    round-tripping through its tag, every pre-operation title saying "Before",
    newest-first ordering including the same-millisecond tie-break.
  - `LocalHistoryLayoutTests` — name round-trips for every event; lexical name
    order equal to chronological order across millisecond, second and day
    boundaries; every malformed-name shape parsing to `nil`; two roots and two
    relative paths giving different directories while one input gives the same
    directory twice; `contains` accepting everything the layout produces; the
    readable project-name prefix bounded in **bytes** rather than characters (an
    emoji and a ZWJ-sequence root name).
  - `LocalHistoryPolicyTests` — each skip reason in isolation and every
    precedence pair between them; exactly 1 MiB captured and one byte more
    refused, counted in UTF-8 bytes (a multi-byte case included); the retention
    rules including "the newest survives even when it is itself expired" and "age
    is applied before the count cap"; the stated defaults as documented numbers.
  - `LocalHistoryStoreTests` — capture/list/read round-trip; a second identical
    capture writing nothing (asserted on `writtenPaths`); one changed byte being a
    new revision; the write going through a temporary name and exactly one `move`;
    an injected failure leaving no partial file and throwing nothing (every
    attempt cleaning up after itself, twice over); a capture whose directory is
    reclaimed mid-write succeeding on its retry — the sweep-versus-quit-capture
    window, staged with `StubFileTree.onWrite`; capture
    pruning the same file's excess; `prune(root:)` bounding a whole project area;
    `pruneAll()` bounding a project area **no root was handed for**, removing an
    area left empty and leaving one holding a foreign entry alone; a never-captured
    file listing `[]`; a foreign file ignored by listing and left alone by pruning;
    the sweep reclaiming an interrupted write nothing else can see, and removing a
    directory that holds nothing but such debris.
  - `LocalHistoryModelTests` — `captureBeforeOperation` returning only once every
    byte is stored (a causal wait through `Gate`, never a delay); a file with both
    a buffer and a disk target captured once, from the buffer; a binary target
    silently absent; the disk cap enforced with every buffer still landing; two
    overlapping saves of one file producing one revision for identical text and
    two ordered ones for different text; the synchronous capture having stored
    everything by the time it returns and dedup'ing against an earlier one; a
    capture held behind the store sweep landing *after* the quit capture and
    still listed as the older revision (the enqueue-time timestamp); urls
    outside the root skipped; the store sweep bounding the area, reclaiming a
    project nobody opened and removing an area left empty; an oversize
    disk target never read into memory; a url that reaches the root through `..`
    refused rather than keyed by its bare name (the re-join guard); and a capture
    with nothing to store returning while the sweep is demonstrably mid-read —
    asserted with a deadline, so joining the chain fails instead of hanging.
  - `LocalHistoryBrowserModelTests` — a stale listing unable to publish over a
    newer one (two loads staged with `Gate`, the older released last); a stale
    content load discarded even when it finishes last (the signal waited on is a
    *later* load landing, never a count of hops); retargeting clearing the
    rows; a file with no history landing `isEmpty` rather than an error; a file
    outside the root targeted but unkeyed (`isUnsupportedTarget`); clearing an
    already-clear selection unable to cancel the listing in flight; the diff
    rows for a selection; the restore plan carrying both texts, `nil` for no
    selection and for an identical revision, and a revision differing from the
    buffer only by Unicode normalization still planning a restore (the store keys
    on UTF-8 bytes, so canonical equivalence is the wrong question).
  - `LocalHistorySourceGatingTests` — the app layer's architectural rules, matched
    against comment- and literal-stripped source the way every sibling suite does:
    every app-side file inside `#if os(macOS)`; the store base spelled in exactly
    one place; **`captureBeforeOperation` named exactly six times against
    `autosave.suspend()` and `localChanges.beginRevert()` also six times each** —
    count equality over the bracket, so a seventh gated operation cannot be added
    without a capture — **and the two sets asserted to alternate by source offset**,
    gate then capture, because counts alone stay green on exactly the arrangement
    the rule exists to refuse: two captures inside one bracket and none inside
    another; the save capture at exactly the three save sites; `onSaved?(`
    invoked at exactly three places in `AutosaveController.swift`, so no write path
    can go unreported again; the quit branch still skipping the probe; the restore
    routed through `SaveTransformController` with no second file naming
    `beginSaveTransformRewrite`/`replaceCharacters`; the restore asking
    `policy.capture(` exactly once, so it cannot replace a buffer the store would
    refuse to snapshot; both open sites present; the
    window declaring no zoom surface; the window closed at termination; and Local
    History never naming `autosave.suspend`/`beginRevert` anywhere.

## Known limits

- **Only what this app writes is captured.** A save through the app's own funnel
  and the six worktree operations are the whole capture surface: an edit made in
  another editor, a `git checkout` run in the embedded terminal or in another
  window, or any other out-of-band write is not seen and leaves no revision. The
  FSEvents watcher exists to keep the *tree* current and is deliberately not
  wired to this — snapshotting every external write would turn a safety net for
  the user's own edits into a mirror of the filesystem.
- **The store holds copies of file contents on the local disk**, unencrypted, in
  `~/Library/Application Support/Pisaka/LocalHistory`, for up to 14 days or 30
  revisions per file. Anything a captured file contained — including a secret
  committed by accident and then removed — is in there until retention reclaims
  it, **except the newest revision of each path, which retention never reclaims**
  (policy rule 3): the store settles at one revision per path ever captured, not
  at nothing. Deleting that directory removes the feature's data completely and
  breaks nothing, and it is the only thing that does; there is no in-app "clear
  history" command, because the directory *is* the state.
- **A pre-operation capture reads at most 200 files from disk.** Open buffers are
  never capped, but in a worktree with more than 200 changed files the disk half
  is truncated, and which 200 is the order the caller handed them in. The bound is
  latency in front of an operation the user asked for, not storage.
- **Files over 1 MiB and files that are not decodable UTF-8 are never captured**,
  silently, under the same ceiling Find in Files uses.
- **Untitled buffers have no history and can have none**, and neither does a file
  opened from outside the project root: the store is keyed by (root,
  project-relative path). Opening one project under two spellings of its path
  (`/tmp/x` and `/private/tmp/x`) gives two separate histories rather than a wrong
  one.
- **The ⌘Z guarantee holds for the tab that is *showing*, not for any open tab.**
  `applyRestore` takes the through-the-view path only when the editor's
  `displayedFileID` already equals the target, so restoring into a file with no
  tab (one is opened) *or* into an open background tab (it is selected, but
  SwiftUI has not moved the editor yet in that same turn) falls through to
  `WorkspaceModel.replaceText(_:for:)`, which costs that tab its undo stack and
  its remembered viewport. The common path — ⌘⇧H on the tab you are looking at —
  is the through-the-view one.
- **A file the operation deleted cannot be restored from its own labelled
  snapshot.** A restore is a buffer edit, and `restoreFromLocalHistory` opens the
  file first; a revert of an untracked file, or a branch switch that removes one,
  deletes it and force-closes its tab, so the `Before Revert` / `Before Branch
  Change` revision taken for exactly that case is still *listed* (the window can
  outlive the file) but Restore beeps rather than recreating it. Recovering it
  means creating the file again and restoring into it.
- **Renaming, moving or deleting a file leaves its history behind.** The store
  is keyed by a digest of the (root, project-relative path) pair, and the digest
  is not invertible, so the project tree's rename, drag-and-drop move and delete
  carry nothing with them: the renamed file starts an empty history under its new
  path, and the revisions taken under the old one stay in the store, unreachable
  from the window; retention thins them to the newest, which then survives for
  good like every other newest revision. Migrating them would mean
  moving one directory for a file move and re-deriving a digest per descendant
  for a folder move — a second path-keying rule beside the one the layout states
  — and a delete has no destination to migrate to at all.
- **The window does not refresh itself.** `revisions` is listed once, by
  `open(file:root:)`; a revision written while the window is open — an autosave,
  a gated operation, or the `Before Restore` snapshot the Restore button itself
  takes — is in the store but not in the list until ⌘⇧H retargets the window.
  Re-listing after a restore would additionally race the capture, which is
  fire-and-forget on the chain, so a reload issued in the same turn could show
  the row or not depending on timing — less truthful than a list that plainly
  reflects the moment it was taken.
- **Two revisions of one file inside the same millisecond order by file name** —
  event tag first, content hash second — rather than chronologically, because a
  millisecond is all the name preserves. The order is deterministic and stable
  (a listing that reshuffled would make the window's selection jump); what it
  costs is a row's position, never a revision.
- **macOS only.** There is no iOS window, no iOS capture and no iOS store.
