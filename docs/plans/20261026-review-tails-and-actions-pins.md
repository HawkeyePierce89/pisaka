# Review tails of the last five merges, and the GitHub Actions pins

## Overview

This plan closes the debt recorded by the last five acceptance reviews and bumps the CI pins. It adds no feature. Only four Core behaviours change:

1. The tree-diagnostics probe count becomes a real count.
2. Folder tombstones in `DiagnosticsModel` get lifted, and covered ones are no longer added.
3. The git lookup (`TreeGitStatus`) is built off the main actor.
4. `offersShowAsOneRow` gets an honest definition.

Everything else is wording, test-suite hygiene, the `build-ios` cache and guard, and the pins:

- `actions/checkout` v4.3.1 → v7.0.1
- `actions/cache` v4.3.0 → v6.1.0
- XcodeGen 2.45.4 → 2.46.0

`ci.yml` and `ReleaseWorkflowTests` are touched by both parts, so this one branch edits them once.

Decisions made here, so nothing is left open at run time:

- **1.2: make the count real; do not remove the seam.** The cost claim ("one key read, a descent of a handful of trie levels") is worth pinning. Two regressions would pass every equality test and compile cleanly: a lookup that scans the table, and one that reads once per ancestor. A real count catches both. The count comes from the nodes the read descent visits. The bound comes from `MarkTrie.depth`, a separate structural walk that already exists. So the work is counted somewhere other than the bound it is checked against, which is what CLAUDE.md requires.
- **1.3:** a new tombstone that an existing one already covers is not added. A new folder tombstone does **not** prune finer tombstones already recorded under it. Lifting the folder later must not also lift a file tombstone that may still be gone.
- **1.4: the build moves into one `nonisolated static` async step in `LocalChangesModel`.** That step awaits the service's snapshot and builds the lookup in the same non-isolated context, then returns both. In the Swift 5 language mode the package uses, this runs on the generic executor. `GitServicing` and its three implementations stay untouched.
- **1.5 delete confirmation:** Core's `TreeChain` gains the one name both the menu title and the sheet use. The tree's delete callback carries an optional display name. It is `nil` for files and plain folders, so `deleteItem` falls back to `url.lastPathComponent` exactly as today.
- **1.6 `strippingComments` doc:** the comment names no list of readers. It says it is "the literal-keeping reading every suite whose rule is about a spelled literal uses" and points at `ChromeThemeSourceGatingTests.testTheHeaderNamesEveryLiteralKeepingReading`. A hand-written list of the six suites would be a second, unpinned copy of a set.
- **Pin verification:** the tag is the authority. If a tag's commit differs from the SHA in the ticket, the plan pins the tag's commit and records the difference in Notes. The same rule applies to the XcodeGen digest: the published asset's digest, recomputed locally, is what gets pinned.
- **XcodeGen diff, both branches spelled out (Task 7):**
  - Byte-identical project, or only the target-order change: keep the bump.
  - Any other diff: build both generated projects and compare the products' embedded frameworks and linked libraries. If they are equal, keep the bump and explain the diff. If they differ, revert XcodeGen to 2.45.4 everywhere and record a follow-up; the action bumps proceed alone.
- **Acceptance grep (criterion 3)** excludes `docs/plans/completed/`. Those files are historical records, and the ticket allows exactly one phrase there to change.
- **Pinned Xcode 26.3 is not installed here.** The installed Xcode (27.1) is used for the app-layer gates. This deviation is recorded in Notes. The `Package.resolved` rewrite guard is observed on CI. A local resolution that rewrites `Package.resolved` is never committed.

## Context

