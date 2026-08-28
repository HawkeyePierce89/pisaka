# Local History — automatic file snapshots with a browse/restore window

## Overview

A safety net independent of git: the app keeps local, per-file snapshots of every
buffer it writes, plus labeled pre-operation snapshots in front of each
worktree-mutating git operation, and a macOS window lets the user browse those
revisions, diff them against the current content and restore one.

All decision logic lands in `PisakaCore` as six new pure/Foundation-only files
(path math, value types, policy, the `FileServicing` engine, and two observable
models); the macOS layer adds one support-directory file, one window controller,
one view, and capture calls at three save sites and six gated-operation sites.
Nothing new compiles on iOS.

## Context

### Existing code the plan builds on

- `Sources/PisakaCore/SHA256.swift` — the digest, already Foundation-only. Used for
  content hashes and for the store's directory keys.
- `Sources/PisakaCore/LeetCodeCacheLayout.swift` +
  `Sources/Pisaka/Platform/LeetCodeSupportDirectory.swift` — the cache-layout pattern
  to follow exactly: pure path math in Core over a base directory the app supplies,
  no `stat`, no `realpath`, nothing created; the platform half is a handful of lines
  in the app.
- `Sources/PisakaCore/LSPInstallLayout.swift` — `directory(_:contains:)`, the one
  lexical containment rule; reused rather than restated.
- `Sources/PisakaCore/FileService.swift` — `FileServicing` already has everything the
  store needs, and every method is **synchronous and throwing**:
  `contentsOfDirectory`, `ensureDirectory`, `removeItem`, `move`, `write`, `read`,
  `fileByteCount`, and — the exact gate this feature needs for its disk-read
  captures — `readTextIfNotBinary(url:maxBytes:)`.
- `Sources/PisakaCore/ProjectSearchModel.swift` — `defaultMaxFileBytes` (1 MiB), the
  ceiling this feature reuses; `results` gives Replace All's matched file URLs before
  the batch runs.
- `Sources/PisakaCore/SymbolIndexModel.swift` — the shape for a model whose real work
  runs off the main actor through `nonisolated static` helpers over `FileServicing`.
- `Sources/PisakaCore/LeetCodeModel.swift` / `LeetCodeBrowserModel.swift` — the
  precedent for splitting a long-lived capture model from a per-window browser model
  with its own generation token.
- `Sources/PisakaCore/LineDiff.swift` — `LineDiff.rows(old:new:)` produces the
  `[DiffRow]` the existing side-by-side `DiffView` renders.
- `Sources/PisakaCore/ProjectFileWalk.swift` — `relativePath(of:under:)`, the one
  relative-path helper.
- `Sources/Pisaka/SaveTransformController.swift` — the pre-write save funnel and, more
  importantly, the one place that rewrites a buffer *through the live text view* in a
  single undoable step, with the documented `WorkspaceModel.replaceText(_:for:)`
  fallback. Restore reuses it.
- `Sources/Pisaka/AutosaveController.swift` — the three write paths and **the existing
  `onSaved` callback**, declared at line 27 as
  `((_ saved: [URL], _ createdFile: Bool) -> Void)?`, passed in at `start(…)` (line 103)
  and bound in `PisakaApp` at line 904 to refresh Local Changes and bump the tree.
  It fires from `performAutosave` (line 250) and from the reporting branch of
  `flushNow` (line 342). The **quit** flush — `PisakaApp.swift:1056`,
  `flushNow(abandoningBuffers: true)` with `reportingSaves` left `false` — returns
  early at line 333 (`guard reportingSaves else { model.saveAllDirty(); return }`) and
  therefore deliberately skips both the missing-file probe and `onSaved`, for the
  reasons written at lines 149–167 and 305–316.
- `Sources/Pisaka/PisakaApp.swift` — `save(id:)` (2509), `saveAs(id:)` (2564), the
  quit observer (1056), the two folder-switch flushes (1760, 1779) and the commit
  dialog's flush (2072), plus the **six** gated worktree operations, each raising
  `autosave.suspend()` + `localChanges.beginRevert()` synchronously before its
  `Task` hop: `commitFromDialog` (2183), `replaceAllInProject` (2462),
  `revertChanges` (2652), `createBranch` (2832), `runBranchOperation` (2894 — the
  shared body behind branch *switch* at 2760 and *checkout-remote* at 2770) and
  `applyMerge` (3110).
