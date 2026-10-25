# Live project tree: git-status name colouring, ignored entries, indent guides (macOS)

## Overview

The macOS project tree starts showing the repository's state. Each row's name is coloured by its git state: conflict, modified, added, ignored or plain. A folder takes the strongest change state found anywhere below it, whether or not it is expanded. Gitignored entries are dimmed, and their children are dimmed by ancestry without another git call. Separately, every expanded folder gets a hairline indent guide running down beside its children.

Nothing new runs git. All of the git knowledge comes from the `git status --porcelain=v2 -uall` run that Local Changes already performs, plus one extra flag, `--ignored=matching`. That status is parsed into a separate ignored list (`changedFiles` stays byte-for-byte as it is today), turned into a pure Core lookup once per refresh, published on `LocalChangesModel` under the refresh's generation tokens, and read by the tree as a value. The tree only reads git state. It raises no writer gate, and no writer gate blocks it.

## Context

- Files involved (Core): `Sources/PisakaCore/GitStatusParser.swift`, `Sources/PisakaCore/ChangedFile.swift`, `Sources/PisakaCore/GitServicing.swift`, `Sources/PisakaCore/LocalChangesModel.swift`, `Sources/PisakaCore/ChromeColorRole.swift`, `Sources/PisakaCore/CanonicalPath.swift` (read only), new `Sources/PisakaCore/TreeGitStatus.swift`
- Files involved (app, macOS): `Sources/Pisaka/GitCLIService.swift`, `Sources/Pisaka/ProjectTreeView.swift`, `Sources/Pisaka/ContentView.swift`
- Tests: `Tests/PisakaCoreTests/GitStatusParserTests.swift`, new `Tests/PisakaCoreTests/TreeGitStatusTests.swift`, `Tests/PisakaCoreTests/LocalChangesModelTests.swift`, the `ChromeColorRole` mapping tests, `Tests/PisakaCoreTests/GitCLIArgumentSourceGatingTests.swift`, `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`, `Tests/PisakaAppTests/GitCLIServiceRepositoryTests.swift`, new `Tests/PisakaAppTests/TreeIndentGuideLayoutTests.swift`, `Tests/PisakaAppTests/TreeRowGlyphLayoutTests.swift` (must stay green)
- Docs: `docs/architecture/core-git.md` (where `GitStatusParser.swift` and `ChangedFile.swift` are actually documented), `docs/architecture/core-git-models.md` (`LocalChangesModel` plus the new lookup), `docs/architecture/app-git-views.md` (`GitCLIService`), `docs/architecture/app-window.md` (the tree), `docs/architecture/core-theme.md` (the role mapping and the new gating rule), `CLAUDE.md` (index name, the rule count and the invariant for readers)
- Related patterns:
  - `ChromeColorRole.changedFileRole(for:)` and `diffWashRole(for:)`: exhaustive Core mappings, the second one answering an optional role.
  - `FileStatus.spokenName`: the accessibility word for a status.
  - `TreeSelection`: no file-system call per row; two spellings are resolved once per render.
  - `LocalChangesModel.projectPrefix(folder:repositoryRoot:)`: canonical relative components.
  - The protocol-extension defaults on `GitServicing`.
  - `HostedRender` for app-layer bitmap measurement.
  - `Gate` for staging races in async tests.
- Dependencies: none new. No new required-reason API, no new palette value, no new role.

## Decisions settled here (resolving the ticket's open edges)

