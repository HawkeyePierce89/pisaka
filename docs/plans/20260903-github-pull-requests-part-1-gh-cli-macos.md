# GitHub pull requests, part 1 — via the `gh` CLI (macOS only)

## Overview
A sixth bottom-dock panel, **Pull Requests**, plus a bottom-bar indicator, a create sheet and a gated checkout — all of it spoken to GitHub through the user's own `gh` binary. Core composes every argument list and parses every answer; the app only runs processes. The layer is a **reader except for checkout**, which becomes the eighth gated worktree operation.

## Context

### Live facts, verified in this repository (do not re-derive from memory)
  - `gh version 2.99.0 (2026-09-01)` at `/opt/homebrew/bin/gh`; `gh --version` prints `gh version X.Y.Z (date)` on line 1 and a release URL on line 2.
  - **Minimum version is 2.50.0.** `pr checks --json` landed in cli/cli#9079 (merged 2024-05-16); comparing that commit against the tags shows it is first contained in `v2.50.0` (2024-05-29). That is the bound, with the reason recorded beside it.
  - `gh auth status` exits 0 when signed in; its prose goes to **stderr**. Judged by exit status only.
  - **`gh pr checks` exit status is not a failure signal.** Documented "Additional exit codes: 8: Checks pending"; exit 1 additionally means "some check failed" (and `gh help exit-codes` reserves 1 for generic failure, 2 for cancelled, 4 for "requires authentication"). The parser must decide on *stdout parsing succeeding*, never on the exit status, for this one command.
  - `pr list` `--json` field set (verified): `number,title,author,headRefName,baseRefName,isDraft,reviewDecision,url,state,statusCheckRollup`. `author` is an object with `login`, `name`, `id`, `is_bot`. `reviewDecision` is `""` when no review is required.
  - `statusCheckRollup` items carry `__typename` `CheckRun` (`status`, `conclusion`, `name`, `detailsUrl`, `workflowName`, `startedAt`, `completedAt`) or `StatusContext` (`state`, `context`, `targetUrl`).
  - `pr checks --json` field set (verified, exactly nine): `bucket,completedAt,description,event,link,name,startedAt,state,workflow`. `bucket` ∈ `pass|fail|pending|skipping|cancel`.
  - `gh repo view --json defaultBranchRef,nameWithOwner` → `{"defaultBranchRef":{"name":"master"},"nameWithOwner":"…"}`. Per the answered question this is the **seventh command in scope**; the "upstream's branch" default is dropped entirely.
  - `gh pr create` flags in scope: `-t/--title`, `-b/--body`, `-B/--base`, `-d/--draft`. `gh pr checkout <number>`.

### Existing patterns to follow
  - Seam shape: `Sources/PisakaCore/LeetCodeTransport.swift` (Foundation-only request/response values) + `Sources/Pisaka/Platform/LeetCodeURLSessionTransport.swift`.
  - Composed-command precedent: `Sources/PisakaCore/DatabaseQuery.swift`; one-schema-file precedent: `LeetCodeAPI.swift`.
  - Ownership out of the scene: `Sources/Pisaka/DatabaseViewerTabs.swift` (`start(isWriteBlocked:didWrite:)`, Combine subscription owned by the file itself).
  - The writer bracket: `PisakaApp.runBranchOperation(_:)` (`PisakaApp.swift:4099`) — `autosave.suspend()` + `localChanges.beginRevert()`, `openTabSnapshot()` / `openBufferTexts()` synchronously, then `await captureBeforeOperation(.branch, …)` as the first `await`, then the op, then `finishBranchOperation`.
  - Discovery: `Sources/Pisaka/LSPRustToolchainService.swift` — `locateCargo()` (inherited `PATH` → well-known dirs → login-shell `PATH`), `loginShellPath()`, `pathEntries`, `executables(named:in:)`.
  - Model shape: `DatabaseViewerModel` (two generation tokens, "a failure never blanks a good answer", `isWriteInFlight`).
  - Gating suites: `DatabaseViewerSourceGatingTests`, reusing `LSPSourceGatingTests.strippingCommentsAndStringLiterals`.
  - Scripted seam: `Tests/PisakaCoreTests/Support/ScriptedDatabaseService.swift` (keyed answers, unscripted call throws, calls logged, `Gate` for staging).

### Dependencies
None new. `gh` is the user's own binary, discovered at run time. No SwiftPM change beyond the test target's `exclude:`.

