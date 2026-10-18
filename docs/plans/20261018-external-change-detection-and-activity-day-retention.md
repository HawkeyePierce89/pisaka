# External change detection for open tabs, and Local History retention in activity days

## Overview

Two safety-net fixes that stop the editor from losing work without telling anyone.

Part A, external changes. Every titled text tab records a FileStamp of its file whenever its baseline (`savedText`) is set. A pure Core rule decides whether the disk really differs from that baseline. A stamp mismatch alone is not enough; the content must differ too. The rule runs at three points:

- before every write (the hard guarantee),
- on the folder watcher's coalesced event,
- on app activation.

A clean tab reloads silently. An edited tab in conflict is never written by autosave or by the quit flush. It gets a marker on the tab and a bar in the editor with Reload, Overwrite and Compare. ⌘S, the close prompt's Save, the Run/Test pre-saves and ⌘Q each ask Overwrite / Reload / Cancel. Whichever side loses is captured into Local History first, under one of two new events.

Part B, retention. Local History retention counts 14 activity days per project instead of 14 calendar days. The activity days come from a small per-project record in the project's area of the store. If that record is missing, the rule falls back to today's calendar rule.

## Context

- Core files involved:
  - `Sources/PisakaCore/OpenFile.swift`
  - `Sources/PisakaCore/WorkspaceModel.swift`
  - `Sources/PisakaCore/FileService.swift` (FileStamp, already there)
  - new `Sources/PisakaCore/ExternalChangeRule.swift`
  - `Sources/PisakaCore/LocalHistorySnapshot.swift` (LocalHistoryEvent)
  - `Sources/PisakaCore/LocalHistoryPolicy.swift`
  - `Sources/PisakaCore/LocalHistoryLayout.swift`
  - `Sources/PisakaCore/LocalHistoryStore.swift`
  - `Sources/PisakaCore/LocalHistoryModel.swift`
  - `Sources/PisakaCore/DiffWindowTitle.swift`
- App files involved:
  - `Sources/Pisaka/AutosaveController.swift`
  - `Sources/Pisaka/PisakaApp.swift`: save(id:), the close prompt, runFile/testFile, openCommitDialog, the watcher wiring, the quit wiring
  - `Sources/Pisaka/AppDelegate.swift`
  - `Sources/Pisaka/ContentView.swift`
  - `Sources/Pisaka/TabStripView.swift`
  - `Sources/Pisaka/TabRowView.swift`
  - `Sources/Pisaka/LocalHistoryView.swift`
  - `Sources/Pisaka/iOS/RootView_iOS.swift` (the save(for:) call site)
  - new `Sources/Pisaka/DiskSyncController.swift`
  - new `Sources/Pisaka/ExternalChangeBar.swift`
- Tests involved:
  - `Tests/PisakaCoreTests`: WorkspaceModel, LocalHistory*, the new ExternalChangeRuleTests, LocalHistorySourceGatingTests, ChromeThemeSourceGatingTests, ZoomSourceGatingTests, MenuShortcutUniquenessTests
  - `Tests/PisakaCoreTests/Support/StubFileTree.swift`, which already serves stamps through stampOverrides and size-derived stamps
- Patterns to follow:
  - the closed set of sites that assign savedText, every one of which bumps diskRevision
  - reloadFromDisk's two tokens, each judged on its own
  - the order in save(id:): writer-gate refusal first, then the transform
  - AutosaveController's suspend and replay gates
  - LocalHistoryModel.captureBuffers(event:…)
  - DiffWindowController.open(title:content:) with a load closure over LineDiff rows
  - LSPConsentBanner as the precedent for an in-editor bar
  - chrome roles through ChromePalette, interface metrics through the environment
- Dependencies: none new.

## Decisions taken in this plan

- **The disk check pass runs synchronously on the main actor.** It costs one stat per open titled tab, plus a content read only when a stamp differs. That is the same cost profile as open() and reloadFromDisk, which already run on main. Nothing hops off the main actor, so no generation token is needed. The architecture doc states this, so a later async version knows it owes one.
- **The pass publishes nothing when nothing changed.** OpenFile is Equatable, openFiles is @Published, and AutosaveController's idle trigger is a debounce on $openFiles. A pass that assigned unconditionally would republish $openFiles on every coalesced watcher event. During a long burst (a package install reports every second) that would keep re-arming the two-second idle debounce and hold off autosave of unrelated dirty tabs for the whole burst. So:
  - every stamp refresh compares the new stamp with the stored one and assigns only when they differ;
  - the conflict map assigns only when an entry is actually added, changed or removed (recording the same disk text again assigns nothing).
  - A test pins this: a pass over unchanged files publishes nothing on $openFiles or on the conflict map.
