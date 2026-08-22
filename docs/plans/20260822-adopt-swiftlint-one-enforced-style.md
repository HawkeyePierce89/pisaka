# Adopt SwiftLint: one enforced style, zero violations, a hook and a CI gate

## Overview

Commit a `.swiftlint.yml` authored for this repository, bring `Sources/` and
`Tests/` to zero violations under it, and make the pinned linter run before
every commit (a tracked `pre-commit` hook wired with `core.hooksPath`) and in
`ci.yml`. The point is that style stops being a convention an agent can
reinterpret: any `swiftlint` invocation from the repository root picks up this
project's answer automatically, and CI refuses a pull request that does not
match it.

Pinned version: **SwiftLint 0.65.0** (the version installed locally, and the
one every number below was measured with).

## Context

### Measured violation profile (master, SwiftLint 0.65.0)

Default rules over `Sources/` + `Tests/`: **909 violations**, dominated by
rules that disagree with deliberate conventions — `identifier_name` 412,
`file_length` 105, `line_length` 90, `type_body_length` 76, `type_name` 54,
`function_body_length` 45, `force_try` 33, `cyclomatic_complexity` 25,
`optional_data_string_conversion` 21, `large_tuple` 20,
`function_parameter_count` 14, `orphaned_doc_comment` 4,
`notification_center_detachment` 4, `nesting` 3, `for_where` 2,
`closure_parameter_position` 1.

Two facts worth recording, both verified rather than assumed:

- **Every one of the 412 `identifier_name` hits is a length complaint**
  ("should be between N and N characters long") — no casing or symbol
  complaints. Configuring the length bounds resolves all of them with zero
  source edits.
- **All 33 `force_try` hits are in `Tests/`; `Sources/` contains no `try!`
  at all.** A global disable would silently license `try!` in app code, so
  `force_try` is disabled for the test tree only.

### The two answered decisions from this session

- `line_length`: limit **140**, with `ignores_urls` and
  `ignores_interpolated_strings`. Wrap what wraps by hand; the raw-string
  fixtures that cannot wrap carry an inline `swiftlint:disable:next
  line_length` with a written reason.
- `optional_data_string_conversion`: **disabled with the reason recorded**.
  The rule wants the failable `String(bytes:encoding:)` in place of
  `String(decoding:as:)`, which would turn 21 `String`s into `String?` and
  lossy decoding into a nil — a behavior change the ticket forbids. No source
  changes.

### The residual under the drafted configuration (measured, not estimated)

With the configuration in Task 1 in place, exactly these remain:

| rule | count | disposition |
|---|---|---|
| `trailing_comma` (mandatory) | 604 | `swiftlint --fix` (verified: `--fix` *inserts* mandatory commas) |
| `line_length` | 20 | ~18 wrapped by hand, the unwrappable raw-string fixtures exempted inline |
| `superfluous_disable_command` | 2 | the two `swiftlint:disable`s in `CompletionController.swift` — the new config makes them unnecessary, so they are deleted |
| `for_where` | 2 | `Sources/PisakaCore/GitRefName.swift:42`, `Sources/PisakaCore/FileName.swift:200` |
| `cyclomatic_complexity` | 2 | `HoverContent.swift` (21) and `Support/QueryScanner.swift` (22) — threshold set to 22, both are flat scanners |
| `closure_parameter_position` | 1 | `Sources/PisakaCore/LSPSession.swift:295` |

The `trailing_comma` sweep is 538 sites in `Tests/PisakaCoreTests`, 36 in
`Sources/PisakaCore`, 30 in `Sources/Pisaka`. SwiftLint's `trailing_comma`
covers **collection literals only**, not call-argument lists — so the pass is
narrower than "trailing commas everywhere".

### Why two config files

SwiftLint has no per-path rule scoping inside one file, but nested
`.swiftlint.yml` files are discovered automatically and **merge** with the
root (verified empirically in this session). The alternative — one root file
with thresholds raised above the largest *test* file — would set `file_length`
to 2200 and `type_body_length` to 2150, which switches those rules off for
`Sources/` too. So:

- `.swiftlint.yml` (root) — the document: every relaxation with its reason,
  thresholds honest for application code.
- `Tests/.swiftlint.yml` — a short child listing only the test-tree
  relaxations (`force_try`, the length rules, `nesting`), each with its
  reason, and a pointer back to the root file.

### Files involved

