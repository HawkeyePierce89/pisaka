# PisakaCore + Pisaka app (macOS) — GitHub pull requests, via the `gh` CLI

Design documentation for the Pull Requests feature: the narrow seam that runs
the user's own `gh`, the one file that knows what `gh`'s output looks like, the
argument vocabulary Core composes byte for byte, the reader model behind both
surfaces, and the macOS panel, sheet and bottom-bar indicator that draw what
Core answered. Read the relevant entry before modifying that file, and update it
when behavior changes.

This is **parts 1 and 2**. Part 1 listed open pull requests, read their checks,
created one and checked one out. Part 2 closes the loop: **merging** one from a
sheet, the bounded **wait** that merges the moment checks pass, and the
**post-merge tail** that switches to the base branch and pulls it when the merged
head is the branch the reader is standing on. Review comments, approvals, issues,
any iOS surface, any HTTP or token handling of this app's own, deleting branches
(local or remote), editing remotes, merging past the repository's own rules
(`--admin`) and GitHub's server-side auto-merge (`--auto`) are all deliberately
out of scope, and the layer holds nothing half-built for them.

## The shape of the feature, in one paragraph

A sixth bottom-dock panel lists this repository's open pull requests — number,
title, author, `head → base`, a draft marker, the review decision and a checks
summary — with **Checkout**, **Merge** and **Open in browser** per row, an
expandable per-job checks list, a **New Pull Request** sheet and a **Merge**
sheet. Beside the branch switcher
in the bottom bar, an indicator shows `#N` and the checks state for the branch
that is checked out right now, and clicking it opens the panel with that row
expanded. Everything GitHub says arrives through the user's own `gh` binary,
discovered at run time: Core composes every argument list and parses every
answer, the app layer only runs processes. The whole feature is a **reader**
except for three writes — creating a pull request, merging one, and
`gh pr checkout`, which rewrites the worktree and is the app's **eighth gated
operation**, the only one reached through a coordinator rather than from the
scene. A merge whose head is the checked-out branch owes a **tail**: a switch to
the base branch and a `--ff-only` pull, the app's **ninth** gated operation,
riding that same bracket. Freshness is **event-driven** — a branch change, the
panel becoming visible, one of the feature's own writes completing — and the one
thing in it that repeats is `PullRequestMergeWait`, the armed, bounded, visible,
cancelable *Merge when checks pass* wait, which is the ban's one stated exception
and is scoped term by term rather than by name (G14).

## Fifteen decisions this feature was built on

### G1 — The seam is one command in, one result out

`GitHubCLITransport` has exactly one member:

```swift
func run(_ command: GitHubCommand) async throws -> GitHubCommandResult
```

`GitHubCommand` carries an argument list, a working directory, a deadline and one
flag (G7); `GitHubCommandResult` carries stdout, stderr and the exit status, all
three raw. This is the `LSPTransport`/`LSPProcessTransport` and
`GitServicing`/`GitCLIService` split applied a third time, and it buys the same
thing: every rule in the layer — which flags are sent, in which order, how each
answer is read, which failure gets which sentence — is asserted in a target that
**cannot link `Process`**.

A transport never retries, never inspects a status and never parses a byte. The
only three interpretations it makes are its own knowledge and not Core's, and
they are the three cases of `GitHubCLIError`: `notInstalled`, `timedOut(seconds:)`
and `launchFailed(message:)`. A non-zero exit is not a throw — it is a
`GitHubCommandResult` the caller inspects, because for one of the seven commands
a non-zero exit is an *answer* (G3).

The argument list never carries the executable. *Which* `gh` runs is the app's
discovery problem (G7), which is exactly the machine-specific knowledge this seam
keeps out of Core.

### G2 — One schema file, and nothing in it shrugs

`GitHubAPI.swift` holds every fact about `gh`'s output: the parsers for `pr list`
(both rollup `__typename`s), `pr checks`, `repo view` and `pr create`'s printed
URL, the five closed vocabularies' decode tables, and the summary rule. This is
`LeetCodeAPI`'s rule applied to a second integration for a *different* reason:
LeetCode publishes no contract, so concentration was damage control; `gh`
publishes one, and concentration here keeps the `--json` field list and the
parser that reads it in two adjacent files that cannot drift apart —
`GitHubCommands` owns the ordered field constants and `GitHubAPI` is their only
reader, so a field nobody parses and a parse nobody asked for are each visible in
one diff.

Three rules make it one file:

- **Nothing shrugs.** A missing key, a value outside a closed table, a number
  where a string belongs — all throw `GitHubSchemaError` carrying the **key
  path** that did not match (`pr list[0].author.login`), in the command's own
  spelling, so the string in the message is both the diagnosis and the `--jq`
  expression that reproduces it. A parser that returned an empty list instead
  would make "no open pull requests" and "GitHub changed `pr list`"
  indistinguishable, forever.
- **The exit status is not consulted, ever** — not by anything in this file (G3).
- **No `owner/repo` is ever composed** (G6).

The vocabularies are closed on purpose. `gh` hands back GitHub's own documented,
versioned GraphQL enums, so a value outside a table is a schema change and is
reported as one, rather than folded into an `other` case that would render an
unexamined state as a green checkmark. The strictness is affordable precisely
because this API, unlike LeetCode's, publishes a contract.

**The summary rule**, pinned, in the order that *is* the rule:

1. `noChecks` when the rollup is empty — its own state, never `success`.
2. `pending` when any entry has not finished. Unfinished outranks a failure
   already in: a rollup with one failed job and one still running has not decided
   anything, and a red badge there would name a verdict nobody reached. GitHub's
   own rollup badge makes the same call.
3. `failure` when any finished entry did not pass — failed, errored, cancelled,
   timed out, stale or action-required.
4. `success` otherwise: everything finished, and every one passed, was neutral or
   was skipped.

A `StatusContext` contributes through its `state`, a `CheckRun` through `status`
**and** `conclusion` (a conclusion is meaningless until the status is
`COMPLETED`), and a mixed array is decided over both tables at once — which is
why `GitHubRollupItem` keeps the two kinds apart instead of flattening them on
the way in.

### G3 — `pr checks` is judged on stdout, never on its exit status

`gh` documents "Additional exit codes: 8: Checks pending" for `pr checks`, and
uses exit 1 for "some check failed" — while `gh help exit-codes` reserves 1 for
generic failure, 2 for cancelled and 4 for "requires authentication". Both 8 and
1 print the very JSON the parser reads. So for this one command the decision is
**whether stdout parsed**, and nothing else.

The rule has exactly one site — `PullRequestModel.loadChecks(number:root:token:)`
— and the schema file's blanket refusal to look at a status at all is what makes
it impossible to forget at one of the other six call sites. Output that did *not*
parse is read **three** ways, because three different things produce it.

