# Local History: readable path record, history follows a move, deleted files come back, user labels

## Overview

Local History (macOS only) keys every file's revisions by a one-way digest of the project-relative path. Because of that, the store cannot be read backwards, a rename or move strands a file's history, and a deleted file cannot be brought back from its own revisions. Separately, the user has no way to put a label of their own on a revision.

This plan closes all four gaps:

1. Every per-file digest directory gets a small readable **path record**. This is the structural change.
2. The project tree's rename and drag-and-drop move **carry the history** to the new key, by reading those records.
3. The tree's delete **captures before it removes**, a Restore into a missing path **recreates the file**, and a new "Deleted Files…" command reaches the history of a file that is gone.
4. A new "Put Label…" command snapshots every open project-backed text buffer under a **user label** that lives on disk and survives a relaunch.

The feature stays what it is. It reads the user's files and writes only its own store. It never takes the writer gate and is never gated by it. Every failure is silent and the disk is the whole state. Retention stays 14 days / 30 revisions per file, with the newest revision always kept.

Three claims bend, and each is stated where it bends:

- the restore gains one worktree create;
- the tree's delete becomes a capture site;
- a labelled capture is exempt from dedup.

## Context

- **Core files:** `Sources/PisakaCore/LocalHistorySnapshot.swift`, `LocalHistoryLayout.swift`, `LocalHistoryPolicy.swift`, `LocalHistoryStore.swift`, `LocalHistoryModel.swift`, `LocalHistoryBrowserModel.swift`
- **App files:** `Sources/Pisaka/PisakaApp.swift` (`performMove`, `deleteItem`, `restoreFromLocalHistory`, the File menu's `CommandGroup(replacing: .saveItem)`, `openBufferTexts()`), `LocalHistoryView.swift`, a new `Sources/Pisaka/LocalHistoryPrompts.swift`
- **Tests:** `Tests/PisakaCoreTests/LocalHistory{Snapshot,Layout,Policy,Store,Model,BrowserModel,SourceGating}Tests.swift`, `LintConfigurationTests.swift`, the helpers `Support/StubFileTree.swift` and `Support/Gate`
- **Docs and config:** `docs/architecture/core-local-history.md` (read in full before starting), `CLAUDE.md`, `docs/FEATURES.md`, `README.md`, `.swiftlint.yml`, `docs/architecture/style-lint.md`
- **Patterns to follow:**
  - The store is a synchronous `nonisolated` value type; the caller owns the hop.
  - Every capture unit is appended to the model's one serial `Task` chain (`append(_:)`).
  - The clock is read in the entry point, before the work joins the chain.
  - Writes go to a temporary name first and are renamed into place (`.partial`).
  - Every delete goes through `discard(_:)`, which checks `layout.contains`.
  - The browser model uses one generation token and `offMain`.
  - The app layer holds no decisions.
- **Dependencies:** none new.

### Decisions taken here (resolved with the user, or settled by the code)

- **The delete capture reads synchronously and writes in the background.** In the main-thread stretch before `removeItem`, `LocalHistoryModel` reads the text of the files about to be deleted:
  - open buffers come from their tabs;
  - the rest come from disk through `readTextIfNotBinary` under the 1 MiB ceiling, at most `maxPreOperationFiles` (200) files, binary skipped.

  It then appends only the store writes to the chain and returns. The delete waits on its own bounded reads and never on the chain or a running sweep. A fire-and-forget unit could not work here: it would read the files only after the removal.
- **The ⌘Z clause of AC4 is dropped.** A recreated file has no tab, so `SaveTransformController.applyRestore` falls back to `WorkspaceModel.replaceText` and there is no undo step back to empty. The existing "⌘Z guarantee" known limit gains one sentence saying so. `applyRestore` is not changed.
- **The path record:**
  - It is a file named `path` (no extension) in each file directory.
  - Its bytes are the lexically normalised relative path in UTF-8: exactly the digest input, no newline.
  - Its temporary name is `path.partial`.
  - **Capture writes, readers verify.** `capture(...)` writes the record only when the directory listing it already holds shows no `path` entry. It never reads the record's content, so a dedup'd capture still costs one directory read and no content read.
  - Verification happens on the read side only. The checks are: the text is non-empty, already normalised and does not start with `/`, and its 32-hex digest equals the directory's own name. `recordedPaths`, `migrate` and every other reader apply them. A reader that finds a wrong record treats the directory as record-less.
  - **A present-but-wrong record is not corrected by capture.** The only thing that corrects one is migration's own rewrite of the records it moves or merges into. An example of a wrong record is a crash between moving a directory and rewriting its record. This is accepted: such a directory stays readable forwards and is in the same position as a pre-upgrade directory, while no listing or migration is ever misled by it.
  - `LocalHistoryLayout` owns the name, the codec, the verification and a public normaliser of relative paths. The record and the digest then share one spelling, and migration compares prefixes in that same spelling.
- **Where the label text lives:** in a sidecar beside the labelled snapshot in the same file directory, named `<snapshot file name>.label`, with temporary name `<snapshot file name>.label.partial`.
  - Each file directory stays self-contained. Retention deletes a label together with its snapshot, and migration carries both with no project-level index.
  - One Put Label writes the same normalised text into every sidecar of that capture. All of them are written from one value, so one labelled capture resolves to one text.
  - The snapshot name codec is unchanged.
  - Neither sidecar name parses as a snapshot, so listing, dedup and retention look straight through them.
  - The sidecar is written before its snapshot, so a row never appears ahead of its text. If the snapshot write then fails, the sidecar is an orphan that the sweep reclaims.
- **Two new events:** `.delete` (tag `delete`, title "Before Delete") and `.label` (tag `label`, title "Label"). Both tags are lowercase ASCII without a dash. No event is added for a file move.
- **Dedup exemption is an explicit policy input.** `LocalHistoryPolicy.capture(of:relativePath:latestHash:event:)` takes the event as a required parameter, and the policy's rule is that a `.label` capture is never `.unchanged`. The store passes its event through and makes no decision of its own. Every existing caller states its event, including the restore preflight in `PisakaApp` (`.restore`).
- **Label text rules live in Core:**
  - `LocalHistoryPolicy.maxLabelLength = 100` characters.
  - `LocalHistoryPolicy.label(from:) -> String?` trims whitespace and newlines. It answers `nil` for an empty result, for text longer than 100 characters, or for text that still contains a line break.
  - The prompt's button and the sidecar reader both ask this one function. A sidecar whose text fails it displays as the plain event title.
- **Migration uses records only, for files and folders alike.**
  - The store finds every verified recorded path equal to the old path, or under it at a `/` boundary (so `a` never matches `ab/x`), and re-keys it under the new prefix.
  - A directory without a verified record does not move. This is AC9: a file never captured since the upgrade does not follow a rename.
  - Per directory, the store tries one directory `move` and then rewrites the record.
  - If that move fails (in practice because the destination exists), it merges entry by entry:
    - a snapshot or sidecar name present on both sides keeps the destination's copy and discards the source's;
    - the source's record and the emptied source directory are then removed;
    - the destination's record is made correct, which also corrects a wrong one;
    - the destination is pruned by the ordinary per-file rule, with label sidecars deleted alongside their snapshots.
  - Any failure leaves that directory, or that entry, where it was.
- **The delete capture walks the item being deleted through `FileServicing`, not `ProjectFileWalk`.**
  - It honours no `.gitignore`, because an ignored `.env` is exactly what a user regrets deleting.
  - It descends depth-first in listing order and stops as soon as 200 disk targets are collected.
  - It skips `FileService.isExcludedEntryName` entries.
  - It does not descend into or capture symlinks (`symbolicLinkDestination(at:) != nil`), because deleting a link leaves its target intact.
  - A url that cannot be listed as a directory is treated as the single file.
  - Buffers win, as in `captureBeforeOperation`.
- **"Missing on disk" is one Core question:** `LocalHistoryStore.isMissing(root:relativePath:)` answers `fileStamp(at:) == nil`. "Deleted Files…" and the restore's recreate branch both ask it, so the store remains the only Local History type that asks the file service about anything.
- **Capture-site naming.** The ticket's "tenth capture site" does not add up: 3 save sites plus 7 brackets already make ten. The docs therefore name the site ("the project tree's delete") instead of giving it an ordinal. The gating suite pins the count of delete sites cross-file against a number stated in `core-local-history.md`.
- **Menu shape:** "Deleted Files…" and "Put Label…" are flat items directly below the existing "Local History…" (⌘⇧H) in the File menu, with no shortcuts. The existing item and its shortcut are untouched, and no submenu is introduced. AC4's "File ▸ Local History ▸ Deleted Files…" refers to this group.
- **Put Label enablement copies no buffer text.** The Core predicate takes the open tabs' urls: the `url`s of `model.openFiles` whose `kind` is `.text`. Menu validation therefore never calls `openBufferTexts()`; only the Put Label action itself does.
- **Prompts are `NSAlert`-based**, in the new `LocalHistoryPrompts.swift` (inside `#if os(macOS)`), the way `FilePanels` hosts the delete confirmation.
  - The label prompt has a text-field accessory whose "Put Label" button is disabled while `LocalHistoryPolicy.label(from:)` refuses the text.
  - The deleted-files prompt has a pop-up accessory listing the paths in order.
  - An empty list shows a short informational alert ("No deleted files with history in this project.") and opens nothing.
  - The file carries the `LocalHistory` prefix so `LocalHistorySourceGatingTests` covers it by name. It names no writer gate and no `revertInFlight`.
- **`PisakaApp.swift` is at its `file_length` and `type_body_length` ceilings.**
  - Everything that can live elsewhere does: the prompts go in the new file, every decision in Core.
  - The lines that must be in `PisakaApp` are the move hook, the delete capture, the recreate branch, the two menu items and their two short actions.
  - Both ceilings are raised by the **measured** amount, with a reasoning paragraph in `.swiftlint.yml` in the established style. `LintConfigurationTests`' pinned numbers and `style-lint.md` move with them.

## Development Approach

- **Testing approach:** regular (code first, then tests), task by task. Every Core rule gets `swift test` coverage through `StubFileTree`, `Gate` and causal rendezvous, never delays.
- Complete each task fully before moving to the next. Existing assertions that the new record changes must be updated in the same task, for example "exactly one `move`" and `writtenPaths` on a first capture.
- No brand or product names of other editors anywhere: code, comments, docs, commit messages.
- Prefer set equality over counting in tests. Where a count is the only shape, pin it cross-file.
- Run `xcodegen generate` before any app build once the new app file exists.
- Every `xcodebuild` uses `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build`.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**

## Implementation Steps

### Task 1: Vocabulary and on-disk codecs (events, path record, label sidecar, label text rule)

**Files:**
- Modify: `Sources/PisakaCore/LocalHistorySnapshot.swift`, `Sources/PisakaCore/LocalHistoryLayout.swift`, `Sources/PisakaCore/LocalHistoryPolicy.swift`
- Modify: `Tests/PisakaCoreTests/LocalHistorySnapshotTests.swift`, `LocalHistoryLayoutTests.swift`, `LocalHistoryPolicyTests.swift`

- [x] Add `.delete` ("Before Delete") and `.label` ("Label") to `LocalHistoryEvent`, both lowercase ASCII tags without a dash. Update the enum's doc to cover them.
- [x] In `LocalHistoryLayout`, add the following. The layout stays pure path math with no file system access.
  - the public relative-path normaliser (the one `fileDirectory` already applies);
  - the record name `path` and its encode;
  - the verifying decode, which answers the path only when the digest matches the directory name and the text is non-empty, normalised and relative;
  - the label sidecar name codec (snapshot name ↔ `<name>.label`);
  - one predicate for this feature's own temporaries: a parseable snapshot name plus `.partial`, `path.partial`, or a valid sidecar name plus `.partial`.
- [x] In `LocalHistoryPolicy`, add `maxLabelLength = 100` and `label(from:)`. Make `event` a required input of `capture(...)`, with `.label` never answering `.unchanged`. Update every caller, including `PisakaApp`'s restore preflight (`.restore`).
- [x] Tests:
  - the tag vocabulary by set equality, including `delete` and `label`, and every tag round-tripping through the name codec;
  - the "Before" title rule restated as every event except `.save` and `.label`;
  - neither `path`, `path.partial`, a sidecar name nor a sidecar temporary parses as a snapshot;
  - the temporaries predicate accepts exactly the three own shapes and refuses a foreign `.partial`;
  - the record verifies only against its own digest directory, and a mismatched, empty, absolute or non-normalised text decodes to `nil`;
  - the label rule: trimming, empty or whitespace-only refused, exactly 100 accepted, 101 refused, interior line break refused;
  - `.label` with `latestHash` equal to the content hash still captures, while every other event (set over `allCases` minus `.label`) skips as `.unchanged`.
- [x] Run `swift test`; it must pass before Task 2.

### Task 2: Store: path record on capture, labelled capture, record-aware sweep, path listing

**Files:**
- Modify: `Sources/PisakaCore/LocalHistoryStore.swift`
- Modify: `Tests/PisakaCoreTests/LocalHistoryStoreTests.swift`

- [x] **Record write in `capture(...)`, driven by the listing only.**
  - After the decision, if the directory holds at least one snapshot (already, or after this write) and the directory listing already in hand shows no `path` entry, write the record.
  - Write it as temporary → rename; failure is silent.
  - Capture never reads the record's content. A present record, correct or not, is left alone, so a dedup'd capture still costs one directory read and no content read.
  - A dedup'd capture into a directory that already has snapshots but no `path` entry still writes the record. This is AC9's "the first capture after the upgrade writes their record".
- [x] **Labelled capture.** Add a `label: String?` parameter (default `nil`) to `capture(...)`, used only with `.label`. Write the sidecar (temporary → rename) before the snapshot, using the same retry discipline. When retention deletes a `.label` snapshot, its sidecar goes with it.
- [x] **Sweep (`prune(directory:)`).**
  - Reclaim every own temporary (the Task 1 predicate) and every orphan sidecar whose snapshot is not in the listing.
  - A directory that then holds no snapshot and nothing foreign (only its record, or nothing) counts as empty. Remove the record, re-list, and remove the directory only if the re-list is empty. This keeps the existing re-list guard against a concurrent quit-time capture.
  - A directory holding a foreign entry is still left alone.
- [x] **Readers, each silent on failure and each verifying records:**
  - `recordedPaths(root:) -> [String]`: one directory read of the project directory plus one record read per file directory. A record that is absent or fails verification makes its directory record-less, and it is skipped. An unreadable store answers `[]`.
  - `isMissing(root:relativePath:) -> Bool`.
  - `labelText(of:root:relativePath:) -> String?`: reads the sidecar and answers it only if `LocalHistoryPolicy.label(from:)` accepts it.
- [x] Tests:
  - The first capture writes the record through a temporary and one extra `move`; a second capture writes nothing and reads no record (update the existing "exactly one move" / `writtenPaths` assertions accordingly, and assert `readPaths` excludes `path`).
  - A dedup'd capture into a directory with snapshots and no `path` entry writes the record.
  - A present-but-wrong record is **not** rewritten by capture (bytes unchanged afterwards), and `recordedPaths` skips that directory.
  - A labelled capture writes the sidecar before the snapshot (assert the order of `moves`); the same text twice under `.label` yields two revisions.
  - Pruning a label snapshot removes its sidecar.
  - The sweep reclaims a record-only directory (record and directory gone), an orphan sidecar, `path.partial` and a sidecar `.partial`, and leaves a directory with a foreign file alone.
  - `recordedPaths` lists only verified records; `isMissing` is true for an absent file and false for a present one; `labelText` returns `nil` for a missing or invalid sidecar.
- [x] Run `swift test`; it must pass before Task 3.

### Task 3: Store and model: history follows a rename or move

**Files:**
- Modify: `Sources/PisakaCore/LocalHistoryStore.swift`, `Sources/PisakaCore/LocalHistoryModel.swift`
- Modify: `Tests/PisakaCoreTests/LocalHistoryStoreTests.swift`, `LocalHistoryModelTests.swift`

- [x] Add `LocalHistoryStore.migrate(root:from:to:now:)` per the decision above:
  - the affected set comes from `recordedPaths` (verified records only), with `/`-boundary prefix matching on normalised paths;
  - per directory: one directory `move`, then a record rewrite;
  - on a failed move, fall back to an entry-by-entry merge: the destination's copy wins a name clash, the source's record and emptied directory are removed through `discard`, the destination record is made correct, and the destination is pruned by the per-file rule together with its sidecars;
  - each directory fails silently on its own.
- [x] Add `LocalHistoryModel.followMove(from:to:root:)`:
  - it keys both urls with `relativePath(of:under:)`;
  - it returns without touching the chain when either side cannot be keyed or the two paths are equal;
  - otherwise it appends the migration to the serial chain, fire-and-forget;
  - it reads the clock at the entry point for the merge's prune;
  - it takes no gate.
- [x] Tests (store):
  - a file rename carries every revision with original names, timestamps and events, and the record now names the new path;
  - a folder move re-keys every recorded descendant, and a record-less descendant stays under its old key;
  - prefix `a` does not move `ab/x`;
  - a merge into an existing destination lists both histories in one directory, keeps the destination's copy on a name clash, and prunes the merged list by the per-file rule (with a small `revisionsPerFile`);
  - a merge into a destination holding a wrong record leaves a correct record;
  - label sidecars travel with their snapshots in both paths;
  - an injected `move` failure (`moveFailures`) leaves the source directory intact and listable under its old key.
- [x] Tests (model):
  - A capture appended before `followMove` lands under the old key and is carried; a capture appended after lands under the new key. Stage this with `Gate` on a listing as the causal rendezvous, then await `chain?.value`.
  - `followMove` with an unkeyable side does not extend the chain.
- [x] Run `swift test`; it must pass before Task 4.

### Task 4: Model and browser: delete capture, labelled capture, deleted-path listing, label titles

**Files:**
- Modify: `Sources/PisakaCore/LocalHistoryModel.swift`, `Sources/PisakaCore/LocalHistoryBrowserModel.swift`
- Modify: `Tests/PisakaCoreTests/LocalHistoryModelTests.swift`, `LocalHistoryBrowserModelTests.swift`

- [ ] **`LocalHistoryModel.captureBeforeDelete(of:root:bufferTexts:)`**, synchronous and not `async`:
  - it keys the buffers (buffers win);
  - it walks the item through the file service per the decision above, capped at `maxPreOperationFiles` disk targets;
  - it reads each target with `readTextIfNotBinary(url:maxBytes:)` **before returning**;
  - it appends only the writes under `.delete`, with the clock read at entry;
  - it returns without touching the chain when there is nothing to store.
- [ ] **`LocalHistoryModel.captureLabel(_:root:texts:)`**:
  - it normalises the text through `LocalHistoryPolicy.label(from:)` and does nothing when that refuses;
  - it appends one unit per keyed buffer under `.label`, with the shared label text.
- [ ] Add a pure predicate the menu uses for enablement. It takes the open tabs' **urls** (`[URL]`, never buffer texts) and answers whether any of them is keyable under the root. It answers false with no root.
- [ ] **`LocalHistoryBrowserModel`:**
  - `deletedPaths(root:) async -> [String]`: runs off-main; `recordedPaths` filtered by `isMissing`, sorted by path; `[]` with no root or an unreadable store; computed on demand and never stored.
  - a published `labelTexts`, keyed by snapshot file name and cleared on `open(file:root:)`;
  - `loadLabel(for:)`: an off-main read through `store.labelText`. It does **not** take the generation token, and it publishes only if the browser still targets the same root and relative path. It is a no-op for a non-`.label` row or one already loaded.
  - `title(for:)`: answers `"Label: <text>"` when the text is loaded, and the event's title otherwise.
- [ ] Tests:
  - `captureBeforeDelete` has read every disk target by the time it returns (assert `readPaths`). Then remove the files from the stub and await the chain: the `.delete` snapshots hold the pre-delete text.
  - A buffer beats its disk copy; a folder capture is capped at a small `maxPreOperationFiles`; a binary file is absent; a symlink is neither read nor descended; a single-file url is captured; nothing to capture leaves the chain unchanged.
  - A capture appended after the delete capture lands after it.
  - A label over three buffers (two edited, one untouched) writes three `.label` revisions, each with a sidecar holding the same text, and a second identical call writes three more. Inject a clock with distinct milliseconds.
  - A refused label writes nothing.
  - The enablement predicate, fed urls only, is false for no root and for only untitled (`nil`) or outside-root urls, and true for one project file.
  - `deletedPaths` is sorted, excludes existing files and record-less directories (including one with a wrong record), and is `[]` for no root.
  - `loadLabel` publishes `"Label: …"`, falls back to "Label" for an unreadable sidecar, and is discarded after a retarget to another file (`Gate` rendezvous). A label load does not cancel an in-flight listing.
- [ ] Run `swift test`; it must pass before Task 5.

### Task 5: App wiring: move, delete, restore recreate, the two menu commands, label titles in the window

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift`, `Sources/Pisaka/LocalHistoryView.swift`
- Create: `Sources/Pisaka/LocalHistoryPrompts.swift`
- Modify: `.swiftlint.yml`, `Tests/PisakaCoreTests/LintConfigurationTests.swift`, `Tests/PisakaCoreTests/LocalHistorySourceGatingTests.swift`

- [ ] **`performMove`:** after the move succeeds and the `applyRenamePlan` / viewer retargets have run, call `localHistory.followMove(from: source, to: destination, root: model.projectRoot)`.
- [ ] **`deleteItem`:** after the confirmation and the affected-tab collection, and before `fileService.removeItem`, call `localHistory.captureBeforeDelete(of: url, root: model.projectRoot, bufferTexts:)` with the affected tabs' buffers (from `openBufferTexts()` restricted to the affected urls). The delete still raises no gate of its own.
- [ ] **`restoreFromLocalHistory`:** after the current-root check, when `localHistory.store.isMissing(root:relativePath:)` is true:
  - consult `revertInFlight()` and stop if it is raised;
  - otherwise `ensureDirectory` the parent and `createFile` through the file service (beep and stop on failure), then call `model.bumpTreeRevision()`;
  - continue with the unchanged restore steps (preflight, open, "Before Restore" capture, `applyRestore`).
- [ ] **File menu:** below "Local History…", add "Deleted Files…" and "Put Label…".
  - Deleted Files is disabled without a project.
  - Put Label's enablement passes the Core predicate the urls of `model.openFiles`' text-kind tabs. It does **not** call `openBufferTexts()`, so menu validation copies no buffer text.
  - Deleted Files: `await localHistoryBrowser.deletedPaths(root:)`, then the prompt, then `showLocalHistory(for: root.appendingPathComponent(choice))`.
  - Put Label: the prompt, then `localHistory.captureLabel(_, root:, texts: openBufferTexts())`. This action is the only place the label feature calls `openBufferTexts()`.
- [ ] **`LocalHistoryPrompts.swift`** (`#if os(macOS)`): the label prompt and the deleted-file chooser per the decisions above. It makes no decisions of its own beyond asking `LocalHistoryPolicy.label(from:)`.
- [ ] **`LocalHistoryView`:** rows show `browser.title(for:)` and call `browser.loadLabel(for:)` when a row appears.
- [ ] **Lint ceilings:** measure `PisakaApp.swift` and raise `file_length` and `type_body_length` by exactly the measured amount, with the reasoning paragraph in `.swiftlint.yml`. Update `LintConfigurationTests`' pinned numbers and `docs/architecture/style-lint.md`'s record of them.
- [ ] **`LocalHistorySourceGatingTests`:**
  - `captureBeforeDelete(` is named exactly once in `PisakaApp`, inside `deleteItem`, at an offset before that body's `removeItem(`, and is not awaited;
  - `followMove(` is named exactly once, inside `performMove`, after its `fileService.move(`;
  - the delete-site count is pinned cross-file against the number stated in `core-local-history.md`'s Tests entry (stated there in Task 6; add the sentence now so this task's tests pass);
  - the existing rule that no `LocalHistory*` file names `autosave.suspend` / `beginRevert` is kept and extended to `revertInFlight`, and it covers the new prompts file by name;
  - the macOS-gating rule covers the new file;
  - the restore's existing counts (`policy.capture(` asked exactly twice, one open) still hold.
