# Releasing Pisaka

Everything here is repository-side. Apple signing, notarization and the App Store
Connect record are deliberately absent — see [Not here yet](#not-here-yet).

There are two paths, and they answer different questions:

- [Automated releases](#automated-releases) — pushing a `vX.Y` tag builds an
  ad-hoc-signed macOS app and publishes it as a GitHub Release with a signed
  Sparkle appcast, so installed copies can update themselves. This is the
  distribution channel that exists today.
- The by-hand archive below, which is the **build-number mechanism** and the
  path an eventual App Store / Developer ID upload takes. The workflow runs the
  same command with the same rules.

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
limitations" section is the list of what 1.0 does not do.

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

The archive this produces is **unsigned** and cannot be uploaded yet:
`project.yml` carries `CODE_SIGNING_ALLOWED: NO` in the target's
`settings.base`, because there is no `DEVELOPMENT_TEAM` (see
[Not here yet](#not-here-yet)). The command below is the build-number mechanism,
verified end to end; when a signing team exists, that base setting has to move
to the debug config or be dropped, or signing will stay suppressed no matter
what the archive is asked for.

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
`swift test` gate, archives an **ad-hoc-signed** macOS app, zips it, signs the
zip with the project's EdDSA key and publishes a GitHub Release carrying exactly
two assets — `Pisaka-X.Y.zip` and `appcast.xml`. The shipped app reads
`https://github.com/HawkeyePierce89/pisaka/releases/latest/download/appcast.xml`
(`SUFeedURL` in `Resources/Info.plist`) and verifies every download against
`SUPublicEDKey` in the same file, so a published release is what an installed
copy offers as an update through Sparkle's own UI.

### One-time setup: the EdDSA key pair

The app ships a **placeholder** public key today
(`UExBQ0VIT0xERVItUkVQTEFDRS1XSVRILVJFQUwtS1k=`, base64 of the ASCII string
`PLACEHOLDER-REPLACE-WITH-REAL-KY`). It is structurally valid — 32 bytes, so
`swift test`'s shape assertion passes — and deliberately obvious. Before the
first real release, once and by hand:

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
   the file undoes. `.gitignore` carries `private-key.txt` as a second guard for
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

Until step 2 is done the workflow refuses to release: its preflight greps the
placeholder value out of `Resources/Info.plist` and fails, so a release signed by
a key no installed copy trusts cannot be produced by accident.

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
recovering means deleting and re-pushing that tag.

The workflow then, in order:

- **`test` job** — `swift test`, pinned identically to `ci.yml` (same SHA-pinned
  `actions/checkout` and `maxim-lobanov/setup-xcode`, Xcode `16.4`). Nothing is
  built or published unless it is green.
- **`release` job** (`needs: test`, the only job with `contents: write`;
  the workflow's top level is `contents: read`) —
  - **Preflight, before anything expensive.** Four refusals, each with an
    actionable message: `MARKETING_VERSION` unreadable from `project.yml`; the
    tag's version (`v` stripped) ≠ `MARKETING_VERSION`; the
    `SPARKLE_PRIVATE_EDDSA_KEY` secret empty or absent; `SUPublicEDKey` still the
    placeholder. The version is parsed with a **quote-agnostic** `sed`, because
    `MARKETING_VERSION: 1.1` is as valid a YAML scalar as `"1.1"` and a parser
    that only understood the quoted form would read an empty string and then
    refuse every release while blaming `project.yml`; an empty read is reported
    as the parse failure it is, not as a version mismatch.
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
    `CODE_SIGN_IDENTITY=-`), so the committed `CODE_SIGNING_ALLOWED: NO` keeps
    dev and CI builds signing-free.

    `-configuration Release` is spelled out rather than left to Xcode's default
    because the *entire* updater is behind `#if !DEBUG`: the configuration is
    what decides whether the shipped app can update at all. Nothing else pins it
    — `Pisaka.xcodeproj` is generated and gitignored and `project.yml` declares
    no `schemes:`, so the scheme is auto-created — and a Debug archive would
    still embed `Sparkle.framework` (the package dependency links
    unconditionally), so every verification below would pass while the release
    shipped with "Check for Updates…" permanently disabled.
  - The app is taken straight from
    `build/Pisaka-macOS.xcarchive/Products/Applications/Pisaka.app` — no
    `-exportArchive`, which needs an export options plist naming a team — then
    checked for an embedded `Sparkle.framework`, verified with
    `codesign --verify --deep --strict`, and checked for
    `CFBundleVersion`, `CFBundleShortVersionString`, `SUFeedURL` and
    `SUPublicEDKey` **one key at a time** with `plutil -extract`. Per-key is the
    point: a single `grep -E 'A|B|C'` over a `plutil -p` dump succeeds when *any*
    alternative matches, and `CFBundleVersion` is always generated — so the two
    Sparkle keys could stop being merged in from the partial
    `Resources/Info.plist` with the step still green, shipping an app that can
    never find an update.
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
  - `gh release create` attaching the zip and `appcast.xml`. That asset name is
    load-bearing: `releases/latest/download/appcast.xml` resolves by asset name,
    so it must stay exactly the last path component of `SUFeedURL`.

`ReleaseWorkflowTests` pins all of the above statically — the tag trigger and the
permission split (by set equality over the parsed blocks, so an added
`workflow_dispatch:` or `packages: write` fails rather than slipping past a
substring match), the `needs: test` gate, the concurrency group,
`-configuration Release` (scoped to the archive step, so a later step carrying
the flag cannot stand in for it), the unsigned-appcast refusal and its position
before `gh release create`, the per-key `plutil -extract` verification,
`ditto -c -k`, the run-number build number, the Sparkle and XcodeGen pins (the
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

### Gatekeeper on the first install (accepted)

The app is ad-hoc signed, not Developer ID signed and not notarized, so a zip
downloaded from GitHub carries the quarantine flag and macOS refuses to open it
on the first double-click. The documented workaround, repeated in every release's
notes: `xattr -d com.apple.quarantine /Applications/Pisaka.app`, or open the app
once and allow it from **System Settings → Privacy & Security → Open Anyway**.

The order matters and is not cosmetic. **Right-click → Open is listed last and
qualified**, because macOS 15 removed that Control-click override for
unnotarized apps — and the release runner is `macos-15` while the supported floor
is macOS 13, so a large share of users would be following an instruction that
does nothing at all. It still works on macOS 13 and 14; the two paths above work
everywhere.

This is friction on the *first manual install only*. Sparkle's in-place updates
do not repeat it: the updater unarchives and swaps the app itself rather than
handing the user a downloaded file, and its integrity chain here is the EdDSA
signature over the zip — which is exactly why the key handling above matters more
than the code signature does today.

`.github/workflows/release.yml`'s archive step marks the **Developer ID /
notarization seam**: swap `CODE_SIGN_IDENTITY=-` for the "Developer ID
Application" identity, add `DEVELOPMENT_TEAM`, import the certificate into a
temporary keychain, and add a notarize-and-staple step before the zip. Nothing
else in the workflow changes, and this whole section goes away.

### Manual verification owed for this feature

None of these is reachable from `swift test` — the first two need the real key
and a network, the third needs two published releases:

- **Swap in the real key.** After replacing `SUPublicEDKey`, confirm `swift test`
  still passes (the shape assertions) and that the placeholder string appears
  nowhere in `Resources/Info.plist`.
- **The first tag push.** Confirm the workflow creates the release with both
  assets and the expected build number, and — deliberately — that a tag whose
  version does not match `MARKETING_VERSION` fails in the preflight, *before*
  archiving, with the intended message.
- **The end-to-end update pass.** Install release N, publish N+1, and confirm the
  installed copy offers and installs it through Sparkle's own UI, and that
  "Check for Updates…" works on demand. What this specifically proves is that
  **Sparkle accepts an ad-hoc-signed update**, using the EdDSA signature as the
  integrity chain — the assumption the whole channel rests on until Developer ID
  exists. Confirm at the same time that the first manual install shows the
  Gatekeeper prompt above and the in-place update afterwards does not.

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

## Not here yet

The following are account-side and cannot be committed until an Apple Developer
Program membership exists:

- `DEVELOPMENT_TEAM` and the signing configuration (the project builds today
  with `CODE_SIGNING_ALLOWED: NO`; the release workflow overrides that on the
  command line to sign *ad hoc*, which needs no team — see
  [Automated releases](#automated-releases)).
- Notarization / stapling for the macOS build. The distribution channel itself is
  no longer absent: GitHub Releases + Sparkle ship today, ad-hoc signed and with
  the documented Gatekeeper friction on a first manual install. What is missing
  is the Developer ID identity that removes that friction, and the workflow marks
  where it plugs in. Note that App Sandbox — which the *Mac* App Store requires — is
  not merely undecided: the macOS build shells out to `git` through `Process`
  (`GitCLIService`) and opens a PTY for the embedded terminal, neither of which
  survives sandboxing. So the macOS channel is Developer ID + notarization unless
  those two features are reworked; the iOS App Store path is unaffected.
  Phase 2b adds a second, **independent** reason the Mac App Store is out: the
  macOS app downloads and executes third-party binaries at the user's request,
  which App Review guideline 2.5.2 forbids outright regardless of sandboxing.
  Nothing in the iOS build does this — the whole layer is behind `#if os(macOS)`.
- The App Store Connect app records, store metadata and screenshots.

None of the repository-side work above depends on a signing team existing;
adding these steps is a separate change to this document.

## Open compliance question: statically linked LGPL

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

Nothing in the repository can resolve that — it is a decision, and the options
are: accept the risk deliberately and in writing; publish an
"object files available on request" offer alongside the store listing; or drop
`deps/xdiff` from the compiled sources and supply the diff implementation
another way (or give libgit2 the same `destinationFilters: [iOS]` treatment
Sparkle gets, which would at least remove the macOS half of the question).

**Decide it before the first `v*` tag is pushed** — not, as this section
previously said, before the first iOS submission. The tag-triggered workflow
publishes a macOS app to GitHub Releases, and that is a distribution to the
public: it starts the clock on the same obligation, and it will almost certainly
happen long before anything reaches App Store Connect. Record the decision here.
