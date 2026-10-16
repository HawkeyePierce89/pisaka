# LSP completion: local narrowing, tiered ranking, suffix-aware commit, server failure record

## Overview

Completion over a language server becomes immediate and predictable, and two
server-lifecycle gaps are closed:

- A complete server answer (`isIncomplete == false`) is kept and narrowed locally
  as the user keeps typing in the same word. The server is asked again only when it
  said its answer was incomplete, or when the situation is new.
- `FuzzyMatch` gains contiguity and case-awareness keys. Its quality yields a
  closed, ordered match partition that sits above D6's `sortText` order in the LSP
  provider. It is not a filter.
- An item whose primary edit cannot be applied to the request text is dropped when
  the list is built. Dropping anything marks the answer incomplete.
- The replace range of a completion edit reaches past the caret only when the
  inserted text ends with that suffix. `insertReplaceSupport: true` is advertised.
- `CompletionItem` carries a display-only `detail`, drawn dimmed and right-aligned
  in the macOS completion panel.
- Shutdown sends `exit`, closes stdin and waits for the server to leave (bounded by
  one grace) before SIGTERM. Quit runs this polite teardown concurrently through
  `applicationShouldTerminate` → `.terminateLater`, and `terminateNow()` stays as
  the `willTerminate` fallback.
- Each `(server, root)` keeps a bounded stderr ring and its last exit code, in
  memory only. The record is shown passively on the server's row in the LSP
  settings page and is cleared by the next successful handshake. There is no alert,
  banner or toast.

Behaviour improves; nothing is added. There is no new completion source, request
kind, snippet support, code action or inlay hint.

## Context

- Files involved (Core): `Sources/PisakaCore/FuzzyMatch.swift`,
  `CodeIntelligence.swift` (`CompletionItem`, provider seam), `CompletionPopup.swift`,
  `CompletionEditPlan.swift`, `LSPIntelligenceProvider.swift` (`completions(for:)`,
  `publish`, `primaryRange`), `RoutingIntelligenceProvider.swift`,
  `SymbolIntelligenceProvider.swift` (consumer of `FuzzyMatch.Quality`),
  `SymbolIndex.swift` (same), `LSPPositionMap.swift`, `LSPProtocolTypes.swift`
  (`LSPCompletionEdit`, `LSPCompletionList`, client capabilities ~line 1312),
  `LSPTransport.swift`, `LSPSession.swift` (`shutdown()`, `close(reason:)`,
  `Budgets`), `LSPWorkspace.swift` (`shutdownAll()`, `terminateNow()`, failure
  counting / `unavailable`), `LSPProvisioning.swift` (`LSPServerRow`,
  `LSPProvisioningModel`)
- New Core files: `Sources/PisakaCore/CompletionNarrowingRule.swift`,
  `Sources/PisakaCore/LSPServerFailureRecord.swift`
- Files involved (app, macOS): `Sources/Pisaka/CompletionController.swift`,
  `CompletionPanel.swift`, `LSPProcessTransport.swift`,
  `LSPServerSettingsView.swift`, `PisakaApp.swift` (`AppDelegate`, the
  `willTerminate` observer at ~line 1245)
- Tests: `Tests/PisakaCoreTests/FuzzyMatchTests.swift`, `CompletionPopupTests.swift`,
  `CompletionEditPlanTests.swift`, `LSPIntelligenceProviderTests.swift`,
  `LSPPositionMapTests.swift`, `LSPProtocolTypesTests.swift`, `LSPSessionTests.swift`,
  `LSPWorkspaceTests.swift`, `LSPSourceGatingTests.swift`,
  `ChromeThemeSourceGatingTests.swift`, `Support/ScriptedLSPTransport.swift`,
  `Support/Gate.swift`; app bundle `Tests/PisakaAppTests/` (+ `Fixtures/`)
- Docs: `docs/architecture/core-lsp.md` (D6, new D40–D44), `core-intelligence.md`,
  `app-editor.md`, `core-provisioning.md`, `app-shell.md`, `docs/FEATURES.md`,
  `CLAUDE.md`