- `Sources/Pisaka/PisakaApp.swift`'s `openTabSnapshot()` — the existing synchronous
  buffer-text snapshot taken before a branch mutation hops; the same shape the
  pre-operation capture uses.
- `Sources/Pisaka/DiffWindowController.swift` / `ProjectSearchWindowController.swift` —
  the two window patterns; the single-window one is what Local History follows.
- `Sources/Pisaka/ProjectTreeView.swift` — `FileRowView`'s context menu and the
  `on…` callback threading from `ContentView`.
- `Tests/PisakaCoreTests/Support/StubFileTree.swift` — the in-memory `FileServicing`
  with directory ops, failure injection and call logs; the store's tests need no new
  stub.
- `Tests/PisakaCoreTests/MainWindowFrameSourceGatingTests.swift` — the template for
  the app-layer static gating suite (comment/literal-stripped matching).

### Design decisions this plan fixes

**Store shape — the metadata is the file name, so listing reads nothing.**

```text
<base>/                                    ~/Library/Application Support/Pisaka/LocalHistory
  <rootName>-<sha256(canonical root path), first 16 hex>/     one per project root
    <sha256(project-relative path), first 32 hex>/            one per file
      0000001772345678901-save-<hash16>.snapshot              content = the exact UTF-8 text
      0000001772345699999-commit-<hash16>.snapshot
```

The snapshot file *is* the content; timestamp (zero-padded 19-digit milliseconds, so
lexical order is chronological order), event tag and content hash live in the name.
Consequences: listing a file's history is one directory read with no content reads;
dedup against the newest revision is a name comparison; retention prunes on names
alone. There is no index file to fall out of step with the disk — deleting the base
directory de-provisions the feature completely, and nothing else breaks.

**Events** (a closed enum, tag → title): `save` → "Save", `replace` → "Before Replace
All", `revert` → "Before Revert", `merge` → "Before Merge Apply", `branch` → "Before
Branch Change" (both branch operations share it), `commit` → "Before Commit",
`restore` → "Before Restore".

**Retention defaults** (stated, no settings UI): maximum age **14 days**, **30
revisions per file**, and the newest revision of a file always survives both rules.
Event-labeled snapshots are not privileged. Pruning runs on capture (for the file just
captured) and once per project open (for the whole project area), always off the main
actor.

**Skip rules** (silent, all in one pure policy type): no url (untitled), no project
root or a path outside it, content whose UTF-8 byte count exceeds 1 MiB
(`ProjectSearchModel.defaultMaxFileBytes`), content that is not decodable UTF-8 (only
reachable on the disk-read path, where `readTextIfNotBinary` answers `nil`), and
content whose hash equals the file's newest stored snapshot.

**Capture on save is post-write, not pre-write.** `SaveTransformController` is the
pre-write funnel and would work, but it early-outs before reading the buffer whenever
no transform applies (the common case), and a pre-write capture stores bytes a failed
write never landed. Instead capture hangs off the points where a write has just
succeeded: `PisakaApp.save(id:)`, `PisakaApp.saveAs(id:)`, and — for every
autosave-controller write — the existing `onSaved` callback. The content is
post-transform either way, because `prepareForSave` runs before the write on every
path, including quit.

**The quit flush is covered, by extending the existing callback rather than adding a
second one.** `onSaved` exists and is bound; it is *not* invoked on the quit path, so
binding Local History to it as-is would silently drop the last save before termination
— exactly the edit a safety net most needs. The fix, all inside `AutosaveController`:

- widen the existing signature to
  `((_ saved: [URL], _ createdFile: Bool, _ isTerminating: Bool) -> Void)?` — one
  callback, one report site per path, no parallel hook;
- invoke it from the non-reporting branch of `flushNow` too, with
  `isTerminating: true` and `createdFile: false`, **without** running
  `missingDirtyPaths` — the probe stays skipped at quit exactly as documented today
  (there is no tree left to bump), so the only behavior added is the report itself;
- update the two doc comments that currently state the callback is skipped at quit
  (the `willTerminateNotification` comment at ~line 157 and the `reportingSaves`
  paragraph at ~line 305) to say what is now true: the probe and the Local Changes
  refresh are skipped at quit, the report is not.

