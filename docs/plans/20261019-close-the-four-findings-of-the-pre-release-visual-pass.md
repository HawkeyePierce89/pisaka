# Close the four findings of the pre-release visual pass

## Overview

This plan fixes the four defects the pre-release visual pass found, and nothing else:

- R1 (regression): when the displayed tab's buffer is replaced in place, the caret and the scroll anchor are now kept.
- R2: the Local Changes inline diff now follows the selected file's content.
- R3: Esc dismisses the one-button "Unsaved changes are not included" alert, and the key never reaches the commit dialog underneath.
- R4: the commit dialog's unified diff starts at the top of its pane.

### Decisions this plan takes, with the reasons

**R1 remaps the live selection and does not go through the viewport memory.** The only buffer assignment, `textView.string = text` in `CodeEditorView.updateNSView`, is reached by every path the ticket lists: the watcher and activation silent reloads, Reload from the bar, Replace All, a post-operation `reloadFromDisk`, a merge apply and a Local History restore. So one fix at that site covers all of them.

- When `contentReplaced && !switchedFile`, the coordinator takes the live viewport with `captureViewport()` before the swap.
- After the swap it re-applies that viewport, clamped by `EditorViewport.clamped(toLength:)`. This is the same arithmetic the tab-switch restore uses.
- The memory store is not used, for two reasons. First, that same branch already calls `forgetViewport(for:)` on `externallyReplaced`, which also fires for the displayed tab, so recording into the store means reordering a forget the off-screen rule depends on. Second, the store's entry describes where a tab was left, not where it is now. A local value captured before the swap and applied after it touches neither rule.
- An explicit reveal still wins. The re-apply is skipped when `hasPendingReveal(reveal.request, fileID:)` is true, as the switch restore is skipped today.
- The off-screen case is unchanged: `switchedFile` with `externallyReplaced` still forgets the viewport and starts at the top.

**R2 has one confirmed cause and one structural gap. Both are fixed where they sit.**

1. Confirmed by reading the code: the `ProjectWatcher` callback in `PisakaApp.openFolder` (`projectWatcher.start(root:onChange:)`) bumps the tree, the symbol index, the `.editorconfig` cache and the disk-sync pass. It never calls `refreshLocalChanges()`, whose own doc comment still says "without filesystem watching". So an external edit never refreshes the list, `listRevision` never advances, and the inline diff never reloads.
2. The step from a refresh to the inline diff lives only in the view: `LocalChangesView`'s `.onChange(of: model.listRevision)`. The Core suite proves the fingerprint rule only by calling `loadSelectionDiff` by hand (`testAnEditToTheSelectedFileRefreshesItsDiff`). That means no gate covers the claim that a refresh with an equal list rebuilds the diff, and the autosave case depends entirely on SwiftUI delivering that `onChange`.
   - Fix: the model starts its own selection-diff load at the end of every successful refresh publish. It claims the token synchronously right after `listRevision += 1`, then awaits `loadSelectionDiff(token:)` before `refresh` returns.
   - The view keeps `onChange(of: selected)` and drops its `listRevision` trigger. `listRevision` itself stays, because the gutter and blame still read it.
   - The Core test in the ticket (selected modified file, a second refresh with an equal list, a moved stamp, no manual load, published diff rebuilt) fails on the current code and passes after.
   - The fingerprint rule itself, `needsRebuild`, is already correct and covered, so it does not change.
   - The watcher-driven refresh is a reader, so it takes no gate. `git status` runs with `--no-optional-locks`, so it writes nothing and cannot start an event loop. The refresh keeps generation pinning through `refreshLocalChanges()`.

**R3 gives the one-button message alert an Esc answer in one place, `PlatformAlert.presentMessage` (macOS).**

- For the duration of `runModal()`, a local key-down monitor is installed.
- An unmodified Esc stops the modal session with the first button's code and consumes the event. Consuming it is what keeps it away from the commit dialog's sheet.
- Return still works as the default button.
- Both siblings go through this function, so the refused folder switch behaves the same way, as does every other one-button message.
- The ordering (dialog raised, then the alert) is untouched, and so is the re-entry reasoning in `openCommitDialog`.
- The key test is factored out as `PlatformAlert.answersAsDismiss(_ event: NSEvent) -> Bool`, so an app-layer test can pin it with synthesized events.

**R4 uses `.defaultScrollAnchor(.topLeading)` (macOS 14+) on the diff's two-axis `ScrollView`.** That ScrollView centres content shorter than its viewport. The placeholder branch is a separate view and keeps its centred layout. If the measurement shows the anchor alone does not pin short content to the top, the fallback is a measured minimum height on the content with `.topLeading` alignment, through the same probe that already reports the visible width.

## Context

