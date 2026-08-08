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

- [x] `LSPTransport` protocol (send `Data`, an `AsyncStream<Data>` of incoming bytes,
      `terminate()`) plus `LSPTransportError` — the whole macOS/Core boundary
- [x] `LSPSession` actor: handshake, monotonic ids, pending-request table,
      per-request budget (D7), `$/cancelRequest` on Swift task cancellation,
      answering server-initiated requests (`client/registerCapability`,
      `workspace/configuration` → an empty/absent-value result; anything unknown →
      `MethodNotFound`), ignoring unknown notifications, graceful
      `shutdown`→`exit`→terminate, and a terminal state on EOF that fails every
      pending request
- [x] `ScriptedLSPTransport`: a deterministic fake driving the session from a
      recorded script (reply, delay, drop, close the stream) with no real process
- [x] tests: successful round-trip, out-of-order replies, a reply to an unknown id
      ignored, timeout fails only its own request, cancellation emits
      `$/cancelRequest` and does not leak the pending entry, EOF mid-flight fails
      pending requests once, `shutdown` sequence order
- [x] run `swift test` — must pass before task 4

Two things the implementation settled that the plan had left open, both worth
carrying into Task 13's `core-lsp.md`:

- **The owner keeps the session alive.** `LSPSession`'s read task holds `self`
  *weakly*, so a session nobody references stops reading. That is deliberate — a
  strong self would keep every session (and its process) alive until the server
  itself exited, which is exactly what D7's "drop it and restart" cannot afford —
  but it makes retention a contract: `LSPWorkspace` owns sessions, and anything
  else holding one for the length of a conversation has to say so. Three tests
  caught this by discarding the session and then watching the server-initiated
  requests go unanswered.
- **A framing error is terminal, a bad *payload* is not.** `ingest` distinguishes
  the two: unreadable framing closes the session (there is no way to find where
  the next message starts), while a correctly framed payload that is not a
  JSON-RPC message is dropped and the stream read on — exactly one message is
  lost, and the alternative would kill a live server over one malformed
  notification.

`LSPSession.Budgets` also carries `resolve` (D4's background
`completionItem/resolve`, given the completion budget) and `shutdown` (2 s) beside
D7's three numbers; both are stated on the type rather than left implicit.

### Task 4: Server registry and workspace lifecycle

One server per (server, project root), started lazily, torn down deliberately.

**Files:**
- Create: `Sources/PisakaCore/LSPServerDescription.swift`,
  `Sources/PisakaCore/LSPWorkspace.swift`
- Create: `Tests/PisakaCoreTests/LSPServerRegistryTests.swift`,
  `Tests/PisakaCoreTests/LSPWorkspaceTests.swift`

- [x] `LSPServerDescription` + `LSPServerRegistry` per D9, with the
      Swift/sourcekit-lsp description as the only registered entry
- [x] `LSPWorkspace` (`@MainActor`): lazy start on first request for a served
      language, a `transportFactory` closure (so `Process` stays out of Core),
      per-document open/version bookkeeping, the request-driven
      `didOpen`/`didChange` flush (D2), `didClose`, backoff/restart and session-wide
      unavailability (D7), and `prepareForFolderChange(root:)` returning a generation
      token, synchronously, before any hop — matching the repository's existing scheme
- [x] `shutdownAll()` for folder switch and termination; a document is never opened
      against a root it does not live under
- [x] tests, all on scripted transports: a fake second server description is served
      by configuration alone (no client changes); lazy start happens once per root; a
      text change flushes exactly one `didChange` before the request and none when the
      text is unchanged; a folder switch supersedes in-flight work and closes every
      document; three crashes restart, the fourth marks unavailable and no further
      launch is attempted
- [x] run `swift test` — must pass before task 5

Four things the implementation settled that the plan had left open, all worth
carrying into Task 13's `core-lsp.md`:

