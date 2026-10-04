# The breadcrumb starts with the project root's name

## Overview

The path bar above the editor shows a file inside the opened project as its path below the
root (`src › a.py`). A file at the root shows only its bare name (`main.py`), which repeats
the tab next to it and says nothing about where the file is. After this change the
breadcrumb starts with the root's own name, the same way the project tree does:
`project › main.py`, `project › src › a.py`.

This deliberately departs from the design. The design's main window shows
`Sources › PisakaCore › WorkspaceModel.swift` for a file in a project named `pisaka`,
without the root's name. The design's tree has no root row, though, and the app's tree
does. The crumb starts where the tree starts. This is recorded in `core-workspace.md` and
dated 2026-10-04.

The whole change is one branch inside `DisplayPath.components(fileURL:projectRoot:home:)`,
plus its tests and docs. `BreadcrumbBarView`'s drawing, height and truncation do not change.
The Problems panel and the window title do not change.

## Context

- Files involved:
  - `Sources/PisakaCore/DisplayPath.swift`: the only place the segments are decided
  - `Tests/PisakaCoreTests/DisplayPathTests.swift`: its suite, including the
    `SymlinkFixture` (`<dir>/real`, `<dir>/link -> <dir>/real`)
  - `Sources/Pisaka/BreadcrumbBarView.swift`: header doc comment only (example path)
  - `docs/architecture/core-workspace.md`: the `DisplayPath.swift` entry
  - `docs/architecture/app-window.md`: the `BreadcrumbBarView.swift` entry (example path)
  - `docs/FEATURES.md`: the path-bar paragraph near line 146 (the limits paragraph near
    line 1798 stays truthful and is left alone)
  - `Sources/PisakaCore/DiagnosticStore.swift`: read only. Its comments cite
    `DisplayPath.relativeComponents(of:under:)`'s probe order, not the public answer, so
    they stay truthful as long as that private helper is untouched.
- Related patterns:
  - `MainWindowTitle.text(projectRoot:focusedFileName:)` and `ProjectSwitcherView` both
    name the project as `projectRoot.lastPathComponent`, the spelling the user opened,
    never resolved. The breadcrumb's first segment must agree with them.
  - The existing two-probe containment (lexical `standardizedFileURL` first, then
    canonical) and its rule that the lexical spelling wins the display.
- Dependencies: none.

## Design decisions (fixed, not open)

- Keep the private `relativeComponents(of:under:)` exactly as it is: same signature, same
  probes, same answer (the suffix strictly below the ancestor). The root's name is
  prepended only in `components(...)`, on the project-root branch. The home branch
  (`["~"] + suffix`), the absolute branch and the `Untitled` branch are not touched. This
  also keeps the comments in `DiagnosticStore.swift` truthful without editing them.
- The name is `projectRoot.standardizedFileURL.lastPathComponent`:
  - It is lexical. Symlinks are never resolved, so a root opened through `link` shows
    `link` even when the file only matched through the canonical probe.
  - A trailing slash (`/…/proj/`) and an unstandardized spelling (`/…/other/../proj`)
    both give `proj`, the same name `MainWindowTitle` shows for any normally opened root.
  - The name is computed from the root URL and never taken from whichever probe matched.
- One edge decided here: when the project root is the filesystem root `/`, its last path
  component is `/`. Today's documented rule is that the leading `/` is never a segment.
  So in that case no name is prepended, and the answer stays exactly what it is today
  (`["a.txt"]` for `/a.txt`). This is one guard in `components(...)` with its own test.
- The root itself still is not strictly under itself and still falls through to the
  `~`/absolute branch, unchanged.

## Development Approach

- **Testing approach**: TDD. Update the expectations and add the new cases first, watch
  them fail for the expected reason, then change `DisplayPath`.
- Complete each task fully before moving to the next.
- No product or brand names anywhere: code, comments, docs, tests, commit messages.
- Every `xcodebuild` invocation passes
  `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build`, the one permanent
  folder, never a path inside the repository.
- The work is committed on the current branch `lsp-consent-banner-card`. Never create a
  new branch.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: `DisplayPath` leads with the root's name (Core + tests)

**Files:**
- Modify: `Tests/PisakaCoreTests/DisplayPathTests.swift`
- Modify: `Sources/PisakaCore/DisplayPath.swift`

