# Fold single-child folder chains into one `a/b/c` row (macOS project tree)

## Overview

Deep package layouts like `src/main/java/com/acme` cost one click and one indent step for every folder that holds nothing but the next folder. After this change the macOS project tree draws such a run as **one row** labelled `a/b/c`. Expanding it goes straight to the last folder's contents. Every file operation, drag, reveal and state decoration still works on the real folders behind the row.

- **The rule is Core's.** A new pure `TreeChainRule` takes one parent listing, a listing function and a symbolic-link question. It returns the rows to draw: a file, a plain folder, or a chain. A chain carries its ordered segments plus the head-vs-tail addressing of every operation, as data.
- **Listings are charged and read once.** A revision-scoped listing memo in Core makes each directory listed at most once per `treeRevision`. The listing read while probing a chain's tail is the one its row shows when expanded.
- **The view only draws the answer.**
  - A row's identity is its head.
  - Its contents are its tail's.
  - Its editable name is the tail's.
  - Its delete and drag address the head; create and drop address the tail.
- **Per-row escape hatch.** `Show as Separate Folders` / `Show as One Row`, backed by a tree-view set that is never persisted.
- Reveal in Project Tree passes through chains. Re-evaluation happens on every revision bump, which already exists.

## Context

- Files involved (Core):
  - new `Sources/PisakaCore/TreeChainRule.swift` (the rule, its row and chain values, the listing memo)
  - `Sources/PisakaCore/WorkspaceModel.swift` (one pass-through: whether a url is a symbolic link)
  - read only: `FileService.swift` (`contentsOfDirectory`, `symbolicLinkDestination`, `excludedEntryNames`), `ScopedFileAccess.swift` (`path(_:isWithin:)`), `TreeRevealRule.swift`, `MoveDropRule.swift`, `TreeDraftDismissRule.swift`
- Files involved (app, macOS):
  - `Sources/Pisaka/ProjectTreeView.swift`: `ProjectTreeView`, `TreeRevealRequest`, `DirectoryNodeView`, `FolderDisclosureStyle`, `FolderDisclosureRow`
  - `Sources/Pisaka/ProjectTreeDraftField.swift`: read; it is touched only if the rename field needs the leading-segments prefix passed in
- Tests:
  - new `Tests/PisakaCoreTests/TreeChainRuleTests.swift`
  - `Tests/PisakaCoreTests/Support/StubFileTree.swift`: reused as is, for `listedPaths`, `symlinks` and `unreadableDirectories`
  - `Tests/PisakaAppTests/TreeRevealRequestTests.swift`
  - new `Tests/PisakaAppTests/TreeChainRowLayoutTests.swift`
  - must stay green: `TreeIndentGuideLayoutTests`, `TreeRowGlyphLayoutTests`, `TreeGitStatusColourTests`, `TreeDiagnosticMarkTests`, `TreeRowBackgroundTests`, `ChromeThemeSourceGatingTests`, `ZoomSourceGatingTests`, `FoldingSourceGatingTests`, `LintConfigurationTests`
- Docs:
  - `docs/architecture/core-workspace.md`
  - `docs/architecture/app-window.md`
  - `docs/FEATURES.md`
  - `README.md`, only if it lists tree behaviour
  - `CLAUDE.md`, one index name
- Related patterns:
  - `TreeRevealRule`, `MoveDropRule`, `TreeDraftDismissRule`: pure, path-spelling-faithful Core rules for the tree
  - `TreeGitStatus` / `TreeDiagnostics`: lexical lookups asked once per row
  - `HostedRender`: one render per scale, as `TreeIndentGuideLayoutTests` does
  - `StubFileTree.listedPaths`: a counting seam separate from any budget
- Dependencies: none new. No new palette value, role, `ChromeGeometry` token, gating rule, app source file or required-reason API.

## Decisions settled here (resolving the ticket's open edges)

- **Vocabulary.** The feature's identifiers say *chain* and *separated*, never `Fold…`, for example `TreeChainRule`, `TreeChain` and `separatedFolders`. `FoldingSourceGatingTests` matches code-folding tokens (`FoldState`, `.fold(`/`.unfold(` calls). Keeping this feature's names out of that vocabulary means those rules cannot be tripped and stay meaningful.
- **Core shape.** `TreeChainRule.rows(in parentListing:, separated:, isSymbolicLink:, list:)` returns `[TreeRow]`:
  - The parent's own listing is an input, so the caller reads it, or the memo hands it over.
  - `separated` is the set of folder keys the user asked to see unfolded.
  - `TreeRow` has three cases: a file entry; a plain folder, carrying `offersShowAsOneRow`; and a chain (`TreeChain`, at least two segments).
  - `TreeRow.id` is the entry url, or the chain's head url. A folder keeps its identity as it turns from plain to chain and back.
  - A plain folder and a chain are both drawn by the one `DirectoryNodeView`, through the same `ForEach` branch. `@State` such as expansion therefore survives a reshape.