- Related patterns:
  - `resolveHandle` is the model for an opaque provider-issued token that the
    editor hands back without interpreting.
  - The `LSPWorkspace` `delay` seam is the model for an injectable wait.
  - `CompletionEdit.shifted(afterReplacingTypedWord:withLength:)` already
    re-expresses edits against a grown or shrunk typed word. Local narrowing reuses
    it.
  - `ScriptedLSPTransport` and `Gate` are the tools for causal-rendezvous async
    tests.
- Dependencies: none new.

## Development Approach

- **Testing approach**: Regular (code first, then tests in the same task)
- Complete each task fully before moving to the next.
- Every decision lives in `PisakaCore` and is unit-tested. The controller, the panel
  and the settings view only wire triggers to Core rules.
- Core imports Foundation only. `LSPProtocolTypes` remains the one schema file.
  `Process` stays in `Sources/Pisaka` behind `LSPTransport`.
- Async tests use `Gate`/`waitFor`, never timed sleeps. Grace periods reach Core
  through injectable wait seams.
- Colour reaches views only through existing `ChromeColorRole`s. Read
  `core-theme.md` and `ChromeThemeSourceGatingTests` before editing
  `CompletionPanel.swift` or `LSPServerSettingsView.swift`, and update its pinned
  per-file inventories where they change.
- `swiftlint --strict` stays clean, with no in-file disables.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task** (`swift test`; plus
  `xcodebuild … -destination 'platform=macOS' test` for tasks touching
  `Sources/Pisaka`)

## Implementation Steps

### Task 1: FuzzyMatch — case mismatches, fragments, boundary tier, contiguous placement, partition

**Files:**
- Modify: `Sources/PisakaCore/FuzzyMatch.swift`
- Modify: `Tests/PisakaCoreTests/FuzzyMatchTests.swift`

- [x] Extend `Quality` to the key order `caseMismatches`, `tier`, `fragments`,
  `offBoundary`, `span`, `start`.
  - `caseMismatches` counts matched positions where the query character is
    uppercase and the candidate character is not. It is always 0 for a query
    without uppercase.
  - `tier`: 0 is a case-sensitive prefix, 1 a case-insensitive prefix, 2 a boundary
    match (every contiguous matched run starts on a boundary), 3 a subsequence
    match.
  - `fragments` is the number of contiguous matched runs.
- [x] Replace the `fuzzyTier` constant with `boundaryTier` and `subsequenceTier`.
  Keep `isPrefixMatch`. Prefix tiers keep `offBoundary`/`span`/`start` pinned to
  today's constants, `fragments` is pinned too, and `caseMismatches` is computed for
  the case-insensitive prefix (`abuse` for `aBu` carries one).
- [x] Add a contiguous-run placement before the two existing walks. If the whole
  query occurs case-insensitively as one contiguous run that starts on one of the
  first `maximumInitials` boundaries, take the first such run. Otherwise fall back
  to today's boundary-preferring walk, then the leftmost walk. The allocation gate,
  the start-on-boundary rule and `maximumInitials` are unchanged.
- [x] Add a closed, ordered `FuzzyMatch.Partition`, `Comparable`, built from a
  `Quality?` and the query:
  - Eight matching values: the four tiers mismatch-free, then the same four with at
    least one case mismatch.
  - Then `noMatch`.
  - An empty query maps every candidate to a single partition.
  - Expose a static `partition(of:matching:)` so callers never recompute it.
- [x] Update the type's doc comment: keys, the boundary-tier definition, the
  contiguous-placement rule, and why a lowercase query ranks exactly as before.
- [x] Tests:
  - `buf`: `ArrayBuffer` < `bigUnderFlow` (both tier 2, fragments 1 vs 3).
  - `aBu`: `ArrayBuffer` < `abuse` (the mismatch at `B`).
  - `caseMismatches == 0` for every lowercase query.
  - Contiguous placement beats the split the boundary walk would take.
  - Partition order, including the mismatch half and `noMatch`. The empty query
    gives one partition.
  - Every existing ranking assertion is unchanged; only the `fuzzyTier` references
    move to the new constants (`aXrr`/`axbc_by` → `subsequenceTier`).
