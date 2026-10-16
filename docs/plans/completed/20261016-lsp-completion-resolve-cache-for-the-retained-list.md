# LSP completion: resolve cache for the retained list, two doc corrections

## Overview

Local narrowing (D40) answers a keystroke inside the same word from the retained list, with no request. But each narrowed answer is a new `publish`, so it carries new resolve handles. The controller's `apply` then forgets its per-list `resolved` table and prefetches `completionItem/resolve` for the top five rows again. With sourcekit-lsp nearly every item needs a resolve, so each narrowed keystroke can send up to five resolves and five `$/cancelRequest`s. That is more traffic than the single debounced request narrowing replaced.

This plan:

- Adds a resolve cache to `LSPIntelligenceProvider`, owned by the retained list. A narrowed row whose server item was already resolved, or is being resolved, for the same retained list is answered from that cache with no second round trip.
- Corrects two stale sentences: one bullet in the completed plan, and the Enter rule in `FEATURES.md`.

The controller does not change. It still clears its own table and prefetches on every shown answer. The provider is what makes the second prefetch free. `CodeIntelligenceProviding` gets no new seam.

## Context

- Files involved:
  - `Sources/PisakaCore/LSPIntelligenceProvider.swift`: `PendingResolve`, `RetainedList`, `publish`, `completionAnswer(for:)`, `narrowedList`, `resolveEdits(for:)`, `retain`, and the class doc comment, which says the only mutable state is the resolve table.
  - `Tests/PisakaCoreTests/LSPIntelligenceProviderTests.swift`: the narrowing tests near `testANarrowedHandleResolvesWhatAFreshHandleResolves`, using the existing `narrowingItems()`, `narrowingResolve` and `narrowingRequest(_:)` helpers.
  - `Tests/PisakaCoreTests/Support/ScriptedLSPTransport.swift`: used as is (`requests(for:)`, `.fail`, the `onSend` hook, and the rule that an unscripted method is never answered).
  - `docs/architecture/core-lsp.md`: D40 and the `LSPIntelligenceProvider` entry (the retained-list paragraph and the "mutable state is the small resolve table" sentence).
  - `docs/architecture/app-editor.md`: the controller's "Local narrowing" paragraph.
  - `docs/FEATURES.md`: the Enter sentence near line 506.
  - `docs/plans/completed/20261015-lsp-completion-local-narrowing-tiered-ranking-suffix-aware-commit-server-failure-record.md`: the Task 4 bullet at line 261.
- Related patterns:
  - The provider's lock discipline: every access to shared state goes through a synchronous helper that takes `NSLock` and never holds it across an `await`.
  - The retained slot's ordering: `retain` replaces the list only for a newer token.
  - `Self.shifted(_:from:to:)` re-expresses edits for a narrowed word length.
  - Async tests use `Gate` / `waitFor`, never timed sleeps; the `onSend` + `Gate` hold pattern (as in the `foldRegions` folder-switch test) stages a request in flight.
- Dependencies: none.

## Design decisions

- **Cache key.** `(retained list handle, index of the item in the retained raw items)`.
  - The list handle is the list token under which the list was retained.
  - The index is the `enumerated()` offset `publish` already sorts by, so it is stable across every `publish` of the same raw items.
  - `PendingResolve` gains an optional key. `publish` takes the retained handle as an optional parameter and records each deferred item's raw index under it:
    - `completionAnswer(for:)` passes its `listToken` when the response is complete (`isIncomplete == false`).
    - `narrowedList` passes `list.handle`.
    - Every other path passes `nil`, so its pending resolves have no key.
- **What is cached.** The resolved `LSPCompletionItem`. `resolveEdits(for:)` keeps building the edits exactly as today:
  - the primary edit comes from the published item;
  - the additional edits are `resolved.additionalTextEdits ?? pending.item.additionalTextEdits`, against the retained text and typed word;
  - the result is then shifted to the handle's own `narrowedLength`.

  So a cached answer differs from a fresh one only in skipping the round trip. Every resolve of one retained list shares the same text and typed word, which is why one resolved item serves every narrowing of it.
