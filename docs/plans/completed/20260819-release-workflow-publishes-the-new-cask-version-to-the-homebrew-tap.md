# Release workflow publishes the new cask version to the Homebrew tap

## Overview

`.github/workflows/release.yml` gains one step, after the GitHub Release is
promoted out of draft: it derives the version from the tag, hashes the exact
zip it just uploaded, clones `HawkeyePierce89/homebrew-apps` over SSH with a
deploy key, rewrites the cask's `version` and `sha256` lines, verifies the
result and pushes one commit to `master`. The deploy key's private half is a
seventh repository secret, refused in the preflight like the other six, written
only under `$RUNNER_TEMP` and deleted on every path. `ReleaseWorkflowTests`
grows to pin the step by mechanism; `docs/RELEASING.md` documents the secret
end to end, the manual fallback and the verification still owed.

## Context

- Files involved:
  - Modify: `.github/workflows/release.yml`
  - Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`
  - Modify: `docs/RELEASING.md`
  - Modify: `CLAUDE.md` (one clause: "six repository secrets" → seven)
  - Untouched, deliberately: `project.yml`, `Package.swift`, all of `Sources/`
- Related patterns:
  - The preflight's `-z "${SECRET}"` → `::error::` → `exit 1` shape, one
    refusal per secret with its own actionable message and a
    `docs/RELEASING.md` pointer.
  - The notarize step's key handling: `(umask 077; printf '%s' … > "$KEY")`
    plus `trap 'rm -f "$KEY"' EXIT`, with the final `if: always()` cleanup step
    repeating the removal by literal path (a cancelled step runs no trap).
  - `ReleaseWorkflowTests` reads the repository through `#filePath` with
    Foundation only, asserts over `activeLines()`/`stepScript(named:)`
    (comment- and blank-stripped), and proves refusals with
    `assertGuardExits(_:in:step:because:)` (the branch must reach `exit 1` at
    depth 0).
- Constraints this must not break:
  - `testEveryStepFailureStopsTheRelease` — the only `if:` in the file is the
    cleanup's `if: always()`, and no `continue-on-error:` anywhere. The new
    step therefore carries no condition and is fatal.
  - `testTheSigningKeychainIsRemovedOnEveryPath` — the cleanup step must remain
    the **last** step in the file, so the bump goes between "Publish the GitHub
    Release" and the cleanup.
  - `testTheJobBudgetCoversTheNotaryWait` — 90 − 30 = 60 ≥ ci.yml's 45; the
    added step changes no number and the assertion keeps holding unchanged.
- Facts established while exploring:
  - The live cask is exactly `  version "1.2"` and `  sha256 "79eb58…"`,
    two-space indented, one occurrence each; the `url` already interpolates
    `#{version}` on both the tag and the file name, so nothing else moves.
  - The shipped zip lives at `build/release-assets/Pisaka-${VERSION}.zip` —
    the same file `gh release create` uploaded, so the hash is of the exact
    published bytes rather than of a re-made archive.

## Decisions taken (flagged for review)

1. **Secret name: `HOMEBREW_TAP_DEPLOY_KEY`.** It names what it unlocks (the
   tap) and reads like the existing six.
2. **Preflight refusal too** (as answered): a missing tap key refuses the whole
   release in the first seconds; nothing is published and recovery is deleting
   and re-pushing the tag.
3. **The cleanup step is renamed** `Remove the signing keychain` →
   `Remove the run's keys and keychain`, because it now removes three private
   keys rather than two and the old name would be a lie about the third. This
   is one constant in the suite (`keychainCleanupStepName`), one `- name:` in
   the workflow and one bullet in `docs/RELEASING.md`.
4. **The SSH host key is pinned, not trusted on first use.** The step writes
   GitHub's published Ed25519 host key into a `$RUNNER_TEMP/known_hosts` and
   connects with `StrictHostKeyChecking=yes`; `accept-new`/`no` are asserted
   absent. A GitHub host-key rotation therefore fails the step loudly, which
   `docs/RELEASING.md` records alongside the other pins.
5. **An already-correct cask is success, not failure.** If the edit produces no
   staged change (a re-pushed tag whose zip hashes identically), the step says
   so and exits 0 rather than dying on `git commit`'s "nothing to commit". A
   *different* zip produces a different hash and therefore a real diff, so this
   cannot swallow a stale cask.

## Development Approach

- **Testing approach**: Regular (workflow edit first, then the matching
  assertions in the same task) — the suite is static verification of the file
  being edited, so both halves land together.
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass (`swift test`) before starting the next task**
- No secret material is ever committed; the workflow names the secret only.

## Implementation Steps

