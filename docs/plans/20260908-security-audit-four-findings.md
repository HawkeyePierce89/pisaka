# The four findings of the security audit

## Overview

Four real findings from an external static audit, fixed in the ticket's priority order,
each as its own task with its own green gates:

1. The iOS libgit2 fetch refuses off-site redirects (`GIT_REMOTE_REDIRECT_NONE`), so a
   stored Personal Access Token cannot be handed to a host the remote redirected to.
2. The macOS language-server transport gets a **bounded** write queue: a backlog past a
   stated ceiling is treated as the server's death, through the one channel the session
   already understands.
3. Two leaks and one narrowing in the vendored SQL external scanner are fixed, marked,
   and recorded in that package's `VENDORED.md`.
4. A language-server download is bounded by the byte count the manifest already pins —
   enforced on the bytes actually received, never on a header.

Nothing else changes. Findings 5–7 of the audit, a libgit2 upgrade, credentials keyed by
port, an integration test for the redirect, and bounding the *incoming* LSP streams are
all out of scope, and the plan records the incoming-stream non-change with its reason.

## Context

### Files involved

**Finding 1 (iOS redirect)**

- `Sources/Pisaka/iOS/LibGit2Service.swift` — `fetch(remote:root:)` at ~line 310 builds
  `git_fetch_options` from `git_fetch_options_init` and installs the credentials callback.
- `docs/architecture/app-ios.md` — the `LibGit2Service` entry (~line 736).
- Create: `Tests/PisakaCoreTests/LibGit2FetchSourceGatingTests.swift`.

**Finding 2 (write queue)**

- `Sources/Pisaka/LSPProcessTransport.swift` — `send(_:)`, the serial `writeQueue`, the
  existing `finishStream()` failure path.
- Create: `Sources/PisakaCore/LSPWriteBudget.swift`.
- Create: `Tests/PisakaCoreTests/LSPWriteBudgetTests.swift`.
- `Tests/PisakaCoreTests/LSPSourceGatingTests.swift` — `expectedCoreFiles` is a set
  equality, so a new Core `LSP*` file must be added there.
- `docs/architecture/core-lsp.md` (Files + Decisions + Known limits), `CLAUDE.md` index.

**Finding 3 (SQL scanner)**

- `Vendor/TreeSitterSql/src/scanner.c` — line 127 (early `return false` leaking
  `start_tag`), lines 167–176 (`serialize`, `int tag_length = strlen(...) + 1`), lines
  180–187 (`deserialize` overwriting `state->start_tag` with `NULL`).
- `Vendor/TreeSitterSql/VENDORED.md` — the verbatim/modified lists and the update
  procedure.

**Finding 4 (download ceiling)**

- `Sources/PisakaCore/LSPInstallEngine.swift` — the `LSPArtifactDownloading` seam (line
  ~28) and the download/digest sequence (lines ~359–378).
- `Sources/PisakaCore/LSPProvisioningManifest.swift` — `LSPArtifact.byteCount` and the
  "sizes shown to the user, not checks" doc comment (line ~119).
- `Sources/Pisaka/LSPDownloadService.swift` — the only `URLSession` in the layer.
- `Tests/PisakaCoreTests/Support/ScriptedInstallSeams.swift` — `ScriptedDownloader`.
- `Tests/PisakaCoreTests/LSPInstallEngineTests.swift`.
- `docs/architecture/core-provisioning.md` (D14 + Known limits), `CLAUDE.md` invariant.

### Facts established by exploration

- `git_fetch_options` carries `follow_redirects` (`libgit2/include/git2/remote.h`, in the
  `git_fetch_options` struct, beside `depth` and `custom_headers`). `git_fetch_options_init`
  leaves it `0` — "not specified" — which makes libgit2 consult `http.followRedirects`,
  whose default is *initial*. So the finding is real and the one-line assignment is the fix.