- Create: `.swiftlint.yml`, `Tests/.swiftlint.yml`, `.githooks/pre-commit`,
  `Tests/PisakaCoreTests/LintConfigurationTests.swift`
- Modify: `.github/workflows/ci.yml`, `README.md`, `CLAUDE.md`,
  `Sources/Pisaka/CompletionController.swift`, and the conformance pass across
  `Sources/` + `Tests/`
- Related patterns: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift` (how
  this repo pins CI shape statically, matching against **comment-stripped**
  text), `Tests/PisakaCoreTests/Support/YAMLLineMatching.swift` (the shared
  comment-stripper), `ci.yml`'s existing "Install XcodeGen 2.45.4" step (the
  URL + `shasum -a 256 -c -` pinning pattern the lint job copies)
- Dependency: SwiftLint 0.65.0. CI installs
  `https://github.com/realm/SwiftLint/releases/download/0.65.0/portable_swiftlint.zip`,
  SHA-256 `d6cb0aa7a2f5f1ef306fc9e37bcb54dc9a26facc8f7784ac0c3dd3eccf5c6ba6`
  (downloaded and hashed in this session; the archive holds a universal
  `swiftlint` binary plus its `LICENSE`). SwiftLint is a developer tool, not a
  linked dependency — it is not a `project.yml` pin and needs no
  `Resources/Licenses/` entry.

## Development Approach

- **Testing approach**: Regular (change first, then pin the shape statically).
  The "behavior" here is repository shape, so the convention that applies is
  the one `ReleaseWorkflowTests` / `ReleaseMetadataTests` follow: read the file
  through `#filePath` with Foundation only, match against comment- and
  literal-stripped text, so a silently deleted step or rule fails `swift test`.
- The whole conformance pass is **behavior-preserving by construction**: every
  edit is either whitespace/punctuation or a rewrite the linter names. If a
  rule demands a behavior change, the rule loses and is disabled with the
  reason written down.
- `swift test` must be green at every task boundary, and `swiftlint --strict`
  (run from the repository root with **no** `--config`, so the nested test
  config applies) is the second gate from Task 3 onward.
- **CRITICAL: every task ships new/updated tests.**
- **CRITICAL: all tests pass before the next task starts.**

## Implementation Steps

### Task 1: Author the SwiftLint configuration

**Files:**
- Create: `.swiftlint.yml`, `Tests/.swiftlint.yml`
- Create: `Tests/PisakaCoreTests/LintConfigurationTests.swift`

