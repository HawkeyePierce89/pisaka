# Text search: per-file find/replace, gitignore matcher, and project-wide find in files

## Overview
One plan covering the whole search feature as a single continuous sequence: a pure Foundation-only search/replace engine in `PisakaCore`, a JetBrains-style search bar above the editor (⌘F), a pure gitignore pattern matcher, and a non-modal Find in Files window (⌘⇧F) with project-wide Replace All. Everything decision-shaped lives in Core under tests; `Sources/Pisaka` keeps AppKit IO, colors, and dispatch. iOS is out of scope for the whole feature — new view files are `#if os(macOS)`, Core stays Foundation-only (enforced by the existing `CrossPlatformAuditTests`).

Shortcut conflict (resolved by the answer earlier in this session): "Show/Hide Local Changes" moves from ⌘⇧G to ⌘⇧C, freeing ⌘⇧G for Find Previous (the macOS standard).

The per-file search deliberately has **no debounce** (it re-runs on every keystroke/toggle/edit); the decision and its known headroom are recorded in the controller's doc comment rather than pre-built (see Task 4).

## Context
Files involved:
  - Create (Core): `Sources/PisakaCore/TextSearch.swift`, `Sources/PisakaCore/GitignoreMatcher.swift`, `Sources/PisakaCore/ProjectSearchModel.swift`
  - Create (tests): `Tests/PisakaCoreTests/TextSearchTests.swift`, `Tests/PisakaCoreTests/GitignoreMatcherTests.swift`, `Tests/PisakaCoreTests/ProjectSearchModelTests.swift`
  - Create (view, macOS): `Sources/Pisaka/EditorSearchState.swift`, `Sources/Pisaka/EditorSearchController.swift`, `Sources/Pisaka/SearchBarView.swift`, `Sources/Pisaka/ProjectSearchView.swift`, `Sources/Pisaka/ProjectSearchWindowController.swift`
  - Modify: `Sources/PisakaCore/FileService.swift`, `Sources/Pisaka/BracketOverlayLayoutManager.swift`, `Sources/Pisaka/BracketHighlightController.swift`, `Sources/Pisaka/CodeEditorView.swift`, `Sources/Pisaka/ContentView.swift`, `Sources/Pisaka/PisakaApp.swift`, `Sources/Pisaka/SyntaxTheme.swift`, `CLAUDE.md`, `README.md`
