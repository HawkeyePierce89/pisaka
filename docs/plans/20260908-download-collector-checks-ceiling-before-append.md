# The download collector checks the ceiling before it appends

## Overview

`BoundedBodyCollector` in `Sources/Pisaka/LSPDownloadService.swift` enforces D14's
ceiling in the wrong order: it appends the arriving chunk to `body` first and compares
the running total to `maximumByteCount` afterwards. The chunk that crosses the line is
therefore resident before the transfer is stopped, and when it does not fit the capacity
reserved for the pin, `Data` reallocates — old buffer, new buffer and chunk alive at
once. Nothing about the install's integrity depends on this (Core re-refuses anything
longer than the pin before the digest, and `LSPInstallEngineTests` pins that), but two
doc sites promise the opposite: the comment beside `reserveCapacity` says appending never
transiently holds two buffers, and `core-provisioning.md`'s Known limits repeats it.

This plan reverses the two lines — compute what is still allowed, refuse without
appending when the chunk does not fit — keeps the ceiling inclusive, updates every doc
site that states the rule, and gives the collector the one test that can see the order.
That test goes in `Tests/PisakaAppTests`, the headless app-layer bundle, driving the
`URLSessionDataDelegate` methods directly: no network, no server, a data task created and
never resumed as the thing to cancel. Today `core-provisioning.md` says outright that
nothing in the pipeline can see this rule; after this plan that sentence is false and is
replaced by the suite's name.

Behaviour visible to a user does not change: an over-limit response still fails as
`tooLarge`, a body of exactly the pin still returns whole.

## Context