- Files involved:
  - R1: `Sources/Pisaka/CodeEditorView.swift` (`updateNSView` buffer swap, `captureViewport`, `restoreViewport`, `scrollAnchor`, `hasPendingReveal`), `Sources/PisakaCore/EditorViewport.swift`, `Sources/PisakaCore/WorkspaceModel.swift` (`reloadFromDisk`, read only)
  - R2: `Sources/PisakaCore/LocalChangesModel.swift` (`refreshImpl`, `loadSelectionDiff`), `Sources/Pisaka/LocalChangesView.swift`, `Sources/Pisaka/PisakaApp.swift` (watcher callback, `refreshLocalChanges` doc comment)
  - R3: `Sources/Pisaka/Platform/PlatformAlert.swift`, `Sources/Pisaka/PisakaApp.swift` (`reportUnsavedBeforeCommit`, `reportUnsavedBeforeFolderSwitch`, read only)
  - R4: `Sources/Pisaka/CommitUnifiedDiffView.swift`
  - Tests: `Tests/PisakaCoreTests/EditorViewportTests.swift` (or the existing viewport suite), `Tests/PisakaCoreTests/LocalChangesModelTests.swift`, new `Tests/PisakaAppTests/InPlaceReplacementViewportTests.swift`, new `Tests/PisakaAppTests/MessageAlertKeyTests.swift`, `Tests/PisakaAppTests/CommitUnifiedDiffWashTests.swift` (or a sibling layout suite using `HostedRender`)
  - Docs: `docs/architecture/app-editor.md`, `docs/architecture/core-git-models.md`, `docs/architecture/app-git-views.md`, `docs/architecture/app-shell.md`, `docs/architecture/app-ios.md` (PlatformAlert entry), `docs/FEATURES.md`
- Related patterns:
  - The tab-switch restore (`restoreViewport`, clamped by `EditorViewport.clamped`).
  - Generation tokens claimed synchronously before a `Task` hop.
  - The existing `loadedModifiedFile()`, `StubGit` and `StubFiles` stamp fixtures in `LocalChangesModelTests`.
  - `HostedRender` for measuring drawn layout.
  - The `expectation(for: NSPredicate…)` causal waits used in `DiskSyncControllerTests`.
- Dependencies: none new.

## Development Approach

- **Testing approach**: TDD for R1's app-layer test and R2's Core test. Both must be seen to fail on the current code before the fix lands. Regular approach for R3 and R4.
- Complete each task fully before moving to the next.
- Pure engine + thin glue: any arithmetic lives in Core. The app-layer wiring is pinned by app-layer tests, because `swift test` cannot see a text view, a modal alert or a SwiftUI layout.
- Async tests stage races with a causal rendezvous (a predicate on the state that must arrive), never with timed delays.
- SwiftLint `--strict` with the committed configuration. A length ceiling is raised only with a reason in the config. `CodeEditorView.swift` is near its ceiling, so prefer a small coordinator helper over growing `updateNSView`.
- App-layer gates run under the pinned Xcode (`DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer`).
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: R1 — keep the caret and scroll anchor across an in-place replacement of the displayed tab

**Files:**
- Modify: `Sources/Pisaka/CodeEditorView.swift`
- Modify: `Sources/PisakaCore/EditorViewport.swift` (doc comment only: name the second consumer of `clamped(toLength:)`)
- Modify: `Tests/PisakaCoreTests/EditorViewportTests.swift` (or the suite that already tests `EditorViewport`)

