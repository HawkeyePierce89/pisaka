# App Store release preparation (repository-side)

## Overview

Bring the repository to distribution readiness for everything that lives in the
codebase: an exact pin for the one branch-tracked dependency, release versioning
with a documented per-upload build-number override, the two Info.plist keys App
Store Connect validation requires, a truthful `PrivacyInfo.xcprivacy`, and
third-party license compliance with an Acknowledgements screen on both
platforms. All account-side work (Developer Program enrollment, App Store
Connect records, `DEVELOPMENT_TEAM`, signing, notarization, the macOS
distribution-channel/sandbox decision, store metadata) is out of scope; nothing
here may depend on a signing team existing.

## Context

Files involved:

- `project.yml` — package pins, target build settings, resource declarations
- `Pisaka.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` —
  committed pins (v2 schema)
- `.github/workflows/ci.yml` — the three gates (swift test, macOS build,
  generic/platform=iOS build)
- `Sources/Pisaka/SettingsView.swift` — macOS Preferences form (`Settings` scene
  in `PisakaApp.swift:453`)
- `Sources/Pisaka/iOS/SettingsView_iOS.swift` — iOS Preferences sheet (`Form`
  inside a `NavigationStack`)
- `Vendor/TreeSitterGitignore/`, `Vendor/TreeSitterDotenv/` — vendored grammars,
  each with `LICENSE` + `VENDORED.md`
- `Tests/PisakaCoreTests/VendoredGrammarQueryTests.swift` — the precedent for
  Foundation-only tests that read repository files through `#filePath`
- New: `Resources/Info.plist`, `Resources/PrivacyInfo.xcprivacy`,
  `Resources/Licenses/`, `docs/RELEASING.md`,
  `Sources/PisakaCore/LicenseNotice.swift`,
  `Sources/Pisaka/Platform/LicenseCatalogLoader.swift`,
  `Sources/Pisaka/AcknowledgementsView.swift`,
  `Sources/Pisaka/iOS/AcknowledgementsView_iOS.swift`

Related patterns:

- Pure decision logic in `PisakaCore` (Foundation-only, unit-tested); views thin
  and untested.
- Static repository-file verification in the Core test target via `#filePath`
  (`VendoredGrammarQueryTests`) — reused here to keep the license list, the pins
  and the manifests honest.
- `Sources/Pisaka/Platform/` holds the non-gated shim layer shared by both
  platforms.
- `project.yml` carries a prose comment explaining *why* each pin is what it is.

Findings from the exploration that the plan builds on:

- `SwiftTreeSitter` is the only `branch: main` package; `Package.resolved`
  already records revision `0f40435cdb41673ce4194d731571cf2a2f7c3285` for it.
  The grammars require it as `from: "0.8.0"`, which a root revision pin
  overrides the same way the current branch pin does.
- Required-reason API audit (greps over `Sources/`): **UserDefaults**
  (`SettingsStore`, `BookmarkStore`, `SessionStore`) and **file timestamp APIs**
  (`lstat`/`stat` in `GitCLIService.swift:627,787,1186` and
  `LibGit2Service.swift:914`) are used. No hits for system boot time, disk
  space, or active keyboard APIs — `FileService`'s `.fileSizeKey` is not in
  Apple's disk-space list. So exactly two categories get declared:
  `NSPrivacyAccessedAPICategoryUserDefaults` = `CA92.1` and
  `NSPrivacyAccessedAPICategoryFileTimestamp` = `3B52.1` (timestamps of files
  and directories the user specifically granted access to, via the open panel /
  document picker). `3B52.1`, not `DDA9.1`: the app never *displays* file
  timestamps to the user — the blame column's dates come from git's own output,
  not from `stat`.
- 18 license texts ship: 15 remote packages (Neon, SwiftTreeSitter, Rearrange,
  SwiftTerm, libgit2, and the 10 remote grammars), the transitive `tree-sitter`
  C runtime that `SwiftTreeSitter` links, and the 2 vendored grammars.
  `swift-argument-parser` appears in `Package.resolved` only because the
  `tree-sitter` package's CLI target needs it — it is not linked into the app,
  so it is an explicitly documented exclusion rather than a silent one.
- Every license text is already on disk at the pinned revision:
  `DerivedData/SourcePackages/checkouts/<pkg>/{LICENSE,COPYING}` (checkout HEADs
  match `Package.resolved`), and `Vendor/*/LICENSE` for the vendored two.
  `libgit2/COPYING` contains the GPLv2 text *and* the LINKING EXCEPTION section.
  No network fetch is needed.

