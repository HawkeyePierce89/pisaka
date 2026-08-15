# R-2: Developer ID signing + notarization for the released macOS app

## Overview

The tag-triggered release workflow stops ad-hoc signing. It imports a Developer
ID Application certificate into a temporary, per-run keychain, archives with the
hardened runtime and `DEVELOPMENT_TEAM=XJT3LK36GS`, notarizes the archived app
with `notarytool`, staples the ticket, and only then produces the shipped zip,
the appcast and the release. Sparkle's EdDSA chain, the draft-then-promote
publication and the asset-set check are untouched. The Gatekeeper-workaround
documentation is deleted everywhere it exists and replaced by the
signing/notarization path in `docs/RELEASING.md`. `ReleaseWorkflowTests` grows
with the workflow in its established style.

This is a workflow + docs + tests change. No Swift source and no `project.yml`
change.

## Context

- Files involved:
  - Modify: `.github/workflows/release.yml` — preflight, new
    keychain/notarize/staple/cleanup steps, archive signing settings, release
    notes.
  - Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift` — new and updated
    static pins.
  - Modify: `docs/RELEASING.md` — the whole signing story, secret inventory,
    renewal, manual pass; the Gatekeeper section goes away.
  - Modify: `README.md` — "Installing a released build", the Known-Limitations
    line, the CI paragraph's "one secret" claim.
  - Modify: `docs/FEATURES.md` — the Known-limitations updater bullet.
  - Unchanged on purpose: `project.yml` (see the decision below),
    `Resources/Info.plist`, all of `Sources/`.
- Related patterns: `ReleaseWorkflowTests`' comment-stripped, step-scoped
  assertions and `assertGuardExits(_:in:step:because:)` (refusals asserted by
  mechanism — the branch must `exit 1`); `stepScript(named:in:because:)` for
  step scoping; `activeYAMLLines` from
  `Tests/PisakaCoreTests/Support/YAMLLineMatching.swift`.
- Dependencies: five repository secrets already created by hand —
  `DEVELOPER_ID_CERT_P12`, `DEVELOPER_ID_CERT_PASSWORD`,
  `APP_STORE_CONNECT_API_KEY_P8`, `APP_STORE_CONNECT_KEY_ID`,
  `APP_STORE_CONNECT_ISSUER_ID`. Team `XJT3LK36GS`. R-1 (`release.yml`) is
  merged on `master`.

## Decisions taken by this plan (rationale belongs in the code comments and `docs/RELEASING.md`)

1. **`DEVELOPMENT_TEAM` stays on the command line, `project.yml` is not
   touched.** The archive already overrides every signing setting for that one
   invocation (`CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES
   CODE_SIGN_STYLE=Manual`), so the committed `CODE_SIGNING_ALLOWED: NO` keeps a
   fresh clone + `xcodegen generate` + build signing-free with no prompt and no
   certificate. This *corrects* the claim in `docs/RELEASING.md` that the base
   setting "has to move to the debug config or be dropped" once a team exists —
   it does not, and the correction is written down rather than silently applied.
   A new test pins that `project.yml` still carries `CODE_SIGNING_ALLOWED: NO`
   and still names no team or identity.
2. **No entitlements file.** The hardened runtime permits `fork`/`exec` of child
   processes by default and library validation is per-process, so `git`, the PTY
   shell and the downloaded Node runtime need nothing declared. An entitlement is
   added only when a concrete failure demands it, and the downloaded-server case
   is exactly the manual check `docs/RELEASING.md` already owes for "a notarized
   build specifically".
3. **The app keeps being taken straight out of the archive** — no
   `-exportArchive`, no export-options plist. The archive already carries the
   shipping Developer ID signature and the hardened runtime; an export would
   introduce a second signing configuration to keep in step with the first. The
   existing comment that says "there is none" (no team) is rewritten to state
   this as the choice it now is.
4. **`--timestamp` is passed explicitly** (`OTHER_CODE_SIGN_FLAGS=--timestamp`).
   A secure timestamp is a notarization requirement; relying on an Xcode default
   for it would make a rejection surface only at the notary service, 20 minutes
   in.
5. **`spctl --assess` runs in the workflow**, after stapling, as a hard gate. It
   is the definitive proof of this ticket's goal and it is cheap; the manual pass
   then covers what a runner structurally cannot — a real double-click of a real
   download.

## Development Approach

- **Testing approach**: Regular (workflow/docs first, then the static pins in the
  same task). `ReleaseWorkflowTests` is the only executable check that exists for
  this change — the workflow itself has no runner, no network and no secret in
  `swift test`, exactly as its own doc comment says.
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: `swift test` must pass before starting the next task.**
- Every new workflow invariant that matters gets a static pin, asserted against
  comment-stripped text and scoped to the step that runs it — a workflow-wide
  `contains` stays green when the command it names moves or dies.

## Implementation Steps

### Task 1: The temporary keychain and the five preflight refusals

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`

The preflight must refuse a release that cannot be signed or notarized *before*
the archive, in the same actionable style as its existing four refusals: one `-z`
guard per secret, each with an `::error::` message naming what to do and pointing
at `docs/RELEASING.md`, each branch reaching `exit 1`. The secrets reach the step
through `env:` and are never echoed.