- [ ] Write `.swiftlint.yml` at the repository root. It must read as a
      document — every relaxed or disabled rule carries a comment saying
      *why*, so the next reader can tell a deliberate exemption from an
      oversight. Contents:
      - `swiftlint_version: 0.65.0` — the pin. Note in a comment that
        SwiftLint only *warns* on a mismatch (verified: it prints
        `warning: Currently running SwiftLint …` and does not fail), which is
        why the hook and CI enforce the pin themselves.
      - `included: [Sources, Tests]`;
        `excluded: [Vendor, build, DerivedData, SourcePackages]` — the
        vendored grammars are third-party C and generated sources.
      - `identifier_name: min_length 1, max_length 60` — every hit was a
        length complaint; short algorithmic bindings (`a`, `b`, `i` in
        `LineDiff`, `ThreeWayMerge`, `SHA256`) and long descriptive test
        bindings are both deliberate.
      - `type_name: min_length 2, max_length 60, allowed_symbols: ["_"]` —
        `Op` is a two-letter local type; the iOS view layer names types
        `RootView_iOS`, `PisakaApp_iOS` on purpose, which the rule reads as a
        disallowed symbol.
      - `line_length: warning 140, error 140, ignores_urls: true,
        ignores_interpolated_strings: true` — per the decision above.
      - `file_length: warning/error 1400, ignore_comment_only_lines: true` —
        configured honestly rather than disabled: this codebase carries dense
        doc comments by design, so comment-only lines are not counted. 1400
        sits above the largest application file (`PisakaApp.swift`, 1339 code
        lines) so the rule still catches runaway growth.
      - `type_body_length: warning/error 1400` — same reasoning (`PisakaApp`'s
        body is 1323).
      - `function_body_length: warning/error 140`,
        `cyclomatic_complexity: warning/error 22` — 22 clears the two flat
        scanners (`HoverContent` 21, `QueryScanner` 22) that are switches over
        a grammar, not branching logic.
      - `large_tuple: 4`, `function_parameter_count: 8` — measured maxima.
      - `trailing_comma: mandatory_comma: true` — **the opposite of the tool's
        default**, with the reason: adding an element touches one line, not
        two. Note that the rule covers collection literals only.
      - `disabled_rules`: `optional_data_string_conversion` (reason as decided
        above), `notification_center_detachment` (the editor's explicit
        `teardown()` observer removal is the architecture this project chose;
        the rule's heuristic assumes `deinit`-only removal),
        `orphaned_doc_comment` (nearly every file opens with a file-header doc
        comment, deliberately).
- [ ] Write `Tests/.swiftlint.yml`: a header comment pointing at the root file
      as the authority, then `disabled_rules` for `force_try` (a `try!` in a
      test *is* the assertion; failure is a reported test failure, and
      `Sources/` contains none), `file_length`, `type_body_length`,
      `function_body_length` (an `XCTestCase` is a flat list of independent
      test methods — length carries no complexity), and `nesting` (fixtures
      and scripted stubs nest their types next to the test that uses them).
- [ ] Verify the residual matches the table above exactly:
      `swiftlint lint --quiet --reporter csv` from the root, grouped by rule,
      must show 604 `trailing_comma`, 20 `line_length`, 2
      `superfluous_disable_command`, 2 `for_where`, 2 `cyclomatic_complexity`,
      1 `closure_parameter_position` and nothing else. A different profile
      means a threshold was mis-set — fix the config, not the sources.
- [ ] Add `Tests/PisakaCoreTests/LintConfigurationTests.swift` with the
      configuration half of the static suite (Foundation only, read through
      `#filePath`, match on comment-stripped lines via the shared
      `YAMLLineMatching` helper): both config files exist; the root declares
      `swiftlint_version:` with a three-component version; `trailing_comma` is
      configured with `mandatory_comma: true` (a silent flip back to the
      default is the exact regression this ticket exists to prevent); the root
      file's `included:` names `Sources` and `Tests`; the child's
      `disabled_rules` set equals the documented set, by **set equality**, so a
      quietly widened test exemption fails the suite.
- [ ] Run `swift test` — must pass before Task 2.

### Task 2: Trailing-comma conformance sweep

**Files:**
- Modify: ~604 sites across `Sources/PisakaCore`, `Sources/Pisaka`,
  `Tests/PisakaCoreTests`

- [ ] Run `swiftlint --fix` from the repository root (verified in this session
      to *insert* mandatory trailing commas in array and dictionary literals).
      This is a local conformance step only — neither the hook nor CI ever
      runs `--fix`.
- [ ] Confirm `swiftlint lint --quiet` now reports **zero** `trailing_comma`
      violations.
- [ ] Read the diff as a whole and confirm it is punctuation only: no line
      other than a collection-literal element's last one changed, no
      reordering, no reflow. Anything else in the diff is a bug in the pass,
      not an accepted side effect.
- [ ] Pay particular attention to the repository-file suites that read Swift
      source text (`LSPSourceGatingTests`, `SparkleSourceGatingTests`,
      `ZoomSourceGatingTests`, `CrossPlatformAuditTests`): they match on
      stripped text and should be indifferent, but they are the suites a
      whole-tree punctuation sweep would break first.
- [ ] Run `swift test` — must pass before Task 3.

### Task 3: Bring the remainder to zero violations

**Files:**
- Modify: `Sources/PisakaCore/GitRefName.swift`,
  `Sources/PisakaCore/FileName.swift`, `Sources/PisakaCore/LSPSession.swift`,
  `Sources/Pisaka/CompletionController.swift`,
  `Sources/Pisaka/LocalChangesView.swift`,
  `Sources/Pisaka/iOS/SettingsView_iOS.swift`,
  `Tests/PisakaCoreTests/LSPProvisioningManifestTests.swift`,
  `Tests/PisakaCoreTests/LeetCodeAPITests.swift`,
  `Tests/PisakaCoreTests/BranchSwitcherModelTests.swift`,
  `Tests/PisakaCoreTests/SparkleSourceGatingTests.swift`

- [ ] `for_where` (2 sites): fold the single `if` inside the `for` into a
      `where` clause — `GitRefName.swift:42`, `FileName.swift:200`. Confirm by
      reading that the loop body has no other statement, so the rewrite is
      exact.
- [ ] `closure_parameter_position` (1 site): move the closure parameters onto
      the opening-brace line in `LSPSession.swift:295`.
- [ ] `CompletionController.swift`: delete the two `swiftlint:disable`
      comments (`file_length` at the top, `type_body_length` at line 67) — the
      configured thresholds make both unnecessary, which is why they now report
      as `superfluous_disable_command` — and repair the doc-comment
      indentation the earlier default-rules sweep broke in the same file.
- [ ] `line_length` (20 sites at the 140 limit): wrap by hand everywhere the
      line is wrappable — the four view/settings lines and the long test
      assertions in `BranchSwitcherModelTests`, `SparkleSourceGatingTests`.
      Wrapping must not change what an assertion asserts.
- [ ] For the raw-string fixtures that genuinely cannot wrap — the GraphQL
      query body in `LeetCodeAPITests` and the pinned-artifact tuple lines in
      `LSPProvisioningManifestTests`, where a break would alter the literal —
      add `// swiftlint:disable:next line_length` with a one-line reason naming
      why the literal is indivisible. Use the narrowest form (`:next`), never a
      file-wide disable.
- [ ] Run `swiftlint --strict` from the repository root with no `--config`:
      **zero** violations, warnings included. Also confirm zero
      `superfluous_disable_command` — an exemption that stopped being needed is
      itself a violation under this configuration.
- [ ] Extend `LintConfigurationTests` with a guard on the in-file exemptions:
      enumerate every `swiftlint:disable` comment under `Sources/` and
      `Tests/`, and assert the set equals the small documented set from this
      task (path + rule). A new silent exemption then fails `swift test` rather
      than passing review unnoticed.
- [ ] Run `swift test` — must pass before Task 4.

### Task 4: The pre-commit hook that refuses

**Files:**
- Create: `.githooks/pre-commit` (executable)
- Modify: `Tests/PisakaCoreTests/LintConfigurationTests.swift`

- [ ] Write `.githooks/pre-commit` (`#!/bin/sh` + `set -eu`), `chmod +x`:
      - Read the pin out of `.swiftlint.yml` — one source of truth. The hook
        must contain **no literal version of its own**; a hook and a CI job
        that disagree about the version produce the exact failure this ticket
        exists to prevent.
      - `command -v swiftlint` missing → exit 1 with an actionable message:
        what to install, the pinned version, and the one-time
        `git config core.hooksPath .githooks`. **No graceful degradation, by
        explicit decision** — a machine without the toolchain is that
        machine's problem, not the repository's. Say so in a comment so the
        next reader does not "fix" it into a skip.
      - `swiftlint version` ≠ the pin → exit 1, naming both versions.
      - Collect the staged Swift files:
        `git diff --cached --name-only --diff-filter=ACMR -z -- '*.swift'`.
        No staged Swift files → exit 0.
      - Lint **what is being committed, not the working tree**: materialise
        the index with `git checkout-index -a --prefix="$TMP/"` (which carries
        both config files along, so the nested test config still applies) and
        run `swiftlint lint --strict --quiet --force-exclude` over the staged
        paths inside that tree. `--force-exclude` is required for `excluded:`
        to apply to explicitly named paths. Record in a comment why the index
        is copied rather than the worktree linted: a partially staged file must
        be judged by what the commit will contain.
      - Never run `--fix`: the hook refuses, it does not rewrite the user's
        staged content. State that in a comment too.
      - On violations, exit non-zero with the linter's own output plus a line
        naming `.swiftlint.yml` as the authority.
- [ ] Verify by hand in a scratch clone or temporary worktree: staging a file
      with a violation is refused; staging a clean file passes; a `PATH`
      without `swiftlint` produces the actionable refusal; a faked mismatched
      version produces the version refusal.
- [ ] Extend `LintConfigurationTests` with the hook half: the file exists at
      `.githooks/pre-commit`; it is executable (POSIX permissions via
      `FileManager`); its comment-stripped body reads the version out of
      `.swiftlint.yml` and contains no hardcoded version literal; it passes
      `--strict`; it contains `--force-exclude`; it contains **no** `--fix` and
      **no** `|| true`-style softening, and every refusal branch reaches
      `exit 1`.
- [ ] Run `swift test` — must pass before Task 5.

### Task 5: The CI lint job

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `Tests/PisakaCoreTests/LintConfigurationTests.swift`

- [ ] Add a `lint` job to `ci.yml`, `runs-on: macos-15`, a short
      `timeout-minutes`, with no `needs:` — it is independent of the build
      graph and should give the fastest possible feedback. Steps: checkout (the
      same pinned SHA the other jobs use), then install SwiftLint the way this
      file already installs pinned tools —
      `curl -fsSL --retry 3 -o swiftlint.zip
      https://github.com/realm/SwiftLint/releases/download/0.65.0/portable_swiftlint.zip`,
      `echo "d6cb0aa7a2f5f1ef306fc9e37bcb54dc9a26facc8f7784ac0c3dd3eccf5c6ba6
      swiftlint.zip" | shasum -a 256 -c -`, unzip, then run
      `./swiftlint lint --strict` from the repository root (no `--config`, so
      the nested test config applies) and print `--version` first so a run's
      log records which binary judged it.
- [ ] Add a comment on the job explaining why CI is the real gate: hooks are
      not cloned and are bypassable with `--no-verify`.
- [ ] Confirm the existing `ci.yml` assertions in `ReleaseWorkflowTests` still
      pass unchanged — the job-budget floor reads the macOS *build* job's
      `timeout-minutes`, and the shared smoke-launch body is matched by step
      name, so a new job with distinct step names must not disturb either. If
      any of them turns out to read the file more broadly, extend it rather
      than loosening it.
- [ ] Extend `LintConfigurationTests` with the CI half, matched on
      comment-stripped YAML lines: `ci.yml` declares a lint job; the job
      downloads SwiftLint from a URL whose version component **equals**
      `.swiftlint.yml`'s `swiftlint_version` (the cross-file pair — this is the
      assertion that makes hook, config and CI incapable of disagreeing); the
      download is verified with `shasum -a 256 -c -`; the lint invocation
      passes `--strict` and passes no `--config`; and the step cannot be
      non-fatal (no `continue-on-error`, no `|| true`).