- [x] In `DisplayPathTests`, update every case whose expectation gains the root's name, and
  rename each one to say what it now asserts. Expected answers (`proj` is the root
  `/Users/tester/dev/proj`; `real`/`link` are the fixture's directories):
  - `testFileInsideRootYieldsSuffixWithoutTheRootName` becomes e.g.
    `testFileInsideRootYieldsTheRootNameThenTheSuffix`: `["proj", "backend", "src", "a.ts"]`
  - `testFileDirectlyAtTheRootYieldsJustItsName` becomes e.g.
    `testFileDirectlyAtTheRootYieldsTheRootNameThenItsName`: `["proj", "main.ts"]`. Give it
    a doc comment saying this is the case the change exists for: a bare name would only
    duplicate the tab beside the bar.
  - `testTrailingSlashOnTheRootStillMatches` becomes e.g.
    `testTrailingSlashOnTheRootYieldsTheSameRootName`: `["proj", "src", "a.ts"]`. It also
    asserts the answer equals the one for the same root spelled without the slash.
  - `testUnstandardizedPathsAreStandardizedOnBothSides` is renamed so the name covers the
    root's name too: `["proj", "src", "a.ts"]`
  - Symlink case (a), the root opened through `link` with a canonically spelled file, is
    renamed to say the symlink's name leads: `["link", "src", "a.swift"]`
  - Symlink case (b), a file through `link` against root `real`, is renamed:
    `["real", "src", "a.swift"]`
  - The symlink inside the root pointing outside, renamed: `["real", "src", "alias.swift"]`
  - The pnpm-shaped symlink inside the root pointing inside, renamed:
    `["real", "src", "alias.swift"]`
  - `testAgreesWithWorkspaceModelAcrossPathSpellings` is renamed. Its inner loop expects
    `["real", "src", "a.swift"]` under `fixture.real` and `["link", "src", "a.swift"]` under
    `fixture.link`, written as literals and not computed from `lastPathComponent`. Its
    message keeps naming the tab and the root.
  - `testDisagreementWithWorkspaceModelIsAlsoConsistent` is renamed. Its
    `XCTAssertNotEqual` compares against the relative answer as it is now,
    `["real", "src", "a.swift"]`. Its absolute-components `XCTAssertEqual` is unchanged.
- [x] Add new cases:
  - A root opened through `link` with the file spelled through `link` too (the lexical
    probe matches): `["link", "src", "a.swift"]`, the symlink's name and never the
    referent's.
  - Project root `/` with file `/a.txt`: `["a.txt"]`, no `/` segment and no name prepended.
- [x] Leave every other case untouched: the root itself, the sibling-prefix cases, outside
  the root/home, no root open, filesystem root without a project, the unstandardized
  absolute path, and both `Untitled` cases.
- [x] Run `swift test --filter DisplayPathTests` and confirm the changed and new
  expectations fail because the root's name is missing. The `/` case and the untouched
  cases still pass.
- [x] In `DisplayPath.components(...)`, on the project-root branch, return the root's name
  (`projectRoot.standardizedFileURL.lastPathComponent`) followed by the suffix. Skip the
  prepend when that name is `/`.
- [x] Update `DisplayPath`'s doc comments to the new answer:
  - The type's summary example starts with the root's name.
  - The bullet for "a file strictly under `projectRoot`" says it yields the root's name as
    the user opened it (lexical, never resolved, the window title's and the project
    switcher's spelling), then the suffix below the root.
  - Say in one sentence that a root at `/` adds no name.
  - Leave the `relativeComponents(of:under:)` doc comment unchanged.
- [x] Confirm `DiagnosticStore.swift`'s two comments that cite
  `DisplayPath.relativeComponents` still describe the probe order truthfully, and leave
  them unedited.
- [x] Run `swift test`. The full suite must pass before Task 2.

### Task 2: Documentation and the view's header example

**Files:**
- Modify: `docs/architecture/core-workspace.md`
- Modify: `docs/architecture/app-window.md`
- Modify: `Sources/Pisaka/BreadcrumbBarView.swift` (doc comment only)
- Modify: `docs/FEATURES.md`

- [x] In `core-workspace.md`'s `DisplayPath.swift` entry:
  - Replace "the suffix *below* the root (without the root's own name, ending in the file
    name)" with the new answer: the root's name, its last path component as the user
    opened it (lexical; a root opened through a symlink shows the symlink's name; a
    trailing slash changes nothing; a root at `/` adds no name), then the suffix below the
    root, ending in the file name.
  - Note that the name agrees with `MainWindowTitle` and the project switcher.
  - Note that the cross-type consistency tests now expect the root's name in the relative
    answer.
  - Add a dated record of the deviation: "Deviation from the design (2026-10-04)". The
    design's main window starts the crumb below the root, but the design's tree has no root
    row and the app's tree has one. The crumb starts where the tree starts, and a
    root-level file no longer reads as a bare name that duplicates its tab.
- [x] In `app-window.md`'s `BreadcrumbBarView.swift` entry and in
  `BreadcrumbBarView.swift`'s header doc comment, change the description to say the path
  starts with the project root's name, and change the example from
  `backend › src › dialogs.service.ts` to one starting with the root's name (e.g.
  `project › backend › src › dialogs.service.ts`). No code change in the view.
- [x] In `docs/FEATURES.md`'s path-bar paragraph near line 146, say the breadcrumbs start
  with the project's name, the way the project tree does, and update the example to start
  with it (e.g. `project › backend › src › dialogs › dialogs.service.ts`). Re-read the
  limits paragraph near line 1798 and confirm it is still truthful (it should need no
  change).
- [x] Grep `docs/` (excluding `docs/plans/`), `README.md` and `Sources/` for other wording
  that states the breadcrumb omits the root's name, and fix only statements that are now
  untrue. Expected: none beyond the files above.
- [x] Run `swift test` (the documentation-reading suites must stay green, including the
  `CLAUDE.md` size pin in `LintConfigurationTests`; `CLAUDE.md` itself is not changed).

### Task 3: Verify acceptance criteria and the four gates

- [ ] Run `swift test`; it must pass.
- [ ] Run `swiftlint lint --strict` from the repository root; it must be clean.
- [ ] Run `xcodegen generate`, then
  `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build test`;
  it must pass.
- [ ] Run
  `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -configuration Release -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build build`;
  it must succeed.
- [ ] Check that the tests pin each acceptance criterion:
  - `project`-rooted files read with the root's name first, at the root and nested.
  - Outside-root, `~`, absolute and `Untitled` answers are unchanged.
  - A root opened through a symlink leads with the symlink's name.
  - Every changed expectation's test name says what it asserts.
  - The deviation, with its date and reason, is in `core-workspace.md`.
- [ ] Read `git diff` over the branch's new commits and confirm:
  - No file outside the lists above changed.
  - No brand or product names were added.
  - `PisakaCore` gained no imports.

## Post-Completion

- Manual check in a Debug build: open a folder, select a root-level file and a nested file,
  and confirm the bar reads `<folder> › main.py` and `<folder> › src › a.py`. Also open a
  folder through a symlink and confirm its name leads.