- **The lookup is git's answer only.** Ignored status comes from git's `!` records. Core's gitignore matcher is not touched.
- **Ignored never spreads upward.** Folder aggregation runs over the three change states only (conflict, modified, added). Ignored spreads only downward, to descendants. Otherwise a folder holding `node_modules` would be dimmed itself.
- **A tracked change outranks ignore** because the change table is consulted before the ignored set. That covers any change state, including an added file under an ignored path.
- **Renames and deletions.** A rename's old path contributes nothing: only the new path is recorded and aggregated. A deleted file contributes "modified" to its ancestors.
- **The parser strips the trailing slash** from a directory `!` record. The ignored list holds plain repo-relative paths, and ancestry treats each one as a prefix.
- **The lookup also takes the opened folder.** Its inputs are the status snapshot, the repository root and the opened folder. At build time it resolves a small set of root spellings: the opened folder standardized and canonical (each mapped to its prefix inside the repository), and the repository root standardized and canonical. A query standardizes the row's URL lexically, strips whichever spelling matches through `CanonicalPath.relativeComponents`, and gets a repo-relative key. There is no file-system call per row. The opened folder is needed because the tree spells rows under the folder as the user spelled it, while git reports a resolved top level.
- **Query cost** is one dictionary read for the row's change state. If that misses, there is at most one set read per ancestor level for ignore inheritance. The cost is bounded by the row's depth and never by the number of status records. An internal probe-counting seam pins this.
- **Failure handling: the tree and the panel never disagree.** Local Changes already empties `changedFiles` in its failure block, under the `refreshGeneration` and `rootRequestGeneration` guards, where it also clears `selected` and the revert selection. The published lookup is reset to empty in that same block, under the same guards. A failed refresh therefore shows plain everywhere, exactly as the panel shows an empty list. A superseded failure returns before that block runs, so it clears nothing newer.
- **Plain has no role.** The plain state maps to no role, so the name keeps the inherited foreground it is drawn in today. That keeps the tree pixel-identical outside a repository.
- **The seam.** `GitServicing` gains a status-snapshot requirement with a protocol-extension default that wraps `changedFiles` with an empty ignored list. iOS's libgit2 service and every existing stub compile unchanged. On macOS, `GitCLIService` runs the one status command in one place, and its `changedFiles` is derived from that same snapshot. The flag therefore appears once, and the commit dialog's and branch switcher's results are unchanged.
- **Indent guide placement.** Guides are drawn behind the children block, so the row backgrounds paint over them exactly as today. They are positioned by layout: the row-padding inset, then a frame one chevron column wide with the rule centred in it. They are never placed by arithmetic on a token, which chrome gating rule seven forbids.
- **Gating gets a new rule, fifty-one.** Rule seventeen stays as it is. Its doc and its reader set are about `changedFileRole(for:)` and its three readers. The tree-name mapping gets its own rule, with its own reader set. The suite's rule count rises to fifty-one, and every place that restates the count moves with it in the same task, because the count is pinned across files on purpose.

## Development Approach

- **Testing approach**: TDD for the Core pieces (parser, lookup, role mapping, model publishing); regular for the app-layer wiring, with the app-layer and gating tests written in the same task.
- Complete each task fully before moving to the next.
- No brand names or references to other editors anywhere: code, comments, docs, commits.
- Paths are stored as spelled and matched canonically. No new spelling of path canonicalisation.
- Generation tokens are captured synchronously before the `Task` hop. The lookup is published in the same guarded block as `changedFiles`, and cleared in the same guarded failure block that empties it.
- Every `xcodebuild` uses `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build` and the pinned Xcode (`DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer`). Run `xcodegen generate` after adding any file to an app or app-test target.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Status snapshot — the parser stops discarding ignored records

**Files:**
- Modify: `Sources/PisakaCore/GitStatusParser.swift`
- Modify: `Sources/PisakaCore/ChangedFile.swift`
- Modify: `Sources/PisakaCore/GitServicing.swift`
- Modify: `Tests/PisakaCoreTests/GitStatusParserTests.swift`

- [x] Introduce a status snapshot value: the changed-file list plus a separate list of ignored repo-relative paths. Add a parser entry point that produces it from porcelain v2 output. `! <path>` records go to the ignored list with the directory trailing slash removed. Paths with spaces survive, as for every other record. The existing list-returning `parse` keeps its exact output, so every current caller and test stays byte-for-byte the same.
- [x] Add a status-snapshot requirement to `GitServicing`, with a default in the protocol extension that wraps `changedFiles(root:)` and an empty ignored list. Document why it is defaulted: iOS and the stubs stay untouched.
- [x] Tests:
  - `!` file records and `!` directory records are carried separately, with the slash stripped.
  - The changed-file list is identical with and without `!` lines interleaved.
  - Header lines are still skipped.
  - A path with spaces is preserved.
  - The default seam returns the wrapped `changedFiles` and no ignored paths.
- [x] Run `swift test`. It must pass before Task 2.

### Task 2: The row-state lookup (Core, pure)

**Files:**
- Create: `Sources/PisakaCore/TreeGitStatus.swift`
- Create: `Tests/PisakaCoreTests/TreeGitStatusTests.swift`