- [x] Run `swift test` (`SymbolIntelligenceProvider`/`SymbolIndex` suites must stay
  green). It must pass before Task 2.

### Task 2: LSP list ordering by partition, and `CompletionItem.detail`

**Files:**
- Modify: `Sources/PisakaCore/CodeIntelligence.swift`
- Modify: `Sources/PisakaCore/LSPIntelligenceProvider.swift`
- Modify: `Sources/PisakaCore/CompletionPopup.swift` (doc only, if needed)
- Modify: `Tests/PisakaCoreTests/LSPIntelligenceProviderTests.swift`,
  `CompletionPopupTests.swift`

- [x] In `publish`, replace the two-valued `matched` key with
  `FuzzyMatch.partition(of: filterText ?? label, matching: typed)`. The sort becomes
  partition, then `rankingKey`, then array index. Nothing is filtered, and the cap
  reaches partitions in order. Rewrite the "neither a filter nor a ranking key"
  comment as "a partition, not a filter".
- [x] Add `public let detail: String?` to `CompletionItem`, as an init parameter
  defaulted to `nil`. `publish` passes the server's `detail` and adds no synthesized
  detail. Tree-sitter and iOS construction sites stay untouched.
  - `detail` is display-only. It never takes part in dedup (`seen` stays keyed by
    inserted text), matching, ranking or edits.
  - The resolve path never rewrites it.
- [x] Tests:
  - Recorded `Gree` transcript: the matched partition is ordered by `sortText` then
    array order, and all seven non-matching items are still present below.
  - The 93-item YAML answer for `ima`: `image` first, the alphabetical rest below,
    the cap reached from the top.
  - A case-mismatch item sits below a mismatch-free one regardless of `sortText`.
  - `detail` round-trips from `LSPCompletionItem.detail` and is `nil` for
    tree-sitter items.
  - `CompletionPopupTests`: two items differing only in `detail` dedup and order
    exactly as without it, and the inserted text is unchanged.
- [x] Run `swift test`. It must pass before Task 3.

### Task 3: Suffix-aware replace range, `insertReplaceSupport`, list-time drop of unapplicable items

**Files:**
- Modify: `Sources/PisakaCore/CompletionEditPlan.swift`
- Modify: `Sources/PisakaCore/LSPPositionMap.swift`
- Modify: `Sources/PisakaCore/LSPProtocolTypes.swift`
- Modify: `Sources/PisakaCore/LSPIntelligenceProvider.swift`
- Modify: `Tests/PisakaCoreTests/CompletionEditPlanTests.swift`,
  `LSPPositionMapTests.swift`, `LSPProtocolTypesTests.swift`,
  `LSPIntelligenceProviderTests.swift`

- [x] Add a pure rule beside `CompletionEditPlan.make`, e.g.
  `CompletionEditPlan.primaryRange(insert:replace:caret:newText:in:)`. It returns
  the replace range only when `newText` ends, case-insensitively, with the buffer
  text in `[caret, replace.end)`. Otherwise it returns the insert range.
  - For a plain `textEdit` reaching past the caret: replace is the server's range,
    and insert is that range trimmed at the caret.
  - A range that ends at or before the caret is returned unchanged.
- [x] Add a non-clamping `LSPPositionMap` mapping that returns `nil` when a
  position's line or character lies outside the text (checked against the line
  table). The existing clamping `range(for:in:lineStarts:)` is unchanged for every
  other caller.
- [x] In the provider, build the primary range through the exact mapping plus the
  rule above. Drop the item when any of these hold:
  - either range does not fit;
  - a range spans more than one line;
  - the chosen range does not contain both the typed word's start and the caret.

  Any drop sets an internal `trimmed` flag, which Task 4 turns into an incomplete
  answer. `additionalTextEdits` are untouched. The commit-time refusal in `make`
  stays.