The first is not a failure at all. `gh pr checks` has no JSON to print for a pull
request with no checks: it exits non-zero, writes "no checks reported on the …
branch" to stderr and prints nothing — which is the ordinary answer for a pull
request without CI, and most pull requests on most repositories have none. The
row already knows, because its `summary` is read from the same rollup `pr checks`
reads and an empty rollup is `noChecks`; so an empty stdout under a `noChecks` row
publishes the **empty list** the panel already has a state for ("No checks
reported"), rather than an orange strip accusing `gh` of failing at the one thing
it was asked. Without that agreement the panel would have had a warning across it
for a healthy pull request, and the view's empty-list branch would have been
unreachable.

The second is the same shape *without* that agreement: empty stdout with
something on stderr under a row that does claim checks is `gh` declining to
answer in JSON, and its sentence is shown verbatim. The third is stdout that is
there and did not parse — a schema change, reported by the typed error with its
key path.

Re-expanding a row **drops that row's recorded failure first**, in `expand`'s
synchronous prefix: the read starts again from nothing, so "Could not read
checks" may not outlive the read it described. The cached job list is
deliberately *not* dropped with it — it describes the same pull request and is
replaced the moment the new read lands, where blanking it would flicker every
re-expand through a spinner.

### G4 — The minimum is `gh` 2.50.0, and the reason is one flag

`gh pr checks --json` — without which the per-row checks list has no
machine-readable answer at all — landed in cli/cli#9079, merged 2024-05-16, and
the first tag containing that commit is **v2.50.0** (2024-05-29). Everything else
in scope (`pr list --json`, `repo view --json`, `pr create`, `pr checkout`) is
older, so that one flag is the bound. Raise it only against a commit-to-tag check
of the same shape, and record the new reason in `GitHubVersion.minimum`'s doc
comment beside the number.

`GitHubVersion` is three integers. `gh --version` prints two lines —
`gh version 2.99.0 (2026-09-01)` and a release URL — and only the first is read,
found by its first two words (`gh`, `version`) rather than by a substring search,
so the URL on line 2 (which also contains a version) can never be the answer. A
prerelease suffix and build metadata are read and **dropped** rather than
modelled: a release candidate for 2.50.0 either has the flag or does not, and
ordering it below 2.50.0 the way semver does would refuse a binary that works.
Unparseable output is `nil`, which is a real answer — it becomes `notInstalled`,
because a binary that will not say what it is cannot be vouched for.

### G5 — The non-interactive environment is a Core value

`gh` is an interactive tool by default: it prompts, it paginates through a pager,
it colours its output and it checks for its own updates. Every one of those is
fatal to a command whose stdout is parsed and whose stdin is a closed pipe — a
pager waits forever, a prompt waits forever, escape codes corrupt the text the
parser reads. `GitHubCLIEnvironment.nonInteractive` turns all four off
(`GH_PROMPT_DISABLED`, `GH_NO_UPDATE_NOTIFIER`, `NO_COLOR`, `CLICOLOR=0`,
`GH_PAGER=cat`, `PAGER=cat`) and adds `GIT_TERMINAL_PROMPT=0` for the `git` that
`gh pr checkout` shells out to — the same thing `GitCLIService` already sets for
its own invocations.

It lives in Core, as data, so the set is unit-testable; the app merges it **over**
the inherited environment, so a user's own `GH_HOST` or `GH_TOKEN` survives
untouched, and overrides `PATH` with the one discovery found (G7).

The overlay carries **one entry that is not about interactivity**: `GH_REPO` is
cleared, because it is the one inherited variable that would silently make G6
below untrue. Nothing here passes `--repo` — every command resolves the
repository from the remote in the working directory it runs in — and `GH_REPO`
overrides exactly that for every `gh` started under an environment that exports
it, which would list another repository's pull requests under this project and
let `gh pr checkout` fetch another repository's branch into *this* worktree,
under the eighth writer bracket. Empty is how `gh` itself spells "not set", so it
costs one entry and needs no second mechanism. `GH_HOST` and `GH_TOKEN` stay
untouched on purpose: they say *where* and *as whom*, which is the user's
business — not *which repository*, which is the working directory's.

### G6 — The app never composes `owner/repo`, which is what makes Enterprise free

There is **no `--repo` anywhere** in the vocabulary. Every command runs with its
working directory set to the repository root and lets `gh` resolve the repository
from the git remote that is already there. That is not a shortcut: it is the
reason a GitHub Enterprise checkout works without this app ever learning a host,
parsing a remote URL, or holding a token. `GitHubRepository.nameWithOwner` is
*read out of* `gh repo view` and never built from anything.

There is no `--web` either. Nothing in the vocabulary may open a browser — a
decision the argument lists carry, rather than a rule a view has to remember. The
panel's **Open in browser** row action opens `GitHubPullRequest.url`, which is a
URL GitHub itself printed, and only ever on an explicit gesture.

### G7 — `gh` is located at most once per refresh

Discovery is `ExecutableLocator`'s three steps, in this order: the inherited
`PATH`, then a caller-supplied list of well-known directories, then the login
shell's `PATH` (`-l -c /usr/bin/env`, reading the `PATH=` line). The order is the
decision — the inherited `PATH` first because an app started from a terminal
should use the program that terminal would run; the well-known directories next
because they are a handful of `stat`s covering the mainstream installs; the login
shell **last**, because it is the only step costing a subprocess and the only one
that can find a version-manager shim, so it runs exactly on the machines that
need it.

The answer is a path **and the `PATH` that found it**, and the second half is
load-bearing: a program found through a shim re-execs things it looks up on
`PATH`, and `gh pr checkout` has to find `git`. A Finder-launched app inherits
launchd's `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), which contains neither
Homebrew prefix.

`GitHubCLIProcessTransport` caches that pair and re-locates on exactly three
triggers:

1. the command carries `refreshesExecutableLocation` — which **exactly one
   factory does**, `GitHubCommands.version()`, the first command of every
   refresh. That is how the rule is expressed without the app layer ever spelling
   `--version`, and it is why a `gh` installed a moment ago from the embedded
   terminal is picked up by the very next refresh;
2. the cached path is no longer an executable file on disk (`brew uninstall`, an
   upgrade that moved it);
3. launching it failed — in which case the search is re-run once and the command
   retried before the failure is reported.

A refresh is three or four commands; **one login-shell spawn per refresh is the
budget, one per command is not.** The cache being defeated by the refresh's own
version probe is the point: it is deliberately *not* an app-run cache, unlike
`LSPRustToolchainService`'s, because `gh` is a thing this app is actively telling
the user to install.

### G8 — Four availability states, each with the exact next step

`GitHubAvailability` is decided purely from the two probes and re-decided at the
top of **every** refresh, never cached across one:

| state | sentence | next step |
| --- | --- | --- |
| `notInstalled` | "The GitHub CLI (gh) was not found." | `brew install gh` |
| `tooOld(found:minimum:)` | names **both** versions | `brew upgrade gh` |
| `notSignedIn` | "The GitHub CLI is not signed in to GitHub." | `gh auth login` |
| `ready(version:)` | names the version | — |

Two things about the table are decisions. **The version is judged before the
sign-in**: a `gh` too old to answer `pr checks --json` is too old whether or not
somebody is signed in, and telling that user to run `gh auth login` would send
them down a road ending in the same refusal — which is also why `auth status` is
skipped entirely when the version already settled the answer, making the
not-installed and too-old refreshes one command rather than two. And the too-old
state says `brew upgrade`, not `brew install`: the binary is already there, and
telling somebody to install what they have is the kind of advice that gets a
panel ignored.

`gh auth status` is judged **by exit status alone**. Its prose goes to stderr in
a shape that has changed between releases; the status has not.

Re-probing on every refresh and at no other moment is what makes the panel honest
without a timer: `gh` can be installed, upgraded, signed in or signed out from
the embedded terminal a second before the panel is looked at, and there is no
event to subscribe to for any of it. Re-deciding at any *other* moment would be
polling, which this feature does not do.

### G9 — Freshness is event-driven, and each trigger lives where the event is known

Three triggers, and no fourth:

- **a branch change** — `PullRequestCoordinator` subscribes to
  `BranchSwitcherModel.$current` (Combine, mapped to the short name,
  `removeDuplicates()`, `dropFirst()`). `@Published` fires *before* the property
  is written, so the branch to ask about is the one the publisher hands over and
  never `branchSwitcher.current`, which is still the branch being left —
  `DatabaseViewerTabs` reads its own subscription the same way. `dropFirst()`
  drops what was already current when the scene wired it up; everything after is
  a real transition, **including the one to `nil`** (a detached HEAD), which must
  clear the indicator rather than leave it naming the branch that was left;
- **the panel becoming visible** — one `.onAppear` in `PullRequestsPanelView`
  calling `coordinator.panelShown()`. It cannot live in the scene: the selected
  bottom panel is `@State` in `ContentView`'s owner and publishes nothing a
  coordinator could subscribe to, so "the panel is on screen" is a fact only the
  panel's own view has. Nothing re-reads while it merely *stays* open;
- **one of the feature's own writes completing** — a created pull request and a
  finished checkout. The created one is the model's own tail (it re-reads the
  list and selects the row it opened), so the coordinator starts no second read
  for it: two reads of the same list, one racing the other's generation token, is
  what the three tokens exist to avoid. The finished checkout is read the same
  way and for the same reason — the coordinator calls `didWrite()` and **nothing
  else**, the branch widget re-reads, and the branch it publishes fires the first
  trigger above. A read started beside `didWrite()` could only ask ahead of the
  widget and be superseded by that sink a moment later, so it would cost a second
  `pr list` per checkout to publish an answer that is always overwritten. The
  *local* branch the widget names is also the right question rather than merely
  the available one: `pr list --head` matches a ref **by name in the base
  repository**, so a cross-repository pull request's own `headRefName` names a
  branch this checkout did not create and is free to match a *different* fork's
  pull request spelled the same way — an indicator naming the wrong pull request,
  which is worse than one naming none.

`PisakaApp.swift` names **no refresh trigger at all**, which
`GitHubSourceGatingTests` pins along with where the other three live.

**Three generation tokens**, because there are three independently re-triggerable
reads: the list (re-asked by all three triggers), a row's checks (re-asked by
expanding, which the reader can do faster than a large pull request answers), and
the create sheet's own read (re-asked every time the sheet opens, while the panel
behind it stays live). One shared token would let a finished refresh cancel a
checks load that has nothing to do with it, or blank an open sheet's base picker.
Each is bumped in its method's **synchronous prefix**, and a superseded run
publishes *nothing* — not its rows, not its message, not its loading flag.

**A failure never blanks a good list.** Every command failure and every schema
refusal lands in `errorMessage` and leaves `pullRequests` and `checks` exactly as
they were: a list that failed to refresh is still the list the reader was reading.
Two stated exceptions. The first is availability going *not ready* — a `gh` that
is gone, too old or signed out is not a failed read but a different state of the
world, in which rows left standing under "sign in to GitHub" would be a lie the
sentence does not correct. The second is `currentBranchPullRequest`, which a
failed `--head` lookup **does** clear (both a non-zero exit and a throw): the rule
keeps a stale answer because it is still *this repository's*, and that one value
is scoped to a **branch** instead. Kept across a branch change whose lookup
failed, it makes the bottom-bar indicator assert the pull request of the branch
the user just left — `#10` under a branch that has none, in a surface with no
message slot of its own to qualify it, whose click opens the panel on a row this
branch never opened. The list above it is the repository's and stands; this does
not.

**…and it is a rule about *one repository*.** The rows kept through a failure are
this project's; rows read under a different root are somebody else's answer, with
somebody else's numbers, and Checkout composes `gh pr checkout <number>` in
whatever root is current *now*. So `prepareForRefresh()` compares the root against
the one everything published was read under (`lastRoot` — there is no
folder-change notification a Core model could take) and, when they differ, drops
availability, the rows, the indicator's row, the checks, the create state and the
message before the next read starts. Without it, opening project B after project A
and getting a `pr list` failure for B — a folder that is not a repository, one
with no GitHub remote, a refused API call — leaves A's pull requests listed under
B, actionable.

**It bumps every token, not only the checks'.** Blanking what is *published* is
half of a folder switch; the other half is the read already in flight. A `pr list`
or a `repo view` suspended in `await transport.run(…)` captured the previous
root's token, and nothing between the clear and the next refresh's own prefix
would stop it resuming and publishing project A's rows — or project A's default
base — over the cleared state, which is the very outcome the clear exists to
prevent. So the root-changed branch bumps the checks **and
create** tokens `clearRows()` itself does, and the list token is bumped by
`prepareForRefresh()` on **every** call, root change or not — superseding
whatever read is in flight is right for every refresh, while blanking the rows is
right only when they stopped being this project's.

**The list token is the one that leaves the model, and that is the point.**
`prepareForRefresh()` *returns* it, and `refresh(branch:token:)` takes it — the
`CommitLogModel.prepareForRefresh(root:)` shape, for the reason CLAUDE.md states
as a cross-cutting invariant: unstructured tasks are not guaranteed to start in
the order they were created, so a token captured *inside* the async read lets two
refreshes queued for two different branches settle on the older one, leaving the
indicator naming a pull request of a branch nobody is on. `PullRequestCoordinator
.refresh(branch:)` therefore takes the token in the trigger's own turn and hands
it across the hop; a read whose token has already moved returns at its first
guard, before it spends a single `gh`. The convenience `refresh(branch:)` — the
form the tests call — simply takes its own token and forwards.

The create token's bump lives **in `clearRows()`**, beside the assignments it
protects, rather than at either caller — and that placement is the fix to a real
hole rather than tidiness. `clearRows()` is reached from two places: the root
change above, and the **not-ready branch of `refresh(branch:)`**, which blanks
the same create state without any root having changed. With the bump at the
caller, only the first was covered: a `prepareCreate()` suspended in `repo view`
or in `commitContext` while `gh` was signed out from the embedded terminal
resumed against an unmoved token, passed both its guards and re-published the
plan the not-ready branch had just dropped — an enabled Create button over a
`create` that refuses. One bump inside the method that blanks the state covers
every caller that ever blanks it.

**And it lowers `isLoading` with them.** A superseded run publishes nothing on its
way out — including its own `isLoading = false` — and the root subscription calls
`prepareForRefresh()` *without* starting a replacement read, on purpose. So the
flag has to come down here or it never does: the panel spins on "Reading…" for a
command nobody sent, for the rest of the app run, on exactly the switch the second
subscription exists for (one `nil` branch to another, where the branch sink never
fires and nothing re-reads until the panel is next shown or its button pressed).
Once the tokens have moved, no read of *this* project is in flight, so `false` is
the honest value.

**Unconditionally, unlike the clear** — it sits with the bump, not with the
blanking, because the two answer different questions and the root subscription is
where they come apart. `BranchSwitcherModel.root` is cleared on a folder switch
and re-set when that folder's refresh *resolves*, so the observer fires a **second
time**, with the project root already settled: `prepareForRefresh()` takes its
early return, bumps the token anyway, and supersedes whatever was started in
between (Refresh pressed, the panel shown) without starting a replacement. Behind
the guard the flag would stay raised there forever. Lowering it costs at most one
frame of a spinner that is about to come back; leaving it raised costs a spinner
that never goes away.