- Files involved:
  - `Sources/Pisaka/LSPDownloadService.swift` — the collector (`urlSession(_:dataTask:didReceive:)`,
    the `reserveCapacity` comment, the class doc comments describing "appends each chunk
    and cancels … the moment the running total passes").
  - `Tests/PisakaAppTests/BoundedBodyCollectorTests.swift` — new.
  - `docs/architecture/core-provisioning.md` — four sites: the `LSPDownloadService.swift`
    file entry (~l.594, which also still says "untested by repository convention"), D14's
    "Who counts and who decides" paragraph (~l.997–1020, including the sentence that no
    test can see the cancellation/ceiling rule), the Known-limits bullets on the whole-in-memory
    peak (~l.1332) and on the cap (~l.1355), and the layer's Tests inventory (~l.1434+).
  - `CLAUDE.md` — the Tests section's one-sentence description of what `Tests/PisakaAppTests`
    covers.
  - `project.yml` — unchanged; the `PisakaAppTests` target already takes
    `sources: [Tests/PisakaAppTests]` wholesale, so only `xcodegen generate` is needed to
    pick up a new file.
- Related patterns:
  - `Tests/PisakaAppTests/FoldLayoutTests.swift` / `GutterFoldTests.swift` — the bundle's
    shape: `#if os(macOS)`, `import XCTest`, `@testable import Pisaka`, headless, no UI
    automation. The documented, flag-free `xcodebuild -project Pisaka.xcodeproj -scheme
    Pisaka -destination 'platform=macOS' test` runs it (proved in the 20260906 plan).
  - `Tests/.swiftlint.yml` relaxations already cover the test tree.
  - `LSPSourceGatingTests` sweeps `Sources/Pisaka` only, so a new test file adds no
    exception there; the downloader stays the single app file naming `URLSession` in
    `Sources/`.
- Dependencies: none. No change to `LSPArtifactDownloading`, to Core's own size refusal,
  or to `ScriptedDownloader`.
- Explicitly out of scope: streaming to disk, connection reuse across artifacts, Swift-task
  cancellation of the transfer (all standing known limits under D14), and keying credentials
  by port on the iOS fetch.

## Development Approach

- **Testing approach**: Regular (code first, then the app-layer test) — the order matters
  here because the test's `@testable` reach depends on the visibility the fix settles, and
  the "prove it bites" step then re-introduces the old order deliberately.
- Complete each task fully before moving to the next; every gate green before the next task.
- Per `CLAUDE.md`: read `core-provisioning.md`'s D14 before touching the file, and update it
  in the same task as the code.
- **CRITICAL: every task that changes behaviour ships new/updated tests.**
- **CRITICAL: all tests pass before the next task starts.**
- No `-derivedDataPath` inside the repository — the documented commands are flag-free and
  use the default DerivedData location, which is already outside the tree.
- No product or brand name anywhere: code, comments, tests, docs, this plan, commit messages.

## Implementation Steps

### Task 1: The collector measures the chunk against what is left, then appends

**Files:**
- Modify: `Sources/Pisaka/LSPDownloadService.swift`
- Modify: `docs/architecture/core-provisioning.md`

- [x] Read D14 in `docs/architecture/core-provisioning.md` end to end before editing the
      Swift file, including the two Known-limits bullets it owns.
- [x] In `urlSession(_:dataTask:didReceive:)`: under the existing lock, compute the room
      still allowed (`maximumByteCount - body.count`); when the chunk is longer than that,
      record `.tooLarge` (keeping the existing `refusal = refusal ?? …` first-reason rule),
      drop the body and cancel outside the lock **without appending**; only a chunk that
      fits is appended. The ceiling stays **inclusive** — a chunk exactly filling the
      remaining room is appended and kept.
- [x] Leave untouched: the response-status/`notHTTP` refusals and their `.cancel`
      dispositions, the record-before-cancel rule, the completion path that prefers a
      recorded refusal over the completion's error, the ephemeral no-cache configuration,
      both timeouts and the seam's signature.
- [x] Update the doc comments in that file so they state the new order rather than the old
      one: the class doc's "appends each chunk and cancels … the moment the running total
      passes", the `BoundedBodyCollector` doc's "it appends, it counts", and the
      `reserveCapacity` comment — which is the promise this task exists to keep, so it now
      says the check precedes the append and the peak resident cost is the pinned size and
      never more.
- [x] `core-provisioning.md`, same task: amend the D14 "Who counts and who decides"
      paragraph (the delegate measures each chunk against what is still allowed and refuses
      without holding it), the `LSPDownloadService.swift` file entry, and the whole-in-memory
      Known-limits bullet whose current sentence about reserving the pin "so appending does
      not transiently hold two buffers" is the claim being made true. Leave the cap bullet's
      substance alone except where it repeats the append-first wording.
- [x] `swift test` (Core gate, must stay green — no Core file is touched, so this is a
      regression check) and `swiftlint --strict` from the repository root.

### Task 2: The collector gets a headless test in the app-layer bundle

**Files:**
- Modify: `Sources/Pisaka/LSPDownloadService.swift` (visibility only)
- Create: `Tests/PisakaAppTests/BoundedBodyCollectorTests.swift`

- [x] Widen visibility only as far as the bundle needs: `BoundedBodyCollector` becomes
      `internal` (drop the file-private `private`), plus lock-taking read accessors for the
      two things the rule is observed through — the bytes it currently holds and the refusal
      it has recorded. Nothing becomes `public`, nothing is added to Core, and the
      accessors are documented as existing for the bundle's sake.
- [x] New suite, in the bundle's shape (`#if os(macOS)`, `import XCTest`,
      `@testable import Pisaka`, no UI automation, no `@MainActor` — the delegate callbacks
      are nonisolated): a small helper builds a `URLSession` from the ephemeral
      configuration with the collector as delegate and creates a data task for a loopback
      URL that is **never resumed** (cancelling an unresumed task is harmless), invalidating
      the session in `defer`; a second helper makes a 200 `HTTPURLResponse`. Callbacks are
      then fed the way URLSession would: response, chunks, completion.
- [x] The four cases, each an assertion of the rule and not of the network:
      (1) a chunk that exactly fills the maximum is appended and the body comes back whole
      at completion — the inclusive ceiling;
      (2) a chunk that would exceed the maximum is **not appended**: read synchronously,
      immediately after the callback and before any completion, the held body is empty and
      the recorded refusal is `tooLarge` — this is the case that sees the order;
      (3) that same self-caused cancel, followed by URLSession's `URLError.cancelled`
      completion, still resolves the seam as `Failure.tooLarge` and never as "cancelled";
      (4) a completion carrying a foreign `URLError` with nothing recorded resolves as that
      error unchanged.