- [x] `LSPProtocolTypes`:
  - Advertise `insertReplaceSupport: true`.
  - `LSPCompletionEdit` re-encodes in the spelling it arrived in
    (`insert`/`replace` for an `InsertReplaceEdit`), so a `completionItem/resolve`
    echo is faithful.
  - Update its doc comment.
- [x] Tests:
  - `foo|Bar` + `fooBaz` → `fooBaz|Bar`, and `foo|Baz` + `fooBaz` → `fooBaz|`, each
    for an `InsertReplaceEdit` and for a plain over-reaching `textEdit`.
  - Case-insensitive suffix match.
  - The exact mapping returns `nil` past the last line and past a line's end.
  - The capabilities JSON carries `insertReplaceSupport: true`, and the
    `InsertReplaceEdit` encode round-trips.
  - The provider drops an item whose `textEdit` lies outside the request text, and
    one that spans another line.
- [x] Run `swift test`. It must pass before Task 4.

### Task 4: Local narrowing in Core — answer type, provider retention, narrowing rule

**Files:**
- Create: `Sources/PisakaCore/CompletionNarrowingRule.swift`
- Modify: `Sources/PisakaCore/CodeIntelligence.swift`
- Modify: `Sources/PisakaCore/LSPIntelligenceProvider.swift`
- Modify: `Sources/PisakaCore/RoutingIntelligenceProvider.swift`
- Modify: `Tests/PisakaCoreTests/LSPSourceGatingTests.swift` (the Core file
  inventory, if the new file falls under its discovery)
- Create: `Tests/PisakaCoreTests/CompletionNarrowingRuleTests.swift`
- Modify: `Tests/PisakaCoreTests/LSPIntelligenceProviderTests.swift`

- [x] Add a seam value `CompletionAnswer { items: [CompletionItem]; retained:
  RetainedCompletionList? }`. `RetainedCompletionList` holds:
  - an opaque `handle: Int`;
  - the typed word's start;
  - the typed word as answered.

  It is non-nil only for a complete LSP answer that was not trimmed (Task 3) and
  came from the live session.
- [x] Add protocol methods `completionAnswer(for:)` and
  `narrow(_:for:) async -> [CompletionItem]?`. Their defaults wrap
  `completions(for:)` with `retained: nil` and return `nil`, so the tree-sitter
  provider and iOS are unaffected.
- [x] The LSP provider keeps the last complete list: raw items, the request text,
  the typed word, the session, and `serverResolves`. A newer list token replaces it.
  `narrow` re-runs the same `publish` pipeline (partition, ranking, dedup, cap,
  resolve registration) with the new prefix:
  - Edits, inserted text and display are computed against the retained request
    text, then re-expressed through
    `CompletionEdit.shifted(afterReplacingTypedWord:withLength:)`.
  - It returns `nil` when the session is no longer the live one (restart or
    retirement), when the handle is not the current one, or when every item lands
    in `noMatch`.
  - The retained raw items are never mutated.
- [x] `RoutingIntelligenceProvider` forwards both methods to the LSP side under the
  existing completion budget. A fallback (tree-sitter) answer always carries
  `retained: nil`.
- [x] Add the pure rule
  `CompletionNarrowingRule.decide(retained:wordStart:typed:explicit:typedTriggerCharacter:insertedNewline:caretJumped:) -> .narrow / .request / .dropRetained`.
  It narrows only when all of these hold:
  - the word start is unchanged;
  - the new word is non-empty;
  - the new word extends or equals the answered one; a backspace below the answered word asks again;
  - no newline was inserted, no trigger character was typed, the caret did not
    jump, and the request is not explicit.

  An emptied word yields `.dropRetained`. Everything else yields `.request`.
  `.dropRetained` means only "forget the retained list": it carries no instruction
  about what the popup does next, and its doc comment says so — the caller then
  follows its existing empty-word path unchanged (Task 5).
