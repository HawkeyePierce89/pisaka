# Git CLI hygiene: optional locks, log format hardening, fetch prompts, checkout terminators, blame attribution

## Overview

Five fixes to how the macOS `GitCLIService` invokes `git`. Each fix is one argument or one environment variable:

1. Reads take no optional lock. A shared global-option prefix in the single launch funnel adds `--no-optional-locks` to every command.
2. User configuration cannot bend the Log's record format. The same prefix carries `-c log.showSignature=false`, and both `--pretty` sites add `--encoding=UTF-8`.
3. `fetch` runs under `GIT_TERMINAL_PROMPT=0`.
4. Both branch checkouts end with `--`.
5. `blame --porcelain` gains `-w -M`.

A new Core source-gating suite pins every argument where `swift test` can see it. An app-layer test runs the real `git` in a temporary repository to prove R4 and R1 against git itself.

Corrections to the ticket's descriptions, found by running git 2.55 locally:

- R2: with `log.showSignature=true`, a signed commit is not dropped. The signature text lands between the previous `%x1e` and the hash, so the record still has six fields, but its hash field becomes `Good "git" signature …\n<hash>`. That breaks the graph's parent link and the `diff-tree` call when the row is selected. As agreed, the fix is the configuration alone, and the Core test pins this real corruption.
- R4: a *local* branch that shares its name with an existing directory already checks out without `--`, because git prefers the branch. The cases that actually break are different:
  - (a) A branch name with no local branch, such as one deleted in the terminal while the switcher's list was stale, that matches a path. `git checkout docs` then silently **restores `docs/` from the index, discarding unstaged edits**, and exits 0. The switcher reports a switch that never happened.
  - (b) A name that exists only as `origin/<name>` and is also a path. Git refuses it with "could be both a local file and a tracking branch".

  With `--`, (a) fails with "invalid reference" and the edits survive, and (b) switches. The app test covers both, plus the ticket's scenario as a regression guard.

## Context

- Files involved:
  - `Sources/Pisaka/GitCLIService.swift`:
    - `runBlocking` is the one `Process` funnel.
    - `commits(filter:limit:root:)` and `headMessage(root:)` are the two `--pretty` sites.
    - `fetch(remote:root:)`, `checkout(branch:root:)`, `createAndCheckout(name:startPoint:root:)` and `blame(fileURL:)` are the other touched sites.
  - `Tests/PisakaCoreTests/CommitParserTests.swift` and `Tests/PisakaCoreTests/BlameParserTests.swift`
  - `Tests/PisakaCoreTests/GitHubSourceGatingTests.swift`: `testTheTailsPullIsFastForwardOnly` counts `GIT_TERMINAL_PROMPT` at 3 today. `strippingComments(_:)` is the repository's literal-keeping scanner.
  - New: `Tests/PisakaCoreTests/GitCLIArgumentSourceGatingTests.swift` and `Tests/PisakaAppTests/GitCLIServiceRepositoryTests.swift`
  - Docs: `docs/architecture/app-git-views.md` (`GitCLIService` entry, the "three calls" paragraph, the blame paragraph), `docs/architecture/core-git.md` (pull paragraph, `Commit`/`BlameParser` entries), `docs/FEATURES.md` (Git Blame bullet, git/terminal section) and `CLAUDE.md` (the list of repository-file suites)
- Related patterns:
  - `GitHubSourceGatingTests` reads `GitCLIService.swift` through `#filePath` with a literal-keeping stripper to pin `pull --ff-only`.
  - `BlameParserTests` already has fixtures for the `previous` and `filename` headers.
  - `PisakaAppTests` uses `@testable import Pisaka`, and `GitCLIService` is internal, so the test can drive it directly.
- Dependencies: none new. The system `git` is already required.

## Development Approach