Dependencies: XcodeGen 2.45.4, Xcode 16.4 (as CI pins them). No new SwiftPM
dependencies.

## Development Approach

- **Testing approach**: Regular (code first, then tests), matching the repo's
  existing style.
- Complete each task fully before moving to the next.
- Every behavioral or data change is guarded by a `PisakaCore` test; the Core
  target and its tests stay Foundation-only and must not import
  Neon/SwiftTreeSitter/SwiftTerm/libgit2/AppKit/UIKit.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting the next task**
- Build gates (`xcodegen generate`, both `xcodebuild` invocations) are run in the
  verification task; `swift test` runs at the end of every task.

## Implementation Steps

### Task 1: Pin SwiftTreeSitter to an exact revision

**Files:**
- Modify: `project.yml`
- Modify: `Pisaka.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
  (only if the resolve rewrites the pin shape)
- Create: `Tests/PisakaCoreTests/DependencyPinTests.swift`

**Finding (invalidates the planned edit):** the root cannot pin SwiftTreeSitter
by revision. The pinned Neon revision `484d6fb` — 119 commits past Neon's newest
tag `0.6.0`, and no Neon tag carries the API the app uses — declares
`.package(url: …/SwiftTreeSitter, branch: "main")` in its own manifest. SwiftPM
refuses a package "required using two different revision-based requirements", so
a root `revision:` makes `xcodebuild -resolvePackageDependencies` fail outright
(verified); an `exactVersion:` fails the same way (version vs. revision
requirement). Removing the branch requirement means moving the *Neon* pin to a
tag whose manifest asks for SwiftTreeSitter by version — a dependency downgrade
with real API risk, deliberately out of this task's scope. The requirement
therefore stays `branch: main` and the pin stays where SwiftPM honours it: the
committed `Package.resolved` revision, now enforced by test.

- [x] keep `SwiftTreeSitter`'s `branch: main` (SwiftPM leaves no alternative, per
  the finding above) and add a comment in the existing `project.yml`
  pinning-comment style recording the exact constraint, the resolve error it
  produces, the revision the committed `Package.resolved` holds
  (`0f40435…`, 3 commits past tag `0.10.0` — the revision that has been building
  and testing all along), and what it would take to remove the branch
  requirement
- [x] run `xcodegen generate` and
  `xcodebuild -project Pisaka.xcodeproj -resolvePackageDependencies`; both
  succeed and `Package.resolved` is byte-for-byte unchanged — resolution reused
  the committed pin (`SwiftTreeSitter … @ main (0f40435)`) instead of fetching a
  newer `main`, which is the reproducibility guarantee the exact pin was meant to
  provide
- [x] write `DependencyPinTests`: read the committed `Package.resolved` through
  `#filePath` with `JSONSerialization` and assert (a) `version == 2` with
  `identity`/`kind`/`location` per pin, (b) every pin's `state` has a non-empty
  40-char lowercase-hex `revision`, (c) `swifttreesitter` is the *only* pin
  carrying a `branch` key (a second one means another dependency silently stopped
  being reproducible), (d) the `swifttreesitter` pin's revision is exactly
  `0f40435cdb41673ce4194d731571cf2a2f7c3285`, so an unnoticed drift to a newer
  `main` fails the suite
- [x] run `swift test` — 1559 tests, 0 failures (4 new)

### Task 2: Release version, build-number override, and the two Info.plist keys

**Files:**
- Modify: `project.yml`
- Create: `Resources/Info.plist`
- Create: `docs/RELEASING.md`
- Create: `Tests/PisakaCoreTests/ReleaseMetadataTests.swift`

- [x] set `MARKETING_VERSION: "1.0"`; keep `CURRENT_PROJECT_VERSION: "1"`
  numeric, with a comment pointing at `docs/RELEASING.md` for the per-upload
  override