## Development Approach
  - **Testing approach**: Regular (code first, then tests) — matching the repository's convention that every behavioural change ships with `PisakaCore` tests.
  - Complete each task fully before moving to the next; `swift test` must be green at the end of every task.
  - Domain logic in `PisakaCore`, Foundation-only. Views thin and untested. `Process` only in `Sources/Pisaka`.
  - Generation tokens captured synchronously before the first `await`.
  - **CRITICAL: every task MUST include new/updated tests.**
  - **CRITICAL: all tests must pass before starting the next task.**

## Implementation Steps

### Task 1: The `gh` seam, the command vocabulary, the version bound and availability
The narrow seam and everything that can be decided before any GitHub data is parsed. Nothing here touches JSON schema.

**Files:**

  - Create: `Sources/PisakaCore/GitHubCLI.swift` — `GitHubCommand` (argument list, working directory, deadline, and the `refreshesExecutableLocation` flag described below), `GitHubCommandResult` (`standardOutput`, `standardError`, `status`), the `GitHubCLITransport` protocol (`run(_:) async throws -> GitHubCommandResult`), `GitHubCLIError` (`notInstalled`, `timedOut(seconds:)`, `launchFailed(message:)`), and the **non-interactive environment overlay** (`GH_PROMPT_DISABLED`/`GH_NO_UPDATE_NOTIFIER`, `NO_COLOR`, `CLICOLOR=0`, `GH_PAGER=cat`, `PAGER=cat`, `GIT_TERMINAL_PROMPT=0`) as a Core value the app merges over the inherited environment.
  - Create: `Sources/PisakaCore/GitHubCommands.swift` — the seven argument lists, byte for byte, each a static factory: version, auth status, open-PR list, `--head` lookup, `pr checks`, `pr create`, `pr checkout`, `repo view`. The `--json` field lists live here as ordered constants shared with the parsers. **The version probe is the one command carrying `refreshesExecutableLocation == true`** — it is the first command of every refresh, and the flag is how the transport is told to re-locate `gh` without the app layer ever spelling `--version` (Task 5's caching rule reads this flag and nothing else).
  - Create: `Sources/PisakaCore/GitHubVersion.swift` — parse `gh version X.Y.Z (…)`, compare, and `GitHubVersion.minimum` = 2.50.0 with the reason (`pr checks --json`, cli/cli#9079, first shipped v2.50.0) in the doc comment.
  - Create: `Sources/PisakaCore/GitHubAvailability.swift` — the four states (`notInstalled`, `tooOld(found:minimum:)`, `notSignedIn`, `ready(version:)`), each with the sentence and the exact next step (`brew install gh`, `gh auth login`), decided purely from the two probes' results.
  - Create: `Tests/PisakaCoreTests/GitHubCommandsTests.swift`, `GitHubVersionTests.swift`, `GitHubAvailabilityTests.swift`.
  - [x] define the seam values, the transport protocol and the non-interactive environment
  - [x] compose the argument lists with their `--json` field lists as shared constants
  - [x] implement version parsing/comparison and pin the 2.50.0 minimum with its reason
  - [x] implement the four-state availability decision including its sentences
  - [x] tests: every argument list byte for byte; **`refreshesExecutableLocation` true for the version probe and false for every other command, asserted by set equality over the factories**; version parse (valid, garbage, prerelease, missing); comparison across major/minor/patch; all four availability states plus the too-old sentence naming both versions
  - [x] run `swift test` — must pass before Task 2

### Task 2: The one schema file — value types, the two strict tables, the parsers, the summary rule
All knowledge of `gh`'s output schema in one place, with closed vocabularies and a typed "the schema changed" error naming the key path.

**Files:**

  - Create: `Sources/PisakaCore/GitHubPullRequest.swift` — `GitHubPullRequest` (number, title, author login, head, base, isDraft, reviewDecision, url, summary), `GitHubCheckRow` (name, workflow, bucket, state, description, link, startedAt, completedAt), and the closed enums: `GitHubCheckStatus`, `GitHubCheckConclusion`, `GitHubStatusContextState`, `GitHubCheckBucket`, `GitHubReviewDecision` (with `.none` for `""`), `GitHubChecksSummary` (`noChecks`, `pending`, `failure`, `success`).
  - Create: `Sources/PisakaCore/GitHubAPI.swift` — **the one schema file**: `GitHubSchemaError.unknownValue(keyPath:value:)` / `.missingKey(keyPath:)` / `.malformed(keyPath:)`; parsers for the PR list (both `__typename`s), the checks list, `repo view`, and the create URL → number; and `GitHubChecksSummary.summarise(_:)`, the summary rule.
  - Create: `Tests/PisakaCoreTests/Fixtures/github/` — real captures from this repository: `pr-list-merged.json` (the four-`CheckRun` rollup captured live), `pr-list-empty.json` (`[]`), `pr-checks.json` (the nine-field rows), `repo-view.json`, plus hand-built `pr-list-mixed-typename.json` and `pr-list-unknown-conclusion.json`.
  - Modify: `Package.swift` — add `Fixtures/github` to the test target's `exclude:` with the same reasoning already recorded there.
  - Create: `Tests/PisakaCoreTests/GitHubAPITests.swift`, `GitHubChecksSummaryTests.swift`.

Summary rule, pinned: **pending** if any job is not finished; **failure** if any finished job failed, was cancelled or timed out; **success** when every job passed or was skipped; **noChecks** when the rollup is empty. A `StatusContext` contributes through its `state`, a `CheckRun` through `status` + `conclusion`, and a mixed array is decided over both.

  - [x] define the value types and the five closed enums with strict decode tables
  - [x] write the parsers and the typed schema error naming the key path
  - [x] implement and document the summary rule
  - [x] capture the fixtures from real `gh` output and list the folder in `Package.swift`'s `exclude:`
  - [x] tests: fixture round-trips for list, checks, repo view and create-URL; every strict table's refusal asserting the key path in the error; the summary rule across all four outcomes; the mixed-`__typename` case; `reviewDecision: ""` mapping to `.none`
  - [x] run `swift test` — must pass before Task 3

### Task 3: `PullRequestModel` — the reader, its tokens and the scripted seam
The main-actor model behind both the panel and the indicator. It re-probes availability on every refresh and never more often.

**Files:**

  - Create: `Sources/PisakaCore/PullRequestModel.swift` — `@MainActor`, `ObservableObject`. Published: `availability`, `pullRequests`, `currentBranchPullRequest`, `checks: [Int: [GitHubCheckRow]]`, `expandedNumber`, `errorMessage`, `isLoading`, `isWriteInFlight`. Two generation tokens (a list token and a per-PR checks token), captured synchronously before each hop. A failure sets `errorMessage` and **never blanks** a good list. `pr checks` is judged on stdout parsing, not on exit status.
  - Create: `Tests/PisakaCoreTests/Support/ScriptedGitHubCLI.swift` — answers keyed by the argument list, a queue per key with a sticky last step, an **unscripted call throws**, every call logged in order, a `Gate` per key so a test can hold a call mid-flight.
  - Create: `Tests/PisakaCoreTests/PullRequestModelTests.swift`.
  - [x] implement the model's read paths: availability probe → list → current-branch lookup → per-row checks on expand
  - [x] wire the two generation tokens and the "a failure never blanks a good list" rule
  - [x] build `ScriptedGitHubCLI` in `Support/`
  - [x] tests: token ordering (a superseded answer is discarded); a failed refresh keeps the previous list and adds a message; availability re-probed on every refresh and not otherwise; `pr checks` exit 8 and exit 1 still parse; an empty `--head` array is "no pull request", not an error; a schema refusal surfaces as the typed error's sentence
  - [x] run `swift test` — must pass before Task 4

### Task 4: The create flow — the base default, push-first, and the one-write rule

**Files:**

  - Create: `Sources/PisakaCore/GitHubCreatePlan.swift` — the sheet's pure half: the default base is the `repo view` answer (read once when the sheet opens, under the model's generation token; on failure the picker is empty, Create disabled, and `gh`'s words are shown); the refusals reuse `PushUnavailableReason.detachedHEAD` / `.noRemote` and their existing sentences; the "uncommitted changes will not be part of the pull request" line; the sentence naming the base that will be used and, for `PushPlan.setUpstream`, the remote the branch will be published to.
  - Modify: `Sources/PisakaCore/PullRequestModel.swift` — `create(...)`: raise `isWriteInFlight`, read `CommitContext`, refuse per the plan, **push first through the existing `GitServicing.push(_:root:)`** on both `PushPlan` branches, then run `pr create` with an always-explicit `--base`, parse the number out of the printed URL, refresh the list, select the new row. Failure publishes trimmed stderr and leaves the caller's fields intact.
  - Modify: `Tests/PisakaCoreTests/PullRequestModelTests.swift`; create `Tests/PisakaCoreTests/GitHubCreatePlanTests.swift`.
  - [x] implement the create plan (base default, refusals, the stated sentences)
  - [x] implement the model's create flow with push-before-create and the write flag
  - [x] tests: the base default comes from `repo view` and is always passed explicitly; a `repo view` failure disables Create; detached HEAD and no-remote refuse with the commit dialog's own sentences; push runs before `pr create` on both `PushPlan` branches (assert call order in the log); a push failure never reaches `pr create`; the new number is parsed from the URL and the row selected; `isWriteInFlight` is up for the whole flow and down on every exit path
  - [x] run `swift test` — must pass before Task 5

### Task 5: The app-side transport and the shared executable locator

**Files:**

  - Create: `Sources/Pisaka/ExecutableLocator.swift` (`#if os(macOS)`) — the one definition of the search: inherited `PATH` → a caller-supplied well-known directory list → the login shell's `PATH` (`-l -c /usr/bin/env`, reading the `PATH=` line), plus `pathEntries` and `executables(named:in:)`, returning the found path **with** the `PATH` that found it. The order and every decision are lifted verbatim from `LSPRustToolchainService`.
  - Modify: `Sources/Pisaka/LSPRustToolchainService.swift` — delegate `locateCargo`/`locateRustAnalyzer`'s directory search and `loginShellPath()` to the helper, passing `~/.cargo/bin` + Homebrew's two prefixes. Observable behaviour and existing tests unchanged. `LSPGoToolchainService` is deliberately left alone (its own directory list and its own decisions; touching it is out of scope, and the gating suite therefore pins **one definition, two callers**).
  - Create: `Sources/Pisaka/GitHubCLIProcessTransport.swift` (`#if os(macOS)`) — the **one** app file that runs `Process` for `gh`. Merges Core's non-interactive overlay over the inherited environment (with the discovered `PATH`), sets `currentDirectoryURL` to the repository root, drains both pipes, enforces the command's deadline (SIGTERM→SIGKILL, exactly as `LSPRustToolchainService` does), and maps "not found" / "timed out" to `GitHubCLIError`. **Located at most once per refresh**, and this is the file's stated rule, carried in its doc comment: the transport caches the located `gh` path **together with the `PATH` that found it**, and re-locates only when (a) the command carries `refreshesExecutableLocation` — the version probe, which is the first command of every refresh, so an install from the embedded terminal is picked up by the very next refresh — or (b) the cached path no longer exists on disk, or (c) launching it fails. A refresh is three or four commands; one login-shell spawn per refresh is the budget, not one per command. The cache is *not* an app-run cache: it never survives a refresh's own version probe.

  - [x] extract the shared locator and repoint the Rust service at it
  - [x] implement the transport with the deadline, the environment overlay and the escalating teardown
  - [x] implement the per-refresh location cache with its three re-locate triggers and write the doc comment stating the rule
  - [x] tests: the Rust service's existing suites still pass unchanged (no new Core tests are possible here — `Process` cannot be linked from the test target; the rules are pinned statically in Task 8)
  - [x] run `swift test` — must pass before Task 6

### Task 6: The panel case, the coordinator, and the eighth gated operation

**Files:**

  - Modify: `Sources/PisakaCore/BottomPanel.swift` — add `case pullRequests` with its doc comment.
  - Modify: `Sources/PisakaCore/LocalHistorySnapshot.swift` — add `case pullRequest = "pullrequest"` (explicit raw value: the tag must be lowercase ASCII with no `-`, which the existing doc comment states and the codec relies on).
  - Create: `Sources/Pisaka/PullRequestCoordinator.swift` (`#if os(macOS)`) — the `DatabaseViewerTabs` analogue: owns the `PullRequestModel` and the transport, is wired once from the scene with `start(root:branchSwitcher:isWriteBlocked:runCheckout:didWrite:)`, **owns the feature's refresh triggers** (Task 7 wires the last of them), forwards the gate question, and is the **one site** through which a checkout reaches the writer bracket.
  - Modify: `Sources/Pisaka/PisakaApp.swift` — a few lines only: one `@StateObject`, one `start(…)` block in the existing start-once section, one View-menu item, and generalising `runBranchOperation(_:)` to take the Local History event and an op returning `String?` (`nil` = success) so the branch callers keep passing `.branch` while the coordinator passes `.pullRequest`. Every line added is measured against the `file_length` / `type_body_length` ceilings.
  - Modify: `Tests/PisakaCoreTests/BottomPanelTests.swift`, `LocalHistorySnapshotTests.swift`; create `Tests/PisakaCoreTests/PullRequestCheckoutTests.swift` (the model's half of the checkout: the gate is consulted before anything is sent, the write flag is raised, the request is handed out exactly once).
  - Modify: `.swiftlint.yml` and `Tests/PisakaCoreTests/LintConfigurationTests.swift` if and only if a measured ceiling moves.
  - [x] add the panel case and the Local History label
  - [x] write the coordinator with its `start(…)` wiring and the single checkout call site
  - [x] generalise `runBranchOperation` and wire the scene
  - [x] tests: the new `BottomPanel` case toggles like the others; the new event's tag round-trips through the layout codec and is lowercase with no `-`; the checkout consults the gate before sending, refuses while a write is in flight, and reports `gh`'s stderr verbatim on failure
  - [x] run `swift test` — must pass before Task 7

### Task 7: The panel, the sheet, the indicator and the refresh triggers
Thin, untested by convention. **`PisakaApp.swift` is not touched in this task** — it already sits at its measured ceiling and the ticket forbids growing it; every refresh trigger lands in the coordinator or in the feature's own view.

**Files:**

  - Create: `Sources/Pisaka/PullRequestsPanelView.swift` (`#if os(macOS)`) — the not-ready states with their exact next step; rows (number, title, author, head → base, draft marker, review decision, checks summary); **Checkout** and **Open in browser** per row (the browser only ever on an explicit gesture); an expandable per-job checks list with each job's link; a **New Pull Request** button and a refresh button. New/Checkout/refresh all disabled while `isWriteInFlight`. The **panel-shown trigger is one `.onAppear` call to `coordinator.panelShown()`** here — the panel's own view is where "the panel became visible" is actually known, and `bottomPanel` is `@State` in the scene, not a publisher.
  - Create: `Sources/Pisaka/NewPullRequestSheet.swift` (`#if os(macOS)`) — the commit dialog's shape: title pre-filled from `GitServicing.headMessage(root:)`'s subject, body, base picker over the local branch list defaulting to the `repo view` answer, a Draft checkbox, the stated base sentence, the publish-to-remote sentence, and the uncommitted-changes line. Failure leaves the sheet open with its fields intact.
  - Create: `Sources/Pisaka/PullRequestIndicatorView.swift` (`#if os(macOS)`) — beside the branch switcher: nothing when there is no open pull request for the current branch and nothing on detached HEAD; otherwise `#N` plus the summary state. Clicking opens the panel with that row expanded. It reads the same model.
  - Modify: `Sources/Pisaka/PullRequestCoordinator.swift` — the **branch-change trigger**: `start(…)` takes the `BranchSwitcherModel` and the coordinator subscribes to its published `current` (Combine, duplicates dropped), refreshing on each distinct branch, exactly as `DatabaseViewerTabs` subscribes to its own publisher. Plus `panelShown()` and the post-operation refreshes (a created pull request, a completed checkout). Event-driven only — no timer, no polling.
  - Modify: `Sources/Pisaka/ContentView.swift` — the sixth bar button, the `panelContent(_:)` branch, and the indicator in `bottomBar`. The panel root states **no** minimum height (`BottomPanelSourceGatingTests`' rule, which is pinned by set equality against the switch's case labels and will otherwise fail).
  - [ ] build the panel, the sheet and the indicator
  - [ ] wire the bar button, the panel branch and the indicator in `ContentView`
  - [ ] put the branch-change subscription and the post-operation refreshes in the coordinator, and the panel-shown trigger in the panel view
  - [ ] tests: extend `BottomPanelSourceGatingTests`' per-panel inventory to the new case so the new panel root is checked for a stated minimum height like the other five
  - [ ] run `swift test` — must pass before Task 8

### Task 8: The source-gating suite

**Files:**

  - Create: `Tests/PisakaCoreTests/GitHubSourceGatingTests.swift` — reads the sources through `#filePath` and matches against **comment- and literal-stripped** text via `LSPSourceGatingTests.strippingCommentsAndStringLiterals`, pinning by set equality where the rule is an inventory. Rules pinned:
  - `Process` for `gh` in exactly one app file (`GitHubCLIProcessTransport.swift`), and Core names `Process` nowhere.
  - Every new app-side file is `#if os(macOS)`-gated, by set equality over the feature's file list.
  - The iOS app names none of it (no `PullRequest…`, no `GitHubCLI…` under `Sources/Pisaka/iOS/`).
  - **No `gh` argument is spelled anywhere in the app layer** — `--json`, `pr list`, `pr checks`, `pr create`, `pr checkout`, `auth status`, `repo view`, `--draft`, `--base`, `--version` appear only in `Sources/PisakaCore/GitHubCommands.swift`.
  - The checkout reaches the writer bracket through exactly one site, and no other file under the feature names `autosave.suspend`/`localChanges.beginRevert`.
  - The discovery helper has **one definition and two callers**.
  - **The refresh triggers live in the coordinator and the panel view only**: `PullRequestCoordinator.swift` holds the branch subscription and the post-operation refreshes, `PullRequestsPanelView.swift` holds the panel-shown call, and `PisakaApp.swift` names no refresh trigger at all.
  - **No polling — scoped, with one stated exception.** The rule bans `Timer`, `DispatchQueue.asyncAfter` and `Task.sleep` in the feature's **Core files and its three views** (`PullRequestsPanelView`, `NewPullRequestSheet`, `PullRequestIndicatorView`), where any sleep or timer would *be* polling. `GitHubCLIProcessTransport.swift` is the **one stated exception**, named as such in the suite's doc comment: its command deadline and its SIGTERM→SIGKILL teardown grace are lifted verbatim from `LSPRustToolchainService` (a `Thread.sleep` loop plus `DispatchSemaphore.wait(timeout:)`) and are a per-command bound, not a repeating read.

  - [ ] write the suite with a doc comment carrying the full inventory (the repository's convention) and the transport's stated exception
  - [ ] run `swift test` — must pass before Task 9

### Task 9: Verify acceptance criteria
  - [ ] run `swift test` — full suite green
  - [ ] run `swiftlint --strict` from the repository root — clean
  - [ ] run `xcodegen generate`
  - [ ] run the macOS build (`xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`)
  - [ ] run the iOS Simulator build (`-destination 'platform=iOS Simulator,name=iPhone 17 Pro'`)
  - [ ] launch the built app once and confirm it comes up (the dyld gate CI runs)

### Task 10: Update documentation
  - [ ] create `docs/architecture/core-github.md` covering both halves with numbered decisions G1–Gn: the narrow seam (G1), the one schema file and the two closed tables (G2), the checks-exit-status rule (G3), the 2.50.0 minimum and why (G4), the non-interactive environment (G5), "the app never composes `owner/repo`" and why that makes GitHub Enterprise work for free (G6), **discovery and its per-refresh cache — located at most once per refresh, re-located when the version probe runs (via `refreshesExecutableLocation`), when the cached path is gone, or when a launch fails, so a refresh costs one login-shell spawn rather than four and an install from the embedded terminal still lands on the next refresh (G7)**, the four availability states (G8), event-driven freshness, where each trigger lives and the two tokens (G9), one write in flight (G10), push-before-create and the `repo view` base (G11), the eighth gated operation and its capture-first order (G12)
  - [ ] add the index lines to `CLAUDE.md` (Core files under a new `core-github.md` heading, app files under it too) plus **one** invariant paragraph — the layer is a reader except for checkout, the eighth gated operation — keeping the file well under its size target
  - [ ] add the feature to `README.md` and `docs/FEATURES.md`
  - [ ] record any moved lint ceiling in `docs/architecture/style-lint.md` with the measured number and the reason

## Post-Completion (manual, by the user)
Manual acceptance on this repository in a DEBUG build, per the ticket:

  - Panel opens with the three not-ready states reachable: rename `gh` (not installed), `gh auth logout` (not signed in), and the too-old state staged through the version parser's tests at minimum.
  - The list shows an open pull request with a live checks summary; expanding a row shows its per-job checks with working links.
  - New Pull Request from a fresh branch publishes the branch, creates the pull request and lists it — without opening a browser.
  - Checkout of that pull request from `master` switches branch with open tabs resynced (clean tab reloads, edited tab reconciles with a beep, deleted file force-closes).
  - The indicator shows `#N` on that branch and nothing on `master`; clicking it opens the panel with that row expanded.

## Out of scope
Merge and everything it drags in (pull, the local branch after a merge, waiting on checks); review comments and approvals; issues; any iOS surface; any HTTP or token handling in the app; deleting branches; editing remotes; auto-opening a browser; polling of any kind.
