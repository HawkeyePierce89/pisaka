# Completion candidate hygiene, and a provisioned yaml-language-server

## Overview

Two deliveries found through one bug: typing `ser` in a fresh `docker-compose.yml`
offers a markdown heading from another file.

**Part 1** stops the tree-sitter completion path from offering index entries that
exist for navigation rather than for typing: `.heading` symbols never complete, and
— as a general rule — a candidate's inserted text must be a single identifier-shaped
token by `IdentifierScanner`'s own boundary rule. The index keeps storing everything
it stores today; ⌃⌘J and go-to-definition are untouched.

**Part 2** gives YAML the schema knowledge the tree-sitter path can never have:
Red Hat's `yaml-language-server` becomes the fourth npm-backed component in
`LSPProvisioningManifest` and the next registry contributor, consented per server
like every other one. Its schemas come from schemastore.org at runtime — a stated,
documented exception to "what may be downloaded is pinned data", declared in the
consent copy, the Settings row, CLAUDE.md and `core-provisioning.md`.

## Context

### Files involved

Part 1:

- `Sources/PisakaCore/IdentifierScanner.swift` — the one boundary rule; gains the
  whole-string question.
- `Sources/PisakaCore/SymbolIntelligenceProvider.swift` — where ranking lives, and
  therefore where the candidate rule belongs.
- `Tests/PisakaCoreTests/` — `IdentifierScannerTests`, `SymbolIntelligenceProviderTests`.

Part 2:

- `Sources/PisakaCore/LSPProvisioningManifest.swift` — the component + the
  `LSPDownloadableServer` case.
- `Sources/PisakaCore/LSPServerDescription.swift` — per-server configuration as data.
- `Sources/PisakaCore/LSPSession.swift` — delivers it (push + answering pulls).
- `Sources/PisakaCore/LSPWorkspace.swift` — passes it at `start`.
- `Sources/PisakaCore/LSPProvisioning.swift` — `LSPConsentPrompt` / `LSPServerRow`
  carry the runtime-network note.
- `Sources/Pisaka/LSPConsentBanner.swift`, `Sources/Pisaka/LSPServerSettingsView.swift`
  — the two macOS surfaces that print it.
- Tests: `LSPProvisioningManifestTests`, `LSPSessionTests`, `LSPProvisioningModelTests`,
  `SettingsStoreTests`.
- Docs: `CLAUDE.md`, `docs/architecture/core-intelligence.md`, `core-provisioning.md`,
  `core-lsp.md`.

### Facts established by exploration (not assumptions)

- `yaml-language-server` 1.24.0 is **not bundled**: `out/server/src/server.js`
  requires its dependencies at runtime, so the whole closure must be pinned.
  Resolved closure — 20 tarballs, ~4.19 MB compressed, ~19 MB unpacked:
  `yaml-language-server` 1.24.0, `ajv` 8.20.0, `ajv-draft-04` 1.0.0, `ajv-i18n` 4.2.0,
  `@vscode/l10n` 0.0.18, `fast-deep-equal` 3.1.3, `fast-uri` 3.1.5,
  `json-schema-traverse` 1.0.0, `jsonc-parser` 3.3.1, `picomatch` 4.0.5,
  `prettier` 3.9.6, `request-light` 0.5.8, `require-from-string` 2.0.2,
  `vscode-jsonrpc` 8.2.0, `vscode-languageserver` 9.0.1,
  `vscode-languageserver-protocol` 3.17.5, `vscode-languageserver-textdocument` 1.0.13,
  `vscode-languageserver-types` 3.17.5, `vscode-uri` 3.1.0, `yaml` 2.8.3.
  No version conflicts in the closure, so the flat `node_modules/<name>` layout the
  existing components use resolves correctly. `prettier` is pinned even though Pisaka
  never asks for formatting: `yamlFormatter.js` requires `prettier/standalone` in the
  language service's own module graph.