- **The walk, precisely.**
  - The rule is applied only to a listing's entries. The project root is never passed as a segment, and the root node is built by the view as itself. This is what keeps the root out of every chain.
  - For each directory entry `d` of the parent listing:
    - `d` is a symbolic link: plain folder row, never listed.
    - `d`'s listing fails: plain folder row; nothing is cached for the failure, so the row's own expansion retries as today.
    - Otherwise list `d`.
  - `d` **qualifies** when it is not in `separated` and its listing is exactly one entry that is a directory.
  - The walk appends the single child `e` while the last segment qualifies and the chain has fewer than `maximumSegments` segments. Before appending, it checks `e`:
    - `e` in `separated`: stop before it, so `e` is not a segment.
    - `e` a symbolic link: append it as the **tail** without listing it; its contents load on expansion.
    - Listing `e` fails: stop before it, so `e` becomes a plain row under the tail.
    - Otherwise: append `e` and list it.
  - A chain of one segment is a plain folder row.
  - `maximumSegments` is pinned at **32**. The 32nd segment is listed, so its listing is handed down as the tail's contents. The remainder appears as that tail's children.
  - `offersShowAsOneRow` is true exactly when `d` is in `separated` **and** would otherwise qualify.
- **Symbolic links in practice.** Today's listing (`isDirectoryKey`, which does not follow links) reports a symlinked directory as a **non-directory entry**, so in the app it already shows as a file row.
  - A run whose next entry is a link therefore ends at the link's parent, which does not qualify because its one entry is "a file". The link is drawn as that row's child.
  - The rule's own link check stays, through `symbolicLinkDestination` behind a `WorkspaceModel` pass-through. It is the stated defence for any listing that does report a link as a directory (the stub; a future listing change), and it is what the Core tests pin.
  - The cost is one link query per directory entry probed, never a listing.
  - Making the tree descend into symlinked directories is out of scope.
- **Addressing, as data on `TreeChain`** (asserted in Core). In each item, the row is the target: "Head" means the row addresses its head folder, "tail" its tail folder.

  | Operation | Target | Notes |
  |---|---|---|
  | Identity | Head | Row id, expansion key, unfold key |
  | Contents directory | Tail | |
  | Create target | Tail | |
  | Rename target | Tail | Rename siblings are the parent segment's listing names, i.e. the tail's own name. The field excludes it, as it does for any rename. |
  | Delete target | Head | |
  | Drag source | Head | |
  | Drop destination | Tail | |
  | Diagnostic-mark url | Head | |
  | Spoken git state | Head | The row stands for the head's subtree. |
  | Per-segment git urls | Each segment | |

  - Label: segment names joined with `/`.
  - Menu titles: `Rename "<tail>"`, `Delete "<label>"`, `Show as Separate Folders`. Plain folder rows keep `Rename` / `Delete`; an overridden qualifying folder adds `Show as One Row`.
  - The existing delete confirmation and the app callbacks are unchanged; they receive the real url.
- **One listing per directory per revision: `TreeListingMemo`** (Core, same file).
  - A reference type created with a listing function and asked `listing(of:revision:)`.
  - A different revision clears it.
  - Successes only are memoized, so a failure is re-read on the next ask, which preserves today's collapse/re-expand retry.
  - It is keyed as the tree spells the url (`standardizedFileURL.path`). That is the same spelling as the `separated` keys, exposed as one Core function `TreeChainRule.key(for:)`, so no new canonicalisation site exists.
  - The tree holds one memo for its lifetime and clears it on a project-root change.
  - Every node's load, the parent's probe included, lists through it. Probe order between a parent and an already-expanded child therefore never causes a second read within one revision.
  - Nothing lists outside a load: not on the FSEvents callback, not in the drop hover path, and not on an unfold toggle, which recomputes from the memo.
