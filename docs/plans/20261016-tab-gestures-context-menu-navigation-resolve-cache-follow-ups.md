# Tab gestures, tab context menu and tab navigation; resolve-cache review follow-ups

## Overview

Part A (macOS only; the iOS strip is untouched) makes the open-file tabs behave the way macOS tabs conventionally behave:

- a middle click closes a tab;
- a right click (or ⌃-click) opens a tab menu: Close / Close Others / Close Tabs to the Right / Close All / Close Saved, Copy Path / Copy Relative Path / Reveal in Finder / Reveal in Project Tree, and Local History;
- ⌥-click on the close mark runs Close Others;
- ⌘⇧] / ⌘⇧[ and ⌃Tab / ⌃⇧Tab move between tabs and wrap at both ends; ⌘1…⌘8 select a tab by position and ⌘9 selects the last tab;
- hovering a tab shows its path.

Every decision lives in Core and is tested there:

- which tabs a batch close affects, and where the walk stops;
- which menu items are enabled;
- which tab a key selects;
- the tooltip and relative-path spelling;
- which directories a reveal expands.

The app layer only routes gestures and menu items into the one existing close funnel, the existing Local History entry point and the existing tree selection.

Part B is Markdown only. It records the review findings from the resolve-cache branch:

- a known limit observed with sourcekit-lsp: every list is `isIncomplete: true`, so D40's narrowing and the retained list's resolve cache never engage for Swift;
- the matching user-facing wording in `docs/FEATURES.md`;
- two sentence corrections in the completed resolve-cache plan.

## Context

- Files involved (Part A):
  - Core: `Sources/PisakaCore/WorkspaceModel.swift` (read only: `openFiles`, `selectedID`, `select`, `close(id:force:)`), `Sources/PisakaCore/OpenFile.swift` (read only: `url`, `kind`, `isDirty`), `Sources/PisakaCore/DisplayPath.swift` (extended), `Sources/PisakaCore/CanonicalPath.swift` (read only)
  - Core, new: `Sources/PisakaCore/TabCloseRule.swift`, `Sources/PisakaCore/TabNavigationRule.swift`, `Sources/PisakaCore/TreeRevealRule.swift`
  - App: `Sources/Pisaka/PisakaApp.swift` (`closeFile(id:)` funnel, `closeSelected`, `showLocalHistory(for:)`, `localHistoryTargetURL`, `.commands`), `Sources/Pisaka/AppDelegate.swift`, `Sources/Pisaka/ContentView.swift` (`editorSplit` wiring of `ProjectTreeView` / `TabListView` / `TabStripView`), `Sources/Pisaka/TabStripView.swift` (strip, plus the shared `TabStatusMark` / `TabFileIcon`), `Sources/Pisaka/TabListView.swift`, `Sources/Pisaka/TabRowView.swift`, `Sources/Pisaka/ProjectTreeView.swift` (`DirectoryNodeView`, `FileRowView`, the `ScrollViewReader`)
  - Tests: `Tests/PisakaCoreTests/` (new `TabCloseRuleTests`, `TabNavigationRuleTests`, `TreeRevealRuleTests`; extended `DisplayPathTests`, `MenuShortcutUniquenessTests`), `Tests/PisakaAppTests/` (new `TabMiddleClickTests`, `TabChordPassThroughTests`)
  - Docs: `docs/architecture/core-services.md`, `core-workspace.md`, `app-window.md`, `app-shell.md`, `docs/FEATURES.md`, `README.md`, `CLAUDE.md` (index names only)
- Files involved (Part B): `docs/architecture/core-lsp.md` (D40 paragraph and `## Known limits`), `docs/FEATURES.md` (the narrowing sentence in the completion bullet, around line 501), `docs/plans/completed/20261016-lsp-completion-resolve-cache-for-the-retained-list.md` (the Task 1 in-flight bullet and the Task 2 verification bullet only). `README.md` does not describe narrowing, so per B2 it gets no Part B change.
- Related patterns:
  - The one close funnel `PisakaApp.closeFile(id:)`: Save / Don't Save / Cancel through `FilePanels.confirmClose`, with `autosave.suspendForModal()` around the prompt and `forgetIndexedBuffer` deferred.
  - The editor's middle-button handling in `CodeEditorView.swift` (`otherMouseDown`, `buttonNumber == 2`).
  - The project tree's context menu (`projectTreeContextMenu`, `FileRowView`'s "Local History").
  - The tree's existing one-shot expansion: `.onChange(of: draft)` sets `isExpanded = true` for a create draft's parent.
  - `TreeSelection`, the tree's existing selection, which follows the active tab.
  - The View menu's duplicate "Zoom In" item: two chords for one command are spelled as two items.
  - `DisplayPath.relativeComponents` (the lexical probe first, then the canonical one).