- [x] Add the closed row-state enum, highest precedence first: conflict, modified, added, ignored, plain. Give it a spoken word for each non-plain state ("Conflicted", "Modified", "Added", "Ignored"). Add one pure function that composes a row's accessibility value: for a file, the state word or nothing; for a folder, the existing "expanded"/"collapsed" followed by the state word when there is one.
- [x] Add the lookup value (Equatable, Sendable, with an empty value that answers plain everywhere).
  - It is built once from the snapshot, the repository root and the opened folder, in time linear in the records times their depth.
  - Change-state mapping: unmerged → conflict; modified, renamed (new path) and deleted → modified; added (copies included) and untracked → added.
  - Each recorded path and every one of its ancestors, up to and including the repository root's empty key, keeps the highest change state seen.
  - Ignored paths go into a set.
- [x] The query takes a row URL as the tree holds it. It converts the URL lexically to a repo-relative key against the root spellings resolved at build (see Decisions), reads the change table first, then checks the key and its ancestors against the ignored set, and otherwise answers plain. A URL outside every spelling answers plain. Expose the probe count through an internal seam so a test can pin the cost bound.
- [x] Tests, one per rule:
  - A file takes its own state.
  - A rename colours the new path, and the old path contributes nothing.
  - A deletion counts for its ancestors as modified, never conflict.
  - Folder aggregation is transitive, several levels deep, and built from the flat list alone.
  - Modified plus untracked gives modified; untracked alone gives added; a conflict anywhere below gives conflict.
  - A wholly untracked directory becomes added without a record of its own.
  - Ignore is inherited by ancestry. A directory record behaves as a prefix, so a sibling sharing a name prefix (`build` versus `build-tools`) is not ignored.
  - Ignored never aggregates upward to the parent of an ignored directory.
  - A tracked change outranks ignore: the file and the ignored folder show the change, and unlisted siblings stay ignored.
  - The empty lookup answers plain.
  - An opened folder that is a subdirectory of the repository resolves keys through its prefix.
  - A symlinked spelling of the opened folder matches through its canonical spelling.
  - The probe count stays at most the row's depth plus one, whether the lookup holds 10 records or 10,000.
  - The accessibility composition gives the right value for both row kinds.
- [x] Run `swift test`. It must pass before Task 3.

### Task 3: The state-to-role mapping, and gating it as Core's one answer (rule fifty-one)

**Files:**
- Modify: `Sources/PisakaCore/ChromeColorRole.swift`
- Modify: the existing `ChromeColorRole` mapping tests in `Tests/PisakaCoreTests/`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md`
- Modify: `CLAUDE.md`

- [x] Beside the existing status mappings, add one exhaustive mapping from row state to an optional role: conflict → `statusRed`, modified → `statusYellow`, added → `statusGreen`, ignored → `textSecondary`, plain → no role, because the name keeps its inherited foreground. Its doc comment states that folder and file rows map identically and that no new role or palette value exists. The reference values, unchanged in `ChromePalette`, are:

  | state | role | dark | light |
  |---|---|---|---|
  | conflict | `statusRed` | `#c4746b` | `#c1483d` |
  | modified | `statusYellow` | `#c9a35c` | `#a67c2e` |
  | added | `statusGreen` | `#7a9d6e` | `#4f8a3d` |
  | ignored | `textSecondary` | `#a0a3aa` | `#6e6e73` |

- [x] Tests: every state's answer pinned over `allCases`, and plain answering no role.
- [x] Add a new rule fifty-one to the theme gating suite for the tree-name mapping, with its own `// MARK: - Rule fifty-one: …` marker placed after rule fifty. Over comment- and literal-stripped source it asserts:
  - no app file declares its own tree-name mapping function;
  - the app files calling the Core mapping are exactly `ProjectTreeView.swift`, by set equality;
  - no gated file spells a row-state case label of the new enum.

  Rule seventeen, its doc comment and its reader set stay exactly as they are.
- [x] In the same task, move every restatement of the rule count, which the suite's self-checks pin across files:
  - add `51: "fifty-one"` to the suite's number-to-word table;
  - add a bolded bullet for rule fifty-one to the suite's header inventory, titled as its marker is and in the markers' order;
  - in `core-theme.md`, change the canonical list's opening to "The fifty-one rules, each invisible to the compiler:" and append item `51.` describing the rule;
  - in `CLAUDE.md`, change "and its fifty rules" to "and its fifty-one rules" in the chrome-theme invariant.

  The gated-file set is unchanged, so the gated-set size wording stays as it is.