- **The conflict state is derived, not sticky.** WorkspaceModel keeps a per-tab "disk text last observed to differ" entry, and only the rule fills it. A tab is in conflict when that entry exists and the buffer differs from the entry's text. Dirtiness is not part of the test. The entry is cleared at every baseline site (open, save, saveAllDirty, saveAs, markSaved, reloadFromDisk, reconcileSavedBaseline) and on close. Recording a conflict does not refresh the tab's stamp, because the baseline has not moved, so the next trigger reads the disk again. Two cases follow from the rule:
  - The buffer is edited by hand to exactly the disk text: the conflict ends on its own.
  - The buffer is edited back to `savedText` (clean again, but stale against the disk): the tab stays in conflict on purpose, because the entry exists and the buffer differs from the disk text. The bar stays up. Autosave writes nothing, since the tab is not dirty. On the next checkDisk trigger (watcher, activation, or any save attempt) the stamp still differs, the rule sees a clean tab whose content differs, and the tab is reloaded as a clean tab, which clears the entry. This is the intended behaviour, and a test pins it.
- **How each disk state is handled:**
  - Missing file: not a change. Today's recreate-on-save is untouched.
  - Unreadable or non-text file: a conflict for a dirty tab (Compare shows the disk side as empty); "leave alone" for a clean one.
  - Buffer already equals the new disk content: the new baseline is adopted silently through reloadFromDisk's existing "baseline only" branch. This is not a conflict.
- **Core API shape:**
  - save(for:) gains an onExternalChange policy and, by default, refuses with a typed error. macOS passes the user's answer. iOS passes .overwrite explicitly, so it writes exactly as today with no new UI.
  - saveAllDirty() returns a batch result: the URLs it wrote and the ids of the conflicted tabs it skipped. Its callers move to `.saved`, and the skips are reported.
- **Retention rule:**
  - A revision expires only when today's calendar rule condemns it AND at least 14 activity days later than its own local day are on record. The AND is what guarantees nothing is ever reclaimed earlier than today's rule would reclaim it. A user active every day gets exactly today's behaviour.
  - Without a readable record, the age rule is today's calendar rule.
  - The count cap and the newest-survives reinstatement keep their order.
- **Activity record:**
  - One small text file named `activity` in the project area, holding up to the 14 most recent yyyy-MM-dd days, one per line.
  - Written on the capture chain at most once per day; read once per project prune.
  - Removed together with the area when it is the only thing left there.
  - The calendar and time zone are injected.
- **New events:**
  - `.overwrite`, titled "Disk Version Before Overwrite", captures the disk text.
  - `.discard`, titled "Edits Discarded by Reload", captures the buffer.
  - Both tags are lowercase with no dash.

## Development Approach

- Testing approach: Regular (code first, then tests), per task.
- Pure engine plus thin glue: every decision lives in PisakaCore with unit tests. The app layer only wires the bar, the marker, the prompts and the two passes.
- Async tests stage races with Gate/waitFor, never with delays.
- Readers take no writer gate. A write the rule refuses writes nothing and transforms nothing.
- SwiftLint strict with the committed configuration. Length ceilings are raised only with a reason written in the config.
- The plan and the docs name no other editor, IDE or project.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Disk stamp on every titled text tab

**Files:**

- Modify: `Sources/PisakaCore/OpenFile.swift`
- Modify: `Sources/PisakaCore/WorkspaceModel.swift`
- Modify: `Tests/PisakaCoreTests/WorkspaceModelTests.swift` (or the existing WorkspaceModel suites)

- [x] Add `diskStamp: FileStamp?` to OpenFile. It is nil for untitled and viewer tabs; the viewer initializer forces nil.
- [x] Read the stamp through `fileService.fileStamp(at:)`, from the path, at every baseline site: open, save, saveAllDirty, saveAs, markSaved, reloadFromDisk, reconcileSavedBaseline. After a write, read it after the write. Route the stamp and the diskRevision bump through one private helper, so they move together or not at all.
- [x] Add a stamp-only refresh for the identical-content case. It moves neither diskRevision nor textReplacementRevision. It compares the new stamp with the stored one and writes into openFiles only when they differ, so an unchanged stamp republishes nothing.
- [x] Tests:
  - each of the seven sites sets both the stamp and the diskRevision, pinned as one set
  - the stamp after a save is the post-write one
  - untitled and viewer tabs carry none
  - a stamp-only refresh moves neither token
  - a stamp-only refresh with an equal stamp publishes nothing on $openFiles
