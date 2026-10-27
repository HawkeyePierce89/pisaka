# PisakaCore — files, paths & workspace

Design documentation moved verbatim from the root `CLAUDE.md` (which now holds a per-file index and the cross-cutting invariants). Each entry records a file's contract, invariants and the reasoning behind non-obvious decisions — read the relevant entry before modifying that file, and update it when behavior changes.

- **`PisakaCore`** (library, `Sources/PisakaCore/`) — all domain logic. Pure,
  testable, no SwiftUI/AppKit views.
  - `OpenFile.swift` — model of an open file: `id` (UUID), optional `url`,
    `displayName` ("Untitled" when no url), `text`, `savedText`, a `kind`
    (`.text` or `.viewer`) and `isDirty`. For a `.text` tab — every tab this
    document otherwise describes — `isDirty == text != savedText`. A `.viewer`
    tab is the database viewer's; it is constructible only through
    `init(id:viewerFor:)`, carries no text, and its `isDirty` is `false` *by
    construction* rather than by comparison. Full entry in
    `core-database-viewer.md`. A text tab also carries `diskStamp: FileStamp?` —
    the file's stamp as of the moment `savedText` was last set from, or written
    to, the disk — which is what the external-change check compares against (see
    `ExternalChangeRule.swift` below). Only `WorkspaceModel` moves it, at the
    same baseline sites that move `savedText` and through the same helper that
    bumps `diskRevisions`, so the two never disagree about when the baseline last
    moved. It is `nil` for an untitled buffer, for a viewer tab (forced by its
    initializer) and for a file whose volume reports no stamp — which the check
    reads as "unknown, compare the content", never as "unchanged".
  - `FileService.swift` — disk read/write (`read(url:)`, `write(_:to:)`),
    directory listing (`contentsOfDirectory(at:)`), and symlink resolution
    (`symbolicLinkDestination(at:)` — the link's target string without
    dereferencing, defaulted to `nil` in a protocol extension so non-symlink-aware
    stubs are unaffected), behind the `FileServicing`
    protocol so tests can inject a stub that simulates read/write/listing
    failures. `contentsOfDirectory(at:)` returns `[DirectoryEntry]` (a public
    `Identifiable`/`Equatable` model: `url`, `isDirectory`, and a computed
    `name` from `lastPathComponent`). Dotfiles are *visible*
    (`.gitignore`/`.github` are ordinary, editable entries); only the service
    entries listed in the `excludedEntryNames` constant (`.git`, `.DS_Store`) are
    filtered out, compared by *exact* name through the public
    `isExcludedEntryName(_:)` predicate — one source of truth shared by the
    listing and by the tree's rename validation, so a name the tree would
    never show can't be created through it and silently vanish. That one
    `excludedEntryNames` set backs *two* documented predicates: the exact-match
    `isExcludedEntryName(_:)` above (the listing and rename — git/Finder write the
    exact names, and hiding a user's own `.Git` folder would be wrong) and the
    stricter, *case-insensitive* `isReservedCreateName(_:)` used to validate a
    create path (`parseRelativeEntryPath`), because on a case-insensitive volume
    (the APFS default) a component spelled `.GIT` resolves onto an existing `.git`
    — creating through it would write inside the hidden repository directory and
    the new entry would never appear in the tree. The rest are sorted
    directories-first, then by name case-insensitive. Five mutating operations back the writable project tree —
    `createFile(at:)`, `createDirectory(at:)`, `ensureDirectory(at:)`,
    `move(from:to:)`, and
    `removeItem(at:) throws`: `createFile`/`createDirectory` throw on an existing
    path (never clobber) and let a missing/unwritable parent's `FileManager`
    error propagate; `createDirectory` does *not* create intermediates (the
    parent must exist); `ensureDirectory(at:)` is the `mkdir -p` shape the
    relative-path create needs — it recurses *upward* first (an existing directory
    returns immediately, an existing non-directory throws
    `FileServiceError.notADirectory(name:)` naming that component, a missing one
    ensures its parent then creates itself), so a file sitting anywhere on the path
    is detected *before* any directory is written; directories created before a
    *later* step fails are **not** rolled back (`mkdir -p` semantics), and a
    **symlink to a directory** on the path is *reused*, not refused (the
    existence/type probe dereferences the link, so the chain continues inside its
    target — deliberate, matching `mkdir -p`). Its probe-then-create pair is not
    atomic, so a failed `createDirectory` is reconciled against a fresh probe
    (the internal `reconcileDirectoryCreateFailure(at:error:)`): the
    postcondition is *"a directory exists here"*, so a concurrent writer (a
    build or a `git` run in the embedded terminal) that created the same
    directory in the window between the two syscalls satisfies it and the
    operation succeeds instead of failing the whole relative-path create with a
    spurious `EEXIST`; a *non*-directory that appeared instead raises the same
    `.notADirectory` the up-front probe would have, and a path still absent (a
    missing/unwritable parent, a dangling symlink occupying the name) rethrows
    the original `FileManager` error. `move` refuses an occupied destination (the explicit
    pre-check yields the typed error rather than `moveItem`'s) *except* when the
    destination resolves to the *same* on-disk item as the source — a case-only
    rename on a case-insensitive volume (`file.txt` → `File.txt`), which the
    pre-check would otherwise misread as a collision with itself (same-item check
    is by `fileResourceIdentifierKey`); `removeItem`
    deletes a file or a whole directory tree. They are defaulted in the
    `FileServicing` protocol extension to throw `FileServiceError.unsupported`,
    so the read/write/listing-only test stubs keep compiling without
    implementing them. A typed `FileServiceError`
    (`Equatable`/`LocalizedError`: `.alreadyExists`, `.unsupported`,
    `.notADirectory(name:)`, `.missingFile(name:)` — the last one added for the
    database viewer's probe-don't-read path, see `core-database-viewer.md`)
    distinguishes
    a collision (create / non-clobbering move) from an unimplemented stub method
    and from a non-directory blocking a path chain
    so the view layer can present a clear message and tests can assert the cause;
    its `LocalizedError.errorDescription` carries human text (`.notADirectory` →
    `"centrifugo" already exists and is not a folder.`) so `NSAlert(error:)`
    shows a real message rather than the raw-enum "couldn't be completed (… error
    0.)" fallback. Two more methods back the project-wide search, both defaulted
    in the protocol extension so every existing stub keeps compiling:
    `fileByteCount(at:) -> Int?` (defaulted `nil` = *unknown*, which callers must
    treat as "read it and find out" rather than as "empty"; the real service reads
    `.fileSizeKey`) and `readTextIfNotBinary(url:maxBytes:) throws -> String?`,
    which returns `nil` for a file that must not be searched — one **larger than
    `maxBytes`**, or a **binary** one (a NUL byte in the first
    `binaryProbeBytes` = 8000 bytes, git's own `buffer_is_binary` window; a *head*
    probe, so it stays O(1) for a large file). `nil` ("skip this file") stays
    distinct from a thrown error ("this file could not be read"), and the
    binary/oversize rule is one decision the service owns rather than something
    each caller re-derives. Unlike the mutating operations, its default is a
    **faithful implementation** in terms of `read`/`fileByteCount` — not a
    throwing stub — so any conforming type (an in-memory test stub, the iOS
    security-scoped decorator) inherits the real contract; it checks the size
    *twice* (the cheap pre-read check is skipped when the service reports no size,
    so the decoded text is measured too, and a caller can never be handed a buffer
    larger than it asked for). The real `FileService` overrides it with a
    byte-level version that never decodes a file it is going to reject and also
    rejects non-UTF-8 bytes (an encoding the editor cannot round-trip is skipped
    rather than lossily decoded).
    A third defaulted method backs the **symbol index** — and, since, the
    open tabs' external-change check (`OpenFile.diskStamp`): `fileStamp(at:) ->
    FileStamp?`, where `FileStamp` is `(byteCount, modificationDate)` — a cheap
    "has this file changed?" fingerprint the index compares against what it
    recorded when it last extracted a file, so an FSEvents burst re-parses only
    what actually moved. Deliberately not a content hash: hashing means reading
    every file, which is the cost the stamp exists to avoid. The accepted
    inaccuracy is the classic one — a write preserving both size and mtime looks
    unchanged — and it is bounded: only a deliberate `touch -t`/`utimes` does
    that, editor buffers are re-indexed from live text rather than from disk, and
    the next genuine edit corrects the entry, so the failure mode is a briefly
    stale symbol and not a wrong jump target. Defaulted to `nil` with the same
    reading as `fileByteCount`: **"unknown" means "re-read it"**, so a partial
    stub or a volume that reports no metadata degrades to correct-but-slower
    rather than to a stale index. The real service reads both values in **one**
    metadata call (the whole reason the pair is one type — the index stamps every
    walked file on every refresh, so two `stat`s per file would double the syscall
    cost of the gate that exists to save work), and through
    `FileManager.attributesOfItem` rather than `URL.resourceValues`, which is not a
    style choice: a `URL` **caches** the resource values it has already been asked
    for, so stamping the same instance twice can return the first answer after the
    file has been rewritten — in a cache gate, "unchanged" forever. A missing
    *date* alone is not `nil`, since a size change still catches the common edit.
    A fourth method backs the language-server install path and is the one member
    of this protocol with **no default**: `isExecutableFile(at:) -> Bool`
    (`core-lsp.md`'s D22). Every other optional member defaults to an answer that
    degrades safely — "unknown size", "unknown stamp", "not a symlink" — but this
    one is a **gate**: `LSPInstallEngine` asks it about a freshly-decompressed
    binary before committing the install, and a default would have to answer
    either `false` (a gate that fails every install through a partial stub) or
    `true` (a gate that silently passes, which is worse than not having one), so
    the compiler asking every conformer — the real service, the iOS
    security-scoped decorator that forwards to it, `StubFileTree` and the small
    local stubs `swift test` compiles — is the cheap side of that trade. The real service answers `access(2)`'s `X_OK` as
    `FileManager` spells it — "can what I just unpacked be run?", which is the
    question the caller has, rather than "is the `x` bit set in its mode", the same
    thing for these binaries and not the same thing on a `noexec` mount or under a
    sandbox that denies it. A **directory answers `false`**, overriding
    `FileManager`'s search-permission `true`: a directory where an executable was
    expected is precisely the outcome the gate exists to catch. `StubFileTree`
    carries the bit per path and moves it with the file through `move`/`removeItem`
    as a rename does on a real volume — without that, a binary unpacked into
    staging would arrive at its version directory unexecutable, a property of the
    stub and of nothing else.
    `FileService.encodingName` (`"UTF-8"`) is the name of the one encoding
    `read`/`write` use, for the caret readout (`CaretReadout`,
    `core-editor.md`): a constant rather than a per-file field, because nothing
    else is ever read or written, so there is nothing per file to record.
  - `FileName.swift` — pure, testable name/path validation for the project-tree
    inline naming draft, in two shapes over *one* rule: the boolean predicates
    `isValidFileName(_:) -> Bool` / `parseRelativeEntryPath(_:) -> [String]?` (the
    guards the operation itself re-runs behind the writer gate) and the reasoned
    validators `validateSingleEntryName(_:)` /
    `validateRelativeEntryPath(_:) -> EntryPathIssue?` (which the draft runs on
    every keystroke to show a reason and to decide whether Enter commits or
    beeps). Both predicates are *facades*
    over the same private component rule (`componentIssue(_:isReserved:)`) and, for
    the path forms, the same private splitter (`relativePathComponents(_:)`), so a
    rule can never split into two implementations and a path parses exactly when
    the validator reports no issue; parity is structural and asserted on a matrix
    in the tests anyway.
    `isValidFileName(_:)` is for the *rename*: rejects an empty or
    whitespace-only name,
    the directory-navigation names `.` and `..`, and any name containing a path
    separator (`/`), NUL (`\0`), or a **line break that survives trimming** — it must
    name *one* new entry, not a path or an
    existing directory. (The line-break rule is newer than the rest and, because
    the rule is shared, tightens `parseRelativeEntryPath` too: pasting `a\nb` used
    to create a file with a newline in its name. A *surrounding* break is trimmed
    like any whitespace, so `a\n` is accepted and only an interior one is rejected;
    in a path, a break at a component boundary — `a/\nb` — is likewise trimmed
    away per component and parses as `["a", "b"]`. Enter and Control-Return in the
    draft commit instead of inserting one, so it is only reachable by paste.)
    The separator/NUL scan runs over *unicode scalars*, not
    `Character`s: a combining mark following a `/` (`a/` + U+0338) fuses into one
    grapheme cluster that compares unequal to `"/"`, so a `Character`-level scan
    would accept a name whose on-disk path still contains a real separator and the
    entry would land in a directory the user never named (for rename, silently
    *moving* it and retargeting the open tab). Leading/trailing whitespace within an otherwise
    non-blank name is allowed (callers trim, and the project-tree rename
    call site does) and dotfiles are accepted (the two *hidden* service names are
    rejected separately at the call site via
    `FileService.isExcludedEntryName(_:)`, not here). Beside it,
    `parseRelativeEntryPath(_ path: String) -> [String]?` backs the *create*
    drafts, which accept a relative path of any depth (`centrifugo/config.json`)
    rather than a single name: it trims the whole input, tolerates exactly *one*
    trailing `/` (so `a/b/` — the natural way to spell a folder — parses as
    `["a", "b"]`), splits on `/` *without* omitting empty subsequences, and trims
    every component. The split runs over *unicode scalars* for the same
    hidden-separator reason as `isValidFileName` — a `Character`-level split would
    hand back a "single component" whose path still contains a real `/`, skipping
    the `ensureDirectory` step entirely. It returns `nil` when the input is empty/whitespace-only; when
    any component is empty *after* trimming — which is the single rule covering
    `a//b`, a leading `/`, a second trailing slash (`a//`), and a whitespace-only
    component (`a/ /b`); when any component fails the shared component rule (`.`,
    `..`, a line break, NUL); or when any component is reserved per
    `FileService.isReservedCreateName(_:)`, whose case-insensitive comparison stops
    both `x/.git/y` and `x/.GIT/y` from writing inside the hidden repository
    directory.
    `public enum EntryPathIssue: Equatable` is the *reason* half of the same rule —
    `.emptyInput`, `.emptyComponent`, `.navigationComponent(String)`,
    `.separatorInName`, `.lineBreak`, `.nulCharacter`,
    `.reservedComponent(String)` (the two payloads let the message name the
    component as the user spelled it) — with a `public var message: String`
    carrying the English text the draft's red reason line displays. The wording
    lives in Core, not the view, for the same reason `GitError.errorDescription`
    and `FileServiceError`'s `LocalizedError` texts do: the decision and its
    explanation are one rule, unit-tested together, while the draft field stays a
    thin display of whatever the validator returns.
    `validateRelativeEntryPath(_:)` (create) and `validateSingleEntryName(_:)`
    (rename) report the first offending component's issue, or `nil` when the input
    is usable. They differ in exactly two places, both deliberate. (1) A `/`: the
    path validator treats it as a separator, the single-name validator reports
    `.separatorInName` up front (rename takes one name — a path there would mean a
    *move*, a separate feature, and the entry would land on disk yet never appear
    in the tree). (2) Reserved-name semantics are **per context, mirroring each
    call site's own re-run guard exactly**, so the draft can never refuse a name
    its guard would accept or accept one it would reject: create paths use the
    case-insensitive `FileService.isReservedCreateName(_:)` (a `.GIT` component
    resolves onto the real `.git` on a case-insensitive volume), rename uses the
    exact-match `FileService.isExcludedEntryName(_:)` (a user's own `.Git` folder
    is an ordinary, visible entry). `isValidFileName` alone judges *no* reserved
    names at all — the rename call site checks `isExcludedEntryName` separately —
    which is the one documented gap in the predicate↔validator matrix.
    Core also exports two rules specifically for the inline naming flow: `initialRenameSelection(in:isDirectory:) -> NSRange` (selecting the name up to the *last* dot for files, or the whole name for directories, empty extensions, or dotfiles) and `liveCollisionIssue(finalComponent:siblingNames:excluding:) -> EntryPathIssue?`. The collision check is exact-case and is run by the caller *only* for single-component input: a multi-component create lands its final component in a folder the tree has not listed, so no siblings are available, and the "already exists in this folder" `.nameTaken` issue is only true under this restriction. Which input is single-component is `parseRelativeEntryPath`'s answer, **not** a `contains("/")` test on the string — a single trailing slash is the natural way to spell a folder, so `Sources/` is one component, and the string test both skipped its collision check and would have handed the raw spelling to the comparison.
    Foundation-only.
  - `GitRefName.swift` — pure, testable `GitRefName.isValid(_:) -> Bool` for the
    branch-switcher's "New Branch…" dialog, separate from `isValidFileName` (a
    branch name has its own, stricter grammar per `git check-ref-format`). Rejects
    an empty/whitespace-only name, a leading `-` (git's own `branch`/`checkout -b`
    refuse it, and the macOS CLI's `git checkout -b <name> <startPoint> --`
    puts its `--` only after the start point, so a dash-led name before it would
    still be mis-parsed as an option), a
    leading/trailing `/`, `..`, `//`, the
    characters space/`~`/`^`/`:`/`?`/`*`/`[`/`\`/NUL, any ASCII control char, and
    any line break (the scan tests `CharacterSet.newlines` *alongside* the control
    range because NEL/U+2028/U+2029 sit above it — and these two dialogs pass no
    live validator, so this predicate is the only gate a pasted break meets before
    `git checkout -b`, which would otherwise create a branch carrying an invisible
    separator), a
    leading dot or a dot right after `/`, a `.lock` suffix on any `/`-separated
    component, the sequence `@{`, a lone `@`, and a trailing dot. Deliberately
    conservative (an interior `/` is allowed only with non-empty, non-dot-leading
    sides). Foundation-only.
  - `BranchRef.swift` — pure value type (`Equatable`/`Identifiable`) for the
    branch-switcher widget, built from the *full* refnames
    `GitServicing.references(root:)` returns (`refs/heads/main`,
    `refs/remotes/origin/master`) plus the current short branch name: `name` (full
    refname — stable `id` and the exact revision a checkout/`createAndCheckout`
    start point needs), `isRemote`, `remoteName?`, `shortName` (display —
    `origin/master` for a remote), `isCurrent`. Pure grouping/sorting static
    helpers: `build(fromRefnames:current:)` (drops tags and any `.../HEAD` symref,
    marks the branch whose short name equals `current` — a detached HEAD passes
    `nil` so none is current — and sorts locals-first then by short name
    case-insensitively), `locals(_:)`/`remotes(_:)` (split the built list), and
    `filtered(_:query:)` (case-insensitive substring filter over short names, a
    blank query passing through). Foundation-only, unit-tested.
  - `RemoteHost.swift` — pure, testable `RemoteHost.host(fromRemoteURL:) ->
    String?`: the lowercased host of an **HTTPS** remote URL
    (`https://user@github.com:443/u/r.git` → `github.com` — userinfo/port/`.git`
    stripped, IPv6 literals guarded), the Keychain key for the iOS PAT-by-host
    selection. Returns `nil` for a non-HTTPS URL — a plain `http://` (the PAT is
    the HTTPS password; sending it over cleartext would leak it, so the feature is
    HTTPS-only), an scp-style `git@github.com:u/r.git`, `ssh://`, `file://`, or
    garbage — which can't be fetched with a PAT on iOS anyway. Foundation-only,
    unit-tested.
  - `GitCredentials.swift` — pure credential-by-host selection for the iOS HTTPS
    fetch (Part B), Foundation-only and testable ahead of the Keychain/libgit2 IO.
    `GitCredential` (`Equatable`: `username` placeholder + `token` PAT sent as the
    HTTPS password), `CredentialResolution` (`Equatable`: `.credential`,
    `.missingToken(host:)`, `.nonHTTPSRemote`), the `CredentialStore` protocol
    (`token(forHost:)`/`save`/`delete`, all defaulted in an extension so a partial
    stub compiles and an unimplemented lookup returns `nil` — an *absent token is
    the explicit default signal*, like `GitServicing`'s defaults), and the
    `GitCredentials` enum: `username(forHost:)` (`"x-access-token"` for GitHub,
    `"git"` elsewhere — the PAT is the real secret) and `resolve(remoteURL:store:)`
    (extracts the host via `RemoteHost.host(...)`; a non-HTTPS remote →
    `.nonHTTPSRemote`, an HTTPS host with no stored/empty token → `.missingToken`,
    else `.credential`). Unit-tested in `GitCredentialsTests`.
  - `WorkspaceModel.swift` — `ObservableObject` holding `openFiles`,
    `selectedID`, and `projectRoot` (`URL?`, the opened project folder).
    Operations: `newFile`, `open(url:)` (re-selects an existing
    tab instead of opening the same `url` twice — kind-blind, so a database
    already showing is re-selected exactly as a text file is; and, only when the
    `viewerTabsEnabled` init flag is on, routes a recognized database file into a
    `.viewer` tab that is *probed* with `fileStamp(at:)` rather than read, a `nil`
    stamp throwing `.missingFile`. The flag is `false` by default and set by the
    macOS app alone — `core-database-viewer.md`), `updateText`,
    `markSaved`, `select`, `save(for:onExternalChange:)` (returns `.needsSaveAs`
    when there is no url; **guarded** — see "External changes" below), `saveAllDirty()`
    (the autosave action: write every dirty file that *has* a url and advance its
    `savedText`, returning a `SaveBatchResult` — `saved`, the urls actually
    written, and `skippedConflicts`, the dirty tabs left unwritten because the
    disk changed under their edits; unlike `save(for:)` it never returns
    `.needsSaveAs`/prompts — a url-less "Untitled" or clean file is skipped — and
    a per-file write failure is swallowed so the file stays dirty and the batch
    continues; idempotent, so an immediate second call writes nothing, and the
    returned urls let the caller refresh Local Changes only when something
    changed),
    `saveAs(url:for:)`, `isDestinationOpenElsewhere(_:for:)` (the same canonical
    "a *different* open tab already targets this url" test `saveAs` refuses on —
    `SaveAsError.destinationAlreadyOpen` — exposed separately so a caller can ask
    it *before* doing anything a refused save would then have to undo: the on-save
    transform rewrites the buffer on its way to the write, and must not rewrite it
    for a write that is about to be rejected, `core-editorconfig.md`),
    `close(id:force:)` (returns
    `.needsConfirmation` for a dirty file), `openFolder(url:)` (sets
    `projectRoot` and nothing else — still not touching open tabs or the
    selection, though **not** because tabs are unrelated to the folder: sessions
    *are* per-project. The two halves of a project switch simply have different
    owners. The tab half is `replaceSession(with:)`, driven by the app
    orchestration, which is the only layer holding the `SessionStore` — and which
    must snapshot the *outgoing* project before this method moves `projectRoot`,
    or the snapshot would be filed under the incoming folder. Keeping the halves
    separate is also what lets launch restore call this without disturbing tabs it
    is about to apply itself. **Only the macOS app drives that tab half today**:
    iOS has no `SessionStore` at all — session restore there is the folder alone,
    through its security-scoped bookmark — so `FileAccessController.openFolder`
    calls this and stops, and a folder switch leaves the previous project's tabs
    open, which its scoped-access bookkeeping deliberately depends on. "Sessions
    are per-project" is a statement about the macOS layer until iOS grows a
    store), `isCurrentProjectRoot(_:)` (whether a url names the
    folder already open, compared **canonically** through the model's own
    `canonicalURL` helper, so `/tmp` vs. `/private/tmp`, a trailing slash and a
    `.`/`..` detour all count as the same folder; `false` when no folder is open,
    so a first Open Folder reads as a switch rather than as a re-open. This is the
    test the app's folder-switch orchestration takes *first* — re-opening the
    current folder must stay a tab no-op, while a real switch has to snapshot the
    outgoing session and apply the incoming one), `replaceSession(with:)` (the tab
    half of a switch: **force-close every open tab** via `closeFiles(ids:)`, then
    apply the incoming `EditorSession` through `restoreSession(_:)` verbatim —
    inheriting all of it, silent skipping included. The closes are forced, dirty
    tabs and all, which is safe only because of what the caller does first: the app
    refuses the switch outright while the disk-writer gate is up, flushes autosave,
    and refuses again — naming the files — if any dirty *titled* buffer is still
    unsaved, so every titled buffer's text is on disk and every untitled one has
    already traveled into the outgoing snapshot. A `.needsConfirmation` path here
    would be the wrong shape anyway: the user answered that question by choosing a
    different project. `closeFiles(ids:)` leaves `selectedID` `nil` once the last
    tab goes, which is what makes an **empty** incoming session — a folder opened
    for the first time — genuinely empty the editor instead of letting
    `restoreSession`'s "an empty session is a no-op" rule preserve a stale
    selection. `projectRoot` is deliberately untouched here too, for the reason
    `restoreSession(_:)` records: the folder is the app layer's job. Note this is
    the *project→project* path only — when the outgoing workspace had no folder at
    all the app applies the incoming session with `restoreSession(_:)` instead, so
    a pre-folder Untitled buffer is carried into the project rather than
    force-closed under a key nothing reads again — and files the *merged* session
    for that project, `EditorSession.merging(_:onto:incomingRestoredAny:)` being the
    stored-side
    statement of what this leaves behind, since the switch's marker makes anything
    the promoted session omits unwritable for the rest of the run; see
    `app-shell.md` and `core-services.md`),
    `restoreSession(_:)`
    (applies a persisted `EditorSession` to a normally empty model — see
    `EditorSession.swift`: reopen the recorded tabs in order and restore the
    selection. **Everything is silent** — a launch is the worst moment for a stack
    of alerts about files that moved — so a record this build cannot turn into a
    tab is skipped and the batch continues: a titled record whose file is missing
    or unreadable, *and* a record naming **neither a path nor text**. That second
    rule lives here rather than in the decoder because it is a decision about what
    a record *means*: it is the future-version tab (a kind a later build added,
    whose fields the keyed decoder skipped, leaving nothing), and skipping it here
    is what keeps such a session loading with every other tab intact instead of
    failing wholesale. A titled record is opened *through* `open(url:)` — the rule
    is inherited, not restated, so tab identity has one implementation — giving the
    same **canonical-path** dedup: a hand-edited blob with duplicates, or two
    spellings of one file (`/tmp/a.txt` vs `/private/tmp/a.txt`, a path through a
    symlink), yields one tab whose saves cannot clobber each other; this is the
    read side of the snapshot's write-verbatim rule, the same store-as-given /
    match-canonically asymmetry `open(url:)` has, and such a duplicate is *not*
    "skipped" for selection purposes — it resolves to the tab already restored.
    (`open`'s own `selectedID` assignment is irrelevant here: the selection is set
    explicitly afterwards whenever anything restored. A restored titled tab is
    therefore **clean** — `savedText` is the contents just read — so it neither
    prompts on close nor is rewritten by the first autosave.) An
    Untitled record becomes a **dirty** url-less buffer (`text` from the session,
    `savedText` empty), so closing it prompts exactly as a buffer typed in this run
    would — the whole point of storing it, since autosave skips a buffer with
    nowhere to write. `selectedIndex` is an index into the records *as stored* —
    read back exactly the way `snapshot` wrote it — so a skipped record neither
    shifts nor invalidates it (index 1 still names the second *record*, whatever
    this build could not restore before it); only a `nil`/out-of-range/skipped
    index falls back to the last restored tab, and a session that restored no tab
    leaves the selection untouched, making an empty session a genuine no-op. `projectRoot` is
    deliberately **not** touched — opening the folder registers the change with
    Local Changes, the Git Log, the branch switcher, Project Search and the
    FSEvents watcher, none of which Core knows about, so it stays the app layer's
    job), `children(of:)`
    (a pass-through to `fileService.contentsOfDirectory(at:)` so the tree view
    goes through the model rather than the service), `reloadFromDisk(id:)`
    (re-reads an open file's on-disk contents — e.g. after a revert restored it
    from `HEAD` — replacing both `text` and `savedText` so it becomes not-dirty;
    a no-op returning `false` for an unknown id, a url-less "Untitled" buffer, or
    a read failure, which leaves the buffer untouched. A read that returns
    **exactly what the buffer already holds** still returns `true` and moves
    *exactly one* of the two tokens, because they answer different questions.
    `textReplacementRevisions` is **not** bumped — it means "this buffer was
    replaced" and nothing was: every post-operation resync reloads every open tab
    under the repository while typically rewriting none of them (a commit
    ordinarily touches no file, a checkout only the files that differ), so an
    unconditional bump had the editor silently drop that file's undo stack on the
    next tab switch with nothing on screen changed. `diskRevisions` **is** bumped
    — it means "the on-disk content this buffer corresponds to changed", which is
    what the caller asserted by asking for a reload at all: after a commit or a
    branch checkout a byte-identical file still belongs to different history, so
    its worktree `git blame` genuinely moved, and skipping the bump left the
    gutter naming the previous branch's authors with nothing to correct it — a
    wrong author being the one thing that column refuses to show. The two
    *assignments* are judged separately for the same reason, since they diverge: a
    **dirty** buffer whose `text` already equals the disk contents (the user typed
    exactly what a checkout or a formatting `pre-commit` hook then wrote) still has
    a stale `savedText`, so the baseline advances — but nothing replaced the
    buffer, so the replacement token stays put; a combined guard bumped it there
    and dropped that file's undo stack with, again, nothing on screen to explain
    it), `reconcileSavedBaseline(id:)`
    (replaces *only* `savedText` with the current on-disk contents — the in-memory
    `text` is left intact — so `isDirty` reflects the true buffer-vs-disk
    difference; used by the post-revert resync for a buffer the user *edited and
    saved* while the async revert was in flight: such a buffer looks clean
    (`savedText == text`) yet `git` has since changed the file on disk, so without
    this it would close without the unsaved-changes prompt and silently lose the
    preserved edit. A deleted/unreadable file is treated as empty on-disk content,
    so a non-empty buffer becomes dirty while an empty one stays clean; a no-op
    returning `false` for an unknown id or a url-less buffer), `fileID(forURL:)`
    (the id of the open tab targeting a url, matched by *canonical* url — same
    rule as `open(url:)` — so a lookup built from a different-but-equivalent path
    form, e.g. a repo-root-relative revert url vs a tab opened via `projectRoot`,
    still resolves; `nil` when no tab targets it), `opensAsViewer(_:)` (whether
    a url is — by an open tab's kind, found the same canonical way — or would
    be, by `open(url:)`'s own name routing, a viewer tab; asked without opening
    or probing anything, so Local History can refuse a restore no buffer could
    take), and `replaceText(_:for:)` — the
    text-mutating counterpart of `updateText(_:for:)` for a writer that is *not*
    the user's typing (the project-wide Replace All's `applyBufferText`, and the
    on-save transform's off-screen path: the macOS funnel's fallback for a buffer
    no editor holds, plus iOS's one save, which never has a text view to rewrite
    through — `core-editorconfig.md`). It sets
    `text` exactly as `updateText` does, leaving `savedText` alone so the tab goes
    dirty and saving stays the user's call (which is why the save transform's
    off-screen path is followed by a write and by the resync `onBufferReplaced`
    performs), and additionally bumps that file's
    entry in `@Published public private(set) var textReplacementRevisions: [UUID:
    Int]` (read through `textReplacementRevision(for:)`, which reports `0` for an
    absent/unknown id; `reloadFromDisk` bumps it too, and a closed tab's entry is
    dropped in `removeFile`). The split exists for the *editor's undo stack*: a
    wholesale buffer swap invalidates every recorded undo action, but Replace All,
    the post-revert/post-merge reloads and the on-save transform's off-screen path
    reach open tabs that are **not on
    screen**, which get no view update of their own — so the editor cannot detect
    the replacement itself and, on the later tab switch, cannot tell it from an
    ordinary switch (which must *preserve* that file's history). The token is what
    distinguishes them; `updateText` deliberately does not bump it, since a bump
    per keystroke would drop the user's undo stack as they type. See
    `CodeEditorView`'s `externalTextRevision`. A *second* per-file token,
    `@Published public private(set) var diskRevisions: [UUID: Int]` (read through
    `diskRevision(for:)`, which reports `0` for an unknown id so a caller never has
    to tell "absent" from "unchanged"; bumped by the private
    `adoptBaseline(at:stamp:)` — which also stores the tab's `diskStamp` and
    clears its external-conflict entry, so the three move together or not at all —
    and dropped in `removeFile`), means exactly one thing: **the on-disk content
    this buffer corresponds to changed**. It is bumped at every site that assigns
    `savedText` — `open`, `markSaved`, `save(for:)`, `saveAllDirty()` (per
    successfully written file), `saveAs`, `reloadFromDisk` and
    `reconcileSavedBaseline` — which is precisely the set of moments the file the
    buffer stands for stopped being the file it was: the first read, a save, an
    autosave, a Save As, the post-revert reload, a merge
    apply, and a branch checkout (which resyncs clean tabs through `reloadFromDisk`
    and edited ones through `reconcileSavedBaseline`). It is *not* bumped by
    `updateText`/`replaceText`, which change the buffer while leaving the file on
    disk exactly as it was. Its consumer is the gutter's git-blame annotation
    column, whose data is a **worktree** blame and so goes stale the instant the
    worktree file moves under it — deliberately *separate* from
    `textReplacementRevisions`, which answers a different question ("drop this
    file's undo stack") and fires on a disjoint set of events (an external buffer
    replacement, disk untouched). **The contract is "it changed", not "it went up by
    one."** Consumers only ever compare the token against the last value they saw
    (`BlameController`'s per-file last-seen revisions,
    `Coordinator.noteExternalTextRevision`'s precedent), so the only observable
    properties are that an affected file's token *differs* afterwards and that no
    other file's does. Today each listed mutator assigns `savedText` directly and
    bumps once, but a future refactor routing one through another (a `save(for:)`
    that comes to delegate to `markSaved`, a `saveAllDirty()` that reuses
    `save(for:)`) would bump twice and change nothing anyone can observe — which is
    why the tests capture every open file's token before the call and assert the
    affected one *moved* while the rest did not, never an exact `+1`. For the
    writable project tree
    it also publishes `treeRevision` (`@Published public private(set) var
    treeRevision: Int = 0`, bumped via `bumpTreeRevision()`): a monotonic token
    the app increments after *any* successful create / rename / delete (never on
    failure) so the tree re-reads its cached directory listings without reopening
    the folder. On macOS the token has two further sources, both view-layer: the
    FSEvents `ProjectWatcher` (so an *external* change reaches the tree on its own)
    and the tree header's manual Refresh button. Core stays unaware of all three —
    it only publishes the token. The same watcher callback also re-queries Local
    Changes on macOS (`refreshForDiskChange`, `app-shell.md`); nothing *else*
    watches the filesystem: the Git Log still refreshes on demand only, and open tabs are
    checked against the disk only by the external-change pass the app runs on the
    watcher's coalesced event and on activation, plus the guard before every
    write — never by a watcher of their own (so
    `LocalChangesModel.revert`'s per-file re-query remains mandatory), and on iOS the
    tree too refreshes only on the app's own operations. Reconciliation of open
    tabs against a tree mutation is split into a *capture* phase and an *apply*
    phase so the matching runs *before* the disk mutation: a tab opened
    through a symlink to the renamed/deleted target canonicalizes to it only
    while the target still exists — once the move/removal lands the symlink
    dangles and `resolvingSymlinksInPath()` can no longer resolve it, so matching
    *after* the mutation would silently miss that tab. Matching goes through a
    private `entryMatch(fileURL:operation:)` helper that tests *three* identities so
    symlinks resolve in both directions. (1) The tab's full canonical url (the
    `fileID(forURL:)`/`open(url:)` rule) against the operation's `entryURL` — which
    canonicalizes the parent directory yet keeps the final path component
    *literal*: a tree rename/delete acts on the named entry itself, so renaming or
    deleting a *symlink* touches only the link, never its referent. Resolving the
    operation's own final symlink component would capture a tab opened directly on
    the (untouched) *referent* and force-close it (losing edits) or retarget it;
    keeping it literal excludes such tabs while a real target — whose final
    component is not a symlink, so its `entryURL` equals its full canonical url —
    still matches a tab opened through a symlink to it. (2) The tab's *lexical*
    (standardized, symlink-*un*resolved) path against the operation's lexical path:
    this matches a tab opened *directly on the operated symlink itself* (or nested
    under an operated symlink-to-directory), which canonicalizes to its referent
    and so the canonical test (1) misses, yet whose remembered url is the very link
    being renamed/deleted — so it must be reconciled (retargeted on rename, closed
    on delete; otherwise a later save would recreate the now-dangling path). Lexical
    path equality means the *same* literal entry, so (2) can never match a tab
    pointing at a different file — a tab on the referent while the symlink is
    operated on stays excluded. (3) The tab's *entry* identity (ancestors
    canonicalized, final component kept literal — the same `entryURL` shape applied
    to the *tab* side) against the operation's `entryURL`: the lexical test (2) only
    matches an operated-symlink tab when tab and operation *spell their shared
    ancestors the same way*. When they differ — the tree operates through a
    symlinked project root (`/link/mylink`) while the tab remembers the canonical
    parent (`/real/mylink`) of the same operated symlink entry — (2)'s lexical paths
    diverge at the ancestor and (1) resolves the final symlink to its referent, so
    both miss; canonicalizing ancestors on *both* sides while keeping the final
    component literal makes the two entry identities equal so the symlink is still
    matched. A tab opened on the *referent* keeps the referent's own final
    component, so its entry identity still differs and it stays excluded. For rename,
    `planRename(from:to:) -> [RenameRetarget]` (public `Equatable` `id`+`newURL`)
    captures, before the move, the tab whose url is exactly `from` (a single-file
    rename, retargeted to `to`) and every tab living *under* `from` (a folder
    rename — `from/a/b.swift` → `to/a/b.swift`); `applyRenamePlan(_:)` retargets
    those tabs after the move succeeds (an entry for a since-closed tab is
    ignored). For delete, `tabIDs(under:) -> [UUID]` captures the same set of ids
    before the removal and `closeFiles(ids:)` force-closes them after (the
    on-disk file is already gone, so nothing to save). Dirty state is preserved
    (only `url` changes — `text`/`savedText` untouched — and `displayName`
    re-derives); an unopened/unrelated path is a no-op. `renamePath(from:to:)`
    (`planRename` + `applyRenamePlan`) and `closeFiles(under:)` (`tabIDs(under:)`
    + `closeFiles(ids:)`) remain as single-call convenience wrappers for callers
    that reconcile against in-memory urls (no symlink-dangling concern); the
    disk-backed app call sites use the two-phase form. (Its private
    `canonicalURL(_:)` and `relativeComponents(of:under:)` helpers — the
    canonical-form and strictly-under path-component checks all of the above
    reuse — are now one-line delegations to `CanonicalPath`, which owns both
    rules; see below.)

    **External changes.** Every titled text tab's baseline carries a stamp
    (`OpenFile.diskStamp`), and `checkDisk(id:)` applies `ExternalChangeRule`
    to it and acts on the verdict: `reload` goes through `reloadFromDisk(id:)`,
    `adoptBaseline` through that method's baseline-only branch (the buffer
    already equals the disk), `stampOnly` records the stamp taken **before the read** —
    never a second stat after it, which would let a writer landing between the
    two have its stamp vouch for the older content — and ends any recorded
    conflict, `conflict` records the disk side and **leaves the stamp
    untouched** — the baseline has not moved, so the next trigger reads the disk
    again — and `missing`/`leaveAlone` only drop a stale conflict entry. A read
    that throws is told apart by the stamp: none means missing, one means there
    but unreadable. `syncAllWithDisk()` runs it over every titled text tab and
    returns a `DiskSyncResult` (`reloaded`, for the app's reindex, and
    `conflicts`); `partitionDirtyTabsForSave()` runs it over the dirty titled
    tabs and splits them into `writable` and `conflicted`, which is exactly the
    set the on-save transform may be offered — transforming a conflicted buffer
    would rewrite text no batch is going to write.

    *The stamp's timing* is chosen so a race can only ever cost a spurious
    comparison, never a missed change: after a **write** (`save`,
    `saveAllDirty`, `saveAs`) it is read after the write and then vouched for by
    a read-back (`stampAfterWriting`), adopted only when the read-back still
    equals the written text and `nil` otherwise — so another writer landing
    between the write and the stamp leaves no stamp to match, and the next check
    reads the disk instead of recording that writer's stamp beside the editor's
    `savedText` and skipping every later read; before a
    **read** (`open`, `reloadFromDisk`, `reconcileSavedBaseline`) it is read
    first, so a file that moves between the two leaves a stamp older than the
    content and the next check finds the content equal. Read the other way
    round, the newer stamp would vouch for the older content and the change
    would never be seen.

    *The conflict map is derived, not sticky.* `observedDiskSides: [UUID:
    ObservedDiskSide]` holds, per tab, the disk side last observed to differ
    while the tab held edits (`nil` text when it could not be read), and only
    `checkDisk` fills it — plus `reconcileSavedBaseline`, which keeps an
    existing entry alive (see below). A tab is in conflict (`isInExternalConflict(_:)`,
    `externalConflictIDs`) while its entry exists **and** the buffer differs from
    the entry's text — dirtiness is not part of the test. `diskText(forConflict:)`
    is what Compare shows and what an Overwrite captures first; an unreadable
    side reads as empty. The entry is cleared at every baseline site (through
    `adoptBaseline`) and on close, **with one exception**:
    `reconcileSavedBaseline` — the git-operation resyncs' way of *preserving* an
    edited tab — re-records the entry against the disk it just read while the
    buffer still differs from it (a missing file ends it, as `.missing` does).
    Preserving an edit is not answering the conflict; clearing it there let the
    next autosave write the buffer over the outside change after any commit,
    checkout, pull, revert or merge apply, unasked and uncaptured. Two cases follow: a buffer edited by hand to
    exactly the disk text ends the conflict on its own; a buffer edited back to
    `savedText` — **clean but stale** — stays in conflict on purpose, so the bar
    and the marker stay up, autosave writes nothing (the tab is not dirty), and
    the next check (watcher, activation, any save attempt) sees a clean tab whose
    content differs and reloads it, which clears the entry. **The one exception
    is the bar's Overwrite**: `checkDisk(id:holdingConflict:)` holds a tab
    already in conflict as dirty, so its check re-records the disk side read now
    instead of reloading — reloading there would replace the very buffer the
    answer asked to keep, uncaptured, and write the disk's text back over itself.
    The flag is ignored for a tab not in conflict.

    *Compare-before-assign.* `openFiles` is `@Published` and `OpenFile` is
    `Equatable`, and the autosave idle trigger is a debounce on `$openFiles`. A
    pass that assigned unconditionally would republish on every coalesced
    watcher event, and a long burst (a package install reports every second)
    would keep re-arming the two-second debounce and hold off autosave of every
    unrelated dirty tab for the whole burst. So the stamp refresh — `checkDisk`'s
    `stampOnly` branch, and `refreshDiskStamp(for:)`, public because the Local History restore also
    calls it after creating the empty file it lands in — that create is the app's
    own write, and a tab that outlived the delete would otherwise read it as an
    external change — writes only when the new stamp differs, and
    `setObservedDiskSide` assigns only when an entry is actually added, changed
    or removed. A pass over files that did not move publishes nothing on either
    — pinned in `WorkspaceModelExternalChangeTests`.

    *The save policy.* `save(for:onExternalChange:)` takes an
    `ExternalChangePolicy`. Under `.refuse`, the default, it checks first; a tab
    in conflict afterwards throws `SaveError.externalChange` and nothing is
    written — `savedText`, the stamp and both tokens stay as they were — and a
    clean tab whose file became unreadable answers `.saved` without writing,
    because writing the old baseline over it would be the very clobber the guard
    exists to prevent. A missing file is no change and is recreated exactly as
    before. `.overwrite` skips the check: the macOS Overwrite answer
    (`overwriteExternalChange(_:)`), and iOS's one save, which has no conflict UI
    and so keeps today's behaviour by passing it explicitly. The disk-favouring
    answer is `reloadDiscardingEdits(_:)`, `reloadFromDisk`'s answer under a name
    that says what it gives up. `saveAllDirty()` checks each dirty tab the same
    way and **skips** a conflicted one — it stays dirty and is reported in
    `skippedConflicts` — so autosave and every flush never write over a change
    made outside the app.

    *Synchronous, no token.* The check runs on the caller's main actor: one stat
    per tab, plus a content read only when the stamp moved — the cost profile of
    `open` and `reloadFromDisk`, which already run there. Nothing hops, so no
    generation token is needed; a later asynchronous version owes one, under the
    generation-token invariant.

    *The tree's link question.* `isSymbolicLink(_:)` is a pass-through to
    `fileService.symbolicLinkDestination(at:) != nil` — one link query, never a
    listing — asked by the project tree's `TreeChainRule` probe for each
    directory entry it considers (see `TreeChainRule.swift` below). Pinned in
    `TreeChainRuleTests.testTheModelsLinkQuestionPassesThroughToTheFileService`.
  - `ExternalChangeRule.swift` — the pure verdict behind the external-change
    check: `ExternalChangeRule.verdict(recorded:current:read:savedText:text:)`
    over the recorded stamp, the current one (`nil` = unknown, which means "read
    and compare", never "unchanged"), a lazily evaluated `ExternalDiskRead`
    (`.text`, `.missing`, `.unreadable`), the baseline and the buffer. Matching
    stamps answer `.unchanged` without reading. Otherwise a **stamp mismatch alone
    is never a change** — the content must differ from `savedText` too, so a
    `touch` or an identical checkout costs one read and a `.stampOnly` refresh. A
    missing file is `.missing` (not a change: today's recreate-on-save stands);
    an unreadable one is `.conflict(diskText: nil)` for a dirty tab and
    `.leaveAlone` for a clean one; readable text equal to the buffer is
    `.adoptBaseline`, not a conflict; otherwise a dirty tab is
    `.conflict(diskText:)` and a clean one `.reload`. Dirtiness is
    `text != savedText` — or `true` under `holdingConflict`, the Overwrite case
    above — which is what makes the clean-but-stale case reload. `ObservedDiskSide` is the value `WorkspaceModel`'s conflict map
    stores. Pinned verdict by verdict in `ExternalChangeRuleTests`; the stamp
    sites in `WorkspaceModelDiskStampTests`.
  - `CanonicalPath.swift` — the single source of truth for the two path
    questions the app keeps asking: *"do these two urls name the same file?"* and
    *"does this file live inside this directory?"*. `enum CanonicalPath`
    (**internal**, not `public` — the tests use `@testable import PisakaCore`, so
    sharing it inside the module needed no API expansion), Foundation-only, two
    static functions. `canonical(_ url: URL) -> URL` is
    `url.standardizedFileURL.resolvingSymlinksInPath()`, and
    `relativeComponents(of:under:) -> [String]?` is the whole-*component* prefix
    check (`/p/rootx` is not under `/p/root`, and "strictly" under — equal paths
    yield `nil`, since a directory is not inside itself). Both were previously
    private helpers *inside* `WorkspaceModel`; the extraction (the
    `ShellQuote` precedent, pulled out of `RunCommand`/`TestCommand`) exists
    because `DisplayPath` asks the same questions about a tab and the project
    root that `WorkspaceModel.open(url:)`/`fileID(forURL:)`/`entryMatch(fileURL:
    operation:)` ask about a tab and an operation — a file the model considers
    "already open" but the breadcrumb considers outside the root would be a
    silent inconsistency, so both delegate here and neither keeps a copy that can
    drift. **The `/private` caveat, documented on `canonical(_:)` itself:**
    `resolvingSymlinksInPath()` resolves ordinary symlinks but deliberately
    *strips* a `/private` prefix (`/private/tmp` → `/tmp`), so it is **not** a
    true `realpath(3)`. That is harmless here precisely because *both* sides of
    every comparison go through this same transform, so a firmlinked path is
    spelled the same way on both sides and still matches — what the function
    guarantees is *consistency*, not canonicality (a test pins exactly that: a
    root and a file under a `/private/…` temp dir still match through
    `canonical` + `relativeComponents`). Do **not** "fix" it to `realpath(3)`:
    `ProjectWatcher.canonical(_:)` does use `realpath` and is right to, because
    *its* comparison is one-sided (FSEvents hands over an already-realpath-spelled
    path that cannot be re-transformed, so a `/private`-stripped root would never
    match it), whereas switching *this* helper would desynchronize it from the
    urls `WorkspaceModel` has been matching all along — exactly the drift the
    extraction prevents.
    **`LSPInstallLayout` is the third and last deliberate variant**, and worth
    naming here because its rule is the *opposite* of this one: it restates
    `relativeComponents(of:under:)`'s whole-component prefix check over
    **lexically** normalised components, because that file may not touch the disk
    at all — so it keeps a `/private` spelling rather than stripping it, and two
    spellings of one directory compare as two. It is the only place that must not
    call in here; its reasoning is in `core-provisioning.md`.
  - `DisplayPath.swift` — the breadcrumb segments shown above the editor for the
    open file: `public enum DisplayPath { public static func components(fileURL:
    URL?, projectRoot: URL?, home: URL) -> [String] }`, Foundation-only and built
    on `CanonicalPath`. `home` is a *parameter* rather than a `FileManager` read
    (the `TerminalLaunch.workingDirectory(projectRoot:home:)` precedent), so the
    whole decision stays pure and unit-tested. Three branches: a url-less buffer
    yields `["Untitled"]` — the literal is duplicated from `OpenFile.displayName`
    rather than shared through a constant, and a test pins the two together so a
    rename of the fallback is caught by the suite instead of by the user (the bar
    and the tab must not disagree); a file strictly under `projectRoot` yields the
    root's name — its last path component as the user opened it
    (`projectRoot.standardizedFileURL.lastPathComponent`: lexical, so a root
    opened through a symlink shows the symlink's name; a trailing slash changes
    nothing; a root at `/` adds no name, since `/` is never a segment) — then the
    suffix *below* the root, ending in the file name. The name agrees with
    `MainWindowTitle` and the project switcher, which both name the project by the
    same spelling, and it is computed from the root URL, never taken from
    whichever probe matched; anything else yields the absolute path — `["~"] + suffix` when the file
    is strictly under `home`, else the plain components. Segments are always
    *names*: the leading `/` component `URL.pathComponents` reports is dropped, so
    joining with a separator can never produce `/ › Volumes › …` (the view chooses
    the separator). "Inside this root" goes through `CanonicalPath` — the same
    primitives `WorkspaceModel.open(url:)`/`fileID(forURL:)` match tabs with — as
    two probes: a *lexical* one (`standardizedFileURL`, symlink-*un*resolved)
    first, then canonical on both sides. Containment is the *or* of the two, so
    the order decides only which spelling is *displayed* when both match: the
    lexical one, i.e. the path as the user opened it, so the bar agrees with the
    project tree and the tab. That is what keeps a symlink inside the root
    pointing *back inside* it (pnpm's `node_modules/foo ->
    .pnpm/foo@1.0.0/node_modules/foo`) from being shown as the referent's
    expansion under a name never opened, and — the same rule, only the lexical
    probe matching — a symlink inside the root pointing *outside* it shown where
    it was opened rather than as an absolute path to its referent. The canonical
    probe then catches what the lexical one cannot see: the two sides spelled
    differently (a root opened through a symlink against a canonically spelled
    file, and the reverse) or paths differing only by a `/private` firmlink
    prefix. It deliberately does **not** copy
    `WorkspaceModel.entryMatch(fileURL:operation:)`'s `entryURL` shape (parent
    canonicalized, final component kept literal) or its third, ancestor-walking
    probe: those exist because a rename/delete acts on a *named entry*, whereas a
    project root is a directory to descend into — canonicalizing it whole is what
    lets a root opened through a symlink still match a canonically spelled file.
    Tests assert the cross-type consistency in both directions (a tab
    `model.fileID(forURL:)` finds through a differently-spelled path yields a
    relative — not absolute — `DisplayPath`; a sibling path the model rejects
    falls through to the absolute branch), so matcher drift fails the suite; the
    relative answer they expect now leads with the root's name. **Deviation from
    the design (2026-10-04)**: the design's main window starts the crumb *below*
    the root (`Sources › PisakaCore › WorkspaceModel.swift` in a project named
    `pisaka`), but the design's tree has no root row and the app's tree has one.
    The crumb starts where the tree starts, and a root-level file no longer reads
    as a bare name that only duplicates its tab (`project › main.py`, not
    `main.py`). Clickable segments, copying the path, the window proxy icon,
    and an iOS bar are deliberately **out of scope** (follow-ups); copying a
    path is offered by the tab menu instead (below), not by the bar.
    Two further answers serve the macOS tabs. `relativePath(fileURL:projectRoot:)`
    is the suffix below the root joined by `/` — no root name, unlike
    `components` — and nil for no url, no root, or a file outside it. It goes
    through the same private `relativeComponents(of:under:)`, lexical probe
    first, so the containment decision and the spelling are exactly the bar's:
    a file the bar shows relative to the root is a file the tab menu can copy
    a relative path for and reveal in the tree (`TabCloseRule.MenuAvailability`,
    `core-services.md`). `tooltip(fileURL:projectRoot:)` is a tab's hover text:
    the relative path, otherwise the standardized absolute path, and
    `"Untitled"` for a url-less buffer (the same literal `components` pins
    against `OpenFile.displayName`). **The absolute fallback is deliberately not
    `~`-abbreviated**, unlike the bar: the tooltip is the one place to read a
    file's full path, and an abbreviated one would only repeat what the bar
    already says. Covered by `DisplayPathTests` (three levels deep, directly
    under the root, outside it, no root, untitled, a symlinked root against a
    canonical file url, a root at `/`).
  - `TreeRevealRule.swift` — which project-tree directories Reveal in Project
    Tree expands, pure: `ancestors(of:root:)` answers every directory from the
    opened root down to the file's parent, **root first and the root
    included** — the root row is a disclosure group like any other and a
    collapsed root would hide everything — so a file three levels deep answers
    `[root, a, a/b, a/b/c]` and a file directly under the root `[root]`. **Each
    answer is spelled the way the tree spells its rows**: the root exactly as
    the user opened it, then one listing component appended per level, never
    the canonical spelling — the tree's nodes are built from the opened root
    and its listings, and a canonical url (`/private/tmp/…` for a `/tmp` root,
    a symlink's referent) would match no row. Containment is `DisplayPath`'s
    two-probe rule, so a root reached through a symlink or a `/private`
    firmlink difference still answers, in the root's own spelling. Nil outside
    the root and for the root itself (it is not inside itself). The app-side
    `TreeRevealRequest` carries the answer to the tree (`app-window.md`).
    Covered by `TreeRevealRuleTests`.
  - `TreeChainRule.swift` — which rows the macOS project tree draws for one
    folder's listing: a file, a plain folder, or a **chain**, a run of folders
    each holding nothing but the next, drawn as one `a/b/c` row whose expansion
    goes straight to the last folder's contents. Pure and Foundation-only:
    `TreeChainRule.rows(in:separated:isSymbolicLink:list:)` takes the parent's
    own listing (read by the caller), the set of folder keys the user asked to
    see as separate folders, a link question and the listing function every
    probe reads through, and answers `[TreeRow]` in the listing's order.
    **The rule is applied to a listing's entries only**: the project root is
    never one of them — the view builds the root node as itself — and that is
    the whole of what keeps the root out of every chain.
    **The walk.** A folder *qualifies* when it is not in `separated` and its
    listing is exactly one entry that is a directory. For each directory entry
    `d`: a symbolic link is a plain folder row and is never listed; a failed
    listing is a plain folder row, nothing remembered for the failure, so the
    row's own expansion retries as before; otherwise `d` is listed and the walk
    appends the single child `e` while the last segment qualifies and the chain
    is shorter than `maximumSegments`, checking `e` first — in `separated`:
    stop before it; a symbolic link: append it as the **tail** without listing
    it, its contents loading on expansion; its listing fails: stop before it,
    so it becomes a plain row under the tail; otherwise append and list it. A
    chain of one segment is a plain folder row. **The cap is 32**
    (`maximumSegments`): the 32nd segment is still listed, so its listing is the
    tail's contents and the rest of the run appears as that tail's children.
    **A separated head is walked all the same**: its row is a plain folder, but
    the run it would draw is listed under the load that drew it, so `Show as One
    Row` re-runs the rule over the memo alone — even after a revision bump left
    nothing else read. Its cost is the one the unseparated head pays.
    `offersShowAsOneRow` on the plain-folder case is true exactly when the
    folder is separated **and** the chain joining it would form has more than
    one segment — `segments.count > 1` off that same walk, the answer the
    unseparated head would draw from. A head merely *holding one folder* is not
    enough: when its one child is itself separated, or cannot be listed, the
    walk stops before it, joining would draw the same plain row, and nothing is
    offered; when its one child is a symbolic link, the link is appended as the
    tail, so joining draws a two-segment chain and the item is offered. **Every probe failure
    is silent**: it shapes the answer and never throws out of the rule; only a
    node's own contents read may beep, in the view.
    **Symbolic links in today's listing.** `FileService.contentsOfDirectory`
    reads `isDirectoryKey`, which does not follow links, so a symlinked
    directory already lists as a *non-directory* entry and the app draws it as
    a file row. A run whose next entry is a link therefore ends at the link's
    parent, which does not qualify — its one entry is "a file" — and the link is
    that row's child. The rule's own link check stays, through
    `WorkspaceModel.isSymbolicLink(_:)`, as the defence for any listing that
    does report a link as a directory (the test stub; a future listing change),
    and it is what the Core link tests pin; it costs one link query per
    directory entry probed, never a listing. Descending into symlinked
    directories is out of scope.
    **`TreeRow`** has three cases — `.file`, `.folder(_, offersShowAsOneRow:)`,
    `.chain(TreeChain)`, the folder's flag being the `offersShowAsOneRow`
    answer above — and **`id` is the entry url, or the chain's head**, so
    a folder keeps its identity as it turns from plain to chain and back, which
    is what lets the view keep its `@State` (expansion above all) across a
    reshape. `leads(toDraftAnchor:renaming:)` is the question a reload asks of
    its rows for a draft anchored below the reloaded folder (`anchor` is the
    folder the draft writes into, `renamed` the entry a rename names): a plain
    entry leads when it is renamed, or when it is a folder holding the anchor
    (today's test, a directory still required further down); a chain leads only
    when the anchor is its tail or lies under it, or when the draft renames its
    tail — a draft anchored on an inner segment is no longer drawn anywhere and
    is dropped. Containment is `ScopedFileAccess.path(_:isWithin:)` over
    standardized paths only, never resolved, for the reason `draftIsBelow(_:)`
    records (`app-window.md`).
    **`TreeChain` carries every address as data**, its segments head first (at
    least two, a precondition) and the tail's handed-down listing (`nil` for an
    unlisted link tail). The row stands for the head's subtree and shows the
    tail's contents, so what is about the *row* addresses the head and what is
    about its *contents* addresses the tail:

    | Property | Target |
    |---|---|
    | `identity` (row id, expansion key, unfold key) | head |
    | `contentsDirectory`, `createTarget`, `dropDestination` | tail |
    | `renameTarget` | tail |
    | `deleteTarget`, `dragSource` | head |
    | `diagnosticMarkURL`, `spokenGitStateURL` | head |
    | `gitStatusURLs` | each segment |

    `label` is the segment names joined with `/`, and
    `deleteConfirmationName` is that label — **the one name a chain's delete is
    confirmed under**: `deleteTitle` is built from it, and the app hands the
    same value to the confirmation sheet (`app-window.md`), so the menu item and
    the sheet cannot name different things. The titles are
    `Rename "<tail>"`, `Delete "<deleteConfirmationName>"`, and the two statics
    `Show as Separate Folders` / `Show as One Row`. `renameSiblings` is the tail
    alone — the listing of its parent segment, which the field excludes as it
    excludes any renamed entry's own name — and `leadingSegments` are the ones a
    rename field is drawn after. `remainderHead` (the second segment) is the
    folder the view opens on first appearance when an expanded chain is shown
    as separate folders (only that folder: folders opened below the tail come
    back collapsed, `app-window.md`). `revealURLs(underHeadRevealURL:)` spells each segment
    the way `TreeRevealRule` does — the head's reveal url, then one name
    appended per level — so a reveal request matches every segment.
    `key(for:)` is `standardizedFileURL.path`, the url as the tree spells it and
    never resolved: the one key of `separated` and of the memo, adding no
    canonicalisation site of its own.
    **`TreeListingMemo`** (same file) is the tree's **one listing per directory
    per `treeRevision`**: a reference type made with a listing function and asked
    `listing(of:revision:)`; a different revision forgets everything first, and
    `reset()` does the same on a project-root change. **Successes only are
    remembered** — a failure is thrown to the caller and re-read on the next
    ask, which keeps the collapse/re-expand retry exactly as it was. Every node's
    load, each parent's chain probe included, lists through it, so the listing
    read while probing a chain's tail is the one the row shows when expanded,
    and the order in which a parent and an already-expanded child load never
    causes a second read within one revision. It lists only when asked: nothing
    lists on the watcher callback, in the drop hover path, or on an unfold
    toggle, which re-runs the rule through `rememberedListing(of:revision:)` —
    the memo's answer alone, a miss (another revision, a directory not asked
    yet, a failed read) throwing `NotRemembered` without reading. The rule takes
    a miss as any failed probe, so a probe that failed under the load is drawn
    as that failure again and is retried by the next load, never by the
    toggle. **Stated limit**: the
    memo bounds reads *within* a revision, not across them — the rule lists
    every non-link subfolder of a listing it is asked about, so a folder of N
    subfolders costs N + 1 reads each time a revision change empties the memo
    (the app half, and the privacy-prompt consequence of probing unopened
    folders, are in `app-window.md`).
    Covered by `TreeChainRuleTests`, each case its own test over `StubFileTree`:
    the qualifying run, the three stops (no entries, two entries, one file), a
    chain of one, files beside a chain, the root never a segment, a link head
    never listed, a link continuation as the unlisted tail, the 32-segment cap,
    a separated head offering `Show as One Row` and a non-qualifying one not,
    a separated head whose only child is unreadable offering nothing and one
    whose only child is a symbolic link offering the item, a
    separated continuation, an unreadable head, continuation and first
    continuation, every address and title as data on one chain (the delete
    title quoting exactly `deleteConfirmationName`, which is `a/b/c`), the key's
    spelling, and `leads` for the plain, tail, under-tail and inner-segment
    anchors; over the real `FileService` in a temporary directory, a folder
    holding `.git` and one subfolder qualifies because the listing's own
    exclusions apply first. The **charged** tests count off
    `StubFileTree.listedPaths`, a seam separate from the cap: a parent of N
    subfolders, one heading a run of depth D, lists exactly `N + D − 1`
    directories, each once by set equality; a 40-deep run lists exactly 32 and
    never the 33rd; the memo serves a second ask in the same revision with no
    listing and reads each once again after a revision change; failures are not
    memoized; `reset()` forgets. Re-evaluation re-runs the rule after mutating
    the stub: a lone folder added in the tail **extends** the chain (same `id`,
    the new tail's listing), a file added in a middle segment **shortens** it to
    that segment (same `id`, its listing holding the old tail and the file), and
    after the extend a rename draft of the old tail leads nowhere. The unfold
    sequence — `{a}`, `{a, b}`, then `a` removed — is three rule re-runs with no
    new listing, the rule staying local to each folder (with `{a, b}` separated,
    `a` offers nothing, its one child being separated); and a separated head
    loaded under a fresh revision is joined again with no new listing either.
  - `TreeStickyRule.swift` — which expanded ancestors the macOS project tree
    pins under its header while scrolling, in what order, where each copy is
    drawn and how tall the stack is, plus the one answer to "where must a
    scrolled-to row land so the stack does not cover it". Pure and
    Foundation-only, a `public enum` of static functions; a navigation aid
    whose answers change nothing about what the tree holds or addresses. The
    app half — measurement, the overlay, the three scroll sites — is the
    sticky-folders entry under `ProjectTreeView.swift` (`app-window.md`).
    **Input.** `Folder` is one folder *node* as the tree measured it: `depth`
    (`0` is the project root), `isExpanded`, and the `top` and `bottom` of the
    whole node — its row plus its expanded subtree — in content coordinates. A
    chain row is one node and one `Folder`, whatever its segment count. The row
    itself is taken to be `[top, top + rowHeight)`, and `rowHeight` is also a
    pinned copy's height. `Viewport` is `top` (the content offset at the
    viewport's top edge) and `height`. The input order is **not trusted**: the
    rule orders folders by `top`, then `depth`, then input index. The copy maps
    back to its report through `Stack.Row.index`, the input index, so `Folder`
    needs no identity of its own.
    **Eligibility.** `depth ≥ 1` (the root never pins), expanded, and `bottom >
    top + rowHeight` — at least one descendant row, so an expanded empty folder
    never pins.
    **Cap.** `maximumRows(viewportHeight:rowHeight:)` is `floor(H · capFraction
    / h)` with `capFraction = 1.0/3.0`, and `0` for a non-positive row height
    or viewport; with `0` nothing pins. The floor carries a `1e-9` tolerance so
    an exact multiple (`66 / 3 / 22`) is not floored one row short by the
    binary rounding of a third.
    **The chain.** Level `i` has the nominal slot `S_i = viewport.top +
    i·rowHeight`. One sorted forward pass takes the first eligible folder that
    lies inside the previous member's subtree (deeper, `top ≥ previous.top +
    rowHeight`, `bottom ≤ previous.bottom`; anything eligible for the first)
    and satisfies `top < S_i < bottom`. Spans containing one point nest, so the
    first match is the outermost and the members form an ancestor chain; a
    sibling after a pinned folder's subtree fails the containment test and never
    stacks under it. Once the chain holds `maximumRows`, a further candidate
    must satisfy `top ≤ S_(maximumRows−1) < bottom` — **`≤`, not `<`**: at
    equality its real row lies exactly under the last copy, so left out it
    would show neither its row nor a copy — and then the **outermost** member
    is dropped and the candidate appended, repeatedly — so capping drops outer
    rows first, a capped row joins once its real row is fully under the stack
    or no more than `slotTolerance` short of it, and a copy is never drawn
    while more than that sliver of its real row shows below it. The equality is
    no corner case: the click anchor aims a capped folder's row precisely
    there, the scroll settles it within the tolerance of it, and with `<` the
    folder directly above it — its parent, when it is the parent's first row —
    ended up covered by the next copy out.
    `testAClickLeavesTheFolderAndItsInnermostAncestorsInSight` pins that by
    round trip, in two passes: every copy, at every offset of the deep fixture
    under every cap, is scrolled to its anchor and the stack recomputed there,
    and neither the folder nor any ancestor the cap leaves room for may be
    covered. The first pass lands exactly; the second runs on the fixture
    shifted by half a point (rows on the half-point grid, as at interface
    scale 1) and **floors** each landing to a whole point, the backing pixel at
    scale 1, asserting that at least one landing moved so the pass cannot be
    vacuous.
    **Tolerance.** The edges are measured, not counted: at a fractional
    interface scale SwiftUI sums the scaled row heights in another order than
    the rule would, so a last child's bottom can come back one ulp past its
    parent's (`246.40000000000003` against `246.4` at scale 1.1) and exact
    containment would drop it from the chain, pinning its child straight under
    the grandparent. Eligibility, containment and the ancestor count compare
    one row's edge with another's, and therefore each allow
    `measurementTolerance = 0.5` points across their boundary — far above the
    drift, far below the smallest row (19.2 at the interface scale's 0.8
    floor), so no two distinct rows blur. The full chain's `≤` is different: it
    compares an edge with the scroll offset, and allows `slotTolerance = 0.5`
    points, sized to the **scroll's rounding**, not to the drift. The record
    has two halves. The raw clip view keeps a programmatic offset as asked: an
    `NSClipView` probe at backing scale 1 read `48.4`, `66.25` and `66.1` back
    unchanged through `scroll(to:)`, `setBoundsOrigin` and
    `constrainBoundsRect`. But the click goes through SwiftUI's
    `ScrollViewProxy.scrollTo`, not the raw clip view, and that settled a
    target of `1165.5` at `1165.0` at backing scale 1 — the backing pixel. It
    rounds to the **nearest** pixel, ties down, not a floor: a plain
    `ScrollView` probed at backing scale 1 settled targets ending in `.1`–`.5`
    on the point below and `.6`–`.9` on the point above, so off the half-point
    grid (any other interface scale) a landing is still at most half a point
    from its target. With
    rows on the half-point grid at interface scale 1, a click therefore lands
    half a point short of the equality, and the former `1e-6` left the clicked
    folder's parent out and its row covered. Half a point is half a backing
    pixel at most for any scale ≥ 1, and far below the smallest row. Its cost,
    stated: a candidate joins — and the outermost row drops — up to half a
    point early, so at most a half-point sliver of its real row shows under
    the copy in its slot, the right trade against a covered row after a click.
    The floored round-trip pass above pins it: at `1e-6` it fails, the parent
    covered. The free slots' `<` stays strict: a drift there pins a copy
    exactly over its own row, the same pixels.
    **Drawing.** Final index `j` is drawn at `min(S_j, folder.bottom −
    rowHeight)`, reported relative to the viewport top as `Stack.Row.top` —
    negative, or above its nominal slot, while the end of its subtree pushes it
    out — with `pushOffset = top − nominal` (`≤ 0`). `Stack.height` is the
    largest drawn bottom, clamped to `≥ 0`, and `0` when empty. Rows come
    outermost first and are drawn outermost on top, so a deeper row whose
    subtree ends slides up under its parent; a child ending with its parent
    slides under it, and the parent is then pushed by the row that follows.
    `Stack.Row` is declared in an extension of `Stack`, the nesting depth the
    style rule allows.
    **Scroll anchors.** `anchorY(rowsAbove:rowHeight:viewportHeight:)` is the
    `UnitPoint.y` landing a row of height `h` with its top `k` rows below the
    viewport top: `scrollTo` aligns the same unit point of the row and of the
    viewport, so the top lands at `y·(H − h)` and `y = k·h / (H − h)`, clamped
    to `0…1`, `0` when `H ≤ h`. `eligibleAncestorCount(forRowAt:folders:
    rowHeight:)` counts the eligible folders whose span contains the row's top
    (`top < rowTop < bottom`); a folder's own row is not inside its span, so it
    never counts itself. It is two binary searches over the eligible folders'
    sorted tops and sorted bottoms — those starting above the row minus those
    ending at or above it, an eligible folder ending above the row necessarily
    starting above it too — so `stack(...)` builds the two arrays once — and
    not at all when nothing pins, an empty chain returning before them — and
    counts each pinned row in `O(log n)`, keeping the whole stack `O(n log n)`
    rather than a linear scan per pinned row on every scroll. `scrollAnchorY(forRowAt:folders:viewportHeight:
    rowHeight:)` — `anchorY` of that count capped at `maximumRows` — is **the
    one below-the-stack anchor**: `stack(...)` fills every
    `Stack.Row.scrollAnchorY` with the same answer for the folder's top, and
    `placement` asks it directly. **Why the count and not the index**: with
    the cap dropping outer rows the index is wrong — with `maximumRows` 3 and
    `a/b/c/d/e` nested, expanded and deep, the stack shows `[c, d, e]`;
    clicking `e` (index 2) would land its real row in slot 2, but once it sits
    there `a`…`d` all qualify again and fill slots 0–2 over it. The count gives
    3 and lands it just under the stack. Uncapped, the two agree, which is why
    only the capped case can tell them apart. `revealAnchorY = 0.5` keeps the
    centre: a centred row's top `(H − h)/2` is never above the largest stack the
    cap allows (`H/3` at most) for any viewport that pins at all (`H ≥ 3h`).
    `placement(ofRowAt:folders:viewport:rowHeight:)` is `nil` when `[rowTop,
    rowTop + h)` already lies inside `[viewport.top + stack.height,
    viewport.top + H)` — no scroll — and otherwise `scrollAnchorY(forRowAt:)`,
    the anchor the click uses; the app asks it for the create draft.
    Covered by `TreeStickyRuleTests` (32 tests, `rowHeight` 22, viewports
    giving caps of 1, 2, 3 and 4): nothing pins at offset 0 or while a real row
    is at or below its slot; one row, several rows outermost first, shuffled
    input, input indices; push-out and both slide-under orders; the cap
    dropping the outermost first and a capped candidate joining once fully
    under the stack or within the rounding's half point of it (`43.5` and
    `43.999` join at cap 2, `43.4` and `43` do not); the click round trip, exact
    and floored to the whole point on the half-shifted fixture; `maximumRows` at and either side of exact multiples, and
    `0` below three rows; a collapsed ancestor, the root and an expanded empty
    folder never pinning; one-ulp drift in every tolerant comparison
    changing no answer (each part failing with the tolerance at 0); a chain as
    one row; siblings; `Stack.height` empty,
    full and pushed. Anchors: `anchorY` for k = 0, 1, 3, clamping and `H ≤ h`;
    the capped `a/b/c/d/e` fixture's anchors `[0.25, 0.375, 0.375]`, equal to a
    direct `scrollAnchorY(forRowAt: e.top)` and **not** `anchorY(rowsAbove:
    2)`; the uncapped stack's anchors equal to the index; the ancestor count
    ignoring the root, collapsed folders and the row's own folder, and equal to
    the definition counted directly at every half point of three fixtures; the reveal
    centre clearing the capped stack for every height from `3h` to `60h` in
    one-point steps, the count of heights checked (1,255) asserted so the loop
    cannot pass empty; and `placement` `nil` for clear rows, the shared anchor —
    capped at `maximumRows` — for a row under the stack and one crossing the
    viewport's bottom edge.
  - `TreeTestRule.swift` — whether a macOS project-tree row is a **test row**,
    the rows the tree paints with a wash underneath the row-state tints. Pure
    and Foundation-only: `TreeTestRule.isTestRow(components:isFolder:)` takes
    the row's **root-relative path components** — `[]` is the project root —
    and whether the last one is a folder (a chain row passes its tail's path),
    and answers `Bool`. It reads no file and calls no service; the cost is one
    walk over the components, so the row's depth.
    **Test folders are a closed set**, `testFolderNames` = `test`, `tests`,
    `__tests__`, `spec`, `specs`, each component lowercased before the lookup,
    so `Tests` and `__TESTS__` count and `testing`, `contest`, `specification`
    do not — a whole-component match, never a prefix or a substring.
    **Being a test folder is inherited the way a git ignore does**: a folder is
    a test row when *any* of its components is a test-folder name — itself, an
    ancestor, or any segment of a chain, wherever in the chain the test segment
    sits — and a file is a test row when any *ancestor* component is one, or
    when its own name follows its ecosystem's naming convention. A file's own
    name is never read as a folder name, so a file called `test` with no
    extension is judged by the convention alone, and is not a test row.
    **The root is never a test row**: the components are relative to it, so
    they never spell it, and `[]` answers `false` for both kinds — which is
    what keeps a project that is itself called `tests` from washing every row.
    **The naming conventions are shared with `TestCommand`, not restated.**
    The file half reads `TestCommand.followsTestNamingConvention(fileName:)`,
    the one table both that predicate and `isTestFile` are built from
    (`core-services.md`), so a convention added there reaches the tree and
    "Run Test" by construction. **Rust is the one difference, and the stated
    exception**: `isTestFile` answers every `.rs` file because Rust's tests
    live beside the code, which would wash every Rust source in the tree; the
    naming predicate answers `false` for `rs`, so a Rust file is a test row
    only through a test folder above it — `tests/integration.rs` yes,
    `src/lib.rs` no. "Run Test" and ⌘U keep reading `isTestFile` and are
    unchanged. Covered by `TreeTestRuleTests` (every folder name in upper and
    mixed case, near misses, the root exclusion, inheritance through
    `Tests/PisakaCoreTests/Support/Gate.swift` and `src/test/java`, a chain
    with its test segment first, middle or last, the Rust pair, and the file
    named `test`), with the agreement of the two `TestCommand` predicates
    pinned in `TestCommandTests`.
  - `DependencyFolderRule.swift` — whether a folder is a **dependency root**
    (a folder a package manager fills) and whether a path lies **inside
    dependencies**. Pure and Foundation-only: it reads folder names and their
    siblings' names, and every listing it needs is handed to it by the caller.
    **The table is closed and compared exactly** (`markers`, pinned by set
    equality): `node_modules` → `package.json`; `vendor` → `composer.json`,
    `go.mod`, `Gemfile`; `.venv` and `venv` → `pyproject.toml`,
    `requirements.txt`, `setup.py`, `setup.cfg`, `Pipfile`; `Pods` →
    `Podfile`; `.build` → `Package.swift`. `isDependencyRoot(name:siblingNames:)`
    holds when the name is in the table **and** one of its markers lies beside
    it: a name alone never counts, because a hand-written `vendor` folder beside
    no manifest is ordinary source the user edits. `Node_Modules` and `VENDOR`
    are not roots. Build-output folders (`build`, `dist`, `target`) are
    deliberately not in the table — they hold what the project produced, not
    what it depends on.
    **The project root is never a root**: the components are root-relative and
    never spell it, so `[]` is never asked about. **Being inside is
    inherited**: `State` (`.outside`, `.root`, `.inside`) answers `.inside` for
    any node or file under a `.root` or `.inside` parent, so a package's own
    nested `node_modules` is never a second root and a file is never a root.
    `showsCaption` is `.root` alone; `showsTestWash(isTestRow:)` is `isTestRow`
    only at `.outside`, which is how a vendored package's `test` folder washes
    nothing while `TreeTestRule` stays untouched.
    **A chain row is a root row when *any* segment is one**
    (`isDependencyRootRow(segmentNames:siblingNames:)`), each segment asked
    about its own siblings. `TreeChainRule` folds a folder only when its
    listing is exactly one folder, so a root — which always has a marker file
    beside it — can only be a chain's head; a tail-only rule could never fire,
    and a `node_modules` holding one package (the chain `node_modules/lodash`)
    would go uncaptioned. The row stands for its head the way its git colour
    does; the tree hands the head its parent's listing names and a later
    segment just its own name, a folded segment being its parent's sole entry.
    **The path question**, `isInsideDependencies(components:siblingNames:)`,
    walks the **ancestors** only (`components.dropLast()`), asks
    `siblingNames(i)` only for a table-named component, reads a `nil` listing
    as not a root and returns at the first root. Its URL form,
    `isInsideDependencies(fileURL:projectRoot:listNames:)`, computes the
    root-relative components canonically (`CanonicalPath.canonical` +
    `relativeComponents(of:under:)`), lists the canonical root plus the
    components before `i`, and answers `false` with no listing for a `nil`
    root or a file not strictly under it. **The cost bound**: one listing per
    table-named ancestor component of the asked path, stopping at the first
    root; a path with no table-named ancestor costs no listing at all. Nothing
    is memoized.
    **Three readers ask it**: the macOS project tree, from listings it already
    holds (the `dependencies` caption, its spoken `Dependencies`, the
    suppressed test wash); `WorkspaceModel.opensInSourceViewer`, which routes a
    file inside dependencies to the read-only source viewer window instead of a
    tab, and the session restore, which drops such tabs; and
    `DiagnosticsModel`, which drops every report naming a document inside
    dependencies. Find in Files and the symbol index are **deliberately
    untouched** — both walk `ProjectFileWalk`, which already honours
    `.gitignore`, and a committed `vendor` tree is still worth searching — so
    no second exclusion is to be added there later. Covered by
    `DependencyFolderRuleTests`: the table by set equality, every key with each
    of its markers, the marker requirement (and `vendor` beside only
    `package.json`), exact comparison, the root exclusion, inheritance, every
    `State` transition, the chain headed by a root and the chain whose later
    segment is the root, the test-wash suppression, the listing-cost bound
    through a counting closure (`src/a/b.swift` 0, `node_modules/x/y.js` 1,
    `a/vendor/b/vendor/c.go` 2, a first-ancestor root 1), and the URL form
    under a symlinked root spelling and outside the root.
  - `MoveDropRule.swift` — the one engine behind the project tree's
    drag-and-drop move: *may this drop land, and where?* `public enum
    MoveDropRule`, Foundation-only, two static functions returning one
    `public enum MoveDropDecision { case move(destination: URL); case
    refuse(MoveDropRefusal) }`. **Two entry points, one vocabulary.**
    `structuralDecision(source:into:)` is **disk-free** — pure path arithmetic
    over `CanonicalPath`, the three answers no listing can change;
    `decision(source:into:fileService:)` runs those same rules first and then
    adds the two facts only the disk knows. **The full one is what the view asks,
    for the hover as well as for the drop**: a highlight drawn from the
    structural half alone would light a row up for a collision it cannot see and
    the drop would then refuse what the row had just promised, so the view asks
    this one and *memoizes* it per (source, target) pair instead —
    `structuralDecision` is the separately-tested first half, not a second call
    site. Because both return the same decision, the highlight the user sees
    while hovering and the move that runs on release come from **one** destination
    rule rather than two that can disagree — and `PisakaApp.moveItem(at:into:)`
    re-asks the full one behind the writer gate, so the view's answer is advisory
    and the app's is authoritative.
    The structural rules, in order: source ≡ target → `ontoItself`; target
    strictly under source (`relativeComponents(of:under:)`) → `intoOwnDescendant`;
    target ≡ the source's *spelled* parent → `unchangedLocation`; otherwise
    `.move(destination:)`. The disk half then lists the destination folder (an
    unlistable folder → `targetMissing(name:)`) and refuses an exact
    last-component match as `nameTaken(name:folder:)`, then confirms the source
    still appears in its own parent's listing (absent or unlistable →
    `sourceMissing(name:)`) — the drag may have started before a Finder delete or
    a branch checkout. Those two listings are exactly why this is the *drop*
    question and the memoized one, never the per-mouse-move one (the view keys the
    memo on the (source, target) pair, so it costs one listing per row entered).
    **The destination is `<the folder as the user spelled it>/<the source's last
    component>`** — a move never renames, and spelled paths are stored while
    canonical paths are compared, per the project's path rule.
    **Why identity and ancestry are canonical, not textual:** a tree row and the
    url a caller computed can spell one file differently (`/tmp` vs
    `/private/tmp`, a trailing slash, a symlinked project root), and a textual
    comparison would let a drag "onto itself" through whenever the two spellings
    differ — after which `FileService.move` either fails obscurely or succeeds at
    something the user did not ask for. Both questions therefore go through
    `CanonicalPath`, matching how `WorkspaceModel.planRename(from:to:)` matches
    tabs: the two **must** agree, since that plan is what carries open tabs across
    the very move this engine authorized. The comparisons are on `.path`, not on
    `URL` values, for the trailing-slash reason every other canonical comparison
    in the project keys on `.path` too. The `unchangedLocation` probe deliberately
    canonicalizes the source's *spelled* parent: a symlink row lives in the
    directory holding the link, so dropping it beside its referent is a genuine
    move, not a no-op.
    **Symlinks are otherwise refused conservatively:** `canonical(_:)` resolves
    them, so a row that *is* a symlink pointing at the destination folder
    canonicalizes onto it and is refused as `ontoItself`, and a symlinked folder
    dropped under its referent reads as `intoOwnDescendant` — even though moving
    the link entry itself would be well defined. That is deliberate and consistent
    with `planRename`, which resolves the same way: a rare, ambiguous drag is
    refused with a clear message rather than carried out under a reading the user
    may not share.
    **The collision check is not the last word:** it compares the exact last
    component against the destination's listing and so cannot see the collision a
    *case-insensitive* volume produces (`README.md` dropped beside an existing
    `readme.md`). `FileService.move` refuses to clobber and raises
    `FileServiceError.alreadyExists`; that stays the backstop. This check exists to
    suppress the drop *highlight* early and to phrase the refusal in the tree's own
    words, not to be the only guard.
    **How a refusal reaches the user — mostly, it does not.** SwiftUI runs
    `performDrop` only for a drop `validateDrop` accepted, and `validateDrop`
    *is* this engine, so the ordinary refusals (collision, self, descendant, the
    same-parent no-op) never reach `moveItem`: the row stays unlit, the pointer
    shows the refusal cursor, releasing does nothing, and that is the feedback —
    the right one for a gesture whose whole answer is visible while it is being
    made. The alert path is for what the hover answer *cannot* have caught, which
    is why `moveItem` re-asks behind the writer gate at the moment the move would
    happen: a destination that gained the name, or a source that vanished,
    between the hover and the release is reported rather than silently dropped.
    `public enum MoveDropRefusal: Error, LocalizedError, Equatable` carries the six
    reasons above and is a `LocalizedError` **on purpose**: a refusal that does get
    that far then reports through the *same* path as every other project-tree file operation
    (`reportFileOperationFailure(_:)` → `NSAlert(error:)` + a warning beep), so the
    tree needs no alert code of its own and the wording lives beside the rule that
    produced it — the arrangement `FileServiceError` and `EntryPathIssue` already
    use. The texts name the entry (and, for a collision, the folder) and are
    written here rather than borrowed from `FileManager`, whose messages describe a
    *failed system call* while every case here is a decision made before the disk
    was touched. `isSilent` is true for `unchangedLocation` **alone**: dropping an
    entry back into the folder it already lives in is how a user cancels a drag
    they thought better of, and an alert for it would be noise; every other
    refusal is something the user asked for and did not get, so it is reported
    *if it gets that far*. That flag consequently guards a path a structural
    refusal cannot normally reach, and is kept as the rule's own statement of
    intent rather than as a live branch.
    Tested (`MoveDropRuleTests`) through both entry points against `StubFileTree`
    for the disk facts and *real temp dirs plus `symlink(2)`* for the canonical
    cases — the destination shape (never a rename), the parent no-op, self and
    one- and multi-level descendant refusals, each of those through a symlinked
    spelling, the `/private` spelling, a collision and the absence of a false
    collision when the only same-named entry is the source itself under another
    parent, a missing source, a missing target, and the ordinary accept.
  - `TreeDraftDismissRule.swift` — the one rule that decides whether a mouse-down
    cancels the project tree's open inline-naming draft: *is this click the
    draft's business?* `public enum TreeDraftDismissRule`, one static function
    `decision(clickedWindowIsDraftWindow:clickedInsideWindowContent:point:draftBounds:)`
    returning a two-case
    `public enum TreeDraftClickDecision { case ignore; case cancel }`, plus the
    companion `cancelTiming(opensContextMenuOnMouseDown:)` returning
    `public enum TreeDraftCancelTiming { case immediately; case onMouseUp }` —
    *when* a `cancel` may be applied, which is a separate moment from deciding
    it. It exists
    because a tree row is a plain SwiftUI view that never takes first responder,
    so `controlTextDidEndEditing` cannot hear a click on one: the view layer keeps
    a local `.leftMouseDown`/`.leftMouseUp`/`.rightMouseDown` monitor alive for
    exactly as long
    as a draft is (`ProjectTreeDraftField`, `app-window.md`) and asks this rule
    what each event means. Everything the rule takes is an AppKit *fact* — which
    window, whether the click was in that window's content area at all, which
    point, which rectangle — so the view holds no policy, the same
    split `MoveDropRule` uses for the drag.
    **The four answers.** A click in *another window* is `ignore` regardless of
    where it landed: Find in Files, a diff window, an alert and Preferences each
    own their clicks, and cancelling on one would destroy a half-typed name
    because the user reached for a different window. The window check comes
    first, before the geometry, because two windows' coordinate spaces overlap.
    A click on the window's own **chrome** — its title bar, the traffic lights,
    the toolbar — is `ignore` too, and is asked *second*, ahead of
    the geometry: the click is in the draft's window and outside the draft, but
    the user is dragging or minimising the window they are typing in,
    so their attention never moved. Finder does not abandon an inline rename when
    the window is dragged, and destroying a half-typed name for it would be the
    worst kind of surprise. The view answers this with one fact — did the point
    land inside `window.contentLayoutRect` — and a window with no content view
    answers `false`, preserving the draft on a state that cannot occur. That
    rectangle rather than `contentView`'s bounds because a plain SwiftUI window
    carries `fullSizeContentView`, whose content view spans the title bar and so
    would answer `true` for the very drag this answer exists to survive.
    That one fact draws the line exactly where AppKit draws it, which leaves two
    **stated limits**, both of them clicks inside the content area and therefore
    `cancel`. A **resize drag** begun from the content side of the bottom, left
    or right edge is one: those few points are inside that rectangle and no
    mouse-down fact separates them from an ordinary click on whatever is drawn
    there, while guessing at a band would make real clicks near the tree pane's
    left edge stop cancelling — the worse error, so the limit is recorded rather
    than approximated. (The top edge is the title bar, so resizing from it is
    already exempt; and since a resize *drag* takes the mouse over from its own
    down, that `cancel` is one the view never gets to apply — the deferral limit
    below.) The **activating click** that brings the app back to the
    front is the other, and is the counterpart of the ⌘Tab note below: the
    monitor sees no other app's events, but it does see the click that returns to
    this one.
    A click *inside* `draftBounds` is `ignore` — placing the caret and
    drag-selecting are ordinary edits, and so is clicking the draft's icon column
    or its validation-reason line. Anything *else in the draft's own window* is
    `cancel`: another tree row, the editor, a tab, the bottom bar — the user's
    attention moved, and the Finder-like answer is to end the naming silently
    rather than commit something they stopped looking at. App *deactivation*
    needs no case at all: a local monitor sees no other app's events, so ⌘Tab
    away and ⌘Tab back preserves the draft for free — coming back by *clicking*
    the window being the stated limit above, since that click is this app's own.
    **`cancel` is not a swallow.** The rule decides the draft's fate, never the
    click's: the monitor returns the event unchanged, so a cancelling click also
    does what it would have done anyway — the folder toggles, the file opens, the
    right-clicked row gets its context menu. That is what Finder (and Zed) do,
    and the alternative charges the user two clicks for one intent. One row is
    the stated exception, and by construction: the **drafted row itself** has no
    menu installed while its draft is open (a menu that empties itself would
    flash an empty panel shut), and AppKit resolves the menu inside the same
    dispatch the cancel runs in — before SwiftUI has re-rendered the row with one
    — so right-clicking it beside the field cancels and opens nothing, and the
    ordinary menu is back on the next right-click. The rule
    answers a *point*, and the view layer reads that point from the mouse-**down**
    — where the user aimed, and the fact that keeps a text-selection drag out of
    the field from reading as a click elsewhere. *Applying* the answer is a
    separate moment, and for a left-click it is the matching mouse-**up**: a
    SwiftUI tap completes only when the release is still inside the view the press
    began in, while cancelling removes a create draft's row (and a rename draft's
    reason line) and shifts every row below it up. Cancelling on the down would
    land that shift in the middle of the click and the row the user pressed would
    no longer be under the release — costing exactly the second click decision A
    exists to avoid. A **context click** needs no wait and must not take one:
    `NSMenu` opens in the down's own dispatch and its tracking loop dequeues the
    release, so a deferred cancel would never be applied at all. That is what
    `cancelTiming(opensContextMenuOnMouseDown:)` answers, and the fact it asks
    for is *opens a menu on the down* rather than "is a right-click": macOS
    spells that gesture twice, and only one spelling arrives as
    `.rightMouseDown` — a **Control-click** is delivered as a `.leftMouseDown`
    carrying `.control` and is routed to the menu path later, inside AppKit's
    own `sendEvent(_:)`, long after the monitor has seen it. Classifying by event
    type alone would defer that one and leave the draft standing over the menu it
    just opened, the single gesture where the two spellings would disagree.
    Waiting has its own **stated limit**: a gesture that takes the mouse over
    from its own down — a window resize begun in the content area's edge band, a
    drag started on any non-drafted tree row — runs a modal tracking loop that
    dequeues events itself rather than letting them through `NSApp.sendEvent`,
    so the monitor hears the down (answered `cancel`) and never the release that
    would apply it. The answer is unapplied rather than lost: the draft outlives
    the gesture, still editable and still cancellable by Esc or by the next click
    outside it, and a drag that moves the drafted row's own entry drops the draft
    anyway on the tree's re-read. Cancelling on the down instead would trade this
    edge for the far commoner one above.
    **What `draftBounds` is.** The draft's *whole* region — icon column, text
    field and reason line — in the same space as `point`. The view layer gets both
    from one invisible `NSView` installed as the draft's outermost `.background`:
    SwiftUI sizes a background to its primary view, so that view's `bounds` **is**
    the draft's rectangle by construction and `convert(_:from: nil)` puts the event
    in the same space. Hit-testing the `NSTextField`'s frame instead would miss the
    icon and the reason line, and reconstructing the rect from SwiftUI's `.global`
    space would mean guessing at flipped-coordinate conversions; this way
    "clicking the icon does not cancel" holds by construction rather than by a
    measured inset, and nothing here knows about flipped coordinates. Two edges
    of that construction are the geometry answering rather than the rule bending,
    and both are stated on the rule itself: the caller passes the **visible** part
    of the rectangle (`bounds.intersection(visibleRect)`), because the tree
    scrolls and a draft scrolled out of the clip view would otherwise keep owning
    clicks on the pane's header and its neighbours — and because `visibleRect`
    alone is not that visible part: AppKit returns the superviews' visible region
    in the receiver's coordinates without intersecting the receiver's own
    rectangle, so it is routinely *larger* than `bounds` and would hand the draft
    every click in the window; and only a **create** draft
    draws an icon column of its own, so during a *rename* the row's icon — and
    the row's padding around the field — belongs to the row, falls outside the
    rectangle, and a click there cancels like any other click on the row.
    **Edges and the degenerate rectangle.** Containment is `CGRect.contains(_:)` —
    half-open, so the origin edges are inside and the `maxX`/`maxY` edges are out.
    A one-point disagreement at a boundary is invisible to a user and not worth a
    bespoke rule; matching AppKit's own convention is what keeps it predictable.
    An empty or `.null` rectangle is `cancel`, and needs no branch of its own
    because `contains` already answers `false` for both: a draft with no measured
    area cannot own a click. That is not theoretical — it is the state between the
    draft appearing and its first layout pass, and reading it as "inside" would
    make the draft briefly uncancellable, the worse failure of the two. The
    chrome check sits ahead of this one for the same reason it sits ahead of the
    geometry: a window dragged by its title bar in that same pre-layout instant
    must not be the one click that destroys the name.
    This is the project's second Foundation-level file to import `CoreGraphics`
    rather than `Foundation` (after `MinimapGeometry`), for the same reason: the
    vocabulary *is* points and rectangles, and importing the geometry types keeps
    the view from having to translate them.
    Tested (`TreeDraftDismissRuleTests`) against a rectangle with a non-zero
    origin, so a test that passes only at the zero point cannot: another window
    ignored with the point inside, far outside and with an unmeasured rect; the
    chrome ignored — outside the draft, again with an unmeasured rect, and on
    another window's chrome — with the content area outside the draft still
    cancelling, so the new check cannot swallow the rule's purpose;
    inside ignored; both `contains` edges (origin corner inside, far corner out,
    and just inside the far edge); outside on each of the four sides; both
    timings (an ordinary click deferred to the release, a context click applied
    on the down); and empty,
    zero-height, zero-width, `.null` and `.infinite` bounds; and
    `CrossPlatformAuditTests` additionally pins the half-open/empty semantics as
    platform-independent, beside `MinimapGeometry`'s.