- `LibGit2Service.fetch` has exactly one `git_fetch_options_init(` call and exactly one
  `git_remote_fetch(` call in the whole file — which is what lets a text pin be an
  ordering assertion rather than a bare `contains`.
- `LSPProcessTransport.send` queues to a serial `DispatchQueue` and returns; its failed
  write calls `finishStream()` and nothing else. `LSPTransport`'s contract already says a
  dead server is reported by `incomingBytes` finishing, and `LSPWorkspace` owns everything
  after that (D7).
- `LSPFraming.defaultMaximumContentLength` is 64 MiB — that is the *incoming* per-message
  cap; nothing bounds the outgoing queue.
- The next free decision number in the D-series is **D39** (`core-lsp.md` runs to D38).
- Source-gating suites share `LSPSourceGatingTests.strippingCommentsAndStringLiterals(_:)`;
  five suites already call it.
- `LSPInstallEngine` wraps anything the downloader throws into
  `LSPInstallError.downloadFailed(component:reason:)` using `localizedDescription`, and
  `ScriptedDownloader.Failure` is written as bare reason phrases to match.
- `ScriptedDownloader` records `requestedURLs` and supports `Gate`-held requests; adding a
  recorded maximum per request fits its existing shape.

### Related patterns

- Source-gating suites that read repository files through `#filePath` with Foundation
  only, match comment- and literal-stripped text, and carry a loud-vacuity guard.