- [x] add `Resources/Info.plist` as a *partial* plist carrying only
  `LSApplicationCategoryType` = `public.app-category.developer-tools` (string)
  and `ITSAppUsesNonExemptEncryption` = `<false/>` (real Boolean — the app's only
  cryptography is HTTPS/TLS via Apple frameworks and libgit2's Apple TLS backend,
  the standard exemption), and point `INFOPLIST_FILE: Resources/Info.plist` at it
  while keeping `GENERATE_INFOPLIST_FILE: YES`, so Xcode merges its generated
  per-destination keys into this file's contents and the existing
  `INFOPLIST_KEY_*` settings keep working; comment this arrangement in
  `project.yml`. If the built plist (verified in Task 8) turns out to lack either
  the generated or the custom keys, fall back to
  `INFOPLIST_KEY_LSApplicationCategoryType` /
  `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption` build settings and re-verify the
  value types — *not needed*: an early macOS build confirms the merge, the built
  `Contents/Info.plist` carrying `LSApplicationCategoryType`, a Boolean
  `ITSAppUsesNonExemptEncryption = false`, *and* the generated keys
  (`CFBundleName`, `CFBundleShortVersionString = 1.0`,
  `LSSupportsOpeningDocumentsInPlace`); Task 8 re-verifies on both destinations
- [x] write `docs/RELEASING.md`: the release version lives in `project.yml`;
  every App Store Connect upload must carry a build number never seen before, so
  uploads pass `CURRENT_PROJECT_VERSION=<n>` on the `xcodebuild archive` command
  line (a command-line setting override beats the project value and leaves the
  working tree clean); record the monotonic-integer rule, an example command, and
  a note that signing/notarization steps are deliberately absent until the
  developer account exists
- [x] extend the `Resources/Info.plist` half into `ReleaseMetadataTests`: read
  the partial plist through `#filePath` with `PropertyListSerialization` and
  assert the category string equals `public.app-category.developer-tools` and
  that `ITSAppUsesNonExemptEncryption` is present and is a `Bool` equal to
  `false` (not the string "NO") — the Boolean check goes through
  `CFBooleanGetTypeID`, since a string `"NO"` also survives `as? Bool` bridging;
  a third test pins the key set to those two, keeping generatable keys out
- [x] run `swift test` — 1562 tests, 0 failures (3 new)

### Task 3: Privacy manifest

**Files:**
- Create: `Resources/PrivacyInfo.xcprivacy`
- Modify: `project.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseMetadataTests.swift`