- [x] Assert the typed failure by pattern match rather than by adding an `Equatable`
      conformance the product code does not otherwise need.
- [x] `xcodegen generate`, then the documented flag-free
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`
      — the whole bundle green, the new cases included.
- [x] **Prove the test bites**: move the check back after the append (the pre-Task-1 order),
      re-run the bundle, record the failing test's name and its message, restore the fix,
      re-run green, and confirm `git diff` shows only the intended change. The failing name
      and message go in this plan's Notes.
- [x] `swiftlint --strict` — clean, including the new test file.

### Task 3: A live run of the real service against a streaming local server

**Files:**
- Temporary, uncommitted only (a scratch server script and a scratch test), removed before
  the task closes.

- [ ] Stand up a loopback HTTP server on an ephemeral port that answers `200` and then keeps
      writing chunks well past any ceiling handed to it — a short raw-socket script is
      enough; nothing in the repository is added for it.
- [ ] Exercise the **real** `LSPDownloadService` (not the collector directly) against that
      URL with a small `maximumByteCount`, through a temporary test in the app bundle, and
      confirm the call throws `Failure.tooLarge` and not `URLError.cancelled` — the mapping
      D14 states, end to end over a real socket.
- [ ] Record in Notes: the command(s), the ceiling used, the observed error, and that the
      transfer stopped at the ceiling rather than at the resource timeout.
- [ ] Delete the scratch server script and the temporary test; `git status` shows nothing
      stray, and the committed tree is exactly Tasks 1–2's changes.
- [ ] If this environment cannot run the bundle against a socket, say so plainly in Notes
      with the observed failure and move the step to Post-Completion — do not report it as
      done.

### Task 4: Verify acceptance criteria

- [ ] `swift test` — full Core suite green; record the test count.
- [ ] `swiftlint --strict` from the repository root — clean; record the file count.
- [ ] `xcodegen generate`.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`
      — the app-layer bundle with the collector's suite, flag-free.
- [ ] `LSPSourceGatingTests` green with no new exception: `Sources/Pisaka` still holds the
      only `URLSession` of this layer and the file is still `#if os(macOS)`.
- [ ] Grep the whole diff for product or brand names — code, comments, tests, docs, plan,
      commit messages.
- [ ] Record every result in this plan's Notes, including Task 2's "prove it bites" run and
      Task 3's live observation.

### Task 5: Update documentation

- [ ] `docs/architecture/core-provisioning.md` — finish what Task 1 started: the layer's
      Tests inventory names the new app-bundle suite and what it pins (the order, the
      inclusive ceiling, the cancellation mapping), and the D14 sentence claiming nothing in
      the pipeline can see these rules is replaced rather than left standing. The cap
      Known-limits bullet keeps its substance; only the append-first wording moves.
- [ ] `CLAUDE.md` — the Tests section's `Tests/PisakaAppTests` sentence gains the collector
      in **one clause**, beside the AppKit overlays. No new essay; the index stays an index.
      The provisioning invariant's "size is enforced, not only displayed" paragraph keeps
      its wording — the enforcement did not change, only the moment it happens.
- [ ] `README.md` — confirm no change is needed (nothing user-facing moves) and say so.
- [ ] Re-run `swift test` and `swiftlint --strict` after the doc edits, since the repository
      suites read documents (`LintConfigurationTests`, `ReleaseWorkflowTests`) and a doc line
      is not automatically inert.

## Post-Completion (manual)

- Open the pull request and confirm CI is green on all four jobs (`swift test`, the macOS
  job — which runs the app-layer bundle before the Release build and launch — the iOS build,
  and `lint`). CI's macOS job is the authority for the bundle if the local run was ever in
  doubt.
- Anything Task 3 could not run here, repeated by the reviewer with the observed error
  recorded.

## Notes

(Filled in as the tasks run: the "prove it bites" failing test name and message, the live
run's ceiling and observed error, and every gate's result.)

### Task 1