- [ ] Run `swift test` — must pass before Task 6.

### Task 6: Documentation

**Files:**
- Modify: `CLAUDE.md`, `README.md`
- Modify: `Tests/PisakaCoreTests/LintConfigurationTests.swift`

- [ ] `CLAUDE.md` Conventions: one short paragraph (no essay — this file is
      budgeted). It states that `.swiftlint.yml` at the root is the single
      authority for style, that the pinned version is enforced by the hook and
      by CI, that `swiftlint --strict` must be clean, that relaxations live in
      the config with their reasons rather than as scattered in-file disables,
      and — pointedly, since this ticket exists because an agent did it — that
      running `swiftlint --fix` with anything other than the committed
      configuration is never the right move.
- [ ] `README.md`: a short section under **Build & Run** giving the one-time
      contributor setup — `git config core.hooksPath .githooks` — the pinned
      version and how to install it, and a line saying CI runs the same check
      so a bypassed hook only defers the failure. Add one line to the
      **Continuous Integration** section naming the new lint job.
- [ ] Extend `LintConfigurationTests`: `README.md` mentions
      `core.hooksPath .githooks`, and both `README.md` and `CLAUDE.md` name
      `.swiftlint.yml`. Setup instructions that quietly disappear are the
      documented failure mode this repo already guards against elsewhere.