It is called from **three places, and all three are the same call**: the top of
`refresh(branch:)`, so a model driven directly is as honest as one driven through
the app, and — in the app — `PullRequestCoordinator.refresh(branch:)`
**synchronously before its `Task` hop** plus the coordinator's root subscription,
which calls nothing else. That is the `prepareForFolderChange` rule every
project-scoped model in this app follows, and the coordinator's calls are what
make the rows gone in the folder switch's *own* main-actor turn: a `Task` start
later is already a turn in which the panel could draw a stale row and Checkout
could compose one. Same-root calls cost a comparison, which is what lets every
trigger go through it.

**Why the branch sink alone cannot see every folder switch, and what the second
subscription is for.** A folder switch usually arrives as a branch change:
`BranchSwitcherModel.prepareForRefresh` clears `current` inside `openFolder`, so
the coordinator's `$current` sink fires in that turn. But `nil` is where a
detached HEAD, an unborn HEAD and a folder that is not a repository all already
sit, so switching *from* one of them clears `current` to the value it already had,
`removeDuplicates()` swallows it, and that sink never fires — leaving project A's
rows listed, and Checkout composing `gh pr checkout <A's number>`, under project
B. `BranchSwitcherModel.root` is cleared on every root change and on that one
alone, so a second subscription on `$root` sees the switches the branch cannot.

It is **not a fourth trigger**: it reads nothing, it only calls
`prepareForRefresh()`. A read there would be a second one for every ordinary
folder switch, where the branch sink is about to fire in the same turn — and this
feature spends a login shell and two network round trips per refresh. Safety is
the clear; a new project whose branch never resolves (it, too, is detached) is
read when the panel is next shown or its refresh button pressed, with nothing
false on screen in the meantime.

**Which is a claim the placeholder has to earn**, and it is why the model answers
`hasProjectRoot`. `availability == nil` is "nothing decided yet", and that covers
two different worlds: no project is open, and a project is open whose first read
has not run — precisely the state the clear above leaves behind. Keyed on
availability alone the panel said "No repository" about a repository that *is*
open, and said it until the panel was hidden and shown again, which for a panel
that never hid is never. So the root is asked (at draw time, like `projectRoot`
itself — this model is retargeted rather than recreated), and the state that is
really "nobody has looked" names the control that looks:
`"Press Refresh to read pull requests."`

**A failure is cleared by the read that caused it and by no other.** The one
message slot records whose sentence it holds (`ErrorSource`: refresh, checks,
create, merge, mergeTail, checkout, checkoutBlocked), for `DatabaseViewerModel`'s reason — a refresh
that succeeded says nothing about an expand that failed a moment earlier, and
clearing that sentence would leave a row expanded over an empty checks list with
no explanation.

**Three of the seven have an end, and it is not another read of their own.** The rule
above keeps a sentence until its own read runs again, which is right for a
*result* — a command answered, and no later read changes what it said — and wrong
for a *condition* that ends silently:

- **`checkoutBlocked`** is a checkout the gate refused, and it is its own source
  precisely so that this exception does not reach `checkout`. The condition it
  names — another operation is rewriting the worktree — ends with nothing in this
  feature told, so a refresh that reaches its tail **with the gate down** clears
  it, that being the only proof available. A refresh that runs while the gate is
  still up leaves it standing, because it is still true. Sharing `checkout` left
  it pinned above a list that had since refreshed cleanly for the rest of the app
  run, telling a reader who did exactly what the sentence asked — wait, then look
  again — to keep waiting. A checkout that *ran* and failed keeps the strict rule:
  its row is still on screen waiting to be understood, and a refresh has no
  standing to withdraw what `gh` said.
- **`create`** is the sheet's, and only the sheet draws it as such
  (`createMessage`). It ends when the sheet does: `dismissCreate()` — wired to
  `NewPullRequestSheet`'s `.onDisappear`, the one place Cancel, Esc and a
  successful Create all reach — clears it, scoped, so a refresh failure that
  landed behind the open sheet is not swept away with it. Without that, a create
  that failed and was then cancelled left `gh`'s refusal (or git's rejected push)
  in the panel's strip with nothing on the ready path able to clear it, since
  every later refresh asks for `refresh` and returns early.
- **`merge`** is the second sheet's, drawn as `mergeMessage` for `create`'s
  reason applied to the second sheet — it too stands over a live panel whose
  list, checks and indicator keep refreshing behind it — and ended by
  `dismissMerge()` on `PullRequestMergeSheet`'s `.onDisappear`, again scoped.

**And `mergeTail` is its own source because of when it is published.** The tail's
one refusal — the base branch is in neither half of the branch widget's list — is
set *during* the caller's turn: `coordinator.merge` runs `runMergeTail(…)` before
it answers `true`, and the sheet dismisses on that answer, so `dismissMerge()`
would clear the sentence in the same turn it was written. Under `.merge` the one
thing the tail can say was therefore unreadable on the path that produces it
most. It records something that happened and stays true — the merge landed and no
branch was switched to — so nothing withdraws it but a new merge sheet
(`prepareMerge(number:)` clears it alongside its own) or a blank of everything.

**Blanking the rows blanks the slot, whoever filled it.** The three moments the
model clears everything a sentence could be about — availability going not-ready,
the project closing, and the project *changing* — clear the message
*unconditionally* rather than through `clearError(from: .refresh)`. Those are the same moments as the exceptions
above, and for the same reason read the other way round: a checks failure or a
refused create is a sentence about rows that have just stopped being drawn, and
leaving it standing puts "could not reach github.com" above a panel whose own
next step is `gh auth login`.

**A surface reads only its own sentence.** The panel's strip draws the slot
whole — it is the surface every read of the feature happens under — but the
create sheet draws `createMessage`, which is the slot **only when
`errorSource == .create`** — and the merge sheet draws `mergeMessage` on the same
terms. A sheet drawing the raw slot would show a background
refresh's failure, or a checks read that failed under a row behind it, in red
above its buttons on a sheet where nothing has been submitted; and
`prepareCreate()` cannot clear that sentence, because clearing it is exactly what
the sources forbid. The panel, which draws the slot whole, is therefore the one
surface the tail's `mergeTail` sentence appears on — which is where it belongs,
since by then the sheet that started the merge is gone.

**A read that failed is not a read still running.** `checks[number] == nil` means
"still reading" and `[]` means "GitHub reported no jobs" — a two-state split the
expanded row draws a spinner from. A failure is neither, so it is recorded in
`checksFailures`, pruned and cleared exactly like `checks`: without it the row
that failed would keep the spinner of the first state for as long as it stays
open, which is the very thing the split was written to avoid.

**Nothing to read is nothing expanded.** `expand(_:)` records `expandedNumber`
*after* its own guard, not before: an expansion recorded for a read the guard
then refuses to send (not ready, or no project root) would draw the "still
reading" state of that same split for a command nobody ran. It also bumps the
checks token wherever it collapses a row — `expand(nil)`, the refused expand,
`clearRows()`, and `pruneChecks(keeping:)` when the expanded row is no longer
open — because collapsing is the same statement supersession is: a load that
resumes after its row stopped being drawn must publish neither its jobs nor its
sentence, and a `.checks` sentence landing after `clearMessage()` would sit above
a panel drawing no rows, contradicting the not-ready state's own next step.

**A not-ready refresh clears the create sheet's state with the rows.**
`clearRows()` drops `repository`, `createPlan` and the context they were planned
over, for the same reason it drops the rows: the sheet's Create button is
`createPlan?.canCreate` read from the view's side, and a plan left standing after
`gh` stopped being ready is an enabled button over a `create` that would refuse.
The **create token goes with them** (above), so a sheet read still on the wire
cannot put the plan back.

And the refusal underneath is no longer silent. `create(...)`'s readiness guard
publishes `PullRequestModel.unavailableMessage` — its own constant, not the
availability state's sentence, which the panel behind the sheet is already
drawing with its next step. Every exit from `create` leaves a sentence; this one
was the exception, and the exception was a Create button that did nothing at all:
no dismissal, no message, no spinner.

### G10 — One write in flight, read from both sides

`isWriteInFlight` is the feature's single "something is being written" term. It is
raised and lowered by the two writes alone — `create` and `checkout` — each of
which also **refuses** on it, so the rule holds even when a button forgot to
disable. Every read path leaves it untouched. The panel greys **New Pull
Request**, **Checkout** and **refresh** on it; the sheet's Create is disabled
through `GitHubCreatePlan.canCreate`, the very value `create(...)` re-decides and
refuses on — one rule read from both sides, rather than a view-side guard and a
model-side guard free to disagree.

### G11 — Push first, and the base is `repo view`'s answer

`gh pr create` compares a **remote** head against the base, so a branch never
pushed — or pushed three commits ago — opens a pull request missing the work it
was opened for. The model therefore pushes first, through the existing
`GitServicing.push(_:root:)`, on both available `PushPlan` branches, and a push
that fails **never reaches** `pr create`: the difference between "nothing
happened" and a pull request published against the wrong commits. `gh` would push
too — silently, as part of `pr create` — but only after prompting for a remote on
a branch that has none, which is a prompt no pipe can answer, and it would make
the push invisible to the sentence the sheet showed.

The refusals are `PushUnavailableReason.detachedHEAD` and `.noRemote`, **with the
commit dialog's own sentences**, because they are literally the same two
refusals: a pull request is a request to merge a *branch* that exists *on a
remote*. The third case, `.branchChanged`, is never produced here for the reason
`PushPlan.plan(context:)` never produces it either — it is a verdict about two
readings of the repository, and this plan is made from one. There is a **third
way Create is off and it carries no sentence**: an empty base, which is what a
failed `repo view` leaves behind, with `gh`'s own words already in the message
slot. What that failure costs is the *default*, not the sheet: the picker goes on
listing the local branches it always lists, so a reader who knows the base can
name it and Create comes back on.