- **Two tokens, not one.** `prepareForFolderChange` bumps the public `generation`
  (only when the root actually changes, matching
  `SymbolIndexModel.prepareForFolderChange` so a caller can pin one token across
  both models) *and* a private `epoch`. `shutdownAll()` bumps only the epoch. A
  launch captures the epoch before its handshake and terminates the server it just
  started if it no longer matches — which is what makes "a folder switch supersedes
  in-flight work" true. One token could not do both jobs: a `shutdownAll()` in the
  same turn would invalidate the very token the caller had just pinned from
  `prepareForFolderChange`.
- **A crash is noticed on the next request, not pushed.** `LSPSession` has no
  back-reference to the workspace (Task 3's weak-read-task contract), so
  `liveSession` asks `isRunning` and treats a dead session as the crash. That is
  also where the document bookkeeping for that server is dropped, which is why a
  restarted server is sent `didOpen` rather than a `didChange` against a document
  the new process never had.
- **The restart budget is per `(server, root)`, and a launch failure spends it.**
  D7 says "3 times per (server, root)", so a server that cannot cope with one
  broken project does not poison the next folder. A factory that throws (no Xcode,
  `xcrun --find` empty) counts exactly like a crash — otherwise a machine with no
  toolchain retries a process launch once per keystroke forever.
- **Two failures are terminal rather than countable**, and both are marked
  unavailable immediately: a server that answers `positionEncoding: utf-8` (every
  offset in this codebase is UTF-16, and it will answer the same on every restart)
  and a superseded launch is the opposite — *not* a failure at all, so it costs no
  restart budget and pays no backoff.

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

- [x] `DefinitionCandidate` per D8 — direct fields, optional `kind`, unchanged
      `displayLabel`, retained `init(symbol:relativePath:)`; update every
      `candidate.symbol.*` accessor in Core, both app layers and the two test suites
- [x] `DefinitionRequest` gains `text: String` (defaulted, so no call site breaks)
      and `CompletionItem` gains `edits: [CompletionEdit]` plus an opaque
      `resolveHandle: Int?`, both defaulted so the tree-sitter provider and the iOS
      surfaces are untouched
- [x] update the macOS `goToDefinition(in:at:)` call site in `CodeEditorView.swift`
      to pass the live buffer text into `DefinitionRequest` — the defaulted field is
      never left to default on a path the LSP provider can see (D2)
- [x] `CompletionEditPlan`: given a buffer, a set of `CompletionEdit`s and the
      partial-word range, produce the ordered (last-to-first) application list, the
      resulting caret offset, and a rejection for overlapping or out-of-range edits
- [x] tests: an import inserted *before* the completion point leaves the caret after
      the inserted symbol; an edit after it; multiple additional edits; overlapping
      edits rejected; empty edit list; edits against a buffer that changed since the
      request are rejected rather than misapplied
- [x] run `swift test` — must pass before task 6

Four things the implementation settled that the plan had left open, all worth
carrying into Task 13's `core-lsp.md`:

- **An edit says what it is *for*, because the geometry cannot.** `CompletionEdit`
  carries a `role` (`.primary` / `.additional`) rather than letting the plan infer
  which edit is the completion from the ranges: an `import` inserted at offset 0
  and a symbol completed at offset 0 of an empty file are geometrically
  identical, and D4's "caret after the symbol, never at the import" needs to tell
  them apart. Exactly one `.primary` per plan; zero or two is a rejection.
- **Staleness is checked against the buffer, not assumed.** `make` takes the typed
  word's range *and* what that range contained when the request was made, and
  compares. A completion list is computed behind a debounce and committed a
  keystroke later, so typing, deleting and undoing between the two are ordinary —
  and all three produce offsets that now name someone else's characters. One
  substring catches every one of them, the same per-item re-check
  `ProjectSearchModel` does before it replaces.
- **The primary edit must *cover* the typed word.** A server is free to answer
  with a range wider than the client's prefix (Task 6's stated case), but one that
  reaches less far would leave the typed characters in the buffer with the
  completion appended — `GreGreeter` — so it is refused. Rejection is safe: the
  editor falls back to AppKit's own insertion of the plain text and loses only the
  auto-import.