A new step, sitting with the other cheap refusals and before the archive, creates
the run's keychain and imports the certificate: a unique password generated in
the step (not a secret, never printed), a keychain under `$RUNNER_TEMP`,
`set-keychain-settings` with no auto-lock timeout surprise, `unlock-keychain`,
`security import` of the base64-decoded `.p12` with `-T /usr/bin/codesign`,
`set-key-partition-list` so `codesign` can use the key non-interactively, and the
temp keychain prepended to the *user* search list without dropping what was
already there. The decoded `.p12` is removed in the same step. The login keychain
is never named, never modified.

That step also carries the last cheap refusal: `security find-identity -v -p
codesigning` must show a **Developer ID Application** identity for team
`XJT3LK36GS`, or the run stops. A certificate of the wrong type (an Apple
Development cert, an expired one) would otherwise archive happily and be rejected
by the notary service twenty minutes later.

A final step with `if: always()` deletes the keychain and restores the search
list, so no path — success, failure, or cancellation — leaves the certificate on
the runner.

- [ ] add the five `-z` secret refusals to the `Preflight` step, each with an
      actionable message, a `docs/RELEASING.md` pointer and `exit 1`
- [ ] add the certificate-import step: per-run password, `$RUNNER_TEMP` keychain,
      import, partition list, search list, decoded `.p12` removed,
      identity-and-team refusal
- [ ] add the `if: always()` keychain-cleanup step as the job's last step
- [ ] tests: extend `testPreflightRefusesEveryUnshippableRelease` with the five
      new guards (by mechanism); add a test that the keychain is created under
      `$RUNNER_TEMP`, that the login keychain is never named, that the identity
      guard exits 1, that the import step runs before the archive, and that a
      step carrying `if: always()` deletes the keychain
- [ ] run `swift test` — must pass before Task 2

### Task 2: Developer ID + hardened runtime in the archive, and verifying it

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`

The archive step loses `CODE_SIGN_IDENTITY=-` and gains
`CODE_SIGN_IDENTITY="Developer ID Application"`, `DEVELOPMENT_TEAM=XJT3LK36GS`,
`ENABLE_HARDENED_RUNTIME=YES` and `OTHER_CODE_SIGN_FLAGS=--timestamp`. It is
renamed to match what it now does; the "DEVELOPER ID / NOTARIZATION SEAM" comment
is replaced by prose explaining why every signing setting is still
command-line-only and why no entitlements file exists.

"Verify the archived app" keeps everything it does today and additionally proves
the signature is what notarization requires, rather than assuming it: the app's
authority is a Developer ID Application certificate, its team identifier is
`XJT3LK36GS`, and its flags carry `runtime`. The same three are checked on the
embedded `Sparkle.framework` — that is the "Xcode re-signs the framework with the
same identity" claim, verified. `codesign --verify --deep --strict` continues to
cover nested code validity, and the notary service remains the authority for
every nested executable, which the comment says plainly instead of pretending the
local checks are exhaustive.

- [ ] rewrite the archive step's signing settings and its comment; rename the
      step
- [ ] extend `Verify the archived app` with the authority / team-identifier /
      `runtime`-flag checks on the app and on `Sparkle.framework`, each refusing
      with an actionable message
- [ ] tests: update the `archiveStepName` constant; add a test scoped to the
      archive step asserting the identity, the team, `ENABLE_HARDENED_RUNTIME=YES`
      and `--timestamp`, and asserting `CODE_SIGN_IDENTITY=-` appears nowhere
      active (the deliberate update of the old ad-hoc pin, not its deletion); add
      a test that the archived app and the embedded framework are checked for the
      Developer ID authority, the team and the hardened-runtime flag; add the
      `project.yml`-stays-signing-free test from Decision 1
- [ ] run `swift test` — must pass before Task 3

### Task 3: Notarize, staple, and prove the result

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`

Two new steps sit between the verification and the staging of the shipped zip.
The first zips the app into a scratch directory with the same symlink-preserving
`ditto`, writes the API key to a `.p8` under `$RUNNER_TEMP` removed by a `trap` on
exit, and submits with `xcrun notarytool submit --wait --timeout` and the
key/key-id/issuer trio, JSON output. The submission's status is read explicitly
and anything other than `Accepted` fetches `xcrun notarytool log` for the
submission id, prints it and `exit 1` — the exit code alone is not trusted to
distinguish a rejected build from an accepted one, and a rejection with no log is
a rejection nobody can act on.

The second staples the ticket to the **.app**, validates it with `stapler
validate`, re-runs `codesign --verify --deep --strict` (stapling must not disturb
the signature) and then asserts the whole point of this ticket with `spctl
--assess --type execute --verbose=4`.

The zip that is submitted and the zip that ships are different artifacts: the
existing "Stage the update archive" step is unchanged and now necessarily runs
*after* the staple, so the shipped zip contains the stapled bundle. Everything
downstream — `generate_appcast`, the draft, the asset-set check, the promotion —
is untouched.

