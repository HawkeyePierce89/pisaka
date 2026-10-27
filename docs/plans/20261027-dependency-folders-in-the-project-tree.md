# Dependency folders in the project tree, and two follow-ups from the #121 review

## Overview

One branch carrying three independent pieces of macOS project-tree work:

1. **Dependency folders.** A pure Core rule, `DependencyFolderRule`, decides whether a folder is a **dependency root**. It reads only the folder's name and its siblings' names: the name must be in a closed table, and one of that name's marker files must lie beside it. Everything below a dependency root is **inside dependencies**. Three readers ask the rule:
   - **The project tree.** It answers from listings it already holds. A dependency root row shows a `dependencies` caption in the secondary text role, also on its pinned sticky copy and on its rename draft. Its spoken value gains `Dependencies`. Inside dependencies, the test wash is suppressed.
   - **The open funnel and the definition fork.** These ask one Core question, `WorkspaceModel.opensInSourceViewer`. A file inside dependencies opens in the read-only source viewer window, never as a tab. Session restore drops such tabs silently.
   - **`DiagnosticsModel`.** At receive, it drops every published or positional report that names a document inside dependencies.
2. **One `onChange` form.** The four remaining one-argument `.onChange(of:)` sites in `ProjectTreeView.swift` move to the two-argument form. A new Core source-gating suite pins that the file has no other form.
3. **The rounding claim.** The "nearest, ties down" direction claim in `TreeStickyRule.slotTolerance` and in `core-workspace.md` either gets pinned by one hosted render at several target fractions, or gets cut down to the measured `.5`-settles-below fact.

Nothing changes on iOS. There is no setting, no toggle and no manual marking. Find in Files, the symbol index, the language servers, completion and the tree's file operations are all unchanged.

## Context

- **Core files involved:**
  - `Sources/PisakaCore/DependencyFolderRule.swift` (new)
  - `Sources/PisakaCore/TreeGitStatus.swift` (`TreeGitState.accessibilityValue`)
  - `Sources/PisakaCore/WorkspaceModel.swift` (`opensInSourceViewer`, `restoreSession`)
  - `Sources/PisakaCore/DiagnosticsModel.swift` (`init`, `receive`, `prepareForFolderChange`)
  - `Sources/PisakaCore/TreeStickyRule.swift` (`slotTolerance` doc comment only)
- **App files involved:**
  - `Sources/Pisaka/ProjectTreeView.swift`: `DirectoryNodeView`, `TreeFolderLabel`, `FolderDisclosureRow`, `FileRowView`, `TreeStickyFolderReport`, `TreeStickyRowView`, and the four `onChange` sites at lines 367, 905, 914 and 944
  - `Sources/Pisaka/PisakaApp.swift`: `openFile(url:)` (the funnel), `activateSearchMatch`, `openAndReveal`, `activateUsage`, `activateProblem`, `viewDefinitionOutsideProject`, the `DiagnosticsModel()` construction (~436), and the `onViewDefinitionOutsideProject` wiring (~943)
  - `Sources/Pisaka/CodeEditorView.swift`: the coordinator's `navigate(to:)` fork (~1772)
- **Core tests:**
  - `Tests/PisakaCoreTests/DependencyFolderRuleTests.swift` (new)
  - `Tests/PisakaCoreTests/ProjectTreeSourceGatingTests.swift` (new)
  - `TreeGitStatusTests.swift`
  - `WorkspaceModelTests.swift`
  - `DiagnosticsModelTests.swift`
  - `ChromeThemeSourceGatingTests.swift` (must stay green unchanged, or with its inventory kept true)
- **App tests:**
  - `Tests/PisakaAppTests/TreeDependencyCaptionTests.swift` (new)
  - `Tests/PisakaAppTests/TreeStickyScrollRoundingTests.swift` (gains the direction measurement)
- **Docs:**
  - `docs/architecture/core-workspace.md`: the new rule's entry, the `WorkspaceModel.swift` entry, and the `TreeStickyRule.swift` Tolerance paragraph
  - `docs/architecture/core-git-models.md`: the `TreeGitStatus.swift` entry
  - `docs/architecture/core-lsp.md`: D3, and the `DiagnosticsModel.swift` entry
  - `docs/architecture/app-window.md`: the project tree's entry
  - `docs/architecture/app-shell.md`: the `PisakaApp.swift` entry, for the funnel
  - `docs/architecture/app-editor.md`: the `CodeEditorView.swift` entry, for the fork
  - `docs/FEATURES.md`, `README.md`
  - `CLAUDE.md`: the index name and the gating-suite list