- [x] In `updateNSView`, before the highlighter detach and the `textView.string = text` swap, capture `let preserved = (contentReplaced && !switchedFile) ? context.coordinator.captureViewport() : nil`.
- [x] Add a coordinator method `restorePreservedViewport(_:)`. It clamps through `EditorViewport.clamped(toLength:)`, then calls `setSelectedRange` and `scrollAnchor(to:)`. It also clears the fold-selection direction, as `restoreViewport` does. (Landed merged with the switch restore's dispatch as `restoreViewportAfterUpdate(fileID:switchedFile:preserved:reveal:)`, so `updateNSView` stays under its body and file length ceilings.)
- [x] Call that method at the same point as the switch restore: `else if let preserved, !hasPendingReveal(reveal.request, fileID:)`. This keeps the order after the minimap, bracket, search, blame and fold reconciliation, and before `applyReveal`.
- [x] Extend the caret report so `reportCaretPosition(of:)` also runs when `contentReplaced`, so the status bar line cannot keep the swap's end-of-file value.
- [x] Leave the off-screen branch (`externallyReplaced` → `forgetViewport`) unchanged. Update the comments on the swap block and on the restore block to name the in-place rule and why it uses a live capture rather than the memory.
- [x] Core tests for the arithmetic the in-place rule relies on:
  - a caret inside an unchanged prefix stays exactly where it was;
  - a caret past a shrunken new end lands at the end;
  - a selection crossing the new end is truncated;
  - an anchor past the new end resolves to the last character;
  - an empty new buffer gives `{0,0}` and anchor 0.
- [x] Run `swift test`. It must pass before Task 2.

### Task 2: R1 — app-layer test of a displayed-tab reload

**Files:**
- Create: `Tests/PisakaAppTests/InPlaceReplacementViewportTests.swift`

- [x] Build the fixture:
  - a 240-line file written to a temp directory and opened through a real `WorkspaceModel(fileService: FileService())`;
  - a `CodeEditorView` bound to that buffer's text, hosted in an `NSHostingView` inside an offscreen `NSWindow` through a small `@ObservedObject` host view;
  - the editor's `NSTextView` found in the hosting hierarchy.
- [x] Case 1:
  - set the selection to line 3 and the top of the view to line 1, then change line 200 on disk;
  - call `model.reloadFromDisk(id:)`;
  - rendezvous on the predicate `textView.string == newText` with an `XCTNSPredicateExpectation`, not a delay;
  - assert the selection is unchanged and `captureViewport()?.topCharacterOffset` is unchanged.
- [x] Case 2: put the caret past the new end, rewrite the file shorter on disk and reload. After the same rendezvous, assert the selection is `{newLength, 0}` and no exception was raised. (Landed behind a selection crossing the new end, truncated to it, because a bare caret alone also lands at the end without the fix; case 1 scrolls to line 40 rather than line 1 so the anchor assertion can fail.)
- [x] Confirm both cases fail with the Task 1 change stashed and pass with it applied. Record the result in the test's doc comment.
- [x] Run the app-layer bundle. The only failures allowed are the eight known scale-1.8 ones.

### Task 3: R2 — the model rebuilds the inline diff after every refresh publish (Core)

**Files:**
- Modify: `Sources/PisakaCore/LocalChangesModel.swift`
- Modify: `Sources/Pisaka/LocalChangesView.swift`
- Modify: `Tests/PisakaCoreTests/LocalChangesModelTests.swift`

- [x] Write the failing test first:
  - load a selected modified file;
  - change its working contents and move its stamp, keeping the git list equal;
  - `await model.refresh(root:)` with no manual `loadSelectionDiff`;
  - assert `selectionDiff` holds the new rows and the new stamp.

  Confirm it fails on the current code.
- [x] In `refreshImpl`'s success path, right after `listRevision += 1`, claim `beginSelectionDiffLoad()` synchronously and `await loadSelectionDiff(token:)`. The existing token checks keep a newer selection's load authoritative.
- [x] Remove `LocalChangesView`'s `.onChange(of: model.listRevision)` trigger and keep the `selected` trigger and `onAppear`. Update the comment there and the `listRevision` doc comment: its readers are now the gutter and blame tokens, not the inline diff.
- [x] Add tests for the edge cases:
  - an equal list with an unchanged stamp does no read (the existing no-work property, now through `refresh` alone);
  - a refresh superseded by a newer selection does not publish over it;
  - a failed refresh does not touch the published diff;
  - a refresh with nothing selected publishes `nil`.
- [x] Adjust any existing test that relied on `refresh` doing no inline-diff work. (Two: `testAnUnknownStampAlwaysRebuilds` now counts the refresh's own read, and `testARefreshResolvingANewRootDropsThePublishedDiff` asserts the old repository's diff is replaced by one computed against the new root, since the refresh now reloads it.)
- [x] Run `swift test`. It must pass before Task 4.

### Task 4: R2 — external edits refresh Local Changes through the watcher

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: an app-layer suite if a seam exists; otherwise a Core gating suite pins the call site (see below)

- [x] Add `refreshLocalChanges()` to the `projectWatcher.start(root:onChange:)` callback. It uses the existing generation-pinned helper and takes no gate, because it is a reader.
- [x] Correct `refreshLocalChanges()`'s doc comment, which currently says "without filesystem watching". Add a comment on the watcher callback explaining why no loop arises (`--no-optional-locks` reads write nothing to `.git`) and why the refresh is ungated.
- [x] Pin the wiring statically with comment- and literal-stripped matching. Prefer extending the existing gating suite that reads `PisakaApp.swift` (for example `GitCLIArgumentSourceGatingTests`, or a new rule in the most fitting `*SourceGatingTests`). Assert that the watcher's callback body calls `refreshLocalChanges()`, and update that suite's doc-comment inventory. (Landed in `GitCLIArgumentSourceGatingTests`, whose `--no-optional-locks` rule is what keeps the refresh from feeding the watcher; seen to fail with the call removed.)
- [x] Run `swift test` and the macOS build. Both must pass before Task 5.

### Task 5: R3 — Esc answers the one-button message alert and never reaches the dialog beneath

**Files:**
- Modify: `Sources/Pisaka/Platform/PlatformAlert.swift`
- Create: `Tests/PisakaAppTests/MessageAlertKeyTests.swift`

- [x] Add `static func answersAsDismiss(_ event: NSEvent) -> Bool` (macOS): a key-down event that is Esc (key code 53, or `cancelOperation` characters) with no command, option or control modifiers.
- [x] In `presentMessage` on macOS:
  - install `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` before `runModal()`;
  - when the monitor sees a matching event, call `NSApp.stopModal(withCode: .alertFirstButtonReturn)` and consume the event by returning `nil`;
  - remove the monitor in a `defer`.

  The OK button keeps Return. The iOS branch is unchanged.
- [x] Leave the order in `openCommitDialog` unchanged: the dialog is raised, then the alert is reported. Note in `reportUnsavedBeforeCommit`'s and `reportUnsavedBeforeFolderSwitch`'s doc comments that both share the rule.
- [x] App-layer tests with synthesized `NSEvent.keyEvent`s:
  - Esc answers;
  - ⌘-Esc, Return and a letter do not;
  - a key-up does not.
- [x] Run the app-layer bundle and the macOS build. (478 tests, only the eight known scale-1.8 failures; Release build succeeds.)

### Task 6: R4 — top-align the commit dialog's unified diff

**Files:**
- Modify: `Sources/Pisaka/CommitUnifiedDiffView.swift`
- Modify: `Tests/PisakaAppTests/CommitUnifiedDiffWashTests.swift` (or a new `CommitUnifiedDiffLayoutTests.swift` using `HostedRender`)

- [ ] Apply `.defaultScrollAnchor(.topLeading)` to the diff's `ScrollView([.vertical, .horizontal])`. Leave the rows, the width probe, the `minWidth` frame and the placeholder untouched.
- [ ] If the measurement below still shows the content centred, use the fallback instead:
  - extend the probe to report the clip height;
  - add `minHeight` with `.topLeading` alignment to the content frame;
  - say why in the view's doc comment.
- [ ] Test with `HostedRender`: one `.added` row in a tall pane. Measure the wash's first painted row off the bitmap and assert it begins within the 2-pt vertical padding of the pane's top edge. Assert that a pane with a placeholder still draws its glyph centred vertically.
- [ ] Confirm the new top-alignment assertion fails before the change.
- [ ] Run the app-layer bundle.

### Task 7: Verify acceptance criteria

- [ ] Run `swift test`.
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`. The only failures allowed are the eight known scale-1.8 ones.
- [ ] Run `swiftlint --strict` from the repository root with the committed configuration.
- [ ] Run the macOS build under the pinned Xcode (Release configuration, as CI builds it).
- [ ] Confirm the tests written as failing-first (Task 2, Task 3 and Task 6) fail with their fixes reverted and pass with them applied.

### Task 8: Update documentation

- [ ] `docs/architecture/app-editor.md`, viewport memory entry: the in-place replacement rule (live capture before the swap, clamped re-apply after, the reveal outranks it, the off-screen case unchanged) and why it does not go through the memory store.
- [ ] `docs/architecture/core-git-models.md`, `LocalChangesModel` entry: a refresh now drives the inline-diff load itself, `listRevision`'s remaining readers, and the watcher as a refresh trigger.
- [ ] `docs/architecture/app-git-views.md`: the Local Changes view's triggers, and `CommitUnifiedDiffView`'s top alignment and how it is pinned.
- [ ] `docs/architecture/app-shell.md`: the watcher callback's new member, and that both one-button alerts answer Esc. `docs/architecture/app-ios.md`'s PlatformAlert entry: the macOS Esc monitor.
- [ ] `docs/FEATURES.md`: a reload of the shown tab (external change, Reload, Replace All, merge apply, Local History restore) keeps the caret and scroll position; the Local Changes inline diff follows edits; Esc closes the commit-time notice.
- [ ] `CLAUDE.md`: change it only if a claim there changes. None is expected; if one is edited, keep it under the measured size.

## Post-Completion

- Manual check in a Debug build:
  - Acceptance criterion 1, three ways: the watcher pass, Reload from the bar, and the activation pass, on a 240-line file with the caret on line 3. Then the past-the-end case.
  - Criterion 2: an external edit and an autosave of the selected file.
  - Criterion 3: commit with a conflicted tab, press Esc. Confirm the dialog stays and stays usable, and that the local monitor fires inside `runModal`.
  - Criterion 4: a one-line diff.