- Files involved:
  - Core:
    - `Sources/PisakaCore/TreeDiagnostics.swift`: `MarkTrie` lookup, `resolve(_:)`, and doc comments.
    - `Sources/PisakaCore/DiagnosticsModel.swift`: `removedPaths`, `noteItemRemoved(at:)`, `isRemovedAndGone(_:)`.
    - `Sources/PisakaCore/LocalChangesModel.swift`: `refreshImpl`, the comment on `projectPrefix(folder:repositoryRoot:)`.
    - `Sources/PisakaCore/ChangedFile.swift`: `Sendable` on `GitStatusSnapshot`, `ChangedFile` and `FileStatus`.
    - `Sources/PisakaCore/TreeChainRule.swift`: the separated-head answer, the `folder` case doc, and `TreeChain`'s delete naming.
  - App:
    - `Sources/Pisaka/ProjectTreeView.swift`: the `onChange(of: separated)` handler, the shape's delete name, and the `onDelete` signature.
    - `Sources/Pisaka/ContentView.swift`: `onDelete` pass-through.
    - `Sources/Pisaka/PisakaApp.swift`: `deleteItem(at:)`.
  - Tests:
    - `TreeDiagnosticsTests`, `DiagnosticsModelTests`, `LocalChangesModelTests`, `TreeChainRuleTests`
    - `LSPSourceGatingTests` (`containsToken`), `GitHubSourceGatingTests` (doc comment), `SparkleSourceGatingTests` (doc and message)
    - `ReleaseWorkflowTests` (`testCIRefusesARewrittenPackageResolved`, its doc comment, and a new rule for `uses:` pins)
    - `DependencyPinTests` (type doc comment), `Support/YAMLLineMatching.swift` (the `# v4.3.1` example in a comment)
  - Workflows: `.github/workflows/ci.yml` and `.github/workflows/release.yml`.
  - Docs:
    - `docs/FEATURES.md`
    - `docs/architecture/core-lsp.md`: D46 table, the limits paragraph, the tombstone paragraph and the `TreeDiagnostics` cost bound.
    - `docs/architecture/core-git-models.md`: the `TreeGitStatus` build site.
    - `docs/architecture/core-workspace.md`: `offersShowAsOneRow`.
    - `docs/architecture/app-window.md`: the tree menu and the separation handler.
    - `docs/architecture/app-shell.md`: the Sparkle paragraph.
    - `docs/RELEASING.md`: the XcodeGen version.
    - `README.md`
    - `CLAUDE.md`: the CI sentence only.
    - `docs/plans/completed/20261026-ci-speed-stripped-source-memo.md`: one phrase.
- Related patterns:
  - Charged work counted apart from its bound, as `TreeDiagnosticsIndex.steps` and `copiedEntries` already do.
  - Gated out-of-order refreshes through `StubGit.gateChangedFiles` and `waitForGatedCalls`.
  - Workflow assertions read through `workflowJobSteps(_:in:)` / `Self.jobSteps(_:in:)` (comment-stripped, job-scoped).
  - Prefer set equality to counting.
- Dependencies: none added. Network is used only to verify tags and digests, through `gh api` and `curl`, and to download the two XcodeGen zips into fresh empty temp directories.

## Development Approach

- **Testing approach**: Regular (code first, then tests). Every Core change gets its test in the same task.
- Complete each task fully before moving to the next.
- Read each touched file's entry in `docs/architecture/` first, and update it in the same task.
- Every local `xcodebuild` uses `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build`, with nothing inside the repository. Run the installed Xcode after `xcodegen generate`, and record the deviation from the pinned Xcode.
- No brand names or references to other editors anywhere: code, comments, docs or commit messages.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: A real probe count in the tree-diagnostics lookup (1.2)

**Files:**
- Modify: `Sources/PisakaCore/TreeDiagnostics.swift`
- Modify: `Tests/PisakaCoreTests/TreeDiagnosticsTests.swift`
- Modify: `docs/architecture/core-lsp.md`

