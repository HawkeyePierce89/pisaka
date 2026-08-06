# GitHub Actions CI: core tests + macOS/iOS builds

## Overview

Add a single GitHub Actions workflow (`.github/workflows/ci.yml`) that reproduces the three manual quality gates on every pull request and push to master: PisakaCore unit tests, macOS build+link, and iOS build+link (device arch, including libgit2 linking). Tests are the first standalone gate; both builds start only when tests are green and run in parallel with each other. The environment (runner image, Xcode, XcodeGen version) is explicitly pinned; the committed lock file anchors a SwiftPM source-package cache so the dependency resolve/clone is skipped on repeat runs; stale runs on the same branch are cancelled. No signing, secrets, simulator, Xcode matrix, or linters.

## Context

- Files involved:
  - Create: `.github/workflows/ci.yml` (the only artifact of this task)
  - Reference (not modified): `project.yml` (XcodeGen; `CODE_SIGNING_ALLOWED: NO` already set), `Package.swift` (SwiftPM builds only PisakaCore + tests, no external deps), `Pisaka.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (committed pin lock file — the cache-key anchor; the `.xcodeproj` is gitignored except this carved-out path, per `.gitignore`)
  - Docs: `README.md`, `CLAUDE.md`
- Known local commands (verified against README/CLAUDE.md and confirmed locally — XcodeGen `2.45.4`):
  - Tests: `swift test`
  - Project generation: `xcodegen generate`
  - macOS: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`
  - iOS (README uses simulator; for CI we use device arch without signing/simulator): `-destination 'generic/platform=iOS'`