- [x] Tests:
  - Rule table: extend, backspace, emptied word, crossed word start, trigger
    character, explicit invocation, newline, caret jump.
  - Typing `fo` → `foo` → `foob` against a complete answer: exactly one
    `textDocument/completion` counted on `ScriptedLSPTransport`, and the `foob`
    narrow equals a fresh `foob` answer from the same items (a second provider over
    the same script), including resolve handles resolving the same items.
  - The same sequence against `isIncomplete: true`: `retained == nil`, so three
    requests.
  - Backspace `foob` → `foo` narrows with no request. The emptied word drops the
    retained list.
  - A list trimmed by Task 3's drop is not retained.
  - After the session restarts, `narrow` returns `nil`.
  - A narrow whose matched partitions are empty returns `nil`.
- [x] Run `swift test`. It must pass before Task 5.

### Task 5: App — controller narrows locally, panel draws the detail column

**Files:**
- Modify: `Sources/Pisaka/CompletionController.swift`
- Modify: `Sources/Pisaka/CompletionPanel.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift` (only where a
  pinned per-file inventory changes)
- Create: `Tests/PisakaAppTests/CompletionPanelDetailLayoutTests.swift`

- [x] Controller:
  - Calls `completionAnswer(for:)` and keeps `answer.retained` for its generation.
  - On each update, asks `CompletionNarrowingRule.decide`. On `.narrow` it calls
    `provider.narrow` with no debounce, under the same generation-token check. A
    `nil` result falls through to an ordinary debounced request.
  - On `.dropRetained` it clears the retained list and then follows today's path for
    an empty typed word unchanged — whatever `reset()`, dismissal or request that
    path performs today. `.dropRetained` therefore never changes current behaviour
    beyond forgetting the list.
  - `reset()` and a tab switch also clear the retained list.
  - The 150 ms debounce and the 1.5 s budget are unchanged for requests.
- [x] Panel:
  - Draws `item.detail` right-aligned in the existing `.textSecondary` role, at the
    row's code font built through `EditorFont` (the panel is already a zoom
    surface).
  - Truncates the detail at its leading edge so the tail survives. The label keeps
    priority.
  - `measureWidth` never exceeds the existing `maximumWidth`.
  - Draws nothing when `detail` is nil.
- [x] Headless app test: a row with a long label and a long detail stays within
  `maximumWidth`, the label is drawn untruncated before the detail, and the
  detail's drawn string keeps its tail.
- [x] Run `swift test` and the `PisakaAppTests` bundle. Both must pass before
  Task 6. (swift test: 6320 passed. PisakaAppTests: all new and completion
  suites pass; 8 pre-existing scale-1.8 layout failures in BottomBarLayoutTests,
  BottomBarToolTipTests, ChromePopoverLayoutTests and CommitDialogLayoutTests
  reproduce identically on the unmodified HEAD — environment, not this task.)

### Task 6: Shutdown that gives `exit` time, and concurrent polite quit