- [x] Rule fifty-one only becomes satisfiable by set equality once `ProjectTreeView.swift` calls the mapping (Task 5). Until then, its reader-set clause expects the empty set, and Task 5 updates that expectation to `ProjectTreeView.swift`. Alternatively, land the clause with its final expectation in Task 5. Either way, the suite is green at the end of each task.
- [x] Run `swift test`. It must pass before Task 4.

### Task 4: One status command, and the model publishes the lookup

**Files:**
- Modify: `Sources/Pisaka/GitCLIService.swift`
- Modify: `Sources/PisakaCore/LocalChangesModel.swift`
- Modify: `Tests/PisakaCoreTests/LocalChangesModelTests.swift`
- Modify: `Tests/PisakaCoreTests/GitCLIArgumentSourceGatingTests.swift`
- Modify: `Tests/PisakaAppTests/GitCLIServiceRepositoryTests.swift`

- [x] In `GitCLIService`, the snapshot method runs the one existing status command with `--ignored=matching` added. `core.quotePath=false`, `--porcelain=v2` and `-uall` stay, and the not-a-repository error mapping is unchanged. `changedFiles(root:)` returns the snapshot's changed-file list, so the argument array is spelled exactly once in the file.
- [x] Publish the lookup on `LocalChangesModel`:
  - `refreshImpl` asks for the snapshot instead of the bare list and builds the lookup from the snapshot, the resolved repository root and the opened folder.
  - It publishes the lookup in the same guarded block, under the same `refreshGeneration` and root-generation checks, that publishes `changedFiles`.
  - The failure path resets the lookup to empty in the same catch block that empties `changedFiles` and clears `selected` and the revert selection, after the same `refreshGeneration` / `rootRequestGeneration` guard. A superseded failure returns at that guard and touches nothing.
  - A superseded successful refresh publishes neither.
  - Both folder-switch clears (`prepareForFolderChange` and the root-change branch of `refreshImpl`) reset it to empty synchronously, before any suspension.
  - `refresh` and `refreshForDiskChange` both funnel here, so the save, watcher, gated-operation, commit and folder-switch refreshes all carry the lookup with no new trigger.
- [x] Core tests, using the existing stub, extended with an ignored list served through the snapshot seam and reusing its gated `changedFiles`:
  - A successful refresh publishes the lookup.
  - Ignored paths never appear in `changedFiles`.
  - A superseded refresh, staged with the existing gate, does not overwrite a newer lookup.
  - A folder switch clears the lookup synchronously before the new root's refresh lands.
  - A failed refresh clears the lookup to empty, together with `changedFiles`.
  - A superseded failure clears nothing newer. Stage it with the gate: a refresh that will fail is held, a newer refresh succeeds and publishes, then the held one is released to fail. The newer lookup and `changedFiles` both survive.
- [x] Gating: add a rule to `GitCLIArgumentSourceGatingTests`, in its literal-keeping reading. Exactly one array literal spells `"--ignored=matching"`, that literal also spells `"status"`, and no other literal in the file spells `--ignored` in any form. List it in the suite's header inventory.
- [x] App-layer real-git tests in throwaway repositories. A snapshot reports each of these as ignored, and none of them appears among the changed files:
  - an ignored directory from `.gitignore`, as one slash-stripped path;
  - a file ignored only through `.git/info/exclude`;
  - a file ignored only through an excludes file named by `core.excludesFile` in the repository's config, standing in for the global one.

  Also, a force-added tracked file inside an ignored directory, once modified, is reported as modified, and its sibling stays ignored.
- [x] Run `swift test` and the app-layer bundle. Both must pass before Task 5. (The pinned Xcode 26.3 is not installed on this machine; the app-layer bundle ran under the installed Xcode 27.1 after `xcodegen generate`: 484 tests, 0 failures.)

