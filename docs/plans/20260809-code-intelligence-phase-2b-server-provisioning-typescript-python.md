# Code intelligence, phase 2b: server provisioning, TypeScript/JavaScript and Python

## Overview

Teach the app to provision language servers itself: a pinned manifest of downloadable
components, an offline-testable install engine in `PisakaCore` behind download/unpack
seams, per-server consent persisted in `SettingsStore`, a minimal Settings surface, and
dynamic registration into 2a's `LSPServerRegistry` so `typescript-language-server` (TS/JS)
and `pyright` (Python) become live `.executable(path:)` entries the moment they install —
no restart, no bundling, no global state, no `$PATH`.

Everything decision-shaped lives in Core (Foundation only); the network, `tar` and the
Preferences UI are macOS-gated app code. Swift's `xcrun`-found sourcekit-lsp path is
untouched, iOS is untouched, and every 2a fallback rule stands: a language whose server is
absent, declined or failed answers from tree-sitter, silently.

### The pins (resolved during planning; no network needed to write the code)

One shared Node runtime plus one component per server. Each component is a directory of
verified artifacts — that is what makes the tenth language one manifest record.

| component | version | artifacts (sha256, download bytes) |
|---|---|---|
| `node` | 24.19.0 | `node-v24.19.0-darwin-arm64.tar.gz` `8294b7aa9b03997481c06babf1e8b270c859358f27da57a11509afe537ac381d` 52 234 372 · `node-v24.19.0-darwin-x64.tar.gz` `d1b5e999db158c62fe8f7267a4476b035d8bd93b1a605bac24a3f0dd166e3316` 53 439 583 |
| `typescript-language-server` | 5.3.0 | `typescript-language-server-5.3.0.tgz` `398cacc17fff2108652e7b4050e3182008d17063246b3fea7dcf5fae2ce1560e` 501 633 · `typescript-5.9.3.tgz` `10e108c9cf7d5f2879053dff18515fb405abf2ccef63eaaf017d9c571687a1d3` 4 377 468 |
| `pyright` | 1.1.411 | `pyright-1.1.411.tgz` `bd5c488fc20fa237a944279bf32cae2f986cf10d5d5d9e8705819859daeb2f4a` 4 139 958 · `fsevents-2.3.3.tgz` `c77e7a5d5ff31dd7acea7c44d4a0455e0528cdacbd24a8cb6c82b66d239b587e` 22 808 |

Sources are official only: `nodejs.org/dist` (checksums verified against the release's own
`SHASUMS256.txt`) and `registry.npmjs.org` tarball URLs.

Two facts that shaped this and are worth stating up front, both verified against the
registry while planning: `typescript-language-server@5.3.0` has **no runtime dependencies**
(it ships one bundled `lib/cli.mjs`), and `pyright@1.1.411` has exactly one, `fsevents`,
which is optional. So there is no transitive npm closure to resolve, no lockfile, and no
`npm` — the manifest is six artifacts, each pinned by its own SHA-256.

### Decisions this plan makes (to be recorded as D11–D16)

- **D11 — How `typescript-language-server` finds `typescript`.** As a second artifact of
  the same component, unpacked beside it:
  `.../typescript-language-server/5.3.0/node_modules/{typescript-language-server,typescript}`.
  Node's own resolution finds it by walking up from `cli.mjs`, and the registry entry
  additionally passes `initializationOptions = {"tsserver": {"path":
  "<…>/node_modules/typescript/lib/tsserver.js"}}` so the lookup never depends on the walk.
  A project with its own `node_modules/typescript` still wins — the server prefers the
  workspace copy, which is the behavior people expect. `typescript` is pinned at **5.9.3**,
  not the `latest` 7.x: 7.0 is the native rewrite and no longer ships the `lib/tsserver.js`
  this server drives.
- **D12 — Component = version directory of verified artifacts; state is the file system.**
  `<Application Support>/Pisaka/LanguageServers/<component>/<version>/…`. Installed/absent
  is a directory listing; installing is the engine's in-flight table. No database.
- **D13 — Atomicity is one rename.** Download → SHA-256 → unpack, all into
  `…/LanguageServers/.staging/<component>-<version>-<n>/`, then a single `move` onto the
  version directory; the previous version is deleted only afterwards. Any failure removes
  the staging tree and leaves the old install (or nothing) exactly as it was. Leftover
  staging from a crash is swept at launch.
- **D14 — The seams carry bytes, not files.** `LSPArtifactDownloading` answers `Data` for a
  URL; `LSPArchiveUnpacking` takes that `Data`, a destination and a strip depth. Core never
  reads or writes archive bytes, so `swift test` needs neither network nor `tar`; the peak
  ~53 MB resident during a Node download is the stated cost, recorded as a known limit.