- [ ] Run `swift test` — must pass before Task 7.

### Task 7: Verify acceptance criteria

- [ ] `swiftlint --strict` from the repository root: zero violations, zero
      warnings, zero `superfluous_disable_command`.
- [ ] `swift test` fully green.
- [ ] `xcodegen generate`, then
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -configuration
      Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
      CODE_SIGNING_REQUIRED=NO build` — green, proving the conformance pass
      changed no behavior in the shipping configuration.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka
      -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
      CODE_SIGNING_REQUIRED=NO build` — green.
- [ ] Re-run the hook checks end to end in a temporary worktree: a staged
      violating file is refused; a missing `swiftlint` is refused with the
      actionable message; a clean commit passes.
- [ ] Confirm `git diff --stat` for the whole branch shows only formatting, the
      handful of named mechanical rewrites, and the new config/hook/CI/test/doc
      files — no API change, no refactor, no reverted branch.

## Post-Completion

- The lint job's real behavior on a pull request (a violating PR is refused)
  can only be observed once the branch is pushed — verify on the first PR.
- Bumping SwiftLint later means: change `swiftlint_version:` in
  `.swiftlint.yml`, re-download the release asset, recompute the SHA-256, and
  update the URL and digest in `ci.yml`. The static suite fails until the two
  agree, which is the intended forcing function.