- **Re-evaluation.** It needs no new trigger.
  - Every expanded node reloads on a `treeRevision` bump, as today, through the memo.
  - A node also reloads when the chain value its parent hands it changes tail.
  - **Extend:** `a/b/c` gains a lone `d` and becomes `a/b/c/d`. It keeps its head identity, stays expanded and shows `d`'s listing.
  - **Shorten:** a file appears in `b`, so the row becomes `a/b`. It stays expanded, with `c`, now a plain collapsed row, and the file as children.
- **Drafts after a reshape.**
  - The existing reload check ("the listing no longer offers the way down to the drafted row") becomes a question asked of the returned rows: `TreeRow.leads(toDraftAnchor:renaming:)`, pure and in Core, using `ScopedFileAccess.path(_:isWithin:)` on standardized paths only.
    - A plain entry leads where its name is the anchor's next component, a directory still being required further down. This is today's test, unchanged.
    - A chain leads only when the anchor is its tail or lies under its tail, or when the draft renames its tail.
    - A draft anchored on an inner segment is no longer rendered and is dropped.
  - The collapse and missing-directory checks ask about the node's **contents directory** (the tail). Asking about the head would wrongly drop the chain row's own rename draft, which is anchored inside the head, on collapse.
  - `TreeDraftDismissRule` is untouched.
- **Unfold memory.**
  - `separatedFolders: Set<String>` is `@State` on `ProjectTreeView`, keyed by `TreeChainRule.key(for:)`. It is handed down as a value with one toggle callback.
  - It is not written to the session, is cleared on a project-root change, and is never pruned.
  - `Show as Separate Folders` inserts the head only. The row then shows `a` over `b/c`, and `b/c` offers the same item again.
  - `Show as One Row` removes the folder.
  - **Unfolding an expanded chain.** The tree also records the second segment in a transient "open on first appearance" set. The new node for `b/c`, or for `b` when the chain had two segments, starts expanded and removes its key, so nothing the user was looking at disappears. The head node keeps its own expansion because its identity is unchanged.
  - Unfolding a collapsed chain records nothing.
  - The same set is cleared on a root change.
- **Reveal.** `TreeRevealRequest` stays app-side and gains two chain-aware questions:
  - `expands(anyOf: segmentRevealURLs)`.
  - `isUnreachable(belowChain: segmentRevealURLs, listing: tailListing)`. A request whose step below an inner segment is not the next segment is unreachable, because the chain says that folder holds only the next one. Otherwise it is today's check below the tail.
  - A chain node expands once per token when any segment is an ancestor. Its children's reveal spelling continues from the tail's reveal spelling (head reveal url plus the segment names).
- **Drawing a chain row.**
  - One single-line label, truncated in the middle as one text: concatenated `Text` runs.
    - Each segment's name takes `ChromeColorRole.treeNameRole(for: gitStatus.state(for: segmentURL))`, or the inherited foreground when there is no role.
    - Each `/` is drawn in `textSecondary`.
  - The glyph is the folder glyph with **one** diagnostic dot, the head's mark.
  - Accessibility: one combined element with the button trait and the expanded/collapsed value. The spoken text is the label; the value uses the head's git state and mark through the existing Core composition. While drafted, `.contain`, as today.
  - **Rename draft:** the leading segments plus their `/` stay drawn as text, coloured as above, before the field. The field replaces the tail's name only.
  - **Create draft:** opens under the row and validates against the tail's listing.
  - **Drag and drop:** the row's drag source is the head and its drop destination is the tail, which splits `FolderDisclosureStyle`/`FolderDisclosureRow`'s single `url` into the two.
  - **Indent and guide:** children are inset by one `treeIndentStep`. The indent guide hangs from the row's chevron, exactly as for any folder.
  - All sizes are through `InterfaceMetrics`; all colours are roles.
- **Pinned Xcode.** Xcode 26.3 is not installed on this machine. The app-layer gates run under the installed Xcode after `xcodegen generate`, with `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build`, and the deviation is recorded in the task notes, as the previous tree plans did.

## Development Approach

- **Testing approach**: Regular. Each Core task lands its tests in the same task. The app tasks extend the app-layer suites named in them.
- Complete each task fully before moving to the next.
- All decisions are in `PisakaCore`, Foundation-only. The view maps returned values to rows and never re-derives the rule.
- The tree stays a **reader**: no writer gate is raised or consulted by anything new. Every write goes through the existing callbacks with a real folder url.
- Before editing a file, read its entry in `docs/architecture/`.
- `swiftlint --strict` must stay clean with no in-file disables. Keep `DirectoryNodeView`'s body under the function/type/complexity ceilings by extracting the chain label and the folder menu into private helpers rather than raising a ceiling. If a ceiling must move anyway, move it in the three pinned places with its reason.
- No brand names or references to other editors anywhere.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: The chain rule (Core, pure)