`--base` is **always** sent explicitly. `gh`'s own default is the *upstream*
repository's branch for a fork — a different pull request from the one the sheet
described — so the base the sentence names is the base that is sent, and the
default the picker opens on is `gh repo view`'s `defaultBranchRef` and nothing
else. (The ticket's alternative, "the upstream's branch", was dropped entirely.)

**`--head` is deliberately *not* sent**, and that is the base's reason read the
other way round rather than the same one repeated. A `--head` value names a ref in
the **base repository**: `gh`'s own help says it "supports `<user>:<branch>` syntax
to select a head repo owned by `<user>`", which is the only way an argument can
name a ref anywhere else. So a bare branch name sent from a fork checkout — where
`gh` resolves the base repository to the *parent* — asks GitHub for that branch in
the parent, where it either does not exist ("no commits between…") or, worse, is a
same-named branch (`develop`, a shared feature name, a stale one) whose commits
belong to somebody else. That is the one failure mode worse than the race an
explicit head would close, and a fork checkout is the ordinary way people
contribute.

The qualified form is not available to this layer, on three counts: no
`owner/repo` is composed anywhere in this feature (G6), the owner of the **push**
remote is in nothing that is read here (`CommitContext.remotes` carries names, not
URLs, and `repo view` answers for the *base*), and `gh` does not accept an
organization as the `<user>` at all. Left implicit, `gh` reads the checked-out
branch's tracking configuration and qualifies the ref itself — which is the one
place both the fork answer and the differently-spelled-tracking-ref answer are
known. `PushPlan`'s rule that a tracking ref "may well be named differently from
the local branch" is therefore honoured by *not guessing* here either, exactly as
it is honoured by composing no refspec.

**What the implicit head costs is paid where the window is.** `gh` resolves the
current branch at *its own* process launch, and this flow pushes first: the sheet
may be dismissed while that push is on the wire — Cancel stays live — so a branch
switched from the widget or the embedded terminal in that window would otherwise
open the pull request from the branch that is current *then*, carrying the title
and base typed for another one, as a published remote act. So the branch is
**re-read once the push returns** (`GitServicing.currentBranch`) and the whole
create is **refused** when it is no longer `GitHubCreatePlan.headBranch` — the
branch `baseSentence` named. A `nil` reading (a detached HEAD) refuses for the same
reason; a reading that *fails* carries git's own words instead, because that is a
failed read and not a moved branch. The sentence is
`PullRequestModel.branchMovedMessage`, and it says the push happened and no pull
request was opened, because the push is the only part of the flow that did.

Refusing is also what an argument could not do. A pinned head in that situation
would have opened a pull request against a ref the flow no longer had any reading
of; stopping is the answer, and it costs at most a spurious refusal in the narrow
case where the switch landed *after* the push launched (the right branch did go
out, and the reader reopens the sheet). The project root is pinned across the same
window by being read once at the top and used by both commands, and the fresh
context read answers a branch switched *before* Create — the re-read answers one
switched *during* it.

**The gate is asked as well, twice** — the same injected `isWriteBlocked` the
checkout asks (G12), with its own sentence,
`PullRequestModel.createBlockedMessage` — and it closes the window those two
leave between them: **the push itself**. Neither the
fresh read before it nor the re-read after it reaches it, because
`PushPlan.push(upstream:)` is a
plain `git push`, which resolves HEAD at *its own* process launch rather than from
the plan — deliberately, since the tracking ref may be named differently from the
local branch and a refspec composed here would be a guess, and that is
`PushPlan`'s rule, shared with the commit dialog, not this feature's to rewrite. So
a branch switch landing between the context read and the push makes that push
publish a branch this flow never planned — a remote act nothing afterwards can
take back, and one the post-push re-read cannot repair, because by then the wrong
branch has already gone out. Refused **before** rather than detected after, which
is the difference between "nothing happened" and a published push nobody asked
for. So while a branch switch, a revert, a merge
apply or a project Replace All is rewriting the worktree, Create does not run —
and the refusal is a "not now" the same sheet retries out of, not a state it has
to be reopened from.

**Twice, because one reading covers only half the flow, and the second is the
load-bearing one.** The consult before the context read answers for a rewrite
already in flight; the flow then *suspends* over `commitContext`, which is several
`git` subprocesses with the main actor free for all of them — which is exactly
when a branch switch is initiated. Nothing on the other side closes that: the
app's three branch-change entry points refuse on the writer gate alone
(`revertInFlight()`), and this flow deliberately never raises it, so a switch
started mid-read would run to completion. Hence the second consult, placed as the
last synchronous statement before the push with **no `await` between the two** —
which is what makes it the last moment the question still has an answer worth
having, since the branch a plain `git push` publishes is decided at that push's own
process launch. Both refusals land before the push and before `pr create`, so
neither is sent. This is a *consult*, not a raise: create still takes no gate of
its own, and the checkout stays the feature's one gated operation. What is left is
the window `CommitDialogModel`'s own push already names and accepts — the push's
own process launch, and a `git checkout` from the embedded terminal inside it,
which no gate in this app can see.

Every sentence names what will actually happen, because Create performs up to
three operations nobody separately asked for: a push, possibly the first
publication of the branch to a remote (stated, because that is a visible public
act), and the pull request. The "uncommitted changes will not be part of the pull
request" line is there for the same reason.

The refusals are re-decided from a **fresh** commit context when the button is
pressed, not from the one the sheet was drawn over: a branch switched, or a
remote removed, behind an open sheet must refuse rather than push.

### G12 — The checkout is the eighth gated operation, and it has one site

`gh pr checkout` rewrites the worktree. Every other worktree-mutating operation
in this app raises `autosave.suspend()` + `localChanges.beginRevert()`
synchronously, snapshots the open tabs, captures Local History as the **first
`await` inside the bracket**, and resyncs the tabs afterwards. None of that is
expressible in Core, and none of it may be re-implemented under this feature.

So `PullRequestModel.checkout(_:)` **sends nothing**. It composes the command and
hands it to the app's bracket through the injected `runCheckout`, exactly once
for an accepted checkout and **not at all** for a refused one — which is what a
refusal has to mean for an operation nobody can take back. The three refusals, in
the order they are asked:

1. one of this feature's own writes is already in flight (G10);
2. **the gate**, asked before anything is composed — a checkout landing inside a
   revert, a merge apply or a branch switch would move the worktree out from
   under an operation already snapshotting it. The refusal's sentence is this
   layer's own words, not `gh`'s, because `gh` was never asked;
3. `gh` is not ready, or there is no project root.

Two more are asked **before** the model *accepts*, in
`PullRequestCoordinator.checkout(_:)`, because both are answers only the scene has
and both must land before the model raises the one-write flag at the hand-out: an
**unwired** coordinator (a preview or a test, whose bracket runs nothing —
handing it an operation it would never run leaves the flag up for the app run),
and the **dirty-tree confirmation** `switchBranch` and `checkoutRemote` already
ask. `gh pr checkout` runs git's own checkout and is blocked by exactly the
changes those two warn about, so a reader warned for one and not the other is
being told they are different operations.

**The gate is asked before that confirmation**, which is the order those two ask
in — `guard !revertInFlight(), confirmBranchSwitchIfDirty()` — and for their
stated reason: a refusal is then one alert rather than a confirmation the reader
gives to an operation refused straight afterwards, with the refusal arriving as a
line in a panel they were not looking at. The question stays the model's:
`checkoutIsBlocked()` is a public member the coordinator calls and `checkout(_:)`
calls too, so the gate keeps one site and the sentence one author — the
coordinator chooses only *when* it is asked, never what the answer means. Asking
twice is free: the gate is a synchronous predicate and the sentence is the same
one both times.
That ordering is also the whole of the runner's contract: **a runner must invoke
the operation exactly once**, and a runner that cannot must refuse before
`checkout(_:)` is called.

Also stated on the title, which is a refusal of `create`'s rather than the
sheet's: `PullRequestModel.untitledMessage` is published and nothing is pushed,
because a rule that lives only in a view is a rule no test can see and a second
caller can walk past.

The gate travels as an injected `isWriteBlocked` closure, wired in the scene
alone to `LocalChangesModel.isReverting`, so **no file under the feature names
`autosave` or `localChanges` at all** — `DatabaseViewerModel`'s arrangement,
pinned here by `GitHubSourceGatingTests`. One closure, **two readers**: the
checkout, whose worktree write this paragraph is about, and `create`, which reads
it for the push (G11). Two readers, two sentences, because they name different
operations to retry; one wiring, because they are asking about one state of one
worktree.

On the app side the bracket is reached through one generalisation rather than a
second bracket: `PisakaApp.runBranchOperation(_:_:)` now takes the Local History
event and an operation answering `String?` — `nil` for success, a sentence for a
failure worth an alert, and `""` for a failure already published where the reader
is looking, which is the only one this feature returns (the panel the reader just
clicked Checkout in is on screen showing `gh`'s own words; a modal repeating them
is not a second fact). The two branch callers keep passing `.branch`; the
coordinator passes `.pullRequest`. Local History's event vocabulary gained
`case pullRequest = "pullrequest"` — the raw value written out because the tag is
on-disk and must be lowercase ASCII with no `-`.

Sharing the bracket is also what made its **failure path** grow a question the two
branch callers never needed to ask. Their operation is a single `git checkout`,
which fails atomically, so "it failed" and "nothing moved" were the same sentence.
`gh pr checkout` is not one command: it fetches, checks out, fast-forwards and
writes the tracking config, and the steps *after* the checkout can fail on their
own — a local branch that has diverged refuses `--ff-only` — or be killed at the
120-second deadline. Each of those exits non-zero with the worktree already on the
pull request's branch, and the old behaviour (skip the tail, show the message)
would have left every open buffer holding the branch the reader left, ready to be
saved over the files of the one they are now on. So on failure the bracket
**re-reads the branch and runs the tail only when it actually moved** — an
ordinary failure compares equal and resyncs nothing, which is what keeps the
edited-tab beep off the path where nothing happened, and both readings must be
known for a move to be declared. That re-read publishes `current`, which fires the
coordinator's own branch subscription, which is why `runCheckout`'s failure path
still triggers nothing of its own (`app-shell.md`).

Because the bracket is shared, `LocalHistorySourceGatingTests`' count of
`autosave.suspend()` sites in `PisakaApp.swift` is unchanged: there are seven
bracket **sites**, and the eighth *operation* rides the one that already served
branch switch and checkout-remote. The alternation rule that suite enforces —
gate, then capture, per site — is what makes that sharing safe.

### G13 — The merge is one rule read by three readers, guarded by `--match-head-commit`

`GitHubMergePlan` decides whether a pull request may be merged from here, and
**three readers ask it**: the sheet's button (which is drawn from it, disabled by
it, and labelled by it), `PullRequestModel.merge(…)` (which re-decides from the
row the list holds *now*, so an open sheet cannot send a merge the panel would
refuse), and **every tick of the wait**. Three readers, one table — a second
enumeration in the view or in the wait would be free to word one state two ways,
and a button reading "Merge" over a model that refuses is the bug this shape
exists to make unwriteable.

**The enabled rule is a conjunction of four facts**: not a draft, `mergeable ==
MERGEABLE`, `mergeStateStatus` one of `CLEAN`/`HAS_HOOKS`/`UNSTABLE`, and the
checks summary `success` or `noChecks`. Everything else is one of seven typed
refusals, each carrying the sentence every reader shows: `draft`, `conflicts`,
`checksRunning`, `checksFailed`, `mergeabilityUnknown`, `behind`, `blocked`.

Two orderings inside that table are load-bearing:

- **checks before blocked.** A repository with a required check answers `BLOCKED`
  for the whole time that check is running, so reading the merge state first would
  stop a wait on "GitHub's rules are blocking the merge" in exactly the state the
  wait exists to sit through.
- **a draft is decided from `isDraft` alone.** GitHub removed `DRAFT` from
  `mergeStateStatus` years ago and a draft now answers `BLOCKED` there, which is a
  sentence about the repository rather than about this pull request.

Each refusal answers **two questions of its own**, so nothing re-derives them:
`isArmable` (may a wait be armed here — `checksRunning` and nothing else) and
`mayResolveByWaiting` (may an armed wait *keep* waiting — `checksRunning` and
`mergeabilityUnknown`, the two computing states). Unknown mergeability is
deliberately in the second set and not the first: it clears in seconds, so it is a
state a running wait sits through and never one a reader is offered a half-hour
promise on.