### Task 1: The preflight refuses a missing tap deploy key

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`

- [x] Add `HOMEBREW_TAP_DEPLOY_KEY: ${{ secrets.HOMEBREW_TAP_DEPLOY_KEY }}` to
      the `Preflight` step's `env:` block.
- [x] Add refusal 9 after the five Apple ones: `if [ -z
      "${HOMEBREW_TAP_DEPLOY_KEY}" ]` → `::error::` naming the secret, saying it
      is the private half of a write-enabled deploy key on
      `HawkeyePierce89/homebrew-apps`, pointing at `docs/RELEASING.md` → `exit 1`.
- [x] Update the step's leading comment: it currently says "the five
      signing/notarization secrets reach this step through `env:`" — restate it
      as six secrets, of which the tap key is the one that gates *distribution*
      rather than signing, and say why it is refused up front (a release whose
      cask cannot be bumped is a release the workflow would publish and then go
      red on, with the recovery being manual).
- [x] Add pinned constants to the suite: `tapDeployKeySecret`,
      `tapRepositorySlug` (`HawkeyePierce89/homebrew-apps`), `caskPath`
      (`Casks/pisaka.rb`), `caskBumpStepName`, `tapDeployKeyPath`
      (`${RUNNER_TEMP}/homebrew-tap-deploy-key`).
- [x] Extend `testPreflightRefusesEveryUnshippableRelease` with the tap secret
      as its **own** assertion pair (not appended to the five-secret loop,
      whose `because:` text is about signing and notarization): the `-z` guard
      reaches `exit 1`, and the `env:` mapping line is present verbatim.
- [x] run `swift test` — must pass before Task 2.

### Task 2: The cask bump step

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`

- [x] Insert `- name: Bump the Homebrew cask` between `Publish the GitHub
      Release` and the cleanup step, with `env:` carrying only
      `HOMEBREW_TAP_DEPLOY_KEY` and `run: |` under `set -euo pipefail`, reading
      top to bottom as: version derivation → hash → key → clone → edit →
      verify → push.
- [x] Version and hash: `TAG="${GITHUB_REF_NAME}"`, `VERSION="${TAG#v}"`,
      `ZIP="build/release-assets/Pisaka-${VERSION}.zip"`; refuse with `exit 1`
      if that file is absent (it is the exact artefact just uploaded, so its
      absence means the step is hashing something other than what shipped);
      `SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"`.
- [x] Key material: `KEY="${RUNNER_TEMP}/homebrew-tap-deploy-key"`,
      `trap 'rm -f "$KEY"' EXIT`, written with `(umask 077; printf '%s\n' … >
      "$KEY")`; a `$RUNNER_TEMP/known_hosts` carrying GitHub's published
      `ssh-ed25519` host key; `GIT_SSH_COMMAND` with `-i "$KEY"`,
      `IdentitiesOnly=yes`, `StrictHostKeyChecking=yes` and
      `UserKnownHostsFile` pointing at that file.
- [x] Clone `git@github.com:HawkeyePierce89/homebrew-apps.git` `--depth 1
      --branch master` into a `$RUNNER_TEMP` directory.
- [x] Shape check before editing, each branch reaching `exit 1` with a message
      that names the cask path and says the recovery is a manual two-line bump:
      the count of lines matching `^  version "[^"]*"$` must be exactly 1, and
      likewise for `^  sha256 "[^"]*"$`. Missing *and* duplicated both fail.
- [x] Rewrite both lines with one `sed -E` into a temp file followed by `mv`
      (not `sed -i`, whose BSD/GNU spelling differs), then verify with
      `grep -qxF` for the exact new `  version "…"` and `  sha256 "…"` lines —
      each failure `exit 1`.
- [x] Commit and push: git identity set locally in the clone, `git add` the
      cask, the no-change branch echoing that the cask already pins this
      version and hash and exiting 0, otherwise one commit (`pisaka <version>`)
      and `git push origin master`.
- [x] Append `Bump the Homebrew cask` to the `sequence` in
      `testTheReleaseIsAssembledInTheOnlyOrderThatShipsAWorkingApp`, so the
      "after publish/promote" ordering is asserted by index in the test that
      already owns ordering; extend that test's doc comment with what an
      inversion would ship (a cask pointing at a release still discardable).
- [x] Add `testTheCaskBumpIsSurgicalAndSelfChecking()`: over
      `stepScript(named: caskBumpStepName)` — the `env:` mapping for the
      secret; `VERSION="${TAG#v}"` derived from `GITHUB_REF_NAME` rather than
      restated; `shasum -a 256` run against the literal
      `build/release-assets/Pisaka-${VERSION}.zip`; the tap slug, `master` and
      the cask path each named; `assertGuardExits` on the missing-zip guard,
      both shape-count guards and both post-edit verification guards; a
      `git … push` present *after* the verification guards by index.
- [x] Add `testTheTapCloneVerifiesTheHostItPushesTo()`: `IdentitiesOnly=yes`
      and `StrictHostKeyChecking=yes` present in the step, and
      `StrictHostKeyChecking=no` / `accept-new` absent from the whole active
      workflow text.