### Task 5: Painting the names in the tree

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift` (rule fifty-one's reader set, if staged in Task 3)

- [ ] `ProjectTreeView` takes the lookup as a value, empty by default, so previews and the existing app tests construct it unchanged. `ContentView` passes `localChanges`' published lookup. The value travels down the recursion beside `selection` to every folder and file row.
- [ ] Each row asks the lookup for its state once.
  - Only the name text takes the mapped role through the injected theme. Plain applies no foreground at all.
  - The icon stays `textSecondary`, the chevron is unchanged, and the row background still comes from `TreeRowState` through `TreeRowBackground` exactly as today. A selected row keeps its status colour.
  - The inline rename field is not recoloured.
- [ ] Accessibility:
  - A folder row's accessibility value becomes the Core composition: the expansion word plus the state word.
  - A file row becomes one combined element carrying the state word as its value when the state is not plain. It stays `.contain` while a rename draft is open, mirroring the folder row.
- [ ] The tree adds no trigger, no timer, no git call and no writer-gate interaction.
- [ ] Rule fifty-one's reader set is now exactly `ProjectTreeView.swift`. Keep `ChromeThemeSourceGatingTests` and `ZoomSourceGatingTests` green. No new chrome file is added, so the pinned sets are unchanged.
- [ ] Run `swift test` and the app-layer bundle. Both must pass before Task 6.

### Task 6: Indent guides

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`
- Create: `Tests/PisakaAppTests/TreeIndentGuideLayoutTests.swift`

- [ ] While a folder is expanded, draw one vertical guide behind its children block.
  - Put it in the folder's disclosure-style body, as a small private view that reads the environment's metrics and theme.
  - It spans the block's full height, nested expanded blocks and an open create-draft included. Nested folders draw their own, deeper guides.
  - Its x position is the centre of the parent folder's chevron column: inset by the scaled row padding, then centred in a frame one scaled chevron column wide.
  - Colour `hairline`; thickness the scaled `ChromeGeometry.hairlineWidth` (1pt at scale 1; one nesting level is the 16pt `treeIndentStep`).
  - No arithmetic on any token.
  - A collapsed folder draws nothing, because its content is not rendered at all.
  - No highlight, no hit target, no setting.
- [ ] App-layer test, with a few renders only and not in loops. Render a tree whose root is expanded with a couple of children, at scale 1 and at one larger scale. Assert that a `hairline`-coloured column exists at the root chevron's centre across the children rows' span, that it is the scaled width, and that it moves with the scale. Also assert that it is absent from the root row itself, above the children block.
- [ ] Keep `TreeRowGlyphLayoutTests` green. If one of its samples now overlaps the guide column, re-scope the sample; do not move the guide.
- [ ] Run `swift test`, the app-layer bundle and `swiftlint --strict`. All must pass before Task 7.

### Task 7: Verify acceptance criteria

- [ ] Run `swift test`.
- [ ] Run the app-layer bundle: `DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build test`
- [ ] Run the iOS build. It must still compile through the protocol default: same command with `-destination 'generic/platform=iOS'` and `build`.
- [ ] Run `swiftlint --strict` from the repository root.
- [ ] Walk the ticket's acceptance list against the tests. Each Core rule has its own test, the parser, gating and real-git cases are covered, and no ignored path reaches `changedFiles`.

### Task 8: Update documentation

- [ ] `core-git.md`: the parser's entry, now carrying the `!` records separately with the slash stripped, and the new snapshot value. The `GitServicing` entry: the new requirement and its default.
- [ ] `core-git-models.md`:
  - `LocalChangesModel`'s entry: the published lookup, its tokens, the clears on folder switch, and the failure block that clears it together with `changedFiles` under the same guards.
  - A full entry for `TreeGitStatus.swift`: states, precedence, the change-only upward aggregation, ignore by ancestry, change-outranks-ignore, the spellings rule and the cost bound.
- [ ] `app-git-views.md`: `GitCLIService`'s status command and the new gating rule.
- [ ] `app-window.md`: name colouring, accessibility values and indent guides for the tree.
- [ ] `core-theme.md`: the new mapping beside the other status mappings. Rule fifty-one's canonical-list item was already added in Task 3; check that it still matches the final code.
- [ ] `CLAUDE.md`:
  - add `TreeGitStatus.swift` to the `core-git-models.md` index line;
  - add a short sentence beside the existing readers invariant: the project tree reads git state only from the published lookup, raises no writer gate, and no writer gate blocks it;
  - the rule count was already moved to fifty-one in Task 3;
  - keep the file under the 60,000-character limit, which `LintConfigurationTests` enforces.
- [ ] Leave `README.md` and `docs/FEATURES.md` alone unless the latter lists tree features; if it does, add one line for status colours and indent guides.