`PisakaApp`'s binding keeps today's behavior by guarding on the new flag: the Local
Changes refresh and the tree bump run only when `!isTerminating`; the Local History
capture runs on every path.

**How the quit-time bytes are guaranteed to land.** The termination observer runs on
the main thread and the process exits when it returns, so a `Task { … }` hop is not
guaranteed to run at all. The quit capture therefore does **not** go through the
model's async chain: `LocalHistoryModel` exposes a second entry point,
`captureSavesSynchronously(urls:root:texts:)`, which calls the same synchronous
`LocalHistoryStore` methods inline on the main actor before the observer returns.
`FileServicing.write` is a synchronous throwing call, so the bytes are handed to the
kernel before control comes back. The cost is bounded and paid once per quit: at most
one directory read plus one ≤1 MiB write per *dirty titled* buffer, and dedup usually
makes it zero writes. Two consequences are stated in the doc: this is the one place
Local History does disk work on the main thread, and any work still queued on the
async chain at termination is abandoned — worst case one snapshot that a later
identical capture would have deduplicated anyway, never a corrupt one, because a
snapshot is written under a temporary name and moved into place.

**Capture before a gated operation is awaited, which is what makes it race-free.**
Each of the six operations already raises the writer bracket *synchronously* before its
`Task` hop; the capture's inputs (buffer texts, target list) are collected in that same
synchronous stretch — the way `openTabSnapshot()` already is — and the
`await localHistory.captureBeforeOperation(…)` is the **first** `await` inside the task
body, ahead of the operation's own `await`. Every byte it stores is therefore
pre-operation by construction. The awaited work hops off the main actor to read the
remaining targets from disk, hash, dedup and write, and returns only when they are
stored. Target sets (no new git calls):

| Operation | Function (line) | Disk targets | Always added |
|---|---|---|---|
| Commit | `commitFromDialog` (2183) | `localChanges.changedFiles` | every open titled tab under the root, from its **buffer** text |
| Replace All | `replaceAllInProject` (2462) | `projectSearch.results.map(\.fileURL)` | ditto |
| Revert | `revertChanges` (2652) | the `ChangedFile`s being reverted | ditto |
| Branch create | `createBranch` (2832) | `localChanges.changedFiles` | ditto |
| Branch switch / checkout-remote | `runBranchOperation` (2894) | `localChanges.changedFiles` | ditto |
| Merge apply | `applyMerge` (3110) | the resolved file | ditto |

Branch switch and branch create are two separate functions with two separate brackets;
they share the `branch` event label but are two distinct call sites. A file that has an
open tab is captured from the buffer and **not** read from disk, so one operation never
leaves two same-labeled snapshots of one file. The disk-read set is capped at **200
files** per operation; beyond that the extras are skipped (a stated limit) so a huge
worktree cannot put an unbounded read pass in front of a git command.

**Restore is a buffer edit, never a disk write.** Local History keeps the reader
invariant: it takes no writer gate, is not gated by one, and its only writes land in
its own store. Restore replaces the buffer — through the live text view as one undoable
step, via the documented `WorkspaceModel.replaceText(_:for:)` fallback otherwise —
leaving the tab dirty; the ordinary save funnel puts it on disk. Restoring a file with
no open tab opens it in a tab first. Before the replacement, the current buffer is
captured under the `restore` label, so a restore is itself reversible from history as
well as by one ⌘Z.

The through-the-view routing already exists exactly once, inside
`SaveTransformController`'s private `apply(_:in:)` bracket. Rather than copy that
AppKit bracket, `SaveTransformController` gains one documented entry point,
`applyRestore(_ text: String, to id: UUID)`, that builds a single whole-buffer
`SaveTransformPlan` (its `init` is public, and its position remap moves the caret) and
runs it through the same path. Its doc comment and its entry in
`docs/architecture/core-editorconfig.md` are updated: it is the one funnel that
rewrites a buffer through the live text view, and a save is no longer its only caller.