- [x] run `swift test` — must pass before Task 3.

### Task 3: The deploy key never outlives the run

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`

- [x] Rename the final step to `Remove the run's keys and keychain` and update
      its comment to say three private keys are now removed by literal path
      (the `.p12`, the notary `.p8` and the tap deploy key), each also removed
      by the step that wrote it, none of which survives a cancellation.
- [x] Add `"${RUNNER_TEMP}/homebrew-tap-deploy-key"` to that step's `rm -f`
      line, keeping the `|| STATUS=1` accumulator intact.
- [x] Update `keychainCleanupStepName` to the new name and add the tap key path
      to the key loop in `testTheSigningKeychainIsRemovedOnEveryPath` (three
      paths), extending its doc comment accordingly.
- [x] Add `testTheTapDeployKeyIsWrittenNarrowlyAndTrapped()`: the bump step
      writes the key inside a `(umask 077; …)` subshell, under `${RUNNER_TEMP}`,
      carries `trap` … `rm -f` on `EXIT`, and the raw secret is never echoed
      (no `echo "$HOMEBREW_TAP_DEPLOY_KEY"` / `cat "$KEY"`).
- [x] run `swift test` — must pass before Task 4.

### Task 4: Documentation

**Files:**
- Modify: `docs/RELEASING.md`
- Modify: `CLAUDE.md`

- [x] New section "One-time setup: the Homebrew tap deploy key" with the exact
      commands: `ssh-keygen -t ed25519 -f ~/.ssh/pisaka-homebrew-tap -N "" -C
      "pisaka release workflow"`; register `~/.ssh/pisaka-homebrew-tap.pub` at
      github.com/HawkeyePierce89/homebrew-apps → Settings → Deploy keys → Add
      deploy key, **Allow write access checked**; register the private half
      (`pbcopy < ~/.ssh/pisaka-homebrew-tap`, whole file including the BEGIN/END
      lines and trailing newline) at github.com/HawkeyePierce89/pisaka →
      Settings → Secrets and variables → Actions as `HOMEBREW_TAP_DEPLOY_KEY`;
      then delete the local copies. State that, unlike the EdDSA key, losing
      this pair strands nothing — rotation is delete the deploy key, generate a
      new pair, repeat — and that the key's write access is scoped to the tap
      repository alone.
- [x] Add the secret to the existing table (or a sibling table) so the document
      reads seven secrets, and update every "five"/"six" count in the prose.
- [x] Add the bump step to the step-by-step list: what it does in order, that
      it is fatal like every other step, and that the host key is pinned (with
      what to do if GitHub rotates it).
- [x] Document the failure semantics explicitly: a failed bump leaves a red run
      with the release **already published**; recovery is the manual two-line
      bump — `shasum -a 256 Pisaka-<version>.zip` on the downloaded asset, edit
      `version` and `sha256` in `Casks/pisaka.rb`, commit, push — and existing
      installs are unaffected either way (Sparkle updates them; the cask
      declares `auto_updates true`).
- [x] Update the cleanup-step bullet for the new name and the third key.
- [x] Extend the `ReleaseWorkflowTests` inventory paragraph with what the new
      assertions pin.
- [x] Add a "Manual verification owed" entry: the step cannot be exercised
      without a real tag, so its first live run is the next release — what to
      check afterwards (the tap has one new commit, `brew update && brew info
      --cask pisaka` shows the new version, a fresh `brew install --cask
      pisaka` lands it).
- [x] `CLAUDE.md`: change "the six repository secrets it reads (the Sparkle
      EdDSA key plus five Apple-account ones)" to seven, naming the tap deploy
      key as the seventh, and mention the cask bump in the same sentence that
      describes what `release.yml` publishes. No new per-file essay — the index
      rule stands.
- [x] run `swift test` (the suite reads `docs/RELEASING.md` too) — must pass.

### Task 5: Verify acceptance criteria

- [x] run `swift test` — fully green, including the extended
      `ReleaseWorkflowTests`.
- [x] `git diff --stat` shows exactly `.github/workflows/release.yml`,
      `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`, `docs/RELEASING.md`
      and `CLAUDE.md` — `project.yml` untouched.
- [x] `grep` the diff for secret material: only the secret **name** may appear;
      no key bytes, no fingerprints beyond the pinned GitHub host key.
- [x] Read the new step top to bottom and confirm the five phases (version,
      hash, clone, edit+verify, push) are each visible and each fatal.

## Post-Completion (manual, owner)

- Generate the deploy key pair and register both halves per the new
  `docs/RELEASING.md` section (the tests are static and assume nothing about
  the secret existing).
- The first live exercise is the next `v*` tag; verify the tap commit and a
  fresh `brew install --cask pisaka` afterwards, then tick the "owed" entry.