- **Testing approach**: Regular (code first, then tests).
- Complete each task fully before moving to the next.
- Decisions:
  - **R1 uses `--no-optional-locks` as a global argument, not `GIT_OPTIONAL_LOCKS=0`.**
    - It lives in the one funnel, so every current and future command, read or write, gets it with no call-site opt-in.
    - It is visible in the command line the gating suite reads.
    - It does not force `process.environment` to be assigned on every run. Today the environment is assigned only when an override exists, and the `run` doc comment explains why that matters.
    - Unlike the environment variable, it does not leak into hook processes the commit path spawns.
  - **`-c log.showSignature=false` goes in the same shared prefix, not per site.** It affects only `log`/`show` output, so it is harmless on every other command. Any future `--pretty` site is covered by construction.
  - **`--encoding=UTF-8` is per site**, on both `log` invocations. In `commits` it is placed before `filter.gitArguments()`, because the filter can end with `-- <paths>`.
  - The prefix is one `private static let` in `GitCLIService`, used only by `runBlocking`: `process.arguments = ["git"] + Self.globalOptions + arguments`.
  - **No `-C` on blame**: it is expensive, and it changes what a line's commit means for the file on screen. The choice is recorded in the doc.
  - The known consequence of R1 is accepted and documented: a lock-free `status` does not refresh the index stat cache, so the user's next terminal `git status` does that work.
  - The iOS `LibGit2Service` is untouched.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**
- Gates: `swift test` and `swiftlint --strict` locally. `make test-app` and `make build` run under the pinned Xcode. `make build-ios` runs on CI only, because the iOS 26.3 platform component is not installed locally.

## Implementation Steps

### Task 1: Shared global options and log encoding (R1, R2)

**Files:**
- Modify: `Sources/Pisaka/GitCLIService.swift`
- Modify: `Tests/PisakaCoreTests/CommitParserTests.swift`

- [x] Add `private static let globalOptions = ["--no-optional-locks", "-c", "log.showSignature=false"]` with a doc comment covering: why each option is there; why it is an argument rather than an environment variable; the accepted stat-cache consequence.
- [x] Prepend `globalOptions` in `runBlocking`.
- [x] Add `--encoding=UTF-8` to `commits` (before the filter arguments) and to `headMessage`'s `log -1 --pretty=%B`. Update both doc comments.
- [x] In `CommitParserTests`, add a test that feeds `Commit.parse` two records, the second preceded by signature lines exactly as `log.showSignature=true` emits them (text between the previous `\u{1e}` and the hash). Assert that the second commit parses with a hash field that is not the commit hash and contains the signature text. Its comment explains that this corruption is why the service forces `log.showSignature=false`, and points to the gating suite.
- [x] Run `swift test`: must pass.

### Task 2: Fetch prompt, checkout terminators, blame flags (R3, R4, R5)

**Files:**
- Modify: `Sources/Pisaka/GitCLIService.swift`
- Modify: `Tests/PisakaCoreTests/BlameParserTests.swift`