- [ ] Run `swift test`, `xcodegen generate`, the app-layer bundle (`xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build test`) and `swiftlint --strict`. All must pass before Task 6.

### Task 6: Documentation

**Files:**
- Modify: `docs/architecture/core-local-history.md`, `CLAUDE.md`, `docs/FEATURES.md`, `README.md`

- [ ] **`core-local-history.md`:**
  - The store diagram and bullets gain the `path` record and the label sidecar. For the record, state: the codec; "the inverse of the hash and nothing more"; that capture writes it only when the listing shows no `path` entry and never reads it, so a dedup'd capture stays one directory read and no content read; and that verification is on the read side only, a reader treating a wrong record as record-less.
  - State that a present-but-wrong record is corrected only by migration's own rewrite, and why that is acceptable.
  - Replace the "cannot be read backwards" cost with the record's story.
  - The snapshot entry gains `.delete` and `.label`.
  - Update the layout, policy, store and model entries:
    - policy: the label rule, the `event` input and the `.label` dedup exemption;
    - store: the record write, labelled capture, the sweep rule, `recordedPaths` / `isMissing` / `labelText`, and `migrate` with the merge rule;
    - model: `followMove` and its ordering argument (enqueued after the disk move and the tab retarget, serial with every capture, no gate), `captureBeforeDelete` and why its reads are synchronous, `captureLabel`, and the url-only enablement predicate.
  - The browser entry gains `deletedPaths`, `labelTexts`, `loadLabel` and `title(for:)`.
  - The app entries gain `LocalHistoryPrompts.swift`, the two menu commands, the delete capture site and the recreate exception: "a restore is a buffer edit, except that a restore into a path with no file first creates an empty file, under `revertInFlight()`".
  - The Tests section lists the new coverage and gives the updated suite count and the cross-file-pinned delete-site count.
  - Known limits:
    - drop the three closed ones (rename leaves history behind; a deleted file cannot be restored from its own snapshot; the store cannot be read backwards);
    - add to the ⌘Z limit that a recreated file's restore has no undo step back to empty;
    - add that a directory never captured since the upgrade, or holding a wrong record, is record-less: it neither follows a move nor appears under Deleted Files.