- **D15 — Consent is per server, sized, and sticky.** `SettingsStore` persists
  `unasked/accepted/declined` per server id. Accepting installs the server *and* its missing
  runtime; declining keeps the language on tree-sitter across launches. The prompt is a
  non-modal banner above the editor with two actions and no dismiss — "asked once" means
  the answer is one of the two.
- **D16 — Registration is dynamic, and removal terminates.** `LSPWorkspace` gains
  `updateRegistry(_:)`: it swaps the registry, and shuts down every session whose
  description vanished or changed, forgetting its documents and clearing its D7 failure
  count. `canServe` therefore flips both ways without a restart, and
  `RoutingIntelligenceProvider` is untouched.

## Context

- Files involved (Core, new): `SHA256.swift`, `LSPProvisioningManifest.swift`,
  `LSPInstallLayout.swift`, `LSPInstallEngine.swift`, `LSPProvisioning.swift`.
- Files involved (Core, modified): `SettingsStore.swift`, `LSPWorkspace.swift`.
- Files involved (app, new, macOS-gated): `LSPDownloadService.swift`,
  `LSPArchiveUnpacker.swift`, `LSPServerSettingsView.swift`, `LSPConsentBanner.swift`,
  `LSPInstalledLicenses.swift`.
- Files involved (app, modified): `PisakaApp.swift`, `ContentView.swift`,
  `SettingsView.swift`, `AcknowledgementsView.swift`.
- Related patterns: 2a's `LSPTransport`/`LSPProcessTransport` seam split;
  `LSPServerDescription`/`LSPServerRegistry` (D9); `LSPToolchain.resolution` already answers
  `.executable(path:)` from a `stat`, and `LSPProcessTransport.make` already passes
  `description.arguments` — neither needs a change; `FileServicing`/`StubFileTree` for the
  file system; `ScriptedLSPTransport` for scripted fakes; `DependencyPinTests` for
  data-validation-by-test; `LSPSourceGatingTests` for the platform split.
- Dependencies: none new. `project.yml`, `Package.resolved`, `licenses.json` and every pin
  stay untouched.
- Note on the environment: the checksums above are already resolved, so implementation
  needs no network. The manual checks at the end do.

## Development Approach

- **Testing approach**: TDD where the rules are the deliverable (SHA-256, the install
  engine, the manifest, consent, `updateRegistry`); regular for the SwiftUI surfaces, which
  stay thin and untested by convention.
- Complete each task fully — code, tests, green suite — before the next.
- Core stays Foundation-only: no `Process`, no `CryptoKit`, no `URLSession` download, no
  AppKit. New `LSP*`-prefixed Core files are swept by `LSPSourceGatingTests`, which enforces
  exactly that; new app files carry `#if os(macOS)` from the first line.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**

## Implementation Steps

### Task 1: SHA-256 in Core

Checksum verification is the load-bearing part of the install engine and `CryptoKit` is not
allowed in Core, so this is a small, self-contained, Foundation-only digest with published
vectors behind it.

**Files:**
- Create: `Sources/PisakaCore/SHA256.swift`
- Create: `Tests/PisakaCoreTests/SHA256Tests.swift`

- [x] implement FIPS 180-4 SHA-256 over `Data` with a lowercase-hex convenience and a
      streaming-friendly `update`/`finalize` shape (the engine hashes one `Data`, but the
      incremental form is what keeps it honest and cheap to test)
- [x] tests against the published vectors: empty input, `"abc"`, the 448-bit message, the
      1 000 000 × `"a"` message, plus a multi-chunk `update` sequence that must equal the
      one-shot digest and a length-boundary sweep around 55/56/63/64/65 bytes
- [x] run `swift test` — must pass before task 2

### Task 2: The provisioning manifest and the install layout

The static description of what may be downloaded, and the pure path math over the install
root. Both are data/decision shaped, so both are pinned by tests in the `DependencyPinTests`
mould.

**Files:**
- Create: `Sources/PisakaCore/LSPProvisioningManifest.swift`
- Create: `Sources/PisakaCore/LSPInstallLayout.swift`
- Create: `Tests/PisakaCoreTests/LSPProvisioningManifestTests.swift`
- Create: `Tests/PisakaCoreTests/LSPInstallLayoutTests.swift`