**Window**: one reusable window (the `ProjectSearchWindowController` pattern),
retargeted per file rather than one window per open. Left: revisions newest-first
(relative time + absolute timestamp + event title). Right: the existing `DiffView` over
`LineDiff.rows(old: revision, new: current)`. A Restore button, and an empty state
("No history for this file yet.") rather than an error. Opened from **File ▸ Local
History…** (⌘⇧H — free; ⌘⇧L/T/C/M/F/O/B and ⌘⇧G are all taken) and from a file row's
context menu in the project tree.

## Development Approach

- **Testing approach**: Regular (code first, then tests), per this repository's habit.
- Core first, bottom-up: path math → policy → engine → models → app wiring → window.
- Every task ends with `swift test` green before the next one starts.
- App-layer files are untested by convention, so the two app tasks carry a static
  gating suite instead (`LocalHistorySourceGatingTests`), matching against comment- and
  literal-stripped source the way every sibling suite does.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**

## Implementation Steps

### Task 1: Snapshot identity and store layout (Core)

**Files:**
- Create: `Sources/PisakaCore/LocalHistorySnapshot.swift`
- Create: `Sources/PisakaCore/LocalHistoryLayout.swift`
- Create: `Tests/PisakaCoreTests/LocalHistorySnapshotTests.swift`
- Create: `Tests/PisakaCoreTests/LocalHistoryLayoutTests.swift`

- [x] `LocalHistoryEvent`: closed enum with a stable lowercase `tag` (the file-name
      token) and a display `title`; an `init?(tag:)` inverse
- [x] `LocalHistorySnapshot`: `Equatable, Sendable` value type — `fileName`,
      `timestamp: Date`, `event`, `contentHash: String`; ordering newest-first
- [x] `LocalHistoryLayout`: pure path math over `base` (lexical normalization copied
      from `LeetCodeCacheLayout`'s initializer, `contains(_:)` through
      `LSPInstallLayout.directory(_:contains:)`), `directoryName = "LocalHistory"`,
      `projectDirectory(forRoot:)`, `fileDirectory(forRoot:relativePath:)`
- [x] snapshot file-name encode/parse on the layout: zero-padded 19-digit milliseconds
      + `-` + event tag + `-` + 16 hex hash + `.snapshot`; parsing refuses anything
      malformed (returns `nil`, never a partial snapshot)
- [x] tests: name round-trips for every event case; lexical name order equals
      chronological order across a millisecond/second/day boundary; malformed names
      (wrong field count, non-numeric millis, unknown tag, wrong extension, a nested
      path) all parse to `nil`; two different roots and two different relative paths
      give different directories, and the same input gives the same directory twice;
      `contains` accepts everything the layout produces
- [x] run `swift test` — must pass before Task 2

### Task 2: Capture policy and retention (Core)

**Files:**
- Create: `Sources/PisakaCore/LocalHistoryPolicy.swift`
- Create: `Tests/PisakaCoreTests/LocalHistoryPolicyTests.swift`

- [x] `LocalHistoryPolicy`: the ceilings
      (`maxContentBytes = ProjectSearchModel.defaultMaxFileBytes`, `maxAge = 14 days`,
      `revisionsPerFile = 30`, `maxPreOperationFiles = 200`) as named constants with
      their reasons in doc comments
- [x] `capture(of:relativePath:latestHash:) -> LocalHistoryCaptureDecision` — the one
      skip rule: `.skip(reason)` for pathless/outside-root/oversized/unchanged,
      `.capture(hash:)` otherwise; the hash comes from `SHA256`
- [x] `prune(_ snapshots:, now:) -> (keep: [LocalHistorySnapshot], delete: [LocalHistorySnapshot])`
      — age first, then the count cap, then the unconditional reinstatement of the
      newest revision
- [x] tests: each skip reason in isolation and the precedence between them; a 1 MiB
      content is captured and 1 MiB + 1 byte is not (byte count, not character count —
      include a multi-byte case); identical content skips, one changed byte does not;
      retention drops everything older than the age bound *except* the newest;
      retention keeps exactly 30 when handed 31 and 100, always the newest ones; an
      empty input and a single-revision input are both no-ops; a labeled snapshot is
      pruned on the same terms as a `save` one
- [x] run `swift test` — must pass before Task 3

### Task 3: The store engine (Core)

**Files:**
- Create: `Sources/PisakaCore/LocalHistoryStore.swift`
- Create: `Tests/PisakaCoreTests/LocalHistoryStoreTests.swift`