- **Two edits starting at the same offset are refused even when neither covers a
  character.** They do not overlap geometrically, but nothing in the spec says
  which comes first, and a zero-length insertion at the start of a replaced range
  could land on either side of it. An insertion at the *end* of a replaced range
  has a defined order and is allowed — both cases have a test.

### Task 6: The LSP intelligence provider

Turning protocol answers into seam values, with D6's ranking and D1's offsets.

**Files:**
- Create: `Sources/PisakaCore/LSPIntelligenceProvider.swift`
- Create: `Tests/PisakaCoreTests/LSPIntelligenceProviderTests.swift`

- [x] `definitions(for:)`: build the position from the request's text and offset, map
      `Location`/`LocationLink` results to candidates, compute each target's display
      line and `relativePath` (file name when outside the root), and flag out-of-root
      targets so the app can route them to the read-only window (D3)
- [x] the D2 guard: a definition request whose `text` is empty while its `offset` is
      non-zero is unanswerable — return no answer (so routing falls back) instead of
      clamping the position to 0:0; no request is ever sent for it
- [x] `completions(for:)`: build the completion params (including the member trigger
      as `triggerCharacter: "."`), rank and dedup per D6, convert each item's
      `textEdit`/`insertText` and `additionalTextEdits` into buffer-coordinate
      `CompletionEdit`s, and carry a resolve handle for items the server deferred
- [x] `resolveEdits(for:)` — the defaulted protocol extension point, implemented here
      and a no-op everywhere else
- [x] tests against recorded transcripts: a cross-module definition, a definition
      returning `LocationLink[]`, an SDK target marked out-of-root, member completion
      after `.`, an item whose `textEdit` range is wider than the client prefix range,
      an item resolved into `additionalTextEdits`, server order preserved on
      `sortText` ties, typed-token/dedup/cap hygiene
- [x] test the D2 guard directly: empty text + non-zero offset yields no LSP answer
      and sends nothing to the scripted transport; empty text + offset 0 stays
      answerable
- [x] run `swift test` — must pass before task 7

Four things the implementation settled that the plan had left open, all worth
carrying into Task 13's `core-lsp.md`:

- **A completion request had no caret in it.** `CompletionRequest` carried a
  prefix, a buffer and a member context but no *position*, and a position is the
  whole of what `textDocument/completion` asks about — a prefix cannot be located
  in a buffer that contains it a hundred times. So the request gains
  `offset: Int?`, defaulted to `nil` and read as **unanswerable** by the LSP
  provider (never as 0), which is D2's guard applied to the other request kind;
  both editor call sites pass the caret they already have, so only a future one
  could hit the guard.
- **The out-of-root flag lives on the candidate.** D3 routes a target outside the
  opened folder to a read-only window, and which window is not something the view
  can re-derive without knowing the project root — the same argument that already
  precomputes `relativePath`. `DefinitionCandidate.isOutsideProjectRoot` is
  defaulted `false`, so the tree-sitter path (which only ever walks the opened
  folder) is untouched.
- **The relative path is computed from canonical components, not lexically.**
  `ProjectFileWalk.relativePath` strips a string prefix, which is right for paths
  the project walk itself produced — but a server answers with the path *it*
  resolved, and the recorded sourcekit-lsp really does report
  `/private/tmp/lspfix/pkg/…` for a project opened as `/tmp/lspfix/pkg`. A lexical
  strip reads that as "outside the root" and shows a bare file name, so the
  containment test and the displayed path both go through `CanonicalPath`.