- Licenses across the closure: MIT throughout, plus `yaml` (ISC) and `fast-uri`
  (BSD-3-Clause) — so `licenseSPDX` becomes `MIT AND ISC AND BSD-3-Clause` and the
  manifest suite's `known` SPDX id set grows two entries. `prettier` and the five
  `vscode-*` packages ship a second `THIRD-PARTY-NOTICES.md` / `thirdpartynotices.txt`
  beside their license, all of which must be listed.
- **`@vscode/l10n` 0.0.18 publishes no license file at all** (MIT declared in
  `package.json` only). That breaks `testEveryComponentDeclaresALicenseItActuallyShips`'
  "nothing lands unacknowledged" rule, which needs a stated per-artifact exception
  rather than a silent omission.
- **How the server takes its configuration** (read out of the pinned 1.24.0 bundle,
  not guessed): on `initialized` it calls `settingsHandler.pullConfiguration()`
  **unconditionally**, sending `workspace/configuration` for the sections
  `yaml`, `http`, `[yaml]`, `editor`, `files` — regardless of the client advertising
  `workspace.configuration: false`. Its `onDidChangeConfiguration` handler ignores the
  pushed payload and re-pulls. So the channel that actually carries the setting is
  **the client's answer to `workspace/configuration`**, which `LSPSession.answer(_:)`
  today answers `null` per item. (`schemaStoreEnabled` happens to default to `true`,
  so schemas would load by luck; the plan states the setting explicitly instead of
  relying on an upstream default.)
- The client capability `workspace.configuration` stays `false`. Flipping it to `true`
  would change the handshake for all five existing servers for no gain — this one pulls
  either way, and the pin is what makes that a fact rather than a hope.

## Development Approach

- **Testing approach**: Regular (code first, then tests), except the two pure Core
  rules in Tasks 1 and 2, where the test is cheap to write first.
- Pure engine + thin glue: every decision in Core with unit tests; the macOS views
  only print what the Core value says.
- Complete each task fully; `swift test` green before the next.
- Part 1 and Part 2 are independent up to Task 6 — Part 1 must not be blocked by any
  pin resolution.

## Implementation Steps

### Task 1: A completion candidate must be one identifier-shaped token

**Files:**
- Modify: `Sources/PisakaCore/IdentifierScanner.swift`,
  `Sources/PisakaCore/SymbolIntelligenceProvider.swift`
- Modify: `Tests/PisakaCoreTests/IdentifierScannerTests.swift`,
  `Tests/PisakaCoreTests/SymbolIntelligenceProviderTests.swift`

Intent: a name that cannot be typed as a word cannot be inserted as one, whatever
kind captured it — and a markdown heading is never a completion candidate even when
it happens to be one word.

- [ ] Extend `IdentifierScanner` with the whole-string form of its one boundary rule
      (non-empty, first scalar an identifier start, every scalar a continuation), so
      the rule is not restated anywhere: the same rule that decides what the caret is
      completing decides what may be inserted.
- [ ] In `SymbolIntelligenceProvider`, filter the **symbol source** of both completion
      paths (ordinary and member) through one documented predicate: excluded kinds
      (`.heading`, stated by name with the reason) and the identifier-shape rule.
      Keywords and harvested buffer words are already identifier-shaped by construction
      and are not re-filtered.
- [ ] Leave `definitions(for:)` and everything the index stores untouched — state that
      in the doc comment, since the whole point is that navigation keeps the entries
      completion now refuses.
- [ ] Tests: a heading is excluded from completion; a multi-word / parenthesised name
      of any kind is excluded; a single-word `.key`, `.anchor`, `.function` survives;
      a heading is still returned by `definitions(for:)`; member completions with a
      well-shaped member are unaffected.
- [ ] `swift test` green.

### Task 2: Per-server configuration as data on the description

**Files:**
- Modify: `Sources/PisakaCore/LSPServerDescription.swift`,
  `Sources/PisakaCore/LSPSession.swift`, `Sources/PisakaCore/LSPWorkspace.swift`
