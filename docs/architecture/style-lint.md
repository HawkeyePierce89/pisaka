# Style lint — one enforced style

The SwiftLint gate: what makes style *enforced* rather than conventional. The
static pin for everything here is `Tests/PisakaCoreTests/LintConfigurationTests.swift`
(see that suite's doc comment for the full assertion inventory); this doc
carries the rationale and the procedures.

## Contributor setup

One time per clone:

```sh
# The pinned release is the reliable route — brew's formula can be a different
# version, and only the pinned one passes the gate. Unpack in a scratch
# directory and take the binary alone: the archive also carries a `LICENSE`, so
# unzipping it inside a clone would prompt to replace this repository's own —
# and answering yes would overwrite Pisaka's license with SwiftLint's.
tmp=$(mktemp -d)
curl -fsSL --retry 3 -o "$tmp/swiftlint.zip" \
  https://github.com/realm/SwiftLint/releases/download/0.65.1/portable_swiftlint.zip
unzip -q "$tmp/swiftlint.zip" swiftlint -d "$tmp"
install -m 755 "$tmp/swiftlint" /usr/local/bin/   # or any directory on your PATH
rm -rf "$tmp"

brew install swiftlint    # alternative; whatever it serves, the check below decides
swiftlint version         # MUST print 0.65.1 — any other binary is refused

make setup                # wires the hooks and confirms the linter is present
```

`make setup` is the blessed form; wiring by hand stays available as
`git config core.hooksPath .githooks`. From then on every commit lints exactly
what is being committed (`--strict`) and refuses violations instead of fixing
them.

## The authority and its two files

`.swiftlint.yml` at the repository root is the single style authority: every
relaxed, disabled or re-tuned rule carries a written reason beside it.
`Tests/.swiftlint.yml` is a nested child whose `disabled_rules` apply to the
test tree only — SwiftLint discovers nested configs from the invocation
directory and **merges** them into the root file, so `swiftlint lint --strict`
with no `--config` (the only blessed form) judges both trees under one merged
document.

Two files exist because the alternative — thresholds raised above the largest
*test* file — would switch `file_length`/`type_body_length` off for `Sources/`
too. The child widens nothing for application code; `LintConfigurationTests`
pins both files' `disabled_rules` by set equality so a quietly widened
exemption fails `swift test`.

## The measured ceilings

`file_length` and `type_body_length` are not round numbers and must never be
made into them. Both are **measured** off the one file that approaches them —
`Sources/Pisaka/PisakaApp.swift`, whose `PisakaApp` struct body is very nearly
the whole file — so the next line added there comes back through the config, and
raising the ceiling is a decision with a written reason rather than a reflex.
The procedure, when a feature genuinely has to land in that file:

1. Run `swiftlint --strict` and read what the file actually measures.
2. Raise the ceiling to **that number**, never rounded up for room.
3. Append the reason to the ceiling comment in `.swiftlint.yml`, in the voice of
   the entries already there — the comment is a history of why the number is
   what it is, and each entry names what was added and what it bought.
4. Update both numbers in `LintConfigurationTests.documentedRootThresholds` in
   the same commit; the suite fails until they agree.

The database viewer set the shape to copy (`file_length`
1809 → 1826 → 1829 → 1833 → 1837 → 1838, `type_body_length`
1800 → 1810 → 1813 → 1817 → 1821 → 1822 — the second step is the viewer reconnect
`resyncViewerTab` gained on review, the third the find menu's
`isFindableTabSelected`, the fourth the write wiring
`databaseViewers.start(isWriteBlocked:didWrite:)`, the fifth the rename's
`databaseViewers.retarget(id:url:)`): everything
with a state shape of its own went into `DatabaseViewerTabs.swift`, so
`PisakaApp` paid four lines of wiring plus the tab-kind skips its own text-shaped
passes needed, and not four hundred (`core-database-viewer.md`).

The most recent bump is the Pull Requests feature (`file_length`
1838 → 1859 → 1861 → 1862 → 1882 → **1885**, `type_body_length`
1822 → 1843 → 1845 → 1846 → 1866 → **1869**;
the second step is the review's, for the checkout's dirty-tree confirmation and
the terminate observer's `pullRequests.terminateNow()`, and the third is a later
review's one line — the three branch-checkout entry points now refuse while
another writer holds the gate, which the bracket they share raises but never
reads, and the fourth is the last review's twenty: the shared bracket's failure
path now re-reads the branch and runs the success tail when `gh pr checkout`
failed *after* already switching the worktree, the one thing a single
`git checkout` could never do, and the fifth is part 2's three: the shared
bracket gained an **optional completion** called on both paths — one parameter
and two calls — because it is fire-and-forget and the post-merge tail is two
bracketed operations that cannot be ordered without one, which is the whole of
the scene's share in the ninth gated operation) — the largest single move either number has
made, which is why it is itemised rather than absorbed. Twenty-one lines, all of
them inside the struct body, so the two ceilings move by exactly the same amount:
**seven** are `pullRequests.start(…)`, the scene's whole involvement in the eighth
gated operation, since the feature's ownership, its transport and its one checkout
site live in `PullRequestCoordinator.swift`; **five** are the View menu's panel
toggle; **one** is the `@StateObject`; and the remaining **eight** are
`runBranchOperation` growing a Local History event parameter and an operation that
answers a message instead of a `Bool` — which is what lets one bracket serve two
callers rather than two brackets serve one each; part 2 then added **three** more
of exactly that kind, the completion parameter and its two calls, which is what
lets that one bracket serve the tail's two ordered operations as well. The same
shape as the viewer's, and the reason a feature this size cost twenty-one lines
here — twenty-three with the review's two, and forty-seven all told once the two
later reviews and part 2 had landed (`core-github.md`).

## The three-way version pin

`swiftlint_version:` in `.swiftlint.yml` is the one pin. It is enforced twice
because SwiftLint itself only *warns* on a mismatch:

- `.githooks/pre-commit` refuses when `swiftlint version` differs from it,
  reading the pin out of the index copy of `.swiftlint.yml` (`git show
  :.swiftlint.yml`) so a partially staged config edit cannot make the enforced
  pin and the applied rules come from two different versions of the file;
- ci.yml's `lint` job downloads exactly the release whose URL names the pinned
  version and verifies the archive's SHA-256 before running it.

`LintConfigurationTests` asserts the cross-file pair (CI URL version component
equals the config pin) and that the hook carries no version literal of its own,
so the three cannot disagree. Bumping SwiftLint therefore means: change
`swiftlint_version:` in `.swiftlint.yml`, re-download the release asset,
recompute its SHA-256, and update the URL + digest in ci.yml — the suite fails
until every site has moved together.

## What the pre-commit hook does, and why

- **It lints what is being committed, not the worktree**: `git checkout-index
  -a --prefix=` materialises the whole index (both config files travel with
  it) into a scratch tree, and the staged paths are judged there. A partially
  staged file is measured by the content the commit will carry.
- **Its staged-file list covers exactly the trees `included:` names**
  (`'Sources/*.swift' 'Tests/*.swift'`). The paths are then handed to
  swiftlint *explicitly*, and explicit paths bypass `included:` (only
  `excluded:` applies under `--force-exclude`) — an unscoped `'*.swift'` would
  judge e.g. root-level files CI's discovery-mode run never sees, and the two
  gates would disagree about one commit.
- **It refuses; it never rewrites.** No `--fix`: a hook silently editing
  already-staged content is content loss.
- **No graceful degradation**: no `swiftlint`, wrong version, unreadable pin,
  violations — all refuse with actionable messages. Skipping is how a violation
  gets in.

## How the hook gets enabled

Git never enables a repository's hooks by itself: `.git/hooks` is not cloned
and `core.hooksPath` is per-clone local config. That is a security stance, not
an omission — a repository that could run its own scripts on `git clone` would
be remote code execution. Every ecosystem that *appears* to install hooks
automatically is riding on a step the developer had to run anyway (husky's
`prepare` script, run by `npm install`).

This project has no single such step. `Package.swift` declares **no external
dependencies**, so `swift test` installs nothing, and SwiftPM evaluates its
manifest in a sandbox — verified: a `Process` launched from a manifest produces
no side effect, with or without `--disable-sandbox`. There is no `preinstall`,
`postinstall` or `prepare` anywhere in SwiftPM, and build-tool plugins are
sandboxed while command plugins are explicit. So the wiring rides on the two
things people *do* run:

- **`make hooks`**, a prerequisite of every working `Makefile` target
  (`test`, `lint`, `generate`, `build`, `build-ios`), so anything run through
  make wires the clone. `make setup` does it explicitly and additionally
  refuses when the pinned linter is absent.
- **The `Wire git hooks` build phase** declared in `project.yml`, so generating
  the project and building the app — what every app contributor and every agent
  run does — wires it too. It is idempotent, silent on success, and exits 0
  where there is no git repository (an export or a `.git`-less CI checkout):
  it only *enables* a gate, so failing a build there would break building for a
  reason unrelated to the build. That is not the graceful skip the hook itself
  refuses to make — the gate still refuses hard once wired, and CI refuses the
  pull request regardless.

What remains uncovered: a contributor who only ever runs `swift test` by hand,
never builds the app and never uses make. They commit unlinted locally, and
CI refuses the pull request. Wiring by hand stays available:
`git config core.hooksPath .githooks`.

## Why CI is the real gate

Hooks are local courtesy: not cloned, bypassable with `--no-verify`. The
`lint` job runs the identical check (`--strict`, no `--config`, whole tree)
independently of the build graph (`needs:` absent on purpose — style should be
the fastest feedback), cannot be non-fatal, and prints `./swiftlint --version`
before linting so each run's log records which binary judged it.

## In-file exemptions

A `// swiftlint:disable…` inside a source file is an exemption outside both
configs' authority, invisible to any `.yml` diff — which is how it slips past
review. Every such marker under `Sources/` and `Tests/` is counted by
(path, rule) in `LintConfigurationTests.documentedInFileExemptions`; adding,
moving or removing one fails the suite until the dictionary moves with it.
Use the narrowest form (`:next`) and write the reason beside it.