- [ ] add the notarize step: scratch zip, `.p8` written and `trap`-removed,
      `notarytool submit --wait`, explicit status check, log fetch, `exit 1` on
      anything but `Accepted`
- [ ] add the staple step: `stapler staple` the `.app`, `stapler validate`,
      re-verify the signature, `spctl --assess`
- [ ] tests: a notarization test asserting the submit invocation carries `--wait`
      and the API-key trio, that the non-`Accepted` branch exits 1 and that the
      step fetches the notarization log; a stapling test asserting `stapler
      staple` and `stapler validate`; an ordering test pinning archive < notarize
      < staple < the shipped zip < `generate_appcast` < `gh release create`; a
      test that the `.p8` is removed by the step that writes it
- [ ] confirm the R-1 publication tests
      (`testTheReleaseIsPublishedOnlyOnceBothAssetsAreOnIt`, the appcast-signature
      guard and its position) still pass unchanged
- [ ] run `swift test` — must pass before Task 4

### Task 4: Delete the Gatekeeper story, document the new one

**Files:**
- Modify: `.github/workflows/release.yml` (the release-notes text)
- Modify: `README.md`
- Modify: `docs/FEATURES.md`
- Modify: `docs/RELEASING.md`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`

The release notes become a plain statement of what the release is (version, build
number, a notarized macOS app) with no workaround in them. `README.md`'s
"Installing a released build" becomes download, unzip, run; its Known-Limitations
line about ad-hoc signing goes; its CI paragraph stops claiming the release
workflow uses one secret. `docs/FEATURES.md`'s updater bullet loses the
Gatekeeper sentence.

`docs/RELEASING.md` is where the real work is. The "Gatekeeper on the first
install (accepted)" section is deleted entirely — R-1 wrote it to be deleted
here. In its place the automated-release description gains the signing and
notarization path end to end: the five secrets and how each was produced, so they
can be rotated; the temporary-keychain mechanics and why the login keychain is
never touched; the notarization submit/staple/verify flow and what a
non-`Accepted` status means; certificate **expiry and renewal** — a Developer ID
Application certificate is valid for years but not forever, and what breaks when
it lapses is *new releases*, not installed copies (already-notarized,
already-stapled builds keep launching, and Sparkle's EdDSA chain is independent
of Apple signing) — plus what to do: issue a new certificate, re-export the
`.p12`, replace the two certificate secrets, no code change. Decision 1's
correction of the `CODE_SIGNING_ALLOWED` note is written here. The "Not here yet"
entries for `DEVELOPMENT_TEAM` and for notarization/stapling move to done,
keeping the Mac-App-Store exclusion (sandbox + guideline 2.5.2) and the App Store
Connect records where they are. The `nm` required-reason audit note and the LGPL
section are not touched.

The manual verification section keeps R-1's items — reworded where they assumed
ad-hoc signing — and gains this ticket's: the first notarized tag assessed by
`spctl` and run by double-click from a clean download with no prompt; the
downloaded Node language server launching under the hardened runtime; a Sparkle
update from a previous release installing normally.

- [ ] rewrite the workflow's release-notes text with no workaround in it
- [ ] rewrite `README.md`'s install section and fix its two other stale claims;
      fix the `docs/FEATURES.md` bullet
- [ ] rewrite `docs/RELEASING.md`: delete the Gatekeeper section, document
      secrets/keychain/notarization/renewal, move the two "Not here yet" items to
      done, update the manual-verification list
- [ ] tests: assert the literal workaround strings (`xattr -dr
      com.apple.quarantine`, `Open Anyway`) appear in none of `release.yml`,
      `README.md`, `docs/FEATURES.md` and `docs/RELEASING.md` — the acceptance
      criterion, pinned so a revert cannot quietly restore instructions the app no
      longer needs
- [ ] run `swift test` — must pass before Task 5

### Task 5: Verify acceptance criteria

- [ ] `swift test` — the full suite green, including every updated and new
      `ReleaseWorkflowTests` assertion
- [ ] `xcodegen generate` then build both destinations (`platform=macOS` and
      `generic/platform=iOS`) and confirm they succeed with no certificate and no
      signing prompt — the committed configuration is unchanged, and this is the
      check that proves it
- [ ] re-read the final `release.yml` against the acceptance criteria: preflight
      refuses each missing secret before archiving, the archive is Developer ID
      signed with the hardened runtime, notarize and staple sit between signing
      and the shipped zip, the keychain is cleaned up on every path, and R-1's
      publication invariants are intact

### Task 6: Update documentation

- [ ] confirm `CLAUDE.md`'s `ReleaseWorkflowTests` description still matches what
      the suite now asserts, and extend the sentence listing its coverage with the
      signing/notarization pins
- [ ] confirm no other document still describes released builds as ad-hoc signed

## Post-Completion (manual, recorded in `docs/RELEASING.md` — not automated)

- The first notarized tag: `spctl --assess` accepts the shipped app, and a clean
  download from the release page runs on a double-click with no prompt.
- The downloaded Node language server still launches under the hardened runtime
  (the check R-1's docs already flag for a notarized build specifically).
- A Sparkle update from a previously published release installs normally.