- Pure Core value + thin app applier (`ZoomScaleRule`/`ZoomController`, `DiagnosticShift`).
- Vendored-grammar local changes marked in the source and recorded in `VENDORED.md` with
  the update procedure adjusted (`queries/highlights.scm`'s `;; Added by Review Fixes`).

## The design decisions this plan makes

**1. The redirect pin is a text pin, and the plan says so out loud.** `LibGit2Service` is
compiled only under `#if os(iOS)`: `swift test` builds Core alone, the app-layer bundle is
macOS, and CI has no simulator. A real integration test would need an HTTP server that
redirects to a second host which answers 401, running inside a simulator this pipeline does
not have. So the rule is pinned the way this repository pins what it cannot execute — a
gating suite over stripped source, asserting the assignment exists exactly once and sits
*between* the file's single `git_fetch_options_init(` and its single `git_remote_fetch(`,
with no other redirect constant anywhere in the file. That is a mechanism, not a `contains`
a comment could satisfy — and it is not a proof that libgit2 honours the value.

**2. No host comparison is added to the credentials callback.** libgit2's
`handle_remote_auth` hands the callback `transport->owner->url` — the *original* remote URL,
not the redirect target — so a comparison there would compare the original with itself and
report a match for exactly the case it was written to catch. The doc entry says this in one
sentence so the next reader does not "harden" it that way. Keying the PAT by port is not
done for the same reason.

**3. The write ceiling is about a backlog, not about one message.** `LSPWriteBudget.admit`
always accepts when nothing is pending, however large the message: a `didOpen` carrying a
20 MB file is a big write, not a dead server, and the pipe will drain it. Over-the-line is
only reachable when a backlog already exists and the new message would push it past the
ceiling — which is precisely the "alive but not reading its stdin" shape the finding
describes. The ceiling is **32 MiB** (`33_554_432`): a 1 MB source file re-synced whole
thirty times over is still under it, and it is half the incoming `Content-Length` cap the
layer already lives with, which makes the two numbers legible together.

**4. Crossing the ceiling calls `finishStream()` and nothing else.** No new error case, no
throw, no second failure channel, no counter, no alert. It is the same call the failed write
already makes, so the session goes terminal and D7's existing machinery — backoff,
diagnostics clear, four-failure retirement — handles the rest. A server that stops reading
is, for every purpose this layer has, a server that died.

**5. Pending `didChange`s are not coalesced.** The transport is handed opaque framed bytes
and by contract never interprets a message; it cannot tell which document a queued write
belongs to without parsing JSON in an app file, and the session cannot learn that an earlier
sync is still unsent without a second channel back from the transport. Both are new plumbing
the ticket rules out. The bound alone is the answer.

**6. The incoming streams stay `.unbounded`, deliberately.** Each element is already bounded
by `LSPFraming`'s `Content-Length` cap, the consumer is an actor that drains continuously,
and dropping an element would desync `LSPFraming.Decoder` permanently — the one failure this
layer cannot recover from. Recorded as a non-change in `core-lsp.md`.

**7. The download seam grows a maximum; the seam still carries bytes, not files.**
`data(from:maximumByteCount:)`. Core passes `artifact.byteCount`. Keeping bytes preserves
D14 — a file-carrying seam would make Core responsible for a temporary file it must hash,
unpack *and* delete on four failure paths. `URLSession.bytes(for:)` was considered and
rejected: `AsyncBytes` yields one `UInt8` at a time, so a 53 MB artifact becomes ~53 million
iterations and the cure costs more than the disease. The app half therefore uses a
`URLSessionDataDelegate` that appends each chunk and cancels the task the moment the
accumulated count exceeds the maximum — one session per request with its own delegate,
`finishTasksAndInvalidate()` when it ends, so the file keeps having no shared mutable state
(the reason it is `@unchecked Sendable` today). The `URLSessionConfiguration` is unchanged
and still built once.

**7a. A cancellation the delegate itself caused surfaces as `tooLarge`, never as
"cancelled".** `URLSessionTask.cancel()` makes URLSession complete the request with
`URLError.cancelled`, so a naive delegate would hand the engine — and the Settings row — the
word "cancelled" for a body that was in fact oversized. The delegate therefore **records the
over-limit reason** on itself before cancelling, and the completion path consults that
record: when the delegate cancelled for the maximum, the seam throws `Failure.tooLarge`, so
`LSPInstallError.downloadFailed`'s reason is the size sentence and `URLError.cancelled`
never reaches the engine for this case. A genuine external cancellation — one the delegate
did not cause — keeps its own error unchanged. The `ScriptedDownloader` cannot see this (it
never runs URLSession), so the rule is stated in the file's doc comment and in
`core-provisioning.md` beside D14.

**8. Core decides, the app counts — and Core checks too.** The engine refuses
`archive.count > artifact.byteCount` as `downloadFailed` after the seam returns. That is not
a redundant second check: the app-side cutoff is what protects *memory* (it can only be
enforced where bytes arrive), and Core's refusal is what *decides* — it is the rule the
tests exercise and the reason `ScriptedDownloader`, which deliberately ignores the maximum
so it can stand in for a misbehaving server, is still caught. No tolerance is added: the
artifact is pinned by SHA-256, so any other length can never verify.

**9. The scanner fix is upstream's if upstream has one.** Task 3 checks the newest tag of
the SQL grammar first and ports verbatim if the fix is there; only otherwise is one authored
here.

## Development Approach

- **Testing approach**: regular (code first, then tests), except the two pure Core rules
  (`LSPWriteBudget`, the engine's size refusal) where the test is written against the
  stated rule before the applier is wired.
- Each of the four findings is one task, in the ticket's order, and its gates are green
  before the next task starts. Every task that changes behavior carries new/updated tests.
- Local builds use derived data **outside** the repository root
  (`~/Library/Developer/Xcode/DerivedData/pisaka-audit{,-ios}`), per the repository's
  build-output convention.
- Before touching a file, read its entry in the matching `docs/architecture/*.md` and
  update that entry in the same task.
- No product or brand name anywhere: code, comments, tests, docs, this plan, commits.

## Implementation Steps

### Task 1: Off-site redirects refused on the iOS fetch

**Files:**

- Modify: `Sources/Pisaka/iOS/LibGit2Service.swift`
- Modify: `docs/architecture/app-ios.md`
- Create: `Tests/PisakaCoreTests/LibGit2FetchSourceGatingTests.swift`

- [x] Read the `LibGit2Service` entry in `docs/architecture/app-ios.md` before editing.
- [x] In `fetch(remote:root:)`, immediately after `git_fetch_options_init(&options, …)`
      and before the credentials wiring, add
      `options.follow_redirects = GIT_REMOTE_REDIRECT_NONE`, with a comment stating what
      it refuses (a `Location` naming another host, at any stage), what it still allows
      (a path-only `Location`, and a redirect to the same host — libgit2's
      `git_net_url_apply_redirect` compares the host alone when off-site is disallowed),
      and why the credentials callback is not the place for this check.
- [x] Change nothing else about the fetch: the same refspecs, the same callback, the same
      `CredentialContext`, the same error mapping. A private repository on a well-behaved
      host must fetch exactly as before.
- [x] Write `LibGit2FetchSourceGatingTests`: read
      `Sources/Pisaka/iOS/LibGit2Service.swift` through `#filePath`, strip with
      `LSPSourceGatingTests.strippingCommentsAndStringLiterals(_:)`, then assert, on the
      stripped text:
      - the file is non-empty and contains `git_fetch_options_init(` exactly once and
        `git_remote_fetch(` exactly once (the loud-vacuity guard — the ordering rule below
        cannot be satisfied by a file that lost either call);
      - a whitespace-insensitive match for `follow_redirects` `=` `GIT_REMOTE_REDIRECT_NONE`
        occurs exactly once, and its offset lies **after** the `git_fetch_options_init(`
        call and **before** the `git_remote_fetch(` call, so it is pinned to the options
        that fetch actually uses;
      - neither `GIT_REMOTE_REDIRECT_INITIAL` nor `GIT_REMOTE_REDIRECT_ALL` appears
        anywhere in the file.

      The suite's doc comment states plainly that this is a text pin, not an integration
      test, and names what an integration test would need (an HTTP server redirecting to a
      second host that answers 401, inside a simulator this pipeline does not have).
- [x] Update the `LibGit2Service` entry in `docs/architecture/app-ios.md`: the policy and
      what it refuses/allows; one sentence on why the callback compares nothing
      (`handle_remote_auth` hands it the original remote URL, so a comparison would
      compare the original with itself); one sentence that keying the PAT by port is
      deliberately not done, for the same reason; and a pointer to the gating suite as the
      only thing that can see this rule.
- [x] Prove the pin bites: temporarily delete the assignment, run
      `swift test --filter LibGit2FetchSourceGatingTests`, record the failing test names
      and messages, restore the line (`git diff` clean for that file), re-run green.
- [x] Gates: `swift test`; `swiftlint --strict`; `xcodegen generate`;
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`.

### Task 2: A bounded write queue for language servers

**Files:**

- Create: `Sources/PisakaCore/LSPWriteBudget.swift`
- Create: `Tests/PisakaCoreTests/LSPWriteBudgetTests.swift`
- Modify: `Sources/Pisaka/LSPProcessTransport.swift`
- Modify: `Tests/PisakaCoreTests/LSPSourceGatingTests.swift`
- Modify: `docs/architecture/core-lsp.md`, `CLAUDE.md`

- [x] Read `core-lsp.md`'s `LSPTransport.swift`/`LSPSession.swift` entries and D7 before
      editing.
- [x] Write `LSPWriteBudget`: a `public struct` in Core with
      `public static let defaultCeiling = 32 * 1024 * 1024` (the reason beside it — a 1 MB
      file re-synced whole thirty times over, half the incoming `Content-Length` cap),
      `let ceiling`, `private(set) var pendingByteCount`,
      `mutating func admit(_ byteCount: Int) -> Admission` and
      `mutating func drain(_ byteCount: Int)`. `Admission` is a two-case enum
      (`queued`, `overCeiling`). Rules, each stated in the doc comment:
      nothing pending → always `queued` whatever the size (one big document is not a dead
      server); otherwise `overCeiling` when `pendingByteCount + byteCount > ceiling`, and
      an `overCeiling` message is **not** counted as pending (it was never queued);
      `drain` clamps at zero.
- [x] Write `LSPWriteBudgetTests` first against those rules: the ceiling crossed by
      repeated admits with no drains; the *same total volume* admitted with a drain after
      each admit never crosses; the first admit is accepted at any size, including one
      larger than the ceiling; a message that crosses leaves `pendingByteCount` unchanged;
      `drain` past zero clamps; the default ceiling's value is pinned.
- [x] Wire the transport: `LSPProcessTransport` gains `private var writeBudget` guarded by
      the existing `lock`. `send(_:)` admits `data.count` under the lock after its
      `isStopped` check; on `.overCeiling` it calls `finishStream()` and returns without
      queueing anything — the same call the failed-write path already makes, no throw and
      no new `LSPTransportError` case. The write-queue block drains `data.count` under the
      lock after the write attempt, on both the success and the failure path.
- [x] Update `send(_:)`'s doc comment: what the ceiling is, that crossing it is read as the
      server's death, and that `LSPWorkspace` (D7) owns everything after.
- [x] Add `LSPWriteBudget.swift` to `LSPSourceGatingTests.expectedCoreFiles` (a set
      equality — the suite fails until this is done).
- [x] `ScriptedLSPTransport` is untouched, and the plan says why in its own comment if one
      is warranted: the fake never blocks, so it has no backlog to bound.
- [x] `core-lsp.md`: a `LSPWriteBudget.swift` line under Files; **D39** in the Decisions
      section stating the ceiling and its reason, the death mapping, why a request timeout
      does not count (it fails one request and `didChange` has no reply at all, so nothing
      in the existing machinery can ever notice this), why coalescing is not done, and the
      deliberate non-change of the incoming streams with its reason. Add the incoming-stream
      non-change to Known limits as well.
- [x] `CLAUDE.md`: one index line for `LSPWriteBudget.swift` under `core-lsp.md`.
- [x] Gates: `swift test`; `swiftlint --strict`; `xcodegen generate`;
      `xcodebuild … -destination 'platform=macOS' build`;
      `xcodebuild … -destination 'platform=macOS' test` (the app-layer bundle).

### Task 3: The SQL scanner leaks

**Files:**

- Modify: `Vendor/TreeSitterSql/src/scanner.c`
- Modify: `Vendor/TreeSitterSql/VENDORED.md`

- [x] Check upstream first: fetch the newest tag of the SQL grammar and diff its
      `src/scanner.c` against the vendored `v0.3.11` copy. If any of the three defects is
      already fixed there, port that hunk **verbatim** and record the upstream tag and
      commit in `VENDORED.md`. Record the outcome of this check either way (including
      "upstream unreachable / no newer tag", if that is the answer).
- [x] Otherwise author the three fixes, each marked in the source the way the highlight
      query's are (a short `// Local fix (see VENDORED.md)` at the site):
      - the `DOLLAR_QUOTED_STRING` branch: `free(start_tag);` before the early
        `return false` taken when it equals `state->start_tag`;
      - `deserialize`: free the previous `state->start_tag` before setting it to `NULL`;
      - `serialize`: `size_t tag_length = strlen(state->start_tag) + 1;`, the existing
        `>= TREE_SITTER_SERIALIZATION_BUFFER_SIZE` refusal (`return 0`) kept and now
        without the narrowing, with the return converted at the `return` where the guard
        has already bounded it.
- [x] Do not change anything else in the file: no reformatting, no unrelated tidying — a
      vendored file's diff against upstream must stay readable.
- [x] `VENDORED.md`: move `src/scanner.c` out of "Copied **verbatim** from the git tag"
      into "Written **in this repository** (or modified from upstream)", with one sentence
      per fix; add to the update procedure the step that re-copies `scanner.c` and
      re-applies the marked fixes, and drops them once upstream carries them.
- [x] Leak-check with a scratch driver **outside the repository** (e.g. under `$TMPDIR`):
      a small C main that provides the `TSLexer` shim the scanner needs, drives the
      dollar-quoted-string branch to the early return and the serialize/deserialize round
      trip, and is run under `leaks --atExit -- ./driver` (LeakSanitizer's `detect_leaks`
      is unavailable on this platform; `leaks` is the equivalent). Run it against the
      pre-fix file and the post-fix file and record both leak counts — non-zero before,
      zero after. Nothing from the driver is committed.
- [x] Run the package's own verification steps from `VENDORED.md`: re-derive the capture
      set and reconcile `VendoredGrammarQueryTests`, check
      `Resources/Queries/sql/symbols.scm` against `SymbolQueryTests`, and
      `swift build --package-path Vendor/TreeSitterSql`.
- [x] Gates: `swift build --package-path Vendor/TreeSitterSql`; `swift test`;
      `swiftlint --strict`; `xcodegen generate`; the macOS and iOS Simulator builds (the
      grammar links on both destinations).

### Task 4: Downloads bounded by the pinned byte count

**Files:**

- Modify: `Sources/PisakaCore/LSPInstallEngine.swift`
- Modify: `Sources/PisakaCore/LSPProvisioningManifest.swift`
- Modify: `Sources/Pisaka/LSPDownloadService.swift`
- Modify: `Tests/PisakaCoreTests/Support/ScriptedInstallSeams.swift`
- Modify: `Tests/PisakaCoreTests/LSPInstallEngineTests.swift`
- Modify: `docs/architecture/core-provisioning.md`, `CLAUDE.md`

- [ ] Read `core-provisioning.md`'s D14 and its Known limits before editing.
- [ ] Change the seam to `func data(from url: URL, maximumByteCount: Int) async throws -> Data`
      and rewrite its doc comment: the maximum is the manifest's pin, it is a bound on
      bytes **actually received** and never on `Content-Length`/`expectedContentLength`
      (a chunked response reports −1 and a header can lie), and the peak resident cost of
      one artifact stays the stated limit.
- [ ] `LSPInstallEngine`: pass `artifact.byteCount` as the maximum, and after the seam
      returns refuse `archive.count > artifact.byteCount` with
      `LSPInstallError.downloadFailed(component:reason:)` carrying a plain sentence, before
      the digest. Its comment states the split — the app-side cutoff protects memory, this
      refusal is the decision, and no tolerance is needed because a body of any other
      length can never match the pinned digest.
- [ ] `LSPProvisioningManifest`: correct the `byteCount` doc comment — it is the enforced
      download ceiling as well as the size shown in the Settings row.
- [ ] `LSPDownloadService`: stream the response with a `URLSessionDataDelegate` that
      appends each chunk and cancels the task the moment the accumulated count exceeds the
      maximum; one session per request built from the existing configuration, its own
      delegate, `finishTasksAndInvalidate()` when the request ends. Add a
      `Failure.tooLarge` case whose `errorDescription` is a bare reason phrase, matching
      the file's existing convention. Keep the status/`notHTTP` checks, the ephemeral
      no-cache configuration and the two timeouts exactly as they are, and update the file's
      doc comment where it describes `data(from:)` and the unbounded peak.
- [ ] **Map the delegate's own cancellation to `tooLarge`, explicitly.** Cancelling the
      task makes URLSession complete the request with `URLError.cancelled`, and that word
      — not the size — is what would otherwise reach `LSPInstallError.downloadFailed` and
      the Settings row. So: the delegate **records the over-limit reason** on itself (a
      flag/reason it sets before calling `cancel()`), and the completion path checks that
      record first — when the delegate cancelled for the maximum, the seam throws
      `Failure.tooLarge` and **never** `URLError.cancelled` for this case. A cancellation
      the delegate did not cause (a genuine external one) keeps its own error unchanged.
      Both halves of this rule go in the file's doc comment.
- [ ] `ScriptedDownloader`: take the maximum, record it per request (so a test can assert
      the engine handed over `artifact.byteCount`), and **deliberately not enforce it** —
      with a comment saying it stands in for a server that ignores what it was asked for,
      which is exactly what Core's refusal has to catch. It runs no URLSession, so the
      cancellation-mapping rule above is not visible to it and lives in the doc comment.
- [ ] Tests in `LSPInstallEngineTests`: a scripted download returning more bytes than the
      pin fails as `.downloadFailed`, installs nothing and leaves no staging directory
      behind; a download of exactly the pinned bytes with the right digest installs as
      before; the maximum handed to the seam equals the artifact's `byteCount`.
- [ ] Prove the new test bites: temporarily remove the engine's size refusal, run
      `swift test --filter LSPInstallEngineTests`, record the failing test name and
      message, restore, re-run green.
- [ ] `core-provisioning.md`: amend D14 (the seam carries a maximum; who counts and who
      decides; why not a file; and that a delegate-caused cancellation surfaces as the
      size failure rather than as "cancelled"), replace the "the peak is bounded by what
      the server sends" known limit with the new rule, and keep the ~53 MB peak-resident
      limit, which is still true. `CLAUDE.md`'s provisioning invariant gains the clause
      that the pinned size is now enforced, not only displayed.
- [ ] Gates: `swift test`; `swiftlint --strict`; `xcodegen generate`;
      `xcodebuild … -destination 'platform=macOS' build`.

### Task 5: Verify acceptance criteria

- [ ] `swift test` — full Core suite green.
- [ ] `swiftlint --strict` from the repository root — clean.
- [ ] `xcodegen generate`.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`
      — the app-layer bundle.
- [ ] `swift build --package-path Vendor/TreeSitterSql`.
- [ ] `LSPSourceGatingTests` green with no new exception — the transport is still the only
      app file with `Process`, the downloader still the only one with `URLSession`, and
      `Sources/PisakaCore/LSPWriteBudget.swift` is in `expectedCoreFiles`.
- [ ] Grep the whole diff for product or brand names — none in code, comments, tests, docs,
      the plan or the commit messages.
- [ ] Record every result, plus the two "prove it bites" runs (Task 1's redirect pin,
      Task 4's ceiling) and Task 3's before/after leak counts, in this plan's Notes.

### Task 6: Update documentation

- [ ] `docs/architecture/app-ios.md` — the redirect policy, the one sentence on why the
      callback compares nothing, and the port-keying non-decision.
- [ ] `docs/architecture/core-lsp.md` — D39, the `LSPWriteBudget.swift` file entry, the
      incoming-stream non-change under Known limits.
- [ ] `docs/architecture/core-provisioning.md` — D14 amended (including the
      cancellation-to-`tooLarge` mapping), the size-limit known limit replaced.
- [ ] `Vendor/TreeSitterSql/VENDORED.md` — `scanner.c` listed as modified, update
      procedure adjusted.
- [ ] `CLAUDE.md` — the `LSPWriteBudget.swift` index line and the provisioning invariant's
      "pinned size is enforced" clause. No new essays; the index stays an index.
- [ ] `README.md` — confirm no change is needed (nothing here is user-facing) and leave it
      alone if so.

## Post-Completion (manual)

- **Live reproduction of the write bound — the reviewer's step, during the acceptance
  review.** There is no user-facing way to register a language server: `LSPServerRegistry
  .standard` is code, and every other entry arrives through provisioning. So the scratch
  "server" gets in through a **temporary, uncommitted edit** in a DEBUG build — either an
  extra `LSPServerDescription` added to the registry, or the existing lookup pointing at
  the scratch script's path instead of the real executable — reverted afterwards, with
  `git diff` clean before anything is pushed. The script answers `initialize` and then
  stops reading its stdin. With it registered, open a large file and edit it until the
  queue passes the 32 MiB ceiling; observe the workspace retiring that `(server, root)`
  through D7 (the restart budget spent, diagnostics cleared, answers falling back
  silently) with the app's memory flat afterwards rather than still climbing. Record what
  was **observed**, not inferred, in Notes at that point.
- **A real install still works.** From Settings, install one small server end to end on the
  reviewer's machine and record the artifact name and the outcome.
- Open a pull request and confirm CI is green on all four jobs (`swift test`, the macOS
  job, the iOS build, `lint`).

## Notes

### Task 1 — off-site redirects refused on the iOS fetch

- **The pin bites.** With `options.follow_redirects = GIT_REMOTE_REDIRECT_NONE` deleted
  from `LibGit2Service.fetch`, `swift test --filter LibGit2FetchSourceGatingTests` failed
  on `testFetchRefusesOffSiteRedirects`:
  `XCTAssertEqual failed: ("0") is not equal to ("1")`, carrying the assignment's whole
  reason. The other two tests — the loud-vacuity guard and the permissive-constant ban —
  stayed green, which is correct: neither is the rule. Line restored, `git diff` shows
  only the intended change, all three green again.
- **Gates:** `swift test` — 5286 tests, 0 failures. `swiftlint --strict` — 0 violations
  in 518 files. `xcodegen generate` — project written. iOS Simulator build (iPhone 17
  Pro, derived data under `~/Library/Developer/Xcode/DerivedData/pisaka-audit-ios`) —
  **BUILD SUCCEEDED**, which is also what typechecks the assignment (the file is
  `#if os(iOS)`, so no other gate compiles it at all).

### Task 2 — a bounded write queue for language servers

- **What landed.** `LSPWriteBudget` (Core, pure: `defaultCeiling` 32 MiB, `admit` /
  `drain`, `Admission` with two cases) plus `LSPWriteBudgetTests`; the applier is
  `LSPProcessTransport.send(_:)`, which admits `data.count` under the existing lock after
  the `isStopped` check, calls `finishStream()` and returns without queueing on
  `.overCeiling`, and drains `data.count` under the lock on both the success and the
  failure path of the write. No new `LSPTransportError` case, no throw, no counter.
  `ScriptedLSPTransport` is untouched and now says why in its own doc comment above
  `send(_:)`. D39, the file entry and the incoming-stream non-change are in `core-lsp.md`
  (the Known-limits entry included); `CLAUDE.md` carries the index line and its D-range now
  reads D17–D39.
- **Gates:** `swift test` — 5292 tests, 0 failures (up from 5286 by the six new budget
  tests). `swiftlint --strict` — 0 violations in 520 files. `xcodegen generate` — project
  written. `xcodebuild … -destination 'platform=macOS' build` (derived data under
  `~/Library/Developer/Xcode/DerivedData/pisaka-audit`) — **BUILD SUCCEEDED**, which is what
  typechecks the wiring.
- **The app-layer bundle did not run here, and the reason is not this change.**
  `xcodebuild … -destination 'platform=macOS' test` fails with
  `Pisaka (…) encountered an error (The test runner hung before establishing connection.)`
  after ~330 s of "Testing started". It was run three times, then run once more against the
  **stashed tree** (Task 1's committed state, none of this task's files present) into a
  separate derived-data root: it fails there identically, so this is the environment — a
  non-interactive session with no window server for a GUI host app — and not a regression.
  Nothing in `PisakaAppTests` covers the transport in any case (it owns `Process`, which
  this repository does not unit-test). CI's macOS job is where that bundle is really
  gated; Task 5 records it again, and the pull request is the honest verdict.

(filled in during execution: the redirect pin's failing test names with the assignment
removed; the write-budget live reproduction, recorded by the reviewer during the acceptance
review; the scanner's before/after leak counts and whether the fix came from upstream; the
download ceiling's failing test name with the refusal removed; the real install's artifact
name; the full gate run.)