**The guard is `--match-head-commit`, always.** Every row is read with its
`headRefOid` — which is why the field is asked for on *every* row rather than on
the one being merged — and the merge carries the head of the row its plan was
decided from. A push landing between that read and the merge is refused by
*GitHub*, in GitHub's words, rather than merged silently. Three flags never
appear: `--admin` (merging past the rules the enabled rule just checked),
`--auto` (a server-side promise this app cannot show, cancel or account for — the
wait is the visible answer to the same question) and `--delete-branch` (this layer
deletes no branch; `deleteBranchOnMerge` is read only so the sheet can say what
GitHub will do by itself).

The write itself is the feature's **third**, under the same one-write rule (G10),
and it asks **the gate** — not for its own sake, since `gh pr merge` writes no
file, but for the tail's: a merge accepted while a revert or a branch switch is
rewriting the worktree owes a switch and a pull the moment it lands, into a
worktree already being rewritten by something else.

### G14 — The wait is the no-polling ban's one stated exception, and it reads the row

*Merge when checks pass* arms `PullRequestMergeWait`: it re-reads **one pull
request row** every `pollInterval` (30 s) for at most `deadline` (30 min) and
merges the moment `GitHubMergePlan` — the value the button was drawn from — says
it may. `LeetCodeJudgeModel`'s shape (L18) applied to a second polled answer: a
`@MainActor` companion owned by the model, an injectable `now` clock and an
injectable `sleep` seam, and a generation token checked after **every**
suspension, so the whole state machine including the deadline runs
deterministically in `swift test` and adds no wall-clock time to it.

**One rule, one table, and this is the feature's load-bearing decision.** A tick
runs `gh pr view <n>` and parses it with the *same row decoder* the list uses; it
never runs `pr checks`. That command answers about **jobs** and cannot see
`mergeable` or `mergeStateStatus`, so checks can go green while GitHub still
answers `BLOCKED`, `BEHIND` or `UNKNOWN` — and a wait deciding "green" from the
jobs table would hand a merge to the plan that refuses it, in words about a state
it never looked at.

**`pr view <n>` rather than `pr list --head <branch> --limit 1`**, for two
reasons: `--head` names a *branch*, and a branch name is not unique across
repositories (a fork's head can be spelled exactly like another's, and `--limit 1`
hands back whichever GitHub ordered first — an ordinary case turned into a stop
with nothing useful to say); and `pr view` answers for a pull request that is **no
longer open**, which is precisely the "somebody else merged it" ending the wait
must recognise, where a `--state open` list would come back empty and be
indistinguishable from a branch that never had one.

**Exactly four endings**, and a wait may not stop without one, because it is a
promise the app made on its own: `merged` (the plan said yes; the outcome is
carried, `nil` when the model refused or `gh` failed, whose sentence is already in
the message slot), `stopped(sentence)` (a failing check, a refusal
`mayResolveByWaiting` says no later tick can leave, a row no longer open, a
read that could not be made at all — in `gh`'s own words, now rather than in half
an hour — or **the world the wait was armed in gone**, which is
`PullRequestMergeWait.stateLostMessage` and not the sheet's
`mergeRowMissingMessage` it would otherwise read like: that sentence ends "close
this sheet", and this ending is drawn in the *panel's* ending strip, where a wait
runs precisely because nobody is standing in front of a sheet), `deadline`, and
`cancelled` (Cancel, a project switch, quit, or another wait armed over this
one). The merge's ending is **the one published past a moved
token**: it is a fact rather than a decision — the merge either landed or was
refused — and a Cancel pressed while the write was in flight cannot un-send it.

**The head guard needs no rule of its own here either**: each tick merges with the
head *that tick* read, so a push landing after it is GitHub's refusal, which stops
the wait with GitHub's words on screen. A comparison against the arm's head would
be a second, weaker guard against the same accident.

While a wait is armed, **every** row's Merge is disabled — the merge it will run
is the one-write rule spent in advance — while reads, Checkout and Create stay
available, because none of them is a merge. `isWriteInFlight` is raised only for
the merge itself, when it actually runs.

The exception to the no-polling ban is **scoped and pinned term by term** by
`GitHubSourceGatingTests`, not granted by file name: the two bounds are named
constants declared once, the wait between ticks is exactly one `Task.sleep` behind
exactly one injectable seam, `Timer` and `asyncAfter` stay banned there, and
`GitHubCommands.checks` may not appear in the file at all. An exception that were
only a name would buy an unbounded, invisible, un-cancelable poll in the same file
and read the same in a diff.

### G15 — The post-merge tail is the ninth gated operation, and its order is Core's

Merging the branch you are standing on leaves the worktree on a branch whose
commits are now in the base — so the tail **switches to the base branch and pulls
it `--ff-only`**. It runs only when `GitHubMergePlan.isTailOwed` (the merged head
*is* the checked-out branch, compared exactly, because git's refs are), in order,
**stopping at the first failure**, and it never reports the merge as failed: the
pull request is merged from the moment `gh` answered, and this model's one
sentence must not start saying otherwise.

**What the tail is, is Core's; what each step does, is the app's.**
`PullRequestModel.mergeTail(for:branches:)` resolves it from the branch widget's
own list — the list the reader is looking at, refreshed by every operation that
could change it — in git's own DWIM order: a **local** ref named `<base>` goes
through `switchTo`; failing that a *remote* ref whose branch half is `<base>` goes
through `checkoutRemote`,
whose DWIM already picks a same-named local or creates the tracking branch; and
only when neither is listed is there `.unresolved`, the tail's one refusal, whose
sentence says the merge landed first because that is the fact the reader most
needs. **The remote is matched by stripping, never by composing `origin/`**: the
whole branch pipeline is remote-agnostic (`BranchRef` carries `remoteName`,
`BranchSwitcherModel.defaultBranchName(forRemote:)` strips whatever it says) and
`gh` resolves the repository from whichever remote the working directory has, so
a checkout whose only remote is `upstream` merges perfectly well and must not
then be told its own base branch is not in the repository; where several remotes
carry the same branch, `origin` wins, because that is the one git's own DWIM
picks. `runMergeTail(…)` then orders it: **the repository first of all** — a merge
is a network round trip that can outlive the project it was started in, and the
folder switch that cancels an armed wait cannot un-send a sent command, so the
outcome carries the root it was decided in and a tail whose root has since moved
runs nothing and says nothing (silently: the reader closed that project on
purpose, and the panel that would carry a sentence went with it). **That question
is asked twice**, here and again between the two steps, because the switch is
itself a bracketed operation and therefore suspends: a folder switch landing while
git's checkout runs reopens the very window the first ask closed, and the pull —
which takes the root it is handed and asks nobody — would fast-forward a branch in
a repository this merge had nothing to do with. The switch needs no second ask:
the coordinator pins the branch widget's refresh generation synchronously, in the
turn the tail is decided in, so a folder switch reaching the widget first makes
the checkout bail. Then the
decision (so a tail that is not
owed costs nothing and puts no modal in front of anybody), then **the writer gate**,
then the same dirty-tree
confirmation `switchBranch` and `checkoutRemote` ask, and the pull **only
on the switch's success** — a pull after a refused checkout would fast-forward the
branch the reader is still standing on with the base's commits.

**The gate is asked twice, and the second time is the tail's own.** `merge(…)`
asks it before anything is composed, but that answer is spent before `gh pr merge`
reaches the network: by the time the tail is handed out, a round trip, a refresh
and — on the wait's path — up to half an hour have gone by, any of which is room
for a revert, a commit, a merge apply or a branch switch to start. The bracket the
tail's two steps ride *raises* the flag without reading it (which is exactly why
`switchBranch` and `checkoutRemote` refuse on it at their own entry points), so a
tail that did not ask would be a second `git` rewriting a worktree the first one
is still in. It is asked ahead of the confirmation, in the order every other
checkout in the app asks in — a refusal is one alert, not a confirmation followed
by one — and after the decision, so a tail that was never owed says nothing about
a gate it did not need. The refusal has its own sentence,
`PullRequestModel.tailBlockedMessage`, published under `.mergeTail` beside the
unresolved base's: it opens by saying the merge landed, because
`mergeBlockedMessage` refuses a merge that has *not* happened and this one reports
one that has.