- Pins/environment (explicit values, adjustable on review):
  - Runner: `macos-15`
  - Xcode: `maxim-lobanov/setup-xcode@v1` → `16.4` (matches the README-documented "Xcode 16+" minimum)
  - XcodeGen: pinned release `2.45.4` (matches the local version), installed from the GitHub release rather than "latest from brew"
  - Concurrency: `group: ${{ github.workflow }}-${{ github.ref }}`, `cancel-in-progress: ${{ github.event_name == 'pull_request' }}` (namespaced by workflow so this CI never cancels an unrelated future workflow on the same ref — the standard idiom; cancellation is gated to pull requests so a rapid second push to `master` never cancels the earlier commit's run, leaving no mainline commit without a finished CI result)
- Caching decision:
  - Cache **only** the SwiftPM cloned source-packages directory (`-clonedSourcePackagesDirPath SourcePackages`). A cache hit means `xcodebuild -resolvePackageDependencies` finds the checkouts locally and does **not** re-resolve or re-clone from the network — exactly the "resolve doesn't start from scratch" acceptance criterion, and it also avoids re-fetching libgit2's C source.
  - Robustness: key the cache on the **exact committed lock-file path** — `hashFiles('Pisaka.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')` — not a `**/Package.resolved` glob. The glob is fragile: `hashFiles` silently returns an empty string if it matches nothing (collapsing the key to a constant `spm-`, so a moved/renamed lock file would keep restoring a stale cache instead of failing loudly), and after `xcodegen generate` + resolve it can also match a `Package.resolved` that `xcodebuild` writes into `DerivedData`/`SourcePackages`, poisoning the key mid-run. The pinned path is deterministic and tied to the real pin file. `restore-keys: spm-` still gives a near-miss fallback.
  - The two build jobs share **one** cache key (`spm-${{ hashFiles('Pisaka.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved') }}`, `restore-keys: spm-`), not separate `spm-macos-`/`spm-ios-` prefixes: the checked-out source packages are platform-independent (C/Swift *source*, not compiled objects), GitHub's cache is immutable per key so a same-key save from the second job simply no-ops rather than contending, and the first green job warms the cache for the other.
  - Do **not** cache DerivedData. (1) Compiled libgit2 objects live in DerivedData's `Build/`, not in `SourcePackages/` (which holds only checked-out source), so the source-package cache never skips the C *compile* — only the resolve/clone; (2) reusing DerivedData across runs is tied to the exact Xcode/toolchain and carries incremental-build state that can go stale — masking or manufacturing failures and defeating the reproducibility this gate exists to enforce.
  - Consequence, stated explicitly: libgit2's C sources recompile on each build job (clean derived-data path per job). This is the intended trade — a correctness gate builds clean; the source-package cache still removes the network resolve/clone, which is what the acceptance criterion measures.

## Development Approach

- **Testing approach**: Regular. The artifact is a YAML config, not PisakaCore code, so "tests" for each task are static validation (`actionlint`) plus local reproduction of the exact step commands (`swift test`, `xcodegen generate`, `xcodebuild … build`) to guarantee the steps match the commands that actually pass locally. This task adds/changes no PisakaCore unit tests (the CLAUDE.md rule "every behavioral change ships with core tests" does not apply here: no domain code is touched).
- Complete each task fully before the next; the workflow stays valid YAML at every step.
- No secrets/certificates; builds are unsigned.

## Implementation Steps

### Task 1: Workflow skeleton — triggers, concurrency, and the test job

**Files:**
- Create: `.github/workflows/ci.yml`

- [x] Declare `name`, triggers `on: pull_request` and `on: push` with `branches: [master]`
- [x] Add a `concurrency` block (`group: ${{ github.workflow }}-${{ github.ref }}`, `cancel-in-progress: true`) to cancel stale runs on the same branch
- [x] `test` job on `runs-on: macos-15`: `actions/checkout@v4` → `maxim-lobanov/setup-xcode@v1` (`xcode-version: '16.4'`) → `swift test` (PisakaCore is dependency-free, so no XcodeGen and no package cache are needed here)
- [x] Job validation: run `actionlint .github/workflows/ci.yml` (install if absent); run `swift test` locally and confirm the step command matches and passes

### Task 2: macOS build job with SwiftPM source-package cache

**Files:**
- Modify: `.github/workflows/ci.yml`

- [x] `build-macos` job with `needs: test` (starts only when tests are green), `runs-on: macos-15`
- [x] Steps: checkout → setup-xcode `16.4` → install pinned XcodeGen `2.45.4` from its release
- [x] `actions/cache@v4` for the cloned SwiftPM packages dir **only** (`SourcePackages`), key `spm-${{ hashFiles('Pisaka.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved') }}`, `restore-keys: spm-`. No DerivedData in the cache.
- [x] `xcodegen generate`
- [x] Explicit pre-resolve step: `xcodebuild -resolvePackageDependencies -clonedSourcePackagesDirPath SourcePackages` (a cache hit is satisfied here, so it skips the network resolve/clone; broken out as its own step so the cache-hit behaviour is legible in the run log rather than folded into the build line)
- [x] Build: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -clonedSourcePackagesDirPath SourcePackages -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build` (fresh `DerivedData` path keeps the build clean)
- [x] Job validation: `actionlint`; locally `xcodegen generate` + `xcodebuild … -destination 'platform=macOS' build` pass with the same flags

### Task 3: iOS build job (device arch, libgit2 linking)

**Files:**
- Modify: `.github/workflows/ci.yml`

- [x] `build-ios` job with `needs: test`, `runs-on: macos-15` (parallel to `build-macos`)
- [x] Same checkout/setup-xcode/XcodeGen/`actions/cache@v4` (`SourcePackages`, shared `spm-` key on the exact committed lock-file path)/`xcodegen generate`/pre-resolve steps as the macOS job
- [x] Build for device arch without signing/simulator: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' -clonedSourcePackagesDirPath SourcePackages -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` (covers UIKit-layer compilation and libgit2 linking; libgit2's C sources compile fresh into `DerivedData`, which is intended)
- [x] Job validation: `actionlint`; locally `xcodebuild … -destination 'generic/platform=iOS' build` passes

### Task 4: Final workflow validation and acceptance criteria

**Files:**
- Modify: `.github/workflows/ci.yml` (if fixes are needed)

- [x] Run `actionlint` over the whole file — 0 errors
- [x] Statically check the job graph: three independent checks in a PR, both builds `needs: test` (builds don't start when tests fail), builds have no mutual dependency (parallel)
- [x] Verify there are no secrets/`secrets.*`/signing steps in the file
- [x] Verify the cache is keyed on the exact committed `Package.resolved` path (not a `**` glob) and scoped to the cloned source-packages dir only (no DerivedData), so a repeat run skips the resolve/clone while every build stays clean

### Task 5: Update documentation

**Files:**
- Modify: `README.md`, `CLAUDE.md`

- [x] README: a short note that GitHub Actions CI runs `swift test` + macOS/iOS builds on every PR and push to master (unsigned)
- [x] CLAUDE.md: one line about the CI gate and its composition in the Build/Commands section
- [x] Ensure the docs don't contradict the workflow's actual triggers/commands

## Post-Completion (verified by the user in GitHub, outside agent automation)

- Open a test PR: three independent statuses appear in the checks; builds don't start when tests fail.
- Clean run: tests and both builds are green.
- Repeat run of the same branch: logs show a SwiftPM cache hit (resolve/clone doesn't start from scratch); the stale run is cancelled.
- The pipeline requires no secrets/certificates.