- **An item carries edits only when applying them literally matters.** An item
  that just replaces the typed word with its own text is exactly what AppKit's
  stock insertion already does, so `edits` stays empty there and the editor keeps
  its cheap path; edits appear when the item drags an `import` along (D4) or when
  the server chose a range other than the one the client typed — the two cases
  AppKit would get wrong. A target file that cannot be read is dropped for the
  mirror-image reason: without its text there is no offset, and every consumer of
  a candidate navigates by one.

### Task 7: Routing and silent fallback

The one provider the UI holds, composing LSP with tree-sitter.

**Files:**
- Create: `Sources/PisakaCore/RoutingIntelligenceProvider.swift`
- Create: `Tests/PisakaCoreTests/RoutingIntelligenceProviderTests.swift`

- [x] implement `CodeIntelligenceProviding` by asking the LSP source when the
      request's language has a live (or startable) server, within D7's budget, and
      falling back to the wrapped `SymbolIntelligenceProvider` on timeout, transport
      error, unavailability, or an empty/unusable answer where tree-sitter has one
- [x] fallback is per request and silent: no state is marked, nothing is logged to
      the user, and a slow answer degrades exactly one question
- [x] tests: live server → LSP answer; timeout → tree-sitter answer and the LSP
      request is cancelled; dead/unavailable server → tree-sitter with no launch
      attempt; **no server registered for the language → byte-identical output to the
      bare `SymbolIntelligenceProvider`, asserted by equality on both request kinds**;
      empty LSP completion with a non-empty tree-sitter list falls back; empty LSP
      definition with an empty tree-sitter list still beeps once
- [x] test that a definition request tripping the D2 guard (empty text, non-zero
      offset) routes to the tree-sitter answer rather than producing an LSP one
- [x] run `swift test` — must pass before task 8

Three things the implementation settled that the plan had left open, all worth
carrying into Task 13's `core-lsp.md`:

- **Two budgets over two different spans, both D7's numbers.**
  `LSPSession.Budgets` bounds the *server's* part of one exchange — it starts when
  the request is written. `RoutingIntelligenceProvider.Budgets` bounds the whole
  attempt: resolving the language, starting the process, waiting out the handshake,
  flushing the buffer, and only then asking. Nothing else can bound the first of
  those, and a first ⌘-click in a cold project would otherwise block for the 20 s
  sourcekit-lsp is allowed to resolve a build system in. So the cold-start
  behaviour is stated rather than accidental: the first jump answers from
  tree-sitter while the server finishes starting *behind* it (the launch is an
  unstructured task `LSPWorkspace` owns, so abandoning the attempt does not abandon
  the launch), and the next one is semantic.
- **The router is the LSP source's only extra question.** Composing needed one
  thing `CodeIntelligenceProviding` does not have — *is it worth asking you* — so
  `LSPIntelligenceSource` refines the seam with `canServe(_:)` (delegating to
  `LSPWorkspace.canServe`, which starts nothing) and adds `Sendable`, which the
  deadline race requires because it puts the call in a child task. The workspace
  stays private to `LSPIntelligenceProvider`: nothing above the seam can reach past
  it to start, stop or interrogate a server.
- **D2's guard is not repeated in the router**, deliberately. A `DefinitionRequest`
  with no text is unanswerable *by a language server* specifically — the index
  looks names up and does not care — so the rule stays in `LSPIntelligenceProvider`
  and the router needs no special case, because "no answer" already routes to
  tree-sitter. The routed *outcome* is pinned by its own test all the same.

### Task 8: macOS transport and sourcekit-lsp discovery

The only new app-side machinery, thin and `#if os(macOS)`-gated.

**Files:**
- Create: `Sources/Pisaka/LSPProcessTransport.swift`, `Sources/Pisaka/LSPToolchain.swift`
- Create: `Tests/PisakaCoreTests/LSPSourceGatingTests.swift`