- [x] re-run the required-reason audit greps over `Sources/` (UserDefaults;
  `lstat`/`stat`/`getattrlist`/`creationDate`/`modificationDate`/`attributesOfItem`;
  `systemUptime`/`mach_absolute_time`/`sysctl`;
  `statfs`/`volumeAvailableCapacity`; `activeInputModes`) and record the result
  as a comment block at the top of `PrivacyInfo.xcprivacy`'s architecture doc
  entry, so a future audit can be diffed against this one; the record must state
  the reason-code choice explicitly — the file-timestamp probes are `3B52.1`
  (files and directories the user specifically granted access to via the open
  panel / document picker), *not* `DDA9.1`, because the app never displays file
  timestamps to the user (blame dates come from git's output, not from `stat`)
  — re-run and unchanged: UserDefaults in `SettingsStore`/`BookmarkStore`/
  `SessionStore` (+ the `SessionController` writer); file timestamps at exactly
  four `lstat`-into-`stat` sites (`GitCLIService.swift:627,787,1186`,
  `LibGit2Service.swift:914`, the rest of the `lstat` hits being comment prose);
  **no hits at all** for boot time, disk space or active keyboard.
  `FileService`'s `.fileSizeKey`/`.isDirectoryKey`/`.fileResourceIdentifierKey`
  and `GitCLIService`'s `.volumeSupportsCaseSensitiveNamesKey` are not
  required-reason APIs. Recorded as the "Release-metadata resources" section of
  `docs/architecture/core-services.md`, `3B52.1`-not-`DDA9.1` reasoning included
- [x] write `Resources/PrivacyInfo.xcprivacy`: `NSPrivacyTracking` = false,
  `NSPrivacyTrackingDomains` = empty, `NSPrivacyCollectedDataTypes` = empty (the
  app has no network telemetry and stores everything locally), and
  `NSPrivacyAccessedAPITypes` with exactly two entries —
  `NSPrivacyAccessedAPICategoryUserDefaults` / `["CA92.1"]` and
  `NSPrivacyAccessedAPICategoryFileTimestamp` / `["3B52.1"]`
- [x] declare it as a target resource in `project.yml` so it lands at the top
  level of the built bundle's resources on both destinations
  (`Contents/Resources/` on macOS, the `.app` root on iOS); keep it out of the
  recursive `Sources/Pisaka` source entry so it is added exactly once — declared
  as a single-file `buildPhase: resources` entry (a plain file reference, not a
  folder reference), naming the *file* rather than `Resources/`, which also keeps
  the partial `Info.plist` out of the resources phase where it would be copied a
  second time beside Xcode's merged one. `xcodegen generate` puts it in the
  Resources phase exactly once and an early macOS build confirms it lands at
  `Pisaka.app/Contents/Resources/PrivacyInfo.xcprivacy` with all four keys
  intact; Task 8 re-verifies on both destinations
- [x] extend `ReleaseMetadataTests` to read `PrivacyInfo.xcprivacy` through
  `#filePath` and assert tracking is false, both collected-data and
  tracking-domain arrays are empty, and the accessed-API set is exactly the two
  category/reason pairs above — `UserDefaults`/`CA92.1` and
  `FileTimestamp`/`3B52.1`, set equality, so an added, dropped or re-coded
  category fails until the manifest and the audit are reconciled
- [x] run `swift test` — 1564 tests, 0 failures (2 new)

### Task 4: Collect license texts and the manifest resource

**Files:**
- Create: `Resources/Licenses/licenses.json`
- Create: `Resources/Licenses/<identity>.txt` (18 files)
- Modify: `project.yml`

- [ ] for each of the 15 remote packages, verify
  `git -C DerivedData/SourcePackages/checkouts/<pkg> rev-parse HEAD` equals that
  package's `Package.resolved` revision, then copy its `LICENSE`/`COPYING`
  verbatim (bytes unchanged, copyright lines intact) to
  `Resources/Licenses/<identity>.txt`; do the same for the transitive
  `tree-sitter` C runtime, and copy `Vendor/TreeSitterGitignore/LICENSE` and
  `Vendor/TreeSitterDotenv/LICENSE` for the two vendored grammars
- [ ] confirm `libgit2.txt` contains both the GPLv2 text and the
  `LINKING EXCEPTION` section (it is what permits linking into a closed-source
  app)
- [ ] write `Resources/Licenses/licenses.json`: an ordered array of entries
  `{ id, name, origin (url or Vendor path), version, revision, spdx, file }`, one
  per shipped dependency, plus a top-level `excluded` array recording
  `swift-argument-parser` with the reason "resolved only for the tree-sitter
  package's CLI target; not linked into the app"
- [ ] declare `Resources/Licenses` in `project.yml` as a folder-reference
  resource so the directory is copied into the bundle as `Licenses/` and adding a
  future `.txt` needs no project regeneration
- [ ] run `swift test` — must pass before Task 5 (the manifest's own tests land
  in Task 5)

### Task 5: `LicenseCatalog` in Core, plus coverage tests

**Files:**
- Create: `Sources/PisakaCore/LicenseNotice.swift`
- Create: `Tests/PisakaCoreTests/LicenseNoticeTests.swift`
- Create: `Tests/PisakaCoreTests/LicenseCoverageTests.swift`

- [ ] add `LicenseNotice` (a `Codable`, `Identifiable` value type: id, name,
  origin, version, revision, spdx, file) and `LicenseCatalog` with a pure
  `decode(manifest:)` plus a `resolve(manifest:texts:)` that pairs each notice
  with its text and throws a typed `LicenseCatalogError` on a missing entry, an
  empty text, a duplicate id, or an empty manifest — Foundation only, no
  `Bundle`, so the app layer supplies the bytes
- [ ] write `LicenseNoticeTests` against in-memory fixtures: decoding a
  well-formed manifest, ordering preserved, and each error case (missing text,
  empty text, duplicate id, malformed JSON, empty manifest)
- [ ] write `LicenseCoverageTests` — the "cannot be silently missing" guard, in
  the `VendoredGrammarQueryTests` style, reading repository files through
  `#filePath`: parse `project.yml`'s `packages:` block and the `Pisaka` target's
  `dependencies:` list, drop `PisakaCore`, and assert the manifest's id set
  equals that linked set plus the documented transitive `tree-sitter` entry (set
  equality, so a new dependency fails the suite until its license is added);
  assert every entry's `file` exists under `Resources/Licenses` and is non-empty;
  assert each remote entry's `revision` equals the `Package.resolved` pin for
  that identity (lowercased package key), so a text can never be taken from
  upstream HEAD; assert the two vendored entries name a real
  `Vendor/<name>/LICENSE` source; assert `libgit2`'s text contains
  `LINKING EXCEPTION`
- [ ] run `swift test` — must pass before Task 6

### Task 6: Acknowledgements UI on both platforms

**Files:**
- Create: `Sources/Pisaka/Platform/LicenseCatalogLoader.swift`
- Create: `Sources/Pisaka/AcknowledgementsView.swift`
- Create: `Sources/Pisaka/iOS/AcknowledgementsView_iOS.swift`
- Modify: `Sources/Pisaka/SettingsView.swift`
- Modify: `Sources/Pisaka/iOS/SettingsView_iOS.swift`

- [ ] add `LicenseCatalogLoader` in the non-gated `Platform/` layer: reads
  `Licenses/licenses.json` and the text files from `Bundle.main` once (lazily
  cached) and hands the bytes to `LicenseCatalog`, exposing the resolved notices
  or a single user-facing failure string — thin glue only, all decisions stay in
  Core
- [ ] macOS: turn the `Settings` scene's `SettingsView` into a `TabView` with a
  "General" tab (today's form, keeping its 340pt width) and an
  "Acknowledgements" tab hosting `AcknowledgementsView` — a list of dependencies
  beside a scrollable, selectable, monospaced license text, sized for reading
  (≈640×420)
- [ ] iOS: add an "About" section to `SettingsView_iOS` with a `NavigationLink`
  (the `Form` already sits in a `NavigationStack`) to
  `AcknowledgementsView_iOS` — a `List` of dependencies pushing a detail screen
  with the full text
- [ ] both screens show name, SPDX identifier, version/revision and origin per
  entry, and the full verbatim text; no truncation
- [ ] no new Core logic is introduced here, so this task adds no tests; re-run
  `swift test` to confirm nothing regressed before Task 7

### Task 7: Documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/architecture/core-services.md`, `docs/architecture/app-shell.md`,
  `docs/architecture/app-ios.md`
- Modify: `README.md`
- Modify: `project.yml` (comments only, if anything is still unexplained)

- [ ] `CLAUDE.md`: one-line index entries only — `LicenseNotice.swift` under
  core-services, `AcknowledgementsView.swift` under app-shell,
  `LicenseCatalogLoader.swift` + `AcknowledgementsView_iOS.swift` under app-ios,
  plus a one-line pointer to `docs/RELEASING.md`; note the release-metadata
  resources (`Resources/`) in the build/project-layout section without growing it
  into an essay
- [ ] `docs/architecture/core-services.md`: the full
  `LicenseNotice`/`LicenseCatalog` contract, why the catalog takes bytes rather
  than a `Bundle`, the coverage-test invariant (set equality against
  `project.yml`, revision equality against `Package.resolved`), and the
  documented `swift-argument-parser` exclusion
- [ ] `docs/architecture/app-shell.md` and `app-ios.md`: the Acknowledgements
  entry points (macOS Preferences tab, iOS About → push) and the loader's
  one-shot caching
- [ ] record the privacy-manifest audit (which greps were run, what they found,
  what is deliberately absent, and the `3B52.1`-not-`DDA9.1` reasoning) in
  `core-services.md` beside the release-metadata notes, so the next audit is a
  diff rather than a rediscovery
- [ ] `README.md`: mention the Acknowledgements screen in the user-facing feature
  list
- [ ] run `swift test` — must pass before Task 8

### Task 8: Verify acceptance criteria

- [ ] `swift test` — full suite green
- [ ] `xcodegen generate` succeeds and produces no unexpected `Package.resolved`
  churn (still v2 schema, no `branch` key anywhere)
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`
  succeeds
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`
  succeeds
- [ ] `plutil -p` the built macOS `Pisaka.app/Contents/Info.plist` and the built
  iOS `Pisaka.app/Info.plist`: both carry `LSApplicationCategoryType =
  public.app-category.developer-tools` and a Boolean
  `ITSAppUsesNonExemptEncryption = false`, *and* still carry the Xcode-generated
  keys (`CFBundleName`, `CFBundleShortVersionString` = `1.0`,
  `LSSupportsOpeningDocumentsInPlace`, the per-destination scene/principal-class
  keys); if not, apply the Task 2 fallback and re-verify
- [ ] both built bundles contain `PrivacyInfo.xcprivacy` at the top level of
  their resources and a `Licenses/` directory holding `licenses.json` plus all 18
  `.txt` files
- [ ] confirm `CURRENT_PROJECT_VERSION=<n>` on the `xcodebuild` command line
  overrides the project value in the built plist (`CFBundleVersion`), matching
  what `docs/RELEASING.md` promises

## Post-Completion (manual, outside the agent's scope)

- Visually check the Acknowledgements screen on a running macOS build and an iOS
  simulator (text is readable, selectable, and not truncated).
- Re-run the license collection whenever a dependency pin moves —
  `LicenseCoverageTests` will fail until it is done.