- [x] model `LSPHostArchitecture` (`arm64`/`x64`), `LSPArtifact` (url, sha256,
      `byteCount`, `unpackedByteCount`, format, `stripComponents`, destination subpath,
      optional architecture), `LSPComponent` (id, version, SPDX license id, license file
      subpaths, artifacts, required component ids) and `LSPProvisioningManifest` with the
      `.standard` value carrying the three pinned components from the table above
- [x] model `LSPDownloadableServer` (`typescript`, `python`): display name, served
      languages, server component, runtime component, and the `LSPServerDescription`
      factory that turns an install root into a live registry entry — node binary as the
      executable, the server's entry `.mjs`/`.js` plus `--stdio` as arguments, D11's
      `tsserver.path` as `initializationOptions` for the TypeScript one
- [x] implement `LSPInstallLayout`: base → component dir, version dir, staging root and
      staging dir, artifact destination, plus the per-server executable/entry paths; a pure
      value type over a base `URL` with no file system access
- [x] manifest tests: every URL is absolute HTTPS on an allowed host; every checksum is 64
      lowercase hex characters; sizes are positive; `node` covers both architectures and the
      npm artifacts none; every `requires` id and every downloadable server's component
      resolve inside the manifest; component ids and artifact destinations are unique; the
      served-language sets are disjoint and none of them is `.swift`
- [x] layout tests: paths compose as documented, are contained in the base, and a
      component/version/token round-trips into a distinct staging directory
- [x] run `swift test` — must pass before task 3

### Task 3: The install engine

The whole of D12–D14: seams, atomicity, checksum rejection, no-op reinstall, version-bump
replacement, coalescing, and state derived from the file system.

**Files:**
- Create: `Sources/PisakaCore/LSPInstallEngine.swift`
- Create: `Tests/PisakaCoreTests/Support/ScriptedInstallSeams.swift`
- Create: `Tests/PisakaCoreTests/LSPInstallEngineTests.swift`
- Modify: `Tests/PisakaCoreTests/Support/StubFileTree.swift` (as needed for
  nested-directory listing and for the fake unpacker to materialise entries into it)

- [x] define `LSPArtifactDownloading` (`Data` for a `URL`, `async throws`) and
      `LSPArchiveUnpacking` (`Data` + destination + strip depth, `async throws`), and the
      typed `LSPInstallError` (`checksumMismatch`, `downloadFailed`, `unpackFailed`,
      `unsupportedArchitecture`, `fileSystemFailed`) with user-facing descriptions in
      `GitError`'s voice
- [x] implement `@MainActor LSPInstallEngine` over manifest + layout + `FileServicing` +
      the two seams + a host architecture: `state(of:)` (`absent` / `installing` /
      `installed(version)`, read from the version directories plus the in-flight table),
      `install(_:)` with per-component coalescing and requirement-first ordering,
      `remove(_:)`, and `sweepStaging()`
- [x] the install sequence exactly as D13 states it — verify before unpack, one `move`
      onto the version directory, old versions deleted only after, staging removed on every
      failure path, and a mismatch reported without retrying
- [x] scripted fakes: a downloader answering canned bytes (or an error, or blocking on a
      `Gate`) per URL and counting calls, and an unpacker that writes a canned tree into the
      `StubFileTree` (or fails on demand)
- [x] engine tests: no-op reinstall performs zero downloads; checksum mismatch leaves
      nothing behind and does not re-download; failure injected at download, checksum,
      unpack and move each leaves the previous install byte-for-byte or leaves nothing; a
      version bump installs beside and then removes the old version, and a failed bump keeps
      the old one servable; two concurrent `install` calls for one component perform one
      download and both see the same result; `state(of:)` reports `installing` between the
      two; `sweepStaging()` removes a leftover staging tree and nothing else; requirement
      ordering installs the runtime first and a runtime failure aborts the server install
- [x] run `swift test` — must pass before task 4

### Task 4: Dynamic registration in `LSPWorkspace`

2a's registry is a `let` fixed at construction. Making registration dynamic is the one
change this phase makes to the 2a machinery, and it must terminate what it un-registers —
a removed server whose process is still running is the orphan the release check greps for.

**Files:**
- Modify: `Sources/PisakaCore/LSPWorkspace.swift`
- Modify: `Tests/PisakaCoreTests/LSPWorkspaceTests.swift`

- [x] add `public func updateRegistry(_ registry: LSPServerRegistry) async`: swap the
      registry, then for every live or pending session whose description is gone or changed
      (id, launch, arguments or initialization options) shut it down, drop its transport,
      forget its documents and clear its failure/unavailable bookkeeping; leave every
      unchanged server running and every generation token alone