- `swift test` — 5296 tests, 0 failures.
- `swiftlint --strict` — 0 violations in 520 files.
- Code: `urlSession(_:dataTask:didReceive:)` now computes `maximumByteCount - body.count`
  under the lock, refuses `.tooLarge` and drops the body without appending when the chunk
  is longer, and appends only a chunk that fits (inclusive ceiling). The response-status
  refusals, the record-before-cancel rule, the completion path, the configuration, both
  timeouts and the seam signature are untouched.
- Docs: the class doc, the collector doc and the `reserveCapacity` comment now state the
  check-then-append order; `core-provisioning.md`'s D14 "Who counts and who decides"
  paragraph, the `LSPDownloadService.swift` file entry and the whole-in-memory Known-limits
  bullet say the same. The cap bullet keeps its substance.

### Task 2

- Visibility: `BoundedBodyCollector` is now `internal` (the file-private `private`
  dropped); three lock-taking read accessors were added — `heldByteCount`,
  `recordedRefusal` and `peakHeldByteCount` — each documented as existing for the
  bundle's sake. Nothing became `public`, nothing was added to Core. Two now-false
  sentences in the file's own doc comments were corrected in the same pass: "It is
  untested by repository convention" and "which is why the rule is stated here and
  beside D14 rather than pinned by a test".
- **Deviation from the plan, with the reason.** The plan expected case (2) — the held
  body read synchronously after an over-limit chunk — to be the case that sees the
  order. It is not: both orders *drop* the body on refusal (`body = Data()`), and the
  two predicates are algebraically identical (`body.count + data.count > maximum` is
  `data.count > maximum - body.count`), so every reading of the final state agrees
  under either order. The only thing that differs is what was *transiently* resident —
  which is exactly the promise the `reserveCapacity` comment makes — so a third
  accessor, `peakHeldByteCount`, was added: a high-water mark of `body.count` updated
  at the append site, and the one observable that tells the two orders apart. It is
  one `max(...)` line in the locked block; nothing else about the collector changed.
- Second deviation: the never-resumed data task is created from a session the collector
  is **not** the delegate of. With the collector as delegate, the `cancel()` the refusal
  performs delivers a real `didCompleteWithError` that can race the completion the test
  feeds and resume the same continuation twice. The collector never reads the session
  argument, so nothing about the rule under test is weakened; the reasoning is in the
  suite's doc comment.
- Five cases, covering the plan's four: the inclusive ceiling
  (`testChunkExactlyFillingTheMaximumIsKeptAndReturnedWhole`), the order
  (`testChunkPastTheMaximumIsRefusedWithoutBeingAppended` and
  `testFirstChunkPastTheMaximumIsNeverResident`), the cancellation mapping
  (`testSelfCausedCancellationResolvesAsTooLargeAndNotAsCancelled`) and the foreign
  error (`testForeignErrorWithNothingRecordedResolvesAsThatError`). The typed failure
  is matched by pattern; no `Equatable` conformance was added.
- `xcodegen generate`, then
  `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`
  — **TEST SUCCEEDED**, 20 tests, 0 failures (5 of them the new suite).
- **Prove it bites** — the append-first order re-introduced verbatim (append, watermark,
  then `body.count > maximumByteCount`), bundle re-run:
  - `testChunkPastTheMaximumIsRefusedWithoutBeingAppended` failed —
    `BoundedBodyCollectorTests.swift:106: XCTAssertEqual failed: ("11") is not equal to ("5")`
    and `:107: XCTAssertLessThanOrEqual failed: ("11") is greater than ("8")`.
  - `testFirstChunkPastTheMaximumIsNeverResident` failed —
    `BoundedBodyCollectorTests.swift:118: XCTAssertEqual failed: ("4096") is not equal to ("0")`.
  - Confirming the deviation above: the `heldByteCount == 0` and `recordedRefusal`
    assertions **passed** under the old order, as did the two async cases. Only the
    watermark bit.
  - Fix restored, bundle re-run: **TEST SUCCEEDED**, 20 tests, 0 failures. `git diff`
    shows one modified file (`Sources/Pisaka/LSPDownloadService.swift`, +47/-6) and one
    new file, nothing else.
- `swift test` — 5296 tests, 0 failures. `swiftlint --strict` — 0 violations in 521 files.
