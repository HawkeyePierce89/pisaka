# LSP diagnostics: errors and warnings in the editor, the gutter, and a panel

## Overview

Surface `textDocument/publishDiagnostics` from the language servers Pisaka
already runs, in three macOS surfaces: squiggly underlines in the editor, a
per-line severity marker in the gutter, and a new "Problems" bottom-dock panel.
Every decision — the wire mapping, the store, the staleness/shift rule,
worst-severity-per-line, panel ordering — lives in `PisakaCore` and is
unit-tested; the view layer stays thin glue.

Three structural additions make it possible:

1. **A notification channel.** `LSPSession` today drops every server-initiated
   notification on the floor (`handle(_:)`, `case .notification: break`). It
   gains an `AsyncStream` of notifications, consumed by `LSPWorkspace` — a
   stream rather than a callback, because two pushes for one document reordered
   by two independent `Task` hops would leave stale errors on screen forever.
2. **A push sync.** D2's sync is request-driven; diagnostics are push-only, so
   without a sync the server never re-diagnoses after an edit. Per the answered
   question, every open buffer of a served language is re-synced on a 400 ms
   debounce (beside the symbol index's existing one), plus immediately on tab
   open/switch. The sync is exactly one
   `LSPWorkspace.prepare(url:language:text:)` call with no follow-up request.
3. **A buffer-truth gate.** Diagnostics are mapped against the text the *server
   was told* (`documents[uri].text`), accepted only for the version the server
   currently holds and only when the buffer has not been edited since that sync;
   afterwards they are shifted across each edit, dropping anything the edit
   touched.

No new settings, no new servers, no new consent surface, no iOS UI.

## Context

**Files involved (read the matching `docs/architecture/` entry before touching
each):**

- Core, LSP layer (`core-lsp.md`): `LSPSession.swift`, `LSPWorkspace.swift`,
  `LSPProtocolTypes.swift`, `LSPPositionMap.swift`, `CodeIntelligence.swift`,
  `HoverContent.swift`
- Core, new: `Diagnostic.swift`, `DiagnosticShift.swift`,
  `DiagnosticStore.swift`, `DiagnosticsModel.swift`
- Core, modified elsewhere: `BottomPanel.swift` (`core-services.md`)
- App, macOS (`app-editor.md`, `app-editor-overlays.md`, `app-window.md`,
  `app-shell.md`): `CodeEditorView.swift`, `BracketOverlayLayoutManager.swift`,
  `LineNumberRulerView.swift`, `SyntaxTheme.swift`, `HoverController.swift`,
  `ContentView.swift`, `PisakaApp.swift`
- App, new: `LSPDocumentSyncController.swift`, `ProblemsPanelView.swift`
- Tests: `Tests/PisakaCoreTests/Support/ScriptedLSPTransport.swift` (gains a
  server-push helper)

**Existing patterns reused, not replaced:**

- `BlameShift.updated(...)` — the shape for `DiagnosticShift`: pure arithmetic
  over the *pre-edit and post-edit line-start arrays* the ruler already holds,
  with a documented fallback for inconsistent input.
- `BracketOverlayLayoutManager` — the temporary-attribute overlay merge.
  Diagnostics add a fourth cache alongside the rainbow runs, the caret pair and
  the search matches, using `.underlineStyle`/`.underlineColor` keys so they
  cannot fight the existing `.foregroundColor`/`.backgroundColor` writers (the
  class's "sole writer of `.backgroundColor`" rule stays intact).
- `SymbolIndexModel` + `SymbolIndexController` — the split between a Core
  observable reader and thin view-layer debounce glue;
  `LSPDocumentSyncController` is its exact analogue for the LSP sync.
- `activateSearchMatch(url:range:)` in `PisakaApp` — open-and-reveal, already
  shared by Find in Files and Go to Definition; the panel becomes its third
  caller.
- `SyntaxTheme` — every color is a `PlatformColor.dynamic(light:dark:)` in the
  view layer; Core stays color-free.

**Dependencies:** none new.

## Decisions this plan makes (each gets a numbered entry in `core-lsp.md`, continuing from D28)

- **D29 — Notifications arrive on a stream.** `LSPSession` exposes
  `notifications: AsyncStream<LSPServerNotification>`, created at init and
  consumed by `LSPWorkspace` in one main-actor task per session. Ordering is the
  whole reason: a "2 errors" push followed by an "all clear" push, delivered by
  two independent `Task { @MainActor }` hops, can arrive backwards and strand
  errors under corrected code for the life of the session. The stream also gives
  the workspace a *termination* signal — see D33.
- **D30 — The sync is the one thing this layer says unasked.** Every open buffer
  of a served language is flushed to its server 400 ms after typing stops
  (per-URL debounce, superseded by the next keystroke for the same file), and
  immediately on tab open/switch. It is one `prepare(...)` call: the whole of
  D2's flush machinery, the launch coalescing, the root check and the
  unavailability gate already apply, so this adds a *trigger*, not a second code
  path. Cost is one full-text `didChange` per typing pause per edited file,
  exactly as the answered question sanctioned. Consequence worth stating:
  opening a served file now launches its server, where before a completion or a
  ⌘-click was needed — that is what "diagnostics on open" means, and
  consent-gated servers are still not in the registry until consented.
- **D31 — Diagnostics are anchored to the text the server was told.** A push is
  mapped through `LSPPositionMap` against `documents[uri].text` at receipt, and
  accepted only when `params.version` is absent or equals
  `documents[uri].version`. A push for a URI no server currently holds open is
  ignored (the panel covers open documents only).
- **D32 — Stale means shifted, and what the edit touched is dropped.** Between
  the push that produced a set and the next one, each editor edit runs
  `DiagnosticShift`: a diagnostic entirely before the edit is unchanged, one
  entirely after is shifted and renumbered, and one whose range intersects the
  touched span is **dropped**. So the error you are currently fixing loses its
  underline on the first keystroke, while errors elsewhere in the file stay
  anchored to their code — rather than either drifting (no shift) or blinking
  off on every keystroke (blanket clear). A wholesale buffer replacement (tab
  switch, `reloadFromDisk`, project Replace All, merge apply) drops the
  document's set outright. **Rejected:** replaying a queue of edits onto a
  late-arriving push. It is exact but needs a bounded per-document edit log and a
  revision↔version map; dropping a push whose buffer moved on is simpler,
  self-correcting (the last keystroke always schedules one more sync, whose push
  has no edits after it), and matches the ticket's own preference for briefly
  missing over misplaced.
- **D33 — A server's diagnostics die with it.** Clearing is keyed by
  `(server, root)` and happens on every teardown path — `noteDeath`,
  `shutdownAll`, `terminateNow`, `updateRegistry`'s removals, and the
  fourth-failure unavailability — plus per-document on `didClose(url:)`. The
  externally-killed server is covered by the *stream's* termination: the
  session's read task hits EOF, the session closes, the notification stream
  finishes, and the workspace's consumer task clears that key on the way out. It
  does not tear the session down or touch D7's counters; noticing a crash stays
  `prepare`'s job.
- **D34 — Hover carries the diagnostic message; there is no second surface.**
  The existing dwell/panel/dismissal pipeline shows the messages under the
  pointer, above the type answer when there is one and alone when there is not.
  Two changes follow: the dwell must fire inside a diagnostic range even when the
  pointer is not on an identifier (a diagnostic can cover punctuation), and the
  anchor range becomes the diagnostic's rather than the identifier's. D25 is
  untouched — a diagnostic comes from a server, so this is still "a server or
  nobody" — and D26's unreachable-chrome rule still applies to the popover.

**No new setting.** Diagnostics are what the server already computes for a
document it already holds; there is nothing to turn off that is not already off
when no server is registered for the language. Adding a flag would be a second
way to express "no server", which is the one state the whole LSP layer expresses
by absence.

## Development Approach

- **Testing approach**: Regular (code first, then tests) for the view layer; TDD
  for the Core engines (`DiagnosticShift`, `DiagnosticStore` and the mapping are
  pure functions whose edge cases are the point).
- Complete each task fully before moving to the next.
- Core additions are Foundation-only and platform-neutral; every macOS view file
  stays inside `#if os(macOS)`.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: all tests must pass (`swift test`) before starting the next task.**

## Implementation Steps

### Task 1: Core value types, severity mapping and the wire shape

**Files:**
- Create: `Sources/PisakaCore/Diagnostic.swift`
- Modify: `Sources/PisakaCore/LSPProtocolTypes.swift`

- [x] Add the wire types to `LSPProtocolTypes.swift` in that file's "decode
      leniently, encode exactly" style: `LSPDiagnosticSeverity` (raw `Int`, 1–4),
      `LSPDiagnostic` (`range`, `severity`, `code`, `source`, `message`, with
      everything optional but `range`/`message`),
      `LSPPublishDiagnosticsParams` (`uri`, `version: Int?`, `diagnostics`), and
      `LSPMethod.publishDiagnostics`; declare `textDocument.publishDiagnostics`
      in the closed client-capability tree so the handshake stays an honest
      description of what this client does.
- [x] Create `Diagnostic.swift`: `DiagnosticSeverity`
      (`error`/`warning`/`information`/`hint`, `Comparable` by seriousness, with
      the LSP-integer mapping and the documented rule that an absent or unknown
      severity is treated as `.error`, which is what the spec's "client decides"
      means for an editor that must not hide a failure) and `Diagnostic` (buffer
      `range: NSRange`, `line: Int`, `severity`, `message`, `source: String?`,
      `fileURL`).
- [x] Add the pure conversion `Diagnostic.make(from:in:lineStarts:)` mapping one
      `LSPDiagnostic` through `LSPPositionMap` into buffer offsets, clamping an
      out-of-range position to the buffer and dropping a diagnostic whose range
      cannot be placed at all.
- [x] Add `Diagnostic.orderingKey` (file path, then start offset, then severity)
      — the panel's stable order, decided here rather than in the view.
- [x] Write `DiagnosticTests`: the severity table both ways, absent/unknown
      severity, an empty range (a zero-length diagnostic at a position), a range
      past the end of the buffer, a multi-line range, a range containing
      non-ASCII (UTF-16 counting), and the ordering key's total order.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: The shift rule and the store

**Files:**
- Create: `Sources/PisakaCore/DiagnosticShift.swift`,
  `Sources/PisakaCore/DiagnosticStore.swift`

- [x] `DiagnosticShift.updated(_:previousLineStarts:newLineStarts:editedRange:changeInLength:)`
      in `BlameShift`'s shape and with its documentation discipline: compute the
      touched span in pre-edit coordinates, drop every diagnostic intersecting
      it, shift the rest by `changeInLength`, renumber each survivor's `line`
      from `newLineStarts`, and fall back to `[]` (honest "unknown", never a
      drifted set) on inconsistent input.
- [x] `DiagnosticStore`: a value type keyed by document URL, each entry holding
      `[Diagnostic]` plus the server key that produced it and the version it
      describes. Operations: `replace(url:serverKey:version:diagnostics:)`
      (wholesale, LSP semantics), `clear(url:)`, `clear(serverKey:)`,
      `clearAll()`, `apply(shift:to:)`.
- [x] Query surface, all pure: `diagnostics(at offset:in url:)` (hover),
      `worstSeverityPerLine(url:lineCount:)` returning `[DiagnosticSeverity?]` at
      exactly `lineCount` entries (the ruler indexes it by line, the `BlameShift`
      invariant applied here), `rows(relativeTo root: URL)` (grouped by file,
      ordered by `orderingKey`, carrying the relative path via
      `CanonicalPath`/`DisplayPath`), and `counts` (errors/warnings for the
      header). Note: `worstSeverityPerLine` grew one parameter (`lineStarts:`)
      because marking every line a multi-line span crosses needs line geometry,
      which the store deliberately does not keep; documented on the query.
- [x] Write `DiagnosticShiftTests`: insertion before/inside/after a diagnostic, a
      deletion spanning one, an Enter split, a multi-line paste, a whole-line
      deletion, a replacement that exactly covers a diagnostic, and every
      inconsistent-input fallback.
- [x] Write `DiagnosticStoreTests`: wholesale replacement (a second push with
      fewer entries removes the first's), clear by url / by server key / all,
      per-line worst severity (two severities on one line, a multi-line
      diagnostic marking every line it spans, a line with none), ordering across
      two files, and the counts.
- [x] Run `swift test` — must pass before Task 3.

### Task 3: The session's notification stream

**Files:**
- Modify: `Sources/PisakaCore/LSPSession.swift`,
  `Tests/PisakaCoreTests/Support/ScriptedLSPTransport.swift`

- [x] Add `LSPServerNotification` (method + params) and `LSPSession.notifications:
      AsyncStream<LSPServerNotification>`, built in `init` with a single
      continuation; `handle(_:)`'s `.notification` case yields into it instead of
      discarding, and `close(reason:)` finishes it exactly once (it is already
      the single terminal transition, so no second finish is reachable).
- [x] Document on the stream that it has one consumer (`LSPWorkspace`, attached
      before `start`), that buffering is unbounded because the owner always
      consumes, and that finishing it is the crash/exit signal D33 reads.
- [x] Update the type's header comment: the "notifications are all noise here"
      paragraph is no longer true.
- [x] Extend `ScriptedLSPTransport` with `push(method:params:)` so a test can
      make the fake server send a server-initiated notification at any moment,
      and a `pushAfter(delay:)` variant for ordering cases.
- [x] Write `LSPSessionNotificationTests`: a notification is delivered with its
      params intact; two notifications arrive in send order; a notification
      interleaved with a request's response does not disturb the pending table;
      the stream finishes on EOF, on a framing error and on `shutdown()`; a
      malformed notification payload is dropped without ending the stream.
- [x] Run `swift test` — must pass before Task 4.

### Task 4: Workspace routing, the clear rules, and the model

**Files:**
- Modify: `Sources/PisakaCore/LSPWorkspace.swift`
- Create: `Sources/PisakaCore/DiagnosticsModel.swift`

- [x] In `LSPWorkspace.launch`, attach one main-actor consumer task per session,
      held beside the session and cancelled with it. It decodes
      `textDocument/publishDiagnostics`, applies D31 (URI must be a document
      currently held for this key; `version` must be absent or equal to the held
      version), maps through `Diagnostic.make(from:in:lineStarts:)` against
      `documents[uri].text`, and hands the result to a sink. Every other
      notification is ignored as before.
- [x] Add the sink as `var onDiagnostics: ((LSPDiagnosticEvent) -> Void)?` with
      `LSPDiagnosticEvent` covering
      `published(url:serverID:version:diagnostics:)` and
      `cleared(serverID:root:)` / `cleared(url:)`.
- [x] Emit the clears on every teardown path per D33: `noteDeath`,
      `shutdownAll`, `terminateNow`, `updateRegistry`'s stale-key branch (both
      the live-session and pending-launch halves), the `unavailable.insert`
      sites, and `didClose(url:)`. The consumer task's own termination emits the
      key's clear — that is the externally-killed-server path.
- [x] Create `DiagnosticsModel`: `@MainActor public final class ... :
      ObservableObject` (the `SymbolIndexModel` precedent) holding a
      `DiagnosticStore`, a per-document buffer revision, and the sync
      bookkeeping. API: `noteSynced(url:version:revision:)`,
      `noteEdit(url:previousLineStarts:newLineStarts:editedRange:changeInLength:)`
      (shift + bump revision), `noteBufferReplaced(url:)` (clear + bump),
      `receive(_ event:)` (accept a push only when its version is the last synced
      one **and** the document's revision still equals the revision recorded at
      that sync — D32's drop rule), `prepareForFolderChange()` (clear
      everything, bump the generation), and the read-only queries the views use.
- [x] Document on the model that it is a **reader**: it never raises
      `autosave.suspend()`/`localChanges.beginRevert()` and is never gated by
      them, for the symbol index's stated reason.
- [x] Write `LSPDiagnosticsRoutingTests` over `ScriptedLSPTransport`: a push for
      an open document reaches the sink with buffer offsets; a push with a stale
      version is dropped; a push for an unopened URI is dropped; a crash
      mid-session clears that key; a folder switch clears everything; `didClose`
      clears one document; `updateRegistry` removing a server clears its
      documents and not another server's.
- [x] Write `DiagnosticsModelTests`: a push accepted when nothing was edited
      since the sync; the same push dropped when the revision moved; an edit
      shifting a set and dropping the touched diagnostic; a buffer replacement
      clearing; two documents kept independent; the generation dropping a push
      that arrives after a folder change.
- [x] Run `swift test` — must pass before Task 5.

### Task 5: The debounced sync and the app composition

**Files:**
- Create: `Sources/Pisaka/LSPDocumentSyncController.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`, `Sources/Pisaka/CodeEditorView.swift`

- [x] `LSPDocumentSyncController` (macOS-gated, thin untested glue in
      `SymbolIndexController`'s exact idiom): a per-URL cancellable `Task` map, a
      400 ms debounce for `noteBufferChanged(url:text:language:)`, no debounce
      for `noteBufferOpened(...)`, and `reset()` for a folder change. Each task
      pins the model's current revision **synchronously** before the hop, awaits
      `lspWorkspace.prepare(url:language:text:)`, and reports
      `noteSynced(url:version:revision:)` on success; a `nil` prepare (no server,
      unavailable, outside the root, folder moved) does nothing at all, silently.
      (Pinning reads a new `DiagnosticsModel.currentRevision(for:)`.)
- [x] Compose in `PisakaApp.init` beside the existing LSP block: construct
      `DiagnosticsModel`, set `lspWorkspace.onDiagnostics` to forward into it,
      construct the sync controller. Wire `prepareForFolderChange` (the same
      main-actor turn as `lspWorkspace.prepareForFolderChange` /
      `symbolIndexController.reset`) and the tab-close path beside the existing
      `lspWorkspace.didClose(url:)` call.
- [x] Call the sync controller from `CodeEditorView`'s three existing call sites
      beside `symbolIndexController.noteBufferOpened`/`noteBufferChanged`, and
      from `PisakaApp`'s `noteBufferClosed`/`noteBufferOpened` sites — the same
      triggers, so the two readers can never disagree about which buffer is
      current. (Forwarded inside `Coordinator.reindexSymbols`, which is exactly
      where those two index calls live and which all three sites funnel through.)
- [x] Verify by inspection that nothing in this path raises the writer gate, and
      that a `nil` prepare produces no log output and no alert (verified: the
      only `autosave`/`beginRevert` mentions in `LSPWorkspace`/the controller are
      doc comments stating their absence; `prepare` logs nothing on any failure,
      uniform-nil contract, and the controller acts not at all on `nil`).
- [x] Extend `DiagnosticsModelTests` with the sync bookkeeping contract the
      controller depends on (revision pinned before the hop, a sync reported for
      a revision that has since moved is recorded but its pushes rejected).
- [x] Run `swift test` and `swiftlint --strict` — must pass before Task 6.
      (3293 tests green; lint clean; macOS app build verified as well, since
      these macOS-only files are outside `swift test`'s target.)

### Task 6: Editor underlines

**Files:**
- Modify: `Sources/Pisaka/BracketOverlayLayoutManager.swift`,
  `Sources/Pisaka/SyntaxTheme.swift`, `Sources/Pisaka/CodeEditorView.swift`

- [x] Add four dynamic colors to `SyntaxTheme` with light/dark values chosen
      deliberately against the existing palette (error red distinct from
      `unmatchedBracketColor` and `.string`; warning amber distinct from
      `searchMatchBackground`; information and hint muted), plus the `ns…`
      accessors the temporary-attribute call sites need.
- [x] Add a `diagnosticRuns: [(range: NSRange, severity:)]` cache to
      `BracketOverlayLayoutManager`, sorted ascending and binary-searched like
      the rainbow runs, painted through `.underlineStyle` + `.underlineColor` in
      `applyOverlays(in:)` so Neon's per-write clear cannot erase it; add
      `setDiagnosticRuns(_:)` and a `clearDiagnostics(in:storageLength:)` on the
      pre-edit-coordinate contract `clearRainbow` already documents.
- [x] Draw the squiggle by overriding
      `drawUnderline(forGlyphRange:underlineType:...)`: when the underline type
      carries the diagnostic marker, stroke a zigzag path along the fragment's
      baseline in the run's color instead of the straight line AppKit would draw.
      Document why (AppKit has no wavy `NSUnderlineStyle`) and that overlapping
      diagnostics resolve to the worst severity for the overlapping span.
- [x] In `CodeEditorView.Coordinator`: push the active document's runs on every
      model change and tab switch; on the text-storage edit notification, drive
      `diagnostics.noteEdit(...)` from the ruler's pre/post line-start arrays (a
      `onEdit` closure on the ruler, captured **weakly** per the file's stated
      retain-cycle rule) and re-push; drive `noteBufferReplaced(url:)` from the
      `contentReplaced` branch beside `beginBlameBufferSwap()`.
- [x] Build both destinations (`xcodebuild` macOS + iOS) and run
      `swiftlint --strict`; run `swift test` — must pass before Task 7.

### Task 7: Gutter markers

**Files:**
- Modify: `Sources/Pisaka/LineNumberRulerView.swift`,
  `Sources/Pisaka/CodeEditorView.swift`

- [x] Add a fixed-width marker column between the blame column and the line
      numbers, contributing a **constant** width to `updateThickness()` whether
      or not there are diagnostics — so nothing shifts when a server starts,
      stops, or first reports. Document the trade (a few points of permanent
      gutter for everyone, versus a gutter that jumps under the pointer).
- [x] Add `setDiagnosticSeverities(_ severities: [DiagnosticSeverity?])`
      maintaining the `count == lineCount` invariant the blame column already
      relies on, and draw one marker per line in the draw loop beside
      `drawAnnotation`, in `SyntaxTheme`'s severity colors, at the scaled ruler
      font size.
- [x] Feed it from the coordinator with
      `store.worstSeverityPerLine(url:lineCount:)` on every model change, edit
      and tab switch; clear on buffer swap.
- [x] Confirm the ruler still declares `zoomSurfaceKind == .code` and that the
      marker scales with the code zoom like the numbers beside it.
- [x] Extend `DiagnosticStoreTests` with the exact-length and multi-line-span
      cases the ruler indexes by (a diagnostic spanning the last line; a document
      of one line; an empty document).
- [x] Run `swift test`, `swiftlint --strict`, and the macOS build — must pass
      before Task 8.

### Task 8: The Problems panel

**Files:**
- Modify: `Sources/PisakaCore/BottomPanel.swift`,
  `Tests/PisakaCoreTests/BottomPanelTests.swift`,
  `Sources/Pisaka/ContentView.swift`, `Sources/Pisaka/PisakaApp.swift`
- Create: `Sources/Pisaka/ProblemsPanelView.swift`

- [x] Add `.problems` to `BottomPanel` (`toggled(_:selecting:)` needs no change)
      and extend `BottomPanelTests` to cover it in all three existing shapes.
- [x] `ProblemsPanelView`: a header with the error/warning counts from
      `store.counts`, and a list of `store.rows(relativeTo:)` grouped by file —
      severity icon, relative path, line, message — in the
      `LocalChangesView`/`CommitLogView` idiom, sized through
      `\.interfaceMetrics` like its siblings. Activating a row calls back with
      `(url, range)`.
- [x] Wire it into `ContentView`'s `panelContent(_:)` and add its bottom-bar
      button beside Terminal/Git/Changes; wire the callback in `PisakaApp`
      straight to the existing `activateSearchMatch(url:range:)`, which already
      opens-or-reselects the tab and reveals the range.
- [x] Add the View-menu item beside the existing panel commands so button and
      command behave identically through `togglePanel`.
- [x] Extend `DiagnosticStoreTests` for the row shape: grouping across two files,
      the relative path for a file at the root and one nested, a file outside the
      root, and the counts excluding information/hint. (The grouping, root /
      nested / outside path, and count cases already existed from Task 2's
      suite; this task added the rendered-field + same-offset-severity-order
      case.)
- [x] Run `swift test`, `swiftlint --strict`, and the macOS build — must pass
      before Task 9. (3297 tests green; lint clean; macOS build succeeded after
      `xcodegen generate` picked up the new file.)

### Task 9: Hover carries the message

**Files:**
- Modify: `Sources/PisakaCore/Diagnostic.swift`,
  `Sources/Pisaka/HoverController.swift`, `Sources/Pisaka/CodeEditorView.swift`

- [ ] Add the pure builder
      `Diagnostic.hoverContent(for diagnostics:merging typeAnswer:)` producing
      `HoverContent` segments — the messages as prose, severity-labelled and in
      `orderingKey` order, above the type answer's segments when there is one —
      and reusing `HoverContent`'s existing truncation so D26's cap is applied
      once, not twice.
- [ ] Extend `HoverController.Source` with a diagnostics lookup, and change the
      dwell rule so a pointer inside a diagnostic range asks even when it is not
      over an identifier; the anchor becomes the diagnostic's range (union of the
      ones hit) so the re-ask suppressor still holds while the pointer stays in
      it.
- [ ] Keep every dismissal rule, the generation token and the silent-failure
      behaviour exactly as they are; no second popover type is introduced.
- [ ] Extend `DiagnosticTests` with the hover-content builder: one diagnostic
      alone, two on one range, a diagnostic plus a type answer, a message longer
      than the cap, and an empty set falling through to the type answer
      unchanged.
- [ ] Run `swift test`, `swiftlint --strict`, and the macOS build — must pass
      before Task 10.

### Task 10: Verify acceptance criteria

- [ ] `swift test` — full suite green
- [ ] `swiftlint --strict` from the repository root — clean, with no new in-file
      disable markers
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- [ ] Confirm by inspection that no Core file added here imports anything but
      Foundation, and that every new app file is inside `#if os(macOS)`

### Task 11: Update documentation

- [ ] `docs/architecture/core-lsp.md`: full per-file entries for the four new
      Core files and the changed contracts of
      `LSPSession`/`LSPWorkspace`/`LSPProtocolTypes`, plus decisions D29–D34 in
      the file's existing numbered style, and the invariant list at the end
- [ ] `docs/architecture/app-editor-overlays.md` (the overlay manager's fourth
      cache and the squiggle drawing; the ruler's marker column),
      `app-editor.md` (`LSPDocumentSyncController`, the hover change),
      `app-window.md` (`ProblemsPanelView`), `app-shell.md` (the composition in
      `PisakaApp`), `core-services.md` (`BottomPanel`'s new case)
- [ ] `CLAUDE.md`: one index line per new file only (`Diagnostic.swift`,
      `DiagnosticShift.swift`, `DiagnosticStore.swift`, `DiagnosticsModel.swift`,
      `LSPDocumentSyncController.swift`, `ProblemsPanelView.swift`) and a
      one-clause amendment to the "Language servers" cross-cutting invariant
      noting the push channel and the debounced sync — no essays
- [ ] `README.md` / `docs/FEATURES.md`: the user-facing line for the Problems
      panel and its shortcut

## Post-Completion (manual, by the user)

- Open a Swift file with a type error in a sourcekit-lsp project: red underline,
  gutter marker, panel row with the right path/line/message
- Fix it in the buffer without saving: all three clear after the server
  re-diagnoses, with no stale underline under the corrected code
- Two diagnosed files open: both groups listed; clicking the inactive file's row
  switches and reveals
- A `.gitignore` file: no diagnostics UI anywhere, nothing in the log
- `kill` the server process: its diagnostics vanish from all three surfaces