**Files:**
- Create: `Sources/PisakaCore/TreeChainRule.swift`
- Create: `Tests/PisakaCoreTests/TreeChainRuleTests.swift`

- [x] Add `TreeChainRule` with `maximumSegments = 32`, `key(for:)` (`standardizedFileURL.path`) and `rows(in:separated:isSymbolicLink:list:)`, implementing the walk exactly as "The walk, precisely" states. A failed listing during a probe is silent: it yields a plain row and never throws out of the rule.
- [x] Add `TreeRow`:
  - the three cases;
  - `id` as specified;
  - `offersShowAsOneRow` on the plain-folder case;
  - `leads(toDraftAnchor:renaming:)`, with the semantics in "Drafts after a reshape".
- [x] Add `TreeChain`:
  - its segments, ordered head first;
  - the tail's handed-down listing, `nil` for an unlisted link tail;
  - every row of the addressing table as a property;
  - the label;
  - the three menu titles;
  - the rename siblings;
  - each segment's reveal spelling under a given head reveal url.
- [x] Tests over `StubFileTree`, each case its own test:
  - a qualifying run becomes one chain;
  - the walk stops at a folder with no entries, at one with two or more entries, and at one whose single entry is a file;
  - a chain of one is a plain row;
  - the root is excluded: the rule over a root listing holding one folder returns that folder's chain, never the root;
  - a head that is a symbolic link is a plain row and is never listed;
  - a link continuation becomes the unlisted tail;
  - a run deeper than the cap ends at exactly 32 segments;
  - a separated head is a plain row with `offersShowAsOneRow == true`, and a separated folder that would not qualify reports false;
  - a separated continuation ends the chain before it;
  - an unreadable head or continuation degrades to a plain row with no throw;
  - every addressing property and title, asserted as data on one returned chain;
  - `leads(toDraftAnchor:renaming:)` for the plain, tail, under-tail and inner-segment anchors.
- [x] One test over the real `FileService` in a temporary directory: a folder holding `.git` and one subfolder qualifies, because the listing's own exclusions apply first.
- [x] Run `swift test`. It must pass before Task 2.

### Task 2: One listing per directory per revision, charged (Core)

**Files:**
- Modify: `Sources/PisakaCore/TreeChainRule.swift`
- Modify: `Sources/PisakaCore/WorkspaceModel.swift`
- Modify: `Tests/PisakaCoreTests/TreeChainRuleTests.swift`

- [x] Add `TreeListingMemo` as specified: a revision-scoped memo of successes only, keyed by `TreeChainRule.key(for:)`, with a `reset()` for a root change.
- [x] Add `WorkspaceModel.isSymbolicLink(_:)`, a pass-through to `fileService.symbolicLinkDestination(at:) != nil`. It is documented as the tree's link question and never a listing.
- [x] Charged tests, counted off `StubFileTree.listedPaths`, which is a seam separate from the cap:
  - **N subfolders, one chain.** A parent with N subfolders, one heading a run of depth D whose tail holds two files, lists exactly `N + D − 1` directories, each exactly once by set equality.
  - **The cap halts a deep run.** A 40-deep run lists exactly 32 directories, and the 33rd is never listed.
  - **The memo serves a second ask.** A parent probe followed by the tail's own load, and the same sequence repeated in the same revision, add no listing. After a revision change, each directory is listed once again.
  - **Failures are not memoized.** A failed listing is retried on the next ask.
- [x] Re-evaluation tests, re-running the rule after mutating the stub:
  - **Extend:** a lone `d` added in the tail extends the chain, same `id`, and the tail listing is `d`'s.
  - **Shorten:** a file added in a middle segment shortens the chain to it, same `id`, and its listing holds the old tail and the file.
  - **Drafts after a reshape:** after the extend, a draft anchored at the old tail's rename no longer leads anywhere.
- [x] Run `swift test`. It must pass before Task 3.

