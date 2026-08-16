# R-3: re-sign Sparkle's nested helpers so notarization passes

## Overview

The `v1.0` tag (run 31936509608) was rejected by the notary service with status
`Invalid`. The log named four binaries, all nested inside the embedded
`Sparkle.framework` — `Versions/B/Autoupdate`, `Versions/B/Updater.app`,
`XPCServices/Downloader.xpc` and `XPCServices/Installer.xpc` — each with the
same two findings: not signed with a valid Developer ID certificate, and no
secure timestamp. Xcode's archive re-signs the framework *bundle* with the run's
identity (R-2's verification proved that, and it was true), but it does not
recurse into the framework's own nested helper bundles, which ship with
Sparkle's upstream ad-hoc signatures.

This change inserts an explicit, inside-out re-sign pass between the archive and
the verification, and deepens the verification so that the four facts it already
reads back are read back off **every nested Mach-O** in the app — so this class
of failure is refused locally, twenty minutes before the notary, rather than by
Apple.

Ground truth confirmed against the pinned artefact
(`Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework`, 2.9.5) and a local
Release build:

- The shipped app contains exactly six Mach-Os: `Contents/MacOS/Pisaka`,
  `…/Sparkle.framework/Versions/B/Sparkle`, `…/Versions/B/Autoupdate`,
  `…/Versions/B/Updater.app/Contents/MacOS/Updater`,
  `…/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader`,
  `…/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer`.
- Upstream signs all of them ad-hoc (`flags=0x10002(adhoc,runtime)`,
  `TeamIdentifier=not set`, no `Timestamp=`) — exactly the two findings the
  notary reported.
- `codesign --display` on a nested bundle's *executable* reports that bundle's
  signature (identifier, authority, flags, timestamp), so enumerating Mach-O
  files covers the nested bundles without a second bundle-walk.
- Entitlements as shipped: `Downloader.xpc`, `Installer.xpc` and `Updater.app`
  carry an empty dict; `Autoupdate` carries `com.apple.application-identifier`.

Sparkle's own distribution documentation (sparkle-project.org, sandboxing/code
signing page) gives the exact commands and order, and they are what this change
follows rather than folklore:

```
codesign -f -s "$IDENTITY" -o runtime Sparkle.framework/Versions/B/XPCServices/Installer.xpc
codesign -f -s "$IDENTITY" -o runtime --preserve-metadata=entitlements Sparkle.framework/Versions/B/XPCServices/Downloader.xpc # 2.6+
codesign -f -s "$IDENTITY" -o runtime Sparkle.framework/Versions/B/Autoupdate
codesign -f -s "$IDENTITY" -o runtime Sparkle.framework/Versions/B/Updater.app
codesign -f -s "$IDENTITY" -o runtime Sparkle.framework
```

`--timestamp` is added on top of each (a notarization requirement Sparkle's
snippet leaves to the Xcode build setting that is not in play here), and the app
bundle is re-signed last, because modifying nested code invalidates every
signature above it. Sparkle asks to preserve entitlements on `Downloader.xpc`
only; `Autoupdate`'s `com.apple.application-identifier` is therefore dropped
deliberately — following upstream, and because carrying an App-Store-shaped
identifier for a foreign team into a Developer ID signature is itself a
notarization finding.

## Context

- Files involved:
  - Modify: `.github/workflows/release.yml` — the new re-sign step, the deepened
    "Verify the archived app" step.
  - Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift` — new pins; the
    two-bundle count assertion and the step-ordering sequence updated.
  - Modify: `docs/RELEASING.md` — the re-sign pass and why, the v1.0 incident,
    the process lesson, the "Manual verification owed" status, the
    `ReleaseWorkflowTests` coverage paragraph.
  - Modify: `docs/architecture/core-services.md` — one note where Sparkle's
    `binaryTarget` layout is already discussed.
  - Modify: `CLAUDE.md` — the `ReleaseWorkflowTests` coverage description.
- Related patterns: `ReleaseWorkflowTests`' established style — assertions over
  comment-stripped text (`activeText()`/`activeLines()`), scoped to one step
  (`stepScript(named:)`), refusals asserted *by mechanism* (`assertGuardExits`
  requires the guarded branch to reach `exit 1` at depth 0), pinned constants
  for step names so a rename fails loudly.
- Dependencies: none new. No Swift source under `Sources/` changes; `PisakaCore`
  is untouched.

## Development Approach

- **Testing approach**: Regular (workflow change first, then its static pins in
  the same task). The pins *are* the tests here — `swift test` is the only
  executable check that can see this workflow, since it runs on a `v*` tag and
  nowhere else.
- Complete each task fully before moving to the next.
- Every substring assertion must run over comment-stripped, step-scoped text.
  The workflow documents itself by quoting its own commands, so a raw `contains`
  would stay green after the command it names is deleted.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: The inside-out re-sign pass

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`