- **Where the cache lives and how it is bounded (R4).**
  - It is a `ResolveCache` value next to `retainedList`: the list handle, `resolved: [Int: LSPCompletionItem]` and `inFlight: [Int: Task<LSPCompletionItem?, Never>]`.
  - `retain` replaces it together with the slot: an empty cache for a new list, `nil` when nothing is retained.
  - A key whose list handle is not the current cache's bypasses the cache and resolves directly, exactly as today. This covers a superseded list, a trimmed or incomplete answer that was never retained, and every fallback answer.
  - So the cache never holds more than one entry per item of the one retained list, and it is dropped with that list.
- **In-flight resolves are deduplicated, option (a) (R3).**
  - On a miss, the provider creates one unstructured `Task` that runs `session.resolveCompletionItem`. It registers the task under the lock before awaiting it, so a second caller asking for the same key awaits the same task instead of sending its own request.
  - When the task completes:
    - a non-`nil` result is stored in `resolved`, but only if the cache still belongs to that list handle;
    - the `inFlight` entry is removed either way;
    - a failure or a timeout (`nil`) is therefore not cached, and the next ask tries again.
  - Why (a) and not (b): a narrow typically arrives while the previous keystroke's prefetch is still in flight. The controller has just cancelled that prefetch, and with (b) the session would send `$/cancelRequest` and then the same resolve again, which is the exact traffic this ticket removes.
  - The cost, stated in the doc: a resolve that goes through the cache is owned by the provider, not by the caller. Cancelling the caller no longer sends `$/cancelRequest`, and the request runs until it is answered or the 1.5 s resolve budget expires. This is acceptable for three reasons:
    - it is bounded by that budget;
    - the next narrow is the caller most likely to want it;
    - the controller already discards a cancelled task's result (`startResolve` checks `Task.isCancelled` and the generation).
  - Resolves without a key keep today's cancellation behaviour.
- **Doc home.** D40 gains the sentence about the resolve cache, because the cache is a property of the retained list rather than of auto-import. The provider's file entry in `core-lsp.md` gains the mechanics and the in-flight cost.

## Development Approach

- **Testing approach**: TDD for Task 1. Write the acceptance tests first, see them fail on the resolve count, then implement.
- Complete each task fully before moving to the next.
- Every decision stays in `PisakaCore`. No app-layer source changes.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Resolve cache owned by the retained list

**Files:**
- Modify: `Sources/PisakaCore/LSPIntelligenceProvider.swift`
- Modify: `Tests/PisakaCoreTests/LSPIntelligenceProviderTests.swift`

- [x] Add tests (they should fail before the implementation):
  - **One resolve across three steps.** `fo` (request), then `foob` (narrow), then `fooba` (narrow), against a complete answer with a deferring item, resolving the top row after each step. `transport.requests(for: LSPMethod.resolveCompletionItem).count == 1`. The edits after the second and third steps equal what a fresh provider resolves for a fresh request at `foob` and at `fooba`, so the ranges are re-expressed for the longer word. Follow the `testANarrowedHandleResolvesWhatAFreshHandleResolves` pattern.
  - **A newer complete answer starts a fresh cache.** After a resolve, a fresh `completionAnswer(for:)` followed by resolving the same label costs exactly one more resolve.
  - **A failure is not cached.** Script `.fail(…)` and then `.reply(…)` for the resolve. The first resolve answers `[]`, and the next ask on a narrowed row sends a second request and answers the edits.
  - **A timeout is not cached.** Leave the resolve unanswered under the `quick` budgets so the first ask times out with `[]`, then script a reply. The next ask sends a second request.
  - **In-flight dedup.** Use the existing `onSend` + `Gate` pattern (as in the `foldRegions` folder-switch test): hold the first resolve's send in `onSend` with `gate.wait()`, start the first `resolveEdits`, `await gate.waitUntilReached()`, only then start a second `resolveEdits` for the same item through the narrowed handle, and wait on the provider's `internal` join count (`joinedResolveCount == 1`) as the causal signal that the second caller joined the in-flight resolve; then release the gate and await both. Assert exactly one `completionItem/resolve` request on the transport and two equal, non-empty answers. The join count is needed because a wire-only observation (counting `completionItem/resolve` sends) would pass just as well if the second caller were answered from a finished cache entry, so it cannot prove the two callers shared one in-flight resolve.
  - **The existing superseded-handle test stays green.** `testAHandleFromASupersededListResolvesToNothing` still holds: a handle the shown and staged tables no longer hold answers `[]` before the cache is consulted.