- [x] tests: `canServe` answers `false` before and `true` after a registry that adds a
      server, and back again after one that removes it; a removed server's session is shut
      down and its documents forgotten; an unchanged server keeps its session across an
      update; a re-added server that had been marked unavailable by D7 gets a fresh budget;
      `prepareForFolderChange`'s generation is unaffected by an update
- [x] run `swift test` — must pass before task 5

### Task 5: Consent, and the provisioning model

Consent persistence in `SettingsStore`, and the model that owns "which servers exist, what
state are they in, what does the registry look like now" — the single thing both the banner
and the Settings surface read.

**Files:**
- Modify: `Sources/PisakaCore/SettingsStore.swift`
- Create: `Sources/PisakaCore/LSPProvisioning.swift`
- Modify: `Tests/PisakaCoreTests/SettingsStoreTests.swift`
- Create: `Tests/PisakaCoreTests/LSPProvisioningModelTests.swift`

- [ ] `SettingsStore`: `LSPServerConsent` (`unasked`/`accepted`/`declined`) persisted per
      server id under a stable key, read leniently (an unknown stored value is `unasked`),
      with round-trip tests across a fresh store instance
- [ ] `@MainActor LSPProvisioningModel`: per-server rows (display name, languages, state,
      pending download size), `consentPrompt(forOpening:)` as a pure rule (a downloadable
      language, consent `unasked`, nothing installed), `accept`/`decline`/`install`/`remove`,
      a `refresh()` that derives everything from the engine at launch, and a published
      `registry` (`.standard` plus every installed server) pushed through an
      `onRegistryChange` callback whenever it changes
- [ ] the silent rules: an accepted-but-absent server installs on first use without asking
      again; a failed install returns the row to "not installed" with a retry available and
      raises nothing anywhere else; a declined server never prompts and never installs;
      removing a server also removes the runtime when no installed server still needs it
- [ ] model tests over the engine with the task-3 fakes: prompt fires once and never after
      either answer, including across a rebuilt store; accept installs runtime + server and
      publishes a registry whose `canServe` covers TS *and* JS; decline publishes nothing
      and downloads nothing; install failure leaves consent accepted, state not-installed
      and the registry unchanged; remove publishes a registry without the server and drops
      the runtime only when unused; the published registry always keeps sourcekit-lsp first
- [ ] run `swift test` — must pass before task 6

### Task 6: The app-side seams and the wiring

The two things Core cannot do — fetch bytes and run `tar` — plus composing the whole thing
in `PisakaApp` and extending the gating suite's per-side lists.

**Files:**
- Create: `Sources/Pisaka/LSPDownloadService.swift`
- Create: `Sources/Pisaka/LSPArchiveUnpacker.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `Tests/PisakaCoreTests/LSPSourceGatingTests.swift`

- [ ] `LSPDownloadService`: an ephemeral `URLSession` with caching off and stated timeouts,
      answering `Data` and mapping a transport error or a non-200 response to
      `LSPInstallError.downloadFailed`
- [ ] `LSPArchiveUnpacker`: `/usr/bin/tar -xz --strip-components=<n> -C <dir>` with the
      archive written to the child's stdin and both other pipes drained before waiting
      (`GitCLIService`/`LSPToolchain`'s deadlock rule), `F_SETNOSIGPIPE`-equivalent care on
      the write side, and a non-zero exit mapped to `unpackFailed`
- [ ] wire in `PisakaApp.init`: install root under `Application Support`, host architecture
      from `#if arch(arm64)`, engine + model built once, `onRegistryChange` pushing into
      `lspWorkspace.updateRegistry(_:)`, a launch-time `sweepStaging()` + `refresh()`, and
      the model published to the views
- [ ] extend `LSPSourceGatingTests`' `expectedAppFiles` and `expectedCoreFiles` with every
      new file of this phase (the app-side ones must open with `#if os(macOS)`; the Core-side
      ones must import Foundation and nothing else, and mention neither `Process` nor a
      platform framework)
- [ ] run `swift test` — must pass before task 7

### Task 7: The consent banner, the Settings surface and Acknowledgements

The whole management UI, deliberately small: one banner, one Preferences tab, one extra
Acknowledgements section that exists only when something is installed.