The pull is `GitServicing.pull(root:)`, whose whole contract is `--ff-only` and
nothing else: the only honest outcome after GitHub merged is "advance to what the
remote already has", and a merge commit or a conflicted worktree would be this
feature writing history nobody asked for, inside a writer bracket, on a branch
nobody has looked at yet. It names no remote and no refspec (the upstream is
git's own answer), throws `GitError.pullFailed(reason:)` with git's words, and is
defaulted in the protocol extension to `throw .gitUnavailable` — iOS is left at
that default, since the tail is macOS only.

Both steps are **gated**, which makes the pull the app's **ninth** gated operation
and the switch a second `.branch` caller. The bracket count stays at **seven**:
`PullRequestCoordinator` holds all three of this feature's bracket call sites —
`.pullRequest` for the checkout, `.branch` for the tail's switch, `.pull` for the
tail's pull — and `PisakaApp.runBranchOperation(_:_:_:)` gained one thing for it,
an **optional completion called on both paths**. That is not decoration: the
bracket is fire-and-forget, and two bracketed operations cannot be ordered without
it — the pull must not start until the switch has finished *and been judged*.
Local History's vocabulary gained `case pull` ("Before Pull"), its own event
rather than `branch`, because a file the tail overwrites was overwritten by *the
remote's* work and "what did this look like before I took everyone else's
changes?" is a different question from "what did this look like before I switched
branches?".

## The Core half (`Sources/PisakaCore/`)

### `GitHubCLI.swift` — the seam

`GitHubCommand` (arguments, working directory, deadline,
`refreshesExecutableLocation`), `GitHubCommandResult` (both streams and the
status, plus `isSuccess` and `trimmedStandardError` — the form every user-facing
failure uses, so `gh`'s words are reported verbatim rather than paraphrased), the
`GitHubCLITransport` protocol, `GitHubCLIError` with its three sentences, and
`GitHubCLIEnvironment` (G5). Deadlines are per command rather than one global
number: `pr checkout` performs network git work and `--version` does not, and one
deadline generous enough for the first would let the second hang a refresh.

### `GitHubCommands.swift` — the whole argument vocabulary

Nine `gh` subcommands reached through ten factories — `pr list` is reached twice
(the current-branch lookup is `--head` rather than a command of its own):

| factory | command | deadline |
| --- | --- | --- |
| `version()` | `gh --version` | local, 15 s — **the one `refreshesExecutableLocation`** |
| `authStatus()` | `gh auth status` | network, 30 s |
| `openPullRequests(root:)` | `pr list --state open --limit 50 --json …` | network |
| `pullRequest(forHeadBranch:root:)` | `pr list --state open --head <b> --limit 1 --json …` | network |
| `pullRequest(number:root:)` | `pr view <n> --json …` — **the wait's one read** (G14) | network |
| `checks(pullRequest:root:)` | `pr checks <n> --json …` | network |
| `createPullRequest(title:body:base:draft:root:)` | `pr create --title --body --base [--draft]` — **no `--head`**, deliberately (below) | git network, 120 s |
| `mergePullRequest(number:method:headRefOid:subject:body:root:)` | `pr merge <n> --merge\|--squash\|--rebase --match-head-commit <oid> [--subject [--body]]` | git network |
| `checkoutPullRequest(number:root:)` | `pr checkout <n>` | git network |
| `repositoryView(root:)` | `repo view --json defaultBranchRef,nameWithOwner,…` | network |

The three `--json` field lists are **ordered constants** shared with the parsers
(ordered, not sets: they go on a command line, and a suite asserting the command
byte for byte needs one spelling to assert). `pullRequestFields` is thirteen:
part 1's ten plus `headRefOid`, `mergeable` and `mergeStateStatus` — asked for on
**every** row, because the button that offers Merge is drawn from the same value
the merge is decided from, and the merge is guarded by that row's head (G13).
`checkFields` is `pr checks`' exact nine, in `gh`'s own order — asking for all
nine costs nothing on the wire and keeps the parser reading one shape.
`repositoryFields` is seven: the default branch and the name, plus the five merge
policy values (`mergeCommitAllowed`, `squashMergeAllowed`, `rebaseMergeAllowed`,
`viewerDefaultMergeMethod`, `deleteBranchOnMerge` — the last read but never acted
on, so the sheet can say what GitHub will do on its own side). The list
limit is 50, above `gh`'s default of 30; a repository with more open than that has
a browser for the rest.

`mergePullRequest` carries four decisions in its argument list rather than in a
rule some view has to remember: exactly one method flag (`gh` refuses
interactively when given none, which in a non-interactive process is a hang until
the deadline), `--match-head-commit` always, `--subject`/`--body` only for the two
commit-producing methods (a rebase composes no commit, and an empty body is
*omitted* rather than sent empty — unlike `pr create`, `pr merge` composes
GitHub's own default body when none is given), and the three flags that never
appear (G13). `methodFlag(_:)` is the one place a merge method is spelled as a
flag, and it lives here rather than on `GitHubMergeMethod` so the vocabulary rule
reads every `gh` argument in one file.

`GitHubSourceGatingTests` pins that **no `gh` argument is spelled anywhere in the
app layer** — the rule that makes this file the vocabulary.

### `GitHubVersion.swift`

Three integers, `Comparable`, `minimum = 2.50.0` with its reason (G4), and two
parsers: `parse(_:)` over `--version`'s whole output, and `parseNumber(_:)` over
one token (`2.99.0`, `v2.99.0`, `2.50.0-rc.1`, `2.50.0+build`, `2.50` — a missing
patch reads as `0`, a fourth component and any suffix are dropped).

### `GitHubAvailability.swift`

`GitHubVersionProbe` (`unavailable` / `version` / `unreadable` — three cases
rather than an optional, because "there is no `gh`" and "there is a `gh` that
would not say what it is" arrive by different routes and collapsing them at the
call site would move that decision into the app layer) and `GitHubAvailability`
with its four states, `isReady`, `message`, `nextStep` and
`decide(version:isSignedIn:)` (G8).

### `GitHubPullRequest.swift` — the vocabulary the surfaces read

The eight closed enums — `GitHubCheckStatus`, `GitHubCheckConclusion`,
`GitHubStatusContextState`, `GitHubCheckBucket`, `GitHubReviewDecision` (with
`.none` for `gh`'s `""`, which is what a repository requiring no review answers),
and part 2's three: `GitHubMergeability` (`MERGEABLE`/`CONFLICTING`/`UNKNOWN`),
`GitHubMergeStateStatus`
(`DIRTY`/`UNKNOWN`/`BLOCKED`/`BEHIND`/`UNSTABLE`/`HAS_HOOKS`/`CLEAN`) and
`GitHubMergeMethod` (`MERGE`/`SQUASH`/`REBASE`, with `composesACommit` — which is
what decides whether `--subject`/`--body` are sent, and which fields the sheet
shows) — plus `GitHubRollupItem` (the two `__typename`s kept apart), the four-case
`GitHubChecksSummary`, and the value types `GitHubPullRequest` (carrying
`headRefOid`, `mergeable` and `mergeStateStatus`), `GitHubCheckRow`
and `GitHubRepository` (carrying the four merge-policy values). Behaviour here is limited to the two questions the
summary rule asks — `isFinished` and `isPassing` — and the conservative direction
of the second is stated on it: an unrecognised-but-finished state is not a pass.

The wire half — which JSON key holds which of these, and which spelling maps to
which case — stays in `GitHubAPI`, so the model, the panel and the indicator can
speak about a review decision or a checks summary without ever having seen a JSON
key.

### `GitHubAPI.swift` — the one schema file

The five parsers, the key-path accessors (each takes the path it is reading under
and reports it on failure, so the string in the error is the string somebody can
paste after `--jq`), `GitHubSchemaError` with its three cases and their sentences,
and the summary rule (G2). The three tables part 2 added refuse an unrecognised
word the way every other one does, naming the key path that carried it.

`pullRequest(fromViewJSON:)` is the fifth parser and deliberately **not** a fifth
schema: it is the *same row decoder* `pullRequests(fromListJSON:)` runs, applied
to one object instead of an array element, so the row the wait re-reads is the
same shape read by the same code as the row the button was drawn from.

`pullRequestNumber(fromCreateOutput:)` is the file's **one deliberate
non-refusal**: `gh pr create` has no `--json`, its whole answer is the new pull
request's URL on stdout, sometimes preceded by informational prose, and the
**last** `…/pull/<n>` in the output is the answer. It returns `nil` rather than
throwing because by the time it is called the pull request **exists** — refusing
would report a failure for an operation that succeeded, and the refresh that
follows lists the new row regardless. The number only decides whether it can be
pre-selected.

### `GitHubCreatePlan.swift`

The sheet's pure half (G11): `base`, `headBranch`, `push: PushPlan`,
`plan(context:base:)`, `refusal`, `canCreate`, `baseSentence`, `publishSentence`
and `uncommittedChangesNote`. Pure and Foundation-only, the way `PushPlan` and
`CommitGate` are.

### `GitHubMergePlan.swift`

The merge sheet's pure half, in `GitHubCreatePlan`'s shape and read by three
readers (G13): `GitHubMergeRefusal` — the seven-case closed table, each case
carrying its `message` and its own `isArmable` / `mayResolveByWaiting` — and
`GitHubMergePlan` itself, which carries the row **whole** (the guard needs that
row's `headRefOid`, and a plan and a head from two readings is the mismatch
`--match-head-commit` exists to prevent), the repository, and the checked-out
branch.

What it answers: `refusal` (the ordered rule), `canMerge`, `allowedMethods` (the
repository's three flags, in `GitHubMergeMethod`'s own declaration order),
`defaultMethod` (the viewer's, falling back to the first allowed — GitHub answers
`viewerDefaultMergeMethod` from a stored preference the repository can have
disallowed since, and opening on a disallowed method sends a `pr merge` GitHub
refuses), `showsMethodPicker` (one allowed method is not a choice),
`defaultSubject` (`<title> (#N)`, GitHub's own default), the three sentences
(`mergeSentence`, shown **whether or not** Merge is enabled — which is exactly
when a reader is looking for what the sheet is about — `deleteBranchSentence`, and
`tailSentence`), `isTailOwed`, and the button: `armsWait`, `buttonTitle`
(`mergeButtonTitle` / `armButtonTitle`), `buttonIsOffered` and
`buttonIsEnabled(method:subject:)` — the last carrying the two things only the
open sheet knows, the selected method and what has been typed, so a
commit-producing method with an empty subject cannot send `--subject ""`.

`canMerge` and `armsWait` both carry a second term, `!allowedMethods.isEmpty`:
that is the way this is off *without* a sentence, exactly as the create plan's
empty base is. A repository allowing none of the three methods has nothing to
send now and nothing to send in half an hour either, GitHub does not permit that
state, and inventing a sentence for it would explain a configuration nobody can
make.

### `PullRequestMergeWait.swift`

The armed wait (G14): `PullRequestMergeWaitEnding` — the closed four-case table,
with `message` `nil` for the two endings that speak for themselves — and the
`@MainActor` model itself, owned by `PullRequestModel` and holding it `unowned`
for the transport and the write.

The two numbers are named constants (`pollInterval` 30 s, `deadline` 30 min), and
`deadlineMessage` names the minutes *out of* the constant rather than spelling
"30" a second time. `armed` (the number and exactly what the merge needs — method,
subject, body; deliberately **not** the row's title, which the panel draws from
its own row, and deliberately not the head the arm was made against, since each
tick merges with the head *that tick* read), `elapsed` (published from `now` at the top of every tick, so **no view
runs a clock**) and `ending` are the published state; `now`, `sleep` and
`didMerge` are the three seams; `isArmed`, `isWaiting(on:)`, `elapsedLabel`
(`m:ss`) and `acknowledgeEnding()` are what the surfaces ask.
`arm(plan:method:subject:body:)` refuses **without a sentence** in the two states
the button offering it cannot be in (a refusal that is not `isArmable`, a method
the repository disallows) and cancels whatever is armed before replacing it, so
there is no path that leaves two loops polling one repository. `cancel()` is
idempotent, silent when nothing is armed, and cancels the loop's task as well as
moving the token — the token already guarantees nothing is published, but a real
sleep would otherwise hold a task alive for up to 30 s past a project switch.

`run(_:token:)` is one read, one decision, one sleep, and `finish(_:token:)` is
its single exit, bumping the token as it lands so anything still suspended
resumes into a moved token and publishes nothing. The one thing published *past* a
moved token is the merge's own ending, and the comment there says why: it is a
fact, not a decision this wait is still entitled to make.

### `PullRequestModel.swift`

The `@MainActor ObservableObject` behind both surfaces. Published: `availability`
(optional — a panel opening on "not found" before it has looked would accuse a
good install of not existing for as long as the probes take), `pullRequests`,
`currentBranchPullRequest`, `checks`, `expandedNumber`, `selectedNumber`,
`createPlan`, `mergePlan`, `errorMessage`, `isLoading`, `isWriteInFlight`, plus
the `lazy` `mergeWait` companion and `mergeIsAvailable` — the one term every row's
Merge button disables on, which is `isReady` plus `isWriteInFlight` plus "no wait
is armed anywhere". The first two are **also refused on** in `merge(…)`, so the
rule holds even when a button forgot to disable; the wait term deliberately is
not, and cannot be — the wait's own merge runs while the wait is armed — so that
term is stated as a surface rule rather than assumed to be enforced twice.

`refresh(branch:)` is the whole read path in the one order it ever runs:
availability, the list, then the `--head` lookup (skipped on a detached HEAD
rather than asked with an empty string, since "no branch" is not a branch whose
pull requests could be listed; an empty array is "no pull request", never an
error). `expand(_:)` bumps the checks token **including when it collapses**, so a
load whose row the reader has since closed publishes nothing. `checks` are kept
across a refresh for rows still open — an expanded row whose jobs vanished while
the list reloaded would flicker — and pruned for rows that are not, so a closed
pull request's jobs cannot appear under a reopened one that reused nothing but
the key.

**A refresh re-reads the expanded row's jobs**, last, after the list and the
`--head` lookup: five commands when a row is open, four when the panel merely
shows one, three otherwise. The badge and the jobs beneath it are read by two
different commands — the summary off `statusCheckRollup` in the list, the list of
jobs by `pr checks` — and re-reading only the first leaves them contradicting each
other on screen: the badge flips green while every job underneath still says
"pending", and Refresh, the one control there is for exactly that question,
appears to do nothing to the detail being watched. The re-read carries the same
token bump and the same failure-clearing `expand(_:)` does, so a row that failed
last time is read from scratch rather than left asserting an old sentence; it is
scoped to a row still both expanded *and* open (`pruneChecks(keeping:)` has
already collapsed one that closed), so a collapsed panel costs a refresh nothing.
It runs after the refresh's own message so that the sentence about the row the
reader is looking at speaks last, and `isLoading` comes down only once it has
landed, because a read is genuinely still in flight until then.

`prepareCreate()` reads `repo view` and the commit context under the create
token; `setCreateBase(_:)` re-plans synchronously (the repository state was
already read; only the base changed). Both sheets **plan from a local and
publish `repository` only on a read that succeeded**: that one value is shared —
the merge plan is decided from it and `PullRequestMergeWait` re-reads it on every
tick, treating `nil` as "the world this wait was armed in is gone" — so a base
read that failed empties *this sheet's* base and nothing else. Blanking it there
would end an armed wait with `stateLostMessage`, about a row that never
left, merely because New Pull Request was opened beside it, and permanently so
when that sheet's own `repo view` failed too. Only the two states that really are
a different world blank it, and both are `clearRows()`'s: the project root
changing, and `gh` going not-ready. `create(...)`, `merge(...)` and
`checkout(_:)` are the three writes (G10–G13). `checkout(_:)` is **synchronous**
and deliberately so: it is called from a button, its answer is "was this
accepted", and everything after the hand-out belongs to the bracket.

The merge half is a **fourth generation token** (bumped in `prepareMerge(_:)`, in
`merge(...)` and in `clearRows()` beside the create's) and a fourth `ErrorSource`.
`prepareMerge(number:)` reads `repo view` and the checked-out branch as the sheet
opens: a failed `repo view` leaves `mergePlan` `nil` — hence Merge disabled and
`gh`'s words in the slot, which is what the create sheet's failed read already
does. **Its two guards publish too**, and that is load-bearing rather than tidy:
the sheet draws its spinner on "no plan *and* no message" and its `.task` runs
once, so a guard returning silently is a modal reading "Reading this repository's
merge settings…" until it is cancelled, with no retry and no reason. A not-ready
`gh` or absent root gets `unavailableMessage`, and a row a refresh dropped between
the press and the read — the honest case, somebody else merged it — gets
`mergeRowMissingMessage`, which is what `merge(…)` already says for the same two
conditions. A failed *branch* read is deliberately weaker and not fatal, because
the merge does not depend on what is checked out locally and a sheet must not
refuse to merge a pull request because `git` could not name a branch.
`dismissMerge()` clears only the merge's own sentence and deliberately **not** the
plan, which the row's own controls keep reading after the sheet closes.

`merge(number:method:subject:body:)` is the write, with six refusals in the order
they are asked, **each of them with a sentence**: the one-write flag
(`mergeBusyMessage` — its own constant rather than the gate's, since it names a
different state and a different cure, and *not* a dead branch behind a disabled
button, because the wait's merge does not go through a button at all and a silent
refusal there would end a wait with nothing merged and nothing said), the gate
(`mergeBlockedMessage`), a not-ready
`gh` or absent root, the row no longer in hand (`mergeRowMissingMessage`), a plan
that re-decides as not mergeable (the refusal's *own* sentence, so button, model
and wait word one state one way), and a method the repository does not allow
(`mergeMethodMissingMessage` — unreachable from the picker, which is exactly why
it is refused here too). It raises and lowers `isWriteInFlight` on every exit
path, and on success re-reads the list — the merged row leaves it, which is also
how the bottom-bar indicator clears — where nothing below the merge may report a
failure, since the pull request is merged from the moment `gh` answered. The
`internal` `merge(row:…)` overload is the same method entered from the wait with
**that tick's** row rather than the list's, which is the whole point of a wait
acting on a reading newer than the list's.

The tail's half is `MergeOutcome` (returned, never published — it is the answer to
one merge, read once, and a published copy would sit there naming refs that no
longer exist), carrying the number, the base, `isTailOwed` and **the root the
merge was sent in**, `MergeTailStep` / `MergeTailRunner` / `MergeTail`,
`mergeTail(for:branches:)` and `runMergeTail(_:branches:confirm:run:)` (G15). The
tail's one refusal sentence, `tailBranchMissingMessage(base:)`, lives here rather
than in the coordinator that runs the tail, for the reason every other sentence in
this file does: it is then testable without a view, and there is one wording of
it.

## The app half (`Sources/Pisaka/`, all `#if os(macOS)`)

### `ExecutableLocator.swift`

The one definition of "where is a program somebody else installed", lifted
verbatim from `LSPRustToolchainService` — which is now one of its two callers,
the other being `GitHubCLIProcessTransport`. `locate(_:wellKnownDirectories:runningProgram:)`
returns a `Found(path:searchPath:)`; `pathEntries`, `executables(named:in:)` and
the login-shell step are here too. Nothing in it launches anything: the one step
costing a subprocess is handed out as a closure, because *how* a program is run —
which registry the child goes in, which deadline it gets, what happens on quit —
is the caller's business and differs between the two.

**`LSPGoToolchainService` is deliberately not a caller**: it carries a directory
list and decisions of its own, and folding it in would mean changing them. One
definition, two callers, pinned by `GitHubSourceGatingTests`.

### `GitHubCLIProcessTransport.swift`

The **one** file in this app that runs a `Process` for `gh`. It finds a `gh`
(G7), starts it with Core's environment overlay merged over the inherited one and
`currentDirectoryURL` set to the repository root, drains both pipes, bounds the
command with its deadline (SIGTERM→SIGKILL, `LSPRustToolchainService`'s
escalation verbatim), and hands back both streams and the status. It never
retries a command, never reads a status and never looks at a byte of output —
except the one program it runs that is not `gh`, the login shell whose `PATH` it
reads.

`@unchecked Sendable` over an `NSLock`, `LSPRustToolchainService`'s arrangement:
the lock guards the cached location and the live-child registry, is never held
across a subprocess wait, and every launched process is reachable from
`terminateNow()`, which signals each child's whole **process group** — so a quit
during a `gh pr checkout` leaves behind neither `gh` nor the `git` it shelled out
to. `gh` is the one `gh` word in the app layer, and it is a binary name, not an
argument.

This file is the **stated exception** to the feature's no-polling rule: its
command deadline and teardown grace are a `Thread.sleep` loop plus a
`DispatchSemaphore.wait(timeout:)` — a per-command bound on a child process, not
a repeating read. It is still held to the `Timer` half of the ban, because a
timer there could only be a repeat.

### `PullRequestCoordinator.swift`

The `DatabaseViewerTabs` analogue: it owns the model and the transport, is wired
once from the scene through
`start(root:branchSwitcher:isWriteBlocked:runBracket:confirmCheckout:didWrite:)` — idempotent,
because `.onAppear` can fire again for a reopened window, and assigning a second
branch observer cancels the first rather than leaving two sinks — and holds
**every site** through which this feature reaches the writer bracket: three of
them, one per gated operation it owns (`.pullRequest` for the checkout, `.branch`
for the tail's switch, `.pull` for the tail's pull). The model is
`lazy` because its four closures read back through `self`: the root, the gate and
the bracket are answers the scene supplies after this object exists.

It owns the refresh triggers (G9), answers `localBranchNames` for the sheet's
base picker (read from the branch model the widget already keeps refreshed rather
than asking git a second time — two lists of the same branches are two lists free
to disagree) and `headSubject()` for the pre-filled title (a failure here is
silent: it is a *suggestion* for a field the reader is about to type in, and a
sentence explaining an empty field would talk over the one slot the sheet keeps
for refusals that actually stop a pull request being opened). The sheet *awaits*
that subject and only then tests whether the field is still empty — never
`if title.isEmpty { title = await … }`, which asks before the suspension and
assigns after it: `headSubject()` queues behind every other `git` on
`GitCLIService`'s one serial run queue, and a title typed in that window would be
silently overwritten by the commit subject.

`checkout(_:)` is its one write entry point, and the two refusals above are
what it exists for — asked *after* the one-write flag, which is the order the
model refuses in, so a checkout arriving while one of this feature's own writes is
running cannot draw a sentence and a modal for an operation the model will refuse
silently a moment later; `terminateNow()` is its one teardown one, forwarded to the
transport from the scene's terminate observer beside the language servers' own —
a `pr checkout` in flight has a `git` beneath it rewriting a worktree, and
nothing else can reach it once the process is going away.

`didWrite` is the scene's own post-write hook: the bracket's tail resyncs tabs and
refreshes the tree, Local Changes and Log, but **not** the branch widget, because
the seven operations before this one all move the branch through
`BranchSwitcherModel` itself and leave it already correct. `gh pr checkout` moves
it from outside.

`merge(number:method:subject:body:)` is the second write entry point and the one
route from a surface to the tail; nothing is asked here first, unlike the
checkout, because a merge puts no modal in front of anybody and has no answer only
the scene can give. `runTail(_:)` hands the outcome, the widget's branch list and
the dirty-tree confirmation to `PullRequestModel.runMergeTail(…)` — which owns the
decision, the order and the stop-at-first-failure rule, so they are asserted in
`swift test` rather than described here — and `runTailStep(_:_:)` is where each
step goes inside the bracket under its own event, with the widget's refresh
generation pinned **synchronously** in that turn (`switchBranch`'s rule: a folder
switch landing in the gap makes the checkout bail rather than move the newly
opened repository's worktree). Neither step's failure is published into the
panel's slot: the merge landed, and this model's one sentence must not start
saying otherwise. The same method wires `mergeWait.didMerge`, so the merge nobody
was standing in front of reaches the identical tail.

A **fourth** subscription-like duty landed here with the wait: `$root` cancels it
on a project switch, and `terminateNow()` cancels it before signalling the
transport. Both are the same reasoning as the rows being cleared, only sharper — a
wait polls one pull request by number in whatever root is current when its tick
composes the command, so half an hour of it under a repository nobody opened would
end by merging project A's pull request from inside project B, then switching
*B's* worktree to A's base branch. A tick waking after the terminate observer
would do the same to a project the app has stopped having open.

### `PullRequestsPanelView.swift`

`UsagesPanelView`'s shape — header, divider, scrolling rows — plus a **not-ready
state with a next step**, printing `GitHubAvailability.message` and `.nextStep`
verbatim. Rows carry the number, title, author, `head → base`, the draft marker,
the review decision and the checks summary, with Checkout, Merge and Open in
browser per row and an expandable per-job list whose entries link to their own
runs. There are exactly **two** disable terms, both Core's: `isWriteInFlight`
(Checkout, New Pull Request, Refresh) and `mergeIsAvailable` (every row's Merge),
neither re-derived from its parts here. The row a wait is armed on shows its
elapsed time — published by the wait, never timed here — and a Cancel button **in
place of** its Merge button, the two being exclusive by construction rather than
by a disable; how the last wait ended, when it ended with something to say, is a
dismissible strip of its own above the list, because two of the four endings land
in a panel nobody was watching and must not overwrite the model's one message
slot. The panel-shown trigger is the single
`.onAppear` here. The panel root states **no** minimum height, which is
`BottomPanelSourceGatingTests`' per-panel rule, pinned by set equality against the
switch's case labels.

### `NewPullRequestSheet.swift`

`CommitDialogView`'s shape: title (pre-filled from `HEAD`'s subject), body, the
base picker over the local branch list defaulting to `repo view`'s answer, a
Draft checkbox, and above the buttons the three sentences naming everything
Create will do. A failure leaves the sheet open with every field intact — the
reader has just typed a description.

### `PullRequestMergeSheet.swift`

`NewPullRequestSheet`'s shape, and **nothing here decides anything**: the method
picker (absent when the repository allows exactly one), the pre-filled subject and
the optional body (both hidden for Rebase, which composes no commit), the three
stated sentences — what will be merged, the tail or its absence, and GitHub's own
branch deletion when it is on — and the button's label are
all `GitHubMergePlan`'s; the button's *enablement* is the plan's own term **and**
the model's `mergeIsAvailable`, which is this feature's one-write rule and the
no-second-wait rule the sheet has no business restating. **The button is two buttons**: *Merge* when the plan
allows it, *Merge when checks pass* when the plan's refusal is `isArmable`, which
is the plan's `armsWait`; every other refusal disables it under that refusal's own
sentence. It observes the wait as well as the model, since it is the one place a
wait is armed and a sheet drawing its button from a wait it never hears from would
be stale the moment one was. A failure leaves the sheet open with every field
intact and `gh`'s own words under them (the create sheet's reason); a merge that
landed closes it, and so does an arming, whose whole point is to stop anybody
sitting in front of it.

### `PullRequestIndicatorView.swift`

Beside the branch switcher: `#N` plus the checks state, for the branch checked out
right now. **Absent rather than empty** — nothing is drawn when the branch has no
open pull request, when `gh` is not ready, or on a detached HEAD, all three of
which are `currentBranchPullRequest == nil`. Clicking opens the panel with that
row expanded. It reads the same model the panel does: one `gh` answer, two
surfaces, no second read. Part 2 gave it **no new
action**: the click already lands on the row where Merge lives, and a second merge
entry point in the bar would be a control offering a sheet beside a row that
offers the same one. Chrome, sized through `\.interfaceMetrics`, declaring no
zoom surface, like every other control in the bar.

### The two files that were only touched

`ContentView.swift` gained the sixth bar button, the `panelContent(_:)` branch and
the indicator in `bottomBar`. The button's glyph is `arrow.triangle.merge` rather
than `arrow.triangle.pull`, which Changes two buttons to its left already uses —
two adjacent dock buttons drawn with one symbol are indistinguishable at a glance.
The indicator expands its row **only when the panel has one**: its pull request
comes from the `--head` lookup, which is independent of the `--limit 50` list and
survives a failed read of it, so on a repository with more open pull requests than
that the row may not be there, and expanding a number nothing draws would spend a
`gh pr checks` call to change nothing.

`PisakaApp.swift` gained one `@StateObject`, one
`pullRequests.start(…)` block in the existing start-once section, one View-menu
item, `pullRequests.terminateNow()` in the terminate observer,
`runBranchOperation`'s generalisation (G12) and — for the tail — its **optional
completion**, the parameter plus the two calls to it on the success and failure
paths (G15). That is the whole of the scene's share in the ninth gated operation:
the tail's order, its two steps and their events are the coordinator's, and the
rule behind them is Core's. Those lines moved both measured lint ceilings, in the
steps `.swiftlint.yml`'s comments and `style-lint.md` record: `file_length`
1838 → 1859 → 1861 → 1862 → 1882 → **1885**, `type_body_length`
1822 → 1843 → 1845 → 1846 → 1866 → **1869**. It names no refresh trigger and no
`gh` argument.

## Tests

Core suites: `GitHubCommandsTests` (every argument list byte for byte, and
`refreshesExecutableLocation` true for the version probe and false for every
other factory, by set equality), `GitHubVersionTests`, `GitHubAvailabilityTests`,
`GitHubAPITests`, `GitHubChecksSummaryTests`, `GitHubCreatePlanTests`,
`GitHubMergePlanTests` (the enabled rule across every combination of its four
inputs, each refusal's sentence, `isArmable`/`mayResolveByWaiting` per refusal,
the method list, default and no-picker rule, and every sentence and button label),
`PullRequestModelTests`, `PullRequestCheckoutTests`, `PullRequestMergeTests` (the
argument list actually sent, each refusal, the one-write rule across all three
writes, the message slot's source rules, and the tail's order, its
stop-at-first-failure rule and its three switch cases) and
`PullRequestMergeWaitTests` (the two constants, the sleep as a seam, each of the
four endings, that no tick composes a `pr checks` command, a poll invalidated
in flight by a moved token, and the plan-driven table tick by tick), plus the new
cases in `BottomPanelTests`, `GitErrorTests`, `LocalHistorySnapshotTests`,
`BottomPanelSourceGatingTests`, `LocalHistorySourceGatingTests` and
`LintConfigurationTests`.

**No wait test spends wall-clock time.** `now` and `sleep` are seams, so the
deadline — sixty sleeps deep — is reached by handing the clock a later date, and
the suite's cost for the whole state machine is the cost of the arithmetic.

`Tests/PisakaCoreTests/Support/ScriptedGitHubCLI.swift` is the seam's fake:
answers keyed by the argument list, a queue per key with a sticky last step, an
unscripted call **throws**, every call logged in order, and a `Gate` per key so a
test can hold a call mid-flight and stage the token races causally rather than
with a sleep.

A gate can be scoped to **one call** (`hold(_:on:forCall:)`), and for a
generation-token test it must be: holding the key holds *both* racers, so
releasing twice resumes them in call order, the stale run publishes first and the
fresh answer lands on top of it — the final state is identical whether or not the
token was ever checked, and the test passes over the deleted guard. Holding the
first call alone lets the fresh run finish while the stale one is still on the
wire, so the stale run publishes **last** and the assertion has something to
catch.

`Tests/PisakaCoreTests/Fixtures/github/` holds real captures — recorded with
`gh version 2.99.0` against this repository, the three files the merge fields grew
re-recorded verbatim when they did, with provenance in its own `README.md` —
including the single-object `pr-view.json` the wait's parser reads, of **the same
pull request** `pr-list-merged.json` holds, so the two together assert that a row
read by number and a row read out of a list are one value under one set of tables.
Beside them the hand-built ones: the mixed `__typename` rollup, an unknown
conclusion, and an unknown `mergeable` / `mergeStateStatus` word each naming the
key path that carried it. They are read through `#filePath` like every other fixture
tree and are listed in the test target's `exclude:` in `Package.swift`. **No test
in this repository ever runs `gh` or reaches the network**; `swift test` stays the
offline, dependency-free gate it has always been, and the test target cannot link
`Process` at all — which is the whole reason the vocabulary lives in Core.

`GitHubSourceGatingTests` is the cross-layer suite, in the
`DatabaseViewerSourceGatingTests` shape, with the full inventory in its doc
comment. It pins: `Process` for `gh` in exactly one app file and never in Core;
every app-side file `#if os(macOS)`-gated, by set equality over the feature's file
list (the four views now, the merge sheet among them); the iOS layer naming none
of it; **no `gh` argument spelled in the app layer** — part 2's vocabulary
(`--merge`, `--squash`, `--rebase`, `--subject`, `--match-head-commit`, and the
`pr merge` / `pr view` subcommands) banned there and required in
`GitHubCommands.swift`, whose counts are **ten factories over nine subcommands**;
the three bracket call sites living in the coordinator alone, with the scene
handing the bracket over once and no file under the feature naming the gate; the
locator's one definition and two callers; the refresh triggers living in the
coordinator and the panel view only, with the scene naming none (it touches the
coordinator exactly twice, to wire it and to tear it down); and the no-polling ban
over the Core files and the four views, with **two** stated exceptions —
`GitHubCLIProcessTransport.swift` (a per-command bound on a child process) and
`PullRequestMergeWait.swift`, pinned term by term: the two bounds are named
constants declared once, the sleep is exactly one injectable seam, `Timer` and
`asyncAfter` stay banned, and `GitHubCommands.checks` may not appear in it at all
(G14).

It uses **two strippers, deliberately**. Most rules read
`LSPSourceGatingTests.strippingCommentsAndStringLiterals`, this repository's usual
scanner. The `gh`-vocabulary rule cannot: `--json` and `"pr", "list"` *are* string
literals, so that scanner would delete the very thing the rule is about and pass
on an app file that ran `gh` behind Core's back. That one rule reads a
comments-only stripper instead — which matters here more than usual, because
several of these files quote the very tokens the suite matches (the coordinator's
doc comment spells `autosave.suspend()`, the transport's spells `gh --version`),
so a raw `contains` would stay green after the call site it names is deleted and
would fail the moment somebody explained the rule.

## Known limits

- **macOS only.** There is no iOS surface and no iOS transport: iOS has no
  subprocesses, so `gh` cannot run there at all.
- **`gh` is not shipped, discovered.** No `gh`, a `gh` older than 2.50.0, or one
  not signed in are three states the panel names with the command that fixes each
  — not failures it works around.
- **No review, no approvals, no comments.** The feature lists, reads checks,
  creates, checks out and merges. Everything else is a browser away, one explicit
  gesture from each row.
- **The merge is the ordinary one.** No `--admin` (merging past the repository
  rules the enabled rule just checked), no `--auto` (GitHub's server-side
  auto-merge — the armed wait is this app's visible, cancelable answer to the same
  question, and it stops when the app does), and no branch deletion of any kind:
  `deleteBranchOnMerge` is read only so the sheet can say what GitHub will do on
  its own side.
- **The wait is bounded and local.** 30 minutes at 30-second ticks, in this
  process: quitting, switching project or arming another wait ends it, and
  nothing survives the app run. It arms only from "checks are still running" —
  every other refusal is a state waiting cannot change.
- **The tail is `--ff-only` and nothing else.** A base branch that cannot
  fast-forward is reported, never merged or rebased into; a base that is neither
  a local ref nor a remote one carrying `<base>` in the branch widget's list stops
  the tail with its own sentence. The merge is still done — the tail moves only what is
  local.
- **The list is capped at 50 open pull requests**, and the checks list is
  whatever `pr checks` answers for one pull request. The header says so: at the
  cap it reads `50+ open`, never `50 open`, because `pr list` asked for fifty rows
  and a total is not something this panel was told.
