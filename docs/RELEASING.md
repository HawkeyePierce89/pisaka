# Releasing Pisaka

Everything here is repository-side. Signing, notarization and the App Store
Connect record are deliberately absent — see [Not here yet](#not-here-yet).

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

## Check by hand before the first submission

`swift test` and CI cover everything static — the plists, the privacy manifest,
the pins, the license manifest. Two things they structurally cannot cover,
because the view layer is untested by convention:

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

## Not here yet

The following are account-side and cannot be committed until an Apple Developer
Program membership exists:

- `DEVELOPMENT_TEAM` and the signing configuration (the project builds today
  with `CODE_SIGNING_ALLOWED: NO`).
- Notarization / stapling for the macOS build, and the distribution channel that
  precedes it. Note that App Sandbox — which the *Mac* App Store requires — is
  not merely undecided: the macOS build shells out to `git` through `Process`
  (`GitCLIService`) and opens a PTY for the embedded terminal, neither of which
  survives sandboxing. So the macOS channel is Developer ID + notarization unless
  those two features are reworked; the iOS App Store path is unaffected.
- The App Store Connect app records, store metadata and screenshots.

None of the repository-side work above depends on a signing team existing;
adding these steps is a separate change to this document.

## Open compliance question: statically linked LGPL

The iOS build links libgit2, whose SwiftPM target compiles `deps/xdiff`
(LibXDiff, LGPL-2.1-or-later) — see the sub-dependency section of
`docs/architecture/core-services.md`. The shipped
`Resources/Licenses/libgit2.txt` carries that notice, which settles the
*attribution* half.

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
another way. **Decide it before the first iOS submission**, and record the
decision here.
