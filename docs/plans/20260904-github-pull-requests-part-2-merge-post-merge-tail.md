# GitHub pull requests, part 2 — merge, the post-merge tail, and part 1's leftovers (macOS only)

## Overview

Close the loop part 1 opened. From the Pull Requests panel a row can be **merged**
through a small sheet (method, subject, optional body), always guarded by
`--match-head-commit` with the head commit the row was drawn from; when the row is
not mergeable yet *only because checks are still running*, the same sheet arms a
**bounded, visible, cancelable wait** that re-reads **the row itself** every 30 s
for at most 30 min and merges the moment the same rule that enables Merge says so.
When the merged pull request's head is the checked-out branch, a **post-merge tail**
switches to the base branch through the existing writer bracket and then **pulls it
`--ff-only`** — the app's ninth gated worktree operation, reached through a new
`GitServicing.pull` member and a new `LocalHistoryEvent.pull`. Part 1's two stale
documentation lines are fixed, and part 1's manual DEBUG pass is carried into this
ticket's post-completion list.

**One rule, one table.** The wait does not read `pr checks`: the checks bucket table
cannot see `mergeable` or `mergeStateStatus`, so checks can turn green while the row
is still `BLOCKED`, `BEHIND` or `UNKNOWN`, and a wait deciding "green" from a second
table would hand a merge to a plan that refuses it. The wait re-reads the row and
lets `GitHubMergePlan` decide every tick — the same value the button is drawn from.

Everything stays inside part 1's rules: Core decides, views draw, `Process` only in
`Sources/Pisaka`, every `gh` argument spelled in `GitHubCommands` alone, generation
tokens captured before the hop, the writer gate consulted and never raised by any
file under the feature.

## Context

Core (`Sources/PisakaCore/`), all existing:

- `GitHubCommands.swift` — the whole `gh` vocabulary; seven commands, eight
  factories, three ordered `--json` field lists, four deadlines.
- `GitHubAPI.swift` — the one schema file; closed tables refuse with the key path.
- `GitHubPullRequest.swift` — the closed vocabularies and the values the surfaces read.
- `GitHubCreatePlan.swift` — the create sheet's pure half; the shape the merge plan copies.
- `PullRequestModel.swift` — the reader with two writes; three generation tokens,
  one message slot with an `ErrorSource`, `isWriteInFlight`, `isWriteBlocked`, `runCheckout`.
- `GitServicing.swift` / `GitError.swift` — the async git protocol, optional members
  defaulted to `throw .gitUnavailable`.
- `BranchSwitcherModel.swift` — `switchTo(_:originGeneration:)` and
  `checkoutRemote(_:originGeneration:)`, whose `remoteCheckoutDecision` already does
  git's DWIM (same-named local when it exists, else a tracking branch from the remote ref).
- `LocalHistorySnapshot.swift` — `LocalHistoryEvent`, whose `tag` is on-disk vocabulary.
- `LeetCodeJudgeModel.swift` — the poll shape this part's wait inherits (L18):
  `now`/`sleep` seams, a deadline rather than an attempt count, a token checked after
  every suspension.

App (`Sources/Pisaka/`, all `#if os(macOS)`):

- `PullRequestCoordinator.swift` — owns the model and the transport, holds the refresh
  triggers, is the one site a write reaches the scene's bracket.
- `PisakaApp.swift` — `runBranchOperation(_:_:)`, the shared bracket (7 bracket sites,
  8 gated operations today); `switchBranch`, `confirmBranchSwitchIfDirty`.
- `PullRequestsPanelView.swift`, `NewPullRequestSheet.swift`,
  `PullRequestIndicatorView.swift`, `GitHubCLIProcessTransport.swift`, `GitCLIService.swift`.

Tests: `GitHubCommandsTests`, `GitHubAPITests`, `GitHubCreatePlanTests`,
`PullRequestModelTests`, `PullRequestCheckoutTests`, `GitHubSourceGatingTests`,
`LocalHistorySourceGatingTests`, `LocalHistorySnapshotTests`, `GitErrorTests`,
`LintConfigurationTests`; `Support/ScriptedGitHubCLI.swift` (answers keyed by the
argument list, sticky last step, a `Gate` per key scopable to one call);
`Fixtures/github/` with its own README and re-recording procedure.