- Modify: `Tests/PisakaCoreTests/LSPSessionTests.swift` (+ workspace tests if the
  start signature is asserted there)

Intent: a server that needs a setting gets it as pinned data on its description, with
no server-specific code anywhere in the session.

- [ ] Add one opaque `JSONValue?` configuration field to `LSPServerDescription`
      (settings object keyed by section, e.g. `{"yaml": {...}}`), documented like
      `initializationOptions`: it is *that server's* configuration and Core has no
      opinion about its shape.
- [ ] `LSPSession` takes it at `start(…)` and delivers it on both channels a server may
      use: a `workspace/didChangeConfiguration` notification carrying `{settings: …}`
      after `initialized`, and — the channel that actually matters here —
      `workspace/configuration` answered **per requested section** out of the same
      value, falling back to `null` for a section it does not name.
- [ ] Behaviour for every existing server is unchanged by construction: with no
      configuration the notification is not sent and the pull still answers `null` per
      item. Say so in the doc comment; the client capability stays
      `workspace.configuration: false` for the reason established above.
- [ ] `LSPWorkspace` passes `description.configuration` at `start`, beside
      `initializationOptions`.
- [ ] Tests over `ScriptedLSPTransport`: a description with configuration produces the
      notification after `initialized`; a `workspace/configuration` request is answered
      section-by-section with the configured object and `null` for unknown sections;
      a description without configuration sends no notification and answers all-`null`
      exactly as today.
- [ ] `swift test` green.

### Task 3: Pin `yaml-language-server` in the manifest

**Files:**
- Modify: `Sources/PisakaCore/LSPProvisioningManifest.swift`
- Modify: `Tests/PisakaCoreTests/LSPProvisioningManifestTests.swift`

Intent: one component record and one server case — no new download code, no unpack
rule, no path math, no npm, ever.

- [ ] Add the `yaml-language-server` component: version `1.24.0`, `requires: ["node"]`
      (the existing runtime, not a second one), 20 `registry.npmjs.org` tarball
      artifacts — the closure listed in Context — each landing at
      `node_modules/<package>` (`node_modules/@vscode/l10n` for the scoped one), entry
      point `node_modules/yaml-language-server/out/server/src/server.js`.
- [ ] Resolve every pin **by the recipe in `core-provisioning.md`** — digest and byte
      count taken from the bytes that arrive, `unpackedByteCount` measured with `du`.
      Sanity check against the exploration figures: ~4.19 MB compressed total, ~19 MB
      unpacked. Run the `tar tzf | grep -iE 'licen|notice|third.?party'` step on every
      one of the 20 artifacts and list what it finds.
- [ ] `licenseSPDX: "MIT AND ISC AND BSD-3-Clause"`; `licenseFileSubpaths` lists every
      license and third-party notice the closure ships — including `prettier`'s
      `THIRD-PARTY-NOTICES.md` and each `vscode-*` `thirdpartynotices.txt`.
- [ ] Add the `LSPDownloadableServer.yaml` case: `languages: [.yaml]`, component
      `yaml-language-server`, runtime `node`, `--stdio`, no tsserver path, and the
      configuration value `{"yaml": {"schemaStore": {"enable": true}, "completion":
      true, "hover": true}}` carried onto the description built by
      `serverDescription(manifest:layout:)`.
- [ ] Manifest tests: extend the served-language and server-set equalities to include
      YAML; add the entry-point / configuration assertions in the shape the TypeScript
      and Python ones already have; grow the `known` SPDX id set with `ISC` and
      `BSD-3-Clause`; add the **stated exception** for `node_modules/@vscode/l10n`
      (publishes no license file; MIT declared in its `package.json`), named by
      destination with the reason, so it reads as a decision and a second one cannot
      appear by accident.
- [ ] `swift test` green.

### Task 4: The runtime schema fetch is stated where consent is given