**Files:**
- Create: `Sources/Pisaka/LSPConsentBanner.swift`
- Create: `Sources/Pisaka/LSPServerSettingsView.swift`
- Create: `Sources/Pisaka/LSPInstalledLicenses.swift`
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Sources/Pisaka/SettingsView.swift`
- Modify: `Sources/Pisaka/AcknowledgementsView.swift`
- Modify: `Tests/PisakaCoreTests/LSPSourceGatingTests.swift`

- [ ] `LSPConsentBanner`: a non-modal strip above the editor, driven by
      `consentPrompt(forOpening:)` on the selected tab's language, naming the server and the
      approximate download size, with exactly two actions (Download / No Thanks) and no
      other way out
- [ ] `LSPServerSettingsView`: a third Preferences tab listing each downloadable server with
      its state — not installed / declined / installing… (indeterminate) / installed +
      version — and Install, Retry and Remove where each applies; no progress bar, no log, no
      version picker
- [ ] `LSPInstalledLicenses` + the Acknowledgements section: read each installed component's
      recorded license files from disk (`node`'s `LICENSE`, `typescript-language-server`'s
      `LICENSE`, `typescript`'s `LICENSE.txt`, `pyright`'s `LICENSE.txt`, `fsevents`'
      `LICENSE`), render them through the existing `LicenseTextView`, and show the section
      only when something is installed
- [ ] extend the gating suite's app-side list with the three new files
- [ ] run `swift test` — must pass before task 8

### Task 8: Pin the invariants and build both destinations

**Files:**
- Modify: `Tests/PisakaCoreTests/RoutingIntelligenceProviderTests.swift`
- Modify: `Tests/PisakaCoreTests/LSPProvisioningModelTests.swift`

- [ ] a test that the downloadable entries never touch the Swift path: with nothing
      installed, a Swift request routes exactly as in 2a, and a TypeScript and a Python
      request answer byte-identically to the bare tree-sitter provider
- [ ] the same equality after an install completes for the *other* language — installing
      pyright must not change a TypeScript answer, and neither may change a Swift one
- [ ] run `swift test`
- [ ] run `xcodegen generate` — XcodeGen enumerates `Sources/Pisaka` into explicit file
      references at generate time, so this phase's new app-side files are absent from
      `Pisaka.xcodeproj` until it is re-run and the macOS build would fail on the
      `PisakaApp` wiring that references them
- [ ] build macOS (`xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`)
- [ ] build iOS (`-destination 'generic/platform=iOS'`) and confirm none of the new app-side
      machinery compiles into it

### Task 9: Documentation

**Files:**
- Create: `docs/architecture/core-provisioning.md`
- Modify: `docs/architecture/core-lsp.md`
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [ ] `core-provisioning.md`: a full entry per new file (Core and app), D11–D16 with their
      reasoning, the pinned manifest table, the by-hand update procedure as copy-pasteable
      commands (nodejs.org `SHASUMS256.txt`; `curl … | shasum -a 256` per npm tarball; how to
      record unpacked sizes), the license-surfacing decision, and the known limits: the
      resident-download memory cost, no resume/proxy/mirror configuration, architecture taken
      from the build slice (a Rosetta-translated app provisions x64 Node), corporate TLS
      interception and air-gapped installs fail as an ordinary silent download failure,
      pyright without a Python interpreter analyses against bundled typeshed only, macOS only
- [ ] `core-lsp.md`: point D9 at the dynamic registry, document `updateRegistry(_:)` on the
      `LSPWorkspace` entry, and cross-link the new doc
- [ ] `CLAUDE.md`: index lines for every new file, and the new invariant — nothing downloads
      without consent; installs are atomic under Application Support and touch nothing
      global; the manifest is pinned data in Core changed only by shipping a new app version;
      Core never fetches or unpacks; the provisioning layer is a reader like the rest of the
      LSP layer
- [ ] `README.md`: which languages download a server and roughly how large, the consent
      flow, where the files live and how to de-provision, and the offline/declined behavior
      in the Known Limitations voice

## Post-Completion Checks (manual, on a real machine)

- Opening a `.ts` file prompts once with a size; accepting downloads, verifies and installs
  Node + the server, and completion/definition in that file become semantic — typed members,
  cross-file jumps — without a restart.
- The same for a `.py` file and pyright; a second TypeScript project reuses the installed
  Node without downloading again.
- Declining persists across relaunch and that language stays on tree-sitter; the Settings row
  shows "declined" and can be turned around from there.
- The Settings surface shows accurate states and removing an installed server returns the
  language to tree-sitter immediately, with no leftover process.
- A mid-download network cut leaves no partial install (`.staging` empty or swept at next
  launch), the row reads "not installed", and Retry works.
- `pgrep -fl "node|pyright|typescript-language-server"` is empty after quitting the app.
- Everything installed lives under `~/Library/Application Support/Pisaka/LanguageServers/`;
  deleting that directory fully de-provisions.
- Acknowledgements shows the installed components and their license texts, and the section
  disappears once they are removed.