- [x] Run swift test; it must pass before task 2.

### Task 2: The external-change rule in Core

**Files:**

- Create: `Sources/PisakaCore/ExternalChangeRule.swift`
- Create: `Tests/PisakaCoreTests/ExternalChangeRuleTests.swift`

- [x] Write a pure rule. Its inputs are the recorded stamp, the current stamp (nil when unknown), a lazily evaluated disk read (text / missing / unreadable), savedText and text. It returns one verdict:
  - `unchanged`: stamps equal, no read
  - `stampOnly`: identical content
  - `reload`: clean tab, content differs
  - `adoptBaseline`: the buffer already equals the disk
  - `conflict(diskText?)`
  - `missing`
  - `leaveAlone`: clean tab and unreadable disk
- [x] A nil current stamp (unknown) means "read and compare", not "unchanged".
- [x] Tests for every verdict, plus:
  - an equal stamp never evaluates the read
  - touch, an identical checkout and a same-bytes copy each give stampOnly
  - unreadable is a conflict when dirty and leaveAlone when clean
  - missing never yields a conflict
  - a clean-but-stale buffer (text == savedText != disk) gives reload
- [x] Run swift test; it must pass before task 3.

### Task 3: WorkspaceModel conflict state, the guarded save funnels and the pass

**Files:**

- Modify: `Sources/PisakaCore/WorkspaceModel.swift`
- Modify: `Sources/Pisaka/iOS/RootView_iOS.swift`
- Modify: `Sources/Pisaka/AutosaveController.swift` (adapt to the new return type only)
- Modify: WorkspaceModel test suites

- [x] Add a published per-tab map of observed disk text, plus these entry points:
  - `isInExternalConflict(id)`: the entry exists and the buffer differs from it, whether or not the tab is dirty
  - `externalConflictIDs`
  - `diskText(forConflict:)`, for Compare and the Overwrite capture
- [x] Mutate the map only when it actually changes. Recording the same disk text that is already stored, or clearing an absent entry, assigns nothing.
- [x] Clear an entry at every baseline site, on close, and on saveAs to another path. Recording a conflict leaves the tab's stamp untouched.
- [x] `checkDisk(id:)` applies the rule to one tab:
  - reload goes through reloadFromDisk
  - adoptBaseline goes through reloadFromDisk's baseline-only branch
  - stampOnly refreshes the stamp only, through Task 1's compare-before-assign refresh
  - conflict records the disk text
  - unchanged assigns nothing at all
- [x] `syncAllWithDisk()` runs `checkDisk(id:)` over every titled text tab. It returns the ids it reloaded and the ids now in conflict, so the app can reindex and refresh blame.
- [x] `save(for:onExternalChange:)` takes `.refuse` (the default) or `.overwrite`. Under `.refuse` it runs checkDisk first and throws `SaveError.externalChange` without writing.
- [x] saveAllDirty() runs the check for each dirty titled tab and skips the conflicted ones, which stay dirty. It returns `SaveBatchResult(saved: [URL], skippedConflicts: [UUID])`.
- [x] Add the two resolutions:
  - `overwriteExternalChange(id)`: a save with `.overwrite`
  - `reloadDiscardingEdits(id)`: reloadFromDisk on a dirty tab