- [x] Give `PendingResolve` an optional cache key (list handle, raw index). Give `publish` an optional `retainedHandle` parameter and record `entry.offset` under it for each deferred item. Pass `listToken` from `completionAnswer(for:)` when the response is complete, and `list.handle` from `narrowedList`.
- [x] Add the `ResolveCache` state beside `retainedList`, and replace it inside `retain`, under the same token check as the slot.
- [x] Add synchronous, lock-taking helpers for the cache: look up the result or the in-flight task, or register a new task; and complete a key by storing or dropping its result and removing its in-flight entry. Each helper checks that the cache still belongs to the key's list handle.
- [x] Change `resolveEdits(for:)` so it obtains the resolved item through the cache when the key matches the current cache, and through a direct `try? await` otherwise. Leave the edit construction and the `shifted` call unchanged.
- [x] Update the class doc comment's "only mutable state" sentence and the `PendingResolve` / `RetainedList` doc comments so they name the cache, its bound and the in-flight ownership cost.
- [x] Run `swift test`. It must pass before Task 2.

### Task 2: Documentation corrections and the cache's doc entries

**Files:**
- Modify: `docs/architecture/core-lsp.md`
- Modify: `docs/architecture/app-editor.md`
- Modify: `docs/FEATURES.md`
- Modify: `docs/plans/completed/20261015-lsp-completion-local-narrowing-tiered-ranking-suffix-aware-commit-server-failure-record.md`

- [x] **`core-lsp.md`:**
  - D40 gains one sentence: a resolve belongs to the retained list, so a narrowed row's resolve is answered from the list's cache with no second round trip.
  - The `LSPIntelligenceProvider` entry's retained-list paragraph gains the mechanics:
    - the key (list handle and raw index);
    - what is cached and how it is re-expressed through `narrowedLength`;
    - the bound and when the cache is dropped;
    - that a failure or a timeout is not cached;
    - the in-flight dedup, and its cost that a resolve going through the cache is not cancelled by its caller and is bounded by the resolve budget.
  - The "mutable state is the small resolve table" sentence names the cache too.
- [x] **`app-editor.md`:** the "Local narrowing" paragraph says that the prefetch on a narrowed answer still runs and is answered from the provider's cache, not by the server.
- [x] **`FEATURES.md`:** reword the Enter sentence:
  - Enter replaces the rest of the word only when the server's edit range reaches past the caret and the completion ends with that rest.
  - An item without a server range replaces only the typed prefix on Enter and leaves the rest of the identifier standing.
  - Keep both examples, and keep the statement that Tab replaces the whole identifier.
- [x] **Completed plan:** rewrite line 261's bullet, and nothing else in that file, to: "the new word extends or equals the answered one; a backspace below the answered word asks again". The surrounding bullets already state the same word start and a non-empty word.
- [x] Run `swift test`, which includes `LintConfigurationTests`' doc-shape checks. `grep -rn "non-empty prefix[ ]of it" docs/plans/completed/` must find nothing.

### Task 3: Verify acceptance criteria

- [x] Run `swift test`: green.
- [x] Run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`: green, except for the pre-existing scale-1.8 layout assertions already recorded in the merged plan. (316 tests; the only 8 failures are those scale-1.8 assertions in BottomBarLayoutTests, BottomBarToolTipTests, ChromePopoverLayoutTests and CommitDialogLayoutTests.)
- [x] Run `swiftlint --strict` from the repository root: clean, with no in-file disables.
- [x] Confirm that acceptance criteria 1–3 map to the Task 1 tests, and 6–7 to the Task 2 edits.
- [x] Confirm that `CLAUDE.md` is unchanged and still under its 60,000-character limit.

### Task 4: Update documentation

- [x] `README.md`: no user-facing change beyond the `FEATURES.md` correction. Confirm that it has no stale copy of the Enter sentence. (Confirmed: README.md has no Enter/rest-of-word sentence.)
- [x] `CLAUDE.md`: no change needed. The resolve cache adds no new file, and the cross-cutting invariants do not mention it.