- Dependencies: none new.

## Development Approach

- **Testing approach**: Regular (code first, then tests), Core rules before the app glue that applies them.
- Complete each task fully before moving to the next.
- Every decision is a pure Core function tested in `swift test`. SwiftUI/AppKit glue only maps gestures and menu items onto those answers and onto the one close funnel. No new Core → app protocol seam.
- No new app-layer file. The shared tab-gesture pieces (the middle-click catcher, the context menu, the actions bundle) live in `TabStripView.swift` beside `TabStatusMark` and `TabFileIcon`, which both orientations already share. That keeps the chrome-theme and zoom gating inventories' file sets unchanged. Both suites must still be green over the edited files.
- Async or event-driven tests use the causal rendezvous pattern; no timed waits.
- **CRITICAL: every task MUST include new/updated tests** (Part B is Markdown-only by requirement B4; its check is the `swift test` doc-shape suites plus the greps named in Task 1).
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Part B: known limit, user wording, completed-plan corrections (Markdown only)

**Files:**
- Modify: `docs/architecture/core-lsp.md`
- Modify: `docs/FEATURES.md`
- Modify: `docs/plans/completed/20261016-lsp-completion-resolve-cache-for-the-retained-list.md`

- [x] `core-lsp.md` `## Known limits`: add an entry next to "Local narrowing trusts `isIncomplete`". It says:
  - With the sourcekit-lsp shipped in the Xcode 27.0 toolchain, every completion list observed on 2026-10-16 carried `isIncomplete: true`.
  - The four scenarios were a member access with a typed prefix, a bare dot, a top-level identifier, and a prefix matching a single item.
  - Consequence: D40's narrowing and the retained list's resolve cache do not engage for Swift. Every keystroke costs the ordinary debounced request plus its prefetched resolves, exactly as before D40.
  - This was observed, not inferred from the server's source. Method, in one sentence: a request-counting pipe transport under Core's own `LSPWorkspace`/`LSPSession`, re-runnable when the toolchain changes.
  - The cache's hit path is verified only through `ScriptedLSPTransport` until a complete-list server is run against it.
  - Honouring `isIncomplete` is correct: the server filters on its side and asks to be asked again.