- [ ] `LocalHistoryStore`: a value type over `FileServicing` + `LocalHistoryLayout` +
      `LocalHistoryPolicy`, all methods **synchronous** and `nonisolated` (the
      `SymbolIndexModel` shape — the caller owns the hop, which is what lets the quit
      path call them inline)
- [ ] `revisions(root:relativePath:) -> [LocalHistorySnapshot]` — one directory read,
      names parsed, unparseable entries ignored, newest first; a missing directory is
      an empty list, never an error
- [ ] `content(of:root:relativePath:) -> String?` — read one snapshot
- [ ] `capture(text:root:relativePath:event:now:) -> LocalHistorySnapshot?` — asks the
      policy against the newest revision's hash, writes through a temporary name and
      one `move` (the `LSPInstallEngine` atomicity rule: a half-written snapshot never
      appears in a listing), then prunes that file's directory
- [ ] `prune(root:now:)` — walk the project area's file directories and apply
      retention; remove a file directory left empty
- [ ] every write path degrades: a failing `ensureDirectory`/`write`/`move`/`removeItem`
      loses the snapshot and nothing else (the `LeetCodeCatalog` degrading-write rule)
- [ ] tests against `StubFileTree`: capture then list round-trip; a second identical
      capture writes nothing (assert `writtenPaths`); a changed capture writes one file;
      capture writes through a temporary name and exactly one `move`; an injected write
      failure leaves no partial file and throws nothing; capture prunes the same file's
      excess revisions; `prune(root:)` bounds a whole project area and leaves the newest
      of each file; listing a never-captured file is `[]`; a foreign file in a snapshot
      directory is ignored by listing and left alone by pruning
- [ ] run `swift test` — must pass before Task 4

### Task 4: The capture model (Core)

**Files:**
- Create: `Sources/PisakaCore/LocalHistoryModel.swift`
- Create: `Tests/PisakaCoreTests/LocalHistoryModelTests.swift`

- [ ] `@MainActor final class LocalHistoryModel: ObservableObject` owning the store, the
      base URL and a **serial write chain** (`private var chain: Task<Void, Never>?`,
      each new unit of work appended) so two captures of one file can never interleave
      or race the same "newest revision" read
- [ ] `captureSaves(urls:root:texts:)` — fire-and-forget through the chain; the ordinary
      save path
- [ ] `captureSavesSynchronously(urls:root:texts:)` — the **quit** path: the same store
      calls, inline on the main actor, so the bytes are written before the termination
      observer returns; documented as the one main-thread disk write in the feature,
      bounded by the number of dirty titled buffers, and as bypassing the chain (whose
      queued work the process is about to discard anyway)
- [ ] `captureBeforeOperation(event:root:bufferTexts:diskTargets:) async` — collects what
      the caller handed it, drops disk targets that already have a buffer text, applies
      `maxPreOperationFiles`, then does the reads
      (`readTextIfNotBinary(url:maxBytes:)` — the binary/oversize gate), hashes, writes
      and prunes off the main actor; returns only when every byte is stored
- [ ] `pruneProject(root:)` — the project-open sweep, fire-and-forget
- [ ] relative paths through `ProjectFileWalk.relativePath(of:under:)`; a url outside the
      root is skipped
- [ ] tests: `captureBeforeOperation` returns only after the store holds every expected
      snapshot (a causal wait through `Gate`, never a delay); a file with both a buffer
      text and a disk target is captured once, from the buffer; a binary disk target
      (`StubFileTree.skippedFiles`) is silently absent; the disk-target cap is enforced
      and the buffer captures still all land; two overlapping `captureSaves` of one file
      produce one snapshot for identical text and two ordered ones for different text;
      `captureSavesSynchronously` leaves the snapshots in the store by the time it
      returns, with no await in between, and dedups against what a prior `captureSaves`
      wrote; a url outside the root is skipped; `pruneProject` bounds the area
- [ ] run `swift test` — must pass before Task 5

### Task 5: The browser model (Core)

**Files:**
- Create: `Sources/PisakaCore/LocalHistoryBrowserModel.swift`
- Create: `Tests/PisakaCoreTests/LocalHistoryBrowserModelTests.swift`

- [ ] `@MainActor final class LocalHistoryBrowserModel: ObservableObject` — the window's
      state: `fileURL`, `relativePath`, `revisions`, `selected`, `diffRows`,
      `isLoading`, `isEmpty`