Docs: `docs/architecture/core-github.md` (G1–G12), `core-git.md`,
`core-local-history.md`, `app-shell.md`, `app-window.md`, `style-lint.md`,
`CLAUDE.md`, `README.md`, `docs/FEATURES.md`, `.swiftlint.yml`.

New files this part adds:

- Core: `GitHubMergePlan.swift`, `PullRequestMergeWait.swift`.
- App: `PullRequestMergeSheet.swift`.
- Tests: `GitHubMergePlanTests.swift`, `PullRequestMergeTests.swift`,
  `PullRequestMergeWaitTests.swift`.

(All three source names carry an existing `GitHubSourceGatingTests.filePrefixes`
prefix, so they fall under the feature's rules the moment they exist.)

## Development Approach

- **Testing approach**: Regular (code first, then tests) — except the merge-enabled
  table and the wait's four endings, which are written test-first as tables.
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: `swift test` must pass before starting the next task.**
- No brand or product names of other tools anywhere; GitHub and `gh` are the subject
  and may be named.

## Implementation Steps

### Task 1: The grown wire — fields, tables, and the two new factories

**Intent.** Teach the schema file the three facts a merge decision needs
(`headRefOid`, `mergeable`, `mergeStateStatus`), teach `repo view` the repository's
merge policy, and add the two new commands: the merge itself, and the **one-row
re-read the wait polls**.

**Why `pr view <n>` rather than `pr list --head <branch>`.** `--head` names a
*branch*, not a pull request: a fork's head branch can carry the same name as
another one, and `--limit 1` then returns whichever GitHub orders first, so the
number check would turn an ordinary case into a stop with nothing to say. Addressing
by number is exact, returns one object, and needs no discard rule. It also answers
for a pull request that is no longer open — which is exactly the "someone else
merged it" ending the wait must recognise — where a `--head` list would just come
back empty.

**Files:**

- Modify: `Sources/PisakaCore/GitHubCommands.swift`,
  `Sources/PisakaCore/GitHubPullRequest.swift`, `Sources/PisakaCore/GitHubAPI.swift`
- Modify: `Tests/PisakaCoreTests/GitHubCommandsTests.swift`,
  `Tests/PisakaCoreTests/GitHubAPITests.swift`,
  `Tests/PisakaCoreTests/Fixtures/github/*` and its `README.md`

- [x] grow `pullRequestFields` with `headRefOid`, `mergeable`, `mergeStateStatus`,
      and `repositoryFields` with `mergeCommitAllowed`, `squashMergeAllowed`,
      `rebaseMergeAllowed`, `viewerDefaultMergeMethod`, `deleteBranchOnMerge`
- [x] add three closed tables in `GitHubPullRequest.swift` — `GitHubMergeability`
      (`MERGEABLE`/`CONFLICTING`/`UNKNOWN`), `GitHubMergeStateStatus`
      (`DIRTY`/`UNKNOWN`/`BLOCKED`/`BEHIND`/`UNSTABLE`/`HAS_HOOKS`/`CLEAN`) and
      `GitHubMergeMethod` (`MERGE`/`SQUASH`/`REBASE`) — each refusing an unknown word
      with its key path like every other table
- [x] carry `headRefOid`, `mergeable`, `mergeStateStatus` on `GitHubPullRequest` and
      the four merge-policy values on `GitHubRepository`; parse them in `GitHubAPI`
      under the existing accessors
- [x] add `GitHubCommands.mergePullRequest(...)` — `pr merge <n>`, exactly one of
      `--merge`/`--squash`/`--rebase`, `--match-head-commit <oid>` always, `--subject`
      and (only when non-empty) `--body` for the two commit-producing methods and
      **neither for rebase** (GitHub composes no commit there), never `--admin`, never
      `--auto`, never `--delete-branch`; deadline `gitNetworkDeadline`, working
      directory the root
- [x] add `GitHubCommands.pullRequest(number:root:)` — `pr view <n> --json
      <pullRequestFields>`, `networkDeadline`, working directory the root — the wait's
      one read; the existing `pullRequest(forHeadBranch:root:)` is untouched and stays
      the indicator's
- [x] `GitHubAPI.pullRequest(fromViewJSON:)` — the **same row decoder** the list parser
      uses, applied to one object instead of an array element, so there is one schema
      and one set of tables
- [x] re-record the verbatim fixtures with the grown field lists per the fixtures'
      README, adding a `pr-view.json` for the single-object shape; if `gh` is not
      available or not signed in on the machine, extend the recorded bodies by hand
      with the new keys and say so honestly in the README's provenance table (a
      re-record then joins the post-completion list)
