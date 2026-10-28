# PisakaCore — Local History (automatic per-file snapshots, browse and restore)

Design documentation for the layer that keeps local, per-file copies of every
buffer the app writes, labeled copies of every file nine worktree-mutating
operations are about to overwrite or the project tree is about to delete, copies
of the open buffers under a label the user names, and a macOS window that lists
those revisions, diffs one against what the file holds now, and restores it —
recreating the file when it is gone. A history follows its file through the
tree's rename and move. Each entry records a
file's contract, invariants and the reasoning behind non-obvious decisions —
read the relevant entry before modifying that file, and update it when behavior
changes.

**What this layer is.** A safety net that is *independent of git*: it captures
what the user is about to lose regardless of whether the file is tracked, staged,
committed or ignored, and regardless of whether git is what is doing the
overwriting. Six Foundation-only Core files — the vocabulary, the path math, the
policy, the `FileServicing` engine and two `@MainActor` observable models — plus
four macOS app files (the support directory, the window controller, the view and
the two File-menu prompts) and capture calls at three save sites, seven
gated-operation brackets (which carry nine operations — `gh pr checkout` and the
post-merge tail's two steps all ride the branch operations' bracket), the project
tree's delete, the two external-change resolutions (Overwrite and Reload, which
capture whichever side loses) and the user's own **Put Label…**; the tree's rename and
drag-and-drop move carry a file's history to its new path. **Nothing
new compiles on iOS**: there is no iOS window to browse a history in and no iOS
caller of the capture model, so building the store on that destination would
create a directory nothing ever writes to.

**The disk is the state.** There is no index, no database and no manifest: a
snapshot is a file whose *name* carries its timestamp, its event label and its
content hash, and whose *bytes are exactly the revision's text*. Listing a
file's history is one directory read and no content reads; dedup is a string
comparison; retention prunes on names alone. What a file directory belongs to is
recorded *in* that directory (its `path` record), and a label's text beside its
snapshot (a sidecar), so each file directory is self-contained and there is still
no project-level index to keep in step. Deleting
`~/Library/Application Support/Pisaka/LocalHistory` forgets the whole feature and
breaks nothing else.

**A reader of the user's files and a writer only of its own store.** Local
History never mutates a buffer of its own accord, never touches the worktree and
never writes a file outside its store, so it takes no
`autosave.suspend()` / `localChanges.beginRevert()` gate and is not gated by one
— the position the symbol index, the `.editorconfig` cache and the LSP client
already hold, for the same reason: taking the gate would serialise a safety net
behind the operations it is protecting the user from. What it *does* take from
the nine gated operations is **timing**, and only that; see "The pre-operation
capture is race-free by construction" below. The one write it causes to a user's
file is a **restore**, which is a buffer edit through the live text view — the
ordinary save funnel puts it on disk when the user saves or the autosave fires —
**except that a restore into a path with no file first creates an empty file,
under `revertInFlight()`**: the one worktree create this feature makes, and the
reason a deleted file can come back from its own revisions. It *consults* the
writer gate the way the tree's own create does and never raises it.

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
sites, the pre-operation capture, the delete and label captures, the move
follow, the store sweep) + `LocalHistoryBrowserModel` (the window's companion
reader, the deleted-file listing, and the restore *plan*) → the four macOS app
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
    activity                                           the project's activity days
    3f8a1c04b7e29d165b0e7a2c94d1f680/                  one per file
      path                                             the readable path record
      0000001772345678901-save-3f8a1c04b7e29d16.snapshot
      0000001772345699999-commit-9b1d0e6a5c74f382.snapshot
      0000001772345700000-label-9b1d0e6a5c74f382.snapshot
      0000001772345700000-label-9b1d0e6a5c74f382.snapshot.label   its label text
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
  would leak the project's structure into a directory anyone can list. A digest
  cannot be read backwards on its own, and three things need to: a rename or move
  has to find every history under the old path, Deleted Files… has to name files
  that no longer exist, and a restore has to know where to recreate one. The
  **path record** below is what answers them.
- The **path record** is a file named `path` (no extension) in each file
  directory. Its bytes are the lexically normalised project-relative path in
  UTF-8 — **exactly the digest's input, no newline** — so it is **the inverse of
  the hash and nothing more**: no timestamp, no version field, nothing a reader
  could disagree with the directory name about except the path itself. It is
  written as `path.partial` and renamed into place like every other write here.
  - **Capture writes, readers verify.** `capture(...)` writes the record only
    when the directory listing it already holds shows **no `path` entry**, and it
    never reads the record's content, so a dedup'd capture stays **one directory
    read and no content read** — the property the layout exists to buy is not
    spent on the record. A dedup'd capture into a directory that already holds
    snapshots but no record still writes one: that is how a directory written
    before records existed gets one, on its file's first capture after the
    upgrade.
  - **Verification is on the read side only.** Every reader — `recordedPaths`,
    `migrate`, and through them Deleted Files… — accepts a record only when its
    text is non-empty, already normalised, does not start with `/`, and digests
    to the directory's own name; a record that fails is treated exactly as no
    record. A **record-less** directory stays readable *forwards* (a reader that
    arrives holding the file finds it by digest, as before) and is reached by
    nothing that reads backwards.
  - **A present-but-wrong record is corrected only by migration's own
    rewrite** of the directories it moves or merges into; capture leaves any
    present record alone. The reachable way to get one is a crash between a
    migration's directory `move` and its record rewrite. That is acceptable
    because the wrong record misleads nothing — every reader verifies — so the
    directory is merely in the position a pre-upgrade directory is in, and
    correcting it from capture would cost every capture a content read to catch
    a crash-only state.
- A **label sidecar** holds the user's text for one `.label` snapshot, beside it
  in the same file directory, named `<snapshot file name>.label` (temporary:
  `<snapshot file name>.label.partial`). The snapshot name codec is unchanged —
  its grammar has no room for free text — and the sidecar ends in `.label`, so
  neither it nor the record parses as a snapshot and listing, dedup and
  retention look straight through both. Keeping it per file directory is what
  lets retention delete a label with its snapshot and migration carry both,
  with no project-level index. One Put Label writes the same normalised text into
  every sidecar of that capture.
- A **snapshot file name** is `<19 digits of ms>-<event tag>-<16 hex>.snapshot`.
  Nineteen zero-padded digits is the width of `Int64.max`, so every representable
  timestamp encodes to the same width and **lexical order over names is
  chronological order**. `-` is the field separator, which is why every event tag
  is lowercase ASCII without one.
- A **snapshot's bytes are the revision's text**, verbatim UTF-8, nothing
  prepended and nothing wrapped.
- The **activity record** is a file named `activity` (no extension) at the top of
  a project area, beside the file directories rather than in one — so it never
  parses as a snapshot and no file directory listing sees it. It holds up to
  `LocalHistoryPolicy.activityDayCount` (14) local days on which the project
  captured a revision, one `yyyy-MM-dd` per line, oldest first. It is what
  retention counts instead of calendar days (see the policy), written on the
  capture chain at most once per day and read once per project prune. It is the
  area's own bookkeeping rather than a history, so it does not keep an otherwise
  empty area alive: a sweep finding nothing else there removes it and then the
  area.

## Files

