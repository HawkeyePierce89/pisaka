# Releasing Pisaka

Everything here is repository-side plus the six repository secrets the release
workflow reads — the Sparkle EdDSA signing key and five Apple-account ones. The
App Store Connect *app record* and store metadata are still absent — see
[Not here yet](#not-here-yet).

There are two paths, and they answer different questions:

- [Automated releases](#automated-releases) — pushing a `vX.Y` tag builds a
  **Developer ID signed, notarized and stapled** macOS app and publishes it as a
  GitHub Release with a signed Sparkle appcast, so a fresh download launches
  from the ordinary, confirmable "downloaded from the Internet" dialog rather
  than being refused, and installed copies can update themselves. This is the
  distribution channel. Notarization does not remove that dialog — quarantine
  still applies to a notarized app and macOS still asks once; what it removes is
  the *unconfirmable* refusal and every terminal workaround for it. The exact
  acceptance criterion is under
  [Manual verification owed for this feature](#manual-verification-owed-for-this-feature).
- The by-hand archive below, which is the **build-number mechanism** and the
  path an eventual App Store upload takes. The workflow runs the same command
  with the same rules.

## The two numbers

| Setting | Plist key | Where it lives | Who changes it |
| --- | --- | --- | --- |
| `MARKETING_VERSION` | `CFBundleShortVersionString` | `project.yml` (currently `1.0`) | committed, per release |
| `CURRENT_PROJECT_VERSION` | `CFBundleVersion` | `project.yml` (`1`) | overridden per upload, **not** committed |

### The release version

`MARKETING_VERSION` is the user-visible version — the one that appears in the
About box and in the store listing. It lives in `project.yml` under the `Pisaka`
target's `settings.base`, and changing it is an ordinary commit: bump it when
the release it names is what you intend to ship.

It is the *store* version and nothing else: `PisakaCore.version` is an unrelated
library constant and does not track it. Feature scope is a separate axis — the
first App Store release ships as `1.0` because a store listing numbered `0.1`
reads as unfinished, not because the feature set changed. `README.md`'s "Known
Limitations" section carries the headline list of what 1.0 does not do; the
complete, per-item list is in `docs/FEATURES.md`.

### The build number

App Store Connect rejects an upload whose `CFBundleVersion` it has already seen
for the same `CFBundleShortVersionString`. Every upload therefore needs a build
number no previous upload used — including re-uploads of a rejected or
mis-built archive, which is exactly when bumping a committed value is most
annoying.

So the build number is **not** bumped in the working tree. `project.yml` keeps
`CURRENT_PROJECT_VERSION: "1"` as a stable floor, and each upload passes its own
value on the `xcodebuild` command line. A build setting given as a command-line
argument overrides the project's value for that invocation only, so the archive
carries the new number and `git status` stays clean:

The archive this produces is **unsigned**, on purpose: `project.yml` carries
`CODE_SIGNING_ALLOWED: NO` in the target's `settings.base`, and names no team and
no identity, so a fresh clone plus `xcodegen generate` plus a build works for
anyone — no certificate, no keychain prompt, no "development team required".

**That base setting stays exactly where it is now that a team exists.** An
earlier version of this document said it "has to move to the debug config or be
dropped" once signing was configured. It does not, and the correction is written
down here rather than silently applied: the release workflow overrides *every*
signing setting on the `xcodebuild` command line
(`CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual`
plus the identity and team), and a command-line build setting beats the
project's value for that one invocation. So the committed configuration keeps
dev and CI builds signing-free while the release signs — no per-configuration
split to maintain, and no way for a local build to start demanding a
certificate. `ReleaseWorkflowTests` pins both halves: that `project.yml` still
carries `CODE_SIGNING_ALLOWED: NO` and still names no team or identity, and that
the archive step supplies all of them itself.

To reproduce a signed archive locally, pass the same overrides the workflow does
(you need the Developer ID Application certificate in your own keychain); the
unsigned command below is the build-number mechanism, verified end to end.

```sh
xcodegen generate
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka \
  -destination 'generic/platform=macOS' \
  -archivePath build/Pisaka-macOS.xcarchive \
  CURRENT_PROJECT_VERSION=7 \
  archive
```

Rules for the value:

- **Monotonic integer.** Use a plain, strictly increasing whole number (`1`,
  `2`, `3`, …). Never reuse one, never go backwards, and never reset it when
  `MARKETING_VERSION` moves — a single ever-increasing sequence across all
  releases is the simplest thing that satisfies both stores.
- **One per upload, not per release.** Two attempts at the same release are two
  build numbers.
- **Both destinations.** macOS and iOS archives of the same release should
  carry the same build number; pass the same `CURRENT_PROJECT_VERSION=<n>` to
  each `archive` invocation.
- **Record it.** The number that actually shipped only exists in App Store
  Connect and in the release tag's notes — the repository does not track it by
  design.

The tag-triggered workflow obeys every one of those rules without anyone typing
a number: it passes `CURRENT_PROJECT_VERSION=${{ github.run_number }}` to the
same `archive` command, which is monotonic by construction (see
[Automated releases](#automated-releases)). The by-hand command above stays the
manual path — the one to use for an App Store Connect upload, or to reproduce a
release build locally — and remains the mechanism the workflow drives.

## Automated releases

Pushing a `vX.Y` tag runs `.github/workflows/release.yml`: it re-runs the
`swift test` gate, archives a macOS app **signed with a Developer ID Application
certificate under the hardened runtime**, submits it to Apple's notary service,
staples the ticket, zips the stapled bundle, signs the zip with the project's
EdDSA key and publishes a GitHub Release carrying exactly two assets —
`Pisaka-X.Y.zip` and `appcast.xml`. The shipped app reads
`https://github.com/HawkeyePierce89/pisaka/releases/latest/download/appcast.xml`
(`SUFeedURL` in `Resources/Info.plist`) and verifies every download against
`SUPublicEDKey` in the same file, so a published release is what an installed
copy offers as an update through Sparkle's own UI.

### The two signatures a release carries

They answer different questions and neither substitutes for the other, which is
why both one-time setups below exist and why the preflight refuses their secrets
separately:

- **Apple's** — a Developer ID Application signature plus a stapled notarization
  ticket — is what lets a *downloaded* copy launch: Gatekeeper evaluates it on
  the first open of a file carrying the quarantine flag.
- **Sparkle's** — the EdDSA signature over the zip, advertised in the appcast —
  is what an *installed* copy checks before replacing itself. Sparkle does not
  consult Apple's signature for that decision.

They also fail independently, and the blast radius differs by an order of
magnitude. An expired or revoked Developer ID certificate breaks *new releases*
and nothing already installed; a lost EdDSA private key strands the entire
installed base forever. Treat them accordingly.

### One-time setup: the EdDSA key pair

**Done (2026-08-16).** The real pair exists: the public half is committed in
`Resources/Info.plist` (`SUPublicEDKey`), the private half lives in the
`SPARKLE_PRIVATE_EDDSA_KEY` repository secret and in an offline backup. The
original state — a deliberate, structurally valid placeholder
(`UExBQ0VIT0xERVItUkVQTEFDRS1XSVRILVJFQUwtS1k=`, base64 of
`PLACEHOLDER-REPLACE-WITH-REAL-KY`) — is retired, and the workflow's preflight
still refuses to release if that value ever reappears in the plist (a revert
would ship a release no installed copy trusts). The procedure is kept below for
a future re-key — with the warning that **rotation orphans every installed
copy** (they verify against the key baked into their own bundle), so it is a
last resort, not maintenance:

```sh
curl -fsSL -o Sparkle-2.9.5.tar.xz \
  https://github.com/sparkle-project/Sparkle/releases/download/2.9.5/Sparkle-2.9.5.tar.xz
echo "015336b601493e05c237964954bff6191370003d94edefe663724c88840d73cc  Sparkle-2.9.5.tar.xz" \
  | shasum -a 256 -c -
mkdir -p sparkle-tools && tar -xJf Sparkle-2.9.5.tar.xz -C sparkle-tools ./bin
./sparkle-tools/bin/generate_keys
```

1. `generate_keys` stores the **private** half in the login keychain and prints
   the **public** half. Take the private half out **outside the repository** —
   `./sparkle-tools/bin/generate_keys -x ~/pisaka-sparkle-private-key.txt` — and
   put its contents into the repository secret **`SPARKLE_PRIVATE_EDDSA_KEY`**
   (Settings → Secrets and variables → Actions). Delete the file afterwards; it
   must never be committed. The export path is outside the checkout on purpose:
   a `git add -A` in the window between writing that file and deleting it would
   otherwise commit a private key, and pushed history is not something deleting
   the file undoes. `.gitignore` carries `*private-key*.txt` as a second guard for
   anyone who exports into the tree anyway, along with `sparkle-tools/`, the
   tarball and a locally generated `appcast.xml`.
2. Replace the placeholder `SUPublicEDKey` in `Resources/Info.plist` with the
   printed public half — one line, no whitespace — and commit that.

**Losing the private key is unrecoverable for copies already installed.** They
verify updates against the public key baked into their own bundle and will
reject anything signed by a different one; the only way out is asking every user
to download a fresh build by hand. Treat the private half as backed-up state
that lives outside this repository (a password manager, an offline copy), not as
something the keychain happens to hold.

The preflight's placeholder grep stays in the workflow permanently: it is what
turns "someone reverted the key commit" into a refused release instead of a
release signed by a key no installed copy trusts.

### One-time setup: the Developer ID certificate and the notarization key

**Done (2026-08-16).** Team **`XJT3LK36GS`**. Five repository secrets carry
everything Apple's half of a release needs; none of them is derivable from the
repository, and each is refused on its own by the preflight, before the archive.
How each was produced — which is also how each is rotated:

| Secret | What it is | Where it came from |
| --- | --- | --- |
| `DEVELOPER_ID_CERT_P12` | the Developer ID Application certificate **and its private key**, base64 | Keychain Access → select the certificate *and* its key → Export as `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_CERT_PASSWORD` | the password typed at that export | chosen at export time; it exists only to protect the `.p12` |
| `APP_STORE_CONNECT_API_KEY_P8` | the notarization API key, verbatim | App Store Connect → Users and Access → Integrations → App Store Connect API → generate a key with the **Developer** role; the `AuthKey_<id>.p8` downloads **once** |
| `APP_STORE_CONNECT_KEY_ID` | the 10-character Key ID | shown beside that key, and it is the `<id>` in the `.p8` filename |
| `APP_STORE_CONNECT_ISSUER_ID` | the team's issuer UUID | shown above the key list on the same page; one per team, shared by every key |

The `.p12` must be exported *with* the private key — a certificate alone imports
fine and then signs nothing, which surfaces as the identity refusal below rather
than as anything that names the real cause. The `.p8` is downloadable exactly
once: losing it means generating a new key and replacing three secrets, which is
cheap (unlike the EdDSA key, an App Store Connect key strands nothing).

**The certificate lives in a keychain created for the run and deleted with it.**
The workflow creates `$RUNNER_TEMP/pisaka-signing.keychain-db` with a password it
generates in the step (never printed, never a secret — it guards nothing that
outlives the job), imports the decoded `.p12` with `-T /usr/bin/codesign`, sets a
key partition list so the first signature does not raise the "wants to sign using
key in your keychain" dialog — on a headless runner that is not a failure, it is
a hang until the job times out — and *prepends* the keychain to the user search
list, saving the previous list so the cleanup step can restore it verbatim
(`security list-keychains -s` overwrites the whole list; passing the new keychain
alone would drop everything else for the rest of the job). The keychain is
unlocked and given a lock timeout longer than the job (`security
set-keychain-settings -ut`, deliberately without `-l`, which means "lock when the
system sleeps" and not "lock timeout") — a keychain that re-locks mid-archive
fails `codesign` with "User interaction is not allowed", which reads like a
missing identity and is not one.

The decoded `.p12` is removed in the same step, and a final `if: always()` step
deletes the keychain, restores the list, and removes **both** private keys by
path — the `.p12` and the notarization `.p8` — on every path: success, failure
or cancellation. That last one is why the cleanup repeats removals the writing
steps already do: a cancelled step is killed, so it runs neither its trailing
`rm` nor its `trap … EXIT`, and the cleanup step is the only thing left. It runs
every one of those commands whatever the others do, and still fails the job if
any of them failed — a green run has to mean the runner was scrubbed, not that
nothing said otherwise.

**The login keychain is never named and never modified.** A GitHub macOS runner
is ephemeral, but that is a property of the fleet rather than a guarantee this
workflow may lean on; and the login keychain is unlocked, shared with every other
step and every third-party action in the job, and not ours to touch. A keychain
under `$RUNNER_TEMP` is ours and is one `security delete-keychain` from gone.

The last cheap refusal lives in that same step: `security find-identity -v -p
codesigning` must list a **Developer ID Application** identity for team
`XJT3LK36GS`. `-v -p codesigning` lists only identities usable for signing, so
one check covers an expired certificate, a missing private key and the wrong
certificate *type* at once. The type is the case worth spelling out: an Apple
Development certificate archives perfectly happily and is then rejected by the
notary service twenty minutes later.

### Notarization and stapling

Between verifying the archive and staging the shipped zip, the workflow:

1. **Submits.** It zips the app into a scratch directory with the same
   symlink-preserving `ditto` the shipped zip uses, writes the API key to a `.p8`
   under `$RUNNER_TEMP` removed by a `trap` on exit (every path out of the step
   must take the key with it, including the ones that never reach the end), and
   runs `xcrun notarytool submit --wait --timeout 30m` with the key/key-id/issuer
   trio and JSON output.

   **The verdict is read, not inferred from the exit code.** `notarytool` reports
   transport and authentication failures through `$?`, but the result is a field
   in the JSON, so the workflow reads `.status` explicitly. Anything other than
   `Accepted` fetches `xcrun notarytool log` for the submission id, prints it and
   exits 1 — a rejection names the offending binary and the reason (a missing
   hardened runtime, a missing secure timestamp, an unsigned nested executable),
   and a rejection with no log printed is one nobody can act on without
   re-running the whole release to see it. Nothing has been published at that
   point: fix the cause, then delete and re-push the tag.

   The one case that has *no* id to fetch a log for is the same one the guarded
   `jq` reads exist for — the `--timeout` expiring, a submission killed
   mid-write, `notarytool` emitting something that is not JSON. That branch says
   so and points at `xcrun notarytool history` instead, because
   `notarytool log ""` fails with a complaint about a malformed id that has
   nothing to do with the actual problem, and the id it would otherwise tell you
   to re-run with was never captured by anything.

2. **Staples.** `xcrun stapler staple` writes the ticket Apple issued into the
   bundle, which is what makes a downloaded copy launch on a machine that cannot
   reach Apple. `stapler validate` then re-reads it back out and checks it
   against the bundle's own code directory hash — not the same statement as
   `staple` succeeding, and what catches a ticket stapled to something other than
   what was submitted. The signature is re-verified afterwards because stapling
   modifies the bundle (it is supposed to be signature-neutral; this proves it
   for this build), and finally `spctl --assess --type execute --verbose=4` asks
   the *system policy* the actual question: would Gatekeeper let this app run.
   That last answer is read out of the assessment, not off the exit status. spctl
   exits 0 for **any** accepting rule and prints which one accepted on a
   `source=` line, so the step refuses anything but `source=Notarized Developer
   ID`. An accepted but *unstapled* Developer ID app reports `source=Developer
   ID` and exits 0, and — the case that is a property of the runner rather than
   of the build — a machine with assessments disabled accepts every path on disk
   with `source=no usable signature`. Against either, an unguarded exit-status
   check would wave the release through having asserted nothing.

The zip submitted to the notary service is **not** the zip that ships. The
shipped one is produced afterwards, from the same `.app`, by the existing "Stage
the update archive" step — the ticket has to be inside the bundle before the copy
users download is made, or every first launch would depend on Apple's service
being reachable. That ordering is pinned by `ReleaseWorkflowTests`.

### Certificate expiry and renewal

A Developer ID Application certificate is valid for five years, and Apple
Developer Program membership renews annually. Both eventually lapse, and it is
worth being precise about what that breaks:

- **New releases stop.** The preflight's identity refusal fires (`find-identity
  -v` does not list an expired certificate at all), so a tag push fails in the
  first seconds instead of producing an unsigned or unnotarizable build.
- **Installed copies keep working.** A notarized, stapled build already
  distributed keeps launching after the certificate that signed it expires —
  Gatekeeper checks that the signature was valid *when it was made*, and the
  stapled ticket is the evidence. Notarization tickets do not expire.
- **Sparkle updates keep working**, independently: its chain is the EdDSA
  signature over the zip, which has nothing to do with Apple's signing.

Renewing is therefore a secrets change and not a code change: issue a new
Developer ID Application certificate in the Apple Developer account, export it
*with its private key* as a `.p12`, and replace `DEVELOPER_ID_CERT_P12` and
`DEVELOPER_ID_CERT_PASSWORD` **together** (the password belongs to that export;
replacing one without the other imports nothing). The team id does not change, so
nothing in `release.yml`, `project.yml` or `Sources/` moves. If the App Store
Connect key is rotated at the same time, replace all three of its secrets
together for the same reason.

### Cutting a release

1. Bump `MARKETING_VERSION` in `project.yml` to `X.Y` and commit it. The tag and
   this value are two independent facts, and the workflow refuses the pair when
   they disagree — a release whose appcast advertises a version the bundle does
   not carry is worse than a failed run.
2. `git tag vX.Y && git push origin vX.Y`.

Runs are **serialized by a `concurrency:` group** keyed on the workflow alone —
not on `github.ref`, which would give every tag its own group and serialize
nothing, since two releases are by definition two different tags. Overlapping
runs matter here because `CFBundleVersion` is `github.run_number` while
`releases/latest` is whichever release was *published* last: interleave two and
the feed can end up advertising a build number lower than the one already
installed, which Sparkle will never offer an update over. `cancel-in-progress` is
`false` — a half-published release (zip attached, appcast not) is worse than a
queued one.

**Push release tags one at a time and wait for each run to finish.**
`cancel-in-progress: false` protects the run that is already *running*; a run
still **pending** in the group is cancelled when a newer one queues into it, the
same GitHub behaviour `ci.yml`'s concurrency comment documents (and works around
by giving every push to master a unique group). Here the shared group is worth
that cost, so the consequence is accepted rather than designed away: three `v*`
tags pushed in quick succession can leave the middle one with no release and no
failure anywhere. `on:` is tags-only, so there is no `workflow_dispatch` re-run —
recovering means deleting and re-pushing that tag. If the run got as far as
creating the release, delete that too before re-pushing: `gh release create`
refuses a tag that already has one, and a run that failed at or after the publish
step leaves the release behind as a **draft** (below), which is invisible on the
releases page's default view but still occupies the tag.

The workflow then, in order:

- **`test` job** — `swift test`, pinned identically to `ci.yml` (same SHA-pinned
  `actions/checkout` and `maxim-lobanov/setup-xcode`, Xcode `16.4`). Nothing is
  built or published unless it is green.
- **`release` job** (`needs: test`, the only job with `contents: write`;
  the workflow's top level is `contents: read`) —
  - **Preflight, before anything expensive.** Nine refusals, each with an
    actionable message: `MARKETING_VERSION` unreadable from `project.yml`; the
    tag's version (`v` stripped) ≠ `MARKETING_VERSION`; the
    `SPARKLE_PRIVATE_EDDSA_KEY` secret empty or absent; `SUPublicEDKey` still the
    placeholder; and one per signing/notarization secret — `DEVELOPER_ID_CERT_P12`,
    `DEVELOPER_ID_CERT_PASSWORD`, `APP_STORE_CONNECT_API_KEY_P8`,
    `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`. The five are
    checked separately rather than as one "signing is not configured" test
    because they come from four different one-time procedures (see above), and
    "one of them is missing" is not an actionable message for any of them. The
    version is parsed with a **quote-agnostic** `sed`, because
    `MARKETING_VERSION: 1.1` is as valid a YAML scalar as `"1.1"` and a parser
    that only understood the quoted form would read an empty string and then
    refuse every release while blaming `project.yml`; an empty read is reported
    as the parse failure it is, not as a version mismatch. The secrets reach the
    step through `env:` and are only ever tested with `-z`; nothing echoes them.
  - **The signing keychain**, beside the preflight and long before the archive:
    a keychain under `$RUNNER_TEMP`, the `.p12` imported and immediately deleted,
    a key partition list (`-s`, so it is applied to the signing key rather than
    to every key item in the keychain), the keychain prepended to the user search
    list — and cheap refusals ten through twelve, one per way the certificate
    pair can be wrong: the base64 body not decoding (`DEVELOPER_ID_CERT_P12`
    pasted raw or with characters lost), `security import` failing on it
    (`DEVELOPER_ID_CERT_PASSWORD` belonging to some other export — the pair
    rotated by halves, the case flagged above — *or* a `.p12` truncated at a
    multiple of four bytes, since `base64 --decode` rejects invalid characters
    and not a short body, so that paste decodes cleanly into a partial file and
    arrives here; the refusal names both halves rather than blaming the password
    on the strength of the decode having passed), and
    `security find-identity -v -p codesigning` showing a Developer ID
    Application identity for team `XJT3LK36GS` — whose listing is printed before
    it is judged, because that refusal covers four causes (wrong certificate
    type, wrong team, expired, exported without its private key) needing four
    different fixes, and only the listing tells them apart. The first two are
    wrapped rather than left bare not because bare would continue — `set -e`
    stops either way — but because `base64: Invalid character in input stream.`
    and `SecKeychainItemImport: MAC verification failed` name neither a secret
    nor which of the two to replace, and they are fixed by editing *different*
    ones.
    Mechanics and rationale are in
    [the one-time setup above](#one-time-setup-the-developer-id-certificate-and-the-notarization-key).
  - Sparkle 2.9.5's release tools, pinned exactly as XcodeGen is (the tarball URL
    plus `shasum -a 256 -c -` against the digest above). This is fetched **here,
    beside the preflight, rather than just before it is used** — for the reason
    the preflight exists at all: a moved asset or a changed tarball layout must
    fail in the first seconds, not after a 20-minute archive.
  - XcodeGen 2.45.4 (same URL + `shasum -a 256 -c -` as CI), the
    `SourcePackages` cache keyed on `Package.resolved`, `xcodegen generate`,
    `-resolvePackageDependencies`.
  - `archive` for `generic/platform=macOS`, **`-configuration Release`
    explicitly**, with `CURRENT_PROJECT_VERSION=${{ github.run_number }}` and the signing settings
    overridden **on the command line only** (`CODE_SIGNING_ALLOWED=YES`,
    `CODE_SIGNING_REQUIRED=YES`, `CODE_SIGN_STYLE=Manual`,
    `CODE_SIGN_IDENTITY="Developer ID Application"`,
    `DEVELOPMENT_TEAM=XJT3LK36GS`, `ENABLE_HARDENED_RUNTIME=YES`,
    `OTHER_CODE_SIGN_FLAGS=--timestamp`), so the committed
    `CODE_SIGNING_ALLOWED: NO` keeps dev and CI builds signing-free — see
    [the build number](#the-build-number) for why that base setting stays.

    `--timestamp` is passed rather than assumed, **and read back off the
    signature** by the verification step below. A secure timestamp is a
    notarization requirement, and leaving it to an Xcode default would move the
    discovery of a missing one to the notary service's rejection, a full archive
    later — but so would passing it and never checking it arrived, since
    `OTHER_CODE_SIGN_FLAGS` holds a single value and anything that displaces it
    (a `settings.base` entry in `project.yml`) drops the timestamp with nothing
    local objecting. Re-signing after the archive is the *other* way to lose it,
    and the step below that does exactly that is why every one of its `codesign`
    lines passes `--timestamp` explicitly — a re-signed bundle carries the flags
    of the invocation that re-signed it and none of the archive's. **No entitlements file goes with the hardened runtime**: it permits
    `fork`/`exec` by default and library validation is per-process, so the `git`
    subprocess, the PTY shell and the downloaded language servers all launch with
    nothing declared. An entitlement is added when a concrete failure demands one
    and not in anticipation — every entitlement widens what the shipped app may
    do.

    `-configuration Release` is spelled out rather than left to Xcode's default
    because the *entire* updater is behind `#if !DEBUG`: the configuration is
    what decides whether the shipped app can update at all. Nothing else pins it
    — `Pisaka.xcodeproj` is generated and gitignored and `project.yml` declares
    no `schemes:`, so the scheme is auto-created — and a Debug archive would
    still embed `Sparkle.framework` (the package dependency links
    unconditionally), so every verification below would pass while the release
    shipped with "Check for Updates…" permanently disabled.
  - **Re-sign Sparkle's nested helpers**, between the archive and the
    verification. Xcode's archive re-signs the embedded `Sparkle.framework`
    *bundle* with the run's identity — that much is verified and is true — but it
    does not recurse into the framework's own nested helper bundles. Sparkle
    ships four of them, all under `Versions/B/` and all carrying upstream's
    ad-hoc signature (`flags=0x10002(adhoc,runtime)`, no team, no `Timestamp=`):
    `XPCServices/Installer.xpc`, `XPCServices/Downloader.xpc`, `Autoupdate` and
    `Updater.app`. The step signs those four, one `codesign` invocation per line,
    then the framework, then the app — **inside-out, because modifying nested
    code invalidates every seal above it**: a helper signed after its framework
    leaves the framework sealing a hash that no longer matches, and the app is
    therefore always last.

    Every invocation passes `--force`, the same `Developer ID Application`
    identity the archive selects, `--options runtime` and `--timestamp`;
    `Downloader.xpc` additionally passes `--preserve-metadata=entitlements`. That
    sequence and those flags come from **Sparkle's own distribution documentation
    for the pinned 2.9.5** (sparkle-project.org, the sandboxing/code signing
    page), followed rather than reasoned out from first principles, with
    `--timestamp` added on top of each: a secure timestamp is a notarization
    requirement, and upstream's snippet leaves it to an Xcode build setting that
    is not in play for a `codesign` run by hand. Preserving entitlements on
    `Downloader.xpc` alone is also upstream's instruction, so `Autoupdate`'s
    shipped `com.apple.application-identifier` is dropped deliberately — carrying
    an App-Store-shaped identifier belonging to a foreign team into a Developer
    ID signature is itself a notarization finding.

    **The list is written out, and `--deep` is refused.** Apple documents
    `--deep` as a debugging convenience unsuited to distribution signing — it
    applies one set of flags to everything it finds and silently signs whatever
    happens to be nested — while an enumerable list is the thing the verification
    below and `ReleaseWorkflowTests` can hold to account. Each of the four paths
    is `test -e`-guarded before it is signed, with an `::error::` naming it and
    saying that the pinned Sparkle version's internal layout changed and that
    both this list and the verification's required set must be re-derived from
    the new framework. That guard, not the notary service, is what must notice a
    layout change; a glob would hide exactly the change it exists to catch. It
    covers the four that are *known*, though — a helper a future Sparkle *adds*
    is invisible to it, and what catches that one is the per-binary enumeration
    in the verification step below: the explicit list leaves the new helper
    ad-hoc signed, and the walk refuses it. `--deep` would sign it into
    invisibility instead, which is the second reason it is refused.

    The six `codesign` invocations themselves are covered by an `ERR` trap that
    prints one `::error::` naming the causes worth checking first — Apple's
    timestamp authority refusing or rate-limiting (`--timestamp` reaches it six
    times here), the throwaway keychain having re-locked since the import step
    (reported as "User interaction is not allowed", which reads like a missing
    identity and is not one), or a second Developer ID Application identity in
    that keychain making the match ambiguous. A trap rather than a `|| { … }` per
    line: `ReleaseWorkflowTests` pins the inside-out order by each line's exact
    trailing path, so appending to those lines would break the pin.

    **The forward hazard, stated because it is silent:** the app is re-signed
    here with no `--entitlements`, which is correct only while the release ships
    no entitlements file (see the archive bullet above). The day one is added it
    has to be passed on this line too, or this step strips it back off and
    nothing fails until the shipped app cannot do the thing the entitlement was
    added for.

    **Why the step exists: `v1.0` was rejected.** Run 31936509608 came back
    `Invalid`, the log naming those four binaries and nothing else, each with the
    same two findings — "not signed with a valid Developer ID certificate" and
    "does not include a secure timestamp". Nothing was published: the
    notarization step read the verdict, printed the log and exited 1, well before
    `gh release create`, which is how the design above intends a rejection to
    land. Recovery was the ordinary one and is not a special case — delete the
    tag and push it again; the fresh run archives under a new
    `github.run_number` (see [the build number](#the-build-number)), and since
    that run never reached the publish step there was no draft release to delete
    first.
  - The app is taken straight from
    `build/Pisaka-macOS.xcarchive/Products/Applications/Pisaka.app` — no
    `-exportArchive`. That is a choice rather than a limitation now: by the time
    this step runs the app already carries the shipping Developer ID signature
    and the hardened runtime — the archive's, replaced in place by the re-sign
    pass above — so an export would only re-sign it under a *third*
    configuration on top of that (an export
    options plist whose team, identity and signing style have to be kept in step
    with the archive's command line forever, with a disagreement failing at the
    notary service rather than in the workflow). The app is then
    checked for an embedded `Sparkle.framework`, verified with
    `codesign --verify --deep --strict`, read back for the four facts
    notarization requires — an `Authority=Developer ID Application:` line, team
    `XJT3LK36GS`, `runtime` among the signature's flags, and a `Timestamp=` line
    (`codesign` prints `Signed Time=` instead when the secure timestamp is
    missing, so the two are distinguishable rather than one being absent) — **on the app and on
    the embedded framework both** (that is the "Xcode re-signs the framework with
    the same identity" claim, verified rather than assumed; the framework is also
    the one piece of nested code Sparkle itself re-checks on the user's machine),
    and checked for
    `CFBundleVersion`, `CFBundleShortVersionString`, `SUFeedURL` and
    `SUPublicEDKey` **one key at a time** with `plutil -extract`. Per-key is the
    point: a single `grep -E 'A|B|C'` over a `plutil -p` dump succeeds when *any*
    alternative matches, and `CFBundleVersion` is always generated — so the two
    Sparkle keys could stop being merged in from the partial
    `Resources/Info.plist` with the step still green, shipping an app that can
    never find an update.

    **Those two signature reads are bundle-level, and bundle-level was not
    enough.** `v1.0` passed both, passed `codesign --verify --deep --strict` on
    the whole app, and was rejected by the notary service naming four Mach-Os
    nested inside `Sparkle.framework`. `--deep --strict` asks whether every
    nested signature is *valid*, and an ad-hoc signature is a perfectly valid
    signature — validity is not identity. So the same four facts now also run
    over **every Mach-O in the app**, discovered rather than listed:
    `find "$APP" -type f` filtered through `file -b … | grep -q Mach-O`, with
    `-type f` making "discovered" mean "once each" (a framework is a tree of
    symlinks, and following them would check the same binary several times under
    several names while proving nothing extra). `codesign --display` on a nested
    bundle's *executable* reports that bundle's signature, so enumerating Mach-Os
    covers `Updater.app` and the two XPC services without a second,
    bundle-shaped walk; each is labelled by its path relative to the app, so a
    refusal names which binary failed. The bundle-level reads stay alongside the
    loop, leaving three call sites in the step: the app, the framework, and the
    enumeration. What the two named reads add is *independence*, not extra facts
    — `codesign --display` reports the same four lines for a bundle and for that
    bundle's main executable, so the loop already covers both, but only for as
    long as the enumeration works, and these two name their targets by path.
    They carry no resource seal; that is `codesign --verify --deep --strict`,
    which stays as well because it answers a question the four facts do not.

    Two refusals guard the enumeration itself, because a recursion that silently
    matches nothing is the same shape of bug as the one it was added to catch.
    An **empty enumeration is a refusal, not a pass**: `find` and `file` are two
    tools whose output is parsed here, either could stop matching without
    failing, and the loop would then run zero times, print nothing, and leave the
    step — and every assertion about it — green while checking no binary at all.
    And the **four helper Mach-Os the notary service named must be among what was
    enumerated**, by exact path: that is the floor under the enumeration and the
    counterpart to the re-sign step's explicit list, so a Sparkle version that
    moves or renames one of them refuses here rather than at the submission
    twenty minutes later.

    Two of those four keys are checked by **value** rather than by presence.
    `CFBundleVersion` must equal this run's `github.run_number` (see below), and
    `CFBundleShortVersionString` must equal the tag's version. The second is not
    a duplicate of the preflight's tag-vs-`MARKETING_VERSION` refusal: that one
    reads `project.yml` with `sed` and takes the first match, which is a textual
    read rather than the *effective* build setting, so a per-configuration or
    per-destination override under `configs:`/`settings:` — or simply a second
    occurrence sorting first — would have it compare the tag against a value the
    archive never uses. It would pass, and the release would advertise a
    `sparkle:shortVersionString` the app does not report under a zip named after
    neither. Here the archive is the authority, which is the same argument the
    `CFBundleVersion` check makes.
  - **Launch the archived app (smoke test)** — the one step in the whole
    pipeline that *executes* the product instead of reading bytes off it. It
    runs `Contents/MacOS/Pisaka` in the background, polls the process with
    `kill -0` for five seconds and then kills it. **Being killed is the pass.**
    The app going away on its own is a refusal *whatever its exit status*,
    including `0`: a clean exit seconds after launch is not a working editor
    either, and a killed process and a crashed one both report ≥128, which is
    why liveness is polled rather than read back out of `wait`. On the refusing
    path both the redirected output and the newest `Pisaka*.ips` report under
    `~/Library/Logs/DiagnosticReports/` are printed before the `::error::`,
    because a refusal nobody can re-run interactively has to carry its own
    evidence. The
    assertion is that the process *lives*, nothing more — windows appearing, the
    updater polling github.com, its first-launch permission prompt and session
    restore finding no session are all inert to it.

    It sits **after the re-sign and before the submission**, and both halves of
    that matter. After, so what it launches is what ships — hardened runtime,
    Developer ID signature, Sparkle's four nested helpers already replaced;
    launching before would exercise a bundle this run then throws away. Before,
    so a build that cannot start never reaches the notary queue: the alternative
    costs twenty minutes and a full archive to learn what five seconds answers
    here, and leaves a dead build one accepted verdict away from a publish. The
    bundle is not yet notarized, which changes nothing — nothing quarantined it,
    so Gatekeeper is not in play and this step says nothing about whether Apple
    will accept it. Launching does not modify the bundle either, and that is not
    an assumption: the staple step's `codesign --verify --deep --strict` runs
    afterwards and is the standing proof.

    An identical script — identical to the line, apart from `APP=`, which
    `ReleaseWorkflowTests` asserts — runs in `ci.yml` against the DerivedData
    Release product, so the same failure is caught on a pull request rather than
    on a tag. Why the step exists at all is
    [the `v1.0` launch crash](#the-v10-launch-crash-and-why-every-gate-missed-it)
    below.
  - **Notarize**, then **staple** — the two steps described in
    [Notarization and stapling](#notarization-and-stapling) above. They sit
    between the smoke launch and the shipped zip, which is the only order that
    ships a working app.
  - `ditto -c -k --sequesterRsrc --keepParent` into a staging directory that
    holds nothing else. `ditto` and not `zip`: the embedded framework is a bundle
    of symlinks, and a plain `zip` stores them as duplicated regular files, after
    which the unzipped framework fails its own signature check. The directory is
    dedicated because `generate_appcast` reads *every* update it finds in the
    directory it is pointed at.
  - `generate_appcast` (from the tools fetched beside the preflight, above) with
    `--ed-key-file -`, so the private key travels on stdin and never lands on
    disk — **followed by a refusal if the feed it wrote carries no
    `sparkle:edSignature`**. That check exists because it is the one way a fully
    green run can still publish a release every installed copy rejects, and it is
    invisible from the exit code: when the app's `SUPublicEDKey` is not the mate
    of the private key on stdin, `generate_appcast` prints a *warning*, leaves
    the signature nil and exits 0 (`Appcast.swift` only rethrows `signingError`,
    which that branch deliberately does not set; `FeedXML.swift` then just omits
    the attribute). The preflight cannot cover it — it can see that the committed
    key is no longer the placeholder, but not that it pairs with a secret it must
    never read — so the guard is on the artefact, and it runs before
    `gh release create`. If it fires, run `bin/generate_keys -p` on the machine
    holding the pair, compare its output against both `Resources/Info.plist` and
    the stored secret, fix whichever is wrong, and re-tag.
  - `gh release create --draft` attaching the zip and `appcast.xml`, then a check
    that the draft carries **exactly** those two asset names, then
    `gh release edit --draft=false`. That asset name is load-bearing:
    `releases/latest/download/appcast.xml` resolves by asset name, so it must
    stay exactly the last path component of `SUFeedURL`.

    The draft is what makes publication atomic from an installed copy's point of
    view. `gh release create` is not transactional — it creates the release first
    and uploads each asset afterwards — so a transient failure on the second
    upload would otherwise leave a *published* release carrying the zip and no
    feed. `releases/latest` is exactly what `SUFeedURL` resolves through and it
    skips drafts, so nothing is visible to anybody until both assets are
    confirmed; a published release missing `appcast.xml` would instead 404 that
    URL for every installed copy, silently, until someone noticed. The promotion
    is deliberately the last line of the step: anything after it would run
    against an already-visible release.
  - **Remove the signing keychain**, `if: always()` and last, so no path through
    the job — success, any failure above, or a cancellation — leaves either
    private key on the runner or the search list rewritten. It deliberately does
    not `set -e`: a failure to restore the search list must not skip deleting the
    keychain. Not aborting is not the same as not reporting, though — each
    command records into a `STATUS` accumulator and the step exits non-zero if
    any of them failed, because without one the step's exit code is its trailing
    `rm -f`'s, which succeeds whether or not the keychain was deleted. That
    cannot mask an earlier failure (that step is already red and already
    annotated); it only stops a cleanup failure from being the one thing here
    that passes silently. If it does fire, treat the certificate and the notary
    key as still on the runner and rotate both.

`ReleaseWorkflowTests` pins all of the above statically — the tag trigger and the
permission split (by set equality over the parsed blocks, so an added
`workflow_dispatch:` or `packages: write` fails rather than slipping past a
substring match), the `needs: test` gate, the concurrency group,
`-configuration Release` (scoped to the archive step, so a later step carrying
the flag cannot stand in for it), the archive's Developer ID identity, team,
`ENABLE_HARDENED_RUNTIME=YES` and `--timestamp` (with `CODE_SIGN_IDENTITY=-`
asserted to appear nowhere active — the ad-hoc pin deliberately updated rather
than deleted), the throwaway keychain (created under `$RUNNER_TEMP`, the login
keychain never named, the three certificate refusals — the base64 decode, the
`security import` and the identity — the import before the archive, the
unlock and the lock settings including the absence of `-l`, the partition list's
`-s`, the decoded `.p12`
written under a `(umask 077; …)` subshell, the `if: always()`
deletion of the keychain *and of both private keys by path*), the re-sign pass
(each of the four nested helpers signed; every signing invocation in that step
carrying `--force`, the Developer ID identity, `--options runtime` and
`--timestamp`; `--preserve-metadata=entitlements` on `Downloader.xpc` alone; the
inside-out order compared by index rather than by presence — helpers before the
framework, framework before the app; each of the four existence guards reaching
`exit 1`; and `--deep` asserted absent from every *signing* invocation anywhere
in the file, while the legitimate `codesign --verify --deep --strict` call is
separately asserted to remain), the Developer ID /
team / hardened-runtime / secure-timestamp read-back at all three call sites —
the app, the embedded framework, and the loop over every Mach-O in the app —
*and the dump being printed as well as judged*, the Mach-O enumeration itself
(a `find` over the app whose results are filtered on `Mach-O` and fed to
`verify_developer_id_signature`, so deleting the recursion fails the suite) with
both of its refusals asserted by mechanism (the empty enumeration, and the four
required helper paths — matched against the same constant the re-sign
assertions use, so the two lists cannot drift apart),
`project.yml` staying signing-free, the notarization submit (`--wait` plus the
API-key trio, the exit-code capture that keeps `set -e` from pre-empting the
verdict, the guarded JSON reads, the non-`Accepted` branch exiting 1, the log
fetch, the `.p8` written under the same `umask 077` subshell and removed by a
`trap … EXIT`), the fact that
every step is fatal to the job (no `continue-on-error:`, and `if: always()` on
the cleanup as the only step condition — the ci.yml-scoped counterpart of which
is asserted too, since without it every refusal below would be a log line), the
**two smoke launches** — each pinned by mechanism on its own side (the app
launched in the background, liveness polled with `kill -0`, the death branch
reaching `exit 1`, `APP=` naming that workflow's own product), the success path
asserted to be survival rather than a zero exit (no comparison of any status
against zero, no `exit 0`, the only non-refusing path running `kill "$PID"`), the
`DEADLINE` pinned against the degenerate `0` that would make the loop body never
run and every launch "survive", the death branch printing the captured output
before refusing, and the two bodies asserted **equal after dropping the `APP=`
line** — because two hand-maintained copies drifting apart means one half of the
pipeline stops checking what the other does, and the fix is to copy rather than
to reconcile by hand, the job budget exceeding the notary
`--timeout` by at least `ci.yml`'s build budget — *read out of `ci.yml`* rather
than restated as a number, so raising CI's budget cannot leave this claim true
only by coincidence — the
staple (refusing with a message of its own rather than bare `Error 65`) and its
`stapler validate`, the full step ordering (archive < re-sign < verify < smoke
launch < notarize < staple < shipped zip < `generate_appcast` <
`gh release create` —
re-signing after the verification would verify signatures the run is about to
replace, re-signing after the submission would invalidate the ticket Apple
issued, smoke-launching before the re-sign would test a bundle the run then
replaces, and smoke-launching after the submission would let a dead build occupy
the notary queue and, worse, reach a publish), the shipped zip
being a different artefact from the submitted one, the absence of the old
Gatekeeper workaround strings from every document that used to carry them, the
unsigned-appcast refusal and its position
before `gh release create`, the per-key `plutil -extract` verification, the two
value checks inside it (`CFBundleVersion` against the run number,
`CFBundleShortVersionString` against the tag), the draft-then-promote publication
(the `--draft` flag on the create, the asset-set refusal, and the promotion as
the step's last line), `ditto -c -k`, the run-number build number, the Sparkle and XcodeGen pins (the
latter compared against `ci.yml`, since drift between the two files is otherwise
silent), the tools-before-archive ordering, and two cross-file pairs against
`Resources/Info.plist`: the asset name and the repository, both against
`SUFeedURL`.

**The preflight refusals are asserted by mechanism, not by mention.** Each guard
must exist *and* its branch must reach `exit 1`. That distinction is the whole
value of the test: asserting merely that the file contains the string
`SPARKLE_PRIVATE_EDDSA_KEY` proves nothing, because it also appears in the
appcast step's `env:` block — so a preflight quietly downgraded from `::error::`
+ `exit 1` to a `::warning::` would keep such an assertion green while publishing
exactly the release the guard exists to refuse. The suite is mutation-tested
against that scenario.

Every assertion in that suite also runs over **comment-stripped** text, which is
load-bearing rather than tidy: `release.yml` documents itself by quoting its own
commands (`# \`ditto -c -k\` and not \`zip\`` sits three lines above the real
invocation), so a raw substring search stays green when the command it names is
deleted.

**What the `v1.0` rejection cost, stated once so it generalizes.** Two things
follow from a dependency that ships nested *executable* helpers, and neither was
obvious before the notary service said so:

- **The dependency's own distribution documentation is part of de-risking a
  release.** Sparkle documents the exact re-sign sequence its framework needs,
  flag for flag; reading it costs minutes, and not reading it cost a rejected
  tag. Any future dependency that embeds helper bundles, XPC services or
  command-line tools owes the same read before the first release that ships it.
- **A local signature check must recurse to every Mach-O.** The checks that
  existed were *true* — the app and the framework really did carry a Developer ID
  Application signature, this team, the hardened runtime and a secure timestamp —
  and they still missed four binaries, because a bundle-level read says nothing
  about code nested inside the bundle, and `--deep --strict` only asks whether
  that nested code's signature is valid. Truth at the level you happened to check
  is not coverage of the level Apple checks.

### The `v1.0` launch crash, and why every gate missed it

The re-pushed `v1.0` tag ran green end to end: signed, notarized, stapled,
`spctl` reporting `source=Notarized Developer ID`, both assets published. The
published app then **aborted in dyld on the first machine that opened it**,
before any code of ours ran:

```
dyld[…]: Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
  Referenced from: /Applications/Pisaka.app/Contents/MacOS/Pisaka
  Reason: tried: '/usr/lib/swift/Sparkle.framework/…' (no such file),
          '…/Pisaka.app/Contents/MacOS/Frameworks/Sparkle.framework/…' (no such file)
```

**The root cause is one build setting that had been wrong since the first
commit.** The multiplatform target inherited XcodeGen's `LD_RUNPATH_SEARCH_PATHS`
preset — `$(inherited)` plus `@executable_path/Frameworks` — on *both*
destinations. That is the iOS layout, where the executable sits at the bundle
root; on macOS the executable is in `Contents/MacOS/` and frameworks in
`Contents/Frameworks/`, so the entry has to be `@executable_path/../Frameworks`.
The searched path in the message above is exactly the preset resolving against
the macOS layout. Nothing had ever dereferenced it, because Sparkle is this
project's **first embedded dynamic framework**: every other dependency links
statically into the executable, and a runpath nobody resolves through is a
runpath nobody notices. The fix is `LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]` in
`project.yml`, pinned by `ReleaseMetadataTests` and explained in
`docs/architecture/core-services.md`.

**Every gate passed, and none of them could have failed.** `swift test` compiles
`PisakaCore` and reads repository files; CI builds the app, which only proves it
*links* against the framework's stub; this workflow reads signatures, plist keys,
a notary verdict and a Gatekeeper assessment back off the archive. Every one of
those is byte-level. **Nothing between the compiler and the user had ever
executed the binary** — and a dynamic-link failure is invisible until something
does. The gates were not weak at what they check; the pipeline had no step that
asked the only question a user asks first.

**The smoke launch is the structural answer**, and it is deliberately structural
rather than a check for this one message: it runs the product in both places that
build the shipping configuration (`ci.yml` against the DerivedData Release
product, `release.yml` against the archived app before the submission) and
refuses if the process is not still alive five seconds later. Any startup crash
fails it, not just an unresolved `@rpath`.

Recovery was the ordinary one and needs no special case — delete the tag, push
it again, as [above](#cutting-a-release); the fresh run archives under a new
`github.run_number` (see [the build number](#the-build-number)). A release that
was already published has to be deleted along with the tag.

**Known limit, recorded rather than fixed: there is no iOS runtime smoke test.**
CI runs no simulator by design, so the iOS product's dynamic loading is checked
by nothing. The same class of failure on that destination would still reach a
user.

### Upgrading Sparkle

Two hard-coded path lists in `.github/workflows/release.yml` are pinned to
Sparkle 2.9.5's internal layout — the re-sign step's four helper *bundles* and
the verification step's four required *Mach-Os* one level inside them — plus
`sparkleNestedHelpers` in `ReleaseWorkflowTests`, which is the same fact a third
time and is what keeps the two halves from drifting. Bumping `exactVersion:` in
`project.yml` without re-deriving them is caught, but only by an `::error::` on
a pushed tag, after the archive. Re-derive them first:

```sh
# `Pisaka.xcodeproj` is generated and gitignored, so this comes first: without
# it the resolve below fails with "does not exist" on a clean checkout — on the
# one path whose alternative is guessing the two path lists.
xcodegen generate
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=macOS' \
  -clonedSourcePackagesDirPath SourcePackages -resolvePackageDependencies
FW=SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework

# 1. Every Mach-O the new framework ships — both lists are derived from this one
#    output. `-type f` is what makes it once each.
find "$FW" -type f -exec sh -c 'file -b "$1" | grep -q Mach-O' _ {} \; -print

# 2. What each one arrives signed as, and which of them carries entitlements.
find "$FW" -type f -exec sh -c 'file -b "$1" | grep -q Mach-O' _ {} \; -print \
  | while IFS= read -r B; do codesign -dvv --entitlements - "$B" 2>&1; done
```

`$FW` names one xcframework slice by hand; if a future artifact stops calling it
`macos-arm64_x86_64`, take whichever macOS slice it does ship — the nested layout
is what is being read, and it is the same in every slice.

Step 1's output is five paths for 2.9.5 — the four helpers' executables and the
framework's own binary, `Versions/B/Sparkle` — and **the two lists divide it
differently**, which is the whole reason to write them out rather than reuse one:

- **The re-sign step's list** is that output with each nested bundle's executable
  replaced by the bundle that contains it
  (`…/Updater.app/Contents/MacOS/Updater` → `…/Updater.app`,
  `…/Versions/B/Sparkle` → `Sparkle.framework`), which is why it has as many
  entries as step 1 printed: `codesign` signs *bundles*, and the framework is one
  of them — signed after its four helpers, before the app.
- **The verification step's `REQUIRED` set** is that same output made relative to
  the app, **minus the framework's own binary** — one fewer entry. That one is
  left out because it is not a floor the enumeration needs: the framework is
  already checked by path, as a bundle, by the second
  `verify_developer_id_signature` call above the loop. `REQUIRED` exists to pin
  the four the notary service named, so a Sparkle that moves or renames one of
  them is refused rather than silently dropped from the walk.

Step 2 is the check that the premise still holds: every helper should read
`flags=0x10002(adhoc,runtime)` with `TeamIdentifier=not set` and no `Timestamp=`
— that is *why* they are re-signed, and a version that started shipping them
properly signed would make the whole pass unnecessary rather than merely stale.

Step 2 does **not** decide `--preserve-metadata=entitlements`. As of 2.9.5 the
dump shows `Downloader.xpc`, `Installer.xpc` and `Updater.app` carrying an empty
entitlements dict and only `Autoupdate` carrying anything at all, so read
literally it would say no helper needs the flag. The flag follows upstream's
published signing sequence instead, and stays on `Downloader.xpc` for as long as
that sequence puts it there — an empty dict today is not a reason to drop it; it
is what makes the day upstream adds an entitlement a non-event. `Autoupdate`'s
shipped entitlement is the one this release deliberately drops (see
[the re-sign pass](#automated-releases)), and that too is upstream's instruction
rather than a reading of the dump.

Then update both lists in `release.yml` and `sparkleNestedHelpers` in
`ReleaseWorkflowTests.swift`, re-read Sparkle's distribution documentation for
the new version in case the sequence itself changed, and run `swift test`.

### Why `github.run_number` is the build number

`CFBundleVersion` is what Sparkle compares to decide one build is newer than
another, so it must strictly increase across every release this workflow ever
publishes. `github.run_number` is a counter GitHub increments on every run and
never resets — the monotonic integer the rules above ask for, produced without
committing anything, so `git status` stays clean after a release.

**The caveat: that counter is keyed on the workflow file's name.** Renaming
`release.yml`, or replacing it with a differently-named workflow, restarts it at
1 — and a build numbered 1 published after a build numbered 12 is one Sparkle
will never offer. Any rename must add a fixed offset large enough to clear every
number already released.

### Manual verification owed for this feature

None of these is reachable from `swift test`: they need a network, a real Apple
account, two published releases, and — for the last of them — a machine that
downloaded the app rather than built it.

- ~~**Swap in the real key.**~~ Done 2026-08-16: the real `SUPublicEDKey` is
  committed, `swift test` passes the shape assertions against it, and the
  placeholder string appears nowhere in `Resources/Info.plist`.
- **The first tag push — done, in two runs, and the second one published.** The
  first `v1.0` run (31936509608) reached the notary service, which returned
  `Invalid` for the four nested Sparkle helpers (see
  [the re-sign pass](#automated-releases) above); nothing was published and the
  rejection surfaced with its log printed — the failure path behaving as
  designed. The re-pushed tag then ran green end to end and **published `v1.0`
  with both assets and the expected build number**, so the whole happy path is
  now exercised: preflight, throwaway keychain, Developer ID signed
  hardened-runtime archive, the re-sign pass, notarization, stapling, `spctl`,
  the signed appcast and the draft-then-promote publication.

  That is also where this document's own limits showed. A green run means every
  *byte-level* gate passed, and the published app then crashed in dyld on first
  launch — see
  [the `v1.0` launch crash](#the-v10-launch-crash-and-why-every-gate-missed-it).
  The two smoke launches close that gap for future tags; what a successful run
  proves is stated above and does not extend to "the app works".

  Still owed, deliberately: the check that a tag whose version does not match
  `MARKETING_VERSION` fails in the preflight, *before* archiving, with the
  intended message.
- **The first notarized tag, from a real download — attempted, and it is what
  caught the crash.** The published `v1.0` was downloaded, moved to
  `/Applications` and double-clicked, and the app aborted in dyld
  ([the launch crash](#the-v10-launch-crash-and-why-every-gate-missed-it)) —
  found here because every automated gate in this pipeline had already said yes.
  So this stays **owed in full** against the next release rather than partly
  done: the criterion below is not "no refusal dialog", it is that dialog
  *followed by an app that runs*, and half of it is exactly what failed. The
  pass, in full:

  The workflow's own
  `spctl --assess` gate proves the bundle it built passes the system policy; what
  a runner structurally cannot do is the thing users do. So: download the zip
  from the release page in a browser (so it carries the quarantine flag a `curl`
  in CI does not), unzip it, move it to `/Applications` and **double-click it**.
  What must happen is a single *confirmable* dialog: "“Pisaka” is an app
  downloaded from the Internet. Are you sure you want to open it?", saying Apple
  checked it for malicious software and none was detected, with a button that
  opens it. That dialog is not the failure — quarantine still applies to a
  notarized app, and macOS still asks once. **The failure is a dialog with no
  way forward** — one saying the developer cannot be verified or that Apple
  cannot check the app for malicious software, sending you to System Settings →
  Privacy & Security, or any instruction to clear the quarantine flag from a
  terminal. None of those may appear, and the app must launch from that one
  confirmation and never ask again. That is this feature's acceptance criterion,
  and it is only true from a real download.
- **The end-to-end update pass.** Install release N, publish N+1, and confirm the
  installed copy offers and installs it through Sparkle's own UI, and that
  "Check for Updates…" works on demand. What this specifically proves is that
  **Sparkle's own chain still works over a notarized, stapled build** — the
  updater unpacks the zip, checks the EdDSA signature and swaps the app, and none
  of that consults Apple's signature. Confirm the updated copy still launches
  afterwards: the update replaces a stapled bundle with another stapled bundle,
  and a copy that stopped launching would mean the ticket did not survive.
- **A downloaded language server under the hardened runtime.** Accept the
  TypeScript server's consent prompt on the notarized build and confirm the
  unpacked `node` actually launches — the same check the provisioning list below
  flags for "a notarized build specifically", now that such a build exists. The
  app writes that binary itself so it carries no quarantine flag, and library
  validation is per-process, so this is expected to work; it is exercised nowhere
  else, and an entitlement (Decision: none ship today) would be added only if
  this failed.

## Check by hand before the first submission

`swift test` and CI cover everything static — the plists, the privacy manifest,
the pins, the license manifest. What follows is what they structurally cannot
cover, because the view layer is untested by convention and because nothing in
CI has a network, a `tar` or a child process:

- **iOS layout at real screen size.** `INFOPLIST_KEY_UILaunchScreen_Generation:
  YES` is what takes the app out of letterboxed compatibility mode, so the first
  build carrying it is also the first one to get true screen bounds, real
  safe-area insets and iPad multitasking. Launch on an iPhone simulator (notched)
  and an iPad simulator, and exercise Slide Over / Split View on the iPad — a
  layout regression here would ship unnoticed otherwise.
- **The Acknowledgements screens.** Open them on both destinations and scroll one
  long text (libgit2's, 66 KB / 1,323 lines) to its tail. That the pane scrolls
  rather than clipping is the whole obligation, and nothing in `swift test` sees
  the rendered view.
- **Provisioned language servers, end to end** (macOS). The whole of phase 2b is
  network, `Process` and view layer, so none of it is reachable from `swift test`:
  1. Open a `.ts` file in a project with no `node_modules`. The consent banner
     appears, sized. Accept it, and confirm completion and Go to Definition become
     semantic without a restart — including that **completing a symbol that needs
     an import inserts the import line** (D4's auto-import, which 2a had no server
     that could exercise; see `core-lsp.md`).
  2. Open a `.py` file, accept, and confirm the second offer is the ~4 MB one.
  3. Preferences → Language Servers: Remove one. Its process must be gone
     *immediately*, and the language must fall back silently.
  4. Quit the app and run `pgrep -fl "node|pyright|typescript-language-server"`.
     **Nothing.** This is the orphan check the provisioning layer's push-then-delete
     ordering exists for, and it has no automated equivalent.
  5. Cut the network mid-download and press Retry. The row says so; nothing is
     left under `LanguageServers/.staging/`.
  6. Confirm Acknowledgements grows a *Language Servers* section while something is
     installed and loses it again after the last removal — the only place the
     downloaded components' notices appear, since `LicenseCoverageTests` cannot
     see them.
  7. On a **notarized** build specifically: confirm the unpacked `node` actually
     launches. The app writes that binary itself so it carries no quarantine flag,
     and library validation does not apply to a child process, but a hardened-runtime
     app spawning a downloaded executable is not exercised anywhere else.

## Done since this document first said "not here yet"

- ~~`DEVELOPMENT_TEAM` and the signing configuration.~~ **Done (2026-08-16).**
  Team `XJT3LK36GS`; the release archives with a Developer ID Application
  identity and the hardened runtime, every signing setting supplied on the
  `xcodebuild` command line. The committed `CODE_SIGNING_ALLOWED: NO` stays —
  see [the build number](#the-build-number).
- ~~Notarization / stapling for the macOS build.~~ **Done (2026-08-16).** Every
  release is submitted to the notary service, stapled and assessed with `spctl`
  before its zip is made — see
  [Notarization and stapling](#notarization-and-stapling).

## Not here yet

The following are account-side and are not part of the release workflow:

- **The Mac App Store — ruled out, not pending.** App Sandbox, which it requires,
  is not merely undecided: the macOS build shells out to `git` through `Process`
  (`GitCLIService`) and opens a PTY for the embedded terminal, neither of which
  survives sandboxing. Phase 2b adds a second, **independent** reason: the macOS
  app downloads and executes third-party binaries at the user's request, which
  App Review guideline 2.5.2 forbids outright regardless of sandboxing. So the
  macOS channel is Developer ID + notarization — which is what ships — unless
  those features are reworked. Nothing in the iOS build does either of these; the
  whole layer is behind `#if os(macOS)`, so the iOS App Store path is unaffected.
- The App Store Connect app records, store metadata and screenshots.

Neither depends on anything in this repository; adding them is a separate change
to this document.

## Resolved compliance question: statically linked LGPL

**Both** shipped binaries link libgit2, whose SwiftPM target compiles
`deps/xdiff` (LibXDiff, LGPL-2.1-or-later) — see the sub-dependency section of
`docs/architecture/core-services.md`. The shipped
`Resources/Licenses/libgit2.txt` carries that notice, which settles the
*attribution* half.

This used to read "the iOS build", and that was too narrow. libgit2 carries no
`destinationFilters:` (only Sparkle does), so it links into the **macOS** app as
well — unused by any macOS code path, but statically linked all the same.
Verified rather than assumed, against a Release archive of the macOS app:

```sh
nm Pisaka.app/Contents/MacOS/Pisaka | grep -c '_xdl_'   # 37 LibXDiff symbols
```

It does not settle the *relinking* half. LGPL-2.1 §6 is satisfied by a notice
only when the library is dynamically linked; a static link into a closed-source
binary additionally requires an offer of the object files (or equivalent) so a
recipient can relink against a modified LibXDiff. libgit2's own
GPLv2-with-linking-exception covers libgit2's files and not the LGPL-headered
xdiff tree, so it does not cover this.

**Decision (2026-08-16): satisfied by the app being open source.** Pisaka's
complete source is public in this repository under the MIT license (the root
`LICENSE`), and every release the tag-triggered workflow publishes is built by
`.github/workflows/release.yml` from a tagged commit of that same public
repository. A recipient of the binary can therefore obtain the full application
source, modify or replace the vendored LibXDiff (`deps/xdiff` inside the pinned
libgit2 package), and rebuild — which is the ability LGPL-2.1 §6 exists to
guarantee, provided in its strongest form (complete corresponding source, not an
object-file offer). The "closed-source binary" scenario the paragraph above
describes does not apply here; no object-file offer, no `deps/xdiff` removal
and no `destinationFilters: [iOS]` workaround is needed.

Two conditions keep this decision true, and both would reopen it:

- **The repository stays public and MIT-licensed.** Taking the source private,
  or relicensing it under terms that forbid rebuilding, removes the very thing
  that satisfies §6 — from that moment every distributed build (GitHub Releases
  and any store) needs one of the previously listed alternatives: an
  object-files offer, or dropping/replacing `deps/xdiff`.
- **Shipped binaries are built from committed, tagged source.** A release built
  from uncommitted local changes would distribute a binary whose corresponding
  source is not actually available; the workflow's tags-only trigger makes this
  structurally hard to do by accident.

The same reasoning covers a future App Store submission unchanged: source
availability satisfies the relinking half regardless of the distribution
channel, and the attribution half already ships inside the app.