- [x] extend the authored fixtures so an unknown `mergeable`/`mergeStateStatus` value
      throws `unknownValue` naming its key path
- [x] write tests for this task: every `pr merge` argument list byte for byte in each
      method, with and without a body, and the three absences asserted; the `pr view`
      argument list; the grown field lists; the three tables including their refusals;
      the view parser reading the same values as the list parser from the same row
- [x] run `swift test` — must pass before Task 2

### Task 2: `GitHubMergePlan` — when Merge is enabled, and what it says when it is not

**Intent.** The pure half of the merge sheet, in `GitHubCreatePlan`'s shape: one value
read from both sides — the button, the model's refusal **and every tick of the wait** —
so they cannot disagree.

**Files:**

- Create: `Sources/PisakaCore/GitHubMergePlan.swift`
- Create: `Tests/PisakaCoreTests/GitHubMergePlanTests.swift`

- [x] the enabled rule: not a draft, `mergeable == MERGEABLE`, `mergeStateStatus` in
      `CLEAN`/`HAS_HOOKS`/`UNSTABLE`, and the checks summary `success` or `noChecks`;
      every other combination is a typed refusal carrying the sentence shown (draft,
      conflicts, blocked by GitHub's rules, behind the base, checks still running,
      checks failed, and `UNKNOWN` mergeability's "GitHub has not finished computing
      mergeability — refresh")
- [x] each refusal answers **two properties of its own**, so no other file re-derives
      them: `isArmable` (may a wait be armed from this state — checks still running
      alone) and `mayResolveByWaiting` (checks still running **and** unknown
      mergeability — the two states a later tick can leave); everything else is a state
      waiting cannot change
- [x] the allowed merge methods (from the repository's three flags, in a stated order),
      the default (the viewer's, falling back to the first allowed), and "exactly one
      allowed ⇒ no picker" as a property of the plan
- [x] the sheet's stated lines: the pre-filled subject `<title> (#N)`, the
      `deleteBranchOnMerge` line when GitHub has it on, and the tail line — "After
      merging, Pisaka will switch to “<base>” and pull it" when the head is the
      checked-out branch, nothing when it is not
- [x] write tests for this task: the enabled rule across every combination of the four
      inputs, each refusal's sentence, `isArmable`/`mayResolveByWaiting` per refusal,
      the method list/default/no-picker rule, and the subject/notes/tail sentences
- [x] run `swift test` — must pass before Task 3

### Task 3: The merge write in `PullRequestModel`

**Intent.** The feature's third write, under the one-write rule, refusing on the same
gate the checkout consults, publishing `gh`'s own words in the one message slot under
a source of its own.

**Files:**

- Modify: `Sources/PisakaCore/PullRequestModel.swift`
- Create: `Tests/PisakaCoreTests/PullRequestMergeTests.swift`

- [ ] a fourth generation token for the merge sheet's own read and its write, bumped in
      `prepareMerge(_:)`, in `merge(...)` and in `clearRows()` beside the create's
- [ ] `prepareMerge(number:)` reads `repo view` and publishes the plan; a failed read
      leaves no plan, Merge disabled and `gh`'s words in the slot, exactly as the create
      sheet's does; `dismissMerge()` clears only the merge's own sentence
- [ ] `merge(...)`: refuses on `isWriteInFlight`, on `isWriteBlocked()` with a sentence
      of its own, on a not-ready `gh`/absent root, and on a plan that re-decides as not
      enabled from the row in hand; raises and lowers `isWriteInFlight` on every exit
      path; composes the command with the `headRefOid` the row was drawn from
- [ ] success refreshes the list (the merged row leaves it, and the indicator clears
      through the ordinary refresh) and answers a `MergeOutcome` naming whether the tail
      is owed and into which base branch; failure keeps the row and says why
- [ ] the tail's **one refusal sentence lives here as a constant** — a base branch that
      is neither a local ref nor an `origin/<base>` in the branch widget's list, which
      is the only case `checkoutRemote`'s DWIM cannot resolve — so the tail's refusal is
      testable without a view
- [ ] write tests for this task: the argument list actually sent (through
      `ScriptedGitHubCLI`), each refusal, the one-write rule across merge/create/
      checkout, the message slot's source rules, and the outcome's tail answer
- [ ] run `swift test` — must pass before Task 4

### Task 4: `PullRequestMergeWait` — the bounded, visible, cancelable wait

**Intent.** The one deliberate exception to "no polling", in `LeetCodeJudgeModel`'s
shape (L18): a companion `@MainActor` model owned by `PullRequestModel`, with its own
token and its own seams, so the whole state machine runs deterministically in
`swift test` and adds no wall-clock time to it.

**What it polls, and what decides.** Each tick runs
`GitHubCommands.pullRequest(number:root:)`, parses the row through
`GitHubAPI.pullRequest(fromViewJSON:)`, and hands it to `GitHubMergePlan` — the same
value the button is drawn from. **No `pr checks` anywhere in the wait.** The plan's
answer is the whole decision table:

- enabled → merge, with `--match-head-commit` against **this tick's** `headRefOid`
- refusal with `mayResolveByWaiting` (checks still running, unknown mergeability) →
  sleep and poll again
- `checksFailed` → stop, with that refusal's sentence, merging nothing
- any other refusal (draft, conflicts, blocked, behind) → stop, with that refusal's own
  sentence, because waiting cannot change it
- a row that is no longer open (someone else merged or closed it) → stop with its own
  sentence, as the "row left the list" cancellation

**Files:**

- Create: `Sources/PisakaCore/PullRequestMergeWait.swift`
- Modify: `Sources/PisakaCore/PullRequestModel.swift`
- Create: `Tests/PisakaCoreTests/PullRequestMergeWaitTests.swift`

- [ ] named constants `pollInterval = 30` and `deadline = 30 * 60`, an injectable `now`
      clock and an injectable `sleep` seam, and a generation token checked after every
      suspension
- [ ] one armed wait per repository: what is armed (number, title, method, subject,
      body, the head the arm was made against), the elapsed time published at each poll
      tick — the sheet and the row read it, and no view runs a clock of its own
- [ ] exactly four endings: the merge running (the enabled branch above), a stop the
      plan named (a failing check, or a refusal waiting cannot change, or a row no
      longer open), the deadline, and cancellation — Cancel, a project switch, quit,
      arming another wait
- [ ] the head guard needs no rule of its own: `--match-head-commit` carries the head
      read on the same tick, so a push landing between that read and the merge is
      GitHub's refusal in GitHub's words, which stops the wait and shows them
- [ ] while armed, other rows' Merge buttons are disabled; reads, Checkout and Create
      stay available, and `isWriteInFlight` is raised only for the merge itself
- [ ] write tests for this task: the two constants, the sleep as a seam (no wall clock
      in the suite), each of the four endings, that no tick composes a `pr checks`
      command, a poll invalidated in flight by a moved token, the plan-driven table
      above tick by tick (keep-waiting vs. stop-with-this-sentence), and the merge
      carrying the tick's head plus `gh`'s refusal when the head moved after that read
- [ ] run `swift test` — must pass before Task 5

### Task 5: `GitServicing.pull` and `LocalHistoryEvent.pull`

**Intent.** The two Core pieces the tail needs, each with its stated default.

**Files:**

- Modify: `Sources/PisakaCore/GitServicing.swift`, `Sources/PisakaCore/GitError.swift`,
  `Sources/PisakaCore/LocalHistorySnapshot.swift`, `Sources/Pisaka/GitCLIService.swift`
- Modify: `Tests/PisakaCoreTests/GitErrorTests.swift`,
  `Tests/PisakaCoreTests/LocalHistorySnapshotTests.swift`

- [ ] `func pull(root: URL) async throws`, documented as `--ff-only` and nothing else,
      defaulted in the protocol extension to `throw GitError.gitUnavailable` (iOS is
      left at the default: libgit2 gains nothing in this part)
- [ ] a `GitError.pullFailed(reason:)` case carrying git's own words, with its
      `errorDescription`
- [ ] `GitCLIService.pull` — `["pull", "--ff-only"]` on the serial queue under
      `GIT_TERMINAL_PROMPT=0`, git's trimmed stderr as the reason
- [ ] `LocalHistoryEvent.pull` with the lowercase tag `pull` and its own title
      ("Before Pull"), stated as its own event rather than `branch`
- [ ] write tests for this task: in `GitErrorTests` — the new case's sentence and that
      the protocol default throws `gitUnavailable` (the suite that already asserts the
      defaults); in `LocalHistorySnapshotTests` — the event's tag round-trip plus the
      `allCases` coverage that suite already asserts
- [ ] run `swift test` — must pass before Task 6

### Task 6: The bracket, the tail, and the coordinator's orchestration

**Intent.** The pull becomes the app's **ninth gated operation** by riding the existing
shared bracket as a third caller — the bracket already takes a Local History event and
already does the suspend/snapshot/capture/resync/refresh work, so the number of bracket
*sites* stays seven while the operations become nine. What grows is the coordinator,
which owns the tail's order; `PisakaApp` gains only the completion the ordering
genuinely needs.

**Files:**

- Modify: `Sources/Pisaka/PisakaApp.swift`, `Sources/Pisaka/PullRequestCoordinator.swift`
- Modify: `Tests/PisakaCoreTests/PullRequestMergeTests.swift` (Core-visible halves)

- [ ] `runBranchOperation` gains an optional completion called on both paths, so a caller
      can order two bracketed operations without the scene knowing what they are; the
      scene hands the bracket over once, still through `pullRequests.start(…)`, now as a
      three-argument closure (event, operation, completion)
- [ ] the coordinator gains the three bracket call sites — the checkout
      (`.pullRequest`), the tail's branch switch (`.branch`) and the tail's pull
      (`.pull`) — and no file under the feature names `autosave` or `localChanges`
- [ ] the tail's switch follows the branch widget's own list, with the refresh generation
      pinned synchronously: a **local** ref named `<base>` goes through
      `branchSwitcher.switchTo`; otherwise an `origin/<base>` in the list goes through
      `branchSwitcher.checkoutRemote`, whose DWIM already picks a same-named local or
      creates the tracking branch; **only when neither is listed** does the tail stop
      with the constant from Task 3
- [ ] the tail runs **only** when the merged pull request's head is the checked-out
      branch, in order, stopping at the first failure with *that step's* sentence and
      never reporting the merge as failed; the same dirty-tree confirmation the branch
      widget asks is asked before the switch
- [ ] the wait is cancelled on a project switch and on `terminateNow()`
- [ ] measure `PisakaApp.swift`'s new `file_length`/`type_body_length` and record the
      bump in `.swiftlint.yml`'s comments (Task 9 carries it into `style-lint.md` and
      `core-github.md`)
- [ ] write tests for this task: the tail's order and its stop-at-first-failure rule,
      and the three switch cases (local ref, remote-only ref, neither), exercised
      through Core's own seams with a scripted bracket runner
- [ ] run `swift test` — must pass before Task 7

### Task 7: The surfaces — the merge sheet, the row's Merge button, the waiting state

**Intent.** Thin views that draw Core's answers and decide nothing: the sheet in the
create sheet's shape, the row's second action beside Checkout, and the wait made
visible where the reader is looking.

**Files:**

- Create: `Sources/Pisaka/PullRequestMergeSheet.swift`
- Modify: `Sources/Pisaka/PullRequestsPanelView.swift`,
  `Sources/Pisaka/PullRequestCoordinator.swift`

- [ ] the sheet: the method picker (absent when the repository allows exactly one), the
      pre-filled subject, the optional body (both hidden for Rebase, which composes no
      commit), the stated lines — what will be merged, the tail or its absence, and the
      remote-branch-deletion note when GitHub has it on — and the one message slot
      scoped to the merge
- [ ] the button reads **Merge** when the plan allows it and **Merge when checks pass**
      when the plan's refusal is `isArmable`; every other refusal disables it under its
      sentence
- [ ] the row gains Merge beside Checkout, disabled while any of this feature's writes is
      in flight or another row's wait is armed; the armed row shows its waiting state
      (elapsed, Cancel) and survives the panel being hidden
- [ ] the indicator needs no new action: its click already opens the panel with that row
      expanded, which is where Merge lives
- [ ] no view names a `gh` argument, runs a clock, or decides an enablement rule
- [ ] write tests for this task: none are view tests by convention — instead assert the
      plan-derived button label and the disable terms in `GitHubMergePlanTests` /
      `PullRequestMergeWaitTests` so the view has nothing left to decide
- [ ] run `swift test` — must pass before Task 8

### Task 8: The gating suites

**Files:**

- Modify: `Tests/PisakaCoreTests/GitHubSourceGatingTests.swift`,
  `Tests/PisakaCoreTests/LocalHistorySourceGatingTests.swift`,
  `Tests/PisakaCoreTests/LintConfigurationTests.swift`

- [ ] the file inventories gain the three new files; the view list gains the sheet
- [ ] the `gh` vocabulary gains `--squash`, `--merge`, `--rebase`, `--subject`,
      `--match-head-commit` and the `pr merge` / `pr view` subcommands, banned in the app
      layer and required in `GitHubCommands.swift`; the counts become **ten factories
      over nine subcommands** (`pr list` still two) — the ticket's "ninth factory" is
      ninth *and* tenth, because the wait reads the row by number instead of `pr checks`
- [ ] the writer-bracket rule is restated for three operations: the scene hands the
      bracket over once, the coordinator is the only file that names it, and the pull
      reaches it through exactly one site
- [ ] the no-polling ban gains its **second stated exception**, scoped to
      `PullRequestMergeWait.swift` and pinned there: the interval and the deadline are
      named constants, the sleep is exactly one injectable seam, no `Timer` and no
      `asyncAfter`, and nothing else in Core or in the four views may sleep
- [ ] `LocalHistorySourceGatingTests` is updated for the ninth operation: seven bracket
      sites serving nine operations, with the alternation rule unchanged and its message
      saying so
- [ ] `LintConfigurationTests` is updated for whatever Task 6 measured
- [ ] run `swift test` — must pass before Task 9

### Task 9: Documentation, and part 1's two leftover lines

**Files:**

- Modify: `docs/architecture/core-github.md`, `core-git.md`, `core-local-history.md`,
  `app-shell.md`, `app-window.md`, `style-lint.md`, `CLAUDE.md`, `README.md`,
  `docs/FEATURES.md`

- [ ] `core-github.md` gains the new decisions after G12 — the merge and its
      `--match-head-commit` guard, the enabled rule and its sentences, the wait as the
      stated polling exception **and its one-rule-one-table decision** (why it reads the
      row by number and not `pr checks`, and why `pr view <n>` rather than a `--head`
      list), and the post-merge tail as the ninth gated operation — plus per-file entries
      for the three new files
- [ ] fix `app-window.md`'s `arrow.triangle.pull` sentence: the bar button is
      deliberately `arrow.triangle.merge`, and `ContentView` says why
- [ ] fix `core-github.md`'s "the two files that were only touched" paragraph: the stale
      1859/1861 and 1843/1845 numbers become the measured ones, in line with
      `.swiftlint.yml` and `style-lint.md`, and carry whatever this part moved them to
- [ ] `core-git.md` gains the `pull` member; `core-local-history.md` and `app-shell.md`
      gain the ninth operation and the `pull` event; `CLAUDE.md`'s invariant paragraphs
      are updated (nine gated operations, the wait as the stated polling exception) —
      index lines only, no per-file essays
- [ ] `README.md` and `docs/FEATURES.md` gain the feature and its limits (no `--admin`,
      no server-side auto-merge, no branch deletion, `--ff-only` only)
- [ ] run `swift test` — must pass before Task 10

### Task 10: Verify acceptance criteria

- [ ] `swift test` green
- [ ] `swiftlint --strict` clean from the repository root
- [ ] `xcodegen generate`, then the macOS build and the iOS build both green
- [ ] confirm no wall-clock time was added to the suite by the wait's tests

## Post-Completion (manual, by the user)

- **Part 1's DEBUG pass first**: the three not-ready states, the list with a live checks
  summary, New Pull Request from a fresh branch, Checkout with tab resync, the bottom-bar
  indicator.
- **Then part 2's**: Merge disabled with the stated reason while checks run; *Merge when
  checks pass* armed, visible, cancelled once, then armed again and merging on green; a
  merge of the current branch landing on `master` with the squash commit pulled in and
  open tabs resynced; a merge of a non-current row moving nothing local.
- If Task 1 could not reach a signed-in `gh`, re-record the verbatim fixtures and drop
  the honesty note from the fixtures' README.
- Launch the built app once and confirm it starts.