- [ ] **`CLAUDE.md`:**
  - In the Local History invariant bullet, add one sentence naming the project tree's delete as a capture site (synchronous reads, background writes, no gate) and one sentence stating the one worktree create (a restore into a missing path creates an empty file under `revertInFlight()`).
  - Add `LocalHistoryPrompts.swift` to the `core-local-history.md` app index line.
  - Nothing else grows; the file stays under 60,000 characters.
- [ ] **`docs/FEATURES.md` and `README.md`:** a user-facing description of history following a rename or move, Before Delete, Deleted Files…, Put Label…, and recreate-on-restore.
- [ ] Run `swift test` (the `LintConfigurationTests` size rule and the cross-file pin); it must pass before Task 7.

### Task 7: Verify acceptance criteria

- [ ] Run `swift test`: full Core suite green.
- [ ] Run `xcodegen generate` and the app-layer bundle with `-destination 'platform=macOS'` and `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build`: green.
- [ ] Run the iOS build (`-destination 'generic/platform=iOS'`, same derived data path) to confirm nothing new compiles there beyond Core.
- [ ] Run `swiftlint --strict` from the repository root: clean.
- [ ] Confirm every new Core rule listed in requirement 5 has a test: record write and codec, empty-directory sweep, file/folder migration including merge, delete capture ordering, label non-dedup, deleted-path listing.

## Post-Completion

Manual checks in a **Debug** build only. A Release build auto-updates through the updater and replaces the bundle.

- AC1–AC3: save, rename in the tree and open ⌘⇧H to see the old revisions. Drag a folder of saved files and see each history follow. Rename onto a previously deleted path and see the merged list.
- AC4–AC6: delete a modified open file, then choose File ▸ Deleted Files…; the "Before Delete" revision holds the buffer's text. Restore recreates the file and opens a tab (no ⌘Z back to empty, by decision). Delete a folder and confirm the delete is immediate. A Restore while a gated operation is running beeps and creates nothing.
- AC7–AC8: Put Label with two edited buffers and one clean one gives three "Label: <text>" rows, which survive a relaunch; repeating it gives three more. The command is disabled with no project, or with only an untitled tab.
- AC9–AC10: with a store from the previous version, files not captured again since the upgrade don't follow a rename and aren't listed; their first capture writes the record. Deleting `~/Library/Application Support/Pisaka/LocalHistory` breaks nothing.
