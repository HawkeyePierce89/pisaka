# PisakaCore — files, paths & workspace

Design documentation moved verbatim from the root `CLAUDE.md` (which now holds only a one-line-per-file index). Each entry records a file's contract, invariants and the reasoning behind non-obvious decisions — read the relevant entry before modifying that file, and update it when behavior changes.

- **`PisakaCore`** (library, `Sources/PisakaCore/`) — all domain logic. Pure,
  testable, no SwiftUI/AppKit views.
  - `OpenFile.swift` — model of an open file: `id` (UUID), optional `url`,
    `displayName` ("Untitled" when no url), `text`, `savedText`, and
    `isDirty == text != savedText`.
  - `FileService.swift` — disk read/write (`read(url:)`, `write(_:to:)`),
    directory listing (`contentsOfDirectory(at:)`), and symlink resolution
    (`symbolicLinkDestination(at:)` — the link's target string without
    dereferencing, defaulted to `nil` in a protocol extension so non-symlink-aware
    stubs are unaffected), behind the `FileServicing`
    protocol so tests can inject a stub that simulates read/write/listing
    failures. `contentsOfDirectory(at:)` returns `[DirectoryEntry]` (a public
    `Identifiable`/`Equatable` model: `url`, `isDirectory`, and a computed
    `name` from `lastPathComponent`). Dotfiles are *visible* (VS Code-style —
    `.gitignore`/`.github` are ordinary, editable entries); only the service
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
    *later* step fails are **not** rolled back (`mkdir -p`/VS Code semantics), and a
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
    `.notADirectory(name:)`) distinguishes
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
    A third defaulted method backs the **symbol index**: `fileStamp(at:) ->
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
  - `FileName.swift` — pure, testable name/path validation for the project-tree
    dialogs, in two shapes over *one* rule: the boolean predicates
    `isValidFileName(_:) -> Bool` / `parseRelativeEntryPath(_:) -> [String]?` (the
    post-OK guards) and the reasoned validators `validateSingleEntryName(_:)` /
    `validateRelativeEntryPath(_:) -> EntryPathIssue?` (which the dialogs run on
    every keystroke to show a reason and gate OK). Both predicates are *facades*
    over the same private component rule (`componentIssue(_:isReserved:)`) and, for
    the path forms, the same private splitter (`relativePathComponents(_:)`), so a
    rule can never split into two implementations and a path parses exactly when
    the validator reports no issue; parity is structural and asserted on a matrix
    in the tests anyway.
    `isValidFileName(_:)` is for the *rename* dialog: rejects an empty or
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
    prompt confirm instead of inserting one, so it is only reachable by paste.)
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
    dialogs, which accept a relative path of any depth (`centrifugo/config.json`)
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
    carrying the English text the dialog displays. The wording lives in Core, not
    the view, for the same reason `GitError.errorDescription` and
    `FileServiceError`'s `LocalizedError` texts do: the decision and its
    explanation are one rule, unit-tested together, while the AppKit prompt stays a
    thin display of whatever the validator returns.
    `validateRelativeEntryPath(_:)` (create) and `validateSingleEntryName(_:)`
    (rename) report the first offending component's issue, or `nil` when the input
    is usable. They differ in exactly two places, both deliberate. (1) A `/`: the
    path validator treats it as a separator, the single-name validator reports
    `.separatorInName` up front (rename takes one name — a path there would mean a
    *move*, a separate feature, and the entry would land on disk yet never appear
    in the tree). (2) Reserved-name semantics are **per context, mirroring each
    call site's own post-OK guard exactly**, so a dialog can never block a name its
    guard would accept or accept one it would reject: create paths use the
    case-insensitive `FileService.isReservedCreateName(_:)` (a `.GIT` component
    resolves onto the real `.git` on a case-insensitive volume), rename uses the
    exact-match `FileService.isExcludedEntryName(_:)` (a user's own `.Git` folder
    is an ordinary, visible entry). `isValidFileName` alone judges *no* reserved
    names at all — the rename call site checks `isExcludedEntryName` separately —
    which is the one documented gap in the predicate↔validator matrix.
    Foundation-only.
  - `GitRefName.swift` — pure, testable `GitRefName.isValid(_:) -> Bool` for the
    branch-switcher's "New Branch…" dialog, separate from `isValidFileName` (a
    branch name has its own, stricter grammar per `git check-ref-format`). Rejects
    an empty/whitespace-only name, a leading `-` (git's own `branch`/`checkout -b`
    refuse it, and the macOS CLI runs `git checkout -b <name> …` with no `--`
    separator so a dash-led name would be mis-parsed as an option), a
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
    tab instead of opening the same `url` twice), `updateText`,
    `markSaved`, `select`, `save(for:)` (returns `.needsSaveAs` when there is no
    url), `saveAllDirty()` (the autosave action: write every dirty file that
    *has* a url and advance its `savedText`, returning the urls actually written;
    unlike `save(for:)` it never returns `.needsSaveAs`/prompts — a url-less
    "Untitled" or clean file is skipped — and a per-file write failure is
    swallowed so the file stays dirty and the batch continues; idempotent, so an
    immediate second call writes nothing and returns `[]`, and the returned urls
    let the caller refresh Local Changes only when something changed),
    `saveAs(url:for:)`, `close(id:force:)` (returns
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
    force-closed under a key nothing reads again; see `app-shell.md`),
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
    still resolves; `nil` when no tab targets it), and `replaceText(_:for:)` — the
    text-mutating counterpart of `updateText(_:for:)` for a writer that is *not*
    the user's typing (the project-wide Replace All's `applyBufferText`). It sets
    `text` exactly as `updateText` does, leaving `savedText` alone so the tab goes
    dirty and saving stays the user's call, and additionally bumps that file's
    entry in `@Published public private(set) var textReplacementRevisions: [UUID:
    Int]` (read through `textReplacementRevision(for:)`, which reports `0` for an
    absent/unknown id; `reloadFromDisk` bumps it too, and a closed tab's entry is
    dropped in `removeFile`). The split exists for the *editor's undo stack*: a
    wholesale buffer swap invalidates every recorded undo action, but Replace All
    and the post-revert/post-merge reloads reach open tabs that are **not on
    screen**, which get no view update of their own — so the editor cannot detect
    the replacement itself and, on the later tab switch, cannot tell it from an
    ordinary switch (which must *preserve* that file's history). The token is what
    distinguishes them; `updateText` deliberately does not bump it, since a bump
    per keystroke would drop the user's undo stack as they type. See
    `CodeEditorView`'s `externalTextRevision`. A *second* per-file token,
    `@Published public private(set) var diskRevisions: [UUID: Int]` (read through
    `diskRevision(for:)`, which reports `0` for an unknown id so a caller never has
    to tell "absent" from "unchanged"; bumped by a private `bumpDiskRevision(_:)`
    and dropped in `removeFile`), means exactly one thing: **the on-disk content
    this buffer corresponds to changed**. It is bumped at every site that assigns
    `savedText` — `markSaved`, `save(for:)`, `saveAllDirty()` (per successfully
    written file), `saveAs`, `reloadFromDisk` and `reconcileSavedBaseline` — which
    is precisely the set of moments the file the buffer stands for stopped being the
    file it was: a save, an autosave, a Save As, the post-revert reload, a merge
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
    it only publishes the token. Nothing *else* watches the filesystem: Local
    Changes, the Git Log, and open tabs still refresh on demand only (so
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
    suffix *below* the root (without the root's own name, ending in the file
    name); anything else yields the absolute path — `["~"] + suffix` when the file
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
    falls through to the absolute branch), so matcher drift fails the suite. Clickable segments, copying the path, the window proxy icon,
    and an iOS bar are deliberately **out of scope** (follow-ups).