### `PisakaCore`

  - `LocalHistorySnapshot.swift` — the vocabulary. `LocalHistoryEvent` is a
    **closed** enum of fourteen cases (`save`, `replace`, `revert`, `merge`,
    `branch`, `commit`, `restore`, `rename`, `pullRequest`, `pull`, `delete`,
    `label`, `overwrite`, `discard`) with a stable lowercase
    `tag`, an `init?(tag:)`
    inverse and a display `title`. The tag is not a display detail: it is one of
    the three fields encoded into a snapshot's file name, so it is **on-disk
    vocabulary** — renaming a case's tag orphans every snapshot already written
    under the old one (the parse refuses it, the listing drops it, retention never
    reclaims it). Add cases freely; change a tag only with that consequence in
    hand. `init?(tag:)` answering `nil` for an unknown tag is also how a snapshot
    written by a *future* version is ignored rather than mis-read. Every
    pre-operation title reads "Before …", because a pre-operation snapshot holds
    what the file looked like *before* the operation ran — that is the whole
    promise of the title, and phrasing it in the enum keeps the window from
    inventing a second wording. The exceptions record a moment rather than
    pre-empt an operation: `save` is the buffer the app just wrote, `label` the
    buffer at the instant the user named it, and the two external-change
    resolutions name **which side lost**, because "before" alone would not say
    whose text the revision holds — `overwrite` ("Disk Version Before Overwrite")
    is the *disk* text an Overwrite is about to replace, the version another
    program wrote and of which no other copy may exist, and `discard` ("Edits
    Discarded by Reload") is the *buffer* a Reload is about to throw away. Both
    tags are lowercase with no `-`. Neither is a pre-operation event in the
    bracket sense: no writer gate is raised, the write being the ordinary save
    funnel and the reload a buffer replacement, so both are captured at the
    resolution site (`DiskSyncController`, `app-shell.md`) through
    `captureBuffers`, ahead of the act, and only for a tab the external-change
    rule found in conflict (`core-workspace.md`). Both branch operations (switch and checkout-remote) share `branch`:
    two call sites and two writer brackets, but from a file's point of view one
    event, and a user restoring a revision does not care which menu item moved the
    worktree. `rename` is the newest case and the one whose snapshots are the
    *whole* recovery story rather than a second one: a project-wide rename lands as
    one undoable step only in the tab that was on screen, so every other file it
    touched — open in a background tab, or held by no tab at all — is recoverable
    here and nowhere else. `pullRequest` is the newest, and the one case whose
    **raw value is written out** (`= "pullrequest"`): the tag must be lowercase
    ASCII with no `-`, which the case name would not have given it, and its title
    is "Before Pull Request Checkout" — a separate case from `branch` even though
    it shares that operation's bracket, because from a file's point of view "the
    branch was switched" and "a pull request was checked out" are different
    answers to "why did this revision get taken" (`core-github.md`). `pull` came
    next, and it is `pullRequest`'s argument applied once more: the post-merge
    tail's second step is a `pull --ff-only`, and a file it overwrites was
    overwritten by *the remote's* work rather than by anything done on this
    machine — "what did this file look like before I took everyone else's
    changes?" is not the question "Before Branch Change" answers, so its title is
    "Before Pull" (`core-github.md`). `delete` ("Before Delete") is the project
    tree's delete, and the one event whose operation removes the file outright, so
    its snapshot is not a second copy of something the worktree still holds but
    the only copy left — it is what Deleted Files… finds and what a restore into
    the missing path recreates the file from. `label` ("Label") is **Put Label…**:
    not a pre-emption, nothing runs after it; the user's own text lives in a
    sidecar rather than in the name, and this title is what a row shows until — or
    unless — that text is read. It is also the one event exempt from dedup (see
    the policy). **No event exists for a move**: a move carries revisions, it does
    not take one. Every tag
    round-trips through `LocalHistoryLayout`'s name
    codec under test, because a tag *is* on-disk data. `LocalHistorySnapshot` is the `Equatable, Sendable` row —
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
    **Every other on-disk name is spelled here too**, so the store composes none:
    - `normalisedRelativePath(_:)` — public, and the very normalisation
      `fileDirectory` applies before digesting (`.` and empty components dropped,
      `..` popped, no leading `/`). The record, the digest and migration's prefix
      comparison share this one spelling; a record written in another would fail
      its own verification.
    - `pathRecordName` (`path`), `pathRecordText(forRelativePath:)` (the encode:
      the normalised path) and `relativePath(fromPathRecord:fileDirectoryName:)`,
      the **verifying decode** — the path only when the text is non-empty,
      normalised, relative and digests to the directory name it was read out of,
      `nil` otherwise. That decode is every reader's whole defence, which is why
      it lives beside the digest rather than in the store.
    - `labelFileName(forSnapshotFileName:)` and its inverse
      `snapshotFileName(fromLabelFileName:)`, which answers only for
      `<a parseable snapshot name>.label`.
    - `temporarySuffix` (`.partial`, moved here from the store) and
      `isOwnTemporary(_:)`, the one predicate for this feature's own debris:
      a parseable snapshot name, `path`, or a valid sidecar name, each plus the
      suffix — exactly three shapes, so a foreign `.partial` is never ours.
  - `LocalHistoryPolicy.swift` — the one place that decides *whether* to keep
    bytes and *which* bytes to keep. Three questions, all answered here so neither
    the store, the capture model nor the window can grow a second opinion:
    `capture(of:relativePath:latestHash:event:)` (the whole skip rule),
    `label(from:)` (what a user's label may say) and
    `prune(_:now:activityDays:calendar:)` (retention, decided on snapshot *names*
    alone, plus the project's activity record). The ceilings
    are instance properties with stated defaults rather than bare constants,
    because the store holds a policy *value*: the app builds the default one and
    the tests build a small one, and neither has to restate the rules to exercise
    them. **There is no settings UI** — these numbers are a stated behavior of the
    feature, not a preference.
    - `defaultMaxContentBytes` = `ProjectSearchModel.defaultMaxFileBytes` (1 MiB),
      deliberately *the same* ceiling Find in Files already refuses to read: one
      ceiling for "a text file this editor works on", asked in two places rather
      than guessed twice.
    - `defaultMaxAge` = **14 days**, a **floor rather than a deadline** (see
      `activityDayCount`). Long enough to cover "what did this look like
      before last week's refactor" — the accident this feature exists for — short
      enough that an ordinary project's history stays small without the user ever
      being asked.
    - `activityDayCount` = **14**, static because it is also the activity
      record's capacity (`LocalHistoryLayout.activityDays(fromRecord:)` keeps
      exactly this many): a policy asking for more days than the record can hold
      would never expire anything, and two numbers that must agree are one
      number.
    - `defaultRevisionsPerFile` = **30**. The age bound alone is unbounded in
      *volume*: an aggressive autosave can produce hundreds of revisions of one
      file in an afternoon, and the oldest of those is worth far less than the
      fact that the last thirty are instant to list.
    - `defaultMaxPreOperationFiles` = **200**. Not a storage bound but a latency
      one: that capture is awaited in front of a git command the user asked for,
      so a worktree with thousands of changed files must not put an unbounded read
      pass between the click and the operation. **Buffers are never capped** —
      they are already in memory and are what the user is actually editing. The
      tree's delete capture is bounded by the same number, for the same reason
      and more so: its reads run on the main thread in front of the removal.
    - `maxLabelLength` = **100** characters, a static rather than an instance
      property because nothing varies it: a label is a row title, not a note,
      and has to fit beside a timestamp.

    The **skip precedence** is deliberate and is what the tests pin: identity
    first (`.untitled` — no url, or no project root: there is nowhere in the store
    to put it, and an untitled buffer has no identity that survives the session
    anyway), then containment (`.outsideProject`), then size (`.tooLarge`), then
    sameness (`.unchanged`). The digest is computed **last**, so the two cheap
    refusals never pay for one and a 1 MiB ceiling is checked before hashing a
    file that could be far larger. **`event` is a required input because sameness
    depends on it: a `.label` capture is never `.unchanged`.** A label marks a
    moment the user chose, and an unchanged buffer at that moment is exactly what
    they asked to mark — deduplicating it would leave the label with no row to
    stand on, and a Put Label over five tabs would silently label only the edited
    ones. Every other skip applies to a label as to anything else. The store
    passes its event straight through and decides nothing; every caller states
    one, including the restore's preflight in `PisakaApp` (`.restore`), which
    leaves `latestHash` at its `nil` default to ask only whether the bytes *may*
    be stored. `.outsideProject` is load-bearing rather than
    defensive: `ProjectFileWalk.relativePath(of:under:)` *degrades* an outside url
    to its bare file name rather than answering `nil`, so without this guard a
    file opened from elsewhere would share a history with the project file that
    happens to have that name. One skip the design names does **not** appear here
    — content that is not decodable UTF-8 — because it cannot: this takes a
    `String`. It is reachable only on the disk-read path, where
    `FileServicing.readTextIfNotBinary(url:maxBytes:)` is the gate for both binary
    content and the byte ceiling, checked there before a big file is pulled into
    memory at all.

    **The label rule is one function asked from both sides.** `label(from:)`
    trims whitespace and newlines from both ends and answers `nil` for an empty
    result, for more than `maxLabelLength` characters, or for text still holding
    a line break (a label is one line of a row title). The prompt's Put Label
    button is enabled only while it answers, the model normalises through it
    before capturing, and a sidecar read back from disk is displayed only if it
    still passes — so a hand-edited or truncated sidecar shows the plain "Label"
    title rather than something the prompt could never have produced.

    **Retention is three rules in order**: age, then the count cap over what
    survived it, then the **unconditional reinstatement of the newest revision**.
    **The age rule counts activity days, under an AND with the calendar.** A
    revision is expired only when it is older than `maxAge` **and** at least
    `activityDayCount` recorded activity days fall strictly after its own local
    day. The activity half can only *spare* a revision the calendar half
    condemned, never condemn one it spared, so nothing is ever reclaimed earlier
    than the calendar rule alone would reclaim it: a user active every day gets
    exactly the calendar behaviour, and one away for a month comes back to the
    last 14 days they actually worked rather than to nothing. **Without a
    readable record** (`activityDays: nil` — none written yet, or one that did
    not parse) the age rule is the calendar half alone, exactly today's rule. A
    revision's own day is spelled through `LocalHistoryLayout.activityDay(of:calendar:)`
    with the same injected `calendar` whose time zone is what "local day" means,
    so a test pins 23:59 and 00:01 as two days on any machine. The count cap and
    the newest-survives reinstatement keep their order and their meaning: the cap
    still bounds what the age rule spares, and **the newest revision of each path
    still survives everything**, which is what the activity rule's leniency can
    never undo.
    The third rule is what makes the feature trustworthy rather than merely tidy —
    a file edited once and then left alone for a month still has the revision from
    before that edit — and it is applied as a reinstatement rather than as an
    exception inside the other two so that those two stay plain and the guarantee
    is stated once. An **event label buys nothing here**: a `save` and a `commit`
    snapshot age out on identical terms, because a label describes *why* a
    revision was taken rather than how much it is worth, and privileging labeled
    ones would quietly make a busy repository's history mostly pre-operation
    snapshots of files nobody edited. A **`.label` revision is no exception**: a
    user's label names a moment, it does not pin one, and the store deletes its
    sidecar together with it. `now`, the days and the calendar are parameters, so
    retention is a pure function of its inputs and every boundary case is
    testable without waiting.
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
    clicks. `capture(text:root:relativePath:event:label:now:)` is a fixed sequence —
    **list, ask, write, rename, record, note the day, prune** — where the listing is what supplies the
    newest revision's hash, so dedup (by far the most common outcome on an
    aggressive autosave) costs one directory read and no content read at all; the
    name it is about to write is **parsed back** before use, so what it returns is
    exactly what a listing will report and a name this version could not read back
    is never written. **A snapshot appears in one `move`**: bytes are written
    under a `.partial` name that deliberately does not parse and are renamed into
    place, so a listing never sees a half-written revision and an interrupted
    capture leaves debris that listing ignores and retention ignores —
    `LSPInstallEngine`'s atomicity rule at the scale of one file. Snapshots,
    sidecars and records all go through one `writeInPlace`, so they share that
    discipline and the retry below.
    **The record step is driven by the same listing**: when the directory holds a
    snapshot — already, or after this write — and the listing shows no `path`
    entry, the record is written; a present one is never read and never
    rewritten (see *The store, on disk*). A capture the policy refuses outright
    into an empty directory writes no record, because a record with no revision
    beside it describes no history.
    **A labelled capture** takes `label:` alongside `.label`, normalised through
    `LocalHistoryPolicy.label(from:)` again so no text the reader would refuse
    reaches the disk. Its sidecar is written **before** the snapshot, so a
    listing never shows the row ahead of its text, and a sidecar that cannot be
    written loses the revision rather than leaving a labelled capture without its
    label; a snapshot write failing after the sidecar landed leaves an orphan the
    sweep reclaims. When retention deletes a `.label` snapshot — at capture, at
    the sweep, after a merge — its sidecar goes with it. **The sweep is
    what reclaims that debris**, and nothing else can: everything else looks
    through a `.partial` by design, so an unreclaimed one would sit there for the
    life of the store and keep its directory from ever counting as empty. Only a
    name this feature could itself have written is removed —
    `LocalHistoryLayout.isOwnTemporary`'s three shapes — so a foreign file that
    happens to end in `.partial` is left alone like any other foreign entry. An
    **orphan sidecar** (one whose snapshot is not in the listing) is debris of
    the same kind and is reclaimed with it. A directory then holding **no
    snapshot and nothing foreign** — only its record, or nothing — counts as
    empty: the record is removed first, the directory is re-listed, and it is
    removed only if the re-list is empty (the quit-capture guard below). A
    directory holding a foreign entry is still left alone, record included. A
    quit-time capture landing in that window may find the record still listed and
    not write one; the next capture's listing shows it gone and writes it then.
    The temporary is derived from the destination name
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
    before it removes and reclaims nothing it can still see something in, and that
    listing and the recursive removal run under the store's one `exclusion` lock,
    which every `capture` holds for its whole length — a re-list alone narrows the
    window and cannot close it, since a capture could still land after the listing
    and before `removeItem` traverses the directory. The project area's removal and
    a migration's emptied source take the same lock; it is held for one capture or
    one removal, never across a sweep, so the quit path waits at most that long.
    Deciding
    on the stale listing would take a just-written snapshot with the directory,
    silently, and that snapshot is the last save before a quit.
    **Noting the day** (`noteActivity`) reads the project's activity record once
    and rewrites it only when today's local day is not already in it, so the
    record is written at most once per day per project; only a *written*
    revision notes the day, since a skipped capture changes nothing in the store
    and must neither create an area for the record nor count as a day this
    project's history moved. The record is **replaced** rather than created, so it
    goes through `FileServicing.write` — atomic on the real service — rather than
    `writeInPlace`, whose `move` refuses an existing destination; a reader sees
    the old days or the new ones, never a missing record a concurrent sweep would
    read as "calendar rule". "Already there" rather than "already the newest"
    keeps a clock set backwards from rewriting it on every capture; a garbled
    record is replaced by one holding today alone, which only ever makes
    retention more lenient; a failed write is silent and answers what was read,
    so the prune that follows judges by what is on disk. The decode
    (`LocalHistoryLayout.activityDays(fromRecord:)`) repairs duplicates, disorder
    and surplus lines but answers `nil` for any line that is not a real
    `yyyy-MM-dd` date, because a garbled record must not be half-believed — a short
    list of days is exactly what spares revisions. The spelling is always
    Gregorian, built from components rather than a `DateFormatter`, so lexical
    order is chronological order and no locale can change a digit; only the time
    zone decides which day a moment belongs to. The `calendar` is the store's
    injected one. The record is written only from inside `capture`, so the quit
    path's synchronous capture writing it on the main thread is that path's
    existing exception and not a new main-thread writer.
    Pruning runs here on the one file just captured, because that is the file
    whose count just changed, and it prunes the list already in hand rather than
    re-reading the directory it just wrote to, against the days the noting step
    just read. A project prune reads the record **once**, before its loop, and
    judges every file directory against that one answer; a migration's merge
    reads it once for its own prune. It is read through `fileService.read` alone,
    never by listing, so a capture-time prune still lists nothing but its own
    file directory. `pruneAll(now:)` is the store-wide
    sweep that reclaims everything *else*, including the history of files nobody
    has touched since their revisions aged out; `prune(root:now:)` is the one
    project area it is made of, kept public because it is the smallest thing the
    rule can be stated and tested against. A file directory left with no entries
    at all is removed, then a project area left with no file directories — its
    activity record never removed on its own but only with the area, which is
    re-listed before its recursive removal for the quit-capture reason (removed
    first, a capture landing in between would keep the area alive without its
    record, and the next prune would fall back to the calendar rule) — while
    one still holding something foreign is left exactly as it is, because this
    feature deletes only what it wrote. Retention alone never empties a directory
    holding a real snapshot, so those two branches in practice reclaim a directory
    left with nothing but debris — a `.partial`, an orphan sidecar, a record with
    no revision beside it. **The sweep is asked of the store,
    not of a root**, and that is load-bearing: retention is the only thing that
    bounds a store kept outside every project, and a sweep keyed to whichever
    project is being opened bounds nothing at all for a project cloned, edited
    once and never opened again — its whole history would sit there for the life
    of the machine. **What no sweep reclaims**, by design, is the newest revision
    of every path ever captured (policy rule 3), including paths whose file was
    since deleted, or renamed or moved while its directory was record-less: the
    store settles at one revision per such path rather than at nothing, which is
    what the newest-survives guarantee costs
    and why both user-facing docs state the retention numbers with that rule
    beside them instead of promising unconditional reclamation.
    Every deletion goes through one `discard(_:)` that asserts
    `layout.contains(_:)` first — `LSPInstallEngine`'s rule, for its reason: a
    layout bug or a caller passing a url from somewhere else must not turn into
    `rm` on a user's file. **URLs from a listing are never used to read**: the
    listing's spelling has the parent's symlinks resolved into it by
    `FileManager` (`StubFileTree.listingSpelling` stages exactly that), so every
    read and delete re-derives its URL from the layout.

    **The readers that read backwards**, each silent on failure:
    - `recordedPaths(root:)` — every verified record under one project area,
      sorted: **one directory read of the area plus one record read per file
      directory**, the file directories themselves never listed. An absent or
      failing record skips its directory; an unreadable area is `[]`.
    - `isMissing(root:relativePath:)` — `fileStamp(at:) == nil` on the file the
      path names. **"Missing on disk" is this one question**, asked by Deleted
      Files… and by the restore's recreate branch alike, so the store stays the
      only Local History type that asks the file service anything.
    - `labelText(of:root:relativePath:)` — the sidecar's text, only if
      `LocalHistoryPolicy.label(from:)` still accepts it; any non-`.label`
      snapshot answers `nil` without a read.

    **`migrate(root:from:to:now:)` carries a history after a rename or move —
    records only, for files and folders alike.** The affected set is every
    verified `recordedPaths` entry equal to the old path or under it **at a `/`
    boundary** (so `a` never takes `ab/x`), compared in the normaliser's
    spelling and re-keyed under the new prefix; it is read once, before anything
    moves, so a directory just re-keyed is never visited twice. A directory with
    no verified record does not move — a file never captured since the upgrade
    keeps its history under the old key. Per directory: **one directory `move`,
    then a record rewrite** (`replaceRecord`, which leaves a record that already
    verifies as the new path alone and otherwise removes and rewrites it — a
    `move` into place refuses an existing name). A `move` fails in practice
    because the destination exists — a file moved onto a path that has history of
    its own (one deleted earlier), a folder moved onto a folder — and that falls
    back to an **entry-by-entry merge**: sidecars then snapshots are carried, the
    order a capture writes them in; a name present on both sides keeps the
    destination's copy and discards the source's (a snapshot name *is* its
    timestamp, event and hash, so the two are one revision) — and a source copy
    that cannot be removed counts as an entry that did not move, stranding with
    its sidecar and its record rather than being taken for carried; the source's own
    temporaries are discarded; the source's record and its emptied directory are
    then removed through `discard` (the directory only on an empty re-list); the
    destination's record is made correct, which also corrects a wrong one; and
    the merged list is pruned by the ordinary per-file rule, sidecars with their
    snapshots. **A labelled snapshot and its sidecar move as a pair**: the
    sidecar goes ahead as a *copy* and the source's original is removed only
    once the snapshot has moved, so a sidecar that cannot be copied keeps its
    snapshot at the source, a snapshot that cannot move has the copy discarded
    (a discard that fails leaves a spare orphan the sweep reclaims, never the
    only label on the wrong side), and a sidecar the destination already holds is
    discarded only once its snapshot has gone — so no failure at any step leaves
    a label-less row on one side and its only label on the other. A destination
    that is **empty** — what a capture that failed after its `ensureDirectory`
    leaves — is no history to merge into but no reason to stay behind either: it
    is merged into like any other, entry by entry, and never removed, since
    nothing would migrate the source again. Only a listing that *succeeded* says
    what a destination holds: one that cannot be listed — absent, a file, an
    unreadable directory — leaves the source where it was and the destination
    untouched. A foreign entry, or an entry whose
    `move` fails, strands the source directory under a record that still names
    it. **Each directory fails silently on its own**, so one stuck directory
    strands one file's history and nothing more.
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
    `waitForQueuedWrites() async` (public) awaits the chain's current tail —
    the way for a reader on another queue to see the writes already queued
    (`deletedPaths(root:awaiting:)`), and what the quit holds the termination on
    once an external-change answer queued an `.overwrite`/`.discard` capture, so
    that capture lands before the process exits; units appended later are not
    waited for.
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
      one retry answers before the `move` and the sweep's own re-list, taken
      with its removal under the store's `exclusion`, answers after it. A third — **a queued capture of older text landing after
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
    - `followMove(from:to:root:)` — the tree's rename and drag-and-drop move,
      fire-and-forget. Both urls are keyed by `relativePath(of:under:)`; a side
      that cannot be keyed, or two sides that normalise alike, returns without
      touching the chain. Otherwise `store.migrate` is appended, with the clock
      read at entry for the merge's prune. **The ordering argument is the chain
      and nothing else**: the call is enqueued *after* the disk move and after
      `applyRenamePlan` has retargeted the tabs, so a capture appended before it
      (keyed under the old path) lands under the old key and is carried with the
      rest, and one appended after (keyed under the new path, because the tab
      already names it) lands under the new key and finds the carried history
      there to dedup against. No gate: the move is the user's and already done,
      and this writes only the store.
    - `captureBeforeDelete(of:root:bufferTexts:)` — the project tree's delete,
      and **synchronous, not `async`, because that is what makes it pre-delete.**
      The tree's delete raises no writer bracket and has no `Task` hop to put an
      `await` in front of: it removes the item on the main actor right after this
      returns, so a fire-and-forget unit would read the files one hop later,
      after the removal, and find nothing. The reads therefore happen here, in the
      main-thread stretch between the confirmation and `removeItem`, bounded the
      way the pre-operation capture bounds its own — at most
      `maxPreOperationFiles` disk targets, each through `readTextIfNotBinary`
      under the 1 MiB ceiling, binary skipped — and **only the store writes**
      are appended to the chain under `.delete`, with the clock read at entry.
      The delete waits on its own bounded reads and **never on the chain or a
      running sweep**. Buffers win, as in `captureBeforeOperation`. The disk
      targets come from a walk of the item **through `FileServicing`, not
      `ProjectFileWalk`**: no `.gitignore` is honoured, because an ignored
      `.env` is exactly what a user regrets deleting; it descends depth-first in
      listing order and stops at the cap; it skips
      `FileService.isExcludedEntryName` entries, the tree's own rule; it neither
      reads nor descends a symlink (`symbolicLinkDestination(at:) != nil`, the
      item itself included), because deleting a link leaves its target intact;
      and a url that cannot be listed as a directory is the single file. Nothing
      to store returns without touching the chain.
    - `captureLabel(_:root:texts:)` — **Put Label…**, fire-and-forget. The text
      is normalised through `LocalHistoryPolicy.label(from:)` and a refusal does
      nothing at all; otherwise one unit per keyed buffer is appended under
      `.label` with the shared text, so one labelled moment resolves to one label
      wherever it is read. Untouched buffers included — the policy's exemption,
      not this model's — so the label marks the whole moment rather than the
      edited part of it.
    - `canPutLabel(tabURLs:root:)` — the menu's enablement, a `nonisolated
      static` predicate over **urls, never buffer texts**: whether any open text
      tab keys under the root, `false` with no root. The menu asks it on every
      validation pass, and copying every open buffer to answer a yes/no would be
      paid on each menu open for a question the urls alone settle; only the
      action collects texts.

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
    of the pre-operation captures are built from the repository root `git rev-parse
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
    `selectedContent`, `diffRows`, `restorePlan`, `isLoading`, plus the computed `isEmpty` (a
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
    in-flight listing. **Retargeting clears before it loads** — `open(file:root:restorable:)`
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
    `ProjectSearchModel.offMain(_:)` shape.
    **What the file holds "now" arrives as a `LocalHistoryCurrentText`, not a
    `String`, because the two answers cost different things.** When a tab holds
    the file the text is already main-actor state and reading it is a dictionary
    lookup, so it travels as `.text(String)` and nothing is deferred; when no tab
    does, the answer is a disk read under the same 1 MiB ceiling the capture side
    uses, and that read has no business on the main thread, so it travels as
    `.deferred(@Sendable () -> String)` and is resolved **inside the hop this call
    already makes** — beside the revision's content read and the diff, on the same
    private serial queue. Same content, same ceiling, same empty-string fallback;
    one fewer main-thread read. The closure is `@Sendable` because that is where
    it runs, and it is only ever called when there is something to diff: clearing
    the pane takes no hop at all, so a deselection no longer reads a file.
    `PisakaApp.currentTextForLocalHistory` is the one place that decides which
    shape to answer with.
    **The Restore button reads a published plan rather than a predicate.** The
    landed selection keeps the text it resolved and `restorePlan:
    LocalHistoryRestore?` is built from it by `plannedRestore()`; the window
    disables on `restorePlan == nil` and acts on that same value, so the question
    "is this revision worth restoring?" is spelled exactly once and against the
    very text the rows above were computed from. That is what makes the button
    agree with the diff pane it sits under — the previous rule, armed by the
    loaded content and refused at click time by a `restore(currentText:)` that
    re-read the current text, could show an armed button whose click did nothing.
    The plan is `nil` in the four cases where a restore would be a no-op the user
    could not tell from a bug: nothing selected, its content not in hand (a
    revision reclaimed between the listing and the click), a target opened with
    `restorable: false`, and a revision whose text the buffer already holds. The
    app opens a path non-restorable when `WorkspaceModel.acceptsLocalHistoryRestore(_:)`
    says no: the path is — or would open as — a **viewer** tab
    (`opensAsViewer(_:)`), or it opens in the read-only source viewer window
    (`opensInSourceViewer(_:)`, a file inside dependencies no tab holds). A
    restore is a buffer edit, a viewer holds none, and a `.db` reached through
    the tree's context menu or Deleted Files (history carried there by a move,
    or captured while it was a text tab) would otherwise be recreated as an
    empty file and left that way; and a file inside dependencies — history from
    a tree delete or a gated operation's capture of a committed `vendor/` — would
    otherwise be opened by the restore's direct `model.open` as a writable tab.
    The listing and the diff still show, so the bytes stay readable; refusing the identical case is what keeps a
    restore from marking a clean tab dirty and writing a `.restore` snapshot of
    bytes that are already the newest revision. **A file missing from disk is
    never the identical case**: the hop that resolves the current text also asks
    `store.isMissing(root:relativePath:)`, and a missing file's current text is
    the empty string, so without that answer an empty revision — a file deleted
    while empty — would be the one revision of a deleted file Restore could not
    bring back. It is cleared wherever the
    selection is — `open(file:root:restorable:)` and a `nil` selection — and a superseded
    selection publishes no plan, like everything else the generation token
    guards.

    **The plan is re-asked when the window becomes key**
    (`refreshSelection(currentText:restorable:)`, driven by the window controller's
    `windowDidBecomeKey`). Moving the question off the click is what buys the
    agreement above, and the price is that it can go stale — and a stale
    *refusal* is worse than a stale pane. Left alone, a window held open across
    an edit made in the main window greys Restore out for a revision the buffer
    no longer holds, with nothing to un-grey it short of clicking another row and
    back; the click-time question it replaced self-corrected there. Becoming key
    is exactly the moment the user has come back from wherever the buffer
    changed, so the diff and the button are recomputed **together** and still
    agree. Unlike `select(_:currentText:)` the refresh does not clear the panes
    first — there is nothing to hide and blanking them on every focus would
    flicker — but it takes the generation token on the same terms, so a refresh
    and a click racing each other resolve in issue order. No selection means no
    question and therefore no read: a `.deferred` current text is not resolved
    and disk is not touched, which matters because a window becomes key every
    time it is clicked. **A current text that has not moved is not a question
    either**: the `.text(_:)` case — the one that is free to compare — is checked
    against the text the last landed load resolved and returns without taking the
    token at all, because otherwise every focus of the window costs a store read
    and a whole-document `LineDiff` and sets `isLoading`, so the footer's spinner
    flashes on an event carrying no news — the very flicker the refresh avoids by
    not blanking the panes, reappearing in the one place it could. `.deferred`
    cannot be settled without the read it defers and so always re-asks. **The
    short-circuit skips the text, not the disk**: the plan also rests on whether
    the file still exists, and a clean tab whose file is deleted (or recreated)
    behind it holds the same text either way, so a short-circuited refresh still
    re-asks `store.isMissing(root:relativePath:)` off the main actor — one stat,
    no `isLoading`, no token of its own — and re-plans only when that answer
    moved and nothing has taken the token since. Because a load in flight and
    every short-circuited focus ask that existence question under **one**
    generation, its answers carry a **token of their own** (`missingCheck`,
    bumped as each is asked): only the newest publishes the missing flag, and a
    load whose answer was overtaken publishes the rest and plans from the newer
    one — the serial queue lands them in order today, and the token makes that
    the rule rather than an accident of the queue. That
    sameness test is `NSString`'s, not Swift's:
    `==` on `String` compares by canonical equivalence, while a revision is
    identified by a SHA-256 over its *UTF-8 bytes*, so a decomposed and a
    precomposed spelling are two real revisions the store keeps apart — and a
    canonical comparison would arm Restore and then plan nothing, which is the
    one no-op that *is* a bug (`SaveTransformController.applyRestore` guards the
    same hazard one layer up). **Restorability is re-asked on the same occasion**
    (the refresh's optional `restorable`, applied before anything else): the answer `open`
    was given is the tab kind the path had *then*, and a text tab renamed to
    `.db` that closes while the window stays open hands the path to the viewer.
    A moved answer re-plans synchronously from the landed selection — the
    missing-file answer is kept beside the resolved text for this — so the click
    that made the window key reads a corrected plan, and the app's viewer
    refusal stays the backstop rather than the thing a user meets. `LocalHistoryRestore` is **a plan, not an
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

    **Labels and deleted files.** Published `labelTexts` maps a snapshot file
    name to its loaded label text and is cleared on every `open(file:root:restorable:)`.
    `loadLabel(for:)` fills it one row at a time with an off-main
    `store.labelText` read, and **does not take the generation token**: a label
    is decoration on a row the listing already published, and a row appearing
    must never cancel the listing or content load in flight. What it checks
    instead is narrower and sufficient — the browser still targets the same root
    and relative path when the read lands — so a label read for one file never
    decorates another file's row of the same name. It is a no-op for a
    non-`.label` row and for one already asked about (an unreadable sidecar
    included, so it is read once per targeting rather than on every appear).
    `title(for:)` answers `"Label: <text>"` once the text is loaded and the
    event's own title otherwise — the one place a row's title is decided.
    `deletedPaths(root:awaiting:) async` is what Deleted Files… offers: it first
    awaits the capture model's queued writes (`waitForQueuedWrites()`), so a
    delete's capture — and, for a file never captured before, its path record —
    has landed and the file just deleted is listed on the first try rather than
    the next; then, off the main
    actor, `store.recordedPaths` filtered by `store.isMissing`, sorted by path,
    `[]` with no root or an unreadable store — computed on demand and **never
    stored**, because it is one answer to one menu command, not window state.

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
    **Chrome (part five (b), `core-theme.md`).** Gated, naming no role: it
    constructs `EscClosableWindow`, whose designated initializer paints the
    window's `bgPanel` ground, and sets none of its own.
  - `LocalHistoryView.swift` — the window's contents: revisions on the left, the
    selected one diffed against what the file holds *now* on the right, a Restore
    button under the list. **It observes `LocalHistoryBrowserModel` alone** — the
    capture model publishes nothing and a window that observed it would re-render
    on captures it does not show, which is the whole reason the browser is a
    companion model rather than more members on its owner. **The current text
    arrives as a closure, read at the moment it is needed**: the window outlives
    edits to the file it is showing and outlives a folder switch, so the "new"
    side of every diff has to be asked for rather than captured. The closure
    answers a `LocalHistoryCurrentText` rather than a `String`, so the disk half
    is itself deferred and this window never reads a file on the main actor;
    which shape it answers with is `PisakaApp`'s decision, not the view's. Each
    row shows
    its title and the timestamp **twice** — relative ("2 hours ago") is how
    a user finds the edit they remember making, absolute is how they tell two of
    them apart. **The relative reading is measured against one date the window
    owns**, held as `@State`, refreshed on a 60 s timer and passed into every
    `RevisionRow`, whose `body` therefore reads no clock. A row's **title is
    `browser.title(for:)`**, handed down like `now`, and each row calls
    `browser.loadLabel(for:)` when it appears, so a `.label` row's sidecar is read
    only once that row is on screen and its title becomes "Label: <text>" when the
    read lands. A `body` that calls
    `Date()` is only correct at the instant SwiftUI happens to evaluate it — rows
    re-render when the model publishes, not when time passes, so a window left
    open goes on reading "just now" about an edit made an hour ago, and two rows
    re-rendered in different passes disagree about what "now" is. One instant
    passed down makes every row consistent; the timer is what makes them true,
    and a minute is the resolution the relative wording has, so a shorter tick
    would re-render the list for no visible difference. The `DiffView` is keyed
    by the revision's own file name (so
    switching rows rebuilds the panes wholesale) but named with the *file's* name
    (which is what selects the syntax language; a snapshot's own name is a
    timestamp with a `.snapshot` extension and would highlight as nothing).
    **Restore reads the model's published plan, for its enablement and for its
    action alike**: the button is disabled on `restorePlan == nil` and hands that
    same value to `onRestore`, so this view decides nothing about it and the
    button cannot disagree with the rows above it — both are answered from the
    text the diff was computed against. Pressing it also re-asks
    `select(_:currentText:)` with
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
    **Chrome (part five (b), `core-theme.md`).** Gated. The root resolves colours
    through a private `chromeColor(_:)`, holding no `\.chromeTheme` in its
    struct; the revisions list is inset with a hidden scroll background and
    `bgPanel` row backgrounds — except the selected row, which yields its
    background (`Color.clear`) so the platform's selection shows: on macOS a row
    background is drawn over the selection box, and the selected row is the one
    Restore applies (`core-theme.md`, rule thirty-five); the
    empty-state and "Select a revision" texts are `textSecondary`; the footer's
    former `Divider()` is a `hairline` rule; Restore is `.chromeSecondary`,
    keeping its plan-driven enablement. `RevisionRow`, at file scope, reads
    `\.chromeTheme` as a child: title `textPrimary`, time line `textSecondary`.
    The revisions/detail split is the shared `ChromeSplitView` (`core-theme.md`,
    *The shared split*): the revisions list is the leading pane at 220/260/380,
    scaled, against the detail's scaled floor of 360, and the divider is the
    `hairline` role; chrome rule forty-eight keeps the platform split out.
  - `LocalHistoryPrompts.swift` — the two modal questions the File menu's new
    commands ask, `NSAlert`-based the way `FilePanels` hosts the delete
    confirmation, and **deciding nothing of their own beyond asking
    `LocalHistoryPolicy.label(from:)`**. `askLabel()` has a text-field accessory
    whose "Put Label" button is enabled only while that function accepts the
    field's text (a small `NSTextFieldDelegate` keeps the two in step), so a
    confirmed answer is always one the capture will take; Cancel answers `nil`.
    `chooseDeletedPath(from:)` shows the paths it is handed — already sorted by
    the browser model — in a pop-up accessory, and answers the chosen one or
    `nil`; an empty list is a fact rather than a choice, so it shows a short
    informational alert ("No deleted files with history in this project.") and
    opens nothing. Neither prompt writes anything; the caller acts on the
    answer. The file carries the `LocalHistory` prefix so the gating suite
    covers it by name, and it names no writer gate and no `revertInFlight`.

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
  - **Nine gated operations, seven brackets, seven pre-operation captures**:
    `commitFromDialog`
    (pre-empting a formatting `pre-commit` hook — the one way a commit rewrites
    the working tree, and the reason the open-tab resync is not enough on its own,
    since the resync can put the hook's text into the tab but the *pre-hook* text
    is then gone from everywhere), `replaceAllInProject` (the one worktree writer
    here that is not git, and the one whose result no `git checkout` can undo),
    `revertChanges` (the operation whose whole purpose is to destroy text, so the
    one a safety net most owes an escape hatch), `createBranch` and
    `runBranchOperation` (two functions, two brackets — and the second is the one
    bracket serving *two* operations: branch switch/checkout-remote pass
    `.branch`, while the Pull Requests coordinator passes `.pullRequest` for
    `gh pr checkout`, the **eighth** gated operation, and `.pull` for the
    post-merge tail's `pull --ff-only`, the **ninth** — the tail's own branch
    switch is a third `.branch` caller, so one bracket now serves four call sites
    and three events, which is why the event parameter exists at all and why the
    bracket count stayed at seven, `core-github.md`), `applyMerge` (one target: the file being resolved, whose conflict
    markers and any hand-editing inside them vanish the moment the apply
    succeeds), and `applyRename` — **the seventh, and the second one that is not
    git**. It is the operation this net most obviously exists for: a language
    server's `WorkspaceEdit` rewrites files across the whole project, most of them
    behind no tab, and *no git command can undo it* — the worktree it changes is
    the one the user was working in. It is also the only gated operation whose
    undo story is incomplete by design (decision 5 in `core-lsp.md`): the tab on
    screen gets one undoable step, every other open tab loses its undo stack, and a
    file no tab holds changes on disk with no undo at all — so the "Before Rename"
    revision *is* the recovery story rather than a second one. It is still capped
    like every other pre-operation capture: `maxPreOperationFiles` (200) disk files,
    binary and oversize ones skipped silently. The cap's own rationale (latency in
    front of an operation the user asked for) argues for raising it here, where the
    target set *is* the write set and no git command is waiting — recorded as a
    follow-up rather than changed silently, and the rename's incomplete-write alert
    is worded so it promises nothing the cap can falsify.
    Each is one line through a private `captureBeforeOperation(_:buffers:targets:)`
    helper that adds no decision of its own, so each site reads as a statement of
    what it is pre-empting. The buffer half is `openBufferTexts()` (every open
    titled tab, collected in the same synchronous stretch as `openTabSnapshot()`)
    and the disk half is `changedFileURLs(_:root:)` over rows Local Changes
    already holds — no second traversal and no new git call — except Replace All,
    which uses `ProjectSearchModel.results`, the merge apply, which names one
    file, and the rename, which names `RenameEditPlan.fileURLs`: the plan's own
    files, which are exactly the set the write that follows touches. The rename's
    capture is additionally the **last moment anything can still abort cleanly** —
    the whole-plan staleness verification runs *after* it, deliberately, because
    the capture must be the first `await` in the bracket and verifying first would
    leave a window in which the verified text could move. An aborted rename
    therefore leaves one harmless extra snapshot behind, which retention prunes.
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
    stops, like the two refusals below; the same first step refuses a path that
    `model.acceptsLocalHistoryRestore(_:)` refuses (a viewer tab, or a file the
    source viewer window would show), the backstop behind the window's
    non-restorable open. **Then the recreate exception: a restore
    is a buffer edit, except that a restore into a path with no file first
    creates an empty file, under `revertInFlight()`.** The action asks
    `localHistory.store.isMissing(root:relativePath:)` first, and the preflight's
    two refusals are asked **before** anything is created — against the empty
    file the create would make (`localHistoryTextToDisplace(_:missing:)` answers
    `""` for a missing path no tab holds, and the buffer when one does) — so a
    refused restore creates nothing. When the path is missing and the preflight
    passes, the action consults `revertInFlight()` — the create is an ordinary
    project-tree write, so it obeys the gate the way the tree's own create does,
    and *consults* it without raising it. If a gated operation holds the gate,
    that consult beeps and shows the "Git operation in progress" notice, the same
    refusal the tree's own file operations give, and the action stops, creating nothing
    and opening nothing. Otherwise it `ensureDirectory`s the parent and `createFile`s through the
    file service (beeping and stopping on failure) and bumps the tree either way,
    since `ensureDirectory` does not roll back the parents it built. The tab's
    disk stamp is then refreshed (`refreshDiskStamp(for:)`): the create is the
    app's own write, and a tab that outlived the delete still holds the deleted
    file's stamp, so the save below would otherwise read the empty file as an
    external change — reloading a clean tab to `""` and writing that back, or
    putting a dirty one in conflict. Everything after runs unchanged against the empty file: the open, the re-asked refusal, a
    "Before Restore" capture of the empty text it displaces, and `applyRestore`.
    Both refusals are asked with `recreating:` set for a missing path, which
    exempts them from the sameness half only (the policy half still applies) —
    the plan's own exemption, so an **empty revision recreates the empty file**
    rather than being refused as identical to the empty text it displaces. A
    clean tab outlives its file's out-of-band delete, and when it already holds
    a non-empty revision the restore changes nothing in it and would leave it
    clean over the empty file just created — so a recreating restore that leaves
    its tab clean and non-empty **saves that tab** through `save(id:)`, the same
    funnel a dirty tab's autosave takes. When that save fails (it has beeped) the
    tab's baseline is re-read from the empty file with `reconcileSavedBaseline`,
    so the tab turns dirty and the autosave or ⌘S retries the write, rather than
    a clean tab claiming bytes the disk does not hold. This is the feature's **one worktree create**;
    without it a `.delete` revision — and the `Before Revert` / `Before Branch
    Change` revision of a file the operation removed — could be listed and never
    brought back. Then: open a tab
    if none holds the file (`model.open` re-selects an existing one, so it is also
    the right call when one is there; an unreadable file beeps and stops, since
    there is nothing to restore *into*), capture the displaced text under
    `.restore` — read back off the buffer **after** the open, `model.text(for:)`
    being exactly what `applyRestore` displaces — but first **re-ask the plan's
    sameness question against that buffer**, because it is the one thing in the
    plan that can have gone stale since the window last resolved it. The
    published plan is refreshed when the window becomes key; a buffer can move
    without that happening (an FSEvents-driven `reloadFromDisk`, a
    `resyncOpenTabs` after an operation, a rename — all while this window stays
    key), and a plan stale that way re-creates the armed-button-whose-click-does-
    nothing the published plan exists to remove, with a side effect on top:
    `applyRestore` bails at its own `NSString` guard, but the capture in front of
    it has already filed a `.restore` revision of bytes nothing displaced, since
    `LocalHistoryStore.capture` dedups against the *newest* revision only. So a
    displaced text already equal to `plan.text` beeps and stops, before the
    `captureBuffers` that would file it — the same byte-wise `NSString` comparison `plannedRestore()` and
    `applyRestore` make, for the same reason. The enablement stays the published
    plan's; this is the refusal behind it, not a second answer to it. The plan's
    `captureText` is
    the fallback when there is no buffer to ask; taking the plan's answer outright
    would store the empty string the *window* had to show for a file that has
    since grown past its 1 MiB read ceiling, which is the one place in this
    feature a capture could lose what it exists to keep — then
    `saveTransform.applyRestore(…)`. **A restore the policy would refuse to
    capture does not happen at all**: the displaced text is put to
    `store.policy.capture(of:relativePath:latestHash: nil, event: .restore)` first, and a refusal
    beeps and stops exactly as an unreadable file does. Reading the buffer back
    fixes *what* is snapshotted, not whether it can be — a file that had history
    when it was small and has since grown past `maxContentBytes` is captured by
    nothing, so going ahead would replace megabytes with one ⌘Z as the only copy,
    and it is also the case the window renders least honestly (the same ceiling
    makes the current side of the diff the empty string, so the revision showed
    as wholly added). `latestHash` left at its `nil` default asks the one question that matters —
    *may* these bytes be stored — rather than whether they would be
    deduplicated, which is a skip that loses nothing. **Both refusals are asked
    twice, and the first ask comes before the open**
    (`localHistoryRestoreRefused(displacing:_:)`, one function so the two moments
    cannot drift): `model.open` is not free of consequence, since it selects the
    tab holding the file and, for a file no tab holds, adds one, so asking only
    afterwards turns a click that does nothing into a click that pulls the editor
    onto another file and beeps — the armed button the published plan exists to
    remove, wearing a side effect. The text the pre-open ask judges comes from
    `localHistoryTextToDisplace(_:)`: the buffer when a tab holds the file, and
    otherwise the *same unbounded* `FileServicing.read` the open itself is about
    to make — deliberately **not** the window's `readTextIfNotBinary`, whose
    ceiling is `LocalHistoryPolicy.maxContentBytes` to the byte and would
    therefore answer the empty string for exactly the file the policy is about to
    refuse as `tooLarge`, waving through the one case the preflight most needs to
    catch. The cost is that a successful restore of a file no tab holds reads it
    twice, bounded by that same ceiling (anything above it is refused before the
    open) and paid once per Restore click. The refusal is still re-asked *after*
    the open, which stays the authority: it is the text the capture and the
    replacement actually act on, and the file can move between the two reads.
    The tab is
    left **dirty**: the ordinary save funnel puts the restored text on disk when
    the user saves or the autosave fires, which is what keeps this feature a
    reader that takes no writer gate.
  - **Four open sites, one window.** File ▸ Local History… (⌘⇧H), disabled without
    a *titled, text* selected tab — stricter than every other item in that group
    on purpose, because an enabled item over an untitled buffer would open a
    window saying the file has no history when what is true is that it has no
    file. The tab-kind half is the stronger of the two: a **viewer** tab holds no
    buffer, so `text(for:)` answers the empty string for it, and a Restore would
    file a revision claiming that database's contents were `""` — the very
    snapshot `openBufferTexts()` skips a viewer tab to avoid — before an
    `applyRestore` that is a no-op for the kind restored nothing. Reachable, too:
    a `.db` that is not SQLite was an ordinary text tab before the viewer existed
    and can carry real revisions. Alongside it,
    a "Local History" item on a project-tree file row's context menu, threaded
    from `ContentView` as `onShowLocalHistory`; a "Local History" item on a
    tab's context menu, enabled by `TabCloseRule.MenuAvailability` under the
    same titled-text condition for the tab the menu was opened on and threaded
    as `TabActions.showLocalHistory`; and File ▸ **Deleted Files…**
    (below). All four go through one
    `showLocalHistory(for:)`, which starts the listing *before* showing the window
    (one directory read on a background queue) so an already-open window never
    shows the previous file's revisions for a frame.
  - **Two flat File-menu items directly below Local History…, with no
    shortcuts** — the existing item and its ⌘⇧H are untouched and no submenu is
    introduced. **Deleted Files…**, disabled without a project, awaits
    `localHistoryBrowser.deletedPaths(root:awaiting: localHistory)`, drops the answer if the folder was
    switched meanwhile (it names files of the previous project), asks
    `LocalHistoryPrompts.chooseDeletedPath(from:)` and opens the window on
    `root.appendingPathComponent(choice)` — a file that does not exist, which the
    window handles like any other target, and which Restore then recreates.
    **Put Label…** is enabled by `LocalHistoryModel.canPutLabel(tabURLs:root:)`
    fed the urls of `model.openFiles`' text-kind tabs — **never
    `openBufferTexts()`, so validating the menu copies no buffer** — and its
    action asks `LocalHistoryPrompts.askLabel()` and hands the answer to
    `localHistory.captureLabel(_:root:texts: openBufferTexts())`, the only place
    the label feature collects buffer texts.
  - **The project tree's delete is a capture site.** In `deleteItem`, after the
    confirmation and the affected-tab collection and **before
    `fileService.removeItem`**, `localHistory.captureBeforeDelete(of:root:
    bufferTexts:)` is called — not awaited — with `openBufferTexts()` restricted
    to the affected tabs' urls. It reads synchronously and writes in the
    background (the model entry says why), and the delete still raises no gate
    of its own. The site is named rather than numbered: three save sites plus
    seven brackets already make ten, so "the tenth capture site" would be a
    count that does not add up.
  - **The project tree's move carries the history.** In `performMove` — the one
    funnel for both the rename and the drag-and-drop — after `fileService.move`
    has succeeded and `applyRenamePlan` and the database viewers' retargets have
    run, `localHistory.followMove(from: source, to: destination, root:)` is
    called. That position is the model's ordering argument: the tabs already
    name their destinations, so every capture enqueued after it keys to the new
    path.
  - **The store sweep** runs from the folder-open path (`pruneStore()`),
    fire-and-forget: capture already prunes the one file it just wrote, and
    without this a project abandoned for a month would keep every snapshot
    forever. It sweeps the **whole store**, not the project being opened — the
    per-project sweep it replaced could not reclaim a project nobody reopens,
    which is precisely the case the retention promise is made for — and it removes
    a file directory, then a project area, left with nothing in it.

