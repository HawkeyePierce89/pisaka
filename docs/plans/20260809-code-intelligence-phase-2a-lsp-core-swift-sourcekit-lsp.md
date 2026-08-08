# Code intelligence, phase 2a: LSP core, Swift via sourcekit-lsp

## Overview

Put a Language Server Protocol client behind the existing `CodeIntelligenceProviding`
seam and ship one server: `sourcekit-lsp`, found through `xcrun` in the Xcode
toolchain. All JSON-RPC/LSP logic lives in `PisakaCore` (Foundation-only, fully
unit-tested); only process launch and pipe plumbing live macOS-gated in the app,
in the mold of `GitCLIService`. For a Swift file, ⌘-click/⌃⌘J becomes a semantic
jump (cross-module and into the SDK) and completion becomes typed candidates with
auto-import. Every other language, and every failure mode, keeps today's
tree-sitter answers — silently, per request.

The architecture is server-agnostic: phase 2b adds TS/JS and Python by registering
another `LSPServerDescription`, not by writing client code.

## Context

Existing code this builds on:

- `Sources/PisakaCore/CodeIntelligence.swift` — the seam (`DefinitionRequest`,
  `DefinitionCandidate`, `CompletionRequest`, `CompletionItem`), already async
  precisely for this phase.
- `Sources/PisakaCore/SymbolIntelligenceProvider.swift` — the tree-sitter provider
  that stays as the fallback, untouched in behavior.
- `Sources/PisakaCore/LineStartIndex.swift` — the editor's line machinery
  (LF/CR/CRLF/NEL/LS/PS), used for *display* line numbers only.
- `Sources/PisakaCore/IdentifierScanner.swift` — the word/prefix/member rules that
  keep deciding what a request is about.
- `Sources/Pisaka/CompletionController.swift` — the snapshot mechanism that makes an
  async provider serve AppKit's synchronous completions delegate.
- `Sources/Pisaka/CodeEditorView.swift` — `goToDefinition(in:at:)`,
  `EditorTextView.insertCompletion(…)`, the `isApplyingProgrammaticEdit` bracket,
  per-file undo managers.
- `Sources/Pisaka/GitCLIService.swift` — the `Process` + serial-queue + environment
  idiom the transport copies.
- `Sources/Pisaka/DiffWindowController.swift` / `DiffView.swift` — the
  separate-window + read-only highlighted `NSTextView` pattern the out-of-project
  definition viewer reuses (`closeAll()` on `willTerminateNotification`).
- `Sources/Pisaka/PisakaApp.swift` — folder-open path (`prepareForFolderChange`
  rule), tab close (`forgetIndexedBuffer`), `willTerminateNotification` observer.

Dependencies: none. JSON-RPC is hand-rolled over Foundation; nothing new ships in
the bundle, no pins or licenses change.

## Design decisions (recorded here because the ticket delegates them)