- **Patterns to follow:**
  - A pure Core rule read by the tree: `TreeTestRule`, `TreeChainRule`.
  - Components carried down the recursion: `relativeComponents`, built from listing names.
  - A seam injected into a Core model with a default: `DiagnosticsModel.init(fileExists:)`.
  - An off-the-model read path: D3's `viewDefinitionOutsideProject` and `SourceViewerWindowController.open(fileURL:range:settings:)`.
  - Source-gating suites read through `RepositorySources.stripped`.
  - Hosted-render bitmap tests through `HostedRender`: one render per appearance, no loops of windows.
- **Dependencies:** none new.

## Development Approach

- **Testing approach:** Regular (code first, then tests), with one exception. In Task 6 the gating pin is written first and seen red against the unmigrated file.
- Complete each task fully before moving to the next. A task whose change trips a source-gating suite updates that suite, and the documents it pins, **in the same task**.
- Read the `docs/architecture/` entry of every file before touching it, and update that entry with the change.
- Every `xcodebuild` uses the pinned Xcode and the single derived-data path:
  ```sh
  DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build test
  ```
  The macOS `build` (`-configuration Release`, as in CI) and the iOS build (`-destination 'generic/platform=iOS'`, `CODE_SIGNING_ALLOWED=NO`) use the same `DEVELOPER_DIR` and `-derivedDataPath`. If the pinned Xcode is not installed on the machine, run under the installed one, record that in the execution notes, and note that a run under the pin is owed before the merge.
- No brand names and no references to other editors anywhere: code, comments, docs or commits.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Execution notes (decisions already taken; record any further conflict found and its resolution here)

1. **The chain rule is "any segment", not "the tail".**
   - `TreeChainRule` folds a folder into a chain only when its listing is exactly one folder. A dependency root always has a marker file beside it, so it can only ever be a chain's **head**.
   - The ticket's tail rule could therefore never fire. Under it, a `node_modules` holding one package (drawn as the chain `node_modules/lodash`) would be uncaptioned.
   - Resolution, as the user decided: a chain row is a dependency root row when **any** of its segments is one. In practice that is the head. The row stands for its head, the way its git colour does, and everything below the chain inherits. There is no separate tail rule, and `TreeChainRule` is untouched.
   - The tree supplies each segment's siblings as follows:
     - the head's siblings are the parent's listing names;
     - a later segment's siblings are just `[its own name]`, because a folded segment is its parent's sole entry. A comment cites `TreeChainRule` for this.
2. **Where the funnel's and the session's listings come from.**
   - `WorkspaceModel` already holds the existing file service (`fileService.contentsOfDirectory(at:)`) and `projectRoot`. The open-routing question and the restore drop are therefore asked of the model itself, through that service. The funnel needs no extra closure.
   - `DiagnosticsModel` holds no file service. It gains one injected seam, `listNames: (URL) -> [String]?`, defaulting to `{ _ in nil }` (no listing, so nothing is a root). The app passes a closure over its `FileService`'s `contentsOfDirectory(at:)` names.
   - **No memoization.** Every ask costs one listing per table-named ancestor component of the asked path, and stops at the first root found. A path with no table-named component costs no listing at all. That bound is stated in the rule's doc entry.