## The pre-operation capture is race-free by construction

Every one of the gated operations already has the shape this needs, because
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

268 tests across seven suites in `Tests/PisakaCoreTests/`, all against
`StubFileTree` or pure values — no temporary directories and no real clock:

  - `LocalHistorySnapshotTests` — the tag vocabulary by set equality, every event
    round-tripping through its tag (`delete` and `label` included), the "Before"
    title rule restated as every pre-operation event, newest-first
    ordering including the same-millisecond tie-break; `.overwrite` and
    `.discard` carrying lowercase, dash-free tags that round-trip through a name.
  - `LocalHistoryLayoutTests` — name round-trips for every event; lexical name
    order equal to chronological order across millisecond, second and day
    boundaries; every malformed-name shape parsing to `nil`; two roots and two
    relative paths giving different directories while one input gives the same
    directory twice; `contains` accepting everything the layout produces; the
    readable project-name prefix bounded in **bytes** rather than characters (an
    emoji and a ZWJ-sequence root name); the record named `path` holding the
    normalised path, and the normaliser being the digest's own spelling; the
    record verifying only against its own digest directory, a mismatched, empty,
    absolute or non-normalised text decoding to `nil`; the sidecar name codec
    round-tripping and accepting only a parseable snapshot name plus `.label`;
    neither `path`, `path.partial`, a sidecar nor a sidecar temporary parsing as
    a snapshot; the temporaries predicate accepting exactly the three own shapes
    and refusing a foreign `.partial` and the finished names. The activity
    record: named `activity` in the project area and never parsing as a
    snapshot; its text round-tripping; the decode deduplicating, sorting and
    keeping the newest fourteen, and answering `nil` for anything unparsable; the
    day spelling ignoring the calendar's era.
  - `LocalHistoryPolicyTests` — each skip reason in isolation and every
    precedence pair between them; exactly 1 MiB captured and one byte more
    refused, counted in UTF-8 bytes (a multi-byte case included); the retention
    rules including "the newest survives even when it is itself expired" and "age
    is applied before the count cap"; the stated defaults as documented numbers;
    a `.label` capture of content equal to `latestHash` still captured while
    every other event (set over `allCases` minus `.label`) skips as
    `.unchanged`, and a label still refused on every other ground; the label
    rule — trimming, empty and whitespace-only refused, exactly 100 characters
    accepted and 101 refused, an interior line break refused — and its ceiling
    as the documented number. Activity-day retention: a revision twenty days old
    with three later activity days surviving; fourteen later days plus an
    expired calendar age deleting, thirteen being one short, and fourteen inside
    the calendar window still surviving (the AND); the revision's own day not
    counting; two minutes across midnight being two days under the injected
    calendar; no record giving exactly the calendar result; the newest surviving
    every record and the count cap still applying under one; the two
    external-change events obeying the ordinary skip rules.
  - `LocalHistoryStoreTests` — capture/list/read round-trip; a second identical
    capture writing nothing (asserted on `writtenPaths`); one changed byte being a
    new revision; the write going through a temporary name and exactly one `move`;
    an injected failure leaving no partial file and throwing nothing (every
    attempt cleaning up after itself, twice over); a capture whose directory is
    reclaimed mid-write succeeding on its retry — the sweep-versus-quit-capture
    window, staged with `StubFileTree.onWrite`; capture
    pruning the same file's excess; `prune(root:)` bounding a whole project area;
    the activity record written once per day, never by a skipped capture, held to
    fourteen days, keyed per project (another project's activity ages nothing
    here), read once per project prune and never listed by a capture; the sweep
    sparing and reclaiming by activity days as the policy does, a missing or
    garbled record giving exactly the calendar result; an area holding only the
    record removed with it and one with a foreign entry beside it kept; the
    injected time zone deciding which day a capture notes;
    `pruneAll()` bounding a project area **no root was handed for**, removing an
    area left empty and leaving one holding a foreign entry alone; a never-captured
    file listing `[]`; a foreign file ignored by listing and left alone by pruning;
    the sweep reclaiming an interrupted write nothing else can see, and removing a
    directory that holds nothing but such debris. The path record: the first
    capture writing it through a temporary and one extra `move`, a second
    capture writing nothing and reading no record (`readPaths` excludes `path`);
    a dedup'd capture into a record-less directory writing it, a refused
    capture into an empty one not; a present-but-wrong record left byte-for-byte
    by capture and skipped by `recordedPaths`. Labels: the sidecar written
    before the snapshot (the order of `moves`), the same text labelled twice
    being two revisions, only text the policy accepts reaching the disk, a
    sidecar that cannot be written losing the revision, and retention — at
    capture and at the sweep — taking a sidecar with its snapshot. The sweep
    reclaiming a record-only directory, orphan sidecars and every own temporary
    (`path.partial` and a sidecar `.partial` included) while leaving a record
    beside a foreign file alone. The readers: `recordedPaths` listing only
    verified records and `[]` for an unreadable or absent area; `isMissing`
    true for an absent file and false for a present one; `labelText` `nil` for
    a missing or invalid sidecar and reading nothing for other events.
    Migration: a file rename carrying every revision with its name, timestamp
    and event and rewriting the record; a folder move re-keying every recorded
    descendant while a record-less one stays under its old key; prefix `a` not
    moving `ab/x`; a merge into an existing history keeping the destination's
    copy on a name clash and pruning the merged list by the per-file rule; a
    merge into a destination holding a wrong record leaving a correct one;
    sidecars carried ahead of their snapshots; an injected `move` failure
    leaving the source intact and listable under its old key, and a merged
    entry that cannot move staying behind under its record; a foreign file in the
    source keeping its record and directory while the merge's own debris is
    discarded; an empty directory under the new key merged into, the whole
    history carried into it, label included; a file or an unreadable directory
    under the new key left untouched with the source still under its old key; a
    labelled pair stranded together at the source when either its sidecar or its
    snapshot cannot move, still labelled at the source when the copy's cleanup
    and every way back fail too, and a stranded snapshot keeping its own sidecar
    over a destination copy; a
    move onto itself doing nothing. A quit-time capture landing as the
    sweep removes a record-only directory's record keeping its snapshot, and the
    next capture writing the record again.
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
    A delete capture held on the chain: the non-awaiting `deletedPaths(root:)`,
    asked while the capture is held, answers `[]`, and its return through the
    browser model's serial queue is the barrier behind which an awaiting form
    that did not wait would already have answered; `deletedPaths(root:awaiting:)`,
    started before it, lists the deleted file once the chain is released — no
    timed window.
    `followMove`: a capture queued before it carried and one queued after landing
    under the new key (a `Gate` on a listing as the causal rendezvous, then
    `chain?.value`), and an unkeyable side not extending the chain.
    `captureBeforeDelete`: every disk target read by the time it returns
    (`readPaths`), the `.delete` snapshots holding the pre-delete text after the
    files are removed from the stub; a buffer beating its disk copy; a folder
    capped at a small `maxPreOperationFiles`, a buffer-held file spending none of
    that cap and read from nowhere; binaries, symlinks and excluded
    entries skipped; a single-file url captured; nothing to store leaving the
    chain untouched; a capture appended after it landing after it.
    `captureLabel`: three buffers (two edited, one untouched) giving three
    `.label` revisions each with a sidecar of the same text, and a second
    identical call three more; a refused label writing nothing. The enablement
    predicate, fed urls only: false with no root and for only untitled or
    outside-root urls, true for one project file.
  - `LocalHistoryBrowserModelTests` — a stale listing unable to publish over a
    newer one (two loads staged with `Gate`, the older released last); a stale
    content load discarded even when it finishes last (the signal waited on is a
    *later* load landing, never a count of hops); retargeting clearing the
    rows; a file with no history landing `isEmpty` rather than an error; a file
    outside the root targeted but unkeyed (`isUnsupportedTarget`); clearing an
    already-clear selection unable to cancel the listing in flight; the diff
    rows for a selection; the restore plan carrying both texts, `nil` for no
    selection and for an identical revision of a file on disk, an empty revision
    of a missing file still planned (and disarmed once the file exists), and a
    revision differing from the buffer only by Unicode normalization still planning a restore (the store keys
    on UTF-8 bytes, so canonical equivalence is the wrong question).
    `deletedPaths` sorted, excluding existing files and record-less directories
    (a wrong record included), and `[]` for no root and for an unreadable store; a loaded label
    titling its row "Label: …" while an unreadable one — its read observed
    through `Gate` — keeps "Label"; a label read once per targeting, not on every
    appear; a label
    read landing after a retarget discarded (`Gate` rendezvous); a label load
    not cancelling the listing in flight; a retarget clearing the loaded labels.
  - `LocalHistorySourceGatingTests` — the app layer's architectural rules, matched
    against comment- and literal-stripped source the way every sibling suite does:
    every app-side file, the prompts file included, inside `#if os(macOS)`; the store base spelled in exactly
    one place; **`captureBeforeOperation` named exactly seven times against
    `autosave.suspend()` and `localChanges.beginRevert()` also seven times each** —
    count equality over the bracket, so a new gated *bracket* cannot be added
    without a capture (an operation routed through an existing bracket, as
    `gh pr checkout` is, moves no count and is instead pinned by
    `GitHubSourceGatingTests`' one-site rule) — **and the two sets asserted to alternate by source offset**,
    gate then capture, because counts alone stay green on exactly the arrangement
    the rule exists to refuse: two captures inside one bracket and none inside
    another; the save capture at exactly the three save sites; `onSaved?(`
    invoked at exactly three places in `AutosaveController.swift`, so no write path
    can go unreported again; the quit branch still skipping the probe; the restore
    routed through `SaveTransformController` with no second file naming
    `beginSaveTransformRewrite`/`replaceCharacters`; the restore asking
    `policy.capture(` exactly once, so it cannot replace a buffer the store would
    refuse to snapshot; all four open sites present (the File menu item, the
    tree's row, the tab menu and Deleted Files…); the project tree's delete capture,
    `captureBeforeDelete(` named at exactly one site, inside `deleteItem`, before
    that body's `removeItem(` and never awaited or handed to a `Task` or a queue
    ahead of it — that number pinned cross-file against this sentence; the
    restore's recreate asking `isMissing(` before its refusal, and both the
    refusal and `revertInFlight()` ahead of its one `createFile(`; the gate it
    consults being `revertInFlight()`, whose body beeps and runs the notice only after
    its pass-through return, with
    the restore never reading `localChanges.isReverting` itself and no
    `PlatformFeedback.warning()` between that consult and the create, so nothing
    beeps twice; `followMove(` named once, inside `performMove`, after
    its `fileService.move(`; the window declaring no zoom surface; the window
    closed at termination; and Local History — the prompts file included, by name —
    never naming `autosave.suspend`/`beginRevert`/`revertInFlight` anywhere.

## Known limits

- **Only what this app writes is captured.** A save through the app's own funnel,
  the nine worktree operations, the project tree's delete and Put Label… are the
  whole capture surface: an edit made in another editor, a `git checkout` run in
  the embedded terminal or in another window, or any other out-of-band write is
  not seen and leaves no revision. (An external change *to an open tab* is
  seen by the external-change check, and the one revision it can cause is the
  side an Overwrite or a Reload gives up — never a mirror of the other writer's
  edits as they happen.) Likewise only the project tree's own rename
  and drag-and-drop move carry a history; a file moved or deleted anywhere else
  (Finder, `git mv`, the terminal) leaves its history under the old path, where
  Deleted Files… still finds it if its record is there. The
  FSEvents watcher exists to keep the *tree* current and is deliberately not
  wired to this — snapshotting every external write would turn a safety net for
  the user's own edits into a mirror of the filesystem.
- **The store holds copies of file contents on the local disk**, unencrypted, in
  `~/Library/Application Support/Pisaka/LocalHistory`, for at least 14 days and
  until 14 *activity days* of that project have followed (14 calendar days when
  no activity record is readable), and at most 30 revisions per file — so a
  project left alone keeps its history until it is worked on again. Anything a captured file contained — including a secret
  committed by accident and then removed — is in there until retention reclaims
  it, **except the newest revision of each path, which retention never reclaims**
  (policy rule 3): the store settles at one revision per path ever captured, not
  at nothing. Deleting that directory removes the feature's data completely and
  breaks nothing, and it is the only thing that does; there is no in-app "clear
  history" command, because the directory *is* the state.
- **A pre-operation capture reads at most 200 files from disk.** Open buffers are
  never capped, but in a worktree with more than 200 changed files the disk half
  is truncated, and which 200 is the order the caller handed them in. The bound is
  latency in front of an operation the user asked for, not storage. The tree's
  delete capture shares it: deleting a folder holding more than 200 files
  snapshots the first 200 a depth-first walk in listing order meets, and the
  rest are deleted with no "Before Delete" revision.
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
  is the through-the-view one. A restore that **recreates** a deleted file is
  always the fallback path — the file has no tab until the restore opens one —
  so there is no ⌘Z step back to the empty file; `applyRestore` is unchanged by
  decision, and the "Before Restore" revision of the empty text is the way back.
- **A record-less directory neither follows a move nor appears under Deleted
  Files….** A file directory written by an earlier version and not captured since
  the upgrade has no `path` record, and one holding a **wrong** record (a crash
  between a migration's directory move and its record rewrite) is treated
  exactly as if it had none. Either stays readable forwards — ⌘⇧H on that path
  still lists it — but a rename or move leaves it under the old key, and a
  deleted file whose history is only there is not offered. A file's first capture
  after the upgrade writes its record; only a migration corrects a wrong one.
- **The revisions *list* does not refresh itself.** `revisions` is listed once, by
  `open(file:root:restorable:)`; a revision written while the window is open — an autosave,
  a gated operation, or the `Before Restore` snapshot the Restore button itself
  takes — is in the store but not in the list until ⌘⇧H retargets the window.
  The *selection* is a different matter and does refresh, on becoming key: its
  right-hand side is the live buffer, and the Restore button's enablement is
  computed from it, so that one is an action going stale rather than a listing
  (see the `refreshSelection(currentText:restorable:)` note above).
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