- [ ] one monotonic generation token captured **synchronously** before every `Task` hop
      (listing, content load, diff computation); a superseded result is discarded, never
      published
- [ ] `open(file:root:)` — retargeting the window clears the previous file's rows before
      the new listing lands, so no stale content is ever shown against a new file
- [ ] `select(_:currentText:)` — loads the revision's content off-main and computes
      `LineDiff.rows(old: revision, new: current)` there too
- [ ] `restore(currentText:) -> LocalHistoryRestore?` — the pure restore plan: `nil` when
      nothing is selected or the selected content equals the current text, otherwise the
      pre-restore capture request plus the replacement text
- [ ] tests: a stale listing cannot publish over a newer one (two loads staged with
      `Gate`, the older released last); retargeting clears rows; a file with no history
      lands `isEmpty`, not an error; selecting a revision produces the expected
      `[DiffRow]`; the restore plan is `nil` for an identical revision and carries the
      revision's text otherwise; the pre-restore capture is part of the plan
- [ ] run `swift test` — must pass before Task 6

### Task 6: Capture wiring (macOS app)

**Files:**
- Create: `Sources/Pisaka/LocalHistorySupportDirectory.swift`
- Modify: `Sources/Pisaka/AutosaveController.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Create: `Tests/PisakaCoreTests/LocalHistorySourceGatingTests.swift`

- [ ] `LocalHistorySupportDirectory` (`#if os(macOS)`):
      `…/Application Support/Pisaka/LocalHistory`, beside `LanguageServers/` and
      `LeetCode/`, the `LeetCodeSupportDirectory` shape
- [ ] `PisakaApp`: hold `LocalHistoryModel`; prune the project area when the project root
      changes and at launch
- [ ] `AutosaveController`: **extend the existing** `onSaved` to
      `(_ saved: [URL], _ createdFile: Bool, _ isTerminating: Bool) -> Void`; keep the
      two current call sites (`performAutosave`, the reporting branch of `flushNow`)
      passing `isTerminating: false`, and add the invocation to the non-reporting branch
      of `flushNow` with `isTerminating: true` and `createdFile: false`, without running
      `missingDirtyPaths` there
- [ ] `AutosaveController` doc comments: rewrite the `willTerminateNotification` comment
      (~line 157) and the `reportingSaves` paragraph (~line 305), which today say the
      quit flush skips `onSaved` — what it skips now is the probe and the Local Changes
      refresh, not the report