- [x] Update the iOS explicit save to pass `.overwrite`, which keeps today's behaviour. Adapt the AutosaveController call sites to `.saved`.
- [x] Tests:
  - the autosave batch skips and reports a conflict while writing the others
  - a refused save writes nothing and leaves savedText, the stamp and the tokens alone
  - editing the buffer by hand to the disk text ends the conflict
  - a conflicted tab edited back to savedText stays in conflict and is not written by saveAllDirty; the next checkDisk reloads it as a clean tab and clears the entry
  - Save As to another path ends the conflict, and so does close
  - a clean tab reloads with the tokens per reloadFromDisk's contract
  - a missing file is still recreated on save
  - the iOS policy writes over a changed file
  - a syncAllWithDisk pass over unchanged files publishes nothing on $openFiles or on the conflict map (count the sink's emissions), and a second pass over an already recorded conflict publishes nothing either
- [x] Run swift test; it must pass before task 4.

### Task 4: Two new Local History events and the Compare title

**Files:**

- Modify: `Sources/PisakaCore/LocalHistorySnapshot.swift`
- Modify: `Sources/PisakaCore/DiffWindowTitle.swift`
- Modify: `Sources/Pisaka/LocalHistoryView.swift` (only if it switches over events)
- Modify: LocalHistoryLayout/Snapshot tests, DiffWindowTitle tests, `Tests/PisakaCoreTests/LocalHistorySourceGatingTests.swift`

- [x] Add `.overwrite` and `.discard` with their titles and lowercase tags. The name round-trip goes through the existing grammar.
- [x] Add a DiffWindowTitle case for the buffer-vs-disk comparison.
- [x] Tests:
  - tag and title for each new case
  - the snapshot name round-trip
  - the ordinary skip rules apply (size, outside the project, untitled)
  - update LocalHistorySourceGatingTests' event inventory; its capture-site count is finished in Task 7
- [x] Run swift test; it must pass before task 5.

### Task 5: Activity-day retention

**Files:**

- Modify: `Sources/PisakaCore/LocalHistoryPolicy.swift`
- Modify: `Sources/PisakaCore/LocalHistoryLayout.swift`
- Modify: `Sources/PisakaCore/LocalHistoryStore.swift`
- Modify: LocalHistoryPolicy/Store tests

- [x] Change the prune to `prune(_:now:activityDays:calendar:)`. When `activityDays` is nil, the age rule is the calendar rule. Otherwise a revision expires only if the calendar rule expires it AND at least 14 recorded days fall strictly after the revision's own local day. The count cap and the reinstatement order are unchanged.
- [x] In the layout: the `activity` record's name, its format and its parser. The parser is tolerant: anything unparsable gives nil, lines are deduplicated and sorted, and only the newest 14 days are kept.
- [x] In the store:
  - a capture adds today to the project's record when today is not already the newest entry, so the record is read and written at most once per day
  - a capture and a project prune each read the record once per project
  - a capture-time prune never lists other file directories
  - an area holding only the record is removed together with the record
  - a foreign entry still blocks removal
  - the synchronous quit capture keeps its existing main-thread exception, and nothing new writes from the main thread
- [x] Tests:
  - 23:59 and 00:01 count as two days
  - a revision 20 days old with 3 later activity days survives
  - 14 later activity days plus an expired calendar age deletes
  - 14 later activity days alone, inside the calendar window, survives
  - the newest revision survives regardless
  - a missing or garbled record gives exactly the calendar result
  - the record is written once per day
  - another project's activity does not age this one
  - the area-emptying cleanup removes the record
  - the calendar and time zone are injected, so the tests are deterministic
- [x] Run swift test; it must pass before task 6.

### Task 6: App wiring of the guarded writes (autosave, ⌘S, close, Run/Test, commit, quit)

**Files:**

- Modify: `Sources/Pisaka/AutosaveController.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `Sources/Pisaka/AppDelegate.swift`
- Create: `Sources/Pisaka/DiskSyncController.swift`

- [x] Autosave tick and flushNow:
  - offer the on-save transform only the dirty titled ids that are not in conflict after checkDisk
  - write through the batch result
  - report the conflicted skips, but do not count them as a write-failure beep, because the bar is their signal
  - the termination flush skips conflicted tabs and never writes over them
- [x] save(id:): after the writer-gate refusal and before the transform, run checkDisk. On a conflict:
  - show a modal saying the file "changed on disk since it was opened or last saved", with Overwrite / Reload / Cancel and no destructive choice styled as the default
  - Overwrite: capture the disk text under `.overwrite`, then save with `.overwrite`
  - Reload: capture the buffer under `.discard`, then call reloadDiscardingEdits
  - Cancel returns false, which already cancels the close prompt and the Run/Test pre-run save
- [x] openCommitDialog: conflicted tabs stay dirty after the flush, so the existing unsaved-files message names them. Make sure its name list includes them.
- [x] Quit: AppDelegate.applicationShouldTerminate first asks a closure from PisakaApp, which puts the same question for each conflicted dirty tab. Cancel answers `.terminateCancel` before any teardown; otherwise the existing teardown runs.
- [x] DiskSyncController:
  - holds the watcher pass and the activation pass (NSApplication.didBecomeActiveNotification)
  - while `localChanges.isReverting` is up, records that a pass is pending and runs it once when the gate comes down
  - after a pass, gives reloaded tabs the same reindex and blame/gutter refresh the resync uses
  - is called from projectWatcher's onChange; the watcher itself stays directory-level and IgnoreSelf
- [x] Tests:
  - Core tests for any rule extracted here: the ids offered to the transform exclude conflicts, and the termination batch never writes a conflict
  - an app-layer test in Tests/PisakaAppTests for the gate deferral and its replay when the gate comes down, staged with a causal rendezvous
  - an app-layer test that a watcher pass over unchanged files does not re-arm the autosave idle debounce: a dirty unrelated tab still autosaves while passes keep arriving, observed through the save sink rather than a clock
- [x] Run swift test and the app-layer bundle; both must pass before task 7. (swift test: 0 failures. App bundle: every suite this task touches passes; the 8 scale-1.8 layout failures in BottomBarLayout/BottomBarToolTip/ChromePopoverLayout/CommitDialogLayout reproduce identically on the unchanged baseline on this machine, so they are not from this change)

### Task 7: Conflict UI and Local History capture sites

**Files:**

- Create: `Sources/Pisaka/ExternalChangeBar.swift`
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Sources/Pisaka/TabStripView.swift`
- Modify: `Sources/Pisaka/TabRowView.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `Tests/PisakaCoreTests/LocalHistorySourceGatingTests.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `Tests/PisakaCoreTests/ZoomSourceGatingTests.swift`
- Modify: `Tests/PisakaCoreTests/MenuShortcutUniquenessTests.swift` (only if a shortcut is added; none is planned)

- [ ] The bar above the editor, shown for the selected tab while it is in conflict (including the clean-but-stale case from the derived rule):
  - the message plus Reload, Overwrite and Compare, as equally weighted plain buttons
  - colours from chrome roles, sizes from InterfaceMetrics
  - it disappears when the conflict does
- [ ] A conflict marker in the tab strip and in the tab list row, distinct from the dirty dot.
- [ ] The bar's Reload and Overwrite use the same capture-then-act helpers as the modal.
- [ ] Compare opens DiffWindowController with the buffer against `diskText(forConflict:)`, through LineDiff rows (word emphasis included), under the new title.
- [ ] Tests:
  - update LocalHistorySourceGatingTests' capture-site and write-path inventories for the two new capture sites
  - add ExternalChangeBar to ChromeThemeSourceGatingTests' set, and to the zoom set wherever its rules require
  - an app-layer HostedRender test of the bar's layout: three buttons, none styled as the default
- [ ] Run swift test and the app-layer bundle; both must pass before task 8.

### Task 8: Verify acceptance criteria

- [ ] Run swift test.
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`.
- [ ] Run the iOS Simulator build to confirm the save(for:) call site compiles.
- [ ] Run `swiftlint --strict` from the repository root.
- [ ] Confirm every acceptance criterion maps to a test (criteria 1–7) or a gate (criterion 8), and that the new rule and the retention code paths are fully covered.

### Task 9: Update documentation

- [ ] docs/architecture/core-workspace.md:
  - OpenFile's stamp
  - the ExternalChangeRule entry
  - WorkspaceModel's conflict map, with the derived rule and the clean-but-stale case
  - compare-before-assign and why it matters to the autosave debounce
  - the save policy, the batch result and the pass
- [ ] docs/architecture/app-shell.md:
  - the autosave skip
  - the watcher and activation passes, and their gate deferral
  - the save funnel's prompt and the quit prompt
  - the DiskSyncController entry
  - why the pass runs synchronously with no token
- [ ] docs/architecture/app-editor.md (or app-window.md): the ExternalChangeBar entry and the tab marker.
- [ ] docs/architecture/core-local-history.md:
  - the two new events
  - the activity record
  - the activity-day rule, with the calendar AND and its fallback
  - the newest-survives sentence beside it
- [ ] README.md and docs/FEATURES.md: the feature entry and the limitations entry. No unqualified "14 days" survives.
- [ ] CLAUDE.md:
  - index names for ExternalChangeRule.swift, DiskSyncController.swift and ExternalChangeBar.swift
  - the "Open-tab resync" bullet gains the external-change claim
  - the Local History bullet's retention sentence becomes 14 activity days / 30 revisions, newest survives
  - stay under 60,000 characters (LintConfigurationTests)
- [ ] Run swift test again for the doc-pinning suites.

## Post-Completion

- Manual check in a DEBUG build:
  - edit a clean open file in another app; confirm the tab reloads and blame and gutter markers refresh
  - edit a dirty one; confirm the bar appears and nothing is written after idle, tab switch or focus loss
  - exercise Overwrite, Reload and Compare, and check the Local History rows and their order
  - exercise ⌘S, close, Run and ⌘Q, each with Cancel
  - edit a file outside the project root, then bring the app back to the foreground
  - run a long burst of filesystem events (for example a package install in the terminal) with an unrelated dirty tab, and confirm it still autosaves
- Manual: during a revert, checkout or commit, confirm the tabs behave exactly as before.