Related patterns:
  - Core engine + thin view glue: `DuplicateEngine`/`AutoPairEngine`/`IndentEngine` (`NSString` + UTF-16 offsets, value-type results).
  - Line numbers and separators: `LineStartIndex.offsets(in:)` (LF, CR, CRLF as one, NEL, LS, PS).
  - Human-readable error text in Core: `FileServiceError`/`GitError` (`LocalizedError.errorDescription`).
  - Highlighting: `BracketOverlayLayoutManager` intercepts `setTemporaryAttributes(_:forCharacterRange:)` and mixes overlays back in; it is the *sole* writer of temporary `.backgroundColor` (the blanket remove in `setPairRanges` would otherwise wipe another owner's background).
  - Debounce + generation-token precedent (for the *recorded* headroom note, not built now): `MinimapTokenizer`.
  - Programmatic edits: `isApplyingProgrammaticEdit` + `insertText(_:replacementRange:)` (the Cmd+D discipline in `Coordinator.duplicateSelection`); `EditorTextView` callback hooks capture the coordinator *weakly* (`onDuplicate`).
  - Inserting a bar above the editor: `ContentView.editorZone` (`PathBarView` in a `VStack`).
  - Async model shape: `LocalChangesModel`/`CommitLogModel` — `@MainActor ObservableObject`, injected services, synchronous `prepareFor…() -> Int` generation capture before the `Task` hop, guard after every `await`, pure static helpers for the branching decisions.
  - Disk-writer coordination: `PisakaApp.applyMerge`/`revertChanges` — `autosave.suspend()` + `localChanges.beginRevert()` raised synchronously before the first `await`, released by `defer`.
  - Separate non-modal window: `DiffWindowController` + `EscClosableWindow` (retained window + per-window `WindowDelegate`, `closeAll()` on `willTerminateNotification`).
  - Defaulted protocol methods so existing stubs keep compiling: `FileServicing`'s extension (`symbolicLinkDestination`, the mutating ops).
Dependencies: none new.

## Development Approach
  - **Testing approach**: TDD for Core (test → implementation). The view layer is deliberately untested per the repository convention (`CLAUDE.md`) — view tasks are verified by the two builds plus the manual scenario at the end.
  - Complete each task fully before the next; `swift test` must be green before starting the next task.
  - Logic lives in Core only; `Sources/Pisaka` keeps dispatch, colors, and AppKit IO.
  - Tasks are ordered by dependency: engine → editor bar → gitignore → project model → Find in Files window.

## Implementation Steps

### Task 1: Core — search engine (`TextSearchEngine.matches`)

**Files:**
  - Create: `Sources/PisakaCore/TextSearch.swift`
  - Create: `Tests/PisakaCoreTests/TextSearchTests.swift`

  - [x] Write the tests first: literal with and without case sensitivity; empty/whitespace-only pattern → `.emptyPattern`; invalid regex → `.invalidRegex(reason:)` with a non-empty `reason` and non-empty `errorDescription`; regex with capture groups; zero-length matches (`a*`) — the walk terminates and locations strictly increase; `wholeWord` at boundaries (start/end of buffer, adjacency to `_`, a digit, Cyrillic, an emoji surrogate pair, punctuation); line numbers for LF, CRLF, CR, U+2028 (1-based; a match exactly at a line start belongs to that line).
  - [x] Write the explicit `wholeWord` + `isRegex` combination test: the post-filter judges the *regex match's* own boundaries, not a literal pattern's — e.g. `\w+` over `foo_bar baz` yields whole-word matches while a pattern that can match mid-word (`[а-я]+` inside a longer Cyrillic word, `oo` inside `foo`) is filtered out; assert a case where a regex match's edge is adjacent to `_`/a digit.
  - [x] Implement `public struct SearchQuery: Equatable` (`pattern`, `isRegex`, `caseSensitive`, `wholeWord`; public init defaulting the flags to `false`), `public struct SearchMatch: Equatable` (`range: NSRange`, `lineNumber: Int`), `public enum TextSearchError: Error, Equatable, LocalizedError` (`.emptyPattern`, `.invalidRegex(reason:)` — `reason` from the `NSError.localizedDescription` `NSRegularExpression` produces).
  - [x] Implement `public static func matches(in text: NSString, query: SearchQuery) throws -> [SearchMatch]`: literal — a loop over `range(of:options:range:)` (`.caseInsensitive` per the flag) advancing by `max(1, found.length)`; regex — `NSRegularExpression` + `matches(in:options:range:)`; empty pattern → `throw .emptyPattern`.
  - [x] Implement `wholeWord` as a post-filter over the neighboring *scalars* (surrogate-safe unichar-pair reads, as in `AutoPairEngine`): a neighbor is "word" when `CharacterSet.alphanumerics` contains the scalar or it is `_`; a buffer boundary is a non-word neighbor. The filter runs over whatever ranges the literal *or* regex path produced, so it is one rule for both.
  - [x] Line numbers: one `LineStartIndex.offsets(in:)` per call plus a binary search per match (not O(n·m)).
  - [x] Run `swift test` — must be green.

### Task 2: Core — replacement plan and navigation cursor

**Files:**
  - Modify: `Sources/PisakaCore/TextSearch.swift`
  - Modify: `Tests/PisakaCoreTests/TextSearchTests.swift`

  - [x] Write the tests first: literal replacement (template verbatim, `$1` not interpreted); regex replacement with `$1`/`$0`; `replacePlan` — strictly last-to-first ordering, overlapping input ranges dropped with the earlier-in-document one winning; an integration test applying the plan to an `NSMutableString` in order for length-changing replacements (shorter/longer/empty) — the result equals the expected string; `index(nearestTo:in:forward:)` — forward/backward with wraparound, empty array → `nil`, caret before the first / after the last match.
  - [x] Implement `public struct ReplaceEdit: Equatable` (`range: NSRange`, `replacement: String`) — a struct rather than a tuple so a plan is `Equatable` in tests.
  - [x] Implement `public static func replacement(for match: SearchMatch, in text: NSString, query: SearchQuery, template: String) -> String`: literal → `template`; regex → rebuild the `NSTextCheckingResult` via `firstMatch(in:options:.anchored, range: match.range)` + `replacementString(for:in:offset:template:)`; an invalid regex or a non-matching range → `template` unsubstituted (documented; the function does not throw).
  - [x] Implement `public static func replacePlan(matches:in:query:template:) -> [ReplaceEdit]` (compiles the regex once, drops overlaps, returns descending by `range.location`) and `public static func index(nearestTo location: Int, in matches: [SearchMatch], forward: Bool) -> Int?`.
  - [x] Run `swift test` — must be green.

### Task 3: View — search background in the overlay manager and theme colors

**Files:**
  - Modify: `Sources/Pisaka/SyntaxTheme.swift`
  - Modify: `Sources/Pisaka/BracketOverlayLayoutManager.swift`
  - Modify: `Sources/Pisaka/BracketHighlightController.swift`

  - [x] `SyntaxTheme`: add `searchMatchBackground` and `currentSearchMatchBackground` (`PlatformColor.dynamic(light:dark:)`, distinguishable from each other, from the matched-pair background, and from the selection) plus the macOS mirrors `nsSearchMatchBackground` / `nsCurrentSearchMatchBackground`.
  - [x] `BracketOverlayLayoutManager`: add a `searchRanges: [NSRange]` cache (ascending by `location`) and `currentSearchRange: NSRange?` alongside the existing `pairRanges`, plus a `setSearchRanges(_:current:)` method.
  - [x] Introduce **one** private painter `paintBackgrounds(clippedTo: NSRange, clampingTo length: Int)` — the *only* place in the class that adds a temporary `.backgroundColor`. It walks the three caches in a single fixed order, pair → matches → current (later write wins, so the current match sits on top of a match, which sits on top of the pair highlight), intersecting each with the clip range (`searchRanges` binary-searched like the rainbow runs). Because the order lives in one loop body, it is physically impossible for the two paint paths to disagree.
  - [x] Route **both** paint paths through that painter, and state the invariant in its doc comment: (a) the state setters go through a private `repaintBackgrounds(clearing:clampingTo:)` — remove `.backgroundColor` over the previously painted ranges, then `paintBackgrounds(clippedTo: <full 0..<length>, clampingTo: length)` — implementing `setPairRanges` and `setSearchRanges(_:current:)`; (b) `applyOverlays(in charRange:)` calls the *same* `paintBackgrounds(clippedTo: charRange, clampingTo: storageLength)` after the rainbow loop, so Neon's per-write repaint (scroll, re-parse) yields the identical priority the navigation path does — no flicker depending on which path painted last. No other method may call `addTemporaryAttributes(.backgroundColor)` directly.
  - [x] Replace `clearPair(storageLength:)` with `clearBackgrounds(storageLength:)` (resets *both* background caches — pair and search — and the attributes in **pre-edit** coordinates, the existing rationale still applying), update the call site in `BracketHighlightController.noteEdit`, and document that after an edit the search highlight is restored by the search re-run.
  - [x] Run `swift test` (Core untouched — no regressions) and the macOS build — both green.

### Task 4: View — editor search state and controller

**Files:**
  - Create: `Sources/Pisaka/EditorSearchState.swift`, `Sources/Pisaka/EditorSearchController.swift`
  - Modify: `Sources/Pisaka/CodeEditorView.swift`

  - [x] `EditorSearchState` — `@MainActor final class … ObservableObject` (window-scoped, owned by `PisakaApp`): `isVisible`, `isReplaceExpanded`, `pattern`, `template`, `caseSensitive`, `wholeWord`, `isRegex`, `matchCount`, `currentIndex: Int?`, `errorText: String?`, `focusRequest: Int` (focus/select-all token), plus weakly held actions (`findNext`/`findPrevious`/`replaceCurrent`/`replaceAll`) registered by the editor coordinator; `open()`, `close()` (clears the highlight), `currentQuery -> SearchQuery`.
  - [x] `EditorSearchController` — the execution owner: recompute `TextSearchEngine.matches` for (buffer, query), pick the current match via `index(nearestTo:forward:)` (kept near the caret across edits), push ranges into `BracketOverlayLayoutManager.setSearchRanges(_:current:)`, navigate (`scrollRangeToVisible` + `setSelectedRange`), `replaceCurrent` (one `insertText` under `isApplyingProgrammaticEdit`, then re-run and advance), `replaceAll` (walk `replacePlan` last-to-first inside the file's `beginUndoGrouping`/`endUndoGrouping` — one ⌘Z), and publish `matchCount`/`currentIndex`/`errorText`.
  - [x] Record the **no-debounce decision** in the controller's type-level doc comment (deliberate, not an oversight): the search re-runs synchronously on every field/toggle change and every text edit because a literal scan over one open file is cheap; the known headroom is that a heavy regex over a megabyte-scale file could become noticeable, and the fix if it is ever reported is a debounce + generation token per the `MinimapTokenizer` precedent. Nothing is built for it now.
  - [x] `CodeEditorView`: accept `@ObservedObject search: EditorSearchState`; `makeNSView` attaches the controller and registers actions; `updateNSView` re-runs on `fileID`/buffer/query change (compared against an "applied" query snapshot) and clears when `isVisible == false`; `teardown()` resets the controller and unregisters actions. Publish into the `ObservableObject` via `DispatchQueue.main.async` (avoiding "Publishing changes from within view updates").
  - [x] Re-run on text edits by extending the existing `bracketTextStorageDidProcessEditing` handler (after `noteEdit`, which already cleared the background). *(Deferred one main-loop turn via `setNeedsRefresh()`: the notification is posted before the storage notifies its layout managers, so painting post-edit backgrounds inside it would have them shifted off their characters.)*
  - [x] `EditorTextView`: add `onCancelSearch: (() -> Bool)?` and override `cancelOperation(_:)` — Esc in the editor closes an open search bar (weak coordinator capture, like `onDuplicate`).
  - [x] Run `swift test` and the macOS build — both green.

### Task 5: View — the search bar, editorZone insertion, and the Find menu

**Files:**
  - Create: `Sources/Pisaka/SearchBarView.swift`
  - Modify: `Sources/Pisaka/ContentView.swift`, `Sources/Pisaka/PisakaApp.swift`

  - [x] `SearchBarView` (macOS, thin): query field, `Aa`/`ab`/`.*` toggles, a `3/17` counter (blanked on error), ▲/▼ prev/next, a button expanding the replace row (replace field + `Replace` / `Replace All`), red reason text on `.invalidRegex`; `.onSubmit` → next; `.onExitCommand` → `search.close()`; `@FocusState` driven by `focusRequest` with a field-editor select-all on a repeated ⌘F.
  - [x] `ContentView`: accept `search: EditorSearchState` (defaulted so previews compile), insert `SearchBarView` into `editorZone` between `PathBarView`/`Divider` and `CodeEditorView` (rendered only while `search.isVisible`), thread the state into `CodeEditorView`.
  - [x] `PisakaApp`: `@StateObject private var search = EditorSearchState()` threaded into `ContentView`; a new `CommandMenu("Find")` — "Find…" (⌘F, opens/focuses), "Find Next" (⌘G), "Find Previous" (⌘⇧G), "Replace…" (⌘⌥F, expands the replace row), all `.disabled(model.selectedID == nil)`.
  - [x] `PisakaApp`: move "Show/Hide Local Changes" from ⌘⇧G to ⌘⇧C.
  - [x] Run `swift test` and both builds (macOS + `generic/platform=iOS`) — green.

### Task 6: Core — gitignore pattern parsing and single-file matching

**Files:**
  - Create: `Sources/PisakaCore/GitignoreMatcher.swift`
  - Create: `Tests/PisakaCoreTests/GitignoreMatcherTests.swift`

  - [x] Write the tests first, one per gitignore(5) grammar rule: blank lines and `#` comments dropped; `\#`/`\!` escaping; trailing whitespace stripped unless escaped; `!` negation; anchoring (a `/` anywhere but the trailing position → root-relative, otherwise match at any depth); trailing `/` → directories only (and `dir/` does not match a same-named file); `*` not crossing `/`; `**` leading, trailing, and in the middle; `?`; `[a-z]`/`[!a-z]` classes; CRLF file contents; a pathological pattern (`a*a*a*a*b` against a long path) completing fast.
  - [x] Implement `public struct GitignorePattern` (parsed form: negated, anchored, directory-only, component globs) and `public struct GitignoreRules` with `init(fileContents: String)`.
  - [x] Implement the component-wise matcher (not a naive regex translation): a memoized/linear backtracking walk over path components with `**` support, plus `public enum Glob { static func matches(name:pattern:) -> Bool }` for the single-component case (reused by the file mask in Task 8).
  - [x] Implement `GitignoreRules.decision(relativePath:isDirectory:) -> Decision?` (`.ignored`/`.included`/`nil` when no pattern matches) with last-match-wins inside one file.
  - [x] Run `swift test` — must be green.

### Task 7: Core — gitignore stack (nesting, negation semantics, oracle set)

**Files:**
  - Modify: `Sources/PisakaCore/GitignoreMatcher.swift`
  - Modify: `Tests/PisakaCoreTests/GitignoreMatcherTests.swift`

  - [x] Write the tests first: a nested `.gitignore` overrides the root one; negation after exclusion and vice versa; a negation under an excluded directory does not resurrect the file; anchored `build/foo` does not match `a/build/foo` while unanchored `foo` matches at any depth; `.git` is not the matcher's business (excluded by the caller).
  - [x] Add the oracle diff test: a table of ~30 (pattern, path, expected) pairs cross-checked against `git check-ignore`, with a comment recording exactly how the expectations were captured (the command line and repo layout used), asserting our matcher agrees on every pair. *(43 rows captured from git 2.55.0 with `core.ignorecase=false`; the one `check-ignore`-vs-traversal divergence — `abc/**` reported as matching the directory `abc/` itself — is held out of the table and documented in its own test with the `git status` evidence.)*
  - [x] Implement `public struct GitignoreStack`: `appending(rules:relativeDirectory:)` and `isExcluded(relativePath:isDirectory:) -> Bool` — deeper rules override outer ones, last match wins within a file, and an excluded parent directory is never re-included by a descendant negation (git semantics).
  - [x] Run `swift test` — must be green.

### Task 8: Core — project search model: traversal and live search

**Files:**
  - Modify: `Sources/PisakaCore/FileService.swift`
  - Create: `Sources/PisakaCore/ProjectSearchModel.swift`, `Tests/PisakaCoreTests/ProjectSearchModelTests.swift`

  - [x] `FileServicing`: add two methods *defaulted in the protocol extension* (so every existing stub keeps compiling) — `fileByteCount(at:) -> Int?` and `readTextIfNotBinary(url:maxBytes:) throws -> String?` (nil for a binary file — NUL in the head — or one over the cap); implement both on the real `FileService` and add `FileServiceTests` coverage for the binary/oversize/text cases. *(The `readTextIfNotBinary` default is a faithful implementation in terms of `read`/`fileByteCount` — not a stub-only shortcut — so every conforming type inherits the real contract; the real `FileService` overrides it with a byte-level version that never decodes a file it will reject, and also rejects non-UTF-8 bytes.)*
  - [x] Write the model tests first (with stubs): traversal honoring nested `.gitignore` files and always skipping `.git`; file mask (`*.ts,*.tsx`, via `Glob`); binary and oversize files skipped; a dirty open buffer searched by buffer text rather than disk; a new query superseding an in-flight one (generation); the match cap producing `truncated == true`; a root change synchronously clearing stale results.
  - [x] Implement `public struct FileSearchResult: Equatable` (`fileURL`, `[SearchMatch]`, preview lines) and `public final class ProjectSearchModel: @MainActor ObservableObject` publishing `results`, `isSearching`, `truncated`, `errorMessage`, `query`, `fileMask`; injected `FileServicing` plus *closure providers* for open buffers (`bufferText: (URL) -> String?`) rather than a `WorkspaceModel` reference. *(A result also carries `relativePath` for the group header, and previews are a parallel `[MatchPreview]` — the clipped line plus the match's range inside it — so a minified single-line file cannot produce a 200 KB row.)*
  - [x] Implement `prepareForSearch(root:) -> Int` (synchronous generation bump + stale-state clear, the `LocalChangesModel` precedent) and `search(root:query:mask:request:) async` — off-main traversal in chunks, guard after every `await`, cap at 10 000 matches with `truncated`, mask/binary/size/gitignore skips as pure static helpers. *(Traversal visits a directory's files before its subdirectories so results stream in root-first; a symlinked directory is not descended into; results publish per chunk.)*
  - [x] Run `swift test` — must be green.

### Task 9: Core — project-wide Replace All

**Files:**
  - Modify: `Sources/PisakaCore/ProjectSearchModel.swift`, `Tests/PisakaCoreTests/ProjectSearchModelTests.swift`

  - [x] Write the tests first: the open-buffer branch (edit routed through the buffer-apply closure, file stays dirty, no disk write); the disk branch (read-modify-write); a file whose contents changed since the results were captured is skipped and reported, not clobbered (the `guardRevert` philosophy); a per-file write failure does not abort the batch; the summary counts replaced/skipped/failed correctly.
  - [x] Implement `public struct ReplaceSummary: Equatable` (`filesChanged`, `matchesReplaced`, `filesSkipped`, `errors`) and `replaceAll(template:) async -> ReplaceSummary`: per file build a `TextSearchEngine.replacePlan`, re-read and re-match immediately before writing, apply last-to-first. *(Staleness is judged on the fresh scan's **leading** matches, because the match cap can clip a file's list mid-way — a match appearing after every captured one cannot invalidate any of them. A skipped file — stale, or newly binary/oversize — is counted separately from an `errors` entry, which is a read/write that actually failed; neither stops the batch.)*
  - [x] Route buffer edits through injected closures (`bufferText` / `applyBufferText: (URL, String) -> Bool`) so Core keeps no reference to `WorkspaceModel`.
  - [x] Run `swift test` — must be green.

### Task 10: View — the Find in Files window (⌘⇧F)

**Files:**
  - Create: `Sources/Pisaka/ProjectSearchView.swift`, `Sources/Pisaka/ProjectSearchWindowController.swift`
  - Modify: `Sources/Pisaka/PisakaApp.swift`

  - [x] `ProjectSearchWindowController` (macOS): one retained `EscClosableWindow` hosting `ProjectSearchView` (the `DiffWindowController` shape, minus multi-window — a repeat ⌘⇧F focuses the existing window); `closeAll()` wired into the existing `willTerminateNotification` observer.
  - [x] `ProjectSearchView` (thin, `@ObservedObject ProjectSearchModel`): query field + `Aa`/`ab`/`.*` toggles + mask field + Find/Replace switch (with the replace field), ~300 ms debounced live search (unlike the per-file bar, a project-wide traversal is expensive per keystroke — this debounce is required by the ticket), results grouped by file with per-match preview lines (match highlighted), a "results truncated" note at the cap, `.preferredColorScheme` and `SettingsStore` font as elsewhere.
  - [x] Match activation (click / Enter): open the file through the existing open-file path and select the match's range in the editor; the window stays open. *(The range reaches the editor through a new window-scoped `EditorRevealState` threaded `PisakaApp → ContentView → CodeEditorView`: activation may **open** the file, so the request is recorded before the editor that will honour it exists, and is consumed once by token in `updateNSView` — after the buffer swap, so the selection lands in the file's own text.)*
  - [x] Replace All: an `NSAlert` confirmation naming file/match counts, then the summary and an automatic re-search.
  - [x] `PisakaApp`: own the `ProjectSearchModel` + controller, add "Find in Files…" (⌘⇧F) to the Find menu (`.disabled(model.projectRoot == nil)`), wire the buffer provider closures to `WorkspaceModel`, call `prepareForSearch` synchronously on folder open/close, and bracket `replaceAll` with the same disk-writer gates as `applyMerge` (`autosave.suspend()` + `localChanges.beginRevert()` raised before the first `await`, released by `defer`), refusing while `localChanges.isReverting`; refresh Local Changes and bump `treeRevision` afterward. *(The buffer closures are `let`s taken at construction, so `PisakaApp` gained an `init()` that builds the `WorkspaceModel` first and wraps both in `StateObject`; there is no "close folder" action, so `prepareForSearch` is called on folder open only.)*
  - [x] Run `swift test` and both builds — green.

### Task 11: Verify acceptance criteria
  - [x] `swift test` — the whole suite green *(1098 tests, 0 failures)*
  - [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build` — green *(BUILD SUCCEEDED)*
  - [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build` — green *(BUILD SUCCEEDED)*
  - [x] verify the three new Core files import nothing but `Foundation` *(`CrossPlatformAuditTests` passes as part of the suite; it asserts value-level platform independence rather than scanning imports, so the import check was made directly: `TextSearch.swift`, `GitignoreMatcher.swift` and `ProjectSearchModel.swift` each declare `import Foundation` and nothing else, and the only non-Foundation import anywhere in Core remains the pre-existing `CoreGraphics` in `MinimapGeometry.swift`)*

### Task 12: Update documentation

**Files:**
  - Modify: `CLAUDE.md`, `README.md`

  - [x] `CLAUDE.md` Core list: `TextSearch.swift` (API, wholeWord/zero-length/line-number semantics — including that the wholeWord post-filter judges the produced match's own boundaries, so it composes with regex — plan ordering; boundaries: no query history, no "replace in selection"), `GitignoreMatcher.swift` (supported grammar and its limits — tree `.gitignore` files only, no `core.excludesFile`/`.git/info/exclude`, `.git` excluded by callers), `ProjectSearchModel.swift` (traversal, skips, cap/truncation, generation guards, the two replace branches and the stale-file rule).
  - [x] `CLAUDE.md` view sections: the search bar + `EditorSearchState`/`EditorSearchController` under `CodeEditorView` — including the recorded **no-debounce** decision for the per-file search (cheap literal re-scan per keystroke; known headroom = a heavy regex on a huge file; the fix, if reported, is the `MinimapTokenizer` debounce + generation shape) *contrasted with* the deliberate ~300 ms debounce in the Find in Files window; the `BracketOverlayLayoutManager` search-background extension — the sole-owner-of-temporary-`.backgroundColor` invariant *and* the single-painter rule (one private `paintBackgrounds` shared by the state setters and by `applyOverlays`, fixed pair → matches → current order, so the Neon-write path and the navigation path can never disagree on priority); the new `SyntaxTheme` colors; the Find menu, the Local Changes move to ⌘⇧C, and the Find in Files window + writer coordination under `PisakaApp`.
  - [x] `README.md`: the "find and replace in a file" and "find in files" features, plus ⌘F / ⌘G / ⌘⇧G / ⌘⌥F / ⌘⇧F and the changed ⌘⇧C in the shortcut table. *(The "No find/replace." MVP limitation was replaced with the feature's real boundaries — macOS-only, no query history, no replace-in-selection, tree `.gitignore` files only.)*

## Post-Completion (manual verification, outside the automatable steps)
  - search/navigation/replace in an open file; Replace All undone by a single ⌘Z; an invalid regex shows its reason in red in the bar (no alert) and the counter blanks
  - typing in a large file with the bar open stays responsive (the no-debounce decision holds in practice; a heavy regex on a megabyte-scale file is the known headroom to watch)
  - match highlighting coexists with rainbow brackets and matched-pair highlighting (neither erases the other on scroll or edit); the current match keeps its distinct color while scrolling over it (the Neon repaint path) and while stepping with ⌘G
  - Esc closes the bar and clears the highlight; a repeated ⌘F focuses the field with its text selected
  - ⌘⇧C shows/hides Local Changes; ⌘⇧G steps to the previous match
  - ⌘⇧F on a JS project does not descend into `node_modules`; clicking a result opens the file at the match; a long search is superseded by a new query
  - Replace All across the project: an open dirty file keeps its unsaved edits and is replaced in the buffer, closed files are written, and the summary reports skipped files