- [x] `fetch`: `run(["fetch", remote], in: root, environment: ["GIT_TERMINAL_PROMPT": "0"])`. Its doc comment states why: git prompts on `/dev/tty` despite stdin being `/dev/null`, and the serial queue would wedge. It also states that the user's ssh command is never overridden.
- [x] `checkout(branch:root:)` becomes `["checkout", branch, "--"]` and `createAndCheckout` becomes `["checkout", "-b", name, startPoint, "--"]`. Doc comments name the two failure modes the terminator closes (a stale name discarding a same-named path's unstaged edits, and the tracking-branch ambiguity). `checkoutReason` is unchanged.
- [x] `blame`: `["-c", "core.quotePath=false", "blame", "--porcelain", "-w", "-M", "--", name]`. The doc comment records why `-w` and `-M` are used and why `-C` is deliberately absent.
- [x] In `BlameParserTests`, add a fixture shaped like `-M` output for a block moved within the file: several groups with `previous <hash> <same file>` lines; per-group `filename` lines naming the same file; a later group reusing a commit without metadata. Assert that the lines map to the right commits and that the headers are skipped, not special-cased.
- [x] Run `swift test`: must pass.

### Task 3: Source-gating suite for the git command lines (R6)

**Files:**
- Create: `Tests/PisakaCoreTests/GitCLIArgumentSourceGatingTests.swift`
- Modify: `Tests/PisakaCoreTests/GitHubSourceGatingTests.swift`

- [ ] The doc comment is the suite's inventory. It covers: that `GitCLIService.swift` is compiled only by the app target; that every subject here is a string literal, so the suite reads `GitHubSourceGatingTests.strippingComments(_:)` (comments stripped, literals kept), for that stated reason; each rule listed below.
- [ ] R1/R2 funnel rules: `process.arguments` is assigned exactly once; that assignment includes `globalOptions`; `globalOptions` contains `"--no-optional-locks"` and `"log.showSignature=false"`; `Process()` appears once in the file, so there is no second launch path that skips the prefix.
- [ ] R2 site rules: the set of array literals containing `"--pretty` equals the set containing `"--encoding=UTF-8"`, and neither set is empty; `--show-signature` and `log.showSignature=true` never appear.
- [ ] R3: the set of `func` names whose bodies contain `GIT_TERMINAL_PROMPT` is exactly `{fetch, push, pull, commit}`.
- [ ] R4: the checkout array literals are exactly the three expected spellings, two ending in `"--"` plus the existing `HEAD -- path`. No `"checkout"` literal lacks a `"--"`.
- [ ] R5: the blame array contains `"-w"` and `"-M"`, and `"-C"` does not appear in it.
- [ ] Remove the `GIT_TERMINAL_PROMPT == 3` count from `GitHubSourceGatingTests.testTheTailsPullIsFastForwardOnly` and point its comment at the new suite's set-equality rule, so the number is not restated in two places.
- [ ] Run `swift test` and `swiftlint --strict`: must pass.

### Task 4: App-layer test against the real git (R4, R1)

**Files:**
- Create: `Tests/PisakaAppTests/GitCLIServiceRepositoryTests.swift`

- [ ] Add a helper that creates a temporary repository using `Process` (`/usr/bin/env git`, with a local user.name and user.email set) and removes it in `tearDown`.
- [ ] R4 regression guard (the ticket's scenario): with a local branch `docs` and a tracked directory `docs/`, `GitCLIService().checkout(branch: "docs", root:)` leaves the current branch as `docs`.
- [ ] R4 stale-name case: no branch `docs`, a tracked `docs/f` with an unstaged edit. `checkout(branch: "docs")` throws `GitError.checkoutFailed`, and `docs/f` still holds the edit. Without the terminator, git restores the file and exits 0.
- [ ] R4 tracking-ambiguity case: clone a repository whose `origin` has branch `docs` and whose tree has `docs/`. `checkout(branch: "docs")` in the clone succeeds and lands on `docs`.
- [ ] R1: commit a file, then backdate its mtime so the index stat data is stale; read the `.git/index` bytes, call `changedFiles(root:)`, and assert the bytes are unchanged; control, so the test cannot pass vacuously: a plain `git status` run by the helper afterwards does change the index bytes.
- [ ] Run `make test-app`: no new failures beyond the eight pre-existing scale-1.8 layout assertions.

### Task 5: Verify acceptance criteria

- [ ] Run `swift test`: green.
- [ ] Run `swiftlint --strict`: clean.
- [ ] Run `make test-app` under the pinned Xcode: only the eight known failures.
- [ ] Run `make build` (macOS Release) under the pinned Xcode.
- [ ] Confirm `git diff` shows no change under `Sources/Pisaka/iOS/`.

### Task 6: Update documentation

- [ ] `docs/architecture/app-git-views.md`, `GitCLIService` entry: describe the shared global options and their reasons; give every touched command line as it now is (log with `--encoding`, checkout with `--`, blame with `-w -M` and the `-C` refusal, fetch with the prompt flag); change "three calls" to four (fetch, push, pull, commit); state the stat-cache consequence; describe the new gating suite and the app test.
- [ ] `docs/architecture/core-git.md`: reword the pull paragraph's "as every other command" to say that four network- or hook-reaching commands carry the flag; add a note to the `Commit` parser entry about the signature corruption the service prevents; add a note to the `BlameParser` entry about the `-M` fixture.
- [ ] `docs/FEATURES.md`: Git Blame bullet — whitespace-only changes and in-file moves do not take over a line's attribution; git/terminal section — the app's git reads take no index lock, so they never collide with git run in the embedded terminal.
- [ ] `CLAUDE.md`: add `GitCLIArgumentSourceGatingTests` to the list of repository-file suites, and check the file stays under the 60,000-character limit `LintConfigurationTests` enforces.
- [ ] Run `swift test` once more, for `LintConfigurationTests` and the doc pins.

## Post-Completion

- Live check of acceptance criterion 1: on a repository with `log.showSignature=true` and a signed commit, the Log row shows the right hash and selecting it loads its changes.
- Live check of acceptance criterion 2: a branch `docs` and a directory `docs/` switch through the branch switcher. Also check the stale-name case: delete a branch in the terminal, switch to it from the open switcher, and confirm the switch fails with no edits lost.
- Live check of acceptance criterion 3: after a whitespace-only reformat commit, Annotate with Git Blame shows the original authors.
- CI: the iOS build, and the macOS job under the Xcode 26.3 pin.