- [x] `LSPProcessTransport`: `Process` + three pipes on a dedicated serial queue (the
      `GitCLIService` idiom), stdout fed into `LSPFraming.Decoder` and published as
      the transport's `AsyncStream`, stderr drained and discarded, environment
      inherited, `terminate()` sending SIGTERM then reaping — and a `deinit`/
      termination path as deliberate as `TerminalSession.terminate()`, so no
      `sourcekit-lsp` ever outlives the app
- [x] `LSPToolchain`: `xcrun --find sourcekit-lsp` honouring `DEVELOPER_DIR`, result
      (including "not found") cached per app run, nothing bundled or downloaded
- [x] `LSPSourceGatingTests` (repo-file suite, `#filePath` + Foundation): every new
      `Sources/Pisaka` LSP file is wrapped in `#if os(macOS)`, and no
      `Sources/PisakaCore/LSP*.swift` mentions `Process`, `AppKit`, `UIKit` or
      `SwiftTreeSitter`
- [x] run `swift test` — must pass before task 9

Five things the implementation settled that the plan had left open, all worth
carrying into Task 13's `core-lsp.md` (and, for the first three, into
`app-editor.md`):

- **The transport publishes raw chunks, not payloads.** The checkbox above says
  "stdout fed into `LSPFraming.Decoder` and published as the transport's
  `AsyncStream`", but `LSPSession` already owns a decoder and Task 3's
  `LSPTransport` states the contract outright — the stream carries "the bytes the
  server wrote, in whatever chunks the pipe delivered them". A decoder here would
  be a second one framing already-framed bytes. So the transport hands `availableData`
  straight through, and the one framing decoder in the client stays where the
  terminal-vs-recoverable distinction is (Task 3's "a framing error is terminal, a
  bad payload is not").
- **`SIGPIPE` would kill the app, not the write.** A server that crashes between
  two `didChange`s leaves a pipe with no reader, and the default disposition of
  `SIGPIPE` terminates the *writing* process — Pisaka. The write end is therefore
  put in `F_SETNOSIGPIPE` mode, per file descriptor rather than by ignoring the
  signal process-wide, so `write(2)` returns `EPIPE`, `FileHandle` throws it, and
  the failure joins the ordinary death path. This is the one thing on the whole
  transport that could take the app down, and it is invisible until a server
  crashes at exactly the wrong moment.
- **A failed write is reported as EOF, because there is nobody to report it to.**
  `send` returns as soon as the bytes are queued (the protocol says so: waiting
  would park the session's actor behind a pipe a busy server has not drained, and
  a `didChange` carrying a large file exceeds the buffer). So a write that fails
  afterwards finishes the byte stream instead of throwing — the one signal the
  session already knows how to act on. `notRunning` is thrown only for a send
  after the transport has stopped.
- **`weak self` in the readability handler is load-bearing twice.** A `FileHandle`
  retains its handler, the handle is retained by the pipe, and the pipe by the
  transport — a strong capture is a cycle, so `deinit` never runs and the
  `deinit`-kills-the-process guarantee silently evaporates. It also makes "a
  transport nobody references stops reading" true, matching Task 3's contract
  about the session's own read task. The `terminationHandler` is the backstop for
  the EOF that never comes (a server whose child inherited stdout), which
  otherwise leaves a crash unnoticed and every request falling back until the
  folder is closed.
- **The gating suite's scanner strips comments before it matches anything**, and
  that is not a refinement — it is the only way the check can exist.
  `LSPWorkspace`'s documentation opens with "**`Process` is not in this file, and
  cannot be**", `LSPTransport` says the app owns "a `Process` and three pipes",
  and `LSPIntelligenceProvider` discusses "AppKit's stock insertion". A substring
  search fails on all three, and rewording the documentation to appease a test is
  the wrong direction. `Process` is additionally matched as a whole token so
  `ProcessInfo`/`processIdentifier` are not false positives, and the scanner is
  pinned by its own test — a stripper that returned the empty string would pass
  every "does not contain" assertion and check nothing.

### Task 9: App wiring — composition and lifecycle

Hanging the new layer off the places that already exist, and nowhere else.

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `Sources/Pisaka/Platform/SymbolIndexController.swift` (the `provider` seam
  it already exposes)

- [x] construct the `LSPWorkspace` with the process transport factory and the Swift
      registry entry, wrap `symbolIndex.provider` in the routing provider, and hand
      the *routing* provider to the editor surfaces — no view signature changes
- [x] re-confirm the macOS `goToDefinition` path built in Task 5 passes the live
      buffer text through the routing provider — no path reaches the LSP provider with
      a defaulted-empty `DefinitionRequest.text`
- [x] folder switch: `prepareForFolderChange` + `shutdownAll()` in the same
      main-actor turn as the existing tokens, alongside `symbolIndexController.reset()`
- [x] tab close: `didClose` beside `forgetIndexedBuffer(_:)`, under the same "no
      other tab shows this file" guard
- [x] termination: `shutdownAll()` from the existing `willTerminateNotification`
      observer, beside `terminalSessions.terminateAll()` / `diffWindows.closeAll()`
      — resolved to the synchronous `LSPWorkspace.terminateNow()`, see below
- [x] confirm the writer gate is untouched: no `autosave.suspend()` /
      `beginRevert()` anywhere on this path (D10)
- [x] run `swift test` — must pass before task 10

Four things the implementation settled that the plan had left open, all worth
carrying into Task 13's `core-lsp.md` (and the first into `app-editor.md`):

- **A quit cannot `await`, so termination needed a synchronous path.**
  `willTerminateNotification` is the last thing AppKit posts before the process
  exits, which is why the autosave and session writers already flush
  *synchronously* from that observer — a `Task` wrapping `shutdownAll()` there
  would compile, never be picked up, and leave exactly the orphan
  `pgrep -fl sourcekit-lsp` checks for. So `LSPWorkspace` gains
  `terminateNow()`: it reaches past the sessions (actors, hence unreachable
  without a hop) to the transports, whose `terminate()` is synchronous and
  idempotent by Task 3's contract. That required the workspace to hold the
  transport beside each session — registered *before* the handshake, so a quit
  also kills a server still resolving a build system, which is the state a quit
  is likeliest to land in. `shutdownAll()` stays the polite path and is what a
  folder switch uses. A `forget(_:for:)` identity check guards the map for
  `pendingLaunches`' reason: a launch that gives up resumes arbitrarily later and
  must not clear a *newer* transport filed under the same key.
- **The seam is the controller's `provider`, not the view signatures.** The
  editor surfaces read `symbolIndex.provider` already, so
  `SymbolIndexController.installProvider(_:)` swaps in the composed provider and
  not one view signature changes — and the routing provider's fallback is
  literally `model.provider`, the same live-reading instance, so a language no
  server serves takes the path it took before this phase existed. iOS installs
  nothing and so stays exactly the index.
- **The folder switch has one narrow window, stated rather than engineered
  around.** `prepareForFolderChange` is synchronous (the ordering rule) and
  `shutdownAll()` cannot be, so a request landing between the two sees the *new*
  root and may start its server, which the teardown then stops. It costs one
  wasted launch and one tree-sitter answer and — the part that matters — no
  restart budget: a superseded launch is not a failure, and a server shut down
  deliberately leaves no dead session for the next request to count as a crash.
  The teardown is skipped entirely when the root did not change, so re-opening
  the same folder does not throw away a resolved build system.
- **`didClose` shares the tab-close guard rather than copying it.** It sits
  inside `forgetIndexedBuffer(_:)`, under the same "no other tab shows this file"
  test, because the index and the server must agree about when a file stops
  having a buffer — a `didClose` for a file another tab still shows would leave
  the server answering about a document it has dropped. Fire-and-forget: nothing
  waits on it, and a server that cannot be told opens the document afresh on its
  next request anyway.

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