Insert a new step, `Re-sign Sparkle's nested helpers`, immediately after the
archive step and before `Verify the archived app`. It re-signs — in this order,
one `codesign` invocation per line, no loop over a glob and emphatically no
`--deep` — the two XPC services, `Autoupdate`, `Updater.app`, then
`Sparkle.framework`, then `Pisaka.app`. Every invocation passes `--force`, the
same `Developer ID Application` identity the archive selects, `--options runtime`
and `--timestamp`; the `Downloader.xpc` line additionally passes
`--preserve-metadata=entitlements` per Sparkle's documentation for 2.6+.

Each of the four helper paths is `test -e`-guarded before it is signed, with an
`::error::` naming the path and saying that the pinned Sparkle version's
internal layout changed and this list plus the verification's required set must
be re-derived from the new framework. That guard, not the notary, is what must
notice a layout change.

The step's comment block carries the reasoning the repository expects: why Xcode
does not do this (it re-signs the framework bundle, not the bundles nested
inside it), why the order is inside-out (modifying nested code invalidates every
seal above it), why the list is explicit rather than `--deep` (Apple documents
`--deep` as unsuited to distribution signing; an enumerable list is what the
verification and the static pins can hold to account), where the flags come from
(Sparkle's own distribution documentation for the pinned 2.9.5, quoted), and the
one forward hazard: the app is re-signed with no `--entitlements`, which is
correct only while the release ships no entitlements file — adding one means
passing it here too, or the re-sign silently strips it.

- [x] add the `Re-sign Sparkle's nested helpers` step between the archive and the verification, with the six explicit `codesign` invocations, the four existence guards, and the comment block above
- [x] add a `reSignStepName` constant and a constant holding the four helper paths as they appear under the framework (`Versions/B/XPCServices/Downloader.xpc`, `Versions/B/XPCServices/Installer.xpc`, `Versions/B/Autoupdate`, `Versions/B/Updater.app`), shared with Task 2's assertions
- [x] new test: the step signs each of the four helper paths, and every signing invocation in it carries `--force`, the Developer ID identity, `--options runtime` and `--timestamp`
- [x] new test: the `Downloader.xpc` invocation carries `--preserve-metadata=entitlements`
- [x] new test: order within the step — every helper invocation precedes the framework's, which precedes the app's (compare indices in the step script, not mere presence)
- [x] new test: no signing invocation anywhere in the workflow uses `--deep` (a line containing both `codesign` and `--sign`/`-s` must not contain `--deep`; the legitimate `codesign --verify --deep --strict` calls must stay green)
- [x] new test: each of the four existence guards refuses via `assertGuardExits`, so a Sparkle layout change stops the run rather than shipping an unsigned helper
- [x] extend `testTheReleaseIsAssembledInTheOnlyOrderThatShipsAWorkingApp`'s sequence to `archive → re-sign → verify → notarize → staple → stage → appcast → publish`, and extend its doc comment with what each new inversion ships (re-signing after the verification verifies signatures that are about to be replaced; re-signing after the notary submission invalidates the ticket)
- [x] run `swift test` — must pass before Task 2

### Task 2: Verification recurses to every nested Mach-O

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`

Extend `Verify the archived app` so `verify_developer_id_signature` — unchanged,
still four facts, still one `grep` per fact, still printing the dump before
judging it — runs over every Mach-O inside the app, discovered by enumeration
rather than listed. `find "$APP" -type f` filtered by `file -b … | grep -q Mach-O`
is the enumeration (`-type f` skips the framework's symlinks, so each binary is
checked exactly once); the loop labels each target by its path relative to the
app so a refusal names which binary failed.

Two refusals guard the enumeration itself, both in the existing style — evidence
printed, actionable `::error::`, `exit 1`:

- an empty enumeration is a refusal, not a pass. A `find`/`file` combination
  that silently stops matching would otherwise turn the whole recursion into a
  no-op while every assertion in the suite stays green.
- the four helper Mach-Os the notary rejected must be *among* what was
  enumerated, checked by exact path. This is the floor under the enumeration and
  the counterpart to Task 1's explicit list: if Sparkle's layout moves, the
  re-sign list is stale and this refuses before the submission.

The existing explicit app and framework bundle checks stay — they read the
bundle-level signature (resource seal included) rather than the Mach-O's, which
the enumeration does not replace. So the step ends up with three
`verify_developer_id_signature` call sites: the app, the framework, and the loop.

- [x] add the Mach-O enumeration, the per-binary verification loop with relative-path labels, the empty-enumeration refusal and the required-four-paths refusal
- [x] extend the step's comment block: what the recursion covers that `--deep --strict` does not (validity is not identity — the ad-hoc upstream signatures passed `--deep --strict` in the v1.0 run and were rejected by the notary), and why the bundle-level checks remain
- [x] update `testTheArchivedAppAndItsFrameworkAreCheckedForTheDeveloperIDSignature`: three call sites, each pinned individually (the app, `Sparkle.framework`, the enumeration loop's variable), with its doc comment updated to say why the count grew — the assertion is deliberately updated, not deleted
- [x] new test: the step enumerates Mach-Os (a `find` over `$APP` whose results are filtered on `Mach-O`) and feeds them to `verify_developer_id_signature`, so deleting the recursion fails the suite
- [x] new test: the empty-enumeration refusal and the four required helper paths refusal both exist and both `exit 1` (`assertGuardExits`), with the required paths matched against the constant shared with Task 1
- [x] new test: `codesign --verify --deep --strict` is still present (it answers a question the four facts do not)
- [x] run `swift test` — must pass before Task 3

### Task 3: Documentation

**Files:**
- Modify: `docs/RELEASING.md`
- Modify: `docs/architecture/core-services.md`
- Modify: `CLAUDE.md`

`docs/RELEASING.md` — in the workflow walkthrough, a new bullet between the
archive and the verification describing the re-sign pass: what it signs, in what
order, with which flags, where those flags come from (Sparkle's own distribution
documentation for 2.9.5, cited), why `--deep` is refused, and the entitlements
hazard. The verification bullet grows the recursion and the two new refusals.

Record the incident plainly where the reader meets the re-sign pass: `v1.0`
(run 31936509608) came back `Invalid`; the log named the four nested helpers with
"not signed with a valid Developer ID certificate" and "does not include a
secure timestamp"; nothing was published, which is how the R-2 design intended a
rejection to land. Recovery is unchanged and must not be restated differently:
delete the tag, re-push it, and the run archives a fresh `github.run_number`.

Add the process lesson where the document already discusses what local checks
can and cannot see: a dependency that ships nested executable helpers makes the
dependency's own distribution documentation part of de-risking, and any local
signature check must recurse to every Mach-O — a bundle-level check on the app
and the framework was true and still missed four binaries.

Update "Manual verification owed": the first-tag item now records that a tag push
happened and what it proved (preflight, keychain, archive and submission all ran;
the rejection surfaced with its log; nothing was published) while leaving the
successful notarized tag and the real-download double-click still owed — that is
this feature's acceptance criterion and no local check subsumes it. Update the
`ReleaseWorkflowTests` coverage paragraph with the new pins.

`docs/architecture/core-services.md` — a short note where Sparkle's
`binaryTarget` layout is already discussed: the framework ships four nested
helper bundles carrying upstream ad-hoc signatures, Xcode's archive does not
re-sign them, and the release workflow's explicit re-sign pass is what does.

`CLAUDE.md` — extend the `ReleaseWorkflowTests` inventory sentence with the
re-sign pass (explicit list, inside-out order, no `--deep`) and the
verification's Mach-O recursion, keeping the file's length discipline: index and
invariants only, no per-file essay.

- [x] `docs/RELEASING.md`: the re-sign bullet, the deepened verification bullet, the v1.0 incident, the process lesson, the "Manual verification owed" status update, the coverage paragraph
- [x] confirm the new text does not contradict the documented delete-tag/re-push recovery or the `github.run_number` caveat
- [x] `docs/architecture/core-services.md`: the nested-helpers note
- [x] `CLAUDE.md`: the `ReleaseWorkflowTests` description
- [x] run `swift test` — the document-scanning suites (the Gatekeeper-workaround absence check among them) must stay green

### Task 4: Verify acceptance criteria

- [ ] `swift test` green, and report the `ReleaseWorkflowTests` count so the growth is visible
- [ ] `xcodegen generate`, then `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build` — green and signing-free (nothing in this change touches `project.yml`)
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` — green
- [ ] re-read the final `release.yml` end to end and confirm the shape: archive → re-sign (helpers → framework → app) → verify (recursing, four facts each) → notarize → staple → stage → appcast → publish, with the re-sign list explicit and `--deep` absent from every signing invocation
- [ ] `git status` clean apart from the five intended files

## Post-Completion (manual, not automatable)

- Re-push the tag (delete `v1.0`, push it again) and confirm the notary returns
  `Accepted`. This is the only proof that the re-sign pass fixes the rejection;
  no runner-free check can stand in for it. Should it fail again, the log names
  the binary and the recursion added here should have named it first.
- The real-download double-click pass and the install-N/publish-N+1 update pass
  remain owed, unchanged, as `docs/RELEASING.md` records them.