### Task 3: The tree renders rows from the rule

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`

- [x] `ProjectTreeView` owns one `TreeListingMemo`, which is cleared with the draft on a root change. `DirectoryNodeView` is driven by the row value its parent hands it:
  - segments, contents directory, handed-down listing;
  - plain folder or chain;
  - the root node is built as a single segment.
- [x] `loadChildren()` lists the **contents directory** through the memo and stores the listing for siblings and reveal. It then asks `TreeChainRule.rows` with `model.isSymbolicLink` and the memo as the listing function, and renders those rows. A folder row and a chain row go through one `DirectoryNodeView` branch, identified by `TreeRow.id`.
- [x] The node also reloads when its tail changes, and after a `separated` change, from the memo with no listing. The existing beep-unless-missing handling applies only to the node's own contents read; probe failures are silent, by the rule.
- [x] The draft checks:
  - collapse and missing-directory ask `draftIsBelow(contentsDirectory)`;
  - the reload check asks `TreeRow.leads(toDraftAnchor:renaming:)` of the returned rows instead of matching names in the listing;
  - the create-expands-the-folder `onChange` compares against the contents directory.
- [x] Tests: no new app test in this task. The Core suites from Tasks 1–2 cover the decisions, and `TreeIndentGuideLayoutTests`, `TreeRowGlyphLayoutTests`, `TreeGitStatusColourTests`, `TreeDiagnosticMarkTests` and `TreeRowBackgroundTests` must stay green, which proves that plain trees render as before.
- [x] Run `swift test`, the app-layer bundle and `swiftlint --strict`. All must pass before Task 4. (Pinned Xcode 26.3 absent: the app-layer bundle ran under the installed Xcode after `xcodegen generate`, with `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build`; 488 app tests, 7092 Core tests, 0 lint violations.)

### Task 4: Drawing a chain row and its operations

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`
- Modify: `Sources/Pisaka/ProjectTreeDraftField.swift` (only if the leading-segments prefix must be passed into the field's view)

- [x] Draw the chain label as "Drawing a chain row" states: per-segment roles, `textSecondary` separators, one middle truncation, one diagnostic dot (the head's), and the spoken value from the head's state and mark.
- [x] Split `FolderDisclosureStyle`/`FolderDisclosureRow`'s `url` into a drag source (head) and a drop destination (tail). The root still drags nothing.
- [x] Wire each menu item to the chain's own data:
  - **New File / New Folder** open a create draft for the tail.
  - **Rename "c"** opens a rename draft for the tail, drawn after the leading segments, validated against the chain's rename siblings, and committed through `onRename(tail, name)`.
  - **Delete "a/b/c"** calls `onDelete(head)`.
  - **Plain folder rows** keep `Rename` / `Delete`.
  - Each title comes from the Core value.
- [x] `isDrafted` for a chain row is "the draft renames this row's tail".
- [x] Tests:
  - `TreeGitStatusColourTests` gains one hosted render, a single window, of a two-segment chain whose segments carry different git states. It asserts each segment's name is drawn in its own role and the separator in `textSecondary`, sampled off that one bitmap.
  - `ChromeThemeSourceGatingTests` and `ZoomSourceGatingTests` stay green unchanged. No new file joins any gated set.
- [x] Run `swift test`, the app-layer bundle and `swiftlint --strict`. All must pass before Task 5. (Pinned Xcode 26.3 absent: the app-layer bundle ran under the installed Xcode after `xcodegen generate`, with `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build`; 489 app tests, 7092 Core tests, 0 lint violations. The rename prefix is passed into `TreeNameFieldView` as an optional `leading` text.)

### Task 5: Per-row unfold

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`
- Modify: `Tests/PisakaCoreTests/TreeChainRuleTests.swift`

- [x] Add `separatedFolders` and the transient "open on first appearance" set to `ProjectTreeView` as specified: handed down as values with one toggle callback, both cleared on a root change, never persisted, never pruned.
  - A chain row's menu offers `Show as Separate Folders`.
  - A plain row with `offersShowAsOneRow` offers `Show as One Row`.
  - Unfolding an expanded chain records the second segment so the new node starts expanded.
- [x] Core tests for the unfold sequence the acceptance criteria walk. Each step is a rule re-run, asserted with no new listing in the same revision:
  - `separated = {a}` turns the chain into `a` (plain, `offersShowAsOneRow`) over the chain `b/…`;
  - `{a, b}` makes `b` plain over the rest;
  - removing `a` restores `a` as a plain row whose child `b` is still separated, because the rule is local to each folder.
- [x] Run `swift test`, the app-layer bundle and `swiftlint --strict`. All must pass before Task 6. (Pinned Xcode 26.3 absent: the app-layer bundle ran under the installed Xcode after `xcodegen generate`, with `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build`; 489 app tests, 7094 Core tests, 0 lint violations. The second segment is `TreeChain.remainderHead`, and the one callback carries a `TreeSeparationChange`: separate, join, or appeared.)

### Task 6: Reveal through a chain

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`
- Modify: `Tests/PisakaAppTests/TreeRevealRequestTests.swift`

- [x] Add `expands(anyOf:)` and `isUnreachable(belowChain:listing:)` to `TreeRevealRequest`, as specified.
- [x] A chain node expands once per token when any segment's reveal spelling is an ancestor. Its children's reveal spelling continues from the tail's. Its withdrawal check uses the chain variant against the tail's listing.
- [x] Tests, in the suite's existing style:
  - the request expands a chain named by any one segment (head, inner, tail), with and without a trailing slash;
  - the step below the tail is the next ancestor or the target;
  - a request whose target sits in an inner segment is unreachable;
  - a tail listing lacking the step is unreachable;
  - a tail listing spelled under a resolved parent still reaches the step.
- [x] Run `swift test`, the app-layer bundle and `swiftlint --strict`. All must pass before Task 7. (Pinned Xcode 26.3 absent: the app-layer bundle ran under the installed Xcode after `xcodegen generate`, with `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build`; 494 app tests, 7094 Core tests, 0 lint violations. The node asks `TreeNodeShape.revealURLs(underHead:)` for its segments; an inner segment whose step is not the next segment, or is the target, is unreachable.)

### Task 7: Hosted render — one row, one indent step

**Files:**
- Create: `Tests/PisakaAppTests/TreeChainRowLayoutTests.swift`

- [ ] Build a real temporary project in which `a/b/c` holds two files. Open it, and pass a reveal request for one of those files so the chain row expands through Task 6's path. Render one window at scale 1 and one at 1.8: two renders in all, with every assertion sampled out of each bitmap.
- [ ] Assert, by counting rows off the bitmap as the indent-guide and glyph-slot suites do:
  - exactly four rows: the root, the chain, and the two files;
  - the chain row is exactly one scaled `rowHeight`;
  - each file's glyph sits exactly one scaled `treeIndentStep` right of the chain row's glyph;
  - one `hairline` guide runs beside the files on the chain row's chevron centre, with none for the inner segments.
- [ ] Run the app-layer bundle. It must pass before Task 8.

### Task 8: Verify acceptance criteria

- [ ] Run `swift test`.
- [ ] Run the app-layer bundle, recording the deviation if the pinned Xcode 26.3 is still absent: `xcodegen generate`, then `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build test`.
- [ ] Run the macOS build with `-configuration Release`, and the iOS build with `-destination 'generic/platform=iOS'`, using the same derived-data path.
- [ ] Run `swiftlint --strict` from the repository root.
- [ ] Walk the ticket's acceptance list against the tests and record where each item is covered:
  - the folding rule's cases;
  - addressing as data;
  - the charged counts and the cap;
  - extend and shorten;
  - the draft drop;
  - the unfold sequence;
  - reveal through a chain;
  - one row and one indent step;
  - per-segment colours;
  - the gating suites green.

  State the symbolic-link deviation as written in "Symbolic links in practice".

### Task 9: Update documentation

- [ ] `core-workspace.md`: a full entry for `TreeChainRule.swift`, after `TreeRevealRule.swift`, covering:
  - the qualifying rule and the walk;
  - the root, link, cap (32) and separation boundaries;
  - the silent probe failure;
  - the symbolic-link fact about today's listing;
  - the head/tail addressing table;
  - `TreeRow.id` = head;
  - the draft-lead question;
  - `TreeListingMemo`'s once-per-revision guarantee and its successes-only memo;
  - the tests that pin each of these.

  The `WorkspaceModel` entry gains the link pass-through.
- [ ] `app-window.md`, the `ProjectTreeView.swift` entry:
  - the row kinds;
  - contents = tail, identity = head;
  - the per-segment colouring and the one dot;
  - drag head / drop tail;
  - the menu titles;
  - the unfold memory and the open-on-appearance set;
  - re-evaluation (extend, shorten, drafts);
  - reveal through chains;
  - the memo's place in every load.
- [ ] `docs/FEATURES.md`: one line on chain rows and the per-row unfold. Change `README.md` only if it lists tree behaviour.
- [ ] `CLAUDE.md`: add `TreeChainRule.swift` to the `core-workspace.md` index line and nothing more. Confirm the file stays under 60,000 characters (`LintConfigurationTests`).
- [ ] Run `swift test`. The doc-pinning suites must pass.