- [x] Make `MarkTrie`'s read report the nodes its descent visited along with the value: a leaf answers 1, and each branch on the way adds one. The descent is the only place the count is produced. Then `resolve(_:)` returns that count instead of the literal `1`. A row outside both spellings still costs 0.
- [x] The bound uses `MarkTrie.depth`, which already exists (`TreeDiagnostics.swift`, added by #115 for the write-path tests). It is an internal, test-facing structural walk: 0 for a leaf, 1 plus the deepest child for a branch, so the deepest branch level plus one. It is separate from the read descent, which never calls it. This task reuses it unchanged; no new property is added. Extend its doc comment to say it also bounds a read's probe count.
- [x] Rewrite the type's "Asked" paragraph and the `resolve(_:)` doc comment. They now say the reported number is the trie nodes the descent visited, at most `depth + 1`.
- [x] Replace `testProbeCountIsAtMostOneWhateverTheStoreHolds` with a test over two stores. Each store also holds the existing `hit/x.swift` error, and each runs the same five lookups (hit, miss below the root `a/b/c/d.swift`, the folder, the root, outside `/elsewhere/x.swift`):
  - **Small store:** three files in one folder (`gen/f0.swift` to `gen/f2.swift`). Its keys are three files, `gen`, `hit/x.swift`, `hit` and the root: 7, under `MarkTrie.leafCapacity` (16), so the root stays a single leaf and `table.depth == 0`. The test asserts that depth, so the premise is checked rather than assumed.
  - **Large store:** 10,000 files under `gen/d<i % 37>/`, so the root splits and `table.depth >= 1` (also asserted).
  - **Assertion 1:** every probe is at most `table.depth + 1` of its own store.
  - **Assertion 2:** the count varies with the key's depth in the trie. Every in-root probe in the small store equals 1, and every in-root probe in the large store is greater than 1. This is what makes assertion 1 non-vacuous.
  - **Assertion 3:** the outside URL costs 0 in both stores.
- [x] Update `core-lsp.md`'s "The cost bound" paragraph to match. The thirteen-level ceiling is `MarkTrie.maxLevel`, and the pinned bound is the actual `depth + 1`.
- [x] Run `swift test`; it must pass before Task 2.

### Task 2: Folder tombstones are lifted and never duplicated (1.3)

**Files:**
- Modify: `Sources/PisakaCore/DiagnosticsModel.swift`
- Modify: `Tests/PisakaCoreTests/DiagnosticsModelTests.swift`
- Modify: `docs/architecture/core-lsp.md`

- [x] In `isRemovedAndGone(_:)`, when the probe finds the file, remove every tombstone the file lies at or under. Use the same whole-component lexical comparison the match uses, so the folder is evidently back.
- [x] In `noteItemRemoved(at:)`, skip the append when an existing tombstone already covers the path (the path is at or under it). The store clear is unchanged and always runs. Tombstones already recorded below a new folder tombstone are kept, for the reason given in the Overview.
- [x] Expose the tombstone list read-only to tests (`private(set)`, internal) and update the property's doc comment.
- [x] Add two tests:
  - After removing folder `Gone`, one positional report for `Gone/inner.swift`, once the probe says the file exists, leaves no tombstone at or above it. A second report under `Gone` does not probe.
  - After removing `Gone`, removing `Gone/a.swift` and then `Gone` again adds no entry: the count stays 1. The store entries under each removed path are still cleared.

  Adjust `testALateReportCannotResurrectARemovedPath` only where its expectations encoded exact-only lifting.
- [x] Update `core-lsp.md`'s tombstone paragraph: folder lifting, and no covered appends.
- [x] Run `swift test`; it must pass before Task 3.

### Task 3: The git lookup is built off the main actor (1.4)

**Files:**
- Modify: `Sources/PisakaCore/LocalChangesModel.swift`
- Modify: `Sources/PisakaCore/ChangedFile.swift`
- Modify: `Tests/PisakaCoreTests/LocalChangesModelTests.swift`
- Modify: `docs/architecture/core-git-models.md`

- [ ] Declare `FileStatus`, `ChangedFile` and `GitStatusSnapshot` `Sendable`. They are value types of `Sendable` members, so the snapshot can cross back from the non-isolated step.
- [ ] Add a `nonisolated static` async step that awaits `gitService.statusSnapshot(root:)` and builds `TreeGitStatus(snapshot:repositoryRoot:openedFolder:)` in the same context, returning both. `refreshImpl` calls it in place of the bare snapshot await. The generation and root-generation guard stays exactly where it is, on the main actor and before anything is assigned, and the published lookup is the one carried back. The failure path is unchanged.
- [ ] Rewrite the `projectPrefix(folder:repositoryRoot:)` comment to say the lookup builds its keys through it off the main actor, inside that step beside the status run. Update the matching sentence in `core-git-models.md`, including the 186 ms / 50 000-entry motivation in one clause.
- [ ] Add `testASupersededRefreshsLookupIsNeverPublished`. It subscribes to `$treeGitStatus` and records every value. It stages two gated refreshes with distinct lists and releases the superseded one **first**, while the newer one is still held, then releases the newer one. It asserts:
  - the recorded values contain no lookup built from the older list;
  - the last recorded value is the newer one's.

  The existing newer-first test stays.
- [ ] Run `swift test`; it must pass before Task 4.

### Task 4: Chain-row leftovers (1.5)

**Files:**
- Modify: `Sources/PisakaCore/TreeChainRule.swift`
- Modify: `Tests/PisakaCoreTests/TreeChainRuleTests.swift`
- Modify: `Sources/Pisaka/ProjectTreeView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `docs/architecture/core-workspace.md`
- Modify: `docs/architecture/app-window.md`
- Modify: `README.md`

- [ ] **`offersShowAsOneRow`.** A separated head now answers `segments.count > 1`: the chain joining it would form has more than one segment. The walk the head already makes gives this, and `holdsOneFolder(headListing)` is no longer used there. Rewrite the `folder` case's doc comment to say exactly that.
- [ ] **Unfold-sequence test.** Change the one expectation in `testTheUnfoldSequenceReRunsTheRuleWithNoNewListing` that encodes the old meaning: with `{a, b}` separated, `a` offers nothing. Add cases where a separated `a` whose only `b` is unreadable offers nothing, and where a separated `a` whose only child is a symbolic link offers the item.
- [ ] **One delete name in Core.** Give `TreeChain` a delete-confirmation name, its label, and build `deleteTitle` from it. Test that a chain's title quotes exactly that name and that the name is `a/b/c`.
- [ ] **Delete callback.** The tree's `onDelete` carries `(URL, String?)`. The chain row passes the chain's name; file and plain-folder rows pass `nil`. `ContentView` passes it through. `PisakaApp.deleteItem` hands `confirmDelete` the name, or `url.lastPathComponent` when it is `nil`.
- [ ] **Separation handler.** In `DirectoryNodeView`'s `onChange(of: separated)`, bind the remembered listing it already requests for the current contents directory. Store that listing as `children`, and compute the rows from it rather than from the saved `children`. The existing "not remembered, so reload or forget" fallback is kept.
- [ ] **Docs.** Update `core-workspace.md` (`offersShowAsOneRow` and `TreeRow`) and `app-window.md`: the menu's delete confirmation now names the label, and the separation handler stores the listing. Add half a sentence to `README.md`'s line with the severity dots: single-child folder chains show as one `a/b/c` row.
- [ ] Run `swift test` and the app-layer bundle (`xcodegen generate`, then `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build test`). Both must pass before Task 5.

### Task 5: Wording and test-suite tails (1.1, 1.6 suite and doc items)

**Files:**
- Modify: `docs/FEATURES.md`
- Modify: `docs/architecture/core-lsp.md`
- Modify: `Tests/PisakaCoreTests/LSPSourceGatingTests.swift`
- Modify: `Tests/PisakaCoreTests/GitHubSourceGatingTests.swift`
- Modify: `Tests/PisakaCoreTests/SparkleSourceGatingTests.swift`
- Modify: `docs/architecture/app-shell.md`
- Modify: `docs/plans/completed/20261026-ci-speed-stripped-source-memo.md`

- [ ] **Closed-file wording (1.1).**
  - In `FEATURES.md`'s Problems paragraph, the sentence "closing a file keeps its rows" and the "files that have been open" sentence now say: the app keeps a file's set on close, and the server decides what happens next. typescript-language-server (5.3.0, probed) clears the file on `didClose`. sourcekit-lsp sends nothing, so its last report stays listed. yaml-language-server's behaviour on close is unverified, and the text says so.
  - Make the same change in `core-lsp.md`'s D46 table rows and in its limits paragraph ("lists only the files that have been open").
- [ ] **`containsToken`.** Before changing it, run `swift test --filter 'ChromeThemeSourceGatingTests|MarkdownPreviewSourceGatingTests'` and record each suite's reported time in Notes. Then compare the slice in place (`elementsEqual`, as the stripper's `matches(_:at:)` does) with no per-position array. Re-run the same filter and record the after times. Behaviour is identical and pinned by the existing suites.
- [ ] **`strippingComments` doc.** Rewrite the "used by nothing else" sentence in `GitHubSourceGatingTests.strippingComments(_:)`'s doc comment to the phrasing chosen in the Overview, pointing at `ChromeThemeSourceGatingTests.testTheHeaderNamesEveryLiteralKeepingReading`.
- [ ] **"No CI job" claims.** Rewrite `SparkleSourceGatingTests`' DEBUG-branch case (doc comment and failure message) and `app-shell.md`'s Sparkle paragraph to what is true now:
  - The Release job (`build-macos`) is the only compile of the shipping `#if !DEBUG` path.
  - `test-macos`'s Debug build is the only compile of macOS `#if DEBUG` code. That job exists to host the app-layer bundle, so DEBUG-only content outside the iOS layer is code the shipping configuration never compiles.
  - Remove the "needs a third, macOS-Debug job" remedy. The asserted bound, `{SoftwareUpdater.swift}`, is unchanged.
- [ ] **Completed-plan phrase.** Correct the one phrase in the completed ci-speed plan's execution notes ("Sparkle keeps `try?` → empty"): that read now throws. Nothing else in that file changes.
- [ ] Run `swift test`; it must pass before Task 6.

### Task 6: `build-ios` gets the Xcode-keyed cache and the resolution guard; the Release-step comment (1.6 CI items)

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`
- Modify: `Tests/PisakaCoreTests/DependencyPinTests.swift`
- Modify: `CLAUDE.md`

- [ ] **Copy three steps into `build-ios`.** Give it the comment and the "Read the selected Xcode for the cache key" step, the cache step with the Xcode-keyed `key:` and `restore-keys:`, and the guard step with its comment directly after the resolve. Each is byte-identical, line for line, to `build-macos` and `test-macos`. All three jobs then share one SwiftPM cache entry.
- [ ] **Release-step comment.** Rewrite the comment above `build-macos`'s Release build step to the same claims as Task 5 (Release is the only compile of `#if !DEBUG`; `test-macos` Debug is the only compile of macOS `#if DEBUG`). Remove "built by no CI job" and "needs a third, macOS-Debug job".
- [ ] **Extend `testCIRefusesARewrittenPackageResolved` to all three jobs.**
  - Ask the guard of `build-ios` too.
  - Hold all three hashed paths equal.
  - Compare `test-macos` and `build-ios` against `build-macos` for each shared item (cache path/key/restore keys, the `id: xcode` step, the resolve step, the guard step), with failure messages naming the job.
  - Rewrite the doc comment: "build-ios … is not asked here" goes, and "two jobs" becomes three.
  - Rewrite `DependencyPinTests`' type doc comment to "all three build jobs".
- [ ] **CLAUDE.md.** Update the CI sentence so the iOS build is behind the same guard. Keep the file under 60,000 characters (`LintConfigurationTests`).
- [ ] **Hand-breaks.** Make each break, confirm the suite goes red, restore it, and record each in Notes:
  - delete `build-ios`'s guard step;
  - revert `build-ios`'s key to the un-Xcode-keyed form;
  - change one character in `build-ios`'s guard body.
- [ ] Run `swift test` and check that `ci.yml` parses as YAML (`ruby -ryaml -e 'YAML.load_file(...)'`). Both must pass before Task 7.

### Task 7: GitHub Actions and XcodeGen pins (Part 2)

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`
- Modify: `Tests/PisakaCoreTests/Support/YAMLLineMatching.swift`
- Modify: `docs/RELEASING.md`

- [ ] **Verify each pin against its tag.** For `actions/checkout` v7.0.1 and `actions/cache` v6.1.0, resolve the tag through `gh api` (`git/ref/tags/<tag>`, then dereference an annotated tag object to its commit). Confirm the commit equals the ticket's SHA (`3d3c42e5aac5ba805825da76410c181273ba90b1` for checkout, `55cc8345863c7cc4c66a329aec7e433d2d1c52a9` for cache), and read `action.yml` at that commit to confirm `using: node24`. On a mismatch, pin the tag's commit and record both values. Record the results in Notes, including setup-xcode v1.7.0's unchanged `node24`.
- [ ] **Replace every `uses:` line** of the two actions in both files. `actions/checkout` has 7 lines: one in each of `ci.yml`'s five jobs (`test`, `build-macos`, `test-macos`, `build-ios`, `lint`), plus 2 in `release.yml`. `actions/cache` has 4 lines: 3 in `ci.yml` (`build-macos`, `test-macos`, `build-ios`), plus 1 in `release.yml`. Use full SHAs and the existing `# vX.Y.Z` comment format, so each action's line is identical everywhere. Update `YAMLLineMatching`'s `# v4.3.1` example comment to `# v7.0.1`.
- [ ] **Confirm no new inputs are needed.** Confirm and record that neither workflow uses `pull_request_target`, so checkout v5+'s one breaking change needs no input. `actions/cache` v6 needs none either.
- [ ] **XcodeGen digest.** Download 2.46.0's `xcodegen.zip` into a fresh empty temp directory. Confirm its SHA-256 equals both `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806` and the digest the release API publishes. Download 2.45.4 into another empty directory and confirm `090ec294…`.
- [ ] **XcodeGen diff.** Generate the project with each binary from the repository root and diff the two `Pisaka.xcodeproj` trees, `Package.resolved` aside.
  - **Identical, or target order only:** keep the bump, and record the diff summary.
  - **Anything else:** build macOS (`platform=macOS`, Debug) and iOS (`generic/platform=iOS`) from each generated project with the shared derived-data path. Compare each product's embedded frameworks listing and `otool -L` of the executable.
    - Equal: keep the bump and record the explanation.
    - Different: revert every XcodeGen mention to 2.45.4, record the follow-up and its reason in Notes, and continue with the action bumps alone.
- [ ] **If the bump stands,** change all four install steps (step name, URL, digest) and `RELEASING.md`'s "XcodeGen 2.45.4". `testXcodeGenIsPinnedIdenticallyToCI` must stay green. No action version is added to `RELEASING.md`.
- [ ] **New pin-shape rule.** Add `testEveryActionIsPinnedToOneFullCommitInBothWorkflows` to `ReleaseWorkflowTests`. It holds three things:
  - Every `uses:` line in `ci.yml` and `release.yml` is `owner/repo@<40 lowercase hex> # vX.Y.Z`.
  - For each action, the distinct `uses:` lines across both files form a single line.
  - The set of actions equals `{actions/checkout, actions/cache, maxim-lobanov/setup-xcode}` by set equality.
- [ ] **Hand-breaks.** Confirm each goes red, restore it, and record it in Notes:
  - one job's checkout SHA altered by a character;
  - a `@v7` tag reference;
  - a dropped `# v7.0.1` comment;
  - a fourth action added.
- [ ] Run `swift test` (`ReleaseWorkflowTests`, `LintConfigurationTests` and `DependencyPinTests` must all stay green, none weakened) and parse both YAML files. Both must pass before Task 8.

### Task 8: Verify acceptance criteria

- [ ] Run `swift test`: the full Core suite.
- [ ] Run the app-layer bundle, the macOS Release build and the iOS `generic/platform=iOS` build. Each runs under the installed Xcode after `xcodegen generate`, with `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build`, and the toolchain deviation is recorded. If local resolution rewrote `Package.resolved`, restore it with `git checkout`.
- [ ] Run `swiftlint --strict` (0.65.1) from the repository root.
- [ ] Grep the repository, excluding `.build` and `docs/plans/completed/`, for "no CI job", "used by nothing else", "files that have been open" and "closing a file keeps its rows". Confirm every hit is true after this ticket.
- [ ] Confirm `CLAUDE.md` is under 60,000 characters, and that no brand name or reference to another editor was introduced (search the diff).
- [ ] Verify test coverage of every changed Core path. Each of the four behaviour changes has its named test.

### Task 9: Update documentation

- [ ] Confirm that `README.md` (the chain row half-sentence) and `CLAUDE.md` (the CI sentence only, no new index entries, since no file was added) are as Tasks 4 and 6 left them.
- [ ] Confirm that every touched file's `docs/architecture/` entry was updated in its task: `core-lsp.md`, `core-git-models.md`, `core-workspace.md`, `app-window.md` and `app-shell.md`.
- [ ] Fill in Notes.

## Notes (filled in during execution)

- Suite timings before and after `containsToken`: `ChromeThemeSourceGatingTests` and `MarkdownPreviewSourceGatingTests`.
- Pin verification: each tag → commit, `node24` confirmed, any difference from the ticket's SHA; setup-xcode unchanged.
- `pull_request_target` check: `ci.yml` runs on `pull_request` and pushes to `master`, `release.yml` on `v*` tags; no checkout input added.
- XcodeGen: both digests, the diff summary, and which branch was taken.
- Hand-breaks: the guard extension (Task 6) and the pin-shape rule (Task 7), each with the failure it produced.
- Toolchain deviation: the installed Xcode in place of 26.3 for the local app-layer gates.

## Post-Completion

These are manual checks, outside the task checkboxes:

- **A PR run of `ci.yml`.** It shows no Node.js deprecation annotation, and all five jobs are green. `build-ios`'s log shows the `spm-Xcode-26.3-…` cache key and the `Package.resolved is unchanged by resolution` step.
- **A Debug build of the app.** Launch the Debug product only. A chain row's *Delete "a/b/c"* menu item and its confirmation sheet name the same `a/b/c`. A separated folder whose only child is itself separated offers no *Show as One Row*.