- [x] D40's paragraph: add one clause pointing at that known-limit entry.
- [x] `docs/FEATURES.md`, the completion bullet's sentence "a list the server said was complete is narrowed on the spot": state that this applies only to servers whose answer is complete, and that the Swift server's lists never are, so Swift completion asks again on every keystroke. `README.md` does not state the behaviour, so it is not touched.
- [x] Completed plan, the Task 1 in-flight dedup bullet: rewrite it to say the test waits on the provider's `internal` join count as its causal signal. Give the reason: a wire-only observation (counting `completionItem/resolve` sends) could pass just as well when the second caller was answered from a finished cache entry, so it cannot prove the two callers shared one in-flight resolve. Remove the claim that the provider carries no seam. Nothing else in that file changes.
- [x] Completed plan, the Task 2 verification bullet: stop quoting the stale phrase verbatim. Spell the grep with a bracket class (`grep -rn "non-empty prefix[ ]of it" docs/plans/completed/`), so the pattern still finds the phrase but never matches its own line.
- [x] Verify: `grep -rn "non-empty prefix[ ]of it" docs/plans/completed/` prints nothing, and `grep -n "no test seam" docs/plans/completed/20261016-lsp-completion-resolve-cache-for-the-retained-list.md` prints nothing.
- [x] Confirm `git diff --stat` touches only `.md` files.
- [x] Run `swift test` (it includes `LintConfigurationTests`' doc-shape checks); it must pass before Task 2.

### Task 2: Core: the relative path and the tooltip

**Files:**
- Modify: `Sources/PisakaCore/DisplayPath.swift`
- Modify: `Tests/PisakaCoreTests/DisplayPathTests.swift`

- [x] `DisplayPath.relativePath(fileURL:projectRoot:) -> String?` returns the suffix below the root joined by `/`. It goes through the existing private `relativeComponents(of:under:)`, lexical probe first, so the containment decision and the spelling are the ones the path bar already uses. It answers nil for no url, no root, or a file outside the root.
- [x] `DisplayPath.tooltip(fileURL:projectRoot:) -> String` answers, in order:
  - the relative path;
  - otherwise the standardized absolute path. Absolute means not `~`-abbreviated: the tooltip is the place to see the full path, and A6 says absolute;
  - "Untitled" for no url, the same literal `components` already pins against `OpenFile.displayName`.
- [x] DisplayPath tests: a file three levels deep, a file directly under the root, a file outside the root (absolute, never `~`), no root, an untitled buffer, a root reached through a symlink against a canonical file url, and a root at `/`.
- [x] Run `swift test`; it must pass before Task 3.

### Task 3: Core: the batch-close rule and the tab menu's availability

**Files:**
- Create: `Sources/PisakaCore/TabCloseRule.swift`
- Create: `Tests/PisakaCoreTests/TabCloseRuleTests.swift`

- [x] Add `public enum TabCloseCommand: CaseIterable, Sendable` with the cases `close`, `closeOthers`, `closeToTheRight`, `closeAll`, `closeSaved`.
- [x] Add `TabCloseRule.targets(_ command:, in files: [OpenFile], anchor: UUID) -> [UUID]`, always in tab order:
  - `close` → `[anchor]`
  - `closeOthers` → every tab except the anchor
  - `closeToTheRight` → the tabs after the anchor
  - `closeAll` → every tab
  - `closeSaved` → every tab whose `isDirty` is false, wherever it sits (the anchor included when clean)
  - An anchor that is not open → `[]`
- [x] Add `TabCloseRule.walk(_ targets: [UUID], closing: (UUID) -> Bool) -> [UUID]`. It calls `closing` in order and stops at the first `false`. It returns the ids actually closed. This is the single statement of "a Cancel stops the batch and leaves that tab and every later one open". Close Saved needs no special case: its targets are clean, so the funnel never prompts for them.
- [x] Add `TabCloseRule.MenuAvailability` (a struct of Bools), built from `(files, anchor, projectRoot)`:
  - each close command is enabled iff its `targets` is non-empty;
  - Copy Path and Reveal in Finder iff the anchor has a url;
  - Copy Relative Path and Reveal in Project Tree iff `DisplayPath.relativePath` (Task 2) answers non-nil;
  - Local History iff the anchor is `.text` with a url. This is the same condition `localHistoryTargetURL` applies to the active tab, stated once here for any tab.
- [x] Tests for the targets:
  - every command with the anchor first, in the middle and last; Close Tabs to the Right on the last tab is empty;
  - a lone tab: Close Others and Close Tabs to the Right are empty;
  - every tab dirty: Close Saved is empty;
  - a dirty/clean mix: Close Saved returns exactly the clean ones, in order;
  - an unknown anchor.
- [x] Tests for the walk: it stops at the first refusal and never calls `closing` again; it returns only the closed prefix; it handles an empty list; it closes everything when nothing is refused.
- [x] Tests for the availability: an untitled buffer, a viewer tab (Local History off, path items on), a lone tab, the last tab, and a file outside the project root (relative path and tree items off).
- [x] Run `swift test`; it must pass before Task 4.

### Task 4: Core: the tab-switch rule

**Files:**
- Create: `Sources/PisakaCore/TabNavigationRule.swift`
- Create: `Tests/PisakaCoreTests/TabNavigationRuleTests.swift`

- [x] Add `TabNavigationRule.adjacent(in ids: [UUID], selected: UUID?, forward: Bool) -> UUID?`:
  - it wraps at both ends;
  - nil with fewer than two tabs, because nothing to move to means the command is disabled;
  - when `selected` is nil or not in the list, forward answers the first tab and backward the last.
- [x] Add `TabNavigationRule.positional(_ number: Int, in ids: [UUID]) -> UUID?`:
  - 1…8 answer the nth tab, or nil past the count;
  - 9 answers the last tab;
  - anything outside 1…9 answers nil;
  - no tabs answers nil.
- [x] Tests:
  - wrap forward from the last tab and backward from the first;
  - a single tab and no tabs;
  - ⌘9 as the last tab with 3 tabs and with 12 tabs;
  - ⌘5 with 3 tabs answers nil;
  - ⌘1 with one tab;
  - an unknown selection.
- [x] Run `swift test`; it must pass before Task 5.

### Task 5: Core: the reveal ancestors

**Files:**
- Create: `Sources/PisakaCore/TreeRevealRule.swift`
- Create: `Tests/PisakaCoreTests/TreeRevealRuleTests.swift`

- [x] `TreeRevealRule.ancestors(of fileURL: URL, root: URL) -> [URL]?` answers the directories from the root down to the file's parent, inclusive of the root. Each is spelled as the tree spells its rows: the opened root with components appended. It uses the same two-probe containment through `CanonicalPath`. It answers nil outside the root or for the root itself.
- [x] TreeRevealRule tests: three levels deep answers `[root, a, a/b, a/b/c]` in that order; a file at the root level answers `[root]`; outside the root answers nil; a symlinked root answers the root's own spelling; a `/private` firmlink difference.
- [x] Run `swift test`; it must pass before Task 6.

### Task 6: App: the close funnel reports its outcome; middle click, ⌥-click, tooltip and context menu in both orientations

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Sources/Pisaka/TabStripView.swift`
- Modify: `Sources/Pisaka/TabListView.swift`
- Modify: `Sources/Pisaka/TabRowView.swift`
- Create: `Tests/PisakaAppTests/TabMiddleClickTests.swift`

- [ ] Make `closeFile(id:)` `@discardableResult -> Bool` ("the tab is gone"):
  - true for `.closed`, for Save followed by a successful close, and for Don't Save;
  - false for Cancel and for a failed or cancelled save.

  The body and its autosave and `forgetIndexedBuffer` brackets stay as they are. ⌘W and the close mark keep calling it unchanged.
- [ ] Add `closeTabs(_ command: TabCloseCommand, anchor: UUID)` in `PisakaApp`. It does nothing but `TabCloseRule.walk(TabCloseRule.targets(...)) { closeFile(id: $0) }`.
- [ ] Add a `TabActions` value in `TabStripView.swift`: closures for close-batch, copy path, copy relative path, Reveal in Finder, Reveal in Project Tree and Local History, plus what is needed to build `TabCloseRule.MenuAvailability` (the project root). It replaces the bare `onClose` parameter that `TabStripView` / `TabListView` take today. `ContentView` gains one parameter and passes it through. `PisakaApp` builds it:
  - copy path: `NSPasteboard.general`, with `url.path`;
  - copy relative path: `NSPasteboard.general`, with `DisplayPath.relativePath`;
  - Reveal in Finder: `NSWorkspace.shared.activateFileViewerSelecting`;
  - Local History: `showLocalHistory(for:)`;
  - Reveal in Project Tree: Task 7.
- [ ] Add one shared `tabContextMenu(file:files:actions:)` modifier in `TabStripView.swift` and apply it to both `TabStripCell` and `TabRowView`:
  - three sections separated by `Divider()`, in the order A2 lists;
  - every item `.disabled` from `MenuAvailability`, never hidden;
  - every action takes the tab the menu was opened on.

  SwiftUI's `.contextMenu` answers both right click and ⌃-click.
- [ ] Middle click: add a `TabMiddleClickCatcher` (an `NSViewRepresentable`, in `TabStripView.swift`) laid over each cell and row.
  - The catcher's view carries an injectable event source, `var currentEvent: () -> NSEvent? = { NSApp.currentEvent }`, which `hitTest` reads instead of touching `NSApp.currentEvent` directly.
  - Its `hitTest` claims the point only when that event is an `otherMouseDown`/`otherMouseDragged`/`otherMouseUp` with `buttonNumber == 2`. That decision is a static `claims(type:buttonNumber:)`. Every other event (left, right, hover, tooltip tracking) passes through to SwiftUI, so selection, the close mark and the context menu are untouched.
  - The tab closes on `otherMouseUp` inside the catcher's bounds, through `actions.close(.close, anchor)`, which is the same funnel. It never calls `select`.
  - It draws nothing and has no `draw(_:)`.
- [ ] ⌥-click: `TabStatusMark`'s close mark reads `NSEvent.modifierFlags.contains(.option)` in its action. With ⌥ held it runs `closeOthers` for its tab through `closeTabs`; otherwise it runs today's single close.
- [ ] Tooltip: `.help(DisplayPath.tooltip(fileURL: file.url, projectRoot: root))` on the cell and the row. The close mark's own `.help("Close")` keeps winning over its small area.
- [ ] Tests (`TabMiddleClickTests`, app bundle):
  - `claims` is true only for the three other-mouse types with button 2;
  - false for left, right and other button numbers;
  - a catcher view's `hitTest`, with its `currentEvent` source replaced by a closure returning a synthesized `CGEvent` center-button event wrapped through `NSEvent(cgEvent:)`, claims the point; the same view with a left-button event, and with a source returning nil, answers nil.
- [ ] Run `swift test` (`ChromeThemeSourceGatingTests`, `ZoomSourceGatingTests` and `DrawDirtyRectSourceGatingTests` must stay green over the edited files), `swiftlint --strict`, and the PisakaAppTests bundle (`xcodegen generate` first for the new test file). All must pass before Task 7.

### Task 7: App: Reveal in Project Tree

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [ ] Add `struct TreeRevealRequest: Equatable { token: Int; target: URL; ancestors: [URL] }`, app-side in `ProjectTreeView.swift`. `PisakaApp` holds it as one `@State` with a monotonic token. Reveal in Project Tree does two things:
  - selects the tab (`model.select(id)`), so the existing `TreeSelection` highlights the row; this is the one selection, not a second spelling;
  - assigns a new request built from `TreeRevealRule.ancestors`.
- [ ] `ProjectTreeView` and `DirectoryNodeView` take `reveal: TreeRevealRequest?`, handed down the recursion beside `selection`.
  - A node whose standardized url is in `ancestors` sets `isExpanded = true` in both `.onChange(of: reveal)` and `.onAppear`, because a child node created by its parent's expansion sees the request only on appear.
  - Each node remembers the last token it honoured in `@State`, so a later collapse by the user is never fought by a stale request.
  - Expansion goes through the existing `onChange(of: isExpanded)` → `loadChildren()` path. Lazy loading and the `treeRevision` refresh are unchanged.
- [ ] Scrolling is causal, not timed. The file row whose url matches `reveal.target` (standardized) reports `onRevealed(token)` from its `.onAppear` and from `.onChange(of: reveal)` (for a row already on screen). `ProjectTreeView` then calls `proxy.scrollTo(target, anchor: .center)` on the existing `ScrollViewReader`. File rows gain `.id(url)` for that; the existing `"draft-row"` id stays.
- [ ] Tests: the ancestor computation is `TreeRevealRuleTests` (Task 5), including the three-level case acceptance criterion 7 names. Add a `TreeRevealRequest` equality and token test only if the type carries logic beyond its fields; otherwise none. The SwiftUI wiring is glue, untested by convention.
- [ ] Run `swift test`, `swiftlint --strict` and the PisakaAppTests bundle; all must pass before Task 8.

### Task 8: App: tab navigation commands, window tabbing off, the uniqueness suite sees every chord

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `Sources/Pisaka/AppDelegate.swift`
- Modify: `Tests/PisakaCoreTests/MenuShortcutUniquenessTests.swift`
- Create: `Tests/PisakaAppTests/TabChordPassThroughTests.swift`

- [ ] Add a `CommandGroup(before: .windowList)` in the Window menu with these items, each `.disabled` when its `TabNavigationRule` answer is nil:
  - "Show Next Tab" `.keyboardShortcut("]", modifiers: [.command, .shift])`, and a second "Show Next Tab" `.keyboardShortcut(.tab, modifiers: .control)`. Two items, following the View menu's duplicated Zoom In precedent;
  - "Show Previous Tab" `.keyboardShortcut("[", modifiers: [.command, .shift])` and `.keyboardShortcut(.tab, modifiers: [.control, .shift])`;
  - a "Select Tab" submenu with "Tab 1"…"Tab 8" (`"1"`…`"8"`, `.command`) and "Last Tab" (`"9"`, `.command`). Each is spelled as its own literal declaration, never generated in a loop, so the uniqueness scan sees all nine.
- [ ] Add `applicationWillFinishLaunching(_:)` to `AppDelegate` and set `NSWindow.allowsAutomaticWindowTabbing = false` there, before any window exists. The app has exactly one `WindowGroup` window. Left on, AppKit adds its own Window-menu "Show Next Tab / Show Previous Tab" items bound to ⌃Tab / ⌃⇧Tab for native window tabs. Those items are invisible to the source scan and would take the chord from ours.
- [ ] Extend `MenuShortcutUniquenessTests`:
  - The pattern also matches the `KeyEquivalent` constant form (`.keyboardShortcut(.tab, modifiers: …)`), so the ⌃Tab chords are in the set. `FoldCommands`' arrow chords join the set too; they collide with nothing.
  - Rewrite the doc comment's "what is matched" paragraph to match.
  - Add one assertion, over comment-stripped text, that `AppDelegate.swift` assigns `allowsAutomaticWindowTabbing = false`, with the reason in the suite's doc comment.
- [ ] Verify the chords reach the menu. `SwiftTerm`'s `TerminalView` overrides `keyDown` but not `performKeyEquivalent`, and the menu is consulted before `keyDown`; record that by reading the source at the pinned revision. In `TabChordPassThroughTests` (app bundle), synthesize the new chord events (⌘⇧], ⌘⇧[, ⌃Tab, ⌃⇧Tab, ⌘1, ⌘8, ⌘9) and assert that `performKeyEquivalent` returns false for them on:
  - the editor's text view subclass, made first responder in a test window;
  - Local Changes' outline view subclass.

  These are the app's only `performKeyEquivalent` overrides.
- [ ] Run `swift test`, `swiftlint --strict` and the PisakaAppTests bundle; all must pass before Task 9.

### Task 9: Verify acceptance criteria

- [ ] Run `swift test`.
- [ ] Run `swiftlint --strict` from the repository root.
- [ ] Run `xcodegen generate`, then `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`. Everything must be green except the pre-existing scale-1.8 layout assertions already recorded.
- [ ] Build `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -configuration Release build` and `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build`.
- [ ] `grep -rn "non-empty prefix[ ]of it" docs/plans/` finds nothing; that includes this plan once it moves to `completed/`.
- [ ] Confirm the new Core rules (`TabCloseRule`, `TabNavigationRule`, `TreeRevealRule`, the `DisplayPath` additions) are fully covered by their suites (80%+ line coverage via `swift test --enable-code-coverage`).

### Task 10: Update documentation

- [ ] `docs/architecture/core-services.md`: add entries for `TabCloseRule.swift` (the commands, the tab-order targets, the stop-at-first-refusal walk, the menu availability, and why Close Saved needs no special case) and `TabNavigationRule.swift` (the wrap, ⌘9 as last, nil as disabled).
- [ ] `docs/architecture/core-workspace.md`: update `DisplayPath.swift` with `relativePath` and `tooltip` (why the tooltip is absolute rather than `~`) and add a `TreeRevealRule.swift` entry (the tree's spelling, the root included).
- [ ] `docs/architecture/app-window.md`: in the `TabListView`/`TabRowView` and `TabStripView` entries, document:
  - the shared `TabActions`, the context menu, `TabMiddleClickCatcher` (its hit-test rule, its injectable event source, and why it closes on mouse-up), the ⌥-click on `TabStatusMark` and the tooltip;
  - the `ProjectTreeView` entry's one-shot `TreeRevealRequest` (token, ancestors, expansion on appear, causal scroll).
- [ ] `docs/architecture/app-shell.md`: document the funnel's Bool result and `closeTabs`, the Window-menu tab commands, and `allowsAutomaticWindowTabbing = false` in `applicationWillFinishLaunching(_:)` with its reason.
- [ ] `docs/FEATURES.md`:
  - The tabs bullet: middle click, the context menu and its disabled states, ⌥-click, the four navigation chords with wrap-around, ⌘1…⌘8 / ⌘9, and the path tooltip.
  - The two "no copy-path action" sentences (the path bar description and the known-limitations entry): they stay true of the bar, but each now points at the tab menu's Copy Path / Copy Relative Path.
  - "No tab reordering or split views" stays.
- [ ] `README.md`'s shortcut table: add ⌘⇧] / ⌘⇧[ (also ⌃Tab / ⌃⇧Tab), ⌘1…⌘8, ⌘9, and a "Middle-click a tab" row. The Welcome screen advertises none of these, so `WelcomeScreen.swift` is unchanged.
- [ ] `CLAUDE.md`: add the index names only: `TabCloseRule.swift` and `TabNavigationRule.swift` under `core-services.md`, and `TreeRevealRule.swift` under `core-workspace.md`. Re-run `swift test` so `LintConfigurationTests` confirms the size bound.

## Post-Completion

Manual checks in a running Debug build (macOS):

- Middle click closes a clean tab in both orientations. On a dirty tab the Save / Don't Save / Cancel prompt appears, and Cancel leaves it open. Left click still selects, and the editor's middle-drag column selection still works.
- The context menu appears on right click and ⌃-click in both orientations. Check the disabled states for an untitled buffer, a database viewer tab, a lone tab and the last tab. Run a Close Others over two dirty tabs and cancel the first prompt: that tab and every later one stay open.
- ⌥-click on the close mark closes the others, with prompts; a plain click closes only that tab.
- ⌘⇧] / ⌘⇧[ / ⌃Tab / ⌃⇧Tab wrap, with focus in the editor, in the terminal and in the project tree; ⌘1…⌘8 and ⌘9 work. If ⌘⇧] does not fire on the US layout, respell it as `"}"` with `.command` (likewise `"{"`), update the uniqueness inventory, and record the reason in `app-shell.md`.
- The tooltip shows the relative path, an absolute path for a file outside the project, and "Untitled".
- Reveal in Project Tree on a file three levels deep in a fully collapsed tree expands every ancestor, selects the row and scrolls it into view.