**Files:**
- Modify: `Sources/PisakaCore/LSPTransport.swift`
- Modify: `Sources/PisakaCore/LSPSession.swift`
- Modify: `Sources/PisakaCore/LSPWorkspace.swift`
- Modify: `Sources/Pisaka/LSPProcessTransport.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `Tests/PisakaCoreTests/Support/ScriptedLSPTransport.swift`,
  `LSPSessionTests.swift`, `LSPWorkspaceTests.swift`
- Create: `Tests/PisakaAppTests/LSPProcessShutdownTests.swift`,
  `Tests/PisakaAppTests/Fixtures/lsp-ignores-exit.sh`

- [x] `LSPTransport` gains `closeInput()` (idempotent; stdin closed, no signal).
- [x] `LSPSession.shutdown()` runs: `shutdown` request (existing budget) → `exit` →
  `closeInput()` → race the read loop's end of stream against an injectable
  `exitGrace` wait (default 2 s) → `close(reason:)`, which calls
  `transport.terminate()`. A server whose stream has already ended costs no wait.
  Pending requests are still failed once, through the idempotent `close`.
- [x] `LSPProcessTransport` takes its SIGTERM→SIGKILL grace as an init parameter
  (default 2 s) and implements `closeInput()`.
- [x] `LSPWorkspace.shutdownAll()` tears sessions down concurrently with a task
  group, keeping today's `didClose` and `forget` bookkeeping per key.
  `terminateNow()` is unchanged.
- [x] `AppDelegate`:
  - `applicationShouldTerminate` returns `.terminateLater` when the workspace holds
    live sessions, runs `shutdownAll()`, then calls
    `reply(toApplicationShouldTerminate: true)`.
  - The workspace reaches the delegate through a closure installed by `PisakaApp`.
  - The `willTerminate` observer keeps `terminateNow()` as the fallback.
- [x] Core tests with `Gate`:
  - A scripted server that ends its stream on `exit` is never terminated before its
    stream ends.
  - One that ignores `exit` is terminated only after the grace gate is released.
  - Pending requests fail exactly once.
  - `shutdownAll()` over two servers that both ignore `exit` waits on both graces
    concurrently: both waits start before either is released.
- [x] App test: a script fixture that ignores `exit` (and ignores stdin EOF) traps
  TERM to write a marker. With small graces, the marker appears only after the
  first grace and the process is gone after the second (kill). Polling uses
  `waitFor`.
- [x] Run `swift test` and the `PisakaAppTests` bundle. Both must pass before
  Task 7. (`swift test` green; the bundle's only failures are the 8 scale-1.8
  layout assertions in BottomBar/ChromePopover/CommitDialog, which fail
  identically on the unmodified tree on this machine.)

### Task 7: Bounded stderr and exit-code record, shown passively in settings

**Files:**
- Create: `Sources/PisakaCore/LSPServerFailureRecord.swift`
- Modify: `Sources/PisakaCore/LSPTransport.swift`, `LSPWorkspace.swift`,
  `LSPProvisioning.swift` (or the row derivation beside it)
- Modify: `Sources/Pisaka/LSPProcessTransport.swift`, `LSPServerSettingsView.swift`,
  `PisakaApp.swift` (wiring)
- Modify: `Tests/PisakaCoreTests/Support/ScriptedLSPTransport.swift`,
  `LSPWorkspaceTests.swift`, `LSPSourceGatingTests.swift`,
  `ChromeThemeSourceGatingTests.swift` (pinned inventories)
- Create: `Tests/PisakaCoreTests/LSPServerFailureRecordTests.swift`

- [x] Add `LSPServerFailureRecord` to Core:
  - a byte ring bounded at a stated size (32 KiB) that keeps the newest bytes;
  - the last exit code;
  - the failure count and whether the key is retired;
  - the status sentence (e.g. "stopped after 4 failures, exit code 1").

  Text is decoded lossily for display only.
- [x] `LSPTransport` gains an `errorOutput` stream of `.bytes(Data)` /
  `.exited(code:)`, defaulted to an empty, finished stream. `LSPProcessTransport`
  yields stderr chunks (still always drained) and the termination status from its
  termination handler.
- [x] `LSPWorkspace` keeps `[ServerKey: LSPServerFailureRecord]` across restarts, in
  memory only.
  - Each launched transport's `errorOutput` is appended to its key's record.
  - A failure and a retirement update it.
  - A successful handshake removes it.
  - Changes are published through a callback in the `onDiagnostics` mould.
- [x] Core row derivation:
  - Each settings row (downloadable, Go, Rust) gets an optional failure status.
  - A server without a row of its own (sourcekit-lsp) gets a status-only row with no
    actions, present only while a record exists.
  - Multiple roots for one server resolve to the newest record.
- [x] `LSPServerSettingsView` shows the status sentence plus a disclosure with the
  captured text in a scrollable, selectable monospaced area. Colour comes only from
  the roles already used on the page. There is no alert, banner, toast or
  notification.
- [x] Tests:
  - The ring keeps the newest bytes at exactly its bound.
  - After four scripted failures the record holds the exit code and the bounded
    tail.
  - A successful restart clears it.
  - Row derivation covers the status-only row appearing and disappearing.
  - The gating suite asserts that neither the workspace, the record file nor
    `LSPServerSettingsView.swift` reaches an alert, banner or notification API
    (`NSAlert`, `.alert(`, `UNUserNotificationCenter`, `NSUserNotification`),
    matched against comment- and literal-stripped text.
  - The new Core file is added to `LSPSourceGatingTests`' set.
- [x] Run `swift test` and the `PisakaAppTests` bundle. Both must pass before
  Task 8. (`swift test` green, 6336 tests; the bundle's only failures are
  the same 8 scale-1.8 layout assertions Task 6 recorded as environmental.
  `PisakaApp`'s `type_body_length` ceiling rose 1920 → 1925 for the wiring,
  recorded in `.swiftlint.yml`, `style-lint.md` and `LintConfigurationTests`.)

### Task 8: Verify acceptance criteria

- [x] `swift test`
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build`
  (`CompletionItem` reaches the iOS bar)
- [x] `swiftlint --strict` from the repository root
- [x] Confirm that `LSPSourceGatingTests` still holds `Process` behind
  `LSPTransport`, and that every acceptance criterion 1–12 maps to a passing test.
  (`swift test` 6336 tests green; `PisakaAppTests` 315 tests, only the 8
  environmental scale-1.8 layout assertions recorded in Task 6 fail; iOS
  build succeeded unsigned; `swiftlint --strict` 0 violations in 684 files.
  The ticket's numbered criteria are not in the repo; each Overview behaviour
  maps to tests in FuzzyMatchTests, LSPIntelligenceProviderTests,
  CompletionEditPlanTests, LSPProtocolTypesTests, CompletionNarrowingRuleTests,
  CompletionPopupTests, CompletionPanelDetailLayoutTests, LSPSessionTests,
  LSPWorkspaceTests, LSPProcessShutdownTests, LSPServerFailureRecordTests,
  LSPProvisioningModelTests and LSPSourceGatingTests.)

### Task 9: Update documentation

- [x] `docs/architecture/core-lsp.md`:
  - D6 gains the tiered partition and its "a partition, not a filter" reasoning.
  - New decisions:
    - D40, local narrowing and the retained list;
    - D41, list-time drop, which marks the answer incomplete;
    - D42, the suffix rule plus `insertReplaceSupport`;
    - D43, the shutdown sequence and the polite concurrent quit;
    - D44, the failure record and its passive display.
  - Entries for the new and changed files.
- [x] `docs/architecture/core-intelligence.md`: the `FuzzyMatch` keys, contiguous
  placement, `Partition`, and `CompletionItem.detail`.
- [x] `docs/architecture/app-editor.md`: the controller's narrowing path (including
  `.dropRetained` only forgetting the list before today's empty-word path) and the
  panel's detail column.
- [x] `docs/architecture/core-provisioning.md`: the failure status on settings rows
  and the status-only row.
- [x] `docs/architecture/app-shell.md`: `applicationShouldTerminate` →
  `.terminateLater`.
- [x] `docs/FEATURES.md`: update Known limitations that describe the commit-time
  degradation or the silent retirement.
- [x] `CLAUDE.md`:
  - Extend the LSP decision range to "D1–D10 + D17–D44".
  - Add `CompletionNarrowingRule.swift` and `LSPServerFailureRecord.swift` to the
    core-lsp index.
  - Keep the file under the 60,000-character limit (`LintConfigurationTests`).
- [x] Re-run `swift test` (doc-reading suites). (6336 tests green;
  `swiftlint --strict` 0 violations. `app-shell.md`'s `AppDelegate` entry was
  already written in Task 6. Row derivation lives in `LSPServerFailureRecord.swift`
  (`LSPServerFailureModel`), documented there and in `core-provisioning.md`.)