3. **One Core question for both routing sites.** `WorkspaceModel.opensInSourceViewer(_ url: URL, isOutsideProjectRoot: Bool = false) -> Bool` answers in this order:
   - `isOutsideProjectRoot` → `true`. This is D3, unchanged, and it holds whether or not a tab holds the file.
   - A tab already holds the file (canonical dedup) → `false`. A pre-existing tab is left alone until it is closed.
   - A recognized database file with viewer tabs enabled → `false`.
   - Otherwise `DependencyFolderRule.isInsideDependencies(fileURL:projectRoot:listNames:)`.

   How the two sites ask it:
   - **The funnel** asks with the default `false`. A file outside the root, reached through the Open panel or a recent file, keeps opening as a tab, exactly as today. The outside-root reason belongs to definition candidates (and to `activateUsage`'s existing fork) alone.
   - **The definition fork** asks with `candidate.isOutsideProjectRoot`, through a closure the app hands the coordinator.
4. **The funnel's range.** `openFile(url:)` becomes `openFile(url:viewerRange:)` and returns whether a tab now holds the file. `viewerRange` defaults to `NSRange(location: 0, length: 0)`, the file's start. The callers pass:
   - `activateSearchMatch` (search hits and in-root definitions): its range;
   - `activateUsage`: `row.range`;
   - `activateProblem`: the start. After the diagnostics drop, a Problems row can no longer name a dependency file;
   - the tree, the Open panel and `newFile`: the start.

   When the viewer cannot read the file, the app beeps, the same as `viewDefinitionOutsideProject`. The two direct `model.open` sites, the LeetCode solution and the Local History restore, are left alone: neither can name a file inside dependencies in practice, and both are writes.
5. **A file created by the tree inside dependencies.** The create itself is unchanged, as the ticket requires. The follow-up open goes through the funnel, so the new file shows in the viewer window.
6. **Session restore needs no platform switch.** `restoreSession` skips a titled record whose path is inside dependencies under `projectRoot`, silently, like a missing file. Only the macOS app calls `restoreSession` (iOS has no session store), so iOS is untouched without a switch. The app sets `projectRoot` before `replaceSession`/`restoreSession`, so the root is known when the skip is asked.
7. **The test-wash suppression lives in Core.** `DependencyFolderRule.State` (`.outside`, `.root`, `.inside`) has `showsTestWash(isTestRow:)`, which is `isTestRow && self == .outside`.
   - The tree passes the suppressed answer wherever it passed `isTestRow` before. So the three gated `rowBackground` bodies pinned by `ChromeThemeSourceGatingTests` keep their exact text, and so does the report's `isTestRow` field.
   - `TreeTestRule` is untouched.
8. **The caption needs no new role.** It is `Text("dependencies")` with `.foregroundStyle(theme.color(.textSecondary))`, a form the tree already uses at three sites. It inherits the label's `.font(metrics.scaledFont(.body))` and sits inside `TreeFolderLabel`'s existing `HStack(spacing: metrics.scaled(4))`, after `name()`. No role, no palette value and no gated file is added. Record here any gating rule the caption trips, and its resolution.
9. **The `onChange` pin is a new Core gating suite.** The comment- and literal-stripping helper (`RepositorySources`) lives only in the Core test target, so the pin goes in a new `ProjectTreeSourceGatingTests`, not in the app bundle. `CLAUDE.md`'s list of repository-verifying suites gains its name.
10. **Part 3 reaches off-grid fractions through the interface scale.**
    - The tree sizes rows with `metrics.scaled(ChromeGeometry.rowHeight)`, and `ChromeGeometry.rowHeight` is `24` points at interface scale 1. At scale 1 rows therefore lie on a whole-point grid, and reveal targets end in `.0` or `.5` only through the centring arithmetic.
    - The direction measurement therefore runs at interface scale **1.1** (row height `26.4`). Different rows' centres there fall at different tenths, while the window stays one window at a whole-point height.
    - Record here the fractions observed, the settled offsets and the backing scale.
11. **The pinned Xcode is not installed on this machine** (only Xcode 27.1 at `/Applications/Xcode.app`). Task 2's compile check of the two tree call sites ran under 27.1 (`build`, Debug, macOS, single derived-data path): green. Every later `xcodebuild` in this plan runs under 27.1 too, and a run of the app-layer bundle and both builds under the pin (Xcode 26.3) is owed before the merge.

12. **Task 3 raised the `PisakaApp.swift` lint ceilings.** The funnel, the reveal paths' stop on its answer and the fork's closure measured four lines over (`file_length` 1982 → **1986**, `type_body_length` 1975 → **1979**), after compacting the new code. Both were raised to the measured numbers with the reason appended in `.swiftlint.yml`, `LintConfigurationTests.documentedRootThresholds` and `style-lint.md`, per that document's procedure.
13. **Intermittent hosted-render crashes in the app bundle, not caused by Task 3.** Two of four full-bundle runs under Xcode 27.1 lost the test process once to an AppKit layout exception in a test this branch does not touch (`TreeStickyStackLayoutTests.testAPinnedFolderDrawsAsItsRealRowUnderTheHeader`, then `GitChangeControllerRepositoryTests.testALongHunksPopoverDrawsTheLimitAndCountsTheRest`). Each suite passed 3/3 in isolation, and the final full run passed 507/507.
14. **Task 5 shifted the four `onChange` sites Task 6 names.** The state carried down the recursion and its comments moved them from lines 367, 905, 914 and 944 to **371, 937, 946 and 976** (the `projectRoot`, `isExpanded`, `draft` and `treeRevision` handlers). `ChromeThemeSourceGatingTests` passed untouched: the caption adds no role, palette value or gated rule, and the three `rowBackground` bodies keep their text because the suppressed answer travels in the existing `isTestRow` fields. `TreeDependencyCaptionTests` was checked against both mutations (caption forced on everywhere: the unmarked row fails; forced off: the marked row fails).
15. **Task 7: note 10's premise did not hold, so the direction test runs at interface scale 0.9.**
    - **What was measured.** `InterfaceMetrics.pt` rounds every scaled metric to the half-point grid, so at interface scale 1.1 a row is `26.5` points, not `26.4`. Each `tK` node measured `53.0` high (minY `1091.25`, `1144.25`, …), and every reveal target landed on a whole point (`981.0`, `1034.0`, `1087.0`, …), each settling exactly on itself. No fraction inside `(0, 0.5)` or `(0.5, 1)` was reachable there, so the non-vacuity precondition failed.
    - **Resolution.** At interface scale 0.9 a row is `21.5`, so a row's centre lies on a quarter point. The odd `tK` folders also hold a file `w` (sorted above `x`), which alternates the targets between the two quarters. Same shape otherwise: one window, resized once to a 300-point viewport, forty padding folders and forty padding files.
    - **Observed** at backing scale 1 (read from the window), identical across the probe runs and the five runs: `767.25` → `767`, `831.75` → `832`, `874.75` → `875`, `939.25` → `939`, `982.25` → `982`, `1046.75` → `1047`. Fractions `.25` and `.75` round to the nearest point. Together with the existing test's `.5` tie (`1165.5` → `1165.0`), this is the deterministic outcome matching the claim, so the doc sentences stay and the test is named beside them. The parenthetical "(any other interface scale)" in `core-workspace.md` was dropped as inaccurate, since other interface scales reach quarter points at most.
    - **A second finding.** A raw scroll to `0` right after a settled reveal is sometimes undone: SwiftUI animates the clip back to the previous reveal's offset over about eight turns. The test therefore waits for the raw scroll causally: held still for ten turns, re-scrolled if it came to rest anywhere but `0`, and `XCTFail` after three seconds.

16. **Task 8 verification, all under Xcode 27.1 (the pin is still not installed, note 11).** `swift test` 7215/7215, including `DependencyFolderRuleTests`, `WorkspaceModelTests`, `DiagnosticsModelTests`, `TreeGitStatusTests`, `ProjectTreeSourceGatingTests`, `ChromeThemeSourceGatingTests` and `LintConfigurationTests`. `swiftlint --strict` 0.65.1 clean; `xcodegen generate` left the tree clean. App bundle 509/509, including `TreeDependencyCaptionTests` and `TreeStickyScrollRoundingTests`. macOS Release build and iOS `generic/platform=iOS` build (`CODE_SIGNING_ALLOWED=NO`) both succeeded. `CLAUDE.md` is 56,914 characters. Every public `DependencyFolderRule` member, `opensInSourceViewer`, the restore drop and the `listNames` seam has direct tests. The brand grep over the branch diff found none (its only hits were "-zed" word endings such as "resized"). The app bundle and both builds still owe one run under Xcode 26.3 before the merge.

## Implementation Steps

### Task 1: Core — the dependency-folder rule

**Files:**
- Create: `Sources/PisakaCore/DependencyFolderRule.swift`
- Create: `Tests/PisakaCoreTests/DependencyFolderRuleTests.swift`
- Modify: `docs/architecture/core-workspace.md`, `CLAUDE.md` (index)

- [x] Create `DependencyFolderRule`, a pure, Foundation-only enum beside `TreeTestRule`.
  - **The table.** `markers: [String: Set<String>]`, public, compared exactly:
    - `node_modules` → `package.json`
    - `vendor` → `composer.json`, `go.mod`, `Gemfile`
    - `.venv` and `venv` → `pyproject.toml`, `requirements.txt`, `setup.py`, `setup.cfg`, `Pipfile`
    - `Pods` → `Podfile`
    - `.build` → `Package.swift`
  - `isDependencyRoot(name:siblingNames:)`: the name is in the table, and at least one of its markers is among the sibling names.
  - `isDependencyRootRow(segmentNames:siblingNames: (Int) -> [String])`: any segment is a root, asked about its own siblings (note 1). Empty segments → `false`.
  - **`State`.** A public enum with cases `.outside`, `.root` and `.inside`.
    - `static func node(segmentNames:siblingNames:parent:)` answers `.inside` when the parent is `.root` or `.inside`. Otherwise it answers `.root` when the row is a root row, and `.outside` when it is not.
    - `static func file(inParent:)` answers `.inside` or `.outside`. A file is never a root.
    - `showsTestWash(isTestRow:)` and `showsCaption` (`self == .root`) complete the type.
  - `isInsideDependencies(components:siblingNames: (Int) -> [String]?)`. `components` is root-relative, and `[]` is the root.
    - It walks the ancestors only (`components.dropLast()`). The root itself, `[]`, is never asked about.
    - `siblingNames(i)` is called **only** when `components[i]` is a table name. It names the entries of the directory that holds component `i`.
    - A `nil` listing means not a root. The walk returns at the first root.
  - `isInsideDependencies(fileURL:projectRoot:listNames: (URL) -> [String]?)`.
    - It computes the root-relative components canonically (`CanonicalPath.canonical` + `relativeComponents(of:under:)`), as the LSP provider does for outside-root.
    - A `nil` root, or a file outside the root, answers `false`.
    - Component `i`'s listing URL is the canonical root plus `components[0..<i]`.
  - **The doc comment** states:
    - the table and the reason for markers (a hand-written `vendor` beside no manifest is ordinary source);
    - the root exclusion and the inheritance;
    - the chain's "any segment" rule;
    - the cost bound;
    - that build-output folders are deliberately not in the table.
- [x] Write `DependencyFolderRuleTests` covering:
  - **the table by set equality:** keys, and each key's marker set;
  - **every key with each of its markers** → root;
  - **the marker requirement:** each table name beside no marker → not a root, and `vendor` beside only `package.json` → not a root;
  - **exact comparison:** `Node_Modules` and `VENDOR` → not roots;
  - **the root exclusion:** `isInsideDependencies(components: [])` and a root-level file → `false`, whatever the listing says;
  - **inheritance:** `node_modules/x/y/z.js`, given a root listing containing `package.json`, → inside;
  - **`State`:** `.node` below `.root` and below `.inside` → `.inside`, and `.file(inParent:)` for all three states;
  - **the chain rule:** a chain headed by a root → `.root`, and a chain whose *later* segment is the root, given a sibling listing holding a marker → `.root`. This pins "any segment". A chain under a `.root` parent → `.inside`;
  - **the test-wash suppression:** `showsTestWash` is `true` only for `.outside` with a test row; `node_modules/x/test` reads `.inside` and so washes nothing;
  - **the listing-cost bound,** with a counting closure:
    - `src/a/b.swift` asks for 0 listings;
    - `node_modules/x/y.js` asks exactly once, for the root's entries;
    - `a/vendor/b/vendor/c.go`, with no marker anywhere, asks exactly twice;
    - a path whose first table-named ancestor is a root asks once and stops;
  - **the URL form:** a file under a symlinked root spelling → inside; outside the root → `false` with no listing asked.
- [x] Add the `DependencyFolderRule.swift` entry to `core-workspace.md`. It states:
  - the contract, the table, the cost bound and the chain resolution;
  - its three readers;
  - one sentence that Find in Files and the symbol index are deliberately untouched (both walk `ProjectFileWalk`, which honours `.gitignore`, and a committed `vendor` tree is still worth searching), so no second exclusion is added later.

  Add `DependencyFolderRule.swift` to `CLAUDE.md`'s core-workspace index line.
- [x] Run `swift test`; it must pass before Task 2.

### Task 2: Core — the spoken `Dependencies` word

**Files:**
- Modify: `Sources/PisakaCore/TreeGitStatus.swift`
- Modify: `Tests/PisakaCoreTests/TreeGitStatusTests.swift`
- Modify: `Sources/Pisaka/ProjectTreeView.swift` (the call sites pass `isDependencyRoot: false` until Task 5)
- Modify: `docs/architecture/core-git-models.md`

- [x] Give `TreeGitState.accessibilityValue` a required `isDependencyRoot: Bool` parameter.
  - A folder's words are `expanded`/`collapsed`, then `Dependencies`, then `Test`, then the git word, then the diagnostic words.
  - A file's words are unchanged: a file is never a root, and the parameter is ignored for `.file`, which the doc comment says.
  - Update the doc comment.
- [x] Update every call site to pass `false` for now: both tree rows, plus any iOS caller found by the compiler.
- [x] Tests in `TreeGitStatusTests`:
  - `Dependencies` alone on an expanded folder and on a collapsed one;
  - with git, with diagnostics, and with `Test`, which pins the position: `"expanded, Dependencies, Test, Modified, …"`;
  - a file passed `true` is unchanged;
  - existing values unchanged with `false`.
- [x] Update the `TreeGitStatus.swift` entry in `core-git-models.md`.
- [x] Run `swift test`; it must pass before Task 3.

### Task 3: Read-only routing — the Core answer, the funnel, the definition fork, session restore

**Files:**
- Modify: `Sources/PisakaCore/WorkspaceModel.swift`
- Modify: `Tests/PisakaCoreTests/WorkspaceModelTests.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`, `Sources/Pisaka/CodeEditorView.swift`
- Modify: `docs/architecture/core-workspace.md` (the `WorkspaceModel.swift` entry), `docs/architecture/core-lsp.md` (D3), `docs/architecture/app-shell.md`, `docs/architecture/app-editor.md`

- [x] Add `WorkspaceModel.opensInSourceViewer(_:isOutsideProjectRoot:)`, with the order in note 3. Its listings go through `fileService.contentsOfDirectory(at:)` names, with a failure read as `nil`. The doc comment states the order and why each branch is where it is.
- [x] In `restoreSession`, skip a titled record whose path is inside dependencies under `projectRoot`, before `open(url:)` is called. The skip is silent and follows the same selection rules as a missing file. Update its doc comment's list of skipped records.
- [x] App funnel (note 4).
  - `openFile(url:viewerRange:)`: when `model.opensInSourceViewer(url)` is true, it calls `sourceViewers.open(fileURL:range:settings:)` and beeps on `false`. Otherwise it keeps `model.open` as today.
  - `activateSearchMatch` and `openAndReveal` stop when no tab holds the file, as they already do.
  - `activateUsage` passes `row.range` through `openAndReveal`'s new `viewerRange:` parameter.
  - The doc comments name every caller and the new branch.
- [x] Definition fork. The coordinator's `navigate(to:)` asks a new closure, `opensInSourceViewer: (DefinitionCandidate) -> Bool`, instead of reading `candidate.isOutsideProjectRoot` alone. The app wires it to `model.opensInSourceViewer(candidate.fileURL, isOutsideProjectRoot: candidate.isOutsideProjectRoot)`. A `true` answer goes to `viewDefinitionOutsideProject`, and a `false` one to `onGoToDefinition`. Update the doc comment on the fork.
- [x] Tests in `WorkspaceModelTests`, using the existing stub file service or a stub listing:
  - outside-root → `true`, including when a tab holds the file;
  - inside dependencies, no tab → `true`;
  - inside dependencies with a tab already open on the file → `false`;
  - a `.sqlite` inside dependencies with viewer tabs enabled → `false`;
  - an ordinary in-root file → `false`, with zero listings asked;
  - `vendor/x.go` beside no marker → `false`;
  - no project root → `false`;
  - `restoreSession`: a session holding an inside-dependencies tab, an ordinary tab and an untitled tab restores the latter two. `selectedIndex` naming the dropped record falls back as for a missing file. An inside-dependencies tab with no root set is restored.
- [x] Docs:
  - `WorkspaceModel.swift` entry in `core-workspace.md`: the routing question and the restore drop.
  - `core-lsp.md` D3: the second reason a target opens in the viewer window, asked through the same Core question.
  - `app-shell.md`: the funnel's new branch, its range, and the created-file case (note 5).
  - `app-editor.md`: the fork's closure.
- [x] Run `swift test` and the app-layer bundle under the pinned Xcode; both must pass before Task 4.

### Task 4: Diagnostics — drop reports about documents inside dependencies

**Files:**
- Modify: `Sources/PisakaCore/DiagnosticsModel.swift`
- Modify: `Tests/PisakaCoreTests/DiagnosticsModelTests.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift` (the construction at ~436)
- Modify: `docs/architecture/core-lsp.md` (the `DiagnosticsModel.swift` entry)

- [x] `DiagnosticsModel.init` gains `listNames: @escaping (URL) -> [String]? = { _ in nil }` beside `fileExists`.
- [x] `prepareForFolderChange(root:)` records the root URL.
- [x] `receive` drops `.published` and `.positional` events whose URL is inside dependencies under that root (`DependencyFolderRule.isInsideDependencies(fileURL:projectRoot:listNames:)`).
  - The drop happens first, so a dropped published report is **not held**. It never reaches the store, the Problems panel, the tree or an editor.
  - `.cleared` events are untouched.
  - The doc comment states the drop, the reason (the positional lane, where a server reports on declaration files no tab holds) and the cost bound.
- [x] The app constructs the model with `listNames: { try? fileService.contentsOfDirectory(at: $0).map(\.name) }` over the app's existing file service.
- [x] Tests in `DiagnosticsModelTests`:
  - a positional report for `node_modules/x/index.d.ts`, with `package.json` at the root → dropped, and the store is empty;
  - a published report for the same path, with a sync record present → dropped, not held, and a later matching sync admits nothing;
  - `vendor/a.go` beside no marker → lands;
  - an ordinary report → lands, with zero listings asked;
  - no root prepared → lands;
  - existing tests stay green with the default seam.
- [x] Update the `DiagnosticsModel.swift` entry in `core-lsp.md`, and the D46 paragraph where it lists what reaches the Problems panel and the tree.
- [x] Run `swift test`; it must pass before Task 5.

### Task 5: App — the tree shows dependency roots

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`
- Create: `Tests/PisakaAppTests/TreeDependencyCaptionTests.swift`
- Modify: `docs/architecture/app-window.md`

- [x] Carry the state down the recursion.
  - `DirectoryNodeView` gains `dependencyState: DependencyFolderRule.State`. The root passes `.outside` and never evaluates itself.
  - A child node gets `.node(segmentNames: childShape.segmentNames, siblingNames: { $0 == 0 ? currentChildrenNames : [childShape.segmentNames[$0]] }, parent: dependencyState)`, with a comment citing note 1.
  - A file row gets `.file(inParent: dependencyState)`.
  - No I/O: the names come from the listing the node already holds.
- [x] The test wash: every place that passed `TreeTestRule.isTestRow(...)` now passes `state.showsTestWash(isTestRow:)` of it (note 7). The node, the file rows and the sticky report all read the suppressed answer.
- [x] The caption.
  - `TreeFolderLabel` gains `showsCaption: Bool`. When true, it draws `Text("dependencies")` in `theme.color(.textSecondary)` after `name()`. The label's font, line limit and spacing are inherited (note 8). The caption keeps its natural width (`.fixedSize()` / layout priority), so the name truncates first.
  - The real folder row passes `dependencyState.showsCaption`, which stays true while its rename draft replaces the name.
  - The create draft row is not a `TreeFolderLabel` and never shows a caption.
- [x] The pinned copy. `TreeStickyFolderReport` gains `isDependencyRoot` (included in its `==`), set from the node's own state. `TreeStickyRowView` passes it to `TreeFolderLabel`.
- [x] Spoken value. The folder row passes `isDependencyRoot: dependencyState.showsCaption`. File rows pass `false`. The draft row's value stays `""`.
- [x] Confirm that `ChromeThemeSourceGatingTests` passes untouched: no role and no palette value added, and the three `rowBackground` bodies unchanged. If a rule needs its inventory updated, update it and the documents it restates in this task, and record that in the execution notes.
- [x] Create `TreeDependencyCaptionTests` (app bundle, `HostedRender`, interface scale 1, one render per appearance, two windows in total).
  - **Project:** a root holding `package.json` and `node_modules/` with two packages (so it does not chain), plus `other/` (expanded) holding `node_modules/` with two packages and no marker.
  - **Assertions in dark and light:**
    - the root-level `node_modules` row has text-coloured pixels in a band to the right of its name, where the caption is drawn;
    - the same band, offset by one indent step on `other/node_modules` (same name, no marker), holds only the row's background;
    - the caption pixels differ from the row background in each appearance.
- [x] Update the project tree's entry in `app-window.md`:
  - the caption and its role and font;
  - the boundary-versus-inheritance split (no caption and no wash inside);
  - the pinned copy;
  - the drafts;
  - the spoken word and its position;
  - the state carried down the recursion;
  - the chain rule.
- [x] Run `swift test`, `swiftlint --strict`, `xcodegen generate` and the app-layer bundle under the pinned Xcode; all must pass before Task 6.

### Task 6: The remaining one-argument `onChange` sites, and their pin

**Files:**
- Create: `Tests/PisakaCoreTests/ProjectTreeSourceGatingTests.swift`
- Modify: `Sources/Pisaka/ProjectTreeView.swift`
- Modify: `CLAUDE.md` (the suite list), `docs/architecture/app-window.md`

- [x] Write `ProjectTreeSourceGatingTests` first.
  - Over `RepositorySources.stripped` text of `ProjectTreeView.swift`, it finds every `.onChange(of:`, balances parentheses to the argument list's close, and expects `{`.
  - It asserts that the closure's parameter list, up to `in`, has exactly two comma-separated names. A missing `in`, which is the zero-argument form, fails too.
  - It asserts at least one site was found, so the check cannot pass vacuously.
  - The doc comment is its inventory, and says why stripped text is read (the file's comments quote the old form).
- [x] Run it and see it fail on lines 367, 905, 914 and 944.
- [x] Move the four sites to `{ _, newValue in … }` / `{ _, _ in … }`. Each gets the reasoning comment the moved sites carry: the one-argument form's action reads the previous update's captured values. The `treeRevision` handler reads a captured `shape`; the others are moved so the file has one form.
- [x] Add `ProjectTreeSourceGatingTests` to `CLAUDE.md`'s list of repository-verifying suites, and name the pin in the tree's entry in `app-window.md`.
- [x] Run `swift test` and the app-layer bundle (tree suites unchanged); both must pass before Task 7.

### Task 7: Pin the scroll-rounding direction, or cut the claim

**Files:**
- Modify: `Tests/PisakaAppTests/TreeStickyScrollRoundingTests.swift`
- Modify: `Sources/PisakaCore/TreeStickyRule.swift` (doc comment only)
- Modify: `docs/architecture/core-workspace.md` (the Tolerance paragraph), `docs/architecture/app-window.md` (the sticky entry's Tests)

- [x] Add one test method: one `HostedRender` window at interface scale 1.1 (rows `26.4` points high, note 10), resized at most once, with no loop of windows. It reuses the suite's reveal host types.
  - **Project:** padding folders, then folders `t0`…`t5`, each holding one file, then padding files, so that each file's centred offset lies inside the scrollable range.
  - **Per target:** reveal `tK/x` through `TreeRevealRequest` with fresh tokens.
    - Measure `tK`'s report in content space, and compute the target with the suite's existing reveal arithmetic (`TreeStickyRule.revealAnchorY`).
    - Raw-scroll to `0`, then reveal again.
    - Wait causally until the clip view's `bounds.origin.y` has left `0` and held still across consecutive turns. On timeout, `XCTFail`; there are no sleeps.
  - **Non-vacuity, before asserting the direction:** at least one target's fraction lies strictly inside `(0, 0.5)` and at least one strictly inside `(0.5, 1)`. Fractions are compared with a `1e-6` slack.
  - **Assertions at backing scale 1** (read from `render.window.backingScaleFactor`): each settled offset is a whole point and equals the target rounded to the nearest whole point, ties down. At any other scale, assert only `|settled − target| ≤ TreeStickyRule.slotTolerance`.
- [x] Run the new test five times, plus once in the full bundle.
  - **Deterministic and matching the claim:** keep it, keep the doc sentences, and name the test beside them in both places.
  - **Deterministic but a different rule** (for example, floor): make the test assert the measured rule, and correct both sentences to match it.
  - **Not deterministic in the headless host:** remove the new method, and cut both the `slotTolerance` doc comment and the Tolerance paragraph down to the measured fact: `1165.5` settled at `1165.0` at backing scale 1, pinned by the existing test. The ties-down and `.6`–`.9` sentences are deleted.

  Record the outcome, the fractions, the settled offsets and the backing scale in the execution notes.
- [x] Update the sticky entry's **Tests** in `app-window.md` to match.
- [x] Run `swift test` and the app-layer bundle; both must pass before Task 8.

### Task 8: Verify acceptance criteria

- [x] `swift test` green, including `DependencyFolderRuleTests`, the spoken positions, the routing answer, the restore drop, the diagnostics drop for both lanes, `ProjectTreeSourceGatingTests` and `ChromeThemeSourceGatingTests`.
- [x] `swiftlint --strict` clean at the pinned version (0.65.1); `xcodegen generate` leaves the tree clean.
- [x] App-layer bundle green (under Xcode 27.1; the pinned 26.3 run is owed, note 16) with the single derived-data path, including `TreeDependencyCaptionTests` and the rounding outcome from Task 7.
- [x] macOS build (`-configuration Release`) and iOS build (`generic/platform=iOS`) green (under Xcode 27.1; the pinned 26.3 run is owed, note 16).
- [x] Coverage: every new Core function has direct tests.
- [x] `CLAUDE.md` under 60,000 characters (`LintConfigurationTests`).
- [x] Grep the branch diff for brand names and references to other editors: none.

### Task 9: Update documentation

- [ ] `docs/FEATURES.md`: under the project tree, describe the `dependencies` caption: the table, the marker requirement and the boundary-only mark. Say that files inside open in the read-only viewer window, that they are not diagnosed, that a database file still opens as its viewer tab, and that search and the symbol index still include them.
- [ ] `README.md`: one line in the project tree's bullet for the caption and the read-only opening.
- [ ] `CLAUDE.md`: confirm the index carries `DependencyFolderRule.swift` and the suite list carries `ProjectTreeSourceGatingTests`. No other growth.
- [ ] Final consistency pass over `core-workspace.md`, `core-git-models.md`, `core-lsp.md`, `app-window.md`, `app-shell.md` and `app-editor.md` against the code as merged. Record any drift fixed in the execution notes.