**Files:**
- Modify: `Sources/PisakaCore/LSPProvisioning.swift`
- Modify: `Sources/PisakaCore/LSPProvisioningManifest.swift` (the note as data on the
  server case)
- Modify: `Tests/PisakaCoreTests/LSPProvisioningModelTests.swift`

Intent: the one honest sentence about traffic that is not pinned travels with the
server, not with a view.

- [ ] Put the note on `LSPDownloadableServer` as data (`nil` for every existing case):
      the YAML server fetches JSON schemas from schemastore.org at runtime, which is
      what makes compose-file completion work.
- [ ] Surface it on both values the views read — `LSPConsentPrompt` and `LSPServerRow`
      — so the banner and the Settings row cannot disagree, and neither invents copy.
- [ ] Tests: the YAML prompt and row carry the note, every other server's is `nil`,
      and consent/install/remove behaviour is otherwise identical to the existing rows
      (including that nothing about the note changes when the server is installed).
- [ ] `swift test` green.

### Task 5: The two macOS surfaces print it

**Files:**
- Modify: `Sources/Pisaka/LSPConsentBanner.swift`,
  `Sources/Pisaka/LSPServerSettingsView.swift`

Intent: thin glue — the views print the Core value and decide nothing.

- [ ] The download consent strip shows the note under its size sentence when the
      prompt has one, in the caption style the existing secondary line uses.
- [ ] The Settings row shows the same note for the same row, beside the state line.
- [ ] No new state, no per-server `if` in the view: the presence of the note is the
      condition.
- [ ] `swift test` green (these files are untested by convention; the compile gates in
      Task 7 cover them).

### Task 6: Documentation where the behaviour lives

**Files:**
- Modify: `CLAUDE.md`, `docs/architecture/core-intelligence.md`,
  `docs/architecture/core-provisioning.md`, `docs/architecture/core-lsp.md`

- [ ] `core-intelligence.md`: the completion-candidate rule beside the ranking rules —
      excluded kinds, the identifier-shape rule, and the explicit statement that the
      index stores and navigates the same entries as before.
- [ ] `core-provisioning.md`: the new row in the pinned-manifest table; the closure and
      why it is pinned whole (including `prettier`); the `@vscode/l10n` license-file
      exception; and **the schemastore exception recorded where the invariant is
      stated**, not in a code comment.
- [ ] `core-lsp.md`: the new decision covering the configuration transport (the
      description field, both delivery channels, why `workspace.configuration` stays
      `false`, and that the pinned version's unconditional pull is the mechanism), plus
      the YAML server as the next registry contributor.
- [ ] `CLAUDE.md`: index lines for the changed files, the provisioned-servers invariant
      gaining its one stated exception, and the completion-candidate rule in the
      cross-cutting list. No per-file essays.

### Task 7: Verify acceptance criteria

- [ ] `swift test` — full suite green.
- [ ] `xcodegen generate`, then macOS **Release** build green.
- [ ] iOS build green (`generic/platform=iOS` or the simulator destination) — every
      provisioning surface stays macOS-gated and Core stays Foundation-only.
- [ ] Confirm no npm invocation, no unpinned download and no secret anywhere in the
      diff; the only unpinned runtime traffic is the schema fetch, stated in the
      consent surface and the docs.

## Post-Completion (manual, DEBUG build)

- Fresh YAML buffer, **no server consented**: `ser` offers no markdown heading and no
  multi-word phrase, from any file of any language.
- ⌃⌘J on a markdown file still lists headings; jumping to one still lands on it.
- Consent to the YAML server from the banner, then in `docker-compose.yml`: `ser`
  completes to `services` (schema knowledge, not buffer luck), and hover answers on a
  compose key.
- Remove the server from Preferences (and separately, delete
  `~/Library/Application Support/Pisaka/LanguageServers` by hand): YAML returns to the
  tree-sitter path with no residue and no alert.
- Open a Go / TypeScript / Python file once after Task 2 to confirm the configuration
  change disturbed no existing server.