- [ ] `PisakaApp`'s `onSaved` binding (~line 904): run the Local Changes refresh and tree
      bump only when `!isTerminating` (today's exact behavior); call
      `localHistory.captureSavesSynchronously(…)` when `isTerminating` and
      `localHistory.captureSaves(…)` otherwise, reading each saved url's post-transform
      text out of `model.openFiles`
- [ ] save captures at the two direct sites: `save(id:)` (2509) and `saveAs(id:)` (2564),
      after a successful write
- [ ] the **six** gated operations each `await localHistory.captureBeforeOperation(…)` as
      the first `await` inside their task body, with inputs collected in the synchronous
      stretch after the writer bracket, and the target sets from the table above:
      `commitFromDialog`, `replaceAllInProject`, `revertChanges`, `createBranch`,
      `runBranchOperation`, `applyMerge`; each call site gets a comment naming what it is
      pre-empting
- [ ] `LocalHistorySourceGatingTests`, part one: every new app file is inside
      `#if os(macOS)`; `captureBeforeOperation` is named in `PisakaApp.swift` exactly
      **six** times, once per bracket site; `autosave.suspend()` and
      `localChanges.beginRevert()` still appear exactly six times each, so a new
      operation cannot be added without a capture; the save capture is named at exactly
      the three save sites (`save`, `saveAs`, the `onSaved` binding); `onSaved?(` is
      invoked at exactly three places in `AutosaveController.swift`, so no write path can
      go unreported again; and Local History never names
      `autosave.suspend`/`beginRevert` (it does not take the writer gate)
- [ ] run `swift test` — must pass before Task 7

### Task 7: The history window and restore (macOS app)

**Files:**
- Create: `Sources/Pisaka/LocalHistoryWindowController.swift`
- Create: `Sources/Pisaka/LocalHistoryView.swift`
- Modify: `Sources/Pisaka/SaveTransformController.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Sources/Pisaka/ProjectTreeView.swift`
- Modify: `Tests/PisakaCoreTests/LocalHistorySourceGatingTests.swift`

- [ ] `SaveTransformController.applyRestore(_:to:)` — one whole-buffer
      `SaveTransformPlan` through the existing private view bracket, with the existing
      model fallback; update the class doc comment ("only a save calls this" is no longer
      true)
- [ ] `LocalHistoryWindowController` — one reusable window (the
      `ProjectSearchWindowController` pattern), `closeAll()` on termination beside the
      other window controllers
- [ ] `LocalHistoryView` — revisions list (event title + absolute and relative
      timestamp), the existing `DiffView` on the right, an empty state, a Restore button;
      `.interfaceScaled(settings)` and `.preferredColorScheme` on its own root like
      `DiffWindowContent`, with the diff panes staying on `settings.fontSize`
- [ ] restore action in `PisakaApp`: open the file in a tab if none holds it, capture the
      current buffer under `restore`, then `saveTransform.applyRestore(…)`
- [ ] **File ▸ Local History…** (⌘⇧H), disabled without a titled selected tab; a "Local
      History" item on `FileRowView`'s context menu threaded from `ContentView` as
      `onShowLocalHistory`
- [ ] `LocalHistorySourceGatingTests`, part two: the restore is routed through
      `SaveTransformController` and no second file names
      `beginSaveTransformRewrite`/`replaceCharacters` for a restore; the window declares
      no zoom surface it should not; the two open sites (menu item, tree row) both exist
- [ ] run `swift test` — must pass before Task 8

### Task 8: Verify acceptance criteria

- [ ] `swift test` — the whole suite green
- [ ] `swiftlint --strict` from the repository root — clean
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`
      after `xcodegen generate`
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
      — compiles unchanged
- [ ] confirm by test inventory that each acceptance criterion has a named test: one
      snapshot per save and none for an identical re-save; the quit flush reporting its
      saves and the synchronous capture landing before it returns; labeled pre-operation
      snapshots for all **six** operations; listing/diff/restore; retention bounds with
      the newest surviving; oversized, binary and pathless buffers skipped silently

### Task 9: Update documentation

- [ ] Create `docs/architecture/core-local-history.md` with a full entry per new Core
      file and per new app file (both halves in one doc, the `core-leetcode.md` shape),
      including the store diagram, the retention numbers, the awaited pre-operation
      capture and why it is race-free across all six sites, the extended `onSaved`
      contract and how the quit-time write is guaranteed to land, the restore routing,
      and the stated limits
- [ ] `CLAUDE.md`: one index block for the six Core files and the three app files, plus
      one short cross-cutting bullet — Local History is a reader with its own store
      outside the project, never takes the writer gate, is never gated by it, its restore
      is a buffer edit rather than a disk write, and the quit flush is the one place it
      writes on the main thread
- [ ] `docs/architecture/app-shell.md`: update the `AutosaveController` entry for the
      widened `onSaved` (three parameters, invoked on every write path including quit;
      the probe and the Local Changes refresh remain quit-exempt)
- [ ] `docs/FEATURES.md`: a Local History feature entry with the retention defaults and
      the shortcut, and its limits in "Known limitations" — edits made by other
      applications are not captured (nothing outside the app's own save funnel and
      worktree operations is seen), the store holds copies of file contents on the local
      disk under `~/Library/Application Support/Pisaka/LocalHistory`, deleting that
      directory removes the feature's data completely, and the 200-file per-operation
      read ceiling
- [ ] `README.md`: one line in the feature list plus the ⌘⇧H shortcut
- [ ] `docs/architecture/core-editorconfig.md`: update the `SaveTransformController`
      entry for its second caller

## Post-Completion (manual, by the user)

- Open the window on a file with a long history and confirm the listing, the diff and a
  Restore that a single ⌘Z undoes.
- Run a Replace All, a branch switch and a branch create in a real repository and confirm
  the labeled pre-operation snapshots are there and restorable.
- Edit a file and quit with ⌘Q without saving; reopen and confirm the quit-time save is
  in the file's history.