**D1 — Position mapping and line separators.** `LSPPositionMap` scans line starts
using **LSP's separator set only: LF, CRLF, CR** — not `LineStartIndex`'s wider set
— because the number we send must be the number the server counted. Positions are
UTF-16 code units within the line (`positionEncoding: utf-16`, the LSP default,
which we advertise explicitly). Every LSP position we receive is converted to an
absolute UTF-16 offset first; anything user-visible (the picker's line number) is
then derived with `LineStartIndex`, so what the user reads still matches the
gutter. *Known limit:* in a file that delimits lines with NEL/U+2028/U+2029, the
editor's line count and the server's differ; offsets — and therefore every jump and
edit — stay exact, only the two numberings diverge, and no LSP line number is ever
shown raw.

**D2 — Document sync is request-driven, full-text.** `textDocument/didChange` uses
`TextDocumentSyncKind.full`. The buffer text is not pushed on every keystroke: each
request carries the live buffer (`CompletionRequest` already does;
`DefinitionRequest` gains a `text` field), and the LSP layer sends `didOpen`, or a
`didChange` with a bumped version, **immediately before** the request whenever the
text differs from what the server was last told. This satisfies the correctness
rule ("the server has the current text before any request against it") with zero
editor wiring for change notification, and avoids shipping the whole file per
keystroke. `didClose` is sent when the last tab on a file closes and for every open
document on a folder switch. The new `text` field is defaulted so no existing call
site breaks at compile time, which makes a *forgotten* call site the real hazard:
it would silently hand the LSP layer an empty string and get positions clamped to
0:0 — wrong answers that never trigger fallback. Two things close that hole. First,
the one macOS call site (`CodeEditorView.goToDefinition(in:at:)`) is updated in the
same task that adds the field, to pass the live buffer text. Second, a guard the
tests pin: **the LSP definition path treats a request whose `text` is empty while
its `offset` is non-zero as unanswerable** — it does not clamp, it returns no
answer, and routing falls back to tree-sitter. A genuinely empty buffer has offset 0
and stays answerable.

**D3 — A definition target outside the project root opens in a separate, read-only
window** (the answer given during planning), modeled on `DiffWindowController` +
`DiffView`'s read-only highlighted pane. No tab, no `WorkspaceModel`, no autosave —
so a jump into an SDK interface or a dependency checkout structurally cannot write
outside the root. Targets inside the root keep today's tab-open + `EditorRevealState`
path unchanged.

**D4 — Auto-import.** An LSP completion item carries its own edits
(`CompletionItem.edits`, UTF-16 buffer ranges): the primary replacement plus any
`additionalTextEdits`. `EditorTextView.insertCompletion` applies an item that
carries edits **itself** — one `shouldChangeTextInRanges` batch inside one undo
group, edits applied last-to-first so earlier offsets stay valid (the `TextSearch`
Replace All rule), with the caret placed after the inserted text, never at the
import. An item with no edits keeps going through `super` exactly as today. Items
the server marks as needing `completionItem/resolve` are resolved **concurrently in
the background the moment the list is shown** — the user's pick is hundreds of
milliseconds later, so the edits are in hand by then. *Known limit:* if an item is
committed before its resolve lands, the insertion happens first and the import edit
is applied when it arrives, as a second undo step.

**D5 — No snippet support is advertised**, so `newText` is always plain text and
nothing has to strip `${1:placeholder}` syntax.

**D6 — Ranking for LSP-answered requests trusts the server**: items sorted by
`sortText ?? label` (stable sort, preserving server order on ties) — which *is* the
server's ranking, expressed the way the spec says to read it — then the existing
hygiene: drop the item identical to the typed token, dedup by inserted text (first
wins), cap at `SymbolIntelligenceProvider.defaultCompletionLimit`. No name
heuristics are applied on top.

**D7 — Budgets.** Per-request: completion 1.5 s, definition 3 s (the 150 ms
completion debounce has already elapsed, and a jump is a deliberate act worth
waiting a beat for). Handshake: 20 s (sourcekit-lsp resolves the build system on
first start). Crash/EOF: restart with 1 s / 2 s / 4 s backoff, at most 3 times per
(server, root); the fourth failure marks the server unavailable **for the session**
and that language falls back for good. No alerts, no banners — ever.

**D8 — `DefinitionCandidate` stops wrapping a `Symbol`.** An LSP definition response
carries a location, not a kind, and adding a synthetic `SymbolKind` case would break
`SymbolQueryTests`' set equality against the shipped queries. The candidate
therefore stores what it displays and navigates by — `name`, `containerName`,
`kind: SymbolKind?`, `fileURL`, `range`, `line`, `relativePath` — with
`displayLabel` byte-identical to today. This is not a free change, and the plan
states the cost rather than hiding it: a retained `init(symbol:relativePath:)`
convenience keeps every **construction** site unchanged (the tree-sitter provider
builds candidates exactly as today), but the stored `symbol` property is gone, so
every **accessor** site is a mechanical edit — `candidate.symbol.name` →
`candidate.name`, `.symbol.line` → `.line`, `.symbol.range` → `.range`,
`.symbol.fileURL` → `.fileURL`. Those sites are: `SymbolIntelligenceProvider`'s
tie-break sort, `CodeEditorView.goToDefinition`, `DefinitionRoute_iOS`, and two test
suites — `SymbolIntelligenceProviderTests` (`.map(\.symbol.name)`,
`"\($0.relativePath):\($0.symbol.line)"`) and
`SymbolIndexModelTests.testProviderAnswersFromTheModelsLatestSnapshot`
(`candidates.first?.symbol.line`). All are listed in Task 5's files; none change
behavior, and the assertions keep asserting the same values.

**D9 — The registry.** `LSPServerDescription` is
`{ id, languages, launch, arguments, initializationOptions }`, where `launch` is
`.toolchainTool(name:)` (resolved by the app through `xcrun --find`, honouring
`DEVELOPER_DIR`, cached per app run) or `.executable(path:)` (what 2b will use).
`LSPServerRegistry` maps language → description. Adding a server is one registry
entry.

**D10 — Reader, not writer.** The LSP layer never raises
`autosave.suspend()`/`beginRevert()` and is never gated by them — the same rule
already written for the symbol index. It reads buffers and answers questions; it
writes nothing to disk.

## Development Approach

- **Testing approach**: TDD for the Core protocol layer (framing, correlation,
  position mapping, edit plans, routing — all pure and cheap to pin first),
  code-first for the thin app glue, which stays untested by repo convention.
- Recorded sourcekit-lsp transcripts live in `Tests/PisakaCoreTests/Fixtures/LSP/`
  and are read through `#filePath` like the other repository-file suites — no
  SwiftPM resource declaration, no live process ever spawned by `swift test`
  (`Package.swift`'s test target gets an `exclude:` for the directory so SwiftPM
  emits no unhandled-resource warning).
- Complete each task fully before the next; **every task carries new/updated Core
  tests**, and `swift test` must be green before moving on.

## Implementation Steps

### Task 1: JSON-RPC envelopes and `Content-Length` framing

The bytes-in/bytes-out layer, with no LSP semantics in it at all.

**Files:**
- Create: `Sources/PisakaCore/LSPMessage.swift`, `Sources/PisakaCore/LSPFraming.swift`
- Create: `Tests/PisakaCoreTests/LSPFramingTests.swift`,
  `Tests/PisakaCoreTests/LSPMessageTests.swift`

- [x] `JSONValue` (a Foundation-only `Codable` any-JSON value), `LSPRequestID` (int
      or string), `LSPErrorCode`, and the three envelopes — outgoing
      request/notification/response, incoming response/notification/server-request —
      decoding a peer message into one typed enum case
- [x] `LSPFraming`: `encode(_:) -> Data` and an incremental `Decoder` that accepts
      arbitrary chunks and yields zero or more complete payloads, tolerating header
      case/whitespace variation, ignoring `Content-Type`, and reporting a malformed
      header as a typed error that poisons the stream rather than desyncing it
- [x] tests: split-mid-header, split-mid-body, several messages in one read, one
      message across many reads, a body containing `\r\n\r\n`, missing/duplicate/
      non-numeric `Content-Length`, absurd length rejected by a cap
- [x] tests: envelope round-trips, out-of-order/unknown-id responses decoded
      faithfully, error responses, `null` results
- [x] run `swift test` — must pass before task 2

### Task 2: LSP protocol types and position mapping

The message bodies this phase uses, and the offset↔position bridge (D1).

**Files:**
- Create: `Sources/PisakaCore/LSPProtocolTypes.swift`,
  `Sources/PisakaCore/LSPPositionMap.swift`
- Create: `Tests/PisakaCoreTests/LSPProtocolTypesTests.swift`,
  `Tests/PisakaCoreTests/LSPPositionMapTests.swift`
- Create: `Tests/PisakaCoreTests/Fixtures/LSP/` (recorded sourcekit-lsp transcripts)
- Modify: `Package.swift` (exclude the fixtures directory from the test target's
  sources)

- [x] value types for initialize/initialized,
      `textDocument/didOpen|didChange|didClose`, `textDocument/definition`
      (Location, Location[], LocationLink[]), `textDocument/completion`
      (CompletionList and bare array, `CompletionItemKind`, `sortText`,
      `filterText`, `textEdit`/`insertText`, `additionalTextEdits`, `data`),
      `completionItem/resolve`, `shutdown`/`exit`, `$/cancelRequest`
- [x] client capabilities advertise exactly this phase's surface: full text sync,
      `positionEncoding: utf-16`, definition with link support, completion with
      `resolveSupport` for `additionalTextEdits`/`detail`, **no** snippet support (D5)
- [x] `LSPPositionMap`: `position(forOffset:in:)` and `offset(for:in:)` over an
      `NSString`, LSP separators only, clamping an out-of-range line/character
- [x] tests: decode every recorded sourcekit-lsp response fixture and re-encode every
      request shape; mapping both directions across surrogate pairs, empty lines,
      CRLF, a lone CR, EOF with and without a trailing newline, and the documented
      NEL/LS/PS divergence asserted explicitly rather than assumed
- [x] run `swift test` — must pass before task 3

Fixtures were **recorded from a live `sourcekit-lsp`** (Xcode 26.6) driven over a
throwaway two-module SwiftPM package, not hand-written from the specification;
`Tests/PisakaCoreTests/Fixtures/LSP/README.md` records the provenance of each
file. Two shapes that server would not produce — `LocationLink[]` (it answered
`Location[]` from every position tried, even with `linkSupport` advertised) and a
completion item carrying `additionalTextEdits` (it offers no unimported symbols,
so it never emitted one) — are authored to the spec and labelled as such in that
README rather than passed off as recordings.

Three things the recording settled that the plan had only assumed:

- The identifier-completion fixture is kept **unreordered** because the recorded
  answer puts `Greeter` *last* in the array with the *lowest* `sortText`. D6's
  "rank by `sortText`, never by array order" is therefore pinned against real
  output rather than against a constructed example.
- One recorded item spells itself three ways — label `greet(name: String)`,
  filterText `greet(:)`, insertText `greet()` — so `insertedText` follows the
  spec's precedence and the test asserts all three.
- The interior of a CRLF pair is **not an addressable LSP position**, which the
  exhaustive offset↔position round-trip surfaced. Both directions agree to clamp
  it to the line's content end; `LSPPositionMapTests`
  `testAnOffsetInsideACRLFPairIsNotAnAddressablePosition` states that outright
  instead of the round-trip assertion being quietly weakened. Worth carrying into
  Task 13's `core-lsp.md` alongside D1's NEL/LS/PS limit.

### Task 3: Transport seam and the session actor

The protocol driver: one live conversation with one server process.

**Files:**
- Create: `Sources/PisakaCore/LSPTransport.swift`, `Sources/PisakaCore/LSPSession.swift`
- Create: `Tests/PisakaCoreTests/Support/ScriptedLSPTransport.swift`
- Create: `Tests/PisakaCoreTests/LSPSessionTests.swift`

- [ ] `LSPTransport` protocol (send `Data`, an `AsyncStream<Data>` of incoming bytes,
      `terminate()`) plus `LSPTransportError` — the whole macOS/Core boundary
- [ ] `LSPSession` actor: handshake, monotonic ids, pending-request table,
      per-request budget (D7), `$/cancelRequest` on Swift task cancellation,
      answering server-initiated requests (`client/registerCapability`,
      `workspace/configuration` → an empty/absent-value result; anything unknown →
      `MethodNotFound`), ignoring unknown notifications, graceful
      `shutdown`→`exit`→terminate, and a terminal state on EOF that fails every
      pending request
- [ ] `ScriptedLSPTransport`: a deterministic fake driving the session from a
      recorded script (reply, delay, drop, close the stream) with no real process
- [ ] tests: successful round-trip, out-of-order replies, a reply to an unknown id
      ignored, timeout fails only its own request, cancellation emits
      `$/cancelRequest` and does not leak the pending entry, EOF mid-flight fails
      pending requests once, `shutdown` sequence order
- [ ] run `swift test` — must pass before task 4

### Task 4: Server registry and workspace lifecycle

One server per (server, project root), started lazily, torn down deliberately.

**Files:**
- Create: `Sources/PisakaCore/LSPServerDescription.swift`,
  `Sources/PisakaCore/LSPWorkspace.swift`
- Create: `Tests/PisakaCoreTests/LSPServerRegistryTests.swift`,
  `Tests/PisakaCoreTests/LSPWorkspaceTests.swift`

- [ ] `LSPServerDescription` + `LSPServerRegistry` per D9, with the
      Swift/sourcekit-lsp description as the only registered entry
- [ ] `LSPWorkspace` (`@MainActor`): lazy start on first request for a served
      language, a `transportFactory` closure (so `Process` stays out of Core),
      per-document open/version bookkeeping, the request-driven
      `didOpen`/`didChange` flush (D2), `didClose`, backoff/restart and session-wide
      unavailability (D7), and `prepareForFolderChange(root:)` returning a generation
      token, synchronously, before any hop — matching the repository's existing scheme
- [ ] `shutdownAll()` for folder switch and termination; a document is never opened
      against a root it does not live under
- [ ] tests, all on scripted transports: a fake second server description is served
      by configuration alone (no client changes); lazy start happens once per root; a
      text change flushes exactly one `didChange` before the request and none when the
      text is unchanged; a folder switch supersedes in-flight work and closes every
      document; three crashes restart, the fourth marks unavailable and no further
      launch is attempted
- [ ] run `swift test` — must pass before task 5

### Task 5: Seam changes — candidate, item edits, request text

The smallest set of changes to `CodeIntelligence.swift` that lets an LSP answer be
expressed, plus the pure edit-application rule auto-import needs. Per D8 this is
also a mechanical accessor sweep across every `candidate.symbol.*` read.

**Files:**
- Modify: `Sources/PisakaCore/CodeIntelligence.swift`
- Create: `Sources/PisakaCore/CompletionEditPlan.swift`
- Modify: `Sources/PisakaCore/SymbolIntelligenceProvider.swift` (construction
  unchanged; tie-break sort moves to the direct fields)
- Modify: `Sources/Pisaka/CodeEditorView.swift`,
  `Sources/Pisaka/iOS/DefinitionRoute_iOS.swift` (candidate field access)
- Create: `Tests/PisakaCoreTests/CompletionEditPlanTests.swift`
- Modify: `Tests/PisakaCoreTests/SymbolIntelligenceProviderTests.swift`,
  `Tests/PisakaCoreTests/SymbolIndexModelTests.swift` (accessor updates:
  `.symbol.name`/`.symbol.line` → the direct fields; assertions keep asserting the
  same values)

- [ ] `DefinitionCandidate` per D8 — direct fields, optional `kind`, unchanged
      `displayLabel`, retained `init(symbol:relativePath:)`; update every
      `candidate.symbol.*` accessor in Core, both app layers and the two test suites
- [ ] `DefinitionRequest` gains `text: String` (defaulted, so no call site breaks)
      and `CompletionItem` gains `edits: [CompletionEdit]` plus an opaque
      `resolveHandle: Int?`, both defaulted so the tree-sitter provider and the iOS
      surfaces are untouched
- [ ] update the macOS `goToDefinition(in:at:)` call site in `CodeEditorView.swift`
      to pass the live buffer text into `DefinitionRequest` — the defaulted field is
      never left to default on a path the LSP provider can see (D2)
- [ ] `CompletionEditPlan`: given a buffer, a set of `CompletionEdit`s and the
      partial-word range, produce the ordered (last-to-first) application list, the
      resulting caret offset, and a rejection for overlapping or out-of-range edits
- [ ] tests: an import inserted *before* the completion point leaves the caret after
      the inserted symbol; an edit after it; multiple additional edits; overlapping
      edits rejected; empty edit list; edits against a buffer that changed since the
      request are rejected rather than misapplied
- [ ] run `swift test` — must pass before task 6

### Task 6: The LSP intelligence provider

Turning protocol answers into seam values, with D6's ranking and D1's offsets.

**Files:**
- Create: `Sources/PisakaCore/LSPIntelligenceProvider.swift`
- Create: `Tests/PisakaCoreTests/LSPIntelligenceProviderTests.swift`

- [ ] `definitions(for:)`: build the position from the request's text and offset, map
      `Location`/`LocationLink` results to candidates, compute each target's display
      line and `relativePath` (file name when outside the root), and flag out-of-root
      targets so the app can route them to the read-only window (D3)
- [ ] the D2 guard: a definition request whose `text` is empty while its `offset` is
      non-zero is unanswerable — return no answer (so routing falls back) instead of
      clamping the position to 0:0; no request is ever sent for it
- [ ] `completions(for:)`: build the completion params (including the member trigger
      as `triggerCharacter: "."`), rank and dedup per D6, convert each item's
      `textEdit`/`insertText` and `additionalTextEdits` into buffer-coordinate
      `CompletionEdit`s, and carry a resolve handle for items the server deferred
- [ ] `resolveEdits(for:)` — the defaulted protocol extension point, implemented here
      and a no-op everywhere else
- [ ] tests against recorded transcripts: a cross-module definition, a definition
      returning `LocationLink[]`, an SDK target marked out-of-root, member completion
      after `.`, an item whose `textEdit` range is wider than the client prefix range,
      an item resolved into `additionalTextEdits`, server order preserved on
      `sortText` ties, typed-token/dedup/cap hygiene
- [ ] test the D2 guard directly: empty text + non-zero offset yields no LSP answer
      and sends nothing to the scripted transport; empty text + offset 0 stays
      answerable
- [ ] run `swift test` — must pass before task 7

### Task 7: Routing and silent fallback

The one provider the UI holds, composing LSP with tree-sitter.

**Files:**
- Create: `Sources/PisakaCore/RoutingIntelligenceProvider.swift`
- Create: `Tests/PisakaCoreTests/RoutingIntelligenceProviderTests.swift`

- [ ] implement `CodeIntelligenceProviding` by asking the LSP source when the
      request's language has a live (or startable) server, within D7's budget, and
      falling back to the wrapped `SymbolIntelligenceProvider` on timeout, transport
      error, unavailability, or an empty/unusable answer where tree-sitter has one
- [ ] fallback is per request and silent: no state is marked, nothing is logged to
      the user, and a slow answer degrades exactly one question
- [ ] tests: live server → LSP answer; timeout → tree-sitter answer and the LSP
      request is cancelled; dead/unavailable server → tree-sitter with no launch
      attempt; **no server registered for the language → byte-identical output to the
      bare `SymbolIntelligenceProvider`, asserted by equality on both request kinds**;
      empty LSP completion with a non-empty tree-sitter list falls back; empty LSP
      definition with an empty tree-sitter list still beeps once
- [ ] test that a definition request tripping the D2 guard (empty text, non-zero
      offset) routes to the tree-sitter answer rather than producing an LSP one
- [ ] run `swift test` — must pass before task 8

### Task 8: macOS transport and sourcekit-lsp discovery

The only new app-side machinery, thin and `#if os(macOS)`-gated.

**Files:**
- Create: `Sources/Pisaka/LSPProcessTransport.swift`, `Sources/Pisaka/LSPToolchain.swift`
- Create: `Tests/PisakaCoreTests/LSPSourceGatingTests.swift`

- [ ] `LSPProcessTransport`: `Process` + three pipes on a dedicated serial queue (the
      `GitCLIService` idiom), stdout fed into `LSPFraming.Decoder` and published as
      the transport's `AsyncStream`, stderr drained and discarded, environment
      inherited, `terminate()` sending SIGTERM then reaping — and a `deinit`/
      termination path as deliberate as `TerminalSession.terminate()`, so no
      `sourcekit-lsp` ever outlives the app
- [ ] `LSPToolchain`: `xcrun --find sourcekit-lsp` honouring `DEVELOPER_DIR`, result
      (including "not found") cached per app run, nothing bundled or downloaded
- [ ] `LSPSourceGatingTests` (repo-file suite, `#filePath` + Foundation): every new
      `Sources/Pisaka` LSP file is wrapped in `#if os(macOS)`, and no
      `Sources/PisakaCore/LSP*.swift` mentions `Process`, `AppKit`, `UIKit` or
      `SwiftTreeSitter`
- [ ] run `swift test` — must pass before task 9

### Task 9: App wiring — composition and lifecycle

Hanging the new layer off the places that already exist, and nowhere else.

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `Sources/Pisaka/Platform/SymbolIndexController.swift` (the `provider` seam
  it already exposes)

- [ ] construct the `LSPWorkspace` with the process transport factory and the Swift
      registry entry, wrap `symbolIndex.provider` in the routing provider, and hand
      the *routing* provider to the editor surfaces — no view signature changes
- [ ] re-confirm the macOS `goToDefinition` path built in Task 5 passes the live
      buffer text through the routing provider — no path reaches the LSP provider with
      a defaulted-empty `DefinitionRequest.text`
- [ ] folder switch: `prepareForFolderChange` + `shutdownAll()` in the same
      main-actor turn as the existing tokens, alongside `symbolIndexController.reset()`
- [ ] tab close: `didClose` beside `forgetIndexedBuffer(_:)`, under the same "no
      other tab shows this file" guard
- [ ] termination: `shutdownAll()` from the existing `willTerminateNotification`
      observer, beside `terminalSessions.terminateAll()` / `diffWindows.closeAll()`
- [ ] confirm the writer gate is untouched: no `autosave.suspend()` /
      `beginRevert()` anywhere on this path (D10)
- [ ] run `swift test` — must pass before task 10

### Task 10: Definition surfaces — the read-only window

Where an out-of-project target lands (D3).

**Files:**
- Create: `Sources/Pisaka/SourceViewerWindowController.swift`,
  `Sources/Pisaka/SourceViewerContent.swift`
- Modify: `Sources/Pisaka/CodeEditorView.swift`, `Sources/Pisaka/PisakaApp.swift`

- [ ] a retained-window controller mirroring `DiffWindowController` (release on
      close, `closeAll()` on termination) hosting a read-only, syntax-highlighted
      `NSTextView` modeled on `DiffView`'s pane, scrolled to the target range
- [ ] `goToDefinition` routes an in-root candidate through today's
      `navigateToDefinition` and an out-of-root one to the viewer; an unreadable
      target beeps, exactly like a resolved-nothing click
- [ ] the viewer is structurally read-only: no `WorkspaceModel` tab, no autosave
      participation, no path by which a file outside the root can be written
- [ ] run `swift test` — must pass before task 11

### Task 11: Completion insertion — combined edits, one undo step

The auto-import payoff, applied through the coordinator's programmatic-edit path.

**Files:**
- Modify: `Sources/Pisaka/CompletionController.swift`,
  `Sources/Pisaka/CodeEditorView.swift`

- [ ] the snapshot keeps whole `CompletionItem`s keyed by inserted text (first wins),
      so the delegate still returns strings while insertion can find its item
- [ ] `EditorTextView.insertCompletion` applies an item carrying edits itself —
      programmatic-edit flag raised, one undo group, `CompletionEditPlan`'s ordered
      edits, caret after the inserted text — and defers to `super` for a plain item
- [ ] deferred-resolve items are prefetched concurrently the moment the popup opens;
      an item committed before its resolve lands gets the import as a follow-up edit
      only while the buffer is unchanged (D4's stated limit)
- [ ] the pending prefetch is cancelled by the same events that clear the snapshot
      (new keystroke, caret move, tab switch, `reset()`)
- [ ] run `swift test` — must pass before task 12

### Task 12: Verify acceptance criteria

- [ ] run `swift test` — full suite green
- [ ] `xcodegen generate` then build macOS:
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`
- [ ] build iOS:
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build`
- [ ] confirm the gating suite covers every new app file and that no Core LSP file
      imports a platform framework
- [ ] confirm the no-server-registered routing tests assert equality with the bare
      tree-sitter provider (behavior identical to today, pinned rather than asserted)

### Task 13: Update documentation

- [ ] create `docs/architecture/core-lsp.md` with a full entry per new Core file and
      the decisions D1–D10 written out, including the line-separator known limit, the
      `DefinitionRequest.text` guard, the out-of-project read-only-window decision,
      the auto-import resolve race, and the SwiftPM-project-only scope of
      sourcekit-lsp's build-system support
- [ ] extend `docs/architecture/app-editor.md` (transport, toolchain discovery,
      completion insertion) and `docs/architecture/app-window.md` (the source viewer
      window), and update `core-intelligence.md` for the seam changes
- [ ] add the index lines to `CLAUDE.md` plus the new cross-cutting invariant —
      *one server per (server, root), started lazily, silent per-request fallback,
      unavailable-for-session after repeated failure, and a reader that never takes
      the writer gate*
- [ ] add the feature to `README.md`: semantic definition and completion for Swift,
      the Xcode requirement, auto-import, and the fallback/known limits in the
      existing "Known Limitations (1.0)" voice

## Post-Completion Checks (manual, on a machine with Xcode)

Open a SwiftPM package project in Pisaka and confirm:

- ⌘-click on a symbol declared in another module of the package jumps to it.
- ⌘-click on an SDK symbol opens the read-only viewer window and never a writable tab.
- Completion after `.` on a typed value lists that type's real members.
- Completing a symbol that needs an import inserts the `import` line and the symbol,
  with the caret after the symbol, and a single ⌘Z undoes both.
- `kill`ing the `sourcekit-lsp` process mid-session degrades silently to tree-sitter
  answers, with no alert and no editor stall.
- Quitting the app leaves no orphan `sourcekit-lsp` (`pgrep -fl sourcekit-lsp` is
  empty afterwards).
- On a machine with no Xcode (or `DEVELOPER_DIR` pointed at nothing), Swift files
  behave exactly as they do today.
